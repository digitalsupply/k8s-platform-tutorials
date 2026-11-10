# Grafana Traces 无内容 —— 根因分析

> **结论先行：Tempo 里有数据，Grafana 查不到是因为「时间范围」和「标签」两处不匹配，不是链路故障。**
> 我此前几轮报告里说的「Tempo 完全空转」「零个 trace block」是**错的** —— 实际有 3 个真实 Parquet block、至少 6 条 trace。

---

## 一、现象与验证

| 检查 | 结果 |
|---|---|
| Grafana Explore 选 Tempo | 空白 |
| Grafana API `/api/search/tags` | `{"tagNames":[],"metrics":{}}` |
| Tempo query-frontend `/api/search?limit=10`（默认最近时段） | `{"traces":[],"metrics":{"completedJobs":3,"totalJobs":3}}` |
| **Tempo `/api/search?start=09-28 10:00&end=09-29 02:00`** | ✅ **返回 trace** |
| S3 `tempo-traces` bucket | **3 个 block，各含 `data.parquet`（~29 KB）** |
| block 元数据 | `totalRecords: 1`（每 block 1 条记录） |

**关键证据 —— 指定历史时间窗就能查到：**
```json
{"traces":[
  {"traceID":"5b8efff798038103d269b633813fd62f",
   "rootServiceName":"retire-probe",
   "rootTraceName":"POST_RETIRE2_1790646071",
   "durationMs":3600000},
  {"traceID":"5b8efff798038103d269b633813fd61d",
   "rootServiceName":"cutover-probe",
   "rootTraceName":"CUTOVER_POST_1790641890",
   "durationMs":3600000},
  ...
]}
```

---

## 二、根因（三层，逐层叠加）

### 根因 1：数据很旧，已接近/超过保留窗口 —— 主因

| Block | 时间范围 (UTC) | 距今 |
|---|---|---|
| `ffb96215-...` | 2026-09-28 10:52:28 ~ 10:52:30 | **约 3.7 天** |
| `b1fc56f5-...` | 2026-09-29 00:29:40 ~ 00:31:30 | **约 3.1 天** |
| `389d6f4b-...` | 2026-09-29 01:39:20 ~ 01:41:11 | **约 3.1 天** |

当前时间：**2026-10-02 04:09 UTC**

Tempo 配置的 `block_retention: 48h`（2 天）——**这些 block 已接近或超过保留期**。

Grafana Explore 默认查询「最近 1 小时」，自然一无所获。**必须把时间范围调到 09-28 ~ 09-29 才能看到。**

> 附注：block 尚未被删除，说明 compactor 尚未清理（或清理周期未到），但它们已处在保留窗口边缘，随时会消失。

### 根因 2：数据量太小，被「空结果」掩盖

每个 block `totalRecords: 1`，3 个 block = **约 3 条 trace**。这个量级下：
- Grafana 的 `tagNames` 需要足够样本才能建立标签索引
- 3 条记录的标签集极稀疏，`api/search/tags` 返回空数组是**正常行为**，不代表没有数据

所以「标签列表为空」和「没有 trace」是两回事，我之前把前者当成了后者。

### 根因 3：数据源不是业务应用 —— 探测流量

服务名暴露了来源：
```
retire-probe    POST_RETIRE2_1790646071
cutover-probe   CUTOVER_POST_1790641890
```

配合 otel-collector 日志：
```
2026-09-29T00:31:39  Traces  {"resource spans": 1, "spans": 1}
2026-09-29T01:41:20  Traces  {"resource spans": 1, "spans": 1}
```

**这是探针/自检脚本发出的 span，不是业务应用的链路追踪。** 整个 collector 生命周期内**只收到过 2 个 span 批次**（09-29 之后 3 天无任何新流量）。

原因：全集群扫描确认——
```
❌ 无任何 Pod 注入 OTEL_EXPORTER_OTLP_ENDPOINT 环境变量
❌ 无任何业务 Pod 声明 4317/4318 端口
✅ 仅 otel-collector 与 tempo3-distributor 自身
```

**没有任何应用接入 OTLP。** Tempo 是空转的接收端。

---

## 三、链路健康度：其实是好的

| 组件 | 状态 | 说明 |
|---|---|---|
| tempo3-distributor | ✅ Running 0 重启 | 正常收 OTLP |
| otel-collector | ✅ Running | traces 管道配置正确（`otlp → batch → otlp_grpc/tempo`） |
| Kafka `tempo-traces` | ✅ 正常 | 3 partition |
| tempo3-live-store ×3 | ✅ Running | 消费正常 |
| tempo3-block-builder ×3 | ✅ Running | **确实产出过 block** |
| tempo3-querier / query-frontend | ✅ Running | 查询正常（指定时间窗可返回数据） |
| Grafana Tempo 数据源 | ✅ 健康检查 OK | 代理查询正常 |

**整条链路是通的**。问题只在于「没有持续输入」+「数据太旧」。

---

## 四、我要更正此前的错误结论

| 此前报告的表述 | 实际情况 |
|---|---|
| 「tempo-traces 桶只有 393 KiB / 16 objects，**零个 trace block**」 | ❌ 错。有 3 个真实 block，各含 `data.parquet`（29 KB）+ `bloom-0`（102 KB）+ `index` + `meta.json` |
| 「Tempo 全链路空转」「从未有真实 trace 流入」 | ❌ 部分错。有 2 批探测流量流入（09-29），确实**无业务流量** |
| 「Grafana 查询 `tagNames:[]` 证明无数据」 | ❌ 错。数据量过小导致标签索引为空，指定时间窗可查到 trace |
| 「Tempo 是 11 个组件的纯成本，产出为零」 | ❌ 错。产出过 3 个 block / 3 条 trace |

**为什么会判断错**：我最初只查了 `aws s3 ls` 的汇总输出（16 objects / 402 KB），看到「都是元数据文件」就下了结论，**没有逐个检查对象的文件名**。实际上 `data.parquet` 才是真正的数据文件，而它就在那 16 个对象里。

---

## 五、如何在 Grafana 里看到这些数据

**方法：调整时间范围**

1. Grafana → Explore → 数据源选 **Tempo**
2. **时间选择器**从「Last 1 hour」改为：
   - 绝对时间：`2026-09-28 10:00` ~ `2026-09-29 02:00`（UTC）
   - 或自定义 range，注意时区
3. 查询：
   ```promql
   {rootServiceName="retire-probe"}
   {rootServiceName="cutover-probe"}
   ```
   或 Search → 标签选择器留空直接搜

也可以直接调 API 验证：
```bash
# 集群内任意 Pod
curl "http://tempo3-query-frontend.logging.svc.cluster.local:3200/api/search?start=1790589600&end=1790736000&limit=20"
# start/end 为 Unix 秒
```

⚠️ **注意**：这些 block 已接近 48h 保留期，随时可能被 compactor 删除。查不到属于正常。

---

## 六、真正的建议：要让 Traces 有意义，需要接入业务

现在这套 T 层是「通路已备、无人使用」。要让 Grafana Traces 真正有内容，必须有应用发送 OTLP。两条路：

### 方案 A：给现有应用加 OpenTelemetry 自动埋点（推荐）

对 `default` / `shop` / `kafka` 等业务应用（若它们是 Java/Go/Node 应用）：

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.opentelemetry.svc.cluster.local:4318"
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  - name: OTEL_SERVICE_NAME
    value: "my-app"
```
多数框架（Spring Boot / Express / Gin）配合对应 OTel SDK 即可自动埋点。

### 方案 B：部署一个演示应用，验证链路闭环

当前 collector 里的 `otel_demo` / `OtelDemoServiceDown` 规则暗示曾计划做 demo。可以用一个最小 OTLP 示例应用（如 `telemetrygen`）产生持续流量：

```yaml
# 验证用，几秒就能跑起来
containers:
  - name: telemetrygen
    image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
    args: ["--config=/etc/telemetrygen/config.yaml"]
```

**目的**：先证明「Grafana ↔ Tempo ↔ otel-collector ↔ Kafka ↔ S3」全链路闭环，再接入真实业务。

---

## 七、其他需要修的问题

| # | 问题 | 影响 | 建议 |
|---|---|---|---|
| 1 | **block_retention 48h 太短** | 数据 2 天就没，而 Prometheus 5d、Loki 7d，三层窗口不匹配 | 统一到 5d（我在 retention 报告里已提过，此处再强调） |
| 2 | **Tempo 组件无持久化** | live-store ×3、block-builder ×3、distributor 全挂 emptyDir，**节点重启即丢热数据和 WAL** | 加 PVC（`ceph-rbd-sc`） |
| 3 | **20 条 tempo3-alerts 中 18 条永不触发** | 标签维度错配（我此前已修 2 条核心的） | 其余需逐条核对 |
| 4 | **无业务接入监控** | T 层无法产生价值 | 见方案 A/B |

---

## 八、验证命令速查

```bash
# ① 查最近时段（通常为空）
kubectl exec -n logging tempo3-query-frontend-7b7fc8ddf8-852sz -c tempo-query-frontend -- \
  wget -qO- 'http://localhost:3200/api/search?limit=10'

# ② 查历史时段（能看到数据）
kubectl exec -n logging tempo3-query-frontend-7b7fc8ddf8-852sz -c tempo-query-frontend -- \
  wget -qO- 'http://localhost:3200/api/search?start=1790589600&end=1790736000&limit=20'

# ③ 看 block 到底有没有数据文件（关键！不要只看汇总）
export AWS_ACCESS_KEY_ID=AS5W8GVA3QVGYJ65NM2M
export AWS_SECRET_ACCESS_KEY=<redacted>
export AWS_DEFAULT_REGION=us-east-1
aws s3 ls --endpoint-url http://10.0.0.31:7480 s3://tempo-traces/ --recursive

# ④ 看 block 元数据（totalRecords 才知道有几条 trace）
aws s3 cp --endpoint-url http://10.0.0.31:7480 \
  s3://tempo-traces/single-tenant/389d6f4b-e844-5eeb-8675-082e15721282/meta.json - | python3 -m json.tool

# ⑤ 确认有无业务在发 OTLP
kubectl get pods -A -o json | jq -r '.items[].spec.containers[]?.env[]? | select(.name|test("OTEL")) | .name'

# ⑥ collector 收到过多少 span
kubectl logs -n opentelemetry otel-collector-985847d99-2rgrk -c otc-container | grep -c '"spans":'
```

---

*分析时间：2026-10-02 04:00~04:30。核心发现：Tempo 中存在 3 个真实 block（约 3 条 trace，服务名 `retire-probe`/`cutover-probe`，时间 09-28~09-29），Grafana 查不到是因为默认时间范围（最近 1 小时）不覆盖该时段。此前提出的「Tempo 完全空转、零个 trace block」结论不成立。*
