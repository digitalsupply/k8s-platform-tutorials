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

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/find_orphan_pv.py](scripts/find_orphan_pv.py) | 只读识别 Released/Failed 且无对应 PVC 的 PV |
| [scripts/inspect-released-pv.sh](scripts/inspect-released-pv.sh) | 只读核对 PV、claimRef、RBD image、watchers |
| [scripts/rbd-du.sh](scripts/rbd-du.sh) | 批量统计 RBD 实际占用 |
| [assets/ceph-audit/](assets/ceph-audit/) | Ceph 主机审计原始材料 |
| [assets/ceph-status.txt](assets/ceph-status.txt) | 当前 `ceph -s` 快照 |
| [assets/ceph-osd-tree.txt](assets/ceph-osd-tree.txt) | 当前 OSD 树 |
| [assets/pv-list.yaml](assets/pv-list.yaml) | 当前 PV 全量清单 |

```bash
# 只读盘点（不会删除任何东西）
python3 docs/06-storage-ceph/scripts/find_orphan_pv.py
bash docs/06-storage-ceph/scripts/inspect-released-pv.sh
bash docs/06-storage-ceph/scripts/rbd-du.sh
```

> 删除 PV/RBD 是不可逆操作。执行前必须确认：PVC 确实不存在、UID 不一致、
> `watchers=none`、没有快照依赖、备份可用。生产环境先做恢复演练。
