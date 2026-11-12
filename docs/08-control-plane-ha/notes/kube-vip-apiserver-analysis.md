# kube-vip / API Server 访问关系分析

> **状态：历史快照（2026-10-11，K8s 1.35.9 + Calico + kube-proxy）**
> 本文的"谁连谁"分析基于当时的 kube-proxy/iptables 数据面；现在 Service DNAT 由 Cilium eBPF 完成，**不要按本文去改 kube-proxy ConfigMap**（对象已不存在）。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），**照本文排障前先看现状**：[current-state.md](../../00-cluster-overview/assets/current-state.md)。
> 审计记录见 [19 章](../../19-audit/README.md)。

> 集群：6 节点（3 control-plane + 3 worker），kube-vip v1.2.4，ARP/L2 模式
> VIP：`10.0.0.168:6443`　SDK/分析时间：2026-10-11

## 一、结论速览

| 客户端 | 访问的 API Server |
|---|---|
| 控制面静态 Pod（kube-controller-manager / kube-scheduler） | **各节点自己的本机 API Server** |
| kubelet | **本节点自己的 API Server**（worker 除外 → 指向 m01） |
| kube-proxy（全节点） | **`10.0.0.61:6443`（m01），全节点统一** |
| 普通业务 Pod（in-cluster） | **Service ClusterIP `10.96.0.1:443` → 负载均衡到 3 台 apiserver** |
| 手工 `kubectl`（admin.conf） | **VIP `10.0.0.168:6443`** → 当前落到 **master01** |

VIP 当前持有者：**master01（10.0.0.121）**。

---

## 二、三套不同的客户端 kubeconfig

| kubeconfig | 谁用 | 指向的 API Server |
|---|---|---|
| `admin.conf` | 手工 `kubectl` / 运维 | **VIP `10.0.0.168:6443`** → 落到当前 VIP 持有者 **master01** |
| `kubelet.conf` | 每台节点的 kubelet | **本节点自己的 API Server**（m01 用 `127.0.0.1`，其它控制面用本机 IP）；worker 指向 m01 |
| `controller-manager.conf` / `scheduler.conf` | 控制面静态 Pod | **本节点自己的 API Server** |
| kube-proxy 用的 configmap kubeconfig | 所有 kube-proxy | **`10.0.0.61:6443`（m01），全节点统一** |

---

## 三、各节点实际访问的 API Server

| 节点 | IP / 角色 | kubelet → | 静态 Pod 访问的 apiserver | 说明 |
|---|---|---|---|---|
| **m01** | 10.0.0.61 / CP | `127.0.0.1:6443`（本机） | CM、Scheduler → **10.0.0.61:6443**（本机） | bootstrap 节点，kubeconfig 单集群指向回环 |
| **master01** | 10.0.0.121 / CP | `10.0.0.121:6443`（本机） | CM、Scheduler → **10.0.0.121:6443**（本机） | 同时是 VIP 持有者 |
| **master02** | 10.0.0.120 / CP | `10.0.0.120:6443`（本机） | CM、Scheduler → **10.0.0.120:6443**（本机） | |
| **worker01** | 10.0.0.122 | `10.0.0.61:6443`（m01） | 无静态 Pod | 加节点时的 join 端点 |
| **worker02** | 10.0.0.123 | `10.0.0.61:6443`（m01） | 无静态 Pod | |
| **worker03** | 10.0.0.124 | `10.0.0.61:6443`（m01） | 无静态 Pod | |

> 静态 Pod 仅存在于控制面节点（`/etc/kubernetes/manifests` 下：`kube-apiserver`、`kube-controller-manager`、`kube-scheduler`、`etcd`）。
> worker 节点无 `/etc/kubernetes/manifests` 目录。
>
> `kube-apiserver` 本身不访问别的 apiserver，只连本机的 etcd `https://127.0.0.1:2379`。
> 各控制面 apiserver 的 advertise-address 分别为 `10.0.0.61` / `10.0.0.121` / `10.0.0.120`。

---

## 四、普通 Pod 走 ClusterIP，负载均衡到三台

集群内 Pod 使用 in-cluster 配置：`KUBERNETES_SERVICE_HOST=10.96.0.1`，端口 `443`。
由 kube-proxy（iptables 模式）做 DNAT，随机分摊到**三台 apiserver**：

```
KUBE-SVC-... : 10.96.0.1:443 ->
  random 1/3 -> 10.0.0.120:6443   (master02)
  random 1/3 -> 10.0.0.121:6443   (master01)
  random 1/3 -> 10.0.0.61:6443    (m01)
```

因此**普通 Pod 是随机打到任意一台 apiserver**，与它所在节点无关。

---

## 五、几个值得注意的点

1. **静态 Pod（CM / Scheduler）永远只连自己那台的 apiserver**，非本地故障时不会自动切到别的 apiserver —— 这是 kubeadm 的默认行为。
2. **kube-proxy 存在单点**：所有节点（含 master01 / master02）的 kube-proxy 都连 `10.0.0.61:6443`（来自 configmap，因为 `kubeadm-config` 里 `controlPlaneEndpoint: 10.0.0.61:6443`）。m01 若彻底宕机，全集群 kube-proxy 会失去 apiserver。
3. **`kubeadm-config` 的 `controlPlaneEndpoint` 是 `10.0.0.61:6443`，并非 VIP**。只有 `admin.conf` 被改成了 VIP `10.0.0.168`。
4. master01 / master02 / worker 的 `kubelet.conf` 里都多出一份指向 VIP `10.0.0.168:6443` 的 `kubernetes` cluster 条目，但 `current-context` 用的是 `default-cluster`（本机 / m01），那份 VIP 条目是**未被使用的残留**。
5. kube-vip 开启了 `vip_preserve_on_leadership_loss=true`，VIP 已固定在当前 leader 上（master01 的 `eth0` 上可见 `10.0.0.168` 这个 secondary 地址）。

---

## 六、一句话总结

> 控制面静态 Pod 各连**本机** apiserver；
> worker 的 kubelet 连 **m01（10.0.0.61）**；
> kube-proxy 全部连 **m01**；
> 普通业务 Pod 经 Service ClusterIP **负载均衡到三台 apiserver**；
> 手工 `kubectl` 走 **VIP 10.0.0.168**，当前落在 **master01**。

---

## 七、概念澄清：谁负责什么

| 组件 | 是不是… | 真正的职责 |
|---|---|---|
| **kubelet** | 负责**在节点上真正创建/启动 Pod** | 节点代理（systemd 服务）。监听 API Server，把**已绑定到自己节点**的 Pod 落成容器；同时也独立加载静态 Pod |
| **kube-scheduler** | 负责**决定 Pod 去哪个节点** | 只做“选节点 + 写回 `spec.nodeName`（Binding）”，**不启动任何容器** |
| **kube-proxy** | 负责**维护 Service → 后端 的转发规则** | 监听 Service/EndpointSlice，在节点上写 iptables（本集群）/IPVS/nftables 规则；**真正的 DNAT 由内核完成**，kube-proxy 只是“写规则的人” |

### 7.1 kubelet 是各节点启动 Pod 的？—— 是，但“启动” ≠ “决定放哪”

- kubelet 是每台节点上的**节点代理**（本环境是 systemd 服务，本身不是 Pod）。
- 它做的事情：
  - 监听 API Server，取 `spec.nodeName == 自己` 的 Pod，通过 **CRI** 调容器运行时（containerd）真正创建/启动/停止容器；
  - 挂载卷、配置网络（调 CNI，如 Calico）、执行探针、上报 Pod/Node 状态；
  - 独立加载 **静态 Pod**（`/etc/kubernetes/manifests/*.yaml`），这条路径**不经过调度器**。
- 但**“Pod 放到哪台节点”不是 kubelet 决定的**，是 kube-scheduler 决定的（静态 Pod 除外）。
- 本环境佐证：6 台节点的 Pod 都带上了 `spec.nodeName`（m01:11、master01:12、master02:10、worker01:49、worker02:36、worker03:21），且不存在 `nodeName` 为空的 Pod（`kubectl get pods -A --field-selector spec.nodeName=` → `No resources found`）。说明“绑定”这一步已完成，kubelet 只负责落地。

> 一句话：**调度器决定“去哪”，kubelet 负责“把它跑起来”。**

### 7.2 kube-scheduler 负责调度？—— 是，但只做到“绑定”为止

- kube-scheduler 监听 API Server，对每个**没有 `nodeName` 的新 Pod**：
  1. **Filter（预选）**：按资源 requests、nodeSelector/affinity、taints/tolerations、拓扑分布、卷可用性等筛出可调度节点；
  2. **Score（优选）**：给候选节点打分，选最高分；
  3. **Bind（绑定）**：把决策写回 API Server（设置 `spec.nodeName`）。
- 绑定完成它就“下班了”，**不再碰容器**。后续拉镜像、起容器、跑探针全部是 kubelet 的事。
- 几个要点：
  - **静态 Pod 不经过 kube-scheduler**（由 kubelet 依据本地 manifest 直接跑）；
  - **DaemonSet 的 Pod 仍走默认调度器**（靠 nodeAffinity 保证每节点一个）；
  - 调度器多副本时通过 **leader 选举**只有一个在干活（本集群运行在 m01 的 `kube-scheduler` 通过 `scheduler.conf` → `10.0.0.61:6443`）。

### 7.3 kube-proxy 是把 Service 转成真实 Pod IP？—— 是，但“转”的是内核，kube-proxy 只写规则

- kube-proxy 监听 **Service + EndpointSlice**，在**每个节点**上维护转发规则（本集群 `--proxy-mode=iptables`）。
- 数据面：某个 Pod 访问 `Service ClusterIP:Port` 时，数据包在**客户端所在节点**命中 iptables，被 **DNAT** 成某个后端 **Pod IP:Port**；回包由 conntrack 反向改写回来。真正的转发与负载均衡是**内核 netfilter** 干的，而非 kube-proxy 进程逐包处理。
- iptables 模式用 `statistic --mode random` 做随机负载均衡（同一连接靠 conntrack 保持粘性）。
- **与本集群的联系**：`kubernetes` 这个 Service（`10.96.0.1:443`）也走同一套机制，只是它的后端不是 Pod，而是**三台 apiserver 的真实 IP**（`10.0.0.61/120/121:6443`）。所以“Pod 访问 apiserver”本质上就是“Pod 走了 kube-proxy 写的 Service 规则”。

> 一句话：**kube-proxy 不是代理进程，而是“规则生成器”；真正把 ClusterIP 换成真实 IP 的是内核。**

### 7.4 全部 worker 指向 10.0.0.61，合理吗？—— 能用，但**不推荐，存在单点故障**

**现状**

- worker01/02/03 的 `kubelet.conf`，其 `current-context`（`default-context`）指向 `default-cluster = https://10.0.0.61:6443`（即 m01）；
- 所有节点的 **kube-proxy** 也指向 `10.0.0.61:6443`（来自 `kube-system/kube-proxy` configmap，因为 `kubeadm-config` 的 `controlPlaneEndpoint` 就是 `10.0.0.61:6443`）。

**为什么会长这样**

- kubeconfig 是在 `kubeadm join` 时按**当时的 `controlPlaneEndpoint`** 生成的；本集群 join 时该端点是 m01，于是所有 worker / kube-proxy 都被写死成 m01。
- 换句话说，**VIP `10.0.0.168` 虽然已经建好，但 kubelet/kube-proxy 的 kubeconfig 并没有改用 VIP**（`kubelet.conf` 里那份指向 VIP 的 `kubernetes` cluster 条目是**未被 `current-context` 引用的残留**）。

**风险（为什么说不合理）**

1. **单点故障**：m01 的 apiserver 一旦挂掉/重启/被下线，所有 worker 的 kubelet 和全部 kube-proxy 立刻失去 API 连接 → 无法上报状态、拉取新 Pod、更新 Service/Endpoint 转发规则。
2. **本集群更明显**：`m01` 现在是 `SchedulingDisabled`（已被 cordon），却仍被当作全集群唯一的 API 入口；若它被真正下线/排水，影响面很大。
3. 明明有 3 个 control-plane 和现成的 VIP，却没有用上，HA 设计没有闭环。

**已经跑起来的容器会怎样**

- **不会立刻死**：kubelet 会继续维持本地已运行的容器。但节点会进入“失联”状态，控制面无法感知、也无法下发变更。

**建议做法（让 worker 走 HA 入口，任选其一）**

- **方案 A（推荐，改动最小）**：把 worker 的 `kubelet.conf` 从 `default-cluster(10.0.0.61)` 切到 VIP。文件里已存在指向 `10.0.0.168:6443` 的 `kubernetes` cluster，只需把 context/cluster 改成它，然后 `systemctl restart kubelet`。
- **方案 B（更彻底）**：重建/编辑默认 kubeconfig，让 `default-cluster` 或 `current-context` 直接指向 VIP，或用一份包含多个 server 的 kubeconfig。
- **kube-proxy**：把 `kube-system/kube-proxy` 这个 configmap 中 `kubeconfig.conf` 的 `server` 改为 `https://10.0.0.168:6443`，再滚动重启 kube-proxy DaemonSet。
- **面向未来**：把 `kubeadm-config` 的 `controlPlaneEndpoint` 设为 VIP，这样之后 join / 升级生成的 kubeconfig 会自动指向 VIP。
- **前置校验**：确认 apiserver 证书 SAN 里包含 VIP（`admin.conf` 已经能通过 VIP 访问，说明大概率已包含）；并确认 3 个控制面都装了 kube-vip、租约正常，否则换汤不换药。

> 结论：**功能上能跑，但架构上是单点，与“3 控制面 + kube-vip VIP”的 HA 目标不一致；建议把 worker 的 kubelet 与全集群 kube-proxy 统一指向 VIP `10.0.0.168:6443`。**

---

## 八、职责流转图（一个普通 Pod 的一生）

```
                    你: kubectl apply -f pod.yaml
                            │  (admin.conf → VIP 10.0.0.168)
                            ▼
                    ┌──────────────────┐
                    │   kube-apiserver │  把 Pod 对象写入 etcd（nodeName 为空）
                    └──────────────────┘
                            │ watch
                            ▼
                    ┌──────────────────┐
                    │  kube-scheduler  │  Filter + Score → Bind
                    └──────────────────┘
                            │ 回写 spec.nodeName（只做“绑定”）
                            ▼
       ┌───────────────────────────────────────────┐
       │  目标节点的 kubelet（watch 到自己名下的 Pod）  │
       │   • 调 CRI/containerd 真正起容器               │
       │   • 调 CNI(Calico) 配 Pod 网络                │
       │   • 上报 Pod/Node 状态                         │
       └───────────────────────────────────────────┘

   数据面（Pod 访问某个 Service）:
   Pod → Service ClusterIP:Port
        │  命中本节点 kube-proxy 写入的 iptables 规则
        ▼
   DNAT 到后端 Pod IP:Port  →  →  跨节点由 CNI(Calico) 路由
        │
        ▼
   内核 netfilter 完成转发（kube-proxy 只负责“写规则”）
```

**一句话对照**：**apiserver 存“期望状态” → scheduler 决定“放哪” → kubelet 负责“跑起来” → kube-proxy 负责“流量怎么转”。**
