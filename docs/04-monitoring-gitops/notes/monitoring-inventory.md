# 集群监控完整资源清单

- **生成时间**：2026-10-02 14:45
- **集群**：Kubernetes v1.29.8，6 节点（与 Ceph 共生于一台 PVE 宿主机 10.0.0.1）
- **监控栈**：kube-prometheus-stack 83.7.0 / prometheus-operator v0.90.1 / Prometheus v3.11.2
- **最终状态**：✅ **125 targets 全部 up / 63 groups / 326 rules / health 全部 ok / 0 down**
- **覆盖率**：从 44/90（49%）提升至 **64/77（83%）**，剩余 13 个无 metrics 端点，已用 KSM 通用告警兜底

---

## 一、监控范围总览

| 层 | 组件 | 采集方式 | targets |
|---|---|---|---|
| **指标** | Prometheus 自监控 + Operator | ServiceMonitor | 4 |
| | kube-state-metrics | ServiceMonitor | 1 |
| | node-exporter | ServiceMonitor（DaemonSet） | 6 |
| | kubelet | ServiceMonitor（3 endpoint × 6 节点） | 18 |
| | apiserver / etcd / scheduler / controller-manager / kube-proxy / coredns | ServiceMonitor | 20 |
| **日志** | Grafana Alloy | ServiceMonitor（DaemonSet） | 6 |
| | Loki 6 组件 | PodMonitor | 8 |
| | Tempo 8 组件 | PodMonitor | 12 |
| **链路** | otel-collector | ServiceMonitor | 2 |
| | Traefik（OTLP 接入） | PodMonitor | 1 |
| **存储** | Ceph mgr | ScrapeConfig | 1 |
| **应用平台** | ArgoCD / cert-manager / ceph-csi / cnpg / strimzi / tekton / knative / traefik / metallb | Service+PodMonitor | 36 |

---

## 二、完整采集清单（62 个 job / 125 targets）

| NAMESPACE | JOB | TARGETS |
|---|---|---|
| ? | `ceph-mgr` | 1 |
| argocd | `argocd/argocd` | 5 |
| ceph-csi-rbd | `ceph-csi-rbd-nodeplugin-http-metrics` | 3 |
| ceph-csi-rbd | `ceph-csi-rbd-provisioner-http-metrics` | 1 |
| cert-manager | `cert-manager` | 1 |
| cert-manager | `cert-manager-cainjector` | 1 |
| cert-manager | `cert-manager-webhook` | 1 |
| cicd | `cicd/tekton-eventlistener` | 1 |
| cnpg-system | `cnpg-system/cnpg-controller-manager` | 1 |
| default | `apiserver` | 3 |
| kafka | `kafka/strimzi-cluster-operator` | 1 |
| knative-eventing | `kafka-broker-ingress` | 1 |
| knative-eventing | `kafka-webhook-eventing` | 1 |
| knative-eventing | `knative-eventing/knative-eventing-controlplane` | 3 |
| knative-eventing | `knative-eventing/knative-eventing-webhook` | 1 |
| knative-eventing | `knative-eventing/knative-job-sink` | 1 |
| knative-eventing | `knative-eventing/knative-kafka-controller` | 1 |
| knative-eventing | `knative-eventing/knative-pingsource-adapter` | 1 |
| knative-operator | `knative-operator/knative-operator` | 2 |
| knative-operator | `knative-operator/knative-operator-webhook` | 1 |
| knative-serving | `knative-serving/knative-autoscaler` | 1 |
| knative-serving | `knative-serving/knative-autoscaler-hpa` | 1 |
| knative-serving | `knative-serving/knative-kourier-controller` | 1 |
| knative-serving | `knative-serving/knative-serving-controller` | 1 |
| knative-serving | `knative-serving/knative-serving-webhook` | 1 |
| kube-system | `coredns` | 2 |
| kube-system | `kube-controller-manager` | 3 |
| kube-system | `kube-etcd` | 3 |
| kube-system | `kube-proxy` | 6 |
| kube-system | `kube-scheduler` | 3 |
| kube-system | `kube-system/vpa-admission` | 2 |
| kube-system | `kube-system/vpa-recommender` | 2 |
| kube-system | `kube-system/vpa-updater` | 2 |
| kube-system | `kubelet` | 18 |
| logging | `alloy` | 6 |
| logging | `backend-scheduler` | 1 |
| logging | `backend-worker` | 1 |
| logging | `block-builder` | 3 |
| logging | `distributor` | 1 |
| logging | `live-store` | 3 |
| logging | `logging/loki-backend` | 1 |
| logging | `logging/loki-canary` | 3 |
| logging | `logging/loki-chunks-cache` | 1 |
| logging | `logging/loki-read` | 1 |
| logging | `logging/loki-results-cache` | 1 |
| logging | `logging/loki-write` | 1 |
| logging | `metrics-generator` | 1 |
| logging | `querier` | 1 |
| logging | `query-frontend` | 1 |
| metallb-system | `metallb-system/metallb-controller` | 1 |
| monitoring | `kube-state-metrics` | 1 |
| monitoring | `node-exporter` | 6 |
| monitoring | `prometheus-alertmanager` | 2 |
| monitoring | `prometheus-grafana` | 1 |
| monitoring | `prometheus-operator` | 1 |
| monitoring | `prometheus-prometheus` | 2 |
| opentelemetry | `otel-collector` | 1 |
| opentelemetry | `otel-collector-monitoring` | 1 |
| tekton-pipelines | `tekton-events-controller` | 1 |
| tekton-pipelines | `tekton-pipelines-controller` | 1 |
| tekton-pipelines | `tekton-pipelines-webhook` | 1 |
| tekton-pipelines | `tekton-triggers-controller` | 1 |
| tekton-pipelines-resolvers | `tekton-pipelines-resolvers/tekton-pipelines-resolvers` | 1 |
| traefik | `traefik/traefik` | 1 |
**按 namespace 汇总**

| NAMESPACE | TARGETS | 说明 |
|---|---|---|
| kube-system | 41 | 控制面 + kubelet + VPA + coredns |
| logging | 26 | Alloy 6 + Loki 8 + Tempo 12 |
| monitoring | 13 | 监控栈自监控 |
| knative-eventing | 9 | Kafka Broker / Webhook / Controller / Sink / Pingsource |
| argocd | 5 | ArgoCD 5 组件 |
| knative-serving | 5 | Controller / Webhook / Autoscaler / HPA / Kourier |
| ceph-csi-rbd | 4 | Nodeplugin 3 + Provisioner 1 |
| tekton-pipelines | 4 | Pipeline/Event/Triggers Controller + Webhook |
| cert-manager | 3 | 3 组件 |
| knative-operator | 3 | Operator + Webhook |
| opentelemetry | 2 | Collector + 自监控 |
| default | 3 | apiserver（运行在 default ns） |
| cicd / cnpg-system / kafka / metallb-system / tekton-pipelines-resolvers / traefik | 各 1 | 平台组件 |
| （无 namespace） | 1 | ceph-mgr（S3 直连） |
| **合计** | **125** | |

---

## 三、本轮新增的监控资源

### 3.1 PodMonitor（20 个，全部新建）

| NAMESPACE | NAME | 组件 | 端口 |
|---|---|---|---|
| logging | `loki-write` | Loki Ingester | http-metrics:3100 |
| logging | `loki-backend` | Loki Compactor/Index Gateway | http-metrics:3100 |
| logging | `loki-read` | Loki Querier | http-metrics:3100 |
| logging | `loki-chunks-cache` | chunk 缓存 | http-metrics:9150 |
| logging | `loki-results-cache` | 结果缓存 | http-metrics:9150 |
| logging | `loki-canary` | Canary 自检 | http-metrics:3500 |
| kube-system | `vpa-recommender` | VPA 副本推荐 | prometheus:8942 |
| kube-system | `vpa-updater` | VPA 扩缩容执行 | prometheus:8943 |
| kube-system | `vpa-admission` | VPA Admission | prometheus:8944 |
| knative-serving | `knative-serving-controller` | Controller | metrics:9090 |
| knative-serving | `knative-serving-webhook` | Webhook | metrics:9090 |
| knative-serving | `knative-autoscaler` | Autoscaler | metrics:9090 |
| knative-serving | `knative-autoscaler-hpa` | HPA Autoscaler | metrics:9090 |
| knative-serving | `knative-kourier-controller` | 网络控制器 | metrics:9090 |
| knative-eventing | `knative-eventing-webhook` | Eventing Webhook | metrics:9090 |
| knative-eventing | `knative-kafka-controller` | Kafka Controller | metrics:9090 |
| knative-eventing | `knative-job-sink` | Job Sink | metrics:9092 |
| knative-eventing | `knative-pingsource-adapter` | PingSource | metrics:9090 |
| knative-operator | `knative-operator` | Operator | metrics:9090 |
| knative-operator | `knative-operator-webhook` | Operator Webhook | metrics:9090 |

> **曾创建但已删除 2 个**：`loki-gateway`（nginx 反代无 metrics）、`argocd-dex-server`（只监听 gRPC 48318）。二者改由 KSM 通用告警兜底。

### 3.2 ConfigMap（4 个）—— 本轮最关键的非 YAML 改动

| NAMESPACE | NAME | 新增键 |
|---|---|---|
| knative-serving | `config-observability` | `metrics-protocol: prometheus` |
| knative-eventing | `config-observability` | `metrics-protocol: prometheus` |
| knative-operator | `config-observability` | `metrics-protocol: prometheus` |
| tekton-pipelines | `config-observability-triggers` | `metrics-protocol: prometheus` |

**为什么必须改这个**：Knative 1.22 / Tekton 的 `metrics:9090` 端口在 Pod spec 里**声明了但默认不监听**。必须通过 ConfigMap 的 `metrics-protocol: prometheus` 显式开启。设置后还需重启组件——**部分 Pod 数月未重启**（`autoscaler-hpa` 是 2026-06-05 启动的），不重启读不到新配置。

### 3.3 PrometheusRule（新建 1 个 / 12 条规则）

**`monitoring/bsm-coverage-alerts`** — 覆盖所有无 metrics 端点的组件：

| GROUP | 规则 | 覆盖组件 |
|---|---|---|
| bsm.availability | `CoreComponentNotReady` | 15 个 ns 全部核心 Pod（通用兜底） |
| | `CNIComponentNotReady` | calico-node × 6 |
| | `CNIKubeControllersDown` | calico-kube-controllers |
| | `MetalLBSpeakerNotReady` | metallb speaker × 5 |
| | `AlertReceiverDown` | **n8n（告警出口本身）** |
| | `StorageProvisionerDown` | nfs-provisioner |
| | `KubeVIPDown` | kube-vip-ds |
| | `GitOpsRedisDown` | argocd-redis |
| | `KafkaEntityOperatorDown` | kafka entity-operator |
| | `TektonInterceptorsDown` | tekton-triggers-core-interceptors |
| | `PodCrashLoopingFixed` | 通用 CrashLoopBackOff（比 rate() 可靠） |
| bsm.coverage | `DaemonSetNotFullyScheduled` | 日志采集/CNI 节点覆盖率 |

### 3.4 其他

| 对象 | 变更 |
|---|---|
| `deployment/traefik` | 4 个 tracing 参数（OTLP 接入，方案 A） |
| Prometheus CR | 尝试开 OTLP receiver **失败**（Helm 管理，Operator reconcile 会重置），已放弃 Knative request-metrics push 方案 |
| 临时探针 Pod | 清理 3 个（loki-ilm-reinit / node-debugger / probe-tempo-verify） |

---

## 四、无法覆盖的部分

| 组件 | 原因 | 替代 |
|---|---|---|
| `logging/loki-gateway` | nginx 反代，无 Prometheus 端点 | `CoreComponentNotReady` |
| `argocd/argocd-dex-server` | 只监听 gRPC 48318 | `CoreComponentNotReady` |
| `tekton-triggers-webhook` | `metrics:9000` 未响应（与 Knative 不同机制） | `CoreComponentNotReady` |
| `kubernetes-dashboard` | 无 metrics 端点 | 实验环境可忽略 |
| `tekton-dashboard` | 无 metrics 端点 | 实验环境可忽略 |
| `default/netshoot-debug` | 调试用 | 建议删除 |
| `default/hello-0000X`（3 个）| Knative demo | 建议清理 |
| `default/report-processor` | Knative demo，正在反复 503 | 建议清理 |
| `default/autoscale-demo` | Knative demo | 建议清理 |
| Prometheus OTLP receiver | CR 被 Helm 管理会被覆盖 | Knative request-metrics 暂不启用 |

---

## 五、查看方法

### 5.1 采集目标

```bash
P=prometheus-prometheus-prometheus-0

# 全部 target
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '.data.activeTargets[]|"\(.labels.job) \(.labels.instance) \(.health)"'

# 按 job 统计
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '[.data.activeTargets[].labels.job]|group_by(.)|map("\(.[0])=\(length)")|.[]'

# 只看 down
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '.data.activeTargets[]|select(.health!="up")|"\(.labels.job) \(.lastError)"'

# 生成的 scrape config(39→62 job)
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/status/config' | jq -r '.data.yaml' | grep -c 'job_name:'
```

### 5.2 告警规则

```bash
# 规则库总览
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | \
  jq -r '"\(.data.groups|length) groups / \([.data.groups[].rules[]]|length) rules"'

# health 分布(查解析失败)
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | \
  jq -r '[.data.groups[].rules[].health]|group_by(.)[]|"\(.[0])=\(length)"'

# 查某条规则(API 不返回 expr,必须从 CR 读)
kubectl get prometheusrule -n monitoring -o json | \
  jq -r '.items[]|select(.metadata.name=="bsm-coverage-alerts")|.spec.groups[].rules[]|"\(.alert): \(.expr)"'

# 当前告警
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts' | \
  jq -r '.data.alerts[]|"\(.state) \(.labels.severity) \(.labels.alertname)"'
```

### 5.3 监控配置对象

```bash
kubectl get servicemonitor -A      # 23 个
kubectl get podmonitor -A          # 30 个(新增 20)
kubectl get scrapeconfig -A        # 1 个(ceph-mgr)
kubectl get prometheusrule -A      # 40 个 CR / 326 条规则

# Prometheus 选择器(决定哪些 monitor 生效)
kubectl get prometheus prometheus-prometheus -n monitoring -o json | \
  jq '.spec|{podMonitorSelector,serviceMonitorSelector,scrapeConfigSelector,ruleSelector}'
```

### 5.4 Grafana 里怎么看

- 指标：Grafana → Prometheus 数据源（4 个数据源已全部原生 provisioning）
- 日志：Grafana → Loki 数据源（需带 `X-Scope-OrgID: fake`）
- 链路：Grafana → Tempo 数据源（**注意时间范围**，block_retention 仅 48h）

---

## 六、备份与回滚

```
/root/full-coverage-backup-20261002-141745/     本轮改动前全量
├── monitors.json         (ServiceMonitor + PodMonitor + ScrapeConfig)
└── prometheusrules.json  (39 个 PrometheusRule)

/root/alert-fix-backup-20261001-214359/         上一轮告警修复前
/root/traefik-otlp-backup-20261002-125718/      Traefik OTLP 接入前
```

**回滚 Knative/Tekton metrics 开关**：
```bash
kubectl patch cm config-observability -n knative-serving --type=merge -p '{"data":{"metrics-protocol":null}}'
kubectl patch cm config-observability -n knative-eventing --type=merge -p '{"data":{"metrics-protocol":null}}'
kubectl patch cm config-observability -n knative-operator  --type=merge -p '{"data":{"metrics-protocol":null}}'
kubectl patch cm config-observability-triggers -n tekton-pipelines --type=merge -p '{"data":{"metrics-protocol":null}}'
# 然后重启对应组件
```

---

## 七、维护建议

### 7.1 定期对账

```bash
kubectl get deploy,sts,ds -A -o name          # 所有 workload
kubectl get servicemonitor,podmonitor,scrapeconfig -A
python3 /root/.hermes/cache/scratch/inventory.py    # 本轮对账脚本(可复用)
python3 /root/.hermes/cache/scratch/verify_gaps.py
```

### 7.2 新增组件检查清单

1. 是否暴露 `/metrics`？端口多少？
2. 暴露了 → 无 Service 用 PodMonitor，有 Service 用 ServiceMonitor
3. 没暴露 → 确认是否在 `CoreComponentNotReady` 的 namespace 范围内
4. **规则上线前必须实跑验证引用指标存在**（本项目已因此产生 47 条静默失效规则）

### 7.3 已知遗留（不影响当前覆盖）

| # | 项目 |
|---|---|
| 1 | Tempo 组件无持久化（live-store/block-builder/distributor 全挂 emptyDir） |
| 2 | Tempo `block_retention: 48h` 与指标 5d / 日志 7d 不匹配 |
| 3 | 47 条历史失效规则未处理（Tekton/Strimzi/Ceph/CNPG 补采指标） |
| 4 | 监控配置未纳入 GitOps（全部手动 apply） |
| 5 | 两条重启告警永久误报（累计计数，频繁开关机环境必然 firing） |

---

*清单生成时间：2026-10-02 14:45。125 targets 全部 up，326 条规则 health 全部 ok，0 down。覆盖从 49% 提升至 83%。*
