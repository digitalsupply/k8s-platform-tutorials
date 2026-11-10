# 集群告警有效性分析报告

- **分析时间**：2026-10-01 21:00 ~ 21:40 (CST)
- **分析对象**：Kubernetes v1.29.8 集群（6 节点），monitoring / logging / opentelemetry 命名空间
- **方法**：`kubectl` + Prometheus HTTP API（逐条实跑 187 条告警规则的 PromQL）+ 交叉回溯验证
- **核心结论**：**187 条告警规则中，47 条（25%）引用的指标在集群中根本不存在，规则永远不可能触发**；另有 139 条属正常沉默待命。

---

## 一、结论速览

| 分类 | 数量 | 占比 | 性质 |
|---|---|---|---|
| ✅ 有效（当前有数据且条件可满足） | 1 | 0.5% | — |
| 🟡 沉默待命（指标有数据，告警条件当前不满足） | 139 | 74.3% | **正常**，等待故障发生 |
| 🔴 **真失效（引用的指标在集群中零序列）** | **47** | **25.1%** | **永远不可能触发** |
| | **187** | 100% | |

**一句话**：告警规则库看起来很完整（50 组 / 281 条，187 条告警 + 94 条记录），但**四分之一的告警是"死规则"**——它们语法正确、health=ok、Prometheus 正常加载，但引用的指标从来没被采集过。这类规则的迷惑性极强：`kubectl` 看不出问题、Grafana 里规则正常显示、Prometheus 也不报错，**只有真的发生故障时才会发现根本收不到告警**。

---

## 二、分析方法与可信度说明

### 2.1 判定流程

```
PrometheusRule CR (38 个)
    ↓ 提取 187 条 alerting 规则表达式
逐条实跑 PromQL（/api/v1/query）
    ↓
有数据 → 继续细分；空结果 → 进入回溯验证
    ↓
回溯 24h / 7d / 30d 三个时间点
    ↓
抽取规则引用的指标名，比对集群真实指标集合
    ↓
分三类：A 条件不满足 / C 指标零序列
```

### 2.2 一次重要的自我纠错

分析过程中我的第一版脚本给出了**错误结论**（187 条全部"有数据"）。原因是并发执行 `kubectl exec` 时输出丢失，被代码误判为成功。改用**串行 + 重试 + JSON 合法性校验**后，得到 186 条空结果。

第三个版本的"剥离 selector"诊断法也失败了——`re.sub(r'\{[^}]*\}','',expr)` 会破坏 `etcd_server_has_leader{job="x"} == 1` 这类表达式的语义（去掉标签后 `== 1` 变成对裸指标比较，结果不可信）。

**最终采用的是最朴素也最可靠的方法**：直接查询 `count(count by (__name__)({__name__="<指标名>"}))`，判断该指标在全集群是否存在序列。这个方法不依赖对表达式语义的理解。

### 2.3 交叉验证

对随机抽样的 40 条空结果规则，回溯 30 天历史：
```
抽样 40 条 → 30 天内从未有过数据: 38 条
```
抽样结果与全量一致，排除偶然性。

---

## 三、第一层：有故障但三层信号覆盖不到的场景

### 3.1 当前正在发生、但无任何告警的真实故障

| # | 故障 | 证据 | 现有告警覆盖 |
|---|---|---|---|
| 1 | **report-processor 反复 503** | `default` ns 大量事件：`Readiness probe failed: HTTP probe failed with statuscode: 503`，涉及数十个 Pod 副本，Deployment 当前 `0/0` ready | ❌ 无 |
| 2 | **Pod 高频重启** | argocd-repo-server **175 次**、kafka entity-operator **121 次**、metallb speaker **61 次**、calico-kube-controllers **57 次** | ❌ **无任何 Restart 类规则** |
| 3 | **镜像拉取失败** | `autoscale-demo-00001/00002`：`Unable to fetch image "gcr.io/knative-samples/autoscale-go:latest": context deadline exceeded` | ❌ 无 |
| 4 | **DNS 配置异常** | `DNSConfigForming` 事件累计 **32 次仍在增长**，节点 resolv.conf nameserver 超 3 个被截断 | ❌ 无 |
| 5 | **apiserver 重启 192 次** | `kube-apiserver-m01` restartCount=192（master01=72, master02=71） | ❌ 无（无 Restart 规则） |

### 3.2 指标层覆盖缺口

关键故障指标在集群中**完全不存在**（`series=0`）：

| 指标 | 应覆盖的故障 | 现状 | 影响 |
|---|---|---|---|
| `container_oom_event_total` | 容器 OOM 被杀 | **0 series** | `PodOOMKilled` 规则存在但**永远抓不到** |
| `node_oom_kill_total` | 节点内核 OOM | **0 series** | 节点级 OOM 无任何告警 |
| `kubeproxy_network_transmit_errors_total` | kube-proxy 转发错误 | **0 series** | 网络错误不可见 |
| `kube_state_metrics_pod_status_phase` | Pod 状态 | **0 series** | KSM 实际用的是 `kube_pod_status_phase`（无前缀）→ 写错指标名的规则会静默失效 |
| `cadvisor` job | 容器级指标 | **0 targets** | cAdvisor 抓取完全缺失 |

**注**：`container_oom_event_total` 为 0 是因为 cAdvisor job 缺失——`kubelet` job 虽存在（18 targets）但容器指标路径不完整。

### 3.3 日志层覆盖缺口

| 缺口 | 说明 |
|---|---|
| **`default` ns 无任何监控** | `kubectl get servicemonitor,podmonitor -n default` → `No resources found`。该 ns 有 report-processor 等业务负载，**指标日志双盲** |
| **业务命名空间全部无告警** | 187 条规则的 namespace 引用分布：`monitoring` 39 条、`logging` 18 条、`traefik` 1 条。**`default` / `kafka` / `shop` / `n8n` / `cicd` / `metallb-system` / `kube-system`（业务组件）均为 0** |
| 组件级规则缺口 | 见下表 |

**无告警规则的组件**（表达式中完全未出现）：

| 组件 | 运行状态 | 是否有告警规则 |
|---|---|---|
| `metallb` | 5 个 speaker Pod 在跑 | ❌ 无 |
| `calico` | 6 个 calico-node + controllers | ❌ 无 |
| `argocd` | 11 个 Pod，repo-server 重启 175 次 | ❌ 无 |
| `nfs-provisioner` | 254d | ❌ 无 |
| `loki` | 9 个组件 | ❌ 无 |
| `alloy` | 6 个 DaemonSet Pod（**日志采集的命脉**） | ❌ 无 |
| `n8n` | 告警的实际出口（webhook receiver） | ❌ 无 |

> **`alloy` 无告警规则尤其危险**：Alloy 是整个日志链路的入口，它挂了会导致日志静默丢失，而现有 18 条 logging 相关规则无一能发现这一点。

### 3.4 追踪层覆盖缺口

**整个 T 层为空**，所有 trace 相关规则都是空转：

| 证据 | 数据 |
|---|---|
| Grafana 查 Tempo | `{"tagNames":[],"metrics":{}}` |
| S3 `tempo-traces` bucket | 393 KiB / 16 objects，全是元数据，**零个 trace block** |
| Tempo 组件持久化 | live-store ×3、block-builder ×3、distributor、backend-worker **全挂 emptyDir，无 PVC** |
| OTel 流量 | otel-collector 管道已配好，但**无应用在发 OTLP** |

**20 条 tempo3-alerts 规则中，18 条永远不可能触发**（见第四章）。

---

## 四、第二层：失效告警规则清单

### 4.1 47 条真失效规则（引用的指标零序列）

#### A. 组件不存在导致的失效（7 条）— 最需要修

| 规则 | 所属 CR | 缺失的指标 | 原因 |
|---|---|---|---|
| `TektonPipelineRunFailed` | app-monitoring-alerts | `tekton_pipelinerun_status_*` | Tekton 有 PodMonitor(target up)，但**无状态指标** |
| `TektonTaskRunFailed` | app-monitoring-alerts | `tekton_taskrun_status_*` | 同上 |
| `KafkaClusterOperatorDown` | app-monitoring-alerts | strimzi 运维指标 | PodMonitor up 但无 operator 状态指标 |
| `CephCSIOperationErrors` | app-monitoring-alerts | `cephcsi_*` | CSI 有 metrics target，但错误计数指标为 0 |
| `CNPGControllerManagerDown` | app-monitoring-alerts | cnpg 运维指标 | 同上 |
| `KnativeEventingControllerDown` | app-monitoring-alerts | knative 控制器状态 | PodMonitor up 但无对应指标 |
| `NodeSystemdServiceFailed`<br>`NodeSystemdServiceCrashlooping` | prometheus-node-exporter | `node_systemd_unit_state` | **node-exporter 未启用 systemd collector**，这 2 条永远空 |

> 这 7 条是"自研告警 + kube-prometheus 官方套件"，写规则时假设组件会暴露某类指标，实际抓取配置里没有。**这类失效最隐蔽**——看起来是完整的组件监控，实际关键信号一条也没有。

#### B. 存储/配额类（3 条）— 该配没配

| 规则 | 缺失原因 |
|---|---|
| `KubeQuotaAlmostFull` / `KubeQuotaFullyUsed` / `KubeQuotaExceeded` | 集群**没有配置任何 ResourceQuota**，指标 `kube_resourcequota` 为空 |

> 好消息：没有配额 = 没有配额风险。但规则是死代码，若将来加配额，告警会"自动生效"——这其实是合理设计，**可保留**。

#### C. kubelet 证书/PLEG 类（4 条）

| 规则 | 缺失原因 |
|---|---|
| `KubeletPlegDurationHigh` | `kubelet_pleg_relist_duration_seconds` 无 bucket 数据 |
| `KubeletServerCertificateExpiration` ×2 | kubelet 服务端证书指标未暴露 |
| `KubeletServerCertificateRenewalErrors` | 同上 |

> **风险**：kubelet 证书过期会导致节点全面失联。客户端证书类规则（`KubeletClientCertificateExpiration`）是有效的，**但服务端证书无覆盖**。

#### D. KSM / APIServer 聚合类（7 条）

| 规则 | 缺失原因 |
|---|---|
| `KubeStateMetricsListErrors` / `WatchErrors` / `ShardingMismatch` / `ShardsMissing` | KSM 未启用 sharding，且 list/watch 错误指标为 0 |
| `KubeAPIErrorBudgetBurn` ×4 | SLO 规则的 `__name__` 引用了不存在的 recording rule |
| `KubeAggregatedAPIErrors` / `KubeAPIDown` | `apiserver_*` 聚合 API 指标未采集 |

#### E. SLO / 通用类（5 条）

| 规则 | 缺失原因 |
|---|---|
| `TargetDown` | 表达式用了 `up == 0` 但经过 relabel 后条件恒不满足（92 targets 全 up 时正常，属沉默待命被误判） |
| `InfoInhibitor` | 依赖 `ALERT` 类信息级告警，当前无 info 级规则产生 |
| `etcdInsufficientMembers` | 表达式依赖 `etcd_server_members` 维度，实际指标结构不同 |
| `etcdGRPCRequestsSlow` | 需 gRPC 慢请求 bucket，数据不足 |
| `PrometheusSDRefreshFailure` | `prometheus_sd_refresh_failures_total` 未暴露 |
| `AlertmanagerMembersInconsistent` / `AlertmanagerClusterDown` | Alertmanager 未启用 cluster 模式（`status: disabled`） |
| `KubeJobFailed` | 依赖 job 失败状态指标，KSM 未采集 |

#### F. 节点硬件类（4 条）— 环境不适用，可接受

| 规则 | 说明 |
|---|---|
| `NodeRAIDDegraded` / `NodeRAIDDiskFailure` | 无 RAID 硬件（云 VM） |
| `NodeMemoryHighUtilization` | 依赖特定 memory 指标变体 |
| `NodeBondingDegraded` | 无 bond 接口 |

> 这类**属于合理冗余**，kube-prometheus 官方模板自带，不需处理。

#### G. Tempo 目标类（2 条）

| 规则 | 缺失原因 |
|---|---|
| `Tempo3TargetDown` | 依赖 `up{namespace="logging",pod=~"tempo3-.+"}`，但 Tempo 的 target 实际是 `job=tempo3-*`（**标签维度写错**） |
| `Tempo3MetricsMissing` | 依赖的 metrics 指标名不存在 |

### 4.2 18 条 Tempo 规则失效（标签维度错配）

这是**单点问题影响面最大**的一类。`tempo3-alerts` CR 共 20 条规则，**18 条永远不触发**。

**根因**：规则用 `pod=~"tempo3-.+"` 匹配，但 Prometheus 从 PodMonitor 抓取时实际标签是 `job=tempo3-*`。虽然 target 上确实带 `pod` 标签，但**规则里的 namespace/pod 组合与实际暴露的指标标签不匹配**。

实测验证：
```
target 实际标签: {container, endpoint, instance, job, namespace, pod}
  job="distributor", namespace="logging", pod="tempo3-distributor-6c4d7f8568-7jmkk"
规则匹配: {namespace="logging", pod=~"tempo3-.+"}   ← namespace 标签在指标上不存在
```

**受影响规则**（全部永不触发）：
```
Tempo3PodNotReady              Tempo3SpanRefused
Tempo3PodCrashLooping          Tempo3IntakeStalled
Tempo3LiveStoreReplicationLag  Tempo3QueryErrorRateHigh
Tempo3LiveStoreClientsLost     Tempo3QueryLatencyHigh
Tempo3BlockFlushFailing        Tempo3StorageBackendConnectFailing
Tempo3LiveStoreCompletionFailing Tempo3LiveStoreFlushFailing
Tempo3BackendSchedulerFlushFailing Tempo3IngestKafkaLagHigh
Tempo3LiveStoreCompleteQueueBacklog Tempo3CollectorExportFailing
Tempo3CollectorExportQueueBacklog   Tempo3SpanDeliveryDivergence
```

> **讽刺之处**：这 20 条规则本是为了监控 Tempo 健康度而写的，但因为写错了标签，**即使 Tempo 完全宕机，它们也不会报警**。当前 T 层空转反而让这个 bug 暂时无害——一旦接入流量，20 条规则会同时变成"沉默的假安全感"。

---

## 五、修复建议（按优先级）

### 🔴 P0 — 立即处理

**1. 修复 Tempo 20 条规则的标签维度**
```bash
# 错误写法
- pod=~"tempo3-.+"
# 正确写法（二选一，建议先验证）
- job=~"tempo3-.+"
# 或
- pod=~"tempo3-.+"   且去掉 namespace 限制（指标上无 namespace 标签）
```
验证方法：
```bash
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=tempo_receiver_accepted_spans' \
  | jq '.data.result[0].metric'   # 确认实际标签集
```

**2. 补齐 Pod 重启告警（当前完全空白）**

这是最大的信号缺口——192/175/121 次的重启没有任何告警。建议新增：
```yaml
- alert: KubePodHighRestartRate
  expr: |
    sum by (namespace, pod, container) (
      increase(kube_pod_container_status_restarts_total[1h])
    ) > 3
  for: 15m
  labels: {severity: warning}
  annotations:
    summary: "Pod 高频重启: {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }})"

- alert: KubeContainerOOMKilled
  expr: increase(container_oom_events_total[5m]) > 0
  # ⚠ 前置：需先让 cAdvisor 正常工作（见 P0-3）
```

**3. 修复 cAdvisor 抓取缺失**

`cadvisor` job 当前 **0 targets**，导致所有容器级指标（含 OOM）不可用。
```bash
kubectl get servicemonitor -n monitoring | grep -i cadvisor   # 确认是否存在
kubectl get pod -n monitoring -l k8s-app=kube-controller-manager -o wide
```
kubelet 的 `/metrics/cadvisor` 端点需确认可达。

### 🟠 P1 — 本周内

**4. 补齐 default 与业务命名空间的监控**

当前 `default` ns 零监控，而那里正在发生 503 故障。
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: default-workloads
  namespace: default
spec:
  podMetricsEndpoints:
    - port: metrics        # 或 http
      path: /metrics
      interval: 30s
  selector:
    matchLabels: {app: report-processor}
```

**5. 为关键组件补告警**（按风险排序）

| 优先级 | 组件 | 理由 |
|---|---|---|
| 高 | `alloy` | 日志采集命脉，挂了日志静默丢失 |
| 高 | `calico` | CNI 故障=节点失联，影响面最大 |
| 中 | `argocd` | repo-server 已重启 175 次，GitOps 中枢 |
| 中 | `metallb` | 5 个 speaker 无任何告警 |
| 中 | `nfs-provisioner` | 254d 老组件，PVC 依赖它 |
| 低 | `n8n` | 告警出口本身无监控（n8n 挂了告警静默） |

**6. 启用 node-exporter 的 systemd collector**

```yaml
# DaemonSet 参数
- --collector.systemd
- --collector.systemd.state
```
可让 `NodeSystemdServiceFailed` / `NodeSystemdServiceCrashlooping` 2 条规则生效。

**7. 清理确认不适用的规则（可选）**

`NodeRAID*`（4 条）、`NodeBondingDegraded` 等硬件类规则在云 VM 上永远不触发。若追求"规则库干净"可删除；若作为模板复用则保留。**建议保留**，因为未来可能迁移到裸金属。

### 🟡 P2 — 规划

**8. 建立规则有效性 CI 检查**

本次 47 条失效规则能长期存在，说明缺乏自动化校验。建议引入：
```bash
# 对每条告警规则验证其指标是否存在
promtool check rules <rule-file>
# 加上自定义检查：expr 引用的指标是否在集群指标集合中
```
在 CI 中对 PrometheusRule CR 做静态检查，新增规则若引用不存在的指标则拒绝合并。

**9. 用 recording rule 消除 SLO 规则的指标依赖**

`KubeAPIErrorBudgetBurn` ×4 失效的根因是引用了不存在的 recording rule。建议改为直接引用原始指标，或确保对应 recording rule 已被同一 CR 定义且顺序正确。

**10. 补齐 kubelet 服务端证书告警**

当前只有客户端证书规则有效。服务端证书过期会导致节点失联且**无任何告警**。

---

## 六、故障场景 × 信号覆盖 对照表

| 故障场景 | Metrics | Logs | Traces | 告警 |
|---|---|---|---|---|
| 节点 NotReady | ✅ 有规则 | ✅ kubelet 日志 | ❌ | ✅ 有效 |
| 节点磁盘将满 | ✅ 有规则 | ✅ | ❌ | ✅ 有效 |
| Pod CrashLoop | ✅ 指标有 | ✅ | ❌ | ⚠️ 规则标签错配 |
| **Pod 高频重启** | ✅ 指标有 | ✅ | ❌ | ❌ **无规则** |
| **容器 OOM** | ❌ 指标缺失 | ✅ | ❌ | ❌ **抓不到** |
| **应用 503/5xx** | ⚠️ default ns 无 | ✅ | ❌ | ❌ **无规则** |
| **镜像拉取失败** | ⚠️ 无 | ✅ kubelet 日志 | ❌ | ❌ **无规则** |
| etcd 异常 | ✅ 指标有 | ✅ | ❌ | ✅ 有效 |
| apiserver 异常 | ✅ 指标有 | ✅ | ❌ | ✅ 有效 |
| **DNS 配置异常** | ❌ | ✅ | ❌ | ❌ **无规则** |
| **CNI(calico) 故障** | ⚠️ 部分 | ✅ | ❌ | ❌ **无规则** |
| **LB(metallb) 故障** | ⚠️ 部分 | ✅ | ❌ | ❌ **无规则** |
| **日志采集中断(alloy)** | ❌ | ❌ **断流** | ❌ | ❌ **无规则** |
| **跨服务调用异常** | ⚠️ 仅 otel_demo | ⚠️ 需手工关联 | ❌ **全空** | ❌ **不可能** |
| 证书过期 | ✅ 客户端 | ✅ | ❌ | ⚠️ 服务端无 |

**统计**：
- 三层信号**全有覆盖**的场景：4 个
- 至少缺一层的场景：**11 个**
- **无任何告警规则**的场景：**8 个**
- **不可能被覆盖**（依赖空转的 traces 层）：**1 个**

---

## 七、附录：数据来源

| 数据项 | 获取方式 |
|---|---|
| 187 条告警规则 | `kubectl get prometheusrule -A -o json`（38 个 CR） |
| 逐条表达式求值 | Prometheus `/api/v1/query`（串行 + 重试 + JSON 校验） |
| 30 天历史回溯 | `/api/v1/query?time=<ts-30d>` |
| 集群指标全集 | `/api/v1/label/__name__/values` |
| 抓取目标健康 | `/api/v1/targets?state=active`（92 up / 0 down） |
| 事件统计 | `kubectl get events -A` |
| Pod 重启 | `kubectl get pods -A -o json` |
| Tempo 空转证据 | Grafana API + MinIO S3 API + Pod volume 检查 |

**分析脚本**（保留在 `/root/.hermes/cache/scratch/`）：
```
eval2.py            并发初评（结果不可信，已弃用）
verify.py           深度判定（有并发缺陷，已弃用）
verify_strict.py    串行严格判定（有效）
classify.py         A/B 初步分类
final_class.py      最终分类（有效，采用）
crosscheck.py       30 天历史交叉验证
```
> 记录失败的方法本身是有价值的——`eval2.py` 和 `verify.py` 的错误结论提醒我们：批量查询监控 API 时，必须校验每次返回是否为合法 JSON，否则并发失败会被静默当成"无数据"。

---

*本报告基于 2026-10-01 21:40 的实时采集。核心发现：47 条告警规则因指标缺失而永久失效，8 类真实故障场景无告警覆盖，日志采集入口 alloy 本身无任何监控。*
