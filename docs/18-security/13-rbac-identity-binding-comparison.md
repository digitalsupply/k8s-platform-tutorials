# RBAC 身份与绑定对比：`cicd/pipeline` 与 `headlamp/headlamp-root`（2026-11-26）

> 本文整合前几轮的 RBAC 概念（Role/ClusterRole、Binding、Subject、SA、Token），
> 用两个真实对象做对照，讲清**工作负载身份**和**访问类身份**的根本差异。
> 数据均为 `kubectl` 实测。

## 一、结论速览

| 维度 | `cicd/pipeline` + `ClusterRole/edit` | `headlamp/headlamp-root` + `ClusterRole/cluster-admin` |
|---|---|---|
| **身份用途** | 工作负载身份（给程序/Pod 用） | 访问类身份（给人用） |
| **使用主体** | 约 30+ 个 Pod 自动使用 | **0 个 Pod**，人粘贴 token 使用 |
| **凭证获取** | Pod 自动挂载 token | 手工 `kubectl create token` 签发后粘贴 |
| **权限范围** | 集群级编辑（有边界） | 全集群全动作（无边界） |
| **能否 exec / 改 RBAC** | ❌ 不能 | ✅ 能 |
| **与 GitLab 的关系** | 不经过 GitLab，CI/CD 内部身份 | GitLab 登录后接棒的 k8s 身份 |

**一句话**：两者都是“SA + ClusterRole + ClusterRoleBinding”的三件套，但一个
是**程序自动用的身份**，一个是**人手动用的身份**；一个权限**有边界**，一个
**无边界**。

---

## 二、核心概念回顾（整合前几轮）

### 1. RBAC 三要素

| 要素 | 作用 | 本文两个例子 |
|---|---|---|
| **Role / ClusterRole** | 权限本体（能做什么） | `ClusterRole/edit`、`ClusterRole/cluster-admin` |
| **RoleBinding / ClusterRoleBinding** | 连接（把权限挂给谁） | `pipeline-edit-binding`、`headlamp-root-cluster-admin` |
| **Subject** | 被授权者（谁拿到权限） | `ServiceAccount cicd/pipeline`、`ServiceAccount headlamp/headlamp-root` |

### 2. Subject 有三种类型

`ServiceAccount` / `User` / `Group`。本文两个例子用的都是 **ServiceAccount**
（SA），且都是**命名空间级**身份，完整身份名是
`system:serviceaccount:<namespace>:<name>`。

### 3. SA 是身份，绑定才给权限

- **SA 对象本身不包含权限**，只是身份载体；
- 权限来自“以该 SA 为 subject 的绑定”；
- 没有绑定的 SA 只有 `system:authenticated` 基线权限。

### 4. Pod 与 SA：认证与授权

- 每个 Pod 都有 SA（显式指定或用 `default`）；
- **认证**靠 SA token，**授权**靠绑定；
- 需要访问 apiserver 的 Pod，才真正用到这份权限。

### 5. Token：认证凭证

- `kubectl create token <sa>` 签发的 bound token，`sub` 就是该 SA 的完整身份名；
- Pod 自动挂载 token（`automountServiceAccountToken: true`）；
- **绑定只给权限，不提供凭证**；凭证必须靠 token 或证书。

---

## 三、两个对象的配置

### 1. `cicd/pipeline` + `ClusterRole/edit`

**绑定：**

```yaml
kind: ClusterRoleBinding
metadata:
  name: pipeline-edit-binding
roleRef:
  kind: ClusterRole
  name: edit
subjects:
  - kind: ServiceAccount
    name: pipeline
    namespace: cicd
```

**使用方**：约 30+ 个 Pod（随流水线运行数量变化），包括：

- `el-*-listener`：Tekton **EventListener**，监听事件、创建 PipelineRun；
- `*-clone-pod`、`*-check-changes-pod`、`*-build-pod`、`*-update-gitops-pod`：
  流水线任务步骤，起 Pod、操作工作负载。

**权限**（`ClusterRole/edit`，集群级编辑）：

| 动作 | 结果 |
|---|---|
| create/delete pods、deployments、secrets、configmaps、services | ✅ |
| get/list/watch 各类资源 | ✅ |
| **exec pods** | ❌（`pods/exec` 只给 get/list/watch） |
| **create clusterrolebindings**（改 RBAC） | ❌ |
| **get nodes/proxy** | ❌ |
| **impersonate** | ❌（仅 `serviceaccounts` 的 impersonate，不是用户级） |

### 2. `headlamp/headlamp-root` + `ClusterRole/cluster-admin`

**绑定：**

```yaml
kind: ClusterRoleBinding
metadata:
  name: headlamp-root-cluster-admin
  annotations:
    argocd.argoproj.io/tracking-id: platform-headlamp:...
roleRef:
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp-root
    namespace: headlamp
```

**使用方**：**0 个 Pod**。它是**纯访问类 SA**，由人（GitLab `root`/leihao）
登录 Headlamp 时粘贴它的 token 来使用。

**权限**（`ClusterRole/cluster-admin`，全集群全动作）：

| 动作 | 结果 |
|---|---|
| create/delete/exec/改所有资源 | ✅ |
| create clusterrolebindings（改 RBAC） | ✅ |
| get nodes/proxy（直连 kubelet） | ✅ |
| impersonate users | ✅ |

---

## 四、根本差异（详解）

### 1. 身份用途不同：工作负载身份 vs 访问类身份

- **`cicd/pipeline` 是“工作负载身份”**：它服务于一个**正在运行的程序**
  （Tekton 流水线执行器）。身份存在的意义是让这些 Pod 能以统一身份调
  apiserver 完成 CI/CD 动作。
- **`headlamp/headlamp-root` 是“访问类身份”**：它不服务于任何 Pod，
  纯粹是**给人用的凭证载体**。存在的意义是让某个管理员能以一个固定的
  k8s 身份登录 Headlamp、管理集群。

这是**最根本的差异**：一个为“程序”服务，一个为“人”服务。

### 2. 凭证获取不同：自动挂载 vs 手工签发粘贴

- **`cicd/pipeline`**：Pod 启动时**自动**把 SA token 挂载到
  `/var/run/secrets/kubernetes.io/serviceaccount/token`，Pod 代码里直接用，
  **无任何人工步骤**。
- **`headlamp/headlamp-root`**：没有 Pod 挂载它，必须由人先执行
  `kubectl -n headlamp create token headlamp-root --duration=24h` 签发，
  再把整行 JWT **粘贴**到 Headlamp 的 “Headlamp Cluster Authentication”
  输入框。

> 为什么 headlamp-root 要手工粘贴？因为 Headlamp 去掉了
> `-unsafe-use-service-account-token`，不再用 Pod 自己的 SA 转发请求；
> 而 apiserver 又没配 OIDC，不认 GitLab 登录态。所以必须由人提供一个
> k8s 认得的凭证，也就是这个 SA 的 token。

### 3. 使用主体不同：Pod 自动 vs 人手动用

- **`cicd/pipeline`**：使用主体是 **Pod**，身份在 Pod 调 apiserver 时**自动**
  带上，属于“程序内自动完成”。
- **`headlamp/headlamp-root`**：使用主体是**人**，身份靠人**手动粘贴 token**
  触发，属于“人工介入”。

### 4. 权限范围不同：edit 有边界 vs cluster-admin 无边界

- **`edit`** 是**有边界的集群级编辑**：能增删改大多数工作负载和 Secret，
  但**明确排除** exec、RBAC 写、`nodes/proxy`、用户级 impersonate。
  它是“能干活，但不能为所欲为”。
- **`cluster-admin`** 是**无边界的全权限**：全资源、全动作，包括 exec、
  改 RBAC、直连 kubelet、impersonate。它是“想干什么都行”。

**权限差异的本质**：`pipeline` 只需要“在集群里跑流水线”，`edit` 足够；
`headlamp-root` 是“管理员”，需要完整控制权，所以用 `cluster-admin`。

### 5. 与 GitLab 认证的关系不同

- **`cicd/pipeline`**：**不经过 GitLab**。它是 CI/CD 系统内部的身份，
  由 Tekton 流水线直接使用，与 SSO 无关。
- **`headlamp/headlamp-root`**：**在 GitLab 登录之后接棒**。整个访问是
  **两层认证**：

```text
① GitLab 登录 → oauth2-proxy → 证明"你是 GitLab 的 root"（网页身份）
② 粘贴 headlamp-root 的 token → apiserver → 证明"你是 k8s 的
   system:serviceaccount:headlamp:headlamp-root"（k8s 身份）
```

第①层无法替代第②层，因为 apiserver 不认 GitLab 登录态。

### 6. 生命周期与归属不同

- **`cicd/pipeline`**：与**工作负载绑定**，随流水线 Pod 的创建/销毁而使用；
  身份的“活跃”体现在有 Pod 在跑。
- **`headlamp/headlamp-root`**：**不绑定任何工作负载**，长期存在，
  活跃与否取决于是否有人拿它的 token 登录。

### 7. 安全考量不同

- **`cicd/pipeline`**：权限偏大但**受功能约束**，且必须绑在集群级
  （流水线要跨命名空间）。风险在于“流水线执行器被滥用时，能跨集群改工作负载、
  读 Secret”，需要靠 PSA/策略和流水线本身的信任边界来约束。
- **`headlamp/headlamp-root`**：**最高权限**，风险在于“谁能拿到它的 token”。
  控制点是**凭证的分发**——只有管理员能签发，且不应把 token 泄露给非管理员。

### 8. 使用主体是怎么配置出来的：`serviceAccountName`

**谁在用一个 SA，不是由 SA 或绑定决定的，而是由使用它的 Pod/工作负载里的
`serviceAccountName` 决定的。**

```yaml
spec:
  template:
    spec:
      serviceAccountName: <SA 名>        # ← 这一行决定这个 Pod 用哪个 SA
      automountServiceAccountToken: true # ← 是否自动挂载该 SA 的 token
```

**`cicd/pipeline` 有约 30 个 Pod 用它**，因为这些工作负载把
`serviceAccountName` 写成了 `pipeline`：

```yaml
# Tekton EventListener 对应的 Deployment
spec:
  template:
    spec:
      serviceAccountName: pipeline
```

**`headlamp/headlamp-root` 没有 Pod 用它**，因为没有任何工作负载把
`serviceAccountName` 写成 `headlamp-root`。Headlamp 自己的 Deployment 用的是
另一个 SA：

```yaml
# headlamp Deployment
spec:
  template:
    spec:
      serviceAccountName: headlamp   # ← 不是 headlamp-root
```

所以 `headlamp-root` 只能由**人粘贴 token** 使用，没有 Pod 使用它。

> **注意**：对 Headlamp 这类“去掉 `-unsafe-use-service-account-token`”的组件，
> 即使把 `serviceAccountName` 改成 `headlamp-root`，Headlamp 也**不会**使用
> 挂载的 SA token，用户仍须粘贴 token。详见
> [17 号文档第四节](../13-sso-oidc/notes/17-headlamp-token-login-per-user-rbac.md#四常见误解改-serviceaccountname-为-headlamp-root-能免-token-吗)。

---

## 五、认证 + 授权链路对比

### `cicd/pipeline`

```text
Tekton 流水线 Pod（serviceAccountName: pipeline）
   │
   ├─ 自动挂载 SA token（sub = system:serviceaccount:cicd:pipeline）
   ▼
Pod 调 apiserver（创建 PipelineRun / 起任务 Pod）
   │
   ├─ ① 认证：token 合法 → 身份 = cicd:pipeline
   ▼
   ② 授权：ClusterRoleBinding/pipeline-edit-binding → ClusterRole/edit
   ▼
   ③ 放行（edit 范围内的动作）
```

**全程无人参与，程序自动完成。**

### `headlamp/headlamp-root`

```text
人（GitLab root）登录 Headlamp
   │
   ├─ ① GitLab 登录（oauth2-proxy）→ 打开 Headlamp 页面
   ▼
   ② 粘贴 headlamp-root 的 token（手工签发）
   ▼
Headlamp 用该 token 调 apiserver
   │
   ├─ ③ 认证：token 合法 → 身份 = headlamp:headlamp-root
   ▼
   ④ 授权：ClusterRoleBinding/headlamp-root-cluster-admin → cluster-admin
   ▼
   ⑤ 放行（全集群全动作）
```

**第②步是人工的，且需要能签发 token 的命令行权限。**

---

## 六、搭配考量（为什么这么配）

### `cicd/pipeline` 为什么用 `ClusterRole/edit`

1. **功能需要集群级权限**：流水线要在多个命名空间创建/删除工作负载，
   命名空间级的 Role 不够用。
2. **`edit` 是功能上够用的最小集合**：能完成流水线动作，又排除了 exec、
   RBAC 写等高危能力，比 `cluster-admin` 收敛。
3. **用 ClusterRoleBinding 而非 RoleBinding**：因为需要跨命名空间。

### `headlamp/headlamp-root` 为什么用 `ClusterRole/cluster-admin`

1. **定位是管理员**：需要完整控制权（含 exec、改 RBAC、排障）。
2. **只有这一个“人”用**：不追求最小权限的细粒度，而是靠“凭证分发”控制风险。
3. **绑定在 ClusterRoleBinding**：管理员权限天然是集群级的。

**两者的搭配逻辑一致**：**按“身份要干什么”来选角色，按“范围”选绑定类型**。
`pipeline` 要跨集群干活 → ClusterRole/edit；`headlamp-root` 要全权管理 →
ClusterRole/cluster-admin。

---

## 七、权限问题与建议

| # | 对象 | 问题 | 建议 |
|---|---|---|---|
| 1 | `cicd/pipeline` | `edit` 权限偏大，含 Secret 写、跨集群建 Pod；若流水线被滥用可造成大范围影响 | 评估改为命名空间级 Role；对流水线 Pod 加 PSA（restricted）限制 privileged/hostPath |
| 2 | `headlamp/headlamp-root` | `cluster-admin` 最高权限，依赖“谁能拿到 token” | 严格控制 token 分发；不把 token 写进文档/聊天/代码；需要时用短时效 token |
| 3 | 两者共性 | 身份是共享的：同 SA 的所有使用者权限完全相同 | 如需按人/按 Pod 区分，必须拆成多个 SA（或上 apiserver OIDC 做用户级 RBAC） |

---

## 八、总结对照表

| 对比项 | `cicd/pipeline` + `edit` | `headlamp/headlamp-root` + `cluster-admin` |
|---|---|---|
| 权限本体 | `ClusterRole/edit`（集群级编辑） | `ClusterRole/cluster-admin`（全集群全动作） |
| 连接 | `ClusterRoleBinding/pipeline-edit-binding` | `ClusterRoleBinding/headlamp-root-cluster-admin` |
| Subject | `SA cicd/pipeline` | `SA headlamp/headlamp-root` |
| 身份用途 | 工作负载身份（程序用） | 访问类身份（人用） |
| 使用主体 | ~30+ 个 Pod | 0 个 Pod，人粘贴 token |
| 凭证获取 | Pod 自动挂载 | 手工 `kubectl create token` 后粘贴 |
| 认证方式 | Pod 带 token 调 apiserver | 人粘贴 token，Headlamp 转发 |
| 授权范围 | 集群级，有边界（无 exec/RBAC/nodes/proxy） | 集群级，无边界 |
| 与 GitLab 关系 | 无关（CI/CD 内部） | GitLab 登录后接棒（两层认证） |
| 生命周期 | 随工作负载 | 长期存在，无工作负载 |
| 主要风险 | 权限偏大、跨集群改工作负载 | 凭证泄露即全权 |

**根本差异**：**一个是“程序自动使用的、权限有边界的工作负载身份”，
一个是“人手动用的、权限无边界的访问类身份”。** 两者都遵循
“SA（身份）+ 绑定（授权）+ Token（认证）”的 RBAC 模型，但使用方式、
凭证来源、权限边界和风险控制点完全不同。

---

## 九、复现命令

```bash
# 1. 看两处绑定
kubectl get clusterrolebinding pipeline-edit-binding -o yaml
kubectl get clusterrolebinding headlamp-root-cluster-admin -o yaml

# 2. 看使用方
kubectl -n cicd get pods -o json | jq -r '.items[] | select(.spec.serviceAccountName=="pipeline") | .metadata.name'
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.serviceAccountName=="headlamp-root") | .metadata.name'   # 应为空

# 3. 模拟两处身份的权限
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline exec pods            # no
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create pods          # yes
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root exec pods  # yes
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root create clusterrolebindings  # yes

# 4. 签发并验证 headlamp-root 的 token（需管理员）
TOKEN=$(kubectl -n headlamp create token headlamp-root --duration=10m)
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root '*' '*'    # yes
```
