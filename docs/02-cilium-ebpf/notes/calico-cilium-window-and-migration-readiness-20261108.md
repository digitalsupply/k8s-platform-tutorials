# Calico → eBPF/Cilium 迁移执行窗口与准备报告

> 执行日期：2026-11-08  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 窗口目标：完成 IPIP 直连 + 全量 Pod MTU 统一 1500；为 Cilium 迁移做镜像/values/回滚准备  
> 当前状态：**IPIP `Never`、全集群 Pod MTU 1500、Felix 指标开启、Cilium 已预拉镜像但尚未安装**

---

## 0. 执行摘要

| 项目 | 结果 |
|---|---|
| IPIP `Always` → `Never` | ✅ 已完成并保留 |
| BGP 直连路由 | ✅ 5/5 mesh 邻居 `Established`，路由从 `tunl0` 切换到 `eth1` |
| 全量 Pod 滚动重启 | ✅ 完成；所有非 hostNetwork Pod 已重建 |
| Pod MTU | ✅ 全集群 `cali*` 接口 **0 个 1480，全部 1500** |
| Felix 指标 | ✅ 保持开启；6/6 target up；Grafana dashboard 正常 |
| Kafka | ✅ 恢复并验证 produce/consume |
| CNPG PostgreSQL | ✅ 完成 failover；2/2 healthy；`select 1` 成功 |
| Ceph RBD | ✅ 现有 PVC 工作负载正常；CSI provisioner 7/7 |
| Cilium 迁移准备 | ✅ 6 节点预拉 5 个 Cilium 镜像；values/runbook/rollback 已生成 |
| Cilium 是否安装 | ❌ 未安装（本次是准备，不是 CNI 切换） |
| 窗口耗时 | 约 1 小时（含 Kafka 故障恢复约 15 分钟） |

**一句话：**

> IPIP 直连和全量 MTU 1500 已经落地；Cilium 迁移所需的镜像、values、chaining 配置和回滚材料已经准备好，下一步可以在独立窗口执行 Cilium chaining 试点或全量 CNI 切换。

---

## 1. 执行前后状态对比

| 项目 | 窗口前 | 窗口后 |
|---|---|---|
| IPPool `ipipMode` | `Always` | **`Never`** |
| `calico-node` env `CALICO_IPV4POOL_IPIP` | `Always` | **`Never`** |
| 跨节点路由 | `via 172.16.1.x dev tunl0` | **`via 172.16.1.x dev eth1 proto bird`** |
| Pod veth/`cali*` MTU | 1480 | **1500** |
| Pod TCP MSS | 约 1440 | **约 1460** |
| 1500 字节 DF ping | 失败 | **成功** |
| Felix 指标 | 已启用 | 保持启用，6/6 up |
| Cilium 镜像 | 未预拉 | **6 节点全部预拉完成** |
| Cilium 组件 | 无 | **仍未安装** |

---

## 2. 执行窗口全过程

### 2.1 窗口前准备

1. **备份关键对象**
   ```bash
   mkdir -p /root/calico-cilium-migration-window-20261108
   kubectl get deploy,sts,ds -A -o yaml > workloads-before.yaml
   kubectl get pods -A -o wide > pods-before.txt
   kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml > ippool-before.yaml
   kubectl -n kube-system get ds calico-node -o yaml > calico-node-ds-before.yaml
   kubectl -n kube-system get cm calico-config -o yaml > calico-config-before.yaml
   ```

2. **冻结控制器，避免重启被回滚**
   ```bash
   kubectl -n argocd scale sts/argocd-application-controller --replicas=0
   kubectl -n kube-system scale deploy/vpa-vertical-pod-autoscaler-updater \
     deploy/vpa-vertical-pod-autoscaler-recommender --replicas=0
   ```

原因：

- ArgoCD 自动同步可能在滚动重启期间把 Pod template 改回原状。
- VPA updater 可能在窗口内驱逐 Pod。
- VPA admission controller 保留（否则可能影响 Pod 创建）。

3. **确认无正在运行的 Tekton PipelineRun**
   ```bash
   kubectl get pipelineruns -A --no-headers | awk '$3=="Running"'
   ```
   结果为空。

### 2.2 切换 IPIP 到 Never

```bash
kubectl -n kube-system patch ds calico-node --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Never"}]'

kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Never"}}'

kubectl -n kube-system rollout status ds/calico-node --timeout=240s
```

结果：

```text
IPPool ipipMode = Never
calico-node env CALICO_IPV4POOL_IPIP = Never
calico-node 6/6 Ready
```

路由验证：

```text
# 切换前
10.244.5.0/26 via 172.16.1.122 dev tunl0 proto bird

# 切换后
10.244.5.0/26 via 172.16.1.122 dev eth1 proto bird
10.244.30.64/26 via 172.16.1.123 dev eth1 proto bird
```

BGP：

```text
Mesh_172_16_1_120  BGP  Established
Mesh_172_16_1_121  BGP  Established
Mesh_172_16_1_122  BGP  Established
Mesh_172_16_1_123  BGP  Established
Mesh_172_16_1_124  BGP  Established
```

### 2.3 全量 Pod 滚动重启

原则：

- **只重启非 hostNetwork 工作负载**；Calico/kube-proxy/kube-vip/MetalLB speaker/node-exporter 等 hostNetwork Pod 不动。
- 按“控制面基础组件 → 监控/日志 → 数据库/消息 → CI/CD/业务 → Ingress”顺序。
- StatefulSet 逐个滚动；单副本业务接受短时中断。
- 对 RWO PVC 的 Deployment（Grafana、n8n）直接删 Pod，避免 RollingUpdate 新 Pod 先起导致 Multi-Attach。

执行顺序与结果：

| 顺序 | 命名空间/组件 | 方式 | 结果 |
|---:|---|---|---|
| 1 | `kube-system`（CoreDNS、metrics-server、calico-kube-controllers、VPA） | `rollout restart deploy` | 全部 Ready |
| 2 | `monitoring`（Prometheus、Alertmanager、Grafana、operator、kube-state-metrics、wecom） | STS rollout + Grafana 删 Pod | 全部 Ready |
| 3 | `logging`（Loki、Tempo、Alloy、canary） | `rollout restart deploy,sts` + DS | 全部 Ready |
| 4 | `cnpg-system` | operator rollout + PostgreSQL Pod 逐个删除 | 2/2 healthy |
| 5 | `kafka` | operator/entity rollout + broker 删除 | 恢复并验证 |
| 6 | `argocd` | `rollout restart deploy` + controller template | 全部 Ready |
| 7 | `tekton-operator`、`tekton-pipelines`、`tekton-pipelines-resolvers` | `rollout restart deploy` | 大部分 Ready；旧 Pod 补充删除 |
| 8 | `ceph-csi-rbd`、`cert-manager`、`opentelemetry`、`nfs-provisioner`、`metallb-system`、`gitlab-runner` | `rollout restart deploy` | 全部 Ready |
| 9 | `china-study-free`、`cicd`、`compassio`、`deeptutor`、`default` | `rollout restart deploy` | 全部 Ready |
| 10 | `n8n` | 删 Pod（RWO） | Ready |
| 11 | `traefik` | `rollout restart deploy` | Ready；Ingress 200 |
| 12 | `logging/alloy`、`logging/loki-canary` | `rollout restart ds` | 全部 Ready |

### 2.4 关键故障与恢复：Kafka StrimziPodSet

这是本次窗口唯一的显著故障。

**现象：**

- 删除 Kafka broker `my-cluster-single-pool-0` 后，Pod 没有被 Strimzi 重新创建。
- `StrimziPodSet` 状态错误地显示 `pods=1, readyPods=1`，但实际没有 Pod。
- Strimzi operator 反复报：
  ```text
  TimeoutException: Exceeded timeout of 300000ms while waiting for Pods resource
  my-cluster-single-pool-0 in namespace kafka to be ready
  ```
- Kafka CR `Ready=False`。

**根因：**

- 删除 broker Pod 时，Strimzi operator 正在滚动重启（leader 切换/缓存重建）。
- StrimziPodSet controller 的缓存状态陈旧，认为 Pod 仍存在，导致不重建。
- KafkaAssemblyOperator 又在等这个不存在的 Pod，形成死锁。

**恢复步骤：**

1. 确认 PVC `data-my-cluster-single-pool-0` 仍 Bound（数据未丢）。
2. 删除陈旧的 `StrimziPodSet`：
   ```bash
   kubectl -n kafka delete strimzipodset my-cluster-single-pool
   ```
3. 再次重启 Strimzi operator：
   ```bash
   kubectl -n kafka rollout restart deploy/strimzi-cluster-operator
   kubectl -n kafka rollout status deploy/strimzi-cluster-operator
   ```
4. Strimzi 重新创建 PodSet 和 broker Pod。
5. 验证：
   ```text
   my-cluster-single-pool-0   1/1 Running
   Kafka my-cluster           Ready=True
   kafka-topics.sh --list     __consumer_offsets, tempo-traces
   produce/consume            成功
   ```

**运维教训：**

- **不要**在 Strimzi operator 滚动重启期间删除 Kafka broker Pod。
- 正确顺序：先等 operator leader 稳定，再删 broker；或使用 Strimzi 的滚动更新机制。
- 删除后检查 `StrimziPodSet` 的 `pods/readyPods` 是否与实际 Pod 一致。
- 单 broker Kafka 没有副本，窗口内必须接受短暂不可用。

### 2.5 CNPG PostgreSQL 滚动重启

顺序：

1. 重启 CNPG operator。
2. 先删除 **replica** `pg16-ceph-3`，等待 Ready。
3. 再删除 **primary** `pg16-ceph-4`，CNPG 自动 failover 到 `pg16-ceph-3`。
4. 原 primary 重建为 replica。
5. 验证：
   ```text
   Cluster in healthy state
   currentPrimary=pg16-ceph-3
   ready=2/2
   pg_isready -> accepting connections
   psql -c 'select 1' -> 1
   ```

**运维教训：**

- 先删 replica，再删 primary。
- 等 `readyInstances=2/2` 再继续。
- PDB `minAvailable=1` 生效；不要同时删两个实例。
- 迁移窗口前确认 CNPG 备份/PVC 正常。

### 2.6 Tekton / EventListener 的特殊处理

`kubectl rollout restart` 对 Tekton operator 管理的 Deployment **不生效**：

- Tekton operator / Triggers EventListener 会把 Deployment template 改回自己的期望状态。
- 新 ReplicaSet 被缩到 0，旧 ReplicaSet 仍保留 1 个旧 Pod。
- 结果：旧 Pod 仍是 1480。

解决：

- 直接删除旧 Pod，让 Deployment/ReplicaSet 用当前模板重建 Pod；新 Pod 会从 Calico 拿到 1500 MTU。
- 涉及：
  - `tekton-events-controller`
  - `tekton-pipelines-controller`
  - `tekton-pipelines-remote-resolvers`
  - `tekton-pipelines-webhook`
  - `tekton-triggers-controller`
  - `tekton-triggers-webhook`
  - `el-china-study-free-listener`
  - `el-compassio-listener`
  - `el-deeptutor-listener`

**运维教训：**

- 对 operator 管理的 Deployment，`rollout restart` 可能被 reconcile 回滚；要以最终 Pod 的 MTU 为准。
- 重启后必须检查 `cali*` MTU，而不是只看 Deployment “successfully rolled out”。

### 2.7 恢复控制器

```bash
kubectl -n argocd scale sts/argocd-application-controller --replicas=1
kubectl -n kube-system scale deploy/vpa-vertical-pod-autoscaler-updater \
  deploy/vpa-vertical-pod-autoscaler-recommender --replicas=2
```

结果：

```text
argocd-application-controller 1/1
VPA updater/recommender 2/2
ArgoCD 6 个 Application 全部 Synced/Healthy
```

---

## 3. 验证结果

### 3.1 节点与 Pod

```text
6/6 节点 Ready
139 个 Running Pod，0 个 Running 但容器 NotReady
剩余非 Running 是历史 CI 任务的 Completed/Error Pod，与本次窗口无关
```

### 3.2 MTU 全量检查

通过每个节点的 `calico-node`（hostNetwork）检查 `cali*` 接口：

| 节点 | cali MTU 1500 | cali MTU 1480 |
|---|---:|---:|
| m01 | 2 | **0** |
| master01 | 2 | **0** |
| master02 | 1 | **0** |
| worker01 | 38 | **0** |
| worker02 | 34 | **0** |
| worker03 | 20 | **0** |

结论：**全集群 Calico veth 已统一 1500，没有 1480 残留。**

### 3.3 MTU/DF 实测

```text
# 宿主机 -> 新 Pod
ping -M do -s 1472 10.244.30.148
# 0% packet loss

# Pod -> Pod（netshoot -> Prometheus）
ping -M do -s 1472 10.244.30.169
# 0% packet loss，RTT 0.1 ms
```

### 3.4 核心服务

| 项目 | 结果 |
|---|---|
| Ingress `studyfree.xyz` | 200 |
| Ingress `compassio.xyz` | 200 |
| Ingress `deeptutor.xyz` | 307（正常跳转） |
| DNS `kubernetes.default.svc.cluster.local` | 10.96.0.1 |
| Service 总数 | 95 |
| EndpointSlice | 95 |
| Prometheus targets | 117 up，0 down |
| Felix targets | 6/6 up |
| Grafana Felix dashboard | 已加载 |
| Kafka | Ready；produce/consume 成功 |
| CNPG | healthy；2/2；`select 1` 成功 |
| Ceph RBD | Prometheus/Grafana/n8n 等 PVC 工作负载正常；CSI provisioner 7/7 |

### 3.5 资源状态

窗口后短时：

```text
m01        CPU 30%  MEM 72%
master01   CPU  9%  MEM 62%
master02   CPU 10%  MEM 72%
worker01   CPU  8%  MEM 43%
worker02   CPU 10%  MEM 53%
worker03   CPU 31%  MEM 52%
```

m01 节点 exporter 显示内存使用约 80%（含 page cache），后续安装 Cilium 前建议再确认实际可用内存，至少保留 500 MiB 余量。

---

## 4. Cilium 迁移准备

### 4.1 已预拉镜像（6 节点全部完成）

| 组件 | 镜像 | 状态 |
|---|---|---|
| cilium-agent | `quay.io/cilium/cilium:v1.20.4` | 6/6 节点已缓存 |
| operator | `quay.io/cilium/operator-generic:v1.20.4` | 6/6 |
| hubble-relay | `quay.io/cilium/hubble-relay:v1.20.4` | 6/6 |
| hubble-ui | `quay.io/cilium/hubble-ui:v0.13.6` | 6/6 |
| hubble-ui-backend | `quay.io/cilium/hubble-ui-backend:v0.13.6` | 6/6 |

预拉日志：

```text
/root/cilium-migration-20261108/prepull-m01.log
/root/cilium-migration-20261108/prepull-master01.log
/root/cilium-migration-20261108/prepull-master02.log
/root/cilium-migration-20261108/prepull-worker01.log
/root/cilium-migration-20261108/prepull-worker02.log
/root/cilium-migration-20261108/prepull-worker03.log
```

> 说明：`cilium-envoy` 镜像未预拉，因为当前 values 设置 `l7Proxy=false`；后续启用 L7 时再补拉。

### 4.2 已生成的 values / 配置文件

目录：`/root/cilium-migration-20261108/`

| 文件 | 用途 |
|---|---|
| `values-chaining.yaml` | Cilium CNI chaining on Calico；保留 Calico IPAM/路由；启用 Hubble |
| `values-full-cni.yaml` | 全量 Cilium 的 **CNI 切换阶段** values；`kubeProxyReplacement=false` |
| `values-full-kubeproxy.yaml` | 全量 Cilium 的 **Service 数据面切换阶段** overlay；`kubeProxyReplacement=true` |
| `chaining-configmap.yaml` | Calico + Cilium chaining 的 CNI 配置（MTU 1500） |
| `rendered-chaining.yaml` | `helm template` 渲染结果，已校验 |
| `rendered-full.yaml` | 全量 + kube-proxy overlay 渲染结果，已校验 |
| `kube-proxy-ds-backup.yaml` | kube-proxy DaemonSet 备份 |
| `kube-proxy-cm-backup.yaml` | kube-proxy ConfigMap 备份 |
| `10-calico.conflist.m01` | m01 的 Calico CNI 配置备份 |
| `prepull-images.txt` | 预拉镜像列表 |
| `cilium-prepull-ds.yaml` | 临时预拉 DaemonSet（已删除） |

### 4.3 values 关键点

#### Chaining（Phase 1）

```yaml
enableLBIPAM: false
defaultLBServiceIPAM: none

cni:
  chainingMode: generic-veth
  customConf: true
  configMap: cni-configuration
  exclusive: false

routingMode: native
enableIPv4Masquerade: false
enableIdentityMark: false
kubeProxyReplacement: "false"
l7Proxy: false

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled: [drop, tcp, flow]
```

说明：

- 保留 Calico IPAM/路由，Cilium 只做 chaining、策略/可观测性。
- `kubeProxyReplacement=false`，不替换 kube-proxy。
- `enableLBIPAM=false`，避免与 MetalLB 抢 LoadBalancer IP。
- `l7Proxy=false`，先只拿 L3/L4/TCP/drop；要看 HTTP/gRPC/DNS 再开 L7。

#### Full CNI 阶段

```yaml
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
```

切换 Service 数据面时叠加：

```yaml
kubeProxyReplacement: "true"
bpf:
  masquerade: true
  hostLegacyRouting: false
```

说明：

- 先把 CNI 切换和 kube-proxy 切换拆成两个窗口，降低爆炸半径。
- `devices=eth0` 显式指定，避免 Cilium 自动选到 eth1。
- `ipam.mode=kubernetes` 复用 `node.spec.podCIDR`（每节点 /24）；全量 Pod 重建后不会与 Calico 旧 IP 冲突。
- 若希望用新 CIDR（如 `10.245.0.0/16`），改用 `cluster-pool` 并同步 `ipv4NativeRoutingCIDR`。
- `enableLBIPAM=false`：第一阶段继续用 MetalLB；Cilium LB IPAM/L2 后续再评估。

### 4.4 Cilium 迁移 Go/No-Go

进入全量 CNI 切换前必须满足：

- [ ] Cilium chaining + Hubble 试点至少运行 1–2 周，确认可观测性有实际价值；
- [ ] staging 验证 18 个 NetworkPolicy、42 个 hostNetwork Pod；
- [ ] Ceph RBD、Kafka、CNPG、Tekton、ArgoCD、MetalLB、kube-vip 验证通过；
- [ ] MetalLB 与 Cilium kube-proxy replacement 兼容性验证通过，或接受保留 kube-proxy；
- [ ] 维护窗口、etcd/数据备份、回滚演练完成；
- [ ] master02/m01 内存余量 >= 500 MiB；
- [ ] 明确本次不使用 netkit/Big TCP（内核 5.15 不支持）。

---

## 5. Calico 与 eBPF + Cilium 的优缺点

### 5.1 Calico（当前：iptables/BIRD + IPIP）

**优点：**

1. **成熟稳定**：Calico 是生产验证最充分的 CNI 之一，当前集群已运行 295 天。
2. **BGP 能力强**：BIRD 支持节点 mesh、外部 peer、路由策略；适合 on-prem/裸金属。
3. **策略模型成熟**：Kubernetes NetworkPolicy + Calico GlobalNetworkPolicy/HostEndpoint；当前 18 个 NP 工作正常。
4. **不依赖新内核特性**：iptables 数据面在内核 5.14/5.15 上非常稳定。
5. **排障直观**：`iptables`、`ipset`、`ip route`、`birdcl` 都是团队熟悉的工具。
6. **无需 CNI 切换**：当前 IPIP 直连已经完成，保留了现有 CNI 的稳定性。
7. **Felix 指标可用**：本次已接入 Prometheus/Grafana，能监控 endpoint、iptables/ipset、resync、错误。

**缺点：**

1. **iptables/ipset 规模上限**：Service/Endpoint/Policy 数量大时，规则同步和遍历成本上升；当前 95 Service 还很小。
2. **kube-proxy 独立组件**：Service 转发依赖 kube-proxy；kube-proxy 全量 sync 有 96–127 ms 的开销（当前频率低）。
3. **没有原生流级可观测性**：Felix 指标是“数据面健康”，不是“业务流”；Calico OSS Whisker 仍是 tech preview，且当前 manifest 安装不支持，需要转 Operator。
4. **IPIP/VXLAN 封装开销**：IPIP 20 字节，MTU 1480；本次已改成直连 1500。
5. **L7 能力弱**：Calico OSS 以 L3/L4 为主；L7/FQDN/HTTP 策略不如 Cilium 完整。
6. **nftables 兼容性风险**：m01 上 `nft v1.0.9` 曾在 kube-proxy nftables 模式下产生 21 次 segfault；目前回退 iptables 模式。
7. **eBPF 数据面不是默认**：Calico eBPF 可用，但当前未启用；与 Cilium 的 eBPF 生态/可观测性仍有差距。

### 5.2 Calico eBPF（可选中间路线）

**优点：**

- 不换 CNI，保留 Calico IPAM/策略/BGP。
- eBPF 数据面 + kube-proxy replacement，性能和 Service 转发优于 iptables。
- 支持 direct routing；同二层可去掉 IPIP。
- 迁移风险低于 Cilium 全量替换。

**缺点：**

- eBPF 模式不支持 IPIP；需要 VXLAN 或直连路由；NodePort 可能仍走 VXLAN。
- 可观测性仍以 Felix 指标为主；没有 Hubble 级别的 L3/L4/L7 流。
- Calico eBPF 的社区生态、L7、Gateway API 不如 Cilium。
- 仍需把 manifest 安装转成 Tigera Operator 才能用 Whisker 等新能力。

### 5.3 eBPF + Cilium

**优点：**

1. **eBPF host routing**：绕过宿主机 netfilter/iptables，减少上下文切换和栈遍历；降低每包 CPU、降低延迟。
2. **socket-level LB**：`connect()` 时选择后端，减少 DNAT/conntrack；首包延迟更低。
3. **kube-proxy replacement**：BPF map O(1) 查找；Service 变更不再重写 iptables；高 churn 更稳。
4. **native routing**：直连路由，MTU 1500；去掉 IPIP/VXLAN 封装。
5. **Hubble 可观测性**：L3/L4 flow、TCP RTT/重传、drop、policy verdict；L7 HTTP/gRPC/DNS（需 Envoy）。
6. **身份化策略**：基于 label/identity，而不是纯 IP；支持 CiliumNetworkPolicy、L7、FQDN。
7. **Gateway API / Ingress / Service Mesh**：Cilium 1.20 支持 Gateway API v1.6.1；可逐步替代部分 Ingress/服务网格。
8. **DSR/XDP/大规模**：DSR、XDP 加速、Maglev 等适合高吞吐/大规模场景。
9. **CNCF 生态**：GKE Dataplane V2、Azure CNI Powered by Cilium 等采用，社区活跃。

**缺点：**

1. **迁移复杂**：CNI 切换需要全量 Pod 重建、IPAM 变更、NetworkPolicy 验证、hostNetwork/Stateful 工作负载验证。
2. **内核依赖**：Cilium 1.20 最低内核 5.10；本集群 5.14/5.15 可用，但 **netkit（6.8+）和 Big TCP（5.19/6.3+）不可用**。
3. **L7 开销**：Envoy 每节点 +100–200 MiB，延迟 +0.1–1 ms/请求；只应对选定命名空间开启。
4. **Hubble 开销/容量**：flow 指标可能高基数，flow log 存储可能 1–10 GB/天；需要过滤/采样/retention。
5. **资源占用**：agent/operator/Hubble/Envoy 增加 CPU/内存；master02 这类 4 GiB 节点需要关注。
6. **运维学习曲线**：`cilium-dbg`、`hubble`、BPF map、identity、policy verdict 与 iptables 思维不同。
7. **与 MetalLB/kube-vip 集成**：kube-proxy-free 后 LoadBalancer 行为需验证；Cilium LB IPAM/L2 仍是 beta 选项。
8. **hostNetwork 可见性有限**：Hubble 主要覆盖 Cilium 管理的 Pod 网络；42 个 hostNetwork Pod 不能全量观测。
9. **升级节奏**：Cilium 每年约 3 个 minor，只能逐 minor 升级；需要 preflight 和回滚计划。
10. **CNI 切换回滚成本**：不是秒级回滚，需要反向切换 + Pod 重建，RTO 约 1–2 小时。

### 5.4 对比总表

| 维度 | Calico iptables（当前） | Calico eBPF | Cilium eBPF |
|---|---|---|---|
| 数据面 | iptables/ipset | eBPF | eBPF |
| kube-proxy | 需要 | 可替换 | 可替换 |
| MTU | 1500（已直连） | 直连 1500；VXLAN 1450 | 直连 1500；VXLAN 1450 |
| 流级可观测性 | 无（Whisker tech preview） | 有限 | Hubble L3/L4/L7 |
| L7 策略 | 弱 | 弱 | 强（Envoy） |
| 迁移风险 | 低（已稳定） | 中 | 高 |
| 内核要求 | 低 | 5.10+ | 5.10+（netkit 6.8+） |
| 运维熟悉度 | 高 | 中 | 低–中 |
| 适用场景 | 稳定优先、当前规模 | 不换 CNI 的性能升级 | 可观测性/规模化/平台标准化 |

---

## 6. 运维要点

### 6.1 Calico 运维要点

1. **BGP 健康**
   ```bash
   P=$(kubectl -n kube-system get pods -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}')
   kubectl -n kube-system exec $P -- birdcl show protocols
   kubectl -n kube-system exec $P -- birdcl show route
   ```
   关注 `Established`；如果 BGP 断开，跨节点 Pod 可能不通。

2. **IPPool / IPAM**
   - 当前 `ipipMode=Never`、`vxlanMode=Never`、`blockSize=26`。
   - 新增节点如果不在同一二层，`Never` 会导致跨节点 Pod 不通；应改 `CrossSubnet` 或加路由。
   - 不要随意删除 `BlockAffinity`/IPPool。

3. **MTU**
   - 当前 Pod MTU 1500；新增节点/网卡 MTU 必须 >=1500。
   - 如果未来启用 IPIP/VXLAN，MTU 要相应回退到 1480/1450。
   - 变更 MTU 后必须滚动重启所有 Pod 才能统一。

4. **Felix 指标**
   - 关注：`felix_int_dataplane_failures`、`felix_iptables_restore_errors`、`felix_ipset_errors`、`felix_log_errors`、`felix_resyncs_started`。
   - `felix_cluster_num_workload_endpoints` 可评估规模。
   - 不要把 `felix_resync_state` 直接做阈值告警。

5. **iptables/nftables**
   - 当前 iptables-nft；m01 的 nft 1.0.9 有 segfault 历史，不要切 kube-proxy nftables 模式。
   - 定期检查 `iptables-save | grep cali` 和 `nft list ruleset` 是否有异常增长。

6. **kube-proxy**
   - 当前 iptables 模式；关注 `kubeproxy_sync_proxy_rules_duration_seconds`。
   - 如果 Service 数大幅增长，考虑 kube-proxy nftables/IPVS 或 Cilium kube-proxy replacement。

7. **变更窗口**
   - 修改 IPPool/MTU/CNI 前备份 IPPool、FelixConfiguration、calico-node DS、CNI conflist。
   - 单 broker Kafka、单副本 Traefik、CNPG primary 要单独排顺序。

### 6.2 Cilium 运维要点（迁移后）

1. **健康检查**
   ```bash
   cilium status --wait
   kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
   kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -E 'Host Routing|KubeProxyReplacement|Routing|Device Mode'
   ```
   期望（kube-proxy-free 后）：
   ```text
   Host Routing: BPF
   KubeProxyReplacement: True
   Routing: Native
   Device Mode: veth
   ```

2. **Hubble**
   ```bash
   kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
   kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50
   ```
   关注 drop、DNS NXDOMAIN、TCP 重传、HTTP 5xx。

3. **BPF map / conntrack**
   - 监控 `cilium_bpf_map_*`、`cilium_datapath_conntrack_*`。
   - 大规模/高连接场景调整 `bpf.mapDynamicSizeRatio`、CT map 大小。

4. **kube-proxy-free**
   - 切换前确认 `k8sServiceHost=10.0.0.168`、`k8sServicePort=6443`。
   - 切换时现有连接会中断；放在第二个维护窗口。
   - MetalLB 兼容性必须验证；不行就保留 kube-proxy 或迁移到 Cilium LB IPAM。

5. **L7/Envoy**
   - 默认 `l7Proxy=false`；只对需要 HTTP/gRPC/DNS 可见性的命名空间开启。
   - 监控 `cilium-envoy` 内存/CPU、HTTP 延迟。
   - 不要把全局 L7 当作默认配置。

6. **Hubble 容量**
   - 先启用 `drop,tcp,flow`；`flow` 指标高基数，按需加聚合/过滤。
   - flow log 只导出 deny/drop + 关键命名空间；retention 7–15 天。
   - 用 Alloy 采集 Hubble exporter 文件到 Loki，避免全量 firehose。

7. **升级**
   - 固定 `1.20.x`；逐 minor 升级；升级前 preflight。
   - 先升级 CRD，再升级 agent/operator；不要在业务高峰做。
   - 保留上一版本 values 和镜像。

8. **内核/BTF**
   - 当前 5.14/5.15 满足 1.20 最低要求；netkit/Big TCP 需要 6.8/5.19+。
   - 新增节点必须验证 `/sys/kernel/btf/vmlinux`、cgroup v2、bpffs、内核配置。

9. **主机网络**
   - 42 个 hostNetwork Pod 不受 Cilium CNI 管理；Hubble 覆盖有限。
   - hostNetwork 依赖 Service 的组件（node-exporter、Ceph CSI、MetalLB、kube-vip）要单独验证。

10. **回滚**
    - 保留 Calico manifests、IPPool、kube-proxy DS/CM、CNI conflist。
    - 回滚不是一键；需要删除 Cilium、恢复 Calico、重建 Pod，RTO 约 1–2 小时。

### 6.3 迁移窗口运维要点

1. **先冻结控制器**：ArgoCD application-controller、VPA updater/recommender。
2. **先备份再变更**：DS/STS/Pod 列表、IPPool、Calico DS/CM、CNI conflist、kube-proxy。
3. **先切 IPIP，再统一 MTU**：只改 IPPool 不够，旧 Pod 不会自动改 MTU。
4. **以 `cali*` MTU 为准**：不要只看 `kubectl rollout status`；operator 管理的 Deployment 可能回滚 template。
5. **Stateful 逐个处理**：CNPG 先 replica 后 primary；Kafka 先 operator 后 broker；RWO PVC 不要 RollingUpdate 并发起新 Pod。
6. **单副本业务接受短暂中断**：Traefik、Grafana、Prometheus、Kafka 单 broker、n8n。
7. **验证顺序**：节点 → Pod Ready → MTU → DNS → Service → Ingress → Kafka → CNPG → Ceph → ArgoCD。
8. **记录异常**：Kafka Strimzi 死锁、Tekton operator 回滚 rollout，都是本次实际遇到的坑。

---

## 7. 当前遗留与下一步

### 7.1 当前遗留

- Cilium **尚未安装**；本次只完成镜像/values/runbook 准备。
- `l7Proxy=false`，Cilium 的 L7/Hubble HTTP 可见性尚未启用。
- `cilium-envoy` 镜像未预拉（启用 L7 时再拉）。
- Cilium LB IPAM 已禁用，继续使用 MetalLB；兼容性需在 chaining/full 试点验证。
- m01 内存约 80%（含 page cache），master02 约 72%；Cilium 安装前建议确认实际可用内存。
- 历史 CI Error Pod 仍在 `cicd` 命名空间；与本次窗口无关，可后续清理。

### 7.2 推荐下一步

**方案 A：Cilium chaining + Hubble 试点（推荐先做）**

```bash
kubectl apply -f /root/cilium-migration-20261108/chaining-configmap.yaml
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 \
  --namespace kube-system \
  -f /root/cilium-migration-20261108/values-chaining.yaml
```

然后重启选定命名空间（如 `traefik`、`monitoring`、`logging`）的 Pod，让它们获得 Cilium endpoint；验证 Hubble 流、drop、TCP。

**方案 B：全量 Cilium（需要独立维护窗口）**

1. 先按 `values-full-cni.yaml` 安装，保持 `kubeProxyReplacement=false`。
2. 删除 Calico、重建全部 Pod。
3. 验证 CNI/DNS/Ingress/Kafka/CNPG/Ceph。
4. 第二个窗口叠加 `values-full-kubeproxy.yaml`，切换 kube-proxy replacement。
5. 验证 MetalLB/kube-vip；必要时回退或迁移 Cilium LB IPAM。

**方案 C：保持 Calico + Felix 指标（当前状态）**

- 已经拿到 IPIP 直连 + MTU 1500 + Felix 指标；
- 适合“稳定优先、暂不引入 CNI 切换风险”的场景。

---

## 8. 回滚

### 8.1 IPIP 回滚（当前已 `Never`，如需回退）

```bash
kubectl -n kube-system patch ds calico-node --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/6/value","value":"Always"}]'

kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool \
  --type=merge -p '{"spec":{"ipipMode":"Always"}}'

kubectl -n kube-system rollout status ds/calico-node
```

回滚后新 Pod MTU 会回到 1480；已有 1500 Pod 需要滚动重启才会统一 1480。

### 8.2 Cilium 回滚（未来）

- 保留：
  - `/root/cilium-migration-20261108/kube-proxy-ds-backup.yaml`
  - `/root/cilium-migration-20261108/kube-proxy-cm-backup.yaml`
  - `/root/calico-phase0-backup-20261108/calico-node-ds.yaml`
  - `/root/calico-phase0-backup-20261108/ippool.yaml`
  - `/root/calico-phase0-backup-20261108/calico-config.yaml`
  - `/root/cilium-migration-20261108/10-calico.conflist.m01`
- 回滚顺序：删除 Cilium → 恢复 Calico CNI/DS/CRD → 恢复 kube-proxy → 重建 Pod → 验证。
- 回滚 RTO 约 1–2 小时。

---

## 附录 A：产物与日志

```text
/root/calico-cilium-migration-window-20261108/
├── workloads-before.yaml
├── pods-before.txt
├── ippool-before.yaml
├── calico-node-ds-before.yaml
├── calico-config-before.yaml
├── restart-kube-system.log
├── restart-monitoring-sts.log
├── restart-monitoring-deploy.log
├── restart-logging.log
├── restart-cnpg.log
├── restart-kafka.log
├── restart-argocd.log
├── restart-tekton.log
├── restart-apps.log
├── restore-controllers.log
└── mtu-check.txt

/root/cilium-migration-20261108/
├── values-chaining.yaml
├── values-full-cni.yaml
├── values-full-kubeproxy.yaml
├── chaining-configmap.yaml
├── rendered-chaining.yaml
├── rendered-full.yaml
├── kube-proxy-ds-backup.yaml
├── kube-proxy-cm-backup.yaml
├── 10-calico.conflist.m01
├── prepull-images.txt
├── prepull-m01.log
├── prepull-master01.log
├── prepull-master02.log
├── prepull-worker01.log
├── prepull-worker02.log
├── prepull-worker03.log
└── cilium-prepull-ds.yaml
```

## 附录 B：关键命令

```bash
# IPIP 状态
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.ipipMode}'
kubectl -n kube-system get ds calico-node -o json | \
  jq -r '.spec.template.spec.containers[0].env[] | select(.name=="CALICO_IPV4POOL_IPIP") | .value'

# 路由/BGP
ip route | grep 10.244
kubectl -n kube-system exec $(kubectl -n kube-system get pods -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}') -- birdcl show protocols

# MTU
for i in /sys/class/net/cali*; do [ -e "$i/mtu" ] && echo "$i $(cat $i/mtu)"; done
ping -M do -s 1472 -c 2 <pod-ip>

# 滚动重启（示例）
kubectl rollout restart deploy -n <ns>
kubectl rollout status deploy -n <ns> --timeout=300s
kubectl rollout restart sts -n <ns>
kubectl rollout status sts -n <ns> --timeout=600s

# Cilium 渲染校验
helm template cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system -f /root/cilium-migration-20261108/values-full-cni.yaml \
  -f /root/cilium-migration-20261108/values-full-kubeproxy.yaml >/dev/null

# 预拉镜像（已执行）
# 使用临时 hostPID DaemonSet + nsenter + crictl pull
```

## 附录 C：参考

- Cilium 1.20 System Requirements：<https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium Kubernetes Compatibility：<https://docs.cilium.io/en/stable/network/kubernetes/compatibility/>
- Cilium kube-proxy-free：<https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium CNI Chaining on Calico：<https://docs.cilium.io/en/stable/installation/cni-chaining-calico/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- Calico IPPool / IPIP：<https://docs.tigera.io/calico/latest/reference/calicoctl/resources/ippool>
- Calico MTU：<https://docs.tigera.io/calico/latest/networking/configuring/mtu>
- Calico Felix metrics：<https://docs.tigera.io/calico/latest/operations/monitor>

---

**报告结束。**
