# 实验：抓包"穿越" Cilium eBPF 数据面

> 用 **Hubble + `bpf lb list` + `bpf ipcache list` + tcpdump 四件套**，在已部署的三节点 k3s+Cilium(VXLAN) 上，完整跟踪一个数据包从客户端 Pod → ServiceIP → 后端 Pod 在内核里的穿行路线：
> `10.0.1.x (ubuntu02) → 10.43.x.x (ClusterIP) → 10.0.2.x (ubuntu03)`

---

## 目录

- [1. 实验目的](#1-实验目的)
- [2. 实验对象与真实拓扑](#2-实验对象与真实拓扑)
- [3. 原理预览：四件套各看哪一层、期望事件时间线](#3-原理预览)
- [4. 前置准备（核对与补丁）](#4-前置准备)
- [5. 实验步骤](#5-实验步骤)
- [6. 预期证据对照表（"穿越"全程）](#6-预期证据对照表)
- [7. 变体实验](#7-变体实验)
- [8. 注意事项与易错点](#8-注意事项与易错点)
- [9. 命令速查附录](#9-命令速查附录)

---

## 1. 实验目的

1. **真实看到 Kernel 里的四段旅程**：
   `客户端Pod →(tcx veth)→ BPF LB(DNAT) →(ipcache 决策)→ VXLAN(eth0外层) →(.203 decap)→ 后端Pod`
2. **让四件套互相作证**：一张图、同一时刻，四个工具各给一份"证据"：
   - `bpf lb list` → "Service 入口应该转给谁"（决策依据）
   - `bpf ipcache list` → "目标 IP 是谁、要不要封装、封装到哪"（路由依据）
   - `cilium-dbg monitor / Hubble` → "BPF 数据面实际执行了什么"（运行时事件）
   - `tcpdump` → "报文在物理/overlay 两个层面的真实外貌"（字节级事实）
3. **固化关键认知**：VXLAN 存在"外层(eth0) 与 内层(vxlan 设备)"两副面孔；LB 的 DNAT 与回包的 revnat 是成对发生的。

---

## 2. 实验对象与真实拓扑

### 2.1 已确认的事实（来自前几轮）

| 项 | 值 |
|----|----|
| 源/客户端 | `.202`(ubuntu02) 上一个 Pod，建议用 `10.0.1.137`（identity 8219，Web 80）或起 netshoot 调试 Pod |
| 目标 Service | ClusterIP **`10.43.66.133:80`**，REVNAT_ID=23 |
| 后端 Pod | **`10.0.2.93:80`**（identity 30056，在 `.203`/ubuntu03） |
| 数据面依据 | ipcache：`10.0.1.0/24→本机`；`10.0.2.93→tunnelendpoint=192.168.67.203（hastunnel）` |
| 网络模式 | VXLAN 隧道、KPR=Direct Routing、未加密、MASQ=iptables(仅出群) |
| VXLAN UDP 端口 | 默认 8472 |

### 2.2 拓扑

```
ubuntu02 (.202)                              ubuntu03 (.203)
┌───────────────────────────┐               ┌───────────────────────────┐
│ 客户端Pod 10.0.1.137      │               │ 后端Pod 10.0.2.93 (Web80)  │
│   └─veth─ lxcXXX          │               │   └─veth─ lxc5c41b4…       │
│        │ from_container   │               │        ▲ to-container      │
│   cilium_host 10.0.1.33   │               │   cilium_host 10.0.2.70    │
│        │ (路由/决策)        │               │        │                  │
│   cilium_vxlan ←封装       │               │   cilium_vxlan →解封装     │
│        │                  │               │        │                  │
│        eth0 ──────UDP8472 外层──────→ eth0│
│   192.168.67.202       (VIA TUNNEL)    192.168.67.203                 │
└───────────────────────────┘               └───────────────────────────┘
```

---

## 3. 原理预览

### 3.1 四件套分工

| 工具 | 看哪一层 | 回答的问题 |
|------|---------|-----------|
| `bpf lb list` | Service 决策表 | 10.43.66.133:80 → 哪些后端（slot/revnat） |
| `bpf ipcache list` | 身份+路由表 | 10.0.2.93 是谁(identity)、去它要走隧道吗(tunnelendpoint/hastunnel) |
| `cilium-dbg monitor` | BPF 运行时事件 | 数据面真实执行了：进容器→**SERVICE 翻译行**→出 overlay |
| `hubble observe` | 高层流日志 | 整条流起点到点、verdict、identity 图案 |
| `tcpdump` | 字节面 | 外层（eth0 上 VXLAN UDP8472 vs 节点IP）vs 内层（vxlan/cilium_host 上原始 IP） |

### 3.2 期望事件时间线（.202 视角）

```
t0 客户端发起: 10.0.1.137:xxxx → 10.43.66.133:80
t1 tcx veth(lxc*) ingress from_container 拦截 → 打身份(8219) → 判定目的=ClusterIP
t2 BPF LB 查表: revnat 23 → 选后端 10.0.2.93:80 → DNAT(目的改写) + conntrack 记录
t3 路由/ipcache: 10.0.2.93 属 10.0.2.0/24 → tunnelendpoint=192.168.67.203 → 决定封装
t4 cilium_vxlan 收内层包 → 外层封VXLAN(8472, src=192.168.67.202,dst=192.168.67.203)
t5 eth0 发出外层包 → 到达 .203 eth0 → cilium_vxlan 解封装 → 内层 10.0.2.93
t6 .203 交付: 查本机 ipcache(10.0.2.93=<none> 本地) → veth → Pod 10.0.2.93
t7 回包: 10.0.2.93 → 10.0.1.137(源) → .203 封 → .202 解 → conntrack revnat 还原 → 客户端看到 src=10.43.66.133
```

---

## 4. 前置准备

### 4.1 确认 Service 与 Endpoint 可用

```bash
kubectl get svc -A -o wide | grep 10.43.66.133
kubectl get endpoints -A | grep 66.133          # 后端地址应含 10.0.2.93:80
kubectl get pod -A -o wide | grep 10.0.2.93      # 确认在 .203
```

### 4.2 准备客户端（.202 上能 curl 的 Pod）

优先在 .202 起一个调试 Pod（netshoot 自带 curl/tcpdump）固定落在 .202：

```bash
kubectl run debug --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"nodeName":"ubuntu02"}}' -- sleep 1d    # nodeName 按实际节点名
kubectl get pod debug -o wide     # 记下 Pod IP（应为 10.0.1.x）
kubectl exec -it debug -- curl -v http://10.43.66.133/    # 连通性自测
```

### 4.3 记录"实验前"基线快照（在两台节点上各截一次）

```bash
# .202
cilium-dbg bpf lb list | grep '10.43.66.133'
cilium-dbg bpf ipcache list | grep -E '10\.0\.1\.137|10\.0\.2\.|0\.0\.0\.0'

# .203
cilium-dbg bpf ipcache list | grep -E '10\.0\.2\.93|10\.0\.1\.0'
```

### 4.4 确认抓包条件

```bash
ip -d link show cilium_vxlan | grep -i port    # 确认 VXLAN UDP 端口(8472)
which tcpdump                                   # 各节点装 tcpdump；cilium pod 里通常也有
```

---

## 5. 实验步骤

### Step 0 · 快照（基线）

在 .202、.203 各留一份 `bpf lb list` 和 `bpf ipcache list` 输出（留存文件名含时间）。

### Step 1 · 打开运行时事件（.202 与 .203 各一路）

```bash
# .202: 只看客户端→后端这段
kubectl -n kube-system exec -it <cilium-on-202> -- \
  cilium-dbg monitor -v -t trace -t drop | tee /tmp/mon202.log

# .203: 看解封装后的交付
kubectl -n kube-system exec -it <cilium-on-203> -- \
  cilium-dbg monitor -v -t trace | tee /tmp/mon203.log
```

> 若 monitor 不支持 `-t` 过滤选项，直接 `cilium-dbg monitor -v` 全量，事后 grep `10.0.2.93`。

### Step 2 · 打开 tcpdump（关键！要抓"两层面孔"）

**源节点 .202**（3 个口：eth0=外层、cilium_vxlan=内层、cilium_host=路由段）

```bash
tcpdump -i eth0        -nn -v 'udp port 8472'            -w /tmp/s202_eth0.pcap &      # 外层
tcpdump -i cilium_vxlan -nn -v 'host 10.0.2.93'           -w /tmp/s202_vxlan.pcap &   # 内层(出向=封前)
tcpdump -i cilium_host -nn 'host 10.43.66.133 or host 10.0.2.93' -w /tmp/s202_host.pcap &
```

**目标节点 .203**（eth0=外层入、cilium_vxlan=解封后内层、后端 veth=交付）

```bash
tcpdump -i eth0        -nn -v 'udp port 8472'            -w /tmp/d203_eth0.pcap &
tcpdump -i cilium_vxlan -nn -v 'host 10.0.2.93'           -w /tmp/d203_vxlan.pcap &
# 找到 10.0.2.93 对应的 lxc 接口名：
cilium-dbg endpoint list | grep 10.0.2.93     # 读 ifindex
ip link show                                # 由 ifindex 映射 lxcXXXX
tcpdump -i lxcXXXX -nn 'port 80'             -w /tmp/d203_lxc.pcap &
```

### Step 3 · 发起流量（把"一发"变成"一段"）

```bash
kubectl exec -it debug -- /bin/sh -c \
  'for i in $(seq 1 30); do curl -s -o /dev/null -m 2 http://10.43.66.133/ ; done'
```

> 30 次连发：保证 tcpdump/monitor 都捕捉到；`-m 2` 超时避免挂死。
> 同时在 .203 的 cilium 上再开一路 monitor（选项）或靠 tcpdump 的 vxlan 内层即能证明到达。

### Step 4 · 停止并对照证据

```bash
jobs -l; kill %1 %2 %3 ...          # 或记录后停掉所有 tcpdump
# 分析
tcpdump -nn -r /tmp/s202_eth0.pcap  | head      # 外层: VXLAN src=202 dst=203
tcpdump -nn -r /tmp/s202_vxlan.pcap | head      # 内层: 10.0.1.137 -> 10.0.2.93
grep -E '10\.43\.66\.133|10\.0\.2\.93|SERVICE' /tmp/mon202.log
hubble observe --from-pod default/debug --verdict FORWARDED --output json  # 事后流核对
```

### Step 5 · 验证回包与 NAT 还原

- 在客户端 Pod 里 `curl -v http://10.43.66.133/`，看 **Response 源地址仍是 10.43.66.133**（没有露出 10.0.2.93）
- 解释：回包经 .203 隧道回 .202 → 查 conntrack 找到 revnat 23 → 目的(原源)还原为 ServiceIP

---

## 6. 预期证据对照表（"穿越"全程）

| # | 阶段 | ·202 应见证据 | ·203 应见证据 | 对应工具 |
|---|------|--------------|--------------|---------|
| 1 | 客户端发包 | Pod 内 SYN dst=`10.43.66.133:80` | — | tcpdump(pod 内) |
| 2 | veth 进数据面 | monitor：`from container` ID=8219, 钩子 `from_container` | — | monitor / bpftool net |
| 3 | BPF LB 决策 | monitor：**SERVICE 行**（revnat→backend `10.0.2.93:80`） | — | monitor + lb list 对照 |
| 4 | 路由/决策 | ipcache：`10.0.2.0/24→tunnel .203 hastunnel`(决策依据) | — | ipcache list |
| 5 | 封装 | `cpu_vxlan` 上**内层**`10.0.1.137→10.0.2.93`；`eth0` 上**外层** `UDP8472 202↔203` | — | tcpdump 两口 |
| 6 | 接收+解封 | — | `eth0` 外层进 → `cilium_vxlan` 内层出`10.0.2.93` | tcpdump 两口 |
| 7 | 交付 | — | monitor：`to container` ID=30056；veth 上 80 端口流量 | monitor / tcpdump veth |
| 8 | 回包 | `eth0` 外层回：`UDP8472 203→202`；`vxlan` 内层回：`10.0.2.93→10.0.1.137` | 反相 | tcpdump |
| 9 | NAT 还原 | 客户端看到 `src=10.43.66.133`（revnat 还原） | — | curl -v / conntrack |
| 10 | 高层核对 | Hubble：`FORWARDED` 双向流 + 身份编号 | Hubble 同流 | hubble observe |

> **核心证据 = 第 5、6、9 行**：同一个包在 eth0 上长着"节点 IP 的外层脸"，在 vxlan 设备上长着"Pod IP 的内层脸"；回来时 LB 把源还原成 ServiceIP。

---

## 7. 变体实验

### 变体 A · 同节点后端（对比"本地直达"）

用 `10.43.162.164:80`（后端 `10.0.1.123=.202 本地` **和** `10.0.2.178=.203`）：

```bash
kubectl exec -it debug -- sh -c 'for i in $(seq 1 40); do curl -s -o /dev/null http://10.43.162.164/; done'
```

观察：命中本地后端的那几次 **eth0/VXLAN 一个外层包都没有**（cilium_host 直接 veth 投递）；命中远端的那几次才有隧道包 → 直接证明"策略讲身份、转发看位置"。

### 变体 B · NodePort + KPR Direct Routing（入口在宿主机）

在 .202 宿主机 `curl http://192.168.67.20x:30135` 等 NodePort：
- 看 BPF LB 是否把 NodePort 解析到后端 pod
- monitor 里出现 `from host`（host 入口）、identity=1 那段
- 对比 `bpf lb list` 中`0.0.0.0:nodePort` 通配入口与具体节点 IP 入口两个 REVNAT 的分工

### 变体 C · 看 drop（Eth/Tail）制造一次失败流

不存在的 Service 端口 or 用 `kubectl delete svc` 前最后一包：monitor 看 `drop (PRIVATE_IP...)` / 无后端时 lb 直接 drop，理解 lb 表"0/ANY 占位条目"意味着访问会掉包。

---

## 8. 注意事项与易错点

1. **"外层 vs 内层"别搞混**：`tcpdump -i cilium_vxlan` 报的是**解封装后/封装前**的内层；`tcpdump -i eth0` 报的是外层 VXLAN(UDP8472)。包在节点间的真实长相要 **eth0** 上看。
2. **Hubble 可能丢流**：此前 status 显示 Hubble `4095/4095 (100%)` 已满 → 实时排障依赖 `cilium monitor` + `tcpdump`，Hubble 只做事后核对。
3. **先抓后发，别倒着来**：tcpdump/monitor 就绪后再发流量；用 `-w` 落盘避免终端刷爆，事后 `-r` 解析。
4. **Filter 要宽松**：先裸抓再 grep，过滤太狠（如只 `port 80`）可能漏掉 VXLAN 外层（端口8472）。
5. **不要在生产高峰期操作**；抓包前确认磁盘空间；结束后 kill 干净 tcpdump。
6. **cluster 内部流量不做 MASQ**：overlay 里源地址就是 `10.0.1.137`（只有出群才 iptables masq）→ 回包路径才简单（只有 LB 的 revnat 一层还原）。
7. **加密开关**：本次 `Encryption: Disabled`，内层可读；若开 IPsec/WireGuard，eth0 上不再是明文 UDP8472 而是 ESP/随机端口，实验要重写预期。
8. **identity 对表**：monitor 里的 ID(如 8219/30056) 用 `cilium-dbg identity list` 反查 labels，体会"身份由标签生成"。
9. **机器别混淆**：`kubectl exec ds/cilium` 可能落到别的节点——本实验请**显式指定** `.202/.203` 各自的 cilium Pod 名（`kubectl -n kube-system get pod -o wide -l k8s-app=cilium`）。
10. **后端就绪检查**：实验前 `kubectl get endpoints` 确认 10.0.2.93 在 Ready，否则 lb 表无 slot1、直接 drop。

---

## 9. 命令速查附录

```bash
# 数据面表（实验前后各一次）
cilium-dbg bpf lb list          | tee lb_$(date +%s).log
cilium-dbg bpf ipcache list     | tee ipc_$(date +%s).log

# 运行时事件（实时主证据）
cilium-dbg monitor -v -t trace -t drop
cilium-dbg monitor -v | grep -E 'SERVICE|10.0.2.93'

# 挂载点对照（顺带看钩子在不在）
bpftool net                          # 注意：在宿主机上跑，不是 exec 进 cilium

# tcpdump 四口模板
tcpdump -i eth0        -nn -v 'udp port 8472'
tcpdump -i cilium_vxlan -nn -v 'host 10.0.2.93'
tcpdump -i cilium_host -nn 'host 10.43.66.133 or host 10.0.2.93'
tcpdump -i lxcXXXX     -nn 'port 80'

# Hubble 事后核对
hubble observe --from-pod default/debug --to-service default/websvc --follow
hubble observe --since 5m --output json | grep -i forwarded

# 端点/身份反查
cilium-dbg endpoint list | grep 10.0.2.93     # ifindex → lxc 接口
cilium-dbg identity list
```

---

**实验完成判据**：在 `.202 的 eth0` 上看到了 `UDP 8472 202↔203` 的外层包，在 `.202 的 cilium_vxlan` 上看到了 `10.0.1.137 → 10.0.2.93` 的内层包，monitor 里出现了 SERVICE 翻译行，且客户端最终看到响应源是 `10.43.66.133` —— 四件套互相印证，一个包"从 10.0.1.x 到 ServiceIP 再到 10.0.2.x"的完整穿越就闭环了。