# Kubernetes v1.35 详解：Timbernetes（世界树版本）

> 文档定位：从 1.29 升级到 1.35 之后，理解这个版本带来了什么、为什么值得升级、以及还有哪些坑要处理。
>
> - 版本代号：**Timbernetes（The World Tree）**
> - 发布日期：**2025-12-17**
> - 增强项总数：**60 个**（**17 个 GA** / **19 个 Beta** / **22 个 Alpha**）
> - 当前最新补丁：**1.35.8**（2026-08-11），1.35.9 计划于 2026-09-15
> - 参考：官方发布博客、官方发布说明、KEP

---

## 目录

1. [为什么大家说 1.35「经典」](#一为什么大家说-135经典)
2. [官方重点推荐的三大更新](#二官方重点推荐的三大更新)
3. [GA 特性详解（15 项）](#三ga-特性详解15-项)
4. [Beta 新特性详解（重点）](#四beta-新特性详解重点)
5. [Alpha 新特性详解](#五alpha-新特性详解)
6. [底层基础设施的进步](#六底层基础设施的进步)
7. [弃用、移除与必须行动项](#七弃用移除与必须行动项)
8. [从 1.29 到 1.35：你会一并获得的能力](#八从-129-到-135你会一并获得的能力)
9. [1.35 的核心优势总结](#九135-的核心优势总结)
10. [升级后行动检查清单](#十升级后行动检查清单)
11. [参考链接](#十一参考链接)

---

## 一、为什么大家说 1.35「经典」

这个说法不是营销话术，而是有具体依据的。1.35 的特殊之处在于它是一个**「收口版本」**——大量孵化多年的能力在同一时间点集中毕业，形成了一个非常完整的能力组合：

| 维度 | 1.35 的状态 | 说明 |
|---|---|---|
| **资源调整** | Pod 资源原地更新 **GA** | 孵化 6 年（1.27 Alpha → 1.33 Beta → 1.35 GA），终于不用删 Pod 改资源了 |
| **异构设备** | DRA 核心特性 **锁定启用** | 1.34 GA，1.35 起不可关闭，替代 Device Plugin 的长期路线确立 |
| **安全** | Pod Certificate **Beta** + 用户命名空间 **Beta** + 缓存镜像凭据强校验 **Beta 默认开** + 受限身份扮演 **Alpha** | 原生工作负载身份 + 多租户隔离，四管齐下 |
| **调度** | Workload API + Gang Scheduling（Alpha）+ 机会式批处理（Beta） | 「工作负载感知调度」北极星目标正式起步 |
| **一致性** | 资源版本（resourceVersion）可比较 | 控制器正确性的一次底层语义升级，支撑存储版本迁移等 |
| **稳定性** | kubelet 重启不再让健康 Pod 掉成 NotReady | 节点维护期不再断流，这类「小改进」实际价值极大 |

**换句话说**：1.35 不是「加了很多新玩具」的版本，而是**把一批关键能力从「可以试」推到「可以放心用」**的版本。对于从 1.29 跨度 6 个小版本上来的团队，这是一个非常合适的落脚点。

> ⚠️ 一个需要说清楚的事实：截至 2026-10，上游最新是 **1.37**，1.35 是**当前仍在维护的最老的小版本**。选 1.35 意味着安全与 bugfix 修复窗口最短（预计 2027 年初 EOL），适合「先稳住」；如果打算长期跑，建议评估是否直接上 1.36/1.37（1.36 已把用户命名空间推到 GA、Pod 级资源原地扩缩容推到 Beta）。

---

## 二、官方重点推荐的三大更新

### 2.1 【GA】Pod 资源原地更新（In-Place Update of Pod Resources）

**KEP-1287 | SIG Node**

这是本版本的第一主角，也是最被期待的特性。

```yaml
# 通过 Pod 的 resize 子资源直接调整运行中容器的 CPU / 内存
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    resources:
      requests:
        cpu: "2"      # 期望值：可在线修改
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 8Gi
```

```bash
# 使用 resize 子资源触发调整
kubectl patch pod my-app --subresource resize --type=merge \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"4"},"limits":{"cpu":"8"}}}]}}'
```

**能力变化：**
- `spec.containers[*].resources` 现在表示**期望值**（CPU/内存可改）
- `status.containerStatuses[*].resources` 反映**实际生效值**
- PodStatus 新增 `resources` 与 `allocatedResources`，记录 Pod 级 cgroup 资源与申请资源

**实际收益：**
1. **有状态应用不再需要重建 Pod** —— 数据库、消息队列、批处理作业的垂直扩缩容不中断连接
2. **与 VPA（Vertical Pod Autoscaler）天然互补** —— VPA 观察指标 → 发起 resize 请求，闭环
3. **开发调试更顺畅** —— 不必删掉 Pod 重来

**从 1.33 Beta 到 1.35 Stable 的关键改进：**
- **允许降低内存 limit**（此前禁止）。kubelet 会在当前内存用量低于新 limit 时才放行，但这是 best-effort，不保证
- **resize 请求具备优先级**：按 PriorityClass → QoS 等级 → Deferred 时长（老的优先）排队
- **可观测性增强**：新增专属 kubelet 指标与 Pod 事件
- **Pod 级资源（Pod Level Resources）**支持在自有 feature gate 后开启（1.35 为 Alpha）

**仍需注意的限制：**
- 与 swap、静态 CPU Manager、静态 Memory Manager 组合时**禁止**使用
- 除 CPU/内存外的资源（如 GPU）**仍不可改**
- kubelet 与 scheduler 之间**已知存在竞态条件**，官方承诺在未来几个版本修复
- 尚未支持工作负载抢占（resize 空间不足时不会自动驱逐低优先级 Pod）

---

### 2.2 【Beta】Pod 证书：原生工作负载身份

**KEP-4317 | SIG Auth**

这是 1.35 中**安全价值最高**的改进。

**过去**：给 Pod 签发证书需要 cert-manager / SPIFFE/SPIRE + CRD 编排 + Secret 管理 + sidecar 或 init container 做轮换，链路长、组件多、易出错。

**现在**：
1. `kubelet` 生成私钥 → 通过 `PodCertificateRequest` 请求证书
2. 证书与凭据包**直接写入 Pod 文件系统**（projected volume）
3. `kube-apiserver` 在**准入阶段强制执行节点约束** —— 这直接堵住了第三方签名者最常见的坑：无意间突破节点隔离边界
4. **签发链路无需持有者令牌（holder token）**，即可实现纯双向 TLS

**收益：**
- 服务网格、零信任网络策略的搭建成本大幅下降
- 证书自动轮换，不再需要外部控制器盯着
- Pod-to-Pod 通信原生具备强身份

---

### 2.3 【Alpha】节点声明式特性（Node Declared Features）

**KEP-5328 | SIG Node**

**要解决的问题**：控制平面启用了新 feature、但节点因版本偏差策略（skew policy）还没升级 —— 调度器可能把需要该特性的 Pod 调度到不兼容的旧节点上，运行期才炸。

**机制**：
- 节点通过新的 `.status.declaredFeatures` 字段声明自己支持的特性
- `kube-scheduler`、准入控制器、第三方组件（含 Cluster Autoscaler）读取该声明
- 可强制执行调度与 API 校验约束，确保 Pod 只落在兼容节点上

**收益**：减少手工打标签、提升调度准确性、**主动**防止不兼容放置。与 Cluster Autoscaler 联动后可做出更明智的扩容决策。特性声明与 feature gate 绑定，便于安全灰度与清理。

---

## 三、GA 特性详解（15 项）

### 3.1 重点 GA

| 特性 | KEP | 说明 |
|---|---|---|
| **Pod 资源原地更新** | 1287 | 见上文 2.1 |
| **PreferSameNode 流量分配** | 3015 | Service `trafficDistribution` 新增 `PreferSameNode`，客户端优先连本节点 Endpoint，无则回退远端。同时 `PreferClose` 重命名为 `PreferSameZone`（旧值保留兼容）。对 CoreDNS 等场景降低延迟效果明显 |
| **Job API managed-by 机制** | 4368 | `Job.spec.managedBy` 允许外部控制器（如 Kueue / MultiKueue）接管 Job 的状态同步，内置 Job 控制器不再处理该 Job。由 MultiKueue 多集群分发场景推动 |
| **Pod Generation** | 5067 | Pod 获得 `.metadata.generation`（spec 变更即自增），新增 `.status.observedGeneration` 报告 kubelet 已处理的 generation，各 condition 也带独立 `observedGeneration`。**终于能可靠判断「Pod 改的东西生效了没」** |
| **TopologyManager NUMA 上限可配** | 4622 | 新增 `max-allowable-numa-nodes` 策略选项，**解除硬编码的 8 个 NUMA 节点上限**，高端 CPU / AI 加速卡服务器可用。注：大规模 NUMA 主机上性能仍欠佳，KEP-5726 在改进 |
| **从 SPDY 迁移到 WebSockets** | 4006 | exec / port-forward / attach 通道全面 WebSocket 化，带宽利用率与长连接稳定性提升，替换老旧 SPDY |

### 3.2 其余 GA 项

| 特性 | KEP | 说明 |
|---|---|---|
| CPUManager 策略选项 | 4540 | 将 `reservedSystemCPUs` 限定用于系统 daemon 与中断处理 |
| Invariant Testing | 5468 | API 一致性不变量测试框架 |
| 细粒度 SupplementalGroups 控制 | 3619 | 更精确控制补充组 |
| drop-in kubelet 配置目录 | 3983 | 允许放置 kubelet 配置片段目录 |
| 移除 API 类型对 gogo protobuf 的依赖 | 5589 | 换用标准 protobuf，降低内存与 CPU 开销 |
| kubelet 镜像 GC：按最大镜像年龄 | 4210 | 超过最大年龄的镜像自动清理，防止节点磁盘被陈旧镜像占满 |
| kubelet 并行拉取镜像数量上限 | 3673 | 大规模节点启动时避免拉取风暴打爆 registry |
| HTTP 请求头包含 kubectl 命令元数据 | 859 | 审计日志可识别请求来源命令 |

---

## 四、Beta 新特性详解（重点）

### 4.1 StatefulSet `maxUnavailable`（KEP-961）—— 有状态应用更新提速

```yaml
apiVersion: apps/v1
kind: StatefulSet
spec:
  podManagementPolicy: Parallel          # 与 maxUnavailable 组合效果最佳
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%                # 或整数，如 3
```

- 从 1.24 的 Alpha 升到 **Beta 且默认启用**
- 支持整数或百分比，**不填默认为 1**（保持「一次一个」的旧行为）
- 效果：可容忍多副本同时不可用的应用（数据库集群等）**更新速度最高提升约 60%**，显著压缩维护窗口

### 4.2 通过 Downward API 暴露节点拓扑标签（KEP-4742）

- 内置 `PodTopologyLabels` 准入控制器把标准拓扑标签（`topology.kubernetes.io/zone`、`topology.kubernetes.io/region` 等）**同步到 Pod**
- 容器可通过环境变量 / projected volume 直接拿到区域、可用区、主机名
- **不再需要**查 API Server（省掉宽泛 RBAC 授权）、**不再需要**特权 init container 或 sidecar

> 🔴 **重要提醒**：升级后你会看到**每一个 Pod 都多出若干标签**，这是预期行为。但要检查是否有基于标签选择器的策略、配额、NetworkPolicy 或 GitOps 同步规则被影响。

### 4.3 存储版本迁移原生支持（KEP-4192）—— 从 Beta 起默认开启

- 存储版本迁移器（SVM）从外部组件**移入 kube-controller-manager**，提供标准化 `StorageVersionMigration` API
- 替代手工 `kubectl get | kubectl replace` 循环（对 Secret 这类大资源尤其低效且易冲突）
- 内置控制器自动处理更新冲突与一致性令牌
- ⚠️ **API 变更**：`StorageVersionMigration` 新增 `v1beta1` API，**移除 `v1alpha1`**。升级前必须删除所有 `v1alpha1` 资源

### 4.4 可变更的卷挂接上限（KEP-4876）—— 解决 Pod 卡在 ContainerCreating

- 痛点：CSI 驱动启动后卷槽位被消耗，但 `CSINode` 上报容量未变 → 调度器把有状态 Pod 调度到挂接容量不足的节点 → 卡在 `ContainerCreating`
- 现在 `CSINode.spec.drivers[*].allocatable.count` **可动态变更**
- 通过 `CSIDriver` 对象引入**可配置刷新间隔**，由驱动控制全集群更新频率
- 检测到因容量不足导致的挂接失败时，**自动修正** `allocatable.count`
- 1.34 时 feature gate 默认关闭，**1.35 默认启用**

### 4.5 机会式批处理（KEP-5598）—— 调度性能优化，Beta 默认开

- 过去调度器**顺序处理** Pod，复杂度 `O(Pod 数 × 节点数)`，对「可兼容 Pod」重复计算
- 新机制：通过 **Pod 调度签名（Pod Scheduling Signature）** 识别可兼容 Pod 并批量处理，**共享过滤与打分结果**
- 两个操作：*create*（基于有效签名 Pod 的结果创建批处理信息）与 *nominate*（复用批处理信息为同签名新 Pod 设置提名节点）
- **无需用户选择加入、无需启用 Workload API**，默认生效；可用 `OpportunisticBatching` gate 关闭
- 目标场景：ML 集群中大量同构 workload 的高性能调度

### 4.6 用户命名空间支持（KEP-127）—— 容器逃逸防护，Beta

```yaml
spec:
  hostUsers: false     # 在命名空间内是 root，主机上是非特权高编号 UID
```

- Pod 内的 UID/GID 映射相互隔离，不再共享主机 ID
- 容器内可以 root 运行，主机上是**非特权高编号 UID**
- 即使发生容器逃逸，也**无法获得主机 root**
- 路线：1.25 Alpha → 1.30 Beta → **1.36 GA**

### 4.7 VolumeSource：OCI 工件 / 镜像（Beta，默认启用）

```yaml
volumes:
  - name: models
    image:
      reference: registry.example.com/ml-models:latest
      pullPolicy: IfNotPresent
```

- 直接把 OCI 镜像 / 工件**声明式挂载为只读卷**，替代「打进主镜像」或「init container 下载解包」
- 数据与镜像彻底解耦，可用标准 registry 工具分发配置、二进制、ML 模型
- ⚠️ 需要 containerd **v2.1 或更高版本**

### 4.8 对缓存镜像强制 kubelet 凭据校验（KEP-2535）—— 多租户安全关键

- 旧行为漏洞：`imagePullPolicy: IfNotPresent` 允许 Pod 使用节点上**已缓存**的镜像，**即使该 Pod 没有任何拉取凭据**
  - 攻击路径：有权限的 Pod 把私有镜像拉到某节点 → 同节点上任何 Pod 靠缓存即可访问
- 新行为：kubelet 在放行本地缓存镜像前，**校验 Pod 是否具备有效拉取凭据**
- **Beta 且默认启用**。可通过 `KubeletEnsureSecretPulledImages=false` 关闭
- `imagePullCredentialsVerificationPolicy` 可配置安全级别（从「优先兼容」到「严格强制」）

> 🔴 **这是升级后最可能影响现网的一条**：如果你的集群中不同团队共用节点，且存在跨团队使用私有镜像的情况，开启后可能**突然出现 ImagePullBackOff**。建议先排查，再决定关闭或调整策略。

### 4.9 细粒度容器重启规则（KEP-5307）—— Beta 默认启用

```yaml
spec:
  restartPolicy: Never                        # Pod 级：作业不重调度
  containers:
  - name: trainer
    restartPolicy: OnFailure                   # 容器级：可独立覆盖
    restartPolicyRules:
    - action: RestartOnFailure
      exitCodes: {operator: In, values: [137, 143]}
  - name: sidecar
    restartPolicyRules:
    - action: RestartAllContainers             # Alpha，需额外 gate
```

- 过去 `restartPolicy` 只能在 Pod 级定义，**强制所有容器行为一致**
- 现在可为**单个普通容器与 Init 容器**独立定义重启策略
- 典型场景：AI/ML 训练作业，Pod 用 `Never` 管理完成语义，但某些容器希望能针对可重试错误（网络抖动、GPU 初始化失败）**原地重启**，避免整个 Pod 重调度的高昂开销
- 相关 Alpha：**RestartAllContainersOnContainerExits**（`RestartAllContainers` 动作，Pod 生命周期从头重跑，新条件 `AllContainersRestarting` 观测）。注意：重启全部容器时 kubelet **不执行 preStop 钩子**

### 4.10 CSI 驱动 ServiceAccount 令牌安全传递（KEP-5538）

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
spec:
  serviceAccountTokenInSecrets: true
```

- 旧方式把 SA 令牌塞进 `volume_context`，而该字段**常被驱动和调试工具以明文记录到日志** → 凭据泄露
- 现在驱动可 opt-in 从 `NodePublishVolume` 请求的**专用 secrets 字段**获取令牌
- 向既有驱动保持向后兼容

### 4.11 可配置 HPA 容忍度（KEP-4951）

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
    - type: Percent
      value: 100
      periodSeconds: 15
    tolerance: 0.05        # 5%，不再固定 10%
```

- 过去 HPA **硬编码 10% 全局容忍度**：对高灵敏度负载（如需负载涨 5% 就扩容）不友好，长期无法触发；另一些负载则产生无谓振荡
- 现在可在 `behavior` 中**按资源粒度**定义容忍窗口

### 4.12 kuberc 凭据插件策略（KEP-3104）

```json
{
  "credentialPluginPolicy": "Allowlist",
  "credentialPluginAllowlist": ["my-approved-exec-plugin"]
}
```

- `credentialPluginPolicy`：允许或拒绝所有 exec 凭据插件
- `credentialPluginAllowlist`：指定允许清单
- 意义：`kuberc` 把服务器配置与凭据/用户偏好分离，避免 CI 流水线中因意外输出而中断

### 4.13 KYAML 输出格式（KEP-5295，Beta 默认启用）

- `kubectl get -o kyaml`：更安全、更少歧义的 YAML 子集
- 解决 YAML 的两个经典痛点：严格的缩进嵌套要求、可选字符串引用导致的意外类型转换（**The Norway Bug**）
- 所有 KYAML 都是合法 YAML，可喂给任意版本 kubectl；即使输入非严格 KYAML 也能解析
- ⚠️ 默认启用；`KUBECTL_KYAML=false` 可关闭

### 4.14 Deployment 状态：正在终止的副本计数（KEP-3973）

- Deployment 与 ReplicaSet 新增 `.status.terminatingReplicas`：已设 `deletionTimestamp` 但尚未移除的 Pod 数
- 过去无法区分「稳定的 Deployment」和「还有 Pod 在跑长优雅终止」的 Deployment
- 是更大计划的基础一步：为未来「滚动发布期间何时创建新 Pod」的策略铺路

---

## 五、Alpha 新特性详解

### 5.1 Gang Scheduling + Workload API（KEP-4671）—— 最具战略意义

**API 组**：`scheduling.k8s.io/v1alpha1`

**要解决的问题**：AI/ML 训练、HPC 仿真这类**相互依赖**的工作负载，默认调度器逐个调度 Pod → 部分已启动、其余无限等待 → **死锁 + 容量浪费**

**机制**：
- 新的 **Workload API** 以结构化、机器可读的形式描述多 Pod 应用的调度需求
  - 面向用户的工作负载（如 Job）定义「运行什么」
  - **Workload 资源定义「一组 Pod 应如何被调度」**，以及放置在整个生命周期中如何管理
- `gang` 策略强制 **all-or-nothing 放置**：只有集群能同时容纳整组 Pod 时才调度
- `kube-scheduler` 的 `GangScheduling` 插件按每个 Pod 组（或副本键）**独立管理生命周期**

**启用**：
```
kube-apiserver + kube-scheduler: GenericWorkload=true（并启用 scheduling.k8s.io/v1alpha1 API 组）
kube-scheduler:                GangScheduling=true（依赖 Workload API）
```

**后续规划**（官方明确）：整组单周期调度阶段、工作负载级抢占。

### 5.2 受限身份扮演 Constrained Impersonation（KEP-5284）

- 旧问题：RBAC 的 `impersonate` 动词是「全有或全无」——被授权扮演某身份 = 获得该身份**全部**权限，违背最小特权
- 新机制：增加**二次鉴权检查**，使用新动词前缀（形如 `impersonate-on:<mode>:<verb>`）校验扮演者是否有权执行**特定动作**
- 效果：允许支持工程师**仅为查看日志**而扮演集群管理员，而不是给完整管理员权限

### 5.3 Flagz / Statusz 结构化输出（KEP-4828 / 4827）

- 覆盖 `kube-apiserver`、`kube-scheduler`、`kube-controller-manager`、`kubelet`、`kube-proxy`
- `/flagz`：版本化结构化 JSON 响应，同时保留纯文本
- `/statusz`：提供 `v1alpha1` JSON 响应（通过正确的 Accept 头内容协商）
- 价值：外部系统**无需特权访问宿主机或解析脆弱文本**，即可编程式审计组件配置与健康状态 —— 合规与可观测性工作流的显著改进

### 5.4 CCM：基于 Informer 的 Watch 式路由调谐（KEP-5237）

- 旧问题：CCM 路由控制器**定时轮询**云 API → 大量无效调用、触发限流、状态变化到路由更新有延迟
- 新机制：用 Informer 监听 Node 事件（新增/删除/字段更新），**仅在确有变更时**触发路由同步
- 收益：云 API 调用量显著下降，拓扑变化后路由表立即更新

### 5.5 扩展容忍度运算符：阈值放置（KEP-5471）—— SLA 感知调度

```yaml
# 节点打上 SLA 污点
# Pod 容忍：SLA 值大于 950
tolerations:
- key: node.sla.io/tier
  operator: Gt            # 新增：Gt / Lt
  value: "950"
  effect: NoExecute
```

- 比 Node Affinity **更强**：支持 `NoExecute` 效果 —— 节点数值跌破阈值时**自动驱逐** Pod
- 场景：关键工作负载要求高 SLA 节点，低优先级负载使用低 SLA 节点 —— **不牺牲可靠性地提升利用率、降低成本**

### 5.6 Job 挂起时可改容器资源（KEP-5440）

```bash
kubectl patch job my-batch-job --subresource suspend   # 或其他方式置为挂起
# 挂起状态下修改 pod template 的 resources
kubectl set resources deployment --limits=cpu=4 --requests=cpu=2 ...
```

- 旧问题：Job spec **不可变**，OOM/CPU 不足失败后只能删除重建 → **丢失执行历史与状态**
- 现在：挂起 → 改 Pod template 资源 → 恢复执行，**不破坏 Job 生命周期标识，不丢失完成状态追踪**
- 对批处理场景的试错体验改善显著（1.36 已升为 Beta）

---

## 六、底层基础设施的进步

### 6.1 DRA（动态资源分配）持续创新

- **核心能力在 1.35 起始终启用、不可关闭**（1.34 已 GA 但可关）
- 1.35 的 Alpha 增强：
  - **通过 DRA 的扩展资源请求**：补齐与 Device Plugin 的差距（如 Init 容器中设备的打分与复用）
  - **设备污点与容忍度**：新增 `effect: None` 用于「演练」—— 先看会驱逐多少 Pod，再改成 `NoExecute` 真正执行
  - **可切分设备**：同类 Partitionable Device 现在可定义在不同的 ResourceSlice 中
  - **可消耗容量与设备绑定条件**：修复若干缺陷、补充测试

**DRA 相对 Device Plugin 的优势**：CEL 表达式细粒度过滤、设备可共享、驱动/管理员集中做设备分类（如「成本优化型」vs「高性能型」）、Pod 请求大幅简化。

### 6.2 可比较的资源版本语义（KEP-5504）

这是一次**语义层面的变更**，容易被忽略但影响深远：

- **1.35 之前**：客户端唯一受支持的比较方式是**字符串相等性**。客户端只能把 resourceVersion 交给 API Server 让控制面比较（如流式获取）
- **1.35 起**：所有 in-tree resourceVersion 都是特殊形式的十进制数，**客户端可以自行比较两个 resourceVersion**
- 具体收益：
  - 客户端崩溃重连后能**检测自己是否丢失了更新**（而非只判断「期间有无更新」）
  - 支撑**存储版本迁移**、informer 性能优化、**控制器可靠性提升**
- 一致性测试已覆盖所有内置 API 对象与自定义资源

### 6.3 kubelet 重启期间 Pod 稳定性（KEP-4781）

- 旧行为：重启 kubelet 会重置容器状态 → **健康 Pod 被标记 NotReady 并从负载均衡器摘除**，尽管应用运行正常
- 现在：kubelet 启动时从运行时**正确恢复现有容器状态**，Pod 保持 Ready，**kubelet 重启/升级期间流量持续不断**
- 对任何有滚动节点运维的团队，这一条的价值非常直接

### 6.4 镜像 GC 与并行拉取上限（KEP-4210 / 3673）

- 镜像垃圾回收支持**按最大镜像年龄**清理 → 防止节点磁盘被陈旧镜像占满
- kubelet **限制并行镜像拉取数** → 大规模节点启动时不打爆 registry

---

## 七、弃用、移除与必须行动项

> 🔴 这一节是本次升级**最需要逐条核对**的部分。

### 7.1 cgroup v1 支持移除 —— 影响最大

| 项 | 说明 |
|---|---|
| **变更** | `FailCgroupV1` 默认设为 **`true`**。Linux 节点上 kubelet **默认只支持 cgroups v2**，cgroup v1 节点上 **kubelet 将无法启动** |
| **kubeadm** | 1.35 起会**校验宿主机 cgroup 版本与 kubelet 版本**。检测到 cgroup v1 且目标 kubelet ≥ 1.35 时，preflight **直接报错** |
| **绕过方法** | ① 忽略 kubeadm SystemVerification preflight 报错；② 在 `kube-system/kubelet-config` ConfigMap 中设置 `failCgroupV1: false` |
| **各发行版** | AL2023：默认 cgroup v2，与上游一致；若手工配成 cgroup v1 必须迁移或设 `failCgroupV1: false`。Bottlerocket：默认 cgroup v2 但设了 `failCgroupV1: false` 保持兼容。Fargate：**仍用 cgroup v1** |

**连带影响 —— CPU shares → CPU weight 换算公式变更**：官方建议随 1.35 + cgroup v2 一起升级 **runc 1.3.2+ / crun 1.23+**，因为生态将采用新的 `cpu.weight` 换算公式。不升级可能出现**工作负载 CPU 优先级被意外降低**。

### 7.2 kube-proxy `ipvs` 模式弃用

- 本版本仍可用，但配置为 ipvs 时**启动即告警**
- Linux 节点**推荐迁移到 `nftables`**（已是上游推荐模式）

### 7.3 containerd 1.x 最终通告

- **1.35 是最后一个支持 containerd 1.x 的版本**（对齐 containerd 1.7 EOL）
- 升级到下一个小版本前，**必须切到 containerd 2.0+**
- 排查指标：**`kubelet_cri_losing_support`**
- 1.35 部分发行版默认已改用 containerd 2.x

### 7.4 Ingress NGINX 退役（影响重大）

- 维护者严重短缺 + 技术债累积，Kubernetes 项目宣布仅提供**尽力而为维护至 2026 年 3 月**，之后归档不再更新
- **推荐迁移路径：Gateway API**
- ⚠️ 不是 drop-in 替换，需要规划与工程投入。**现有部署仍可运行**，但退役后不再有 bug 修复与安全补丁
- 与 1.35 无直接关系，但**恰好同期发生，务必纳入规划**

### 7.5 其他 API / 门控变更

| 变更 | 说明 |
|---|---|
| `--pod-infra-container-image` | **已从 kubelet 移除**。自定义 AMI 用户升级前必须移除该配置 |
| `StorageVersionMigration` | 新增 `v1beta1` API，**移除 `v1alpha1`**。升级前必须删除所有 `v1alpha1` 资源 |
| `JobManagedBy` gate | 升 GA 后**锁定为 true**，后续版本将移除该 gate |
| DRA 核心 gate | **锁定默认启用，不可关闭** |
| `ExecProbeTimeout` gate | 锁定默认启用，无法回退到「忽略 exec 探针超时」的旧行为 |
| CRD | `conditions` 字段新增 `ObservedGeneration` |
| `PreferClose` | 重命名为 `PreferSameZone`（旧值保留兼容，建议逐步迁移） |
| DRA + swap/静态 CPU/内存 Manager | 与原地 resize 组合仍被禁止 |

---

## 八、从 1.29 到 1.35：你会一并获得的能力

你跨度了 **6 个小版本**（1.29 → 1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35）。除了 1.35 本身，这一路你还获得了：

> ⚠️ 重要前提：**kubeadm 管理的集群一次只能升级一个小版本**，不能从 1.29 直跳 1.35。必须逐级 `kubeadm upgrade`（控制平面 → 节点），每级完成后再进下一级。若你使用了某些托管发行版（EKS/CCE 等）的一键升级通道，则由平台负责此过程。

一路上成熟下来的关键能力：

- **DRA（异构设备）** —— 1.34 GA、1.35 锁定启用，替代 Device Plugin 的长期路线正式确立
- **Pod 级资源（Pod Level Resources）** —— 1.33/1.34 Beta，1.35 起支持其原地 resize（Alpha）
- **用户命名空间** —— 1.30 Beta → **1.36 GA**
- **镜像卷（image volume）** —— 1.31 Alpha → 1.33 Beta → **1.35 默认启用**
- **VolumeGroupSnapshot** —— 从 1.32 起的磁盘组快照能力（1.36 GA）
- **Gateway API 成熟** —— 与 Ingress NGINX 退役形成明确的迁移方向
- **原生 Sidecar 容器**（1.28 Beta）、**PSI 指标**（1.34 Beta → 1.36 GA）、**声明式校验（CEL）**（1.30 VAP GA，1.36 进一步 GA）等一整批能力

---

## 九、1.35 的核心优势总结

### 9.1 对**运维/SRE**

1. **节点维护不再断流** —— kubelet 重启不摘除健康 Pod（KEP-4781）
2. **调度性能** —— 机会式批处理默认开，大规模同构 Pod 调度显著加速
3. **状态可视性** —— `statusz`/`flagz` 结构化 JSON、`observedGeneration`、`terminatingReplicas`，不用再 grep 文本日志
4. **存储版本迁移** —— 内置控制器 + 标准化 API，告别手工 read/write 循环
5. **资源版本可比较** —— 控制器正确性的底层提升，你的自定义 operator 会更可靠
6. **卷挂接容量自愈** —— 减少 Pod 卡在 `ContainerCreating`

### 9.2 对**应用/业务**

1. **垂直扩缩容零中断** —— 有状态应用、批处理作业的 CPU/内存调整不再需要重建 Pod
2. **有状态应用更新提速最高 60%** —— StatefulSet `maxUnavailable`
3. **原生工作负载身份** —— Pod 证书 Beta，服务网格 / 零信任落地成本大降
4. **数据与镜像解耦** —— OCI 工件直接挂载为卷，分发 ML 模型、配置、二进制更干净
5. **弹性更精确** —— HPA 可按资源设容忍度，避免「涨 5% 不扩容」和振荡

### 9.3 对**安全**

1. **多租户隔离加固** —— 用户命名空间（容器内 root ≠ 主机 root）、缓存镜像凭据强校验、CSI 令牌不走 `volume_context`
2. **最小特权** —— 受限身份扮演（Alpha）
3. **原生 mTLS** —— 无需持有者令牌的纯双向 TLS 签发链路

### 9.4 对**AI/ML & 异构计算**

1. **Gang Scheduling（Alpha）** —— 彻底解决部分调度死锁，昂贵 GPU 容量不再被「跑不起来」的作业占着
2. **DRA 锁定启用** —— CEL 过滤、设备共享、集中化设备分类（成本型 / 性能型 DeviceClass）
3. **NUMA 上限解除** —— 高端 CPU / 加速卡服务器充分利用
4. **扩展资源兼容层** —— 老工作负载用 `nvidia.com/gpu` 写法即可平滑吃到 DRA 好处

### 9.5 对**CLI / 开发者**

1. **KYAML** —— 消除 YAML 类型转换陷阱
2. **WebSocket 替代 SPDY** —— `kubectl exec` / `port-forward` 更稳
3. **kuberc 凭据插件白名单** —— CI 流水线更可控

---

## 十、升级后行动检查清单

### P0 —— 必须立刻确认

- [ ] **cgroup v1 节点**：全量扫描 `kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.containerRuntimeVersion'`，确认无 v1 节点残留
- [ ] **kubelet 配置**：删除已移除的 `--pod-infra-container-image` flag
- [ ] **containerd 版本**：`kubelet_cri_losing_support` 指标 + 逐节点确认版本，规划 1.36 前完成 containerd 2.x 迁移
- [ ] **kube-proxy 模式**：若为 `ipvs`，制定 `nftables` 迁移计划（当前仅告警，不会中断）
- [ ] **StorageVersionMigration**：删除所有 `v1alpha1` 资源，确认使用 `v1beta1`
- [ ] **缓存镜像凭据强校验**（默认已开）：排查是否有 Pod 因缺少凭据而 `ImagePullBackOff`；必要时调整 `imagePullCredentialsVerificationPolicy`
- [ ] **runc / crun 版本**：升级到 runc 1.3.2+ / crun 1.23+，避免 cgroup v2 CPU weight 换算导致优先级异常
- [ ] **Ingress NGINX**：确认是否使用；若是，启动 Gateway API 迁移评估（2026-03 后无安全补丁）

### P1 —— 稳定性与性能收益

- [ ] 验证 `PreferClose` → `PreferSameZone` 的行为一致性
- [ ] 检查基于标签的策略 / 配额 / NetworkPolicy 是否受新增 Pod 拓扑标签影响
- [ ] StatefulSet 评估配置 `maxUnavailable`（配合 `podManagementPolicy: Parallel`）
- [ ] 观察 kube-scheduler 的 `OpportunisticBatching` 效果与相关指标
- [ ] 检查 `volume_context` 中是否仍有 SA 令牌，评估开启 `serviceAccountTokenInSecrets`

### P2 —— 长期规划

- [ ] Gang Scheduling / Workload API 概念验证（AI/ML、HPC 场景收益最大）
- [ ] Pod 证书（Beta）用于服务网格 mTLS 的可行性验证
- [ ] 受限身份扮演（Alpha）替换现有多用途高权 impersonate 账号
- [ ] 评估是否直接跟进 1.36 / 1.37（1.35 将于 2027 年初 EOL）

---

## 十一、参考链接

**官方一手资料**
- 发布博客：https://kubernetes.io/blog/2025/12/17/kubernetes-v1-35-release/
- 版本主页：https://kubernetes.io/releases/1.35/
- 完整 CHANGELOG：https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.35.md
- Sneak Peek（弃用预告）：https://kubernetes.io/blog/2025/11/26/kubernetes-v1-35-sneak-peek/
- Release Highlights 讨论：https://github.com/kubernetes/sig-release/discussions/2903
- 升级指南：https://v1-35.kubernetes.ac.cn/docs/tasks/administer-cluster/cluster-upgrade/

**专题博客**
- 原地 Pod Resize GA：https://kubernetes.io/blog/2025/12/19/kubernetes-v1-35-in-place-pod-resize-ga/
- 工作负载感知调度：https://kubernetes.io/blog/2025/12/29/kubernetes-v1-35-introducing-workload-aware-scheduling/
- 容器重启规则：https://kubernetes.io/blog/2026/01/05/kubernetes-v1-35-restart-all-containers/
- 数值容忍度运算符：https://kubernetes.io/blog/2026/01/05/kubernetes-v1-35-numeric-toleration-operators/
- CSI SA 令牌安全传递：https://kubernetes.io/blog/2026/01/07/kubernetes-v1-35-csi-sa-tokens-secrets-field-beta/
- CCM Watch 式路由调谐：https://kubernetes.io/blog/2025/12/30/kubernetes-v1-35-watch-based-route-reconciliation-in-ccm/
- Job managedBy GA：https://kubernetes.io/blog/2025/12/18/kubernetes-v1-35-job-managedby-for-jobs-goes-ga/
- Ingress NGINX 退役：https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
- cgroup v1→v2 CPU 换算：https://kubernetes.io/blog/2026/01/30/new-cgroup-v1-to-v2-cpu-conversion-formula/

**KEP 索引**
`kep.k8s.io/1287`（原地 resize）、`4317`（Pod 证书）、`5328`（节点声明特性）、`3015`（流量分布）、`4368`（Job managedBy）、`5067`（Pod Generation）、`4622`（NUMA 上限）、`4006`（WebSocket）、`961`（StatefulSet maxUnavailable）、`4742`（拓扑 Downward API）、`4192`（存储版本迁移）、`4876`（卷挂接上限）、`5598`（机会式批处理）、`3104`（kuberc）、`5295`（KYAML）、`4951`（HPA 容忍度）、`127`（用户命名空间）、`4639`（OCI 卷）、`2535`（镜像凭据校验）、`5307`（容器重启规则）、`5538`（CSI SA 令牌）、`3973`（terminatingReplicas）、`4671`（Gang Scheduling）、`5284`（受限身份扮演）、`4828`/`4827`（flagz/statusz）、`5237`（CCM 路由）、`5471`（数值容忍度）、`5440`（挂起 Job 资源）、`5504`（资源版本）、`5573`（移除 cgroup v1）、`5495`（弃用 ipvs）、`4033`（containerd 1.x）、`4781`（kubelet 重启稳定性）、`5726`（大规模 NUMA 性能）

---

*文档基于 Kubernetes v1.35 官方发布博客、发布说明与 KEP 整理。特性成熟度以你集群中实际的 Feature Gate 与 API 版本为准。*
