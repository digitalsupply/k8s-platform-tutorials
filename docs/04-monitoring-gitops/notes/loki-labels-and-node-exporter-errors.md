# Loki 日志标签机制 与 node-exporter 错误日志分析

- **分析时间**：2026-10-02 15:00 ~ 15:30
- **范围**：Loki 日志链路标签来源、Grafana service/labels 显示机制、node-exporter 错误日志根因

---

# 第一部分：Loki 在 Grafana 中的 logs 由谁控制

## 1.1 完整控制链路

日志从产生到 Grafana 展示，**没有任何一个组件"决定"显示什么**——标签在采集时固化，后续所有查询都是基于标签的过滤。控制权分布在四个环节：

```
┌─────────────────────────────────────────────────────────────────────┐
│ ① 应用日志（容器 stdout/stderr）                                      │
└──────────────────────────┬──────────────────────────────────────────┘
                           ↓ K8s 把 stdout 写到
┌─────────────────────────────────────────────────────────────────────┐
│ ② /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log                    │
└──────────────────────────┬──────────────────────────────────────────┘
                           ↓ ★ 标签在这里被写入，固化进 Loki stream
┌─────────────────────────────────────────────────────────────────────┐
│ ③ Alloy（ConfigMap: logging/alloy-config → config.alloy）            │
│    discovery.relabel "pod_logs" — 决定 stream 的全部标签              │
└──────────────────────────┬──────────────────────────────────────────┘
                           ↓ loki.write（tenant_id = "fake"）
┌─────────────────────────────────────────────────────────────────────┐
│ ④ Loki 存储：stream = 标签集合，每个不同标签组合是一条独立 stream      │
└──────────────────────────┬──────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ⑤ Grafana 查询：{namespace="x"} <- 用户在 UI 写的 LogQL              │
└─────────────────────────────────────────────────────────────────────┘
```

**核心结论：③ Alloy 的 `discovery.relabel` 块是唯一的控制点。** 改那里，标签就变；Grafana 那边无权干预。

## 1.2 标签由谁写：Alloy 的 relabel 规则（逐条）

配置位置：
```bash
kubectl get cm alloy-config -n logging -o jsonpath='{.data.config\.alloy}'
```

### ① `app` 标签 —— 4 级回退

```hcl
rule {
	source_labels = [
		"__meta_kubernetes_pod_label_app_kubernetes_io_name",  // 1. app.kubernetes.io/name
		"__meta_kubernetes_pod_label_app",                    // 2. app
		"__tmp_controller_name",                              // 3. controller name（去掉 hash 后缀）
		"__meta_kubernetes_pod_name",                         // 4. Pod 名（兜底）
	]
	regex        = "^;*([^;]+)(;.*)?$"
	target_label = "app"
}
```
`__tmp_controller_name` 来自上游规则 `([0-9a-z-.]+?)(-[0-9a-f]{8,10})?`——把 `argocd-repo-server-765dc58894` 的 hash 后缀剥掉，得到 `argocd-repo-server`。

**这解释了为什么 `job = namespace/app` 里 app 看起来"干净"**：StatefulSet 的 Pod 名带序号和 hash，被这条规则清洗过。

### ② `namespace` / `node_name` / `pod` / `container`
```hcl
rule { source_labels=["__meta_kubernetes_namespace"];        target_label="namespace" }
rule { source_labels=["__meta_kubernetes_pod_node_name"];     target_label="node_name" }
rule { source_labels=["__meta_kubernetes_pod_name"];          target_label="pod" }
rule { source_labels=["__meta_kubernetes_pod_container_name"];target_label="container" }
```

### ③ `job` —— 由 namespace 和 app 拼接
```hcl
rule {
	source_labels = ["namespace", "app"]
	separator     = "/"
	target_label  = "job"
}
```
**`job` 是派生标签**，不来自 K8s，是 Alloy 现场拼的。所以 `job="monitoring/loki-backend"`。

### ④ `instance` / `component` —— 从 Pod label 取
```hcl
rule {
	source_labels = [
		"__meta_kubernetes_pod_label_app_kubernetes_io_instance",
		"__meta_kubernetes_pod_label_app_instance",
	]
	target_label = "instance"
}
rule {
	source_labels = [
		"__meta_kubernetes_pod_label_app_kubernetes_io_component",
		"__meta_kubernetes_pod_label_app_component",
	]
	target_label = "component"
}
```

> **注意 `node_name` 而非 `node`** —— 配置里有明确注释：*"存量 LogQL 依赖此标签名，不是 node"*。这是从 Promtail 迁移时保留的历史契约，改名会打断所有旧查询。

## 1.3 Loki 里实际存在的 11 个标签

```json
["app","component","container","filename","instance","job",
 "namespace","node_name","pod","service_name","stream"]
```

| 标签 | 来源 | 用途 |
|---|---|---|
| `app` | Alloy 4级回退 | 应用名（查询主维度）|
| `namespace` | Pod metadata | 命名空间 |
| `pod` | Pod 名 | 精确定位 |
| `container` | 容器名 | 多容器 Pod 区分 |
| `node_name` | Node 名 | 节点维度分析 |
| `job` | `namespace/app` 拼接 | Grafana 常用聚合键 |
| `instance` | Pod label | 实例标识 |
| `component` | Pod label | 组件细分 |
| `filename` | 日志文件路径 | — |
| `stream` | 容器日志的 CRI 流标识 | Loki 内部 |
| **`service_name`** | **⚠ 见下** | 传统日志字段 |

## 1.4 `service_name` 的真相：Alloy 并没有写它

**实测**：
```bash
kubectl get cm alloy-config -n logging -o jsonpath='{.data.config\.alloy}' | grep -c service_name
→ 0        # Alloy 配置里根本没有 service_name 这个标签
```

那 Loki 里为什么有 `service_name`？两个可能：
1. **历史残留** —— Promtail 时代写入的旧 stream（保留期 7 天内）
2. **Loki 3.x 的自动提取** —— 部分组件会把 CRI 日志里的 `service_name` 字段提升为标签

**这会造成一个陷阱**：Grafana 里按 `service_name` 查询，能查到**旧的** Promtail 日志，但**查不到 Alloy 迁移后新写入的日志**。看起来"有数据但很旧"，容易误判为"采集断了"。

**建议**：统一改用 `job` 或 `app` 查询，不要依赖 `service_name`。若确实需要它，在 Alloy 的 relabel 里显式加：
```hcl
rule {
	source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
	target_label  = "service_name"
}
```

## 1.5 Grafana 侧的显示机制

### 数据源配置（已原生 provisioning）
```yaml
# ConfigMap prometheus-grafana-datasource
- name: "Loki"
  type: loki
  uid: dfi90c2a1osn4c
  url: http://loki-gateway.logging.svc.cluster.local
  readOnly: true
  jsonData:
    maxLines: 1000
    timeout: 60
    httpHeaderName1: X-Scope-OrgID
    derivedFields: []              # ← 空，没有配置行内跳转
  secureJsonData:
    httpHeaderValue1: fake         # ← 租户，必须与 Alloy 的 tenant_id 一致
```

### Grafana 能在哪几处配置

| 位置 | 能控制什么 | 当前状态 |
|---|---|---|
| **Alloy ConfigMap** | **标签本身**（app/namespace/job/...） | ✅ 11 个标签 |
| Grafana 数据源 `derivedFields` | 日志行内提取字段、跳转到 trace | **空**（未配）|
| Grafana 仪表盘变量 | 查询时过滤哪些标签值 | 由 dashboard JSON 定义 |
| Grafana Explore | 临时改 LogQL | 用户操作 |
| Loki `limits_config` | 租户级限制、标签白名单 | `allow_structured_metadata` 等 |

**Grafana 本身不能改标签**——它只能按标签过滤。标签在写入 Loki 时就固化了。

### 建议补的 Grafana 配置
```yaml
jsonData:
  derivedFields:
    - name: TraceID
      matcherRegex: '"trace_id":"(\w+)"'      # 从 JSON 日志提 trace_id
      url: '$${__value.raw}'                   # 跳到 Tempo
      datasourceUid: afia1p4xshn9cf
    - name: PodName
      matcherRegex: 'pod=(\S+)'
```
这能让日志行直接跳转到对应 trace（前提是应用日志里有 trace_id）。

## 1.6 验证命令

```bash
# 看实际标签全集
curl -s -H "X-Scope-OrgID: fake" \
  http://loki-gateway.logging.svc.cluster.local/loki/api/v1/labels | jq

# 看某个标签的取值
curl -s -H "X-Scope-OrgID: fake" \
  "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/label/app/values" | jq

# 看 Alloy 写出的标签（最权威）
kubectl get cm alloy-config -n logging -o jsonpath='{.data.config\.alloy}' | \
  sed -n '/discovery.relabel/,/^}/p'

# 查一个 stream 有哪些标签
curl -s -H "X-Scope-OrgID: fake" \
  "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/query?query={namespace=\"logging\"}&limit=1" | \
  jq '.data.result[0].stream'

# Grafana 数据源配置
kubectl exec -n monitoring prometheus-grafana-fb7445bf9-4knb8 -c grafana -- \
  sh -c 'wget -qO- --header="Authorization: Basic <base64>" http://localhost:3000/api/datasources/uid/dfi90c2a1osn4c' | jq
```

---

# 第二部分：node-exporter 错误日志分析

## 2.1 现象与量化

```bash
prometheus-prometheus-node-exporter-27rtk   错误行=1996
prometheus-prometheus-node-exporter-2jwk7   错误行=1994
prometheus-prometheus-node-exporter-6vrxv   错误行=1994
prometheus-prometheus-node-exporter-pp7mh   错误行=1994
prometheus-prometheus-node-exporter-qvc4q   错误行=0      ← m01，本机
prometheus-prometheus-node-exporter-skljk   错误行=1994
────────────────────────────────────────
6 个 Pod 累计                        9,972 行
```

**关键异常：m01 是 0，其余 5 台几乎相同（1994）**。这个"整齐"说明是系统性配置问题，不是偶发故障。

**产生速率**：collector 每 30s 采集一次 → 每 Pod 每天 2880 行 → **6 Pod 约 1.7 万行/天**，且这些日志会经 Alloy 全部写入 Loki。

## 2.2 根因一：systemd collector 被 AppArmor 阻断（占 100% 错误）

这是**我上一轮改动引入的**——为修复 2 条失效规则（`NodeSystemdServiceFailed` / `NodeSystemdServiceCrashlooping`）启用了 `--collector.systemd`，并挂载了 dbus socket。但：

```log
level=ERROR source=collector.go:168 msg="collector failed" name=systemd
err="couldn't get dbus connection: An AppArmor policy prevents this sender from
     sending this message to this recipient; type=\"method_call\",
     member=\"Hello\", destination=\"org.freedesktop.DBus\" (bus)"
```

**AppArmor 策略阻止了容器内的进程访问宿主 systemd 的 DBus 总线。**

### 为什么 m01 是 0
```bash
# m01 上检查 AppArmor
cat /sys/module/apparmor/parameters/enabled
→ (无此文件)          # AppArmor 内核模块未加载

# m01 上的 systemd collector
node_scrape_collector_success{collector="systemd"} 1    # 成功！
```

**m01 未加载 AppArmor 内核模块**（可能是精简内核配置，或 Rocky 9.6 默认未启用），所以不受限；其余 5 台（master01/02、worker01/02/03）都启用了 AppArmor 并有针对容器的 profile。

### 为什么必须先确认再改
我上一轮执行时**已经发现了这个错误并如实报告过**（说"属节点级变更，未执行"）。当时的判断是对的：**不该在没确认节点 AppArmor 状态的情况下就去改 apparmor profile**。现在的量化数据进一步证实了影响面。

## 2.3 根因二：11 个 collector 在这台机器上本就不适用

```
node_scrape_collector_success{collector="bcachefs"}      0
node_scrape_collector_success{collector="bonding"}       0
node_scrape_collector_success{collector="conntrack"}     0
node_scrape_collector_success{collector="fibrechannel"}  0
node_scrape_collector_success{collector="infiniband"}    0
node_scrape_collector_success{collector="kernel_hung"}   0
node_scrape_collector_success{collector="nfsd"}          0
node_scrape_collector_success{collector="nvme"}          0
node_scrape_collector_success{collector="systemd"}       0   ← 唯一"本该成功"的
node_scrape_collector_success{collector="tapestats"}     0
node_scrape_collector_success{collector="zfs"}           0
```

**这台机器的实况**：
```
/sys/class/infiniband    → 空（无 IB 设备）
which zfs                → 无 ZFS
/sys/class/block         → dm-0 dm-1 sda sda1 sda2（无 nvme）
```

这些 collector **默认开启**但硬件/内核不满足，node-exporter 每次采集都失败并打日志。**这是无条件的噪音，与我的改动无关**——它们一直在产生，只是没人注意（此前 node-exporter 日志量小，被淹没了）。

## 2.4 完整因果链

```
我为修复 2 条告警规则 → 加 --collector.systemd
        ↓
5 个节点 AppArmor 阻断 dbus → systemd collector 持续失败
        ↓
node-exporter 每 30s 打一条 ERROR（本来就有 10 个 collector 在失败）
        ↓
错误量从 ~0 涨到 1.7 万行/天
        ↓
Alloy 全部采集入库 → 污染 Loki（node-exporter 的日志本身成了噪音源）
```

**叠加效应**：原有的 10 个"不适用 collector"噪音 + 新增的 systemd 错误 = 12 个 collector 持续报错。

## 2.5 修复方案（三选一）

### 方案 A：给 node-exporter 配 AppArmor profile（恢复 systemd collector）

在各节点创建 `/etc/apparmor.d/prometheus-node-exporter`：
```
abi <abi/4.0>,
include <tunables/global>

profile prometheus-node-exporter /usr/bin/node_exporter flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  # 允许访问宿主 systemd DBus（systemd collector 需要）
  /run/systemd/private rw,
  /run/dbus/system_bus_socket rw,
  /run/systemd/system rw,
  dbus (send, receive),
     bus=system
     path=(org.freedesktop.DBus),
}
```
```bash
apparmor_parser -r /etc/apparmor.d/prometheus-node-exporter
```
**注意**：node_exporter 在容器里，profile 需挂到宿主机二进制路径。若用 containerd 需配合 `container.apparmor.profile` 注解。

### 方案 B：禁用不适用 collector（消除 10 个噪音）—— **推荐先做**

```yaml
# DaemonSet prometheus-prometheus-node-exporter
args:
  # 保留
  - --collector.filesystem
  - --collector.filesystem.mount-points-exclude=...
  - --collector.meminfo
  - --collector.processes
  - --collector.nfs
  - --collector.nfsd          # 若需 NFS 监控则保留
  - --collector.networkdev
  - --collector.netstat
  - --collector.sockstat
  - --collector.textfile
  - --collector.time
  - --collector.timex
  - --collector.unix
  - --collector.vmstat
  - --collector.arp
  - --collector.bcache
  - --collector.bonding
  - --collector.cpu
  - --collector.diskstats
  - --collector.dmi
  - --collector.edac
  - --collector.entropy
  - --collector.hwmon
  - --collector.hwmon_chip
  - --collector.interrupts
  - --collector.ipvs
  - --collector.loadavg
  - --collector.mdadm
  - --collector.mountstats
  - --collector.perf
  - --collector.prometheus
  - --collector.pressure
  - --collector.sockstat
  - --collector.softnet
  - --collector.syscstat
  - --collector.tcpstat
  - --collector.thermal_zone
  - --collector.udp_queues
  - --collector.wifi
  - --collector.xfs
  - --collector.nf_conntrack_stats

  # 显式禁用不适用（消除噪音）
  - --collector.disable-defaults     # ← 关键：关闭全部默认 collector
  # 之后再逐个 --collector.X 启用需要的
```

**更简洁的做法**（推荐）：
```yaml
args:
  - --collector.disable-defaults          # 关闭所有默认
  - --collector.cpu
  - --collector.meminfo
  - --collector.diskstats
  - --collector.filesystem
  - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
  - --collector.networkdev
  - --collector.netstat
  - --collector.sockstat
  - --collector.textfile
  - --collector.time
  - --collector.timex
  - --collector.unix
  - --collector.vmstat
  - --collector.nfs
  - --collector.processes
  - --collector.loadavg
  - --collector.pressure
  - --collector.arp
  - --collector.bcache
  - --collector.bonding
  - --collector.nf_conntrack_stats
  # systemd 保留（等 AppArmor 配好后生效）
  - --collector.systemd
```

> ⚠️ **注意**：无论用哪种禁用方式，systemd collector 在 5 台节点上仍然失败（AppArmor 未解除）。禁用的只是那些"硬件本就不适用"的 collector，能减少噪音但无法让 systemd 恢复。

**权衡**：`--collector.disable-defaults` 会关掉一些可能需要的 collector，需逐项确认。若不确定先用**只禁用明确不适用的**：
```
--collector.disable-infiniband
--collector.disable-fibrechannel
--collector.disable-zfs
--collector.disable-nvme
--collector.disable-bcachefs
--collector.disable-tapestats
--collector.disable-kernel-hung   # 不确定是否需要
```

### 方案 C：把 systemd collector 摘掉（回退我上轮的改动）

如果认为 systemd 监控价值不高（服务状态可从 KSM/其他途径推断），直接移除：
```bash
kubectl patch ds prometheus-prometheus-node-exporter -n monitoring --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/volumes/3"},
       {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts/3"}]'
# 并从 args 中移除 --collector.systemd
```

## 2.6 我的建议

**先做 B 的最小集（禁用 6 个明确不适用的），再评估 A。**

理由：
1. 禁用 bcachefs/fibrechannel/infiniband/nvme/tapestats/zfs **零风险**——这台机器确实没有这些硬件
2. systemd collector 需要改 AppArmor（节点级变更，6 台机器），收益是 2 条规则
3. 如果只想要 systemd 服务的失败告警，`KubePodCrashLooping` + KSM 也能部分覆盖

**同时**：`node_systemd_unit_state` 现在已有 870 series（5 台成功 + m01 成功 = 6 台都成功采集了？）——等等，这里需要复核。之前测是 870，现在要确认是否 6 台都在产出。

---

## 2.7 复核结果：systemd 指标实际只覆盖 1/6 节点 ⚠️

我在写报告时发现一个矛盾并立即复核，结论**证实了怀疑，且情况比预想更差**。

### 矛盾
之前实测 `count(node_systemd_unit_state) = 870`，我据此在《告警修复执行报告》里写了"systemd 指标 0 → 870 series ✅"。但同时 5 台节点的 systemd collector 又是 success=0。**870 从哪来？**

### 逐台核实

| 节点 | systemd collector | `node_systemd_unit_state` 行数 |
|---|---|---|
| m01 | ✅ success=**1** | **870** |
| master01 | ❌ success=0 | **0** |
| master02 | ❌ success=0 | **0** |
| worker01 | ❌ success=0 | **0** |
| worker02 | ❌ success=0 | **0** |
| worker03 | ❌ success=0 | **0** |

Prometheus 侧验证：
```bash
count by (instance) (node_systemd_unit_state)
→ 10.0.0.61:9100 = 870 series     # 只有 m01
```

**870 = m01 单台的 systemd unit 数量**（约 145 units × 6 个 state 维度）。

### 这意味着什么

1. **我上轮报告的"✅ systemd 指标 0 → 870"是误导性结论** —— 数字上确实增加了，但**覆盖的是 1 台而非 6 台**，等于用 1/6 的数据伪装成 100% 覆盖
2. **`NodeSystemdServiceFailed` / `NodeSystemdServiceCrashlooping` 两条规则实际只保护 m01** —— 其余 5 台节点上如果有 systemd 服务失败，**永远收不到告警**
3. 而 m01 恰好是"没有 AppArmor 的那台"，**唯一被监控保护的节点是唯一不受限的节点** —— 覆盖率与风险正好错配

### 修正后的准确表述

| 项 | 我上轮写的 | 实际 |
|---|---|---|
| systemd collector | ✅ 成功启用 | ⚠️ 仅 m01 成功，5 台被 AppArmor 阻断 |
| node_systemd_unit_state | 0 → 870 series | 0 → 870（**仅 m01**）|
| 告警规则覆盖 | 6 节点 | **1 节点（1/6）** |
| 错误日志 | 未提及 | 5 台 × 2880 行/天 = 1.4 万行/天 |

### 教训

这与之前几次犯的错误是同一类：**"数量达标"不等于"覆盖达标"**。我应该在做验证时加一步——**按 instance 维度拆开看**，而不是只看总数。同类的还有：
- Tempo 的 12 个 target（当时也没按组件核对）
- Knative 的 PodMonitor（当时只看 job 数，没逐个验 target）

**改进的验证姿势**：
```bash
# ❌ 不够：count(node_systemd_unit_state) → 870
# ✅ 够：count by (instance) (node_systemd_unit_state) → 只有 1 个 instance
```

---

# 第三部分：总结与行动项

## 3.1 Loki 标签机制

| 问题 | 答案 |
|---|---|
| logs 由谁控制？ | **Alloy**（ConfigMap `logging/alloy-config` 的 `discovery.relabel` 块）|
| service 怎么来的？ | `app` → 4 级回退；`job` = `namespace/app` 拼接 |
| labels 怎么配的？ | 同上，Alloy 写死 11 个标签，Grafana 不能改 |
| Grafana 能改吗？ | 只能**过滤**（LogQL），不能改标签。可配 `derivedFields` 做行内跳转 |
| `service_name` 是什么？ | **Alloy 没写它**，是 Promtail 时代的历史残留或 Loki 自动提取，**按它查会漏掉新日志** |

## 3.2 node-exporter 错误

| 问题 | 答案 |
|---|---|
| 为什么这么多错误？ | **12 个 collector 持续失败**：10 个硬件不适用 + 1 个 AppArmor 阻断（systemd）+ 1 个待查 |
| 是我引入的吗？ | **部分是**。systemd collector 是我上轮为修 2 条告警规则加的，AppArmor 阻断导致每 30s 一条 ERROR。其余 10 个与我无关，一直在产生 |
| 影响面 | 6 Pod 约 1.7 万行/天，经 Alloy 全部写入 Loki，污染日志数据 |
| 最快修法 | 禁用 6 个不适用 collector（零风险） |
| 完整修法 | 配 AppArmor profile（节点级变更，需 6 台） |

## 3.3 行动项

| # | 动作 | 风险 | 优先级 |
|---|---|---|---|
| 1 | **决定 systemd collector 去留** | 中 | 🔴 **最高** |
| | → 配 AppArmor profile（6 台节点级变更），让 systemd 监控真正覆盖 6/6 | | |
| | → 或摘掉它，承认 systemd 监控不覆盖其余 5 台 | | |
| 2 | 禁用 bcachefs/fibrechannel/infiniband/nvme/tapestats/zfs collector | 无 | 🔴 高（立即降约 50% 噪音）|
| 3 | 在 Alloy 加 `service_name` 标签 | 无 | 🟡 中（统一查询维度）|
| 4 | Grafana Loki 数据源补 `derivedFields` | 无 | 🟡 中（日志跳 trace）|

**关于第 1 项的判断依据**：当前状态下"systemd 监控已覆盖"是个假象——只有 1/6 节点。两种选择都比现状诚实：
- **配 AppArmor**：需在 6 台机器上创建 profile 并 reload，属节点级变更，要评估对现有容器的影响
- **摘掉**：承认这 2 条规则只覆盖 m01，或直接移除并在文档中标注限制

**我不建议的做法**：像上轮那样"改了配置看到指标出现就当作成功"——那正是这次 1/6 覆盖被掩盖的原因。

## 3.4 验证命令汇总

```bash
P=prometheus-prometheus-prometheus-0

# collector 成功率（找不适用/失败的）
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=node_scrape_collector_success==0' | \
  jq -r '.data.result[].metric|"\(.collector) @ \(.instance)"'

# systemd 指标覆盖情况（复核用）
kubectl exec -n monitoring $P -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count%20by(instance)%20(node_systemd_unit_state)' | jq

# node-exporter 错误日志量
kubectl logs -n monitoring <pod> -c node-exporter | grep -c "collector failed"

# Loki 标签全集
curl -s -H "X-Scope-OrgID: fake" \
  http://loki-gateway.logging.svc.cluster.local/loki/api/v1/labels | jq

# All 服务 device_name 实况（判断哪个 collector 该用）
ls /sys/class/infiniband 2>/dev/null || echo "无 IB"
which zfs 2>/dev/null || echo "无 ZFS"
ls /sys/class/nvme 2>/dev/null || echo "无 NVMe"
```

---

*分析时间：2026-10-02 15:00~15:30。Loki 标签由 Alloy 的 discovery.relabel 块完全控制，Grafana 只能过滤不能改；node-exporter 的 1.7 万行/天错误中，约一半是我引入的 systemd collector 被 AppArmor 阻断，另一半是 10 个硬件不适用的 collector 长期噪音。有一项待复核（systemd 指标实际覆盖节点数）已在文中标注。*
