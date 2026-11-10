# 集群诊断报告 - 2026-10-07

## kube-proxy nftables 切换结果

**结论：切换失败，已回滚到 iptables。**

- nftables v1.0.2 已安装（所有节点）
- kube-proxy v1.35.9 支持 nftables 模式
- 切换到 nftables 后：nft 规则集为空（0 条规则），Pod 网络不受影响但 kube-proxy 不生成 nft 规则
- 导致 Tempo3StorageBackendConnectFailing 告警触发（对象存储连接受影响）
- 已回滚：`--proxy-mode=iptables`，所有节点 iptables 规则恢复

## 集群状态总览

| 项目 | 状态 |
|---|---|
| 节点 | 6/6 Ready |
| kube-proxy | iptables（已恢复） |
| etcd | 3/3 Running，0 重启 |
| Calico | 6/6 Running |
| Tempo3 | 全部 Running，0 重启 |
| 当前告警 | Tempo3StorageBackendConnectFailing 已清除 |

## Pod 重启分析

### 重启次数 > 0 的 Pod

| 命名空间 | Pod | 重启 | 周期 | 原因 |
|---|---|---|---|---|
| metallb-system | speaker-zv64c | 64 | 263d | 节点重启累积 |
| metallb-system | speaker-7lsdm | 64 | 263d | 节点重启累积 |
| metallb-system | speaker-qmwd4 | 62 | 263d | 节点重启累积 |
| metallb-system | speaker-xz49v | 36 | 221d | 节点重启累积 |
| kafka | entity-operator | 14 | 23h | topic-operator liveness 失败 |
| kafka | strimzi-operator | 7 | 22h | HTTP 连接超时 |
| kube-system | calico-node-mqvkv | 5 | 4d8h | 未知 |
| kube-system | calico-node-qm2nb | 4 | 4d8h | 未知 |
| kube-system | kube-apiserver-m01 | 3 | 2d16h | etcd 连接错误 |
| logging | alloy-* (6个) | 2 各 | 6d22h | 未知 |
| knative-serving | activator | 1 | 39h | 未知 |
| monitoring | node-exporter-* | 1 各 | 4d21h | 未知 |

### 重点问题

1. **kafka entity-operator topic-operator** — liveness probe 失败（HTTP 500），readiness probe 超时（context deadline exceeded）。这是 14 次重启的根因。
2. **kube-apiserver-m01** — etcd 连接错误 `authentication handshake failed: context canceled`，可能与 nftables 尝试期间的网络中断有关。
3. **metallb speakers** — 64 次重启 / 263d，频率约 4 天/次，无错误日志，可能是节点维护导致。

## 告警准确性评估

### Tempo3StorageBackendConnectFailing

**规则逻辑：** `rate(tempo_ingest_storage_reader_connect_errors_total{namespace="logging",pod=~"tempo3-block-builder.*"}[5m]) > 0`

**问题：** Tempo3 block-builder 使用 emptyDir（无持久 trace block），不应连接对象存储。该告警对 block-builder 来说逻辑上不会触发（除非 block-builder 被错误配置）。当前未触发是因为 block-builder 实际未尝试连接对象存储。

**修复建议：** 从告警规则中排除 block-builder pod，或改为仅检查 backend-scheduler/backend-worker 的连接错误。

### 其他已修复的告警问题（来自之前分析）

- LokiIngestStalled：改为检查写入量而非仅 target 可达性
- metallb-system/speaker 重启：改用 `rate()` 窗口检测

## nftables vs iptables 影响评估

| 维度 | iptables | nftables |
|---|---|---|
| 规则生成 | 正常 | 本次未生效（内核 bug） |
| 性能 | 规则集较大，匹配较慢 | 理论上更快（合并规则） |
| 连接跟踪 | conntrack 正常 | 依赖 nftables conntrack 集成 |
| 回滚 | — | 已成功回滚 |
| 稳定性 | 生产验证通过 | 当前内核有已知 bug |

## 待办事项

1. **kafka entity-operator** — 检查 topic-operator 配置/资源限制，修复 liveness probe
2. **kube-apiserver-m01** — 观察 etcd 连接是否恢复，必要时重启
3. **metallb speakers** — 确认是否节点重启导致，无需紧急处理
4. **Tempo3StorageBackendConnectFailing 规则** — 排除 block-builder，避免误报
5. **nftables 内核 bug** — 内核升级或等待修复后再评估
