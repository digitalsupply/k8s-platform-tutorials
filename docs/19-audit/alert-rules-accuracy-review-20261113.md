# K8s 集群告警规则全面性与准确性评审

> 评审时间：2026-11-13 06:30 UTC（14:30 CST）  
> 评审对象：`monitoring`、`compassio`、`deeptutor` 三个命名空间下的 44 个 `PrometheusRule`，共 248 条 alerting rule（232 个唯一告警名）；Prometheus v3.11.2、Alertmanager v0.32.0；6 节点集群。  
> 评审方式：线上 Prometheus/Alertmanager API + `kubectl` 资源盘点 + 14 天告警历史 + Git 规则 + 外部基线。  
> 权威数据源说明：`/root/platform-gitops-public` 是 2026-11-10 的公开镜像，线上实际由内网 `platform-gitops.git` 管理；公开镜像中仍是 Calico 规则，线上已是 Cilium。因此本报告以**线上 API 和线上资源**为准，Git 仅用于对照和发现漂移。

> **与同目录既有审计的关系**：`alert-rules-coverage-20261113.md` 采样更早（40 个 PrometheusRule / 231 条 alert），侧重“哪些指标不存在、哪些该有没有”；本文采样于 2026-11-13 06:30 UTC（44 个 PrometheusRule / 248 条 alert），侧重“自建 100 条规则的全面性、准确性、告警链路与修复路线”。两文互补，冲突处以各自采样时点为准。本文对其中一条结论做了复核更正：`CephPoolNearFull` / `CephPoolCriticallyFull` 在本集群实际不可用，原因是 `ceph_pool_percent_used` 返回 0–1 小数而阈值写成 85/95（见 §4.1），不是“实际可用”。

---

## 0. 执行摘要

**结论：基础层覆盖较好，但整体还达不到“全面、准确”。**

- **规则数量不少，但存在硬错误**：248 条规则中，自建规则 100 条；发现 **8 条永远不会触发的死规则**、**4 条因单位/公式错误永远无法触发的 Ceph 容量规则**、**1 条长期误报**、**1 条当前正在误报的 CI 规则**。
- **覆盖不均**：K8s 控制面、节点、Ceph、Tempo、Loki、cert-manager 覆盖较深；但 **Kafka broker、CNPG 数据库、Ceph RGW、etcd 备份、oauth2-proxy、ArgoCD 应用健康、用户入口黑盒探测** 基本空白。
- **业务级覆盖缺口明显**：至少 12 个有工作负载的命名空间/组件没有业务级告警，部分只有 Pod Ready 兜底，部分连兜底都没有。
- **告警质量参差**：自建规则中 47/100 没有 `description`，98/100 没有 `runbook`；至少 18 组语义重叠；多条 `sum(...) < 1` 或 `up{...} == 0` 规则在“目标被删除”时反而静默。
- **告警链路曾严重不可靠**：webhook 通道累计 4,521 次通知、4,391 次失败（97%），日志确认集中在 n8n-webhook 到 Cloudflare 的连接重置；2026-11-11 12:58 改回集群内 `n8n-svc` 后最近 24 小时已无失败。
- **监控自身不是高可用**：Prometheus 1 副本、Alertmanager 1 副本、无 Thanos、无外部 dead-man switch；Watchdog 被路由到 n8n，而不是 null receiver。
- **GitOps 存在漂移**：Git values、Helm live values、Alertmanager 实际 Secret 三者不一致；Git 不能完整重建当前告警链路。

**一句话评价：现有体系“广而不全、多而不准”，基础可用，但需要先修 P0 硬错误，再补 P1 关键空白，才能称为生产级“全面准确”。**

---

## 1. 数据与方法

### 1.1 线上数据

| 项目 | 结果 |
|---|---|
| 节点 | 6 个（3 control-plane + 3 worker），v1.35.9 |
| PrometheusRule | 44 个（35 chart + 6 platform + 2 deeptutor + 1 compassio） |
| Alerting rule | 248 条，232 个唯一告警名 |
| 自建规则 | 100 条（platform 83 + compassio 6 + deeptutor 11） |
| 自建规则 severity | warning 61、critical 39 |
| 规则健康度 | 0 条 health 异常、0 条 lastError |
| 抓取目标 | 115 个，全部 up |
| ArgoCD 应用 | 44 个，全部 Synced/Healthy |
| 当前 firing | 4 条（其中 2 条为误报，2 条为 Watchdog/InfoInhibitor 预期告警） |

### 1.2 历史数据

- 使用 Prometheus `query_range` 拉取最近 14 天 `ALERTS{alertstate="firing"}`，按小时统计告警持续时长。
- 使用 `query` 验证关键指标是否存在、单位、标签和当前值。
- 使用 Alertmanager API 和日志验证通知链路。

### 1.3 外部基线

- Prometheus 官方告警实践：症状告警、少而准、控制台/黑盒监控。
- Monitoring Mixins：severity/summary/description/runbook 规范，以及 Ceph、Kubernetes、Loki、Kafka、ArgoCD 等 mixin。
- kube-prometheus runbooks：每条上游告警的处置手册。
- Ceph mixin：基于 `ceph_health_detail` 的健康检查告警。
- ArgoCD metrics：`argocd_app_info` 的 health/sync 标签。
- Strimzi Kafka metrics / CNPG monitoring：broker、consumer lag、数据库指标的采集方式。
- Google SRE Workbook：基于 SLO burn rate 的多窗口告警。

---

## 2. 规则资产盘点

### 2.1 来源分布

| 来源 | PrometheusRule 数 | 告警数 | 说明 |
|---|---:|---:|---|
| kube-prometheus-stack chart | 35 | 148 | 上游规则，质量总体较好 |
| `monitoring` 自建 | 6 | 83 | 平台/中间件/存储/日志/Tempo |
| `deeptutor` | 2 | 11 | 应用回合健康 + Tekton CI |
| `compassio` | 1 | 6 | 应用业务指标 |
| **合计** | **44** | **248** | 232 个唯一告警名 |

### 2.2 自建规则分组

| 文件 | 分组 | 告警数 |
|---|---|---:|
| `app-monitoring-alerts` | cert-manager / tekton / traefik / kafka / storage / cnpg | 9 |
| `bsm-coverage-alerts` | bsm.availability / bsm.coverage | 10 |
| `ceph-cluster-alerts` | ceph.health / mon / osd / pg / capacity | 19 |
| `cluster-wide-alerts` | pod / node / otel-demo / workload / cache | 15 |
| `coverage-gap-alerts` | logging / cni / lb / gitops / default-workloads | 10 |
| `tempo3-alerts` | tempo3.availability / intake / query / storage / pipeline | 20 |
| `compassio-alerts` | compassio.rules | 6 |
| `deeptutor-turn-health` | deeptutor.availability / turns / latency | 8 |
| `tekton-ci-health` | tekton.ci | 3 |

### 2.3 质量统计（自建 100 条）

| 指标 | 数量 | 评价 |
|---|---:|---|
| 有 severity | 100/100 | 好 |
| 有 `for` | 100/100 | 好 |
| 有 `description` | 53/100 | 47 条缺失，通知里只有标题，定位困难 |
| 有 `runbook`/`runbook_url` | 2/100 | 98 条缺失，与 mixin 规范差距大 |
| 有 `dashboard_url` | 0/100 | 无 |
| 语义重复组 | 约 18 组 | 见 4.4 |
| critical 占比 | 39% | 偏高，critical 语义被稀释 |

---

## 3. 全面性评估

### 3.1 覆盖矩阵

评分：★★★★★ 完善；★★★☆☆ 部分覆盖；★☆☆☆☆ 基本空白。

| 领域 | 现有覆盖 | 主要缺口 | 评分 |
|---|---|---|---|
| K8s 控制面 | apiserver、etcd、scheduler、controller-manager、kubelet、KSM、API SLO burn rate | 无 CoreDNS 查询错误/延迟告警；无 metrics-server 专项；无 kube-proxy（Cilium 集群可接受，但 values 仍启用） | ★★★★☆ |
| 节点 | CPU、内存、磁盘、inode、时钟、RAID、conntrack、网络错误、systemd | 无磁盘 SMART/硬件健康；无节点重启/内核告警 | ★★★★☆ |
| 工作负载 | KubePod/KubeDeployment/KubeStatefulSet/KubeDaemonSet/KubeJob/KubeHPA/PDB 等上游规则；多个自建补充 | 自建规则与上游大量重复；多命名空间无业务告警 | ★★★☆☆ |
| 应用（业务） | compassio、deeptutor 有业务指标；china-study-free/open-webui 仅靠 Pod/Deployment 兜底 | oauth2-proxy、headlamp、gitlab-runner、grafana-operator、tekton-operator、ceph-csi-operator 无业务告警 | ★★☆☆☆ |
| 存储 | Ceph health/mon/osd/pg/capacity；PVC filling/errors | 4 条容量规则永不触发；无 `ceph_health_detail` 细分；无 RGW；ceph-csi 无指标；无 Pending PVC；无备份新鲜度 | ★★☆☆☆ |
| 网络 | Cilium agent/operator Ready、MetalLB speaker Ready/重启、Traefik 5xx、节点网络 | 无 Cilium connectivity/health；无 MetalLB speaker metrics/BGP；无 DNS/入口黑盒；无 Traefik target down | ★★★☆☆ |
| 日志 | Alloy Down/覆盖、Loki ingest stalled、Loki canary targets | Loki 仅 1 条告警；无 per-component down、canary、compactor、query 错误；无 S3/RGW 后端告警 | ★★★☆☆ |
| Trace | Tempo3 20 条，覆盖可用性、接收、查询、存储、投递 | 1 条长期误报；1 条 target down 无 absent；部分阈值缺少流量保护 | ★★★★☆ |
| CI/CD & GitOps | Tekton 失败/停滞/卡住；ArgoCD repo-server/redis/重启 | CI 计数器语义误报；2 条 Tekton 死规则；无 ArgoCD 应用 health/sync；无 EventListener；无 GitLab Runner | ★★☆☆☆ |
| 数据服务 | Kafka operator/entity operator；CNPG operator | 无 Kafka broker/consumer lag；无 CNPG 数据库/复制/备份指标 | ★☆☆☆☆ |
| 安全/SSO | cert-manager 证书过期/未 Ready | 无 oauth2-proxy；无 sealed-secrets；无 Issuer/ACME 失败；无入口 TLS 探测 | ★★☆☆☆ |
| 备份/恢复 | 无 | etcd 备份新鲜度/失败/恢复演练；无 Velero | ☆☆☆☆☆ |
| 用户入口 | 无 | 无任何 `Probe`/blackbox；DNS、TLS、路由、登录页故障不可见 | ☆☆☆☆☆ |
| 告警链路自身 | Prometheus/Alertmanager 上游规则；Watchdog；AlertReceiverDown | 单副本；无外部 dead-man switch；Watchdog 进 n8n；wecom-adapter 无告警 | ★★☆☆☆ |

### 3.2 覆盖较好的部分

1. **KubeVIP 规则质量高**：`KubeVIPRestarting`、`KubeVIPLeadershipChurn`、`KubeVIPLeaderNotRenewing` 有阈值推导、根因说明和完整 runbook，是自建规则里最成熟的。
2. **Tempo3 覆盖较完整**：可用性、接收拒绝、摄入停滞、查询错误/延迟、live-store、block flush、Kafka lag、OTel Collector 投递都有覆盖。
3. **Ceph 基础面覆盖**：health、mon quorum、OSD down/out、PG incomplete/degraded/stale、池/集群容量都有规则，方向正确。
4. **规则加载健康**：44 个 PrometheusRule 全部带 `release=prometheus` + `platform.gitops/managed=true`，248 条规则 0 health 异常，115 个 target 全部 up。
5. **双通道投递**：critical/warning 同时进 n8n 和 WeCom，WeCom 适配器当前健康，最近 POST 返回 200。

### 3.3 主要空白（按业务影响排序）

1. **用户入口无黑盒探测**：没有任何 `Probe` CR，也没有 blackbox exporter。Traefik 的 5xx 只能看到“已经到达后端”的请求；DNS 解析失败、证书过期、Ingress 路由错误、登录页 502 都可能完全无声。
2. **数据服务无深度监控**：Kafka 只有 1 个 broker（`my-cluster-single-pool-0`），CNPG 有 2 实例 `pg16-ceph`，但既没有 broker/DB 指标，也没有 broker down、under-replicated、offline partition、consumer lag、复制延迟、连接数、备份失败告警。
3. **Ceph RGW 无告警**：Loki 的 S3 后端是 `http://10.0.0.31:7480`（Ceph RGW，2 个 daemon）。RGW 故障会直接导致日志写入失败，但目前没有任何 RGW 告警。
4. **ceph-csi 实际未被抓取**：`ceph-csi-rbd` 的两个 ServiceMonitor 选择不到任何 Service（该命名空间没有 Service），`up{namespace="ceph-csi-rbd"}` 为空；唯一的 CSI 告警还写错了指标名。
5. **etcd 备份无新鲜度告警**：`etcd-snapshot` CronJob 每小时执行，`kube_cronjob_status_last_successful_time` 指标存在（当前约 39 分钟前成功），但没有“超过 N 小时未成功”的告警，也没有恢复演练。
6. **ArgoCD 应用健康无告警**：`argocd_app_info` 有 43 个应用序列，全部 Synced/Healthy；但没有 `health_status != Healthy` 或 `sync_status != Synced` 告警，GitOps 退化不可见。
7. **oauth2-proxy 无告警**：5 个 Deployment（alloy/headlamp/hubble/tekton/traefik）是多个 UI 的 SSO 入口，没有指标抓取、没有 up/5xx/延迟告警。
8. **其他无业务告警的组件**：open-webui、china-study-free、headlamp、gitlab-runner、grafana-operator、tekton-operator、ceph-csi-operator、cicd EventListener、n8n 工作流失败、wecom-adapter。
9. **PVC Pending/挂载失败无告警**：`kube_persistentvolumeclaim_status_phase` 有 54 个序列，但没有 Pending 超时告警；`KubePersistentVolumeErrors` 只覆盖 Failed 阶段。
10. **无容量预测**：Ceph 池增长、Kafka/CNPG 磁盘、PVC 增长都没有 `predict_linear` 类预测告警。

---

## 4. 准确性评估

### 4.1 P0：永远不会触发 / 长期误报

| # | 规则 | 问题 | 线上证据 | 修复方向 |
|---|---|---|---|---|
| 1 | `CephPoolNearFull`、`CephPoolCriticallyFull` | 指标是 0–1 的小数，阈值却按百分数写 85/95 | `ceph_pool_percent_used` 最大 pool 44 = **0.652**（65.2%），`>85` 相当于 8500%，永不触发 | 改为 `>0.85`/`>0.95`，或直接用 `ceph_health_detail{name="POOL_NEAR_FULL"/"POOL_FULL"}` |
| 2 | `CephClusterNearFull`、`CephClusterCriticallyFull` | 公式 `1 - used/(used+total)` 不是使用率；在 `used<=total` 时结果恒在 0.5~1，阈值 `<0.15`/`<0.05` 永不成立 | 当前 used=119.65GB、total=193.25GB，表达式=**0.6176**，实际使用率 61.9% | 改为 `used/total >0.85`/`>0.95`，或用 `ceph_health_detail` |
| 3 | `CephCSIOperationErrors` | 指标名不存在；且 `increase(csi_sidecar_operations_seconds_count)` 统计的是“所有操作”，不是错误 | 指标列表只有 `csi_operations_seconds_count`（来自 kubelet），没有 `csi_sidecar_*`；ceph-csi 也没有 Service 可抓 | 用 `csi_operations_seconds_count{driver_name="rbd.csi.ceph.com",grpc_status_code!="OK"}`；先给 ceph-csi 建 Service/PodMonitor |
| 4 | `TektonPipelineRunFailed`、`TektonTaskRunFailed` | 指标名不存在 | 实际是 `tekton_pipelines_controller_pipelinerun_total` / `taskrun_total` / `..._duration_seconds_count`，没有 `..._pipelinerun_count` | 用 `_total` + `changes()`/`increase()`，或统一到 `CIPipelineRunFailed` |
| 5 | `MemcachedLimitAboveContainerLimit` | 指标名不存在 | 实际是 `memcached_limit_bytes`；`memcached_limit_maxbytes_bytes` 不存在 | 改为 `memcached_limit_bytes`；同时增加“容器 working set / limit”告警，因为本集群 700MiB < 1GiB，规则即使修好也不会报当前 OOM |
| 6 | `OtelDemoHighErrorRate`、`OtelDemoServiceDown` | 命名空间和指标都不存在 | 没有 `otel-demo` 命名空间；实际指标是 `otel_demo_traces_span_metrics_calls_total` | 改命名空间/指标，或删除；当前 opentelemetry 命名空间没有对应告警 |
| 7 | `DeepTutorTurnStalled`、`DeepTutorStallWarningsFrequent` | 指标不存在，但单测用合成序列“通过” | 指标列表只有 `deeptutor_active_turns`、`turns_finished_total`、`ttft_*`、`turn_event_gap_*`；没有 `deeptutor_stalls_total` / `stall_warnings_total` | 让应用重新暴露指标，或改用 `turns_finished_total{status="stalled"}`；单测必须用真实指标名 |
| 8 | `CIPipelineStalled` | 当前正在误报：deeptutor-cicd 3h54m 前启动、3h32m 前成功完成，告警却在 03:10 触发“72 小时没有新 run” | `increase(tekton_pipelines_controller_pipelinerun_duration_seconds_count[72h])` 返回 0；计数器序列在控制器重启后首次出现时值已经是 1，`increase` 看不到 0→1 | 不要用 `increase` 判断“最近一次运行”；改用 last-success 时间戳、Tekton API/自定义 exporter，或至少用 `changes()` + 序列存在性保护 |
| 9 | `Tempo3LiveStoreClientsLost` | 长期误报：`tempo_querier_livestore_clients` 在所有组件上都是 0；告警已持续约 22 小时 | 12 个 Tempo 组件的该指标全部为 0；而 `tempo_live_store_ready{job="live-store"}` 三个 live-store 都是 1 | 删除或改为 `min(tempo_live_store_ready{job="live-store"}) < 1` / `count(... == 1) < 3` |

> 这 9 类问题中，前 8 条是“规则不会按预期工作”，第 9 条是“规则一直在误报”。它们直接说明：**“规则能加载”不等于“规则能正确触发”**。

### 4.2 P1：语义、阈值、窗口与重复

| # | 规则/问题 | 说明 | 建议 |
|---|---|---|---|
| 1 | `CephPGScrubbingError` | `ceph_pg_scrubbing==1` 表示“正在 scrub”，不是“scrub 报错”；且它是 per-pool 计数，只有恰好等于 1 才命中 | 改用 `ceph_health_detail{name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"} == 1`，或 `ceph_pg_inconsistent` / `ceph_pg_failed_repair` |
| 2 | `CephClusterUnhealthy` | `!=0` 把 HEALTH_WARN 和 HEALTH_ERR 都判成 critical，容易把 nearfull、clock skew 等 warning 升级成 page | `==2` critical、`==1` warning；或使用 `ceph_health_detail{severity="HEALTH_ERR"}` |
| 3 | `CephOSDHighCommitLatency` | `avg(...)` 会被其他健康 OSD 平均掉，单个慢盘可能永远不报 | `max by (ceph_daemon) (ceph_osd_commit_latency_ms) > 50`，并考虑 apply latency |
| 4 | `CephTooFewOSDs` | 硬编码 `<3`；当前 6 个 OSD、3 副本，等到只剩 2 个才报已经太晚 | 按副本数/故障域判断，或用 `ceph_health_detail{name="OSD_DOWN"/"OSD_HOST_DOWN"}`、`count(up==0)/count(up) >= 0.1` |
| 5 | `CephMGRMetricsMissing` + `CephClusterHealthUnknown` + `CephMGRUnreachable` | 同一个 Ceph 监控失明会同时触发 3 条 critical；语义重复 | 合并为 1 条 `CephMetricsMissing`，其余用 inhibition 抑制 |
| 6 | `KubeVIPLeadershipChurn` | `max_over_time[24h]` 让一次 leader 切换持续告警 24 小时；历史上 49 小时处于 firing | 改为 `changes(kube_lease_owner{...}[1h]) > 0` 或 `resets`，把“历史切换”和“正在churn”分开 |
| 7 | `KubePodCriticalComponentHighRestart` | 用累计 `restarts_total > 20`，Pod 一旦超过 20 次就永久告警，即使早已稳定 | 改用 `increase(...[1h])` 或 `resets(...[1h])` |
| 8 | `CIPipelineRunFailed` | 用 `increase(..._count{status="failed"}[1h])`；失败计数器序列首次出现时可能从 1 开始，`increase` 可能为 0，漏掉首次失败 | 用 `max_over_time(...[1h]) > 0 unless max_over_time(...[1h] offset 1h) > 0`，或 `changes(_total{status="failed"}[1h]) > 0` |
| 9 | `CIPipelineRunStuck` | `tekton_pipelines_controller_running_pipelineruns > 0` 没有 pipeline 标签，无法定位；2 小时也可能误伤正常长构建 | 用 per-pipeline 的运行时长指标，或至少把 `for` 调到覆盖最长正常构建 |
| 10 | `Tempo3QueryErrorRateHigh` | 用“错误数/秒 > 0.1”，不是错误率；流量变化时阈值失真 | 改为错误率 = 5xx / total，并加最小请求量保护 |
| 11 | `Tempo3TargetDown` | `up{...} == 0`；如果 ServiceMonitor/PodMonitor 被删，序列消失，告警静默 | 加 `or absent(up{job=~"...",namespace="logging"})` |
| 12 | `TraefikHigh5xxRate`、`CompassioHttpLatencyHigh`、`DeepTutorTTFTSlow`、`Tempo3QueryLatencyHigh` | 没有最小请求量/样本量保护，低流量时 1 个 5xx 或 1 个慢请求就能触发 | 加 `sum(rate(...)) > 0.1` 或 `increase(count[10m]) >= 20` |
| 13 | `CertManagerCertificateExpiringSoon` | 没有 `>0` 保护，证书已过期时“即将过期”和“已过期”会同时存在 | 加 `and (certmanager_certificate_expiration_timestamp_seconds - time() > 0)` |
| 14 | `LokiIngestStalled` | write/backend/read 任一 down 都会触发“ingest stalled” critical；read 挂并不影响写入 | 拆成 `LokiWriteDown`/`LokiBackendDown`/`LokiReadDown`，或至少改名/降级 |
| 15 | `sum(...) < 1` 类规则 | n8n、nfs-provisioner、MetalLB speaker、kube-vip、ArgoCD Redis、Kafka entity operator、Tekton interceptors、Cilium agent/operator：**序列消失时返回空，不会触发** | 统一加 `absent(...) or sum(...) < 1`，或改用 Deployment/DaemonSet 的 desired/ready 指标 |
| 16 | 重复告警 | 至少 18 组：PodCrashLooping vs KubePodCrashLooping vs PodCrashLoopingFixed；PodNotReady vs KubePodNotReady；PodOOMKilled vs KubeContainerOOMKilled；NodeHighCPU vs NodeCPUHighUsage；NodeHighMemory vs NodeMemoryHighUtilization；NodeDiskPressure vs NodeFilesystemSpaceFillingUp；DaemonSetNotFullyScheduled vs KubeDaemonSetNotScheduled；CiliumAgentNotReady vs CoreComponentNotReady；KafkaEntityOperatorDown/KubeVIPDown/GitOpsRedisDown/StorageProvisionerDown/AlertReceiverDown/TektonInterceptorsDown vs CoreComponentNotReady；Tempo3PodNotReady vs PodNotReady；CIPipelineRunFailed vs TektonPipelineRunFailed；CephMGR 三兄弟；KubePodHighRestartCount vs KubePodCriticalComponentHighRestart | 保留上游通用规则，自建只补上游没有的；同一故障只保留一条“症状告警” |
| 17 | 注释质量 | 47/100 无 `description`，98/100 无 `runbook`；大量规则的通知只有一句 summary | 按 mixin 规范补 `summary` + `description` + `runbook_url` + `dashboard_url`；至少 P0/P1 规则先补 |
| 18 | `PodOOMKilled` 注释过时 | 注释说 `kube_pod_container_status_last_terminated_reason` 在当前集群为 0 序列，但实际有 25 个序列 | 更新注释；保留 `PodOOMKilled` 与 `KubeContainerOOMKilled` 中的一条，或明确分工 |

### 4.3 P2：一致性与可维护性

- `NodeHighMemory` 的 summary 用 `instance`，`NodeHighCPU` 用 `node`，通知里节点标识不一致。
- `CephPoolNearFull`/`CriticallyFull` 用 `pool_id`，没有 join `ceph_pool_metadata` 的 pool 名，值班人员需要再查。
- `CephPoolNoSpace` 用 `min(ceph_pool_max_avail)==0`，但当前 15 个池的 `max_avail` 完全相同（12.6GB），它实际是集群级指标，不是池级。
- `CephMonNotInQuorum` 硬编码 `!=3`、`CephTooFewOSDs` 硬编码 `<3`，集群拓扑变化后会误报/漏报。
- `CoreComponentNotReady` 的命名空间列表包含并不存在的 `knative-serving`/`knative-eventing`/`knative-operator`，同时漏掉 12+ 个实际命名空间，像是从模板复制后未收口。
- `DefaultNS*` 只覆盖 `default`，但 `default` 当前没有工作负载；真正有业务的 `china-study-free`、`open-webui` 等反而没有。
- `DaemonSetNotFullyScheduled` 只覆盖 `kube-system|logging`，漏掉 `ceph-csi-rbd` nodeplugin、`metallb-system` speaker；上游 `KubeDaemonSetNotScheduled` 已覆盖全命名空间，重复且不完整。

### 4.4 当前 firing 解读（06:36 UTC）

| 告警 | 状态 | 解读 |
|---|---|---|
| `Tempo3LiveStoreClientsLost` | firing，约 22h | **误报**，指标恒 0；live-store ready 实际为 1 |
| `CIPipelineStalled` | firing，03:10 起 | **误报**，deeptutor-cicd 03:04 刚成功完成 |
| `Watchdog` | firing | 预期；但被路由到 n8n，而不是 null/dead-man switch |
| `InfoInhibitor` | firing | 预期；同样进默认 n8n |
| `CPUThrottlingHigh`（config-reloader/alloy） | pending，info | 低优先级；可观察，不建议 page |

### 4.5 最近 14 天噪声排行

| 告警 | 处于 firing 的小时数 | 判断 |
|---|---:|---|
| Watchdog | 311/336 | 预期，但不应进业务通道 |
| `Tempo3LiveStoreClientsLost` | 247 | 长期误报 |
| `CephClusterHealthUnknown` | 167 | Ceph 指标缺失约 7 天，规则正确但未及时处置 |
| `CephMGRMetricsMissing` | 167 | 同上，且与上一条重复 |
| `CIPipelineStalled` | 129 | 反复误报，当前仍在误报 |
| `PodOOMKilled` | 99 | `loki-chunks-cache/memcached` 过去 14 天累计 99h；当前 Pod 21h 前重建后暂未再触发，但防护规则是死的 |
| `InfoInhibitor` | 92 | 预期 |
| `DeepTutorActiveTurnsStuck` | 72 | 11-04~11-07 连续 72h，值得复盘是真实卡死还是指标未归零 |
| `Alertmanager*FailedToSendAlerts` | 70–71 | n8n webhook 故障，已修复 |
| `KubeProxyDown` | 57 | 历史规则；Cilium 集群无 kube-proxy，当前规则已移除，但 Git values 仍启用 kubeProxy |
| `KubeVIPLeadershipChurn` | 50 | 24h 回看导致“一次切换、长时间告警” |
| `NodeHighMemory` | 13 | 需结合节点确认是否真实 |
| `KubeAggregatedAPIDown` | 10 | `v1beta1.metrics.k8s.io`，metrics-server 不稳定会影响 HPA |
| `CIPipelineRunFailed` | 5 | 有失败，但当前表达式可能漏首次失败 |

---

## 5. 告警链路与运维

### 5.1 路由

当前 Alertmanager：

- 全局 receiver：`n8n-webhook`
- `severity=critical|warning` → n8n + WeCom，两个都 `continue: true`
- `group_by: [alertname, namespace, severity]`
- `group_wait: 30s`、`group_interval: 5m`、`repeat_interval: 12h`
- `Watchdog`/`InfoInhibitor` 的 `severity=none` 不匹配业务路由，落到默认 n8n

问题：

1. **没有按严重级别分流**：critical 和 warning 都进同两个通道，没有电话/值班升级通道。
2. **没有 null receiver**：Watchdog、InfoInhibitor 每 12 小时进 n8n，属于噪声；标准做法是 Watchdog → null + 外部 dead-man switch。
3. **没有团队级 AlertmanagerConfig**：集群里 0 个 `AlertmanagerConfig`，所有路由全局；后续多团队会互相打扰。
4. **抑制规则太弱**：只有“同 namespace、同 alertname 的 critical 抑制 warning/info”，没有依赖链抑制（NodeDown 抑制 Pod 告警、Ceph 健康抑制 PG、TargetDown 抑制应用、Prometheus 故障抑制全部）。
5. **单副本**：Prometheus 1 副本、Alertmanager 1 副本，监控栈自身是单点；`AlertmanagerClusterDown` 这类规则在单副本下意义有限。

### 5.2 投递可靠性

- 历史上 n8n webhook 走 Cloudflare 域名，Alertmanager 日志持续出现 `connection reset by peer`。
- `alertmanager_notifications_total{integration="webhook"}` = **4,521**；`failed_total` 中 `other`=2,883、`serverError`=1,508，合计 **4,391 次失败（约 97%）**；日志中失败集中在 `n8n-webhook`。
- 2026-11-11 12:58 改回集群内 `http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts` 后，最近 24 小时无 notify 失败；n8n `/healthz` 返回 `{"status":"ok"}`。
- WeCom 适配器同期收到 POST 并返回 200，说明 WeCom 通道是好的；但如果 only-n8n 的告警（如 Watchdog）失败，不会有人知道。

**结论：链路已恢复，但历史上 3 天左右的告警不可达，且没有外部 dead-man switch 兜底。**

### 5.3 GitOps/配置漂移

| 项目 | Git `values.yaml` | Helm live values | Alertmanager 实际 Secret |
|---|---|---|---|
| n8n URL | `https://example.invalid/n8n-webhook` | `https://n8ntrace.ccwu.cc/webhook/k8s-alerts` | `http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts` |
| inhibit_rules | 无 | 有 | 有 3 条 |
| kubeProxy | `enabled: true` | `enabled: true` | 集群是 Cilium，无 kube-proxy target |
| 规则内容 | 公开镜像仍是 Calico | 线上是 Cilium | — |

这说明：

1. **`values.yaml` 不是当前 alertmanager 配置的事实源**；“source of truth”声明不成立。
2. Helm release 的 values 与 Alertmanager Secret 又不一致（n8n URL 两种）。
3. 公开 Git 镜像与线上规则不一致（Calico vs Cilium），不能用于灾后重建。
4. 重新 `helm upgrade` 或重新 apply values，可能把 `KubeProxyDown` 误报、`example.invalid` webhook 带回来。

### 5.4 规则治理

- `ruleSelector` 要求 `release=prometheus` + `platform.gitops/managed=true`；44 个规则都满足，当前加载正常。
- 但如果团队新增 PrometheusRule 忘记打标签，**规则会静默不加载**，没有任何告警/CI 检查。
- 没有 `promtool check rules`/`promtool test rules` 的统一 CI；deeptutor 有单测，但单测使用合成序列，无法发现“指标名不存在”（如 `deeptutor_stalls_total`）。
- 没有“规则引用的指标在目标集群存在”的校验；这正是 8 条死规则长期未被发现的原因。

---

## 6. 外部对标

### 6.1 Prometheus 官方告警实践

Prometheus 官方建议：

- 告警要少而准，优先告“症状”（用户可见的延迟、错误、饱和度），而不是每一个可能的原因。
- 告警要链接到控制台/runbook，便于定位。
- 对批处理任务，按“最近一次成功是否足够新”告警，至少覆盖 2 个完整周期。
- 要有 metamonitoring 和外部黑盒监控，验证“PushGateway → Prometheus → Alertmanager → 邮件”整条链路。

对照本集群：

- 因果告警偏多，用户入口症状告警几乎为零。
- 批处理（etcd 备份）没有“最近成功时间”告警。
- 没有外部黑盒监控；Watchdog 也没有外部 dead-man switch。
- 98% 自建规则没有 runbook。

### 6.2 Monitoring Mixins 规范

Mixins 建议：

- `severity` 只用 critical/warning/info，语义分别是“立即处理/尽快处理/仅记录”。
- `summary` 和 `description` 必填，`runbook_url` 推荐。
- 告警名 CamelCase，同一 mixin 使用统一前缀。

对照本集群：

- severity 都有，但 critical 占 39%，且多条是同一故障的重复/因果告警，critical 被稀释。
- 47% 缺 description，98% 缺 runbook。
- 命名基本一致，但 `NodeHighMemory` 用 instance、`NodeHighCPU` 用 node，通知字段不统一。

### 6.3 Ceph mixin

Ceph 官方 mixin 的做法是**围绕 `ceph_health_detail` 的具名健康检查**告警，例如：

- `CephOSDDown`、`CephOSDNearFull`、`CephOSDFull`
- `CephPoolNearFull`、`CephPoolFull`
- `CephPGsDamaged`（`PG_DAMAGED|OSD_SCRUB_ERRORS`）
- `CephSlowOps`、`CephDaemonCrash`
- `CephMgrPrometheusModuleInactive`
- `CephObjectMissing`（`OBJECT_UNFOUND`）
- `CephDeviceFailurePredicted`（`DEVICE_HEALTH`）
- `CephOSDFlapping`、`CephNodeNetworkPacketDrops/Errors`

对照本集群：当前只用了 `ceph_health_status`、`ceph_osd_up`、`ceph_pg_*` 等少量指标，**没有用 `ceph_health_detail` 的具名检查**，导致 nearfull/full、slow ops、device health、unfound、daemon crash 等关键场景缺失；已有的容量规则还写错了单位/公式。

### 6.4 ArgoCD / Strimzi / CNPG

- ArgoCD 官方暴露 `argocd_app_info{sync_status,health_status}`；本集群有 43 条序列但没有任何应用健康/同步告警。
- Strimzi 官方提供 Kafka metrics、JMX Exporter、Kafka Exporter 和示例告警；本集群只有 operator/entity operator 告警，没有 broker/consumer lag 指标。
- CNPG 官方提供 PodMonitor 和 `cnpg_collector_*` 指标；本集群 `count(cnpg_collector_up)` 为空，数据库层完全不可见。

### 6.5 Google SRE：SLO burn rate

Google SRE Workbook 建议对关键用户旅程使用**多窗口、多燃烧率**的 SLO 告警（如 1h/5m、6h/30m），而不是对每个组件原因单独 page。

对照本集群：`KubeAPIErrorBudgetBurn` 已用于 apiserver，但业务侧（DeepTutor、Compassio、ChinaStudyFree、Open WebUI）没有 SLO；现有应用告警是 P95/错误率阈值，不是 SLO burn rate。

---

## 7. 修复路线图

### P0（本周内，先让规则“可信”）

1. **修 8 条死规则**：`CephCSIOperationErrors`、`TektonPipelineRunFailed`、`TektonTaskRunFailed`、`MemcachedLimitAboveContainerLimit`、`OtelDemoHighErrorRate`、`OtelDemoServiceDown`、`DeepTutorTurnStalled`、`DeepTutorStallWarningsFrequent`。
2. **修 4 条 Ceph 容量规则**：
   ```promql
   # 集群使用率
   ceph_cluster_total_used_bytes{cluster="ceph-prod"}
     / ceph_cluster_total_bytes{cluster="ceph-prod"} > 0.85

   # 池使用率（本集群该指标是 0-1 小数）
   max by (pool_id) (ceph_pool_percent_used{cluster="ceph-prod"}) > 0.85
   ```
   更推荐直接使用 Ceph 健康检查：
   ```promql
   ceph_health_detail{cluster="ceph-prod",name=~"POOL_NEAR_FULL|POOL_FULL|OSD_NEAR_FULL|OSD_FULL"} > 0
   ```
3. **修 `CephPGScrubbingError`**：
   ```promql
   ceph_health_detail{cluster="ceph-prod",name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"} == 1
   ```
4. **修 `Tempo3LiveStoreClientsLost`**：
   ```promql
   min(tempo_live_store_ready{namespace="logging",job="live-store"}) < 1
   ```
5. **修 `CIPipelineStalled`**：停止用 `increase()` 判断“最近一次运行”；改用 last-success 时间戳/自定义 exporter，或先降级为 info 并加人工确认。
6. **统一补 absent 保护**：所有 `up{job=...} == 0` 和 `sum(...) < 1` 规则加 `or absent(...)`，避免“删除 target/ServiceMonitor 反而静默”。
7. **补关键空白**：Kafka broker、CNPG、Ceph RGW、etcd 备份新鲜度、oauth2-proxy、ArgoCD 应用健康、Pending PVC。
8. **补用户入口黑盒**：部署 blackbox exporter + `Probe`，覆盖 `deeptutor.xyz`、`compassio.xyz`、`studyfree.xyz`、`cngpt.ccwu.cc`、`n8n.zeroth.com`、Grafana、ArgoCD、Headlamp；告警 `probe_success==0` 和证书 `<14d`。
9. **修投递链路**：Watchdog/InfoInhibitor → `null` receiver；增加外部 dead-man switch；wecom-adapter 加 down 告警；critical 单独路由到值班通道。
10. **HA**：Alertmanager 至少 2 副本；Prometheus 至少 2 副本或接受“单副本 + 外部 watchdog”；补 `externalLabels.cluster`。

### P1（两周内，减少噪声、补齐语义）

1. **去重**：保留上游通用规则，自建只补上游没有的；重点清理 Pod/Node/Ceph/CI 的 18 组重叠。
2. **Ceph 全面对齐 mixin**：用 `ceph_health_detail` 补 `OSD_DOWN`、`OSD_NEAR_FULL`、`OSD_FULL`、`POOL_NEAR_FULL`、`POOL_FULL`、`PG_DAMAGED`、`SLOW_OPS`、`RECENT_CRASH`、`OBJECT_UNFOUND`、`DEVICE_HEALTH`、`MON_DOWN`、`MON_DISK_LOW`。
3. **Tempo/Loki 语义修正**：Tempo 错误率改成比例 + 最小流量；Loki 拆分 write/backend/read，补 canary、compactor、S3 错误。
4. **CI 指标修正**：用 `_total` + `changes()` 或 last-success 时间戳；`CIPipelineRunStuck` 加 pipeline 维度。
5. **阈值校准**：`CephClusterUnhealthy` 区分 WARN/ERR；`CephOSDHighCommitLatency` 用 max；`CephTooFewOSDs` 按副本/故障域；低流量告警加最小请求量。
6. **注释补齐**：P0/P1 规则补 description/runbook/dashboard；至少让值班人员能从通知直接跳到排障入口。
7. **GitOps 收口**：把 Alertmanager 实际 Secret、Helm values、n8n URL、inhibit rules 回写到 Git；删除 `example.invalid`；明确 `values.yaml` 为唯一事实源，禁止手工 `--reuse-values` 漂移。
8. **CI 校验**：`promtool check rules` + `promtool test rules` + 指标存在性检查 + 标签 lint + 重复告警名检查。

### P2（一个月内，体系化提升）

1. **SLO 告警**：为 DeepTutor、Compassio、ChinaStudyFree、Open WebUI、ArgoCD、Grafana 定义 SLI/SLO，使用多窗口 burn rate（1h/5m、6h/30m），替代“每个原因都告警”。
2. **容量预测**：Ceph 池增长、Kafka/CNPG 磁盘、PVC 增长用 `predict_linear` 提前 3–7 天告警。
3. **备份恢复**：etcd 快照新鲜度 + 定期恢复演练；CNPG 备份失败/过期；RGW 对象存储可用性。
4. **团队路由**：给规则加 `team`/`service` 标签，按团队 AlertmanagerConfig 路由；critical 进电话/值班，warning 进企微，info 进 null/工单。
5. **长期存储**：Thanos/远程写，保留 90 天以上，支持容量趋势和事故复盘。

---

## 8. 附录

### 8.1 死规则清单（8 条）

| 规则 | 原因 |
|---|---|
| `CephCSIOperationErrors` | `csi_sidecar_operations_seconds_count` 不存在 |
| `TektonPipelineRunFailed` | `tekton_pipelines_controller_pipelinerun_count` 不存在 |
| `TektonTaskRunFailed` | `tekton_pipelines_controller_taskrun_count` 不存在 |
| `MemcachedLimitAboveContainerLimit` | `memcached_limit_maxbytes_bytes` 不存在 |
| `OtelDemoHighErrorRate` | 命名空间 `otel-demo` + 指标 `traces_spanmetrics_calls_total` 不存在 |
| `OtelDemoServiceDown` | 命名空间 `otel-demo` 不存在 |
| `DeepTutorTurnStalled` | `deeptutor_stalls_total` 不存在 |
| `DeepTutorStallWarningsFrequent` | `deeptutor_stall_warnings_total` 不存在 |

### 8.2 永不触发/长期误报清单

| 规则 | 类型 |
|---|---|
| `CephPoolNearFull` | 单位错误，永不触发 |
| `CephPoolCriticallyFull` | 单位错误，永不触发 |
| `CephClusterNearFull` | 公式错误，永不触发 |
| `CephClusterCriticallyFull` | 公式错误，永不触发 |
| `Tempo3LiveStoreClientsLost` | 长期误报（约 22h） |
| `CIPipelineStalled` | 当前误报（成功 run 后仍 firing） |

### 8.3 推荐新增告警（按优先级）

**P0**

- `KafkaBrokerDown`、`KafkaUnderReplicatedPartitions`、`KafkaOfflinePartitions`、`KafkaActiveControllerCount`、`KafkaConsumerLag`
- `CNPGClusterUp`、`CNPGReplicationLag`、`CNPGBackupFailed`、`CNPGDiskUsage`
- `CephRGWDown`、`CephRGWRequestErrors`
- `EtcdBackupStale`（`time() - kube_cronjob_status_last_successful_time > 7200`）
- `ArgoCDAppUnhealthy`、`ArgoCDAppOutOfSync`
- `OAuth2ProxyDown`、`OAuth2ProxyHigh5xx`
- `PVCPendingTooLong`
- `ProbeFailure`、`TLSCertExpiringSoon`
- `WeComAdapterDown`

**P1**

- `CephOSDNearFull`、`CephOSDFull`、`CephPoolFull`、`CephPGsDamaged`、`CephSlowOps`、`CephDaemonCrash`、`CephObjectMissing`、`CephDeviceFailurePredicted`
- `LokiWriteDown`、`LokiBackendDown`、`LokiReadDown`、`LokiCanaryLatency`、`LokiCompactorStale`
- `Tempo3LiveStoreNotReady`、`Tempo3QueryErrorRatioHigh`、`Tempo3MetricsGeneratorDroppedSpans`
- `CoreDNSDown`、`CoreDNSServfailRate`
- `GrafanaDown`、`TektonEventListenerDown`、`GitLabRunnerDown`

### 8.4 参考链接

- Prometheus 告警实践：<https://prometheus.io/docs/practices/alerting/>
- Monitoring Mixins（severity/annotation 规范及 Ceph/Kubernetes/Loki/Kafka/ArgoCD mixin）：<https://monitoring.mixins.dev/>
- Ceph mixin 告警：<https://monitoring.mixins.dev/ceph/>
- kube-prometheus runbooks：<https://runbooks.prometheus-operator.dev/>
- ArgoCD metrics：<https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/>
- Strimzi metrics/告警：<https://strimzi.io/docs/operators/latest/deploying#assembly-metrics-str>
- CloudNativePG monitoring：<https://cloudnative-pg.io/docs/current/monitoring/>
- Google SRE Workbook（SLO burn rate）：<https://sre.google/workbook/alerting-on-slos/>

---

**最终判断**：当前告警体系在“K8s 基础层 + Ceph + Tempo”上有不错的骨架，但准确性存在 P0 硬错误，全面性在数据服务、用户入口、备份、SSO、GitOps 应用健康上明显不足。建议按“先修死规则/误报 → 再补关键空白 → 最后做 SLO 化”的顺序推进；在 P0 完成前，不宜把当前体系称为“全面准确”。
