# 工作节点 Pod 负载均衡方案（结合本集群实测）

> 生成时间：2026-10-03
> 数据来源：本机 `m01`（control-plane，`KUBECONFIG=/etc/kubernetes/admin.conf`）实时采集
> 集群版本：k8s v1.35.9 / containerd 2.3.2 / Calico v3.32.2
> 关联文档：`/root/k8s-cluster-audit-2026-10-03.md`（已把「worker03 严重失衡」列为 🟠 中风险项，但未给方案）、`/root/infra-topology-truth.md`（K8s + Ceph 全部运行在同一台 PVE 宿主机上）

---

## 一、结论速览

**当前失衡的量化事实**（非 DS 业务 Pod）：

| 节点 | 业务 Pod 数 | requests CPU | requests 内存 | BestEffort 占比 | 实际 CPU 用量 |
|---|---|---|---|---|---|
| worker01 (6C/9.6Gi) | **50** | **4.47C / 74%** | **5.44Gi / 57%** | 30/50 = 60% | 646m (10%) |
| worker02 (6C/9.6Gi) | 36 | 1.33C / 22% | 1.79Gi / 19% | 34/36 = 94% | 598m (9%) |
| worker03 (4C/7.7Gi) | **3** | 0.89C / 22% | 2.17Gi / 28% | 1/3 | 877m (21%) |

**三条最关键的结论：**

1. **调度器不是"坏了"，而是"看不见"负载。** 全集群 142 个 Pod 中 **82 个是 BestEffort（无任何 requests）**，其中 55 个是业务 Pod。`kube-scheduler` 默认打分插件 `NodeResourcesBalancedAllocation` 只按 requests 比例打分，request=0 的 Pod 权重为 0，三台 worker 得分完全相同 → 落点由并列打破规则决定，与负载无关。
2. **现有 12 处 `topology.kubernetes.io/zone` 拓扑约束全部空转。** 实测**没有任何节点带 `topology.kubernetes.io/zone` 标签**（只有自定义的 `zone=test-a/test-b`），tempo3 / kafka-broker 的 `topologySpreadConstraints` 因找不到拓扑域而完全不生效。
3. **worker01 内存已经贴顶。** requests 内存 5.44Gi vs 实际用量 5.55Gi（**覆盖率 102%**），而 worker02 只有 45%、worker03 61%。任何内存型工作负载继续往 worker01 调度，都有触发驱逐/OOM 的直接风险。

**方案主干：** P0 补 requests + 修拓扑标签 → P1 上 descheduler + 定制 scheduler 配置 → P2 关键组件双副本化 + VPA 试点 → P3 节点角色标签规范化与容量对齐。

---

## 二、现状实测

### 2.1 节点与可调度性

| 节点 | 角色 | IP | vCPU | allocatable CPU | allocatable 内存 | 自定义标签 | 污点 | 业务 Pod |
|---|---|---|---|---|---|---|---|---|
| m01 | control-plane | 10.0.0.61 | 4 | 4 | 5.4Gi | — | `control-plane:NoSchedule` | 0 |
| master01 | control-plane | 10.0.0.121 | 4 | 4 | 5.7Gi | — | `control-plane:NoSchedule` | 0 |
| master02 | control-plane | 10.0.0.120 | 4 | 4 | 3.7Gi | — | `control-plane:NoSchedule` | 0 |
| worker01 | worker | 10.0.0.122 | 6 | 6 | 9.6Gi | `dedicated=high-mem`, `zone=test-a` | 无 | 50 |
| worker02 | worker | 10.0.0.123 | 6 | 6 | 9.6Gi | `dedicated=general`, `zone=test-b` | 无 | 36 |
| worker03 | worker | 10.0.0.124 | 4 | 4 | 7.7Gi | `dedicated=general`, `zone=test-a` | 无 | 3 |

要点：

- **真正可承载业务 Pod 的只有 3 台节点**，且**容量不等**（6C:6C:4C = 37.5% : 37.5% : 25%）。均衡目标必须按容量加权，不能按"每节点 1/3"。
- **worker 节点没有 `node-role.kubernetes.io/worker` 标签**（`kubectl get nodes -l node-role.kubernetes.io/worker` 返回空），`kubectl get nodes` 的 ROLES 列显示 `<none>`。任何依赖该标签的选择器、亲和规则、`drain` 脚本都会漏掉全部 worker。
- **没有任何节点带标准 zone 标签**（`kubectl get nodes -l topology.kubernetes.io/zone` 返回空）。`zone` 是自定义标签，K8s 拓扑逻辑不认它。
- 三台 control-plane 均被 `NoSchedule` 污点隔离，etcd/apiserver/scheduler 静态 Pod + coredns 副本在内，**不参与业务调度，本方案不动它们**。
- 无节点处于 MemoryPressure / DiskPressure / Unschedulable 状态；`pods` allocatable 均为 110，**Pod 数量没有配额压力**。

### 2.2 负载分布（requests 口径 = 调度器口径）

| 节点 | Pod 总数 | DaemonSet | 业务 Pod | req CPU | req CPU% | req 内存 | req 内存% | limit CPU | limit 内存 |
|---|---|---|---|---|---|---|---|---|---|
| worker01 | 57 | 7 | 50 | 4.47 | **74%** | 5.44Gi | **57%** | 14.90 | 20.25Gi |
| worker02 | 43 | 7 | 36 | 1.33 | 22% | 1.79Gi | 19% | 3.90 | 4.14Gi |
| worker03 | 10 | 7 | 3 | 0.89 | 22% | 2.17Gi | 28% | 2.50 | 4.50Gi |

**limits 口径的失衡更极端**：worker01 的 limit CPU 合计 14.90 核，是 allocatable 6 核的 **2.5 倍**（worker02 仅 0.65x、worker03 0.63x）。limit/request 倍数三节点分别是 3.3x / 2.9x / 2.8x——**该倍数本身还算合理，问题在于绝对量差了 6 倍**。

### 2.3 实际用量（metrics-server，`kubectl top nodes`）

| 节点 | CPU | CPU% | 内存 | 内存% | requests 内存覆盖率 |
|---|---|---|---|---|---|
| m01 | 746m | 18% | 3989Mi | 71% | — |
| master01 | 451m | 11% | 2970Mi | 51% | — |
| master02 | 768m | 19% | 2534Mi | 66% | — |
| worker01 | 646m | 10% | **5679Mi** | **57%** | **102%** ⚠️ |
| worker02 | 598m | 9% | 5139Mi | 52% | 286% |
| worker03 | 877m | 21% | 3672Mi | 46% | 165% |

> **worker01 的内存 requests 已经低于实际用量**（5.44Gi vs 5.55Gi）。这不是巧合，而是 requests 缺失导致的必然结果：worker01 上 60% 的业务 Pod 是 BestEffort，声明为 0，调度器把"看不见的内存消耗"全堆在了同一台 VM。

### 2.4 QoS 分布（根因所在）

| QoS | Pod 数 | 占比 |
|---|---|---|
| BestEffort（无 requests 无 limits） | **82** | **57.7%** |
| Burstable | 60 | 42.3% |
| Guaranteed | **0** | 0% |

剔除 DaemonSet 后，**3 台 worker 上的 89 个业务 Pod 中有 55 个是 BestEffort**（master 上另有 14 个业务 Pod：`coredns` ×2、`calico-kube-controllers`、`vpa` 组件 ×2 等）。

按 namespace 统计 BestEffort 业务 Pod（合计 55）：

| namespace | 数量 | 典型组件 |
|---|---|---|
| logging | 17 | loki-gateway、loki-read、tempo3-distributor/querier/query-frontend/metrics-generator/memcached |
| argocd | 7 | applicationset-controller、notifications-controller、redis、repo-server、dex-server |
| kube-system | 7 | calico-kube-controllers、vpa-admission-controller/recommender/updater、metallb controller |
| tekton-pipelines | 6 | pipelines-controller、triggers-controller、events-controller、dashboard |
| cert-manager | 3 | cert-manager、cainjector、webhook |
| 其他（kafka / monitoring / n8n / opentelemetry / dashboard / metallb / nfs / traefik / cicd / ceph-csi） | 15 | — |

**完全没有 `ResourceQuota` 和 `LimitRange`**（`kubectl get resourcequota -A` / `limitrange -A` 均为空）→ 没有任何机制强制补齐 requests，新装组件继续以 BestEffort 落地。

### 2.5 调度栈现状

| 组件 | 状态 | 影响 |
|---|---|---|
| `kube-scheduler` | 3 副本（m01/master01/master02），`--leader-elect=true`，**未使用 `--config`**，即 100% 默认插件集 | 只能用默认权重，无法调优 |
| 默认打分插件 | `NodeResourcesFit`(1) + `NodeResourcesBalancedAllocation`(cpu:1, memory:1) + `PodTopologySpread` | 对 0-request Pod 完全无感 |
| `descheduler` | **未安装** | 历史倾斜永不自我纠正，调度器只在 Pod 创建时决策 |
| `VPA` | admission-controller / recommender / updater 均已部署（各 2 副本，preferred 反亲和），**但 `kubectl get vpa -A` 为空，0 个 VPA 对象** | 资源画像能力空转 |
| `metrics-server` | 已部署，1 副本（在 worker01，无副本冗余） | VPA / HPA / descheduler 的前提，可用 |
| `PriorityClass` | 仅 `system-cluster-critical` / `system-node-critical` | 无业务优先级分级 |
| `HPA` | 5 个（knative ×4 + tekton-pipelines-webhook），基于 CPU 利用率 | **没有 requests 时 CPU 利用率失真，HPA 形同虚设**（实测 `activator` target cpu 0%、`webhook` 4%，而实际根本拿不到 CPU request） |
| `PodDisruptionBudget` | 13 个 | 驱逐时可用约束，配合 drain 使用 |

### 2.6 硬约束盘点（哪些东西挡着"想放哪放哪"）

| 约束 | 数量/详情 | 对均衡的影响 |
|---|---|---|
| `nodeSelector` | 仅 `kubernetes.io/os: linux`（无实际筛选力）+ `kube-vip-ds` 用 `node-role.kubernetes.io/control-plane` | **不构成障碍** |
| nodeAffinity（required） | **0 个业务工作负载使用** | 无障碍 |
| podAntiAffinity（**required**） | tempo3 的 distributor/querier/query-frontend/metrics-generator/memcached、loki-backend（均在 worker01） | 这些组件 `replicas=1`，required 反亲和实际不产生约束（单副本必然满足），但一旦扩容就会自动分摊，**是好事** |
| `topologySpreadConstraints` | 13 处，其中 **12 处用 `topology.kubernetes.io/zone`**（tempo3 6 处、kafka-broker 3 处、tempo3-backend 2 处等），1 处用 `kubernetes.io/hostname`（wecom-adapter） | **12 处全部空转**：无节点带该 zone 标签；且绝大多数 `whenUnsatisfiable: ScheduleAnyway` + `maxSkew:1`，对 `replicas=1` 的组件即使标签修好也无效 |
| PV 绑定 | 全部 StorageClass 为 `Immediate`（`ceph-rbd-sc` Ceph RBD、`nfs-sc`），**所有 PV 均无 `nodeAffinity`** | **无本地卷钉死，迁移/驱逐完全可行**（这是本方案能落地的关键前提） |
| 副本数 | **69 个 Deployment 中 60 个是单副本**；13 个 StatefulSet 中 11 个是单副本 | 单副本组件只能"移动"不能"分摊"，是均衡的硬天花板 |
| DaemonSet | 8 个（calico-node、kube-proxy、kube-vip、alloy、loki-canary、metallb speaker、node-exporter、ceph-csi-nodeplugin），每 worker 7 个 | 三节点固定开销一致，**不是失衡来源** |

### 2.7 失衡是如何形成的（时间线证据）

Pod 创建时间聚合显示，失衡不是"慢慢积累"的，而是**两次批量 apply 各自整块落到单个节点**：

```
10-03 02:30~02:38   worker01 += 45 个业务 Pod（本时段 worker02/03 各 0 个）  ← tempo3 全家桶 + knative + tekton webhook + monitoring + CNPG
10-03 03:40         worker02 += 36 个业务 Pod（一次性）                      ← argocd + cert-manager + tekton controller + kafka + loki-write + tempo3-backend + otel + dashboard
10-03 07:30         worker03 += 1  (n8n)
10-03 13:10         worker03 += 1  (prometheus)
10-03 13:40         worker03 += 1  (report-processor)
```

三台 worker 的 Ready 状态自 `10-03T00:09:57Z` 起持续未变、当前均无污点无 cordon，说明**不是"节点不可用"造成的**。全部 142 个 Pod 的 `schedulerName` 均为 `default-scheduler`，无预绑定 `nodeName`、无第三方调度器。

> **机制解释**：45 个 Pod 中绝大多数是 BestEffort → 三台 worker 在 `NodeResourcesBalancedAllocation` 上得分完全相同（并列满分）。调度器在并列时按节点遍历顺序取第一个最高分节点，于是**一次批量 apply 会成片落在同一台节点**。这就是 requests 缺失导致失衡的直接证据链。
>
> 补充说明：节点对象的 `managedFields` 为空、kubelet/scheduler 日志已滚动，因此"当时是否存在临时污点/cordon"无法 100% 证实；但无论是否存在，上述并列机制已足以解释 45/45 的成片现象，且这是唯一能同时解释"两次 apply 各自落单节点"和"worker03 只拿到零星 3 个"的假设。

---

## 三、均衡目标模型（容量加权）

### 3.1 权重

| 节点 | allocatable CPU 权重 | 内存权重 | 加权份额 |
|---|---|---|---|
| worker01 | 6 | 9.6Gi | 37.5% |
| worker02 | 6 | 9.6Gi | 37.5% |
| worker03 | 4 | 7.7Gi | **25.0%** |

> worker03 内存更小（7.7Gi），CPU 权重取 4/16 = 25%，内存权重取 7.7/26.9 = 28.6%。**CPU 是本集群的调度瓶颈口径**（内存总量尚余 65%），因此以 CPU 权重为准、内存为辅。

### 3.2 目标值与差距

当前三节点 requests 合计 CPU 6.69 核（占 16 核的 42%）、内存 9.40Gi（占 26.9Gi 的 35%），**总量并不紧张，纯粹是分布问题**。

| 节点 | req CPU 现状 | 目标（37.5/37.5/25%） | 差距 | req 内存 现状 | 内存目标 | 差距 |
|---|---|---|---|---|---|---|
| worker01 | 4.47C (74%) | ≤ 45% | **需迁出 ~1.7 核 / ~1.8Gi** | 5.44Gi (57%) | ≤ 45% | 需迁出 ~1.0Gi |
| worker02 | 1.33C (22%) | 35~45% | 可承接 ~0.9 核 | 1.79Gi (19%) | 30~40% | 可承接 ~1.8Gi |
| worker03 | 0.89C (22%) | 18~30% | 可承接 ~0.1~0.5 核 | 2.17Gi (28%) | 22~32% | 基本达标 |

业务 Pod 数目标（89 个，按权重）：**worker01 ≈ 33 / worker02 ≈ 33 / worker03 ≈ 22**（当前 50 / 36 / 3）。

**验收标准（偏差 ≤ 15 个百分点）：**

| 指标 | 现状 | 目标 |
|---|---|---|
| 各节点 req CPU% 与容量加权目标的偏差 | worker01 +36.5pp | ≤ ±15pp |
| 各节点 req 内存% 与容量加权目标的偏差 | worker01 +19.5pp | ≤ ±15pp |
| 业务 Pod 数占比 | 56% / 40% / 3% | 37.5% / 37.5% / 25% ± 10pp |
| BestEffort 业务 Pod 数 | 55 | **0** |
| worker01 内存 requests 覆盖率 | 102% | ≤ 85% |
| requests 总量 / 容量 | CPU 42% / 内存 35% | 保持 ≤ 60%（不得靠"均衡"之名放大总占用） |

---

## 四、落地方案

按"**先让调度器看得见 → 再让调度器动得动 → 最后让架构分得开**"的顺序推进。P0 不做完，后面全是空转。

### P0-1 补齐 requests（最高优先级，一切的前提）

分两层做，先兜底、再精调。

**① Namespace 级 LimitRange 兜底**：给所有业务 namespace 加默认 requests，防止新组件再次以 BestEffort 落地。

```yaml
# kubectl apply -f limitrange-default.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-requests-limits
  namespace: <ns>
spec:
  limits:
  - type: Container
    default:              # 未声明 resources 时自动注入
      cpu: 100m
      memory: 128Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "2"
      memory: 4Gi
```

需要创建的 namespace：`logging argocd tekton-pipelines cert-manager monitoring opentelemetry kafka kubernetes-dashboard n8n metallb-system ceph-csi-rbd nfs-provisioner cicd traefik cnpg-system knative-serving knative-eventing knative-operator default`。

> ⚠️ **只对新建/重建 Pod 生效**，存量 Pod 不受影响，需配合下一条。
>
> ⚠️ `logging` / `knative-*` 等 namespace 被 LimitRange 覆盖后，Pod QoS 会从 BestEffort 变为 Burstable，**这会让重调度量放大**，必须先做完 P1-1 的 descheduler 部署再统一 rollout，否则会出现一波手工搬迁。

**② 关键组件精调 requests**（按实测用量 × 2~3 倍余量，而非拍脑袋）：

| 组件 | 当前 | 建议 requests | 建议 limits | 依据 |
|---|---|---|---|---|
| `logging/tempo3-distributor` | 无 | cpu 300m / mem 512Mi | cpu 1 / mem 1Gi | trace 入口，QPS 敏感 |
| `logging/tempo3-querier` | 无 | cpu 500m / mem 1Gi | cpu 2 / mem 4Gi | 重查询，内存密集 |
| `logging/tempo3-query-frontend` | 无 | cpu 200m / mem 256Mi | cpu 1 / mem 1Gi | 并发入口 |
| `logging/tempo3-metrics-generator` | 无 | cpu 300m / mem 512Mi | cpu 1 / mem 2Gi | 指标聚合 |
| `logging/loki-gateway` / `loki-read` | 无 | cpu 200m / mem 256Mi | cpu 1 / mem 1Gi | 查询链路 |
| `argocd/*`（5 个组件） | 无 | cpu 50m~100m / mem 128~256Mi | cpu 500m / mem 512Mi | 控制面型，常驻小内存 |
| `tekton-pipelines/{pipelines,triggers,events}-controller` | 无 | cpu 100m / mem 128Mi | cpu 1 / mem 1Gi | webhook + 控制器 |
| `cert-manager/*`（3 个） | 无 | cpu 100m / mem 128Mi | cpu 500m / mem 512Mi | 与现有 knative 组件对齐 |
| `tempo3-block-builder` / `live-store` | 3 副本，已有空限制 | cpu 300m / mem 512Mi | cpu 1 / mem 2Gi | 3 副本，扩容后自动分摊 |
| `prometheus` | 500m / 2Gi | 保持 | 2 / 4Gi | 已在 worker03，不动 |

> 修改方式：这些组件由 Helm 管理，**改 Helm values 而不是 `kubectl patch`**（否则下次 `helm upgrade` 会被打回）。升级路径同样需要人工执行，暂无 ArgoCD Application（`kubectl get applications -n argocd` 为空），因此走 `helm upgrade --reuse-values` + values 文件持久化。

### P0-2 修复节点拓扑标签

二选一，**推荐方案 B**（改动面更小、不引入新的 zone 语义）。

**方案 A：补标准 zone 标签**（保留现有 `zone` 语义，让已有 12 处 TSC 生效）

```bash
kubectl label node worker01 topology.kubernetes.io/zone=test-a --overwrite
kubectl label node worker02 topology.kubernetes.io/zone=test-b --overwrite
kubectl label node worker03 topology.kubernetes.io/zone=test-a --overwrite
# control-plane 无 zone 语义，不打标签（否则 TSC 的 eligible domain 计算会被污染）
```

代价：3 台节点中 2 台同属 test-a，**zone 级 maxSkew 在 2 域 / 3 节点下几乎无法真正摊开**，且部分组件会因 zone 内 2 节点而"看似满足实际没摊"。

**方案 B：把 TSC 从 zone 改为 hostname（推荐）**

```bash
# 逐个组件修改 topologySpreadConstraints.topologyKey，hostname 才是本集群真正有效的拓扑维度
# 例：tempo3 StatefulSet/Deployment
kubectl patch sts tempo3-block-builder -n logging --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/topologyKey","value":"kubernetes.io/hostname"}]'
```

同时把 `maxSkew: 1` + `whenUnsatisfiable: ScheduleAnyway` 的组合保留（软约束不阻塞启动），但对**要真正分摊的组件（§ P2-1）**在副本数 ≥2 后再评估是否升级为 `DoNotSchedule`。

> ⚠️ 修改 TSC 只影响**新建 Pod**，需配合 descheduler 重建 Pod 才生效。
>
> ⚠️ 对 `replicas=1` 的组件，**任何 TSC 都不起作用**（`maxSkew` 是同一组副本之间的相对约束）。这是本集群最大的结构性限制，见 P2-1。

### P0-3 清理 default namespace 遗留 Pod

`default` 空间有 5 个实验残留占用着 worker01/worker02/worker03（详见 `/root/default-ns-pod-provenance.md`）：

| Pod | 位置 | 建议 |
|---|---|---|
| `netshoot-debug-54c86b9985-48z9t` | worker01 | 删除（调试工具，已 11h 无变更） |
| `hello-00003-deployment` | worker02 | 确认 demo 是否还保留，保留则补 requests |
| `report-processor-00001-deployment` | worker03 | Knative demo revision，确认后归档 |
| `autoscale-demo-00003-deployment` | — | 同上 |

清理后 worker01 直接减少 1 个常驻 Pod，且消除一个 BestEffort 黑洞。

> 采集过程中还观测到 `default/report-processor-00001-deployment` 在 10 分钟内连续产生 3 个 Knative revision（`-rh7n5` → `-jfqp8` → `-vmzjq`），属于 demo 的自动伸缩churn。这类 Pod 的建/删会让上面的分布统计短时抖动，**做前后对比时请以 10 分钟窗口的稳定值为准**。

### P1-1 部署 descheduler（让历史倾斜自我纠正）

**部署可行性与镜像来源**：本管理机**无法访问 github.com / raw.githubusercontent.com**（已实测超时），`autoscaler` Helm 仓库索引中也**不含 descheduler chart**（只有 cluster-autoscaler 与 vertical-pod-autoscaler）。但 containerd 已配置镜像加速（`/etc/containerd/certs.d/` 下 `registry.k8s.io → https://k8s.1ms.run`、`docker.io → docker.m.daocloud.io`，实测加速端点均可达），因此采用**手写 manifest + 官方镜像**方式部署。部署前先用附录 B 的 `crictl pull` 确认镜像可拉取。

```yaml
# descheduler.yaml  —— 完整内容见附录 B
apiVersion: v1
kind: ServiceAccount
metadata:
  name: descheduler
  namespace: kube-system
---
apiVersion: v1
kind: ClusterRole
metadata:
  name: descheduler
rules:
  - apiGroups: ["api", ""]
    resources: ["pods", "nodes", "namespaces"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: descheduler
  namespace: kube-system
  labels: { app: descheduler }
spec:
  replicas: 1
  selector:
    matchLabels: { app: descheduler }
  template:
    metadata:
      labels: { app: descheduler }
    spec:
      serviceAccountName: descheduler
      priorityClassName: system-cluster-critical
      nodeSelector: { kubernetes.io/hostname: worker03 }   # 刻意放在最空节点，避免自我加剧失衡
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Equal
          effect: NoSchedule
          value: ""
      containers:
        - name: descheduler
          image: registry.k8s.io/descheduler/descheduler:v0.33.0
          args:
            - --policy-config-file=/policy-dir/policy.yaml
            - --v=2
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 512Mi }
          volumeMounts:
            - { name: policy-dir, mountPath: /policy-dir }
      volumes:
        - name: policy-dir
          configMap: { name: descheduler-policy }
```

```yaml
# policy ConfigMap：LowNodeUtilization（把 worker01 的 requests 压力降到容量加权线）
#                 + RemoveDuplicates（清理同副本落同一节点）
apiVersion: v1
kind: ConfigMap
metadata:
  name: descheduler-policy
  namespace: kube-system
data:
  policy.yaml: |
    apiVersion: "descheduler/v1alpha2"
    kind: "DeschedulerPolicy"
    nodeSelector: "node-role.kubernetes.io/control-plane!=true"   # 只在 worker 上动作
    maxNoOfPodsToEvictPerNode: 5          # 保守限速，避免一次搬走太多触发雪崩
    maxNoOfPodsToEvictPerNamespace: 2
    profiles:
      - name: balance-utilization
        pluginConfig:
          - name: "DefaultEvictor"
            args:
              evictSystemCriticalPods: false      # 保护 Calico/kube-proxy/metallb 等
              evictLocalStoragePods: false       # 无本地卷，本项为兜底
              nodeFit: true                     # 关键：只驱逐"搬走后目标节点仍装得下"的 Pod
          - name: "LowNodeUtilization"
            args:
              thresholds:
                cpu: 20        # 低于容量的 20% 视为"欠载"
                memory: 20
              targetThresholds:
                cpu: 40        # 迁出直到降到 40% 以下
                memory: 40
        plugins:
          balance:
            enabled:
              - "LowNodeUtilization"
              - "RemoveDuplicates"
```

**策略参数取值依据**（结合本集群实测）：三节点 requests CPU 总量仅占 42%，`targetThresholds` 设为 40%/40% 意味着会持续把总量往"占容量 40%"的方向牵引，最终稳定在 worker01≈37%、worker02≈37%、worker03≈25% 左右——正是容量加权目标。`nodeFit: true` 保证不会为了均衡而制造超卖。`evictLocalStoragePods: false` 是必须的（本集群 PV 均为 Ceph RBD / NFS，但 kubelet 的 `local` 临时存储仍需保守对待）。

> ⚠️ **descheduler 只处理"可驱逐 Pod"**：StatefulSet Pod 会被尊重 PDB，但 `cnpg-system/pg16-ceph-primary` 的 PDB `minAvailable=1`、当前 `allowedDisruptions=0` → 数据库 Pod 不会被自动驱逐，需人工处理。
>
> ⚠️ **单副本 Deployment + PDB 80% 的组合**（knative 的 4 个 PDB）同样 `allowedDisruptions=0`，descheduler 跳过它们。这些组件必须靠 P2-1 扩容 + `maxUnavailable` 调整才能分摊。

### P1-2 定制 kube-scheduler 配置

当前 3 个 scheduler 实例均为默认配置。要让 `PodTopologySpread` 的打分和均衡权重可控，必须引入 `KubeSchedulerConfiguration`（完整文件见附录 C）。要点：

1. **保留默认插件集**，只调整 `NodeResourcesBalancedAllocation` 权重：`resources: { cpu: 1, memory: 2 }` —— 本集群内存才是真实瓶颈（worker01 内存已贴顶而 CPU 仅 10%）。
2. **开启 `PodTopologySpread` 的 Scoring**（默认已启用，显式声明权重）。
3. 为 descheduler 预留独立 profile（`descheduler`），让自动搬迁的 Pod 走"先按 TSC 打分"的路径，避免与业务调度抢同一份打分逻辑。
4. **三台 control-plane 必须使用完全相同的配置文件**，且滚动顺序为 `master02 → master01 → m01`（每台等 leader 切换稳定后再动下一台，`--leader-elect=true` 保证任何时刻至少一个可用）。

```bash
# 每台 master 上的操作（在 /etc/kubernetes/manifests/kube-scheduler.yaml 增加）
#   - --config=/etc/kubernetes/scheduler-config.yaml
# 并新增 volumeMount 挂载 /etc/kubernetes/scheduler-config.yaml（hostPath）
```

> ⚠️ 配置文件语法错误会导致 scheduler 启动失败形成 CrashLoop，而 **3 副本同时挂 = 集群完全无法调度新 Pod**。务必：① 先 `kube-scheduler --config=xxx --write-config-to` 在本地做语法校验；② 一次只改一台；③ 改完立刻 `kubectl get pod -n kube-system kube-scheduler-<node> -w` 确认 Ready。

### P2-1 把单副本关键组件扩到 2 副本（真正的"分摊"）

这是本方案里**唯一能突破"只能移动不能分摊"天花板**的动作。69 个 Deployment 中 60 个是单副本，13 个 StatefulSet 中 11 个是单副本。

**优先级排序（按"是否影响业务连续性 × 是否已有存储约束"评估）**：

| 优先级 | 组件 | 当前 | 目标 | 可行性说明 |
|---|---|---|---|---|
| 高 | `logging/tempo3-querier` / `query-frontend` / `distributor` / `metrics-generator` | 1 | 2 | 无状态 + **已有 required podAntiAffinity(hostname)** → 改 replicas 即自动分摊，零额外配置 |
| 高 | `tempo3-block-builder` / `tempo3-live-store` | 3 | 3（保持） | 已 3 副本，且分布在 worker01/02；补 hostname TSC 后可摊到 3 节点 |
| 高 | `cert-manager` / `cainjector` / `webhook` | 1 | 2 | 无状态，注意 webhook 双副本需确认证书轮换逻辑（cert-manager 自身支持多副本） |
| 高 | `argocd-repo-server` / `notifications-controller` | 1 | 2 | 无状态，ArgoCD 官方支持多副本 |
| ❌ 不做 | `argocd-redis` | 1 | — | ArgoCD 的 redis 承担缓存/会话/leader 角色，官方定位为单实例；扩副本前必须确认当前版本是否支持，否则会出现会话不一致 |
| 中 | `tekton-pipelines-controller` / `triggers-controller` / `events-controller` | 1 | 2 | 无状态控制器，支持多副本 |
| 中 | `monitoring/prometheus-prometheus-prometheus` | 1 | **2** | 单副本是可用性单点。kube-prometheus-stack 的 Prometheus 支持多副本（需 `--storage.tsdb.retention` + Service 负载均衡），**但必须先确认 nfs-sc 的 100Gi PVC 是否支持 ReadWriteMany**（当前 nfs-provisioner 支持 RWX，但需实测） |
| 中 | `monitoring/alertmanager-prometheus-alertmanager-0` | 1 | 2 | Alertmanager 原生支持多副本 + gossip，**推荐** |
| 低 | `cnpg-system/pg16-ceph` 实例 | 2 实例 × 1 | 保持 2 或改 2×1 分散 | `affinity.podAntiAffinityType: preferred`（软）→ 可把 `instances[].replicas` 提到 2 得到 4 个实例分摊 3 节点；存储 `ceph-rbd-sc` 为 `Immediate` 绑定，**扩容不涉及卷迁移，安全** |
| 低 | `kube-system/metrics-server` | 1 | 2 | 本身是 P1/P2 的依赖，单副本是单点 |
| ❌ 不做 | `kafka/my-cluster-single-pool-0` | 1 | — | Kafka broker 扩副本涉及分区重平衡，实验环境收益/风险不划算 |
| ❌ 不做 | `traefik` / `3scale-kourier-gateway` | 1 | — | LoadBalancer 单入口（MetalLB 10.110.191.58 / 10.111.240.160），扩副本会引入入口语义变化，且有 PDB 80% 保护 |

**扩副本后同步调整 PDB**：knative 的 4 个 PDB 是 `minAvailable: 80%`，`replicas=2` 时 `allowedDisruptions` 仍为 1（可行），但 `replicas=1` 时恒为 0 —— 扩副本同时让 descheduler/节点维护真正可动。

### P2-2 VPA 试点（把已装的能力用起来）

VPA 三件套已部署但 **0 个对象**，`kubectl top` 可用，`InPlacePodVerticalScaling` 在 1.35 已 GA。选两个无状态组件试点：

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: tempo3-querier
  namespace: logging
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: tempo3-querier
  updatePolicy:
    updateMode: InPlaceOrRecreate      # 优先原地扩缩，失败再重建
    minReplicas: 2                    # 依赖 P2-1 扩到 2 副本后再启用
  resourcePolicy:
    containerPolicies:
      - containerName: tempo3-querier
        minAllowed: { cpu: 100m, memory: 256Mi }
        maxAllowed: { cpu: "2", memory: 4Gi }
```

> ⚠️ 必须配合 `replicas>=2` + 跨节点反亲和，否则 VPA 会重启 Pod 而 Pod 又被拉回同一节点，形成抖动。
>
> ⚠️ VPA 会**修改 Pod 的 resources 字段**从而改变 requests，直接影响本方案 P0-1 手工设定的基线。上线后要重新核对 P0-1 表格并以 VPA recommendation 为准。

### P3-1 节点角色标签规范化

补齐 worker 角色标签，让标准选择器可用（当前 `kubectl get nodes -l node-role.kubernetes.io/worker` 返回空，任何基于该标签的运维脚本/策略/告警规则都是空跑）：

```bash
for n in worker01 worker02 worker03; do
  kubectl label node $n node-role.kubernetes.io/worker= --overwrite
done
# 验证
kubectl get nodes -l node-role.kubernetes.io/worker
```

同时补齐 P1-1 descheduler 里用到的 `node-role.kubernetes.io/control-plane!=true` 表达式所需的对照标签（control-plane 已有该标签，表达式可直接工作）。

### P3-2 容量规划（结构性改进）

- **worker03 只有 4C/7.7Gi，比另两台少 33% CPU**。在 PVE 上把 worker03 提到 6C/10Gi 与另两台对齐，可让"均衡"目标从 37.5/37.5/25 变成干净的 1/3:1/3:1/3，后续不必再做容量加权。VM 规格变更需要停机，建议与 PVE 维护窗口合并。
- **备选：再加 1 台 worker**（4 台 = 6:6:4:4，均衡空间更大，且单节点故障时剩余容量更充裕）。但注意 `/root/infra-topology-truth.md` 的结论：**K8s 与 Ceph 共生于同一台 PVE 宿主机**，总资源已近饱和（K8s 28 vCPU/43Gi + Ceph 14 vCPU/18.5Gi ≈ 42 vCPU/61.5Gi），扩节点前必须先核算宿主机余量，否则只是把瓶颈从 VM 层推到宿主层。
- **历史数据提示**：worker03 磁盘 `/` 占用 69%（约 31G/48G），其中约 4.0GB 是历史残留镜像（`k8s-cluster-audit-2026-10-03.md` 实测）。**迁移工作负载到 worker03 前先执行镜像 prune**，否则新 Pod 拉镜像/解包会触发 DiskPressure。

### 关于"放开 control-plane 承载业务"的评估（**不推荐**）

三台 control-plane 合计 12 核 / 15Gi，requests 仅占用 25~28%，看起来有空间。但：

- m01 是**当前 PVE 上最忙的宿主机 VM**（内存 71%），且是本管理机的登录节点；
- 移除 `control-plane:NoSchedule` 会让 etcd/apiserver 与业务 Pod 争抢同一 VM 的 4 核 CPU，**etcd 写入延迟抖动会直接影响全集群**；
- 收益远小于"给 worker03 提配"或"加一台 worker"。

**结论：保持 control-plane 污点不变。** 均衡只在 3 台 worker 之间做。

---

## 五、执行顺序与验证

### 5.1 建议时间线

| 阶段 | 内容 | 风险 | 可否回滚 |
|---|---|---|---|
| **第 1 步** | P3-1 补 worker 角色标签；P0-3 清理 default 遗留；P0-2 打 zone 标签（方案 A）或 patch TSC（方案 B） | 极低 | 是（删标签/回滚 patch） |
| **第 2 步** | P0-1② 精调 requests（先 logging、argocd、tekton、cert-manager 四个 namespace），用 `helm upgrade` 滚动 | 低（Pod 重建，单副本组件短暂中断） | 是（`helm rollback`） |
| **第 3 步** | P1-1 部署 descheduler，先 `maxNoOfPodsToEvictPerNode: 1` 灰度观察 1 小时，再放宽到 5 | 中（会开始搬 Pod） | 是（缩容到 0） |
| **第 4 步** | P2-1 扩副本（tempo3 四件套 → cert-manager → argocd → tekton → alertmanager） | 中 | 是（改回 replicas=1） |
| **第 5 步** | P0-1① 全 namespace LimitRange 兜底（此时 requests 已补齐，LimitRange 只会命中新组件） | 低 | 是（删 LimitRange） |
| **第 6 步** | P1-2 定制 scheduler 配置（三台逐台滚动） | **高**（配置错误会阻塞全集群调度） | 是（删 `--config` 参数，静态 Pod 自动重启） |
| **第 7 步** | P2-2 VPA 试点；P3-2 容量规划（需 PVE 窗口） | 低 / 需停机 | VPA 可删除；VM 提配需回滚 VM 配置 |

### 5.2 每步验证命令

```bash
# ① 负载分布（requests 口径，调度器实际看到的分布）
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name)\t\(.status.allocatable.cpu)\t\(.status.allocatable.memory)"'
# 对照目标：worker01 ≤45% / worker02 35~45% / worker03 18~30%

# ② BestEffort 清零检查（核心验收项）
kubectl get pods -A -o json | jq -r '.items[] | select(.status.qosClass=="BestEffort") | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l
# 目标：业务 Pod 为 0（DaemonSet 固定开销可保留）

# ③ 实际用量与内存余量
kubectl top nodes
# worker01 内存应从 57% 降到 45% 以下

# ④ 业务 Pod 数分布（剔除 DaemonSet）
kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.nodeName != null) | select(
    ([.metadata.ownerReferences[]?.kind] | index("DaemonSet")) | not
  ) | .spec.nodeName' | sort | uniq -c
# 目标：worker01≈33 / worker02≈33 / worker03≈22

# ⑤ descheduler 动作审计
kubectl -n kube-system logs deploy/descheduler --tail=200 | grep -E 'Evicted|MoveError|balance'

# ⑥ 调度失败/驱逐事件（应始终为空）
kubectl get events -A --field-selector reason=FailedScheduling
kubectl get pods -A -o json | jq -r '.items[] | select(.status.reason=="Evicted") | .metadata.name'

# ⑦ 拓扑标签生效确认
kubectl get nodes -l topology.kubernetes.io/zone

# ⑧ HPA 是否恢复工作（有 requests 后 CPU 利用率才有意义）
kubectl get hpa -A
```

### 5.3 验收清单

- [ ] 三节点 BestEffort 业务 Pod = 0
- [ ] 各节点 req CPU% 与容量加权目标偏差 ≤ 15pp
- [ ] 各节点 req 内存% 与容量加权目标偏差 ≤ 15pp
- [ ] worker01 实际内存 ≤ 45%，requests 覆盖率 ≤ 85%
- [ ] 业务 Pod 数分布 33/33/22 ± 10pp
- [ ] descheduler 日志无 `MoveError`，`kubectl get events -A --field-selector reason=FailedScheduling` 为空
- [ ] tempo3 / cert-manager / argocd / tekton 的多副本确实跨 3 个节点分布
- [ ] HPA 的 5 个对象 `TARGETS` 列出现真实百分比（不再是恒定 0%）

---

## 六、风险与回滚

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| **scheduler 配置错误导致全集群无法调度** | 低 | 严重 | 一次只改一台；改前用 `kube-scheduler --config=file --write-config-to=/tmp/x.yaml` 校验语法；leader 切换稳定后再动下一台 |
| descheduler 一次性驱逐过多引发连锁重调度 | 中 | 中 | `maxNoOfPodsToEvictPerNode` 从 1 灰度起步；`nodeFit: true`；保留 PDB 保护 |
| 补 requests 后内存预留突增，触发 Pending | 中 | 中 | 三节点内存 requests 总量仅 9.40Gi/26.9Gi = 35%，加 LimitRange 默认值后仍在 50% 以内；上线前用 `--dry-run=server` 验证 |
| 单副本组件滚动重建期间短暂不可用 | 高 | 低-中 | 全部组件均为实验/平台用途，非生产 SLA；关键路径（kourier、traefik、prometheus）排在最后或不动 |
| CNPG 数据库 Pod 被误驱逐 | 低 | 高 | `pg16-ceph-primary` PDB `minAvailable=1`，`allowedDisruptions=0`，descheduler 不会动；人工操作前先确认主备角色 |
| Kafka broker 副本变化导致分区不可用 | 低 | 高 | 本方案明确**不扩 Kafka 副本** |
| LimitRange 覆盖 knative 等 namespace 导致 QoS 抖动 | 中 | 中 | LimitRange 放在第 5 步，等 requests 已补齐后再启用 |
| worker03 磁盘 69% 触发 DiskPressure | 中 | 中 | 迁移前先 `crictl rmi --prune` 回收约 4GB 历史镜像 |

**回滚要点**：本方案所有变更均为声明式（Helm values / 标签 / manifest），`helm rollback <release> <revision>` 与删除标签即可回退；descheduler 可直接 `scale deploy/descheduler --replicas=0`；scheduler 配置回滚 = 删掉 `--config` 参数，静态 Pod 会自动重启回默认行为（这一步反而是最安全的兜底）。

---

## 附录 A：本次实测使用的命令清单

```bash
# 节点与标签
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\t"}{.spec.taints}{"\n"}{end}'
kubectl get nodes -l node-role.kubernetes.io/worker          # 空 → worker 无角色标签
kubectl get nodes -l topology.kubernetes.io/zone               # 空 → 无标准 zone 标签

# 负载分布
kubectl describe nodes | grep -A20 'Allocated resources'
kubectl top nodes
kubectl get pods -A -o wide --field-selector spec.nodeName=worker01

# QoS / requests 缺口
kubectl get pods -A -o jsonpath='{range .items[*]}{.status.qosClass}{"\n"}{end}' | sort | uniq -c
kubectl get resourcequota -A ; kubectl get limitrange -A

# 调度栈
kubectl get pod -n kube-system kube-scheduler-master01 -o jsonpath='{.spec.containers[0].command}{.spec.containers[0].args}'
kubectl get deploy -A | grep -iE 'desched|volcano|kueue|koordinator'
kubectl get vpa -A
kubectl get hpa -A ; kubectl get pdb -A

# 约束与存储
kubectl get deploy,sts -A -o json | jq '.items[].spec.template.spec | {nodeSelector,affinity,topologySpreadConstraints}'
kubectl get sc -o custom-columns='NAME:.metadata.name,VOLBIND:.volumeBindingMode'
kubectl get pv -o json | jq -r '.items[] | "\(.metadata.name) nodeAffinity=\(.spec.nodeAffinity // "none")"'

# 失衡时间线
kubectl get pods -A -o json | jq -r '.items[] | "\(.metadata.creationTimestamp) \(.spec.nodeName) \(.metadata.namespace)/\(.metadata.name)"' | sort
```

## 附录 B：descheduler 完整部署清单

见 § P1-1 的三段 YAML（ServiceAccount/ClusterRole/Deployment + ConfigMap policy）。部署顺序：

```bash
kubectl apply -f policy-configmap.yaml     # 先 ConfigMap
kubectl apply -f descheduler.yaml          # 再 Deployment
kubectl -n kube-system rollout status deploy/descheduler
kubectl -n kube-system logs deploy/descheduler --tail=50
```

镜像拉取自检（管理机无法访问 github，依赖 containerd 已配置的镜像加速）：

```bash
crictl pull registry.k8s.io/descheduler/descheduler:v0.33.0
```

## 附录 C：kube-scheduler 定制配置（要点，完整文件按 §P1-2 结构书写）

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
leaderElection:
  leaderElect: true
profiles:
  - schedulerName: default-scheduler
    plugins:
      score:
        enabled:
          - name: NodeResourcesBalancedAllocation
            weight: 1
          - name: PodTopologySpread
            weight: 2
    pluginConfig:
      - name: NodeResourcesBalancedAllocation
        args:
          apiVersion: kubescheduler.config.k8s.io/v1
          kind: NodeResourcesBalancedAllocationArgs
          resources:
            - name: cpu
              weight: 1
            - name: memory
              weight: 2          # 内存是本集群真实瓶颈（worker01 内存贴顶、CPU 仅 10%）
  - schedulerName: descheduler-scheduling   # 供 descheduler 使用，拓扑约束打分更高
    plugins:
      score:
        enabled:
          - name: PodTopologySpread
            weight: 5
      filter:
        enabled:
          - name: NodeResourcesFit
            disabled: false
```

> `weight` 取值范围 1~100，`NodeResourcesBalancedAllocation.resources[].weight` 上限为 100；这里保持保守（1:2），避免单次调度产生剧烈搬迁。**该配置必须在三台 master 上完全一致**，且必须先通过本地语法校验。

## 附录 D：本文档未采纳的方案及原因

| 方案 | 不采纳原因 |
|---|---|
| 移除 control-plane 污点让业务上 master | etcd/apiserver 与业务争抢同 VM 4 核 CPU，风险远大于收益（§P3-2 末） |
| 引入 Volcano / Kueue / Koordinator | 引入复杂度远超收益；3 节点场景下 `descheduler` + TSC 已足够 |
| 盲目调大 descheduler 频率（如 `--interval=1m`） | 会与 P0-1 的 rollout 互相打架，放大抖动；建议先 `--interval=5m` 跑一周 |
| 给所有组件加 `topologySpreadConstraints` + `DoNotSchedule` | 单副本组件加 DoNotSchedule 会直接导致 Pending（无法满足约束）；必须先扩副本 |
| 用 HPA 替代静态 requests 分布 | HPA 基于 CPU 利用率，无 requests 时失真（当前 5 个 HPA 全部形同虚设）；应先补 requests 再谈 HPA 扩容 |