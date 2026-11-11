# 09 · 可观测性工程面试题

> 详细证据：[04 可观测性工程](../04-monitoring-gitops/10-observability-engineering.md)。

## 1. 指标类型

**一句话**：Counter 只增、Gauge 可增可减、Histogram 分桶、Summary 客户端分位。

**本环境**：`compassio_http_requests_total` 是 counter；`compassio_users_total` 名字像 counter，实际是 gauge（按 role 只有 3 series）。

## 2. 基数为什么烧内存

**一句话**：series = 指标名 × 各 label 取值数的笛卡尔积，每条 series 约占 1–6KB 内存。

**本环境**：26 万 series，RSS 1.57GiB/4GiB，约 6KB/series。

## 3. 为什么不能把 user_id 放 label

**一句话**：100k 用户 × 100 路径 × 5 状态 = 5000 万 series，直接打爆内存；用户维度应放日志/trace/exemplar。

**本环境**：`compassio_users_total` 只用 `role`（3 series），不按用户展开。

## 4. 基数打爆内存的真实证据

**一句话**：15 万合成 series + 128Mi limit，Prometheus 3.11.2 在 30–90 秒内 OOMKilled。

**本环境**：`Reason: OOMKilled`、`Exit Code: 137`、重启 3 次；GOMEMLIMIT 自动压到 115Mi 仍不够。

## 5. 高基数治理

**一句话**：指标评审 + label 白名单 + 应用侧聚合 + relabel drop + series 预算。

**本环境**：apiserver 占 12.8 万 series（49%）；`id`/`uid`/`container_id`/`path` 是主要高基数 label；24h series +13.5%。

## 6. `rate()` 为什么要 2 个样本

**一句话**：range 窗口内至少 2 个样本才能算斜率；30s 抓取至少用 `[2m]`，常用 `[5m]`。

**本环境**：`rate(...[10s])`、`[30s]` 都是 0 series，`[1m]` 才有 6 条。

## 7. `irate` vs `rate`

**一句话**：`rate` 用整个窗口平滑；`irate` 只用最后两个样本，灵敏但抖。

**本环境**：idle CPU `irate=0.856`、`rate=0.877`；SLO/画图用 `rate`，瞬时告警才用 `irate`。

## 8. 聚合前先 `sum by`

**一句话**：先按维度聚合再算比率/分位数，不能先 `avg` 每个实例的比率。

**本环境**：`sum by (verb)(rate(apiserver_request_total[5m]))` 得到 9 条；全局 `sum(rate(...))` = 28.6/s。

## 9. `histogram_quantile` 的坑

**一句话**：必须先 `sum by (le)`；否则每个 label 组合各算一条，大量 NaN。

**本环境**：不聚合返回 188 条、122 条 NaN；`sum by (le)` 后 1 条、p99=0.0229s。

## 10. bucket 怎么选

**一句话**：必须有 `+Inf`，桶要覆盖 SLO 边界；桶太少只能插值，p99 会失真。

**本环境**：apiserver 10 个桶（0.005–60s），0.1 到 1s 跨度过大，200ms SLO 精度有限。

## 11. 黑盒 vs 白盒

**一句话**：黑盒看“用户能不能用”，白盒看“内部为什么慢/错”。

**本环境**：白盒 52 job（27 SM + 16 PM）；黑盒 0 Probe、无 blackbox exporter，是明显缺口。

## 12. 分层监控

**一句话**：基础设施 → 中间件 → 应用 → 业务，每层都要有 SLI，不要只盯 CPU。

**本环境**：node/kubelet/apiserver/etcd；CNPG/Kafka/Traefik/Ceph；compassio/deeptutor；`compassio_users_total`、LLM 请求数、DeepTutor 轮次。

## 13. 结构化日志与采样

**一句话**：应用输出 JSON；Loki label 只放低基数维度；错误 100%、普通日志采样。

**本环境**：Alloy `stage.json=0`、`sampling=0`，只有 CRI 剥离和 120h 丢弃；Loki 0.6GB/天。

## 14. `/var/log` 生命周期

**一句话**：容器日志由 kubelet 轮转（默认 10Mi×5），宿主机日志才归 logrotate。

**本环境**：kubelet 未显式配置 → 默认 10Mi×5；worker01 14 个轮转文件、最大约 10.5MB；logrotate weekly×4、journald 20.4M。

## 15. Trace context 传播

**一句话**：入口生成/透传 `traceparent`，服务用 OTel SDK 提取并注入到出站 HTTP/gRPC/消息。

**本环境**：OTel Collector 0.145.0 接收 OTLP、batch 后发 Tempo；日志需带 `trace_id` 才能跳转。

## 16. 头部采样 vs 尾部采样

**一句话**：头部在入口决定，简单但可能丢错误 trace；尾部收完整 trace 后按错误/延迟决定，贵但准。

**本环境**：没有配置任何采样，入口全收；当前 6.8 万 span/天量小，放量后必须加尾部采样。

## 17. OTel 统一 SDK

**一句话**：用 OpenTelemetry SDK 统一 metrics/logs/traces，Collector 做批处理、采样、导出，避免厂商绑定。

**本环境**：Collector 只有 batch，无 memory_limiter/tail_sampling；spanmetrics 当前 0 series，`OtelDemoHighErrorRate` 永不触发。

## 18. Thanos / VictoriaMetrics / Mimir

**一句话**：Thanos 适合已有 Prometheus 长期化；VM 简单高压缩；Mimir 强在多租户/大规模。

**本环境**：都没有部署，Prometheus 本地 15d/25GiB，26 万 series 还没到必须上长期存储的规模。

## 19. 可观测性成本治理

**一句话**：成本 = series × 维度 × 采样率 × 保留时间；最贵的通常不是日志，是高基数指标。

**本环境**：指标 17.9GB/15d，日志仅 0.6GB/天；100 万 series ≈ 6GB 内存 + 67GB 磁盘。

## 20. 告警分层

**一句话**：症状告警优先（错误率/延迟/可用性），原因告警用于定位，容量/证书做预警。

**本环境**：251 条 alerting；有业务告警（Compassio/DeepTutor），但存在引用 0 series 的失效规则。

## 一句话总表

| 题 | 一句话 |
|---|---|
| 指标类型 | Counter/Gauge/Histogram/Summary |
| 基数 | label 笛卡尔积，1 series ≈ 1–6KB |
| user_id | 不能进 label，放日志/trace |
| OOM | 15 万 series + 128Mi → OOMKilled |
| 治理 | 白名单 + 聚合 + drop + 预算 |
| rate | 至少 2 样本，窗口 ≥ 4×scrape |
| irate | 最后 2 样本，灵敏但抖 |
| 聚合 | 先 sum by 再比率/分位 |
| histogram | 必须 sum by (le) + +Inf |
| 黑盒/白盒 | 可用性 vs 内部原因 |
| 分层 | 基础设施/中间件/应用/业务 |
| 日志 | JSON + 采样 + 低基数 label |
| 轮转 | kubelet 10Mi×5；logrotate 管宿主机 |
| Trace | traceparent 传播 + OTel SDK |
| 采样 | 头部简单；尾部按错误/延迟 |
| 长期存储 | Thanos/VM/Mimir 按规模选 |
| 成本 | series × 维度 × 采样 × 保留 |
| 告警 | 症状优先，原因定位 |
