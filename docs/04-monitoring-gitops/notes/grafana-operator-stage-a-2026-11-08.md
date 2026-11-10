# Grafana Operator Stage A 执行记录

> 执行日期：2026-11-08
> 目标：在不替换现有 Grafana Deployment/PVC 的前提下，用 Grafana Operator 接管 Dashboard/Datasource
> 结果：**Stage A 完成，`platform-grafana` / `platform-grafana-operator` 均 Synced/Healthy**

---

## 0. 最终结果

| 项目 | 结果 |
|---|---|
| Grafana Operator | **v5.25.0**，namespace `grafana-operator`，1/1 Running |
| Grafana 实例 | 仍为 Helm Deployment，**12.4.3**，PVC `prometheus-grafana` 未变 |
| Grafana 容器 | 从 **3 个（grafana + 2 sidecar）** 降为 **1 个（grafana）** |
| Datasource | **4 个**（Prometheus / Alertmanager / Loki / Tempo），`readOnly=false`，全部由 Operator 管理 |
| Dashboard | **37 个 `GrafanaDashboard` CR**，全部 `DashboardSynchronized=True` |
| Grafana 中总 Dashboard | **47 个**（37 个来自 ConfigMap + 10 个原有用户自建，已保留） |
| ArgoCD | `platform-grafana`、`platform-grafana-operator` 均 `Synced/Healthy` |
| Helm | kube-prometheus-stack revision 4，sidecar 已关闭 |

---

## 1. 架构变化

### 之前

```text
Helm kube-prometheus-stack
└── Deployment prometheus-grafana
    ├── grafana
    ├── k8s-sidecar (dashboards)   ← 监听 30 个 ConfigMap
    └── k8s-sidecar (datasources)  ← 监听 1 个 ConfigMap
```

### 之后

```text
GitOps (platform-gitops)
├── platform-grafana-operator
│   └── Grafana Operator v5.25.0
└── platform-grafana
    ├── Grafana (external 模式，指向现有 Service)
    ├── GrafanaDatasource × 4
    └── GrafanaDashboard × 37 (configMapRef → 现有 ConfigMap)

Helm kube-prometheus-stack
└── Deployment prometheus-grafana
    └── grafana   ← sidecar 已移除，PVC 保留
```

关键点：**外部模式**下 Operator 不创建 Deployment/Service，只通过 Grafana API 管理资源。

---

## 2. 执行步骤

### 2.1 安装 Grafana Operator

由于集群没有 Helm，先安装 Helm 3.19.0，再渲染 Operator 的 OCI Chart：

```bash
curl -fsSL https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz -o /tmp/helm.tgz
tar -xzf /tmp/helm.tgz -C /tmp
mv /tmp/linux-amd64/helm /usr/local/bin/helm

helm template grafana-operator oci://ghcr.io/grafana/helm-charts/grafana-operator \
  --version 5.25.0 \
  --namespace grafana-operator \
  --include-crds \
  > /tmp/grafana-operator-rendered.yaml
```

渲染结果包含：

- 13 个 CRD（`grafana.integreatly.org`）
- 1 个 Deployment（`ghcr.io/grafana/grafana-operator:v5.25.0`）
- ClusterRole / ClusterRoleBinding / Role / RoleBinding / Service / ServiceAccount

补充 Namespace 后提交到：

```text
platform/grafana/operator/
├── namespace.yaml
└── operator.yaml
```

ArgoCD Application `platform-grafana-operator`：

- wave `-5`
- destination `grafana-operator`
- `prune=false`
- `ServerSideApply=true`
- `ignoreDifferences` 忽略 CRD 的 `/spec/conversion`（API Server 默认值导致 OutOfSync）

### 2.2 创建 external Grafana CR

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: prometheus-grafana
  namespace: monitoring
  labels:
    dashboards: prometheus-grafana
spec:
  external:
    url: http://prometheus-grafana.monitoring.svc:80
    adminUser:
      name: prometheus-grafana
      key: admin-user
    adminPassword:
      name: prometheus-grafana
      key: admin-password
```

复用现有 Secret 的 `admin-user` / `admin-password`，不改 Grafana 实例。

### 2.3 创建 4 个 GrafanaDatasource

| Name | Type | UID |
|---|---|---|
| Prometheus | prometheus | `prometheus` |
| Alertmanager | alertmanager | `alertmanager` |
| Loki | loki | `dfi90c2a1osn4c` |
| Tempo | tempo | `afia1p4xshn9cf` |

Loki 的 `X-Scope-OrgID: fake` 放在 `secureJsonData.httpHeaderValue1`。

Tempo 保留 `tracesToLogsV2`、`tracesToMetrics`、`serviceMap`、`lokiSearch` 的下钻配置。

### 2.4 生成 37 个 GrafanaDashboard

从 30 个带 `grafana_dashboard=1` 的 ConfigMap 中提取 37 个 JSON key，生成：

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: dash-<configmap>-<key>
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: prometheus-grafana
  configMapRef:
    name: <configmap>
    key: <key>
```

这样 **Dashboard 内容仍保留在现有 ConfigMap**，Operator 只做引用和同步。

### 2.5 关闭 Helm sidecar

```bash
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 \
  --reuse-values \
  --set grafana.sidecar.dashboards.enabled=false \
  --set grafana.sidecar.datasources.enabled=false
```

结果：Grafana Deployment 从 3 容器变为 1 容器，PVC 保留。

### 2.6 启用 platform-grafana

ArgoCD Application `platform-grafana`：

- wave `10`
- destination `monitoring`
- `prune=false`
- `ServerSideApply=true`
- `SkipDryRunOnMissingResource=true`
- `ignoreDifferences` 忽略 `Grafana` / `GrafanaDatasource` / `GrafanaDashboard` 的 `/status`

---

## 3. 踩坑与修复

### 3.1 Datasource PUT 403：`Cannot update read-only data source`

**现象**

```text
[PUT /datasources/uid/{uid}][403] updateDataSourceByUidForbidden
{"message":"Cannot update read-only data source"}
```

**原因**

旧 Datasource 由 sidecar 通过 provisioning 创建，配置里 `readOnly: true`。Grafana 禁止通过 API 更新/删除只读数据源。

**修复**

1. 备份 `grafana.db`；
2. scale Grafana 到 0；
3. 挂载 PVC，修改 SQLite：

```sql
UPDATE data_source SET read_only = 0;
```

4. 复制回 PVC，清理 `-wal`/`-shm`；
5. scale 回 1。

之后 Operator 的 PUT 成功。

### 3.2 Dashboard DELETE 400：`provisioned dashboard cannot be deleted`

**现象**

```text
[DELETE /dashboards/uid/{uid}] deleteDashboardByUID (status 400): {}
```

**原因**

旧 Dashboard 由 sidecar provisioning 创建，Grafana 在 `dashboard_provisioning` 表里记录了 provisioning 关系，禁止 API 删除。

**修复**

在同一份 SQLite 中执行：

```sql
DELETE FROM dashboard_provisioning;
```

这样 37 个旧 provisioning dashboard 变成普通 dashboard，Operator 可以按“同标题不同 UID”删除并重建。

> 只删除 provisioning 关系，不删除 Dashboard 本身；10 个用户自建 Dashboard 不受影响。

### 3.3 Operator 连接 `connection refused`

**现象**

Grafana 重启后，Operator 仍然报：

```text
dial tcp 10.101.49.32:80: connect: connection refused
```

但临时 Pod 访问 Service 正常（`200`）。

**原因**

Operator 进程里缓存了 Grafana 重启前的连接/客户端状态。

**修复**

```bash
kubectl -n grafana-operator delete pod -l app.kubernetes.io/name=grafana-operator
```

Operator 重启后立即恢复。

### 3.4 CRD `spec.conversion` 导致 OutOfSync

**现象**

`platform-grafana-operator` 唯一 OutOfSync 资源是 `grafanas.grafana.integreatly.org`。

**原因**

API Server 给 CRD 补了 `spec.conversion` 默认值，Helm 渲染的 manifest 没有该字段。

**修复**

Application 增加：

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec/conversion
      - /status
```

### 3.5 Helm sidecar 移除后旧资源仍带 provisioned/readOnly 标志

这是 3.1 和 3.2 的根因：sidecar 移除只删除了 provisioning 文件，**不会清理 Grafana DB 里的 provisioned/readOnly 状态**。所以必须做一次定向 DB 解锁。这个经验对以后从 sidecar 迁移到 Operator 同样适用。

---

## 4. 验证结果

### 4.1 ArgoCD

```text
platform-grafana            Synced   Healthy
platform-grafana-operator   Synced   Healthy
```

### 4.2 Grafana CR

```text
stage=complete  stageStatus=success  version=12.4.3
adminUrl=http://prometheus-grafana.monitoring.svc:80
```

### 4.3 Datasource

```text
alertmanager  Alertmanager  alertmanager  readOnly=False
dfi90c2a1osn4c Loki         loki          readOnly=False
prometheus    Prometheus    prometheus    readOnly=False
afia1p4xshn9cf Tempo        tempo         readOnly=False
```

### 4.4 Dashboard

```text
37 × GrafanaDashboard  DashboardSynchronized=True
Grafana 中总 Dashboard = 47（37 个 CR + 10 个用户自建）
```

用户自建 Dashboard 示例仍保留：

- `ArgoCD GitOps 总览`
- `CloudNativePG 总览`
- `Compassio 校级心理测评`

### 4.5 容器

```text
prometheus-grafana  1/1 Running
containers: grafana (docker.io/grafana/grafana:12.4.3)
```

---

## 5. 备份与回滚

### 备份

| 文件 | 说明 |
|---|---|
| `/root/k8s-postmortem/backup/grafana.db` | 迁移前 Grafana SQLite 备份（3.9MB） |
| `/root/k8s-postmortem/backup/grafana-dashboards/*.json` | 47 个 Dashboard JSON 导出 |
| `/root/k8s-postmortem/backup/prometheus-values-before-grafana-operator.yaml` | Helm values 备份 |

### 回滚 Stage A

```bash
# 1. 暂停/删除 platform-grafana 和 platform-grafana-operator
kubectl -n argocd patch application platform-grafana \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd delete application platform-grafana
kubectl -n argocd delete application platform-grafana-operator

# 2. 重新打开 Helm sidecar
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 --reuse-values \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.datasources.enabled=true

# 3. 如需恢复 DB（会丢迁移后的 Operator 管理状态）
kubectl -n monitoring scale deploy/prometheus-grafana --replicas=0
# 挂载 PVC 的 helper pod，把 backup/grafana.db 复制回 /data/grafana.db
kubectl -n monitoring scale deploy/prometheus-grafana --replicas=1
```

---

## 6. Stage A 未做的事

| 项 | 说明 |
|---|---|
| 替换 Grafana Deployment/PVC | **没有做**；当前仍是 Helm 部署，PVC 未变 |
| 迁移 `grafana.ini` / 插件 | external 模式限制：`.spec.config` 不生效，不能装插件；仍由 Helm 管理 |
| Grafana 告警迁移 | 当前未使用 Grafana unified alerting，告警仍走 Prometheus + Alertmanager |
| 10 个用户自建 Dashboard 入库 | 已导出备份，但尚未纳入 Git；Stage B 前需要处理 |
| Ingress | 当前仍无 Ingress，只有 ClusterIP Service |

---

## 7. Stage B 建议（单独窗口）

1. 把 10 个用户自建 Dashboard 转为 `GrafanaDashboard` CR（inline JSON 或 ConfigMap）；
2. 新建 internal 模式的 `Grafana` CR：
   - 镜像 `grafana/grafana:12.4.3`
   - `spec.config` 复刻当前 `grafana.ini`
   - `spec.persistence` 复用/新建 PVC
   - admin Secret、resources、Service；
3. kube-prometheus-stack values 设置 `grafana.enabled=false`；
4. 维护窗口执行，保留旧 PVC 做回滚；
5. 验证后再决定是否迁移旧 DB 数据。

---

## 8. 后续建议

- **轮换 Grafana admin 密码**：当前仍是初始值。
- **补 Ingress**：当前只有 ClusterIP，建议用 Traefik IngressRoute 暴露。
- **启用 Operator 监控**：Helm chart 的 `serviceMonitor.enabled` 默认 false，可开启。
- **锁定 Operator 版本**：当前 v5.25.0，升级前先看 CRD 变更。
- **Dashboard prune 策略**：当前 `prune=false`；稳定后可考虑 `prune=true`，让 Git 删除即生效。
- **Stage B 前处理用户自建 Dashboard**：从 `/root/k8s-postmortem/backup/grafana-dashboards/` 导入 Git。

---

## 8.1 后续加固（2/3/4）

在 Stage A 基础上又完成了三项：

### ① Traefik IngressRoute 纳入 GitOps

集群里原本有一套手动创建的 Grafana IngressRoute，已清洗后放入 `platform/grafana/resources/ingress.yaml`：

- `grafana`（websecure）
  - `Host(\`grafana.example.local\`) || Host(\`grafana.k8s.local\`)`
  - `prometheus-grafana:80`
  - `tls: {}`（Traefik 默认自签证书）
- `grafana-http-redirect`（web）
  - 同样两个 Host
  - `redirect-to-https` Middleware

同时给 Grafana 设置了：

```text
GF_SERVER_ROOT_URL=https://grafana.k8s.local/
GF_SERVER_DOMAIN=grafana.k8s.local
```

验证：

```text
HTTPS  https://grafana.k8s.local/api/health  -> 200
HTTP   http://grafana.k8s.local/api/health   -> 301 https://grafana.k8s.local/api/health
```

> 如果后续有正式域名，只需改 IngressRoute 的 Host 和 `GF_SERVER_ROOT_URL`，并换成 cert-manager 签发的 TLS Secret。

### ② Grafana Operator ServiceMonitor

新增 `platform/grafana/operator/servicemonitor.yaml`：

- namespace `grafana-operator`
- label `release: prometheus`（匹配 Prometheus CR 的 `serviceMonitorSelector`）
- 选择 `grafana-operator-metrics-service` 的 `metrics` 端口

验证：

```text
Prometheus target: grafana-operator-metrics-service
health: up
scrapeUrl: http://<operator-pod>:9090/metrics
```

### ③ platform-grafana 开启 prune

`platform-grafana` 的 `syncPolicy.automated.prune` 已从 `false` 改为 `true`：

- 从 Git 删除 `GrafanaDashboard`/`GrafanaDatasource`/IngressRoute，会同步删除集群资源；
- `Grafana` 连接根资源加了 `argocd.argoproj.io/sync-options: Prune=false`，避免误删导致整个外部连接消失；
- 10 个用户自建 Dashboard 不在 ArgoCD 跟踪范围内，不受影响。

验证：

```text
platform-grafana  Synced  Healthy
prune=true
IngressRoute tracking-id = platform-grafana:traefik.io/IngressRoute:monitoring/grafana
```

## 9. 相关提交

```text
432b093 feat(grafana): adopt ingressroutes, enable operator servicemonitor, enable prune
200c077 docs(grafana): document stage A and sidecar migration notes
e6cf9c8 feat(grafana): enable external grafana datasources and dashboards (stage A)
f2c12d7 fix(grafana): ignore CRD conversion default in operator app
85fe156 feat(grafana): add grafana-operator and external grafana resources (stage A)
```

仓库：`http://192.168.67.201/digitalsupply/platform-gitops.git`
