# 08 · Control Plane HA：kube-vip、apiserver 内存与 etcd

## 当时的情况

控制面是 3 个 stacked etcd 节点：

| 节点 | IP | 角色 |
|---|---|---|
| m01 | `10.0.0.61` | control-plane + etcd |
| master01 | `10.0.0.121` | control-plane + etcd |
| master02 | `10.0.0.120` | control-plane + etcd |

API VIP：`10.0.0.168:6443`，由 **kube-vip** 以 ARP 模式在 `eth0` 上宣告。

出现过三类问题：

1. **kube-vip 重启 157 次**（三个 Pod 分别 51/53/53 次），退出码 2，日志 `panic`；
2. **apiserver 内存差异巨大**：m01 850MiB，master01 1.66GiB，master02 1.55GiB；
3. **没有 etcd 备份**，误删 CRD/Namespace 或 etcd 损坏时无法恢复。

## 主要概念与原理

### 1. kube-vip 的职责

- 在控制面节点间选举 leader；
- leader 把 VIP 加到网卡并做 ARP/NDP 宣告；
- 通过 `plndr-cp-lock` Lease 维持领导权；
- 支持 ARP、BGP、DSR 等模式（本集群 ARP）。

### 2. 为什么 kube-vip 会 `panic`

kube-vip 在**丢失 leader 租约**时会主动 `panic` 退出（上游硬编码行为，升级版本也不会改变）。
默认还会 **删除 VIP**（`vip_preserve_on_leadership_loss=false`）。

如果此时 kubelet 正好通过这个 VIP 访问 apiserver，就会形成放大循环：

```text
API 卡顿 > 3s
  → kube-vip 判租约失败
  → 删除 VIP + panic 退出
  → m01 kubelet 失去 apiserver
  → 节点 NotReady
  → 更多组件重试，API 更卡
```

### 3. apiserver 内存由什么决定

apiserver 不是“泄漏”，内存主要来自：

- **watch 数**：每个客户端的长连接 watch 会缓存对象；
- **CRD/OpenAPI**：CRD 越多，OpenAPI v2 文档越大；
- **对象缓存**：Pod/Secret/ConfigMap/Event 等；
- **Go 堆/GC**：heap inuse、Go sys、RSS。

本集群 148 个 CRD、OpenAPI 13.3MB、Helm release secret 36 个（14.45MB），
master01/02 各有 600+ watch，m01 只有 72 个，所以内存差一倍。

### 4. etcd 的数据与备份

- kubeadm stacked etcd 数据目录：`/var/lib/etcd`；
- `member/snap/db` 是 bbolt 数据库，`member/wal` 是预写日志；
- 备份用 `etcdctl snapshot save`，恢复用 `etcdutl snapshot restore`；
- **不能直接复制运行中的数据目录**到另一台机器启动，会 member ID 冲突/脑裂；
- 快照包含集群/成员身份，恢复时要决定是否生成新 member ID。

> etcd 恢复会回退**整个集群状态**，不是单个 namespace；快照时间点、revision 差距与恢复演练
> 见 [09 三个不可逆](../09-incidents-and-readiness/10-three-irreversibles.md)。

### 5. 版本偏斜与静态 Pod

apiserver/controller-manager/scheduler/etcd 都是 static Pod，清单在
`/etc/kubernetes/manifests/`。升级 apiserver 实际是改镜像/参数，kubelet 检测文件变化后重建容器。

## 踩坑点

### 坑 1：把 kube-vip panic 当成 bug

`panic: [recovered, repanicked]`、`exitCode=2` 看起来像程序崩溃，实际是
“丢失租约 → 主动退出”的设计。升级到 v1.2.4 也不能消除 panic。

**真正要修的是**：不要让 VIP 消失、不要让 kubelet 依赖 VIP、给足选举超时和资源。

### 坑 2：`vip_preserve_on_leadership_loss=false`

默认值会在失去领导权时删除 VIP。对“kubelet 通过 VIP 访问 apiserver”的节点，
这等于拔掉自己的 API 通路。

**修复**：

```yaml
env:
  # 注意：kube-vip 从 env 读的是下划线全小写形式；`preserveVipOnLeadershipLoss`
  # 只是 CLI flag 名，写成 env 会被静默忽略（等于没开）。
  - name: vip_preserve_on_leadership_loss
    value: "true"
```

### 坑 3：选举超时太紧

原来 `5s/3s/1s`，API 只要卡 3 秒就判失败。调整为 `vip_leaseduration=15 / vip_renewdeadline=10 / vip_retryperiod=2`，
并给 kube-vip 配 requests/limits（本环境实际：`limits.memory=512Mi`，刻意不设 CPU limit），避免被节流。

### 坑 4：m01 的 kubelet 指向 VIP

这是最隐蔽的循环依赖。m01 的 kubelet 用 `10.0.0.168:6443`，而 VIP 由 m01 上的 kube-vip 宣告。
kube-vip 一重启，kubelet 就失联。

**修复（方案 A）**：把 worker/kubelet 的 API 入口改为本机 `127.0.0.1:6443`（控制面）
或直连某个稳定 apiserver；`admin.conf` 保留 VIP 供运维使用。
本集群最终把 m01 kubelet 改为 `127.0.0.1:6443`，master01/02 原本就指向本机 IP。

### 坑 5：`KubeVIPLeaderNotRenewing` 告警误报

告警表达式对 `kube_vip_leader_lease_renew_time` 做了错误的 `count` 聚合，
把“单 Pod 维度”的指标变成了全局判断，导致 VIP 正常时也报。

**修复**：去掉 `count` 聚合，恢复单 Pod 语义；并新增真正能区分“租约未更新”的检测。
修复后的规则见 `assets/kubevip-leader-notrenewing-FIXED.yaml`。

### 坑 6：apiserver 内存高就加内存

先看 watch 分布和 CRD/OpenAPI 体量。本集群 master01/02 的 watch 是 m01 的 8–9 倍，
盲目加内存只是掩盖不均衡。

**修复顺序**：清理无用 CRD/Helm 历史 → 减少 operator/watch → 再考虑加内存。

### 坑 7：删掉的 CRD 被 ArgoCD 自动建回来

清理 23 个 CRD 后，Traefik 的 ArgoCD Application 立刻把 21 个 Hub/Gateway CRD 重新创建。
**修复**：先改 GitOps 仓/Application 的 include/exclude，再删 CRD；否则白做。

### 坑 8：`--target-ram-mb` 在 1.35 已不存在

网上很多 apiserver 调优文章还在写 `--target-ram-mb`，1.35.9 里没有这个参数。
`--watch-cache-sizes` 的非零值也只表示“启用 watch cache”，不能调大小。

### 坑 9：etcd 快照没有验证

只执行 `snapshot save` 不够，要验证：

```bash
etcdutl snapshot status <snapshot>.db -w table
```

并定期做 restore 演练。快照文件 0 字节或损坏，等于没有备份。

### 坑 10：直接复制 `/var/lib/etcd`

运行中的 etcd 数据目录包含 member ID、cluster ID、WAL。直接复制到另一台机器启动，
可能出现相同 member ID 双写/脑裂。迁移要用 `snapshot save/restore`，或按官方成员变更流程。

## 修复关键

### 1. kube-vip 止血与根治

```yaml
# 关键配置（完整清单见 assets/kube-vip-ha-daemonset-FIXED.yaml）
env:
  - name: vip_arp
    value: "true"
  - name: vip_interface
    value: "eth0"
  - name: preserveVipOnLeadershipLoss
    value: "true"
  - name: cp_enable
    value: "true"
resources:
  requests: {cpu: 50m, memory: 64Mi}
  limits:   {cpu: 200m, memory: 128Mi}
```

然后：

1. 把 m01 kubelet 的 API 入口改为 `127.0.0.1:6443`；
2. 升级 kube-vip 到 v1.2.4（保留关键 env）；
3. 做故障注入：掐断 leader 的 API 通路，确认领导权转移且 VIP 不消失；
4. 修正告警表达式，确认不再误报。

### 2. apiserver 内存治理

1. 备份并清理未使用 CRD（先处理 ArgoCD 回滚）；
2. 清理 Helm release 历史 secret（36 → 22，14.45MB → 7.85MB）；
3. 滚动重启 apiserver（master01 → master02 → m01），观察 watch 重新分布；
4. 如果仍然高，再评估加内存/减少 operator watch。

> 滚动重启只能临时重置 watch 分布，**不能永久降低总内存**。

### 3. etcd 备份

当前已上线 CronJob `etcd-backup/etcd-snapshot`，每小时一次：

```bash
kubectl -n etcd-backup get cronjob etcd-snapshot
kubectl -n etcd-backup get jobs --sort-by=.metadata.creationTimestamp
```

备份产物应落到独立存储/S3，并定期验证：

```bash
etcdutl snapshot status <file>.db -w table
```

## 本目录文档

| 文档 | 内容 |
|---|---|
| [kube-vip-restart-rootcause-and-fix.md](notes/kube-vip-restart-rootcause-and-fix.md) | 157 次重启的根因链、两轮修复、故障注入验证 |
| [kubevip-leader-notrenewing-falsepositive-analysis-and-fix-20261006.md](notes/kubevip-leader-notrenewing-falsepositive-analysis-and-fix-20261006.md) | `KubeVIPLeaderNotRenewing` 误报分析与修复 |
| [kube-vip-apiserver-analysis.md](notes/kube-vip-apiserver-analysis.md) | 三套 kubeconfig、各节点实际访问的 apiserver |
| [kube-vip-planA-execution-report-20261012.md](notes/kube-vip-planA-execution-report-20261012.md) | worker kubelet 切换至 VIP 的执行报告 |
| [kube-vip-planA-complete-inventory-20261013.md](notes/kube-vip-planA-complete-inventory-20261013.md) | 方案 A 完整变更清单与现状 |
| [apiserver-memory-analysis-20261109.md](notes/apiserver-memory-analysis-20261109.md) | watch/CRD/OpenAPI/对象缓存与内存关系 |
| [apiserver-remediation-20261109/REPORT.md](notes/apiserver-remediation-20261109/REPORT.md) | CRD/Helm secret/滚动重启执行记录 |
| [k8s-etcd-data-and-migration.md](notes/k8s-etcd-data-and-migration.md) | etcd 数据目录、特性、快照/恢复/迁移指南 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/kube-vip-ha-daemonset-FIXED.yaml](assets/kube-vip-ha-daemonset-FIXED.yaml) | 修复后的 kube-vip DaemonSet（含 preserveVip、超时、资源） |
| [assets/kube-vip-ha-daemonset.yaml](assets/kube-vip-ha-daemonset.yaml) | 早期版本，用于对比 |
| [assets/kube-vip-ds-AFTER-p0.yaml](assets/kube-vip-ds-AFTER-p0.yaml) | P0 修复后的 DaemonSet |
| [scripts/planA-switch-worker.sh](scripts/planA-switch-worker.sh) | 把 worker/kubelet 的 API 入口切到 VIP 的脚本（含备份） |
| [scripts/restart-apiserver.sh](scripts/restart-apiserver.sh) | 逐台滚动重启 apiserver |
| [assets/etcd-snapshot-cronjob.yaml](assets/etcd-snapshot-cronjob.yaml) | 当前每小时 etcd 快照 CronJob |
| [assets/kubevip-leader-notrenewing-FIXED.yaml](assets/kubevip-leader-notrenewing-FIXED.yaml) | 修正后的告警规则 |

```bash
# 查看 VIP 与租约
kubectl -n kube-system get lease plndr-cp-lock -o yaml
kubectl -n kube-system get pods -l app=kube-vip-ds -o wide

# etcd 健康与快照
kubectl -n kube-system exec etcd-m01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health
```

> kube-vip 的故障注入会产生短暂 API 中断，必须在维护窗口做。
> etcd 恢复演练请在独立环境进行，不要在生产直接 `snapshot restore`。
