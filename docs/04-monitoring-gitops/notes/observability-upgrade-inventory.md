# 可观测性栈升级 - 只读盘点报告

> 生成时间: 2026-09-28  
> 集群: Kubernetes v1.29.8 (6 nodes)  
> 阶段: 第一阶段 - 只读盘点

---

## 1. 集群概览

| 项目 | 值 |
|------|-----|
| Kubernetes 版本 | v1.29.8 |
| 节点数 | 6 (3 control-plane + 3 worker) |
| 容器运行时 | containerd://1.7.22 |
| 存储类 | ceph-rbd-sc (RBD), nfs-sc (NFS) |

---

## 2. Helm Release 清单

| Release | Namespace | Chart | App Version | Status | Revision |
|---------|-----------|-------|-------------|--------|----------|
| loki | logging | loki-6.55.0 | 3.6.7 | deployed | 2 |
| tempo | logging | tempo-distributed-1.61.3 | 2.9.0 | deployed | 1 |
| promtail | logging | promtail-6.17.1 | 3.5.1 | deployed | 2 |
| prometheus | monitoring | kube-prometheus-stack-83.7.0 | v0.90.1 | deployed | 3 |
| otel-operator | opentelemetry | opentelemetry-operator-0.106.0 | 0.145.0 | deployed | 1 |

### Helm Repo

| Name | URL |
|------|-----|
| grafana | https://grafana.github.io/helm-charts |
| prometheus-community | https://prometheus-community.github.io/helm-charts |
| open-telemetry | https://open-telemetry.github.io/opentelemetry-helm-charts |

---

## 3. 组件详细分析

### 3.1 Loki

| 项目 | 值 |
|------|-----|
| **Helm Chart** | loki-6.55.0 |
| **App Version** | 3.6.7 |
| **Deployment Mode** | SimpleScalable (backend + read + write) |
| **Gateway** | 启用 (Nginx) |
| **认证** | auth_enabled: true |
| **存储后端** | S3 (Ceph RGW) |
| **S3 Endpoint** | http://10.0.0.31:7480 |
| **S3 Buckets** | loki-admin, loki-chunks, loki-ruler |
| **Schema** | v13 (tsdb) |
| **Replication Factor** | 1 |
| **PVC** | data-loki-backend-0 (10Gi, ceph-rbd-sc), data-loki-write-0 (10Gi, ceph-rbd-sc) |
| **缓存** | chunks-cache (Memcached), results-cache (Memcached) |
| **是否 EOL** | ❌ 否 (3.6.7 为当前稳定版) |
| **目标版本** | 保持 3.6.7 或升级到最新 3.x |
| **是否需要迁移** | ⚠️ 可选 (SimpleScalable 模式仍受支持) |
| **风险** | 低 |

### 3.2 Tempo

| 项目 | 值 |
|------|-----|
| **Helm Chart** | tempo-distributed-1.61.3 |
| **App Version** | 2.9.0 |
| **Deployment Mode** | Microservices |
| **存储后端** | S3 (Ceph RGW) |
| **S3 Endpoint** | 10.0.0.31:7480 |
| **S3 Bucket** | tempo-traces |
| **组件** | distributor, ingester (3 replicas), compactor, querier, query-frontend, metrics-generator |
| **是否 EOL** | ⚠️ 是 (Tempo 3.x 已移除 ingester 和 compactor) |
| **目标版本** | Tempo 3.x (新架构: Kafka + block-builder + live-store) |
| **是否需要迁移** | ✅ 是 (必须迁移) |
| **风险** | 🔴 高 (架构变化大) |

### 3.3 Promtail

| 项目 | 值 |
|------|-----|
| **Helm Chart** | promtail-6.17.1 |
| **App Version** | 3.5.1 |
| **DaemonSet** | 6 replicas (每节点一个) |
| **Loki Push URL** | http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push |
| **Tenant** | fake |
| **Pipeline Stages** | cri, drop (older_than: 168h) |
| **是否 EOL** | ✅ 是 (2026-03-02 EOL) |
| **目标版本** | Grafana Alloy |
| **是否需要迁移** | ✅ 是 (必须迁移) |
| **风险** | 中 (需保持日志发现、labels、pipeline 兼容) |

### 3.4 OpenTelemetry Collector

| 项目 | 值 |
|------|-----|
| **部署模式** | Deployment (1 replica) |
| **镜像** | opentelemetry-collector-contrib:0.145.0 |
| **OTLP Endpoint** | gRPC :4317, HTTP :4318 |
| **Trace 导出** | tempo-distributor.logging.svc.cluster.local:4317 |
| **是否 EOL** | ❌ 否 (仍受支持) |
| **目标版本** | 保持或评估迁移到 Grafana Alloy |
| **是否需要迁移** | ⚠️ 可选 (可继续运行) |
| **风险** | 低 |

### 3.5 Prometheus Stack

| 项目 | 值 |
|------|-----|
| **Helm Chart** | kube-prometheus-stack-83.7.0 |
| **App Version** | v0.90.1 |
| **Prometheus** | 1 replica, 100Gi PVC (nfs-sc), retention 5d |
| **Alertmanager** | 1 replica, 20Gi PVC (nfs-sc) |
| **Grafana** | 1 replica, 10Gi PVC (nfs-sc) |
| **kube-state-metrics** | 运行中 |
| **node-exporter** | 6 replicas (DaemonSet) |
| **是否 EOL** | ❌ 否 |
| **目标版本** | 保持 |
| **是否需要迁移** | ❌ 否 |
| **风险** | 无 |

---

## 4. Grafana Datasource 配置

| Datasource | Type | URL | 状态 |
|------------|------|-----|------|
| Prometheus | prometheus | http://prometheus-prometheus.monitoring:9090/ | ✅ 正常 |
| Alertmanager | alertmanager | http://prometheus-alertmanager.monitoring:9093/ | ✅ 正常 |
| **Loki** | - | - | ❌ **缺失** |
| **Tempo** | - | - | ❌ **缺失** |

> ⚠️ **重要发现**: Grafana 当前只配置了 Prometheus 和 Alertmanager datasource，**没有配置 Loki 和 Tempo datasource**！

---

## 5. Kafka 集群信息

| 项目 | 值 |
|------|-----|
| **Cluster 名称** | my-cluster |
| **Kafka 版本** | 4.1.2 |
| **Bootstrap Service** | my-cluster-kafka-bootstrap (10.105.63.178:9092) |
| **Topic 数量** | 0 (无 topic) |
| **Partition 数量** | N/A |
| **Replication Factor** | N/A |
| **存储** | 未配置 (使用默认) |
| **Broker 状态** | Ready |

> ⚠️ **重要发现**: Kafka 集群已部署但**没有任何 topic**，Tempo 3.x 需要创建新 topic。

---

## 6. 存储配置

### Ceph RGW (S3)

| 项目 | 值 |
|------|-----|
| **Endpoint** | http://10.0.0.31:7480 |
| **Loki Buckets** | loki-admin, loki-chunks, loki-ruler |
| **Tempo Bucket** | tempo-traces |
| **Secret** | logging/loki-s3-secret |

### PVC 清单

| PVC | Namespace | StorageClass | 容量 | 状态 |
|-----|-----------|--------------|------|------|
| data-loki-backend-0 | logging | ceph-rbd-sc | 10Gi | Bound |
| data-loki-write-0 | logging | ceph-rbd-sc | 10Gi | Bound |
| prometheus-grafana | monitoring | nfs-sc | 10Gi | Bound |
| prometheus-prometheus-prometheus-db-... | monitoring | nfs-sc | 100Gi | Bound |
| alertmanager-prometheus-alertmanager-db-... | monitoring | nfs-sc | 20Gi | Bound |

---

## 7. Argo CD 管理状态

| 项目 | 结果 |
|------|------|
| **Argo CD 是否管理 observability** | ❌ 否 |
| **Argo CD Applications** | 无 logging/monitoring/opentelemetry 相关 |
| **管理方式** | 直接 Helm 部署 |

> ✅ **好消息**: 可观测性栈**不是**由 Argo CD 管理的，可以直接使用 helm upgrade 或 kubectl 修改。

---

## 8. 镜像版本清单

| 组件 | 镜像 | 版本 |
|------|------|------|
| Loki | docker.io/grafana/loki | 3.6.7 |
| Tempo | docker.io/grafana/tempo | 2.9.0 |
| Promtail | docker.io/grafana/promtail | 3.5.1 |
| OTel Collector | opentelemetry-collector-contrib | 0.145.0 |
| Memcached | memcached | 1.6.39-alpine |
| Nginx (Loki Gateway) | nginxinc/nginx-unprivileged | 1.29-alpine |
| Grafana | (由 kube-prometheus-stack 管理) | 12.4.3 |
| Prometheus | (由 kube-prometheus-stack 管理) | v3.11.2 |
| Alertmanager | (由 kube-prometheus-stack 管理) | v0.32.0 |

---

## 9. 组件 EOL 状态总结

| 组件 | 当前版本 | 是否 EOL | 目标版本 | 是否需要迁移 | 风险 |
|------|----------|----------|----------|--------------|------|
| **Promtail** | 3.5.1 | ✅ 是 (2026-03-02) | Grafana Alloy | ✅ 必须 | 中 |
| **Tempo** | 2.9.0 | ⚠️ 是 (3.x 架构变化) | Tempo 3.x | ✅ 必须 | 高 |
| Loki | 3.6.7 | ❌ 否 | 保持 3.6.7 | ⚠️ 可选 | 低 |
| OTel Collector | 0.145.0 | ❌ 否 | 保持 | ⚠️ 可选 | 低 |
| Prometheus | v3.11.2 | ❌ 否 | 保持 | ❌ 否 | 无 |
| Grafana | 12.4.3 | ❌ 否 | 保持 | ❌ 否 | 无 |
| Alertmanager | v0.32.0 | ❌ 否 | 保持 | ❌ 否 | 无 |
| kube-state-metrics | v2.18.0 | ❌ 否 | 保持 | ❌ 否 | 无 |
| node-exporter | v1.11.1 | ❌ 否 | 保持 | ❌ 否 | 无 |

---

## 10. 关键发现与风险

### 🔴 高风险

1. **Tempo 2.x → 3.x 迁移**
   - 架构完全变化 (ingester/compactor → Kafka + block-builder + live-store)
   - 需要创建 Kafka topic
   - 需要并行迁移，不能直接替换

2. **Grafana 缺少 Loki/Tempo datasource**
   - 当前只能查询 Prometheus 指标
   - 无法查询日志和追踪

### ⚠️ 中风险

3. **Promtail EOL**
   - 2026-03-02 已 EOL
   - 需要迁移到 Grafana Alloy
   - 需要保持日志发现、labels、pipeline 兼容

### ✅ 低风险

4. **Loki 3.6.7**
   - 当前稳定版，无需立即升级
   - SimpleScalable 模式仍受支持

5. **OTel Collector**
   - 仍受支持，可继续运行
   - 可评估是否迁移到 Alloy

---

## 11. 升级路径建议

### 第一阶段: Promtail → Grafana Alloy

```
Promtail (EOL)
    ↓
Grafana Alloy (并行部署)
    ↓
验证日志正常进入 Loki
    ↓
停止 Promtail
    ↓
删除 Promtail
```

### 第二阶段: Tempo 2.x → 3.x

```
Tempo 2.x (保持运行)
    +
Tempo 3.x (并行部署)
    ↓
创建 Kafka topic
    ↓
切换 OTLP 写入到 Tempo 3.x
    ↓
验证查询
    ↓
观察
    ↓
下线 Tempo 2.x
```

### 第三阶段: 补充 Grafana datasource

```
添加 Loki datasource
    ↓
添加 Tempo datasource
    ↓
验证 Grafana 查询
```

---

## 12. 迁移进度

### 已完成
1. ✅ 第一阶段：只读盘点
2. ✅ 第二阶段：备份
3. ✅ 第三阶段：分析升级路径
4. ✅ 第四阶段：Tempo 迁移方案设计
5. ✅ **Promtail → Alloy 迁移完成**
   - Alloy DaemonSet 已部署 (3 节点)
   - 日志推送验证通过 (Loki gateway 收到 204 响应)
   - Promtail 资源已完全删除

### 待执行
6. ⚠️ 第五阶段：Tempo 2.x → 3.x 迁移 — **暂停**
   - 原因：Helm chart 尚未发布 3.x 版本，Docker 镜像部署需要额外配置
   - 当前 Tempo 2.9.0 仍正常运行
   - 建议：等待官方 Helm chart 更新后再迁移
7. ⏭️ 第六阶段：补充 Grafana datasource (Loki/Tempo)
8. ⏭️ 第七阶段：全面验证

---

## 13. Tempo 3.x 迁移说明

### 当前状态
| 项目 | 状态 |
|------|------|
| Tempo 3.x 发布 | ✅ v3.0.3 (2026-08-13) |
| Helm chart 支持 | ❌ 尚未更新 (最新 1.61.3 / app 2.9.0) |
| Docker 镜像 | ✅ grafana/tempo:3.0.3 |
| 迁移状态 | ⏸️ 暂停 |

### Tempo 3.x 新架构变化
- 移除：Ingester、Compactor
- 新增：Kafka、Block Builder、Live Store
- 保留：Distributor、Query Frontend、Querier、Metrics Generator

### 迁移建议
1. **等待 Helm chart** — 推荐，官方支持更稳定
2. **手动部署** — 需要编写新的 K8s 配置，配置复杂
3. **保持 2.x** — Tempo 2.9.0 仍受支持，可继续运行

---

*报告由 kubectl/helm 只读命令自动生成*
