# Ceph 存储压力复盘：背景、原因、解决方案与关键坑

> 记录时间：2026-11-24  
> 范围：Ceph 集群容量告警（`OSD_NEARFULL` / `POOL_NEARFULL` / `CephClusterWarning`）的完整复盘，
> 包含背景、根因、已执行的解决方案，以及**“删除对象后空间不降”**这一关键坑的原因与处理。  
> 配套脚本与配置文件见 [第 5 节](#5-脚本与依赖文件)。

## 1. 背景

### 1.1 集群与触发环境

| 项 | 值 |
|---|---|
| Ceph | Reef `18.2.8` |
| 拓扑 | 3 台 VM（ceph-01/02/03），6 个 OSD × 30GiB，共 **180GiB 裸容量** |
| 副本 | 15 个池全部 `size=3, min_size=2`，CRUSH `replicated_rule` |
| PG | 465 个，全部 `active+clean` |
| 告警链路 | Ceph health → mgr prometheus → Prometheus → Alertmanager → n8n/wecom |
| 触发业务 | etcd 快照备份上传到 Ceph RGW（`s3://etcd-backups/`） |

### 1.2 触发现象

```text
$ ceph -s
  health: HEALTH_WARN
          1 nearfull osd(s)
          15 pool(s) nearfull

$ ceph df
hdd  180 GiB   49 GiB  131 GiB   131 GiB      72.76   # 裸占用 72.76%
```

- `OSD_NEARFULL`：`osd.2` 数据 26.18GiB / 30GiB = **86.40%**（阈值 `nearfull_ratio=0.85`）；
- `POOL_NEARFULL`：**15 个池全部**置位（同一个根因的连带效应）；
- Prometheus `CephClusterWarning`：`ceph_health_status == 1`，自 2026-11-24 04:11 UTC 起持续触发。

### 1.3 目标

1. 消除 Ceph 告警，恢复可用容量；
2. 把 etcd 备份从“会写满集群”的频率改成可长期运行的策略；
3. 沉淀“删除对象不释放空间”的排查与处理经验，避免重复踩坑。

## 2. 原因分析

### 2.1 直接原因：etcd 每小时备份 + 长保留

etcd 备份由 CronJob `etcd-backup/etcd-snapshot` 执行，原策略为**每小时一次**：

- 频率 `5 * * * *`（每小时第 5 分钟），单份快照约 **159MB**；
- 对象存储侧保留 **30 天**（RGW lifecycle `hourly/ expire 30d`）；
- 稳态下最多 **720 份** hourly 快照：720 × 159MB ≈ **99GiB 逻辑**，
  3 副本后 ≈ **297GiB 裸**，远超 180GiB 集群容量。

实测增长：桶 2026-11-09 创建，到 11-24 共 15 天、21.6GiB，≈ **1.44GiB/天逻辑**，
3 副本后 ≈ **4.3GiB/天裸**。剩余 49GiB，按此速率 **3–5 天内就会触发 nearfull**。

### 2.2 放大因素

1. **3 副本放大**：180GiB 裸容量里，逻辑数据被复制 3 份，任何逻辑数据膨胀都按 3 倍计入裸容量；
2. **OSD 分布不均**：6 个 OSD 数据量 17.1–26.2GiB，PG 数量几乎相同但单个 PG 体量差异大，
   大 PG 多落在 `osd.2`，导致它率先越过 85%；
3. **快照持续变大**：etcd pod 未设置 `auto-compaction`，revision 累积到 7347 万，
   单份快照从 README 记录的 ~120MB 涨到 159MB，且会继续涨。

### 2.3 告警链路与阈值

| 层级 | 告警 | 触发条件 | 实际值 |
|---|---|---|---|
| Ceph 原生 | `OSD_NEARFULL` | OSD 使用率 ≥ `mon_osd_nearfull_ratio`（0.85） | `osd.2` 86.40% |
| Ceph 原生 | `POOL_NEARFULL` | 池置 `FLAG_NEARFULL`（受 nearfull OSD 影响的池；无 nearfull OSD 时才统一清除） | 15 个池 |
| Prometheus | `CephClusterWarning` | `ceph_health_status{cluster="ceph-prod"} == 1` | 持续触发 |

## 3. 解决方案（已执行）

### 3.1 备份策略：改为每天一次、滚动 3 天

`platform-gitops` 提交 **`6e8b116`**，CronJob `etcd-backup/etcd-snapshot`：

| 项 | 原策略 | 新策略 |
|---|---|---|
| 频率 | `5 * * * *`（每小时） | **`25 3 * * *`（每天 03:25，Asia/Shanghai）** |
| 快照 | hourly + daily | 只生成 `daily/etcd-YYYYMMDD.db` |
| 上传 | hourly/ + daily/ | 只上传 `s3://etcd-backups/daily/` |
| 本地暂存 | hourly 26h + daily 7 天 | **删除 2 天前的文件（保留最近 3 份）** |

- ArgoCD `platform-etcd-backup` 已同步（revision `6e8b116`，Synced/Healthy）；
- 手动触发验证通过：快照 159MB，成功上传 `daily/etcd-20261124.db`。

### 3.2 对象侧生命周期

`etcd-backups` bucket lifecycle 改为：

| 前缀 | 过期 | 说明 |
|---|---|---|
| `daily/` | **3 天** | 与“滚动 3 天”一致 |
| `hourly/` | **1 天** | 历史前缀兜底，防止旧脚本残留继续堆积 |

配置见 [assets/etcd-backups-lifecycle.json](../assets/etcd-backups-lifecycle.json)，
CronJob 见 [assets/etcd-backup-daily-cronjob.yaml](../assets/etcd-backup-daily-cronjob.yaml)。

### 3.3 历史对象清理

使用 [scripts/cleanup-etcd-backups.sh](../scripts/cleanup-etcd-backups.sh)：

- 删除全部 `hourly/*`（143 个）；
- 删除早于 3 天的 `daily/*`（11 个，保留 11-22/23/24）；
- 删除测试对象。

桶从 **153 个对象 / 21.6 GiB** → **3 个对象 / 454 MiB**。

### 3.4 泄漏孤儿清理（关键步骤）

删除对象后空间并未立刻下降，排查发现数据池存在大量**泄漏孤儿**，
用 [scripts/ceph-orphan-cleanup.sh](../scripts/ceph-orphan-cleanup.sh) 清理，详见 [第 4 节](#4-关键坑删除对象空间不降)。

### 3.5 结果对比

| 指标 | 处理前 | 处理后 |
|---|---|---|
| Ceph 健康 | `HEALTH_WARN`（1 nearfull osd + 15 nearfull pools） | **`HEALTH_OK`** |
| 裸容量占用 | 131 GiB / 180 GiB = **72.76%** | 78 GiB / 180 GiB = **43.3%** |
| 可用空间 | 49 GiB | **102 GiB** |
| `osd.2` 使用率 | 86.40%（触发 nearfull） | 54.96% |
| `CephClusterWarning` 告警 | active | **已清除** |
| `etcd-backups` 桶 | 153 个对象 / 21.6 GiB | 3 个对象 / 454 MiB |

## 4. 关键坑：删除对象，空间不降

### 4.1 现象

通过 `aws s3 rm` 删除了 `etcd-backups` 桶里 150 个对象（逻辑上释放了约 21.6GiB），
但 `ceph df` 的裸占用始终不降（`osd df` 各 OSD 数据量也不变），
甚至因为期间其他写入略有上升。

### 4.2 原因

**`aws s3 cp` 上传 159MB 快照时走了 multipart upload。** 删除对象时，
RGW 只移除了 bucket 索引里的条目，multipart 上传产生的 **part 与 shadow 对象**
作为“泄漏孤儿”留在数据池里，并没有被删除。这些孤儿占用了与快照相当的空间（3 副本下按倍数放大）。

本次 `radosgw-admin orphans find` 查到 **4678 个**泄漏孤儿（`__multipart_hourly/...`、`__shadow_hourly/...` 等），
合计约 **21.6 GiB 逻辑**，与“删了却没释放”的缺口吻合。

> 补充：这些孤儿本应由 RGW 垃圾回收处理，但本次 `radosgw-admin gc list` 为空、`gc process` 未生效，
> 没有自动清理，所以需要手动处理。

### 4.3 如何排查

```bash
# 在能访问 Ceph 集群的机器上执行
radosgw-admin orphans find --pool=my-zone.rgw.buckets.data \
  --job-id=orphan-probe --yes-i-really-mean-it 2>/dev/null | grep '^leaked:'
```

- 输出里的 `leaked: <oid>` 就是无索引引用的泄漏孤儿；
- 日志行（`skipping head object`）不是孤儿，不要误删。

### 4.4 解决方案

确认孤儿无索引引用后，直接删除：

```bash
while read -r oid; do
  rados -p my-zone.rgw.buckets.data "$oid"
done < <(radosgw-admin orphans find --pool=my-zone.rgw.buckets.data \
  --job-id=orphan-cleanup --yes-i-really-mean-it 2>/dev/null | grep '^leaked:' | sed 's/^leaked: //')
```

或直接用脚本（先 `DRY_RUN=true` 核对，再实际删除）：

```bash
POOL=my-zone.rgw.buckets.data DRY_RUN=true bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
POOL=my-zone.rgw.buckets.data bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
```

删除后空间立即释放（本次删除 4677 个，Ceph 裸占用 131GiB → 78GiB）。

### 4.5 预防与注意

1. **删除对象后空间没降，先查 orphans，不要误判为删除失败**；
2. **只有 `orphans find` 判定为 leaked 的对象才可直接 `rados rm`**，
   有索引引用的对象（如在用 PVC、在途 multipart）不要手动删；
3. 大文件用 `aws s3 cp` 上传默认可能走 multipart，删除后容易留孤儿；
   定期用 `orphans find` 巡检，或考虑上传后主动清理；
4. RGW 生命周期删除同样可能滞后，紧急清理需要手动触发。

## 5. 脚本与依赖文件

| 文件 | 作用 | 说明 |
|---|---|---|
| [scripts/cleanup-etcd-backups.sh](../scripts/cleanup-etcd-backups.sh) | 清理 `etcd-backups` 桶 | 删 `hourly/`、删早于 N 天的 `daily/`、删 `test-*`；需要 aws CLI 凭据 |
| [scripts/ceph-orphan-cleanup.sh](../scripts/ceph-orphan-cleanup.sh) | 清理 RGW 泄漏孤儿 | `orphans find` + `rados rm`；支持 `DRY_RUN=true` |
| [assets/etcd-backup-daily-cronjob.yaml](../assets/etcd-backup-daily-cronjob.yaml) | 新的etcd 备份 CronJob | 从 `platform-gitops` 复制的最终版本 |
| [assets/etcd-backups-lifecycle.json](../assets/etcd-backups-lifecycle.json) | bucket 生命周期配置 | `daily/` 3 天、`hourly/` 1 天 |

上游源文件（GitOps，不在本文档仓库）：

| 仓库 / 路径 | 内容 |
|---|---|
| `platform-gitops` → `platform/backup/etcd/cronjob.yaml` | etcd 备份 CronJob（提交 `6e8b116`） |
| `platform-gitops` → `platform/backup/etcd/README.md` | 备份策略说明（频率、保留、恢复步骤） |

用法示例：

```bash
# 1) 清理历史备份
KEEP_DAYS=3 S3_ENDPOINT=http://10.0.0.31:7480 S3_BUCKET=etcd-backups \
  bash docs/06-storage-ceph/scripts/cleanup-etcd-backups.sh

# 2) 清理泄漏孤儿（先 dry-run，再实际删除）
POOL=my-zone.rgw.buckets.data DRY_RUN=true \
  bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
POOL=my-zone.rgw.buckets.data \
  bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
```

## 6. 验证

```bash
# 1) 健康状态与告警清除
ceph -s
ceph health detail          # 期望 HEALTH_OK

# 2) 容量下降
ceph df
ceph osd df                 # 各 OSD 使用率下降

# 3) 桶体积回落
radosgw-admin bucket stats --bucket=etcd-backups | jq '.usage["rgw.main"]'

# 4) 无残留孤儿
radosgw-admin orphans find --pool=my-zone.rgw.buckets.data \
  --job-id=check --yes-i-really-mean-it 2>/dev/null | grep -c '^leaked:'

# 5) 告警消失
curl -s localhost:9093/api/v2/alerts | jq -r '.[].labels.alertname' | sort -u
```

## 7. 后续建议

1. **给 etcd 开 auto-compaction**：`--auto-compaction-mode=periodic --auto-compaction-retention=1h`（或 24h），
   压住快照体积增长（当前 revision 已 7369 万、单份 159MB 且仍在涨）。
2. **定期巡检孤儿**：把 `orphans find` 纳入容量巡检，避免 multipart 孤儿长期占空间。
3. **容量趋势告警**：对 `ceph_cluster_total_used_bytes` 做增速/预测告警，提前预警。
4. **备份策略统一评审**：etcd、PG、Loki、Tempo 的备份保留期统一评估，避免都挤在同一数据池。

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| [ceph-capacity-nearfull-audit-20261124.md](ceph-capacity-nearfull-audit-20261124.md) | 告警排查过程：占用拆解、空间排名、逐项配置、实测输出 |
| [../assets/ceph-capacity-nearfull-20261124/](../assets/ceph-capacity-nearfull-20261124/) | 排查时的原始命令输出（`ceph -s`/`df`/OSD 分布/PG 分布/RGW 桶/RBD du） |
| [pv-cleanup-report.md](pv-cleanup-report.md) | Released PV（95Gi）清理全过程 |
| [ceph-disk-optimization-2026-11-05.md](ceph-disk-optimization-2026-11-05.md) | 两轮节点磁盘清理 |
| [minio-vs-ceph-rgw-analysis.md](minio-vs-ceph-rgw-analysis.md) | RGW 与 S3 访问路径、命名澄清 |
| [ceph-rbd-released-pv-audit-20261005.md](ceph-rbd-released-pv-audit-20261005.md) | RBD Released PV 与僵尸镜像审计 |
