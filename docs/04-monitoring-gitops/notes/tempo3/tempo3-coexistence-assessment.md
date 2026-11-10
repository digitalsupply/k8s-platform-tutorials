# Tempo 3.x 与 Tempo 2.x 共存风险评估

> **评估时间**：2026-09-28 19:05 – 19:25 (CST)
> **评估范围**：release `tempo`（tempo-distributed 1.61.3 / Tempo **2.9.0**）与 release `tempo3`（tempo-distributed 3.7.0 / Tempo **3.0.3**），均在 ns `logging`
> **触发原因**：tempo3 P0 修复（§3 of `observability-phase2-fixes.md`）完成后，两套 Tempo 同时在线
> **评估方式**：全部结论基于线上实测，无推测

---

## 目录

- [0. 一句话结论](#0-一句话结论)
- [1. 技术冲突核对（逐项实测）](#1-技术冲突核对逐项实测)
- [2. 真正的 6 个问题](#2-真正的-6-个问题)
- [3. 共存期健康快照](#3-共存期健康快照)
- [4. 风险矩阵](#4-风险矩阵)
- [5. 处置建议](#5-处置建议)
- [6. 附录：核查命令](#6-附录核查命令)
- [7. 评估边界说明](#7-评估边界说明)
- [8. 自查修正记录](#8-自查修正记录)

---

## 0. 一句话结论

> **技术上不冲突，运营上严重浪费。**
>
> 两套 Tempo 在 release 名、Service、memberlist 集群、存储后端、memcached、Kafka topic 上**完全隔离**，没有任何资源争抢或数据串写。
> 但因为**流量入口仍指向旧栈**（OTel Collector exporter + Grafana Tempo 数据源，两处都是旧栈），tempo3 的 13 个 Pod、59 MiB 常驻内存目前是**纯空转** —— 它能收 span（已在 `observability-phase2-fixes.md` §3.7 端到端验证），却**一个真实 span 都收不到**。
>
> 共存的唯一"收益"是留了个随时可切的备件；代价是**双份资源占用 + 一份看不见摸不着的历史数据风险**。
>
> 建议：**要么尽快完成切换（准备工作约 30 分钟），要么把 tempo3 缩到最小规格**，不要让它长期以全量规格空转。
>
> ⚠️ 切换必须**成对改两处**（OTel Collector + Grafana 数据源 URL），只改一处会得到一个**无任何报错的空白 Trace 面板** —— 详见 §2.2。
>
> 📌 本文档 §2.2 的初稿结论经自查后被推翻并修正，过程记录在 [§8](#8-自查修正记录)。

---

## 1. 技术冲突核对（逐项实测）

### 1.1 隔离维度对照表

| 维度 | `tempo`（2.9.0） | `tempo3`（3.0.3） | 是否冲突 |
|---|---|---|:---:|
| Helm release 名 | `tempo` | `tempo3` | ✅ 独立 |
| chart / appVersion | 1.61.3 / **2.9.0** | 3.7.0 / **3.0.3** | ✅ 独立 |
| ConfigMap | `tempo-config` | `tempo3-config` | ✅ 独立 |
| Service 名前缀 | `tempo-*` | `tempo3-*` | ✅ 独立 |
| Service 数量 | 6 | 12 | ✅ 独立 ClusterIP |
| `storage.trace.backend` | **`local`** | **`s3`** | ✅ 完全不同的后端 |
| 本地路径 | `/var/tempo/traces` | `/var/tempo/traces`（仅放 WAL） | ✅ 不同 Pod |
| S3 bucket | 无（不用 S3） | `tempo-traces` | ✅ 不共享 |
| `memberlist.cluster_label` | **`tempo.logging`** | **`tempo3.logging`** | ✅ 两个独立 gossip 环 |
| `memberlist.bind_port` | 7946 | 7946 | ⚠️ 同端口，但 Pod IP 不同 + 独立 cluster_label，不串 |
| memcached 实例 | `tempo-memcached-0` | `tempo3-memcached-0` | ✅ 独立 StatefulSet |
| Kafka ingest | 无 | topic `tempo-traces` | ✅ 旧栈不碰 Kafka |
| `multitenancy_enabled` | `false` | `false` | ⚠️ 值相同，但后端不同，无影响 |
| `overrides` | `defaults:{}` | `defaults:{}` | ⚠️ 值相同，无害 |
| `block_retention` | 336h（chart 默认） | 48h（显式配置） | ⚠️ **不一致，见 §2.4** |
| NetworkPolicy | 无 | 无 | ✅ 不存在策略冲突 |
| ResourceQuota / LimitRange | 无 | 无 | ✅ 不存在 |
| PriorityClass | 未设置 | 未设置 | ✅ 不存在抢占 |

**核对结论**：**没有任何一项会导致跨栈干扰**。memberlist 虽共用 7946 端口，但 Pod IP 不同且 `cluster_label` 是两套独立标识，实际运行中两个 gossip 环互不可见（见 §3.3 实测）。

### 1.2 Kafka topic 全集群占用核对

`tempo-traces` 这个名字在集群里被两处使用，但**分属不同系统**：

```
logging/tempo3-config:tempo.yaml
    topic:  tempo-traces      ← Kafka topic（tempo3 ingest 用）
    bucket: tempo-traces      ← S3 bucket 名（同名字符串）
```

**没有其他组件使用 `tempo-traces` 这个 Kafka topic**（全集群 ConfigMap 扫描确认）。旧栈 `backend: local`，完全不接触 Kafka。

> ⚠️ **易混淆点**：同一个字符串 `tempo-traces` 既是 Kafka topic 又是 S3 桶名。技术上无冲突（不同存储系统），但排查问题时极易看错。tempo3 配置里两者相隔仅 4 行。

### 1.3 存储命名冲突检查

| 存储 | 名称 | 使用方 | 冲突 |
|---|---|---|:---:|
| S3 bucket | `tempo-traces` | tempo3 | ✅ |
| Kafka topic | `tempo-traces` | tempo3 | ✅ |
| emptyDir `data` | `/var/tempo/traces` | tempo 2.x（3 个 ingester） | ✅ Pod 隔离 |
| emptyDir `data` | `/var/tempo/traces` | tempo3（WAL 用） | ✅ Pod 隔离 |

> 虽然两栈的本地路径字符串相同（`/var/tempo/traces`），但它们在**不同 Pod 的不同 emptyDir** 里，物理上完全隔离。

---

## 2. 真正的 6 个问题

按严重程度排序。**没有 P0 级的技术故障，但有 P0 级的运营浪费**。

### 2.1 【P0】tempo3 正在纯空转 —— 13 Pod / 59 MiB 常驻却收不到任何数据

**根因**：OTel Collector 的 exporter 指向**旧栈**。

```
# OpenTelemetryCollector CR: opentelemetry/otel  (mode: deployment, 0.145.0)
exporters:
  otlp_grpc/tempo:
    endpoint: tempo-distributor.logging.svc.cluster.local:4317   ← 旧栈，不是 tempo3
    tls: { insecure: true }
service:
  pipelines:
    traces:
      exporters: [otlp_grpc/tempo, debug, spanmetrics]
```

ns `opentelemetry` 下有 **4 个历史遗留的 ConfigMap**（`otel-collector-089d9319` / `08becd12` / `718612e4` / `caf5b0c0`），每一个都指向 `tempo-distributor` 或 `tempo.logging`，**全部是旧栈**。生效的是 CR `otel`（174 天）。

**实测对照（决定性证据）**：

| 栈 | `tempo_distributor_spans_received_total` | 说明 |
|---|---:|---|
| `tempo-distributor`（旧） | **14** | 来自 OTel Collector 的真实流量 |
| `tempo3-distributor` | **1** | 只有我 18:52 注入的测试 span |

旧栈 distributor 日志中有 14 行 `received spans` 记录，与指标完全吻合。

**代价**：

| 项 | tempo3 | tempo（对照） |
|---|---:|---:|
| Pod 数 | **13** | 9 |
| 常驻内存（`kubectl top`） | **59 Mi** | 21 Mi |
| 实际利用率 | **0%** | 承载全部真实流量 |
| Kafka consumer 连接 | 活跃（`connects_total` 有值） | 无 Kafka |

> 💡 讽刺之处：tempo3 的 Kafka ingest 通道**完全正常**（consumer lag = 0，read 22 KB），只是**没有上游喂给它数据**。这正是 `observability-phase2-fixes.md` §3.7 端到端验证时需要手动注入 span 才能测通的原因。

**修复方式**（三选一，**都需要人工确认后再执行**）：

| 方案 | 动作 | 优点 | 缺点 |
|---|---|---|---|
| **A. 切流量**（推荐） | 把 CR `otel` 的 exporter endpoint 改成 `tempo3-distributor.logging.svc.cluster.local:4317` | tempo3 立刻有真实流量，验证迁移效果 | 旧栈停止接收新 trace |
| **B. 双写** | exporter 改成 `otlp_grpc/tempo3` + 保留 `otlp_grpc/tempo`，`exporters: [tempo3, tempo, debug, spanmetrics]` | 两套都有数据，可对比 | 两套都在跑，成本翻倍，且 Kafka 压力 ×2 |
| **C. 缩容等待** | tempo3 各 StatefulSet 缩到 1 副本 / Deployment 缩到 0，保留配置待切 | 省资源 | tempo3 更长时间不验证，风险累积 |

> ⚠️ **A 与 B 都必须同时改 Grafana 的 Tempo 数据源 URL**，否则 span 进了 tempo3 但 Grafana 仍查旧栈 → **面板静默空白、无报错**。完整成对修改清单见 §2.2，执行顺序见 §5 阶段一。

### 2.2 【P0】Grafana 的 Tempo 数据源指向**旧栈** —— 切了流量 Grafana 仍是空白

> ⚠️ **本节结论经过一次自查修正**：初稿误判为"Grafana 没有 Tempo 数据源"，实际是**有，但指向旧栈**。修正过程与证据见 [§8 自查修正记录](#8-自查修正记录)。

**实测（Grafana API 权威，非 provisioning 文件）**：

```
$ curl -K /tmp/.gfrc http://<grafana-clusterip>/api/datasources     → HTTP 200, 共 4 个

  id  name          type          url
  ──  ────────────  ────────────  ──────────────────────────────────────────────
   1  Prometheus    prometheus    http://prometheus-prometheus.monitoring:9090/
   2  Alertmanager  alertmanager  http://prometheus-alertmanager.monitoring:9093/
   3  loki          loki          http://loki-gateway.logging.svc.cluster.local
   4  tempo         tempo         http://tempo-query-frontend.logging.svc.cluster.local:3200
                                                        ^^^^^^^^^^^^^^^^^^^^^^^ 旧栈
```

**`tempo` 数据源（id=4）指向 `tempo-query-frontend`（旧栈），不是 `tempo3-query-frontend`。**

该数据源的关联配置（经确认不含任何凭据字段，可安全展示）：

```json
{
  "uid": "afia1p4xshn9cf",
  "pdcInjected": false,
  "tracesToLogsV2":  { "customQuery": false, "datasourceUid": "dfi90c2a1osn4c" },
  "tracesToMetrics": { "datasourceUid": "prometheus" }
}
```

**引用完整性核对（已验证）**：

| 引用 | 目标 uid | 实际数据源 | 结论 |
|---|---|---|:---:|
| `tracesToLogsV2.datasourceUid` | `dfi90c2a1osn4c` | `loki` (id=3) | ✅ 有效 |
| `tracesToMetrics.datasourceUid` | `prometheus` | `Prometheus` (id=1) | ✅ 有效 |

**为什么这比"没有数据源"更危险**：

- 若只改 OTel Collector（§2.1 方案 A）而**不**动这个数据源 → span 进 tempo3，Grafana 仍去查旧栈 → **Trace 面板一片空白，且无任何报错**（旧栈 `/api/echo` 返回 200，健康检查照样通过）
- 这与 §2.5 讨论的 `nameOverride` 静默失联属**同一类故障模式**：配置层错配，但运行层无告警
- 两栈 query-frontend **都健康**（实测 `/api/echo` 均 HTTP 200），所以**不能靠"服务是否可用"判断数据源指向对不对** —— 必须比对 URL 字符串

**切换时必须成对修改（缺一不可）**：

| # | 对象 | 从 | 到 |
|---|---|---|---|
| 1 | OTel Collector CR `otel` → `otlp_grpc/tempo.endpoint` | `tempo-distributor.logging.svc.cluster.local:4317` | `tempo3-distributor.logging.svc.cluster.local:4317` |
| 2 | Grafana 数据源 `tempo`（id=4）→ `url` | `http://tempo-query-frontend.logging.svc.cluster.local:3200` | `http://tempo3-query-frontend.logging.svc.cluster.local:3200` |

**tempo3 侧 Service 已就绪，无需新建**（实测）：

| Service | ClusterIP | 端口 | Endpoints | `/api/echo` |
|---|---|---|---|:---:|
| `tempo3-query-frontend` | 10.101.73.249 | 3200, 9095 | 10.244.19.122 | **200** |
| `tempo-query-frontend`（旧） | 10.97.117.176 | 3200, 9095 | 10.244.19.68 | **200** |

**附带发现（配置漂移，P2）**：4 个数据源里**只有 2 个由 provisioning 文件管理**（`Prometheus`、`Alertmanager`）；`loki` 与 `tempo` 是**运行时经 API 添加**的 —— `/etc/grafana/provisioning/datasources/` 目录下只有 `datasource.yaml` 一个文件。

后果：若将来重建 Grafana Pod 或重跑 provisioning 流程，`loki` 与 `tempo` 会**静默消失**，而 Prometheus/Alertmanager 会自动恢复。建议把这两个也纳入 provisioning 管理。

### 2.3 【P1】切换会丢失全部历史 trace

| 项 | 数据量 | 位置 | 持久性 |
|---|---:|---|---|
| 旧栈 3 个 ingester 本地 traces | 205.7 M + 212.0 M + 212.1 M = **约 620 MB** | `/var/tempo/traces` | ⚠️ **emptyDir，Pod 删除即丢** |
| 旧栈 WAL | 3 × 8.0 K | `/var/tempo/wal` | emptyDir |
| 旧栈 compactor traces | 4.0 K | `/var/tempo/traces` | emptyDir |
| tempo3 S3 桶 `tempo-traces` | 仅 1 个种子文件（2026-04-23，215 B） | Ceph RGW | 持久 |

**问题本质**：两栈数据在**完全不同的存储系统**里。tempo3 `backend: s3`，只读 S3 桶；旧栈 `backend: local`，数据在 Pod 本地盘。**tempo3 看不到旧栈的任何历史 trace。**

**更严重的是 emptyDir**：

```
tempo-ingester StatefulSet:
  volume data → emptyDir     ⚠️ 无 PVC
```

这意味着旧栈的历史 trace **本来就不耐重启**。127 次累计重启中，任何一次 ingester 重建都会丢掉它的本地 traces。存量 620 MB 是"侥幸保留至今"的结果。

> ⚠️ 如果执行 §2.1 方案 A/B 或 §5 的切换流程，**切之前不要删旧栈的 Pod**。旧栈一旦下线，620 MB 历史 trace 立即消失且无法恢复（除非现在就把 emptyDir 内容导出到 S3 桶）。

**建议**：若需要保留历史，先从 3 个 ingester 把 `/var/tempo/traces` 导出到 `tempo-traces` 桶的对应目录结构，再执行切换。**这需要人工确认**（涉及读旧栈数据 + 写 S3）。

### 2.4 【P1】旧栈自身不健康，不宜长期共存

| 指标 | 数值 |
|---|---|
| 累计重启次数 | **127**（compactor 19 / query-frontend 24 / 其余各 12） |
| 最近一次重启 | **2026-09-27 05:55**（约 36 小时前，9 个 Pod 几乎同时） |
| chart 版本 | 1.61.3（很旧） |
| Tempo 版本 | 2.9.0（2.x 已停止主线维护） |
| 当前状态 | 9/9 Running（此刻是好的） |

2026-09-27 05:55 那次**9 个 Pod 同时重启**（时间戳集中在 05:54:55 – 05:55:06），典型的**节点级事件**（节点重启 / kubelet 重启 / OOM），不是单组件 bug。

**判断**：旧栈能跑，但它是"随时可能再挂一次"的状态。长期共存等于把一份不稳定的历史数据源和一个稳定的新数据源摆在同一个 namespace 里，**运维时容易搞不清哪个是权威源**。

### 2.5 【P1】两套 Tempo 都只被 Prometheus 抓了 distributor 一个组件

**实测 Prometheus 抓取目标**：

```
job=tempo-distributor               10.244.30.113:3200    (旧栈)
job=tempo-distributor-discovery     10.244.30.113:3200    (旧栈)
job=tempo3-distributor              10.244.70.70:3200      (tempo3)  ← 竟被抓到了
job=tempo3-distributor-discovery    10.244.70.70:3200      (tempo3)
```

**注意这个"巧合"**：唯一的 ServiceMonitor 是 `monitoring/tempo-self-monitor`，其 selector 为：

```yaml
selector:
  matchLabels:
    app.kubernetes.io/component: distributor
    app.kubernetes.io/name: tempo            # ← 关键
namespaceSelector:
  matchNames: [logging]
```

而 tempo3 的 Pod label 恰好也是 `app.kubernetes.io/name: tempo`：

| label | tempo（2.x） | tempo3（3.x） |
|---|---|---|
| `app.kubernetes.io/component` | `distributor` | `distributor` |
| `app.kubernetes.io/name` | `tempo` | **`tempo`** ← 相同！ |
| `app.kubernetes.io/instance` | `tempo` | `tempo3` |
| `app.kubernetes.io/version` | `2.9.0` | `3.0.3` |

tempo3 只设了 `fullnameOverride: tempo3`（改资源名），**没有设 `nameOverride`**（改 label）。于是两栈的 Pod 撞了同一个 `app.kubernetes.io/name` 值，ServiceMonitor 一网打尽。

**这带来两个隐患**：

1. **脆弱**：任何人将来给 tempo3 加上 `nameOverride: tempo3`，`tempo-self-monitor` 会**静默漏掉 tempo3**，而 Prometheus 不会报任何错 —— 与本文档 §2.6 讨论的"静默失败"是同一类问题。
2. **覆盖不足**：**两套都只抓了 distributor**。querier / query-frontend / ingester / compactor / backend-scheduler / backend-worker / block-builder / live-store / metrics-generator **全部没有指标**。

**没有 Tempo 相关的 PrometheusRule**（全集群 36 条 PrometheusRule 中含 `tempo` 的：**0 条**）—— 所以 Tempo 崩了也不会告警。这解释了为什么 tempo3 CrashLoop 了 4 小时没人发现。

### 2.6 【P2】易混淆的命名

| 混淆源 | 说明 |
|---|---|
| `tempo-traces` | 既是 S3 桶名，又是 Kafka topic 名，配置里相隔 4 行 |
| `/var/tempo/traces` | 两栈本地路径字符串完全相同（不同 Pod，但看配置时容易看错） |
| `app.kubernetes.io/name=tempo` | tempo3 的 Pod 也带这个 label，与旧栈撞名 |
| `memberlist.bind_port=7946` | 两栈同端口同路径，靠 Pod IP + cluster_label 区分 |
| ns `logging` 下 21 个 Service | `tempo-*` 6 个 + `tempo3-*` 12 个 + 其他 |

---

## 3. 共存期健康快照

### 3.1 Pod 状态（2026-09-28 19:20 实测）

| 栈 | Pod 数 | Ready | CrashLoop | 累计重启 | 常驻内存 |
|---|---:|---:|---:|---:|---:|
| `tempo`（2.9.0） | 9 | 9/9 | **0** | 127 | 21 Mi |
| `tempo3`（3.0.3） | 13 | 13/13 | **0** | **0** | 59 Mi |
| 合计 | 22 | 22/22 | 0 | 127 | 80 Mi |

**tempo3 零重启**（18:45 升级至今），说明修复彻底。

### 3.2 Prometheus 可见性

```
tempo_build_info{version="v2.9.0"}   2 series
tempo_build_info{version="v3.0.3"}   2 series
```

两套的 build 信息都在 Prometheus 里（各 2 个 series，对应 distributor + distributor-discovery）。

### 3.3 memberlist 隔离性实证

两栈同用 7946 端口、同路径 `/var/tempo/traces`，但实际运行互不干扰：

| 项 | `tempo` | `tempo3` |
|---|---|---|
| `cluster_label` | `tempo.logging` | `tempo3.logging` |
| `join_members` | `dns+tempo-gossip-ring:7946` | `dns+tempo3-gossip-ring:7946` |
| 实际 Pod 成员 | 各自独立 | 各自独立 |

**没有任何一条日志出现跨栈 join 尝试**（tempo3 全部 13 个 Pod 日志已扫描归档）。

### 3.4 数据流现状

```
应用 → OTel Collector(4317/4318) → tempo-distributor(2.9.0)  ✅ 14 spans
应用 → OTel Collector(4317/4318) → tempo3-distributor(3.0.3)  ❌ 0 spans（无上游）
                                   tempo3 → Kafka tempo-traces ✅ 通道健康但无数据
                                   tempo3 → S3 tempo-traces  ✅ 通道健康但仅 1 个种子文件
```

---

## 4. 风险矩阵

| # | 风险 | 等级 | 概率 | 影响 | 当前状态 |
|---|---|:---:|:---:|---|---|
| 1 | tempo3 空转浪费 13 Pod / 59 Mi | **P0** | 100% | 资源浪费 | 已发生 |
| 2 | Grafana Tempo 数据源指向旧栈，切换后 Trace 面板静默空白 | **P0** | 100% | 迁移无法验收 | 已发生 |
| 3 | 切换后丢失 620 MB 历史 trace | **P1** | 取决于切换方式 | 历史不可查 | 未触发 |
| 4 | emptyDir 无持久化，旧栈重启即丢历史 | **P1** | 中 | 历史丢失 | 潜在 |
| 5 | 旧栈 127 次重启，不稳定 | **P1** | 中 | 随时可用性中断 | 已发生 |
| 6 | 两栈都只有 distributor 指标 | **P1** | 100% | 故障不可见 | 已发生 |
| 7 | 无 Tempo 告警规则 | **P1** | 100% | 故障 4 小时无人知 | 已发生 |
| 8 | `nameOverride` 变更会静默断监控 | **P2** | 低 | 监控失效 | 潜在 |
| 9 | `tempo-traces` 一名两用易看错 | **P2** | 中 | 排查绕路 | 已发生 |

**反过来说，共存"没有引入"的风险**：无端口冲突、无 Service 冲突、无 memberlist 串环、无数据串写、无网络策略冲突、无资源配额冲突。

---

## 5. 处置建议

分三阶段。**每一步都需要人工确认后执行，本文档只做评估不做变更。**

### 阶段一：让 tempo3 真正有流量（推荐，约 30 分钟）

> ⚠️ **步 2 与步 4 是同一笔操作的因果对**：Grafana 的 Tempo 数据源**已经存在**（id=4），但指向旧栈。所以这一步不是"新建数据源"，而是**改 URL**。漏改步 4 的后果见 §2.2 —— 面板静默空白且无报错。

| 步 | 动作 | 前置检查 | 回滚 |
|---|---|---|---|
| 1 | Grafana 数据源 `tempo`（id=4）的 `url` → `http://tempo3-query-frontend.logging.svc.cluster.local:3200` | 已验证 tempo3 query-frontend `/api/echo` = 200 ✅ | 改回 `tempo-query-frontend...` |
| 2 | 确认 Grafana Tempo 面板能查出数据（先查旧栈存量，再查新 span） | 该数据源 `tracesToLogsV2` → loki、`tracesToMetrics` → prometheus，引用均有效 ✅ | 同上 |
| 3 | 改 OTel Collector CR `otel` 的 `exporters.otlp_grpc/tempo.endpoint` → `tempo3-distributor.logging.svc.cluster.local:4317` | 已验证 tempo3 distributor 暴露 4317 ✅ | `kubectl patch` 改回 `tempo-distributor...` |
| 4 | 观察 `tempo_distributor_spans_received_total`（tempo3）增长、旧栈该指标**停止**增长 | 两者应呈此消彼长 | 同上 |
| 5 | 复核 Grafana Trace 面板能查到新 span（**这步是唯一能证明切换成功的验收点**） | — | — |

**为什么先改数据源（步 1）再改 Collector（步 3）**：反序会导致 Collector 已切、数据源未切的窗口期，期间所有新 trace 都查不到。**先切"看"的一端，再切"写"的一端**，任何时刻至少有一端是好的。

**注意**：改 CR 会触发 Collector 滚动重启（约 30 秒中断），期间**应用侧 trace 会缓冲或丢弃**（`batch` processor `timeout: 10s`，最多丢 10 秒内的数据）。建议低峰期执行。

**风险点**：这一步开始，**新 trace 只进 tempo3，不再进旧栈**。执行前需确认 §2.3 的历史数据处理方案。

### 阶段二：处理历史数据（可选，需决策）

| 选项 | 动作 | 适用 |
|---|---|---|
| **接受丢失** | 直接切，旧栈 620 MB 历史 trace 放弃 | 历史 trace 业务价值低 |
| **导出到 S3** | 3 个 ingester 的 `/var/tempo/traces` → `tempo-traces` 桶对应目录 | 需要延续历史查询 |
| **先只读保留** | 不动数据，旧栈降级为"只跑不收"，观察一段时间后再下线 | 保守方案 |

> 若选"导出到 S3"，必须先确认 Tempo 的 block 目录结构与桶内 prefix 的对应关系，且旧栈 Pod 在导出期间**不能重启**（emptyDir 会丢）。

### 阶段三：退役旧栈（等阶段一二稳定后）

| 步 | 动作 | 说明 |
|---|---|---|
| 1 | 确认旧栈 7 天内无流量增长 | `tempo_distributor_spans_received_total` 不再变化 |
| 2 | 备份 `helm get values tempo -n logging -a` + `helm get manifest` | 回滚源 |
| 3 | 确认历史 trace 处理完毕 | 见 §5 阶段二 |
| 4 | `helm uninstall tempo -n logging` | **⚠️ 需明确人工确认**（本次未执行任何删除） |
| 5 | 验证 tempo3 链路无中断 | trace 查询、告警 |

**预期收益**：释放 9 Pod / 21 Mi，消除 §2.4 的不稳定源，namespace 内 Service 从 21 降到 12。

### 不建议做的事

| ❌ 不要做 | 原因 |
|---|---|
| 直接改 `nameOverride` 修 §2.5 的撞名 | 会静默断掉 `tempo-self-monitor` 对 tempo3 的抓取（它靠撞上的 `name=tempo`）。要改必须**先补 tempo3 的 ServiceMonitor** |
| 现在就 `helm uninstall tempo` | 会立刻丢掉 620 MB 历史 trace + 让阶段一失去对照基准 |
| 把两栈的 S3 桶指向同一个 | 目前**没有这个配置**，不要引入。两栈 block 目录结构不同（2.x 与 3.x 布局有差异），混写会损坏 block |
| 给 tempo3 配 `block_retention` 与旧栈一致 | 旧栈 336h（chart 默认）vs tempo3 48h。**新数据保留期必须按业务需求定，不能照抄旧值** |

---

## 6. 附录：核查命令

本文档所有结论可复现：

### 6.1 隔离维度

```bash
# 两栈配置对比
for CM in tempo-config tempo3-config; do
  kubectl get cm $CM -n logging -o jsonpath='{.data.tempo\.yaml}' \
  | python3 -c "
import sys,yaml
d=yaml.safe_load(sys.stdin.read())
print('$CM',
  'backend=',d['storage']['trace']['backend'],
  'cluster=',d['memberlist']['cluster_label'],
  'mt=',d.get('multitenancy_enabled'))
"
done

# memberlist 是否串环（应无输出）
kubectl logs -n logging -l app.kubernetes.io/instance=tempo3 --tail=500 \
  | grep -i 'tempo.logging' | grep -v tempo3.logging
```

### 6.2 ★ 判定 tempo3 是否空转

```bash
# 建探查 Pod（务必先自检，见 §2.1 的坑）
kubectl run mq --image=curlimages/curl:latest --restart=Never -n logging \
  --command -- sleep 120
kubectl wait --for=condition=Ready pod/mq -n logging --timeout=60s

# 分别取两栈 distributor 的收 span 计数
for L in tempo tempo3; do
  IP=$(kubectl get pod -n logging -l app.kubernetes.io/instance=$L,app.kubernetes.io/component=distributor \
       -o jsonpath='{.items[0].status.podIP}')
  echo "── $L ($IP)"
  kubectl exec mq -n logging -- sh -c \
    "curl -s --max-time 8 http://$IP:3200/metrics" \
  | grep -E '^tempo_distributor_(spans_received|bytes_received)_total'
done

kubectl delete pod mq -n logging --ignore-not-found
```

**判读**：`tempo3` 的 `spans_received_total` 若长期为 0 或只有测试值 → 空转中。

### 6.3 trace 流向的权威判据

```bash
# OTel Collector 的 exporter 指向哪 —— 唯一决定性配置
kubectl get opentelemetrycollector otel -n opentelemetry -o yaml \
  | grep -o "endpoint: '[^']*tempo[^']*'"

# 期望输出（二选一）：
#   endpoint: 'tempo-distributor.logging.svc.cluster.local:4317'   ← 旧栈（当前状态）
#   endpoint: 'tempo3-distributor.logging.svc.cluster.local:4317'  ← 切换后
```

### 6.4 监控覆盖

```bash
# ServiceMonitor selector
kubectl get servicemonitor tempo-self-monitor -n monitoring \
  -o jsonpath='{.spec.selector.matchLabels}'

# 两栈 Pod 的 app.kubernetes.io/name（当前相同 → 撞名）
kubectl get pods -n logging -l app.kubernetes.io/component=distributor \
  -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/name}{"\n"}{end}' | sort -u

# Prometheus 里实际有哪些 tempo job
kubectl run pq --image=curlimages/curl:latest --restart=Never -n monitoring --command -- sleep 120
kubectl exec pq -n monitoring -- curl -s \
  'http://prometheus-prometheus.monitoring:9090/api/v1/targets?state=active' \
  | tr ',' '\n' | grep -oE 'job="[^"]*tempo[^"]*"' | sort -u
kubectl delete pod pq -n monitoring --ignore-not-found
```

### 6.5 ★ Grafana 数据源指向（§2.2 的权威判据）

**不要只看 provisioning 文件** —— 运行时数据源比它多。本次实例中 4 个数据源只有 2 个来自 provisioning。

```bash
# 凭据从 Secret 取，务必用 curl -K 且不 echo（明文不进命令行、不进 shell 历史）
umask 077
GFU=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-user}'      | base64 -d)
GFP=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
printf 'user = "%s:%s"\n' "$GFU" "$GFP" > /tmp/.gfrc
unset GFU GFP

GW=$(kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.spec.clusterIP}')
curl -s -K /tmp/.gfrc "http://$GW/api/datasources" | \
  python3 -c "
import json,sys
for x in json.load(sys.stdin):
    print('  id={} {:<12} type={:<11} {}'.format(x['id'],x['name'],x['type'],x['url']))
"
rm -f /tmp/.gfrc

# 判读：tempo 数据源的 url 是 tempo-query-frontend 还是 tempo3-query-frontend
#        tempo-…  → 旧栈（未切换）
#        tempo3-… → 新栈（已切换）
```

**关联引用完整性**（可选，防悬空 uid）：

```bash
curl -s -K /tmp/.gfrc "http://$GW/api/datasources" | python3 -c "
import json,sys
d=json.load(sys.stdin); uids={x.get('uid') for x in d}
for x in d:
    jd=x.get('jsonData') or {}
    for k in ('tracesToLogsV2','tracesToMetrics'):
        r=(jd.get(k) or {}).get('datasourceUid')
        if r: print('  {}.{} -> {}  {}'.format(x['name'],k,r,'OK' if r in uids else 'DANGLING'))
"
```

### 6.6 历史数据与持久性

```bash
# 旧栈存储类型（emptyDir = 不持久）
kubectl get sts tempo-ingester -n logging -o jsonpath='{.spec.template.spec.volumes}'

# 旧栈数据量
for P in tempo-ingester-0 tempo-ingester-1 tempo-ingester-2; do
  echo "── $P"
  kubectl exec -n logging $P -- du -sh /var/tempo/traces
done

# tempo3 的 S3 桶（凭据从 RGW 取，禁止回显明文）
aws --endpoint-url http://10.0.0.31:7480 s3 ls s3://tempo-traces/ --recursive
```

---

## 7. 评估边界说明

本次评估**只读不写**，未执行任何变更。以下内容**未覆盖**，如需请另行确认：

| 未覆盖项 | 原因 |
|---|---|
| tempo3 承接真实流量的实际表现 | 需要先切流量（§5 阶段一），属于变更 |
| 历史 trace 导出到 S3 的可行性 | 需要读旧栈数据 + 写 S3，属写操作 |
| 旧栈卸载 | 需明确人工确认 |
| tempo3 承接后 Kafka partition 是否够用 | `tempo-traces` 12 partitions vs `auto_create_topic_default_partitions: 3`（已知 P2 项，需真实流量才能判断） |
| Grafana Tempo 面板的**渲染**是否正常 | 已验证数据源配置与 URL 可达（`/api/echo` 200）、引用 uid 完整，但未在浏览器实际打开面板（需登录态） |
| 切换后的回滚路径是否真能还原 | §5 只列出动作，未实际演练（演练需先切流量） |

---

## 8. 自查修正记录

按"结论必须能被自己的探查工具证伪"的纪律，本文档在定稿前做了一轮自查，**推翻了初稿的一条 P0 结论**。记录在此以备复核。

### 8.1 被推翻的结论

| 项 | 内容 |
|---|---|
| **初稿结论** | §2.2「Grafana 里**没有** Tempo 数据源 —— 切了也没地方看」，定级 **P0** |
| **证伪依据** | Grafana API `/api/datasources` 返回 **HTTP 200 / 4 个数据源**，其中 id=4 `name=tempo type=tempo` |
| **真实情况** | Tempo 数据源**存在**，但 `url` 指向**旧栈** `tempo-query-frontend` |
| **修正后结论** | 性质从"无处可看"变为"**看错对象**" —— 仍定级 P0，但风险机制完全不同（静默空白 vs 硬报错） |

### 8.2 初稿为什么会错

**证据来源错误**：只查了 `/etc/grafana/provisioning/datasources/datasource.yaml`，该文件确实只有 `Prometheus` 与 `Alertmanager` 两项。但 Grafana 的数据源可以**运行时经 API 添加**，不体现在 provisioning 文件里 —— 而本集群的 `loki` 与 `tempo` 正是如此添加的。

**交叉线索本该被重视**：Phase-2 审计记录写的是"Grafana 12.4.3（**4 ds** / 37 看板）"。provisioning 只解释得了 2 个，与 4 这个数字对不上。**当时没有去追这个 2 个的差额**，直接采信了 provisioning 的片面结论。

**备份文件本身是坏的**：`observability-upgrade-backup-20260928-172244/grafana/datasources.json` 全文 121 字节，内容是一个 **401 错误响应**，不是数据源快照：

```json
{"extra":null,"message":"Invalid username or password","messageId":"password-auth.failed","statusCode":401,"traceID":""}
```

早前把它当"非字典项"跳过了（解析报 `AttributeError`），**没有去读那个报错体**。如果当时读了，就会立刻知道这份备份根本没抓到数据。

### 8.3 沉淀的教训

| # | 教训 |
|---|---|
| 1 | **provisioning ≠ 运行时真相**。查 Grafana/ArgoCD 等"声明式 + 运行时"双轨系统，必须走 API 读运行时状态 |
| 2 | **交叉数字对不上就要追**。"审计说 4 个，文件里只有 2 个"是明确的矛盾信号，不能跳过 |
| 3 | **备份文件要先验真伪**。备份目录里的文件**不保证是有效快照** —— 本次就抓到一份 401 错误响应冒充快照。落库前应校验内容特征（如状态码、顶层结构），而不是只看文件存在且非空 |
| 4 | **解析异常要读原始内容**。`AttributeError: 'str' object has no attribute 'get'` 的正确处置是打印那个 str 本身，而不是把它当噪声过滤 |
| 5 | **"没有 X"是比"X 指向错了"更强的断言**，需要更强的证据。本文档初稿把一个中等强度证据（文件里没有）用成了强断言（系统里没有） |
| 6 | **静默失联比硬报错更危险**，且更值得写进 P0。§2.2 修正后的问题性质正是如此 |

### 8.4 本次自查的覆盖范围

| 结论 | 证据强度 | 是否经交叉验证 |
|---|---|:---:|
| §1 隔离维度无冲突 | 强（live ConfigMap 解析） | ✅ 与 Prometheus `tempo_build_info` 双版本互证 |
| §2.1 tempo3 空转 | 强（两栈指标直接对比 14 vs 1） | ✅ 与 Collector 配置、distributor 日志三方互证 |
| §2.2 Grafana 数据源 | 强（API 200/4 项） | ✅ 与审计"4 ds"记录互证 |
| §2.3 历史数据丢失 | 强（emptyDir 声明 + du 实测） | ✅ 存储类型与数据量互证 |
| §2.4 旧栈不健康 | 中（重启计数 127） | ⚠️ 未查重启原因（仅从时间戳聚集推断为节点级事件） |
| §2.5 监控撞名 | 强（selector 与 Pod label 比对） | ✅ 与 Prometheus 实际抓到的 `tempo3-distributor` job 互证 |
| §3 健康快照 | 强（实时查询） | — |

**仍存疑、需后续确认的两点**：

- §2.4 判断"2026-09-27 05:55 为节点级事件"，仅依据 9 个 Pod 重启时间戳聚集（05:54:55–05:55:06），**未调取节点事件或 kubelet 日志**确证
- §2.3 认定旧栈 620 MB 历史"不可迁移"，但**未验证** Tempo 2.x 的 block 目录结构能否直接映射到 3.x 的 S3 前缀布局（2.x 与 3.x 的 block 元数据格式可能不兼容）

---

*评估时间：2026-09-28 19:05 – 19:40 CST（含 §8 自查修正）*
*执行人：OpenCode（受 LGMT 运维指令）*
*本文档仅做评估，未执行任何变更、未删除任何数据或命名空间*
