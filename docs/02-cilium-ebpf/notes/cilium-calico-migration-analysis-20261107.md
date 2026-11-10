# eBPF + Cilium 取代 Calico 的代价、可观测性收益与性能分析

> 集群实测评估报告  
> 评估日期：2026-11-07  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 当前 CNI：Calico v3.32.2（BIRD + IPIP Always，非 eBPF 数据面）  
> 当前 Service：kube-proxy iptables 模式  
> 目标版本：Cilium v1.20.4（评估时最新 stable）

---

## 0. 结论摘要

**技术可行，但不建议“为了性能”直接全量替换。**

| 维度 | 判断 | 依据 |
|---|---|---|
| 技术可行性 | ✅ 可行 | 6 节点内核 5.14/5.15、BTF、cgroup v2、bpffs 全部满足 Cilium 1.20 要求；K8s 1.35 在 Cilium 1.20 的 e2e 支持范围内 |
| 性能收益 | ⚠️ 当前规模下很小 | 集群总 Pod 网络流量约 **9.4 MB/s（约 75 Mbps）**；conntrack 使用率 < 3.4%；kube-proxy 仅 1.5–2.4 millicores/节点；网络不是瓶颈 |
| 可观测性收益 | ✅ 显著 | 当前没有流级网络可观测性；Hubble 可提供 L3/L4/L7 流、DNS、TCP 重传/RTT、策略 verdict、服务依赖图 |
| 迁移代价 | ⚠️ 高 | 需要全量 CNI 切换，全部非 hostNetwork Pod 重启；42 个 hostNetwork Pod、18 个 NetworkPolicy、Ceph/Kafka/CNPG/Tekton/MetalLB/kube-vip 均需验证 |
| 资源代价 | 中性偏可控 | 替换 Calico + kube-proxy 后，无 L7 场景内存大致中性；开启 L7/Envoy 后每节点约 +100–300 MiB |
| 停机窗口 | 1–3 小时 | 全量切换 + 基础验证；回滚 RTO 约 1–2 小时 |
| 人力估算 | 15–23 人天 | 含评估、试点、切换、验证、可观测性集成、培训；不熟悉 Cilium 的团队 20–30 人天 |

**推荐路线：**

1. **先做 Phase 0（1–2 人天）**：启用 Calico Felix 指标、补 ServiceMonitor/Grafana；把 Calico IPIP 改成同二层直连路由，先拿回 20 字节 MTU 和封装开销。  
2. **再做 Phase 1（3–5 人天）**：用 **Cilium CNI chaining + Hubble** 做可观测性试点，不换 CNI、不全量停机；只重启选定的命名空间，验证 Hubble 的真实价值和开销。  
3. **最后决定是否 Phase 2（15–23 人天）**：只有在“需要 kube-proxy-free、L7 策略、身份化策略、规模化 Service”等条件成立，且 staging 验证通过时，才做全量 Cilium 替换。  
4. **不建议的第一步**：直接全量替换；同时替换 MetalLB；全局开启 L7 Envoy；全量导出 Hubble flow log。

---

## 1. 集群实测基线

### 1.1 节点与内核

| 节点 | 角色 | vCPU | 内存 | 内核 | 发行版 | BTF | cgroup v2 | bpffs | bpf_jit |
|---|---|---:|---:|---|---|---|---|---|---|
| m01 | control-plane | 4 | 5.8 GiB | 5.14.0-570.58.1.el9_6 | Rocky Linux 9.6 | ✅ 4.9 MiB | ✅ | ✅ | 1 |
| master01 | control-plane | 4 | 6.0 GiB | 5.15.0-202-generic | Ubuntu 22.04.5 | ✅ 5.0 MiB | ✅ | ✅ | 1 |
| master02 | control-plane | 4 | 4.0 GiB | 5.15.0-202-generic | Ubuntu 22.04.5 | ✅ 5.0 MiB | ✅ | ✅ | 1 |
| worker01 | worker | 6 | 10.0 GiB | 5.15.0-202-generic | Ubuntu 22.04.5 | ✅ 5.0 MiB | ✅ | ✅ | 1 |
| worker02 | worker | 6 | 10.0 GiB | 5.15.0-202-generic | Ubuntu 22.04.5 | ✅ 5.0 MiB | ✅ | ✅ | 1 |
| worker03 | worker | 4 | 8.0 GiB | 5.15.0-202-generic | Ubuntu 22.04.5 | ✅ 5.0 MiB | ✅ | ✅ | 1 |

关键内核配置（6 节点一致，均为 `y` 或 `m`）：

```text
CONFIG_BPF_SYSCALL=y   CONFIG_BPF_JIT=y       CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_CGROUP_BPF=y    CONFIG_NET_CLS_BPF=m   CONFIG_NET_ACT_BPF=m
CONFIG_NET_SCH_INGRESS=m  CONFIG_NET_CLS_ACT=y  CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_LSM=y       CONFIG_KPROBE_EVENTS=y CONFIG_UPROBE_EVENTS=y
CONFIG_FTRACE=y        CONFIG_FUNCTION_TRACER=y  CONFIG_XDP_SOCKETS=y
CONFIG_NFT_CT=m        CONFIG_NFT_NAT=m      CONFIG_NF_TABLES=m
```

`perf_event_paranoid`：m01 为 2，其余 Ubuntu 节点为 4。Cilium 网络数据面不依赖该值；若后续上 Tetragon 的某些追踪能力，需要在 staging 验证。

### 1.2 当前 Calico 数据面

| 项目 | 实测值 |
|---|---|
| Calico 版本 | v3.32.2 |
| 安装方式 | `calico.yaml` manifest（非 Tigera Operator） |
| `CALICO_NETWORKING_BACKEND` | `bird` |
| IPIP | `ipipMode: Always` |
| VXLAN | `vxlanMode: Never` |
| IPPool | `10.244.0.0/16`，`blockSize: 26`，`natOutgoing: true` |
| BGP | BIRD，节点间 mesh；无外部 BGP peer（`bgppeers=0`） |
| eBPF 数据面 | **未启用**：无 `FELIX_BPFENABLED`，`tc filter show ... ingress` 无 BPF filter |
| 隧道接口 | `tunl0`，MTU **1480** |
| 隧道端点 | 自动探测到 **eth1 172.16.1.x/16**（不是 eth0 10.0.0.x） |
| Felix 配置 | `bpfConnectTimeLoadBalancing: TCP`、`bpfHostNetworkedNATWithoutCTLB: Enabled`（这些是 Felix 的 BPF 相关配置项，不代表已启用 BPF 数据面） |

**重要结论：当前是 Calico 的 iptables/BIRD + IPIP 数据面，不是 Calico eBPF。** 因此与 Cilium 的对比应拿“iptables + IPIP + kube-proxy”做基线，而不是拿“Calico eBPF”做基线。

补充：calico-node 各节点重启次数为 0/2/3/3/6/8，主要集中在 2026-11-04 前后（与节点内核升级时间吻合），当前无持续崩溃迹象；MetalLB speaker 的重启次数更高（23/66/68/76），更值得关注。

### 1.3 当前 kube-proxy 与 Service 规模

| 项目 | 实测值 |
|---|---|
| kube-proxy 模式 | `iptables`（底层 `iptables-nft`） |
| Service 总数 | 95（94 ClusterIP + 1 LoadBalancer；无 NodePort 类型 Service） |
| EndpointSlice | 95 |
| NAT 规则数/节点 | 507 |
| `KUBE-SVC` 链数/节点 | 341 |
| `iptables-save` 行数/节点 | 923 |
| `nft list ruleset` 行数/节点 | 1628 |
| kube-proxy CPU | 1.5–2.4 millicores/节点 |
| kube-proxy 内存 | 55–101 MiB/节点 |
| kube-proxy 全量 sync 耗时 | p50 **96 ms**，p99 **127 ms**；sync 频率约 0.0017 次/秒（约 10 分钟一次，仅在变更时） |
| 历史 nftables 问题 | m01 上 `nft v1.0.9` 曾在 kube-proxy nftables 模式下产生至少 **21 次 segfault**；已回退 iptables 模式，当前无新增 segfault |

注意：kube-proxy 的 96–127 ms 是“规则全量同步耗时”，不是数据面转发延迟；在当前 Service 数量下，它每约 10 分钟才发生一次，不能直接理解为业务延迟。

另外，当前 kube-proxy ConfigMap 使用 `clusterCIDR`（单数），而 v1alpha1 期望 `clusterCIDRs`（复数数组），日志中存在 detect-local-mode 警告。这是既有配置债，与 Cilium 迁移无直接关系，但建议在迁移前顺手修正或记录。

### 1.4 工作负载与特殊对象

| 项目 | 实测值 |
|---|---|
| Namespace | 25 |
| Pod 总数 | 143 |
| hostNetwork Pod | **42** |
| NetworkPolicy | **18 个**（全部是 Kubernetes 原生 NP；无 Calico CNP/GNP/HostEndpoint） |
| PVC | 23 |
| Ingress | 9 个，均由 Traefik 承载，VIP `10.0.0.252` |
| LoadBalancer Service | 1 个（Traefik：80/443，NodePort 30156/30306） |
| Kafka | Strimzi `my-cluster`，**单 broker**（`my-cluster-single-pool-0`） |
| PostgreSQL | CloudNativePG `pg16-ceph`，2 实例（1 primary + 1 replica） |
| 存储 | Ceph RBD CSI 3.16.2；23 个 PVC；Ceph RGW `10.0.0.31:7480` |
| CI/CD | ArgoCD 3.5.3、Tekton（含 default-deny NP）、GitLab Runner |
| 可观测性 | Prometheus v3.11.2（15d retention）、Grafana、Loki、Tempo、OTel Operator、Alloy |
| MetalLB | v0.13.12，6 个 speaker；部分 speaker 重启次数较高（23/66/68/76 次） |
| kube-vip | v1.2.4，仅负责 API VIP `10.0.0.168`，ARP 模式，不做 Service LB |

42 个 hostNetwork Pod 的构成：

| 类别 | 数量 | 说明 |
|---|---:|---|
| calico-node | 6 | 迁移后移除 |
| kube-proxy | 6 | 若 kube-proxy-free，迁移后移除 |
| MetalLB speaker | 6 | 建议第一阶段保留 |
| node-exporter | 6 | 监控采集，需验证 |
| Ceph CSI nodeplugin | 3 | hostNetwork，需验证 RBD |
| kube-vip | 3 | API VIP，需验证 |
| 静态控制面（etcd/apiserver/controller-manager/scheduler） | 12 | hostNetwork，不受 CNI 影响，但需确认 Cilium 不干扰 |
| **合计** | **42** | |

### 1.5 流量、资源与连接跟踪

| 指标 | 实测值 | 解读 |
|---|---:|---|
| Pod 网络总 TX | **9.4 MB/s（约 75 Mbps）** | 远低于虚拟网卡容量；网络不是瓶颈 |
| 单节点 eth0/eth1 RX | 约 0.03–0.32 MB/s | 同上 |
| conntrack 使用 | 612–4424 / 131072–196608 | 使用率 **0.5%–3.4%**，无连接跟踪压力 |
| 节点 CPU 使用率 | 9%–15% | 有充足 CPU 余量 |
| 节点内存使用率 | 27%–67% | m01 66%、master02 67%，需关注；worker03 27% |
| Calico-node CPU | 80–108 millicores/节点 | 比 kube-proxy 重 |
| Calico-node 内存 | 284–450 MiB/节点 | 6 节点合计约 2.1 GiB |
| TCP 重传 | 接近 0 | 网络质量良好 |
| 网卡 MTU | eth0/eth1 均为 1500；tunl0 为 1480 | IPIP 损失 20 字节，约 1.35% 有效载荷 |

### 1.6 网络拓扑关键事实

- 6 个节点都在 `10.0.0.0/24`，`ip neigh` 显示彼此 **REACHABLE**，说明同一二层广播域。
- 6 个节点也都在 `172.16.1.0/16`；Calico 当前用 eth1 作为 IPIP 隧道端点。
- 因此 **Calico 的 IPIP 在当前环境下并非必需**：同二层可以直接路由 Pod CIDR，或使用 BGP 直连。
- 这带来一个“低成本性能优化”：把 Calico `ipipMode` 从 `Always` 改为 `Never`，先拿回 MTU 和封装开销；不需要换 CNI。

---

## 2. Cilium 技术可行性

### 2.1 版本与兼容性

| 项目 | 要求/事实 | 本集群 | 结论 |
|---|---|---|---|
| Cilium 版本 | 1.20.4（stable） | 计划使用 | ✅ |
| Kubernetes | Cilium 1.20 e2e 覆盖 1.33–1.36 | 1.35.9 | ✅ |
| 内核 | >= 5.10（Cilium 1.20 系统要求） | 5.14 / 5.15 | ✅ |
| 架构 | amd64 / arm64 | amd64 | ✅ |
| BTF | `/sys/kernel/btf/vmlinux` | 6 节点全部存在 | ✅ |
| cgroup v2 | 统一 cgroup | 6 节点全部 cgroup2 | ✅ |
| bpffs | `/sys/fs/bpf` 已挂载 | 6 节点全部已挂载 | ✅ |
| clang/LLVM | >= 18.1（仅宿主机原生运行时需要） | 容器镜像自带 | ✅ 无需宿主机安装 |
| CNI 运行时 | containerd 2.3.2 | 支持 CNI 1.0.0 | ✅ |
| SELinux/AppArmor | Cilium chart 使用 `spc_t`/Unconfined | SELinux Disabled | ✅ |
| 防火墙 | 需放行 4240/TCP、8472/UDP（如 VXLAN）、51871/UDP（如 WireGuard） | firewalld inactive | ✅（后续启用防火墙需补规则） |

### 2.2 功能可用性矩阵

| 能力 | 本集群可用性 | 说明 |
|---|---|---|
| eBPF kube-proxy replacement | ✅ | 内核 5.15 支持 socket-LB；需 `k8sServiceHost/Port` |
| BPF masquerade | ✅ | 内核 4.19+ |
| eBPF host routing | ✅ | 内核 5.10+；需 kube-proxy replacement + BPF masquerade |
| Native routing / 直连路由 | ✅ | 6 节点同二层；需 `routingMode=native` + `autoDirectNodeRoutes` |
| VXLAN/Geneve | ✅ | 但会增加封装，MTU 1450/1442，不建议首选 |
| WireGuard 加密 | ✅ | 内核 5.6+；会增加 CPU/吞吐开销，非必需 |
| IPsec | ✅ | 内核 4.19+；需内核配置与密钥管理 |
| DSR | ✅（需验证） | 依赖内核/网卡/负载均衡模式，建议 staging 验证 |
| XDP 加速 | ⚠️ 取决于网卡 | 虚拟网卡需实测；当前 NodePort/LB 流量很低，收益有限 |
| L7 策略 / Hubble L7 | ✅ | 需要 Envoy（`l7Proxy`）；有额外 CPU/内存/延迟 |
| Hubble | ✅ | flow、DNS、TCP、drop、HTTP/gRPC 指标与 UI |
| Tetragon | ✅ | 内核 4.19+、BTF；可选，不属于网络 CNI 必需 |
| Gateway API | ✅ | Cilium 1.20 支持 Gateway API v1.6.1；非本次必需 |
| **netkit** | ❌ | 需要内核 **6.8+**；当前 5.14/5.15 不可用 |
| **Big TCP（IPv6）** | ❌ | 需要内核 **5.19+** |
| **Big TCP（IPv4）** | ❌ | 需要内核 **6.3+** |

### 2.3 结论

- **基础设施门槛全部通过**，Cilium 1.20.4 可以在这 6 个节点上运行。
- 但当前内核是 **5.14/5.15**，拿不到 Cilium 最强性能组合（netkit + Big TCP + eBPF host routing）。本集群能用的是 **eBPF host routing + kube-proxy replacement + native routing + BPF masquerade**，这已经能带来收益，但不要期待 6.8 内核基准里的数字。
- 如果未来明确要 netkit/Big TCP，需要单独规划内核升级（Ubuntu 24.04/6.8 或更新），这是另一个项目，不应混在本次 CNI 迁移里。

---

## 3. 迁移代价

### 3.1 组件替换范围

**移除/停用：**

- `calico-node` DaemonSet（6 Pod）
- `calico-kube-controllers`
- Calico CNI conflist（`/etc/cni/net.d/10-calico.conflist`）
- Calico IPPool、FelixConfiguration、BGPConfiguration 等 CR
- Calico CRD（22 个，最终移除；删除 CRD 会级联删除 CR，必须先备份，建议等 Cilium 稳定后再删）
- `tunl0`、`cali*` veth、Calico 遗留路由与 iptables/nftables 链
- 若启用 kube-proxy-free：`kube-proxy` DaemonSet（6 Pod）与 kube-proxy ConfigMap

**新增：**

- `cilium-agent` DaemonSet（6 Pod）
- `cilium-operator`（建议 2 副本）
- `cilium-envoy`（若启用 L7；否则可不启用）
- Hubble Relay（1）、Hubble UI（1，可选）
- Cilium CRD、ConfigMap、RBAC、ServiceMonitor
- 可观测性：Prometheus 抓取、Grafana dashboard、Loki flow log 管道

**保留：**

- kube-vip（API VIP）
- MetalLB（第一阶段保留，避免扩大风险）
- CoreDNS、containerd、Ceph CSI、Kafka、CNPG、Tekton、ArgoCD、Traefik

### 3.2 网络中断与 IPAM

这是迁移成本的核心。

| 事项 | 说明 |
|---|---|
| 是否可以滚动逐节点切换 | **不可以**（Calico 与 Cilium 数据面不能在同一节点/集群混跑；Cilium chaining 除外，但功能受限） |
| 现有 Pod 是否保留 IP | **不会**。Cilium 接管后，非 hostNetwork Pod 需要重建并重新分配 IP |
| 中断范围 | 全部非 hostNetwork Pod 网络；hostNetwork Pod 不依赖 CNI，但其中依赖 Service 的仍需验证 |
| 停机窗口 | 1–3 小时（切换 + 基础验证）；状态型业务验证可能更长 |
| 回滚 | 需要反向切换，RTO 约 1–2 小时；不是秒级回滚 |

**IPAM 方案对比：**

| 方案 | 做法 | 优点 | 风险 |
|---|---|---|---|
| Kubernetes IPAM | `ipam.mode=kubernetes`，复用 `node.spec.podCIDR`（当前每节点 /24） | 配置改动最小；不需要改 kube-controller-manager | 必须在 Calico Pod 全部停止后切换，否则可能与 Calico 旧 IP 冲突 |
| Cluster Pool（同 CIDR） | `ipam.mode=cluster-pool`，`10.244.0.0/16`，mask /26 | 与当前 Calico block 大小一致 | 同样需要全量停止；block 分配逻辑与 Calico 不同 |
| Cluster Pool（新 CIDR） | 例如 `10.245.0.0/16` | 与旧 Calico IP 完全隔离，切换/回滚更清晰 | 需要更新任何硬编码 `10.244.0.0/16` 的配置；当前集群仅有 3 处引用，主要是控制面/Calico 自身 |

**建议：**

- 若追求“改动最小”：用 `ipam.mode=kubernetes`，但必须接受全量 Pod 重建，且切换前确认没有 Calico 旧 IP 仍被使用。
- 若追求“切换干净、可回滚”：用新 CIDR `10.245.0.0/16`，同时更新 kube-controller-manager 的 `--cluster-cidr`（或接受其继续分配旧 CIDR 但 Cilium 不使用）。这会增加变更面，但对生产更可控。
- 无论哪种，**不要**在 Calico Pod 还在运行时让 Cilium 从同一 CIDR 分配 IP。

### 3.3 NetworkPolicy 迁移

当前只有 **18 个 Kubernetes 原生 NetworkPolicy**，没有 Calico 特有的 CNP/GNP/HostEndpoint，这是有利条件。

| 风险点 | 说明 | 缓解 |
|---|---|---|
| 默认拒绝语义 | Tekton 命名空间有多个 default-deny；Cilium 对 K8s NP 的语义一致，但 named port、egress 到 Service、hostNetwork 场景需验证 | 在 staging 重放 18 个 NP，重点测 Tekton/Kafka |
| egress 到 Service | K8s NP 的 egress `toServices` 在 Cilium 中支持，但行为需验证 | 用 `hubble observe --verdict DROPPED` 定位 |
| hostNetwork | Cilium 不管理 hostNetwork Pod 的策略；K8s NP 对 hostNetwork 的语义本来就有限 | 对 42 个 hostNetwork Pod 单独做连通性矩阵 |
| Calico staged policy CRD | 当前存在 staged* CRD，但未发现实际策略；迁移前确认无残留 | `kubectl get stagednetworkpolicies,... -A` |
| L7 策略 | 当前没有 L7 策略；Cilium 的 L7 能力是增量，不是迁移必需 | 第一阶段不启用 L7，避免 Envoy 开销 |

### 3.4 hostNetwork 与特殊工作负载

| 工作负载 | 迁移关注点 | 验证方式 |
|---|---|---|
| Ceph CSI RBD | nodeplugin 使用 hostNetwork，连接 Ceph MON/RGW；Pod 重启后 RBD 重新挂载 | 创建测试 PVC，写入/读取；检查 `ceph-csi-rbd-nodeplugin` 日志 |
| Kafka（单 broker） | 重启会中断生产/消费；单 broker 无副本，数据风险高 | 迁移前备份 PVC；迁移后 produce/consume；检查 Strimzi CR 状态 |
| CNPG PostgreSQL | 2 实例，primary/replica；Pod 重建可能触发 failover | `kubectl cnpg status`；psql 读写；检查 PDB |
| Tekton | default-deny NP + webhook；CNI 切换可能使 webhook/pipeline 失败 | 跑一条最小 PipelineRun；检查 webhook 连通性 |
| ArgoCD | 不管理 Calico；但自动同步可能在维护窗口内 reconcile 应用 | 暂停 auto-sync 或设置维护窗口；迁移后手动 sync |
| Traefik Ingress | 单副本；迁移期间 Ingress 会短暂中断 | 迁移后 `curl -H "Host: ..." http://10.0.0.252`；检查 9 个 Ingress |
| MetalLB | 6 speaker；部分重启次数高；L2 模式依赖 Service 数据面 | 保留 MetalLB；验证 `10.0.0.252`；若异常，考虑 Cilium LB IPAM（beta） |
| kube-vip | API VIP `10.0.0.168`；Cilium agent 需要直连 API | `kubectl get --raw /healthz` 通过 VIP；检查 kube-vip 日志 |
| 可观测性栈 | Prometheus/Grafana/Loki/Tempo/OTel/Alloy 可能依赖 Service/DNS | 迁移后检查 target、dashboard、日志、trace |
| node-exporter | hostNetwork；Prometheus 通过节点 IP 抓取 | 检查 `up` 指标 |

### 3.5 可观测性栈改造成本

| 项目 | 工作 | 人天 |
|---|---|---:|
| Prometheus 抓取 | 启用 Cilium/Hubble ServiceMonitor；校验 target/labels | 0.5–1 |
| Grafana | 导入 Cilium/Hubble dashboard；按命名空间/服务定制 | 1–2 |
| Loki | Hubble flow log 导出（file → Alloy → Loki）；过滤、脱敏、retention | 1–2 |
| 告警 | 丢包、DNS NXDOMAIN、HTTP 5xx、TCP 重传、策略拒绝 | 1–2 |
| 文档/runbook | Hubble 查询手册、排障流程、值班培训 | 1–2 |
| **合计** | | **4.5–9** |

注意：如果只做 Phase 1（chaining + Hubble），可观测性集成工作相同，但不需要 CNI 切换的 10+ 人天。

### 3.6 运维与技能成本

| 项目 | 影响 |
|---|---|
| 排障方式变化 | 从 `iptables -L`/`nft list ruleset` 转向 `cilium-dbg`、`hubble observe`、`bpftool`、`tc`；团队需要新 runbook |
| eBPF 知识 | 需要理解 BPF map、conntrack、identity、policy verdict；不需要写 eBPF 程序，但需要会读状态 |
| 升级节奏 | Cilium 每年约 3 个 minor；只能逐 minor 升级；升级前需 preflight；比 Calico manifest 升级更需要流程 |
| 内核依赖 | 新特性依赖新内核；5.15 可用但会逐渐落后；需要跟踪 Cilium 最低内核要求 |
| 安全边界 | Cilium agent 需要 `CAP_SYS_ADMIN`、hostNetwork、bpffs；与 Calico 类似，但攻击面/授权需评估 |
| 支持 | Cilium OSS 免费；Isovalent（Cisco）企业支持需单独询价；Calico OSS 也免费，迁移不节省 license |

### 3.7 资源成本估算

当前每节点：

- Calico-node：80–108 millicores，284–450 MiB
- kube-proxy：1.5–2.4 millicores，55–101 MiB
- 合计：约 **82–110 millicores，340–550 MiB/节点**

Cilium 预期（143 Pod、6 节点、低流量）：

| 组件 | CPU | 内存 | 说明 |
|---|---|---|---|
| cilium-agent（每节点） | 50–150m | 100–250 MiB | 低 Pod 数/低流量；eBPF map 另计内核内存 |
| cilium-operator（2 副本） | 10–50m ×2 | 50–100 MiB ×2 | 可只跑 1 副本，但生产建议 2 |
| Hubble Relay（1） | 10–50m | 50–100 MiB | 可选 |
| Hubble UI（1） | 5–20m | 30–80 MiB | 可选 |
| cilium-envoy（每节点，仅 L7） | 50–100m | 100–200 MiB | 仅启用 L7 时 |
| **无 L7 合计/节点** | **约 60–200m** | **约 150–350 MiB** | 与 Calico+kube-proxy 大致中性 |
| **含 L7 合计/节点** | **约 110–300m** | **约 250–550 MiB** | 比现状多 0–200 MiB/节点 |

> 以上为规划估算，需 Phase 1 实测。Cilium 官方 scalability 报告在 50,000 Pod 场景下给出 agent 平均约 438 MiB、峰值约 573 MiB；本集群仅 143 Pod，实际应显著低于该值。eBPF map 还占用内核内存，不体现在容器 working set 中。

**对 master02 的影响：** 该节点 4 GiB 内存、使用率约 67%，空闲约 1.2–1.3 GiB。Cilium 无 L7 约 150–350 MiB，可放下，但余量不算大；若再开 L7 Envoy + Hubble UI，建议先扩容或把非关键组件迁走。m01 约 66% 使用率、空闲约 2 GiB，相对宽松。

### 3.8 时间与人力估算

| 阶段 | 内容 | 人天 | 停机 |
|---|---|---:|---|
| 评估/设计 | 版本选型、网络设计、IPAM/策略方案 | 2–3 | 0 |
| 试点（chaining + Hubble） | 安装、重启选定命名空间、验证 | 3–5 | 0（滚动重启） |
| 全量切换准备 | 备份、staging、runbook、回滚演练 | 3–5 | 0 |
| 切换窗口 | 删除 Calico、安装 Cilium、重建 Pod、基础验证 | 1–2 | 1–3 h |
| 稳定/验证 | 业务验证、性能/可观测性对比、修复 | 3–5 | 0–部分 |
| 可观测性集成 | Prometheus/Grafana/Loki/告警 | 4.5–9 | 0 |
| 培训/文档 | 团队培训、runbook | 2 | 0 |
| **合计** | | **15–23**（熟悉 Cilium） | **1–3 h** |
| **不熟悉 Cilium** | 含学习曲线 | **20–30** | 同上 |

### 3.9 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| CNI 切换期间业务中断 | 高 | 高 | 维护窗口；staging 演练；保留回滚镜像/配置 |
| IPAM 冲突/旧 IP 残留 | 中 | 高 | 全量停止旧 Pod；或使用新 CIDR；切换前核对 IPPool/BlockAffinity |
| NetworkPolicy 行为差异 | 中 | 中 | 重放 18 个 NP；重点 Tekton/Kafka；Hubble 看 verdict |
| hostNetwork/Service/VIP 异常 | 中 | 高 | 42 个 hostNetwork 清单逐项验证；MetalLB/kube-vip 单独测试 |
| 状态型数据风险 | 中 | 高 | Kafka/CNPG/Ceph 备份；PDB；迁移顺序；先在 staging 验证 |
| Cilium 资源压力（master02） | 中 | 中 | 限制 Hubble/L7；设置 requests/limits；监控 OOM |
| 内核 5.15 功能不足 | 高 | 低 | 不承诺 netkit/Big TCP；需要时单独升级内核 |
| MetalLB 与 kube-proxy replacement 兼容性 | 中 | 中 | 第一阶段保留 MetalLB 并实测；失败则保留 kube-proxy 或迁移 Cilium LB IPAM |
| 团队不熟悉 eBPF | 高 | 中 | 培训、runbook、先在 chaining 模式练手 |
| 回滚不彻底 | 中 | 高 | 备份 Calico/IPPool/kube-proxy/CNI 配置；etcd 快照；回滚演练 |
| Cilium 升级/CRD 变更 | 中 | 中 | 固定 1.20.x；逐 minor 升级；preflight |
| 全量 flow log 存储膨胀 | 中 | 中 | 只导出 deny/drop + 关键命名空间；采样；retention |

---

## 4. 可观测性收益

### 4.1 当前可观测性缺口

当前集群有 Prometheus/Grafana/Loki/Tempo/OTel/Alloy，但**网络层可观测性主要停留在节点/容器指标**：

- 没有流级 L3/L4 网络日志：无法快速回答“哪个 Pod 在什么时间被哪条策略拒绝”。
- Calico Felix 指标**未抓取**：`calico-node` 没有 ServiceMonitor，Prometheus 里没有 Felix 的 dataplane/policy 指标。
- 没有每 Pod 的 DNS 查询/响应指标（只有 CoreDNS 聚合指标）。
- 没有每 Pod/服务的 HTTP/gRPC 指标（状态码、方法、路径、延迟）。
- 没有 TCP RTT/重传/连接状态的细粒度指标。
- 没有服务依赖图；排障靠 `tcpdump`、`iptables`、应用日志。
- 没有网络策略 verdict（allow/deny + 命中策略）可视化。
- 没有 flow log 用于安全审计/取证。

### 4.2 Hubble 能带来什么

Hubble 是 Cilium 的分布式网络可观测层，数据来自 eBPF，不依赖应用埋点：

| 能力 | 具体内容 |
|---|---|
| L3/L4 flow | 源/目的 identity、namespace、pod、workload、IP、端口、协议、方向、verdict、字节/包数、TCP flags、节点 |
| L7 可见性 | HTTP method/path/status/latency、gRPC、DNS qname/qtype/rcode；需要 Envoy/L7 proxy + visibility 注解或 L7 策略 |
| DNS | 每 Pod/服务的查询量、响应码、延迟；DNS 可见性同样依赖 L7 proxy/DNS 代理与相应策略 |
| TCP | RTT、重传、连接状态；定位网络抖动/丢包 |
| Drop | 丢包原因（策略拒绝、无效包、CT 无效等）、方向、Pod |
| Policy verdict | 允许/拒绝、命中策略；直接回答“为什么不通” |
| Service map | Hubble UI 自动发现 L3/L4 乃至 L7 服务依赖图 |
| CLI | `hubble observe --namespace X --verdict DROPPED`、`--protocol http`、`--last 100`、follow |
| Metrics | `hubble_flows_processed_total`、`hubble_dns_*`、`hubble_tcp_flags_total`、`hubble_drop_total`、`hubble_http_*` 等接入 Prometheus |
| Flow export | Hubble exporter 写文件；可用现有 Alloy 采集到 Loki；支持过滤/字段裁剪 |
| 告警 | 丢包突增、DNS NXDOMAIN、HTTP 5xx、TCP 重传、策略拒绝接入 Alertmanager |

**注意：** Hubble 不是分布式追踪（tracing）。它提供网络流/协议指标，不替代 Tempo 的应用 trace；L7（HTTP/gRPC）和 DNS 细粒度可见性需要 `l7Proxy=true` + visibility 注解或 L7/DNS 策略，且只对匹配的流量生效。若 `l7Proxy=false`，Hubble 仍提供 L3/L4 flow、TCP、drop 等基础可见性。另外，Hubble 主要覆盖 Cilium 管理的 Pod 网络；本集群 42 个 hostNetwork Pod（Ceph CSI、MetalLB、kube-vip、node-exporter 等）的流量可见性有限，不能把 Hubble 当作主机网络全量观测。

### 4.3 三种可观测性方案对比

| 能力 | 现状（Calico iptables + Prometheus） | Calico OSS Whisker 3.32 | Cilium Hubble |
|---|---|---|---|
| L3/L4 flow log | ❌ | ✅（聚合 flow，tech preview） | ✅（逐流，可过滤） |
| L7 HTTP/gRPC | ❌ | ❌（以 L3/L4 为主） | ✅（需 Envoy） |
| DNS 细粒度 | ❌（仅 CoreDNS 聚合） | 有限 | ✅（需 L7 proxy/DNS 代理） |
| TCP RTT/重传 | ❌（仅节点级） | 有限 | ✅ |
| 策略 verdict | ❌ | ✅（allow/deny） | ✅（allow/deny + 策略） |
| 服务依赖图 | ❌ | Whisker UI | Hubble UI |
| Prometheus 指标 | Calico 未抓取 | Goldmane API 为主 | 丰富，原生 ServiceMonitor |
| Flow 导出 | ❌ | Goldmane gRPC | file → Alloy → Loki |
| 成熟度 | 稳定 | **tech preview** | GA |
| 需要换 CNI | 否 | 否，但需 operator 迁移 | 是（或 chaining） |
| 额外组件 | 无 | Goldmane + Whisker | Cilium agent + Relay/UI（+ Envoy 若 L7） |

**关键结论：**

- 如果只要“L3/L4 流 + 策略 verdict”，**Calico OSS Whisker 是更便宜的增量**；但它是 tech preview，且当前 manifest 安装不支持，必须先转 Tigera Operator。
- 如果要“L7 + DNS + TCP + 服务图 + 丰富 Prometheus 指标”，**Hubble 明显更强**；但需要 Cilium CNI 或 chaining。
- 如果现在做全量 Cilium，Hubble 是“顺带获得”的最大收益；如果只想要 Hubble，**chaining 模式是成本最低的验证路径**。
- 当前 18 个策略全是 L3/L4 原生 NetworkPolicy，没有 L7/FQDN 需求；L7 策略是未来选项，不应作为本次迁移的主要理由。

### 4.4 与现有可观测性栈的集成

```text
Cilium agent (eBPF)
  ├─ Cilium metrics :9962  ──┐
  ├─ Hubble metrics :9965  ──┼─> Prometheus (ServiceMonitor) ─> Grafana
  ├─ Hubble Relay :4245  ────┼─> Hubble UI / hubble CLI
  └─ Hubble exporter ─> file ─> Alloy ─> Loki ─> Grafana
```

建议：

- **Prometheus**：启用 `prometheus.serviceMonitor.enabled=true`、`hubble.metrics.serviceMonitor.enabled=true`；复用现有 Prometheus Operator。
- **Grafana**：使用 Cilium 官方 dashboard；若 Grafana sidecar 已启用，设置 `hubble.metrics.dashboards.enabled=true` 与 `label=grafana_dashboard`；否则手动导入 JSON。
- **Loki**：不要全量导出 flow；先导出 `deny/drop`、关键命名空间（如 `kube-system`、`traefik`、`monitoring`、`kafka`）和 L7 错误；用 Alloy 解析/脱敏。
- **告警**：优先做“策略拒绝突增”“DNS NXDOMAIN 比例”“TCP 重传率”“HTTP 5xx 比例”，而不是一开始就做全量流量告警。

### 4.5 可观测性成本与容量

| 成本项 | 估算 | 控制手段 |
|---|---|---|
| Hubble agent 开销 | 每节点 +50–80 MiB；CPU 随 flow 速率增长 | 限制 `hubble.eventBufferCapacity`；只开必要 metrics |
| Relay/UI | 1–2 个 Pod，约 100–200 MiB | UI 可选；用 port-forward 或内部 Ingress |
| Flow log 存储 | 低流量下约 1–10 GB/天（粗估） | 只导出 deny/drop；采样；retention 7–15 天 |
| Metrics 基数 | `flow` 指标可能高基数 | 先用 `dns,drop,tcp`；`flow` 加聚合/过滤；避免 pod IP 级 label 全量 |
| L7 Envoy | 每节点 +100–200 MiB，延迟 +0.1–1 ms/请求 | 只对选定命名空间开 L7；不要全局 |
| 工程成本 | dashboard/告警/runbook 4.5–9 人天 | 复用官方 dashboard；先做 3–5 个关键告警 |

### 4.6 可选：Tetragon

Tetragon 是 Cilium 生态的 eBPF 运行时安全可观测性组件，可提供进程执行、文件访问、网络连接、权限提升等事件。它不是网络 CNI 必需，但如果目标是“eBPF 统一可观测性/安全”，可以作为 Phase 3：

- 优点：内核态、低开销、BTF/CO-RE；与 Cilium 共享 eBPF 基础设施。
- 成本：额外 agent、策略调优、事件存储；`perf_event_paranoid=4` 的节点需验证部分能力。
- 建议：先不做；等 Hubble 稳定后再评估。

---

## 5. 性能分析

### 5.1 当前瓶颈判断

用实测数据回答“要不要为了性能换 CNI”：

| 检查项 | 实测 | 判断 |
|---|---|---|
| 网络吞吐 | 总 Pod TX 约 75 Mbps | 远低于网卡容量；不是瓶颈 |
| conntrack | 使用率 0.5%–3.4% | 不是瓶颈 |
| kube-proxy CPU | 1.5–2.4 millicores/节点 | 不是瓶颈 |
| Service 数量 | 95 | iptables 舒适区；规则遍历开销很小 |
| iptables 规则 | 507 NAT 规则/节点 | 很小；p50 全量 sync 96 ms 但频率低 |
| 节点 CPU | 9%–15% | 有大量余量 |
| TCP 重传 | 接近 0 | 网络质量好 |
| IPIP | MTU 1480，封装/解封装 | 唯一明确的性能损失；可通过直连路由消除 |

**结论：当前集群没有“必须换 CNI 才能解决”的性能问题。** 换 Cilium 的性能收益主要是“未来潜力”和“消除 IPIP/iptables”，不是当前救火。

### 5.2 Cilium 的性能收益来源

| 机制 | 收益 | 本集群适用性 |
|---|---|---|
| eBPF host routing | 绕过宿主机 netfilter/iptables，减少上下文切换和栈遍历；降低每包 CPU、降低延迟 | ✅ 5.15 支持；需 kube-proxy replacement + BPF masquerade |
| Socket-level LB | `connect()` 时选择后端，避免 DNAT/conntrack；降低首包延迟；保留源 IP | ✅ 5.15 支持 |
| kube-proxy replacement | BPF map O(1) 查找；Service 变更不再重写 iptables；高 churn 更稳 | ✅ 当前 95 Service，收益小 |
| Native routing | 去掉 IPIP 20 字节封装；MTU 1500；去掉 encap/decap CPU | ✅ 6 节点同二层；需 `routingMode=native` |
| DSR | 回程直连，减少 SNAT/回程经过 LB 节点 | ✅ 需验证；当前只有 1 个 LB Service |
| XDP 加速 | NodePort/LB 在驱动层处理 | ⚠️ 取决于虚拟网卡；当前流量低 |
| 更好的规模化 | 数千 Service/高 PPS 下优势明显 | ❌ 当前规模用不到 |
| netkit | 接近宿主网络命名空间的零开销 | ❌ 需要 6.8+ |
| Big TCP | 更大 GSO/GRO，降低栈遍历 | ❌ 需要 5.19/6.3+ |

### 5.3 本集群可预期的量化影响

| 指标 | 预期变化 | 说明 |
|---|---|---|
| 跨节点 Pod 吞吐 | **+1.35% 左右**（仅 MTU 1480→1500） | 加上去掉 encap/decap 的 CPU 节省；实际取决于流量和网卡 |
| Pod-to-Service 延迟 | 可能降低 **0.02–0.1 ms**（新连接/首包） | 当前 p50 在 0.15–0.2 ms 量级；收益对多数业务不可见 |
| 每包 CPU | 高 PPS 下降低；低 PPS 下差异很小 | 当前网络 CPU 占比很低 |
| Service 变更同步 | 从 iptables 全量 sync 变为 BPF map 更新 | 当前 churn 低，收益小 |
| 节点内存 | 无 L7 大致中性；L7 +100–300 MiB | 替换 Calico+kube-proxy 后抵消一部分 |
| 节点 CPU | 大致中性；高负载下更优 | Calico 80–108m + kube-proxy 1.5–2.4m 被替换 |
| 网络策略性能 | eBPF 策略查找通常优于 iptables/ipset；当前 18 NP，规模小 | 收益有限 |
| 可观测性开销 | Hubble 增加 50–80 MiB/节点；flow log 另计 | 需要预算 |

**一句话：在当前 75 Mbps、95 Service、143 Pod 的规模下，性能差异大概率落在测量噪声内；真正的收益是“未来扩展性”和“去掉 IPIP/iptables 的技术债”。**

### 5.4 性能回退风险

| 风险 | 后果 | 避免方式 |
|---|---|---|
| 误用 VXLAN/Geneve | MTU 1450/1442，比当前 IPIP 1480 更差 | 同二层优先 `routingMode=native`；不要默认 tunnel |
| 全局启用 L7 Envoy | 每请求增加 0.1–1 ms，内存 +100–200 MiB/节点 | 只对选定命名空间开 L7；默认 `l7Proxy=false` |
| Hubble 全量 flow log | CPU/磁盘/ Loki 压力 | 过滤 deny/drop；采样；限制 buffer |
| BPF map 过大 | 内核内存占用高，可能触发 memlock | 设置 `bpf.mapDynamicSizeRatio`；监控 map 使用 |
| conntrack 表过大/过小 | 内存或丢连接 | 按 Pod/Service 规模设置；监控 |
| 5.15 内核缺少新特性 | 无法使用 netkit/Big TCP，性能上限低 | 不承诺这些特性；需要时规划内核升级 |
| MetalLB 兼容性问题 | LB Service 不通，回滚压力 | 第一阶段保留 MetalLB 并实测；保留 kube-proxy 备选 |

### 5.5 公开基准数据的正确用法

公开基准可以作为“方向参考”，但不能直接套到本集群：

- Cilium 2021 年 CNI benchmark：在 100G 网卡、单 TCP 流场景，eBPF 数据面可接近或超过 40 Gbps，明显优于 iptables；eBPF host routing 减少上下文切换。  
- 2026 年第三方对比：Pod-to-Service 约 28.5 Gbps（Cilium）vs 22.1 Gbps（Calico），p50 约 0.15 ms vs 0.18 ms；但这类数据通常来自合成负载、特定内核/网卡，且 Calico 版本/数据面不同。  
- 2026 年学术研究也指出：在**无负载/轻负载**场景，iptables 有时反而更快；eBPF 的优势更体现在高 PPS、高 Service 数、策略复杂度和 CPU 效率。  
- 本集群是虚拟网卡、75 Mbps 流量、95 Service，**不满足公开基准的高负载前提**；因此不要把“+25%”直接写进容量规划。

---

## 6. 替代方案与决策矩阵

### 6.1 可选方案

| 方案 | 变更 | 停机 | 人天 | 可观测性 | 性能 | 风险 | 适用场景 |
|---|---|---|---:|---|---|---|---|
| A. 现状 | 无 | 0 | 0 | 低 | 基线 | 低 | 稳定优先 |
| B. Calico IPIP→直连 | 改 IPPool `ipipMode=Never` | 0–5 min | 1–2 | 低 | +MTU/去封装 | 低 | 先拿性能小收益 |
| C. Calico eBPF + Operator + Whisker | 转 Operator、启用 eBPF、Whisker | 0–30 min（滚动） | 5–10 | 中（L3/L4，tech preview） | 高（eBPF；NodePort 可能走 VXLAN） | 中 | 不换 CNI 的性能+基础流观测 |
| D. Cilium chaining + Hubble | CNI 链式插件 + Cilium agent | 0 全局；局部滚动 | 3–5 | 高（L3/L4/L7 可选） | 基线（无 kube-proxy replacement） | 低–中 | 先验证 Hubble 价值 |
| E. 全量 Cilium | 删除 Calico，安装 Cilium | 1–3 h | 15–23 | 最高 | 高（受 5.15 限制） | 高 | 平台标准化/kube-proxy-free |
| F. 全量 Cilium + 替换 MetalLB | E + Cilium LB IPAM/L2 | 1–3 h | 18–28 | 最高 | 最高 | 很高 | 组件收敛，不建议首步 |

### 6.2 加权决策矩阵

权重按本集群现状设定：可观测性 30%、性能 15%、迁移风险 25%、成本 20%、战略 10%。评分 1–5，越高越好；评分含主观判断，团队可按自身优先级调整权重后重算。

| 方案 | 可观测性 (30%) | 性能 (15%) | 低风险 (25%) | 低成本 (20%) | 战略 (10%) | 加权分 |
|---|---:|---:|---:|---:|---:|---:|
| A. 现状 | 1 | 2 | 5 | 5 | 2 | **3.05** |
| B. Calico 直连 | 1 | 3 | 5 | 5 | 2 | **3.20** |
| C. Calico eBPF + Whisker | 3 | 4 | 3 | 3 | 3 | **3.15** |
| D. Cilium chaining + Hubble | 4.5 | 2 | 4 | 4 | 3 | **3.75** |
| E. 全量 Cilium | 5 | 4 | 2 | 2 | 5 | **3.50** |
| F. 全量 Cilium + LB | 5 | 4.5 | 1.5 | 1.5 | 5 | **3.35** |

**解读：**

- 在本集群“可观测性优先、性能不瓶颈”的权重下，**D（chaining + Hubble）得分最高**。
- 如果战略权重提高（例如明确要 kube-proxy-free、统一 Cilium、L7 策略），E 会胜出；但仍是高风险项目。
- B 是“最低成本的性能优化”，应作为 Phase 0 立即做。
- C 是“不换 CNI 的折中”，但 Whisker 是 tech preview，且需要 Operator 迁移；适合不想换 CNI、又需要基础流观测的团队。

### 6.3 推荐决策

**推荐：Phase 0 + Phase 1 先做，Phase 2 设 Go/No-Go。**

- 如果目标只是“性能更好”：先做 B（Calico 直连），不要换 CNI。
- 如果目标是“网络可观测性”：先做 D（Cilium chaining + Hubble），用 2–4 周验证 Hubble 是否真的被使用、是否解决排障问题。
- 如果目标是“平台标准化、kube-proxy-free、L7 策略、未来规模化”：在 D 验证后做 E；F 留到最后。
- **不建议**：为了“eBPF 更先进”直接做 E；为了“组件更少”同时做 F；为了“L7 可视”全局开 Envoy。

---

## 7. 分阶段实施计划与 Runbook

> 以下命令是计划/示例，本次评估**未执行**任何迁移操作。执行前请在 staging 验证并备份。

### 7.1 Phase 0：低成本优化（1–2 人天，0 停机）

#### 7.1.1 启用 Calico Felix 指标

当前 `calico-node` 没有暴露/抓取 Felix 指标。建议：

1. 给 `calico-node` 增加环境变量 `FELIX_PROMETHEUSMETRICSENABLED=true`，暴露 9091 端口。
2. 增加 ServiceMonitor，让现有 Prometheus 抓取。
3. 重点看：`felix_int_dataplane_*`、`felix_iptables_*`、`felix_cluster_*`、策略/IPSets 指标。

这是“零 CNI 变更”的可观测性增量，能先补上 Calico 数据面的盲区。

#### 7.1.2 Calico IPIP → 同二层直连

当前 `ipipMode: Always`，但 6 节点同二层。可以先做：

```bash
# 备份
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml \
  > backup/ippool-default.yaml

# 改为直连（不封装）
kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Never"}}'
```

验证：

- 跨节点 Pod 互通；
- Pod veth/路由 MTU 恢复 1500（已有 Pod 可能仍保持 1480，需要滚动重启才会更新）；
- `tunl0` 不再承载流量；
- BIRD 路由指向节点 IP，而不是 tunl0；
- 观察 24 小时无异常。

回滚：

```bash
kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Always"}}'
```

注意：IPPool 变更会影响现有路由，建议在低峰窗口执行；如果 BGP node-to-node mesh 未启用或网络不允许直连路由，不要做这一步。

#### 7.1.3 补 kube-proxy/Calico dashboard 与告警

- kube-proxy 已有 ServiceMonitor；补 Grafana dashboard（sync 耗时、规则数、Service 变更）。
- Calico 指标接入后补 Felix dashboard。
- 这一步为后续“是否真的需要 Cilium”提供基线。

### 7.2 Phase 1：Cilium chaining + Hubble 试点（3–5 人天，0 全局停机）

目标：不换 CNI，只给选定命名空间加 Hubble 可见性，验证价值与开销。

#### 7.2.1 安装方式

Cilium 官方提供 Calico chaining 指南：Calico 负责 IPAM/路由，Cilium 作为链式插件提供 eBPF 策略/可观测性。

`chaining.yaml` 示例（MTU 按当前 Calico 1480 设置）：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cni-configuration
  namespace: kube-system
data:
  cni-config: |-
    {
      "name": "generic-veth",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "calico",
          "log_level": "info",
          "datastore_type": "kubernetes",
          "mtu": 1480,
          "ipam": { "type": "calico-ipam" },
          "policy": { "type": "k8s" },
          "kubernetes": { "kubeconfig": "/etc/cni/net.d/calico-kubeconfig" }
        },
        {
          "type": "portmap",
          "snat": true,
          "capabilities": { "portMappings": true }
        },
        {
          "type": "cilium-cni"
        }
      ]
    }
```

安装 Cilium（示例）：

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 \
  --namespace kube-system \
  --set cni.chainingMode=generic-veth \
  --set cni.customConf=true \
  --set cni.configMap=cni-configuration \
  --set cni.exclusive=false \
  --set routingMode=native \
  --set enableIPv4Masquerade=false \
  --set enableIdentityMark=false \
  --set kubeProxyReplacement=false \
  --set l7Proxy=false \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{drop,tcp,flow}" \
  --set hubble.metrics.serviceMonitor.enabled=true \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true
```

注意：

- chaining 模式**不会**替换 kube-proxy，也不启用 eBPF host routing；它的价值是可观测性/部分策略，不是性能。
- 现有 Pod 不会自动获得 Cilium 端点；需要重启选定命名空间的 Pod 才会生效。
- 安装后确认 `/etc/cni/net.d` 中 Cilium 的 conflist（通常是 `05-cilium.conflist`）排在 `10-calico.conflist` 之前；否则新 Pod 可能仍走纯 Calico，Hubble 看不到。必要时先备份并移除旧的 Calico conflist，回滚时恢复。
- 先选低风险命名空间（如 `traefik`、`monitoring`、`logging`、`compassio`），不要一次性重启全部。
- **不要只把 Cilium agent 限制在 worker 节点**：chaining 配置下，任何可能创建 Pod 的节点都需要 Cilium agent，否则该节点新 Pod 可能因 `cilium-cni` 不可用而创建失败。控制面节点也运行 CoreDNS 等工作负载，必须覆盖。

#### 7.2.2 验证

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50

# 仅在启用 L7（l7Proxy=true）后才有 HTTP 可见性：
# kubectl -n kube-system exec ds/cilium -- hubble observe --namespace traefik --protocol http --last 20

# 连通性测试建议在装有 Cilium CLI 的机器上运行：
# cilium connectivity test
```

说明：Phase 1 示例 values 里 `l7Proxy=false`，此时 Hubble 主要提供 L3/L4 flow、TCP、drop 可见性；要看 HTTP/gRPC 或细粒度 DNS，需要单独开启 L7（`l7Proxy=true`）并配置 visibility/L7 策略，同时接受 Envoy 开销。

评估指标：

- Hubble 是否能看到真实业务流（不只是 health check）；
- 排障时间是否下降（例如策略拒绝、DNS 失败、5xx）；
- Cilium agent/Hubble 的 CPU/内存是否可接受；
- 是否有 Pod 因 chaining 配置无法启动；
- 与现有 Prometheus/Grafana/Loki 的集成是否顺畅。

#### 7.2.3 回滚

- 恢复原 Calico conflist（`/etc/cni/net.d/10-calico.conflist`）；
- 删除 chaining ConfigMap；
- `helm uninstall cilium -n kube-system`；
- 重启受影响的 Pod（让它们回到纯 Calico CNI）；
- 已运行的 Calico Pod 不受影响，回滚风险较低。

### 7.3 Phase 2：全量 Cilium（15–23 人天，1–3 h 停机）

#### 7.3.1 前置条件

- Phase 1 证明 Hubble 有实际价值；
- staging 完成 18 个 NP、Ceph、Kafka、CNPG、Tekton、MetalLB、kube-vip 验证；
- 备份：etcd 快照、Calico IPPool/Felix/BGP、kube-proxy DS/CM、CNI conflist、Cilium values；
- 预拉 Cilium 镜像（cilium、operator-generic、hubble-relay、hubble-ui、cilium-envoy，按实际 values 确认），避免切换窗口内拉镜像；
- 维护窗口与回滚演练完成；
- master02 内存余量 >= 500 MiB（或先扩容/迁移组件）。

#### 7.3.2 推荐 values（CNI 切换阶段）

先保持 `kubeProxyReplacement=false`，让 kube-proxy 继续工作，降低“CNI + Service 数据面”同时切换的风险；CNI 稳定后再第二阶段切 kube-proxy。

```yaml
cluster:
  name: home

k8sServiceHost: 10.0.0.168
k8sServicePort: 6443

routingMode: native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: true
devices: eth0

ipam:
  mode: kubernetes
k8s:
  requireIPv4PodCIDR: true

kubeProxyReplacement: "false"
bpf:
  masquerade: false
  hostLegacyRouting: true

l7Proxy: false

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - drop
      - tcp
      - flow
    serviceMonitor:
      enabled: true

prometheus:
  enabled: true
  serviceMonitor:
    enabled: true

operator:
  replicas: 2
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
```

说明：

- `ipam.mode=kubernetes` 复用 `node.spec.podCIDR`（当前 /24）；必须全量停止旧 Calico Pod，避免 IP 冲突。
- 若使用新 CIDR：`ipam.mode=cluster-pool` + `clusterPoolIPv4PodCIDRList: ["10.245.0.0/16"]` + `clusterPoolIPv4MaskSize: 26`，并同步 `ipv4NativeRoutingCIDR`。
- `devices=eth0` 是显式选择；当前 Calico 自动探测到 eth1，Cilium 不要让自动探测选错网卡。
- **CNI 阶段先不要切 Service 数据面**：保持 `kubeProxyReplacement=false`、`bpf.masquerade=false`、`hostLegacyRouting=true`，让 kube-proxy 继续负责 Service；这样把“CNI 切换”和“Service 数据面切换”拆成两个窗口。
- 第二阶段切 kube-proxy replacement 时再改为 `kubeProxyReplacement=true`、`bpf.masquerade=true`、`hostLegacyRouting=false`，然后删除 kube-proxy。
- `hostLegacyRouting=false` 会绕过宿主机 netfilter；当前 firewalld 未启用，风险较低。如果未来依赖主机防火墙/审计规则处理 Pod 流量，需要评估是否保持 legacy routing。
- `l7Proxy=false` 先关闭 Envoy；需要 L7 时再按命名空间开，并把 `hubble.metrics.enabled` 增加 `dns`/`httpV2`（同时接受 Envoy 开销）。

#### 7.3.3 切换顺序（建议）

1. **冻结变更**：暂停 ArgoCD auto-sync、Tekton、CI 发布；通知业务。
2. **备份**：etcd 快照；Calico/kube-proxy/CNI 配置；Kafka/CNPG/Ceph 数据备份。
3. **停止非关键负载**：先缩容无状态、可快速恢复的应用；保留 CoreDNS、API、CNI、存储、监控。
4. **停用 Calico 数据面**：
   - 删除 `calico-node` DS、`calico-kube-controllers`；
   - 删除 Calico CNI conflist；
   - 删除 `tunl0`、`cali*` 接口和遗留路由；
   - 清理 iptables/nftables 的 `cali-*` 链；
   - 确认没有新的 Calico 端点创建（旧端点会随 Pod 重建消失）；
   - **Calico CRD/IPPool 先不要删**：保留到 Cilium 稳定 24–72 小时后再删，便于回滚；删除前必须备份（CRD 删除会级联删除 CR）。
5. **安装 Cilium**：使用上面的 values；等待 `cilium status --wait`。
6. **重建 Pod**：按命名空间逐个删除/滚动重启，先核心（CoreDNS、Traefik、monitoring），再业务（Kafka、CNPG、Tekton、ArgoCD）。
   - 注意：在 Pod 重建完成前，旧 Pod 仍持有 Calico IP；Cilium 不识别这些旧端点，跨 CNI 的 Pod-to-Pod/Service 流量可能中断。因此应尽量缩短“Calico 已停、Pod 未重建完”的窗口，并避免在这个窗口内做业务变更。
   - 如果无法接受这个窗口，可在 staging 验证“先安装 Cilium CNI 配置（05 优先于 10-calico）、再移除 Calico”的顺序；但两套数据面短暂共存可能产生路由/策略冲突，不建议在生产首次迁移时尝试。
7. **验证**：见 7.3.5。
8. **切换 kube-proxy（第二阶段窗口）**：
   - 将 `kubeProxyReplacement` 改为 `"true"`，同时将 `bpf.masquerade` 改为 `true`、`bpf.hostLegacyRouting` 改为 `false`；这是第二个维护窗口，切换时现有连接会中断；
   - 确认 `k8sServiceHost/Port` 指向 `10.0.0.168:6443`；
   - 删除 kube-proxy DS；
   - 验证 ClusterIP/NodePort/LoadBalancer/MetalLB/kube-vip；
   - 如果 MetalLB 异常，可回退到 kube-proxy（需同时把 Cilium `kubeProxyReplacement` 改回 false，不能只恢复 kube-proxy），或评估 Cilium LB IPAM。
9. **恢复变更**：ArgoCD、Tekton、CI；观察 24–72 小时。

#### 7.3.4 清理 Calico 的注意事项

- 不要先删 CRD 再删工作负载：CRD 删除会删除 IPPool/BlockAffinity，可能导致 IPAM 状态丢失。
- 删除 Calico 后，节点上可能残留 `tunl0`、`cali*`、`blackhole` 路由；逐一清理，或按节点重启（重启前确保静态 Pod 与 Cilium 能恢复）。
- `iptables-save | grep cali` 检查残留；Cilium 可以容忍部分残留，但残留规则可能影响排障。
- 如果使用 nftables 原生链，也要清理 Calico 相关表；当前是 iptables-nft，重点看 `cali-*` 链。

#### 7.3.5 验证清单

| 类别 | 命令/检查 | 通过标准 |
|---|---|---|
| 节点 | `kubectl get nodes -o wide` | 全部 Ready，InternalIP 正确 |
| Cilium | `cilium status --wait` | Cilium/Operator/Hubble OK |
| 数据面 | `cilium-dbg status --verbose` | Routing: Native；Device Mode: veth；KubeProxyReplacement 符合阶段；切 kube-proxy 后 Host Routing 应为 BPF |
| 连通性 | `cilium connectivity test` | 全部通过（或明确已知豁免） |
| DNS | `dig @10.96.0.10 kubernetes.default.svc.cluster.local` | 解析正常 |
| Service | `kubectl get svc -A`、`kubectl get endpointslices -A` | 端点完整 |
| Ingress | `curl -H "Host: studyfree.xyz" http://10.0.0.252/` | 200/正常跳转 |
| kube-vip | `kubectl get --raw /healthz`（通过 10.0.0.168） | 正常 |
| MetalLB | `curl http://10.0.0.252` | Traefik 响应 |
| Ceph RBD | 创建测试 PVC + Pod，写入/读取 | 成功；CSI 日志无错误 |
| Kafka | `kubectl -n kafka get kafka my-cluster`；produce/consume | Ready；消息成功 |
| CNPG | `kubectl cnpg status pg16-ceph -n cnpg-system`；psql | Healthy；读写正常 |
| Tekton | 跑最小 PipelineRun | 成功；webhook 正常 |
| ArgoCD | `argocd app list` / UI | Synced/Healthy |
| 监控 | Prometheus targets、Grafana、Loki、Tempo | 全部 up；无数据断档 |
| 策略 | `hubble observe --verdict DROPPED` | 仅预期拒绝；无业务误杀 |
| 可观测性 | Hubble UI/CLI、Cilium/Hubble metrics | 能看到业务流与关键指标 |

#### 7.3.6 回滚方案

回滚不是“一键”，需要预留 1–2 小时：

1. 删除 Cilium（Helm uninstall；保留 CRD 还是删除需按版本说明）。
2. 恢复 Calico CNI conflist 与 `calico.yaml`；恢复 IPPool/Felix/BGP 配置。
3. 重新安装 Calico-node/kube-controllers；等待 Ready。
4. 如果之前删了 kube-proxy，恢复 DS/ConfigMap。
5. 删除所有 Pod，让它们重新走 Calico CNI；等待业务恢复。
6. 验证 DNS/Ingress/MetalLB/Ceph/Kafka/CNPG/Tekton。
7. 必要时从 etcd 快照恢复（最后手段）。

回滚前必须确认：Calico 镜像仍可拉取、IPPool 备份可用、kube-proxy 配置未丢失、业务数据未受影响。

### 7.4 Go/No-Go 条件

只有以下条件全部满足，才建议进入 Phase 2：

- [ ] Phase 1 的 Hubble 试点被实际使用，能解决至少 2 个真实排障场景；
- [ ] 性能瓶颈被数据证明（CPU/PPS/Service churn/延迟），而不是“感觉 eBPF 更快”；
- [ ] staging 通过 18 个 NetworkPolicy、42 个 hostNetwork、Ceph/Kafka/CNPG/Tekton/MetalLB/kube-vip 验证；
- [ ] 团队完成 Cilium 培训，有 `cilium-dbg`/`hubble` runbook；
- [ ] master02 等节点内存余量 >= 500 MiB，或已完成扩容；
- [ ] MetalLB 与 kube-proxy replacement 兼容性已验证，或接受 Cilium LB IPAM（beta）方案；
- [ ] 维护窗口、回滚演练、etcd/数据备份完成；
- [ ] 明确不把 netkit/Big TCP 作为本次目标（内核 5.15 不支持）。

任何一项不满足，建议停留在 Phase 0/1。

---

## 8. 最终结论

1. **Cilium 1.20.4 在本集群技术上完全可行**：6 节点内核、BTF、cgroup v2、bpffs、K8s 1.35 全部满足；Cilium 1.20 e2e 覆盖 K8s 1.33–1.36。  
2. **性能上，当前不是换 CNI 的好理由**：75 Mbps 流量、95 Service、conntrack <3.4%、kube-proxy 1.5–2.4 millicores，网络不是瓶颈；Cilium 的 netkit/Big TCP 又受 5.15 内核限制。  
3. **可观测性上，Hubble 是真实增量**：L3/L4/L7 flow、DNS、TCP、drop、policy verdict、服务图，能显著缩短网络排障时间；当前 Calico 连 Felix 指标都没抓取。  
4. **迁移代价主要在“CNI 切换”本身**：全部非 hostNetwork Pod 重建、IPAM 决策、42 个 hostNetwork、18 个 NP、Ceph/Kafka/CNPG/Tekton/MetalLB/kube-vip 验证；15–23 人天、1–3 小时窗口、1–2 小时回滚 RTO。  
5. **最优路径不是“二选一”**：  
   - 先做 **Calico 直连 + Felix 指标**（1–2 人天，0 停机）；  
   - 再做 **Cilium chaining + Hubble**（3–5 人天，0 全局停机）；  
   - 只有 Go/No-Go 全部通过，才做 **全量 Cilium**。  
6. **如果必须给一个一句话建议**：  
   > **现在不要为了性能换 Cilium；如果网络可观测性是痛点，先用 chaining + Hubble 花 3–5 人天验证；如果验证后确认需要 kube-proxy-free/L7/规模化，再做 15–23 人天的全量替换，并接受 1–3 小时停机与 1–2 小时回滚 RTO。**

---

## 附录 A：数据口径与限制

- 节点内核/BTF/cgroup/bpffs/内核配置：通过临时 privileged DaemonSet（hostPID）在 6 节点实测；评估结束后已删除。
- 流量/CPU/内存/conntrack/Calico/kube-proxy 指标：来自集群内 Prometheus（2026-11-07，5m rate）；部分指标为瞬时值，会随负载波动。
- Service/Pod/NP/PVC/Ingress 数量：来自 `kubectl` 实时查询；Tekton 等组件在评估期间有新安装，数量可能变化。
- 未执行 Cilium 安装或迁移；未做生产网络压测（避免影响业务）。性能结论基于实测指标 + 公开基准，不等同于本集群压测结果。
- 虚拟网卡 `ethtool` 无法报告速率；实际带宽上限未测量。
- Flow log 容量为基于 Pod 数/流量的粗估，需在 Phase 1 实测。
- Cilium/Calico 版本与文档会演进；执行前请重新核对官方兼容性与升级说明。

## 附录 B：主要参考

- Cilium 1.20 System Requirements：<https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium 1.20 Kubernetes Compatibility：<https://docs.cilium.io/en/stable/network/kubernetes/compatibility/>
- Cilium Kubernetes Without kube-proxy：<https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium Tuning Guide（netkit/Big TCP 内核要求）：<https://docs.cilium.io/en/stable/operations/performance/tuning/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- Cilium Metrics：<https://docs.cilium.io/en/stable/observability/metrics/>
- Cilium CNI Chaining on Calico：<https://docs.cilium.io/en/stable/installation/cni-chaining-calico/>
- Calico 3.32 eBPF data plane：<https://docs.tigera.io/calico/3.32/operations/ebpf/enabling-ebpf>
- Calico 3.32 Flow logs / Whisker（tech preview）：<https://docs.tigera.io/calico/3.32/observability/view-flow-logs>
- Calico 3.32 Enable Whisker（需 operator/Helm）：<https://docs.tigera.io/calico/3.32/observability/enable-whisker>
- Cilium CNI Benchmark（2021，历史参考）：<https://cilium.io/blog/2021/05/11/cni-benchmark/>

## 附录 C：本次评估使用的关键命令（节选）

```bash
# 节点与版本
kubectl get nodes -o wide
kubectl version
kubectl get pods -A -o wide

# Calico
kubectl -n kube-system get ds calico-node -o json
kubectl get ippools.crd.projectcalico.org -o yaml
kubectl get felixconfiguration default -o yaml
kubectl get bgpconfiguration default -o yaml
kubectl get networkpolicy -A
kubectl get crd | grep -i calico

# kube-proxy / Service
kubectl -n kube-system get cm kube-proxy -o yaml
kubectl get svc -A -o wide
kubectl get endpointslices -A
iptables -t nat -S | wc -l
iptables -t nat -S | grep -c KUBE-SVC
nft list ruleset | wc -l

# 主机 eBPF 前置条件（在临时 privileged Pod 内）
ls -l /sys/kernel/btf/vmlinux
mount | grep -E 'bpf|cgroup'
grep -E 'CONFIG_(BPF|BPF_SYSCALL|BPF_JIT|CGROUP_BPF|NET_CLS_BPF|DEBUG_INFO_BTF)=' /boot/config-$(uname -r)

# Prometheus 查询（通过 port-forward）
kubectl -n monitoring port-forward svc/prometheus-prometheus 19090:9090
# 示例：
# sum(rate(container_network_transmit_bytes_total{namespace!=""}[5m]))
# histogram_quantile(0.99, sum by (le)(rate(kubeproxy_sync_proxy_rules_duration_seconds_bucket[5m])))
# sum by (pod)(rate(container_cpu_usage_seconds_total{pod=~"calico-node.*"}[5m]))
```

---

**报告结束。**
