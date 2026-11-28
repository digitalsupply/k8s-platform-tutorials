# RBAC 身份与绑定对比：`cicd/pipeline` 与 `headlamp/headlamp-root`（2026-11-26，2026-11-28 更新）

> 本文整合前几轮的 RBAC 概念（Role/ClusterRole、Binding、Subject、SA、Token），
> 用两个真实对象做对照，讲清**工作负载身份**和**访问类身份**的根本差异。
> 数据均为 `kubectl` 实测。

## 一、结论速览

| 维度 | `cicd/pipeline` + `ClusterRole/edit` | `headlamp/headlamp-root` + `ClusterRole/cluster-admin` |
|---|---|---|
| **身份用途** | 工作负载身份（给程序/Pod 用） | 访问类身份（给人用） |
| **使用主体** | 约 41 个 Pod（全在 `cicd`）自动使用 | **0 个 Pod**，人粘贴 token 使用 |
| **凭证获取** | Pod 自动挂载 token | 手工 `kubectl create token` 签发后粘贴 |
| **权限范围** | 集群级编辑（**表面有边界，实际可提权**） | 全集群全动作（无边界） |
| **能否 exec / 改 RBAC** | ⚠️ 能 exec；不能直接改 RBAC，但可 impersonate SA / 签 token / 建 Pod 提权 | ✅ 能 |
| **与 GitLab 的关系** | 不经过 GitLab，CI/CD 内部身份 | GitLab 登录后接棒的 k8s 身份 |

**一句话**：两者都是“SA + ClusterRole + ClusterRoleBinding”的三件套，但一个
是**程序自动用的身份**，一个是**人手动用的身份**；一个权限**表面有边界**，
一个**无边界**。

> **2026-11-27 更正**：`edit` 并不是“有边界”的角色。K8s 1.35 原生 `edit`
> 含 `impersonate serviceaccounts`、`create serviceaccounts/token`、
> `pods/exec` 写权限。`pipeline` 可借此直接变成 `headlamp-root`
> （cluster-admin），也可在 `headlamp` 命名空间创建一个
> `serviceAccountName: headlamp-root` 的 Pod。实测与修补建议见第七节。

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

**使用方**：约 41 个 Pod（全在 `cicd`，随流水线运行数量变化），包括：

- `el-*-listener`：Tekton **EventListener**，监听事件、创建 PipelineRun；
- `*-clone-pod`、`*-check-changes-pod`、`*-build-pod`、`*-update-gitops-pod`：
  流水线任务步骤，起 Pod、操作工作负载。

**权限**（`ClusterRole/edit`，集群级编辑）：

| 动作 | 结果 |
|---|---|
| create/delete pods、deployments、secrets、configmaps、services | ✅ |
| get/list/watch 各类资源 | ✅ |
| **exec pods**（`create pods/exec`） | **✅**（`edit` 含 `pods/exec` 写权限） |
| **create clusterrolebindings**（直接改 RBAC） | ❌ |
| **get nodes/proxy** | ❌ |
| **impersonate serviceaccounts** | **✅**（可冒充任意 SA） |
| **create serviceaccounts/token** | **✅**（可给任意 SA 签 token） |
| **create pods（指定任意 `serviceAccountName`）** | **✅**（可借高权 SA 的 Pod 提权） |

> **关键**：`edit` 不是“有边界”的角色。它虽然不能直接写 RBAC、不能
> `nodes/proxy`，但 `impersonate serviceaccounts` + `serviceaccounts/token`
> + 任意 Pod SA 这三条，任意一条都足以接管 `headlamp-root`。实测见第七节。

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

### 4. 权限范围不同：edit 表面有边界，实际可提权 vs cluster-admin 无边界

- **`edit`** 看起来是“有边界的集群级编辑”：不能直接写 RBAC、不能
  `nodes/proxy`、不能 impersonate 用户/组。但它**不是安全边界**：
  - 能 `create pods/exec`，可 exec 进任何 Pod；
  - 能 `impersonate serviceaccounts`，可直接 `--as` 成任意 SA；
  - 能 `create serviceaccounts/token`，可给任意 SA 签 token；
  - 能 `create pods` 并指定任意 `serviceAccountName`，Pod 会拿到该 SA 的
    token。
  在本集群，后三条都能指向 `headlamp-root` → **等价于 cluster-admin**
  （`pods/exec` 也能进 Headlamp Pod 拿它的挂载凭证，但该 Pod 本身没挂高权 token）。
- **`cluster-admin`** 是**无边界的全权限**：全资源、全动作，包括 exec、
  改 RBAC、直连 kubelet、impersonate。它是“想干什么都行”。

**权限差异的本质**：`pipeline` 名义上只需要“在集群里跑流水线”，但
`edit` 自带的 `impersonate`/`token`/`pods/exec` 让它**越过了“编辑”边界**。
真正的差异不是“edit 有边界、cluster-admin 无边界”，而是
**“edit 的边界可以被绕过，cluster-admin 不需要绕过”**。

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

- **`cicd/pipeline`**：权限偏大且**并非必须绑在集群级**——实测流水线只用
  `cicd` 命名空间。风险在于“流水线执行器被滥用时，能改任意命名空间的工作负载、
  读 Secret，还能提权到 `headlamp-root`”，需要降为命名空间级 + 准入策略约束。
- **`headlamp/headlamp-root`**：**最高权限**，风险在于“谁能拿到它的 token”。
  控制点是**凭证的分发**——但要注意，能签 token / impersonate / 建 Pod 指定
  SA 的实体不止管理员（见第七节）。

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

**第②步是人工的，但“能签发 token”本身就是一种权限。** 任何拥有
`create serviceaccounts/token`（或能 impersonate / 建 Pod 指定 SA）的实体，
都能替 `headlamp-root` 签 token——本集群的 `cicd/pipeline` 和两个 CSI SA
就是例子（见第七节）。

---

## 六、搭配考量（为什么这么配）

### `cicd/pipeline` 为什么用 `ClusterRole/edit`

1. **最初的理由是“要跨命名空间”**：当时认为流水线要在多个命名空间
   创建/删除工作负载，命名空间级的 Role 不够用。**但实测 PipelineRun/
   TaskRun 全部落在 `cicd`**，这个理由并不成立，至少应该降为 `cicd`
   命名空间级（见第七节修补建议）。
2. **`edit` 是“功能上够用”，但不是“最小集合”**：它能完成流水线动作，
   却同时带上了 `impersonate serviceaccounts`、`serviceaccounts/token`、
   `pods/exec` 写权限——这些对流水线并非必需，却足以提权到
   `headlamp-root`。**用 `edit` 是便利选择，不是安全选择。**
3. **用 ClusterRoleBinding 而非 RoleBinding**：因为需要跨命名空间。
   但本集群的 PipelineRun/TaskRun 实际只落在 `cicd`，这一点值得重新评估
   （见第七节修补建议）。

### `headlamp/headlamp-root` 为什么用 `ClusterRole/cluster-admin`

1. **定位是管理员**：需要完整控制权（含 exec、改 RBAC、排障）。
2. **只有这一个“人”用**：不追求最小权限的细粒度，而是靠“凭证分发”控制风险。
3. **绑定在 ClusterRoleBinding**：管理员权限天然是集群级的。

**两者的搭配逻辑一致**：**按“身份要干什么”来选角色，按“范围”选绑定类型**。
`pipeline` 要在 `cicd` 里干活 → 本应用 `RoleBinding` + `edit`（现在误用了
ClusterRoleBinding）；`headlamp-root` 要全权管理 → ClusterRoleBinding +
cluster-admin。

---

## 七、谁拥有 `edit` 权限、如何提权、怎么修

### 1. 谁拥有 `edit` 权限（2026-11-28 实测）

**直接绑定 `ClusterRole/edit` 的只有 1 个实体：**

| 类型 | 实体 | 绑定 | 范围 | 说明 |
|---|---|---|---|---|
| 直接 `edit` | `SA cicd/pipeline` | `ClusterRoleBinding/pipeline-edit-binding` | 全集群 | 3 个 Deployment、3 个 EventListener、约 40 个 Pod（随流水线运行变化） |

没有名为 `edit` 的 `Role`，也没有 `RoleBinding` 引用 `Role/edit`；也没有
绑定到 `ClusterRole/admin` 的实体。

**`edit` 的权限超集（`cluster-admin`）另有 3 个：**

| 类型 | 实体 | 绑定 | 说明 |
|---|---|---|---|
| 超集 | `Group system:masters` | `ClusterRoleBinding/cluster-admin` | 证书 CN 匹配，kubeadm 管理员 |
| 超集 | `Group kubeadm:cluster-admins` | `ClusterRoleBinding/kubeadm:cluster-admins` | kubeadm 引导组 |
| 超集 | `SA headlamp/headlamp-root` | `ClusterRoleBinding/headlamp-root-cluster-admin` | Headlamp 管理员 token |

> `system:masters` / `kubeadm:cluster-admins` 的成员来自**客户端证书**，
> 无法从 RBAC 对象里枚举。它们本来就拥有全部权限，不属于“edit 提权”。

### 2. `edit` 的三条提权链（全部实测）

**链路 A：签 token**

```bash
# 管理员 shell 里用 --as 模拟 pipeline 的授权身份（不是 pipeline 的 token）
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline
# → 成功返回 JWT；解码后 sub = system:serviceaccount:headlamp:headlamp-root
```

> 也可以直接用 `pipeline` 自己的 token 签，不需要 `--as`：
> `edit` 本身就含 `create serviceaccounts/token`。

**链路 B：impersonate**

```bash
# 用 pipeline 自己的 token，直接 --as 成 headlamp-root
# 注意：本机 kubeconfig 带客户端证书时 --token 会被证书覆盖，
# 需用只含 token 的临时 kubeconfig（见 11 号文档第十节第 14 条）。
PIPELINE_TOKEN=$(kubectl -n cicd create token pipeline --duration=10m)
kubectl --token="$PIPELINE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root
# → yes
kubectl --token="$PIPELINE_TOKEN" auth can-i delete clusterrolebindings \
  --as=system:serviceaccount:headlamp:headlamp-root
# → yes
```

**链路 C：建 Pod 指定 SA**

```bash
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server
# → pod/evil created (server dry run)
```

Pod 一旦真正创建，挂载的就是 `headlamp-root` 的 token，Pod 内直接拥有
cluster-admin。**这条链路不需要 `serviceaccounts/token`，也不需要
`impersonate`——只要“能在该命名空间建 Pod”就够。**

> 同一个 dry-run 用 `headlamp-bigdev` 身份也能通过。也就是说，
> `headlamp-bigdev` 虽然被设计成“受限开发者”，但因为它能建 Pod，仍可借
> `headlamp-root` 提权。**“不能签 token”不等于“不能提权”。**

### 3. 不止 `edit`：其他能签 token 的实体

`serviceaccounts/token` 的 `create` 还出现在这些角色里：

| 角色 | 绑定实体 | 范围 | 备注 |
|---|---|---|---|
| `edit` | `SA cicd/pipeline` | 全集群 | 本文重点 |
| `rbd-csi-ceph-com-ctrlplugin-cr` | `SA ceph-csi-rbd/rbd-csi-ceph-com-ctrlplugin-sa` | 全集群 | **实测可签 headlamp-root** |
| `rbd-csi-ceph-com-nodeplugin-cr` | `SA ceph-csi-rbd/rbd-csi-ceph-com-nodeplugin-sa` | 全集群 | **实测可签 headlamp-root** |
| `system:kube-controller-manager` | `User system:kube-controller-manager` | 全集群 | 系统组件，受信 |
| `admin` | 无绑定 | — | 预置角色 |

> **坑**：`kubectl auth can-i create serviceaccounts/token` 对 CSI SA 返回
> `no`，但实际 `kubectl create token` 成功（已用 CSI 自己的 token 验证）。
> 审计时不能只信 `can-i`，要实测签发或看 `auth can-i --list`。

### 4. 修补建议（按优先级）

#### 方案 1（推荐，改动最小）：把 pipeline 的 `edit` 降为命名空间级

本集群的 PipelineRun/TaskRun **全部落在 `cicd`**，没有跨命名空间写入的
证据。把 `ClusterRoleBinding` 换成 `cicd` 里的 `RoleBinding`：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pipeline-edit
  namespace: cicd
roleRef:
  kind: ClusterRole
  name: edit
subjects:
  - kind: ServiceAccount
    name: pipeline
    namespace: cicd
```

效果：

- pipeline 仍能在 `cicd` 里编辑；
- **不能再碰 `headlamp` 命名空间**，因此不能签 `headlamp-root` token、
  不能 impersonate 它、不能建 `headlamp-root` 的 Pod；
- `edit` 在 `cicd` 里仍可签 `cicd` 内 SA 的 token、exec `cicd` 的 Pod，
  但那里没有 cluster-admin SA，风险大幅下降。

> 前提：确认 pipeline 不需要写其他命名空间。若后续要跨命名空间部署，
> 用方案 2，而不是恢复 ClusterRoleBinding。

#### 方案 2（更彻底）：自定义 ClusterRole，去掉提权规则

从 `edit` 复制规则，删掉这些（其余按需保留）：

```yaml
# 不要包含：
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["impersonate"]
- apiGroups: [""]
  resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/proxy"]
  verbs: ["create", "delete", "deletecollection", "patch", "update"]
```

保留 `pods` 的 create/delete（流水线要建 Pod），但注意：**只要能建 Pod
并指定 SA，就仍可借 `headlamp-root` 提权**。所以方案 2 必须配合方案 3。

#### 方案 3（必须做）：限制 Pod 能使用的 SA

用 ValidatingAdmissionPolicy（K8s 1.30+ 内置）禁止在 `headlamp` 命名空间
创建使用 `headlamp-root`/`headlamp-bigdev` 的 Pod：

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: restrict-headlamp-access-sa
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        !(has(object.spec.serviceAccountName) &&
          object.spec.serviceAccountName in
            ["headlamp-root", "headlamp-bigdev"])
      message: "access-only SA cannot be used by pods"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: restrict-headlamp-access-sa
spec:
  policyName: restrict-headlamp-access-sa
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: headlamp
```

效果：即使有人能在 `headlamp` 建 Pod，也不能把 `headlamp-root` 设成
`serviceAccountName`。

> 同理，可对 `serviceaccounts/token` 做准入限制，只允许特定组为
> `headlamp-root` 签 token；但更稳的是直接删掉非管理员角色里的
> `serviceaccounts/token`。

#### 方案 4：收敛其他 token 签发者

- **CSI 角色**：确认 CSI 插件是否真的需要 `serviceaccounts/token`。
  不需要就删；需要就限定到自己的 SA（TokenRequest 的 URL 含 SA 名，
  RBAC 支持按 `resourceNames` 限制，需在目标版本验证）。
- **`system:kube-controller-manager`**：系统组件，保留，但纳入审计。
- **定期审计**：找所有含 `serviceaccounts/token` 的 ClusterRole，再查
  绑定主体；不要只看 `edit`。

### 5. 修补后的验证

```bash
# 1) pipeline 不应再能签 headlamp-root token
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline   # 应 403

# 2) pipeline 不应再能 impersonate
kubectl auth can-i impersonate serviceaccounts \
  --as=system:serviceaccount:cicd:pipeline    # 应 no

# 3) pipeline 不应再能建 headlamp-root 的 Pod
kubectl -n headlamp run x --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server                            # 应被拒绝

# 4) 流水线回归：触发一次真实流水线，确认能正常建 PipelineRun/Pod
```

### 6. 其他问题

| # | 对象 | 问题 | 建议 |
|---|---|---|---|
| 1 | `cicd/pipeline` | `edit` 含 `impersonate`/`token`/`pods/exec`，可提权到 `headlamp-root`；含 Secret 写、可建任意命名空间的 Pod | 优先按方案 1 降为 `cicd` 命名空间级；再按方案 2/3 收敛 |
| 2 | `headlamp/headlamp-root` | `cluster-admin` 最高权限，依赖“谁能拿到 token” | 严格控制 token 分发；不把 token 写进文档/聊天/代码；用短时效 token |
| 3 | `headlamp/headlamp-bigdev` | 不能签 token，但能建 Pod → 可借 `headlamp-root` SA 提权 | 方案 3 的准入限制；或收回 `create pods` |
| 4 | 两者共性 | 身份是共享的：同 SA 的所有使用者权限完全相同 | 如需按人/按 Pod 区分，必须拆成多个 SA（或上 apiserver OIDC 做用户级 RBAC） |

---

## 八、总结对照表

| 对比项 | `cicd/pipeline` + `edit` | `headlamp/headlamp-root` + `cluster-admin` |
|---|---|---|
| 权限本体 | `ClusterRole/edit`（集群级编辑） | `ClusterRole/cluster-admin`（全集群全动作） |
| 连接 | `ClusterRoleBinding/pipeline-edit-binding` | `ClusterRoleBinding/headlamp-root-cluster-admin` |
| Subject | `SA cicd/pipeline` | `SA headlamp/headlamp-root` |
| 身份用途 | 工作负载身份（程序用） | 访问类身份（人用） |
| 使用主体 | 约 41 个 Pod（全在 `cicd`） | 0 个 Pod，人粘贴 token |
| 凭证获取 | Pod 自动挂载 | 手工 `kubectl create token` 后粘贴 |
| 认证方式 | Pod 带 token 调 apiserver | 人粘贴 token，Headlamp 转发 |
| 授权范围 | 集群级，**表面有边界，实际可提权** | 集群级，无边界 |
| 与 GitLab 关系 | 无关（CI/CD 内部） | GitLab 登录后接棒（两层认证） |
| 生命周期 | 随工作负载 | 长期存在，无工作负载 |
| 主要风险 | 可 impersonate/签 token/建高权 SA 的 Pod → 提权到 cluster-admin | 凭证泄露即全权 |

**根本差异**：**一个是“程序自动使用的、名义上有边界但可绕过的工作负载身份”，
一个是“人手动用的、权限无边界的访问类身份”。** 两者都遵循
“SA（身份）+ 绑定（授权）+ Token（认证）”的 RBAC 模型，但使用方式、
凭证来源、权限边界和风险控制点完全不同。

> **不要把 `edit` 当作安全边界**。在本集群，`pipeline` 通过
> `impersonate serviceaccounts`、`serviceaccounts/token` 或“建一个
> `serviceAccountName: headlamp-root` 的 Pod”三条路径中的任意一条，
> 都能拿到 cluster-admin。修补见第七节。

---

## 九、复现命令

```bash
# 1. 看两处绑定
kubectl get clusterrolebinding pipeline-edit-binding -o yaml
kubectl get clusterrolebinding headlamp-root-cluster-admin -o yaml

# 2. 看使用方
kubectl -n cicd get pods -o json | jq -r '.items[] | select(.spec.serviceAccountName=="pipeline") | .metadata.name'
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.serviceAccountName=="headlamp-root") | .metadata.name'   # 应为空

# 3. 枚举所有绑定到 ClusterRole/edit 的实体
kubectl get rolebinding,clusterrolebinding -A -o json | jq -r '
  .items[] | select(.roleRef.kind=="ClusterRole" and .roleRef.name=="edit") |
  "\(.kind) \(.metadata.namespace // "(cluster)")/\(.metadata.name) -> " +
  ([.subjects[]? | "\(.kind):\(.namespace // "")/\(.name)"] | join(", "))'

# 4. 正确模拟权限（注意：exec 不是 RBAC 动词）
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create pods/exec     # yes
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create pods          # yes
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline impersonate serviceaccounts  # yes
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create serviceaccounts/token  # yes
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create clusterrolebindings     # no
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root create pods/exec      # yes
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root create clusterrolebindings  # yes

# 5. 提权链 A：以 pipeline 身份签 headlamp-root token
kubectl -n headlamp create token headlamp-root --duration=10m \
  --as=system:serviceaccount:cicd:pipeline

# 6. 提权链 B：以 pipeline 自己的 token impersonate
#    必须用只含 token 的临时 kubeconfig，否则本机客户端证书会覆盖 --token
PIPE_TOKEN=$(kubectl -n cicd create token pipeline --duration=10m)
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
echo "$CA" | base64 -d > /tmp/k8s-ca.crt
KUBECONFIG=/tmp/none kubectl --server="$SRV" --certificate-authority=/tmp/k8s-ca.crt \
  --token="$PIPE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root     # yes

# 7. 提权链 C：建一个使用 headlamp-root SA 的 Pod（server dry-run）
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server

# 8. 对照：CSI SA 也能签 headlamp-root token
#    （token 最短有效期 10m；同样要绕开客户端证书）
CSI_TOKEN=$(kubectl -n ceph-csi-rbd create token rbd-csi-ceph-com-ctrlplugin-sa --duration=10m)
KUBECONFIG=/tmp/none kubectl --server="$SRV" --certificate-authority=/tmp/k8s-ca.crt \
  --token="$CSI_TOKEN" -n headlamp create token headlamp-root --duration=10m
```
