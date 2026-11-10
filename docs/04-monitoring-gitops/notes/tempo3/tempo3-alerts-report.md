# tempo3 告警规则配置与启用报告

- **执行时间**：2026-09-29 10:28 ~ 10:52 (+08:00)
- **范围**：tempo3 (Tempo 3.0.3) 告警规则上线 + 配套指标采集补齐
- **备份**：`/root/observability-upgrade-backup-20260929-102815-tempo3-alerts`
- **原则**：离线校验先行（5 类），确认后落线；不猜指标名，全部基于集群实测

---

## 【变更】

| # | 对象 | 动作 | 内容 |
|---|---|---|---|
| 1 | `monitoring/podmonitor/tempo3-components` | **新建** | 逐 Pod 抓取 12/13 个 tempo3 Pod 的 `/metrics` |
| 2 | `monitoring/servicemonitor/otel-collector-self-monitoring` | **新建** | 抓 Collector 自身遥测 `:8888`（`otelcol_*` 44 行指标） |
| 3 | `monitoring/prometheusrule/tempo3-alerts` | **新建** | 5 个 rule group / 20 条告警 |
| 4 | `monitoring/servicemonitor/tempo-self-monitor` | **退役（删除）** | 消除 distributor 三重抓取 |

净变更：**+3 个对象，−1 个对象**，tempo3 组件本身零改动（未 restart、未改配置）。

---

## 【原因】

上轮退役报告结论「全集群 0 条 Tempo 告警规则」是 P1 遗留项。44 小时 gRPC ack 半断静默无告警，根因之一就是没有任何规则覆盖摄入链路。本轮目标是：

1. 把 20 条规则建立在**集群实测**的指标名与标签集上（不猜——猜指标名是告警静默失效的头号原因）
2. 补齐规则生效所**必需的采集缺口**（无数据则规则永久沉默）
3. 覆盖本轮实际发生过的失败模式，而非泛化模板

---

## 【实际执行】

### 前置：规则生效链路核对

| 项 | 实测值 | 影响 |
|---|---|---|
| `ruleSelector` | `matchLabels: {release: prometheus}` | **必须**给 PrometheusRule 打此标签，否则不被加载 |
| `serviceMonitorSelector` | 同上 | 同 |
| `podMonitorSelector` | 同上 | 支持 PodMonitor |
| `podMonitorNamespaceSelector` | 未设置 | PodMonitor 不会跨 ns 选取（见下方工具失误 1） |
| 现有自建规则约定 | `cluster-wide-alerts`，标签 `{release: prometheus}` | 沿用 |
| Prometheus retention | 5d | 限制 `for` 与历史窗口长度 |
| 现有规模 | 38 group / 251 rule，health 全 ok | 基线 |

### 指标面实测（8 个组件逐个拉 `/metrics`）

| 组件 | 指标数 | 关键发现 |
|---|---|---|
| distributor | 163 | `tempo_receiver_accepted/refused_spans`（**无 `_total` 后缀**） |
| query-frontend | 119 | `tempo_request_duration_seconds` 带 `route` + `status_code`，`route` 含 `api_search`/`api_traces_traceid` 等 → **可做查询错误率告警** |
| querier | 151 | `tempo_querier_livestore_clients` = 3（Tempo 3.0 替代 ingester ring 的健康信号） |
| live-store | 170 | `tempo_ingest_group_partition_lag`（Kafka 摄入滞后，实测 0） |
| block-builder | 166 | `tempo_ingest_storage_reader_read_errors_total` — **名不副实，实为 S3 写失败** |
| backend-scheduler | 111 | `tempo_backend_scheduler_work_flushes_total`（实测仍增长 = 仍能写 S3） |
| backend-worker | 152 | — |
| metrics-generator | 231 | — |
| memcached | 0 | 容器只声明 `client:11211`，`:9150` 探测 HTTP=000，无指标可抓 |

### 采集缺口（规则生效前提）

| 缺口 | 证据 | 处理 |
|---|---|---|
| 仅 distributor 被抓 | 55 个 target 中 tempo 相关只有 2 个 job | 建 PodMonitor 覆盖 12 Pod |
| `otelcol_*` 完全未抓 | 现有 SM 只抓 `:8889`（`prom-exporter`），该端口 `otelcol_` 行数 = **0**；`:8888` 有 44 行 | 建 SM 抓 `:8888` |
| distributor 三重抓取 | 3 个 job 抓同一 Pod，890 条冗余 series | 退役 `tempo-self-monitor` |

### 20 条规则

**tempo3.availability**（5）
- `Tempo3PodNotReady` — kube-state-metrics，`kube_pod_status_ready == 0`
- `Tempo3PodCrashLooping` — `increase(restarts_total[15m]) > 0`
- `Tempo3TargetDown` — `up == 0`（抓取侧失败）
- `Tempo3MetricsMissing` — `absent(up{...})`（**监控自身失效**——正是 44h 静默的那一类）
- `Tempo3LiveStoreReplicationLag` — `catch_up_duration_seconds > 60`

**tempo3.intake**（2）
- `Tempo3SpanRefused` — `rate(refused_spans[5m]) > 0`
- `Tempo3IntakeStalled` — 写侧有流量 **且** tempo3 接收为 0 的 `and`
  - 关键：不写「零流量」告警（集群本底流量近零，会永久误报）

**tempo3.query**（3）
- `Tempo3QueryErrorRateHigh` — 查询类路由 5xx 占比 > 5%，带流量下限门槛
- `Tempo3LiveStoreClientsLost` — `min(livestore_clients) < 3`（3.0 版的 "ring unhealthy"）
- `Tempo3QueryLatencyHigh` — P95 > 10s

**tempo3.storage**（7）
- `Tempo3BlockFlushFailing` — `rate(read_errors_total[5m]) > 0.1` ← **本次会 firing 的 P0**
- `Tempo3StorageBackendConnectFailing`
- `Tempo3LiveStoreCompletionFailing` / `Tempo3LiveStoreFlushFailing`
- `Tempo3BackendSchedulerFlushFailing`
- `Tempo3IngestKafkaLagHigh` — `partition_lag > 10000`
- `Tempo3LiveStoreCompleteQueueBacklog` — 队列 > 1000

**tempo3.pipeline**（3）
- `Tempo3CollectorExportFailing` — `rate(send_failed_spans[5m]) > 0`
- `Tempo3CollectorExportQueueBacklog`
- `Tempo3SpanDeliveryDivergence` — Collector 报已发送 **但** tempo3 收到 0
  - 直接对应 44h ack 半断的检测逻辑

### ★ 过程中发现的 P0（告警已捕获）

`tempo3-block-builder-0` 持续 S3 写失败：

```
error writing object to s3 backend, object single-tenant/b1fc56f5-.../nocompact.flg:
The provided 'x-amz-content-sha256' header does not match what was computed.
```

- 起始：bb-2 于 2026-09-28 21:11，bb-0 于 2026-09-29 02:23
- 速率：bb-0 实测 **431 次/分 ≈ 62 万/天**，持续重试同一个 block
- **反向排除 RGW/凭据/endpoint**：`backend-scheduler` 用同桶同凭据仍在成功写（`work_flushes` 941→942 持续增长、failed=0）→ 故障特定于 block-builder 的对象上传路径
- 影响：tempo3 至今**没有成功持久化过任何 trace block**，数据只在 live-store 内存中，重启即丢
- 我此前独立构造的 SigV4 测试返回 403 `SignatureDoesNotMatch`——**是我自己的签名构造错误，不构成对 RGW 的证据**（此前 Phase-2 §3.7「S3 写入路径已验证」的结论据此被推翻）

---

## 【验证结果】

### 离线校验（落线前 5 类全过）

| 校验 | 方法 | 结果 |
|---|---|---|
| A. PromQL 语法 | `promtool check rules`（提取 `spec.groups`） | SUCCESS, 20 rules |
| B. 落线可行性 | `kubectl apply --dry-run=server` ×3 | 全部 created/configured |
| C. 名称冲突 | 对 20 个告警名逐个比对现有 251 条 | 0 冲突 |
| D. 抓取目标预演 | 手工计算 PodMonitor/ServiceMonitor 选中的 Pod/Service 集合 | 12/13 Pod、1 Service |
| E. 表达式命中 | 每条规则跑「原始选择器」确认有序列，再跑「阈值」确认当前不触发 | 见下 |

### 落线后验证

| 项 | 结果 |
|---|---|
| rule group / 规则总数 | 38 → **43 group**，251 → **271 rule** |
| health != ok | **0 / 271**（全集群，含既有规则） |
| tempo3 target | **12 个，0 down**（`backend-scheduler`/`backend-worker`/`block-builder`×3/`distributor`/`live-store`×3/`metrics-generator`/`querier`/`query-frontend`） |
| 重复抓取 | distributor 3 job → **1 job**；冗余 890 series 停止增长（100s 采样 890→890） |
| 全集群 target | 55 → **66**（+12 tempo3，−2 旧 distributor，+1 collector） |
| tempo3 组件 | 13/13 Running，**零重启** |
| Alertmanager | `Tempo3BlockFlushFailing` severity=critical 送达，receiver = `n8n-webhook` |
| 既有告警未受影响 | 其余 12 条原样保留（TargetDown×5、etcdMembersDown、Watchdog 等） |
| 既有非 Running | 16 个 down target 全部是既有控制面组件（kube-proxy×6、etcd×3、scheduler×3、controller-manager×3、coredns×1），**本轮未触碰** |

### 规则命中验证（否定性验证，防假阴性）

每条规则都跑了「原始选择器」确认有真实序列，避免把「标签写错」误读成「当前无异常」：

```
✓ Tempo3PodNotReady         原始 13 序列 → ○ 当前不触发
✓ Tempo3PodCrashLooping     原始 13 序列 → ○ 当前不触发
✓ Tempo3TargetDown          原始 14 序列 → ○ 当前不触发
✓ Tempo3MetricsMissing      原始 14 序列 → ○ 当前不触发
✓ Tempo3LiveStoreReplicationLag 原始 3 序列 → ○ 当前不触发
✓ Tempo3SpanRefused         原始 6 序列  → ○ 当前不触发
✓ Tempo3IntakeStalled       两段分别验证 → ○ 当前不触发
✓ Tempo3QueryErrorRateHigh  原始 8 序列  → ○ 当前不触发
✓ Tempo3LiveStoreClientsLost 原始 1 序列(=3) → ○ 当前不触发
✓ Tempo3QueryLatencyHigh    原始 120 序列 → ○ 当前不触发
⚡ Tempo3BlockFlushFailing  原始 2 序列  → firing（正确：S3 写确实在失败）
✓ 其余 storage/pipeline 9 条 原始均有序列 → ○ 当前不触发
```

### 端到端告警链路

`Prometheus 规则求值 → pending(5m) → firing → Alertmanager 接收 → 路由 n8n-webhook`
`Tempo3BlockFlushFailing` 实际经历 `pending → firing`（210s），全链路走通，非仅"规则已加载"。

---

## 【风险】

| 风险 | 等级 | 说明 | 缓解 |
|---|---|---|---|
| **S3 写失败 P0 未修复** | **高** | tempo3 无法持久化 block，数据在内存中，重启即丢 | 已由 `Tempo3BlockFlushFailing` 持续告警；**修复需人工决策**（可能涉及 RGW 侧或 tempo3 客户端行为） |
| `Tempo3BlockFlushFailing` 会长期 firing | 中 | P0 未修前持续告警，可能造成告警疲劳 | severity=critical；若需临时静默需人工确认 |
| 退役 `tempo-self-monitor` 后旧 series 仍在 TSDB | 低 | 890 条 series 会在 retention=5d 内自然过期，**不主动删数据** | 已确认停止增长 |
| 3 条规则阈值偏宽，罕见故障可能漏报 | 低 | Kafka lag >10000、队列 >1000、P95 >10s | 集群本底流量近零，宽阈值避免误报；有真实流量后可收紧 |
| `Tempo3IntakeStalled` 依赖 Collector 指标 | 低 | 若 Collector 自身采集再断，该规则会沉默 | `Tempo3MetricsMissing` 只覆盖 tempo3，不覆盖 collector——**已知覆盖缺口** |
| 未覆盖 memcached | 低 | 无指标可抓（容器无 metrics 端口） | 若后续需要，需改 tempo3 helm values 开 telemetry |
| 采集量增加 | 低 | target 55→66，tempo series 445→5506 | 12 Pod × 30s，可接受 |

**已知覆盖缺口（明确声明）**：
1. `metrics-generator` / `backend-worker` 的业务指标已采集但未写告警规则（当前无异常，无需规则）
2. Collector 侧无"指标消失"类规则
3. 无 S3 桶容量的黑盒探测（只能被动等 tempo3 报错）

---

## 【回滚方式】

全部回滚源在 `/root/observability-upgrade-backup-20260929-102815-tempo3-alerts`：

```bash
BD=/root/observability-upgrade-backup-20260929-102815-tempo3-alerts

# 1) 撤销全部变更（恢复原状：回到只有 tempo-self-monitor 抓 distributor）
kubectl delete -n monitoring prometheusrule/tempo3-alerts
kubectl delete -n monitoring podmonitor/tempo3-components
kubectl delete -n monitoring servicemonitor/otel-collector-self-monitoring
kubectl apply -f "$BD/manifests/tempo-self-monitor-retired.yaml"   # 恢复退役的 SM

# 2) 只撤销告警规则，保留采集补齐（推荐——采集本身是净收益）
kubectl delete -n monitoring prometheusrule/tempo3-alerts
```

回滚源清单：

| 文件 | 内容 |
|---|---|
| `manifests/tempo3-alerts.yaml` | 20 条规则（含最终修正的指标名） |
| `manifests/tempo3-podmonitor.yaml` | PodMonitor（含 `namespaceSelector` 修正） |
| `manifests/otel-collector-selfmon.yaml` | Collector SM |
| `manifests/tempo-self-monitor-retired.yaml` | 退役的 SM，26 行 |
| `manifests/{servicemonitors,prometheusrules,prometheus}-before.yaml` | 变更前全量快照（600 / 4083 / 144 行） |
| `verify/baseline-before.txt` | 上线前基线（38 group / 251 rule / 12 firing / 2 tempo target） |
| `verify/after-state.txt` | 上线后终态 |

回滚无需重启任何 tempo3 组件（未触碰其 Pod）。

---

## 【本轮工具失误记录】

1. **PodMonitor 不跨 ns 选取**。首版 PodMonitor 未写 `namespaceSelector`，`--dry-run=server` 通过、apply 成功，但**生成 0 个 target**。根因：PodMonitor 不会像 ServiceMonitor 那样从 `nsSelector` 推导 namespace，不写就退回 Prometheus 自身 ns（`monitoring`），而 tempo3 Pod 在 `logging`。定位方式：读 `/api/v1/status/config` 看 operator 生成的 `kubernetes_sd_configs.namespaces=['monitoring']`。**教训：`--dry-run=server` 通过 ≠ 会生效**，必须再查生成的配置或 target 数。

2. **指标名猜错**。规则写 `tempo_receiver_refused_spans_total`，实际是 `tempo_receiver_refused_spans`（**无 `_total` 后缀**），导致 2 条规则静默无数据。定位方式：跑「原始选择器」发现无数据，再用 `/api/v1/series` 查真实标签集。**这正是本轮坚持逐条否定性验证的价值**——否则会误以为"当前无异常"。

3. **headless Service 轮询导致测量不确定**。经 `tempo3-block-builder` headless Service 取数时，3 次请求分别落到 3 个不同 Pod，其中 `block-builder-1` 恰好**没有** `read_errors` 指标（因为它错误数为 0，该 counter 不暴露），被误读成"该 Pod 无 reader 指标"。改为**逐 Pod 直连 PodIP** 才得到确定结论。**教训：同组件多副本指标必须逐 Pod 测，不能经 headless Service 汇总。**

4. **空值参与算术**。首次测增长率时 awk 转义失败使取数为空，`$((B2-B1))` 把空当 0，得出"增量 5461"的假结论。已加取数自检（非数字则中止）后才得到真实值 1293/180s。**教训：算增量前必须校验两侧取数均为有效数字。**

5. **探查 Pod 静默失败伪装成"无数据"**。中途一批查询全部返回空，第一反应是"采集出问题"，实际是 `t-rx` 的 `sleep 1800` 到期退出（phase=Succeeded），`kubectl exec` 报 `cannot exec into a container in a completed pod`。重建后自检立刻拿到 200。**教训：探查 Pod 用完即毁是常态，查询前先查 `phase` 并自检已知端点。**

6. **grep 管道把空输入当命中**。等待 Prometheus 重载时用 `grep -c` 判断残留，空输入返回 1（应为 0），导致误判"配置残留 120s 未清"。改用 Python 精确统计后确认：文本命中 **0** 次、job 名单仅 `podMonitor/monitoring/tempo3-components/0`。**教训：计数类判断不能只靠 shell 管道，落地到可复核的解析结果。**

7. **`kubectl delete ... -o yaml` 是非法 printer**。离线校验时整条失败（`only support '-o name'`），删除动作未执行。改用 `-o name` 校验通过。**与之前记录的 `create -o wide` 同类问题。**

8. **子命令不支持 `-A`**。`kubectl get podmonitor tempo3-components -A -o name` 返回空（被误读为"对象缺失"），实为该子命令语法问题。补 `-n monitoring` 后正常。**与之前记录的"单条命令 `-n` 作用于所有参数"是同一族陷阱。**

---

## 【下一步】

按优先级：

1. **【P0，待人工决策】修复 tempo3 → S3 写失败**
   `x-amz-content-sha256` 不匹配，431 次/分持续重试同 1 个 block，tempo3 至今未持久化任何 trace block。已定位到故障特定于 block-builder 上传路径（同桶同凭据下 backend-scheduler 写入正常），**具体机制与修复方案需单独一轮排查**。这会持续触发 `Tempo3BlockFlushFailing`。

2. **【P2】补 Collector 侧"指标消失"规则**
   当前 `Tempo3MetricsMissing` 只覆盖 tempo3。Collector 采集再次中断时，`tempo3.pipeline` 组 3 条规则会全部沉默——与本次 44h 静默同源。

3. **【P2】`loki` / `tempo` 两个 Grafana 数据源纳入 provisioning**
   风险已升高：tempo 数据源现指向唯一可用的 tempo3，属单点，Grafana 重建即丢失。

4. **【P2】tempo3 各组件补业务看板**
   指标已全量采集（5506 series），但无 tempo3 专属 Grafana 面板。

5. **【待人工确认】既有 P1/P2**
   9 个 OTel ReplicaSet 累积、CoreDNS `ImagePullBackOff`（37h）、16 个 down target（kube-proxy/etcd/scheduler/controller-manager）。

---

## 附：采集拓扑变化

| job | 变更 | target |
|---|---|---|
| `podMonitor/monitoring/tempo3-components` | **新增** | 12（8 个组件，block-builder/live-store 各 3） |
| `serviceMonitor/monitoring/otel-collector-self-monitoring` | **新增** | 1（Collector `:8888`） |
| `serviceMonitor/monitoring/tempo-self-monitor` | **删除** | −2（`tempo3-distributor` / `tempo3-distributor-discovery`） |
| `serviceMonitor/opentelemetry/otel-collector-spanmetrics` | 未动 | 1（`:8889`，保留原样） |
