# 16 · 中间件在 OS 层的高频坑

> 不是“中间件调优大全”，而是把 **OS 参数、cgroup、fd、page cache、JVM** 和
> 本集群真实组件对上：Redis 7.4、Kafka 4.1.2（JDK 21）、Nginx 1.27/1.30、
> PostgreSQL 16.15；MySQL/MariaDB 未部署，单独说明。
>
> 详细章节：[`10-middleware-os-pitfalls.md`](10-middleware-os-pitfalls.md)。
> 一句话版本：[15 面试速查 11-middleware-os](../15-interview-cheatsheet/11-middleware-os.md)。

## 本环境组件

| 组件 | 实际 | 位置 |
|---|---|---|
| Redis | 7.4.11 / 7.4.12 / 8.6.4，3 个实例 | `compassio`、`deeptutor`、`argocd` |
| Kafka | Strimzi 4.1.2，单 broker（controller+broker） | `kafka/my-cluster` |
| Nginx | K8s 1.27.3（compassio frontend）、Harbor 1.30.4（Docker） | `compassio`、`192.168.67.202` |
| Java | Kafka JDK 21.0.10；另有 JDK 21 实验 | `kafka` |
| PostgreSQL | CNPG 16.15，`max_connections=100`，当前 13 | `cnpg-system/pg16-ceph` |
| MySQL/MariaDB | **未部署**（K8s 与 PVE 宿主都没有） | - |

## 快速结论

| 项 | 实测 | 风险/建议 |
|---|---|---|
| THP | m01 `always`；worker `madvise` | Redis 应 `never`；m01 上跑 Redis 会抖 |
| `overcommit_memory` | `1` | Redis fork 不会分配失败；仍要留内存余量 |
| `swappiness` | `60` | 无 swap 暂不触发；有 swap 时 Redis 延迟会炸 |
| `somaxconn` | `4096` | Nginx/Redis backlog 可对齐到 4096 |
| `tcp_max_syn_backlog` | `512/1024` | 高并发握手可能偏小 |
| `netdev_max_backlog` | `1000` | 高 PPS 需观察 drops |
| Redis maxmemory | 384M / 400M / **0（ArgoCD）** | ArgoCD Redis 无上限、无 limit |
| Redis policy | `allkeys-lru` / `noeviction` | 确认能否淘汰/写满报错 |
| Kafka 堆 | `MaxHeapSize=1.99G`，只有 `-Xms128M` | 无 Xmx、无 memory limit |
| Kafka fd | soft `1024` | 分区/连接一多就 `Too many open files` |
| Nginx worker | K8s 6 个，CPU limit 0.1 | `worker_processes auto` 不按 limit |
| Nginx fd | soft `1024` | `worker_connections` 先被 fd 卡住 |
| Harbor Nginx | `client_max_body_size 0` | 上传无上限，需加限制 |
| Java 容器 | 500m/512Mi：默认堆 128M，75% 堆 384M | `MaxRAMPercentage` 必设 |
| Java GC/JIT | 500m 时 GC=0、CICompilerCount=2 | `nproc` 显示 6，不可信 |
| PG 连接 | 13 / 100 | 连接池总和不能超过 100 |

## 怎么读

1. 先看 [`10-middleware-os-pitfalls.md`](10-middleware-os-pitfalls.md) 的 OS 底座；
2. 按组件看“实际配置 → 风险 → 检查命令”；
3. 需要复现/取证时看 [`assets/evidence/`](assets/evidence/README.md)；
4. 需要采集新环境时跑 [`scripts/collect_middleware_os.sh`](scripts/collect_middleware_os.sh)。

```bash
bash docs/16-middleware-os/scripts/collect_middleware_os.sh > /tmp/middleware-os.txt
```

> 脚本只读：不改 sysctl、不重启服务、不写 Redis/Kafka/PG。
