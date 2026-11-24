# Ceph 容量告警排查：`OSD_NEARFULL` / `POOL_NEARFULL` 与 72% 占用根因

> 实测时间：2026-11-24  
> 集群：Ceph Reef `18.2.8`，3 台 VM（ceph-01/02/03），6 个 OSD × 30GiB，共 **180GiB 裸容量**，465 个 PG，15 个 pool（全部 `size=3`）。  
> 现象：`ceph -s` = `HEALTH_WARN`（`1 nearfull osd` + `15 pool(s) nearfull`），裸容量占用 **72.76%**；
> Prometheus 侧 `CephClusterWarning` 告警自 2026-11-24 04:11 UTC 起持续触发。  
> 目标：把告警来源、72% 的构成、空间占用排名、根因和处理路径整理清楚。

## 1. 结论先看

| 问题 | 结论 |
|---|---|
| 触发了哪些告警 | Ceph 原生 `OSD_NEARFULL`（`osd.2` 86.4%）+ `POOL_NEARFULL`（15 个池）；Prometheus `CephClusterWarning`（`ceph_health_status=1`） |
| 72% 的构成 | 逻辑数据 **43.3GiB × 3 副本 = 126GiB**，加 OSD BlueStore 元数据 **4.6GiB**，合计 **131GiB / 180GiB = 72.76%** |
| 占用排名 | RGW 对象桶 `my-zone.rgw.buckets.data` **67GiB**（51%）> K8s RBD `k8s-rbd` **59GiB**（45%）> 其余合计 <100MiB |
| 最大的单一消耗 | `etcd-backups` 桶 **21.6GiB 逻辑（≈65GiB 裸，占全集群 49%）**，由 etcd 每小时快照累积，只靠 30 天生命周期过期，稳态会超过集群容量 |
| 第二大消耗 | Prometheus `prometheus-db` PVC：**100GiB 配额 / 实际 17GiB（≈51GiB 裸）** |
| `osd.2` 为什么先满 | 6 个 OSD 数据量 17.1–26.2GiB，PG 数量几乎相同（224–241）但单个 PG 体量差异大（大 PG 落在 osd.2 的 acting 集合里），upmap 均衡器已无优化空间 |
| 时间压力 | 剩余 49GiB；`etcd-backups` 按 15 天实测 ≈ **4.3GiB/天裸增长**，预计 **3–5 天内触发 nearfull，之后逼近 full** |

## 2. 告警清单与触发原因

### 2.1 Ceph 原生健康检查

```text
$ ceph -s
  health: HEALTH_WARN
          1 nearfull osd(s)
          15 pool(s) nearfull
```

`ceph health detail`：

```text
[WRN] OSD_NEARFULL: 1 nearfull osd(s)
    osd.2 is near full
[WRN] POOL_NEARFULL: 15 pool(s) nearfull
    pool '.mgr' is nearfull
    ... （15 个池全部列出）
```

阈值（`ceph osd dump`）：

```text
full_ratio 0.95
backfillfull_ratio 0.9
nearfull_ratio 0.85
```

| 告警 | 触发条件 | 实际值 | 根因 |
|---|---|---|---|
| `OSD_NEARFULL` | 某 OSD 使用率 ≥ `mon_osd_nearfull_ratio`（0.85） | `osd.2` 数据 26.18GiB / 30GiB，**86.40%**（含元数据后 86.4%） | OSD 数据分布不均 + 集群容量吃紧 |
| `POOL_NEARFULL` | 池被置 `FLAG_NEARFULL` | 15 个池全部置位 | **连带效应**：监控器把“受 nearfull OSD 影响”的池打上标志；只有集群完全没有 nearfull OSD 时才统一清除，所以 osd.2 一直满，15 个池就一直挂着 |

`POOL_NEARFULL` 的机制（对照 Ceph 源码 `src/mon/OSDMonitor.cc` 的 `update_pools_status()`）：

- 监控器先算出 `full_pool_ids / backfillfull_pool_ids / nearfull_pool_ids`，即**受 nearfull/backfillfull/full OSD 影响**的池；
- 给这些池置 `pg_pool_t::FLAG_NEARFULL`；
- **只有当三个集合都为空时**，才会去清除其它池上遗留的 nearfull 标志。

所以这里 **15 个池同时告警是同一个根因（osd.2 接近写满）的连带结果，不是 15 个池各自写满**。
其中 `.mgr` 只有 1 个 PG 且 acting 在 `[3,0,4]`，并不在 osd.2 上，属于“标志未被清除”的遗留，不是它自己满了。

### 2.2 Prometheus / Alertmanager

Alertmanager 当前活动告警：

| alertname | severity | 说明 |
|---|---|---|
| `CephClusterWarning` | warning | **Ceph 相关，本次排查对象** |
| `KubeProxyDown` | critical | 与 Ceph 无关（k8s 组件） |
| `Watchdog` | none | Alertmanager 心跳，非真实故障 |

`CephClusterWarning` 详情：

```json
{
  "labels": {
    "alertname": "CephClusterWarning",
    "ceph_role": "mgr",
    "cluster": "ceph-prod",
    "instance": "10.0.0.41:9283",
    "job": "ceph-mgr",
    "mgr_node": "ceph-02",
    "severity": "warning"
  },
  "startsAt": "2026-11-24T04:11:05.335Z",
  "generatorURL": "http://prometheus-prometheus.monitoring:9090/graph?g0.expr=ceph_health_status{cluster=\"ceph-prod\"}+==+1"
}
```

规则来自 `ceph-cluster-alerts`：

```promql
CephClusterWarning:  ceph_health_status{cluster="ceph-prod"} == 1
```

**告警链路**：

```text
Ceph OSD_NEARFULL / POOL_NEARFULL
  -> ceph health = HEALTH_WARN -> status 1
  -> mgr prometheus 模块暴露 ceph_health_status=1
  -> Prometheus 规则 CephClusterWarning
  -> Alertmanager -> n8n-webhook / wecom
```

> 注意一个监控盲区：`ceph-cluster-alerts` 里有 `CephPoolNearFull`（`ceph_pool_percent_used > 0.85`），
> 但当前各池百分比最高的是 `my-zone.rgw.buckets.data` 81.3%、`k8s-rbd` 79.4%，**都没到 85%，所以没触发**。
> 真正先触发的是 Ceph 原生的 `OSD_NEARFULL`（按 OSD 维度），而 Prometheus 里**没有对应的 OSD nearfull 规则**，
> 只靠 `ceph_health_status` 兜底。详见第 6 节建议。

## 3. 为什么占用 72%

### 3.1 数字拆解

```text
ceph -s  : objects 21.47k, 43 GiB     （逻辑存储）
ceph df  : hdd SIZE 180 GiB, USED 131 GiB, AVAIL 49 GiB, %RAW USED 72.76
```

拆解：

| 项 | 大小 | 说明 |
|---|---|---|
| 逻辑数据 | **43.31 GiB** | `ceph pg dump` 的 `pg_stats_sum.stat_sum.num_bytes = 46,503,967,690` |
| × 副本 | **126 GiB** | 15 个池全部 `size=3, min_size=2`，CRUSH 规则 `replicated_rule`，3 副本 |
| OSD 元数据 | **4.6 GiB** | BlueStore 的 DB/OMAP 与 OSD 同盘（6 个 OSD 的 META 合计约 4.6GiB） |
| **裸占用合计** | **131 GiB** | 与 `ceph df` 一致 |
| 裸容量 | 180 GiB | 6 OSD × 30GiB |
| **占比** | **72.76%** | 剩余 49GiB |

> 为什么不是 43GiB 而是 131GiB：**3 副本把逻辑数据放大成 3 倍**；
> 再叠加同盘 BlueStore 元数据。这是 3 副本小集群占用“虚高”的根本原因。

### 3.2 空间占用排名：Pool 维度

`ceph df detail` 的 `USED` 已是含副本的裸用量：

| 排名 | Pool | 逻辑存储 | 裸占用（USED） | 占比 | 说明 |
|---|---|---|---|---|---|
| 1 | `my-zone.rgw.buckets.data` | 22 GiB | **67 GiB** | 51.4% | 全部 RGW 对象数据，几乎全是 `etcd-backups` |
| 2 | `k8s-rbd` | 20 GiB | **59 GiB** | 45.1% | 14 个 RBD PVC（K8s 块存储） |
| 3 | `cephfs_data` | 10 MiB | 30 MiB | — | CephFS 数据池，几乎没用 |
| 4 | `.mgr` | 1.2 MiB | 3.6 MiB | — | mgr 元数据 |
| 5 | `cephfs_metadata` | 57 KiB | 255 KiB | — | CephFS 元数据 |
| 6 | `my-zone.rgw.buckets.index` | 2.6 MiB | 7.7 MiB | — | RGW bucket index |
| 7 | `my-zone.rgw.log/control/meta` | <100 KiB | <1 MiB | — | RGW 元数据池 |
| 8 | `default.rgw.*`、`rbd`、`my-zone.rgw.buckets.non-ec` | ~0 | ~0 | — | 空池 |

> 两个大头合计占裸容量的 **96.5%**，其余池可忽略。

### 3.3 排名第 1：`my-zone.rgw.buckets.data` 内部（RGW 桶）

`radosgw-admin bucket stats`（按逻辑大小排序）：

| 排名 | Bucket | 逻辑大小 | 对象数 | 所有者 | 创建时间 |
|---|---|---|---|---|---|
| 1 | **`etcd-backups`** | **23,187,247,884 B ≈ 21.6 GiB** | 153 | `pg-backup` | 2026-11-09 |
| 2 | `pg-backups` | 420,510,475 B ≈ 0.39 GiB | 2,328 | `pg-backup` | 2026-10-05 |
| 3 | `loki-chunks` | 322,446,477 B ≈ 0.30 GiB | 5,830 | `loki-admin` | 2026-04-06 |
| 4 | `tempo-traces` | 42,083,082 B ≈ 0.04 GiB | 756 | `tempo-admin` | 2026-04-23 |
| 5 | `testbucket` | 10 B | 1 | `testuser` | 2025-12-22 |
| 6 | `loki-ruler` / `loki-admin` | 0 | 0 | — | — |

**`etcd-backups` 是本次告警的核心**：

- 对象构成：**140 个 `hourly/` + 12 个 `daily/`**，加 1 个测试文件，共 153 个；
- hourly 单对象约 **153 MiB**（103 个为 158,576,672 B，其余 126–157 MiB 不等）；
- hourly 总 21,461,811,584 B ≈ **19.98 GiB**，daily 总 1,725,436,288 B ≈ **1.6 GiB**。

来源（K8s CronJob，命名空间 `etcd-backup`，名称 `etcd-snapshot`）：

```yaml
spec:
  schedule: 5 * * * *      # 每小时第 5 分钟
  jobTemplate: ... 容器 args:
    - /usr/local/bin/etcdctl snapshot save /backup/hourly/etcd-${TS}.db
    - chroot /host /usr/bin/aws --endpoint-url "$S3_ENDPOINT" \
        s3 cp /var/backups/etcd/hourly/etcd-${TS}.db s3://${S3_BUCKET}/hourly/...
    - if [ "$(date +%H)" = "00" ]; then ... 上传 daily ... fi
    # 本地 staging 只保留 ~24 小时 hourly + 7 天 daily
    find /backup/hourly -name 'etcd-*.db' -mmin +1560 -delete
    find /backup/daily  -name 'etcd-*.db' -mtime +7 -delete
  env:
    S3_ENDPOINT: http://10.0.0.31:7480   # Ceph RGW
    S3_BUCKET:   etcd-backups
```

**对象存储侧只有生命周期，没有删除脚本**，生命周期规则：

```json
{
  "prefix_map": {
    "daily/": { "status": true, "expiration": 90 },
    "hourly/": { "status": true, "expiration": 30 }
  }
}
```

即：**hourly 保留 30 天、daily 保留 90 天**，`radosgw-admin lc list` 显示生命周期处理器每天 00:00 正常跑完（`COMPLETE`）。

**增长与稳态估算**：

- 实测：11-09 创建 → 11-24，15 天累计 21.6 GiB，≈ **1.44 GiB/天逻辑**，3 副本后 **≈ 4.3 GiB/天裸**；
- 若每小时 24 次全部成功：24 × 153 MiB ≈ 3.67 GiB/天逻辑 ≈ **11 GiB/天裸**；
- 稳态（30 天 hourly 全保留）：720 × 153 MiB ≈ **99 GiB 逻辑 ≈ 297 GiB 裸**，远超 180GiB 集群容量——**即使生命周期在跑，也会在过期生效前写满**；
- 剩余 49GiB：按实测 4.3GiB/天，**3–5 天内到 85%（nearfull）**，之后继续向 90%/95% 逼近；按满负荷 11GiB/天，**1–2 天内就会触发**。

### 3.4 排名第 2：`k8s-rbd` 内部（RBD 镜像）

`rbd du -p k8s-rbd`（14 个镜像，配额合计 247GiB，实际 24GiB；`ceph df` 口径 STORED 20GiB）：

| 排名 | RBD 镜像 | 配额 | 实际 | 对应 PVC / 命名空间 |
|---|---|---|---|---|
| 1 | `csi-vol-e07faa22-…` | 100 GiB | **17.0 GiB** | `monitoring/prometheus-db-ceph-prometheus-…-0` |
| 2 | `csi-vol-e99018f7-…` | 30 GiB | 1.8 GiB | `deeptutor/deeptutor-data` |
| 3 | `csi-vol-cdfecb4f-…` | 20 GiB | 1.0 GiB | `kafka/data-my-cluster-single-pool-0` |
| 4 | `csi-vol-32e04190-…` | 5 GiB | 796 MiB | `cnpg-system/pg16-ceph-3-wal` |
| 5 | `csi-vol-ab4583f2-…` | 5 GiB | 784 MiB | `cnpg-system/pg16-ceph-4-wal` |
| 6 | `csi-vol-f34d561a-…` | 10 GiB | 544 MiB | `monitoring/prometheus-grafana-ceph` |
| 7 | `csi-vol-4c5d4189-…` | 10 GiB | 344 MiB | `logging/data-loki-write-0` |
| 8 | `csi-vol-0a6cc9fb-…` | 10 GiB | 288 MiB | `cnpg-system/pg16-ceph-3` |
| 9 | `csi-vol-dda57ca2-…` | 10 GiB | 284 MiB | `cnpg-system/pg16-ceph-4` |
| 10 | `csi-vol-ec12c118-…` | 10 GiB | 208 MiB | `logging/data-loki-backend-0` |
| 11 | `csi-vol-5d351d6f-…` | 2 GiB | 208 MiB | `deeptutor/redis-data` |
| 12 | `csi-vol-1658274c-…` | 10 GiB | 120 MiB | `open-webui/open-webui-data` |
| 13 | `csi-vol-33413b60-…` | 5 GiB | 140 MiB | `n8n/n8n-pvc` |

- **Prometheus 一个 PVC 就占掉 k8s-rbd 的 17GiB（裸 51GiB，占全集群约 39%）**，是第二大消耗源；
- 30 天趋势：`k8s-rbd` 逻辑从 21.91GiB 降到 19.75GiB（回收了 2.17GiB，主要是清理了部分 PVC），整体在**下降**；
- 无快照、无 trash（`rbd snap ls` / `rbd trash ls` 均为空），说明这部分没有冗余垃圾，主要是业务真实占用。

### 3.5 `osd.2` 为什么最高（数据分布不均）

`ceph osd df tree`（数据列，含副本）：

| OSD | 主机 | 数据 | %USE | PG 数 |
|---|---|---|---|---|
| osd.2 | ceph-03 | **26.18 GiB** | **86.40%** | 236 |
| osd.1 | ceph-02 | 24.39 GiB | 83.01% | 241 |
| osd.0 | ceph-01 | 23.58 GiB | 78.18% | 240 |
| osd.5 | ceph-01 | 19.73 GiB | 66.35% | 225 |
| osd.4 | ceph-02 | 18.92 GiB | 64.21% | 224 |
| osd.3 | ceph-03 | 17.13 GiB | 58.30% | 229 |

- PG 数量几乎一致（224–241），但数据量从 17.1 到 26.2GiB，**最大/最小 VAR = 1.19 / 0.80，标准差 10.36**；
- 原因是 **PG 体积差异大**：`ceph pg dump` 里最大的 10 个 PG 都在 0.74–0.81GiB，且它们的 `acting` 集合里多包含 osd.2；
- `ceph balancer status` 为 `upmap`，结果 `Unable to find further optimization` —— upmap 只能调整 PG→OSD 的映射，**无法拆分已经偏大的对象**，所以均衡器已尽力、无法再优化；
- 主机维度是均衡的（每台约 42–44GiB），不均衡发生在**同一台两个 OSD 之间**，加上 `osd.2` 只剩 4.1GiB，于是率先越过 85%。

## 4. 关键配置清单

| 对象 | 值 |
|---|---|
| 版本 | Ceph Reef `18.2.8`（mon 3、mgr 2、osd 6、mds 3、rgw 2） |
| 拓扑 | 3 主机 × 2 OSD，每 OSD 30GiB（`ceph osd tree`） |
| 副本 | 所有池 `size=3, min_size=2`，CRUSH `replicated_rule` |
| 阈值 | `nearfull_ratio=0.85`，`backfillfull_ratio=0.9`，`full_ratio=0.95` |
| RGW | Zone `my-zone`，endpoint `http://10.0.0.31:7480`（ceph-01），bucket `etcd-backups` |
| etcd 备份 | CronJob `etcd-backup/etcd-snapshot`，`5 * * * *`，上传 hourly + daily |
| etcd 生命周期 | hourly 30 天、daily 90 天（`radosgw-admin lc get --bucket=etcd-backups`） |
| 告警规则 | `ceph-cluster-alerts`：`CephClusterWarning: ceph_health_status == 1` |
| 均衡器 | mgr `balancer`，`upmap` 模式，当前无优化空间 |

## 5. 复现与核查命令

```bash
# 1) 健康状态与告警明细
ceph -s
ceph health detail

# 2) 容量与池占用
ceph df
ceph df detail

# 3) OSD 分布（重点看 osd.2 的 %USE 和 VAR）
ceph osd df tree
ceph balancer status

# 4) 阈值
ceph osd dump | grep -E 'full_ratio|backfillfull_ratio|nearfull_ratio'

# 5) RGW 桶排名
radosgw-admin bucket stats | jq -r '.[] | [.bucket, .usage["rgw.main"].size, .usage["rgw.main"].num_objects] | @tsv' | sort -k2 -nr

# 6) etcd-backups 明细与生命周期
radosgw-admin bucket list --bucket=etcd-backups | jq 'length'
radosgw-admin lc get --bucket=etcd-backups
radosgw-admin lc list

# 7) RBD 镜像占用
rbd du -p k8s-rbd | sort -k3 -h

# 8) PG 体积与分布（找不均根源）
ceph pg dump -f json | jq -r '.pg_map.pg_stats[] | [.pgid, .stat_sum.num_bytes] | @tsv' | sort -k2 -nr | head

# 9) 告警
kubectl -n monitoring port-forward svc/alertmanager-operated 9093:9093
curl -s localhost:9093/api/v2/alerts | jq -r '.[] | [.labels.alertname, .labels.severity, .status.state] | @tsv'
```

原始证据见 [../assets/ceph-capacity-nearfull-20261124/](../assets/ceph-capacity-nearfull-20261124/)：

| 文件 | 内容 |
|---|---|
| `ceph-status.txt` | `ceph -s` + `ceph health detail` |
| `ceph-df.txt` / `ceph-df-detail.txt` | `ceph df` / `ceph df detail` |
| `osd-df-tree.txt` / `osd-tree.txt` | OSD 分布与拓扑 |
| `osd-ratios.txt` | nearfull/full 阈值 |
| `pg-stat.txt` / `pg-distribution.txt` | PG 状态与按 OSD 的数据分布 |
| `rgw-buckets.txt` | RGW 桶排名 |
| `etcd-backups-sizes.txt` | etcd hourly 对象大小分布 |
| `etcd-backups-lifecycle.json` | 生命周期规则 |
| `rbd-du.txt` | RBD 镜像占用 |

## 6. 处理建议

### 6.1 短期（立即，先把空间让出来）

1. **压缩 `etcd-backups` 的保留时长**（最有效，能立刻止住增长）：

   ```bash
   # 小时快照只留 7 天、daily 只留 30 天（替换原 hourly 30 / daily 90）
   radosgw-admin lc rm --bucket=etcd-backups --rule-id=<hourly-rule-id>
   # 或直接改：重新下发一条 hourly 7 天的规则
   ```

   更彻底的做法：**只保留 daily（甚至 weekly）**，去掉 hourly 上传，把 etcd 备份体积从 21.6GiB 降到 1–2GiB。

2. **清理历史小时快照**（在改生命周期后，等处理器跑完或手动触发）：

   ```bash
   radosgw-admin lc process --bucket=etcd-backups
   ```

3. **重新评估 etcd 备份频率**：`etcd-snapshot` 每小时一次、单份 153MiB，收益是否值得 4.3GiB/天的裸容量。建议改为**每天一次 + 每周一次**，或在上传前压缩（`gzip`/`zstd`）后再 `s3 cp`。

4. **不要用的临时手段**：`ceph osd set-nearfull-ratio 0.9` 之类只是把告警阈值抬高，会掩盖真实风险，不推荐（可作为极端应急，事后必须调回并补空间）。

5. 顺带清理 K8s `Released` PV / RBD 僵尸镜像（见 [pv-cleanup-report.md](pv-cleanup-report.md) 与 [ceph-rbd-released-pv-audit-20261005.md](ceph-rbd-released-pv-audit-20261005.md)），但 `k8s-rbd` 当前在下降，优先级低于 etcd。

### 6.2 中期（消除不均衡与容量瓶颈）

1. **给 OSD 扩容/加盘**：当前 6 个 OSD × 30GiB 是硬瓶颈；3 副本下每加一块盘，有效容量增加约 `盘容量 × (1/3)`。优先加在 `osd.3`（58%）所在的 ceph-03 或均衡分布。
2. **提升 PG 数量 / 重均衡**：`my-zone.rgw.buckets.data`、`k8s-rbd` 的 PG 只有 32 个，单个 PG 偏大导致分布不均。可适度提高 `pg_num`（如 64–128），再 `ceph osd reweight-by-utilization`，让 upmap 有更多调整空间。
3. **复核 etcd 快照大小**：153MiB/次对于 etcd 是否偏大（可能包含大量历史 revision），可考虑定期压缩或启用 etcd 快照压缩。

### 6.3 长期（监控与策略）

1. **补 OSD 维度告警规则**：

   ```promql
   CephOSDNearFull:  max by (osd) (ceph_osd_stat_bytes_used / ceph_osd_stat_bytes) > 0.85
   ```

   或直接对 `ceph_health_detail{name="OSD_NEARFULL"}` 做告警，避免只依赖 `ceph_health_status` 这条粗规则。

2. **加容量趋势/预测告警**：对 `ceph_cluster_total_used_bytes / ceph_cluster_total_bytes` 做 `for: 1h` 的增速判断，提前 N 天预警。
3. **统一对象桶生命周期与配额**：给 `etcd-backups`、`pg-backups`、`loki-chunks` 都配置明确的 `max_size`/`max_objects` 配额，防止单桶无限增长拖垮整个集群。
4. **备份策略评审**：etcd、PG、Loki、Tempo 的备份目标与保留期统一评估，避免都挤在同一块 180GiB 的 RGW 数据池上。

## 7. 实际执行与结果（2026-11-24）

第 6 节的建议已在当天执行，告警已消除。

### 7.1 etcd 备份改为每天一次、滚动 3 天

- `platform-gitops` 提交 **`6e8b116`**，CronJob `etcd-backup/etcd-snapshot`：
  - 频率：`25 3 * * *`（**每天 03:25**，Asia/Shanghai）；
  - 脚本：只生成 `daily/etcd-YYYYMMDD.db`，上传到 `s3://etcd-backups/daily/`；
  - 本地暂存：删除 2 天前的文件（保留最近 3 份）。
- ArgoCD `platform-etcd-backup` 已同步到 revision `6e8b116`（Synced/Healthy）。
- 手动触发一次验证：快照 159MB，成功上传 `daily/etcd-20261124.db`，bucket 保持 3 份。

### 7.2 对象侧生命周期

- `etcd-backups` bucket lifecycle：`daily/` **3 天**过期、`hourly/` **1 天**过期（历史前缀兜底清理）。
- 手动清理历史对象：删除全部 `hourly/*`、早于 3 天的 `daily/*` 以及测试文件，
  bucket 从 153 个对象 / 21.6 GiB 降到 3 个对象 / 454 MiB。

### 7.3 关键坑：删除对象不会立刻释放空间

删除 RGW 对象后，`ceph df` 占用并没有立刻下降。原因是：
`aws s3 cp` 上传 159MB 快照时使用了 **multipart upload**，删除对象后，
multipart 的 **part 与 shadow 对象**作为“泄漏孤儿”留在数据池里，
`radosgw-admin orphans find` 能查到（本次共 **4678 个**，约 **21.6 GiB 逻辑**）。

这些孤儿本应由 RGW 垃圾回收处理，但本次 `radosgw-admin gc list` 为空、`gc process` 未生效，
于是直接对孤儿对象执行 `rados rm`（`orphans find` 已确认它们无索引引用，可安全删除），
删除后空间才真正释放。**排查占用没降时，先查 orphans，不要误判为删除失败。**

### 7.4 结果

| 指标 | 处理前 | 处理后 |
|---|---|---|
| Ceph 健康 | `HEALTH_WARN`（1 nearfull osd + 15 nearfull pools） | **`HEALTH_OK`** |
| 裸容量占用 | 131 GiB / 180 GiB = **72.76%** | 78 GiB / 180 GiB = **43.3%** |
| `osd.2` 使用率 | 86.4%（触发 nearfull） | 54.96% |
| `CephClusterWarning` 告警 | active | 已清除 |
| `etcd-backups` 桶 | 153 个对象 / 21.6 GiB | 3 个对象 / 454 MiB |

## 8. 验证方式

处理后按下面顺序确认告警消除：

```bash
# 1) 空间是否下降、nearfull 是否清除
ceph df
ceph health detail          # 期望不再出现 OSD_NEARFULL / POOL_NEARFULL

# 2) etcd-backups 体积是否回落
radosgw-admin bucket stats --bucket=etcd-backups | jq '.usage["rgw.main"]'

# 3) Alertmanager 告警是否消失
curl -s localhost:9093/api/v2/alerts | jq -r '.[].labels.alertname' | sort -u
```

## 9. 注意事项

1. **不要直接 `rados rm` 或 `rbd rm` 清理**：先确认对象/镜像没有在用（如 etcd 快照是否被恢复流程依赖、PVC 是否仍被 StatefulSet 引用）；
   只有在 `radosgw-admin orphans find` 确认“泄漏孤儿、无索引引用”时才可直接 `rados rm`。
2. **生命周期删除有延迟**：RGW 生命周期处理器每天跑一次，改完规则后不会立刻释放空间；紧急时需要手动触发或直接删对象。
3. **改阈值是掩盖不是解决**：`nearfull_ratio` 调高后告警消失，但写满风险仍在，且会破坏“预留恢复空间”的意义。
4. **副本是占用放大器**：3 副本下任何逻辑数据的膨胀都按 3 倍计入裸容量，评估“删多少”时要除以 3。
5. **集群小、容错空间小**：6 OSD / 3 主机，坏一块盘就少 30GiB 并触发降级；容量必须留足恢复余量。
6. **`aws s3 cp` 会走 multipart**：大文件上传后若删除，可能留下 part/shadow 孤儿，占用要按 3 副本计；
   后续可考虑上传后主动 `s3 cp --no-progress` 之外的清理，或定期跑 `orphans find` 巡检。
7. `KubeProxyDown` 是与 Ceph 无关的另一条告警，本次未处理。

## 10. 相关文档

| 文档 | 内容 |
|---|---|
| [pv-cleanup-report.md](pv-cleanup-report.md) | Released PV（95Gi）清理全过程 |
| [ceph-rbd-released-pv-audit-20261005.md](ceph-rbd-released-pv-audit-20261005.md) | 9 个 RBD Released PV + 2 个僵尸镜像审计 |
| [ceph-disk-optimization-2026-11-05.md](ceph-disk-optimization-2026-11-05.md) | 两轮节点磁盘清理 |
| [minio-vs-ceph-rgw-analysis.md](minio-vs-ceph-rgw-analysis.md) | RGW 与 S3 访问路径、命名澄清 |
| [../../13-sso-oidc/notes/12-keycloak-ceph-sso-account-and-topology.md](../../13-sso-oidc/notes/12-keycloak-ceph-sso-account-and-topology.md) | Ceph Dashboard 的 SSO 账号与拓扑 |
| [../assets/ceph-capacity-nearfull-20261124/](../assets/ceph-capacity-nearfull-20261124/) | 本次排查的原始命令输出 |
