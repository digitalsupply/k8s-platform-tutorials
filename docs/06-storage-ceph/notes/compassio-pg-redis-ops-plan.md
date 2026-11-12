# Compassio PostgreSQL + Redis 运维提升方案

> 基于 2026-11-05 对现网集群的**只读巡检**，未做任何变更。
> 集群：Kubernetes v1.35.9 / CloudNativePG 1.22.0 / PostgreSQL 16.15 / Redis 7 / 命名空间 `compassio`。
> 目标：把运维从"能连、能重启"提升到"有 HA、有观测、有演练、有容量规划"，并给出面试四问的可落地答案。

---

## 目录

- [0. 一页结论](#0-一页结论)
- [1. 现网基线（实测）](#1-现网基线实测)
- [2. 面试题一：Redis 穿透、击穿、雪崩](#2-面试题一redis-穿透击穿雪崩)
- [3. 面试题二：主库宕机、切换流程与 RTO](#3-面试题二主库宕机切换流程与-rto)
- [4. 面试题三：连接池打满](#4-面试题三连接池打满)
- [5. 面试题四：慢查询定位到 SQL 和索引](#5-面试题四慢查询定位到-sql-和索引)
- [6. 备份与恢复演练](#6-备份与恢复演练)
- [7. 容量规划](#7-容量规划)
- [8. 观测与告警补齐](#8-观测与告警补齐)
- [9. 实施路线图（P0/P1/P2）](#9-实施路线图p0p1p2)
- [10. 面试速答卡](#10-面试速答卡)

---

## 0. 一页结论

### 现状好的地方

- PostgreSQL 由 **CloudNativePG（CNPG）** 管理，**2 实例（1 主 1 备）**，有自动 failover。
- 每天 **02:00 全量备份**，WAL 连续归档到 S3（Ceph RGW），保留 30 天；最近一次成功。
- 应用有 **Redis 不可用时的本地降级**：`next_cache`、`checkpoint` 都有进程内 LRU fallback。
- 登录失败限流使用 Redis `INCR + EXPIRE`，实现正确。
- LLM 探活使用 `SET NX EX` 做跨进程单飞，避免 2 pod × 2 worker 重复探测。
- 有 PDB、topologySpread、readiness/liveness 探针。

### 当前最大的 6 个缺口

| 优先级 | 缺口 | 证据 | 影响 |
|---|---|---|---|
| P0 | 应用启动对 DB **没有重试** | 2026-11-05 01:37 failover 时 pod 启动报 `ConnectionRefusedError` 退出 | 实际 RTO 被拉长到约 44 秒 |
| P0 | SQLAlchemy **没有 pool 配置** | `create_async_engine(url, future=True)`，默认 5+10、`pool_pre_ping=False` | failover 后陈旧连接报错；扩容时连接数不可控 |
| P0 | **没有 `pg_stat_statements` / 慢日志** | `shared_preload_libraries=""`、`log_min_duration_statement=-1`、`track_io_timing=off` | 无法定位具体 SQL 和索引 |
| P0 | `/api/health` **永远返回 200** | readinessProbe 只看 HTTP 状态，端点在 DB/Redis 失败时也不返回 5xx | DB 挂了 pod 仍被判定 Ready，继续接流量报 500 |
| P1 | PG 实例**没有 Prometheus 指标** | `monitoring.enablePodMonitor: false`，只有 operator 的 PodMonitor | 连接数、复制延迟、锁、磁盘无告警 |
| P1 | Redis **单实例、无持久化、无 HA** | 1 replica、`--appendonly no`、无 PVC、无 Sentinel | 重启丢缓存；业务缓存扩大后可能打穿 DB |

### 关键数字（先记住这些）

| 指标 | 当前值 |
|---|---|
| `compassio` 数据库大小 | **8.8 MB** |
| 连接数 / `max_connections` | **16 / 100**（compassio 7 条，全部 idle） |
| 主库资源 | CPU 11m / 1 core，内存 581 MiB / 2 GiB |
| 备库复制 | **async，lag 0 字节** |
| WAL | 576 MB / 5 GiB |
| 备份 | 30 份每日全备，最近 12h 前，保留 30 天，WAL 连续归档 |
| Redis | 1.07 MB / 384 MB，**2 个 key**，命中率 99.15%，0 eviction |
| Redis 持久化 | AOF **关闭**，无 PVC，单 master |
| 应用 | 2 pod × 2 uvicorn worker，默认连接池上限 60 |
| 实测 failover | DB 层 **约 7 秒**；应用 pod **约 44 秒** 才 Ready |
| 控制平面证书 | 2027-10-03 到期（与本主题无关，但排障时会遇到） |

---

## 1. 现网基线（实测）

### 1.1 拓扑

```
compassio namespace
├── compassio-backend   Deployment 2/2   FastAPI + uvicorn 2 workers
├── compassio-frontend  Deployment 2/2
├── compassio-redis     Deployment 1/1   redis:7-alpine，单实例
└── frpc

cnpg-system namespace
├── cnpg-controller-manager  Deployment 1/1（CNPG 1.22.0）
└── pg16-ceph                Cluster 2 instances
    ├── pg16-ceph-4  primary   10.244.19.82  worker03
    └── pg16-ceph-3  replica   10.244.30.176 worker02
    Services:
      pg16-ceph-rw  -> 10.244.19.82:5432  (只指向主库)
      pg16-ceph-ro  -> 10.244.30.176:5432 (只指向备库)
      pg16-ceph-r   -> 两个都指向
```

应用连接串（已脱敏）：

```
DATABASE_URL=postgresql+asyncpg://***:***@pg16-ceph-rw.cnpg-system.svc:5432/compassio
REDIS_URL=redis://compassio-redis.compassio.svc:6379/0
```

### 1.2 PostgreSQL 实测

| 项目 | 值 |
|---|---|
| 版本 | PostgreSQL 16.15 |
| 实例 | 2（1 primary + 1 replica） |
| 主/备 | `pg16-ceph-4`（worker03）/ `pg16-ceph-3`（worker02） |
| 复制模式 | **async**（`sync_state=async`，`minSyncReplicas=0`） |
| 复制延迟 | 0 字节（稳态） |
| 数据库 | `compassio` 8.8 MB、`n8n` 17 MB、`deeptutor` 7.7 MB、`mytest` 7.7 MB |
| 连接 | 总数 16，active 2（其中 1 个是 WAL sender），idle 8，idle in transaction 0 |
| `max_connections` | 100 |
| `shared_buffers` | 160 MB |
| `work_mem` | 4 MB |
| `effective_cache_size` | 5 GB |
| 缓存命中 | `compassio` 99.93%，`n8n` 99.34% |
| 锁等待 | 0 |
| WAL | 576 MB / 5 GiB |
| 归档 | 58 成功 / **1 失败**（发生在 failover 时刻） |
| PDB | `pg16-ceph-primary` minAvailable=1，allowed disruptions=0 |
| 反亲和 | `podAntiAffinityType: preferred`（不是 required） |
| 监控 | `enablePodMonitor: false`（PG 实例指标未采集） |
| 连接池组件 | `poolerIntegrations: {}`（**没有 PgBouncer**） |

### 1.3 Redis 实测

| 项目 | 值 |
|---|---|
| 版本/镜像 | Redis 7 Alpine |
| 部署 | Deployment 1 replica，无 StatefulSet、无 PVC |
| 启动参数 | `--maxmemory 384mb --maxmemory-policy allkeys-lru --appendonly no` |
| 持久化 | AOF 关闭；RDB 配置存在，但容器无卷，重启即丢 |
| 高可用 | 单 master，无 Sentinel / Cluster / 副本 |
| 认证 | 无密码，仅 ClusterIP |
| 内存 | 1.07 MB / 384 MB，峰值 1.13 MB |
| Key 数 | **2 个**：`compassio:deps:llm`、`compassio:deps:llm:ping` |
| 命中率 | hits 28,413 / misses 243 ≈ **99.15%** |
| eviction | 0 |
| 连接/命令 | 8,701 次连接，57,694 条命令（生命周期累计） |
| 过期 key | 246 |

> 说明：Redis 当前**几乎只用于依赖健康缓存**；业务缓存（`compassio:next:*`、`compassio:llm_sched:*`、`compassio:login:fail:*`）在当前时刻没有活跃 key，但代码里已经实现。

### 1.4 应用实测

- 2 个 backend pod，每个 pod 内 **2 个 uvicorn worker**（日志可见 parent + 2 server process）。
- `build_engine()` 只传 `future=True`，没有 `pool_size/max_overflow/pool_timeout/pool_recycle/pool_pre_ping`：
  - SQLAlchemy asyncpg 默认 `pool_size=5`、`max_overflow=10`、`pool_timeout=30s`、`pool_recycle=-1`、`pool_pre_ping=False`。
  - 每个进程最多 15 条连接；2 pod × 2 worker = **最多 60 条**。
- `lifespan` 启动时直接 `async with engine.begin()`，**没有重试**；DB 不可用则进程退出。
- `/api/health/live` 零依赖，设计正确。
- `/api/health` 会检查 DB/Redis，但**始终返回 HTTP 200**；readinessProbe 只看状态码，因此 DB 挂了 pod 仍 Ready。
- `/api/health` 每次都会调用 `_refresh_user_metrics(db)`，执行 `SELECT role, count(*) FROM users GROUP BY role`；readiness 每 10 秒一次，2 pod ≈ **17,280 次/天**，与 `users` 表 `seq_scan=17,469` 高度吻合。
- `list_accounts` 没有分页，`q` 使用 `ILIKE '%...%'` 同时匹配 `username/real_name/phone`，B-tree 索引无法使用。
- `resolve_provider` 每次依赖刷新/LLM 调用都查 `llm_configs`（空表），与 `llm_configs` 的 6,985 次 seq scan 吻合。

### 1.5 一次真实 failover 复盘（2026-11-05 09:37 本地时间）

| 时间（UTC） | 事件 |
|---|---|
| 01:36:41 | backend pod `...-jhwrf` 启动（滚动/重建） |
| 01:37:26 | CNPG 检测到当前主库 `pg16-ceph-3` 不健康，发起 failover，目标 `pg16-ceph-4` |
| 01:37:29 | backend 启动时 `engine.begin()` 连接 `pg16-ceph-rw` 被拒：`ConnectionRefusedError`，应用启动失败退出 |
| 01:37:32 | 归档器记录一次失败；新主 `currentPrimaryTimestamp` |
| 01:37:33 | CNPG 设置新主标签；`pg16-ceph-3` 以副本身份重建 |
| 01:37:34 | backend 容器退出（exit 0, Completed） |
| 01:37:47 | backend 容器重新运行 |
| 01:38:10 | backend pod Ready |

结论：

- **数据库层 RTO ≈ 7 秒**（01:37:26 → 01:37:33）。
- **该 pod 的应用层 RTO ≈ 44 秒**（01:37:26 → 01:38:10），主要耗在启动失败 + 重启 + 重新初始化。
- 另一个 backend pod 全程 Ready，但 `/api/health` 永远 200，所以它可能一边 Ready 一边对 DB 请求报 500。
- **RPO**：异步复制，稳态 lag 0；failover 瞬间可能丢最近未复制的事务。本次流量极低，实际可能为 0，但不能作为承诺。

### 1.6 现有备份

```
ScheduledBackup: pg16-ceph-daily-full
  调度: 每天 02:00
  方式: barmanObjectStore -> s3://pg-backups/ (http://10.0.0.31:7480)
  保留: 30d
  目标: prefer-standby
  最近成功: 2026-11-05 02:00
  最近可用恢复点: 2026-10-06
```

- 连续归档条件 `ContinuousArchiving=True`，`LastBackupSucceeded=True`。
- 30 份每日全备全部 `completed`。
- **没有恢复演练记录**；`pg_stat_archiver.failed_count=1` 需要告警。

### 1.7 观测缺口

| 缺口 | 现状 | 后果 |
|---|---|---|
| PG 实例指标 | 未开 PodMonitor | 连接数、复制延迟、锁、磁盘、WAL 无告警 |
| SQL 级统计 | 无 `pg_stat_statements` | 无法按 SQL 排序 |
| 慢日志 | `log_min_duration_statement=-1` | 无法回放慢 SQL |
| 执行计划 | 无 `auto_explain` | 事后看不到实际 plan |
| IO 计时 | `track_io_timing=off` | 无法判断 IO 瓶颈 |
| Redis 指标 | 无 exporter/ServiceMonitor | 内存、eviction、命中率无告警 |
| 连接池指标 | 无 | 无法区分应用等待 vs DB 慢 |
| 应用 5xx/延迟 | 有 ServiceMonitor + OTel | 有基础，但缺 DB/Redis 细分 |
| CNPG operator | 1 replica | operator 挂了自动 failover 失效 |

---

## 2. 面试题一：Redis 穿透、击穿、雪崩

### 2.1 三个概念（先用一句话说清）

| 问题 | 本质 | 典型现象 |
|---|---|---|
| **穿透** | 查**不存在**的数据，缓存永远不命中，请求全打到 DB | 随机 ID / 不存在的用户名被高频查询 |
| **击穿** | **单个热点 key 过期**瞬间，大量并发同时回源 | 热点配置/榜单过期，DB QPS 瞬间飙升 |
| **雪崩** | **大量 key 同时过期**或 **Redis 整体挂掉**，请求全打到 DB | 凌晨统一过期、Redis 重启、缓存层故障 |

### 2.2 Compassio 当前实际做了什么（代码级）

| 代码 | Key | TTL | 机制 | 对应防护 |
|---|---|---|---|---|
| `app/next_cache.py` | `compassio:next:{assessment_id}` | 300s | Redis 预取下一题；读后删除（一次性）；Redis 失败退进程内 LRU（500 条） | **击穿/雪崩的降级**、预取削峰 |
| `app/engine/checkpoint.py` | `compassio:llm_sched:{id}` | 2h | Redis + 本地 LRU，保存 LLM 检查点调度 | **Redis 故障降级** |
| `app/ratelimit.py` | `compassio:login:fail:{sha256}` | 窗口 TTL | `INCR + EXPIRE` 同事务；Redis 不可用则放行 | 登录暴破防护，不是缓存三防 |
| `app/main.py` | `compassio:deps:llm`、`:ping`、`:probe` | 30s 级 | Redis 共享健康值；`SET NX EX` 抢探活名额 | **跨进程单飞（singleflight）** |
| `app/llm/service.py` | 无缓存 | - | 每次查 `llm_configs`（空表） | 这是一个可优化点 |

**已经落地的：**

1. **雪崩/Redis 故障**：`next_cache`、`checkpoint` 都有本地 LRU fallback，Redis 挂了应用还能继续回答，不会把请求全部打到 DB。
2. **击穿（部分）**：`next_cache` 在 answer 后异步 **prefetch** 下一题，正常路径 `/next` 直接命中；`read_next` 是一次性消费，减少重复回源。
3. **单飞**：LLM 探活用 `SET NX EX`，2 pod × 2 worker 每个间隔只探活一次，避免重复打外部依赖。
4. **限流**：登录失败计数用 Redis 滑动窗口，Redis 挂了放行（可用性优先）。

**还没做的：**

- **穿透**：没有负缓存、没有 Bloom filter；随机用户名登录仍会查 DB（好在有登录限流）。
- **击穿**：`next_cache` 未命中时没有按 `assessment_id` 加 `SET NX` 锁；两个并发 `/next` 可能同时计算/调用 LLM。
- **雪崩**：TTL 是固定 300s / 2h，没有抖动；Redis 单点无 HA。
- **热点 key**：`deps:llm` 是热点，但没有本地多级缓存（只有 Redis 共享值 + 进程内节流）。
- **业务缓存**：当前没有把用户/班级/量表等读多写少数据放进 Redis，缓存三防还没有真正的业务战场。

### 2.3 落地方案（按优先级）

#### P0：先做“不引入新组件”的代码级防护

1. **穿透：负缓存 + 已有登录限流**
   - 登录/用户查询未命中时，写 `compassio:null:user:{sha256(username)}`，TTL 30–60s，值为 `1`。
   - 随机用户名攻击由 `ratelimit.py` 的登录失败计数兜底；如果未来有公开查询接口，再加 Bloom filter。
   - 注意：负缓存 TTL 要短，用户创建后要主动删 key。

2. **击穿：`next_cache` 未命中加单飞锁**
   - 复用 `main.py` 的 `SET NX EX` 模式：
     ```python
     lock_key = f"compassio:next:lock:{assessment_id}"
     got = await client.set(lock_key, "1", nx=True, ex=10)
     if not got:
         # 等 50-100ms 后重读，或直接走确定性规则，避免重复 LLM
         ...
     try:
         payload = await compute_next(...)
         await write_next(...)
     finally:
         await client.delete(lock_key)
     ```
   - 对 `/next` 这种用户可感知接口，锁等待要短（<200ms），拿不到锁就降级为规则引擎结果，不要让用户等 LLM。

3. **雪崩：TTL 抖动**
   - `next_cache`：`ttl = 300 + random.randint(0, 60)`。
   - `checkpoint`：`ttl = 7200 + random.randint(0, 600)`。
   - 这样即使一批学生同时开始测评，key 也不会同一秒集体过期。

4. **本地缓存继续保留**
   - 现有 LRU 500 条是很好的降级；建议把容量、TTL 做成配置，并加命中率指标 `compassio_next_cache_total{result}`。
   - 本地缓存只放“可重建、非敏感”的数据，避免多 pod 状态不一致。

#### P1：Redis 高可用与容量

- **如果 Redis 只做缓存/限流/调度**：单点可接受，但必须接受“重启后限流计数清零、调度重建”；建议至少加 **PVC + AOF everysec**，让限流/调度状态可恢复。
- **如果要把业务读缓存放进去**：上 **Redis Sentinel（1 主 2 从 + 3 Sentinel）** 或 Redis Cluster；应用连接串要支持 Sentinel（`redis+sentinel://`）或前置代理。
- 当前 `allkeys-lru` 会淘汰限流 key；如果内存吃紧，建议：
  - 缓存 key 用 `volatile-lru` + TTL；
  - **注意：Redis 的 `maxmemory` 与淘汰策略是实例级、不分 DB**——`SELECT 1` 换个 DB 一样会被 `volatile-lru` 淘汰。
    要隔离必须用**独立实例**（或至少独立 Redis 进程），或把限流/锁的状态做成可重建（重建时以 PG 为准）。
    换个 DB 号只是逻辑分区，不是资源隔离。
- 加密码/ACL + NetworkPolicy；当前无密码，同命名空间任何 pod 都能读写。

#### P2：业务缓存设计

- 先选读多写少、可容忍短暂不一致的数据：`scale_defs`、`classes`、`llm_configs`、用户基础信息。
- 统一封装 `get_or_set(key, ttl, loader)`：
  - 先读本地 LRU（可选）；
  - 再读 Redis；
  - 未命中加单飞锁；
  - 回源 DB；
  - 写 Redis（TTL + 抖动）；
  - 失败时返回 stale（如果允许）。
- 所有缓存写入必须带 TTL；禁止无 TTL 的业务 key。

### 2.4 代码示意：带单飞和抖动的 cache-aside

```python
import random
from redis.exceptions import RedisError

async def get_or_set_json(client, key: str, ttl: int, loader):
    # 1) 读缓存
    try:
        raw = await client.get(key)
        if raw is not None:
            return json.loads(raw)
    except RedisError:
        pass  # Redis 故障，直接回源

    # 2) 单飞锁，避免击穿
    lock = f"{key}:lock"
    got = False
    try:
        got = bool(await client.set(lock, "1", nx=True, ex=5))
    except RedisError:
        got = True  # Redis 挂了，退化为直接回源

    if not got:
        # 等一小会儿重读；仍没有再回源（或返回 stale）
        await asyncio.sleep(0.05)
        try:
            raw = await client.get(key)
            if raw is not None:
                return json.loads(raw)
        except RedisError:
            pass

    try:
        value = await loader()
        body = json.dumps(value, ensure_ascii=False)
        try:
            await client.set(key, body, ex=ttl + random.randint(0, max(1, ttl // 10)))
        except RedisError:
            pass
        return value
    finally:
        if got:
            try:
                await client.delete(lock)
            except RedisError:
                pass
```

### 2.5 面试口述版

> “Compassio 里我落地的是**两级缓存 + 单飞 + 优雅降级**。下一题预取用 Redis `compassio:next:{id}`，TTL 300 秒，读后删除；Redis 不可用时退进程内 LRU，所以 Redis 挂不会把压力全打到 DB。LLM 探活用 `SET NX EX` 做跨 worker 单飞，2 pod × 2 worker 每个间隔只探一次。登录失败限流用 `INCR+EXPIRE`。穿透目前还没做，下一步会加 30–60 秒的负缓存 + 现有登录限流兜底；击穿会给 `/next` 未命中加 `SET NX` 锁；雪崩下一步加 TTL 抖动和 Redis Sentinel/PVC。”

---

## 3. 面试题二：主库宕机、切换流程与 RTO

### 3.1 当前机制

- CNPG 管理 2 个实例，**自动 failover**：operator 检测主库不健康 → 选择最新副本 → 提升为新主 → 更新 `-rw` Service。
- `minSyncReplicas=0`、`maxSyncReplicas=0` → **异步复制**，RPO 不为 0。
- `failoverDelay=0` → 检测到就切，不额外等待。
- PDB `pg16-ceph-primary` minAvailable=1，allowed disruptions=0 → 主动驱逐时不会把主库打掉。
- `podAntiAffinityType: preferred` → 当前主备在 worker03/worker02，但不保证永远分开。
- CNPG operator 只有 **1 个副本** → operator 挂了，自动 failover 不会发生。

### 3.2 实测 RTO / RPO

| 指标 | 实测/当前值 | 说明 |
|---|---|---|
| DB failover RTO | **约 7 秒** | 01:37:26 检测 → 01:37:33 新主 label |
| 应用 pod RTO | **约 44 秒** | 01:37:26 → 01:38:10 Ready；启动失败 + 重启 |
| 另一个 pod | 全程 Ready | 但 health 永远 200，可能带病接流量 |
| RPO（failover） | 异步复制，稳态 lag 0；故障瞬间可能丢最近事务 | 不能承诺 0 |
| RPO（PITR） | ≤ 5 分钟 | `archive_timeout=5min`，WAL 归档 |
| 备份 RTO | 未演练 | 数据仅 8.8 MB，预估分钟级，但必须实测 |

> 面试时不要只说“RTO 30 秒”，要说清**哪一层**：DB 层 7 秒，应用层 44 秒，目标是把应用层压到 15–30 秒。

### 3.3 非计划 failover 值班流程

```bash
# 1) 确认集群状态
kubectl -n cnpg-system get cluster pg16-ceph -o wide
kubectl -n cnpg-system get pods -l cnpg.io/cluster=pg16-ceph -o wide
kubectl -n cnpg-system get endpoints pg16-ceph-rw pg16-ceph-ro

# 2) 确认谁是新主、复制是否恢复
kubectl -n cnpg-system exec pg16-ceph-4 -- \
  psql -U postgres -d postgres -c "select pg_is_in_recovery();"
kubectl -n cnpg-system exec pg16-ceph-4 -- \
  psql -U postgres -d postgres -c \
  "select client_addr,state,sync_state,pg_size_pretty(pg_wal_lsn_diff(sent_lsn,replay_lsn)) lag from pg_stat_replication;"

# 3) 看应用错误
kubectl -n compassio logs deploy/compassio-backend --since=10m | \
  grep -iE "connection|timeout|refused|pool|error" | tail -50

# 4) 必要时滚动重启应用（先确认新主已可写）
kubectl -n compassio rollout restart deploy/compassio-backend
kubectl -n compassio rollout status deploy/compassio-backend

# 5) 写测试
kubectl -n cnpg-system exec pg16-ceph-4 -- \
  psql -U postgres -d compassio -c \
  "create table if not exists _rto_probe(id serial primary key, ts timestamptz default now()); insert into _rto_probe default values; select count(*) from _rto_probe;"
```

判断：

- `pg_is_in_recovery()=false` 且 `pg16-ceph-rw` 指向它 → 新主已就绪。
- 如果 operator 没自动切（例如 operator 挂了），需要人工 promote。
- 如果两个实例都挂 → 走备份恢复（第 6 章）。

### 3.4 计划内 switchover 流程

```bash
# 1) 维护窗口，通知；确认备库 lag 接近 0
kubectl -n cnpg-system exec pg16-ceph-4 -- \
  psql -U postgres -d postgres -c \
  "select client_addr,state,sync_state,replay_lag from pg_stat_replication;"

# 2) 触发 switchover（需要 kubectl cnpg 插件）
kubectl cnpg promote pg16-ceph pg16-ceph-3

# 3) 观察
kubectl -n cnpg-system get cluster pg16-ceph -w
kubectl -n cnpg-system get pods -l cnpg.io/cluster=pg16-ceph -w

# 4) 验证新主可写、旧主变备
kubectl -n cnpg-system exec pg16-ceph-3 -- \
  psql -U postgres -d postgres -c "select pg_is_in_recovery();"

# 5) 应用冒烟：登录、列表、创建一条测评、读回
```

> `kubectl cnpg promote` 是 CNPG 的计划内切换方式；没有插件时先安装 krew 插件，或按 CNPG 文档用注解/API 操作。不要直接 `kubectl delete pod` 主库来“测试切换”，那会走非计划 failover。

### 3.5 应用侧必须改的 4 件事（RTO 从 44s 降到 15–30s）

1. **启动重试**：`lifespan` 里的 `engine.begin()` 加重试。
   ```python
   async def wait_for_db(engine, attempts=10):
       for i in range(attempts):
           try:
               async with engine.begin() as conn:
                   await conn.run_sync(Base.metadata.create_all)
                   await _apply_light_migrations(conn)
               return
           except Exception:
               if i == attempts - 1:
                   raise
               await asyncio.sleep(min(30, 2 ** i))
   ```
2. **连接池健康检查**：
   ```python
   create_async_engine(
       url,
       pool_size=5,
       max_overflow=5,
       pool_timeout=5,
       pool_recycle=300,
       pool_pre_ping=True,
       connect_args={"timeout": 5, "command_timeout": 30},
   )
   ```
   `pool_pre_ping` 让 failover 后的陈旧连接在 checkout 时被剔除。
3. **读请求重试**：对 `OperationalError`/`DBAPIError` 的幂等读做 1–2 次短重试；写请求不要盲目重试，除非有幂等键。
4. **readiness 返回 503**：DB 不可用时 `/api/health` 返回 503，让 kubelet 把 pod 摘掉；liveness 继续用零依赖的 `/api/health/live`。
   ```python
   if not db_ok:
       return JSONResponse(status_code=503, content={"db": False, "redis": redis_ok, "llm": llm_ok})
   ```
   如果不希望 DB 短暂抖动就摘流量，可以加 2–3 次确认/短 TTL 缓存，但不能永远 200。

### 3.6 RTO/RPO 提升路线

| 目标 | 动作 | 代价 |
|---|---|---|
| DB RTO < 15s | 保持 2 实例 + 自动 failover；operator 升到 2 副本 | 低 |
| 应用 RTO < 30s | 启动重试 + pool_pre_ping + readiness 503 + 读重试 | 低 |
| RPO=0 | 3 实例 + `minSyncReplicas=1`、`maxSyncReplicas=1`；或接受异步 RPO | 写延迟增加，副本故障时可能阻塞写 |
| 防止双实例同节点 | `podAntiAffinityType: required` + topologySpread | 需要 3 个可用节点 |
| 备份 RTO 可承诺 | 每季度恢复演练，记录实际耗时 | 需要演练环境/存储 |

> 对当前 8.8 MB 的库，异步复制 + 每日全备 + WAL 已经够用；如果业务不能接受丢最近几秒事务，再上同步复制。不要为了“架构好看”上 3 实例同步复制，先问 RPO 要求。

### 3.7 RTO/RPO 演练脚本（建议在 `mytest` 库做）

```bash
# 终端 1：持续写入，记录序号
while true; do
  kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d mytest -q -c \
    "insert into rto_probe(ts) values (clock_timestamp());" 2>/dev/null
  sleep 0.2
done

# 终端 2：记录开始时间，触发 switchover
date -u +%FT%TZ
kubectl cnpg promote pg16-ceph pg16-ceph-3

# 终端 3：观察 -rw endpoint 和写入恢复
watch -n1 'kubectl -n cnpg-system get endpoints pg16-ceph-rw -o jsonpath="{.subsets[*].addresses[*].ip}"'

# 恢复后统计
kubectl -n cnpg-system exec pg16-ceph-3 -- psql -U postgres -d mytest -c \
  "select count(*), max(ts) from rto_probe;"
```

记录：`T_switch_start`、`T_first_write_ok`、丢失的行数（RPO）、应用错误数。

### 3.8 面试口述版

> “我们的 PostgreSQL 是 CNPG 管的 2 实例，1 主 1 备，自动 failover。2026-11-05 真实切过一次：01:37:26 检测到主库不健康，01:37:33 新主就绪，**DB 层 RTO 约 7 秒**。但应用层因为启动时 `engine.begin()` 没有重试，pod 到 01:38:10 才 Ready，**应用 RTO 约 44 秒**。RPO 是异步复制，稳态 lag 0，但故障瞬间可能丢最近事务；要 RPO=0 就上 3 实例 + 同步复制。切换流程是：告警确认 → 看 CNPG 是否自动切 → 验证 `-rw` 端点和 `pg_is_in_recovery` → 应用重连/重启 → 写测试 → 复盘。下一步把启动重试、`pool_pre_ping`、readiness 503 加上，把应用 RTO 压到 30 秒内。”

---

## 4. 面试题三：连接池打满

### 4.1 现象

应用侧：

- 接口 p99 飙升，大量请求超时/500。
- 日志出现：
  - `TimeoutError: QueuePool limit of size 5 overflow 10 reached, connection timed out, timeout 30`
  - `asyncpg.exceptions.TooManyConnectionsError`
  - `FATAL: sorry, too many clients already`
- 进程 CPU 不高，但协程/线程都在等连接。
- 健康检查可能仍然 200（本集群就是），因为 `/api/health` 不返回 503。

数据库侧：

- `pg_stat_activity` 连接数接近/达到 `max_connections`。
- 大量 `idle`（池子占着不用）或 `idle in transaction`（应用没提交）。
- 大量 `active` + `wait_event`（锁/IO），说明 DB 慢。
- `pg_stat_database.numbackends` 高，`pg_locks` 有未授予锁。

### 4.2 先分清“应用池满”还是“数据库慢”

| 观察 | 结论 |
|---|---|
| DB 连接数接近 `max_connections`，但大部分 `idle`，应用在等连接 | **应用池太小/池泄漏/worker 太多** |
| DB 连接数不高，应用仍超时，DB `active` 很多且 `wait_event` 非空 | **DB 慢/锁/IO** |
| 大量 `idle in transaction` | **应用事务没提交/没回滚**，连接被占住 |
| `pg_stat_activity` 有长查询，`pg_locks` 未授予 | **慢 SQL/锁等待** |
| 应用连接数正常，但 CPU 打满、事件循环阻塞 | **应用自身**（同步调用、GIL、bcrypt、JSON 大对象） |
| `max_connections` 已满，报 `too many clients` | **池总量超了**，需要 PgBouncer 或调小 pool |

### 4.3 本集群连接账本

- `max_connections=100`。
- 当前总连接 16：compassio 7（全 idle）、n8nuser 1 idle、replication 1、psql/本地若干。
- 应用：2 pod × 2 uvicorn worker = **4 个进程**；每个进程默认池 5+10=15 → **理论上限 60**。
- 当前实际 7 条，说明连接是懒创建，低峰没有打满。
- 但连接预算是全集群共享的：`compassio`、`n8n`、`deeptutor`、`mytest` 在同一个 PG 实例上。
- 扩容临界点：
  - 默认 15/进程：**3 pod = 90**，已经接近 100。
  - 如果 pool 改成 5+5=10/进程：**5 pod = 100**，仍无余量。
  - 结论：**在没有 PgBouncer 的情况下，backend 不要超过 3 个 pod**；超过就上 Pooler。

### 4.4 定位命令（本集群可直接用）

```bash
# 1) 总量 vs 上限
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select count(*) total, count(*) filter (where state='active') active,
          count(*) filter (where state='idle') idle,
          count(*) filter (where state like 'idle in transaction%') idle_in_tx
   from pg_stat_activity;"
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "show max_connections;"

# 2) 按用户/库/客户端/状态分组
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select usename,datname,application_name,client_addr,state,count(*)
   from pg_stat_activity group by 1,2,3,4,5 order by 6 desc;"

# 3) 长查询 / 等待事件
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select pid, now()-query_start age, state, wait_event_type, wait_event,
          left(query,120)
   from pg_stat_activity
   where state <> 'idle' order by age desc nulls last limit 10;"

# 4) 锁
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select * from pg_locks where not granted;"

# 5) 应用日志
kubectl -n compassio logs deploy/compassio-backend --since=30m | \
  grep -iE "QueuePool|TimeoutError|too many clients|asyncpg|connection" | tail -50
```

### 4.5 修复方案

#### 立即（P0）

```python
create_async_engine(
    url,
    pool_size=5,
    max_overflow=5,
    pool_timeout=5,
    pool_recycle=300,
    pool_pre_ping=True,
    connect_args={"timeout": 5, "command_timeout": 30},
)
```

- 每个 worker 上限 10 条；4 个 worker = 40 条；给 n8n/管理预留 60。
- `pool_timeout=5`：池满时快速失败，不要堆 30 秒。
- `pool_pre_ping=True`：failover 后剔除死连接。
- 给 pool 加指标：`checkedout`、`overflow`、`timeout`，暴露到 `/metrics`。

#### 数据库侧超时（P0）

```sql
ALTER ROLE compassio SET statement_timeout = '30s';
ALTER ROLE compassio SET lock_timeout = '5s';
ALTER ROLE compassio SET idle_in_transaction_session_timeout = '60s';
```

或在 CNPG `spec.postgresql.parameters` 里全局设置。防止一个慢查询/未提交事务占住连接。

#### PgBouncer（P1，连接数真正上来时）

CNPG 1.22 原生支持 `Pooler`：

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pg16-ceph-pooler-rw
  namespace: cnpg-system
spec:
  cluster:
    name: pg16-ceph
  instances: 2
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "20"
      max_prepared_statements: "100"
```

应用连接串改为：

```
postgresql+asyncpg://***:***@pg16-ceph-pooler-rw.cnpg-system.svc:5432/compassio
```

注意：

- PgBouncer **transaction 模式**下，asyncpg 的 prepared statement 需要 PgBouncer 1.21+ 的 `max_prepared_statements`，或给 asyncpg 设 `statement_cache_size=0`。上线前先在测试库压测。
- 事务模式不保留 session 级 `SET`；应用不要依赖 session 状态。
- Pooler 也要 2 副本 + PDB + 监控。

#### 扩容策略（P1）

- 不要只按 CPU 做 HPA；连接数是硬约束。
- HPA 上限 = `(max_connections × 0.7 - 其他应用预留) / 每 pod 连接上限`。
- 当前 `100 × 0.7 = 70`，减 n8n 等预留 10，剩 60；每 pod 10 条 → **最多 6 pod**（有 PgBouncer 后可更多）。
- 更好的做法：HPA 按 RPS/延迟，设置 `maxReplicas`；连接层用 PgBouncer 吸收。

#### 读写分离（P2）

- `pg16-ceph-ro` 指向备库，可用于报表/列表等只读接口。
- 异步复制有延迟，不能用于“写后立刻读”的场景。
- 当前负载很低，暂时不需要；数据量/报表增长后再做。

### 4.6 面试口述版

> “连接池打满的现象是接口 p99 飙升、`QueuePool limit ... reached`、`too many clients`，但 CPU 不一定高。定位分两步：先看应用日志/指标是不是在等连接；再看 `pg_stat_activity`：如果连接数接近 `max_connections` 且大量 `idle`，是应用池太大/泄漏/worker 太多；如果连接数不高但 `active` 多、`wait_event` 非空，是 DB 慢或锁；如果大量 `idle in transaction`，是应用没提交。我们当前 `max_connections=100`，总连接 16，compassio 7 条 idle；但应用是 2 pod × 2 worker，默认 5+10，理论最多 60，3 个 pod 就 90，所以我在代码里把 pool 调成 5+5、加 `pool_pre_ping` 和 `pool_timeout`，并在扩容前上 CNPG 的 PgBouncer Pooler。”

---

## 5. 面试题四：慢查询定位到 SQL 和索引

### 5.1 当前最大的问题：没有观测

实测：

```
shared_preload_libraries = ""        -- pg_stat_statements 未加载
log_min_duration_statement = -1ms    -- 慢日志关闭
track_io_timing = off                -- 无 IO 计时
pg_stat_statements installed_version = 空
```

所以**现在无法回答“哪条 SQL 慢”**。第一步不是猜索引，而是打开观测。

### 5.2 开启观测（CNPG 1.22，维护窗口执行）

```bash
kubectl -n cnpg-system patch cluster pg16-ceph --type merge -p '
{
  "spec": {
    "postgresql": {
      "parameters": {
        "shared_preload_libraries": "pg_stat_statements,auto_explain",
        "pg_stat_statements.max": "10000",
        "pg_stat_statements.track": "all",
        "log_min_duration_statement": "500ms",
        "track_io_timing": "on",
        "auto_explain.log_min_duration": "1s",
        "auto_explain.log_analyze": "on",
        "auto_explain.log_buffers": "on",
        "auto_explain.log_plan": "on"
      }
    }
  }
}'
```

注意：

- 这会触发 CNPG 滚动重启；当前 `primaryUpdateMethod: restart`，可能有一次主备切换，**必须在维护窗口做**。
- 重启后在各业务库创建扩展：
  ```sql
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
  ```
- `auto_explain` 不需要 `CREATE EXTENSION`，但必须在 `shared_preload_libraries` 里。
- 验证：
  ```sql
  SHOW shared_preload_libraries;
  SELECT * FROM pg_stat_statements LIMIT 1;
  ```

### 5.3 找 Top SQL

```sql
-- 按总耗时排序（最值得优化）
SELECT queryid,
       calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows,
       shared_blks_read,
       shared_blks_hit,
       temp_blks_written,
       left(query, 200) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'compassio')
ORDER BY total_exec_time DESC
LIMIT 20;

-- 按单次平均耗时排序（最慢的单条）
SELECT queryid, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round(max_exec_time::numeric, 2) AS max_ms,
       left(query, 200) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'compassio')
ORDER BY mean_exec_time DESC
LIMIT 20;

-- 按调用次数排序（高频小查询也值得看）
SELECT queryid, calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       left(query, 200) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'compassio')
ORDER BY calls DESC
LIMIT 20;
```

补充：

- `pg_stat_activity` 抓正在跑的：
  ```sql
  SELECT pid, now() - query_start AS age, state,
         wait_event_type, wait_event, left(query, 200)
  FROM pg_stat_activity
  WHERE state <> 'idle'
  ORDER BY age DESC NULLS LAST;
  ```
- `log_min_duration_statement=500ms` 后，慢 SQL 会进 PostgreSQL 日志；用 `kubectl logs pg16-ceph-4` 或 Loki 查。
- `auto_explain` 会把慢 SQL 的实际执行计划写日志，适合抓“偶发但慢”的查询。

### 5.4 EXPLAIN 分析

对目标 SQL：

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT ...;
```

重点看：

| 现象 | 含义 | 动作 |
|---|---|---|
| `Seq Scan` on 大表 + `rows` 很大 | 全表扫描 | 加索引 / 改查询 |
| `rows=1` 但 `actual rows=100000` | 统计信息不准 | `ANALYZE`，调 autovacuum |
| `loops` 很大 + `actual time` 高 | N+1 / 嵌套循环 | 改 JOIN / 批量查询 |
| `Buffers: shared read` 很大 | 缓存未命中/IO 多 | 加索引、加内存、优化查询 |
| `Sort Method: external merge` | 排序落盘 | 调 `work_mem` 或加索引 |
| `Hash Join` 大 + `temp` 大 | 内存不足 | 调 `work_mem` |
| `Rows Removed by Filter` 很大 | 索引选择性差 | 建更合适的复合/部分索引 |

对 DML 的 `EXPLAIN ANALYZE` 要放在事务里回滚：

```sql
BEGIN;
EXPLAIN (ANALYZE, BUFFERS) UPDATE ...;
ROLLBACK;
```

### 5.5 索引分析

```sql
-- 哪些表在全表扫描、扫描了多少行
SELECT schemaname, relname, seq_scan, seq_tup_read,
       idx_scan, n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_stat_user_tables
ORDER BY seq_tup_read DESC
LIMIT 20;

-- 哪些索引从来没被用过
SELECT schemaname, relname, indexrelname, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC
LIMIT 20;

-- 表膨胀（需要 pgstattuple）
SELECT * FROM pgstattuple('public.users');

-- 建索引进度
SELECT * FROM pg_stat_progress_create_index;
```

建索引原则：

- 用 `CREATE INDEX CONCURRENTLY`，避免锁表；CNPG 会复制到备库。
- 先确认 `EXPLAIN` 真的会用，不要凭感觉堆索引。
- 复合索引顺序按“等值列在前、范围列在后”。
- `ILIKE '%x%'` 这种前置通配，B-tree 无效；用 `pg_trgm` GIN：
  ```sql
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  CREATE INDEX CONCURRENTLY ix_users_username_trgm
    ON users USING gin (username gin_trgm_ops);
  CREATE INDEX CONCURRENTLY ix_users_real_name_trgm
    ON users USING gin (real_name gin_trgm_ops);
  CREATE INDEX CONCURRENTLY ix_users_phone_trgm
    ON users USING gin (phone gin_trgm_ops);
  ```
- `role`/`class_id` 过滤可加：
  ```sql
  CREATE INDEX CONCURRENTLY ix_users_role ON users(role);
  CREATE INDEX CONCURRENTLY ix_users_class_id ON users(class_id);
  CREATE INDEX CONCURRENTLY ix_users_role_class ON users(role, class_id);
  ```

### 5.6 现网已经看到的三个具体问题

#### 问题 1：readiness 探针每次全表扫 `users`

- `/api/health` 每次调用 `_refresh_user_metrics(db)`：
  ```sql
  SELECT role, count(*) FROM users GROUP BY role;
  ```
- readiness 每 10 秒一次，2 pod ≈ **17,280 次/天**；实测 `users` `seq_scan=17,469`，几乎完全吻合。
- `users` 当前 904 行、408 kB，单次很快；但用户涨到 10 万后，这个探针会变成定时炸弹。
- 修复：
  - 把 `_refresh_user_metrics` 从 `/api/health` 移走；
  - 用后台任务每 60 秒刷新一次，或用户增删改时更新；
  - readiness 只做 `SELECT 1`；
  - 指标可以用缓存值，允许 60 秒延迟。

#### 问题 2：账号列表无分页 + 前置通配

- `list_accounts` 当前没有 `LIMIT/OFFSET`，一次返回全部匹配用户。
- `q` 使用：
  ```sql
  username ILIKE '%q%' OR real_name ILIKE '%q%' OR phone ILIKE '%q%'
  ```
  B-tree `ix_users_username` 无法使用；`idx_scan=0` 与此一致。
- 修复：
  - 加 `page/page_size`，默认 50，最大 200；
  - 需要模糊搜索就上 `pg_trgm` GIN；
  - 如果只是精确登录，`auth.py` 的 `WHERE username = $1` 会走 `ix_users_username`，不受影响。

#### 问题 3：`llm_configs` 空表被反复扫描

- `resolve_provider` 每次依赖刷新/LLM 调用都执行：
  ```sql
  SELECT * FROM llm_configs WHERE is_active = true AND is_default = true;
  ```
- 表 0 行，但实测 `seq_scan=6,985`，与 2 pod × 每 30 秒刷新 ≈ 5,760/天 + LLM 请求吻合。
- 修复：
  - 在进程内缓存 provider 配置（TTL 30–60 秒）；
  - 管理员修改 LLM 配置时主动失效缓存；
  - 空表查询本身不贵，但没必要每 30 秒打一次 DB。

#### 补充：统计信息

- `last_autoanalyze` 为空，`llm_configs` `reltuples=-1`（从未分析）。
- 建议：
  ```sql
  ANALYZE public.users;
  ANALYZE public.llm_configs;
  ```
  并调低小表的 autovacuum 阈值，或对大表单独设置。

### 5.7 面试口述版

> “先开观测，不要凭感觉加索引。我们现网之前 `shared_preload_libraries` 是空的、`log_min_duration_statement=-1`，所以根本不知道哪条 SQL 慢。第一步在 CNPG 里开 `pg_stat_statements` + `auto_explain` + `log_min_duration_statement=500ms` + `track_io_timing=on`，重启后在业务库 `CREATE EXTENSION`。然后用 `pg_stat_statements` 按 `total_exec_time/mean_exec_time/calls` 排序拿 `queryid`，用 `EXPLAIN (ANALYZE, BUFFERS)` 看 Seq Scan、actual rows、loops、buffers、sort/hash spill；再结合 `pg_stat_user_tables.seq_scan/seq_tup_read` 和 `pg_stat_user_indexes.idx_scan=0` 找缺失或未用索引。现网已经发现 `users` 904 行被 seq scan 17,469 次，根因之一是 readiness 每 10 秒调 `_refresh_user_metrics` 做 `GROUP BY role`，加上账号列表无分页、`ILIKE '%q%'` 前置通配。先把探针里的全表扫移走，再加分页和 `pg_trgm` GIN 索引。”

---

## 6. 备份与恢复演练

### 6.1 现状

- 每日 02:00 全备，保留 30 天，WAL 连续归档，目标 `prefer-standby`。
- 最近成功：2026-11-05 02:00；30 份全备全部 completed。
- `pg_stat_archiver` 有 1 次失败（failover 时刻），需要告警但不能只看“最近成功”。
- **恢复从未演练**；这是最大的“看起来有备份”风险。

### 6.2 恢复演练（CNPG 1.22，恢复到新集群，不动生产）

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg16-ceph-restore
  namespace: cnpg-system
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  storage:
    size: 10Gi
    storageClass: ceph-rbd-sc
  walStorage:
    size: 5Gi
    storageClass: ceph-rbd-sc
  enableSuperuserAccess: true
  superuserSecret:
    name: pg-superuser-secret
  bootstrap:
    recovery:
      source: pg16-ceph
      # 可选：恢复到指定时间点
      # recoveryTarget:
      #   targetTime: "2026-11-05 12:00:00+00"
  externalClusters:
    - name: pg16-ceph
      barmanObjectStore:
        destinationPath: s3://pg-backups/
        endpointURL: http://10.0.0.31:7480
        s3Credentials:
          accessKeyId:
            name: pg-backup-s3-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: pg-backup-s3-creds
            key: ACCESS_SECRET_KEY
        serverName: pg16-ceph
        wal:
          maxParallel: 2
```

步骤：

```bash
# 1) 记录开始时间
date -u +%FT%TZ

# 2) 应用
kubectl apply -f pg16-ceph-restore.yaml

# 3) 等待 Ready
kubectl -n cnpg-system get cluster pg16-ceph-restore -w
kubectl -n cnpg-system get pods -l cnpg.io/cluster=pg16-ceph-restore -w

# 4) 记录 Ready 时间，计算 RTO
date -u +%FT%TZ

# 5) 校验数据
kubectl -n cnpg-system exec pg16-ceph-restore-1 -- \
  psql -U postgres -d compassio -c \
  "select 'users' t, count(*) from users
   union all select 'assessments', count(*) from assessments
   union all select 'responses', count(*) from responses;"

# 6) 用恢复库跑一次应用冒烟（临时改 DATABASE_URL 到 restore 的 rw service）
# 7) 记录 RTO/RPO，清理
kubectl -n cnpg-system delete cluster pg16-ceph-restore
kubectl -n cnpg-system delete pvc -l cnpg.io/cluster=pg16-ceph-restore
```

验收：

- 恢复集群 `Ready`；
- 关键表行数与生产一致（或与备份时间点一致）；
- 应用能登录、能读列表、能创建一条测评；
- 记录 **RTO**（开始恢复 → Ready + 冒烟通过）和 **RPO**（备份时间点/最后一次 WAL 与故障时间差）。

### 6.3 备份告警

至少加：

| 告警 | 条件 |
|---|---|
| 备份过期 | 最近成功备份 > 26h |
| 归档失败 | `pg_stat_archiver.failed_count` 增加 |
| 连续归档断开 | `ContinuousArchiving=False` |
| 恢复点过旧 | `firstRecoverabilityPoint` 超过 24h |
| 存储容量 | S3 bucket 使用率 > 80% |

### 6.4 面试口述版

> “备份不是‘有任务’就行，要能恢复。我们是 CNPG 每日全备 + WAL 连续归档，保留 30 天，最近一次成功；但恢复还没演练，这是我要补的。演练会新建一个 `pg16-ceph-restore` 集群，从同一个 barmanObjectStore 恢复，记录 RTO/RPO，跑行数校验和应用冒烟，再删掉。只有演练过，RTO 才敢对外承诺。”

---

## 7. 容量规划

### 7.1 当前用量

| 资源 | 当前 | 上限/容量 | 使用率 |
|---|---|---|---|
| `compassio` DB | 8.8 MB | 10 GiB PVC | < 0.1% |
| WAL | 576 MB | 5 GiB | 11.5% |
| 连接 | 16 | 100 | 16% |
| PG 主库 CPU | 11m | 1 core | 1.1% |
| PG 主库内存 | 581 MiB | 2 GiB | 29% |
| Redis 内存 | 1.07 MB | 384 MB | 0.3% |
| Redis key | 2 | - | - |
| Backend CPU | 8–10m ×2 | 500m ×2 | ~2% |
| Backend 内存 | 325–367 MiB ×2 | 768 MiB ×2 | ~46% |
| 节点内存 | 44%–72% | - | 有余量 |

结论：**当前瓶颈不是存储和 CPU，而是连接预算、failover 应用恢复、观测能力**。

### 7.2 规划公式

**连接数：**

```
总连接 = Σ(每个进程 pool_size + max_overflow) × 进程数
       + 其他应用 + 管理/监控 + 复制
安全线 < max_connections × 70%
```

当前：

- 4 个进程 × 15 = 60；
- 其他应用/管理约 40；
- 100 的上限已经比较紧。

调整后：

- 4 × 10 = 40；
- 留 60 给其他；
- 3 pod 时 6 进程 × 10 = 60，仍可；
- 4 pod 时 8 × 10 = 80，需 PgBouncer。

**存储：**

```
数据盘 >= 当前 DB × 12 个月增长 × 2（余量）
WAL 盘 >= 峰值 WAL 生成速率 × 最长归档延迟 + 2 GB
```

当前 8.8 MB，10 GiB 数据盘足够；WAL 5 GiB 也足够，但要监控 `pg_wal` 和归档延迟。

**备份：**

```
备份存储 ≈ 全备大小 × 保留份数 + WAL 归档 × 保留天数
```

当前 DB 很小，成本可忽略；主要是 WAL 和 S3 生命周期。

### 7.3 12 个月预测

| 场景 | DB 大小 | 连接峰值 | 动作 |
|---|---|---|---|
| 平稳（2x） | ~18 MB | ~30 | 不需要扩容，补观测 |
| 增长（10x） | ~90 MB | ~60 | 加 PgBouncer，连接池调优 |
| 爆发（100x） | ~900 MB | 100+ | 加 PG 实例/垂直扩容，读写分离，HPA + Pooler |
| 只读报表 | - | - | 用 `pg16-ceph-ro`，加索引 |

当前数据量太小，**不要过度设计**；重点是把 10x 场景的连接和 failover 处理好。

### 7.4 扩容触发条件

| 指标 | 阈值 | 动作 |
|---|---|---|
| 连接使用率 | > 70% 持续 5 分钟 | 调 pool / 上 PgBouncer |
| DB 磁盘 | > 70% | 扩 PVC（Ceph RBD 支持在线扩容） |
| WAL 盘 | > 70% | 扩 WAL PVC / 检查归档/复制槽 |
| PG CPU | > 70% 持续 10 分钟 | 垂直扩容或加只读副本 |
| 复制延迟 | > 10s | 查网络/IO/大事务 |
| 慢查询 p99 | > 500ms | 按第 5 章定位 |
| 备份时长 | > 30 分钟 | 检查数据量/S3 带宽 |
| 备份年龄 | > 26h | 立即排查 |

### 7.5 面试口述版

> “容量规划先看连接，不是先看磁盘。我们 DB 只有 8.8 MB，10 GiB 盘用了不到 0.1%，但 `max_connections=100`，应用 2 pod × 2 worker，默认池 5+10，理论 60 条，3 个 pod 就 90，所以连接是第一个瓶颈。我的做法是：pool 调到 5+5、加 `pool_pre_ping`、按 70% 安全线算 HPA 上限，超过 4 个 pod 就上 PgBouncer；存储按 12 个月增长和 WAL 峰值留 2 倍余量，Ceph RBD 可以在线扩；备份按 30 天全备 + WAL 算。每季度复盘一次增长曲线。”

---

## 8. 观测与告警补齐

### 8.1 PostgreSQL

- 开启 `monitoring.enablePodMonitor: true`（CNPG 会自动创建 PodMonitor），或手写 PodMonitor 抓 9187。
- 必看指标：
  - `cnpg_cluster_ready`
  - `cnpg_pg_replication_lag`
  - `cnpg_pg_stat_activity_count{state=...}`
  - `cnpg_pg_database_size_bytes`
  - `cnpg_pg_stat_archiver_failed`
  - `cnpg_pg_postmaster_start_time`
- 建议告警：
  - 集群 Not Ready；
  - 复制延迟 > 10s；
  - 连接数 / max_connections > 70%；
  - 磁盘 > 70%；
  - 归档失败；
  - 备份超过 26h。

### 8.2 Redis

- 部署 `oliver006/redis_exporter`（sidecar 或独立 Deployment），加 ServiceMonitor。
- 必看指标：
  - `redis_up`
  - `redis_memory_used_bytes` / `redis_memory_max_bytes`
  - `redis_evicted_keys_total`
  - `redis_keyspace_hits_total` / `misses_total`
  - `redis_connected_clients`
  - `redis_rejected_connections_total`
- 告警：
  - `redis_up == 0`；
  - 内存 > 80%；
  - eviction > 0；
  - 命中率 < 90%；
  - 连接数异常。

### 8.3 应用

- 已有 ServiceMonitor 和 OTel；补充：
  - SQLAlchemy pool：`checkedout`、`overflow`、`timeout`、`size`；
  - DB 查询延迟（按 operation/resource）；
  - Redis 命令延迟/错误；
  - `compassio_dependency_up{db,redis,llm}`；
  - HTTP 5xx、p99。
- 日志：Loki 已存在；把 slow query 日志、应用错误、failover 事件统一采集。

### 8.4 CNPG operator

- 当前 1 副本；建议 2 副本（leader election），避免 operator 挂了自动 failover 失效。
- 给 operator 加 PDB 和监控。

---

## 9. 实施路线图（P0/P1/P2）

### P0（本周，低风险，先止血）

| # | 动作 | 影响 | 回滚 |
|---|---|---|---|
| 1 | `build_engine` 加 `pool_size=5/max_overflow=5/pool_timeout=5/pool_recycle=300/pool_pre_ping=True` | 连接更可控，failover 后少报错 | 改回默认 |
| 2 | `lifespan` 加 DB 启动重试（指数退避） | 应用 RTO 44s → 15–30s | 代码回滚 |
| 3 | `/api/health` DB 失败返回 503；移除 `_refresh_user_metrics` | readiness 真正生效，去掉每 10s 全表扫 | 代码回滚 |
| 4 | 开启 `pg_stat_statements` + `auto_explain` + 慢日志 + `track_io_timing` | 首次有 SQL 级观测 | CNPG 参数回滚 + 重启 |
| 5 | 开启 CNPG PodMonitor | 有连接/复制/磁盘指标 | 关闭 |
| 6 | 部署 Redis exporter + ServiceMonitor | 有 Redis 指标 | 删除 |
| 7 | 备份失败/过期告警 | 备份可见 | 删除规则 |

### P1（2–4 周）

| # | 动作 | 说明 |
|---|---|---|
| 1 | 账号列表分页 + `pg_trgm` GIN + `role/class_id` 索引 | 按 `pg_stat_statements` 验证后再建 |
| 2 | `resolve_provider` 缓存 + 管理端失效 | 减少空表查询 |
| 3 | PgBouncer Pooler（transaction 模式） | 扩容前必做；先压测 prepared statement |
| 4 | 3 实例 + `podAntiAffinityType: required` | 提高 HA；评估同步复制 RPO |
| 5 | 恢复演练（季度） | 记录 RTO/RPO |
| 6 | Redis PVC + AOF 或 Sentinel | 取决于缓存重要性 |
| 7 | CNPG operator 2 副本 | 避免 operator 单点 |

### P2（季度）

| # | 动作 |
|---|---|
| 1 | 业务缓存体系（负缓存、单飞、TTL 抖动、热点本地缓存） |
| 2 | 读写分离（报表走 `-ro`） |
| 3 | SLO/错误预算、混沌演练（failover、Redis 挂、连接打满） |
| 4 | 安全加固：Redis ACL/TLS、S3 TLS、NetworkPolicy、密钥轮换 |
| 5 | 成本优化：备份生命周期、PVC 容量、实例规格 |

---

## 10. 面试速答卡

### Q1：Redis 穿透、击穿、雪崩怎么防？你做了哪个？

**答：**

- 穿透：负缓存（短 TTL）+ Bloom filter + 参数校验 + 登录限流。
- 击穿：热点 key 逻辑过期 + `SET NX` 单飞锁 + 本地缓存 + 异步刷新。
- 雪崩：TTL 抖动 + 多级缓存 + 熔断/降级 + Redis Sentinel/Cluster + DB 连接池保护。
- 我在 compassio 落地的是：`next_cache` 的 Redis + 本地 LRU 两级缓存、预取、一次性消费；`checkpoint` 的 Redis + 本地 fallback；LLM 探活 `SET NX EX` 单飞；登录限流 `INCR+EXPIRE`。穿透还没做，下一步加负缓存 + 登录限流兜底；击穿下一步给 `/next` 未命中加锁；雪崩下一步加 TTL 抖动 + Redis HA。

### Q2：主库宕了，切换流程是什么？RTO 多少？

**答：**

- CNPG 2 实例自动 failover；实测 2026-11-05：01:37:26 检测到主库不健康，01:37:33 新主就绪，**DB RTO ≈ 7s**。
- 应用层因为启动无重试，pod 到 01:38:10 才 Ready，**应用 RTO ≈ 44s**；另一个 pod 全程 Ready，但 health 永远 200，可能带病接流量。
- RPO：异步复制，稳态 lag 0，故障瞬间可能丢最近事务；要 RPO=0 上 3 实例 + 同步复制。
- 流程：告警确认 → 看 CNPG 是否自动切 → 验证 `-rw` 端点和 `pg_is_in_recovery` → 应用重连/重启 → 写测试 → 复盘。
- 改进：启动重试、`pool_pre_ping`、读重试、readiness 503、operator 2 副本、required anti-affinity。

### Q3：连接池打满，现象是什么？怎么定位是应用还是数据库？

**答：**

- 现象：p99 飙升、`QueuePool limit ... reached`、`too many clients`、500，但 CPU 不一定高。
- 定位：先看应用日志/指标是否在等连接；再看 `pg_stat_activity`：
  - 连接数接近上限且大量 `idle` → 应用池太大/泄漏/worker 太多；
  - 连接数不高但 `active` 多、`wait_event` 非空 → DB 慢/锁/IO；
  - 大量 `idle in transaction` → 应用没提交；
  - `max_connections` 满 → 池总量超了，上 PgBouncer。
- 本集群：100 上限，当前 16，compassio 7 idle；2 pod × 2 worker × 默认 15 = 60 理论上限，3 pod 就 90。已把 pool 调成 5+5、加 `pool_pre_ping`，扩容前上 PgBouncer。

### Q4：慢查询怎么定位到具体 SQL 和索引？

**答：**

- 先开观测：CNPG 里 `shared_preload_libraries=pg_stat_statements,auto_explain`、`log_min_duration_statement=500ms`、`track_io_timing=on`；业务库 `CREATE EXTENSION pg_stat_statements`。
- 用 `pg_stat_statements` 按 `total_exec_time/mean_exec_time/calls` 排序，拿 `queryid` 和 SQL。
- 用 `EXPLAIN (ANALYZE, BUFFERS)` 看 Seq Scan、actual rows、loops、buffers、sort/hash spill。
- 用 `pg_stat_user_tables.seq_scan/seq_tup_read` 和 `pg_stat_user_indexes.idx_scan=0` 找缺失/未用索引。
- `ILIKE '%x%'` 用 `pg_trgm` GIN；建索引用 `CREATE INDEX CONCURRENTLY`。
- 现网已发现：`users` 904 行被 seq scan 17,469 次，根因是 readiness 每次调 `_refresh_user_metrics` 做 `GROUP BY role`，加上账号列表无分页、`ILIKE '%q%'` 前置通配。先移走探针全表扫，再分页 + trigram 索引。

---

## 附：关键命令速查

```bash
# PG 状态
kubectl -n cnpg-system get cluster pg16-ceph -o wide
kubectl -n cnpg-system get pods -l cnpg.io/cluster=pg16-ceph -o wide
kubectl -n cnpg-system get endpoints pg16-ceph-rw pg16-ceph-ro

# 连接/慢查询
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select state,count(*) from pg_stat_activity group by 1;"
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select pid,now()-query_start age,wait_event_type,wait_event,left(query,120)
   from pg_stat_activity where state<>'idle' order by age desc nulls last limit 10;"

# 复制/归档
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select client_addr,state,sync_state,replay_lag from pg_stat_replication;"
kubectl -n cnpg-system exec pg16-ceph-4 -- psql -U postgres -d postgres -c \
  "select archived_count,failed_count,last_archived_time from pg_stat_archiver;"

# Redis
kubectl -n compassio exec deploy/compassio-redis -- redis-cli INFO memory
kubectl -n compassio exec deploy/compassio-redis -- redis-cli INFO stats
kubectl -n compassio exec deploy/compassio-redis -- redis-cli --scan

# 备份
kubectl -n cnpg-system get backup,scheduledbackup
kubectl -n cnpg-system get cluster pg16-ceph -o jsonpath='{.status.lastSuccessfulBackup}'
```

---

## 参考

- CloudNativePG 1.22: Connection pooling / Recovery / Failover
- PostgreSQL 16: `pg_stat_statements`, `pg_stat_activity`, `EXPLAIN`, `pg_trgm`
- Redis: cache-aside, singleflight, TTL jitter, Sentinel
