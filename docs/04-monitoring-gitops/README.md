# 04 · Monitoring GitOps：Prometheus / Loki / Tempo / Grafana 全链路

这个目录是整套可观测性栈的“运行手册 + 事故复盘”：

- **Metrics**：Prometheus + Alertmanager + 企业微信/n8n 双出口；
- **Logs**：Grafana Alloy → Loki → Ceph RGW S3；
- **Traces**：OTel Collector → Tempo 3 → S3，Grafana 三支柱关联；
- **GitOps**：kube-prometheus-stack、CRD、PrometheusRule、wecom-adapter 全部纳入 ArgoCD；
- **告警治理**：规则审计、失效规则、累计重启告警、白名单 selector。

## 当时的情况

改造前，`monitoring` 命名空间的 kube-prometheus-stack 由 **Helm release** 管理，但：

- 6 个自建 PrometheusRule 是手工 `kubectl apply`，没有 Git 记录；
- Alertmanager 只有 **n8n webhook 一个出口**，而 n8n 本身是被监控对象，构成自指缺陷；
- 企业微信适配器已部署，但因 NetworkPolicy/DNS 问题一直发不出消息；
- kube-prometheus-stack 不在 ArgoCD 管理范围，CRD 手工安装，版本落后；
- 告警规则库 281 条，其中 **27 条引用了不存在的 metric**，永远不会触发；
- 只有 `rate()` 型 CrashLoop 告警，抓不到“历史重启 100 次但当前稳定”的 Pod；
- 日志侧刚从 Promtail 迁到 Alloy，**采集了 0 条日志**；
- Tempo 2.x 与 3.x 共存，3.x 因 S3 凭据错误全部 CrashLoop；
- Grafana 里 traces 查询为空，日志/指标/追踪三支柱没有真正关联。

2026-11-08 到 11-09 又完成了两件与可观测性强相关的事：

- **Grafana Operator Stage A**：4 个 Datasource + 37 个 Dashboard 从 Helm sidecar 迁到 Operator 管理；
- **Prometheus / Alertmanager / Grafana 存储从 NFS 迁到 Ceph RBD**，期间遇到 `k8s-rbd` 池写满、
  CSI/RWO 挂载卡死、worker02 I/O 卡死、CNPG failover 等连锁事故。

## 主要概念与原理

### 1. 三支柱与数据流

```text
Metrics:  kubelet/apiservers/exporters ──scrape──► Prometheus ──► Alertmanager ──► WeCom / n8n
Logs:     /var/log/pods ──Alloy──► Loki ──► Ceph RGW S3
Traces:   OTel SDK/Collector ──► Tempo distributor ──► Kafka/live-store ──► block-builder ──► S3
Query:    Grafana ──► Prometheus / Loki / Tempo
```

### 2. Prometheus Operator 的 CRD

kube-prometheus-stack 不直接创建进程，而是创建 CR：

| CR | 作用 |
|---|---|
| `Prometheus` | 副本、存储、保留期、`ruleSelector`、`serviceMonitorSelector` |
| `Alertmanager` | 副本、存储、路由/接收器来源 |
| `PrometheusRule` | 告警/记录规则 |
| `ServiceMonitor` / `PodMonitor` / `Probe` | 抓取配置 |
| `AlertmanagerConfig` | 团队级路由/接收器 |

Operator 监听这些 CR，生成 StatefulSet、配置文件和 Secret。**GitOps 的对象是 CR，不是 Operator 生成的 StatefulSet。**

### 3. `ruleSelector` 与白名单

Prometheus CR 通过 `ruleSelector` 选择 PrometheusRule。本集群给所有 GitOps 管理的规则打：

```yaml
labels:
  platform.gitops/managed: "true"
```

`ruleSelector` 同时匹配 `release=prometheus` + `platform.gitops/managed=true`，
这样手工创建的规则即使存在也不会被加载，堵住绕过 GitOps 的口子。
`alertmanagerConfigSelector` 同理。

### 4. Alertmanager 路由与抑制

- `route` 决定告警去哪个 receiver；
- `continue: true` 让同一告警继续匹配后续子路由，实现**双出口**；
- `inhibit_rules` 用于抑制衍生告警，但条件写错会导致“该报的不报”；
- `wechat_configs` 只能调企业微信**应用消息 API**，不能直接调群机器人 webhook，所以需要 `wecom-adapter` 做协议转换。

### 5. Loki 标签与保留

Loki 的标签由采集端（Alloy relabel）决定，常见标签：
`namespace`、`pod`、`container`、`node_name`、`job`、`app`、`instance`、`component`。

保留策略有三层，必须同时改：

1. Loki `limits_config.retention_period` / `compactor`；
2. S3 对象生命周期（RGW lifecycle）；
3. Tempo 的 block retention。

只改一层会出现“Grafana 查不到但 S3 还在涨”或“S3 删了但索引还在”。

### 6. Tempo 3 的架构

`tempo-distributed` 把 distributor、querier、live-store、block-builder、backend-scheduler/worker、
query-frontend、metrics-generator 拆成独立组件。trace 先写 live-store/Kafka，再由 block-builder
落 S3。**S3 凭据、endpoint、bucket 任一错误都会让 block-builder 持续失败。**

### 7. Grafana 的三种供给方式

| 方式 | 管理者 | 特点 |
|---|---|---|
| Helm sidecar | chart 内的 sidecar 容器扫描 ConfigMap/Secret | 简单，但和 chart 生命周期绑死 |
| Grafana Operator CR | `GrafanaDatasource` / `GrafanaDashboard` | GitOps 友好，资源级 reconcile |
| 手工 UI | 人 | 无法复现，重启/迁移即丢 |

Stage A 的目标不是“装 Operator”，而是把 Datasource/Dashboard 的**所有权**从 Helm sidecar
转到 CR，同时保持 Grafana 实例本身仍由 Helm 管理（external Grafana 模式）。

### 8. 监控数据为什么不适合放 NFS

- Prometheus TSDB 是大量小文件 + 频繁 rename，NFS 延迟和锁语义会放大抖动；
- RWO 语义下，Pod 漂移时 NFS 可能仍被旧节点挂载，出现“新 Pod 卡 ContainerCreating”；
- Ceph RBD 提供块设备 + 明确 attach/detach，适合单副本 TSDB，但没有 RWX；
- 迁移时必须停写、复制数据、改 PVC，不能在线 `rsync` 一个正在写的 TSDB。

## 踩坑点

### 坑 1：Alertmanager 的 `wechat_configs` 发不到群机器人

从 Alertmanager v0.32 源码看，`wechat_configs.api_url` 会被拼接 `gettoken` 和 `message/send`，
只能用于企业微信**应用**。把群机器人 URL 填进去会 404。

**修复**：部署 `wecom-adapter`，Alertmanager 用 webhook 调 adapter，adapter 再调群机器人。

### 坑 2：告警单出口 + 自指依赖

原来唯一 receiver 是 n8n，而 n8n 挂了也会产生告警，导致“告警出口消失时，告警也发不出去”。

**修复**：`severity=critical|warning` 同时走 `wecom-adapter` 和 `n8n-webhook`，`continue: true`，两者互不依赖。

### 坑 3：27 条规则引用不存在的 metric

例如 `container_oom_event_total`（少了复数 s）、`kube_pod_container_status_last_terminated_reason`（KSM 未采集）。
这些规则 `health=ok` 但 `state=inactive`，看起来“没告警”，实际是**永远不会触发**。

**修复**：逐条用 Prometheus API 验证表达式至少返回一个序列；对确实无数据的规则，要么补采集，要么删除/标注。

### 坑 4：`rate()` 抓不到累计重启

`rate(kube_pod_container_status_restarts_total[15m]) > 0` 只能抓“正在频繁重启”。
对已经稳定但历史重启 192 次的 apiserver 永远静默。

**修复**：新增累计重启告警，直接比较 `kube_pod_container_status_restarts_total` 的绝对值/增量窗口。

### 坑 5：标签维度依赖 Pod 名

`up{namespace="logging",pod=~"tempo3-.+"}` 在 Pod 改名/换 StatefulSet 后失效。
**修复**：改用 `job=~"distributor|querier|..."`，按组件名而非 Pod 名匹配。

### 坑 6：Promtail → Alloy 迁移丢了 5 项能力

配置文件搬过去了，但 chart 的隐式能力没搬：多行日志、Kubernetes 元数据、label 保留、
pipeline stage、position 文件等。结果 Alloy 运行正常但 Loki 里 0 条日志。

**修复**：按 Promtail 的能力清单逐项对照，补 relabel/pipeline，再用 Loki API 验证
`{namespace="logging"}[1h]` 有数据，而不是只看 Alloy Pod Running。

### 坑 7：Tempo3 的 S3 凭据错误导致全部 CrashLoop

S3 `secret_key` 错误时，distributor/block-builder 会持续报签名失败。
**修复**：用 RGW 真实凭据做 S3 签名请求验证，再改 Secret；不要只看 Pod 日志里的 “S3 error”。

### 坑 8：Ceph RGW 17.2.8 的 aws-chunked 兼容 bug

Tempo 用 minio-go 写 0 字节的 aws-chunked 终止块，RGW 17.2.8 把 seed 签名当终止块签名比对，
必然 400 `XAmzContentSHA256Mismatch`。一度以为是 minio-go 的锅，做了兼容层代理，最后定位到 RGW 服务端。

**修复**：Ceph 17.2.8 → 18.2.8（reef）滚动升级，修复在 18.2.5+。兼容层代理从未接流量，已删除。

### 坑 9：Loki chunks-cache OOM 是配置矛盾，不是节点内存不足

Loki 的 `chunks_cache` 上限设置大于容器 memory limit，缓存还没到上限容器就被 OOMKill。
**修复**：让 cache 上限与 memory limit 匹配，并留出余量；不要盲目加内存。

### 坑 10：Grafana Logs Drilldown 502

Loki gateway 的 upstream/端口配置与实际 Service 不一致，导致 drilldown 请求 502，普通查询却正常。
**修复**：对齐 gateway 配置与 Service 端口，重启后验证 drilldown 的 `/api/ds/query` 路径。

### 坑 11：Grafana 里“没有 traces”不一定是没数据

可能是 datasource URL/tenant 不对、时间范围不对、或 trace 根本没落 S3。
**修复**：先用 Tempo API 直接查 `api/search`，再查 Grafana datasource，最后看 OTel Collector 是否真的收到 span。

### 坑 12：Dashboard 不是 Ingress，是 IngressRoute

Traefik 环境里 `kubectl get ingress` 为空，不代表没有入口。要看 `kubectl get ingressroute -A`。
本集群的 Grafana/Prometheus/ArgoCD/Hubble/Alloy/Tekton/Traefik Dashboard 全部是 IngressRoute。

### 坑 13：Grafana Operator 接管后，旧 sidecar 资源仍带 `provisioned` 标志

Datasource PUT 返回 403 `Cannot update read-only data source`；Dashboard DELETE 返回 400
`provisioned dashboard cannot be deleted`。

**根因**：Helm sidecar 时期创建的资源带 `provisioned=true` / `readOnly=true` 标志，
Operator 通过 API 更新时被 Grafana 拒绝。必须先关 sidecar、按 label 找到旧资源、删除后
再由 Operator 重建，而不是继续在 UI 里改。

### 坑 14：统计“存储不够”时只看 PVC 声明容量

Prometheus PVC 声明 100Gi，NFS 上实际 19.3G；Ceph RBD 是 thin provisioning，声明不等于占用。
迁移前必须用 `du`/`rbd du` 看实际数据量，并给目标池留出 **快照/副本/突发写入** 余量。
本集群 `k8s-rbd` 被新 PVC 一次写满，直接导致 CSI、CNPG、监控连锁故障。

### 坑 15：RWO 卷在 Pod 漂移时会“假死”

旧 Pod 所在节点失联，新 Pod 已调度，但 RBD 卷仍被旧节点 attach，新 Pod 卡在
`Multi-Attach error` / `ContainerCreating`。此时删 Pod 没用，要确认旧节点上的
`rbd map`/watcher 是否释放，必要时在 Ceph 侧处理。

## 修复关键

### 阶段 1：规则与告警出口

1. 6 个自建 PrometheusRule 纳入 ArgoCD，打 `platform.gitops/managed=true`；
2. 修复 `ruleSelector` / `alertmanagerConfigSelector`，堵住手工规则；
3. 部署 `wecom-adapter`，Alertmanager 双出口 + `continue: true`；
4. 修 adapter 的 NetworkPolicy/DNS，端到端发一条测试告警；
5. 审计 27 条失效规则，能补数据的补，不能补的删/标注。

### 阶段 2：监控栈整体 GitOps

1. kube-prometheus-stack 整体纳入 ArgoCD（Application + values）；
2. CRD 单独一个 Application（10 个 CRD），避免 operator 升级时 CRD 落后；
3. 规则单独一个 Application，按团队/主题拆文件；
4. 所有 Secret 用 SealedSecret，不把明文提交到 Git。

### 阶段 3：日志与追踪

1. Alloy 按 Promtail 能力清单补齐，验证 Loki 有数据；
2. Tempo 3 的 S3 凭据/endpoint/bucket 全部对齐，验证 block 落盘；
3. 统一 retention 为 5 天（Loki + S3 lifecycle + Tempo）；
4. 修 Loki cache OOM、Logs Drilldown 502、node-exporter collector 错误；
5. 补 Cilium/Alloy/Traefik/Hubble 等 Dashboard 和对应 IngressRoute。

### 阶段 4：验证

```bash
# 规则是否被 Prometheus 加载
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}'

# target 是否全 up
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up")'

# Loki 是否真的收到日志
curl -sG http://loki-gateway.logging.svc/api/v1/query_range \
  --data-urlencode 'query={namespace="logging"}' --data-urlencode 'limit=5'

# Tempo 是否有 trace
curl -s 'http://tempo3-query-frontend.logging.svc:3200/api/search?limit=5'
```

### 阶段 5：存储迁移

```text
预检查（Ceph 容量 / CSI 健康 / 20Gi 测试 PVC）
  → 缩副本、停写
  → 新 PVC（ceph-rbd-sc）
  → helper Pod 同时挂旧/新卷，rsync
  → 改 Helm values/PVC 名
  → 启动、验证
  → 保留旧卷至少一个保留周期再删
```

顺序：Grafana（10Gi）→ Alertmanager（20Gi）→ Prometheus（100Gi）。
**Prometheus 最后做**，因为它数据量最大、最怕写中断。

## 本目录文档

### 总体审计与运行状态

| 文档 | 内容 |
|---|---|
| [10-observability-engineering.md](10-observability-engineering.md) | 可观测性工程：指标类型/基数爆炸、PromQL 坑、黑盒/白盒分层、日志生命周期、Trace 采样、长期存储、成本治理 |
| [11-logging-pipeline.md](11-logging-pipeline.md) | 日志轮转 copytruncate/create、journald 持久化、json-file/kubelet、Alloy/Loki、采样/脱敏/成本 |
| [17 SRE](../17-sre/README.md) | SLO/Error Budget、burn rate、症状告警、SEV/IC、postmortem、变更相关性 |
| [observability-lab.md](notes/observability-lab.md) | 可观测性实战实验手册（基于本集群实测） |
| [observability-stack-full-audit.md](notes/observability-stack-full-audit.md) | LGTM 全栈审计：组件、链路、P0/P1 问题 |
| [cluster-observability-report.md](notes/cluster-observability-report.md) | LGTM 运行状态与三支柱关联分析 |
| [observability-phase2-fixes.md](notes/observability-phase2-fixes.md) | Phase-2 修复：通知失败、Alloy、Tempo 等 |
| [observability-upgrade-inventory.md](notes/observability-upgrade-inventory.md) | 升级前只读盘点 |
| [observability-upgrade-report.md](notes/observability-upgrade-report.md) | 同期的 Ceph 集群诊断（文件名有历史原因） |
| [monitoring-inventory.md](notes/monitoring-inventory.md) | 62 个 job / 125 targets 全量清单 |
| [monitoring-coverage-gap-report.md](notes/monitoring-coverage-gap-report.md) | 监控覆盖缺口：A 类漏配 / B 类无 metrics |

### 告警治理

| 文档 | 内容 |
|---|---|
| [prometheus-promql-alerting-tutorial.md](notes/prometheus-promql-alerting-tutorial.md) | PromQL + 告警实战教程 |
| [monitoring-alerts-analysis.md](notes/monitoring-alerts-analysis.md) | 全部告警规则逐条分析 |
| [alerting-coverage-audit-20260930.md](notes/alerting-coverage-audit-20260930.md) | 告警覆盖审计与 n8n 业务面 |
| [alert-fix-execution-report.md](notes/alert-fix-execution-report.md) | P0/P1 修复执行，推翻三处误判 |
| [cluster-alert-effectiveness-report.md](notes/cluster-alert-effectiveness-report.md) | 告警有效性分析 |
| [告警根因分析.md](notes/告警根因分析.md) | 告警根因与处置落地 |
| [wecom-alert-receiver-20261001/](notes/wecom-alert-receiver-20261001/) | 企业微信双出口变更、失效规则、mcrun 事故 |

### 日志 / 追踪

| 文档 | 内容 |
|---|---|
| [retention-unification-5d.md](notes/retention-unification-5d.md) | Loki/S3/Tempo 三层保留统一为 5 天 |
| [loki-labels-and-node-exporter-errors.md](notes/loki-labels-and-node-exporter-errors.md) | Loki 标签机制与 Alloy relabel |
| [loki-cache-oom-fix-20261104.md](notes/loki-cache-oom-fix-20261104.md) | chunks-cache OOM 修复 |
| [logging-components-analysis.md](notes/logging-components-analysis.md) | logging 命名空间组件分析 |
| [logging-drilldown-fix-20261109/REPORT.md](notes/logging-drilldown-fix-20261109/REPORT.md) | Grafana Logs Drilldown 502 修复 |
| [node-exporter-fix-report.md](notes/node-exporter-fix-report.md) | node-exporter collector 错误修复 |
| [loki-and-cephcsi-probe-report.md](notes/loki-and-cephcsi-probe-report.md) | loki-canary / ceph-csi 探针修复 |
| [traces-architecture-and-correlation.md](notes/traces-architecture-and-correlation.md) | Traces 原理、架构与三支柱关联 |
| [trace-context-propagation-and-tempo-tiering.md](notes/trace-context-propagation-and-tempo-tiering.md) | Trace 上下文传播、Tempo 冷热分层 |
| [grafana-traces-empty-analysis.md](notes/grafana-traces-empty-analysis.md) | Grafana traces 为空的根因 |
| [tempo3/](notes/tempo3/) | Tempo 3 共存评估、S3 兼容、流量切换、旧栈退役、告警配置 |

### Dashboard 与入口

| 文档 | 内容 |
|---|---|
| [k8s-dashboard-inventory-20261110.md](notes/k8s-dashboard-inventory-20261110.md) | 47 个 Grafana 面板 + 组件自带 UI 全景 |
| [ui-and-dashboards-update-20261110.md](notes/ui-and-dashboards-update-20261110.md) | IngressRoute 更正、Cilium 面板、Hubble/Alloy/Traefik 暴露 |
| [fix-report-grafana-prometheus-https.md](notes/fix-report-grafana-prometheus-https.md) | Grafana/Prometheus HTTPS 访问修复 |
| [ceph-monitoring-integration-report.md](notes/ceph-monitoring-integration-report.md) | Ceph 监控接入（含 ceph_exporter 方案） |
| [grafana-operator-stage-a-2026-11-08.md](notes/grafana-operator-stage-a-2026-11-08.md) | Grafana Operator 接管 4 Datasource + 37 Dashboard 与 5 个坑 |
| [prometheus-nfs-to-ceph-feasibility-2026-11-09.md](notes/prometheus-nfs-to-ceph-feasibility-2026-11-09.md) | NFS → Ceph RBD 的容量/能力/风险可行性评估 |
| [prometheus-nfs-to-ceph-migration-2026-11-09.md](notes/prometheus-nfs-to-ceph-migration-2026-11-09.md) | 三组件迁移全过程、Ceph full、CSI/RWO、CNPG failover |
| [platform-gitops-repo/](../11-gitops-platform/notes/platform-gitops-repo/) | 平台仓原始文档：Grafana Operator、监控、日志、SSO |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/logging-pipeline/](assets/logging-pipeline/README.md) | logrotate 实验、journald、容器日志、Alloy/Loki 与成本证据 |
| [assets/observability-engineering/](assets/observability-engineering/README.md) | 基数/OOM/PromQL/日志/Trace 证据与 15 万 series 复现实验 |
| [manifests/](manifests/) | 4 个 ArgoCD Application、6 个规则、10 个 CRD、stack values、wecom adapter |
| [assets/alert-backup/](assets/alert-backup/) | 修复前的规则与 Prometheus CR 备份 |
| [assets/wecom/](assets/wecom/) | Alertmanager 配置与 `apply.sh`（webhook 已脱敏） |
| [assets/retention/](assets/retention/) | Alloy/Loki/Tempo3 保留配置备份 |
| [assets/loki-values-cache-fix.yaml](assets/loki-values-cache-fix.yaml) | Loki cache OOM 修复 values |
| [assets/node-exporter-ds.yaml](assets/node-exporter-ds.yaml) | node-exporter DaemonSet 修复版 |
| [assets/grafana-dashboards/](assets/grafana-dashboards/) | ArgoCD/cert-manager/CNPG/Knative/MetalLB/Strimzi/Tekton/Traefik 面板 JSON |
| [assets/gen-dashboards.py](assets/gen-dashboards.py) | 批量生成/导入 Dashboard 的脚本 |
| [assets/prometheus-cr-backup-20261003.yaml](assets/prometheus-cr-backup-20261003.yaml) | Prometheus CR 备份 |
| [assets/current-prometheusrules.yaml](assets/current-prometheusrules.yaml) | 当前全部 PrometheusRule 快照 |
| [scripts/sigv4-probe.py](scripts/sigv4-probe.py)、[sigv4-probe2.py](scripts/sigv4-probe2.py)、[rgw-rule-matrix.py](scripts/rgw-rule-matrix.py) | Ceph RGW aws-chunked 签名探针（复现 400 根因） |

> `manifests/` 里的 GitLab/n8n 地址、SealedSecret、webhook 已脱敏；使用前替换成你的环境。
> 告警规则不要直接全量 apply，先 `promtool check rules` 并确认 metric 存在。
