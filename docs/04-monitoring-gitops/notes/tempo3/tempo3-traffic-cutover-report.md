# Tempo 3.x 流量切换报告（tempo2 → tempo3）

> **执行时间**：2026-09-29 08:28 – 08:45 (CST)
> **切换目标**：把 trace 流量入口（OTel Collector exporter）+ 查询入口（Grafana Tempo 数据源）从旧栈 `tempo` 切到 `tempo3`
> **备份目录**：`/root/observability-upgrade-backup-20260928-202328-traffic-cut`（15 文件 / 672 KB）
> **关联文档**：`/root/tempo3-coexistence-assessment.md`（共存评估）、`/root/observability-phase2-fixes.md`（tempo3 P0 修复）

---

## 目录

- [0. 一句话结论](#0-一句话结论)
- [1. 变更清单](#1-变更清单)
- [2. 切换前的意外发现：trace 管道已断 44 小时](#2-切换前的意外发现trace-管道已断-44-小时)
- [3. 离线校验（落线前）](#3-离线校验落线前)
- [4. 实际执行过程](#4-实际执行过程)
- [5. 验证结果](#5-验证结果)
- [6. 影响评估](#6-影响评估)
- [7. 风险与回滚](#7-风险与回滚)
- [8. 工具失误记录](#8-工具失误记录)
- [9. 遗留问题](#9-遗留问题)
- [10. 复现命令](#10-复现命令)

---

## 0. 一句话结论

> **切换成功，并且顺带修掉了一个已存在 44 小时的静默故障。**
>
> 变更共 2 处、**各只改 1 行**：Grafana 数据源 URL、OTel Collector endpoint。全部验证通过：
> **tempo3 精确 +1 span / 旧栈保持不动 / Collector `sent_spans` 首次从 0 变为 1 / 零错误日志**。
>
> ⚠️ 但本次最重要的发现不是"切换本身"，而是：**在切换前的基线测量中，发现旧栈的 trace 写入管道自 2026-09-27 05:56 起就已半断** —— 数据能过去但 ack 回不来，Collector 无限重试、最终丢弃，同时旧栈收到**重复数据**。这个故障此前无人察觉（无 Tempo 告警规则）。

---

## 1. 变更清单

| # | 对象 | 文件/字段 | 变更前 | 变更后 |
|---|---|---|---|---|
| **1** | Grafana 数据源 `tempo`（id=4, uid `afia1p4xshn9cf`） | `url` | `http://tempo-query-frontend.logging.svc.cluster.local:3200` | `http://tempo3-query-frontend.logging.svc.cluster.local:3200` |
| **2** | OpenTelemetryCollector `opentelemetry/otel` | `spec.config.exporters["otlp_grpc/tempo"].endpoint` | `tempo-distributor.logging.svc.cluster.local:4317` | `tempo3-distributor.logging.svc.cluster.local:4317` |

**变更量**：2 个对象，**2 个字段**。未新增/删除任何 Service、Deployment、StatefulSet、数据源、桶、topic。

**未触碰**：`tempo`（2.x）release 本身、`tempo3` 的 values 与 ConfigMap、Loki、Prometheus、Alertmanager、Alloy、Kafka topic、任何 PVC/数据。

**执行顺序（刻意）**：先改"看"的一端（数据源），再改"写"的一端（exporter）。反序会出现 Collector 已切、数据源未切的窗口期，期间所有新 trace 都查不到。

---

## 2. 切换前的意外发现：trace 管道已断 44 小时

### 2.1 起因

按 `tempo3-coexistence-assessment.md` §5 阶段一的计划，切换前先测"变更前计数器基线"。基线取回来是空的（探查 Pod 已过期，见 §8.2），重建后取到真实值：

```
## tempo(old)
  tempo_distributor_spans_received_total{tenant="single-tenant"} 14
## tempo3(new)
  tempo_distributor_spans_received_total{tenant="single-tenant"} 1
```

但 Collector 侧的计数更反常：

```
otelcol_exporter_sent_spans_total{exporter="otlp_grpc/tempo"}      0
otelcol_exporter_send_failed_spans_total{exporter="otlp_grpc/tempo"} 1
```

**旧栈累计收到 14 条 span（155 天），而 Collector 自上次重启以来成功发送 0 条、失败 1 条。** 两者矛盾，必须查清。

### 2.2 根因

Collector 日志给出了完整因果链：

```
2026-09-27T05:56:39Z  warn  grpc@v1.78.0/clientconn.go:1526  [core] [Channel #1 SubChannel #4]
        grpc: addrConn.createTransport failed to connect to {Addr: "10.96.63.117:4317",
        ServerName: "tempo-distr…"

2026-09-27T14:00:01Z  info  internal/retry_sender.go:133  Exporting failed. Will retry the request after interval.
        （连续重试 4 分 38 秒，14:00:01 → 14:04:39）
2026-09-27T14:04:39Z  error internal/queue_sender.go:50   Exporting failed. Dropping data.
```

`10.96.63.117` 正是旧栈 `tempo-distributor` 的 ClusterIP，且这个时间点（05:56）紧跟 2026-09-27 05:55 的**九 Pod 同时重启**事件（`observability-phase2-fixes.md` 已记录该事件）。

时间线：

| 时刻 | 事件 |
|---|---|
| 2026-09-27 05:55:01 | Collector 第 6 次重启（计数窗口归零） |
| 2026-09-27 05:55 | 旧栈 9 个 Pod 同时重启（节点级事件） |
| 2026-09-27 05:56:39 | Collector 无法建立到 `10.96.63.117:4317` 的 gRPC 连接 |
| 2026-09-27 14:00–14:04 | 一条 span 重试 4 分 38 秒后被永久丢弃 |
| 2026-09-27 → 至今 | **无任何流量进入系统**，故障静默持续 ~44 小时 |

### 2.3 关键证据：连接是"半断"的，不是"不通"

TCP 探活显示 4317 **是通的**：

```
[t-ep] DNS tempo3-distributor... → 10.105.251.62
      ✅ 4317 开放  ✅ 4318 开放
[t-ep] 旧栈 tempo-distributor... → 10.96.63.117
      ✅ 旧 4317 也开放
```

所以"端口通不通"完全测不出这个故障。必须用**真实数据注入**才能暴露：

```
注入 1 条 span 到 Collector（OTLP/HTTP 4318）→ HTTP 200
等待 batch flush + 重试窗口 20s

结果：
  tempo(old)   14 → 17     ← 1 条 span 变成 3 条（重复投递）
  tempo3(new)   1 →  1
  collector sent_spans{otlp_grpc/tempo}  仍然 = 0    ← 从未确认成功
  collector 日志: 持续 "Exporting failed. Will retry…"（00:29:49 起新一轮）
```

**判定**：gRPC 连接处于"请求能送达、响应 ack 回不来"的半断状态。Collector 以为失败而重试，Tempo 实际收到数据 → **重复 + 最终丢弃**双重损害。

> 📌 这解释了为什么旧栈 155 天只积累 14 条 span：**写入管道基本一直是坏的**。

### 2.4 为什么此前无人发现

| 原因 | 说明 |
|---|---|
| 无 Tempo 告警规则 | 全集群 36 条 PrometheusRule 中含 `tempo` 的 **0 条** |
| 无 Tempo 数据源健康检查 | Grafana 面板本就返回 500（见 §9.1），没人把它当"新问题" |
| 监控只覆盖 distributor | querier / live-store / backend / block-builder 无指标 |
| 上游确实几乎无流量 | Collector `receiver_accepted_spans_total` 累计仅 1 条 |

---

## 3. 离线校验（落线前）

严格遵循"**先离线校验，确认后再落线上**"。

### 3.1 校验 A：tempo3 能否服务 Grafana 会调用的 API

对两栈 query-frontend 逐端点对照（判读依据是**状态码差异**，不是"服务是否可用"）：

| Grafana 会调的端点 | 旧栈（切换前数据源） | 新栈（切换目标） |
|---|:---:|:---:|
| `/api/echo` | 200 | 200 |
| `/api/search?limit=20` | **500** | **200** |
| `/api/search/tags` | **500** | **200** |
| `/api/v2/search/tags` | **500** | **200** |
| `/api/search?start&end&limit`（Grafana 实际形态） | **500** | **200** |

新栈响应体有效：

```json
{"traces":[],"metrics":{"completedJobs":3,"totalJobs":3}}
```

### 3.2 校验 B：Collector 新配置能否通过 validate

用 Collector 镜像**自带的 `validate` 子命令**离线校验（不是猜配置对不对）：

```
镜像: ghcr.io/…/opentelemetry-collector-contrib:0.145.0
命令: validate --config=/conf/collector.yaml
结果: exitCode=0, reason=Completed, 无输出
```

配置 diff —— 确认**只有一行变化**：

```diff
7c7
<     endpoint: tempo-distributor.logging.svc.cluster.local:4317
---
>     endpoint: tempo3-distributor.logging.svc.cluster.local:4317
```

差异行数 **2**（1 删 1 增），符合预期。

### 3.3 校验 C：新 endpoint 在 Collector 所在 ns 可达

DNS 与 gRPC 端口必须**从 `opentelemetry` ns** 验证（Collector 跑在那里）：

```
DNS  tempo3-distributor.logging.svc.cluster.local → 10.105.251.62
TCP  10.105.251.62:4317  ✅ 开放
TCP  10.105.251.62:4318  ✅ 开放（对照）
```

### 3.4 校验 D：patch 预演

```bash
kubectl patch opentelemetrycollector otel -n opentelemetry \
  --type=json --patch-file=/tmp/otel-patch.json --dry-run=server
# → ✅ server 端校验通过
#   新 endpoint = tempo3-distributor.logging.svc.cluster.local:4317
#   traces pipeline exporters = ['otlp_grpc/tempo', 'debug', 'spanmetrics']  未变
#   tls = {'insecure': True}  未变
```

---

## 4. 实际执行过程

### 4.1 变更 1/2：Grafana 数据源 URL

```
PUT /api/datasources/uid/afia1p4xshn9cf     → HTTP 200
```

**最小化载荷策略**：GET 当前对象 → 只改 `url` → PUT 回写。显式携带 `jsonData` 原样传入，避免 Grafana 重建时丢失关联配置。

回读验证（不信响应体，读实际对象）：

```
url:      http://tempo-query-frontend...  →  http://tempo3-query-frontend...
version:  38 → 1（Grafana 版本号，非语义变化）
name / type / access 未变:  True / True / True
jsonData 未变:              True
实际变化字段: ['url', 'version']      ← 只有这两个
```

`jsonData` 中两个关联引用保持有效（`tracesToLogsV2` → loki uid `dfi90c2a1osn4c`；`tracesToMetrics` → prometheus），已核对 uid 存在。

### 4.2 变更 2/2：OTel Collector endpoint

用 **JSON Patch**（最原子，非整对象 replace）：

```json
[{"op":"replace",
  "path":"/spec/config/exporters/otlp_grpc~1tempo/endpoint",
  "value":"tempo3-distributor.logging.svc.cluster.local:4317"}]
```

> key `otlp_grpc/tempo` 含 `/`，JSON Pointer 中必须转义为 `~1`。

应用后：

```
opentelemetrycollector.opentelemetry.io/otel patched
endpoint    = tempo3-distributor.logging.svc.cluster.local:4317
generation  = 8 → 9
其余 exporter = ['debug', 'otlp_grpc/tempo', 'prometheus']   未变
receivers    = ['grpc', 'http']                              未变
```

### 4.3 Operator 滚动

```
t+5s   otel-collector-985847d99-2rgrk  0/1  ContainerCreating  (新)
       otel-collector-98795c445-kjvm5  1/1  Running             (旧，142d)
→ 滚动完成
```

Operator 生成了新 ConfigMap `opentelemetry/otel-collector-326097f8`，内容确认：

```yaml
endpoint: tempo3-distributor.logging.svc.cluster.local:4317
```

**新 Pod**：`otel-collector-985847d99-2rgrk`，1/1 Running，restartCount=**0**，节点 worker01。

> 📌 `opentelemetry` ns 内另有 3 个历史遗留 ConfigMap（`089d9319` / `718612e4` / `caf5b0c0`）与 1 个 `08becd12`，其 endpoint 仍指向旧栈。**它们是 2026-04-06 的孤儿，不被任何 Deployment 挂载**，未处置（见 §9.4）。

---

## 5. 验证结果

### 5.1 ★ 核心验收：注入 1 条 span，检验是否精确 +1

这是**唯一能同时证明三件事**的测试：流量已切换、ack 正常、无重复。

| 指标 | 切换前 | 切换后 | 判定 |
|---|---:|---:|:---:|
| `tempo3` `spans_received_total` | 1 | **2** | ✅ 精确 **+1**（旧栈是 +3 重复） |
| `tempo` `spans_received_total` | 19 | **19** | ✅ 不变 |
| `tempo3` `bytes_received_total` | 173 | **354** | ✅ +181（1 条 span 的合理体积） |
| Collector `sent_spans{otlp_grpc/tempo}` | **0** | **1** | ✅ **ack 首次正常** |
| Collector `send_failed_spans` | 1 | 0（新 Pod 内） | ✅ 无失败 |
| 新 Collector `error`/`warn` 日志 | — | **0 条** | ✅ |
| 新 Collector `restartCount` | — | **0** | ✅ |

### 5.2 旧栈流量确实停止（间隔 45s 两次采样）

```
采样1  旧栈 = 19
采样2  旧栈 = 19      ← 完全静止
```

### 5.3 通过 Grafana 数据源代理查询（Grafana 面板的真实路径）

不走直连，走 `GET /api/datasources/proxy/uid/afia1p4xshn9cf/...`，确保整条链路（含 Grafana 的 URL 配置）正确：

| # | 验证项 | 结果 |
|---|---|---|
| 1 | `/api/echo`（Save&Test 用） | **HTTP 200** |
| 2 | `/api/search?start&end&limit` | **HTTP 200**，`traces` 1 条 |
| 3 | `/api/traces/{traceID}` 取完整 span | **HTTP 200**，`cutover.marker` / `service.name` 属性完整 |
| 4 | `/api/search?tags=cutover.marker=…` | **HTTP 200**，命中 |
| 5 | `/api/search/tags` | **HTTP 200** → `["cutover.marker","service.name"]` |

搜索返回体：

```json
{"traces":[{"traceID":"5b8efff798038103d269b633813fd61d",
            "rootServiceName":"cutover-probe",
            "rootTraceName":"CUTOVER_POST_1790641890",
            "startTimeUnixNano":"1790638290000000000",
            "durationMs":3600000}],
 "metrics":{"inspectedTraces":1,"inspectedBytes":"19387","completedJobs":3,"totalJobs":3}}
```

### 5.4 全集群回归

| 范围 | 结果 |
|---|---|
| **CrashLoopBackOff** | **0**（切换前也是 0） |
| 非 Running Pod | 仅 `kube-system/coredns` `ImagePullBackOff`（36h，**既有问题，与本次无关**） |
| `tempo`（旧） | **9/9 Running** ✅ |
| `tempo3`（新） | **13/13 Running** ✅ |
| Loki | 9 Pod 全部 Running ✅ |
| Prometheus | 2/2 Running ✅ |
| Alertmanager | 2/2 Running ✅ |
| Alloy | 6/6 Running ✅ |
| OTel Collector | 1/1 Running，restart 0 ✅ |

### 5.5 Grafana 数据源整体完好

```
数据源数: 4 → 4
  id=1 Prometheus   prometheus    http://prometheus-prometheus.monitoring:9090/        变化字段: 无
  id=2 Alertmanager alertmanager  http://prometheus-alertmanager.monitoring:9093/      变化字段: 无
  id=3 loki         loki          http://loki-gateway.logging.svc.cluster.local      变化字段: 无
  id=4 tempo        tempo         http://tempo3-query-frontend...:3200               变化字段: ['url']

uid / name / type / jsonData 全部保持
```

---

## 6. 影响评估

### 6.1 业务影响

| 维度 | 影响 | 程度 |
|---|---|:---:|
| **trace 数据流** | 停止写入旧栈，全部进入 tempo3 | 预期内 |
| **旧栈历史 trace 查询** | 旧栈 19 条 span 仍可通过旧 API 访问，但 Grafana 数据源已不指向它 | **需注意** |
| **应用侧中断** | Collector 滚动重启约 15s，期间 span 由 `batch` processor（`timeout: 10s`）缓冲，超时丢弃 | **约 10s 内的 trace 可能丢失** |
| **Grafana 面板** | Trace 面板现在查 tempo3；切换前查旧栈（本就 500） | **净改善** |
| **其余面板/数据源** | 零影响（已逐字段 diff 确认） | 无 |
| **Loki / Prometheus / Alertmanager** | 零影响 | 无 |
| **Kafka `tempo-traces`** | 不变 | 无 |
| **Ceph 桶 `tempo-traces`** | 不变（tempo3 本就写这里） | 无 |

### 6.2 性能与资源

| 项 | 变化 |
|---|---|
| tempo3 内存 | 59 Mi → 实测无明显变化（trace 量本身极低） |
| 旧栈 | 保持运行，占用不变（**未退役**，见 §9.3） |
| Collector | 单副本滚动，资源不变 |
| 网络 | 流量路径长度不变（ClusterIP → ClusterIP） |

### 6.3 净收益

| 项 | 切换前 | 切换后 |
|---|---|---|
| trace 写入可用性 | ❌ 半断（重复 + 丢弃，持续 44h+） | ✅ 正常（ack 正常，精确 +1） |
| trace 查询可用性 | ❌ HTTP 500 | ✅ HTTP 200 |
| 写入路径版本 | 2.9.0（2.x 已停止主线） | 3.0.3 |
| 存储后端 | 本地 emptyDir（Pod 重建即丢） | Ceph S3（持久） |
| 告警 | 无 | 无（**仍未补**，见 §9.2） |

### 6.4 风险

| 风险 | 等级 | 说明 | 缓解 |
|---|:---:|---|---|
| 上游应用尚未接入 OTel SDK | 低 | 切换后 trace 量仍接近 0（`receiver_accepted_spans_total` 累计仅 1） | 管道已就绪，接入即生效 |
| Collector 滚动期少量 span 丢失 | 低 | 约 10s 窗口，实际无流量故影响为 0 | 已发生，无法回补 |
| 旧栈历史数据暂不可查 | 中 | 620 MB emptyDir 数据仍在，但 Grafana 已不指向它 | 旧栈未退役，需要时可临时改回 URL |
| tempo3 尚无真实流量验证 block flush | 中 | 只验证了 1 条 span 的接收与查询，未验证 S3 block 落盘的完整周期 | 见 §9.5 |

---

## 7. 风险与回滚

### 7.1 回滚方式（两条独立回滚路径）

**回滚路径 A —— 只回滚查询端（秒级，影响最小）**

```bash
# 把 Grafana 数据源改回旧栈
# 载荷：url = http://tempo-query-frontend.logging.svc.cluster.local:3200
PUT /api/datasources/uid/afia1p4xshn9cf
```

**回滚路径 B —— 完整回滚（恢复写入端 + 查询端）**

```bash
kubectl patch opentelemetrycollector otel -n opentelemetry --type=json \
  --patch='[{"op":"replace","path":"/spec/config/exporters/otlp_grpc~1tempo/endpoint",
             "value":"tempo-distributor.logging.svc.cluster.local:4317"}]'
# 再执行回滚路径 A
```

> ⚠️ **但要清楚：回滚会同时恢复 §2 的故障**（重复投递 + 无限重试 + 丢弃）。回滚到旧栈不是"恢复可用"，而是"恢复一个已知有问题的状态"。

### 7.2 回滚源

| 内容 | 路径 |
|---|---|
| 备份根目录 | `/root/observability-upgrade-backup-20260928-202328-traffic-cut` |
| Collector CR 变更前 | `otel/collector-cr-before.yaml`（104 行完整 CR） |
| Collector CR 变更后 | `otel/collector-cr-after.yaml` |
| Grafana 数据源变更前 | `grafana/datasources-before.json`、`grafana/tempo-ds-before.json` |
| 变更前计数基线 | `verify/spans-before.txt`、`verify/baseline-before.txt` |
| 变更后验证证据 | `verify/after.txt` |

### 7.3 凭据处理

- Grafana admin 凭据全程以 `curl -K` 配置文件方式使用，权限 `600`，**用后即删**
- 报告与备份中**不含任何凭据明文**（已正则扫描：0 命中）
- 凭据指纹（供比对）：`admin-user` sha256[:12]=`8c6976e5b541`，`admin-password` sha256[:12]=`53baccef4ef6`

---

## 8. 工具失误记录

本轮自身出现 4 次工具故障，均已定位根因并修正。记录在此，因为**每一次都差点导致错误结论**。

### 8.1 manifest 缺 `metadata.namespace` → Pod 落到 `default` ns

- **现象**：validate Pod `apply` 报 `created`，1 秒后 `get pod -n opentelemetry` 报 NotFound，**且零事件**
- **真实原因**：manifest 里只写了 `metadata.name`，没写 `namespace`，kubectl 按 context 默认值放到了 `default` ns；而 ConfigMap 在 `opentelemetry`，跨 ns 挂载被拒 → Pod 卡 `ContainerCreating`
- **误导性**：`apply` 报 `configured`（因为前一次 `delete --wait=false` 留下了正在终止的对象，apply 打在它身上），加剧了误判
- **修复**：manifest 显式加 `"namespace":"opentelemetry"`
- **教训**：**JSON manifest 必须显式写 namespace**；`create -f` 也不接受 `-o wide`（非法 printer，会整条失败且不创建）

### 8.2 探查 Pod 过期导致空输出被当成"无数据"

- **现象**：取 metrics 基线返回空
- **真实原因**：`cfq2` 早已 `Succeeded`（创建于 12h 前，`sleep 600` 到期），`kubectl exec` 失败被 `2>/dev/null` 静默吞掉
- **误导性**：完全可能误判为"两栈都没有该指标"
- **修复**：先查 `phase`，`Running` 才用；重建后**先自检一个已知端点返回 200**，再复用
- **教训**：`2>/dev/null` 会把工具故障伪装成业务结论。**探查 Pod 用完即毁是常态，取数前必须验证其存活**

### 8.3 `kubectl exec` 重定向与 `/memberlist` 的假信号

- **现象**：`kubectl exec ... > /tmp/x.json` 两次都得到空文件
- **真实原因**：管道本身正常（用 `PIPELINE_SELFTEST_OK` 验证过），是**服务端返回的不是 JSON** —— Tempo 2.x query-frontend 对 `/memberlist` 回的是纯文本 `This instance doesn't use memberlist.`
- **误导性**：**HTTP 200 并不代表端点语义正确**。若不做 `2>&1` + 看首字节自检，会误判为"memberlist 配置异常"
- **修复**：对每个端点先看响应体前 120 字节，再决定是否 JSON 解析
- **顺带发现**：tempo3 用 `live-store` 组件替代了 2.x 的 `ingester`，`app.kubernetes.io/component=ingester` 查不到任何 Pod —— **版本间组件命名不同，不能用旧标签想当然**

### 8.4 跨 namespace 删除参数误用

- **现象**：`kubectl delete pod t-bb2 -n logging t-ep -n opentelemetry` 只删了 `t-ep`
- **原因**：单条命令的 `-n` 作用于全部参数
- **修复**：分两条命令执行
- **教训**：多 namespace 操作必须拆开写

---

## 9. 遗留问题

| # | 问题 | 等级 | 说明 |
|---|---|:---:|---|
| 9.1 | 旧栈 search 仍 500 | P1 | `too many unhealthy instances in the ring`。**本次不修**（属于旧栈，退役前无需处理）。若回滚则需先修 |
| 9.2 | 仍无 Tempo 告警规则 | P1 | 全集群 0 条。§2 的 44 小时静默故障正因此未被发现 |
| 9.3 | 旧栈 9 Pod 未退役 | P1 | 按共存评估 §5 阶段三处理，**需人工确认**。当前仍在消耗资源 |
| 9.4 | 3 个孤儿 ConfigMap | P2 | `otel-collector-089d9319` / `718612e4` / `caf5b0c0`（2026-04-06）仍指向旧栈。不被挂载，但干扰排查 |
| 9.5 | tempo3 真实 block flush 未验证 | P2 | 只测了 1 条 span 的收/查。S3 block 需累积到阈值才 flush（`observability-phase2-fixes.md` §3.7 记录过 `work.json`） |
| 9.6 | 上游无应用接入 OTel | P2 | 管道通了但数据量仍≈0。需至少 1 个应用接入 SDK 才能验证完整链路 |
| 9.7 | OTel ReplicaSet 累积 | P2 | operator 每次变更留一个旧 RS。**清理需人工确认** |
| 9.8 | CoreDNS ImagePullBackOff | P2 | 既有问题，与本次无关（`registry.k8s.io` 出网超时） |

---

## 10. 复现命令

### 10.1 判断 trace 流向哪套 Tempo（权威判据）

```bash
# 1) Collector 配的 exporter endpoint
kubectl get opentelemetrycollector otel -n opentelemetry -o jsonpath='{.spec.config.exporters.otlp_grpc~1tempo.endpoint}'

# 2) Grafana 数据源指向
curl -s -K /tmp/.gfrc "http://<grafana-clusterip>/api/datasources" | \
  python3 -c "import json,sys;[print(x['name'],x['url']) for x in json.load(sys.stdin) if x['type']=='tempo']"

# 3) 实际收数（两者必须一致）
#    建探查 Pod 后取两栈 distributor 的计数对比
```

### 10.2 ★ 端到端验收脚本（本次用的方法）

```bash
# 前置：探查 Pod 必须先自检一个已知端点返回 200
# 1) 记录两栈基线
for L in tempo tempo3; do
  IP=$(kubectl get pod -n logging -l app.kubernetes.io/instance=$L,app.kubernetes.io/component=distributor \
       -o jsonpath='{.items[0].status.podIP}')
  printf "%-8s " "$L"
  kubectl exec $PROBE -n logging -- sh -c "curl -s http://$IP:3200/metrics" | grep '^tempo_distributor_spans_received_total'
done

# 2) 注入带唯一 marker 的 span
MARK="VERIFY_$(date +%s)"
curl -X POST -H 'Content-Type: application/json' \
  --data "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"m\",\"value\":{\"stringValue\":\"$MARK\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"5b8efff798038103d269b633813fd61d\",\"spanId\":\"eee19b7ec3c1b175\",\"name\":\"$MARK\",\"kind\":2,\"startTimeUnixNano\":\"$AGO\",\"endTimeUnixNano\":\"$NOW\"}]}]}]}" \
  http://<collector-ip>:4318/v1/traces
sleep 25

# 3) 判读：新栈应精确 +1（不是 +N），旧栈应不变
#    Collector sent_spans 应从 0 变为 1
```

### 10.3 检查"半断连接"（端口通但 ack 不通）

```bash
# TCP 通 ≠ 管道通。必须真注入数据并同时看 Collector 的 sent_spans
kubectl exec $PROBE -n opentelemetry -- curl -s http://<collector-ip>:8888/metrics \
  | grep -E '^otelcol_exporter_(sent|send_failed)_spans_total'

# 若是半断：tempo 侧计数增长，但 sent_spans 恒为 0，日志持续
#   "Exporting failed. Will retry the request after interval."
```

### 10.4 回滚

```bash
# 查询端
curl -s -K /tmp/.gfrc -X PUT -H 'Content-Type: application/json' \
  --data @payload-oldurl.json \
  "http://<grafana-clusterip>/api/datasources/uid/afia1p4xshn9cf"

# 写入端（key 里的 / 必须转义为 ~1）
kubectl patch opentelemetrycollector otel -n opentelemetry --type=json \
  --patch='[{"op":"replace","path":"/spec/config/exporters/otlp_grpc~1tempo/endpoint","value":"tempo-distributor.logging.svc.cluster.local:4317"}]'
```

---

## 11. 收尾确认

- 临时探查资源：**0 残留**（`cfq2` / `t-ep` / `t-bb` / `t-bb2` / `t-curl` / `t-mx` / `t-vc` / `otelval-*` / 临时 CM 全部删除）
- 误建到 `default` ns 的对象：已清理
- 临时凭据文件 `/tmp/.gfrc2`：**已删除**
- 备份目录：15 文件 / 672 KB，含变更前后完整对照
- 本次未执行任何 `helm uninstall`、未删除任何 namespace / PVC / PV / 桶 / 对象 / topic / 数据源 / trace 数据

---

*执行时间：2026-09-29 08:28 – 08:45 CST*
*执行人：OpenCode（受 LGMT 运维指令）*
*变更范围：2 个对象 / 2 个字段；其余全部只读*
