# Tekton standalone 迁移到 Operator v0.81.3 + GitOps 执行记录

> 环境：K8s v1.35.9，3 master + 3 worker
> 迁移日期：2026-11-07
> 目标：Tekton 从 standalone 官方 YAML 迁移到 Tekton Operator，纳入 ArgoCD GitOps，保留策略从“1 天”改为生产级的 30 天

---

## 0. 结果摘要

| 项目 | 迁移前 | 迁移后 |
|---|---|---|
| 安装方式 | `kubectl apply` 官方 release YAML | **Tekton Operator v0.81.3** |
| Pipelines | v1.6.0 | **v1.15.5** |
| Triggers | v0.34.0 | **v0.37.2** |
| Dashboard | v0.63.1（read-only） | **v0.71.0（read-only）** |
| Pruner | 自定义 `cicd-cleanup` CronJob，保留 1 天 | **事件驱动 Pruner v0.4.4，保留 30 天** |
| GitOps | 无 | **ArgoCD Application：`tekton-operator`、`tekton-config`** |
| TektonConfig | 无 | **Ready=True，Operator v0.81.3** |
| 现有 Tekton 资源 | 4 Pipelines / 12 Tasks / 2 PipelineRuns / 4 TaskRuns 等 | **全部保留** |
| 旧 1 天清理 CronJob | `cicd-cleanup` | **已删除**（备份保留） |

ArgoCD 状态：

```text
tekton-operator   Synced   Healthy
tekton-config     Synced   Healthy
```

---

## 1. 背景与目标

原集群 Tekton 是 standalone 安装：

- Pipelines v1.6.0
- Triggers v0.34.0
- Dashboard v0.63.1
- Resolvers v1.6.0
- 无 Operator、无 Helm、无 ArgoCD 管理
- 自定义 `cicd-cleanup` CronJob 只保留 1 天 PipelineRun/TaskRun

目标：

1. 迁移到 Tekton Operator，获得统一生命周期管理和内置 Pruner；
2. 纳入 ArgoCD GitOps；
3. 保留策略改为生产级，不再只留 1 天；
4. 保留现有 Pipeline/Task/Trigger 和运行历史。

---

## 2. 迁移前关键状态

### 2.1 Tekton 组件

```text
Tekton Pipelines   v1.6.0
Tekton Triggers    v0.34.0
Tekton Dashboard   v0.63.1
Tekton Resolvers   v1.6.0
```

### 2.2 现有资源

```text
pipelines        4
tasks            12
pipelineruns     2
taskruns         4
triggertemplates 3
triggerbindings  3
eventlisteners   3
```

### 2.3 自定义清理

```text
CronJob cicd-cleanup
  RETAIN_DAYS=1
  schedule: 0 */6 * * *
  image: 192.168.67.202:8443/compassio/python:3.11-slim
```

### 2.4 GitOps 基础

ArgoCD 已存在，已有应用：

```text
china-study-free
compassio
deeptutor
open-webui
```

GitLab 可用：

```text
http://192.168.67.201
```

---

## 3. 关键版本决策（重要踩坑）

### 3.1 GCS 的 `latest` 是旧的

一开始使用：

```text
https://storage.googleapis.com/tekton-releases/operator/latest/release.yaml
```

它返回 **v0.77.0**，但这不是最新版本。

GitHub Releases 实际最新：

```text
https://api.github.com/repos/tektoncd/operator/releases/latest
=> tekton-operator-0.81.3
```

**结论：不要只看 GCS `latest`，以 GitHub Releases 为准。**

### 3.2 v0.77.0 会降级 Pipelines

Operator v0.77.0 自带的组件：

```text
Pipelines v1.3.1
Triggers  v0.33.0
```

而迁移前是：

```text
Pipelines v1.6.0
Triggers  v0.34.0
```

所以 v0.77.0 是**降级**，不是升级。

### 3.3 最终选择 v0.81.3

Operator v0.81.3（2026-11-05 发布）自带：

```text
Pipelines v1.15.5
Triggers  v0.37.2
Dashboard v0.71.0
Pruner    v0.4.4
```

这是真正的升级。

> 本文记录的过程包含一次“先装 v0.77.0 → 发现降级 → 升级 v0.81.3”的纠正过程，生产迁移时应直接使用 v0.81.3。

---

## 4. 备份

迁移前备份目录：

```text
/root/tekton-migration-backup-2026-11-07/
```

内容：

```text
crds.yaml                               # Tekton 相关 CRD
tekton-crs.yaml                         # 所有 Pipelines/Tasks/Runs/Triggers 等 CR
tekton-pipelines-resources.yaml         # tekton-pipelines 命名空间资源
tekton-pipelines-resolvers-resources.yaml
cicd-cleanup.yaml                       # 旧清理相关资源
cicd-cleanup-cronjob.yaml
cicd-cleanup-script.yaml
```

建议生产迁移还备份：

```bash
# etcd 快照
ETCDCTL_API=3 etcdctl snapshot save /root/etcd-before-tekton-operator.db

# VG/关键存储
# 以及 ArgoCD 配置、GitLab 仓库
```

---

## 5. GitOps 仓库

### 5.1 GitLab 项目

```text
http://192.168.67.201/digitalsupply/tekton-platform-gitops.git
```

### 5.2 目录结构

```text
operator/release.yaml              # Tekton Operator v0.81.3 release（vendored）
config/tektonconfig.yaml           # TektonConfig + 生产保留策略
argocd/tekton-operator-app.yaml    # ArgoCD Application：Operator
argocd/tekton-config-app.yaml      # ArgoCD Application：TektonConfig
README.md
```

### 5.3 ArgoCD repo secret

在 `argocd` 命名空间创建：

```bash
kubectl -n argocd create secret generic tekton-platform-repo \
  --from-literal=type=git \
  --from-literal=url=http://192.168.67.201/digitalsupply/tekton-platform-gitops.git \
  --from-literal=username=root \
  --from-literal=password="$GITLAB_TOKEN"

kubectl -n argocd label secret tekton-platform-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
```

> token 不写入 Git；轮换 token 时更新该 secret。

---

## 6. ArgoCD Application

### 6.1 Operator App

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://192.168.67.201/digitalsupply/tekton-platform-gitops.git
    targetRevision: main
    path: operator
  destination:
    server: https://kubernetes.default.svc
    namespace: tekton-operator
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers:
        - /spec/conversion
        - /spec/preserveUnknownFields
      jqPathExpressions:
        - .spec.conversion
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 6.2 Config App

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tekton-config
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://192.168.67.201/digitalsupply/tekton-platform-gitops.git
    targetRevision: main
    path: config
  destination:
    server: https://kubernetes.default.svc
    namespace: tekton-pipelines
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

### 6.3 为什么 `prune: false`

Operator 包含 CRD 和集群级资源；ArgoCD 自动 prune 可能在删除 App 时误删 CRD，导致所有 Tekton CR 被级联删除。

生产环境建议保持 `prune: false`，需要删除时人工确认。

---

## 7. TektonConfig 与生产保留策略

### 7.1 最终配置

```yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  targetNamespace: tekton-pipelines
  profile: all

  result:
    disabled: true
  chain:
    disabled: true

  dashboard:
    readonly: true

  # Kubernetes 环境不需要 Pipelines-as-Code
  platforms:
    kubernetes:
      pipelinesAsCode:
        enable: false

  # 关闭 job-based pruner，启用事件驱动 pruner
  pruner:
    disabled: true
  tektonpruner:
    disabled: false
    global-config:
      enforcedConfigLevel: namespace
      ttlSecondsAfterFinished: 2592000   # 30 天
      successfulHistoryLimit: 200
      failedHistoryLimit: 100
```

### 7.2 保留策略说明

| 参数 | 值 | 含义 |
|---|---:|---|
| `ttlSecondsAfterFinished` | 2592000 | 完成 30 天后删除 |
| `successfulHistoryLimit` | 200 | 成功 run 最多保留 200 个 |
| `failedHistoryLimit` | 100 | 失败 run 最多保留 100 个 |
| `historyLimit` | 100 | Operator 默认填充值，作为兜底 |

Pruner 是**事件驱动**的，不是 CronJob；Pruner Controller 会监听 PipelineRun/TaskRun 事件并执行 GC。

### 7.3 旧清理任务

旧 `cicd-cleanup` CronJob 已删除：

```bash
kubectl -n cicd delete cronjob cicd-cleanup
```

备份仍在：

```text
/root/tekton-migration-backup-2026-11-07/cicd-cleanup-cronjob.yaml
```

> 这样不会再出现“1 天就把 PipelineRun 删掉”的行为。

---

## 8. Operator 安装与升级过程

### 8.1 第一次：v0.77.0（发现问题）

通过 ArgoCD 安装 v0.77.0 后：

```text
Pipelines v1.3.1
Triggers  v0.33.0
```

发现是降级，且不是最新版本。

### 8.2 第二次：v0.81.3（最终）

将 GitOps 仓库 `operator/release.yaml` 替换为 v0.81.3：

```bash
cp /tmp/op-0.81.3.yaml \
  /root/tekton-platform-gitops/operator/release.yaml
```

提交后 ArgoCD 自动同步，Operator 滚动升级。

最终版本：

```text
Tekton Operator   v0.81.3
Pipelines         v1.15.5
Triggers          v0.37.2
Dashboard         v0.71.0
Pruner            v0.4.4
```

### 8.3 官方 release 文件的一个坑

`https://infra.tekton.dev/tekton-releases/operator/previous/v0.81.3/release.yaml` 下载后有一个文档缺少 `kind`，ArgoCD 报：

```text
Failed to unmarshal "release.yaml":
Object 'Kind' is missing in '{"apiVersion":"v1","data":{...}}'
```

解决：使用 GitHub Release asset：

```text
https://github.com/tektoncd/operator/releases/download/v0.81.3/release.yaml
```

该文件解析正常（38 个文档，全部有 `kind`）。

> 生产迁移前一定要先做 YAML 解析/`kubectl apply --dry-run=server` 校验。

---

## 9. 迁移中的问题与修复

### 9.1 Pruner ConfigMap 丢失

现象：

```text
tekton-pruner-controller CrashLoopBackOff
error: configmap "tekton-pruner-default-spec" not found
```

原因：升级过程中旧的 ConfigMap 被清理，新 InstallerSet 没有重新创建。

修复：从 InstallerSet 的 manifest 直接补建：

```bash
kubectl get tektoninstallerset pruner-config-xw6wn \
  -o jsonpath='{.spec.manifests[0]}' | kubectl apply -f -
```

然后重启 Pruner Controller：

```bash
kubectl -n tekton-pipelines delete pod -l app=tekton-pruner-controller
```

### 9.2 OpenShiftPipelinesAsCode 阻塞 Ready

现象：

```text
Components not in ready state: OpenShiftPipelinesAsCode
```

原因：v0.81.3 默认在 Kubernetes 也启用了 `platforms.kubernetes.pipelinesAsCode.enable: true`。

修复：

```yaml
spec:
  platforms:
    kubernetes:
      pipelinesAsCode:
        enable: false
```

应用后，PAC CR 和 Pod 被清理，TektonConfig Ready=True。

### 9.3 ArgoCD CRD OutOfSync

现象：

```text
CustomResourceDefinition ... OutOfSync
```

差异：

```text
live 有 spec.conversion: {strategy: None}
source 没有
```

修复：在 Application 加：

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec/conversion
      - /spec/preserveUnknownFields
    jqPathExpressions:
      - .spec.conversion
```

之后两个 App 均 `Synced/Healthy`。

### 9.4 Operator 升级期间短暂不可用

滚动升级过程中：

- 旧 controller/webhook Pod Terminating；
- 新 Pod ContainerCreating/ImagePull；
- EventListener/Trigger 短暂不可用；
- Pruner 曾 CrashLoop。

生产迁移需要在维护窗口执行，并准备好回滚。

---

## 10. 验证结果

### 10.1 组件

```text
pipeline   v1.15.5   True
trigger    v0.37.2   True
dashboard  v0.71.0   True
pruner     v0.4.4    True
config     v0.81.3   True
```

### 10.2 ArgoCD

```text
tekton-operator   Synced   Healthy
tekton-config     Synced   Healthy
```

### 10.3 现有资源

```text
pipelines        4
tasks            12
pipelineruns     2
taskruns         4
triggertemplates 3
triggerbindings  3
eventlisteners   3
```

全部保留，没有因为 CRD 升级丢失。

### 10.4 Pod 健康

```text
tekton-dashboard                    1/1 Running
tekton-events-controller            1/1 Running
tekton-pipelines-controller         1/1 Running
tekton-pipelines-webhook            1/1 Running
tekton-pipelines-remote-resolvers   1/1 Running
tekton-pruner-controller            1/1 Running
tekton-pruner-webhook               1/1 Running
tekton-triggers-controller          1/1 Running
tekton-triggers-core-interceptors   1/1 Running
tekton-triggers-webhook             1/1 Running
tekton-operator                     2/2 Running
tekton-operator-webhook             1/1 Running
```

### 10.5 Dashboard

`https://tekton.xyz` 仍然可用：

```text
/                                        200
/v1/properties                           200
/apis/tekton.dev/v1/namespaces/cicd/pipelines 200
/api/v1/namespaces                       200
```

> Dashboard 的 Traefik 路由、BasicAuth、`strip-auth` 中间件仍沿用之前配置；v0.71.0 下继续工作。

---

## 11. 回滚方案

如果新版本出现不可接受的问题：

### 11.1 停止 GitOps 自动同步

```bash
# 暂停/删除 ArgoCD App，避免继续 reconcile
kubectl -n argocd delete application tekton-config
kubectl -n argocd delete application tekton-operator
```

### 11.2 恢复 standalone v1.6.0

> 注意：CRD 是 cluster-scoped，升级后已变成 v1.15.5；回滚到 v1.6.0 属于 **CRD 降级**，风险高，必须在测试环境验证。

大致步骤：

1. 备份当前 Tekton CR/CRD；
2. 删除 TektonConfig、Operator 相关 Deployment/CRD；
3. 重新 apply standalone v1.6.0 release：
   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.6.0/release.yaml
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml
   kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/previous/v0.63.1/tekton-dashboard-release.yaml
   ```
4. 恢复 `cicd-cleanup` CronJob（从备份）；
5. 验证 CR/版本/Pod。

**建议：不要轻易回滚；优先修复新版本。**

---

## 12. 注意事项与风险

### 12.1 版本来源

- **不要只看 GCS `latest`**：它可能滞后（本次 v0.77.0 vs GitHub v0.81.3）。
- 以 GitHub Releases 为准：
  ```text
  https://github.com/tektoncd/operator/releases
  ```
- 官方 `infra.tekton.dev` 的某个 release 文件可能有格式问题；使用 GitHub Release asset，并先校验 YAML。

### 12.2 CRD 风险

- Tekton CRD 是 cluster-scoped；
- Operator 升级会升级 CRD；
- 从 v1.6.0 直接到 v1.15.5 跨度较大；
- 迁移前必须备份 CRD 和所有 Tekton CR，并在测试集群验证。

### 12.3 保留策略

- 30 天 TTL + 成功 200 / 失败 100，比原来 1 天宽松很多；
- 会增加 etcd 对象数、PVC 数量、Dashboard 历史；
- 需要监控 etcd 大小、PVC 使用、Pruner 是否正常；
- 如需审计，建议部署 Tekton Results，而不是无限延长 K8s 对象保留。

### 12.4 Pruner

- `TektonConfig.spec.pruner` 和 `spec.tektonpruner` 不能同时启用；
- 本次启用 `tektonpruner`，关闭 `pruner`；
- Pruner ConfigMap 丢失会导致 controller CrashLoop；
- 生产建议给 `tekton-pruner-controller` 加告警。

### 12.5 Pipelines-as-Code

- v0.81.3 在 Kubernetes 默认开启 PAC；
- 当前不需要，已关闭；
- 如果以后需要 PAC，设置：
  ```yaml
  platforms:
    kubernetes:
      pipelinesAsCode:
        enable: true
  ```
  并配置 GitHub/GitLab App/Token。

### 12.6 ArgoCD

- `prune: false` 防止误删 CRD；
- `ignoreDifferences` 必须保留，否则 CRD 默认字段会导致永久 OutOfSync；
- `selfHeal: true` 会覆盖手工修改 TektonConfig；所有变更走 Git；
- repo secret `tekton-platform-repo` 的 token 需要定期轮换；
- 不要把 GitLab token、Harbor 密码写进 Git。

### 12.7 Dashboard

- Dashboard 路由仍是手工管理（不在本次 GitOps 仓库中）；
- BasicAuth + `Authorization` strip 中间件仍需保留；
- v0.71.0 下已验证 `/v1/properties`、Pipelines API 返回 200；
- 自签名证书仍会提示不受信任，正式使用建议 ACME。

### 12.8 旧清理任务

- 旧 `cicd-cleanup` CronJob 已删除；
- 备份在 `/root/tekton-migration-backup-2026-11-07/`；
- 如果新 Pruner 异常，短期会没有 1 天清理兜底；
- 监控 PipelineRun/TaskRun 数量，避免 etcd 膨胀。

### 12.9 镜像与网络

- Operator/Pruner 镜像来自 `ghcr.io`；
- Harbor 故障时，节点拉取可能受影响；
- 建议把 Operator/Pruner 镜像同步到本地 Harbor，或配置 registry mirror。

### 12.10 维护窗口

- Operator 安装/升级会滚动重启 controller/webhook；
- EventListener/Trigger 可能短暂不可用；
- 建议在低峰维护窗口执行，并提前通知 CI 用户。

---

## 13. 后续建议

1. **观察 1–2 周**：重点看 Pruner 是否按 30 天策略清理、etcd 大小、PVC 数量。
2. **接入 Tekton Results**：生产审计和长期日志，避免无限保留 K8s 对象。
3. **给 Pruner 加告警**：Controller CrashLoop、InstallerSet 不 Ready、ConfigMap 丢失。
4. **镜像本地化**：把 Operator/Pruner/Pipelines/Triggers/Dashboard 镜像同步到 Harbor。
5. **完善 GitOps**：
   - 把 Dashboard 路由、BasicAuth Secret、TLS Secret 用 ExternalSecrets/SOPS 管理；
   - 给 `tekton-platform-gitops` 加 CI 校验（YAML parse、kubeconform）。
6. **版本升级策略**：
   - 以 GitHub Releases 为准；
   - 先测试集群；
   - 保留 Operator 版本回滚包；
   - 关注 CRD 变更说明。

---

## 附录 A：关键命令

### A.1 备份

```bash
BK=/root/tekton-migration-backup-2026-11-07
mkdir -p "$BK"
kubectl get crd -o name | grep -E 'tekton|resolution' \
  | xargs -r kubectl get -o yaml > "$BK/crds.yaml"
kubectl get pipelines,tasks,pipelineruns,taskruns,triggertemplates,triggerbindings,triggers,eventlisteners -A -o yaml \
  > "$BK/tekton-crs.yaml"
kubectl get all,cm,secret,sa,role,rolebinding -n tekton-pipelines -o yaml \
  > "$BK/tekton-pipelines-resources.yaml"
```

### A.2 创建 GitLab 仓库

```bash
curl -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --data "name=tekton-platform-gitops&path=tekton-platform-gitops&namespace_id=2&visibility=private" \
  "http://192.168.67.201/api/v4/projects"
```

### A.3 验证 Operator

```bash
kubectl -n tekton-operator get pods
kubectl get tektonconfig config
kubectl get tektonpipeline,tektontrigger,tektondashboard,tektonpruner
```

### A.4 验证 Pruner

```bash
kubectl -n tekton-pipelines get cm tekton-pruner-default-spec -o yaml
kubectl -n tekton-pipelines logs deploy/tekton-pruner-controller --tail=50
```

### A.5 验证 ArgoCD

```bash
kubectl -n argocd get application tekton-operator tekton-config -o wide
```

---

## 附录 B：保留策略参数

```yaml
tektonpruner:
  disabled: false
  global-config:
    enforcedConfigLevel: namespace
    ttlSecondsAfterFinished: 2592000   # 30 天
    successfulHistoryLimit: 200
    failedHistoryLimit: 100
```

调整建议：

| 场景 | TTL | 成功保留 | 失败保留 |
|---|---:|---:|---:|
| 开发 | 3–7 天 | 50–100 | 20–50 |
| 预发 | 7–14 天 | 100–200 | 50–100 |
| 生产 | 30 天 | 200–500 | 100–200 |
| 合规 | 90 天+ | 结合 Tekton Results | 结合 Tekton Results |

---

## 附录 C：一句话总结

**最终把 Tekton 从 standalone v1.6.0/0.34.0/0.63.1 迁移到 Operator v0.81.3，组件升级到 Pipelines v1.15.5、Triggers v0.37.2、Dashboard v0.71.0、Pruner v0.4.4；用 GitLab + ArgoCD 管理 Operator 和 TektonConfig；保留策略从 1 天改为 30 天 TTL + 成功 200 / 失败 100；旧 1 天清理 CronJob 已删除。迁移过程中踩过 GCS latest 滞后、v0.77.0 降级、release YAML 格式错误、Pruner ConfigMap 丢失、PAC 默认开启、CRD OutOfSync 等问题，均已修复并记录。**
