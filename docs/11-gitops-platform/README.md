# 11 · GitOps 平台化：app-of-apps、覆盖盘点与 Secret 管理

这一章讲的不是“ArgoCD 怎么装”，而是**一个已经能跑的集群，如何逐步交给 Git**：
哪些该纳管、怎么接管已有资源、Secret 怎么不落明文、哪些东西不该硬塞进 GitOps。

## 当时的情况

2026-11-08 做盘点时，集群有 **86 个工作负载**，但 ArgoCD 只直接管理其中一小部分：

| 管理方式 | 工作负载数 | 问题 |
|---|---:|---|
| ArgoCD 直接管理 | 11 | 只有 6 个 Application，覆盖不全 |
| 间接 GitOps | 12 | 由已纳管组件派生，但源配置仍在手工 |
| Helm release | 38 | `helm upgrade` 可绕过 Git |
| 完全手工 / manifest | 21 | 无 Git 记录，重建靠记忆 |

更具体的问题：

- CNPG、Kafka、CI 定义、监控规则都还是手工 apply；
- Secret 以明文 YAML 存在 Git（open-webui 的 3 个 Secret）；
- Grafana 的 Datasource/Dashboard 由 Helm sidecar 供给，UI 改动无法复现；
- 没有 app-of-apps，新增平台组件要手工建 Application；
- 已有的 6 个 Application 一旦被 app-of-apps 接管，`prune`/`selfHeal` 行为需要重新设计。

完成 P0 后（2026-11-09）：CNPG、Kafka、CI、app-of-apps、Sealed Secrets 全部落地；
ArgoCD 管着全套平台与业务应用，**应用数量与健康度不在这里写死**：见 [current-state](../00-cluster-overview/assets/current-state.md) §3（`kubectl -n argocd get applications` 可现场复核；2026-11-11 为 31 个，全部 Synced/Healthy）。

## 主要概念与原理

### 1. ArgoCD 的对象模型

```text
Application
  ├─ source: repoURL + path + targetRevision
  ├─ destination: cluster + namespace
  ├─ syncPolicy: automated / prune / selfHeal
  └─ status: sync + health + conditions
```

`Application` 只描述“把哪个 Git 路径同步到哪个集群/命名空间”，
真正创建资源的是 ArgoCD 的 application-controller（通过 apiserver apply）。

### 2. app-of-apps

一个“根 Application”指向 `clusters/prod/applications/` 目录，目录里每个 YAML 又是一个
`Application`。这样新增平台组件只需要：

```text
加一个 Application YAML → 提交 → 根 App 自动创建子 App → 子 App 同步资源
```

本集群的根 App：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  destination:
    namespace: argocd
    server: https://kubernetes.default.svc
  source:
    repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
    path: clusters/prod/applications
    targetRevision: main
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
```

### 3. `prune` / `selfHeal` 的真实含义

| 字段 | 作用 | 风险 |
|---|---|---|
| `selfHeal: true` | 集群漂移时自动改回 Git 状态 | 手工 hotfix 会被覆盖 |
| `prune: true` | Git 删除资源时，集群也删 | 误删 CRD/PVC/Namespace 不可逆 |
| `prune: false` | Git 删除资源时，集群保留 | 会留下孤儿资源，需要人工清理 |

平台组件（CRD、Operator、数据库）通常先 `prune: false`，确认资源归属和备份后再开。

### 4. 接管已有资源的两种方式

1. **先 adoption，再交给 ArgoCD**：手工给资源加 ArgoCD tracking 注解/label，或让 ArgoCD
   首次 sync 时 `--force`；
2. **直接让 ArgoCD apply**：会看到大量 diff，需要 `ignoreDifferences` 处理 Operator 回写的字段。

CNPG 是典型：Operator 会改 `status`、`spec.instances` 相关字段、默认值，必须忽略：

```yaml
ignoreDifferences:
  - group: postgresql.cnpg.io
    kind: Cluster
    jsonPointers:
      - /status
      - /spec/instances
```

### 5. Secret 的三种 GitOps 方案

| 方案 | 原理 | 适用 |
|---|---|---|
| Sealed Secrets | 用集群公钥加密，controller 用私钥解密 | 单集群、简单 |
| External Secrets (ESO) | 从 Vault/AWS SM 拉取，不同步密文 | 多集群、集中管理 |
| SOPS + age/KMS | 文件级加密，CI/ArgoCD 解密 | 多仓库、离线 |

本集群选了 **Sealed Secrets**：单集群、无外部依赖、controller 已在 GitOps 里。
Vault + ESO 做过可行性评估，但因为 **unseal 人工操作**和资源成本，暂未落地。

### 6. GitOps 仓库布局

```text
platform-gitops/
├── clusters/prod/
│   ├── app-of-apps.yaml
│   └── applications/          # 每个平台组件一个 Application
└── platform/
    ├── ceph-csi/
    ├── cnpg/
    ├── traefik/
    ├── monitoring/
    ├── secrets/sealed-secrets/
    └── ...
```

原则：

- **集群差异放 `clusters/`**，组件定义放 `platform/`；
- 一个组件一个目录，目录内自带 `kustomization.yaml`；
- Application 只引用目录，不写具体资源；
- 镜像 tag、域名、副本数等环境差异放 overlay/values，不 fork 整个目录。

## 踩坑点

### 坑 1：app-of-apps 移除 Application 不会删资源

从 `clusters/prod/applications/` 删掉一个 Application YAML，根 App 会删除该 Application 对象，
但**不会删除它管理过的集群资源**（除非该 App 自己开了 `prune` 且先同步）。这既是保护，也是坑：
以为“已经从 GitOps 下线”，实际资源还在跑。

**修复**：下线流程要显式：先 `prune` 同步一次，确认资源删除，再删 Application。

### 坑 2：`prune: true` + CRD = 灾难

ArgoCD 删除 CRD 会级联删除所有 CR。平台组件升级时，如果 Git 里暂时移除了 CRD 文件，
`prune: true` 可能直接把 CRD 删掉。

**修复**：CRD 用独立 Application 管理，且 `prune: false`；升级时只 apply 不删。

### 坑 3：SealedSecret 的注解被 ArgoCD 改坏

从 `kubeseal` 生成的 SealedSecret 带 `kubectl.kubernetes.io/last-applied-configuration` 或
ArgoCD tracking 注解，直接提交会与 controller 的期望不一致。

**修复**：提交前清理模板里的 ArgoCD tracking 注解；SealedSecret 的 `spec` 只保留
`encryptedData` 和必要的 `template`。

### 坑 4：Git 历史里的明文 Secret 不会因为“删文件”消失

open-webui 迁移时，明文 Secret 已提交过。即使当前 HEAD 删了，`git log -p` 仍能看到。
**轮换凭据**比“删 Git 历史”更优先；如果仓库要公开，必须 rewrite history + 轮换。

### 坑 5：adoption 时 diff 巨大，误以为配置错了

已有资源被 ArgoCD 接管时，Operator 回写的默认值、status、annotation 会产生大量 diff。
这不是“Git 写错了”，而是**期望状态与实际状态的正常差异**。

**修复**：用 `ignoreDifferences` 精确忽略；不要为了消除 diff 把 status 抄进 Git。

### 坑 6：`selfHeal` 会把手工 hotfix 冲掉

生产故障时手工改了一个 Deployment，ArgoCD 几分钟后又改回 Git 版本。
**规则**：紧急 hotfix 也必须走 Git（或先暂停 auto-sync），并记录原因。

### 坑 7：Vault 的 unseal 是人工单点

Vault 重启后需要 3 个 unseal key 才能解封。放在 K8s 里，节点重启/ Pod 漂移都会触发人工操作。
如果没有自动解封（KMS/云 KMS），Vault 不适合“无人值守”集群。

**修复**：要么用云 KMS auto-unseal，要么接受“重启需人工”；本集群因此暂缓 Vault。

## 修复关键

### 1. 先盘点，再排 P0

```text
按工作负载列出：谁管理、Git 路径、是否可重建、Secret 是否明文
  → P0：状态关键 + 手工操作风险最高（数据库、CI、密钥、根 App）
  → P1：平台标准化（监控规则、Grafana、中间件）
  → P2：暂不纳管（一次性 Job、实验组件）
```

### 2. 建 app-of-apps 的节奏

1. 先建根 App，但只接管“已经 GitOps 化”的 6 个 App；
2. 每纳管一个组件：建目录 → 清洗 YAML → `kubectl apply --dry-run=server` → 首次 sync；
3. 首次 sync 用 `prune: false`，确认无删除；
4. 稳定后再决定是否开 `prune`。

### 3. Secret 闭环

```bash
# 安装 controller（GitOps）
kubectl apply -f platform/secrets/sealed-secrets/controller.yaml

# 获取公钥
kubeseal --fetch-cert > pub-cert.pem

# 密封
kubeseal --cert pub-cert.pem --format yaml < secret.yaml > sealedsecret.yaml

# 验证：controller 解出的 Secret 与原始数据哈希一致
kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | sha256sum
```

### 4. 验证清单

```bash
# 所有 App 状态
kubectl -n argocd get applications

# 是否有 App 仍引用旧仓库/旧路径
kubectl -n argocd get applications -o json | jq -r '.items[] | [.metadata.name,.spec.source.repoURL,.spec.source.path] | @tsv'

# 是否还有明文 Secret 在 Git
git grep -nE 'kind: Secret|password:|token:' -- '*.yaml'

# 审计脚本
python3 docs/11-gitops-platform/scripts/argocd_gitops_audit.py
```

## 本目录文档

| 文档 | 内容 |
|---|---|
| [gitops-coverage-and-recommendations-2026-11-08.md](notes/gitops-coverage-and-recommendations-2026-11-08.md) | 86 个工作负载的 GitOps 覆盖率、P0/P1/P2、目标架构 |
| [p0-gitops-execution-log-2026-11-08.md](notes/p0-gitops-execution-log-2026-11-08.md) | CNPG/Kafka/CI/app-of-apps 落地过程与提交记录 |
| [sealed-secrets-openwebui-2026-11-08.md](notes/sealed-secrets-openwebui-2026-11-08.md) | Sealed Secrets 安装、3 个 Secret 迁移、数据一致性验证 |
| [vault-eso-feasibility-2026-11-08.md](notes/vault-eso-feasibility-2026-11-08.md) | Vault + ESO 的资源核算、unseal 代价、决策矩阵、POC 清单 |
| [platform-gitops-repo/](notes/platform-gitops-repo/) | 平台仓原始文档：ArgoCD/Grafana/监控/日志/SSO/Secrets/etcd/网络 |
| [10-iac-evolution.md](10-iac-evolution.md) | Ansible/Terraform/GitOps 能力边界、真机验证与演进逻辑 |
| [2026-11-09-weekly-postmortem-index.md](../09-incidents-and-readiness/notes/2026-11-09-weekly-postmortem-index.md) | 7 轮改造总索引（跨分类） |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/argocd/app-of-apps.yaml](assets/argocd/app-of-apps.yaml) | 根 Application |
| [assets/argocd/existing-apps.yaml](assets/argocd/existing-apps.yaml) | 接管原有 6 个 Application 的清单 |
| [assets/argocd/platform-sealed-secrets.yaml](assets/argocd/platform-sealed-secrets.yaml) | Sealed Secrets Application |
| [assets/sealed-secrets/controller.yaml](assets/sealed-secrets/controller.yaml) | controller 官方清单快照 |
| [scripts/clean-k8s-yaml.py](scripts/clean-k8s-yaml.py) | 清洗 `kubectl get -o yaml` 的运行时字段，拒绝 Secret |
| [scripts/argocd_gitops_audit.py](scripts/argocd_gitops_audit.py) | 只读审计 App 状态、仓库/路径、automated/prune/selfHeal |
| [scripts/gitlab-create-grafana-oauth-app.sh](scripts/gitlab-create-grafana-oauth-app.sh) | 在 GitLab 创建 Grafana OAuth Application 并直接 seal |
| [assets/iac-evolution/](assets/iac-evolution/README.md) | Ansible 幂等/handlers/check/delegate/roles、Terraform state/plan、ArgoCD 审计证据 |

```bash
# 清洗一个 live 资源，生成可提交的 YAML
kubectl -n cnpg-system get cluster pg16-ceph -o yaml \
  | python3 docs/11-gitops-platform/scripts/clean-k8s-yaml.py > cluster.yaml

# 审计
python3 docs/11-gitops-platform/scripts/argocd_gitops_audit.py
```

> 本仓库里的 SealedSecret 是**密文**，只能被对应集群的 controller 解密；
> 换集群必须重新密封。不要把 Sealed Secrets 的私钥提交到 Git。
