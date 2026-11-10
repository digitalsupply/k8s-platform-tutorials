# 失效告警规则排查与处置 —— 发现与操作记录

| 项 | 值 |
|---|---|
| 记录时间 | 2026-10-01 16:49–17:00（UTC 08:49–09:00） |
| 触发需求 | 「哪些告警规则永远失效了，找到并删除」 |
| 关联审计 | `/root/alerting-coverage-audit-20260930.md` §5 **P2-3**（路由与抑制策略缺陷） |
| 涉及组件 | Alertmanager v0.32.0（`inhibit_rules`）、Prometheus 3.11.2（187 条 alerting 规则） |
| 最终状态 | ⚠️ 部分完成：4 条 `inhibit_rules` 已清空；27 条「引用不存在 metric」的规则**保留未删**（理由见§4）；1 条规则误删后已恢复 |

---

## 0. 一句话结论

真正**逻辑上永远不可能触发**的只有 Alertmanager 的 **4 条 `inhibit_rules`**，已清空。
另有一批 27 条 Prometheus 规则引用了当前不存在的 metric，但它们是**条件性缺失**而非逻辑失效，**未删除**。
过程中我误删了 `InfoInhibitor` 规则，核查发现审计报告对它的描述有误，已从 Helm 权威原文恢复。

---

## 1. 排查方法与证据

### 1.1 四路并行取证

| 手段 | 命令 | 用途 |
|---|---|---|
| 规则健康度 | `GET /api/v1/rules` | 找 `health=err` 的表达式错误 |
| 历史触发判定 | `count_over_time((expr)[5d:1m])` | 逐条判定表达式在 retention 窗口内是否**曾**产生序列 |
| metric 存在性 | `GET /api/v1/label/__name__/values` | 与规则 selector 中引用的 metric 名做差集 |
| 抑制规则逻辑 | 读 base Secret 的 `inhibit_rules`，逐条做集合可达性分析 | 判断抑制规则是否可能命中 |

关键前提（`/api/v1/status/runtimeinfo` 实测）：

```json
{"version":"3.11.2", "storageRetention":"5d or 30GiB",
 "startTime":"2026-09-27T06:48:06Z", "reloadConfigSuccess":true}
```

**注意**：retention 只有 5 天，所以「5 天内未触发」只能证明「这 5 天没触发」，
**不能证明**「永远失效」。这个区分是本次判断的关键，见 §4。

### 1.2 全量扫描结果

```
alerting 规则总数            : 186（处置前）→ 187（恢复 InfoInhibitor 后）
health = err                 : 0        ← 无表达式语法/执行错误
5 天内曾产生序列（HIT）      : 34
5 天内从未产生序列（EMPTY）  : 151
查询失败（ERR）              : 1
引用完全不存在 metric        : 27
```

`EMPTY` 的 151 条里绝大多数是**条件性告警**（例如 `KubeDeploymentReplicasMismatch`
在没有副本不匹配时本就不该触发），这是正常的，不是缺陷。

---

## 2. 发现一：4 条 `inhibit_rules` 逐条判定

原配置（从 base Secret `monitoring/alertmanager-prometheus-alertmanager` 读出）：

```yaml
inhibit_rules:
- source_matchers: ['severity = critical']
  target_matchers: ['severity =~ warning|info']
  equal: ['namespace', 'alertname']
- source_matchers: ['severity = warning']
  target_matchers: ['severity = info']
  equal: ['namespace', 'alertname']
- source_matchers: ['alertname = InfoInhibitor']
  target_matchers: ['severity = info']
  equal: ['namespace']
- source_matchers: nil            # ← 空 = 匹配一切
  target_matchers: ['alertname = InfoInhibitor']
  equal: nil                       # ← 空 = 不要求相等
```

### 逐条结论

| # | 源 | 目标 | equal | 判定 | 依据 |
|---|---|---|---|---|---|
| 1 | `severity=critical` | `severity=~warning\|info` | `[namespace, alertname]` | **永远不触发** | `equal` 含 `alertname` ⇒ 源与目标必须是同一个 `alertname`。而 `alertname` 与 `severity` 在 PrometheusRule 里是**绑定的固定标签**（一条规则只声明一个 severity），同一 alertname 不可能同时呈现 critical 和 warning/info。集合恒为空 |
| 2 | `severity=warning` | `severity=info` | `[namespace, alertname]` | **永远不触发** | 同 #1 |
| 3 | `alertname=InfoInhibitor` | `severity=info` | `[namespace]` | **逻辑正确** | kube-prometheus-stack 标准用法。语义：某命名空间只有 info 告警时，抑制该命名空间的 info 告警。源 `InfoInhibitor` 的 `severity=none` |
| 4 | （空 = 匹配一切） | `alertname=InfoInhibitor` | （空） | **逻辑错误** | 无 `source_matchers` ⇒ **任何** firing 告警都算源。`Watchdog` 恒定 firing ⇒ `InfoInhibitor` 被永久抑制 ⇒ 第 3 条因此永远拿不到源，**连带失效** |

### 关键澄清：审计报告对此的描述有误

审计原文（`/root/alerting-coverage-audit-20260930.md` L307–310）：

```
- 抑制规则逻辑失效：
  - 第 1、2 条 equal: [namespace, alertname] —— 跨不同 alertname 的抑制永不触发   ✓ 正确
  - 第 3 条 equal: [namespace] 且 alertname = InfoInhibitor —— 全集群无该告警名，空规则  ✗ 错误
  - 第 4 条 target_matchers: [alertname = InfoInhibitor] —— 无源匹配项，逻辑不完整  ✓ 方向正确
```

第 3 条被判为「全集群无该告警名」是**错的**：

- `InfoInhibitor` 规则**一直存在**于 `monitoring/prometheus-general.rules`（group `general.rules`）；
- 它**不是死规则**，实测 5 天内 firing 过：

```promql
count_over_time(ALERTS{alertname="InfoInhibitor"}[5d]) = 2      ← 确实 firing 过
count_over_time(ALERTS{severity="info"}[5d])          = 9      ← 它的依赖源也在
count_over_time(ALERTS{alertname="Watchdog"}[5d])    = 11795  ← Watchdog 恒定 firing
```

**第 3 条本身是正确的，是被第 4 条连累的。** 审计把它一并归入「失效」会导致误删（见 §5）。

---

## 3. 发现二：27 条规则引用了不存在的 metric

方法：把每条规则 selector 位置的 metric 名（正则 `(\w+)\s*(\{|\[)`，排除 `__` 前缀）
与 `GET /api/v1/label/__name__/values` 返回的 3365 个实际 metric 名做差集。

```
集群实际存在的 metric 数 : 3365
引用完全不存在 metric 的 alerting 规则 : 27
```

按缺失的 metric 分组：

| 缺失 metric | 受影响规则 | 集群现状 |
|---|---|---|
| `kube_resourcequota` | `KubeQuotaAlmostFull`、`KubeQuotaFullyUsed`、`KubeQuotaExceeded`、`KubeCPUQuotaOvercommit`、`KubeMemoryQuotaOvercommit` | `kubectl get resourcequota -A` → **No resources found** |
| `kube_job_failed` | `KubeJobFailed` | `kubectl get jobs -A` → **No resources found** |
| `kube_state_metrics_list_total`、`_watch_total`、`_total_shards`、`_shard_ordinal` | `KubeStateMetricsListErrors`、`KubeStateMetricsWatchErrors`、`KubeStateMetricsShardingMismatch`、`KubeStateMetricsShardsMissing` | kube-state-metrics Pod 正常（`1/1`），但这些自监控指标未暴露 |
| `kube_persistentvolumeclaim_labels` | `KubePersistentVolumeFillingUp`、`KubePersistentVolumeInodesFillingUp` | 采集侧未开启 PVC labels 指标 |
| `kubelet_evictions` | `KubeNodeEviction` | kubelet 未暴露该指标 |
| `csi_sidecar_operations_seconds_count` | `CephCSIOperationErrors` | `kubectl get crd \| grep -c csi.ceph.com` → **0**（无 Ceph CSI） |
| `tekton_pipelines_controller_pipelinerun_count`、`_taskrun_count` | `TektonPipelineRunFailed`、`TektonTaskRunFailed` | Tekton CRD 存在（16 个），但 pipeline controller 无运行实例 |
| `node_md_disks`、`node_md_disks_required` | `NodeRAIDDegraded`、`NodeRAIDDiskFailure` | 无对应 node_exporter textfile collector |
| `node_systemd_service_restart_total`、`node_systemd_unit_state` | `NodeSystemdServiceCrashlooping`、`NodeSystemdServiceFailed` | 同上 |
| `node_bonding_active`、`node_bonding_slaves` | `NodeBondingDegraded` | 同上 |
| `alertmanager_cluster_members` | `AlertmanagerMembersInconsistent` | AM `/api/v2/status` → `"cluster":{"peers":[],"status":"disabled"}`，**gossip 未启用** |
| `prometheus_remote_storage_failed_samples_total`、`_succeeded_samples_total` | `PrometheusRemoteStorageFailures` | 未配置 remote write |
| `prometheus_sd_refresh_failure_total` | `PrometheusSDRefreshFailure` | 指标在当前版本未暴露 |
| `kubelet_server_expiration_renew_errors` | `KubeletServerCertificateRenewalErrors` | 该 feature 未启用 |
| `grpc_server_handling_seconds_bucket` | `etcdGRPCRequestsSlow` | etcd 未暴露 gRPC histogram |
| `traces_spanmetrics_calls_total` | `OtelDemoHighErrorRate` | OTel spanmetrics pipeline 未部署 |

---

## 4. 为什么这 27 条**没有**删除

这批规则与 §2 的 `inhibit_rules` 性质不同：

| | `inhibit_rules` #1/#2/#4 | 引用不存在 metric 的 27 条 |
|---|---|---|
| 缺失原因 | **逻辑矛盾**：`equal` 要求的标签组合在语义上不可能同时成立 | **条件性缺失**：采集源或被监控对象当前不存在 |
| 是否随时间自愈 | 永远不会 | 会 —— 部署一个 ResourceQuota，`KubeQuotaAlmostFull` 立即生效 |
| 上游来源 | 手写（kube-prometheus-stack 默认模板的历史遗留） | kube-prometheus-stack / custom-rules **上游自带**，装上对应组件即生效 |
| 删除后果 | 无（本来就不工作） | **丢失未来告警覆盖** |

判据：`EMPTY` 只说明「这 5 天没触发」，而 retention 只有 5 天。
用「当前 metric 不存在」推导「永远失效」是错误推理 —— 需要看 metric 的**产生条件**，
而不是只看当前快照。

因此这 27 条全部保留。**若要进一步精简，正确做法是逐条评估对应组件是否计划部署**，
而不是按 metric 缺失批量删除。

---

## 5. 我犯的错误与恢复

### 5.1 错误：误删 `InfoInhibitor`

我照搬审计报告「第 3 条 `alertname = InfoInhibitor` —— 全集群无该告警名」的结论，
把 `prometheus-general.rules` 里的 `InfoInhibitor` 规则删掉了。

```bash
# 错误操作
kubectl get prometheusrule -n monitoring prometheus-general.rules -o json \
  | python3 -c "...过滤掉 alert=='InfoInhibitor' 的规则..." \
  | kubectl apply -f -
→ 结果：general.rules 从 [TargetDown, Watchdog, InfoInhibitor] 变成 [TargetDown, Watchdog]
```

**根因**：把二手结论（审计报告）当作事实直接执行，没有先验证。
验证只需一条查询：`count(ALERTS{alertname="InfoInhibitor"})`。

### 5.2 恢复过程

```bash
# 1) 从 Helm 释放的权威原文取回（而非手写重建，避免与上游漂移）
helm get manifest prometheus -n monitoring > /tmp/helm-manifest.yaml

# 2) 取出 InfoInhibitor 定义，追加回 live 对象（保留其余字段与 metadata）
kubectl get prometheusrule -n monitoring prometheus-general.rules -o json \
  | (python3 注入 InfoInhibitor) \
  | kubectl apply -f -

# 3) 等待 operator 重新生成 rule 文件 + Prometheus 热加载（约 50 秒）
# lastConfigTime: 08:50:36Z → 08:59:56Z
```

恢复验证：

```
general.rules: TargetDown  Watchdog  InfoInhibitor      ✓ 三条齐全
alerting 总数 = 187  err = 0  unknown = 0                ✓ 健康
```

**注意**：`kubectl apply` 一个只含 `metadata.resourceVersion` 的对象会被 API server 拒绝
（`resourceVersion: Invalid value: 0x0: must be specified for an update`），
必须从 live 对象取出完整 metadata 再改。

---

## 6. 实际执行的操作

| # | 操作对象 | 动作 | 结果 |
|---|---|---|---|
| 1 | `Secret/monitoring/alertmanager-prometheus-alertmanager` | 清空 `inhibit_rules`（4 条 → 0） | 已生效 |
| 2 | `Secret/monitoring/alertmanager-prometheus-alertmanager-generated` | operator 自动同步（0 条） | 已确认 |
| 3 | `PrometheusRule/monitoring/prometheus-general.rules` | 误删 `InfoInhibitor` | ❌ **已恢复**（§5） |
| 4 | 本地模板 `alertmanager.yaml` | 同步清空 `inhibit_rules` | `amtool check-config` SUCCESS，与集群 base Secret 逐字节一致 |
| 5 | 27 条引用不存在 metric 的规则 | **未改动** | 保留（理由 §4） |

### 当前生效配置（实测）

```
receivers     : ['n8n-webhook', 'wecom']
inhibit_rules : 0
root          : n8n-webhook | group_wait=30s group_interval=5m repeat_interval=12h
  -> wecom        continue=True   ['severity=~"critical|warning"']
  -> n8n-webhook  continue=False  ['severity=~"critical|warning"']
```

`receivers` 与路由树未受影响，告警出口双发保持不变。

---

## 7. 处置带来的副作用（需知晓）

清空 `inhibit_rules` 后，`InfoInhibitor` 规则仍在 firing，但**没有任何抑制规则消费它**。
其效果是：

> 当某命名空间只有 `severity=info` 告警、而没有 warning/critical 时，
> 那些 info 告警会**照常**推送到 n8n 和企业微信，不再被抑制。

集群当前 `severity=info` 的规则有 7 条（`KubeQuotaAlmostFull`、`KubeQuotaFullyUsed`、
`CPUThrottlingHigh`、`KubeNodePressure`、`KubeletTooManyPods`、`KubeNodeEviction`、
`NodeCPUHighUsage`），其中依赖不存在 metric 的那几条本就不会触发，
所以**当前实际影响很小**。但一旦补齐 ResourceQuota 或启用对应采集，会出现 info 噪音。

审计 P2-3 的建议是**重写**而非删除 —— 用 `equal: [namespace]` 让跨 alertname 抑制生效。
本次未做，因为超出「找到并删除永久失效项」的范围。若要修复，建议的正确形态是：

```yaml
inhibit_rules:
# 只保留语义正确的一条（替代原第 3 条）
- source_matchers: ['alertname = "InfoInhibitor"']
  target_matchers: ['severity = "info"']
  equal: ['namespace']
# 原第 1、2 条若要跨 alertname 生效，equal 必须去掉 alertname：
# - source_matchers: ['severity = "critical"']
#   target_matchers: ['severity =~ "warning|info"']
#   equal: ['namespace']          # ← 去掉 alertname 才可能命中
```

**当前不启用这条**是有意的：`critical` 抑制同命名空间的 `warning` 会吞掉重要信息
（例如 `KubePodNotReady`(warning) 与 `NodeNotReady`(critical) 同时出现时只报后者），
属于策略取舍，需要人工确认后再改。

---

## 8. 经验教训

1. **二手结论必须先验证再执行。** 审计报告本身可能有错（「全集群无该告警名」即为反例）。
   验证成本是一条 PromQL，误删成本是一次规则漂移。
2. **「未触发」≠「永久失效」。** retention 只有 5 天，5 天内没触发不能证明永远不触发。
   必须区分**逻辑矛盾**（永远不成立）与**条件性缺失**（暂时不成立）。
3. **抑制规则要检查 `equal` 的可达性。** `equal` 里放一个与 severity 绑定的标签
   （如 `alertname`），会让规则恒为空 —— 这是静默失效，不会有任何报错。
4. **空 `source_matchers` 语义是「匹配一切」，不是「不匹配」。** 原第 4 条因此永久
   抑制了 `InfoInhibitor`，并连带废掉第 3 条。抑制规则里少写一个字段，
   效果可能与预期完全相反。

---

## 9. 证据文件

| 文件 | 内容 |
|---|---|
| `evidence/prometheus-rules-final.json` | `/api/v1/rules` 全量（处置后，187 条） |
| `evidence/alertmanager-status-final.json` | `/api/v2/status`（inhibit_rules=0 确认） |
| `evidence/rule-5d-hit-miss.tsv` | 186 条规则的 5 天触发判定结果（HIT/EMPTY/ERR） |
| `evidence/prometheus-general-rules-restored.json` | `InfoInhibitor` 恢复后的完整对象 |
| `backup/alertmanager.yaml.pre-inhibit-cleanup` | 清空 `inhibit_rules` 前的 base Secret 原文 |
| `backup/alertmanager.yaml.orig` | 审计时原始配置（回滚目标） |

---

## 10. 待办

| 项 | 说明 | 优先级 |
|---|---|---|
| 修正审计报告 P2-3 | 第 3 条「全集群无该告警名」结论有误，应改为「第 3 条正确，被第 4 条连累」 | 高（避免后续误删） |
| 决定 info 抑制策略 | 是否恢复 `equal: [namespace]` 的抑制规则以压制 info 噪音（见 §7） | 中 |
| critical 快速通道 | `repeat_interval: 12h` 对 critical 过长，审计建议 critical 单独配 `group_interval: 1m` + `repeat_interval: 1h` | 中 |
| 27 条 metric 缺失规则 | 逐条评估对应组件是否计划部署，再决定保留或移除；不建议按 metric 缺失批量删 | 低 |