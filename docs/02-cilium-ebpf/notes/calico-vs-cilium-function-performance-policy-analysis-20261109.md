# Calico + kube-proxy 与 Cilium 全量替换后的功能、性能与 NetworkPolicy 差异

> 评估日期：2026-11-09  
> 对比对象：
> - **之前**：Calico 3.32.2（iptables/ipset + BIRD，IPIP 后期已改 Never）+ kube-proxy iptables
> - **现在**：Cilium 1.20.4 全量 CNI + `KubeProxyReplacement=True` + eBPF host routing + BPF masquerade；kube-proxy 已移除
>
> 数据来源：本集群实测 Prometheus、`kubectl top`、Cilium 状态、迁移窗口记录；资源数字为某一时刻采样，会随负载变化。

---

## 0. 结论摘要

| 维度 | 结论 |
|---|---|
| 功能 | Cilium 在 Service、NetworkPolicy、可观测性、L7/FQDN 方面是超集；Calico 的 BGP/Tiers/HostEndpoint 等能力需要显式替代或不再使用 |
| 资源占用 | 按组件对比，Cilium agent + operator + Hubble 的总内存/CPU **低于** 原 Calico + kube-proxy；但 dense 节点（worker01）Cilium agent CPU 更高 |
| 性能 | 当前流量/Service 规模下，差异主要是“新建连接延迟/每包 CPU”，不是吞吐瓶颈；Cilium 无 kube-proxy iptables 遍历，Host Routing/Masquerade 均为 BPF |
| 内核能力 | 5.15 不支持 netkit（6.8+）和 Big TCP（5.19/6.3+），因此 Cilium 的性能上限仍受内核限制 |
| NetworkPolicy | Cilium 支持 K8s NP + Cilium NP（L7/FQDN/entities），能力更强但语义更严格；**kubelet 探针被默认拒绝**是本次实际踩到的坑 |
| SRE 重点 | 策略迁移映射、健康检查放行、默认拒绝 rollout、Hubble 排障、Cilium 指标替代 kube-proxy/Calico 指标、资源与内核监控 |

**一句话：**

> 现在不是“简单的 CNI 替换”，而是从 iptables/kube-proxy 模型切换到 eBPF/identity 模型。功能更强、组件更少、总资源更低，但 NetworkPolicy 和健康检查的语义变化需要 SRE 重新建立 runbook。

---

## 1. 架构与功能对比

### 1.1 核心架构

| 维度 | 之前（Calico + kube-proxy） | 现在（Cilium 全量） |
|---|---|---|
| CNI | Calico CNI | Cilium CNI |
| IPAM | Calico IPAM（/26 block） | Cilium Kubernetes IPAM（node podCIDR /24） |
| 路由 | BIRD/BGP，后期 IPIP `Never` 直连 | Cilium native routing，`devices=eth0`，无 BGP |
| Service | kube-proxy iptables | Cilium eBPF（Socket LB + BPF service map） |
| 数据面 | iptables/ipset + netfilter conntrack | eBPF + BPF conntrack + BPF masquerade |
| Host routing | 宿主机 netfilter | `Host: BPF`（Pod 流量绕过宿主机 netfilter） |
| Masquerade | iptables MASQUERADE | `Masquerading: BPF` |
| 可观测性 | Felix 指标 + Prometheus；无流级日志 | Cilium 指标 + Hubble L3/L4；可选 L7 |
| 策略 | K8s NP + Calico CRD（GNP/CNP/HostEndpoint/Tiers） | K8s NP + Cilium NP/CCNP（L3/L4/L7/FQDN/entities） |
| LB | MetalLB L2 + kube-vip | MetalLB L2 + kube-vip（Cilium LB IPAM 关闭） |
| MTU | IPIP 时 1480；改直连后 1500 | Native routing 1500 |

### 1.2 功能差异

| 能力 | Calico + kube-proxy | Cilium | 说明 |
|---|---|---|---|
| ClusterIP/NodePort/LoadBalancer | kube-proxy iptables | Cilium eBPF | Cilium 已启用 Socket LB、NodePort、LB、externalIPs、HostPort |
| kube-proxy-free | ❌ | ✅ | 已删除 kube-proxy |
| 每包 netfilter | 走 iptables/conntrack | BPF host routing 绕过 | 延迟/CPU 更低 |
| L3/L4 策略 | ✅ K8s NP + Calico CRD | ✅ K8s NP + Cilium NP | Cilium 基于 identity |
| L7 HTTP/gRPC 策略 | 有限（OSS 以 L3/L4 为主） | ✅（Envoy，需开启） | 当前 `l7Proxy=false`，未启用 |
| FQDN/DNS 策略 | Calico OSS 有限 | ✅ Cilium `toFQDNs` | 需 DNS proxy |
| 全局策略 | Calico GlobalNetworkPolicy | Cilium CCNP | 语义/优先级需映射 |
| Host endpoint | Calico HostEndpoint | Cilium host firewall/CCNP | 当前未使用 |
| Tiers/Policy order | Calico Tiers/order | Cilium 策略优先级/deny/audit | 迁移需逐条核对 |
| BGP | BIRD，可外部 peer | Cilium BGP control plane（未启用） | 当前无外部 BGP peer，所以未造成功能缺口 |
| 流级可观测 | Felix 指标，无 flow | Hubble L3/L4，L7 可选 | Hubble buffer 当前 `4095/4095` |
| 服务依赖图 | 无 | Hubble UI | 可用 |
| 加密 | WireGuard 可选 | WireGuard/IPsec 可选 | 当前未启用 |
| 入口/Gateway API | Traefik + MetalLB | 可继续 Traefik/MetalLB；Cilium Gateway 可选 | 当前未替换 Ingress |

### 1.3 当前 Cilium 实际模式

```text
KubeProxyReplacement: True
Host Routing:         BPF
Masquerading:         BPF
Socket LB:            Enabled / Coverage: Full
Mode:                 SNAT
Backend Selection:    Random
XDP Acceleration:     Disabled
NodePort:             Enabled 30000-32767
LoadBalancer:         Enabled
externalIPs/HostPort: Enabled
```

不是 DSR，不是 Maglev，不是 XDP 加速；这些是后续可选优化。

---

## 2. 性能与资源占用对比

### 2.1 数据面性能路径

**之前：kube-proxy iptables**

```text
Pod -> veth -> host netfilter
  PREROUTING/OUTPUT -> KUBE-SERVICES
  -> KUBE-SVC-xxx -> KUBE-SEP-xxx -> DNAT backend
  -> conntrack -> veth -> Pod
```

特点：

- 规则线性遍历；Service/Endpoint 多时规则链变长。
- 全量/增量 `iptables-restore` sync；本集群实测 kube-proxy p50 sync 96 ms、p99 127 ms（频率低）。
- 每包经过 netfilter，CPU 随 PPS/规则数增长。
- 首包需要 DNAT。

**现在：Cilium eBPF**

```text
Pod connect()/sendmsg()
  -> Cilium socket LB 选 backend（或 tc/XDP LB）
  -> BPF service/backend map
  -> BPF conntrack / BPF masquerade
  -> veth/eth0 native routing
```

特点：

- BPF map 哈希查找，近似 O(1)。
- Socket LB 在 `connect()` 阶段选 backend，降低首包/新建连接延迟。
- Host routing 为 BPF，绕过宿主机 netfilter。
- Service 变更更新 BPF map，不再重写 iptables。
- 当前 `Mode=SNAT`、`XDP=Disabled`，NodePort/LB 走 tc 层。

### 2.2 资源占用：按组件对比

**之前每节点：**

| 组件 | CPU | 内存 |
|---|---:|---:|
| calico-node | 80–108m | 284–450 MiB |
| kube-proxy | 1.5–2.4m | 55–101 MiB |
| **合计** | **约 82–110m** | **约 340–550 MiB** |

**现在每节点：**

| 组件 | CPU | 内存 |
|---|---:|---:|
| cilium-agent | 28–152m | 145–251 MiB |
| cilium-operator（2 副本，按节点分摊） | 2–6m ×2 | 38–60 MiB ×2 |
| hubble-relay（1 副本） | ~1m | ~18 MiB |
| hubble-ui（1 副本） | ~1m | ~15 MiB |

当前实测总量（6 节点）：

```text
cilium-agent 合计：约 391m CPU / 1020 MiB
cilium-operator：  约 8m CPU / 98 MiB
hubble-relay/UI：  约 2m CPU / 33 MiB
合计：              约 401m CPU / 1.15 GiB
```

之前 Calico + kube-proxy 粗略合计：

```text
Calico：     约 535m CPU / 2.1 GiB
kube-proxy： 约 12m CPU / 0.44 GiB
合计：       约 547m CPU / 2.5 GiB
```

**结论：**

- 集群总内存/CPU **Cilium 更低**（约少 1.3 GiB、少 150m CPU，粗算）。
- 但 **dense 节点 worker01** 的 Cilium agent 达到约 150m CPU（83 个 endpoint），高于原 Calico 80–108m；端点密集节点 CPU 反而更高。
- eBPF map 使用内核内存，**不计入容器 working set**；实际内核内存还需加 50–200 MiB/节点量级（需看 `cilium_bpf_map_*`/memlock）。
- 节点整体内存百分比不能直接对比：当前 m01 82%、master02 81%、worker01 81%，高于迁移前，但这包含工作负载分布、page cache、Cilium/Hubble 和全部 Pod 重建后的变化；按组件对比才有意义。

### 2.3 性能收益/损失判断

| 场景 | 预期 |
|---|---|
| 新建 Service 连接 | Cilium Socket LB 通常更低延迟；本集群未做压测 |
| 已建立连接 | 差异很小；都依赖 conntrack/BPF conntrack |
| Service 数量/变更频率 | Cilium BPF map 更新优于 iptables 全量 sync；当前 105 Service 规模仍小 |
| NodePort/LB | Cilium BPF 优于 kube-proxy iptables；当前流量低 |
| Pod-to-Pod 吞吐 | 两者都 1500 MTU、native routing；Cilium veth + BPF，无 netkit，吞吐差异不应期待很大 |
| 高 PPS/低延迟 | Cilium eBPF host routing 更有优势；当前 75 Mbps 级流量看不出 |
| 资源 | Cilium 总资源更低；dense 节点 agent CPU 更高；eBPF map 内核内存另计 |
| L7 Envoy | 开启后每节点 +100–200 MiB、每请求 +0.1–1 ms；当前未开启 |

### 2.4 内核限制

当前内核 5.14/5.15：

- ✅ eBPF host routing
- ✅ BPF masquerade
- ✅ Socket LB
- ✅ Cilium kube-proxy replacement
- ❌ netkit（需要 6.8+）
- ❌ Big TCP（IPv6 5.19+ / IPv4 6.3+）

所以现在的性能是“eBPF 基础收益”，不是 Cilium 在 6.8 内核上的完整性能形态。

---

## 3. NetworkPolicy 差异

### 3.1 执行模型

| 维度 | Calico（之前） | Cilium（现在） |
|---|---|---|
| 执行点 | iptables/ipset（Felix） | eBPF（endpoint/identity/BPF policy map） |
| 选择器解析 | 转成 ipset/iptables 规则 | 转成 identity + policy map |
| 策略单元 | IP/端口/协议为主 | identity/label 为主，可表达 entities/L7/FQDN |
| 默认拒绝 | 支持 | 支持 |
| 规则更新 | iptables sync | BPF map 更新 |
| 策略可见性 | Felix 指标、iptables 规则 | Hubble verdict、`cilium-dbg policy` |
| Host 流量 | Calico host endpoint 路径 | Cilium host identity / `world` 语义 |

### 3.2 支持的策略类型

**Calico：**

- Kubernetes NetworkPolicy
- Calico NetworkPolicy / GlobalNetworkPolicy
- HostEndpoint
- StagedNetworkPolicy / StagedGlobalNetworkPolicy / StagedKubernetesNetworkPolicy
- Tiers / order
- L3/L4 为主；L7 能力有限/依赖商业版

**Cilium：**

- Kubernetes NetworkPolicy
- CiliumNetworkPolicy（namespaced）
- CiliumClusterwideNetworkPolicy（cluster-wide）
- L3/L4，L7 HTTP/gRPC（Envoy），DNS/FQDN（`toFQDNs`）
- `fromEntities` / `toEntities`：host、world、cluster、remote-node、kube-apiserver、ingress 等
- Deny 策略/策略审计模式
- Host firewall / CCNP node selector
- 不直接等价 Calico 的 Tiers/order；需要把规则语义显式映射

### 3.3 本集群实际踩到的差异：kubelet 探针被拒绝

迁移到 Cilium kube-proxy replacement + eBPF host routing 后，出现：

```text
10.244.3.57 (world) -> china-study-free/...:8787
Policy denied DROPPED
```

受影响：

- `china-study-free`
- `monitoring/wecom-adapter`
- `tekton-pipelines` 的 controller/webhook/events

原因：

- kubelet 探针源是 **Cilium host IP**（如 `10.244.3.57`），Hubble 识别为 `world`。
- 这些命名空间已有 K8s NetworkPolicy 默认拒绝/白名单，不允许该来源。
- Calico 时期同样的 K8s NP 下这些 Pod 是 Ready；Cilium 的 host 流量身份语义更严格。
- 尝试 `CiliumNetworkPolicy fromEntities: host` / `fromCIDR: 10.244.0.0/16` 没有覆盖 K8s NP 的默认拒绝。
- 最终在每个命名空间增加 K8s NP `allow-kubelet-health-probes`，只开放健康检查端口，Pod 才恢复 Ready。

**这是迁移 Cilium 时必须加入 runbook 的检查项：**

> 所有有默认拒绝/限制性 Ingress 的命名空间，必须显式允许 kubelet 健康检查端口（8080/8443/8787 等），否则 Pod 会在迁移后反复重启。

### 3.4 K8s NP 与 Cilium NP 的关系

- K8s NP 仍然是可移植的 L3/L4 策略来源，建议保留为基线。
- Cilium NP 用于：
  - L7 HTTP/gRPC；
  - FQDN/DNS；
  - `fromEntities`/`toEntities`（host/world/cluster/remote-node）；
  - 更细的 identity 策略。
- 不要假设 Cilium NP 一定能“覆盖”K8s NP 的默认拒绝；本集群实测需要显式 K8s NP 放行健康检查。
- 混用时必须逐条验证：策略是否命中、方向、端口、来源 identity、默认拒绝范围。

### 3.5 `ipBlock` 与 cluster CIDR 的坑

- 本集群尝试用 `ipBlock: 10.244.0.0/16` 放行 kubelet 探针，对 Cilium host 源没有达到预期效果。
- 最终用“K8s NP 只开放健康检查端口、不限制 from”恢复。
- 这说明：**Cilium 对 cluster 内部地址/主机源的 identity 处理与 Calico 的 IP 语义不同**；不要直接照搬 Calico 的 `ipBlock` 规则。
- 生产上应尽量用 Cilium 的 entities/host firewall 或在 K8s NP 中显式健康端口，并做 canary。

### 3.6 策略能力对照

| 能力 | Calico | Cilium |
|---|---|---|
| K8s NP | ✅ | ✅ |
| Global policy | GNP | CCNP |
| L7 HTTP/gRPC | 有限 | ✅（Envoy） |
| FQDN/DNS | 有限 | ✅ |
| Host endpoint | HostEndpoint | host firewall/CCNP |
| Tiers/order | ✅ | 需映射/优先级验证 |
| Staged/audit | Staged policies | policy audit mode |
| 流量 verdict | iptables/Felix 指标 | Hubble verdict |
| 策略 trace | iptables 规则反查 | `cilium-dbg policy trace` |

---

## 4. SRE / 运维注意事项

### 4.1 策略迁移

1. 先盘点：
   - K8s NP（可移植）
   - Calico GNP/CNP/HostEndpoint/Tiers/Staged
   - 默认拒绝命名空间
   - 健康检查端口、DNS、API server、监控抓取
2. K8s NP 原样保留；Calico 特有策略逐条映射到 Cilium NP/CCNP，不要直接删除。
3. 先 audit/观察，再 enforce：
   - Cilium policy audit mode；
   - Hubble `--verdict DROPPED` 观察；
   - 先在非生产/单命名空间验证。
4. 对默认拒绝命名空间，先加健康检查放行，再滚动重启。

### 4.2 健康检查

- 重点检查所有有 NetworkPolicy 的命名空间：
  - `china-study-free` 8787
  - `monitoring/wecom-adapter` 8080
  - `tekton-pipelines` 8080/8443/9090/8008/9097
- 现象：Pod `Running` 但 `0/1 Ready`，kubelet 报 `context deadline exceeded`，Hubble 显示 `Policy denied DROPPED`。
- 处理：增加健康端口放行 K8s NP；或调整 Cilium host 策略；不要只看容器日志。
- 健康端口放行范围尽量小；当前为恢复可用性使用了 `from` 为空（允许所有来源到健康端口），后续可收紧。

### 4.3 默认拒绝 rollout

- 不要一次性全集群默认拒绝。
- 按命名空间：
  1. 先观察现有流量（Hubble）；
  2. 加 DNS/API/健康检查/监控放行；
  3. audit；
  4. enforce；
  5. 回滚策略准备好。
- 特别注意：
  - DNS 53/TCP、53/UDP；
  - API server 6443；
  - kubelet 健康端口；
  - Prometheus 抓取端口；
  - Ceph/Kafka/CNPG 端口；
  - MetalLB/kube-vip。

### 4.4 排障命令

**Cilium 策略/服务：**

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy trace ...
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50
```

**Calico 时代（对比/回滚参考）：**

```bash
calicoctl get networkpolicy -A
iptables -t nat -L KUBE-SERVICES
iptables -L cali-INPUT
birdcl show protocols
```

### 4.5 指标与告警

- **移除/替换**：
  - `kubeproxy_*` 指标不再存在；
  - Calico Felix 指标/PodMonitor 已删除；
  - 相关 dashboard/告警要改为 Cilium。
- **新增关注**：
  - `cilium_*` agent/operator metrics；
  - `hubble_*` flow/drop/DNS/TCP/HTTP metrics；
  - `cilium_bpf_map_*`（map 使用/压力）；
  - CiliumEndpoint/identity 数量；
  - Hubble buffer 是否长期 100%（当前 `4095/4095`）。
- 告警建议：
  - `hubble_drop_total` 突增；
  - `cilium_agent_api_process_time_seconds`；
  - `cilium_bpf_map_pressure`；
  - Cilium agent/operator not ready；
  - Node memory pressure（m01/master02/worker01 较紧）。

### 4.6 资源与容量

- Cilium agent 内存 145–251 MiB/节点；dense 节点 CPU 可达 150m。
- Cilium operator 2 副本约 98 MiB；Hubble relay/UI 约 33 MiB。
- eBPF map 内核内存不显示在容器 working set，需看 `cilium_bpf_map_*`、`/sys/fs/bpf`、memlock。
- L7 Envoy 开启后每节点 +100–200 MiB、每请求 +0.1–1 ms；只对必要命名空间开启。
- 节点内存：m01 82%、master02 81%、worker01 81%，后续扩容/调度的前提要关注。

### 4.7 Service / LB / hostNetwork

- kube-proxy 已移除：
  - 不要再用 `kubectl logs kube-proxy` 排障；
  - 用 `cilium-dbg service list` / `bpf lb list`。
- MetalLB L2 仍负责 `10.0.0.252`；kube-vip 仍负责 API VIP。
- hostNetwork Pod：
  - ClusterIP 访问已验证正常；
  - 默认 DNS 使用节点 `/etc/resolv.conf`，需要集群 DNS 时用 `dnsPolicy: ClusterFirstWithHostNet` 或显式 `10.96.0.10`。
- NodePort/LB 验证：
  ```bash
  curl -H 'Host: studyfree.xyz' http://10.0.0.252/
  curl -H 'Host: studyfree.xyz' http://<node-ip>:30156/
  kubectl get --raw /healthz
  ```

### 4.8 升级与回滚

- `kubeProxyReplacement`、`bpf.masquerade`、`hostLegacyRouting` 是启动时配置；Helm 改 values 后必须：
  ```bash
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium
  ```
- 检查 `config-drift-checker` 日志，避免配置漂移。
- Cilium 升级逐 minor；保留 values/镜像；内核 5.15 不支持 netkit/BigTCP。
- 回滚 Calico：
  - 备份 `calico.yaml`、IPPool、Felix/BGP、kube-proxy DS/CM、CNI conflist；
  - 恢复 Calico 后必须设置 `IP_AUTODETECTION_METHOD=interface=eth1`，避免 `cilium_host` 被误认节点 IP；
  - 回滚 RTO 约 1–2 小时。

### 4.9 安全

- 健康检查 NP 当前对健康端口开放所有来源；后续可收紧到节点/Cilium host 实体。
- Cilium NP 的 `fromEntities: host`/`world` 语义与 Calico IP 语义不同，安全策略必须重新 review。
- 避免使用高基数 label 生成大量 identity；关注 CiliumIdentity 数量。
- Cilium agent 具备高权限；RBAC/镜像供应链/升级签名需纳入安全基线。
- 当前未启用 L7/加密；需要时再单独评估 Envoy/WireGuard 开销。

---

## 5. 最终结论

1. **功能上**：Cilium 已覆盖 ClusterIP/NodePort/LB/externalIPs/HostPort、K8s NP、Hubble 流级观测；L7/FQDN/identity 是增量能力。Calico 的 BGP/Tiers/HostEndpoint 能力在当前集群未使用，不构成功能缺口；若未来需要外部 BGP，需配置 Cilium BGP Control Plane。
2. **资源上**：按组件对比，Cilium 总内存/CPU 低于 Calico + kube-proxy；但 dense 节点 Cilium agent CPU 更高，eBPF map 内核内存另计；节点整体内存压力需要持续观察。
3. **性能上**：当前规模下收益主要在新建连接/每包 CPU/Service 变更；吞吐不是瓶颈。5.15 内核不支持 netkit/Big TCP，XDP 未启用，当前不是 Cilium 的极限性能形态。
4. **NetworkPolicy 上**：Cilium 能力更强但语义更严格；**kubelet 探针被默认拒绝**是实际踩坑，必须为有默认拒绝的命名空间显式放行健康端口。
5. **SRE 上**：排障入口从 `iptables/kube-proxy` 转为 `cilium-dbg/hubble/BPF map`；指标、告警、runbook、策略审计、健康检查放行都要同步更新。

---

## 附录：关键数据与命令

### 资源采样

```text
之前（Calico + kube-proxy）：
  calico-node: 80–108m CPU / 284–450 MiB
  kube-proxy:  1.5–2.4m CPU / 55–101 MiB

现在（Cilium）：
  cilium-agent: 28–152m CPU / 145–251 MiB
  cilium-operator: 2–6m CPU / 38–60 MiB ×2
  hubble-relay: ~1m / 18 MiB
  hubble-ui: ~1m / 15 MiB
```

### 关键命令

```bash
# Service/策略
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50

# 状态
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

# 资源
kubectl top pods -n kube-system -l k8s-app=cilium
kubectl top nodes
```

---

**报告结束。**
