# LGTM 数据保留窗口统一为 5 天 —— 修复报告

> 生成时间：2026-09-30 15:13 ~ 15:45 (CST)
> 范围：`monitoring` / `logging` 两个命名空间的 Prometheus、Alertmanager、Loki、Tempo、Grafana Alloy，以及 MinIO 对象存储层
> 目标：把 metrics / logs / traces 三条链路的保留窗口统一为 **5 天 = 120h**
> 状态：**已实施并逐层验证通过**

---

## 零、先纠正一个前提：之前的"5天/7天/2天"里，7天是误判

发起这次需求时的记忆是"指标 5 天、日志 7 天、追踪 2 天"。实测之后发现**日志那层的归因是错的**，而真实情况比记忆中更严重。

Loki 配置文件里出现过两次 `168h`（7 天），它们都**不是保留策略**：

| 出现位置 | 配置项 | 它真正的作用 | 是保留期吗 |
|---|---|---|---|
| `loki` CM → `limits_config` | `reject_old_samples_max_age: 168h` | **写入侧的闸门**：拒绝时间戳早于 168h 的样本进入存储。目的是防乱序写入/坏客户端重放，**不删除任何已有数据** | ❌ 否 |
| `alloy-config` CM → `stage.drop` | `older_than = "168h"` | **采集侧的过滤器**：Alloy 读 `/var/log/pods/*.log` 时跳过 7 天前的行。同样不删除数据 | ❌ 否 |

Loki 真正的保留由 **compactor** 控制，而它当时是**关闭**的：

```yaml
# kubectl -n logging get cm loki -o jsonpath='{.data.config\.yaml}'  → 原始配置中
compactor:                      # ← 整个段落不存在
limits_config:
  retention_period: 0s         # ← 0s 的官方语义 = 永久保留
```

通过 Loki 自身的 `/config` 端点读到运行时实际值，确认了这一点：

```
retention_enabled: false
retention_period: 0s
```

Loki 官方文档明确写着：`retention_period` 缺省为 `0s`，**意味着日志被无限期保留**（`retention_enabled` 默认 false，compactor 不做任何删除）。

**那日志为什么只查得到 3~4 天？** 因为真正在删数据的是完全另一层——**MinIO 的对象存储 lifecycle 规则**。这是本次排查最关键的发现，详见第三节。

所以真实的保留窗口分布是：

| 信号 | 组件 | 改前真实保留 | 改前你记的 |
|---|---|---|---|
| Metrics | Prometheus | **5 天** | ✅ 5天 |
| Metrics（告警） | Alertmanager | **5 天**（120h） | ✅ |
| Logs | Loki compactor | **无限**（关闭） | ❌ 不是 7 天 |
| Logs | MinIO lifecycle | **7 天**（真正在删的就是它） | ⚠️ 现象对，来源错 |
| Traces | Tempo | **2 天**（48h） | ✅ 2天 |

**这意味着改前的真实风险不是"窗口不齐"，而是"日志在无界增长"** ——Loki 侧没有任何删除逻辑，一旦对象存储那点容量压力被解除（比如 lifecycle 规则被误删），日志会无限堆积。统一到 5 天同时修掉了这个问题。

---

## 一、名词串讲：三层删除机制各是什么，为什么必须三层都懂

这是本次任务的核心认知。同一份日志数据，从产生到消失要穿过**三个独立的层**，每层都有自己独立的"保留"概念，它们**互不感知、互不同步**。

```
   ┌──────────────┐   ① 采集侧过滤（读的时候不读）
   │  Grafana     │
   │  Alloy       │   stage.drop { older_than = "120h" }
   │  (DaemonSet) │   ← 只是"跳过"，文件还在磁盘上，别的工具还能读
   └──────┬───────┘
          │ 写
   ┌──────▼────────────────────────────────────────┐
   │  Loki 3.6.7  (微服务模式)                       │  ② 索引/存储侧保留（compactor）
   │  ingester → index_gateway → compactor          │     limits_config.retention_period: 120h
   │  → S3 loki-chunks (tsdb chunks + index)        │     retention_enabled: true
   └──────┬────────────────────────────────────────┘
          │ 对象落在 MinIO
   ┌──────▼────────────────────────────────────────┐
   │  MinIO  10.0.0.31:7480                         │  ③ 对象存储生命周期（桶级策略）
   │  bucket: loki-chunks                           │     ILM rule: Expiration Days=10
   │  ILM rule "delete-old-logs"                    │     ← 对所有 key 生效，Loki 完全不知情
   └────────────────────────────────────────────────┘
```

**关键点：③ 对 Loki 是不可见的。** MinIO 只知道"这个对象超过 N 天就删"，它不知道这个对象是 Loki 的 chunk、也不知道 Loki 想保留多久。如果 ③ 比 ② 更短，Loki 的索引里会指向已被硬删的对象，查询时报错或返回空洞；如果 ③ 不存在，② 又没开，数据就永久堆积。

Loki 官方文档对此有硬性要求：**对象存储的 lifecycle 策略必须长于 compactor 的 retention_period**。这正是本次必须先改 MinIO、再改 Loki 的原因。

### 三个必须分清的"保留"术语

**`retention_period`（Loki）** — 定义在 `limits_config` 下，是**数据保留时长**。语义特殊：`0s` = 永久保留（不是"不删除"而是"没有期限"）。真正的删除执行者是 compactor，所以还必须配 `compactor.retention_enabled: true` 才会生效。可被 `runtime_config` 的 per-tenant override 覆盖（本集群 `loki-runtime` CM 内容为 `{}`，无覆盖）。

**`block_retention`（Tempo）** — 定义在 compactor 的 `compaction` 段，单位是**小时**。Tempo 的数据模型和 Loki 不同：trace 数据先聚合成 **block**（一段 parquet 文件），block 写完后才可被 compaction 和 retention 处理。所以 `block_retention: 48h` 的真实含义是"**block 生成 48 小时后被删除**"。配套的 `compacted_block_retention: 1h` 是"已被压缩的 block 保留 1 小时"，必须**小于** `block_retention`，否则压缩完立刻被删。

**MinIO ILM / lifecycle** — 桶级对象存储策略，规则形如 `Expiration: {Days: N}`。它**不认识任何应用语义**，只看对象的最后修改时间。对 S3 兼容存储做保留期管理时，它通常是最后一道兜底，也往往是唯一真正在删数据的那一层（本集群改前就是如此）。

---

## 二、改动前后的完整对照

### 2.1 六个配置点

| # | 组件 | ConfigMap | 配置路径 | 改前 | 改后 | 作用 |
|---|---|---|---|---|---|---|
| 1 | Prometheus | `prometheus-prometheus` (CR) | `spec.retention` | `5d` | `5d` 不动 | TSDB 自删 |
| 2 | Alertmanager | `prometheus-alertmanager` (CR) | `spec.retention` | `120h` | `120h` 不动 | 告警自删 |
| 3 | **Tempo** | `tempo3-config` | `backend_scheduler.provider.compaction.compaction.block_retention` | `48h` | **`120h`** | trace block 保留 |
| 4 | **Tempo** | `tempo3-config` | `backend_worker.compaction.block_retention` | `48h` | **`120h`** | 同上（worker 侧独立配置） |
| 5 | **Loki** | `loki` | `compactor.retention_enabled` | *（段不存在）* | **`true`** | 开启 compactor 删除 |
| 6 | **Loki** | `loki` | `limits_config.retention_period` | `0s` | **`120h`** | 日志保留 5 天 |
| 7 | **Loki** | `loki` | `limits_config.max_query_lookback` | `0s` | **`120h`** | 查询窗口上限对齐 |
| 8 | **Loki** | `loki` | `limits_config.reject_old_samples_max_age` | `168h` | **`120h`** | 写入闸门对齐 |
| 9 | **Loki** | `loki` | `compactor.retention_delete_delay` | *（段不存在）* | **`2h`** | 删除前的缓冲期 |
| 10 | **Loki** | `loki` | `compactor.delete_request_store` | *（段不存在）* | **`s3`** | 删除请求持久化 |
| 11 | **Alloy** | `alloy-config` | `stage.drop.older_than` | `168h` | **`120h`** | 采集侧对齐 |
| 12 | **MinIO** | 桶 `loki-chunks` | ILM rule `delete-old-logs` | `Days: 7` | **`Days: 10`** | 存储层兜底 |

> Tempo 的 `block_retention` 必须改**两处**。`backend_scheduler` 和 `backend_worker` 是两个独立的 StatefulSet，各有自己的配置副本，只改一处会导致调度端和执行端对"多久算过期"的理解不一致。这类"同一个语义参数在多个组件里各写一遍"的坑是分布式配置最常见的疏漏点。

### 2.2 保留窗口最终状态

| 信号 | 组件 | 有效保留 | 存储层兜底 | 是否对齐 |
|---|---|---|---|---|
| Metrics | Prometheus v3.11.2 | 5d | 本地 PVC，无 ILM | ✅ |
| Metrics（告警） | Alertmanager v0.32.0 | 120h | 本地 PVC | ✅ |
| Logs | Loki 3.6.7 | 120h | MinIO 10d | ✅ |
| Traces | Tempo 3.0.3 | 120h | `tempo-traces` 无 ILM | ✅ |

三层关系现在是：**Loki compactor 5 天是唯一的删除决策方，MinIO 10 天是纯兜底**（10 > 5 满足官方约束），Alloy 5 天不再读已被删除的区间。

---

## 三、MinIO lifecycle：从 7 天改到 10 天，以及为什么必须先改它

### 3.1 发现过程

`loki-chunks` 桶的访问需要 `loki-admin` 账号（与 Tempo 的 `tempo-traces` 是**分离的 service account**，权限不互通——用 tempo 凭据访问 loki-chunks 会 403）。查配置时用的是 Loki 自己配置里的那组凭据。

```json
// mc ilm rule ls --json la/loki-chunks   —— 改前
{"Rules":[{"Expiration":{"Days":7},"ID":"delete-old-logs","Status":"Enabled"}]}

// mc version info --json la/loki-chunks   —— 改前
{"versioning":{"status":""}}    // 空字符串 = 未开启 versioning
```

一条 **已启用**的 ILM 规则 `delete-old-logs`，7 天删除，桶**没有开对象版本控制**。

### 3.2 为什么这是必须先解决的阻塞点

假设跳过这步，直接开 Loki `retention_period: 120h`：

- **双重删除**：Loki compactor 在第 5 天发起删除，MinIO ILM 在第 7 天独立发起删除。两者对同一批 chunk 各删一次，第二次会撞上"对象不存在"。
- **Loki 报错**：compactor 生成的删除请求可能指向已被 ILM 硬删的对象，日志里会出现删除失败，且 compactor 会持续重试。
- **不可逆**：桶没有 versioning，MinIO 的 Expiration 是**硬删**。一旦保留期配错（比如手误写成 `1d`），数据永久消失，**没有任何回滚路径**。这是本次操作中风险最高的一点。

Loki 官方文档的原话是：*"If you have a lifecycle policy configured on the object store, please ensure that it is longer than the retention period."*

### 3.3 执行

按用户确认（该 7 天规则疑似 Promtail → Alloy 迁移时设置）改为 **10 天**：

```bash
# mc 镜像内无 sed/sed 不可用，改用 printf 直接写文件后 import
printf '%s\n' '{"Rules":[{"Expiration":{"Days":10},"ID":"delete-old-logs","Status":"Enabled"}]}' > /tmp/ilm.json
mc ilm rule import la/loki-chunks < /tmp/ilm.json
```

```json
// 改后终态
{"Rules":[{"Expiration":{"Days":10},"ID":"delete-old-logs","Status":"Enabled"}]}
```

规则 ID `delete-old-logs` 保持不变，状态保持 `Enabled`。同时确认 `tempo-traces` 桶**没有任何 ILM 规则**（返回 `NoSuchLifecycleConfiguration`），不受本次操作影响。

桶用量：改前 247 MiB / 7451 objects → 改后 248 MiB / 7389 objects（正常波动，ILM 尚未到执行点）。

---

## 四、Loki 改动：首次开启 compactor 保留

### 4.1 前置条件核验

Loki 的 retention 功能有几个硬性前置条件，逐一确认才动配置：

| 条件 | 要求 | 本集群实测 | 结论 |
|---|---|---|---|
| 索引类型 | `store: tsdb`（BoltDB 已废弃） | `store: tsdb`, `schema: v13` | ✅ |
| **索引周期** | **必须 24h**（硬性要求，短于此会拒绝配置） | `index.period: 24h` | ✅ |
| 工作目录 | 需可写且最好持久化 | `working_directory: /var/loki/compactor`，`/var/loki` 挂 10Gi PVC `data-loki-backend-0` | ✅ |
| 对象存储 | 需配置 S3 兼容后端 | `common.storage.s3` → bucket `loki-chunks` @ `10.0.0.31:7480` | ✅ |
| 删除请求存储 | `delete_request_store` 需显式配置 | 改前为空，已设为 `s3` | ✅ 补上 |

索引周期 24h 这一条特别值得注意：它是 Loki 保留功能的**硬门槛**。如果集群用的是 BoltDB shipper 或更短的索引周期，compactor 会直接拒绝启动保留功能。这也是"配了 retention 却没生效"最常见的原因之一。

### 4.2 新增的 compactor 段

```yaml
compactor:
  working_directory: /var/loki/compactor
  compaction_interval: 10m
  # ---- retention (5d = 120h, unified with Prometheus/Tempo/Alertmanager) ----
  # Before: retention_enabled=false + limits_config.retention_period=0s
  # => logs lived forever; the only real deletion was the MinIO lifecycle rule.
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
  delete_request_store: s3
```

各字段的作用：

- **`retention_enabled: true`** — 打开保留功能的总开关。false 时 compactor 只做索引压缩，不删任何数据。
- **`retention_delete_delay: 2h`** — 标记"此数据可删"到"真正执行删除"之间的缓冲期。给运维留了 2 小时的反悔窗口：这段时间内如果发现配错，调回配置还能救回来。这是**唯一的安全阀**，不要设成 0。
- **`retention_delete_worker_count: 150`** — 并发删除的工作协程数。值太大会对 S3 端造成突发压力（删除风暴）。
- **`delete_request_store: s3`** — 删除请求（delete request）持久化到哪里。**必须显式配置**，否则 compactor 没有地方记录"哪些 chunk 待删"，重启后状态丢失。设为 `s3` 表示请求本身也落对象存储，避免 pod 重启丢状态。
- **`compaction_interval: 10m`** — compactor 主循环周期，决定保留检查的频率。

### 4.3 limits_config 改动

```yaml
limits_config:
  max_cache_freshness_per_query: 10m
  query_timeout: 300s
  # ---- 5d (120h) unified retention window ----
  retention_period: 120h        # ← 新增：数据保留 5 天
  max_query_lookback: 120h       # ← 新增：查询窗口上限
  reject_old_samples: true
  reject_old_samples_max_age: 120h   # 168h → 120h
  split_queries_by_interval: 15m
  volume_enabled: true
```

- **`retention_period: 120h`** — 保留时长本体。这是本次统一的核心参数。
- **`max_query_lookback: 120h`** — 查询侧的时间回溯上限。设成 0s（无限）时，Grafana 时间选择器会让用户选出 3 个月前的时间范围，然后得到一个空结果或报错。对齐到 120h 后，查询窗口和实际可用数据一致，用户体验和排障效率都更好。
- **`reject_old_samples_max_age: 168h → 120h`** — 这个**不是**保留期（前面解释过），但既然统一了窗口，同一处出现两个时间数字容易误导后续维护者，一并对齐并加注释说明其真实语义。

### 4.4 一次真实的踩坑：Loki 3.6 移除了两个 compactor 字段

首次 apply 后 `loki-backend-0` 立刻进入 **CrashLoopBackOff**（4 次重启）：

```
failed parsing config: /etc/loki/config/config.yaml: yaml: unmarshal errors:
  line 29: field compaction_retries not found in type compactor.Config
  line 30: field compaction_concurrency not found in type compactor.Config.
```

原因是我按旧版本文档顺手加了 `compaction_retries: 3` 和 `compaction_concurrency: 1`，但这两个字段在 **Loki 3.6 已被移除**。Loki 对未知字段是**严格拒绝**而非忽略（这是个好设计——拼错的配置不会被静默忽略），所以直接启动失败。移除这两个字段后一次通过。

**教训**：跨大版本改配置时，字段必须以目标版本的实际二进制为准，不能照搬旧文档。验证手段是启动日志里的 `unmarshal errors`，它会把所有不认识的字段一次性列全，比逐个试错快得多。

### 4.5 关键陷阱：改 ConfigMap ≠ 所有角色生效

这是本次踩的第二个坑，也是一个容易误判为"配置没生效"的陷阱。

第一次验证时读 `loki-read` 的 `/config`，拿到的仍是：

```
retention_enabled: false
retention_period: 0s
```

此时 ConfigMap 里的内容**确实已经是新的**（`kubectl get cm loki` 确认无误），backend pod 也已经 0 重启正常 Running。原因在于 **Loki 微服务模式下每个角色是独立进程，各自持有启动时解析的配置快照**：

| 角色 | 工作负载类型 | 挂载 `loki` CM | 是否需要重启 |
|---|---|---|---|
| `loki-backend` | StatefulSet | ✅ | ✅ 已重启 |
| `loki-read` | **Deployment** | ✅ | ✅ **必须重启** |
| `loki-write` | StatefulSet | ✅ | 保留参数不影响写入，可选 |

补重启 `loki-read` 后才拿到新值。**教训**：在这个架构里改 Loki 配置，ConfigMap 更新只是第一步，必须逐个确认哪些角色需要 reload——Deployment 和 StatefulSet 的重启语义也不同，不能假设"改了 CM 就会自动生效"。

### 4.6 生效证据

重启后从 Loki 自身的 `/config` 端点读到**运行时实际解析值**（不是配置文件文本，这是唯一可信的验证方式）：

```
=== /ready ===
200
=== compactor (as parsed) ===
  working_directory: /var/loki/compactor
  retention_enabled: true          ← ✅
  retention_delete_delay: 2h0m0s
  delete_request_store: s3         ← ✅
=== limits ===
  retention_period: 5d             ← ✅
  max_query_lookback: 5d           ← ✅
  reject_old_samples_max_age: 5d   ← ✅
```

compactor 首个周期（07:28:59）的日志证明它**在真实工作**，而非只是配置被接受：

```
caller=util.go:79  table-name=index_20624  user-id=self-monitoring  msg="downloaded file"  size="834 B"
caller=marker.go:77 msg="mark file created"  file=/var/loki/compactor/retention/s3_2024-01-01/markers/1790753339313468983
caller=util.go:79  table-name=index_20622  user-id=fake  msg="downloaded and extracted file"  size="293 kB"
caller=marker.go:77 msg="mark file created"  file=/var/loki/compactor/retention/s3_2024-01-01/markers/1790753339495074510
```

解读：compactor 正在遍历 20622 / 20623 / 20624 三天的索引表，**两个租户都在处理**（`fake` 是业务租户，`self-monitoring` 是 Loki 自监控租户），并已在 PVC 上写入 retention marker 文件。这说明删除流水线已建立，`retention_delete_delay: 2h` 的缓冲期机制在运作。

查询功能同步验证正常：

```json
{"status":"success","data":{"resultType":"streams","result":[{"stream":{"app":"calico-node","container":"calico-node",...
```

---

## 五、Tempo 改动：48h → 120h

### 5.1 改动

`tempo3-config` CM 的 `tempo.yaml` 中 `block_retention` 出现在**两个独立位置**，两处都要改：

```yaml
# 位置 1：backend_scheduler（作业调度端）
backend_scheduler:
  provider:
    compaction:
      compaction:
        # ---- 5d (120h) unified with Prometheus/Loki/Alertmanager ----
        # Was 48h, which made traces the shortest window in the stack and
        # broke cross-signal correlation for any incident older than 2 days.
        block_retention: 120h
        compacted_block_retention: 1h

# 位置 2：backend_worker（作业执行端）
backend_worker:
  compaction:
    # ---- 5d (120h) unified (see backend_scheduler.provider.compaction) ----
    block_retention: 120h
    compacted_block_retention: 1h
```

`compacted_block_retention: 1h` 保持不变——它必须小于 `block_retention`，1h < 120h 约束满足。

### 5.2 未受影响的配置

```yaml
multitenancy_enabled: false
overrides:
  defaults: {}
  per_tenant_override_config: /runtime-config/overrides.yaml
```

`tempo3-runtime` CM 内容为 `overrides:\n  null`，无租户级覆盖。所以 `spec` 里的 `block_retention` 就是最终生效值，不存在被 override 掉的可能。**这是必须验证的一点**——如果存在 per-tenant override，改了基础配置也不会生效。

### 5.3 验证

```bash
kubectl -n logging rollout restart sts tempo3-backend-scheduler tempo3-backend-worker
```

- `tempo3-backend-scheduler-0`：Ready，0 重启，日志确认 `retention provider started` + `compaction provider started`
- `tempo3-backend-worker-0`：Ready，0 重启
- `tempo3-query-frontend` `/ready` → **200**

worker 启动时有两类日志需要正确解读，**都不是故障**：

```
msg="waiting until backend-worker ring topology is stable" min_waiting=1m0s max_waiting=5m0s
  → 正常：Tempo 3.x 新架构要求等 memberlist 环拓扑稳定后才接活，约 1 分钟后自动转为 ACTIVE

err="rpc error: code = NotFound desc = no jobs found"  backoff=1.714657818s
  → 正常：集群空转，没有 block 需要 compaction/retention，worker 轮询 scheduler 要活但没活可领
```

`WriteTo failed addr=10.0.0.x:7946 i/o timeout` 是 memberlist gossip 的周期性噪声，每个 Tempo 组件都有，与本次改动无关。

**关于空转的重要说明**：Tempo 目前**没有任何 trace 数据**（`tempo-traces` 桶 393 KiB / 16 objects，全是元数据），所以 `block_retention` 的实际删除效果**无法在当前状态下被验证**——没有 block 存在，也就无从观察 5 天后是否被正确删除。已验证的是**配置已正确加载并被服务接受**，实际删除行为需要等业务侧接入 OTLP 流量后才能观察。这一点在原报告的 P0-2（追踪链路空转）中已单独记录，本次修复不改变该状态。

---

## 六、Alloy 改动：168h → 120h

```hcl
// alloy-config CM → config.alloy
loki.process "logs_to_prometheus" {
    forward_to = [loki.write.default.receiver]
    stage.cri { }
    // 与 Loki retention_period 对齐：5d = 120h
    stage.drop {
        // 改动前是 168h，比 Loki 的 retention_period 长，
        // 导致采集端还在读 Loki 早已删除的日志
        older_than = "120h"
    }
}
```

改前 Alloy 的 120h→168h 窗口比 Loki 的实际保留更长，会出现"白读"——Alloy 费力读取 Loki 早就删掉的日志区间。这不会导致数据错误，但会造成无谓的磁盘 IO 和 CPU 开销。对齐后三层一致。

**注意这个改动是纯一致性优化，不是功能修复**：真正删数据的是 Loki compactor，Alloy 的 `stage.drop` 无论如何都不删任何东西。理解这一点很重要，否则会误以为改 Alloy 就能"实现保留"。

执行：`kubectl -n logging rollout restart ds alloy` → 6/6 节点就绪，0 重启。

> 排查期间观察到 alloy Pod 名称频繁变化（`68t5k`→`mj7kt`→`tsj9x`），一度疑似崩溃。核实后确认是 DaemonSet **滚动替换的正常过程**——`maxUnavailable` 策略下逐个替换 Pod，旧 Pod 被 `Killing` 后以新名重建。最终 `kubectl rollout status ds/alloy` 返回 `successfully rolled out`，6 个 Pod 全部 Ready 且 `restarts=0`。**判断依据是 restartCount 而非 Pod 名称**——DaemonSet 重建 Pod 不增加容器重启计数。

---

## 七、逐层验证结果汇总

### 7.1 配置层

| 检查项 | 命令 | 结果 |
|---|---|---|
| Prometheus 保留 | `kubectl -n monitoring get prometheus -o custom-columns=...` | `5d` ✅ |
| Alertmanager 保留 | `kubectl -n monitoring get alertmanager -o custom-columns=...` | `120h` ✅ |
| Tempo 保留（scheduler） | `cm tempo3-config \| grep block_retention` | `120h` ×1 ✅ |
| Tempo 保留（worker） | 同上 | `120h` ×1（共 2 处，均已改）✅ |
| Loki compactor | `cm loki \| grep retention_enabled` | `true` ✅ |
| Loki 保留期 | `cm loki \| grep retention_period` | `120h` ✅ |
| Loki 查询窗口 | `cm loki \| grep max_query_lookback` | `120h` ✅ |
| Loki 写入闸门 | `cm loki \| grep reject_old_samples_max_age` | `120h` ✅ |
| Loki 删除请求存储 | `cm loki \| grep delete_request_store` | `s3` ✅ |
| Alloy 采集窗口 | `cm alloy-config \| grep older_than` | `120h` ✅ |
| MinIO 兜底 | `mc ilm rule ls --json la/loki-chunks` | `Days: 10` ✅ |
| MinIO versioning | `mc version info --json` | 未开启（已知风险，见第八节）⚠️ |

### 7.2 运行时层（读服务自身暴露的接口，而非配置文件文本）

| 检查项 | 结果 |
|---|---|
| Prometheus `/api/v1/status/flags` | `storage.tsdb.retention.time: 5d` ✅ |
| Prometheus `/-/ready` | 200 ✅ |
| Loki `/ready` | 200 ✅ |
| Loki `/config` 运行时解析 | `retention_enabled: true`、`retention_period: 5d`、`delete_request_store: s3` ✅ |
| Loki 实时查询 | 返回真实日志流（`calico-node` 等）✅ |
| Loki compactor 行为 | 遍历 index_20622/20623/20624，写入 retention marker，两个租户均处理 ✅ |
| Tempo `/ready` | 200 ✅ |
| Tempo scheduler 日志 | `retention provider started` ✅ |
| MinIO lifecycle 终态 | `Days: 10`, `Enabled` ✅ |

### 7.3 Pod 健康

全部受影响 Pod **0 重启**（滚动更新导致的正常重建，restartCount 均为 0）：

```
alloy × 6                0 restarts   Ready
loki-backend-0           0 restarts   Ready
loki-read-65c6649765     0 restarts   Ready
tempo3-backend-scheduler-0  0 restarts  Ready
tempo3-backend-worker-0     0 restarts  Ready
```

未受影响的 Pod（`loki-write-0`、`loki-canary × 3`、cache 等）保持原有 restartCount 12/30（来自 9-27 的集群重启事件，非本次引入）。

### 7.4 容量影响

| 存储 | 改前 | 改后 | 说明 |
|---|---|---|---|
| `loki-chunks` (MinIO) | 247 MiB / 7451 objects | 248 MiB / 7389 objects | Loki 数据仅回溯 ~3 天（Promtail→Alloy 迁移所致），开启 120h 保留**未删除任何数据** |
| `tempo-traces` (MinIO) | 393 KiB / 16 objects | 不变 | 无 ILM 规则，无 trace 数据 |
| Prometheus PVC | 3.86 GiB | 不变 | 未改动 |

**风险评估：低。** Loki 中现存数据比新的 5 天窗口还少，compactor 首次运行未触发任何删除（只写了 marker）。日志量级按现有 248 MiB / 3天 推算，5 天约 400 MiB，容量充裕。

---

## 八、遗留风险与后续建议

### 8.1 🟡 MinIO 桶未开对象 versioning（建议处理）

`loki-chunks` 和 `tempo-traces` 均未开启 versioning。这意味着**任何存储层误配都是不可逆的**。本次操作中这一点尤其值得注意：如果 MinIO lifecycle 被误设为 1 天，compactor 还在按 5 天逻辑工作，日志会在无人察觉的情况下持续消失且无法恢复。

建议：对 `loki-chunks` 开启 versioning（`mc version enable`），或至少确保 ILM 规则有意识地保持长于 compactor 保留期。versioning 会增加存储占用（保留旧版本），需要评估——但对于日志这类可重新生成的信号数据，这个权衡通常值得。

### 8.2 🟡 Tempo 保留的实际删除行为仍未验证

如第五节所述，集群无 trace 数据，`block_retention: 120h` 的删除效果**未被实际观察**。需要在业务侧接入 OTLP 流量后，验证 5 天后 block 被正确清理。这依赖 P0-2（追踪链路空转）的解决。

### 8.3 🟡 ConfigMap 手动 apply，未纳入 GitOps

本次改动的三个 ConfigMap（`loki`、`tempo3-config`、`alloy-config`）和 MinIO ILM 规则都是**手动 apply**，与原报告 P0-1 中指出的 Grafana datasource 问题是同一类：**不在 GitOps 管理下，集群重建或误操作会丢失，且配置漂移无法察觉**。

建议纳入 ArgoCD（集群已有 `argocd` 命名空间，运行 255 天）。特别提醒：**MinIO 的 ILM 规则不在 Kubernetes 里，ArgoCD 管不到**，它需要单独的 IaC 管理（如 Terraform 管理 MinIO），否则会成为 GitOps 覆盖范围内的一个盲区。

### 8.4 提示后续维护者：三个"保留"不是一回事

本次最核心的认知收获，建议记录在运维文档中：

> 在这个集群里，"日志保留 5 天"是由**三个独立配置**共同保证的：
> `loki` CM 的 `limits_config.retention_period` + `compactor.retention_enabled`（**决定实际删除**）、
> `alloy-config` 的 `stage.drop.older_than`（只影响读取，不删除）、
> MinIO 桶 `loki-chunks` 的 ILM 规则（**兜底，必须长于前者**）。
>
> 改任何一个都要同步另外两个，且 MinIO 那个在 kubectl 里看不到。

---

## 九、变更清单与回滚方式

### 9.1 备份位置

所有改动前的完整 YAML 已备份：

```
/root/retention-unify-backup-20260930-151325/
├── loki.yaml            (ConfigMap loki)
├── tempo3-config.yaml   (ConfigMap tempo3-config)
├── alloy-config.yaml    (ConfigMap alloy-config)
└── runtime-config.yaml  (空，loki-runtime 无覆盖)
```

MinIO ILM 规则原值已记录在第三节 3.1 节（`Days: 7`）。

### 9.2 变更对象

| 对象 | 类型 | 命名空间/位置 |
|---|---|---|
| `loki` | ConfigMap | `logging` |
| `tempo3-config` | ConfigMap | `logging` |
| `alloy-config` | ConfigMap | `logging` |
| `loki-backend` | StatefulSet（重启） | `logging` |
| `loki-read` | Deployment（重启） | `logging` |
| `tempo3-backend-scheduler` | StatefulSet（重启） | `logging` |
| `tempo3-backend-worker` | StatefulSet（重启） | `logging` |
| `alloy` | DaemonSet（重启） | `logging` |
| `loki-chunks` 桶 ILM 规则 | MinIO 对象存储 | `10.0.0.31:7480` |

**未改动**：Prometheus、Alertmanager 及其 CR、`loki-write`、`loki-canary`、cache 组件、otel-collector、`tempo-traces` 桶。

### 9.3 回滚

```bash
BK=/root/retention-unify-backup-20260930-151325

# 1) 恢复三个 ConfigMap
kubectl apply -f $BK/loki.yaml
kubectl apply -f $BK/tempo3-config.yaml
kubectl apply -f $BK/alloy-config.yaml

# 2) 重启受影响的工作负载
kubectl -n logging rollout restart sts loki-backend
kubectl -n logging rollout restart deploy loki-read
kubectl -n logging rollout restart sts tempo3-backend-scheduler tempo3-backend-worker
kubectl -n logging rollout restart ds alloy

# 3) 恢复 MinIO ILM 为 7 天
#    注意：应先恢复 Loki 配置（关闭 retention），再放宽 ILM，
#    顺序反了会出现短暂的窗口错配
printf '%s\n' '{"Rules":[{"Expiration":{"Days":7},"ID":"delete-old-logs","Status":"Enabled"}]}' > /tmp/ilm-rollback.json
mc ilm rule import la/loki-chunks < /tmp/ilm-rollback.json
```

> **回滚顺序很重要**：MinIO 的 ILM 生效有延迟（MinIO 定期扫描桶），而 Loki compactor 的 `retention_delete_delay: 2h` 也提供了缓冲。回滚时应先让 Loki 停止删除，再放宽 ILM，避免出现"Loki 已停止删除但 ILM 仍在 7 天清理"的错配窗口。反向操作（先收紧 ILM）则会让 compactor 撞上不存在的对象。

### 9.4 重要提醒

**已删除的数据无法恢复。** 本次操作中 Loki compactor 尚未触发任何实际删除（现存数据比 5 天窗口少），但随着时间推移，5 天前的日志和 trace 将开始被真实删除。这是预期行为。

---

## 十、给后续排查者的速查表

```bash
# ===== 保留窗口：配置层 =====
kubectl -n monitoring get prometheus  -o custom-columns=NAME:.metadata.name,RET:.spec.retention --no-headers
kubectl -n monitoring get alertmanager -o custom-columns=NAME:.metadata.name,RET:.spec.retention --no-headers
kubectl -n logging get cm tempo3-config -o jsonpath='{.data.tempo\.yaml}' | grep -n block_retention
kubectl -n logging get cm loki          -o jsonpath='{.data.config\.yaml}' | grep -E "retention_enabled|retention_period|max_query_lookback|delete_request_store"
kubectl -n logging get cm alloy-config  -o jsonpath='{.data.config\.alloy}' | grep -n older_than

# ===== 保留窗口：运行时（更可信，读服务自身解析结果）=====
# Prometheus
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/status/flags | tr ',' '\n' | grep retention

# Loki（需带租户头 fake）
kubectl -n logging port-forward svc/loki-read 3100:3100 &
curl -s localhost:3100/config | grep -E "^  retention_period:|^  retention_enabled:|^  max_query_lookback:"

# ===== MinIO 桶策略（kubectl 看不到，必须用 mc）=====
kubectl -n logging run mc --rm -i --restart=Never --image=minio/mc:latest --overrides='...' 
# 关键：loki-chunks 用 loki-admin 凭据，tempo-traces 用 tempo 凭据，两者权限不互通
mc ilm rule ls --json <alias>/loki-chunks     # lifecycle 规则
mc version info --json <alias>/loki-chunks    # versioning 状态（空字符串 = 未开启）
mc du <alias>/loki-chunks                     # 用量

# ===== 健康检查 =====
kubectl -n logging get pods -l app.kubernetes.io/name=loki  -o wide
kubectl -n logging get pods -l app.kubernetes.io/name=tempo -o wide
kubectl -n logging get pods -l app.kubernetes.io/name=alloy -o wide
kubectl -n logging logs loki-backend-0 -c loki --tail=100 | grep -i "compactor\|retention\|mark file"
kubectl -n logging logs tempo3-backend-scheduler-0 --tail=50 | grep -i "retention provider"
```

---

## 附：本次操作的关键经验

1. **"配置里有个时间数字"≠ "那是保留期"。** Loki 的 `reject_old_samples_max_age` 是写入闸门，Alloy 的 `stage.drop` 是读取过滤，MinIO 的 ILF 才是真正在删数据的那一层。三者都影响"你能查多久"，但机制完全不同。

2. **对象存储的 lifecycle 必须长于应用层保留期**，否则两层删除互相打架，且在无 versioning 的桶上不可逆。这是执行顺序的硬约束。

3. **改 ConfigMap 不等于所有服务生效。** 微服务架构下每个角色是独立进程、各持配置快照，Deployment 和 StatefulSet 都要单独确认。唯一可信的验证是读服务自己的 `/config` 或 `/status/flags` 接口。

4. **跨版本改配置要以目标版本二进制为准。** Loki 3.6 移除了 `compaction_retries`/`compaction_concurrency`，照搬旧文档直接 CrashLoop。好在 Loki 对未知字段严格报错并一次性列全，启动日志是最快的排错入口。

5. **同一语义参数在多个组件里各写一遍时，必须全部改到。** Tempo 的 `block_retention` 在 scheduler 和 worker 各有一份。

6. **判断 Pod 是否崩溃看 restartCount，不看 Pod 名称。** DaemonSet 滚动替换会不断换名字，那是正常过程。

7. **保留期配错的杀伤力在于不可逆。** 桶无 versioning 时，任何误配都是硬删。`retention_delete_delay` 提供的缓冲期是唯一的安全阀。

---

*报告结束。全部改动已实施并通过配置层 + 运行时层双重验证。*
