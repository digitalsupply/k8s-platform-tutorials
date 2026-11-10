# MetalLB Speaker → Cilium L2 Announcements 执行报告

> 日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> Cilium：1.20.4（KPR=True，Host BPF，BPF masquerade，Native routing）  
> MetalLB：v0.13.12（L2 模式）  
> 变更范围：**只替换 MetalLB Speaker 的 L2 宣告功能**；MetalLB Controller / IPAM 保留  
> 结果：✅ 成功，Traefik VIP `10.0.0.252` 保持可用，宣告节点/MAC 未变化

---

## 1. 目标与边界

### 目标

把 `10.0.0.252` 的 ARP/NDP 宣告从 MetalLB Speaker 切到 Cilium Agent，同时：

- 保留 MetalLB Controller 继续做 LB IPAM；
- 保持 VIP 不变；
- 保持宣告节点仍为 `worker03`，避免 ARP/MAC 变化；
- 不引入 eth1，不改变现有 Cilium 数据面配置；
- 可快速回滚。

### 明确不做

| 不做的事 | 原因 |
|---|---|
| 启用 Cilium LB IPAM | 本次只替换 speaker，IPAM 仍由 MetalLB 负责 |
| 删除 MetalLB Controller | 保留作为回滚路径和 IP 分配来源 |
| 把 eth1 加入 Cilium `devices` | 唯一 LB Service 是 Traefik `10.0.0.252`，外部走 `10.0.0.0/24` 的 eth0；`172.16.1.220-250` 无 Service 使用 |
| 开启 DSR / XDP / Maglev / L7 | 与本次替换无关，保持现状 |
| 强制 VIP failover 演练 | 会产生 10–20s 入口中断；本次只验证其他节点已参与选主（见 §6） |

---

## 2. 变更前状态

### MetalLB

```text
metallb-system/
├── controller-684cd67747-qzrtw   1/1 Running   worker01
└── speaker × 6                  1/1 Running   每节点一个
```

```text
metallb_speaker_announced{ip="10.0.0.252",node="worker03",protocol="layer2",service="traefik/traefik"} 1
```

即：`10.0.0.252` 由 **worker03** 宣告。

### Cilium

```text
KubeProxyReplacement: True
Host Routing:         BPF
Masquerading:         BPF
Routing:              Native
devices:              eth0
enableLBIPAM:         false
defaultLBServiceIPAM: none
l2announcements:      未启用
```

### Traefik Service

```text
NAME      TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)
traefik   LoadBalancer   10.111.240.160   10.0.0.252    80:30156/TCP,443:30306/TCP
```

```yaml
externalTrafficPolicy: Cluster
annotations:
  metallb.universe.tf/address-pool: lb-pool-tailscale
  metallb.universe.tf/loadBalancerIPs: "10.0.0.252"
```

### 备份

全部保存在 `/root/metallb-speaker-to-cilium-l2-20261109/`：

```text
speaker-ds-backup.yaml        MetalLB speaker DaemonSet 备份
controller-backup.yaml        MetalLB controller Deployment 备份
metallb-config-backup.yaml    IPAddressPool / L2Advertisement 备份
traefik-svc-backup.yaml       Traefik Service 备份
cilium-values-before.yaml     Cilium Helm values（变更前）
leases-before.txt             变更前 Lease 快照
```

---

## 3. 执行步骤

### 3.1 启用 Cilium L2 Announcements

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system --skip-crds --reuse-values \
  --set l2announcements.enabled=true
```

结果：

```text
Release "cilium" has been upgraded.
REVISION: 4
```

但随后在 agent 日志中发现配置漂移：

```text
level=warn msg="Mismatch found" module=agent.controlplane.config-drift-checker \
  key=enable-l2-announcements actual=false expectedValue=true
```

说明 ConfigMap 已更新，但 agent 未重新加载。执行：

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=420s
```

结果：

```text
daemon set "cilium" successfully rolled out
6/6 Running
```

Cilium L2 组件确认：

```text
l2-announcer
  job-l2-announcer-run                  [OK] Running
  timer-job-l2-announcer-lease-gc       [OK]
l2-responder
  job-l2-responder-reconciler           [OK] Running
```

ConfigMap：

```text
enable-l2-announcements=true
```

### 3.2 先创建“匹配不到任何 Service”的 L2 Policy

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: traefik-l2
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: worker03
  interfaces:
    - ^eth0$
  loadBalancerIPs: true
  externalIPs: false
  serviceSelector:
    matchLabels:
      cilium-l2-enabled: "no-match-yet"
```

```bash
kubectl apply -f /root/metallb-speaker-to-cilium-l2-20261109/cilium-l2-policy.yaml
```

验证：

```text
ciliuml2announcementpolicy.cilium.io/traefik-l2 created
kubectl get ciliuml2announcementpolicies
NAME         AGE
traefik-l2   5s

kubectl -n kube-system get lease | grep cilium-l2
(no cilium l2 lease yet - expected)
```

此时 MetalLB 仍在宣告，VIP 正常：

```text
curl -H 'Host: studyfree.xyz' http://10.0.0.252/  -> 200
```

### 3.3 停掉 MetalLB Speaker，保留 DaemonSet

没有删除 DS，而是给它加一个不匹配任何节点的 `nodeSelector`，这样：

- 所有 speaker Pod 立即退出；
- DaemonSet 对象、配置、历史都保留；
- 回滚只需要删掉这个 label。

```bash
kubectl -n metallb-system patch ds speaker --type=merge -p '{
  "spec":{"template":{"spec":{"nodeSelector":{
    "kubernetes.io/os":"linux",
    "metallb.io/announcer-disabled":"true"
  }}}}
}'
```

结果：

```text
daemonset.apps/speaker patched
speaker pods: 6 -> 0
```

剩余：

```text
controller-684cd67747-qzrtw   1/1 Running   worker01
```

说明：**只停 speaker，controller 继续运行并持有 IP 分配。**

此时 VIP 仍然返回 200（依赖本机/上游 ARP 缓存短时间未过期）：

```text
code=200 time=0.005173
```

这正是无中断切换的窗口期：宣告者刚刚消失，客户端 ARP 缓存仍指向 worker03 的 MAC。

### 3.4 切换到 Traefik 选择器

第一次用 `merge` patch 时，`matchLabels` 被合并而不是替换，旧标签残留：

```yaml
serviceSelector:
  matchLabels:
    cilium-l2-enabled: no-match-yet      # 残留
    io.kubernetes.service.namespace: traefik
```

这会导致策略仍然匹配不到 Service。改用 JSON patch 整体替换：

```bash
kubectl patch ciliuml2announcementpolicy traefik-l2 --type=json -p '[
  {"op":"replace","path":"/spec/serviceSelector","value":{
    "matchLabels":{"io.kubernetes.service.namespace":"traefik"}
  }}
]'
```

`io.kubernetes.service.namespace` 是 Cilium L2 的保留选择器，按 Service 所在命名空间匹配，不依赖 Service 上真实存在的 label。

结果（约 15 秒内）：

```text
kubectl -n kube-system get lease | grep cilium-l2
cilium-l2announce-traefik-traefik   worker03   15s
```

Lease 被 **worker03** 拿到，与 MetalLB 原来的宣告节点一致。

```yaml
spec:
  holderIdentity: worker03
  leaseDurationSeconds: 15
  leaseTransitions: 0
```

### 3.5 放宽 nodeSelector 到所有 worker

为了让 VIP 在 worker03 故障时有迁移能力（MetalLB 原来也是全节点候选），把策略从“只允许 worker03”放宽为“所有非 control-plane 节点”：

```bash
kubectl patch ciliuml2announcementpolicy traefik-l2 --type=json -p '[
  {"op":"replace","path":"/spec/nodeSelector","value":{
    "matchExpressions":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}
    ]
  }}
]'
```

验证 Lease 没有漂移：

```text
holderIdentity=worker03 transitions=0 renewTime=2026-11-09T02:15:26Z
```

原因：Cilium L2 的 Lease 是“先到先得”，worker03 已经持有 Lease，其他节点只是成为候选，不会抢占。

其他节点已经参与选主（日志证据）：

```text
worker01: Attempting to acquire leader lease... lock=kube-system/cilium-l2announce-traefik-traefik
worker02: Attempting to acquire leader lease... lock=kube-system/cilium-l2announce-traefik-traefik
```

---

## 4. 验证结果

### 4.1 服务可用性

| 测试 | 结果 |
|---|---|
| `curl -H 'Host: studyfree.xyz' http://10.0.0.252/` | `200` |
| `curl -k -H 'Host: studyfree.xyz' https://10.0.0.252/` | `200` |
| `curl -H 'Host: studyfree.xyz' http://10.0.0.124:30156/`（NodePort） | `200` |
| Traefik Service `EXTERNAL-IP` | 仍为 `10.0.0.252` |
| MetalLB controller | `1/1 Running` |

### 4.2 ARP / MAC 一致性（关键）

清空 ARP 后重新探测：

```text
ip neigh flush 10.0.0.252
ping -c1 10.0.0.252
ip neigh show 10.0.0.252
10.0.0.252 dev eth0 lladdr bc:24:11:b2:36:91 REACHABLE

ip neigh show 10.0.0.124        # worker03 节点 IP
10.0.0.124 dev eth0 lladdr bc:24:11:b2:36:91 REACHABLE
```

worker03 的 eth0 MAC：

```text
bc:24:11:b2:36:91
```

结论：**VIP 的 MAC 仍然等于 worker03 的 MAC，客户端看到的二层地址没有变化**，因此切换对上游交换机/客户端的 ARP 缓存影响最小。

### 4.3 VIP 不再绑定到网卡

MetalLB L2 会把 VIP 加到 leader 节点网卡上；Cilium L2 不这样做，而是用 BPF 直接应答 ARP。worker03 上：

```text
eth0   UP   10.0.0.124/24
eth1   UP   172.16.1.124/16
```

`10.0.0.252` 没有出现在任何网卡上，但 ARP 能正确应答，说明宣告来自 Cilium eBPF 数据面。

### 4.4 数据面转发

worker01 上 Hubble 观测到发往 Traefik 的流量：

```text
10.0.0.61:41998 -> traefik/traefik-...:8000  FORWARDED
```

源 IP 保持 `10.0.0.61`（m01），说明在 `externalTrafficPolicy: Cluster` 下该路径没有发生额外的源地址改写（同二层、对称回程）。

### 4.5 集群健康

```text
6/6 节点 Ready
Cilium 6/6 Running，Controller Status 68/68 healthy
Cilium: Ok 1.20.4
KubeProxyReplacement: True [eth0 10.0.0.124 (Direct Routing)]
Routing: Native / Host: BPF
Masquerading: BPF
```

> 备注：`monitoring/prometheus-prometheus-prometheus-0` 当时处于 `Init:0/1`，原因是该工作负载正在做 Ceph RBD 存储迁移（新建了 `ceph-rbd-sc` PVC，并出现过 `prometheus-data-migrate2` Pod），与本次 MetalLB/Cilium 变更无关。未做处理。

---

## 5. 变更前后对比

### 5.1 组件与资源

| 项目 | 变更前 | 变更后 |
|---|---|---|
| MetalLB controller | 1 Pod | 1 Pod（保留） |
| MetalLB speaker | 6 Pod | 0 Pod（DS 保留，nodeSelector 禁用） |
| 宣告组件 | MetalLB speaker | Cilium agent（复用） |
| 选主机制 | memberlist（7946/TCP+UDP） | Kubernetes Lease |
| 额外端口 | 7946/TCP+UDP、7472 | 无 |
| Pod 总数 | 140 | 134 |
| MetalLB 资源 | controller 2m/82Mi + speaker 约 33m/180Mi | controller 2m/82Mi |
| Cilium agent | 28–152m / 145–251Mi | 31–111m / 123–247Mi（无显著增加） |

### 5.2 行为差异

| 维度 | MetalLB Speaker | Cilium L2 |
|---|---|---|
| VIP 是否加到网卡 | 是（leader 节点 eth0） | 否（BPF 应答 ARP/NDP） |
| 选主 | memberlist | Kubernetes Lease |
| failover 默认时间 | 秒级（取决于 memberlist/心跳） | 10–20s（Lease 15/5/2s） |
| `externalTrafficPolicy: Local` | 可用但需谨慎 | **明确不兼容** |
| 可观测性 | MetalLB metrics | Cilium metrics / Hubble / Lease 事件 |
| 成熟度 | 成熟 | Beta |
| IPAM | MetalLB controller | 仍由 MetalLB controller 负责 |

### 5.3 关键结论

- VIP 与 MAC 未变，客户端无感。
- MetalLB 的 IP 分配职责完全保留，因此不存在 VIP 被重新分配的风险。
- Cilium 只接管“二层宣告”这一层，数据面 DNAT 本来就已经在 Cilium BPF 中。
- 不再需要 memberlist 和 6 个 speaker Pod。

---

## 6. 高可用状态说明

当前 Lease：

```text
cilium-l2announce-traefik-traefik   worker03
```

策略已放宽到 worker01/worker02/worker03，因此：

- worker03 正常时：由 worker03 宣告（保持原 MAC）；
- worker03 故障时：Lease 过期后由 worker01 或 worker02 接管，预计 **10–20 秒**入口中断；
- 不会自动“负载均衡”：同一时刻只有一个节点应答 ARP（L2 模式固有特性）。

### 未执行 failover 演练

原因：会真实产生 10–20 秒入口不可用，且当前 Traefik 单副本，演练价值有限（VIP 迁移 ≠ 应用高可用）。已通过其他节点的 Lease 竞选日志验证“候选就绪”。

如需演练，建议在维护窗口执行：

```bash
# 记录当前 holder
kubectl -n kube-system get lease cilium-l2announce-traefik-traefik \
  -o jsonpath='{.spec.holderIdentity}'

# 方式一：停止 worker03 上的 cilium agent（会短暂影响该节点网络）
kubectl -n kube-system delete pod <worker03-cilium-pod>

# 方式二：临时把 worker03 cordon 并驱逐 Traefik/cilium（更重）

# 观察新 holder 与 ARP
watch -n1 "kubectl -n kube-system get lease cilium-l2announce-traefik-traefik \
  -o jsonpath='{.spec.holderIdentity}{\"\n\"}'"
ip neigh show 10.0.0.252
```

---

## 7. 回滚方案

### 7.1 立即回滚到 MetalLB Speaker（推荐，约 30 秒）

原则：**先关闭 Cilium 宣告，再恢复 MetalLB speaker**，避免同一个 VIP 被两个组件同时宣告。

```bash
# 1) 让 Cilium 停止宣告（删除策略即可）
kubectl delete ciliuml2announcementpolicy traefik-l2

# 2) 恢复 MetalLB speaker
kubectl -n metallb-system patch ds speaker --type=json -p '[
  {"op":"remove","path":"/spec/template/spec/nodeSelector/metallb.io/announcer-disabled"}
]'

# 3) 等待 speaker 就绪
kubectl -n metallb-system rollout status ds/speaker --timeout=180s

# 4) 验证
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: studyfree.xyz' http://10.0.0.252/
curl -s http://10.0.0.124:7472/metrics | grep metallb_speaker_announced | grep 10.0.0.252
kubectl -n kube-system get lease | grep cilium-l2   # 应无输出
```

如果 DaemonSet 已被误删：

```bash
kubectl apply -f /root/metallb-speaker-to-cilium-l2-20261109/speaker-ds-backup.yaml
```

### 7.2 只回滚节点范围

如果只是想把宣告固定回 worker03：

```bash
kubectl patch ciliuml2announcementpolicy traefik-l2 --type=json -p '[
  {"op":"replace","path":"/spec/nodeSelector","value":{
    "matchLabels":{"kubernetes.io/hostname":"worker03"}
  }}
]'
```

### 7.3 回滚 Cilium 的 L2 开关

仅在确定不再使用 Cilium L2 时执行：

```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium --version 1.20.4 \
  -n kube-system --skip-crds --reuse-values \
  --set l2announcements.enabled=false

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=420s
```

注意：关掉开关后如果策略还在，不会宣告；恢复时同样需要重启 DS 以消除 config drift。

---

## 8. 已知限制与风险

1. **Cilium L2 Announcements 是 Beta**：升级 Cilium 时需要回归验证 ARP/Lease 行为。
2. **`externalTrafficPolicy: Local` 不兼容**：当前 Traefik 是 `Cluster`。若未来改用 `Local`（例如为了保留客户端源 IP），Cilium L2 会把 VIP 宣告到没有 backend 的节点，导致丢流量。届时需要：
   - 保持 `Cluster`；或
   - 改用 BGP/NodePort；或
   - 保证每个候选节点都有 Traefik 副本。
3. **failover 10–20 秒**：默认 Lease `15s/5s/2s`。可以调短：
   ```yaml
   l2announcements:
     leaseDuration: 3s
     leaseRenewDeadline: 1s
     leaseRetryPeriod: 200ms
   ```
   但会增加 API/Lease 压力，多 Service 时要评估 `k8sClientRateLimit`。
4. **Traefik 单副本**：VIP 高可用不等于应用高可用。建议 Traefik 至少 2 副本 + 反亲和，才有实际故障切换意义。
5. **Lease/API 负载**：每个被宣告的 Service 对应一个 Lease。当前只有 1 个，压力可忽略；未来 Service 增多时需要调 QPS/burst。
6. **`devices` 仍然只有 eth0**：这是有意为之。若未来要使用 `172.16.1.220-250` 的 eth1 VIP，才需要：
   ```yaml
   devices: eth0,eth1
   ```
   并在策略里加 `^eth1$`，同时验证 NodePort 暴露面。
7. **ARN/NDP 缓存**：切换瞬间依赖客户端 ARP 缓存自然过期；本次因节点/MAC 未变，影响最小。若未来更换宣告节点，可能出现短时黑洞。

---

## 9. 后续建议

| 优先级 | 建议 | 说明 |
|---|---|---|
| 高 | 给 Traefik 增加副本 + 反亲和 | 让 VIP failover 真正有意义 |
| 中 | 观察 1–2 周 Lease/agent 日志 | 确认 Beta 功能稳定 |
| 中 | 把 Cilium L2 纳入监控 | Lease 持有者变化、`cilium_*` agent 健康、VIP 探活 |
| 低 | 评估 Cilium LB IPAM | 若目标是彻底移除 MetalLB，再做第二步 |
| 低 | 调短 Lease 参数 | 当前 1 个 VIP，可考虑 3s/1s/200ms |
| 低 | failover 演练 | 维护窗口执行，记录恢复时间 |

### 监控建议

```promql
# Cilium agent 健康
up{job="cilium-agent"} == 0

# Hubble drop 突增
rate(hubble_drop_total[5m]) > 0

# VIP 探活（黑盒）
probe_success{instance="10.0.0.252"} == 0
```

外加：

```bash
kubectl -n kube-system get lease cilium-l2announce-traefik-traefik
```

Lease 的 `holderIdentity` 变化就是一次真实的 VIP 迁移事件，应该告警。

---

## 10. 附录：最终配置

### 10.1 CiliumL2AnnouncementPolicy

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: traefik-l2
spec:
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  interfaces:
    - ^eth0$
  loadBalancerIPs: true
  externalIPs: false
  serviceSelector:
    matchLabels:
      io.kubernetes.service.namespace: traefik
```

文件：`/root/metallb-speaker-to-cilium-l2-20261109/cilium-l2-policy.yaml`

### 10.2 MetalLB Speaker 当前状态

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
        metallb.io/announcer-disabled: "true"   # 本次新增，用于停用 speaker
```

```text
DESIRED=0 CURRENT=0 READY=0
```

### 10.3 Cilium 关键配置

```text
l2announcements.enabled: true
devices: eth0
kubeProxyReplacement: "true"
enableLBIPAM: false
defaultLBServiceIPAM: none
l7Proxy: false
```

### 10.4 最终状态快照

```text
Nodes:                 6/6 Ready
Cilium:                 Ok 1.20.4, 6/6 Running, 68/68 controllers healthy
KubeProxyReplacement:   True [eth0 10.0.0.124 Direct Routing]
Routing:                Native / Host BPF
Masquerading:           BPF
L2 Lease:               cilium-l2announce-traefik-traefik -> worker03
Traefik VIP:            10.0.0.252, MAC bc:24:11:b2:36:91 (= worker03 eth0)
HTTP / HTTPS / NodePort: 200 / 200 / 200
MetalLB controller:     1/1 Running
MetalLB speaker:        0 Pods (DS 保留)
```

### 10.5 本次产物文件

```text
/root/metallb-speaker-to-cilium-l2-20261109/
├── speaker-ds-backup.yaml
├── controller-backup.yaml
├── metallb-config-backup.yaml
├── traefik-svc-backup.yaml
├── cilium-values-before.yaml
├── cilium-l2-policy.yaml
├── cilium-enable-l2.log
├── disable-speaker.log
├── switch-policy.log
├── broaden-policy.log
├── vip-before.txt
├── vip-gap.txt
├── hubble-traefik.txt
├── leases-before.txt
└── final-state.txt
```

相关分析文档：

- `/root/metallb-speaker-vs-cilium-l2-analysis-20261109.md`
- `/root/cilium-tutorial-basic-to-advanced-20261109.md`

---

## 11. GitOps 纳管（2026-11-09 完成）

变更已提交到 `platform-gitops`，commit `a52b63b`：

```text
feat(network): manage MetalLB controller-only and Cilium L2 announcement in GitOps
```

### 11.1 新增内容

```text
platform/network/
├── README.md
├── cilium/
│   ├── values.yaml                      # Cilium Helm values（l2announcements.enabled=true）
│   └── l2-policy/
│       └── l2-announcement-policy.yaml  # CiliumL2AnnouncementPolicy
└── metallb/
    ├── kustomization.yaml
    ├── metallb-native.yaml              # MetalLB v0.13.12 组件清单
    ├── pools.yaml                       # IPAddressPool + L2Advertisement
    └── speaker-disabled-patch.yaml      # speaker 固定为不可调度

clusters/prod/applications/
├── platform-metallb.yaml                # sync-wave -5
└── platform-cilium-l2.yaml              # sync-wave 0
```

### 11.2 接管结果

```text
platform-metallb      Synced  Healthy  rev=a52b63b
platform-cilium-l2    Synced  Healthy  rev=a52b63b
app-of-apps           Synced  Healthy  rev=a52b63b
```

- `kubectl diff` 对 MetalLB 渲染结果为零差异，首次同步没有改动任何字段。
- speaker 仍为 0 Pod，controller 仍为 1/1 Running。
- Lease holder 仍为 worker03，VIP HTTP/HTTPS 均 200。
- 漂移测试：手动修改 `spec.externalIPs` 和 `spec.revisionHistoryLimit`，ArgoCD 分别在 10s/20s 内自动改回。

### 11.3 顺序与回滚

- 同步顺序：`platform-metallb`（wave -5，先禁用 speaker）→ `platform-cilium-l2`（wave 0）。
- 回滚：先停 Cilium 宣告，再删除 `speaker-disabled-patch.yaml` 的 patch 并提交。
- 两个 Application 均为 `prune: false`，避免误删 CRD/策略导致 VIP 消失。
- Cilium 本身仍是手动 Helm（values 在 Git），与 `platform/monitoring` 模式一致。

### 11.4 注意

ArgoCD 不会把“额外 annotation”判为漂移，只对 spec 字段做 selfHeal；因此不要用 annotation 表达关键状态，关键期望状态必须写进 spec。
