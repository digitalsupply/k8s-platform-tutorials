# Knative 架构、概念、组件关系与实验指南

> 本文档基于当前实际集群环境分析编写，旨在结合主流 Knative 生产应用场景，设计一系列可一步步操作、验证和逐步掌握 Knative 运维的实验。

## 1. 概述

Knative 是一个构建在 Kubernetes 上的开源 Serverless 平台，主要分为两个核心模块：

- **Knative Serving**：提供无服务器（Serverless）应用的部署、自动扩缩容（Scale-to-Zero）、流量管理（路由、灰度、金丝雀）、服务版本管理（Revisions）等能力。
- **Knative Eventing**：提供事件驱动架构（EDA）的构建能力，支持事件的产生（Sources）、路由（Brokers/Triggers/Channels/Subscriptions）、消费（Sinks）以及事件流模式（Flows）。

本集群当前采用 **Knative Operator** 管理 Serving（v1.22.0），Eventing 为手动部署（数据面使用 Kafka Broker，部分组件为 Loom 架构），网络层使用 **Kourier** 作为 Ingress，事件总线使用 **Knative Kafka Broker**，后端消息存储依赖 **Kafka** 集群。

---

## 2. 核心概念

### 2.1 Knative Serving 核心概念

| 概念 | 说明 |
|---|---|
| `Service (ksvc)` | Knative Serving 的顶层资源，定义一个可路由、可扩缩容的服务。它将 `Configuration`、`Route`、`Revision` 的生命周期自动管理在一起，是最常用的抽象。 |
| `Revision` | 服务的不可变版本。每次代码/配置变更（如镜像、环境变量、注解等）都会创建一个新的 Revision。Revision 是 Knative 扩缩容、流量路由的最小粒度单位。 |
| `Configuration` | 描述服务的期望状态（Pod 模板、容器、资源限制等），负责创建和跟踪 Revisions。Configuration 的变更会触发新的 Revision 生成。 |
| `Route` | 管理服务的网络流量路由规则。可以将流量按百分比分配到不同的 Revisions，实现蓝绿部署、金丝雀发布、A/B 测试等。 |
| `DomainMapping` | 将自定义域名映射到 Knative Route/Service，用于暴露集群外部访问域名。 |
| `ServerlessService (Sks)` | Serving 网络子系统的内部资源（通常由控制器自动创建），用于在 Scale-to-Zero 和有流量之间平滑切换（Activator 与 Queue-Proxy 协作）。 |

### 2.2 自动扩缩容（Autoscaling）

Knative Autoscaler 支持多种策略和粒度：

| 组件/概念 | 说明 |
|---|---|
| `KPA`（Knative Pod Autoscaler） | Knative 默认的 Pod Autoscaler，基于请求并发（Concurrency）或每秒请求数（RPS）进行扩缩容，支持 Scale-to-Zero（缩容到 0 副本）。 |
| `HPA`（Horizontal Pod Autoscaler） | Kubernetes 原生 HPA，可通过 `autoscaling.knative.dev/class: hpa.autoscaling.knative.dev` 指定使用，通常基于 CPU/Memory 指标。 |
| `Scale-to-Zero` | 当一段时间（`scale-to-zero-grace-period`，默认 30s）没有请求到达时，Revision 会缩容至 0 个 Pod。首次请求会经过 `Activator` 缓冲并触发冷启动（Cold Start）。 |
| `Activator` | Serving 数据平面的关键组件。在服务缩容到 0 或流量突增时，Activator 会接收传入请求、缓冲请求并协助 Pod 启动，之后将流量转发至 `Queue-Proxy`。 |
| `Queue-Proxy` | 每个用户 Pod 旁边的 Sidecar（由 Knative 注入），负责流量接入、并发控制、请求指标采集（暴露给 Autoscaler）、重试/超时等。 |
| `containerConcurrency` | 单个容器可同时处理的最大并发请求数。配合目标利用率（`container-concurrency-target-percentage`，默认 70%）决定扩缩容副本数。 |
| `minScale/maxScale` | Revision 的最小/最大副本数，可通过注解 `autoscaling.knative.dev/min-scale`、`autoscaling.knative.dev/max-scale` 覆盖集群默认值。 |
| `initialScale` | Revision 创建后的初始副本数。 |

### 2.3 Knative Eventing 核心概念

| 概念 | 说明 |
|---|---|
| `Event` | 符合 CloudEvents 规范（v1.0） 的事件数据，包含 `id`、`source`、`type`、`specversion`、`time`、`data` 等属性。 |
| `Source` | 事件源，负责从外部系统（定时器、API Server、消息队列、Git、Webhook 等）产生事件并发送到 Sink。常见类型：`PingSource`、`ApiServerSource`、`ContainerSource`、`SinkBinding`、`KafkaSource` 等。 |
| `Sink` | 事件的接收端，可以是 Knative Service（ksvc）、Broker、Channel、KafkaSink 或任何符合 Addressable 的资源（暴露 `status.address.url`）。 |
| `Broker` | 事件中转/分发中心（Event Hub），接收所有事件（Ingress）并根据 `Trigger` 的过滤规则路由到订阅者。支持多种 Broker 实现（`MTChannelBasedBroker`、`KafkaBroker`、`RabbitMQBroker` 等）。 |
| `Trigger` | 订阅 Broker 上的事件，支持基于 CloudEvents 属性（`type`、`source`、`subject`、扩展属性等）的过滤（`filter.attributes`），并将匹配的事件转发到 `subscriber`（可引用 ksvc/Addressable）。 |
| `Channel` | 基于消息通道的点对点/多订阅模型（类似 Pub/Sub 的 Channel），配合 `Subscription` 使用。支持 In-Memory、KafkaChannel 等实现。 |
| `Subscription` | 将 Channel 的事件订阅到特定的 Subscriber（Sink），支持 `reply`（响应回 Channel）和 `deadLetterSink`（死信）。 |
| `Flow` | 高级事件流编排：`Sequence`（顺序处理链路）、`Parallel`（并行分支处理）。 |
| `EventType` | 对 Broker 上流转事件类型的描述和发现（配合 `eventtype-auto-create` 特性）。 |
| `DeadLetterSink (DLS)` | 当事件处理失败（重试耗尽）时，将事件转发到的备份 Sink，用于异常处理、审计或重放。 |

### 2.4 CloudEvents

Knative Eventing 严格遵循 [CloudEvents](https://cloudevents.io/) 规范，所有事件在组件间以标准化格式传递，保证可移植性和互操作性。本集群中 `PingSource` 产生的事件类型为 `dev.knative.sources.ping`。

---

## 3. Knative 架构详解

### 3.1 整体架构

Knative 采用控制平面（Control Plane）和数据平面（Data Plane）分离的设计：

- **Control Plane**：由一系列 Controllers（Reconciler）组成，负责监听 CRD、调谐期望状态与实际状态（Deployment/Service/Route/Revision/Broker/Trigger 等）。
- **Data Plane**：负责实际的请求转发和事件流转，由 Activator、Queue-Proxy、Ingress Gateway（Kourier/Envoy）、Eventing Data Plane（Broker Dispatcher/Receiver、Kafka Broker Data Plane）等组件承载。

### 3.2 Serving 架构与组件

| 组件（命名空间 knative-serving） | 类型 | 作用 |
|---|---|---|
| `controller` | Deployment | Serving 控制器核心，负责 Reconcile `Service`、`Configuration`、`Route`、`Revision`，创建对应的 K8s 资源（Deployment、Service、Ingress/Kingress 等）。 |
| `webhook` | Deployment | Admission/Webhook，负责 CRD 的校验（Validation）、默认值注入（Defaulting）、转换（Conversion）以及 Pod 修改（注入 Queue-Proxy Sidecar）。 |
| `autoscaler` | Deployment | Knative Pod Autoscaler（KPA）控制器，收集指标、计算期望副本数并控制 Revision 的可用性/伸缩决策。 |
| `autoscaler-hpa` | Deployment | HPA 控制器适配器，用于当指定使用原生 HPA 时协调伸缩。 |
| `activator` | Deployment | 数据平面请求入口缓冲器。处理 Scale-to-Zero 场景的冷启动、流量突增保护（Burst Capacity）、请求代理转发至就绪 Pod。暴露 Service `activator-service`（9090/8008/80/443 等）。 |
| `net-kourier-controller` | Deployment | Kourier Ingress 控制器（Knative Networking 层适配器），监听 `Ingress`/Knative 网络资源，生成 Envoy 配置并控制 Kourier Gateway。 |
| `3scale-kourier-gateway` | Deployment（HPA） | Kourier 数据面网关，基于 Envoy 实现，负责外部流量到集群内 Knative 服务的路由和 TLS 终止（当前未启用外部 TLS）。Service 类型为 `LoadBalancer`（EXTERNAL-IP `10.0.0.253`，端口 80/443）。 |
| `Queue-Proxy` | Sidecar（自动注入） | 每个 Revision Pod 中注入的容器，位于用户容器前，负责并发限流、健康检查转发、请求日志、指标暴露（`/metrics`）、超时控制等。镜像见 `config-deployment.queue-sidecar-image`。 |

**流量路径（Serving）**：

1. 外部请求 → LoadBalancer（kourier `10.0.0.253:80/443`） → Envoy（3scale-kourier-gateway）
2. Envoy 根据 Host/Path 路由到对应的 Knative Service（Route 映射）
3. 若 Revision 副本数 == 0（Scale-to-Zero）：流量先到达 `Activator`（缓冲）→ 触发 Autoscaler 启动 Pod → Pod Ready 后 Activator 将请求转发至 Queue-Proxy → 用户容器
4. 若有就绪 Pod：流量经 Envoy/Kourier 直接或通过网络路径到达 Queue-Proxy → 用户容器（视配置和网络拓扑而定，Kourier 模式下通常由 Gateway 路由到 Pod ClusterIP）
5. 内部集群调用可直接使用 `ksvc.status.address.url`（ClusterLocal 域名 `http://<name>.<ns>.svc.cluster.local`）

### 3.3 Eventing 架构与组件

本集群 Eventing 采用 **Knative Kafka Broker**（Broker.class: Kafka）实现，数据面使用 Kafka 作为事件存储/缓冲。

| 组件（命名空间 knative-eventing） | 类型 | 作用 |
|---|---|---|
| `eventing-controller` | Deployment | Eventing 控制器核心，Reconcile `Broker`、`Trigger`、`Subscription`、`Source`、`Channel`、`Flow` 等 CR，创建必要的配置和数据面资源。 |
| `eventing-webhook` | Deployment | Eventing Admission Webhook，校验和默认值注入。 |
| `kafka-controller` | Deployment | Knative Kafka Broker 控制平面组件，负责为 Kafka Broker/Trigger 创建和管理 Kafka 相关资源（Topics、Consumer Groups、Dispatcher 配置等），维护 `kafka-broker-brokers-triggers` ConfigMap 等。 |
| `kafka-webhook-eventing` | Deployment | Kafka Broker/Webhook 相关校验。 |
| `kafka-broker-receiver` | Deployment | Kafka Broker **Ingress/Receiver**（接收端），接收来自 Sources/Sinks 外部调用的 HTTP 事件请求（CloudEvents over HTTP），将事件写入对应的 Kafka Topic。对外暴露 Service `kafka-broker-ingress`（80/443/8080/8443/9090）。 |
| `kafka-broker-dispatcher` | StatefulSet | Kafka Broker **Dispatcher**（分发端），从 Kafka Topic 消费事件，根据 Triggers 的过滤规则和订阅关系，将事件投递到各 Subscriber（ksvc/Sink）。是事件路由的核心数据面。 |
| `pingsource-mt-adapter` | Deployment | PingSource 多租户适配器（Multi-Tenant Adapter），负责根据 `PingSource` CR 定时触发（Cron）并发送 CloudEvents 到指定 Sink（本例为 central-broker）。 |
| `job-sink` | Deployment/Service | JobSink 组件（Eventing Sinks 扩展），用于将事件转发到 Kubernetes Job 执行批处理任务（实验中可按需使用）。 |

**事件流路径（Eventing，Kafka Broker）**：

1. **事件源（Source）**：`PingSource`（由 `pingsource-mt-adapter` 按 Cron 调度）构造 CloudEvents（`type=dev.knative.sources.ping`，`source=/apis/v1/namespaces/default/pingsources/hourly-report-source`，`data` 为 JSON），通过 HTTP POST 发送到 Sink。
2. **写入 Broker**：Sink 指向 `Broker`（`central-broker`），地址为 `http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/central-broker`。请求到达 `kafka-broker-receiver`，校验 CloudEvents，写入 Kafka Topic（本例 `knative-broker-default-central-broker`，1 Partition，ReplicationFactor 1，bootstrap `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`）。
3. **消费与路由**：`kafka-broker-dispatcher`（StatefulSet）消费该 Topic，结合 `Trigger`（`filter-health-report-trigger`，过滤 `type=dev.knative.sources.ping`）匹配到 Subscriber `http://report-processor.default.svc.cluster.local`（Knative Service `report-processor`）。
4. **事件处理**：事件经 Serving 网络（ClusterLocal）到达 `report-processor` Revision Pod（Queue-Proxy → 用户容器 `gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest`），`event_display` 将事件日志打印到标准输出，可通过 `kubectl logs` 查看。

> 注：Kafka Broker 的 Topic 命名模板见 `config-kafka-features`：`brokers-topic-template: knative-broker-{{ .Namespace }}-{{ .Name }}`，ConsumerGroup 模板 `triggers-consumergroup-template: knative-trigger-{{ .Namespace }}-{{ .Name }}`。

### 3.4 网络（Ingress）—— Kourier

当前集群 Serving 网络使用 **Kourier**（基于 Envoy Proxy）：

- `ingress-class: kourier.ingress.networking.knative.dev`（配置于 `config-network`）
- Knative Operator 启用 `ingress.kourier.enabled: true`
- 数据面：`3scale-kourier-gateway`（Deployment + HPA），Service `kourier` 类型 `LoadBalancer`，外部 IP `10.0.0.253`，暴露 80/443
- 控制面：`net-kourier-controller` 将 Knative Route/Ingress 翻译为 Envoy xDS 配置，下发到 Gateway
- Knative 会自动创建 `KnativeIngress (Kingress)` 资源（可见 `autoscale-demo`、`hello`、`report-processor` 均 Ready）

相比 Istio，Kourier 更轻量、资源占用较低，适合中小规模及简化的生产环境。本集群域名后缀配置为 `hao.com`（`config-domain`），因此 ksvc 可通过 `http://<name>.<namespace>.hao.com` 对外访问（需将 `10.0.0.253` 解析到该域名，或本地 /etc/hosts 配置）。

### 3.5 Operator 与版本

- **Knative Serving**：由 `KnativeServing` CR（`operator.knative.dev/v1beta1`，namespace `knative-serving`，name `knative-serving`）管理，当前版本 `1.22.0`，manifests 路径 `/var/run/ko/knative-serving/1.22.0`、`/var/run/ko/ingress/1.22/kourier`。
- **Knative Eventing**：当前未见 `KnativeEventing` CR（items 空），推测为**手动部署**（YAML 直接应用），Eventing 相关组件镜像 tag 多为 `@sha256`（固定版本），Kafka Broker 相关镜像包含 `knative-kafka-broker-*`（Loom 架构变体 `-loom`）。

> **Loom 架构**：Knative Kafka Broker 在近期版本引入了 Loom（基于虚拟线程/调度优化的执行模型）相关构建（`knative-kafka-broker-receiver-loom`、`knative-kafka-broker-dispatcher-loom`），用于提升事件消费的并发性和资源利用率，是 Kafka Broker 数据面在性能方向的演进。

### 3.6 特性开关（Feature Flags）

- **Serving `config-features`**：多容器 `multi-container: enabled`，EmptyDir 卷 `kubernetes.podspec-volumes-emptydir: enabled`，其余多为默认/disabled（安全上下文、Host 网络/IPC/PID、InitContainer、PVC 写等按需开启）。
- **Eventing `config-features`**：`delivery-timeout: enabled`，其余如 `authentication-oidc`、`transport-encryption`、`eventtype-auto-create`、`cross-namespace-event-links` 均 `disabled`（生产环境若需安全加固可逐步开启）。
- **Kafka Broker `config-kafka-features`**：`dispatcher-rate-limiter: disabled`、`controller-autoscaler-keda: disabled`，Topic/ConsumerGroup 模板已配置。

### 3.7 可观测性（Observability）

Serving 配置：
- `metrics.backend-destination: prometheus`、`metrics.request-metrics-backend-destination: prometheus`
- `metrics-protocol: http/protobuf`，`metrics-endpoint`、`request-metrics-endpoint` 指向 `http://promstack-kube-prometheus-prometheus.observability:9090/api/v1/otlp/v1/metrics`（OTLP Push）
- Tracing：`tracing-protocol: http/protobuf`，`tracing-endpoint: http://jaeger-collector.observability:4318/v1/traces`，采样率 `1`
- Request Logging：默认 `logging.enable-request-log: false`（可按需开启用于调试）

Eventing `config-observability` 同样配置了日志/追踪相关模板（默认未开启请求日志）。

> 生产实践：建议开启请求日志（采样）、分布式追踪（Jaeger/Tempo）、指标（Prometheus) 并配合告警。

---

## 4. 各组件关系与作用总结

| 层级 | Serving | Eventing | 作用 |
|---|---|---|---|
| **API/CRD** | Service, Configuration, Route, Revision, DomainMapping | Broker, Trigger, Source (Ping/API/Container/SinkBinding/Kafka), Channel, Subscription, Sequence/Parallel, EventType, JobSink | 声明式 API，抽象业务意图 |
| **控制平面** | controller, webhook, autoscaler, autoscaler-hpa, net-kourier-controller | eventing-controller, webhook, kafka-controller, kafka-webhook | 状态调谐、版本管理、路由生成、资源编排 |
| **网络入口** | Kourier (Envoy Gateway, LoadBalancer 10.0.0.253) | Kafka Broker Receiver (kafka-broker-ingress Service) | 外部流量入口/事件入口（HTTP/CloudEvents） |
| **请求缓冲/保护** | Activator + Queue-Proxy (Sidecar) | — | 冷启动、并发控制、指标采集、流量整形 |
| **数据平面（转发）** | Envoy (Kourier) → Queue-Proxy → User Container | Receiver → Kafka → Dispatcher → Subscriber (ksvc) | 实际流量/事件传递 |
| **自动伸缩** | KPA/HPA（基于并发/RPS/CPU）+ Scale-to-Zero | Dispatcher 消费速率、KEDA（当前未启用） | 弹性与成本优化 |
| **事件存储/缓冲** | — | Kafka（Topics/ConsumerGroups） | 解耦、持久化、重放、背压控制 |

**关键协作关系**：
- `ksvc` → 自动生成 Revision（不可变）+ Route（流量）+ Configuration（模板）
- Kourier 控制器监听 Kingress/Ingress → 下发 Envoy 路由规则到 Gateway
- Activator 与 Autoscaler 配合实现 Scale-to-Zero 的平滑冷启动
- PingSource（adapter）→ CloudEvents → Kafka Broker Receiver → Kafka Topic → Dispatcher → Trigger Filter → ksvc（report-processor）
- Broker（Kafka）通过 Topic 隔离，每个 Trigger 对应 ConsumerGroup（`knative-trigger-<ns>-<name>`），实现多订阅者独立消费进度。

---

## 5. 主流 Knative 生产应用场景

基于 Knative 的 Serverless + Eventing 特性，以下为主流生产落地场景及其适用性分析：

| 场景 | Knative 模块 | 核心资源 | 生产价值 | 注意事项 |
|---|---|---|---|---|
| **Serverless HTTP API/微服务** | Serving | `Service (ksvc)` + `Route`（流量分配）+ HPA/KPA | 按请求付费、自动扩缩容、Scale-to-Zero 降本、快速迭代、蓝绿/金丝雀发布 | 冷启动敏感场景需优化（预热、minScale>0、保持活动实例）、设置合理超时/并发限制 |
| **实时事件处理（ETL/清洗/转换）** | Eventing + Serving | `Broker` + `Trigger` + `ksvc`（Sink） | 解耦上游（Kafka/DB/CDC/Webhook），异步处理、背压控制、易扩展 | 需考虑幂等性、重试策略、DeadLetterSink、消息顺序（Kafka 分区） |
| **定时任务（CronJob 替代/增强）** | Eventing | `PingSource` → `Sink`（ksvc/JobSink/Broker） | 声明式定时事件、与事件总线打通、可观测性统一（CloudEvents）、失败重试 | 与 K8s CronJob 对比：事件化、可路由到 Broker 进行多下游分发 |
| **异步任务队列/工作流触发** | Eventing | `Broker` + `Trigger` + `Sequence/Parallel` | 事件驱动工作流、串行/并行编排、故障隔离 | 复杂编排建议结合 Argo/Temporal，Knative Flows 适合轻量级 |
| **流式处理桥接（Kafka 源/汇）** | Eventing | `KafkaSource` → Sink、Sink → `KafkaSink` | 将 Kafka 主题事件转换为 CloudEvents 或反向写回 Kafka，打通现有消息平台 | 需注意消费位移（ConsumerGroup）、批处理、反压 |
| **AI/ML 推理（推理服务）** | Serving | `ksvc` + GPU（需 NodeSelector/RuntimeClass）+ `minScale` 控制预热池 | 按需扩缩容、流量灰度（AB 测试模型版本）、多版本 Revision 管理 | 大模型冷启动较重，建议 `minScale>=1` 或预热（`initialScale`、扩缩容窗口调优）、资源配额、队列深度控制 |
| **Webhook/API 网关后端** | Serving + Eventing | ksvc（同步）或 Broker（异步校验/通知） | 弹性应对突发 Webhook（如 GitHub、CI/CD） | Scale-to-Zero 冷启动对低延迟 Webhook 可能影响，按业务 SLA 调整 |
| **CDC/数据变更事件** | Eventing（外部 Source） | 外部 Source（Debezium）→ KafkaSource/Broker → ksvc | 数据事件流、最终一致性、微服务解耦 | 需保证事件顺序性（按主键/分区）、Schema 演进（CloudEvents + Schema Registry） |
| **批处理/离线任务触发** | Eventing | `PingSource`/自定义 Source → `JobSink` 或直接触发 K8s Job | 事件驱动批处理、失败重试、资源限制、自动清理 | JobSink 将事件映射为 Job 参数，适合按事件触发一次性任务 |

> **生产建议**：对于延迟敏感型服务（SLA < 500ms 冷启动要求高），建议设置 `autoscaling.knative.dev/min-scale: "1"`（保留预热 Pod），避免 Scale-to-Zero 冷启动；对于流量波动大且非关键的后台任务，可充分利用 Scale-to-Zero 降本。

---

## 6. 实验设计（循序渐进掌握 Knative 运维）

> 所有实验基于当前集群实际资源（Kourier LB `10.0.0.253`，域名 `hao.com`，Kafka Broker 已就绪，现有 `hello`、`autoscale-demo`、`report-processor`、`central-broker`、`hourly-report-source`、`filter-health-report-trigger` 可作为参考）。建议按顺序执行，每个实验独立可验证，包含预期结果和排障要点。

### 实验前置：环境检查与本地访问配置

**目的**：确认网络可达性，便于 curl 验证外部访问。

```bash
# 1. 检查 Kourier LB
kubectl get svc kourier -n knative-serving

# 2. 本地 hosts 配置（可选，便于使用 *.hao.com 域名访问）
# echo "10.0.0.253 hello.default.hao.com autoscale-demo.default.hao.com report-processor.default.hao.com" >> /etc/hosts
ping -c 1 10.0.0.253
```

**预期**：kourier Service EXTERNAL-IP 为 `10.0.0.253`，网络可达。

---

### 实验 1：Knative Serving 基础 —— 部署第一个 ksvc 并验证

**目的**：理解 `Service (ksvc)`、`Revision`、`Route` 自动创建流程，验证外部访问路径。

**步骤 1.1：创建测试服务 `lab-hello`**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-hello
  namespace: default
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "1"
        autoscaling.knative.dev/max-scale: "3"
        autoscaling.knative.dev/target: "10"
    spec:
      containerConcurrency: 0
      containers:
      - name: user-container
        image: ghcr.io/knative/helloworld-go:latest
        env:
        - name: TARGET
          value: "Lab Hello from Knative"
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
EOF
```

**步骤 1.2：观察资源创建（控制平面自动创建）**

```bash
# 查看 ksvc 状态
kubectl get ksvc lab-hello -w

# 查看 Configuration、Route、Revision
kubectl get configuration,route,revision -l serving.knative.dev/service=lab-hello

# 查看 Pod（min-scale=1 会创建 1 个 Pod）
kubectl get pods -l serving.knative.dev/service=lab-hello

# 查看 KnativeIngress
kubectl get kingress -A | grep lab-hello
```

**预期**：`READY=True`，LatestReadyRevision 存在，Pod Running，Kingress Ready。

**步骤 1.3：验证访问**

```bash
# ClusterLocal 内部访问（最稳定，绕过 Ingress）
curl -s http://lab-hello.default.svc.cluster.local

# 通过 Kourier 外部域名访问（需 hosts 配置或 DNS 解析 10.0.0.253 到 *.hao.com）
curl -s -H "Host: lab-hello.default.hao.com" http://10.0.0.253

# 或直接使用域名（已配 hosts）
curl -s http://lab-hello.default.hao.com
```

**预期输出**：`Hello Lab Hello from Knative!`

**验证要点**：理解 ksvc 自动管理 Configuration/Route/Revision 三者关系。

---

### 实验 2：流量管理 —— 蓝绿/金丝雀发布（Traffic Splitting）

**目的**：掌握 Revision 版本切换和百分比分流，实现零停机发布。

**步骤 2.1：更新服务，触发新 Revision**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-hello
  namespace: default
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "1"
        autoscaling.knative.dev/max-scale: "5"
    spec:
      containers:
      - name: user-container
        image: ghcr.io/knative/helloworld-go:latest
        env:
        - name: TARGET
          value: "Lab Hello - v2 (Canary)"
        ports:
        - containerPort: 8080
EOF
```

**步骤 2.2：查看新旧 Revision**

```bash
kubectl get revisions -l serving.knative.dev/service=lab-hello --sort-by=.metadata.creationTimestamp
# 记录两个 Revision 名称（例如 lab-hello-00001、lab-hello-00002）
```

**步骤 2.3：配置流量按比例分配（金丝雀）**

> 假设旧版为 `lab-hello-00001`，新版为 `lab-hello-00002`（按实际名称替换）。

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-hello
  namespace: default
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "1"
        autoscaling.knative.dev/max-scale: "5"
    spec:
      containers:
      - name: user-container
        image: ghcr.io/knative/helloworld-go:latest
        env:
        - name: TARGET
          value: "Lab Hello - v2 (Canary)"
        ports:
        - containerPort: 8080
  traffic:
  - revisionName: lab-hello-00001
    percent: 80
  - revisionName: lab-hello-00002
    percent: 20
    tag: canary
EOF
```

**步骤 2.4：验证流量分配**

```bash
# 连续访问 20 次，观察 v1/v2 比例（约 8:2）
for i in $(seq 1 20); do
  curl -s http://lab-hello.default.hao.com
  echo
done
```

**预期**：大部分返回 `Hello Lab Hello from Knative!`（v1 环境变量未变动？注意 helloworld-go 回显 TARGET：`Hello ${TARGET}!`，v1 TARGET 是 "Lab Hello from Knative"，v2 是 "Lab Hello - v2 (Canary)"，因此应看到两种不同响应，比例约 8:2）。

**步骤 2.5：按 Tag 路由（稳定访问 Canary）**

```bash
curl -s -H "Host: canary-lab-hello.default.hao.com" http://10.0.0.253
# 或通过 tag 域名（Knative 根据 tag-template 构建子域名：{{.Tag}}-{{.Name}}.{{.Namespace}}.{{.Domain}}）
curl -s http://canary-lab-hello.default.hao.com
```

**预期**：全部返回 v2 响应。

**步骤 2.6：全量切换到新版**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-hello
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: ghcr.io/knative/helloworld-go:latest
        env:
        - name: TARGET
          value: "Lab Hello - v2 (Canary)"
        ports:
        - containerPort: 8080
  traffic:
  - latestRevision: true
    percent: 100
EOF
```

**预期**：全部流量指向最新 Revision，旧 Revision 在 GC 策略（`config-gc`：retain 48h/最少20非活跃）下按配置保留或清理。

---

### 实验 3：自动扩缩容（KPA）与 Scale-to-Zero

**目的**：验证基于并发的自动扩缩容、冷启动（Activator）和 Scale-to-Zero 行为，理解 Queue-Proxy 指标作用。

**步骤 3.1：部署压测服务 `lab-autoscale`**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-autoscale
  namespace: default
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "0"        # 允许 Scale-to-Zero
        autoscaling.knative.dev/max-scale: "10"
        autoscaling.knative.dev/target: "5"           # 每个 Pod 目标并发 5
        autoscaling.knative.dev/metric: "concurrency"
        autoscaling.knative.dev/window: "60s"
        autoscaling.knative.dev/panic-window-percentage: "10.0"
    spec:
      containerConcurrency: 10                        # 单容器最大并发
      timeoutSeconds: 120
      containers:
      - name: user-container
        image: gcr.io/knative-samples/knative-route-demo:latest
        ports:
        - containerPort: 8080
        env:
        - name: T_VERSION
          value: "lab-autoscale-v1"
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
EOF
```

**等待 Ready**：

```bash
kubectl get ksvc lab-autoscale -w
curl -s http://lab-autoscale.default.hao.com
```

**步骤 3.2：验证 Scale-to-Zero（空闲收缩）**

```bash
# 观察初始副本（首次访问后可能有 1 个）
kubectl get pods -l serving.knative.dev/service=lab-autoscale -w

# 静置 90s（大于 scale-to-zero-grace-period 30s + 稳定窗口影响）
sleep 95
kubectl get pods -l serving.knative.dev/service=lab-autoscale
kubectl get revision -l serving.knative.dev/service=lab-autoscale
```

**预期**：静置后 Pod 数降至 0（Scale-to-Zero）。Revision 仍存在（非活跃但未达到 GC 删除条件）。

**步骤 3.3：冷启动验证（Activator 路径）**

```bash
# 第一次请求（冷启动）—— 记录耗时
time curl -s http://lab-autoscale.default.hao.com

# 立即再次请求（热路径）
time curl -s http://lab-autoscale.default.hao.com
```

**预期**：首次请求耗时明显高于第二次（冷启动：Pod 启动 + 就绪探测 + Activator 缓冲转发）。可通过 `kubectl logs -n knative-serving deploy/activator -f`（可选）观察请求代理过程。

**步骤 3.4：并发压测触发扩容**

> 使用 `hey`、`ab`、`wrk` 或简单 shell 循环并发。这里用 bash 并发背景请求模拟突发流量。

```bash
# 后台并发 50 个请求（持续 30s）
for i in $(seq 1 50); do
  curl -s http://lab-autoscale.default.hao.com >/dev/null &
done
wait

# 观察扩容过程
kubectl get pods -l serving.knative.dev/service=lab-autoscale -w &
PID=$!
sleep 30
kill $PID 2>/dev/null
kubectl get pods -l serving.knative.dev/service=lab-autoscale
```

**预期**：并发请求导致副本数从 0/1 向上扩容（受 `target=5`、`containerConcurrency=10`、`max-scale=10` 限制），Autoscaler 根据平均并发计算期望副本数。

**步骤 3.5：流量下降后的缩容**

```bash
# 停止压测，静置观察缩容
sleep 120
kubectl get pods -l serving.knative.dev/service=lab-autoscale
```

**预期**：副本数逐步缩减，最终在 `scale-to-zero-grace-period` 后缩至 0。

**分析要点**：对比 `stable-window`（60s）、`panic-window-percentage`（10%）、`max-scale-up/down-rate` 对扩缩容敏感度的影响。

---

### 实验 4：Eventing 基础 —— 理解 Broker、Trigger、Source 的事件流

**目的**：基于现有 `central-broker` + `hourly-report-source` + `report-processor`，手动验证事件链路并观测 CloudEvents。

**步骤 4.1：查看现有事件链路状态**

```bash
kubectl get broker,trigger,pingsource -A
kubectl get ksvc report-processor
```

**步骤 4.2：观测 PingSource 定时事件（每 2 分钟触发一次）**

```bash
# 实时查看 report-processor 的日志（event_display 会打印完整 CloudEvents）
kubectl logs -l serving.knative.dev/service=report-processor -f --tail=30
```

**预期**：每隔 2 分钟出现一条 CloudEvents 日志，包含 `id`、`source`、`specversion`、`type=dev.knative.sources.ping`、`time`、`datacontenttype: application/json`、`data: {"status":"UP","disk_usage":"72%","memory_free_gb":16}`。

> 按 `*/2 * * * *` 调度，需等待下次触发或执行 4.3 手动触发验证。

**步骤 4.3：临时修改 PingSource 调度频率，加快验证（可选演练）**

```bash
# 将调度改为每 30s 一次，便于快速验证
kubectl patch pingsource hourly-report-source -n default --type=merge -p '{"spec":{"schedule":"*/30 * * * *"}}'
sleep 40
kubectl logs -l serving.knative.dev/service=report-processor --tail=15
```

**预期**：30s 内能看到新事件日志。实验完成后可改回 `*/2 * * * *`：

```bash
kubectl patch pingsource hourly-report-source -n default --type=merge -p '{"spec":{"schedule":"*/2 * * * *"}}'
```

**步骤 4.4：手动发送 CloudEvents 到 Broker（直接验证 Receiver → Kafka → Dispatcher）**

> 使用 `curl` 直接向 Kafka Broker Ingress 发送符合 CloudEvents v1.0 的 HTTP 请求，绕过 Source，验证事件路由链路。

```bash
curl -i -X POST \
  -H "Content-Type: application/cloudevents+json" \
  -H "ce-specversion: 1.0" \
  -H "ce-type: dev.knative.lab.test" \
  -H "ce-source: /lab/manual-test" \
  -H "ce-id: $(uuidgen 2>/dev/null || date +%s%N)" \
  -H "ce-time: $(date -Iseconds)" \
  -d '{"message":"Hello from manual CloudEvent","severity":"info"}' \
  http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/central-broker
```

**预期**：HTTP 返回 2xx（202/200）。由于当前 Trigger `filter-health-report-trigger` 的过滤条件是 `type=dev.knative.sources.ping`，**手动发送的 `ce-type: dev.knative.lab.test` 不会匹配该 Trigger**，因此 `report-processor` 日志**不会**出现该事件。

**验证过滤生效**：确认日志未新增该条目。

---

### 实验 5：自定义 Trigger 过滤与多订阅者

**目的**：掌握 Trigger 的 `filter.attributes`（基于 CloudEvents 属性过滤），理解一个 Broker 可有多个 Trigger 路由到不同 Subscriber。

**步骤 5.1：创建第二个 Subscriber `lab-event-logger`**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-event-logger
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest
EOF
```

等待 Ready：

```bash
kubectl get ksvc lab-event-logger
```

**步骤 5.2：创建 Trigger，过滤手动测试事件类型**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: lab-manual-test-trigger
  namespace: default
  labels:
    eventing.knative.dev/broker: central-broker
spec:
  broker: central-broker
  filter:
    attributes:
      type: dev.knative.lab.test
      source: /lab/manual-test
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: lab-event-logger
      namespace: default
EOF
```

**步骤 5.3：重新发送手动 CloudEvent**

```bash
curl -i -X POST \
  -H "Content-Type: application/cloudevents+json" \
  -H "ce-specversion: 1.0" \
  -H "ce-type: dev.knative.lab.test" \
  -H "ce-source: /lab/manual-test" \
  -H "ce-id: $(uuidgen 2>/dev/null || date +%s%N)" \
  -d '{"message":"Manual test routed to lab-event-logger","test":true}' \
  http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/central-broker
```

**步骤 5.4：验证路由到正确的 Subscriber**

```bash
# lab-event-logger 应收到该事件
kubectl logs -l serving.knative.dev/service=lab-event-logger --tail=10

# report-processor 不应收到（类型不匹配）
kubectl logs -l serving.knative.dev/service=report-processor --tail=2
```

**预期**：`lab-event-logger` 日志出现 `dev.knative.lab.test` 事件，`report-processor` 无新增。

**结论**：Broker + Trigger 实现基于属性的事件路由（Content-Based Routing），一个事件可被 0、1 或多个 Trigger 匹配（多订阅者广播）。

**步骤 5.5：清理实验资源（可选）**

```bash
kubectl delete trigger lab-manual-test-trigger
kubectl delete ksvc lab-event-logger
```

---

### 实验 6：创建自有 Broker 与事件链路（端到端实践）

**目的**：从零创建 Kafka Broker、Source、Trigger、Sink，深度理解控制平面如何自动创建 Kafka Topic、ConsumerGroup。

**步骤 6.1：创建自定义 Kafka Broker `lab-broker`**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: eventing.knative.dev/v1
kind: Broker
metadata:
  name: lab-broker
  namespace: default
  annotations:
    eventing.knative.dev/broker.class: Kafka
spec:
  config:
    apiVersion: v1
    kind: ConfigMap
    name: kafka-broker-config
    namespace: knative-eventing
EOF
```

**观察创建过程**：

```bash
kubectl get broker lab-broker -w
# 等待 READY=True
```

**查看 Broker 状态（Topic 创建情况）**

```bash
kubectl get broker lab-broker -o yaml | grep -B2 -A40 'status:' | head -40
```

**预期**：`TopicReady=True`，`DataPlaneAvailable=True`，`Ready=True`，`address.url` 指向 `kafka-broker-ingress.knative-eventing.svc.cluster.local/default/lab-broker`，Topic 名称 `knative-broker-default-lab-broker`（按模板生成）。

**验证 Kafka Topic 是否创建（可选，需有 Kafka 客户端工具）**

```bash
# 如集群有 kafka CLI，可在 kafka pod 内执行
# kubectl exec -it -n kafka my-cluster-kafka-0 -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep lab-broker
```

**步骤 6.2：创建 Sink（事件消费者）**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: lab-sink
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest
EOF
kubectl get ksvc lab-sink
```

**步骤 6.3：创建 PingSource，每 10 秒发送一次自定义事件**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: sources.knative.dev/v1
kind: PingSource
metadata:
  name: lab-ping
  namespace: default
spec:
  schedule: "*/10 * * * *"
  contentType: "application/json"
  data: '{"source":"lab-ping","env":"test","msg":"heartbeat"}'
  sink:
    ref:
      apiVersion: eventing.knative.dev/v1
      kind: Broker
      name: lab-broker
EOF
```

等待 Deployed/Ready：

```bash
kubectl get pingsource lab-ping
```

**步骤 6.4：创建 Trigger，将事件路由到 lab-sink**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: lab-ping-trigger
  namespace: default
  labels:
    eventing.knative.dev/broker: lab-broker
spec:
  broker: lab-broker
  filter:
    attributes:
      type: dev.knative.sources.ping
      source: /apis/v1/namespaces/default/pingsources/lab-ping
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: lab-sink
      namespace: default
EOF
```

**等待 Ready**：

```bash
kubectl get trigger lab-ping-trigger
```

**步骤 6.5：验证端到端事件流**

```bash
# 等待 15s，观察 lab-sink 日志
sleep 15
kubectl logs -l serving.knative.dev/service=lab-sink --tail=20
```

**预期**：日志中出现 CloudEvents，`type=dev.knative.sources.ping`，`source=/apis/v1/namespaces/default/pingsources/lab-ping`，`data` 为 `{"source":"lab-ping","env":"test","msg":"heartbeat"}`。

**步骤 6.6：验证事件未匹配时不路由（负向验证）**

```bash
# 向 lab-broker 发送不同 type
curl -i -X POST \
  -H "Content-Type: application/cloudevents+json" \
  -H "ce-specversion: 1.0" \
  -H "ce-type: custom.event" \
  -H "ce-source: /test" \
  -H "ce-id: test-001" \
  -d '{"x":1}' \
  http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/lab-broker

sleep 2
kubectl logs -l serving.knative.dev/service=lab-sink --tail=5
```

**预期**：自定义事件未出现在 lab-sink 日志（被过滤）。

**步骤 6.7：清理实验 6 资源**

```bash
kubectl delete pingsource lab-ping
kubectl delete trigger lab-ping-trigger
kubectl delete ksvc lab-sink
kubectl delete broker lab-broker
```

---

### 实验 7：ApiServerSource —— 监听 Kubernetes API 事件

**目的**：掌握 `ApiServerSource`，将 K8s 资源变更（如 Pod/ConfigMap 创建）转换为 CloudEvents 并路由到 Sink，用于审计、告警、自动化。

**前置**：Eventing 支持 ApiServerSource（CRD `apiserversources.sources.knative.dev` 已存在）。

**步骤 7.1：创建 ServiceAccount 并授予所需 RBAC**

ApiServerSource 需要权限读取目标资源。

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apiserversource-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: apiserversource-role
  namespace: default
rules:
- apiGroups: [""]
  resources: ["events", "pods", "configmaps", "secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: apiserversource-rolebinding
  namespace: default
subjects:
- kind: ServiceAccount
  name: apiserversource-sa
  namespace: default
roleRef:
  kind: Role
  name: apiserversource-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

**步骤 7.2：创建 Sink**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: apiserver-sink
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest
EOF
```

**步骤 7.3：创建 ApiServerSource（监听 ConfigMap 变更）**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: sources.knative.dev/v1
kind: ApiServerSource
metadata:
  name: configmap-watcher
  namespace: default
spec:
  serviceAccountName: apiserversource-sa
  mode: Resource
  resources:
  - apiVersion: v1
    kind: ConfigMap
  sink:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: apiserver-sink
      namespace: default
EOF
```

**等待 Ready**：

```bash
kubectl get apiserversources configmap-watcher
```

**步骤 7.4：触发事件（创建/更新 ConfigMap）**

```bash
# 创建 ConfigMap 触发 ADD 事件
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-test-cm
  namespace: default
data:
  key1: value1
EOF

# 更新 ConfigMap 触发 UPDATE 事件
kubectl patch cm lab-test-cm -n default --type=merge -p '{"data":{"key2":"value2"}}'

# 删除 ConfigMap 触发 DELETE 事件（取决于 mode/config）
kubectl delete cm lab-test-cm -n default
```

**步骤 7.5：查看事件日志**

```bash
sleep 5
kubectl logs -l serving.knative.dev/service=apiserver-sink --tail=60
```

**预期**：日志中出现 CloudEvents，`type` 为 `dev.knative.apiserver.resource.add/update/delete`（或 K8s 事件类型变体），`source` 指向 API Server 资源路径，`data` 包含 ConfigMap 的 ObjectReference/变更信息。

**分析要点**：`mode: Resource`（资源事件） vs `mode: Reference`（引用事件），`resources` 可指定多个 GroupVersionKind，适合配置漂移审计、合规、自动化响应等生产场景。

**清理**：

```bash
kubectl delete apiserversources configmap-watcher
kubectl delete rolebinding apiserversource-rolebinding role apiserversource-role
kubectl delete sa apiserversource-sa
kubectl delete ksvc apiserver-sink
```

---

### 实验 8：SinkBinding —— 将现有 K8s 工作负载事件化

**目的**：掌握 `SinkBinding`，无需修改应用代码，将现有 Deployment/Job 的生命周期事件或自定义事件“绑定”到 Sink（常用于将传统应用接入 Eventing）。

**步骤 8.1：创建 Sink**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: sinkbinding-sink
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest
EOF
```

**步骤 8.2：创建 SinkBinding（绑定到 Deployment）**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: sources.knative.dev/v1
kind: SinkBinding
metadata:
  name: lab-sinkbinding
  namespace: default
spec:
  subject:
    apiVersion: apps/v1
    kind: Deployment
    name: lab-app
  sink:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: sinkbinding-sink
      namespace: default
EOF
```

**步骤 8.3：创建被绑定的 Deployment `lab-app`**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-app
  namespace: default
  labels:
    app: lab-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lab-app
  template:
    metadata:
      labels:
        app: lab-app
    spec:
      containers:
      - name: app
        image: busybox:1.36
        command: ["/bin/sh","-c"]
        args:
        - |
          echo "Starting app..."
          # 模拟产生 CloudEvents（可选：应用本身也可发送 CE）
          sleep 3600
EOF
```

**观察**：SinkBinding 会向 `lab-app` Pod 模板注入环境变量（`K_SINK`、`K_CE_OVERRIDES` 等 CloudEvents 相关元数据），使应用可感知 Sink 地址并发送符合 CloudEvents 的事件。对于不直接发送事件的应用，SinkBinding 更多用于“标记”或配合支持 CloudEvents 的框架使用。

**验证 Pod 环境变量是否注入**：

```bash
POD=$(kubectl get pods -l app=lab-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- env | grep K_
```

**预期**：应看到 `K_SINK=<sinkbinding-sink URL>`、`K_CE_*` 等环境变量（SinkBinding 控制器注入）。

**清理**：

```bash
kubectl delete deployment lab-app
kubectl delete sinkbinding lab-sinkbinding
kubectl delete ksvc sinkbinding-sink
```

---

### 实验 9：KafkaSource（可选进阶）—— 从 Kafka 主题消费事件到 Knative

**目的**：了解 `KafkaSource`（Eventing Kafka）如何将外部 Kafka 主题的消息转换为 CloudEvents 并投递到 Sink。本集群已部署 Kafka（`my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`），可选实验。

> 注意：KafkaSource 属于 Knative Eventing Kafka Sources，与 Kafka Broker 不同（Broker 是“推入式”事件总线，Source 是“拉取式”消费外部 Kafka）。

**前置**：确认 Kafka 可用，创建测试 Topic（如已有可跳过）。

```bash
# 创建测试 Topic（需 kafka CLI）
# kubectl exec -it -n kafka my-cluster-kafka-0 -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic lab-kafka-source --partitions 1 --replication-factor 1
```

**步骤 9.1：创建 Sink**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: kafkasrc-sink
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: user-container
        image: gcr.io/knative-releases/knative.dev/eventing/cmd/event_display:latest
EOF
```

**步骤 9.2：创建 ServiceAccount + RBAC（KafkaSource 需）**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafkasrc-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kafkasrc-role
  namespace: default
rules:
- apiGroups: ["sources.knative.dev"]
  resources: ["kafkasources"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kafkasrc-rb
  namespace: default
subjects:
- kind: ServiceAccount
  name: kafkasrc-sa
  namespace: default
roleRef:
  kind: Role
  name: kafkasrc-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

**步骤 9.3：创建 KafkaSource**

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: sources.knative.dev/v1beta1
kind: KafkaSource
metadata:
  name: lab-kafka-source
  namespace: default
spec:
  bootstrapServers:
  - my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
  topics:
  - lab-kafka-source
  consumerGroup: knative-kafkasrc-default-lab-kafka-source
  net:
    tls:
      enable: false
  sink:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: kafkasrc-sink
      namespace: default
EOF
```

**等待 Ready**：

```bash
kubectl get kafkasources lab-kafka-source
```

**步骤 9.4：向 Kafka Topic 发送消息**

```bash
# 向 Topic 发送原始 JSON（KafkaSource 会将其封装为 CloudEvents）
kubectl exec -it -n kafka my-cluster-kafka-0 -- bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic lab-kafka-source
# 输入： {"orderId":"o001","amount":100}
```

**步骤 9.5：验证转换为 CloudEvents**

```bash
sleep 3
kubectl logs -l serving.knative.dev/service=kafkasrc-sink --tail=20
```

**预期**：日志显示 CloudEvents，`source` 指向 Kafka 主题/服务器，`type` 为 KafkaSource 默认类型（`dev.knative.kafka.event` 或按配置），`data` 为原始消息内容。

**清理**：

```bash
kubectl delete kafkasources lab-kafka-source
kubectl delete rolebinding kafkasrc-rb role kafkasrc-role sa kafkasrc-sa
kubectl delete ksvc kafkasrc-sink
# kubectl exec -it -n kafka my-cluster-kafka-0 -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic lab-kafka-source
```

---

### 实验 10：可观测性与运维排障

**目的**：掌握 Knative 日志、指标、追踪、Pod 注入、Webhook、网络排障的常用方法。

#### 10.1 查看组件日志

```bash
# Serving 控制平面
kubectl logs -n knative-serving deploy/controller -f --tail=40
kubectl logs -n knative-serving deploy/webhook -f --tail=30
kubectl logs -n knative-serving deploy/autoscaler -f --tail=40
kubectl logs -n knative-serving deploy/activator -f --tail=40
kubectl logs -n knative-serving deploy/net-kourier-controller -f --tail=40
kubectl logs -n knative-serving deploy/3scale-kourier-gateway -f --tail=40

# Eventing 控制平面
kubectl logs -n knative-eventing deploy/eventing-controller -f --tail=40
kubectl logs -n knative-eventing deploy/eventing-webhook -f --tail=30
kubectl logs -n knative-eventing deploy/kafka-controller -f --tail=40
kubectl logs -n knative-eventing deploy/kafka-broker-receiver -f --tail=40
kubectl logs -n knative-eventing sts/kafka-broker-dispatcher -f --tail=40
kubectl logs -n knative-eventing deploy/pingsource-mt-adapter -f --tail=40
```

#### 10.2 查看用户 Revision 日志（Queue-Proxy + User Container）

```bash
# 查看 Pod
kubectl get pods -l serving.knative.dev/service=lab-hello

# User container 日志（Queue-Proxy sidecar 存在）
kubectl logs <pod> -c user-container --tail=30
kubectl logs <pod> -c queue-proxy --tail=30
```

#### 10.3 检查 Conditions（故障诊断核心）

Knative 大量使用 `status.conditions`，`Ready=True` 是健康标志。常见排查对象：ksvc、revision、route、broker、trigger、pingsource。

```bash
# ksvc 全量 Conditions
kubectl get ksvc lab-hello -o jsonpath='{.status.conditions}' | jq '.'

# Revision 就绪状态
kubectl get revision -l serving.knative.dev/service=lab-hello -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions}{"\n"}{end}' | jq .

# Broker/Trigger
kubectl get broker lab-broker -o jsonpath='{.status.conditions}' | jq '.'
kubectl get trigger lab-ping-trigger -o jsonpath='{.status.conditions}' | jq '.'
```

**常见非 Ready 原因**：镜像拉取失败（ImagePullBackOff）、探针失败（Readiness/Liveness）、资源不足（Pending）、网络配置错误、Kafka Topic/ConsumerGroup 异常（Broker/Trigger）、RBAC 权限不足（ApiServerSource）。

#### 10.4 检查 Knative Ingress 与外部可达性

```bash
# Kingress 状态
kubectl get kingress -A
kubectl describe kingress lab-hello -n default

# Kourier Gateway Endpoints
kubectl get endpoints -n knative-serving -l app=3scale-kourier-gateway

# DNS/Hosts 验证
nslookup lab-hello.default.hao.com 2>/dev/null || echo "需配置 DNS 指向 10.0.0.253"
curl -v -H "Host: lab-hello.default.hao.com" http://10.0.0.253 -o /dev/null
```

#### 10.5 Webhook 健康检查

```bash
# Serving Webhook
kubectl get pods -n knative-serving -l app=webhook
kubectl get endpoints webhook -n knative-serving

# Eventing Webhook
kubectl get pods -n knative-eventing -l app=eventing-webhook
```

#### 10.6 配置验证（ConfigMaps）

```bash
# 核心配置速览
kubectl get cm config-network config-domain config-autoscaler config-features -n knative-serving -o jsonpath='{.items[*].metadata.name}{"\n"}'
kubectl get cm config-features config-kafka-features kafka-broker-config -n knative-eventing
```

#### 10.7 指标采集验证（Prometheus/OTLP）

```bash
# Queue-Proxy 指标（任一 Revision Pod）
POD=$(kubectl get pods -l serving.knative.dev/service=lab-autoscale -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] && kubectl port-forward pod/$POD 9090:9090 &
PF=$!
sleep 2
curl -s http://localhost:9090/metrics | grep -E 'queue_.*requests|revision_request_count' | head -10
kill $PF 2>/dev/null
```

**预期**：能看到 Queue-Proxy 暴露的请求并发/延迟等指标（用于 KPA 决策）。

#### 10.8 事件追踪（Tracing）

集群已配置 Jaeger Collector（`tracing-endpoint: http://jaeger-collector.observability:4318/v1/traces`，采样率 1.0）。可通过 Jaeger UI 查询 Serving 请求链路和 Eventing 事件链路（需访问 observability 命名空间的 Jaeger Service/Ingress）。

---

### 实验 11：生产最佳实践与运维清单

**目的**：将实验知识固化为生产运维规范。

| 维度 | 最佳实践 | 建议配置/检查项 |
|---|---|---|
| **安全** | 关闭不必要的特性，启用 TLS、最小 RBAC | 评估 `transport-encryption`、`authentication-oidc`（Eventing），Serving 内部 TLS（`system-internal-tls` Alpha），镜像签名（Cosign/Notary） |
| **可靠性** | 设置合理超时、重试、DeadLetterSink | `timeoutSeconds`、Eventing Delivery（重试/重试后退/超时/DLS），Broker/Trigger 配置 DLS |
| **弹性** | 区分关键/非关键服务的 Scale-to-Zero 策略 | 延迟敏感：`minScale>=1`（预热池）；后台任务：`minScale=0` 节省成本；设置 `initialScale`、`maxScale` 限流 |
| **性能** | 冷启动优化、资源请求限制、并发调优 | 优化镜像体积（Distroless）、`containerConcurrency`、`target`、Queue-Proxy 资源（`config-deployment`）、KPA 窗口参数 |
| **网络** | 域名规划、TLS 终止、Ingress 配置 | `config-domain` 管理外部域名，ClusterLocal 域名用于内部调用，Kourier LB 高可用 |
| **事件治理** | 幂等性、Schema、事件顺序、背压 | Kafka 分区键保证顺序，ConsumerGroup 管理，DLS+重试策略，CloudEvents Schema（EventType） |
| **可观测性** | 日志采集、指标告警、链路追踪 | 开启请求日志（采样）、Prometheus 告警（冷启动时延、错误率、队列深度）、Jaeger 分布式追踪 |
| **版本管理** | 流量灰度、回滚、Revision 保留 | Traffic Splitting（实验 2），GC 策略（`config-gc`）按保留时长/数量平衡存储 |
| **运维** | 变更审计、配置管理（GitOps） | 所有 CR 用 GitOps（ArgoCD/Flux）管理，KnativeServing/KnativeEventing CR 纳入配置基线，镜像用不可变 Tag/Digest |
| **排障** | 条件优先、日志关联、逐层排查 | 先查 `status.conditions`（Ready/Reason）→ 控制平面日志 → 数据面（Activator/Queue-Proxy/Dispatcher/Receiver）→ 网络（Kingress/Kourier/Kafka） |

---

## 7. 附录

### 7.1 当前集群关键信息速览

| 项目 | 值 |
|---|---|
| Kubernetes | v1.29.8 |
| Knative Serving | v1.22.0（Operator 管理，KnativeServing CR） |
| Knative Eventing | 手动部署（Kafka Broker，Loom 架构镜像） |
| Ingress | Kourier（Envoy），LoadBalancer `10.0.0.253`，80/443 |
| IngressClass | `kourier.ingress.networking.knative.dev` |
| 域名后缀 | `hao.com` |
| Broker 实现 | Kafka Broker（`eventing.knative.dev/broker.class: Kafka`） |
| Kafka Bootstrap | `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| Eventing 特性 | `delivery-timeout: enabled`，OIDC/TransportEncryption/EventTypeAutoCreate 未启用 |
| Serving 特性 | `multi-container: enabled`，`emptyDir: enabled` |

### 7.2 常用调试命令速查表

| 操作 | 命令 |
|---|---|
| 查看所有 ksvc | `kubectl get ksvc -A` |
| 查看所有 Revisions | `kubectl get revisions -A --sort-by=.metadata.creationTimestamp` |
| 查看 Kingress | `kubectl get kingress -A` |
| 强制重建 Revision（触发新版本） | 更新 ksvc spec.template（任意注解/标签/env 变更即可） |
| 进入 Revision Pod | `kubectl exec -it <pod> -c user-container -- sh` |
| 查看 Queue-Proxy 指标 | `kubectl port-forward pod/<pod> 9090:9090 && curl localhost:9090/metrics` |
| 发送 CloudEvent（Broker） | `curl -i -X POST -H "Content-Type: application/cloudevents+json" -H "ce-specversion:1.0" -H "ce-type:xxx" -H "ce-source:/x" -H "ce-id:$(date +%s)" -d '{}' http://kafka-broker-ingress.knative-eventing.svc.cluster.local/<ns>/<broker>` |
| 查看 Autoscaler 决策日志 | `kubectl logs -n knative-serving deploy/autoscaler -f` |
| 查看 Activator 请求日志 | `kubectl logs -n knative-serving deploy/activator -f` |

### 7.3 参考资料

- [Knative Docs](https://knative.dev/docs/) — 官方文档
- [Knative Serving Concepts](https://knative.dev/docs/serving/concepts/)
- [Knative Eventing Concepts](https://knative.dev/docs/eventing/concepts/)
- [CloudEvents Specification](https://cloudevents.io/)
- [Knative Kafka Broker](https://knative.dev/docs/eventing/brokers/broker-types/kafka-broker/)
- [Kourier Ingress](https://github.com/3scale/kourier)

---

**结语**

本指南基于实际集群现状（Serving 1.22.0 + Kourier + Kafka Broker Eventing）编写，实验设计循序渐进：从基础部署、流量管理、自动扩缩容，到事件驱动（Broker/Trigger/Source/ApiServerSource/SinkBinding），再到可观测性与生产运维实践。建议按顺序完成所有实验并验证预期结果，逐步掌握 Knative 的架构原理与日常运维能力。