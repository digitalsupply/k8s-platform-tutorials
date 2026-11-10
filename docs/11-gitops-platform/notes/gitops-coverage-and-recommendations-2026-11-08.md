# K8s 集群 GitOps 覆盖盘点与生产化建议

> 集群：kubeadm v1.35.9，6 节点
> 盘点时间：2026-11-08
> GitOps 引擎：ArgoCD v3.5.3（Helm 安装，namespace `argocd`）

---

## 0. 结论摘要

| 类别 | 工作负载数（Deploy/STS/DS） | 占比 |
|---|---:|---:|
| **ArgoCD 直接管理** | 11 | 12.8% |
| **ArgoCD 间接管理**（GitOps 管 TektonConfig，Operator 再创建） | 12 | 14.0% |
| **Helm 管理**（未纳入 ArgoCD） | 38 | 44.2% |
| **Operator 从手动 CR 创建** | 4 | 4.7% |
| **完全手动 / kubectl apply** | 21 | 24.4% |
| **合计** | **86** | 100% |

一句话：

- **业务应用基本已经 GitOps 化**（4 个业务 App，全部 auto-sync + self-heal）；
- **平台/中间件大部分还没 GitOps 化**（CNPG、Kafka、MetalLB、Calico、监控 CR、CI 定义、n8n 等）；
- **ArgoCD 自身没有 app-of-apps**，6 个 Application 是 `kubectl apply` 创建的，集群重建后会丢。

---

## 1. 当前由 ArgoCD 直接管理的 6 个 Application

| Application | 类型 | 目标 namespace | 管理的资源数 | 同步策略 |
|---|---|---|---:|---|
| `china-study-free` | 业务 | china-study-free | 13 | auto / prune / selfHeal |
| `compassio` | 业务 | compassio | 18 | auto / selfHeal / **prune=false** |
| `deeptutor` | 业务 | deeptutor | 13 | auto / prune / selfHeal |
| `open-webui` | 业务 | open-webui | 13 | auto / prune / selfHeal |
| `tekton-operator` | 平台 | tekton-operator | 38 | auto / selfHeal / **prune=false** |
| `tekton-config` | 平台 | tekton-pipelines | 1（TektonConfig） | auto / selfHeal / **prune=false** |

合计 **96 个 Kubernetes 资源**。

### 1.1 直接 GitOps 的工作负载（11 个）

| namespace | 工作负载 |
|---|---|
| china-study-free | `china-study-free` |
| compassio | `compassio-backend`、`compassio-frontend`、`compassio-redis`、`frpc` |
| deeptutor | `deeptutor`、`redis` |
| open-webui | `open-webui`、`frpc` |
| tekton-operator | `tekton-operator`、`tekton-operator-webhook` |

这些 Pod 的 Deployment/Service/Ingress/ConfigMap/PVC/NetworkPolicy/PDB/PrometheusRule/ServiceMonitor 都由对应 GitOps 仓库的 `overlays/prod` 管理。

### 1.2 间接 GitOps 的工作负载（12 个）

Tekton 的 `TektonConfig` 由 `tekton-config` App 管理；Tekton Operator 再根据它创建 **TektonInstallSet**，进而创建：

- `tekton-pipelines-controller`、`tekton-pipelines-webhook`、`tekton-events-controller`
- `tekton-dashboard`
- `tekton-triggers-controller`、`tekton-triggers-webhook`、`tekton-triggers-core-interceptors`
- `tekton-pruner-controller`、`tekton-pruner-webhook`
- `tekton-pipelines-remote-resolvers`（两个 namespace）
- `tekton-operator-proxy-webhook`

所以这 12 个是“**GitOps → TektonConfig → Operator → 子资源**”的间接管理，不是 ArgoCD 直接 track。

---

## 2. 没有纳入 GitOps 的部分

### 2.1 Helm 管理（38 个工作负载）

| 组件 | namespace | 说明 |
|---|---|---|
| ArgoCD | argocd | 6 Deployment + 1 STS |
| cert-manager | cert-manager | 3 Deployment |
| ceph-csi-rbd | ceph-csi-rbd | 1 Deployment + 1 DaemonSet |
| VPA | kube-system | 3 Deployment |
| kube-prometheus-stack | monitoring | Prometheus/Alertmanager/Grafana/Operator/KS M/Node Exporter |
| Loki | logging | 多个 Deploy/STS |
| Tempo | logging | 多个 Deploy/STS |
| Alloy | logging | DaemonSet |
| OTel Operator | opentelemetry | Operator + Collector |
| Traefik | traefik | 1 Deployment |

> Helm release 是有的，但 ArgoCD 没有接管；升级、回滚、漂移检测都靠人工 `helm upgrade`。

### 2.2 完全手动 / manifest（21 个工作负载）

**数据库与中间件**

- CNPG：`cnpg-controller-manager`、`barman-cloud`；以及 `Cluster`、`ObjectStore`、`ScheduledBackup`、Barman Plugin 清单
- Kafka：`strimzi-cluster-operator`、`my-cluster-entity-operator`；以及 `Kafka` / `KafkaNodePool` / `KafkaTopic`
- MetalLB：`controller`、`speaker`；以及 `IPAddressPool` / `L2Advertisement`
- NFS Provisioner：`nfs-provisioner`

**网络与基础组件**

- Calico：`calico-node`、`calico-kube-controllers`
- CoreDNS、metrics-server、kube-proxy、kube-vip

**业务 / 工具**

- n8n：`n8n`、`cloudflared`
- GitLab Runner：`gitlab-runner`
- BuildKit：`buildkitd`
- 告警适配器：`wecom-adapter`
- 调试 Pod：`default/netshoot-debug`（建议删除）

**CI 定义（不是工作负载，但同样关键）**

- `cicd` namespace 下的 `Pipeline`、`Task`、`EventListener`、`TriggerBinding`、`TriggerTemplate` 全部**没有 ArgoCD 跟踪**；
- 3 个 `el-*-listener` Deployment 是 Tekton Triggers 根据这些手动 EventListener CR 创建的，所以也不在 GitOps 里；
- 但 CI 已经在用正确模式：`update-gitops-tag` Task 会 `git push` 修改业务 App 的 `overlays/prod/kustomization.yaml`，ArgoCD 再 auto-sync。**CI → GitOps 仓库 → ArgoCD** 这条链路是通的。

---

## 3. 生产上建议纳入 GitOps 的优先级

### P0：优先做（状态关键、手工操作风险最高）

| # | 对象 | 现状 | 建议 | 关键注意点 |
|---|---|---|---|---|
| 1 | **CNPG 数据库栈** | 全手动 | 新增 `platform-cnpg` App：Operator + CRD + Barman Plugin + ObjectStore + Cluster + ScheduledBackup | `Cluster`/`ObjectStore` 必须 `Prune=false`；用 sync-wave 排序；`ServerSideApply=true`；对 Operator 回填字段加 `ignoreDifferences` |
| 2 | **Kafka / Strimzi** | 全手动 | 新增 `platform-kafka` App：Operator + Kafka + NodePool + Topic + User | `Kafka`/`KafkaNodePool` `Prune=false`；`KafkaTopic` 删除会删数据，建议也 `Prune=false` |
| 3 | **监控与告警 CR** | Helm + 手写 CR | 新增 `platform-monitoring` App：Prometheus/Alertmanager CR、ServiceMonitor、PrometheusRule、AlertmanagerConfig、Grafana Dashboard | 规则/探针可 `prune=true`；Prometheus/Alertmanager `prune=false`；忽略 `status` |
| 4 | **CI 定义** | `cicd` 手动 | 把 Pipeline/Task/EventListener/TriggerBinding/TriggerTemplate 放进 `tekton-platform-gitops/cicd`，新增 `tekton-cicd` App | 与业务 App 仓库分开，避免 CI 改自己造成循环 |
| 5 | **ArgoCD app-of-apps** | 6 个 App 手动 apply | 建 `clusters/prod/app-of-apps.yaml`，用 ApplicationSet 或目录 App 管理所有 Application | ArgoCD 自身用独立 App 管 Helm values，`prune=false` |
| 6 | **Secret 管理** | open-webui 仓库里有明文 `Secret` | 引入 Sealed Secrets 或 External Secrets Operator | 不要把明文 Secret 提交 Git；`gitlab-auth` 也走 ESO/Sealed |

### P1：第二批（平台标准化、收益明显）

| # | 对象 | 建议 |
|---|---|---|
| 7 | MetalLB `IPAddressPool` / `L2Advertisement` | 纳入 `platform-network` App；改地址池前先确认 LB IP 不冲突 |
| 8 | cert-manager `Issuer` / `Certificate` | 纳入 `platform-certs` App |
| 9 | Traefik 配置（IngressRoute/Middleware/TLSStore） | 纳入 `platform-ingress` App；Helm values 也进 Git |
| 10 | Helm 平台组件（cert-manager、ceph-csi、VPA、OTel、Loki/Tempo/Alloy、kube-prometheus-stack、Traefik） | 用 ArgoCD 的 Helm source 或 values 仓库接管，获得漂移检测和审计 |
| 11 | Namespace / RBAC / NetworkPolicy / ResourceQuota / LimitRange | 建 `platform-baseline` App，统一所有 namespace 的基线和 PSA 标签 |
| 12 | n8n + cloudflared | 新增 `app-n8n` App；数据库连接 Secret 走 ESO/Sealed |
| 13 | GitLab Runner / BuildKit | 纳入 `platform-ci` App；注册 token 走 Secret 管理 |
| 14 | wecom-adapter | 纳入 `platform-monitoring` App |
| 15 | NFS Provisioner | 纳入 `platform-storage` App；长期建议换 csi-driver-nfs |

### P2：谨慎或暂不纳入

| 对象 | 原因 | 建议 |
|---|---|---|
| kubelet / etcd / 控制面证书 | 节点级 bootstrap，ArgoCD 管不了也不该管 | 用 kubeadm/Ansible 管理 |
| kube-proxy / CoreDNS / Calico / kube-vip 的**安装** | 循环依赖：ArgoCD 本身依赖 CNI/DNS | 只把**配置**（Calico IPPool/BGP/FelixConfiguration、CoreDNS ConfigMap、kube-proxy ConfigMap）纳入 GitOps；安装保留在 bootstrap |
| 调试 Pod（netshoot-debug） | 临时资源 | 直接删除，不要进 Git |
| 明文 Secret | 安全风险 | 用 Sealed Secrets / ESO / SOPS |
| 一次性 CRD / CR | 生命周期短 | 用 `ServerSideApply` + `prune=false`，或独立 App |

---

## 4. 推荐的目标架构

### 4.1 仓库布局

```text
platform-gitops/
├── clusters/prod/
│   ├── app-of-apps.yaml              # ApplicationSet 或目录 App
│   └── applications/
│       ├── cnpg.yaml
│       ├── kafka.yaml
│       ├── monitoring.yaml
│       ├── logging.yaml
│       ├── ingress.yaml
│       ├── storage.yaml
│       ├── cert-manager.yaml
│       ├── metallb.yaml
│       ├── tekton-operator.yaml
│       ├── tekton-config.yaml
│       └── tekton-cicd.yaml
├── platform/
│   ├── cnpg/{operator,plugin,objectstore,cluster,scheduledbackup}/
│   ├── kafka/{operator,cluster,topics}/
│   ├── monitoring/{prometheus,alertmanager,rules,dashboards}/
│   ├── logging/{loki,tempo,alloy}/
│   ├── ingress/traefik/
│   ├── storage/ceph-csi/
│   ├── cert-manager/
│   └── metallb/
├── apps/
│   ├── china-study-free/
│   ├── compassio/
│   ├── deeptutor/
│   ├── open-webui/
│   └── n8n/
└── secrets/
    └── sealed-secrets/
```

### 4.2 ArgoCD 关键策略

| 策略 | 建议 |
|---|---|
| `syncPolicy.automated.selfHeal` | 所有 App 开启，持续纠偏 |
| `syncPolicy.automated.prune` | 无状态资源 `true`；有状态 CR（Cluster/Kafka/ObjectStore）`false` |
| `ServerSideApply=true` | CRD 较大的平台组件必开 |
| `SkipDryRunOnMissingResource=true` | CR 和 CRD 同 App 时必开 |
| `PruneLast=true` | 有依赖顺序的 App 开启 |
| `sync-wave` | 按“CRD/Operator → 插件 → ObjectStore → Cluster → ScheduledBackup”排序 |
| `ignoreDifferences` | 忽略 Operator 回填字段（CNPG 默认值、cert-manager caBundle、HPA replicas 等） |
| `RespectIgnoreDifferences=true` | 避免每次 sync 覆盖回填值 |
| `retry` | 开启 backoff，应对 webhook/CRD 尚未就绪 |

### 4.3 CNPG 的 `ignoreDifferences` 示例

CNPG 1.30 会回填以下字段，不加忽略会导致 ArgoCD 永远 OutOfSync：

```yaml
ignoreDifferences:
  - group: postgresql.cnpg.io
    kind: Cluster
    jsonPointers:
      - /spec/enablePDB
      - /spec/postgresql/parameters
      - /spec/probes
      - /spec/replicationSlots/synchronizeReplicas
      - /status
```

> 更稳妥的做法：只让 GitOps 管“业务字段”，对 Operator 回填字段用 `ignoreDifferences`，并定期人工审查。

---

## 5. 当前风险点

| 风险 | 影响 | 建议 |
|---|---|---|
| 没有 app-of-apps | 集群重建后 6 个 Application 丢失 | 尽快建 app-of-apps |
| ArgoCD 自身是 Helm | 升级/回滚无 Git 审计 | 用 ArgoCD 管 ArgoCD 的 Helm values（`prune=false`） |
| `compassio` 是 `prune=false`，其他业务是 `prune=true` | 行为不一致，删除资源时容易误判 | 统一策略：业务无状态资源可 `prune=true` |
| open-webui 仓库有明文 `Secret` | 凭据泄露风险 | 迁移到 Sealed Secrets/ESO |
| CNPG/Kafka/MetalLB/Calico 全手动 | 无漂移检测、无审计、误操作风险高 | 按 P0/P1 纳入 GitOps |
| `cicd` 定义手动 | CI 是发布关键路径，改错无审计 | 纳入 `tekton-cicd` App |
| n8n 不在 GitOps | 业务应用与数据库配置脱节 | 纳入 `app-n8n` App |
| `default/netshoot-debug` 常驻 | 无用资源占用 | 删除 |
| 平台组件 Helm 未纳管 | 版本漂移、升级不可追溯 | 用 ArgoCD Helm source 接管 |

---

## 6. 落地路线图

### 第 1 周：闭环与数据库

- [ ] 建 `clusters/prod` app-of-apps
- [ ] 迁移 6 个现有 Application 到 app-of-apps 管理
- [ ] 新增 `platform-cnpg` App（Operator + Plugin + ObjectStore + Cluster + ScheduledBackup）
- [ ] 引入 Sealed Secrets 或 ESO，迁移 open-webui 明文 Secret
- [ ] 删除 `netshoot-debug`

### 第 2 周：中间件与可观测性

- [ ] 新增 `platform-kafka` App（Operator + Kafka + NodePool + Topic）
- [ ] 新增 `platform-monitoring` App（Prometheus/Alertmanager CR + 规则 + Dashboard）
- [ ] 新增 `tekton-cicd` App（`cicd` 的 Pipeline/Task/EventListener）
- [ ] 统一 `prune` 策略

### 第 3–4 周：平台标准化

- [ ] ArgoCD 接管 Helm 平台组件（cert-manager、ceph-csi、VPA、OTel、Loki/Tempo/Alloy、kube-prometheus-stack、Traefik）
- [ ] `platform-network`：MetalLB 地址池
- [ ] `platform-certs`：Issuer/Certificate
- [ ] `platform-ingress`：Traefik 配置
- [ ] `platform-baseline`：Namespace/RBAC/NetworkPolicy/Quota/PSA

### 后续

- [ ] n8n、GitLab Runner、BuildKit、wecom-adapter、NFS Provisioner 纳入 GitOps
- [ ] 配置 ArgoCD Image Updater 或继续用 CI 写 tag（当前 CI 模式已可用）
- [ ] 开启 ArgoCD Notifications，同步失败告警到企业微信
- [ ] 定期做“集群重建演练”，验证 GitOps 能否从零拉起

---

## 7. 一句话总结

> 业务应用已经 GitOps 化，平台层还差得远。优先把 **CNPG、Kafka、监控 CR、CI 定义、ArgoCD app-of-apps、Secret 管理** 这 6 件事做完；这 6 件事做完后，生产环境的“可审计、可回滚、可重建”才算真正闭环。
