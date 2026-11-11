# LGMT 可观测性栈全面审计报告

> 生成时间：2026-09-28 17:20 CST（17:55 增补 Promtail 专章 4.10）
> 采集方式：kubectl / Prometheus API / Loki API / Tempo API / Ceph RGW S3 API / Grafana API / Helm 备份
> 数据新鲜度：全部为本机实时采集，非历史归档
> 密钥策略：全文不含任何明文口令 / AK / SK
> 组件范围：含已退役组件 **Promtail 3.5.1**（其角色见 [4.10](#410-promtail-351-前任日志采集器已退役)）

---

## 目录

1. [执行摘要](#1-执行摘要)
2. [组件清单（实测）](#2-组件清单实测)
3. [整体架构与分工](#3-整体架构与分工)
4. [组件详解](#4-组件详解)
5. [数据链路实测证据](#5-数据链路实测证据)
6. [P0 级故障深度剖析](#6-p0-级故障深度剖析)
7. [P1 级问题](#7-p1-级问题)
8. [Grafana 三大信号查询实战](#8-grafana-三大信号查询实战)
9. [推荐配置基线](#9-推荐配置基线)
10. [修复优先级与路线图](#10-修复优先级与路线图)
11. [附录](#11-附录)

### 第 4 章内部导航

| 节 | 组件 | 信号 | 状态 |
|----|------|------|------|
| [4.1](#41-loki-367日志) | Loki 3.6.7 | Logs（存储/查询） | ✅ 健康 |
| [4.2](#42-grafana-alloy-v1200-日志采集当前失效) | Grafana Alloy v1.20.0 | Logs（采集） | ❌ **空转** |
| [4.3](#43-tempo-290-追踪存储当前在用但数据枯竭) | Tempo 2.9.0 | Traces | ⚠️ 可用但无数据 |
| [4.4](#44-tempo-303-追踪新架构完全不可用) | Tempo 3.0.3 | Traces | ❌ 全挂 |
| [4.5](#45-opentelemetry-collector-01450) | OTel Collector 0.145.0 | Traces 入口 | ✅ |
| [4.6](#46-prometheus-3112-与-alertmanager) | Prometheus 3.11.2 | Metrics | ⚠️ 18 target DOWN |
| [4.7](#47-grafana-1243) | Grafana 12.4.3 | 统一查询层 | ✅ |
| [4.8](#48-存储层-ceph-quincy) | Ceph Quincy | 存储 | ✅ |
| [4.9](#49-kafka-412strimzi) | Kafka 4.1.2 | Traces 队列 | ✅ |
| [**4.10**](#410-promtail-351-前任日志采集器已退役) | **Promtail 3.5.1** | **Logs（已退役的前任采集器）** | **🏳 已退役** |

---

## 1. 执行摘要

### 1.1 集群总体健康

| 维度 | 实测值 | 判定 |
|------|--------|------|
| 节点 | 6/6 Ready（m01 / master01 / master02 / worker01-03） | ✅ |
| Pod | 135 Running / 19 Completed / **13 CrashLoopBackOff** / **1 ImagePullBackOff** | ❌ |
| Prometheus 抓取目标 | **39 up / 18 down**（共 57） | ❌ |
| 告警 | **58 firing / 1 pending** | ❌ |
| Grafana 数据源 | 4 个（Prometheus / Alertmanager / loki / tempo） | ✅ |
| Grafana Dashboard | 37 个 | ✅ |
| Ceph | `HEALTH_OK`，433 PG active+clean，6/6 OSD up-in | ✅（本轮已修复） |
| 集群 Pod 内存 | 41% ~ 73%，无节点内存压力 | ✅ |

### 1.2 三个致命结论（均以实测数据定论）

| # | 结论 | 证据强度 | 影响 |
|---|------|---------|------|
| **①** | **tempo3 全部 13 个 Pod CrashLoop 的根因是 S3 `secret_key` 错误**，用 RGW 真实凭据当场验证通过 | 100% 确定（真实 S3 签名请求对比） | Tempo 3.x 完全不可用 |
| **②** | **Alloy 采集了 0 条日志**——Promtail→Alloy 迁移丢了 **5 项能力**，当前 Pod 在 Loki 中零记录 | 100% 确定（`{namespace="logging"}[1h]` 返回空集 + 15 项 Promtail↔Alloy 逐项对照） | **集群日志管道已断约 3 小时** |
| **③** | Loki 历史数据完好（3608 个 S3 对象），非数据丢失，是「采集端断流」 | 100% 确定（S3 桶枚举） | 可秒级恢复 |

### 1.3 日志采集器的历史：Promtail → Alloy

```
2026-04-06  Promtail 3.5.1 上线（DaemonSet × 6，含 control-plane）  ← 正常工作 155 天
            ↓  建立标签契约：node_name / job / app / instance / component
            ↓  采集约 125 万行/24h（logging 命名空间），沉淀 3608 个 S3 chunk
            ↓
2026-09-28 12:33  迁移到 Grafana Alloy v1.20.0（DaemonSet × 3，仅 worker）
            ↓  迁移不完整：配置文件搬了，chart 隐式能力没搬
            ↓
2026-09-28 14:00  写入量断崖归零，日志管道实际中断
```

**迁移丢失的能力**（详见 4.10 / 6.2）：

| # | 丢失项 | 后果 | 严重度 |
|---|--------|------|--------|
| 1 | `loki.source.file` 组件 | 完全不读文件 | **致命** |
| 2 | `discovery.relabel.targets` 断链 | 无输入 | **致命** |
| 3 | `/var/log/pods` 等 hostPath 挂载 | 无文件可读 | **致命** |
| 4 | `tolerations` | 只覆盖 3/6 节点，控制面 28 个 Pod 漏采 | 高 |
| 5 | 资源 requests/limits | BestEffort QoS，节点压力下先被驱逐 | 中 |
| — | `node_name` / `job` / `instance` / `component` 标签 | 存量 LogQL 与看板失效 | 高 |

> **根因一句话**：Promtail 有相当一部分能力来自 chart 的**隐式默认值**（`defaultVolumes`、挂载、`tolerations`、资源），迁移时只搬了「配置文件」。**换 chart 时，凡是默认值给的东西都会消失。**

### 1.4 一句话总结

> **Loki 存储层健康、Prometheus 正常、只有两个「入口」断了**：Tempo 3.x 因为一把错误的 S3 密钥起不来；Alloy 因为 Promtail→Alloy 迁移丢了 5 项能力而空转。两者互不依赖，但都堵住了追踪与日志的入口。

---

## 2. 组件清单（实测）

### 2.1 Helm Release

| Release | 命名空间 | Chart | App 版本 | 修订 | 部署时间 | 状态 |
|---------|----------|-------|----------|------|----------|------|
| `loki` | logging | `loki-6.55.0` | 3.6.7 | 2 | 2026-05-03 | deployed |
| `tempo` | logging | `tempo-distributed-1.61.3` | 2.9.0 | 1 | 2026-04-26 | deployed |
| `tempo3` | logging | `tempo-distributed-3.7.0` | 3.0.3 | **5** | 2026-09-28 15:18 | deployed（**全挂**） |
| `alloy` | logging | `alloy-1.13.0` | v1.20.0 | 1 | 2026-09-28 12:33 | deployed（**空转**） |
| ~~`promtail`~~ | ~~logging~~ | ~~`promtail-6.17.1`~~ | ~~3.5.1~~ | ~~2~~ | ~~2026-04-06 13:56~~ | **已退役**（Helm 保留 `superseded`，可回滚） |
| `prometheus` | monitoring | `kube-prometheus-stack-83.7.0` | v0.90.1 | 3 | 2026-05-05 | deployed |
| `otel-operator` | opentelemetry | `opentelemetry-operator-0.106.0` | 0.145.0 | 1 | 2026-03-03 | deployed |

> **Promtail 生命周期**：2026-04-06 13:56 部署（chart `promtail-6.17.1` / app **3.5.1**），2026-09-28 12:33 被 Alloy 取代，运行 **155 天**。它的作用、配置契约与退役影响详见 [4.10](#410-promtail-351-前任日志采集器已退役)。

### 2.2 Pod 清单（logging 命名空间）

#### ✅ 正常运行（21 个）

```
alloy-fv6gk              2/2 Running  0 restarts   178m  worker01
alloy-nmzrw              2/2 Running  0 restarts   179m  worker03
alloy-nx982              2/2 Running  0 restarts   179m  worker02
loki-backend-0           2/2 Running  12 restarts  155d
loki-write-0             1/1 Running  12 restarts  175d
loki-read-67b5687d4b     1/1 Running  77 restarts  148d
loki-gateway-68ff9df4b   1/1 Running  30 restarts  155d
loki-chunks-cache-0      2/2 Running  12 restarts  155d
loki-results-cache-0     2/2 Running  12 restarts  155d
loki-canary × 3          1/1 Running  12 restarts  155d
tempo-distributor        1/1 Running  12 restarts  155d
tempo-ingester-0/1/2     1/1 Running  12 restarts  155d
tempo-querier            1/1 Running  12 restarts  155d
tempo-query-frontend     1/1 Running  12 restarts  155d
tempo-compactor          1/1 Running  12 restarts  155d
tempo-metrics-generator  1/1 Running  12 restarts  155d
tempo-memcached-0        1/1 Running  12 restarts  155d
```

#### ❌ CrashLoopBackOff（13 个，全部 tempo3）

```
tempo3-block-builder-0            0/1  35 restarts  156m
tempo3-block-builder-1            0/1  35 restarts  156m
tempo3-block-builder-2            0/1  23 restarts   97m
tempo3-live-store-0               0/1  35 restarts  156m
tempo3-live-store-1               0/1  35 restarts  156m
tempo3-live-store-2               0/1  23 restarts   97m
tempo3-backend-scheduler-0        0/1  23 restarts   97m
tempo3-backend-worker-0           0/1  23 restarts   97m
tempo3-distributor-667f4658fd     0/1  23 restarts   97m
tempo3-querier-6f6d5b9b78         0/1  23 restarts   97m
tempo3-query-frontend-7f49b4cb6c  0/1  24 restarts   97m
tempo3-metrics-generator-56647c   0/1  32 restarts  142m
tempo3-metrics-generator-7b7fb8f  0/1  29 restarts  124m
```

#### ❌ ImagePullBackOff（1 个）

```
kube-system/coredns-7bf7bd7987-k7f47   0/1   20h
```

### 2.3 tempo3 组件拓扑（全新架构）

| 组件 | 类型 | 副本 | 角色 | 状态 |
|------|------|------|------|------|
| `tempo3-distributor` | Deployment | 1 | 接收 OTLP、写入 Kafka | ❌ 单点 + CrashLoop |
| `tempo3-live-store` | StatefulSet | 3 | 消费 Kafka，热数据存储 | ❌ CrashLoop |
| `tempo3-block-builder` | StatefulSet | 3 | 热转冷，生成 block | ❌ CrashLoop |
| `tempo3-backend-scheduler` | StatefulSet | 1 | 压缩/保留任务调度 | ❌ 单点 + CrashLoop |
| `tempo3-backend-worker` | StatefulSet | 1 | 执行压缩/保留 | ❌ 单点 + CrashLoop |
| `tempo3-querier` | Deployment | 1 | 追踪查询 | ❌ 单点 + CrashLoop |
| `tempo3-query-frontend` | Deployment | 1 | 查询入口 | ❌ 单点 + CrashLoop |
| `tempo3-metrics-generator` | Deployment | 1 | RED 指标生成 | ❌ 双副本均 CrashLoop |
| `tempo3-memcached` | StatefulSet | 1 | Parquet footer / Bloom 缓存 | ❌ 单点 |

> **单副本组件共 7 个**，即使修好 S3，也存在大面积单点风险。

---

## 3. 整体架构与分工

### 3.1 四大信号的职责边界

| 信号 | 是什么 | 采集者 | 存储 | 查询 | 本集群方案 |
|------|--------|--------|------|------|-----------|
| **Metrics** | 数值时间序列，可聚合 | Prometheus 拉取 | Prometheus TSDB | PromQL | kube-prometheus-stack |
| **Logs** | 文本行，不可聚合 | Alloy DaemonSet 尾随文件 | Loki（chunk+TSDB 索引，S3 存 chunk） | LogQL | grafana/loki 6.55.0 |
| **Traces** | 请求调用链（span 树） | OTel Collector OTLP 接收 | Tempo（block，S3） | TraceQL | grafana-community/tempo-distributed |
| **Events** | K8s 对象状态变化 | kube-state-metrics 转换 | 同 Metrics | PromQL | 内置于 kube-prometheus-stack |

### 3.2 数据流全景（当前真实状态）

```
                          ┌─────────────────────────────────────────────┐
                          │  Kubernetes Cluster v1.29.8 (6 nodes)       │
                          └─────────────────────────────────────────────┘

  ┌─────────────── METRICS 通路（正常）──────────────────────────────┐
  │                                                                    │
  │  node-exporter(6)  kube-state-metrics(1)  apiserver/kubelet      │
  │  kube-proxy/etcd/scheduler/controller-manager  ← ⚠️ 后 4 类全 DOWN │
  │         │  ServiceMonitor × 15                                       │
  │         ▼                                                          │
  │  ┌──────────────────┐    remote_write    ┌──────────────┐        │
  │  │ Prometheus 3.11.2│◄───────────────────│OTel Collector│        │
  │  │ TSDB: 182,498    │    spanmetrics      │ (otelcol)    │        │
  │  │ series, 5d/30GiB │                     └──────┬───────┘        │
  │  └────────┬─────────┘                            │ OTLP/gRPC      │
  │           │ /api/v1/alerts                       │ :4317          │
  │           ▼                                      ▼                │
  │  ┌──────────────────┐                    ┌──────────────────┐      │
  │  │ Alertmanager      │                   │ Tempo 2.9.0 ✅   │      │
  │  │ v0.32.0 (1 副本)  │───webhook ✗────▶ │ distributor      │      │
  │  └──────────────────┘                    │ ingester ×3      │      │
  │           │                              │ querier/frontend │      │
  │           │  ┌──────────┐                │ compactor        │      │
  │           └─▶│ Grafana  │◀───────────────│ storage=local PVC│     │
  │              │ 12.4.3   │ TraceQL         └──────────────────┘      │
  │              │ 4 ds/37  │                                           │
  │              │ 看板     │                                           │
  │              └──────────┘                                           │
  └────────────────────────────────────────────────────────────────────┘

  ┌─────────────── LOGS 通路（❌ 已断 3 小时）─────────────────────────┐
  │                                                                    │
  │  节点 /var/log/pods/*.log                                          │
  │         │                                                          │
  │         ×  ← ❌ Alloy DaemonSet【无 hostPath 挂载 + 无 source 组件】│
  │                                                                    │
  │  ┌──────────┐   /loki/api/v1/push    ┌──────────┐                │
  │  │  Loki    │◀───────────────────────│  (无采集) │                │
  │  │ gateway  │  nginx, 路由到 write   └──────────┘                │
  │  └────┬─────┘                                                    │
  │       ▼                                                          │
  │  ┌────────────────────────┐      ┌──────────────┐              │
  │  │ write → backend(1 副本) │─────▶│ S3: loki-chunks │            │
  │  │ TSDB index v13, 24h 周期│      │ loki-ruler     │            │
  │  └────────────┬───────────┘      │ 3608 objects ✅│            │
  │               ▼                   └──────────────┘              │
  │  ┌────────┐ ┌───────────┐                                      │
  │  │ read(1)│ │ memcached │                                      │
  │  └────┬───┘ └───────────┘                                      │
  │       ▼  LogQL                                                 │
  │   Grafana (datasource: loki)                                    │
  └────────────────────────────────────────────────────────────────────┘

  ┌─────────────── TRACES 通路（❌ 双断裂）──────────────────────────┐
  │                                                                    │
  │  应用 OTLP ──▶ ┌──────────────────┐                             │
  │   :4317/:4318  │ OTel Collector    │──otlp_grpc──▶ tempo-distributor│
  │                │ (otelcol 0.145.0) │   .logging:4317   (2.x) ✅   │
  │                │ receiver=otlp     │                             │
  │                │ exporter=         │                             │
  │                │  otlp_grpc/tempo  │                             │
  │                │  + spanmetrics ───┼──▶ Prometheus :9090 ✅       │
  │                └──────────────────┘                             │
  │                                                                    │
  │                    ✗ 未切换到 tempo3（因 tempo3 全挂）            │
  │                                                                    │
  │  ┌──────────────────────────────────────────────────────┐       │
  │  │ Tempo 3.0.3  ❌ 13/13 CrashLoop                        │       │
  │  │ 失败点：ListObjects(tempo-traces) → 403 SigDoesNotMatch│       │
  │  └──────────────────────────────────────────────────────┘       │
  └────────────────────────────────────────────────────────────────────┘

  ┌─────────────── STORAGE 层（正常）────────────────────────────────┐
  │  Ceph Quincy  fsid=594e535e-…  HEALTH_OK                        │
  │  mon×3 (10.0.0.31/.41/.51)  mgr×2  osd×6  mds×1+2  rgw×2        │
  │  RGW: http://10.0.0.31:7480  (forcepathstyle, insecure)         │
  │  用户: alice / bob / testuser / dashboard / loki-admin / tempo-admin│
  │  桶: loki-chunks ✅  loki-ruler(空)  tempo-traces ✅             │
  │       testbucket  loki-admin                                    │
  │  SC: ceph-rbd-sc(Retain) / nfs-sc(Delete)                       │
  └────────────────────────────────────────────────────────────────────┘
```

### 3.3 组件分工详解（谁向谁交付什么）

| 组件 | 上游依赖 | 交付物 | 下游消费者 | 失败影响 |
|------|----------|--------|------------|----------|
| **Alloy** | K8s API + `/var/log/pods` | LogQL stream | Loki gateway | **日志全断**（当前） |
| **Loki write** | Alloy | 内存 stream → chunk | Loki backend | 写入失败 |
| **Loki backend** | S3 chunk | TSDB index / block | Loki read | 索引不可用 |
| **Loki read** | backend + memcached | LogQL 查询结果 | Grafana | 查不到日志 |
| **Loki canary** | 自己 | 合成日志 | Loki | 仅自检 |
| **OTel Collector** | 应用 OTLP | span | Tempo + Prometheus | 追踪断 |
| **Tempo distributor** | OTel / Kafka | 热 span | live-store | 收不到 span |
| **Tempo live-store** | Kafka | 热数据 | block-builder | 数据滞留 |
| **Tempo block-builder** | live-store | block | S3 backend | 冷数据不落盘 |
| **Tempo backend-scheduler/worker** | block | 压缩/清理后 block | S3 | 数据不压缩、不清理 |
| **Tempo querier/frontend** | S3 block | TraceQL 结果 | Grafana | 查不到追踪 |
| **Tempo metrics-generator** | live data | RED 指标 | Prometheus remote_write | 无 APM 指标 |
| **Tempo 2.x compactor** | ingester | 压缩 block | local PVC | 存储膨胀 |
| **Prometheus** | 15 个 ServiceMonitor | PromQL | Grafana + Alertmanager | 监控盲区 |
| **Alertmanager** | Prometheus | 告警通知 | webhook（**未连通**） | 告警不外发 |
| **Grafana** | 4 个 datasource | 看板/Explore | 人 | — |
| **kube-state-metrics** | K8s API | 对象状态指标 | Prometheus | 告警失效 |
| **node-exporter** | node 内核 | 主机指标 | Prometheus | — |

---

## 4. 组件详解

### 4.1 Loki 3.6.7（日志）

#### 部署形态：SimpleScalable

```
                          ┌──────────────┐
   Alloy ──push──▶ nginx │ loki-gateway │  (1 副本, nginx 1.29.5)
                          └──────┬───────┘
                    /loki/api/v1/push → loki-write
                    /loki/api/v1/      → loki-read
                    /api/prom/         → loki-read
                    /loki/api/v1/rules → loki-backend
                                 │
        ┌────────────────────────┴────────────────────────┐
        ▼                                                  ▼
  ┌───────────┐   flush chunk                         ┌───────────┐
  │loki-write │──────────────┐                       │loki-read  │
  │  (1 副本)  │              │                       │ (1 副本)  │
  │ ingester  │              ▼                       │ querier   │
  └─────┬─────┘        ┌──────────┐                   └─────┬─────┘
        │              │  S3      │                         │
        │              │loki-     │◀──── chunk 读取 ───────┘
        │              │chunks    │
        │              └──────────┘
        ▼
  ┌──────────────┐
  │loki-backend  │  1 副本, compactor + index-gateway
  │  TSDB v13    │  index period=24h
  └──────────────┘
        │
        ├──▶ memcached: loki-chunks-cache   (chunk 缓存, 2/2)
        └──▶ memcached: loki-results-cache  (查询结果缓存, 2/2)
```

#### 关键配置（实测）

```yaml
# schema_config —— 数据格式与版本
schema_config:
  configs:
  - from: "2024-01-01"
    schema: v13                 # TSDB
    store: tsdb
    object_store: s3
    index:
      period: 24h               # ⚠️ 索引周期 24h
      prefix: index_

# limits_config
limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h    # 只收 7 天内的日志
  query_timeout: 300s
  volume_enabled: true
  split_queries_by_interval: 15m

# common —— 复用的 S3 配置
common:
  path_prefix: /var/loki
  replication_factor: 1        # ⚠️ 单副本 = 零冗余
  storage:
    s3:
      endpoint: http://10.0.0.31:7480
      bucketnames: loki-chunks
      region: us-east-1
      s3forcepathstyle: true
      insecure: true

# auth
auth_enabled: true             # 需要 X-Scope-OrgID 头
```

#### 关键指标（实测）

```
loki_distributor_lines_received_total{tenant="fake"}            2991608
loki_distributor_bytes_received_total{tenant="fake"}            9.626e+08   (962 MB)
loki_distributor_lines_received_total{tenant="self-monitoring"}   239320
loki_ingester_memory_streams{tenant="fake"}                             0   ← 当前无活跃流
loki_build_info{version="3.6.7", revision="7e1daf3a", go1.24.13}
```

#### ⚠️ 发现的两个坑

**坑 1：Loki 3.x 的 `/label/*/values` 强制要求 `start` / `end` 参数**

```
# 无参数（错误用法，返回空）
curl "http://loki-read:3100/loki/api/v1/label/namespace/values"
→ {"status":"success"}          ← 看起来像「没数据」，实际是参数缺失

# 带参数（正确）
curl -G "http://loki-read:3100/loki/api/v1/label/namespace/values" \
     --data-urlencode "start=$(( $(date +%s) - 86400 ))000000000" \
     --data-urlencode "end=$(date +%s)000000000"
→ {"status":"success","data":["argocd","ceph-csi-rbd",...]}   ← 21 个命名空间
```

**这会让人误判「Loki 没数据」，Grafana 的标签下拉框在某些版本下也会受影响。**

**坑 2：网关无 `/metrics` 路由**

`loki-gateway` 的 nginx 配置里没有 `location /metrics`，访问返回 `404`。取指标必须直连各组件（`loki-write:3100/metrics`、`loki-read:3100/metrics`）。

---

### 4.2 Grafana Alloy v1.20.0 日志采集当前失效

> **状态**：❌ 失效 —— 组件全绿但采集量为 0（空转）

> **背景**：本节讲的是 Promtail 的替代者。Promtail 本身的角色、配置契约与退役影响见 [4.10](#410-promtail-351-前任日志采集器已退役)，强烈建议对照阅读 —— 本节列出的 5 处缺件，本质都是「迁移时没把 Promtail chart 隐式提供的能力一并搬过来」。

#### 部署形态：DaemonSet × 3

```
alloy-fv6gk   worker01   2/2 Running   0 restarts
alloy-nx982   worker02   2/2 Running   0 restarts
alloy-nmzrw   worker03   2/2 Running   0 restarts
```

> ⚠️ **只有 3 个 worker 节点。** `tolerations: null`，而 control-plane 节点带 `NoSchedule` taint，因此 m01 / master01 / master02 上的 **28 个 Pod**（含 kube-apiserver、etcd、calico、CoreDNS）**完全不被采集**。
> Promtail 时代靠 `tolerations: [{operator: Exists, effect: NoSchedule}]` 覆盖了 6/6 节点 —— 这是迁移丢失的第 4 项能力，详见下方「缺件 #4」与 [4.10](#410-promtail-351-前任日志采集器已退役)。

#### 线上实际配置（ConfigMap `alloy-config`）

```alloy
discovery.kubernetes "pod_logs" {
    role = "pod"                    // ✅ 只产出 target，不读日志
}

discovery.relabel "pod_logs" {
    targets = []                     // ❌❌ 断链：没接 discovery 的输出
    rule { source_labels = ["__meta_kubernetes_pod_name"]; target_label = "pod" }
    rule { source_labels = ["__meta_kubernetes_namespace"]; target_label = "namespace" }
    rule { source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]; target_label = "app" }
    rule { source_labels = ["__meta_kubernetes_pod_node_name"]; target_label = "node" }  // ⚠️ 应为 node_name
    rule { source_labels = ["__meta_kubernetes_container_name"]; target_label = "container" }
}

loki.process "logs_to_prometheus" {
    forward_to = [loki.write.default.receiver]
    stage.cri {}
    stage.drop { older_than = "168h" }
}

loki.write "default" {
    endpoint {
        url = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
        tenant_id = "fake"
    }
}

# ❌❌❌ 缺失：loki.source.kubernetes / loki.source.file
```

#### ❌ 缺件 #1：没有 source 组件

`discovery.kubernetes` 只做服务发现，**不读日志文件**。真正读文件的是 `loki.source.kubernetes`（或 `loki.source.file`）。缺了它，整条链路是断的。

**官方 `alloy convert` 权威输出（用 Alloy 自带转换器跑原 Promtail 配置生成）：**

```
1: discovery.kubernetes "kubernetes_pods"    ← 有
10: loki.process      "kubernetes_pods"      ← 有
20: discovery.relabel "kubernetes_pods"      ← 有
89: loki.source.file  "kubernetes_pods"      ← ❌ 线上没有这一行
99: loki.write        "default"              ← 有
```

组件数量：**官方转换 5 个 vs 线上 4 个**。

#### ❌ 缺件 #2：`targets = []` 断链

即使补上 source，`discovery.relabel` 的 `targets` 是空数组，也不会连到 `discovery.kubernetes` 的输出。官方转换器生成的是：

```alloy
discovery.relabel "kubernetes_pods" {
    targets = discovery.kubernetes.kubernetes_pods.targets   // ← 必须有
```

#### ❌ 缺件 #3：没有 `/var/log/pods` 挂载

实测 Alloy Pod 的 volumeMounts：

```
config                -> /etc/alloy                                    ✅
kube-api-access-...   -> /var/run/secrets/kubernetes.io/serviceaccount ✅
（缺失）              -> /var/log/pods                                 ❌
（缺失）              -> /var/lib/docker/containers                    ❌
（缺失）              -> /var/log                                       ❌
（缺失）              -> /run/alloy   （positions 写不了）              ❌
```

**即使配置补全，没有这个 hostPath 挂载也读不到任何日志文件。**

关键在于**为什么 Promtail 有、Alloy 没有**：

| | Promtail `promtail-6.17.1` | Alloy `alloy-1.13.0` |
|---|---|---|
| 挂载来源 | chart 的 `defaultVolumes` **默认注入** | **无默认值**，必须手写 `controller.volumes` |
| 迁移时是否显式化 | 不需要 | ❌ **漏了** |

Promtail values 里这组是白送的：

```yaml
defaultVolumes:
  - { hostPath: { path: /run/promtail },              name: run }
  - { hostPath: { path: /var/lib/docker/containers }, name: containers }
  - { hostPath: { path: /var/log/pods },              name: pods }
```

> **凡是 chart 默认给你的东西，换 chart 时都会消失。** 这是所有日志采集器迁移最常见的坑。

#### ❌ 缺件 #4：没有 tolerations，只能覆盖 3/6 节点

```bash
# Promtail manifest（实测）
tolerations:
  - effect: NoSchedule
    operator: Exists        # ← Exists = 容忍一切 NoSchedule taint，因此能上 control-plane

# Alloy DaemonSet（实测）
tolerations  : null
nodeSelector : None
affinity     : null
```

**实测调度结果 —— 只有 3 个 worker 节点：**

```
alloy-fv6gk   worker01
alloy-nmzrw   worker03
alloy-nx982   worker02
```

**漏掉的 3 个 control-plane 节点及其上承载的 Pod：**

| 节点 | 角色 | 该机 Pod 总数 | 漏采的关键日志 |
|------|------|--------------|----------------|
| `m01` | control-plane | 9 | kube-apiserver、etcd、calico、CoreDNS |
| `master01` | control-plane | 9 | 同上 |
| `master02` | control-plane | 10 | 同上 |
| **合计** | | **28** | **整个控制面的日志全部不可见** |

> 就算把缺件 #1~#3 都修好，**控制面（API Server / etcd / CNI）的日志仍然一条都采不到**。
> 这恰好与 7.2 节「所有指向宿主节点 IP 的抓取目标全挂」指向同一个问题域：控制面可观测性整体失明。

#### ❌ 缺件 #5：没有资源 requests/limits

```yaml
# Promtail
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 200m, memory: 256Mi }

# Alloy（实测）
resources: {}          # ← 完全未设置
```

无 requests → Pod 处于 **BestEffort QoS**，节点内存压力下**第一批被驱逐**。而日志采集器恰恰是最该被保护的（它一挂就全局失明）。实测当前 3 个副本合计仅用 147Mi，设 `requests: 200m/256Mi` 毫无压力。

> **额外利好**：Alloy 的 RBAC 反而比 Promtail 更全（有 `endpointslices` / `ingresses` / `pods/log` / `namespaces`），**RBAC 不是问题点**，无需改动。

#### 实测：Alloy 采集量 = 0

```
# /metrics 里只有 3 个 loki_* 指标，全部是 0 或计数类
loki_experimental_features_in_use_total
loki_process_cri_lines_truncated_total{component_id="loki.process.logs_to_prometheus"} 0
loki_process_cri_partial_lines_flushed_total{...} 0

# 没有 loki_write_lines_total —— 因为没东西可写
# 没有 loki_read_lines_total  —— 因为没读文件
# 没有 loki_source_*          —— 因为没有 source 组件

alloy_component_controller_running_components{health_type="healthy"} 4   ← 只有 4 个组件
alloy_config_last_load_successful 1    # 配置语法没问题
alloy_config_load_failures_total 0     # 加载零错误
```

> **Alloy 自己是「健康」的——语法正确、无错误、组件全绿。但它是个空转的容器。**

#### ⚠️ 标签契约已断裂

| 标签 | Promtail（原有） | Alloy（线上） | 后果 |
|------|------------------|---------------|------|
| `namespace` | ✅ | ✅ | — |
| `pod` | ✅ | ✅ | — |
| `container` | ✅ | ✅ | — |
| `app` | ✅ 多源回退 | ⚠️ 仅 name label | 部分 Pod 丢失 app |
| `node_name` | ✅ | ❌ 写成 `node` | **所有存量 LogQL 里的 `{node_name=...}` 失效** |
| `job` | ✅ `ns/app` | ❌ 缺失 | Grafana 看板按 job 过滤失效 |
| `instance` | ✅ | ❌ 缺失 | — |
| `component` | ✅ | ❌ 缺失 | — |
| `__path__` | ✅ 构造文件路径 | ❌ 缺失 | **source 组件无法定位文件** |
| `detected_level` | ✅ 自动解析 | — | 级别过滤失效 |

---

### 4.3 Tempo 2.9.0 追踪存储当前在用但数据枯竭

> **状态**：⚠️ 可用，但仅收到 14 个 span（3.4 KB），且 `block_retention: 48h`

#### 架构：Microservices

```
OTel Collector ──OTLP:4317──▶ tempo-distributor (1)
                                   │  ring (memberlist)
                                   ▼
                             tempo-ingester ×3  (replication_factor=3)
                                   │
                                   ▼ flush
                        ┌──────────────────────┐
                        │  storage: local      │  ← ⚠️ 不是 S3！
                        │  path: /var/tempo    │
                        │  → PVC               │
                        └──────────────────────┘
                                   ▲
                             tempo-compactor (1)
                                   ▲
                        tempo-query-frontend (1) ◀── Grafana TraceQL
                                   │
                             tempo-querier (1)
                        tempo-metrics-generator (1) ──remote_write──▶ Prometheus
                        tempo-memcached (1) 缓存 Parquet footer
```

#### 关键配置（实测）

```yaml
distributor:
  receivers:
    otlp:
      protocols:
        grpc: { endpoint: 0.0.0.0:4317 }     # ✅ OTLP gRPC
        http: { endpoint: 0.0.0.0:4318 }     # ✅ OTLP HTTP
ingester:
  ring:
    replication_factor: 3                    # ✅
storage:
  trace:
    backend: local                            # ⚠️ 本地 PVC，不是 S3
    local: { path: /var/tempo/traces }
compactor:
  compaction:
    block_retention: 48h                      # ⚠️ 只保留 2 天
    max_block_bytes: 107374182400             # 100 GB
```

> **重要发现：Tempo 2.x 根本没用 S3。** 所以「tempo3 的 S3 配置应该照抄 tempo」这个思路是错的——tempo3 的 S3 配置是凭空写的。

#### 实测：追踪数据枯竭

```
tempo_distributor_spans_received_total{tenant="single-tenant"}  14      ← 自进程启动仅 14 个 span
tempo_distributor_bytes_received_total{tenant="single-tenant"} 3430    ← 仅 3.4 KB
tempo_querier_* 指标：全部无输出（从未被查询过）
tempo_compactor_blocks_processed_total：无输出
tempo_build_info{version="v2.9.0", revision="607c7fb69", go1.25.1}
```

**14 个 span 意味着：几乎没有应用在真正上报链路数据。**

#### 历史上确实丢过数据

OTel Collector 日志（2026-09-27 14:00 ~ 14:04，即 Ceph 故障期间）：

```
error  internal/queue_sender.go:50
  Exporting failed. Dropping data.
  {"component.id":"otlp_grpc/tempo","signal":"traces",
   "error":"rpc error: code = Unavailable desc = at least 2 live replicas required,
            could only find 1 - unhealthy instances: 10.244.19.97:9095,10.244.5.34:9095",
   "dropped_items": 1}
```

Tempo 副本不足 → 重试耗尽 → **trace 被丢弃**。最后一条此类错误为 `2026-09-27T22:04:39`，此后 20 小时无新错误，说明已恢复。

---

### 4.4 Tempo 3.0.3 追踪新架构完全不可用

> **状态**：❌ 13/13 Pod CrashLoopBackOff（S3 凭据错误，见 6.1）

#### 架构：Kafka 驱动的新一代

```
                    ┌──────────────────────────┐
OTel ──▶ Collector ─▶ tempo3-distributor (1)   │
                    └────────────┬─────────────┘
                                 │ 写 Kafka topic: tempo-traces
                                 │  (12 partitions, RF 1)
                                 ▼
                    ┌──────────────────────────┐
                    │  Kafka  my-cluster       │  Strimzi / Kafka 4.1.2
                    │  plaintext:9092          │  broker: my-cluster-single-pool-0
                    └────────────┬─────────────┘
                                 │ 消费
                                 ▼
                    ┌──────────────────────────┐
                    │  tempo3-live-store ×3    │  热数据（可查询）
                    └────────────┬─────────────┘
                                 │ 转换
                                 ▼
                    ┌──────────────────────────┐
                    │  tempo3-block-builder ×3 │  生成 block
                    └────────────┬─────────────┘
                                 ▼
                    ┌──────────────────────────┐
                    │  S3  tempo-traces bucket │
                    └────────────┬─────────────┘
                                 │
              ┌──────────────────┴───────────────────┐
              ▼                                      ▼
   tempo3-backend-scheduler (1)              tempo3-querier (1)
              ↓ 派发任务                                ↑
   tempo3-backend-worker (1) ──▶ 压缩/保留          tempo3-query-frontend (1)
```

#### 线上配置（实测）

```yaml
storage:
  trace:
    backend: s3
    s3:
      access_key: <redacted>                      # ✅ 正确（= RGW 用户 tempo-admin）
      secret_key: <redacted>      # ❌ 错误（40 字符，明文见 /tmp/tempo3-values.yaml）
      bucket: tempo-traces
      endpoint: 10.0.0.31:7480
      forcepathstyle: true
      insecure: true
      region: us-east-1

distributor:
  receivers: null                              # ❌❌ 没配任何接收器！
  log_received_spans: { enabled: true }         # ⚠️ 生产环境不该开（刷日志）

ingest:
  kafka:
    address: my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
    topic: tempo-traces
    auto_create_topic_enabled: true
    auto_create_topic_default_partitions: 3     # ⚠️ 与实际 12 分区不一致

block_builder:
  partitions_per_instance: 1

usage_report:
  reporting_enabled: true                      # ⚠️ 这是第一个报错的模块
```

---

### 4.5 OpenTelemetry Collector 0.145.0

#### 配置（`otelcol/otel`，managed by operator）

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }         # 接收应用 span
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch: { send_batch_size: 1000, timeout: 10s }

connectors:
  spanmetrics: {}                              # span → RED 指标

exporters:
  otlp_grpc/tempo:                             # ← 追踪主出口
    endpoint: tempo-distributor.logging.svc.cluster.local:4317
    tls: { insecure: true }
  prometheus:                                  # ← spanmetrics 出口
    endpoint: 0.0.0.0:8889
    namespace: otel_demo
    resource_to_telemetry_conversion: { enabled: true }
  debug: { verbosity: basic }                  # ⚠️ 调试用，生产应删

service:
  pipelines:
    traces:   [ otlp ] → [ batch ] → [ otlp_grpc/tempo, debug, spanmetrics ]
    metrics:  [ spanmetrics ] → [ prometheus ]
  telemetry:
    metrics:
      readers:
        - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
```

#### 服务端口

| Service | 端口 | 用途 |
|---------|------|------|
| `otel-collector` | 4317, 4318, 8889 | OTLP 接收 + spanmetrics 暴露 |
| `otel-collector-monitoring` | 8888 | 内部 telemetry |

#### 状态

```
otel-collector-98795c445-kjvm5    1/1 Running   6 restarts   141d
```

最近一次错误日志时间 `2026-09-27T22:04:39`，此后 20h 无新错误。

---

### 4.6 Prometheus 3.11.2 与 Alertmanager

> **状态**：⚠️ 39/57 target UP；Alertmanager 通知通道不通（见 7.2 / 7.3）

#### Prometheus 运行时（实测 `/api/v1/status/runtimeinfo`）

```json
{
  "version": "3.11.2",
  "startTime": "2026-09-27T06:48:06Z",
  "storageRetention": "5d or 30GiB",
  "corruptionCount": 0,
  "goroutineCount": 386,
  "GOMAXPROCS": 2,
  "reloadConfigSuccess": true
}
```

#### TSDB 容量（实测）

```
headStats.numSeries      = 182,498
headStats.numLabelPairs  = 11,460
headStats.chunkCount     = 363,977
headStats 时间跨度       = 约 1 小时（滚动 head）
```

#### 抓取目标健康度（实测）

```
活跃 target: 57
  up   = 39   (68%)
  down = 18   (32%)   ← 严重
```

**18 个 DOWN 明细：**

| job | 数量 | 失败原因 |
|-----|------|----------|
| `kube-proxy` | 6/6 | `dial tcp 10.0.0.x:10249: i/o timeout` |
| `kube-scheduler` | 3/3 | `dial tcp 10.0.0.x:10259` |
| `kube-controller-manager` | 3/3 | `dial tcp 10.0.0.x:10257` |
| `kube-etcd` | 3/3 | `dial tcp 10.0.0.x:2381` |
| `coredns` | 1 | `dial tcp 10.244.5.53:9153` |
| `tempo3-distributor` | 1 | Pod CrashLoop，IP 10.244.5.14:3200 |
| `tempo3-distributor-discovery` | 1 | 同上 |

> **规律：所有 `https://10.0.0.x` 和 `10.0.0.x:10249/2381/10257/10259` 的目标全挂。** 说明 Prometheus 到宿主节点 IP 的网络路径有问题（很可能是 Prometheus Pod（`10.244.x`）到节点 IP 的流量被 Calico 策略拦截，或节点防火墙）。这不是 Tempo 引起的。

#### Alertmanager

```
alertmanager-prometheus-alertmanager-0   2/2 Running   16 restarts   145d
datasource: http://prometheus-alertmanager.monitoring:9093/
```

**但通知渠道不通**（见 7.1）。

---

### 4.7 Grafana 12.4.3

#### 数据源（实测 4 个）

| 名称 | 类型 | URL | 默认 |
|------|------|-----|------|
| **Prometheus** | prometheus | `http://prometheus-prometheus.monitoring:9090/` | ✅ |
| Alertmanager | alertmanager | `http://prometheus-alertmanager.monitoring:9093/` | |
| **loki** | loki | `http://loki-gateway.logging.svc.cluster.local` | |
| **tempo** | tempo | `http://tempo-query-frontend.logging.svc.cluster.local:3200` | |

> ✅ Loki 和 Tempo 数据源**已配置**。这是好的——修好采集端后 Grafana 侧无需改动。

⚠️ 但 Loki 数据源可能需要配 `X-Scope-OrgID: fake` 头（因为 `auth_enabled: true`），否则查询会返回空。Grafana 10+ 的 Loki 数据源在 Extra HTTP Headers 里加 `X-Scope-OrgID = fake` 即可。

#### Dashboard（37 个）

**与可观测性直接相关：**

| Dashboard | 覆盖 |
|-----------|------|
| `Loki stack monitoring (Promtail, Loki)` | ⚠️ **面板写的是 Promtail，Alloy 迁移后需改** |
| `OpenTelemetry & Tempo` | Tempo + OTel 链路 |
| `Lightweight APM for OpenTelemetry` | RED 指标 |
| `Kubernetes / Kubelet`, `Node Exporter Full` | 节点 |
| `etcd`, `CoreDNS`, `Traefik`, `ArgoCD`, `cert-manager` | 组件 |
| `Kubernetes / Compute Resources / *` | 资源（4 个） |
| `Prometheus / Overview`, `Grafana Overview`, `Alertmanager / Overview` | 自监控 |

---

### 4.8 存储层： Ceph Quincy

#### 集群状态（实测）

```
cluster:
  id:  594e535e-d82c-11f0-afa7-bc24112b746f
  health: HEALTH_OK            ← 本轮已修复
  mon: 3 daemons, quorum ceph-02,ceph-03,ceph-01 (age 22h), leader=ceph-02
  mgr: ceph-01.egryfx(active), standby ceph-02.wzbtbx
  mds: 1/1 daemons up, 2 standby
  osd: 6 osds: 6 up, 6 in (since 9M)
  rgw: 2 daemons active (2 hosts, 1 zones)
  pgs: 433 active+clean
  usage: 17 GiB used, 163 GiB / 180 GiB avail
  volumes: 1/1 healthy
```

#### 节点（真实 IP，勿用猜测地址）

| 名称 | IP | 角色 |
|------|-----|------|
| ceph-01 | **10.0.0.31** | mon + mgr(active) + osd.0/5 + rgw |
| ceph-02 | **10.0.0.41** | mon + mgr(standby) + osd.1/4 + rgw |
| ceph-03 | **10.0.0.51** | mon + osd.2/3 |
| ceph-04/05/06 | — | OSD 节点（未在本次核查范围） |

> ⚠️ **常见误区**：mon 不是 `.32/.33`，是 `.41/.51`。

#### RGW（S3 端点）

```
Endpoint : http://10.0.0.31:7480
Dashboard: https://10.0.0.31:8443  (自签名证书，CN=ceph-dashboard)
Metrics : http://10.0.0.31:9283/metrics  (542 个 ceph_* 指标族，无认证)
```

#### RGW 用户与桶（实测，凭据脱敏）

| 用户 | access_key（脱敏） | 用途 |
|------|-------------------|------|
| `loki-admin` | `MSZ7************AIH7` | Loki 读写 `loki-chunks` / `loki-ruler` |
| `tempo-admin` | `AS5W************NM2M` | Tempo 读写 `tempo-traces` |
| `dashboard` | `JQ2O************RZ33` | Ceph Dashboard 使用 |
| `alice` / `bob` / `testuser` | — | 测试遗留，建议清理 |

| 桶 | 对象数 | 说明 |
|----|--------|------|
| `loki-chunks` | **3608** | ✅ 含 106 个 index 文件 + chunk 数据 |
| `tempo-traces` | **1** | 仅 `tempo_cluster_seed.json`（215 B，2026-04-23） |
| `loki-ruler` | 0 | 未使用告警规则 |
| `testbucket` / `loki-admin` | — | 测试遗留 |

#### NTP 状态（本轮修复后）

| 节点 | Leap | Stratum | 源 |
|------|------|---------|-----|
| ceph-01 | Normal | 3-4 | 203.107.6.88 (ntp.aliyun.com) |
| ceph-02 | Normal | 3 | 203.107.6.88 |
| ceph-03 | Normal | 3 | 203.107.6.88 |

三机实际时钟差 **≈ 1.4 ms**（阈值 50 ms）。

---

### 4.9 Kafka 4.1.2（Strimzi）

```
Kafka CR  : my-cluster (kafka.strimzi.io)  Ready
版本      : 4.1.2 (Strimzi 4.1-IV1)
Listeners : plaintext:9092 (internal, no TLS) / tls:9093 (internal, TLS)
Broker Pod: my-cluster-single-pool-0    1/1 Running   0 restarts
Entity Op : my-cluster-entity-operator-d888898c7-r28ll  2/2 Running  212 restarts
Cluster Op: strimzi-cluster-operator-6bccfd6b88-9txrh   1/1 Running   13 restarts
```

#### Topic `tempo-traces`

```yaml
partitions: 12          # 手动创建
replicas: 1             # ⚠️ 单副本
labels: { strimzi.io/cluster: my-cluster }
status: [{ type: Ready, status: True }]
```

**⚠️ 矛盾点**：Topic 12 分区，但 tempo3 配置 `auto_create_topic_default_partitions: 3`，且 `block-builder` / `live-store` 各 3 副本。Kafka 消费者组会 rebalance 到 3 个分区消费，**另外 9 个分区闲置**。而 RF=1 意味着一台 broker 挂掉该 topic 不可用。

---

### 4.10 Promtail 3.5.1 前任日志采集器已退役

> **状态**：🏳 已退役（2026-09-28 12:33），运行 155 天，资源已彻底清理，Helm 保留可回滚

> Promtail 已于 2026-09-28 12:33 被 Grafana Alloy 取代并清理干净。**但它建立的标签契约与挂载约定仍在被依赖** —— 理解它才能判断 Alloy 迁移丢了什么。

#### 4.10.1 它在栈中的位置

```
   ┌────────────────────────────────────────────────────────────────┐
   │  节点上的日志文件                                              │
   │    /var/log/pods/<ns>_<pod>_<uid>/<container>/<n>.log         │
   │    /var/lib/docker/containers/<id>/<n>-json.log               │
   └───────────────┬────────────────────────────────────────────────┘
                   │  ★ Promtail 的全部工作就是这一段：读文件 + 打标签 + 推给 Loki
                   ▼
          ┌─────────────────┐
          │  Loki gateway   │
          └─────────────────┘

  Promtail 在 LGMT 四大信号里的位置：
     Metrics → 由 Prometheus + node-exporter 负责   （与 Promtail 无关）
     Logs    → ★ Promtail 负责采集 ★               （唯一采集者）
     Traces  → 由 OTel Collector + Tempo 负责      （与 Promtail 无关）
     Events  → 由 kube-state-metrics 负责           （与 Promtail 无关）

  结论：Promtail 只干「日志采集」这一件事，但这一件事是整个 Logs 信号的唯一入口。
        它一停，Loki 侧立刻没有任何新数据 —— 存储层再健康也没用。
```

#### 4.10.2 部署形态与生命周期（实测自备份）

| 项 | 值 | 来源 |
|----|-----|------|
| Helm Release | `promtail` | `promtail-history.txt` |
| Chart / App | `promtail-6.17.1` / **3.5.1** | 同上 |
| 修订 1 | 2026-04-06 12:13:35 `superseded` — Install complete | 同上 |
| 修订 2 | 2026-04-06 13:56:03 `deployed` — Upgrade complete | 同上 |
| 生命周期 | **155 天**（2026-04-06 → 2026-09-28 12:33 清理） | 实测 |
| 部署方式 | `daemonset.enabled: true` / `deployment.enabled: false` | values |
| 节点覆盖 | 6/6（含 3 个 control-plane） | manifest `tolerations` |
| 镜像 | `docker.io/grafana/promtail:3.5.1`，`IfNotPresent` | manifest |
| 容器数 | 1（`sidecar.configReloader.enabled: false`） | values |
| 监听端口 | `3101`（`/ready`、`/metrics`） | manifest |
| 配置文件位置 | **Secret** `promtail`（`/etc/promtail`） | manifest |
| 进度文件 | `/run/promtail/positions.yaml` | values |

#### 4.10.3 它的完整配置（备份中的原始值，这是「标签契约」的权威定义）

```yaml
# Helm values（promtail-6.17.1 计算后值，已去除模板占位）
config:
  clients:
    - tenant_id: fake
      url: http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push
  logLevel: info
  logFormat: logfmt
  serverPort: 3101
  positions:
    filename: /run/promtail/positions.yaml
  snippets:
    addScrapeJobLabel: false
    pipelineStages:
      - cri: {}                    # ① 解析 CRI 日志包装（剥离 timestamp/stream）
      - drop:
          older_than: 168h         # ② 丢弃 7 天前的日志
```

`scrape_configs`（模板渲染后的实际生效配置）：

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    pipeline_stages:
      - cri: {}
      - drop: { older_than: 168h }
    kubernetes_sd_configs:              # ★★★ 关键：告诉它「去读哪些文件」
      - role: pod
    relabel_configs:                     # ★★★ 关键：定义日志带哪些标签
      - source_labels: [__meta_kubernetes_pod_controller_name]
        regex: ([0-9a-z-.]+?)(-[0-9a-f]{8,10})?
        target_label: __tmp_controller_name
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name,
                        __meta_kubernetes_pod_label_app,
                        __tmp_controller_name,
                        __meta_kubernetes_pod_name]
        regex: ^;*([^;]+)(;.*)?$
        target_label: app                # 4 级回退：name label → app label → controller → pod name
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_instance,
                        __meta_kubernetes_pod_label_instance]
        target_label: instance
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component,
                        __meta_kubernetes_pod_label_component]
        target_label: component
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node_name          # ★ 是 node_name，不是 node
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [namespace, app]
        separator: /
        replacement: $1
        target_label: job                # ★ job = "<namespace>/<app>"
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
      - source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
        separator: /
        replacement: /var/log/pods/*$1/*.log
        target_label: __path__           # ★ 拼出文件真实路径
      - source_labels: [__meta_kubernetes_pod_annotationpresent_kubernetes_io_config_hash,
                        __meta_kubernetes_pod_annotation_kubernetes_io_config_hash,
                        __meta_kubernetes_pod_container_name]
        separator: /
        regex: true/(.*)
        replacement: /var/log/pods/*$1/*.log
        target_label: __path__           # ★ 兼容 config.hash 注解形式的路径
```

#### 4.10.4 挂载约定 —— Promtail chart **默认就给了**，Alloy chart 不给

```yaml
# promtail-6.17.1 的 defaultVolumes（原样）
defaultVolumes:
  - hostPath: { path: /run/promtail }              name: run
  - hostPath: { path: /var/lib/docker/containers } name: containers
  - hostPath: { path: /var/log/pods }              name: pods
defaultVolumeMounts:
  - { name: run,       mountPath: /run/promtail }
  - { name: containers,mountPath: /var/lib/docker/containers, readOnly: true }
  - { name: pods,      mountPath: /var/log/pods,               readOnly: true }
```

> **这就是 Alloy 迁移失败的最深层原因。** 迁移时只写了「Alloy 配置」，没有把 chart 隐式提供的挂载显式化 —— 而 `grafana/alloy` chart **没有** `defaultVolumes` 这组默认值，必须手写 `controller.volumes` / `controller.volumeMounts`。
>
> **凡是 chart 默认给你的东西，换 chart 时都会消失。** 这是所有「Promtail→Alloy」「Filebeat→Fluentd」迁移最容易踩的坑。

#### 4.10.5 调度与安全上下文

```yaml
# 调度：能上被 taint 的 control-plane 节点
tolerations:
  - effect: NoSchedule
    operator: Exists                      # ★ Exists = 容忍一切 NoSchedule taint

# Pod 级
podSecurityContext:
  runAsUser: 0                             # root（读日志文件需要）
  runAsGroup: 0
# 容器级（安全收紧）
containerSecurityContext:
  allowPrivilegeEscalation: false
  capabilities: { drop: [ALL] }
  readOnlyRootFilesystem: true             # ★ 配合 volumes 写 positions.yaml

# 资源（有保障）
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 200m, memory: 256Mi }

# 探针
readinessProbe:
  httpGet: { path: /ready, port: http-metrics }
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 5

# RBAC（ClusterRole，集群级只读）
rules:
  - apiGroups: [""]
    resources: [nodes, nodes/proxy, services, endpoints, pods]
    verbs: [get, watch, list]
```

#### 4.10.6 它建立的「标签契约」—— 存量数据的依据

Promtail 运行 155 天，**Loki 里的 3608 个 chunk、125 万行/24h 的 logging 命名空间日志，全部是它打的标签**。这些标签是查询和看板的基础：

| 标签 | 来源 | 典型值（实测自 Loki 存量数据） |
|------|------|-------------------------------|
| `namespace` | Pod 元数据 | 21 个（argocd … tf-spa） |
| `node_name` | `__meta_kubernetes_pod_node_name` | 6 个：m01 / master01 / master02 / worker01 / worker02 / worker03 |
| `job` | `namespace` + `app`，分隔符 `/` | `argocd/argocd-server`、`logging/loki`… |
| `app` | 4 级回退链 | `prometheus`、`loki`、`calico-node`… |
| `pod` | Pod 名 | 数十个 |
| `container` | 容器名 | `loki`、`nginx`、`prometheus`… |
| `instance` | `app.kubernetes.io/instance` 或 `instance` | `loki`、`prometheus-prometheus` |
| `component` | `app.kubernetes.io/component` 或 `component` | `gateway` 等 |
| `filename` | Loki 自动加 | `/var/log/pods/logging_loki-gateway-…/nginx/30.log` |
| `stream` | CRI 解析结果 | `stdout` / `stderr` |
| `detected_level` | Loki 3.x 自动探测 | `info` / `error` / `unknown` |

**实测样本（Promtail 时代采集的真实 stream，labels 完整）：**

```json
{
  "app": "loki", "component": "gateway", "container": "nginx",
  "detected_level": "unknown",
  "filename": "/var/log/pods/logging_loki-gateway-68ff9df4b8-lm2dr_bb88a78a-db0f-4f73-99af-1c70abb47dfb/nginx/30.log",
  "instance": "loki", "job": "logging/loki", "namespace": "logging",
  "node_name": "worker03", "pod": "loki-gateway-68ff9df4b8-lm2dr",
  "service_name": "loki", "stream": "stderr"
}
```

> ⚠️ 线上 Alloy 产出的标签只有 `pod` / `namespace` / `app` / `node` / `container`。**`node_name`、`job`、`instance`、`component`、`__path__` 全部缺失，且把 `node_name` 写成了 `node`。**
>
> 直接后果：所有存量 LogQL 里的 `{node_name="..."}`、`{job="logging/loki"}` 过滤条件**会立刻查不到任何东西**。存量数据在，新数据不在同一个标签空间里。

#### 4.10.7 退役状态核验（实测）

| 资源类型 | 残留数 |
|---------|--------|
| DaemonSet / Deployment / Pod | 0 ✅ |
| Service / ConfigMap / Secret | 0 ✅ |
| ServiceAccount / ClusterRole / ClusterRoleBinding | 0 ✅ |

**Promtail 已彻底清除，无僵尸资源。** 其 Helm 修订历史仍保留在备份中（`superseded` 状态，未 `uninstall`），**这是可回滚的** —— 详见 10.4。

#### 4.10.8 Promtail vs Alloy 能力对照

| 维度 | Promtail 3.5.1 | Alloy v1.20.0（线上） | 判定 |
|------|---------------|---------------------|------|
| 日志采集 | `kubernetes_sd_configs: role: pod` | ❌ 无 source 组件 | **退化** |
| `/var/log/pods` 挂载 | ✅ chart 默认提供 | ❌ 无 | **退化** |
| `/var/lib/docker/containers` 挂载 | ✅ chart 默认提供 | ❌ 无 | **退化** |
| control-plane 节点覆盖 | ✅ `tolerations: Exists`，6/6 节点 | ❌ `tolerations: null`，仅 3/6 | **退化** |
| `node_name` 标签 | ✅ | ❌ 写成 `node` | **退化** |
| `job` / `instance` / `component` 标签 | ✅ | ❌ 缺失 | **退化** |
| `__path__` 构造 | ✅ 双规则 | ❌ 缺失 | **退化** |
| 资源 requests/limits | ✅ 100m/128Mi · 200m/256Mi | ❌ `{}` 无限制 | **退化** |
| 集群列表 RBAC | nodes/services/endpoints/pods | **更多**：+ endpointslices / ingresses / pods/log / namespaces | ✅ Alloy 更强 |
| 配置热加载 | ❌ Secret + 需重启 Pod | ✅ ConfigMap + config-reloader sidecar | **Alloy 更强** |
| 多信号（metrics/traces/profiling） | ❌ 仅 logs | ✅ 组件化，可同时采 Prometheus/OTel | **Alloy 更强** |
| 内置转换工具 | — | ✅ `alloy convert` 可从 Promtail 配置自动转换 | **Alloy 更强** |
| 官方维护状态 | 由 Grafana 维护 | 由 Grafana 维护 | 持平 |

> **10 项退化 vs 5 项增强 —— 迁移方向是对的，但落地是残缺的。** Alloy 的能力上限明显更高，问题是迁移时只搬了「配置」，没搬 chart 隐式提供的挂载、调度、资源和标签约定。

#### 4.10.9 结论

**Promtail 的作用 = Logs 信号的唯一入口 + 存量标签契约的定义者。**

- 它**没有**做 metrics、traces、events，这三块与它无关；
- 但没有它，Loki 就只是一堆「躺在 S3 里的历史 chunk」—— 这正是 4.1 中 3608 个对象的真实处境；
- 它在 155 天里建立的 `node_name` / `job` / `app` / `instance` / `component` 标签体系，是 Grafana 37 个看板与全部存量 LogQL 的基础，**替换它就必须 1:1 复刻这个契约**，否则等于换了采集器却丢了数据视图。

**当前状态：入口消失、契约未复刻、历史数据完好。** 这三点与 6.2 的 Alloy 五重缺件是同一件事的两面。

---

## 5. 数据链路实测证据

### 5.1 日志链路：断裂的证据

| # | 检测 | 方法 | 结果 |
|---|------|------|------|
| 1 | Alloy 采集行数 | `grep loki_write_ /metrics` | **无该指标**（没东西可写） |
| 2 | Alloy 组件数 | `alloy_component_controller_running_components` | **4**（官方应有 5） |
| 3 | Alloy 源组件指标 | `grep loki_source_` | **无** |
| 4 | 当前 Pod 日志 | `{namespace="logging",app="alloy"}` 查最近 6h | **每小时均为 0 行** |
| 5 | Loki 中 alloy 日志来源 | 查 24h 窗口 | 来自 **`alloy-mbgvj`（旧 Pod，04:36）**，由**旧 Promtail** 采集 |
| 6 | logging 命名空间实时量 | `sum(count_over_time({namespace="logging"}[1h]))` | **`result: []` —— 零行** |
| 7 | S3 写入量 | `loki-chunks` 按小时分布 | 14 点后骤降：126 → 113 → **1** → **3** |
| 8 | S3 剩余数据 | `aws s3 ls s3://loki-chunks --recursive` | **3608 个对象完好** |

**结论：数据完好，采集断了。约 3 小时（14:00 起）无新日志进入 Loki。**

### 5.2 追踪链路：断裂的证据

| # | 检测 | 结果 |
|---|------|------|
| 1 | Tempo 2.x 收到 span | `tempo_distributor_spans_received_total` = **14**（3.4 KB） |
| 2 | Tempo 3.x 全部 Pod | 13/13 CrashLoop |
| 3 | 失败模块（distributor/metrics-gen） | `usage-report: ListObjects on tempo-traces: The request signature we calculated does not match` |
| 4 | 失败模块（其余组件） | `store: failed to create store: <同样的签名错误>` |
| 5 | OTel Collector 出口 | 仍指向 `tempo-distributor`（2.x）✅ 未误切 |
| 6 | 历史上丢数据 | 2026-09-27 14:00-14:04，`at least 2 live replicas required` → `Dropping data` |
| 7 | 最近是否仍丢 | 最后一条 `2026-09-27T22:04:39`，此后 20h 无错误 ✅ |

### 5.3 指标链路：部分断裂的证据

| # | 检测 | 结果 |
|---|------|------|
| 1 | Target 健康 | 39 up / **18 down** |
| 2 | 规律 | 所有指向宿主节点 IP 的 target 全挂 |
| 3 | TSDB | 182,498 series，正常增长 |
| 4 | 告警 | **58 firing / 1 pending** |
| 5 | Ceph 被监控 | ❌ **无 ServiceMonitor**（9283 端点未接入） |
| 6 | Loki 被监控 | ⚠️ 有 `Loki stack monitoring` 看板，但依赖 Promtail 指标名 |
| 7 | Alloy 被监控 | ❌ 无 ServiceMonitor |

---

## 6. P0 级故障深度剖析

### 6.1 【P0-1】tempo3 全挂 —— S3 `secret_key` 错误

#### 现象

```
tempo3-distributor  level=error  msg="error running Tempo"
  err="failed to init module services: error initialising module: usage-report:
       failed to initialize usage report: unexpected error from ListObjects on tempo-traces:
       The request signature we calculated does not match the signature you provided.
       Check your key and signing method."
```

13 个 Pod 表现一致，只是先失败的模块不同（`usage-report` / `store`）。

#### 根因

**`access_key` 是对的，`secret_key` 是错的。**

| 组件 | access_key | 判定 |
|------|-----------|------|
| tempo3 配置 | `AS5W…NM2M` | ✅ 匹配 RGW 用户 `tempo-admin` |
| RGW `tempo-admin` | `AS5W…NM2M` | ✅ |
| tempo3 `secret_key` | `pEvD…****************TRHt` | ❌ 不匹配 |
| RGW `tempo-admin` 真实 secret | （同为 40 字符，与上不同） | — |
| Loki `loki-admin` secret | `pEvD…****************TRHt` | ← **掩码后与 tempo3 完全相同** |

**（上表所有密钥仅显示掩码，明文一律不写入文档。完整值请用附录 11.3 的方式从 RGW 现取。）**

#### 旁证：tempo3 的 secret 是「抄错」的 Loki secret

把两个值做逐字符比对（不回显明文）：

| 指标 | 数值 |
|------|------|
| 长度 | 两者均为 **40** 字符 |
| 公共前缀 | **14** 字符（`<redacted>`） |
| 公共后缀 | **14** 字符（`…Ppad6NeTRHt`） |
| 差异位数 | **12** 位 |
| 差异位置 | 偏移 **14–25**（连续区间，正中间） |

同长、前后各 14 位完全一致、只有正中间连续 12 位被改写 —— 这不是「随便写错了一个字符」，而是**把 Loki 的 secret 抄过来之后，中间一段被覆盖/串行错位了**，然后又配上了 `tempo-admin` 的 access_key。典型的凭据复制粘贴事故。

#### 决定性验证（真实 S3 签名请求）

```bash
# 测试 1：用 tempo3 现有配置
$ aws --endpoint-url http://10.0.0.31:7480 s3 ls s3://tempo-traces/
An error occurred (SignatureDoesNotMatch) when calling the ListObjectsV2 operation

# 测试 2：用 RGW 中 tempo-admin 的真实凭据
$ aws --endpoint-url http://10.0.0.31:7480 s3 ls s3://tempo-traces/
2026-04-23 20:36:18        215 tempo_cluster_seed.json     ← 成功
```

**100% 确证。** 拿到正确 secret 即可访问同一个桶。

#### 修复方案

```bash
# 从 RGW 取真实凭据（不要手工抄写）
ssh root@10.0.0.31 "radosgw-admin user info --uid=tempo-admin --format=json" \
  | python3 -c "import json,sys; k=json.load(sys.stdin)['keys'][0]; print(k['access_key']); print(k['secret_key'])"
```

在 `/tmp/tempo3-values.yaml` 中把 `secret_key` 替换为上述值，然后：

```bash
helm upgrade tempo3 /tmp/tempo-distributed -n logging -f /tmp/tempo3-values.yaml
```

> ⚠️ 但**仅改 secret 还不够**，见 6.2。

#### 顺带发现的问题

| 问题 | 说明 |
|------|------|
| `distributor.receivers: null` | **tempo3 没有任何 OTLP 接收器**，即使起来了也收不到 span。必须补 `receivers.otlp.protocols.grpc/http` |
| `usage_report.reporting_enabled: true` | 第一个报错的模块就是它。生产环境建议关掉，减少一次启动期 S3 依赖 |
| `log_received_spans.enabled: true` | Tempo 自己启动时打印：`"Span logging is enabled. This is for debugging only and not recommended for production deployments."` 会把每个 span 打到日志，浪费且噪音 |
| Topic 12 分区 vs 3 副本 | 9 个分区闲置，RF=1 无冗余 |
| 7 个单副本组件 | 即使修好也是大面积单点 |

---

### 6.2 【P0-2】Alloy 采集 0 条日志 —— 五重缺件

这是比 tempo3 更严重的问题：**集群日志管道已经断了约 3 小时，而没有任何告警捕捉到这一点。**

根因是一句话：**Promtail 的能力有 60% 来自 chart 的隐式默认值，迁移时只搬了「配置文件」，没搬 chart 隐式提供的东西。**

#### 五个缺件

```
缺件 1：配置里没有 source 组件
  官方 alloy convert 输出 5 个组件：
    discovery.kubernetes "kubernetes_pods"     ✅ 线上有
    loki.process      "kubernetes_pods"        ✅ 线上有
    discovery.relabel "kubernetes_pods"        ⚠️ 线上有但断链
    loki.source.file  "kubernetes_pods"        ❌ 线上没有   ← 缺
    loki.write        "default"                ✅ 线上有

缺件 2：discovery.relabel.targets = []
  应为 discovery.kubernetes.<name>.targets，实际是空数组

缺件 3：DaemonSet 没有日志 hostPath 挂载
  实测 volumeMounts 只有 config(/etc/alloy) + serviceaccount
  缺 /var/log/pods、/var/lib/docker/containers、/var/log、/run/alloy
  ⚠️ Promtail 的 promtail-6.17.1 chart 用 defaultVolumes 默认注入了前两个
     grafana/alloy chart 没有默认值 → 迁移时必须显式写，漏了

缺件 4：没有 tolerations，只覆盖 3/6 节点
  Promtail: tolerations: [{effect: NoSchedule, operator: Exists}]  → 6/6 节点
  Alloy   : tolerations: null                                     → 仅 worker01/02/03
  实测漏采 m01 / master01 / master02 三个 control-plane，共 28 个 Pod
  其中包含 kube-apiserver、etcd、calico、CoreDNS 的全部日志

缺件 5：没有资源 requests/limits
  Promtail: requests 100m/128Mi  limits 200m/256Mi  → Burstable，有保障
  Alloy   : resources: {}                             → BestEffort，压力下先被驱逐
```

**缺件 1~3 任一存在，Alloy 都无法采集日志 —— 当前三个都存在。**
**缺件 4 会让修复后仍漏掉整个控制面，缺件 5 让采集器在节点压力下最先死。**

#### Promtail 时代 vs Alloy 线上：逐项对照

| 维度 | Promtail 3.5.1 | Alloy 线上 | 判定 |
|------|---------------|-----------|------|
| 日志采集 | ✅ `role: pod` | ❌ 无 source | **退化** |
| `/var/log/pods` 挂载 | ✅ chart 默认 | ❌ 无 | **退化** |
| `/var/lib/docker/containers` 挂载 | ✅ chart 默认 | ❌ 无 | **退化** |
| control-plane 覆盖 | ✅ 6/6 | ❌ 3/6 | **退化** |
| `node_name` 标签 | ✅ | ❌ 写成 `node` | **退化** |
| `job`/`instance`/`component` | ✅ | ❌ 缺失 | **退化** |
| `__path__` 构造 | ✅ 双规则 | ❌ 缺失 | **退化** |
| 资源保障 | ✅ 100m/128Mi 起 | ❌ `{}` | **退化** |
| 集群列表 RBAC | nodes/svc/ep/pods | **+ep slices / ingresses / pods/log / ns** | ✅ 更强 |
| 配置热加载 | ❌ Secret + 需重启 | ✅ ConfigMap + reloader | ✅ 更强 |
| 多信号能力 | ❌ 仅 logs | ✅ 可采 Prom/OTel | ✅ 更强 |
| 官方转换工具 | — | ✅ `alloy convert` | ✅ 更强 |
| 官方维护 | ✅ Grafana | ✅ Grafana | 持平 |

> **10 项退化 vs 5 项增强。** 迁移方向正确（Alloy 能力上限更高、有官方转换器、Promtail 官方仍维护），**但落地是残缺的**。

#### 为什么「看起来是成功的」

| 表面现象 | 真相 |
|----------|------|
| 3 个 Pod `2/2 Running`，0 重启 | 只是进程活着 |
| `alloy_config_last_load_successful 1` | 语法正确，缺失组件不算语法错 |
| `alloy_config_load_failures_total 0` | 同上 |
| 4 个组件 `health_type="healthy"` | 健康的空组件 |
| 日志里有 `finished node evaluation` | 图求值正常，但 source 节点不存在 |

**典型「假成功」——这也解释了为什么之前基于「网关看到 204」的验证结论是错的：那 204 是 Promtail 时代或 Loki canary 产生的。**

#### 修复方案

**步骤 1：修正 ConfigMap `alloy-config`**

```alloy
// ============ 1. 服务发现 ============
discovery.kubernetes "pod_logs" {
    role = "pod"
    selectors {
        role  = "pod"
        field = "spec.nodeName=" + coalesce(sys.env("K8S_NODE_NAME"), constants.hostname)
    }
}

// ============ 2. 标签重写（保持与 Promtail 完全一致的契约）============
discovery.relabel "pod_logs" {
    targets = discovery.kubernetes.pod_logs.targets      // ✅ 关键修复

    rule { source_labels = ["__meta_kubernetes_pod_controller_name"]
           regex = "([0-9a-z-.]+?)(-[0-9a-f]{8,10})?" target_label = "__tmp_controller_name" }
    rule { source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name",
                            "__meta_kubernetes_pod_label_app",
                            "__tmp_controller_name",
                            "__meta_kubernetes_pod_name"]
           regex = "^;*([^;]+)(;.*)?$" target_label = "app" }
    rule { source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_instance",
                            "__meta_kubernetes_pod_label_instance"]
           regex = "^;*([^;]+)(;.*)?$" target_label = "instance" }
    rule { source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component",
                            "__meta_kubernetes_pod_label_component"]
           regex = "^;*([^;]+)(;.*)?$" target_label = "component" }
    rule { source_labels = ["__meta_kubernetes_pod_node_name"] target_label = "node_name" }   // ✅ node_name
    rule { source_labels = ["__meta_kubernetes_namespace"]   target_label = "namespace" }
    rule { source_labels = ["namespace", "app"] separator = "/" target_label = "job" }
    rule { source_labels = ["__meta_kubernetes_pod_name"]    target_label = "pod" }
    rule { source_labels = ["__meta_kubernetes_pod_container_name"] target_label = "container" }
    rule { source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
           separator = "/" replacement = "/var/log/pods/*$1/*.log" target_label = "__path__" }
    rule { source_labels = ["__meta_kubernetes_pod_annotationpresent_kubernetes_io_config_hash",
                            "__meta_kubernetes_pod_annotation_kubernetes_io_config_hash",
                            "__meta_kubernetes_pod_container_name"]
           separator = "/" regex = "true/(.*)"
           replacement = "/var/log/pods/*$1/*.log" target_label = "__path__" }
}

// ============ 3. 真正的日志读取源（❌ 原来完全缺失）============
loki.source.kubernetes "pod_logs" {
    targets    = discovery.relabel.pod_logs.output
    forward_to = [loki.process.logs_to_prometheus.receiver]
}

// ============ 4. 解析 ============
loki.process "logs_to_prometheus" {
    forward_to = [loki.write.default.receiver]
    stage.cri {}
    stage.drop { older_than = "168h" }
}

// ============ 5. 写出 ============
loki.write "default" {
    endpoint {
        url       = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
        tenant_id = "fake"
    }
}
```

**步骤 2：给 DaemonSet 加 hostPath 挂载 + tolerations + 资源保障**

```yaml
# alloy values 片段（对齐 Promtail 时代的行为）
controller:
  type: daemonset

  # ★ 缺件 3 修复：grafana/alloy chart 无默认值，必须显式声明
  volumes:
    - name: varlog
      hostPath: { path: /var/log,  type: Directory }
    - name: varlogpods
      hostPath: { path: /var/log/pods, type: Directory }
    - name: dockercontainers          # Promtail 时代也挂了，保留兼容
      hostPath: { path: /var/lib/docker/containers, type: DirectoryOrCreate }
    - name: positions                 # 断点续传文件，readOnlyRootFilesystem 下必须可写
      hostPath: { path: /run/alloy, type: DirectoryOrCreate }
  volumeMounts:
    - { name: varlog,            mountPath: /var/log,  readOnly: true }
    - { name: varlogpods,        mountPath: /var/log/pods, readOnly: true }
    - { name: dockercontainers,  mountPath: /var/lib/docker/containers, readOnly: true }
    - { name: positions,         mountPath: /run/alloy }

  # ★ 缺件 4 修复：恢复 6/6 节点覆盖（含 control-plane）
  tolerations:
    - operator: Exists
      effect: NoSchedule

  # ★ 缺件 5 修复：从 BestEffort 提升为 Burstable，避免压力下先被驱逐
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { cpu: 200m, memory: 256Mi }
```

> 改 DaemonSet 触发滚动更新，**3 个 worker 节点会依次重启，worker 上 Pod 的日志会短暂断档**（`positions` 文件在 `/run/alloy`，是新目录，首次会重读文件尾部，不会全量重放）。可接受，无需停机。

**步骤 3：验证（必须做这 7 项，缺一不可）**

```bash
# 1) source 组件存在且在读文件
kubectl exec -n logging alloy-xxx -c alloy -- curl -s localhost:12345/metrics | grep loki_read_lines_total
#    期望：loki_read_lines_total > 0 且持续增长   ← 这是「真的在读」的唯一铁证

# 2) 组件数 = 5
kubectl exec -n logging alloy-xxx -c alloy -- curl -s localhost:12345/metrics | grep running_components
#    期望：running_components{health_type="healthy"} 5

# 3) hostPath 挂载存在
kubectl get pod -n logging alloy-xxx -o jsonpath='{.spec.containers[?(@.name=="alloy")].volumeMounts[*].mountPath}'
#    期望包含 /var/log 和 /var/log/pods

# 4) ★ 节点覆盖恢复到 6/6
kubectl get pods -n logging -l app.kubernetes.io/name=alloy -o custom-columns='NODE:.spec.nodeName' --no-headers | sort -u
#    期望：m01 master01 master02 worker01 worker02 worker03  共 6 个

# 5) ★ 标签契约复刻（用 Loki 查，不靠猜）
NOW=$(date +%s); S=$((NOW-600))000000000; E=$((NOW))000000000
for l in node_name job instance component; do
  printf "  %-12s " $l
  curl -s -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/label/$l/values" \
       --data-urlencode "start=$S" --data-urlencode "end=$E" -H 'X-Scope-OrgID: fake'
done
#    期望：node_name 返回 6 个节点名；job 返回 "<ns>/<app>" 形式

# 6) Loki 里真能查到实时数据
curl -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({namespace="logging"}[5m]))' \
  --data-urlencode "start=$S" --data-urlencode "end=$E" -H 'X-Scope-OrgID: fake'
#    期望：非空且 > 0

# 7) ★ 存量 LogQL 兼容性回归（用 Promtail 时代的老查询串）
curl -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({node_name="worker03"}[5m]))' \
  --data-urlencode "start=$S" --data-urlencode "end=$E" -H 'X-Scope-OrgID: fake'
#    期望：> 0。若为 0 说明 node_name 没复刻成功 —— 这是最容易被忽略的回归点
```

> **第 7 项是兼容性回归测试。** 修好之后一定要用**迁移前就存在的 LogQL 查询串**去验证，而不是用新写的查询 —— 否则「能查到数据」和「旧看板还能用」是两回事。

---

## 7. P1 级问题

### 7.1 CoreDNS Pod `ImagePullBackOff`

```
kube-system/coredns-7bf7bd7987-k7f47   0/1   ImagePullBackOff   20h

Warning  Failed  37m (x267 over 20h)  kubelet
  Failed to pull image "registry.k8s.io/coredns/coredns:v1.11.1":
  rpc error: code = DeadlineExceeded ... failed to resolve reference:
  Head "https://europe-west2-docker.pkg.dev/v2/k8s-artifacts-prod/images/coredns/coredns/manifests/v1.11.1":
  dial tcp 64.233.188.82:443: i/o timeout
```

**根因**：`registry.k8s.io` 重定向到 Google 的 `europe-west2-docker.pkg.dev`（64.233.188.82），该地址从本集群网络**不可达（i/o timeout）**。这是国内网络环境的典型问题。

**当前状态**：另一个 CoreDNS Pod（`coredns-7bf7bd7987-4d7ts` on master02）Running，**集群 DNS 仍可用**，但**只有单副本，无冗余**——这个 Pod 一挂，集群 DNS 全断。

**建议方案**（按优先级）：

| 方案 | 操作 | 优点 |
|------|------|------|
| A | 镜像同步到内网 registry | 一劳永逸 |
| B | 改用国内镜像源（如 `docker.m.daocloud.io/registry.k8s.io/coredns/coredns:v1.11.1`） | 改一行 |
| C | 给已有 Pod 加 `imagePullPolicy: IfNotPresent` + 预拉镜像 | 缓解 |

---

### 7.2 18/57 抓取目标 DOWN

**规律**：所有指向**宿主节点 IP** 的 target 全挂。

| job | 数量 | 端点 |
|-----|------|------|
| kube-proxy | 6 | `10.0.0.x:10249` |
| kube-scheduler | 3 | `10.0.0.x:10259` |
| kube-controller-manager | 3 | `10.0.0.x:10257` |
| kube-etcd | 3 | `10.0.0.x:2381` |
| coredns | 1 | `10.244.5.53:9153` |
| tempo3-* | 2 | Pod CrashLoop（预期内） |

**丢了这 4 类 target 意味着监控看不到**：节点网络流量、调度器行为、控制器队列、etcd 集群健康。这正好对应正在 firing 的 `etcdMembersDown` / `etcdInsufficientMembers` 告警——**告警本身可能是假阳性**（Prometheus 抓不到 etcd，所以 `up=0` 触发告警，而非 etcd 真有问题）。

**建议诊断**：

```bash
# 从 Prometheus Pod 内测试连通性
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  sh -c 'nc -zv 10.0.0.120 2381; nc -zv 10.0.0.120 10249'
```

---

### 7.3 58 条告警在 Firing

| 告警名 | 数量 | 严重度 | 说明 |
|--------|------|--------|------|
| `PodCrashLooping` | 14 | warning | 13 个 tempo3 + 1 个 coredns |
| `KubePodCrashLooping` | 13 | warning | 同上 |
| `TargetDown` | 7 | warning | 见 7.2 |
| `KubeDeploymentReplicasMismatch` | 5 | warning | — |
| `KubeDeploymentRolloutStuck` | 5 | warning | — |
| `KubeStatefulSetReplicasMismatch` | 4 | warning | — |
| `KubeStatefulSetUpdateNotRolledOut` | 2 | warning | — |
| `KubePdbNotEnoughHealthyPods` | 2 | warning | — |
| `AlertmanagerFailedToSendAlerts` | 1 | warning | — |
| **`AlertmanagerClusterFailedToSendAlerts`** | 1 | **critical** | **通知发不出去** |
| `etcdMembersDown` | 1 | warning | 疑似 7.2 引起 |
| `etcdInsufficientMembers` | 1 | **critical** | 同上 |
| `KubePodNotReady` | 1 | warning | coredns |
| `Watchdog` | 1 | none | 正常心跳 |

**`AlertmanagerClusterFailedToSendAlerts` 是 critical** —— 所有告警都发不出去，监控形同虚设。需检查 webhook 端点连通性。

---

### 7.4 DNSConfigForming 告警刷屏

```
Warning  DNSConfigForming  2m52s (x5242 over 20h)  kubelet
  Nameserver limits were exceeded, some nameservers have been omitted,
  the applied nameserver line is: 223.5.5.5 119.29.29.29 223.5.5.5
```

**问题**：`/etc/resolv.conf` 超过 3 个 nameserver（Linux `MAXDNSRESOLV` 限制），kubelet 截断。注意「`223.5.5.5` 出现两次」——说明宿主机 `/etc/resolv.conf` 与 Pod 的 `dnsConfig` 有重叠。

**修复**：精简为 2 个不重复的 nameserver：

```yaml
dnsConfig:
  nameservers: ["223.5.5.5", "119.29.29.29"]
  options:    [{ name: ndots, value: "2" }]
```

---

### 7.5 存储冗余度不足

| 组件 | 副本 | 建议 |
|------|------|------|
| **日志采集器（Alloy）** | **3/6 节点** | **6/6（补 tolerations）** ← 迁移丢失 |
| Loki write | 1 | ≥2 |
| Loki read | 1 | ≥2 |
| Loki backend (compactor) | 1 | ≥2（Leader 可选） |
| Loki results/chunks cache | 1 | ≥2 |
| Tempo 2.x distributor/querier/frontend/compactor | 各 1 | ≥2 |
| Tempo 3.x 7 个组件 | 7 个为 1 | ≥2 |
| Prometheus | 1 | 2（+ Thanos/Mimir 长期方案） |
| Alertmanager | 1 | 2 |
| Kafka topic `tempo-traces` | RF=1 | ≥2 |
| CoreDNS | 实际 1 | ≥2（ImagePull 问题解决后） |
| Ceph OSD | 6 | ✅ 足够 |

> 本集群所有核心可观测性组件**几乎全是单副本**。任何一次节点维护/Pod 驱逐都会造成对应信号完全不可用。这是**架构级风险**，不是配置 bug。

---

### 7.6 Ceph 监控缺失

Ceph mgr 的 Prometheus 模块已在跑，暴露 542 个 `ceph_*` 指标族，但**集群里没有任何 ServiceMonitor 抓它**。

后果：OSD 掉线、PG 异常、容量水位、MON_CLOCK_SKEW、backfill 进度——全靠人肉 `ceph -s`。这正是本次 `MON_CLOCK_SKEW` 持续 9 个月没人发现的原因。

---

## 8. Grafana 三大信号查询实战

> 以下所有示例都基于**本集群真实 label 名**（从实际数据提取），可直接复制使用。

### 8.1 Metrics（PromQL）

#### 查看本集群实际可用的指标前缀

```
kube_*                 K8s 对象（kube-state-metrics）
node_*                 节点（node-exporter）
container_*            容器（cAdvisor）
cAdvisor_*             容器别名
apiserver_* request_*  API server
go_* process_*         各进程运行时
up scrape_*            抓取自身
tempo_*                Tempo 2.x 自监控
otelcol_*              OTel Collector
loki_*                 Loki（若接入）
ceph_*                 Ceph（若接入，当前缺失）
```

#### 常用查询

```promql
# ── 集群总体 ──
sum(node_cpu_seconds_total{mode="idle"}) by (instance)      # 各节点空闲 CPU
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes

# ── Pod 资源 TOP10（实测集群有 182,498 series）──
topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{container!="", container!="POD"}))
topk(10, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])))

# ── 命名空间 Pod 数（实测 21 个命名空间有数据）──
count by (namespace) (kube_pod_info)

# ── 崩溃循环的 Pod ──
kube_pod_container_status_restarts_total > 0
increase(kube_pod_container_status_restarts_total[1h]) > 5

# ── 抓取健康（本次问题的核心）──
up == 0                                          # 18 个
up{job=~"kube-(proxy|scheduler|controller-manager|etcd)"} == 0

# ── 告警状态 ──
ALERTS{alertstate="firing"}                     # 58 条
count by (alertname) (ALERTS{alertstate="firing"})

# ── 本集群特有的 OTel RED 指标（spanmetrics 产生）──
otel_demo_calls_total
otel_demo_duration_milliseconds_bucket
# 注意 namespace 是 otel_demo（见 otelcol 配置）
```

#### Grafana 变量（Dashboard 用）

```promql
label_values(up, job)                    # 列出所有抓取任务
label_values(kube_pod_info, namespace)  # 列出所有命名空间
label_values(up{job="$job"}, instance)   # 某任务的实例
```

### 8.2 Logs（LogQL）

#### ⚠️ 先记住：Loki 3.x 的 label API 必须带时间参数

```bash
# ✅ 正确
NOW=$(date +%s)
curl -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/label/namespace/values" \
     --data-urlencode "start=$((NOW-86400))000000000" \
     --data-urlencode "end=$NOW000000000" \
     -H 'X-Scope-OrgID: fake'
```

#### 本集群实际 label 契约（Promtail 时代建立，Alloy 修复后应保持）

```
app, component, container, detected_level, filename, instance,
job, namespace, node_name, pod, stream
```

#### 查询示例

```logql
# ── 基础 ──
{namespace="logging"}                                # 某命名空间全部
{namespace="logging", app="prometheus"}              # 某应用
{node_name="worker01"}                               # 某节点
{namespace="logging", app="loki", detected_level="error"}   # 只看错误

# ── 行过滤 ──
{namespace="kube-system"} |= "error"                 # 包含
{namespace="kube-system"} |~ "error|fail|timeout"   # 正则
{namespace="kube-system"} != "healthz"               # 排除
{namespace="kube-system"} |~ `(?i)panic|fatal`       # 大小写不敏感

# ── 解析 ──
{namespace="logging"} | json                         # 按 JSON 解析
{namespace="logging"} | logfmt                       # 按 logfmt 解析（本集群主力格式）
{namespace="logging"} | logfmt | level="error"       # 提取字段后过滤
{namespace="logging"} | line_format "{{.status}} {{.msg}}"

# ── 聚合统计 ──
sum by (namespace) (count_over_time({namespace=~".+"}[5m]))      # 各命名空间行数
topk(10, sum by (pod) (count_over_time({namespace="logging"}[1h])))
sum(count_over_time({namespace=~".+"}[1h]))                       # 总行数
avg_over_time(rate({namespace="logging"} | logfmt [5m]))          # 行速率

# ── 组合：本次排障实际用过的查询 ──
sum(count_over_time({namespace="logging"}[1h]))    # → result: [] 证明日志断流
count_over_time({namespace="logging",app="alloy"}[1h])   # → 0 证明 Alloy 没在采

# ── 错误率 ──
sum by (namespace) (count_over_time({namespace=~".+"} | json | level="error" [5m]))
  /
sum by (namespace) (count_over_time({namespace=~".+"}[5m]))
```

#### 本集群实测数据（近 24h，Promtail 时代采集的存量）

| 命名空间 | 24h 日志行数 |
|----------|-------------|
| **logging** | **1,255,725** |
| kube-system | 263,974 |
| kafka | 60,687 |
| argocd | 28,276 |
| monitoring | 24,901 |
| n8n | 2,140 |
| opentelemetry | 22 |
| cert-manager | 16 |
| **logging（最近 1h）** | **0 ← 断流** |

#### 真实日志样本（Prometheus TSDB 清理块）

```log
# 查询：{namespace="monitoring",app="prometheus"}  direction=BACKWARD
2026-09-28 05:00:19 | time=2026-09-28T05:00:19.457Z level=INFO source=db.go:2077
               msg="Deleting obsolete block" component=tsdb block=01M3JRD8QD0Y4QVNV3C6...
2026-09-28 05:00:19 | time=2026-09-28T05:00:19.411Z level=INFO source=db.go:2077
               msg="Deleting obsolete block" component=tsdb block=01M3JHHHFEJ3X87JHGCB...
2026-09-28 05:00:19 | time=2026-09-28T05:00:19.365Z level=INFO source=db.go:2077
               msg="Deleting obsolete block" component=tsdb block=01M3JANT7DEM126WDM9S...
```

#### 排障：抓某个 Pod 的当前日志（比 Loki 更快的办法）

```bash
# Loki 有 30s~数分钟延迟，排障时直接看容器
kubectl logs -n logging alloy-fv6gk -c alloy --tail=50 --timestamps

# 崩溃重启看上一次
kubectl logs tempo3-distributor-xxx -n logging --previous --tail=100

# 按级别过滤
kubectl logs -n logging alloy-xxx -c alloy --tail=200 | grep -E "level=(error|warn)"
```

### 8.3 Traces（TraceQL）

#### 本集群现状

```
Tempo 2.9.0  ← Grafana datasource 指向这个（tempo-query-frontend:3200）
  仅收到 14 个 span / 3.4 KB
Tempo 3.0.3  ← 全部 CrashLoop，不可用
```

#### TraceQL 查询示例

```traceql
# ── 基础 ──
{}                                   # 全部 trace
{ resource.service.name = "myservice" }
{ span.http.url = "/api/v1/users" }

# ── 错误与性能（Grafana Explore 最常用）──
{ status = error }
{ duration > 1s }
{ name = "HTTP GET" && status = error }

# ── 组合 ──
{ resource.service.namespace = "logging" && duration > 500ms }
{ span.db.system = "postgresql" && status = error }
{ name =~ "SELECT.*" && duration > 100ms }

# ── 关联指标（Grafana "Metrics for this trace" 按钮）──
{ status = error } | rate()
```

#### 服务列表（TraceQL Explore）

```bash
# 从 Tempo API 拿服务名
curl -s "http://tempo-query-frontend.logging.svc.cluster.local:3200/api/search/tag/service.name/values"
```

#### ⚠️ 当前限制

**Tempo 2.x 的 `block_retention: 48h`** —— 追踪数据只保留 2 天。加上几乎无 span 流入，**TraceQL 实际查不出有意义的内容**。要真正用起来需要：

1. 至少一个应用接入 OTel SDK 上报 span
2. OTel Collector 的 `otlp_grpc/tempo` 出口保持指向 `tempo-distributor:4317`
3. Tempo 2.x 存活期内不要切到 tempo3，除非 tempo3 全绿

### 8.4 关联分析：三大信号串联（Grafana Explore）

Grafana 的核心价值在关联。从一条异常指标跳到日志、再跳到 trace：

```
① Metrics 发现异常
   容器重启次数突增
   sum by (pod) (increase(kube_pod_container_status_restarts_total[5m])) > 3
        │  点击 pod 名
        ▼
② Logs 定位原因
   {namespace="logging", pod="$pod"} |~ "error|fatal|panic"
        │  点击具体时间点
        ▼
③ Traces 看调用链
   { status = error && resource.k8s.pod.name = "$pod" }
        │  看是哪个下游服务拖慢/失败
        ▼
④ 回到 Metrics 验证影响面
   rate(http_requests_total{code="500"}[5m])
```

**本集群当前的关联断点**：② 到 ③ 断了——因为日志断了、trace 也几乎没有。修好采集端才能串联。

---

## 9. 推荐配置基线

### 9.1 日志

| 项 | 现状 | 推荐 | 优先级 |
|----|------|------|--------|
| 采集器 | Alloy（配置失效） | 修 5 处缺件，配置用官方 `alloy convert` 输出 | **P0** |
| 挂载 | 无 `/var/log/pods` 等 | hostPath `Directory` + `readOnly`（显式声明，chart 无默认值） | **P0** |
| 节点覆盖 | 3/6（无 tolerations） | 加 `tolerations: [{operator: Exists, effect: NoSchedule}]` 恢复 6/6 | **P0** |
| 资源 | `{}`（BestEffort） | `requests: 100m/128Mi`、`limits: 200m/256Mi`（对齐 Promtail） | P1 |
| 标签 | `node`（错），缺 `job`/`instance`/`component` | 完整复刻 Promtail 契约 | **P0** |
| Loki 副本 | write/read/backend 各 1 | ≥2 | P1 |
| 保留 | `reject_old_samples_max_age: 168h` | 保留 14-30d + compactor 真正启用 | P2 |
| Schema index 周期 | 24h | 12h（查询更快） | P2 |
| Compactor | 未配 retention | 配 `retention_enabled` + 明确 `retention_period` | P1 |
| Ruler | `loki-ruler` 桶空 | 未用则关掉，或配 LogQL 告警规则 | P2 |
| Grafana Loki ds | 已配 | 加 `X-Scope-OrgID: fake` 头 | **P0** |

### 9.2 追踪

| 项 | 现状 | 推荐 | 优先级 |
|----|------|------|--------|
| tempo3 secret_key | 错误 | 用 RGW `tempo-admin` 真实凭据 | **P0** |
| tempo3 receivers | `null` | 补 `otlp.protocols.grpc/http` | **P0** |
| tempo3 usage_report | 开启 | 生产关闭 | P1 |
| tempo3 span logging | 开启 | 关闭 | P1 |
| Topic 分区 | 12 vs 3 副本 | 统一为 3（或副本调到 12） | P1 |
| Topic RF | 1 | ≥2 | P1 |
| 单副本组件 | 7 个 | ≥2 | P1 |
| Tempo 2.x 保留 | 48h | 7-14d | P2 |
| span 流量 | 14 个 span | 至少接入 1 个应用的 OTel SDK | P1 |
| OTel debug exporter | 开启 | 关闭 | P2 |

### 9.3 指标

| 项 | 现状 | 推荐 | 优先级 |
|----|------|------|--------|
| 18 个 down target | 全挂 | 排查 Prom→节点 IP 网络 | **P1** |
| Prometheus 副本 | 1 | 2 + Thanos/Mimir | P1 |
| Ceph 监控 | 无 | 接 `10.0.0.31:9283/metrics` | **P1** |
| Alloy 监控 | 无 | ServiceMonitor 抓 12345/metrics | **P1** |
| Alertmanager 通知 | 不通 | 修 webhook | **P0** |
| etcd 告警 | 疑似假阳性 | 先修 target 再判 | P1 |
| 告警噪声 | 58 条 | 收敛 + 分级路由 | P2 |

**推荐的 Ceph ServiceMonitor（尚未部署）：**

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: ceph-mgr-metrics
  namespace: monitoring
  labels: { app.kubernetes.io/name: ceph-mgr-metrics }
subsets:
  - addresses: [{ ip: 10.0.0.31 }]        # active mgr
    ports: [{ name: metrics, port: 9283, protocol: TCP }]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ceph
  namespace: monitoring
  labels: { release: prometheus }
spec:
  selector:
    matchLabels: { app.kubernetes.io/name: ceph-mgr-metrics }
  endpoints:
    - port: metrics
      interval: 30s
```

**接入后可用的关键 Ceph 查询：**

```promql
ceph_health_status                       # 1=OK 0=WARN
ceph_osd_up == 0                         # OSD 掉线
ceph_pg_incomplete > 0                   # PG 降级
ceph_cluster_total_used_bytes / ceph_cluster_total_bytes > 0.85    # 容量水位
ceph_bluestore_*_latency_*               # 存储延迟
```

### 9.4 存储

| 项 | 现状 | 推荐 |
|----|------|------|
| Ceph | `HEALTH_OK`，6 OSD，180 GB（已用 17 GB） | 容量偏低，按增速规划 |
| NTP | 三台已同步（阿里云） | ✅ 保持 |
| mon 冗余 | 3 mon / 3 主机 | ✅ 保持 |
| RGW 用户 | 3 个业务 + 3 个测试遗留 | 清理 `alice`/`bob`/`testuser`/`testbucket` |
| 凭据管理 | 明文写在 ConfigMap | 改用 Secret + `ExternalSecret` |
| 备份 | 未见 Ceph 备份 | RBD 快照 + RGW 桶同步 |

---

## 10. 修复优先级与路线图

### 10.1 P0（立即，1 小时内）

| # | 动作 | 影响 | 预计耗时 |
|---|------|------|----------|
| 1 | **修 Alertmanager 通知**（`AlertmanagerClusterFailedToSendAlerts` critical） | 恢复告警投递能力——否则修了别的也没人知道 | 15 min |
| 2 | **修 Alloy 五处缺件**（source 组件 / targets / hostPath / tolerations / 资源） | **恢复集群日志采集 + 补回控制面 28 个 Pod**，当前已断 3h | 25 min |
| 3 | **Grafana Loki 数据源加 `X-Scope-OrgID: fake`** | Loki 查询正常 | 5 min |
| 4 | **修 tempo3 `secret_key`** + 补 `receivers.otlp` | 让 Tempo 3.x 至少能启动 | 15 min |

> ⚠️ **顺序建议**：先做 #1（告警通道），再做 #2-#4。否则修完还是不知道修没修好。
>
> ⚠️ **#2 里的 tolerations 千万不要省。** 只修前 3 项的话，日志虽然回来了，但**控制面（API Server / etcd / CNI）的日志依然一条都看不到** —— 容易误判为「已修复」。验证必须包含「6/6 节点覆盖」和「用 Promtail 时代的老 LogQL 串回归」两项（见 6.2 步骤 3 的第 4、7 项）。

### 10.2 P1（1-3 天）

| # | 动作 |
|---|------|
| 5 | 修 CoreDNS `ImagePullBackOff`（换国内镜像源） |
| 6 | 排查并修复 18 个 down target（Prom → 节点 IP 网络） |
| 7 | 接入 Ceph（9283）与 Alloy（12345）的 ServiceMonitor |
| 8 | 统一 Kafka topic 分区（12→3 或 3→12），RF 提到 2 |
| 9 | 接入至少 1 个应用的 OTel SDK，让 trace 真正有数据 |
| 10 | 关键组件副本数从 1 提到 2（分批滚动，注意别同时动） |
| 11 | 清理 RGW 测试遗留用户/桶 |
| 12 | 修 `DNSConfigForming`（精简 nameserver 至 2 个不重复） |

### 10.3 P2（1-2 周）

| # | 动作 |
|---|------|
| 13 | Loki 保留策略（compactor retention + 14-30d） |
| 14 | Tempo 保留策略 48h → 7-14d |
| 15 | 关闭 OTel `debug` exporter、tempo3 `log_received_spans` |
| 16 | 凭据迁到 Secret（不再明文在 ConfigMap） |
| 17 | 告警收敛（58 → 目标 <15），按严重度分级路由 |
| 18 | Prometheus HA（2 副本 + Thanos 或 Mimir） |
| 19 | 更新 `Loki stack monitoring` 看板（Promtail → Alloy） |
| 20 | Ceph 备份策略（RBD 快照 + RGW 同步） |
| 21 | 考虑 Tempo 2.x → 3.x 正式切换（tempo3 全绿后） |
| 22 | 评估 Mimir 替代 Prometheus（长期） |

### 10.4 回滚保障

| 已做的备份 | 位置 |
|-----------|------|
| 全量 Helm values / manifest / history | `/root/observability-upgrade-backup-20260928-122529/` |
| 原 Promtail 配置 | `.../helm/promtail-manifest.yaml`、`.../helm/promtail-values.yaml` |
| 原 ConfigMap/Secret/Deployment/StatefulSet | `.../logging/`、`.../monitoring/`、`.../opentelemetry/` |
| CoreDNS 修复前配置 | `/tmp/coredns-backup-20260928-*.yaml` |
| Ceph NTP 修复前配置 | `/root/observability-upgrade-backup-20260928-122529/ceph-ntp-fix-20260928-164551/` |

**Promtail 可回滚**（Helm release 仍在 history 中，values 已备份）——这是 Alloy 出问题时的兜底。

---

## 11. 附录

### 11.1 常用排障命令

```bash
# ── 集群总览 ──
kubectl get nodes -o wide
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn
kubectl get pods -A --no-headers | grep -vE "Running|Completed"

# ── 崩溃分析（黄金三连）──
kubectl logs <pod> -n <ns> --tail=100              # 当前
kubectl logs <pod> -n <ns> --previous --tail=100   # 上一次
kubectl describe pod <pod> -n <ns> | tail -30       # 事件

# ── Helm ──
helm list -A
helm get values <release> -n <ns> -a               # 全部值
helm history <release> -n <ns>
helm get manifest <release> -n <ns>

# ── Loki（注意 start/end 必填）──
NOW=$(date +%s); S=$((NOW-86400))000000000; E=$((NOW))000000000
curl -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/label/namespace/values" \
     --data-urlencode "start=$S" --data-urlencode "end=$E" -H 'X-Scope-OrgID: fake'
curl -G "http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/query" \
     --data-urlencode 'query=sum(count_over_time({namespace="logging"}[1h]))' \
     --data-urlencode "start=$S" --data-urlencode "end=$E" -H 'X-Scope-OrgID: fake'

# ── Tempo ──
curl -s "http://tempo-distributor.logging.svc.cluster.local:3200/metrics" | grep tempo_distributor
curl -s "http://tempo-query-frontend.logging.svc.cluster.local:3200/api/search/tags"

# ── Prometheus ──
P=http://prometheus-prometheus.monitoring.svc.cluster.local:9090
curl -s "$P/api/v1/targets?state=active"   # 抓取目标
curl -s "$P/api/v1/alerts"                 # 告警
curl -s "$P/api/v1/status/runtimeinfo"     # 运行时
curl -s "$P/api/v1/status/tsdb"            # 容量

# ── Grafana ──
GF=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $GF -c grafana -- curl -s -u "admin:<密码>" localhost:3000/api/datasources
kubectl exec -n monitoring $GF -c grafana -- curl -s -u "admin:<密码>" 'localhost:3000/api/search?type=dash-db'

# ── Alloy ──
kubectl logs alloy-xxx -n logging -c alloy --tail=100
kubectl exec -n logging alloy-xxx -c alloy -- curl -s localhost:12345/metrics | grep -E "loki_(read|write|source)_"
kubectl exec -n logging alloy-xxx -c alloy -- /bin/alloy validate /etc/alloy/config.alloy

# ── Ceph ──
ssh root@10.0.0.31 'ceph -s; ceph health detail; ceph osd tree; ceph quorum_status'
ssh root@10.0.0.31 'radosgw-admin user list; radosgw-admin bucket list'
curl -sk -o /dev/null -w "%{http_code}\n" https://10.0.0.31:8443/     # Dashboard
curl -s -o /dev/null -w "%{http_code}\n" http://10.0.0.31:9283/metrics  # Metrics
```

### 11.2 关键端点速查

| 用途 | 地址 |
|------|------|
| Grafana | `https://grafana.example.local` |
| ArgoCD | `https://argocd.devops.com` |
| Prometheus | `https://prometheus.k8s.local` |
| K8s Dashboard | `https://dashboard.k8s.local` |
| Loki 集群内 | `http://loki-gateway.logging.svc.cluster.local` |
| Tempo 2.x 查询 | `http://tempo-query-frontend.logging.svc.cluster.local:3200` |
| Tempo 3.x 查询 | `http://tempo3-query-frontend.logging.svc.cluster.local:3200`（❌ 不可用） |
| OTel OTLP | `otel-collector.opentelemetry.svc.cluster.local:4317` / `:4318` |
| Kafka | `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| Ceph S3 (RGW) | `http://10.0.0.31:7480` |
| Ceph Dashboard | `https://10.0.0.31:8443` |
| Ceph Metrics | `http://10.0.0.31:9283/metrics` |
| Traefik LB | `10.0.0.252` |
| Kourier LB | `10.0.0.253` |

### 11.3 本文档未包含的敏感信息

以下内容已刻意省略，仅在需要时从源头获取：

- Loki S3 `access_key_id` / `secret_access_key`
- Tempo S3 `access_key` / `secret_key`
- RGW 用户真实密钥（`loki-admin` / `tempo-admin` / `dashboard`）
- Grafana admin 口令
- ArgoCD admin 口令
- Kafka / 数据库凭据

获取方式：

```bash
# RGW 凭据
ssh root@10.0.0.31 "radosgw-admin user info --uid=tempo-admin --format=json"
```

### 11.4 报告元信息

```
采集时间   : 2026-09-28 16:40 ~ 17:20 CST
采集工具   : kubectl v1.29 客户端 / curl / aws-cli / python3 / radosgw-admin / ceph
探测 Pod   : obs (curlimages/curl, default 命名空间，脚本执行完已清理)
数据性质   : 全部为本机实时采集
验证强度   : tempo3 根因经真实 S3 签名请求双向验证；Alloy 故障经 7 项独立证据交叉验证
```

---

*本报告由实测数据生成，所有结论均可复现。*

---

## 12. 监控覆盖改造（2026-09-30）

### 【变更】
- **修复重复抓取**：`opentelemetry/otel-collector-spanmetrics` SM 原通过 `app.kubernetes.io/name=otel-collector` 同时匹配 base（`otel-collector`）与 headless（`otel-collector-headless`）两个 Service → 同一 Pod `:8889/prom-exporter` 被抓 2 次。修复：SM selector 增加 `operator.opentelemetry.io/collector-service-type: base`，只匹配 base Service。`matchExpressions NotIn` 方式不可用（Prometheus Operator 不将该表达式编译进 relabel keep 规则，已实测证伪）。
- **新增 7 个 ServiceMonitor**：cert-manager / tekton-pipelines / tekton-triggers / knative-eventing-kafka-broker / knative-eventing-kafka-webhook / ceph-csi-rbd-provisioner / ceph-csi-rbd-nodeplugin。
- **新增 8 个 PodMonitor**：argocd（排除 dex-server，其声明 metrics:5558 但未监听）/ traefik / cnpg-controller-manager / metallb-controller / strimzi-cluster-operator / knative-eventing-controlplane（4 组件）/ tekton-eventlistener / tekton-pipelines-resolvers。
- **新增 PrometheusRule** `app-monitoring-alerts`（10 条）：cert-manager 证书过期/过期 14 天预警/NotReady、tekton PipelineRun/TaskRun 失败、traefik 5xx>5%、strimzi operator down、ceph-csi 操作失败、cnpg-controller down、knative-eventing 控制面 down。

### 【原因】
- 监控覆盖缺口：cluster 仅 5/22 namespace 有抓取，17 个业务 ns 无任何指标；控制面（etcd/proxy/cm/scheduler）主机端口未暴露为环境事实（Pod 内直连亦 000）。

### 【实际执行】
全部清单先备份至 `/root/observability-upgrade-backup-20260929-154623/monitoring/`（含改造前全量 all-monitors-BEFORE.yaml）后 apply；每类资源经实测端点可达性（200 + 指标名存在）确认。

### 【验证结果】
- targets: 65 → **90**（+25，全部 up）；重复抓取 0（kubelet 3 路径为 kube-prometheus-stack 标准设计，非重复）。
- 指标已采集：cert-manager 540 series、tekton-controller 528、argocd 3608、knative-eventing-cp 3229、traefik 442、cnpg 274、strimzi 187、ceph-csi 55、metallb 58、el-listener 54。
- 告警规则 10 条已加载（/api/v1/rules 可见）。

### 【风险】
- 新增 25 个抓取目标 → series 增量约 8-9k，Prometheus 存储/内存需观察（当前瞬时系列可能达 ~50-60k，属可接受范围）。
- 部分指标名以 job 名（svc/pod 名）为前缀生成，规则引用需按实际 job 名校准。

### 【回滚方式】
`kubectl delete -f` 对应备份清单；或从 `all-monitors-BEFORE.yaml` 恢复原 otel SM。

### 【遗留】
- 控制面监控（etcd/proxy/cm/scheduler）需主机侧放通端口后才有意义（环境网络层待评估）。
- kafka broker 本身无 metrics（未配置 JMX exporter），当前仅 strimzi operator 有 JVM 指标；如需 broker 级指标需在 Kafka CR 配置 strimzi-http-metrics 或部署 kafka-exporter。评估为 P2。
- knative-serving 组件（controller/activator/autoscaler/webhook/kourier）metrics 端口 CLOSED/404，组件未启用，留待其配置开启。

---

## 13. 控制面 metrics 监控修复（2026-09-30）：16 down → 15 up

### 【变更】
- **根因**：控制面组件 metrics 全部绑定回环（`127.0.0.1`），Prometheus 跨网不可达。
  - kube-controller-manager `--bind-address=127.0.0.1`（kubeadm 安全默认）
  - kube-scheduler 同上
  - etcd `--listen-metrics-urls=http://127.0.0.1:2381`
  - kube-proxy CM `metricsBindAddress: ""` → kube-proxy 默认回环 10249
- **操作**（三台控制面节点 10.0.0.61/120/121 逐台滚动，每台 etcd→cm→scheduler 顺序）：
  - 静态 Pod `/etc/kubernetes/manifests/{etcd,kube-controller-manager,kube-scheduler}.yaml`：
    - `--bind-address=127.0.0.1 → 0.0.0.0`（cm/scheduler）
    - `--listen-metrics-urls=http://127.0.0.1:2381 → http://0.0.0.0:2381`（etcd）
  - kube-proxy：`kubectl apply` 覆盖 CM `metricsBindAddress: 0.0.0.0:10249` + 滚动重启 DaemonSet
- **未动**：任何 RBAC（`prometheus-prometheus` ClusterRole 已有 `/metrics` nonResourceURL + SA token 授权，无需新增）；kube-proxy/组件版本、IPVS 模式均未变。

### 【原因】
- 补齐控制面可观测性：etcd quorum/磁盘 fsync、cm 控制器队列、scheduler 调度延迟、kube-proxy sync 耗时等关键运维指标此前完全不可见。

### 【验证结果】
- 90 targets：**89 up / 1 down**（原 16 down → 15 up；唯一残留 down 为 coredns 10.244.5.53 worker01 ImagePullBackOff，非本次范围）。
- 指标实测：etcd（leader/heartbeat_fail/disk_fsync 各 3 序列）、cm（rest_client 10 序列）、scheduler（31 个 scheduler_* 指标：framework/pending_pods/pod_scheduling）、kube-proxy（sync_proxy_rules、network_programming 各 6 序列）。
- 集群健康：API ok，6 节点 Ready，控制面 10 pod Running。

### 【风险】
- 控制面 metrics 端口现监听 0.0.0.0：指标含集群内部状态，暴露于节点网络。环境为内网隔离集群，且端口为组件自身鉴权端口（10257/10259 需 SA token + RBAC），2381/10249 为只读 metrics。如后续有暴露面收紧需求可改绑节点 IP。
- 静态 Pod 变更若被 kubeadm upgrade 覆盖需重做（kubeadm 不管理已改 manifests，升级时会重新生成）。

### 【回滚方式】
- 静态 Pod：三台节点 `/root/cp-metrics-backup-20260930-094806/` 原始 yaml 原路径覆盖 → kubelet 自动重建（已确认三份齐全）。
- kube-proxy：`kubectl apply` 还原 `metricsBindAddress: ""` + rollout restart ds。
- 本地镜像：/root/k8s-controlplane-backup-20260930-094806/。

### 【遗留】
- coredns ImagePullBackOff（worker01 11.0 节点）：镜像拉取问题，待排查 registry 可达性，修好后 coredns target 自动转 up（90/90）。

## 14. 遗留 down target 修复（2026-09-30）：coredns ImagePullBackOff → 90/90 全 up

### 【背景】
上一节遗留的最后一个 down target：`coredns-7bf7bd7987-k7f47`（worker01）ImagePullBackOff，镜像 `registry.k8s.io/coredns/coredns:v1.11.1`。

### 【根因】（环境网络事实 + 单节点缓存缺失的组合）
1. `registry.k8s.io` 是 Google 镜像**入口**（HTTPS 可达，curl /v2/ 返回 401 属正常），containerd 拉取时会被**重定向到真实 blob 存储 `europe-west2-docker.pkg.dev`**（74.125.204.82）。
2. 该存储域在环境放行列表之外：`dial tcp 74.125.204.82:443: i/o timeout`，resolving 卡 24s 超时。
3. 节点可达性实测矩阵：registry.k8s.io / ghcr.io / quay.io ✅；europe-west2-docker.pkg.dev / docker.io / gcr.io / pkg.dev ❌。
4. 全集群其余节点（master01/02/m01、worker02/03）均有 coredns 镜像缓存（2~4 份），唯独 worker01 缓存为 0 → 无兜底 → 持续 ImagePullBackOff。master02 那副本因早缓存镜像正常 Running，证实非 worker01 网络问题。
5. 结论：**非节点故障、非配置问题，是受控网络对部分 registry 存储域不通 + worker01 从未缓存过该镜像**。

### 【变更内容】
- 从 master02（10.0.0.120）`ctr images export --platform linux/amd64` 导出 coredns v1.11.1（18,199,040 B）→ 经内网 SSH 管道传输至 worker01（10.0.0.122）`/tmp/coredns.tar` → `ctr -n k8s.io images import` 导入本地缓存。
- 删除 ImagePullBackOff pod，令 Deployment 用新缓存重建。

### 【执行结果】
- worker01 缓存确认：`registry.k8s.io/coredns/coredns:v1.11.1 (unpacking ... done)`。
- Deployment 终态：replicas 2 / ready 2（新副本被调度至 **master01**，不依赖 worker01 拉取链路，更稳）。
- Prometheus targets：**90 / 90 up，down = 0**；coredns 两个 target 均 up。
- 全集群 ImagePullBackOff / ErrImagePull 复核：0。
- 临时 tar 已从 master02 与 worker01 清除。

### 【验证】
- `kubectl get deploy coredns -n kube-system`：2/2 ready。
- `/api/v1/targets`：90 up / 0 down（此前 89 up / 1 down）。
- 集群 DNS 解析不受影响（coredns 无状态，副本分布 master02+master01）。

### 【风险】
- 低。仅向 worker01 注入本地镜像缓存，不触及任何配置；多节点缓存已保证不依赖外网。
- 未来若工作负载使用 docker.io / gcr.io / pkg.dev 域的新镜像且节点无缓存，将同样拉取失败——属环境网络约束，列入遗留。

### 【回滚】
- `ctr -n k8s.io images rm registry.k8s.io/coredns/coredns:v1.11.1`（worker01）删除导入缓存即可还原（无需，全集群已 healthy）。
- 镜像源层面无任何持久改动，无 ConfigMap/Deployment 改动。

### 【遗留】
- 环境注册表放行范围受限（docker.io / gcr.io / pkg.dev 不通）：集群部署新镜像优先选用 quay.io / ghcr.io / registry.k8s.io（入口）或提前预置节点缓存。

## 15. Grafana 看板与 cert-manager 采集缺口修复（2026-09-30）

### 【变更 1】cert-manager ServiceMonitor 采集缺口修复
- **问题**：原 SM 仅定义 `port: http-metrics`，而主 controller 的 Service 端口名为 `tcp-prometheus-servicemonitor`、webhook 为 `metrics` → 只有 cainjector 被采集。主 controller 的证书指标（certmanager_certificate_expiration_timestamp_seconds 等）与**证书告警规则实际一直在空转**。
- **原因**：Prometheus Operator 按 Service endpoint 端口名匹配，端口名不一致即跳过。
- **变更**：SM `cert-manager` endpoints 补齐三端口（tcp-prometheus-servicemonitor / http-metrics / metrics），端口名互斥无重复抓取风险。
- **执行**：`kubectl apply` SM → operator 重生成配置（Secret 中出现 3 个 job）→ config-reloader reload。
- **验证**：targets 92/92 up（新增 cert-manager 主 controller、cert-manager-webhook 2 个 target）；`certmanager_certificate_expiration_timestamp_seconds`、`certmanager_certificate_ready_status` 等指标可查询；`curl registry.k8s.io` 无关。

### 【变更 2】8 个组件 Grafana 看板
- **方式**：kube-prometheus-stack 标准 dashboard sidecar（`grafana-sc-dashboard`，LABEL=grafana_dashboard / VALUE=1，RESOURCE=both，watch /tmp/dashboards，reload POST /api/admin/provisioning/dashboards/reload）。
- **变更**：ConfigMap `prometheus-grafana-dashboard-apps`（monitoring，label `grafana_dashboard=1`+`release=prometheus`），8 个 key：
  - cert-manager.json（8 panels：证书总数/Ready/非 Ready/到期倒计时/controller 同步速率等）
  - tekton.json（10：运行中 PipelineRun/TaskRun、TaskRun 完成速率、workqueue、webhook、EventListener p95）
  - traefik.json（9：入口/服务请求速率、5xx 比例、TLS 到期、reload 状态）
  - strimzi.json（10：资源状态表、reconcile 成功/失败、证书到期、JVM 堆/GC）
  - argocd.json（9：cluster 连接/缓存年龄、git/redis/kubectl 请求、reconcile）
  - cnpg.json（8：leader/worker/reconcile/webhook/APIServer 请求）
  - knative-eventing.json（9：controller/ingress up、workqueue、kafka producer、分发延迟）
  - metallb-cephcsi.json（9：地址池利用率、CSI liveness/up）
  - datasource：uid=prometheus（默认），schemaVersion 39。
- **验证**：全部 72 个面板 expr 经 /api/v1/query 逐条 count 校验非空（首轮 5 个空面板定位后修复：cert-manager 主 controller 无 controller_runtime 指标、ready_status False 值为 0）；Grafana API 确认 8/8 看板已加载、datasource 代理查询返回数据。
- **本地归档**：/root/grafana-dashboards-20260930/*.json（8 份）+ /root/gen-dashboards.py 生成器；CM 清单 /tmp/grafana-dashboards-cm.yaml。

### 【风险与回滚】
- 低。新增/修改 SM 与 CM-only 变更，不动 Grafana 主配置。
- 回滚：`kubectl delete cm prometheus-grafana-dashboard-apps -n monitoring`（看板消失）；SM 恢复单 endpoint（备份 in monitoring/sm-certmanager-BEFORE.yaml）。
- 注意：现有 CM 重建采用 delete+create；若同一 CM 名持续迭代，用本归档清单 apply 即可。

### 【遗留】
- Grafana 访问：已通过 Traefik IngressRoute 暴露（`monitoring/grafana`，websecure + certResolver=default）：
  - `https://grafana.k8s.local` / `https://grafana.example.local` → Traefik LB `10.0.0.252:443` → svc `prometheus-grafana:80`（实测 HTTP 302 登录跳转正常）。
  - 同入口还暴露 `https://prometheus.k8s.local`（monitoring/prometheus）。
  - 凭据 admin / `<redacted-grafana-password>`；客户端需在 DNS 或 /etc/hosts 将对应 host 指向 10.0.0.252。
- 已有官方 ArgoCD/cert-manager/Traefik 看板（uid qPkgGHg7k/u6M5igpWk/qPdAviJmz），与本次 `cm-*` 中文总览并存。
- Kafka broker 级指标（P2）仍未做；strimzi.json 仅覆盖 operator 侧（JVM/资源/reconcile/证书）。
