# 12 · SLO / 事故管理 / 告警设计面试题

> 详细证据：[17 SRE](../17-sre/10-slo-incident-alerting.md)。

## 1. SLI / SLO / SLA / Error Budget

**一句话**：SLI 是测量值，SLO 是内部目标，SLA 是对外合同，Error Budget = 1 - SLO。

**本环境**：无对外 SLA；Compassio 有 HTTP 指标，但还没正式 SLO。

## 2. 怎么选 SLI

**一句话**：选用户旅程：成功率、P99 延迟、新鲜度、吞吐/正确性；排除健康检查。

**本环境**：总请求 p99 21ms，业务 p99 219ms；健康检查占 99.93% 请求，必须排除。

## 3. SLO 该定几个 9

**一句话**：单副本/单区域先 99.9%；有 failover 演练才 99.95%；多 AZ/无单点才 99.99%。

**本环境**：backend/Redis 单副本，CNPG 2 实例但单区域 → 99.9% 最现实。

## 4. 低流量怎么定 SLO

**一句话**：7d 样本太小就拉长到 30d，或加合成拨测；否则一次失败就烧穿。

**本环境**：业务 1,948 请求/7d，99.9% 只允许 1.95 次错误/7d。

## 5. Error Budget 花完怎么办

**一句话**：提前写策略：50% 预警、100% 冻结发布，hotfix/安全例外需 IC+Owner 批准。

**本环境**：尚无正式 error budget 政策，需要补。

## 6. Burn Rate 公式

**一句话**：`burn = error_ratio / (1 - SLO)`；99.9% 时 0.1% 错误 = burn 1。

**本环境**：业务 0 个 5xx，当前 burn=0；规则要先写好。

## 7. 多窗口多燃烧率

**一句话**：1h/5m >14.4 page；6h/30m >6 page/ticket；3d/6h >1 ticket。

**本环境**：只有 apiserver 有 4 条 burn 规则；业务 0 条。

## 8. 为什么不用“阈值 + for 5m”

**一句话**：阈值抓不到低速燃烧，也容易被短尖刺触发；多窗口 burn 同时看快烧/慢烧。

**本环境**：251 条规则里 `for` 多为 5/10/15m，但没有业务 SLO burn。

## 9. 症状告警 vs 原因告警

**一句话**：只 page 用户症状（错误率/延迟/可用性）；CPU 高、内存高是 dashboard/工单。

**本环境**：`CPUThrottlingHigh` 是 info（正确）；但 5 条长期 firing 全是原因/采集问题。

## 10. 本环境最典型的坏告警

**一句话**：`absent()` 用在可能不存在的 job 上，会永久 firing。

**本环境**：`KubeProxyDown` 用 `absent(up{job="kube-proxy"})`，Cilium KPR 后 job 不存在 → 50.9h；Ceph 两条 39h。

## 11. 告警分组/抑制

**一句话**：同根因要聚合；inhibit 的 equal 不要只匹配 alertname。

**本环境**：`group_by=[alertname,namespace,severity]`；inhibit `equal=[namespace,alertname]`，Alertmanager 两条同根因告警各发一次。

## 12. 可行动性

**一句话**：每条 page 必须有 owner、runbook、dashboard、silence 入口；否则降级为工单。

**本环境**：137/251 有 runbook；114 条没有。

## 13. MTTD / MTTA / MTTR

**一句话**：MTTD 故障→发现，MTTA 发现→认领，MTTR 故障→恢复；通常 MTTD 最致命。

**本环境**：重启告警在 Pod 恢复后仍 firing 16h~1.5d；人工处置约 2h05m。

## 14. 事故角色与 SEV

**一句话**：SEV1/2 立即 page；IC 决策、Ops 执行、Scribe 记录、Comms 沟通。

**本环境**：没有正式 on-call/ack/status page，只有 Alertmanager→WeCom/n8n。

## 15. 对外沟通

**一句话**：只说我已知/正在做/下次更新时间；不猜根因、不写内部信息。

**本环境**：状态页模板已补，但未接入真实状态页。

## 16. Blameless Postmortem

**一句话**：时间线、影响量化、5 Whys、行动项 owner+截止日；不评价个人。

**本环境**：CNPG/Ceph 事故有详细过程记录，但行动项 owner/截止日不完整。

## 17. 变更与故障相关性

**一句话**：80% 是行业经验值；要用 deploy marker + 变更后 30–60 分钟指标做相关性。

**本环境**：7 轮改造中 3 轮直接触发故障（CNPG、Grafana Operator、监控存储），另有 kube-proxy 升级导致监控缺口。

## 18. 怎么做变更相关性分析

**一句话**：把 ArgoCD sync/Git commit 打到 Grafana，比较变更组/非变更组的错误率、p99、burn。

**本环境**：目前没有 deploy marker，ArgoCD 历史是唯一时间参考。

## 19. 当前最大缺口

**一句话**：业务没有 SLO burn、5 条长期误报、无 blackbox、无 on-call/status page、114 条无 runbook。

**本环境**：优先做 Compassio 99.9% + burn、清理 stale alerts、补拨测。

## 20. 30 秒总回答

```text
SLI 选用户旅程：成功率、p99、新鲜度；排除健康检查。
SLO 先定 99.9%，单副本/单区域不要承诺 99.99%。
Error Budget = 1-SLO，花完冻结发布。

告警只对症状，不对原因；CPU 高不 page，错误率/延迟才 page。
用多窗口 burn rate：1h/5m 14.4、6h/30m 6、3d/6h 1。
一次事故只产生一条可行动告警；同根因聚合/抑制。

事故：SEV + IC/Scribe/Comms；MTTD 通常比 MTTR 更致命。
Postmortem：时间线、影响量化、5 Whys、行动项 owner+截止日。
变更：80% 故障来自变更（经验值），用 deploy marker 做相关性。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| SLI | 用户旅程的成功率/延迟/新鲜度 |
| SLO | 内部目标，先 99.9% |
| SLA | 对外合同 |
| Error Budget | 1-SLO，花完冻结 |
| 排除健康检查 | 总 p99 21ms vs 业务 219ms |
| Burn | error_ratio / (1-SLO) |
| 多窗口 | 1h/5m、6h/30m、3d/6h |
| 症状告警 | 错误率/延迟，不是 CPU |
| 坏告警 | absent() 永久 firing |
| 分组/抑制 | 同根因聚合，equal 别只放 alertname |
| 可行动 | owner + runbook + dashboard |
| MTTD | 通常比 MTTR 更致命 |
| SEV | 1/2 page，3/4 工单 |
| Postmortem | 时间线/影响/5 Whys/行动项 |
| 变更 | 80% 经验值，deploy marker 分析 |
