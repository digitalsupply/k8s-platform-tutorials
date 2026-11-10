# 监控覆盖缺口盘点 —— 修修补补后还剩什么

- **盘点时间**：2026-10-02 13:30
- **范围**：全集群 90 个工作负载（Deployment / StatefulSet / DaemonSet）
- **方法**：`kubectl` 枚举全部 workload → 与 43 个采集 job 做映射 → 逐个验证是否暴露 metrics 端口 → 确认指标是否真的为 0

---

## 一、总体结论

| 分类 | 数量 | 说明 |
|---|---|---|
| 已有效监控 | **44** | 有 ServiceMonitor/PodMonitor，target 正常 up |
| **A 类：暴露了 metrics 但没配 monitor** | **27** | **真正的漏配** — 组件在吐指标但没人抓 |
| B 类：未暴露 metrics 端口 | 14 | 只能用 `kube_pod_*` 通用指标兜底 |
| B 类中实际有 Service 可抓 | 3 | dashboard-metrics-scraper / tekton-dashboard / n8n |

**监控覆盖率：44 / 90 ≈ 49%**

**最刺眼的一条**：**Loki 的 6 个核心组件（日志系统的全部）零 metrics 采集** —— `loki_build_info` 实测 0 series。当前只能靠 KubePodCrashLooping 之类的通用规则发现它挂了，而 ingest 速率、chunk 堆积、缓存命中率等**日志系统自身的健康指标一个都看不到**。

---

## 二、A 类 — 真正的漏配（27 个）

这些组件**端口都声明好了、指标都在吐**，但没有任何 monitor 去抓。补一个 ServiceMonitor 就能解决。

### 2.1 🔴 Loki 全套（6 个）—— 最高优先级

| 组件 | metrics 端口 | 缺失影响 |
|---|---|---|
| `loki-write` | 3100 | **ingest 速率、chunk 堆积、WAL 大小全不可见** |
| `loki-backend` | 3100 | compactor 状态、index 状态不可见 |
| `loki-read` | 3100 | 查询延迟、querier 状态不可见 |
| `loki-gateway` | 8080 | 入口流量、错误率不可见 |
| `loki-chunks-cache` | 9150 | memcached 命中率（决定查询性能）不可见 |
| `loki-results-cache` | 9150 | 同上 |
| `loki-canary` | 3500 | canary 自检结果不可见 |

**实测确认**：
```bash
count(loki_build_info)                            → 0
count(loki_distributor_bytes_received_total)      → 0
count(loki_ingester_memory_chunks)                → 0
```

**这意味着**：
- 告警库里 18 条 `Tempo3*` 规则虽有对应物，但 **Loki 侧一条都没有**（tempo3-alerts 只管 Tempo）
- 日志系统完全依赖 `AlloyDown` / `LokiIngestStalled`（我上轮加的，用 KSM 指标）这种粗粒度判断
- **日志丢失、摄取停滞、查询变慢**都无法主动发现

### 2.2 🟠 Knative 全套（12 个）

| Namespace | 组件 | metrics 端口 |
|---|---|---|
| knative-serving | `controller` | 9090 |
| knative-serving | `webhook` | 9090 |
| knative-serving | `activator` | 9090（已被 controlplane PodMonitor 部分覆盖）|
| knative-serving | `autoscaler` | 9090 |
| knative-serving | `autoscaler-hpa` | 9090 |
| knative-serving | `net-kourier-controller` | 9090 |
| knative-serving | `3scale-kourier-gateway`（envoy）| 9000 |
| knative-eventing | `eventing-webhook` | 9090 |
| knative-eventing | `kafka-controller` | 9090 |
| knative-eventing | `job-sink` | 9092 |
| knative-eventing | `pingsource-mt-adapter` | 9090 |
| knative-operator | `knative-operator` | 9090 |
| knative-operator | `operator-webhook` | 9090 |

**缺失影响**：Knative 是集群的事件/服务运行底座，12 个组件的队列深度、请求延迟、并发数、revision 状态全部不可见。`knative-eventing-controlplane` PodMonitor 只覆盖了 3 个 target，其余 9 个裸奔。

### 2.3 🟠 VPA（3 个）— 自动扩缩容完全不可见

| 组件 | 端口 | 状态 |
|---|---|---|
| `vpa-recommender` | 8942 | ❌ 指标 0 |
| `vpa-updater` | 8943 | ❌ 指标 0 |
| `vpa-admission-controller` | 8944 | ❌ 指标 0 |

**VPA 是自动扩缩容决策者**。推荐值、驱逐风险、OOM 历史全部不可见 —— **自动扩容出问题无法排查**。

### 2.4 🟡 其他

| 组件 | 端口 | 说明 |
|---|---|---|
| `kube-system/metrics-server` | 10250 | HPA 的数据源，指标 0（但集群目前无 HPA 使用，影响有限）|
| `argocd/argocd-dex-server` | 5558 | ArgoCD 登录服务 |
| `tekton-pipelines/tekton-triggers-webhook` | 9000 | 触发器 webhook |
| `default/hello-0000X`（3 个）| 9090 | Knative demo，**可忽略** |
| `default/report-processor` | 9090 | Knative demo，**可忽略**（但它正在反复 503）|

---

## 三、B 类 — 未暴露 metrics（14 个）

这些组件不吐 Prometheus 格式指标，**只能靠 KSM 通用指标**（`kube_pod_status_ready` / `kube_pod_container_status_restarts_total` 等）覆盖。我已在上一轮为其中关键几个加了告警。

| Namespace | 组件 | 现有覆盖 | 是否已加告警 |
|---|---|---|---|
| kube-system | `calico-node`（6 副本）| KSM | ✅ `CalicoNodeNotReady` |
| kube-system | `calico-kube-controllers` | KSM | ✅ `CalicoKubeControllersDown` |
| metallb-system | `speaker`（5 副本）| KSM | ✅ `MetalLBSpeakerNotReady` + 重启告警 |
| n8n | `n8n` | KSM | ❌ **无告警**（告警出口本身）|
| n8n | `cloudflared` | KSM | ❌ 无 |
| nfs-provisioner | `nfs-provisioner` | KSM | ❌ **无告警**（PVC 依赖它）|
| kube-system | `kube-vip-ds` | KSM | ❌ 无 |
| kubernetes-dashboard | `kubernetes-dashboard` | — | ❌ 无（实验环境可忽略）|
| argocd | `argocd-redis` | KSM | ❌ 无 |
| kafka | `my-cluster-entity-operator` | KSM | ❌ 无 |
| tekton-pipelines | `tekton-triggers-core-interceptors` | KSM | ❌ 无 |
| tekton-pipelines | `tekton-dashboard` | — | ❌ 无（实验环境可忽略）|
| default | `netshoot-debug` | — | ❌ 无（调试用，可删）|

### 3.1 B 类中有 3 个其实能抓

| 组件 | Service | 端口 | 实际暴露的指标 |
|---|---|---|---|
| `kubernetes-dashboard/metrics-scraper` | dashboard-metrics-scraper | 8000 | **kubelet/coredns 资源汇总**，抓它等于补齐 dashboard 视图 |
| `tekton-pipelines/tekton-dashboard` | tekton-dashboard | 9097 | Tekton 任务状态 |
| `n8n/n8n` | n8n-svc | 5678 | n8n 自身无 Prometheus 端点（需 `@n8n/otel` 插件）|

> `n8n` 5678 端口是 HTTP API 不是 metrics，**技术上可抓但实际无 Prometheus 指标**。n8n 2.x 有官方 OTel 支持（`@n8n/otel` 插件），但需改镜像 + 装插件，不属于「配个 ServiceMonitor」范畴。

---

## 四、告警覆盖 vs 指标覆盖（第二个维度）

指标采集到位 ≠ 有告警。这是本轮盘点发现的另一层缺口。

| 组件 | 指标已采集 | 有专属告警 |
|---|---|---|
| ceph-csi-rbd | ✅ 4 target | ⚠️ `CephCSIOperationErrors` 引用的指标不存在（死规则）|
| cert-manager | ✅ 3 target | ✅ 3 条自研规则 |
| tekton-pipelines | ✅ 部分 | ❌ `TektonPipelineRunFailed` / `TektonTaskRunFailed` 引用的指标不存在 |
| traefik | ✅ 1 target | ⚠️ 仅 `TraefikHigh5xxRate`（指标名 `traefik_service_requests_total` 存在，但规则可能写错字段）|
| n8n | ❌ | ❌ **告警出口本身无监控** |
| allnoy | ✅ 6 target | ✅ 本轮已加 3 条 |
| Tempo | ✅ 12 target | ✅ 本轮已加 19 条（Ceph 告警覆盖）|
| **Loki** | ❌ **0** | ❌ **0** |
| **VPA** | ❌ 0 | ❌ 0 |
| **Knative（12 个）** | ❌ 9 个 0 | ❌ 0 |

---

## 五、优先级建议

### 🔴 P0 — Loki 全套（6 个组件）

**理由**：日志链路是三大信号之一，当前完全是黑盒。Alloy 挂了能告警，但「Alloy 正常、Loki 拒收」「Loki 查询变慢」这类问题无法发现。

**动作**：一个 ServiceMonitor 覆盖 6 个组件。
```yaml
# 每个组件需单独 ServiceMonitor（selector 不同），或用 relabel 合并
- port: http-metrics      # 3100/8080
- port: http-metrics      # cache 9150
- port: http-metrics      # canary 3500
```

配套告警（有了指标后）：
```promql
# 摄取速率归零
sum(rate(loki_distributor_bytes_received_total[5m])) == 0
# ingest chunk 堆积（内存压力）
max(loki_ingester_memory_chunks) > 30000
# 查询延迟高
histogram_quantile(0.95, sum(rate(loki_request_duration_seconds_bucket[5m]))) > 2
# cache 未命中（查询慢的常见原因）
rate(loki_cache_hits[5m]) / rate(loki_cache_requests[5m]) < 0.8
```

### 🟠 P1 — Knative（12 个组件）

统一用 `metrics:9090` 端口，配一个带 `namespace` 维度的通用 PodMonitor + relabel 合并成一个 job，再补：
```promql
# Knative 请求延迟高
histogram_quantile(0.95, sum(rate(knative_request_count_sum...))) > 1
# 队列积压
max(knative_queue_depth) > 100
```

### 🟠 P1 — VPA（3 个组件）

```yaml
- port: prometheus     # 8942/8943/8944
```

配套告警：
```promql
# VPA 推荐值异常
vpa_recommender_container_requests{recommender=~".*"} > <limit>
# 驱逐风险
increase(vpa_evictions_total[1h]) > 0
```

### 🟡 P2 — 其他

| 优先级 | 动作 |
|---|---|
| 2 | 给 `n8n` / `nfs-provisioner` 加 KSM 通用告警（n8n 是告警出口，挂了告警静默）|
| 2 | 补 `metrics-server`（HPA 数据源）|
| 3 | 补 `tekton-triggers-webhook`（9000）|
| 3 | 清理 `default` 下的 Knative demo（hello-0000X / report-processor / netshoot-debug）—— 无监控价值且 report-processor 正在反复 503 |

---

## 六、一个更根本的观察

盘点下来发现一个模式：**监控覆盖率的提升一直依赖「我临时加了一条规则」，而不是系统性机制**。

这几轮加的：
- Tempo 19 条规则 → 因为发现 Tempo 空转
- Loki/calico/metallb/argocd 11 条 → 因为发现这些组件零告警
- 重启类 3 条 → 因为发现没人管重启
- Traefik OTLP → 因为发现 traces 没数据

每次都是**先出故障（或我怀疑有故障）→ 再补监控**。结果就是：
- 补的地方很扎实（方案 A 选了 Traefik 而不是随便挑一个）
- 没补的地方依然是黑盒

**建议做一次机制化收口**：
1. 用脚本定期对账「workload 列表 vs ServiceMonitor 列表」，输出差集
2. 新增 Deployment 时强制要求配套 monitor（Admission Webhook 或 CI 检查）
3. 告警规则上线前自动验证引用的指标是否存在（我前几轮反复手工做这件事）

---

## 七、验证命令

```bash
# 全量 workload 列表
kubectl get deploy,sts,ds -A

# 现有 monitor 覆盖了谁
kubectl get servicemonitor,podmonitor -A

# 差集（无 monitor 的 workload）
# 脚本：/root/.hermes/cache/scratch/verify_gaps.py

# 验证某组件指标是否为 0
P=prometheus-prometheus-prometheus-0
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(loki_build_info)'

# 列出集群已有指标名前缀，排查可用信号
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]'
```

---

*盘点时间：2026-10-02 13:30 ~ 14:00。结论：90 个工作负载中 44 个有效监控（49%），27 个「暴露了 metrics 但没配 monitor」属真正漏配，其中 Loki 全套（6 个）零采集为最高优先级缺口。*
