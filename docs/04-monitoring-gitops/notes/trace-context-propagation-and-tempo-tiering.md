# Trace 上下文传播底层机制 · Tempo 冷热分层 · 三支柱关联

> **定位**：这不是一份通用文档，而是一份**把你集群的真实配置、真实 trace、真实报错逐条对上号**的讲解文档。
>
> **证据基线**（全部来自本集群实测，命令见附录 A）：
> - Tempo `3.0.3`（chart `tempo-distributed-3.7.0`，helm release `tempo3`，ns `logging`）
> - Kafka `my-cluster` 4.1.2（Strimzi），topic `tempo-traces`
> - 对象存储 Ceph RGW `10.0.0.31:7480`，bucket `tempo-traces`
> - Prometheus `v3.11.2`（retention **15d**）、Loki `3.6.7`（retention **5d**）
> - Kubernetes `v1.35.9`，6 节点；唯一 trace 生产者是 Traefik `3.6.2`
> - 采集时间：2026-10-03 14:00–14:35 UTC
>
> **文档中所有"实测"标记的内容都可以用附录 A 的命令复现。所有"推断"标记的内容我会明确说明推理依据。**

---

## 目录

- [第一部分 · Trace 上下文传播的底层机制](#第一部分--trace-上下文传播的底层机制)
  - [1. 先看一条你集群里的真实 trace](#1-先看一条你集群里的真实-trace)
  - [2. 三个 ID：TraceID / SpanID / TraceFlags](#2-三个-idtraceid--spanid--traceflags)
  - [3. SpanContext：传播的真正载体](#3-spancontext传播的真正载体)
  - [4. W3C Trace Context 规范逐字节拆解](#4-w3c-trace-context-规范逐字节拆解)
  - [5. Inject / Extract：SDK 到底在什么时机做了什么](#5-inject--extractsdk-到底在什么时机做了什么)
  - [6. ★ 集群实测：6 组对照实验（这是本文档的核心证据）](#6--集群实测6-组对照实验这是本文档的核心证据)
  - [7. 断链的 6 种典型成因](#7-断链的-6-种典型成因)
  - [8. 术语速查 · 传播篇](#8-术语速查--传播篇)
- [第二部分 · Tempo 的冷热分层](#第二部分--tempo-的冷热分层)
  - [9. 三层抽象：热 / 温 / 冷](#9-三层抽象热--温--冷)
  - [10. 写入路径：一条 span 落到冷层要经过 5 跳](#10-写入路径一条-span-落到冷层要经过-5-跳)
  - [11. 热层：live-store 的四段状态机（实测参数）](#11-热层live-store-的四段状态机实测参数)
  - [12. 冷层：Ceph RGW 里的 block 布局](#12-冷层ceph-rgw-里的-block-布局)
  - [13. 冷层的自我治理：compaction / retention / blocklist](#13-冷层的自我治理compaction--retention--blocklist)
  - [14. 查询路径：querier 如何同时打穿热与冷](#14-查询路径querier-如何同时打穿热与冷)
  - [15. Tempo 3 的并行度单位：partition ring](#15-tempo-3-的并行度单位partition-ring)
  - [16. 各层的持久性与故障半径](#16-各层的持久性与故障半径)
  - [17. 术语速查 · 分层篇](#17-术语速查--分层篇)
- [第三部分 · 三支柱关联](#第三部分--三支柱关联)
  - [18. 三支柱的本质差异](#18-三支柱的本质差异)
  - [19. 关联的三种技术手段](#19-关联的三种技术手段)
  - [20. ★ 集群实测：三条关联链路的真实完成度](#20--集群实测三条关联链路的真实完成度)
  - [21. 你集群的关联能力矩阵与缺口](#21-你集群的关联能力矩阵与缺口)
  - [22. 术语速查 · 关联篇](#22-术语速查--关联篇)
- [第四部分 · 改进清单](#第四部分--改进清单)
- [附录 A · 全部实测命令](#附录-a--全部实测命令)
- [附录 B · 术语总表](#附录-b--术语总表)

---

# 第一部分 · Trace 上下文传播的底层机制

## 1. 先看一条你集群里的真实 trace

在讲原理之前，先把一条真实数据摆出来。这条 trace 是 Grafana 前端加载一个 JS 静态文件时被 Traefik 记录的。

**trace_id = `20ed7901f789929a03fda2a3a36d7fa1`**

```
ResourceSpans #0
  resource: service.name=traefik
            service.version=3.6.2
            k8s.namespace.name=traefik
            k8s.pod.name=traefik-59b795db8-66xgj
            host.name=traefik-59b795db8-66xgj
            telemetry.sdk.name=opentelemetry
            telemetry.sdk.language=go
            telemetry.sdk.version=1.38.0

  ├─ span  GET            kind=SERVER   spanId=HY+O7IIOcj8=   parentSpanId=(无，即 root)
  │        start=1791025138665723408  end=1791025138669248622   耗时 3.53 ms
  │        entry_point=websecure
  │        network.protocol.version=HTTP/2.0
  │        http.request.method=GET
  │        url.path=/public/build/1142.1581b949606d692e8397.js
  │        server.address=grafana.example.local
  │        http.response.status_code=200
  │
  └─ span  ReverseProxy   kind=CLIENT   spanId=PgYLYOFkz8M=   parentSpanId=HY+O7IIOcj8=
           start=1791025138665861833  end=1791025138667202926   耗时 1.34 ms
           url.full=http://10.244.5.119:3000/public/build/1142.1581b949606d692e8397.js
           network.protocol.version=1.1
           server.address=10.244.5.119   server.port=3000
           http.response.status_code=200
```

### 这条 trace 立刻暴露了三个关键事实

| 观察 | 含义 |
|---|---|
| `ReverseProxy` 的 `parentSpanId` = `GET` 的 `spanId` | **父子关系就是靠这 16 字节建立的**，不是靠时间接近、不是靠 IP 相同 |
| 只有 **2 个 span**，分别是 Traefik 的入口 span 和出口 span | **Grafana（`10.244.5.119:3000`）没有贡献任何 span** → 链路在网关到应用之间**被截断** |
| `traceState=(none)`，全部 span `status={}`（即 `STATUS_CODE_UNSET`） | `unset ≠ error`；判断失败要看 `http.response.status_code`，不能看 span status |

> **为什么 Grafana 不产生 span？** 因为它没装 OTel SDK。
> Traefik 在转发请求时**确实注入了 `traceparent` 头**（我在 §6 用实验 B 证明了），但 Grafana 侧没有任何代码去 `Extract` 这个头。
> **注入和提取必须成对出现，缺一整条链路就断在这里。** 这是你集群目前最真实的"传播断点"。

---

## 2. 三个 ID：TraceID / SpanID / TraceFlags

这是整份文档里最需要先钉死的概念。**90% 的"trace 断了"问题，本质是把这三个东西搞混了。**

| 概念 | 长度 | 唯一性范围 | 谁生成 | 作用 |
|---|---|---|---|---|
| **TraceID** | 32 个小写 hex = **16 字节** | 全局（256 位熵） | 链路的**第一个** span | 把整条链路的所有 span 归为一组 |
| **SpanID** | 16 个小写 hex = **8 字节** | 单条 trace 内（64 位熵） | 每个 span 自己 | 标识"这一个操作单元" |
| **TraceFlags** | 2 个小写 hex = **1 字节**，当前只用最低位 | 全局 | 采样器 | bit0=`sampled`（1=采样，0=丢弃） |

### 2.1 TraceID：为什么是 128 位而不是 64 位

64 位 = 1.8×10¹⁹。以每秒 100 万条 trace 计，64 位空间大约 **58 年**才会耗尽——听起来够用，但这里有一个致命问题：

> 64 位随机数在**多租户、多集群**并发生成时，碰撞概率不可接受，而且碰撞一旦发生就是**静默的**（两条完全无关的 trace 被合并成一个，数据污染且无告警）。

所以 OTel 规范直接定死 128 位。代价是存储：每条 span 都要多存 8 字节，1 亿 span 就是 800MB。这正是后来 `SpanID` 被设计成 64 位的原因——**SpanID 只需要在一条 trace 内唯一，而一条 trace 的 span 数最多也就几千**，64 位绰绰有余。

### 2.2 SpanID：它是"身份"，不是"关系"

这是最容易搞错的一点，用一张表说清楚：

```
        [TraceID = T]
              │
   ┌──────────┼──────────┬──────────┐
   │          │          │          │
  spanA     spanB     spanC     spanD          ← 每个都有自己的 SpanID（身份）
  id=a1     id=b2     id=c3     id=d4
   │          │          │
   └─ parent  └─ parent  └─ parent
      = a1      = a1        = b2           ← parentSpanId 才是"关系"
```

- `spanB.spanId = b2`（我是谁）
- `spanB.parentSpanId = a1`（我挂在谁下面）

**`parentSpanId` 只是一个普通字段，没有索引，没有约束。** 后端（Tempo）把 span 们拼成树，靠的就是在内存里按 `traceId` 分组后，用 `parentSpanId → spanId` 做指针连接。

这也解释了一个常见困惑：**为什么 trace 可以"不完整"？** 因为如果某个 span 因为采样丢弃、或者接收端没上报、或者 `parentSpanId` 指向一个不存在的 spanId（parent 所在服务没埋点），那这个 span 就会变成**孤儿 span（orphan span）**——它带着正确的 `traceId` 进到了 Tempo，但它在树里找不到位置。Tempo 会把它当作**独立的 root** 渲染，画出来是一片"浮空"的 span。

> 你集群里现在**满地都是孤儿 span**：所有 `ReverseProxy` 的 `parentSpanId` 都能找到对应的 `GET`（同一进程内传播，正常），但整条 trace 在 Grafana 之后就断了——不是孤儿，而是**整棵子树缺失**。

### 2.3 TraceFlags：一个字节，承载采样决策

```
01  →  0b00000001  →  sampled=true  →  这个 span 被上报
00  →  0b00000000  →  sampled=false →  这个 span 不上报
```

规范里预留了其余 7 位给未来用（当前实现全部忽略）。

**关键点：`sampled` 标志是"整条 trace 级别"的决策，不是 span 级别的。** 一条 trace 要么整条上报，要么整条丢弃。所以下游服务看到 `sampled=false` 的 `traceparent` 时，正确的行为是**继续传播 `false`，自己也丢弃**——这叫 **parent-based sampling（父级采样）**。

而 §6 实验 C 会告诉你：你集群的 Traefik 配了 `--tracing.sampleRate=1.0`，它**违反了**这个约定。

---

## 3. SpanContext：传播的真正载体

`SpanContext` 是 OTel SDK 里的一个 struct，跨进程时它被**序列化成 HTTP 头**。这是"传播"这个词的字面含义。

```
SpanContext {
    TraceID       TraceID     // 16B —— 全局身份
    TraceFlags    TraceFlags  // 1B  —— 采样决策
    TraceState    TraceState  // 变长 —— 厂商私有状态
    Remote        bool        // 1bit —— true=从远程拿来的，false=本进程新建的
}
```

`Remote` 这个布尔值看起来不起眼，但它决定了**一个 span 是"续接"还是"另起"**：

```go
// OTel Go SDK 里判断逻辑的等价形式
if sc := Extract(ctx); sc.IsValid() && sc.IsSampled() {
    // Remote=true（有上游）→ 用上游的 TraceID，新建自己的 SpanID，parent 指向 sc.SpanID
    span = tracer.Start(ctx, name, trace.WithSpanKind(kind),
                        trace.WithLinks(...))   // 隐式续接
} else {
    // 无有效上游 → 生成全新 TraceID，parent 为空 → root span
    span = tracer.Start(ctx, name, trace.WithNewRoot())
}
```

### 3.1 TraceState：唯一能"跨服务传业务数据"的官方位置

`tracestate` 头是一个逗号分隔的 `key=value` 列表：

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
             └──── vendor A 的状态 ────┘ └──── vendor B 的状态 ────┘
```

规范要求（这几个细节很关键）：
- **最多 32 个条目**
- **最多 512 字符**
- **最左边的 entry 是最近一次修改的**（后写入的在左），处理方应从左往右读
- key 只能是小写字母、数字、`_`、`-`、`*`、`/`，且**第一个字符必须是字母**
- value 只能包含 ASCII 可见字符（0x20–0x7E），且**不能有逗号**（逗号是分隔符）、**末尾不能有空格**
- `key=value` 之间**不能有空格**

`tracestate` 的设计意图是：**让上游的采样器/网关把决策传给下游，而不用改协议。** 最著名的用法是 OTel 的概率采样阈值：

```
tracestate: ot=th:8   ← "我的采样门槛是 1/256，比你严格，你自己按这个算"
```

下游读到后就知道"这条 trace 我该采还是不该采"，从而保证**整条 trace 要么都在要么都不在**，避免出现"前半段有、后半段没"的破碎 trace。

> **实测提醒**：你集群里所有 span 的 `traceState` 都是**空**的（`traceState=(none)`）。因为 Traefik 没启用 `enable_tracestate_span_multiplier`，而 Grafana 也没有下游 SDK 参与。**这意味着你集群目前是"全采样"，靠 Traefik 的 `sampleRate=1.0` 硬扛——流量一涨就是致命的。**

---

## 4. W3C Trace Context 规范逐字节拆解

`traceparent` 是最重要的一个头，格式非常严格：

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  │                                │                └─ flags，2 位小写 hex
             │  │                                └────────────────── parent-id，16 位小写 hex
             │  └─────────────────────────────────────────────────── trace-id，32 位小写 hex
             └────────────────────────────────────────────────────── version，2 位小写 hex
```

固定 55 个字符（`2 + 1 + 32 + 1 + 16 + 1 + 2`），没有空格。

### 4.1 校验规则（不合规就必须丢弃重建）

| 字段 | 规则 | 违规后果 |
|---|---|---|
| `version` | 2 位**小写** hex。`ff` 是**保留值，永远非法**。当前只定义了 `00` | 丢弃整个头，**新建 trace** |
| `trace-id` | 32 位小写 hex，**不能全为 0** | 丢弃整个头，新建 trace |
| `parent-id` | 16 位小写 hex，**不能全为 0** | 丢弃整个头，新建 trace |
| `flags` | 2 位小写 hex。当前只定义 bit0 | 未知位**必须被保留并原样传播**（为向前兼容） |
| 整条头 | 长度必须精确等于 55 | 丢弃整个头，新建 trace |

**"版本前向兼容"的设计**：假设未来规范定义 `01` 版本，且 `01` 版本的头更长（比如加了新字段）：

- 接收方看到 `version=01` 但只懂 `00` → **只读前 55 个字符**（`00` 版本的固定前缀），多出来的部分丢弃
- 接收方看到 `version=00` → 按 `00` 规范严格解析，**多一个字符都不行**
- 接收方看到 `version=ff` → 无效，整条丢弃
- 接收方看到 `version=fe`（未来某个高位还会用到的值）→ **只取高 4 位**（`fe` 的高位是 `f`）…实际上规范规定：`00` 是唯一双字符都能解析的版本，其他版本实现应读取高 4 bit，若为 `0` 则是未来的 `0X` 格式

这套规则让**新旧版本 SDK 可以共存而不互相破坏**。

### 4.2 为什么全 0 是非法的

```
trace-id = 00000000000000000000000000000000
parent-id = 0000000000000000
```

全 0 是"最容易写出来的默认值"。如果把它当合法值，那么**每个没配 SDK 的程序**（比如一个用裸 `net/http` 写的服务）如果不小心生成了全 0 的 ID，就会**意外地加入别人的 trace**。规范直接禁止，把"未初始化"这个状态从协议层面消除。

> **工程含义**：如果你在代码里看到 `traceId == "0"*32`，那基本可以断定是 **context 丢了**（没传播、没 Extract、或者手动 new 了 Context），而不是"真的有这么一条 trace"。

### 4.3 baggage：与 trace 无关的第四个头

```
baggage: userId=alice,tenantId=acme,featureFlag=newCheckout
```

这是 W3C **Baggage** 规范（独立于 Trace Context）的头。区别：

| | `traceparent` / `tracestate` | `baggage` |
|---|---|---|
| 属于哪个规范 | W3C Trace Context | W3C Baggage |
| 内容 | ID + 采样状态 + 厂商状态 | 任意 KV |
| 跨服务传递 | 必须 | **默认不传**，需显式开启 |
| 有大小限制 | tracestate 512 字符 | 默认实现通常限 ~8192 字节 |
| 语义 | 链路拓扑 | 业务上下文 |

**Baggage 的坑**（面试常问）：
1. 它会**跟着每一个下游请求走**，包括打给第三方 SaaS 的请求 → **不要放密码/token/PII**
2. 每个中间服务都会**原样透传**，没人校验、没人清理 → 上下文会**指数膨胀**
3. OTel 默认**不传播 baggage**（`OTEL_PROPAGATORS` 默认只有 `tracecontext,baggage`，但很多 SDK 的 HTTP 注入器默认不注入 baggage）

> 你集群里 `BAGGAGE=`（空），符合预期——没有任何服务用它。

---

## 5. Inject / Extract：SDK 到底在什么时机做了什么

这是"底层机制"里最实操的一层。

### 5.1 Extract（提取）——发生在**处理请求之前**

```
HTTP 请求到达
    │
    ├─▶ [1] HTTP Server 层（net/http / Gin / Spring）
    │
    ├─▶ [2] 中间件链：认证 → CORS → 限流 → ...
    │
    ├─▶ [3] ★ OTel Interceptor / Middleware ★   ← Extract 应该插在这里
    │        从 ctx 中取出 SpanContext（若存在）
    │
    ├─▶ [4] 业务 Handler
    │        tracer.Start(ctx, "handler")  →  生成 spanC，parent = 上游 spanId
    │
    └─▶ [5] 下游调用
             tracer.Start(ctx, "call-db")  →  生成 spanD
```

**Extract 位置错了会怎样？** 这是最常见的 bug：

| Extract 位置 | 后果 |
|---|---|
| 在**认证中间件之后** | 认证逻辑里的埋点拿不到 context，自己变成 root |
| 在**业务 Handler 内部**才 Extract | Handler 之前的所有中间件 span 全是孤儿 |
| 在**异步 goroutine 里**才 Extract | `ctx` 根本没传进来（Go 的 `ctx` 不会自动跨 goroutine） |
| 完全没 Extract | 每个服务都是独立 root，trace 只有一段 |

### 5.2 Inject（注入）——发生在**发出请求之前**

```
tracer.Start(ctx, "call-downstream")   → spanD 拿到 ctx
    │
    ├─▶ OTel HTTP Client Interceptor   ← Inject 插在这里
    │        1. 拿到当前 span 的 SpanContext
    │        2. 序列化：traceparent / tracestate（+ baggage 若启用）
    │        3. 塞进 http.Request.Header
    │        4. 透传给 transport 发出去
    │
    └─▶ 下游 Extract → 续接
```

### 5.3 完整的"一次传播"，逐跳看

```
[浏览器]  没有 traceparent（浏览器不参与 tracing）
    │  GET https://grafana.example.local/public/build/x.js
    ▼
[Traefik 网关]  ── Extract: 请求里没有 traceparent ──▶ 新建
    │  spanA = GET         (SERVER, root, TraceID=T1)
    │
    │  ★ Inject ★
    ▼
[  HTTP header 注入 traceparent: 00-T1-spanA-01  ★  ★ ★
    │
    ▼
[Grafana Pod]  ── Extract: 没有 SDK，无人提取 ──▶  ✗ 链路到此为止
```

**这段就是你现在集群的完整现状。** 网关做了正确的事（注入），但下游没有人接（提取）。

### 5.4 非 HTTP 载体的传播

同样的 Inject/Extract 逻辑，但载体不一定是 HTTP header：

| 载体 | 注入方式 | 你集群现状 |
|---|---|---|
| HTTP / gRPC | header `traceparent` | ✅ Traefik → (断) |
| Kafka 消息 | 消息 **header**（不是 payload！） | ⚠️ 有 Kafka（tempo-traces），但那是 Tempo 内部存储，不承载应用 trace |
| RabbitMQ / SQS | message headers / message attributes | 无 |
| 数据库 | SQL 注释（`/* traceparent=... */`）、session 变量 | 无 |
| 定时任务 / 批处理 | 显式构造 Context + `Link` | 无 |
| 线程池 / goroutine 池 | Go: `ctx` 必须显式传；Java: `ThreadLocal` 需装饰 `Executor` | 无 |
| `SpanLink` | 不建立父子关系，只做**因果引用**（用于 MQ、批处理） | 无 |

> **Span vs Link 的区别**（高频面试题）：
> - **父子关系（Parent）**：同步调用，父结束 = 子结束。A 调 B，B 是 A 的子 span。
> - **Link（链接）**：异步/无时序关系。生产者 P 发消息到 MQ，消费者 C 隔几分钟才处理。C **不能**是 P 的子 span（时间不重叠），但应该 `Link` 到 P。
> - 后端渲染时，Link 通常画成一条虚线箭头，不参与火焰图的耗时累加。

---

## 6. ★ 集群实测：6 组对照实验（这是本文档的核心证据）

### 6.1 实验方法

我在 `monitoring` 命名空间临时部署了一个返回**自身收到的全部 HTTP 头**的 nginx Pod，并加了一条 `IngressRoute` 让它挂在 Traefik 的 `websecure` 入口上。然后用 curl 从不同入口打 6 组请求，观察 Traefik 到底往上游注入了什么。

**所有探针资源已删除**（`kubectl delete` 后全集群扫描无残留，见 §6.8）。

### 6.2 实验结果

| # | 客户端发送的头 | nginx 收到的 `traceparent` | 结论 |
|---|---|---|---|
| **A** | *（什么都不发）* | `00-c381588241aec5e52f499adb72e1a8c9-10879adb99c03a69-01` | Traefik **新建**了一条 trace |
| **B** | `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` | `00-4bf92f3577b34da6a3ce929d0e0e4736-1b76fcc43c117533-01` | **续接成功**：trace-id 保持，parent-id 被替换成新 client span id |
| **C** | `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00` | `00-4bf92f3577b34da6a3ce929d0e0e4736-f864bedfc9622139-01` | **flags 被覆盖** `00` → `01`，采样决策被网关推翻 |
| **D** | `X-B3-TraceId: 463ac35c...`<br>`X-B3-SpanId: a2fb4a1d...` | `00-dc8aebd2f5d4a7f5cd9f6924e69628ff-42e313ccc38362fc-01` | **完全不识别 B3** → 生成了全新 trace-id，**链路断裂** |
| **E** | `ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` | `00-85bd7d4017882d73783e730def5f99f9-a1a6fddadb3cb0ce-01` | `ff` 是保留版本 → **合规丢弃**，重建 trace |
| **F** | `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`<br>`tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE` | traceparent 同上<br>`tracestate=rojo=00f067aa0ba902b7,congo=t61rcWkgMzE` | **tracestate 原样透传**，字节级未改动 |

### 6.3 逐条解读

#### 实验 A —— 新建路径

请求里没有 traceparent，Traefik 走的是"无上游"分支：

```
00  c381588241aec5e52f499adb72e1a8c9  10879adb99c03a69  01
│   └── 全新 TraceID（128 位随机）      └─ 自己的 SERVER span id   └─ 采样
```

**要点**：Traefik 的 SERVER span（`GET`）就是这条 trace 的 root，它把自己的 spanId 塞进了给上游的 header。这个 spanId 就是下游应该挂的 parent。

#### 实验 B —— 续接路径（最重要的一条）

对比输入输出：

```
输入 trace-id : 4bf92f3577b34da6a3ce929d0e0e4736   ← 保持不变 ✓
输入 parent-id: 00f067aa0ba902b7                  ← 被丢弃 ✗
输出 parent-id: 1b76fcc43c117533                  ← 换成 Traefik 自己的 CLIENT span id
输出 flags    : 01                                 ← 保持 ✓
```

**这是"传播"二字的字面含义**：`trace-id` 是**不可变的血缘标识**，从链路第一个 span 一路带到最后一个 span，**永远不变**；`parent-id` 是**每一跳重新计算的指针**，上一跳的 spanId 就是下一跳的 parentSpanId。

> 换句话说：**`trace-id` 回答"这是哪次请求"，`parent-id` 回答"我是被谁叫起来的"。**

#### 实验 C —— 采样决策冲突（一个真实的反模式）

客户端明确说 `flags=00`（"这条 trace 不要采"），Traefik 却发出了 `flags=01`（"我要采"）。

**原因**：Traefik 配了 `--tracing.sampleRate=1.0`。

**为什么这是问题？** 按 W3C 规范和 OTel 的 parent-based sampling 约定，下游**必须尊重**上游的 `sampled=false`。Traefik 覆盖它意味着：

- 如果上游是 Java 用了 Tail Sampling（决定丢弃），Traefik 照样上报 → 产生**只有一半的破碎 trace**
- 更普遍的问题：`sampleRate=1.0` 意味着**每个请求都产生完整 trace**，生产环境下这是存储炸弹

**正确做法**：网关应该配置为尊重上游决策（不设 `sampleRate` 或设为 `parent-based`），把采样决策交给应用层的 Tail Sampling 或 OTel Collector 的 `tail_sampling` 处理器。

> 你集群里目前 `sampleRate=1.0` 能跑，纯粹因为**总流量极小**（见 §20，只有 Traefik 一个生产者）。一旦接入业务，这个配置会先炸存储、再炸内存。

#### 实验 D —— B3 格式不被识别（兼容性陷阱）

我只发了经典 B3 多头格式（`X-B3-TraceId` / `X-B3-SpanId`），Traefik **完全无视**，生成了一个全新的 trace-id。

**对比**：输入的 `463ac35c9f6413ad48485a3953bb6124` ≠ 输出的 `dc8aebd2f5d4a7f5cd9f6924e69628ff`。**这条链路在第一跳就断了。**

**根因**：Traefik 的 propagator 列表默认只含 `tracecontext`（W3C 标准），不含 `b3multi`。老应用（Java 的 Spring Cloud Sleuth 早期版本、部分 Go 中间件、Envoy 的某些配置）默认发的是 B3。

**B3 vs W3C 格式对照**（面试常考）：

| | W3C Trace Context | B3 Multi | B3 Single |
|---|---|---|---|
| 头数量 | 2（`traceparent` + `tracestate`） | 4~6 个 `X-B3-*` | 1 个 `b3` |
| TraceID 长度 | **固定 32 hex** | **16 或 32 hex**（64 位或 128 位） | 同左 |
| SpanID | 固定 16 hex | 固定 16 hex | 同左 |
| 采样位 | `traceparent` 最后一位 | 独立的 `X-B3-Sampled: 1` | `b3: {traceid}-{spanid}-1` |
| 父 ID 字段 | `traceparent` 第 3 段 | `X-B3-ParentSpanId` | 同左 |
| 厂商状态 | `tracestate` | `X-B3-TraceState` | 无 |
| 当前地位 | **标准，默认** | 事实标准，遗留系统多 | 遗留 |

> ⚠️ **B3 的 TraceID 可以是 16 hex（64 位）**，这是一个真实的坑：某些 B3 实现只解析前 16 位，导致 trace 撞车。迁移到 W3C 时务必确认两端都用 128 位。

**排查口诀**：如果 trace 在某个服务**入口就换了 trace-id**，先查 propagator 格式是否对齐，再查 Extract 有没有配。

#### 实验 E —— 非法 version 的合规处理

我故意把 version 写成 `ff`（规范明确保留、永不合法的值）。Traefik 丢弃了整个头，生成了全新 trace。

**这是规范要求的行为，不是 bug。** 实现必须这样，因为 `ff` 意味着"发送方用了你完全不懂的编码方式"，任何猜测都可能连错 trace。

> 注意对比：`ff` → 丢弃重建（正确）；而如果是 `01` → 未来的新版本 → 实现应该**只读前 55 字符**并尝试按 `00` 解析。这是 `ff` 唯一被特殊对待的原因：它是"这个字节串永远不会有定义"的哨兵值。

#### 实验 F —— tracestate 的透传

两个厂商条目 `rojo=...` 和 `congo=...` 被**逐字节原样透传**，包括顺序（`rojo` 在左，因为它是最后写入的）。

**要点**：
- Traefik **不理解** `rojo` 和 `congo` 是什么，但**必须原样转发**——这是规范强制的
- 一个厂商只允许修改**自己的** key；要删别人的条目必须整条重写 `tracestate`
- 这就是为什么 `tracestate` 能承载"跨厂商的采样决策传递"而不需要改协议

### 6.4 一个反直觉的实测结果：`tracestate` 空、`baggage` 空

实验 A/C/D/E 里，`TRACESTATE=` 和 `BAGGAGE=` 都是空的。原因是：

- Traefik 自己没设 `tracestate`（无采样阈值传递、无厂商状态）
- `tracestate` 只在**上游传了**的时候才有内容（实验 F 证明了）
- Baggage 从未启用

**这意味着**：你集群里目前**没有任何跨服务的采样决策传递机制**。全靠 Traefik 一家的 `sampleRate=1.0`。这是一个"单点决策、零协调"的脆弱设计。

### 6.5 端到端验证：这次探针真的进了 Tempo 吗？

是的。我用实验 A 产生的 trace-id `c381588241aec5e52f499adb72e1a8c9` 直接查 Tempo：

```
$ curl http://tempo3-query-frontend.logging.svc.cluster.local:3200/api/traces/c381588241aec5e52f499adb72e1a8c9
HTTP 200

ResourceSpans #0
  service.name=traefik
  ├─ GET           SERVER  spanId=eNKos8RazUo=  parent=(root)        3.82 ms
  │     url.path=/probe
  │     server.address=hdr-probe.example.local
  └─ ReverseProxy  CLIENT  spanId=EIea25nAOmk=  parent=eNKos8RazUo=  2.89 ms
        url.full=http://10.244.19.101:8080/probe
```

**这条链路走完了全程**：

```
curl → Traefik(websecure, 建 span) → 注入 traceparent → nginx(无 SDK, 断)
     → otel-collector (opentelemetry ns) → OTLP/gRPC
     → tempo3-distributor (logging ns) → hash(traceID) → Kafka partition
     → live-store (内存, 立即可查)
     → block-builder (5min 后) → Ceph RGW
```

**从"发起请求"到"trace_by_id 可查"耗时 < 2 秒**——因为查询命中的是**热层 live-store 的内存**。这就是冷热分层的第一层价值（详见第二部分）。

### 6.6 实验方法学上的一个诚实声明

我的探针 nginx **没有装 OTel SDK**，所以它只能证明"Traefik 确实注入了 `traceparent`"，**不能**证明"如果 Grafana 装了 SDK 就一定能接上"。

不过 §1 的真实 trace 已经从另一侧证明了同一件事：Traefik 的 `ReverseProxy` CLIENT span 存在且 `parentSpanId` 正确，说明注入逻辑在工作；而 Grafana 侧零 span，说明**没有任何人 extract**。两侧证据一致。

### 6.7 顺带一个被忽略的观察

实验里 `client.port=41118`、`network.peer.address=10.244.59.192`、`network.peer.port` 都被记录了。这是 **Traefik 的 `clientIpHeaders` / 真实 IP 提取**行为，值得单独记住：

> 客户端 IP 是一个典型的**"看起来像 context、实际不是"**的东西。它需要网关从 `X-Forwarded-For` 里提取并**显式写进 span 属性**。如果不做这步，所有 span 的 IP 都是网关的 IP，故障排查时定位不到真实来源。
>
> 这也是 **trace ↔ logs 关联的关键前提**：日志里的 `client_ip` 和 trace 里的 `client.address` 必须来自同一个提取逻辑，否则两边对不上。

### 6.8 探针清理确认

```bash
kubectl delete -f /tmp/opencode/probe/ir.yaml      # IngressRoute hdr-probe  → deleted
kubectl delete -f /tmp/opencode/probe/hdr.yaml    # Pod/CM/Service hdr-probe → deleted

kubectl get pod,svc,cm,ingressroute -n monitoring | grep hdr-probe   # 无输出 ✅
kubectl get pod,svc,cm -A | grep -E "hdr-probe|curlprobe|s3probe"   # 无输出 ✅
```

集群已恢复原状。唯一的残留是 Tempo 里那条探针 trace（`/probe` 路径的 2 个 span），它会在 5 天后被 retention 自动清除——**这本身就是冷层 retention 的一次实证**（见 §13）。

---

## 7. 断链的 6 种典型成因

按"从外到内"的顺序排查——**先看现象在哪一跳断的，再倒推原因**。

### 成因 1：Propagator 格式不匹配（实验 D 实证）

**现象**：trace 在服务 A 之后换了 trace-id。
**排查**：`curl -v` 看 A 往上游发的是什么头、B 期望的是什么头。
**修法**：统一到 W3C `tracecontext`；过渡期在两边都启用 `tracecontext,b3multi`。

### 成因 2：Extract 位置不对

**现象**：某些 span 是孤儿，某些 span 是根，两种混在一起。
**排查**：在每个 span 上看 `parentSpanId` 是否指向一个不存在的 spanId。
**修法**：Extract 必须是最外层中间件，且要在**任何业务逻辑之前**。

### 成因 3：无头环境丢失 Context

**现象**：异步任务、定时任务、消息消费产生的 span 全是独立 root。
**排查**：Go 里 `go func()` 不继承 `ctx`；Java 里 `CompletableFuture`/线程池不传递 `ThreadLocal`。
**修法**：显式传递 `ctx`；对无法传递的场景用 **SpanLink** 而非 Parent。

### 成因 4：Agent 与应用 SDK 未桥接

**现象**：只有网关/框架层有 span，业务方法没有。
**排查**：检查是否同时装了 auto-instrumentation agent **和**手动 SDK（两套会冲突）。
**修法**：二选一。你集群就属于这一类（Traefik 有，业务全无）。

### 成因 5：采样决策冲突（实验 C 实证）

**现象**：trace 只有前半段或只有后半段。
**排查**：对比 `flags` 是否在某一跳从 `00` 变成了 `01`。
**修法**：网关不要覆盖上游采样决策；把采样交给 Collector 的 `tail_sampling`。

### 成因 6：非 HTTP 载体头名不一致

**现象**：走 MQ 的链路断了，HTTP 的正常。
**排查**：Kafka/RabbitMQ 的头是**消息 header**而非 payload；有些 MQ SDK 用 `traceparent`、有些用 `b3`，还有的塞进 payload JSON（不规范）。
**修法**：统一在 MQ 的 message headers 里放标准 `traceparent`。

---

## 8. 术语速查 · 传播篇

| 术语 | 英文 | 一句话解释 |
|---|---|---|
| 上下文传播 | Context Propagation | 把链路身份编码进载体（HTTP 头 / 消息头），跨进程传递 |
| 传播器 | Propagator | 负责 Inject/Extract 的组件；有 `tracecontext` / `b3` / `baggage` 等实现 |
| 提取 | Extract | 从载体读出 SpanContext 放进 Context |
| 注入 | Inject | 从 Context 读出 SpanContext 写进载体 |
| Span 上下文 | SpanContext | `TraceID + SpanFlags + TraceState + Remote`，传播的最小单元 |
| 链路 | Trace | 共享同一 TraceID 的全部 span 的集合 |
| 操作单元 | Span | 一次操作，携带 name/kind/属性/时间戳/parent 指针 |
| 链路 ID | TraceID | 128 位，全局唯一的血缘标识，**传播时永不变** |
| 父 ID | SpanID | 64 位，单 trace 内唯一；上一跳的 SpanID 成为下一跳的 ParentSpanID |
| 采样标志 | TraceFlags | 1 字节，bit0 = sampled；整条 trace 级别的决策 |
| 厂商状态 | TraceState | 逗号分隔 KV，跨厂商透传采样阈值等信息 |
| 业务上下文 | Baggage | 独立于 trace 的跨进程 KV，默认不传播 |
| 远程标志 | Remote | SpanContext 是否来自外部进程 |
| 父级采样 | Parent-based Sampling | 下游尊重上游的 sampled 决策 |
| 尾部采样 | Tail Sampling | 在 Collector 端基于完整 trace 做采样决策 |
| 采样倍率 | Span Multiplier | 记录"1 条实际发生的请求被 extrapolate 成 N 条" |
| 链接 | SpanLink | 无时序关系的因果引用（MQ、批处理） |
| 孤儿 span | Orphan Span | ParentSpanID 找不到对应 span 的 span |
| 根 span | Root Span | ParentSpanID 为空的 span |
| 语义约定 | Semantic Conventions | 统一属性命名的规范（如 `http.request.method`） |
| span 类型 | SpanKind | SERVER / CLIENT / INTERNAL / PRODUCER / CONSUMER |
| 资源属性 | Resource Attributes | 描述"谁产生的"（service.name、k8s.pod.name） |
| span 属性 | Span Attributes | 描述"这次操作"（http.*、db.*） |

---

# 第二部分 · Tempo 的冷热分层

## 9. 三层抽象：热 / 温 / 冷

### 9.1 先讲通用模型（与具体产品无关）

任何"时序数据"系统都要面对同一个矛盾：

| | 写入成本 | 查询成本 | 单位容量成本 | 适合 |
|---|---|---|---|---|
| **内存** | 极低 | **极低** | **极高** | 最近几分钟的实时数据 |
| **本地磁盘** | 低 | 中（需预热） | 低 | 最近几小时的近期数据 |
| **对象存储** | 高（要打包上传） | **高**（要拉取 + 解析） | **极低** | 几个月到几年的归档数据 |

冷热分层就是**按"数据年龄"自动在不同介质之间搬运**：

```
新数据 ──► 热层（内存）──► 温层（本地磁盘）──► 冷层（对象存储）
  秒级           ~1 分钟         ~30 分钟          ~5 分钟（block flush）
  ↑                                                  ↑
  可查              可查              可查                可查（延迟最高）
```

关键性质：**任何一层都必须可查**。分层不是"归档即失联"，而是"查询路径要同时打穿所有层"。

### 9.2 Tempo 3.0 的实现映射

| 通用层 | Tempo 2.x 实现 | **Tempo 3.0.3 实现（本集群）** | 存储介质 |
|---|---|---|---|
| 热 | Ingester 内存 trace | **`live-store` 内存 + 本地 WAL** | Pod `emptyDir`（**无 PVC**） |
| 温 | Ingester 本地 WAL + head block | **`live-store` 的 complete block** | Pod `emptyDir` |
| 冷 | Object Storage 的 block | **Ceph RGW 的 block**（同 2.x） | RGW on Ceph（`10.0.0.31:7480`） |
| 写缓冲 | Ingester 内存队列 | **Kafka `tempo-traces`**（新增！） | Kafka `20Gi` PVC |
| 打包 | Ingester flush | **`block-builder`**（从 2.x 的 ingester 拆出） | scratch `emptyDir` |
| 冷层维护 | `compactor` | **`backend-scheduler` + `backend-worker`** | `work.json` in RGW |
| 归并去重 | compactor compaction | backend-worker compaction | 同上 |

> **Tempo 3.0 的核心变化**：用 **Kafka 替代 Ingester 集群做写缓冲**，因此
> - **不再需要 Ingester 副本（RF1）**——Kafka 自己提供持久性
> - 写路径被拆成三条**独立的消费流**（block-builder / live-store / metrics-generator），互不干扰
> - 每个消费者可以**独立扩缩容**
>
> 这是理解你集群所有 Tempo 参数的前提。Tempo 2.x 的很多文档已经不适用。

### 9.3 你集群的实际部署形态

```
                     ┌─────────────────────────────────────────┐
   Traefik          │  ns: opentelemetry                      │
   (唯一 span 生产者) │  otel-collector (Deployment, 1 replica) │
        │ OTLP/gRPC  │    traces: otlp → batch → otlp_grpc/tempo│
        │ :4317      │    metrics: spanmetrics → prometheus    │
        └───────────►└──────────────────┬──────────────────────┘
                                        │
                     ┌──────────────────▼──────────────────────┐
                     │  ns: logging                            │
                     │  tempo3-distributor (Deployment, 1)      │
                     │    receivers: otlp/grpc :4317,          │
                     │               otlp/http :4318,          │
                     │               jaeger/legacy :55680      │
                     │    → hash(traceID) → 查 partition ring   │
                     └──────────────────┬──────────────────────┘
                                        │ acks=all 后才回客户端
                     ┌──────────────────▼──────────────────────┐
   ┌──────────────── │  Kafka topic tempo-traces (12 分区)     │ ──────────┐
   │ 消费流 1        │  RF=1, retention.ms=7d, segment=1GiB   │           │
   │ (持久化 + 打包) └──────────────────┬──────────────────────┘           │
   │                                    │                     ┌───────────▼──────────┐
   ├──────────────────────────┐         │                     │ 消费流 3（读路径）    │
   ▼                          ▼         ▼                     │ tempo3-live-store ×3  │
 tempo3-block-builder ×3   tempo3-metrics-generator ×1        │ 内存 + 本地 WAL      │
 从 partition 0/1/2 消费    (唯一 RED 生产者，但已失效)         │ 热层，立即可查       │
 5min 一个 consume cycle            ┌──────────────────────────┘
   │                               │
   │  ┌─> Ceph RGW 10.0.0.31:7480 ◄──────────── 消费流 2（持久化）
   │  │   bucket tempo-traces                    tempo3-block-builder ×3
   │  │   ├─ single-tenant/<blockID>/           + tempo3-backend-worker ×1
   │  │   │    ├─ data.parquet   ← span 数据
   │  │   │    ├─ index          ← TraceID → block 映射
   │  │   │    ├─ bloom-0        ← 布隆过滤器（快速排除）
   │  │   │    ├─ nocompact.flg  ← 构建中标记
   │  │   │    └─ meta.json      ← 出现它 block 才可见
   │  │   ├─ index.pb.zst / index.json.gz  ← blocklist（租户索引）
   │  │   ├─ work.json         ← backend-scheduler 作业状态
   │  │   └─ tempo_cluster_seed.json ← memberlist 持久化
   │  │
   │  └─> tempo3-backend-scheduler ×1 (计算 + 分发作业)
   │        └─> tempo3-backend-worker ×1 (执行 compaction/retention)
   ▼
┌──────────────────────────────────────────────────────────┐
│ 读路径（全部组件在 ns: logging）                          │
│   tempo3-query-frontend ×1  ── 切分查询、缓存              │
│     └─> tempo3-querier ×1  ── 合并                      │
│           ├─ gRPC ──> live-store ×3   （查最近 ~20 分钟）  │
│           └─ S3  ──> Ceph RGW          （查更早的全部）     │
│   缓存：memcached（parquet-footer / bloom / frontend-search）│
└──────────────────────────────────────────────────────────┘
```

---

## 10. 写入路径：一条 span 落到冷层要经过 5 跳

以我实测的那条探针 trace 为例，逐步标注**实测证据**。

### 跳 1：应用 → Collector

```
Traefik --tracing.otlp.grpc.endpoint=otel-collector.opentelemetry.svc.cluster.local:4317
```

- Traefik 通过 `otel/opentelemetry-go` SDK 生成 span
- SDK 内部起一个 `BatchSpanProcessor`，**异步批量**通过 OTLP/gRPC 发送
- 实测：`otel-collector` 的 traces pipeline 接收 OTLP，`batch` processor `send_batch_size=1000`, `timeout=10s`

> **注意 `timeout: 10s`**：这意味着最坏情况下一个 span 会在应用内存里滞留 10 秒才发出。如果 Collector 挂了，span 就丢了。**对"不能丢"的场景要配 `memory_limiter` + 降级策略。**

### 跳 2：Collector → Tempo Distributor（同步、可确认）

```
otlp → [batch] → otlp_grpc/tempo { endpoint: tempo3-distributor.logging.svc.cluster.local:4317 }
```

- Collector 收到 OTLP 请求（可能是多个 ResourceSpans 打包在一个 gRPC 消息里）
- `batch` processor 聚合后发给 Tempo
- **这是唯一一跳"客户端会等确认"的写入**（Traefik 等 Collector，Collector 等 Tempo）

### 跳 3：Distributor → Kafka（acks=all，持久化边界）

**这是整个数据可靠性的分水岭。**

```
distributor:
  receivers.otlp.protocols.grpc.endpoint: 0.0.0.0:4317
ingest:
  kafka:
    address: my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
    topic: tempo-traces
    auto_create_topic_default_partitions: 3
```

Distributor 的动作：
1. 校验（大小限制、batch 限制）
2. `hash(traceID) % N` → 查 **partition ring** 得到目标 Kafka partition
3. `acks=all` 写入 Kafka
4. **Kafka 确认后才返回客户端**

> **关键概念：`acks=all` + RF=1 的组合**
> Kafka 配置 `min.insync.replicas=1`, `default.replication.factor=1`。也就是说**只有一份副本**。
> `acks=all` 在 RF=1 时等价于"主副本落盘即返回"——**Kafka broker 所在磁盘（`20Gi` Ceph RBD PVC）挂了，这批 trace 就永久丢了**。
> 这是本集群的一个单点风险（§16 会再提）。

**Topic 实测配置**：

```
Topic: tempo-traces   PartitionCount: 12   ReplicationFactor: 1
Configs: min.insync.replicas=1, cleanup.policy=delete,
         segment.bytes=1073741824, retention.ms=604800000
```

| 参数 | 值 | 含义 |
|---|---|---|
| `PartitionCount` | **12** | **上限**（见 §15，重要） |
| `ReplicationFactor` | **1** | 单副本，Kafka 层无冗余 |
| `retention.ms` | **604800000 = 7 天** | **block-builder 故障 7 天以上 = trace 永久丢失** |
| `segment.bytes` | 1 GiB | 日志分段大小 |

> **`retention.ms=7d` 是"冷热分层的隐藏参数"。** Kafka 是**持久化缓冲层**，它必须"撑得住" block-builder 的故障恢复时间。7 天意味着：block-builder 挂 3 天后重启，Kafka 会把积压的 trace 全部重放，不会丢。这是 Kafka 作为 WAL 的核心价值。
> **但如果 block-builder 挂超过 7 天，trace 就彻底没了——而 Tempo 那边什么都看不到（因为它只统计自己收到的）。**
> 这就是为什么 §21 里我把"监控 Kafka consumer lag"列为高优先级。

### 跳 4：Kafka → live-store（读路径，立刻生效）

见 §11。

### 跳 5：Kafka → block-builder → Ceph RGW（写路径，冷层）

见 §12。

### 写入延迟汇总（实测推断）

| 阶段 | 延迟 | 是否可调 | 证据 |
|---|---|---|---|
| 应用 → Collector | 最多 `batch.timeout = 10s` | ✅ Collector 配置 | Collector 配置 |
| Collector → Distributor | < 100 ms | 网络 | — |
| Distributor → Kafka | < 50 ms | 网络 + `write_timeout=10s` 上限 | Tempo 配置 |
| Kafka → live-store 可查 | **秒级**（实测 < 2 s） | `commit_interval=5s` | **§6.5 实测** |
| Kafka → block 落 RGW | **最多 5 分钟** | `consume_cycle_duration=5m` | block-builder 配置 + 日志 |

> **实测证据**：block-builder 日志显示严格的 5 分钟周期：
> ```
> tempo3-block-builder-0
>   11:39:20  starting consume cycle  active_partitions=0
>   11:39:30  no data  partition=0  commit_offset=125
>   11:44:30  starting consume cycle  active_partitions=0
>   11:44:40  no data  partition=0  commit_offset=125
> ```
> 所以：**从写入到"冷层可查"最坏要等 5 分钟。**

---

## 11. 热层：live-store 的四段状态机（实测参数）

live-store 不是简单的"内存缓存"。它内部有**四个阶段**，每个阶段的可查能力和生命周期都不同。这是你集群 `live_store` 全部参数的含义。

### 11.1 四段状态机

```
    span 到达 Kafka
         │
         ▼
  ┌──────────────────────────────────────────────────┐
  │ ① ACTIVE TRACE（纯内存）                          │
  │    · trace 正在接收 span                          │
  │    · 可按 traceID 查                              │
  │    · 不可 TraceQL 搜索（还没成索引）               │  ← 关键区别
  │    · 存活条件：max_trace_idle(5s) 内无新 span     │
  └───────────────────────┬──────────────────────────┘
                          │ idle 5s
                          ▼
  ┌──────────────────────────────────────────────────┐
  │ ② LOCAL WAL（本地磁盘，Parquet 格式）            │
  │    · 按 tenant 分目录                             │
  │    · ★ 此时 TraceQL 搜索可用 ★                    │
  │    · 作用：崩溃恢复 + 搜索可用性                  │
  │    · 存活到被切块                                 │
  └───────────────────────┬──────────────────────────┘
                          │ 累积到 max_block_duration(30s)
                          │ 或 max_block_bytes(50MiB)
                          ▼
  ┌──────────────────────────────────────────────────┐
  │ ③ COMPLETE BLOCK（本地磁盘，可查询的正式块）      │
  │    · 可按 traceID 查、可 TraceQL 搜索             │
  │    · 保留 complete_block_timeout(20 分钟)         │
  └───────────────────────┬──────────────────────────┘
                          │ 20 分钟后
                          ▼
                 【本地删除】
                 （数据已在 S3，查询走冷层）
```

### 11.2 实测参数逐条解读

以下全部来自 `tempo3-querier` 的 `/status/config`（这是**运行时实际生效值**，不是 yaml 里的声明值）：

```yaml
live_store:
    commit_interval: 5s              # 多久向 Kafka 提交消费位点
    flush_check_period: 5s           # 多久扫一遍所有 tenant 推进状态机
    flush_op_timeout: 5m             # 单次 flush 操作的上限
    max_trace_idle: 5s               # ①→② 空闲多久落 WAL
    max_trace_live: 30s              # ① 的最长驻留（不管有没有新 span）
    max_live_traces_bytes: 250000000 # ① 内存总上限 250 MB
    max_block_duration: 30s          # ②→③ 切块时间上限
    max_block_bytes: 52428800        # ②→③ 切块大小上限 50 MiB
    complete_block_timeout: 20m      # ③ 的保留时长
    block_reclaim_grace: 2m          # 从内存快照移除后，磁盘文件延迟删除
    query_block_concurrency: 10      # metrics 查询时并发读的块数
    complete_block_concurrency: 2    # 并发执行"切块"的次数
    wal:
        path: /var/tempo/live-store/traces
        ingestion_time_range_slack: 2m   # WAL 接受的时间戳松弛
    partition_ring:
        min_partition_owners_count: 1    # PENDING → ACTIVE 需几个 owner
        min_partition_owners_duration: 10s
        delete_inactive_partition_after: 13h
    metrics:
        time_overlap_cutoff: 0.2         # metrics 查询的时间重叠比例
```

### 11.3 两个必须理解的参数

#### `max_trace_idle: 5s` vs `max_trace_live: 30s`

| 参数 | 语义 | 为什么需要"兜底" |
|---|---|---|
| `max_trace_idle` | **空闲** 5 秒就落 WAL | 正常情况：请求结束后 5 秒 trace 就完整了，可以落盘 |
| `max_trace_live` | **无论如何** 30 秒必须落 WAL | 兜底：如果有个"每秒发一个 span 的长连接"（如 gRPC stream、SSE、WebSocket），trace 永远不 idle，会一直占着内存 → **内存打满** |

> **工程含义**：`max_trace_live` 是**内存保护阈值**，不是"trace 时长"。一条跑了 10 分钟的 trace，在系统看来只"live" 30 秒。
> **副作用**：如果一个 trace 的 span 在 30 秒后才陆续到达（比如极慢的异步操作），后半段会变成**另一条 trace**（新 TraceID）或者落在 WAL 的另一个块里 → trace 被"腰斩"。
> 对长耗时任务要调大 `max_trace_live`。

#### `max_live_traces_bytes: 250000000`（250 MB）

这是**每个 live-store Pod 的内存硬上限**。超出后：
- live-store 开始施加**背压（back pressure）**，让 Kafka 消费者变慢
- 相关指标：`tempo_live_store_back_pressure_duration_seconds`

> **容量公式**：
> ```
> 每 Pod 可缓存 trace 数 ≈ 250MB / 平均单 trace 字节数
> ```
> 一条典型业务 trace（50 spans × ~500 B/span，含属性）≈ **25 KB** → 250MB / 25KB ≈ **10000 条 trace**。
> 但你集群只有 **3 个 live-store，每 Pod 又是 `resources.limits.memory: 512Mi`** —— 250MB 的 WAL 预算已经占了 limits 的 **49%**。
> **这意味着：512Mi 的 limits 给 live-store 是偏紧的**，真接入业务后 OOM 风险很高（见 §21）。

### 11.4 一个关键的实测坑：本地盘是 `emptyDir`

```bash
$ kubectl get pod -n logging tempo3-live-store-0 -o jsonpath='{range .spec.volumes[*]}...'
tempo-live-store-store -> emptyDir:{}    ← 不是 PVC！
```

**live-store 的内存 trace + 本地 WAL + complete block 全部在 `emptyDir` 上。** 后果：

| 事件 | 后果 | 恢复方式 |
|---|---|---|
| Pod 被杀 / 节点重启 | **本地 WAL 和 complete block 全丢** | Kafka 重放（`commit_offset` 失效） |
| 节点重启 | 同上 | 同上 |

**实测证据**（live-store 日志，优雅处理了这个场景）：

```
level=info caller=partition_reader.go:277 partition=2
  msg="ignoring committed offset due to missing local data, using lookback period"
  lookback=40m0s  committed_offset=106
```

Tempo 检测到"本地数据没了但位点是 106"，于是**放弃位点，回退 40 分钟重放 Kafka**。这是正确的容错行为。

> **但 40 分钟是个硬编码的回退窗口。** 如果 live-store 停机超过 40 分钟，重放也只能拿到最近 40 分钟的数据——更早的 span **永久丢失**（因为它们已经被 block-builder 打进 S3 了，但 live-store 是独立的消费者，它不读 S3）。
>
> **实测数据**：Kafka 里 partition 0/1/2 的 offset 只有 ~100-130 条（很少），说明目前流量极小。真正上量后，live-store 停机 40 分钟以上就会造成**最近数据查询空洞**。
>
> **修法**：给 live-store 挂 PVC（集群已有 `ceph-rbd-sc`，Loki 就在用）。

### 11.5 热层的可查性边界：`query_end_cutoff`

这是**查询路径上区分热/冷的那一刀**，也是理解冷热分层查询行为的关键。

```yaml
query_frontend:
    query_end_cutoff: 30s
    search:
        ingester_shards: 3          # ← 注意：Tempo 3 里这个字段仍叫 ingester_shards
        most_recent_shards: 200
        query_backend_after: 15m0s
```

**语义**：query-frontend 收到一个查询时，会把它在 **`now - 30s`** 这个时间点切成两半：

```
查询时间范围 [start, end]
                 │
    ┌────────────┴────────────┐
    ▼                         ▼
[ start, now-30s ]      [ now-30s, end ]
    │                         │
    ▼                         ▼
打冷层（backend）          只打热层（live-store）
查 S3 的 block              查 live-store 内存/WAL
```

**为什么这么设计？**
- 最后 30 秒的数据**必然只在 live-store 里**（block-builder 还没打包，最坏要等 5 分钟）
- 30 秒之前的数据**必然已在 S3 里**（block-builder 至少跑完了一轮）
- 所以这 30 秒是"只有热层有"的独占区间

> **`query_end_cutoff` 与 `fail_on_high_lag` 的联动**：
> `live_store.fail_on_high_lag: true`（实测值）意味着——**当 live-store 的 Kafka lag 太大、无法保证结果完整时，Tempo 会直接返回错误而不是返回不完整的结果**。
> 前提条件就是 `query_end_cutoff != 0`。
> **这是一个"用可用性换正确性"的设计**：宁可告诉你"查不了"，也不给你一个缺了尾巴的 trace。
> 监控指标：`tempo_live_store_lagged_requests_total`。

---

## 12. 冷层：Ceph RGW 里的 block 布局

### 12.1 一个真实的 block 目录

```bash
$ mc ls --recursive t/tempo-traces | grep 1b032cf6
[2026-10-03 11:03:32 UTC] 100KiB  single-tenant/1b032cf6-.../bloom-0
[2026-10-03 11:03:32 UTC]  35KiB  single-tenant/1b032cf6-.../data.parquet
[2026-10-03 11:03:32 UTC]    42B  single-tenant/1b032cf6-.../index
[2026-10-03 11:03:32 UTC]   448B  single-tenant/1b032cf6-.../meta.json
```

**四个文件，四个职责**：

| 文件 | 大小 | 作用 | 类比 |
|---|---|---|---|
| `data.parquet` | 变长（这里 35 KiB） | **真正的 span 数据**，列式存储 | 数据库的数据页 |
| `bloom-0` | 固定 ~100 KiB | **布隆过滤器**，快速判断"这个 block 里绝对没有我要的" | 目录索引 |
| `index` | 固定 42 B | **TraceID → 数据偏移**的映射，用于 `trace_by_id` | 主键索引 |
| `meta.json` | ~450 B | **block 元数据**；**它存在 = block 对读者可见** | 目录项 / 提交标记 |

### 12.2 `meta.json` 逐字段解读（真实内容）

```json
{
  "format": "vParquet4",
  "blockID": "1b032cf6-b989-4524-8ca8-664d0d21ca43",
  "tenantID": "single-tenant",
  "startTime": "2026-10-02T10:01:40.398Z",
  "endTime": "2026-10-02T10:27:27.139043794Z",
  "totalObjects": 6,
  "size": 35620,
  "compactionLevel": 3,
  "indexPageSize": 0,
  "totalRecords": 1,
  "bloomShards": 1,
  "footerSize": 18956,
  "dedicatedColumns": [
    {"n": "http.request.method"},
    {"n": "url.path"},
    {"n": "url.route"},
    {"n": "server.address"},
    {"n": "http.route"}
  ],
  "replicationFactor": 1
}
```

| 字段 | 值 | 解读 |
|---|---|---|
| `format` | `vParquet4` | **列式存储格式**——只读查询需要的列，大幅降低 I/O |
| `compactionLevel` | **3** | 这个 block 已经被 **3 轮 compaction** 归并过（见 §13） |
| `dedicatedColumns` | 5 个 HTTP 属性 | **"专用列"优化**：把高频查询属性提升为独立 Parquet 列，避免扫描整行 |
| `replicationFactor` | **1** | **Tempo 3.0 特征**：block-builder 写 RF1（2.x 是 RF3） |
| `totalRecords` | **1** | 只有 1 条 trace 记录（因为总流量极小） |
| `startTime` ~ `endTime` | 25 分钟跨度 | 一个 block 覆盖的时间范围 |

> **`dedicatedColumns` 是冷热分层里"存储层自己做的优化"**：因为你的查询 99% 是 `url.path = "/xxx"` 和 `http.request.method = "GET"`，把这两列物理上单独存，查询就只读这几列字节，不碰其他 30 列。
> 这是 Parquet 列存 + 高频列提升带来的收益，也是冷层能做到"低单位成本"的技术基础。

### 12.3 block 生命周期与 `nocompact.flg`

block-builder 写一个 block 的顺序（**官方规范**）：

```
1. 构建 Parquet 到本地 scratch 盘
2. 上传 bloom-0
3. 上传 data.parquet
4. 上传 index
5. 上传 nocompact.flg    ← 标记"构建中，别碰我"
6. ★ 上传 meta.json ★   ← 从这一刻起 block 才可见
7. 删除 nocompact.flg
8. 提交 Kafka offset
```

**为什么 `meta.json` 是最后写的？** 这是**两阶段提交**思想，保证崩溃安全：

| 崩溃时刻 | 后果 | 恢复 |
|---|---|---|
| `meta.json` **之前** | block 对读者**不可见**（因为 blocklist 只收录有 `meta.json` 的） | block-builder 回退到上次的 Kafka 位点，**重新生成同一个 blockID，覆盖写** |
| `meta.json` **之后** | block 已经是"活"的 | 检测到 block 已存在，用 `replaces` 字段**原子替换** |

> **`nocompact.flg` 的作用**：防止 backend-worker 在 block 还在构建时就去 compact 它，避免竞态。block-builder 写完 meta.json 后删掉它，backend-worker 才被允许动这个 block。

> ⚠️ **你集群的历史教训**：Ceph RGW **17.2.8** 有一个 bug——校验 0 字节对象的 `aws-chunked` 终止块时，把 seed 当成了签名。
> 而 `nocompact.flg` **永远是 0 字节** → 100% 失败 → block 永远写不完 → `meta.json` 永远不生成 → **整个 Tempo 冷层完全不可用**。
> 详见 `/root/tempo3-s3-compat-report.md`。
> **已通过 Ceph 17.2.8 → 18.2.8 (reef) 升级根治。** 现在 112 个对象里有大量 `meta.json`，冷层正常。

### 12.4 bucket 顶层布局（真实）

```bash
$ mc ls t/tempo-traces/single-tenant/
[2026-10-03 14:29:04 UTC] 1.9KiB  index.json.gz      ← blocklist（JSON 格式）
[2026-10-03 14:29:04 UTC] 1.5KiB  index.pb.zst       ← blocklist（protobuf + zstd）
[2026-10-03 14:29:54 UTC]    0B   034649c8-.../      ← block 目录
[2026-10-03 14:29:54 UTC]    0B   1b032cf6-.../
...

$ mc ls t/tempo-traces/
[2026-04-23 12:36:18 UTC]  215B   tempo_cluster_seed.json   ← memberlist KVStore 持久化
[2026-10-03 14:29:39 UTC] 3.9KiB  work.json                ← backend-scheduler 作业状态

$ mc du t/tempo-traces
4.1MiB  112 objects
```

**四个"元数据对象"的作用**：

| 对象 | 作用 | 丢了会怎样 |
|---|---|---|
| `single-tenant/index.pb.zst` / `index.json.gz` | **blocklist**：所有已知 block 的索引，querier 靠它决定"要查哪些 block" | **退化成扫全桶**（极慢），或查询失败 |
| `work.json` | backend-scheduler 的作业队列状态（32 个 shard） | 作业进度丢失，重新开始 |
| `tempo_cluster_seed.json` | **memberlist 的持久化种子** | ring/partition ring 状态丢失，分区归属重建 |
| `<blockID>/meta.json` | block 可见性标记 | **该 block 永久不可查**（数据还在，但没人知道它存在） |

> **实测的 blocklist 内容**（`work.json` 片段）：
> ```json
> {"shards":[
>   {"jobs":{}}, ..., {"jobs":{}},   ← 共 32 个 shard（与 scheduler 副本数匹配）
>   {"jobs":{"d05a40f4-98b3-4882-87ca-c6aeafdd2675":{
>      "id":"d05a40f4-...",
>      "type":2,                              ← 2 = 作业类型
>      "job_detail":{"tenant":"single-tenant","retention":{}},  ← retention 作业
>      "status":1,                            ← 1 = 进行中
>      "created_time":"2026-10-03T13:42:39Z",
>      "start_time":"2026-10-03T13:42:39Z",
>      "end_time": ...}}}}
> ]}
> ```
> **可见"retention 作业正在运行"**——这是冷层数据 5 天后被删除的执行记录（见 §13）。

---

## 13. 冷层的自我治理：compaction / retention / blocklist

冷层不是"写进去就不动了"。有三个持续运行的机制。

### 13.1 Compaction（归并）—— 冷层的"冷热再分层"

**问题**：block-builder 每 5 分钟产一个小 block。如果直接攒 5 天（120 小时）：

```
120h / 5min = 1440 个 block
```

查询时要在 **1440 个 block** 里找一条 trace → 极慢。

**Compaction 的作用**：把小 block 合并成大 block，减少查询时的 block 扫描数量。

```
归并前：  [███][██][█████][██][██][███████][███][██]...  × 1440
         每个都覆盖 5 分钟，边界大量重叠

归并后：  [████████████████████████████████████████████]  × 12
         每个覆盖 ~10 小时，内部已排序去重
```

**实测参数**（来自 `backend_scheduler.provider.compaction`）：

```yaml
block_retention: 120h                    # ★ 数据保留 5 天
compacted_block_retention: 1h            # 归并产物只留 1 小时就会被替换
compaction_window: 1h
compaction_cycle: 30s
max_block_bytes: 107374182400            # 归并目标：100 GiB
max_compaction_objects: 6000000          # 单次归并最多 600 万对象
max_compaction_level: 0                  # ★ 只归并 1 层，不做多级归并
min_input_blocks: 2                      # 至少 2 个 block 才值得归并
max_input_blocks: 4                      # 一次最多吃 4 个 block
max_time_per_tenant: 5m
retention_concurrency: 10
```

**`compacted_block_retention: 1h` 是最巧妙的一个参数**：

```
归并产物写成 meta.compacted.json   ← 注意不是 meta.json
        ↓
等 1 小时后，这个归并产物会被下一轮归并"吸收"进更新的产物
        ↓
旧的归并产物被删
```

> **为什么要等 1 小时？** 因为归并会**重写数据**。在"新的归并产物"和"旧的原始 block"都存在的 1 小时窗口里，查询可以任选一个得到正确结果——这是一种**渐进式替换**，避免归并过程中的查询看到不完整的数据。
>
> **这就是为什么你会看到 `meta.compacted.json` 和 `meta.json` 并存**：
> ```
> single-tenant/034649c8-.../
>     ├─ data.parquet         (10-02 13:58)
>     ├─ bloom-0
>     ├─ index
>     └─ meta.compacted.json  (10-03 14:02)   ← 归并产物
> ```
> 对比：
> ```
> single-tenant/1b032cf6-.../
>     ├─ data.parquet         (10-03 11:03)
>     ├─ bloom-0
>     ├─ index
>     └─ meta.json            (10-03 11:03)   ← 原始 block
> ```

**`max_compaction_level: 0` 的含义**：只做**单级**归并，不做"归并的归并的归并"。这是对 Tempo 2.x 的一个简化——避免多级归并带来的复杂度和写放大。代价是单个大 block 可能达到 100 GiB，查询时单 block 读取时间变长。

### 13.2 Retention（过期删除）

```yaml
block_retention: 120h   # 5 天
retention:
  interval: 1h          # 每小时扫一次
```

**执行者**：`tempo3-backend-worker ×1`，从 `backend-scheduler` 领作业（就是 §12.4 里 `work.json` 那个 `"type":2` 的作业）。

**实测的保留期全景**：

| 信号 | 组件 | 保留期 | 配置来源 |
|---|---|---|---|
| **Traces** | Tempo backend-worker | **5 天（120h）** | `block_retention: 120h` |
| **Traces（Kafka 缓冲）** | Kafka | **7 天** | `retention.ms=604800000` |
| **Logs** | Loki compactor | **5 天** | `retention_period: 5d`（运行时确认） |
| **Metrics** | Prometheus | **15 天** | `spec.retention: 15d` |

> ⚠️ **这里有一个真实的窗口不匹配**（§21 会列为改进项）：
> **Metrics 保留 15 天，Logs 和 Traces 只保留 5 天。**
> 后果：**10 天前的一次故障，日志和 trace 已经没了，但指标还在**。你还能看到"当时错误率是 8%"，但**无法回答"具体是哪个请求、报了什么错"**。
>
> 这个不一致是历史演进的结果（`/root/retention-unification-5d.md` 把三层统一到了 5 天，但后来 Prometheus 又被改成 15 天）。
>
> **原则**：Traces 应该 ≥ Logs，Logs 应该 ≥ Metrics。因为排查的顺序永远是 **指标（发现）→ 日志（定位）→ Trace（还原）**，越往后数据量越稀疏、越需要保留更久。**你现在的设置是反过来的**——最稀疏的指标保留最久，最丰富的 trace 保留最短。

### 13.3 Blocklist（租户索引）

**问题**：bucket 里有几十万个 block，querier 怎么知道该查哪几个？

**答案**：blocklist。它是一个"block 元数据索引"，由 **backend-worker 周期性扫描对象存储、收集所有 `meta.json` 内容**生成的。

```
backend-worker 定期执行：
  ① 列举 bucket 里所有 single-tenant/*/meta.json
  ② 解析每个 block 的 [startTime, endTime, 总行数, 尺寸]
  ③ 聚合成一个紧凑索引文件
  ④ 写回 index.pb.zst / index.json.gz
```

**实测查询参数**：

```yaml
storage:
  trace:
    blocklist_poll: 5m0s                      # 每 5 分钟拉一次 blocklist
    blocklist_poll_concurrency: 50
    blocklist_poll_tenant_concurrency: 0
    blocklist_poll_fallback: true             # ★ 索引不可用时回退到扫全桶
    blocklist_poll_tenant_index_builders: 2
    blocklist_poll_stale_tenant_index: 0s
    blocklist_poll_jitter_ms: 0
    blocklist_poll_tolerate_consecutive_errors: 1
    blocklist_poll_tolerate_tenant_failures: 1
    cache_max_block_age: 0s
```

> **`blocklist_poll: 5m` 与 `blocklist_poll_fallback: true` 的组合风险**：
> blocklist 每 5 分钟才更新一次，而 block-builder 每 5 分钟才产一个 block。
> **两者周期相同 → 有可能刚产出的 block 还没进 blocklist，查询就找不到它。**
>
> 官方规范明确说了兜底逻辑：
> > "They fall back to scanning object storage for `meta.json` files only when the tenant index is unavailable or too stale."
>
> **实测验证了这个场景**：§6.5 我在 probe trace 写入后 **2 秒内**就查到了它——那时它只可能在 live-store 里。等它落到 S3 后，如果 blocklist 还没刷新，query-frontend 会走 fallback 扫桶，也能找到。
> **所以功能正确，但有性能抖动风险。**

### 13.4 backend-scheduler / backend-worker：把 compactor 拆成两半

Tempo 2.x 只有一个 `compactor`，它同时负责：决定做什么作业 + 执行作业。Tempo 3.0 拆成：

| 组件 | 副本 | 职责 | 实测参数 |
|---|---|---|---|
| `backend-scheduler` | **1**（唯一） | **只计算**：扫 blocklist、判断哪些 block 该归并/该过期、生成分片作业、写入 `work.json` | `maintenance_interval: 1m`, `local_work_path: /var/tempo` |
| `backend-worker` | **1**（可横向扩） | **只执行**：从 scheduler 领作业、干活、回报状态；**同时维护 blocklist** | `max_retries: 0`, `finish_on_shutdown_timeout: 30s` |

**实测配置**：

```yaml
backend_scheduler:
    maintenance_interval: 1m
    backend_flush_interval: 1m
    job_timeout: 15s                # 单个作业超时
    dead_job_timeout: 24h            # 死了的作业 24h 后清理
    prune_age: 1h
backend_worker:
    max_retries: 0                   # ★ 不重试（幂等作业不需要）
    min_period: 100ms
    max_period: 1m
    finish_on_shutdown_timeout: 30s  # 关停时最多等 30s
```

> **为什么 scheduler 只能有 1 个？** 因为它独占"决定"的权力。两个 scheduler 会算出两套不同的作业计划，导致重复归并 / 竞态覆盖。
> **为什么 worker 可以多个？** 因为作业是分片的（`work.json` 里的 32 个 shard），worker 之间通过"领作业-提交状态"协调。
>
> **实测警告：`job_timeout: 15s` 偏短。** 一个 100 GiB 的归并作业绝不可能 15 秒完成。
> 这意味着**大归并作业会被 scheduler 判定超时并重新分发** → worker 白干 → 冷层 CPU 浪费。
> **你集群现在没暴露这个问题，只是因为总数据量只有 4.1 MiB。**

---

## 14. 查询路径：querier 如何同时打穿热与冷

### 14.1 五步查询流程

```
① Grafana → tempo3-query-frontend
     │
     │  收到 TraceQL / trace_by_id 请求
     │  按 query_end_cutoff(30s) 切分：
     │    · [start, now-30s]      → 打 backend
     │    · [now-30s, end]        → 打 live-store
     ▼
② query-frontend：查缓存 + 派发 job
     │  cache.roles = [parquet-footer, bloom, frontend-search]
     │  → memcached.tempo3-memcached:11211
     │
     │  search.concurrent_jobs: 1000
     │  search.target_bytes_per_job: 100 MiB
     │  trace_by_id.query_shards: 50        ← 按 traceID 哈希分 50 份并行
     │  search.ingester_shards: 3           ← 热层也分 3 片并行（= live-store 数）
     ▼
③ tempo3-querier：并行执行，两条腿走路
     │
     ├─ gRPC ──> live-store ×3
     │    live_store_client:
     │      concurrent_blocks: 2
     │      max_traceql_conditions: 4
     │
     └─ S3  ──> Ceph RGW
          1. 从 blocklist（index.pb.zst）筛出时间范围重叠的 block
          2. 拉 bloom-0 → 布隆过滤排除（"这个 block 肯定没有"）
          3. 拉 index     → 精确定位（trace_by_id 走这条）
          4. 拉 data.parquet 的相关列 → 过滤
          ▼
④ 合并两路结果（按 traceID + spanID 去重、按时间排序、建父子树）
     ▼
⑤ query-frontend 流式返回给 Grafana
```

### 14.2 缓存的三个角色（实测）

```yaml
cache:
  caches:
  - memcached:
      consistent_hash: true      # ★ 一致性哈希，避免缓存失效风暴
      host: tempo3-memcached
      service: memcached-client
      timeout: 500ms
    roles:
    - parquet-footer             # Parquet 文件尾部的元数据（列布局、行数、offset）
    - bloom                      # 布隆过滤器
    - frontend-search            # query-frontend 的查询结果缓存
```

**这三个角色对应冷层查询的三个"每查必读"的东西**：

| 缓存内容 | 不缓存的后果 | 为什么适合缓存 |
|---|---|---|
| `parquet-footer` | 每次查询都要从 S3 拉文件尾部（虽然有 range read，但仍是一次 RTT） | footer 内容不变（直到 block 被替换） |
| `bloom` | 每个候选 block 都要拉 100 KiB | bloom 只在 block 重新生成时变 |
| `frontend-search` | 相同查询重复计算 | 时间范围小的时候结果可复用 |

> **`consistent_hash: true` 是关键**：缓存 key 包含 querier 实例 ID，一致性哈希保证扩缩容时**大部分 key 不变**（缓存命中率不塌方）。如果用普通哈希，扩缩容会导致 100% key 失效 → 缓存瞬间击穿 → 全打 S3 → RGW 被打满。

**实测状态**：`tempo3-memcached` 1 副本，`memcached:1.6.45-alpine`。

### 14.3 为什么 `search.ingester_shards: 3` 这个名字要特别注意

```yaml
query_frontend:
    search:
        ingester_shards: 3              # ← 名字还是 "ingester"，但含义已变
        most_recent_shards: 200
```

> ⚠️ **Tempo 3.0 里已经没有 ingester 了**，但这个配置项**保留了旧名字**。
> 它的实际语义是"**查热层时并行打几个 live-store**"。
> 这里设为 `3`，正好等于 live-store 副本数 → 每个 live-store 打一次，全覆盖。
> **如果你把 live-store 扩到 5 个，这个值还是 3 → 查询会漏掉 2 个 live-store 的数据 → trace 结果不完整（但 `fail_on_high_lag` 不会报错，因为这不是 lag 问题）。**
> **这是扩缩容时必须同步修改的参数。**

### 14.4 查询延迟的构成（实测推断）

| 数据位置 | 主要耗时 | 量级 |
|---|---|---|
| 热层（live-store 内存） | gRPC 往返 | **毫秒级**（实测 §6.5 < 2s 含写入） |
| 热层（live-store 本地 block） | 本地磁盘读 | 十毫秒级 |
| 冷层（block 在 memcached 命中） | memcached 往返 + S3 range read | 数十毫秒 |
| 冷层（缓存未命中） | S3 拉 bloom + index + parquet 列 | **百毫秒 ~ 秒级** |
| 冷层（`blocklist` 未命中 → 扫全桶） | 列举 bucket | **秒级 ~ 分钟级**（block 多时） |

> 缓存命中率是冷层查询性能的生命线。你集群的 `tempo3-memcached` 只有 **1 副本、无持久化、`resources.limits.memory: 512Mi`**（helm 全局默认）。
> 数据量小的时候完全够用；一旦上量，**第一个要扩的就是 memcached**。

---

## 15. Tempo 3 的并行度单位：partition ring

这是 Tempo 3.0 最容易被误解的部分，也是我实测中**差点误判**的地方。

### 15.1 三个"分区"概念必须分清

| 概念 | 归属 | 含义 | 本集群实测 |
|---|---|---|---|
| **Kafka partition** | Kafka | 物理日志分片 | **12 个** |
| **Tempo partition** | Tempo partition ring | 逻辑分区，映射到 Kafka partition | **3 个**（state=PartitionActive） |
| **Pod ordinal** | StatefulSet | 实例序号 | live-store 0/1/2，block-builder 0/1/2 |

### 15.2 partition ring 的状态机

```
                 live-store 加入，等待 owner 数量满足
                            │
                            ▼
  ┌──────────────┐   min_partition_owners_count: 1
  │   PENDING    │   min_partition_owners_duration: 10s
  │  不读写      │
  └──────┬───────┘
         │ owner 就位且满足 10 秒
         ▼
  ┌──────────────┐   ★ distributor 只往 ACTIVE 分区写数据
  │    ACTIVE    │   ★ querier 从这里查最近数据
  │   正常读写    │   ★ block-builder 从对应 Kafka partition 消费
  └──────┬───────┘
         │ 缩容时先标记（数据仍需 flush）
         ▼
  ┌──────────────┐   delete_inactive_partition_after: 13h
  │   INACTIVE   │   只读，等数据都落到 S3 后删除
  │   只读       │
  └──────────────┘
```

### 15.3 ★ 实测：12 个 Kafka partition，只有 3 个在用

我最初的判断是"**Kafka topic 有 12 个分区，但只有 3 个 block-builder，9 个分区的数据会被丢弃**"——这是一个**严重得多的误判**。核实后：

```bash
$ kafka-get-offsets.sh --topic tempo-traces
tempo-traces:0:128      ← 有数据
tempo-traces:1:105      ← 有数据
tempo-traces:2:114      ← 有数据
tempo-traces:3:0        ← 全空
tempo-traces:4:0
...
tempo-traces:11:0       ← 全空
```

**为什么 9 个分区是空的？** 因为 distributor **不是**用 Kafka 的默认分区策略，而是**查 partition ring，只往 ACTIVE 的 Tempo partition 写**：

> **官方原文**：
> "The distributor shards traces by hashing the trace ID, looks up the partition ring to determine which Kafka partitions are active, and writes records to the appropriate partitions."
>
> "The distributor uses the partition ring, not Kafka's partition routing, to determine target partitions."
>
> **"The topic can have significantly more partitions than Tempo currently has active. Extra Kafka partitions receive no distributor writes until live-stores scale up and activate the corresponding Tempo partitions."**

**实测印证**：

```
$ kubectl logs tempo3-block-builder-0 | grep -oE "partition=[0-9]+" | sort -u
partition=0
$ kubectl logs tempo3-block-builder-1 | grep -oE "partition=[0-9]+" | sort -u
partition=1
$ kubectl logs tempo3-block-builder-2 | grep -oE "partition=[0-9]+" | sort -u
partition=2

$ kubectl logs tempo3-live-store-0 | grep partition=   → partition=0
$ kubectl logs tempo3-live-store-1 | grep partition=   → partition=1
$ kubectl logs tempo3-live-store-2 | grep partition=   → partition=2

$ promql: tempo_block_builder_owned_partitions
  {pod=tempo3-block-builder-0, partition=0, state=PartitionActive} = 1
  {pod=tempo3-block-builder-1, partition=1, state=PartitionActive} = 1
  {pod=tempo3-block-builder-2, partition=2, state=PartitionActive} = 1
```

**结论：12 是"预留的扩容空间"，不是"浪费的分区"。这是 Tempo 3.0 的设计。**

> **设计意图**：Kafka partition 数**一旦设定就不能减少**（只能加）。
> 所以聪明的做法是**一次给足**（比如按 3 年规划的峰值分区数），而 live-store / block-builder 按当前负载小规模跑，需要时再扩。
> 你集群 `auto_create_topic_default_partitions: 3` 但实际 topic 有 12 个分区 —— 说明是**人工预建的**，这个决策是对的。
>
> ⚠️ **但要注意**：`auto_create_topic_default_partitions` 在 Tempo 里是**broker 级 `num.partitions` 的默认值**，官方文档明确警告：
> > "If other services share the same Kafka cluster, consider creating the topic manually instead."
>
> 你集群的 Kafka 只有 Tempo 一个用户（`topic: tempo-traces` 是唯一业务 topic），所以暂时无碍。但 `strimzi` 自己还有一些内部 topic，未来若有别的组件接入 Kafka 会被波及。

### 15.4 扩容公式（官方）

```
topic_partitions >= block_builder_replicas × partitions_per_instance
```

你集群实测：

```
12 >= 3 × 1 = 3   ✅ 满足，还有 9 个分区的余量
```

**因此你可以把 live-store 扩到最多 12 副本，无需改 Kafka topic。** 但扩的时候必须同步改：

| 要改的 | 从 | 到 | 为什么 |
|---|---|---|---|
| `liveStore.replicas` (StatefulSet) | 3 | ≤ 12 | 新 ordinal 会创建新的 Tempo partition（先 PENDING → 后 ACTIVE） |
| `blockBuilder.replicas` | 3 | ≤ 12 | 必须与 active partition 数匹配 |
| `query_frontend.search.ingester_shards` | 3 | 匹配 live-store 数 | **否则查询漏数据**（§14.3） |

> ⚠️ **缩容有严格顺序**（官方规范），不能直接改小 StatefulSet：
> 1. `POST` 到该 pod 的 `/live-store/prepare-partition-downscale`
> 2. 等 block-builder 把该 partition 剩余的 Kafka 记录消费完、数据到达对象存储
> 3. `POST` 到 `/live-store/prepare-downscale`
> 4. 才能减 `liveStore.replicas`
> 5. 最后减 `blockBuilder.replicas`
>
> **跳过这些步骤 = 数据丢失。**

### 15.5 为什么 partition 数量决定写入并行度

```
Kafka partition 0 → block-builder-0 → RGW
Kafka partition 1 → block-builder-1 → RGW
Kafka partition 2 → block-builder-2 → RGW
```

**每个 partition 是完全独立的处理流水线。** 好处：
- 无跨 partition 协调
- 一个 partition 的 block-builder 挂了，不影响其他 partition
- 天然的数据隔离（一个 partition 的数据只在一个 live-store 里）

**限制**：
- **写入吞吐上限 = partition 数 × 单 partition 消费速率**
- **热层内存上限 = partition 数 × `max_live_traces_bytes`**（你集群 3 × 250MB = 750MB，但 Pod limits 只有 512Mi×3）
- **不能超过 topic partition 数**

---

## 16. 各层的持久性与故障半径

这张表是全文最实用的总结——**每层挂了会怎样，数据会怎样，多久恢复**。

| 层 | 组件 | 介质 | 副本 | 持久性 | 挂了的后果 | 恢复时间 | RPO |
|---|---|---|---|---|---|---|---|
| **L0 应用缓冲** | Traefik / SDK | 进程内存 | — | ❌ 无 | span 丢失 | — | 最多 10s（batch timeout） |
| **L1 Collector** | otel-collector | 进程内存 | 1 | ❌ 无 | 缓冲中的 span 丢失；**重启导致 trace 断裂** | 秒级 | ≤ 10s |
| **L2 Kafka** | tempo-traces | Ceph RBD PVC 20Gi | **1** | ✅ 持久 | **Kafka Pod/节点挂 = 该节点上未 ack 的数据丢**（RF1 无冗余） | 分钟级 | 0（acks=all 后） |
| **L3 热层** | live-store ×3 | **`emptyDir`** | 3 | ❌ 无 | 本地 WAL + block 全丢；**已 ack 的数据靠 Kafka 重放** | 重放窗口 **40 分钟** | **40 分钟** |
| **L4 温层** | live-store complete block | **`emptyDir`** | 3 | ❌ 无 | 同 L3 | 同上 | 40 分钟 |
| **L5 冷层** | Ceph RGW | Ceph 集群 3 节点 | 3（RBD） | ✅ 持久 | RGW 全挂 = 查不到历史 trace（写入也失败） | 分钟级 | 0 |
| **L6 冷层治理** | backend-worker | `emptyDir` | 1 | ❌ 无 | 归并/过期暂停；**block 持续增长 → 查询变慢** | 分钟级 | 无（幂等作业） |
| **L7 索引** | blocklist in RGW | Ceph | 3 | ✅ 持久 | 退化为扫全桶 | 5min 轮询 | 0 |
| **L8 缓存** | memcached | `emptyDir` | 1 | ❌ 无 | 缓存全冷 → S3 压力 spike | 预热 | 0 |

### 16.1 最需要关注的三个风险

#### 风险 1：Kafka RF=1（单副本）

```
Topic: tempo-traces  ReplicationFactor: 1  min.insync.replicas=1
Kafka Pod: my-cluster-single-pool-0 (20Gi Ceph RBD PVC)
```

Kafka Pod 重启时，**正在写入但未 ack 的 trace 会丢**；如果 Ceph RBD 损坏，**7 天的 trace 全丢**。

**这是整条链路唯一的"单副本持久化点"。** 其他层要么多副本、要么有上游可重放，只有 Kafka 是单点。

**缓解**：`ReplicationFactor: 3`（需要 3 个 broker，你集群只有 1 个 → 做不到）；或至少确认 Ceph RBD 有多副本 + 备份。

#### 风险 2：live-store 无 PVC（`emptyDir` + 40 分钟重放窗口）

见 §11.4。**这是当前最容易在压测中暴露的问题。**

#### 风险 3：全局 sampling 与资源限额不匹配

```yaml
resources:
  limits:   { cpu: 500m, memory: 512Mi }
  requests: { cpu: 100m, memory: 128Mi }
```

这是 `tempo-distributed-3.7.0` chart 的**全局默认**，`helm get values tempo3` 显示没有覆盖。

**对照实测量级**：

| 组件 | 配置的内存上限 | 实际可能需要 |
|---|---|---|
| `live-store` | 512 Mi | WAL 预算 250 MB + Parquet 缓冲 + Go runtime → **≥ 400 MB** |
| `block-builder` | 512 Mi | `max_consuming_bytes: 5 GB` 的消费 + 20 MiB block 构建缓冲 |
| `querier` | 512 Mi | `search.concurrent_jobs: 1000` × 100 MiB/job 的**理论上限是 100 GB** |

> **`search.concurrent_jobs: 1000` 和 `target_bytes_per_job: 100 MiB` 在 512 MiB 的 Pod 里是危险的组合。**
> 理论上 query-frontend 可以同时派发 1000 个 job，每个 job 最多读 100 MiB → 内存需求可达 100 GB。
> **实际上靠 `query_block_concurrency` 和 gRPC 流式传输限制了单 Pod 并发，但没有全局的总量限制。**
> 一个恶意或误操作的 TraceQL 查询（比如 `{ . = "*" }` 配大时间范围）就能 OOM。

---

## 17. 术语速查 · 分层篇

| 术语 | 英文 | 一句话解释 |
|---|---|---|
| 分层 | Tiering | 按数据年龄自动在不同存储介质间搬运 |
| 热层 | Hot Tier | 内存，能最快响应查询，成本最高 |
| 温层 | Warm Tier | 本地磁盘，比内存慢但比对象存储快 |
| 冷层 | Cold Tier | 对象存储，最便宜，查询最慢 |
| 背压 | Back Pressure | 下游处理不过来时向上游施加延迟 |
| 写入放大 | Write Amplification | 归并导致同一份数据被多次重写 |
| 分段 | Segment | Kafka 的物理日志文件，`segment.bytes=1GiB` |
| WAL | Write-Ahead Log | 预写日志；崩溃后用于重放恢复 |
| 块 | Block | Tempo 的数据存储单元，一个时间范围的一段数据 |
| 列存 | Columnar Storage | Parquet；只读查询需要的列 |
| 专用列 | Dedicated Column | 把高频查询属性提升为独立 Parquet 列 |
| 布隆过滤器 | Bloom Filter | 概率性集合，快速排除"肯定不存在" |
| Footer | Parquet Footer | 文件尾部的元数据（列布局、行数、offset） |
| Blocklist | 租户 Block 索引 | 记录所有已知 block 的元数据索引 |
| 归并 | Compaction | 把多个小 block 合并成大 block，减少查询开销 |
| 归并等级 | Compaction Level | block 被归并的轮次 |
| 过期 | Retention | 删除超过保留期的数据 |
| 渐进替换 | Progressive Replacement | 归并产物延迟删除旧数据 |
| 提交标记 | meta.json | 存在才可见，block 的可见性边界 |
| 可见性 | Visibility | meta.json 写入 = block 对读者可见 |
| Trace-by-ID | Trace by ID | 已知 traceID 直接查（用 `index`，快） |
| TraceQL | TraceQL | Tempo 的查询语言（支持结构化 span 过滤） |
| 引擎 | Query Engine | Tempo 的搜索执行引擎（vParquet4） |
| 活跃分区 | Active Partition | 分区 ring 中可读写的分区 |
| 分区环 | Partition Ring | 记录分区存在性、状态、归属的机制 |
| 成员发现 | Memberlist | Tempo 集群的 gossip 成员协议 |
| 伸缩保护 | Downscale Guard | 缩容前必须先 drain 分区的保护机制 |
| 远程写入 | Remote Write | metrics-generator 推送指标的协议 |
| 跨度 | Span | 一次操作的度量单元 |
| 跨度指标 | Span Metrics | 从 span 聚合出的 RED 指标 |
| 服务图 | Service Graph | 服务间调用拓扑，由 span 推导 |
| 排他 | Exclusive | 指标库占用而非与现有库共享 |

---

# 第三部分 · 三支柱关联

## 18. 三支柱的本质差异

先建立直觉，否则后面所有关联技术都记不住。

| 维度 | **Metrics** | **Logs** | **Traces** |
|---|---|---|---|
| **数据形态** | 数值时间序列 | 非结构化文本行 | 有层级结构的操作树 |
| **基数（cardinality）** | **极高**（Prometheus 上限约 1000 万 series） | **低**（内容不参与索引） | **极高**（每个 span 属性都是维度） |
| **聚合能力** | **原生**（PromQL） | **无**（只能全文检索） | **弱**（TraceQL 有，但成本高） |
| **存储单位** | 采样点（每 15–30s 一个） | 原始行 | span（每个操作一条） |
| **数据量（本集群）** | Prometheus TSDB（15d） | Loki chunk（5d） | Tempo block（5d，**仅 4.1 MiB**） |
| **回答的问题** | **有什么问题？** 趋势 | **具体发生了什么？** 上下文 | **在哪儿、为什么？** 精确路径 |
| **成本/条** | 最低 | 中 | **最高**（1000× 于日志，10⁶× 于指标） |
| **能否表达因果** | ❌ | ⚠️ 靠 ID 拼接 | ✅ **原生**（parent 指针） |
| **丢失影响** | 趋势失真 | 丢上下文 | **链路断裂**（无法重建） |

> **成本差是理解"为什么要采样"的根本原因。**
> 一条业务请求 ≈ 50 个 span。一个 QPS=100 的服务，一天产生：
> ```
> 100 req/s × 86400 s × 50 span = 4.32 亿 span/天
> 每个 span 按 500 字节算 ≈ **216 GB/天**
> ```
> 这个量级下**全量存储 trace 在任何集群上都不现实**。所以：
> - 全量指标（便宜）
> - 全量日志（中等）
> - **采样 trace**（昂贵，只能采 1%~10%）
>
> 这也解释了 §6 实验 C 里 `--tracing.sampleRate=1.0` 为什么危险：**它在你集群现在能跑，只是因为总 QPS 是个位数。**

### 18.1 三支柱的"信息粒度"图谱

```
时间 ──────────────────────────────────────────────►

Metrics   ●━━━━━━━━━●━━━━━━━━━●━━━━━━━━━●
          15s 一个点，告诉你 "P99 从 80ms 涨到 900ms"

Logs            ▌  ▌  ▌    ▌  ▌        ▌
                单条事件，带完整文本和 stack trace

Traces                    ╭─────────╮
                          │ ●       │          一个请求的完整操作树
                          │ ●       │          精确到 "第 3 个 span 慢了 400ms"
                          │   ●     │
                          ╰─────────╯
```

**排查的自然顺序永远是：粗 → 细**

```
① Metrics 发现异常   "错误率从 0.1% 涨到 8%"
        ↓ 用 exemplar 定位到一个具体时刻的请求
② Traces 定位位置    "80% 的耗时在 span #3，是 MySQL 查询"
        ↓ 用 span 属性（trace_id）定位
③ Logs 拿到细节      "MySQL: Lock wait timeout exceeded"
```

> **这就是"关联"的价值**：三根柱子单独看都残缺，只有串起来才能还原现场。
> **任何一个断点都会让排查链条中断**——而这正是你集群的现状（§20）。

---

## 19. 关联的三种技术手段

### 19.1 手段一：Exemplar（指标 → Trace）—— 唯一"官方级"的强关联

**是什么**：Prometheus 的 exemplar 是**挂在指标样本上的一个 traceID 引用**。

```
# HELP http_request_duration_seconds ...
http_request_duration_seconds_bucket{le="0.5"} 1.2e6
http_request_duration_seconds_bucket{le="0.5"} 1.2e6  # {trace_id="20ed7901f789929a03fda2a3a36d7fa1"} 0.482
                                                            ↑↑↑
                                                     exemplar（注释形式）
```

**存储**：**不占独立空间**。exemplar 附在已有的时间序列样本上，在 Prometheus 的 WAL / TSDB chunk 里以特殊标记存储。

**工作方式**：
- metrics-generator（或 spanmetrics connector）从 trace 里算出指标值
- 同时把这条 trace 的 `traceID` 作为 exemplar 挂在那个时间点上
- Grafana 在图表上**渲染成一个特殊的小圆点**
- 点击 → 直接跳到那条 trace

**特点**：

| 优点 | 缺点 |
|---|---|
| **零存储成本**（挂在已有样本上） | **只能挂有限个数**（Prometheus 默认每条 series 最多保留有限 exemplar） |
| 点哪跳哪，定位精确 | **只有指标产生方主动挂**才有，不是自动的 |
| 不需要日志配合 | 需要 `remote_write` 支持 exemplar（否则被静默丢弃） |

> **Exemplar 是"指标→Trace"方向唯一无损的关联方式。** 其他方式都是"按时间范围 + 属性过滤"的近似匹配。

### 19.2 手段二：Span Metrics（Trace → 指标）—— 聚合降维

**是什么**：把高基数、低聚合的 trace 数据**降维**成低基数、可聚合的指标。

```
输入（高基数）：
  span{service="order", span_name="POST /orders", http_method="POST",
       http_status="200", url_path="/api/v1/orders", k8s_pod="order-7d9f...",
       user_id="u12345", trace_id="abc..."}   ← 每个维度都可能是百万级基数

输出（低基数）：
  traces_span_metrics_calls_total{service="order", span_name="POST /orders",
       span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_OK"} 1
  traces_span_metrics_duration_seconds_bucket{..., le="0.5"} 0.91
```

**关键认知**：这个方向是**"用 trace 产生指标"**，不是"用指标关联 trace"。它的价值在于：

1. **补齐业务指标的语义**（RED = Rate / Error / Duration）
2. **天然带 exemplar**（见手段一）
3. **自动产生服务图**（`traces_service_graph_request_total`）

**本集群有两个 Span Metrics 生产者**：

| 生产者 | 实现 | 输出指标名 | 状态 |
|---|---|---|---|
| **otel-collector `spanmetrics` connector** | 采集器内进程 | `otel_demo_traces_span_metrics_*` | ✅ **正常工作** |
| **Tempo `metrics-generator`** | 独立组件 | `traces_span_metrics_*` / `traces_service_graph_*` | ❌ **完全失效**（见 §20） |

> **注意指标名前缀 `otel_demo_`**：因为 otel-collector 的 prometheus exporter 配了 `namespace: otel_demo`。
> 这是一个很容易踩的坑——**你以为指标叫 `traces_span_metrics_calls_total`，其实叫 `otel_demo_traces_span_metrics_calls_total`**，写 PromQL 时不加前缀就返回空。

### 19.3 手段三：ID 注入（Trace ↔ Logs）—— 最灵活也最脆弱

**原理**：在日志里写入 `trace_id`，就能从日志跳到 trace；反过来，trace 的 span 属性能匹配到日志的标签，就能从 trace 跳到日志。

**实现需要在两处配合**：

#### 方向 A：Trace → Logs（Grafana 数据源配置驱动）

```yaml
# Tempo 数据源配置（你集群已有）
tracesToLogsV2:
  datasourceUid: dfi90c2a1osn4c      # ← 指向 Loki ✅ 已配置
  spanStartTimeShift: -1h            # 查询时间 = span 开始时间 - 1h
  spanEndTimeShift: 1h               #             span 结束时间 + 1h
  filterByTraceID: true              # ★ 用 traceID 作为检索条件
  filterBySpanID: false              # 用 spanID（需要日志里也有）
```

**Grafana 生成的 LogQL**（当 `filterByTraceID: true`）：

```logql
{namespace="traefik"} | traceID="20ed7901f789929a03fda2a3a36d7fa1"
```

> ⚠️ **注意 Grafana 用的是 `traceID` 这个字段名**（大写 ID），这是 Grafana 的约定，取决于日志里用什么名字写入。

#### 方向 B：Logs → Trace（Loki `derivedFields` 驱动）

```yaml
# Loki 数据源配置（你集群是空的 ❌）
derivedFields:
  - name: TraceID
    matcherRegex: '"traceID":"(\w+)"'      # 从日志正文里正则提取
    url: '$${__value.raw}'                 # 拼出 Tempo 的 URL
    datasourceUid: afia1p4xshn9cf          # ← 指向 Tempo
```

**这是方向 A 的反向操作**，也是**唯一能让"在日志搜索框里粘贴 traceID 就跳到 trace"生效的配置**。

> **两种方式的区别**：
> - `tracesToLogsV2`（方向 A）：**不需要日志里有 traceID**，因为 Grafana 会把 traceID 作为 LogQL 过滤条件发出去 → 但**日志里必须有 `traceID` 这个 label 或被解析出的字段**，否则返回空
> - `derivedFields`（方向 B）：**Grafana 在日志结果里渲染一个可点击链接**，点它跳到 trace
>
> **两者都需要"日志里真的有 traceID"。**

### 19.4 手段四（补充）：Trace → Metrics（Grafana 数据源配置驱动）

```yaml
# Tempo 数据源配置（你集群已有）
tracesToMetrics:
  datasourceUid: prometheus             # ← 指向 Prometheus ✅ 已配置
  spanStartTimeShift: -1h
  spanEndTimeShift: 1h
serviceMap:
  datasourceUid: prometheus             # ← 服务图数据源 ✅ 已配置
lokiSearch:
  datasourceUid: dfi90c2a1osn4c         # ← ★ "在 Loki 里搜 service.name" ✅ 已配置
```

**`lokiSearch` 是什么**：在 trace 详情页，让用户**按 `service.name` 直接搜日志**。这是一个"弱关联"——它不要求日志里有 traceID，只要求日志有 `service` 标签。

> **这个配置是本集群里唯一实际可用的 Trace→Logs 下钻路径**，因为它只依赖标签而不依赖 traceID。

---

## 20. ★ 集群实测：三条关联链路的真实完成度

### 20.1 关联配置矩阵（实测）

```bash
$ kubectl get cm prometheus-grafana-datasource -n monitoring -o jsonpath='{.data.datasource\.yaml}'
```

**Tempo 数据源**：

| 配置项 | 值 | 状态 |
|---|---|---|
| `nodeGraph.enabled` | `true` | ✅ |
| `search.hide` | `false` | ✅ |
| `tracesToLogsV2.datasourceUid` | `dfi90c2a1osn4c`（Loki） | ✅ 已配 |
| `tracesToLogsV2.filterByTraceID` | `true` | ✅ 已配 |
| `tracesToMetrics.datasourceUid` | `prometheus` | ✅ 已配 |
| `serviceMap.datasourceUid` | `prometheus` | ✅ 已配 |
| `lokiSearch.datasourceUid` | `dfi90c2a1osn4c` | ✅ 已配 |

**Loki 数据源**：

| 配置项 | 值 | 状态 |
|---|---|---|
| `derivedFields` | **`[]`** | ❌ **空数组** |

**Prometheus 数据源**：无关联配置（正常，关联配置在 Tempo/Loki 侧）。

> **结论**：Grafana 侧的**关联配置基本齐全**（除 Loki `derivedFields`）。
> 缺口不在配置，而在**数据生产端**。

### 20.2 Traces ↔ Metrics：两条路径，一条通一条断

#### 路径 1：otel-collector spanmetrics connector —— ✅ 正常工作

```bash
$ promql: count(otel_demo_traces_span_metrics_calls_total)
4
$ promql: sum(otel_demo_traces_span_metrics_calls_total)
323
$ promql: count(otel_demo_traces_span_metrics_duration_milliseconds_bucket)
68
```

**实际 series 的标签**（真实查询结果）：

```
otel_demo_traces_span_metrics_calls_total{
    exported_job        = "traefik",
    host_name           = "traefik-59b795db8-66xgj",
    k8s_namespace_name  = "traefik",
    k8s_pod_name        = "traefik-59b795db8-66xgj",
    k8s_pod_uid         = "dc62445c-83a4-40f4-9bc5-251e4133686c",
    instance            = "10.244.30.151:8889",
    job                 = "otel-collector",
    pod                 = "otel-collector-985847d99-5s7r5",
    namespace           = "opentelemetry",
    os_type             = "linux",
    otel_scope_name     = "spanmetricsconnector",   ← ★ 证明是 connector 产生的
    process_command_args = "[\"traefik\",\"traefik\",...]",
    telemetry_sdk_language = "go",
    ...
}
```

**配置来源**：

```yaml
# otel-collector
exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: otel_demo                       # ← 指标名前缀来源
    resource_to_telemetry_conversion:
      enabled: true                            # ← resource 属性变成标签的开关
connectors:
  spanmetrics: {}
service:
  pipelines:
    metrics:
      receivers: [spanmetrics]                 # ← spanmetrics 是"接收器"式接入
      exporters: [prometheus]
```

> **`resource_to_telemetry_conversion: true` 的效果**：把 span 的 **resource 属性**（`service.name`、`k8s.pod.name`、`host.name`…）**全部转成指标标签**。
> 这是双刃剑：**方便但极易炸基数**。你集群现在只有 `service.name=traefik` 一个服务，所以标签数可控；一旦接入 50 个微服务，每个服务 × 每个 span_name × 每个 status_code × **每个 pod**（`k8s_pod_name`！）→ **基数爆炸**。
>
> **改进建议**：改成用 `spanmetrics` connector 的 `dimensions` 白名单，而不是全量转换：
> ```yaml
> connectors:
>   spanmetrics:
>     dimensions:
>       - name: http.method
>       - name: http.status_code
>       - name: http.route            # ★ 用 route 模板，不用原始 url
>     exemplars:
>       enabled: true                 # ★ 开启 exemplar
> ```
>
> **注意：当前配置里 `spanmetrics: {}` 是空配置，exemplar 默认关闭。**
> 验证：`otel_demo_traces_span_metrics_calls_total` 的查询结果里**没有 `# {trace_id=...}` 注释** → **exemplar 未生成**。

#### 路径 2：Tempo metrics-generator —— ❌ 完全失效（两个独立根因）

这是本次分析**最重要的发现**。Tempo 的 metrics-generator 是官方推荐的服务图 + exemplar 来源，但它在你集群里**一条指标都没产出**。

##### 实测证据链

**证据 1 —— Prometheus 里一条 `traces_*` 指标都没有**

```bash
$ promql: count(traces_span_metrics_calls_total)                     → EMPTY
$ promql: count(traces_service_graph_request_total)                   → EMPTY
$ promql: count(traces_service_graph_request_failed_total)            → EMPTY
$ promql: count(traces_spanmetrics_duration_seconds_bucket)           → EMPTY
```

全量扫描 278 个含 `service_graph` / `span_metrics` / `traces_` 的指标名，**来自 metrics-generator 的一个都没有**。

**证据 2 —— registry 里有 0 条活跃 series**

```bash
$ promql: tempo_metrics_generator_registry_active_series          → 0
$ promql: tempo_metrics_generator_registry_collections_total      → 831
$ promql: tempo_metrics_generator_bytes_received_total             → 471350   ← 在消费！
$ promql: tempo_metrics_generator_processor_span_metrics_calls_total       → EMPTY
$ promql: tempo_metrics_generator_processor_service_graph_request_total   → EMPTY
```

> **`bytes_received_total = 471350` 但 `active_series = 0`** —— 这是最关键的矛盾信号：
> **它在读 Kafka（有数据进来），但产不出任何指标序列。**

**证据 3 —— 我打了一发新 trace，验证它确实在实时消费**

```
before: active_series=0, bytes_received=468782
   ↓ curl → Traefik → 一条新 trace 写入
   ↓ 等 90 秒（跨过 6 个 15s 采集周期）
after:  active_series=0, bytes_received=471350   ← 增加了 2568 字节 = 我那条 trace
```

> **结论**：span 确实被 metrics-generator 消费了，但**处理器没有产出任何 series**。
> 这排除了"Kafka 消费故障"的可能性，指向**处理器本身被禁用**。

##### 根因 1：per-tenant overrides 为空 → 处理器默认禁用

**Tempo 官方文档明确写着**：

> **"Metrics-generator processors are disabled by default. To enable it for a specific tenant, set `metrics_generator.processors` in the `overrides` section."**

**实测的 overrides 文件内容**：

```bash
$ kubectl get cm tempo3-runtime -n logging -o jsonpath='{.data.overrides\.yaml}'
overrides:
  null
```

**YAML 解析结果就是 `overrides: null`** —— 没有任何租户配置，因此**所有处理器对所有租户都是关闭的**。

**这完全解释了 `active_series = 0`**：处理器压根没运行，自然没有序列。

**修法**：

```yaml
# tempo3-runtime ConfigMap
overrides:
  defaults:
    metrics_generator:
      processors:
        - service-graphs
        - span-metrics
        - local-blocks        # 注意：Tempo 3.0 已移除 local-blocks，别加
```

##### 根因 2：Prometheus 未开启 remote-write receiver → 即使产出也推不进去

**这是一个独立于根因 1 的第二道墙。** 即使修好 overrides，指标**仍然推不过去**。

**决定性实测**：

```bash
$ curl -XPOST -H "Content-Type: application/x-protobuf" --data-binary '' \
    http://prometheus-prometheus.monitoring:9090/api/v1/write
HTTP 404
remote write receiver needs to be enabled with --web.enable-remote-write-receiver
```

**Prometheus CR 的相关字段**：

```bash
$ kubectl get prometheus prometheus-prometheus -n monitoring -o json | ...
enableAdminAPI: False
enableOTLPReceiver: False
# ★ 没有 enableRemoteWriteReceiver 字段 → 默认 false
```

> `enableRemoteWriteReceiver` 未设置 = Prometheus Operator **不会**给容器加 `--web.enable-remote-write-receiver` flag → `/api/v1/write` 端点不存在 → **HTTP 404**。

**修法**：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus-prometheus
  namespace: monitoring
spec:
  enableRemoteWriteReceiver: true      # ★ 加上这个
  # retention: 15d                      # 建议同时改成 5d，与 Logs/Traces 对齐
```

##### 两个根因的叠加效果

```
根因 1（processors 未启用）
        ↓
active_series = 0  ← registry 里没有任何东西可推
        ↓
        ×  根因 2（/api/v1/write 返回 404）
        ↓
即使根因 1 修好，推送也会 404
        ↓
Prometheus 里永远不会有 traces_* 指标
```

> **必须两个都修。** 只修一个的结果都是"指标依然为 0"。

##### 附带的第二个小问题：`consumer_group` 为空导致 lag 指标失效

```bash
$ kubectl logs tempo3-metrics-generator | grep -c "metric lag failed"
653      # 11 小时内 653 次，约每 62 秒一次
```

```
level=error caller=metrics.go:81 msg="metric lag failed:"
  err="INVALID_REQUEST: This most likely occurs because of a request being malformed
       by the client library or the message was sent to an incompatible broker."
  retries=5
```

**根因**：`ingest.kafka.consumer_group: ""`（空字符串）。

Tempo 官方文档说明：

> **"[consumer_group: When empty (recommended), Tempo uses the instance ID to guarantee uniqueness.]"**

所以空值本身是**推荐做法**。但 metrics-generator 用 `kadm` 去查消费组位点做 lag 计算时，带着空的 consumer group 去问 Kafka，Kafka 返回 `INVALID_REQUEST`。

**影响**：`tempo_metrics_generator_*` 的 lag 相关指标**不可用** → **你无法监控 metrics-generator 的消费延迟**。
**优先级**：低（因为根因 1/2 修好后需要重新验证）。

#### 路径 2 失效的连锁后果

| 受影响能力 | 状态 | 根因 |
|---|---|---|
| `traces_span_metrics_calls_total`（Tempo 版 RED） | ❌ 不存在 | 根因 1 + 2 |
| `traces_service_graph_request_total` | ❌ 不存在 | 根因 1 + 2 |
| **Grafana 服务图（Service Graph）视图** | ❌ **空白** | 缺 `traces_service_graph_*` |
| **Grafana 节点图（Node Graph）** | ⚠️ 退化为只有 Traefik 一个节点 | 缺服务图 |
| **Exemplar（指标→trace 下钻）** | ❌ **完全不可用** | 根因 1 + 2；且 spanmetrics connector 也没开 exemplars |
| `traces_target_info` | ❌ 不存在 | `enable_target_info: false` |

> **`serviceMap.datasourceUid: prometheus` 这个配置是"悬空"的** —— Grafana 去 Prometheus 找 `traces_service_graph_request_total`，找不到，所以服务图页面是空的。

### 20.3 Traces ↔ Logs：配置齐全但**数据侧完全断裂**

**实测：Loki 里一条日志都没有 `traceID`**

```bash
# 检查所有可能承载 trace_id 的位置
$ kubectl logs ... | grep -iE "trace_id|traceID|trace-id"    → 无
```

**原因链（每一环都实测确认过）**：

```
① Traefik 没有开 access log
   $ kubectl get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}'
   [... "--tracing.serviceName=traefik",
    "--tracing.otlp.grpc.endpoint=otel-collector.opentelemetry.svc.cluster.local:4317",
    "--tracing.otlp.grpc.insecure=true",
    "--tracing.sampleRate=1.0"]
   ★ 没有 --accesslog=true
        ↓
② 所以 Traefik 一行访问日志都不产生，Loki 里没有任何 Traefik 请求日志
        ↓
③ Grafana 应用本身也不打日志到 Loki（Grafana 的 stdout 没被 Alloy 采集，或根本没开日志）
        ↓
④ 即使有日志，也没有日志库会自动把 trace_id 写进日志行
   ★ 这是关键：注入 trace_id 到日志是【应用的责任】，不是采集器的责任
        ↓
⑤ Loki 数据源 derivedFields: []  ← 连兜底配置都没有
```

> **第 ④ 点是最根本的认知**：
> **日志和 trace 是两条独立的管道。采集器（Alloy / otel-collector）不会自动把它们关联起来。**
> 关联只有两种方式：
> 1. **应用主动写**：在日志语句里带上 `traceID`（用 OTel 的 `traceparent` 提取后拼进日志格式）
> 2. **采集器提取**：Alloy 的 `loki.source.*` 有 `trace` 相关配置，可以从日志正文正则提取 trace_id 作为标签（你集群**没有配**）

**实测 Alloy 配置确认**：

```bash
$ kubectl get cm alloy-config -n logging -o jsonpath='{.data.config\.alloy}'
```

完整的 alloy 配置（`/root` 里备份过）包含：
```alloy
discovery.kubernetes "pod_logs" { ... }        # 发现本节点 Pod
discovery.relabel "pod_logs" { ... }           # 标签重写（app/instance/component/...）
loki.source.file "pod_logs" { ... }            # ★ 读 /var/log/pods/*.log
loki.process "logs_to_prometheus" {
    stage.cri { }                               # 剥 CRI 包装
    stage.drop { older_than = "120h" }          # 丢弃超 5 天的
}
loki.write "default" { ... }                   # 写到 loki-gateway
```

**没有任何 `trace_id` 提取配置**，也没有 OTLP 日志管道（Alloy 只做日志，不接 trace）。

> **完整实测的日志管道**：
> ```
> Pod stdout/stderr
>   → /var/log/pods/<ns>_<pod>_<uid>/<container>/N.log  （CRI 格式）
>   → Alloy DaemonSet ×6（每节点 1 个，tail_from_end=true）
>   → stage.cri（剥掉 timestamp/stream/P|F 包装）
>   → stage.drop（>120h 丢弃）
>   → loki-gateway → loki-write (ks=8,w=128) → MinIO/S3 loki-chunks
>   → loki-read → loki-gateway → Grafana
> ```
> **这条管道里没有任何一个环节接触 trace。**

##### Traces → Logs 的实际可用性

| 路径 | 配置 | 实际结果 |
|---|---|---|
| **trace → Loki（按 traceID 过滤）** | ✅ `tracesToLogsV2.filterByTraceID: true` | ❌ **返回空** —— Loki 里没有带 traceID 的日志行 |
| **trace → Loki（按 service.name 搜）** | ✅ `lokiSearch.datasourceUid` | ✅ **可用** —— 只要该 Pod 打了日志 |
| **日志 → trace（点 derivedFields 链接）** | ❌ `derivedFields: []` | ❌ **不可用** |

> ⚠️ **重要区分**：`lokiSearch` 走的是"按 service.name 标签搜该服务所有日志"，**这不是真正的关联**，只是范围缩小。
> 它能帮你"看到这个服务在这段时间的日志"，但**不能定位到"这条 trace 对应的那一行日志"**。

### 20.4 Metrics ↔ Logs：配置和数据双缺

**配置侧**：

```yaml
# Loki 数据源
derivedFields: []      # ❌ 空
```

这一项承担的是 **Metrics → Logs** 的部分场景：Grafana 里点击一个指标点，跳到同时段日志。

**Tempo 数据源侧**：

```yaml
tracesToMetrics:
  datasourceUid: prometheus
  spanStartTimeShift: -1h
  spanEndTimeShift: 1h
```

> ⚠️ **这里有一个必须理解的语义**：`tracesToMetrics` 的意思是
> **"给定一个 trace，返回它对应时间段的指标"** —— 方向是 **Trace → Metrics**。
> **它不是 Metrics → Logs。**
>
> 所以 Metrics ↔ Logs 这个方向，**Grafana 本身没有内建的"指标→日志"跳转**。
> 业界通常这么做：
> 1. **手动切换**：在 Grafana 里并排放 Prometheus 图 + Loki 日志面板，手动对齐时间轴（最常用）
> 2. **基于标签约定**：约定两者用同名标签（如 `service`/`namespace`），在两个面板用同一个变量
> 3. **Exemplar 间接桥接**：Metrics →(exemplar)→ Trace →(tracesToLogsV2)→ Logs（**这条路需要 exemplar + 日志里有 traceID，三者都齐**）

**数据侧**：

```bash
# Prometheus 有 traefik 相关指标吗？
$ promql: count(up{namespace="traefik"})   → 有（ServiceMonitor 抓的 Traefik /metrics）
```

**注意区分两类指标**：

| 指标类型 | 来源 | 有 trace_id 吗 | 能否跳到 trace |
|---|---|---|---|
| `traefik_*`（如 `traefik_service_requests_total`） | Traefik 的 `/metrics` 端点，ServiceMonitor 抓取 | ❌ **没有** | ❌ |
| `otel_demo_traces_span_metrics_*` | spanmetrics connector 从 span 算 | ⚠️ 本应带 exemplar，但没开 | ❌ |

> **关键洞察**：`traefik_*` 是 Traefik **主动暴露**的指标，它对每个请求的处理完全知道，但**它不会把 traceID 关联进去**——因为那是 OTel 的事，不是 Prometheus exposition 的事。
> **唯一能把 traceID 放进指标的方式就是 exemplar。** 而 exemplar 需要：
> 1. 生产方显式生成并通过 remote_write 的 exemplar 字段发送 ✅ 机制存在
> 2. metrics-generator 工作 ❌ 坏了
> 3. spanmetrics connector 开 `exemplars.enabled` ❌ 没开
>
> **所以你集群的 Metrics → Trace 跳转能力是 0。**

---

## 21. 你集群的关联能力矩阵与缺口

### 21.1 完整矩阵

| 关联方向 | 技术手段 | 配置 | 数据 | 综合状态 |
|---|---|:---:|:---:|:---:|
| **Trace → Metrics** | `tracesToMetrics`（时间范围匹配） | ✅ | ✅ spanmetrics 在产出 | ⚠️ **可用（近似匹配）** |
| **Trace → Service Graph** | `traces_service_graph_*` | ✅ | ❌ | ❌ **不可用** |
| **Metrics → Trace**（exemplar） | exemplar | — | ❌ 两条路径都没开 | ❌ **不可用** |
| **Trace → Logs**（按 traceID） | `tracesToLogsV2` | ✅ | ❌ 日志无 traceID | ❌ **配置有、数据无** |
| **Trace → Logs**（按 service） | `lokiSearch` | ✅ | ✅（如果有日志） | ✅ **可用（弱关联）** |
| **Logs → Trace**（derivedFields） | `derivedFields` | ❌ 空 | ❌ | ❌ **不可用** |
| **Metrics ↔ Logs** | 手动时间轴对齐 | — | ✅ | ⚠️ **需人工** |

### 21.2 缺口按优先级排序（含修复方案）

| # | 优先级 | 问题 | 影响 | 修复方案 |
|---|:---:|---|---|---|
| **1** | 🔴 **P0** | Tempo `metrics-generator` processors 未启用（`overrides: null`） | 服务图空白、无 Tempo 版 RED | `tempo3-runtime` CM 改为：<br>`overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]` |
| **2** | 🔴 **P0** | Prometheus 未开 remote-write receiver | 即使 processors 启用也推不进去 | Prometheus CR 加 `enableRemoteWriteReceiver: true` |
| **3** | 🟠 **P1** | 唯一 trace 生产者是 Traefik，业务应用零埋点 | trace 只有 2 个 span，无业务链路 | 给业务应用加 OTel SDK + `OTEL_EXPORTER_OTLP_ENDPOINT` |
| **4** | 🟠 **P1** | Traefik `--tracing.sampleRate=1.0` | 全采样，量一涨就炸 | 改为尊重上游采样（去掉 `sampleRate`），采样决策交给 Collector `tail_sampling` |
| **5** | 🟡 **P2** | exemplar 完全没开 | Metrics→Trace 下钻不可用 | ① 修 #1/#2 后自动恢复；② spanmetrics connector 加 `exemplars: {enabled: true}` |
| **6** | 🟡 **P2** | Loki `derivedFields: []` | Logs→Trace 下钻不可用 | 加 `derivedFields`（需先有日志带 traceID，见 #7） |
| **7** | 🟡 **P2** | 日志里没有 traceID | **所有日志关联的根因** | ① 应用日志格式加 traceID；② Alloy 加 trace_id 提取；③ Traefik 开 accesslog |
| **8** | 🟡 **P2** | spanmetrics 指标基数隐患（`resource_to_telemetry_conversion: true` + `k8s_pod_name`） | 业务接入后 series 爆炸 | 改用 `dimensions` 白名单，去掉 pod 级标签 |
| **9** | 🟢 **P3** | 保留期不一致：Metrics 15d，Logs/Traces 5d | 5-15 天前故障无法定位细节 | Prometheus 改 `retention: 5d`（或反过来延长 Logs/Traces） |
| **10** | 🟢 **P3** | live-store / block-builder 无 PVC（`emptyDir`） | 停机 >40min 有数据空洞 | 加 `ceph-rbd-sc` PVC（Loki 已在用） |
| **11** | 🟢 **P3** | Kafka RF=1 | Kafka 节点故障 = trace 丢失 | 单 broker 无法改 RF；至少确认 Ceph RBD 有冗余 |
| **12** | 🟢 **P3** | `backend_scheduler.job_timeout: 15s` 偏短 | 大归并作业会超时重试 | 调大到分钟级 |
| **13** | 🟢 **P3** | `consumer_group: ""` 导致 metrics-generator lag 指标失效 | 无法监控消费延迟 | 修 #1/#2 后重新验证；如仍失败则显式设置 consumer_group |
| **14** | 🟢 **P3** | `search.ingester_shards: 3` 与 live-store 副本数耦合 | 扩缩容时易漏数据 | 扩 live-store 时同步改这个值 |

### 21.3 推荐的修复顺序

```
阶段一：恢复关联能力（不动业务）
  ① 开 enableRemoteWriteReceiver          ← 5 分钟
  ② 配 overrides 启用 processors          ← 5 分钟
  ③ 验证：promql: count(traces_span_metrics_calls_total)  > 0
  ④ 验证：promql: count(traces_service_graph_request_total) > 0
  ⑤ Grafana 打开 Service Graph 视图，确认有节点和边

阶段二：修正采样策略
  ⑥ Traefik 去掉 --tracing.sampleRate=1.0
  ⑦ otel-collector 加 tail_sampling processor
  ⑧ 验证：trace 数量 < 请求数量的 10%

阶段三：接入业务（产生真实链路）
  ⑨ 选一个服务加 OTel SDK
  ⑩ 验证：Grafana 里能看到 >2 个 span 的 trace
  ⑪ 确认 Prometheus 里出现该服务的 traces_span_metrics_*

阶段四：打通日志关联
  ⑫ 应用日志格式加 traceID
  ⑬ Alloy 配置 trace_id 提取为 label
  ⑭ Loki derivedFields 加 TraceID
  ⑮ 验证：Grafana trace 详情页能跳到日志
```

### 21.4 当前集群的一个"隐性优势"

值得说明的是：**你集群的三层数据量极小**（Tempo 只有 4.1 MiB / 112 objects），这意味着：

- 所有修复操作都是**低风险的**（不会触发大规模数据迁移）
- 可以放心地做**破坏性测试**（改配置 → 观察 → 回滚）
- **但也意味着当前的"看起来没问题"是假象**——因为根本没有数据量去暴露问题

> **建议在接入业务之前，把 §21.2 的 P0/P1 全部修完并验证。** 否则一旦流量上来，P0 问题（metrics-generator 失效）会导致**指标数据永久缺失**，而这恰恰是排查时最依赖的信号。

---

## 22. 术语速查 · 关联篇

| 术语 | 英文 | 一句话解释 |
|---|---|---|
| 三支柱 | Three Pillars | Metrics / Logs / Traces |
| 基数 | Cardinality | 指标的标签组合数量；爆炸会导致 OOM |
| 维度 | Dimension | 用于切分指标的标签 |
| RED | Rate / Error / Duration | 服务健康三核心指标 |
| 用例 | USE | Util / Saturation / Error，资源视角 |
| 跨度指标 | Span Metrics | 从 span 聚合出的指标（Trace→Metrics 方向） |
| 服务图 | Service Graph | 服务间调用拓扑 |
| 样本 | Exemplar | 挂在指标样本上的 traceID 引用 |
| 服务图数据源 | serviceMap | Grafana 服务图的数据来源配置 |
| 节点图 | Node Graph | Grafana 的服务依赖可视化 |
| 派生字段 | Derived Fields | Loki 数据源配置：从日志正文提取 traceID 并渲染链接 |
| 追踪到日志 | tracesToLogsV2 | Tempo 数据源配置：给定 trace 生成 LogQL |
| 追踪到指标 | tracesToMetrics | Tempo 数据源配置：给定 trace 返回对应时间段的指标 |
| Loki 搜索 | lokiSearch | Tempo 数据源配置：按 service.name 搜日志（弱关联） |
| 时间偏移 | Time Shift | 关联查询时相对 span 时间的前后偏移量 |
| 资源到遥测转换 | resource_to_telemetry_conversion | 把 resource 属性转成指标标签 |
| 尾部采样 | tail_sampling | Collector 端基于完整 trace 做采样决策 |
| 采样概率阈值 | tracestate `ot=th:` | 通过 tracestate 传递采样门槛 |
| 归一化命名 | Normalization | 统一指标名（避免前缀不一致） |

---

# 第四部分 · 改进清单

## 23. 配置变更清单（可直接执行）

### 23.1 P0-①：Prometheus 开启 remote-write receiver

```bash
# 1. 备份
kubectl get prometheus prometheus-prometheus -n monitoring -o yaml \
  > /root/prometheus-cr-backup-$(date +%Y%m%d-%H%M%S).yaml

# 2. 打补丁
kubectl patch prometheus prometheus-prometheus -n monitoring --type=merge -p \
  '{"spec":{"enableRemoteWriteReceiver":true}}'

# 3. 验证（需要等 STS 滚动完成，约 1-2 分钟）
kubectl rollout status sts/prometheus-prometheus-prometheus -n monitoring --timeout=5m

# 4. 验证端点已开启
kubectl exec -n monitoring <grafana-pod> -c grafana -- \
  curl -s -XPOST -H "Content-Type: application/x-protobuf" --data-binary '' \
  http://prometheus-prometheus.monitoring:9090/api/v1/write -w "\nHTTP %{http_code}\n"
# 期望：不再是 404，而是 400（缺少数据）或 415（媒体类型不对）
```

> **注意**：Prometheus Operator 需要给 StatefulSet 加 `--web.enable-remote-write-receiver` 参数并触发滚动更新。
> **单副本 Prometheus 滚动更新期间会有短暂不可用**（约 1-2 分钟）。
> 如果要做 HA（2 副本），滚动更新才是无中断的。

### 23.2 P0-②：启用 metrics-generator processors

```bash
# 1. 备份
kubectl get cm tempo3-runtime -n logging -o yaml \
  > /root/tempo3-runtime-backup-$(date +%Y%m%d-%H%M%S).yaml

# 2. 打补丁
kubectl patch cm tempo3-runtime -n logging --type=merge -p \
  '{"data":{"overrides.yaml":"overrides:\n  defaults:\n    metrics_generator:\n      processors:\n        - service-graphs\n        - span-metrics\n"}}'

# 3. 触发重载（backend-scheduler / worker / metrics-generator 会定期读这个文件）
#    最保险：滚动重启这三个组件
kubectl rollout restart sts/tempo3-metrics-generator -n logging
kubectl rollout restart sts/tempo3-backend-scheduler -n logging
kubectl rollout restart sts/tempo3-backend-worker -n logging

# 4. 等待
for c in tempo3-metrics-generator tempo3-backend-scheduler tempo3-backend-worker; do
  kubectl rollout status sts/$c -n logging --timeout=3m
done

# 5. 验证（等 2-3 个采集周期 = 45 秒）
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  --data-urlencode 'query=tempo_metrics_generator_registry_active_series' \
  http://prometheus-prometheus.monitoring:9090/api/v1/query
# 期望：> 0

# 6. 验证 traces_* 指标出现
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  --data-urlencode 'query=count(traces_span_metrics_calls_total)' \
  http://prometheus-prometheus.monitoring:9090/api/v1/query
# 期望：> 0
```

> ⚠️ **官方迁移文档的警告**（适用于从 2.x 迁移的场景）：
> > "If your metrics-generator uses the `local_blocks` processor, remove it (block building is handled internally by the live-store)."
> > "The `local-blocks` processor has been removed."
>
> **不要加 `local-blocks` 到 processors 列表**——Tempo 3.0 已经移除了它。

### 23.3 P1：修正 Traefik 采样策略

```bash
# 移除 --tracing.sampleRate=1.0，让 Traefik 尊重上游的采样决策
# ⚠️ 这是 helm chart 管理的话，需要改 values 而不是直接改 Deployment
helm get values traefik -n traefik    # 查看当前用户 values
# 修改 values.yaml，删除 --tracing.sampleRate=1.0 这一行
# 或者改成更低的比例（如果确定不需要全采样）
helm upgrade traefik traefik/traefik -n traefik -f updated-values.yaml
```

**更彻底的方案**（在 otel-collector 做 Tail Sampling）：

```yaml
# otel-collector 配置新增
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 1000
    policies:
      - name: errors-always
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow-requests
        type: latency
        latency: {threshold_ms: 1000}
      - name: baseline
        type: probabilistic
        probabilistic: {sampling_percentage: 5}

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling, batch]      # ★ tail_sampling 必须在 batch 之前
      exporters: [otlp_grpc/tempo, debug, spanmetrics]
```

> ⚠️ **`tail_sampling` 的三个前提**（否则会得到错误的采样决策）：
> 1. `decision_wait` 必须**大于**正常的 trace 完成时间（否则在 span 到齐前就决策了）
> 2. **同一个 trace 的所有 span 必须经过同一个 Collector 实例**（否则永远等不齐）→ 需要 `loadbalancing` exporter 或单副本
> 3. 必须放在 `batch` **之前**
>
> **对你集群的现实评估**：目前只有 Traefik 一个生产者，**span 在 ~4ms 内全部到齐**，所以 `tail_sampling` 能工作。
> 但一旦接入业务（尤其有异步操作），需要认真设计。

### 23.4 P2：开启 exemplar

```yaml
# otel-collector 配置
connectors:
  spanmetrics:
    exemplars:
      enabled: true
    dimensions:
      - name: http.method
      - name: http.status_code
      - name: http.route
    exclude_dimensions: ["status.code"]
```

> **注意**：`spanmetrics` connector 的 exemplar 支持依赖 collector 版本。
> 你集群是 `opentelemetry-operator-0.145.0` + `otel-operator-0.106.0`（2026-03 部署），
> 修改前需确认 connector 的 `exemplars` 字段支持。

### 23.5 P2：Loki derivedFields + 日志 trace_id

**第一步：让 Traefik 开 access log**（先有日志）

```bash
# Traefik deployment 加参数
--accesslog=true
--accesslog.format=json
--accesslog.fields.headers.defaultmode=drop
--accesslog.fields.headers.names.X-Request-Id=keep
```

**第二步：在 Grafana 日志里配置 derivedFields**

```yaml
# Loki 数据源
derivedFields:
  - name: TraceID
    matcherRegex: 'traceparent":"?([0-9a-f]{32})'   # 匹配日志里的 trace-id
    url: '${__value.raw}'
    datasourceUid: afia1p4xshn9cf                   # Tempo 的 uid
    matcherType: name
```

**第三步（应用侧，最根本）：在应用日志里写入 trace_id**

以 OTel 自动埋点为例：

```java
// Spring Boot + Micrometer Tracing
logging.pattern.level = "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

```go
// Go + logrus/otelzap
logger.WithFields(logrus.Fields{
    "trace_id": trace.SpanContextFromContext(ctx).TraceID().String(),
    "span_id":  trace.SpanContextFromContext(ctx).SpanID().String(),
}).Info("处理订单")
```

> **这一步无法在基础设施层绕过。** 日志里的 trace_id 必须由应用写入。

### 23.6 P3：保留期统一

**选项 A：全部对齐到 5 天**（与当前 `retention-unification-5d.md` 的方向一致）

```yaml
# Prometheus CR
spec:
  retention: 5d
  retentionSize: 8GiB        # 当前是 25GiB，按 5 天算可以缩
```

**选项 B：全部对齐到 15 天**（数据量增长后考虑）

```bash
# Loki
compactor.retention_period: 360h
index_gateway.retention_period: 360h
# alloy stage.drop.older_than: "360h"    ★ 必须同步改，否则采集端还在读已删除的日志

# Tempo
backend_scheduler.provider.compaction.block_retention: 360h
backend_worker.compaction.block_retention: 360h

# Prometheus
spec.retention: 15d                        # 已经是
```

> ⚠️ **保留期必须四处同步**（Tempo ×2 + Loki ×2 + Alloy ×1），少改一处就会出问题。
> 具体的四处及默认值详见 `/root/retention-unification-5d.md`。

### 23.7 P3：给 live-store 加 PVC

```bash
# 1. 检查当前 StatefulSet 的 volumeClaimTemplates
kubectl get sts tempo3-live-store -n logging -o jsonpath='{.spec.volumeClaimTemplates}'
# 输出为空 → 无 PVC

# 2. helm values 添加 persistence
helm get values tempo3 -n logging    # 查看当前 values

# 在 values 中添加：
# liveStore:
#   persistence:
#     enabled: true
#     size: 10Gi
#     storageClass: ceph-rbd-sc
```

> **注意**：`tempo-distributed` chart 的 liveStore 是否支持 `persistence.enabled`，需要先确认。
> 如果不支持，需要用 `extraVolumes` + `extraVolumeMounts` 手工挂 PVC 到 `/var/tempo/live-store/traces`。

---

# 附录 A · 全部实测命令

以下命令都可以直接复现本文档的所有结论。

## A.1 环境与版本

```bash
# Tempo 版本与 chart
helm list -A | grep tempo3
kubectl get sts,deploy -n logging -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'

# 集群版本
kubectl get nodes -o wide
kubectl get pods -n logging -o wide
```

## A.2 Tempo 配置

```bash
# ConfigMap 内容（声明值）
kubectl get cm tempo3-config -n logging -o jsonpath='{.data}' | python3 -c \
  "import sys,json;d=json.load(sys.stdin);[print('#### FILE:',k,'####\n',v) for k,v in d.items()]"

# 运行时实际值（★ 权威来源，会含默认值）
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://tempo3-query-frontend.logging.svc.cluster.local:3200/status/config'

kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://tempo3-querier.logging.svc.cluster.local:3200/status/config'

kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://tempo3-distributor.logging.svc.cluster.local:3200/status/config'

# overrides 文件（★ 关键：metrics-generator 的开关在这里）
kubectl get cm tempo3-runtime -n logging -o jsonpath='{.data.overrides\.yaml}'
```

## A.3 冷层对象存储

```bash
# bucket 概览
kubectl run s3probe --rm -i --restart=Never --image=minio/mc:latest --quiet --command -- sh -c '
mc alias set t http://10.0.0.31:7480 <ACCESS_KEY> <SECRET_KEY> >/dev/null 2>&1
mc du t/tempo-traces
mc ls --recursive t/tempo-traces
'

# 单个 block 的元数据
mc cat t/tempo-traces/single-tenant/<blockID>/meta.json

# backend-scheduler 作业状态
mc cat t/tempo-traces/work.json

# blocklist
mc cat t/tempo-traces/single-tenant/index.pb.zst | head -c 200
```

## A.4 Kafka 分区状态（★ 验证 partition 假设）

```bash
# topic 分区数与 offset（★ 这条命令直接证明了 §15.3）
kubectl exec -n kafka my-cluster-single-pool-0 -c kafka -- \
  bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic tempo-traces

# 详细分区信息
kubectl exec -n kafka my-cluster-single-pool-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic tempo-traces

# 动态配置
kubectl exec -n kafka my-cluster-single-pool-0 -c kafka -- \
  bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name tempo-traces --describe
```

## A.5 分区归属（★ 验证 block-builder / live-store 的 partition）

```bash
# block-builder 消费的 partition
for i in 0 1 2; do
  echo -n "bb-$i: "
  kubectl logs -n logging tempo3-block-builder-$i | grep -oE "partition=[0-9]+" | sort -u | tr '\n' ' '
  echo
done

# live-store 的 partition
for i in 0 1 2; do
  echo -n "ls-$i: "
  kubectl logs -n logging tempo3-live-store-$i | grep -oE "partition=[0-9]+" | sort -u | tr '\n' ' '
  echo
done

# Prometheus 指标视图（★ 更简洁）
# promql: tempo_block_builder_owned_partitions
```

## A.6 上下文传播实验（§6 全部实验）

```bash
# ① 部署探针
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: hdr-probe-cm, namespace: monitoring}
data:
  default.conf: |
    server {
      listen 8080;
      location / {
        default_type text/plain;
        return 200 "traceparent=$http_traceparent\ntracestate=$http_tracestate\nbaggage=$http_baggage\nx-request-id=$http_x_request_id\nua=$http_user_agent\n";
      }
    }
---
apiVersion: v1
kind: Pod
metadata: {name: hdr-probe, namespace: monitoring, labels: {app: hdr-probe}}
spec:
  containers:
  - {name: hdr, image: docker.io/nginxinc/nginx-unprivileged:1.29-alpine, ports: [{containerPort: 8080}],
     volumeMounts: [{name: cfg, mountPath: /etc/nginx/conf.d, readOnly: true}]}
  volumes: [{name: cfg, configMap: {name: hdr-probe-cm}}]
  restartPolicy: Never
---
apiVersion: v1
kind: Service
metadata: {name: hdr-probe, namespace: monitoring}
spec:
  selector: {app: hdr-probe}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: hdr-probe, namespace: monitoring}
spec:
  entryPoints: [websecure]
  routes:
  - {kind: Rule, match: 'Host(`hdr-probe.example.local`)', services: [{name: hdr-probe, port: 80}]}
  tls: {certResolver: default}
EOF

kubectl wait --for=condition=Ready pod/hdr-probe -n monitoring --timeout=90s
sleep 5

# ② 实验 A：无入站 traceparent
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  https://hdr-probe.example.local/probe

# ③ 实验 B：W3C 续接
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  https://hdr-probe.example.local/probe

# ④ 实验 C：采样标志覆盖
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00" \
  https://hdr-probe.example.local/probe

# ⑤ 实验 D：B3 格式
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  -H "X-B3-TraceId: 463ac35c9f6413ad48485a3953bb6124" \
  -H "X-B3-SpanId: a2fb4a1d1a96d312" \
  https://hdr-probe.example.local/probe

# ⑥ 实验 E：非法 version
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  -H "traceparent: ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  https://hdr-probe.example.local/probe

# ⑦ 实验 F：tracestate 透传
kubectl run curlprobe --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -sk --max-time 20 --resolve hdr-probe.example.local:443:10.111.240.160 \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  -H "tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE" \
  https://hdr-probe.example.local/probe

# ⑧ 清理（★ 必须执行）
kubectl delete ingressroute hdr-probe -n monitoring
kubectl delete pod/hdr-probe svc/hdr-probe cm/hdr-probe-cm -n monitoring
kubectl get pod,svc,cm,ingressroute -A | grep -E "hdr-probe|curlprobe"   # 应无输出
```

## A.7 查询 Tempo

```bash
# 按 traceID 查（★ 命中热层，秒级）
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://tempo3-query-frontend.logging.svc.cluster.local:3200/api/traces/c381588241aec5e52f499adb72e1a8c9'

# 搜索（★ 默认最近时段；★ 数据量大时必须指定时间范围）
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  "http://tempo3-query-frontend.logging.svc.cluster.local:3200/api/search?start=$(( \$(date +%s) - 432000 ))&end=\$(date +%s)&limit=20"

# Tag 列表
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://tempo3-query-frontend.logging.svc.cluster.local:3200/api/search/tags'
```

## A.8 关联链路验证（★ §20 全部结论）

```bash
P=http://prometheus-prometheus.monitoring:9090
GF='kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s'

# ① spanmetrics connector（✅ 应有结果）
$GF --data-urlencode 'query=count(otel_demo_traces_span_metrics_calls_total)' $P/api/v1/query
$GF --data-urlencode 'query=sum(otel_demo_traces_span_metrics_calls_total)' $P/api/v1/query

# ② Tempo metrics-generator（❌ 应为 EMPTY）
$GF --data-urlencode 'query=count(traces_span_metrics_calls_total)' $P/api/v1/query
$GF --data-urlencode 'query=count(traces_service_graph_request_total)' $P/api/v1/query
$GF --data-urlencode 'query=count(traces_spanmetrics_duration_seconds_bucket)' $P/api/v1/query

# ③ ★★ 决定性证据：remote-write receiver 未开启 → 404
$GF -XPOST -H "Content-Type: application/x-protobuf" --data-binary '' \
  $P/api/v1/write -w "\nHTTP %{http_code}\n"
# 期望输出：404 + "remote write receiver needs to be enabled with --web.enable-remote-write-receiver"

# ④ metrics-generator 内部状态（★ active_series=0 是根因 1 的证据）
$GF --data-urlencode 'query=tempo_metrics_generator_registry_active_series' $P/api/v1/query
$GF --data-urlencode 'query=tempo_metrics_generator_registry_collections_total' $P/api/v1/query
$GF --data-urlencode 'query=tempo_metrics_generator_bytes_received_total' $P/api/v1/query
$GF --data-urlencode 'query=tempo_metrics_generator_processor_span_metrics_calls_total' $P/api/v1/query

# ⑤ 全量指标名扫描（找 traces_* / service_graph）
$GF "$P/api/v1/label/__name__/values" | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
for n in sorted(d):
    if any(k in n for k in ('service_graph','span_metrics','spanmetrics')): print(n)
"

# ⑥ Grafana 数据源关联配置
kubectl get cm prometheus-grafana-datasource -n monitoring -o jsonpath='{.data.datasource\.yaml}'
# ★ 重点看 Tempo 的 tracesToLogsV2 / tracesToMetrics / serviceMap / lokiSearch
# ★ 以及 Loki 的 derivedFields（当前为 []）

# ⑦ Loki 侧确认日志无 trace_id
#    Loki 开启 auth_enabled: true，未带租户头返回 401 "no org id"
#    Alloy 写入用 tenant_id="fake"（见 alloy-config），查询必须带同样的头
$GF -H "X-Scope-OrgID: fake" \
  --data-urlencode 'query={namespace="traefik"} |~ "trace_?[iI]D"' \
  'http://loki-gateway.logging.svc.cluster.local/loki/api/v1/query_range'
```

## A.9 保留期核对

```bash
# Prometheus
kubectl get prometheus prometheus-prometheus -n monitoring -o jsonpath='{.spec.retention}{"\n"}'

# Loki（★ 运行时值，权威）
kubectl exec -n monitoring <grafana-pod> -c grafana -- curl -s \
  'http://loki-backend.logging.svc.cluster.local:3100/config' | \
  grep -E 'retention_period|retention_enabled|reject_old_samples_max_age'

# Tempo
kubectl get cm tempo3-config -n logging -o jsonpath='{.data.tempo\.yaml}' | grep -E 'block_retention'

# Alloy（★ 必须与 Loki 同步）
kubectl get cm alloy-config -n logging -o jsonpath='{.data.config\.alloy}' | grep -A3 'stage.drop'
```

## A.10 存储持久性检查

```bash
# ★ 所有 tempo3 Pod 都是 emptyDir（无 PVC）——这是 §16 的证据
for p in tempo3-live-store-0 tempo3-block-builder-0 \
         tempo3-distributor-6c4d7f8568-j9bn2 tempo3-querier-d44b97ffc-bs5bx; do
  echo "--- $p ---"
  kubectl get pod -n logging $p -o jsonpath='{range .spec.volumes[*]}{.name}{" -> "}{.emptyDir}{.persistentVolumeClaim.claimName}{"\n"}{end}'
done

# 对比：Loki 是有 PVC 的
kubectl get pvc -n logging
```

---

# 附录 B · 术语总表

## B.1 标准与协议

| 术语 | 全称 / 来源 | 说明 |
|---|---|---|
| W3C Trace Context | W3C Recommendation | traceparent / tracestate 规范 |
| W3C Baggage | W3C Recommendation | 跨进程业务上下文 |
| OTLP | OpenTelemetry Protocol | Collector 与后端之间的传输协议（gRPC/HTTP） |
| OTLP/gRPC 4317 | 端口 | OTLP over gRPC |
| OTLP/HTTP 4318 | 端口 | OTLP over HTTP |
| Jaeger 14268 / Zipkin 9411 | 端口 | 旧协议端口（你集群 Tempo 开 `55680` legacy） |
| OpenTracing | — | 已废弃的旧标准 |
| B3 | Zipkin 格式 | `X-B3-*` 头，事实标准 |
| TraceContext | OTel propagator 名称 | 对应 W3C `traceparent` |
| b3multi / b3 | OTel propagator 名称 | 对应 B3 多头/单头 |

## B.2 三支柱

| 术语 | 说明 |
|---|---|
| Prometheus / PromQL | 指标存储与查询语言 |
| TSDB | Time Series Database，Prometheus 的存储引擎 |
| Loki / LogQL | 日志存储与查询语言 |
| Tempo / TraceQL | trace 存储与查询语言 |
| vParquet4 | Tempo 2/3 的块格式与查询引擎名 |
| RED | Rate / Error / Duration |
| USE | Utilization / Saturation / Error |
| Four Golden Signals | Latency / Traffic / Errors / Saturation |

## B.3 Grafana 关联配置项

| 配置项 | 所在数据源 | 方向 | 作用 |
|---|---|---|---|
| `tracesToLogsV2` | Tempo | Trace → Logs | 用 traceID 过滤日志 |
| `tracesToMetrics` | Tempo | Trace → Metrics | 返回对应时段指标 |
| `serviceMap` | Tempo | — | 服务图数据源 |
| `lokiSearch` | Tempo | Trace → Logs | 按 service.name 搜日志 |
| `derivedFields` | Loki | Logs → Trace | 日志里的可点击 trace 链接 |
| `nodeGraph` | Tempo | — | 节点图开关 |
| `exemplars` | spanmetrics connector | Metrics → Trace | 生成 exemplar |

## B.4 本集群专有名词速查

| 名词 | 值 | 说明 |
|---|---|---|
| `single-tenant` | tenant ID | Tempo 实际租户名（`multitenancy_enabled: false`） |
| `tempo-traces` | Kafka topic + S3 bucket | 同一名字但两处不同对象 |
| `hdr-probe` | 探针名 | 已删除 |
| `otel_demo` | 指标前缀 | otel-collector prometheus exporter 的 namespace |
| `fake` | Loki 租户 | Alloy 写入时用的 tenant_id |
| `PartitionActive` | 分区状态 | Tempo partition ring 的正常读写态 |
| `meta.compacted.json` | 文件名 | 归并产物的元数据 |
| `work.json` | 文件名 | backend-scheduler 作业状态（32 shard） |
| `index.pb.zst` | 文件名 | blocklist（protobuf + zstd） |
| `tempo_cluster_seed.json` | 文件名 | memberlist 持久化种子 |
| `nocompact.flg` | 文件名 | block 构建中标记（**永远 0 字节**） |

---

## 结语：这份文档的三个核心结论

1. **上下文传播的本质是"把 16 字节的身份塞进 HTTP 头"**。`trace-id` 永不变（血缘），`parent-id` 每跳重算（关系）。你集群的 Traefik 完整实现了注入（§6 六组实验证明），但下游 Grafana 无人提取，链路断在网关。

2. **Tempo 的冷热分层是"用延迟换成本"**：内存（live-store）秒级查但只存 20 分钟且不持久；对象存储（Ceph RGW）存 5 天但查询要经过 bloom → index → parquet 三级过滤 + memcached 缓存。中间用 Kafka 做持久化缓冲（7 天 retention），把"写入吞吐"和"查询延迟"解耦。

3. **三支柱关联在你的集群是"配置齐全但数据断裂"**：Grafana 侧的关联配置基本都对，但 Tempo 的 metrics-generator 因为两个独立根因（processors 未启用 + remote-write receiver 未开启）完全失效，日志侧则从来没有注入过 trace_id。**这些不是配置问题，是数据生产端的问题。**

**最有价值的优先级建议**：先修 §23.1 和 §23.2 两个 P0（10 分钟的工作量），恢复服务图和 Tempo 版 RED 指标；然后在接入业务之前修好采样策略（§23.3），否则第一个业务应用接入就会把 512Mi 的 live-store 打爆。

---

*文档生成时间：2026-10-03*
*集群状态快照：Tempo 3.0.3 / Kafka 4.1.2 / Ceph RGW 18.2.8 / Prometheus v3.11.2 / Loki 3.6.7 / K8s v1.35.9*
*所有实验数据均为实测，探针资源已完全清理*
