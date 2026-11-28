# 集群 ServiceAccount 全景审计（2026-11-25）

> 范围：整个集群 **136 个 ServiceAccount**，按命名空间分组。
> 内容：每个 SA 的**作用、被谁绑定、权限为什么是这样**，以及**过期/可清理**清单。
> 数据均为 `kubectl` 实测，采集时间 2026-11-25。

## 一、方法与口径

```bash
# 采集对象
kubectl get sa -A -o json                     # SA 本体
kubectl get rolebinding -A -o json            # 命名空间内绑定
kubectl get clusterrolebinding -o json        # 集群级绑定
kubectl get pods -A -o json                   # 实际使用方
kubectl get deploy,sts,ds,job,cronjob -A -o json   # 工作负载定义
kubectl get secrets -A -o json                # 查找遗留 token Secret

# 判断权限
kubectl auth can-i --as=system:serviceaccount:<ns>:<sa> <verb> <resource>
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>
```

口径说明：

- **“被谁绑定”** = 所有 `RoleBinding` / `ClusterRoleBinding` 中
  `subjects` 指向该 SA 的条目，`roleRef` 就是它拿到的权限来源。
- **“使用方”** = 显式声明 `serviceAccountName` 的 Pod / 工作负载；
  没有声明的 Pod 走该命名空间的 `default` SA。
- **“过期/可清理”** = 没有工作负载、绑定变成死引用，或所在命名空间已空。

---

## 二、总览

| 指标 | 数量 |
|---|---|
| 命名空间 | 31 |
| ServiceAccount 总数 | **136** |
| 有自定义绑定 | 95 |
| 无自定义绑定 | 41 |
| 有运行中的 Pod | 72 |
| 有工作负载对象（deploy/sts/ds/job/cronjob） | 63 |
| ArgoCD 托管（带 tracking-id 注解） | 39 |
| **纯孤儿（无绑定、无工作负载、无遗留 token）** | 20（全部是 `default`） |
| **遗留长期 token Secret（`type=kubernetes.io/service-account-token`）** | **0** |
| 集群内 Pod 总数 / 有效挂载 SA token | 182 / 156（26 个有效不挂载：13 个 Pod 显式 false + 13 个继承 SA false） |
| 绑定到 `cluster-admin` 的主体 | 3 个活跃（另 1 个 `admin-user` 已于 2026-11-26 删除） |
| 绑定到 `ClusterRole/edit` 的主体 | **1 个**（`SA cicd/pipeline`，集群级；可提权到 cluster-admin） |
| binding 中的 subject 类型 | SA 177 个 / User 10 个 / Group 24 个（去重后 103 个 SA 作为 subject） |

**三个最重要的结论：**

1. **集群里没有任何长期 ServiceAccount token Secret**。所有 token 都是
   `kubectl create token` / 控制器动态签发的 bound token（JWT，默认 1h），
   不存在“一个 Secret 永久有效”的隐患。这一点是好的。
2. **唯一绑定 `cluster-admin` 的活跃使用方 SA 是 `headlamp-root`**，
   用于管理员登录 Headlamp。此前有一个**死绑定** `admin-user` 指向已删除
   命名空间里的 SA，**已于 2026-11-26 删除**。业务类 SA（如 `cicd/pipeline`、
   `gitlab-runner`）直接绑定不是 cluster-admin，但 `cicd/pipeline` 的 `edit`
   可经签 token / impersonate / Pod-SA 提权到 cluster-admin（见第六节第 5 小节）。
3. **20 个“孤儿”全部是各命名空间的 `default` SA**，是 Kubernetes 自动创建
   的，不是业务遗留，一般不建议删除。`admin-user` 已清理，剩余 2 项一次性 SA
   （见第八节）。

---

## 三、核心概念：Subject、ServiceAccount、Pod 与 apiserver

前面按命名空间列了每个 SA 的绑定，这里把“**SA 是什么、subject 是什么、Pod 到底需不需要 SA**”
讲清楚，避免把概念混在一起。

### 1. RBAC 的三要素：Role、Binding、Subject

RBAC 由三个东西组成，缺一不可：

| 要素 | 作用 | 例子 |
|---|---|---|
| **Role / ClusterRole** | 定义权限（能做什么） | `ClusterRole/cluster-admin`、`Role/pg16-ceph` |
| **RoleBinding / ClusterRoleBinding** | 把权限“挂”给某些身份 | `headlamp-root-cluster-admin` |
| **Subject** | 被授权者（谁拿到这些权限） | `ServiceAccount headlamp-root`、`Group system:masters` |

一个绑定的结构就是：

```yaml
kind: ClusterRoleBinding
metadata:
  name: headlamp-root-cluster-admin
roleRef:            # ① 权限来自哪个 Role/ClusterRole
  kind: ClusterRole
  name: cluster-admin
subjects:           # ② 这些身份拿到上面的权限
  - kind: ServiceAccount
    name: headlamp-root
    namespace: headlamp
```

**所以“SA 被谁绑定”本质是：这个 SA 的名字出现在哪些 RoleBinding /
ClusterRoleBinding 的 `subjects` 里。**

### 2. Role / ClusterRole：权限本体，以及它如何与 Subject 关联

**Role 和 ClusterRole 都是“权限规则集”**，回答的是“允许对哪些资源做哪些动作”。
它们本身**不会**把权限给任何人，必须通过 Binding 与 Subject 连接后，Subject
才获得这些权限。

**两者的区别是作用范围：**

| | Role | ClusterRole |
|---|---|---|
| 作用范围 | **单个命名空间内** | **整个集群** |
| 能授权的资源 | 该命名空间内的资源 | 集群级资源（nodes、namespaces、PV、clusterroles…）+ 所有命名空间的命名空间级资源 |
| 一般由谁引用 | `RoleBinding` | `ClusterRoleBinding`（`RoleBinding` 也可以引用 ClusterRole） |

**为什么分两种**：K8s 资源本身分两类，Role 管不了集群级资源：

- **命名空间级资源**：pods、services、configmaps、secrets、deployments…
- **集群级资源**：nodes、namespaces、persistentvolumes、storageclasses、
  clusterroles、clusterrolebindings…

**权限规则长什么样**：每条规则是「apiGroups + resources + verbs」三元组：

```yaml
kind: ClusterRole
metadata:
  name: headlamp-bigdev
rules:
  - apiGroups: [""]                        # 核心组
    resources: ["pods"]                    # 针对 pods
    verbs: ["get", "list", "watch"]        # 只读
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
```

**与 Subject 的关系（关键链路）**：

```text
Subject（谁）                ← subjects 引用
    ↑
RoleBinding / ClusterRoleBinding   （把“谁”和“哪个权限”连起来）
    ↑ roleRef 引用
Role（命名空间内权限） / ClusterRole（集群级权限）   （权限规则本体）
```

一句话总结：**Role/ClusterRole 是“权限”，Binding 是“连接”，Subject 是“谁”。**

**四种组合决定 Subject 最终拿到的权限范围：**

| roleRef | 绑定类型 | Subject 最终权限范围 |
|---|---|---|
| `Role` | `RoleBinding` | **仅该命名空间内** |
| `ClusterRole` | `ClusterRoleBinding` | **整个集群** |
| `ClusterRole` | `RoleBinding` | **仅该命名空间内**（把集群级规则“降”到命名空间） |
| `Role` | `ClusterRoleBinding` | ❌ 不允许（ClusterRoleBinding 只能引用 ClusterRole） |

**本集群实例：**

| 权限本体 | 绑定 | Subject | 实际效果 |
|---|---|---|---|
| `ClusterRole/cluster-admin`（规则 `*`→`*`→`*`） | `ClusterRoleBinding/headlamp-root-cluster-admin` | `SA headlamp/headlamp-root` | **全集群全权限** |
| `ClusterRole/edit`（集群级编辑） | `ClusterRoleBinding/pipeline-edit-binding` | `SA cicd/pipeline` | **全集群编辑**（含 Secret 写） |
| `Role/pg16-ceph`（仅 cnpg-system 内 pg16-ceph 相关 CR/Secret） | `RoleBinding/pg16-ceph` | `SA cnpg-system/pg16-ceph` | **仅 cnpg-system 内** |
| `ClusterRole/strimzi-cluster-operator-namespaced` | `RoleBinding/strimzi-cluster-operator` | `SA kafka/strimzi-cluster-operator` | ClusterRole 经 **RoleBinding** 引用，权限**限定在 kafka 命名空间** |

最后一行是容易忽略的点：**`RoleBinding` 也能引用 `ClusterRole`**，此时虽然
引用的是集群级角色，但授予范围被限制在该 RoleBinding 所在的命名空间。

**内置角色的聚合**：`edit` / `view` / `admin` 不是手写规则，而是用
`aggregationRule`（按标签聚合其它 ClusterRole）生成；`cluster-admin` 则是
直接的 `*` 通配规则。

### 3. Subject 有三种类型

`subjects` 里可以放三种身份，**ServiceAccount 只是其中一种**：

| kind | 代表 | 说明 |
|---|---|---|
| `ServiceAccount` | `headlamp/headlamp-root` | K8s 内置身份，**命名空间级**；Pod 和 token 的身份 |
| `User` | `system:kube-controller-manager`、OIDC 用户如 `root` | 单个身份，可以是人或外部系统 |
| `Group` | `system:masters`、`kubeadm:cluster-admins`、OIDC 组如 `digitalsupply` | 一组身份 |

**本集群实测**：所有 binding 的 subject 一共 **211 个**，其中
**ServiceAccount 177 个、User 10 个、Group 24 个**；去重后有 **103 个 SA**
作为 subject。User/Group 基本都是 `system:*` 系统身份
（如 `system:kube-scheduler`、`system:authenticated`、`system:nodes`）。

> 注意：本集群 **apiserver 没有配置 OIDC**，所以 K8s RBAC 里**没有**
> `root`/`digitalsupply` 这类 OIDC 用户/组绑定。GitLab 用户能获得 k8s 身份，
> 是通过 Headlamp 的 SA token（见下文例子），而不是直接作为 RBAC 的
> User/Group subject。

### 4. ServiceAccount 是“身份”，绑定才给“权限”

- **SA 对象本身不包含任何权限**。它只是一个身份载体。
- 权限来自“以该 SA 为 subject 的绑定”。
- SA 对应的完整 K8s 身份名是：**`system:serviceaccount:<namespace>:<name>`**。
  例如 `headlamp-root` 的 token，其 `sub` 就是
  `system:serviceaccount:headlamp:headlamp-root`。

所以两条线要分开看：

```text
ServiceAccount（身份）  ──被绑定──>  Role/ClusterRole（权限）
        │
        └─ Pod 用它去访问 apiserver 时，才真正“用到”这份权限
```

### 5. Pod 与 SA：每个 Pod 都有身份，但不是都要访问 apiserver

这是最容易搞混的一点，分三层：

1. **每个 Pod 都必然有一个 SA**。Pod 显式写 `serviceAccountName` 就用它；
   不写就用所在命名空间的 `default` SA。不存在“没有 SA 的 Pod”。
2. **SA 提供身份（token），绑定决定这个身份能做什么**。有 SA 但没有绑定，
   Pod 只能拿到 `system:authenticated` 的基线权限。
3. **是否需要访问 apiserver，决定 SA 的权限是否真正生效**：
   - Pod 代码会调 apiserver（创建对象、读 Secret、列举资源）→ 需要
     **指定 SA + 该 SA 有绑定**，否则会 403。
   - Pod 完全不调 apiserver（只连数据库/外部接口、只读挂载卷）→ SA 只是
     “白给”的身份，token 挂进来也不用，可以关掉自动挂载。

`automountServiceAccountToken` 控制是否把 token 挂进 Pod：

- `true`（默认）：Pod 里挂载 `/var/run/secrets/kubernetes.io/serviceaccount/`
  的 token。
- `false`：不挂载。Pod 即使想调 apiserver 也没有现成的 token 可用，适合
  **确定不访问 apiserver** 的 Pod。

> 截至 2026-11-27，本集群 182 个 Pod 中，Pod 字段显式
> `automountServiceAccountToken: false` 的有 **13 个**；但把 **SA 级设置**
> 也算进去后，**有效不挂载的是 26 个**（另有 13 个 `tempo3` Pod 继承了
> SA 上的 `false`）。早期快照“168 个 Pod / 155 个挂载 / 13 个关闭”是
> **只看 Pod 字段**的口径。
>
> 完整清单、配置来源和三个口径陷阱见
> [第六节第 4 小节](#4-自动挂载-sa-token-的-pod口径清单与考量)。

### 6. 什么 Pod 需要 SA + 访问 apiserver

| 场景 | 原因 | 本集群例子 |
|---|---|---|
| 控制器 / Operator / Webhook | 要管理 K8s 对象、处理准入 | `argocd-*`、`cert-manager`、`cilium`、`prometheus-operator` |
| 需要创建/管理 K8s 对象的业务 | 在集群里起资源 | `cicd/pipeline`（创建 PipelineRun）、`gitlab-runner`（创建任务 Pod） |
| 需要读集群内 Secret/配置的组件 | 拿凭据/配置 | `sealed-secrets-controller`、`pg16-ceph` |

**共同特征**：这些 SA 在绑定里有对应的 Role/ClusterRole，且 Pod 实际会调
apiserver。

### 7. 如何验证某个 SA 身份的权限（`auth can-i --as`）

一个 Pod 指定 `serviceAccountName: <sa>` 后，它访问 apiserver 时的**身份就是
该 SA**，会自动继承这个 SA 被绑定到的全部权限——**Pod 本身不需要再单独绑定**。
验证这个身份能做什么，最直接的方式就是模拟它的身份问 apiserver：

```bash
# 看该 SA 身份的完整权限清单
kubectl auth can-i --list --as=system:serviceaccount:cicd:pipeline

# 看某个具体动作是否允许
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create configmaps
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create clusterrolebindings
```

**为什么这条命令能代表 Pod 的真实权限：**

- `--as=system:serviceaccount:<ns>:<sa>` 就是 Pod 挂载的 SA token 里 `sub`
  对应的身份；
- `auth can-i` 让 apiserver 以该身份做一次授权判断，和 Pod 带着 token 调
  apiserver 时走的判定**完全一致**（纯授权判断，不校验 token 真伪）；
- 因此它返回的 yes/no，就是该 SA 身份实际能行使的权限。

**三个前提（缺一个就“理论有权限、实际用不上”）：**

1. **Pod 要挂载到 token**：`automountServiceAccountToken` 必须为 `true`
   （默认）。设为 `false` 的 Pod 没有 token，无法以该身份调 apiserver。
2. **Pod 要真的调用 apiserver**：不调 API 的 Pod，即使挂着高权限 SA 也不会
   用到这份权限（身份和权限仍存在，属于潜在面）。
3. **SA 要有绑定**：没有绑定的 SA 只有基线权限，`--as` 查出来也只有
   discovery、basic-user 等。

**身份是共享的**：所有指定同一个 SA 的 Pod，权限完全相同，无法区分到具体
Pod。要按 Pod/人区分，必须给每个工作负载建独立 SA。

**端到端验证（真正用该 SA 的 Pod 调 apiserver）**

`--as` 是“模拟”，要确认“实际能行”，可以起一个挂载该 SA 的 Pod，用它自己的
token 调 apiserver：

```bash
kubectl -n cicd run sa-e2e --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"serviceAccountName":"pipeline","automountServiceAccountToken":true,"restartPolicy":"Never"}}' \
  -- sh -c '
T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
# 有权限的动作 -> 201
curl -sk -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"sa-e2e-cm\",\"namespace\":\"cicd\"}}" \
  https://kubernetes.default.svc/api/v1/namespaces/cicd/configmaps -w "HTTP %{http_code}\n" -o /dev/null
# 无权限的动作 -> 403
curl -sk -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d "{\"apiVersion\":\"rbac.authorization.k8s.io/v1\",\"kind\":\"ClusterRoleBinding\",\"metadata\":{\"name\":\"sa-e2e-crb\"},\"roleRef\":{\"kind\":\"ClusterRole\",\"name\":\"view\",\"apiGroup\":\"rbac.authorization.k8s.io\"},\"subjects\":[{\"kind\":\"User\",\"name\":\"x\"}]}" \
  https://kubernetes.default.svc/apis/rbac.authorization.k8s.io/v1/clusterrolebindings -w "HTTP %{http_code}\n" -o /dev/null
'
```

实测结果：创建 ConfigMap **HTTP 201**（允许）、创建 ClusterRoleBinding
**HTTP 403**（拒绝），与 `kubectl auth can-i --as=system:serviceaccount:cicd:pipeline`
的判断完全一致。

**一个容易踩的坑**：不要在带**客户端证书**的 kubeconfig 上用
`kubectl --token=<SA token>` 来“扮演” SA。此时客户端证书的身份会**覆盖**
token，`--token` 实际不生效，查到的仍是管理员权限。本集群实测：

```bash
# 客户端证书 kubeconfig + --token，仍然被当成管理员
kubectl --token="$TOKEN" auth can-i '*' '*'        # yes（错误，被证书覆盖）
# 正确做法：用 --as 明确模拟 SA 身份
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline '*' '*'   # 按 SA 真实权限
```

**模拟 SA 身份用 `--as`；要真实验证就用上面这种挂载该 SA 的 Pod。**

### 8. 什么 Pod 不需要 SA / apiserver

| 场景 | 原因 | 本集群例子 |
|---|---|---|
| 纯应用后端 | 只连数据库/外部 HTTP，不碰 K8s API | `keycloak`（连 PostgreSQL）、`open-webui`、`kafka` broker |
| 反向代理 | 只转发流量 | `oauth2-proxy/*`（5 个 Pod，用 `default` SA、无绑定） |
| 只读节点/挂载卷的采集器 | 直接读节点指标或挂载卷，不调 API | `prometheus-prometheus-node-exporter`（显式 `false`）、`etcd-snapshot`（直连 etcd，显式 `false`）、`hubble-relay` |

这类 Pod 通常：
- 用 `default` SA 或一个无绑定的 SA；
- 最好设置 `automountServiceAccountToken: false`，减少被利用面。

### 9. 集群实际例子（与本次审计一一对应）

| SA（作为 subject） | 绑定 | 使用方 Pod | 是否访问 apiserver | 说明 |
|---|---|---|---|---|
| `headlamp/headlamp-root` | `ClusterRole/cluster-admin` | **无 Pod** | 否（人粘贴 token） | **纯访问类 SA**：不跑工作负载，只作为登录 token 的 subject |
| `headlamp/headlamp-bigdev` | `ClusterRole/headlamp-bigdev` | **无 Pod** | 否（人粘贴 token） | 同上，受限访问类 |
| `cicd/pipeline` | `ClusterRole/edit` | 约 40 个 Pod（`el-*`、build/clone/check） | **是** | 流水线执行器要创建/删除 PipelineRun、任务 Pod；实际只用到 `cicd`，建议降为命名空间级 |
| `gitlab-runner/gitlab-runner` | `Role/gitlab-runner-manager`（通配） | 1 Pod | **是** | Runner 要创建任务 Pod、读命名空间 Secret |
| `kube-system/deployment-controller` | `ClusterRole/system:controller:deployment-controller` | 静态 Pod | **是** | 控制器管理 Deployment/ReplicaSet |
| `oauth2-proxy/default` | **无绑定** | 5 个 Pod | **否** | 反向代理，不用调 apiserver，只有基线身份 |
| `etcd-backup/default` | **无绑定** | 快照 Job（`automount: false`） | **否** | 直连 etcd 做快照，显式不挂 token |
| `monitoring/prometheus-prometheus-node-exporter` | **无绑定** | DaemonSet（`automount: false`） | **否** | 只读节点指标 |
| `kafka/my-cluster-kafka` | 仅 `get` 3 个指定 Secret | 1 Pod | 基本否 | 只取证书，权限被压到最小 |

### 10. 几个容易踩的点

- **“SA 被绑定”不等于“SA 有权限”**：绑定的是角色，角色里写什么才有什么。
- **`default` SA 也能被绑定**：例如 `cicd/default` 绑了 `openwebui-runner-role`，
  于是该命名空间里用 `default` 的 Pod 也能创建 PipelineRun。
- **User/Group 是另外两种 subject**：本集群里主要是 `system:*` 身份；
  要给 GitLab 用户/组直接做 k8s RBAC，需要 apiserver 配 OIDC，目前没有。
- **无绑定 ≠ 不能用**：没有自定义绑定的 SA/Pod 仍能认证，只是只有基线权限。

## 四、集群里的真实例子：命令 + 配置 + 作用

概念讲完，这里用**本集群真实存在的对象**把「权限本体 → 连接 → Subject → 效果」
彻底跑通。每个例子都给出：**查什么命令、对象是什么配置、这样配的作用是什么**。

### 例子 1：全集群最高权限 `cluster-admin` → `headlamp-root`

**命令：**

```bash
# 看权限本体
kubectl get clusterrole cluster-admin -o yaml
# 看连接
kubectl get clusterrolebinding headlamp-root-cluster-admin -o yaml
# 看 Subject（SA）
kubectl get sa headlamp-root -n headlamp -o yaml
# 验证效果
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root '*' '*'
```

**配置：**

```yaml
# ① 权限本体：ClusterRole（集群级）
kind: ClusterRole
metadata:
  name: cluster-admin
rules:
  - apiGroups: ["*"]      # 所有 API 组
    resources: ["*"]      # 所有资源
    verbs: ["*"]          # 所有动作
  - nonResourceURLs: ["*"]
    verbs: ["*"]
```

```yaml
# ② 连接：ClusterRoleBinding
kind: ClusterRoleBinding
metadata:
  name: headlamp-root-cluster-admin
roleRef:                  # 引用集群级权限
  kind: ClusterRole
  name: cluster-admin
subjects:                 # Subject：谁拿到这些权限
  - kind: ServiceAccount
    name: headlamp-root
    namespace: headlamp
```

**作用：**

- `cluster-admin` 是“全资源全动作”的集群级角色；
- 经 **ClusterRoleBinding** 挂给 Subject `headlamp/headlamp-root`；
- 这个 SA 不跑 Pod，它的 token 被粘贴到 Headlamp 登录后，身份
  `system:serviceaccount:headlamp:headlamp-root` 即获得**全集群全权限**；
- 这是 **ClusterRole + ClusterRoleBinding + SA subject → 全集群** 的标准链路。

### 例子 2：集群级编辑 `edit` → `cicd/pipeline`

**命令：**

```bash
kubectl get clusterrole edit -o yaml
kubectl get clusterrolebinding pipeline-edit-binding -o yaml
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create secrets
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create clusterrolebindings
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create pods/exec
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline impersonate serviceaccounts
kubectl auth can-i --as=system:serviceaccount:cicd:pipeline create serviceaccounts/token
```

**配置：**

```yaml
# ① 权限本体：ClusterRole edit（内置聚合角色，规则很多，节选）
kind: ClusterRole
metadata:
  name: edit
aggregationRule:                     # 由带标签的 ClusterRole 聚合而成
  clusterRoleSelectors:
    - matchLabels:
        rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:                               # 聚合后实际生效的规则（节选）
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps", "services", "serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["create", "delete", "update", "patch"]
```

```yaml
# ② 连接：ClusterRoleBinding
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

**作用：**

- `edit` 是集群级“编辑”角色，覆盖 pods/secrets/deployments 等资源的增删改；
- 挂给 `cicd/pipeline` 这个 SA，流水线里的 Pod（`el-*` 等）用它调 apiserver
  时，就能创建/删除 PipelineRun、任务 Pod；
- 注意 `edit` **包含 Secret 的增删**，所以 `cicd/pipeline` 是业务 SA 中权限
  偏大的典型；
- **它不能直接创建 clusterrolebinding，但可以提权**：`edit` 含
  `impersonate serviceaccounts`、`create serviceaccounts/token`、
  `pods/exec` 写权限，还能建 Pod 并指定任意 `serviceAccountName`。

**实测提权（2026-11-28）：**

```bash
# A. 以 pipeline 身份给 headlamp-root 签 token
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline          # 成功

# B. 用 pipeline 自己的 token impersonate headlamp-root
PIPE_TOKEN=$(kubectl -n cicd create token pipeline --duration=10m)
kubectl --token="$PIPE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root # yes
# 注意：本机 kubeconfig 带客户端证书时 --token 会被证书覆盖，
# 需用只含 token 的临时 kubeconfig；见第十节复现命令。

# C. 建一个用 headlamp-root SA 的 Pod（dry-run 通过）
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server                                   # created (server dry run)
```

结论：**`ClusterRole/edit` 在本集群等价于 cluster-admin 的跳板**，因为
`headlamp` 命名空间里存在一个绑定 cluster-admin 的 SA。修补建议见
[第六节第 5 小节](#5-edit-的隐藏提权面token-签发与-pod-sa)。

> 用 `kubectl auth can-i --list --as=system:serviceaccount:cicd:pipeline`
> 即可验证这约 40 个 Pod 共享的这份权限（详见第六节第 5 小节）。

### 例子 3：命名空间内权限 `Role/pg16-ceph` → `cnpg-system/pg16-ceph`

**命令：**

```bash
kubectl get role pg16-ceph -n cnpg-system -o yaml
kubectl get rolebinding pg16-ceph -n cnpg-system -o yaml
# 同命名空间有权限
kubectl auth can-i --as=system:serviceaccount:cnpg-system:pg16-ceph list secrets -n cnpg-system
# 跨命名空间没有权限
kubectl auth can-i --as=system:serviceaccount:cnpg-system:pg16-ceph list secrets -n default
```

**配置：**

```yaml
# ① 权限本体：Role（仅 cnpg-system 命名空间内）
kind: Role
metadata:
  name: pg16-ceph
  namespace: cnpg-system
rules:
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resourceNames: ["pg-secret", "pg-superuser-secret", "pg16-ceph-ca"]
    resources: ["secrets"]          # 只允许读这几个指定 Secret
    verbs: ["get", "watch"]
  # … 其余规则仅针对 pg16-ceph 相关 CR 和对象
```

```yaml
# ② 连接：RoleBinding
kind: RoleBinding
metadata:
  name: pg16-ceph
  namespace: cnpg-system
roleRef:
  kind: Role
  name: pg16-ceph
subjects:
  - kind: ServiceAccount
    name: pg16-ceph
    namespace: cnpg-system
```

**作用：**

- Role 只作用于 `cnpg-system` 命名空间，且规则只针对 `pg16-ceph` 集群；
- 经 **RoleBinding** 挂给该命名空间的 `pg16-ceph` SA；
- 该 SA 在 `cnpg-system` 内能管理这个 PostgreSQL 集群、读指定 Secret，
  **跨到其它命名空间就没有权限**；
- 这是 **Role + RoleBinding + SA subject → 仅命名空间内** 的标准链路，
  也是 CNPG 官方推荐做法，权限边界清晰。

### 例子 4：ClusterRole 经 RoleBinding “降范围” `strimzi-cluster-operator`

**命令：**

```bash
kubectl get clusterrole strimzi-cluster-operator-namespaced -o yaml
kubectl get rolebinding strimzi-cluster-operator -n kafka -o yaml
# 在 kafka 命名空间内可以
kubectl auth can-i --as=system:serviceaccount:kafka:strimzi-cluster-operator create deployments -n kafka
# 在其它命名空间不可以
kubectl auth can-i --as=system:serviceaccount:kafka:strimzi-cluster-operator create deployments -n default
```

**配置：**

```yaml
# ① 权限本体：ClusterRole（集群级定义）
kind: ClusterRole
metadata:
  name: strimzi-cluster-operator-namespaced
rules:                              # 节选
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods", "secrets", "configmaps", "services", "deployments"]
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
```

```yaml
# ② 连接：RoleBinding（注意：不是 ClusterRoleBinding）
kind: RoleBinding
metadata:
  name: strimzi-cluster-operator
  namespace: kafka
roleRef:
  kind: ClusterRole                 # 引用的是 ClusterRole
  name: strimzi-cluster-operator-namespaced
subjects:
  - kind: ServiceAccount
    name: strimzi-cluster-operator
    namespace: kafka
```

**作用：**

- 关键：`roleRef` 是 **ClusterRole**，但绑定是 **RoleBinding**（在 kafka 命名空间）；
- 所以虽然引用的是集群级角色，**授予范围被限制在 kafka 命名空间**：
  在 kafka 内能创建 deployment，到 default 等其它命名空间就无权限；
- 这验证了 **ClusterRole + RoleBinding → 仅命名空间内** 的组合，
  是把集群级规则按命名空间收窄的常用手法。

### 例子 5：对照组——无绑定的 SA，只有基线权限 `oauth2-proxy/default`

**命令：**

```bash
kubectl get sa default -n oauth2-proxy -o yaml
kubectl get rolebinding -n oauth2-proxy -o name      # 应无输出
kubectl get clusterrolebinding -o json | \
  jq '.items[] | select(.subjects[]?.name=="default" and .subjects[]?.namespace=="oauth2-proxy")'
kubectl auth can-i --as=system:serviceaccount:oauth2-proxy:default list pods
kubectl auth can-i --as=system:serviceaccount:oauth2-proxy:default list secrets
```

**配置：**

```yaml
# ① Subject：只有这个 SA，没有任何绑定指向它
kind: ServiceAccount
metadata:
  name: default
  namespace: oauth2-proxy
# ② 不存在对应的 Role / RoleBinding / ClusterRoleBinding
```

**作用：**

- oauth2-proxy 是反向代理，**不调 apiserver**；
- 它用的 `default` SA **没有任何绑定**，因此只有 `system:authenticated`
  的基线权限，`list pods`、`list secrets` 都是 `no`；
- 这组对照说明：**有 SA 不等于有权限，权限完全由绑定决定**；
  不访问 apiserver 的 Pod，无绑定正好合适，也不该给它多余权限。

### 例子 6：自定义细粒度权限 `headlamp-bigdev`

**命令：**

```bash
kubectl get clusterrole headlamp-bigdev -o yaml
kubectl get clusterrolebinding headlamp-bigdev-limited -o yaml
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-bigdev get secrets
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-bigdev exec pods
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-bigdev get nodes/proxy
```

**配置：**

```yaml
# ① 权限本体：自定义 ClusterRole
kind: ClusterRole
metadata:
  name: headlamp-bigdev
rules:                              # 节选
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets", "namespaces", "events"]
    verbs: ["get", "list", "watch"]            # 集群级只读
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  # 明确不含：pods/exec、RBAC 写、nodes/proxy、impersonate、Secret 写
```

```yaml
# ② 连接：ClusterRoleBinding
kind: ClusterRoleBinding
metadata:
  name: headlamp-bigdev-limited
roleRef:
  kind: ClusterRole
  name: headlamp-bigdev
subjects:
  - kind: ServiceAccount
    name: headlamp-bigdev
    namespace: headlamp
```

**作用：**

- 自定义的集群级角色：全集群只读 + 对 pods/services/configmaps/deployments
  的增删改，同时**明确排除** exec、RBAC 写、`nodes/proxy`、impersonate、Secret 写；
- 挂给 `headlamp/headlamp-bigdev`，用于受限开发者登录；
- 展示 **自定义 ClusterRole + ClusterRoleBinding + SA** 如何做到细粒度授权：
  权限写在角色规则里，通过绑定连到 Subject。

### 闭环总结

| 例子 | 权限本体 | 连接 | Subject | 效果范围 |
|---|---|---|---|---|
| 1 | `ClusterRole/cluster-admin` | ClusterRoleBinding | `SA headlamp-root` | 全集群全权限 |
| 2 | `ClusterRole/edit` | ClusterRoleBinding | `SA cicd/pipeline` | 全集群编辑 |
| 3 | `Role/pg16-ceph` | RoleBinding | `SA pg16-ceph` | 仅 cnpg-system |
| 4 | `ClusterRole/strimzi-...-namespaced` | RoleBinding | `SA strimzi-cluster-operator` | 仅 kafka |
| 5 | 无 | 无 | `SA oauth2-proxy/default` | 仅基线权限 |
| 6 | `ClusterRole/headlamp-bigdev` | ClusterRoleBinding | `SA headlamp-bigdev` | 全集群受限 |

**一条完整链路**：

```text
① Role / ClusterRole（权限本体，定义规则）
        ↓ roleRef 被引用
② RoleBinding / ClusterRoleBinding（连接，决定挂给谁、范围多大）
        ↓ subjects 引用
③ Subject（SA / User / Group，谁拿到权限）
        ↓ 实际使用
④ Pod 用 SA 的 token 访问 apiserver → 按规则放行/拒绝
```

**记住**：**Role/ClusterRole 是“能做什么”，Binding 是“连到谁”，Subject 是“谁”。**
三者缺一不可；最终权限范围由“权限本体的类型”和“绑定的类型”共同决定。

## 五、按命名空间逐个讲解

> 表格列：**SA / 作用 / 绑定 / 使用方 / 权限说明**。

### argocd（8 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `argocd-application-controller` | ArgoCD 应用同步控制器 | Role + ClusterRole 同名 | StatefulSet |
| `argocd-applicationset-controller` | ApplicationSet 集合管理 | Role | Deployment |
| `argocd-dex-server` | ArgoCD 内置 OIDC（Dex） | Role | Deployment |
| `argocd-notifications-controller` | 通知控制器 | Role + ClusterRole | Deployment |
| `argocd-redis-secret-init` | **一次性**：初始化 Redis Secret | Role `argocd-redis-secret-init` | **无** |
| `argocd-repo-server` | 仓库访问服务 | Role | Deployment |
| `argocd-server` | ArgoCD API/UI 服务 | Role + ClusterRole | Deployment |
| `default` | 默认身份 | 无 | `argocd-redis` Deployment |

**权限说明**：ArgoCD 组件权限是上游 Helm chart 定义的，每个组件角色只覆盖
自己需要的资源（应用控制器管 Application/Project，repo-server 管仓库与
Secret）。`default` 被 Redis 使用，只享受 `system:authenticated` 基线权限。

> `argocd-redis-secret-init` 是初始化 Job 的一次性 SA，Job 已不存在，
> 属于可清理项（见第八节）。

### ceph-csi-operator-system（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `ceph-csi-operator` | Ceph CSI Operator | leader-election Role + manager ClusterRole + metrics ClusterRole | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：`ceph-csi-operator-manager-role` 是 Ceph CSI Operator 管理
CSI 资源所需；metrics 角色用于暴露指标。`default` 无使用方。

### ceph-csi-rbd（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `rbd-csi-ceph-com-ctrlplugin-sa` | RBD 控制端插件 | Role + ClusterRole | Deployment |
| `rbd-csi-ceph-com-nodeplugin-sa` | RBD 节点端插件（每节点一个） | Role + ClusterRole | DaemonSet（3 Pod） |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：控制端插件需要集群级 PV/PVC/Secret 读写权限来创建/绑定卷；
节点端插件权限被收窄到节点侧资源。这是 CSI 驱动的标准模型。

### cert-manager（4 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `cert-manager` | 证书签发控制器 | 9 个 ClusterRole + tokenrequest Role | Deployment |
| `cert-manager-cainjector` | 把 CA 注入到被签发对象 | ClusterRole | Deployment |
| `cert-manager-webhook` | 准入 Webhook | Role + ClusterRole | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：cert-manager 是集群级组件，需要跨命名空间管理 Issuer、
Certificate、CSR、Order、Challenge 等，所以绑定了多个集群级角色，这是
官方 chart 的默认最小权限组合。

### china-study-free（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `china-study-free` | 业务应用身份 | 无自定义绑定 | Deployment（1 Pod） |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：应用没有自定义 RBAC，仅依赖 `system:authenticated` 基线，
不授予任何额外资源权限——属于“能跑但无业务权限”的状态。若该应用需要
访问集群资源，需要补绑定。

Deployment 的 Pod 模板显式写了 `automountServiceAccountToken: false`，
所以 Pod 里没有 SA token。拉私有镜像用的是 `imagePullSecrets: harbor-auth`
（Secret），与 SA token 无关。

### cicd（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `pipeline` | **CI 流水线执行身份**，供 Tekton EventListener 触发流水线 | **ClusterRoleBinding → `ClusterRole/edit`（集群级）** | 3 个 Deployment、3 个 EventListener、约 40 个 Pod（随流水线运行变化） |
| `default` | open-webui runner 身份 | Role `openwebui-runner-role` | 1 Pod |
| `cicd-cleanup` | **一次性**：清理流水线运行记录 | Role `cicd-cleanup` | **无** |

**权限说明**：

- `pipeline` 绑定 `ClusterRole/edit`，是本审计中**权限最大的业务 SA**：
  可以集群级 `create/delete pods`、`delete deployments`、**`create/delete secrets`**、
  `create serviceaccounts`；但它**不是“有边界”的**——`edit` 含
  `impersonate serviceaccounts`、`create serviceaccounts/token`、
  `pods/exec` 写权限，还能建 Pod 并指定任意 `serviceAccountName`。
  实测可借此拿到 `headlamp-root`（cluster-admin），见第六节第 5 小节。
- 历史上给集群级 `edit` 的理由是“跨命名空间”；但实测 PipelineRun/TaskRun
  **全部在 `cicd`**，没有跨命名空间写入的证据。建议降为 `cicd` 的
  `RoleBinding`，切断对 `headlamp` 命名空间的访问。
- `default` 的 `openwebui-runner-role` 允许对 `pipelineruns` 做
  `create/get/list/watch/patch/delete`，并可读同命名空间的 PVC/Secret/
  ConfigMap/SA——给 open-webui 的运行器创建和结束流水线用。
- `cicd-cleanup` 是清理 Job 的一次性 SA，Job 已不存在，可清理。

### cilium-secrets（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 默认身份 | 无 | **无（整个命名空间为空）** |

**权限说明**：该命名空间除自动创建的 `default` SA 外没有任何资源、没有
Pod。属于疑似遗留的空命名空间，见第八节。

### cnpg-system（4 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `cnpg-manager` | CloudNativePG Operator | ClusterRole `cnpg-manager` | Deployment |
| `pg16-ceph` | **Keycloak 用的 PostgreSQL 集群身份** | Role `pg16-ceph` + Role `pg16-ceph-barman-cloud` | 2 Pod |
| `plugin-barman-cloud` | Barman Cloud 备份插件 | leader-election Role + metrics ClusterRole + plugin ClusterRole | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：

- `cnpg-manager` 是 Operator 的集群级管理权限。
- `pg16-ceph` 绑定的是 CNPG 生成的**最小化角色**：只对
  `pg16-ceph` 这个 Cluster 资源、其关联的 Secret/ConfigMap/Lease、以及
  备份/数据库对象做限定操作，避免使用通配符。这是 CNPG 官方推荐的做法，
  权限边界清晰。

### compassio（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `frpc` | frp 内网穿透客户端 | 无自定义绑定 | Deployment（1 Pod） |
| `default` | 默认身份 | 无 | 3 Pod |

**权限说明**：frp 客户端只做网络穿透，不需要集群资源权限，未给绑定是对的。

### deeptutor（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 默认身份 | 无 | 2 Pod |

**权限说明**：业务 Pod 直接用 `default`，只有基线权限，无自定义授权。

### default（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 集群默认命名空间的默认身份 | 无 | 2 Pod |

**权限说明**：仅基线权限。`default` 命名空间内跑着 2 个 Pod，建议后续
给业务应用建独立 SA，避免共用默认身份。

### etcd-backup（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 默认身份 | 无 | 4 Pod（etcd 快照 Job） |

**权限说明**：etcd 快照 Job 未指定 SA，使用 `default`，仅基线权限。
快照内容本身在 PVC/Secret 里，靠 RBAC 之外的机制保护。建议给快照 Job
建专用 SA 并只授予所需权限。

CronJob 的 Pod 模板显式写了 `automountServiceAccountToken: false`：它用
`hostNetwork: true` 直连 `127.0.0.1:2379`，靠挂载的 etcd 客户端证书认证，
不需要 K8s API。该 Job 同时是 `runAsUser: 0` 且挂宿主机证书，关闭 token
可避免“宿主风险 + 集群凭证”叠加。

### gitlab-runner（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `gitlab-runner` | GitLab Runner 执行器身份 | Role `gitlab-runner-manager`（**命名空间内通配 `*`**） | Deployment（1 Pod） |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：`gitlab-runner-manager` 对命名空间内的
`pods、pods/log、pods/exec、pods/attach、secrets、configmaps、
serviceaccounts、events、persistentvolumeclaims、jobs` 给了 `*` 通配。
这是 GitLab Runner Kubernetes 执行器的**官方默认模型**：执行器要创建/
删除任务 Pod、读 Secret、起 Job，所以权限集中且宽。风险是**命名空间内
等同管理员**，若 Runner 被滥用，可以读走该命名空间所有 Secret、exec 进
所有 Pod。这是设计使然，但需要靠命名空间隔离和 Runner 令牌保护。

### grafana-operator（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `grafana-operator` | Grafana Operator | leader-election Role + ClusterRole | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：Operator 需要集群级管理 Grafana CR，ClusterRole 由上游 chart
定义。

### headlamp（4 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `headlamp` | Headlamp Pod 自身身份 | **无绑定** | Deployment（1 Pod） |
| `headlamp-root` | **管理员访问身份**（token 登录用） | ClusterRoleBinding → `cluster-admin` | **无 Pod（token 专用）** |
| `headlamp-bigdev` | **受限开发者访问身份** | ClusterRoleBinding → `ClusterRole/headlamp-bigdev` | **无 Pod（token 专用）** |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：这是本次审计中**唯一的用户类 SA**。

- `headlamp` 在去掉 `-unsafe-use-service-account-token` 后不再参与
  apiserver 请求，因此**故意不给任何绑定**，只保留 `system:authenticated`
  基线权限。
- `headlamp-root` 是管理员，绑定 `cluster-admin`。
- `headlamp-bigdev` 绑定自定义 `ClusterRole/headlamp-bigdev`：集群级只读
  + 工作负载读写，明确排除 `exec`、RBAC 写、`nodes/proxy`、`impersonate`、
  Secret 写。

**使用主体说明**：

- `headlamp` 的使用主体是 **Headlamp Pod**——Deployment 的 Pod 模板里
  `serviceAccountName: headlamp`，Pod 自动挂载它的 token。
- `headlamp-root` / `headlamp-bigdev` **没有任何 Pod 使用**（全集群无 Pod
  把 `serviceAccountName` 指向它们），只能由**人粘贴 token** 使用。
- 注意：Headlamp 去掉 `-unsafe-use-service-account-token` 后**不使用** Pod
  挂载的 SA token，只认粘贴的 token。因此即使把 `serviceAccountName` 改成
  `headlamp-root`，也不会让登录用户自动获得全权（详见
  [17 号文档第四节](../13-sso-oidc/notes/17-headlamp-token-login-per-user-rbac.md#四常见误解改-serviceaccountname-为-headlamp-root-能免-token-吗)）。

详见 [13-sso-oidc 的 17 号文档](../13-sso-oidc/notes/17-headlamp-token-login-per-user-rbac.md)。

### kafka（4 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `strimzi-cluster-operator` | Strimzi Kafka Operator | 多个 Role + ClusterRole（含 broker/client 委托） | Deployment |
| `my-cluster-entity-operator` | 业务 Kafka 集群的 Topic/User Operator | Role `my-cluster-entity-operator`（×2 个绑定） | Deployment |
| `my-cluster-kafka` | Kafka 集群访问身份 | Role `my-cluster-kafka`（限定 3 个 Secret） | 1 Pod |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：Strimzi 是官方 Operator，权限按组件拆分。`my-cluster-entity-operator`
对 `kafkatopics/kafkausers` 做全量管理并可写 Secret（Topic/User 的凭证），
属于该业务集群运营所需。`my-cluster-kafka` 只被允许 `get` 指定的 3 个
证书/信任包 Secret，是**非常紧的最小权限**。

### keycloak（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | Keycloak Pod 身份 | 无 | 1 Pod |

**权限说明**：Keycloak 走 NodePort + PostgreSQL（CNPG），自身不需要集群
资源权限，未给绑定是正确的。它连接数据库用的凭据在 Secret 里，不靠 SA。

### kube-node-lease（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 系统命名空间默认身份 | 无 | 无 |

**权限说明**：K8s 系统命名空间，无自定义授权，正常。

### kube-public（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 系统命名空间默认身份 | 无 | 无 |

**权限说明**：同上，系统命名空间。

### kube-system（48 个）

kube-system 是集群核心，48 个 SA 分为四类：

| 类型 | SA | 绑定 | 说明 |
|---|---|---|---|
| **系统控制器** | `attachdetach-controller`、`certificate-controller`、`clusterrole-aggregation-controller`、`cronjob-controller`、`daemon-set-controller`、`deployment-controller`、`disruption-controller`、`endpoint-controller`、`endpointslice-controller`、`endpointslicemirroring-controller`、`ephemeral-volume-controller`、`expand-controller`、`generic-garbage-collector`、`job-controller`、`namespace-controller`、`node-controller`、`persistent-volume-binder`、`pod-garbage-collector`、`pv-protection-controller`、`pvc-protection-controller`、`replicaset-controller`、`replication-controller`、`resource-claim-controller`、`resourcequota-controller`、`root-ca-cert-publisher`、`service-account-controller`、`service-cidrs-controller`、`service-controller`、`statefulset-controller`、`ttl-after-finished-controller`、`ttl-controller`、`validatingadmissionpolicy-status-controller`、`volumeattributesclass-protection-controller` | 各自同名 `ClusterRole/system:controller:*` | kubeadm 控制器，权限**严格按控制器职责**，最小化 |
| **核心组件** | `coredns`、`metrics-server` | `system:coredns`、`system:metrics-server` + `auth-delegator` | DNS、指标 |
| **Cilium / 可观测** | `cilium`、`cilium-operator`、`hubble-relay`、`hubble-ui` | `ClusterRole/cilium`、`cilium-operator`、`hubble-ui` 等 | Cilium 数据面与 Hubble |
| **第三方 Operator** | `sealed-secrets-controller`、`vpa-vertical-pod-autoscaler-*`（3 个）、`horizontal-pod-autoscaler` | 各自 Role/ClusterRole | Sealed Secrets、VPA |
| **默认** | `default` | 无 | 3 个 Pod（kube-vip DaemonSet） |

**权限说明**：

- `system:controller:*` 是 Kubernetes 内置角色，**每个控制器只拿到管理
  自己那类资源所需的动作**，这是“为什么这些 SA 权限看着小但很准”的原因。
- `horizontal-pod-autoscaler` 额外绑了 `prometheus-adapter-external-metrics`，
  用于 HPA 读取外部指标。
- `sealed-secrets-controller` 绑 `sealed-secrets-key-admin`（可
  `create/list secrets`）与 `secrets-unsealer`，用于生成/读取 Sealed
  Secret 密钥，是该组件的标准最小权限。
- `hubble-ui` 只读组件状态/节点/Pod/Service，用于 UI 展示。

### logging（5 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `loki` | Loki 日志组件 | ClusterRole `loki-clusterrole`（读 ConfigMap/Secret） | 6 Pod（gateway/read） |
| `alloy` | Grafana Alloy 采集器 | ClusterRole `alloy`（13 条规则） | DaemonSet（6 Pod） |
| `tempo3` | Tempo 链路追踪 | 无自定义绑定 | 13 Pod |
| `loki-canary` | Loki 存活探针 | 无自定义绑定 | DaemonSet（3 Pod） |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：`loki-clusterrole` 只允许读 ConfigMap/Secret（收集配置），
没有写权限。`alloy` 的规则偏大（含 `nodes/pods`、`nodes/metrics` 等），
因为它是集群级采集器，需要遍历节点与工作负载——但都是**只读**，符合
采集器定位。`tempo3`/`loki-canary` 无自定义绑定，靠基线权限运行。

`tempo3` 的 SA 上写了 `automountServiceAccountToken: false`，因此它下面
**13 个 Pod 虽然 Pod 字段没写，实际都不挂载 token**——这是“SA 级继承”
的典型例子，只统计 Pod 字段会漏掉。Tempo 的后端是 S3，不需要 K8s API。

### metallb-system（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `controller` | MetalLB 控制器 | Role `controller` + ClusterRole `metallb-system:controller` | Deployment |
| `speaker` | MetalLB 节点通告 | Role `pod-lister` + ClusterRole `metallb-system:speaker` | DaemonSet |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：控制器需要读写 Service/Secret 来分配 LoadBalancer；speaker
只需要 list Pod 和读相关资源来通告地址。标准最小权限。

### monitoring（8 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `prometheus-operator` | Prometheus Operator | ClusterRole `prometheus-operator` | Deployment |
| `prometheus-prometheus` | Prometheus 实例 | ClusterRole `prometheus-prometheus` | StatefulSet |
| `prometheus-alertmanager` | Alertmanager | 无自定义绑定 | StatefulSet |
| `prometheus-grafana` | Grafana | Role + ClusterRole | Deployment |
| `prometheus-kube-state-metrics` | kube-state-metrics | ClusterRole | Deployment |
| `prometheus-adapter` | 指标适配器 | resource-reader + auth-delegator | Deployment |
| `prometheus-prometheus-node-exporter` | 节点指标导出 | 无自定义绑定 | DaemonSet（6 Pod） |
| `default` | 默认身份 | 无 | 2 Pod |

**权限说明**：prometheus-operator 系列按上游 Operator 的标准角色授权，
主要是对 ServiceMonitor/PodMonitor/PrometheusRule 的读写。
`prometheus-grafana` 的 `ClusterRole/prometheus-grafana-clusterrole` 当前
规则数为 0（空角色），说明只靠 Role + 基线，权限很窄。

`prometheus-prometheus-node-exporter` 的 SA 和 Pod 模板都显式写了
`automountServiceAccountToken: false`（6 个 DaemonSet Pod 全部不挂载）；
`default` 下的 2 个 Pod 是 `wecom-adapter`，也在 Deployment 里显式关闭。
两者都只读宿主指标或只转发 webhook，不需要 apiserver。

### n8n（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | n8n 工作流 Pod 身份 | 无 | 1 Pod |

**权限说明**：仅基线权限，n8n 主要对外调用，不访问集群资源。

### nfs-provisioner（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `nfs-provisioner` | NFS 动态供应器 | ClusterRole `nfs-provisioner` | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：需要 `create/delete PV`、`update PVC`、读写 Endpoints/
ConfigMap 来动态供应 NFS 卷，是 PV 供应器的标准权限。

### oauth2-proxy（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 5 个 oauth2-proxy 实例的公共身份 | 无 | 5 Pod |

**权限说明**：oauth2-proxy 是反向代理，不直接访问集群资源，仅基线权限，
符合预期。

### open-webui（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `open-webui` | open-webui 应用身份 | 无自定义绑定 | Deployment（**副本 0**） |
| `frpc` | frp 内网穿透客户端 | 无自定义绑定 | Deployment（**副本 0**） |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：两个工作负载都**缩容到 0**，目前没有运行 Pod，SA 处于闲置
状态。若确认 open-webui 已下线，可连同命名空间清理（见第八节）。

### opentelemetry（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `opentelemetry-operator` | OTel Operator | leader-election Role + manager/proxy ClusterRole | Deployment |
| `otel-collector` | OpenTelemetry Collector | 无自定义绑定 | 12 个工作负载、1 Pod |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：Operator 按上游角色授权；Collector 无自定义绑定，靠基线权限
采集，符合只读采集定位。

### tekton-operator（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `tekton-operator` | Tekton Operator | ClusterRole `tekton-operator`、`tekton-pac-controller-role`、`tekton-scheduler-role` | 2 Pod |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：Tekton Operator 需要集群级管理 Tekton CR 与调度，权限偏大，
是 Operator 的职责所需。

### tekton-pipelines（11 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `tekton-pipelines-controller` | 流水线控制器 | Role + 3 个 ClusterRole | Deployment |
| `tekton-pipelines-webhook` | 准入 Webhook | Role + ClusterRole | Deployment |
| `tekton-pipelines-resolvers` | 镜像/资源解析器 | Role + ClusterRole | Deployment |
| `tekton-events-controller` | 事件控制器 | Role + ClusterRole | Deployment |
| `tekton-pruner-controller` | 运行记录清理 | Role + ClusterRole | 2 Pod |
| `tekton-triggers-controller` | Trigger 控制器 | ClusterRole `tekton-triggers-admin` | Deployment |
| `tekton-triggers-core-interceptors` | 核心拦截器 | Role + 2 ClusterRole（含 Secrets） | Deployment |
| `tekton-triggers-webhook` | Trigger Webhook | Role + ClusterRole | Deployment |
| `tekton-operators-proxy-webhook` | Operator 代理 Webhook | Role（Secret 全量）+ ClusterRole（pods/deployments/webhooks） | Deployment |
| `tekton-dashboard` | Tekton Dashboard 后端 | 4 个只读 ClusterRole | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：

- Tekton 组件权限来自官方 chart，控制器/Webhook 权限较大是**运行需要**。
- **`tekton-operators-proxy-webhook` 是敏感点**：命名空间内对 Secret 有
  `get/list/create/update/delete/patch/watch`，集群级对 pods、deployments、
  admission webhook、leases 有全量权限。属于高权限 SA，需确保其 Pod 不被
  越权访问。
- `tekton-dashboard` 只绑只读角色，用于展示。

### traefik（2 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `traefik` | Traefik 反向代理 | ClusterRole `traefik-traefik` | Deployment |
| `default` | 默认身份 | 无 | 无 |

**权限说明**：Traefik 需要读 Ingress/Service/Endpoints 等做路由，是官方
标准权限。

---

## 六、敏感权限重点汇总

### 1. 绑定到 `cluster-admin` 的主体（3 个活跃 + 1 个已删除）

| 绑定 | 主体 | 状态 |
|---|---|---|
| `cluster-admin` | `Group system:masters` | 内置，无实际成员（仅证书 CN 匹配） |
| `kubeadm:cluster-admins` | `Group kubeadm:cluster-admins` | kubeadm 引导组，靠客户端证书 |
| `headlamp-root-cluster-admin` | `SA headlamp/headlamp-root` | **活跃**，管理员登录用 |
| ~~`admin-user`~~ | `SA admin-user@kubernetes-dashboard` | ~~**死绑定**~~ **已于 2026-11-26 删除** |

**`admin-user` 已于 2026-11-26 清理**：它原本指向的 `kubernetes-dashboard`
命名空间和 SA 都不存在，绑定一旦存在，重建同名命名空间/SA 就会立刻获得
集群管理员权限。现已删除，当前 cluster-admin 绑定只剩 3 个合法主体。

### 2. 集群级 Secret 写权限的 SA

| SA | 能力 | 说明 |
|---|---|---|
| `cicd/pipeline` | 集群级 `create/delete secrets` | `ClusterRole/edit` 包含 Secret 管理，权限偏大 |
| `tekton-pipelines/tekton-operators-proxy-webhook` | 命名空间内 Secret 全量 | Operator 代理 Webhook 设计使然 |
| `kafka/my-cluster-entity-operator` | 命名空间内 Secret 读写 | Topic/User 凭证管理 |
| `kube-system/sealed-secrets-controller` | `create/list secrets` | 生成 Sealed Secret 密钥，属预期 |
| `metallb-system/controller` | Secret 全量 | 分配 LoadBalancer 所需 |

### 3. 通配符权限

- `gitlab-runner/gitlab-runner-manager`：命名空间内对 pods/secrets/jobs 等
  使用 `*` 通配，等同命名空间管理员（Runner 执行器标准模型）。

### 4. 自动挂载 SA token 的 Pod：口径、清单与考量

`automountServiceAccountToken: false` 是“不给凭证”，比“给一个小权限”更
彻底。但它有两个口径，还有一个容易被忽略的覆盖关系。

#### 1) 两个口径：Pod 字段 vs 有效挂载

截至 2026-11-27 的实测：

```text
Pod 总数                         182
├─ Pod 字段显式 false             13   ← 最常见的统计口径
├─ Pod 字段显式 true              28
└─ Pod 未设置                    141   ← 继承 SA 的设置
```

把 SA 级设置也算进去后的**有效结果**：

| 口径 | 数量 | 说明 |
|---|---|---|
| 有效挂载 token | **156** | Pod `true` + 未设置且 SA 未关闭 |
| 有效不挂载 | **26** | 13 个 Pod 显式 false + 13 个继承 SA 的 false |
| 其中：Pod 显式 false | 13 | 见下表 |
| 其中：Pod 未写、继承 SA false | **13** | 全是 `logging/tempo3` |

**优先级**：Pod 字段 > SA 字段 > 默认 `true`。

- Pod 写了 → 以 Pod 为准；
- Pod 没写 → 继承 SA；
- 两者都没写 → 默认挂载。

所以只统计 Pod 字段会**漏掉**“SA 关了、Pod 没写”的 Pod（本集群就是
`tempo3` 的 13 个）；也会**误判**“SA 关了、Pod 又写 true”的 Pod
（本集群就是 `traefik`）。

#### 2) 13 个显式关闭的 Pod 清单

| # | 命名空间 | Pod / 工作负载 | SA | 配置来源 | 为什么不挂 |
|---|---|---|---|---|---|
| 1 | china-study-free | `china-study-free-*`（Deployment） | `china-study-free` | `ChinaStudyFree/deploy/k8s/base/deployment.yaml` | Web 应用，只写本地 JSONL，不调 API |
| 2-4 | etcd-backup | `etcd-snapshot-*`（CronJob 历史 Pod） | `default` | `platform-gitops-public/platform/backup/etcd/cronjob.yaml` | 用宿主机证书直连 `127.0.0.1:2379` 做快照，再传 S3 |
| 5 | kube-system | `hubble-relay-*`（Deployment） | `hubble-relay` | `platform/network/cilium/manifests.yaml` | 连本节点 Cilium agent 的 gRPC，不走 apiserver |
| 6-11 | monitoring | `prometheus-prometheus-node-exporter-*`（DaemonSet，6 节点各 1） | `prometheus-prometheus-node-exporter` | kube-prometheus-stack（SA 上即 `false`） | 只读宿主 `/proc`、`/sys`、`/`，暴露 9100 指标 |
| 12-13 | monitoring | `wecom-adapter-*`（Deployment，2 副本） | `default` | `platform/monitoring/wecom/deployment.yaml` | 收 Alertmanager webhook，转发企业微信 |

> 其中 3 个 `etcd-snapshot-*` 是**已完成的 Job Pod**（`Succeeded`）。
> 实际 Running 且不挂载的是 **10 个**：1 + 1 + 6 + 2。

#### 3) 为什么关掉：五条考量

**① 它们不需要 apiserver，凭证不该存在**

这 13 个 Pod 的职责里没有一条需要调 Kubernetes API：

- `china-study-free`：业务 Web，只落本地文件；
- `wecom-adapter`：只接 HTTP webhook、发企业微信；
- `node-exporter`：只读宿主 `/proc`、`/sys`；
- `etcd-snapshot`：直连 `127.0.0.1:2379`，用 etcd 客户端证书；
- `hubble-relay`：连 Cilium agent，不连 apiserver；
- `tempo3`：后端是 S3（`10.0.0.31:7480`），不调 API。

**既然不用，就不要把凭证放进去。** 这是最小权限最直接的落地：不是
“少给权限”，而是“根本不给凭证”。

**② 缩小攻击面：应用被攻破也拿不到集群凭证**

如果应用存在 RCE/SSRF，攻击者第一件事就是读：

```text
/var/run/secrets/kubernetes.io/serviceaccount/token
```

拿到后就能以该 SA 身份调 apiserver。关掉自动挂载后，这个路径**根本
不存在**（实测 `ls` 报 `No such file or directory`）。即使 SA 本身权限
不高，也少了一条横向移动的路。

**③ 这些组件本身“高危”，更不能带 token**

- `etcd-snapshot`：`hostNetwork: true` + `runAsUser: 0` + 挂宿主机
  `/etc/etcd` 证书；
- `node-exporter`：挂宿主机 `/proc`、`/sys`、`/`。

它们已经在宿主机层面有很强能力，再给集群 token 等于**把宿主风险和集群
风险叠加**。

**④ 避免应用“误用”API**

即使没有恶意，依赖库也可能在启动时探测 in-cluster 配置（发现 token 就
尝试连 apiserver），产生无意义请求、报错或审计噪音。没有 token，SDK
会直接走“非集群模式”，行为更可预期。

**⑤ 减少凭证轮换与审计负担**

projected token 默认 1 小时轮换，kubelet 要持续维护；审计日志里也会多出
这些身份。不用就不挂。

#### 4) 四个容易踩的坑

**① SA 级和 Pod 级是“Pod 优先”，会互相覆盖**

- `tempo3`：Pod 字段为空，但 SA `logging/tempo3` 上是 `false` →
  **13 个 Pod 有效不挂载**；
- `traefik`：SA `traefik/traefik` 上是 `false`，但 Pod 模板显式写了
  `true` → **token 照样挂载**（它要 watch Ingress，确实需要 API）。

```bash
# tempo3：Pod 没写，继承 SA 的 false
kubectl -n logging get sa tempo3 -o jsonpath='{.automountServiceAccountToken}{"\n"}'   # false
kubectl -n logging get pod tempo3-distributor-xxx -o jsonpath='{.spec.automountServiceAccountToken}{"\n"}'  # 空

# traefik：SA 关了，但 Pod 又开回来
kubectl -n traefik get sa traefik -o jsonpath='{.automountServiceAccountToken}{"\n"}'   # false
kubectl -n traefik get pod traefik-xxx -o jsonpath='{.spec.automountServiceAccountToken}{"\n"}'  # true
kubectl -n traefik exec traefik-xxx -- ls /var/run/secrets/kubernetes.io/serviceaccount/  # 有 token
```

**结论**：关不关要看组件**是否需要 API**，不能一刀切；审计时两个字段都
要看。

**② `automount: false` ≠ 完全没有凭证**

它只关掉“自动注入的默认 token”。如果 Pod 里**显式**写了 projected
volume，token 照样会挂进去：

```yaml
volumes:
  - name: kube-api-access-xxxx
    projected:
      sources:
        - serviceAccountToken:
            path: token
```

`automountServiceAccountToken` 管的是默认注入，不管显式投影。审计时要
同时看 `volumes`，不能只看这个字段。

**③ 关掉 token 不影响拉镜像**

`china-study-free` 用了 `imagePullSecrets: harbor-auth`，那是 **Secret**，
和 SA token 是两回事。关掉自动挂载不影响私有仓库拉取。

**④ 关掉 token 也不等于“访问不了 apiserver”**

Pod 仍能网络连通 apiserver，只是**没有凭证**（匿名请求会被 403）。要
彻底隔离，还得配 NetworkPolicy。凭证层和网络层是两道独立防线。

#### 5) 验证命令

```bash
# 1) Pod 字段口径
kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.automountServiceAccountToken==false) |
  "\(.metadata.namespace)/\(.metadata.name)  SA=\(.spec.serviceAccountName)"'

# 2) SA 级口径（被继承的 false）
kubectl get sa -A -o json | jq -r '
  .items[] | select(.automountServiceAccountToken==false) |
  "\(.metadata.namespace)/\(.metadata.name)"'

# 3) 实际验证 token 文件不存在
kubectl -n monitoring exec deploy/wecom-adapter -- \
  ls /var/run/secrets/kubernetes.io/serviceaccount/    # 应报 No such file

# 4) 检查是否有显式投影（automount=false 也可能有 token）
kubectl -n <ns> get pod <pod> -o json | jq '
  .spec.volumes[] | select(.projected.sources[]?.serviceAccountToken)'
```

**一句话**：这 13 个 Pod 的共同点是“不需要 apiserver”；关掉自动挂载 =
不给凭证，比“给个小权限”更彻底。但统计和审计要同时看 **Pod 字段、
SA 字段、显式投影** 三处，否则会漏判或误判。

### 5. `edit` 的隐藏提权面：token 签发与 Pod SA

**直接绑定 `ClusterRole/edit` 的实体（2026-11-28 实测）：**

| 实体 | 绑定 | 范围 | 使用方 |
|---|---|---|---|
| `SA cicd/pipeline` | `ClusterRoleBinding/pipeline-edit-binding` | 全集群 | 3 个 Deployment、3 个 EventListener、约 40 个 Pod |

没有名为 `edit` 的 `Role`，也没有绑定到 `ClusterRole/admin` 的实体。
`edit` 的权限超集（cluster-admin）另有 3 个：`Group system:masters`、
`Group kubeadm:cluster-admins`、`SA headlamp/headlamp-root`。

**为什么 `edit` 不是安全边界**（K8s 1.35 原生规则）：

| 规则 | 后果 |
|---|---|
| `impersonate serviceaccounts` | 可 `--as` 成任意 SA |
| `create serviceaccounts/token` | 可给任意 SA 签 token |
| `create pods` + 任意 `serviceAccountName` | Pod 直接拿到该 SA 的 token |
| `create pods/exec` | 可 exec 进任意 Pod（若该 Pod 挂有高权 token 则可窃取） |

在本集群，前三条都能直接指向 `headlamp-root`，因此 **`edit` 等价于
cluster-admin 的跳板**。实测：

```bash
# A. 签 token
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline          # 成功

# B. impersonate（用 pipeline 自己的 token）
#    需只含 token 的临时 kubeconfig，否则本机客户端证书会覆盖 --token
PIPE_TOKEN=$(kubectl -n cicd create token pipeline --duration=10m)
kubectl --token="$PIPE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root # yes

# C. 建一个使用 headlamp-root SA 的 Pod（server dry-run 通过）
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server
```

**不止 `edit`：其他能签 token 的实体**

| 角色 | 实体 | 备注 |
|---|---|---|
| `rbd-csi-ceph-com-ctrlplugin-cr` | `SA ceph-csi-rbd/rbd-csi-ceph-com-ctrlplugin-sa` | 实测可签 `headlamp-root` |
| `rbd-csi-ceph-com-nodeplugin-cr` | `SA ceph-csi-rbd/rbd-csi-ceph-com-nodeplugin-sa` | 实测可签 `headlamp-root` |
| `system:kube-controller-manager` | `User system:kube-controller-manager` | 系统组件，受信 |

> **坑**：`kubectl auth can-i create serviceaccounts/token` 对 CSI SA 返回
> `no`，但实际签发成功。审计时不能只信 `can-i`。

**修补建议（摘要，完整 YAML 见
[13 号文档第七节](13-rbac-identity-binding-comparison.md#七谁拥有-edit-权限如何提权怎么修)）：**

1. **把 pipeline 的 `edit` 降为 `cicd` 命名空间级 `RoleBinding`**。
   本集群 PipelineRun/TaskRun 全部在 `cicd`，这样 pipeline 碰不到
   `headlamp` 命名空间，提权链直接断掉。
2. **自定义 ClusterRole**：去掉 `serviceaccounts/token`、
   `impersonate serviceaccounts`、`pods/exec|attach|portforward|proxy` 写。
3. **准入限制 Pod 的 SA**：用 ValidatingAdmissionPolicy 禁止在 `headlamp`
   命名空间创建使用 `headlamp-root`/`headlamp-bigdev` 的 Pod。
   **只做第 1、2 步不够**：只要能建 Pod 并指定 SA，仍可提权。
4. **收敛 CSI 角色的 token 权限**：不需要就删，需要就限定到自己的 SA。

**修补后验证：**

```bash
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline          # 应 403
kubectl auth can-i impersonate serviceaccounts \
  --as=system:serviceaccount:cicd:pipeline          # 应 no
kubectl -n headlamp run x --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server                                  # 应被拒绝
```

---

## 七、为什么权限是这样（总结规律）

1. **控制器 SA 权限小而准**：`system:controller:*` 内置角色按职责划分，
   不做通配，这是 Kubernetes 的最小权限设计。
2. **Operator 权限由上游定义**：cert-manager、strimzi、cnpg、prometheus
   等都是官方 chart/Operator 自带的角色，通常按组件拆分，看似条目多，
   实际各自只覆盖所需资源。
3. **业务 SA 权限偏大**：CI/CD、Runner、Tekton 这类需要“在集群里干活”
   的 SA，往往拿到集群级 `edit` 或命名空间通配，这是功能需要，但也是
   主要风险点。
4. **访问类 SA 按需授权**：`headlamp-root`/`headlamp-bigdev` 不跑工作负载，
   只作为登录 token 的载体，权限完全由绑定决定。
5. **无自定义绑定的 SA 只有基线权限**：`system:authenticated` 给的
   discovery、basic-user 等，没有业务资源权限，属于“能认证、无授权”。

---

## 八、过期 / 可清理清单

### A. 明确可清理（无工作负载、绑定已成死引用）

| 对象 | 类型 | 清理命令 | 依据 |
|---|---|---|---|
| ~~`ClusterRoleBinding/admin-user`~~ | ClusterRoleBinding | ✅ 已执行 `kubectl delete clusterrolebinding admin-user`（2026-11-26） | 指向已删除的 `kubernetes-dashboard` 命名空间里的 `admin-user` SA，死绑定且是 cluster-admin |
| `argocd/argocd-redis-secret-init`（SA + Role + RoleBinding） | SA/Role/RoleBinding | `kubectl -n argocd delete sa argocd-redis-secret-init role argocd-redis-secret-init rolebinding argocd-redis-secret-init` | 一次性初始化 Job 的 SA，无 Job/工作负载，GitOps 仓库未引用 |
| `cicd/cicd-cleanup`（SA + Role + RoleBinding） | SA/Role/RoleBinding | `kubectl -n cicd delete sa cicd-cleanup role cicd-cleanup rolebinding cicd-cleanup` | 一次性清理 Job 的 SA，无 Job/工作负载，GitOps 仓库未引用 |

> 清理前建议再确认一次：这些一次性 Job 不会在下次部署时被重建。
> `argocd-redis-secret-init` 若由 ArgoCD 自身安装流程触发，重新部署时
> 会重新创建，届时再保留即可。

### B. 待确认后清理

| 对象 | 现状 | 建议 |
|---|---|---|
| `cilium-secrets` 命名空间及 `cilium-secrets/default` SA | 命名空间内无任何资源、无 Pod | 确认 Cilium 已不需要该命名空间后，整命名空间删除 |
| `open-webui` 的 `open-webui`、`frpc`、`default` SA | 两个 Deployment 副本均为 0，无运行 Pod | 确认 open-webui 已下线后，整命名空间或对应工作负载+SA 删除 |

### C. 不建议清理

| 对象 | 原因 |
|---|---|
| 各命名空间的 20 个 `default` SA | K8s 自动创建，是命名空间默认身份，很多工具/控制器依赖；删除可能影响工作负载 |
| `kube-system/system:controller:*` 全部系统控制器 SA | 集群核心控制器身份，删除会导致控制器无法运行 |
| 有运行工作负载的 Operator/业务 SA | 正在被使用，删除会破坏组件 |
| `headlamp-root`、`headlamp-bigdev` | **故意不绑定工作负载**，是访问类 token 身份，属于设计，不是过期 |

### D. 清理后的验证

```bash
# 确认死绑定已删除
kubectl get clusterrolebinding admin-user   # NotFound

# 确认一次性 SA 已删除
kubectl -n argocd get sa argocd-redis-secret-init     # NotFound
kubectl -n cicd get sa cicd-cleanup                   # NotFound

# 复查是否还有无工作负载的 SA（不含 default）
kubectl get sa -A -o json | \
  python3 -c "import sys,json;[print(s['metadata']['namespace']+'/'+s['metadata']['name']) for s in json.load(sys.stdin)['items'] if s['metadata']['name']!='default']"
```

---

## 九、审计发现与建议

| # | 发现 | 风险 | 建议 |
|---|---|---|---|
| 1 | ~~`admin-user` 死绑定到 cluster-admin~~ **已处理** | 低（SA 不存在），但若重建同名 SA 立即提权 | ✅ 已于 2026-11-26 删除 |
| 2 | `cicd/pipeline` 拥有集群级 `edit`；`edit` 含 `impersonate serviceaccounts`、`create serviceaccounts/token`、`pods/exec` 写权限 | **极高**：实测可签 `headlamp-root` token、impersonate 它、或建 `headlamp-root` SA 的 Pod → cluster-admin | 优先降为 `cicd` 命名空间级 `RoleBinding`；再用自定义 ClusterRole 去掉提权规则；配合准入限制 Pod SA |
| 3 | `gitlab-runner-manager` 命名空间内 `*` | 中 | 确认 Runner 命名空间隔离充分，Runner 令牌保护到位 |
| 4 | 156/182 Pod 有效自动挂载 SA token（26 个有效不挂载） | 中 | 对不访问 API 的 Pod 显式 `automountServiceAccountToken: false`；注意 SA 级继承与显式投影 |
| 5 | 多个 SA 具备集群级 Secret 读/写 | 中 | 按“最小必要”收敛；`headlamp-bigdev` 若不需要可去掉 Secret 读 |
| 6 | 无遗留长期 token Secret | ✅ 良好 | 继续保持 bound token 机制，不要改回长期 Secret |
| 7 | 大量业务 Pod 使用 `default` SA | 低 | 逐步为业务应用创建专用 SA，便于审计与授权 |
| 8 | 存在空命名空间 `cilium-secrets`、缩容的 `open-webui` | 低 | 确认后清理，减少无用身份面 |
| 9 | CSI 两个 SA 的 ClusterRole 含 `serviceaccounts/token` create，实测可签 `headlamp-root` token | **高** | 确认 CSI 是否需要；不需要就删规则，需要就限定到自己的 SA |
| 10 | 任何能在 `headlamp` 命名空间建 Pod 的实体，都可指定 `serviceAccountName: headlamp-root` 提权；`headlamp-bigdev` 实测 dry-run 通过 | **高** | 用 ValidatingAdmissionPolicy 禁止 Pod 使用 access-only SA；并收回不必要的 `create pods` |
| 11 | `kubectl auth can-i create serviceaccounts/token` 对 CSI SA 返回假阴性 | 低（审计方法） | 以实际签发或 `auth can-i --list` 为准，不要只信 `can-i` |

---

## 十、复现命令

```bash
# 1. 总数与分布
kubectl get sa -A

# 2. 找出所有指向 SA 的绑定
kubectl get rolebinding -A -o json | jq -r '.items[].subjects[]? | select(.kind=="ServiceAccount") | [.namespace,.name] | @tsv'
kubectl get clusterrolebinding -o json | jq -r '.items[].subjects[]? | select(.kind=="ServiceAccount") | [.namespace,.name] | @tsv'

# 3. 看某个 SA 的权限
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>

# 4. 看某个 SA 被哪些工作负载使用
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.serviceAccountName=="<sa>") | .metadata.namespace+"/"+.metadata.name'

# 5. 找遗留长期 token Secret（应为空）
kubectl get secrets -A -o json | jq -r '.items[] | select(.type=="kubernetes.io/service-account-token") | .metadata.namespace+"/"+.metadata.name'

# 6. 找死绑定（引用不存在的 SA）
kubectl get clusterrolebinding -o json | jq -r '.items[] | .metadata.name as $b | .subjects[]? | select(.kind=="ServiceAccount") | select((.namespace+"/"+.name) as $k | (kubectl get sa -n .namespace .name -o name 2>/dev/null | head -1) | not) | $b+" -> "+.namespace+"/"+.name'

# 7. 找无工作负载的非默认 SA
kubectl get sa -A -o json | jq -r '.items[] | select(.metadata.name!="default") | .metadata.namespace+"/"+.metadata.name'

# 8. 自动挂载 token 的两个口径
#    Pod 字段显式 false
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.automountServiceAccountToken==false) | .metadata.namespace+"/"+.metadata.name'
#    SA 级 false（会被没写 Pod 字段的 Pod 继承）
kubectl get sa -A -o json | jq -r '.items[] | select(.automountServiceAccountToken==false) | .metadata.namespace+"/"+.metadata.name'

# 9. 找显式投影的 SA token（automount=false 也可能有 token）
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.projected.sources[]?.serviceAccountToken) | .metadata.namespace+"/"+.metadata.name'

# 10. 实测某个 Pod 里 token 文件是否存在
kubectl -n <ns> exec <pod> -- ls /var/run/secrets/kubernetes.io/serviceaccount/

# 11. 枚举绑定到 ClusterRole/edit 的实体
kubectl get rolebinding,clusterrolebinding -A -o json | jq -r '
  .items[] | select(.roleRef.kind=="ClusterRole" and .roleRef.name=="edit") |
  "\(.kind) \(.metadata.namespace // "(cluster)")/\(.metadata.name) -> " +
  ([.subjects[]? | "\(.kind):\(.namespace // "")/\(.name)"] | join(", "))'

# 12. 正确检查 edit 的危险权限（exec 不是 RBAC 动词）
kubectl auth can-i create pods/exec --as=system:serviceaccount:cicd:pipeline
kubectl auth can-i impersonate serviceaccounts --as=system:serviceaccount:cicd:pipeline
kubectl auth can-i create serviceaccounts/token --as=system:serviceaccount:cicd:pipeline

# 13. 提权链 A：以 pipeline 身份签 headlamp-root token
kubectl -n headlamp create token headlamp-root --duration=10m \
  --as=system:serviceaccount:cicd:pipeline

# 14. 提权链 B：用 pipeline 自己的 token impersonate
#     （需只含 token 的临时 kubeconfig，避免客户端证书覆盖）
PIPE_TOKEN=$(kubectl -n cicd create token pipeline --duration=10m)
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
echo "$CA" | base64 -d > /tmp/k8s-ca.crt
KUBECONFIG=/tmp/none kubectl --server="$SRV" --certificate-authority=/tmp/k8s-ca.crt \
  --token="$PIPE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root    # yes

# 15. 提权链 C：建一个使用 headlamp-root SA 的 Pod（server dry-run）
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server

# 16. 找所有含 serviceaccounts/token create 的 ClusterRole
kubectl get clusterrole -o json | jq -r '
  .items[] | select(.rules[]? | ((.resources // []) | index("serviceaccounts/token")) and ((.verbs // []) | index("create"))) |
  .metadata.name'
```
