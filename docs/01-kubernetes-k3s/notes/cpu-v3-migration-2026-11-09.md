# Kubernetes 节点 VM CPU 升级到 x86-64-v3

- **日期**：2026-11-09
- **Proxmox**：8.4.13 / QEMU 9.2.0（单机，未加入 Proxmox 集群）
- **宿主 CPU**：Intel Xeon Gold 6138（Skylake-SP，支持 AVX2/BMI1/BMI2/FMA/F16C/MOVBE）
- **变更前**：6 台 VM 均为 `x86-64-v2-AES`
- **变更后**：6 台 VM 均为 `x86-64-v3`
- **目的**：让节点支持 x86-64-v3，从而使用标准 Ceph-CSI `v3.18.2` 镜像（不再需要 `-rocky9` 构建），同时为其他负载提供 AVX2 等指令集。

---

## 1. 最终结果

| 节点 | VMID | 变更前 | 变更后 | AVX2 |
|---|---|---|---|---|
| m01 | 119 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |
| master02 | 120 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |
| master01 | 121 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |
| worker01 | 122 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |
| worker02 | 123 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |
| worker03 | 124 | `x86-64-v2-AES` | `x86-64-v3` | ✅ |

验证命令：

```bash
ssh root@<node> 'grep -m1 flags /proc/cpuinfo | grep -o avx2'
```

6 台全部输出 `avx2`。集群 6 节点 Ready，无 Unbound PVC，无异常 Pod。

Ceph-CSI 驱动已切回标准镜像：

```
quay.io/cephcsi/cephcsi:v3.18.2
```

对应 Git 提交：

```
8b594be chore(ceph-csi): switch plugin image to standard v3.18.2 after CPU v3 migration
```

---

## 2. 前置检查

- 宿主 CPU 支持 v3 所需全部指令集。
- Proxmox `CPUConfig.pm` 中 `x86-64-v3` 的定义包含 `+aes`，因此不会丢失原有 AES 加速：

  ```
  'x86-64-v3' => {
      flags => "+aes;+popcnt;+pni;+sse4.1;+sse4.2;+ssse3;+avx;+avx2;+bmi1;+bmi2;+f16c;+fma;+abm;+movbe;+xsave",
  }
  ```

- Proxmox 为单机部署，无 corosync 集群，不存在跨主机迁移的 CPU 兼容性问题。
- 集群 etcd 3 节点健康，API Server 三副本可用。
- 已备份 Ceph-CSI 配置到 `/root/ceph-csi-backup-20261109/`。

---

## 3. 执行顺序

原则：**先 worker，后 control-plane；m01 最后**（kubeconfig 默认指向 `10.0.0.61:6443`，即 m01；m01 重启期间改用 VIP `10.0.0.168:6443`）。

### 3.1 通用步骤（每台）

```bash
# 1. 驱逐 Pod
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=600s

# 2. 优雅关机
qm shutdown <vmid> --timeout 120
# 等待 qm status <vmid> 变为 stopped

# 3. 修改 CPU 型号
qm set <vmid> --cpu x86-64-v3

# 4. 开机
qm start <vmid>
# 等待 qm status <vmid> 变为 running

# 5. 等待节点 Ready
kubectl wait --for=condition=Ready node/<node> --timeout=600s

# 6. 恢复调度
kubectl uncordon <node>
```

> 注意：CPU 型号不是热插拔，必须 **stop/start**，普通 `reboot` 不生效。

### 3.2 worker03（VM 124）

- 直接 drain → 关机 → 改 CPU → 开机 → uncordon。
- 验证 AVX2、CSI nodeplugin、CNI 正常。

### 3.3 worker01（VM 122）

worker01 上有 CNPG 主库 `pg16-ceph-3` 和 Kafka 单 broker，先做 CNPG 主从切换：

```bash
kubectl -n cnpg-system delete pod pg16-ceph-3
# 等待 primary 变为 pg16-ceph-4，cluster healthy
```

然后 drain → 关机 → 改 CPU → 开机 → uncordon。

### 3.4 worker02（VM 123）

worker02 上有 CNPG 新主库 `pg16-ceph-4`、Traefik、Prometheus、Loki 等：

```bash
kubectl -n cnpg-system delete pod pg16-ceph-4
# 等待 primary 变为 pg16-ceph-3，cluster healthy
```

然后 drain → 关机 → 改 CPU → 开机 → uncordon。

### 3.5 control-plane（master02 → master01 → m01）

- master02（VM 120）：drain → 关机 → 改 CPU → 开机 → uncordon。
- master01（VM 121）：同上。
- m01（VM 119）：最后处理。
  - 先准备临时 kubeconfig，指向 kube-vip VIP `10.0.0.168:6443`：

    ```bash
    cp /root/.kube/config /tmp/kubeconfig-v3
    kubectl --kubeconfig /tmp/kubeconfig-v3 config set-cluster kubernetes \
      --server=https://10.0.0.168:6443
    ```

  - 用临时 kubeconfig drain m01、等待节点 Ready、uncordon。
  - 完成后删除临时 kubeconfig。

m01 重启期间，kube-vip 会把 VIP 漂移到其他 control-plane 节点，kubectl 仍可用。

---

## 4. 过程中遇到的问题

### 4.1 worker01 镜像拉取慢 / Pod 卡在 ContainerCreating

worker 重启后，部分有状态 Pod 被调度到 worker01，但所需镜像只在 worker02 缓存，节点从 Docker Hub / quay.io 拉取很慢，Pod 长时间处于 `ContainerCreating` / `Init`。

处理方式：从 worker02 用 containerd 导出镜像，再导入 worker01：

```bash
# worker02 导出
ssh root@10.0.0.123 'ctr -n k8s.io images export /tmp/img.tar <image-ref>'
# 通过 Proxmox 宿主中转
scp root@10.0.0.123:/tmp/img.tar /tmp/img.tar
scp /tmp/img.tar root@10.0.0.122:/tmp/img.tar
# worker01 导入
ssh root@10.0.0.122 'ctr -n k8s.io images import /tmp/img.tar'
```

导入后删除卡住的 Pod，让控制器重建，Pod 即正常启动。

### 4.2 worker01 DiskPressure

worker01 磁盘一度达到 85%，kubelet 进入 `DiskPressure`，开始驱逐 Pod（包括 CSI nodeplugin），但 `crictl rmi --prune` 已释放空间后条件仍未消失（kubelet 缓存了旧状态）。

处理：

```bash
ssh root@10.0.0.122 'crictl rmi --prune'
# 磁盘从 46G 降到 25G（46%）
ssh root@10.0.0.122 'systemctl restart kubelet'
```

kubelet 重启后 `DiskPressure=False`，CSI nodeplugin 重新调度成功。

> 后续建议：给 worker 节点的 `/var/lib/containerd` 和容器日志做定期清理，避免再次触发 DiskPressure。

### 4.3 CNPG 两次 failover

- worker01 前：`pg16-ceph-3 → pg16-ceph-4`
- worker02 前：`pg16-ceph-4 → pg16-ceph-3`

每次 failover 后等待 `Cluster in healthy state` 且 `ready=2/2` 再继续。最终 CNPG 集群健康。

### 4.4 短暂 API Server 连接失败

master01 刚重启时，临时 kubeconfig 指到 `10.0.0.121:6443` 曾短暂 connection refused；稍后恢复。最终改用 kube-vip VIP `10.0.0.168:6443`，更稳定。

---

## 5. 最终验证

```bash
# 6 节点 Ready
kubectl get nodes

# 6 节点均包含 avx2
for ip in 10.0.0.61 10.0.0.120 10.0.0.121 10.0.0.122 10.0.0.123 10.0.0.124; do
  printf "%s: " "$ip"
  ssh root@$ip 'grep -m1 flags /proc/cpuinfo | grep -o avx2'
done

# 无异常 Pod、无 Unbound PVC
kubectl get pods -A | grep -v -E 'Running|Completed'
kubectl get pvc -A | grep -v Bound

# Ceph-CSI 标准镜像
kubectl -n ceph-csi-rbd get ds,deploy -o wide
# images: quay.io/cephcsi/cephcsi:v3.18.2

# ArgoCD
kubectl -n argocd get applications | grep -E 'ceph-csi|traefik|app-of-apps'
```

动态 provisioning 测试通过：新建 PVC → Bound → Pod 挂载 → 写入/读取 `csi-ok` → 清理。

---

## 6. 回滚

如需回退 CPU 型号：

```bash
qm shutdown <vmid>
qm set <vmid> --cpu x86-64-v2-AES
qm start <vmid>
```

然后同样 drain/uncordon。注意：

- 回退后标准 `v3.18.2` 镜像会再次因 x86-64-v3 要求失败，需要把 Ceph-CSI imageSet 切回 `v3.18.2-rocky9`。
- 回退同样需要逐台 stop/start + 维护窗口。

---

## 7. 备注

- `x86-64-v3` 已包含 AES（Proxmox CPUConfig 定义），不会丢失原有 AES 加速。
- 单机 Proxmox 没有跨主机 CPU 迁移问题；如果未来加入其他 Proxmox 主机，建议统一使用 `x86-64-v3` baseline。
- 使用 `x86-64-v3` 而不是 `host`，避免暴露宿主全部特性、也便于未来迁移。
- 节点重启会驱逐 Pod；对 CNPG、Kafka、Prometheus/Loki 等有状态负载，建议始终在维护窗口执行，并提前确认副本/备份。
