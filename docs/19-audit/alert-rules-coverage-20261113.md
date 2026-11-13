# 告警规则覆盖与正确性审计（2026-11-13）

审计对象：Prometheus 里实际加载的 248 条 alert 规则（40 个 PrometheusRule 对象、231 条 alert + 94 条 recording）
+ Alertmanager 的送达链路 + 集群里实际存在的组件。

方法：先用 `kubectl` / Prometheus API / Alertmanager API 拉事实，再让 opencode 做判断，最后逐条复核它的结论。
**本文所有数字都有一条可复现命令**（见 §8），opencode 的判断凡与实测不符的都标了"复核更正"。

---

## 1. 结论

| 维度 | 结论 | 关键证据 |
|---|---|---|
| 通用 K8s 覆盖 | **好**（上游 kube-prometheus 那套基本完整） | apps 17 / resources 8 / storage 5 / kubelet 15 / node-exporter 26 / prometheus 自身 23 条 |
| CNI（Cilium）覆盖 | **严重不足** | 253 个 `cilium_*` 指标在采，只有 2 条规则（agent/operator Ready）；`cilium_bpf_map_pressure`、`hubble_lost_events_total` 有数据但零规则 |
| 日志（Loki）覆盖 | **严重不足** | 1 条规则（`LokiIngestStalled`，判的是 target 可用性不是写入量）；有 loki-canary 3 副本却无 canary 丢日志告警；对比 Tempo 有 20 条 |
| 存储双路径 | **一半**：Ceph 集群本体覆盖好（19 条），**RBD/CSI 数据面零覆盖** | 26 条 Ceph 相关规则全在 ceph-mgr 指标上；`csi_sidecar_*` 指标一条都没采 |
| 正确性 | **26 条规则引用了当前不存在的指标**，其中 14 条是真失效 | 见 §4；`tekton_pipelines_controller_pipelinerun_count`、`memcached_limit_maxbytes_bytes`、`kubelet_certificate_manager_server_ttl_seconds` 等 |
| 分级送达 | **info/none 结构性收不到** | Alertmanager `InfoInhibitor` 常驻 firing 并抑制全部 info；7 条 info 规则等于装饰 |
| 送达可靠性 | **历史大面积失败，现恢复** | `failed_total` 2883(other)+1508(serverError)；400 行日志里 372 条失败，集中在 2026-11-11T12:58，当时 URL 指向已死的 Cloudflare 隧道 |
| 盲区组件 | oauth2-proxy×5、headlamp、wecom-adapter、metrics-server、prometheus-adapter、sealed-secrets、VPA、etcd 备份 | 规则里 0 命中 |

一句话：**通用层是被 kube-prometheus 默认值覆盖的，自建层（Cilium/Loki/CSI/SSO/备份）才是真正的缺口，而"告警响了能不能收到"这条链本身没有 deadman。**

---

## 2. 实测基线

```
PrometheusRule 对象 40 个 → alert 231 条 / recording 94 条
Prometheus 实际加载   51 组 / 248 条，health 全部 ok
severity 分布         warning 146 / critical 76 / info 7 / none 2
当前状态              firing 4（Tempo3LiveStoreClientsLost、CIPipelineStalled、Watchdog、InfoInhibitor）
                      pending 1（CPUThrottlingHigh×2）
target                115 个全部 up，0 down（52 个 job）
Alertmanager          单实例，v0.32.0，配置 2026-11-11T12:58:43 加载成功
silence               0 条 active
```

---

## 3. 覆盖矩阵（组件 × 信号类型）

信号类型：**A** 可用性 / **R** 资源与容量 / **F** 数据流（真的在流动） / **E** 错误率 / **S** 缓慢死亡（备份、证书、磁盘）

| 组件 | A | R | F | E | S | 备注 |
|---|---|---|---|---|---|---|
| node / kubelet / OS | ✅26 | ✅ | — | ✅ | ✅ | node-exporter 26 条 + kubelet 15 条 |
| apiserver / etcd / scheduler / controller-manager | ✅ | ✅ | — | ⚠️ | — | `etcdGRPCRequestsSlow` 指标不存在（§4） |
| pods / deployments / sts / ds / jobs / HPA / PDB | ✅17 | ✅8 | — | — | — | 上游 kubernetes-apps 全套 |
| PV / PVC | ⚠️ | ✅ | — | ✅ | ✅ | 排除条件用的 `kube_persistentvolumeclaim_labels` 已不存在，见 §4 |
| Ceph 集群（mon/osd/pg/pool） | ✅19 | ✅ | — | ⚠️ | ✅ | `pool_id` 类规则实际可用；RGW 只有 `ceph_rgw_metadata` 一个指标，请求/错误率无 |
| **ceph-csi（RBD 数据面）** | ❌ | ❌ | ❌ | ❌ | ❌ | 没采 csi sidecar 指标；`CephCSIOperationErrors` 引用的指标不存在 |
| **Cilium / CNI** | ⚠️2 | ❌ | ❌ | ❌ | — | bpf map 压力、drop、endpoint 未 ready、hubble 丢事件全裸 |
| **Loki** | ⚠️1 | ❌ | ❌ | ❌ | ❌ | 只有 `LokiIngestStalled`；canary 有 3 副本未接告警 |
| Tempo | ✅20 | ⚠️ | ✅ | ✅ | — | 唯一做得完整的自建组件 |
| Alloy | ✅2 | ⚠️ | ❌ | ❌ | — | `AlloyDown`/`AlloyDesiredCountMismatch` |
| ArgoCD | ⚠️2 | ⚠️ | ❌ | ❌ | — | 只有 repo-server down + 重启；`argocd_app_info` 有 43 条 series 但无 App Degraded/OutOfSync 告警 |
| cert-manager | ✅3 | — | — | — | ✅ | 到期/过期/NotReady |
| Tekton | ❌ | — | — | ❌ | — | 2 条规则引用的指标名不存在（真实指标名是 `_pipelinerun_total{status=...}`） |
| Kafka / Strimzi | ⚠️2 | — | ❌ | ❌ | — | 只有 operator/entity operator down |
| CNPG（pg16-ceph，2 实例） | ❌ | — | ❌ | ❌ | — | 只监控 controller-manager；**Postgres 实例一条指标都没采**（`cnpg_collector_up` 0 series） |
| traefik | — | — | — | ✅1 | — | 5xx 率 |
| kube-vip | ✅3 | — | — | — | — | 用 `kube_lease_owner`，实测有数据 |
| MetalLB | ⚠️2 | — | — | — | — | speaker 已 0 副本，规则会长期"符合预期地沉默" |
| **etcd 备份（CronJob 每小时）** | ❌ | — | ❌ | ❌ | ❌ | 44 分钟前刚成功；失败了没有任何告警 |
| **oauth2-proxy（5 副本）** | ❌ | — | — | ❌ | — | 它挂了 = 所有 UI 登不上，没人知道 |
| headlamp / gitlab-runner / sealed-secrets / VPA / metrics-server / prometheus-adapter | ❌ | ❌ | ❌ | ❌ | ❌ | 0 命中 |
| n8n / wecom-adapter（告警接收端） | ⚠️ | — | ❌ | ❌ | — | 只监控 n8n pod ready，转发侧无覆盖 |

---

## 4. 引用了不存在指标的 26 条规则（逐条定性 · 已复核）

判定方法：把每条 expr 里的指标名抽出来，与 Prometheus 实际持有的 4299 个指标名比对；
再对可疑项**直接抓对应 exporter 的 `/metrics` 复核**，避免把"当前恰好没有 series"误判成"指标不存在"：

```
kube_persistentvolumeclaim_labels              KSM /metrics → 0    (KSM 2.x 已移除)
kube_state_metrics_list_total                  KSM 8080 → 0，但 **8081 bytes 有 69 条 series**
memcached_limit_maxbytes_bytes                  exporter → 0 ；memcached_limit_bytes → 1
tekton_pipelines_controller_pipelinerun_count   controller → 0 ；_total{status} 与 _duration_seconds_count{status} 都有
alertmanager_cluster_members                    AM /metrics → 0
prometheus_sd_refresh_failures_total            Prometheus /metrics → 0
node_systemd_unit_state                         node-exporter /metrics → 0
prometheus_remote_storage_samples_failed_total  存在（1 series）→ 原规则靠 or 兜底，可用
```

**A. 真失效——永远不会触发（13 条）**

| 规则 | severity | 规则里的指标 | 实际是什么 | 修法 |
|---|---|---|---|---|
| TektonPipelineRunFailed | warning | `tekton_pipelines_controller_pipelinerun_count` | `..._pipelinerun_total{status="failed"}` 或 `..._pipelinerun_duration_seconds_count{status="failed"}`（两者都带 status，实测 success 有值） | `increase(tekton_pipelines_controller_pipelinerun_total{status="failed"}[10m]) > 0` |
| TektonTaskRunFailed | warning | `..._taskrun_count` | `..._taskrun_total{status=...}` | 同上换 taskrun |
| MemcachedLimitAboveContainerLimit | warning | `memcached_limit_maxbytes_bytes` | `memcached_limit_bytes`（loki-chunks-cache 实测 2 series） | 换名，并改成 `> 0.85 * on(namespace,pod) group_left() kube_pod_container_resource_limits{resource="memory"}` |
| KubeletServerCertificateExpiration ×2 | critical+warning | `kubelet_certificate_manager_server_ttl_seconds` | kubelet 1.35 只导出 `..._client_ttl_seconds` | 删除（或改为监控 apiserver 客户端证书 + cert-manager 证书） |
| KubeletServerCertificateRenewalErrors | warning | `kubelet_server_expiration_renew_errors` | 新旧名都不存在（`kubelet_certificate_manager_server_expiration_renew_errors` 也是 0 series） | 删除 |
| KubeStateMetricsListErrors | critical | `kube_state_metrics_list_total` | **指标存在，但只在容器 8081（telemetry），Service 只暴露 8080** | 给 Service 加 8081 端口 + ServiceMonitor 加 `metrics` endpoint，规则即可复活 |
| KubeStateMetricsWatchErrors | critical | `kube_state_metrics_watch_total` | 同上 | 同上 |
| KubeStateMetricsShardingMismatch | critical | `kube_state_metrics_total_shards` | 同上（但单分片无意义） | 删除 |
| KubeStateMetricsShardsMissing | critical | `kube_state_metrics_shard_ordinal` | 同上 | 删除 |
| AlertmanagerMembersInconsistent | critical | `alertmanager_cluster_members` | 只有 `alertmanager_cluster_enabled`（单副本，HA 关闭） | 删除 |
| etcdGRPCRequestsSlow | critical | `grpc_server_handling_seconds_bucket` | etcd 3.6 只导出 `grpc_server_handled_total` 等计数 | 改用 `histogram_quantile(0.99, sum(rate(etcd_request_duration_seconds_bucket[5m])) by (le)) > 0.15` |
| PrometheusSDRefreshFailure | warning | `prometheus_sd_refresh_failures_total` | Prometheus v3 不再导出 | 删除 |
| NodeSystemdServiceFailed / Crashlooping ×2 | warning | `node_systemd_unit_state` / `node_systemd_service_restart_total` | 6 台都没启用 systemd 收集器 | 开收集器（需 dbus socket）或删规则——现在等于假象覆盖 |

> 这 13 条里有 **4 条 critical 是 KSM 自监控**。它们让列表看起来"集群核心组件都被监控着"，
> 实际全是死规则——比没有规则更危险，因为审计时会被当成已覆盖。而其中 2 条只需给 Service 加一个 8081 端口。

**B. 规则照常工作，但里面的"排除条件"是空操作（4 条）**

`KubePersistentVolumeFillingUp`（critical+warning）、`KubePersistentVolumeInodesFillingUp`（critical+warning）
里的 `unless on (...) kube_persistentvolumeclaim_labels{...}` —— 该指标 KSM 2.x 已移除；
`unless` 右侧为空时**左侧原样保留**，所以告警仍会响，只是"按标签排除某些 PVC"失效。
修法：改用 `kube_persistentvolumeclaim_info` join，或删掉这个 unless。

**C. 其实是可用的（2 类）**

- `etcdHighNumberOfLeaderChanges`：`[15m:1m]` 子查询被解析成"指标 `:1m`"，是解析假阳性，规则正常。
- `PrometheusRemoteStorageFailures`：表达式用 `(old or new)` 兜底，`prometheus_remote_storage_samples_failed_total` 实测存在，规则可用（但当前没配 remote write，恒为 0）。

**D. 硬件/场景不存在，死得其所（6 条）**

`NodeRAIDDegraded`、`NodeRAIDDiskFailure`（无软 RAID）、`NodeBondingDegraded`（无 bond）、
`OtelDemoServiceDown`、`OtelDemoHighErrorRate`（demo 已删，且 spanmetrics 指标本身不存在）、
`CephPoolNearFull`/`CephPoolCriticallyFull`（`pool_id` 是标签不是指标，实际可用——复核更正：这两条不是失效规则）。

**一个必须记住的结论**：13 条真失效里，**8 条靠改 PromQL 救不回来**——它们是采集侧没开
（node-exporter 的 mdadm/systemd/bonding collector、ceph-csi sidecar 的 :8080、KSM 的 8081、kubelet 证书轮转）。
修规则之前先修采集，否则只是把一条死规则换成另一条死规则。

## 5. 该有但没有的告警（按 业务影响 × 发生概率 排序）

只列能落到这套集群真实组件、且现有 248 条里确实没有的信号。

| # | 缺失告警 | 覆盖的故障 | 为什么重要（本集群事实） | PromQL（可直接用） | sev / for |
|---|---|---|---|---|---|
| 1 | `EtcdSnapshotStale` | 备份**没有产出**（CronJob 被 suspend / 一直排队），而不仅是 Job 失败 | ns `etcd-backup` 小时级 CronJob，最近一次成功在 44 分钟前。Job 失败有上游 `KubeJobFailed` 兜着，但"根本没跑"没有任何告警 | `time() - max(kube_cronjob_status_last_successful_time{namespace="etcd-backup",cronjob="etcd-snapshot"}) > 7200` | critical / 10m |
| 2 | `CiliumBPFMapPressureHigh` | BPF map 接近满 → 新 Pod/新连接静默失败 | 253 个 cilium 指标在采，`cilium_bpf_map_pressure` 有数据但零规则 | `max by (map_name) (cilium_bpf_map_pressure) > 0.9` | warning / 10m |
| 3 | `CiliumEndpointNotReady` | endpoint 卡在 regenerating → Pod 网络不通但 Ready | CNI 是数据面单点，现有只有 agent pod ready；标签实测是 `endpoint_state`（不是 `state`） | `sum by (instance) (cilium_endpoint_state{endpoint_state=~"not-ready|regenerating"}) > 0` | warning / 15m |
| 4 | `LokiCanaryLogLoss` | 日志实际丢失（写入链路断但 target 还 up） | 有 3 副本 loki-canary，指标 `loki_canary_missing_entries_total` 在采，无规则 | `increase(loki_canary_missing_entries_total[10m]) > 0` | critical / 5m |
| 5 | `LokiIngesterRestarting` | ingester/backend 反复重启 → 写入抖动 | 单副本 `loki-backend`，重启即写不可用 | `increase(kube_pod_container_status_restarts_total{namespace="logging",pod=~"loki-(backend|write).*"}[1h]) > 0` | warning / 10m |
| 6 | `ArgoCDAppDegraded` | GitOps 应用掉到 Degraded/OutOfSync 无人知 | 43 个 Application 全靠它；`argocd_app_info` 在采但零规则 | `max by (name) (argocd_app_info{health_status!="Healthy"}) > 0` | critical / 15m |
| 7 | `CNPGClusterNotReady` | Postgres 主备/副本异常 | `pg16-ceph` 2 实例在跑，但**一条 PG 指标都没采**（`cnpg_collector_up` 0 series）——先加 PodMonitor 抓实例 9187 端口，再谈规则 | 加 monitor 后：`cnpg_pg_replication_streaming_replicas < 1` 或 `cnpg_collector_up == 0` | critical / 5m |
| 8 | `CephRBDVolumeErrors` | RBD 挂载/扩容失败 → Pod 起不来 | ceph-csi 完全没采；先加 PodMonitor 再谈规则 | 加 monitor 后用 `csi_sidecar_operations_errors_total > 0` | critical / 10m |
| 9 | `OAuth2ProxyDown` | SSO 挂了 → 所有 UI 登不上 | 5 个 oauth2-proxy 实例、0 规则 | `sum by (deployment) (kube_deployment_status_replicas_available{namespace="oauth2-proxy"}) < 1` | warning / 5m |
| 10 | `HubbleFlowLoss` | Hubble 丢事件 → 观测数据不全 | **实测现在就在丢**：3 个 agent 上 `rate(hubble_lost_events_total[10m])` = 0.2/s，buffer 4095/4095 满 | `rate(hubble_lost_events_total[10m]) > 0` | warning / 15m |
| 11 | `MetricsServerDown` | metrics.k8s.io 不可用 → HPA 全瞎 | metrics-server 单副本，0 规则；HPA 有 3 条规则却依赖它 | `absent(up{job="metrics-server"} == 1) or up{job="metrics-server"} == 0` | critical / 5m |
| 12 | `WecomAdapterDown` | 企业微信通道挂掉但 n8n 正常 | `wecom-adapter` 2 副本自研服务，无覆盖；`AlertReceiverDown` 只看 n8n | `sum(kube_pod_status_ready{namespace="monitoring",pod=~"wecom-adapter-.*",condition="true"}) < 1` | critical / 5m |

**来自 opencode 第二意见、经我复核后采纳的补充（6 条）**

| # | 缺失告警 | 覆盖的故障 | 为什么重要 | PromQL（已修正 label） | sev / for |
|---|---|---|---|---|---|
| 13 | `NodeCorrelatedFailure` | 宿主机故障导致多节点同时失联 | 6 台 VM 同在一台 PVE 上，现有 `KubeNodeNotReady` 只会逐节点触发 6 次，分不清"宿主机挂了"和"单节点挂了"，响应动作完全不同 | `(1 - count(kube_node_status_condition{condition="Ready",status="true"} == 1) / count(kube_node_info)) >= 0.5` | critical / 2m |
| 14 | `NodeFilesystemReadOnly` | 盘被 remount 成只读 | 现有规则只覆盖"将满/快满"，不覆盖"已只读"；只读会让 kubelet/containerd 连锁崩 | `node_filesystem_readonly{job="node-exporter",fstype!~"tmpfs|overlay|squashfs"} == 1`（36 series 在采） | critical / 5m |
| 15 | `PersistentVolumeClaimPendingTooLong` | 新 PVC 长时间 Pending | `KubePersistentVolumeErrors` 只看 Failed 阶段，Pending 无告警 | `kube_persistentvolumeclaim_status_phase{job="kube-state-metrics",phase="Pending"} == 1` | warning / 30m |
| 16 | `CephOSDFlapping` | OSD 反复 up/down | 现有 `CephOSDDown` 只看持续 down，抓不到 flapping；Ceph 与 K8s 同宿主机，资源争抢必然抖 | `max by (ceph_daemon) (changes(ceph_osd_up[1h])) > 3` | warning / 15m |
| 17 | `ArgoCDAppOutOfSyncStuck` | 应用长期 OutOfSync/Unknown | `argocd_app_info` 43 条 series 在采；GitOps 静默失效时集群会一直停在旧版本 | `max by (name) (argocd_app_info{job="argocd/argocd",sync_status=~"OutOfSync|Unknown"} == 1)` | warning / 1h |
| 18 | `KCMWorkqueueBacklog` | controller-manager 调谐队列积压 | 队列积压时 ArgoCD 显示同步成功、实际没人 reconcile | `max by (instance) (workqueue_depth{job="kube-controller-manager"}) > 1000`（59 series 在采） | warning / 15m |

未采纳的 opencode 建议及原因：`CephRBDVolumeStatsMissing`（表达式实测会命中 1 条"PVC 存在但无 volume stats"，
需要再加"Pod Running 且 PVC Bound"限定才不误报）；`KubeletCertMetricsAbsent` 用
`absent(kubelet_certificate_manager_server_ttl_seconds)` —— 该指标永远不存在，会变成永久 firing 的假告警。

补充（重要性次之）：`KubeJobFailed` 已有上游规则但排除了 CronJob 的 `etcd-snapshot`？实测未排除——需要确认 Job 失败是否会触发（CronJob 生成的 Job 有 `ownerReferences`，规则按 ns 匹配，会响）。这条留作待验证项（§7）。

---

## 6. 送达链路：告警响了，人能不能收到

### 6.1 配置现状（generated config 原文）

```yaml
route:
  receiver: n8n-webhook            # 默认
  group_by: [alertname, namespace, severity]
  routes:
  - {receiver: n8n-webhook, matchers: severity =~ "critical|warning", continue: true}
  - {receiver: wecom,       matchers: severity =~ "critical|warning", continue: true}
  group_wait: 30s / group_interval: 5m / repeat_interval: 12h
```

### 6.2 三个结构性问题

1. **两条子路由条件完全相同、都 `continue: true`** → critical 和 warning 走同样的通道、同样的节奏，
   severity 分级在路由层等于不存在；每次故障打两份 webhook，而接收端恰恰是最脆弱的自研服务。
2. **info / none 结构性收不到**：`InfoInhibitor`（`vector(1)`，常驻 firing）通过 inhibit 抑制所有 info，
   剩下的 none 类只落到 n8n 默认路由。本集群有 **7 条 info 规则**（含 `CPUThrottlingHigh`），
   实测就停在 pending 后再无下文 —— 等于装饰。
3. **没有 deadman's switch**：`Watchdog` 与业务告警共用同一个 n8n webhook、同一个故障域；
   `repeat_interval: 12h` 意味着 n8n 挂掉后最长 12 小时才可能有人注意到"心跳没了"——
   而心跳本身也是经 n8n 发的，一起消失。

### 6.3 历史失败是真实的（不是抖动）

```
alertmanager_notifications_total{integration="webhook"}        = 4513
alertmanager_notifications_failed_total{reason="other"}        = 2883
alertmanager_notifications_failed_total{reason="serverError"}  = 1508
400 行日志里 Notify attempt failed                              = 372 条
```

日志里的目标 IP 是 `104.21.18.107:443` / `172.67.181.153:443`（Cloudflare）——
说明当时 webhook 指向的是一条**公网 Cloudflare 隧道**（n8n 命名空间里那个 `cloudflared` 现在 0 副本）。
失败信息是 `notify retry canceled after 15 attempts: read: connection reset by peer`，
即重试 15 次后丢弃。2026-11-11T12:58:43 配置被重新加载成集群内地址 `n8n-svc.n8n.svc.cluster.local:5678`，
现在实测 POST 返回 `{"message":"Workflow was started"}`。

也就是说：**告警链路曾经依赖一条公网隧道，隧道死了以后所有 critical 告警在 15 次重试后全部丢弃，而没有任何人知道** ——
这正好证明了为什么需要 §6.2 第 3 点的 deadman's switch。

**复核更正（opencode 说"没有通知失败自监控"）：**不准确。规则里有
`AlertmanagerFailedToSendAlerts`、`AlertmanagerClusterFailedToSendAlerts`（各 2 条）、`AlertmanagerFailedReload`。
真正的问题是：**这些告警本身也走同一条坏掉的 webhook**，所以链路断了它会跟着一起哑——自监控存在但与被监控对象同命运。

### 6.4 抑制规则

```yaml
- source: severity=critical  target: severity=~warning|info   equal: [namespace, alertname]
- source: severity=warning   target: severity=info            equal: [namespace, alertname]
- source: alertname=InfoInhibitor  target: severity=info      equal: [namespace]
- target: alertname=InfoInhibitor                             # 无 source_matchers = 任何告警都抑制它
```

问题：`equal` 用 `namespace + alertname`，对基础设施类故障过窄——一个节点挂了，
`KubeNodeNotReady`（ns 空）与 `KubePodNotReady`（ns=compassio）不会互相抑制，一次宿主机故障会打出几十个 group。
反过来同一 ns、同名不同原因的告警会互相吞。建议基础设施类单独一条 inhibit，`equal` 换成 `node`/`instance`。

---

## 7. 修复顺序

**P0（今天就该做，都不涉及改代码）**
1. `Watchdog` 独立路由到集群外心跳（healthchecks.io / 另一台机器），并配"缺失即告警"。
2. 把 critical 与 warning 拆成两条终止路由（critical→wecom，warning→n8n），末条 `continue: false`。
3. 修 §4 里 14 条真失效规则中影响最大的 4 条：Tekton×2、Memcached、KubeletServerCert。
4. 补 `EtcdSnapshotStale`、`ArgoCDAppDegraded`、`LokiCanaryLogLoss`、`MetricsServerDown`（都有现成指标）。

**P0.5（一条改动救回 4 条 critical）**
4.5 给 `prometheus-kube-state-metrics` 的 Service 加 8081 端口 + ServiceMonitor 加 `metrics` endpoint
   （实测 8081 上有 69 条 `kube_state_metrics_list_total` series），KSM 的 2 条规则立即复活，另 2 条按需删除。

**P1**
5. 采 ceph-csi 指标（PodMonitor → csi sidecar 的 `http-metrics` 端口），再加 `CephRBDVolumeErrors`。
   同时给 node-exporter 开 mdadm / systemd / bonding 三个收集器（或无该硬件就删对应规则）。
6. 补 Cilium 深度告警（bpf map 压力、endpoint not-ready、hubble 丢事件）。
7. 补 CNPG / oauth2-proxy / wecom-adapter。
8. 修 §4 的"空操作"4 条（`unless` 用不存在的指标）。

**P2**
9. 删 §4 里死得其所的规则（KSM 自监控 4 条、remote write、systemd、RAID/bonding、OtelDemo）——
   留着会让下一个人以为覆盖到了。
10. info 级告警明确产品定位：要么日报通道，要么删掉，别让它停在 pending 当装饰。
11. inhibit 维度重构；静默加 owner+到期时间。

---

## 8. 复现命令

```bash
# 规则清单与 severity 分布
kubectl -n monitoring get prometheusrule -o json | jq '[.items[].spec.groups[].rules[] | select(.alert)] | length'
# Prometheus 实际加载状态
kubectl get --raw "/api/v1/namespaces/monitoring/pods/prometheus-prometheus-prometheus-0:9090/proxy/api/v1/rules?type=alert"
# 指标是否存在（换 <metric>）
kubectl get --raw "/api/v1/namespaces/monitoring/pods/prometheus-prometheus-prometheus-0:9090/proxy/api/v1/query?query=<metric>"
# Alertmanager 实际生效的配置（不是 CR）
kubectl get --raw "/api/v1/namespaces/monitoring/pods/alertmanager-prometheus-alertmanager-0:9093/proxy/api/v2/status" | jq -r .config.original
# 送达失败
kubectl get --raw "/api/v1/namespaces/monitoring/pods/prometheus-prometheus-prometheus-0:9090/proxy/api/v1/query?query=alertmanager_notifications_failed_total"
kubectl -n monitoring logs alertmanager-prometheus-alertmanager-0 -c alertmanager --tail=400 | grep -c "Notify attempt failed"
```

---

## 9. opencode 交叉复核记录

用 `opencode run` 跑了三节（模型 `opencode-go/deepseek-v4.1-flash`，附件 5–9KB）：
送达链路、覆盖缺口、26 条失效规则定性。它的结论**逐条复核**如下——凡与实测不符的都以实测为准。

| opencode 主张 | 实测 | 结论 |
|---|---|---|
| 两条子路由条件相同且都 continue:true → severity 分级失效 | 配置原文确认 | ✅ 采纳 |
| info/none 结构性收不到（InfoInhibitor + 默认路由） | 规则 7 条 info；InfoInhibitor 常驻 firing + inhibit 抑制 info | ✅ 采纳 |
| 没有 deadman's switch，Watchdog 与业务共用 n8n | 配置确认；Watchdog severity=none 落默认 receiver | ✅ 采纳 |
| "没有通知失败自监控" | 实际有 `AlertmanagerFailedToSendAlerts`、`AlertmanagerClusterFailedToSendAlerts` | ❌ **复核更正**：有，但它们也走同一条坏 webhook，所以等于没有 |
| "failed 4391 ≥ total 4513" | 4391 < 4513，且两个计数窗口不一致（失败含重试） | ❌ 复核更正：方向对，算式错 |
| Tekton 修法用 `_duration_seconds_count{status="failed"}` | 实测该指标带 status（success 有值） | ✅ 可用（`_total{status}` 亦可） |
| KSM 规则可"先抓 telemetry 8081 再保留" | **实测 8081 上有 69 条 `kube_state_metrics_list_total`**，Service 只暴露 8080 | ✅ 采纳，且这是一条改动救 2 条 critical 的高性价比修复 |
| kubelet 证书规则可改 `kubelet_certificate_manager_server_expiration_renew_errors` | 该名 0 series | ❌ 复核更正：新旧名都没有，只能删 |
| `traces_span_metrics_calls_total` 是正确名 | 0 series（otel 没接 spanmetrics） | ❌ 无法验证，按"没有数据源"处理：删规则 |
| 6 节点同宿主机应有"相关性故障"告警 | 拓扑确认（6 VM 同 PVE） | ✅ 采纳为新规则第 1 条 |
| CephRBDVolumeStatsMissing 用 kubelet_volume_stats 兜底 | 表达式可求值，但实测命中 1 条（cicd 的 PVC 无 volume stats） | ⚠️ 可用但会误报，需加"PVC 已 Bound 且 Pod Running"限定 |
| `argocd_app_info{job="argocd"}` | 实际 job 标签是 `argocd/argocd` | ❌ 复核更正：label 写错，规则会空转 |
| `absent(kubelet_certificate_manager_server_ttl_seconds)` 作为"监控失明"告警 | 该指标永远不存在 → 永久 firing | ❌ 不能这么做，应写"指标族消失"要用别的方式（如 exporter 版本断言） |

> 过程记录：`glm-5.3` 挂两个 60KB 附件跑 30 分钟零输出；`deepseek-v4.1-flash` 遇到 35–60KB 附件同样卡死。
> **附件控制在 10KB 以内、单次只给一个问题，就能稳定产出**（这三次成功都是这个规模）。
