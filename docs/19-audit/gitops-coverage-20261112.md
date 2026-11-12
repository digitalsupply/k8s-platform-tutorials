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
| **Cilium**（CNI 数据面） | helm CLI rev4 | `platform/network/cilium/values.yaml` **无引用** | 只有 `platform-cilium-l2`（一条策略） | 🔴 **P0** |
| **Loki**（日志） | helm CLI rev3，**手动 `-f` 升级** | `platform/logging/values.yaml` | 无 | 🔴 **P0**（半 GitOps） |
| **Tempo**（追踪） | helm CLI rev6 | **无 values 文件** | 无 | 🔴 **P0** |
| **n8n + cloudflared** | kubectl apply | 无 | 无 | 🔴 **P0**（告警接收端） |
| **kube-vip**（API VIP） | kubectl apply | 无 | 无 | 🔴 **P0**（丢了 apiserver 起不来） |
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

## 4. 按优先级：应该补的清单

### P0 — 丢了要手工重建、或者直接影响可用性

1. **Cilium 纳入 GitOps**
   `platform/network/cilium/values.yaml` 已经在仓里，但没有 app 引用。补一个 multi-source Application：
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
   注意：接管现有 release 前先 `helm get values cilium -n kube-system > /tmp/cilium-live.yaml` 与仓里文件 diff，
   否则 sync 会按仓里的值改网络配置（这条是网络数据面，改错要断整个集群）。

2. **n8n + cloudflared 纳入 GitOps**
   这是 Alertmanager 唯一 webhook 目标（`n8n-svc.n8n.svc.cluster.local:5678`）。现在 Deployment/Service/PVC
   全靠手工，重建时没人知道镜像 tag（`n8n:2.14.2`）和 cloudflared 的 tunnel 配置。
   最小做法：`platform/apps/n8n/{deployment,service,pvc,sealedsecret}.yaml` + 一个 Application；
   tunnel token 用 SealedSecret（现在 `open-webui/frp-token` 那种形态即可参考）。

3. **kube-vip 纳入 GitOps**
   VIP 只在一个 DaemonSet 的 env 里（`vip_address`、`vip_interface`、`port`）。丢了等于控制面连不上。
   做法：`platform/network/kube-vip/{rbac,daemonset,configmap}.yaml`，静态 Pod 或 DS 均可。
   ⚠️ 注意这是控制面组件，先 `kubectl get ds kube-vip-ds -n kube-system -o yaml > /tmp/kube-vip.yaml`
   原样入库，不要在迁移同时改参数。

4. **Loki / Tempo 从 helm CLI 转成 Application**
   - Loki：values 已在 `platform/logging/values.yaml`（文件头写着"手动 `helm upgrade --reuse-values`"），
     加一个 chart App 即可；**但 S3 凭据现在只在 helm release 里**，转换前要先把
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

第 3 批（需窗口）        ── 接网络/日志/追踪
  Loki（先 SealedSecret 化 S3 凭据）→ Alloy → Cilium → kube-vip

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
