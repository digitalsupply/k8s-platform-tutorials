# MetalLB Speaker 与 Cilium L2 Announcement：平替可行性、收益与代价

> 评估日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点  
> 当前 CNI：Cilium 1.20.4（KubeProxyReplacement=True，Host BPF，Masquerading BPF）  
> 当前 LB：MetalLB v0.13.12，L2 模式  
> 当前 LoadBalancer Service：Traefik，VIP `10.0.0.252`

---

## 0. 结论先行

**有平替：Cilium 的 `LB IPAM` + `L2 Announcements`。**

但结论不是“马上换”：

| 维度 | 判断 |
|---|---|
| 功能平替 | ✅ 可以覆盖当前 MetalLB 的 L2 模式：IP 分配、ARP/NDP 宣告、VIP 漂移 |
| 技术可行性 | ✅ 高：当前 Cilium KPR 已开启，Traefik `externalTrafficPolicy: Cluster`，节点同二层 |
| 生产成熟度 | ⚠️ 中：Cilium L2 Announcements 仍是 **Beta**；MetalLB L2 更成熟 |
| 当前集群收益 | ⚠️ 中低：只减少 1 个 controller + 6 个 speaker（约 39m CPU / 260 MiB），但减少一个组件和 memberlist 端口 |
| 主要代价 | Cilium L2 Beta、VIP 切换窗口、默认 10–20s failover、`externalTrafficPolicy: Local` 不兼容；只有需要保留 eth1 的 VIP 时才要把 eth1 加入 Cilium devices |
| 推荐 | **当前不急于替换**；如果目标是组件收敛，建议分两步：先只替换 speaker（保留 MetalLB IPAM），再替换 LB IPAM |

**一句话：**

> Cilium 完全有能力平替 MetalLB Speaker 的 L2 宣告功能，但它是 Beta，且当前集群只有一个 Traefik VIP，收益主要是“少一个组件”，不是性能大幅提升。建议保留 MetalLB，或分阶段替换并做 VIP 故障演练。

---

## 1. MetalLB 的组成与 Speaker 的职责

当前 MetalLB：

```text
metallb-system/
├── controller-...       1 个 Pod
└── speaker-...          6 个 Pod（每节点一个 DaemonSet）
```

### 1.1 Controller

- watch `Service type=LoadBalancer`
- 从 `IPAddressPool` 分配 IP
- 写入 `status.loadBalancer.ingress`
- 管理池、服务选择器、冲突

### 1.2 Speaker（本次讨论重点）

当前是 **L2 模式**：

- 每个节点一个 speaker，hostNetwork。
- speaker 之间通过 **memberlist**（7946/TCP+UDP）组成集群。
- 每个 Service/VIP 选出一个 leader 节点。
- leader 节点：
  - 把 VIP 加入本机；
  - 响应 ARP/NDP；
  - 让外部流量到达本节点；
  - 由 kube-proxy/Cilium 把 VIP DNAT 到 backend。
- 非 leader 待命；leader 挂了重新选主。

**Speaker 不负责真正的负载均衡**，只负责“让 VIP 在二层可达”。L2 模式同一时刻只有一个节点响应 ARP。

当前配置：

```text
IPAddressPool:
  lb-pool-eth1       172.16.1.220-172.16.1.250
  lb-pool-tailscale  10.0.0.252-10.0.0.253

L2Advertisement:
  l2adv-eth1         interfaces: eth1
  l2adv-tailscale    interfaces: eth0, eth1

Traefik Service:
  metalb.universe.tf/address-pool: lb-pool-tailscale
  metalb.universe.tf/loadBalancerIPs: 10.0.0.252
  externalTrafficPolicy: Cluster
```

当前 speaker 状态：

```text
speaker-62nbr  master01  restarts 5
speaker-7lsdm  worker01  restarts 76
speaker-ngjvx  worker03  restarts 4   ← 当前宣告 10.0.0.252
speaker-qmwd4  worker02  restarts 66
speaker-vtcl8  m01       restarts 23
speaker-zv64c  master02  restarts 68
```

资源：

```text
6 × speaker：约 5–8m CPU / 29–31 MiB
controller：约 2m CPU / 82 MiB
合计：约 39m CPU / 260 MiB
```

---

## 2. Cilium 的对应能力

### 2.1 两个组件对应 MetalLB 的两个部分

| MetalLB | Cilium |
|---|---|
| Controller 分配 LB IP | **Cilium LB IPAM**（`CiliumLoadBalancerIPPool`） |
| Speaker L2 宣告 VIP | **Cilium L2 Announcements**（`CiliumL2AnnouncementPolicy`） |
| Speaker BGP 宣告 | **Cilium BGP Control Plane**（当前未启用） |
| memberlist 选主 | Kubernetes **Lease** 选主 |
| speaker 资源 | 复用 cilium-agent，无额外 DaemonSet |

### 2.2 Cilium L2 Announcements 是什么

Cilium agent 直接：

- 响应 ARP/NDP；
- 每个 Service/VIP 通过 Kubernetes Lease 选一个 leader 节点；
- leader 节点宣告 VIP；
- Cilium 的 Service LB 负责 DNAT 到 backend。

与 MetalLB L2 的相同点：

- 都是 L2 单活：同一时刻一个节点响应 ARP/NDP；
- 都不做“入口前负载均衡”；
- 都依赖底层二层可达。

不同点：

- MetalLB 用 memberlist；Cilium 用 Kubernetes Lease。
- Cilium 没有独立 speaker Pod，复用 cilium-agent。
- Cilium L2 是 **Beta**；MetalLB L2 是成熟功能。
- Cilium L2 可以与 Cilium LB IPAM、BGP Control Plane 组合。

### 2.3 Cilium L2 的前提

- **KubeProxyReplacement 必须开启**（当前已满足）。
- **所有宣告接口必须在 Cilium `devices` 中**。当前 Traefik VIP `10.0.0.252` 走 eth0，**只保留 `devices=eth0` 即可**；只有当你要保留 `172.16.1.220-250` 或明确要在 eth1 宣告 VIP 时，才需要加 `eth1`。
- **不支持 `externalTrafficPolicy: Local`**（当前 Traefik 是 `Cluster`，满足）。
- `CiliumL2AnnouncementPolicy` 是 `cilium.io/v2alpha1`（Beta）。
- 需要开启 `l2announcements.enabled=true`。
- 需要关注 API/Lease 负载，调节 `k8sClientRateLimit`。

---

## 3. 本集群可行性评估

### 3.1 满足的条件

| 条件 | 当前 |
|---|---|
| Cilium KPR | ✅ True |
| Host Routing | ✅ BPF |
| 节点同二层 | ✅ 10.0.0.0/24 |
| 接口 eth0/eth1 | ✅ |
| Traefik `externalTrafficPolicy` | ✅ Cluster |
| Cilium 版本 | 1.20.4，支持 L2 Announcements |
| 当前 LB Service 数量 | 只有 1 个（Traefik），迁移面小 |
| 当前 MetalLB 模式 | L2，无 BGP，平替路径简单 |

### 3.2 需要改变的点

1. Cilium `devices`：当前只有 Traefik `10.0.0.252`，保持 `eth0` 即可；若要保留 `172.16.1.220-250` 的 eth1 宣告，才改为 `eth0,eth1`。
2. 开启 `l2announcements.enabled=true`。
3. 决定 LB IPAM：
   - 若完全替换：`enableLBIPAM=true`、`defaultLBServiceIPAM=lbipam`；
   - 若只替换 speaker：保留 MetalLB controller，Cilium L2 只宣告 MetalLB 已分配的 status IP。
4. 迁移 Service 注解：
   - MetalLB 注解不会被 Cilium 识别；
   - 需要 `lbipam.cilium.io/ips: "10.0.0.252"` 固定 VIP。
5. 处理 `10.0.0.252` 的 VIP 连续性：
   - 切换 ARP 宣告者时可能有短暂中断；
   - 需要维护窗口和回滚。
6. 测试 `externalTrafficPolicy: Local`：
   - 当前不需要；未来若使用，Cilium L2 不兼容，应改用 BGP/NodePort。

### 3.3 关键限制

| 限制 | 影响 |
|---|---|
| L2 Announcements 是 Beta | 生产稳定性/升级风险高于 MetalLB |
| 默认 failover 10–20s | 比很多环境期望的秒级长；可调 lease 到 2–4s |
| 不支持 `externalTrafficPolicy: Local` | 当前 Cluster 可用；未来 Local 需改方案 |
| 无入口前负载均衡 | 与 MetalLB L2 相同；单节点接收全部 VIP 流量 |
| 需要 `devices` 包含所有宣告接口 | 当前 Traefik 只用 eth0，`devices=eth0` 即可；只有保留 eth1 VIP 才需加 eth1 |
| LB IPAM 池更新可能重分配 IP | 必须用 annotation 固定 VIP |
| LB IPAM/服务共享语义需验证 | MetalLB 的 `allow-shared-ip` 有明确支持；Cilium 需验证 |
| API/Lease 负载 | 每个 VIP 一个 Lease；大规模 Service 需调 QPS |

---

## 4. 收益分析

### 4.1 组件收敛

删除：

- MetalLB controller（1 Pod）
- MetalLB speaker（6 Pod）
- memberlist 7946/TCP+UDP
- MetalLB CRD/配置/监控对象

节省：

```text
约 39m CPU / 260 MiB
7 个 Pod
一个 DaemonSet
一个 controller
memberlist 端口/选主机制
```

Cilium L2 复用 cilium-agent，只增加少量 ARP/Lease/API 开销；LB IPAM 在 operator 内。

### 4.2 稳定性收益

当前 MetalLB speaker 重启次数较高：

```text
speaker-7lsdm 76
speaker-qmwd4 66
speaker-zv64c 68
speaker-vtcl8 23
```

可能原因：

- liveness `/metrics` 1s 超时；
- memberlist 抖动；
- 节点重启/资源压力；
- speaker 没有 requests/limits。

Cilium L2：

- 复用已经稳定运行的 cilium-agent；
- 用 Kubernetes Lease 选主；
- 少一个独立组件和 memberlist；
- 可统一 Cilium metrics/Hubble/告警。

但注意：Cilium L2 是 Beta，不能假设一定比 MetalLB 更稳；需要故障演练。

### 4.3 统一数据面

当前：

```text
外部 -> MetalLB speaker ARP -> 节点 -> Cilium BPF Service -> Traefik
```

替换后：

```text
外部 -> Cilium agent ARP/Lease -> 节点 -> Cilium BPF Service -> Traefik
```

好处：

- VIP 宣告和 Service DNAT 都由 Cilium 管理；
- 不再需要 MetalLB 与 Cilium kube-proxy replacement 的兼容性验证；
- 统一 CRD/监控/升级路径；
- 未来可用 Cilium BGP Control Plane 替代 L2。

### 4.4 未来扩展

- Cilium BGP Control Plane 可以做 BGP 宣告/ECMP；
- Cilium LB IPAM 可以统一管理 LB IP；
- Cilium Gateway API 可以进一步统一入口；
- 但这些都是后续，不是当前替换 speaker 的直接收益。

---

## 5. 代价与风险

### 5.1 Cilium L2 是 Beta

- MetalLB L2 是成熟稳定功能。
- Cilium L2 Announcements 从 1.14 起 Beta，1.20 仍 Beta。
- 需要关注升级/回归/lease 行为。
- 生产替换前必须做 VIP 故障演练。

### 5.2 VIP 切换窗口

- 从 MetalLB speaker 切到 Cilium L2，ARP 宣告者变化。
- ARP 缓存可能短时指向旧节点。
- 现有连接可能中断；新连接恢复。
- 需要维护窗口，不能让 MetalLB speaker 和 Cilium L2 同时宣告同一个 VIP（会 ARP 冲突/抖动）。

### 5.3 failover 时间

Cilium L2 默认：

```text
leaseDuration=15s
leaseRenewDeadline=5s
leaseRetryPeriod=2s
```

理论 failover：

```text
最短 10s，最长 20s
```

可调：

```yaml
l2announcements:
  leaseDuration: 3s
  leaseRenewDeadline: 1s
  leaseRetryPeriod: 200ms
```

变为约 2–4s，但增加 API/Lease 压力。当前 1 个 VIP 可以调短；未来多 Service 要评估 API 负载。

### 5.4 `externalTrafficPolicy: Local` 不兼容

Cilium L2 明确不兼容 `externalTrafficPolicy: Local`，可能把 VIP 宣告到没有 backend 的节点，导致流量丢弃。

当前 Traefik 是 `Cluster`，没问题；如果未来为了保留源 IP 改成 `Local`，Cilium L2 方案需要重新评估（BGP/NodePort/其他）。

### 5.5 `devices` 是否需要 eth1：取决于你要不要保留 eth1 的 VIP

当前 Cilium：

```yaml
devices: eth0
```

MetalLB 当前配置里有：

- `l2adv-eth1`：`172.16.1.220-250`，只走 eth1；
- `l2adv-tailscale`：`10.0.0.252-253`，配置了 eth0 + eth1。

但实际只有 **一个** LoadBalancer Service：Traefik，VIP `10.0.0.252`，外部访问通常走 `10.0.0.0/24` 的 eth0。`lb-pool-eth1` 当前没有被任何 Service 使用。

因此：

**情况 1：只保留 Traefik 10.0.0.252，且外部从 eth0 访问**

```yaml
devices: eth0
```

Cilium L2 policy 只写 `^eth0$` 就够了。**不需要加 eth1。**

**情况 2：要保留 172.16.1.220-250 的 eth1 VIP，或明确要求 10.0.0.252 同时在 eth1 宣告**

```yaml
devices: eth0,eth1
```

Cilium L2 policy interfaces 加 `^eth1$`。

注意：

- `devices` 也影响 NodePort/LB 的绑定接口；加 eth1 可能让 NodePort 在 eth1 也可达，需验证 `30156/30306`。
- eth1 如果是内部/不可外部访问的网络，就不应该为了“对齐 MetalLB 配置”而强行加 eth1。
- 当前 `lb-pool-eth1` 没有 LB Service 使用，可以直接从替换范围里去掉。

### 5.6 LB IPAM 迁移风险

如果同时替换 IPAM：

- Cilium 可能给 Traefik 分配新 IP，VIP 变化。
- 必须用：
  ```yaml
  metadata:
    annotations:
      lbipam.cilium.io/ips: "10.0.0.252"
  ```
  固定 VIP。
- 删除 MetalLB 注解或让 Cilium 忽略它们。
- 池更新可能导致重新分配（Cilium 文档有警告）。

### 5.7 功能语义差异

| MetalLB | Cilium |
|---|---|
| `autoAssign` | 无直接同名字段；用 `serviceSelector` 控制 |
| `avoidBuggyIPs` | 用 range/`allowFirstLastIPs` 控制 |
| `allow-shared-ip` | 需验证 Cilium LB IPAM 多 Service 共享 IP 行为 |
| BGP speaker | Cilium BGP Control Plane（需单独配置） |
| memberlist | Kubernetes Lease |
| speaker metrics | Cilium/LB IPAM metrics |
| `metallb.universe.tf/*` 注解 | `lbipam.cilium.io/ips`、`loadBalancerClass` |

当前只有 1 个 LB Service，所以 `autoAssign`/共享 IP 的影响很小；未来多 Service 需要逐项验证。

### 5.8 运维学习成本

- 新 CRD：`CiliumLoadBalancerIPPool`、`CiliumL2AnnouncementPolicy`。
- 新排障：
  ```bash
  kubectl get ciliumloadbalancerippools
  kubectl get ciliuml2announcementpolicies
  kubectl -n kube-system get lease | grep cilium-l2announce
  kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
  ```
- 旧 MetalLB dashboard/告警要替换。
- 需要 ARP/Lease 故障演练。

---

## 6. 两种迁移路径

### 路径 A：只替换 Speaker，保留 MetalLB IPAM（低风险）

思路：

1. 保留 MetalLB controller 负责分配 IP 和写 status。
2. 删除 MetalLB speaker（停止 MetalLB 宣告）。
3. 开启 Cilium L2 Announcements，让 Cilium agent 宣告 `status.loadBalancer.ingress` 中的 VIP。

优点：

- 不改 Traefik 的 IPAM/注解；
- VIP 仍是 `10.0.0.252`；
- 只替换 ARP/NDP 宣告者；
- 回滚只需恢复 MetalLB speaker DS。

步骤：

```bash
# 1. Cilium values
#    devices: eth0          # 只保留 Traefik 10.0.0.252，eth0 足够
#    l2announcements.enabled=true
#    k8sClientRateLimit.qps/burst 适当调大

# 2. 创建 L2 policy
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: metallb-l2-replacement
spec:
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  interfaces:
    - ^eth0$
    # 需要保留 eth1 VIP 时再加：
    # - ^eth1$
  externalIPs: false
  loadBalancerIPs: true
EOF

# 3. 停止 MetalLB speaker 宣告
kubectl -n metallb-system scale ds/speaker --replicas=0
# 如果 DS 不支持 scale，删除 DS 并保留 YAML 备份

# 4. 验证
kubectl -n kube-system get lease | grep cilium-l2announce
kubectl get ciliuml2announcementpolicies
curl -H 'Host: studyfree.xyz' http://10.0.0.252/
```

注意：

- 删除 speaker 后，MetalLB controller 仍分配 IP；Cilium L2 读取 status 宣告。
- 不要让 MetalLB speaker 与 Cilium L2 同时宣告同一个 VIP。
- 先备份 speaker DS。

### 路径 B：完整替换（Cilium LB IPAM + L2）

```bash
# 1. Cilium values
# enableLBIPAM: true
# defaultLBServiceIPAM: lbipam
# l2announcements.enabled: true
# devices: eth0          # 只保留 Traefik 10.0.0.252

# 2. 创建 Cilium IP Pool
#    当前只有 Traefik 使用 10.0.0.252；lb-pool-eth1 未被任何 Service 使用，
#    因此替换范围可以只保留 10.0.0.252-253。
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: metallb-replacement
spec:
  blocks:
    - start: 10.0.0.252
      stop: 10.0.0.253
    # 如果确实要保留 eth1 的 172.16.1.x VIP，再取消注释：
    # - start: 172.16.1.220
    #   stop: 172.16.1.250
EOF

# 3. 固定 Traefik VIP
kubectl -n traefik annotate svc traefik \
  lbipam.cilium.io/ips=10.0.0.252 --overwrite

# 4. 创建 L2 policy（同路径 A）

# 5. 删除 MetalLB speaker/controller
kubectl -n metallb-system delete ds speaker
kubectl -n metallb-system delete deploy controller
# 备份并删除 MetalLB CRD/配置

# 6. 验证
kubectl get ciliumloadbalancerippools
kubectl get ciliuml2announcementpolicies
kubectl -n kube-system get lease | grep cilium-l2announce
curl -H 'Host: studyfree.xyz' http://10.0.0.252/
```

优点：

- 彻底移除 MetalLB。
- 统一 Cilium LB IPAM + L2 + Service 数据面。
- 少 7 个 Pod、约 39m CPU / 260 MiB。

风险：

- VIP 切换窗口；
- Cilium L2 Beta；
- LB IPAM 池/注解/共享语义；
- `devices` 变更；
- 需要完整回滚方案。

---

## 7. 建议

### 当前集群的建议

**短期：保留 MetalLB。**

理由：

- 当前只有 1 个 LoadBalancer Service（Traefik）。
- MetalLB L2 成熟，当前功能正常。
- Cilium L2 是 Beta，替换收益主要是“少一个组件”，不是性能大幅提升。
- 当前 MetalLB speaker 重启高的问题，可以先通过：
  - 调整 liveness/readiness 超时（1s → 3s）；
  - 给 speaker 加 requests/limits；
  - 检查节点/网络；
  来处理。

### 如果目标是组件收敛

建议按 **路径 A → 路径 B**：

1. **先只替换 speaker**：
   - 保留 MetalLB controller/IPAM；
   - Cilium L2 宣告 MetalLB 分配的 VIP；
   - 验证 ARP、VIP 连续性、failover、回滚。
2. **再替换 LB IPAM**：
   - 创建 Cilium pool；
   - `lbipam.cilium.io/ips` 固定 Traefik VIP；
   - 删除 MetalLB controller/CRD；
   - 观察 1–2 周。

### 不建议

- 不要同时运行 MetalLB speaker 和 Cilium L2 宣告同一个 VIP。
- 不要在未验证 `externalTrafficPolicy: Local` 的情况下启用 Cilium L2。
- 不要直接改 `devices` 和 LB IPAM 而不做 NodePort/LB 回归。
- 不要忽略 Cilium L2 Beta 的升级/回归风险。

---

## 8. 验证清单

```bash
# Cilium L2
kubectl get ciliumloadbalancerippools
kubectl get ciliuml2announcementpolicies
kubectl -n kube-system get lease | grep cilium-l2announce
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

# VIP/ARP
ip neigh | grep 10.0.0.252
arping -I eth0 10.0.0.252
curl -H 'Host: studyfree.xyz' http://10.0.0.252/
curl -H 'Host: studyfree.xyz' http://<node-ip>:30156/

# 故障演练
# 找到 lease holder 节点，cordon/drain 或重启；验证 VIP 在 2–20s 内迁移
```

---

## 9. 总结

| 问题 | 回答 |
|---|---|
| 有平替吗？ | ✅ Cilium LB IPAM + L2 Announcements；BGP 模式则用 Cilium BGP Control Plane |
| 可行性 | ✅ 技术上可行；当前 KPR/Cluster 策略/同二层满足 |
| 成熟度 | ⚠️ Cilium L2 是 Beta；MetalLB L2 更成熟 |
| 收益 | 少 7 个 Pod、约 39m CPU / 260 MiB；统一 Cilium；减少 MetalLB memberlist/speaker 重启 |
| 代价 | Beta 风险、VIP 切换、默认 10–20s failover、Local 不兼容；只有保留 eth1 VIP 时才需要 devices 加 eth1；LB IPAM/注解迁移 |
| 当前建议 | 保留 MetalLB；如要收敛，先替换 speaker，再替换 LB IPAM |
| 不建议 | 同时宣告同一 VIP；未演练直接生产切换 |
