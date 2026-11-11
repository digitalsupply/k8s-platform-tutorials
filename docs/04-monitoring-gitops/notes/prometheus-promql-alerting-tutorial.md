# Prometheus 表达式 + 告警实战教程：从入门到进阶

> **本教程所有表达式、告警规则、数值均来自本集群（`rocky9-prod`）的真实数据**，不是编造的例子。
> 数据快照时间：**2026-10-06 13:52 (CST)**，Prometheus 服务端时间 `2026-10-06T05:52:52Z`。
> 快照时集群状态：**125 个抓取目标全部健康、10 条告警处于 firing 状态** —— 正好可以拿来做活教材。
> 所有查询都可以直接复制到本集群的 Prometheus UI（`http://10.111.41.17:9090/graph`）里跑出同样结果。

---

## 目录

| 章节 | 内容 | 阶段 |
|---|---|---|
| [0](#0-本集群监控栈速览) | 本集群监控栈速览 + 实验环境搭建 | 准备 |
| [1](#1-入门篇指标标签与第一条表达式) | 指标模型、标签、第一条 PromQL | ⭐ 入门 |
| [2](#2-基础篇counter-的三个黄金函数) | rate / increase / counter reset | ⭐⭐ 基础 |
| [3](#3-聚合与向量匹配) | sum by、and/or/unless、group_left | ⭐⭐ 基础 |
| [4](#4-进阶函数) | histogram_quantile、predict_linear、offset、changes | ⭐⭐⭐ 进阶 |
| [5](#5-录制规则recording-rules) | 录制规则：把贵的查询变便宜 | ⭐⭐⭐ 进阶 |
| [6](#6-告警规则解剖一条告警的完整结构) | alert / for / labels / annotations / 模板 | ⭐⭐ 告警 |
| [7](#7-本集群-235-条告警全景与分层设计) | 235 条告警的全景图与分层方法论 | ⭐⭐ 告警 |
| [8](#8-实战一从零写一条告警六步法) | 从 0 写一条告警：六步法 | 🔨 实战 |
| [9](#9-实战二正在-firing-的-10-条告警复盘) | 当前 10 条真实告警的复盘与排查 | 🔨 实战 |
| [10](#10-实战三误报与哑告警治理) | 误报根因分析（真实案例 3 个） | 🔨 实战 |
| [11](#11-测试与校验promtool) | promtool check / test，附实测通过的用例 | 🔨 实战 |
| [12](#12-alertmanager-通知与降噪) | 分组、抑制、静默、按 severity 路由 | 🔨 实战 |
| [13](#13-进阶选修slo--多窗口-burn-rate-告警) | SLO 错误预算燃烧告警 | 🎓 选修 |
| [14](#14-常见坑与调优清单) | 20 个常见坑 + 上线检查清单 | 📋 清单 |
| [附录 A~D](#附录-a常用-promql-速查本集群可直接跑) | 速查表 / 235 条告警清单 / 命令 / 术语 | 📚 参考 |

---

## 0. 本集群监控栈速览

### 0.1 组件与版本

| 组件 | 版本 / 说明 | 位置 |
|---|---|---|
| 监控栈 | `kube-prometheus-stack-83.7.0`（Helm chart） | namespace `monitoring` |
| Prometheus | **v3.11.2**，单副本，WAL 压缩开启 | `prometheus-prometheus-prometheus-0` |
| Prometheus Operator | 通过 `PrometheusRule` CRD 管理规则 | `prometheus-operator` |
| Alertmanager | 邮件（QQ 企业邮 SMTP）通知 | `prometheus-alertmanager` (10.111.199.90:9093) |
| kube-state-metrics | K8s 对象状态（Pod/Node/Deployment…） | `prometheus-kube-state-metrics` |
| node-exporter | 主机指标（CPU/内存/磁盘/网络） | 6 个 DaemonSet Pod |
| cAdvisor | 容器指标，由 kubelet 内置暴露 | `job="kubelet" metrics_path="/metrics/cadvisor"` |
| Grafana | 看板 | `prometheus-grafana` (10.101.49.32) |

**关键参数（来自 `Prometheus` CR）：**

```yaml
scrapeInterval: 30s          # 抓取周期
evaluationInterval: 30s      # 规则求值周期
retention: 15d               # 数据保留 15 天
retentionSize: 25GiB         # 或 25GiB，先到先触发
storage: 100Gi PVC (storageClassName: nfs-sc)
externalLabels:
  cluster: rocky9-prod
  env: production
```

> ⚠️ **`scrapeInterval: 30s` 是后面一切经验法则的基准**：range selector 的窗口至少要覆盖 4 个抓取点（≥ 2 分钟），推荐 5 分钟。

### 0.2 规则资产盘点（本教程的"教材来源"）

```text
PrometheusRule CR 数量      ：41 个
其中自研（本集群自己写的）   ：6 个 CR / 86 条告警
其中上游 kube-prometheus-stack：35 个 CR / 149 条告警
告警规则（alerting rules）   ：235 条
录制规则（recording rules）  ：94 条
规则合计                     ：329 条
```

severity 分布与 `for` 持续时间分布（235 条告警统计）：

```text
severity : warning 145 | critical 81 | info 7 | none 2
for      : 15m 71 | 5m 69 | 10m 43 | 1h 15 | 1m 7 | 2m 7 | 30m 4
           | 20m 3 | 4h 2 | 3h 1 | 0s 1 | 未设置 10
```

### 0.3 打通实验环境（三种方式任选）

**方式一：本机可直连 ClusterIP（本教程用的方式）**

```bash
P=http://10.111.41.17:9090          # svc/prometheus-prometheus
curl -s $P/-/ready                   # -> Prometheus Server is Ready.
```

**方式二：端口转发（任意机器可用）**

```bash
kubectl port-forward -n monitoring svc/prometheus-prometheus 9090:9090 &
kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093 &
```

**方式三：纯 UI 操作** —— 浏览器打开 `http://10.111.41.17:9090/graph`，Graph 页输入表达式，点 **Execute**。

### 0.4 本教程的"三板斧"：用 API 做查询

后面每一章的"实测输出"都是用这条命令拿到的，你可以照抄：

```bash
# 1) 执行单条 PromQL，格式化输出
q() {
  curl -s --max-time 10 "http://10.111.41.17:9090/api/v1/query" \
    --data-urlencode "query=$1" |
  python3 -c '
import json,sys
d=json.load(sys.stdin)
if d["status"]!="success":
    print("ERROR:", d.get("error")); raise SystemExit(1)
r=d["data"]["result"]
print(f"series={len(r)}")
for x in r[:8]:
    print("  ", dict(x["metric"]), "->", x["value"][1])
'
}

# 2) 查某条告警现在到底是什么状态
curl -s "http://10.111.41.17:9090/api/v1/alerts" | python3 -m json.tool | less

# 3) 导出本集群全部告警规则（后面写规则、做审计都靠它）
kubectl get prometheusrule -A -o json > /tmp/pr.json
```

---

# 第一阶段 · 入门

## 1. 入门篇：指标、标签与第一条表达式

### 1.1 Prometheus 的数据模型：一条时间序列 = 指标名 + 一组标签

```text
node_cpu_seconds_total{mode="idle", cpu="0", instance="10.0.0.61:9100", job="node-exporter"}
└────── 指标名 ─────┘ └──────────────────── 标签（labels）─────────────────────┘
```

本集群四大指标类型及其真实来源：

| 类型 | 特征 | 本集群真实例子 | 用来回答 |
|---|---|---|---|
| **Counter** | 只增不减（可被重置） | `node_cpu_seconds_total`<br>`kube_pod_container_status_restarts_total`<br>`traefik_service_requests_total` | "增长了多快" |
| **Gauge** | 可增可减的瞬时值 | `node_memory_MemAvailable_bytes`<br>`kubelet_volume_stats_available_bytes`<br>`ceph_health_status` | "现在是多少" |
| **Histogram** | `_bucket` + `_sum` + `_count`，分桶 | `apiserver_request_sli_duration_seconds_bucket`<br>`etcd_disk_wal_fsync_duration_seconds_bucket` | "分位数/延迟分布" |
| **Summary** | 客户端算好的分位数 | 部分 exporter 提供 `quantile="0.9"` | 同上（较少用） |

> **为什么要区分？** Counter 必须用 `rate()`/`increase()` 做差分才有意义；Gauge 直接比较即可；Histogram 必须用 `histogram_quantile()` 配合 `_bucket`。用错函数是新手最常见的第一个 bug。

### 1.2 第一条表达式：目标健康度 `up`

`up` 是 Prometheus 自己生成的指标：**1 = 抓取成功，0 = 抓取失败**。它是整个监控体系的地基。

```promql
up
```

```promql
count(up)          # 一共有多少个抓取目标
```

**实测输出：**

```text
count(up)  -> 125        # 125 个目标
sum(up == 0) -> 空       # 0 个失败目标，全部健康
```

按 job 拆开看（了解"我的指标从哪来"）：

```promql
count by (job) (up)
```

```text
kubelet 18 | apiserver 3 | alloy 6 | node-exporter 6 | kube-etcd 3
| kube-proxy 6 | kube-controller-manager 3 | kube-scheduler 3
| argocd/argocd 5 | coredns 2 | kube-state-metrics 1 | ceph-mgr 1
| traefik/traefik 1 | cert-manager 3 | ... 合计 125
```

### 1.3 选择器：给指标加过滤条件

```promql
# 精确匹配
up{job="node-exporter"}

# 正则匹配（注意必须写锚定 ^...$，否则是"包含"语义）
up{job=~"loki-write|loki-backend|loki-read"}

# 反向匹配
node_cpu_seconds_total{mode!="idle"}

# 不等于任何一个
node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}

# 匹配空标签 / 非空标签
node_filesystem_avail_bytes{fstype!="",mountpoint!=""}
```

> 🔸 **本集群真实踩坑点**：`job` 标签在这里有两种风格 —— 有些是裸名（`alloy`、`live-store`），有些带命名空间前缀（`logging/loki-write`、`kafka/strimzi-cluster-operator`）。第 10 章有一条告警**正是因为没注意这个差异而长期误报**。

### 1.4 四类运算符

```promql
# 比较运算符 -> 过滤（返回布尔标记的序列，真值才保留）
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.10

# 算术运算符
node_memory_MemAvailable_bytes / node_filesystem_size_bytes * 100

# 逻辑/集合运算符（针对"向量集合"，不是布尔值）：and / or / unless
up{job="node-exporter"} and on (instance) node_filesystem_size_bytes
```

**动手：算一下 6 个节点的 CPU 使用率**

```promql
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

**实测输出（本集群 6 节点真实值）：**

```text
10.0.0.120:9100 -> 0.1392   (13.92%)
10.0.0.121:9100 -> 0.1576   (15.76%)
10.0.0.122:9100 -> 0.1784   (17.84%)   ← 最高
10.0.0.123:9100 -> 0.1015   (10.15%)
10.0.0.124:9100 -> 0.0700   ( 7.00%)   ← 最低
10.0.0.61:9100  -> 0.1672   (16.72%)
```

### 1.5 本章练习（答案在下一章开头）

1. 查出本集群所有节点的内存使用率（已用 / 总量）。
2. 查出当前 `namespace="logging"` 下有哪些 job 在被抓取。
3. 查出所有处于 `CrashLoopBackOff` 等待状态的容器。
4. 查出本集群 6 个节点的名字（提示：`kube_node_info`）。
5. 查出当前所有 firing 状态的告警按 severity 分组的条数。

<details><summary>点开查看答案</summary>

```promql
# 1
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
# 实测：6 节点 22.7% ~ 77.8%（10.0.0.61 最高 77.83%，10.0.0.124 最低 22.71%）

# 2
count by (job) (up{namespace="logging"})
# 实测：alloy 6、logging/loki-write 1、logging/loki-backend 1、logging/loki-read 1、
#       logging/loki-canary 3、live-store 3、block-builder 3、distributor 1、querier 1 ...

# 3
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0

# 4
count by (node) (kube_node_info)
# 实测：m01 / master01 / master02 / worker01 / worker02 / worker03 共 6 个

# 5
count by (severity) (ALERTS{alertstate="firing"} == 1)
# 实测：warning 8 | critical 1 | none 1（合计 10 条，2026-10-06 快照）
```

</details>

---

## 2. 基础篇：counter 的三个黄金函数

### 2.1 `rate` / `irate` / `increase` 怎么选

| 函数 | 输出含义 | 适用场景 | 本集群用法 |
|---|---|---|---|
| `rate(v[t])` | **平均每秒增量**（对窗口做线性回归，能跨 counter 重置） | 长期趋势、QPS、CPU 使用率 | `rate(container_cpu_usage_seconds_total[5m])` |
| `irate(v[t])` | 窗口内**最后一次**两点斜率，瞬时值 | 抖动大、需要灵敏的场景 | 录制规则 `...sum_irate` |
| `increase(v[t])` | 窗口内**总增量**（可为小数，跨重置） | "这 1 小时重启了几次" | `increase(kube_pod_container_status_restarts_total[1h])` |
| `delta(v[t])` | 首尾差值，**不做重置处理** | Gauge 的两点差 | 少用 |
| `idelta` / `resets` | 最后两点差 / 窗口内重置次数 | 排查 counter 异常 | 调试用 |

**核心心法：**

> Counter 的绝对值本身**几乎没有意义**，有意义的是"单位时间内的变化量"。
> 本集群 `kube_pod_container_status_restarts_total` 对 `speaker-7lsdm` 是 `64` —— 这个 64 不能直接告诉我们"它还在坏"，必须配合时间窗口看增量。

### 2.2 range selector 的窗口选择（与 scrapeInterval 强相关）

本集群 `scrapeInterval = 30s`，经验法则：

```text
窗口长度 >= 4 × scrapeInterval   （至少 4 个样本点，否则 rate 抖动/失真）
推荐        >= 10 × scrapeInterval （20 个点，曲线平滑）
本集群推荐   [2m] 起步，常用 [5m]，趋势分析用 [30m]/[1h]
```

**真实对照**（同一个指标，不同窗口）：

```promql
rate(node_cpu_seconds_total{mode="idle"}[1m])   # 2 个点：曲线锯齿严重
rate(node_cpu_seconds_total{mode="idle"}[5m])   # 10 个点：本集群告警采用
rate(node_cpu_seconds_total{mode="idle"}[15m])  # 30 个点：适合看板
```

### 2.3 案例：本集群的两条"节点 CPU"告警

**告警 A（自研，`cluster-wide-alerts`）：**

```promql
# alert: NodeHighCPU   for: 5m   severity: warning
1 - avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85
```

**告警 B（上游，`prometheus-node-exporter`）：**

```promql
# alert: NodeCPUHighUsage   for: 15m   severity: warning
sum without(mode) (avg without (cpu) (rate(node_cpu_seconds_total{job="node-exporter", mode!~"idle|iowait"}[2m]))) * 100 > 90
```

两者差异（这正是"进阶"的分水岭）：

| 维度 | A：自研 NodeHighCPU | B：上游 NodeCPUHighUsage |
|---|---|---|
| 阈值 | 85% | 90% |
| 窗口 | 5m | 2m |
| `for` | 5m（最短持续 5 分钟） | 15m |
| 计算口径 | 只排除 `idle`（**含 iowait**，会偏高） | 排除 `idle\|iowait`（更符合"业务占用"直觉） |
| 聚合维度 | `by (node)` —— **依赖 `node` 标签存在** | `without (mode/cpu)` —— 不依赖额外标签 |
| 触发速度 | 快（5m+5m ≈ 10 分钟） | 慢（2m+15m ≈ 17 分钟） |

> 🔸 **注意 A 的潜在缺陷**：`avg by(node)` 要求序列上有 `node` 标签。node-exporter 通过 ServiceMonitor 抓取时通常**没有 `node` 标签**（只有 `instance`）。此时 `by(node)` 会把所有节点聚合成一条空标签序列，导致**要么全部一起告警、要么算错**。本集群 node-exporter 序列实测标签是 `instance/job/namespace/pod/...`，**没有 `node`**：

```promql
node_cpu_seconds_total{mode="idle"}
# 实测标签：{cpu="0", instance="10.0.0.121:9100", job="node-exporter",
#            namespace="monitoring", pod="prometheus-prometheus-node-exporter-5lq5k", ...}
```

> 👉 这就是第 14 章"**先在 Graph 里看一眼标签，再写 `by (...)`**"这条纪律的由来。
> 安全写法（本集群可用，已实测）：`1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85`。

### 2.4 案例：`increase` 与"正在发生 vs 历史遗留"

```promql
# 过去 1 小时重启次数（"正在发生"）
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="metallb-system"}[1h]))
```

```text
实测：speaker-7lsdm -> 0    speaker-xz49v -> 0    speaker-qmwd4 -> 0
      speaker-zv64c -> 0    speaker-62nbr -> 0    speaker-vtcl8  -> 0
                                                    ← 1 小时内一次都没重启
```

```promql
# 累计重启次数（"历史遗留"）
topk(5, max by (namespace, pod) (kube_pod_container_status_restarts_total))
```

```text
实测：metallb-system/speaker-7lsdm  -> 64
      metallb-system/speaker-zv64c  -> 64
      metallb-system/speaker-qmwd4  -> 62
      metallb-system/speaker-xz49v  -> 36
      kafka/...entity-operator-...  ->  7
```

`kubectl` 交叉验证（完全一致，说明指标可信）：

```bash
$ kubectl get pods -n metallb-system
speaker-7lsdm   1/1   Running   64   262d     # 重启 64 次，Pod 已存在 262 天
speaker-qmwd4   1/1   Running   62   262d
speaker-xz49v   1/1   Running   36   220d
speaker-62nbr   1/1   Running   0    262d
speaker-vtcl8   1/1   Running   0    262d
```

> 📌 **结论**：`increase[1h]=0` 但累计 64 —— 这是"**历史累积型**"问题，不是"正在崩溃"。
> 本集群同时存在这两类告警：`PodCrashLooping`（`increase(...[5m]) > 2`，抓"正在发生"）与 `KubePodHighRestartCount`（累计 `>10`，抓"历史遗留"）。**两条互补，缺一条就会有盲区** —— 这是告警设计的重要范式，第 9 章详细复盘。

### 2.5 counter reset（重置）怎么处理

Container/Pod 被重建后 counter 归零。`rate()`/`increase()` 会自动把重置当作正常延续（把前一段补回来）：

```promql
# Prometheus 内部等价逻辑：遇到 v[i] < v[i-1] 就认为发生 reset，累加上一段的末值
increase(node_cpu_seconds_total[5m])
```

**不需要手动处理 reset**，但要记住两条推论：

1. **`increase()` 跨 reset 时会"补一段"**，如果窗口内 reset 太多，数值会偏大（重启风暴时 `increase[1h]` 可能虚高）。
2. **Gauge 没有 reset 概念**，对 Gauge 用 `rate()` 是错的（比如 `node_memory_MemAvailable_bytes`）。

### 2.6 本章练习

```promql
# 1. 计算各节点 1 分钟 load1 相对 CPU 核数的饱和度（本集群上游告警 NodeSystemSaturation 的思路）
node_load1 / count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})

# 2. 过去 24 小时内每个 Pod 的重启增量，找出还在抖的
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[24h])) > 0

# 3. 各容器的内存工作集（排除缓存干扰）
container_memory_working_set_bytes{image!=""}
```

---

## 3. 聚合与向量匹配

### 3.1 聚合：`sum / avg / min / max / count / topk / quantile`

```promql
sum by (namespace) (kube_pod_info)          # 按命名空间数 Pod
count(up)                                   # 总目标数
topk(5, kube_pod_container_status_restarts_total)   # Top 5
min(ceph_pool_max_avail{cluster="ceph-prod"})       # 最少可用空间的池
```

`by` 与 `without` 的区别：

```promql
sum by (namespace, pod) (X)     # 只保留这两个标签，其余丢弃
sum without (id, job, node) (X) # 保留除这些之外的所有标签
```

> 🔸 什么时候用 `without`？当你**不关心也不确定**还剩哪些无关标签时（上游规则几乎都用 `without`，因为 cAdvisor 序列标签多达 15+ 个，`by` 容易漏写导致意外聚合）。

### 3.2 `and` / `or` / `unless`：集合运算（不是布尔逻辑）

这是最容易被误解的一节。**PromQL 里的 `and/or/unless` 作用于"左边的结果集"，右边只是一个条件集**：

```promql
A and B       # 保留 A 中"标签能在 B 中匹配上"的序列（值仍取 A 的）
A or B        # A 的序列 ∪ B 的序列（标签完全匹配才算同一条）
A unless B    # 保留 A 中"在 B 里找不到匹配"的序列
```

匹配规则：**默认要求左右两侧标签"完全相同"**，需要忽略某些标签时用 `on()` / `ignoring()`。

### 3.3 案例一：`absent()` —— 监控"监控本身"（本集群真实误报源）

本集群规则 `LokiIngestStalled`（`coverage-gap-alerts`，severity: **critical**）：

```promql
absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"})
  or
sum(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"} == 0) > 0
for: 5m
```

**语义拆解：**

| 片段 | 作用 |
|---|---|
| `absent(选择器)` | 如果选择器**一条序列都匹配不到**，返回 `{}` → `1`；只要有一条，返回**空** |
| `or ... sum(... == 0) > 0` | 第二段：如果匹配到了但值为 0（抓取失败），也告警 |
| 两段用 `or` 拼接 | 覆盖"指标根本不存在"和"指标存在但为 0"两种故障 |

**实测（快照时刻）：**

```promql
absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"})
-> series=1  {"namespace":"logging"} -> 1        # 返回 1，即"没匹配到" → 告警成立！
```

**但 Loki 其实活得好好的：**

```bash
$ kubectl get pods -n logging | grep loki
loki-backend-0    2/2   Running   0   15h
loki-read-...     2/2   Running   1   15h
loki-write-0      1/1   Running   0   15h
```

**根因**：真实的 job 标签是 `logging/loki-write`（带命名空间前缀），而正则写的是 `loki-write`（裸名），**完全匹配不上** → `absent()` 判定"指标不存在" → 持续误报 critical。

这是本教程最有价值的真实案例，第 10 章给出完整修复方案。

> 🔸 **`absent()` 使用铁律**：
> 1. 用它之前，**必须先手动跑一遍选择器**，确认正常时返回什么；
> 2. `absent()` 只能覆盖"指标消失"，覆盖不了"指标存在但为 0"，所以要像上面一样配 `or`；
> 3. 正则必须写 `^loki-write$` 风格的完整匹配意图，或者干脆写 `job=~".*loki-write.*"`。

### 3.4 案例二：`on()` / `group_left()` —— 跨指标"补标签"

上游规则 `KubePodNotReady`（简化后）：

```promql
sum by (namespace, pod) (
  max by (namespace, pod) (kube_pod_status_phase{phase=~"Pending|Unknown"})
  * on (namespace, pod) group_left(owner_kind)
  topk by (namespace, pod) (1, max by (namespace, pod, owner_kind) (kube_pod_owner{owner_kind!="Job"}))
) > 0
```

**读法（从内到外）：**

```text
1) 左边：找出处于 Pending/Unknown 的 Pod（有 namespace/pod 标签）
2) 右边：每个 Pod 的 owner_kind（Deployment/StatefulSet/DaemonSet）
3) * on (namespace, pod)   —— 只按这两个标签做匹配
   group_left(owner_kind)  —— 多对一：右边一条匹配左边多条，并把 owner_kind "带过来"
4) sum by (namespace, pod) —— 汇总
```

**`group_left` / `group_right` 记忆法：**

```text
  多  <---(group_left)--   1     "左边多、右边一"：把右边的标签复制给左边
  1   --(group_right)-->   多     "左边一、右边多"：把左边的标签复制给右边
  没写 group_x          要求严格一对一（多对一、一对多都会报错）
```

**本集群另一例（节点归属，来自录制规则 `prometheus-node.rules`）：**

```promql
node:node_num_cpu:sum =
  count by (cluster, node) (
    node_cpu_seconds_total{mode="idle", job="node-exporter"}
    * on (cluster, namespace, pod) group_left(node)
    topk by (cluster, namespace, pod) (1, max by (cluster, node, namespace, pod) (
      label_replace(kube_pod_info, "pod", "$1", "pod", "(.+)")
    ))
  )
```

> 👉 node-exporter 是 DaemonSet，`kube_pod_info` 有 `node` 标签，通过 `group_left(node)` 把"这个 Pod 跑在哪个节点"灌给主机指标 —— **这正是 2.3 节缺少 `node` 标签的标准解法**。

### 3.5 案例三：`unless` 做排除法

上游规则 `KubePersistentVolumeFillingUp`：

```promql
(
  kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.03
)
and kubelet_volume_stats_used_bytes > 0
unless on (cluster, namespace, persistentvolumeclaim)
  kube_persistentvolumeclaim_access_mode{access_mode="ReadOnlyMany"} == 1
unless on (cluster, namespace, persistentvolumeclaim)
  kube_persistentvolumeclaim_labels{label_excluded_from_alerts="true"} == 1
```

```text
and   ... used_bytes > 0        → 排除"还没开始用"的空 PV（刚建的 PVC 不该告警）
unless ... ReadOnlyMany         → 排除只读 PVC（不会写满）
unless ... label_excluded_from_alerts="true"  → 给运维留的"人工豁免开关"！
```

> 💡 **`unless` + 豁免标签**是生产环境必备技巧：临时不想让某个 PVC 告警，打个 label 即可，不用改规则：
> ```bash
> kubectl label pvc my-pvc -n my-ns label_excluded_from_alerts=true
> ```

本集群实测 PV 使用率（阈值 3%，当前安全）：

```promql
100 - kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes * 100
# 实测最高 37.28%（nfs-sc 上的 PVC），最低 0.17%
```

### 3.6 本章练习

```promql
# 1. 找出「Running 但不在 Ready」的 Pod
kube_pod_status_phase{phase="Running"} == 1
  and on (namespace, pod) kube_pod_status_ready{condition="true"} == 0

# 2. 统计每个 namespace 的 critical 告警条数
count by (namespace) (ALERTS{severity="critical"} == 1)

# 3. 找出「声明副本数 > 可用副本数」的 Deployment
kube_deployment_spec_replicas > kube_deployment_status_replicas_available

# 4. 用 unless 排除掉 monitoring 命名空间（豁免监控栈自身）
ALERTS == 1 unless on (namespace) ALERTS{namespace="monitoring"} == 1
```

---

## 4. 进阶函数

### 4.1 `histogram_quantile` —— 延迟分位数

**原理**：Histogram 暴露 `..._bucket{le="0.1"}` 这样的累计桶，`histogram_quantile(q, sum by (le) (rate(..._bucket[5m])))` 在桶内做线性插值。

**本集群实测：API Server GET 请求 p99 延迟**

```promql
histogram_quantile(0.99,
  sum by (le) (rate(apiserver_request_sli_duration_seconds_bucket{verb="GET"}[5m])))
```

```text
-> 0.04956 秒（约 49.6ms），即 p99 = 49.6ms，非常健康
```

**三条铁律（不遵守就会算出错误的分位数）：**

```promql
# ✅ 必须按 le 聚合
histogram_quantile(0.99, sum by (le) (rate(x_bucket[5m])))

# ✅ 想分维度看，把维度加在 by 后面，le 必须保留
histogram_quantile(0.99, sum by (le, resource) (rate(x_bucket[5m])))

# ❌ 忘记 by (le) -> 把所有桶混在一起 -> 结果永远是 +Inf 附近的垃圾值
histogram_quantile(0.99, rate(x_bucket[5m]))
```

**本集群用它的两条真实告警：**

```promql
# 1) etcd WAL fsync 慢（prometheus-etcd，两档：for 5m > 0.5s / for 10m > 1s）
histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=~".*etcd.*"}[5m])) > 0.5

# 2) CPU 被限流的比例（prometheus-kubernetes-resources，for 15m）
sum without (...) (topk by (...) (1, increase(container_cpu_cfs_throttled_periods_total[5m])))
/
sum without (...) (topk by (...) (1, increase(container_cpu_cfs_periods_total[5m])))
> 0.25
```

### 4.2 `predict_linear` —— "照这个趋势，多久会爆"

对窗口内数据做线性回归，外推 `t` 秒后的值。**这是"提前预警"类告警的核心。**

**本集群案例一：etcd 数据库增长过快（`etcdExcessiveDatabaseGrowth`）**

```promql
predict_linear(etcd_mvcc_db_total_size_in_bytes[4h], 4*60*60)
  > etcd_server_quota_backend_bytes
for: 10m
```

实测当前 etcd db 大小（3 个成员）：

```text
10.0.0.61:2381  -> 104984576  (~100 MB)
10.0.0.120:2381 -> 105046016
10.0.0.121:2381 -> 105250816
# 默认 quota 8GB，距离告警还有很远；一旦 watch/写入暴涨，4 小时外推会立刻超限
```

**本集群案例二：磁盘 24 小时内会写满（`NodeFilesystemSpaceFillingUp`，上游，for 1h）**

```promql
(
  node_filesystem_avail_bytes{fstype!="",mountpoint!=""} / node_filesystem_size_bytes * 100 < 15
  and predict_linear(node_filesystem_avail_bytes[6h], 24*60*60) < 0
  and node_filesystem_readonly == 0
)
for: 1h
```

```text
三段条件缺一不可：
  ① 当前剩余 < 15%        —— 已经紧张
  ② 6 小时趋势外推 24h 后 < 0 —— 且正在持续增长
  ③ 不是只读挂载           —— 只读盘告警没意义
```

**实测本集群当前磁盘（安全）：**

```promql
100 - (node_filesystem_avail_bytes{fstype="ext4",mountpoint="/"} / node_filesystem_size_bytes * 100)
# 10.0.0.123 -> 65.74%   10.0.0.122 -> 65.70%   10.0.0.124 -> 56.27%
# 10.0.0.120 -> 44.23%   10.0.0.121 -> 41.81%   ← 均未超过 85% 阈值，无 NodeDiskPressure
```

> ⚠️ `predict_linear` **只在数据近似线性时准**。周期性任务（白天写满夜里清理）会误判 —— 这类告警必须配较长的 `for`（1h）+ 足够窗口（6h）。

### 4.3 `changes` / `deriv` —— 抓"抖动"

```promql
# 上游：网络接口频繁 up/down（for 2m）
changes(node_network_up{device!~"veth.+"}[2m]) > 2

# 上游：节点 Ready 状态 15 分钟内翻转超过 2 次（for 15m）
sum by (cluster, node) (changes(kube_node_status_condition{condition="Ready",status="true"}[15m])) > 2

# 上游：时间同步漂移方向（deriv = 瞬时导数）
deriv(node_timex_offset_seconds[5m]) >= 0
```

`changes()` 的用法是"**数一数窗口内值变化的次数**"，特别适合 flapping 检测。

本集群实测（当前稳定）：

```promql
sum(changes(kube_node_status_condition{condition="Ready",status="true"}[15m]))
-> 0     # 15 分钟内没有任何节点 Ready 状态翻转
```

### 4.4 `offset` —— 与历史同期比较

```promql
# 今天 vs 1 小时前：增量是否已经停下来
kube_pod_container_status_restarts_total{namespace="metallb-system"}
  - kube_pod_container_status_restarts_total{namespace="metallb-system"} offset 1h
```

**实测输出：**

```text
speaker-7lsdm -> 0     speaker-xz49v -> 0     speaker-qmwd4 -> 0
speaker-zv64c -> 0     speaker-62nbr -> 0     speaker-vtcl8  -> 0
# 全部为 0：过去 1 小时计数器没有增长 → 重启事件早已停止，属于历史遗留
```

**常用套路：**

```promql
# 环比昨天同一时刻（增长 30% 就告警）
sum(rate(http_requests_total[15m])) > 1.3 * sum(rate(http_requests_total[15m])) offset 1d

# 本周同比
sum(...) / sum(...) offset 1w
```

> ⚠️ `offset` 必须写在选择器之后：`metric{...}[5m] offset 1h`；且窗口从"当前时刻 - offset"往前推，**offset 窗口不能超出数据保留期（本集群 15 天）**。

### 4.5 `time()` 与日期函数 —— 绝对时间判断

本集群自研规则 `KubeVIPLeaderNotRenewing`（severity: **critical**）：

```promql
time() - kube_lease_renew_time{namespace="kube-system",lease="plndr-cp-lock"} > 90
for: 1m
```

```text
time()             -> Prometheus 服务端当前 Unix 时间戳
kube_lease_renew_time -> kube-state-metrics 暴露的 Lease 续约时间
差值 > 90 秒        -> leader 超过 90 秒没续约 → 控制面 VIP 可能已经脑裂
```

**其他时间函数：**

```promql
# 证书 14 天内过期（本集群 CertManagerCertificateExpiringSoon）
certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600

# 工作时间告警抑制思路：只在 9:00-18:00 触发
(hour() >= 9 and hour() < 18)

# Job 超过 1 小时没跑完（本集群 KubeJobNotCompleted）
time() - max by (namespace, job_name) (kube_job_status_start_time and kube_job_status_active == 1) > 3600
```

### 4.6 `label_replace` / `label_join` —— 打标签

```promql
# 从 pod 名里剥离 ReplicaSet hash，得到干净的 workload 名
label_replace(
  label_replace(kube_pod_owner{owner_kind="ReplicaSet"},
    "workload", "$1", "owner_name", "(.+)-[a-z0-9]+"),
  "workload", "$1", "workload", "(.+)")
```

> 💡 录制规则 `namespace_workload_pod:kube_pod_owner:relabel`（本集群 6 条变体）就是专门干这件事的 —— **把原始 K8s 标签清洗成人类可读的 workload 标签，供告警和看板复用**。

### 4.7 本章练习

```promql
# 1. 计算 coredns 查询延迟 p99（Histogram）
histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))

# 2. 预测 PV 还能撑多久（外推 7 天）
predict_linear(kubelet_volume_stats_available_bytes[6h], 7*24*3600) < 0

# 3. 节点接口 flapping 检测
changes(node_network_up{device!~"veth.+"}[10m]) > 3

# 4. CPU 使用率环比 1 小时前上升 50%
(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
  > 1.5 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) offset 1h)
```

---

# 第二阶段 · 告警基础

## 5. 录制规则（Recording Rules）

### 5.1 为什么需要它

有些表达式**又贵又复杂**（比如 `CPUThrottlingHigh` 那条 15 行的查询），如果：

- Grafana 看板每 30 秒刷一次 → 每次都重新算；
- 告警每 30 秒求值一次 → 每次都重新算；
- 3 个这样的面板 + 5 条这样的告警 → 同一个复杂计算被重复执行几十次。

**解法**：把复杂表达式的结果**预先算好存成新指标**，这就是录制规则。它的名字里带冒号，天然表达"这是算出来的"。

### 5.2 命名规范：`level:metric:operations`

```text
level        聚合的粒度：instance / cluster / namespace / node / job / 无(空)
metric       基础指标名
operations   做过的操作：sum / rate / avg / ratio / increase / total
冒号越多，抽象层次越高

本集群真实例子（94 条录制规则中的代表作）：
instance:node_cpu:rate:sum                     instance 级 CPU 速率求和
instance:node_memory_utilisation:ratio         instance 级内存使用率
cluster:node_cpu:ratio                         整集群 CPU 使用率（无 level 前缀的最高层）
namespace_cpu:kube_pod_container_resource_requests:sum   命名空间 CPU requests 总量
node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m
apiserver_request:burnrate5m                   API Server 5 分钟错误预算燃烧率
```

**实测（可直接跑）：**

```promql
cluster:node_cpu:ratio
# -> 0.1138015873015895   （全集群 CPU 平均使用率 11.38%）

instance:node_memory_utilisation:ratio
# -> 每个节点一条，本集群 0.22 ~ 0.78
```

### 5.3 录制规则的三种典型用法

**用法一：性能优化（最常见）**

```yaml
# prometheus-kube-prometheus-node-recording.rules
- record: instance:node_cpu:rate:sum
  expr: sum(rate(node_cpu_seconds_total{mode!="idle",mode!="iowait",mode!="steal"}[3m])) BY (instance)
```

**用法二：给告警提供"中间结果"（本集群最关键的用法）**

SLO 燃烧率告警 `KubeAPIErrorBudgetBurn` 的表达式是：

```promql
sum by (cluster) (apiserver_request:burnrate1h) > (14.40 * 0.01000)
  and on (cluster) sum by (cluster) (apiserver_request:burnrate5m) > (14.40 * 0.01000)
```

这里的 `apiserver_request:burnrate1h` / `burnrate5m` **本身就是录制规则**（`prometheus-kube-apiserver-burnrate.rules` 里定义了 5m/30m/1h/2h/6h/1d/3d 共 7 个窗口 × 读写两套 = 14 条）。**没有录制规则，这种多窗口告警根本写不出来**（见第 13 章）。

**用法三：统一口径，避免各处算得不一样**

```yaml
# prometheus-k8s.rules.container-resource
- record: namespace_cpu:kube_pod_container_resource_requests:sum
  expr: sum by (namespace, cluster) (
          sum by (namespace, pod, cluster) (
            max by (namespace, pod, container, cluster) (
              kube_pod_container_resource_requests{resource="cpu", job="kube-state-metrics"}
            )
          )
        )
```

> 这里连套三层 `by` 是有讲究的：**容器级去重 → Pod 级求和 → 命名空间求和**。
> 直接 `sum by (namespace)` 会把同一个 Pod 的多个容器重复计算。这种"去重细节"固化进录制规则后，下游告警（`KubeCPUOvercommit`）就不用再操心。

### 5.4 录制规则的放置与生效

本集群所有规则都放在 `PrometheusRule` CR 里，由 Operator 分发给 Prometheus：

```bash
kubectl get prometheusrule -n monitoring          # 41 个
kubectl get prometheusrule cluster-wide-alerts -n monitoring -o yaml
kubectl get prometheusrule -A -o json > /tmp/pr.json   # 全量导出
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-new-rules
  namespace: monitoring
  labels:
    release: prometheus          # ← 必须！Prometheus CR 的 ruleSelector 匹配这个 label
spec:
  groups:
    - name: my-app.rules
      interval: 30s              # 可选，覆盖全局求值周期
      rules:
        - record: namespace:my_app_requests:rate5m
          expr: sum by (namespace) (rate(my_app_requests_total[5m]))
        - alert: MyAppHighErrorRate
          expr: ...              # 直接引用上面的 record 名
          for: 5m
```

> ⚠️ **没有 `release: prometheus` 这个 label 的 PrometheusRule 不会被加载**（`ruleSelector.matchLabels: {release: prometheus}`）。这是"我写了规则怎么不生效"的第一嫌疑。

### 5.5 什么时候**不该**用录制规则

| 场景 | 建议 |
|---|---|
| 查询很轻（如 `up == 0`） | 直接写在 alert 里，少一层间接 |
| 指标基数极高、结果集巨大 | 录制规则会**常驻内存/存储**，先算基数 |
| 探索性查询、临时排查 | 不要建规则，用 Graph 即可 |
| 结果只需要存几天 | 注意录制规则同样占存储（retention 25GiB） |

---

## 6. 告警规则解剖：一条告警的完整结构

### 6.1 五要素

本集群自研规则 `NodeDiskPressure`（`cluster-wide-alerts`）是教科书式的完整示例：

```yaml
groups:
  - name: node-resource.rules          # 组名：模块-主题.rules
    rules:
      - alert: NodeDiskPressure        # ① 告警名：PascalCase，全局唯一可检索
        expr: |                        # ② 表达式：返回"非空即为真"的向量
          (node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes) < 0.15
        for: 5m                        # ③ 持续时间：条件连续成立 5 分钟才从 pending 转 firing
        labels:                        # ④ 标签：决定路由/分组/抑制/静默的依据
          severity: critical
        annotations:                   # ⑤ 注解：给人看的文本（不参与匹配）
          summary: "磁盘空间紧张: {{ $labels.instance }} {{ $labels.mountpoint }}"
```

**5 个字段的分工必须记牢：**

| 字段 | 给谁看 | 用途 |
|---|---|---|
| `expr` | Prometheus | 判断是否触发 |
| `for` | Prometheus | 防抖，过滤瞬时毛刺 |
| `labels` | Alertmanager | **路由、分组、抑制、静默全靠它** |
| `annotations` | 人（通知里显示） | 说明"发生了什么、怎么处理" |
| `alert` | 所有人 | 唯一标识 |

### 6.2 `for` 的语义：Inactive → Pending → Firing → Resolved

```text
t=0s     expr 首次返回真      → Inactive → Pending   （ALERTS{alertstate="pending"}=1）
t=0~5m   expr 持续为真        → 仍是 Pending          （还在"观察期"）
t=5m     expr 连续 5 分钟为真 → Pending → Firing     （ALERTS{alertstate="firing"}=1）→ 发通知
t=?      expr 变为空/假       → Firing → Resolved    （发"恢复"通知）
         expr 中途断了再真    → 计时器清零，重新 Pending！
```

**本集群实测当前 firing 的告警（`ALERTS` 指标）：**

```promql
count by (severity) (ALERTS{alertstate="firing"} == 1)
# -> warning 8 | critical 1 | none 1   （合计 10 条）
```

**如何看某条告警当前处于什么状态：**

```bash
curl -s "http://10.111.41.17:9090/api/v1/alerts" | python3 -m json.tool
# 返回 state: pending / firing，activeAt（开始时间），annotations（渲染后的文本）
```

> 🔸 **`for` 与 scrapeInterval/evaluationInterval 的关系（本集群都是 30s）：**
> `for: 5m` 实际需要 **至少 10 次连续求值为真**（5min ÷ 30s）。如果 `for` 小于 2 个求值周期，基本等于没设。
> **本集群统计**：71 条用 `15m`、69 条用 `5m`、43 条用 `10m`，这三档覆盖了 83% 的规则，是我们的默认档位。

### 6.3 annotations 模板语法

Prometheus 用 Go template 渲染 annotations，最常用的是这三个变量：

```yaml
annotations:
  summary: "磁盘空间紧张: {{ $labels.instance }} {{ $labels.mountpoint }}"
  description: "当前使用率 {{ $value | humanizePercentage }}，已持续 {{ $labels.instance }}"
  runbook_url: "https://runbooks.prometheus-operator.dev/runbooks/kubernetes/kubepodcrashlooping"
```

| 模板 | 含义 | 本集群真实用例 |
|---|---|---|
| `{{ $labels.xxx }}` | 取该告警实例的标签值 | `{{ $labels.namespace }}/{{ $labels.pod }}` |
| `{{ $value }}` | 表达式返回的数值 | `Pod 累计重启 {{ $value }} 次` |
| `{{ $value \| humanizePercentage }}` | 0.234 → `23.4%` | OtelDemo 错误率、CPUThrottlingHigh |
| `{{ $value \| humanizeDuration }}` | 95 → `1m 35s` | `KubeVIPLeaderNotRenewing` 停滞时长 |
| `{{ printf "%.2f" $value }}` | 精确保留 2 位小数 | `NodeCPUHighUsage`、磁盘百分比 |
| `{{ humanize $value }}` | 1234567 → `1.235 M` | 大字节数 |

**实测一条已渲染的告警（来自 `/api/v1/alerts`）：**

```json
{
  "state": "firing",
  "labels": {
    "alertname": "KubePodHighRestartCount",
    "namespace": "metallb-system",
    "pod": "speaker-7lsdm",
    "severity": "warning"
  },
  "annotations": {
    "summary": "Pod 累计重启 64 次: metallb-system/speaker-7lsdm",
    "description": "该 Pod 累计重启超过 10 次。现有 PodCrashLooping 规则用 rate() 只覆盖'正在发生的频繁重启'，本规则用累计值覆盖'已稳定但历史频繁崩溃'的盲区..."
  },
  "activeAt": "2026-09-30T02:11:00Z"
}
```

### 6.4 severity 分级约定（本集群现行标准）

| severity | 条数 | 含义 | `for` 惯例 | 通知策略建议 |
|---|---|---|---|---|
| `critical` | 81 | **服务已不可用 / 数据有风险**，需要立刻人工介入 | 1m ~ 10m（要快） | 电话 / 企业微信强提醒，7×24 |
| `warning` | 145 | **正在劣化或已超出阈值**，暂不影响可用性 | 5m ~ 15m | 即时消息，工作时间处理 |
| `info` | 7 | 提示性信息（证书快过期、配额将满） | 10m ~ 1h | 汇总日报 |
| `none` | 2 | 不通知（`Watchdog` 心跳、`InfoInhibitor`） | - | 仅用于管道自检 |

> 📌 **分级的唯一标准是"要不要把人叫醒"，不是"指标有多难看"。**
> 反例：`NodeDiskPressure` 用 `critical` 是对的（磁盘写满 = 服务雪崩），但 `CPUThrottlingHigh` 用 `warning` 更合适（只是变慢，没挂）。

### 6.5 Watchdog：告警管道的"心跳"

```promql
# prometheus-general.rules / general.rules
alert: Watchdog
expr: vector(1)          # 永远返回一条值为 1 的序列 → 永远 firing
labels: {severity: none}
annotations:
  description: "This is an alert meant to ensure that the entire alerting pipeline is functional..."
```

**设计意图**：如果哪天你在 Alertmanager 里**再也看不到 Watchdog**，说明 **Prometheus → Alertmanager 这条链路断了** —— 所有其他告警也发不出来了。

配套的还有 `InfoInhibitor`：

```promql
group by (namespace) (ALERTS{severity = "info"} == 1)
unless on (namespace)
group by (namespace) (ALERTS{alertname != "InfoInhibitor", severity =~ "warning|critical"} == 1)
```

> 语义：**某个 namespace 已经有 warning/critical 告警了，就把该 namespace 的 info 告警抑制掉** —— 别在火情现场发"证书 14 天后过期"的噪音。

---

## 7. 本集群 235 条告警全景与分层设计

### 7.1 资产总览

| 分类 | CR 数 | 告警数 | 说明 |
|---|---|---|---|
| **自研** | 6 | **86** | 本集群运维团队根据实际组件编写 |
| **上游自带** | 35 | **149** | kube-prometheus-stack 官方规则 |
| 合计 | 41 | **235** | 另有 94 条录制规则 |

### 7.2 分层模型（从硬件到业务，逐层负责）

```text
┌─────────────────────────────────────────────────────────────────┐
│ L6 观测栈自监控   prometheus / alertmanager / prometheus-operator│
│                    + Watchdog（管道心跳）                        │  ← 自己监控自己
├─────────────────────────────────────────────────────────────────┤
│ L5 业务应用       OtelDemo* / TraefikHigh5xxRate / Kafka / CNPG  │
│                    Knative / Tekton / CertManager               │
├─────────────────────────────────────────────────────────────────┤
│ L4 中间件与存储   ceph-cluster-alerts(19) / tempo3-alerts(20)    │
│                    KubePersistentVolumeFillingUp / CephCSI       │
├─────────────────────────────────────────────────────────────────┤
│ L3 工作负载       prometheus-kubernetes-apps(17)                 │
│                    Pod/Deployment/StatefulSet/DaemonSet/HPA/PDB  │
├─────────────────────────────────────────────────────────────────┤
│ L2 Kubernetes 控制面  etcd(15) / apiserver(6+slos 4) /           │
│                       scheduler(1) / controller-manager(1) /     │
│                       kubelet(15) / kube-proxy(1)                │
├─────────────────────────────────────────────────────────────────┤
│ L1 节点与网络     prometheus-node-exporter(26) / node-network(1)  │
│                    + 自研 NodeHighCPU/NodeHighMemory/NodeDiskPressure │
├─────────────────────────────────────────────────────────────────┤
│ L0 覆盖盲区补位   coverage-gap-alerts(11) / bsm-coverage-alerts(12)│
│                    （CNI、ArgoCD、Loki、MetalLB、kube-vip、默认ns）│  ← 专治"没人管"
└─────────────────────────────────────────────────────────────────┘
```

**每一层的"第一响应人"和处置动作都不同** —— 这就是为什么要分层：告警名的前缀直接告诉值班人"该找谁"。

### 7.3 全部 25 个规则组清单

| 规则组 | 告警数 | severity | `for` 取值 | 归属与职责 |
|---|---|---|---|---|
| `app-monitoring-alerts` | 10 | critical,warning | 15m, 1h, 5m | 自研·应用与中间件（证书/Tekton/Traefik/CephCSI） |
| `bsm-coverage-alerts` | 12 | critical,warning | 10m, 15m, 5m | 自研·关键服务就绪性（BSM） |
| `ceph-cluster-alerts` | 19 | critical,warning | 10m, 15m, 1m, 2m, 30m, 3m, 5m | 自研·Ceph 存储集群 |
| `cluster-wide-alerts` | 14 | critical,warning | 10m, 1h, 1m, 2m, 5m | 自研·集群全局（节点/控制面VIP/工作负载/应用） |
| `coverage-gap-alerts` | 11 | critical,warning | 10m, 15m, 5m | 自研·监控盲区补位（CNI/存储/ArgoCD/Loki） |
| `prometheus-alertmanager.rules` | 8 | critical,warning | 10m, 15m, 20m, 5m | 上游·Alertmanager 自身 |
| `prometheus-config-reloaders` | 1 | warning | 10m | 上游·配置重载 |
| `prometheus-etcd` | 15 | critical,warning | 10m, 15m, 1m, 20m, 3m, 5m | 上游·etcd 集群 |
| `prometheus-general.rules` | 3 | none,warning | -, 10m | 上游·Watchdog/TargetDown/InfoInhibitor |
| `prometheus-kube-apiserver-slos` | 4 | critical,warning | 15m, 1h, 2m, 3h | 上游·API Server 错误预算燃烧 |
| `prometheus-kube-state-metrics` | 4 | critical | 15m | 上游·KSM 自身 |
| `prometheus-kubernetes-apps` | 17 | warning | -, 10m, 15m, 1h | 上游·工作负载 |
| `prometheus-kubernetes-resources` | 8 | info,warning | 10m, 15m, 5m | 上游·资源配额/超卖/限流 |
| `prometheus-kubernetes-storage` | 5 | critical,warning | 1h, 1m, 5m | 上游·PV/PVC |
| `prometheus-kubernetes-system` | 2 | warning | 15m | 上游·版本不一致/客户端错误 |
| `prometheus-kubernetes-system-apiserver` | 6 | critical,warning | 10m, 15m, 5m | 上游·API Server 运行时 |
| `prometheus-kubernetes-system-controller-manager` | 1 | critical | 15m | 上游 |
| `prometheus-kubernetes-system-kube-proxy` | 1 | critical | 15m | 上游 |
| `prometheus-kubernetes-system-kubelet` | 15 | critical,info,warning | -, 0s, 10m, 15m, 5m | 上游·kubelet |
| `prometheus-kubernetes-system-scheduler` | 1 | critical | 15m | 上游 |
| `prometheus-node-exporter` | 26 | critical,info,warning | -, 10m, 15m, 1h, 30m, 5m | 上游·主机（本集群最大的一组） |
| `prometheus-node-network` | 1 | warning | 2m | 上游·网卡 flapping |
| `prometheus-prometheus` | 23 | critical,warning | 10m, 15m, 20m, 4h, 5m | 上游·Prometheus 自身 |
| `prometheus-prometheus-operator` | 8 | warning | 10m, 15m, 5m | 上游·Operator 自身 |
| `tempo3-alerts` | 20 | critical,warning | 10m, 15m, 5m | 自研·Tempo3 链路追踪 |

### 7.4 六条值得逐字研读的"优秀规则"

**① 监控盲区补位型 —— `LokiIngestStalled`**（覆盖"指标根本不存在"）

```promql
absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"})
  or sum(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"} == 0) > 0
for: 5m
labels: {severity: critical}
```

**② 历史与实时互补型 —— `KubePodHighRestartCount`**（annotation 直接写明设计动机）

```promql
max by (namespace, pod, container) (kube_pod_container_status_restarts_total) > 10
for: 1h
labels: {severity: warning}
annotations:
  summary: "Pod 累计重启 {{ $value }} 次: {{ $labels.namespace }}/{{ $labels.pod }}"
  description: "该 Pod 累计重启超过 10 次。现有 PodCrashLooping 规则用 rate() 只覆盖'正在发生的频繁重启'，
                本规则用累计值覆盖'已稳定但历史频繁崩溃'的盲区——集群现存 192/175/121 次的案例均属此类。
                建议人工排查根因（OOM / 探针配置 / 上游依赖）。"
```

**③ 趋势预警型 —— `NodeFilesystemSpaceFillingUp`**（现状 + 趋势 + 排除只读，三条件缺一不可）

```promql
(node_filesystem_avail_bytes / node_filesystem_size_bytes * 100 < 15
 and predict_linear(node_filesystem_avail_bytes[6h], 24*60*60) < 0
 and node_filesystem_readonly == 0) for: 1h
```

**④ 多窗口联合判定型 —— `KubeAPIErrorBudgetBurn`**（见第 13 章详解）

```promql
sum by (cluster) (apiserver_request:burnrate1h) > (14.40 * 0.01000)
  and on (cluster) sum by (cluster) (apiserver_request:burnrate5m) > (14.40 * 0.01000)
for: 2m
```

**⑤ 豁免开关型 —— `KubePersistentVolumeFillingUp`**（`unless` 留人工豁免口子）

```promql
(kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes) < 0.03
and kubelet_volume_stats_used_bytes > 0
unless on (...) kube_persistentvolumeclaim_access_mode{access_mode="ReadOnlyMany"} == 1
unless on (...) kube_persistentvolumeclaim_labels{label_excluded_from_alerts="true"} == 1
```

**⑥ 双段覆盖型 —— `LokiIngestStalled` 的 `absent() or sum(...==0)`**（见 §3.3）

### 7.5 自研 vs 上游的取舍经验

| 维度 | 上游规则 | 自研规则 |
|---|---|---|
| 覆盖面 | 全（节点 26 条、etcd 15 条、kubelet 15 条） | 针对性强（tempo3 20 条、ceph 19 条） |
| 标签依赖 | 依赖 ServiceMonitor 的标准标签 | 依赖本集群实际标签（**易踩坑**） |
| 阈值 | 全行业经验值（85%/90%/3%/15%） | 按本集群实测基线（CPU 才 11%） |
| 注解质量 | 带 `runbook_url` 指向官方排障手册 | 多数只有 `summary`，**缺 runbook** |
| 建议 | **尽量保留，别改阈值** | **补齐 runbook_url 和 description** |

> 📌 本集群自研 86 条规则中，只有少数写了完整的 `summary + description`，`runbook_url` 几乎没有 —— 这是当前最值得投入的改进项（见第 14 章检查清单）。

---

## 8. 实战一：从零写一条告警（六步法）

**需求**：`default` 命名空间里有 Deployment 副本数不足，我要在 5 分钟内知道。
（本集群确实有这条规则 `DefaultNSDeploymentUnavailable`，我们把它的诞生过程重演一遍。）

### Step 1：先用 Graph 手算，确认指标存在、标签正确

```promql
kube_deployment_spec_replicas{namespace="default"}
```

```text
实测：series=N，标签含 {namespace="default", deployment="xxx", job="kube-state-metrics", ...}
      → 确认有 deployment 标签可用 ✅
```

> **纪律：任何告警表达式，先在 Graph 里裸跑一遍。** 没有输出的表达式要么指标名错、要么标签不匹配，直接写成告警 = 一条永远不响（或永远误响）的规则。

### Step 2：把"问题"表达出来（先宽后严）

```promql
# 2a. 只看 default 命名空间
kube_deployment_spec_replicas{namespace="default"}

# 2b. 声明数 > 可用数（这才是"副本不足"）
kube_deployment_spec_replicas{namespace="default"}
  > kube_deployment_status_replicas_available{namespace="default"}
```

> ⚠️ `>` 要求**左右标签完全一致**。这两个指标来自同一个 KSM 序列族，标签天然对齐，所以可以直接比。**如果不一致，必须写 `on (namespace, deployment)`** —— 否则会静默返回空结果（这是最阴险的 bug：不报错，只是永远不告警）。

### Step 3：加聚合（需要更上层的维度吗？）

```promql
# 按 namespace + deployment 汇总（本集群最终采用的形式）
sum by (namespace, deployment) (
  kube_deployment_spec_replicas{namespace="default"}
    > on (namespace, deployment)
  kube_deployment_status_replicas_available{namespace="default"}
)
```

**决策依据**：如果你只关心"default 有没有问题"→ 不聚合，每条告警自带 deployment 标签更好定位；如果要统计"多少个 deployment 有问题"→ `count by (...)`。

### Step 4：加 `for` 和 labels / annotations

```yaml
- alert: DefaultNSDeploymentUnavailable
  expr: |
    sum by (namespace, deployment) (
      kube_deployment_spec_replicas{namespace="default"}
        > on (namespace, deployment)
      kube_deployment_status_replicas_available{namespace="default"}
    )
  for: 5m                 # 滚动更新时副本数短暂不足是正常的，给 5 分钟宽限
  labels:
    severity: warning     # 服务还在跑，只是冗余不足 → warning
    namespace: default    # 便于按 namespace 路由
  annotations:
    summary: "default 命名空间 Deployment 副本不足: {{ $labels.deployment }}"
    description: >-
      {{ $labels.deployment }} 当前可用副本数低于期望值，
      缺口 {{ $value }} 个。请检查 Pod 状态与事件：
      kubectl -n default describe deployment {{ $labels.deployment }}
    runbook_url: "https://wiki.example.internal/runbooks/default-ns-deployment"
```

### Step 5：本地校验（见第 11 章）

```bash
promtool check rules my-rules.yml                    # 语法
promtool test rules my-rules_test.yml                # 语义（会真的模拟数据）
```

### Step 6：部署 + 验证生效

```bash
# 1) 建 CR（注意 release: prometheus 标签）
kubectl apply -f my-new-rules.yaml

# 2) 确认 Operator 已加载
kubectl get prometheusrule my-new-rules -n monitoring

# 3) 确认 Prometheus 规则 API 里出现了（关键一步！）
curl -s http://10.111.41.17:9090/api/v1/rules | \
  python3 -c "import json,sys; d=json.load(sys.stdin);
print([g['name'] for g in d['data']['groups'] if 'default' in g['name']])"

# 4) 检查规则求值有无报错（health != "ok" 说明表达式有问题）
curl -s http://10.111.41.17:9090/api/v1/rules | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
for g in d['groups']:
    for r in g['rules']:
        if r.get('health') != 'ok':
            print('BAD:', g['name'], r.get('name'), r.get('lastError'))"
```

> **第 4 步是新手最常漏的**：规则被加载了，但表达式有错，`health` 会是 `err`，告警永远不会响。健康时 `lastEvaluation` 会持续更新。

---

## 9. 实战二：正在 firing 的 10 条告警复盘

**快照（2026-10-06 13:52 CST）本集群真实 firing 列表：**

| # | alertname | severity | 目标 | 条数 |
|---|---|---|---|---|
| 1 | `Watchdog` | none | 管道心跳（**正常，应永远 firing**） | 1 |
| 2 | `LokiIngestStalled` | **critical** | logging/loki-* | 1 |
| 3 | `Tempo3PodCrashLooping` | warning | tempo3-live-store-0、tempo3-block-builder-0、tempo3-metrics-generator-... | 3 |
| 4 | `Tempo3LiveStoreClientsLost` | warning | tempo3-querier-* | 1 |
| 5 | `KubePodHighRestartCount` | warning | metallb-system/speaker-7lsdm、xz49v、qmwd4、zv64c | 4 |
| | | | **合计** | **10** |

### 9.1 标准排查动线（可直接复制执行）

```bash
# ① 拿到告警的完整信息：标签 + 渲染后的注解 + 开始时间
curl -s http://10.111.41.17:9090/api/v1/alerts | python3 -m json.tool | less

# ② 复算表达式，看返回值到底是什么（而不是猜）
curl -s http://10.111.41.17:9090/api/v1/query --data-urlencode \
  'query=max by (pod)(kube_pod_container_status_restarts_total{namespace="metallb-system"})' | python3 -m json.tool

# ③ 拉时间序列，看"是什么时候开始的"
curl -s "http://10.111.41.17:9090/api/v1/query_range?query=<expr>&start=<ts>&end=<ts>&step=300"

# ④ 看规则本身有没有求值错误
curl -s http://10.111.41.17:9090/api/v1/rules | grep -A3 KubePodHighRestart

# ⑤ 回到 Kubernetes 现场
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system describe pod speaker-7lsdm | tail -30
kubectl -n metallb-system logs speaker-7lsdm --tail=100

# ⑥ 查 Alertmanager 是否已正确分组/发送
curl -s http://10.111.199.90:9093/api/v2/alerts | python3 -m json.tool
```

### 9.2 案例 A：`KubePodHighRestartCount` × 4（历史遗留型）

**现象**：4 个 metallb speaker 告警，且已持续多日。

**第一步：看数值**

```promql
max by (namespace, pod, container) (kube_pod_container_status_restarts_total) > 10
# speaker-7lsdm -> 64    speaker-zv64c -> 64
# speaker-qmwd4 -> 62    speaker-xz49v -> 36
```

**第二步：判断"还在坏吗"**

```promql
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="metallb-system"}[1h]))
# 全部 -> 0     ← 过去 1 小时没重启
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="metallb-system"}[24h]))
# 全部 -> 0     ← 过去 24 小时也没重启
```

**第三步：交叉验证**

```bash
$ kubectl get pods -n metallb-system
speaker-7lsdm  1/1  Running  64  262d    # Pod 存在 262 天，64 次重启是很久以前累计的
speaker-xz49v  1/1  Running  36  220d
```

**结论**：这是**"已稳定但历史频繁崩溃"**的场景 —— 正是规则作者在 description 里写明的设计意图（"覆盖 rate() 盲区"）。

**处置建议**：
1. 确认 speaker 当前功能正常（`kubectl -n metallb-system get pods`、MetalLB 日志无报错）→ 属**低优先级**；
2. 如果历史重启是已修复的问题 → 通过重建 Pod 清零计数器（`kubectl -n metallb-system rollout restart ds/speaker`），告警自动 Resolved；
3. 如果认为不该这么报 → 给规则加豁免标签或调高阈值（**不推荐直接删规则，会重新打开盲区**）。

> 📌 **这类告警的通病**：counter 只在 Pod 重建时归零，所以它**永远不会自动恢复**。设计上必须配套"处置后清零"的 runbook，否则告警会永久挂在看板上，最终导致所有人忽略它（告警疲劳的头号来源）。

### 9.3 案例 B：`Tempo3PodCrashLooping` × 3 + `Tempo3LiveStoreClientsLost`

**规则原文（`tempo3-alerts`）：**

```promql
# alert: Tempo3PodCrashLooping   for: 5m   severity: warning
max by (namespace, pod) (kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"} * 100 > 5)

# alert: Tempo3LiveStoreClientsLost   for: 5m   severity: warning
min(tempo_querier_livestore_clients{namespace="logging",pod=~"tempo3-querier-.*"}) < 3
```

**实测：**

```promql
max by (pod) (kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"})
# tempo3-live-store-0 -> 4     ← 触发了（4 * 100 = 400 > 5）
# tempo3-block-builder-0 -> ?  ← 也 > 0
# tempo3-live-store-1/2, block-builder-1/2, memcached-0 -> 0（未触发）
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"}[6h]))
# 全部 -> 0     ← 6 小时内没有新重启
```

**分析**（这是本教程第 3 个关键案例）：

| 观察 | 结论 |
|---|---|
| `* 100 > 5` 等价于 `> 0.05`，而 counter 是整数 | **等价于 `> 0`**，那个 `* 100` 是无效的迷惑写法 |
| 用的是**累计值**而非增量 | Pod 只要历史上重启过 1 次，**就会永远告警** |
| `increase[6h] = 0` | 当前并没有在崩溃，是历史遗留 |
| 与 `KubePodHighRestartCount` 语义重叠但阈值不同（>0 vs >10） | **规则冗余 + 阈值过松** |

**排查动作**：

```bash
kubectl -n logging get pods | grep tempo3
kubectl -n logging describe pod tempo3-live-store-0 | grep -A5 -E 'Restart|Last State'
kubectl -n logging logs tempo3-live-store-0 --previous --tail=100   # 看上一次崩溃的日志
```

**修复建议**（第 10 章给出完整改法）：改成增量 + 提高阈值，例如
`sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"}[30m])) > 3 for 5m`。

`Tempo3LiveStoreClientsLost` 则是**真正的运行时故障信号**（querier 拿不到 live-store 连接，查询会降级/超时），优先级更高，应先处理它。

### 9.4 案例 C：`LokiIngestStalled`（critical，但其实是误报）

**详见第 10.1 节** —— 结论先行：**Loki 实际完全健康，误报根因是 job 标签前缀不匹配导致 `absent()` 误判**。

> 这是全集群**唯一一条 critical 级别的 firing 告警**，却是误报 —— 也就是说，**当前真实的 critical 故障数为 0**。误报 critical 的代价非常高：消耗值班信任度，下次真出事时没人看。

### 9.5 案例 D：`Watchdog`（不是故障！）

`vector(1)` 永远 firing，`severity: none`。**它的存在恰恰说明 Prometheus → Alertmanager 链路正常。**

**看板/值班时的正确姿势**：把 `severity="none"` 的告警从"故障列表"里排除：

```promql
ALERTS{alertstate="firing", severity=~"critical|warning"} == 1     # 真正需要关注的
```

---

# 第三阶段 · 治理与工程化

## 10. 实战三：误报与哑告警治理

> 一条**误报**的告警比没有告警更糟（消耗信任），一条**哑告警**（永远不响）比误报更隐蔽（你以为有保护，其实没有）。
> 本章 4 个案例全部来自本集群的真实规则，**每个都能当场复现、当场修复**。

### 10.1 案例一：误报 —— `LokiIngestStalled` 持续 critical，但 Loki 完全健康

**症状**：Alertmanager 里这条 critical 告警长期 firing。

**复现：**

```promql
# ① 告警表达式的第一段
absent(up{namespace="logging",job=~"loki-write|loki-backend|loki-read"})
# -> series=1  {"namespace":"logging"} -> 1     ← 返回 1 = "一条都没匹配到" = 告警成立
```

**但监控目标明明存在：**

```promql
count(up{namespace="logging",job=~".*loki-(write|backend|read)"})
# -> 3       ← logging/loki-write、logging/loki-backend、logging/loki-read 都在，且 up=1
```

```bash
$ kubectl -n logging get pods | grep -E 'loki-(write|backend|read)'
loki-backend-0   2/2   Running   0   15h
loki-read-...    2/2   Running   1   15h
loki-write-0     1/1   Running   0   15h
```

**根因：**

```text
真实标签值 : job="logging/loki-write"     ← ServiceMonitor 生成时带了命名空间前缀
告警正则   : job=~"loki-write"            ← 正则默认是"完全匹配"语义，不是"包含"
结果       : 一条都匹配不上 → absent() = 1 → critical 永久误报
```

**修复（三选一，推荐 A）：**

```promql
# ✅ 方案 A：写成包含语义（兼容将来改名/加前缀）
absent(up{namespace="logging",job=~".*loki-(write|backend|read).*"})
  or sum(up{namespace="logging",job=~".*loki-(write|backend|read).*"} == 0) > 0

# ✅ 方案 B：老老实实写全前缀（最精确，但 ServiceMonitor 改名就失效）
absent(up{namespace="logging",job=~"logging/loki-(write|backend|read)"})

# ✅ 方案 C：按 pod 名匹配，绕开 job 命名不一致（最稳）
absent(up{namespace="logging",pod=~"loki-(write|backend|read)-.*"})
```

**验证修复（跑出来必须是"空"，空 = 不告警 = 现在正常）：**

```bash
q 'absent(up{namespace="logging",job=~".*loki-(write|backend|read).*"})'
# -> series=0     ✅ 修复生效（对照组：老表达式 series=1）
```

**防回归**：把这条"正常时必须为空"的断言写进 promtool 单元测试（见第 11 章用例三），以后改规则 CI 会自动拦截。

> 🔸 **通用教训**：**任何用到 `absent()` 的规则，上线前必须验证"正常时它返回什么"。** `absent()` 的失败模式是"静默变成永久告警"，而且不会有任何报错。

### 10.2 案例二：哑告警 —— `NodeHighCPU` 用了不存在的标签，永远不会响

**规则原文（`cluster-wide-alerts`）：**

```promql
1 - avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85
for: 5m
```

**假设测试：把阈值降到 0（无条件看聚合结果）**

```promql
1 - avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
# -> series=1  {node=缺失} -> 0.14008994708995692
#    只剩 1 条序列，而且 node 标签是空的！
```

**发生了什么：**

```text
node-exporter 序列上的真实标签：instance / job / namespace / pod / service / endpoint
                              —— 没有 node 标签！

avg by(node) (...)
   ↓ 每条序列的 node 都是"不存在"
   ↓ 不存在的标签被当作同一个空值
   ↓ 6 个节点被聚合成 1 条 {} 序列
   ↓ 得到的是全集群平均 CPU（14%），不是单节点 CPU
   ↓ 14% < 85% → 永不触发
```

**最危险的地方**：**即使某个节点 CPU 打到 99%，全集群平均值仍可能是 28%，告警依旧不响。** 而它看起来"已部署、已启用"，让人误以为有保护。

**修复：**

```promql
# ✅ 用真实存在的标签
1 - avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85

# ✅ 或者用录制规则补上 node 标签（本集群已有现成的录制规则可复用）
#    prometheus-node.rules: node:node_cpu_utilization:ratio_rate5m
1 - node:node_cpu_utilization:ratio_rate5m > 0.85
```

**验证修复（把阈值临时调到 15%，应能列出具体节点）：**

```promql
1 - avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.15
# -> series=3
#    10.0.0.122:9100 -> 0.1878
#    10.0.0.61:9100  -> 0.1873
#    10.0.0.121:9100 -> 0.1528     ✅ 能精确定位到节点
```

**哑告警检测方法（全量扫描本集群 235 条规则）：**

```bash
# 找出所有 by(...) 里用到的标签，逐个确认在对应指标上确实存在
curl -s http://10.111.41.17:9090/api/v1/rules | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["data"]
pat=re.compile(r"\b(?:by|without)\s*\(([^)]*)\)")
for g in d["groups"]:
    for r in g.get("rules",[]):
        expr=r.get("query") or r.get("expr") or ""
        for m in pat.finditer(expr):
            for lab in [x.strip() for x in m.group(1).split(",") if x.strip()]:
                if lab in ("node",):
                    print(f"{g[\"name\"]} / {r.get(\"name\")}: 使用了标签 {lab} <- 请人工确认存在")'
```

### 10.3 案例三：永不恢复 —— 累计型告警没有"清零"机制

见 §9.2。`speaker-7lsdm` 已累计重启 64 次、Pod 存活 262 天，`increase[1h] = 0`、`increase[24h] = 0`，但告警持续 firing。

**治理方案（按优先级）：**

| 方案 | 做法 | 适用 |
|---|---|---|
| ① 处置即清零 | 确认根因已修复后重建 Pod：`kubectl -n metallb-system rollout restart ds/speaker` | 有明确修复动作 |
| ② 加人工豁免口子 | 仿照上游 `KubePersistentVolumeFillingUp`，加 `unless on (namespace,pod) kube_pod_labels{label_excluded_from_alerts="true"} == 1` | 需要临时降噪 |
| ③ 改成"时间衰减"口径 | 用 `increase(...[7d]) > 10`（近 7 天重启超 10 次），而不是全生命周期累计 | 想要自动恢复 |
| ④ 保持现状 + 写清 runbook | annotation 明确写"本告警不自动恢复，处置后重建 Pod" | 累计值确实有审计价值 |

> 📌 **判断一条告警是否健康的核心指标：它是否具备 `Resolved` 的路径。**
> 永不恢复的告警 = 看板上永远的红色 = 告警疲劳的头号来源。

### 10.4 案例四：语义缺陷 —— `Tempo3PodCrashLooping` 的 `* 100 > 5`

```promql
max by (namespace, pod) (kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"} * 100 > 5)
```

逐条问题：

| 问题 | 分析 | 后果 |
|---|---|---|
| `* 100 > 5` 等价于 `> 0.05` | counter 是整数，等价于 `> 0` | 阈值形同虚设：**重启过 1 次就永久告警** |
| 用累计值而非 `increase` | 与 `KubePodHighRestartCount`（>10）语义重叠但更松 | 同一个 Pod 可能被两条规则各报一次 |
| 与 `Tempo3PodNotReady` 缺少联动 | 崩溃但副本仍 Ready 时只报一条 warning | 严重度失真 |
| `for: 5m` + 累计值 | 累计值不会抖动，`for` 无意义 | - |

**修复建议：**

```promql
# alert: Tempo3PodCrashLooping   for: 5m   severity: warning
sum by (namespace, pod) (
  increase(kube_pod_container_status_restarts_total{namespace="logging",pod=~"tempo3-.+"}[30m])
) > 3
# 语义：30 分钟内重启超过 3 次 = 真正的崩溃风暴；停止重启 30 分钟后自动恢复
```

配套的严重度阶梯建议：

```promql
# warning：30 分钟内重启 > 3 次（局部抖动）
sum by (pod) (increase(kube_pod_container_status_restarts_total{pod=~"tempo3-.+"}[30m])) > 3

# critical：10 分钟内重启 > 5 次，或 live-store 客户端数归零（可用性受损）
sum by (pod) (increase(kube_pod_container_status_restarts_total{pod=~"tempo3-.+"}[10m])) > 5
  or min(tempo_querier_livestore_clients{pod=~"tempo3-querier-.*"}) == 0
```

### 10.5 案例五：配置层的"死代码"

**发现一：Alertmanager 的抑制规则引用了不存在的告警名**

主机配置 `/etc/alertmanager/alertmanager.yml`：

```yaml
inhibit_rules:
  - source_matchers:
      - 'alertname = "NodeDown"'        # ← 引用 NodeDown
    target_matchers:
      - 'alertname =~ ".*"'
    equal: ['instance']
```

```bash
# 事实核查：本集群 235 条告警里根本没有 NodeDown
$ # 含 Down 的告警有 KubeletDown / KubeAPIDown / TargetDown / AlloyDown ... 但没有 NodeDown
# → 这条抑制规则永远不会生效，节点宕机时仍会收到一串级联告警
```

**发现二：主机上跑着一个收不到任何告警的"僵尸" Alertmanager**

```bash
$ systemctl is-active prometheus.service alertmanager.service
inactive                                   # 主机 Prometheus 已停
active

$ curl -s localhost:9093/api/v2/alerts | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"
0                                          # 主机 Alertmanager 里 0 条告警

$ ps -p 1059 -o lstart,cmd
Sun Sep 27 13:54:00 2026  /usr/local/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml ...
```

**结论：真正生效的是集群内 Operator 管理的 Alertmanager（`10.111.199.90:9093`，10 条告警），主机那份是遗留配置** —— 改错文件 = 白改。第 12 章有完整的"确认哪份配置生效"的方法。

### 10.6 告警治理的常态化手段

```bash
# ① 覆盖率审计：有哪些组件根本没被监控？
kubectl get deploy,ds,sts -A -o json | python3 -c '...对比 up 的 job/namespace...'

# ② 噪音审计：近 7 天哪些告警最吵？（Alertmanager 历史）
curl -s http://10.111.199.90:9093/api/v2/alerts | \
  python3 -c 'import json,sys; from collections import Counter
d=json.load(sys.stdin)
print(Counter(a["labels"]["alertname"] for a in d))'

# ③ 哑告警审计：health != ok 的规则
curl -s http://10.111.41.17:9090/api/v1/rules | grep -B2 '"health": "err"'

# ④ 永久 firing 审计：activeAt 超过 7 天的告警
curl -s http://10.111.41.17:9090/api/v1/alerts | python3 -c '
import json,sys,datetime
for a in json.load(sys.stdin)["data"]["alerts"]:
    if a["state"]=="firing":
        age=(datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(a["activeAt"].replace("Z","+00:00"))).days
        print(f"{age:3d}d  {a[\"labels\"][\"alertname\"]}  {a[\"labels\"].get(\"pod\",\"\")}")'
```

---

## 11. 测试与校验：promtool

**本机工具**：`promtool 2.55.0`（`/usr/bin/promtool`）。
⚠️ 集群内 Prometheus 是 **3.11.2**，主版本不同。`check rules` / `test rules` 对常规语法完全兼容，但**建议生产环境把 promtool 升级到与服务端一致的版本**，避免 3.x 新语法（如 `align_time()`、`limitk()` 等函数）本地测不了。

### 11.1 第一道：`promtool check rules` —— 语法与引用检查

**先把本集群真实规则导出成本地文件：**

```bash
kubectl get prometheusrule -A -o json > /tmp/pr.json
python3 - <<'EOF'
import json, yaml
d = json.load(open('/tmp/pr.json'))
out = {'groups': []}
for it in d['items']:
    if it['metadata']['name'] in ('cluster-wide-alerts', 'coverage-gap-alerts'):
        out['groups'].extend(it['spec']['groups'])
yaml.safe_dump(out, open('/tmp/demo_rules.yml', 'w'), allow_unicode=True, sort_keys=False)
print('groups:', len(out['groups']))
EOF
```

**执行检查：**

```bash
$ promtool check rules /tmp/demo_rules.yml
Checking /tmp/demo_rules.yml
  SUCCESS: 25 rules found
```

**它能抓出的错误（举例）：**

```text
expr parse error: unexpected ")"                 # 括号不匹配
unknown function with name "foo"                 # 函数名写错
incompatible types in comparison                 # 向量和标量比较但写了 on()
duplicate alert name in group                     # 同组告警重名
label "xxx" is not unique in group                # 静态标签冲突
```

**批量检查全集群规则：**

```bash
python3 -c "
import json,yaml
d=json.load(open('/tmp/pr.json'))
yaml.safe_dump({'groups':[g for it in d['items'] for g in it['spec'].get('groups',[])]},
               open('/tmp/all_rules.yml','w'),allow_unicode=True,sort_keys=False)"
promtool check rules /tmp/all_rules.yml
```

### 11.2 第二道：`promtool test rules` —— 单元测试（真正验证"会不会按预期响"）

`check` 只保证**语法对**，不保证**语义对**。语义要用测试文件模拟输入序列，断言"该响的时候响、不该响的时候闭嘴"。

**测试文件（本教程附带的可运行完整示例，已在本集群实测通过）：**

```yaml
# /tmp/demo_rules_test.yml
rule_files:
  - /tmp/demo_rules.yml          # 被测规则（本集群 cluster-wide + coverage-gap 真实规则）

evaluation_interval: 1m

tests:
  # ---- 用例 1：metallb speaker 累计重启 30 次 → 必须触发 KubePodHighRestartCount ----
  - interval: 5m
    input_series:
      - series: 'kube_pod_container_status_restarts_total{namespace="metallb-system",pod="speaker-test",container="speaker"}'
        values: '0+1x30'         # 起始 0，每 5 分钟 +1，共 31 个点 → 最终 30 次
    alert_rule_test:
      - eval_time: 150m          # 第 150 分钟检查（>10 的时刻 + for:1h 已满足）
        alertname: KubePodHighRestartCount
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: metallb-system
              pod: speaker-test
              container: speaker
            exp_annotations:
              summary: "Pod 累计重启 30 次: metallb-system/speaker-test"
              description: "该 Pod 累计重启超过 10 次。现有 PodCrashLooping 规则用 rate() 只覆盖'正在发生的频繁重启'，本规则用累计值覆盖'已稳定但历史频繁崩溃'的盲区——集群现存 192/175/121 次的案例均属此类。建议人工排查根因（OOM / 探针配置 / 上游依赖）。"

  # ---- 用例 2：只有 3 次重启 → 必须保持沉默（验证阈值下限）----
  - interval: 5m
    input_series:
      - series: 'kube_pod_container_status_restarts_total{namespace="default",pod="calm-app",container="app"}'
        values: '0+1x10'
    alert_rule_test:
      - eval_time: 60m
        alertname: KubePodHighRestartCount
        exp_alerts: []           # 期望：无告警
```

**执行与结果：**

```bash
$ promtool test rules /tmp/demo_rules_test.yml
SUCCESS
```

**补充：验证"正常时必须不告警"（针对 10.1 的误报回归）**

```yaml
  # ---- 用例 3：Loki 正常在跑 → LokiIngestStalled 绝不能响 ----
  - interval: 30s
    input_series:
      - series: 'up{namespace="logging", job="logging/loki-write", instance="10.244.5.75:3100"}'
        values: '1x100'
      - series: 'up{namespace="logging", job="logging/loki-backend", instance="10.244.5.78:3100"}'
        values: '1x100'
      - series: 'up{namespace="logging", job="logging/loki-read", instance="10.244.5.125:3100"}'
        values: '1x100'
    alert_rule_test:
      - eval_time: 30m
        alertname: LokiIngestStalled
        exp_alerts: []           # 用修复后的表达式 → 通过；用原表达式 → 这里会失败并暴露误报
```

**`values` 语法速查：**

```text
'0+1x30'   从 0 开始，每步 +1，重复 30 次   → 0,1,2,...,30
'0+5x10'   从 0 开始，每步 +5，重复 10 次
'10-1x20'  从 10 开始，每步 -1，重复 20 次（模拟下降）
'0+1x5 7 9+2x3'  多段：空格分隔，可表达跳变（counter reset 用）
'_x10'     从上一个值延续 10 步（值不变）
```

### 11.3 第三道：部署后验证（线上）

```bash
# 规则是否被加载
curl -s $P/api/v1/rules | python3 -c 'import json,sys
d=json.load(sys.stdin)["data"]
print("组数:", len(d["groups"]), " 规则数:", sum(len(g["rules"]) for g in d["groups"]))'

# 是否有求值错误（最重要！）
curl -s $P/api/v1/rules | python3 -c 'import json,sys
d=json.load(sys.stdin)["data"]
bad=[(g["name"],r.get("name"),r.get("lastError")) for g in d["groups"] for r in g["rules"] if r.get("health")!="ok"]
print("异常规则:", len(bad))
[print(" ",*b) for b in bad[:20]]'

# 是否已经开始产生 pending/firing（用一条故意触发的测试告警验证全链路）
# 见下方"全链路自检"
```

### 11.4 全链路自检：造一条测试告警走完整条路

```bash
# 1) 建一条必然触发的规则（vector(1) > 0，for: 0s）
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: alert-pipeline-selftest
  namespace: monitoring
  labels: {release: prometheus}
spec:
  groups:
    - name: selftest.rules
      rules:
        - alert: AlertPipelineSelfTest
          expr: vector(1) > 0
          for: 0s
          labels: {severity: warning, selftest: "true"}
          annotations:
            summary: "告警链路自检（可安全静默/删除）"
EOF

# 2) 确认 Prometheus 侧 firing
curl -s "$P/api/v1/query?query=ALERTS{alertname=\"AlertPipelineSelfTest\"}" | python3 -m json.tool

# 3) 确认 Alertmanager 收到
curl -s http://10.111.199.90:9093/api/v2/alerts | grep -c AlertPipelineSelfTest

# 4) 确认通知出口（wecom adapter / n8n webhook 日志）
kubectl -n monitoring logs deploy/wecom-adapter --tail=20

# 5) 用完立刻删掉
kubectl -n monitoring delete prometheusrule alert-pipeline-selftest
```

> 📌 **每次改完 Alertmanager 配置或通知出口，都跑一遍这个自检** —— 它是唯一能证明"告警真的发得出去"的手段。

### 11.5 规则上线前检查清单

```text
□ 1. promtool check rules 通过
□ 2. promtool test rules 覆盖"该响"和"不该响"两个用例
□ 3. 在 Graph 里裸跑表达式，确认正常时返回空、故障时返回具体序列
□ 4. 确认所有 by(...)/on(...) 用到的标签在该指标上真实存在
□ 5. 用 absent() 的规则，已验证正常时返回空
□ 6. for ≥ 2× evaluation_interval（本集群即 ≥ 1 分钟）
□ 7. severity 分级合理，critical 必须"需要叫醒人"
□ 8. annotations 有 summary + description，description 含可复制的处置命令
□ 9. 同类语义没有重复规则（累计 vs 增量要分清）
□ 10. PrometheusRule 带 release: prometheus 标签
□ 11. 部署后 curl /api/v1/rules 确认 health == "ok"
□ 12. 跑一次全链路自检，确认通知真的发出去了
□ 13. 决定了这条告警的 Resolved 路径（怎么自动/手动消除）
□ 14. 通知对象确认：wecom/n8n webhook 收到分组后能正确显示标签
```

---

## 12. Alertmanager 通知与降噪

### 12.1 先搞清楚：哪份配置才是生效的？

本集群存在**两套 Alertmanager**，这是最容易踩的坑：

| | 集群内（**生效中**） | 主机上（**遗留/闲置**） |
|---|---|---|
| 进程 | Operator 管理的 Pod（AM v0.32.0） | `alertmanager.service`（systemd，2026-09-27 启动） |
| 地址 | `10.111.199.90:9093`（svc `prometheus-alertmanager`） | `0.0.0.0:9093`（本机） |
| 配置来源 | Secret `alertmanager-prometheus-alertmanager` | `/etc/alertmanager/alertmanager.yml` |
| 接收器 | `n8n-webhook`、`wecom`（Webhook） | `default-email`（QQ 企业邮 SMTP） |
| 当前告警数 | **10 条** ✅ | **0 条** ❌ |
| 判定依据 | Prometheus CR 的 `alerting` 指向集群 svc | 主机 `prometheus.service` 已 `inactive`，无告警可发 |

**确认哪份配置生效的三条命令：**

```bash
# 1) Prometheus 实际把告警发给谁
kubectl get prometheus prometheus -n monitoring -o yaml | grep -A6 'alerting:'

# 2) Alertmanager 自己声明的配置（最权威）
curl -s http://10.111.199.90:9093/api/v2/status | python3 -c 'import json,sys;print(json.load(sys.stdin)["config"]["original"])'

# 3) 两边告警数对比（谁有告警谁就是活的）
curl -s http://10.111.199.90:9093/api/v2/alerts | python3 -c 'import json,sys;print("集群AM:",len(json.load(sys.stdin)))'
curl -s localhost:9093/api/v2/alerts | python3 -c 'import json,sys;print("主机AM:",len(json.load(sys.stdin)))'
```

### 12.2 生效中的真实配置（节选，敏感信息已脱敏）

```yaml
route:
  receiver: n8n-webhook              # 默认出口（含 info / none 级别）
  group_by: [alertname, namespace, severity]   # 按 告警名+命名空间+级别 分组
  group_wait: 30s                    # 组内第一条先等 30s，收集同组的其他告警
  group_interval: 5m                 # 同组新增告警，5 分钟后再通知一次
  repeat_interval: 12h               # 持续 firing 的，每 12 小时重复一次
  routes:
    - receiver: wecom                # 企业微信出口
      matchers: [severity =~ "critical|warning"]
      continue: true                 # ★ 匹配后继续往下走（所以 wecom 和 n8n 都会收到）
    - receiver: n8n-webhook
      matchers: [severity =~ "critical|warning"]
receivers:
  - name: n8n-webhook
    webhook_configs:
      - send_resolved: true
        url: http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
  - name: wecom
    webhook_configs:
      - send_resolved: true
        url: http://wecom-adapter.monitoring.svc.cluster.local:8080/alerts
inhibit_rules: []                    # ⚠️ 当前没有任何抑制规则
templates: [/etc/alertmanager/config/*.tmpl]
```

**这份配置的语义解读：**

```text
critical / warning  → wecom（企业微信）+ n8n-webhook 两个出口都发（continue: true）
info / none         → 只发 n8n-webhook（不打扰企业微信）
恢复通知            → send_resolved: true，故障消失时也发
分组效果            → metallb 4 个 speaker 的 KubePodHighRestartCount
                      因为 alertname + namespace + severity 都相同
                      → 被合并成 1 条通知，而不是 4 条轰炸 ✅
```

**验证分组效果（实测）：**

```bash
$ curl -s http://10.111.199.90:9093/api/v2/alerts | \
    python3 -c 'import json,sys;from collections import Counter
d=json.load(sys.stdin);print(Counter(a["labels"]["alertname"] for a in d))'
Counter({'KubePodHighRestartCount': 4, 'Tempo3PodCrashLooping': 3,
         'Watchdog': 1, 'LokiIngestStalled': 1, 'Tempo3LiveStoreClientsLost': 1})
# 这 4 条 + 3 条在通知侧会被聚合成 2 条消息
```

> 📌 **`group_by` 里放什么，决定通知的"颗粒度"**：
> - 放 `pod`/`instance` → 每个实例一条（精细但吵）；
> - 放 `alertname, namespace` → 同类问题合并（**推荐，本集群做法**）；
> - 什么都不放（`[]`）→ 全部塞进一条（省心但看不到细节）。

### 12.3 时间参数怎么调

```text
group_wait:      30s    # 等待窗口：给"同一波故障同时产生多条告警"留收集时间
                     #   故障范围大（如节点宕机引发 20 条告警）时，这 30s 决定是 1 封还是 20 封
group_interval:  5m     # 同一组有新成员/新恢复时，5 分钟后再更新一次
repeat_interval: 12h    # 没人处理时的重复提醒周期
                     #   critical → 建议 1~2h（别让火灭了没人管）
                     #   warning  → 12h~24h 合适
                     #   本集群全局 12h：建议拆成按 severity 分别设置（见 12.5）
```

### 12.4 静默（Silence）与抑制（Inhibit）

**临时静默 —— 计划内维护窗口：**

```bash
# 通过 API 创建静默（匹配 metallb-system 的所有告警，2 小时）
curl -XPOST http://10.111.199.90:9093/api/v2/silences -H 'Content-Type: application/json' -d '{
  "matchers": [
    {"name": "namespace", "value": "metallb-system", "isRegex": false},
    {"name": "severity",  "value": "warning",        "isRegex": false}
  ],
  "startsAt": "2026-10-06T14:00:00Z",
  "endsAt":   "2026-10-06T16:00:00Z",
  "createdBy": "oncall-zhang",
  "comment":   "MetalLB 升级维护窗口"
}'

# 查看/结束静默
curl -s http://10.111.199.90:9093/api/v2/silences | python3 -m json.tool
curl -XDELETE http://10.111.199.90:9093/api/v2/silence/<id>
```

> ⚠️ **静默 ≠ 删除**：静默期间告警仍在 Prometheus 里 firing，恢复时**不会**补发通知。**必须写 `endsAt`**，否则会变成"永久静默 = 变相删告警"（历史上最常见的事故之一）。

**抑制 —— 用一条大告警压掉级联噪音（当前集群是空的，建议补上）：**

```yaml
inhibit_rules:
  # 节点 NotReady → 抑制该节点上的所有 Kubelet/Pod 告警
  - source_matchers: ['alertname = "KubeNodeNotReady"']
    target_matchers: ['alertname =~ "Kubelet.*|KubePod.*|Node.*"']
    equal: [node]

  # 控制面 VIP 异常 → 抑制其引发的 apiserver 抖动告警
  - source_matchers: ['alertname = "KubeVIPLeaderNotRenewing"']
    target_matchers: ['alertname =~ "KubeAPI.*"']

  # 已有 critical → 抑制同 namespace 的 warning/info
  - source_matchers: ['severity = "critical"']
    target_matchers: ['severity =~ "warning|info"']
    equal: [namespace]
```

**抑制规则的三条铁律：**

```text
1. source 和 target 都必须用 matchers（新式），equal 里放"必须相同"的标签
2. 只有 source 真的 firing 时才抑制 target（不存在的 source 名 = 不生效，见 10.5）
3. 每加一条抑制，都要验证：制造 source 告警，确认 target 被压掉；
   source 恢复后，target 立刻重新可见
```

### 12.5 当前配置的三个改进点（按收益排序）

**改进 ①：按 severity 拆分 `repeat_interval`**

```yaml
route:
  receiver: n8n-webhook
  group_by: [alertname, namespace]
  routes:
    - receiver: wecom                       # critical：30 分钟重复一次，直到有人处理
      matchers: [severity = "critical"]
      repeat_interval: 30m
      group_wait: 10s                       # critical 要快，别等 30s
    - receiver: wecom                       # warning：一天两次足够
      matchers: [severity = "warning"]
      repeat_interval: 6h
      continue: true
    - receiver: n8n-webhook                 # info/none：只进汇总流水
      matchers: [severity =~ "info|none"]
      repeat_interval: 24h
```

**改进 ②：补上 12.4 的 `inhibit_rules`**（当前 `[]`，节点故障会产生级联轰炸）。

**改进 ③：给通知加上下文链接**（模板里带上 runbook 与直跳链接）：

```yaml
templates: [/etc/alertmanager/config/*.tmpl]
# tmpl 内容示例：
# {{ .CommonLabels.alertname }} | {{ .CommonLabels.namespace }}
# {{ range .Alerts }}- {{ .Annotations.summary }}
#   Runbook: {{ .Annotations.runbook_url }}{{ end }}
```

### 12.6 通知链路故障怎么查

```bash
# 1) Prometheus 有没有在发
curl -s "$P/api/v1/query?query=rate(alertmanager_notifications_failed_total[15m])"
curl -s "$P/api/v1/query?query=alertmanager_notifications_total"

# 2) AM 自身告警（AlertmanagerFailedToSendAlerts 会在这里响）
curl -s http://10.111.199.90:9093/api/v2/alerts | grep -i alertmanager

# 3) 接收端（webhook 是否 200）
kubectl -n monitoring logs deploy/wecom-adapter --tail=50 | grep -iE 'error|4[0-9][0-9]|5[0-9][0-9]'
kubectl -n monitoring logs deploy/wecom-adapter --tail=20

# 4) 终极自检：第 11.4 节的 AlertPipelineSelfTest
```

---

## 13. 进阶选修：SLO / 多窗口 burn rate 告警

### 13.1 为什么"错误率 > 1%"这种阈值是错的

```text
错误率 1% 持续 5 分钟  → 可能只是发布抖动，不该叫人
错误率 1% 持续 6 小时  → 要看 SLO：99.9% 时约 8% 月预算，99% 时约 0.83%
                         不是“一整天”的损失，但已经值得处理

同一个阈值，不同持续时间，严重程度天差地别。
SLO 的解法：**不盯"当前值"，盯"错误预算燃烧速度"**。
```

### 13.2 本集群的真实实现（`prometheus-kube-apiserver-slos`）

**第一步：录制规则预先算好 7 个窗口的燃烧率**

```promql
# prometheus-kube-apiserver-burnrate.rules 中（读写各一套，共 14 条）
apiserver_request:burnrate5m  = (过去 5 分钟的错误请求率 / SLO 允许的错误率)
apiserver_request:burnrate30m
apiserver_request:burnrate1h
apiserver_request:burnrate2h
apiserver_request:burnrate6h
apiserver_request:burnrate1d
apiserver_request:burnrate3d
```

**第二步：四档告警，长短窗口必须同时超标**

> **修正记录（2026-11-11）**：原文把“该窗口消耗预算的比例”写成了“烧光全部预算的时间”。
> 按 30 天 SLO（720h）计算，14.4×1h 只消耗 2% 预算，不是 1 小时烧光；
> 1× 烧光需要 30 天，不是 3 天。告警阈值本身不变，时间换算已修正如下。

```promql
# 档位 1（fast，for: 2m）：14.4 倍速，1h 消耗月预算 2% → 立刻告警
sum by (cluster) (apiserver_request:burnrate1h) > (14.40 * 0.01000)
  and on (cluster) sum by (cluster) (apiserver_request:burnrate5m) > (14.40 * 0.01000)

# 档位 2（for: 15m）：6 倍速，6h 消耗月预算 5%
apiserver_request:burnrate6h > 6.00 * 0.01000  and  apiserver_request:burnrate30m > 6.00 * 0.01000

# 档位 3（for: 1h）：3 倍速，1d 消耗月预算 10%
apiserver_request:burnrate1d > 3.00 * 0.01000  and  apiserver_request:burnrate2h > 3.00 * 0.01000

# 档位 4（for: 3h）：1 倍速，3d 消耗月预算 10%；按 1× 烧光要 30 天
apiserver_request:burnrate3d > 1.00 * 0.01000  and  apiserver_request:burnrate6h > 1.00 * 0.01000
```

> 统一公式（30 天 SLO，预算窗口 720h）：
>
> ```text
> 预算消耗比 = burn_rate × 观察窗口 / 720h
> 烧光时间   = 720h / burn_rate
> ```
>
> | burn | 窗口 | 该窗口消耗预算 | 按此速率烧光 |
> |---:|---:|---:|---:|
> | 14.4 | 1h | 2% | 50h |
> | 6 | 6h | 5% | 120h（5d） |
> | 3 | 1d | 10% | 240h（10d） |
> | 1 | 3d | 10% | 720h（30d） |
>
> 所以四档告警的语义是“**这段时间烧掉了多少预算**”，不是“多久烧光”。
> 1× 是“按计划在 30 天内刚好烧完”，不是 3 天。

**设计要点解读：**

| 要点 | 原因 |
|---|---|
| `and on (cluster)` 短窗口 + 长窗口**双条件** | 只看 5m 会被毛刺骗；只看 6h 反应太慢。**双窗口 = 既要趋势成立、又要当前仍在烧** |
| 短窗口决定灵敏度，长窗口决定可信度 | `for` 因此可以设得很短（2m），因为第二个条件已经天然过滤了毛刺 |
| 乘 `0.01000`（= 99% SLO 对应的 1% 错误率） | 燃烧率的定义：**实际错误率 ÷ 预算错误率**，所以 1.0 = 按 30 天计划持续刚好烧光 |
| 用录制规则而非内联 | 7 窗口 × 读写两套的复杂度，内联写出来没法维护 |

**当前本集群实测：**

```promql
apiserver_request:burnrate5m
# 当前值远低于 0.144（14.4×0.01），无燃烧告警
```

### 13.3 给自己的服务做同款（模板）

```yaml
groups:
  - name: myservice-slo.rules
    rules:
      # ---- 录制规则：先算好 ----
      - record: myservice:http_requests:burnrate5m
        expr: |
          sum(rate(myservice_http_requests_total{status=~"5.."}[5m]))
          / sum(rate(myservice_http_requests_total[5m]))
          / 0.01    # SLO 99% → 允许 1% 错误率
      - record: myservice:http_requests:burnrate1h
        expr: |
          sum(rate(myservice_http_requests_total{status=~"5.."}[1h]))
          / sum(rate(myservice_http_requests_total[1h]))
          / 0.01

      # ---- 告警规则：双窗口 ----
      - alert: MyServiceErrorBudgetBurnFast
        expr: |
          myservice:http_requests:burnrate1h > 14.4
            and on () myservice:http_requests:burnrate5m > 14.4
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "myservice 错误预算正在以 14.4 倍速燃烧（1 小时消耗 2% 月预算）"
          description: "短窗 {{ $value | humanizePercentage }}，请立即回滚或限流。"
```

**配套的看板指标（判断 SLO 健康度）：**

```promql
# 30 天可用性
1 - (
  sum(rate(apiserver_request_total{code=~"5.."}[30d]))
  / sum(rate(apiserver_request_total[30d]))
)

# 剩余错误预算百分比（0~100%）
100 * (1 - 剩余燃烧量)
```

---

## 14. 常见坑与调优清单

### 14.1 二十个高频坑（前 6 个已在本集群真实发生）

| # | 坑 | 症状 | 检查方法 |
|---|---|---|---|
| 1 | **`by(node)` 用了不存在的标签** | 6 节点聚成 1 条空标签序列，永远不告警（§10.2） | 裸跑表达式看 `series` 数和标签 |
| 2 | **`absent()` 正则不匹配真实标签** | 永久 critical 误报（§10.1） | 正常时跑一次，必须为空 |
| 3 | **用累计值而非 `increase`** | 告警永不恢复（§10.3、§10.4） | 问自己：这条告警怎么 Resolved？ |
| 4 | **规则引用不存在的告警做抑制** | 抑制规则是死代码（§10.5） | `grep alertname` 与规则库比对 |
| 5 | **改了不生效的配置文件** | 改主机 AM，集群 AM 没变（§12.1） | `curl /api/v2/status` 看真实配置 |
| 6 | **规则 health=err 没人发现** | 规则加载了但永不求值 | `curl /api/v1/rules` 扫 `health != ok` |
| 7 | `>` 两侧标签不对齐 | 静默返回空（不报错） | 加 `on (xxx)` 前先裸跑 |
| 8 | 忘记 `by (le)` 算分位数 | 结果永远是 +Inf / 0 | 检查 `sum by (le)` 是否存在 |
| 9 | 对 Gauge 用 `rate()` | 数值无意义 | 认清指标类型（§1.1） |
| 10 | 窗口 < 4 × scrapeInterval | 曲线锯齿、rate 抖动误报 | 本集群窗口 ≥ 2m，推荐 5m |
| 11 | `for` 太短（< 2 个求值周期） | 等于没设 `for` | 本集群 `for ≥ 1m`，推荐 5m |
| 12 | 正则没想清楚"完全匹配 vs 包含" | `job=~"loki-write"` 匹配不上 `logging/loki-write` | 用 `.*xxx.*` 或写全 |
| 13 | 缺少 `release: prometheus` 标签 | PrometheusRule 不被加载 | `kubectl get prometheusrule -o yaml` 检查 label |
| 14 | 除零产生 `+Inf` / `NaN` | 告警值显示 Inf | 分母加 `> 0` 条件（参考 PV 规则） |
| 15 | 阈值未按本集群基线校准 | 全集群 CPU 才 11%，却按 90% 阈值 → 永不告警或过松 | 先看 P95 再定阈值 |
| 16 | 同一语义写了两条规则 | 同一 Pod 收到重复通知 | 审计 alertname 语义重叠 |
| 17 | critical 不需要叫醒人 | 分级失真，信任崩塌 | 定期评审 severity |
| 18 | 没有 `send_resolved` | 故障恢复了没人知道，故障时长被高估 | 确认每个 receiver 都 `send_resolved: true` |
| 19 | 静默没有 `endsAt` | 变相永久删除告警 | 审计 `/api/v2/silences` |
| 20 | 告警没有 runbook | 收到告警不知道怎么处置 | 每条 warning+ 必须有 description/runbook |

### 14.2 阈值怎么定：用数据说话，不要拍脑袋

```bash
# 步骤 1：先看历史分布，而不是先定阈值
# 例：节点 CPU 的 P50 / P95 / P99（本集群可用 range query 拿一段时间的分布）

# 用 Prometheus 的 quantile_over_time（对 instant vector 的历史分位数）
curl -s "$P/api/v1/query" --data-urlencode \
 'query=quantile_over_time(0.95, (1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])))[7d:5m])'
```

**本集群的实测基线（2026-10-06 快照）：**

| 指标 | 实测值 | 现有阈值 | 评估 |
|---|---|---|---|
| 节点 CPU | 7.00% ~ 17.84%（均值 11.38%） | 85% / 90% | **过于宽松**：即使某节点到 40% 也毫无感知；建议 warn 60% / crit 85%，或先加 info 级观察 |
| 节点内存 | 22.71% ~ 77.83% | 90% | 合理，但 10.0.0.61 已 77.8%，需关注 |
| 根分区使用率 | 41.8% ~ 65.7% | 85%（NodeDiskPressure） | 合理 |
| PV 使用率 | 0.17% ~ 37.28% | 3%（填满预警） | 合理（3% 是"快满了"，不是"当前用量"） |
| API Server p99 | 49.6ms | SLO 燃烧率 | 合理 |
| etcd db | ~105MB / 8GB quota | 外推 4h 超限 | 合理 |
| Pod 重启累计 | 最高 64 次（262 天） | >10 次 | **口径偏松**且永不恢复（§10.3） |

> 📌 **阈值方法论**：`阈值 = P95(基线) + 安全余量`，并按 severity 分两档：
> `warning = P95 × 1.5`，`critical = P95 × 3` 或绝对上限。
> **新指标先挂 info/warning 观察一周，再决定要不要升 critical。**

### 14.3 性能调优

```text
1. 复杂表达式 → 录制规则（本集群已有 94 条，善加利用）
2. 避免在告警里用高基数正则（job=~".*" 会扫全量序列）
3. topk/quantile 等聚合放在录制规则里，别放在看板的每个面板
4. 看板刷新周期 ≥ scrapeInterval（30s），别设 5s
5. 录制规则的 interval 可以比告警求值慢（如 1m），减少计算量
6. 关注 Prometheus 自身告警：PrometheusHighQueryLoad / PrometheusRuleFailures
7. retention 15d/25GiB 是硬约束：长周期查询（30d）会算不出来，
   SLO 类 30d 查询需要靠录制规则按天预聚合
```

### 14.4 上线前最终检查（可打印贴在墙上）

```text
表达式层
  □ Graph 裸跑过：正常时为空，故障时有输出
  □ 所有 by/on 用到的标签确认存在
  □ absent() 已验证正常返回空
  □ 窗口 ≥ 4 × scrapeInterval（≥ 2m）
  □ 除零/Inf 已防护

告警层
  □ for ≥ 2 × evaluation_interval
  □ severity 分级有依据（critical = 要叫醒人）
  □ 有 summary + description（description 含处置命令）
  □ 有 runbook_url
  □ 明确 Resolved 路径（尤其累计型指标）
  □ 与已有规则无语义重复

工程层
  □ promtool check + test 通过
  □ CR 带 release: prometheus 标签
  □ /api/v1/rules 里 health = ok
  □ 全链路自检通过（AlertPipelineSelfTest）
  □ 通知分组符合预期（同 namespace 同类告警合并）
  □ 抑制规则已验证生效与解除
  □ 静默都有 endsAt
```

---

# 附录 A：常用 PromQL 速查（本集群可直接跑）

### A.1 概览与健康

```promql
count(up)                                   # 抓取目标总数（实测 125）
sum(up == 0)                                # 失败目标数（实测 0）
count by (job) (up)                         # 按 job 分布
up == 0                                     # 哪些目标挂了
ALERTS{alertstate="firing"} == 1            # 当前所有 firing 告警
count by (severity) (ALERTS{alertstate="firing"} == 1)   # 按级别统计
```

### A.2 节点（node-exporter）

```promql
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))            # CPU 使用率
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)                # 内存使用率
node_load1 / count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})     # 每核负载
100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)  # 根分区
rate(node_network_receive_bytes_total{device!="lo"}[5m])                         # 网络入向速率
rate(node_disk_io_time_weighted_seconds_total{device=~"sd.*|nvme.*"}[5m])       # 磁盘 iowait
```

### A.3 Kubernetes 工作负载（kube-state-metrics）

```promql
sum by (namespace) (kube_pod_info)                                     # 各 ns Pod 数
sum by (phase) (kube_pod_status_phase{phase=~"Running|Pending"} == 1)  # 状态分布
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0
topk(5, max by (namespace, pod) (kube_pod_container_status_restarts_total))
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h]))
kube_deployment_spec_replicas > kube_deployment_status_replicas_available
kube_node_status_condition{condition="Ready", status="true"} == 0
```

### A.4 容器资源（cAdvisor）

```promql
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{image!=""}[5m]))
sum by (namespace, pod) (container_memory_working_set_bytes{image!=""})
sum by (namespace, pod) (increase(container_oom_events_total[1h])) > 0
increase(container_cpu_cfs_throttled_periods_total[5m]) / increase(container_cpu_cfs_periods_total[5m]) > 0.25
```

### A.5 存储（Ceph / PV）

```promql
ceph_health_status{cluster="ceph-prod"}                       # 0=HEALTH_OK（实测 0）
count(ceph_osd_up == 1)                                       # 在线 OSD 数（实测 6）
count(ceph_pg_degraded == 1)                                  # 降级 PG 数
kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes
kube_persistentvolume_status_phase{phase=~"Failed|Pending"} > 0
```

### A.6 告警与规则调试

```promql
# 表达式"是否会产生告警"的等价查询（把 alert 的 expr 直接贴进来即可）
(node_filesystem_avail_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes) < 0.15

# 某条告警的历史轨迹（什么时候开始 firing）
ALERTS{alertname="KubePodHighRestartCount"} == 1
```

```bash
# 规则求值健康检查
curl -s $P/api/v1/rules | python3 -c 'import json,sys
d=json.load(sys.stdin)["data"]
print("groups:",len(d["groups"]),"rules:",sum(len(g["rules"]) for g in d["groups"]))
print("err:",sum(1 for g in d["groups"] for r in g["rules"] if r.get("health")!="ok"))'
```

---

# 附录 B：235 条告警全清单

### B.1 按规则组（条数 = 规则数，同名不同阈值档位算多条）

| 规则组 | 条数 | severity | `for` 取值 | 归属 |
|---|---|---|---|---|
| `app-monitoring-alerts` | 10 | critical,warning | 15m, 1h, 5m | 自研·应用与中间件 |
| `bsm-coverage-alerts` | 12 | critical,warning | 10m, 15m, 5m | 自研·关键服务就绪性 |
| `ceph-cluster-alerts` | 19 | critical,warning | 1m~30m | 自研·Ceph 存储 |
| `cluster-wide-alerts` | 14 | critical,warning | 1m,2m,5m,10m,1h | 自研·集群全局 |
| `coverage-gap-alerts` | 11 | critical,warning | 5m,10m,15m | 自研·监控盲区补位 |
| `tempo3-alerts` | 20 | critical,warning | 5m,10m,15m | 自研·Tempo3 |
| `prometheus-alertmanager.rules` | 8 | critical,warning | 5m~20m | 上游·AM 自身 |
| `prometheus-config-reloaders` | 1 | warning | 10m | 上游 |
| `prometheus-etcd` | 15 | critical,warning | 1m~20m | 上游·etcd |
| `prometheus-general.rules` | 3 | none,warning | -,10m | 上游·Watchdog 等 |
| `prometheus-kube-apiserver-slos` | 4 | critical,warning | 2m,15m,1h,3h | 上游·SLO 燃烧 |
| `prometheus-kube-state-metrics` | 4 | critical | 15m | 上游·KSM |
| `prometheus-kubernetes-apps` | 17 | warning | -,10m,15m,1h | 上游·工作负载 |
| `prometheus-kubernetes-resources` | 8 | info,warning | 5m,10m,15m | 上游·配额/限流 |
| `prometheus-kubernetes-storage` | 5 | critical,warning | 1m,5m,1h | 上游·PV |
| `prometheus-kubernetes-system` | 2 | warning | 15m | 上游 |
| `prometheus-kubernetes-system-apiserver` | 6 | critical,warning | 5m,10m,15m | 上游·API Server |
| `prometheus-kubernetes-system-controller-manager` | 1 | critical | 15m | 上游 |
| `prometheus-kubernetes-system-kube-proxy` | 1 | critical | 15m | 上游 |
| `prometheus-kubernetes-system-kubelet` | 15 | critical,info,warning | 0s,5m,10m,15m | 上游·kubelet |
| `prometheus-kubernetes-system-scheduler` | 1 | critical | 15m | 上游 |
| `prometheus-node-exporter` | 26 | critical,info,warning | -,5m,10m,15m,30m,1h | 上游·主机 |
| `prometheus-node-network` | 1 | warning | 2m | 上游·网卡 |
| `prometheus-prometheus` | 23 | critical,warning | 5m~4h | 上游·Prometheus 自身 |
| `prometheus-prometheus-operator` | 8 | warning | 5m,10m,15m | 上游·Operator |
| **合计** | **235** | | | |

### B.2 按告警名（去重；同名多档位规则只列一次）

**app-monitoring-alerts**（10）：`CNPGControllerManagerDown`、`CephCSIOperationErrors`、`CertManagerCertificateExpired`、`CertManagerCertificateExpiringSoon`、`CertManagerNotReady`、`KafkaClusterOperatorDown`、`KnativeEventingControllerDown`、`TektonPipelineRunFailed`、`TektonTaskRunFailed`、`TraefikHigh5xxRate`

**bsm-coverage-alerts**（12）：`AlertReceiverDown`、`CNIComponentNotReady`、`CNIKubeControllersDown`、`CoreComponentNotReady`、`DaemonSetNotFullyScheduled`、`GitOpsRedisDown`、`KafkaEntityOperatorDown`、`KubeVIPDown`、`MetalLBSpeakerNotReady`、`PodCrashLoopingFixed`、`StorageProvisionerDown`、`TektonInterceptorsDown`

**ceph-cluster-alerts**（19）：`CephClusterCriticallyFull`、`CephClusterHealthUnknown`、`CephClusterNearFull`、`CephClusterUnhealthy`、`CephMGRMetricsMissing`、`CephMGRUnreachable`、`CephMonNotInQuorum`、`CephMonQuorumLost`、`CephOSDDown`、`CephOSDHighCommitLatency`、`CephOSDOutOfCluster`、`CephPGDegraded`、`CephPGIncomplete`、`CephPGScrubbingError`、`CephPGStale`、`CephPoolCriticallyFull`、`CephPoolNearFull`、`CephPoolNoSpace`、`CephTooFewOSDs`

**cluster-wide-alerts**（14）：`KubeContainerOOMKilled`、`KubePodCriticalComponentHighRestart`、`KubePodHighRestartCount`、`KubeVIPLeaderNotRenewing`、`KubeVIPLeadershipChurn`、`KubeVIPRestarting`、`NodeDiskPressure`、`NodeHighCPU`、`NodeHighMemory`、`OtelDemoHighErrorRate`、`OtelDemoServiceDown`、`PodCrashLooping`、`PodNotReady`、`PodOOMKilled`

**coverage-gap-alerts**（11）：`AlloyDesiredCountMismatch`、`AlloyDown`、`ArgoCDHighRestart`、`ArgoCDRepoServerDown`、`CalicoKubeControllersDown`、`CalicoNodeNotReady`、`DefaultNSDeploymentUnavailable`、`DefaultNSProbeFailing`、`LokiIngestStalled`、`MetalLBSpeakerHighRestart`、`MetalLBSpeakerNotReady`

**tempo3-alerts**（20）：`Tempo3BackendSchedulerFlushFailing`、`Tempo3BlockFlushFailing`、`Tempo3CollectorExportFailing`、`Tempo3CollectorExportQueueBacklog`、`Tempo3IngestKafkaLagHigh`、`Tempo3IntakeStalled`、`Tempo3LiveStoreClientsLost`、`Tempo3LiveStoreCompleteQueueBacklog`、`Tempo3LiveStoreCompletionFailing`、`Tempo3LiveStoreFlushFailing`、`Tempo3LiveStoreReplicationLag`、`Tempo3MetricsMissing`、`Tempo3PodCrashLooping`、`Tempo3PodNotReady`、`Tempo3QueryErrorRateHigh`、`Tempo3QueryLatencyHigh`、`Tempo3SpanDeliveryDivergence`、`Tempo3SpanRefused`、`Tempo3StorageBackendConnectFailing`、`Tempo3TargetDown`

**prometheus-general.rules**（3）：`InfoInhibitor`、`TargetDown`、`Watchdog`

**prometheus-etcd**（13）：`etcdDatabaseHighFragmentationRatio`、`etcdDatabaseQuotaLowSpace`、`etcdExcessiveDatabaseGrowth`、`etcdGRPCRequestsSlow`、`etcdHighCommitDurations`、`etcdHighFsyncDurations`、`etcdHighNumberOfFailedGRPCRequests`、`etcdHighNumberOfFailedProposals`、`etcdHighNumberOfLeaderChanges`、`etcdInsufficientMembers`、`etcdMemberCommunicationSlow`、`etcdMembersDown`、`etcdNoLeader`

**prometheus-kubernetes-apps**（17）：`KubeContainerWaiting`、`KubeDaemonSetMisScheduled`、`KubeDaemonSetNotScheduled`、`KubeDaemonSetRolloutStuck`、`KubeDeploymentGenerationMismatch`、`KubeDeploymentReplicasMismatch`、`KubeDeploymentRolloutStuck`、`KubeHpaMaxedOut`、`KubeHpaReplicasMismatch`、`KubeJobFailed`、`KubeJobNotCompleted`、`KubePdbNotEnoughHealthyPods`、`KubePodCrashLooping`、`KubePodNotReady`、`KubeStatefulSetGenerationMismatch`、`KubeStatefulSetReplicasMismatch`、`KubeStatefulSetUpdateNotRolledOut`

**prometheus-kubernetes-resources**（8）：`CPUThrottlingHigh`、`KubeCPUOvercommit`、`KubeCPUQuotaOvercommit`、`KubeMemoryOvercommit`、`KubeMemoryQuotaOvercommit`、`KubeQuotaAlmostFull`、`KubeQuotaExceeded`、`KubeQuotaFullyUsed`

**prometheus-kubernetes-system**（2）：`KubeClientErrors`、`KubeVersionMismatch`

**prometheus-kubernetes-system-apiserver**（5）：`KubeAPIDown`、`KubeAPITerminatedRequests`、`KubeAggregatedAPIDown`、`KubeAggregatedAPIErrors`、`KubeClientCertificateExpiration`

**prometheus-kubernetes-system-kubelet**（13）：`KubeNodeEviction`、`KubeNodeNotReady`、`KubeNodePressure`、`KubeNodeReadinessFlapping`、`KubeNodeUnreachable`、`KubeletClientCertificateExpiration`、`KubeletClientCertificateRenewalErrors`、`KubeletDown`、`KubeletPlegDurationHigh`、`KubeletPodStartUpLatencyHigh`、`KubeletServerCertificateExpiration`、`KubeletServerCertificateRenewalErrors`、`KubeletTooManyPods`

**prometheus-kube-state-metrics**（4）：`KubeStateMetricsListErrors`、`KubeStateMetricsShardingMismatch`、`KubeStateMetricsShardsMissing`、`KubeStateMetricsWatchErrors`

**prometheus-kubernetes-storage**（3）：`KubePersistentVolumeErrors`、`KubePersistentVolumeFillingUp`、`KubePersistentVolumeInodesFillingUp`

**prometheus-node-exporter**（21）：`NodeBondingDegraded`、`NodeCPUHighUsage`、`NodeClockNotSynchronising`、`NodeClockSkewDetected`、`NodeDiskIOSaturation`、`NodeFileDescriptorLimit`、`NodeFilesystemAlmostOutOfFiles`、`NodeFilesystemAlmostOutOfSpace`、`NodeFilesystemFilesFillingUp`、`NodeFilesystemSpaceFillingUp`、`NodeHighNumberConntrackEntriesUsed`、`NodeMemoryHighUtilization`、`NodeMemoryMajorPagesFaults`、`NodeNetworkReceiveErrs`、`NodeNetworkTransmitErrs`、`NodeRAIDDegraded`、`NodeRAIDDiskFailure`、`NodeSystemSaturation`、`NodeSystemdServiceCrashlooping`、`NodeSystemdServiceFailed`、`NodeTextFileCollectorScrapeError`

**prometheus-node-network**（1）：`NodeNetworkInterfaceFlapping`

**prometheus-alertmanager.rules**（7）：`AlertmanagerClusterCrashlooping`、`AlertmanagerClusterDown`、`AlertmanagerClusterFailedToSendAlerts`、`AlertmanagerConfigInconsistent`、`AlertmanagerFailedReload`、`AlertmanagerFailedToSendAlerts`、`AlertmanagerMembersInconsistent`

**prometheus-prometheus**（23）：`PrometheusBadConfig`、`PrometheusDuplicateTimestamps`、`PrometheusErrorSendingAlertsToAnyAlertmanager`、`PrometheusErrorSendingAlertsToSomeAlertmanagers`、`PrometheusHighQueryLoad`、`PrometheusKubernetesListWatchFailures`、`PrometheusLabelLimitHit`、`PrometheusMissingRuleEvaluations`、`PrometheusNotConnectedToAlertmanagers`、`PrometheusNotIngestingSamples`、`PrometheusNotificationQueueRunningFull`、`PrometheusOutOfOrderTimestamps`、`PrometheusRemoteStorageFailures`、`PrometheusRemoteWriteBehind`、`PrometheusRemoteWriteDesiredShards`、`PrometheusRuleFailures`、`PrometheusSDRefreshFailure`、`PrometheusScrapeBodySizeLimitHit`、`PrometheusScrapeSampleLimitHit`、`PrometheusTargetLimitHit`、`PrometheusTargetSyncFailure`、`PrometheusTSDBCompactionsFailing`、`PrometheusTSDBReloadsFailing`

**prometheus-prometheus-operator**（8）：`PrometheusOperatorListErrors`、`PrometheusOperatorNodeLookupErrors`、`PrometheusOperatorNotReady`、`PrometheusOperatorReconcileErrors`、`PrometheusOperatorRejectedResources`、`PrometheusOperatorStatusUpdateErrors`、`PrometheusOperatorSyncFailed`、`PrometheusOperatorWatchErrors`

**其余单条规则组**：`ConfigReloaderSidecarErrors`（config-reloaders）、`KubeAPIErrorBudgetBurn`（apiserver-slos，4 档窗口）、`KubeControllerManagerDown`、`KubeProxyDown`、`KubeSchedulerDown`

---

# 附录 C：命令与 API 速查

### C.1 查询 API

```bash
P=http://10.111.41.17:9090

# 瞬时查询
curl -s "$P/api/v1/query" --data-urlencode 'query=up' | python3 -m json.tool

# 范围查询（start/end 支持 Unix 时间戳或 RFC3339）
curl -s "$P/api/v1/query_range" \
  --data-urlencode 'query=1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))' \
  --data-urlencode 'start=2026-10-06T00:00:00Z' \
  --data-urlencode 'end=2026-10-06T06:00:00Z' \
  --data-urlencode 'step=300'

# 序列匹配（拿到某条时间序列的全部数据点）
curl -s "$P/api/v1/series" --data-urlencode 'match[]=ALERTS{alertstate="firing"}'

# 标签值
curl -s "$P/api/v1/label/job/values"
curl -s "$P/api/v1/labels"
```

### C.2 规则与告警 API

```bash
curl -s $P/api/v1/rules     | python3 -m json.tool   # 全部规则 + health + lastError
curl -s $P/api/v1/alerts    | python3 -m json.tool   # pending/firing 告警
curl -s $P/api/v1/status/config | head -c 500        # 当前生效配置
curl -s $P/api/v1/status/runtimeinfo | python3 -m json.tool   # 保留策略等
curl -s $P/api/v1/status/buildinfo                    # 版本（实测 v3.11.2）
```

### C.3 Alertmanager API

```bash
A=http://10.111.199.90:9093
curl -s $A/api/v2/status | python3 -c 'import json,sys;print(json.load(sys.stdin)["config"]["original"])'  # 生效配置
curl -s $A/api/v2/alerts | python3 -m json.tool       # 当前告警
curl -s $A/api/v2/receivers                            # 接收器列表
curl -s $A/api/v2/silences                             # 静默列表
```

### C.4 规则管理

```bash
kubectl get prometheusrule -A                          # 41 个 CR
kubectl get prometheusrule -A -o json > /tmp/pr.json   # 全量导出
kubectl describe prometheusrule cluster-wide-alerts -n monitoring
kubectl apply -f my-rules.yaml
kubectl delete prometheusrule my-rules -n monitoring

# Operator 是否报错
kubectl logs -n monitoring deploy/prometheus-operator --tail=50 | grep -iE 'error|reject'
```

### C.5 本地校验

```bash
promtool check rules /tmp/all_rules.yml                # 语法
promtool test rules /tmp/demo_rules_test.yml           # 单元测试
promtool check config /etc/prometheus/prometheus.yml   # 抓取配置（主机遗留配置用）
promtool tsdb analyze /prometheus                      # TSDB 分析（进阶）
```

### C.6 导出与调试辅助

```bash
# 把某规则组导出成独立规则文件
python3 -c "
import json,yaml
d=json.load(open('/tmp/pr.json'))
out={'groups':[g for it in d['items'] if it['metadata']['name']=='cluster-wide-alerts'
     for g in it['spec']['groups']]}
yaml.safe_dump(out,open('/tmp/demo_rules.yml','w'),allow_unicode=True,sort_keys=False)"

# 统计 severity / for 分布
python3 -c "
import json;from collections import Counter
d=json.load(open('/tmp/pr.json'))
rules=[r for it in d['items'] for g in it['spec'].get('groups',[]) for r in g['rules'] if 'alert' in r]
print('total:',len(rules))
print('severity:',Counter(r.get('labels',{}).get('severity') for r in rules))
print('for:',Counter(str(r.get('for')) for r in rules))"
```

---

# 附录 D：术语表

| 术语 | 含义 |
|---|---|
| **指标 (metric)** | 带名字的时序数据，如 `node_cpu_seconds_total` |
| **标签 (label)** | 指标的维度，`{k="v"}` 形式，用于筛选与聚合 |
| **序列 (series)** | 指标名 + 一组唯一标签值 = 一条时间序列 |
| **Counter** | 只增不减的计数器（可因重启归零，称 reset） |
| **Gauge** | 可增可减的瞬时量（温度、内存、剩余空间） |
| **Histogram** | 分桶计数（`_bucket`/`_sum`/`_count`），可算分位数 |
| **Range Vector** | 区间向量：一段时间内的多个样本，写法 `[5m]` |
| **Instant Vector** | 即时向量：每个序列的最新一个值（默认查询类型） |
| **Scalar** | 标量：单个数字 |
| **PromQL** | Prometheus 查询语言 |
| **Recording Rule** | 录制规则：把查询结果存成新指标（名含冒号） |
| **Alerting Rule** | 告警规则：表达式持续为真超过 `for` 即 firing |
| **`for`** | 告警从 Pending 转 Firing 所需的持续时间 |
| **Pending / Firing / Resolved** | 告警的三个状态：观察中 / 触发中 / 已恢复 |
| **`up`** | Prometheus 合成指标，1=抓取成功，0=失败 |
| **`absent()`** | 选择器无匹配时返回 1 的函数，用于"监控缺失" |
| **`rate` / `increase`** | 区间内平均每秒增量 / 总增量（自动处理 counter reset） |
| **`histogram_quantile`** | 由 `_bucket` 插值计算分位数 |
| **`predict_linear`** | 线性回归外推，用于"多久之后会爆" |
| **`group_left/right`** | 向量匹配时的多对一/一对多标签继承 |
| **Scrape Interval** | 抓取周期，本集群 30s |
| **Evaluation Interval** | 规则求值周期，本集群 30s |
| **Retention** | 数据保留期，本集群 15d / 25GiB |
| **PrometheusRule** | Operator 的 CRD，规则的 Kubernetes 化载体 |
| **Alertmanager** | 告警去重、分组、抑制、静默、路由的独立组件 |
| **Group / Inhibit / Silence** | 分组（同类合并）/ 抑制（大告警压小告警）/ 静默（临时屏蔽） |
| **Receiver** | 通知出口（邮件、Webhook、企业微信等） |
| **SLO / SLI / Error Budget** | 服务等级目标 / 指标 / 错误预算（1 - SLO） |
| **Burn Rate** | 错误预算燃烧速度，1.0 = 按 30 天计划持续刚好烧光 |
| **Flapping** | 状态反复横跳（up/down、Ready/NotReady） |
| **Runbook** | 告警处置手册，通常放在 `runbook_url` 注解里 |

---

## 结语：三条最值得记住的原则

1. **先 Graph、后告警** —— 任何表达式先裸跑，确认"正常为空、故障有值"，再包装成规则。
2. **每条告警都要能 Resolved** —— 想清楚它怎么消失；想不清楚，就是在制造告警疲劳。
3. **告警的质量比数量重要** —— 本集群 235 条规则里，真正需要人管的只有 10 条 firing，其中还有 1 条误报；
   **把误报修掉、把哑告警点亮，比再加 50 条规则更有价值。**

---

*本教程基于 rocky9-prod 集群真实环境编写，数据快照 2026-10-06 13:52 CST。*
*涉及的密码、Token 均已脱敏；文中所有查询结果可在集群内复现。*
*配套文件：`/tmp/demo_rules.yml`（真实规则导出）、`/tmp/demo_rules_test.yml`（已通过的单元测试）。*
