# Ceph 集群监控接入执行报告

- **执行时间**：2026-10-01 22:40 ~ 23:30 (CST)
- **Ceph 集群**：`ceph-01`(10.0.0.31) / `ceph-02`(10.0.0.41) / `ceph-03`(10.0.0.51)，ID `594e535e-d82c-11f0-afa7-bc24112b746f`
- **接入前状态**：`HEALTH_OK`，但**集群层零监控**（Prometheus 无任何 ceph target）
- **执行结果**：✅ **已接入，100 个指标族 / 19 条告警规则 / target up**

---

## 一、集群现状

```
cluster:
  id:     594e535e-d82c-11f0-afa7-bc24112b746f
  health: HEALTH_OK

services:
  mon: 3 daemons, quorum ceph-02, ceph-03, ceph-01 (age 2d)
  mgr: ceph-01.egryfx(active, since 2d), standbys: ceph-02.wzbtbx
  mds: 1/1 daemons up, 2 standby
  osd: 6 osds: 6 up (since 2d), 6 in (since 9M)
  rgw: 2 daemons active (2 hosts, 1 zones)

data:
  volumes: 1/1 healthy
  pools:   15 pools, 465 pgs
  objects: 11.96k objects, 5.2 GiB
  usage:   18 GiB used, 162 GiB / 180 GiB avail
  pgs:     465 active+clean
```

**关键关联**：`ceph-csi-rbd-sc`（StorageClass）正由该集群提供 RBD 存储，Loki 的对象存储也指向其上的 MinIO（`10.0.0.31:7480`）。**这是 K8s 生产存储底座，此前完全没有集群层监控。**

---

## 二、接入前的关键判断（决定了整个方案）

### 2.1 不需要部署 ceph_exporter

`ceph_exporter` 未安装，但 **Ceph mgr 内置 prometheus 模块已经暴露 9283 端口**：

```
$ curl -s http://10.0.0.31:9283/metrics | head
# HELP ceph_health_status Cluster health status
# TYPE ceph_health_status untyped
```

实测输出 **1287 行 / 101 个 ceph 指标族**，涵盖 OSD、Pool、PG、Mon 全维度。**直接用内置端点，不引入新的部署和升级负担。**

### 2.2 三台节点只有一台能采 —— 主动只采 active mgr

| 节点 | 角色 | 9283 实测 |
|---|---|---|
| 10.0.0.31 (ceph-01) | **active mgr** | http 200，**1084 行 ceph 指标** |
| 10.0.0.41 (ceph-02) | standby mgr | http 200，**0 行**（无 prometheus 模块输出） |
| 10.0.0.51 (ceph-03) | mon/osd | **网络不通**（从 K8s 与 m01 均无法连接） |

**原因**：Ceph 的 prometheus 模块**只在 active mgr 上运行**。采三台只会得到 1 份数据 + 2 个噪音 target（其中 1 个还会 down）。

**决策**：只采 `10.0.0.31`，并用 `CephMGRMetricsMissing` 告警覆盖"active mgr 切换导致监控失明"这一风险。

### 2.3 从 K8S 网络可达性已验证

通过临时 Pod 实测（与实际采集路径一致）：
```
10.0.0.31  http=200  ceph指标行=1084   ✅
10.0.0.41  http=200  ceph指标行=0      (standby，符合预期)
10.0.0.51  http=000  ceph指标行=0      (网络不通)
```
**Prometheus Pod 可以直连 10.0.0.31:9283**，无需额外网络策略。

---

## 三、实施过程

### 3.1 方案选型：踩了两次坑，最终用 ScrapeConfig

#### 第一次尝试：ServiceMonitor + headless Service + 手动 Endpoints ❌

**失败现象**：
- ServiceMonitor `ceph-mgr` 创建成功，标签 `release=prometheus` 与 selector 均正确
- 但 Prometheus 生成的 **38 个 job 里没有它**
- 反倒发现 `10.0.0.31:9283` 出现在另外 **8 个 ServiceMonitor 的 droppedTargets** 中（grafana / alertmanager / node-exporter / kube-state-metrics / prometheus 等）

**根因**：ServiceMonitor 依赖 `role=endpoints` 的 K8s 服务发现。**手动创建的 Endpoints 不被 prometheus-operator v0.90.1 纳入生成结果**，而 headless Service 的 Endpoints 又被本命名空间下所有 ServiceMonitor 各自声明了一遍——它们端口不匹配（都不叫 `metrics:9283`），于是全部被 relabel 丢弃，我那一份反而没生成。

#### 第二次尝试：ScrapeConfig 字段名错误 ❌

```yaml
spec:
  static_configs: ...      # ❌ 应为 staticConfigs
  metrics_path: /metrics   # ❌ 应为 metricsPath
  scrape_interval: 30s     # ❌ 应为 scrapeInterval
  metric_relabel_configs: # ❌ 应为 metricRelabelings
```
CRD 校验直接拒绝：
```
ScrapeConfig in version "v1alpha1" cannot be handled: strict decoding error:
  unknown field "spec.metric_relabel_configs", unknown field "spec.metrics_path", ...
```

查 `kubectl get crd scrapeconfigs.monitoring.coreos.com` 拿到实际 schema，确认该 Operator 版本使用**驼峰命名**。

#### 最终方案：ScrapeConfig ✅

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: ceph-mgr
  namespace: monitoring
  labels: {release: prometheus}
spec:
  jobName: ceph-mgr
  staticConfigs:
    - targets: ["10.0.0.31:9283"]
      labels: {cluster: ceph-prod, mgr_node: ceph-01, ceph_role: mgr}
  scrapeInterval: 30s
  scrapeTimeout: 10s
  metricsPath: /metrics
  scheme: http
  metricRelabelings:
    - sourceLabels: [__name__]
      regex: ".*_idle_seconds"
      action: drop
```

**验证**（等待 Operator 完整 reconcile 后）：
```
生成 job: scrapeConfig/monitoring/ceph-mgr     ✅
target:   ceph-mgr | 10.0.0.31:9283 | up       ✅
指标族:   100
```

**顺带清理**：把第一次尝试残留的 ServiceMonitor / Service / Endpoints 全部删除（Operator 侧有配置缓存，删除后需等待一轮 reconcile 才彻底消失）。

### 3.2 告警规则：发现并修正了两批问题

**第一批 — 引用了不存在的指标**（v1，18 条）

首版规则写完后逐条实跑，虽然**无解析错误**，但抽查底层数据发现 5 个指标在集群中根本不存在：

| 误用指标 | 实际存在的替代 |
|---|---|
| `ceph_pool_bytes_total` | `ceph_pool_max_avail` / `ceph_pool_percent_used` |
| `ceph_cluster_total_bytes_raw` | `ceph_cluster_total_used_bytes` |
| `ceph_recovery_bytes` | （删除该规则） |
| `ceph_osd_disk_ops` | （删除该规则） |
| `ceph_csi_operations_errors_total` | （删除该规则，CSI 侧无 ceph_ 指标） |

> 这正是前几轮《告警有效性分析报告》中说的「静默失效」——语法正确、health=ok，但永远抓不到数据。**若只看 apply 是否成功就上线，会再制造一批死规则。**

**第二批 — f-string 拼接 bug**（v2）

修复第一批时用了 f-string 拼接 selector：
```python
C = '{cluster="ceph-prod"'
f'absent(ceph_health_status{C})'    # C 已含 }，实际生成 {...})
```
产生 `{cluster="ceph-prod")` 这类非法表达式。**CRD 校验拦下了 apply，未污染集群**（这是 Kubernetes schema 校验的价值）。

v3 改用普通字符串 `%` 拼接，并增加生成后自检：
```python
if e.count("{") != e.count("}"):  raise SystemExit(...)
```

### 3.3 上线前逐条实跑验证

19 条规则全部实跑，**0 条错误**，且抽查确认是真实健康数据导致的正常沉默：

| 指标 | 实际值 | 说明 |
|---|---|---|
| `ceph_health_status` | 0 | HEALTH_OK |
| `ceph_mon_quorum_status` | 1,1,1 | 3 个 mon 全部在 quorum |
| `up{job="ceph-mgr"}` | 1 | target 健康 |
| `max(ceph_pool_percent_used)` | 0.076% | 池使用率极低 |
| `ceph_cluster_total_used_bytes` / `total_bytes` | 19.4G / 193.2G | 集群使用率 10% |
| `avg(ceph_osd_commit_latency_ms)` | 0.83ms | 远低于 50ms 阈值 |
| `ceph_osd_up` | 6 个全 1 | 6 OSD 在线 |

---

## 四、最终告警覆盖（19 条 / 5 个 group）

### ceph.health（4 条）
| 规则 | 级别 | 触发条件 |
|---|---|---|
| `CephClusterUnhealthy` | critical | `ceph_health_status != 0` |
| `CephClusterHealthUnknown` | critical | 健康指标缺失（监控失明） |
| `CephMGRMetricsMissing` | critical | mgr 端点不可达（**覆盖 mgr 主备切换风险**） |
| `CephMGRUnreachable` | critical | `up{job="ceph-mgr"} == 0` |

### ceph.mon（2 条）
| 规则 | 级别 | 触发条件 |
|---|---|---|
| `CephMonQuorumLost` | critical | 在 quorum 的 mon < 2 |
| `CephMonNotInQuorum` | warning | mon 总数 != 3 |

### ceph.osd（4 条）
| 规则 | 级别 | 触发条件 |
|---|---|---|
| `CephOSDDown` | critical | 存在 `ceph_osd_up == 0` |
| `CephOSDOutOfCluster` | critical | 存在 `ceph_osd_in == 0`（被踢出集群） |
| `CephTooFewOSDs` | critical | 在线 OSD < 3（失去冗余） |
| `CephOSDHighCommitLatency` | warning | 平均提交延迟 > 50ms |

### ceph.pg（4 条）
| 规则 | 级别 | 触发条件 |
|---|---|---|
| `CephPGIncomplete` | critical | 存在 incomplete PG（数据不完整） |
| `CephPGDegraded` | warning | 存在 degraded PG |
| `CephPGStale` | warning | 存在 stale PG |
| `CephPGScrubbingError` | warning | PG scrub 报错 |

### ceph.capacity（5 条）
| 规则 | 级别 | 触发条件 |
|---|---|---|
| `CephPoolNearFull` | warning | 池使用率 > 85% |
| `CephPoolCriticallyFull` | critical | 池使用率 > 95% |
| `CephClusterNearFull` | warning | 集群使用率 > 85% |
| `CephClusterCriticallyFull` | critical | 集群使用率 > 95% |
| `CephPoolNoSpace` | critical | 池可用空间为 0 |

---

## 五、执行结果

### 监控栈终态
```
规则库:  61 groups / 314 rules / health 全部 ok  (原 56/295)
targets: 99 up / 0 down                          (原 98)
采集job: 44 个
集群:    6/6 Ready，无非 Running Pod
```

### Ceph 采集结果
```
job:      ceph-mgr
target:   10.0.0.31:9283  →  up
指标族:   100 个 ceph_* 指标
标签:     cluster=ceph-prod, mgr_node=ceph-01, ceph_role=mgr
```

### 变更清单
| 对象 | 类型 | 变更 |
|---|---|---|
| `monitoring/ceph-mgr` | **ScrapeConfig** | **新建**，采集 active mgr :9283 |
| `monitoring/ceph-cluster-alerts` | **PrometheusRule** | **新建**，5 groups / 19 rules |

> 首次尝试的 `ceph-mgr` ServiceMonitor + Service + Endpoints **已全部清理**。

### 降基数措施
```yaml
metricRelabelings:
  - regex: ".*_idle_seconds"        # 丢弃 idle 计数器
  - regex: "rgw_.*_(objects|bytes)_(per|shard)"   # 丢弃 RGW 对象级高基数指标
```

---

## 六、遗留风险与建议

### 🔴 高优先级

**1. mgr 主备切换会导致监控失明（架构固有限制）**

Ceph 的 prometheus 模块**只在 active mgr 上运行**，这是设计使然。当前只采 `10.0.0.31`：

- 若 `ceph-01` 故障导致 `ceph-02` 升主 → 9283 无输出 → `CephMGRMetricsMissing` 会告警（监控本身发现问题）
- 但**修复需要人工介入**：把新 mgr IP 加入 ScrapeConfig 的 `staticConfigs`

**建议改进**（未实施，需先评估）：
- 改用 `dnsSDConfigs` + Ceph 提供的 mgr DNS 记录（若有）
- 或部署 `ceph_exporter` 主动轮询 mon（不依赖 mgr）
- 或在 K8s 侧跑一个 DaemonSet 做 mgr 主动发现 + 代理

**2. ceph-03（10.0.0.51）网络不通**

从 m01 和 K8S 网络均无法连接 9283（ping 通但端口不通）。该节点承担 mon + osd 角色，**其指标完全不可见**。建议排查防火墙规则。

**3. 变更未纳入 GitOps**

2 个新对象均为手动 apply。集群有 argocd（258d），建议纳入。

### 🟡 中优先级

| # | 项目 | 说明 |
|---|---|---|
| 4 | RGW 指标覆盖有限 | 2 个 RGW daemon 的对象级指标基数极高，已 drop；如需 RGW 专项监控应单独设计 |
| 5 | MDS 指标未专门覆盖 | 当前 1 active + 2 standby，MDS 故障影响 CephFS（本集群主要用 RBD，影响有限） |
| 6 | CephFS 卷未使用 | `ceph -s` 显示 `volumes: 1/1 healthy`，但 K8s StorageClass 只有 `ceph-rbd-sc`（RBD），CephFS 暂未接入 |
| 7 | 容量告警阈值偏保守 | 集群当前使用率 10%，85%/95% 阈值短期内不会触发。可按实际增长预期调整 |

### ✅ 已确认健康（接入后首轮）

所有 19 条规则均为"条件不满足"状态，即**真实健康**而非失效：
- HEALTH_OK，3 mon 全部在 quorum
- 6 OSD 全部 up + in
- 465 PG 全部 active+clean（无 degraded/stale/incomplete）
- 集群使用率 10%（19.4G / 193.2G）
- OSD 提交延迟 0.83ms

---

## 七、命令速查

```bash
# Ceph 集群健康（直查）
sshpass -p '<redacted-password>' ssh root@10.0.0.31 "ceph -s"

# mgr prometheus 端点
curl -s http://10.0.0.31:9283/metrics | grep '^ceph_' | wc -l     # 应 ~1084

# Prometheus 侧验证 target
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | \
  jq -r '.data.activeTargets[]|select(.labels.job=="ceph-mgr")'

# Ceph 关键指标
Q() { kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- "http://localhost:9090/api/v1/query?query=$1" | jq -r '.data.result[].value[1]'; }
Q ceph_health_status          # 0 = HEALTH_OK
Q 'count(ceph_osd_up==1)'     # 应 6
Q 'ceph_cluster_total_used_bytes'
Q 'max(ceph_pool_percent_used)'

# Ceph 告警状态
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' | \
  jq -r '.data.groups[]|select(.name|startswith("ceph."))|.rules[]|"\(.name): \(.health) \(.state)"'

# 验证规则引用的指标是否真实存在（避免静默失效）
kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]|select(startswith("ceph_"))'

# 回滚
kubectl delete scrapeconfig ceph-mgr -n monitoring
kubectl delete prometheusrule ceph-cluster-alerts -n monitoring
```

---

## 八、凭证使用说明

用户提供的 Ceph 凭据（`root` / `<redacted-password>`）**仅用于本次排查阶段的 `ceph -s` 查询**，未写入任何配置文件：

```yaml
# ScrapeConfig 中不含任何 secret
spec:
  staticConfigs:
    - targets: ["10.0.0.31:9283"]     # mgr prometheus 端点无需认证
```

**建议**：`root/<redacted>` 这类弱口令用于存储集群的管理账号风险较高（可通过 SSH 获得全集群控制权）。建议：
1. 改用 Ceph 官方 admin 认证（`cephadm shell` + ceph keyring）
2. 若必须用密码，改为强口令并限制 SSH 来源
3. 监控接入本身不需要这些凭证——**不要把它写进 ScrapeConfig 或 ConfigMap**

---

*本次接入使 Ceph 存储底座首次纳入可观测性体系。规则库 314 条全部 health=ok，99 targets 全 up，19 条 Ceph 规则均处于真实健康状态。主要遗留是 mgr 主备切换导致的监控失明（已由告警覆盖但需人工修复配置）。*
