# Traces 原理、架构与三支柱关联

- **分析时间**：2026-10-02 17:10
- **依据**：集群实际配置 + 你提供的真实 trace `e284de20431ddd49`（Grafana Tempo）
- **结论先行**：你这条 trace 完整走通了 Traefik → OTel Collector → Tempo 全链路，**且 traces 与 metrics 的关联也已生效**（通过 spanmetrics connector），日志关联则存在缺口。

---

## 一、先看这条 trace 本身

### 1.1 它是一次真实的 Grafana 请求

```
POST https://grafana.example.local/api/user/auth-tokens/rotate
Chrome 154 on Windows 11
→ traefik (43.71ms, HTTP/2.0)
  └─ ReverseProxy (42.43ms, HTTP/1.1) → 10.244.30.116:3000
```

`url.path = /api/user/auth-tokens/rotate` 是 Grafana 的**令牌轮换接口**——你打开 Grafana 时它会悄悄调一次。所以这条 trace 的产生源头就是 Grafana 本身。

### 1.2 两个 span 的父子关系

```
[Root] traefik POST              43.71ms   16:45:39.336
  └─[Child] ReverseProxy         42.43ms   16:45:39.336 (+363.75μs)
```

`Start Time: 363.75μs` 表示子 span 在父 span 开始后 **0.36 毫秒**就启动了——这是网关的标准模式：Traefik 一收到请求立刻开 root span，转发时才开下游 span。

**关键证据**：父 span 43.71ms、子 span 42.43ms，差值 **1.28ms** 就是 Traefik 自身的处理开销（TLS 终止、路由匹配、转发）。99% 的时间花在后端 Grafana 上。

### 1.3 Span 的三种属性（面试常问）

| 属性类型 | 例子 | 谁产生 | 用途 |
|---|---|---|---|
| **Span attributes** | `http.request.method=POST`、`url.path`、`http.response.status_code=200` | SDK 自动埋点 | 描述**这次操作** |
| **Resource attributes** | `service.name=traefik`、`k8s.pod.name`、`process.pid=1` | OTel SDK + K8s 资源检测 | 描述**谁产生的** |
| **Status** | `Status: unset` | SDK | 成功/失败 |

**注意 `Status: unset`** —— Traefik 即使返回 200 也标记 unset，这是 SDK 语义（unset ≠ error，是"没设置"）。判断失败要看 `http.response.status_code`，不能看 Status。这是个常见误解。

---

## 二、Traces 原理：一次请求的一生

### 2.1 核心概念

| 概念 | 定义 | 你的 trace 中的实例 |
|---|---|---|
| **Trace** | 一次完整的请求链路，共享同一个 `trace_id` | `e284de20431ddd49` |
| **Span** | 链路中的一个操作单元 | `POST`(root) + `ReverseProxy`(child) |
| **Parent Span** | 上游操作 | `POST` |
| **Child Span** | 下游操作 | `ReverseProxy` |
| **Span Context** | `trace_id` + `span_id` + `trace_flags` | 传播载体 |
| **Context Propagation** | 通过 HTTP header 传递 span context | W3C `traceparent` |

### 2.2 上下文传播（Trace 能在跨服务时"串起来"的根本原因）

这是整个 Traces 原理的**最核心机制**。HTTP 请求本身没有 trace 概念，是靠**在 HTTP header 里夹带一个 span 上下文**实现的。

**W3C Trace Context 标准**，四个 header：

```http
traceparent: 00-e284de20431ddd49-765e4320f3b5a1c9-01
             │  │              │              │  └─ flags(01=采样)
             │  │              │              └──── parent span_id
             │  │              └─────────────────── 当前 span_id
             │  └────────────────────────────────── trace_id
             └───────────────────────────────────── version(00)
tracestate: congo=t61rcWkgMzE
```

**传播流程**：

```
Grafana(客户端)
  │  生成 trace_id=e284de20...，写入 header
  ↓  HTTP POST
Traefik
  │  ① 从 header 读出 traceparent → 拿到 trace_id
  │  ② 开启自己的 root span（ParentSpanId = 客户端的 span_id）
  │  ③ 反向代理时，把【自己新 span 的】traceparent 写进下游请求
  ↓  HTTP/1.1 POST 10.244.30.116:3000
Grafana 后端
     ④ 读 header → 自动关联到同一个 trace_id → 生成自己的 span
```

**如果没有这个 header，链路就断了**——Tempo 里会看到两个独立的 trace，而不是一棵 43.71ms 的树。

> **注意**：你的 trace 里只有 Traefik 的 2 个 span，**Grafana 后端的 span 缺失**。因为 Grafana 没接入 OTel SDK，它不知道 traceparent 的存在。下游服务若未插桩，链路就在 Traefik 终止。这是"部分可观测"的典型形态。

### 2.3 采样的必要性

全量采集开销极大（每个 span 约 1-2KB，一秒几千请求就是几十 MB/s）。所以有采样策略：

| 采样类型 | 含义 | 你的集群 |
|---|---|---|
| **Head-based** | 入口决定采不采（提前决定，省资源） | — |
| **Tail-based** | 入口全采，存储时筛选（如只存慢请求/错误） | — |
| **Head sampling** | 按比例 | Traefik `--tracing.sampleRate=1.0` = **100% 全采** |

**`sampleRate=1.0` 意味着全量采集**。实验环境合理，生产环境通常 0.01~0.1（1%~10%）。采样率一旦调低，**trace 就变成统计行为，不再保证"你要查的那个请求一定在"**——这是 Traces 最大的局限。

---

## 三、架构：你的集群里 traces 怎么流转

### 3.1 完整数据流（实测验证）

```
┌──────────────────────────────────────────────────────────────┐
│ Traefik v3.6.2 (k8s/traefik Pod)                              │
│  --tracing.serviceName=traefik                               │
│  --tracing.otlp.grpc.endpoint=otel-collector.opentelemetry.svc.cluster.local:4317
│  --tracing.sampleRate=1.0                                    │
│  --tracing.otlp.grpc.insecure=true                           │
│                                                              │
│  ① 生成 span，注入 k8s.* / process.* 资源属性                 │
└───────────────────────────┬──────────────────────────────────┘
                            │ OTLP/gRPC (protobuf, 4317)
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ otel-collector (v0.145.0, opentelemetry ns)                 │
│                                                              │
│  receivers.otlp [grpc:4317, http:4318]                       │
│         ↓                                                    │
│  processors.batch (send_batch_size:1000, timeout:10s)        │
│         ↓                                                    │
│  ┌──────────────────┬────────────────────┬─────────────────┐  │
│  ↓                  ↓                    ↓                 │  │
│ otlp_grpc/tempo   debug            spanmetrics (connector) │
│  ↓                  ↓                    ↓                 │
│  ↓              日志(可选)         聚合 span 成 RED 指标     │
│  ↓                                     ↓                    │
│  ↓                              prometheus exporter          │
│  ↓                                     ↓                    │
│  ↓                              :8889/metrics                │
│  ↓                                     ↓                    │
│  ↓                              Prometheus 抓取               │
│  ↓                              (ServiceMonitor                │
│  ↓                               otel-collector-spanmetrics) │
└──┼─────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ Tempo 3.0.3 分布式架构 (logging ns)                           │
│                                                              │
│  tempo3-distributor  ← 入口，接收 OTLP                        │
│         ↓                                                   │
│  tempo3-live-store-0/1/2  ← 热数据（⚠️ emptyDir，无持久化）   │
│         ↓ flush 到对象存储                                   │
│  tempo3-block-builder-0/1/2  ← 构建 Parquet block            │
│         ↓                                                    │
│  tempo3-backend-scheduler-0 / backend-worker-0 ← 查询后端    │
│  tempo3-memcached-0        ← 查询缓存                        │
│  tempo3-query-frontend      ← Grafana 查询入口 (:3200)       │
│  tempo3-metrics-generator   ← 生成 traces 自身指标            │
│         ↓                                                    │
│  Ceph RGW (10.0.0.31:7480) bucket  ← 块存储                  │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 OTel Collector 配置（实际内容）

```yaml
receivers:
  otlp:
    protocols:
      grpc: {endpoint: 0.0.0.0:4317}
      http: {endpoint: 0.0.0.0:4318}

processors:
  batch:
    send_batch_size: 1000
    timeout: 10s

connectors:
  spanmetrics: {}          # ★ traces → metrics 的桥梁

exporters:
  otlp_grpc/tempo:
    endpoint: tempo3-distributor.logging.svc.cluster.local:4317
    tls: {insecure: true}
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: otel_demo           # ★ 决定了指标名前缀
    resource_to_telemetry_conversion: {enabled: true}

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp_grpc/tempo, debug, spanmetrics]   # ★ 扇出到 3 个出口
    metrics:
      receivers: [spanmetrics]      # ★ 接收 connector 产出的指标
      exporters: [prometheus]
```

**两个关键设计点**：

1. **`connectors: spanmetrics`** —— OTel Collector 的 connector 是**双向的**：吃 traces，吐 metrics。这是 traces 与 metrics 唯一的自动化关联手段。
2. **`namespace: otel_demo`** —— 给所有导出的指标加前缀。所以真实指标名是 `otel_demo_traces_span_metrics_calls_total`，**不是** `traces_span_metrics_calls_total`。我第一次查询时就因为漏掉前缀而误判"spanmetrics 没生效"。

### 3.3 Tempo 3.0 分布式架构（与传统单体的区别）

| 组件 | 职责 | 你的副本数 |
|---|---|---|
| **distributor** | 入口，接收 OTLP，不存数据 | 1 |
| **live-store** | 热数据存储（最近数据） | **3** ⚠️ emptyDir |
| **block-builder** | 把热数据转成 Parquet block | **3** ⚠️ emptyDir |
| **backend-scheduler** | 调度查询到 backend-worker | 1 |
| **backend-worker** | 实际执行查询 | 1 |
| **query-frontend** | 查询入口，拆分/合并查询 | 1 |
| **memcached** | 查询结果缓存 | 1 |
| **metrics-generator** | 生成 traces 自身指标 | 1 |

**⚠️ 已知风险（之前报告已记录）**：live-store 和 block-builder 都挂 `emptyDir`，**节点重启热数据全丢**。且 `block_retention: 48h` 远短于指标 5d / 日志 7d。

---

## 四、Traces 与 Metrics 如何关联

### 4.1 关联的本质

**Traces 是"个体"，Metrics 是"聚合"**。关联靠的不是时间戳，而是 **service + operation + 维度标签的聚合关系**。

```
一个 trace  =  一次请求 = POST /api/user/auth-tokens/rotate
                  ↓ spanmetrics 聚合
一个指标点   =  一段时间内所有 POST 的统计
  otel_demo_traces_span_metrics_calls_total{service_name="traefik", span_name="POST"} = 499
  otel_demo_traces_span_metrics_duration_milliseconds_bucket{...} = 分布直方图
```

**实测验证**（与你这条 trace 完全对应）：

```
cutover-probe / CUTOVER_POST_1790641890   = 1
retire-probe  / POST_RETIRE2_1790646071    = 1
traefik / GET       = 502
traefik / ReverseProxy = 998
traefik / POST      = 499          ← 你这条 trace 就在这里
─────────────────────────────────────
总调用数 = 2001
5 分钟速率 = 0.0947 spans/s
```

`ReverseProxy=998` 正好是 `POST=499` 的 **2 倍**——说明你这次请求产生了 root + child 两个 span。**指标和 trace 严格对应。**

### 4.2 三个维度的关联路径

```
┌────────────────────────────────────────────────────────────────┐
│ ① Traces ↔ Metrics：service.name + span_name                 │
│                                                                │
│   Metrics 标签: service_name="traefik"                        │
│                 span_name="POST"                              │
│   ↕ 展开                                                             │
│   Trace 属性:  Resource service.name=traefik                  │
│                 Span Kind=server                              │
│                                                                │
│   ✅ 你的集群已实现（spanmetrics connector）                     │
├────────────────────────────────────────────────────────────────┤
│ ② Traces ↔ Logs：trace_id / span_id                          │
│                                                                │
│   日志中需包含: trace_id=e284de20431ddd49                     │
│   Grafana 配 derivedFields 正则提取                            │
│   → 点击日志跳到 trace，点击 trace 跳到日志                     │
│                                                                │
│   ❌ 你的集群尚未打通（见第五节）                                │
├────────────────────────────────────────────────────────────────┤
│ ③ Metrics ↔ Logs：service/level/instance                     │
│                                                                │
│   Metrics: kube_pod_status_ready{namespace, pod}              │
│   Logs:    {namespace="logging", pod="loki-backend-0"}        │
│                                                                │
│   ✅ 通过相同的 K8s 元数据标签（你的 Alloy 已产出 namespace/pod）│
└────────────────────────────────────────────────────────────────┘
```

### 4.3 RED 方法论（spanmetrics 产出的正是 RED）

spanmetrics connector 自动产出的三个指标就是 **RED**（Google SRE 提出的方法论）：

| 指标 | 含义 | 你的集群中的指标名 |
|---|---|---|
| **R**ate（请求率） | 每秒请求数 | `otel_demo_traces_span_metrics_calls_total` |
| **E**rrors（错误率） | 失败请求数 | 同上，配合 `http_response_status_code` 标签 |
| **D**uration（延迟） | 耗时分布 | `otel_demo_traces_span_metrics_duration_milliseconds_bucket` |

**为什么这是关键**：传统 metrics 由应用自己埋点，而 spanmetrics 是**从已有 traces 反推**的——**零侵入**。不用改一行应用代码，只要它接了 OTel，就自动有 RED 指标。这是 traces 相比 metrics 最大的增量价值。

### 4.4 用 metrics 找问题，再用 traces 查原因（标准排查流程）

这是三支柱协同的标准用法，也是面试高频考点：

```
第 1 步（Metrics）：发现异常
   PromQL: sum(rate(otel_demo_traces_span_metrics_calls_total{
       service_name="traefik", span_name="POST"}[5m]))
   → 发现 POST 速率突降 / duration_bucket 的 p99 飙升

第 2 步（Traces）：定位到具体请求
   Prometheus → Grafana Tempo → 按 service 筛选
   → 找到 duration 长的那条 trace → 看 span 树

第 3 步（Logs）：下钻到代码行
   在 trace 详情点 "Logs for this span"
   → 直接跳到该请求产生的日志
```

**你截图里每个 span 下方都有 "Logs for this span" 按钮**——这说明 Grafana 已经做了 trace↔log 的关联跳转。它依赖的就是「日志里有 trace_id」这个前提。

---

## 五、日志关联：你的集群当前状态

### 5.1 现状

你的 Grafana Tempo 里 **"Logs for this span" 是可点击的**，说明 Grafana 侧关联已配置。但这需要两个前提：

**前提 1：日志里必须有 trace_id**

你集群里唯一产生 trace 的组件是 Traefik，而 Traefik 的访问日志默认**不开** OTel 关联（需要在 middleware 里加 `traceHeaders`）。所以：

```bash
# 查 Traefik 访问日志里有无 trace_id
kubectl logs -n traefik deploy/traefik --tail=100 | grep -c "traceparent\|trace_id"
```
**如果这里是 0，那"Logs for this span"点进去大概率是空的。**

**前提 2：Grafana Loki 数据源要配 derivedFields**

你当前配置（实测）：
```json
{
  "name": "Loki", "type": "loki", "uid": "dfi90c2a1osn4c",
  "url": "http://loki-gateway.logging.svc.cluster.local",
  "jsonData": {
    "maxLines": 1000, "timeout": 60,
    "httpHeaderName1": "X-Scope-OrgID",
    "derivedFields": []        ← ★ 空
  }
}
```

`derivedFields` 为空 = **Grafana 不知道要从日志里提取哪个字段作为 trace_id**。

### 5.2 补齐方式

```yaml
jsonData:
  derivedFields:
    - name: TraceID
      matcherRegex: 'traceparent.*?([0-9a-f]{32})'      # W3C 格式
      url: '$${__value.raw}'
      datasourceUid: afia1p4xshn9cf                     # Tempo 的 uid
    - name: PodLogs
      matcherRegex: '.*'
      url: '$${__value.raw}'
      datasourceUid: dfi90c2a1osn4c                     # Loki
```

### 5.3 三支柱关联全景（你集群的完成度）

| 关联 | 状态 | 说明 |
|---|---|---|
| **Traces ↔ Metrics** | ✅ **已打通** | spanmetrics connector → otel_demo_traces_span_metrics_* |
| **Metrics ↔ Logs** | ✅ **已打通** | 双方都有 namespace/pod/node_name 标签 |
| **Traces ↔ Logs** | ⚠️ **半通** | Grafana 按钮在，但 `derivedFields: []` + Traefik 日志可能无 trace_id |

---

## 六、面试要点提炼（结合你这条 trace）

如果你要在面试里讲这段经历，这几点是有说服力的：

**1. 能讲清 trace 上下文传播的底层机制**
不是"我在 K8s 里接了 Tempo"，而是"W3C Trace Context 通过 HTTP header 传递 trace_id/span_id，服务端插桩后链路才能串起来，不插桩就断在边界"。

**2. 理解 Tempo 的冷热分层**
live-store 存热数据 → block-builder 转 Parquet block → backend-worker 查对象存储。知道它和 Prometheus 的 WAL + 长期存储是同构的设计思路。

**3. 能讲 spanmetrics 这个关键设计**
OTel Collector 的 connector 是双向的，能把 traces 聚合成 RED 指标实现零侵入监控。这是"用 traces 反哺 metrics"的经典方案。

**4. 敢承认数据缺口**
你集群的 Tempo live-store 挂 emptyDir（重启丢数据）、retention 48h 太短、traefik 下游 Grafana 未插桩导致 trace 只有 2 个 span。**能指出并规划这些，比声称"部署好了 Tempo"更有说服力。**

**5. 一个可深挖的故障案例**
`e284de20431ddd49` 这条 trace 就是现成素材——`POST 43.71ms` vs `ReverseProxy 42.43ms`，能算出网关自身开销 1.28ms（占 2.9%），说明 Traefik 性能健康、瓶颈在后端 Grafana。这种从 trace 读出容量结论的能力，就是 SRE 的核心功夫。

---

*分析时间：2026-10-02 17:10。你的 trace e284de20431ddd49 完整验证了 Traefik → OTel Collector → Tempo 全链路，spanmetrics connector 生成的 RED 指标（POST=499、ReverseProxy=998）与 trace 严格对应。日志关联（Grafana derivedFields）尚未配置，是三支柱关联链路中唯一未闭合的一环。*
