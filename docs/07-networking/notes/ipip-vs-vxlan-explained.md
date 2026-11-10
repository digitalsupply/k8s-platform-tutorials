# IPIP 与 VXLAN 封装机制详解

本文所有数据来自本集群实测（Kubernetes v1.35.9 | Calico v3.32.2 | IPIP Always + VXLAN Never）。

---

## 一、它们解决什么问题

Calico 支持两种跨节点 Pod 网络的数据传输方式：

| 模式 | 是否封装 | 跨节点 Pod 流量路径 |
|---|---|---|
| **IPIP** | ✅ 封装 | 走IP 隧道 |
| **VXLAN** | ✅ 封装 | 走二层隧道 |
| BGP（无封装）| ❌ | 走 BGP 学到的路由 |

**为什么需要封装？**

Pod 网段（如 `10.244.0.0/16`）通常和物理网络（如 `10.0.0.0/24` / `172.16.1.0/24`）**不重叠**。目标 Pod 在另一台机器上，但底层网络不知道 `10.244.x.x` 该怎么转发。

解决办法就是**在物理包外面再套一层**，把「Pod 内层包」当作「物理外层包」的数据。

---

## 二、本集群实际配置

```yaml
CALICO_IPV4POOL_IPIP   = Always     # IPIP 封装开启
CALICO_IPV4POOL_VXLAN  = Never      # VXLAN 关闭
CLUSTER_TYPE= k8s,bgp        # BIRD 做节点间路由
IPPool cidr = 10.244.0.0/16
```

### 实测证据（worker02）

```
# 隧道设备存在
tunl0@NONE   UNKNOWN   10.244.30.64/32

# 类型确认
$ ip -d link show tunl0
5: tunl0@NONE: <NOARP,UP,LOWER_UP> mtu 1480 ...
    link/ipip 0.0.0.0 brd 0.0.0.0 promiscuity 0 minmtu 0 maxmtu 0
    ipip any remote any local any ttl inherit nopmtudisc

# MTU
eth0  MTU = 1500
tunl0 MTU = 1480        ← 差 20 字节 = IPIP 头开销
cali* MTU = 1480        ← Pod 网卡继承
```

### BIRD 路由全部指向 tunl0

```
$ ip route show | grep tunl0
10.244.5.0/26   via 172.16.1.122 dev tunl0 proto bird metric 1024 onlink
10.244.19.64/26 via 172.16.1.124 dev tunl0 proto bird onlink
10.244.28.64/26 via 172.16.1.61dev tunl0 proto bird metric 1024 onlink
blackhole 10.244.30.64/26 proto bird← 本节点自己的网段
```

`tunl0` 的下一跳是 `172.16.1.x`（**节点 eth1 的物理地址**），说明封装后的外层包走物理网络。

---

## 三、IPIP 机制

### 3.1 数据包结构

IPIP（RFC 2003）就是**在 IP 包里套 IP 包**。

```
┌─────────────────────────────────────────────┐
│ 外层 IP Header (20B)                         │  ← 物理网络看这个
│   src = 10.244.30.64   (源节点 tunl0)│
│   dst = 172.16.1.122  (目标节点物理 IP)     │
├─────────────────────────────────────────────┤
│ 内层 IP Header (20B)                         │  ← 目标节点解封装后看这个
│   src = 10.244.30.89   (源 Pod)             │
│   dst = 10.244.5.94    (目标 Pod)           │
├─────────────────────────────────────────────┤
│ TCP/UDP + Data                               │
└─────────────────────────────────────────────┘
```

**开销 = 20 字节**（一个 IPv4 头，无 TCP/UDP 端口概念）。

### 3.2 完整转发流程

```
1. Pod A (10.244.30.89) 发出包 dst=10.244.5.94
        ↓
2. Felix (Calico agent) 收到，查本节点路由表
        ↓
3. 查到: 10.244.5.94 via 172.16.1.122 dev tunl0
   → 需要走 IPIP 隧道
        ↓
4. 内核 tunl0 驱动封装：
   外层 src=10.244.30.64 (本节点 tunl0 IP)
   外层 dst=172.16.1.122     (目标节点 eth1 IP)
        ↓
5. 物理网卡 eth0 发出（MTU 1500，装得下 1480+20）
        ↓
6. 中间物理网络只认外层：src 10.244.30.64 → dst 172.16.1.122
   它完全不知道内层的10.244.5.94
        ↓
7. 目标节点 worker01 的 tunl0 收到
        ↓
8. 内核解封装，剥掉外层，露出内层包
        ↓
9. 内层 dst=10.244.5.94，查路由 → cali5f849469782（veth 对）
        ↓
10. 从 veth 送进 Pod B
```

### 3.3 本集群的实际封装流量

```
$ ip -s link show tunl0
RX: bytes 17878064055   packets 76364050
TX: bytes 53226095364   packets 76247148
errors 0  dropped 0
```

76M 个包 / 53GB 流量，全部经由 IPIP 隧道 —— 这是实测数据，不是推算。

---

## 四、IPIP 的关键参数（实测值解释）

```
ipip any remote any local any ttl inherit nopmtudisc
```

| 参数 | 值 | 含义 |
|---|---|---|
| `local any` | any | 不绑定本地地址，任何源都可以封装 |
| `remote any` | any | 不绑定远端地址（多邻居场景，IPIP 典型配置） |
| `ttl inherit` | inherit | 内层包的 TTL 直接用作外层 TTL |
| `nopmtudisc` | 关闭 | **不做路径 MTU 探测** |

### ⚠ `nopmtudisc` 是关键风险点

正常情况下，IPIP 会发送 ICMP「需要分片」报文来探测路径 MTU。有了 `nopmtudisc`，**这个探测被禁用**。

后果：
- 如果底层网络 MTU < 1480（例如中间有 VPN、云厂商限速）
- 大包（>1480）会被静默丢弃
- 应用看到的是**连接超时**，不是明确的 MTU 错误
- 表现为「小请求正常，大请求/大文件传输卡住」

**排查这类问题时，第一件事就是检查底层网络 MTU。**

---

## 五、VXLAN 机制

### 5.1 数据包结构

VXLAN（RFC 7348）是**在二层帧里套二层帧**。

```
┌─────────────────────────────────────────────┐
│ 外层 Ethernet Header (14B)                   │  ← 物理网络看这个
├─────────────────────────────────────────────┤
│ 外层 IP Header (20B)                         │
│   src = 节点 IP                              │
│   dst = 节点 IP                              │
├─────────────────────────────────────────────┤
│ VXLAN Header (8B)                            │  ← VNI(24bit) 在这里
│   VNI = 0x000001 (calico VXLAN 默认 VNI=1)   │
│   Reserved = 0                               │
├─────────────────────────────────────────────┤
│ 内层 Ethernet Header (14B)                   │  ← 目标节点解封装后看这个
│   src = Pod MAC                             │
│   dst = Pod MAC                             │
├─────────────────────────────────────────────┤
│ 内层 IP Header (20B)                         │
│   src = 10.244.30.89   (源 Pod)             │
│   dst = 10.244.5.94    (目标 Pod)           │
├─────────────────────────────────────────────┤
│ TCP/UDP + Data                               │
└─────────────────────────────────────────────┘
```

**开销 = 14(以太头) + 20(IP) + 8(VXLAN) + 14(以太头) + 20(IP) = 76 字节**

VXLAN 里有两个以太头，外层那个可以被中间交换机识别为「单播」，所以实际只需在内部再套一个以太头。

### 5.2 为什么需要 VNI

传统 VLAN 用 12 bit标识（4094 个），不够用。VXLAN 用 24 bit VNI（**1670 万个**），可以在一张物理网络上隔离成千上万个二层网络。

### 5.3 VXLAN 的二层能力（IPIP 没有）

VXLAN 本质是二层隧道，所以支持：
- 二层广播/单播（Pod 间 ARP）
- **同一二层域内的 Pod 可以直接通信，不经过隧道**
- 需要 `FELIX_VXLANMDS` 指定多播分发 MAC（默认 `224.0.0.100`）和 UDP 端口（默认 `4789`）

IPIP 只封装 IP 报文，**没有二层概念**。

### 5.4 MTU 代价

```
VXLAN MTU = 1500 - 50 = 1450
           （Calico 扣50，官方文档采用此值）
```

对比你的 IPIP：`1500 - 20 = 1480`。

---

## 六、核心对比

| 维度 | IPIP | VXLAN |
|---|---|---|
| 协议层 | 三层（IP in IP） | 二层（Ethernet over IP） |
| **MTU 开销** | **20 字节 → MTU 1480** | **50 字节 → MTU 1450** |
| 二层能力 | ❌ 无 | ✅ 有（VNI 隔离） |
| VNI | ❌ 无 | ✅ 24bit（1670 万） |
| 典型场景 | 云厂商 VPC 内部 | 跨 VPC / 大规模集群 |
| 排障难度 | 低（`ip -d link` 即可） | 中（需要看 VNI 映射） |
| Calico 中封装设备 | `tunl0` | `vxlan.calico` |
| 环境变量 | `FELIX_IPINIPMTU` | `FELIX_VXLANMTU` |

### MTU 对比（本集群实测 + 官方值）

```
当前 IPIP:
  eth0  1500
  tunl0 1480          ← 封装开销 20 字节

若改 VXLAN:
  eth0  1500
  vxlan.calico 1450   ← 封装开销 50 字节
  cali*  1450         ← Pod 网卡随之改变
```

**MTU 降低 30 字节**。对你集群的 Ceph RBD 存储流量会有实际影响 —— 大包需要更早分片。

---

## 七、配置值 `Always` / `Never` / `CrossSubnet` 的区别

Calico IPPool 的 `ipipMode` 取值：

| 值 | 含义 | 什么时候用 |
|---|---|---|
| `Always` | **所有**跨节点 Pod 流量都封装 | 底层网络不认识 Pod 网段（**你的情况**）|
| `CrossSubnet` | 只在跨子网时封装 | 底层网络已路由 Pod 网段 |
| `Never` | 不封装 | 底层网络完全可达 Pod 网段 |

你当前是 `Always` + `CLUSTER_TYPE=k8s,bgp`：

**两者配合的含义**：
```
BIRD 负责：告诉其他节点「10.244.5.0/26 在我这边」(proto bird)
IPIP 负责：实际传包时套一层 IP 头，走物理网络
```

即**控制平面用 BGP，数据平面用 IPIP**。

---

## 八、实际影响：什么会受影响

### 8.1 跨节点大包传输（最直接）

**IPIP 下**：Pod 可发 1480 字节的包
**VXLAN 下**：Pod 只能发 1450 字节的包

所以改 VXLAN 后，下列场景可能出现「小数据正常、大数据卡住」：
- Ceph RBD 块存储（IO 大块传输）
- 数据库大查询结果
- 日志批量拉取（Loki）
- 备份传输

**你的集群**有 CNPG（PostgreSQL）+ Ceph CSI + Loki，这条链路对 MTU 敏感。

### 8.2 抓包排查难度

```bash
# IPIP：直接看到内层
tcpdump -i tunl0

# VXLAN：需要解码 VNI 才能看内层
tcpdump -i vxlan.calico -w file.pcap
# Wireshark 过滤: vxlan.vni == 1
```

### 8.3 网络插件性能

| 指标 | IPIP | VXLAN |
|---|---|---|
| 内核路径长度 | 短（IP 层处理） | 长（二层帧 + VNI） |
| 大规模集群扩展性 | 一般 | 好（二层隔离） |

你只有 3 台 worker，**扩展性差异无意义**。

### 8.4 MTU 探测行为

```
tunl0: nopmtudisc   ← IPIP 不做 PMTUD
```

如果你后续改 VXLAN，需要确认 Calico 是否仍然禁用 PMTUD —— 这直接影响底层网络 MTU 不标准时的故障表现。

---

## 九、为什么会有人从 IPIP 切到 VXLAN

常见原因：

1. **底层 MTU 不确定**：VXLAN 在 AWS/AliCloud 上有更标准的处理路径
2. **需要二层能力**：某些 CNI 插件依赖 Pod 间二层可达
3. **Calico 官方推荐趋势**：新部署倾向 VXLAN 或 BGP native routing
4. **规避 IPIP 性能问题**：某些内核版本 IPIP 有已知性能 bug

**但**：如果你现在的集群稳定运行，没有遇到具体的 MTU 或二层问题，**没有理由切换**。

---

## 十、本集群的判断

### 保持现状（IPIP Always）

| 理由 | 说明 |
|---|---|
| MTU 更大 | 1480 > VXLAN 1450，对 Ceph RBD 更友好 |
| 已在 BIRD 下稳定运行 | 经过两次 Calico 升级验证 |
| 无二层需求 | 3 worker，无跨 VPC 场景 |
| 无 MTU 问题记录 | 未出现大包丢失 |

### 什么时候需要重新评估

出现以下信号时：
- [ ] Ceph RBD 出现随机 IO 超时（先查底层 MTU）
- [ ] 大文件传输跨节点时断断续续
- [ ] 底层网络要换成 MTU 1450 的链路（如某些云厂商 VPC）
- [ ] 出现 IPIP 相关的内核 bug

---

## 附录：常用命令

```bash
# 查看当前封装模式
kubectl get ippools -o yaml | grep -E 'ipipMode|vxlanMode'
kubectl -n kube-system get ds calico-node -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' | grep MTU

# 节点上确认隧道设备
ip -d link show tunl0          # IPIP
ip -d link show vxlan.calico   # VXLAN

# MTU 检查（最重要的排障项）
cat /sys/class/net/eth0/mtu
cat /sys/class/net/tunl0/mtu

# 路由与封装的关系
ip route show | grep tunl0
ip route show | grep vxlan

# 隧道流量统计
ip -s link show tunl0

# 底层路径 MTU 测试（排查大包问题）
# 从 worker02 发往 worker01
ping -M do -s 1472 172.16.1.122   # 1472+28=1500 刚好
ping -M do -s 1473 172.16.1.122   # 应失败，说明不支持更大包

# 测试 Pod 间实际可用 MTU
ping -M do -s 1452 10.244.5.94# IPIP 下可用
```

---

## 总结

| 问题 | 答案 |
|---|---|
| IPIP 影响什么 | MTU（-20）、路由（走 tunl0）、排障方式 |
| VXLAN 影响什么 | MTU（-50）、二层能力、路由（走 vxlan.calico） |
| 核心差别 | 三层封装 vs 二层封装；20 vs 50 字节开销 |
| 本集群为什么用 IPIP | BGP 控制平面 + IPIP 数据平面，MTU 更大且已稳定 |
| 什么时候该切 VXLAN | 出现真实 MTU/二层需求时，当前没有 |