# 02 · Cilium / eBPF：从 Calico + kube-proxy 到全量 eBPF 数据面

## 当时的情况

2026-11 之前，集群网络是典型的“传统三件套”：

- CNI：**Calico v3.32.2**，BIRD + **IPIP Always**（不是 Calico eBPF 数据面）；
- Service：**kube-proxy iptables**（早期是 IPVS，1.29→1.35 升级时迁到 iptables）；
- 入口 VIP：**MetalLB Speaker L2** 宣告 `10.0.0.252`；
- 规模：6 节点、约 145 个 Pod、95–105 个 Service、18 个 NetworkPolicy、42 个 hostNetwork Pod；
- 痛点：没有流级可观测性；IPIP 把 MTU 压到 1480；kube-proxy 规则 800+ 条；MetalLB Speaker 重启 23–76 次。

目标不是“为了性能而换 CNI”，而是：

1. 用 Hubble 拿到 L3/L4 流、DNS、TCP 重试、策略 verdict；
2. 用 Cilium 取代 kube-proxy，减少 iptables 规则和 Service 路径开销；
3. 把 MetalLB Speaker 的 L2 宣告也收编到 Cilium，减少一个常驻组件；
4. 全程可控、可回滚，业务中断控制在分钟级。

最终在 2026-11-09 完成全量替换：

```text
Cilium 1.20.4
├─ CNI: 全量（非 chaining）
├─ KubeProxyReplacement: True
├─ Host Routing: BPF
├─ Masquerading: BPF
├─ Routing: Native（devices=eth0）
├─ IPAM: Kubernetes IPAM（每节点 /24）
├─ Hubble: 开启
└─ L2 Announcements: 开启（只接管 Traefik VIP）
```

## 主要概念与原理

### 1. eBPF 四件套

| 概念 | 作用 |
|---|---|
| Program | 挂到内核钩子（XDP、TC、kprobe、tracepoint、cgroup）上执行的程序 |
| Map | 内核与用户态共享的键值存储；Cilium 的 LB/ipcache/identity/conntrack 都是 Map |
| Hook | 程序被触发的时机/位置 |
| Helper | 内核提供给 BPF 程序的函数 |

Cilium 不是“在 iptables 外面包一层”，而是把 Service LB、NAT、策略、转发直接编译进 eBPF，
挂到 veth/eth0 的 TC ingress/egress 和 socket 层。

### 2. Cilium 的关键表

- **LB map**：Service VIP/port → 后端 Pod；
- **ipcache**：IP → identity / tunnel endpoint / flags；
- **identity**：标签集合的数值化身份，策略按 identity 匹配；
- **nodeid**：节点 ID 与节点 IP；
- **conntrack**：连接跟踪，决定回包和 NAT。

### 3. kube-proxy replacement 到底替换了什么

开启 `kubeProxyReplacement=true` 后，Cilium 接管：

- ClusterIP；
- NodePort（30000–32767）；
- LoadBalancer；
- externalIPs；
- HostPort；
- Socket LB（Pod 内直接连 Service，在 socket 层完成后端选择）。

本集群还开启了 **eBPF host routing** 和 **BPF masquerade**，所以 Pod 出节点不再经过
iptables MASQUERADE 和 host 路由栈。

### 4. Native routing vs 隧道

- **Native routing**：Pod 网段 `10.244.0.0/16` 由 underlay 路由直达，无封装、MTU 1500；
- **VXLAN/IPIP**：有封装开销，MTU 降低（IPIP 通常 1480），跨子网更简单。

本集群 underlay 是 `10.0.0.0/24` 二层可达，所以选 native routing，`devices=eth0`。

### 5. L2 Announcements 与 MetalLB 的分工

- **MetalLB Controller**：继续做 LB IPAM（分配 `10.0.0.252`）；
- **Cilium L2 Announcements**：负责 ARP/NDP 宣告，替代 MetalLB Speaker；
- 通过 `CiliumL2AnnouncementPolicy` 的 nodeSelector 固定宣告节点，避免 VIP 漂移导致 ARP/MAC 变化。

## 踩坑点

### 坑 1：把 Calico 当成“Calico eBPF”

评估时发现 Calico 实际是 **BIRD + IPIP + iptables**，`FELIX_BPFENABLED` 未开启。
如果按“Calico eBPF vs Cilium eBPF”比较，会高估迁移收益、低估差异。

### 坑 2：IPIP 的 20 字节开销

IPIP 外层 20 字节 + 内层 20 字节，1500 的 underlay 只能承载 1480 的 Pod MTU。
`ping -s 1472` 看似能过，但加上 ICMP 头就超了。切换 native routing 后 MTU 恢复 1500。

### 坑 3：隧道端点选错网卡

Calico 自动探测到了 `eth1 172.16.1.x`，而不是业务 `eth0 10.0.0.x`。
跨网段时流量绕行，排障时 `tunl0` 看起来“有接口但没路由”。迁移前必须确认 underlay 和设备。

### 坑 4：全量切换会让所有非 hostNetwork Pod 重启

Calico → Cilium 不是热替换。CNI 配置切换后，新 Pod 用新 CNI，旧 Pod 仍挂在旧网络，
必须滚动重启工作负载。42 个 hostNetwork Pod 不受 CNI 影响，但要单独验证。

### 坑 5：NetworkPolicy 把 kubelet 探针挡了

启用 KPR + eBPF 后，kubelet 的探针流量走宿主机，可能被 K8s NetworkPolicy 拒绝，
表现为 Pod `Running` 但 `NotReady`。需要给探针端口放行（本集群用 CiliumNetworkPolicy
放行 `kubelet` 到业务端口的健康检查）。

### 坑 6：旧 iptables 规则误导排障

kube-proxy 删除后，节点上仍残留 **825 条 `KUBE-*`** 规则，以及 Calico 的 `cali-*` 链、
`calico-arp` nft 表、ipset。Cilium 不依赖它们，但排障时 `iptables-save` 会让人以为
“kube-proxy 还在工作”。清理脚本见 `assets/leftover-cleanup/`。

### 坑 7：MetalLB Speaker 的 ARP 不能直接“一刀切”

直接删 Speaker 会导致 VIP 短暂无宣告。正确做法：

1. 开启 Cilium `enable-l2-announcements`；
2. 创建 `CiliumL2AnnouncementPolicy`，nodeSelector 固定到当前宣告节点（worker03）；
3. 给 MetalLB Speaker 打 `metallb.io/announcer-disabled=true`，缩容到 0；
4. 验证 VIP 的 ARP/MAC 未变化，再决定是否删除 Speaker DaemonSet。

### 坑 8：Hubble 流量上限

Hubble 默认 ring buffer 4095 条 flow。流量大时会覆盖，排障要配合
`--last`、`--since`、filter，不能指望“回放全部历史”。

### 坑 9：Cilium 不是“开得越多越好”

L7 策略需要 Envoy，每节点多 100–300MiB；DSR、XDP、Big TCP、netkit 对内核/网卡有要求。
本集群内核 5.14/5.15，netkit 和 Big TCP 不可用，L7 也刻意未开。

## 修复关键

1. **先 Phase 0，再全量**：先开 Calico Felix 指标、分析 IPIP/MTU，再决定是否迁移。
2. **用 chaining 做可观测性试点**：Cilium chaining + Hubble 不换 CNI，只验证收益和开销。
3. **全量切换前备份**：Calico DS/ConfigMap/IPPool、Cilium values、所有工作负载 YAML、kube-proxy DS/CM。
4. **分两步替换 Service 数据面**：
   - 第一步：Cilium 全量 CNI，`kubeProxyReplacement=false`，kube-proxy 保留；
   - 第二步：确认 DNS/Service/NodePort/Ingress 正常后，再开 KPR、删 kube-proxy。
5. **最后替换 MetalLB Speaker**：保留 Controller 做 IPAM，Cilium 只接管 L2 宣告。
6. **清理遗留**：kube-proxy RBAC、旧 ServiceMonitor、Calico CRD/DS/CNI、`cali-*` 链、ipset、`calico-arp` nft 表。
7. **验证矩阵**：DNS、ClusterIP、NodePort、LoadBalancer、Ingress、Kafka produce/consume、CNPG `select 1`、Prometheus targets、ArgoCD Synced/Healthy。

最终验证：6/6 Cilium Ready，139–145 Pod Running，0 NotReady，Prometheus 120–126 targets up，
Hubble 正常，Ingress/NodePort/VIP 全部 200。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [cilium-tutorial-basic-to-advanced-20261109.md](notes/cilium-tutorial-basic-to-advanced-20261109.md) | 从 K8s 网络基础到 Cilium 进阶的完整教程，含本集群能力矩阵 |
| [cilium-calico-migration-analysis-20261107.md](notes/cilium-calico-migration-analysis-20261107.md) | 迁移代价、性能、可观测性收益评估（含 15–23 人天估算） |
| [cilium-migration-assessment.md](notes/cilium-migration-assessment.md) | 早期可行性评估 |
| [cilium-ebpf-evaluation.md](notes/cilium-ebpf-evaluation.md) | eBPF 切换评估短报告 |
| [calico-phase0-felix-ipip-deep-dive-20261108.md](notes/calico-phase0-felix-ipip-deep-dive-20261108.md) | IPIP MTU 1480、Felix 指标、eth1 探测问题 |
| [cilium-chaining-migration-20261108.md](notes/cilium-chaining-migration-20261108.md) | Cilium chaining + Hubble 试点 |
| [calico-cilium-window-and-migration-readiness-20261108.md](notes/calico-cilium-window-and-migration-readiness-20261108.md) | 切换窗口与就绪检查 |
| [calico-to-cilium-full-cutover-20261109.md](notes/calico-to-cilium-full-cutover-20261109.md) | 全量切换执行报告（Calico 移除、Cilium 接管） |
| [cilium-kubeproxy-replacement-20261109.md](notes/cilium-kubeproxy-replacement-20261109.md) | 删除 kube-proxy，开启 KPR/Host BPF/BPF masquerade |
| [cilium-leftover-cleanup-20261109.md](notes/cilium-leftover-cleanup-20261109.md) | 清理 KUBE-*/cali-* 规则，修复探针 NetworkPolicy |
| [calico-vs-cilium-function-performance-policy-analysis-20261109.md](notes/calico-vs-cilium-function-performance-policy-analysis-20261109.md) | 功能、性能、NetworkPolicy 差异对比 |
| [metallb-speaker-vs-cilium-l2-analysis-20261109.md](notes/metallb-speaker-vs-cilium-l2-analysis-20261109.md) | MetalLB Speaker 与 Cilium L2 的平替分析 |
| [metallb-speaker-to-cilium-l2-replacement-report-20261109.md](notes/metallb-speaker-to-cilium-l2-replacement-report-20261109.md) | L2 宣告替换执行报告 |
| [metallb_speaker_analysis.md](notes/metallb_speaker_analysis.md) | MetalLB Speaker 早期分析 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [labs/](labs/) | Cilium 分步实验：安装、基础、可观测、L3/L4、L7、进阶、Service、排障 |
| [experiment/](experiment/) | BPF LB/ipcache 实验数据与 `analyze_monitor.py` |
| [scripts/collect_cilium_bpf.py](scripts/collect_cilium_bpf.py) | 指定节点采集 BPF LB/ipcache/status |
| [assets/migration/](assets/migration/) | chaining ConfigMap、prepull DS、host inspect DS、values |
| [assets/calico-phase0/](assets/calico-phase0/) | Calico ConfigMap、IPPool、Felix PodMonitor、Grafana 面板 |
| [assets/full-cutover/](assets/full-cutover/) | 全量切换前 Cilium values、IPPool、APIService 备份 |
| [assets/kubeproxy-replacement/](assets/kubeproxy-replacement/) | KPR 前后 values、kube-proxy DS/CM 备份、探针 CNP/NP |
| [assets/metallb-to-cilium-l2/](assets/metallb-to-cilium-l2/) | L2 policy、Speaker/Controller/Traefik 备份、验证日志 |
| [assets/leftover-cleanup/](assets/leftover-cleanup/) | 调试 Pod、RBD 测试 PVC、旧 Calico PDB |
| [assets/current-cilium-values.yaml](assets/current-cilium-values.yaml) | 当前 Cilium Helm values |
| [assets/current-cilium-config.yaml](assets/current-cilium-config.yaml) | 当前 `cilium-config` ConfigMap |
| [assets/current-cilium-status.txt](assets/current-cilium-status.txt) | 当前 `cilium-dbg status --all-addresses` |

```bash
# 在指定节点采集 BPF 表
python3 docs/02-cilium-ebpf/scripts/collect_cilium_bpf.py worker01

# 查看当前 Cilium 状态
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --all-addresses
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ipcache list
```

> 迁移相关脚本/清单是**当时状态的备份**，不要直接 apply 到别的集群。
> 尤其是 `values-full-*`、`ippool-before.yaml`、`kube-proxy-*-before.yaml` 只用于对照和回滚。

## 当前状态

- 数据面**形态**（这是架构，不是数字）：`KubeProxyReplacement=True`、`Host Routing: BPF`、
  `Masquerading: BPF`、`Routing: Network: Native`、`devices=eth0`；
- kube-proxy DaemonSet 已不存在；MetalLB Speaker 已缩容到 0（Controller 保留做 LB IPAM）；
- Traefik VIP 由 Cilium L2 宣告。

> 版本号、agent 数量、Hubble flow 上限等**实时值**见
> [current-state](../00-cluster-overview/assets/current-state.md)（§3 对象计数 / §4 组件版本 / §7 入口）。
> 本章正文里的 `1.20.4`、`6/6` 是写文时的取值。
