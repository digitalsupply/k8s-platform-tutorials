# P0 GitOps 落地执行日志

> 执行日期：2026-11-08
> 集群：kubeadm v1.35.9，6 节点
> GitLab 仓库：`http://192.168.67.201/digitalsupply/platform-gitops.git`（project id 10）
> ArgoCD：`argocd` namespace，v3.5.3

---

## 0. 执行结果总览

| P0 项 | 状态 | 结果 |
|---|---|---|
| 1. CNPG 数据库栈 | ✅ 完成 | Operator / Plugin / Cluster / ObjectStore / ScheduledBackup 全部 GitOps |
| 2. Kafka / Strimzi | ✅ 完成 | Operator / Kafka / KafkaNodePool / KafkaTopic 全部 GitOps |
| 3. 监控告警 CR | 🟡 部分完成 | **Grafana 已切 Grafana Operator（Stage A）**；Prometheus/Alertmanager CR 仍待维护窗口 |
| 4. CI 定义 | ✅ 完成 | `cicd` 的 Pipeline/Task/EventListener/TriggerBinding/Template 已 GitOps |
| 5. ArgoCD app-of-apps | ✅ 完成 | 12 个 Application 全部由 `app-of-apps` 管理 |
| 6. Secret 管理 | 🟡 部分完成 | **Sealed Secrets 已安装；open-webui 3 个 Secret 已迁移并验证**；gitlab-auth / CNPG 凭据待迁移 |

当前 ArgoCD 状态：

```text
NAME                      SYNC     HEALTH
app-of-apps               Synced   Healthy
china-study-free          Synced   Healthy
compassio                 Synced   Healthy
deeptutor                 Synced   Healthy
open-webui                Synced   Healthy
platform-cicd             Synced   Healthy
platform-cnpg-cluster     Synced   Healthy
platform-cnpg-operator    Synced   Healthy
platform-cnpg-plugin      Synced   Healthy
platform-kafka-cluster    Synced   Healthy
platform-kafka-operator   Synced   Healthy
tekton-config             Synced   Healthy
tekton-operator           Synced   Healthy
```

业务与中间件健康：

```text
CNPG:   pg16-ceph  2/2  Cluster in healthy state
Kafka:  my-cluster True  4.1.2
Tekton: config     True  v0.81.3
```

---

## 1. 仓库与提交记录

```text
http://192.168.67.201/digitalsupply/platform-gitops.git

3d45c22 feat(app-of-apps): adopt existing six applications
de94ab1 feat(kafka): manage strimzi operator and kafka CRs via gitops
e6c915e feat(cicd): manage tekton pipelines/tasks/listeners via gitops
38c0b13 fix(cnpg): cover operator-defaulted fields in ignoreDifferences
e5afa24 feat: bootstrap P0 gitops (cnpg operator/plugin/cluster + app-of-apps)
```

仓库结构：

```text
platform-gitops/
├── clusters/prod/
│   ├── app-of-apps.yaml
│   └── applications/
│       ├── existing-apps.yaml                 # 原有 6 个 App
│       ├── platform-cnpg-operator.yaml
│       ├── platform-cnpg-plugin.yaml
│       ├── platform-cnpg-cluster.yaml
│       ├── platform-kafka-operator.yaml
│       ├── platform-kafka-cluster.yaml
│       └── platform-cicd.yaml
├── platform/
│   ├── cnpg/{operator,plugin,cluster}/
│   ├── kafka/{operator,cluster}/
│   ├── cicd/
│   ├── monitoring/README.md                   # 待切换方案
│   └── secrets/README.md                      # 待切换方案
└── scripts/clean-k8s-yaml.py
```

---

## 2. 执行步骤

### 2.1 准备 GitLab 仓库

```bash
# 确认 GitLab API 可用（root token 来自 cicd/gitlab-auth）
curl -H "PRIVATE-TOKEN: <token>" http://192.168.67.201/api/v4/user
# 200

# 创建 project（group: digitalsupply, id=2）
curl -X POST -H "PRIVATE-TOKEN: <token>" \
  --data-urlencode "name=platform-gitops" \
  --data-urlencode "path=platform-gitops" \
  --data-urlencode "namespace_id=2" \
  --data-urlencode "visibility=private" \
  http://192.168.67.201/api/v4/projects
# 201，project id=10
```

推送本地骨架：

```bash
cd /root/gitops-p0
git init && git add . && git commit -m "feat: bootstrap P0 gitops (cnpg)"
git branch -M main
git remote add origin http://192.168.67.201/digitalsupply/platform-gitops.git
git push -u origin main
```

### 2.2 补 ArgoCD 仓库凭据

**问题**：`app-of-apps` 拉取新仓库时报：

```text
authentication required: HTTP Basic: Access denied
```

**原因**：ArgoCD 使用的是 per-repository Secret，不是全局 `repo-creds`；`platform-gitops` 没有对应凭据。

**修复**：

```bash
kubectl -n argocd create secret generic platform-gitops-repo \
  --from-literal=type=git \
  --from-literal=url=http://192.168.67.201/digitalsupply/platform-gitops.git \
  --from-literal=username=root \
  --from-literal=password=<token> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret platform-gitops-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
```

### 2.3 创建 app-of-apps

```bash
kubectl apply -f clusters/prod/app-of-apps.yaml
```

结果：ArgoCD 自动创建 `platform-cnpg-*`，随后又创建 `platform-kafka-*`、`platform-cicd`。

### 2.4 CNPG GitOps 化

**提交内容**：

- 官方 Operator manifest：`cnpg-1.30.1.yaml`
- 官方 Barman Cloud Plugin manifest：`plugin-barman-cloud-0.15.1.yaml`
- 清洗后的 `Cluster` / `ObjectStore` / `ScheduledBackup`

**拆分 3 个 Application（sync-wave）**：

| App | wave | 内容 |
|---|---:|---|
| `platform-cnpg-operator` | -10 | CRD + Operator |
| `platform-cnpg-plugin` | -5 | Plugin + CRD |
| `platform-cnpg-cluster` | 0 | Cluster / ObjectStore / ScheduledBackup |

**关键配置**：

```yaml
syncPolicy:
  automated:
    prune: false        # 数据库 CR 绝不能自动 prune
    selfHeal: true
  syncOptions:
    - ServerSideApply=true
    - SkipDryRunOnMissingResource=true
    - RespectIgnoreDifferences=true
```

**问题**：`platform-cnpg-cluster` 首次显示 `OutOfSync`。

**原因**：CNPG Operator 向 `Cluster.spec` 回填默认值：

```text
enablePDB / failoverDelay / logLevel / maxSyncReplicas / minSyncReplicas
postgresGID / postgresUID / probes / replicationSlots
smartShutdownTimeout / startDelay / stopDelay / switchoverDelay
postgresql.syncReplicaElectionConstraint
```

**修复**：

1. 在 `ignoreDifferences` 中列出这些路径；
2. 在 `cluster.yaml` 中显式补 `plugins[].enabled: true` 和 `monitoring.customQueriesConfigMap/disableDefaultQueries`，消除两处非默认差异。

修复后：`platform-cnpg-cluster` → `Synced/Healthy`。

### 2.5 CI 定义 GitOps 化

```bash
kubectl -n cicd get pipeline,task,eventlistener,triggerbinding,triggertemplate -o yaml \
  | python3 scripts/clean-k8s-yaml.py > platform/cicd/cicd-defs.yaml
```

**问题**：`kubectl get` 多资源返回 `kind: List`，脚本原样输出，ArgoCD 无法逐资源跟踪。

**修复**：清洗脚本增加 `List` 展开逻辑，拆成独立 YAML 文档。

结果：4 Pipeline / 12 Task / 3 EventListener / 3 TriggerBinding / 3 TriggerTemplate。

Application `platform-cicd`：`prune=false`（避免误删 EventListener 导致 `el-*` Deployment 消失）。

### 2.6 Kafka GitOps 化

**问题**：Strimzi 1.0.0 官方 manifest 下载超时（GitHub release asset）。

**修复**：从集群提取 Operator 资源并清洗：

- 1 Deployment（`strimzi-cluster-operator`）
- 1 ConfigMap、1 ServiceAccount
- 4 RoleBinding
- 7 ClusterRole、3 ClusterRoleBinding
- 9 CRD

**不提交**由 Operator 生成的子资源：

- `my-cluster-entity-operator` Deployment
- `my-cluster-*` ConfigMap / SA / Role / RoleBinding
- Kafka broker Pod / PVC

**CR 提交**：

- `Kafka my-cluster`
- `KafkaNodePool single-pool`
- `KafkaTopic tempo-traces`

拆分为：

| App | wave | 内容 |
|---|---:|---|
| `platform-kafka-operator` | -10 | Strimzi Operator + CRD + RBAC |
| `platform-kafka-cluster` | 0 | Kafka / NodePool / Topic |

`prune=false`，`ignoreDifferences` 忽略 `/status`。

结果：两个 App 均 `Synced/Healthy`。

### 2.7 app-of-apps 接管原有 6 个 Application

把原有 6 个 Application 的清单清洗后放入 `clusters/prod/applications/existing-apps.yaml`：

- 删除 `status`、`uid`、`resourceVersion`、`generation`、`creationTimestamp`、`managedFields`
- 删除 `last-applied-configuration`、`tracking-id`、`refresh` 注解
- **保留** `finalizers`（`resources-finalizer.argocd.argoproj.io`）

结果：`app-of-apps` 现在管理 **12 个 Application**，全部 `Synced/Healthy`。

---

## 3. 当前架构

```text
app-of-apps (root, 手动 bootstrap)
├── china-study-free        (业务)
├── compassio               (业务)
├── deeptutor               (业务)
├── open-webui              (业务)
├── tekton-config           (平台)
├── tekton-operator         (平台)
├── platform-cnpg-operator  (平台, wave -10)
├── platform-cnpg-plugin    (平台, wave -5)
├── platform-cnpg-cluster   (平台, wave 0)
├── platform-kafka-operator (平台, wave -10)
├── platform-kafka-cluster  (平台, wave 0)
└── platform-cicd           (平台, wave 20)
```

---

## 4. 未完成项与切换方案

### 4.0 Grafana Stage A（已完成）

Grafana 已用 Grafana Operator v5.25.0 的 **external 模式**接管，未替换原 Helm Deployment/PVC：

- 4 个 `GrafanaDatasource`（Prometheus / Alertmanager / Loki / Tempo）
- 37 个 `GrafanaDashboard`（引用现有 ConfigMap）
- Helm sidecar 已关闭，Grafana 容器从 3 个降为 1 个
- `platform-grafana` / `platform-grafana-operator` 均 `Synced/Healthy`
- 踩坑：旧 sidecar 资源的 `readOnly` / `dashboard_provisioning` 需要定向 DB 解锁

详见：`2026-11-08-grafana-operator-stage-a.md`

### 4.1 监控告警 CR（P0-3）

**为什么没直接切**：

- `kube-prometheus-stack` 仍由 Helm 管理，`Prometheus` / `Alertmanager` CR 是 Helm chart 的子资源；
- 如果 ArgoCD 直接接管这些 CR，会和 Helm 冲突；
- 正确做法是先把 Helm values 里的 `prometheus.enabled` / `alertmanager.enabled` 关掉，再由 GitOps 创建 CR，这会重建 Prometheus/Alertmanager StatefulSet，需要维护窗口。

**切换方案**（已写入 `platform/monitoring/README.md`）：

1. 导出当前 Helm values；
2. 新建 `platform/monitoring/`：
   - `prometheus.yaml`（Prometheus CR）
   - `alertmanager.yaml`（Alertmanager CR）
   - `rules/`（平台级 PrometheusRule）
   - `dashboards/`（Grafana Dashboard ConfigMap）
3. Helm values 设置 `prometheus.enabled=false`、`alertmanager.enabled=false`；
4. 维护窗口内执行，确认新 CR 接管后再清理旧 StatefulSet；
5. 验证 `kubectl -n monitoring get prometheus,alertmanager` 与告警链路。

### 4.2 Secret 管理（P0-6）

**当前状态（2026-11-08）**：

- Sealed Secrets Controller **v0.41.2** 已通过 GitOps 安装（`platform-sealed-secrets` App，`kube-system`）；
- open-webui 的 3 个 Secret 已迁移为 `SealedSecret`，控制器创建的 Secret 数据哈希与迁移前一致；
- `open-webui` App `Synced/Healthy`；
- 私钥备份：`/root/k8s-postmortem/backup/sealed-secrets-key.yaml`；
- 剩余：`cicd/gitlab-auth`、CNPG 的 `pg-secret` / `pg-superuser-secret` / `pg-backup-s3-creds`。

详见：`2026-11-08-sealed-secrets-openwebui.md`

**为什么没直接切**：

- 当前 `open-webui` GitOps 仓库里有明文 `Secret`（`frp-token`、`harbor-pull`、`open-webui-config`）；
- `cicd/gitlab-auth`、`cnpg-system/pg-secret` 等也是手动 Secret；
- 直接换 Sealed Secrets/ESO 需要重新加密/同步所有 Secret，属于凭据迁移，不能盲操作。

**切换方案**（已写入 `platform/secrets/README.md`）：

1. 二选一：
   - **Sealed Secrets**：适合纯 GitOps，控制器 + `kubeseal`；
   - **External Secrets Operator**：适合对接 Vault/云 Secret Manager。
2. 先安装控制器（通过 ArgoCD App）；
3. 逐个迁移：
   - `open-webui` 的 3 个 Secret；
   - `cicd/gitlab-auth`；
   - `cnpg-system/pg-secret`、`pg-superuser-secret`、`pg-backup-s3-creds`；
4. 迁移完成后从 Git 历史中清除明文 Secret（需要 rewrite history 或轮换凭据）。

---

## 5. 验证清单

- [x] `app-of-apps` 管理 12 个 Application
- [x] 全部 Application `Synced/Healthy`
- [x] CNPG `pg16-ceph` 2/2 healthy
- [x] Kafka `my-cluster` Ready
- [x] Tekton `config` Ready
- [x] CI 定义已由 ArgoCD 跟踪
- [x] 所有平台 App `prune=false`
- [x] CNPG/Kafka 的 Operator 回填字段已 `ignoreDifferences`
- [ ] 监控 CR 切换（待维护窗口）
- [ ] Secret 迁移（待凭据迁移窗口）

---

## 6. 回滚

### 回滚某个平台 App

```bash
# 暂停自动同步
kubectl -n argocd patch application platform-cnpg-cluster \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 需要时删除 App（不会删除资源，因为 prune=false）
kubectl -n argocd delete application platform-cnpg-cluster
```

### 回滚 app-of-apps 接管

```bash
# 从仓库移除 clusters/prod/applications/existing-apps.yaml
# app-of-apps 会停止管理原有 6 个 App（它们本身仍然存在）
```

> 注意：`prune=false` 只防止“从 Git 删除资源时级联删除”；如果手动 `kubectl delete application` 且 App 带 `resources-finalizer`，仍可能触发级联删除。操作前先移除 finalizer 或暂停自动同步。

---

## 7. 下一步

1. **监控 CR 切换**（维护窗口，按 `platform/monitoring/README.md`）；
2. **Secret 迁移**（按 `platform/secrets/README.md`）；
3. 给 ArgoCD 自身建一个 `argocd` Application（`prune=false`），实现“GitOps 管 GitOps”；
4. 把 `platform-baseline`（Namespace/RBAC/NetworkPolicy/Quota）纳入 GitOps；
5. 做一次“从零重建”演练：删一个临时 namespace，确认 ArgoCD 能完整拉起。
