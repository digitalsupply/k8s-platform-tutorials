# Cilium 数据面实战教程：从 `bpf lb list / ipcache / nodeid` 看到 eBPF 网络全貌

> 本教程由一次真实三节点 k3s + Cilium 集群的排查整理而成，覆盖：
> Service/负载均衡数据面、身份与路由数据面、节点身份、Pod IP 规划、Headless/NodePort/HostPort 概念，以及 Cilium 与 Calico 的实现对照。

---

## 目录

- [第 1 章 环境总览](#第-1-章-环境总览)
- [第 2 章 Service 数据面：`bpf lb list`](#第-2-章-service-数据面bpf-lb-list)
- [第 3 章 关键概念：SLOT / REVNAT / 0.0.0.0](#第-3-章-关键概念slot--revnat--00000)
- [第 4 章 服务类型：ClusterIP / NodePort / LoadBalancer / HostPort / Headless](#第-4-章-服务类型clusterip--nodeport--loadbalancer--hostport--headless)
- [第 5 章 端点数据面：`bpf ipcache list`](#第-5-章-端点数据面bpf-ipcache-list)
- [第 6 章 节点身份：`bpf nodeid list` 与 cilium_host](#第-6-章-节点身份bpf-nodeid-list-与-cilium_host)
- [第 7 章 Pod IP 规划：自动分配还是安装时配置？](#第-7-章-pod-ip-规划自动分配还是安装时配置)
- [第 8 章 Cilium 与 Calico 的实现对照](#第-8-章-cilium-与-calico-的实现对照)
- [第 9 章 排障命令速查表](#第-9-章-排障命令速查表)
- [第 10 章 综合结论：完整数据通路](#第-10-章-综合结论完整数据通路)

---

## 第 1 章 环境总览

### 1.1 节点与网段

三节点 k3s 集群（k3s 默认 Service 网段 10.43.0.0/16）：

| 节点 | 物理 IP | podCIDR(kubectl) | 数据面实际 Pod 网段 |
|------|--------|------------------|--------------------|
| ubuntu01 | 192.168.67.201 | 10.42.0.0/24 | 10.0.0.0/24 |
| ubuntu02 | 192.168.67.202 | 10.42.1.0/24 | 10.0.1.0/24 |
| ubuntu03 | 192.168.67.203 | 10.42.3.0/24 | 10.0.2.0/24 |

### 1.2 基础判定方法

- **`kubectl exec ds/cilium` 钻进的是某个 cilium-agent Pod**（DaemonSet 每节点一个），输出的 BPF 表只代表**它所在节点**
- 从表中 `0.0.0.0:xxx` 的本机监听条目、或 identity=1(host) 的 IP，可反推 **本表属于哪台节点**（本案例 = ubuntu02/.202）
- 要查某节点，就 exec 进那台节点上的 cilium pod

```bash
kubectl -n kube-system get pod -o wide -l k8s-app=cilium
kubectl -n kube-system exec <对应节点上的cilium-pod> -- cilium-dbg bpf lb list
```

---

## 第 2 章 Service 数据面：`bpf lb list`

### 2.1 输出格式

```
SERVICE ADDRESS                BACKEND ADDRESS (REVNAT_ID) (SLOT)
  虚拟服务地址(前端)              真实后端地址    (反向NAT ID)  (槽位号)
```

| 字段 | 含义 |
|------|------|
| SERVICE ADDRESS | Service 虚拟 IP（ClusterIP/NodePort/LoadBalancer）+ 端口/协议 |
| BACKEND ADDRESS | 后端 Pod 真实 IP + 端口/协议 |
| REVNAT_ID | 反向 NAT 编号 |
| SLOT | 同地址下的条目槽位 |
| `[标签]` | Service 类型：ClusterIP/NodePort/LoadBalancer/HostPort、non-routable、InternalLocal |

### 2.2 常见条目分类

**ClusterIP → 单后端（kubernetes/apiserver）**

```
REVNAT_ID=5
10.43.0.1:443/TCP (0)   0.0.0.0:0 (5) (0) [ClusterIP, non-routable]
10.43.0.1:443/TCP (1)   192.168.67.201:6443/TCP (5) (1)
```

**ClusterIP → 多后端（负载均衡）**

```
REVNAT_ID=27
10.43.162.164:80/TCP (0)   0.0.0.0:0 (27) (0)
10.43.162.164:80/TCP (1)   10.0.1.123:80/TCP (27) (1)
10.43.162.164:80/TCP (2)   10.0.2.178:80/TCP (27) (2)
```

**NodePort（通配入口 + 节点 IP 入口 两个视图）**

```
REVNAT_ID=24 / 25
0.0.0.0:30080/TCP (0)          0.0.0.0:0 (24) (0) [NodePort, non-routable]
0.0.0.0:30080/TCP (1)          10.0.0.17:8081/TCP (24) (1)
192.168.67.202:30080/TCP (0)   0.0.0.0:0 (25) (0) [NodePort]
192.168.67.202:30080/TCP (1)   10.0.0.17:8081/TCP (25) (1)
```

**LoadBalancer + HostPort + headless(0/ANY 占位)**

```
192.168.67.201:443/TCP (0)  0.0.0.0:0 (18) (0) [LoadBalancer]   ← 占位无后端
192.168.67.201:443/TCP (1)  10.0.2.216:8443/TCP (18) (1)
0.0.0.0:80/TCP (0)          0.0.0.0:0 (21) (0) [HostPort, non-routable]
0.0.0.0:80/TCP (1)          10.0.1.163:80/TCP (21) (1)
10.43.66.133:0/ANY (0)      0.0.0.0:0 (0) (0) [ClusterIP, non-routable]   ← headless
```

---

## 第 3 章 关键概念：SLOT / REVNAT / 0.0.0.0

### 3.1 `0.0.0.0` 是什么？

**不是 Pod、不是机器，是"占位/通配"**：

- 在 BACKEND 列（`0.0.0.0:0`）：SLOT 0 条目的占位，表示"本条目无真实后端"，仅登记 Service 与 REVNAT_ID
- 在 SERVICE 列（`0.0.0.0:30080`）：**本机任意地址**的通配入口（NodePort/HostPort 使用），数据面语义为"命中本机任意本地地址的包都按此处理"

### 3.2 SLOT 0 与 SLOT 1 的关系

不是"前端/后端"两回事，而是**同一 Service 地址下的不同 BPF Map Key**：

```
lb4_services 的 Key = (Service IP, 端口, 协议, SLOT)

@ SLOT 0 → Service 元数据（REVNAT_ID、类型标志、0.0.0.0:0 占位）
@ SLOT 1+ → 真实后端地址
```

数据包转发流程：

```
包 → 查 SLOT 0（确认 Service、拿 REVNAT_ID）
   → 负载均衡哈希选后端
   → 查 SLOT N 得真实目标
   → DNAT 转发，REVNAT_ID 记入 conntrack，回包还原
```

### 3.3 为什么同一 Service 的条目不连续显示

`bpf lb list` 直接遍历 BPF 哈希表，顺序由**内部哈希桶**决定，与逻辑无关。判断分组**不能靠行序**，只能靠 REVNAT_ID + SLOT。想要清晰分组用 `cilium-dbg service list`。

### 3.4 为什么 NodePort 有两个 REVNAT（24/25）

同一 K8s SVC 会生成多个 frontend 实例，**每个 frontend 独立分配 REVNAT_ID**：

| REVNAT | Frontend | 含义 |
|--------|----------|------|
| 24 | `0.0.0.0:30080` | 通配：本机任意 IP 监听（non-routable） |
| 25 | `192.168.67.202:30080` | 节点指定 IP 监听 |

后端完全相同（10.0.0.17:8081）→ 仍是**同一个 SVC 的两个入口视图**，不是两个服务。

---

## 第 4 章 服务类型：ClusterIP / NodePort / LoadBalancer / HostPort / Headless

### 4.1 NodePort vs HostPort

| | NodePort | HostPort |
|---|---|---|
| 定义位置 | **Service** 级别 | **Pod** 级别（container.ports.hostPort） |
| 生效范围 | **所有节点**都监听 | **只有 Pod 所在节点** |
| 转发 | 负载均衡到任意后端 | 直连本机那个 Pod |
| 端口范围 | 30000-32767 | 任意 |

```
访问 任意节点IP:31124  ✔ NodePort 任意节点都通
访问 10.0.1.163 所在节点:80 ✔ HostPort
访问 其他节点:80         ✘
```

### 4.2 Headless Service

- 定义：`clusterIP: None`，无 VIP、无 LB，DNS 直接返回全部 Pod IP
- 适用场景：
  1. **StatefulSet 稳定标识**（Kafka/ES/MongoDB 成员发现）：`pod-name.headless.svc` 返回固定 Pod IP
  2. **客户端要拿全量后端**（Prometheus 按 Pod 逐个抓取）
  3. **无 selector 指向集群外资源**（Endpoints 手动定义外部 IP）
  4. **业务精确连接指定副本**
- 数据面标志：lb 里表现为 `0/ANY`、无后端、`non-routable`
- 反向判断：`kubectl get svc -A | grep None`

什么时候**不要**用 headless：需要稳定 VIP、自动故障转移的无状态应用。

---

## 第 5 章 端点数据面：`bpf ipcache list`

### 5.1 字段含义

```
IP ... identity=安全ID  encryptkey=加密密钥  tunnelendpoint=隧道路由  flags
```

| 字段 | 含义 |
|------|------|
| identity | 安全身份 ID，策略的依据 |
| tunnelendpoint | 隧道模式下目标所属节点物理 IP；`0.0.0.0`=本机 |
| flags=hastunnel | 需经 VXLAN 隧道到达；`<none>`=本地直达 |
| encryptkey | IPsec 密钥索引；全 0 = 未启用加密 |

### 5.2 保留 identity 速查

| identity | 含义 | 本案例对应 |
|----------|------|-----------|
| 1 | host（本机节点） | 192.168.67.202、10.0.1.33 |
| 2 | world | 0.0.0.0/0 |
| 4 | health（节点健康端点） | 10.0.0.80 / 10.0.1.130 / 10.0.2.87 |
| 6 | remote-node（远端节点） | 192.168.67.203、10.0.0.37、10.0.2.70 |
| 7 | kube-apiserver | 192.168.67.201 |
| 其它 | 工作负载自定义身份 | 由 Pod 标签自动生成 |

### 5.3 hastunnel 的视角问题（排障高频疑问）

`flags=hastunnel` 是**相对导出这张表的节点**说的，不是相对 Pod 所在节点：

```
（.202 导出的表）
10.0.2.216/32   tunnelendpoint=192.168.67.203 flags=hastunnel
              ↑ 认识：Pod 在 .203，但从 .202 看必须 VXLAN 封装过去

同一张表：
192.168.67.203/32   tunnelendpoint=0.0.0.0 flags=<none>   ← 物理IP直连，不隧道
10.0.1.123/32       tunnelendpoint=0.0.0.0 flags=<none>   ← 本机Pod，直投
```

三种"无隧道"：本机 Pod（直接投递）、相邻物理 IP（二层可达）。

### 5.4 identity 相同 = 同一部署副本

```
identity=7721 → 10.0.1.163(本机) + 10.0.2.179(.203) + 10.0.0.38(.201)
              → 每节点一份 → 类似 DaemonSet
identity=14608 → 10.0.1.123(.202) + 10.0.2.178(.203) → 跨节点 Deployment
```

不跑 kubectl 也能从身份数字还原出"哪些 Pod 属于同一工作负载"。

---

## 第 6 章 节点身份：`bpf nodeid list` 与 cilium_host

### 6.1 nodeid：给节点发"身份证号"

```
0x3cba  192.168.67.201  0   ← ubuntu01（物理IP + 内部IP 10.0.0.37）
0x1903  192.168.67.203  0   ← ubuntu03（+ 10.0.2.70）
0xc960  192.168.67.202  0   ← ubuntu02（+ 10.0.1.33）
```

| 字段 | 含义 |
|------|------|
| NODE ID | 节点全局唯一编号（三台节点表一致） |
| IP ADDRESSES | 物理 IP + 集群内路由 IP |
| SPI | IPsec 安全参数索引，0=未启用加密 |

**用途**：隧道元数据里带 node id 供收端快速归源；IPsec 时按 node id/SPI 查解密 SA。它把"节点多 IP"归并成一个 ID，比逐条比 IP 更快。

### 6.2 cilium_host：节点在集群网内的"网关网口"

| 节点 | 物理 IP | cilium_host IP |
|------|--------|---------------|
| ubuntu01 | 192.168.67.201 | 10.0.0.37 |
| ubuntu02 | 192.168.67.202 | 10.0.1.33 |
| ubuntu03 | 192.168.67.203 | 10.0.2.70 |

作用：
1. **本机 Pod 的默认网关**：`.202` 上 Pod 的默认路由都是 `via 10.0.1.33`
2. **宿主机访问 Pod 网络的桥梁**
3. **BPF 挂载点与身份载体**：本机=identity 1(host)，远端=identity 6(remote-node)

转发示例（.202 → .203 的 10.0.2.216）：

```
源Pod → 网关 10.0.1.33(cilium_host)
     → 路由表: 10.0.2.0/24 via cilium_vxlan
     → VXLAN封装(外层到 .203, 带 node id 0x1903)
     → .203 解封装 → 直送 Pod
```

验证命令：

```bash
ip addr show cilium_host
ip route | grep -E '10\.0\.'
cilium-dbg endpoint list | grep -E 'host|remote'
kubectl exec -it <pod> -- ip route
```

---

## 第 7 章 Pod IP 规划：自动分配还是安装时配置？

### 7.1 结论：节点拿哪段是"自动的"，但"大段/掩码"是安装时配的

**k3s 默认（`kubectl get nodes` 看到的 10.42.x.x）**

```
--cluster-cidr 默认 10.42.0.0/16，-service-cidr 默认 10.43.0.0/16
节点加入时由内置 controller 按顺序自动分 /24：
ubuntu01→10.42.0.0/24  ubuntu02→10.42.1.0/24  ubuntu03→10.42.3.0/24
```

**10.42.2.0/24 为何空缺**：分配器"用过不回收"，曾占用的节点被删后不再原地复用 → 节点网段不代表邻居关系。

**Cilium 层（ipcache 实际走的 10.0.x.x）**

| ipam.mode | 分配来源 |
|-----------|---------|
| cluster-pool（默认） | 从 `--cluster-pool-ipv4-cidr`（默认 10.0.0.0/16）按 `--cluster-pool-ipv4-mask-size`（默认 24）自动分 /24 |
| kubernetes | 直接消费 node.spec.podCIDR |

本案例 `10.0.0.0/24→.201、10.0.1.0/24→本机(.202)、10.0.2.0/24→.203` 正是 cluster-pool 按**节点加入顺序**自动分的。

### 7.2 两层分配可能"名实不符"

```
第1层: kube-controller/k3s → node.spec.podCIDR = 10.42.x.x (kubectl get nodes) 
第2层: Cilium cluster-pool → ipcache 数据面 = 10.0.x.x (真实)
```

**ipcache 才是权威**。核实命令：

```bash
sudo cat /etc/rancher/k3s/config.yaml
kubectl -n kube-system get cm cilium-config -o yaml | grep -iE 'ipam|cidr'
kubectl get node ubuntu01 -o jsonpath='{.metadata.annotations.io\.cilium\.network\.ipv4-pod-cidr}'
```

### 7.3 生产安装要点（k3s + Cilium）

前提：内核 ≥5.10 + `CONFIG_DEBUG_INFO_BTF` + cgroup v2 + `/sys/fs/bpf`；k3s 需一起关 `--flannel-backend=none --disable-network-policy`（可用 `--disable-kube-proxy`）。

```bash
k3s server --flannel-backend=none --disable-kube-proxy \
  --disable-network-policy --cluster-cidr=10.0.0.0/16 --service-cidr=10.43.0.0/16

helm install cilium cilium/cilium -n kube-system \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16 \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set kubeProxyReplacement=strict \
  --set routingMode=tunnel --set tunnelProtocol=vxlan
```

### 7.4 避坑清单（节选）

| 坑 | 说明 |
|----|------|
| CIDR 不可变 | 上线后改网段=全重建，安装前规划拍板 |
| 掩码=单节点容量 | /24≈254 个 Pod/节点，大节点需加大掩码 |
| 两层 CIDR 对齐 | k3s `--cluster-cidr` 与 Cilium cluster-pool 不一致会"名实不符" |
| 加密 | 需要合规加密开 IPsec/WireGuard（本例 encryptkey=0 未开） |
| MTU | VXLAN 约 1450；native routing 1500 |
| 有状态应用 | 节点重建 Pod IP 会变，用 Headless+稳定名称 |

---

## 第 8 章 Cilium 与 Calico 的实现对照

Calico 没有 ipcache/nodeid/cilium_host，用"标准路由 + BGP + 按 IP 匹配"替代：

| 概念 | Cilium | Calico |
|------|--------|--------|
| 身份 | 16 位数字 identity 带在包元数据 | 无带内身份，按源 IP 查 IP 集合（felix 预编译） |
| IP→隧道端点 | bpf ipcache 预缓存 | Linux 主路由表 + BIRD/BGP 通告（IPIP/VXLAN） |
| 节点路由口 | cilium_host（Pod 网段内 IP，作默认网关） | veth host 端固定 169.254.1.1，节点当 L3 路由 |
| 节点身份 | bpf nodeid map（16 位 ID + SPI） | 无；外层报头源 IP 即节点，加密用 WireGuard 公钥 |
| 隧道 | VXLAN（cilium_vxlan），带 node id/identity | IPIP(tunl0)/VXLAN；外层普通 IP |
| 加密 | IPsec(SPI)/WireGuard | WireGuard（推荐）/IPsec |
| 数据面 | 全 eBPF | 默认 iptables/IPvs，可选 eBPF |
| IPAM | cluster-pool 分 /24 | IPPool 分 /26 块 |
| 挑选 | 精细化身份+全 eBPF | 简单直观、运维可用 ip route/iptables |

命令翻译表：

| Cilium 命令 | Calico 对应 |
|------------|------------|
| `bpf lb list` | iptables 模式 `iptables -t nat -L -n`；eBPF 模式无公开命令 |
| `bpf ipcache list` | `calicoctl node status` / `bird n s` / `ip route` / `calicoctl get wep -A` |
| `bpf nodeid list` | 无；`calicoctl node status` + `wg show` |
| identity 查询 | 无数字身份；`calicoctl get profiles` / label 选择器 |

---

## 第 9 章 排障命令速查表

```bash
# Service 面（LB 表）—— 虚拟 IP 转给谁
cilium-dbg bpf lb list
cilium-dbg service list            # 逻辑分组视图

# 端点/路由面（ipcache）—— IP 是谁、怎么到达
cilium-dbg bpf ipcache list        # | grep <pod-ip|<prefix>

# 节点身份面
cilium-dbg bpf nodeid list         # 节点 ID / SPI

# 其它常用
cilium-dbg endpoint list           # 端点身份
cilium-dbg identity list           # 身份号 → 工作负载
cilium-dbg status / connectivity test   # 健康
kubectl get svc -A | grep None     # 找 headless
kubectl get pod -A -o wide | grep <ip>  # IP → 真实节点
```

---

## 第 10 章 综合结论：完整数据通路

把三张 BPF 表合起来，就是完整的"Service → Pod → 物理节点"拓扑：

```
入口  ClusterIP / NodePort / LoadBalancer / HostPort
        │
 ① bpf lb list     虚拟IP → 后端Pod IP（REVNAT/SLOT 分发, DNAT）
        │
 ② bpf ipcache     IP → identity（谁） + tunnelendpoint（往哪封装）
        │
 ③ bpf nodeid      node ID → 物理IP + cilium_host IP（隧道归源/加密）
        │
 VXLAN 隧道 → 目标节点 → 本机直投 / cilium_host 网关 → Pod
```

### 本案例最终画像

- **网络模式**：k3s + Cilium，VXLAN 隧道，cluster-pool IPAM，未启用 IPsec/WireGuard
- **节点分工**：.201 = 控制平面（identity=7 的 kubepiserver、CoreDNS、NodePort 后端 10.0.0.17）；.202 = 本表节点（本地交付 10.0.1.x）；.203 = 核心业务主力（10.0.2.216 承载几乎全部 LB/NodePort 流量）
- **两张"自动"的地址分配**：k3s 上层 10.42.x.x（可查），Cilium 数据面 10.0.x.x（权威）
- **判断准则**：看身份用 ipcache/identity，看归属用 tunnelendpoint，看服务分发用 lb list——**ipcache 是数据面真理**