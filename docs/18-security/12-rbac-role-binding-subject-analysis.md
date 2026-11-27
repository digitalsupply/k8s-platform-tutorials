# 集群 RBAC 全景分析：Role / ClusterRole / Binding / Subject（2026-11-26）

> 范围：全集群 RBAC 对象全量盘点。
> 内容：**有多少** Role / ClusterRole / RoleBinding / ClusterRoleBinding；
> **除了 SA 还有哪些 User / Group**；**三者配合的组合有多少、作用是什么**；
> **搭配是否合理、权限有没有问题**，结合实际运行情况分析。
> 数据均为 `kubectl` 实测，采集时间 2026-11-26。

## 一、方法与口径

```bash
kubectl get role -A -o json                # 命名空间级权限
kubectl get clusterrole -o json            # 集群级权限
kubectl get rolebinding -A -o json         # 命名空间级绑定
kubectl get clusterrolebinding -o json     # 集群级绑定
kubectl get users / groups                 # 无 User/Group 对象（见下文说明）
```

口径说明：

- **Role / ClusterRole = 权限本体**：定义“对哪些资源做哪些动作”。
- **RoleBinding / ClusterRoleBinding = 连接**：把权限挂给 Subject。
- **Subject = 被授权者**：`ServiceAccount` / `User` / `Group` 三种。
- **组合** = 一个绑定里的 `(roleRef, subject)` 对，是三者实际配合的最小单元。
- **User / Group 不是 k8s 对象**：`kubectl get users/groups` 为空。它们是身份
  名称，出现在绑定的 `subjects` 里，由认证器（客户端证书、OIDC、SA token）解析。

---

## 二、总量概览

| 对象 | 数量 |
|---|---|
| **Role**（命名空间级权限） | **60** |
| **ClusterRole**（集群级权限） | **182** |
| **RoleBinding**（命名空间级连接） | **68** |
| **ClusterRoleBinding**（集群级连接） | **135** |
| **RBAC 对象合计** | **446** |

| 统计项 | 数量 |
|---|---|
| 绑定中的 subject 条目 | **210** |
| 去重后的 `(roleRef, subject)` 组合 | **208** |
| 去重后的 Subject 总数 | **115**（SA 102 + Group 8 + User 5） |

**组合按主体类型**：

| 主体类型 | 组合数 |
|---|---|
| ServiceAccount | 174 |
| Group | 24 |
| User | 10 |

**组合按角色 / 绑定类型**：

| 维度 | 分布 |
|---|---|
| 按角色类型 | ClusterRole 139 / Role 69 |
| 按绑定类型 | ClusterRoleBinding 135 / RoleBinding 73 |

**一句话**：**182 个 ClusterRole + 60 个 Role 定义了“能做什么”，204 个绑定
把它们连到 115 个身份上，形成 208 个实际生效的“权限 + 连接 + 主体”组合。**

---

## 三、Role / ClusterRole：权限本体

### 1. ClusterRole（182 个）分类

| 分类 | 数量 | 说明 |
|---|---|---|
| `system:*` 内置 | 67 | Kubernetes 控制器、核心组件、证书审批等标准角色 |
| `tekton:*` | 24 | Tekton Operator 系列角色 |
| `ceph:*` | 16 | Ceph CSI Operator 角色 |
| `cert-manager:*` | 13 | cert-manager 控制器角色 |
| `vpa:*` | 11 | Vertical Pod Autoscaler 角色 |
| `cnpg:*` | 7 | CloudNativePG Operator 角色 |
| `strimzi:*` | 7 | Strimzi Kafka Operator 角色 |
| `prometheus:*` | 6 | Prometheus 系列角色 |
| 内置聚合（view/edit/admin/cluster-admin） | 4 | 聚合角色 |
| `barman:*` | 4 | Barman Cloud 备份角色 |
| `argocd:*` | 3 | ArgoCD 角色 |
| `otel:*` | 3 | OpenTelemetry Operator 角色 |
| `cilium:*` | 2 | Cilium 角色 |
| `headlamp:*` | 2 | Headlamp 自定义角色（`headlamp-bigdev`、`headlamp-cluster-read`） |
| `metallb:*` | 2 | MetalLB 角色 |
| `alloy / grafana / hubble / loki / nfs / plugin / traefik` | 各 1 | 各自组件角色 |
| 其他 | 4 | 杂项 |

### 2. Role（60 个）分类

Role 几乎全是**命名空间内的辅助角色**，主要是：

- **Operator 的 leader-election 角色**：如
  `kube-system/system::leader-locking-kube-controller-manager`、
  `cert-manager:leaderelection`、`vpa-...-leader-locking`、
  `tekton-pipelines-leader-election` 等；
- **kubeadm 引导角色**：`kubeadm:bootstrap-signer-clusterinfo`、
  `kubeadm:kubeadm-certs`、`kubeadm:kubelet-config` 等；
- **系统控制器命名空间角色**：`system:controller:token-cleaner`、
  `system:controller:bootstrap-signer`、`system:controller:cloud-provider`；
- **认证委托角色**：`extension-apiserver-authentication-reader`；
- **业务/自定义角色**：`pg16-ceph`、`pg16-ceph-barman-cloud`、
  `my-cluster-entity-operator`、`my-cluster-kafka`、`cicd-cleanup`、
  `openwebui-runner-role`、`gitlab-runner-manager`、`prometheus-grafana`、
  `sealed-secrets-key-admin`、`sealed-secrets-service-proxier`、
  `tekton-*-info`、`tekton-operators-proxy-admin`、`tekton-triggers-admin-webhook` 等；
- **组件角色**：`cilium-config-agent`、`cilium-operator-ztunnel`、
  `cilium-tlsinterception-secrets`、`cilium-operator-tlsinterception-secrets`、
  `metallb-system/controller`、`metallb-system/pod-lister` 等。

### 3. 未被直接引用的角色（使用情况）

- **Role：1 个未使用** → `kube-system/kube-proxy`（规则数 1，可能是遗留或
  未启用的组件角色）。
- **ClusterRole：47 个未被任何绑定直接引用**，但需要区分：

| 情况 | 例子 | 说明 |
|---|---|---|
| **经聚合间接使用** | `admin`、`view`、`system:aggregate-to-admin/edit/view` | 被 `edit`/`admin` 的 `aggregationRule` 按标签聚合，**不是死角色** |
| **Operator 提供的可选角色** | `ceph-csi-operator-*-editor/viewer-role`、`cnpg-*-editor/viewer-role`、`cert-manager-view/edit`、`barman-plugin-*` | Operator 创建出来供用户按需绑定，**当前无人绑定** |
| **已收回的角色** | `headlamp-cluster-read` | 之前绑给 `headlamp` SA，收回绑定后角色保留但未使用 |
| **其它** | `system:heapster`、`system:kube-aggregator`、`system:node-problem-detector`、`tekton-aggregate-edit` 等 | 历史/可选/聚合类 |

> 结论：47 个未直接引用**不全是垃圾**，大部分是聚合或 Operator 预留角色，
> 但确实存在“角色定义很多、实际使用少”的卫生问题。

---

## 四、RoleBinding / ClusterRoleBinding：连接

| 类型 | 数量 | 作用范围 |
|---|---|---|
| RoleBinding | 68 | 把权限**限制在命名空间内**授予 Subject |
| ClusterRoleBinding | 135 | 把权限**授予到整个集群** |

**绑定的主要用途分类**：

1. **系统控制器绑定**：`ClusterRoleBinding/system:controller:*` → 各控制器 SA。
2. **核心组件绑定**：`system:coredns`、`system:metrics-server`、
   `system:kube-scheduler`、`system:kube-controller-manager` 等。
3. **kubeadm 引导绑定**：`kubeadm:*` → 引导组/节点组。
4. **内置角色绑定**：`cluster-admin`、`system:basic-user`、`system:discovery`、
   `system:public-info-viewer`、`system:monitoring` 等 → 内置 Group。
5. **Operator 绑定**：各 Operator 的 ClusterRole/Role → 其 SA。
6. **业务/访问绑定**：`cluster-admin`→`headlamp-root`、`edit`→`cicd/pipeline`、
   `Role/gitlab-runner-manager`→`gitlab-runner`、`Role/pg16-ceph`→`pg16-ceph` 等。
7. **信息类绑定**：`tekton-*-info`、`tekton-config-read-role`、
   `tekton-result-read-role` → `system:authenticated`。
8. **认证委托绑定**：`extension-apiserver-authentication-reader`、
   `system:auth-delegator` → 核心组件 SA/User。

**引用完整性**：**0 个坏绑定**（没有引用不存在的 Role/ClusterRole）。

---

## 五、User 与 Group（除 SA 外的身份）

### 1. User（去重 5 个，10 个组合）

| User | 绑定到 | 作用 |
|---|---|---|
| `system:anonymous` | `Role/kubeadm:bootstrap-signer-clusterinfo` | 未认证身份读取集群信息（bootstrap 阶段） |
| `system:kube-controller-manager` | `system::leader-locking-*`、`system:kube-controller-manager`、`extension-apiserver-authentication-reader` | 控制器管理器身份，leader 选举 + 认证委托 |
| `system:kube-scheduler` | `system:kube-scheduler`、`system:volume-scheduler`、`system::leader-locking-kube-scheduler`、`extension-apiserver-authentication-reader` | 调度器身份 |
| `system:kube-proxy` | `system:node-proxier` | kube-proxy 身份 |
| `kube-apiserver-kubelet-client` | `system:kubelet-api-admin` | apiserver 访问 kubelet 的客户端身份 |

**全部是 `system:*` 系统身份**，没有 OIDC 用户。

### 2. Group（去重 8 个，24 个组合）

| Group | 绑定到 | 作用 |
|---|---|---|
| `system:authenticated` | `system:basic-user`、`system:discovery`、`system:public-info-viewer`、`tekton-*-info`、`tekton-config-read-role`、`tekton-result-read-role`、`sealed-secrets-service-proxier` | **任何认证身份**的基础权限 + 信息读取 |
| `system:unauthenticated` | `system:public-info-viewer` | 未认证身份也能读公开信息 |
| `system:masters` | `cluster-admin` | 内置“管理员组”（靠证书 CN 匹配） |
| `system:monitoring` | `system:monitoring` | 监控系统读取健康/指标 |
| `system:nodes` | `kubeadm:kubelet-config`、`kubeadm:nodes-kubeadm-config`、`system:certificates.k8s.io:...:selfnodeclient` | 节点身份 |
| `system:serviceaccounts` | `system:service-account-issuer-discovery` | SA 身份发现 |
| `system:bootstrappers:kubeadm:default-node-token` | `kubeadm:*`（多个） | 节点引导 token 组 |
| `kubeadm:cluster-admins` | `cluster-admin` | kubeadm 引导的集群管理员组 |

**全部是 `system:*` / `kubeadm:*` 系统组**，没有 OIDC 组。

### 3. 关键结论

- **本集群 apiserver 未配置 OIDC**，所以 RBAC 里**没有任何** `root`、
  `bigdev`、`digitalsupply` 这类 OIDC 用户/组绑定。
- User/Group 身份**全部来自系统认证器**（客户端证书、SA token、bootstrap token），
  不存在“给人直接绑 k8s 角色”的情况。
- 要给 GitLab 用户/组做 k8s RBAC，必须先给 apiserver 配 OIDC（当前阻塞）。

---

## 六、三者配合的组合：数量与分布

**去重组合 208 个**，按主体类型：

| 主体 | 组合数 | 典型角色 |
|---|---|---|
| ServiceAccount | 174 | 控制器、Operator、业务、访问类角色 |
| Group | 24 | 内置角色（basic-user、discovery、public-info-viewer、cluster-admin 等） |
| User | 10 | 调度器、控制器管理器、kube-proxy、kubelet-client |

**按角色类型 / 绑定类型**：

| 维度 | 分布 |
|---|---|
| ClusterRole 组合 | 139 |
| Role 组合 | 69 |
| ClusterRoleBinding 组合 | 135 |
| RoleBinding 组合 | 73 |

**组合的“密度”**：绝大多数角色只被 1 个组合引用（171 个角色引用次数为 1），
少数角色被多个组合引用（如 `cluster-admin` 4 个、`extension-apiserver-authentication-reader`
4 个、`tekton-pipelines-leader-election` 3 个）。

---

## 七、典型组合的作用

### 1. 系统控制器组合：`ClusterRole/system:controller:*` + SA

```text
ClusterRole/system:controller:deployment-controller
  + ClusterRoleBinding/system:controller:deployment-controller
  + Subject: ServiceAccount kube-system/deployment-controller
```

**作用**：让 deployment-controller 这个静态 Pod 能管理 Deployment/ReplicaSet。
每个控制器一个角色，权限严格按职责划分。**合理**，是 Kubernetes 的标准设计。

### 2. 核心组件组合：`ClusterRole/system:coredns` + SA

```text
ClusterRole/system:coredns
  + ClusterRoleBinding/system:coredns
  + Subject: ServiceAccount kube-system/coredns
```

**作用**：CoreDNS 需要读写 Endpoints/Service 做服务发现。**合理**。

### 3. kubeadm 引导组合：`ClusterRole/kubeadm:*` + Group/User

```text
ClusterRole/kubeadm:get-nodes
  + ClusterRoleBinding/kubeadm:get-nodes
  + Subject: Group system:bootstrappers:kubeadm:default-node-token
```

**作用**：新节点用引导 token 加入集群时，临时获得必要的权限（读节点、申请证书）。
引导完成后这些权限不再需要。**合理**，是 kubeadm 的标准引导模型。

### 4. 内置聚合组合：`ClusterRole/cluster-admin` + Group

```text
ClusterRole/cluster-admin
  + ClusterRoleBinding/cluster-admin
  + Subject: Group system:masters

ClusterRole/cluster-admin
  + ClusterRoleBinding/kubeadm:cluster-admins
  + Subject: Group kubeadm:cluster-admins
```

**作用**：把集群管理员权限授予内置组，成员由客户端证书 CN 匹配。**合理**，
但需确保只有受控证书属于这些组。

### 5. 认证委托组合：`Role/extension-apiserver-authentication-reader` + User

```text
Role/extension-apiserver-authentication-reader
  + RoleBinding/system::extension-apiserver-authentication-reader
  + Subject: User system:kube-controller-manager
```

**作用**：让控制器管理器能读取聚合 apiserver 的认证配置。**合理**。

### 6. Operator 组合：`ClusterRole/cert-manager-controller-certificates` + SA

```text
ClusterRole/cert-manager-controller-certificates
  + ClusterRoleBinding/cert-manager-controller-certificates
  + Subject: ServiceAccount cert-manager/cert-manager
```

**作用**：cert-manager 控制器管理集群级 Certificate 资源。**合理**，
是官方 chart 的标准权限。

### 7. 业务/访问组合：`ClusterRole/edit` + SA

```text
ClusterRole/edit
  + ClusterRoleBinding/pipeline-edit-binding
  + Subject: ServiceAccount cicd/pipeline
```

**作用**：让流水线执行器能跨集群创建/删除工作负载。**功能上合理**，
但 `edit` 权限偏大（见第九节）。

### 8. 访问类组合：`ClusterRole/cluster-admin` + SA

```text
ClusterRole/cluster-admin
  + ClusterRoleBinding/headlamp-root-cluster-admin
  + Subject: ServiceAccount headlamp/headlamp-root
```

**作用**：管理员登录 Headlamp 时粘贴该 SA 的 token，获得全集群权限。**按需求合理**，
但需控制能拿到 token 的人。

### 9. 信息类组合：`ClusterRole/tekton-config-read-role` + Group

```text
ClusterRole/tekton-config-read-role
  + ClusterRoleBinding/tekton-config-read-rolebinding
  + Subject: Group system:authenticated
```

**作用**：任何认证身份都能读 Tekton Operator 的配置/结果 CR。**低风险但需知悉**：
集群里任何能认证的人（含各 SA）都能读这些 CR。

---

## 八、搭配考量与合理性评估

| 类别 | 组合数 | 合理性 | 说明 |
|---|---|---|---|
| 系统控制器 | ~35 | ✅ 合理 | 标准、最小权限、按职责拆分 |
| 核心组件（coredns/metrics-server/scheduler 等） | ~10 | ✅ 合理 | 官方标准角色 |
| kubeadm 引导 | ~10 | ✅ 合理 | 标准引导模型 |
| 内置聚合/基础角色 | ~15 | ✅ 合理 | view/edit/admin/cluster-admin、basic-user、discovery 等 |
| Operator | ~80 | ⚠️ 基本合理 | 上游 chart 定义，但部分 Operator 角色偏大 |
| 业务/访问 | ~20 | ⚠️ 需关注 | `cicd/pipeline`、`gitlab-runner` 权限偏大 |
| 信息类 | ~10 | ⚠️ 需知悉 | 绑给 `system:authenticated`，任何认证身份可读 |
| 认证委托 | ~5 | ✅ 合理 | 标准委托模型 |

**总体判断**：**骨架是合理的**——系统层、引导层、Operator 层都遵循 Kubernetes
的最小权限和标准模型，没有发现系统性的权限错配。**问题集中在业务/访问层和
信息暴露层**。

---

## 九、权限问题与风险

### 1. 明确的安全问题

| # | 问题 | 位置 | 风险 | 建议 |
|---|---|---|---|---|
| 1 | ~~`admin-user` 死绑定到 cluster-admin~~ **已处理** | 原 `ClusterRoleBinding/admin-user` → `SA admin-user@kubernetes-dashboard` | 已于 2026-11-26 删除；当前 cluster-admin 绑定仅剩 3 个合法主体 | ✅ **已删除** |
| 2 | **`cicd/pipeline` 集群级 `edit`** | `ClusterRole/edit` + `ClusterRoleBinding/pipeline-edit-binding` | 可跨集群创建/删除 pods、**Secret**、serviceaccounts | 评估改为命名空间级 Role；对流水线 Pod 加 PSA 限制 |
| 3 | **`gitlab-runner-manager` 命名空间通配** | `Role/gitlab-runner-manager` | 命名空间内 pods/secrets/jobs 全通配，等同命名空间管理员 | 确认 Runner 命名空间隔离与令牌保护 |
| 4 | **`tekton-operators-proxy-webhook` 高权限** | `Role/tekton-operators-proxy-admin` + ClusterRole | 命名空间内 Secret 全量 + 集群级 pods/deployments/webhook 全量 | 收敛或加审计 |
| 5 | **信息类角色绑给 `system:authenticated`** | `tekton-config-read-role`、`tekton-result-read-role`、`tekton-*-info` | 任何认证身份（含所有 SA）都能读 Tekton 配置/结果 | 若不需要，改为绑定到具体 SA/组 |

### 2. 卫生问题（非直接安全风险）

| # | 问题 | 说明 |
|---|---|---|
| 6 | **47 个 ClusterRole 未被直接引用** | 多为聚合角色或 Operator 预留角色，不是死角色，但反映“角色定义多、使用少” |
| 7 | **1 个 Role 未使用** | `kube-system/kube-proxy`，疑似遗留 |
| 8 | **`headlamp-cluster-read` 未使用** | 已收回绑定，角色保留，可删可留 |

### 3. 结构性限制

| # | 问题 | 说明 |
|---|---|---|
| 9 | **无 OIDC，无法做用户/组级 RBAC** | User/Group 全是 `system:*`，GitLab 用户无法直接作为 k8s RBAC 主体 |
| 10 | **156/182 Pod 有效自动挂载 SA token** | 身份面偏大，被攻破的 Pod 可直接使用其 SA 权限；26 个有效不挂载（13 个 Pod 显式 false + 13 个继承 SA false） |

### 4. 运行情况印证

- **0 个坏绑定**：所有绑定引用的角色都存在，配置完整。
- **系统层运行正常**：各控制器、核心组件的角色与绑定一一对应，无错配。
- **业务层有权限放大**：`cicd/pipeline`、`gitlab-runner` 等需要“在集群里干活”
  的 SA，权限明显大于系统层，这是业务需要的，但也是主要风险点。
- **访问层收敛有效**：`headlamp` 已改为按 SA 授权，`headlamp-root` 是唯一活跃
  的 cluster-admin 使用方 SA。

---

## 十、结论与建议

### 结论

1. **总量**：60 个 Role + 182 个 ClusterRole，68 个 RoleBinding + 135 个
   ClusterRoleBinding，共 **445 个 RBAC 对象**，形成 **208 个实际生效组合**。
2. **主体**：115 个去重身份（SA 102、Group 8、User 5）；**User/Group 全是
   系统身份，没有 OIDC 用户/组**。
3. **骨架合理**：系统、引导、Operator 层符合 Kubernetes 标准模型，配置完整
   （0 坏绑定）。
4. **问题集中**：业务/访问层权限偏大、信息类角色绑给 `system:authenticated`、
   存在 1 个死绑定。

### 建议（按优先级）

1. ✅ **已处理**：`admin-user` 死绑定已于 2026-11-26 删除。
2. **近期**：收敛 `cicd/pipeline` 的 `edit` 权限（改命名空间级、限制 Secret）；
   评估 `tekton-operators-proxy-webhook` 的高权限。
3. **中期**：清理 47 个未直接引用的 ClusterRole 中的遗留项（如
   `headlamp-cluster-read`、`kube-proxy` Role）；信息类角色从
   `system:authenticated` 改绑到具体 SA/组。
4. **长期**：给 apiserver 配 OIDC（HTTPS issuer），打通“GitLab 用户/组 →
   k8s RBAC”的用户级授权；对不访问 apiserver 的 Pod 关闭 SA token 自动挂载。

---

## 十一、复现命令

```bash
# 1. 总量
kubectl get role -A | tail -n +2 | wc -l
kubectl get clusterrole | tail -n +2 | wc -l
kubectl get rolebinding -A | tail -n +2 | wc -l
kubectl get clusterrolebinding | tail -n +2 | wc -l

# 2. 统计绑定中的 subject 类型与组合
kubectl get rolebinding -A -o json | jq -r '.items[].subjects[]? | .kind' | sort | uniq -c
kubectl get clusterrolebinding -o json | jq -r '.items[].subjects[]? | .kind' | sort | uniq -c

# 3. 列出所有非 SA 的 User / Group subject
kubectl get rolebinding -A -o json | jq -r '.items[] | .subjects[]? | select(.kind=="User" or .kind=="Group") | [.kind,.name] | @tsv'
kubectl get clusterrolebinding -o json | jq -r '.items[] | .subjects[]? | select(.kind=="User" or .kind=="Group") | [.kind,.name] | @tsv'

# 4. 找坏绑定（引用不存在的角色）
kubectl get rolebinding -A -o json | jq -r '.items[] | select((.roleRef.kind=="Role") and (.metadata.namespace+"/"+.roleRef.name) as $k | (kubectl get role -n .metadata.namespace .roleRef.name -o name 2>/dev/null | head -1) | not) | .metadata.namespace+"/"+.metadata.name+" -> Role/"+.roleRef.name'

# 5. 找未被引用的角色
kubectl get clusterrole -o json | jq -r '.items[].metadata.name' | sort > /tmp/all_cr.txt
kubectl get rolebinding -A -o json | jq -r '.items[].roleRef.name' ; kubectl get clusterrolebinding -o json | jq -r '.items[].roleRef.name' | sort -u > /tmp/used_cr.txt
comm -23 /tmp/all_cr.txt /tmp/used_cr.txt
```
