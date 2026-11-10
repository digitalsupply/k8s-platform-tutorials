# Cilium BPF IPCache 表解析（`cilium-dbg bpf ipcache list`）

<!-- 概述：本文解析 ipcache 输出,并与上一轮的 bpf lb list 对比分析,得到完整数据通路拓扑 -->

---

## 目录

1. [一、这个输出讲的是什么](#一这个输出讲的是什么)
2. [二、保留身份的 identity 含义（技术要点 1）](#二保留身份的-identity-含义技术要点-1)
3. [三、tunnelendpoint / flags 揭示网络模式（技术要点 2）](#三tunnelendpoint--flags-揭示网络模式技术要点-2)
4. [四、Pod CIDR 到节点的权威映射（技术要点 3）](#四pod-cidr-到节点的权威映射技术要点-3)
5. [五、与 bpf lb list 的区别与联系](#五与-bpf-lb-list-的区别与联系)
6. [六、二者综合后的新信息（重点）](#六二者综合后的新信息重点)
7. [七、联调查看建议命令](#七联调查看建议命令)

---

## 一、这个输出讲的是什么

**ipcache（IP 缓存表）** 是 Cilium 的核心 BPF Map（`cilium_ipcache`），解决两个问题：

> **"这个 IP 是谁（安全身份）"** + **"怎么到达它（本地直达还是隧道转发）"**

```
IP PREFIX/ADDRESS    IDENTITY(安全身份)  encryptkey(加密密钥)  tunnelendpoint(隧道路由)  flags(标记)
```

| 字段 | 含义 |
|------|------|
| IP PREFIX/ADDRESS | 端点 IP 或网段（/32 是精确端点，/24 是某节点的 Pod CIDR 通告） |
| identity | 安全身份 ID，**策略（NetworkPolicy/CiliumNetworkPolicy）识别的核心** |
| tunnelendpoint | 隧道模式下目标所属节点的物理 IP；`0.0.0.0` = 本机，无需隧道 |
| flags=hastunnel | 该 IP **需经 VXLAN 隧道**到达（远端）；`<none>` = 本地直达 |
| encryptkey | IPsec 加密密钥索引；**全部为 0 → 未启用 IPsec 加密** |

---

## 二、保留身份的 identity 含义（技术要点 1）

Cilium 有编号固定的**保留身份**：

| identity | 含义 | 本次输出对应条目 |
|----------|------|-----------------|
| **1** | host（本机节点） | `192.168.67.202` ← **证明本 dump 来自 .202 的 agent**；另有 `10.0.1.33`（本机 cilium_host 路由 IP） |
| **2** | world（外部/全网） | `0.0.0.0/0`（默认兜底）、两个 `/24` Pod CIDR |
| **4** | health（节点健康端点） | `10.0.0.80`、`10.0.1.130`、`10.0.2.87`（**每节点各一个 cilium-health**） |
| **6** | remote-node（远端节点） | `192.168.67.203`、`10.0.0.37`、`10.0.2.70`（远端节点及内部参考端点） |
| **7** | kube-apiserver | `192.168.67.201` ← **控制平面节点确认** |
| 其余数字 | 各类自定义端点身份（由 Pod 标签自动生成） | 各 Pod |

> identity=7 直接坐实之前 LB 表里的推断：**.201 是控制平面节点**（kube-apiserver 在 192.168.67.201:6443）。

---

## 三、tunnelendpoint / flags 揭示网络模式（技术要点 2）

- `flags=hastunnel` + 有 tunnelendpoint → **远端 IP，走 VXLAN 隧道**
- `flags=<none>` + tunnelendpoint=0.0.0.0 → **本机 IP，直接投递**

**证明 Cilium 运行在 VXLAN 隧道模式**，节点间 Pod 流量全部封装进隧道：

```
本机(202) → Pod 10.0.1.123 → 直接交付
本机(202) → Pod 10.0.2.216 → VXLAN 封装 → 送到 .203
```

---

## 四、Pod CIDR 到节点的权威映射（技术要点 3）

三个 `/24` 前缀直接给出**每台节点的 Pod 网段归属**：

| Pod CIDR | tunnelendpoint | 所属节点 | 说明 |
|----------|---------------|---------|------|
| 10.0.0.0/24 | 192.168.67.201 | 节点 .201 | 远端，隧道可达 |
| 10.0.1.0/24 | （本机无 /24 条目） | **节点 .202** | 本机，所以只有 /32 本地条目 |
| 10.0.2.0/24 | 192.168.67.203 | 节点 .203 | 远端，隧道可达 |

> 这既**印证了之前 LB 表"本机是 .202"的结论**，也给出缺失的第三块拼图。

---

## 五、与 `bpf lb list` 的区别与联系

### 区别：分工不同

| | `bpf lb list`（lb4_services） | `bpf ipcache list`（ipcache） |
|---|---|---|
| 关注的单元 | **Service**（虚拟 IP） | **Endpoints/节点**（真实 IP） |
| 回答的问题 | 虚拟 IP → 哪些后端？用什么 SLOT/REVNAT 分发？ | 这个 IP 是谁（身份）？怎么到达（隧道）？ |
| 结构 | 按 `(SVIP,端口,协议,SLOT)`，靠 REVNAT_ID 串关联 | 按 `IP/前缀 → (identity, tunnel)` |
| 数据面用途 | 入口负载均衡、DNAT/反向NAT | 身份校验（策略）、隧道转发决策 |

### 联系：同一数据面的两个维度

- **lb 表管"转到哪"**(后端地址)，**ipcache 管"到了怎么身份鉴别/封包"**
- LB 表列出的每个后端 Pod IP，**都必然在 ipcache 中有一条对应记录**（否则收包端无法验证身份、也无法路由）

---

## 六、二者综合后的新信息（重点）

### 新信息 1：所有后端 Pod 的"落点 + 身份"全貌

| 后端 Pod | 服务角色（来自 lb 表） | identity | 所在节点 | 到达方式 |
|----------|----------------------|----------|---------|---------|
| 10.0.2.216 | 核心业务（**所有 LB/NodePort 443/80 的主力**） | 51260 | **.203** | 隧道 |
| 10.0.0.17 | NodePort 30080 → 8081 | 5448 | **.201** | 隧道 |
| 10.0.0.4 | CoreDNS（53/9153） | 18946 | .201 | 隧道 |
| 10.0.0.61 | kubelet → apiserver 回跳 | 3420 | .201 | 隧道 |
| 10.0.0.75 | 代理端口 4245 | 21334 | .201 | 隧道 |
| 10.0.1.123 / 10.0.2.178 | Service `10.43.162.164:80` 双后端 | 同身份 **14608** | .202 / .203 | 本机 + 隧道 |
| 10.0.2.93 | Service `10.43.66.133:80` | 30056 | .203 | 隧道 |
| 10.0.1.137 | 前端 Web(80) | 8219 | .202 | 本机 |
| 10.0.1.163 | HostPort 80/443 | 7721 | .202 | 本机 |

### 新信息 2：**identity 相同 = 同一部署的副本**（无需 kubectl 即可分组）

同一 identity 出现在多台节点 → 是同一个工作负载的多个副本：

```
identity=7721 → 10.0.1.163(本机) + 10.0.2.179(.203) + 10.0.0.38(.201)
               → 三节点各一份 → 高度怀疑是 DaemonSet 类组件
identity=14608 → 10.0.1.123(.202) + 10.0.2.178(.203)
               → 两副本 Deployment（跨节点）→ 与 LB 表中同一 SVC 的双后端完全对应
```

### 新信息 3：⚠️ 与之前说法的一处冲突

之前你讲"NodePort 30080 的 Pod（10.0.0.17）在 Ubuntu02"。
**ipcache 明确显示 `10.0.0.17 → tunnelendpoint=192.168.67.201`**，即该 Pod 在 **.201** 节点（跨节点，需 VXLAN 转发）。

- 数据面的 ipcache 是**权威依据**（它决定包实际往哪封）
- 若你的命名相反（Ubuntu02=.201）则一致；否则之前的节点说法需修正
- 建议核实：`kubectl -n <ns> get pod -o wide -l app=<该应用>`

### 新信息 4：控制平面/数据面分工清晰

```
.201 → 控制平面（identity=7 apiserver）+ 承载 CoreDNS/kubelet 端点
.202 → 数据面（本机表所在）
.203 → 数据面 + 核心业务主力部署（10.0.2.216）
```

### 新信息 5：加密与隧道状态

- `encryptkey=0` 全部 → **未启用 IPsec**，隧道也只为 VXLAN 封装、不加密
- 网络模式 = **VXLAN 隧道 + 身份策略验证**（隧道端点即各节点物理 IP）

---

## 七、联调查看建议命令

```bash
# identity 数字 → 工作负载标签
cilium-dbg identity list                     # 或
kubectl get cep -A | grep <identity>

# Pod CIDR 与节点对应
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}'

# 确认某个后端 Pod 真实节点
kubectl get pod -A -o wide | grep 10.0.0.17
```

**一句话总结**：`lb list` 告诉你"服务入口转给谁"，`ipcache list` 告诉你"被转的 IP 是谁的身份、在哪个节点、怎么封包过去"——两者合起来，就得到了**从 Service 到 Pod、再到物理节点的完整数据通路拓扑**。

---

## 附录：本次分析的 ipcache 原始输出

```
IP PREFIX/ADDRESS   IDENTITY
10.0.0.75/32        identity=21334 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.0.0/24         identity=2 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
192.168.67.202/32   identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
192.168.67.203/32   identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.0.4/32         identity=18946 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.0.17/32        identity=5448 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.0.37/32        identity=6 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.0.148/32       identity=52785 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.1.123/32       identity=14608 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.163/32       identity=7721 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.2.93/32        identity=30056 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.2.179/32       identity=7721 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.0.80/32        identity=4 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.1.33/32        identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.137/32       identity=8219 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.2.70/32        identity=6 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.2.87/32        identity=4 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.2.216/32       identity=51260 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.2.0/24         identity=2 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
192.168.67.201/32   identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.0.61/32        identity=3420 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
10.0.1.93/32        identity=22193 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.130/32       identity=4 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.2.88/32        identity=12689 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
10.0.2.178/32       identity=14608 encryptkey=0 tunnelendpoint=192.168.67.203 flags=hastunnel
0.0.0.0/0           identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.0.38/32        identity=7721 encryptkey=0 tunnelendpoint=192.168.67.201 flags=hastunnel
```