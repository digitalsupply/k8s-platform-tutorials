# 集群可观测性告警覆盖审计报告
## Prometheus + Alertmanager + n8n 业务面

| 项目 | 值 |
|---|---|
| 审计时间 | 2026-09-30 15:50 (UTC+8) |
| 集群 | `kubernetes-admin@kubernetes` / v1.29.8 / 6 节点 (3 control-plane + 3 worker) |
| 采集栈 | kube-prometheus-stack `83.7.0`（Prometheus Operator v0.90.1 / Prometheus v3.11.2 / Alertmanager v0.32.0） |
| 命名空间 | 24 个 |
| 审计结论 | ❌ **不完整 — 存在 P0 级架构缺陷** |

---

## 1. 执行摘要

整体判定为 **"基础设施层覆盖良好，业务面完全裸奔，告警管道自身是单点"**。

三条主线结论：

1. **基础设施/节点层覆盖扎实** — 187 条告警中 149 条（80%）来自 kube-prometheus-stack 上游，覆盖 etcd / apiserver / kubelet / scheduler / node-exporter / kube-proxy / CoreDNS / KSM / kube-state-metrics，并包含 apiserver 的 SLO 燃尽率（burnrate）机制。`Tempo3` 组件另有 20 条定制告警，设计质量高（每条含 summary+description+runbook，路由按 namespace/job 细分）。

2. **业务面 n8n 覆盖率为 0** — `n8n` 命名空间**没有任何** ServiceMonitor / PodMonitor / Probe，Prometheus 中 `up{namespace="n8n"}` 返回空集。n8n 自身也未开启任何 metrics 端点。**没有任何一条针对 n8n 的告警，没有一个业务 SLI/SLO。**

3. **告警投递链是架构级单点（最严重）** — Alertmanager 全局唯一 receiver 指向 **n8n 自己**。n8n 宕机 = 全集群告警静默丢失。且该链路在 2026-09-27~28 期间实测**失败率 93.9%（2160/2299）**，导致 `excessive retries creating aggregation group`，告警被直接丢弃。

> **核心风险**：这是"用被监控对象承载告警出口"的自指结构 —— n8n 是告警的**唯一出口**，而 n8n 恰恰是全集群观测性最差的组件。

---

## 2. 资产盘点

### 2.1 监控 CR 清单

| 类型 | 数量 | 说明 |
|---|---|---|
| `PrometheusRule` | **38** | 全部位于 `monitoring` 命名空间，无业务方自带规则 |
| `ServiceMonitor` | **22** | 覆盖 7 个命名空间 |
| `PodMonitor` | **9** | 覆盖 9 个命名空间 |
| `Probe` | **0** | ❌ 无任何主动/黑盒探测 |
| `AlertmanagerConfig` | **0** | ❌ 无命名空间级路由收件人 |
| `ScrapeConfig` | 0 | 未使用 |

### 2.2 告警规则来源分布

| 来源 | 告警数 | 占比 | 评价 |
|---|---|---|---|
| 上游 kube-prometheus-stack (35 个 CR) | 149 | 80% | ✅ 成熟，含 apiserver SLO 燃尽率 |
| `tempo3-alerts` (定制) | 20 | 11% | ✅ 质量最佳，有 runbook |
| `app-monitoring-alerts` (定制) | 10 | 5% | ⚠️ 含 4 条死规则 |
| `cluster-wide-alerts` (定制) | 8 | 4% | ⚠️ 含 2 条死规则 + 与上游重复 |
| **合计** | **187** | 100% | |

### 2.3 采集目标

`Prometheus` 实例：`replicas=1`、`shards=1`、`retention=5d`、`retentionSize=30GB`、`evaluationInterval=30s`、`scrapeInterval=30s`。

当前实况：**92 个抓取目标，0 个 down**。共 53 个 job。

---

## 3. 覆盖维度矩阵

| 维度 | 状态 | 依据 |
|---|:---:|---|
| 节点（CPU/内存/磁盘/网络/conntrack/RAID/时钟/bonding） | ✅ 完整 | 33 条 node-exporter 告警 |
| etcd | ✅ 完整 | 14 条（成员、leader、fsync、碎片率、配额） |
| kube-apiserver | ✅ 完整 | 40 条 + 4 条 SLO 燃尽率 |
| kubelet / scheduler / controller-manager | ✅ 完整 | 上游全套 |
| CoreDNS / kube-proxy | ⚠️ 仅 down 检测 | `KubeProxyDown` 1 条，无延迟/错误率 |
| 容器资源 / OOM / 重启 | ✅ 有 | 但见 §6.1 重复问题 |
| 工作负载状态（Deploy/STS/DS/Job/HPA/PDB） | ✅ 完整 | 上游 `prometheus-kubernetes-apps` |
| 存储（PV 填充、inodes、CSI 错误） | ❌ 严重缺失 | Ceph 集群 0 指标，见 §5.3 |
| 网络入口（Traefik 5xx） | ⚠️ 仅 1 条 | 无延迟/连接数/证书/请求量 SLI |
| **n8n 业务面** | ❌ **完全缺失** | 0 指标、0 告警、0 探测 |
| **Loki 日志栈** | ❌ **完全缺失** | 0 告警、0 采集 |
| **PostgreSQL / CNPG 数据面** | ❌ **完全缺失** | `pg_*` 0 序列 |
| **端到端/外部可用性** | ❌ **完全缺失** | 0 Probe、无 blackbox-exporter |
| **业务 SLO / 错误预算** | ❌ **完全缺失** | 仅 apiserver 有 |

---

## 4. n8n 业务面专项审计

### 4.1 n8n 资产现状

```
n8n 命名空间
├── Deployment/n8n            1/1  n8nio/n8n:2.14.2   ← 业务主体
├── Deployment/cloudflared    1/1  cloudflared:latest ← 公网隧道
├── Service/n8n-svc          ClusterIP 10.109.202.66:5678
├── Ingress/n8n-ingress      traefik  n8n.zeroth.com → 10.0.0.252:80
├── PVC/n8n-pvc              5Gi  ceph-rbd-sc (Retain)
├── Secret/n8n-db-secret     DB 用户/密码/加密密钥
└── Secret/cloudflared-secret Cloudflare Tunnel 凭据
```

n8n 数据后端：`pg16-ceph-rw.cnpg-system.svc.cluster.local:5432/n8n`（CloudNativePG 集群 `pg16-ceph`，2 实例）

### 4.2 观测性覆盖：**0%**

实测验证：

```
$ up{namespace="n8n"}                                    → []  (空集)
$ n8n_uptime_seconds / n8n_queue_total_done / ...        → []  (空集)
$ ServiceMonitor/PodMonitor/Probe -n n8n                 → 0 / 0 / 0
```

| 缺失项 | 现状 | 影响 |
|---|---|---|
| 指标采集 | 无 ServiceMonitor / PodMonitor / Probe | 无任何遥测数据 |
| 应用 metrics 端点 | 容器仅暴露 `5678`，无 metrics 端口，env 无 `N8N_METRICS` | 即使配 SM 也无数据源 |
| 存活/就绪探针 | liveness / readiness / startup **全部为空** | K8s 无法感知进程假死；`KubePodNotReady` 永不触发 |
| 资源限额 | `resources: {}` | QoS = **BestEffort**，首个被驱逐者；`KubeCPUQuotaOvercommit` 等配额告警全部失效 |
| 副本 | `replicas: 1` | 无冗余 |
| PDB | 不存在 | 节点排空/升级时必然中断 |
| HPA | 不存在 | 流量高峰无法扩容 |
| 业务 SLI | 无 | 执行成功率/耗时/队列深度/活跃工作流数全部不可见 |
| SLO / 错误预算 | 无 | 无 `n8n` 燃尽率告警 |
| 端到端探测 | 无 | `n8n.zeroth.com`（Ingress）与 `n8ntrace.ccwu.cc`（Cloudflare 隧道）是否可达**无任何监控** |
| 公网隧道 | cloudflared 无探针、无指标、无告警 | 隧道断开 = 业务对外完全不可达，且**静默** |
| 数据库侧 | n8n DB 跑在 CNPG `pg16-ceph`，无 postgres exporter | 连接数、慢查询、复制延迟、磁盘全不可见 |

### 4.3 n8n 作为告警出口的风险

**配置**（`monitoring` 命名空间，Alertmanager 有效配置）：

```yaml
route:
  receiver: n8n-webhook          # ← 全局唯一 receiver
  routes:
  - receiver: n8n-webhook        # severity =~ "critical|warning"
    matchers: [severity =~ "critical|warning"]
receivers:
- name: n8n-webhook
  webhook_configs:
  - url: http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
```

问题：

- **单出口**：无 email / Slack / PagerDuty / 企业微信 任何备用 receiver。`AlertmanagerConfig` CR 数量为 0。
- **自指依赖**：出口是被监控对象 n8n。n8n 挂 → 全部 187 条告警无处可投 → `AlertmanagerFailedToSendAlerts` 本身也投不出去 → **告警静默**。
- **未验证连通性即上线**：该 URL 由 n8n 工作流定义提供。工作流被禁用/删除/改路径，告警即刻全哑，且无任何针对该端点的存活探测。

### 4.4 实测投递失败记录

Alertmanager 容器自 2026-09-27 13:55 启动至今的累计值：

| 指标 | 值 |
|---|---|
| `sum(alertmanager_notifications_total)` | **2299** |
| `sum(alertmanager_notifications_failed_total)` | **2160** |
| **失败率** | **93.9%** |
| 失败原因 | `reason="other"`（`integration=webhook`） |
| 其余 17 种 integration（email/slack/pagerduty…） | 全部 0（未配置） |

失败根因（AM 日志，2026-09-28 集中爆发）——**当时 receiver URL 指向公网地址**：

```
err="Post \"<redacted>\": read tcp 10.244.5.48:57068->172.67.181.153:443:
     read: connection reset by peer"
err="dial tcp: lookup n8ntrace.ccwu.cc on 10.96.0.10:53: server misbehaving"
```

`172.67.181.153` / `104.21.18.107` 均为 **Cloudflare 边缘 IP**。即：告警出口绕公网 Cloudflare 回打 n8n，DNS 抖动与 CF 连接重置导致大面积失败。后果：

```
level=ERROR msg="excessive retries creating aggregation group" alert=KubePdbNotEnoughHealthyPods retries=101
level=ERROR msg="Notify for alerts failed" num_alerts=4
    err="notify retry canceled after 15 attempts: ... connection reset by peer"
```

`retries=101` 意味着聚合组被彻底放弃，**告警永久丢失**。

**当前状态（已修复）**：receiver 已改为集群内地址，近 24h `33 成功 / 0 失败`。但**架构性单点未消除**。

---

## 5. 严重问题清单

### P0-1 ｜ Alertmanager 单出口 + 自指依赖

- **位置**：`monitoring/alertmanager-prometheus-alertmanager-generated`
- **现象**：`receivers` 仅 1 个，指向 n8n 自身；无任何备用通道
- **影响**：n8n 不可用 ⇒ 全集群告警静默；n8n 工作流异常 ⇒ 同上。AM 自身无冗余（`replicas=1`）
- **建议**：
  1. 增加 `email` + 企业微信/Slack 独立 receiver 作为 primary 或 `continue: true` 双发
  2. critical 走独立 receiver，与 n8n 解耦
  3. `Alertmanager` 副本数提至 2–3
  4. 新增"死循环告警"探针：从集群外部监控 `/webhook/k8s-alerts` 可达性

### P0-2 ｜ n8n 业务面零可观测性

- **位置**：`n8n` 命名空间
- **现象**：0 采集目标、0 告警、0 探针、无 metrics 端点
- **影响**：n8n 是本集群最关键业务（且承载全集群告警出口），却完全不可观测
- **建议**：见 §7 阶段一

### P0-3 ｜ 5 条告警规则永久失效（死规则）

已逐条用 Prometheus 实时查询验证：

| 告警名 | 规则引用 | 实测结果 | 根因 |
|---|---|---|---|
| `OtelDemoServiceDown` | `up{namespace="otel-demo"}==0` | `namespace "otel-demo" not found` | 演示环境 namespace 已删除，规则未清理 |
| `OtelDemoHighErrorRate` | `traces_spanmetrics_calls_total{namespace="otel-demo"}` | EMPTY | 同上 |
| `CephCSIOperationErrors` | `csi_sidecar_operations_seconds_count{driver_name="rbd.csi.ceph.com"}` | EMPTY | 指标名错误：ceph-csi 3.16.2 实际暴露 `csi_operations_seconds_count`；且**无** `driver_name` 标签 |
| `TektonPipelineRunFailed` | `tekton_pipelines_controller_pipelinerun_count` | EMPTY | 指标不存在 |
| `TektonTaskRunFailed` | `tekton_pipelines_controller_taskrun_count` | EMPTY | 实际为 `tekton_pipelines_controller_taskrun_total`，且**无失败计数器** |

> 附带问题：`CephCSIOperationErrors` 语义本身也有误 —— `csi_operations_seconds_count` 按 `grpc_status_code` 区分，原写法会把**成功操作**也计为失败。正确写法应加 `grpc_status_code!="OK"` 过滤。

### P1-1 ｜ 端到端/外部可用性完全无监控

- `Probe` CR = **0**，集群未部署 blackbox-exporter，无对应 ServiceMonitor
- 业务唯一对外入口 `n8n.zeroth.com`（Traefik Ingress）与 `n8ntrace.ccwu.cc`（Cloudflare Tunnel）**无任何探测**
- Ingress 侧仅有 1 条 `TraefikHigh5xxRate`，无延迟分位、连接数、请求速率、证书过期
- cloudflared 隧道无探针无指标 —— 隧道断开即业务对外完全不可达，且系统无感知

### P1-2 ｜ Loki 日志栈零监控

| 组件 | 工作负载 | 告警 | 指标采集 |
|---|---:|---:|---|
| loki-write (STS) | 1 | ❌ 0 | ❌ 无 |
| loki-backend (STS) | 1 | ❌ 0 | ❌ 无 |
| loki-read / loki-gateway | 2 | ❌ 0 | ❌ 无 |
| loki-chunks-cache / results-cache / memcached | 3 | ❌ 0 | ❌ 无 |
| loki-canary (DS ×3) | 3 | ❌ 0 | ❌ 无（canary 存在却不校验） |
| alloy (DS ×6，日志采集器) | 6 | ❌ 0 | ❌ 无（`alloy_*` = 0 序列） |

`logging` 命名空间共 **17 个工作负载**，是全集群第二大命名空间，却**无一条告警、无一个采集目标**。这与 Tempo3（20 条告警、全组件覆盖）形成刺眼对比。

后果：**故障时无日志可查**。AM 日志中大量 `namespace="logging"` 的告警（`KubePodCrashLooping`、`KubeDeploymentReplicasMismatch`、`KubeStatefulSetUpdateNotRolledOut`）说明该命名空间长期处于异常状态，但既无根因告警也无日志。

### P1-3 ｜ Ceph 存储集群零监控

- `count({__name__=~"ceph_.*"})` = **0**，`rbd_*` = **0** → 集群未部署任何 Ceph exporter
- `node_filesystem_*` 仅可见 `['ext4','ramfs','tmpfs','xfs']` → **node-exporter 无法看到 RBD 块设备**
- `ceph-csi-rbd-sc` 的 `reclaimPolicy: Retain` → 卷误删无法自动回收
- 依赖 Ceph 的 9 个 PVC 全部无容量水位告警：

| Namespace | PVC | 容量 | 业务影响 |
|---|---|---|---|
| **n8n** | `n8n-pvc` | 5Gi | n8n 工作流/凭据存储 |
| **cnpg-system** | `pg16-ceph-3/4` + `-wal` | 10+10+5+5 Gi | **n8n 数据库**、全集群 PG |
| **kafka** | `data-my-cluster-single-pool-0` | 20Gi | Kafka 消息存储 |
| **logging** | `data-loki-backend-0`, `data-loki-write-0` | 10+10 Gi | 日志存储 |

缺失告警：pool 容量、OSD down/full、PG 状态、slow ops、scrub 错误、容量增长率。

### P1-4 ｜ PostgreSQL / CNPG 数据面零监控

- 仅 `cnpg-controller-manager` 被 PodMonitor 采集（控制面）
- `count({__name__=~"pg_.*"})` = **0** → **未部署 postgres-exporter**
- CNPG 集群 `pg16-ceph`（2 实例，承载 n8n 全部业务数据）缺失：
  - 复制延迟、wal 堆积
  - 连接数饱和、慢查询
  - 磁盘水位（10Gi data + 5Gi wal，随工作流增长必然写满）
  - 主备切换、failingover
  - `Cluster in healthy state` 仅为 CNPG 自身判断，无 Prometheus 侧交叉验证

### P1-5 ｜ 监控栈自身单副本

| 组件 | 副本 | 风险 |
|---|---|---|
| Prometheus | **1**（`shards: 1`） | 全部指标与告警计算单点；重启期间告警中断 |
| Alertmanager | **1** | 静默状态与在途通知丢失（该 STS 已重启 16 次） |
| Grafana | 1 | 仪表盘不可用 |

`retention: 5d` 与 `Alertmanager retention: 120h` 不匹配；容量 100Gi NFS PVC。

---

## 6. 中等问题清单

### P2-1 ｜ 告警重复（双重通知）

自定义规则与上游规则语义重叠，同时命中 → 同一问题两条告警推送到同一 n8n webhook：

| 自定义 | `for` | 上游 | `for` | 问题 |
|---|---|---|---|---|
| `PodCrashLooping` | 5m | `KubePodCrashLooping` | 15m | 自定义版 `rate(restarts[15m])*60>0` **单次重启即告警**，噪声源 |
| `PodNotReady` | 5m | `KubePodNotReady` | 15m | 重复 |
| `NodeHighCPU` | 5m | `NodeHighCPU` | — | 重复 |
| `NodeHighMemory` | 5m | `NodeHighMemory` | — | 重复 |
| `NodeDiskPressure` | 5m | `NodeFilesystemSpaceFillingUp` 等 | — | 重复且阈值不同 |

`inhibit_rules` 无法去重 —— 其 `equal: [namespace, alertname]` 要求 alertname 相同，而这些是不同名称。

### P2-2 ｜ 告警质量：52 条无 runbook，13 条无 description

- **52/187（28%）无 runbook_url**，其中包含**全部 20 条 tempo3 告警**、**全部 14 条 etcd 告警**、全部 n8n/traefik/kafka/cnpg/knative 相关告警
- **13 条无 description**：`CertManagerCertificateExpired`、`CertManagerCertificateExpiringSoon`、`CertManagerNotReady`、`TektonPipelineRunFailed`、`TektonTaskRunFailed`、`TraefikHigh5xxRate`、`KafkaClusterOperatorDown`、`CephCSIOperationErrors`、`CNPGControllerManagerDown`、`KnativeEventingControllerDown`、`PodNotReady`、`PodOOMKilled`、`OtelDemoServiceDown`
- 告警标签仅 4 类（`severity` + `component/short/long`），**无 `service` / `team` / `runbook` 归属标签** → 无法按业务域路由与分派

### P2-3 ｜ 路由与抑制策略缺陷

```yaml
group_wait: 30s
group_interval: 5m        # critical 告警确认后 5 分钟才复查，突发场景过慢
repeat_interval: 12h      # critical 持续 12h 不再重复 → 长时间故障仅通知一次
```

- **无 critical 快速通道**：未为 `severity="critical"` 配置 `group_interval: 1m` + `repeat_interval: 1h`
- **`repeat_interval: 12h` 过长**：12 小时内持续恶化的 critical 只报一次
- **抑制规则逻辑失效**：
  - 第 1、2 条 `equal: [namespace, alertname]` —— 跨不同 alertname 的抑制**永不触发**
  - 第 3 条 `equal: [namespace]` 且 `alertname = InfoInhibitor` —— **本条逻辑正确，不应删除**
    （2026-10-01 更正：本条原判「全集群无该告警名」有误。`InfoInhibitor` 规则存在于
    `prometheus-general.rules`，且实测 5 天内 firing 过。它是被第 4 条连累失效的。
    处置记录见 `/root/wecom-alert-receiver-20261001/DEAD-RULES-AUDIT-20261001.md`）
  - 第 4 条 `target_matchers: [alertname = InfoInhibitor]` —— 无源匹配项，逻辑不完整
- `Watchdog` 告警 `severity="none"`，不匹配 `critical|warning` 子路由，但因**根 receiver 同为 n8n-webhook** 仍会推送到 n8n

### P2-4 ｜ nfs-provisioner 零监控

`nfs-provisioner` 命名空间承载集群 NFS 供给（Prometheus 100Gi PVC 与 Alertmanager 20Gi PVC 均使用 `nfs-sc`），但 `nfs_provisioner_*` 指标为 **EMPTY**，无对应 job，无任何告警。存储供给链路断裂将导致监控栈自身 PVC 无法创建。

### P2-5 ｜ 大量 `replicas=1` 且无 PDB 的工作负载

全集群 **45+ 个** Deployment/StatefulSet 为 `replicas=1` 且无 PDB，其中多数是控制面关键组件：

- `cert-manager` / `cert-manager-cainjector` / `cert-manager-webhook`
- `cnpg-controller-manager`（n8n 数据库控制器）
- `strimzi-cluster-operator` / `my-cluster-entity-operator`
- `knative-eventing-controller` / `knative-serving-controller` / `webhook` / `activator` / `autoscaler`
- `ceph-csi-rbd-provisioner`
- `loki-gateway` / `loki-read`
- `n8n` / `cloudflared`

集群仅有 2 个 NetworkPolicy，`n8n`、`logging`、`monitoring` 等均无网络隔离。

### P2-6 ｜ 陈旧序列指向已删除命名空间

`kube_pod_info` 的 namespace 标签值包含 `gitlab-runner`、`tekton-demo`、`tf-space` —— 这三个命名空间在集群中**均已不存在**。5 天 retention 内的残留序列导致历史告警持续触发（AM 日志可见 `namespace="gitlab-runner"` 的 `PodCrashLooping`）。

---

## 7. 修复路线图

### 阶段一 · P0（1–3 天）：打通告警管道 + n8n 可见性

| # | 动作 | 对象 |
|---|---|---|
| 1 | 新增独立 receiver（邮件 / 企业微信 / Slack），critical 走**双发**（`continue: true`），与 n8n 解耦 | Alertmanager |
| 2 | 部署 blackbox-exporter + `Probe`：探测 `n8n-svc:5678/healthz/readiness`、`https://n8n.zeroth.com`、`https://n8ntrace.ccwu.cc` | monitoring |
| 3 | 删除 5 条死规则：`OtelDemo*`（2）、`CephCSIOperationErrors`、`Tekton*Failed`（2） | `cluster-wide-alerts` / `app-monitoring-alerts` |
| 4 | n8n 加 readiness/liveness/startup 探针 + `resources`（limits cpu 500m/mem 1Gi） | `deploy/n8n` |
| 5 | n8n `replicas: 2` + PDB + 改 `maxUnavailable: 0` | `deploy/n8n` |
| 6 | 开启 n8n metrics：容器加 `--port` metrics + `N8N_METRICS=true`，建 ServiceMonitor | `deploy/n8n` |

### 阶段二 · P1（1–2 周）：补齐存储/日志/数据面

| # | 动作 |
|---|---|
| 7 | 部署 **Ceph exporter**（mgr 插件）+ ServiceMonitor；新增 pool 容量/OSD down/OSD full/slow ops/scrub 告警 |
| 8 | 为 ceph-rbd PVC 增加容量水位告警（`kubelet_volume_stats_available_bytes` 已可用，需按 `storageclass` 过滤） |
| 9 | 部署 **postgres-exporter** 到 CNPG `pg16-ceph`；新增复制延迟/wal 堆积/连接饱和/慢查询/磁盘水位/主备切换告警 |
| 10 | 为 `logging` 命名空间建立 ServiceMonitor + PodMonitor（Loki 5 组件 + alloy + canary）；新增 Loki 20+ 条告警模板（对齐 tempo3-alerts 质量） |
| 11 | cloudflared 加探针与指标；新增隧道断连告警 |
| 12 | Prometheus 副本 → 2，Alertmanager 副本 → 2 |

### 阶段三 · P2（2–4 周）：质量与治理

| # | 动作 |
|---|---|
| 13 | 清理 5 条与上游重复的自定义告警（`PodCrashLooping`/`PodNotReady`/`NodeHigh*`/`NodeDiskPressure`） |
| 14 | critical 路由加 `group_interval: 1m` + `repeat_interval: 1h`；全局 `repeat_interval` 12h → 4h |
| 15 | 重写 4 条 inhibit_rules，使跨 alertname 抑制生效（`equal: [namespace]`） |
| 16 | 补齐 52 条 runbook + 13 条 description；统一增加 `service`/`team` 标签 |
| 17 | 引入 **n8n SLO**：定义可用性 SLI（`up{probe=~"n8n.*"}`）+ 延迟 SLI，配置 5m/1h/6h/1d/3d 多窗口燃尽率告警 |
| 18 | 为 45+ 个 `replicas=1` 关键工作负载补 PDB；为 `monitoring`/`logging`/`n8n` 补 NetworkPolicy |
| 19 | 为 nfs-provisioner 增加监控与告警 |
| 20 | 建立告警规则 lint（`promtool check rules` + CI 校验指标存在性），防止再次出现死规则 |

---

## 8. 附录：关键验证证据

<details>
<summary>采集与规则统计</summary>

```
$ kubectl get prometheusrules -A --no-headers | wc -l        → 38   (全部在 monitoring ns)
$ kubectl get alertmanagerconfigs -A --no-headers | wc -l    → 0
$ kubectl get probes -A --no-headers | wc -l                 → 0
$ curl 'prom/api/v1/query?query=up{namespace="n8n"}'         → []
$ curl 'prom/api/v1/query?query=count(up)'                   → 92
$ curl 'prom/api/v1/query?query=count(up==0)'               → []
$ curl 'prom/api/v1/query?query=count({__name__=~"pg_.*"})' → 0
$ curl '...count({__name__=~"ceph_.*"})'                    → 0
$ curl '...count({__name__=~"alloy.*"})'                    → 0
$ curl '...node_filesystem_avail_bytes' fstype values        → ['ext4','ramfs','tmpfs','xfs']
$ curl '...kubelet_volume_stats_available_bytes'            → 1 (n8n) / 4 (cnpg) / 1 (kafka) / 2 (logging)
```

</details>

<details>
<summary>Alertmanager 有效配置（amtool check-config: SUCCESS）</summary>

```yaml
global: {resolve_timeout: 5m}
route:
  receiver: n8n-webhook
  group_by: [alertname, namespace, severity]
  routes:
  - receiver: n8n-webhook
    matchers: [severity =~ "critical|warning"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
inhibit_rules:
- target_matchers: [severity =~ warning|info]
  source_matchers: [severity = critical]
  equal: [namespace, alertname]
- target_matchers: [severity = info]
  source_matchers: [severity = warning]
  equal: [namespace, alertname]
- target_matchers: [severity = info]
  source_matchers: [alertname = InfoInhibitor]
  equal: [namespace]
- target_matchers: [alertname = InfoInhibitor]
receivers:
- name: n8n-webhook
  webhook_configs:
  - send_resolved: true
    url: http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
templates: [/etc/alertmanager/config/*.tmpl]
```

</details>

<details>
<summary>告警投递统计</summary>

```
sum(alertmanager_notifications_total)        = 2299   (100% 走 webhook integration)
sum(alertmanager_notifications_failed_total) = 2160   (reason="other")
→ 失败率 93.9%

近 24h: notifications = 33, failed = 0     (receiver 已切换为集群内地址后恢复正常)
近  1h: notifications = 2,  failed = 0
```

AM 日志根因（2026-09-28）：
```
err="Post \"<redacted>\": read tcp 10.244.5.48:57068->172.67.181.153:443:
      read: connection reset by peer"          # 172.67.181.153 = Cloudflare 边缘 IP
err="dial tcp: lookup n8ntrace.ccwu.cc on 10.96.0.10:53: server misbehaving"
level=ERROR msg="excessive retries creating aggregation group" retries=101
level=ERROR msg="notify retry canceled after 15 attempts"
```

</details>

<details>
<summary>n8n 探针与资源配置实测</summary>

```
$ kubectl get deploy n8n -n n8n -o jsonpath
replicas=1  strategy=RollingUpdate  maxSurge=25%  maxUnavailable=25%
resources={}
liveness=  readiness=  startup=                    ← 三种探针全部缺失
ports=[5678]                                       ← 无 metrics 端口
env: DB_TYPE, DB_POSTGRESDB_*, N8N_TRUST_PROXY, N8N_ENCRYPTION_KEY,
     WEBHOOK_URL=https://n8ntrace.ccwu.cc/, N8N_PROTOCOL=https   ← 无 N8N_METRICS

$ kubectl get pdb/hpa/networkpolicy/servicemonitor/podmonitor/probe -n n8n
→ 全部 0

$ kubectl exec -n monitoring alertmanager-0 -c alertmanager -- \
    wget --post-data='{}' http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
→ HTTP/1.1 200 OK  {"message":"Workflow was started"}     (工作流当前存在且启用)
```

</details>

<details>
<summary>未监控工作负载清单</summary>

| 命名空间 | 工作负载数 | ServiceMonitor | PodMonitor | 告警数 | 状态 |
|---|---:|---:|---:|---:|---|
| **n8n** | 2 | 0 | 0 | 0 | ❌ 业务面完全缺失 |
| **logging** | 17 | 0 | 0 | 0 | ❌ Loki 零监控 |
| **knative-serving** | 7 | 0 | 0 | 0 | ❌ |
| **knative-operator** | 2 | 0 | 0 | 0 | ❌ |
| **tekton-pipelines** | 7 | 2 | 0 | 3(死) | ⚠️ 规则失效 |
| **argocd** | 7 | 0 | 1 | 0 | ⚠️ 仅 1 个 metrics 端点 |
| **kafka** | 2 | 0 | 1 | 1 | ⚠️ 仅 operator，broker 无 |
| **cert-manager** | 3 | 1 | 0 | 3 | ✅ |
| **cnpg-system** | 1 | 0 | 1 | 1 | ⚠️ 无数据面 exporter |
| **ceph-csi-rbd** | 2 | 2 | 0 | 1(死) | ⚠️ 规则失效 |
| **metallb-system** | 2 | 0 | 1 | 0 | ⚠️ |
| **traefik** | 1 | 0 | 1 | 1 | ⚠️ 仅 5xx |
| **opentelemetry** | 2 | 2 | 0 | 0 | ⚠️ |
| **nfs-provisioner** | 1 | 0 | 0 | 0 | ❌ |
| **kubernetes-dashboard** | 2 | 0 | 0 | 0 | ❌ |
| **cicd** | 1 | 0 | 1 | 0 | ⚠️ |
| **shop** | 0 | 0 | 0 | 0 | 空命名空间 |
| **monitoring** | 12 | 13 | 1 | 约 100 | ✅ |
| **logging (tempo3 部分)** | 9 | 0 | 1 | 20 | ✅ |

</details>

---

## 9. 评分卡

| 维度 | 得分 | 说明 |
|---|:---:|---|
| 节点 / 主机基础设施 | 9/10 | node-exporter 告警完备 |
| Kubernetes 控制面 | 9/10 | 含 apiserver SLO 燃尽率 |
| 存储（Ceph / CSI） | 2/10 | Ceph 集群 0 指标，CSI 规则失效 |
| 数据库（CNPG / PG） | 1/10 | 仅控制器，0 数据面指标 |
| 日志栈（Loki / Alloy） | 1/10 | 17 工作负载，0 告警 0 采集 |
| 入口网关（Traefik / cloudflared） | 3/10 | 仅 1 条 5xx 告警 |
| **业务面（n8n）** | **0/10** | 无指标、无探针、无告警、无 SLI |
| 告警管道可靠性 | 3/10 | 单出口自指，历史 94% 失败 |
| 告警质量与治理 | 4/10 | 52 条无 runbook、5 条死规则、重复告警 |
| 端到端可用性 | 0/10 | 0 Probe、无 blackbox |
| **加权总分** | **4.3/10** | 未达到生产可观测性基线 |
