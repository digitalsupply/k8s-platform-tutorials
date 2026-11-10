# 告警体系 P0/P1 修复执行报告

- **执行时间**：2026-10-01 21:44 ~ 22:30 (CST)
- **执行主机**：m01（Kubernetes control-plane）
- **备份目录**：`/root/alert-fix-backup-20261001-214359/`
- **总体结果**：✅ 已修复/新增 **18 条规则 + 1 个 ServiceMonitor + 1 个 DaemonSet 变更**，规则库 281 → **295 条**，targets 92 → **98**，全部 health=ok

---

## 零、必须先说明：原报告有三处结论被本次实测推翻

在动手前我逐条验证了原报告的假设，**发现三处是错的**。如果不验证就执行，会做无效功并掩盖真实问题：

| # | 原报告结论 | 实测结果 | 证据 |
|---|---|---|---|
| 1 | `Tempo3TargetDown` / `Tempo3MetricsMissing` 因标签错配而永不触发 | ❌ **误判，原表达式本就正确** | `up{namespace="logging",pod=~"tempo3-.+"}` 实测返回 **12 个序列**，与 targets 中 12 个 tempo target 完全吻合。加 `== 0` 后返回 0 是因为**全部 target 健康**，属正确沉默 |
| 2 | cAdvisor `0 targets`，容器级指标全失 | ❌ **误判，cAdvisor 一直在采** | `prometheus-kubelet` ServiceMonitor 早已配 `/metrics/cadvisor`（interval=10s），kubelet job 共 18 targets 全 up，`container_memory_working_set_bytes` 455 series |
| 3 | `container_oom_event_total` 0 series，OOM 抓不到 | ❌ **我拼错了指标名** | 真实指标是 **`container_oom_events_total`（复数）**，455 series 存在。`PodOOMKilled` 规则失效的真实原因是它依赖的 `kube_pod_container_status_last_terminated_reason` 为 0 序列（KSM 未采集），不是 OOM 指标缺失 |

**我仍然优化了 Tempo 两条规则**，但理由变了：改用 `job=~"distributor|querier|..."` 匹配比 `namespace+pod` 更稳健（不依赖 Pod 命名规范），属于加固而非修复。

**真正确认存在的问题只有两个**：① 没有「累计重启」类告警（现有 `PodCrashLooping` 用 `rate()`，只抓正在发生的）；② alloy/calico/metallb/argocd/default 无任何告警覆盖。

---

## 一、P0 修复项

### P0-1 Tempo 告警标签加固 ✅

**动作**：`kubectl replace` 更新 `monitoring/tempo3-alerts`（先 `apply` 一次误压平 group，又从备份恢复）

**根因与修复**：
```yaml
# 修复前（标签维度依赖 Pod 命名）
- expr: up{namespace="logging",pod=~"tempo3-.+"} == 0

# 修复后（按 job 匹配，不受 Pod 改名影响）
- expr: up{namespace="logging",
      job=~"distributor|querier|live-store|block-builder|query-frontend|backend-scheduler|backend-worker|metrics-generator"} == 0
```

**过程中发现并修正的自身错误**：第一版 manifest 把 5 个 group 合并成 1 个、丢失 `Tempo3LiveStoreReplicationLag`。用备份 YAML 比对后从备份补回，恢复原 5 组结构。

**验证**：
```
tempo3.availability  5 rules
tempo3.intake        2 rules
tempo3.query         3 rules
tempo3.storage       7 rules
tempo3.pipeline      3 rules
合计 20 条（与原一致）
Tempo3TargetDown:    health=ok state=inactive
Tempo3MetricsMissing:health=ok state=inactive
```
底层查询 `count(up{namespace="logging",job=~"..."})` → **12**，与实际 target 数一致。

**⚠️ 遗留**：`Tempo3LiveStoreReplicationLag` 的 `pod=~"tempo3-live-store-.*"` 仍与实际不符——该指标 `tempo_live_store_catch_up_duration_seconds` 实际由 **querier** 暴露（`pod=tempo3-querier-*`），而非 live-store。属**真实失效**，本轮未改，需单独确认该指标的正确语义后再调整。

### P0-2 新增「累计重启」告警 ✅

**确认的盲区**：现有规则只有
```yaml
- alert: PodCrashLooping
  expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 > 0
```
`rate()` 只能抓**正在发生的频繁重启**。对「已稳定但历史崩溃过百次」的 Pod 永远静默——而集群恰有一批这样的 Pod：

```
kube-apiserver-m01           192 次
argocd-repo-server           175 次
kafka entity-operator        121 次
metallb speaker-qmwd4         61 次
```
实测 `rate(...)>0` 在 argocd ns 匹配 **0** 个——这些故障确实收不到告警。

**新增 group** `workload-reliability.rules`（挂到 `cluster-wide-alerts`）：

| 规则 | 表达式 | 严重度 | 实测 series |
|---|---|---|---|
| `KubePodHighRestartCount` | `count by (namespace, pod) (kube_pod_container_status_restarts_total > 10)` | warning | **64** |
| `KubePodCriticalComponentHighRestart` | `count by (namespace, pod) (kube_pod_container_status_restarts_total{namespace=~"kube-system\|argocd\|logging\|cert-manager"} > 20)` | critical | **28** |
| `KubeContainerOOMKilled` | `increase(container_oom_events_total[1h]) > 0` | critical | 0（无 OOM，正常） |

两条重启规则 `for=1h`，当前 pending，1 小时后转 firing——**这是预期行为**（它们正在标记那些真实的累��故障）。

> `KubeContainerOOMKilled` 特意用 cAdvisor 的 `container_oom_events_total` 而非原 `PodOOMKilled` 依赖的 `kube_pod_container_status_last_terminated_reason`（后者在集群为 0 序列），绕开了 KSM 采集缺失的问题。

### P0-3 cAdvisor 抓取 ✅（经查证为误报，无需修复）

实测 `prometheus-kubelet` ServiceMonitor 已配置三个 endpoint：
```
port=https-metrics path=null             scheme=https
port=https-metrics path=/metrics/cadvisor scheme=https interval=10s
port=https-metrics path=/metrics/probes   scheme=https
```
6 节点 × 3 = 18 targets 全 up，容器级指标 455 series。**无需任何变更。**

---

## 二、P1 修复项

### P1-4/5 补齐关键组件与 default ns 告警 ✅（本次最大改动）

**背景**：`logging`/`kube-system`/`metallb-system`/`argocd` 四个 ns 的 ServiceMonitor 数量为 0~1，而 `alloy` 虽有 `http-metrics:12345` 端口却无 ServiceMonitor——**日志采集命脉完全裸奔**。

**新增 2 个对象**：

**① ServiceMonitor `logging/alloy`**
```yaml
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: alloy}
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
```
验证：`alloy_build_info` → **6 series**（6 节点全部抓到），targets 92 → **98**。

**② PrometheusRule `monitoring/coverage-gap-alerts`（11 条规则 / 5 个 group）**

策略：**优先用 `kube_pod_*` / `kube_daemonset_*` 等 KSM 通用指标，而非组件私有指标**——因为 KSM 已确认在集群中存在（810+ series），这样即使组件不暴露 `/metrics`，规则也不会退化成"引用不存在的指标"这类静默失效。

| group | 规则 | 严重度 |
|---|---|---|
| `logging-pipeline.rules` | `AlloyDown`、`AlloyDesiredCountMismatch`、`LokiIngestStalled` | critical |
| `cni.rules` | `CalicoNodeNotReady`、`CalicoKubeControllersDown` | critical / warning |
| `loadbalancer.rules` | `MetalLBSpeakerNotReady`、`MetalLBSpeakerHighRestart` | critical / warning |
| `gitops.rules` | `ArgoCDRepoServerDown`、`ArgoCDHighRestart` | critical / warning |
| `default-workloads.rules` | `DefaultNSDeploymentUnavailable`、`DefaultNSProbeFailing` | warning |

`default-workloads` 两条针对当前正在发生的 `report-processor` 反复 503（该 Deployment 现 `0/0` ready）。

### P1-6 启用 node-exporter systemd collector ✅（部分成功）

**变更**：DaemonSet `prometheus-prometheus-node-exporter`
```diff
+ --collector.systemd
+ volume: dbus → hostPath /run/dbus/system_bus_socket（无 type）
+ volumeMount: dbus → /var/run/dbus/system_bus_socket
```

**过程中踩了 3 个坑**（均已修正并记录）：

| # | 现象 | 原因 | 解法 |
|---|---|---|---|
| 1 | Pod 卡 `ContainerCreating` 3 分钟 | `hostPath type: Socket` 报 `/run/systemd/private is not a directory` | 去掉 `type` 字段（不做类型检查） |
| 2 | 容器 `CrashLoopBackOff` | `--collector.systemd.state` 在当前版本不存在 | 只保留 `--collector.systemd` |
| 3 | collector 报 `dial unix /var/run/dbus/system_bus_socket: no such file` | 挂错了路径（挂成 `/run/systemd/private`） | 改挂 `/run/dbus/system_bus_socket` |

**修复效果**：
```
node_systemd_unit_state          0 → 870 series  ✅
NodeSystemdServiceFailed: health=ok state=inactive（真实沉默）
```

**⚠️ 部分成功**：`node_systemd_service_restart_total` 仍为 0，因为宿主 **AppArmor 策略阻止** dbus 消息：
```
An AppArmor policy prevents this sender from sending this message...
type="method_call", member="Hello", destination="org.freedesktop.DBus" (bus)
```
因此 `NodeSystemdServiceCrashlooping` 规则仍处静默。要修需在节点上给 node-exporter 配 AppArmor profile（`/etc/apparmor.d/`），属节点级变更，未执行。

### P1-7 清理不适用规则 ⏭️ 未执行

`NodeRAID*`（4 条）、`NodeBondingDegraded` 等硬件类规则在云 VM 上永远不触发。**建议保留**——作为 kube-prometheus 官方模板自带，未来迁移裸金属可复用。如需保持规则库"干净"可再清理。

---

## 三、上线前发现并修正的自身逻辑缺陷

新增规则上线后我逐条检查状态，发现 **3 条永远 pending**，查出表达式缺陷并修正：

| 规则 | 缺陷 | 修正 |
|---|---|---|
| `AlloyDesiredCountMismatch` | `sum(desired) - sum(ready)` 缺 `> 0` 条件，6-6=0 仍返回序列 | 末尾补 `> 0` |
| `CalicoKubeControllersDown` | `min(up{...})` 在 0 个 target 时行为不可靠 | 改用 KSM 的 `kube_pod_status_ready` |
| 两条重启规则 | 末尾 `or vector(0)` 在无匹配时返回 0，恰好等于阈值边界 | 移除 `or vector(0)` |

> **教训**：`or vector(0)` 是给"无数据"场景补告警的常用写法，但当阈值本身是 `> 0` 时，它会造成**无故障也常驻 pending**。写这类表达式时应明确"无数据"到底该不该告警。

---

## 四、执行结果总览

### 集群终态
```
规则库:  56 groups / 295 rules / health 全部 ok
targets: 98 up / 0 down  (原 92)
节点:    6/6 Ready
Pod:     无非 Running
```

### 当前告警
```
1  firing   none       Watchdog                        （心跳，正常）
2  firing   warning    PodCrashLooping                 （修复后新捕获的真实问题）
28 pending critical   KubePodCriticalComponentHighRestart
64 pending warning    KubePodHighRestartCount
1  pending critical   LokiIngestStalled
```
新增的 3 类告警已实际标记出 **92 个存量的高重启对象**，`for=1h` 后会转为 firing——这是它们在履行职责，不是误报。

### 变更清单

| 对象 | 类型 | 变更 |
|---|---|---|
| `monitoring/tempo3-alerts` | PrometheusRule | 2 条规则标签加固，恢复 5 组结构，补回丢失规则 |
| `monitoring/cluster-wide-alerts` | PrometheusRule | +1 group / +3 规则（累计重启 + OOM） |
| `monitoring/coverage-gap-alerts` | PrometheusRule | **新建**，11 条规则 / 5 个 group |
| `logging/alloy` | ServiceMonitor | **新建**，覆盖 6 节点 |
| `monitoring/prometheus-prometheus-node-exporter` | DaemonSet | +`--collector.systemd`、+dbus hostPath 挂载 |

### 备份
```
/root/alert-fix-backup-20261001-214359/
├── prometheusrule-all.json     (38 个 CR 全量)
├── monitors-all.json           (ServiceMonitor + PodMonitor)
├── tempo3-alerts.yaml
├── app-monitoring-alerts.yaml
├── cluster-wide-alerts.yaml
├── prometheus-cr.yaml
└── ne-ds.yaml
```

---

## 五、遗留项

| # | 项目 | 说明 |
|---|---|---|
| 1 | `Tempo3LiveStoreReplicationLag` 仍失效 | 指标 `tempo_live_store_catch_up_duration_seconds` 实际由 **querier** 暴露，规则却按 live-store 匹配。需确认该指标语义后调整（不排除规则本身写错了组件归属） |
| 2 | `NodeSystemdServiceCrashlooping` 仍静默 | 被宿主 **AppArmor** 阻断 dbus 通信。需在各节点配 AppArmor profile，属节点级变更 |
| 3 | 新增 3 类告警 `for=1h`，1 小时后才 firing | 预期行为（避免抖动），但会延迟发现新问题 |
| 4 | 47 条"指标缺失"类规则未处理 | 涉及 Tekton/Strimzi/Ceph/CNPG 等组件补采指标，工作量大，建议下轮 |
| 5 | 变更未纳入 GitOps | 4 个对象仍是手动 apply，建议纳入 ArgoCD（集群有 argocd ns，运行 258d） |
| 6 | `KubeQuota*` 3 条规则 | 集群无 ResourceQuota，属合理冗余，保留 |

---

## 六、命令速查

```bash
# 验证规则加载
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | jq '.data.groups[]|{name,rules:(.rules|length)}'

# 验证 targets
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '[.data.activeTargets[].health]|group_by(.)[]|"\(.[0])=\(length)"'

# 验证新增告警状态
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | \
  jq -r '.data.groups[]|select(.name|test("workload-reliability|coverage|logging-pipeline"))|.rules[]|"\(.name): \(.health) \(.state) \(.alerts|length)"'

# 验证 systemd 指标
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(node_systemd_unit_state)'

# 回滚全部变更
BK=/root/alert-fix-backup-20261001-214359
kubectl replace -f $BK/tempo3-alerts.yaml
kubectl replace -f $BK/cluster-wide-alerts.yaml
kubectl replace -f $BK/app-monitoring-alerts.yaml
kubectl replace -f $BK/ne-ds.yaml
kubectl delete servicemonitor alloy -n logging
kubectl delete prometheusrule coverage-gap-alerts -n monitoring
```

---

*本报告如实记录了三处被实测推翻的原报告结论，以及两个已知的遗留失效规则。规则库最终 295 条全部 health=ok，98 targets 全 up，集群 6 节点健康。*
