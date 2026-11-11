# 06 · Storage / Ceph：RBD、PV 回收、备份与对象存储

## 当时的情况

存储层是**集群外部的 Ceph 集群**：

| 项 | 值 |
|---|---|
| Ceph | Reef `18.2.8`，3 台 VM（ceph-01/02/03），6 个 OSD，465 PG |
| 健康 | `HEALTH_OK`（多数时间），约 180 GiB 裸容量 |
| K8s 接入 | ceph-csi-rbd `3.16.2`，StorageClass `ceph-rbd-sc`（`Retain`） |
| 对象存储 | Ceph RGW（S3），Loki/Tempo/CNPG 备份共用 |
| 其他 | NFS StorageClass `nfs-sc`（自建 provisioner） |

当时暴露的问题：

1. **10 个 `Released` PV（95Gi）** 长期不回收，其中 9 个 Ceph RBD、1 个 NFS；
2. Ceph 侧还有 **2 个没有 PV 引用的僵尸镜像**（PV 被强删，RBD 镜像留下）；
3. PostgreSQL 看似“归档正常”，实际上 **没有任何可用备份**；
4. `pg16-ceph-2` 因 `pg_xact/0000` 被截断为 0 字节无限重启；
5. Tempo 写 RGW 持续 400 `XAmzContentSHA256Mismatch`；
6. ceph-csi nodeplugin 累计重启 69 次，`kubectl` 显示 Running、`crictl` 里却查不到容器。

2026-11-09 又做了两件存储层的大改造：

- **Ceph-CSI 从 Helm 3.16.2 分阶段升级到 3.18.2，再迁移到 Ceph-CSI-Operator 1.1.0**，三个 Application 全部纳入 ArgoCD；
- **CNPG 从 1.22.0 升到 1.30.1**，备份从内置 `barmanObjectStore` 迁到 Barman Cloud Plugin，PostgreSQL 镜像固定到 16.15；
- 期间还做了 **K8s 节点磁盘两轮清理**（旧镜像、已完成 Pod、kubelet GC、Harbor tag 保留、Tekton 历史、PVE discard/TRIM）。

## 主要概念与原理

### 1. Ceph 的三种接口

| 接口 | 用途 | K8s 场景 |
|---|---|---|
| **RBD**（块设备） | 给 Pod 当磁盘 | `ceph-rbd-sc` → PVC/PV |
| **CephFS**（文件系统） | 共享文件 | 本集群未用于 K8s |
| **RGW**（对象存储，S3 兼容） | 存对象 | Loki chunks、Tempo blocks、CNPG 备份 |

> 本集群没有 MinIO。早期把 RGW 误称为 “MinIO”，见
> [minio-vs-ceph-rgw-analysis.md](notes/minio-vs-ceph-rgw-analysis.md)。

### 2. PV / PVC / CSI 的关系

```text
PVC（命名空间内）──绑定──► PV（集群级）──► CSI volumeHandle ──► Ceph RBD image
```

- **Provisioner**：动态创建 RBD image 和 PV；
- **Attacher**：把卷 attach 到节点；
- **Nodeplugin**：在节点上 map/unmap RBD、挂载文件系统；
- **reclaimPolicy=Retain**：PVC 删除后，PV 保留为 `Released`，RBD image 也保留。

### 3. `Released` 是怎么产生的

1. StatefulSet 删 Pod/PVC（升级、迁移、误删）；
2. PVC 被删除，PV 进入 `Released`；
3. StatefulSet 重建同名 PVC，**新 PVC 的 UID 与旧 PV 的 `claimRef.uid` 不一致**；
4. Kubernetes 不会把旧 PV 重新绑定给新 PVC（UID 不匹配），旧 PV 永远停在 `Released`。

所以“同名 PVC 存在”不代表旧 PV 还能用。判断孤儿必须比对 **UID**，不能只看名字。

### 4. CNPG 的备份：WAL 归档 ≠ 基础备份

- **WAL 归档**：持续把 WAL 送到对象存储，用于 PITR；
- **基础备份**：`Backup` / `ScheduledBackup` 产生 base backup；
- `barmanObjectStore` 声明备份目的地（S3 endpoint、bucket、凭据、压缩、并发）。

只有 WAL 没有 base backup，无法恢复；只有 base backup 没有 WAL，只能恢复到备份时刻。

### 5. RBD image 的“声明容量”和“实际占用”

RBD 是 thin provisioning：PVC 声明 10Gi，不代表 Ceph 实际用了 10Gi。
`rbd du` 才是实际占用；清理前要同时看 `watchers`（是否有客户端映射）和文件系统内容。

### 6. Operator 模式：CRD + controller + reconcile

Ceph-CSI Operator 和 CNPG 都是同一套模式：

```text
CRD（自定义 API）
  + controller 进程（watch CR）
  + reconcile 循环：期望状态 vs 实际状态 → 创建/更新/删除子资源
  + status/conditions 回写
```

它不是“安装脚本”，而是**长期运行的控制器**。因此：

- 升级 Operator 不等于升级 CRD，也不等于升级它管理的驱动/实例；
- CR 里写的是期望状态，Pod/Service/PVC 是 Operator 生成的；
- 调试时先看 CR 的 `status.conditions`，再看 Operator 日志和子资源事件。

### 7. Ceph-CSI Operator 的分层

本集群拆成三个 ArgoCD Application：

| Application | 内容 |
|---|---|
| `platform-ceph-csi-operator` | Operator CRD + Deployment + RBAC |
| `platform-ceph-csi-drivers` | `Driver`、`CephConnection`、`ClientProfile`、驱动 RBAC/ConfigMap |
| `platform-ceph-csi` | StorageClass `ceph-rbd-sc` + SealedSecret |

关键 CR：

- `CephConnection`：mon 地址、认证引用；
- `ClientProfile`：集群 ID、pool、secret 引用；
- `Driver`：驱动类型（rbd）、镜像、sidecar 版本、nodeplugin/ctrlplugin 规格；
- `OperatorConfig`：全局默认值（本集群未创建）。

> `helm list -n ceph-csi-rbd` 为空是正常的：Helm release 已卸载，驱动由 Operator 根据 CR 生成。

### 8. CNPG：Operator + Instance Manager + Plugin

- **Operator**：管集群级决策（实例数、主从、Service、PVC、备份、升级）；
- **Instance Manager**：每个 PostgreSQL Pod 内的 sidecar，负责启动/停止/检查数据库进程；
- **Plugin**：扩展备份等能力，本集群用 `plugin-barman-cloud` 0.15.1 对接 S3。

CNPG 的 `Cluster` CR 不是“一个 StatefulSet 的别名”，它还会生成：

- 主/备 Service（`-rw`、`-ro`、`-r`）；
- 每个实例的 PVC；
- PDB、Lease、Secret、证书；
- `ScheduledBackup` / `Backup` 对象和 WAL 归档配置。

### 9. 磁盘为什么会被镜像吃满

- CI 每次构建产生新 tag，Harbor 和历史镜像持续增长；
- kubelet 默认 `imageGCHighThresholdPercent=85`，不到 85% 不 GC；
- 已完成 Pod 仍引用镜像，`crictl rmi --prune` 也删不掉；
- PVE thin pool 需要 VM 开启 `discard=on` + 周期性 `fstrim` 才能把空间还给宿主机。

## 踩坑点

### 坑 1：`Retain` + StatefulSet 重建 = 孤儿 PV

Loki 的 `data-loki-backend-0` 多次重建，留下 6 个旧 PV，claimRef 都是旧 UID。
它们**永远不会被回收**，也不会自动重新绑定。

**修复**：确认 `Released` + claimRef PVC 不存在/UID 不一致 + `watchers=none` 后，
先删 PV，再删 Ceph RBD image。顺序反了会泄漏。

### 坑 2：只删 PV 不删 RBD，镜像永久泄漏

PV 只是 Kubernetes 对象，删 PV 不会自动删 RBD image（`Retain` 的语义就是保留）。
本集群发现 2 个“PV 已不存在但镜像还在”的僵尸卷，合计约 1.48GiB。

**修复**：建立“PV → volumeHandle → RBD image”的对照表，清理时两边都核销。

### 坑 3：把 `Released` PV 当成“还能恢复”

`Released` 意味着 PVC 已删除，PV 不会自动回到 `Available`。
如果里面还有数据，只能手工创建新 PVC + 静态绑定（改 claimRef），不能指望它自己恢复。

### 坑 4：PostgreSQL “归档成功”是假象

CNPG 的 `ContinuousArchiving=True`、`archived_count=702`、`failed_count=0`，
但日志实际是 `Backup not configured, skip WAL archiving`。

原因：`archive_command` 被调用后正常退出（返回 0），PostgreSQL 就累加成功计数；
CNPG 看到命令成功，也把条件置为 True。**但一个字节都没写出去。**

**修复**：检查 `spec.backup` 是否为 null、`kubectl get backup,scheduledbackup` 是否为空、
对象存储里是否真的有 base backup 和 WAL。不要只信 condition。

### 坑 5：`pg_xact/0000` 为 0 字节导致无限重启

PostgreSQL 启动时读事务 3047 的状态失败：

```text
invalid record length at 1/A30000A0: expected at least 24, got 0
could not access status of transaction 3047
startup process exited with exit code 1
```

对照健康实例，`pg_xact/0000` 应该是 8192 字节。

**修复**：先归档/保留现场，再删除故障实例的 PVC，让 CNPG 从主库重新克隆；
不要在原卷上反复 `initdb`。

### 坑 6：Tempo 写 RGW 失败，先怀疑客户端是错的

minio-go 写 0 字节 aws-chunked 终止块，RGW 17.2.8 把 seed 签名当终止块签名比对，
必然 400。做了兼容层代理也没接流量，最后升级 RGW 到 18.2.8 才根治。

**教训**：对象存储的签名兼容问题，要用 pcap/服务端日志证明，不要只凭客户端报错。

### 坑 7：csi nodeplugin 重启是 kubelet/containerd 状态不一致

升级时重启了 kubelet，但 containerd 一直运行。kubelet 从 API 恢复 Pod 列表，
CRI 侧却没有对应容器，日志出现 `Missing actuated resource record`：

- `kubectl get pod` → Running，重启 69 次；
- `crictl ps -a` → 查无此容器。

**修复**：重启对应节点的 kubelet/containerd，让 CRI 与 API 状态重新对齐；
必要时删除异常 Pod 让其重建。根治要避免“只重启 kubelet 不重启 containerd”的升级操作。

### 坑 8：NFS provisioner 已停止维护

`nfs-subdir-external-provisioner` 最后一版是 2023-03，无维护、有已知漏洞。
本集群仍有 `nfs-sc` 在用，建议迁移到 `csi-driver-nfs`。

### 坑 9：`WATCH_NAMESPACE` 只 watch 一个命名空间

Ceph-CSI Operator 的 Deployment 通过 `WATCH_NAMESPACE` 限定监听范围。
如果 Operator 在 `ceph-csi-operator-system`，Driver CR 却在 `ceph-csi-rbd`，
而 `WATCH_NAMESPACE` 只写了前者，Operator 会“看起来正常但不 reconcile”。

**修复**：让 `WATCH_NAMESPACE` 覆盖 CR 所在命名空间，或留空监听全集群；
改完后重启 Operator，确认日志出现对应 CR 的 reconcile。

### 坑 10：Helm release 残留会与 ArgoCD 争管

Traefik/Ceph-CSI 都出现过：资源已被 ArgoCD 接管，但 `sh.helm.release.v1.*` 还在。
`helm list` 显示旧版本，运维一执行 `helm upgrade` 就会覆盖 GitOps 管理的资源。

**修复**：确认 ArgoCD `Synced/Healthy` 后，只删 Helm release secret（不碰运行资源）：

```bash
kubectl -n ceph-csi-rbd delete secret -l owner=helm
```

### 坑 11：标准 Ceph-CSI 镜像要求 x86-64-v3

Ceph-CSI 3.18.2 的官方镜像包含 AVX2 等指令集。节点 CPU 还是 `x86-64-v2-AES` 时，
容器会直接 `SIGILL`（Illegal instruction），表现是 CrashLoop 而不是普通报错。

**修复**：两条路二选一：

1. 用兼容构建（如 `-rocky9` 镜像）临时过渡；
2. 把 PVE VM CPU 型号改为 `x86-64-v3`（必须 stop/start，reboot 不生效），再切回标准镜像。
   本集群最终选 2，见 [01 CPU v3 迁移](../01-kubernetes-k3s/notes/cpu-v3-migration-2026-11-09.md)。

### 坑 12：浮动镜像 tag 让“升级”不可复现

CNPG 曾使用浮动的 PostgreSQL tag，重新拉取就可能换版本；Ceph-CSI 也出现过
`latest`/`stable` 与实际版本不一致。**升级记录里必须写镜像 digest 或固定 tag。**

**修复**：所有生产 CR 固定到 `16.15`、`v3.18.2` 这类不可变版本；
用 `imagePullPolicy: IfNotPresent` + 预拉取，避免节点重启时被动升级。

### 坑 13：`rp_filter=1` 让 CNPG webhook 全集群超时

m01 的 `net.ipv4.conf.all.rp_filter=1` 与 Cilium 的转发路径冲突，
CNPG webhook 请求被丢弃，表现为所有 Cluster 操作卡住、备份也一起失败。

**修复**：统一节点 `rp_filter=0` 并持久化，再重启 CNPG Operator/webhook。
这类“网络策略没变但 webhook 全挂”的问题，要先查内核参数，不要只查 CNPG。

## 修复关键

### 1. 孤儿 PV 清理

```bash
# 1) 盘点
kubectl get pv -o wide
kubectl get pvc -A

# 2) 自动识别 Released + PVC 不存在/UID 不一致
python3 docs/06-storage-ceph/scripts/find_orphan_pv.py

# 3) 核对 Ceph 侧
rbd -p k8s-rbd ls | grep csi-vol
rbd -p k8s-rbd info <image>
rbd -p k8s-rbd snap ls <image>
rbd -p k8s-rbd watchers <image>

# 4) 先删 PV，再删 image（确认 watchers=none）
kubectl delete pv <pv>
rbd -p k8s-rbd rm <image>
```

本集群最终删除 **10 个失效 PV（95Gi）**，集群剩余 18 个 PV 全部 Bound。

### 2. PostgreSQL 备份上线

- 在 CNPG Cluster 的 `spec.backup.barmanObjectStore` 配置 S3；
- 创建 `ScheduledBackup`（本集群每日）；
- 验证对象存储里同时有 base backup 和 WAL；
- **做一次真实恢复演练**，不是只看 Backup condition。

### 3. 存储监控

- Ceph exporter → Prometheus：`ceph_health_status`、OSD up/in、PG active+clean、容量；
- PV/PVC 状态告警：`Released`/`Failed` PV、PVC 使用率；
- CSI 重启、attach/detach 失败、RBD map 失败；
- 对象存储：bucket 容量、4xx/5xx、签名错误。

### 4. 运维基线

- StorageClass 的 `reclaimPolicy` 要按数据重要性选择：数据库用 `Retain`，临时卷用 `Delete`；
- 所有 `Retain` 卷建立清理 Runbook；
- 定期跑 `rbd du` 对账，防止“PV 没了镜像还在”；
- NFS 仅用于非关键数据，逐步迁移到 CephFS/RBD。

### 5. Ceph-CSI 分阶段升级并迁移 Operator

```text
3.16.2（Helm）
  → 3.16.2 原版本先纳入 GitOps
  → 3.17.2 → 3.18.2（逐 minor，不跳版本）
  → Operator 1.1.0 + Driver CR
```

每一步都先预拉镜像、确认 17 个 PVC 全 Bound、做一次动态 provisioning 测试，
再进入下一步。Operator 迁移完成后的验证：

```bash
kubectl -n ceph-csi-rbd get driver,cephconnection,clientprofile
kubectl -n ceph-csi-rbd get pods
kubectl get pv | grep -c Bound
helm -n ceph-csi-rbd list          # 应为空
```

### 6. CNPG 升级与备份迁移

- 先升 Operator，再改 Cluster；`primaryUpdateMethod` 从 `restart` 改为 `switchover`，减少停机；
- 内置 `barmanObjectStore` 在 1.31 将移除，提前迁到 Barman Cloud Plugin；
- 备份验证不能只看 `ContinuousArchiving=True`，要确认 S3 里同时有 base backup 和 WAL；
- 做一次真实恢复演练（恢复到临时集群或临时实例）。

### 7. 磁盘容量治理

```bash
# 节点侧：未使用镜像 + 已完成 Pod
crictl rmi --prune
kubectl delete pod --field-selector=status.phase=Succeeded -A

# PVE 侧：thin pool 回收
qm set <vmid> --scsi0 <disk>,discard=on,ssd=1
fstrim -av

# 长效：kubelet GC 阈值、Harbor tag 保留、Tekton 历史清理
```

本集群两轮清理释放约 **137GiB thin pool + 34GiB 节点根盘**，但 **没有降低 Prometheus 的 21G 本地数据**；
容量治理要区分“镜像/日志/历史对象”和“真实业务数据”。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [ceph-audit/](notes/ceph-audit/) | Ceph 主机硬件、服务、非 Ceph 进程、清理记录 |
| [ceph-csi-restart-analysis.md](notes/ceph-csi-restart-analysis.md) | nodeplugin 累计重启 69 次的根因与修复 |
| [ceph-rbd-released-pv-audit-20261005.md](notes/ceph-rbd-released-pv-audit-20261005.md) | 9 个 RBD Released PV + 2 个僵尸镜像的逐项审计 |
| [pv-cleanup-report.md](notes/pv-cleanup-report.md) | 10 个失效 PV（95Gi）清理全过程 |
| [ceph-rbd-released-pg-backup-implementation-20261005.md](notes/ceph-rbd-released-pg-backup-implementation-20261005.md) | barmanObjectStore + ScheduledBackup 上线与恢复演练 |
| [pg-s3-incident-report.md](notes/pg-s3-incident-report.md) | pg16-ceph-2 重启 + Tempo S3 失败的双问题复盘 |
| [ceph-s3-rbd-client-setup-20261006.md](notes/ceph-s3-rbd-client-setup-20261006.md) | 在 m01 安装 s3cmd/ceph-common 并验证 RBD/S3 |
| [minio-vs-ceph-rgw-analysis.md](notes/minio-vs-ceph-rgw-analysis.md) | “MinIO”命名错误的排查与 RGW 两种访问路径 |
| [compassio-pg-redis-ops-plan.md](notes/compassio-pg-redis-ops-plan.md) | PostgreSQL/Redis 运维、主库故障切换、RTO/RPO |
| [ceph-csi-operator-how-it-works-2026-11-09.md](notes/ceph-csi-operator-how-it-works-2026-11-09.md) | 以 Ceph-CSI 为例讲 Operator/CRD/reconcile、RBAC、leader election |
| [10-storage-basics.md](10-storage-basics.md) | 分区/LVM/RAID/文件系统/fstab/NFS/Ceph/云盘/CSI/SMART 基础与真机证据 |
| [ceph-csi-upgrade-to-operator-2026-11-09.md](notes/ceph-csi-upgrade-to-operator-2026-11-09.md) | 3.16.2 → 3.17.2 → 3.18.2 → Operator 1.1.0 的分阶段升级与回滚 |
| [cnpg-operator-how-it-works-2026-11-09.md](notes/cnpg-operator-how-it-works-2026-11-09.md) | CNPG Operator、Instance Manager、Plugin、reconcile 全过程 |
| [cnpg-upgrade-postmortem-2026-11-08.md](notes/cnpg-upgrade-postmortem-2026-11-08.md) | CNPG 1.22 → 1.30.1、rp_filter、barman plugin、switchover |
| [ceph-disk-optimization-2026-11-05.md](notes/ceph-disk-optimization-2026-11-05.md) | 镜像/Pod/GC/Harbor/Tekton/PVE discard 两轮磁盘清理 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/find_orphan_pv.py](scripts/find_orphan_pv.py) | 只读识别 Released/Failed 且无对应 PVC 的 PV |
| [scripts/inspect-released-pv.sh](scripts/inspect-released-pv.sh) | 只读核对 PV、claimRef、RBD image、watchers |
| [scripts/rbd-du.sh](scripts/rbd-du.sh) | 批量统计 RBD 实际占用 |
| [scripts/recover-test.sh](scripts/recover-test.sh) | 从 S3 下载 base backup 并校验 tar/关键文件 |
| [scripts/pitr-verify.sh](scripts/pitr-verify.sh) | PITR 可达性验证 |
| [assets/ceph-audit/](assets/ceph-audit/) | Ceph 主机审计原始材料 |
| [assets/ceph-status.txt](assets/ceph-status.txt) | 当前 `ceph -s` 快照 |
| [assets/ceph-osd-tree.txt](assets/ceph-osd-tree.txt) | 当前 OSD 树 |
| [assets/pv-list.yaml](assets/pv-list.yaml) | 当前 PV 全量清单 |
| [scripts/ceph_csi_inventory.py](scripts/ceph_csi_inventory.py) | 只读盘点 Operator/Driver/CephConnection/ClientProfile/PV/PVC |
| [assets/ceph-csi-operator/](assets/ceph-csi-operator/) | 升级前备份、Helm values、imageset、StorageClass、实时 CR |
| [assets/cnpg/](assets/cnpg/) | CNPG Cluster/ObjectStore/ScheduledBackup/Plugin 清单与实时导出 |
| [assets/storage-basics/](assets/storage-basics/README.md) | 分区/LVM/RAID/fstab/NFS/CSI/SMART 真机证据 |
| [scripts/enforce-rp-filter.sh](scripts/enforce-rp-filter.sh) | 将节点 rp_filter 改为 loose(2) 并持久化，修复 CNPG webhook 超时 |

```bash
# 只读盘点（不会删除任何东西）
python3 docs/06-storage-ceph/scripts/find_orphan_pv.py
bash docs/06-storage-ceph/scripts/inspect-released-pv.sh
bash docs/06-storage-ceph/scripts/rbd-du.sh
```

> 删除 PV/RBD 是不可逆操作。执行前必须确认：PVC 确实不存在、UID 不一致、
> `watchers=none`、没有快照依赖、备份可用。生产环境先做恢复演练。
