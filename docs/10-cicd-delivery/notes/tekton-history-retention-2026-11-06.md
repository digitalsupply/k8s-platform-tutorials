# Tekton 安装、历史保留/清理与生产实践

> **2026-11-07 更新：本集群已迁移到 Tekton Operator v0.81.3，最终版本为 Pipelines v1.15.5 / Triggers v0.37.2 / Dashboard v0.71.0 / Pruner v0.4.4。旧的 1 天 `cicd-cleanup` CronJob 已删除，保留策略改为 30 天 TTL + 成功 200 / 失败 100。迁移全过程见 `tekton-operator-migration-2026-11-07.md`。本文以下内容保留为迁移前的历史记录。**
>
> 本文覆盖：本集群 Tekton 的安装方式、历史保留/清理配置、与 Operator/Helm 的对比及生产建议。
>
> 环境：Tekton Pipelines **v1.6.0**（standalone，无 Tekton Operator / TektonConfig）
> 命名空间：`cicd`
> 日期：2026-11-06

---

## 0. 结论先行

1. Tekton v1.6.0 的 `PipelineRun` / `TaskRun` CRD **没有** `ttlSecondsAfterFinished` 字段，不能像 Kubernetes Job 那样直接设置 TTL。
2. 本次用的是已有的 `cicd-cleanup` CronJob：
   - 只删除**已完成**且超过 `RETAIN_DAYS=1` 天的 PipelineRun；
   - 删除 PipelineRun 后，由 Kubernetes GC 级联删除 TaskRun → Pod → 由 `volumeClaimTemplate` 创建的 PVC；
   - 每 6 小时执行一次。
3. 这是**实验室/磁盘压力下**的激进配置；生产一般不会只留 1 天。
4. 生产环境常见做法：
   - 使用 **Tekton Operator 的 Pruner**（`TektonConfig.spec.pruner`，按数量或天数保留）；
   - 或使用 **事件驱动 Pruner**（`TektonConfig.spec.tektonpruner`，支持 TTL + history limit）；
   - standalone 安装则用 CronJob + `tkn`/自定义脚本；
   - 长期审计/回滚需求用 **Tekton Results** 归档，再对 K8s 对象做激进清理。

---

## 1. 本次实际配置

### 1.1 CronJob 现状

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cicd-cleanup
  namespace: cicd
spec:
  schedule: "0 */6 * * *"          # 每 6 小时
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: cicd-cleanup
          restartPolicy: OnFailure
          imagePullSecrets:
            - name: harbor-auth
          containers:
            - name: cleanup
              image: 192.168.67.202:8443/compassio/python:3.11-slim
              command: ["python", "/scripts/cleanup.py"]
              env:
                - name: RETAIN_DAYS
                  value: "1"
                - name: DRY_RUN
                  value: "false"
              volumeMounts:
                - name: script
                  mountPath: /scripts
                  readOnly: true
          volumes:
            - name: script
              configMap:
                name: cicd-cleanup-script
```

本次修改：

| 参数 | 原值 | 现值 | 原因 |
|---|---|---|---|
| `RETAIN_DAYS` | 7 | **1** | 磁盘压力大，先快速回收 |
| `schedule` | `0 3 * * *` | **`0 */6 * * *`** | 提高清理频率 |
| `nodeSelector` | 无 | 曾临时设为 worker03，后已移除 | Harbor 故障期间保证镜像可用 |

> `nodeSelector: worker03` 是故障期间的临时措施，**不应进入生产配置**。

### 1.2 RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cicd-cleanup
  namespace: cicd
rules:
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns"]
    verbs: ["get", "list", "delete"]
  - apiGroups: ["tekton.dev"]
    resources: ["taskruns"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list"]
```

- 只允许删除 PipelineRun；
- TaskRun/PVC 只读，用于统计和日志；
- 不授予 cluster-admin，符合最小权限。

### 1.3 清理脚本逻辑

ConfigMap `cicd-cleanup-script` 中的 Python 脚本核心逻辑：

1. 通过 ServiceAccount token 调用 K8s API；
2. 列出当前 namespace 的 PipelineRun、TaskRun、PVC；
3. 跳过带 `cleanup=keep` label/annotation 的 PipelineRun；
4. 只处理以下完成状态：
   - `Succeeded`
   - `Failed`
   - `Completed`
   - `PipelineRunTimeout`
   - `Cancelled`
5. 必须有 `status.completionTime`，且早于 `now - RETAIN_DAYS`；
6. 删除 PipelineRun，由 K8s GC 级联删除：
   - TaskRun
   - Pod
   - 由 `volumeClaimTemplate` 创建且 ownerReference 指向该 PipelineRun 的 PVC
7. 支持 `DRY_RUN=true` 只打印不删除。

关键片段：

```python
reason = reason_of(pr)
done_raw = (pr.get("status") or {}).get("completionTime")

if reason not in ("Succeeded", "Failed", "Completed",
                  "PipelineRunTimeout", "Cancelled") or not done_raw:
    # 跳过未完成/运行中的
    continue

done = datetime.datetime.fromisoformat(done_raw.replace("Z", "+00:00"))
if done >= cutoff:
    # 还在保留期内
    continue

# 只删 PipelineRun，交给 K8s GC 级联
api("DELETE", f"/apis/tekton.dev/v1/namespaces/{NS}/pipelineruns/{name}")
```

### 1.4 本次效果

| 对象 | 清理前 | 清理后 |
|---|---:|---:|
| PipelineRun | 35 | 3 |
| TaskRun | 112 | 级联清理 |
| cicd PVC | 36 | 4 |

后续新产生的 PipelineRun 继续按 1 天保留；当前实时数量会随 CI 运行变化。

---

## 2. 为什么不能直接配 `ttlSecondsAfterFinished`

在 Tekton v1.6.0：

```bash
kubectl explain pipelinerun.spec.ttlSecondsAfterFinished
# error: field "ttlSecondsAfterFinished" does not exist

kubectl explain taskrun.spec.ttlSecondsAfterFinished
# error: field "ttlSecondsAfterFinished" does not exist
```

PipelineRun CRD 的 `spec` 字段只有：

```text
managedBy, params, pipelineRef, pipelineSpec, status,
taskRunSpecs, taskRunTemplate, timeouts, workspaces
```

Kubernetes 的 `ttlSecondsAfterFinished` 是 **Job** 的字段，PipelineRun 不是 Job，所以不能直接套用。

> 注意：Tekton Operator 的**事件驱动 Pruner** 在 `TektonConfig` 里也有一个叫
> `ttlSecondsAfterFinished` 的配置项，但它是 **Pruner 的保留时长**，不是 PipelineRun spec 字段。

---

## 3. 生产环境一般怎么配

按安装方式分三种主流方案。

### 3.1 方案 A：Tekton Operator 的 Job-based Pruner（最常见）

如果集群用 Tekton Operator 安装，直接在 `TektonConfig` 配：

```yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  pruner:
    disabled: false
    schedule: "0 2 * * *"          # 每天凌晨 2 点
    startingDeadlineSeconds: 300
    resources:
      - pipelinerun
      - taskrun
    # keep: 200
    keep-since: 10080               # 分钟；10080 = 7 天
    prune-per-resource: true
```

参数说明（官方文档）：

| 字段 | 含义 |
|---|---|
| `disabled` | 是否禁用 pruner |
| `schedule` | Cron 表达式，决定多久跑一次 |
| `startingDeadlineSeconds` | 错过调度后的启动截止时间 |
| `resources` | `pipelinerun` / `taskrun`，可同时选 |
| `keep` | 最多保留多少个资源（按数量） |
| `keep-since` | 保留最近多少**分钟**内创建的资源（按时间） |
| `prune-per-resource` | `true` 时，按每个 Pipeline/Task 分别应用 `keep` |

**注意：`keep` 和 `keep-since` 二选一，不能同时设置。**

生产常见取值：

```yaml
# 保留最近 7 天
keep-since: 10080

# 或保留最近 200 个
keep: 200
```

按 namespace 覆盖：

```yaml
metadata:
  annotations:
    operator.tekton.dev/prune.schedule: "0 3 * * *"
    operator.tekton.dev/prune.keep-since: "43200"   # 30 天
    operator.tekton.dev/prune.resources: "pipelinerun,taskrun"
    operator.tekton.dev/prune.prune-per-resource: "true"
    # operator.tekton.dev/prune.skip: "true"       # 整个 namespace 跳过
```

### 3.2 方案 B：Tekton Operator 的事件驱动 Pruner（较新）

如果 Operator 版本支持 `tektonpruner`，可以用 TTL + history limit：

```yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  pruner:
    disabled: true                  # 必须先关闭 job-based pruner
  tektonpruner:
    disabled: false
    global-config:
      enforcedConfigLevel: namespace
      ttlSecondsAfterFinished: 604800   # 7 天
      historyLimit: 200
      successfulHistoryLimit: 150
      failedHistoryLimit: 50
      namespaces:
        dev:
          ttlSecondsAfterFinished: 86400  # 1 天
          historyLimit: 50
        prod:
          ttlSecondsAfterFinished: 2592000 # 30 天
          successfulHistoryLimit: 300
          failedHistoryLimit: 100
    options: {}
```

字段含义：

| 字段 | 含义 |
|---|---|
| `ttlSecondsAfterFinished` | 完成后保留多少秒 |
| `historyLimit` | 每个状态最多保留多少个 run |
| `successfulHistoryLimit` | 成功 run 保留数 |
| `failedHistoryLimit` | 失败 run 保留数 |
| `enforcedConfigLevel` | `global` 或 `namespace` |

**Job-based pruner 和事件驱动 pruner 不能同时启用。**

### 3.3 方案 C：standalone Tekton（当前环境）

没有 Tekton Operator 时，没有 `TektonConfig`，只能用 CronJob 或外部脚本。

#### 方式 1：自定义脚本（本次方案）

优点：

- 不依赖 `tkn` 镜像；
- 可以精确控制完成状态、保留天数、`cleanup=keep`；
- 可以先 `DRY_RUN` 验证。

生产建议：

```yaml
env:
  - name: RETAIN_DAYS
    value: "7"          # 生产一般 7–30 天
  - name: DRY_RUN
    value: "false"
schedule: "0 */6 * * *"
concurrencyPolicy: Forbid
timeZone: Asia/Shanghai   # Kubernetes 1.27+
```

#### 方式 2：`tkn` CLI CronJob

```yaml
containers:
  - name: pruner
    image: <你的 registry>/tkn:<version>
    command: ["/bin/sh", "-c"]
    args:
      - |
        tkn pipelinerun delete -n cicd --keep 200 --ignore-running
        tkn taskrun delete -n cicd --keep 500 --ignore-running
```

如果 `tkn` 版本支持 `--keep-since`，可以按时间：

```bash
tkn pipelinerun delete -n cicd --keep-since 168h --ignore-running
tkn taskrun delete -n cicd --keep-since 168h --ignore-running
```

> `--keep-since` 的具体可用性和单位以 `tkn <version> pipelinerun delete --help` 为准。

缺点：

- 需要维护 `tkn` 镜像；
- 需要 RBAC；
- 需要确认 `--keep` / `--keep-since` 的语义与版本。

#### 方式 3：安装 Tekton Operator

如果希望用官方 Pruner，可以把 standalone 安装迁移到 Tekton Operator；之后用 `TektonConfig` 管理，减少自维护脚本。

### 3.4 方案 D：Tekton Results + 激进清理（生产审计推荐）

生产环境通常不仅需要“删掉”，还需要“留痕”：

- **Tekton Results**：把 PipelineRun/TaskRun 记录和日志归档到数据库/对象存储；
- **Tekton Chains**：保存构建 provenance/签名；
- 然后 K8s 中的 PipelineRun 可以只保留 1–7 天，甚至更短；
- 审计/回滚查 Tekton Results，不依赖 K8s 对象。

这是“历史缩短”和“可追溯”之间的最佳平衡。

---

## 4. 生产保留策略建议

### 4.1 按环境

| 环境 | PipelineRun 保留 | 说明 |
|---|---|---|
| Dev | 1–3 天，或 keep 20–50 | 迭代快，日志价值低 |
| Staging | 7–14 天，或 keep 50–100 | 需要排查集成问题 |
| Prod | 7–30 天，或 keep 200–500 | 兼顾排障、审计、etcd 压力 |
| 合规/发布 | 30–90 天，或长期归档 | 用 Tekton Results/S3/Loki |

### 4.2 按成功/失败

| 类型 | 建议 |
|---|---|
| Succeeded | 7–14 天，或 keep 100–200 |
| Failed | 30–90 天，或长期归档 |
| Cancelled/Timeout | 7–30 天 |
| 发布/部署 | 打 `cleanup=keep` 或单独长保留 |

### 4.3 生产常用参数示例

**Job-based pruner：**

```yaml
pruner:
  disabled: false
  schedule: "0 2 * * *"
  startingDeadlineSeconds: 300
  resources:
    - pipelinerun
    - taskrun
  keep-since: 10080        # 7 天
  prune-per-resource: true
```

**事件驱动 pruner：**

```yaml
tektonpruner:
  disabled: false
  global-config:
    ttlSecondsAfterFinished: 604800   # 7 天
    successfulHistoryLimit: 150
    failedHistoryLimit: 50
```

**Standalone CronJob：**

```yaml
RETAIN_DAYS: "7"
schedule: "0 */6 * * *"
```

---

## 5. 本次配置 vs 生产建议

| 项目 | 本次（实验室） | 生产建议 |
|---|---|---|
| 保留天数 | **1 天** | 7–30 天，失败 run 更长 |
| 执行频率 | 每 6 小时 | 每天/每 6 小时，避开业务高峰 |
| 保留方式 | 仅按时间 | 时间 + 数量，或 Operator Pruner |
| 历史归档 | 无 | Tekton Results / S3 / Loki |
| 失败 run | 1 天后删除 | 30–90 天或长期归档 |
| 发布 run | 1 天后删除 | `cleanup=keep` 或单独保留 |
| 配置载体 | 自定义 CronJob | TektonConfig 或 GitOps 管理的 CronJob |
| 时区 | 未显式设置 | 显式 `Asia/Shanghai` |
| 镜像 | Harbor 私有镜像 | 固定 digest + 镜像仓库 HA |

> 1 天保留是为了快速回收磁盘，不适合作为生产默认值。

---

## 6. 删除 PipelineRun 会连带删除什么

### 6.1 级联关系

```text
PipelineRun
  ├── TaskRun
  │     └── Pod
  └── PVC（由 volumeClaimTemplate 创建，且 ownerReference 指向 PipelineRun）
```

删除 PipelineRun 后，Kubernetes GC 会级联删除：

- TaskRun；
- TaskRun 对应的 Pod；
- 由该 PipelineRun 创建的 workspace PVC；
- 对应的 Pod 日志（如果未采集）。

### 6.2 不会自动删除的内容

- 外部对象存储中的日志/制品（如果已归档）；
- 手工创建、没有 ownerReference 的 PVC；
- 共享 PVC（多个 run 共用）；
- Tekton Results 中的记录（如果已归档）。

### 6.3 风险

- 如果 PVC 被其他 Pod 共享，删除 PipelineRun 可能导致 PVC 被删；
- 如果日志未采集，删除后无法排查；
- 如果有审计要求，必须先归档；
- 如果 PipelineRun 仍在运行，脚本应跳过（本次脚本只处理有 `completionTime` 的完成态）。

---

## 7. 生产落地注意事项

### 7.1 安全

- RBAC 最小权限：只给 `pipelineruns` 的 `get/list/delete`，`taskruns`/`pvc` 的 `get/list`；
- 不要用 `cluster-admin`；
- 镜像固定 digest，避免供应链风险；
- `imagePullSecrets` 使用专用账号；
- 清理脚本放在 GitOps 仓库，变更可审计。

### 7.2 可靠性

- `concurrencyPolicy: Forbid`，避免重叠；
- `startingDeadlineSeconds` 防止错过调度；
- `backoffLimit` 不要太大，失败要告警；
- `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` 控制 Job 自身堆积；
- CronJob 失败要告警（否则历史会悄悄涨回来）。

### 7.3 时间与顺序

- 显式设置 `timeZone: Asia/Shanghai`（K8s 1.27+），避免 controller 默认 UTC 造成误解；
- 先 `DRY_RUN=true` 跑一次，确认删除列表；
- 首次大规模清理前，先归档/备份；
- 清理顺序：先 PipelineRun，级联 TaskRun/Pod/PVC，不建议单独删 TaskRun 再删 PipelineRun。

### 7.4 审计与可观测性

- 监控 PipelineRun/TaskRun 数量、最老 run 年龄、PVC 数量、etcd 大小；
- 记录每次删除的资源名和数量（本次脚本会打印 `DELETE ... pvc=N taskruns=M`）；
- 对重要流水线打 `cleanup=keep`；
- 生产建议部署 Tekton Results，把日志/记录与 K8s 对象解耦。

---

## 8. 推荐落地顺序

1. **确认安装方式**：
   - 有 Tekton Operator → 用 `TektonConfig.spec.pruner` 或 `tektonpruner`；
   - standalone → 用 CronJob + 脚本/`tkn`。
2. **先 DRY_RUN**：
   - 自定义脚本设 `DRY_RUN=true`；
   - 确认删除列表、PVC 数量、是否有运行中的 run。
3. **设置保留策略**：
   - 生产 7–30 天；失败 run 30–90 天；
   - 发布 run 打 `cleanup=keep`。
4. **部署 Tekton Results（如需要审计）**：
   - 先归档，再激进清理。
5. **加监控告警**：
   - CronJob 失败、PipelineRun 数量异常、PVC 数量异常、etcd 增长。
6. **定期复盘**：
   - 观察 1–2 周，调整 `RETAIN_DAYS` / `keep` / `keep-since`。

---

## 9. 附录：本次清理脚本关键代码

```python
import os, json, ssl, urllib.request, datetime

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
NS = open(f"{SA}/namespace").read().strip()
TOKEN = open(f"{SA}/token").read().strip()
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")
BASE = "https://kubernetes.default.svc"
RETAIN_DAYS = int(os.getenv("RETAIN_DAYS", "7"))
DRY_RUN = os.getenv("DRY_RUN", "false").lower() in ("1", "true", "yes")

def api(method, path):
    req = urllib.request.Request(
        BASE + path, method=method,
        headers={"Authorization": "Bearer " + TOKEN},
    )
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}

def list_all(path):
    items, cont = [], ""
    while True:
        sep = "&" if "?" in path else "?"
        data = api("GET", path + (f"{sep}continue={cont}" if cont else ""))
        items += data.get("items", [])
        cont = (data.get("metadata") or {}).get("continue", "")
        if not cont:
            return items

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=RETAIN_DAYS)

prs = list_all(f"/apis/tekton.dev/v1/namespaces/{NS}/pipelineruns?limit=200")
pvs = list_all(f"/api/v1/namespaces/{NS}/persistentvolumeclaims?limit=200")
trs = list_all(f"/apis/tekton.dev/v1/namespaces/{NS}/taskruns?limit=500")

def reason_of(pr):
    c = (pr.get("status") or {}).get("conditions") or []
    return c[0].get("reason") if c else None

stats = {"deleted": 0, "skipped": 0, "pvc": 0, "taskrun": 0}
for pr in prs:
    name = pr["metadata"]["name"]
    labels = pr["metadata"].get("labels") or {}
    ann = pr["metadata"].get("annotations") or {}

    if labels.get("cleanup") == "keep" or ann.get("cleanup") == "keep":
        stats["skipped"] += 1
        continue

    reason = reason_of(pr)
    done_raw = (pr.get("status") or {}).get("completionTime")

    if reason not in ("Succeeded", "Failed", "Completed",
                      "PipelineRunTimeout", "Cancelled") or not done_raw:
        stats["skipped"] += 1
        continue

    done = datetime.datetime.fromisoformat(done_raw.replace("Z", "+00:00"))
    if done >= cutoff:
        stats["skipped"] += 1
        continue

    owned_pvc = [
        p["metadata"]["name"] for p in pvs
        if any(o.get("kind") == "PipelineRun" and o.get("name") == name
               for o in (p["metadata"].get("ownerReferences") or []))
    ]
    owned_tr = [
        t["metadata"]["name"] for t in trs
        if (t["metadata"].get("labels") or {}).get("tekton.dev/pipelineRun") == name
    ]

    print(f"{'DRY-RUN ' if DRY_RUN else ''}DELETE {name} "
          f"({reason}, {done_raw}) pvc={len(owned_pvc)} taskruns={len(owned_tr)}")
    stats["deleted"] += 1
    stats["pvc"] += len(owned_pvc)
    stats["taskrun"] += len(owned_tr)

    if not DRY_RUN:
        api("DELETE", f"/apis/tekton.dev/v1/namespaces/{NS}/pipelineruns/{name}")

print("done:", json.dumps({**stats, "retain_days": RETAIN_DAYS, "dry_run": DRY_RUN}))
```

---

## 10. 一句话总结

**本次是 standalone Tekton + 自定义 CronJob：只删超过 1 天的已完成 PipelineRun，级联清理 TaskRun/Pod/PVC，每 6 小时一次。生产环境一般不会只留 1 天：用 Tekton Operator 的 `spec.pruner`（`keep` 或 `keep-since`）或事件驱动 `tektonpruner`（TTL/history limits），保留 7–30 天，失败/发布 run 更长，并用 Tekton Results 做长期归档。**

---

# 第二部分：本集群 Tekton 的安装方式与方案对比

## 11. 本集群 Tekton 是怎么装的？

### 11.1 结论

从集群资源元数据看：

> **不是 Helm，不是 Tekton Operator，也不是 ArgoCD 管理；是用 `kubectl apply -f` 官方 release YAML 手工安装的。**

### 11.2 判断依据

| 检查项 | 结果 | 说明 |
|---|---|---|
| Helm release secret | 没有 | 不是 `helm install` |
| `TektonConfig` / Operator CRD | 没有 | 不是 Tekton Operator |
| ArgoCD Application | 没有 Tekton 相关 Application | 不是 GitOps 管理 |
| `managedFields` | `kubectl-client-side-apply` | 典型的 `kubectl apply` |
| `last-applied-configuration` | 存在 | 客户端 apply 留下的注解 |
| 版本标签 | `pipeline.tekton.dev/release: v1.6.0`、`triggers.tekton.dev/release: v0.34.0`、`dashboard.tekton.dev/release: v0.63.1` | 与官方 release YAML 的标签一致 |
| 命名空间 | `tekton-pipelines`、`tekton-pipelines-resolvers` | Pipelines/Triggers/Dashboard 在同一命名空间 |
| PodSecurity | `pod-security.kubernetes.io/enforce: restricted` | 与官方 release 的命名空间标签一致 |

### 11.3 组件与版本

| 组件 | 版本 | 命名空间 | Deployment |
|---|---|---|---|
| Tekton Pipelines | **v1.6.0** | `tekton-pipelines` | `tekton-pipelines-controller`、`tekton-pipelines-webhook`、`tekton-events-controller` |
| Tekton Triggers | **v0.34.0** | `tekton-pipelines` | `tekton-triggers-controller`、`tekton-triggers-webhook`、`tekton-triggers-core-interceptors` |
| Tekton Dashboard | **v0.63.1** | `tekton-pipelines` | `tekton-dashboard`（read-only 模式） |
| Tekton Resolvers | **v1.6.0** | `tekton-pipelines-resolvers` | `tekton-pipelines-remote-resolvers` |

CRD 包括：

```text
pipelineruns.tekton.dev
taskruns.tekton.dev
pipelines.tekton.dev
tasks.tekton.dev
customruns.tekton.dev
stepactions.tekton.dev
resolutionrequests.resolution.tekton.dev
verificationpolicies.tekton.dev
triggers.tekton.dev
triggerbindings.tekton.dev
triggertemplates.tekton.dev
eventlisteners.triggers.tekton.dev
clusterinterceptors.triggers.tekton.dev
clustertriggerbindings.triggers.tekton.dev
interceptors.triggers.tekton.dev
extensions.dashboard.tekton.dev
```

### 11.4 安装时间

- `pipelines-info` ConfigMap 的 `creationTimestamp`：**2026-01-28T08:22:14Z**；
- 命名空间年龄约 **283 天**；
- 说明这套 Tekton 已经稳定运行较长时间。

### 11.5 最可能的安装命令

按官方 release 的安装方式，应该是：

```bash
# 1) Tekton Pipelines v1.6.0
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.6.0/release.yaml

# 2) Tekton Triggers v0.34.0
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml

# 3) Tekton Dashboard v0.63.1
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.63.1/tekton-dashboard-release.yaml
```

补充：

- `tekton-pipelines-resolvers` 通常包含在 Pipelines release 中；如果不是，则额外 apply 了 resolvers release。
- Triggers 和 Dashboard 默认都装在 `tekton-pipelines` 命名空间。
- 因为是 client-side apply，所以资源上都有 `kubectl.kubernetes.io/last-applied-configuration`。
- 本机 shell history 里没有留下安装命令；以上是根据资源标签、版本、`managedFields` 和 `last-applied` 注解还原的。

### 11.6 如何自行验证

```bash
# 版本
kubectl -n tekton-pipelines get cm pipelines-info -o jsonpath='{.data.version}'
# v1.6.0

kubectl -n tekton-pipelines get deploy tekton-triggers-controller \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'
# v0.34.0

kubectl -n tekton-pipelines get deploy tekton-dashboard \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'
# v0.63.1

# 安装方式痕迹
kubectl get crd pipelines.tekton.dev \
  -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}'
# kubectl-client-side-apply

kubectl -n tekton-pipelines get deploy -o yaml | grep -E 'helm|argocd'
# 无输出

kubectl get crd | grep operator.tekton.dev
# 无输出
```

---

## 12. 官方 YAML / Operator / Helm 对比

| 维度 | 官方 YAML + `kubectl apply`（当前） | Tekton Operator | Helm（社区 chart） |
|---|---|---|---|
| 官方支持 | 官方 release，但无生命周期管理 | **官方推荐的生命周期方案** | Pipelines/Triggers 无官方 Helm chart，多为社区维护 |
| 安装复杂度 | 低，逐组件 apply | 中，装 Operator + TektonConfig | 中，装 chart + values |
| 升级 | 手工 apply 新 release，容易漏组件 | Operator 统一管理，升级路径清晰 | `helm upgrade`，但 **CRD 不会自动升级** |
| 回滚 | 基本靠手工/备份 | 可回滚 Operator/CR 版本 | `helm rollback`，CRD 例外 |
| 漂移检测 | 无，除非接 ArgoCD/Kustomize | TektonConfig 声明式管理 | Helm values + GitOps |
| CRD 生命周期 | 手工管理，升级 CRD 风险高 | Operator 负责 | Helm 的 `crds/` 只安装不升级，仍需手工 |
| Pruner | **需自制**（当前 CronJob） | **内置** job-based / event-based pruner | 需自制 |
| 多组件（Dashboard/Results/Chains） | 逐个安装、逐个升级 | 一个 `TektonConfig` 管多个组件 | 多个 chart，版本协调麻烦 |
| 组件版本兼容 | 手工维护兼容矩阵 | Operator 负责兼容 | chart 维护者负责 |
| 可观测/运维 | 自己看 Deployment/CRD | Operator 状态 + CR | Helm release 状态 |
| 适合场景 | 实验室、小团队、air-gapped 手工管理 | **生产、多团队、长期平台** | 组织强制 Helm 标准，且接受社区 chart |
| 本集群适配度 | 当前可用，但偏手工 | **长期推荐** | 可用，但不是首选 |

### 12.1 官方 YAML + `kubectl apply`

优点：

- 简单透明：就是官方 YAML，资源一眼看到底，排障直接；
- 组件少：没有 Operator/CRD 额外控制器；Harbor 故障时受影响面更小；
- 升级可控：可以精确控制每个组件版本，适合实验/学习；
- air-gapped 友好：把 release YAML 和镜像同步到内网即可。

缺点：

- 没有生命周期管理：Pipelines/Triggers/Dashboard/Resolvers 要分别 apply、分别升级；
- 没有 drift 检测/回滚：改错了只能靠备份和手工恢复；
- CRD 升级风险：Tekton 升级时 CRD 变更需要手工处理，容易漏；
- 没有内置 Pruner：需要自己写清理 CronJob；
- 版本兼容靠人记：Pipelines/Triggers/Dashboard 的兼容矩阵要自己维护；
- 没有 GitOps 审计：当前安装是一次性 `kubectl apply`，没有 Git 记录。

### 12.2 Tekton Operator

优点：

- 官方生命周期方案：一个 `TektonConfig` 管理 Pipelines、Triggers、Dashboard、Results、Chains 等；
- 升级/回滚更规范：Operator 负责组件版本和 CRD 生命周期；
- 内置 Pruner：
  - job-based：`spec.pruner` 的 `keep` / `keep-since`
  - event-based：`spec.tektonpruner` 的 `ttlSecondsAfterFinished` / history limits
  - 可以替代当前自定义 CronJob；
- 减少自制代码：清理、组件配置、部分 RBAC 都由 Operator 管；
- 适合多团队/长期平台：配置声明式，容易纳入 GitOps。

缺点：

- 多一层 Operator：多一个控制器、CRD 和镜像；Harbor 故障时要多同步一些镜像；
- 迁移不是零成本：从手工安装迁移到 Operator，可能需要清理/重装或做 adoption 测试；CRD 是 cluster-scoped，要谨慎；
- Operator 版本兼容性：Operator 与 K8s/Tekton 版本也有矩阵；
- 排障多一层：出问题时要看 Operator 和组件两层。

### 12.3 Helm

优点：

- 有 release 历史、`helm rollback`、values 管理；
- 容易接 ArgoCD/Flux；
- 对“组织强制 Helm 标准”的团队友好。

缺点：

- Tekton 官方没有为 Pipelines/Triggers 提供官方 Helm chart，常用的是社区 chart；
- 社区 chart 版本可能滞后于 Tekton release；
- **Helm 不会自动升级 CRD**：`crds/` 目录只在首次安装时生效，升级 CRD 仍需手工；
- chart 的 values 与官方 release 可能有偏差；
- 如果 chart 停止维护，迁移成本高；
- 没有内置 Pruner，仍要自己做清理。

---

## 13. 结合本集群的建议

### 13.1 短期（现在）

**继续用当前方式可以，但建议做三件事：**

1. **把官方 release YAML 纳入 Git**
   - 不要只存在 shell history 里；
   - 用 ArgoCD/Kustomize 管理，至少获得审计和 drift 检测。

2. **维护版本矩阵和升级 runbook**
   - Pipelines 1.6.0 / Triggers 0.34.0 / Dashboard 0.63.1；
   - 升级前 `kubectl diff`，备份 CRD 和 `tekton-pipelines` 命名空间；
   - 按 Pipelines → Triggers → Dashboard 顺序升级。

3. **保留并完善自定义 Pruner**
   - 当前 `cicd-cleanup` 已经能用；
   - 加失败告警，避免 Harbor/镜像问题导致静默失败。

### 13.2 中长期（如果这套 CI 要生产化）

**建议迁移到 Tekton Operator + ArgoCD 管理 TektonConfig。**

理由：

- 已经有 ArgoCD，GitOps 基础具备；
- 多组件（Pipelines/Triggers/Dashboard/Resolvers）手工升级容易漏；
- Operator 内置 Pruner，可以去掉自定义清理脚本；
- 生产环境需要可重复的升级/回滚和版本兼容管理。

### 13.3 迁移清单

1. 导出所有 Pipeline/Task/Trigger/TriggerTemplate/TriggerBinding/EventListener 定义到 Git；
2. 备份 CRD、`tekton-pipelines` 命名空间、etcd；
3. 在测试集群验证 Operator 能否接管现有 CRD/资源，检查冲突；
4. 规划维护窗口：Tekton CRD 是 cluster-scoped，迁移有风险；
5. 安装 Operator，创建 `TektonConfig`，验证组件版本；
6. 启用 Operator Pruner 后，删除/停用自定义 `cicd-cleanup`；
7. 检查 `tekton-pipelines` 的 PodSecurity restricted 是否与 Operator 组件兼容；
8. 更新 ArgoCD/GitOps，监控 1–2 周。

### 13.4 如果坚持 Helm

只有在以下条件才建议：

- 组织强制 Helm；
- 选用维护活跃、版本跟得上的 chart；
- 接受 CRD 仍需手工升级；
- 有专人维护 chart values 和升级流程。

否则，**Operator 比 Helm 更适合 Tekton**。

---

## 14. 安装方式总结

**当前这套 `kubectl apply` 官方 YAML 对这台 6 节点实验集群是够用的，283 天稳定运行也证明了这一点；但它属于手工生命周期管理，不适合作为长期生产平台。生产化建议用 Tekton Operator + ArgoCD 管理 TektonConfig，内置 Pruner 也能替代现在的自定义清理 CronJob；Helm 不是 Tekton 的首选，除非组织强制且接受社区 chart 与 CRD 手工升级的代价。**

---

# 第三部分：Tekton Dashboard 的 Web 暴露与 403 排查

## 15. Tekton Dashboard 是 Web UI

### 15.1 原始状态

本集群的 Dashboard：

```text
Deployment: tekton-dashboard
Version:    v0.63.1
Namespace:  tekton-pipelines
Node:       worker01
Args:       --read-only=true
            --stream-logs=true
            --pipelines-namespace=tekton-pipelines
            --triggers-namespace=tekton-pipelines
```

原始 Service：

```text
NAME               TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
tekton-dashboard   ClusterIP   10.101.112.251   <none>        9097/TCP
```

结论：

- Dashboard 是 Web UI；
- 默认只有 ClusterIP，**没有对外暴露**；
- 没有 Ingress / IngressRoute / HTTPRoute；
- 只能通过 `kubectl port-forward` 访问。

临时访问：

```bash
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097
# 浏览器打开 http://localhost:9097
```

---

## 16. 通过 Traefik 暴露 `tekton.xyz`

### 16.1 创建的资源

| 资源 | 命名空间 | 作用 |
|---|---|---|
| `Secret/tekton-dashboard-auth` | `tekton-pipelines` | BasicAuth 用户 |
| `Secret/tekton-dashboard-tls` | `tekton-pipelines` | `tekton.xyz` 自签名证书 |
| `Middleware/tekton-dashboard-auth` | `tekton-pipelines` | BasicAuth |
| `Middleware/tekton-dashboard-https` | `tekton-pipelines` | HTTP → HTTPS |
| `Middleware/tekton-dashboard-strip-auth` | `tekton-pipelines` | **删除 Authorization 头**，修复 403 |
| `IngressRoute/tekton-dashboard` | `tekton-pipelines` | HTTPS 路由 `Host(tekton.xyz)` |
| `IngressRoute/tekton-dashboard-http` | `tekton-pipelines` | HTTP 301 跳转 |

### 16.2 IngressRoute 配置

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`tekton.xyz`)
      middlewares:
        - name: tekton-dashboard-auth
        - name: tekton-dashboard-strip-auth
      services:
        - name: tekton-dashboard
          port: 9097
          scheme: http
  tls:
    secretName: tekton-dashboard-tls
```

HTTP 跳转：

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: tekton-dashboard-http
  namespace: tekton-pipelines
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`tekton.xyz`)
      middlewares:
        - name: tekton-dashboard-https
      services:
        - name: tekton-dashboard
          port: 9097
          scheme: http
```

### 16.3 BasicAuth 和 TLS

BasicAuth Secret 的 key 必须是 `users`：

```bash
# 生成密码和 htpasswd（openssl 可用）
PASS=$(openssl rand -hex 8)
printf 'admin:%s\n' "$(openssl passwd -apr1 "$PASS")" > /tmp/tekton-users

kubectl -n tekton-pipelines create secret generic tekton-dashboard-auth \
  --from-file=users=/tmp/tekton-users

# 保存明文密码到本机，权限 600
printf 'admin:%s\n' "$PASS" > /root/tekton-dashboard-credentials.txt
chmod 600 /root/tekton-dashboard-credentials.txt
rm -f /tmp/tekton-users
```

自签名 TLS：

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout /tmp/tekton.key -out /tmp/tekton.crt \
  -subj "/CN=tekton.xyz" \
  -addext "subjectAltName=DNS:tekton.xyz"

kubectl -n tekton-pipelines create secret tls tekton-dashboard-tls \
  --cert=/tmp/tekton.crt --key=/tmp/tekton.key
```

> 当前集群没有公网 ClusterIssuer；这与 `argocd-tls`、`studyfree-xyz-tls` 的自签名模式一致。
> 要换正式证书，需要先把 `tekton.xyz` DNS 指向本集群入口，再配 cert-manager/ACME。

---

## 17. 故障：加载 Pipelines 时出错 / 403 system:anonymous

### 17.1 现象

浏览器打开 `https://tekton.xyz`，Dashboard 页面能加载，但列表报错：

```text
加载 Pipelines 时出错
{
  "stack": "Error ... at Object.oM [as queryFn] ...",
  "message": "",
  "response": {}
}
```

用 curl 直接请求 API：

```bash
curl -sk -u admin:<password> \
  --resolve tekton.xyz:443:10.0.0.252 \
  https://tekton.xyz/apis/tekton.dev/v1/namespaces/cicd/pipelines
```

返回：

```json
{
  "kind": "Status",
  "status": "Failure",
  "message": "pipelines.tekton.dev is forbidden: User \"system:anonymous\"
              cannot list resource \"pipelines\" in API group \"tekton.dev\"
              in the namespace \"cicd\"",
  "reason": "Forbidden",
  "code": 403
}
```

### 17.2 对比：绕过 Traefik 直接访问

```bash
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 19099:9097
curl -s http://127.0.0.1:19099/apis/tekton.dev/v1/namespaces/cicd/pipelines
```

返回 **200**，而且是以：

```text
system:serviceaccount:tekton-pipelines:tekton-dashboard
```

身份访问的。

说明：

- Dashboard 的 ServiceAccount 和 RBAC 正常；
- 问题出在 Traefik 到 Dashboard 之间的认证头。

### 17.3 根因

Traefik 的 BasicAuth 中间件会在请求中保留/转发：

```text
Authorization: Basic base64(admin:password)
```

Tekton Dashboard 的 Kube API 代理会读取传入的 `Authorization` 头，并把它当作 **Kubernetes Bearer token** 去访问 API Server。

但 `Basic ...` 不是合法的 K8s token，API Server 就按匿名用户处理：

```text
system:anonymous → 403 Forbidden
```

所以：

- 页面静态资源能加载（不需要 K8s API）；
- 所有列表 API 都 403；
- 错误信息里的 `response: {}` 就是前端拿到的 403/空响应。

### 17.4 修复：BasicAuth 之后删除 Authorization 头

新增 Traefik `headers` 中间件：

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: tekton-dashboard-strip-auth
  namespace: tekton-pipelines
spec:
  headers:
    customRequestHeaders:
      Authorization: ""
```

把中间件加到 IngressRoute 的 BasicAuth 之后：

```yaml
middlewares:
  - name: tekton-dashboard-auth
  - name: tekton-dashboard-strip-auth
```

执行：

```bash
kubectl apply -f - <<'YAML'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: tekton-dashboard-strip-auth
  namespace: tekton-pipelines
spec:
  headers:
    customRequestHeaders:
      Authorization: ""
YAML

kubectl -n tekton-pipelines patch ingressroute tekton-dashboard --type=json -p='[
  {"op":"add","path":"/spec/routes/0/middlewares/-",
   "value":{"name":"tekton-dashboard-strip-auth"}}
]'
```

原理：

- BasicAuth 仍然在 Traefik 层校验用户名/密码；
- 校验通过后，`strip-auth` 删除 `Authorization` 头；
- Dashboard 收不到 Authorization，就回退使用自己的 ServiceAccount；
- ServiceAccount 有只读权限，Dashboard 正常列出 Pipeline/PipelineRun。

### 17.5 验证

修复后：

```bash
curl -sk -u admin:<password> \
  --resolve tekton.xyz:443:10.0.0.252 \
  https://tekton.xyz/apis/tekton.dev/v1/namespaces/cicd/pipelines
# HTTP 200，返回 Pipeline 列表

curl -sk -u admin:<password> \
  --resolve tekton.xyz:443:10.0.0.252 \
  https://tekton.xyz/api/v1/namespaces
# HTTP 200，返回 NamespaceList
```

浏览器：

- 强制刷新（Ctrl/Cmd + Shift + R）；
- 如果仍失败，清理该站点的 BasicAuth 缓存后重试。

---

## 18. 访问、DNS 与安全注意

### 18.1 访问信息

| 项目 | 值 |
|---|---|
| URL | `https://tekton.xyz` |
| 用户名 | `admin` |
| 密码 | 见 `/root/tekton-dashboard-credentials.txt` |
| TLS | 自签名 `tekton.xyz` |
| 认证 | Traefik BasicAuth |
| Dashboard | read-only |

### 18.2 DNS 现状

当前 `tekton.xyz` 解析到：

```text
44.232.173.249
52.40.42.113
```

不是本集群 Traefik 的 `10.0.0.252`。

因此：

- 内网访问：在客户端加 hosts：
  ```text
  10.0.0.252 tekton.xyz
  ```
- 公网访问：需要把 `tekton.xyz` A 记录指向本集群公网入口，并把 443 转发到 `10.0.0.252:443`（或通过 FRP/反代）。
- 本地验证（绕过 DNS）：
  ```bash
  curl -k --resolve tekton.xyz:443:10.0.0.252 \
    -u admin:<password> \
    https://tekton.xyz/
  ```

### 18.3 安全注意

- Dashboard 是 `--read-only=true`，不能从 UI 修改资源；
- 但日志、Pipeline 定义、镜像地址仍可能敏感；
- BasicAuth 是必要的，不建议公网裸奔；
- 更严格可以用 OIDC/forward-auth 替代 BasicAuth；
- 自签名证书浏览器会提示不受信任，正式使用建议换 ACME 证书。

### 18.4 撤销

```bash
kubectl -n tekton-pipelines delete ingressroute tekton-dashboard tekton-dashboard-http
kubectl -n tekton-pipelines delete middleware \
  tekton-dashboard-auth tekton-dashboard-https tekton-dashboard-strip-auth
kubectl -n tekton-pipelines delete secret \
  tekton-dashboard-auth tekton-dashboard-tls
```

---

## 19. Dashboard 暴露排障总结

**Dashboard 是 Web UI，默认只有 ClusterIP。通过 Traefik 暴露时，BasicAuth 会保留 `Authorization: Basic ...` 头；Dashboard 的 Kube API 代理会把它当 K8s token 转发，导致 `system:anonymous` 403。修复方法是在 BasicAuth 之后加一个 `headers.customRequestHeaders.Authorization: ""` 中间件删除该头，让 Dashboard 回退使用自己的只读 ServiceAccount。**
