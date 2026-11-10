# default 命名空间 Pod 来源与关联资源分析

- **分析时间**：2026-10-02 17:40
- **范围**：default ns 全部 Pod 的创建者、ownerReference 链路、依赖资源

---

## 一、结论速览

default ns 现有 **4 个 Pod**（不含 netshoot），来源分两类，**没有任何一个是人为创建的 Deployment**：

| Pod | 类型 | 谁创建 | 是否 Knative |
|---|---|---|---|
| `hello-00003-deployment-6b69c65796-8jwps` | Knative Revision | **Knative Serving 控制器** | ✅ Serving |
| `report-processor-00001-deployment-675b668fc7-rzr2b` | Knative Revision | **Knative Eventing + Serving** | ✅ Serving（被 Eventing 触发）|
| `trf-doc` | **裸 Pod** | 人工 `kubectl run` | ❌ 无 |
| `netshoot-debug-54c86b9985-n8vcl` | Deployment | 人工（调试用）| ❌ 无 |

**核心区别**：`hello` / `report-processor` 的 ownerReference 链末端是 ReplicaSet，但**往上追溯到 Knative 自定义资源**；`trf-doc` **完全没有 ownerReference**，是脱离控制器的孤儿 Pod。

---

## 二、Pod 1：hello-00003（Knative Serving）

### 2.1 ownerReference 链

```bash
kubectl get pod hello-00003-deployment-6b69c65796-8jwps -n default   -o jsonpath='{.metadata.ownerReferences}'
```
```json
[{"kind":"ReplicaSet","name":"hello-00003-deployment-6b69c65796","controller":true}]
```

**这是最容易被误判的一点**：ownerReference 指向 ReplicaSet，看起来像普通 Deployment——但 ReplicaSet 上面是 **Knative 自己生成的 Deployment**，再往上是 Knative 自定义资源。

### 2.2 完整依赖链（6 层，实测全部存在）

```
service.serving.knative.dev/hello                    ← 用户创建的 KService
        url = http://hello.default.hao.com
              │
              ▼
configuration.serving.knative.dev/hello              ← 用户创建的模板
              │  (template.spec: ghcr.io/knative/helloworld-go)
              ▼
revision.serving.knative.dev/hello-00003             ← Knative 自动版本化
        generation=3, status=ResourcesAvailable
              │  ★ Knative Serving 控制器在这里
              │    把 KRevision「翻译」成 K8s Deployment
              ▼
deployment.apps/hello-00003-deployment              ← Knative 生成，非人手创建
        replicas=1
        containers:
          user-container = ghcr.io/knative/helloworld-go   ← 用户的镜像
          queue-proxy    = knative.dev/serving/cmd/queue    ← Knative 注入
              │
              ▼
replicaset.apps/hello-00003-deployment-6b69c65796   ← K8s Deployment 生成
              │
              ▼
pod/hello-00003-deployment-6b69c65796-8jwps         ← 最终 Pod（2/2 Running）
```

### 2.3 关键标签（证明归属 Knative）

```json
{
  "serving.knative.dev/service":       "hello",
  "serving.knative.dev/revision":       "hello-00003",
  "serving.knative.dev/configuration":  "hello",
  "serving.knative.dev/configurationGeneration": "3",
  "serving.knative.dev/revisionUID":   "af114c1c-7132-4d8d-87d3-a5646772d62f",
  "serving.knative.dev/serviceUID":    "c5108b07-1af6-4f58-9ce0-4e343a99885b",
  "pod-template-hash":                  "6b69c65796"
}
```

### 2.4 为什么有 2 个容器

```
user-container   ghcr.io/knative/helloworld-go    ← 用户代码
queue-proxy      knative.dev/serving/cmd/queue   ← Knative 数据面
```

`queue-proxy` 是 Knative 的**数据面**：负责
- 接收 Kourier Ingress 转来的请求
- 并发控制（最大并发请求数）
- 请求排队与超时控制
- 指标上报（QPS / 并发数 / 拒绝数）

它**必须与用户容器同 Pod 生命周期**——用户容器缩容到 0 时它也一起停，所以能实现「缩容到零」。

环境变量也证实了归属：
```
K_REVISION=hello-00003
K_CONFIGURATION=hello
TARGET=Knative
```

### 2.5 访问入口

```yaml
# Knative Route / KService
url: http://hello.default.hao.com
# 解析过程
hello.default.hao.com
  → Kourier Ingress（knative-serving ns）
  → ExternalName Service: hello → kourier-internal.knative-serving.svc.cluster.local
  → Kourier → queue-proxy → user-container
```

---

## 三、Pod 2：report-processor（Knative Serving，被 Eventing 触发）

### 3.1 这是本次分析中最有价值的发现

`report-processor` 表面上是一个 Knative Service，但它的**真正驱动者是 Eventing 链路的定时任务**。**如果删掉它，上游的 PingSource 会持续报错。**

### 3.2 完整触发链（实测）

```
pingsource.sources.knative.dev/hourly-report-source
    schedule: */2 * * * *          ← ★ 每 2 分钟触发一次
    sink: Broker/central-broker
        │
        ▼
broker.eventing.knative.dev/central-broker
    URL: http://kafka-broker-ingress.knative-eventing.svc.cluster.local
         /default/central-broker
    status.url: http://kafka-broker-ingress.knative-eventing.svc.cluster.local
                /default/central-broker   (Ready=True)
        │  ★ Broker 后端是 Kafka（Strimzi 部署）
        │    事件不是内存队列，会真实写入 Kafka topic
        ▼
trigger.eventing.knative.dev/filter-health-report-trigger
    broker: central-broker
    subscriber: http://report-processor.default.svc.cluster.local   ← ★ 指向 Pod 2
        │
        ▼
service.serving.knative.dev/report-processor
    url: http://report-processor.default.hao.com
        │
        ▼
revision.serving.knative.dev/report-processor-00001
        │
        ▼
deployment.apps/report-processor-00001-deployment
        containers:
          user-container = knative.dev/eventing/cmd/event_display   ← ★ 注意：不是业务代码
          queue-proxy    = knative.dev/serving/cmd/queue
        │
        ▼
pod/report-processor-00001-deployment-675b668fc7-rzr2b
```

### 3.3 一个 EventType（事件契约）

```yaml
eventtype.eventing.knative.dev/fcb2cefc76f2b3649a1c0387a99a137a
    source:   /apis/v1/namespaces/default/pingsources/hourly-report-source
    reference: central-broker (Broker)
    description: CloudEvent type for fixed payloads on a specified cron schedule
    readiness: True
```
这是 PingSource → Broker 之间的**事件契约**：约定 CloudEvent 的 type 字段，保证 Trigger 只接收匹配的事件。

### 3.4 完整架构图

```
                    ┌──────────────────────────────────────┐
                    │  PingSource (*/2 * * * *)            │
                    │  定时产生 CloudEvent                  │
                    └──────────────────┬───────────────────┘
                                       ↓
                    ┌──────────────────────────────────────┐
                    │  Broker: central-broker              │
                    │  后端 → Kafka (Strimzi)              │
                    └──────────────────┬───────────────────┘
                                       ↓ 订阅
                    ┌──────────────────────────────────────┐
                    │  Trigger: filter-health-report-trigger│
                    └──────────────────┬───────────────────┘
                                       ↓
                    ┌──────────────────────────────────────┐
                    │  Service: report-processor            │
                    │  image: knative.dev/eventing/         │
                    │         cmd/event_display             │
                    │  （官方演示接收器，非业务代码）        │
                    └──────────────────────────────────────┘
```

### 3.5 另一个 Broker 未被使用

```yaml
broker.eventing.knative.dev/order-broker   # Ready=True，但无 Trigger 订阅
```
**`order-broker` 是孤立的**——没有任何 Trigger 订阅它。可能是实验时建的示例，遗留至今。

---

## 四、Pod 3：trf-doc（裸 Pod，孤儿资源）

### 4.1 判定为人工创建的依据

```json
{
  "metadata": {
    "labels": {"run": "trf-doc"},          ← ★ kubectl run 的默认 label 格式
    "ownerReferences": []                    ← ★ 空，完全无属主
  },
  "spec": {
    "nodeName": "worker03",
    "restartPolicy": "Never",                ← ★ kubectl run 默认值
    "containers": [{
      "name": "trf-doc",
      "image": "docker.io/traefik:v3.6.2",  ← ★ 与 traefik ns 主容器同版本
      "command": ["traefik"],                ← ★ 仅启动，无任何参数
      "resources": {}                        ← 未设资源限制
    }]
  }
}
```

**三条铁证**：

| 证据 | 说明 |
|---|---|
| `labels: {run: trf-doc}` | `kubectl run NAME --image=...` 会自动打 `run=NAME` label |
| `restartPolicy: Never` | kubectl run 的默认值（Deployment 里是 Always） |
| `ownerReferences: []` | 无属主，无任何控制器管理 |

### 4.2 它是干什么的

```
image: docker.io/traefik:v3.6.2   ← 与 traefik ns 的正式 Traefik 同镜像
command: ["traefik"]             ← 无参数启动
ports: 无                        ← 未暴露任何端口
resources: {}                    ← 无资源限制
```

**推断**：这是排查 Traefik 行为时临时起的实验 Pod——用相同的镜像、但不给参数，观察 Traefik 在**无 entrypoint、无 provider 配置**情况下的默认行为（大概率是想看它启动后输出的默认配置或报错）。

**当前状态**：
```bash
kubectl logs -n default trf-doc
→ (无日志)
```
**没有输出、没有端口、无资源限制、且不受任何控制器管理**——说明启动后既没干活也不被需要，属于典型的遗留排查 Pod。

### 4.3 风险点

| 风险 | 说明 |
|---|---|
| `restartPolicy: Never` | 崩溃后不会重启，也不会有 CrashLoop 告警 |
| 无资源限制 | 理论上可耗尽节点资源 |
| 无端口、无 Service | 无网络暴露面 |
| 无人管理 | **无 ownerReference，无法通过 owner 链追踪来源** |

---

## 五、四个 Pod 对照表

| # | Pod 名 | 创建方式 | 属主 | 镜像 | 有 Service? | 可删? |
|---|---|---|---|---|---|---|
| 1 | `hello-00003-deployment-6b69c65796-8jwps` | Knative Serving 控制器 | ReplicaSet → Deployment → KRevision → KConfiguration → KService | `helloworld-go` + queue-proxy | ✅ hello.default.hao.com | ❌ 删了 Knative 会重建 |
| 2 | `report-processor-00001-deployment-675b668fc7-rzr2b` | Knative Serving 控制器 | 同上链 | `event_display` + queue-proxy | ✅ report-processor.default.hao.com | ⚠️ 删了 Trigger 会报错 |
| 3 | `trf-doc` | **人工 kubectl run** | **无** | `traefik:v3.6.2` | ❌ 孤立 | ✅ **可删** |
| 4 | `netshoot-debug-54c86b9985-n8vcl` | 人工 Deployment | Deployment/ReplicaSet | netshoot | ✅ | ✅ 可删 |

---

## 六、删除影响分析

### 6.1 trf-doc（安全）

```bash
kubectl delete pod trf-doc -n default
```
**无任何依赖**，删除无副作用。

### 6.2 report-processor（需谨慎）

删除顺序**必须自上而下**，否则上游会报错：

```bash
# ① 先断 Trigger（否则 Broker 收到事件无处投递）
kubectl delete trigger filter-health-report-trigger -n default
# ② 再删 Service
kubectl delete ksvc report-processor -n default
# ③ 最后清理不再需要的 PingSource 和 Broker
kubectl delete pingsource hourly-report-source -n default
kubectl delete broker central-broker -n default
```

**否则**：`hourly-report-source` 每 2 分钟仍会向 Broker 发事件，Trigger 已无订阅者 → Eventing 控制器持续报 `Broker` 投递失败。

### 6.3 顺带可清理的无主资源

```yaml
# 无 Trigger 订阅的孤立 Broker
broker.eventing.knative.dev/order-broker

# 缩容到 0 的历史 Revision（早已不 Ready）
revision/autoscale-demo-00001  (Ready=False, ContainerMissing)
revision/autoscale-demo-00002  (Ready=False, ContainerMissing)

# 对应的空 Deployment（0/0）
deployment/autoscale-demo-00003-deployment  (0/0)
deployment/hello-00001-deployment            (0/0)
deployment/hello-00002-deployment            (0/0)
deployment/report-processor-00001-deployment (0/0)

# 对应空 Service（ClusterIP 但无后端）
service/hello-00001, hello-00002
service/autoscale-demo-00003, report-processor-00001
```

**注意**：`autoscale-demo-00001/00002` 的 `REASON: ContainerMissing` 说明镜像拉取曾失败过——是历史故障留下的痕迹。

---

## 七、这份分析的可迁移知识点

### 7.1 如何判断 Pod 的真正创建者

```bash
# 方法 1：看 ownerReferences（最直接）
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.ownerReferences}'

# 方法 2：看 managedFields.manager（谁执行的 API 调用）
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.managedFields[*].manager}'

# 方法 3：看 Knative 标签
kubectl get pod -n <ns> --show-labels | grep serving.knative.dev

# 方法 4：反查 —— 有没有人手工创建同名上层资源
kubectl get deploy,ksvc,krevision -n <ns>
```

**关键判据**：
- `ownerReferences: []` → **裸 Pod，人工创建，无控制器管理**
- `ownerReferences[].kind == ReplicaSet` 但上层是 Knative CR → **Knative 生成的**

### 7.2 Knative 的 6 层资源模型（面试常考）

| Knative CR | 对应 K8s 资源 | 作用 |
|---|---|---|
| **Service (KSvc)** | Route + Configuration + K8s Service | 用户唯一需要创建的资源 |
| **Route** | Kourier/ Ingress | 外部访问入口 + 流量切分 |
| **Configuration** | 无（模板） | 容器镜像与配置模板 |
| **Revision** | Deployment + ReplicaSet | 不可变版本，Knative 的核心抽象 |
| （自动）| queue-proxy sidecar | 数据面，注入到用户容器同 Pod |

**设计要点**：**Revision 不可变**——每次改配置生成新 Revision（`hello-00001` → `00002` → `00003`），零停机回滚就是切 Route 指向旧 Revision。这是 Knative 与传统 Deployment 最大的差异，也是「可回滚」的基础。

### 7.3 Knative Eventing 的事件流模型

```
PingSource(Source) ──→ Broker ──→ Trigger ──→ Subscriber(Sink)
                          ↑
                    事件存储（你这里是 Kafka）
```

- **Source**：事件产生者（PingSource 定时、HTTP、Kafka 消费等）
- **Broker**：事件枢纽，**带持久化**（你集群用 Strimzi Kafka）
- **Trigger**：订阅规则，声明「订阅什么事件」
- **EventType**：事件契约，声明 CloudEvent type

**排障要点**：Sink 收不到事件时，依次查 ① Source 是否产生 ② Broker 是否 Ready ③ EventType 是否匹配 ④ Trigger 是否订阅 ⑤ Sink Service 是否 Ready。

---

*分析时间：2026-10-02 17:40。default ns 4 个 Pod 中，hello 与 report-processor 由 Knative Serving 控制器自动生成（report-processor 实际由 Eventing 的 PingSource 每 2 分钟经 Kafka Broker 触发），trf-doc 是 kubectl run 的人工排查 Pod（无 ownerReference、无端口、无日志），netshoot-debug 为人工 Deployment。可安全删除 trf-doc；report-processor 需自上而下删除（Trigger → KService → PingSource → Broker）以免上游持续报错。*
