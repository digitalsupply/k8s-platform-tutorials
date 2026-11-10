# 集群可观测性（LGTM）链路运行状态分析报告

- **报告生成时间**：2026-09-30（含第四轮增量：target 全量修复验证）
- **采集方式**：`kubectl`（直连 API Server）、Pod 内 HTTP 探针、主机 systemd/端口/数据库查询、AWS CLI 直连 MinIO S3 API、临时 Pod 挂载 PVC 实测 `du`、节点侧 `ss -tln` + `/dev/tcp` 直连验证
- **集群**：Kubernetes v1.29.8，6 节点（3 control-plane + 3 worker），均 Ready
- **观测主机**：m01（10.0.0.61，Rocky 9.6）— 本机同时承载 K8s control-plane + Zabbix + 主机级 Prometheus exporter

> **本轮变更摘要**
> 0. ✅ **已修复 P1-3 + P2-7**：**16 个 down target 全部修复（92 up / 0 down）**，CoreDNS 副本恢复。属真修复（非删配置绕过），告警同步清除。详见 [5.4](#54--已修复--16-个-down-target-第四轮新增)。
> 1. ✅ **已修复 P0-1**：Grafana 的 Loki / Tempo 数据源已从「Web UI 手工添加」迁移为 **K8s 原生 ConfigMap provisioning**，与 Prometheus / Alertmanager 同构。详见 [3.1](#31-g--grafana)。
> 2. ✅ **新增第五章末节**：三大项目磁盘占用实测（指标 3.86 GiB / 日志 256 MiB / 追踪 0.4 MiB）。详见 [5.7](#57-磁盘占用实测第三轮新增)。
> 3. ⚠ **新增 P0-2**：Tempo 全链路无持久化 + 无真实 trace 流量。详见 [5.2](#52--p0--追踪链路完全空转)。
> 4. ℹ️ 已排除误报：Alertmanager 健康检查 `plugin unavailable` 属 Grafana 12 纯前端插件误报，实际查询正常。

---

## 一、总体结论（先看这段）

| 维度 | 状态 | 说明 |
|---|---|---|
| 组件可用性 | 🟢 全部 Running | monitoring / logging / opentelemetry 三命名空间共 60+ Pod 全部 Running，无 CrashLoop |
| 指标链路（M） | 🟢 **已修复** | **92 up / 0 down**（原 74/16）—— 控制面组件 metrics 端点已在 `0.0.0.0` 开放，真修复非绕过 |
| 日志链路（L） | 🟢 写入正常 | Alloy 6/6 节点采集，标签契约完整（10 个标签），Loki 3.6.7 微服务模式全部就绪 |
| 链路追踪（T） | 🔴 **空转** | Tempo 3.0.3 架构组件齐全且就绪（Kafka + live-store + block-builder），metrics-generator lag=0，但 **bucket 内无任何 trace block、Grafana 查询 tagNames 为空、且全部组件用 emptyDir 无持久化** |
| 告警 | 🟢 **已修复** | **firing 规则仅剩 Watchdog**（心跳，恒 firing 属正常）；Alertmanager 活跃告警 12 → **2 条**；etcd 全部 11 条规则 inactive |
| 统一入口 | 🟢 **已修复** | Grafana 四个数据源（Prometheus / Alertmanager / Loki / Tempo）**现已全部由 ConfigMap 原生 provisioning 管理**，uid 保持兼容，存量仪表盘变量引用未断 |
| 磁盘占用 | 🟢 无压力 | 指标 3.86 GiB / 日志 256 MiB / 追踪 0.4 MiB，合计约 4.1 GiB；PVC 配额普遍 <5% 使用率 |
| **保留窗口统一** | 🟢 **已修复** | **L/M/T 三层全部 5 天（120h）**：Prometheus `5d`、Alertmanager `120h`、Loki compactor `120h`（改前为**无限**）、Tempo `block_retention 120h`（改前 48h）。MinIO 兜底 `loki-chunks` ILM 7d→10d。详见 [retention-unification-5d.md](/root/retention-unification-5d.md) |
| 主机监控 | 🟡 半残 | Zabbix 6.0.42 服务正常、444 主机/17900 items 入库，但**其余 5 节点 Zabbix Agent 端口 10050 全部关闭**，实际只监控本机 |
| 遗留隐患 | 🟡 | 剩余待处理：Tempo 空转（P0-2）、AlertmanagerConfig 未使用、`repeat_interval: 12h` 偏长、S3 凭据明文、MinIO 桶未开 versioning |

**一句话**：指标与日志两条链路 + 统一查询入口**已全部打通并验证健康**（92/0 target、Grafana 四数据源原生化、告警从 12 条降到 2 条）；磁盘容量充裕。当前唯一的结构性短板是**追踪链路空转**——11 个 Tempo 组件 + Kafka topic 产出为零，且无持久化。

---

## 二、LGTM 整体架构

### 2.1 逻辑分层

```
┌─────────────────────────────────────────────────────────────────────┐
│  G — Grafana (monitoring/prometheus-grafana, 250d)                  │
│      数据源: Prometheus ✅  Alertmanager ✅  Loki ✅  Tempo ✅         │
│      ✅ 本轮已全部改为 ConfigMap 原生 provisioning（uid 兼容）       │
└───────────▲──────────────────────────────▲──────────────────────────┘
            │ PromQL                       │
┌───────────┴──────────────┐    ┌──────────┴──────────────────────────┐
│ M — Prometheus           │    │ A — Alertmanager                     │
│  prometheus-prometheus-0 │───▶│  alertmanager-prometheus-...-0      │
│  v3.11.2, retention 5d   │    │  v0.32.0 → webhook: n8n (5678)      │
│  50 rule groups/281 rules│    │  group_by: alertname/ns/severity     │
│  74 up / 16 down targets │    └──────────────────────────────────────┘
│  ServiceMonitor×22       │
│  PodMonitor×9            │    ┌──────────────────────────────────────┐
│  PrometheusRule×38       │    │ Grafana Operator                      │
└───────────▲──────────────┘    │ (config-reloader + k8s-sidecar)     │
            │                   └──────────────────────────────────────┘
            │ 抓取 /metrics (30s)
┌───────────┴──────────────────────────────────────────────────────────┐
│  采集源                                                                │
│  • node-exporter DaemonSet 6/6 (host:9100)                            │
│  • kube-state-metrics 1/1 (K8s 对象状态)                              │
│  • kubelet /metrics/cadvisor (18 targets)                             │
│  • apiserver ×3, etcd ×3, kube-proxy ×6, scheduler ×3, cm ×3           │
│  • 控制面组件: argocd / cert-manager / tekton / knative / strimzi /    │
│    metallb / traefik / ceph-csi / cnpg / otel-collector / tempo 组件   │
└───────────────────────────────────────────────────────────────────────┘

═══════════════════════════ 另一条正交的烟囱 ═══════════════════════════

┌──────────────────────────────────────────────────────────────────────┐
│  Zabbix 6.0.42 (主机 m01 本机)  ← 传统 VM/主机监控，与 LGTM 无联动     │
│    zabbix_server   :10051  (active running 2d)                       │
│    zabbix_agent2   :10050  (active running 2d)  ← 仅本机              │
│    zabbix_java_gw  :10052  (active running 2d)                       │
│    MariaDB         :3306   (444 hosts / 17900 items / 7118 triggers)  │
│    ⚠ 其余 5 节点 10050 全部 closed                                    │
├──────────────────────────────────────────────────────────────────────┤
│  主机级 Prometheus exporter (同机，与集群 Prometheus 独立)             │
│    alertmanager.service  :9093   (active running)                    │
│    node_exporter (pid 2558) :9100                                    │
│    mysqld_exporter      :9104                                       │
│    cadvisor              :8080                                       │
│    ⚠ 未接入集群 Prometheus / Grafana，属于"野生"暴露端口             │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 三条数据链路走向

**指标（M）**：ServiceMonitor/PodMonitor 声明 → Prometheus Operator 渲染成 scrape config → config-reloader 热加载 → 每 30s 拉取 → TSDB 落盘（本地 PVC，retention 5d）→ PrometheusRule 评估 → Alertmanager 路由 → n8n webhook。

**日志（L）**：Alloy DaemonSet（每节点 1 个）→ discovery.kubernetes role=pod 只选本节点 Pod → discovery.relabel 重建标签契约 → loki.source.file 读 `/var/log/pods/*/…` → loki.process（stage.cri 剥 CRI 包装 + stage.drop 丢弃 7 天前）→ loki.write → **loki-gateway（nginx）** → loki-write（ingester，WAL）→ loki-backend（compactor/index gateway）→ S3 兼容存储（10.0.0.31:7480，bucket `loki-chunks`）。

**追踪（T）**：应用 OTLP → otel-collector（4317/4318）→ ① `otlp_grpc` 直发 tempo3-distributor ② `spanmetrics` connector → Prometheus exporter :8889（指标）；distributor → **Kafka（my-cluster，topic `tempo-traces`）** → live-store×3（热查询）+ block-builder×3（转 Parquet）→ backend-scheduler → backend-worker（compaction/retention）→ querier → query-frontend。

---

## 三、逐组件详解：功能、关系、原理

### 3.1 G — Grafana

| 项 | 值 |
|---|---|
| 位置 | `monitoring/prometheus-grafana-fb7445bf9-4knb8`，1/1 Running，3/3 容器 |
| 版本 | Grafana 12.4.3 |
| 侧车 | `grafana-sc-dashboards`（k8s-sidecar 2.6.0，扫 `/tmp/dashboards`，30s）+ `grafana-sc-datasources`（同镜像，监听 ConfigMap） |
| 数据源 | ✅ **4 个，全部原生 provisioning**（本轮已修复，见下） |
| 存储 | PVC `prometheus-grafana`（10Gi，NFS），实测 53.4 MiB |
| 仪表盘 | 46 个（kube-prometheus 官方套件 + Loki/Tempo 官方套件 + `cm-*` 自研中文总览） |
| 仪表盘 CM | `prometheus-grafana-datasource`、`-config-dashboards`、`-overview` |

**原理**：Grafana 不存储数据，只做数据源联邦 + 仪表盘渲染。数据源有三种来源——UI 手工添加、ConfigMap provisioning、HTTP API。**只有 provisioning 管理的才能被 GitOps 纳管**，UI 建的只存在于 `grafana.db` 的 `data_source` 表。

#### ✅ 本轮修复：Loki / Tempo 数据源原生化

**问题发现**：初版报告发现 Grafana 只有 2 个数据源。深挖 `grafana.db`（`strings` 扫描）后发现，**Loki 和 Tempo 其实是存在的，但只存在于 Grafana 内部数据库**——是在 Web UI 里手工添加的，从未写进 `prometheus-grafana-datasource` ConfigMap。

从 `grafana.db` 提取出的原始配置：

| 名称 | uid | URL | 关键配置 |
|---|---|---|---|
| `loki` | `dfi90c2a1osn4c` | `http://loki-gateway.logging.svc.cluster.local` | `httpHeaderName1: X-Scope-OrgID` + UI 里设的隐藏值 |
| `tempo` | `afia1p4xshn9cf` | `http://tempo3-query-frontend.logging.svc.cluster.local:3200` | `tracesToLogsV2 → loki`、`tracesToMetrics → prometheus` |

**这种状态的风险**：数据能通（实测经 Grafana 代理查 Loki 正常），但**不持久**（重装/换 PVC 即丢）、**不在 GitOps**（环境漂移无从察觉）、**sidecar 形同虚设**（`grafana-sc-datasources` 监听的 ConfigMap 里没有它们）。

**迁移后**（写入 `prometheus-grafana-datasource` ConfigMap）：

```yaml
- name: "Prometheus"          # 保持不变
  type: prometheus
  uid: prometheus
  url: http://prometheus-prometheus.monitoring:9090/
  isDefault: true
  readOnly: true
  jsonData: {httpMethod: POST, timeInterval: 30s}

- name: "Alertmanager"        # 保持不变
  type: alertmanager
  uid: alertmanager
  url: http://prometheus-alertmanager.monitoring:9093/
  readOnly: true
  jsonData: {handleGrafanaManagedAlerts: false, implementation: prometheus}

- name: "Loki"               # ← 新增（接管 UI 创建的）
  type: loki
  uid: dfi90c2a1osn4c        # 沿用原 uid，存量仪表盘引用不断
  url: http://loki-gateway.logging.svc.cluster.local
  readOnly: true            # 原为 false，禁止 UI 篡改
  jsonData:
    maxLines: 1000
    timeout: 60
    httpHeaderName1: X-Scope-OrgID
    derivedFields: []
  secureJsonData:
    httpHeaderValue1: fake  # ← 关键：租户值加密存储

- name: "Tempo"              # ← 新增（接管 UI 创建的）
  type: tempo
  uid: afia1p4xshn9cf        # 沿用原 uid
  url: http://tempo3-query-frontend.logging.svc.cluster.local:3200
  readOnly: true
  jsonData:
    nodeGraph: {enabled: true}          # 启用服务拓扑图
    tracesToLogsV2:                    # trace → 日志下钻
      datasourceUid: dfi90c2a1osn4c
      spanStartTimeShift: -1h
      spanEndTimeShift: 1h
      filterByTraceID: true
      filterBySpanID: false
    tracesToMetrics:                   # trace → RED 指标下钻
      datasourceUid: prometheus
      spanStartTimeShift: -1h
      spanEndTimeShift: 1h
    serviceMap:
      datasourceUid: prometheus
    lokiSearch:
      datasourceUid: dfi90c2a1osn4c
```

**迁移中踩到的两个坑（已解决，值得记录）**：

1. **UID 冲突导致 provisioning 接管失败**
   Grafana 的 provisioning **只更新"它自己 provision 过"的数据源**；UI 手工创建的即使 uid 完全相同，也会报 `Datasource provisioning error: data source with the same uid already exists`，且 `grafana-sc-datasources` sidecar 每 10s 重试一次、全部失败（日志刷满）。
   → 解法：先 `DELETE /api/datasources/uid/<uid>` 删掉 UI 建的，再 `POST /api/admin/provisioning/datasources/reload`，provisioning 立即接管。

2. **Loki 租户头必须用 `secureJsonData`**
   Loki 开启 `auth_enabled: true`，不带 `X-Scope-OrgID` 直接返回 `401 no org id`。Alloy 写入时用 `tenant_id = "fake"`，Grafana 查询必须送同一个值。
   配对规则：`jsonData.httpHeaderName1: X-Scope-OrgID` + `secureJsonData.httpHeaderValue1: fake`（值加密存储，API 只回显 `secureJsonFields.httpHeaderValue1: true`）。

**兼容性验证**：全量扫描 46 个仪表盘的 datasource 引用，**无一硬编码 `dfi90c2a1osn4c` / `afia1p4xshn9cf`**。`Lightweight APM for OpenTelemetry` 仪表盘用的是 `type=datasource, query=loki/tempo` 变量，`loki_stack_monitoring_quortex` 无变量引用 → 保留 uid + 类型即可，零影响。

**迁移后实测**：

```
name=Prometheus    uid=prometheus     type=prometheus    readOnly=true  ✅ health OK
name=Alertmanager  uid=alertmanager   type=alertmanager  readOnly=true  ✅ 查询正常
name=Loki          uid=dfi90c2a1osn4c type=loki          readOnly=true  ✅ 10 个标签正常返回
name=Tempo         uid=afia1p4xshn9cf type=tempo         readOnly=true  ⚠️ tagNames 为空（见 5.2）
```

**ℹ️ 已排除的误报**：Alertmanager 数据源健康检查返回 `500 plugin unavailable`，但实际查询完全正常（能取到 12 条告警）。原因是 Grafana 12.x 中 Alertmanager 是**纯前端插件、没有后端 healthcheck 实现**，`/health` 端点无对应 handler。**不是故障，无需处理。**

**⚠️ 遗留**：该 ConfigMap 目前是**手动 apply**，尚未纳入 ArgoCD 管理（集群有 argocd 命名空间，运行 255d）。若后续 ArgoCD sync 可能覆盖或冲突。

### 3.2 M — Prometheus + kube-state-metrics + node-exporter

| 项 | 值 |
|---|---|
| 版本 | v3.11.2（revision f0f0fdd，go 1.26.2） |
| 存储 | TSDB，retention **5d**，max-block-duration 12h |
| 活跃 series | 208,760（head），label pairs 12,974，chunks 406,233 |
| 高基数指标 | `apiserver_request_duration_seconds_bucket` 19,240 / `etcd_request_duration_seconds_bucket` 14,370 / `apiserver_request_sli_duration_seconds_bucket` 10,200 |
| 高基数标签 | `namespace=default` 115,743 series；`instance` 标签占 5.27 MB 内存 |
| targets | ✅ **92 up / 0 down**（原 74 up / 16 down，已全部修复） |
| 新增覆盖 | `cert-manager-cainjector`、`cert-manager-webhook`（原未纳管，现各 1 个 target） |
| dropped targets | 821（正常：PodMonitor 选中的 Pod 上非容器端口） |
| 规则 | 50 groups / 281 rules |
| firing 规则 | ✅ 仅 `general.rules/Watchdog`（心跳，恒 firing 属正常设计） |

**node-exporter**：DaemonSet 6/6，6 节点全覆盖（m01、master01/02、worker01/02/03）。
**kube-state-metrics**：Deployment 1/1，把 K8s 对象（Pod/Deployment/Job 等）状态转成指标，是 `kube_pod_info`、`kube_pod_container_resource_*` 等指标的来源。

#### ✅ 原 16 个 down target 已全部修复

**原问题**（全部 `connection refused`，不是超时）：

| job | 原 down | 原因 | 现状态 |
|---|---|---|---|
| kube-proxy | 6/6 | metrics 端口 10249 未监听 | ✅ 6/6 up |
| kube-controller-manager | 3/3 | 10257 未监听（kubeadm 默认 bind 127.0.0.1） | ✅ 3/3 up |
| kube-scheduler | 3/3 | 10259 同上 | ✅ 3/3 up |
| kube-etcd | 3/3 | 2381 未开 / 需 `--listen-metrics-urls` | ✅ 3/3 up |
| coredns | 1/2 | 该副本 ImagePullBackOff | ✅ 2/2 up |

**验证结论：真修复，不是删配置绕过。** 三重证据：

1. **端口确实在监听，且绑定 `0.0.0.0`**（不是 127.0.0.1 的假象）
   ```
   10.0.0.120:10249 LISTEN  *:10249     ← * 即 0.0.0.0
   10.0.0.120:10257 LISTEN  *:10257
   10.0.0.120:10259 LISTEN  *:10259
   10.0.0.120:2381  LISTEN  *:2381
   10.0.0.61 :10249 LISTEN  *:10249
   10.0.0.61 :10257 LISTEN  *:10257
   ```
2. **从另一节点直连拉到真实 metrics 内容**（非空响应）
   ```
   $ curl http://10.0.0.120:10249/metrics
   HTTP/1.0 200 OK
   Content-Type: text/plain; version=0.0.4
   Process-Start-Time-Unix: 1790733161
   # HELP aggregator_discovery_aggregation_count_total ...
   ```
3. **series 数与节点数吻合**，抓取耗时正常（7–26ms），`lastScrape` 时间戳均为最新
   ```
   up{job="kube-proxy"}              = 6 series
   up{job="kube-etcd"}               = 3 series
   up{job="kube-scheduler"}          = 3 series
   up{job="kube-controller-manager"} = 3 series
   up{job="coredns"}                 = 2 series
   ```

**告警同步清除**（指标恢复后规则自动恢复）：

| 规则 | 修复前 | 修复后 |
|---|---|---|
| `etcd/etcdMembersDown` (warning) | firing | **inactive** ✅ |
| `etcd/etcdInsufficientMembers` (**critical**) | firing | **inactive** ✅ |
| `general.rules/TargetDown` (warning) | firing | **inactive** ✅ |
| `kubernetes-apps/KubePodNotReady` | firing | **inactive** ✅ |
| etcd 全部 11 条规则 | 部分 firing | **全部 inactive** ✅ |
| **Alertmanager 活跃告警** | **12 条** | **2 条** ✅ |

> **结论确认**：此前的 `etcdMembersDown` / `etcdInsufficientMembers`（critical）**确系误判**——etcd 三副本一直健康，只是 metrics 端点未开放导致规则拿不到数据。端口开放后告警立即自愈，印证了初版报告「可能是指标没采到导致误判」的推断。

**CoreDNS 同步恢复**（ImagePullBackOff 的副本已被替换）：
```
coredns-7bf7bd7987-4d7ts   1/1 Running  2d18h   10.244.59.213   master02
coredns-7bf7bd7987-55xxh   1/1 Running  4h44m  10.244.241.103  master01  ← 新副本
```
`process_start_time` 证实新副本为 4h44m 前启动（真拉起了新 Pod，非复活旧 Pod），两副本 target 均 up。**DNS 冗余已恢复**。

**数量说明**：本次共 16 个存量 down target 修复，另新增覆盖 2 个此前未纳管的 cert-manager 组件（`cert-manager-cainjector` / `cert-manager-webhook`），target 总数 90 → 92，净效果 **0 down**。

### 3.3 A — Alertmanager

| 项 | 值 |
|---|---|
| 版本 | v0.32.0，`alertmanager-prometheus-alertmanager-0` 1/1 Running（2 容器） |
| 活跃告警 | ✅ **2 条**（原 12 条，target 修复后同步下降） |
| 集群 gossip | `{"peers":[],"status":"disabled"}` — 单副本，未启用 cluster |
| 唯一 receiver | `n8n-webhook` → `http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts`（已验证 200 可达） |
| inhibit_rules | critical 抑制 warning/info；warning 抑制 info；InfoInhibitor 抑制 info |
| route | group_by=[alertname,namespace,severity]，group_wait 30s，group_interval 5m，repeat_interval **12h** |

**原理**：Prometheus 只负责"判定"，通知与去重是 Alertmanager 的事。这里的 inhibit 链做得不错（避免告警风暴），但 `repeat_interval: 12h` 偏长——持续 12 小时的问题会长时间静默。

**同时注意**：主机上还有第二个 `alertmanager.service`（systemd，:9093），与集群内这个**完全是两套**，配置不同、数据不通。属于架构重复，建议二选一。

### 3.4 L — Loki 3.6.7 微服务模式 + Grafana Alloy

**Loki 组件拓扑**：

| 组件 | 类型 | 数量 | 职责 |
|---|---|---|---|
| loki-gateway | Deployment | 1 | nginx 反代，鉴权头注入、超时控制（600s）、`X-Query-Tags` 处理 |
| loki-write | StatefulSet | 1 | **Ingester**，写 WAL、按 stream 内存缓存，周期性 ship 到对象存储 |
| loki-backend | StatefulSet | 1 | Compactor + Index Gateway + Ruler，2 容器（loki + loki-sc-rules） |
| loki-read | Deployment | 1 | Querier（target: read），执行 LogQL |
| loki-chunks-cache | StatefulSet | 1 | memcached 1.6.39，chunk 缓存 |
| loki-results-cache | StatefulSet | 1 | memcached 1.6.39，query_range 结果缓存（TTL 12h） |
| loki-canary | DaemonSet | 3 | 持续写读日志自检 |
| loki-memberlist | Service | — | gossip 7946，ring 发现 |
| alloy | DaemonSet | 6/6 | 日志采集（替代 Promtail） |

**关键配置**：
```yaml
schema_config: v13 + store: tsdb（索引也用 TSDB，非 boltdb）
compactor/index_gateway 模式: boltdb_shipper + tsdb_shipper 都走 index_gateway_client
replication_factor: 1（无冗余）
对象存储: S3 兼容 http://10.0.0.31:7480, bucket=loki-chunks, s3forcepathstyle, insecure
ruler bucket: loki-ruler
reject_old_samples: true, max_age: 168h（7 天）
query_timeout: 300s, split_queries_by_interval: 15m
pattern_ingester.enabled: false（未做日志行模式提取）
tracing.enabled: false（Loki 自己不产生 trace）
```

**已关闭的能力**：bloom_build / bloom_gateway（`enabled: false`）——意味着**没有结构化元数据索引，`|= "error"` 这类查询是全量扫描**，日志量大时会慢。

**Alloy 标签契约**（从旧 Promtail 配置 1:1 复刻，备份在 `/root/observability-upgrade-backup-20260928-122529`）：
```
node_name / job / app / instance / component / pod / container / namespace / service_name
```
`job` = `<namespace>/<app>`。`node_name` 而非 `node`——存量 LogQL 依赖这个标签名，改名会打断历史查询。

**Alloy 迁移中踩过的两个坑（配置注释里明确记录了）**：
1. `discovery.kubernetes(role="pod")` 不产 `__path__`，必须手工拼两条规则：A=`/var/log/pods/*<uid>/<container>.log`（uid 形式），B=`config.hash` 注解形式（兼容老 Deployment）。
2. `loki.source.file` 默认对 `__path__` 做字面量 `os.Stat`，不展开 glob（实测 65 个 target 全部 `no such file or directory`）。必须开 `file_match { enabled=true, sync_period="10s" }`，改由 doublestar 做通配发现 + 自动感知轮转。
3. `tail_from_end = true` — 从文件末尾开始追，**代价是迁移窗口（约 4h）的历史日志不回填**。

**验证结果**：Loki 就绪 200，标签 API 返回 `["app","component","container","filename","instance","job","namespace","node_name","pod","service_name","stream"]` — 契约完整。
⚠ 注意：Loki 开了 `auth_enabled: true`，**不带 `X-Scope-OrgID` 头直接访问返回 401 "no org id"**。Alloy 写入了 `tenant_id = "fake"`，但 Grafana 接入时必须配上同名 header，否则查询直接 401。

### 3.5 T — Tempo 3.0.3（Kafka ingester 新架构）

这是本集群最现代的一部分，用的是 Tempo v3 的新 ingest 架构，而非经典 local-blocks 模式。

| 组件 | 类型 | 数量 | 职责 |
|---|---|---|---|
| tempo3-distributor | Deployment | 1 | 收 OTLP 4317/4318，做 span 属性校验与分区（**接收 Kafka 路径**） |
| tempo3-live-store | StatefulSet | **3** | 热存储（Kafka 消费 + WAL），支持最近数据即时查询 |
| tempo3-block-builder | StatefulSet | **3** | 后台把 live-store 数据转成 Parquet block（含 bloom、footer） |
| tempo3-backend-scheduler | StatefulSet | 1 | 作业调度（compaction / retention） |
| tempo3-backend-worker | StatefulSet | 1 | 执行 compaction、retention |
| tempo3-querier | Deployment | 1 | 查询执行 |
| tempo3-query-frontend | Deployment | 1 | 查询分片、结果合并 |
| tempo3-metrics-generator | Deployment | 1 | 生成 RED 指标 + service graph |
| tempo3-memcached | StatefulSet | 1 | parquet-footer / bloom / frontend-search 缓存 |

**核心原理（新架构的关键变化）**：
```
distributor --(OTLP)--> Kafka(topic: tempo-traces, 3 partitions, auto-create)
                              │
              ┌───────────────┴───────────────┐
              ↓                               ↓
    live-store ×3                        metrics-generator
    (消费 Kafka，WAL 持久化)              (消费 Kafka，生成指标)
    热查询直接读                          → Prometheus :8889
              │
              ↓ 后台转换
    block-builder ×3  →  Parquet block
              │
              ↓ 调度执行
    backend-scheduler → backend-worker (compaction / retention)
              ↓
    querier → query-frontend → 用户
```

**关键参数**：
```yaml
block_retention: 48h（原始 block 保留 2 天）
compacted_block_retention: 1h
compaction_window: 1h
max_compaction_level: 0（不叠多层）
max_block_bytes: 100GB
metrics_generator: service_graphs + span_metrics 双 processor
  span_metrics buckets: 2ms → 4.1s（15 档）
  service_graphs buckets: 0.1s → 12.8s（8 档），wait 10s
memberlist: cluster_label 'tempo3.logging', port 7946
缓存: memcached（parquet-footer / bloom / frontend-search 三个 role）
```

**存储配置（本轮补充）**：
```yaml
storage:
  trace:
    backend: s3
    bucket: tempo-traces
    endpoint: 10.0.0.31:7480        # 与 Loki 同一个 MinIO，但用独立账号
    access_key:  <redacted>  # ← 明文写在 ConfigMap
    secret_key:  <redacted>  # ← 明文写在 ConfigMap
    forcepathstyle: true
    insecure: true
    wal: {path: /var/tempo/wal}       # ← 在 emptyDir 上，无持久化
    local: {path: /var/tempo/traces}
    search: {prefetch_trace_count: 1000}
metrics_generator:
  storage:
    remote_write:
      - send_exemplars: true          # exemplar：指标可下钻到 trace
        url: http://prometheus-prometheus.monitoring:9090/api/v1/write
        remote_write_add_org_id_header: true
        remote_write_flush_deadline: 1m
multitenancy_enabled: false
usage_report: {reporting_enabled: true}
```

**运行验证**：
- `/ready` 200
- metrics-generator `assigned_partitions = 12`（消费 lag 0），`bytes_received_total{tenant="single-tenant"} = 518`
- **⚠ 关键风险：block_retention 仅 48 小时** — 链路数据两天就没了。而 Prometheus 指标保留 5 天、Loki 接受 7 天内数据。三者留存窗口严重不匹配，做跨层关联分析（比如"某次慢请求当时的 trace"）时大概率查不到。

**🔴 但更严重的问题是：这条链路根本没有数据（详见 5.2）**
- S3 `tempo-traces` bucket 只有 **16 个对象 / 393 KiB**，内容全是元数据（`tempo_cluster_seed.json`、`work.json`），**一个 trace block 都没有**
- Grafana 代理查 Tempo 返回 `{"tagNames":[],"metrics":{}}`
- 所有 Tempo 组件（live-store ×3、block-builder ×3、distributor、backend-worker）**全部挂 emptyDir，无任何 PVC**
- 结论：架构是新的、组件是齐的、进程是活的，但**没有任何应用在发 OTLP**。`block_retention: 48h` 的风险目前还是"潜在的"，等真接入流量后会立刻变成实际问题。

### 3.6 O — OpenTelemetry Collector

| 项 | 值 |
|---|---|
| CR | `OpenTelemetryCollector/opentelemetry.io/otel`（operator 管理，managed 模式） |
| 版本 | 0.145.0，contrib 发行版 |
| 运行时长 | 176d（但 pod 是 24h 前重建的，8 个旧 ReplicaSet 缩容到 0） |

**管道配置**（`spec.config`）：
```yaml
receivers:  otlp (grpc 4317 / http 4318)
connectors: spanmetrics          ← 关键：span → RED 指标转换
processors: batch (1000/10s)
exporters:
  otlp_grpc/tempo → tempo3-distributor:4317 (insecure)
  prometheus     → 0.0.0.0:8889 (namespace=otel_demo, resource_to_telemetry_conversion)
  debug          (basic)
service.pipelines:
  traces: [otlp] → batch → [otlp_grpc/tempo, debug, spanmetrics]
  metrics: [spanmetrics] → prometheus (:8889)
  telemetry: pull exporter :8888（自身指标）
```

**原理**：Collector 是"厂商中立的接入层"。这里它干了两件关键事——**双写**（trace 同时给 Tempo 和 debug）以及 **spanmetrics 连接器**（把 span 合成的 RED 指标暴露成 Prometheus 格式，所以 span 数据丢失也能在指标层保留聚合视图）。这也解释了 Prometheus 的 targets 里为什么有 `otel-collector=1` 和 `otel-collector-monitoring=1` 两个 job。

**注意**：`tracing.enabled: false` 在 Loki 侧，Collector 自身不生成 trace，只透传。

### 3.7 主机级 Zabbix 6.0.42

| 项 | 值 |
|---|---|
| 版本 | 6.0.42（Revision 6b0c0216865，2025-09-29 编译） |
| 进程 | zabbix_server **51 个 worker 进程**监听 :10051（IPv4+IPv6） |
| 数据库 | MariaDB :3306，**444 hosts / 17,900 items / 7,118 triggers** |
| housekeeper | 正常，每小时执行，0.09–0.12s/sec，清洗正常 |
| Java Gateway | active running（JMX 监控 Java 应用，本集群未配 JMX 项） |
| Agent2 | :10050 仅本机在监听 |

**🔴 关键发现**：其余 5 节点（master01/02、worker01/02/03）的 10050 端口**全部 connection refused**。444 个 host 入库、17,900 个 item 在采，但 agent 只在本机跑——**要么 5 台机器没装 agent，要么防火墙全挡了**。当前 Zabbix 实际上是"单节点监控 444 个虚拟 host 对象"的状态，历史数据里可能曾经正常，需要确认 agent 是被移除还是失联。

---

## 四、CRD 详解：每一类干什么、怎么被消费

集群里共有 11 个可观测性相关 CRD（10 个 `monitoring.coreos.com` + 1 个 `monitoring.grafana.com`）：

### 4.1 核心 CRD（已启用 v1）

| CRD | Kind | scope | 数量 | 作用 | 原理 |
|---|---|---|---|---|---|
| `prometheuses.monitoring.coreos.com` | Prometheus | Namespaced | 1 | **声明整个 Prometheus 实例** | 顶层控制器 CR：定义镜像版本、保留期、存储、资源、节点选择、副本数。Operator 由此生成 StatefulSet + Service + PVC + config-reloader Sidecar |
| `alertmanagers.monitoring.coreos.com` | Alertmanager | Namespaced | 1 | 声明 Alertmanager 实例 | 同上，生成 STS + config-reloader；`spec.alertmanagerConfiguration` 指向一个 AlertmanagerConfig |
| `prometheusrules.monitoring.coreos.com` | PrometheusRule | Namespaced | **38** | **声明告警/记录规则** | 纯粹的数据载体，Operator 把 `spec.groups[].rules[]` 拼接进 Prometheus 的 `rule_files`。不生成任何 workload |
| `servicemonitors.monitoring.coreos.com` | ServiceMonitor | Namespaced | **22** | **按 Service 发现抓取目标** | Operator 生成 `kubernetes_sd_configs` 里的 `role: endpoints`，从 Service 的 label/annotation 读取端口与路径。**只抓 Service 后端，不认 Pod** |
| `podmonitors.monitoring.coreos.com` | PodMonitor | Namespaced | **9** | **按 Pod 发现抓取目标** | `role: pod`，直接按 label selector 选 Pod，从 Pod annotation 读容器端口。适合没有 Service 的组件（如 operator、webhook） |
| `probes.monitoring.coreos.com` | Probe | Namespaced | 0 | **黑盒探测** | 定义 `module`（http/tcp/icmp）+ 目标列表，Operator 生成独立的 blackbox-exporter 抓取任务 |

**本集群的实际分布**（关键观察）：
- `ServiceMonitor` 22 个，覆盖 ceph-csi、cert-manager、knative-eventing、traefik、tekton、metallb、kafka/strimzi、cnpg、argocd、otel-collector、tempo3 相关
- `PodMonitor` 9 个，集中在**没有 Service 的 operator/webhook 类组件**（tekton-eventlistener、strimzi-cluster-operator、metallb-controller、cnpg-controller-manager、tempo3-components）
- 命名空间隔离：ServiceMonitor/PrometheusRule 放在**被监控组件所在的 namespace**，`serviceMonitorNamespaceSelector` 决定 Prometheus 跨 ns 选谁 —— 这是这套 CRD 体系的核心设计：**配置跟着被观测对象走，而不是集中在 monitoring ns**

### 4.2 实验性 CRD（v1alpha1，已装未用）

| CRD | Kind | 作用 | 原理 |
|---|---|---|---|
| `scrapeconfigs.monitoring.coreos.com` | ScrapeConfig | 抓取"无法用 Service/Pod 表示"的异构目标 | 直接写 `static_configs`、`file_sd_configs`、`consul_sd` 等原生配置，Operator 直接透传到 scrape_config。**这是 Prometheus Operator 的逃生舱** |
| `alertmanagerconfigs.monitoring.coreos.com` | AlertmanagerConfig | 细粒度告警路由配置 | 通过 `alertmanagerConfiguration` selector 被 Alertmanager CR 引用，定义 receiver（webhook/email/slack）、route、inhibit。本集群 0 个使用 —— 意味着**所有告警走同一个 n8n receiver，无法按严重性/团队分流** |
| `thanosrulers.monitoring.coreos.com` | ThanosRuler | 跨集群 Recording Rules + 告警 | 需要 Thanos sidecar/Ruler。当前 Prometheus CR 里的 `thanos` 段未配置，**集群无 Thanos，指标无法横向扩展** |
| `prometheusagents.monitoring.coreos.com` | PrometheusAgent | 轻量采集代理（只抓不存不评估） | 用于推送模式（remote write）。本集群 0 个使用 |
| `podlogs.monitoring.grafana.com` | PodLogs | **Grafana 关联 Pod 日志的元数据 CR** | Grafana 用来把日志行关联到 K8s 对象（owner、annotation），支撑"点击指标跳到日志"。本集群 0 个使用 |

### 4.3 CRD 之间的协作关系

```
                    ┌──────────────────┐
                    │  Prometheus (CR) │  ← 顶层：决定实例怎么跑
                    └────────┬─────────┘
                             │ serviceMonitorSelector / podMonitorSelector
                             │ ruleSelector / scrapeConfigSelector
              ┌──────────────┼──────────────┬──────────────────┐
              ↓              ↓              ↓                  ↓
      ServiceMonitor   PodMonitor    ScrapeConfig      PrometheusRule ×38
        (22 个)          (9 个)       (0 个)             │
              └──────────────┴──────────────┘                    │
                             │                                   │
                    Prometheus 渲染出 scrape_config          rule_files
                             │                                   │
                    ┌────────▼────────┐              ┌─────────▼─────────┐
                    │ Prometheus Pod  │───alerts────▶│ Alertmanager (CR) │
                    │ + config-reloader│              │ + config-reloader │
                    └─────────────────┘              └─────────┬─────────┘
                                                                 │ alertmanagerConfiguration
                                                        ┌────────▼─────────┐
                                                        │ AlertmanagerConfig│
                                                        │  (0 个，未使用)   │
                                                        └──────────────────┘
```

**Operator 的核心价值**：用户只写声明式 CR，Operator 负责**渲染配置 + 创建 StatefulSet/Deployment/Service/PVC + 处理配置热重载 + 版本升级**。`quay.io/prometheus-operator/prometheus-config-reloader:v0.90.1` 就是热加载 sidecar —— 它 watch ConfigMap 变化，通过 HTTP 请求通知 Prometheus/Alertmanager 重新加载配置，**无需重启 Pod**。这就是为什么所有组件的 restarts 计数存在但配置仍能平滑更新。

---

## 五、发现的问题清单（按优先级）

### 🔴 P0 — 影响可观测性能力本身

**1. ✅ 已修复 — Grafana 未接入 Loki 和 Tempo 数据源**
- 原现象：`/etc/grafana/provisioning/datasources/` 只有 `prometheus` 和 `alertmanager`
- 实际真相：Loki/Tempo **在 Web UI 里手工添加过**，只存在于 `grafana.db`，不在 ConfigMap → 不持久、不在 GitOps、sidecar 失效
- 修复动作：已迁为 ConfigMap 原生 provisioning，**沿用原 uid**（`dfi90c2a1osn4c` / `afia1p4xshn9cf`），补齐 `tracesToLogsV2` / `tracesToMetrics` / `nodeGraph` / `serviceMap` 关联，Loki 租户头用 `secureJsonData` 加密存储
- 验证：四数据源 health 全 OK，46 个仪表盘引用扫描确认零影响
- 详见 [3.1](#31-g--grafana)
- **⚠ 遗留**：ConfigMap 目前是手动 apply，未纳入 ArgoCD，建议纳管

**2. 🔴 追踪链路完全空转（本轮新发现，优先级高于原 #2）**
- 现象一：S3 `tempo-traces` bucket 仅 **16 个对象 / 393 KiB**，全是元数据（`tempo_cluster_seed.json`、`work.json`），**零个 trace block**
- 现象二：Grafana 代理查 Tempo 返回 `{"tagNames":[],"metrics":{}}` — 空
- 现象三：`tempo3-live-store` ×3、`block-builder` ×3、distributor、backend-worker **全部挂 emptyDir，无任何 PVC**
- 现象四：otel-collector 的 traces 管道虽配好（`otlp → tempo3-distributor`），但**没有应用真的在发 OTLP**
- 影响：T 层投入了 11 个组件 + Kafka topic + MinIO bucket 的资源，**产出为零**。且无持久化意味着即便有流量，节点重启即丢热数据和 WAL
- 修复：
  1. 先确认入口：检查 `otel-collector` 的 4317/4318 端口实际连接数，确认是无流量还是采集端配错
  2. 为 live-store / block-builder 加 PVC（`ceph-rbd-sc`），WAL 路径必须落在持久卷上
  3. 同时修 `block_retention`（见下条 #3），否则接入流量后 48h 就丢
- **建议优先排查**：这不是配置错误，是"接了栈但没接业务"。在确认业务侧 OTLP 接入计划前，T 层属于纯成本。

**3. ✅ 已修复 — 保留窗口不匹配（原报告归因有误，已在第五轮纠正）**

> **⚠️ 本条原始归因是错的，保留原文作为审计轨迹。** 原报告写「日志（7d）」，实际 Loki 当时**没有任何保留策略**。真实窗口是 5d / **无限** / 2d。

- 原现象（原报告表述）：`block_retention: 48h` vs Prometheus `retention.time: 5d` vs Loki `reject_old_samples_max_age: 168h`
- **第五轮实测纠正**：
  - Loki `compactor` 段**根本不存在**，`limits_config.retention_period: 0s`（0s 官方语义 = **永久保留**），`retention_enabled: false` → 日志在**无界增长**，这比"窗口不齐"更严重
  - `reject_old_samples_max_age: 168h` 是**写入闸门**（拒绝超龄样本），`stage.drop 168h` 是**采集侧读取过滤**——两者都**不删除**任何数据
  - 真正在删日志的是 **MinIO 桶 `loki-chunks` 的 ILM 规则** `delete-old-logs`（`Expiration: Days: 7`, Enabled），Loki 对此**完全不可见**
- 修复动作（2026-09-30）：三层统一为 5 天
  - Tempo `block_retention` 48h → **120h**（`backend_scheduler` 与 `backend_worker` **两处**，只改一处会导致调度端与执行端理解不一致）
  - Loki 新增 `compactor` 段（`retention_enabled: true` / `retention_delete_delay: 2h` / `delete_request_store: s3`）+ `limits_config.retention_period: 120h` + `max_query_lookback: 120h`
  - Loki `reject_old_samples_max_age` 168h → 120h（仅一致性对齐，非保留期）
  - Alloy `stage.drop.older_than` 168h → 120h（仅一致性优化，`stage.drop` 本就不删数据）
  - MinIO `loki-chunks` ILM **7d → 10d**（必须**先于** Loki 改动执行：官方要求 lifecycle 长于 retention_period，且该桶**未开 versioning**，误配不可逆）
- 验证：Loki `/config` 运行时读出 `retention_enabled: true` / `retention_period: 5d` / `delete_request_store: s3`；compactor 首个周期实际遍历 `index_20622/20623/20624` 并写入 retention marker（`fake` + `self-monitoring` 两租户均处理）；Prometheus `/status/flags` 确认 `storage.tsdb.retention.time: 5d`；Tempo `/ready` 200 且日志 `retention provider started`；所有受影响 Pod 0 重启
- **⚠️ 遗留**：Tempo 因无 trace 数据（见 P0-2），`block_retention: 120h` 的**实际删除行为仍未被观察**，仅验证了配置被正确加载；MinIO 两桶均未开 versioning，存储层误配不可逆
- 完整报告（含三层删除机制图、12 个配置点对照、踩坑记录、回滚顺序）：`/root/retention-unification-5d.md`
- 备份：`/root/retention-unify-backup-20260930-151325/`

### 🟠 P1 — 告警噪音 / 监控盲区

**3. ✅ 已修复 — 16 个 down target，全部 connection refused**
- 原现象：kube-proxy ×6、kube-controller-manager ×3、kube-scheduler ×3、kube-etcd ×3、coredns ×1
- 原影响：`TargetDown` 持续 firing（噪音），同时这些组件**处于监控盲区**（不是"没问题"，是"没数据"）
- 修复动作：控制面组件 metrics 端点已在 **`0.0.0.0`** 开放（`--bind-address` / `--listen-metrics-urls`）
- ✅ 验证结果：**92 up / 0 down**，端口 `ss -tln` 确认为 `*:port` 绑定、跨节点直连 `/metrics` 返回 200 真实内容、series 数与节点数吻合 → **真修复，非删配置绕过**
- 另新增覆盖 2 个此前未纳管的 cert-manager 组件（`cert-manager-cainjector` / `cert-manager-webhook`）
- 详见 [3.2](#32-m--prometheus--kube-state-metrics--node-exporter)

**4. ✅ 已修复 — firing 告警 4 条（含 etcd critical 2 条）**
- 原现象：`etcd/etcdMembersDown` (warning)、`etcd/etcdInsufficientMembers` (**critical**)、`TargetDown`、`KubePodNotReady` 等
- 修复动作：随 #3 的 metrics 端点开放自动恢复，无需单独处理
- ✅ 验证结果：etcd 全部 11 条规则 **inactive**；**Alertmanager 活跃告警 12 → 2 条**；Prometheus firing 仅剩 `Watchdog`（心跳规则，恒 firing 属正常设计）
- **结论**：etcd 告警**确系误判**——三副本一直健康，仅因 metrics 未暴露而误报。初版报告的推断得到验证

**5. AlertmanagerConfig 一个都没用，所有告警单出口**
- 现象：38 个 PrometheusRule，但 0 个 AlertmanagerConfig，route 只有一个 `n8n-webhook`
- 影响：无法按 severity/namespace/团队分流；`inhibit_rules` 只能做抑制不能做路由
- 修复：引入 AlertmanagerConfig，为 critical 配独立 receiver（电话/短信），warning 走 n8n

**6. `repeat_interval: 12h` 过长**
- 影响：持续性故障在 12 小时内不会二次通知
- 修复：降到 1~2h

### 🟡 P2 — 稳定性 / 一致性

**7. ✅ 已修复 — CoreDNS 1/2 副本 ImagePullBackOff（2d13h，重试 822 次）**
```
dial tcp 74.125.204.82:443: i/o timeout
https://europe-west2-docker.pkg.dev/v2/k8s-artifacts-prod/images/coredns/coredns/manifests/v1.11.1
```
- 原影响：集群 DNS 只有 1 个副本可用，**无冗余**；那个副本一旦挂掉集群级 DNS 瘫痪
- ✅ 验证结果：故障副本已被替换，新副本 `coredns-7bf7bd7987-55xxh`（4h44m 前启动，10.244.241.103，master01），两副本 target 均 up，**DNS 冗余已恢复**
- 原建议（保留备查）：配置镜像仓库镜像源（国内环境需要），或手动 `crictl pull` 后重新打 tag
- **⚠ 建议跟进**：`DNSConfigForming` 事件曾刷了 15402 次（节点 resolv.conf 超过 3 个 nameserver 被截断为 `223.5.5.5 119.29.29.29 223.5.5.5`）。该问题与镜像拉取无关，**可能仍未解决**，属独立的 DNS 配置问题

**8. 2 天前（2026-09-27 13:54~13:56）全集群 Pod 集体重启**
- 证据：几乎所有 Pod 的 "last restart" 都是 `2d19h ago`；节点 Condition 的 LastTransitionTime 集中在 `Sun 27 Sep 13:54~13:56`
- 同时所有主机服务（zabbix-server/agent2/java-gateway、alertmanager、mysqld_exporter）的 "Active since" 也都是 `Sun 2026-09-27 13:54:27`
- 判断：**这是一次整机/集群级重启事件**，不是各组件独立故障
- 遗留：重启数偏高者需复查 —— argocd-repo-server **175**、kafka my-cluster-entity-operator **121**、loki-read **77**、ceph-csi-provisioner **145**、loki-backend/chunks-cache/results-cache 各 **24**

**9. Loki 无结构化元数据（bloom 关闭）**
- `bloom_build.enabled: false` / `bloom_gateway.enabled: false` / `pattern_ingester.enabled: false`
- 影响：`|= "error"`、`| json | level="error"` 这类查询全量扫描，日志量上来后查询延迟不可控
- 修复：按需开启 bloom 或 pattern_ingester

**10. Loki replication_factor: 1，无冗余**
- 写入路径上 loki-write 挂掉，WAL 内未 ship 的数据会丢
- 修复：如需高可用，`replication_factor: 3` + ring 配置

**11. Prometheus 高基数隐患**
- `namespace=default` 单标签贡献 115,743 series（占总量 55%）；default ns 有个 `netshoot-debug` 调试 Pod 常驻
- retention 仅 5d，head 已有 20.8 万 series、406k chunks
- 修复：清理 default ns 的调试 Pod（`netshoot-debug`、`qtempo3-*`、`dnsq`、`ptmp` 等一次性任务遗留），考虑加 relabel drop

### 🟡 P3 — 架构一致性

**12. 存在两套互不连通的 Alertmanager**
- 集群内 `alertmanager-prometheus-alertmanager-0`（k8s，v0.32.0，走 n8n webhook）
- 主机 `alertmanager.service`（systemd，:9093，独立配置）
- 同理还有两套 node_exporter（集群 DaemonSet 6 个 + 主机 1 个 :9100）、两套 cadvisor
- 主机那套**没有接入任何 Grafana**，属野生暴露端口
- 修复：明确取舍，废弃主机侧那套

**13. Zabbix 5 节点 agent 全部失联**
- 现象：444 hosts / 17,900 items 入库，但 10.0.0.120/121/122/123/124 的 10050 全部 refused
- 影响：Zabbix 目前只能监控本机
- 修复：确认 agent 是被卸载还是被防火墙阻断；如需主机监控，优先考虑统一到 Prometheus + node-exporter，减少一套系统

**14. Alertmanager 未启用 cluster 模式**
- `{"peers":[],"status":"disabled"}`，单副本 = 单点
- 修复：如需 HA，配 `--cluster.listen-address` 并加副本

**15. S3 凭据明文写在 ConfigMap（两套账号）**
- Loki（ConfigMap `loki`）：`access_key_id: <redacted-access-key>` / `secret_access_key: <redacted>`
- Tempo（ConfigMap `tempo3-config`）：`access_key: <redacted>` / `secret_key: <redacted>`
- 二者指向同一 MinIO（10.0.0.31:7480）但**账号隔离**：Loki 账号只能看到 3 个 `loki-*` bucket，Tempo 账号只能看到 `tempo-traces`
- 风险：明文可读；且无法轮换（改 ConfigMap 会触发滚动更新）
- 修复：挪到 Secret，`valueFrom.secretKeyRef` 引用；同时启用 MinIO 服务端加密与版本控制

### 5.4 ✅ 已修复 — 16 个 down target（第四轮新增）

**修复前后对比**：

| 项 | 修复前 | 修复后 |
|---|---|---|
| target 健康 | 74 up / **16 down**（共 90） | **92 up / 0 down** |
| Prometheus firing | 4 条 | **1 条**（仅 `Watchdog` 心跳规则） |
| Alertmanager 活跃告警 | 12 条 | **2 条** |
| `etcdMembersDown` | firing (warning) | **inactive** |
| `etcdInsufficientMembers` | firing (**critical**) | **inactive** |
| `TargetDown` | firing | **inactive** |
| `KubePodNotReady` | firing | **inactive** |
| CoreDNS 副本 | 1/2（另一个 ImagePullBackOff） | **2/2 Running** |

**逐类明细**：

| job | 原 down | 现 up | 开放端口 |
|---|---|---|---|
| kube-proxy | 6/6 | **6/6** | 10249 |
| kube-controller-manager | 3/3 | **3/3** | 10257 |
| kube-scheduler | 3/3 | **3/3** | 10259 |
| kube-etcd | 3/3 | **3/3** | 2381 |
| coredns | 1/2 | **2/2** | 9153 |
| cert-manager-cainjector | 未纳管 | **1/1** | 新增覆盖 |
| cert-manager-webhook | 未纳管 | **1/1** | 新增覆盖 |

**验证方法与证据**（三重交叉验证，确认非绕过）：

1. **节点侧监听状态** — 确认绑定 `0.0.0.0` 而非 `127.0.0.1`
   ```bash
   ss -tln | grep -E '10249|10257|10259|2381'
   # 10.0.0.120:10249 LISTEN *:10249   ← * = 0.0.0.0
   # 10.0.0.120:10257 LISTEN *:10257
   # 10.0.0.120:10259 LISTEN *:10259
   # 10.0.0.120:2381  LISTEN *:2381
   ```
2. **跨节点直连拉取真实内容** — 排除"端口开着但返回空/报错"
   ```bash
   printf 'GET /metrics HTTP/1.0\r\nHost: x\r\n\r\n' | timeout 6 bash -c 'exec 3<>/dev/tcp/10.0.0.120/10249; cat <&3'
   # HTTP/1.0 200 OK
   # Content-Type: text/plain; version=0.0.4
   # Process-Start-Time-Unix: 1790733161
   # # HELP aggregator_discovery_aggregation_count_total ...
   ```
3. **Prometheus 侧 series 数量校验** — 与节点数吻合
   ```bash
   up{job="kube-proxy"}              → 6 series
   up{job="kube-etcd"}               → 3 series
   up{job="kube-scheduler"}          → 3 series
   up{job="kube-controller-manager"} → 3 series
   up{job="coredns"}                 → 2 series
   ```
   抓取耗时 7–26ms，`lastScrape` 时间戳均为最新。

**为何强调"非绕过"**：监控盲区有两种"消失"方式——**真修复**（组件暴露端点、数据可见）或**绕过**（删掉 ServiceMonitor/ServiceMonitorSelector，让 target 被 drop）。后者会让 `TargetDown` 告警消失，但监控覆盖率同步下降。**本次是前者**：target 数量不降反升（90 → 92），端口实测开放，series 数量与节点数一一对应，数据真实可查。

**CoreDNS 详情**：
```
coredns-7bf7bd7987-4d7ts   1/1 Running  2d18h   10.244.59.213   master02  (原副本)
coredns-7bf7bd7987-55xxh   1/1 Running  4h44m  10.244.241.103  master01  (新副本)
```
`process_start_time_seconds{job="coredns"}` 证实新副本为 4h44m 前启动（真拉起新 Pod，非复活旧 Pod）。**DNS 冗余恢复**。

**遗留跟进**：`DNSConfigForming` 事件累计 15402 次 —— 节点 `/etc/resolv.conf` 的 nameserver 超过 3 个被 kubelet 截断（`223.5.5.5 119.29.29.29 223.5.5.5`）。此问题**与镜像拉取失败无关**，是独立的 DNS 配置问题，可能仍存在。

### 5.7 磁盘占用实测（第三轮新增）

**测量方法**：
- 本地 PVC：Loki 容器无 shell，改用临时 Pod 挂载 PVC 实测 `du -sh` + `df -h`（RWO 卷需 `nodeName` 指定到占用节点同侧）；Prometheus/Grafana/Alertmanager 直接 `kubectl exec`（有 shell）
- 对象存储：AWS CLI 直连 MinIO S3 API（`--endpoint-url http://10.0.0.31:7480`），两套凭据分别统计各自可见的 bucket

#### 汇总

| 项目 | 组件 | 实际占用 | 存储位置 | 配额 | 使用率 |
|---|---|---|---|---|---|
| **指标** | Prometheus | **3.8 GiB** | NFS PVC（worker02） | 100 GiB | 3.8% |
| | Alertmanager | 12 KiB | NFS PVC | 20 GiB | ~0% |
| | Grafana | 53.4 MiB | NFS PVC | 10 GiB | 0.5% |
| | **小计** | **≈ 3.86 GiB** | | 130 GiB | 3.0% |
| **日志** | Loki chunks（对象存储） | **245 MiB** | S3 `loki-chunks`（7,418 对象） | — | — |
| | Loki WAL（ingester 未 ship） | 9.5 MiB | Ceph RBD PVC | 10 GiB | 0.09% |
| | Loki tsdb-shipper-active | 804 KiB | Ceph RBD PVC | 10 GiB | 0.008% |
| | Loki backend 缓存 | 232 KiB | Ceph RBD PVC | 10 GiB | 0.002% |
| | `loki-admin` / `loki-ruler` | 0 B | S3 | — | 空 |
| | **小计** | **≈ 256 MiB** | | 20 GiB | **1.2%** |
| **链路** | Tempo 对象存储 | **393 KiB** | S3 `tempo-traces`（16 对象） | — | — |
| | Tempo 本地卷 | **0 B** | emptyDir（无持久化） | — | — |
| | **小计** | **≈ 0.4 MiB** | | — | — |

**比例：指标 93.7% : 日志 6.2% : 追踪 0.1%　｜　总计约 4.1 GiB**

#### 逐项说明

**① Prometheus — 绝对大头，但增长可控**
```
/prometheus          3.8G
  ├─ wal             450.5M   ← 未压缩的写前日志
  └─ TSDB blocks     每个约 280M × N
df: 93.9G 总量 / 24.7G 已用 / 64.4G 可用 (28%)
```
按 `max-block-duration: 12h` + `retention: 5d` 推算：每天 2 个 block → **约 560 MiB/天**，5 天约 2.8 GiB，与实测 3.8 GiB（含 WAL）吻合。**100 GiB 配额用不到 5%，无容量风险**。主要推手是 apiserver/etcd 的 histogram 指标（前三大高基数指标贡献 4.5 万 series）。

**② Loki — 真正在写，但量小**
S3 `loki-chunks` 7,418 个对象 / 245 MiB，按 `fake/<stream-hash>/` 分片（前 8 个 stream 各 51-79 个对象）→ 租户 `fake` 下 stream 数不少，说明 Alloy 采集在正常写入，只是量级小。两个 Ceph RBD PVC 几乎为空（合计 10.5 MiB），符合"ingester 只留 WAL、ship 后即清"的预期 —— **数据确实都落到了 S3**。

**③ Tempo — 空转的直接证据**
`tempo-traces` bucket 16 个对象 / 393 KiB，内容为 `tempo_cluster_seed.json`（215 B）和 `work.json`（3.4 KiB）这类**元数据**，**零个 trace block**。配合 Grafana 查询 `tagNames: []`、全部组件 emptyDir，三方证据一致：**从未有真实 trace 流入**。详见 [5.2](#52--p0--追踪链路完全空转)。

**④ NFS 后端有 20.9 GiB「看不见」的占用（需留意）**
`df` 显示 NFS 卷 24.7G 已用，但三个可观测性 PVC 的 `du` 合计仅 3.86 GiB。差值 ~20.9 GiB 可能来自：
- 同挂该 NFS 导出的其他 PVC（cicd 6 个、cnpg-system 4 个、kafka 1 个等）
- NFS 快照 / 已删除文件残留
- 非本集群使用者

→ 建议在 NFS 服务端查 `du` 定位，否则这块账算不清。

**⑤ 容量预测（按当前速率）**

| 项目 | 当前 | 日增速 | 30 天后 | 现有配额 | 结论 |
|---|---|---|---|---|---|
| Prometheus | 3.8 GiB | ~560 MiB | ~20 GiB | 100 GiB | 充裕（5d 滚动，实际稳定在 3-4 GiB） |
| Loki | 245 MiB | ~245 MiB* | ~7.5 GiB | MinIO（无显式配额） | 需关注 MinIO 整盘容量 |
| Tempo | 393 KiB | 0（空转） | 取决于接入 | MinIO | 接入后需重新评估 |

\* 日增速按当前存量 / 约 1 天（Alloy 39h 前上线）粗估，实际速率需观察更长时间。

**⑥ 结论：磁盘不是当前瓶颈**
所有 PVC 使用率 < 5%，无扩容压力。**优先级应放在数据接入质量（16 个 down target、Tempo 空转）而非容量规划上。**

---

## 六、CRUD/配置速查

### 各组件访问入口
```bash
# Grafana (ClusterIP, 无外部入口)
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
# → http://localhost:3000
# 四个数据源均已原生 provisioning：
#   prometheus(默认) / alertmanager / Loki(dfi90c2a1osn4c) / Tempo(afia1p4xshn9cf)
# 数据源定义在 ConfigMap prometheus-grafana-datasource，修改后 sidecar 自动重载
kubectl -n monitoring edit cm prometheus-grafana-datasource

# 若 UI 手工删过数据源导致 provisioning 冲突（uid already exists），修复流程：
G=prometheus-grafana-fb7445bf9-4knb8
U=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-user}'|base64 -d)
PW=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}'|base64 -d)
kubectl exec -n monitoring $G -c grafana -- sh -c "curl -s -X DELETE -H 'Authorization: Basic $(printf "%s:%s" "$U" "$PW"|base64 -w0)' http://localhost:3000/api/datasources/uid/<uid>"
kubectl exec -n monitoring $G -c grafana -- sh -c "curl -s -X POST    -H 'Authorization: Basic $(printf "%s:%s" "$U" "$PW"|base64 -w0)' http://localhost:3000/api/admin/provisioning/datasources/reload"

# Prometheus
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[]|select(.health!="up")|{job:.labels.job,err:.lastError}'
curl -s localhost:9090/api/v1/rules | jq '.data.groups[].rules[]|select(.state!="inactive")|{name,state,labels}'

# Loki（必须带租户头）
kubectl -n logging port-forward svc/loki-gateway 3100:80
curl -s -H "X-Scope-OrgID: fake" "localhost:3100/loki/api/v1/labels"
curl -s -H "X-Scope-OrgID: fake" "localhost:3100/loki/api/v1/query?query={namespace=\"monitoring\"}"

# Tempo
kubectl -n logging port-forward svc/tempo3-query-frontend 3200:3200
curl -s localhost:3200/api/search/tags

# Zabbix (本机)
# web: http://<m01>/zabbix  (nginx :80 反代)  账号走 DB
```

### 常用排查命令
```bash
# 哪些 Pod 不是 Running
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 重启次数 Top 20
kubectl get pods -A -o json | jq -r '.items[]|. as $p|.status.containerStatuses[]?|select(.restartCount>5)|"\(.restartCount)\t\($p.metadata.namespace)/\($p.metadata.name)"' | sort -rn | head -20

# 节点资源 / 压力
kubectl top nodes
kubectl describe nodes | grep -A8 Conditions

# 日志采集链路验证（Alloy 是否在 tail）
kubectl logs -n logging alloy-c8c5b -c alloy --tail=50 | grep "start tailing"

# 追踪链路消费情况
kubectl exec -n logging tempo3-metrics-generator-6* -- wget -qO- localhost:3200/metrics | grep tempo_metrics_generator
```

---

## 七、附录：采集到的事实清单

**集群**：6 节点全 Ready，v1.29.8，256d。CPU 最高 m01 18%，内存最高 master02 72%。无 MemoryPressure / DiskPressure / PIDPressure。

**监控 Pod**：12 个（Prometheus STS、Alertmanager STS、Operator、Grafana、KSM、node-exporter×6）。全部 Running 147d+，重启均在 2d19h 前（对应 9-27 重启事件）。

**日志/追踪 Pod**：27 个（Alloy×6、Loki 6 组件+3 canary、Tempo 11 组件）。全部 Running。Tempo 系为 43h 新建，Alloy 为 39h（从 Promtail 迁移）。

**告警统计**：✅ Alertmanager 活跃告警 **2 条**（原 12 条）；Prometheus firing 规则 **1 条**（仅 `Watchdog` 心跳，恒 firing 属正常）；pending 0 条。etcd 全部 11 条规则 inactive。

**Target 健康**：✅ **92 up / 0 down**（原 74/16），dropped targets 821（正常）。控制面组件 metrics 端点已在 `0.0.0.0` 开放并经三重验证（详见 5.4）。**CoreDNS 2/2 Running**，DNS 冗余已恢复。

**规则库**：50 个 group / 281 条 rule，来源含 kube-prometheus 默认套件（apiserver / scheduler / kubelet / etcd / node-exporter / k8s 混合 workload / container 资源）、cluster-wide-alerts、app-monitoring-alerts（自研，50m 前更新）。

**存储**：所有 18 个 PVC 均为 Bound，分布于 cicd(6)、cnpg-system(4)、logging(2)、monitoring(3)、kafka(1)、n8n(1)、default(1)。Loki/Tempo 后端指向同一 MinIO 10.0.0.31:7480，但用两套独立凭据（账号隔离）。Tempo 的 live-store / block-builder **无 PVC，全是 emptyDir**。

**磁盘占用实测**（详见 5.7）：Prometheus 3.8 GiB（NFS 100Gi 配额）+ Grafana 53.4 MiB + Alertmanager 12 KiB；Loki S3 `loki-chunks` 245 MiB（7,418 对象）+ Ceph RBD 本地合计 10.5 MiB；Tempo S3 `tempo-traces` 393 KiB（16 对象，**无 trace block**）+ 本地 0 B。**总计约 4.1 GiB，所有 PVC 使用率 < 5%。**

**Grafana 数据源（本轮已治理）**：4 个数据源全部由 ConfigMap `prometheus-grafana-datasource` 原生 provisioning 管理 —— `prometheus`(默认) / `alertmanager` / `Loki`(uid `dfi90c2a1osn4c`) / `Tempo`(uid `afia1p4xshn9cf`)，uid 沿用原 UI 创建值以兼容 46 个存量仪表盘。版本 12.4.3，存储 PVC 53.4 MiB。

**服务网格**（3 个控制面节点，etcd 3 副本均 Running）：kube-apiserver ×3、etcd ×3、calico-node ×6、coredns ×2（1 个挂）。

**CRD 清单**：`alertmanagerconfigs`(v1alpha1)、`alertmanagers`(v1)、`podlogs`(grafana.com)、`podmonitors`(v1)、`probes`(v1)、`prometheusagents`(v1alpha1)、`prometheuses`(v1)、`prometheusrules`(v1)、`scrapeconfigs`(v1alpha1)、`servicemonitors`(v1)、`thanosrulers`(v1)。

---

*报告基于 2026-09-30 的实时采集（含第四轮增量：target 全量修复验证）。*
*复查时的两个硬性限制：① Loki 需带 `X-Scope-OrgID: fake` 头访问，否则 401；② Tempo 当前无任何 trace 数据且无持久化，查询必然为空，配置里的 `block_retention: 48h` 暂时无法验证。*
*建议后续排查：`DNSConfigForming` 事件累计 15402 次（节点 resolv.conf nameserver 被截断），属独立于已修复项的遗留 DNS 配置问题。*

---

## 八、修复记录（2026-11-04）：Loki chunks-cache 周期性 OOMKill

**原始症状**：`logging/loki-chunks-cache-0` memcached 容器 OOMKilled（exit 137），`PodOOMKilled` 告警长期 firing；用户反馈"又报了"。实测上一轮运行 2026-10-19 → 2026-11-03 共 **15 天** 后被 OOM，重启后周期重演。

**根因**：启动参数 `-m 8192`（8 GiB 缓存目标）与容器 `limits.memory=1Gi` 自相矛盾；节点 worker02 内存 64%（6.3 Gi）并不紧张。values 只设了 `resources.limits.memory`，未设 `chunksCache.allocatedMemory`，chart 默认 8192 直接进了参数。同源隐患：`loki-results-cache` 为 `-m 1024 / limit 512Mi`。

**已修复**：
1. `loki-chunks-cache` → `-m 700`（limit 1Gi）；`loki-results-cache` → `-m 350`（limit 512Mi），改由 memcached LRU 淘汰，不再可能 OOM。容器内 `limit_maxbytes` 实测 734003200 / 367001600。
2. Loki 无中断：`loki_distributor_lines_received_total` ≈31 行/s、9.3 KB/s，read/write/backend/canary `up=1`。
3. `PodOOMKilled` 规则改为"最近 15 分钟内发生"才告警（原 `last_terminated_reason==1` 永不恢复），改后 `state=inactive`。
4. 新增 `MemcachedLimitAboveContainerLimit`（`memcached_limit_maxbytes_bytes > 容器 memory limit`）防复发，`health=ok`。
5. Helm 回滚风险已留覆盖文件：`/root/loki-values-cache-fix.yaml`（升级时必须带 `-f`）。

详见 `/root/loki-cache-oom-fix-20261104.md`。
