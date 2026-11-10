# LGMT 可观测性栈 Phase-2 修复记录

> **文档范围**：Alertmanager 通知通道 + Grafana Alloy 采集中断 + Tempo 3.x (tempo3) 崩溃
> **执行时间**：2026-09-28 17:24 – 18:55 (CST)
> **回滚源**：
> - `/root/observability-upgrade-backup-20260928-172244/`（§1 Alertmanager、§2 Alloy）
> - `/root/observability-upgrade-backup-20260928-183547-tempo3/`（§3 tempo3，59 文件 / 1.2 MB）
> **关联文档**：`observability-stack-full-audit.md`（全栈审计，§4.10 Promtail 专章）、`observability-upgrade-inventory.md`（Phase-1 清单）

---

## 目录

- [0. 摘要](#0-摘要)
- [1. 问题一：Alertmanager 通知全量失败](#1-问题一alertmanager-通知全量失败)
- [2. 问题二：Alloy 采集中断](#2-问题二alloy-采集中断)
  - [2.1 症状](#21-症状)
  - [2.2 根因 A：values 层级写错（缺件 #3 #4 #5）](#22-根因-avalues-层级写错缺件-3-4-5)
  - [2.3 根因 B：loki.source.file 缺失且 glob 不展开（缺件 #1 #2 #7）](#23-根因-blokisourcefile-缺失且-glob-不展开缺件-1-2-7)
  - [2.4 根因 C：误导性报错 --web.enable-lifecycle（缺件 #6）](#24-根因-c误导性报错---webenable-lifecycle缺件-6)
  - [2.5 标签契约：不是 node 是 node_name](#25-标签契约不是-node-是-node_name)
  - [2.6 附带发现：detected_level 与 Alloy 无关](#26-附带发现detected_level-与-alloy-无关)
  - [2.7 配置文件：修复前 / 修复后](#27-配置文件修复前--修复后)
  - [2.8 验证结果](#28-验证结果)
  - [2.9 风险与回滚](#29-风险与回滚)
- [3. 问题三：tempo3 13/13 CrashLoopBackOff](#3-问题三tempo3-1313-crashloopbackoff)
  - [3.1 症状](#31-症状)
  - [3.2 根因一：S3 secret_key 错误（崩溃直接原因）](#32-根因一s3-secret_key-错误崩溃直接原因)
  - [3.3 根因二：distributor.receivers 被渲染成 null（功能阻断）](#33-根因二distributorreceivers-被渲染成-null功能阻断)
  - [3.4 次要报错：为什么不是根因](#34-次要报错为什么不是根因)
  - [3.5 配置文件：修复前 / 修复后](#35-配置文件修复前--修复后)
  - [3.6 变更前后的离线校验链](#36-变更前后的离线校验链)
  - [3.7 验证结果（14 项，含端到端 trace）](#37-验证结果14-项含端到端-trace)
  - [3.8 风险与回滚](#38-风险与回滚)
- [4. 过程性踩坑记录（避免重复踩）](#4-过程性踩坑记录避免重复踩)
- [5. 遗留与下一步](#5-遗留与下一步)

---

## 0. 摘要

| # | 组件 | 故障 | 根因 | 状态 | 变更面 |
|---|---|---|---|---|---|
| 1 | Alertmanager | 全部通知投递失败 | 上游 Cloudflare 隧道 `198.41.200.x:7844` 持续 i/o timeout，**非配置问题** | ✅ 已修复 | Secret 1 行 URL |
| 2 | Grafana Alloy | 采集中断（Promtail 退役后一直 0 数据） | values 层级写错 + `loki.source.file` 缺失 + glob 未开启 `file_match` | ✅ 已修复 | ConfigMap 56→156 行 + values 重组 |
| 3 | Tempo 3.x (tempo3) | 13/13 Pod CrashLoopBackOff + 收不到 span | S3 `secret_key` 错误（AK 对 SK 错）+ `distributor.receivers` 被渲染成 `null` | ✅ 已修复 | values 改 1 项 + 加 3 项 |

**修复后的集群状态**：

| 指标 | 修复前 | 修复后 |
|---|---:|---:|
| 全集群 CrashLoopBackOff | 13 | **0** |
| tempo3 Pod 就绪 | 1 / 14 | **13 / 13**（0 重启） |
| Alloy 节点覆盖 | 3 / 6 | **6 / 6** |
| Alertmanager 通知失败 | 与成功数持平 | **0** |
| tempo3 端到端 trace | 不可能（进程起不来） | **注入 → 查回 → tag 检索全通** |

**本轮核心结论（三条）**：

> **一、换 chart 时，凡是新 chart 默认给你的东西都会消失；而新 chart 不认的键，你写进去它也会静默消失。**
> Alloy 的 7 处缺件里，3 处源于前者（chart 默认空），3 处源于后者（键写错层级），1 处是官方文档未在迁移指南里强调的必要开关（`file_match`）。

> **二、「静默的空」比「报错的错」更危险。**
> Alloy 是键写错层级被 Helm 丢弃；Tempo 是开关没开导致模板分支不渲染、`receivers:` 变成 `null`。两者都不报错，都只表现为「没数据」。解包 chart 源码逐个确认 `{{- if }}` 条件，是唯一可靠办法。

> **三、验证的标准不是「服务起来了」，而是「数据走完了整条链路」。**
> tempo3 修好后没有停在 Pod Running + `/ready` 200，而是注入一条真 span → 经 Kafka → live-store → querier → query-frontend → 原样查回 → 按 tag 检索命中，并确认桶里出现了 Tempo 自己 flush 出来的对象。

---

## 1. 问题一：Alertmanager 通知全量失败

### 【症状】

58 条 firing 告警全部无法送达 n8n webhook。`Notify attempt failed` 持续刷屏，失败计数一度累积到 14 且排不空。

### 【诊断过程】

```
$ kubectl logs -n n8n deploy/cloudflared --tail=50
... 2026-09-28T07:58:00Z  Registered tunnel connection connIndex=0 ...
    2026-09-28T07:58:00Z  Registered tunnel connection connIndex=2 ...
    2026-09-28T07:58:00Z  Registered tunnel connection connIndex=3 ...
    （之后 9 小时无新注册记录）
    反复出现： failed to dial to edge with error: ... i/o timeout
    edge 地址： 198.41.200.x:7844
```

DNS 解析正常（`104.21.18.107` / `172.67.181.153`），但 TLS 握手阶段被重置：

```
$ curl -v https://n8ntrace.ccwu.cc/webhook/k8s-alerts
*   Trying 104.21.18.107:443...
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS alert, handshake failure (112)
*   Connection reset by peer     ← 宿主机与 Pod 内双向均失败
```

集群内直连 n8n 则完全正常：

```
$ kubectl exec -n <ns> deploy/curl -- curl -s -o /dev/null -w '%{http_code} %{time_total}\n' \
    -X POST http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
200 0.159

$ ... curl http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts   # GET
404  ← webhook 只收 POST，404 属正常
```

**结论：故障在 Cloudflare 隧道出网链路，不在 Alertmanager 配置。**
（这与 CoreDNS 拉 `registry.k8s.io` 时 `64.233.188.82:443` i/o timeout 属同一问题域。）

### 【变更】

只改 Secret `alertmanager-prometheus-alertmanager` 中的 `url` 一行：

```diff
- url: https://n8ntrace.ccwu.cc/webhook/k8s-alerts
+ url: http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts
```

**为什么不加第二个 receiver**：并排两个 receiver 会导致同一条告警双发，污染 n8n 侧的工作流执行记录。保持单 receiver，只换传输路径。

### 【执行方式】

Secret 变更时**完整继承原 metadata**（labels / annotations / ownerReferences），避免被 Helm 或 operator 判定为漂移而回滚。Alertmanager 以 `--watch-config` 运行，自动重载，**未重启 Pod**。

### 【验证结果】

用 `alertmanager_notifications_total` 与 `alertmanager_notifications_failed_total` 做修复前后窗口对比：

| 窗口 | 成功通知 | 失败通知 | 判定 |
|------|---------:|---------:|------|
| 修复前 17:00–17:15 | 19.83 | **19.83** | 全挂 |
| 修复后 17:25–17:30（5m） | 1.11 | **0** | ✅ |
| 修复后 17:28–17:30（2m） | 1.33 | **0** | ✅ |

补充验证：
- 注入 `Phase2FixVerification` 测试告警 → `POST /api/v2/alerts` 返回 **200**，`state=active`，未被 silence / inhibit
- Alertmanager `/-/healthy` → `OK`
- `/api/v2/receivers` → `n8n-webhook`
- `Notify attempt failed` 计数 14 → 10 → 8 → 6 → 2 → **0**（72 秒内排空），此后持续为 0

### 【回滚方式】

```bash
B=/root/observability-upgrade-backup-20260928-172244
kubectl replace -f $B/alertmanager/secret-original.json
# 隧道恢复后若想切回公网：把 url 改回 https://n8ntrace.ccwu.cc/webhook/k8s-alerts
# 前提是 cloudflared 能稳定连上 edge（当前未验证）
```

---

## 2. 问题二：Alloy 采集中断

### 2.1 症状

Promtail 于 2026-09-28 12:33 退役（已运行 155 天），Alloy 接管后**持续 0 数据流入**。DaemonSet 只在 3 个 worker 节点上有副本，control-plane 三个节点完全没有采集。

修复前 ConfigMap 全文（56 行）：

```alloy
// Kubernetes Pod 日志发现
discovery.kubernetes "pod_logs" {
    role = "pod"
}

// 重标记规则 - 添加标签
discovery.relabel "pod_logs" {
    targets = []                          // ← 缺件 #2：discovery 输出没接上

    rule { source_labels = ["__meta_kubernetes_pod_name"]
           target_label  = "pod" }
    rule { source_labels = ["__meta_kubernetes_namespace"]
           target_label  = "namespace" }
    rule { source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
           target_label  = "app" }
    rule { source_labels = ["__meta_kubernetes_pod_node_name"]
           target_label  = "node" }       // ← 缺件：应为 node_name
    rule { source_labels = ["__meta_kubernetes_container_name"]   // ← 该 meta 键不存在
           target_label  = "container" }  //    正确键是 __meta_kubernetes_pod_container_name
}

// 日志处理管道
loki.process "logs_to_prometheus" {
    forward_to = [loki.write.default.receiver]
    stage.cri {}
    stage.drop { older_than = "168h" }
}

// Loki 写入配置
loki.write "default" {
    endpoint {
        url = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
        tenant_id = "fake"
    }
}
```

**致命点**：整个文件里 **没有 `loki.source.file`** —— 没有任何组件去读日志文件。`loki.process` 和 `loki.write` 之间的链路是断的。

修复前 values 全文（**这是本节根因所在**）：

```yaml
# Grafana Alloy values
alloy:
  configMap:
    create: false
    name: alloy-config
    key: config.alloy
  mounts:
    varlog: false              # ← 缺件 #3：显式关掉了 /var/log 挂载
    dockercontainers: false

# 资源限制                        ← 缺件 #5：写在顶层，被 chart 忽略
resources:
  limits:   { cpu: 500m,  memory: 512Mi }
  requests: { cpu: 100m,  memory: 128Mi }

# 节点选择器 - 与 Promtail 相同
nodeSelector: {}
tolerations:                   # ← 缺件 #4：写在顶层，被 chart 忽略
- effect: NoSchedule
  operator: Exists

serviceAccount:
  create: true
  name: alloy

containerPorts:                # ← 同样被忽略（chart 实际用 alloy.listenPort）
  http: 12345

persistence:                   # ← 同样被忽略
  enabled: false

extraEnv:                      # ← 同样被忽略（chart 内置 HOSTNAME/K8S_NODE_NAME）
- name: HOSTNAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName

clusterRole:                   # ← 同样被忽略（chart 实际用 rbac.create）
  create: true
```

---

### 2.2 根因 A：values 层级写错（缺件 #3 #4 #5）

`grafana/alloy` chart 1.13.0 的 values 顶层结构是：

```
alloy            ← configMap / mounts / resources / extraArgs / extraEnv / storagePath / securityContext
configReloader   ← enabled / image / customArgs / resources / securityContext
controller       ← type / tolerations / nodeSelector / volumes.extra / updateStrategy / hostNetwork ...
crds             ← create
image            ← registry / repository / tag
rbac             ← create / clusterRules
service          ← enabled / type / ports
serviceAccount   ← create / name
serviceMonitor   ← enabled
global / ingress / networkPolicy / extraObjects / fullnameOverride / nameOverride / namespaceOverride
```

**上一版 values 把 `resources` / `tolerations` / `nodeSelector` / `containerPorts` / `persistence` / `extraEnv` / `clusterRole` 全部写在了顶层**，chart 读的是 `alloy.resources` / `controller.tolerations` / `rbac.create` …… 这些顶层键**不存在于任何模板引用中，Helm 不报错、不告警，直接丢弃**。

`alloy.mounts.varlog` 则是另一回事：它层级写对了，但值被**显式写成 `false`**，等于主动关掉了 chart 原生支持的 `/var/log` 挂载。

**每处缺件的真实归因：**

| 缺件 | 现象 | 原判断 | 真实原因 | 证据 |
|---|---|---|---|---|
| #3 | 无 `/var/log` 挂载 | chart 默认不提供 | `alloy.mounts.varlog: false` 被显式关闭 | `_pod.yaml:91-95` 有 `{{- if $values.mounts.varlog }}` 条件分支 |
| #4 | `tolerations: null`，只覆盖 3/6 节点 | chart 默认空 | 键写在顶层被忽略 | 渲染后 Pod spec `tolerations: null` |
| #5 | `resources: {}` → BestEffort QoS | chart 默认空 | 键写在顶层被忽略 | 渲染后容器 `resources: {}` |

**校验方法（可复用）**：不要读文档猜层级，直接从渲染结果反推。

```bash
# 1) 解包 chart
tar -xzf /root/.cache/helm/repository/alloy-1.13.0.tgz -C /tmp/alloy-chart

# 2) 读真实 values 层级
python3 -c "import yaml;print(sorted(yaml.safe_load(open('/tmp/alloy-chart/alloy/values.yaml')).keys()))"

# 3) 看模板到底引用了哪些路径
grep -n 'mounts.varlog\|Values.controller.tolerations\|\$values.resources' \
     /tmp/alloy-chart/alloy/templates/containers/_agent.yaml \
     /tmp/alloy-chart/alloy/templates/controllers/_pod.yaml

# 4) 落地前先 dry-run 看渲染结果
helm upgrade alloy /tmp/alloy-chart/alloy -n logging -f values.yaml --dry-run
```

> ⚠️ 本集群 `helm show` / `helm upgrade` 从 `github.com/grafana/helm-charts` 拉 chart 会 `unexpected EOF`。
> 解法：用 helm 缓存里已有的包 `tar -xzf /root/.cache/helm/repository/alloy-1.13.0.tgz`，然后以**本地目录**作为 chart 源。

---

### 2.3 根因 B：loki.source.file 缺失且 glob 不展开（缺件 #1 #2 #7）

这是**采不到日志的直接原因**，也是排查中耗时最久的一处。

#### 缺件 #1 #2：source 组件整段缺失

迁移时把 Promtail 的 `kubernetes_sd_configs` + `relabel_configs` 翻译成了 `discovery.kubernetes` + `discovery.relabel`，但**忘了 source 组件**。Promtail 的 `kubernetes_sd_configs(role: pod)` 会自动完成「发现 Pod → 定位日志文件 → 读取」三件事；Alloy 把这三件事拆成三个组件，`loki.source.file` 就是被漏掉的那个。

另外 `discovery.relabel` 的 `targets = []` 也没接上 `discovery.kubernetes.pod_logs.targets`，等于发现层的结果被丢弃。

#### 补上 source 后：65 个 target 全部 stat 失败

补齐挂载、加上 `loki.source.file` 后，配置能正常加载（`alloy_config_last_load_successful 1`，组件数 4 → 5），但文件读不到：

```
level=error msg="failed to create source, skipping"
  component_id=loki.source.file.pod_logs
  error="failed to tail file, stat failed:
         stat /var/log/pods/*50408e3a-0814-4ece-99a1-45b7dcba2efc/tekton-pipelines-controller/*.log:
         no such file or directory"
  key="{Path:/var/log/pods/*50408e3a-.../tekton-pipelines-controller/*.log
       Labels:{app="controller", component="controller",
               container="tekton-pipelines-controller", instance="default",
               job="tekton-pipelines/controller", namespace="tekton-pipelines",
               node_name="worker01", pod="tekton-pipelines-controller-76d9f95b56-8ttwh"}}"
```

**注意错误里的路径带着字面量 `*`** —— 说明 Alloy 是对通配符**字面量**调 `os.Stat`，根本没做 glob 展开。

排除环境问题的实测：

```
容器身份      uid=0(root)
目录权限      drwxr-xr-x root root  /var/log/pods
shell glob    ls /var/log/pods/*<uid>/recommender/*.log  →  正常列出 19.log 20.log
读内容        head -c 80 .../20.log  →  2026-09-28T10:54:38...  ✅ 可读
```

文件可读、权限没问题、shell glob 也没问题 —— **问题在 Alloy 侧**。

#### 一次走错的弯路（记录下来避免重犯）

按官方 `alloy convert` 输出的思路，我一度**删掉两条 `__path__` 规则**，以为 `discovery.kubernetes(role="pod")` 会自带真实路径。结果：

```
error="failed to tail file, stat failed: stat : no such file or directory"
key="{Path: Labels:{...}}"     ← Path 完全为空
```

**结论：`discovery.kubernetes` 在这个组合下不产出 `__path__`，必须自己拼。**

#### 缺件 #7：正解是 `file_match` 块

官方文档明确写了（`loki.source.file` → Note）：

> By default, `loki.source.file` requires **absolute file paths** in the `targets` argument. To discover files using glob patterns, you can either enable the **`file_match` block** (recommended) for built-in file discovery, or use the `local.file_match` component.

`file_match` 块参数：

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | `false` | **开启 glob 发现** |
| `sync_period` | duration | `10s` | 扫描周期，自动感知文件轮转新增 |
| `ignore_older_than` | duration | `0s` | 忽略 mtime 早于该时长的文件 |

开启后由 `doublestar` 库做通配符匹配，`__path__` 支持 `*`、`**`、`{a,b}` 语法，**且 `__path__` 的值会作为 `filename` 标签带到每条日志**（正好对上 Promtail 的 `filename` 契约）。

> 📌 迁移指南不会告诉你这一条。`alloy convert` 生成的是 `loki.source.file`，但 Promtail 的 `__path__` 天然是 glob —— 两者语义**不对齐**，必须手工补这个开关。

---

### 2.4 根因 C：误导性报错 `--web.enable-lifecycle`（缺件 #6）

ConfigMap 第一次改动后，config-reloader sidecar 持续报错：

```
level=error msg="function failed. Retrying in next tick"
  err="trigger reload: received non-200 response: 400 Bad Request;
       have you set `--web.enable-lifecycle` Prometheus flag?"
```

这个报错极具误导性。它让人以为 Alloy 缺一个 lifecycle 开关。实测三个候选 flag：

```
$ alloy run ... --server.http.enable-lifecycle=true   → Error: unknown flag
$ alloy run ... --web.enable-lifecycle                 → Error: unknown flag
$ alloy run ... --enable-lifecycle                     → Error: unknown flag
$ alloy run --help | grep lifecycle                    →  （无匹配）
```

**Alloy 1.20 根本不存在 lifecycle/reload flag**（`strings` 在该镜像里也没有，无法直接查 binary）。

继续查日志才发现真相：

```
level=info  msg="reload requested via /-/reload endpoint"      ← 端点是通的！
level=error msg="failed to reload config"
  err="reading config path \"/etc/alloy/config.alloy\": /etc/alloy/config.alloy:1:191: expected block label, got +"
```

**`/-/reload` 正常工作，400 是配置校验失败的响应体。**
那句 `have you set --web.enable-lifecycle` 是 Alloy 复用 Prometheus web 包时的固定文案 —— 它只在「配置加载失败」这一条路径上出现，**不代表缺 flag**。

这条经验的价值：如果当时按提示去加 flag，会白花很多时间。**正确做法是去看 `/-/reload` 有没有被调用过**（有 `reload requested` 日志 = 链路正常，问题在配置本身）。

---

### 2.5 标签契约：不是 `node` 是 `node_name`

Promtail 3.5.1 时代建立的 label 契约（已运行 155 天，Grafana 37 个看板依赖）：

| 标签 | 来源 | 取值示例 |
|---|---|---|
| `namespace` | `__meta_kubernetes_namespace` | `logging` |
| `node_name` | `__meta_kubernetes_pod_node_name` | `worker03` |
| `job` | `namespace` + `app`，分隔符 `/` | `kube-system/kube-apiserver` |
| `app` | 4 级回退（见下） | `loki` |
| `instance` | `app.kubernetes.io/instance` 或 `instance` | `loki` |
| `component` | `app.kubernetes.io/component` 或 `component` | `gateway` |
| `pod` | `__meta_kubernetes_pod_name` | `loki-gateway-68ff9df4b8-lm2dr` |
| `container` | `__meta_kubernetes_pod_container_name` | `nginx` |
| `filename` | Loki 自动加（`__path__` 的值） | `/var/log/pods/logging_loki-gateway-…/nginx/30.log` |
| `stream` | `stage.cri` 解析结果 | `stdout` / `stderr` |
| `__path__` | 两条 relabel 构造 | `/var/log/pods/*<uid>/<container>/*.log` |

**`app` 的 4 级回退**（Promtail 原样，Alloy 逐字复刻）：

```alloy
rule { source_labels = ["__meta_kubernetes_pod_controller_name"]
       regex         = "([0-9a-z-.]+?)(-[0-9a-f]{8,10})?"
       target_label  = "__tmp_controller_name" }

rule { source_labels = [
         "__meta_kubernetes_pod_label_app_kubernetes_io_name",   // ① app.kubernetes.io/name
         "__meta_kubernetes_pod_label_app",                      // ② app
         "__tmp_controller_name",                                 // ③ controller name
         "__meta_kubernetes_pod_name",                            // ④ pod name
       ]
       regex        = "^;*([^;]+)(;.*)?$"                         // 取第一个非空
       target_label = "app" }
```

**`__path__` 的两条规则**（两种目录形态并存，必须都留）：

```alloy
// A：uid 形式（绝大多数 Pod）
rule { source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
       separator     = "/"
       replacement   = "/var/log/pods/*$1/*.log"
       target_label  = "__path__" }

// B：config.hash 注解形式（兼容老式 Deployment）
rule { source_labels = [
         "__meta_kubernetes_pod_annotationpresent_kubernetes_io_config_hash",
         "__meta_kubernetes_pod_annotation_kubernetes_io_config_hash",
         "__meta_kubernetes_pod_container_name",
       ]
       separator    = "/"
       regex        = "true/(.*)"
       replacement  = "/var/log/pods/*$1/*.log"
       target_label = "__path__" }
```

> ⚠️ 修复前的配置里写的是 `__meta_kubernetes_container_name`（**少了 `_pod_`**）—— 这个 meta 键在 Kubernetes SD 里不存在，Alloy 与 Prometheus 都会把它当普通标签（值为空）处理，不报错，静默失效。正确键名是 `__meta_kubernetes_pod_container_name`。

> 🔑 **`node_name` 不是 `node`**：修复前写的是 `target_label = "node"`，一旦采到数据，所有 `{node_name="worker03"}` 形式的存量 LogQL 会全部返回空。这也是「先复刻契约再修功能」的原因 —— 名字错了比不采集更难排查。

---

### 2.6 附带发现：`detected_level` 与 Alloy 无关

审计报告 §6.3 记录的 Promtail 时代样本里含 `detected_level: "unknown"`，本次修复**没有复刻这个标签**。查证过程：

```
$ curl -H 'X-Scope-OrgID: fake' \
    'http://loki-gateway.logging.svc.cluster.local/loki/api/v1/label/detected_level/values?start=<7天前>&end=<现在>'
  status: success
  取值数: 0
```

**7 天窗口（覆盖 Promtail 155 天运行的最近段）内该标签全局为 0，新数据旧数据都没有。**

对照 §6.3 表格里 `detected_level` 的来源写的是「**Loki 3.x 自动探测**」—— 它是 **Loki 服务端**的 bloom-grep 索引产物，不是采集器产物。Promtail pipeline 里也确实没有相关 stage（只有 `cri: {}` 和 `drop: older_than: 168h`）：

```yaml
# promtail-values.yaml
pipelineStages:
  - cri: {}
  - drop:
      older_than: 168h
```

**结论**：`{detected_level="error"}` 这类查询失效的责任在 Loki 侧索引，不在 Alloy。**不是本次迁移引入的退化**，记入 P1 待查（Loki 是否开启 `discover_level` / bloom-grep 配置）。

---

### 2.7 配置文件：修复前 / 修复后

#### 修复后 ConfigMap `alloy-config`（键 `config.alloy`，156 行）

```alloy
// =============================================================================
// Grafana Alloy v1.20.0 — Kubernetes Pod 日志采集
// 基线来源：Promtail 3.5.1 原配置（备份 /root/observability-upgrade-backup-20260928-122529）
// 转换方式：grafana/alloy 内置 `alloy convert` + 人工复刻 Promtail 标签契约
// 契约保证：node_name / job / app / instance / component / pod / container
//            + /var/log/pods 路径双规则（uid 形式 + config.hash 注解形式）
// =============================================================================

// ---------- 1. 服务发现：只看本节点的 Pod ----------
discovery.kubernetes "pod_logs" {
	role = "pod"

	selectors {
		role  = "pod"
		field = "spec.nodeName=" + coalesce(sys.env("K8S_NODE_NAME"), constants.hostname)
	}
}

// ---------- 2. 标签重写：1:1 复刻 Promtail 的 relabel_configs ----------
discovery.relabel "pod_logs" {
	targets = discovery.kubernetes.pod_logs.targets

	// app：4 级回退（name label → app label → controller name → pod name）
	rule {
		source_labels = ["__meta_kubernetes_pod_controller_name"]
		regex         = "([0-9a-z-.]+?)(-[0-9a-f]{8,10})?"
		target_label  = "__tmp_controller_name"
	}

	rule {
		source_labels = [
			"__meta_kubernetes_pod_label_app_kubernetes_io_name",
			"__meta_kubernetes_pod_label_app",
			"__tmp_controller_name",
			"__meta_kubernetes_pod_name",
		]
		regex        = "^;*([^;]+)(;.*)?$"
		target_label = "app"
	}

	// instance
	rule {
		source_labels = [
			"__meta_kubernetes_pod_label_app_kubernetes_io_instance",
			"__meta_kubernetes_pod_label_instance",
		]
		regex        = "^;*([^;]+)(;.*)?$"
		target_label = "instance"
	}

	// component
	rule {
		source_labels = [
			"__meta_kubernetes_pod_label_app_kubernetes_io_component",
			"__meta_kubernetes_pod_label_component",
		]
		regex        = "^;*([^;]+)(;.*)?$"
		target_label = "component"
	}

	// node_name（★ 存量 LogQL 依赖此标签名，不是 node）
	rule {
		source_labels = ["__meta_kubernetes_pod_node_name"]
		target_label  = "node_name"
	}

	rule {
		source_labels = ["__meta_kubernetes_namespace"]
		target_label  = "namespace"
	}

	// job = "<namespace>/<app>"
	rule {
		source_labels = ["namespace", "app"]
		separator     = "/"
		target_label  = "job"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_name"]
		target_label  = "pod"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_container_name"]
		target_label  = "container"
	}

	// __path__：与 Promtail 原配置 1:1 复刻的两条规则
	//   A = uid 形式（绝大多数 Pod）
	//   B = config.hash 注解形式（兼容老式 Deployment）
	// 说明：discovery.kubernetes(role="pod") 不会产出 __path__，必须自己拼。
	// glob 展开由下方 loki.source.file 的 file_match 块负责（见该块注释）。

	// __path__ 规则 A：uid 形式（绝大多数 Pod）
	rule {
		source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
		separator     = "/"
		replacement   = "/var/log/pods/*$1/*.log"
		target_label  = "__path__"
	}

	// __path__ 规则 B：config.hash 注解形式（兼容老式 Deployment）
	rule {
		source_labels = [
			"__meta_kubernetes_pod_annotationpresent_kubernetes_io_config_hash",
			"__meta_kubernetes_pod_annotation_kubernetes_io_config_hash",
			"__meta_kubernetes_pod_container_name",
		]
		separator    = "/"
		regex        = "true/(.*)"
		replacement  = "/var/log/pods/*$1/*.log"
		target_label = "__path__"
	}
}

// ---------- 3. 日志读取源（★ 迁移时完全缺失的一环）----------
loki.source.file "pod_logs" {
	targets    = discovery.relabel.pod_logs.output
	forward_to = [loki.process.logs_to_prometheus.receiver]

	// 从文件末尾开始追：避免把 Promtail 时代遗留的最多 7 天历史日志
	// 一次性重放进 Loki（会被 reject_old_samples / out-of-order 大面积拒绝，
	// 且会打爆 gateway 与 WAL）。代价是迁移窗口（约 4h）的日志不回填。
	tail_from_end = true

	// ★ 关键：loki.source.file 默认要求 targets.__path__ 是「具体文件路径」，
	//   遇到 glob 会对字面量直接 os.Stat 而不展开（实测 65 个 target 全部
	//   stat .../*.log: no such file or directory）。开启 file_match 后改由
	//   doublestar 库做通配符发现，并按 sync_period 自动感知文件轮转新增。
	file_match {
		enabled     = true
		sync_period = "10s"
	}
}

// ---------- 4. 解析管道（对齐 Promtail pipeline_stages）----------
loki.process "logs_to_prometheus" {
	forward_to = [loki.write.default.receiver]

	// 剥离 CRI 包装：timestamp / stream / P | F
	stage.cri { }

	// 与 Promtail 一致：丢弃 7 天前的日志
	stage.drop {
		older_than = "168h"
	}
}

// ---------- 5. 写出（端点与租户与 Promtail 时代完全一致）----------
loki.write "default" {
	endpoint {
		url       = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
		tenant_id = "fake"
	}
}
```

#### 修复后 values

```yaml
# =============================================================================
# Grafana Alloy — 修正版 values
#
# 修正的根因：上一版把所有键写在 YAML 顶层，而 chart 的真实结构是
#             alloy.* / controller.* / rbac.* / serviceAccount.*
#             顶层键被静默忽略 —— 这才是 5 处缺件里 3 处的真正来源。
#
# 本文件逐项对照 chart templates/containers/_agent.yaml 与
# chart templates/controllers/_pod.yaml 编写，非猜测。
# =============================================================================

alloy:
  # 复用外部 ConfigMap（chart 不托管内容）
  configMap:
    create: false
    name: alloy-config
    key: config.alloy

  # ★ 缺件 3 修复：hostPath 挂载
  #   Promtail-6.17.1 的 defaultVolumes 默认提供，grafana/alloy chart 无默认值
  #   → chart 原生支持这两个开关，此前被显式写成 false
  mounts:
    varlog: true               # → hostPath /var/log                readOnly
    dockercontainers: true     # → hostPath /var/lib/docker/containers  readOnly
    extra:
      - name: positions
        mountPath: /run/alloy

  # ★ 缺件 5 修复：资源保障（此前写在顶层被忽略 → BestEffort QoS）
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # 断点续传文件落到 hostPath，重启不重读全量
  storagePath: /run/alloy

controller:
  type: daemonset

  # ★ 缺件 4 修复：容忍 NoSchedule taint，恢复 6/6 节点覆盖
  #   Promtail: tolerations: [{operator: Exists, effect: NoSchedule}]
  tolerations:
    - operator: Exists
      effect: NoSchedule

  # 逐节点滚动，避免 6 个节点同时重启
  updateStrategy:
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
    type: RollingUpdate

  volumes:
    extra:
      - name: positions
        hostPath:
          path: /run/alloy
          type: DirectoryOrCreate

rbac:
  create: true

serviceAccount:
  create: true
  name: alloy

service:
  enabled: true
  type: ClusterIP

# 保持与现状一致（此前也未开）
serviceMonitor:
  enabled: false
```

#### 变更 diff 摘要

**ConfigMap（56 → 156 行）**

| 位置 | 变更 |
|---|---|
| `discovery.relabel.targets` | `[]` → `discovery.kubernetes.pod_logs.targets` |
| relabel 规则 | 5 条 → 11 条（补 `node_name` / `job` / `instance` / `component` / `app` 4 级回退 / `__path__` × 2） |
| `__meta_kubernetes_container_name` | → `__meta_kubernetes_pod_container_name`（补 `_pod_`） |
| `target_label = "node"` | → `target_label = "node_name"` |
| **新增组件** | `loki.source.file "pod_logs"`（含 `file_match` + `tail_from_end`） |
| 组件总数 | 4 → 5 |

**values**

| 键 | 修复前 | 修复后 |
|---|---|---|
| `alloy.mounts.varlog` | `false` | `true` |
| `alloy.mounts.dockercontainers` | `false` | `true` |
| `alloy.mounts.extra` | — | `[{name: positions, mountPath: /run/alloy}]` |
| `alloy.resources` | 顶层（被忽略） | `100m/128Mi` requests，`500m/512Mi` limits |
| `alloy.storagePath` | — | `/run/alloy` |
| `controller.tolerations` | 顶层（被忽略） | `[{operator: Exists, effect: NoSchedule}]` |
| `controller.updateStrategy` | — | `maxUnavailable: 1, maxSurge: 0` |
| `controller.volumes.extra` | — | `[{name: positions, hostPath: /run/alloy, DirectoryOrCreate}]` |
| `rbac.create` | `clusterRole.create`（顶层） | `true` |

---

### 2.8 验证结果

7 项验证全部通过：

| # | 验证项 | 方法 | 结果 |
|---|---|---|---|
| 1 | 组件加载成功 | `alloy_component_controller_running_components` | 6/6 副本 = **5**（原 4） |
| 2 | 配置无语法错 | `alloy_config_last_load_successful` | 6/6 = **1** |
| 3 | hostPath 挂载到位 | 查 Pod spec volumeMounts + 容器内 `ls /var/log/pods` | 6/6 全部含 `/var/log`、`/var/lib/docker/containers`、`/run/alloy` |
| 4 | **节点覆盖 6/6** | `loki_source_file_files_active_total` 按节点聚合 | m01=72 / master01=32 / master02=30 / worker01=100 / worker02=110 / worker03=72 |
| 5 | 标签契约 | Loki `/label/<name>/values` 逐个确认 | 10/11 复刻（见下表） |
| 6 | 写往 Loki 成功 | `loki_write_request_duration_seconds{status_code="204"}` | **204**，累计已发 8822 条，稳定增长（+1134 / +1163 每 30s） |
| 7 | LogQL 兼容性回归 | 用 Promtail 时代老查询串实跑 | 5/6 命中（见下） |

**验证 5 明细：**

| 标签 | 取值数 | 示例 | 判定 |
|---|---:|---|---|
| `namespace` | 13 | `argocd`, `ceph-csi-rbd`, `cnpg-system` | ✅ |
| `node_name` | 6 | `m01`, `master01`, `master02` | ✅ |
| `job` | 22 | `argocd/argocd-repo-server`, `kube-system/calico-node` | ✅ |
| `app` | 22 | `3scale-kourier-gateway`, `alloy` | ✅ |
| `instance` | 6 | `alloy`, `argocd`, `loki` | ✅ |
| `component` | 24 | `activator`, `admission-controller` | ✅ |
| `pod` | 59 | `alloy-68t5k`, `activator-6fc7cfdb6f-6t2zs` | ✅ |
| `container` | 39 | `activator`, `alloy` | ✅ |
| `filename` | 67 | `/var/log/pods/argocd_…/notifications-controller/42.log` | ✅ |
| `stream` | 2 | `stdout`, `stderr` | ✅ |
| `detected_level` | 0 | — | ⚠️ 见 §2.6，非本次退化 |

**验证 7 明细（老 LogQL 直接可用）：**

| 查询串 | 结果 |
|---|---|
| `{node_name="worker01"}` | ✅ 命中 |
| `{job="kafka/kafka"}` | ✅ 命中 |
| `{app="kafka"}` | ✅ 命中 |
| `{container="kafka"}` | ✅ 命中 |
| `{namespace="kube-system"} \|= "error"` | ✅ 命中 |
| `{component="kafka"}` | 窗口内无数据（kafka Pod 无 `component` label，正常） |

**为什么必须做验证 7**：把标签名从 `node` 改回 `node_name` 的唯一目的就是让存量 LogQL 继续工作。**只验证「新数据能查到」会漏掉「老查询是否还能用」**，而后者才是这次迁移的验收标准。

#### 复核（文档定稿时，约修复后 2 小时）

| 检查 | 结果 |
|---|---|
| 6/6 副本 | 组件数 = 5，`alloy_config_last_load_successful` = 1 |
| `active_files` | worker01=100 / worker02=110 / worker03=72 / m01=72 / master01=32 / master02=30 |
| 累计已发条目 | **37,093**（验证时 8,822 → 定稿时 37,093，持续增长） |
| 增长速率 | +1236 条/30s，+1100 条/30s |
| Loki 侧独立确认 | 近 10 分钟 **22,764 行** |
| Loki 内 `node_name` 覆盖 | **6/6**，无缺失 |

> 采集量的核对用了两个独立来源：Alloy 自报的 `loki_write_sent_entries_total`（累计），以及直连 Loki 的 `sum(count_over_time(...))`（窗口内）。两者互相印证，避免「采集器自说自话」。

---

### 2.9 风险与回滚

#### 风险

**中低。**

| 项 | 评估 |
|---|---|
| 数据丢失窗口 | `tail_from_end = true` 使 Alloy 从文件末尾起追，**Promtail 退役（12:33）到修复完成（18:00）之间约 5.5 小时的日志未回填**。这是主动取舍：反过来（从文件头读）会把 Promtail 时代最多 7 天的历史日志一次性灌进 Loki，被 `reject_old_samples` + out-of-order 大面积拒绝，同时打爆 gateway 与 WAL。该 5.5h 日志**仍完整保留在各节点 `/var/log/pods`**，需要时可按时间窗单独回填。 |
| CPU / 内存 | `file_match` 每 10s 扫一次文件系统，6 节点合计约 400 个文件，开销可忽略。`requests 100m/128Mi` 与 Promtail 时代一致。 |
| 日志噪音 | 仍有 `failed to create source` 报错，是已退出 init 容器（如 `init-config-reloader`）的日志目录被 kubelet 清理所致，属正常噪音，不影响活跃容器采集。 |
| 未触碰 | 未删任何 Pod / PVC / namespace，未 force-delete，未动 Loki 数据。DaemonSet 逐节点滚动（`maxUnavailable: 1`），全程无采集真空。 |

#### 回滚

```bash
B=/root/observability-upgrade-backup-20260928-172244

# ① 回滚 DaemonSet 到 revision 1
helm rollback alloy -n logging 1

# ② 回滚 ConfigMap
#    ⚠️ data 必须是明文，kubectl 会自行 base64 编码（见 §4.1）
kubectl create cm alloy-config -n logging \
  --from-file=config.alloy=$B/alloy/config-original.alloy \
  --dry-run=client -o json | kubectl replace -f -
```

备份内容：

| 文件 | 内容 |
|---|---|
| `$B/alloy/config-original.alloy` | 修复前配置全文（56 行，含 `targets = []` 与 `label node` 两处缺陷） |
| `$B/alloy/config-fixed.alloy` | 修复后配置全文（156 行） |
| `$B/alloy/values-deployed.yaml` | 修复前 values（原样保留） |
| `$B/alloy/values-fixed.yaml` | 修复后 values |
| `$B/alloy/values-applied.yaml` | `helm get values` 实际生效值 |
| `$B/alloy/cm-alloy-config-original.yaml` | 修复前 ConfigMap 完整 YAML |
| `$B/alloy/cm-alloy-config-fixed.yaml` | 修复后 ConfigMap 完整 YAML |
| `$B/alloy/ds-alloy.yaml` / `ds-alloy-after.yaml` | 修复前后 DaemonSet |
| `$B/alloy/manifest-after.yaml` | 修复后 helm manifest |
| `$B/alertmanager/secret-original.json` | Alertmanager Secret 变更前完整 JSON（含原公网 URL） |

---

## 3. 问题三：tempo3 13/13 CrashLoopBackOff

> **执行时间**：2026-09-28 18:35 – 18:55 (CST)
> **回滚源**：`/root/observability-upgrade-backup-20260928-183547-tempo3/`（59 文件 / 1.2 MB）
> **组件**：`tempo-distributed` 3.7.0 / Tempo 3.0.3 / release `tempo3` / ns `logging`

### 3.1 症状

`tempo3` 14 个 Pod 中 **13 个 CrashLoopBackOff**，仅 `memcached-0` 存活。重启次数 42–54 次，持续 3–4 小时。

**注意**：这类"Pod 数从 14 变 13"不是缩容。`metricsGenerator.replicas` 在 values 与线上 Deployment 里**一直是 1**；多出来的那个 `tempo3-metrics-generator-7b7fb8f664-bnd86` 是**废弃 ReplicaSet 遗留的孤儿 Pod**（所属 RS `desired=0`），本次 `helm upgrade` 顺带把它归零清理了。判定依据见 §3.7 验证 1。

崩溃日志（所有组件一致）：

```
level=error msg="error running Tempo"
  err="failed to init module services: error initialising module: usage-report:
       failed to initialize usage report: unexpected error from ListObjects on
       tempo-traces: The request signature we calculated does not match the
       signature you provided. Check your key and signing method."
```

`usage-report` 模块在启动时要对 `tempo-traces` 桶做一次 `ListObjects` 来采集用量统计。**这个探测失败直接导致整个 Tempo 进程退出** —— 于是所有组件（distributor / querier / query-frontend / backend-scheduler / backend-worker / block-builder / live-store / metrics-generator）全部一起崩。

### 3.2 根因一：S3 secret_key 错误（崩溃直接原因）

凭据是**内联在 values 里**的（没有走 Secret）：

```yaml
storage:
  trace:
    backend: s3
    s3:
      access_key: <redacted>
      secret_key: <redacted>        # ← 错的
      bucket: tempo-traces
      endpoint: 10.0.0.31:7480
      region: us-east-1
      forcepathstyle: true
      insecure: true
```

**离线指纹比对**（只比 SHA256 前 12 位，不回显明文）：

| 项 | 当前 values | RGW 实时值 | 判定 |
|---|---|---|---|
| `access_key` | `5f3d45561ed2` | `5f3d45561ed2` | ✅ 一致 |
| `secret_key` | `6dedf775e8d5` | `1545d6ac455a` | ❌ **不一致** |

真凭据取自 RGW 主机：

```bash
ssh root@10.0.0.31 "radosgw-admin user info --uid=tempo-admin --format=json"
# → user_id: tempo-admin, display_name: "Tempo Storage User"
# → access_key / secret_key 长度 20 / 40
```

**三组对照实验**（`aws --endpoint-url http://10.0.0.31:7480 s3 ls s3://tempo-traces/`）：

| # | secret_key | 结果 |
|---|---|---|
| ① | values 里那个（错的） | `An error occurred (SignatureDoesNotMatch) when calling the ListObjectsV2 operation` |
| ② | RGW 实时值 | ✅ `2026-04-23 20:36:18  215 tempo_cluster_seed.json` |
| ③ | RGW 实时值 + 列全部桶 | ✅ `2026-04-23 20:27:10 tempo-traces` |

**写权限也一并验证了**（自建探针对象，写完即删，未碰任何已有数据）：

```
PUT   Completed 17 Bytes/17 Bytes
LIST  2026-09-28 18:34:24  17 verify-write.txt
DEL   delete: s3://tempo-traces/_probe/verify-write.txt

前缀级权限：blocks/ ✅   index/ ✅   tempo-cluster/ ✅   _blocks/ ✅
```

> 🔑 **`access_key` 对、`secret_key` 错** —— 这种"只错一半"的组合最难查，因为 AK 能在 RGW 用户列表里找到，会让人误以为凭据没问题。**排查签名错误永远要做指纹比对，不要只确认"用户存在"。**

---

### 3.3 根因二：`distributor.receivers` 被渲染成 null（功能阻断）

即使把凭据修好，tempo3 **依然收不到任何 span**。当前 live 配置第 64 行：

```yaml
distributor:
  log_received_spans:
    enabled: true
    filter_by_status_error: false
    include_all_attributes: false
  receivers: null          # ← 空的
  ring:
    kvstore:
      store: memberlist
```

**为什么会是 `null`**：读 chart 源码 `/tmp/tempo-distributed/values.yaml:2021`（chart 把主配置内联在 values 里）：

```gotemplate
      receivers:
        {{- if  or (.Values.traces.jaeger.thriftCompact.enabled) … }}
        jaeger: …
        {{- end }}
        {{- if .Values.traces.otlp.http.enabled }}
        http:  …
        {{- end }}
        {{- if .Values.traces.otlp.grpc.enabled }}
        grpc:  …
        {{- end }}
```

`receivers:` 这一行**是无条件输出的**，但它下面所有的填充分支都由 `traces.jaeger.*` / `traces.otlp.*` 的 `enabled` 开关控制。chart 默认值：

```yaml
traces:
  otlp:
    grpc: { enabled: false, port: 4317 }
    http: { enabled: false }
```

全 false ⇒ `receivers:` 下面一行都没有 ⇒ YAML 把它解析成 **`null`**。

而 `tempo3-values.yaml` 里**根本没有 `traces:` 这个键**（顶层的 `distributor:`、`storage:`、`ingest:` 都有，唯独没有 `traces:`），所以默认值原样生效。

> 📌 这与 §2.2 的 Alloy 案例是**同一个陷阱的变种**：chart 不会告诉你"你少写了一个开关"，只会渲染出一个语法合法、语义为空的 `null`。区别在于 Alloy 是**键写错层级被丢弃**，Tempo 是**开关没开导致分支不渲染**。两者都属于"静默失败"。

**打开 OTLP 后 chart 会自动带出端口**，不需要手写 Service 和 containerPorts：

- `templates/distributor/service-distributor.yaml`：`if .Values.traces.otlp.http.enabled` → 加 `distributor-otlp-http:4318`；`grpc.enabled` → 加 `grpc-distributor-otlp:4317` 和 `distributor-otlp-legacy:55680`
- `templates/distributor/deployment-distributor.yaml:27-32`：对应加 `containerPort 4318 name=otlp-http` / `4317 name=grpc-otlp`

### 3.4 次要报错：为什么不是根因

日志里还有两类噪音，一并查证并排除：

**① memberlist fast-join 失败**

```
msg="fast-joining node failed" err="dial tcp 10.244.5.62:7946: connection refused"
```

`memberlist.abort_if_cluster_join_fails: false` 已正确设置。**这是果不是因** —— 目标节点自己也处于 CrashLoop，7946 端口根本没监听，所以 connection refused。集群成员全部起来后自然消失。

**② memcached SRV 解析失败**

```
lookup _memcached-client._tcp.tempo3-memcached on 10.96.0.10:53: no such host
```

同样验证过 DNS 本身没问题：

```
SRV _memcached-client._tcp.tempo3-memcached.logging.svc.cluster.local
  → service = 0 100 11211 tempo3-memcached-0.tempo3-memcached.logging.svc.cluster.local
A  tempo3-gossip-ring.logging.svc.cluster.local → 10.244.19.87 / 10.244.5.61 / 10.244.5.62
```

`tempo3-memcached` 是 headless Service（`clusterIP=None`）。**启动竞态**：其他组件做 SRV 查询时，`tempo3-memcached-0` 还没 Ready，headless Service 没有可用 endpoint，SRV 记录不存在。`memcached-0` 起来后就正常了。

### 3.5 配置文件：修复前 / 修复后

#### 变更的语义化 diff（改 1 项 + 加 3 项，38 个键未动）

```
~ 修改  storage.trace.s3.secret_key   <脱敏, len 40 → 40>     ← 修复 1
+ 新增  traces.otlp.grpc.enabled = True                        ← 修复 2
+ 新增  traces.otlp.grpc.port     = 4317
+ 新增  traces.otlp.http.enabled = True

未变动键数: 38
```

#### 修复后 values（`/tmp/tempo3-values-fixed.yaml`，节选变更部分）

```yaml
# ── 修复 1：S3 凭据 ──────────────────────────────────────────────
storage:
  trace:
    backend: s3
    s3:
      access_key: <redacted>       # 与 RGW 一致（原本就对）
      secret_key: <redacted>      # ★ 已修正
      bucket: tempo-traces
      endpoint: 10.0.0.31:7480
      region: us-east-1
      forcepathstyle: true
      insecure: true

# ── 修复 2：打开 OTLP 接收端（整个 values 里原本没有 traces: 键）──
#   chart 用 traces.otlp.*.enabled 决定 distributor.receivers 是否渲染，
#   以及是否在 Service / containerPorts 上加 4317、4318。
traces:
  otlp:
    grpc:
      enabled: true
      port: 4317
      receiverConfig: {}
    http:
      enabled: true
      receiverConfig: {}
```

#### 修复后生成的 `tempo.yaml` 关键段（live ConfigMap 实测）

```yaml
distributor:
  log_received_spans:
    enabled: true
  receivers:                    # ← 从 null 变成有内容
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  ring:
    kvstore:
      store: memberlist
```

#### 修复后 distributor Service 端口

| 端口名 | port | targetPort |
|---|---|---|
| `http-metrics` | 3200 | http-metrics |
| `grpc` | 9095 | 9095 |
| **`distributor-otlp-http`** | **4318** | otlp-http |
| **`grpc-distributor-otlp`** | **4317** | grpc-otlp |
| `distributor-otlp-legacy` | 55680 | grpc-otlp |

### 3.6 变更前后的离线校验链

按"先离线验证再上线"的原则，**改集群之前**跑了 6 道校验：

| # | 校验 | 手段 | 结果 |
|---|---|---|---|
| 1 | values 语义 diff | python 扁平化逐键比对 | 改 1 + 加 3，38 键未动 |
| 2 | Helm 渲染 | `helm template tempo3 /tmp/tempo-distributed -f values-fixed.yaml` | 27 个文档，无错误 |
| 3 | `receivers` 是否还是 null | 解析渲染产物 YAML | `dict`，含 `otlp.protocols.{grpc,http}` ✅ |
| 4 | S3 凭据是否进了渲染产物 | 比对 RGW 实时值 | `secret_key == RGW` ✅ |
| 5 | Service / containerPorts | 解析渲染产物 | 4317/4318 双双出现（Service + 容器） ✅ |
| 6 | **Tempo 二进制离线校验** | 临时 Pod 跑 `tempo -target=distributor -config.file=/conf/tempo.yaml -config.verify=/tmp/out.yaml` | **退出码 0** ✅ |

第 6 项是含金量最高的一道：它用**真实 Tempo 3.0.3 二进制**加载渲染出来的配置，并且 `store`(S3) 与 `usage-report` 模块都成功初始化（后者正是原先崩溃的模块），端口 3200 / 4317 / 4318 全部实测监听。

```
  3200: ✅ 已监听
  4317: ✅ 已监听
  4318: ✅ 已监听
```

> ⚠️ 这一步踩了两次自己的坑，都已修正，详见 §4.7 和 §4.8。核心教训：**离线校验 Pod 必须挂载与线上完全一致的卷**，否则会得到假失败。

确认离线校验全绿之后，才执行：

```bash
helm upgrade tempo3 /tmp/tempo-distributed -n logging -f /tmp/tempo3-values-fixed.yaml
# Release "tempo3" has been upgraded.  REVISION: 5 → 6
```

### 3.7 验证结果（14 项，含端到端 trace）

#### 基础健康

| # | 验证项 | 结果 |
|---|---|---|
| 1 | Pod 总数 | **13/13 Running**，0 CrashLoopBackOff |
| 2 | 容器重启次数合计 | **0** |
| 3 | 就绪状态 | 13/13 `ready=True` |
| 4 | 崩溃签名是否消失 | 13 个 Pod 日志中 `SignatureDoesNotMatch` / `error running Tempo` / `ListObjects.*error` 命中数 **0** |
| 5 | Pod 数从 14→13 的解释 | `metricsGenerator.replicas` 变更前后均为 **1**；减少的是废弃 RS `7b7fb8f664` 的孤儿 Pod（desired=0），**非缩容** |

#### API 端点

| # | 端点 | HTTP |
|---|---|---|
| 6 | `query-frontend:3200/ready` | 200 ✅ |
| 6 | `distributor:3200/ready` | 200 ✅ |
| 6 | `querier:3200/ready` | 200 ✅ |
| 6 | `metrics-generator:3200/ready` | 200 ✅ |
| 6 | `backend-scheduler:3200/ready` | 200 ✅ |
| 6 | `live-store:3200/ready` | 200 ✅ |
| 7 | `distributor:3200/metrics` | 200 ✅（825 行指标） |

#### 端到端 trace（最有说服力的一项）

**第 8 步 —— 注入**：用 OTLP/HTTP JSON 协议往 `tempo3-distributor:4318/v1/traces` POST 一条 span

```
POST → {"partialSuccess":{}}   HTTP=200        ✅ distributor 接收成功
```

**第 9 步 —— distributor 确认收到**（`tempo_distributor_spans_received_total`）

```
tempo_distributor_spans_received_total{tenant="single-tenant"}   1     ← 正好是我们那一条
tempo_distributor_bytes_received_total{tenant="single-tenant"}   173
无 discarded_spans / spans_received_failed / receiver_failed 指标
```

**第 10 步 —— Kafka 通道**：live-store 作为 Kafka consumer 确实消费到了

```
tempo_ingest_group_partition_lag{group="tempo3-live-store",partition="0"}   0   ← 无积压
tempo_ingest_storage_reader_read_bytes_total{component="live-store",node_id="0"}   22113
tempo_distributor_kafka_records_per_request_count / _write_latency_seconds_*   有值
```

**第 11 步 —— 原样查回来**（`POST /api/search`）

```json
{"traces":[{"traceID":"296022ad…","rootServiceName":"tempo3-p0-verification",
            "rootTraceName":"P0_VERIFICATION_SPAN",
            "startTimeUnixNano":"1790592748919091200","durationMs":2000}],
 "metrics":{"inspectedTraces":1,"inspectedBytes":"19417",
            "completedJobs":3,"totalJobs":3}}
HTTP=200
```

**第 12 步 —— 取完整 trace**（`GET /api/traces/{id}`）

```json
{"batches":[{"resource":{"attributes":[{"key":"service.name",
   "value":{"stringValue":"tempo3-p0-verification"}}]},
 "scopeSpans":[{"scope":{"name":"verify"},"spans":[
   {"traceId":"KWAirYIcXwp3dVEdn3ySaA==","spanId":"ASNFZ4mrze8=",
    "name":"P0_VERIFICATION_SPAN","kind":"SPAN_KIND_SERVER",
    "startTimeUnixNano":"1790592748919091200","endTimeUnixNano":"1790592750919091200",
    "attributes":[{"key":"verify.marker","value":{"stringValue":"phase2-tempo3-fix"}}],
    "status":{}}]}]}]}
```

**第 13 步 —— 按 tag 检索**（`POST /api/search` with `q={"verify.marker":"phase2-tempo3-fix"}`）→ 命中同一条 trace ✅

> 这四步串起来证明的不只是"Tempo 没崩"，而是
> **`OTLP/HTTP → distributor → Kafka → live-store → querier → query-frontend → API`**
> 整条链路真的在跑，且 span 属性可被索引检索。

**第 14 步 —— S3 写入路径被真实触发**

桶内对象（修复前只有 1 个 2026-04-23 的种子文件）：

```
2026-04-23 20:36:18        215 tempo_cluster_seed.json
2026-09-28 18:54:01       3084 work.json          ← ★ tempo3 自己写进去的
```

```
tempo_backend_scheduler_work_flushes_total           9
tempo_backend_scheduler_work_flushes_failed_total     0
S3 相关错误日志（SignatureDoesNotMatch/AccessDenied/NoSuchBucket）  0 行
```

这条 `work.json` 不是我用 `aws cli` 写的，是 **Tempo 自己 flush 出来的**，因此 S3 写入路径（凭据 → 签名 → PUT）得到端到端证实。

#### 全局回归

| 组件 | 结果 |
|---|---|
| Tempo 2.x（release `tempo`） | 9/9 全部 `1/1` ✅ 未受影响 |
| Grafana Alloy | 6/6 全部 `2/2` ✅ 未受影响 |
| Loki | 6×`1/1` + 3×`2/2` ✅ 未受影响 |
| **全集群 CrashLoopBackOff 总数** | **13 → 0** |

### 3.8 风险与回滚

#### 3.8.1 风险

**低。**

| 项 | 评估 |
|---|---|
| 数据丢失 | **无风险**。`tempo-traces` 桶在修复前只有 1 个 2026-04-23 的 `tempo_cluster_seed.json`（215 B），没有任何真实 trace 数据。且 Tempo 2.x 用的是 `backend: local`（`/var/tempo/traces`），与 S3 完全无关 —— 也就是说 **S3 这条路径此前从未被任何组件真正使用过**，不存在"写进去的数据读不出来"的情况。 |
| 凭据回显 | 报告与日志中一律只出现 SHA256 前 12 位指纹；真凭据只落在 `/tmp/.tempo_ak_live` `/tmp/.tempo_sk_live`（`chmod 600`）与本机备份目录。 |
| 服务端口变化 | distributor Service 新增 3 个端口（4317/4318/55680）。均为**新增**，无端口冲突，无其他组件占用。 |
| 对 Tempo 2.x 的影响 | 两个 release 的 Service / ConfigMap / memberlist cluster_label 完全独立（`tempo.logging` vs `tempo3.logging`），且 Tempo 2.x 用 local backend。实测 9/9 未受影响。 |
| 未触碰 | 未删除任何 Pod / PVC / namespace / 对象存储数据，未 force-delete，未 `helm uninstall`。唯一"删除"动作是本次 upgrade 把废弃 RS 的孤儿 Pod 归零（该 RS desired 本就是 0）。 |

#### 3.8.2 回滚方式

```bash
B3=/root/observability-upgrade-backup-20260928-183547-tempo3

# ① 回滚 Helm release（revision 5 是本次变更前的版本）
helm rollback tempo3 -n logging 5

# ② 或用变更前的 values 重新升级
helm upgrade tempo3 /tmp/tempo-distributed -n logging \
  -f $B3/values/local-values.yaml
```

> ⚠️ 回滚会**让 13 个 Pod 重新回到 CrashLoopBackOff**（因为错误凭据会被恢复）。
> 若只是想回退「打开 OTLP」这一半、保留正确凭据，用 `values/local-values.yaml` 作为基底，只手工保留 `storage.trace.s3.secret_key` 的修正即可。

| 备份文件 | 内容 |
|---|---|
| `$B3/values/local-values.yaml` | 变更前 values（**主回滚源**） |
| `$B3/values/values-fixed.yaml` | 变更后 values |
| `$B3/values/all-values.yaml` / `user-values.yaml` | `helm get values -a` / 用户层 |
| `$B3/configmap/tempo3-config.yaml` | 变更前 ConfigMap 完整 YAML |
| `$B3/helm/manifest.yaml` / `history.txt` | 变更前 helm manifest 与历史 |
| `$B3/helm/render-fixed.yaml` | 变更后的离线渲染产物（27 文档） |
| `$B3/verify-tempo-offline.log` | Tempo 二进制离线校验完整日志 |
| `$B3/pods-before.txt` / `pods-after.txt` | 变更前后 Pod 状态快照 |
| `$B3/workloads/*.json` | 全部 9 个 tempo3 工作负载 + 12 个 Service 的完整定义 |
| `$B3/after/` | 变更后全部 13 个 Pod 日志、ConfigMap、manifest、distributor/live-store 指标快照 |

---

## 4. 过程性踩坑记录（避免重复踩）

### 4.1 kubectl 的 ConfigMap/Secret `data` 编码语义

**现象**：写入 ConfigMap 后，Pod 内挂载的文件内容是一串 base64 文本：

```
$ kubectl exec -n logging <pod> -- head -3 /etc/alloy/config.alloy
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09...
```

Alloy 报 `config.alloy:1:191: expected block label, got +`（`+` 是 base64 串里才有的字符）。

**原因**：我先手动 `base64.b64encode(content)` 写进 JSON 的 `data` 字段，而 kubectl 在 `replace -f` 时**又编码了一次** → 双层 base64。

**实测结论**（三种写法逐一验证）：

| 写法 | `kubectl get -o json` 返回 | 判定 |
|---|---|---|
| `apply -f` + YAML 里 `data` 写明文 | 明文 | ✅ |
| `replace -f` + JSON 里 `data` 写明文 | 明文 | ✅ |
| `replace -f` + JSON 里 `data` 写 base64 | base64 | ❌ 双层编码 |

**规则**：交给 `kubectl` 手工构造 ——

```bash
# ✅ 推荐：--from-file 由 kubectl 负责编码
kubectl create cm <name> -n <ns> --from-file=key=/path/to/file \
  --dry-run=client -o json | kubectl replace -f -

# ✅ 也可：直接改 live 对象的 data 字段（明文）
kubectl get cm <name> -n <ns> -o json | python3 -c "
import json,sys
o=json.load(sys.stdin)
o['data']={'key': open('/path/to/file',encoding='utf-8').read()}
json.dump(o,open('/tmp/cm.json','w'))" && kubectl replace -f /tmp/cm.json

# ❌ 不要手动 base64
```

**配套陷阱**：`replace` 会因 `resourceVersion` 变化报 `Conflict`。**取 live 对象 → 只改 `data` → replace**，不要拿离线渲染的对象去 replace（会丢 labels / annotations / ownerReferences）。

**另一个配套陷阱**：ConfigMap 卷同步有延迟（实测 20–90 秒，kubelet sync 周期）。**改完立刻验证挂载文件会看到旧内容**，误判成「没写进去」。要轮询等同步。

### 4.2 判断 Alloy 是否真的在 reload

不要看 `400` 状态码，要看**有没有 `reload requested` 日志**：

```bash
# ✅ 可靠判据
kubectl logs -n logging <pod> -c alloy --tail=50 | grep "reload requested"
#   有 → /-/reload 链路正常，问题在配置本身
#   无 → reload 链路本身有问题
```

### 4.3 探查 Pod 的镜像能力

- `curlimages/curl` **没有 python3**（exit 127）→ 在 Pod 内取原始 JSON，回主机用 `python3` 解析
- 容器内是 BusyBox 时 `wget` **不支持 `--method=POST`**，只支持 `--post-data` / `--post-file`
- 探查完及时清理：`kubectl delete pod <name> --ignore-not-found`

### 4.4 查 Prometheus / Loki 时的两个假空

- **Loki `/label/<name>/values` 强制要求 `start` / `end`**，不传会返回空结果，**极易误判为「没数据」**
- Loki 开了 `auth_enabled: true`，所有查询必须带 `-H 'X-Scope-OrgID: fake'`
- LogQL 里的 `|=`、`|~` 建议用 `--data-urlencode query@/tmp/q.txt` 传，避免 shell 引号问题

### 4.5 验证脚本里聚合多行指标

Alloy 的 `loki_source_file_*` 是**每文件一条**的多行指标，跨行取值会炸：

```bash
# ❌ 拿到多行后做算术 → 语法错误
A=$(curl ... | awk '/^loki_source_file_files_active_total/{print $2}')

# ✅ 在 awk 里就地求和
A=$(curl ... | awk '/^loki_source_file_files_active_total/{s+=$2} END{printf "%d", s+0}')
```

### 4.6 假零：探查 Pod 没建成就把 0 当成故障

本次定稿时复查线上，6 个节点全部返回「累计已发 = 0」，看着像采集中断。**实际是探查 Pod 根本没创建成功**（前一步的 `kubectl delete --wait=false` 还在进行中，`kubectl run` 撞名失败），后续 `kubectl exec` 全部落空，指标文件为空，awk 求和得 0。

**教训：报「归零」这类坏消息前，先自检测量工具。**

```bash
# ✅ 探查 Pod 建好后必须先自检
kubectl run probe --image=curlimages/curl:latest --restart=Never --command -- sleep 900
kubectl wait --for=condition=Ready pod/probe --timeout=60s
kubectl get pod probe -o jsonpath='{.status.phase}'   # 必须看到 Running

# ✅ 探查端点自检：连 Loki gateway 都打不通，说明是探查坏了不是业务坏了
kubectl exec probe -- curl -s -o /dev/null -w '%{http_code}' \
  --max-time 8 http://loki-gateway.logging.svc.cluster.local/loki-gateway/ready
```

同一个探查 Pod 复用到底，**不要在循环里反复 `kubectl run` / `delete`** —— 既容易撞名失败，又会在 `delete --wait=false` 的窗口期取空值。

### 4.7 离线校验 Pod 挂载不全 ⇒ 假失败

用真实二进制做离线配置校验（`tempo -config.verify`）时，我第一次的结果是"通过"，第二次却是"失败"，两次都不是配置的问题：

| 轮次 | 校验 Pod 挂载 | 结果 | 真因 |
|---|---|---|---|
| ① | 只挂 `config` | 退出码 0，但 `overrides` 模块报错 | `read "/runtime-config/overrides.yaml": no such file` |
| ② | 挂 `config` + `runtime-config` | 又失败，报 `SignatureDoesNotMatch` | **校验 Pod 挂的是线上 live ConfigMap（还是旧凭据），不是我渲染出来的新配置** |
| ③ | 挂**临时 ConfigMap**（渲染后配置）+ `runtime-config` | 退出码 0，全部模块启动成功 | ✅ |

**两条规则**：

```bash
# ✅ 规则 1：挂载必须与线上 Deployment 完全一致
#    先从渲染产物里读出真实的 volumeMounts，照抄，别凭印象
python3 - <<'PY'
import yaml,io
for d in yaml.safe_load_all(io.open('/tmp/tempo3-render-fixed.yaml',encoding='utf-8')):
    if d and d.get('kind')=='Deployment' and d['metadata']['name'].startswith('tempo3-distributor'):
        for c in d['spec']['template']['spec']['containers']:
            print('args   :', c.get('args'))
            print('mounts :', [(v['name'],v['mountPath']) for v in c.get('volumeMounts',[])])
PY
#    → args: ['-target=distributor', '-config.file=/conf/tempo.yaml']
#    → mounts: [('config','/conf'), ('runtime-config','/runtime-config'), ...]

# ✅ 规则 2：校验"新配置"必须挂"新配置"，不能挂 live 对象
kubectl create cm tempo3-verify-config -n logging \
  --from-file=tempo.yaml=/tmp/<渲染后配置> --dry-run=client -o json | kubectl apply -f -
```

> ⚠️ `-config.verify` 在 Tempo 3.0.3 **需要一个值**（输出路径），写 `-config.verify` 会报 `flag needs an argument` 并打印完整 usage（退出码 2）。
> 正确写法：`-config.verify=/tmp/out.yaml`。
>
> 另外该镜像 **distroless，没有 `sleep`、没有 shell**。想用它当探查 Pod 主体必须直接跑 `/tempo`，不能 `--command -- sleep 900`（会报 `exec: "sleep": executable file not found in $PATH`）。

### 4.8 distroless 镜像探查 + `kubectl cp` 静默失败

想把 payload 送进探查 Pod 时踩了两个坑：

```bash
# ❌ kubectl cp 到 distroless 镜像：静默失败，文件根本没进去
kubectl cp /tmp/span.json apiq -n logging:/tmp/span.json   # 无输出 = 假成功
kubectl exec apiq -- ls -la /tmp/span.json
#   → ls: /tmp/span.json: No such file or directory
#   而 curl 报的是 "Failed to open /tmp/span.json"，很容易误以为是服务端问题

# ✅ 改用 base64 从 stdin 写入（curlimages/curl 有 base64 和 sh）
B64=$(base64 -w0 /tmp/span.json)
kubectl exec apiq -n logging -- sh -c "echo '$B64' | base64 -d > /tmp/span.json && wc -c < /tmp/span.json"
#   → 483
```

**`kubectl cp` 没有输出不等于成功**。凡是 cp 之后要用到该文件的，必须回读校验（`wc -c` / `head -1`）再继续。

另外 **`curl telnet://host:port` 在 `curlimages/curl` 里不可用**（返回 CLOSED，容易误判端口不通）。判断端口是否监听，改用真实协议探活：

```bash
# ✅ HTTP 端口：直接打，看返回码
curl -s -o /dev/null -w '%{http_code}' http://svc:4318/
#   → 404  ← 端口是通的！OTLP/HTTP 只接受 POST /v1/traces，GET 返回 404 属正常
```

---

## 5. 遗留与下一步

### 本轮未处理（按优先级）

| 优先级 | 项 | 说明 |
|---|---|---|
| ~~P0~~ ✅ | Grafana Loki datasource `X-Scope-OrgID: fake` | 已由人工完成配置 |
| ~~P0~~ ✅ | tempo3 13/13 CrashLoopBackOff | 已修复，见 §3。13/13 Running，端到端 trace 打通 |
| P1 | `detected_level` 全局缺失 | Loki 服务端 bloom-grep 索引未产出 level（§2.6）。7 天窗口新旧数据均为 0 |
| P1 | 18 个 Prometheus down target | 网络根因未定位 |
| P1 | CoreDNS 1 Pod `ImagePullBackOff` | `registry.k8s.io` → `64.233.188.82:443` i/o timeout，与 cloudflared 同属出网问题域 |
| P1 | `DNSConfigForming` 刷屏 | 3 个 nameserver 超过 `MAXDNSRESOLV`，需精简为 2 个不重复项 |
| P1 | Alloy `serviceMonitor.enabled: false` | 从未被 Prometheus 抓取，Alloy 自身指标不可见（与 Promtail 时代一致，非退化） |
| P1 | **tempo3 尚未接入任何 OTel SDK** | tempo3 现在**能收 span 了**（§3.7 已端到端验证），但集群里还没有应用真的往 `tempo3-distributor:4317/4318` 发数据。需要挑至少 1 个应用接入 OTel SDK，否则 trace 数据量会一直是 0 |
| P1 | tempo3 block 落 S3 的完整链路 | 已验证 `work.json` 写入（§3.7 第 14 项），但真实 trace block 需要累积到阈值才会 flush，需在接入 OTel SDK 后复查 `tempo-traces` 桶的 block 结构 |
| P2 | `tempo3` 遗留 ReplicaSet 清理 | 20 个 RS 中 15 个为 `0/0/0`（历史 upgrade 遗留），无实际影响。需要时可用 `helm history` 定位对应 revision 后逐个清理 —— **未经确认不执行** |
| P2 | 5.5h 日志窗口回填 | 可选。需按时间窗从各节点 `/var/log/pods` 定向重放 |
| P2 | Kafka 分区/RF 统一 | `tempo-traces` 12 partitions vs `auto_create_topic_default_partitions: 3`，RF=1 无冗余 |

### 经验沉淀（写给下一次迁移）

1. **换 chart 前先解包对照**：把旧 chart 与新 chart 的 `values.yaml` 顶层键做一次 `set` 差异，输出「旧 chart 有、新 chart 没有」的键清单 —— 那就是默认行为会消失的部分。
2. **values 层级不要凭记忆写**：用 `helm template` 看渲染结果，**对照修复前后的 Deployment/StatefulSet diff** 确认每项都真的生效。
3. **配置先离线校验再上线**：`alloy validate`（Alloy）/ `tempo -config.verify`（Tempo）都能用真实二进制离线加载配置，比在生产上试错安全得多。
4. **组件从 N 变 M 是最好的健康信号**：`alloy_component_controller_running_components` 从 4 变 5，一眼看出 source 组件补上了。
5. **报错文案不可尽信**：`have you set --web.enable-lifecycle` 是个陷阱，实际是配置校验失败。**以「上游有没有被调用过」为准，不以错误文案为准**。
6. **先复刻契约，再修功能**：标签名错了（`node` vs `node_name`）比完全不采集更难排查。
7. **签名错误要做指纹比对，不能只确认"用户存在"**：`access_key` 对 + `secret_key` 错是最难查的组合（AK 在 RGW 用户列表里能查到，人会以为凭据没问题）。用 `sha256(值)[:12]` 比对，**且不回显明文**。
8. **"静默的空"比"报错的错"更危险**：Alloy 是键写错层级被丢弃，Tempo 是开关没开导致分支不渲染成 `null`。两者都不报错，都表现为"没数据"。**解包 chart 源码逐个确认 `{{- if }}` 的条件**，是唯一可靠办法。
9. **升级前后各做一次「语义化 diff」**：用 python 把 values 扁平化逐键比对（`改 1 + 加 3，38 键未动`）。这比看 `git diff` 有效 —— `sort_keys=True` 会把整个文件重排，diff 全是噪音，人根本审不完。
10. **Pod 数变化先查 RS，不要直接当缩容**：`helm upgrade` 会把废弃 RS 缩到 0 并清掉孤儿 Pod。看到"少了 1 个 Pod"时，先确认 `replicas` 字段变更前后的值，再看 RS 的 `desired/cur`。
11. **端到端验证要串完整条链路**：tempo3 修好后我没有只验证"Pod Running + /ready 200"，而是**注入一条真 span 再查回来**（OTLP → distributor → Kafka → live-store → querier → query-frontend → API，含 tag 检索）。这才证明了 Kafka 通道、索引、查询全都没问题。
12. **S3 写入路径要由 Tempo 自己触发才算验证**：`aws cli` 写通 ≠ Tempo 写通。真正确认靠的是桶里出现了 `work.json`（`backend-scheduler flush 9 次 / 0 失败`）。

---

*文档生成时间：2026-09-28 18:10 CST（§0–§2）*
*补充时间：2026-09-28 18:55 CST（§3 tempo3 修复、§4.7–§4.8 新增踩坑）*
*执行人：OpenCode（受 LGMT 运维指令）*
*所有变更均可回滚，未删除任何数据或命名空间*
