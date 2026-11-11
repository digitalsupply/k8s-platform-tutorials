# 10 · 可观测性工程：指标基数、PromQL、日志、Trace 与成本

> “装了 Prometheus”只是起点。可观测性工程要回答的是：
> **哪些信号值得采、每个信号多少钱、出故障时能不能在 5 分钟内定位。**
>
> 本章基于本集群真实数据（2026-11-11）：
> Prometheus 3.11.2 / 26 万 series / 17.9GB / RSS 1.5GiB；
> Loki 0.6GB/天；Tempo 6.8 万 span/天；52 个抓取 job；无 blackbox、无 Thanos/VM/Mimir。
>
> 证据：[`assets/observability-engineering/`](assets/observability-engineering/README.md)。
> 一句话版本：[15 面试速查 09-observability.md](../15-interview-cheatsheet/09-observability.md)。

## 1. 先看本环境基线

| 项 | 实测值 | 说明 |
|---|---|---|
| Prometheus | `v3.11.2`，scrape 30s | 单副本，本地 TSDB |
| Head series | **260,359** | TSDB 内存中的活跃序列 |
| Label pairs | 14,206 | 标签组合总量 |
| Chunks | 567,104 | head 中的 chunk 数 |
| 本地存储 | **17.9GB** / PVC 100Gi | retention 15d / 25GiB |
| RSS | **1.57GiB** / limit 4GiB | 约 6KB/series |
| 抓取 job | 52 个 | 27 ServiceMonitor + 16 PodMonitor |
| Blackbox / Probe | **0** | 黑盒监控缺失 |
| Loki | 0.6GB/天，5d | S3 bucket `loki-chunks` |
| Tempo | 6.85 万 span/天，5d | S3 bucket `tempo-traces` |
| Thanos / VM / Mimir | **未部署** | 只有 Prometheus 本地 15d |

```text
prometheus_tsdb_head_series        260359
process_resident_memory_bytes      1.57 GiB
prometheus_tsdb_storage_blocks     17.9 GB
```

> 这组数字是本章所有结论的基线。换环境必须重新采集，不要直接复用。

## 2. 指标类型与基数爆炸

### 2.1 四种指标类型

| 类型 | 语义 | 典型用法 | 坑 |
|---|---|---|---|
| Counter | 只增不减 | 请求数、错误数、字节数 | 不能直接画绝对值，要 `rate`/`increase` |
| Gauge | 可增可减 | 温度、队列长度、内存 | 不能 `rate`，只能看趋势/聚合 |
| Histogram | 分桶计数 + sum + count | 延迟、大小 | 桶选择决定分位数精度 |
| Summary | 客户端算分位数 | 少量固定分位 | 不能跨实例聚合，成本高 |

本环境绝大多数是 Counter/Histogram：`apiserver_request_total`、`*_bucket`；
`kube_pod_status_phase` 是 Gauge；`compassio_users_total` 名字像 counter，实际是当前用户数（Gauge），
这也是一个常见命名坑。

### 2.2 基数 = 标签值的笛卡尔积

```text
series = 指标名 × 每个 label 的取值数
```

例如：

```text
http_requests_total{user_id, path, method, status}
= 100,000 用户 × 100 路径 × 5 方法 × 5 状态
= 250,000,000 series
```

**为什么不能把 `user_id` 放 label**：

- 每个 series 在 head 里约占 **1–6KB**（本环境实测 RSS/series ≈ 6KB）；
- 1M series 约 6GB 内存，10M series 直接打爆单机 Prometheus；
- 用户 ID 是高基数、低聚合维度：它不适合做“聚合监控”，适合放日志/trace/exemplar；
- 真要按用户排查，用 **exemplar + trace_id** 跳转，不要进指标标签。

本环境的业务指标做对了这一点：

```text
compassio_users_total{role="student"} 887
compassio_users_total{role="teacher"} 16
compassio_users_total{role="school_admin"} 1
```

只有 3 个 series，而不是 904 个用户各一条。

### 2.3 受控复现：15 万 series 在 128Mi 下 OOM

为了验证“基数打爆内存”不是玄学，在隔离命名空间启动一个 Prometheus 3.11.2，
限制 128Mi，抓一个合成 exporter：

```text
app_http_requests_total{user_id="uN", path="/api/items/N", status="200", method="GET"}
N = 150,000
```

结果：

```text
container prometheus: Restart Count: 3
Last State: Terminated
  Reason:   OOMKilled
  Exit Code: 137
```

Prometheus 启动日志已经把 `GOMEMLIMIT` 自动压到约 115Mi，仍然 OOM：

```text
GOMEMLIMIT=120795955
```

完整记录：[`evidence/cardinality-oom-lab.txt`](assets/observability-engineering/evidence/cardinality-oom-lab.txt)。

> 这是受控实验，不是生产事故。它说明：**内存上限不是“series 数 × 固定值”的硬保证**，
> GOMEMLIMIT 是软限制，chunk、索引、查询并发都会叠加。

### 2.4 本环境真实高基数审计

TSDB status 的 top series：

| metric | series | 说明 |
|---|---:|---|
| `apiserver_request_duration_seconds_bucket` | 19,440 | 每个 verb/resource/scope/le 一条 |
| `apiserver_request_body_size_bytes_bucket` | 14,496 | 同上 |
| `etcd_request_duration_seconds_bucket` | 12,800 | etcd 请求延迟 |
| `apiserver_request_sli_duration_seconds_bucket` | 11,024 | SLI 直方图 |
| `apiserver_response_sizes_bucket` | 8,256 | 响应大小 |

apiserver 相关合计约 **12.8 万 series，占全部 26 万的 49%**：

```text
job=apiserver        127,929 series
endpoint=https       128,433 series
namespace=default    127,952 series
service=kubernetes   127,932 series
```

这不是“apiserver 指标没用”，而是说明：**一个组件的直方图 + 多维标签就能吃掉一半内存**。
如果再加一个高基数 label（比如 `path` 或 `user_agent`），立刻翻倍。

高基数 label 的真实来源：

| label | 取值数 | 主要 metric | 风险 |
|---|---:|---|---|
| `path` | 311 | cilium/kubelet/loki 的 HTTP 直方图 | 路径参数化不足会爆炸 |
| `id` | 544 | cAdvisor `container_*`（容器 ID） | 容器重建就产生新 series |
| `uid` | 291 | KSM `kube_pod_*`（Pod UID） | Pod 重建就产生新 series |
| `container_id` | 244 | `kube_pod_container_info` | 同上 |
| `address` | 271 | endpointslice/node network | 通常可控 |

具体：

```text
container_blkio_device_usage_total   1306 series  (label id)
kube_pod_status_reason                695 series  (label uid)
cilium_k8s_client_api_latency_*       804 series  (label path)
```

### 2.5 更危险的是“churn”

当前 24 小时：

```text
head series: 229,356 -> 260,359   (+31,003, +13.5%)
series created / 1h: 7,224
series removed / 1h:    663
```

创建远大于删除，说明大量 series 是短命的（Pod/容器重建、临时 Job、Tekton PipelineRun）。
这些 series 即使过期，也会在 head/WAL 中留下成本，并让查询变慢。

> 面试结论：**基数治理不仅看“当前多少”，还要看“每小时创建多少”。**
> 一个每天重建 1000 个 Pod 的集群，`pod`/`uid`/`container_id` 标签就是持续泄漏。

### 2.6 基数治理清单

1. **指标评审**：新指标必须写 label 白名单和基数估算；
2. **禁止 label**：`user_id`、`order_id`、`request_id`、`trace_id`、`session_id`、原始 URL；
3. **参数化路径**：`/api/items/:id` 而不是 `/api/items/12345`；
4. **应用侧聚合**：在 exporter 里按 route/status 聚合，不要把原始维度抛给 Prometheus；
5. **metric_relabel_configs**：采集时 `drop` 不需要的 label/metric；
6. **recording rules**：把高频查询降维成低基数序列；
7. **预算**：每团队/每 namespace 的 series 配额，周环比 >20% 告警。

本环境 Prometheus 配置已有 63 条 `drop`、187 条 `keep` relabel，
说明采集侧做过治理；但没有“series 预算”与“按团队 showback”。

## 3. PromQL 常见坑

### 3.1 `rate()` 至少需要 2 个样本

本环境 scrape interval = **30s**。实测：

```text
rate(node_cpu_seconds_total{mode="idle"}[10s])  -> 0 series
rate(node_cpu_seconds_total{mode="idle"}[30s])  -> 0 series
rate(node_cpu_seconds_total{mode="idle"}[1m])   -> 6 series
```

为什么 `[30s]` 也不够：range selector 是左开右闭，30s 窗口内往往只有 1 个样本。
**经验规则：窗口 ≥ 4 × scrape interval**；30s 抓取至少用 `[2m]`，常用 `[5m]`。

证据：[`evidence/promql-pitfalls.txt`](assets/observability-engineering/evidence/promql-pitfalls.txt)。

### 3.2 `rate` vs `irate`

- `rate(v[5m])`：用窗口内所有样本做线性回归，平滑，适合画图/SLO；
- `irate(v[5m])`：只用最后两个样本，灵敏但抖动大，适合“快速变化”的告警。

实测（idle CPU）：

```text
irate(...[5m])  cpu0 = 0.8563
rate(...[5m])   cpu0 = 0.8773
```

两者数值接近，因为负载平稳；如果负载突变，`irate` 会立刻跳，`rate` 会滞后。
**不要用 `irate` 算 SLO/长期趋势**，也不要用 `rate[1m]` 抓瞬时毛刺。

### 3.3 先 `sum by` 再算比率/分位数

业务速率：

```promql
# 正确：先按 verb 聚合，再得到每秒请求数
sum by (verb) (rate(apiserver_request_total[5m]))

# 结果 9 条：GET 11.7/s、PUT 12.2/s、WATCH 2.2/s ...
```

全局总量：

```promql
sum(rate(apiserver_request_total[5m]))   # 28.6/s
```

**常见错误**：先 `avg` 每个实例的比率，再平均。
如果实例流量不同，平均比率 ≠ 全局比率；应 `sum(分子)/sum(分母)`。

### 3.4 `histogram_quantile` 必须先 `sum by (le)`

本环境 apiserver 直方图有 10 个 bucket（`0.005 ... 60, +Inf`）。
错误写法（不聚合）：

```promql
histogram_quantile(0.99,
  rate(apiserver_request_duration_seconds_bucket{verb="GET"}[5m]))
```

结果：

```text
series = 188
NaN    = 122
```

因为它对每个 label 组合（instance/resource/scope/...）各算一个分位数，
很多组合在 5m 窗口内没有请求，直接 NaN。

正确写法：

```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(apiserver_request_duration_seconds_bucket{verb="GET"}[5m])
  ))
```

结果：

```text
series = 1
p99    = 0.0229s
```

### 3.5 bucket 选择

- 必须有 `+Inf`，否则 `histogram_quantile` 返回 NaN；
- 桶太少/太粗，分位数是插值出来的，p99 可能严重失真；
- 桶要覆盖 SLO 边界：例如 SLO 200ms，桶至少要有 0.1/0.2/0.5；
- 本环境 apiserver 桶：`0.005, 0.025, 0.05, 0.1, 1, 5, 10, 30, 60, +Inf`，
  对 200ms 的 SLO 来说，0.1 到 1 之间跨度过大，p99 精度有限；
- 更高精度可用 native histogram（Prometheus 3.x 支持），但客户端要暴露。

### 3.6 其他高频坑

| 坑 | 现象 | 修法 |
|---|---|---|
| Counter 重置 | `rate` 出现负值/尖刺 | Prometheus 会处理重置，但窗口太短会抖动 |
| `absent()` 用错 | 指标消失时不告警 | `absent(metric)` 或 `unless` 组合 |
| label 匹配 | `=` 精确、`=~` 正则、`!=` 不等于 | 正则要锚定，避免 `.*` 扫全量 |
| `topk` 位置 | `topk(5, sum by (pod)(...))` vs `sum by(pod)(topk(...))` | 先聚合再 topk |
| `increase` 外推 | 窗口边界导致小数 | 对短窗口不要过度解读 |
| 高基数正则 | `job=~".*"` 扫全量 series | 用具体 job/namespace |

### 3.7 规则审计（本环境 345 条）

```text
total 345 = 251 alerting + 94 recording
rate/irate 窗口 < 120s: 0
histogram_quantile 无 sum 聚合: 4（etcd 按 instance 算分位数）
group by 含 pod/uid/container_id/path: 52（多数是告警定位，必要）
irate 规则: 1
```

说明：告警里保留 `pod` 是必要的（否则不知道哪个 Pod），
但**长期 recording rule 里保留 `uid/container_id/path`** 会制造高基数，要区分场景。

证据：[`evidence/rule-audit.txt`](assets/observability-engineering/evidence/rule-audit.txt)。

## 4. 分层监控：黑盒 vs 白盒

### 4.1 两种视角

| 视角 | 看什么 | 手段 | 本环境 |
|---|---|---|---|
| 黑盒 | 用户能否访问、响应是否正确/快 | 拨测、HTTP/TCP/ICMP Probe、合成事务 | **缺失**（0 Probe，无 blackbox exporter） |
| 白盒 | 内部队列、GC、连接池、错误码、延迟分布 | exporter / `/metrics` / OTel | 52 job，27 SM + 16 PM |

黑盒回答“服务活着吗”，白盒回答“为什么慢/为什么错”。
只有白盒会出现“所有指标正常但用户打不开”的盲区；只有黑盒会“知道挂了但不知道原因”。

> 本环境是典型“白盒很强、黑盒缺失”：入口/证书/ DNS/外部依赖没有主动拨测。
> 补法：blackbox_exporter + `Probe` CR，至少覆盖域名、TLS 到期、关键 API 200/延迟。

### 4.2 四层监控

| 层 | 关注 | 本环境实际 job/指标 |
|---|---|---|
| 基础设施 | CPU/内存/磁盘/网络/节点 | `node-exporter` 6、`kubelet` 18、`apiserver` 3、`kube-etcd` 3、`coredns` 2、`cilium-agent` 6 |
| 中间件 | 数据库/消息/入口/存储 | `cnpg-controller-manager`、`kafka/strimzi-cluster-operator`、`traefik/traefik`、`metallb-controller`、`ceph-mgr`、Loki/Tempo |
| 应用 | 请求量/错误/延迟/饱和度 | `compassio-backend`、`deeptutor-api`、`argocd`、`tekton`、`alloy` |
| 业务 | 用户/订单/课程/LLM 调用 | `compassio_users_total`、`compassio_llm_requests_total`、`deeptutor_turns_finished_total` |

业务层不是“再装一个 exporter”，而是把业务事件做成低基数指标：

```text
compassio_users_total{role="student|teacher|school_admin"}   3 series
compassio_llm_requests_total                                 27,615/24h
compassio_http_requests_total                                 ~150/s
deeptutor_turns_finished_total                                ~3/24h
```

本环境业务告警已经存在：

```text
CompassioHttpLatencyHigh / CompassioLlmFallbackRateHigh / CompassioRedisDown
DeepTutorTurnStalled / DeepTutorTTFTSlow / DeepTutorTurnFailureRate
```

但 `OtelDemoHighErrorRate` 引用的 `traces_spanmetrics_*` 当前 **0 series**，
属于“规则存在但永远不会触发”的覆盖缺口。

### 4.3 SLI / SLO / 告警分层

```text
SLI：请求成功率、P99 延迟、TTFT、队列积压
SLO：99.9% 成功、P99 < 300ms、TTFT < 2s
告警：
  - 症状告警（用户视角）：错误率、延迟、可用性
  - 原因告警（组件视角）：CPU、GC、连接池、磁盘
  - 预警：容量/趋势/证书到期
```

原则：**症状告警优先**，原因告警用于定位；不要给每个 CPU 指标都配 Pager。

## 5. 日志：结构化、采样与生命周期

### 5.1 结构化日志

推荐应用输出 JSON：

```json
{"time":"2026-11-11T03:00:00Z","level":"error","service":"backend",
 "trace_id":"...","route":"/api/items/:id","status":500,"msg":"db timeout"}
```

好处：字段可过滤、可聚合、可和 trace 关联。
代价：**不要把高基数字段变成 Loki label**（`trace_id`、`user_id`、原始 URL）；
Loki 的 label 只放低基数维度（namespace/pod/container/job/app/level）。

本环境 Alloy 管道：

```text
stage.cri: 1     # 剥掉 CRI 时间戳/stream
stage.json: 0    # 没有 JSON 解析
sampling: 0      # 没有采样
stage.drop: 1    # 只丢弃超过 120h 的旧日志
```

也就是说：日志按文本采集，结构化解析和采样都还没做。
如果应用输出 JSON，建议在 Alloy 加 `stage.json`，但只提取 `level` 等低基数字段；
`trace_id` 放 **structured metadata**，不要做 label。

### 5.2 日志量与成本

```text
24h ingest: 624 MB
24h lines:  2,138,546
avg rate:   7.1 KiB/s
retention:  120h (5d)
steady raw: ~2.9 GiB (不含索引/压缩)
```

对比指标：26 万 series 占 17.9GB，日志 5 天才 ~3GB。
**当前存储大头是指标，不是日志**；但日志增速快、单条成本高，仍要治理。

### 5.3 日志成本控制

1. **级别治理**：生产默认 INFO，DEBUG 只按 namespace/请求头临时开；
2. **采样**：高频访问日志按 1%–10% 采样，错误日志 100%；
3. **丢弃**：健康检查、静态资源、重复堆栈；
4. **结构化但不滥用 label**：字段过滤 vs label 索引；
5. **分层保留**：错误 30d、普通 7d、debug 1d；
6. **压缩/对象存储**：Loki S3 后端 + 生命周期；
7. **按团队配额**：ingestion rate/stream 数限制。

### 5.4 `/var/log` 生命周期

容器日志由 **kubelet** 轮转，不是 logrotate：

```text
kubelet 未显式配置 containerLogMaxSize/MaxFiles
-> 默认 10Mi × 5（每容器）
worker01 已出现 14 个 *.log.* 轮转文件，最大约 10.5MB
containerd max_container_log_line_size = 16384
/var/log 326M，其中 /var/log/pods 183M
```

logrotate 负责宿主机日志：

```text
/etc/logrotate.conf: weekly, rotate 4
/var/log/syslog 11M
journald: 20.4M
```

结论：

- 容器日志：kubelet 10Mi×5，单容器最多约 50MB；
- 宿主机 syslog：weekly × 4；
- journald：按默认/发行版配置，需单独设 `SystemMaxUse`；
- 不要用 logrotate 管 `/var/log/pods`，会和 kubelet 冲突；
- 节点磁盘告警要覆盖 `/var/lib/containerd`、`/var/log/pods`、`/var/lib/kubelet`。

证据：[`evidence/logs-lifecycle.txt`](assets/observability-engineering/evidence/logs-lifecycle.txt)、
[`evidence/logs-rotation.txt`](assets/observability-engineering/evidence/logs-rotation.txt)。

## 6. Trace：context 传播与采样

### 6.1 context 传播

跨服务链路靠标准头：

```text
traceparent: 00-<trace-id>-<span-id>-<flags>
tracestate:  vendor-specific
baggage:     key=value
```

要求：

- 入口（Traefik/网关）生成或透传 `traceparent`；
- 每个服务用 OTel SDK 创建 span，并从入站请求提取 context；
- 出站 HTTP/gRPC/DB 调用注入 context；
- 异步消息把 context 放进消息头；
- 日志里打 `trace_id`，Grafana 才能从日志跳 trace。

本环境 OTel Collector 0.145.0：

```text
receivers:  otlp
processors: batch
exporters:  debug, otlp_grpc/tempo, prometheus
connectors: spanmetrics
```

### 6.2 头部采样 vs 尾部采样

| 方式 | 决策点 | 优点 | 缺点 |
|---|---|---|---|
| Head-based | SDK/Collector 入口 | 实现简单、开销低 | 不知道后续是否出错，可能丢关键 trace |
| Tail-based | Collector 收集完整 trace 后 | 可按错误/延迟/属性保留 | 需要缓冲、内存/磁盘、路由复杂 |

本环境 **Collector 侧没有配置任何采样**（processors 只有 batch）；
如果应用 SDK 也未做 head sampling，就是入口全收。
当前 Tempo 只有 6.85 万 span/天（0.79 span/s），量小，全收没问题；
但业务放量后必须加采样，否则 Tempo/S3/查询成本线性上涨。

推荐尾部采样策略：

```text
保留：status=ERROR、latency > P99、特定租户/灰度流量、慢 DB 调用
丢弃：健康检查、静态资源、成功且低延迟的 90%
```

### 6.3 当前 trace 覆盖缺口

```text
tempo_distributor_spans_received_total  68,544/24h
traces_spanmetrics_calls_total          0 series
traces_service_graph_request_total      0 series
otelcol_receiver_accepted_spans         0 series
```

说明 Tempo 有 span，但 **OTel Collector 的 spanmetrics/服务图没有产出**，
或者业务没有经过该 Collector。结果是：

- `OtelDemoHighErrorRate` 规则永远不会触发；
- 无法从 trace 自动生成 RED 指标/服务依赖图；
- 只能查 Tempo，不能在 Prometheus 里做跨服务聚合。

这不是“再加一个 dashboard”能解决的，要先确认 span 的入口和 exporter 链路。

## 7. 长期存储：Thanos / VictoriaMetrics / Mimir

本环境 Prometheus 只有本地 15d/25GiB，**没有长期存储**；
Loki/Tempo 用 S3（`loki-chunks`、`tempo-traces`，5d）。
当需要“查 6 个月/跨集群/多租户”时，才考虑以下方案。

| 维度 | Thanos | VictoriaMetrics | Grafana Mimir |
|---|---|---|---|
| 架构 | Sidecar/Receive + Store Gateway + Querier + Compactor | 单机或 vmcluster（vminsert/vmselect/vmstorage） | Distributor + Ingester + Store Gateway + Querier + Compactor |
| 对象存储 | S3/GCS/Azure | 支持，也可本地 | S3/GCS/Azure |
| 查询语言 | PromQL | MetricsQL（兼容大部分 PromQL） | PromQL |
| 多租户 | 有限（靠外部） | 支持 | 原生强多租户 |
| 降采样 | 支持 | 支持 | 支持 |
| 运维复杂度 | 中（组件多） | 低–中 | 高 |
| 适合 | 已有 Prometheus，想低成本长期化 | 单集群/中小规模，追求压缩比和简单 | 大规模、多租户、平台团队 |

决策建议：

```text
只想延长保留、跨集群查询，且已有 Prometheus
  -> Thanos sidecar + 对象存储

想少运维、高压缩、单集群/中小规模
  -> VictoriaMetrics

多租户 SaaS/大平台，需要配额、隔离、水平扩展
  -> Mimir
```

本环境当前 26 万 series、17.9GB/15d，**还不需要**上长期存储；
优先做基数和 retention 治理。等单集群 >100 万 series 或需要跨集群时再选型。

## 8. 成本治理

### 8.1 本环境成本基线

| 信号 | 量 | 存储/保留 | 主要成本驱动 |
|---|---|---|---|
| Metrics | 26 万 series | 17.9GB / 15d | **series 数 × label 数 × 抓取频率** |
| Logs | 0.6GB/天，214 万行 | ~2.9GB / 5d | 字节数 × 保留天数 |
| Traces | 6.85 万 span/天 | 5d，S3 | span 数 × 属性大小 × 采样率 |

指标的单位成本：

```text
磁盘：67 KiB/series（15d）≈ 4.5 KiB/series/天
内存：约 6 KB/series
```

按此估算：

```text
100 万 series ≈ 6GB 内存 + 67GB 磁盘（15d）
```

这只是 Prometheus 单副本，不含副本/查询/compaction 余量。

### 8.2 成本治理杠杆

| 杠杆 | 效果 | 风险 |
|---|---|---|
| 删无用指标/规则 | 直接降 series | 可能丢排障能力 |
| metric_relabel drop | 采集侧降基数 | 需要确认下游不用 |
| 聚合/recording rule | 查询快、series 少 | 丢失原始维度 |
| 降采样/长期存储 | 冷数据便宜 | 查询精度下降 |
| 降低 scrape 频率 | 降样本数 | 告警灵敏度下降 |
| 日志采样/丢弃 | 降字节数 | 可能丢关键错误 |
| Trace 采样 | 降 span 数 | 可能丢长尾 |
| 保留分级 | 直接降存储 | 回滚/审计窗口变短 |

### 8.3 面试怎么答“可观测性成本治理”

不要只说“加 retention”。可按三层回答：

1. **建模层**：指标只留可聚合维度，禁止 user_id/request_id；日志结构化但不滥用 label；trace 用采样。
2. **采集层**：scrape 频率、relabel/drop、采样、批量、压缩。
3. **存储层**：保留分级、对象存储、降采样、长期存储选型。
4. **组织层**：每团队 series/ingest 配额、周环比告警、成本 showback、变更评审。

一句话：

> 可观测性成本不是“存储费用”，而是 **series 数 × 维度 × 采样率 × 保留时间** 的乘积；
> 最贵的通常不是日志，而是没人清理的高基数指标。

## 9. 一页命令与检查清单

```bash
# 基数
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/status/tsdb | jq '.data.headStats'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=prometheus_tsdb_head_series'

# 高基数 label
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=topk(10, count by (__name__) ({user_id!=""}))'

# PromQL
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'

# 日志
kubectl -n logging logs deploy/loki-gateway
kubectl -n logging get cm alloy-config -o yaml | grep -E 'stage\.|sampling|drop'

# Trace
kubectl -n opentelemetry get opentelemetrycollector otel -o yaml
kubectl -n logging get cm tempo3-config -o yaml | grep -E 'retention|bucket'

# 宿主机日志
ssh root@<node> 'du -sh /var/log /var/log/pods; journalctl --disk-usage'
```

上线前检查：

- [ ] 新指标有 label 白名单和基数估算；
- [ ] 没有 `user_id/order_id/request_id/trace_id` 进 label；
- [ ] `rate()` 窗口 ≥ 4×scrape interval；
- [ ] `histogram_quantile` 前 `sum by (le)`；
- [ ] 有黑盒拨测（域名/TLS/关键 API）；
- [ ] 日志 JSON 化、采样、保留分级；
- [ ] Trace 有采样策略，错误/长尾必留；
- [ ] 有 series 预算和周环比告警；
- [ ] 明确长期存储选型（Thanos/VM/Mimir）和成本上限。
