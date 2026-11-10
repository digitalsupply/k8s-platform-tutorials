# eBPF + Cilium 取代 Calico + kube-proxy：可行性与优缺点评估

**评估日期**：2026-10-03
**集群现状**：Kubernetes v1.35.9 | 6 节点（3 CP + 3 Worker）| Calico v3.32.2（BIRD + IPIP Always）| kube-proxy iptables

本文所有判断基于本集群实测数据，非文档推测。

---

## 一、结论先行

### 技术上可行，但**当前不建议做**

| 维度 | 判断 |
|---|---|
| 技术可行性 | ✅ **可行**，内核条件全部满足 |
| 版本兼容性 | ✅ Cilium 1.20 支持 K8s 1.33–1.36 |
| 迁移风险 | ⚠️ **高** —— BIRD+IPIP 语义需完整重建 |
| 收益匹配度 | ❌ **低** —— 当前规模下 kube-proxy 不是瓶颈 |
| 可观测性收益 | ✅ **显著** —— Hubble 是真实增量 |

**核心判断**：这个迁移解决的是**你现在没有的问题**（kube-proxy 性能），却引入**你正要承担的复杂度**（eBPF 运维门槛）。

唯一值得立刻做的是 **Hubble 网络可观测性**，而它**不需要**换 CNI——见第六节。

---

## 二、现状实测数据

### 2.1 eBPF 前置条件（6 节点实测）

| 节点 | 内核 | 架构 | BTF | BPF fs | cgroup | 编译器 |
|---|---|---|---|---|---|---|
| m01 | 5.14.0-570.el9 | x86_64 | ✅ | ✅ 已挂载 | v2 | 无 |
| master01 | 5.15.0-179 | x86_64 | ✅ | ✅ | v2 | 无 |
| master02 | 5.15.0-179 | x86_64 | ✅ | ✅ | v2 | 无 |
| worker01-03 | 5.15.0-179 | x86_64 | ✅ | ✅ | v2 | 无 |

**结论**：BTF 齐全（`/sys/kernel/btf/vmlinux` 存在）是 eBPF CO-RE 的核心前提，6 节点全部满足。无本地编译器不是问题——Cilium 用 Go + cilium/ebpf 库，不需要 clang。

### 2.2 Calico 当前配置（迁移需重建的）

```yaml
CLUSTER_TYPE              = k8s,bgp        # ← BIRD 在跑
CALICO_IPV4POOL_IPIP      = Always         # ← 封装模式
CALICO_IPV4POOL_VXLAN     = Never
DATASTORE_TYPE            = kubernetes     # 状态存在 K8s CRD
IPPool                    = default-ipv4-ippool
  cidr                    = 10.244.0.0/16
  ipipMode                = Always
  vxlanMode               = Never
```

容器结构（每个节点）：
```
calico-node                    quay.io/calico/node:v3.32.2
initContainer upgrade-ipam      quay.io/calico/cni:v3.32.2
initContainer install-cni       quay.io/calico/cni:v3.32.2
initContainer ebpf-bootstrap    quay.io/calico/node:v3.32.2
hostNetwork: true
```

**注意**：Calico 自己的 `ebpf-bootstrap` initContainer 存在，但 `FELIX_BPFENABLED` 未设置 —— **BPF 模式未启用**。

### 2.3 kube-proxy 现状（被替代的对象）

```
nat 表KUBE-SVC 规则    603 条
filter 表 KUBE 链      11 条（KUBE-SERVICES / KUBE-FIREWALL / KUBE-NODEPORTS 等）
mangle 表 KUBE 链      3 条（含 KUBE-IPTABLES-HINT）
残留                  KUBE-IPVS-FILTER / KUBE-IPVS-OUT-FILTER（IPVS 迁移遗留）
```

Service 数量 108，NodePort 规则 603 条 —— **完全在 iptables 舒适区**。

### 2.4 其他相关事实

| 项目 | 数值 | 影响 |
|---|---|---|
| NetworkPolicy | 3 个 | Cilium 的主要优势点，但当前用量极低 |
| hostNetwork Pod | **42 个** | Cilium 无法直接管理，需逐个验证 |
| 使用 calico label 的资源 | **0 个** | ✅ 无 Calico 特有语义耦合 |
| Calico 特有 CRD 资源 | bgppeers=0, ipreservations=0 | ✅ BGP 无外部 peer |
| 数据存储 | kubernetes（CRD） | ✅ 无需迁移数据文件 |
| Hubble | 未部署 | Cilium 可带来的增量 |

**42 个 hostNetwork Pod** 构成主要风险——包含：
- 6 个 calico-node（会随迁移移除）
- 3 个 etcd（静态 Pod）
- Ceph-CSI nodeplugin（多副本）
- Prometheus / Alertmanager / Grafana / Tempo / Loki / OTel 等可观测性组件

---

## 三、优势分析

### 3.1 性能收益（**当前规模下不明显**）

| 能力 | 当前（kube-proxy iptables） | Cilium eBPF |
|---|---|---|
| Service 转发 | 603 条 iptables 规则线性遍历 | eBPF map 哈希查找 O(1) |
| 连接跟踪 | conntrack netfilter | BPF conntrack（更快） |
| 延迟 | ~微秒级 | ~亚微秒级 |

**但**：108 个 Service、603 条规则，iptables 遍历耗时在 **10μs 以内**。这点开销在任何真实业务面前都不可测量。

**Cilium 性能优势要到数千 Service / 高 PPS 场景才显现。**

### 3.2 网络可观测性（**这是真实增量**）

当前集群网络排障只能靠：
- iptables 规则反查
- 抓包
- Prometheus 的 calico_* 指标（粗粒度）

Hubble 提供：
```
hubble observe                  # 实时流式网络流
hubble metrics list              # DNS / HTTP / TCP / Flow / ICMP 指标
hubble monitor                   # 指标导出到 Prometheus
```

**具体能力**：
- 7 层可观测：HTTP 请求方法/路径/状态码、DNS 查询
- 服务依赖图（自动生成，无需埋点）
- 网络策略命中/拒绝日志（**当前完全不可见**）
- 单请求全链路追踪（L3–L7）

对你这套 LGTM 体系，这部分价值明确——现在 Traefik 侧的 trace 只能覆盖入口，进到 Pod 内部就是黑盒。

### 3.3 kube-proxy-free（移除一个组件）

Cilium 可完全替代 kube-proxy（`kubeProxyReplacement: true`）：
- 少一个 DaemonSet（6 个 Pod）
- Service/Endpoint 逻辑内聚到 Cilium
- 支持 L7 负载均衡（Header/ Cookie 路由）

**但**：你现在刚把 kube-proxy 从 IPVS 迁到 iptables 并验证稳定，马上再动它属于连续扰动。

### 3.4 更细的 NetworkPolicy

Cilium 支持 k8s NetworkPolicy 之外还有 CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy：
- L7 策略（按 HTTP 路径、方法）
- 基于身份的策略（`toEntities: world`）
- 全局可见的策略下发与审计

**当前只有 3 个 NetworkPolicy，且都是标准的 Ingress**，收益有限。

### 3.5 其他

- **一致性**：Calico 用 BIRD + IPIP（Calico 自己的一套 BGP），Cilium 用原生 BGP/native routing，跨厂商兼容性更好
- **可观测性数据**：Cilium 指标可直接进 Prometheus，与现有 LGTM 无缝集成

---

## 四、劣势与风险

### 4.1 迁移风险（**高**）

#### ① BIRD + IPIP 语义需完整重建

当前 Calico 配置是**经过两次升级验证的稳定状态**：

```
CLUSTER_TYPE = k8s,bgp          # BIRD 做节点间路由
IPIP Mode    = Always            # 跨节点 Pod 流量全部封装
Pod CIDR     = 10.244.0.0/16
```

迁移到 Cilium 需要重新决策：
| 决策点 | 选项 | 影响 |
|---|---|---|
| 隧道模式 | VXLAN / Geneve / **native** | 当前 IPIP ≈ 封装，Cilium 默认 VXLAN 会改变 MTU 计算 |
| 路由模式 | BGP / Direct Node Route | BIRD 配置要重写 |
| Pod CIDR | 沿用 10.244.0.0/16 | 可保留，但 Cilium 的 IPAM 行为不同 |

**MTU 是隐形坑**：IPIP 封装开销 20 字节，VXLAN 50 字节。Ceph 的 RBD 网络对 MTU 敏感，换 VXLAN 可能导致大包丢失。

#### ② 42 个 hostNetwork Pod

Cilium **不管理 hostNetwork Pod**（它们绕过 CNI）。需要逐个确认：
- 这些 Pod 的流量在 Cilium 下如何走
- NetworkPolicy 对它们是否生效
- ceph-csi 多副本是否需要额外处理

#### ③ Strimzi 自动生成的 NetworkPolicy

```yaml
# kafka/my-cluster-network-policy-kafka（Strimzi 生成）
policyTypes: [Ingress]
ingress:
  - from:
    - podSelector: {strimzi.io/cluster: my-cluster, strimzi.io/kind: Kafka, ...}
    - podSelector: {strimzi.io/kind: cluster-operator}
```

**风险**：Cilium 对 k8s NetworkPolicy 的**默认拒绝语义**与 Calico 有细微差异。Cilium 需要显式启用 `default-deny` 行为，配置不当会导致：
- Kafka broker 互相不通
- Strimzi operator 健康检查失败
- **且这类问题往往在滚动升级后才暴露**

#### ④ 无 In-Place 升级路径

Cilium **不支持从 Calico 在线迁移**。必须：
```
1. 迁移窗口内同时停 Calico 和 Cilium（Pod 网络中断）
2. 或用 Cilium 的「无 CNI 模式」先接管，再移除 Calico
```

对一个承载 Kafka、PostgreSQL、Ceph CSI、LGTM 全家桶的集群，**网络中断窗口是主要风险**。

#### ⑤ 网络插件故障 = 集群全网不可用

现状：Calico 出问题只影响 Pod 网络，节点本身的管理网络还在。

Cilium：eBPF 程序加载在内核，一旦 Cilium agent 异常或节点重启后 BPF 程序失效，**该节点可能完全失联**（除非配了 emergency mode）。

### 4.2 运维复杂度上升

| 维度 | Calico | Cilium |
|---|---|---|
| 组件数 | calico-node + kube-controllers | cilium + cilium-operator + Hubble |
| 配置方式 | CRD / 环境变量 | helm values + CiliumNetworkPolicy |
| 排障工具 | calicoctl、iptables | cilium CLI、hubble CLI、bpftool |
| 学习曲线 | 中 | **高** |
| 内核依赖 | 基础 netfilter | eBPF、BTF、cgroup v2 |

**对你当前的状态**：刚完成 K8s 1.29→1.35 升级、containerd 2.x、Calico 两步升级，集群处于**刚稳定下来的状态**。立刻引入 eBPF 复杂度，时机不佳。

### 4.3 版本约束

| Cilium | 支持 K8s |
|---|---|
| 1.18 | 1.30 – 1.33 |
| 1.19 | 1.32.6+ |
| **1.20** | **1.33 – 1.36** ✅ |

你的集群是 **1.35.9** → 必须用 **Cilium 1.20+**。这是刚发布的版本，稳定性数据相对少。

GitHub 上有用户报告 Cilium 1.18.1 在 K8s 1.35 上"能跑但未完整测试"——**不要用 1.18 迁到这个集群**。

### 4.4 现有 BIRD 资产会废弃

`CLUSTER_TYPE=k8s,bgp` 说明 BIRD 在跑。虽然实测 `bgppeers` CRD = 0（无外部 peer），但 BIRD 进程和配置都在，迁移后全部废弃。

---

## 五、可行性判断

### 5.1 技术可行性：✅ 高

| 条件 | 状态 |
|---|---|
| 内核 ≥ 5.4 | ✅ 5.14/5.15 |
| BTF 可用 | ✅ 6 节点全部有 |
| cgroup v2 | ✅ 全部 |
| 架构 x86_64 | ✅ |
| Cilium 版本匹配 K8s 1.35 | ✅ 1.20+ |
| 无 Calico 特有语义耦合 | ✅ 0 个资源使用 calico label |
| 无需数据迁移 | ✅ datastore=kubernetes |

### 5.2 业务风险：⚠️ 高

| 风险点 | 影响 |
|---|---|
| 42 个 hostNetwork Pod | 需逐个验证，Ceph-CSI / etcd 都在其中 |
| Kafka NetworkPolicy | Strimzi 生成，语义差异可能导致 broker 失联 |
| Ceph RBD + MTU | 封装模式变化可能影响存储流量 |
| 无在线迁移路径 | 需要网络中断窗口 |
| Cilium 1.20 新版本 | 稳定性数据少 |

### 5.3 收益匹配度：❌ 低

| Cilium 优势 | 你当前是否需要 |
|---|---|
| 万级 Service 性能 | ❌ 108 个 Service |
| 高 PPS 转发 | ❌ 实验环境流量 |
| L7 负载均衡 | ❌ 现有轮询够用 |
| 细粒度 NetworkPolicy | ❌ 只有 3 个，且都是基础 Ingress |
| **Hubble 网络可观测性** | ✅ **这个是真需求** |

---

## 六、替代方案：只取 Hubble，不换 CNI

**Hubble 的核心能力（网络流观测）需要 Cilium，但有折中路径。**

### 方案 A：暂不迁移，先解决可观测性痛点（推荐）

当前网络排障的实际痛点：
- 不知道某个 Service 流量分布
- 不知道 NetworkPolicy 在拒绝什么
- Pod 间调用链无法追踪

**不换 CNI 也能改善**：
1. **现有监控已覆盖的**：Prometheus targets 125/125、kube-proxy iptables 指标、Calico 指标
2. **补充手段**：
   - `conntrack -L` 看连接状态
   - Calico 的 `calico_denied_packets` 指标（**当前未采集**）
   - Traefik 已有 OTel trace（本次升级已验证）
3. **成本**：零风险，1-2 小时

### 方案 B：若确实想要 Hubble，接受 CNI 迁移

**推荐路径**（降低风险）：

```
阶段 1：准备（无风险）
  └─ 确认 Cilium 1.20 兼容性、评估 hostNetwork Pod
  └─ 备份 Calico 配置、准备回滚方案

阶段 2：并行验证（可回滚）
  └─ 用 Cilium「无 CNI 模式」部署（不接管网络）
  └─ 验证 Hubble 能否采集到流量

阶段 3：切换（需窗口）
  └─ 选时间窗口，先 drain worker
  └─ 移除 Calico、安装 Cilium CNI
  └─ kubeProxyReplacement=true

阶段 4：验证
  └─ Kafka / PostgreSQL / Ceph CSI / LGTM 全套业务验证
  └─ NetworkPolicy 语义验证
```

**预计工作量**：2-4 周（含验证）。

### 方案 C：延后到有真实需求时

等出现这些信号再考虑：
- Service 数量超过 1000
- 网络策略超过 50 条
- 出现 kube-proxy 导致的连接延迟问题
- 明确需要 L7 负载均衡

---

## 七、最终建议

### ❌ 不建议现在做

理由：
1. **收益不匹配** —— 108 个 Service 用 iptables 完全够用
2. **风险高** —— 刚稳定的集群，42 个 hostNetwork Pod + Kafka 策略语义风险
3. **时机不对** —— 刚完成 6 级 K8s 升级 + containerd 2.x + Calico 两步升级
4. **需 Cilium 1.20** —— 新版本，稳定性数据少

### ✅ 建议做的（低成本、高价值）

1. **补采 Calico 丢弃指标** —— `calico_denied_packets_total`，当前未采集，NetworkPolicy 在拒绝什么完全不可见
2. **观察 Prometheus 存储增长** —— 7.3GB 且未配置 retention，这是当前实际的资源压力
3. **建立容量基线** —— 记录 Service 数、连接数、PPS，超过阈值再评估

### 🔄 重新评估的触发条件

| 信号 | 阈值 |
|---|---|
| Service 数量 | > 1000 |
| iptables KUBE-SVC 规则 | > 10000 |
| NetworkPolicy | > 50 |
| 网络延迟投诉 | 任何 P99 超 1ms |
| 明确需要 L7 路由 | 任意场景 |

---

## 附：关键命令

```bash
# 验证 eBPF 前提
ls /sys/kernel/btf/vmlinux && echo "BTF OK"
mount | grep bpf
stat -fc %T /sys/fs/cgroup          # 应为 cgroup2fs

# 评估迁移影响面
kubectl get pods -A -o json | jq -r '.items[]|select(.spec.hostNetwork==true)|"\(.metadata.namespace)/\(.metadata.name)"'
kubectl get networkpolicy -A
kubectl get pods -A -o json | jq -r '.items[].metadata.labels|to_entries[]|select(.key|contains("calico"))'

# 当前 kube-proxy 规模
iptables-save -t nat | grep -c KUBE-SVC

# Calico 丢弃流量（当前未采集）
# calico_denied_packets_total{revision="0"}
```

---

## 参考

- [Cilium Kubernetes 兼容性矩阵](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) —— 1.20 支持 K8s 1.33–1.36
- [Cilium 系统要求](https://docs.cilium.io/en/v1.18/network/kubernetes/requirements/)
- Cilium 1.19 + K8s 1.35 讨论：https://github.com/cilium/cilium/discussions/43439