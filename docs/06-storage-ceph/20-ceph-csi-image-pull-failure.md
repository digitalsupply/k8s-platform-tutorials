# ceph-csi 镜像拉取失败导致 PG Pod 卡 Init 故障排查与修复

> 集群：Compassio k8s 平台（CNPG `pg16-ceph` + ceph-csi-rbd）。现象：`pg16-ceph-4` 卡在 `Init:0/2`，ceph-csi-rbd 的 ctrlplugin 处于 `ImagePullBackOff`。本文记录根因分析与修复过程。

## 一、问题现象

```bash
kubectl get pod -n cnpg-system -o wide
# pg16-ceph-4   0/2   Init:0/2   0   14h   <none>   worker02

kubectl get pod -n ceph-csi-rbd -o wide
# rbd.csi.ceph.com-ctrlplugin-748d7c6b54-snnh9   2/5   ImagePullBackOff   0   14h   worker01
```

两个现象时间点吻合（均 14h），高度关联。

## 二、根因分析

### 2.1 ctrlplugin 镜像拉取失败

`kubectl describe pod` 的事件明确指向镜像代理 403：

```
Failed to pull image "registry.k8s.io/sig-storage/csi-attacher:v4.13.0":
  failed to authorize: failed to fetch anonymous token:
  unexpected status from GET https://k8s.1ms.run/openapi/v1/auth/token...: 403 Forbidden
```

三个镜像全部拉取失败：

| 镜像 | 状态 |
| --- | --- |
| `registry.k8s.io/sig-storage/csi-attacher:v4.13.0` | ImagePullBackOff（403） |
| `registry.k8s.io/sig-storage/csi-provisioner:v6.3.0` | ImagePullBackOff（403） |
| `registry.k8s.io/sig-storage/csi-resizer:v2.2.1` | ImagePullBackOff（403） |
| `quay.io/cephcsi/cephcsi:v3.18.2` | 正常（有 Image ID） |

**根因**：`registry.k8s.io` 被 containerd 镜像加速配置重定向到 `k8s.1ms.run`，该代理对 `sig-storage/csi-*` 这几个镜像返回 **403 Forbidden**，导致 ctrlplugin 的三个 sidecar 容器无法启动。

### 2.2 PG Pod 卡 Init 的因果链

```
ctrlplugin ImagePullBackOff
  → csi-attacher 容器无法启动
    → attachdetach-controller 无法 attach 卷
      → pg16-ceph-4 的 PVC 无法挂载
        → init 容器（bootstrap-controller）无法完成
          → Pod 卡在 Init:0/2，IP 为 <none>
```

pg16-ceph-4 的 Events 佐证：

```
Warning FailedAttachVolume 3m4s (x439 over 14h) attachdetach-controller
  AttachVolume.Attach failed for volume "pvc-7787aabb-...": volume attachment is being deleted
```

`attachdetach-controller` 重试 439 次仍无法 attach 卷，因为 csi-attacher 没有运行。

### 2.3 镜像加速配置位置

```bash
# /etc/containerd/certs.d/registry.k8s.io/hosts.toml
server = "https://registry.k8s.io"

[host."https://k8s.1ms.run"]
  capabilities = ["pull", "resolve"]
```

`k8s.1ms.run` 是镜像加速代理，对部分镜像正常，但对 `sig-storage/csi-*` 返回 403。

## 三、镜像源可用性测试

修复前先验证各镜像源对 csi 镜像的可达性：

```bash
for src in k8s.1ms.run k8s.m.daocloud.io registry.k8s.io; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "https://$src/v2/sig-storage/csi-attacher/manifests/v4.13.0")
  echo "$src -> HTTP $code"
done
```

结果：

| 镜像源 | 状态 | 说明 |
| --- | --- | --- |
| `k8s.1ms.run` | 401 | 当前配置的代理，对 csi 镜像 403（实际拉取失败） |
| `k8s.m.daocloud.io` | 401 | DaoCloud 镜像源，可达 |
| `registry.k8s.io` | 307 | 官方源，可达（需 token，307 为认证重定向） |

## 四、修复方案

### 方案 A：更换镜像加速代理（推荐）

将 `k8s.1ms.run` 替换为可用的镜像源，修改 containerd 的 hosts.toml：

```bash
# 1. 备份原配置
cp /etc/containerd/certs.d/registry.k8s.io/hosts.toml /etc/containerd/certs.d/registry.k8s.io/hosts.toml.bak

# 2. 修改为可用镜像源（示例用 daocloud，按测试结果选择）
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# 3. 重启 containerd（影响该节点所有 Pod，需在维护窗口操作）
systemctl restart containerd

# 4. 删除 ctrlplugin Pod，触发重建拉取新镜像
kubectl -n ceph-csi-rbd delete pod -l app=rbd.csi.ceph.com-ctrlplugin
```

> 注意：重启 containerd 会重启该节点上的 Pod，需评估影响。如仅 ctrlplugin 需要修复，可只删除该 Pod，kubelet 会用新配置重新拉取。

### 方案 B：使用 docker.aityp.com 直接拉取（非加速）

`docker.aityp.com` 提供镜像直下载，但**不是加速代理**，需直接 pull：

```bash
# 在节点上直接从 aityp 拉取镜像并打本地 tag
ctr -n k8s.io images pull docker.aityp.com/sig-storage/csi-attacher:v4.13.0
ctr -n k8s.io images tag docker.aityp.com/sig-storage/csi-attacher:v4.13.0 \
  registry.k8s.io/sig-storage/csi-attacher:v4.13.0

# 同理拉取 csi-provisioner、csi-resizer
ctr -n k8s.io images pull docker.aityp.com/sig-storage/csi-provisioner:v6.3.0
ctr -n k8s.io images tag docker.aityp.com/sig-storage/csi-provisioner:v6.3.0 \
  registry.k8s.io/sig-storage/csi-provisioner:v6.3.0

ctr -n k8s.io images pull docker.aityp.com/sig-storage/csi-resizer:v2.2.1
ctr -n k8s.io images tag docker.aityp.com/sig-storage/csi-resizer:v2.2.1 \
  registry.k8s.io/sig-storage/csi-resizer:v2.2.1

# 删除 ctrlplugin Pod，用本地镜像重建
kubectl -n ceph-csi-rbd delete pod -l app=rbd.csi.ceph.com-ctrlplugin
```

> 此方案不改 containerd 全局配置，仅预拉取到本地，影响面更小，适合临时修复。

## 五、验证修复

```bash
# 1. 确认 ctrlplugin 重新拉取镜像并启动
kubectl -n ceph-csi-rbd get pod
# 期望：ctrlplugin 状态 Running，无 ImagePullBackOff

# 2. 确认 pg16-ceph-4 卷挂载成功，init 容器完成
kubectl -n cnpg-system get pod pg16-ceph-4
# 期望：2/2 Running

# 3. 确认集群恢复
kubectl -n cnpg-system get cluster pg16-ceph
# 期望：Cluster in healthy state，两个实例 Ready
```

## 六、Headlamp 中的对应报错

Headlamp 是 k8s Web UI，报错与 kubectl 等价：

- **ctrlplugin Pod**：状态显示 `ImagePullBackOff`，事件区显示 `Failed to pull image ... 403 Forbidden`；
- **pg16-ceph-4**：状态显示 `Init:0/2`，事件区显示 `FailedAttachVolume ... volume attachment is being deleted`；
- 在 Headlamp 中可直接点击 Pod 的 Events 查看完整错误，与 `kubectl describe pod` 输出一致。

## 七、总结

| 项 | 内容 |
| --- | --- |
| **根因** | 镜像加速代理 `k8s.1ms.run` 对 `registry.k8s.io/sig-storage/csi-*` 返回 403 |
| **影响链** | ctrlplugin 镜像拉失败 → csi-attacher 不运行 → 卷无法 attach → PG Pod 卡 init |
| **修复** | 换可用镜像源（方案 A）或用 docker.aityp.com 直拉（方案 B），重建 ctrlplugin |
| **验证** | ctrlplugin Running、PG Pod 2/2、集群 healthy |

> 建议长期方案：统一镜像加速配置，为 `registry.k8s.io` 配置多个可用 mirror，避免单一代理故障导致存储插件不可用；关键镜像预拉取到节点本地作为兜底。
