# Calico Phase 0 实操与深度解析：IPIP MTU 1480 + Felix 指标

> 执行日期：2026-11-08  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 当前 CNI：Calico v3.32.2（BIRD + IPIP Always，iptables-nft 数据面）  
> 本文包含：本次实际执行记录、验证输出、回滚原因、IPIP/MTU 原理、Felix 指标架构与 PromQL 示例

---

## 0. 本次做了什么：结论先行

我按 Phase 0 理解执行了两件事：

| 项目 | 状态 | 结果 |
|---|---|---|
| 1. 启用 Calico Felix 指标 | ✅ **已保留** | `calico-node` 暴露 9091；Prometheus PodMonitor 6/6 target up；Grafana dashboard 已加载 |
| 2. Calico IPIP `Always` → `Never` 直连试验 | ⚠️ **已验证后回滚** | 直连路由/BGP/新 Pod MTU 1500 均验证成功；但旧 Pod 仍是 1480，出现**混合 MTU**，为避免生产风险回滚到 `Always` |
| 当前 IPIP 状态 | `Always` | 路由仍走 `tunl0`，Pod MTU 仍为 1480 |
| 当前 Felix 指标 | 开启 | 6/6 target up，76 个 `felix_*` metric family，约 194 条 series/节点 |

**一句话：**

> Felix 指标已经落地并可用；IPIP 直连已经证明可行，但因为“旧 Pod 1480 / 新 Pod 1500”的混合 MTU 需要全量滚动重启才能统一，本次没有在生产窗口外强行保留，已回滚到稳定状态。

---

## 1. 当前集群状态（执行后）

### 1.1 IPIP / MTU 状态

| 项目 | 当前值 |
|---|---|
| IPPool `default-ipv4-ippool.spec.ipipMode` | `Always` |
| `calico-node` env `CALICO_IPV4POOL_IPIP` | `Always` |
| `tunl0` MTU | `1480` |
| Pod veth/cali MTU | `1480` |
| 跨节点路由 | `10.244.x.x/26 via 172.16.1.x dev tunl0 proto bird` |
| `ping -M do -s 1472`（1500 字节 IP 包） | 失败（100% loss） |
| `ping -M do -s 1452`（1480 字节 IP 包） | 成功 |

### 1.2 Felix 指标状态

| 项目 | 当前值 |
|---|---|
| `calico-node` Felix metrics | 已启用，端口 `9091` |
| Prometheus PodMonitor | `monitoring/calico-node-felix` |
| Prometheus targets | 6/6 `up` |
| `felix_*` metric family | 76 个 |
| `felix_*` series（m01） | 约 194 条 |
| Grafana dashboard | ConfigMap `monitoring/calico-felix-dashboard`，已由 sidecar 加载 |

### 1.3 备份

所有变更前的对象已备份到：

```text
/root/calico-phase0-backup-20261108/
├── calico-node-ds.yaml
├── ippool.yaml
├── calico-config.yaml
├── podmonitor-calico-node-felix.yaml
├── calico-felix-dashboard.json
```

---

## 2. IPIP 深度解析

### 2.1 IPIP 是什么

IPIP（IP-in-IP）是把**一个完整的 IP 包**封装在另一个 IP 包里传输的隧道技术。

- 外层 IP 头：源/目的地址是**节点 IP**（本集群是 `172.16.1.x`）。
- 内层 IP 包：源/目的地址是 **Pod IP**（本集群是 `10.244.x.x`）。
- IP 协议号：**4**（IPIP）。
- Linux 上通常表现为 `tunl0` 隧道接口。
- IPIP **不加密、不认证**，只做封装/解封装。

报文结构：

```text
┌─────────────────────────────────────────────────────────────┐
│ Outer IPv4 Header (20 B)                                    │
│   src = node A 172.16.1.61                                  │
│   dst = node B 172.16.1.122                                 │
│   protocol = 4 (IPIP)                                       │
├─────────────────────────────────────────────────────────────┤
│ Inner IPv4 Header (20 B)                                    │
│   src = pod A 10.244.28.101                                 │
│   dst = pod B 10.244.5.78                                   │
│   protocol = TCP/UDP/ICMP                                   │
├─────────────────────────────────────────────────────────────┤
│ TCP/UDP Header + Payload                                    │
└─────────────────────────────────────────────────────────────┘
```

在节点上：

```text
Pod veth (caliXXXX)  MTU 1480
        │
        ▼
    tunl0 (IPIP)     MTU 1480
        │  加 20 字节外层 IP 头
        ▼
    eth1 (172.16.1.x) MTU 1500
```

### 2.2 为什么 IPIP 会导致 MTU 1480

物理网卡 MTU 是 1500 字节，这是**一个以太网帧能承载的最大 IP 包**（不含以太网头）。

IPIP 封装后，外层 IP 头要占 **20 字节**：

```text
1500（物理 MTU）
- 20（外层 IPv4 头）
= 1480（隧道内层可用的最大 IP 包）
```

所以：

- `tunl0` MTU = **1480**
- Pod veth/`cali*` MTU = **1480**
- Pod 内 TCP MSS 通常是 `1480 - 20（内层 IP） - 20（TCP） = 1440`
- UDP 最大 payload 约为 `1480 - 20（内层 IP） - 8（UDP） = 1452`

用 `ping` 验证非常直观：

```text
ping -M do -s 1472 <pod-ip>
# 1472 payload + 8 ICMP + 20 IP = 1500
# 但 Pod/隧道 MTU 只有 1480，所以失败

ping -M do -s 1452 <pod-ip>
# 1452 + 8 + 20 = 1480
# 正好等于 MTU，所以成功
```

本次实测完全符合：

```text
# IPIP Always，cali MTU 1480
ping -M do -s 1472 10.244.5.78  -> 100% packet loss
ping -M do -s 1452 10.244.5.78  -> 0% packet loss，RTT 0.5 ms

cali06b9a9c2b81 MTU = 1480
ip route get 10.244.5.78
  10.244.5.78 via 172.16.1.122 dev tunl0
```

### 2.3 Calico 如何决定 Pod MTU

当前 `calico-config`：

```yaml
data:
  veth_mtu: "0"
```

`veth_mtu: "0"` 表示**自动推导**，Calico/Felix 会根据封装方式计算：

| 封装方式 | 自动 MTU | 说明 |
|---|---:|---|
| 无封装（IPIP Never / 直连） | 1500 | 使用物理网卡 MTU |
| IPIP | 1480 | 1500 - 20 |
| VXLAN | 1450 | 1500 - 50 |
| Geneve | 约 1442 | 1500 - 58（选项可变） |

相关环境变量：

```text
FELIX_IPINIPMTU   <- configMapKeyRef: calico-config/veth_mtu
FELIX_VXLANMTU    <- configMapKeyRef: calico-config/veth_mtu
FELIX_WIREGUARDMTU<- configMapKeyRef: calico-config/veth_mtu
```

所以当前是：

```text
veth_mtu=0
  + IPIP Always
  -> 自动 1480
  -> Pod veth 1480
```

如果改成 IPIP Never，自动 MTU 会变成 1500，但**只对新建 Pod 生效**；已有 Pod 的 veth 不会自动改变。这是本次回滚的直接原因。

### 2.4 IPIP 的三种模式

Calico IPPool 的 `ipipMode` 有三种：

| 模式 | 行为 | MTU | 适用场景 | 风险 |
|---|---|---|---:|---|---|
| `Always` | 所有跨节点 Pod 流量都 IPIP 封装 | 1480 | 节点跨网段、底层网络不路由 Pod CIDR | 有封装开销、MTU 损失 |
| `CrossSubnet` | 只有跨子网的节点之间才封装；同子网直连 | 通常仍按 IPIP 配置为 1480（取决于实现/配置） | 混合网络：同子网性能好，跨子网兼容 | 同子网未必能拿到 1500；跨子网仍需 1480 |
| `Never` | 完全不封装，完全依赖 BGP/底层路由 | 1500 | 所有节点在同一二层，或底层网络能路由 Pod CIDR | 依赖 BGP/路由；跨网段无路由时 Pod 网络断 |

**关键点：**

- `CrossSubnet` 看起来“同子网不封装”，但 Calico 仍可能因为 IPIP 已启用而把 veth MTU 设为 1480；它不一定能拿到 1500。
- 想稳定拿到 1500，通常要用 `Never`，或显式设置 `veth_mtu: "1500"`（仅当确认不会跨子网封装）。
- 本次实测：`Never` 后新建 Pod MTU 1500；旧 Pod 仍 1480。

### 2.5 与其他封装的 MTU 对比

| 封装 | 额外开销 | 1500 物理 MTU 下的有效 MTU | 备注 |
|---|---:|---:|---|
| 无封装/直连 | 0 | **1500** | 需要底层路由/同二层 |
| IPIP | 20 B | **1480** | 当前模式；不加密 |
| VXLAN | 50 B | **1450** | UDP 8 + VXLAN 8 + 内层以太网 14 + 外层 IP 20 |
| Geneve | 约 58 B | **约 1442** | 选项可变 |
| WireGuard | 约 60–80 B | 约 1420–1440 | 加密场景；取决于实现 |

所以：**当前 IPIP 的 1480 已经比 VXLAN 1450 好，但仍比直连 1500 少 20 字节。**

### 2.6 BGP 直连路由是怎么工作的

Calico 的 BIRD 在每个节点上运行，负责把本节点的 Pod CIDR 通过 BGP 通告给其他节点。

当前 BGP mesh 状态（实测）：

```text
BIRD v0.3.3+birdv1.6.8 ready.
Mesh_172_16_1_120  BGP  master  up  Established
Mesh_172_16_1_121  BGP  master  up  Established
Mesh_172_16_1_122  BGP  master  up  Established
Mesh_172_16_1_124  BGP  master  up  Established
Mesh_172_16_1_61   BGP  master  up  Established
```

IPIP `Always` 时：

```text
10.244.5.0/26 via 172.16.1.122 dev tunl0 proto bird
```

IPIP `Never` 时（本次实测）：

```text
10.244.5.0/26 via 172.16.1.122 dev eth1 proto bird
```

区别：

- `tunl0`：内核先给包加外层 IP 头，再走 eth1。
- `eth1`：内核直接把包发给 `172.16.1.122`（下一跳节点），由节点转发到 Pod。
- 因为 6 个节点都在 `172.16.1.0/16` 同一二层，节点 IP 可以直接 ARP，不需要路由器。
- 所以 `Never` 在本集群是可行的；BGP 已经验证 Established。

如果节点跨网段，或者底层网络不允许节点转发 Pod CIDR，那么 `Never` 会导致跨节点 Pod 不通；这时要用 `CrossSubnet` 或 VXLAN/IPIP。

### 2.7 MTU、MSS、PMTUD 与分片

- **MTU**：接口能发送的最大 IP 包。
- **MSS**：TCP 最大段大小，通常是 `MTU - IP 头 - TCP 头`。
- **PMTUD**：路径 MTU 发现，依赖 ICMP “Fragmentation Needed”；如果 ICMP 被防火墙拦截，会出现“大包不通、小包正常”。
- **DF 位**：`ping -M do` 设置 Don't Fragment；超过 MTU 直接失败，不会分片。

IPIP 场景：

```text
Pod 内 MTU 1480
TCP MSS 1440
UDP 大包 > 1452 可能被分片/丢弃
```

直连场景：

```text
Pod 内 MTU 1500
TCP MSS 1460
```

**混合 MTU 的风险：**

- 旧 Pod 1480，新 Pod 1500。
- TCP 通常通过 MSS 协商取较小值（1440），大多数 TCP 没问题。
- UDP、ICMP、某些不做 PMTUD 的应用可能出现“大包不通”。
- 如果底层网络/防火墙拦截 ICMP Frag Needed，问题更难排查。
- 因此生产环境应尽量让所有 Pod 的 MTU 一致；变更 MTU 后要滚动重启所有 Pod。

### 2.8 性能与安全影响

| 维度 | IPIP Always | 直连（Never） |
|---|---|---|
| 额外头部 | 20 B/包 | 0 |
| 有效载荷损失 | 约 1.33%（20/1500） | 0 |
| 封装/解封装 CPU | 有 | 无 |
| 延迟 | 略高（隧道处理） | 略低 |
| 吞吐 | 略低（MTU + CPU） | 略高 |
| 排障 | 多一层 `tunl0` | 路由更直观 |
| 加密 | 无 | 无（需要 WireGuard/IPsec） |
| 防火墙 | 需要允许 IP 协议 4 | 只需允许节点间 Pod CIDR 路由 |

本集群当前总 Pod 流量约 **75 Mbps**，所以 1.33% 的 MTU 差异在业务上几乎不可见；IPIP 的主要成本是“多一层封装 + MTU 变小”，不是当前瓶颈。但在高吞吐/高 PPS 场景，直连会更有价值。

### 2.9 本次 IPIP 试验的实测结果

#### 变更前（Always）

```text
ip route get 10.244.5.78
  10.244.5.78 via 172.16.1.122 dev tunl0

cali06b9a9c2b81 MTU = 1480

ping -M do -s 1472 10.244.5.78 -> 100% packet loss
ping -M do -s 1452 10.244.5.78 -> 0% packet loss
```

#### 变更后（Never，临时）

```text
IPPool ipipMode = Never
calico-node env CALICO_IPV4POOL_IPIP = Never

ip route:
  10.244.5.0/26 via 172.16.1.122 dev eth1 proto bird
  10.244.30.64/26 via 172.16.1.123 dev eth1 proto bird

新建 Pod（worker02，10.244.30.144）:
  eth0 MTU = 1500

宿主机 -> 新 Pod:
  ping -M do -s 1472 10.244.30.144 -> 0% packet loss

宿主机 -> 旧 Pod:
  ping -M do -s 1472 10.244.5.78 -> 100% packet loss（旧 Pod 仍 1480）

BGP:
  5 个 mesh 邻居全部 Established

Ingress:
  curl -H 'Host: studyfree.xyz' http://10.0.0.252/ -> 200
```

#### 为什么回滚

- 新 Pod 已经是 1500，旧 Pod 仍是 1480。
- 要让全集群统一 1500，需要**滚动重启所有非 hostNetwork Pod**（143 个 Pod，含 Kafka/CNPG/Prometheus/Loki/Tempo/Tekton/ArgoCD 等）。
- 这本质上是一个维护窗口操作，不能在不通知业务的情况下直接做。
- 为避免混合 MTU 带来的 UDP/PMTUD 隐患，已回滚到 `Always`，恢复统一的 1480。

#### 回滚后（当前）

```text
IPPool ipipMode = Always
calico-node env CALICO_IPV4POOL_IPIP = Always
路由恢复 via tunl0
ping -M do -s 1472 -> 100% loss
ping -M do -s 1452 -> 0% loss
Felix 指标仍保持开启，6/6 target up
```

---

## 3. Felix 深度解析

### 3.1 Calico 的组件架构

当前集群的 Calico 是 **manifest 安装、Kubernetes CRD datastore、无 Typha**：

```text
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes API / CRD datastore                              │
│   IPPool / FelixConfiguration / BGPConfiguration / NP ...   │
└───────────────┬─────────────────────────────────────────────┘
                │ watch
┌───────────────▼─────────────────────────────────────────────┐
│ calico-node DaemonSet（每个节点一个 Pod）                    │
│                                                             │
│  ┌─────────────┐   ┌─────────────┐   ┌──────────────────┐  │
│  │   Felix     │   │    BIRD     │   │      confd       │  │
│  │ 策略/数据面 │   │ BGP 路由    │   │ 生成 BIRD 配置   │  │
│  └──────┬──────┘   └──────┬──────┘   └──────────────────┘  │
│         │                 │                                 │
│         ▼                 ▼                                 │
│  iptables/ipsets      kernel routes                         │
│  nftables/BPF         (tunl0 / eth1)                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ CNI plugin（calico-cni）：创建 veth、调用 IPAM        │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ calico-kube-controllers                                     │
│   IPAM 回收、policy/namespace 同步、workload endpoint 同步  │
└─────────────────────────────────────────────────────────────┘
```

当前 `calico-config` 里：

```yaml
typha_service_name: none
calico_backend: bird
```

说明：

- **没有 Typha**。6 节点规模下，Felix 直接 watch Kubernetes datastore 没问题。
- 规模超过几十个节点时，通常引入 Typha 作为 datastore 代理，降低 API Server 压力。
- `calico_backend: bird` 表示 BGP 路由由 BIRD 负责。
- 当前没有启用 Calico eBPF 数据面。

### 3.2 Felix 的职责

Felix 是 Calico 的**每节点策略/数据面代理**，主要职责：

1. **策略计算与下发**
   - 把 Kubernetes NetworkPolicy、Calico NetworkPolicy 转换成数据面规则。
   - 维护 selector → endpoint 的映射。
   - 计算 allow/deny 规则。
2. **Endpoint 管理**
   - 为本节点 Pod 创建/更新路由、veth、iptables/ipsets 规则。
   - 维护 host endpoint（如果使用）。
3. **数据面编程**
   - iptables/ipset（当前）。
   - nftables（如果启用 nftables 模式）。
   - eBPF（如果启用 Calico eBPF 数据面）。
4. **路由/接口**
   - 管理 `cali*` veth、`tunl0`、本地路由。
   - 与 BIRD 协作发布 Pod CIDR。
5. **健康与指标**
   - 暴露 Prometheus 指标（本次启用的 9091）。
   - 健康检查、日志、resync。

### 3.3 当前 Felix 的数据面

从本次抓到的指标可以看出：

```text
felix_iptables_restore_calls   4
felix_iptables_save_calls      24
felix_iptables_lines_executed  7
felix_nft_calls                0
felix_nft_list_calls           17
felix_nft_set_calls            0
felix_nft_errors               0
felix_int_dataplane_failures   0
```

解读：

- `felix_iptables_*` 有值，说明 Felix 在使用 **iptables/iptables-nft** 编程数据面。
- `felix_nft_calls` / `felix_nft_set_calls` 为 0，说明没有走原生 nftables 编程（`felix_nft_list_calls` 可能是清理/探测时的 list 调用）。
- `felix_int_dataplane_failures=0`，当前数据面下发没有失败。
- 这与前面 `CALICO_NETWORKING_BACKEND=bird`、`tc` 无 BPF filter 的事实一致：**当前是 iptables 数据面，不是 Calico eBPF**。

### 3.4 Felix 指标是怎么暴露的

Felix 内置 Prometheus metrics server：

```text
calico-node（hostNetwork）
  └─ Felix :9091/metrics
       │
       ▼
Prometheus PodMonitor `monitoring/calico-node-felix`
  namespaceSelector: kube-system
  selector: k8s-app=calico-node
  port: felix-metrics
       │
       ▼
Prometheus（serviceMonitorSelector/podMonitorSelector: release=prometheus）
       │
       ▼
Grafana dashboard `Calico Felix - Node Dataplane`
```

关键配置：

```yaml
# calico-node DaemonSet
env:
  - name: FELIX_PROMETHEUSMETRICSENABLED
    value: "true"
  - name: FELIX_PROMETHEUSMETRICSPORT
    value: "9091"
ports:
  - name: felix-metrics
    containerPort: 9091
    protocol: TCP
```

本次创建的 PodMonitor：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: calico-node-felix
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: calico-node
  podMetricsEndpoints:
    - port: felix-metrics
      interval: 15s
      path: /metrics
      scheme: http
```

验证结果：

```text
Prometheus target job: monitoring/calico-node-felix
6/6 targets up
每个 target: http://10.0.0.x:9091/metrics
```

### 3.5 Felix 指标分组与含义

当前每个节点暴露 **76 个 `felix_*` metric family**。按用途分组：

#### A. 本节点 endpoint / policy / selector

| 指标 | 含义 | 本次 m01 示例 |
|---|---|---:|
| `felix_active_local_endpoints` | 本节点活跃 workload endpoint 数 | 1 |
| `felix_active_local_policies` | 本节点生效策略数 | 0 |
| `felix_active_local_selectors` | 本节点活跃 selector 数 | 0 |
| `felix_label_index_num_endpoints` | label index 中的 endpoint 数 | — |
| `felix_label_index_num_active_selectors` | 活跃 selector 数 | — |
| `felix_label_index_selector_evals` | selector 评估次数 | — |

#### B. 集群级聚合（来自 datastore）

| 指标 | 含义 | 本次示例 |
|---|---|---:|
| `felix_cluster_num_hosts` | 集群节点数 | 6 |
| `felix_cluster_num_workload_endpoints` | 集群 workload endpoint 数 | 97 |
| `felix_cluster_num_policies` | 集群策略数 | 18 |
| `felix_cluster_num_profiles` | profile 数 | — |
| `felix_cluster_num_host_endpoints` | host endpoint 数 | — |
| `felix_cluster_num_tiers` | tier 数 | — |

> 97 个 workload endpoint 小于 143 个 Pod，是因为 hostNetwork Pod、静态 Pod 不走 Calico CNI。

#### C. 数据面下发

| 指标 | 含义 | 本次示例 |
|---|---|---:|
| `felix_int_dataplane_apply_time_seconds` | 数据面 apply 耗时 | 约 0.0317 s |
| `felix_int_dataplane_failures` | 数据面失败次数 | 0 |
| `felix_int_dataplane_messages` | 数据面消息数 | 2 |
| `felix_int_dataplane_msg_batch_size` | 消息批大小 | — |
| `felix_resyncs_started` | resync 启动次数 | 1 |
| `felix_resync_state` | resync 内部状态枚举 | 3（需结合源码解读，不建议直接告警） |

#### D. iptables / ipset（当前主要数据面）

| 指标 | 含义 | 本次示例 |
|---|---|---:|
| `felix_iptables_chains` | 管理的 iptables 链数 | 20 |
| `felix_iptables_rules` | 管理的 iptables 规则数 | 52 |
| `felix_iptables_lines_executed` | 执行的 iptables 命令行数 | 7 |
| `felix_iptables_restore_calls` | `iptables-restore` 调用次数 | 4 |
| `felix_iptables_save_calls` | `iptables-save` 调用次数 | 24 |
| `felix_iptables_restore_errors` | restore 错误数 | 0 |
| `felix_iptables_save_errors` | save 错误数 | 0 |
| `felix_ipsets_calico` | Calico 管理的 ipset 数 | 5 |
| `felix_ipset_calls` | ipset 调用次数 | 0 |
| `felix_ipset_errors` | ipset 错误数 | 0 |
| `felix_ipset_lines_executed` | ipset 命令行数 | — |

#### E. nftables（当前未走原生 nft 编程）

| 指标 | 含义 | 本次示例 |
|---|---|---:|
| `felix_nft_calls` | nft 调用次数 | 0 |
| `felix_nft_list_calls` | nft list 调用次数 | 17 |
| `felix_nft_set_calls` | nft set 调用次数 | 0 |
| `felix_nft_errors` | nft 错误数 | 0 |
| `felix_nft_chains` | nft 链数 | — |
| `felix_nft_rules` | nft 规则数 | — |

#### F. BPF（当前未启用，仅保留指标）

| 指标 | 含义 |
|---|---|
| `felix_bpf_dataplane_endpoints` | BPF 数据面 endpoint 数 |
| `felix_bpf_dirty_dataplane_endpoints` | 需要更新的 endpoint 数 |
| `felix_bpf_happy_dataplane_endpoints` | 状态正常的 endpoint 数 |
| `felix_bpf_conntrack_used` | BPF conntrack 使用量 |
| `felix_bpf_conntrack_sweeps` | BPF conntrack 扫描次数 |
| `felix_bpf_num_ip_sets` | BPF IP set 数 |

当前这些值应接近 0/不活跃；如果启用 Calico eBPF，这些指标才有意义。

#### G. 路由 / 日志 / 运行时

| 指标 | 含义 |
|---|---|
| `felix_route_table_num_routes` | 路由表路由数 |
| `felix_route_table_resync_seconds` | 路由表 resync 耗时 |
| `felix_log_errors` | 日志错误数 |
| `felix_logs_dropped` | 被丢弃日志数 |
| `felix_exec_time_micros` | Felix 内部执行时间 |
| `felix_host` | 主机信息（label 形式） |

### 3.6 推荐的 PromQL 与告警

#### 基础查询

```promql
# 每个节点的 endpoint 数
felix_active_local_endpoints

# 集群 workload endpoint 总数（各节点重复，取 max）
max(felix_cluster_num_workload_endpoints)

# 集群策略总数
max(felix_cluster_num_policies)

# 每个节点的 iptables 规则/链
felix_iptables_rules
felix_iptables_chains

# 数据面 apply 耗时
felix_int_dataplane_apply_time_seconds

# 数据面失败
felix_int_dataplane_failures

# iptables restore 错误增长
increase(felix_iptables_restore_errors[5m])

# ipset 错误增长
increase(felix_ipset_errors[5m])

# resync 频率
rate(felix_resyncs_started[5m])

# 日志错误/丢弃
felix_log_errors
felix_logs_dropped
```

#### 建议告警规则（示例）

```yaml
groups:
  - name: calico-felix
    rules:
      - alert: CalicoFelixDataplaneFailures
        expr: increase(felix_int_dataplane_failures[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Calico Felix 数据面下发失败"
          description: "节点 {{ $labels.instance }} 在 5 分钟内出现数据面失败。"

      - alert: CalicoFelixIptablesRestoreErrors
        expr: increase(felix_iptables_restore_errors[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Calico iptables restore 错误"
          description: "节点 {{ $labels.instance }} iptables restore 出现错误。"

      - alert: CalicoFelixIpsetErrors
        expr: increase(felix_ipset_errors[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Calico ipset 错误"
          description: "节点 {{ $labels.instance }} ipset 操作出现错误。"

      - alert: CalicoFelixLogErrors
        expr: increase(felix_log_errors[5m]) > 0
        for: 10m
        labels:
          severity: info
        annotations:
          summary: "Calico Felix 日志错误"
          description: "节点 {{ $labels.instance }} 出现 Felix 日志错误。"

      - alert: CalicoFelixResyncStorm
        expr: rate(felix_resyncs_started[5m]) > 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Calico Felix resync 频繁"
          description: "节点 {{ $labels.instance }} resync 频率异常。"
```

注意：

- `felix_resync_state` 是内部枚举，不建议直接做阈值告警；用 `felix_resyncs_started` 的 rate 更稳。
- `felix_log_errors` 可能是累计值/瞬时值，先观察基线再定阈值。
- `felix_iptables_rules` 会随策略/Service 变化，不要设死阈值；看趋势和突增。

### 3.7 Grafana dashboard

已创建：

```text
ConfigMap: monitoring/calico-felix-dashboard
Label:     grafana_dashboard=1
File:      calico-felix.json
Title:     Calico Felix - Node Dataplane
UID:       calico-felix-node
```

面板包括：

1. Active local endpoints
2. Cluster workload endpoints
3. Cluster policies
4. Local iptables rules
5. iptables rules / chains 趋势
6. iptables restore / save calls（rate）
7. ipset calls / errors（rate）
8. dataplane apply time
9. resyncs started（rate）
10. dataplane failures / log errors / dropped logs

Grafana sidecar 已确认加载：

```text
Writing /tmp/dashboards/calico-felix.json (ascii)
Dashboards config reloaded
```

### 3.8 Felix 指标 vs Hubble / 流日志

两者不是一回事：

| 能力 | Felix 指标 | Hubble / 流日志 |
|---|---|---|
| 定位 | 节点数据面健康/策略下发 | 网络流级可观测性 |
| 数据 | endpoint、iptables/ipset、resync、错误 | 五元组、verdict、L7、DNS、TCP |
| 排障问题 | “Felix 是否正常工作？” | “这个 Pod 为什么连不上？” |
| 开销 | 很低（Prometheus 抓取） | 较高（flow buffer、存储） |
| 当前状态 | ✅ 已启用 | ❌ 未部署 |

**结论：Felix 指标补的是“Calico 自身健康”的盲区；Hubble 补的是“业务流”的盲区。两者互补，不互相替代。**

---

## 4. 本次执行记录

### 4.1 Felix 指标启用

#### 变更

```bash
kubectl -n kube-system patch ds calico-node --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FELIX_PROMETHEUSMETRICSENABLED","value":"true"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FELIX_PROMETHEUSMETRICSPORT","value":"9091"}},
  {"op":"add","path":"/spec/template/spec/containers/0/ports","value":[{"name":"felix-metrics","containerPort":9091,"protocol":"TCP"}]}
]'
```

注意：`calico-node` 原来没有 `ports` 字段；第一次尝试 `add /ports/-` 失败，改为直接设置整个 `ports` 数组后成功。

#### 结果

```text
daemonset.apps/calico-node patched
daemon set "calico-node" successfully rolled out

curl http://10.0.0.61:9091/metrics
# 194 条 felix_* series
# 76 个 felix_* metric family
```

创建 PodMonitor 后：

```text
Prometheus job: monitoring/calico-node-felix
6/6 targets up
```

#### 影响

- 只增加 metrics endpoint，不改变数据面。
- `calico-node` 滚动重启一次；BGP/Felix 重新建立，业务未中断。
- 指标开销很低；Prometheus 15s 抓取，6 个 target。

### 4.2 IPIP `Always` → `Never` 试验

#### 变更

```bash
# 1) 修改 calico-node 环境变量（index 6 = CALICO_IPV4POOL_IPIP）
kubectl -n kube-system patch ds calico-node --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Never"}]'

# 2) 修改 IPPool
kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Never"}}'
```

#### 结果

```text
IPPool ipipMode = Never
calico-node env CALICO_IPV4POOL_IPIP = Never

BGP mesh: 5/5 Established
路由: 10.244.x.x/26 via 172.16.1.x dev eth1 proto bird

新建 Pod MTU: 1500
宿主机 -> 新 Pod ping -M do -s 1472: 成功
宿主机 -> 旧 Pod ping -M do -s 1472: 失败（旧 Pod 仍 1480）
Ingress: HTTP 200
```

#### 为什么没有保留

- 旧 Pod 不会自动改 MTU；只有新 Pod 是 1500。
- 统一 MTU 需要滚动重启全部 143 个 Pod，涉及 Kafka/CNPG/Prometheus/Loki/Tempo/Tekton/ArgoCD，必须走维护窗口。
- 混合 MTU 对 TCP 通常可通过 MSS 协商兼容，但 UDP/ICMP/PMTUD 有风险；生产环境不应长期保留。
- 已回滚到 `Always`，当前统一 1480。

#### 回滚

```bash
kubectl -n kube-system patch ds calico-node --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Always"}]'

kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Always"}}'
```

回滚后：

```text
路由恢复 via tunl0
ping -M do -s 1472 -> 100% loss
ping -M do -s 1452 -> 0% loss
Felix 指标仍 6/6 up
Ingress 200
```

### 4.3 如果要正式完成 IPIP 直连（维护窗口方案）

建议在维护窗口执行，顺序如下：

1. **备份**
   ```bash
   kubectl -n kube-system get ds calico-node -o yaml > backup/calico-node-ds.yaml
   kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml > backup/ippool.yaml
   kubectl -n kube-system get cm calico-config -o yaml > backup/calico-config.yaml
   ```

2. **确认 BGP mesh 全部 Established**
   ```bash
   P=$(kubectl -n kube-system get pods -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}')
   kubectl -n kube-system exec $P -- birdcl show protocols
   ```

3. **切换 IPIP**
   ```bash
   kubectl -n kube-system patch ds calico-node --type=json \
     -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Never"}]'
   kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
     --type=merge -p '{"spec":{"ipipMode":"Never"}}'
   kubectl -n kube-system rollout status ds/calico-node
   ```

4. **验证路由与 BGP**
   ```bash
   ip route | grep 10.244
   # 期望：via <node-ip> dev eth1（不再 via tunl0）
   ```

5. **滚动重启所有非 hostNetwork Pod，统一 MTU**
   - 按命名空间逐个重启，先核心（CoreDNS、Traefik、monitoring），再业务（Kafka、CNPG、Tekton、ArgoCD）。
   - 对每个命名空间：
     ```bash
     kubectl -n <ns> rollout restart deploy,sts
     kubectl -n <ns> rollout status deploy,sts
     ```
   - 注意：单副本 Traefik、单 broker Kafka、CNPG primary 需要逐个处理，避免同时不可用。

6. **验证新 Pod MTU**
   ```bash
   kubectl run mtu-test --image=docker.io/library/busybox:1.37 --restart=Never --command -- sleep 600
   kubectl exec mtu-test -- cat /sys/class/net/eth0/mtu
   # 期望：1500
   ```

7. **验证跨节点 1500 字节 DF**
   ```bash
   # 从宿主机 ping 新 Pod
   ping -M do -s 1472 -c 2 <new-pod-ip>
   # 期望：0% loss
   ```

8. **回滚方案**
   ```bash
   kubectl -n kube-system patch ds calico-node --type=json \
     -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Always"}]'
   kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
     --type=merge -p '{"spec":{"ipipMode":"Always"}}'
   ```

**替代方案：**

- 如果不想全量重启，可保持 `CrossSubnet` + 1480，只获得“同子网不封装”的 CPU 收益，不获得 MTU 1500。
- 如果确定永远同二层，可用 `Never` + `veth_mtu: "1500"`；但未来新增跨网段节点会出问题。
- 如果未来需要跨子网，保留 `Always` 或 `CrossSubnet`，不要强行 1500。

---

## 5. 结论与下一步

### 5.1 本次结论

1. **Felix 指标是低风险、高性价比的 Phase 0 动作**：已启用、已抓取、已有 dashboard；可以直接用于日常排障和告警。
2. **IPIP 直连技术上可行**：BGP mesh 正常，`Never` 后路由走 eth1，新 Pod MTU 1500，1500 字节 DF ping 成功。
3. **不能直接在生产保留**：旧 Pod 仍 1480，混合 MTU 需要全量滚动重启才能统一；本次已回滚到 `Always`。
4. **当前集群稳定**：IPIP Always、Pod MTU 1480、Felix 6/6 up、Ingress 200。

### 5.2 下一步建议

- **保留 Felix 指标**，补 3–5 条告警（数据面失败、iptables restore 错误、ipset 错误、resync 风暴）。
- **规划 IPIP 直连维护窗口**：按 4.3 执行，重点是对全部 Pod 做滚动重启，确保 MTU 统一 1500。
- **不要现在做 Cilium 全量替换**：Phase 0 的 Felix 指标 + IPIP 直连已经能拿到一部分收益；Cilium/Hubble 仍建议先走 chaining pilot。

---

## 附录 A：本次关键验证输出

### A.1 Felix 指标

```text
curl http://10.0.0.61:9091/metrics | grep -c '^felix_'
194

# metric families
76

# 关键值（m01）
felix_active_local_endpoints 1
felix_cluster_num_hosts 6
felix_cluster_num_workload_endpoints 97
felix_cluster_num_policies 18
felix_iptables_chains 20
felix_iptables_rules 52
felix_ipsets_calico 5
felix_int_dataplane_apply_time_seconds 0.031685568
felix_int_dataplane_failures 0
felix_resyncs_started 1
felix_log_errors 4
felix_nft_calls 0
felix_nft_list_calls 17
```

### A.2 Prometheus target

```text
job: monitoring/calico-node-felix
calico-node-8xkbw  10.0.0.122:9091  up
calico-node-gr8dx  10.0.0.61:9091   up
calico-node-hq525  10.0.0.124:9091  up
calico-node-kgwbr  10.0.0.123:9091  up
calico-node-qbzkd  10.0.0.120:9091  up
calico-node-r97jf  10.0.0.121:9091  up
```

### A.3 IPIP 切换前/后/回滚

| 阶段 | 路由 | Pod MTU | ping 1472 DF | ping 1452 DF |
|---|---|---|---:|---:|
| 切换前 Always | via tunl0 | 1480 | 失败 | 成功 |
| 切换后 Never | via eth1 | 新 Pod 1500；旧 Pod 1480 | 新 Pod 成功；旧 Pod 失败 | 成功 |
| 回滚后 Always | via tunl0 | 1480 | 失败 | 成功 |

### A.4 备份与对象

```text
/root/calico-phase0-backup-20261108/calico-node-ds.yaml
/root/calico-phase0-backup-20261108/ippool.yaml
/root/calico-phase0-backup-20261108/calico-config.yaml
/root/calico-phase0-backup-20261108/podmonitor-calico-node-felix.yaml
/root/calico-phase0-backup-20261108/calico-felix-dashboard.json
```

Kubernetes 对象：

```text
monitoring/PodMonitor calico-node-felix
monitoring/ConfigMap calico-felix-dashboard (label grafana_dashboard=1)
```

---

## 附录 B：命令速查

```bash
# 查看 IPIP 状态
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.ipipMode}{"\n"}'
kubectl -n kube-system get ds calico-node -o json | \
  jq -r '.spec.template.spec.containers[0].env[] | select(.name=="CALICO_IPV4POOL_IPIP") | .value'

# 查看路由
ip route | grep 10.244
ip route get <pod-ip>

# 查看 BGP
P=$(kubectl -n kube-system get pods -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $P -- birdcl show protocols
kubectl -n kube-system exec $P -- birdcl show route

# 查看 MTU
cat /sys/class/net/tunl0/mtu
for i in $(ip -br link show | awk -F'[ @]' '/cali/{print $1}'); do echo -n "$i "; cat /sys/class/net/$i/mtu; done

# 验证 MTU（DF）
ping -M do -s 1472 -c 2 <pod-ip>   # 1500 字节 IP 包
ping -M do -s 1452 -c 2 <pod-ip>   # 1480 字节 IP 包

# Felix 指标
curl -s http://<node-ip>:9091/metrics | grep '^felix_'
curl -s http://<node-ip>:9091/metrics | awk '/^# TYPE felix_/{print $3}' | sort -u

# Prometheus 查询
kubectl -n monitoring port-forward svc/prometheus-prometheus 19090:9090
curl -s 'http://127.0.0.1:19090/api/v1/query?query=felix_active_local_endpoints'
```

---

## 附录 C：参考

- Calico IPPool / IPIP 模式：<https://docs.tigera.io/calico/latest/reference/calicoctl/resources/ippool>
- Calico MTU 配置：<https://docs.tigera.io/calico/latest/networking/configuring/mtu>
- Calico Felix 配置：<https://docs.tigera.io/calico/latest/reference/felix/configuration>
- Calico 监控指标：<https://docs.tigera.io/calico/latest/operations/monitor>
- Prometheus Operator PodMonitor：<https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PodMonitor>
- Cilium Hubble（对比用）：<https://docs.cilium.io/en/stable/observability/hubble/>

---

**报告结束。**
