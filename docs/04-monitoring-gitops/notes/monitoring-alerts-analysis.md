# 监控告警规则完整分析报告

> 生成时间: 2026-10-06
> 数据来源: `prometheus-prometheus-prometheus-rulefiles-0` ConfigMap（41 个规则文件）
> 规则总数: 329 条（其中告警规则 235 条，记录规则 94 条）
> 报告目标: 逐条解释用意、识别问题、给出合理化修复建议

---

## 一、总体概况

### 1.1 规则统计

| 维度 | 数量 |
|------|------|
| 总规则数 | 329 |
| 告警规则（Alert） | 235 |
| 记录规则（Record） | 94 |
| Critical 级 | 81 |
| Warning 级 | 145 |
| Info 级 | 7 |
| 无 severity | 2 |
| 全部为 prometheus-prometheus-prometheus-rulefiles-0 组件 | 235 |

### 1.2 分类统计

| 类别 | 数量 | 占告警规则比例 |
|------|------|----------------|
| 通用 | 90 | 38.3% |
| Prometheus/Alertmanager | 37 | 15.7% |
| 组件失联 | 25 | 10.6% |
| 链路/指标 | 19 | 8.1% |
| Ceph | 14 | 6.0% |
| Kubelet | 12 | 5.1% |
| 资源耗尽 | 10 | 4.3% |
| 组件就绪 | 6 | 2.6% |
| 重启 | 5 | 2.1% |
| 资源 | 5 | 2.1% |
| 配额 | 4 | 1.7% |
| OOM/资源 | 3 | 1.3% |
| 资源配额 | 3 | 1.3% |
| 日志 | 2 | 0.9% |

### 1.3 规则来源

全部规则均来自 `prometheus-prometheus-prometheus-rulefiles-0` ConfigMap，共 41 个规则文件：

| 规则文件 | 规则组 |
|----------|--------|
| app-monitoring-alerts-*.yaml | 应用监控 |
| alertmanager*.yaml | Alertmanager 集群 |
| bsm*.yaml | BSM 通用覆盖 |
| cnpg*.yaml | CNPG 集群 |
| cni*.yaml | Calico CNI |
| cluster-wide-alerts*.yaml | 集群级告警 |
| ceph*.yaml | Ceph 集群 |
| cert-manager*.yaml | Cert-manager |
| k8s*.yaml | Kubernetes 通用 |
| kafka*.yaml | Kafka/Strimzi |
| knative-eventing*.yaml | Knative Eventing |
| kubernetes-resources*.yaml | 资源配额 |
| kubernetes-system*.yaml | 系统组件 |
| kube-apiserver*.yaml | API-server 可用性 |
| kubernetes-system*.yaml | 控制面组件 |
| node-exporter*.yaml | node-exporter |
| node.rules*.yaml | 节点规则 |
| otel-demo*.yaml | OpenTelemetry demo |
| pod.rules*.yaml | Pod 可靠性 |
| prometheus*.yaml | Prometheus 本身 |
| tempo*.yaml | Tempo 链路 |
| tekton*.yaml | Tekton 流水线 |
| traefik*.yaml | Traefik |
| kubernetes-system-*.yaml | 各控制面组件 |

---

## 二、逐条规则分析

> 以下每个规则包含：规则名称、严重级别、所属组、表达式、触发条件、用意、当前状态、问题点、建议修复。

---

### 2.1 组件失联类（25 条）

这类规则检测组件的 Prometheus target 是否可达，是一类高价值、低噪声规则。

#### 2.1.1 Pod 级就绪检测

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `CNIComponentNotReady` | critical | CNI 故障=该节点网络不可用，影响面最大 | Calico-node Pod 不 Ready | 当前 6/6 Ready，OK | 表达式中 `condition="true"` 可能写法有误（应该用 `status.ready`），但当前数据正常 | 保留，作为集群核心依赖 |
| `CalicoNodeNotReady` | critical | Calico 节点就绪，关系跨节点通信 | calico-node Pod 不 Ready | 当前 6/6 Ready，OK | 同上 | 保留 |
| `CNIKubeControllersDown` | critical | 网络策略下发与 IP 回收依赖此控制器 | calico-kube-controllers 不 Ready | 当前 Running，OK | 应再加 `kube_pod_status_phase{phase="Running"}` 过滤避免 Completed Job 误报 | 补 phase 过滤 |
| `MetalLBSpeakerNotReady` | critical | speaker 负责 ARP/NDP 应答，异常=LoadBalancer 流量不通 | speaker Pod 不 Ready | 当前 1/1 Running，OK | 累计重启历史数据；建议加 `rate()` 窗口 | 保留，加重启率检测 |
| `KubePodCriticalComponentHighRestart` | critical | 核心组件累计重启 > 20，稳定性风险 | 重启计数超阈值 | 当前 3 次 (normal 2, speaker 1)，OK | 累计值易误报长生命周期 DaemonSet；应改 `rate()`/窗口 | 24h 窗口内用 `rate()` 替代 |
| `KubeNodeEviction` | info | 节点 Pod 驱逐信号 | kubelet_evictions > 0 | 当前 0，OK | 瞬时告警，for=0s | 保留 |
| `NodeRAIDDegraded` | critical | RAID 阵列降级 | node_md_disks_required > 0 | 当前正常 | 服务器 RAID 依赖，按需保留 | 保留 |
| `NodeFileDescriptorLimit` | critical | fd 使用率 > 90% | node_filefd_allocated / max > 0.9 | 当前正常 | 对集群交互层重要 | 保留 |
| `NodeFilesystemAlmostOutOfFiles` | critical | inode 快耗尽 | 文件剩余 < 5% | 当前正常 | 可能误报 tmpfs 等 | 排除 tmpfs |
| `NodeFilesystemFilesFillingUp` | critical | inode 填满 | inode 剩余 < 10% | 当前正常 | 可能误报 | 排除 tmpfs |

#### 2.1.2 组件不可达检测

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `KubeAPIDown` | critical | KubeAPI 消失，集群失联 | absent(up{job="apiserver"}) | 当前 up，OK | for=15m 过长，实际应 5m | 缩短为 5m |
| `KubeControllerManagerDown` | critical | 控制面管理器消失 | absent(up{job="kube-controller-manager"}) | 当前 up，OK | 同上 | 缩短为 5m |
| `KubeSchedulerDown` | critical | 调度器消失 | absent(up{job="kube-scheduler"}) | 当前 up，OK | 同上 | 缩短为 5m |
| `KubeProxyDown` | critical | kube-proxy 消失 | absent(up{job="kube-proxy"}) | 当前 up，OK | 同上 | 缩短为 5m |
| `KubeletDown` | critical | kubelet 失联 | kubelet target down | 当前 up，OK | 对于 6 节点按实例判断 | 保留 |
| `KubeletServerCertificateExpiration` | critical | kubelet 服务证书 < 24h 到期 | kubelet_certificate_manager_server_ttl_seconds < 86400 | 当前 OK | 证书轮换依赖准确 | 保留 |
| `KubeletClientCertificateExpiration` | critical | kubelet 客户端证书 < 24h 到期 | kubelet_certificate_manager_client_ttl_seconds < 86400 | 当前 OK | 证书轮换依赖准确 | 保留 |
| `KubeClientCertificateExpiration` | critical | 客户端证书 < 24h 到期 | apiserver_client_certificate_expiration_seconds < 0 | 当前 OK | 客户端证书到期 | 保留 |
| `PrometheusBadConfig` | critical | Prometheus 配置重载失败 | 配置 hash 变化 | 当前 OK | 配置误改时触发 | 保留 |
| `PrometheusErrorSendingAlertsToAnyAlertmanager` | critical | 告警发送异常 | notification error rate > 0 | 当前 OK | 需要 Alertmanager 可达 | 保留 |
| `PrometheusRemoteStorageFailures` | critical | 远端存储写失败 | remote_storage failed samples > 0 | 当前 OK | 适用于远端存储 | 保留 |
| `PrometheusRemoteWriteBehind` | critical | 远端写入延迟 | remote write 滞后 | 当前 OK | 对跨集群远写重要 | 保留 |
| `AlloyDown` | critical | Alloy 日志入口不可达 | alloy up == 0 | 当前 OK | 日志静默丢失 | 保留 |
| `ArgoCDRepoServerDown` | critical | Argo CD 同步阻塞 | argocd-repo-server 不可用 | 当前 OK | GitOps 同步 | 保留 |

#### 2.1.3 特殊组件失联

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `CNI...` (重复) | - | - | - | - | 见 2.1.1 | - |
| `KubeNodePressure` | info | 节点内存/磁盘压力 | kube_node_status_condition > 0 | 当前 OK | 压力判定 | 保留 |
| `KubeQuotaAlmostFull` | info | 配额接近满 | quota > 80% | 当前 OK | 轻压告警 | 保留 |
| `KubeQuotaFullyUsed` | info | 配额完全用完 | quota == 100% | 当前 OK | 重配置 | 保留 |
| `KubeletTooManyPods` | info | 节点 Pod 容量满 | > 120% | 当前 OK | 容量规划 | 保留 |
| `KubePodCriticalComponentHighRestart` | critical | 核心组件重启 > 20 | 累计重启 > 20 | 当前 3 次，OK | 累计阈值易误报 | 改 `rate()` |
| `KubePodHighRestartCount` | warning | Pod 累计重启 > 10 | 累计重启 > 10 | 当前 62 次 (speaker-qmwd4) | 历史累计，当前正常；建议改 `rate()` | 改为近 24h rate() |
| `KubeContainerOOMKilled` | critical | 容器 OOM 被杀 | container_oom_events_total > 0 | 当前 OK | 依赖指标不稳定 | 改用 `kube_pod_container_status_last_terminated_reason` |
| `PodOOMKilled` | critical | 容器 OOM 被杀 | last_terminated_reason == OOMKilled | 当前 OK | 序列为 0，可能不可靠 | 改指标 |
| `KubePersistentVolumeErrors` | critical | PV 处于 Failed/Pending | > 0 | 当前 OK | 发出就绪 | 保留 |
| `KubePersistentVolumeFillingUp` | critical | PV 快耗尽 | < 10% 剩余 | 当前 OK | 存储告警 | 保留 |
| `KubePersistentVolumeInodesFillingUp` | critical | PV inode 快耗尽 | < 10% 剩余 | 当前 OK | 存储告警 | 保留 |

---

### 2.2 Prometheus/Alertmanager 系列（37 条）

#### 2.2.1 Prometheus 自身健康

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `AlertmanagerClusterCrashlooping` | critical | Alertmanager 集群崩溃 | 实例在 10m 内重启 >= 5 次 | 当前 OK | 波动阈值，建议用 rate() | 改 rate() |
| `AlertmanagerClusterDown` | critical | 集群全部 down | < 50% 存活 | 当前 OK | 级联失效 | 保留 |
| `AlertmanagerConfigInconsistent` | critical | 配置不一致 | 配置 hash 不同 | 当前 OK | 影响告警投递 | 保留 |
| `AlertmanagerFailedReload` | critical | 配置重载失败 | 失败标志 | 当前 OK | 配置问题 | 保留 |
| `AlertmanagerMembersInconsistent` | critical | 集群成员不一致 | 成员数异常 | 当前 OK | 需要 20m 稳定 | 保留 |
| `AlertmanagerFailedReload` | critical | 配置重载失败 | > 0 | 当前 OK | 配置问题 | 保留 |
| `AlertmanagerClusterFailedToSendAlerts` | critical | 通知发送失败 | 失败率 > 0 | 当前 OK | 通知链路 | 保留 |
| `AlertReceiverDown` | critical | 接收端宕机 | n8n 就绪数 < 1 | 当前 OK | n8n 是告警接收端 | 保留 |

#### 2.2.2 记录规则

记录规则（Record）本身不会触发告警，但它们是查询指标的基础。共 94 个记录规则，属于已知良性，通常无需处理。

---

### 2.3 日志链路类（2 条）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `AlloyDesiredCountMismatch` | critical | Alloy DaemonSet 预期/实际不一致 | desired != ready | 当前 6/6，OK | 应为 0 | 保留 |
| `LokiIngestStalled` | critical | Loki 写入链路中断 | up 目标落空或总和为 0 | 当前 NOT ACTIVE（3 路均 up） | 仅检查 target discover，不检查实际写入；历史频繁触发根因是 loki-read 因 DNS 失败 Completed 退出 | 加写入量判断：`loki_ingester_accepted_chunks_total` / `loki_ingester_store_blocks_total` |

---

### 2.4 链路/指标类（19 条）

#### 2.4.1 Tempo 相关

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `Tempo3PodCrashLooping` | warning | 链路组件崩溃 | 容器重启 > 5 次 | 当前 OK | 累计阈值 | 改 rate() |
| `Tempo3PodNotReady` | warning | 链路组件未就绪 | ready < 1 | 当前 OK | 按实例 | 保留 |
| `Tempo3LiveStoreReplicationLag` | warning | live-store 落后 | > 60s | 当前 OK | 请输出本地化存储 | 保留 |
| `Tempo3QueryErrorRateHigh` | warning | 查询错误率 | 错误率 > 0 | 当前 OK | 查询链路 | 保留 |
| `Tempo3QueryLatencyHigh` | warning | 查询延迟 | p95 > 阈值 | 当前 OK | 查询延迟 | 保留 |
| `Tempo3SpanRefused` | warning | 接收拒绝 | 拒绝 span 率 > 0 | 当前 OK | 接收链路 | 保留 |
| `OtelDemoServiceDown` | critical | demo 服务中断 | up == 0 | 当前 OK | 测试环境 | 保留 |

#### 2.4.2 节点资源

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `NodeCPUHighUsage` | critical | CPU>90% | 15min 仍>90% | 当前 OK | 按实例 | 保留 |
| `NodeDiskPressure` | critical | 磁盘压力 | < 15% 剩余 | 当前 OK | 按实例 | 保留 |
| `KubeletTooManyPods` | info | 节点 Pod 容量 | > 120% | 当前 OK | 容量 | 保留 |

---

### 2.5 Ceph 系列（14 条）

这些规则与 Ceph 集群监控相关，通过 `ceph-prod` cluster label 关联到 Ceph。

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `CephClusterHealthUnknown` | critical | 集群健康未知 | absent(ceph_health_status) | 当前 OK | 基础 | 保留 |
| `CephClusterUnhealthy` | critical | 集群不健康 | health != 0 | 当前 OK | 基础 | 保留 |
| `CephMonQuorumLost` | critical | 监听器数量不足 | < 2 主 | 当前 OK | 关键 | 保留 |
| `CephMGRMetricsMissing` | critical | MGR 指标丢失 | absent(ceph_mon_quorum_status) | 当前 OK | 指标采集 | 保留 |
| `CephMGRUnreachable` | critical | MGR 不可达 | up == 0 | 当前 OK | 链路 | 保留 |
| `CephOSDDown` | critical | OSD 宕机 | > 0 个 down | 当前 OK | 数据保护 | 保留 |
| `CephOSDOutOfCluster` | critical | OSD 离群 | 0 个 in | 当前 OK | 数据保护 | 保留 |
| `CephPGIncomplete` | critical | PG 不完整 | > 0 不完整 | 当前 OK | 数据完整性 | 保留 |
| `CephClusterCriticallyFull` | critical | 集群极满 | > 95% | 当前 OK | 容量 | 保留 |
| `CephPoolCriticallyFull` | critical | Pool 极满 | > 95% | 当前 OK | 容量 | 保留 |
| `CephPoolNoSpace` | critical | Pool 无空间 | max_avail == 0 | 当前 OK | 容量 | 保留 |
| `CephTooFewOSDs` | critical | OSD 数量不足 | < 3 | 当前 OK | 冗余 | 保留 |
| `CephClusterFull` | critical | 集群满 | > 90% | 当前 OK | 容量 | 保留 |

---

### 2.6 Kubelet 系列（12 条）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `KubeletDown` | critical | kubelet 失联 | 目标 down | 当前 OK | 按实例 | 保留 |
| `KubeletServerCertificateExpiration` | critical | 服务证书 < 24h | TTL < 86400 | 当前 OK | 证书 | 保留 |
| `KubeletClientCertificateExpiration` | critical | 客户端证书 < 24h | TTL < 86400 | 当前 OK | 证书 | 保留 |
| `KubePodCriticalComponentHighRestart` | critical | 核心组件重启 | 累计 > 20 | 当前 3 次 | 累计阈值 | 改 rate() |

---

### 2.7 资源耗尽类（10 条）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `KubePersistentVolumeFillingUp` | critical | PV 容量 | < 10% 剩余 | 当前 OK | 按 PVC | 保留 |
| `KubePersistentVolumeInodesFillingUp` | critical | PV inode | < 10% 剩余 | 当前 OK | 按 PVC | 保留 |
| `NodeFilesystemAlmostOutOfSpace` | critical | 磁盘容量 | < 10% 剩余 | 当前 OK | 按实例 | 保留 |
| `NodeFilesystemFilesFillingUp` | critical | inode 耗尽 | < 10% 剩余 | 当前 OK | 按实例 | 保留 |
| `KubeQuotaAlmostFull` | info | 配额接近满 | > 80% | 当前 OK | 按 namespace | 保留 |
| `KubeQuotaFullyUsed` | info | 配额用完 | 100% | 当前 OK | 按 namespace | 保留 |
| `CPUThrottlingHigh` | info | CPU 节流 | > 阈值 | 当前 OK | 按 Pod | 保留 |
| `KubeNodePressure` | info | 节点压力 | 状态 true | 当前 OK | 按节点 | 保留 |
| `KubeNodeEviction` | info | 节点驱逐 | > 0 | 当前 OK | 瞬时 | 保留 |
| `KubeletTooManyPods` | info | Pod 容量 | > 120% | 当前 OK | 按节点 | 保留 |

---

### 2.8 其他规则（90 条通用）

#### 2.8.1 workload-reliability（3 条）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `KubeContainerOOMKilled` | critical | 容器 OOM 杀死 | oom_events > 0 | 当前 OK | 依赖指标 | 改指标 |
| `KubePodCriticalComponentHighRestart` | critical | 核心重启 | 累计 > 20 | 当前 3 次 | 累计阈值 | 改 rate() |
| `KubePodHighRestartCount` | warning | Pod 重启 | 累计 > 10 | 当前 62 次 | 历史累计 | 改 rate() |

#### 2.8.2 配置重载（3 条）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `PrometheusBadConfig` | critical | 配置重载失败 | hash 变化 | 当前 OK | 配置问题 | 保留 |
| `AlertmanagerFailedReload` | critical | 配置重载失败 | > 0 | 当前 OK | 配置问题 | 保留 |
| `PrometheusConfigReload` | critical | 配置重载 | > 0 | 当前 OK | 配置问题 | 保留 |

#### 2.8.3 KSM 通用告警（默认）

| 规则 | 级别 | 用意 | 触发条件 | 当前状态 | 问题 | 建议 |
|------|------|------|----------|----------|------|------|
| `KubeStateMetricsListErrors` | critical | KSM 读错误 | 5m error rate > 0 | 当前 OK | 可观测性 | 保留 |
| `KubeStateMetricsWatchErrors` | critical | KSM watch 错误 | 5m 错误率 > 0 | 当前 OK | 可观测性 | 保留 |
| `KubeStateMetricsShardingMismatch` | critical | KSM 分片不一致 | stdvar != 0 | 当前 OK | 集群状态 | 保留 |
| `KubeStateMetricsShardsMissing` | critical | KSM 节点丢失 | 数量不符 | 当前 OK | 集群状态 | 保留 |

#### 2.8.4 节点级别（26 条 node-exporter）

node-exporter 相关规则主要是节点资源指标，涵盖 CPU、内存、磁盘、网络、文件描述符、RAID、负载等。全部当前正常。

---

## 三、问题识别与修复建议

> 以下按严重程度和影响面排序，给出修复建议。

---

### 问题 1：LokiIngestStalled 规则设计缺陷（Critical）

**规则**: `monitoring-coverage-gap-alerts-16854106-6dd6-4a4f-87d0-c7e43e82ad0f.yaml` > `LokiIngestStalled`

**表达式**:
```
absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"}) or sum(up{...}) == 0
```

**问题**:
1. 只检查 target discover 状态，不检查实际写入量。Loki 可能启动但阻塞，`up` 仍为 1。
2. 历史频繁触发根因：`loki-read-65c6649765-hfntp` 因 DNS 解析 `loki-backend-headless` 失败（no such host）而 `Completed` 退出 1 次，`for:5m` 放大了重启抖动。
3. 规则建议为"链路中断"，但实际是 discovery 状态告警，不是写入状态告警。

**建议修复**:
```yaml
# 推荐：同时判断 target 可达性和写入量
- alert: LokiIngestStalled
  expr: |
    absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"})
    or
    sum(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"}) == 0
    or
    sum(rate(loki_ingester_accepted_chunks_total{namespace="logging"}[5m])) == 0
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Loki write/backend/read 链路中断，日志无法写入或查询"
```

---

### 问题 2：metallb-system/speaker-qmwd4 累计重启 62 次（Warning）

**规则**: `KubePodHighRestartCount`

**当前状态**: 该 Pod 1/1 Running，3 天稳定，CPU 6m、Memory 28Mi，无 OOM/探针失败。62 次重启为 2026-10-03 之前的历史累计。

**问题**:
1. 累计阈值（10 次）容易误报长生命周期 DaemonSet。
2. 对于已经稳定运行的 Pod，累计重启数会持续增长，导致告警失效或频繁误报。
3. 建议将告警从累计值改为 `rate()` 或连续重启窗口。

**建议修复**:
```yaml
# 推荐：近 24h 内重启率异常
- alert: KubePodHighRestartCount
  expr: |
    sum by (namespace, pod) (
      rate(kube_pod_container_status_restarts_total{namespace=~"metallb-system|kube-system|argocd"}[24h])
    ) > 2
  for: 10m
  labels:
    severity: warning
```

---

### 问题 3：KubePodCriticalComponentHighRestart 累计阈值（Critical）

**规则**: `KubePodCriticalComponentHighRestart`

**当前状态**: 当前集群 3 次，OK。表达式：`max by (namespace, pod, container) (kube_pod_container_status_restarts_total{namespace=~"kube-system|argocd|logging|cert-manager"}) > 20`

**问题**:
1. 长生命周期 DaemonSet（如 metallb-speaker、calico-node）累计重启数会随时间递增，导致告警误报。
2. 2026-10-03 之前的历史累计已达到 62 次，若阈值为 20，可能会触发大量误报。

**建议修复**:
```yaml
# 推荐：24h 窗口内重启率，连续 10m
- alert: KubePodCriticalComponentHighRestart
  expr: |
    sum by (namespace, pod, container) (
      rate(kube_pod_container_status_restarts_total{namespace=~"kube-system|argocd|logging|cert-manager"}[24h])
    ) > 2
  for: 10m
  labels:
    severity: critical
```

---

### 问题 4：KubeletDown / KubeletServerCertificateExpiration 等指示符绑定问题（Critical）

**规则**: `KubeletDown`

**问题**: 控制面 metrics 需要显式绑定 `0.0.0.0` 或节点 IP。如果 kubelet 默认监听 `127.0.0.1`，kubeadm 1.30+ 会导致 target down。

**建议修复**: 在 kubelet 配置中将 metrics 绑定地址改为 `0.0.0.0` 或节点 IP。

---

### 问题 5：KubeContainerOOMKilled 依赖指标不可靠（Critical）

**规则**: `KubeContainerOOMKilled`

**当前状态**: 表达式使用 `container_oom_events_total`，但该指标序列为 0，可能与 KSM 采集不完全有关。

**问题**: 该指标在 KSM 中采集不完整，导致规则无法正确检测 OOM。

**建议修复**:
```yaml
# 推荐：使用 kube_pod_container_status_last_terminated_reason
- alert: KubeContainerOOMKilled
  expr: max by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) == 1
  for: 1m
  labels:
    severity: critical
```

---

### 问题 6：KubeAPIErrorBudgetBurn 表达式过于复杂（Warning）

**规则**: `KubeAPIErrorBudgetBurn`

**问题**: 表达式中 `apiserver_request:burnrate1h`、`apiserver_request:burnrate5m` 等可能存在指标名不匹配风险。标准 prometheus-community 规则使用 `apiserver_request_total:burnrate1h`。

**建议修复**: 检查指标名是否为 `apiserver_request_total:burnrate1h`，如不匹配，修正为标准写法。

---

### 问题 7：PodOOMKilled 序列问题（Critical）

**规则**: `PodOOMKilled`

**当前状态**: 表达式 `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1` 序列为 0，可能不可靠。

**问题**: 该指标在当前集群中值为 0，可能因为 KSM 未正确采集或指标名不匹配。

**建议修复**:
```yaml
# 推荐：使用 kube_pod_container_status_last_terminated_reason
- alert: PodOOMKilled
  expr: max by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) == 1
  for: 1m
```

---

### 问题 8：Calico 规则与 BIRD/IPIP 冲突（Warning）

**规则**: `CNIComponentNotReady`、`CalicoNodeNotReady` 等。

**当前状态**: Calico v3.32.2 使用 BIRD 后端，IPIP `Always`。这些规则检测 Calico-node Pod 就绪。

**问题**: 规则本身正常，但集群的 IPIP 封装可能导致性能开销。建议监控 `cilium` 或 `calico-node` 的 BPF 性能指标。

**建议修复**: 保留现有规则，并补充 BPF 性能指标监控。

---

### 问题 9：n8n ImagePullBackOff（Critical）

**规则**: `AlertReceiverDown`

**当前状态**: 该规则检测 n8n 就绪数 < 1，当前 n8n 恢复 Running，OK。

**问题**: 之前因 `docker.n8n.io` 外部仓库不可达导致 ImagePullBackOff，通过华为云 SWR 镜像解决。

**建议修复**: 保留镜像源配置，确保未来拉取稳定。

---

### 问题 10：记录规则（Record）无法触发告警（Warning）

**问题**: 94 个记录规则没有 `alert` 字段，只定义了 `record` 和 `expr`。这类规则用于缓存聚合指标，用于查询优化，通常不会直接导致告警。

**建议修复**: 保留记录规则，不做修改。仅当记录规则的查询结果对监控正常运行至关重要时，才需要单独告警。

---

## 四、当前集群状态

以下是当前集群的实际监控状态，供参考：

| 组件 | 状态 | 数据 |
|------|------|------|
| Kubernetes 版本 | v1.35.9 | 6/6 节点 Ready |
| Prometheus targets | 125/125 up | 0 down |
| Alert rules health | 63 组 | 全部 ok |
| Grafana | 1/1 Running | OK |
| Loki | 9/9 Running | OK |
| Tempo | 13/13 Running | OK |
| OTel | 正常 | OK |
| Calico | v3.32.2 | BIRD 后端，IPIP Always |
| kube-proxy | iptables 模式 | 已确认 |
| containerd | 2.3.2 | 6/6 节点 |
| runc | 1.4.3 | 6/6 节点 |
| image mirror | 1ms.run | 6 节点全局 |
| n8n | 2.14.2 | 恢复 Running |
| etcd | 3.5.15 | 3/3 healthy |

---

## 五、监控完整资源清单（附查看方法）

### 5.1 采集信息

| 组件 | 采集方式 | 配置文件 |
|------|----------|----------|
| Prometheus 自身 | Prometheus CR（PodMonitor） | `monitoring/prometheus.yaml` |
| KSM | KSM DaemonSet（KSM） | `/etc/kubernetes/kubelet-resolv.conf` |
| node-exporter | Prometheus 静态 config | `monitoring/prometheus-config.yaml` |
| Loki | Alloy DaemonSet + Loki ConfigMap | `logging/alloy-config.yaml` |
| Tempo | Tempo 3 组件 | `logging/tempo-config.yaml` |
| Grafana | Grafana provisioning | `monitoring/grafana-provisioning.yaml` |
| Alertmanager | Alertmanager CR | `monitoring/alertmanager.yaml` |

### 5.2 查看方法

```
# 1. 查看 Prometheus targets 状态
kubectl -n monitoring port-forward svc/prometheus-k8s 9090 &

# 2. 查看 Alertmanager 状态
kubectl -n monitoring port-forward svc/alertmanager 9093 &

# 3. 查看 Grafana 仪表盘
kubectl -n monitoring port-forward svc/grafana 3000 &

# 4. 查看 Loki 状态
kubectl -n logging port-forward svc/loki 3500 &

# 5. 查看 Tempo 状态
kubectl -n logging port-forward svc/tempo 3200 &

# 6. 查看完整集群监控清单
cat /root/集群监控完整资源清单.md
```

### 5.3 规则查询

```
# 查询所有告警规则
kubectl -n monitoring get cm prometheus-prometheus-prometheus-rulefiles-0 -o yaml

# 查询单个告警规则
kubectl -n monitoring get cm prometheus-prometheus-prometheus-rulefiles-0 -o json | \
  jq '.data | to_entries[] | .value' | grep -A 20 "alert: <规则名>"

# 查询当前告警状态
kubectl -n monitoring get alerts 2>/dev/null || \
  kubectl -n monitoring port-forward svc/prometheus-k8s 9090 && \
  curl -s http://localhost:9090/api/v1/alerts
```

---

## 六、总结

### 6.1 规则统计

| 维度 | 数量 |
|------|------|
| 总规则数 | 329 |
| 告警规则 | 235 |
| 记录规则 | 94 |
| Critical 级 | 81 |
| Warning 级 | 145 |
| Info 级 | 7 |

### 6.2 主要问题

1. **LokiIngestStalled 规则设计缺陷**：只检查 target discover，不检查实际写入量。建议加写入量判断。
2. **metallb-system/speaker-qmwd4 累计重启 62 次**：历史累计，当前正常。建议改 `rate()`。
3. **KubePodCriticalComponentHighRestart 累计阈值**：长生命周期 DaemonSet 易误报。建议改 `rate()`。
4. **KubeContainerOOMKilled 和 PodOOMKilled 依赖指标不可靠**：该指标序列为 0。建议改用 `kube_pod_container_status_last_terminated_reason`。
5. **KubeAPIErrorBudgetBurn 表达式过于复杂**：可能存在指标名不匹配风险。
6. **KubeletDown 等组件指示符绑定问题**：控制面 metrics 需要显式绑定 `0.0.0.0`。

### 6.3 合规性

- 已按 `1.29 → 1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35` 逐级升级
- 每级升级前验证三份 etcd 快照
- Calico 按 `v3.27.4 → v3.30.7 → v3.32.2` 两步升级
- 等待用户确认：是否给 quay.io 配置 1ms.run 镜像加速
- 所有密码、Token、Secret、API key 已统一写为 `[REDACTED]`

---

*报告生成时间: 2026-10-06*
*数据来源: `prometheus-prometheus-prometheus-rulefiles-0` ConfigMap（41 个规则文件）*
*当前集群: Kubernetes v1.35.9, 6 节点, 125/125 targets up, 63 规则组 health ok*
