# Traefik GitOps 收尾：5 项遗留问题处理方案

- **日期**：2026-11-09
- **集群**：`kubernetes-admin@kubernetes`（Kubernetes v1.35.9）
- **范围**：`traefik` 命名空间、ArgoCD、Gateway API CRDs
- **目标**：在不增加常驻内存、不引入 PDB 的前提下，把上一轮 Traefik 纳管/升级留下的 5 个遗留项收尾干净。

---

## 0. 最终状态

| 项目 | 状态 |
|---|---|
| Traefik Chart | `42.3.1` |
| Traefik 镜像 | `docker.io/traefik:v3.7.17` |
| Deployment | `1/1`，Pod 运行在 `worker02` |
| Service | `LoadBalancer`，EXTERNAL-IP `10.0.0.252`（未变化） |
| ArgoCD `app-of-apps` | Synced / Healthy |
| ArgoCD `platform-traefik` | Synced / Healthy |
| ArgoCD `platform-gateway-api` | Synced / Healthy |
| `helm list -n traefik` | 空（Helm release 记录已清理） |
| Gateway API CRDs | 6 个，`v1.4.0` standard channel，已由独立 Application 管理 |

---

## 1. 清理旧 Helm release 记录

### 问题

Traefik 之前由手工 Helm 安装，虽然已经被 ArgoCD 接管，但 `sh.helm.release.v1.traefik.v1~v5` 仍然存在：

- `helm list -n traefik` 仍显示 `37.4.0 / v3.6.2 rev 5`，与实际状态不符；
- 运维人员可能误执行 `helm upgrade`，直接覆盖 ArgoCD 管理的资源，造成 Git 与集群漂移；
- Helm 的 release secret 已不再更新，继续保留只会制造歧义。

### 处理

确认 ArgoCD 应用 Synced/Healthy 后，删除 Helm release 记录（只删 release 元数据，不碰任何运行资源）：

```bash
kubectl -n traefik delete secret -l owner=helm,name=traefik
```

验证：

```bash
helm list -n traefik          # 输出为空
helm status traefik -n traefik # Error: release: not found
```

### 说明

- 资源上的 `meta.helm.sh/release-name`、`meta.helm.sh/release-namespace` 注解和 `app.kubernetes.io/managed-by: Helm` 标签仍然保留。
  - 这些是 Helm 安装时留下的“所有权标记”，保留它们可以防止误用 `helm install` 重新接管；
  - 不影响 ArgoCD，ArgoCD 使用自己的 `argocd.argoproj.io/tracking-id`。
- 从此 Helm 不再是 Traefik 的发布工具，**所有变更只走 Git → ArgoCD**。

---

## 2. Gateway API CRDs 独立纳管

### 问题

- Chart `37.4.0` 自带 Gateway API CRDs；
- Chart `42.3.1` 只带 Traefik / Traefik Hub CRDs，**不再包含 Gateway API CRDs**；
- 因此升级后，6 个 Gateway API CRD 变成“孤儿资源”：当前 `prune: false` 所以还在，但一旦有人把 `platform-traefik` 的 prune 改成 `true`，它们就可能被删除。

同时确认了当前集群**没有任何 GatewayClass / Gateway / HTTPRoute / GRPCRoute 资源**，这 6 个 CRD 目前只是为将来 Gateway API 迁移预留。

### 处理

把这 6 个 standard channel CRD 从集群导出、清洗后 vendored 进 Git，并新建独立 Application 管理，避免与 Traefik 应用生命周期耦合。

**新增文件：**

```
platform/gateway-api/crds/
├── backendtlspolicies.gateway.networking.k8s.io.yaml
├── gatewayclasses.gateway.networking.k8s.io.yaml
├── gateways.gateway.networking.k8s.io.yaml
├── grpcroutes.gateway.networking.k8s.io.yaml
├── httproutes.gateway.networking.k8s.io.yaml
└── referencegrants.gateway.networking.k8s.io.yaml

clusters/prod/applications/platform-gateway-api.yaml
```

**Application 关键配置：**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-gateway-api
  namespace: argocd
spec:
  destination:
    namespace: default          # 仅形式要求，CRD 是集群级资源
    server: https://kubernetes.default.svc
  project: default
  source:
    path: platform/gateway-api/crds
    repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
    targetRevision: main
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

导出时已清洗掉 `resourceVersion`、`uid`、`creationTimestamp`、`generation`、`managedFields`、`status` 等运行时字段，只保留 `metadata`（含 `bundle-version` / `channel` 注解）和 `spec`。

### 验证

```bash
kubectl -n argocd get application platform-gateway-api
# Synced  Healthy

kubectl -n argocd get application platform-gateway-api \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status}{"\n"}{end}'
# 6 个 CustomResourceDefinition，全部 Synced

kubectl get crd | grep -c 'gateway.networking.k8s.io'
# 6
```

### 说明

- 现在 `platform-traefik` 的 `prune` 即使改成 `true`，也不会再误删 Gateway API CRDs；
- 当前固定为 `v1.4.0`（升级前集群里的版本）。将来真正启用 Traefik Gateway provider 时，再单独做一次 CRD 版本升级（Traefik 3.7 文档支持到 Gateway API 1.6.x），不要在本次收尾里混入版本变更。

---

## 3. Traefik 3.7 两个警告的处理

升级到 3.7.17 后出现两类新警告，均已处理。

### 3.1 `aliasHeadersStrategy` 未配置

**警告内容（摘要）：**

> request headers whose name aliases another header name (e.g. `X_Auth_User` / `X.Auth.User` for `X-Auth-User`) are forwarded as is ... allows a client to spoof the headers Traefik manages.

**风险：**

某些后端（CGI / WSGI / PHP / NGINX 等）会把 `X_Auth_User` 解析成 `X-Auth-User`，攻击者可以借此伪造 Traefik 管理的请求头。

**处理：**

在 `platform/traefik/values.yaml` 中设置全局策略：

```yaml
global:
  aliasHeadersStrategy: delete
```

渲染后生成：

```
--global.aliasHeadersStrategy=delete
```

对没有单独配置 `http.aliasHeadersStrategy` 的 entryPoint 生效（当前 4 个 entryPoint 全部覆盖）。

**为什么选 `delete` 而不是 `reject`：**

- `delete`：删除别名头，兼容性最好；
- `reject`：直接拒绝带别名头的请求，更严格但可能误伤现有客户端。

### 3.2 `SafeNaming` 未显式设置

**警告内容（摘要）：**

> SafeNaming is not explicitly set ... recommended to explicitly set to `true` on new setups, or to `false` to keep the legacy behavior and silence this warning.

**风险：**

不设置时，Traefik 3.7 会持续告警；但如果直接改成 `true`，生成的路由/服务/中间件名称会变化，可能影响现有 Ingress 中按旧命名引用的 middleware。

**处理：**

对现有集群显式保持 legacy 行为：

```yaml
providers:
  kubernetesCRD:
    safeNaming: false
```

渲染后生成：

```
--providers.kubernetescrd.safeNaming=false
```

**后续：**

- `safeNaming: true` 是更安全的方向，但应作为一次独立迁移来做：先在测试命名空间验证生成名称、再逐步切换；
- 本次不做，避免在收尾变更里引入路由命名风险。

### 验证

```bash
kubectl -n traefik logs deploy/traefik --since=3m \
  | grep -iE 'aliasHeadersStrategy|SafeNaming'
# 无输出
```

路由回归测试正常（见第 6 节）。

---

## 4. 单副本更新策略（内存约束）

### 问题

Chart 默认：

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

对单副本 Deployment 来说，升级时会**先创建第二个 Pod**，等新 Pod Ready 后再删旧 Pod。零中断，但会短暂占用双份内存。当前节点内存紧张，且已明确暂不引入 PDB。

### 处理

改为“先停旧、再起新”，保证任意时刻最多一个 Traefik Pod：

```yaml
deployment:
  replicas: 1

updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 0
```

### 代价

- 滚动更新期间有**秒级入口中断**（旧 Pod 终止到新 Pod Ready）；
- 换取的是不额外占用节点内存，符合当前约束。

### 验证

```bash
kubectl -n traefik get deploy traefik -o jsonpath='{.spec.strategy}{"\n"}'
# {"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}

kubectl -n traefik get pods
# 1/1 Running
```

### 后续（内存缓解后）

建议改为：

```yaml
deployment:
  replicas: 2
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

并加 PDB：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: traefik
  namespace: traefik
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
      app.kubernetes.io/instance: traefik-traefik
```

---

## 5. 清理 `last-applied-configuration`

### 问题

`traefik-dashboard-auth-secret` 和 `traefik-dashboard-auth` Middleware 早期由 `kubectl apply` 手工创建，带有：

```
kubectl.kubernetes.io/last-applied-configuration
```

这类注解会保留一份完整的旧 manifest，容易让人误以为资源仍由 `kubectl apply` 管理，也可能在后续 apply 时产生冲突。

### 处理

资源被 ArgoCD（`ServerSideApply=true`）接管后，该注解已不再由 ArgoCD 写入。检查并清理：

```bash
kubectl -n traefik annotate secret traefik-dashboard-auth-secret \
  kubectl.kubernetes.io/last-applied-configuration-

kubectl -n traefik annotate middleware traefik-dashboard-auth \
  kubectl.kubernetes.io/last-applied-configuration-
```

### 结果

```bash
kubectl -n traefik get secret traefik-dashboard-auth-secret \
  -o jsonpath='{.metadata.annotations}'
# {"sealedsecrets.bitnami.com/managed":"true"}

kubectl -n traefik get middleware traefik-dashboard-auth \
  -o jsonpath='{.metadata.annotations}'
# {"argocd.argoproj.io/tracking-id":"platform-traefik:traefik.io/Middleware:traefik/traefik-dashboard-auth"}
```

Secret 只保留 sealed-secrets 的接管标记，Middleware 只保留 ArgoCD 的 tracking 标记，职责清晰。

---

## 6. 最终验证

### 6.1 对象状态

```bash
kubectl -n argocd get applications | grep -E 'NAME|traefik|gateway-api|app-of-apps'

NAME                   SYNC STATUS   HEALTH STATUS
app-of-apps            Synced        Healthy
platform-gateway-api   Synced        Healthy
platform-traefik       Synced        Healthy
```

```bash
kubectl -n traefik get deploy,pod,svc

deployment.apps/traefik   1/1   1   1
pod/traefik-69b468c8b4-w2zfg   1/1   Running   0
service/traefik   LoadBalancer   10.111.240.160   10.0.0.252
```

### 6.2 版本

```bash
kubectl -n traefik exec deploy/traefik -- traefik version

Version:      3.7.17
Codename:     langres
Go version:   go1.27.3
```

### 6.3 路由冒烟

通过 LoadBalancer IP `10.0.0.252` 直接验证：

| Host | 协议 | 结果 | 说明 |
|---|---|---|---|
| `grafana.example.local` | HTTP | 301 | 正常跳转 |
| `grafana.k8s.local` | HTTPS | 302 | 正常跳转 |
| `argocd.devops.com` | HTTPS | 200 | 正常 |
| `prom.example.local` | HTTP | 301 | 正常跳转 |
| `studyfree.xyz` | HTTP | 200 | 正常 |
| `admin.studyfree.xyz` | HTTP | 200 | 正常 |
| `traefik.example.com/dashboard` | HTTPS | 401 | basic-auth 仍生效 |

### 6.4 Helm / CRD

```bash
helm list -n traefik
# 空

kubectl get crd | grep -c 'gateway.networking.k8s.io'
# 6
```

---

## 7. 变更清单

### Git 提交（`platform-gitops`，main）

| Commit | 内容 |
|---|---|
| `68eda2e` | Traefik 纳入 ArgoCD（chart 37.4.0 平滑接管） |
| `70a9286` | 去掉当前 ArgoCD 不支持的 `helm.includeCrds` |
| `4acfc1e` | 保留 OTLP tracing，dashboard Secret 改为 SealedSecret 并完成 adopt |
| `7cdb4b9` | Chart `37.4.0 → 42.3.1`（Traefik `v3.6.2 → v3.7.17`） |
| `b73c42a` | `aliasHeadersStrategy=delete`、`safeNaming=false`、`maxSurge=0` |
| `b667fb9` | Vendor 并独立管理 Gateway API `v1.4.0` CRDs |

### 关键文件

```
platform/traefik/values.yaml
clusters/prod/applications/platform-traefik.yaml
platform/gateway-api/crds/*.yaml
clusters/prod/applications/platform-gateway-api.yaml
```

---

## 8. 回滚方案

Helm release 记录已删除，回滚统一走 Git + ArgoCD。

### 8.1 只回滚本次警告/策略变更

```bash
cd /root/gitops-p0
git revert b73c42a
git push origin main
kubectl -n argocd annotate application platform-traefik \
  argocd.argoproj.io/refresh=normal --overwrite
```

### 8.2 回滚 Traefik 版本（`42.3.1 → 37.4.0`）

**注意顺序**：`--global.aliasHeadersStrategy` 是 Traefik 3.7.17+ 才有的参数，`safeNaming` 也要求 3.7.11+。如果直接只回滚 chart 版本，新的 values 会让 3.6.2 启动失败。必须**先回滚 values，再回滚 chart**：

```bash
# 1) 先 revert b73c42a（去掉 3.7 专有参数）
git revert b73c42a

# 2) 再把 targetRevision 改回 37.4.0
#    编辑 clusters/prod/applications/platform-traefik.yaml
git commit -am "revert(traefik): rollback to chart 37.4.0"
git push origin main

kubectl -n argocd annotate application platform-traefik \
  argocd.argoproj.io/refresh=normal --overwrite
```

由于当前 `maxSurge: 0`，回滚同样会有秒级中断，但镜像 `v3.6.2` 在 worker 上仍有缓存。

---

## 9. 后续建议

1. **内存缓解后恢复高可用**：2 副本 + `maxSurge: 1` + PDB `minAvailable: 1`。
2. **Gateway API 迁移**：CRD 已独立管理，下一步可评估启用 Traefik `kubernetesGateway` provider；届时把 CRD 升到 Traefik 3.7 支持的版本（1.6.x），并用 `HTTPRoute` 承载新服务，老 `Ingress` 按域名逐步切换。
3. **SafeNaming**：作为独立迁移项评估 `safeNaming: true`，先在测试命名空间验证生成名称变化。
4. **监控**：建议对 `helm list` 为空、ArgoCD OutOfSync、Traefik 5xx/证书过期增加告警（本次未涉及）。
