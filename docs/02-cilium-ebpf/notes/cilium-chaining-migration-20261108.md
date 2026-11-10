# 迁移到 Cilium：Chaining + Hubble 执行报告

> 执行日期：2026-11-08  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> 当前架构：**Calico 负责 IPAM/BGP/路由；Cilium 1.20.4 以 generic-veth chaining 模式接入；kube-proxy 保留**  
> 结论：**Cilium chaining + Hubble 已成功运行**；全量 CNI 替换（删除 Calico）尚未执行，留待下一窗口

---

## 0. 执行摘要

| 项目 | 结果 |
|---|---|
| Cilium 版本 | `1.20.4` |
| 接入模式 | **CNI chaining：Calico → portmap → cilium-cni** |
| Cilium agents | **6/6 Ready** |
| Cilium operator | **2/2 Ready** |
| Hubble Relay / UI | **Ready** |
| `KubeProxyReplacement` | `False`（kube-proxy 保留） |
| `CNI Chaining` | `generic-veth` |
| `Routing` | `Network: Native` / `Host: Legacy` |
| `Masquerading` | `Disabled`（Calico 负责） |
| Calico IPIP | `Never`（直连路由，MTU 1500） |
| BGP | 5/5 mesh `Established`（`172.16.1.x`） |
| Pod MTU | 全集群 1500（无 1480 残留） |
| DNS / Ingress | 正常（`10.96.0.1` / HTTP 200） |
| Prometheus | 132 targets up；Cilium/Hubble targets 全部 up |
| 全量 CNI 替换 | ❌ 未执行 |

**一句话：**

> Cilium 已经以 chaining 模式接入并验证了 DNS、Ingress、跨节点 Pod 通信、MTU 1500、Hubble 流；Calico 仍在负责 IPAM/BGP/路由，kube-proxy 仍在负责 Service。全量替换 Calico 需要另一个独立窗口。

---

## 1. 本次迁移范围

按上一轮建议，本次执行的是 **Phase 1：Cilium chaining + Hubble 试点**，不是全量 CNI 替换。

### 为什么先做 chaining

- 不删除 Calico，不改变 IPAM/BGP，风险低。
- 可以真实验证 Cilium 1.20.4 在当前内核/集群上的兼容性。
- 可以验证 Hubble 的 L3/L4 流、DNS、TCP、drop 是否满足排障需求。
- 全量 CNI 替换需要全量 Pod 重建、IPAM 切换、42 个 hostNetwork、Ceph/Kafka/CNPG/Tekton/MetalLB 验证，属于高风险窗口。

### Chaining 的数据流

```text
Pod 创建
  │
  ▼
05-cilium.conflist（优先于 10-calico.conflist）
  ├─ 1. calico      -> Calico IPAM 分配 10.244.x.x，创建 veth
  ├─ 2. portmap     -> hostPort 支持
  └─ 3. cilium-cni  -> 创建 Cilium endpoint，挂载 eBPF 程序
```

---

## 2. 执行过程与故障处理

### 2.1 第一次安装：worker 节点 Cilium init 失败

安装命令：

```bash
kubectl apply -f /root/cilium-migration-20261108/chaining-configmap.yaml
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system \
  -f /root/cilium-migration-20261108/values-chaining.yaml
```

结果：

- `m01`、`master01`、`master02` 的 Cilium agent Running。
- `worker01/02/03` 的 Cilium agent 卡在 `Init:Error`。

错误：

```text
cp: cannot create regular file '/hostbin/cilium-mount': Permission denied
```

原因：

- worker 节点的 `/opt/cni/bin` 属主是 **1001:127**，权限 `755`。
- Cilium init container 以 root 运行，但 capabilities 里 **drop ALL**，只加了 `SYS_ADMIN/SYS_CHROOT/SYS_PTRACE`，没有 `DAC_OVERRIDE`。
- root 不是该目录 owner，755 权限下无法写入，导致 `cilium-mount` 复制失败。
- 控制面节点的 `/opt/cni/bin` 是 `root:root`，所以正常。

修复：

```bash
# 在每个 worker 上（通过临时 privileged hostPath Pod）
chown root:root /opt/cni/bin
chmod 755 /opt/cni/bin
```

修复后 worker 上的 Cilium agent 正常启动，6/6 Ready。

**运维教训：**

- Cilium 安装前必须检查所有节点 `/opt/cni/bin` 的属主/权限。
- 建议统一为 `root:root 755`，与 kubelet/CNI 预期一致。

### 2.2 第二次故障：DNS 全集群中断

第一次安装后，Cilium agent 全部 Running，但出现严重问题：

```text
DNS 10.96.0.10:53 超时
Ingress 10.0.0.252 返回 000
旧 Pod 和新 Pod 都无法解析 cluster.local
```

检查发现：

```text
Calico BGP mesh 变成了：
  Mesh_10_0_0_200
  Mesh_10_0_2_150
  Mesh_10_0_3_217
  Mesh_10_0_4_155
  Mesh_10_0_5_190
```

而不是原来的：

```text
Mesh_172_16_1_61
Mesh_172_16_1_120
Mesh_172_16_1_121
Mesh_172_16_1_122
Mesh_172_16_1_124
```

原因：

- Cilium chaining 在每个节点创建了 `cilium_host` 接口，并分配了 `10.0.x.x/32`。
- Calico 使用 `IP=autodetect`，在 `cilium_host` 出现后把 **Cilium host IP 误认为节点 IP**。
- Calico BGP mesh 从 `172.16.1.x` 切到 `10.0.x.x`，BGP 会话无法建立，跨节点路由被撤销。
- 结果：DNS 到 CoreDNS、Ingress 到 Traefik 全部跨节点失败。

修复步骤：

1. 回滚 Cilium：

   ```bash
   helm uninstall cilium -n kube-system
   ```

2. 删除所有节点上的 `05-cilium.conflist`（保留 `10-calico.conflist`）：

   ```bash
   rm -f /etc/cni/net.d/05-cilium.conflist
   ```

3. 给 Calico 固定节点 IP 自动探测接口：

   ```bash
   kubectl -n kube-system patch ds calico-node --type=json -p '[
     {"op":"add","path":"/spec/template/spec/containers/0/env/-",
      "value":{"name":"IP_AUTODETECTION_METHOD","value":"interface=eth1"}}
   ]'
   kubectl -n kube-system rollout status ds/calico-node --timeout=240s
   ```

4. 重启 CoreDNS，让它们重新使用 Calico CNI：

   ```bash
   kubectl -n kube-system delete pod -l k8s-app=kube-dns
   ```

5. 验证：

   ```text
   BGP: Mesh_172_16_1_61 / 120 / 121 / 122 / 124 全部 Established
   路由: 10.244.x.x via 172.16.1.x dev eth1
   DNS: 10.96.0.1
   Ingress: 200
   ```

**根因总结：**

> Calico 的 `IP=autodetect` 不能与 Cilium 的 `cilium_host` 共存。安装 Cilium 前必须先固定 `IP_AUTODETECTION_METHOD=interface=eth1`（或 eth0），否则 Calico 可能把 Cilium host IP 当成节点 IP，导致 BGP/路由/DNS/Ingress 全面异常。

### 2.3 重新安装：成功

在 Calico autodetect 固定为 `eth1` 后重新安装：

```bash
helm install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds \
  -f /root/cilium-migration-20261108/values-chaining.yaml \
  -f /root/cilium-migration-20261108/values-chaining-retry.yaml
```

其中 `values-chaining-retry.yaml`：

```yaml
cleanState: true
```

作用：清理第一次安装残留的 Cilium BPF/本地状态，避免旧 state 干扰。

安装后：

- Cilium agent 6/6 Ready。
- BGP 保持 `172.16.1.x`，没有再次被 `cilium_host` 劫持。
- DNS/Ingress 正常。
- 新 Pod 获得 Cilium endpoint。

然后执行：

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds \
  --reuse-values --set cleanState=false
```

原因：`cleanState=true` 只适合首次清理；如果长期保留，Cilium agent 每次重启都可能清理 datapath state。现在已改为 `false`。

---

## 3. 最终状态

### 3.1 Cilium 组件

```text
cilium-8tmcb   1/1 Running   worker02
cilium-g2n9f   1/1 Running   worker03
cilium-mz88v   1/1 Running   worker01
cilium-n7zxh   1/1 Running   m01
cilium-tsbpb   1/1 Running   master02
cilium-xzxw7   1/1 Running   master01

cilium-operator-... 2/2 Running
hubble-relay-...    1/1 Running
hubble-ui-...       2/2 Running
```

`cilium-dbg status`：

```text
KubeProxyReplacement:    False
CNI Chaining:            generic-veth
Cilium:                  Ok   1.20.4
Routing:                 Network: Native   Host: Legacy
Masquerading:            Disabled
Controller Status:       9/9 healthy
Hubble:                  Ok   Current/Max Flows: 58/4095 (1.42%)
```

### 3.2 网络状态

| 项目 | 状态 |
|---|---|
| Calico IPIP | `Never` |
| Calico BGP | 5/5 `Established`（`172.16.1.x`） |
| 跨节点路由 | `via 172.16.1.x dev eth1 proto bird` |
| Pod MTU | 全集群 1500；`cali*` 无 1480 |
| 新 Cilium Pod MTU | 1500 |
| 旧 Pod → 新 Cilium Pod 1500 DF ping | 0% loss |
| 新 Cilium Pod → 旧 Pod ping | 0% loss |
| DNS | 正常（`10.96.0.1`） |
| Ingress | `studyfree.xyz` 200 |
| Prometheus targets | 132 up；Cilium/Hubble targets 全部 up |

### 3.3 已迁移为 Cilium endpoint 的工作负载

- CoreDNS（Cilium operator 自动重启，`--pod-restart-selector=k8s-app=kube-dns`）
- Traefik（手动 `rollout restart`）
- `default/netshoot-debug`（手动 rollout）
- 新建测试 Pod（验证后已删除）

其余大部分 Pod 仍是 Calico endpoint；Cilium chaining 只对**新建/重启后的 Pod**生效。要扩大 Hubble 覆盖范围，需要滚动重启对应命名空间。

### 3.4 资源占用

```text
cilium-agent:   25–39m CPU / 153–215 MiB
cilium-operator: 2–6m CPU / 43–78 MiB
hubble-relay:   1m CPU / 18 MiB
hubble-ui:      1m CPU / 15 MiB
```

节点内存：

```text
m01       84%
master01  74%
master02  84%
worker01  53%
worker02  58%
worker03  59%
```

m01 和 master02 内存余量较低（约 0.6–0.9 GiB），后续开启 L7 Envoy 或更多 Hubble 功能前需要关注。

---

## 4. Cilium Chaining 的当前能力与限制

### 已有能力

- Cilium endpoint 创建、identity、K8s NetworkPolicy 加载。
- Hubble L3/L4 flow、TCP、drop、DNS 可见性（当前 `l7Proxy=false`，HTTP/gRPC 未开）。
- 新 Pod 的 MTU 1500。
- 跨节点 Cilium ↔ Calico Pod 互通。
- Prometheus metrics / ServiceMonitor / Grafana。
- Hubble Relay/UI。

### 当前限制

| 限制 | 说明 |
|---|---|
| 不替换 kube-proxy | `KubeProxyReplacement=False`，Service 仍由 kube-proxy iptables 处理 |
| 不启用 eBPF host routing | `Host: Legacy`，无 eBPF host routing 性能收益 |
| 不接管 IPAM | Pod IP 仍由 Calico IPAM 分配（10.244.x.x） |
| Cilium IPAM 仅内部 | `10.0.x.x/24` 是 Cilium 内部 host IP，不用于 Pod |
| 旧 Pod 无 Hubble 覆盖 | 只有重启后的 Pod 才有 Cilium endpoint |
| L7 未启用 | `l7Proxy=false`，HTTP/gRPC/DNS 细粒度需要后续开启 Envoy |
| 策略范围有限 | 旧 Calico Pod 不受 Cilium policy 管理；K8s NP 主要对新 endpoint 生效 |
| 不适合作为最终形态 | 最终目标仍是全量 Cilium 或长期 Calico+Cilium 双栈（不推荐） |

---

## 5. 重要运维变更

### 5.1 Calico 固定节点 IP 探测（永久保留）

```bash
kubectl -n kube-system get ds calico-node -o json | \
  jq -r '.spec.template.spec.containers[0].env[] | select(.name=="IP_AUTODETECTION_METHOD") | .value'
# interface=eth1
```

**不要删除这个环境变量。** 否则 Cilium 的 `cilium_host` 可能再次被 Calico 误认为节点 IP，导致 BGP/DNS/Ingress 故障。

### 5.2 `/opt/cni/bin` 属主

所有节点统一为：

```text
root:root 755 /opt/cni/bin
```

否则 Cilium init container 的 `mount-cgroup` 会因缺少 `DAC_OVERRIDE` 而失败。

### 5.3 Cilium `cleanState`

- 首次重装使用 `cleanState=true` 清理旧 BPF state。
- 安装成功后已改为 `cleanState=false`。
- 查看：
  ```bash
  helm get values cilium -n kube-system | grep cleanState
  # cleanState: false
  ```

### 5.4 CoreDNS 被 Cilium 重启

Cilium operator 带有：

```text
--pod-restart-selector='k8s-app=kube-dns'
```

它会把 CoreDNS Pod 重启成 Cilium endpoint，以便 DNS 可见性/策略。当前 CoreDNS 已由 Cilium 管理，DNS 正常。

### 5.5 访问 Hubble UI

```bash
kubectl -n kube-system port-forward svc/hubble-ui 8080:80
# 浏览器打开 http://localhost:8080
```

Hubble CLI：

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 50
```

---

## 6. 回滚方案

如果后续验证发现问题，可回滚 chaining：

```bash
# 1. 卸载 Cilium
helm uninstall cilium -n kube-system

# 2. 删除所有节点的 05-cilium.conflist（保留 10-calico.conflist）
#    通过 hostPath privileged Pod 执行：
rm -f /etc/cni/net.d/05-cilium.conflist

# 3. 重启 CoreDNS，让它们回到 Calico
kubectl -n kube-system delete pod -l k8s-app=kube-dns

# 4. 确认 Calico autodetect 仍为 eth1
kubectl -n kube-system get ds calico-node -o json | \
  jq -r '.spec.template.spec.containers[0].env[] | select(.name=="IP_AUTODETECTION_METHOD") | .value'

# 5. 验证
kubectl -n default exec deploy/netshoot-debug -- dig +short kubernetes.default.svc.cluster.local @10.96.0.10
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: studyfree.xyz' http://10.0.0.252/
```

回滚后 Calico 仍是主 CNI；Cilium CRD/CR 可保留，后续可重装。

---

## 7. 下一步

### 7.1 扩大 Cilium endpoint 覆盖（推荐）

按命名空间滚动重启，让更多 Pod 进入 Cilium 管理：

```bash
kubectl rollout restart deploy -n monitoring
kubectl rollout restart deploy -n logging
kubectl rollout restart deploy -n compassio
kubectl rollout restart deploy -n deeptutor
```

**先不要**对 `kafka`、`tekton-pipelines` 等有 NetworkPolicy 的命名空间做批量重启，先在 staging 验证策略语义。

### 7.2 开启 L7 可见性（可选）

需要：

```yaml
l7Proxy: true
hubble:
  metrics:
    enabled: [dns, drop, tcp, flow, httpV2]
```

并给目标命名空间加 visibility 注解或 L7 策略。会增加 Envoy 内存/延迟。

### 7.3 全量 Cilium（下一窗口）

使用已准备的：

```text
/root/cilium-migration-20261108/values-full-cni.yaml
/root/cilium-migration-20261108/values-full-kubeproxy.yaml
```

流程：

1. 删除 Calico（先备份 IPPool/Felix/CNI）。
2. 安装 Cilium，`kubeProxyReplacement=false`，`ipam.mode=kubernetes`，native routing。
3. 全量 Pod 重建。
4. 验证 DNS/Ingress/Ceph/Kafka/CNPG/Tekton。
5. 第二窗口切换 kube-proxy replacement。

**前置条件：**

- Cilium chaining 稳定运行 1–2 周；
- 42 个 hostNetwork、18 个 NetworkPolicy、Ceph/Kafka/CNPG/Tekton/MetalLB/kube-vip 验证通过；
- 回滚演练完成。

---

## 8. 产物

```text
/root/cilium-migration-20261108/
├── values-chaining.yaml
├── values-chaining-retry.yaml
├── values-full-cni.yaml
├── values-full-kubeproxy.yaml
├── chaining-configmap.yaml
├── rendered-chaining.yaml
├── rendered-full.yaml
├── kube-proxy-ds-backup.yaml
├── kube-proxy-cm-backup.yaml
├── 10-calico.conflist.m01
├── prepull-images.txt
└── prepull-*.log

/root/calico-cilium-migration-window-20261108/
├── cilium-install.log
├── cilium-install-retry.log
├── cilium-upgrade-cleanstate.log
├── cilium-uninstall.log
├── cilium-pilot.log
└── ...
```

## 9. 参考

- Cilium 1.20 System Requirements：<https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium Kubernetes Compatibility：<https://docs.cilium.io/en/stable/network/kubernetes/compatibility/>
- Cilium CNI Chaining on Calico：<https://docs.cilium.io/en/stable/installation/cni-chaining-calico/>
- Cilium Hubble：<https://docs.cilium.io/en/stable/observability/hubble/>
- Calico IP autodetection：<https://docs.tigera.io/calico/latest/reference/node/configuration>
- Calico BGP：<https://docs.tigera.io/calico/latest/networking/configuring/bgp>

---

**报告结束。**
