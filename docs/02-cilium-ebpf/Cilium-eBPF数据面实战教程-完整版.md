# Cilium eBPF 数据面实战教程（完整整合版）

> 由真实三节点 k3s + Cilium 集群的多轮排查整理而成。
> 从四类命令看全 Cilium 网络：**BPF 表**（lb/ipcache/nodeid）、**BPF 挂载点**（bpftool net）、**组件健康**（status）、**概念层**（SLOT/身份/隧道/Headless/IPAM/Cilium vs Calico）。

---

## 目录

1. [环境总览](#1-环境总览)
2. [Service 数据面：bpf lb list](#2-service-数据面bpf-lb-list)
3. [关键概念：SLOT / REVNAT / 0.0.0.0](#3-关键概念slot--revnat--00000)
4. [服务类型：ClusterIP / NodePort / LoadBalancer / HostPort / Headless](#4-服务类型)
5. [端点数据面：bpf ipcache list](#5-端点数据面bpf-ipcache-list)
6. [节点身份：bpf nodeid list 与 cilium_host](#6-节点身份bpf-nodeid-list-与-cilium_host)
7. [BPF 挂载点全景：bpftool net](#7-bpf-挂载点全景bpftool-net)
8. [组件体检报告：cilium-dbg status](#8-组件体检报告cilium-dbg-status)
9. [Pod IP 规划与生产安装](#9-pod-ip-规划与生产安装)
10. [Cilium 与 Calico 实现对照](#10-cilium-与-calico-实现对照)
11. [排障命令速查表](#11-排障命令速查表)
12. [实机穿越实验与 Socket-LB 关键发现](#12-实机穿越实验与-socket-lb-关键发现)
13. [综合结论：完整数据通路](#13-综合结论完整数据通路)

---

## 1. 环境总览

### 1.1 节点与网段

三节点 k3s（默认 Service 网段 10.43.0.0/16），Cilium VXLAN 隧道 + cluster-pool IPAM：

| 节点 | 物理 IP | podCIDR(kubectl) | 数据面实际 Pod 网段 |
|------|--------|------------------|--------------------|
| ubuntu01 | 192.168.67.20x | 10.42.0.0/24 | 10.0.0.0/24 |
| ubuntu02 | 192.168.67.20y | 10.42.1.0/24 | 10.0.1.0/24 |
| ubuntu03 | 192.168.67.203 | 10.42.3.0/24 | 10.0.2.0/24 |

> 文件统一以 ipcache 判定为准：`10.0.0.0/24→.201`、`10.0.1.0/24→本机`、`10.0.2.0/24→.203`；本教程大多数 BPF 表 dump 来自 **eth0=192.168.67.202 的 agent**（IPAM 池 10.0.1.0/24）。

### 1.2 关键提醒：`kubectl exec ds/cilium` 打哪台？

- `ds/cilium` 是 DaemonSet，exec 会选中**某个** cilium-agent Pod
- 输出只代表**它所在节点**；跨节点结论请 exec 到目标节点上的 Pod（或直接在该节点 shell 跑 bpftool）
- 判定"本表属于谁"的三板斧：`eth0 的 IP`（status 里）、identity=1(host) 的条目、NodePort 具体 IP 条目

---

## 2. Service 数据面：`bpf lb list`

### 2.1 格式

```
SERVICE ADDRESS                BACKEND ADDRESS (REVNAT_ID) (SLOT)
```

| 字段 | 含义 |
|------|------|
| SERVICE ADDRESS | Service 虚拟 IP + 端口/协议 |
| BACKEND ADDRESS | 后端 Pod 真实 IP + 端口/协议 |
| REVNAT_ID | 反向 NAT 编号 |
| SLOT | 同地址下的条目槽位 |
| `[标签]` | ClusterIP/NodePort/LoadBalancer/HostPort、non-routable、InternalLocal |

### 2.2 典型条目

```
REVNAT_ID=5
10.43.0.1:443/TCP (0)   0.0.0.0:0 (5) (0) [ClusterIP, non-routable]   ← 定义
10.43.0.1:443/TCP (1)   192.168.67.201:6443/TCP (5) (1)              ← 后端(apiserver)

REVNAT_ID=27                           ← 多后端轮询
10.43.162.164:80/TCP (1)   10.0.1.123:80   (27) (1)
10.43.162.164:80/TCP (2)   10.0.2.178:80   (27) (2)

REVNAT_ID=24/25                        ← NodePort 双视图
0.0.0.0:30080/TCP (1)        10.0.0.17:8081 (24) (1)   [通配入口]
192.168.67.202:30080/TCP (1) 10.0.0.17:8081 (25) (1)   [节点IP入口]

REVNAT_ID=18                           ← LoadBalancer
192.168.67.201:443/TCP (1)   10.0.2.216:8443 (18) (1)

REVNAT_ID=21/22                        ← HostPort
0.0.0.0:80/TCP  (1)   10.0.1.163:80/TCP  (21) (1)
0.0.0.0:443/TCP (1)   10.0.1.163:443/TCP (22) (1)
```

---

## 3. 关键概念：SLOT / REVNAT / 0.0.0.0

### 3.1 `0.0.0.0` 是啥？

- **BACKEND 列的 `0.0.0.0:0`**：SLOT 0 的占位符，表示"该条目无真实后端"，仅登记 Service + REVNAT_ID。**不是任何 Pod/机器**
- **SERVICE 列的 `0.0.0.0:30080`**：**本机任意地址**的通配入口（NodePort/HostPort），数据面语义＝"命中本机任何本地 IP 的包都按此处理"

### 3.2 SLOT 机制

```
lb4_services Key = (Service IP, 端口, 协议, SLOT)
@SLOT 0 → Service 元数据（REVNAT_ID、类型、占位）
@SLOT 1+ → 真实后端
```

转发流程：查 SLOT0 确认服务 → LB 哈希选后端 → 查 SLOTn 得目标 → DNAT 并记录 REVNAT，回包还原。

> **不是"前端/后端"两种服务**；是同一地址下不同 Key 的条目。

### 3.3 为什么条目不按 Service 连续？

直接遍历 BPF 哈希表，顺序由**哈希桶**决定。同 Service 的条目**散落各处**，判定分组只能靠 `REVNAT_ID + SLOT`，不能靠行序。清晰视图：`cilium-dbg service list`。

### 3.4 NodePort 为什么有两个 REVNAT？

同一 K8s SVC 会拆成多个 frontend，**每个 frontend 独立一个 REVNAT_ID**：

| REVNAT | 入口 | 含义 |
|--------|------|------|
| 24 | `0.0.0.0:30080` | 通配入口（non-routable） |
| 25 | `192.168.67.202:30080` | 节点 IP 入口 |

后端相同 → **同一个 SVC 的两个视图**，不是两个服务。

---

## 4. 服务类型

### 4.1 NodePort vs HostPort

| | NodePort | HostPort |
|---|---|---|
| 定义处 | **Service** 级别 | **Pod** 级别 |
| 生效 | **所有节点**都监听 | **只有 Pod 所在节点** |
| 转发 | 负载均衡到任意后端 | 直连本机那个 Pod |
| 端口 | 30000-32767 | 任意 |

```
访问 任意节点IP:31124  ✔ NodePort 通
访问 10.0.1.163所在节点:80 ✔ HostPort 通
访问 其他节点:80         ✘
```

### 4.2 Headless Service

- `clusterIP: None`：无 VIP/LB，DNS 直接返回**全部 Pod IP**
- 适用：① StatefulSet 稳定标识（Kafka/ES/MongoDB 成员发现）② 客户端要全量后端（Prometheus 按 pod 抓取）③ 无 selector 指向集群外资源（Endpoints 手动描）④ 精确连接指定副本
- 数据面标志：lb 表出现 `0/ANY`、无后端、`non-routable`（Cilium 不需要为它们做 LB）
- 验证：`kubectl get svc -A | grep None`
- **不要用**：无状态应用需要稳定 VIP + 自动故障转移时

---

## 5. 端点数据面：`bpf ipcache list`

### 5.1 字段

```
IP ... identity=安全ID encryptkey=加密密钥 tunnelendpoint=隧道路由 flags
```

| 字段 | 含义 |
|------|------|
| identity | 安全身份 ID（策略依据） |
| tunnelendpoint | 隧道目标节点物理 IP；`0.0.0.0`=本机 |
| flags=hastunnel | 需 VXLAN 封装；`<none>`=本地直达 |
| encryptkey | IPsec 密钥索引；全 0=未加密 |

### 5.2 保留 identity 速查

| identity | 含义 | 本案例 |
|----------|------|--------|
| 1 | host（本机） | 192.168.67.202、10.0.1.33 |
| 2 | world | 0.0.0.0/0 |
| 4 | health（健康端点） | 10.0.0.80 / 10.0.1.130 / 10.0.2.87 |
| 6 | remote-node | 192.168.67.203、10.0.0.37、10.0.2.70 |
| 7 | kube-apiserver | 192.168.67.201 |
| ≥256 | 工作负载身份 | 由 Pod 标签生成 |

### 5.3 hastunnel 是"相对导出表的那台节点"说的

```
（.202 导出的表）
10.0.2.216/32  tunnelendpoint=192.168.67.203 flags=hastunnel
              ↑ Pod 在 .203，但从 .202 看要 VXLAN 过去
192.168.67.203/32  flags=<none>   ← 物理IP近距离直连，不隧道
10.0.1.123/32      flags=<none>   ← 本机 Pod，直投
```

**排障高频坑**：`kubectl get nodes` 的 podCIDR（10.42.x）≠ 数据面（10.0.x），**ipcache 才是权威**。

---

## 6. 节点身份：`bpf nodeid list` 与 cilium_host

### 6.1 nodeid 表

```
0x3cba  192.168.67.201  0   ← 节点(.201)物理IP + 内部路由IP 10.0.0.37
0x1903  192.168.67.203  0   ← .203 + 10.0.2.70
0xc960  192.168.67.202  0   ← .202(本机) + 10.0.1.33
```

- 给节点发全局唯一"身份证号"（三台节点表一致）
- 用途：隧道元数据带 node id 供收端归源；IPsec 时按 id/SPI 找解密 SA
- SPI=0 → 未启用加密（与 encryptkey=0、status Encryption: Disabled 三方一致）

### 6.2 cilium_host：节点的"集群内网关网口"

| 节点 | 物理 IP | cilium_host |
|------|--------|-------------|
| ubuntu01 | .201 | 10.0.0.37 |
| ubuntu02 | .202 | 10.0.1.33 |
| ubuntu03 | .203 | 10.0.2.70 |

作用：
1. **本机 Pod 默认网关**（.202 上 Pod 的 `default via 10.0.1.33`）
2. **宿主机访问 Pod 网的桥梁**
3. **BPF 挂载点 + 身份载体**（本机 host=1，远端 remote-node=6）

示例（.202 → .203 的 10.0.2.216）：

```
源Pod → GW 10.0.1.33(cilium_host) → 路由:10.0.2.0/24 via cilium_vxlan
     → VXLAN封装(外层到 .203, 带nodeid 0x1903) → .203 解封装 → 直送 Pod
```

验证：`ip addr show cilium_host`、`ip route | grep 10.0.`、`cilium-dbg endpoint list`、Pod 内 `ip route`。

---

## 7. BPF 挂载点全景：`bpftool net`

### 7.1 输出解读

`bpftool net` 列出**每个网络接口上挂了哪些 eBPF 程序**。Cilium 用 **TCX**（新一代 tc 挂载，经 bpf_link 管理，有 prog_id/link_id）：

```
eth0(2)     tc/ingress cil_from_netdev  prog_id 436 link_id 19
eth0(2)     tc/egress  cil_to_netdev    prog_id 440 link_id 20
tailscale0(3) tc/ingress cil_from_netdev  prog_id 452 link_id 21
tailscale0(3) tc/egress  cil_to_netdev    prog_id 447 link_id 22
cilium_net(4)   tc/ingress cil_to_host    prog_id 423 link_id 18
cilium_host(5)  tc/ingress cil_to_host    prog_id 417 link_id 16
cilium_host(5)  tc/egress  cil_from_host  prog_id 415 link_id 17
cilium_vxlan(6) tc/ingress cil_from_overlay prog_id 402 link_id 14
cilium_vxlan(6) tc/egress  cil_to_overlay   prog_id 400 link_id 15
lxc_health(8)   tc/ingress cil_from_container prog_id 525 link_id 29
lxcXXXX...×6    tc/ingress cil_from_container ...
```

### 7.2 各接口职责（Cilium 的"钩子语义"）

| 接口 | 方向/程序 | 职责 |
|------|-----------|------|
| eth0 | from/to_netdev | 物理出入口：接管所有进出本机的包（含 NodePort 入站、出外网） |
| tailscale0 | from/to_netdev | **Tailscale 虚拟网卡也被接管**（本机装了 tailscale，属于 netdev 域） |
| cilium_net | to_host | host 路径的一个伪设备收口 |
| cilium_host | to_host / from_host | 节点↔Pod 双向 |
| cilium_vxlan | from/to_overlay | VXLAN 隧道解封装/封装 |
| lxc_health | from_container | 健康端点（identity=4） |
| lxc_* ×6 | from_container | 每个 Pod 的 veth host 端收口 |

**核心机制**：数据面不是"一个集中程序"，而是**每个出入口一个"方向性"钩子**（`from_`=进入处理域，`to_`=离开），任何包走到某个口都被对应程序拦截，完成**分域、身份打标、LB、策略**后再放行或转发。

### 7.3 与前面内容的相互印证

- **6 个 lxc + lxc_health = 7 个端点接口** ↔ status 的 `IPAM 6/254` ↔ ipcache 的健康端点（每节点 1 个）
- **cilium_vxlan 的 from/to_overlay** ↔ ipcache 的 `hastunnel`（走隧道）
- **tcx** ↔ status 的 `Attach Mode: TCX`

### 7.4 注意点

- Tailscale 流量也过 Cilium netdev 管线：若配了 host 防火墙或 LB 规则要注意边界（本例 host firewall 关闭）
- `prog_id/link_id` 是内核 BPF 对象句柄，可拿 `bpftool prog show id 436` / `bpftool link show id 19` 深挖

---

## 8. 组件体检报告：`cilium-dbg status`

### 8.1 逐项解码（本例值 → 含义）

| 字段 | 本例值 | 原理/含义 |
|------|--------|----------|
| KVStore | Disabled | 不用 etcd，数据源=K8s CRD（单集群；Cluster Mesh 才需要 kvstore） |
| Kubernetes | Ok 1.36.4+k3s1 | 与 apiserver 连通、版本身份 |
| APIs | CiliumNode/CiliumEndpoint… | agent 监听的下发资源 |
| KubeProxyReplacement | True [eth0 192.168.67.202 Direct Routing] | **完全接管 kube-proxy**；NodePort 用直连路由（非 DSR）；内含 `Socket LB: Enabled (Coverage: Full)`，ClusterIP 在 connect() 时选后端（见 §12.3） |
| Host firewall | Disabled | 不对宿主机流量做策略 |
| Cilium | 1.20.1 | agent 版本 |
| IPAM | IPv4: 6/254 from 10.0.1.0/24 | **本机 Pod 池=10.0.1.0/24**，6 个已分配 = bpftool 里 6 个 lxc |
| Routing | Network: Tunnel[vxlan] / Host: Legacy | Pom 流量走 VXLAN；宿主机走标准内核路由（非 eBPF 原生） |
| Attach Mode / Device Mode | TCX / veth | 挂载方式 TCX；端点用 veth |
| Masquerading | IPTables [IPv4: Enabled] | Pod 出外网 SNAT 走 iptables（非 BPF masq） |
| Global Identity Range | min 256 max 65535 | **工作负载身份从 256 起**（保留身份 0-255），解释 ipcache 大数字（51260 等） |
| Proxy | ip 10.0.1.33, Envoy: external | L7 代理绑定在 cilium_host IP 上 |
| Hubble | Ok, Flows 4095/4095 (100%) | **流缓冲区已用满**，监控有丢流风险（建议调 `hubble.eventBufferCapacity`） |
| Encryption | Disabled | 无加密（与 encryptkey=0、SPI=0 三省一致） |
| Cluster health | 3/3 reachable | 三节点 health 探测全通（每节点 1 个 lxc_health=identity4） |

### 8.2 status 回答的是什么层面？

```
bpf lb list    → 数据面"Service 分发"表
bpf ipcache    → 数据面"身份+路由"表
bpf nodeid     → 数据面"节点身份"表
bpftool net    → 数据面"程序挂载"在哪
cilium-dbg status → 组件/参数层"体检报告"
kubectl get nodes/pods → 上层控制面事实
```

**排障顺序建议**：先 `status`（区分"组件坏"）→ 再 `bpftool net`（程序在不在）→ 再钻三张 BPF 表（数据对不对）→ 最后 kubectl 对上命名。

---

## 9. Pod IP 规划与生产安装

### 9.1 结论：节点拿哪段是"自动的"，大段/掩码是"安装时配的"

**k3s 层（kubectl 看到的 10.42.x）**：默认 `--cluster-cidr=10.42.0.0/16`，节点按**加入顺序**自动分 /24（ubuntu01→0、02→1、03→3）；`10.42.2.0/24` 空缺＝被删节点"用过不回收"。

**Cilium 层（ipcache 实际走的 10.0.x）**：`ipam.mode=cluster-pool` 从 `--cluster-pool-ipv4-cidr`（默认 10.0.0.0/16）按 `--cluster-pool-ipv4-mask-size`（默认 24）**自动给每节点分 /24**。

> 因此 ipcache 显示 `10.0.0.0/24→.201、10.0.1.0/24→本机、10.0.2.0/24→.203` 是按加入顺序自动分配的。

### 9.2 两层分配易"名实不符"

`kubectl get nodes` 的 podCIDR(10.42.x) 是上层分配；`ipcache` 是数据面实际(10.0.x)。**以 ipcache 为准**。核对命令：

```bash
sudo cat /etc/rancher/k3s/config.yaml
kubectl -n kube-system get cm cilium-config -o yaml | grep -iE 'ipam|cidr'
kubectl get node ubuntu01 -o jsonpath='{.metadata.annotations.io\.cilium\.network\.ipv4-pod-cidr}'
```

### 9.3 生产安装（k3s + Cilium）

前提：内核 ≥5.10 + BTF + cgroup2 + `/sys/fs/bpf`；k3s 关掉 `--flannel-backend=none --disable-network-policy`（可加 `--disable-kube-proxy`）。

```bash
k3s server --flannel-backend=none --disable-kube-proxy --disable-network-policy \
  --cluster-cidr=10.0.0.0/16 --service-cidr=10.43.0.0/16

helm install cilium cilium/cilium -n kube-system \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16 \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set kubeProxyReplacement=strict \
  --set routingMode=tunnel --set tunnelProtocol=vxlan
```

### 9.4 避坑清单

| 坑 | 说明 |
|----|------|
| CIDR 不可变 | 上线后改=全重建，安装前定死 |
| 掩码=单节点容量 | /24≈254 Pod/节点 |
| 两层 CIDR 对齐 | k3s 与 Cilium 不一致→"名实不符" |
| 加密 | 需要时开 IPsec/WireGuard（本例 Disabled） |
| MTU | VXLAN≈1450，native=1500 |
| Hubble 上限 | 4095 满会丢流，调大 buffer |
| 有状态应用 | Pod IP 可变，用 Headless+稳定名 |
| hostPort 与 NodePort | 别在同一端口打架（30000-32767） |

---

## 10. Cilium 与 Calico 实现对照

| 概念 | Cilium | Calico |
|------|--------|--------|
| 身份 | 16 位数字 identity 带在包元数据 | 无带内身份，按源 IP 查 IP 集合（felix 预编译规则） |
| IP→隧道 | bpf ipcache 预缓存 | Linux 路由表 + BIRD/BGP 通告 |
| 节点路由口 | cilium_host（Pod 网段内 IP 作网关） | veth host 端固定 169.254.1.1 |
| 节点身份 | bpf nodeid（16 位 + SPI） | 无；外层 IP 即节点，加密用 WireGuard 公钥 |
| 隧道 | VXLAN（带 nodeid/identity） | IPIP(tunl0)/VXLAN，外层普通 IP |
| 数据面 | 全 eBPF | 默认 iptables/IPvs，可选 eBPF |
| IPAM | cluster-pool 分 /24 | IPPool 分 /26 块 |

命令翻译表：

| Cilium 命令 | Calico 对应 |
|------------|------------|
| `bpf lb list` | `iptables -t nat -L -n`（iptables 模式） |
| `bpf ipcache list` | `calicoctl node status` / `bird n s` / `ip route` |
| `bpf nodeid list` | 无；`calicoctl node status` + `wg show` |
| identity 查询 | 无数字身份；`calicoctl get profiles` |

> 选择：要身份精细化+全 eBPF→Cilium；要简单直观、运维认路由表→Calico。

---

## 11. 排障命令速查表

```bash
# Service 面
cilium-dbg bpf lb list
cilium-dbg service list

# 端点/身份/路由面
cilium-dbg bpf ipcache list
cilium-dbg bpf nodeid list
cilium-dbg endpoint list
cilium-dbg identity list

# 挂载点与体检
bpftool net                            # 或 bpftool prog/link show
cilium-dbg status

# K8s 层
kubectl get svc -A | grep None         # headless
kubectl get pod -A -o wide | grep <ip> # IP→节点
kubectl get node -o wide               # podCIDR/真实角色
```

---

## 12. 实机穿越实验与 Socket-LB 关键发现

> 实验设计与判据：`/root/实验-Hubble-LB-ipcache-tcpdump穿越跟踪.md`；证据归档：`/root/experiment/`（pcaps/ + mon/ + 基线表）。

### 12.1 实验对象（本环境实测值）

- 主服务 `default/nginx` 10.43.66.133:80 → 后端 10.0.2.93:80（@.203，revnat=23，slot1）
- 客户端 `lab/api-…` 10.0.1.137@.202（identity **8219**，endpoint 1817；httpd:alpine，无 curl 用 wget）
- 后端 identity **30056**（endpoint 1393）；变体 A：`lab/web` 10.43.162.164:80 → 10.0.1.123(本地.202)+10.0.2.178(远端.203)，identity **14608**

### 12.2 四证据面采集与判据对照

| 证据面 | 命令 | 实测命中 |
|--------|------|----------|
| 静态表 | `cilium-dbg bpf lb list` / `bpf ipcache list` | 10.43.66.133:80 slot1→10.0.2.93 revnat23；10.0.2.93 `tunnelendpoint=192.168.67.203 hastunnel` |
| 抓包 | tcpdump × 7 路（外层 eth0 / 内层 vxlan / 两端 veth / host口） | 外层 `202→203:8472` VXLAN；内层 `10.0.1.137→10.0.2.93:80` SYN seq/TS 在.**202 出口与 .203 入口逐字节一致**（同包穿隧道）；回程 SYN-ACK seq 三处一致闭环 |
| 内核事件 | `cilium-dbg monitor -j -t trace -t drop --related-to <endpointID>` | .202 `to-overlay if=cilium_vxlan 8219→30056` → .203 `to-endpoint if=lxc91308…` → .203 `to-overlay` 回 → .202 `to-endpoint if=lxc2a450…`（identity 与 ipcache 吻合） |
| 负向验证 | tcpdump in host 栈 | **cilium_host 口 0 包**：远端后端流量全程 BPF 数据面（from-container→overlay→to-container），不上 host 协议栈 |

### 12.3 核心发现：Socket-LB（socket 层负载均衡）

**铁证**：`nsenter` 进容器网络栈抓 eth0 + pod 内 `netstat`：

```
tcp  0  0 10.0.1.137:42413  10.0.2.93:80  ESTABLISHED
```

应用执行 `nc 10.43.66.133 80`，但内核 socket 实际连的是 **10.0.2.93:80**；容器内 tcpdump（s202_inside.pcap）看到 SYN/SYN-ACK 也全是后端地址。`cilium-dbg status` 佐证：`Socket LB: Enabled, Coverage: Full`。

机制：`connect()/sendmsg` 系统调用点绑定的 eBPF 直接查 `lb4_services` map **选中后端并把 socket 连过去**——包从出生起就带着后端地址，与 kube-proxy 完全不同：

| | Cilium Socket-LB（本集群实测） | kube-proxy (iptables/ipvs) |
|---|---|---|
| 翻译时机 | connect() 调用点，发包前 | 包发出后 per-packet 走 netfilter |
| 数据面开销 | 无 DNAT / revSNAT / conntrack | 每个包查规则链 + 建 conntrack |
| 应用看到 | 应用以为连 ClusterIP，**内核 socket/capture 都显示后端 IP** | 应用/socket 是 ClusterIP，**tcpdump 才显示后端 IP** |
| TCP 握手 | 直接和真实后端完成 | DNAT 后完成，需回程还原 |

**排障含义**：在 Cilium 下任何抓包点都看不到 ClusterIP 是**正常现象**；别拿"没看见 ServiceIP"当故障。判定链路成败改用：两端 veth/隧道口的四元组 + monitor 事件的 identity 对上 ipcache。

### 12.4 变体 A：同/跨节点路径差异（monitor 佐证）

- 本地后端 10.0.1.123 回包 `to-endpoint`（同节点 veth 直投，**无隧道**）
- 远端后端 10.0.2.178 走 `to-overlay`（VXLAN 封装）
- 结论：同节点存在免隧道直通路径，跨节点才上隧道——与 ipcache 的 `hastunnel`/`<none>` 标签一一对应

### 12.5 本实验踩过的坑（复用要点）

- `cilium-dbg monitor` 无 `--output`，用 `-j`；trace 事件默认不收，须 `-t trace -t drop`
- pod 内 `pkill -f "cilium-dbg monitor"` 会误杀自己 → 用 `pkill -x cilium-dbg`
- `kubectl exec ds/cilium` 落点随机 → 按节点 pod 名（cilium-98vtn/cilium-wz8bj）执行
- tcpdump 后台跨 ssh 断开即死 → 单条 ssh 会话内 `timeout 10 tcpdump … &` 同步发流量
- Hubble buffer 100%（4095/4095 满）时实时追踪改用 `cilium-dbg monitor`

---

## 13. 综合结论：完整数据通路

### 12.1 数据通路全景

```
入口 ClusterIP / NodePort / LoadBalancer / HostPort
  │
① bpf lb list      虚拟IP → 后端Pod IP（REVNAT/SLOT 分发；**Socket-LB 在 connect() 时选后端**，intra-cluster 无 per-packet DNAT）
  │
② bpf ipcache      IP → identity(谁) + tunnelendpoint(往哪封装)
  │
③ bpf nodeid       node id → 物理IP + cilium_host(隧道归源/加密)
  │
④ bpftool net      各出口挂载 from/to 钩子(分域/LB/策略)
  │
VXLAN 隧道 → 目标节点 → 本机直投 / cilium_host 网关 → Pod
```

### 12.2 本案例最终画像

- **网络模式**：k3s + Cilium 1.20，VXLAN 隧道，cluster-pool IPAM，TCX 挂载，KPR 开启（Direct Routing），MASQ 走 iptables，**未加密**
- **节点分工**：`.201`＝控制平面（identity=7 apiserver、CoreDNS 10.0.0.4、NodePort 后端 10.0.0.17）；`.202`＝本表节点（本地交付 10.0.1.x，cilium_host 10.0.1.33）；`.203`＝核心业务主力（10.0.2.216 承载几乎全部 LB/NodePort 流量）
- **两张自动地址分配**：k3s 上层 10.42.x（可查） / Cilium 数据面 10.0.x（权威）
- **判断准则**：看服务分发用 lb list、看归属/身份用 ipcache+identity、看节点用 nodeid、看程序挂载用 bpftool net、看组件用 status——**数据面三表＋挂载点＋status，缺一不可**