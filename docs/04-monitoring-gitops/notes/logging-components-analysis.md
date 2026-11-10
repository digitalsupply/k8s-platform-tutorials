# Logging 命名空间组件分析

> 分析时间: 2026-09-28

---

## 当前版本

| 组件 | 版本 | 状态 |
|------|------|------|
| Loki | 3.6.7 | 较新 |
| Tempo | 2.9.0 | 较新 |
| Promtail | 3.5.1 | 较新 |
| Memcached | 1.6.39-alpine | 较旧 |
| Nginx | 1.29-alpine | 较新 |

---

## 过时/不推荐使用的组件

### 1. loki-gateway (Nginx 网关)

| 项目 | 说明 |
|------|------|
| **当前状态** | 运行中 |
| **问题** | 自定义 Nginx 网关，增加了架构复杂性 |
| **官方推荐** | Loki 3.x 推荐直接使用 Grafana 作为前端，或使用 Loki 自带的网关 |
| **建议** | **可以移除**，直接使用 Grafana 查询 Loki |

### 2. loki-canary

| 项目 | 说明 |
|------|------|
| **当前状态** | 运行中 (3 副本) |
| **问题** | Loki Canary 是旧版监控工具，Loki 3.x 已集成更好的监控功能 |
| **官方推荐** | 使用 Grafana + Prometheus 监控 Loki 健康状态 |
| **建议** | **可以移除**，使用 Prometheus 监控替代 |

### 3. Memcached 缓存层

| 项目 | 说明 |
|------|------|
| **当前状态** | 运行中 (loki-chunks-cache, loki-results-cache, tempo-memcached) |
| **问题** | Loki 3.x 和 Tempo 2.x 使用对象存储，Memcached 不再是必需的 |
| **官方推荐** | 现代部署中通常使用 Redis 或依赖对象存储性能 |
| **建议** | **可以移除**，除非有明确的缓存需求 |

### 4. Promtail

| 项目 | 说明 |
|------|------|
| **当前状态** | 运行中 (6 副本 DaemonSet) |
| **问题** | Promtail 已被 OpenTelemetry Collector 取代 |
| **官方推荐** | Grafana 官方推荐使用 OpenTelemetry Collector 采集日志 |
| **建议** | **建议迁移**到 OpenTelemetry Collector |

### 5. Tempo 分布式架构组件

| 项目 | 说明 |
|------|------|
| **当前状态** | 运行中 (distributor, ingester, querier, query-frontend) |
| **问题** | Tempo 2.x 的分布式架构在 3.x 中已被简化 |
| **官方推荐** | Tempo 3.x 推荐使用单二进制模式或更简单的部署 |
| **建议** | **可以考虑简化**，但当前架构仍然可用 |

---

## 推荐保留的组件

| 组件 | 原因 |
|------|------|
| loki-backend | Loki 核心存储 |
| loki-write | Loki 写入组件 |
| loki-read | Loki 读取组件 |
| tempo-ingester | Tempo 核心存储 |
| tempo-querier | Tempo 查询组件 |
| tempo-query-frontend | Tempo 查询前端 |
| tempo-distributor | Tempo 数据分发 |
| tempo-compactor | Tempo 数据压缩 |
| tempo-metrics-generator | Tempo 指标生成 |

---

## 优化建议

### 短期优化

1. **移除 loki-gateway** - 直接使用 Grafana 查询 Loki
2. **移除 loki-canary** - 使用 Prometheus 监控替代
3. **评估 Memcached** - 如果没有明确缓存需求，可以移除

### 长期优化

1. **迁移 Promtail 到 OpenTelemetry Collector**
2. **升级 Loki 到 3.x 最新稳定版**
3. **升级 Tempo 到 3.x 并简化架构**

---

## 验证命令

```bash
# 查看 logging 命名空间所有资源
kubectl get all -n logging

# 查看 Loki 组件状态
kubectl get pods -n logging -l app.kubernetes.io/name=loki

# 查看 Tempo 组件状态
kubectl get pods -n logging -l app.kubernetes.io/name=tempo

# 查看 Promtail 状态
kubectl get pods -n logging -l app.kubernetes.io/name=promtail
```

---

*报告由 kubectl 自动生成*
