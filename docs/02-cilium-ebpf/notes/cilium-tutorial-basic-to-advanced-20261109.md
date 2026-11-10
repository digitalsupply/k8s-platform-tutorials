# Cilium 从基础到深入：本集群完整教程

> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 当前网络：Cilium 1.20.4 全量 CNI + kube-proxy replacement + eBPF host routing + BPF masquerade  
> 当前状态：139 Pod、105 Service、101 CiliumEndpoint、MTU 1500、kube-proxy 已移除  
> 本文目标：从 Kubernetes 网络基础讲到 Cilium 进阶能力，并结合本集群说明“哪些优势已经用到、哪些还没有、为什么”。

---

## 0. 先回答：当前配置是否发挥了 Cilium 的全部优势？

**没有。**

当前集群已经用到的核心能力：

| 能力 | 状态 |
|---|---|
| Cilium 全量 CNI | ✅ |
| kube-proxy replacement | ✅ |
| eBPF host routing | ✅ `Host: BPF` |
| BPF masquerade | ✅ `Masquerading: BPF` |
| Socket LB | ✅ `Coverage: Full` |
| ClusterIP / NodePort / LoadBalancer / externalIPs / HostPort | ✅ |
| Kubernetes IPAM | ✅ 每节点 `/24` |
| Native routing | ✅ `devices=eth0`，无 IPIP/VXLAN |
| Hubble L3/L4 流、drop、TCP | ✅ |
| K8s NetworkPolicy | ✅ |
| Cilium/Hubble Prometheus 指标 | ✅ |

当前**没有**发挥的 Cilium 能力：

| 能力 | 当前状态 | 原因/影响 |
|---|---|---|
| L7 HTTP/gRPC 策略与可见性 | ❌ `l7Proxy=false` | 未启用 Envoy；看不到 HTTP 状态码/路径 |
| FQDN/DNS 策略 | ❌ | 需要 DNS proxy/L7 |
| DSR / Hybrid LB | ❌ `Mode: SNAT` | 回程仍 SNAT；源 IP 保留/回程优化未启用 |
| Maglev | ❌ `Backend Selection: Random` | 大规模 Service 一致性哈希未启用 |
| XDP 加速 | ❌ `XDP Acceleration: Disabled` | 未启用，且依赖网卡驱动 |
| netkit | ❌ | 需要内核 6.8+，当前 5.14/5.15 |
| Big TCP | ❌ | IPv6 需 5.19+，IPv4 需 6.3+ |
| Cilium LB IPAM / L2 Announcement | ❌ | 继续使用 MetalLB |
| BGP Control Plane | ❌ | 当前没有外部 BGP peer |
| WireGuard/IPsec 加密 | ❌ | 未启用 |
| Gateway API / Cilium Ingress | ❌ | 继续使用 Traefik |
| Cluster Mesh | ❌ | 单集群 |
| Egress Gateway | ❌ | 未启用 |
| Tetragon 运行时安全 | ❌ | 未安装 |
| Bandwidth Manager/BBR | ❌ | 未启用 |
| L7 Hubble 指标（http/dns） | ❌ | 当前 metrics 只有 drop/tcp/flow |

**结论：**

> 当前是“Cilium 的 eBPF CNI + kube-proxy replacement”形态，已经拿到了核心数据面和 Service 替换收益；但 L7、DSR、XDP、netkit、Big TCP、BGP、加密、Tetragon、Gateway API 等高级能力还没启用，其中一部分受 5.15 内核限制，一部分是当前规模/需求不需要，一部分是为了降低风险而刻意关闭。

---

## 1. 基础篇：Kubernetes 网络到底在做什么

### 1.1 Pod 网络模型

Kubernetes 只规定“每个 Pod 有唯一 IP，Pod 之间可以直接通信”，不规定怎么实现。

典型实现：

```text
Pod A netns
  eth0 10.244.3.10
      │ veth pair
      ▼
Host eth0 / cali*/lxc*
      │
      ▼
Underlay 10.0.0.0/24（本集群）
      │
      ▼
Host eth0 / cali*/lxc*
      │
      ▼
Pod B netns
  eth0 10.244.4.20
```

需要解决：

1. **IPAM**：Pod IP 从哪来。
2. **Pod-to-Pod 路由**：同节点/跨节点怎么走。
3. **Pod-to-Service**：ClusterIP 怎么 DNAT 到 backend。
4. **NAT/Masquerade**：出集群怎么 SNAT。
5. **NetworkPolicy**：谁可以访问谁。
6. **可观测性**：流量、丢包、延迟。

### 1.2 CNI、IPAM、Chaining

**CNI**：容器运行时创建/删除 Pod 网络时调用的插件协议。

**IPAM**：IP 地址管理。

**Chaining**：多个 CNI 插件串联，例如：

```text
Calico (IPAM/路由) -> portmap -> cilium-cni (eBPF)
```

本集群历史：

- 最早：Calico + IPIP。
- Phase 0：Calico IPIP `Never`，MTU 1500。
- Phase 1：Cilium chaining + Hubble。
- Phase 2：Cilium 全量 CNI，删除 Calico。
- Phase 3：删除 kube-proxy，Cilium kube-proxy replacement。

当前：

```text
05-cilium.conflist
  └─ cilium-cni
```

Calico CNI/CRD/DS 已删除。

### 1.3 Service 基础

Kubernetes Service 类型：

| 类型 | 作用 |
|---|---|
| ClusterIP | 集群内虚拟 IP |
| NodePort | 每个节点开一个端口，转发到 Service |
| LoadBalancer | 外部 LB VIP（本集群用 MetalLB L2） |
| ExternalName | DNS CNAME，不做代理 |
| Headless | 无 ClusterIP，直接返回 Pod IP |
| externalIPs | 额外外部 IP |
| HostPort | Pod 绑定宿主机端口 |

Service 本身不是进程，它依赖：

- EndpointSlice：哪些 Pod 是 backend。
- 数据面：kube-proxy 或 Cilium 把 VIP:Port 转成 PodIP:Port。
- conntrack：保持连接。
- NAT：SNAT/DNAT。

### 1.4 NAT 与 conntrack

```text
Client -> Service VIP:Port
  DNAT -> PodIP:Port
  conntrack 记录反向转换
Pod reply -> conntrack 反向 NAT -> Client
```

出集群：

```text
Pod -> 外部 IP
  SNAT 成节点 IP
外部 reply -> conntrack 反向 SNAT -> Pod
```

MTU 很关键：

- 无封装：1500
- IPIP：1480
- VXLAN：1450
- Geneve：约 1442

本集群当前：**Cilium native routing，MTU 1500**。

### 1.5 本集群网络拓扑

```text
节点：
  m01        10.0.0.61   Rocky 9.6  kernel 5.14
  master01   10.0.0.121  Ubuntu 22.04 kernel 5.15
  master02   10.0.0.120  Ubuntu 22.04 kernel 5.15
  worker01   10.0.0.122  Ubuntu 22.04 kernel 5.15
  worker02   10.0.0.123  Ubuntu 22.04 kernel 5.15
  worker03   10.0.0.124  Ubuntu 22.04 kernel 5.15

Pod CIDR：10.244.0.0/16（每节点 /24）
API VIP：10.0.0.168（kube-vip）
Ingress VIP：10.0.0.252（MetalLB L2 -> Traefik）
```

所有节点在同一二层 `10.0.0.0/24`，所以 Cilium native routing 可以直接工作，不需要 IPIP/VXLAN。

---

## 2. kube-proxy：它到底做了什么

### 2.1 控制循环

kube-proxy：

1. watch `Service`、`EndpointSlice`、`Node`。
2. 根据模式（iptables/IPVS/nftables）生成转发规则。
3. 周期性 sync，保证规则与 API 一致。
4. 提供 metrics/healthz。

它不转发数据包；数据包由内核 netfilter/IPVS 处理。

### 2.2 iptables 模式

典型链：

```text
PREROUTING
  -> KUBE-SERVICES
      -> KUBE-SVC-xxxxx
          -> KUBE-SEP-yyyyy  (DNAT 到 PodIP)
POSTROUTING
  -> KUBE-POSTROUTING
      -> MASQUERADE
```

其他：

- `KUBE-MARK-MASQ`
- `KUBE-NODEPORTS`
- `KUBE-FW-*`
- `KUBE-EXTERNAL-SERVICES`

包路径：

```text
Pod/外部 -> netfilter PREROUTING
  -> KUBE-SERVICES
  -> KUBE-SVC-xxx
  -> KUBE-SEP-xxx DNAT
  -> 路由到 backend
  -> 回程 conntrack 反向 NAT
```

特点：

- 规则线性遍历；Service/Endpoint 多时规则链变长。
- 全量/增量 `iptables-restore`；sync 有延迟。
- 首包需要 DNAT。
- 依赖 conntrack。
- 无 L7、无 flow 级观测。

本集群历史实测：

```text
NAT 规则/节点：507
KUBE-SVC 链：341
kube-proxy CPU：1.5–2.4m
kube-proxy 内存：55–101 MiB
全量 sync p50：96 ms，p99：127 ms（频率低）
```

### 2.3 IPVS / nftables 模式

- **IPVS**：用 IPVS virtual server + scheduler（rr/lc/sh...），比 iptables 更适合大量 Service，但调试复杂。
- **nftables**：新规则后端，原子替换、set 查找；本集群 m01 上 `nft v1.0.9` 曾有 segfault 历史，因此 kube-proxy 回退 iptables。
- 两种模式仍然不做 L7，不做 flow 观测。

### 2.4 kube-proxy 支持的功能

| 功能 | kube-proxy |
|---|---|
| ClusterIP | ✅ |
| NodePort | ✅ |
| LoadBalancer | ✅（配合 MetalLB/云 LB） |
| externalIPs | ✅ |
| Headless | 不做代理，直接 DNS |
| sessionAffinity | ✅ |
| externalTrafficPolicy=Local/Cluster | ✅ |
| internalTrafficPolicy | ✅ |
| source IP 保留 | 部分场景 |
| healthCheckNodePort | ✅ |
| EndpointSlice | ✅ |
| topology-aware hints | ✅（版本相关） |
| DSR | ❌（IPVS 也不是 Cilium DSR） |
| L7 策略 | ❌ |
| flow 级观测 | ❌ |
| Socket LB | ❌ |

### 2.5 kube-proxy 的痛点

1. 规则数量随 Service/Endpoint 增长。
2. 全量 sync 有成本。
3. 每包走 netfilter，CPU 随 PPS 增长。
4. 没有 L7/流级可观测性。
5. nftables/iptables 兼容性和内核 bug。
6. 无法做 socket-level 负载均衡。
7. metrics 只覆盖规则同步，不覆盖业务流。

---

## 3. Cilium 架构与 eBPF 基础

### 3.1 eBPF 是什么

eBPF 是内核中的安全虚拟机：

- **程序**：C 编译成 BPF 字节码，加载到内核。
- **map**：内核态键值存储，用户态/内核态共享。
- **hook**：socket、tc、XDP、cgroup、kprobe、tracepoint 等。
- **CO-RE/BTF**：一次编译，跨内核版本运行；本集群 BTF 全部存在。

Cilium 把网络、策略、LB、NAT、可观测性都放进 eBPF。

### 3.2 Cilium 组件

```text
cilium-agent（每节点，hostNetwork）
  ├─ CNI 插件
  ├─ eBPF datapath
  ├─ policy/identity
  ├─ IPAM（Kubernetes IPAM）
  ├─ Hubble server
  └─ metrics

cilium-operator（2 副本）
  ├─ IPAM/CiliumNode
  ├─ CiliumEndpoint GC
  ├─ identity/CRD
  └─ LB IPAM（当前关闭）

hubble-relay（1）
  └─ 聚合各节点 Hubble 流

hubble-ui（1）
  └─ 服务依赖图/流查询

cilium-envoy（按需）
  └─ L7 策略/可见性（当前 l7Proxy=false，未启用）
```

CRD：

- `CiliumNode`
- `CiliumEndpoint`
- `CiliumIdentity`
- `CiliumNetworkPolicy`
- `CiliumClusterwideNetworkPolicy`
- `CiliumLoadBalancerIPPool`
- `CiliumL2AnnouncementPolicy`
- `CiliumBGPPeeringPolicy`
- `CiliumEgressGatewayPolicy`

### 3.3 Cilium 数据面

```text
Pod A -> veth/lxc -> tc ingress
  -> from-container BPF
  -> policy (identity)
  -> service LB（socket LB 通常更早）
  -> conntrack/NAT
  -> route/eth0
  -> remote node
  -> to-container BPF
  -> Pod B
```

关键程序：

- `bpf_lxc`：Pod ingress/egress。
- `bpf_host`：host routing / NodePort / masquerade。
- `bpf_overlay`：VXLAN/Geneve（当前未用）。
- `bpf_sock`：socket-level LB。
- `bpf_xdp`：XDP 加速（当前未启用）。

### 3.4 Identity 与策略

Cilium 不是主要按 IP 做策略，而是：

```text
Pod labels -> CiliumIdentity -> policy map
```

优点：

- 策略跟 label/identity 走，不依赖 IP。
- 支持 L7/FQDN/entities。
- Hubble 能显示 identity/verdict。

代价：

- label 基数过高会产生大量 identity。
- 策略变更需要 endpoint 重新生成。
- K8s NP 与 Cilium NP 语义需要理解。

### 3.5 当前 Cilium 状态

```text
Cilium:                 Ok 1.20.4
KubeProxyReplacement:   True
Host Routing:           BPF
Masquerading:           BPF
Socket LB:              Enabled / Full
Mode:                   SNAT
Backend Selection:      Random
XDP Acceleration:       Disabled
CNI Chaining:           none
IPAM:                   Kubernetes（每节点 /24）
Routing:                Native / eth0
Controller Status:      62/62 healthy
```

---

## 4. Cilium 如何取代 kube-proxy

### 4.1 控制面

Cilium agent 直接 watch：

- Service
- EndpointSlice
- Node
- NetworkPolicy

然后写入 BPF maps：

- `cilium_lb4_services_v2`
- `cilium_lb4_backends_v3`
- `cilium_lb4_reverse_nat`
- `cilium_lb4_affinity`
- `cilium_ct4_global`
- `cilium_ipcache_v2`

不再生成 `KUBE-SVC`/`KUBE-SEP` iptables 链。

### 4.2 三种 LB 层

| 层 | 说明 | 当前 |
|---|---|---|
| Socket LB | 在 `connect()`/`sendmsg()` 时选 backend，连接直接指向 Pod IP | ✅ `Coverage: Full` |
| tc LB | veth/host 的 tc ingress 处理 Service VIP | ✅ 作为回退/外部流量 |
| XDP LB | 驱动层处理 NodePort/LB，最早 | ❌ 未启用 |

Socket LB 是 Cilium 相比 kube-proxy 最大的差异之一：

```text
应用 connect("10.96.0.10:443")
  -> Cilium socket hook 查 service map
  -> 直接把 socket 目标改成 backend PodIP:Port
  -> 不需要 netfilter DNAT
```

### 4.3 Service 类型映射

| kube-proxy | Cilium |
|---|---|
| ClusterIP | `lb4_services` + backends |
| NodePort | BPF NodePort（tc/XDP） |
| LoadBalancer | BPF LB + MetalLB/kube-vip |
| externalIPs | BPF LB externalIPs |
| HostPort | Cilium HostPort |
| Headless | 不代理，DNS 直接返回 Pod IP |
| sessionAffinity | BPF affinity map |
| externalTrafficPolicy | Cilium 支持，需验证 |
| healthCheckNodePort | Cilium 支持（需按版本验证） |
| topology hints | Cilium 支持 PreferSameZone/Node（1.20） |
| DSR | Cilium 支持（当前未启用） |
| Maglev | Cilium 支持（当前 random） |

### 4.4 SNAT、DSR、Hybrid

当前：

```text
Mode: SNAT
```

含义：

- NodePort/LoadBalancer 回程通常经过 SNAT。
- 源 IP 保留取决于 `externalTrafficPolicy`/模式，需验证。

可选：

```yaml
loadBalancer:
  mode: dsr        # 或 hybrid
```

优点：

- 回程不经过 LB 节点，减少一跳。
- 更好保留客户端源 IP。
- 降低 NodePort/LB 节点回程带宽。

代价：

- 需要网络/内核支持。
- 与 MetalLB L2、kube-vip、云 LB 的兼容性要验证。
- 不是所有拓扑都适合。

### 4.5 Maglev

当前：

```text
Backend Selection: Random
```

可选：

```yaml
loadBalancer:
  algorithm: maglev
```

适用：

- 大量 backend/Service。
- 需要更稳定的一致性哈希。
- 减少 backend 变化导致的连接重分配。

当前 105 Service，random 足够。

### 4.6 XDP 加速

当前：

```text
XDP Acceleration: Disabled
```

可选：

```yaml
loadBalancer:
  acceleration: native
```

需要：

- 网卡驱动支持 native XDP。
- 单设备（direct routing device）。
- 适合高 PPS NodePort/LB。

当前流量低，收益有限。

### 4.7 与 kube-proxy 的对照

| 维度 | kube-proxy | Cilium |
|---|---|---|
| Service 编程 | iptables/IPVS/nftables | BPF maps |
| 包路径 | netfilter DNAT | socket/tc/XDP LB |
| 规则规模 | 随 Service 线性增长 | map O(1) |
| 首包延迟 | DNAT | Socket LB 更低 |
| 源 IP | 受 SNAT/Local 影响 | SNAT/DSR/Hybrid 可选 |
| DSR | ❌ | ✅ |
| Maglev | ❌ | ✅ |
| L7 | ❌ | ✅（Envoy） |
| 流级观测 | ❌ | Hubble |
| 指标 | `kubeproxy_*` | `cilium_*`/`hubble_*` |
| 组件 | 独立 DaemonSet | 集成在 agent |

### 4.8 切换风险

- 两者同时运行会维护两套 NAT 表，**不感知彼此**。
- 切换时现有连接可能中断。
- 必须维护窗口。
- 本集群已经完成：kube-proxy 删除，KPR=True。

---

## 5. Cilium 的增强能力

### 5.1 NetworkPolicy

Cilium 支持：

- Kubernetes NetworkPolicy
- CiliumNetworkPolicy（namespaced）
- CiliumClusterwideNetworkPolicy（cluster-wide）
- L3/L4
- L7 HTTP/gRPC（Envoy）
- FQDN/DNS（`toFQDNs`）
- entities：host/world/cluster/remote-node/kube-apiserver/ingress
- deny/audit（版本/配置）
- policy trace

与 Calico 差异：

- Calico 以 IP/iptables/ipset 为主，GlobalNetworkPolicy/HostEndpoint/Tiers。
- Cilium 以 identity/eBPF 为主，L7/FQDN/entities 更强。
- Cilium 对 kubelet 探针的 host 源语义更严格（本集群踩坑）。
- K8s NP 与 Cilium NP 混用需要逐条验证，不能假设 Cilium NP 覆盖 K8s NP 默认拒绝。

### 5.2 Hubble

当前可用：

- L3/L4 flow
- drop
- TCP
- 服务依赖图
- Hubble UI/CLI
- Prometheus metrics

当前未启用：

- L7 HTTP/gRPC 可见性（需要 `l7Proxy=true`）
- DNS 细粒度指标（需要 L7/DNS proxy）
- HTTP 指标（`httpV2`）

Hubble 不是 tracing，不替代 Tempo；它提供网络流/协议观测。

### 5.3 L7 / Ingress / Gateway API

- `l7Proxy=true` 启用 Envoy。
- CiliumNetworkPolicy 支持 HTTP method/path/header。
- Cilium Gateway API 可替代部分 Ingress/服务网格。
- 当前继续使用 Traefik + MetalLB；未启用 Cilium Gateway/Ingress。

### 5.4 加密

- WireGuard：内核 5.6+，UDP 51871。
- IPsec：内核 4.19+。
- 当前未启用；会增加 CPU/吞吐开销。

### 5.5 BGP / LB IPAM

- Cilium BGP Control Plane 可替代 Calico BIRD，对外发布 Service/Pod 路由。
- Cilium LB IPAM + L2 Announcement 可替代 MetalLB。
- 当前：
  - 无外部 BGP peer；
  - MetalLB 继续负责 `10.0.0.252`；
  - Cilium LB IPAM 关闭。

### 5.6 Cluster Mesh / Egress Gateway

- Cluster Mesh：多集群 Pod/Service 互通。
- Egress Gateway：固定出口 IP。
- 当前单集群，未启用。

### 5.7 Tetragon

- eBPF 运行时安全：进程、文件、网络、权限。
- 独立组件，不是 CNI 必需。
- 当前未安装。

### 5.8 Bandwidth Manager / BBR

- `bandwidthManager.enabled=true` 可做 Pod 限速/BBR。
- 当前未启用。

---

## 6. 当前集群能力矩阵（逐项）

| 能力 | 当前 | 说明 | 启用方式 | 优先级 |
|---|---|---|---|---|
| KubeProxyReplacement | ✅ | kube-proxy 已删除 | `kubeProxyReplacement=true` | 已完成 |
| eBPF host routing | ✅ | Host BPF | `bpf.hostLegacyRouting=false` | 已完成 |
| BPF masquerade | ✅ | Masquerading BPF | `bpf.masquerade=true` | 已完成 |
| Socket LB | ✅ | Full | 自动 | 已完成 |
| Native routing | ✅ | eth0，1500 | `routingMode=native` | 已完成 |
| Kubernetes IPAM | ✅ | 每节点 /24 | `ipam.mode=kubernetes` | 已完成 |
| Hubble L3/L4 | ✅ | drop/tcp/flow | `hubble.enabled=true` | 已完成 |
| L7 HTTP/gRPC | ❌ | 未启用 Envoy | `l7Proxy=true` + visibility | 中 |
| FQDN/DNS 策略 | ❌ | 需要 DNS proxy | `toFQDNs` | 中 |
| DSR/Hybrid | ❌ | 当前 SNAT | `loadBalancer.mode=dsr/hybrid` | 中高（入口场景） |
| Maglev | ❌ | 当前 random | `loadBalancer.algorithm=maglev` | 低（规模足够大再开） |
| XDP 加速 | ❌ | 未启用/需网卡 | `loadBalancer.acceleration=native` | 中（高 PPS） |
| netkit | ❌ | 内核 5.15 不支持 | 内核 6.8+ + `bpf.datapathMode=netkit` | 高（性能） |
| Big TCP | ❌ | 内核 5.15 不支持 | 5.19/6.3+ | 高（大流量） |
| Cilium LB IPAM/L2 | ❌ | MetalLB 仍在 | `enableLBIPAM=true` | 低（当前 MetalLB 可用） |
| BGP | ❌ | 无外部 peer | BGP Control Plane | 低（当前不需要） |
| WireGuard/IPsec | ❌ | 未启用 | `encryption.enabled=true` | 视合规 |
| Gateway API | ❌ | Traefik | `gatewayAPI.enabled=true` | 中 |
| Cluster Mesh | ❌ | 单集群 | `clustermesh` | 低 |
| Egress Gateway | ❌ | 未启用 | `egressGateway.enabled=true` | 低 |
| Tetragon | ❌ | 未安装 | 单独 Helm | 中（安全） |
| Bandwidth Manager | ❌ | 未启用 | `bandwidthManager.enabled=true` | 低 |
| Local Redirect Policy | ❌ | 未启用 | `localRedirectPolicies.enabled=true` | 低 |

---

## 7. 性能与资源：本集群实测

### 7.1 之前 vs 现在

**之前 Calico + kube-proxy：**

```text
calico-node: 80–108m CPU / 284–450 MiB
kube-proxy:  1.5–2.4m CPU / 55–101 MiB
合计:        约 82–110m / 340–550 MiB 每节点
iptables NAT 规则：507/节点
kube-proxy p50 sync：96 ms
```

**现在 Cilium：**

```text
cilium-agent:    28–152m CPU / 145–251 MiB
cilium-operator: 2–6m ×2 / 38–60 MiB ×2
hubble-relay:    ~1m / 18 MiB
hubble-ui:       ~1m / 15 MiB
```

集群合计粗算：

```text
Cilium：约 401m CPU / 1.15 GiB
Calico + kube-proxy：约 547m CPU / 2.5 GiB
```

注意：

- dense 节点 worker01 的 Cilium agent 约 150m CPU（83 endpoint），高于原 Calico。
- eBPF map 使用内核内存，不在容器 working set 内，需额外预留。
- 当前节点内存：m01 82%、master02 81%、worker01 81%，容量要关注。
- 当前流量很低（约 75 Mbps 级），性能差异不体现在吞吐上。

### 7.2 当前性能收益来源

- 新建连接：Socket LB 直接选 backend。
- 每包：Host Routing BPF 绕过 netfilter。
- Masquerade：BPF 完成。
- Service 变更：BPF map 更新。
- kube-proxy 进程消失：CPU/内存减少。

### 7.3 当前性能上限

- 内核 5.15，无 netkit/Big TCP。
- XDP 未启用。
- DSR 未启用（SNAT）。
- Maglev 未启用（random）。
- L7 未启用。
- 当前不是 Cilium 的极限性能形态。

### 7.4 如何做性能验证

建议在维护窗口/测试环境：

```bash
# Pod 到 Pod 吞吐/延迟
kubectl run iperf-server --image=networkstatic/iperf3 ...
kubectl run iperf-client --image=networkstatic/iperf3 ...

# 不同节点、不同 Service、NodePort/LB
# 对比 Cilium 与旧 kube-proxy 数据（历史）
```

不要在生产高峰做带宽压测。

---

## 8. 运维 / SRE 教程

### 8.1 日常检查

```bash
cilium status --wait

kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50
```

关注：

- `KubeProxyReplacement: True`
- `Host Routing: BPF`
- `Masquerading: BPF`
- `Controller Status`
- `Socket LB`
- `cilium-dbg service list` 的 backend
- Hubble drop 原因
- Cilium agent/operator/Hubble 资源
- Hubble buffer 是否 100%

### 8.2 NetworkPolicy 迁移与健康检查

**最重要的一条：**

> 有默认拒绝/限制性 Ingress 的命名空间，迁移到 Cilium 后必须显式放行 kubelet 健康检查端口，否则 Pod 会 Running 但 NotReady。

本集群实际处理：

```yaml
# china-study-free / monitoring / tekton-pipelines
kind: NetworkPolicy
metadata:
  name: allow-kubelet-health-probes
spec:
  podSelector: ...
  policyTypes: [Ingress]
  ingress:
    - ports:
        - port: 8787   # 按命名空间调整
```

原因：

- Cilium KPR + host routing 下，kubelet 探针源是 Cilium host IP（10.244.x），被识别为 `world`。
- 原有 K8s NP 默认拒绝，探针被 Hubble 标记为 `Policy denied DROPPED`。
- 健康端口放行后恢复。

建议：

- 把健康端口放行纳入所有 NP 迁移 checklist。
- 尽量缩小端口/来源；当前为恢复使用允许所有来源到健康端口，后续可收紧。
- 不要只加 CiliumNetworkPolicy，K8s NP 默认拒绝仍需显式放行（本集群实测）。

### 8.3 策略迁移流程

1. 盘点 Calico/K8s NP。
2. K8s NP 原样保留。
3. Calico GNP/CNP/HostEndpoint/Tiers 逐条映射到 Cilium NP/CCNP。
4. audit 观察（Hubble DROP）。
5. 先放行 DNS/API/健康检查/监控。
6. 再 enforce。
7. 准备回滚。

### 8.4 排障路径

**DNS 不通：**

- CoreDNS endpoints；
- Cilium DNS proxy（如启用）；
- NP 是否放行 53/TCP/UDP；
- hostNetwork Pod 默认 DNS 是节点 resolv.conf，需要 `ClusterFirstWithHostNet` 或显式 `10.96.0.10`。

**Service 不通：**

```bash
cilium-dbg service list
cilium-dbg bpf lb list
kubectl get endpointslices
hubble observe --verdict DROPPED
```

检查 backend 是否正确、NetworkPolicy、NodePort/LB、MetalLB/kube-vip。

**Pod 启动但 NotReady：**

- 优先看 kubelet 探针事件；
- Hubble 是否 `Policy denied DROPPED`；
- 健康端口 NetworkPolicy；
- 容器日志。

**策略不生效：**

```bash
cilium-dbg policy get
cilium-dbg endpoint list
cilium-dbg policy trace ...
```

检查 endpoint identity、方向、端口、K8s NP vs Cilium NP。

### 8.5 指标与告警

移除：

- `kubeproxy_*`
- Calico Felix 指标/PodMonitor
- 旧 kube-proxy dashboard

新增：

- `cilium_*` agent/operator
- `hubble_*` drop/DNS/TCP/HTTP
- `cilium_bpf_map_*`
- CiliumEndpoint/identity 数量
- Node memory/CPU

告警建议：

- Hubble drop 突增；
- Cilium agent/operator not ready；
- BPF map pressure；
- Node memory pressure；
- Hubble buffer 100%；
- Cilium API latency。

### 8.6 配置变更

`kubeProxyReplacement`、`bpf.masquerade`、`hostLegacyRouting` 是启动时配置：

```bash
helm upgrade ...
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

检查 `config-drift-checker` 日志，避免 Helm 改了 ConfigMap 但 agent 没生效。

### 8.7 升级与回滚

- Cilium 逐 minor 升级；1.20.x 固定。
- 先 preflight，再升级 agent/operator/CRD。
- 备份 values、kube-proxy DS/CM、Calico IPPool/Felix/BGP、CNI conflist。
- 回滚 Calico 时必须设置 `IP_AUTODETECTION_METHOD=interface=eth1`，避免 `cilium_host` 被误认节点 IP。
- 回滚 RTO 约 1–2 小时。

---

## 9. 进阶实验（在本集群可执行）

### 9.1 查看 Service 后端

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
```

### 9.2 验证 NodePort / LoadBalancer

```bash
curl -H 'Host: studyfree.xyz' http://10.0.0.252/
curl -H 'Host: studyfree.xyz' http://10.0.0.61:30156/
kubectl get --raw /healthz
```

### 9.3 验证 Pod-to-Pod MTU

```bash
kubectl run mtu-test --image=busybox:1.37 --restart=Never --command -- sleep 600
kubectl exec mtu-test -- cat /sys/class/net/eth0/mtu
# 从另一 Pod/宿主 ping -M do -s 1472 <pod-ip>
```

### 9.4 观察策略 DROP

```bash
# 在测试命名空间创建默认拒绝
kubectl create ns cilium-policy-demo
kubectl -n cilium-policy-demo apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF

kubectl -n kube-system exec ds/cilium -- hubble observe --namespace cilium-policy-demo --verdict DROPPED --last 50
```

### 9.5 观察 Hubble 流

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace traefik --last 20
kubectl -n kube-system exec ds/cilium -- hubble observe --protocol http --last 20  # 仅在 l7Proxy=true 时
```

### 9.6 L7 试点（需单独窗口）

```yaml
l7Proxy: true
hubble:
  metrics:
    enabled: [dns, drop, tcp, flow, httpV2]
```

然后：

- 给目标命名空间加 visibility 注解或 L7 策略；
- 验证 Envoy 内存/延迟；
- 先单命名空间，不要全局。

### 9.7 DSR / XDP / Maglev（需评估）

```yaml
loadBalancer:
  mode: dsr          # 或 hybrid
  algorithm: maglev
  acceleration: native
```

这些需要网络/网卡/业务验证，不能直接在生产开启。

---

## 10. 从当前到“完整 Cilium”的路线

### Phase A：当前（已完成）

- Cilium full CNI
- KPR
- Host BPF
- BPF masquerade
- Socket LB
- Native routing
- Hubble L3/L4
- K8s NP
- MetalLB/kube-vip

### Phase B：可立即评估（无需内核升级）

- L7 Proxy + Hubble L7（单命名空间）
- FQDN/DNS 策略
- DSR/Hybrid（需 MetalLB/kube-vip 验证）
- Maglev（Service 规模足够时）
- Cilium Gateway API（替代部分 Ingress）
- Tetragon（运行时安全）
- Bandwidth Manager/BBR
- Cilium LB IPAM（替换 MetalLB，需验证）
- BGP Control Plane（如有外部 peer）

### Phase C：需要内核升级（性能上限）

- 升级到 6.8+：
  - netkit（`bpf.datapathMode=netkit`）
  - Big TCP（5.19/6.3+）
- 网卡支持：
  - XDP acceleration
  - 更高吞吐
- 这需要单独的内核升级/节点滚动计划，不建议和 CNI 变更混做。

### Phase D：多集群/安全

- Cluster Mesh
- Egress Gateway
- SPIFFE/mTLS
- Tetragon 策略

---

## 11. 速查表

### Cilium

```bash
cilium status --wait
cilium-dbg status --verbose
cilium-dbg service list
cilium-dbg bpf lb list
cilium-dbg endpoint list
cilium-dbg policy get
cilium-dbg policy trace ...
cilium-dbg bpf ct list global
cilium-dbg bpf nat list
cilium-dbg monitor
hubble observe --last 50
hubble observe --verdict DROPPED --last 50
cilium sysdump
```

### 旧 kube-proxy（对比/回滚参考）

```bash
iptables -t nat -L KUBE-SERVICES -n
iptables-save | grep KUBE
kubectl -n kube-system logs ds/kube-proxy
kubectl -n kube-system get cm kube-proxy -o yaml
```

### 本集群关键对象

```text
Cilium 1.20.4
KubeProxyReplacement=True
Host Routing=BPF
Masquerading=BPF
Socket LB=Full
Mode=SNAT
Backend=Random
XDP=Disabled
IPAM=Kubernetes /24
Routing=Native eth0
Pod CIDR=10.244.0.0/16
API VIP=10.0.0.168
Ingress VIP=10.0.0.252
```

---

## 12. 结论

1. **Cilium 已经取代 kube-proxy 的核心 Service 功能**：ClusterIP、NodePort、LoadBalancer、externalIPs、HostPort、sessionAffinity、socket LB。
2. **当前不是 Cilium 的完整形态**：L7、FQDN、DSR、Maglev、XDP、netkit、Big TCP、BGP、加密、Gateway API、Tetragon 未启用，部分受 5.15 内核限制。
3. **当前收益**：kube-proxy 移除、Host BPF、Masquerade BPF、Socket LB、native routing、Hubble L3/L4、K8s NP；资源总量低于 Calico+kube-proxy，但 dense 节点 CPU 更高。
4. **最大运维风险**：NetworkPolicy 语义变化，尤其是 kubelet 探针被默认拒绝；必须把健康检查放行加入迁移/日常 runbook。
5. **下一步优先级**：
   - 先稳定当前 Cilium；
   - 再评估 L7/Tetragon/DSR/Gateway；
   - 最后规划内核 6.8+ 解锁 netkit/Big TCP/XDP。

---

## 附录：参考

- Kubernetes Service：<https://kubernetes.io/docs/concepts/services-networking/service/>
- kube-proxy：<https://kubernetes.io/docs/reference/networking/virtual-ips/>
- Cilium 1.20 文档：<https://docs.cilium.io/en/stable/>
- Cilium kube-proxy-free：<https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium Routing：<https://docs.cilium.io/en/stable/network/concepts/routing/>
- Cilium IPAM：<https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Cilium NetworkPolicy：<https://docs.cilium.io/en/stable/security/policy/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- Cilium Tuning：<https://docs.cilium.io/en/stable/operations/performance/tuning/>

---

**教程结束。**
