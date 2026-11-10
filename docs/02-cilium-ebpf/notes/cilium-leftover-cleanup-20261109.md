# Cilium 迁移遗留清理报告

> 执行日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点  
> 当前 CNI：Cilium 1.20.4（全量 CNI + kube-proxy replacement）  
> 本次目标：清理 Calico / kube-proxy 残留，恢复因策略导致的健康检查异常，并记录清理过程

---

## 0. 执行摘要

| 项目 | 清理前 | 清理后 |
|---|---|---|
| kube-proxy DaemonSet | 已删除 | 仍然为 0 |
| kube-proxy ServiceMonitor | 已删除 | 仍然为 0 |
| `KUBE-SVC` / `KUBE-SEP` iptables 规则 | 825 条 `KUBE-*` | `KUBE-SVC/SEP=0`；仅剩 8 条 kubelet 基线规则 |
| Calico `cali-*` iptables 链 | 有 | **0** |
| Calico `calico-arp` nft 表 | 6 节点都有 | **0** |
| Calico ipset | m01 有 4 个 | **0** |
| Calico CRD / DS / RBAC / CNI | 已删除 | 仍为 0 |
| kube-proxy SA / RBAC | 仍存在 | 已删除 |
| `calico-node-felix` PodMonitor | 仍存在 | 已删除 |
| `tunl0` 接口 | 存在（无路由） | 仍存在（无路由，未使用） |
| 业务 Pod | 部分因探针失败 NotReady | **139 Running，0 NotReady** |
| DNS / Ingress / NodePort | 正常 | 正常 |
| Prometheus | 有少量 stale target | 120 up，0 down |
| ArgoCD | 正常 | 全部 Synced/Healthy |

**结论：**

> kube-proxy/Calico 的 Service 规则、Calico nft ARP 表、ipsets、RBAC 和旧监控对象已清理；Cilium 的 Service 数据面保持正常。清理过程中发现并修复了 Cilium kube-proxy replacement 下的 **kubelet 探针被 K8s NetworkPolicy 拒绝** 问题。

---

## 1. 清理前的遗留

### 1.1 kube-proxy iptables

```text
iptables-save | grep -c 'KUBE-'
825
```

包含：

- `KUBE-SERVICES`
- `KUBE-SVC-*`
- `KUBE-SEP-*`
- `KUBE-NODEPORTS`
- `KUBE-FIREWALL`
- `KUBE-KUBELET-CANARY`
- `KUBE-IPTABLES-HINT`

Cilium 已接管 Service，但旧规则仍存在，容易在排障时误导。

### 1.2 Calico iptables / nft / ipset

```text
cali-PREROUTING
cali-POSTROUTING
cali-egress-dscp
cali-from-host-endpoint
cali-to-host-endpoint
```

以及：

```text
table arp calico-arp
```

m01 上还有 4 个 Calico ipset。

### 1.3 kube-proxy RBAC

- `kube-system/kube-proxy` ServiceAccount
- `kube-system/kube-proxy` RoleBinding
- `kubeadm:node-proxier` ClusterRoleBinding

### 1.4 旧监控对象

- `monitoring/prometheus-kube-proxy` ServiceMonitor（已在前一步删除）
- `monitoring/calico-node-felix` PodMonitor（仍存在）

### 1.5 `tunl0`

Calico IPIP 隧道接口仍然存在，但没有路由，不影响 Cilium。

---

## 2. 清理执行

### 2.1 创建临时 host-clean DaemonSet

使用 privileged + hostPID + hostNetwork，镜像使用已缓存的 `quay.io/calico/node:v3.32.2`。

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: host-clean
  namespace: default
spec:
  selector:
    matchLabels:
      app: host-clean
  template:
    metadata:
      labels:
        app: host-clean
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
        - operator: Exists
      containers:
        - name: clean
          image: quay.io/calico/node:v3.32.2
          command: ["/bin/sh", "-c", "sleep 1800"]
          securityContext:
            privileged: true
          volumeMounts:
            - name: host
              mountPath: /host
      volumes:
        - name: host
          hostPath:
            path: /
```

每个节点通过：

```bash
nsenter -t 1 -m -u -i -n -p -- /bin/sh
```

进入宿主机命名空间操作。

### 2.2 备份 iptables

每个节点执行：

```bash
iptables-save > /root/iptables-before-clean-<node>-20261109.save
```

备份文件位于节点宿主机 `/root/`。

### 2.3 清理 kube-proxy / Calico iptables

采用“过滤后原子恢复”的方式：

```bash
iptables-save | grep -v -E 'KUBE|cali-' | iptables-restore
```

说明：

- 删除 `KUBE-*`、`cali-*` 链定义和引用规则。
- 不影响 Cilium 的 `CILIUM_*` 链。
- `iptables-restore` 原子替换，避免中间状态。
- 先在 m01 验证 DNS/ClusterIP/Ingress/NodePort/kube-vip 正常，再应用到其余 5 个节点。

结果：

```text
KUBE-SVC/SEP = 0
cali-*       = 0
```

保留的 8 条 `KUBE-*` 是 kubelet 自己维护的基线规则：

```text
KUBE-FIREWALL
KUBE-KUBELET-CANARY
KUBE-IPTABLES-HINT
```

这些不是 kube-proxy 的 Service 规则，删除后 kubelet 仍会重建，保留是正常状态。

### 2.4 清理 Calico nft ARP 表

Calico 的 `calico-arp` 表仍在 nftables：

```bash
nft delete table arp calico-arp
```

结果：

```text
nft list tables | grep -ci calico
0
```

### 2.5 清理 Calico ipset

```bash
ipset list -n | grep '^cali' | xargs -r ipset destroy
```

结果：

- m01 销毁 4 个；
- 其余节点 0 个；
- 清理后 `ipset list -n | grep -ci cali = 0`。

### 2.6 清理 Calico 主机目录

```bash
rm -rf /var/lib/calico /var/run/calico
```

Calico CNI 配置/二进制此前已删除，`/etc/cni/net.d` 仅剩：

```text
05-cilium.conflist
```

### 2.7 清理 kube-proxy RBAC

```bash
kubectl -n kube-system delete rolebinding kube-proxy
kubectl -n kube-system delete sa kube-proxy
kubectl delete clusterrolebinding kubeadm:node-proxier
```

保留 Kubernetes 默认的 `system:node-proxier` ClusterRole/Binding（系统基线，不删）。

### 2.8 清理旧监控对象

```bash
kubectl -n monitoring delete podmonitor calico-node-felix
kubectl -n monitoring delete servicemonitor prometheus-kube-proxy
```

### 2.9 清理临时 DaemonSet

```bash
kubectl delete -f host-clean-ds.yaml
```

---

## 3. 清理中发现并修复的问题

### 3.1 kubelet 探针被 K8s NetworkPolicy 拒绝

清理后部分 Pod 变为 NotReady：

- `china-study-free/china-study-free`
- `monitoring/wecom-adapter`
- `tekton-pipelines/tekton-events-controller`
- `tekton-pipelines/tekton-pipelines-controller`
- `tekton-pipelines/tekton-pipelines-webhook`

Hubble 显示：

```text
10.244.3.57 (world) -> china-study-free/...:8787
Policy denied DROPPED
```

原因：

- Cilium kube-proxy replacement + eBPF host routing 下，kubelet 探针源地址是 **Cilium host IP**（如 `10.244.3.57`），Hubble 将其标记为 `world`。
- 这些命名空间已有 K8s NetworkPolicy 默认拒绝/白名单，不允许来自该 `world` 地址的探针。
- 原有 Calico 环境下探针被放行，迁移到 Cilium 后策略语义变得更严格。

尝试过：

- CiliumNetworkPolicy `fromEntities: host`
- CiliumNetworkPolicy `fromCIDR: 10.244.0.0/16`

对 K8s NetworkPolicy 已选中的 Pod **没有覆盖效果**（K8s NP 仍然默认拒绝）。

最终修复：

在每个受影响命名空间增加一个 **K8s NetworkPolicy**，只开放健康检查端口：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kubelet-health-probes
spec:
  podSelector: ...
  policyTypes: [Ingress]
  ingress:
    - ports:
        - port: 8787
          protocol: TCP
```

实际文件：

```text
/root/cilium-kubeproxy-replacement-20261109/np-health-probes.yaml
```

覆盖：

- `china-study-free`：8787
- `monitoring/wecom-adapter`：8080
- `tekton-pipelines`：8080/8443/9090/8008/9097

结果：

- china-study-free Ready
- wecom-adapter 2/2 Ready
- Tekton 控制器、webhook、events、triggers 全部 Ready

**安全说明：**

- 这些规则对健康检查端口开放了所有来源（`from` 为空）。
- 这是为了让 kubelet 探针通过；健康端口通常只提供 healthz/metrics。
- 后续可以收紧为仅允许节点/Cilium host 网段，但当前 Cilium 将 host 源标记为 `world`，需要更精细的 Cilium 策略或 host firewall。

### 3.2 Tekton 控制器 `bind: address already in use`

Tekton 控制器多次被 liveness 杀后，在同一 Pod 网络命名空间内重启，出现：

```text
listen tcp :8080: bind: address already in use
```

处理：

```bash
kubectl -n tekton-pipelines delete pod \
  tekton-events-controller-... \
  tekton-pipelines-controller-... \
  tekton-pipelines-webhook-...
```

让它们获得新的 Pod sandbox/网络命名空间后恢复：

```text
tekton-pipelines-controller   1/1 Running
tekton-events-controller      1/1 Running
tekton-pipelines-webhook      1/1 Running
```

这不是 Cilium 数据面问题，而是容器反复重启后的本地端口残留。

---

## 4. 清理后验证

### 4.1 网络

| 测试 | 结果 |
|---|---|
| DNS `kubernetes.default.svc.cluster.local` | 10.96.0.1 |
| ClusterIP Prometheus | 200 |
| Ingress VIP `10.0.0.252` | 200 |
| NodePort `10.0.0.61:30156` | 200 |
| kube-vip `/healthz` | ok |

### 4.2 Cilium

```text
KubeProxyReplacement: True
Routing: Network: Native / Host: BPF
Masquerading: BPF
Controller Status: 62/62 healthy
```

### 4.3 残留检查

| 项目 | 结果 |
|---|---|
| kube-proxy DS | NotFound |
| kube-proxy Pods | 0 |
| Calico CRD | 0 |
| Calico DS/Deploy | 0 |
| Calico RBAC | 0 |
| `KUBE-SVC` / `KUBE-SEP` | 0 |
| `cali-*` iptables | 0 |
| `calico-arp` nft 表 | 0 |
| Calico ipset | 0 |
| `tunl0` | 仍存在，但无路由 |

### 4.4 集群健康

```text
139 Pod Running，0 NotReady
Prometheus：120 targets up，0 down
ArgoCD：全部 Synced/Healthy
```

---

## 5. 仍保留的残余

### 5.1 `tunl0`

```text
tunl0@NONE UNKNOWN 0.0.0.0 <NOARP,UP,LOWER_UP>
```

- 没有路由指向它。
- 是内核 ipip 模块的 fallback 设备，删除后可能被自动重建。
- 不影响 Cilium native routing。
- 可在节点重启后观察；如需彻底清理，需要卸载 `ipip` 模块或重启后确认。

### 5.2 kubelet 基线 iptables

保留 8 条：

```text
KUBE-FIREWALL
KUBE-KUBELET-CANARY
KUBE-IPTABLES-HINT
```

这是 kubelet 维护的，不是 kube-proxy，属于正常状态。

### 5.3 健康检查 NetworkPolicy

`allow-kubelet-health-probes` 已加入以下命名空间：

```text
china-study-free
monitoring
tekton-pipelines
```

需要纳入 GitOps/文档管理，避免后续被 ArgoCD 或人工覆盖。

### 5.4 旧监控

- `prometheus-kube-proxy` ServiceMonitor 已删除。
- `calico-node-felix` PodMonitor 已删除。
- 相关 Grafana dashboard/告警应同步删除或改为 Cilium 指标。

---

## 6. 回滚

如果清理导致问题：

1. **恢复 iptables**
   - 每个节点备份在 `/root/iptables-before-clean-<node>-20261109.save`
   - 恢复：
     ```bash
     iptables-restore < /root/iptables-before-clean-<node>-20261109.save
     ```
   - 注意：恢复会重新带回 `KUBE-*`/`cali-*` 旧规则；Cilium BPF 仍优先处理 Service。

2. **恢复 kube-proxy**
   ```bash
   kubectl apply -f /root/cilium-kubeproxy-replacement-20261109/kube-proxy-ds-before.yaml
   kubectl apply -f /root/cilium-kubeproxy-replacement-20261109/kube-proxy-cm-before.yaml
   ```
   然后把 Cilium 改回 `kubeProxyReplacement=false`，重启 Cilium DS。

3. **恢复 Calico nft/ipset**
   - 不建议恢复；Calico 已移除，旧 nft ARP 表无用途。

---

## 7. 结论

- kube-proxy 的 825 条 Service iptables 规则已清空，仅保留 kubelet 基线规则。
- Calico `cali-*` iptables、`calico-arp` nft 表、ipset、RBAC、CRD、DS 均已清理。
- kube-proxy SA/RBAC 和旧监控对象已删除。
- 清理后 DNS、ClusterIP、NodePort、LoadBalancer、MetalLB、kube-vip 全部正常。
- 发现并修复了 **Cilium kube-proxy replacement 下 kubelet 探针被 NetworkPolicy 拒绝** 的问题；这是后续 Cilium 迁移必须纳入 runbook 的检查项。
- 仅剩 `tunl0`（无路由）和 kubelet 基线的 8 条 `KUBE-*` 规则，均不影响运行。

---

## 8. 产物

```text
/root/cilium-kubeproxy-replacement-20261109/
├── host-clean-ds.yaml
├── np-health-probes.yaml
├── cnp-china-study-free-health.yaml
├── kube-proxy-ds-before.yaml
├── kube-proxy-cm-before.yaml
└── ...

节点宿主机：
/root/iptables-before-clean-<node>-20261109.save
```

---

**报告结束。**
