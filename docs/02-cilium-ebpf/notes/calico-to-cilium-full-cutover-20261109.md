# Calico → Cilium 全量替换执行报告

> 执行日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 结果：**Calico 已移除，Cilium 1.20.4 全量接管 CNI（非 chaining）**  
> 当前 Service 数据面：**kube-proxy 仍保留**（`KubeProxyReplacement=False`）  
> 当前 CNI：`05-cilium.conflist`（Calico CNI/CRD/DS 已删除）

---

## 0. 执行摘要

| 项目 | 结果 |
|---|---|
| Calico | ❌ 已移除 DS / controllers / CRD / RBAC / CNI 配置 |
| Cilium | ✅ 1.20.4 全量 CNI，非 chaining |
| Cilium agents | **6/6 Ready** |
| Cilium operator | **2/2 Ready** |
| Hubble Relay / UI | **Ready** |
| CNI 模式 | `CNI Chaining: none` |
| IPAM | `ipam.mode=kubernetes`，使用 node `podCIDR`（每节点 /24） |
| 路由 | `Routing: Network: Native`，`devices=eth0` |
| kube-proxy | 保留，`KubeProxyReplacement=False` |
| Masquerading | `IPTables` |
| Pod 总数 | 145，全部 Running/Ready |
| CiliumEndpoint | 96（其余为 hostNetwork/静态 Pod） |
| Pod MTU | `lxc*` 全部 1500，无 1480 |
| DNS | 正常（`10.96.0.1`） |
| Ingress | **200** |
| Kafka | Ready，produce/consume 成功 |
| CNPG | healthy，2/2，`select 1` 成功 |
| Prometheus | 126 targets up，0 down |
| 全量切换耗时 | 约 25–30 分钟（含故障恢复） |

**一句话：**

> Calico 已经从 CNI/路由/BGP/IPAM 层完全移除，Cilium 全量 CNI 接管；kube-proxy 仍保留，下一步才是 kube-proxy-free（`KubeProxyReplacement=True`）。

---

## 1. 最终架构

```text
Pod 创建
  │
  ▼
05-cilium.conflist
  └─ cilium-cni
       ├─ Cilium IPAM（Kubernetes IPAM，node podCIDR /24）
       ├─ Cilium native routing（eth0）
       └─ CiliumEndpoint / identity / policy / Hubble
  │
  ▼
kube-proxy（仍保留）负责 Service ClusterIP/NodePort
  │
  ▼
MetalLB L2（仍保留）负责 10.0.0.252 → Traefik
```

当前状态：

```text
Cilium:                  Ok   1.20.4
CNI Chaining:            none
KubeProxyReplacement:    False
IPAM:                    IPv4: x/254 allocated from 10.244.x.0/24
Routing:                 Network: Native   Host: Legacy
Device Mode:             veth
Masquerading:            IPTables [IPv4: Enabled]
Hubble:                  Ok
Controller Status:       49/49 healthy
```

> `Host: Legacy` 是因为 `kubeProxyReplacement=false`；真正启用 eBPF host routing 需要下一步切换 kube-proxy replacement。

---

## 2. 执行过程

### 2.1 窗口前准备

- 备份：
  ```bash
  /root/calico-cilium-full-cutover-20261109/
  ├── workloads-before.yaml
  ├── pods-before.txt
  ├── crds-before.txt
  ├── cilium-values-before.yaml
  ├── calico-node-before.yaml
  ├── ippool-before.yaml
  ├── 10-calico.conflist.m01
  └── 05-cilium.conflist.m01
  ```
- 冻结 ArgoCD application-controller、VPA updater/recommender。
- 确认无运行中的 Tekton PipelineRun。
- 创建 host-inspect DaemonSet，用于清理节点 CNI/接口/路由。

### 2.2 全量停机

为了让所有 Pod 重新由 Cilium IPAM 分配 IP，避免“旧 Calico IP 与新 Cilium IP 冲突”，执行全量 drain：

```bash
kubectl cordon m01 master01 master02 worker01 worker02 worker03

for n in m01 master01 master02 worker01 worker02 worker03; do
  kubectl drain $n --ignore-daemonsets --delete-emptydir-data \
    --force --disable-eviction --timeout=300s
done
```

说明：

- `--ignore-daemonsets` 保留 hostNetwork DaemonSet（Calico/Cilium/kube-proxy/kube-vip/MetalLB/node-exporter/Ceph CSI）。
- 所有普通 Pod 被驱逐，控制器保持 desired replicas，等待节点 uncordon 后重建。
- 这是**全量停机窗口**，DNS/Ingress 在 drain 后到 Cilium 就绪前不可用。

### 2.3 移除 chaining Cilium 和 Calico

```bash
helm uninstall cilium -n kube-system

kubectl -n kube-system delete ds calico-node
kubectl -n kube-system delete deploy calico-kube-controllers
kubectl -n kube-system delete cm calico-config cni-configuration

# 删除 Calico CRD（22 个）
kubectl get crd | grep -i calico | awk '{print $1}' | xargs -n1 kubectl delete crd
```

删除 Calico RBAC/SA：

```bash
kubectl -n kube-system delete sa calico-cni-plugin calico-kube-controllers calico-node
kubectl delete clusterrole,clusterrolebinding -l ... # 或按名字逐个删除
```

节点清理（host-inspect privileged Pod）：

```bash
rm -f /etc/cni/net.d/05-cilium.conflist
rm -f /etc/cni/net.d/10-calico.conflist
rm -f /etc/cni/net.d/calico-kubeconfig

ip link del cilium_host
ip link del cilium_net
ip link del tunl0
for i in /sys/class/net/cali*; do ip link del "$(basename "$i")"; done
ip route flush proto bird
```

结果：

- `/etc/cni/net.d` 只剩 Cilium 安装前的空目录。
- Calico CRD 数量：0。
- Calico DS/controllers：0。
- `tunl0` 的残留接口无路由（后续可重启清理）。

### 2.4 安装全量 Cilium

使用的 values：

```text
/root/cilium-migration-20261108/values-full-cni.yaml
/root/cilium-migration-20261108/values-full-clean.yaml   # cleanState: true
```

关键值：

```yaml
enableLBIPAM: false
defaultLBServiceIPAM: none

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
  relay: { enabled: true }
  ui: { enabled: true }
  metrics:
    enabled: [drop, tcp, flow]
    serviceMonitor:
      enabled: true
      trustCRDsExist: true
      labels: { release: prometheus }
```

安装：

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds \
  -f values-full-cni.yaml \
  -f values-full-clean.yaml
```

安装成功后：

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds \
  --reuse-values --set cleanState=false
```

原因：`cleanState=true` 只用于首次清理旧 Cilium BPF 状态；长期保留会导致 Cilium agent 重启时重复清理 datapath。

### 2.5 安装过程中的故障与处理

#### 故障 1：`cilium-secrets` namespace 卡在 Terminating

第一次 `helm install` 失败：

```text
roles.rbac.authorization.k8s.io "cilium-tlsinterception-secrets" is forbidden:
unable to create new content in namespace cilium-secrets because it is being terminated
```

原因：

- 卸载 chaining Cilium 时 `cilium-secrets` 进入 Terminating。
- 同时 metrics-server 被 drain 驱逐，`v1beta1.metrics.k8s.io` APIService 不可用，namespace 删除的 discovery 失败。
- namespace 一直卡住，导致全量 Cilium 无法创建 `cilium-secrets`。

处理：

```bash
# 保存 APIService 备份后删除
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml > metrics-apiservice-backup.yaml
kubectl delete apiservice v1beta1.metrics.k8s.io

# 强制移除已经空的 namespace finalizer
kubectl get ns cilium-secrets -o json | \
  jq '.spec.finalizers=[]' | \
  kubectl replace --raw "/api/v1/namespaces/cilium-secrets/finalize" -f -
```

之后重新 `helm install` 成功。metrics-server 恢复后，重新应用 APIService 备份，`v1beta1.metrics.k8s.io` 恢复 `AVAILABLE=True`。

#### 故障 2：Ceph RBD 卷挂载延迟

drain/重建后，CNPG、Kafka、Loki 等 PVC 出现：

```text
FailedAttachVolume ... timed out waiting for external-attacher
```

原因：

- 所有 Pod 同时重建，Ceph RBD 的 attach/detach 压力集中。
- Ceph CSI provisioner 被驱逐后需要重新拉起。

处理：

- 等 Ceph CSI provisioner 恢复；
- 等待 `VolumeAttachment` attach 成功；
- 不强制删除 VolumeAttachment，避免数据风险。

最终 CNPG、Kafka、Loki 全部恢复。

#### 故障 3：Kafka broker 启动慢 / entity operator CrashLoop

- Kafka broker 镜像 `quay.io/strimzi/kafka:1.0.0-kafka-4.1.2` 需要拉取，且 RBD 卷 attach 较慢。
- Entity Operator 在 broker 未 ready 前启动，topic-operator 连接 `my-cluster-kafka-bootstrap:9091` 超时，CrashLoop。
- Kafka broker ready 后，删除 Entity Operator Pod 让它重启。

结果：

```text
my-cluster-single-pool-0   1/1 Running
Kafka my-cluster           Ready=True
produce/consume            成功
```

#### 故障 4：Alloy / Loki Canary DaemonSet 仍是旧 Calico Pod

`kubectl drain --ignore-daemonsets` 不会驱逐 DaemonSet Pod，所以：

- `logging/alloy`、`logging/loki-canary` 仍是旧 Calico IP/旧 veth。
- Calico 删除后，它们的网络失效，出现 DNS `network is unreachable`。

处理：

```bash
kubectl rollout restart ds/alloy ds/loki-canary -n logging
```

重启后它们获得 Cilium IP，Alloy 2/2，loki-canary 1/1。

---

## 3. 最终验证

### 3.1 节点与 Pod

```text
6/6 节点 Ready
145 个 Pod，全部 Running/Ready
无 NotReady 容器
```

### 3.2 Cilium

```text
cilium-*             6/6 Running
cilium-operator-*    2/2 Running
hubble-relay-*       1/1 Running
hubble-ui-*          2/2 Running

Cilium:               Ok 1.20.4
CNI Chaining:         none
KubeProxyReplacement: False
IPAM:                 kubernetes（10.244.x.0/24 per node）
Routing:              Network: Native / Host: Legacy
Device Mode:          veth
Masquerading:         IPTables
Controller Status:    49/49 healthy
Hubble:               Ok
```

CiliumEndpoint：

```text
kubectl get ciliumendpoints -A | wc -l
96
```

其余为 hostNetwork/静态 Pod（Calico 移除后不再有 Calico endpoint）。

### 3.3 网络

```text
DNS:
  kubectl exec ... -- dig +short kubernetes.default.svc.cluster.local @10.96.0.10
  -> 10.96.0.1

Ingress:
  curl -H 'Host: studyfree.xyz' http://10.0.0.252/
  -> 200

跨节点 Pod -> Pod 1500 DF:
  ping -M do -s 1472 <prometheus-pod-ip>
  -> 0% packet loss

Pod MTU:
  lxc* 接口全部 1500，无 1480
```

### 3.4 数据面业务

| 项目 | 结果 |
|---|---|
| Kafka | `Ready=True`；produce/consume 成功 |
| CNPG | `Cluster in healthy state`；2/2；`select 1` 成功 |
| Ceph RBD | Prometheus/Grafana/CNPG/Kafka/Loki PVC 正常 |
| Prometheus | 126 targets up，0 down |
| Cilium targets | agent 6/6、operator 2/2、hubble 6/6 全部 up |
| ArgoCD | 16 个 Application 全部 Synced/Healthy |
| VPA | admission 2/2、recommender 2/2、updater 2/2 |

### 3.5 资源

```text
cilium-agent:    28–152m CPU / 180–251 MiB
cilium-operator: 2–6m CPU / 38–60 MiB
hubble-relay:    ~1m / 18 MiB
hubble-ui:       ~1m / 15 MiB
```

节点内存：

```text
m01       83%
master01  72%
master02  80%
worker01  78%
worker02  23%
worker03  39%
```

m01/master02/worker01 内存余量较低，后续开 L7 Envoy 或增加 Hubble buffer 前需评估。

---

## 4. 当前 Cilium 的边界

### 已完成

- Calico CNI/DS/controllers/CRD/RBAC 移除。
- Cilium 全量 CNI，所有新 Pod 由 Cilium IPAM 分配 IP。
- Native routing（eth0），无 IPIP/VXLAN/BGP。
- Pod MTU 1500。
- CiliumEndpoint/identity/policy/Hubble 覆盖所有普通 Pod。
- Hubble Relay/UI、Prometheus ServiceMonitor。
- 与 MetalLB L2、kube-vip、Ceph RBD、Kafka、CNPG 共存。

### 未完成（下一阶段）

| 项目 | 状态 | 说明 |
|---|---|---|
| kube-proxy replacement | ❌ 未启用 | `KubeProxyReplacement=False`，Service 仍由 kube-proxy iptables |
| eBPF host routing | ❌ 未启用 | `Host: Legacy`；需要 kube-proxy replacement + BPF masquerade |
| L7 / HTTP/gRPC 可见性 | ❌ 未启用 | `l7Proxy=false` |
| L7 策略 / FQDN | ❌ 未启用 | 需要 Envoy 和 CiliumNetworkPolicy |
| Calico eBPF | 不适用 | Calico 已移除 |
| 主机残留清理 | 部分 | `tunl0` 无路由；Calico `cali-*` iptables 链仍在；可重启清理 |

> **本次“全量替换”指 CNI/IPAM/路由层替换 Calico；Service 数据面仍是 kube-proxy。** 如果目标是完全 kube-proxy-free + eBPF host routing，还需要第二个窗口。

---

## 5. 运维要点

### 5.1 日常检查

```bash
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50
```

关注：

- `Controller Status` 是否全部 healthy；
- `IPAM` 使用率（每节点 /24，254 个 IP）；
- `Hubble` buffer 是否长期 100%（当前 `4095/4095`，需要时可增大 `hubble.eventBufferCapacity` 或减少 flow metrics）；
- CiliumEndpoint 数量是否与 Pod 数匹配；
- Cilium agent 内存/CPU；
- 节点内存压力（m01/master02/worker01 较紧）。

### 5.2 IPAM

- `ipam.mode=kubernetes`，每个节点使用 `node.spec.podCIDR`（/24）。
- kube-controller-manager 仍分配 `10.244.x.0/24`；CiliumNode 中可见。
- 单节点最多约 254 个 Pod；当前 worker01 约 83 个 Cilium endpoint，仍有空间。
- 扩容节点时，确保 kube-controller-manager 继续分配 podCIDR；Cilium 不会使用 Calico IPAM。

### 5.3 路由

- `Routing: native`，`devices=eth0`，`autoDirectNodeRoutes=true`。
- 依赖所有节点在同一二层/可路由 `10.0.0.0/24`；当前满足。
- 如果未来节点跨子网，需要：
  - 底层网络路由 Pod CIDR，或
  - 改 VXLAN/Geneve（MTU 1450/1442），或
  - 使用 BGP/其他路由方案。
- 当前 `tunl0` 接口无路由，不影响；可在维护窗口删除或重启清理。

### 5.4 kube-proxy

- 当前仍保留，`KubeProxyReplacement=False`。
- 下一步切换：
  ```yaml
  kubeProxyReplacement: "true"
  bpf:
    masquerade: true
    hostLegacyRouting: false
  ```
  使用 `values-full-kubeproxy.yaml` overlay。
- 切换前验证：
  - MetalLB L2 VIP；
  - kube-vip API VIP；
  - hostNetwork Pod 访问 Service；
  - NodePort/LoadBalancer；
  - kube-proxy 删除后的连接中断窗口。

### 5.5 MetalLB / kube-vip

- MetalLB L2 仍负责 `10.0.0.252`；当前 speaker 正常。
- Cilium LB IPAM 已关闭（`enableLBIPAM=false`），避免与 MetalLB 抢 IP。
- kube-vip 仍负责 API VIP `10.0.0.168`；Cilium `k8sServiceHost` 指向它。
- 如果未来切 kube-proxy-free，需要重新验证 MetalLB L2 与 Cilium Service 数据面兼容性。

### 5.6 清理残留

- `tunl0`：无路由，可 `ip tunnel del tunl0` 或重启清理。
- Calico `cali-*` iptables 链：当前未使用；可在维护窗口清理，避免误判。
- Calico CNI 二进制已删除；CRD/RBAC/SA 已删除。
- `/etc/cni/net.d` 只剩 `05-cilium.conflist`。

### 5.7 回滚

完整回滚需要恢复 Calico：

1. 备份在：
   - `/root/calico-phase0-backup-20261108/`
   - `/root/calico-cilium-full-cutover-20261109/`
2. 步骤：
   - 卸载 Cilium；
   - 删除 `05-cilium.conflist`；
   - 重新 apply Calico manifest/CRD；
   - 恢复 IPPool（`ipipMode: Never` 或 `Always`）；
   - **设置 `IP_AUTODETECTION_METHOD=interface=eth1`**（避免 cilium_host 劫持）；
   - 重启所有 Pod；
   - 验证 DNS/Ingress/Kafka/CNPG/Ceph。
3. RTO 约 1–2 小时；不是秒级回滚。

---

## 6. 下一步建议

### 6.1 先稳定观察 24–72 小时

- 观察 CiliumEndpoint/IPAM 使用率；
- 观察 Hubble buffer、Cilium agent 内存；
- 观察 Kafka/CNPG/Ceph 长稳；
- 验证 Tekton PipelineRun（NetworkPolicy 语义）；
- 验证 MetalLB/kube-vip。

### 6.2 第二窗口：kube-proxy replacement

使用：

```text
/root/cilium-migration-20261108/values-full-kubeproxy.yaml
```

目标：

```text
KubeProxyReplacement: True
Host Routing: BPF
```

收益：

- Socket-level LB；
- 去掉 kube-proxy iptables；
- eBPF host routing；
- 更低 Service 转发延迟/CPU。

风险：

- 现有连接会中断；
- MetalLB/kube-vip 兼容性；
- hostNetwork Pod 访问 Service；
- 需要回滚 kube-proxy。

### 6.3 可选：L7 / Hubble 增强

- `l7Proxy=true` + visibility/L7 策略；
- `hubble.metrics.enabled` 增加 `dns`/`httpV2`；
- 增加 Hubble buffer 或降低 flow 指标基数；
- 仅对必要命名空间开启，避免全局 Envoy 开销。

---

## 7. 产物与日志

```text
/root/calico-cilium-full-cutover-20261109/
├── workloads-before.yaml
├── pods-before.txt
├── crds-before.txt
├── cilium-values-before.yaml
├── calico-node-before.yaml
├── ippool-before.yaml
├── 10-calico.conflist.m01
├── 05-cilium.conflist.m01
├── cordon.log
├── drain.log
├── remove-chaining.log
├── delete-calico-crds.log
├── cilium-full-install.log
├── cilium-full-install-retry2.log
├── cilium-full-cleanstate-false.log
├── uncordon.log
├── fix-kafka.log
├── fix-tempo.log
├── restore-metrics-apiservice.log
└── metrics-apiservice-backup.yaml

/root/cilium-migration-20261108/
├── values-full-cni.yaml
├── values-full-clean.yaml
├── values-full-kubeproxy.yaml
├── values-chaining.yaml
├── chaining-configmap.yaml
└── ...
```

## 8. 参考

- Cilium System Requirements：<https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium kube-proxy-free：<https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium Routing：<https://docs.cilium.io/en/stable/network/concepts/routing/>
- Cilium IPAM：<https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- MetalLB L2：<https://metallb.universe.tf/concepts/layer2/>

---

**报告结束。**
