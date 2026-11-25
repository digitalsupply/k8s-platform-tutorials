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
| 集群内 Pod 总数 / 自动挂载 SA token | 168 / 155（13 个显式 `automountServiceAccountToken: false`） |
| 绑定到 `cluster-admin` 的主体 | 4 个（1 个是**死绑定**） |

**三个最重要的结论：**

1. **集群里没有任何长期 ServiceAccount token Secret**。所有 token 都是
   `kubectl create token` / 控制器动态签发的 bound token（JWT，默认 1h），
   不存在“一个 Secret 永久有效”的隐患。这一点是好的。
2. **唯一绑定 `cluster-admin` 的活跃使用方 SA 是 `headlamp-root`**，
   用于管理员登录 Headlamp；另外有一个**死绑定** `admin-user` 指向已删除
   命名空间里的 SA，应当清理。业务类 SA（如 `cicd/pipeline`、
   `gitlab-runner`）权限偏大但不是 cluster-admin。
3. **20 个“孤儿”全部是各命名空间的 `default` SA**，是 Kubernetes 自动创建
   的，不是业务遗留，一般不建议删除。真正可清理的是 3 项死绑定/一次性 SA
   （见第七节）。

---

## 三、ServiceAccount 在集群里承担的四类角色

理解权限前先明确 SA 的四种用途，后面逐个对照：

| 类型 | 说明 | 典型例子 |
|---|---|---|
| **系统控制器 SA** | Kubernetes / kubeadm 自带控制器的身份，权限“刚好够用”，绑定到 `system:controller:*` 这类内置 ClusterRole | `kube-system/deployment-controller` |
| **平台组件 / Operator SA** | 各中间件、Operator 组件的身份，权限来自 Helm/Operator 自带的 Role/ClusterRole，通常按组件最小化 | `argocd/argocd-server`、`cert-manager/cert-manager` |
| **业务工作负载 SA** | 业务应用的身份，权限取决于业务需要 | `cicd/pipeline`、`gitlab-runner/gitlab-runner` |
| **访问/用户类 SA** | 不跑工作负载，只作为“人或流程”的授权载体，靠 token 登录或调用 API | `headlamp-root`、`headlamp-bigdev` |
| **默认 SA** | K8s 在每个命名空间自动创建，未指定 SA 的 Pod 会落到它身上 | 各命名空间的 `default` |

**为什么权限长成这样**：RBAC 是“按需授予”。控制器只给它管理的资源
（如 deployment-controller 只操作 ReplicaSet/Deployment 等）；Operator 的
权限是上游 chart 定义的；业务 SA 的权限往往偏大，因为要兼容业务操作。

---

## 四、按命名空间逐个讲解

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
> 属于可清理项（见第七节）。

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

### cicd（3 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `pipeline` | **CI 流水线执行身份**，供 Tekton EventListener 触发流水线 | **ClusterRoleBinding → `ClusterRole/edit`（集群级）** | 19 个 Deployment、27 个 Pod（`el-*` 事件监听器等） |
| `default` | open-webui runner 身份 | Role `openwebui-runner-role` | 1 Pod |
| `cicd-cleanup` | **一次性**：清理流水线运行记录 | Role `cicd-cleanup` | **无** |

**权限说明**：

- `pipeline` 绑定 `ClusterRole/edit`，是本审计中**权限最大的业务 SA**：
  可以集群级 `create/delete pods`、`delete deployments`、**`create/delete secrets`**、
  `create serviceaccounts`，但**不能**改 RBAC、不能 `exec`、不能碰
  `nodes/proxy`。Tekton EventListener 需要跨命名空间创建/删除 PipelineRun，
  所以给了集群级 `edit`。
- `default` 的 `openwebui-runner-role` 允许对 `pipelineruns` 做
  `create/get/list/watch/patch/delete`，并可读同命名空间的 PVC/Secret/
  ConfigMap/SA——给 open-webui 的运行器创建和结束流水线用。
- `cicd-cleanup` 是清理 Job 的一次性 SA，Job 已不存在，可清理。

### cilium-secrets（1 个）

| SA | 作用 | 绑定 | 使用方 |
|---|---|---|---|
| `default` | 默认身份 | 无 | **无（整个命名空间为空）** |

**权限说明**：该命名空间除自动创建的 `default` SA 外没有任何资源、没有
Pod。属于疑似遗留的空命名空间，见第七节。

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
状态。若确认 open-webui 已下线，可连同命名空间清理（见第七节）。

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

## 五、敏感权限重点汇总

### 1. 绑定到 `cluster-admin` 的主体（4 个）

| 绑定 | 主体 | 状态 |
|---|---|---|
| `cluster-admin` | `Group system:masters` | 内置，无实际成员（仅证书 CN 匹配） |
| `kubeadm:cluster-admins` | `Group kubeadm:cluster-admins` | kubeadm 引导组，靠客户端证书 |
| `headlamp-root-cluster-admin` | `SA headlamp/headlamp-root` | **活跃**，管理员登录用 |
| `admin-user` | `SA admin-user@kubernetes-dashboard` | **死绑定**，命名空间已删除 |

**`admin-user` 是明确的清理对象**：它指向的 `kubernetes-dashboard`
命名空间和 SA 都不存在，但绑定还在，一旦有人重建同名命名空间/SA，会
立刻获得集群管理员权限。

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

### 4. 自动挂载 SA token 的 Pod

168 个 Pod 中 **155 个自动挂载** SA token，只有 13 个显式
`automountServiceAccountToken: false`。这意味着一旦 Pod 被攻破或
`exec` 进去，就能拿到该 SA 的 token。建议对不需要访问 API 的 Pod
（如纯代理、采集器、一次性 Job）显式关闭自动挂载。

---

## 六、为什么权限是这样（总结规律）

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

## 七、过期 / 可清理清单

### A. 明确可清理（无工作负载、绑定已成死引用）

| 对象 | 类型 | 清理命令 | 依据 |
|---|---|---|---|
| `ClusterRoleBinding/admin-user` | ClusterRoleBinding | `kubectl delete clusterrolebinding admin-user` | 指向已删除的 `kubernetes-dashboard` 命名空间里的 `admin-user` SA，死绑定且是 cluster-admin |
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

## 八、审计发现与建议

| # | 发现 | 风险 | 建议 |
|---|---|---|---|
| 1 | `admin-user` 死绑定到 cluster-admin | 低（SA 不存在），但若重建同名 SA 立即提权 | 立即删除该绑定 |
| 2 | `cicd/pipeline` 拥有集群级 `edit`，含 Secret 写 | 高 | 评估能否改为命名空间级 Role；对流水线 Pod 加 PSA 限制 |
| 3 | `gitlab-runner-manager` 命名空间内 `*` | 中 | 确认 Runner 命名空间隔离充分，Runner 令牌保护到位 |
| 4 | 155/168 Pod 自动挂载 SA token | 中 | 对不访问 API 的 Pod 显式 `automountServiceAccountToken: false` |
| 5 | 多个 SA 具备集群级 Secret 读/写 | 中 | 按“最小必要”收敛；`headlamp-bigdev` 若不需要可去掉 Secret 读 |
| 6 | 无遗留长期 token Secret | ✅ 良好 | 继续保持 bound token 机制，不要改回长期 Secret |
| 7 | 大量业务 Pod 使用 `default` SA | 低 | 逐步为业务应用创建专用 SA，便于审计与授权 |
| 8 | 存在空命名空间 `cilium-secrets`、缩容的 `open-webui` | 低 | 确认后清理，减少无用身份面 |

---

## 九、复现命令

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
```
