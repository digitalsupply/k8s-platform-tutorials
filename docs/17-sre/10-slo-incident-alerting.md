# 10 · SLO / 事故管理 / 告警设计：SRE 的灵魂

> 技术上不难，难在**把“资源指标”换成“用户症状”**，并且让告警、事故流程、变更管理闭环。
>
> 本章基于本集群实测（2026-11-11）：
> 251 条告警规则、7 条 firing（5 条非 Watchdog）、Alertmanager 双出口、
> Compassio 7 天 9,370 万请求（其中 99.93% 是健康检查）、业务 p99 219ms。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)。
> 一句话版本：[15 面试速查 12-sre](../15-interview-cheatsheet/12-sre.md)。

## 1. 本环境现状：告警很多，SLO 很少

```text
告警规则       251 条（critical 82 / warning 160 / info 7 / none 2）
有 runbook     137 条（54.6%）
无 for          10 条
SLO/burn 规则   5 条，其中 4 条是 kube-apiserver，业务 SLO 为 0
当前 firing     7 条，其中 5 条非 Watchdog，最长 50.9 小时
Alertmanager    group_wait 30s / group_interval 5m / repeat 12h
                双出口 n8n + wecom，inhibit 4 条
```

这就是本章要解决的问题：

> **不是把告警数量压下去，而是把告警从“资源指标”迁到“SLO 燃烧率”，
> 让一次事故只产生一条可行动告警。**

## 2. SLI / SLO / SLA / Error Budget

### 2.1 四个概念

| 概念 | 定义 | 本环境 |
|---|---|---|
| SLI | 实际测量的指标：成功率、延迟、新鲜度 | `compassio_http_requests_total`、`*_duration_seconds_bucket` |
| SLO | 内部目标，如 99.9% 成功、p99 < 300ms | 尚未正式定义 |
| SLA | 对外合同，含赔偿条款 | 无对外 SLA |
| Error Budget | `1 - SLO`，可接受的失败量 | 99.9% → 0.1% |

关系：

```text
SLA 是对客户的承诺（通常比 SLO 松）
SLO 是内部目标（比 SLA 紧）
SLI 是测量值
Error Budget = 1 - SLO
```

### 2.2 选 SLI：先排除健康检查

本环境 Compassio 7 天数据：

```text
总请求           93,698,918
健康检查+/metrics 93,631,932（99.929%）
业务路由          1,948（0.0021%）
```

如果直接拿总请求算 SLO：

- 99.9% 预算 = 93,699 次错误，几乎不可能触发；
- p99 = 21ms，看起来很好；
- 实际业务 p99 = **219ms**，差 10 倍。

原因：`/api/health`、`/api/health/live`、`/metrics` 把请求量和延迟都稀释了。
**SLI 必须只统计用户旅程**：

```promql
# 成功率的错误数
sum(rate(compassio_http_requests_total{
  route!~"/api/health.*|/metrics",
  status=~"5.."
}[5m]))

# 业务 p99
histogram_quantile(0.99,
  sum by (le) (rate(compassio_http_request_duration_seconds_bucket{
    route!~"/api/health.*|/metrics"
  }[5m])))
```

本环境真实业务路由：

```text
/api/notify/unread-count   717/7d
/api/notify/list           569/7d
/api/assess/{id}/answer    203/7d
/api/assess/{id}/next      174/7d
```

### 2.3 选几个 9

| SLO | 月停机 | 7d 允许错误（业务 1,948） | 30d 允许错误 | 适用 |
|---|---:|---:|---:|---|
| 99.9% | 43m | 1.95 | 8.35 | 单副本/单区域，当前最现实 |
| 99.95% | 21.6m | 0.97 | 4.17 | 有自动 failover 且演练过 |
| 99.99% | 4.3m | 0.19 | 0.83 | 多副本/多 AZ/无单点 |

本环境：

- Compassio backend **1 副本**；
- Redis **1 副本**；
- CNPG 2 实例但单集群、单区域；
- 入口/监控也有单点。

所以：

- **99.9% 是现实目标**；
- 99.95% 需要先证明 failover/回滚能在 1 分钟内完成；
- 99.99% 在没有多 AZ、没有 Redis HA 前不要承诺。

### 2.4 低流量 SLO 的陷阱

业务 7 天只有 1,948 次请求：

- 99.9% 只允许 **1.95 次错误/7d**；
- 一次发布故障就可能烧穿；
- 7d 窗口样本太小，建议用 **30d** 或 **合成拨测**（blackbox）补齐；
- 本环境目前 **0 个 Probe / 无 blackbox**，所以只能靠业务指标，低流量下不灵敏。

### 2.5 Error Budget 花完怎么办

策略要提前写死，而不是事后争论：

| 燃烧比例 | 动作 |
|---|---|
| > 50% | 预警，排期治理，减少非必要变更 |
| 100% | **冻结发布**（hotfix/安全例外需 IC + Owner 批准） |
| 连续两个窗口超 | 进入可靠性专项，暂停新功能 |
| 预算充足 | 可以加快发布，但保留回滚 |

> Error Budget 不是“允许故障”，而是“用可接受的故障换取发布速度”的预算。

## 3. 燃烧率告警（Burn Rate）

### 3.1 公式

```text
error_ratio = errors / total
burn_rate   = error_ratio / (1 - SLO)
```

SLO 99.9% 时：

- error_ratio = 0.1% → burn = 1（30 天正好烧完）；
- burn 14.4 → 1 小时烧掉 2% 月预算；
- burn 6 → 6 小时烧掉 5%；
- burn 1 → 3 天烧掉 10%。

### 3.2 多窗口多燃烧率

| 窗口 | 短窗口 | 阈值 | 动作 |
|---|---|---|---|
| 1h | 5m | 14.4 | page（快烧） |
| 6h | 30m | 6 | page/ticket（中烧） |
| 3d | 6h | 1 | ticket（慢烧） |

为什么用两个窗口：长窗口看趋势，短窗口防“已经恢复的历史尖刺”继续 page。
`and` 保证两个窗口同时超阈值才触发。

### 3.3 本环境业务 SLO 查询

当前 7 天 0 个 5xx、0 个 4xx，所以 burn = 0：

```text
burn_rate(1h) = 0
burn_rate(5m) = 0
```

但规则要提前写好。示例见
[`assets/slo/compassio-slo-rules.yaml`](assets/slo/compassio-slo-rules.yaml)：

```promql
compassio:slo_burn_rate:1h > 14.4
and
compassio:slo_burn_rate:5m > 14.4
```

### 3.4 现有规则：只有 apiserver

本环境 5 条 SLO/burn 规则里，4 条是 kube-apiserver：

```text
KubeAPIErrorBudgetBurn  1h/5m  > 14.4 * 0.01
KubeAPIErrorBudgetBurn  6h/30m > 6.00 * 0.01
KubeAPIErrorBudgetBurn  1d/2h  > 3.00 * 0.01
KubeAPIErrorBudgetBurn  3d/6h  > 1.00 * 0.01
```

业务侧没有 burn rate 告警，这是当前最大的告警设计缺口。

## 4. 告警设计：只对症状告警

### 4.1 症状 vs 原因

| 类型 | 例子 | 是否 page |
|---|---|---|
| 症状（用户视角） | 错误率上升、p99 超 SLO、可用性下降 | ✅ |
| 原因（组件视角） | CPU 高、内存高、GC 频繁、磁盘 80% | ❌（dashboard/ticket） |
| 死信/缺失 | 指标不存在、target down | ⚠️ 先修采集，不要直接 page |

**CPU 高不是告警理由**；“用户请求失败率上升”才是。

本环境 `CPUThrottlingHigh` 是 `info`，不 page，这是对的；但仍有大量 critical 资源/组件告警。

### 4.2 真实告警卫生问题

当前 7 条 firing：

| 告警 | 级别 | 持续 | 问题 |
|---|---|---:|---|
| `KubeProxyDown` | critical | **50.9h** | Cilium KPR 替代 kube-proxy，`up{job="kube-proxy"}` 0 series，`absent()` 恒真 |
| `CephClusterHealthUnknown` | critical | 39.0h | `ceph_health_status` 0 series，采集缺口，不是用户故障 |
| `CephMGRMetricsMissing` | critical | 39.0h | `up{job="ceph-mgr"}=1`，但 `ceph_mon_quorum_status` 缺失 |
| `AlertmanagerClusterFailedToSendAlerts` | critical | 39.0h | 与下一条同一 webhook 根因 |
| `AlertmanagerFailedToSendAlerts` | warning | 2.0h | 同一根因的实例级告警 |
| `Watchdog` | none | 39h | dead-man，预期 |
| `InfoInhibitor` | none | 5.8m | info 抑制器，预期 |

结论：

- **5 条非 Watchdog 告警里，没有一条是用户业务症状**；
- `absent()` 用在“可能不存在”的 job 上，会永久误报；
- 同一根因产生两条通知，因为 `group_by` 含 `alertname`，inhibit 只匹配同 `alertname`。

### 4.3 本环境规则画像

```text
251 条 alerting：
  critical 82 / warning 160 / info 7 / none 2
  for: 5m 72、10m 51、15m 74、1h 14、无 for 10
  runbook: 137/251
  粗略分类：error 26、latency 19、availability 61、resource 28、workload 29、other 88
```

问题：

- 82 条 critical 太多，真正需要立刻 page 的没那么多；
- 114 条没有 runbook；
- 10 条没有 `for`（除 Watchdog/InfoInhibitor 外要逐个确认）；
- 只有 apiserver 有 burn rate，业务没有；
- 资源类告警和症状类告警混在一起。

### 4.4 Alertmanager 配置

```text
group_by       = [alertname, namespace, severity]
group_wait     = 30s
group_interval = 5m
repeat_interval= 12h
routes         = n8n-webhook + wecom（continue=true）
inhibit        = critical 抑制同 namespace+alertname 的 warning/info
                 warning 抑制同 namespace+alertname 的 info
```

优点：

- 双出口，避免单通道；
- 有基本抑制；
- group_wait 30s 能聚合同一批告警。

不足：

- `group_by` 含 `alertname`，同根因不同名字的告警不会聚合；
- inhibit 的 `equal` 含 `alertname`，只抑制同名；
- 没有 on-call/ack/升级链路，MTTA 无法度量；
- 没有 status page/事故机器人。

### 4.5 告警设计检查清单

```text
[ ] 这条告警对应哪个用户症状/SLO？
[ ] 值班看到后能做什么？runbook 在哪？
[ ] 是否可自愈？是否用窗口计数而不是累计值？
[ ] 是否会被 absent() 永久触发？
[ ] 是否和别的告警同根因？能否 inhibition/聚合？
[ ] 级别是否正确？critical 是否真的需要半夜叫人？
[ ] 是否有 owner、dashboard、silence 入口？
```

### 4.6 “一次事故一条告警”

目标不是“告警越少越好”，而是：

- 一次用户可见事故 → 一条 SLO burn 告警；
- 组件原因 → dashboard/工单，不 page；
- 同根因多告警 → 聚合/抑制；
- 告警名称直接说用户影响，例如：

```text
CompassioErrorBudgetFastBurn
CompassioLatencySLOBreach
```

而不是：

```text
NodeCPUHigh
CephMGRMetricsMissing
KubeProxyDown
```

## 5. 事故管理

### 5.1 SEV 分级

| 级别 | 定义 | 响应 |
|---|---|---|
| SEV1 | 全站不可用、数据丢失/泄露 | 立即 page IC，5 分钟 war room，15 分钟对外 |
| SEV2 | 核心功能部分不可用、SLO 快速燃烧 | 立即 page，30 分钟定位/回滚 |
| SEV3 | 非核心降级、单组件异常 | 工作时间处理，工单 |
| SEV4 | 外观/文档 | 排期 |

完整模板：[`assets/templates/sev-matrix.md`](assets/templates/sev-matrix.md)。

### 5.2 角色

```text
IC（Incident Commander）：决策/分工/节奏，不亲自 debug
Ops Lead：执行回滚/扩容/切流
Scribe：时间线、命令、决策、影响
Comms：状态页、对内/对外沟通
SME：DB/网络/存储专家，按需加入
```

本环境目前 **没有正式 IC/on-call/status page**，只有 Alertmanager → WeCom/n8n。
这是流程缺口，不是工具越多越好。

### 5.3 MTTD / MTTA / MTTR

| 指标 | 定义 | 本环境 |
|---|---|---|
| MTTD | 故障开始 → 发现 | 案例 A ≥16h/1.5d（告警一直 firing 但没人有效处理） |
| MTTA | 发现 → 认领 | 无 ack 工具，无法量化 |
| MTTR | 故障开始 → 服务恢复 | 案例 A 人工处置约 2h05m |

真正的瓶颈通常是 **MTTD**，不是 MTTR。  
告警不可信/不可行动，会让 MTTD 无限大。

### 5.4 真实案例 A：重启告警长期不恢复

```text
10-05 22:31  37 个工作负载重建，Kafka 晚就绪，Tempo 组件崩 4-5 次
10-06 15:31  DNS 抖动 + liveness 路径错误，repo-server 12 次重启
10-07 07:35  第一轮人工处置
10-07 09:40  第二轮定位真根因并闭环
```

告警 `KubePodHighRestartCount`/`Tempo3PodCrashLooping` 在 Pod 恢复后仍 FIRING **16h~1.5 天**：

- 根因 1：规则用累计 `restarts_total`，不回退；
- 根因 2：liveness `/metrics/healthz?full=true` 在 ArgoCD v3.2.4 无条件 404；
- 根因 3：kube-proxy metrics bind 0.0.0.1；
- 根因 4：Loki 规则 job 名少了 namespace 前缀，`absent()` 恒真。

完整时间线：[`assets/evidence/incident-cases.md`](assets/evidence/incident-cases.md)。

### 5.5 真实案例 B：存储迁移触发 Ceph full

```text
变更：监控 NFS -> Ceph RBD
触发：3 副本放大 + 孤儿 RBD + 单 OSD full -> MAX AVAIL=0
影响：Prom/AM/Grafana FailedMount；worker02 D 状态；CNPG failover；Grafana/ArgoCD Degraded
恢复：删除 6 个孤儿镜像 -> HEALTH_OK；CNPG 2/2
```

这是“80% 故障来自变更”的典型样本：  
变更前没有算清副本放大、`MAX AVAIL`、孤儿镜像和 30% 余量。

### 5.6 对外沟通/状态页

模板：[`assets/templates/status-page.md`](assets/templates/status-page.md)。

原则：

- 只说我已知/正在做/下次更新时间；
- 不猜根因；
- 不写内部 IP/Token/个人；
- 恢复后 24h 内给最终说明。

## 6. Postmortem：Blameless

模板：[`assets/templates/postmortem.md`](assets/templates/postmortem.md)。

必备：

1. **时间线**：开始/检测/响应/恢复，UTC+8；
2. **影响面量化**：用户数、失败请求、SLO 预算、数据丢失；
3. **5 Whys**：技术根因 + 流程根因；
4. **行动项**：Owner + 截止日 + 类型（防发生/防扩散/防再发）；
5. **做对了什么/运气好**：避免只写“下次注意”。

反例：

```text
❌ “加强监控”
❌ “提高意识”
❌ “以后小心”
```

正例：

```text
✅ 给 Compassio 加 99.9% SLO + 1h/5m burn alert，Owner=@sre，截止=11-20
✅ 迁移前检查 MAX AVAIL >= 30%，Owner=@storage，截止=11-15
```

## 7. 变更管理

### 7.1 变更前

```text
[ ] 变更范围/影响面/回滚预案
[ ] 灰度/金丝雀/蓝绿
[ ] 数据库 expand-contract
[ ] 监控看板 + SLO burn 告警已就绪
[ ] 变更窗口 + 值班 + 通知
[ ] 回滚演练（1 分钟内）
```

### 7.2 变更与故障相关性

本仓库 7 轮改造：

| 轮次 | 变更 | 结果 |
|---|---|---|
| 1 | CNPG 升级 | rp_filter webhook 超时 + 主库重启 3min |
| 4 | Grafana Operator | 403/400/连接拒绝 |
| 7 | 监控存储迁移 | Ceph full + worker02 I/O 卡死 + CNPG failover |
| 额外 | kube-proxy 升级 | metrics 全 0，KubeProxyDown 长期误报 |
| 2/3/5/6 | 盘点/Sealed Secrets/Vault | 无用户故障或只分析 |

样本中：7 轮改造有 **3 轮**（CNPG、Grafana Operator、监控存储）直接触发故障/退化，
另有 kube-proxy 升级导致监控缺口；合计 4 次变更相关事件（3/7 = 43%）。
“80% 故障来自变更”是行业经验值，本样本不足以证明精确比例，但方向一致。

### 7.3 怎么做相关性分析

- 在 Prometheus/Grafana 打 deploy marker（ArgoCD sync / Git commit / Helm release）；
- 统计变更后 30–60 分钟内的错误率、p99、burn rate；
- 对比变更组 vs 非变更组；
- 把“变更后 1 小时内的告警”自动关联到变更单；
- 每次 SEV1/2 postmortem 必须标注“是否变更触发”。

## 8. 当前缺口与优先级

| 优先级 | 缺口 | 建议 |
|---|---|---|
| P0 | 业务无 SLO/burn 告警 | 上 Compassio 99.9% + 1h/5m、6h/30m、3d/6h |
| P0 | 5 条长期 firing 的非症状告警 | 删 `KubeProxyDown`；修 Ceph exporter；合并 Alertmanager 两条 |
| P1 | 无 blackbox/Probe | 加域名/TLS/关键 API 拨测，补低流量 SLO |
| P1 | 无 on-call/ack/status page | 接入 PagerDuty/企微机器人 + 状态页 |
| P1 | 114 条无 runbook | 先补 critical，再补 warning |
| P2 | 82 条 critical 过多 | 按 SEV 重新分级，资源类降为 ticket |
| P2 | 无变更 marker/相关性 | ArgoCD sync + Prometheus deploy marker |

## 9. 一页命令

```bash
# SLO 查询（业务路由，排除健康检查）
sum(rate(compassio_http_requests_total{
  route!~"/api/health.*|/metrics", status=~"5.."}[5m]))
/
sum(rate(compassio_http_requests_total{
  route!~"/api/health.*|/metrics"}[5m]))

# burn rate（99.9%）
(...) / 0.001

# 当前告警
curl -s localhost:9093/api/v2/alerts?active=true

# 告警持续时间
curl -sG localhost:9090/api/v1/query \
  --data-urlencode 'query=time() - ALERTS_FOR_STATE'

# 规则审计
kubectl get prometheusrule -A -o json | jq '.items[].spec.groups[].rules[] | select(.alert) | {alert,for,labels}'
```

## 10. 面试 30 秒

```text
SLI 选用户旅程：成功率、p99、新鲜度；排除健康检查。
SLO 先定 99.9%，单副本/单区域不要承诺 99.99%。
Error Budget = 1-SLO，花完冻结发布。

告警只对症状，不对原因；CPU 高不 page，错误率/延迟才 page。
用多窗口 burn rate：1h/5m 14.4、6h/30m 6、3d/6h 1，替代阈值+for 5m。
一次事故只产生一条可行动告警；同根因聚合/抑制。

事故：SEV 分级 + IC/Scribe/Comms；MTTD 通常比 MTTR 更致命。
Postmortem：时间线、影响量化、5 Whys、行动项 owner+截止日。
变更：80% 故障来自变更（经验值），本仓库样本 4/7 轮变更触发故障；
      部署 marker + 变更后 30-60 分钟相关性分析。
```
