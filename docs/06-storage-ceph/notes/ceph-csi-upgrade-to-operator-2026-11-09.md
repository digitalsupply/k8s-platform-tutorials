# Ceph-CSI RBD 分阶段升级与 Operator 迁移（GitOps）

- **日期**：2026-11-09
- **集群**：`kubernetes-admin@kubernetes`（Kubernetes v1.35.9）
- **Ceph**：外部 Ceph **20.2.0 Tentacle**（mon: `10.0.0.31/41/51:6789`）
- **范围**：`ceph-csi-rbd`、`ceph-csi-operator-system`、ArgoCD
- **目标**：从 Helm 3.16.2 分阶段升级到 3.18.2，再迁移到 Ceph-CSI-Operator，全部纳入 GitOps。

---

## 0. 最终状态

| 项目 | 状态 |
|---|---|
| 部署方式 | **Ceph-CSI-Operator 1.1.0**（Helm chart，由 ArgoCD 管理） |
| 驱动 | RBD only（`rbd.csi.ceph.com`） |
| 驱动镜像 | `quay.io/cephcsi/cephcsi:v3.18.2`（CPU 已升级到 x86-64-v3，见 CPU 迁移文档） |
| Sidecar | provisioner `v6.3.0`、attacher `v4.13.0`、resizer `v2.2.1`、registrar `v2.18.0` |
| NodePlugin | `rbd.csi.ceph.com-nodeplugin`，3/3 Ready（每 worker 一个） |
| ControllerPlugin | `rbd.csi.ceph.com-ctrlplugin`，1/1 Ready |
| ArgoCD `platform-ceph-csi` | Synced / Healthy（仅管理 StorageClass + SealedSecret） |
| ArgoCD `platform-ceph-csi-operator` | Synced / Healthy |
| ArgoCD `platform-ceph-csi-drivers` | Synced / Healthy |
| `helm list -n ceph-csi-rbd` | 空（旧 Helm release 已卸载） |
| StorageClass `ceph-rbd-sc` | 不变（`Retain`，`clusterID = 594e535e-...`） |
| Secret `csi-rbd-secret` | 保留在 `ceph-csi-rbd`，由 SealedSecret 管理 |
| 现有 PVC | 17/17 Bound |
| 动态 provisioning 测试 | 通过（写入/读取 `csi-ok`，测试卷已清理） |

---

## 1. 为什么要升级

1. **支持窗口**：Ceph-CSI 只支持最近两个 minor（N / N-1）。当前最新 3.18.2，支持 3.17 / 3.18，**3.16 已 EOL**。
2. **Helm chart 生命周期**：官方从 3.16+ 起推荐 Ceph-CSI-Operator；**Helm chart 在 3.18 弃用，3.19 移除**。
3. **Sidecar 与 bugfix**：3.17/3.18 更新了 CSI sidecar，并包含多项修复。
4. **不能跳版本**：上游明确不建议 3.16 直接到 3.18，必须 3.16 → 3.17 → 3.18。

---

## 2. 分阶段执行

### Phase 0：前置检查与备份

- 所有节点 Ready，`/readyz` 正常；无 Pending Pod、无 Unbound PVC。
- etcd 备份 CronJob（`etcd-backup/etcd-snapshot`）每小时执行，最近一次成功。
- CNPG `pg16-ceph` 健康，存在最近的 successful backup；2026-11-09 02:00 的 daily full 因 barman-cloud plugin 报错失败（**独立问题**，未阻塞本次升级）。
- 备份当前 CSI 配置到 `/root/ceph-csi-backup-20261109/`：
  - `rbac-workloads-cm.yaml`
  - `csidriver.yaml`
  - `storageclass.yaml`
- 在 worker01/02/03 预拉取所有目标镜像。

### Phase 1：以 3.16.2 原版本纳入 GitOps

新增：

```
platform/ceph-csi/values.yaml                     # 从 live Helm release 导出
platform/ceph-csi/resources/storageclass.yaml     # 原手工创建的 ceph-rbd-sc
platform/ceph-csi/resources/sealedsecret-csi-rbd-secret.yaml
clusters/prod/applications/platform-ceph-csi.yaml
```

要点：

- ArgoCD Helm source 使用 `releaseName: ceph-csi-rbd`，平滑接管原 release。
- chart 本身不管理 StorageClass 和 Secret（`storageClass.create=false`、`secret.create=false`），因此单独放在 resources source。
- `csi-rbd-secret` 通过 kubeseal 转为 SealedSecret，并给 live Secret 加：
  `sealedsecrets.bitnami.com/managed=true`，由 sealed-secrets controller 接管。
- 纳管后验证：PVC 全部 Bound，动态 provisioning 测试通过。

### Phase 2：3.16.2 → 3.17.2

- 更新 values 中所有 image tag 到 3.17.2 对应版本：
  - cephcsi `v3.17.2`
  - registrar `v2.16.0`
  - provisioner `v6.2.0`
  - attacher `v4.11.0`
  - resizer `v2.1.0`
  - snapshotter `v8.5.0`
- 更新 Application `targetRevision: 3.17.2`。
- 预拉镜像后同步；NodePlugin 逐节点滚动，ControllerPlugin 重启。
- 验证：`vendor_version=v3.17.2`，动态 provisioning 测试通过，PVC/关键负载正常。

### Phase 3：3.17.2 → 3.18.2（遇到 CPU 兼容性问题）

- 更新 values 到 3.18.2 默认版本：
  - cephcsi `v3.18.2`
  - registrar `v2.18.0`
  - provisioner `v6.3.0`
  - attacher `v4.13.0`
  - resizer `v2.2.1`
  - snapshotter `v8.6.0`
- 首次同步后 **CrashLoopBackOff**，日志：

  ```
  Fatal glibc error: CPU does not support x86-64-v3
  ```

- 节点 CPU 为 `QEMU Virtual CPU version 2.5+`，没有 AVX/AVX2 等 x86-64-v3 指令集。
- 临时解决：Ceph-CSI 官方为 v2 CPU 提供 Rocky Linux 9 构建，tag 后缀 `-rocky9`：
  - `quay.io/cephcsi/cephcsi:v3.18.2-rocky9`
- 更新 values 后同步，所有 Pod 正常，`vendor_version=v3.18.2-rocky9`，动态 provisioning 测试通过。
- **后续**：已把 6 台节点的 VM CPU 从 `x86-64-v2-AES` 改为 `x86-64-v3`，并切回标准镜像 `v3.18.2`；详见
  `k8s-cpu-v3-migration-2026-11-09.md`。

### Phase 4：迁移到 Ceph-CSI-Operator

#### 4.1 安装 Operator

新增 `clusters/prod/applications/platform-ceph-csi-operator.yaml`：

- chart：`ceph-csi-operator` 1.1.0
- namespace：`ceph-csi-operator-system`
- **关键配置**：`controllerManager.manager.env.watchNamespace: ceph-csi-rbd`
  - 初始渲染路径写错为 `controllerManager.env`，导致 Operator 只 watch 自己的 namespace，Driver 不生效；
  - 修正为 `controllerManager.manager.env` 后，Operator 正常 watch `ceph-csi-rbd`。

#### 4.2 拆分 config 与 driver

- 将 `platform-ceph-csi` Application 改为 **只管理** `platform/ceph-csi/resources/`（StorageClass + SealedSecret），移除 Helm chart source。
- 确认 app Synced 后执行：

  ```bash
  helm uninstall ceph-csi-rbd -n ceph-csi-rbd
  ```

- 该操作删除旧的 DaemonSet/Deployment/RBAC/ConfigMap/CSIDriver；StorageClass 和 Secret 不属于 Helm release，保留。
- 迁移窗口内：已挂载的 RBD 卷继续工作；新建 PVC/新挂载会失败。实际窗口约 1 分钟。

#### 4.3 部署 Operator 驱动

新增：

```
platform/ceph-csi/drivers-values.yaml
platform/ceph-csi/drivers-resources/imageset.yaml
clusters/prod/applications/platform-ceph-csi-drivers.yaml
```

- chart：`ceph-csi-drivers` 1.1.0
- namespace：`ceph-csi-rbd`
- 只启用 RBD，禁用 CephFS / NVMe-oF / NFS。
- `CephConnection` monitors：`10.0.0.31/41/51:6789`
- `ClientProfile` 名称 = 原 StorageClass 的 `clusterID`：
  `594e535e-d82c-11f0-afa7-bc24112b746f`
  - 这是 Operator 迁移的关键：StorageClass 的 `clusterID` 必须与 ClientProfile 名称一致，现有 StorageClass 无需修改。
- ClientProfile 的 RBD secret 仍指向 `ceph-csi-rbd/csi-rbd-secret`，与现有 PV 的不可变 secret 引用保持一致。
- 通过 imageSet ConfigMap 固定镜像版本；早期临时使用 rocky9 plugin，CPU 升级到 v3 后已切回标准 `v3.18.2`。

#### 4.4 迁移中遇到的问题

| 问题 | 现象 | 解决 |
|---|---|---|
| 3.18.2 镜像要求 x86-64-v3 | `Fatal glibc error: CPU does not support x86-64-v3` | 先用 `v3.18.2-rocky9` 过渡；随后把 VM CPU 改为 `x86-64-v3`，切回标准 `v3.18.2` |
| Operator 只 watch 自己 namespace | Driver CR 存在但无驱动 Pod | 设置 `controllerManager.manager.env.watchNamespace=ceph-csi-rbd` |
| Operator 首次 reconcile 冲突 | `the object has been modified; please apply your changes to the latest version` | 下一轮 reconcile 自动恢复，无需人工处理 |
| ArgoCD 首次同步 Operator `DeadlineExceeded` | ComparisonError | 重试后成功，属于瞬时问题 |

---

## 3. 最终 GitOps 结构

```
platform/ceph-csi/
├── drivers-values.yaml                  # ceph-csi-drivers chart values
├── drivers-resources/
│   └── imageset.yaml                    # rbd-csi-images ConfigMap
└── resources/
    ├── storageclass.yaml                # ceph-rbd-sc
    └── sealedsecret-csi-rbd-secret.yaml # csi-rbd-secret

clusters/prod/applications/
├── platform-ceph-csi.yaml               # StorageClass + SealedSecret
├── platform-ceph-csi-operator.yaml      # Operator chart
└── platform-ceph-csi-drivers.yaml       # Driver/CephConnection/ClientProfile/RBAC
```

职责划分：

| Application | 管理内容 |
|---|---|
| `platform-ceph-csi` | StorageClass、SealedSecret（以及由 sealed-secrets 生成的 Secret） |
| `platform-ceph-csi-operator` | Operator Deployment、CRD、Operator RBAC |
| `platform-ceph-csi-drivers` | Driver、CephConnection、ClientProfile、驱动 RBAC、imageSet ConfigMap |

---

## 4. Git 提交

| Commit | 内容 |
|---|---|
| `668b388` | onboarding ceph-csi-rbd 3.16.2 到 ArgoCD |
| `dc78387` | 3.16.2 → 3.17.2 |
| `d2f04d2` | 3.17.2 → 3.18.2 |
| `680f27d` | 3.18.2 使用 rocky9 镜像（x86-64-v2） |
| `ebd58a1` | 添加 ceph-csi-operator 1.1.0 |
| `93085b3` | `platform-ceph-csi` 缩减为 StorageClass/Secret |
| `c9cc0c7` | 添加 ceph-csi-drivers（Operator 驱动） |
| `cf62e4a` | 修正 operator watch namespace（第一次） |
| `fed4b38` | 修正 `controllerManager.manager.env.watchNamespace` 路径 |
| `047517a` | 删除旧 Helm values |

---

## 5. 验证结果

### 5.1 ArgoCD

```
NAME                         SYNC STATUS   HEALTH STATUS
app-of-apps                  Synced        Healthy
platform-ceph-csi            Synced        Healthy
platform-ceph-csi-drivers    Synced        Healthy
platform-ceph-csi-operator   Synced        Healthy
```

### 5.2 驱动

```
daemonset/rbd.csi.ceph.com-nodeplugin    3/3 Ready
deployment/rbd.csi.ceph.com-ctrlplugin   1/1 Ready

pod/rbd.csi.ceph.com-nodeplugin-qmsj2   3/3 Running   worker01
pod/rbd.csi.ceph.com-nodeplugin-gfldv   3/3 Running   worker02
pod/rbd.csi.ceph.com-nodeplugin-7hjdh   3/3 Running   worker03
pod/rbd.csi.ceph.com-ctrlplugin-...     5/5 Running   worker02
```

### 5.3 存储

- `kubectl get pvc -A`：17/17 Bound。
- 动态 provisioning 测试：新建 PVC → Bound → Pod 挂载 → 写入/读取 `csi-ok` → 清理，全部通过。
- 关键负载持续运行：CNPG `pg16-ceph`、Kafka、Loki、Prometheus 等。
- StorageClass 保持不变：

```
provisioner=rbd.csi.ceph.com
reclaimPolicy=Retain
allowVolumeExpansion=true
clusterID=594e535e-d82c-11f0-afa7-bc24112b746f
```

- Secret 仍由 SealedSecret 管理，ownerReference 正确。

---

## 6. 回滚方案

### 6.1 回滚 Operator 驱动到 Helm 3.18.2

1. 删除 drivers Application（或把 `drivers.rbd.enabled` 设为 false 后同步）。
2. 删除 Driver / CephConnection / ClientProfile：

   ```bash
   kubectl -n ceph-csi-rbd delete driver rbd.csi.ceph.com
   kubectl -n ceph-csi-rbd delete clientprofile 594e535e-d82c-11f0-afa7-bc24112b746f
   kubectl -n ceph-csi-rbd delete cephconnection ceph-connection
   ```

3. 从 Git 历史恢复旧 Helm values（commit `680f27d` 的 `platform/ceph-csi/values.yaml`）。
4. 重新安装 Helm release：

   ```bash
   helm install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
     --version 3.18.2 -n ceph-csi-rbd \
     -f <restored-values.yaml>
   ```

5. 如 CSIDriver/RBAC 未恢复，可用 `/root/ceph-csi-backup-20261109/` 中的备份恢复。

### 6.2 注意事项

- 现有 PV 的 `nodeStageSecretRef` / `controllerExpandSecretRef` 不可变，`csi-rbd-secret` **必须继续保留在 `ceph-csi-rbd`**。
- 迁移/回滚窗口内，已挂载卷不受影响；新建 PVC / 新挂载会失败。
- StorageClass 的 `clusterID` 与 ClientProfile 名称绑定；如果改回 Helm，StorageClass 不需要改，但 Helm 的 `csiConfig` 需要包含同一个 clusterID。

---

## 7. 后续建议

1. **排查 nodeplugin 的 API Server 超时**
   升级前旧 nodeplugin 存在多次重启，日志为：

   ```
   Get "https://10.96.0.1:443/api/v1/nodes/worker02": dial tcp 10.96.0.1:443: i/o timeout
   ```

   这是节点到 API Server 的连通性问题，不是 Ceph 问题，本次升级不会自动修复。建议单独排查 kube-proxy/Cilium/控制面网络。

2. **CNPG daily backup 失败**
   `pg16-ceph-daily-full-20261109020000` 因 barman-cloud plugin 报错失败；存在最近的成功备份，但建议尽快修复并验证恢复流程。

3. **Operator 升级**
   后续升级只需更新 `platform-ceph-csi-operator` 的 chart 版本和 `rbd-csi-images` 中的镜像，不再使用 Ceph-CSI Helm chart。

4. **快照能力**
   当前未安装 VolumeSnapshot CRD/Controller；如果以后需要 PVC 快照，需要单独部署 snapshot-controller 和 VolumeSnapshotClass。

5. **客户端兼容性**
   3.17.1+ 的 AES256 key 支持需要 Linux kernel 7.0+；当前节点内核 5.14/5.15，如果 Ceph 集群使用 AES256 key 格式需另行评估。

---

## 8. 关键验证命令

```bash
kubectl -n argocd get applications | grep ceph-csi
helm list -n ceph-csi-rbd

kubectl -n ceph-csi-rbd get driver,cephconnection,clientprofile
kubectl -n ceph-csi-rbd get ds,deploy,pods -o wide

kubectl get csidriver rbd.csi.ceph.com -o yaml
kubectl get pvc -A | grep -v Bound

kubectl -n ceph-csi-rbd get sealedsecret csi-rbd-secret -o yaml
kubectl -n ceph-csi-rbd get secret csi-rbd-secret -o jsonpath='{.metadata.ownerReferences}'
```

---

## 9. 遗留问题复查（2026-11-09）

### 9.1 CNPG daily backup 失败

- 现象：`pg16-ceph-daily-full-20261109020000` 在 02:00 以 `plugin` 方式失败，错误 `rpc error: exit status 1`。
- 复查：
  - CNPG 集群健康，primary `pg16-ceph-3`，ready 2/2。
  - WAL archive/restore 正常，S3/RGW endpoint `10.0.0.31:7480` 可访问。
  - 手动备份 `pg16-ceph-check-20261109`（method: plugin）**completed**，在 standby `pg16-ceph-4` 上执行。
- 结论：02:00 失败是瞬时问题（插件/实例状态切换期间），插件本身可用。
- 注意：`status.lastSuccessfulBackup` 仍显示 `2026-11-08T10:19:32Z`，因为手动 Backup CR 没有 ownerReference；下一次 ScheduledBackup（11-10 02:00）成功后会更新。
- 后续：观察 11-10 02:00 的 daily full；若再次失败，检查 `pg16-ceph-*` 的 `plugin-barman-cloud` sidecar 日志和 S3 凭据。

### 9.2 CSI nodeplugin 的 API Server 超时

- 现象（升级前）：nodeplugin 日志出现 `10.96.0.1:443 i/o timeout`，导致容器重启。
- 复查（CPU v3 切换后）：
  - 当前 nodeplugin Pod 0 restarts，近 2h 无 `10.96.0.1:443`/i/o timeout。
  - 三个 worker 访问 `https://10.96.0.1:443/healthz` 均返回 200，耗时 15–37ms。
  - 仍观察到 barman-cloud leader election 在 12:50 出现一次 `10.96.0.1:443` timeout，说明底层偶发问题未完全消失。
- 结论：目前不影响 CSI；建议继续观察，若复发再排查 Cilium/kube-proxy/控制面网络。

### 9.3 worker 磁盘 / ImageGC

- worker03：43G → 25G（45%），已无 DiskPressure。
- worker02：34G → 17G（30%），已无 DiskPressure。
- worker01：26G（47%），无 DiskPressure。
- 历史 `ImageGCFailed` 事件是清理前的；当前所有节点 `DiskPressure=False`。
- 建议：给 worker 的 containerd 镜像和容器日志加定期清理。

### 9.4 快照 CRD

- `VolumeSnapshot`/`VolumeGroupSnapshot` CRD 仍未安装；如果不需要 PVC 快照，保持现状即可。
