# Cilium 替换 kube-proxy 执行报告

> 执行日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 当前 CNI：Cilium 1.20.4（全量 CNI，非 chaining）  
> 本次变更：**移除 kube-proxy，启用 Cilium kube-proxy replacement + eBPF host routing + BPF masquerade**  
> 当前 Service 数据面：**Cilium eBPF（KubeProxyReplacement=True）**

---

## 0. 执行摘要

| 项目 | 结果 |
|---|---|
| kube-proxy | ❌ 已删除 DaemonSet / ConfigMap / ServiceMonitor |
| Cilium kube-proxy replacement | ✅ `KubeProxyReplacement=True` |
| eBPF host routing | ✅ `Host Routing: BPF` |
| BPF masquerade | ✅ `Masquerading: BPF` |
| Socket LB | ✅ `Enabled` / `Coverage: Full` |
| NodePort | ✅ 启用，范围 `30000-32767` |
| LoadBalancer | ✅ 启用；MetalLB L2 VIP `10.0.0.252` 正常 |
| externalIPs / HostPort | ✅ 启用 |
| Cilium agents | 6/6 Running |
| 业务 Pod | 139 Running，0 NotReady |
| DNS | 正常 |
| ClusterIP Service | 正常 |
| NodePort `30156` | 正常（200） |
| Ingress `10.0.0.252` | 正常（200） |
| kube-vip API VIP `10.0.0.168` | 正常（`/healthz` ok） |
| Prometheus | 126 targets up，0 down |
| ArgoCD | 全部 Synced/Healthy |
| 遗留 | 825 条旧 `KUBE-*` iptables 规则仍在；Cilium BPF 不依赖它们，可重启清理 |

**一句话：**

> kube-proxy 已经从集群移除，Cilium eBPF 接管 ClusterIP/NodePort/LoadBalancer/externalIPs/HostPort，Host Routing 和 Masquerade 都切到 BPF；DNS、Ingress、NodePort、MetalLB、kube-vip 均验证正常。

---

## 1. 最终状态

### 1.1 Cilium

```text
KubeProxyReplacement:    True   [eth0 10.0.0.124 (Direct Routing)]
CNI Chaining:            none
Cilium:                  Ok 1.20.4
Routing:                 Network: Native   Host: BPF
Device Mode:             veth
Masquerading:            BPF [eth0] 10.244.0.0/16 [IPv4: Enabled]
Controller Status:       56/56 healthy
```

`KubeProxyReplacement Details`：

```text
Status:               True
Socket LB:            Enabled
Socket LB Tracing:    Enabled
Socket LB Coverage:   Full
Devices:              eth0 10.0.0.124 (Direct Routing)
Mode:                 SNAT
Backend Selection:    Random
Session Affinity:     Enabled
Services:
- ClusterIP:      Enabled
- NodePort:       Enabled (Range: 30000-32767)
- LoadBalancer:   Enabled
- externalIPs:    Enabled
- HostPort:       Enabled
XDP Acceleration:     Disabled
```

### 1.2 Cilium Service 表

```text
10.96.0.10:53/TCP      ClusterIP  -> CoreDNS
10.96.0.10:53/UDP      ClusterIP  -> CoreDNS
0.0.0.0:30156/TCP      NodePort   -> Traefik 8000
0.0.0.0:30306/TCP      NodePort   -> Traefik 8443
10.0.0.252:80/TCP      LoadBalancer -> Traefik 8000
10.0.0.252:443/TCP     LoadBalancer -> Traefik 8443
```

### 1.3 kube-proxy 移除确认

```text
kubectl -n kube-system get ds kube-proxy
# NotFound

kubectl -n kube-system get cm kube-proxy
# NotFound

kubectl -n monitoring get servicemonitor prometheus-kube-proxy
# NotFound
```

---

## 2. 执行过程

### 2.1 备份

```text
/root/cilium-kubeproxy-replacement-20261109/
├── kube-proxy-ds-before.yaml
├── kube-proxy-cm-before.yaml
├── cilium-values-before.yaml
├── cilium-status-before.txt
├── cilium-upgrade-kubeproxy.log
├── cilium-rollout-restart.log
└── remove-kube-proxy.log
```

### 2.2 升级 Cilium values

使用 overlay：

```text
/root/cilium-migration-20261108/values-full-kubeproxy.yaml
```

内容：

```yaml
kubeProxyReplacement: "true"
bpf:
  masquerade: true
  hostLegacyRouting: false
```

执行：

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds \
  -f /root/cilium-migration-20261108/values-full-cni.yaml \
  -f /root/cilium-migration-20261108/values-full-kubeproxy.yaml
```

### 2.3 关键点：Helm 升级不会自动重启 Cilium agent

第一次升级后：

```text
KubeProxyReplacement: False
Host Routing: Legacy
Masquerading: IPTables
```

Cilium 日志出现配置漂移：

```text
Mismatch found key=enable-bpf-masquerade actual=false expectedValue=true
Mismatch found key=kube-proxy-replacement actual=false expectedValue=true
```

原因：

- `kubeProxyReplacement` / `bpf.masquerade` / `hostLegacyRouting` 属于 **agent 启动时生效** 的 datapath 配置。
- Helm 只更新了 `cilium-config` ConfigMap，没有改变 DaemonSet Pod template，所以 agent 没有重启。
- 必须手动重启 Cilium DS。

执行：

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=420s
```

重启后：

```text
KubeProxyReplacement: True
Routing: Network: Native / Host: BPF
Masquerading: BPF
```

### 2.4 验证 Cilium 服务能力

在删除 kube-proxy 之前，Cilium 与 kube-proxy 短暂共存。验证：

- DNS：`10.96.0.1`
- ClusterIP：Prometheus `/healthy` 200
- Ingress VIP：`10.0.0.252` 200
- NodePort：`10.0.0.61:30156` 200
- kube-vip：`kubectl get --raw /healthz` ok
- `cilium-dbg service list` 已包含 NodePort/LoadBalancer/ClusterIP

### 2.5 删除 kube-proxy

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
kubectl -n monitoring delete servicemonitor prometheus-kube-proxy
```

删除后再次验证：

```text
DNS / ClusterIP / NodePort / LoadBalancer / kube-vip 全部正常
```

---

## 3. kube-proxy 与 Cilium eBPF 的行为区别

### 3.1 数据面路径

| 维度 | kube-proxy（iptables） | Cilium eBPF |
|---|---|---|
| Service 编程 | 监听 Service/EndpointSlice，写 `KUBE-SVC`/`KUBE-SEP` iptables 链 | 监听 Service/EndpointSlice，写 BPF `lb4_services`/`lb4_backends` map |
| 包处理 | 包进入 netfilter，PREROUTING/OUTPUT 命中 `KUBE-SERVICES`，DNAT 到 backend | socket `connect()`/`sendmsg()` 阶段选 backend；或 tc/XDP 层 LB |
| 查找复杂度 | iptables 线性遍历规则链 | BPF map 哈希查找，近似 O(1) |
| 连接跟踪 | netfilter conntrack | Cilium BPF conntrack |
| 首包延迟 | 需要走 netfilter DNAT | Socket LB 可在 connect 阶段直接选 backend，首包更快 |
| NodePort | kube-proxy 写 `KUBE-NODEPORTS`/DNAT | Cilium BPF NodePort（当前 XDP 未启用，tc 层处理） |
| LoadBalancer | kube-proxy + 云 LB/MetalLB 配合 | Cilium BPF LB + MetalLB L2 ARP |
| HostPort | kube-proxy/CNI portmap | Cilium `HostPort: Enabled` |
| externalIPs | kube-proxy DNAT | Cilium `externalIPs: Enabled` |
| 规则同步 | 全量 `iptables-restore`；Service 多时同步慢 | 增量更新 BPF map |
| 失败模式 | iptables restore 失败、规则膨胀、nftables 兼容性 | BPF map/agent 异常、conntrack 表满、内核版本依赖 |

### 3.2 观测与排障

| 维度 | kube-proxy | Cilium |
|---|---|---|
| Service 列表 | `iptables -t nat -L KUBE-SERVICES` | `cilium-dbg service list` |
| BPF LB | 无 | `cilium-dbg bpf lb list` |
| 指标 | `kubeproxy_sync_proxy_rules_*` | `cilium_*`、`hubble_*`、Envoy 指标 |
| 流级可观测 | 无 | Hubble（L3/L4，可选 L7） |
| 健康检查 | kube-proxy `/healthz` | `cilium status` / `cilium-dbg status` |
| 规则同步延迟 | 全量 sync 可能有 100ms 级开销 | BPF map 增量更新 |

### 3.3 当前 Cilium 的具体模式

- `Mode: SNAT`：NodePort/LoadBalancer 回程经过 SNAT；不是 DSR。
- `Backend Selection: Random`：默认随机，不是 Maglev。
- `XDP Acceleration: Disabled`：当前走 tc 层，不是驱动 XDP。
- `Host Routing: BPF`：Pod 流量绕过宿主机 netfilter。
- `Masquerading: BPF`：Pod 出集群 SNAT 由 BPF 完成，不再依赖 iptables MASQUERADE。
- `Socket LB Coverage: Full`：Pod 内 `connect()` 直接选 backend，覆盖全部 Service 类型。

### 3.4 行为差异的实际影响

| 场景 | kube-proxy | Cilium eBPF |
|---|---|---|
| 新建连接 | 走 netfilter DNAT | connect 阶段选 backend，通常更低延迟 |
| 已建立连接 | conntrack 保持 | BPF conntrack 保持 |
| Service 变更 | iptables 全量/增量 sync | BPF map 更新，通常更快 |
| NodePort 外部访问 | iptables DNAT + SNAT | BPF NodePort + SNAT（当前模式） |
| MetalLB L2 | VIP ARP + kube-proxy DNAT | VIP ARP + Cilium BPF LB；已验证 10.0.0.252 正常 |
| hostNetwork Pod 访问 Service | 走 host netfilter | Cilium host BPF 处理；已验证 ClusterIP 正常 |
| 排障入口 | iptables/conntrack | cilium-dbg/hubble/BPF maps |

---

## 4. 验证结果

### 4.1 Service / Ingress

| 测试 | 结果 |
|---|---|
| DNS `kubernetes.default.svc.cluster.local` | `10.96.0.1` |
| ClusterIP Prometheus `/healthy` | 200 |
| Ingress `10.0.0.252` `Host: studyfree.xyz` | 200 |
| NodePort `10.0.0.61:30156` | 200 |
| kube-vip `10.0.0.168:6443 /healthz` | ok |
| MetalLB announce | `10.0.0.252` on worker03 |

### 4.2 hostNetwork Pod 测试

临时 hostNetwork Pod（busybox，nodeName=m01）：

```text
ClusterIP 10.111.41.17:9090/-/healthy -> 200
DNS 显式指定 10.96.0.10 -> kubernetes.default.svc.cluster.local -> 10.96.0.1
```

注意：

- hostNetwork Pod 默认使用**节点 `/etc/resolv.conf`**（223.5.5.5/119.29.29.29），不是集群 DNS。
- 需要集群 DNS 时必须显式指定 `10.96.0.10`，或配置 `dnsPolicy: ClusterFirstWithHostNet`。
- 这不是 Cilium 的故障，是 hostNetwork Pod 的 DNS 策略。

### 4.3 集群状态

```text
6/6 节点 Ready
139 Pod Running，0 NotReady
Cilium agents 6/6
Cilium operator 2/2
Hubble Relay/UI Ready
Prometheus 126 targets up，0 down
ArgoCD 全部 Synced/Healthy
```

### 4.4 资源

```text
cilium-agent: 39–150m CPU / 145–207 MiB
cilium-operator: 2–6m / 38–60 MiB
```

节点内存：

```text
m01       82%
master01  76%
master02  81%
worker01  81%
worker02  23%
worker03  39%
```

m01/master02/worker01 内存较紧；后续开 L7 Envoy 或增大 Hubble buffer 前需评估。

---

## 5. 遗留问题与清理

### 5.1 旧 kube-proxy iptables 规则仍存在

检查：

```bash
iptables-save | grep -c 'KUBE-'
# 825
```

当前 Cilium BPF 已接管 Service，旧 `KUBE-*` 规则**不再参与 Cilium 的 Pod-to-Service 路径**；DNS/ClusterIP/NodePort/LoadBalancer 均正常。

建议：

- 在维护窗口清理：
  - 使用 `kube-proxy --cleanup`（需要 hostNetwork/privileged Pod）；
  - 或重启节点，iptables 运行时规则会清空；
  - 或保留，不影响 Cilium BPF 路径，但排障时容易混淆。
- 不要直接手工删 `KUBE-*` 链，除非确认没有其他组件依赖。

### 5.2 Calico 残留

- Calico CRD/DS/RBAC/CNI 已删除。
- `tunl0` 接口仍存在但无路由。
- Calico `cali-*` iptables 链仍有残留；当前未被 Cilium 使用。
- 建议同一维护窗口重启节点清理 `tunl0`/旧 iptables 链。

### 5.3 kube-proxy 监控

- `monitoring/prometheus-kube-proxy` ServiceMonitor 已删除。
- `kubeproxy_*` 指标不再产生；相关 dashboard/告警应移除或改为 Cilium 指标。
- 如果 Helm/ArgoCD 重新创建该 ServiceMonitor，需要同步调整 values。

### 5.4 备份

删除前备份：

```text
/root/cilium-kubeproxy-replacement-20261109/kube-proxy-ds-before.yaml
/root/cilium-kubeproxy-replacement-20261109/kube-proxy-cm-before.yaml
```

回滚 kube-proxy 时使用。

---

## 6. 运维要点

### 6.1 日常检查

```bash
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
```

关注：

- `KubeProxyReplacement: True`
- `Host Routing: BPF`
- `Masquerading: BPF`
- `Controller Status` 全部 healthy
- `Socket LB: Enabled`
- Service list 中 NodePort/LoadBalancer 的 backend 是否正确
- Hubble buffer（当前 `4095/4095`，长期满可增大 buffer 或减少 flow 指标）

### 6.2 Service 变更

- Cilium 监听 Service/EndpointSlice，自动更新 BPF map。
- 不再需要 kube-proxy 全量 iptables sync。
- 变更后验证：
  ```bash
  kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
  kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
  ```

### 6.3 NodePort / LoadBalancer

- NodePort 范围 `30000-32767`，当前 Traefik `30156/30306` 正常。
- MetalLB L2 负责 `10.0.0.252` ARP；Cilium BPF 负责 DNAT 到 Traefik。
- Cilium LB IPAM 仍关闭（`enableLBIPAM=false`），避免与 MetalLB 抢 IP。
- 如果未来替换 MetalLB 为 Cilium LB IPAM/L2，需要单独验证。

### 6.4 hostNetwork

- hostNetwork Pod 的 ClusterIP 访问已验证正常。
- hostNetwork Pod 默认使用节点 DNS；需要集群 DNS 时用 `dnsPolicy: ClusterFirstWithHostNet` 或显式 `10.96.0.10`。
- 42 个 hostNetwork Pod（Ceph CSI、MetalLB、kube-vip、node-exporter 等）仍需持续观察。

### 6.5 升级/变更

- `kubeProxyReplacement`、`bpf.masquerade`、`hostLegacyRouting` 属于启动时配置；修改后必须重启 Cilium DS。
- 建议通过 Helm values 变更后：
  ```bash
  helm upgrade ...
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium
  ```
- 检查 `config-drift-checker` 日志，确认没有 `Mismatch found`。

### 6.6 回滚 kube-proxy

1. 恢复备份：
   ```bash
   kubectl apply -f /root/cilium-kubeproxy-replacement-20261109/kube-proxy-ds-before.yaml
   kubectl apply -f /root/cilium-kubeproxy-replacement-20261109/kube-proxy-cm-before.yaml
   ```
2. 将 Cilium 改回：
   ```yaml
   kubeProxyReplacement: "false"
   bpf:
     masquerade: false
     hostLegacyRouting: true
   ```
3. `helm upgrade` 后重启 Cilium DS。
4. 验证 `kube-proxy` Pod 和 `KubeProxyReplacement: False`。
5. 注意：切换时现有连接会中断，放在维护窗口。

---

## 7. 结论

1. **kube-proxy 已成功移除**：DS/ConfigMap/ServiceMonitor 均不存在。
2. **Cilium 已接管 Service 数据面**：ClusterIP、NodePort、LoadBalancer、externalIPs、HostPort 全部启用。
3. **eBPF host routing + BPF masquerade 已生效**：`Host: BPF`、`Masquerading: BPF`。
4. **业务验证通过**：DNS、Ingress、NodePort、MetalLB VIP、kube-vip、hostNetwork ClusterIP 均正常。
5. **主要坑**：Helm 升级不会自动重启 Cilium agent；修改 `kubeProxyReplacement` 后必须 `rollout restart ds/cilium`，否则配置漂移。
6. **遗留清理**：825 条旧 `KUBE-*` iptables 规则、Calico `cali-*` 链、`tunl0`，可在维护窗口清理/重启。

---

## 8. 产物

```text
/root/cilium-kubeproxy-replacement-20261109/
├── kube-proxy-ds-before.yaml
├── kube-proxy-cm-before.yaml
├── cilium-values-before.yaml
├── cilium-status-before.txt
├── cilium-upgrade-kubeproxy.log
├── cilium-rollout-restart.log
└── remove-kube-proxy.log
```

## 9. 参考

- Cilium kube-proxy-free：<https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium BPF masquerading：<https://docs.cilium.io/en/stable/network/concepts/masquerading/>
- Cilium native routing：<https://docs.cilium.io/en/stable/network/concepts/routing/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- MetalLB L2：<https://metallb.universe.tf/concepts/layer2/>

---

**报告结束。**
