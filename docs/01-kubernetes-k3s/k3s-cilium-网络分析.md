# k3s + Cilium 网络段与关联机制详解

> 环境事实：k3s v1.36.4+k3s1（3 节点）+ Cilium v1.20.1（Helm，kubeProxyReplacement=true，routing-mode=tunnel/VXLAN，IPAM=cluster-pool）。无 kube-proxy，无 flannel。

## 0. 结论速览

| 问题 | 答案 |
|---|---|
| 实际 Pod 网段 | **10.0.0.0/8**（每节点 /24），Cilium IPAM 自动分配 |
| Service 网段 | **10.43.0.0/16**（k3s 内置默认值，apiserver 负责发号） |
| k3s 的 10.42.0.0/16 用了吗？ | 只在 `node.spec.podCIDR` 上登记，因 `--flannel-backend=none` **没被使用** |
| Pod 网段与 SVC 网段怎么"关联"？ | 不在"分配"环节关联，而在**数据面**：ClusctIP 是虚拟 VIP，靠数据面 NAT/LB 规则把 `10.43.x.x` 翻译成真实 Pod IP `10.0.x.x` |
| 关联靠哪些组件？ | Cilium 场景：kube-apiserver（发 ClusterIP）+ Cilium agent（eBPF LB + IPAM + 跨节点 VXLAN） |
| Calico 场景机制 | kube-controller-manager 发 PodCIDR，calico-ipam 消费；**kube-proxy iptables** 做 svc→pod 的 DNAT，**Calico** 做 pod→pod 的路由/封装，两套组件分工合作 |

一句话：**"发号"是分配器的事，"关联"是转发平面的 NAT/LB 规则的事**。Pod 网段和 SvC 网段本质是两套不相干的地址池，靠数据面把它们桥接起来。

---

## 1. 两套网段各自的"发号机构"

### 1.1 Pod 网段（Cluster CIDR）

| 环境 | 谁来切 `/24` 给节点 | 写在哪个字段 | 谁消费它 |
|---|---|---|---|
| 原生 k8s | kube-controller-manager（`--cluster-cidr` + `--allocate-node-cidrs`） | `node.spec.podCIDR` | CNI |
| k3s（本环境） | k3s supervisor 自己切（默认 `10.42.0.0/16`，每节点 /24） | `node.spec.podCIDR` | 本应是 flannel / 但 flannel=none 后是 Cilium |
| 本环境 Cilium | **彻低绕开** `node.spec.podCIDR`，用自己 IPAM `cluster-pool`（`10.0.0.0/8`，每节点 /24） | 写在 Cilium 自己内部 & `cilium-config` | Cilium agent |

实测分配结果（Cilium 内部记录 + 实际 Pod IP）：

```
ubuntu01 → 10.0.0.0/24   （CiliumInternalIP 10.0.0.37；coredns=10.0.0.4）
ubuntu02 → 10.0.1.0/24   （CiliumInternalIP 10.0.1.33；lab/api=10.0.1.137）
ubuntu03 → 10.0.2.0/24   （CiliumInternalIP 10.0.2.70；nginx=10.0.2.93）
```

> 注意 k3s 的 `node.spec.podCIDR` 是 10.42.0/10.42.1/10.42.3，与真实 Pod IP（10.0.x.x）**完全对不上**。这是 flannel-backend=none 下的正常现象：CNI 不认 k8s 的 PodCIDR 字段。

### 1.2 Service 网段（ClusterIP Range）

- 由 **kube-apiserver 内部的 ServiceClusterIPAllocator（range 分配器）** 从 `--service-cluster-ip-range` 里逐个发 ClusterIP。
- k3s 没配该参数 → 用编译默认 **10.43.0.0/16**。实测：`kubernetes=10.43.0.1`、`kube-dns=10.43.0.10`、`nginx=10.43.66.133`、`lab/api=10.43.174.55`。
- 分配的"数字"与 Pod 网段**无任何运算关系**——它只是保证：所有 Service IP 在这个池子里，且不与 Pod 网段重叠。

> 关键前提：**k8s 要求 Pod 网段与 Service 网段终身不重叠**，否则路由/查表会产生歧义。本环境三者（10.42 未用、10.43 svc、10.0 pod）互不重叠，正好满足。

---

## 2. 网段之间的"关联点"到底在哪？

> 核心：**ClusterIP 是虚拟 IP，不挂在任何一台机器的网卡上**。`10.43.x.x` 的数据包一旦进入某个节点，节点的数据面必须把它"翻译"成某个真实后端 Pod IP（`10.0.x.x`），这个"翻译规则"就是 Pod 段与 Svc 段唯一的、真正的关联。
>
> 这个关联 = **Service 的 VIP→Backend 映射表（LB 规则）**。谁来做这个表、用什么技术实现，就区分了各 CNI 方案。

### 参与链路的所有组件（通用清单）

| 组件 | 作用 | 本环境是否存在 |
|---|---|---|
| kube-controller-manager | 分配 node podCIDR / 维护 endpoints | 内嵌于 k3s server |
| kube-apiserver | 分配 Service ClusterIP、下发 SVC/Endpoints 事件 | ✅ k3s 内嵌 |
| kubelet | 调 CNI 建 pod 网络、写 pod 状态 IP | ✅ |
| CNI 插件 | 分配 Pod IP、建 veth/路由/封装 | Cilium（Calico 场景则为 calico） |
| kube-proxy | 监听 Service+Endpoints，写 iptables/ipvs 的 svc→pod DNAT 规则 | ❌（被 Cilium KPR 替代） |
| CNI 内置 LB | 用 eBPF/BPF map 直接做 svc→pod 负载均衡 | ✅ 只有 Cilium 有 |
| CoreDNS | Service 名 → ClusterIP 的解析 | ✅ 10.43.0.10 |

---

## 3. 本环境（k3s + Cilium）机制：eBPF 一体式

### 3.1 关键配置证据

```
# k3s.service 实际只有：
--flannel-backend=none --disable-kube-proxy --disable-network-policy --write-kubeconfig-mode 644
# 无 --cluster-cidr / --service-cidr

# cilium-config 关键项：
ipam: cluster-pool
cluster-pool-ipv4-cidr: 10.0.0.0/8
cluster-pool-ipv4-mask-size: "24"
routing-mode: tunnel
tunnel-protocol: vxlan
kube-proxy-replacement: "true"
kube-proxy-replacement(healthz): ""   # 完全替换，连 fallback 都不开
enable-ipv4-masquerade: "true"
```

### 3.2 实测：eBPF 里的 svc→pod 映射表（这就是"关联"本体）

在 cilium-agent 里查询 `cilium bpf lb list`，直接看到四个事实：

```
10.43.0.10:53/UDP (1)   10.0.0.4:53/UDP   ← kube-dns VIP → coredns Pod IP
10.43.0.10:53/TCP (1)   10.0.0.4:53/TCP
10.43.66.133:80/TCP (1) 10.0.2.93:80/TCP  ← nginx SVC → nginx Pod(ubuntu03)
10.43.174.55:80/TCP (1) 10.0.1.137:80/TCP ← lab/api SVC → api Pod(ubuntu02)
```

**Pod 网段（10.0.0.0/8）与 Svc 网段（10.43.0.0/16）的关联，就实打实地存在这张 BPF LB map 里**：key 是 `服务VIP:port`，value 是 `后端PodIP:port`。

### 3.3 一次完整请求的七步（以内网 curl 到 nginx 为例）

前提：`curl` Pod = 10.0.1.93（ubuntu02），nginx Service = 10.43.66.133:80，后端 nginx Pod = 10.0.2.93（ubuntu03）。

```
1. DNS       curl 容器内解析 "nginx.default" → CoreDNS(10.43.0.10) → 返回 A 记录 10.43.66.133
2. 发包      curl 发 SYN，dst=10.43.66.133:80，src=10.0.1.93（Pod IP）
3. 出 pod    packet 从 veth(bpf lxc) 出 → 到宿主机 datapath（TC hook）
4. eBPF 查表 TCP-INGRESS 上查 lb4_services_v2：
            key(10.43.66.133:80) → 命中 backend 10.0.2.93:80，原 dst 被改写
            同时把 10.43.66.133 记录为 "rev-NAT 源地址"
5. 跨节点   routing-mode=tunnel → 包封装进 VXLAN，外层 dst=192.168.67.203(ubuntu03)
6. 到目标   目标节点 cilium_vxlan 收包、解封，按 10.0.2.93 命中 cilium_host，
            从 veth 灌进 nginx Pod
7. 回包     nginx 应答 src=10.0.2.93 → 反向路径再经 rev-NAT 改回 src=10.43.66.133
            curl 全程只看到服务 VIP，完全感知不到 Pod IP
```

> 精髓（要分清"控制面/数据面"）：
> - **数据面（每包转发）**：NAT（查 `lb4_services_v2` 换后端）和 Pod 路由（查 `endpoint map`/`tunnel map` 决定本地投递还是 VXLAN 封装）**都在 eBPF 里跑**——它们挂在对端 veth / cilium_host / cilium_vxlan 的 TC hook 上，Pod 间的包不经过内核 IP 路由（本环境 `Host: Legacy` 仅指宿主机自身流量走传统栈）。
> - **控制面（写规则的人）**：cilium-agent 一个进程负责建模——算好每张 BPF map 的值、把 BPF 程序安装到钩子上，但**它不碰包**。
> - 即：**agent 管控制面、一套 BPF 管数据面，NAT 与 Pod 转发两个功能都长在 BPF 里**，单体耦合。
> - 这是与 Calico 的底层哲学差异：Calico 数据面默认还给内核，见第 4 节。

---

## 4. k8s + Calico 机制：两套组件分工

### 4.1 组件结构与"谁负责什么"

| 职能 | 负责组件 | 实现 |
|---|---|---|
| 分配 PodCIDR（/24 给节点） | kube-controller-manager（`--cluster-cidr`） | 写 `node.spec.podCIDR` |
| 消费 PodCIDR / 实现 Pod 互访 | Calico（calico-ipam / host-local + Felix/BIRD） | 每节点一个 block；Felix 写路由规则 |
| 分配 Service ClusterIP | kube-apiserver（`--service-cluster-ip-range`） | 池子默认 10.96.0.0/12（vanilla k8s） |
| 做 svc→pod 的 DNAT | **kube-proxy（默认 iptables 模式）** | KUBE-SERVICES→KUBE-SVC-xx→KUBE-SEP-xx→DNAT |
| 跨节点转发 Pod 流量 | Calico | BGP（默认）或 IPIP/VXLAN 封装 |

核心区别一句话：
- **Calico 世界里，Service 的关联依托 kube-proxy 的 iptables；Calico 只管 Pod 到 Pod 的路由。两个独立组件、两套规则表。**
- **Calico 的"数据面默认不归自己管"**：它把转发规则写进内核——Felix 写 Linux 路由表（FIB）/ IPIP 或 VXLAN tunnel 设备、kube-proxy 写 iptables（netfilter）——此后**每包转发由内核自己完成（ip_forward 路由查找 + netfilter DNAT），Calico/kube-proxy 的代码不再碰包**；它们只是控制面（算路由、发布 BGP、维护 iptables 规则）。
- 想要 Calico 也接管数据面 → 需显式开 `eBPF datapath`，此时与 Cilium 同构（BPF 里同时做转发和 svc NAT）。

### 4.2 一次完整请求（Calico 版）

```
1. DNS       同前，svc 名 → ClusterIP（ number')
2. 发包      curl Pod(10.42.0.5) → dst=10.43.x.x:80（ClusterIP 是本地可路由的？）
            关键：kube-proxy 在每台机器用 ip rule/route 把 10.43.0.0/16 引到本机 lo
3. 本地 NAT  packet 进 INPUT → PREROUTING 的 KUBE-SERVICES 链：
            匹配 -d 10.43.x.x --dport 80 → KUBE-SVC-xxx → 随机挑 backend
            → KUBE-SEP-xxx 执行 DNAT --to-destination 10.42.1.50:80
4. 重新路由  dst 已被改写成 Pod IP 10.42.1.50，走 output/postrouting，
            进入 Felix 维护的 Linux 路由表（查 OVS 路由 / IPIP tunnel 表）
5. 跨节点    若开启 IPIP → src 10.42.0.5 包装进 IPIP(tunnel0)，dst 外层=节点2 IP；
            若纯 BGP → 直接经物理机路由下一跳转发（不封装）
6. 目标      节点2 收包、解封，查 Felix 路由 → 从 veth 送进 Pod(10.42.1.50)
7. 回包      conntrack 反向还原 src=svc VIP
```

### 4.3 Calico 的 IPAM 两种姿势（讲透）

| 方式 | 如何取 Pod 网段 | 适用 |
|---|---|---|
| `ipam: kubernetes`（host-local） | 直接吃 `node.spec.podCIDR`（controller-manager 发的 10.42.x/24），**与 k8s 官方字段完全一致、不浪费** | vanilla k8s + flannel 出身的团队最熟 |
| `ipam: calico-ipam`（默认 bundle） | 从 Calico **IPPool**（安装时手工指定，通常与 `--cluster-cidr` 对齐）分配 | 需 BGP/精细 block 控制的场景 |

> Calico 里 **"k8s 的 cluster-cidr 就是真实 Pod 段"**——因为要么 IPPool 直接对齐它，要么 host-local 直接消费它。这是与 Cilium（独立池）最大的手感差异。

---

## 5. 两轴对比表（把"关联机制"这一关键维度单列）

| 维度 | 本环境 k3s+Cilium | vanilla k8s+Calico（iptables） | vanilla k8s+Calico（eBPF 可选） |
|---|---|---|---|
| 真实 Pod 网段来源 | Cilium 自己 `cluster-pool`（10.0.0.0/8，绕过 node.podCIDR） | k8s `--cluster-cidr` → node.podCIDR（10.42.x/24） | 同左 |
| node.podCIDR 是否有用 | 没用（登记 10.42 但被忽略） | 有用，是唯一真相 | 同左 |
| svc→pod 关联组件 | Cilium agent eBPF（BPF LB map） | kube-proxy iptables（DNAT） | Calico eBPF datapath |
| pod→pod 转发组件 | Cilium agent（VXLAN tunnel） | Calico Felix+BIRD（BGP/IPIP/VXLAN） | Calico eBPF |
| 规则表载体 | BPF map（lb4_services_v2 / backend / rev-nat） | iptables 链 + conntrack | BPF map |
| 关联的"耦合度" | 单体：一个 agent 一套哈希表 | 分离：iptables 决策 + 路由表 forwarded 两套 | 单体（与 Cilium 同哲学） |
| 能否省掉 kube-proxy | 能（本环境正是，k3s 都 disable 了） | 默认不行，得开 eBPF | 能（eBPF 时） |
| 拆网络排障入口 | `cilium bpf lb list` / `cilium monitor` | `iptables -t nat -L` / `ip route` | `calicoctl` + BPF |
| 最典型"平台坑" | 记得 pod 池与 svc 段不重叠；别被 node.podCIDR=10.42 的假象带偏 | 改 cluster-cidr 时需同步 IPPool/CNI 配置，双份真相易漂移 | 同左 |

---

## 6. 关键结论与注意点

1. **两段网"各自独立发号、数据面汇合"**：Pod IP 由 CNI/controller-manager 从 Pod 段发，Svc IP 由 apiserver 从 Svc 段发，两者在数值上毫无耦合；真正把它们绑在一起的是"服务 VIP→后端 Pod IP"的 NAT/LB 规则——Cilium 在 BPF map 里，Calico+kube-proxy 在 iptables 里。
2. **本环境 Pod 段是 Cilium 自动默认值（10.0.0.0/8）、Svc 段是 k3s 默认值（10.43.0.0/16）**，安装时从未指定 CIDR。
3. **Cilium 完全替代 kube-proxy**（本集群 k3s 直接 `--disable-kube-proxy`），svc 关联进 eBPF，成熟、低延迟；Calico 默认仍需 kube-proxy，两者各自为政。
4. 排障时的第一认知差异：**环境里看到 10.0.x.x 是 Pod 的"真实身份证"，10.43.x.x 是"服务的门牌"，10.42.x.x 只是 k3s 登记的、实际不用的号码**——别对着 10.42 调路由。

---

## 7. 附：性能差异的本质辨析（澄清"上下文切换"误区）

### 7.1 一个常见误解

> "Calico 数据面默认走内核 → 大规模集群有大量用户态/内核态上下文切换；eBPF 全在内核 → 更快。"

**这个说法是错的。** netfilter（iptables）本身就在内核，转发全程跑在内核软中断/进程上下文，**并不存在每包的用户态切换**。有"用户态数据面 + 上下文切换"的是 DPDK/OVS-DPDK 这类方案。真正该对比的不是"谁在内核"，而是"在内核里用什么模型决策"。

### 7.2 真正的根本区别：决策模型（不是切换次数）

| | Calico 默认(iptables/kube-proxy) | Cilium(eBPF) |
|---|---|---|
| 服务转发决策 | **线性链遍历**：每个包串行走 PREROUTING→FORWARD→POSTROUTING，逐条匹配 KUBE-SERVICES/KUBE-SVC-xx/KUBE-SEP-xx | **O(1) hash 查找**：TC/XDP 里一张 `lb4_services_v2` map 查完即定后端 |
| conntrack | 依赖 **nf_conntrack**（内核全局单表，高 PPS / 多 Service 时是锁竞争热点） | 自管 **BPF map** 状态，无全局锁；本地 socket 路径可免查询 |
| 时延/吞吐放大器 | 规则条数线性放大查找成本；Service 多 → 首包+每包都贵 | 规则多不影响查找复杂度，只影响 map 变大 |
| 控制面更新 | `iptables-restore` + xtables 锁，几百上千个 Service 时同步慢、易超时 | BPF map **原子批量替换**，更新成本低、快 |
| 卸载/边界 | 难以硬件卸载；VXLAN/IPIP 由内核 tunnel 设备做 | XDP 可在驱动层截包（不建 skb）；支持硬件 offload |
| 资格条件 | 需要 kube-proxy 一起跑 | 一个 agent 全包（KPR） |

### 7.3 所以准确的表述

1. 两套 **数据面都在内核**：Calico 用"通用 netfilter 管线 + 线性规则"，Cilium 用"专用 BPF 程序 + O(1) map"。
2. 差异在**"每包代价（查找复杂度 / 表锁 / 经过的子机制数量）"**与**"规模化后的控制面成本"**，缺省并不在于上下文切换。
3. 这个差距在"服务条数/流量规模"放大后才显性——这正是 Calico 自己也推出 eBPF datapath 的原因（开启后与 Cilium 同构）；若 Calico 走 BGP 原生路由（无 VXLAN 封装），差距会进一步收窄到"规则规模"这一个维度。

---

## 8. Pod 直连流量（不走 Service）：同节点 vs 跨节点

> 本节只讨论 **Pod IP → Pod IP** 的直连（如集群内部互相 ping/HTTP，不经过 Service）。
> 一个常见的错误认知要先纠正：**直连 Pod IP 不走 `lb` 家族 map（`cilium bpf lb list`）**——那张表只存 ClusterIP/NodePort/ExternalIP 这类"VIP→后端"的 NAT 规则。直连打全凭 `endpoint map`（本机 Pod）+ `ipcache map`（全局 Pod→节点映射）。

### 8.1 Cilium（本环境，routing-mode=tunnel/VXLAN）

**依赖的表：**

| 表 | 命令 | 存什么 | 何时查 |
|---|---|---|---|
| endpoint map | `cilium bpf endpoint list` | 本机所有 Pod 的 IP→veth(ifindex)/MAC | 任何入 node 的包，判断"是不是本机 Pod" |
| ipcache map | `cilium bpf ipcache list` | 全局所有 Pod IP→节点(tunnelendpoint)+identity | 目标不在本机时，决定去哪个节点/要不要隧道 |
| tunnel map | `cilium bpf tunnel list` | 远端节点→VXLAN 外层 IP | 跨节点封装用（tunnel 模式） |

实测 `cilium bpf ipcache list`（ubuntu02 视角，`tunnelendpoint` 是否跨节点的铁证）：

```
10.0.1.93 / 10.0.1.137 / 10.0.1.163 / 10.0.1.33   tunnelendpoint=0.0.0.0      ← 本机 Pod，无隧道
10.0.0.75                                        tunnelendpoint=192.168.67.201 ← 远端(ubuntu01)
10.0.2.70 / 10.0.2.93 / 10.0.2.178               tunnelendpoint=192.168.67.203 ← 远端(ubuntu03)
```

**同节点 pod→pod（例 10.0.1.93 → 10.0.1.137）：**

```
src pod → veth → LXC BPF(TC) 查 policy → 查 endpoint map：10.0.1.137 命中本机 veth(ifindex)
        → bpf_redirect 直接灌进目标 veth → dst pod
不查路由表、不 VXLAN、不经过任何 lb map。per-packet 成本 = 一次 map 查找。
```

**跨节点 pod→pod（例 10.0.1.93 → 10.0.2.93，前往 ubuntu03）：**

```
src pod → veth → LXC BPF：endpoint map 未命中本机 → 查 ipcache：
        10.0.2.93 → tunnelendpoint=192.168.67.203 flags=hastunnel
        → 包封装进 VXLAN(内层=10.0.1.93→10.0.2.93，外层=本机→192.168.67.203)
→ via cilium_vxlan 物理转发 → ubuntu03 cilium_vxlan 解封
→ endpoint map 命中 10.0.2.93 的 veth → 投递
```

> **"同一子网所以不用跨节点"只说对一半**：每节点 /24（cluster-pool mask 24）只是 IPAM 的**分组/聚合法**（同 /24 永远只属于一个节点），真正决定"本地直达"的是 **endpoint map 命中**拿到了本机 veth。即便两个 Pod 同节点同在 10.0.1.0/24，也是 map 先命中，而不是"子网相同"决定的。

### 8.2 Calico（默认，无 BPF 数据面）

**数据面=内核**：Felix 负责把规则写进内核，之后每包由内核自己转发。

**同节点 pod→pod：**

```
src pod → veth → 内核 ip_forward：
        查 FIB：Calico 给每个 pod 装了 /32 host 路由（10.x.y.z dev caliX scope link）
        → 命中的是"scope link + 本机 veth"→ 二层直接投递对端 veth → dst pod
policy 走 FORWARD 链的 iptables（cali-* 链）过滤。无封装、无额外查表。
```

**跨节点 pod→pod：**

```
内核路由查 node 子网路由：
  · IPIP 默认 → via tunl0：内核 IPIP 封装（内层 pod-to-pod）→ 物理 → 目标节点
  · VXLAN 模式 → via vxlan.calico（内核 VXLAN 封装，MTU 约 -50）
  · 纯 BGP → 直接经物理网卡下一跳转发（不封装）
目标节点：解封 → 内核路由查 /32 → veth 投递
```

同样：**同节点不靠"同子网"判断，靠 /32 路由明确指向本机 veth**。

### 8.3 注意事项

1. **隧道模式 ≠ 所有流量都封装**：同节点永远裸奔；只有"跨节点 + 开了 overlay"才封装。`ipcache` 里 `tunnelendpoint=0.0.0.0` 就是铁证。
2. **三张表的职责别混用**：`lb list`=Service/NAT、`endpoint map`=本机 Pod、`ipcache`=全局 Pod↔节点。排障：直连 Pod 出问题查后两者；Service 访问出问题才查前者。
3. **ipcache 是 LRU map**：大规模集群建议开 `bpf-map-dynamic-size` 并监控 eviction，被挤出会导致转发异常。
4. **Calico 依赖内核 `ip_forward`**；启用 IPIP/VXLAN 时注意 **MTU**（VXLAN 约减 50，IPIP 减 ~20），否则大包分片/丢包。
5. **别靠"同子网"判断同节点**：per-node /24 全局唯一，同 /24 一定在同一节点；但跨节点也可以在相同大网段（10.0.0.0/8）内，看 `tunnelendpoint` 才准。
6. **BGP 原生路由模式**（Cilium native-routing / Calico BGP）：跨节点也无封装、走物理路由，性能贴近同节点；代价是要求节点二层/BGP 可达且改动内核路由表。

---

## 9. Pod 直连 vs 不走直连（走 Service）：同/跨节点 × Cilium/Calico

> "直连"= Pod IP → Pod IP（无 NAT）；"不直连"= 经 Service ClusterIP → 后端 Pod（有 LB/NAT 一步）。
> 两者差别只在中间多了"查 LB 表选后端 + 改写目标地址"这一步；**同/跨节点只影响"选完后端之后"的转发段**。

### 9.1 用本环境真实映射当例子（来自 `cilium bpf lb list` 实测）

```
curl Pod(10.0.1.93, ubuntu02)
├─ 直连同节点    → 10.0.1.137                    = api Pod(ubuntu02)
├─ 直连跨节点    → 10.0.2.93                     = nginx Pod(ubuntu03)
├─ 不直连(后端同节点) → api Service  10.43.174.55:80 → 后端 10.0.1.137:80
└─ 不直连(后端跨节点) → nginx Service 10.43.66.133:80 → 后端 10.0.2.93:80
```

### 9.2 四场景路径分解

| 场景 | Cilium（eBPF）| Calico（默认 iptables）|
|---|---|---|
| 直连·同节点 | veth → LXC BPF → **endpoint map 命中本机 veth → 直接 redirect**；无 NAT、无隧道 | veth → 内核 ip_forward → 查 per-pod `/32` 路由(`dev caliX scope link`)→ 二层投递 |
| 直连·跨节点 | endpoint map 未命中 → ipcache(`tunnelendpoint=192.168.67.203`)→ **VXLAN 封装** → 对端解封 → veth | 内核路由 → `tunl0`(IPIP)/vxlan.calico → 内核封装 → 对端解封 → veth |
| 不直连·后端同节点（api 10.43.174.55:80） | 查 `lb4_services_v2`(VIP:port)→ 后端 10.0.1.137 → **endpoint map 又命中本机 → 改 dst + 直接 redirect**（连隧道都省了）| kube-proxy **DNAT** dst→10.0.1.137 → 内核 /32 路由 → veth → conntrack 反向还原 |
| 不直连·后端跨节点（nginx 10.43.66.133:80） | 查 lb → 后端 10.0.2.93 → ipcache → **VXLAN 到 .203** → 对端 veth → 返回 rev-NAT 还原 10.43.66.133 | kube-proxy DNAT → 内核路由 via tunl0 → IPIP 封装 → 对端 veth → conntrack 还原 VIP |

### 9.3 直连 vs 不直连的本质区别（举例视角）

| | 直连（Pod IP） | 不直连（Service VIP） |
|---|---|---|
| 目标地址 | 真实 Pod IP，重建即变 | 长期稳定 VIP + DNS 名 |
| 负载均衡 | 无，点到点 | 有：按 EndpointSlice 在所有节点后端中挑选 |
| NAT/回程 | 无 NAT，双向都是原地址 | 有：DNAT/rev-NAT（Cilium BPF map；Calico 靠 kube-proxy iptables + conntrack） |
| 健康/就绪 | 无 | 有：readiness 探针自动剔除失效 Endpoints |
| 典型故障含义 | 直连不通 = 底层 Pod 网络坏（路由/ipcache/封装/MTU） | 直连通但不直连不通 = Service 层问题（Endpoints 空、selector 错、DNS、LB 规则未同步、conntrack 残留） |
| 排障工具 | Cilium：`cilium bpf endpoint list` / `cilium bpf ipcache list`；Calico：`ip route`/`route` | Cilium：`cilium bpf lb list` / `cilium service list`；Calico：`kubectl get endpoints` + `iptables -t nat -L KUBE-SVC-*` |

### 9.4 关键点

1. **LB 选择与节点无关，但成本与节点有关**：端点表在全部节点的后端里挑；选中的后端恰在本机 → 免隧道（Cilium 直接 redirect / Calico 只走 /32 路由）；在别节点 → 才走 overlay/封装那一步。
2. **不直连也不比直连复杂到哪去，只是多了"查 LB 表+改 dst+回程还原"三段**；同节点场景两套都很快，跨节点才显现封装开销。
3. **排障分层**：先 `直连` 验底网，再 `不直连` 验 Service——一票否决把四张表(feature)分开看最不容易绕。

---

## 10. 本案例的 Overlay 与 Underlay（两层网如何协同）

> 配置证据：`routing-mode: tunnel` + `tunnel-protocol: vxlan`（无自定义 port/VNI → 默认 UDP 8472、VNI 1）；节点上 `cilium_vxlan` 只有 link-local 地址，是纯 L2 VTEP。

```
┌──────────── Overlay 层（Pod 虚拟网）──────────────────────────┐
│  10.0.0.0/8，每节点一个 /24；只存在于数据面逻辑里             │
│  VTEP = 每节点的 cilium_vxlan                                 │
│  跨节点 pod 包在 eBPF 里 VXLAN 封装/解封                      │
└───────────────────────┬──────────────────────────────────────┘
                        │ UDP 8472 · 内层=Pod IP · 外层=节点 underlay IP
┌───────────────────────▼──────────────────────────────────────┐
│  Underlay 层（物理网）192.168.67.0/24，节点 eth0 + L2 交换机  │
│  承载：节点管理流 + VXLAN 封装包                              │
└──────────────────────────────────────────────────────────────┘
```

### 10.1 两层各自的定义

| 层 | 网段 | 载体 | 角色 |
|---|---|---|---|
| Underlay | 192.168.67.0/24（.201/.202/.203） | 真实网卡 eth0 + 物理交换机 | 节点间互达：管理流 + VXLAN 封装包；同网段二层直达，无需 BGP |
| Overlay | 10.0.0.0/8（每节点 /24） | 不存在的物理设备，活在数据面 map + cilium_vxlan | Pod 互访的虚拟二/三层 |
| Service VIP | 10.43.0.0/16 | 哪都不是 | 纯逻辑层（BPF lb map / iptables），非 overlay 非 underlay |

### 10.2 协同机制

| 路径 | 走哪层 | 机制 |
|---|---|---|
| 同节点 pod→pod | 哪层都不走 | endpoint map 命中 → veth redirect，不碰 vxlan |
| 跨节点 pod→pod | overlay 封装，跑在 underlay 上 | ① lxc BPF 查 ipcache：10.0.2.93→tunnelendpoint=.203 ② eBPF 在 cilium_vxlan 封装(inner=10.0.1.93→10.0.2.93, outer=.202→.203, UDP 8472) ③ underlay 真实网卡转发 ④ 对端解封→endpoint map→veth |
| 节点自身/外部流量 | underlay | Host: Legacy，走传统内核栈 |

### 10.3 关键洞察

1. **Underlay 不参与 Pod 路由决策**：物理交换机看不见 10.0.x.x，只管外层 192.168.67.x。这就是 overlay 的核心价值——Pod 子网对 underlay 完全隐藏，不用在物理网络上配 10 网段路由。
2. **封装由 eBPF 完成**（区别于 Calico 用内核 `vxlan.calico`/`tunl0` 驱动设备）：少一层内核设备栈的开销，且可统一控制/offload。
3. **切 native-routing / BGP 模式 = 搬到 underlay 上组织 Pod 路由**：10.0.0.0/8 由物理路由器/BGP 宣告，跨节点不再封装，性能贴近同节点；代价是 underlay 必须懂 Pod 网段。
4. 逻辑三段各归其位：**同节点=本机 micro 转发(MF)；跨节点=overlay 封装的 underlay 传输；Service=数据面逻辑 VIP**。排障时先分清包此刻在"哪层"。