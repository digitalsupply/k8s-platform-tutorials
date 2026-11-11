# 事故与变更案例（本环境）

对应教程：[`../../10-slo-incident-alerting.md`](../../10-slo-incident-alerting.md)。

## 案例 A：重启告警长期不恢复（2026-10-05 ~ 10-07）

来源：[`04-monitoring-gitops/notes/告警根因分析.md`](../../../04-monitoring-gitops/notes/告警根因分析.md)。

### 时间线

| 时间 | 事件 |
|---|---|
| 10-05 22:31–22:41 | 集群约 37 个工作负载批量重建；Kafka 晚就绪，Tempo block-builder/live-store/metrics-generator 连不上 Kafka，崩 4–5 次后自愈 |
| 10-06 15:31–16:01 | DNS/网络抖动 + liveness 路径错误；argocd-repo-server 12 次重启；query-frontend 被 liveness 反复杀死 |
| 10-07 07:35–08:40 | 第一轮人工处置：窗口化重启规则、调探针、补资源 |
| 10-07 08:45–09:40 | 第二轮：定位真根因（probe 路径 404、kube-proxy metrics bind、Loki job 名不匹配）并闭环 |

### 影响

- 告警 `KubePodHighRestartCount` / `Tempo3PodCrashLooping` 在 Pod 已恢复后仍 **FIRING 16h~1.5 天**；
- 值班被无效告警占用；真正根因（probe 路径）在第二轮才定位；
- 监控侧 kube-proxy target 全 0，`TargetDown` 长时间误报；
- Loki `LokiIngestStalled` 因 job 名正则不匹配，`absent()` 恒真，误报 2 天。

### 根因（5 Whys 摘要）

1. 为什么告警不恢复？规则用累计 `restarts_total`，计数不回退。
2. 为什么 Pod 一直重启？liveness 路径 `/metrics/healthz?full=true` 在 ArgoCD v3.2.4 无条件 404。
3. 为什么路径错？chart 仍是 v2 时代路径，升级后没校验。
4. 为什么没早发现？只看 Pod Running/告警名，没有验证探针实际 HTTP 码。
5. 为什么规则没兜底？缺少“窗口计数 + 可自愈”的规则评审。

### 行动项

| 行动 | Owner | 状态 |
|---|---|---|
| 重启规则改 `increase(...[10m/15m])` | SRE | 已完成 |
| repo-server liveness 改 `/healthz` | SRE | 已完成 |
| query-frontend liveness 改进程级 | SRE | 已完成 |
| kube-proxy metrics bind 0.0.0.0 | SRE | 已完成 |
| Loki job 正则加 namespace 前缀 | SRE | 已完成 |
| 告警规则评审加“可自愈/窗口”检查项 | SRE | 待固化 |

### MTTD / MTTA / MTTR

```text
MTTD（故障 -> 发现）：≥16h / 1.5d（告警一直 FIRING，但未被有效处理）
MTTA（发现 -> 认领）：无正式 on-call/ack 工具，无法量化
MTTR（故障 -> 恢复）：人工处置约 2h05m（07:35–09:40）
```

结论：这起案例的主要问题不是 MTTR，而是 **MTTD/告警可信度**。

## 案例 B：监控存储迁移触发 Ceph full（2026-11-09）

来源：[`04-monitoring-gitops/notes/prometheus-nfs-to-ceph-migration-2026-11-09.md`](../../../04-monitoring-gitops/notes/prometheus-nfs-to-ceph-migration-2026-11-09.md)。

### 变更

Prometheus / Alertmanager / Grafana 从 NFS 迁移到 Ceph RBD（`ceph-rbd-sc`），同时创建新 PVC、复制数据、改 Helm values。

### 触发链

```text
3 副本 k8s-rbd + 42GiB 实际数据 = 127GiB 裸写入
  + 集群仅剩 47GiB 且分布不均
  + 迁移产生 6 个孤儿 RBD 镜像（含 19.3G 的算错名字 PVC）
  -> osd.2 先到 full ratio
  -> ceph df MAX AVAIL = 0
  -> 新 Pod FailedMount / MountDevice DeadlineExceeded
  -> worker02 RBD I/O 卡死，kubelet D 状态
  -> CNPG failover
  -> Grafana/ArgoCD Degraded
```

### 影响

- Prometheus / Alertmanager / Grafana 新 Pod 全部无法挂载；
- CNPG 主库 `pg16-ceph-4` 触发 failover 到 `pg16-ceph-3`；
- worker02 只能 `qm reset 123` 硬重启；
- 37 个 GrafanaDashboard 同步失败，`platform-grafana` Degraded。

### 恢复

- `rbd ls -l k8s-rbd` + `kubectl get pv` 对比，找出无 PV 引用的孤儿镜像；
- `rbd status` 确认 `Watchers: none` 后 `rbd rm`，共删除 6 个；
- 恢复后：

```text
HEALTH_OK
k8s-rbd STORED 21GiB USED 63GiB %USED 42.88 MAX AVAIL 28GiB
CNPG 2/2 healthy，primary=pg16-ceph-3
```

### 变更相关性

**直接由变更触发**：迁移前没有算清 3 副本放大、`MAX AVAIL`、孤儿镜像和 30% 余量。

### 行动项

| 行动 | Owner | 状态 |
|---|---|---|
| 迁移前检查 `ceph df` / `ceph osd df` / `MAX AVAIL` | Storage | 待固化 |
| 预留 ≥30% 裸容量 | Storage | 待固化 |
| 迁移前清理孤儿 RBD | Storage | 待固化 |
| 监控 `ceph_osd_nearfull_ratio` / `full_ratio` | SRE | 已有规则，需验证 |
| RBD 快照/备份策略 | Storage | 待办 |

## 变更与故障相关性（本仓库样本）

| 轮次 | 变更 | 结果 |
|---|---|---|
| 1 | CNPG 1.22 → 1.30.1 | rp_filter 导致全集群 webhook 超时；主库重启 3 分钟 |
| 2 | GitOps 覆盖盘点 | 只读，无故障 |
| 3 | P0 GitOps 落地 | 有 SSA/字段冲突，未造成用户故障 |
| 4 | Grafana Operator Stage A | Datasource 403、Dashboard 400、Operator 连接拒绝 |
| 5 | Sealed Secrets | 迁移成功，无用户故障 |
| 6 | Vault/ESO 可行性 | 只分析，无变更 |
| 7 | 监控存储 NFS → Ceph RBD | Ceph full、worker02 I/O 卡死、CNPG failover、Grafana/ArgoCD Degraded |
| 额外 | kube-proxy 升级 | metrics bind 变化，kube-proxy target 全 0，`KubeProxyDown` 长期误报 |

本样本：7 轮改造中 **3 轮**（CNPG、Grafana Operator、监控存储）直接触发故障/退化，
另有 kube-proxy 升级导致监控缺口，合计 4 次变更相关事件（3/7 = 43%）。  
行业常说“80% 故障来自变更”，本样本不足以证明精确比例，但方向一致：**变更是最需要被观测和回滚预案覆盖的风险源**。

> 结论：不要只统计“变更次数”，要统计“变更后 30–60 分钟内告警/错误率/延迟变化”，
> 把部署 marker 打到 Prometheus/Grafana，才能做相关性分析。
