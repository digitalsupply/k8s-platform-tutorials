# 10 · 中间件在 OS 层的高频坑：Redis / MySQL / Kafka / Nginx / Java

> 中间件“慢/抖/OOM”有一半不是代码问题，而是 OS 层：THP、overcommit、swappiness、
> page cache、fd、backlog、cgroup CPU、JVM 容器感知。
>
> 本章全部基于本集群实测（2026-11-11）：
> Redis 7.4 / Kafka 4.1.2（JDK 21）/ Nginx 1.27 + 1.30 / PostgreSQL 16.15；
> **MySQL/MariaDB 未部署**，用 CNPG PostgreSQL 做同层对照，不把 PG 参数冒充 MySQL。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)。
> 一句话版本：[15 面试速查 11-middleware-os](../15-interview-cheatsheet/11-middleware-os.md)。

## 1. OS 底座：本环境实际值

| 项 | 实际值 | 影响 |
|---|---|---|
| cgroup | 全部 `cgroup2fs` | 统一 v2；Java/Redis 能感知 memory.max/cpu.max |
| THP | m01 `[always]`；worker `[madvise]` | Redis 推荐 `never`；`always` 会增加 fork/延迟抖动 |
| `vm.overcommit_memory` | `1` | Redis fork 不会因 overcommit 失败；代价是可能 OOM |
| `vm.swappiness` | `60` | Redis 推荐 `1`；本环境无 swap，暂不触发，但一旦加 swap 会放大延迟 |
| `net.core.somaxconn` | `4096` | Nginx/Redis backlog 上限 |
| `net.ipv4.tcp_max_syn_backlog` | `512` / `1024` | SYN 队列；高并发握手时可能偏小 |
| `net.core.netdev_max_backlog` | `1000` | 高 PPS 时可能丢包 |
| `ip_local_port_range` | `32768–60999` | 约 2.8 万临时端口 |
| `tcp_max_tw_buckets` | `32768` / `65536` | TIME_WAIT 上限 |
| `fs.nr_open` | 1M | 进程 fd 硬上限 |
| kubelet fd | soft/hard `1000000` | 节点侧足够 |
| containerd fd | soft `1024` / hard 1M | soft 偏低 |
| shell `ulimit -n` | `1024` | 交互 shell 默认，不代表服务进程 |
| Redis 进程 fd | soft/hard `10032` | 够用 |
| Nginx/Kafka 进程 fd | soft `1024` / hard 524288 | **soft 偏低** |
| PG `max_connections` | `100`，当前 `13` | 连接池不能超过 DB 承载 |

证据：[`evidence/os-baseline.txt`](assets/evidence/os-baseline.txt)、
[`evidence/general.txt`](assets/evidence/general.txt)。

## 2. Redis

### 2.1 OS 层关键点

| 项 | 推荐 | 原因 |
|---|---|---|
| THP | `never` | fork/RDB/AOF rewrite 时大页复制更慢、延迟抖动 |
| `vm.overcommit_memory` | `1` | fork 需要预留地址空间，避免 `Cannot allocate memory` |
| `vm.swappiness` | `1` | 避免 Redis 热数据被换出；本环境无 swap 但仍应设 |
| `somaxconn` | ≥ 4096 | 连接风暴时 accept 队列 |
| `tcp-backlog` | 与 somaxconn 匹配 | Redis 默认 511；somaxconn 4096 时 backlog 可能先满 |
| fork COW | 预留内存 | RDB/AOF rewrite 时页复制，最坏接近 2× 内存 |
| `maxmemory` | 小于容器 limit | 留出 fork/碎片/客户端缓冲区 |
| `maxmemory-policy` | 按业务选 | `noeviction` 写满会报错；`allkeys-lru` 可能淘汰会话 |

### 2.2 本环境三个 Redis

| 实例 | 版本 | maxmemory | policy | AOF | RSS | 备注 |
|---|---|---|---:|---|---:|---:|---|
| `compassio/compassio-redis` | 7.4.11 | 384M | `allkeys-lru` | no | 6.9M | 512Mi limit；缓存型 |
| `deeptutor/redis` | 7.4.12 | 400M | `noeviction` | yes/everysec | 31.5M | 512Mi limit；AOF 持久化 |
| `argocd/argocd-redis` | 8.6.4 | **0（无上限）** | `noeviction` | no | 18.6M | resources `{}`；无 limit |

共同点：

```text
tcp-backlog = 511
connected_clients = 5
mem_fragmentation_ratio: 6.35 / 1.34 / 1.97
```

### 2.3 风险与运维

- **ArgoCD Redis 无 maxmemory、无 resources limit**：客户端/队列增长时可能吃满节点内存，
  然后被内核 OOM；至少设 `maxmemory` + `resources.limits.memory`。
- **deeptutor `noeviction`**：400M 写满后写命令直接报错；要监控 `used_memory`/`maxmemory`。
- **compassio `allkeys-lru`**：可能淘汰会话/锁；确认 key 都可丢，或改用 `volatile-lru`。
- **fork COW**：本环境 `rdb_last_cow_size` 1.5MB、`aof_last_cow_size` 2.8MB，因为数据小；
  数据到几百 MB 时必须留 fork 余量，`overcommit_memory=1` 只是避免分配失败，不是避免 OOM。
- **THP**：Redis 在 worker 上看到 `madvise`，不是 `never`；m01 是 `always`，
  如果 Redis 漂移到 m01 会踩 THP 坑。
- **swappiness=60**：当前无 swap，但节点一旦加 swap，Redis 延迟会抖。

检查：

```bash
redis-cli INFO memory | grep -E 'used_memory|maxmemory|fragmentation'
redis-cli INFO persistence | grep -E 'rdb_last_cow_size|aof_last_cow_size'
redis-cli CONFIG GET maxmemory maxmemory-policy appendonly tcp-backlog
cat /sys/kernel/mm/transparent_hugepage/enabled
sysctl vm.overcommit_memory vm.swappiness net.core.somaxconn
```

证据：[`evidence/redis.txt`](assets/evidence/redis.txt)。

## 3. MySQL

### 3.1 本环境事实

**Kubernetes 内没有 MySQL/MariaDB Pod；PVE 宿主也没有运行 mysqld/mariadbd。**
本节是“如果部署 MySQL 要检查什么”，并用本环境 PostgreSQL 16.15 做同层参照。

### 3.2 O_DIRECT / fsync / page cache

MySQL 的两套缓存：

```text
InnoDB Buffer Pool（MySQL 自己的缓存）
  + OS page cache（内核缓存）
```

`innodb_flush_method`：

| 值 | 行为 | 适用 |
|---|---|---|
| `fsync` | 写 data + redo 都走 page cache，再 fsync | 默认；依赖 page cache |
| `O_DIRECT` | data 文件绕过 page cache，减少双缓存 | 大内存、专用 DB 盘常用 |
| `O_DSYNC` | redo 用 O_SYNC | 特定场景 |

关键点：

- `O_DIRECT` 不是所有文件系统都支持；XFS/ext4 可以，tmpfs/overlay 要验证；
- `innodb_flush_log_at_trx_commit=1` 才是最安全（每次提交刷 redo）；
- `fsync=on` 是底线，不能为了性能关；
- `vm.dirty_ratio` / `vm.dirty_background_ratio` 太高会导致脏页堆积、提交抖动；
- `innodb_max_dirty_pages_pct` 控制 InnoDB 脏页比例，和内核 dirty 参数要一起看；
- NUMA：`innodb_numa_interleave=ON` 或 `numactl --interleave=all`，避免单节点内存耗尽。

### 3.3 本环境 PostgreSQL 对照

```text
shared_buffers        = 128MB
effective_cache_size  = 4GB
fsync                 = on
wal_sync_method       = fdatasync
checkpoint_timeout    = 300s
max_wal_size          = 1GB
work_mem              = 4MB
maintenance_work_mem  = 64MB
max_connections       = 100
current connections   = 13
huge_pages            = try
```

对应关系：

| MySQL | PostgreSQL 对照 | 说明 |
|---|---|---|
| `innodb_buffer_pool_size` | `shared_buffers` | DB 自己的缓存 |
| `innodb_flush_method=O_DIRECT` | 无直接等价 | PG 依赖 OS page cache + `fsync` |
| `innodb_flush_log_at_trx_commit` | `synchronous_commit` / `fsync` | 持久性 |
| `innodb_io_capacity` | `effective_io_concurrency` | 磁盘 IO 能力 |
| `innodb_numa_interleave` | `numa`/`numactl` | NUMA 均衡 |
| `max_connections` | `max_connections` | 连接上限 |

### 3.4 运维检查

```bash
# MySQL
mysql -e "SHOW VARIABLES LIKE 'innodb_flush_method';"
mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
mysql -e "SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';"
mysql -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty';"
numastat -p $(pgrep mysqld)

# 内核脏页
sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs

# 本环境 PG
psql -c "show shared_buffers; show fsync; show wal_sync_method;"
```

## 4. Kafka

### 4.1 OS 层关键点

| 项 | 推荐 | 原因 |
|---|---|---|
| page cache | 留足 | Kafka 依赖 OS page cache 做读写缓存 |
| 堆 | 不要太大 | 堆太大反而挤压 page cache；Kafka 常用 4–8G |
| `sendfile` | 开启 | 零拷贝把日志文件发到 socket |
| fd | 100k+ | 每分区/连接都占 fd；1024 远远不够 |
| 磁盘 | 顺序写、独立盘 | 避免和系统盘/其他 IO 争抢 |
| `num.io.threads` | 按磁盘数 | 不是越大越好 |
| `log.dirs` | 多盘分散 | 单盘 IOPS 是瓶颈 |

### 4.2 本环境实际

Kafka CR：

```text
version 4.1.2
replicas: 1（single-pool，controller+broker）
replication.factor = 1
min.insync.replicas = 1
storage: ceph-rbd 20Gi
resources: {}
jvmOptions: {}
```

Pod：

```text
JDK 21.0.10
KAFKA_HEAP_OPTS=-Xms128M        # 只有 Xms，没有 Xmx
fd soft=1024 / hard=524288
cgroup cpu.max = max 100000     # 无 CPU quota
cpuset = 0-3                    # 4 核
memory.max = max                # 无内存 limit
nproc = 4
JVM:
  MaxHeapSize        = 1.99GB   # 默认 1/4 宿主内存
  ParallelGCThreads  = 4
  CICompilerCount    = 3
  MaxDirectMemorySize= 0        # 默认等于最大堆
  MaxMetaspaceSize   = unlimited
```

磁盘：`/var/lib/kafka/data` 20G，已用 248M。
节点 page cache：8GB 内存，`buff/cache` 约 3.7GB。

### 4.3 风险

- **没有 Xmx、没有 memory limit**：JVM 按宿主 8GB 算最大堆 ~2GB；
  如果同节点还有其他 Java/缓存进程，容易互相挤 page cache。
- **fd soft=1024**：Kafka 分区/连接一多就会 `Too many open files`；
  Strimzi 没显式设置 ulimit，需要 `template` 或容器 `ulimits`。
- **单 broker + RF=1**：这是开发配置；broker/磁盘故障直接丢数据。
- **page cache 与堆争内存**：堆 2GB + 其他进程，剩余 page cache 可能不足；
  Kafka 性能依赖 page cache，不是堆越大越好。
- **sendfile**：Kafka 用零拷贝发送日志段；如果容器/内核限制，会退化为用户态拷贝。

### 4.4 运维检查

```bash
kubectl -n kafka get kafka my-cluster -o yaml
kubectl -n kafka exec my-cluster-single-pool-0 -- \
  sh -c 'cat /proc/1/limits; java -XX:+PrintFlagsFinal -version | grep -E "MaxHeapSize|ParallelGCThreads"'
kubectl -n kafka exec my-cluster-single-pool-0 -- df -h /var/lib/kafka/data
free -m; grep -E 'Cached|Dirty|Writeback' /proc/meminfo
```

证据：[`evidence/kafka-java.txt`](assets/evidence/kafka-java.txt)。

## 5. Nginx

### 5.1 公式

```text
最大并发连接 ≈ worker_processes × worker_connections
反向代理场景要 ÷2：每个被代理请求占用「客户端→Nginx」+「Nginx→上游」两条连接
但受 worker_rlimit_nofile / 系统 fd / somaxconn / backlog 限制
```

### 5.2 本环境两套 Nginx

**K8s `compassio-frontend`（nginx 1.27.3）**

```text
worker_processes  auto;          # 实际 6 个 worker
worker_connections 1024;         # 6 × 1024 = 6144
sendfile on;
# tcp_nopush 未开启
keepalive_timeout 65;
client_max_body_size 20m;
proxy_read_timeout 600s;
fd soft=1024 / hard=524288
CPU limit=100m（cpu.max=10000 100000）
nproc=6
```

问题：

- CPU limit 只有 **0.1 核**，但 `worker_processes auto` 起了 **6 个 worker**；
  6 个进程抢 0.1 核，context switch 多、收益低。
- fd soft=1024，`worker_rlimit_nofile` 未设置；6 个 worker 共享/各自受限。
- `tcp_nopush` 未开，静态文件小包发送效率略低。
- `worker_connections 1024` 对 6 个 worker 理论 6144，但 fd 1024 先成为瓶颈。

**Harbor `nginx`（nginx 1.30.4，Docker）**

```text
worker_processes auto;          # 实际 2 个 worker
worker_connections 3096;        # 2 × 3096 = 6192
client_max_body_size 0;         # 不限制上传大小
proxy_read_timeout 900s;
fd soft=1024 / hard=524288
nproc=2
sendfile / tcp_nopush 未在配置中显式开启
```

问题：

- `client_max_body_size 0` 允许无限大请求体，镜像推送/恶意请求可能打满磁盘/带宽；
- fd soft=1024，`worker_connections 3096` 实际受 fd 限制；
- 没显式 `sendfile on` / `tcp_nopush on`，静态分发效率不是最优；
- `worker_rlimit_nofile` 未设置。

### 5.3 运维建议

```nginx
worker_processes 1;              # 与 CPU limit 匹配，不要 auto
worker_rlimit_nofile 65535;
events {
  worker_connections 4096;
  multi_accept on;
}
http {
  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;
  client_max_body_size 100m;     # 明确上限，不要 0
  server {
    listen 80 backlog=4096;
  }
}
```

检查：

```bash
nginx -T | grep -E 'worker_processes|worker_connections|worker_rlimit_nofile|sendfile|tcp_nopush|backlog'
cat /proc/1/limits | grep 'open files'
ss -lnt | grep :80
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
```

证据：[`evidence/nginx.txt`](assets/evidence/nginx.txt)。

## 6. Java 容器化

### 6.1 容器感知

JDK 10+ 默认容器感知；JDK 8 需要 8u191+ 或 `-XX:+UseContainerSupport`。
它会影响：

- 最大堆：默认 `MaxRAMPercentage=25%`；
- GC 线程数：按 CPU limit/cpuset；
- JIT 编译线程：`CICompilerCount`；
- `ActiveProcessorCount`：可显式覆盖。

### 6.2 本环境实验：CPU 500m / 内存 512Mi

```text
nproc = 6                          # 容器内看到宿主 CPU 数
JVM 检测: cgroups v2, is_containerized() = true

默认 MaxHeapSize        = 128Mi  # 25% × 512Mi
MaxRAMPercentage=75     = 384Mi  # 75% × 512Mi
ActiveProcessorCount    = -1     # 自动
ParallelGCThreads       = 0      # 0.5 CPU 下几乎不并行
CICompilerCount         = 2
显式 ActiveProcessorCount=2 -> 2
```

结论：

- `nproc` 可能显示宿主 CPU 数，不能用来判断 JVM 实际并行度；
- JVM 会按 cgroup CPU quota 选择 GC/JIT 线程，500m 时 GC 线程为 0/很少；
- CPU limit 太低会导致启动慢、GC 单线程、吞吐上不去；
- `MaxRAMPercentage` 要显式设置，默认 25% 对很多服务偏小；
- 堆外还有 metaspace、直接内存、线程栈、JNI，不能只按 `-Xmx` 算内存。

### 6.3 本环境 Kafka JVM

```text
JDK 21，KAFKA_HEAP_OPTS=-Xms128M（没有 Xmx）
MaxHeapSize = 1.99GB（宿主 8GB 的 25%）
memory.max = max（无容器内存限制）
ParallelGCThreads = 4（cpuset 4 核）
```

风险：

- 没有显式 `-Xmx`/`MaxRAMPercentage`，堆大小随宿主内存变化；
- 没有 memory limit，JVM 可能和 page cache/其他进程争内存；
- `MaxDirectMemorySize=0` 表示默认等于最大堆，NIO/网络缓冲可能吃满；
- `MaxMetaspaceSize=unlimited`，类加载泄漏会无限增长。

建议：

```bash
JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=60 -XX:InitialRAMPercentage=30 \
  -XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=256m"
```

并设置容器 memory limit，预留 25–30% 给堆外/page cache。

证据：[`evidence/java-container-lab.txt`](assets/evidence/java-container-lab.txt)。

## 7. 连接池与 DB 承载

公式：

```text
所有应用实例的连接池上限之和 < DB max_connections
```

本环境：

```text
PostgreSQL max_connections = 100
当前连接 = 13
compassio-backend 1 副本
deeptutor-api 1 副本
```

如果扩到 10 个副本、每池 20：

```text
10 × 20 = 200 > 100   -> 连接被拒
```

做法：

- 应用池上限按 DB 承载反推；
- 上 PgBouncer/ProxySQL 做连接复用；
- 监控 `pg_stat_activity` / `Threads_connected`；
- 不要用“池越大越快”的思路。

## 8. 一页检查清单

```text
[ ] THP：Redis 节点设 never；至少确认不是 always
[ ] vm.overcommit_memory=1（Redis fork）
[ ] vm.swappiness=1（有 swap 时尤其重要）
[ ] somaxconn/backlog 与 Nginx/Redis 配置匹配
[ ] Redis maxmemory < 容器 limit，policy 与业务匹配
[ ] Redis fork COW 余量；监控 rdb_last_cow_size
[ ] MySQL：innodb_flush_method、flush_log_at_trx_commit、dirty pages、NUMA
[ ] Kafka：堆不要太大、fd 100k、page cache 足够、多盘顺序写
[ ] Nginx：worker_processes 匹配 CPU limit，worker_rlimit_nofile、sendfile/tcp_nopush
[ ] Java：MaxRAMPercentage、ActiveProcessorCount、metaspace/direct memory
[ ] 连接池总和 < DB max_connections
[ ] 监控 TIME_WAIT、fd、conntrack、dirty pages
```

## 9. 面试 30 秒

```text
Redis：THP 关、overcommit=1、swappiness=1、somaxconn/backlog 对齐，
       fork COW 要留内存，maxmemory 要小于容器 limit。

MySQL：O_DIRECT 减少双缓存、fsync/刷盘决定持久性，
       脏页比例和 NUMA 影响抖动。

Kafka：page cache 是主缓存，堆别太大；sendfile 零拷贝；
       fd 要 100k，磁盘顺序写。

Nginx：并发 ≈ worker_processes × worker_connections（反代场景 ÷2，一请求两条连接），
       但受 worker_rlimit_nofile、somaxconn、backlog 限制。

Java：JDK 10+ 容器感知；MaxRAMPercentage 控堆；
       CPU limit 会决定 GC/JIT 线程，nproc 不可信；
       metaspace/direct memory 不占堆。
```
