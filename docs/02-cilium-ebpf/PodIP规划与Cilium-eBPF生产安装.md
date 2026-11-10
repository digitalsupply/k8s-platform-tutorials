# 从本案例看 Pod IP 规划 与 Cilium/eBPF 生产安装

> 结合本集群的实际输出（`bpf lb list`、`bpf ipcache list`、`kubectl get nodes`），讲透不同节点的 Pod IP 到底怎么来的 —— 是安装时配的还是自动分的，以及真实生产部署 eBPF + Cilium 的前提、步骤与注意事项。

---

## 目录

1. [一、本案例的节点与网段事实](#一本案例的节点与网段事实)
2. [二、不同节点 Pod IP 是配置的还是自动的？](#二不同节点-pod-ip-是配置的还是自动的)
3. [三、kubectl 显示 10.42 而 ipcache 显示 10.0 —— 两层分配为何可能不一致](#三kubectl-显示-1042-而-ipcache-显示-100--两层分配为何可能不一致)
4. [四、真实生产部署 eBPF + Cilium 的前提条件](#四真实生产部署-ebpf--cilium-的前提条件)
5. [五、生产安装典型流程（k3s + Cilium）](#五生产安装典型流程k3s--cilium)
6. [六、生产注意事项与避坑清单](#六生产注意事项与避坑清单)
7. [七、两轮分析的综合结论](#七两轮分析的综合结论)

---

## 一、本案例的节点与网段事实

### 1.1 当前 `kubectl get nodes`（k3s 默认视角）

| 节点 | 节点物理 IP | node.spec.podCIDR |
|------|------------|-------------------|
| ubuntu01 | 192.168.67.201 | **10.42.0.0/24** |
| ubuntu02 | 192.168.67.202 | **10.42.1.0/24** |
| ubuntu03 | 192.168.67.203 | **10.42.3.0/24** |

**注意：ubuntu03 是 10.42.3.0/24，跳过了 10.42.2.0/24。**（见 2.1 的"空洞"解释）

### 1.2 之前 ipcache 分析看到的"实际数据面"

| Pod CIDR | tunnelendpoint | 对应节点 |
|----------|---------------|---------|
| 10.0.0.0/24 | 192.168.67.201 | ubuntu01 |
| 10.0.1.0/24 | 本机（无隧道） | ubuntu02 |
| 10.0.2.0/24 | 192.168.67.203 | ubuntu03 |

### 1.3 关键矛盾点

- **节点 IP（192.168.67.201-203）与服务网段（10.43.0.0/16，k3s 默认）两边完全一致**
- **但 Pod 网段不一致**：`.spec.podCIDR` 是 10.42.x.x，ipcache 数据面是 10.0.x.x
- 两种可能：
  1. 这是两套不同的集群（同一批物理机）
  2. 同一套集群但"分配的上层"（kube-controller-manager/k3s）与"实际使用"（Cilium 数据面）分层不一致
- 下文 2、3 两节正好解释这两种机制，也给出核实方法

---

## 二、不同节点 Pod IP 是配置的还是自动的？

**答案：绝大多数是"自动的"，但"从哪个大网段里分、每个节点分多大、预留多少"这一步必须安装前人为规划配置好。**

### 2.1 k3s 默认（本案例第一层分配）

k3s 是嵌入式 kube-apiserver + embedded kube-controller-manager，默认行为：

```
--cluster-cidr  默认 10.42.0.0/16   (Pod 网段)
--service-cidr  默认 10.43.0.0/16   (Service 网段)
```

- 每个节点加入时，由内置 controller **按加入顺序自动分配一个 /24**
- 第一个节点 ubuntu01 → `10.42.0.0/24`
- 第二个 ubuntu02 → `10.42.1.0/24`
- 第三个 ubuntu03 → `10.42.3.0/24`（**为什么不是 2？**）

**10.42.2.0/24 空洞的原因：**
k3s 的 CIDR 分配器"用过不返还原地"。典型场景：
- 曾有一台（worker/agent）加入时拿到了 `10.42.2.0/24`，之后被删除/重装
- 或初始化时该段被某个分配请求占走
- 后续节点只从"当前未分配"的开始取 → 于是排到 3

> 所以节点 Pod 段**不代表邻居关系、也不代表固定**——它是"先到先得 + 不回收复用"的动态结果。

### 2.2 若想手动规划，是"安装时配置"的

k3s 在安装时通过 `config.yaml` 或 systemd service 参数固定：

```yaml
# /etc/rancher/k3s/config.yaml（所有节点保持一致）
cluster-cidr: 10.0.0.0/16      # Pod 大段
service-cidr: 10.43.0.0/16     # Service 大段
```

```bash
# systemd 方式
ExecStart=/usr/local/bin/k3s server \
  --flannel-backend=none \
  --cluster-cidr=10.0.0.0/16 \
  --service-cidr=10.43.0.0/16
```

> 大段（/16）固定后，**节点具体拿哪个 /24 仍是自动的**；你要"规划"的是：大段大小、掩码位（每节点多少 Pod）、是否与物理网冲突。

### 2.3 Cilium 的 IPAM 模式（第二层，真正决定数据面）

用 Cilium 时，"节点 Pod 网段怎么来"由 `ipam.mode` 决定：

| ipam.mode | 分配来源 | 特点 |
|-----------|---------|------|
| **cluster-pool**（默认） | Cilium 自己从 `--cluster-pool-ipv4-cidr`（默认 **10.0.0.0/16**）按 `--cluster-pool-ipv4-mask-size`（默认 **24**）自动给每个节点分 /24 | 不依赖 node.spec.podCIDR；**之前 ipcache 里的 10.0.x.x 正是这种** |
| **kubernetes** | 直接使用 node.spec.podCIDR（即 k3s/kcp 分出来的 10.42.x.x） | 与上层一致，无需 Cilium 再分 |
| kubernetes (host-scoped) / ENI / Azure / GCE | 云厂商原生 | 云上生产首选 |

**结论对本案例：**
- 之前那次 ipcache 输出 `10.0.0.0/24 → .201`、`10.0.1.0/24 → 本机(.202)`、`10.0.2.0/24 → .203`，**正是 Cilium cluster-pool 按节点加入顺序自动分配的 /24**（默认池就是 10.0.0.0/16）
- 也就是说：**装的时候 Cilium 帮我们自动分了**，无需手工逐节点指定
- 但**规划**（池的范围、掩码）是安装 Cilium 时通过 helm/ConfigMap 配的

---

## 三、kubectl 显示 10.42 而 ipcache 显示 10.0 —— 两层分配为何可能不一致

因为存在**两条分配线**：

```
第1层：kube-controller-manager/k3s →
       node.spec.podCIDR（本例 10.42.x.x）  ← kubectl get nodes 看到的是它
第2层：Cilium cluster-pool IPAM →
       node 上的 io.cilium.network.ipv4-pod-cidr / ipcache 数据面（本例 10.0.x.x）
```

如果 k3s 没设置 `--cluster-cidr`，node 会拿到 10.42.x.x；同时 Cilium 又用默认池 10.0.0.0/16 给 kubelet 的实际 Pod 地址 → **两层就出现"名实不符"**。这是 k3s+Cilium 最常见的坑之一。

**核实方法（生产上必做）：**

```bash
# 1) 看 k3s 配置（大段定义）
sudo cat /etc/rancher/k3s/config.yaml   # 或 systemctl cat k3s

# 2) 看 Cilium 的 IPAM 配置
kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'ipam|cluster-pool|cidr'

# 3) 看节点上 Cilium 自己主张的 Pod CIDR
kubectl get node ubuntu01 -o jsonpath='{.metadata.annotations.io\.cilium\.network\.ipv4-pod-cidr}{"\n"}'

# 4) 数据面实际（权威）
kubectl -n kube-system exec -it <cilium-pod> -- cilium-dbg bpf ipcache list | grep /24
```

> 结论：**以 ipcache/Endpoint 为准**，它才是包真实走哪的答案；`kubectl get nodes` 的 podCIDR 只反映上层分配。

---

## 四、真实生产部署 eBPF + Cilium 的前提条件

### 4.1 内核要求（eBPF 能力的根）

| 内核版本 | 支持情况 |
|---------|---------|
| < 4.19 | 不可用 |
| 4.19 ~ 5.9 | 可用但功能受限（缺 ringbuf、bpf_prog 一些能力） |
| **>= 5.10** | **官方建议线**，kube-proxy replacement、VXLAN、most features 完整 |
| >= 5.15 / 6.x | 全功能（含 WireGuard、新的 bpf_loop 等） |

上线前建议：`uname -r`

### 4.2 内核特性/系统开关（没开就装不上或功能缺失）

- **BTF**：`CONFIG_DEBUG_INFO_BTF=y`（Cilium 拓扑/co-re 依赖）
- **cgroup v2**：必须挂载且有 BPF 支持（推荐 systemd 已启用 cgroup2：`stat -fc %T /sys/fs/cgroup` 应打印 `cgroup2fs`）
- **BPF 文件系统**：`/sys/fs/bpf` 可挂载
- 相关内核模块：`bpftool` 验证；`ls /sys/kernel/btf/vmlinux`
- 必要 sysctl：`net.ipv4.ip_forward=1`（转发场景）
- **XDP**（若用 XDP 加速/负载均衡）

**快速自检（Cilium 自带）：**

```bash
cilium-dbg status            # 看 BPF 可用性
cilium-dbg check             # 内核对齐检查
cilium-dbg map list          # BPF map 全部可访问
```

### 4.3 运行时/发行版前提

- 节点需要**完整 root/特权**（agent 以 hostPID/hostNetwork 运行，不能跑在无特权容器里）
- 建议 containerd（k3s 内置）作为容器运行时
- 若用 Docker：`cgroupDriver: systemd` 需一致，否则 kubelet 与容器运行时 cgroup 对不上

### 4.4 k3s 里启用 Cilium 的开关

```bash
# server（所有节点）都要一致
--flannel-backend=none     # 关掉 flannel
--disable-network-policy   # 关掉 k3s 自带 netpol 控制器
--disable-kube-proxy       # 用 Cilium 的 kube-proxy replacement（可选但要严格）
```

> 三件套不一起关，会与 Cilium 抢转发/策略，出现路由冲突、策略不生效等偶发问题。

---

## 五、生产安装典型流程（k3s + Cilium）

### 5.1 制定 CIDR 规划（提前定死）

| 项 | 值（示例） | 说明 |
|----|-----------|------|
| Pod 大段 | `10.0.0.0/16` | 与物理/办公网/VM 网段不重叠 |
| 每节点掩码 | `/24` | 每节点 ≤ ~254 Pod |
| Service 大段 | `10.43.0.0/16` | 不能与 Pod 段重叠 |
| NodePort 范围 | `30000-32767` | 避免与 hostPort/内网端口冲突 |

### 5.2 安装 k3s（统一参数）

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --flannel-backend=none \
  --disable-kube-proxy \
  --disable-network-policy \
  --cluster-cidr=10.0.0.0/16 \
  --service-cidr=10.43.0.0/16 \
  --write-kubeconfig-mode=644
```

### 5.3 安装 Cilium（helm）

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --namespace kube-system \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16 \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set kubeProxyReplacement=strict \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.enabled=true
```

### 5.4 验证

```bash
cilium-dbg status                    # 整体
cilium-dbg bpf lb list               # 服务面
cilium-dbg bpf ipcache list          # 身份/路由面
cilium-dbg endpoint list             # 端点身份
cilium-dbg connectivity test         # 端到端连通
```

---

## 六、生产注意事项与避坑清单

| # | 注意事项 | 说明 |
|---|---------|------|
| 1 | **CIDR 一经使用不可变** | 后期改网段 = 全部重建；规划拍板后再装 |
| 2 | **大段预留扩容** | 三节点 /24 只占 3 个，剩 250+ 个可扩；别把池压满 |
| 3 | **掩码大小=每节点容量** | /24≈254 个 Pod；单节点 Pod>256 需放大掩码或换 IPAM |
| 4 | **两层 CIDR 必须对齐** | k3s `--cluster-cidr` 与 Cilium cluster-poolCIDR 不一致→上文 3 的"名实不符" |
| 5 | **节点 /24 "空洞"属正常** | 节点删了不回收：10.42.2.0/24 悬空就是例子，勿慌 |
| 6 | **kube-proxy / flannel / netpol 三件套要关** | 不关会特权冲突、策略失效 |
| 7 | **隧道 MTU** | VXLAN 下 MTU 约 1450，业务大包可能分片；native routing 用 1500 |
| 8 | **加密** | 需要合规加密时开 IPsec 或 WireGuard（本例 encryptkey=0 = 未开） |
| 9 | **有状态应用与 Pod IP** | 节点重建/agent 重启可能重分 IP；StatefulSet 用 Headless + 稳定名称（见前文） |
| 10 | **hostPort 与 30000-32767 冲突** | NodePort 默认区间你别再用 hostPort 占同一端口 |
| 11 | **identity=7 是 apiserver** | 排障时看到 1/2/4/6/7 别当业务身份 |
| 12 | **升级先看兼容矩阵** | 内核版、Cilium 版、k3s 版三者互相锁版本 |
| 13 | **监控** | 上 Hubble，提前暴露身份/连接问题 |
| 14 | **多集群** | Cluster Mesh 要求各集群 cluster-pool CIDR 不重叠 |

---

## 七、两轮分析的综合结论

1. **Pod IP 是自动分配的**：k3s 按加入顺序分 /24（10.42.x.x），Cilium cluster-pool 按加入顺序从 10.0.0.0/16 分 /24（10.0.x.x）
2. **"规划"发生在安装时**：大段、掩码、Service 段都是装的时候定死的，之后节点拿哪段由系统自动决定
3. **ipcache 是权威**：`kubectl get nodes` 的 podCIDR 可能和实际数据面不一致，一切以 ipcache/Endpoint 为准
4. **融合之前 `bpf lb list` + `bpf ipcache list` 可得完整拓扑**：

```
入口(LB/NodePort/ClusterIP)
   │ bpf lb list：虚拟IP → 后端Pod IP
   ▼
ipcache：后端Pod IP → 身份(identity) + 节点(tunnelendpoint)
   ▼
VXLAN 隧道 → 目标节点物理IP → 本地交付 / 转发
```

5. **本环境的基建结论**：k3s + Cilium，VXLAN 隧道模式，cluster-pool IPAM，未启用加密；节点 .201 为控制平面（identity=7），.202 为本机表节点，.203 承载核心业务主力 Pod（10.0.2.216）