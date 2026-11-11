# 11 · 中间件 OS 层面试题

> 详细证据：[16 中间件 OS 层](../16-middleware-os/10-middleware-os-pitfalls.md)。

## 1. Redis 为什么关 THP

**一句话**：THP 让 fork/COW 的内存复制变慢、延迟抖动，Redis 建议 `never`。

**本环境**：m01 THP `always`，worker `madvise`；Redis 在 worker 上，尚未踩到，但漂移就会踩。

## 2. `vm.overcommit_memory=1` 解决什么

**一句话**：Redis fork 需要预留地址空间，overcommit=1 避免 `Cannot allocate memory`。

**本环境**：所有节点都是 1；它只避免分配失败，不避免 OOM。

## 3. Redis 为什么 `swappiness=1`

**一句话**：避免热数据被换出，swap 上的 Redis 延迟会不可预测。

**本环境**：`swappiness=60`，当前无 swap；一旦加 swap 就是隐患。

## 4. `somaxconn` 和 `tcp-backlog`

**一句话**：somaxconn 是内核 accept 队列上限，Redis 的 tcp-backlog 不能超过它。

**本环境**：somaxconn 4096，Redis tcp-backlog 511。

## 5. Redis fork 的 COW 风险

**一句话**：RDB/AOF rewrite fork 后页复制，最坏接近 2× 内存。

**本环境**：`rdb_last_cow_size` 1.5MB、AOF 2.8MB（数据小）；400M 数据时要留余量。

## 6. Redis maxmemory / policy 怎么选

**一句话**：maxmemory 必须小于容器 limit；`noeviction` 写满报错，`allkeys-lru` 可能淘汰会话。

**本环境**：compassio 384M/allkeys-lru；deeptutor 400M/noeviction；ArgoCD Redis **0 无上限、无 limit**。

## 7. MySQL 的 O_DIRECT 是什么

**一句话**：数据文件绕过 OS page cache，减少双缓存；不是所有文件系统都支持。

**本环境**：无 MySQL；PG 用 `fsync=on`、`wal_sync_method=fdatasync` 做对照。

## 8. MySQL 脏页/NUMA

**一句话**：`vm.dirty_ratio` 和 `innodb_max_dirty_pages_pct` 太高会提交抖动；NUMA 不均衡会单节点 OOM。

**本环境**：PG `checkpoint_timeout=5min`、`max_wal_size=1GB`；NUMA 用 `numactl --interleave`。

## 9. Kafka 为什么堆不要太大

**一句话**：Kafka 靠 OS page cache 缓存日志段，堆太大反而挤压 page cache。

**本环境**：Kafka 堆 1.99GB（宿主 8GB 的 25%），节点 buff/cache 约 3.7GB。

## 10. Kafka sendfile

**一句话**：零拷贝把日志段直接从 page cache 发到 socket，减少用户态复制。

**本环境**：Kafka 4.1.2 单 broker，20G PVC，248M 数据；sendfile 由内核支持。

## 11. Kafka fd 为什么重要

**一句话**：每个分区/连接都占 fd，Kafka 通常要 100k+。

**本环境**：Kafka 容器 soft fd = **1024**，分区一多就 `Too many open files`。

## 12. Nginx 并发怎么算

**一句话**：并发 ≈ `worker_processes × worker_connections`，但受 `worker_rlimit_nofile`/fd/somaxconn/backlog 限制。

**本环境**：K8s Nginx 6×1024，Harbor Nginx 2×3096；两边 fd soft 都是 1024。

## 13. `worker_processes auto` 的坑

**一句话**：它按 CPU 数起进程，不按 cgroup CPU limit。

**本环境**：compassio frontend CPU limit 0.1 核，却起了 6 个 worker；应设 1。

## 14. Java 容器感知

**一句话**：JDK 10+ 默认感知 cgroup；JDK 8 要 8u191+ 或 `-XX:+UseContainerSupport`。

**本环境**：Kafka JDK 21，JVM 检测到 cgroups v2。

## 15. MaxRAMPercentage

**一句话**：控制堆占容器内存比例；默认 25%，很多服务需要显式调大。

**本环境**：512Mi limit，默认堆 128Mi，`MaxRAMPercentage=75` 后 384Mi。

## 16. CPU limit 与 GC/JIT

**一句话**：JVM 按 CPU quota 决定 GC/JIT 线程，limit 太低会单线程 GC、启动慢。

**本环境**：500m 时 GC=0、CICompilerCount=2，而 `nproc=6`，所以 nproc 不可信。

## 17. metaspace / direct memory

**一句话**：它们不在堆里，`-Xmx` 管不到；要单独设上限。

**本环境**：Kafka `MaxMetaspaceSize=unlimited`、`MaxDirectMemorySize=0`（默认等于堆）。

## 18. fd / TIME_WAIT / 端口

**一句话**：fd 决定连接数上限；TIME_WAIT 是主动关闭方正常状态；端口范围决定 NAT/出站能力。

**本环境**：TIME_WAIT 189、端口 32768–60999、conntrack 947/262144。

## 19. 连接池与 DB 承载

**一句话**：所有实例池上限之和必须小于 DB `max_connections`，超了要 PgBouncer/ProxySQL。

**本环境**：PG `max_connections=100`，当前 13；10 副本×20 就会打满。

## 20. 30 秒总回答

```text
Redis：THP 关、overcommit=1、swappiness=1、somaxconn/backlog 对齐，
       fork COW 留内存，maxmemory < 容器 limit。

MySQL：O_DIRECT 减少双缓存，fsync/刷盘决定持久性，
       脏页比例和 NUMA 影响抖动。

Kafka：page cache 是主缓存，堆别太大；sendfile 零拷贝；
       fd 100k，磁盘顺序写。

Nginx：并发 ≈ worker_processes × worker_connections，
       受 fd/somaxconn/backlog 限制；worker_processes 要匹配 CPU limit。

Java：MaxRAMPercentage 控堆，ActiveProcessorCount/CPU limit 决定 GC/JIT，
       metaspace/direct memory 不占堆。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| THP | Redis 关，减少 fork/COW 抖动 |
| overcommit | Redis fork 预留地址空间 |
| swappiness | Redis 设 1 |
| somaxconn | accept 队列上限 |
| COW | fork 最坏 2× 内存 |
| maxmemory | 小于容器 limit |
| O_DIRECT | 绕过 page cache |
| 脏页/NUMA | 抖动与单节点 OOM |
| Kafka 堆 | 别太大，留 page cache |
| sendfile | 零拷贝 |
| Kafka fd | 100k+ |
| Nginx 并发 | workers × connections，受 fd 限制 |
| worker auto | 不按 CPU limit |
| Java 容器 | JDK 10+ 感知 cgroup |
| MaxRAMPercentage | 控堆比例 |
| CPU limit | 决定 GC/JIT 线程 |
| metaspace/direct | 堆外内存，单独限额 |
| 连接池 | 总和 < DB max_connections |
