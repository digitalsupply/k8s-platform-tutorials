# K8s 集群组件 Dashboard 全景清单

> 日期：2026-11-10  
> 范围：本集群已安装组件 + 官方提供但当前未安装/未配置的 Dashboard  
> 说明：Dashboard 分为三类：  
> 1. **组件自带 Web UI**（Prometheus、Grafana、ArgoCD、Hubble 等）  
> 2. **Grafana 仪表盘**（kube-prometheus-stack、Operator、自定义）  
> 3. **官方提供但未安装**（Kubernetes Dashboard、Headlamp、Kiali、Longhorn 等）

---

## 0. 总览

### 0.1 已安装

| 类型 | 数量 | 说明 |
|---|---:|---|
| Grafana 仪表盘 | **47** | 10 个 General + 37 个 monitoring 文件夹 |
| Grafana Drilldown 插件 | **4** | Logs、Metrics、Traces、Pyroscope |
| 组件自带 Web UI | **8+** | Grafana、Prometheus、Alertmanager、ArgoCD、Hubble UI、Tekton Dashboard、Traefik Dashboard、Alloy UI |
| 业务应用 UI | **5** | Compassio、China Study Free、DeepTutor、Open WebUI、n8n |
| 外部系统 UI | **3+** | Harbor、GitLab、Ceph Dashboard（外部） |

### 0.2 当前没有独立 Dashboard 的组件

以下组件只有 CLI/API/指标，没有官方独立 UI：

```text
CoreDNS、etcd、kube-apiserver、kube-controller-manager、kube-scheduler、
kubelet、kube-vip、MetalLB、CNPG、Strimzi/Kafka、cert-manager、
Sealed Secrets、Metrics Server、VPA、Prometheus Adapter、
Ceph CSI、NFS Provisioner、GitLab Runner、BuildKit、Barman、
Loki（无独立 UI，Grafana 替代）、Tempo（无独立 UI，Grafana 替代）
```

它们的能力主要通过 **Grafana 仪表盘** 或 `kubectl`/Prometheus 查询体现。

---

## 1. 已安装的 Grafana 仪表盘（47 个）

### 1.1 General 文件夹（10 个）

| # | 仪表盘 | UID | 说明 |
|---:|---|---|---|
| 1 | Alertmanager | `eea-9_sik` | Alertmanager 概览 |
| 2 | ArgoCD | `qPkgGHg7k` | ArgoCD 运行状态 |
| 3 | cert-manager | `u6M5igpWk` | 证书签发/续期 |
| 4 | Compassio 校级心理测评 | `compassio-main` | 业务指标、LLM、缓存 |
| 5 | K8S Dashboard | `f2027334-...` | 通用 K8s 面板，**不是** Kubernetes Dashboard UI |
| 6 | Lightweight APM for OpenTelemetry | `febljk0a32qyoa` | OTel APM |
| 7 | Loki stack monitoring (Promtail, Loki) | `loki_stack_monitoring_quortex` | Loki 自身监控 |
| 8 | Node Exporter Full | `rYdddlPWk` | 主机指标 |
| 9 | OpenTelemetry & Tempo | `fe6ry0t5qk0zkb` | Trace 链路 |
| 10 | Traefik | `qPdAviJmz` | Traefik 入口 |

### 1.2 monitoring 文件夹（37 个）

#### Kubernetes 核心

| # | 仪表盘 | UID |
|---:|---|---|
| 1 | Kubernetes / API server | `09ec8aa1...` |
| 2 | Kubernetes / Controller Manager | `72e0e05b...` |
| 3 | Kubernetes / Kubelet | `3138fa15...` |
| 4 | Kubernetes / Scheduler | `2e6b6a3b...` |
| 5 | Kubernetes / Proxy | `632e265d...` |
| 6 | CoreDNS | `vkQ0UHxik` |
| 7 | etcd | `c2f4e12c...` |
| 8 | Kubernetes / Persistent Volumes | `919b92a8...` |

#### 资源与网络

| # | 仪表盘 | UID |
|---:|---|---|
| 9 | Kubernetes / Compute Resources / Cluster | `efa86fd1...` |
| 10 | Kubernetes / Compute Resources / Multi-Cluster | `b59e6c9f...` |
| 11 | Kubernetes / Compute Resources / Namespace (Pods) | `85a56207...` |
| 12 | Kubernetes / Compute Resources / Namespace (Workloads) | `a87fb0d9...` |
| 13 | Kubernetes / Compute Resources / Node (Pods) | `200ac8fd...` |
| 14 | Kubernetes / Compute Resources / Pod | `6581e46e...` |
| 15 | Kubernetes / Compute Resources / Workload | `a164a7f0...` |
| 16 | Kubernetes / Networking / Cluster | `ff635a02...` |
| 17 | Kubernetes / Networking / Namespace (Pods) | `8b7a8b32...` |
| 18 | Kubernetes / Networking / Namespace (Workload) | `bbb2a765...` |
| 19 | Kubernetes / Networking / Pod | `7a18067c...` |
| 20 | Kubernetes / Networking / Workload | `728bf77c...` |

#### 主机与节点

| # | 仪表盘 | UID |
|---:|---|---|
| 21 | Node Exporter / Nodes | `7d577163...` |
| 22 | Node Exporter / USE Method / Cluster | `3e97d1d0...` |
| 23 | Node Exporter / USE Method / Node | `fac67cfb...` |
| 24 | Node Exporter / AIX | `7e0a61e4...` |
| 25 | Node Exporter / MacOS | `629701ea...` |
| 26 | Node Exporter Full（General 也有） | `rYdddlPWk` |

#### 监控栈自身

| # | 仪表盘 | UID |
|---:|---|---|
| 27 | Prometheus / Overview | `9fa0d141...` |
| 28 | Alertmanager / Overview | `alertmanager-overview` |
| 29 | Grafana Overview | `6be0s85Mk` |

#### 组件总览

| # | 仪表盘 | UID |
|---:|---|---|
| 30 | ArgoCD GitOps 总览 | `cm-argocd-overview` |
| 31 | Cert-Manager 总览 | `cm-cert-manager-overview` |
| 32 | CloudNativePG 总览 | `cm-cnpg-overview` |
| 33 | MetalLB & Ceph CSI | `cm-metallb-cephcsi` |
| 34 | Strimzi Kafka 总览 | `cm-strimzi-kafka-overview` |
| 35 | Tekton CI/CD 总览 | `cm-tekton-overview` |
| 36 | Traefik 入口流量 | `cm-traefik-overview` |

#### 历史残留

| # | 仪表盘 | 说明 |
|---:|---|---|
| 37 | Calico Felix - Node Dataplane | Calico 已移除，**残留** |
| 38 | Knative Eventing 总览 | Knative 未安装，**残留** |

> 注：第 37/38 个是残留仪表盘，不影响功能，但建议清理。

### 1.3 Grafana Drilldown 插件（已安装）

| 插件 | 版本 | 用途 | 依赖 |
|---|---|---|---|
| `grafana-lokiexplore-app` | 1.0.37 | Logs Drilldown | Loki（已安装） |
| `grafana-metricsdrilldown-app` | 1.0.34 | Metrics Drilldown | Prometheus（已安装） |
| `grafana-exploretraces-app` | 1.3.3 | Traces Drilldown | Tempo（已安装） |
| `grafana-pyroscope-app` | 1.17.0 | Profiles Drilldown | **Pyroscope 服务未安装** |

> Pyroscope 插件已装，但没有 Pyroscope server/datasource，实际不可用。

---

## 2. 已安装的组件自带 Web UI

> **2026-11-10 更正**：原清单只统计了标准 `Ingress`，遗漏了 Traefik
> `IngressRoute` CRD。ArgoCD/Grafana/Prometheus/Tekton/Traefik 实际都已通过
> IngressRoute 暴露；下表已修正。

| 组件 | UI | 访问方式 | 暴露状态 | 备注 |
|---|---|---|---|---|
| Grafana | Grafana | `https://grafana.k8s.local/` 或 port-forward | Traefik IngressRoute（websecure） | 已有 |
| Prometheus | Prometheus UI | `https://prometheus.k8s.local/` 或 port-forward | Traefik IngressRoute（websecure） | 已有 |
| Alertmanager | Alertmanager UI | `port-forward svc/prometheus-alertmanager 9093:9093` | 仅 ClusterIP | 未暴露 |
| ArgoCD | ArgoCD UI | `https://argocd.devops.com` 或 port-forward | Traefik IngressRoute（websecure + TLS） | 已有 |
| Hubble | Hubble UI | `https://hubble.xyz`（basic auth）或 port-forward | Traefik IngressRoute（本次新增） | 新暴露 |
| Tekton | Tekton Dashboard | `https://tekton.xyz`（basic auth）或 port-forward | Traefik IngressRoute（已有） | 已有 |
| Traefik | Traefik Dashboard | `https://traefik.example.com/dashboard/` 或 `https://traefik.xyz/dashboard/`（basic auth） | Traefik IngressRoute（已有 + 本次新增） | 已有 |
| Alloy | Alloy UI | `https://alloy.xyz`（basic auth）或 port-forward | Traefik IngressRoute（本次新增） | 新暴露 |
| Grafana Drilldown | Logs/Metrics/Traces | Grafana 内 `Drilldown` 菜单 | 已启用 | Pyroscope 无后端 |

### 2.1 业务应用 UI（非集群组件，但属于“Dashboard”）

| 应用 | 域名 | 说明 |
|---|---|---|
| Compassio | `http://compassio.xyz` | 业务前端 |
| China Study Free | `https://studyfree.xyz` / `admin.studyfree.xyz` | 业务前端/管理端 |
| DeepTutor | `https://deeptutor.xyz` | 业务前端 |
| Open WebUI | `http://cngpt.ccwu.cc` | LLM 对话 UI |
| n8n | `http://n8n.zeroth.com` | 工作流 UI |
| CI EventListener | `ci-compassio.xyz` / `el-deeptutor.internal` | Webhook，不是可视 Dashboard |

### 2.2 外部系统 UI

| 系统 | 地址 | 说明 |
|---|---|---|
| Harbor | `http://192.168.67.202:8443` | 镜像仓库 UI（外部） |
| GitLab | `http://192.168.67.201` | 代码/CI UI（外部） |
| Ceph Dashboard | Ceph mgr（10.0.0.31/41/51） | Ceph 集群 UI（外部，需确认端口） |
| Proxmox / 虚拟化平台 | 外部 | 如使用 Proxmox，另有 UI（不在 K8s 内） |

---

## 3. 各组件 Dashboard 能力矩阵

### 3.1 Kubernetes 核心

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| kube-apiserver | ❌ | ✅ API server | 已安装 |
| etcd | ❌ | ✅ etcd | 已安装 |
| kube-controller-manager | ❌ | ✅ Controller Manager | 已安装 |
| kube-scheduler | ❌ | ✅ Scheduler | 已安装 |
| kubelet | ❌ | ✅ Kubelet | 已安装 |
| kube-proxy | ❌ | ✅ Proxy（已移除，残留） | 组件已删除 |
| CoreDNS | ❌ | ✅ CoreDNS | 已安装 |
| kube-state-metrics | ❌ | ✅ 被多个 K8s 面板使用 | 已安装 |
| metrics-server | ❌ | ❌ | 仅 API |
| Node Exporter | ❌ | ✅ Node Exporter Full / USE | 已安装 |
| VPA | ❌ | ❌（官方/社区 dashboard 未装） | 控制器已安装，无 VPA 对象 |
| Sealed Secrets | ❌ | ❌ | 仅控制器 |
| kube-vip | ❌ | ❌（社区 dashboard 未装） | 已安装 |

### 3.2 网络

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| Cilium Agent/Operator | ❌ | ❌（官方 Cilium dashboards 未启用） | 已安装 |
| Hubble Relay/UI | ✅ Hubble UI | ❌（官方 Hubble dashboard 未装） | UI 已安装，未暴露 |
| MetalLB Controller | ❌ | ✅ MetalLB & Ceph CSI | 已安装（speaker 禁用） |
| Cilium L2 Announcements | ❌ | ❌ | 已启用 |
| Traefik | ✅ Dashboard（9000） | ✅ Traefik / Traefik 入口流量 | Dashboard 已启用但未暴露 |
| CoreDNS | ❌ | ✅ CoreDNS | 已安装 |
| kube-vip | ❌ | ❌ | 已安装 |

### 3.3 存储

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| Ceph CSI RBD | ❌ | ✅ MetalLB & Ceph CSI | 已安装 |
| Ceph 集群 | ✅ Ceph Dashboard（外部） | ❌ | 外部 Ceph |
| NFS Provisioner | ❌ | ❌ | 已安装 |
| CNPG | ❌ | ✅ CloudNativePG 总览 | 已安装 |
| Barman Cloud | ❌ | ❌ | 已安装 |

### 3.4 监控 / 日志 / Trace

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| Prometheus | ✅ UI | ✅ Prometheus / Overview | 已安装 |
| Alertmanager | ✅ UI | ✅ Alertmanager / Overview | 已安装 |
| Grafana | ✅ UI | ✅ Grafana Overview | 已安装 |
| Loki | ❌（Grafana Logs Drilldown 替代） | ✅ Loki stack monitoring | 已安装 |
| Tempo | ❌（Grafana Traces Drilldown 替代） | ✅ OpenTelemetry & Tempo | 已安装 |
| Alloy | ✅ Alloy UI（12345） | ❌ | UI 已安装，未暴露 |
| OpenTelemetry Collector/Operator | ❌ | ✅ Lightweight APM for OpenTelemetry | 已安装 |
| Prometheus Adapter | ❌ | ❌ | 已安装（Compassio HPA） |
| Pyroscope | ✅（服务未装） | ✅ 插件已装，无后端 | 不可用 |

### 3.5 GitOps / CI/CD

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| ArgoCD | ✅ UI | ✅ ArgoCD / ArgoCD GitOps 总览 | 已安装 |
| ArgoCD ApplicationSet/Notifications/Dex | ❌（随 ArgoCD UI） | ✅ | 已安装 |
| Tekton Pipelines/Triggers | ✅ Tekton Dashboard | ✅ Tekton CI/CD 总览 | 已安装 |
| Tekton Operator | ❌ | ✅ | 已安装 |
| GitLab Runner | ❌（GitLab UI 外部） | ❌ | 已安装 |
| BuildKit | ❌ | ❌ | 已安装 |
| Harbor | ✅ UI（外部） | ❌ | 外部 |

### 3.6 消息 / 应用

| 组件 | 自带 UI | Grafana 仪表盘 | 当前状态 |
|---|---|---|---|
| Strimzi Kafka | ❌（Kafka UI 未装） | ✅ Strimzi Kafka 总览 | 已安装 |
| CNPG | ❌ | ✅ CloudNativePG 总览 | 已安装 |
| cert-manager | ❌ | ✅ Cert-Manager 总览 | 已安装 |
| Compassio | ✅ 业务 UI | ✅ Compassio 校级心理测评 | 已安装 |
| China Study Free | ✅ 业务 UI | ❌ | 已安装 |
| DeepTutor | ✅ 业务 UI | ❌ | 已安装 |
| Open WebUI | ✅ 业务 UI | ❌ | 已安装 |
| n8n | ✅ 业务 UI | ❌ | 已安装 |

---

## 4. 官方提供但当前未安装 / 未配置的 Dashboard

### 4.1 Kubernetes / 集群通用

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| Kubernetes | **Kubernetes Dashboard** | Web UI | ❌ 未安装 | 如需官方 UI 可安装；注意认证/RBAC |
| Headlamp | **Headlamp** | Web UI | ❌ 未安装 | CNCF 现代化 UI，可替代 Kubernetes Dashboard |
| Kiali | **Kiali** | Web UI | ❌ 未安装 | 主要面向 Istio；当前无 Istio，**不适用** |
| KubeSphere | KubeSphere Console | Web UI | ❌ 未安装 | 重型平台，不建议 |
| Rancher | Rancher UI | Web UI | ❌ 未安装 | 重型平台，不建议 |
| Lens / OpenLens | 桌面 UI | Desktop | ❌ 未安装 | 客户端工具，不是集群组件 |
| K9s | 终端 UI | CLI | ❌ 未安装 | 运维终端工具 |

### 4.2 网络

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| Cilium | **Cilium Agent / Operator Grafana dashboards** | Grafana | ❌ 未启用 | 可在 Cilium Helm values 开 `dashboards.enabled=true` |
| Cilium | **Hubble Grafana dashboard** | Grafana | ❌ 未安装 | 官方 dashboard 可导入 |
| Hubble | **Hubble UI** | Web UI | ✅ 已安装（未暴露） | 加 Ingress/port-forward |
| Kiali | Kiali | Web UI | ❌ 不适用 | 需要 Istio |
| MetalLB | MetalLB Grafana dashboard | Grafana | ✅ 已安装（合并面板） | 可拆分官方 dashboard |

### 4.3 自动扩缩 / 策略 / 安全

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| VPA | VPA Grafana dashboard | Grafana | ❌ 未安装 | 可导入社区 dashboard |
| Goldilocks | **Goldilocks** | Web UI | ❌ 未安装 | VPA 推荐值 UI，可选 |
| KEDA | KEDA Grafana dashboard | Grafana | ❌ 未安装 | 需要先安装 KEDA |
| Kyverno | **Policy Reporter UI** / Grafana | Web UI/Grafana | ❌ 未安装 | 需要先安装 Kyverno |
| Falco | **Falco Sidekick UI** | Web UI | ❌ 未安装 | 需要先安装 Falco |
| Trivy Operator | Trivy Operator Grafana dashboard | Grafana | ❌ 未安装 | 需要先安装 Trivy Operator |
| Tetragon | Tetragon Grafana/Hubble | Grafana | ❌ 未安装 | 需要先安装 Tetragon |
| Pixie | Pixie UI | Web UI | ❌ 未安装 | 需要先安装 Pixie |
| Polaris | Polaris UI | Web UI | ❌ 未安装 | 配置审计 |
| Kubevious | Kubevious UI | Web UI | ❌ 未安装 | 集群可视化 |
| Chaos Mesh | Chaos Mesh Dashboard | Web UI | ❌ 未安装 | 混沌工程 |
| Litmus | Litmus UI | Web UI | ❌ 未安装 | 混沌工程 |
| OpenCost / Kubecost | Cost UI | Web UI | ❌ 未安装 | 成本可视化 |

### 4.4 存储 / 备份 / 发布

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| Longhorn | **Longhorn UI** | Web UI | ❌ 未安装 | 当前用 Ceph RBD/NFS |
| Velero | 无官方 UI（社区有） | Web UI | ❌ 未安装 | 备份组件本身未安装 |
| Argo Rollouts | **Rollouts Dashboard** | Web UI | ❌ 未安装 | 需要先安装 Argo Rollouts |
| Argo Workflows | **Argo Workflows UI** | Web UI | ❌ 未安装 | 需要先安装 Argo Workflows |
| MinIO | **MinIO Console** | Web UI | ❌ 未安装 | 当前用 Ceph RGW，无 MinIO |
| Ceph | **Ceph Dashboard** | Web UI | ⚠️ 外部 Ceph 提供 | 不在 K8s 内，需在 Ceph mgr 确认 |
| Harbor | Harbor UI | Web UI | ✅ 外部 | `192.168.67.202:8443` |
| GitLab | GitLab UI | Web UI | ✅ 外部 | `192.168.67.201` |

### 4.5 消息 / 数据

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| Strimzi Kafka | Strimzi Grafana dashboards（Kafka/Connect/ZooKeeper） | Grafana | ⚠️ 只有总览 | 可导入官方全套 |
| Kafka UI | Kafka UI / AKHQ / Redpanda Console | Web UI | ❌ 未安装 | 可选，需额外组件 |
| CNPG | CloudNativePG Grafana dashboard | Grafana | ✅ 已安装 | - |
| Redis | RedisInsight | Web UI | ❌ 未安装 | 可选 |
| PostgreSQL | pgAdmin | Web UI | ❌ 未安装 | 可选 |

### 4.6 日志 / Trace / Profile

| 组件 | 官方 Dashboard | 类型 | 当前状态 | 建议 |
|---|---|---|---|---|
| Loki | Logs Drilldown（Grafana 插件） | Grafana | ✅ 已安装 | - |
| Tempo | Traces Drilldown（Grafana 插件） | Grafana | ✅ 已安装 | - |
| Alloy | Alloy UI | Web UI | ✅ 已安装（未暴露） | 加 Ingress/port-forward |
| Alloy | Alloy Grafana dashboard | Grafana | ❌ 未安装 | 可导入 |
| Pyroscope | Pyroscope UI + Profiles Drilldown | Web UI/Grafana | ⚠️ 插件已装，服务未装 | 安装 Pyroscope server 或移除插件 |
| Jaeger | Jaeger UI | Web UI | ❌ 未安装 | 当前用 Tempo，不需要 |
| Zipkin | Zipkin UI | Web UI | ❌ 未安装 | 不需要 |

---

## 5. 访问方式与暴露缺口

### 5.1 暴露方式说明

之前清单只统计了标准 `Ingress`，遗漏了 Traefik `IngressRoute` CRD。实际：

```text
ArgoCD       IngressRoute argocd           Host argocd.devops.com
Grafana      IngressRoute grafana          Host grafana.k8s.local / grafana.example.local
Prometheus   IngressRoute prometheus       Host prometheus.k8s.local / prom.example.local
Tekton       IngressRoute tekton-dashboard Host tekton.xyz（basic auth）
Traefik      IngressRoute traefik-dashboard Host traefik.example.com（basic auth）
Hubble       IngressRoute hubble           Host hubble.xyz（basic auth，本次新增）
Alloy        IngressRoute alloy            Host alloy.xyz（basic auth，本次新增）
Traefik      IngressRoute traefik-xyz      Host traefik.xyz（basic auth，本次新增）
```

仍只有 ClusterIP 的 UI：

| UI | 当前访问 | 建议 |
|---|---|---|
| Alertmanager | `port-forward 9093` | 一般不需要公网；Grafana 可跳转 |
| Grafana / ArgoCD / Prometheus / Tekton / Traefik | 已有 IngressRoute | 无需新增 |
| Hubble / Alloy | 本次已加 IngressRoute | 使用 basic auth |
| Alertmanager | port-forward 9093 | 不建议公网 |

### 5.2 常用 port-forward 命令

```bash
# Grafana
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80

# Prometheus
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090

# Alertmanager
kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093

# ArgoCD
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Hubble UI
kubectl -n kube-system port-forward svc/hubble-ui 8080:80

# Tekton Dashboard
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097

# Traefik Dashboard
kubectl -n traefik port-forward deploy/traefik 9000:9000

# Alloy UI
kubectl -n logging port-forward svc/alloy 12345:12345
```

---

## 6. 建议

### 6.1 立即值得做的

1. **给 Grafana/ArgoCD 补 Ingress 或确认外部反代**
   - 当前集群内没有 Ingress 记录；
   - 需要确认 `grafana.k8s.local` 和 `argocd.devops.com` 的外部反代是否仍然有效。

2. **清理残留 Grafana dashboard**
   - `Calico Felix - Node Dataplane`（Calico 已移除）
   - `Knative Eventing 总览`（Knative 未安装）
   - `Kubernetes / Proxy`（kube-proxy 已移除）

3. **Cilium 官方 dashboard**
   - 当前没有 Cilium Agent/Operator/Hubble 的 Grafana 面板；
   - 可在 Cilium Helm values 开 `dashboards.enabled=true`，或手动导入官方 JSON。

4. **Pyroscope 插件没有后端**
   - `grafana-pyroscope-app` 已安装，但没有 Pyroscope server/datasource；
   - 要么安装 Pyroscope，要么禁用/移除该插件，避免菜单误导。

5. **暴露 Hubble UI / Tekton Dashboard 时加认证**
   - 不要让它们直接公网可访问；
   - 建议只在内网或通过 ArgoCD/Grafana SSO 后访问。

### 6.2 可选

| 需求 | 建议 |
|---|---|
| 官方 K8s UI | 安装 Kubernetes Dashboard 或 Headlamp |
| VPA 资源推荐 | 加 VPA `Off` + Goldilocks |
| Cilium 深度可视化 | 启用 Cilium Grafana dashboards + Hubble UI |
| 成本可视化 | OpenCost / Kubecost |
| 策略/安全 | Kyverno + Policy Reporter、Falco + Sidekick UI、Trivy Operator |
| 备份 UI | Velero + 社区 UI（当前未安装备份组件） |
| Kafka UI | Kafka UI / AKHQ / Redpanda Console（Strimzi Grafana 已有总览） |
| PostgreSQL UI | pgAdmin（可选） |
| Redis UI | RedisInsight（可选） |

### 6.3 不建议

- 不要把 Prometheus/Alertmanager/Traefik Dashboard 直接暴露公网；
- 不要在未安装对应组件时导入其 dashboard（会显示 No data）；
- 不要同时运行多个 K8s 管理 UI（Kubernetes Dashboard + Headlamp + KubeSphere）而不做权限收敛。

---

## 7. 附录：本次清点命令

```bash
# 已安装 Grafana dashboards
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
curl -u admin:<password> 'http://127.0.0.1:3000/api/search?type=dash-db&limit=1000'

# Grafana 插件
curl -u admin:<password> 'http://127.0.0.1:3000/api/plugins?embedded=0'

# Ingress / UI Service
kubectl get ingress -A -o wide
kubectl get svc -A | grep -Ei 'grafana|prometheus|alertmanager|argocd-server|hubble-ui|tekton-dashboard|traefik|alloy'

# 是否存在可选 Dashboard 组件
kubectl get crd -o name | grep -Ei 'rollout|workflow|keda|kyverno|longhorn|velero|trivy|falco|tetragon|pixie'
kubectl get ns | grep -Ei 'keda|kyverno|falco|longhorn|velero|trivy|tetragon|pixie|kiali|headlamp'
kubectl get pods -A | grep -Ei 'dashboard|headlamp|kiali|pyroscope|keda|kyverno|falco|longhorn|velero|trivy|tetragon|pixie'
```

---

## 8. 一句话总结

**已安装 47 个 Grafana 仪表盘、4 个 Grafana Drilldown 插件、8 个组件自带 Web UI（Grafana/Prometheus/Alertmanager/ArgoCD/Hubble/Tekton/Traefik/Alloy）和 5 个业务 UI。**  
**官方提供但未安装的主要有：Kubernetes Dashboard、Headlamp、Cilium Grafana dashboards、VPA/Goldilocks、KEDA、Kyverno/Policy Reporter、Falco Sidekick、Trivy Operator、Longhorn、Velero、Argo Rollouts/Workflows、Kafka UI、MinIO Console、Pyroscope server 等。**  
当前最大的缺口不是“没有 dashboard”，而是 **ArgoCD/Grafana/Hubble/Tekton 等 UI 没有集群内 Ingress 暴露**，以及 **Cilium/VPA 等关键组件缺少 Grafana 面板**。

---

## 9. 2026-11-10 更新

### 9.1 IngressRoute 更正

经核实，ArgoCD/Grafana/Prometheus/Tekton/Traefik 不是“没有暴露”，而是使用
**Traefik IngressRoute CRD**，标准 `Ingress` 列表不会显示它们：

```text
argocd/argocd              Host argocd.devops.com
monitoring/grafana         Host grafana.k8s.local / grafana.example.local
monitoring/prometheus      Host prometheus.k8s.local / prom.example.local
tekton-pipelines/tekton-dashboard Host tekton.xyz
traefik/traefik-dashboard  Host traefik.example.com
```

### 9.2 Grafana 仪表盘数量变化

```text
2026-11-09: 47
2026-11-10: 50
  -3  Calico Felix / Knative Eventing / Kubernetes Proxy（残留清理）
  +6  Cilium Metrics / Cilium Operator / Hubble Metrics /
      Hubble DNS / Hubble L7 HTTP / Hubble Network
```

Cilium 仪表盘已导入 `monitoring` 文件夹，数据源 UID 为 `prometheus`。

### 9.3 新增 UI 暴露

```text
hubble.xyz  -> hubble-ui:80     basic auth
alloy.xyz   -> alloy:12345      basic auth
traefik.xyz -> Traefik api@internal  existing traefik-dashboard-auth
```

凭据和操作记录见：`/root/ui-and-dashboards-update-20261110.md`
