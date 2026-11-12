# GitOps 覆盖度审计：哪些该纳管却没纳管

- **审计时间**：2026-11-12 15:0x CST
- **集群**：6 节点 v1.35.9（m01 / master01-02 / worker01-03）
- **ArgoCD**：v3.5.3，31 个 Application，声明管理 **586** 个对象
- **判定口径**：以 **ArgoCD 自己的 `status.resources`** 为准（不是看 label —— ServerSideApply + 历史 helm 安装会让 label 不可靠）
- **数据来源**：本机只读命令，脚本见 §8

---

## 1. 一句话结论

真正做 GitOps 的只有"以 ArgoCD Application 为入口的那一层"（586 个对象，覆盖业务应用、
监控栈、Traefik、Metallb、CNPG、Kafka、Ceph-CSI、Tekton operator）。

**但集群的"地基"基本不在 GitOps 里**：CNI（Cilium）、日志（Loki）、追踪（Tempo）、
证书（cert-manager）、VPA、ArgoCD 自己，全是 `helm upgrade` 手工装的；
kube-vip、metrics-server、nfs-provisioner、n8n、cloudflared、gitlab-runner、buildkitd
是 `kubectl apply` 手工装的；146 个 CRD 里 44 个不在任何仓里（ArgoCD 管 102 个）。

**最危险的一条**：告警链路的接收端 **n8n 完全不在 GitOps 里**，而它又是 Alertmanager 唯一的 webhook 目标。

---

## 1.1 先分清两层：自举层（Tier 0）与 GitOps 层（Tier 1）

这一节回答一个必须先回答的问题：**CNI 和 API VIP 能不能由 ArgoCD 装？** 不能，原因是硬约束：

```text
ArgoCD 自己跑在 Pod 里  ──需要──►  Pod 网络（CNI）
Pod 网络（CNI）要装     ──需要──►  apiserver 可用（kubectl/helm 都得连它）
apiserver 高可用        ──需要──►  VIP（本集群 10.0.0.168:6443，kube-vip）
kubelet 注册            ──需要──►  apiserver（kubelet.conf 里的 server 就是 VIP）
```

本集群实测印证这条链：`argocd-server` / `argocd-repo-server` 的 `hostNetwork` 都是空的（=false），
所以 ArgoCD **必须**等 CNI 就绪才能起来；`kubeadm-config` 的 `controlPlaneEndpoint` 直接写的 VIP
`10.0.0.168:6443`，kube-vip 以 DaemonSet（`vip_leaderelection=true`、`vip_arp=true`）提供该 VIP。

于是"该不该纳管"要拆成两问：

| 层 | 什么时候需要 | 谁装 | 能否由 ArgoCD 装 | 该进 git 吗 |
|---|---|---|---|---|
| **Tier 0 自举**：OS/runtime、kubeadm 控制面、**kube-vip**、**CNI(Cilium)**、CoreDNS、CSI | ArgoCD 之前 | 一次性脚本 / Ansible（本仓 12 章 + bootstrap 目录） | ❌ 不能（鸡生蛋） | ✅ **必须**——不入库就没有"可重建" |
| **Tier 1 平台/应用**：监控栈、Loki/Tempo、Traefik、CNPG、Kafka、业务应用 | ArgoCD 之后 | ArgoCD | ✅ | ✅ |
| **Tier 0.5 可切换**：Cilium、metrics-server、coredns、kube-vip(DS) | 自举时装，之后**可以**交给 ArgoCD 接管 | 自举装 → Argo 接管（同一份 values） | 可以，但**接管 ≠ 自举** | ✅ values 入 bootstrap 目录；manifest 可选入库 |

结论：**"Cilium 应该纳入 GitOps"的准确含义是 —— values 必须进 git（保证能重建），
再决定是否让 ArgoCD 在自举完成后接管。kube-vip 建议永远留在自举层，只把 manifest 存进 git 备查。**

为什么不把 kube-vip 交给 ArgoCD：

- 它是控制面的一部分，不是"应用"；误 prune 或 sync 出错 = 控制面失联，救回来要登 PVE 控制台；
- 它没有"版本升级"需求（一年动不了一次），GitOps 带来的收益接近 0；
- 自举时它必须存在（否则 kubelet 连不上 endpoint），本来就绕不开脚本。

而 Loki / Tempo 与自举无关（只依赖 CSI 和 PVC），它们的 P0 是**另一个性质**：
配置只活在 `helm upgrade` 的 release 记录里，集群重建后没人知道当时用了什么参数。这两条必须入库。

---

## 2. 现状速览

| 类别 | 数量 | 说明 |
|---|---:|---|
| ArgoCD Application | 31 | 全部 Synced/Healthy |
| ArgoCD 声明的对象 | 586 | 平均 19 个/app；最大 `platform-monitoring-stack` 113 |
| helm CLI 安装的 release | 10 | 见 §3，**全部不在 ArgoCD 里**（仅 argocd 自身的 release secret 带了个无关 label） |
| 手工 `kubectl apply` 的工作负载 | 7 Deploy + 1 DS | n8n、cloudflared、gitlab-runner、buildkitd、metrics-server、nfs-provisioner、coredns + kube-vip（DS） |
| 未纳管 ConfigMap | 77 | 其中 5 个是调试残留（含**明文凭据**，见 §6） |
| 未纳管 ServiceMonitor / PodMonitor | 11 / 16 | 多数是 helm chart 自带（随 chart 走），但 cilium/alloy/cert-manager 的就与 chart 绑定 |
| 未纳管 CRD | 44 / 146 | cilium 10、tekton 系 17、cert-manager 6、otel 4、argoproj 3、VPA 2、grafana/strimzi 各 1 |
| 未纳管 Namespace | 19 / 29 | 除 kube-system/default/kube-node-lease/kube-public 外都是平台自己的命名空间 |

---

## 3. 核心表格：组件 × 是否真在 GitOps

"values 在 git" 一列特别重要 —— 有好几个组件**values 文件躺在仓里，却没有任何 Application 引用它**，
等于摆设：改了不生效，也不会被发现。

| 组件 | 安装方式 | values 在 git | 有 Argo app | 判定 |
|---|---|---|---|---|
| **Cilium**（CNI 数据面） | helm CLI rev4（自举时装） | `platform/network/cilium/values.yaml` **无引用** | 只有 `platform-cilium-l2`（一条策略） | 🔴 **P0（Tier 0.5）**：values 必须入库 + 可选 adopt |
| **Loki**（日志） | helm CLI rev3，**手动 `-f` 升级** | `platform/logging/values.yaml` | 无 | 🔴 **P0（纯配置未入库，无自举约束）** |
| **Tempo**（追踪） | helm CLI rev6 | **无 values 文件** | 无 | 🔴 **P0（同上）** |
| **n8n + cloudflared** | kubectl apply | 无 | 无 | 🔴 **P0**（告警接收端） |
| **kube-vip**（API VIP） | kubectl apply（自举时装） | **无 manifest** | 无 | 🔴 **P0（Tier 0，建议不 adopt）**：manifest 入库备查即可 |
| **ArgoCD 自身** | helm CLI rev15 | `platform/argocd/values.yaml` **无引用** | 无（自举，可接受但要记录） | 🟠 P1 |
| **Alloy**（日志采集） | helm CLI rev3 | `platform/logging/alloy-values.yaml` **无引用** | 只有 `platform-alloy-config`（配置 CR） | 🟠 P1 |
| **cert-manager** | helm CLI rev1 | 无 | 无 | 🟠 P1 |
| **gitlab-runner** | kubectl apply | 无 | 无 | 🟠 P1（CI 执行端） |
| **buildkitd** | kubectl apply | CM 未纳管 | `platform-cicd` 只覆盖部分 | 🟠 P1 |
| **otel-collector**（CR） | kubectl apply | 无 | 无（operator 由 helm 装） | 🟠 P1 |
| **nfs-provisioner + nfs-sc** | kubectl apply | 无 | 无 | 🟠 P1（3 个 PVC 依赖） |
| **metrics-server** | kubectl apply | 无 | 无 | 🟡 P2（kube-system 自举可接受） |
| **VPA** | helm CLI rev2 | 无 | 无 | 🟡 P2 |
| **prometheus-adapter** | helm CLI rev3 | `prometheus-adapter-values.yaml` + 自带 chart 目录 **均无引用** | 无 | 🟡 P2 |
| **otel-operator** | helm CLI rev1 | 无 | 无 | 🟡 P2 |
| **coredns** | kubeadm 自带 | 无 | 无 | ⚪ 不纳管（记录即可） |
| 业务应用 5 个（compassio / deeptutor / open-webui / china-study-free） | ArgoCD | 各自 gitops 仓 | ✅ | ✅ 已覆盖 |
| 监控栈 / Traefik / MetalLB / CNPG / Kafka / Ceph-CSI / Grafana / Tekton operator | ArgoCD | 仓里 | ✅ | ✅ 已覆盖 |

---

## 4. 按优先级：该补的清单（注意 Tier 0 的特殊处理）

### P0 — 丢了要手工重建、或者直接影响可用性

1. **Cilium：values 入库 + 自举后可选 adopt**
   `platform/network/cilium/values.yaml` 已经在仓里，但没有 app 引用 —— 也就是说**新集群重建时没人知道当时用了什么参数**。
   分两步：
   - **必做（Tier 0）**：把这个文件纳入自举脚本（`bootstrap/` 目录 + Ansible），新建集群时
     `helm install cilium cilium-1.20.4 -f bootstrap/cilium-values.yaml --set kubeProxyReplacement=true`，
     这一步**发生在 ArgoCD 之前**，见 §6.5 的新建集群 runbook；
   - **可选（Tier 0.5）**：自举完成后，用同一个文件建 multi-source Application 让 ArgoCD 接管：
   ```yaml
   spec:
     sources:
       - {ref: values, repoURL: <platform-gitops>, targetRevision: main}
       - chart: cilium
         repoURL: https://helm.cilium.io/
         targetRevision: 1.20.4
         helm:
           releaseName: cilium
           valueFiles: [$values/platform/network/cilium/values.yaml]
           # 首次接管需 --server-side + 忽略 operator 注入字段
     syncPolicy:
       syncOptions: [ServerSideApply=true, RespectIgnoreDifferences=true]
   ```
   注意三件事：①接管前 `helm get values cilium -n kube-system > /tmp/cilium-live.yaml` 与仓里文件 diff，
   否则 sync 按仓里的值改网络配置，改错要断整个集群；②App 必须 `prune: false`，否则哪天误删资源 =
   CNI 消失；③本集群已移除 kube-proxy，`kubeProxyReplacement` 必须是 `true`，改错立刻全集群 Service 失效。

2. **n8n + cloudflared 纳入 GitOps**
   这是 Alertmanager 唯一 webhook 目标（`n8n-svc.n8n.svc.cluster.local:5678`）。现在 Deployment/Service/PVC
   全靠手工，重建时没人知道镜像 tag（`n8n:2.14.2`）和 cloudflared 的 tunnel 配置。
   最小做法：`platform/apps/n8n/{deployment,service,pvc,sealedsecret}.yaml` + 一个 Application；
   tunnel token 用 SealedSecret（现在 `open-webui/frp-token` 那种形态即可参考）。

3. **kube-vip：manifest 入库，但**不要**交给 ArgoCD**
   VIP（`vip_address=10.0.0.168`、`vip_interface=eth0`、`port=6443`、`vip_leaderelection=true`）
   只存在于 DaemonSet 的 env 里。丢了控制面连不上，但它属于**自举层**：
   ```bash
   kubectl -n kube-system get ds kube-vip-ds -o yaml > bootstrap/kube-vip/kube-vip-ds.yaml
   ```
   入库目的只有一个：新建集群时照着它重建 / 对照参数。**不建议建 Application** —— 控制面组件被
   ArgoCD prune 或 sync 出错，代价是整台宿主机控制台见。

4. **Loki / Tempo 从 helm CLI 转成 Application**
   - Loki：values 已在 `platform/logging/values.yaml`（文件头写着"手动 `helm upgrade --reuse-values`"），
     加一个 chart App 即可；**但 S3 凭据现在只在 helm release 里，且被渲染进 `logging/loki` 的 ConfigMap（明文，没有 Secret）**，转换前要先把
     `access_key_id/secret_access_key` 做成 SealedSecret 并以 `existingSecret` 方式注入，否则会写进 git 明文。
   - Tempo：仓里连 values 都没有，先 `helm get values tempo3 -n logging` 导出，再建
     `platform/logging/tempo/values.yaml` + Application。

### P1 — 该有、且实现成本低

5. **Alloy**：`alloy-values.yaml` 无引用 → 补 chart App（releaseName `alloy`，chart `alloy-1.13.0`）；
   现有的 `platform-alloy-config` 继续只管配置 CR，两者分工写清楚。
6. **ArgoCD 自身**：`platform/argocd/values.yaml` 无引用。要么补一个自举 App（推荐，改配置不必登机器），
   要么在文件头注明"仅作记录，不自动应用"，避免下一个人以为改了就生效。
7. **cert-manager**：整组（3 Deployment + webhook + CRD）无声明。至少把 `helm get values` 导出入库。
8. **gitlab-runner**：CI 执行端，配置在 `gitlab-runner-config` CM 里（含 runner token 的引用）。
   最小做法：Deployment + CM + SealedSecret 三件套入 `platform/cicd/`。
9. **buildkitd**：`cicd/buildkitd*`（Deployment/CM/Service/CA）现在不在任何 app 里，
   而它是 Compassio/DeepTutor 镜像构建的实际执行者。`platform-cicd` app 已有 25 个对象，把这几个并进去即可。
10. **otel-collector CR**：`opentelemetry/otel-collector` 是由 operator 从 `OpenTelemetryCollector` CR 生成的，
    CR 本身没入库 → operator 重装后 traces 管道需要手工重建。补 `platform/otel/collector.yaml`。
11. **nfs-provisioner + nfs-sc**：`china-study-free` 的 2 个 PVC 与 `cicd/frpc-build-ctx` 依赖它。
   补 `platform/network/nfs/{deployment,storageclass}.yaml`（StorageClass 是 cluster-scoped，注意别写进业务 overlays）。

### P2 — 记录即可，或顺手做

12. **VPA / prometheus-adapter / otel-operator / metrics-server / coredns**：
   逐步把 `helm get values` 导出入库（哪怕先不接 app），目标是"能重建"。
13. **CRD**：146 个里 44 个不在仓（cilium 10、tekton 系 17、cert-manager 6、otel 4、argoproj 3、VPA 2）。建议单独一个 `platform/crds/` 平铺目录 + 一个 App，
    或按组件在各 App 里打开 CRD 管理（`skipCrds: false` / 带 crds/ 目录）。当前 `platform-monitoring-stack`
    明确 `skipCrds: true`，靠 `platform-monitoring-crds` 单独管 10 个 —— 这个模式可以复制到其他 operator。
14. **Namespace**：19 个未纳管（含 kube-system 这类系统命名空间）。要么每个 app 显式带 `namespace.yaml`，要么统一用 `CreateNamespace=true`
    并在 app 里写明（现在只有业务 app 用了这个选项，平台 app 没有）。
15. **RBAC / SA**：未纳管的 role/rolebinding/SA 多数是 helm chart 与 operator 生成的，属于正常；
    但 `allow-kubelet-health-probes`（china-study-free / monitoring / tekton-pipelines 各一份）是手工加的，
    建议并入对应 app。
16. **未纳管的 1 个 SealedSecret**：`argocd/argocd-oauth`（ArgoCD 的 OIDC client 凭据）不在仓里 —— 补进去。

---

## 5. 确认**不需要**纳管的（避免为了覆盖率而纳管）

| 对象 | 为什么不算缺口 |
|---|---|
| ReplicaSet / Pod / EndpointSlice / Lease | 控制器或 kubelet 生成，不是期望状态 |
| PVC / PV（12 + 17） | 由 StatefulSet/PVC 模板与 CSI 动态创建；期望状态在 STS/Deployment 里 |
| `system-cluster-critical` 等 PriorityClass | k8s 内置 |
| Tekton 的 Deployment / NetworkPolicy / HPA | 由 TektonOperator 根据 `TektonConfig`（**在仓里**）生成 |
| Kafka entity-operator、CNPG 的 Service/CM | 由各自 operator 从 CR 生成，CR 在仓里 |
| ceph-csi 的 ctrl/node plugin（Deployment+DS） | `ownerReferences: Driver/rbd.csi.ceph.com`，Driver CR 在 `platform/ceph-csi/drivers-resources` 里 |
| `cicd/el-*-listener`（3 个 Deployment） | 由 `EventListener` CR 生成，CR 在 `platform/cicd/cicd-defs.yaml` |
| `opentelemetry/otel-collector` Deployment | 由 `OpenTelemetryCollector/otel` 生成 —— **但那个 CR 本身不在仓里，算 P1 缺口**（见 §4.10） |
| helm/operator 生成的 ServiceMonitor（11 个） | 随 chart/CR 走；监控覆盖率问题另一说（见 19-审计主报告） |
| `kube-root-ca.crt`、default ServiceAccount | 系统自动创建 |

---

## 6. 顺带发现（不在"覆盖度"范围，但该处理）

1. **🔴 明文对象存储凭据**：`default/mc-cm` 的 `mc.sh` 里写着 RGW 的
   `access_key_id=MSZ7…` / `secret_access_key=pEvD…`，且 `logging/loki` 的 ConfigMap 里也是明文。
   而 `ceph-csi`、`pg-backup`、`oauth2-proxy` 都已经用 SealedSecret —— 凭据管理标准不一致。
   建议：把这组 RGW key 轮换，Loki 改为引用 Secret（helm values 支持 `existingSecret`），
   删掉 `mc-cm`。
2. **调试残留 ConfigMap（5 个）**：`default/lokap-cm`、`default/mc-cm`、`logging/mc-cm`、`logging/lokicf-cm`、
   `opentelemetry/otel-collector-326097f8` —— 都是 2026-09~10 用 `mc`（MinIO client）折腾 RGW 时的残留，
   内容还是"给 MinIO bucket 设 ILM"，与实际（Ceph RGW）不符。
3. **stale helm release 记录**：`monitoring/prometheus` 的 release (rev13) 与 ArgoCD App 同时存在。
   现在实际由 `platform-monitoring-stack` 渲染，但 `helm list` 仍显示它 —— 谁要跑 `helm upgrade prometheus`
   就会和 ArgoCD 打架。建议 `helm -n monitoring uninstall prometheus --keep-history=false` 前先确认
   ArgoCD 的 `prune: false` 不会删资源，或干脆在文档里写明"不要用 helm 碰它"。

---

## 6.5 新建集群（或灾后重建）的正确顺序

把上面的分层落成可执行顺序。参数取自本集群实测，可直接照抄：

```bash
# ── Tier 0：ArgoCD 之前必须完成 ─────────────────────────────
# 0. VM + OS（12 章的 Terraform/cloud-init）
#    containerd 2.x、kubelet/kubeadm/kubectl 1.35.x、swap off、
#    br_netfilter/ip_forward、/etc/hosts、Harbor/内网源

# 1. 第一个 control-plane：先让 VIP 可用，再 kubeadm init
#    方式 a（推荐）：kube-vip 静态 Pod —— init 前把 manifest 放进 /etc/kubernetes/manifests/
kube-vip manifest pod --interface eth0 --address 10.0.0.168 --controlplane --services \
  --arp --leaderElection > /etc/kubernetes/manifests/kube-vip.yaml
kubeadm init --control-plane-endpoint=10.0.0.168:6443 \
             --pod-network-cidr=10.244.0.0/16 --kubernetes-version=v1.35.9
#    方式 b：先用本机 IP init，装完 kube-vip 后再改 endpoint（换来换去，不推荐）

# 2. join 其余 control-plane / worker（此时节点 NotReady 是正常的：还没 CNI）

# 3. CNI —— 这一步必须在 ArgoCD 之前
helm install cilium cilium-1.20.4 -n kube-system \
  --set kubeProxyReplacement=true \
  -f bootstrap/cilium-values.yaml            # ← 就是仓里那个"悬空"的 values 文件
kubectl get nodes                            # 期望 6/6 Ready

# 4. CoreDNS / metrics-server（kubeadm 自带，按需 patch）
kubectl -n kube-system get pod -l k8s-app=kube-dns

# 5. CSI —— 没有它，后面所有 PVC（prometheus/loki/tempo/cnpg）都会 Pending
kubectl get sc                               # ceph-rbd-sc 存在且能 provision 一个测试 PVC

# ── Tier 1：ArgoCD 起来之后 ────────────────────────────────
# 6. 装 ArgoCD（helm，与本集群同版本 argo-cd-10.9.6 / v3.5.3）
helm install argocd argo-cd-10.9.6 -n argocd --create-namespace -f bootstrap/argocd-values.yaml

# 7. apply app-of-apps（bootstrap 仓里的 clusters/prod/app-of-apps.yaml）
kubectl apply -f clusters/prod/app-of-apps.yaml
argocd app list                              # 等全部 Synced

# 8. 数据恢复：etcd 快照（etcdutl）、CNPG barman 备份、PV 备份
etcdutl snapshot restore ...                 # 见 09 章 runbook

# 9. 可选：把 Tier 0 装过的组件 adopt 给 ArgoCD（Cilium / metrics-server / coredns）
#    前提：Application 用同一份 values，sync 前 argocd app diff 必须为空，且 prune: false
```

关键顺序不能乱的三处：

1. **VIP 先于 kubeadm init**：`kubelet.conf` 里的 server 就是 VIP，VIP 不在 kubelet 注册不上；
2. **CNI 先于 ArgoCD**：ArgoCD 是 Pod（实测 hostNetwork=false），没 CNI 起不来；
3. **CSI 先于监控栈**：Prometheus/Alertmanager/Loki/Tempo 全是 StatefulSet + PVC。

---

## 7. 建议的落地顺序

```text
第 1 批（今天，零风险）  ── 导出 values 入库、不接 app
  helm get values cilium -n kube-system      > platform/network/cilium/values.live.yaml
  helm get values loki   -n logging          > platform/logging/loki/values.live.yaml
  helm get values tempo3 -n logging          > platform/logging/tempo/values.live.yaml
  helm get values alloy  -n logging          > platform/logging/alloy/values.live.yaml
  helm get values cert-manager -n cert-manager > platform/cert-manager/values.live.yaml
  helm get values vpa -n kube-system         > platform/vpa/values.live.yaml
  kubectl get ds kube-vip-ds -n kube-system -o yaml > platform/network/kube-vip/daemonset.yaml

第 2 批（业务影响小）    ── 接 app
  n8n + cloudflared、gitlab-runner、buildkitd、otel-collector CR、nfs-provisioner

第 3 批（需窗口）        ── 接日志/追踪（无自举约束）
  Loki（先 SealedSecret 化 S3 凭据）→ Alloy → Tempo
第 3.5 批（可选，想清楚再做）── Cilium 由 ArgoCD adopt
  前提：同一份 values、prune: false、sync 前 diff 为空；kube-vip 不 adopt

第 4 批（清理）
  删 5 个调试 CM、轮换 RGW key、处理 stale helm release
```

每批做完都验三件事：`argocd app diff` 为空、目标组件 Pod 未重建、`kubectl get app -o json` 里
`status.sync.status=Synced` 且 `health=Healthy`。

---

## 8. 可复现的命令

```bash
# 1) 权威口径：每个 app 声明了哪些对象（586 个的并集）
kubectl -n argocd get applications -o json \
  | jq -r '.items[] | .metadata.name as $a | (.status.resources // [])[]
           | [$a, .kind, (.namespace // "-"), .name] | @tsv' | sort

# 2) 逐类型找"不在任何 app 里"的对象
kubectl get deploy,sts,ds,svc,cm,sa,role,rolebinding,networkpolicy -A -o json \
  | jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name] | @tsv' > /tmp/live.tsv

# 3) helm CLI 装的有哪些（与 app 对照）
helm list -A

# 4) 每个 helm release 的实时 values（迁移前必做）
for r in "kube-system cilium" "logging loki" "logging tempo3" "logging alloy"; do
  set -- $r; echo "=== $1/$2"; helm get values $2 -n $1 -a
done
```

审计脚本（本次使用）：`/root/audit-k8s-tutorials/gitops_gap3.py`（ArgoCD status.resources 对比现场对象）。

---

## 9. 边界

- 未审计 **PVE / Hyper-V 层面**（VM 定义、网桥、VHDX）是否在 IaC 里 —— 12 章有 Terraform，但本次只覆盖 K8s。
- 未审计 **GitLab / Harbor 自身配置**（它们不在 K8s 里，属于 03 章范围）。
- "未纳管"不等于"错误"：kube-system 自举组件（coredns/metrics-server）留在 GitOps 外是常见做法，
  这里标 P2 只是因为**重建时缺依据**。
