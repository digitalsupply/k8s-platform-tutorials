# 中间件 OS 层：本环境实测

对应教程：[`../../10-middleware-os-pitfalls.md`](../../10-middleware-os-pitfalls.md)。

## 证据

| 文件 | 内容 |
|---|---|
| `evidence/os-baseline.txt` | 5 个节点的 THP、overcommit、swappiness、somaxconn、fd、cgroup |
| `evidence/general.txt` | worker03 `ss -s`、TIME_WAIT、端口范围、conntrack、ulimit |
| `evidence/redis.txt` | 3 个 Redis 的版本/maxmemory/policy/AOF/RSS/COW/fragmentation |
| `evidence/kafka-java.txt` | Strimzi CR、Pod env/fd/cgroup/JVM flags/磁盘 |
| `evidence/nginx.txt` | compassio K8s Nginx 与 Harbor Nginx 的配置/worker/fd |
| `evidence/postgres-mysql.txt` | PG 16.15 参数/连接数、无 MySQL、节点 page cache |
| `evidence/java-container-lab.txt` | 500m/512Mi 下默认堆、75% 堆、ActiveProcessorCount/GC/JIT |

## 关键结论

- THP：m01 `always`，worker `madvise`；Redis 推荐 `never`；
- `overcommit_memory=1`，`swappiness=60`（无 swap）；
- `somaxconn=4096`，Redis `tcp-backlog=511`；
- Redis：compassio 384M/allkeys-lru，deeptutor 400M/noeviction+AOF，ArgoCD 0 无上限且无 resources；
- Kafka：单 broker/RF=1，20G PVC，`-Xms128M` 无 Xmx，MaxHeap 1.99G，fd soft 1024；
- Nginx：compassio 6 worker/CPU limit 0.1，Harbor 2 worker/worker_connections 3096/client_max_body_size 0，fd soft 1024；
- Java：512Mi limit 默认堆 128Mi，`MaxRAMPercentage=75` → 384Mi；500m 时 GC=0/CICompilerCount=2，`nproc=6` 不可信；
- PG `max_connections=100`，当前 13；MySQL/MariaDB 未部署。

## 采集脚本

```bash
bash docs/16-middleware-os/scripts/collect_middleware_os.sh > /tmp/middleware-os.txt
```

只读；不改 sysctl、不重启服务、不写数据。
