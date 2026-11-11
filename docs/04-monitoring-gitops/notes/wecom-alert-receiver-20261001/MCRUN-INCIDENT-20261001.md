# logging/mcrun Pod 起不来 —— 根因与告警情况

| 项 | 值 |
|---|---|
| 记录时间 | 2026-10-01 17:05（UTC 09:05） |
| 对象 | `Pod/logging/mcrun` |
| 现象 | `ContainerCreating` 持续 **27 小时**，容器从未启动 |
| 根因 | **ConfigMap 命名空间错配** —— Pod 在 `logging`，引用的 `mc-cm` 被建在了 `default` |
| 当前告警 | 2 条 firing（`KubePodNotReady`、`KubeContainerWaiting`），均 `severity=warning` |
| 处置状态 | **未修复**（本文档只做诊断，修复需你确认） |

---

## 0. 一句话结论

`mcrun` 是一个**一次性运维任务 Pod**（裸 Pod，`restartPolicy: Never`，无 ownerReference），
用来给 MinIO 的 `loki-chunks` bucket 重设 ILM 生命周期规则。
它引用了同名的 ConfigMap `mc-cm`，但该 ConfigMap 建在 `default` 命名空间而 Pod 在 `logging`，
**kubelet 在 `logging` 里找不到它**，导致卷挂载永久失败、容器无法创建。
两条 warning 告警已持续触发 24–25 小时，投递正常。

---

## 1. 直接证据

### 1.1 Pod 状态

```console
$ kubectl get pod mcrun -n logging -o wide
NAME     READY   STATUS              RESTARTS   AGE    IP      NODE
mcrun    0/1     ContainerCreating   0          27h    <none>  m01
```

关键点：

| 字段 | 值 | 含义 |
|---|---|---|
| `RESTARTS` | **0** | 容器**从未成功启动过**，不是「启动后崩溃」 |
| `IP` | `<none>` | 从未分配到 Pod IP |
| `phase` | `Pending` | 卡在调度后、容器创建前 |
| `status.containerStatuses[0].state.waiting.reason` | `ContainerCreating` | 卡在卷挂载阶段 |
| `PodReadyToStartContainers` | `False` | kubelet 自己也认为还没准备好起容器 |
| `qosClass` | `BestEffort` | 无 requests/limits（`resources: {}`） |
| `ownerReferences` | **空** | 裸 Pod，无控制器托管 —— **不会被自动重建，也不会被自动清理** |

### 1.2 根因（kubelet 直接给出）

```console
$ kubectl describe pod mcrun -n logging | tail -5
Events:
  Type     Reason       Age                    From     Message
  ----     ------       ----                   ----     -------
  Warning  FailedMount  3m56s (x827 over 27h)  kubelet  MountVolume.SetUp failed
          for volume "script" : configmap "mc-cm" not found
```

事件计数与时间跨度：

| 项 | 值 |
|---|---|
| 重试次数 `count` | **827** |
| 首次 `2026-09-30T07:50:05Z` | 与 Pod `creationTimestamp` 完全一致 |
| 最近 `2026-10-01T11:36:11Z` | 至今仍在每轮退避后重试 |

**827 次重试、27 小时零成功** —— kubelet 一直报错，但从不放弃，也不会升级为别的错误。

### 1.3 ConfigMap 的实际位置（错配的铁证）

```console
$ kubectl get pod mcrun -n logging -o jsonpath='{.spec.volumes[?(@.name=="script")].configMap.name}'
mc-cm

$ kubectl get cm -A | grep mc-cm
default    mc-cm    1    27h      ← 在 default，不在 logging

$ kubectl get cm -n logging | grep mc-cm
（无输出）
```

Pod 里写的 volume 引用：

```yaml
volumes:
- name: script
  configMap:
    name: mc-cm        # ← ConfigMap 卷引用【没有 namespace 字段】
    defaultMode: 493
```

> **Kubernetes 的 ConfigMap volume 引用是命名空间内的相对引用，没有 `namespace` 字段。**
> Pod 在哪个 namespace，就只能在哪个 namespace 找 ConfigMap。
> 这不是配置写错语法，而是**两个对象被建在了不同的 namespace**。

---

## 2. 这个 Pod 想做什么

### 2.1 Pod 完整定义

```yaml
apiVersion: v1
kind: Pod                      # ← 裸 Pod，不是 Job
metadata:
  name: mcrun
  namespace: logging
  creationTimestamp: "2026-09-30T07:50:05Z"
spec:
  restartPolicy: Never         # ← 一次性任务语义
  nodeName: m01                # ← 已被指定到节点（非调度器分配）
  tolerations:
  - key: node-role.kubernetes.io/control-plane    # ← 容忍控制面 taint
    operator: Exists
    effect: NoSchedule
  containers:
  - name: c
    image: minio/mc:latest     # ← :latest 未固定版本
    imagePullPolicy: Always
    command: ["sh", "-c"]
    args: ["sh /tmp/mc.sh"]
    volumeMounts:
    - mountPath: /tmp/mc.sh
      name: script
      readOnly: true
      subPath: mc.sh
```

### 2.2 脚本内容（`default/mc-cm` 的 key `mc.sh`）

```sh
#!/bin/sh
set -e
mc alias set la http://10.0.0.31:7480 <access-key> <secret-key> >/dev/null
echo "=== all rules before ==="
mc ilm rule ls --json la/loki-chunks
# 拿到所有 rule id，一条条删
ids=$(mc ilm rule ls --json la/loki-chunks | python3 -c "...")
for id in $ids; do
  echo "removing $id"
  mc ilm rule remove --id "$id" la/loki-chunks
done
# 重新加一条，id 明确为 delete-old-logs，10 天
mc ilm rule add --expire-days 10 --id delete-old-logs la/loki-chunks
echo "=== rules after ==="
mc ilm rule ls --json la/loki-chunks
echo "=== bucket usage ==="
mc du la/loki-chunks
```

**意图**：清掉 MinIO `loki-chunks` bucket 上所有已存在的 ILM 规则，
只保留一条 `delete-old-logs`（10 天过期）。这是一次**破坏性重建**——
`set -e` 配合「先全删再加」的顺序，如果加规则那步失败，bucket 会处于**无生命周期规则**状态。

### 2.3 为什么需要 ILM 规则

`logging` 命名空间的 Loki 配置（`ConfigMap/logi`）注释里写明了历史脉络：

```yaml
# Before: retention_enabled=false + limits_config.retention_period=0s
# => logs lived forever; the only real deletion was the MinIO lifecycle rule.
retention_enabled: true
retention_delete_delay: 2h
delete_request_store: s3
...
limits_config:
  retention_period: 120h          # 5 天窗口，由 compactor 删除
```

即：**Loki 现在已启用原生 retention（120h / 5 天，由 compactor 负责删除）**，
不再单纯依赖 MinIO ILM 规则。这降低了本次失败的紧迫度，但见 §6。

---

## 3. 告警情况

### 3.1 当前全部活跃告警（`/api/v2/alerts`，共 4 条）

| 状态 | alertname | 命名空间 | severity | since | 持续 |
|---|---|---|---|---|---|
| active | `KubePodNotReady` | logging | warning | `2026-09-30T08:05:29` | **25.0 小时** |
| active | `KubeContainerWaiting` | logging | warning | `2026-09-30T08:50:29` | **24.2 小时** |
| active | `Phase2FixVerification` | phase2-verify | warning | `2026-09-28T09:30:13` | — |
| active | `Watchdog` | — | none | `2026-09-27T06:48:19` | — |

两条 logging 告警**都指向 `pod=mcrun`**，是本次故障的全部告警表现。

### 3.2 告警内容原文

```yaml
KubePodNotReady:
  summary:     Pod has been in a non-ready state for more than 15 minutes.
  description: Pod logging/mcrun has been in a non-ready state for longer than
               15 minutes on cluster .
  since:       2026-09-30T08:05:29Z   (for: 15m)

KubeContainerWaiting:
  summary:     Pod container waiting longer than 1 hour
  description: pod/mcrun in namespace logging on container c has been in waiting
               state for longer than 1 hour. (reason: "ContainerCreating") on cluster .
  since:       2026-09-30T08:50:29Z   (for: 1h)
```

### 3.3 触发时序（为什么这两个时间点）

```
07:50:05Z  Pod mcrun 创建          → 立刻开始 FailedMount（827 次至今）
   ↓ +15m
08:05:29Z  KubePodNotReady 触发    （规则 for: 15m）
   ↓ +1h
08:50:29Z  KubeContainerWaiting 触发（规则 for: 1h）
```

两条告警都是 `kube-state-metrics` 的通用规则，**没有任何 mcrun/loki/MinIO 专属告警**。
也就是说：即使这个 Pod 明天换成别的故障模式，也只会得到同样这两条泛化告警 ——
「配置了 ConfigMap 但放错 namespace」这个具体根因，告警系统里**没有任何规则能表达**。

### 3.4 告警投递链路（正常）

两条告警均命中 `severity=~"critical|warning"` 子路由，双发两个 receiver：

| receiver | 投递状态 |
|---|---|
| `wecom`（企业微信） | ✅ 成功。`08:27:21 Notify success receiver=wecom KubeContainerWaiting numAlerts=2`、`08:27:51 ... KubePodNotReady numAlerts=2` |
| `n8n-webhook` | ✅ 成功（历史累计 19 条 `Notify success`，含 logging 相关分组） |

**告警链路本身工作正常**，这两条告警已真实送达企业微信群和 n8n。
不是告警没发出去，是**被告警的对象真的坏了**。

### 3.5 一个观察：告警与故障的时间差

```
故障开始     2026-09-30 07:50:05Z   （Pod 创建即 FailedMount）
首次告警     2026-09-30 08:05:29Z   （+15 分 29 秒）
```

`KubePodNotReady` 的 `for: 15m` 生效正常。但注意：
**Pod 一创建就是坏的**，理论上更快的告警（如对 `Pending` 状态的即时检测）能提前 15 分钟发现。
这属于规则调优范畴，当前配置下 15 分钟是可接受的。

---

## 4. 为什么 27 小时才被发现 —— 根因分析

这是一次典型的**「一次性运维任务被当成长期服务部署」**的事故链条：

| 环节 | 缺陷 |
|---|---|
| ① 用裸 Pod 而非 Job | 无 ownerReference → 无自愈、无重试记录、无 `backoffLimit`；Pod 卡住时没有任何控制器介入 |
| ② `restartPolicy: Never` + 卡在 `Pending` | 容器从未启动，所以「一次性任务」的语义反而掩盖了问题 —— 它看起来像「还在排队」而不是「坏了」 |
| ③ ConfigMap 建在 `default` 而 Pod 在 `logging` | 命名空间错配。这类错误**不会在 apply 时报错**（两个对象各自都能创建成功），只在 kubelet 挂载时才暴露 |
| ④ 两个对象分两次创建 | `mc-cm`（`07:50:05Z`）与 `mcrun`（`07:50:05Z`）时间戳相同，说明是同一次操作，但创建者在 `default` 命名空间执行了 ConfigMap、在 `logging` 执行了 Pod |
| ⑤ 无人清理 | 裸 Pod 完成后不会自动删除；卡住时更不会。27 小时里一直占着告警位 |

**为什么 `default` 下有个 `mc-cm`**：`kubectl get cm -A` 显示 `default/mc-cm` 的
`creationTimestamp` 与 Pod 完全相同（`2026-09-30T07:50:05Z`），
且 `default` 命名空间下**没有任何 mc 相关 Pod** —— 说明 ConfigMap 建错了地方，本该在 `logging`。

---

## 5. 修复方案（未执行，需你确认）

### 方案 A：就地修好 ConfigMap 命名空间（推荐）

```bash
# 1) 备份脚本内容
kubectl get cm mc-cm -n default -o jsonpath='{.data.mc\.sh}' > /tmp/mc.sh

# 2) 在 logging 建同名 ConfigMap
kubectl create cm mc-cm -n logging --from-file=mc.sh=/tmp/mc.sh

# 3) 删除卡住的裸 Pod（裸 Pod 无控制器，会自动重建挂载）
kubectl delete pod mcrun -n logging

# 4) 观察任务执行（restartPolicy: Never，成功后变 Completed）
kubectl get pod mcrun -n logging -w
```

预期结果：Pod 变为 `Completed`，两条告警自动 resolve，kubelet 不再报 `FailedMount`。

**风险提示**：脚本是破坏性的（先删光 ILM 规则再加一条）。若 MinIO 上 `loki-chunks` 有多条规则，
这一步会**清掉除 `delete-old-logs` 外的所有规则**。执行前建议先只跑脚本的前两行
（`mc ilm rule ls`）确认现状。

### 方案 B：直接删除 Pod，放弃这次 ILM 重建

```bash
kubectl delete pod mcrun -n logging
kubectl delete cm mc-cm -n default
```

**适用前提**：确认 Loki 原生 retention（120h）已足够，不再需要 MinIO ILM 兜底。
若成立，这是最干净的处置 —— 任务没完成就没有留下的必要。

### 方案 C：改用 Job + 修正设计（推荐长期做法）

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: loki-ilm-reinit
  namespace: logging
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600     # 完成后自动清理
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: mc
        image: minio/mc:<固定版本>   # 不用 :latest
        command: ["sh", "-c"]
        args: ["sh /tmp/mc.sh"]
        volumeMounts:
        - mountPath: /tmp/mc.sh
          name: script
          subPath: mc.sh
      volumes:
      - name: script
        configMap:
          name: mc-cm               # ← 同 namespace，这次确保一致
```

Job 相比裸 Pod 的优势：有 `backoffLimit` 重试、有 `ttlSecondsAfterFinished` 自动清理、
状态可查（`succeeded`/`failed`）、不会被遗忘在集群里。

### 顺带应处理的凭据问题

`default/mc-cm` 与 `ConfigMap/logi` 中以**明文**存放 MinIO 凭据：

```
access_key_id:     <redacted-s3-access-key>
secret_access_key: <redacted>
```

ConfigMap **不做加密**，任何能读 ConfigMap 的主体都能拿到 MinIO 的读写凭据。
建议迁到 `Secret` + `envFrom`，或至少确认这些凭据的轮换状态。
（本次未改动，仅记录。）

---

## 6. 影响评估

| 维度 | 影响 | 严重度 |
|---|---|---|
| Loki 日志采集 | **无影响**。`alloy`(6/6) 、`loki-write-0`、`loki-backend-0`、`loki-read` 全部 `Running` | — |
| Loki 查询 | **无影响**。`loki-gateway`、`loki-results-cache-0`、`loki-chunks-cache-0` 均 `Running` | — |
| Tempo3 链路 | **无影响**。8 个 tempo3 Pod 全部 `Running` | — |
| MinIO ILM 规则 | **可能已偏离预期**。脚本从未执行，bucket 上的 ILM 规则仍是历史状态 | ⚠️ 中 |
| 日志留存成本 | Loki 原生 `retention_period: 120h` + compactor 已启用，删除不依赖 ILM 规则 | 低 |
| 告警噪音 | 2 条 warning 持续 firing 25 小时 | 低 |
| 凭据安全 | MinIO 凭据明文存于 ConfigMap | ⚠️ 中（既存问题） |

**logging 命名空间其余 30 个 Pod 全部健康**，本次故障是孤立的单个裸 Pod。

需要注意的是：如果 MinIO 侧的 ILM 规则配置原本就是错的（这可能正是这个任务要修的问题），
那么在 Loki compactor 之外，**S3 层没有任何第二道删除机制**，长期会累积存储成本。
建议查一下当前 `loki-chunks` 的实际 ILM 规则状态，再决定走方案 A 还是 B。

---

## 7. 相关背景

| 项 | 说明 |
|---|---|
| 同类 Pod | 早期会话中 `logging` 命名空间还有 `lokap`、`lokicfg`、`lokiconfig` 三个 Pod 同处 `Error`/`ContainerCreating`，现已消失（无 Job/CronJob 托管，属手工创建的裸 Pod）。当前该命名空间只剩 `mcrun` 一个异常 Pod |
| 审计报告关联 | `/root/alerting-coverage-audit-20260930.md` L317 记录 `loki-chunks-cache / results-cache / memcached` 三项缓存的监控状态；本 Pod 是运维脚本，不是监控组件 |
| 配置来源 | `ConfigMap/logi`、`ConfigMap/lokicf-cm`（后者是一个查询 Loki 配置的 python 脚本 ConfigMap，同样未挂在任何 Pod 上） |

---

## 8. 经验教训

1. **ConfigMap/Secret 卷引用是命名空间内的相对引用，没有 `namespace` 字段。**
   跨命名空间「看起来能用」的写法在 apply 阶段不会报错，只在 kubelet 挂载时暴露。

2. **一次性任务用裸 Pod 是隐患。** 裸 Pod 无 ownerReference，卡住时没有控制器介入，
   状态只存在于 `kubectl describe` 里。应改用 `Job` + `ttlSecondsAfterFinished`。

3. **`ContainerCreating` 卡住 27 小时只产生 2 条泛化告警** ——
   `KubePodNotReady` + `KubeContainerWaiting`，都无法表达「ConfigMap 缺失」这个真实根因。
   排查必须落到 `kubectl describe` 的 Events 上。

4. **kubelet 的 `FailedMount` 重试是静默的**：827 次重试、零告警升级。
   如果有对 kubelet 事件或 `volumes_mount` 失败的监控，能提前发现。

5. **告警链路本次表现完美** —— 两条告警都真实送达了企业微信和 n8n，
   链路健康与被监控对象故障是两件事，本次前者正常、后者异常。