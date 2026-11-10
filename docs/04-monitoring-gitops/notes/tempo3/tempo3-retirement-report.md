# Tempo 旧栈（2.9.0）退役报告

> **执行时间**：2026-09-29 09:37 – 09:52 (CST)
> **退役对象**：helm release `tempo`（chart `tempo-distributed-1.61.3` / app `2.9.0`，revision 1，部署于 2026-04-26）
> **授权**：用户明确确认「直接卸载，历史放弃」+「孤儿 ConfigMap 一并删除」
> **备份目录**：`/root/observability-upgrade-backup-20260929-093751-tempo-decommission`（18 文件 / 588 KB）
> **前置文档**：`/root/tempo3-traffic-cutover-report.md`（流量切换，本次退役的上游步骤）

---

## 目录

- [0. 一句话结论](#0-一句话结论)
- [1. 变更清单](#1-变更清单)
- [2. 退役前的核查](#2-退役前的核查)
- [3. 意外发现：那 620MB 到底是什么](#3-意外发现那-620mb-到底是什么)
- [4. 实际执行过程](#4-实际执行过程)
- [5. 验证结果](#5-验证结果)
- [6. 顺带修正的一处历史误判](#6-顺带修正的一处历史误判)
- [7. 资源账目](#7-资源账目)
- [8. 风险与回滚](#8-风险与回滚)
- [9. 工具失误记录](#9-工具失误记录)
- [10. 遗留问题](#10-遗留问题)
- [11. 复现命令](#11-复现命令)

---

## 0. 一句话结论

> **旧栈已彻底退役，零残留、零回归、trace 链路无损。**
>
> 变更 2 处：`helm uninstall tempo`（删除 23 个对象 + 9 个 Pod）、删除 3 个 2026-04-06 的孤儿 ConfigMap。退役后注入标记 span 验证：tempo3 **精确 +1**、Collector `sent_spans` 正常递增、**0 条 DNS 错误**（证明无任何残留引用指向已删除的旧栈 Service），Grafana 面板路径 3 项全 200。
>
> ⚠️ 本轮最有价值的副产品是**一处历史误判的修正**（§6）：`tempo-self-monitor` 这个 ServiceMonitor 一直被判定为"抓到了 tempo3"，实际上 job 名来源一直没人验证过；退役后暴露它**正在对 tempo3 重复抓取两遍**。

---

## 1. 变更清单

| # | 操作 | 范围 | 授权 |
|---|---|---|:---:|
| **1** | `helm uninstall tempo -n logging --timeout 10m` | 23 个 k8s 对象 + 9 个 Pod | ✅ 用户明确确认 |
| **2** | `kubectl delete cm` × 3（`opentelemetry` ns） | `otel-collector-089d9319` / `718612e4` / `caf5b0c0` | ✅ 用户明确确认 |

**变更量**：2 个操作，删除 26 个对象。**未新增任何对象，未修改任何现存对象的 spec。**

**同时清理（我自己的残留，非变更）**：

| 对象 | 原因 |
|---|---|
| `cm/otelval-1790641593-cm`、`cm/otelval-new-cm` | 上一轮 validate 尝试失败时留下的孤儿 CM，被挂载数 0 |
| Pod `t-rc` / `t-oc` / `t-px` | 本轮验证用探查 Pod |

**明确未触碰**：`tempo3` release（6 个 Pod + 1 StatefulSet 组）、`loki` release、`alloy` release、namespace `logging`、任何 PVC/PV、Ceph 桶 `tempo-traces`、Kafka topic `tempo-traces`、Grafana 任何数据源、任何 Loki/Tempo 数据。

---

## 2. 退役前的核查

### 2.1 无在途流量 ✅

```
采样1  旧栈 tempo_distributor_spans_received_total = 19   (间隔 60s)
采样2  旧栈 tempo_distributor_spans_received_total = 19
→ 完全静止
```

流量切换（上一轮）后旧栈已无任何写入，退役不会丢在途数据。

### 2.2 无外部依赖 ✅

| 依赖类型 | 扫描结果 |
|---|---|
| Ingress / IngressRoute / HTTPRoute / NetworkPolicy 引用 `tempo-` | **0** |
| PrometheusRule 引用 `tempo-` | **0** |
| Grafana 数据源 | 已指向 `tempo3-query-frontend`，与旧栈无关 |
| 仍指向旧栈的 ConfigMap | 3 个（孤儿，见变更 2） |
| 仍指向旧栈的引用位置 | 仅 `logging/tempo-config`（属旧栈 release 自身，随卸载删除） |

### 2.3 无 PVC 风险 ✅

```
tempo-ingester   volumes=[config=configMap, runtime-config=configMap, data=emptyDir]  volumeClaimTemplates=0
tempo-memcached  volumes=[]                                                             volumeClaimTemplates=0
```

**旧栈没有任何 PVC/PV**，全部数据在 `emptyDir` 中。这意味着两件事：卸载不会波及任何存储资源；但 emptyDir 里的内容**必然随 Pod 消失，不可恢复**。

### 2.4 卸载命令的影响面

`helm get manifest tempo` 枚举结果：

| Kind | 数量 |
|---|---:|
| Service | 12 |
| Deployment | 5 |
| StatefulSet | 2 |
| ConfigMap | 2 |
| PodDisruptionBudget | 1 |
| ServiceAccount | 1 |
| **合计** | **23** |

---

## 3. 意外发现：那 620MB 到底是什么

退役前对 3 个 ingester 的 `emptyDir` 做了完整清点，结果与"620MB 垃圾数据"的初始印象**完全不同**。

### 3.1 规模与时间跨度

| 项 | 值 |
|---|---|
| ingester 数量 | 3（`tempo-ingester-0/1/2`） |
| 每栈 block 数 | 65 |
| block 总数 | **195** |
| 容量 | 205.7 MB + 212.0 MB + 212.1 MB = **629.8 MB** |
| 时间跨度 | **2026-05-03T07:56:12Z → 2026-06-05T03:02:17Z** |
| `totalObjects` 合计 | 134,651 + 137,674 + 137,775 = **410,100** |
| parquet 格式 | `vParquet4`（Tempo 2.x 专有） |
| 魔数校验 | 首尾均为 `PAR1` ✅ 文件真实有效，非占位 |

**这不是 19 条 span 的残留**。`spans_received_total=19` 只是当前 distributor 进程的累计值，而这 195 个 block 记录的 `totalObjects` 合计 41 万条、覆盖 5–6 月两个月。

### 3.2 两个反常点

**反常一：数据为何比 `block_retention` 老 4 个月？**

旧栈配置 `block_retention: 336h`（14 天），而这批数据已有约 4 个月。唯一解释是 **compactor 的 ring 同样不健康**——它从未处理过这些 block，因此也从未删除它们。

> 这与上一轮报告 §2 发现的故障是**同一个根因**：ingester ring 不健康 → `search` 返回 500；compactor ring 不健康 → 过期数据不清理。**一个坏 ring 同时造成了"查不出来"和"删不掉"两个症状。**

**反常二：`totalRecords=1` 但 `totalObjects=2100+`**

每个 block 的 `meta.json` 里这两个字段互相矛盾。无法在不加载 parquet 的前提下判定哪个是真实记录数。因此**既不能假设它是有效数据，也不能假设它是垃圾**——这是决定退役前必须先取证、而不是直接卸载的原因。

### 3.3 格式不兼容（决定了它无法抢救）

tempo3 是 `backend: s3` + Tempo 3.x 的 parquet 格式。这批 `vParquet4` 数据即使完整导出到 Ceph 桶，**tempo3 也读不了**。上一轮报告 §8.4 里"历史数据能否迁移"的存疑项，至此可以确认为**不可迁移**。

### 3.4 处置决策

取证完成后，把四个选项连同上述事实提交给用户决策：

| 选项 | 用户选择 |
|---|---|
| A. 直接卸载，历史放弃 | **✅ 选定** |
| B. 先导出历史到 S3 再卸载 | ✗ |
| C. 只备份元数据后卸载 | ✗（但实际执行时**元数据仍全量备份了**，见 §4.1） |
| D. 暂不卸载 | ✗ |

> 用户选定 A 的判断依据与本报告一致：数据已 4 个月无写入（旧栈 09-27 起管道半断）、格式无法被 tempo3 读取、旧栈 search 一直 500 本就查不出来 —— 保留它不产生实际价值。
>
> **尽管如此，仍在卸载前把 195 个 block 的完整 `meta.json` 清单落盘留档**（§4.1），使"当时有什么"这件事永久可查，成本仅 73 KB。

---

## 4. 实际执行过程

### 4.1 备份（18 文件 / 588 KB）

| 类别 | 文件 | 用途 |
|---|---|---|
| **Helm 回滚源** | `helm/values-all.yaml`（1784 行） | 完整计算值，可直接 `helm install` 重建 |
| | `helm/values-user.yaml`（38 行） | 用户自定义值 |
| | `helm/manifest.yaml`（1547 行） | 全部 23 个对象的完整 manifest |
| | `helm/metadata.json` | release 元信息 |
| **现状快照** | `manifests/tempo-resources-before.yaml`（1993 行） | deploy/sts/svc/cm/sa/pdb 完整快照 |
| | `manifests/pods-before.json`（115 KB） | 9 个 Pod 完整状态 |
| | `manifests/svcs-logging-before.json`（84 KB） | logging ns 全部 Service（用于对比 Service 总数变化） |
| | `manifests/cms-logging-before.json`（40 KB） | logging ns 全部 ConfigMap |
| **元数据留档** | `metabackup/tempo-ingester-{0,1,2}-blocks.txt`（各 65 block / 24 KB） | **195 个 block 的完整 `meta.json` 原文** |
| | `metabackup/ALL-blocks.jsonl` | 195 条 block 元数据的结构化汇总 |
| **孤儿 CM** | `orphan-cm/otel-collector-{089d9319,718612e4,caf5b0c0}.json` | 3 个待删 CM 的完整 JSON |
| **验证** | `verify/baseline-before.txt` | 退役前基线 |
| | `verify/after-retire.txt` | 退役后验收证据 |
| | `verify/final-state.txt` | 退役后终态快照 |

### 4.2 孤儿 ConfigMap 的删除前确认

删任何东西之前先证明它们确实是孤儿：

```
otel-collector-089d9319  被 0 个 Pod 挂载 ✅ 孤儿确认
otel-collector-718612e4  被 0 个 Pod 挂载 ✅ 孤儿确认
otel-collector-caf5b0c0  被 0 个 Pod 挂载 ✅ 孤儿确认
```

检查方法：遍历全集群所有 Pod 的 `spec.volumes[].configMap.name` 做精确匹配，不依赖 label 或命名推断。

### 4.3 卸载

```
$ helm uninstall tempo -n logging --timeout 10m
release "tempo" uninstalled
```

Pod 终止过程（正常优雅退出，非 force）：

```
t+005s  剩余 Pod=2 (Terminating=2)
t+010s  剩余 Pod=2 (Terminating=2)
t+015s  剩余 Pod=2 (Terminating=2)
t+020s  剩余 Pod=2 (Terminating=2)
t+025s  剩余 Pod=2 (Terminating=2)
t+030s  剩余 Pod=0
✅ 9 个 Pod 已全部终止
```

> 期间未使用任何 `--force` / `--grace-period=0`，符合既定纪律。

### 4.4 删除孤儿 ConfigMap

```
configmap "otel-collector-089d9319" deleted
configmap "otel-collector-718612e4" deleted
configmap "otel-collector-caf5b0c0" deleted
```

---

## 5. 验证结果

### 5.1 ★ 退役后端到端验收（唯一硬判据）

卸载是破坏性操作，真正的验收标准不是"Pod 没了"，而是**"trace 链路是否仍然完好"**。因此退役后重新注入一条带唯一 marker 的 span：

| 指标 | 退役前 | 退役后 | 判定 |
|---|---:|---:|:---:|
| `tempo3` `spans_received_total` | 2 | **3** | ✅ **精确 +1** |
| Collector `sent_spans{otlp_grpc/tempo}` | 2 | **3** | ✅ ack 正常（+1 同步递增） |
| Collector `send_failed_spans` | 0 | **0** | ✅ 无失败 |
| Collector 日志 `error`/`failed` 行数 | 0 | **0** | ✅ |
| **Collector 日志 `no such host` / `connection refused`** | — | **0** | ✅ **无残留引用指向已删除的旧栈 Service** |

最后一项是本次退役**最关键的一条判据**：如果有任何组件还持有指向 `tempo-distributor` / `tempo-query-frontend` 的引用，卸载后必然立刻产生 DNS 解析失败。0 条证明引用关系已彻底切断。

### 5.2 Grafana 面板路径验证（走数据源代理，非直连）

| # | 验证项 | 结果 |
|---|---|---|
| 1 | `/api/echo` | **HTTP 200** |
| 2 | `/api/search?tags=cutover.marker=POST_RETIRE2_…` | **HTTP 200**，命中 1 条，`traceID=5b8efff798038103d269b633813fd62f` |
| 3 | `/api/search`（全量） | **HTTP 200**，可见 1 条 |

### 5.3 Grafana 数据源完好

```
数据源数 = 4（退役前后一致）
  id=1 Prometheus    http://prometheus-prometheus.monitoring:9090/
  id=2 Alertmanager  http://prometheus-alertmanager.monitoring:9093/
  id=3 loki          http://loki-gateway.logging.svc.cluster.local
  id=4 tempo         http://tempo3-query-frontend.logging.svc.cluster.local:3200
```

### 5.4 旧栈 Service 逐个确认已删除

```
tempo-distributor           ✅ 已删除
tempo-query-frontend        ✅ 已删除
tempo-querier               ✅ 已删除
tempo-ingester              ✅ 已删除
tempo-compactor             ✅ 已删除
tempo-memcached             ✅ 已删除
tempo-gossip-ring           ✅ 已删除
```

### 5.5 集群级回归

| 范围 | 结果 |
|---|---|
| **全集群 CrashLoopBackOff** | **0** ✅ |
| 非 Running Pod | 仅 `kube-system/coredns` `ImagePullBackOff`（37h，**既有问题，与本次无关**） |
| 旧栈资源（deploy/sts/svc/cm/sa/pdb/pod 匹配 `instance=tempo`） | **0** ✅ |
| helm release（`logging` ns） | `alloy` / `loki` / `tempo3` 三个，旧 `tempo` 已消失 ✅ |
| `tempo3` Pod | **13/13 Running**，全栈重启总数 **0** ✅ |
| `loki` Pod | 9 个全 Running ✅ |
| `alloy` Pod | 6 个全 Running ✅ |
| `monitoring` ns Pod | 11 个全 Running ✅ |
| OTel Collector | 1/1 Running，endpoint 仍为 `tempo3-distributor:4317` ✅ |
| OTel Collector 生效 ConfigMap | `otel-collector-326097f8`，内容已核实指向 tempo3 ✅ |
| 探查 Pod / 临时 CM 残留 | **0** ✅ |
| 临时凭据文件 | 已清 ✅ |

### 5.6 Prometheus 侧确认

```
up{job=~"tempo3.*"}  → 2 targets, 值 ['1', '1']   ✅ tempo3 监控链路正常
tempo_distributor_spans_received_total → 2 条 series，值均为 3（与 5.1 一致）
tempo-distributor / tempo-distributor-discovery 旧 job → 已无 activeTarget ✅
```

---

## 6. 顺带修正的一处历史误判

退役后核查监控时，发现 `monitoring/tempo-self-monitor` 这个 ServiceMonitor 有一个**此前从未被验证过**的问题。

### 6.1 背景：它到底在抓什么

`monitoring/tempo-self-monitor`（创建于 2026-09-27T14:20:31Z）的定义：

```yaml
selector:
  matchLabels:
    app.kubernetes.io/component: distributor
    app.kubernetes.io/name: tempo        # ← 注意：不是 tempo3
namespaceSelector:
  matchNames: [logging]
endpoints:
  - port: http-metrics
    interval: 30s
```

共存评估文档（§6/§8）当时的结论是：「它**恰好**也抓到了 tempo3（Prometheus 里有 `tempo3-distributor` job）」，并据此推论「改 `nameOverride` 会静默断监控」。

### 6.2 追查 job 名的真实来源

退役后逐一排查，结论是：**`logging` ns 里有 0 个 ServiceMonitor**，也就是说 `tempo3-distributor` 这个 job **不可能**来自 tempo3 自带的 ServiceMonitor。

真正来源是 Prometheus Operator 的默认行为——**未设置 `jobLabel` 时，job 名取被选中 Service 的名字**。反查 Prometheus target 的完整标签可确认：

```
job = tempo3-distributor
   container = distributor
   endpoint   = http-metrics
   instance   = 10.244.30.70:3200
   namespace  = logging
   pod        = tempo3-distributor-6c4d7f8568-7jmkk
   service    = tempo3-distributor
   health=up  lastError=''
```

`service = tempo3-distributor` → 这个 job 确实由 `tempo-self-monitor` 产出。**旧栈时代的 `tempo-distributor` job 同理**。评估文档的最终结论（"它抓到了 tempo3"）**恰好是对的，但推理链是错的**——当时把 job 名的存在当成了因果证据，而没有验证是谁产出的。

### 6.3 退役暴露的真问题：重复抓取

`logging` ns 里有 **2 个** Service 同时满足该 selector：

```
tempo3-distributor              (10.105.251.62)   ← 有 ClusterIP
tempo3-distributor-discovery    (None)            ← headless
```

两者都指向同一组 distributor Pod，于是**同一份指标被抓了两遍**：

```
job=tempo3-distributor              445 series
job=tempo3-distributor-discovery    445 series
─────────────────────────────────────────────
合计                                892 series（约一半是重复）
```

这不是退役造成的，而是**一直存在**、只是此前没人对比过两个 job 的 series 数。旧栈时代是同样的重复（旧栈也有 `tempo-distributor` + `tempo-distributor-discovery` 两个 job）。

### 6.4 结论修正

| 此前认知 | 修正后 |
|---|---|
| `tempo-self-monitor` 抓到了 tempo3 | ✅ 结论正确 |
| 依据是"Prometheus 里有 `tempo3-distributor` job" | ❌ 推理无效。`logging` ns 无任何 ServiceMonitor，该 job 由 `tempo-self-monitor` 产出 |
| 该 ServiceMonitor 状态正常 | ⚠️ **正在对 tempo3 重复抓取**，浪费约一半存储 |

**对改 `nameOverride` 的影响**：结论仍然成立——一旦给 tempo3 加上 `nameOverride: tempo3`，`app.kubernetes.io/name` 会从 `tempo` 变成 `tempo3`，selector 立即失配，**distributor 监控会静默中断**。这个坑依然存在，只是现在知道了它真实的成因与代价。

---

## 7. 资源账目

| 项 | 退役前 | 退役后 | 变化 |
|---|---:|---:|---:|
| `logging` ns Pod 总数 | 38 | **28** | **−10**（9 旧栈 Pod + 1 探查 Pod） |
| `logging` ns helm release | 4 | **3** | **−1** |
| `logging` ns Service | 21 | **12** | **−9**（退役前含旧栈 12 个中的大部分） |
| 旧栈 Pod 常驻内存 | 约 9 Pod | 0 | **全部释放** |
| `emptyDir` 占用 | 629.8 MB | 0 | **全部释放** |
| 集群 CrashLoopBackOff | 0 | 0 | 持平 |

保留部分：tempo3（13 Pod）、loki（9 Pod）、alloy（6 Pod）。

---

## 8. 风险与回滚

### 8.1 实际风险（回看）

| 风险 | 事前评估 | 事后实测 |
|---|:---:|:---:|
| 有组件仍指向旧栈导致写入失败 | 中 | **零发生**（0 条 DNS 错误，5.1） |
| 卸载误伤同 ns 其他 release | 中 | **零发生**（loki/alloy/tempo3 全部完好，5.5） |
| 卸载误伤 Ceph 桶 / Kafka topic | 低 | **零发生**（tempo3 S3 写入与 Kafka ingest 未受影响） |
| Grafana 数据源失效 | 低 | **零发生**（4 数据源完好，5.3） |
| 629.8 MB 历史不可恢复 | **已发生** | 经用户决策接受；元数据已留档 |

### 8.2 回滚方式

**回滚源**：`/root/observability-upgrade-backup-20260929-093751-tempo-decommission/helm/`

```bash
# 方式 A：按原始 values 完整重建（推荐，最忠实）
helm install tempo -n logging \
  /root/observability-upgrade-backup-20260929-093751-tempo-decommission/helm/values-all.yaml \
  -f /root/observability-upgrade-backup-20260929-093751-tempo-decommission/helm/values-all.yaml

# 方式 B：按 manifest 逐对象重建
kubectl apply -f /root/observability-upgrade-backup-20260929-093751-tempo-decommission/helm/manifest.yaml

# 孤儿 ConfigMap 回滚
kubectl apply -f .../orphan-cm/otel-collector-089d9319.json
kubectl apply -f .../orphan-cm/otel-collector-718612e4.json
kubectl apply -f .../orphan-cm/otel-collector-caf5b0c0.json
```

### 8.3 ⚠️ 回滚的代价（必须知道）

回滚**无法恢复**的部分：

| 丢失项 | 原因 |
|---|---|
| 195 个 block / 629.8 MB trace 数据 | 存在 `emptyDir`，Pod 一删即物理消失，备份中不含实体数据 |
| 旧栈的运行状态 | ingester/compactor ring 需重新协商，约需数分钟才稳定 |

回滚**会重新引入**的问题：

- ingester ring 不健康 → `search` 重新返回 500（流量切换报告 §2 的原始故障）
- compactor ring 不健康 → 过期 block 不清理，磁盘只增不减
- gRPC ack 半断 → 重复投递 + 无限重试（流量切换报告 §2.3 实测：1 条 span 变 3 条）

> 📌 **结论：回滚到旧栈不是"恢复可用"，而是"恢复一个已知有问题的状态"。** 唯一合理的回滚理由是"tempo3 出现比这更严重的问题"，而目前没有这个迹象。

### 8.4 凭据处理

- 本轮未使用任何 Grafana / Ceph 凭据做变更操作，仅用 Grafana admin 凭据做只读验证，以 `curl -K` 方式使用、权限 `600`、**用后即删**（`/tmp/.gfv`、`/tmp/.gfv2` 均已删除）
- 报告与备份中**不含任何凭据明文**
- 凭据指纹：`admin-user` sha256[:12]=`8c6976e5b541`，`admin-password` sha256[:12]=`53baccef4ef6`

---

## 9. 工具失误记录

本轮出现 4 次工具故障，其中第 1 次差点被当成"退役把 trace 链路打断了"。全部先自查再纠正。

### 9.1 ★ 探查 Pod 用错 namespace → 误报"管道中断"

- **现象**：退役后注入 span，`tempo3 spans_received_total` 增量 **0**，第一反应是"卸载打断了写入链路"
- **真实原因**：`kubectl exec t-rc -n opentelemetry` —— 但 `t-rc` 实际在 `logging` ns。命令直接报 `pods "t-rc" not found`，**POST 请求从未发出**
- **为什么危险**：增量 0 + span 查不到，是"退役打断链路"的标准特征。若不查日志就会得出完全错误的结论，甚至触发不必要的紧急回滚
- **识别方法**：命令输出里紧跟着的 `Error from server (NotFound)` 就是线索——**我的管道只 grep 了计数、没保留 stderr**
- **修复**：在 `opentelemetry` ns 新建 `t-oc`，并**先自检**（`otelcol_` 指标 44 行可达）再执行 POST
- **教训**：验证脚本必须先自检执行通道；**不能把"工具没跑成"读作"系统出问题"**

### 9.2 Prometheus label 选择器不存在

- **现象**：`PIP`（Prometheus PodIP）为空 → 所有查询返回 `ERR`
- **真实原因**：用了 `-l app=prometheus`，但 `prometheus-prometheus-prometheus-0` 的 `app` 标签是**空字符串**（该 chart 不用 `app` 标签）
- **修复**：改用 StatefulSet 名称直接定位 + 走 Service ClusterIP（`prometheus-prometheus` = 10.111.41.17）
- **教训**：Helm chart 的标签约定各不相同，**不能假设 `app=<name>` 一定存在**

### 9.3 跨 namespace 删除参数误用（连续两次）

```bash
kubectl delete pod t-bb2 -n logging t-ep -n opentelemetry   # ❌ 只删了 t-ep
kubectl delete pod t-rc -n logging t-oc t-px -n opentelemetry  # ❌ 同样只删了后两个
```

单条命令里的 `-n` 作用于**所有**参数。要跨 ns 必须拆成多条。残留复查（§5.5）抓到了 `t-rc`，单独删除后归零。

### 9.4 label key 写错导致"ServiceMonitor 已失效"的假结论

- **现象**：查 `tempo-self-monitor` 匹配的 Service 得到 0 个 → 一度以为旧 ServiceMonitor 在退役后变成了悬空死配置
- **真实原因**：查询用了 `-l component=distributor,name=tempo`，而实际 label key 是 `app.kubernetes.io/component` / `app.kubernetes.io/name`
- **修复**：改用完整 key 后查到 2 个匹配 Service，并顺带发现了 §6.3 的重复抓取问题
- **教训**：**"查不到" 必须先怀疑查询本身**，尤其是当你刚刚改动了被查询对象的时候——这是退役场景下最自然的一种自我欺骗

---

## 10. 遗留问题

| # | 问题 | 等级 | 说明 |
|---|---|:---:|---|
| 10.1 | **仍无任何 Tempo 告警规则** | P1 | 全集群 PrometheusRule 引用 `tempo-` 的 **0 条**。流量切换报告 §2 的 44 小时静默故障、§6 发现的重复抓取，都是因此没被发现的 |
| 10.2 | `tempo-self-monitor` 重复抓取 tempo3 | P2 | 2 个 Service → 2 个 job → 892 series 约一半重复（§6.3） |
| 10.3 | ServiceMonitor 覆盖不全 | P2 | 仅覆盖 `distributor`。tempo3 的 `querier` / `live-store` / `block-builder` / `backend-*` / `memcached` **无任何指标采集**——这些正是替代了 2.x `ingester` / `compactor` 的组件 |
| 10.4 | 上游无应用接入 OTel | P2 | 管道已通，但 `receiver_accepted_spans_total` 累计仅个位数，真实流量接近 0 |
| 10.5 | tempo3 真实 block flush 未验证 | P2 | 仅验证了单条 span 的收/查，未验证完整 S3 block 落盘周期 |
| 10.6 | OTel ReplicaSet 累积 | P2 | operator 每次变更留一个旧 RS（现存 9 个），**清理需人工确认** |
| 10.7 | `loki` / `tempo` 两个 Grafana 数据源未纳入 provisioning | P2 | 运行时 API 添加，**Grafana 若重建会丢失**。特别注意：`tempo` 数据源的 URL 刚被改过，丢失会退回不可用的旧栈地址 |
| 10.8 | CoreDNS `ImagePullBackOff` | P2 | 既有问题，与本次无关 |
| 10.9 | 18 个 down target / `detected_level` 全局缺失 | P2 | 既有未解 P1/P2，本轮不涉及 |

> 📌 **10.7 风险已因本次变更而升高**：数据源 `tempo` 从"指向一个 search 报 500 的旧栈"变成"指向唯一可用的 tempo3"。它现在处于**单点**位置——Grafana 一旦重建，这个 URL 就会丢失。

---

## 11. 复现命令

### 11.1 确认旧栈已彻底退役

```bash
# 1) release 不存在
helm list -n logging | grep '^tempo ' || echo "已退役"

# 2) 任何 kind 都不再匹配旧栈 label
kubectl get deploy,sts,svc,cm,sa,pdb,pod -n logging -l app.kubernetes.io/instance=tempo

# 3) Service 逐个确认（应全部 NotFound）
for S in tempo-distributor tempo-query-frontend tempo-querier tempo-ingester \
         tempo-compactor tempo-memcached tempo-gossip-ring; do
  kubectl get svc $S -n logging >/dev/null 2>&1 && echo "$S 仍存在" || echo "$S 已删除"
done
```

### 11.2 ★ 退役后功能验收（唯一该跑的测试）

```bash
# 前置：在两个 ns 各建探查 Pod，并各自先自检一个已知端点
#   opentelemetry ns → 读 Collector :8888/metrics
#   logging ns        → 读 tempo3-distributor:3200/metrics
#
# 1) 记录 tempo3 基线
# 2) 注入带唯一 marker 的 span 到 Collector :4318
# 3) 等 25s，判读三项：
#    a) tempo3 spans_received_total 增量 == 1        （流量确实到达）
#    b) Collector sent_spans 同步 +1                （ack 正常）
#    c) Collector 日志 grep -c 'no such host' == 0   （无残留引用指向已删 Service）
#    ← 第 c 项是"卸载是否安全"的决定性判据
```

### 11.3 检查 `tempo-self-monitor` 的实际抓取对象

```bash
# 该 ServiceMonitor 匹配到的 Service（注意 label key 有 app.kubernetes.io/ 前缀）
kubectl get svc -n logging \
  -l app.kubernetes.io/component=distributor,app.kubernetes.io/name=tempo

# 实际有几个 job 在抓（job 名默认 = Service 名）
kubectl exec -n monitoring <prom-pod> -- curl -s \
  'http://prometheus-prometheus.monitoring:9090/api/v1/label/job/values' \
  | python3 -c "import json,sys;print([v for v in json.load(sys.stdin)['data'] if 'tempo' in v])"
# 期望只应出现 1 个（tempo3-distributor），出现 2 个即为重复抓取
```

### 11.4 回滚

```bash
BD=/root/observability-upgrade-backup-20260929-093751-tempo-decommission
helm install tempo -n logging "$BD/helm/values-all.yaml" -f "$BD/helm/values-all.yaml"
# 或
kubectl apply -f "$BD/helm/manifest.yaml"
```

---

## 12. 收尾确认

- 旧栈资源：**0 残留**（release、7 个 Service、9 个 Pod、2 个 StatefulSet、5 个 Deployment、2 个 ConfigMap、1 个 SA、1 个 PDB 全部删除）
- 孤儿 ConfigMap：3 个已删（备份在 `orphan-cm/`）
- 本轮自身残留：探查 Pod 3 个 + validate 遗留 CM 2 个，全部已清
- 临时凭据文件：`/tmp/.gfv`、`/tmp/.gfv2` **已删除**
- 备份目录：18 文件 / 588 KB，含完整 Helm 回滚源与 195 个 block 的元数据留档
- 本次未执行任何删 namespace / PVC / PV / Ceph 桶 / Ceph 对象 / Kafka topic / Grafana 数据源 / Loki 或 Tempo 数据的操作
- 未使用 force 删除任何 Pod

---

*执行时间：2026-09-29 09:37 – 09:52 CST*
*执行人：OpenCode（受 LGMT 运维指令）*
*变更范围：2 个操作 / 删除 26 个对象；其余全部只读*
*上游步骤：见 `tempo3-traffic-cutover-report.md`（流量切换，2 个字段）*
