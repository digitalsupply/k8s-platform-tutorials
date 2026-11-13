# 告警规则 P0 修复记录（2026-11-13）

> 对应审计：[alert-rules-accuracy-review-20261113.md](alert-rules-accuracy-review-20261113.md)  
> 修复时间：2026-11-13 07:00–07:40 UTC  
> 涉及仓库：`platform-gitops`、`deeptutor-gitops`、`k8s-platform-tutorials`  
> 验证时点：2026-11-13 07:40 UTC

---

## 1. 结论

本轮把审计里的 **规则级 P0** 全部处理完，并补了 3 类关键空白（CNPG、ArgoCD 应用健康、etcd 备份/SSO/告警出口）：

- 修掉 **8 条死规则**；
- 修掉 **4 条 Ceph 容量规则** 的单位/公式错误；
- 修掉 **2 条当前误报**：`CIPipelineStalled`、`Tempo3LiveStoreClientsLost`；
- 修掉 `CephPGScrubbingError`、`CephOSDHighCommitLatency`、`CephClusterUnhealthy` 等语义/聚合问题；
- 给 13 个“目标消失就静默”的规则补了 `absent()` / DaemonSet desired-ready 保护；
- 新增 CNPG 实例指标与告警、ArgoCD App health/sync、etcd 备份新鲜度、PVC Pending、oauth2-proxy、wecom-adapter、Ceph RGW、OTel span 错误率；
- Alertmanager 的 Watchdog/InfoInhibitor 改走 `noop`（空 receiver），不再每 12h 进业务通道；
- 把 live 里已有的抑制规则回写 Git，并新增 Ceph 监控失明抑制。

**线上验证：264 条 alerting rule、0 条 health 异常；当前 firing 只剩 Watchdog/InfoInhibitor（已进 noop）和 1 条 info 级 CPUThrottlingHigh pending；两条误报已消失。**

---

## 2. 修复明细

### 2.1 死规则（8 条）

| 规则 | 修法 | 结果 |
|---|---|---|
| `CephCSIOperationErrors` | 改用 kubelet 的 `csi_operations_seconds_count{driver_name="rbd.csi.ceph.com",grpc_status_code!="OK"}` | 指标存在，有数据时触发 |
| `TektonPipelineRunFailed` | 改用 `tekton_pipelines_controller_pipelinerun_duration_seconds_count{status="failed"}` | 指标存在 |
| `TektonTaskRunFailed` | 改用 `tekton_pipelines_controller_taskrun_duration_seconds_count{status="failed"}`，按 `task` 聚合 | 指标存在 |
| `MemcachedLimitAboveContainerLimit` | 改用 `memcached_limit_bytes`，并用 `max by(namespace,pod)` 避免标签冲突 | 指标存在 |
| `OtelDemoHighErrorRate` | 改为 `OtelSpanErrorRateHigh`，使用实际存在的 `otel_demo_traces_span_metrics_calls_total` + `opentelemetry` 命名空间 | 指标存在 |
| `OtelDemoServiceDown` | 改为 `OtelCollectorDown`，监控 `opentelemetry` 的 otel-collector | 指标存在 |
| `DeepTutorTurnStalled` | 应用未暴露 `deeptutor_stalls_total`，删除；卡死由 `DeepTutorActiveTurnsStuck` 覆盖 | 规则与单测同步删除 |
| `DeepTutorStallWarningsFrequent` | 应用未暴露 `deeptutor_stall_warnings_total`，删除；失败由 `DeepTutorTurnFailureRate` 覆盖 | 规则与单测同步删除 |

> 说明：`DeepTutorTurnStalled` / `DeepTutorStallWarningsFrequent` 的删除不是“放弃覆盖”，而是承认当前应用没有这两个指标；保留它们只会制造“有告警”的假象。

### 2.2 Ceph 容量/语义（7 条）

| 规则 | 修法 |
|---|---|
| `CephPoolNearFull` | `ceph_pool_percent_used > 0.85`（本集群指标是 0–1 小数，不是 0–100） |
| `CephPoolCriticallyFull` | `> 0.95` |
| `CephClusterNearFull` | `ceph_cluster_total_used_bytes / ceph_cluster_total_bytes > 0.85` |
| `CephClusterCriticallyFull` | `> 0.95` |
| `CephPGScrubbingError` | 改用 `ceph_health_detail{name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"} == 1` |
| `CephOSDHighCommitLatency` | 改用 `max by (ceph_daemon)`，避免单盘慢被平均掉 |
| `CephClusterUnhealthy` | 拆成 `CephClusterWarning`（status=1）与 `CephClusterUnhealthy`（status=2） |

### 2.3 Tempo（3 条）

| 规则 | 修法 |
|---|---|
| `Tempo3LiveStoreClientsLost` | 删除，改为 `Tempo3LiveStoreNotReady`：`min by(pod)(tempo_live_store_ready{job="live-store"}) < 1` |
| `Tempo3QueryErrorRateHigh` | 改为 5xx / total 比例 >5%，并加最小请求量 0.1/s 保护 |
| `Tempo3TargetDown` | 增加 `or absent(up{...})` 兜底 |

### 2.4 CI（2 条）

| 规则 | 修法 |
|---|---|
| `CIPipelineStalled` | 增加 `metric offset 72h > 0` 保护：series 必须在 72h 前已存在；修复 controller 重启后“刚成功仍报 72h 没 run”的误报 |
| `CIPipelineRunFailed` | 增加“failed series 首次出现”兜底：`increase > 0` 或“现在有、1h 前没有”，避免漏首次失败 |

> `CIPipelineStalled` 的 `for` 从 10m 改为 0m：72h 窗口本身已提供阻尼，避免在 1h 评估间隔的合成测试里一直 pending；生产评估间隔 30s，条件成立即触发。

### 2.5 目标消失静默（13 条）

以下规则统一补 `absent()`，或在有 DaemonSet 的场景改用 desired/ready 比较：

- `AlertReceiverDown`、`StorageProvisionerDown`、`KubeVIPDown`、`GitOpsRedisDown`
- `KafkaEntityOperatorDown`、`TektonInterceptorsDown`
- `CiliumAgentNotReady`、`CiliumOperatorNotReady`
- `KafkaClusterOperatorDown`、`CNPGControllerManagerDown`
- `CephMGRUnreachable`
- `MetalLBSpeakerNotReady`（改用 `kube_daemonset_status_desired_number_scheduled > number_ready`，避免 speaker 有意缩容到 0 时误报）

### 2.6 新增覆盖（18 条规则 + 1 个 PodMonitor）

| 领域 | 新增 |
|---|---|
| CNPG | `cnpg-instances` PodMonitor（9187/metrics）+ `CNPGMetricsMissing`、`CNPGClusterNotReady`、`CNPGReplicationLagHigh`、`CNPGBackupFailed`、`CNPGBackupStale` |
| ArgoCD | `ArgoCDAppUnhealthy`、`ArgoCDAppOutOfSync`、`ArgoCDAppInfoMissing` |
| 备份 | `EtcdBackupStale`、`EtcdBackupJobFailed` |
| 存储 | `PersistentVolumeClaimPendingTooLong` |
| SSO | `OAuth2ProxyDown`、`OAuth2ProxyMetricsMissing` |
| 告警出口 | `WeComAdapterDown` |
| Ceph | `CephRGWDaemonDown`、`CephRGWMetadataMissing` |
| OTel | `OtelSpanErrorRateHigh`、`OtelCollectorDown` |
| 缓存 | `MemcachedWorkingSetNearLimit` |

### 2.7 告警链路

- `route.receiver` 默认改为 `wecom`，避免新规则漏 severity 时完全静默；
- `alertname=~"Watchdog|InfoInhibitor"` → `noop` 空 receiver；
- 把 live 里已有的 2 条 severity 抑制规则回写 Git；
- 新增 Ceph 监控失明抑制：`CephClusterHealthUnknown|CephMGRMetricsMissing|CephMGRUnreachable` 抑制其他 `Ceph.*`。

> 踩坑：`receiver: null` 在 YAML 里是空值，Alertmanager 会忽略该 route 的 receiver 并回退到父 receiver；改用字符串 `noop` 后 route 才真正生效。

---

## 3. 验证结果

```text
PrometheusRule 加载：
  alerting rule 264 条
  health != ok  0 条
  CNPG target   cnpg-system/cnpg-instances → pg16-ceph-3/4 均 up
当前 alerts：
  Watchdog         firing   → noop
  InfoInhibitor    firing   → noop
  CPUThrottlingHigh pending (info) ×1
  CIPipelineStalled          已消失
  Tempo3LiveStoreClientsLost 已消失
  MetalLBSpeakerNotReady     已消失（speaker desired=0）
Alertmanager：
  amtool check-config SUCCESS（3 inhibit rules / 3 receivers）
  route 中 Watchdog/InfoInhibitor → noop
```

复现命令见 `platform-gitops/platform/monitoring/README.md` §12.2。

---

## 4. 暂缓项

| 项 | 原因 | 后续 |
|---|---|---|
| 用户入口 blackbox/Probe | 集群内 DNS 对 `deeptutor.xyz` / `studyfree.xyz` / `cngpt.ccwu.cc` 解析不稳定，直接加 Probe 会大量误报 | 先修集群 DNS 或使用 Traefik VIP + Host header |
| Kafka broker / consumer lag | Strimzi 未启用 `metricsConfig`/JMX Exporter；开启要滚动单 broker | 维护窗口加 metricsConfig 后再补 under-replicated/offline/consumer lag |
| Prometheus/Alertmanager HA | 单副本 + RWO PVC；Ceph 池 `MAX AVAIL` 约 12.6GiB，第二套 100Gi Prometheus PVC 有容量风险 | 先扩 Ceph 池或上远程写/Thanos |
| 外部 dead-man switch | 依赖外部服务，尚未选型 | 选型后给 Watchdog 配外部心跳 |
| 入口 TLS 证书探测 | 与 blackbox 一起做 | 同上 |

---

## 5. 提交

| 仓库 | 提交 | 内容 |
|---|---|---|
| `platform-gitops` | `4b5cec1` | 告警 P0 主修复（规则 + values + README） |
| `platform-gitops` | `4ecadc3` | MetalLB speaker 改 DaemonSet desired/ready |
| `platform-gitops` | `1f5ccc3` | 修正 null receiver YAML 引用 |
| `platform-gitops` | `bffaadb` | 用 noop 替代 null，确保 Watchdog 路由生效 |
| `platform-gitops` | `8429959` | etcd 备份新鲜度增加指标缺失兜底 |
| `deeptutor-gitops` | `68a87a1` | 删除死指标告警 + 修正 CI 停滞/失败判定 + 单测 |

ArgoCD 已自动同步：

```text
platform-monitoring-rules   Synced/Healthy   bffaadb
platform-monitoring-stack   Synced/Healthy
deeptutor                   Synced/Healthy   68a87a1
```
