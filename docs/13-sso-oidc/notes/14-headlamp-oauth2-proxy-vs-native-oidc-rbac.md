# Headlamp：oauth2-proxy 反向代理 vs 原生 OIDC + K8s RBAC 对比

> 实测环境：K8s `v1.35.9`（3 control-plane + workers），Headlamp `ghcr.io/headlamp-k8s/headlamp:v0.46.0`，GitLab CE `19.5.0`，oauth2-proxy `v7.15.6`。  
> 目的：对比当前“oauth2-proxy 统一入口认证”与“Headlamp 原生 OIDC + K8s RBAC”两种模式的配置、权限模型和风险。

## 1. 结论先看

| 维度 | 当前：oauth2-proxy ReverseProxy | 目标：Headlamp 原生 OIDC + K8s RBAC |
|---|---|---|
| 认证发生位置 | Traefik 后面的 oauth2-proxy | Headlamp 应用自身 |
| GitLab OAuth 应用 | `oauth2-headlamp`，回调 `https://headlamp.devops.com/oauth2/callback` | 需要 Headlamp OIDC 回调（通常 `https://headlamp.devops.com/oidc-callback`，以实际版本/配置为准） |
| Headlamp 进程参数 | `-in-cluster -plugins-dir=/headlamp/plugins -session-ttl=86400 -unsafe-use-service-account-token` | 增加 `-oidc-client-id/-oidc-client-secret/-oidc-idp-issuer-url/-oidc-scopes` 等 |
| K8s API 身份 | Headlamp SA `headlamp` 的 token（所有登录用户共用同一 K8s 身份） | 用户 OIDC token 身份（需 apiserver OIDC 认证）或 Headlamp 代理/模拟；取决于部署方式 |
| K8s 权限粒度 | 取决于 Headlamp SA 的 ClusterRoleBinding | 取决于 OIDC 用户/组到 K8s Role/ClusterRoleBinding 的映射 |
| 最高权限实现 | 给 Headlamp SA 绑 `cluster-admin`（**极危险**：所有能过 oauth2-proxy 的人都拿到同等权限） | 给特定 OIDC 用户/组绑 `cluster-admin`（仍高风险，但可按身份审计/收敛） |
| apiserver 改动 | 无 | 若要用用户 OIDC token 直通 K8s API，需配置 apiserver `--oidc-*` |
| 运维复杂度 | 低，和其他 UI 统一 | 中高，涉及 Headlamp + GitLab/IdP + K8s apiserver/RBAC |

## 2. 当前模式实测（oauth2-proxy）

### 2.1 流量链路

```text
浏览器
  -> Traefik (websecure, headlamp.devops.com)
  -> oauth2-proxy-headlamp Service:4180 (无 ForwardAuth middleware，ReverseProxy)
  -> GitLab OAuth/OIDC 登录
  -> oauth2-proxy-headlamp 代理到 headlamp.headlamp.svc:80
  -> Headlamp 使用 in-cluster ServiceAccount token 访问 K8s API
```

### 2.2 Headlamp Deployment（当前）

```yaml
image: ghcr.io/headlamp-k8s/headlamp:v0.46.0
serviceAccountName: headlamp
args:
  - -in-cluster
  - -in-cluster-context-name=main
  - -plugins-dir=/headlamp/plugins
  - -session-ttl=86400
  - -unsafe-use-service-account-token
```

关键点：

- `-in-cluster`：Headlamp 使用 Pod 内 SA 凭据访问 K8s API。
- `-unsafe-use-service-account-token`：允许使用 SA token；适合内部受控入口，但边缘认证一旦被绕过风险大。
- 没有 `-oidc-*` 参数：Headlamp 本身不做 OIDC 登录。

### 2.3 当前 RBAC（实测）

```text
ServiceAccount: headlamp/headlamp

ClusterRoleBinding headlamp-admin        -> ClusterRole/view
ClusterRoleBinding headlamp-cluster-read -> ClusterRole/headlamp-cluster-read
```

`headlamp-cluster-read` 实测包含 nodes/pv/namespaces/secrets/storageclasses 等只读权限（见集群实际对象）。这意味着：**只要通过 oauth2-proxy 进入 Headlamp，用户看到的是 Headlamp SA 的权限视图，而不是自己的 K8s 身份权限**。

### 2.4 oauth2-proxy（当前）

GitLab OAuth 应用：`oauth2-headlamp`（id 12）

- `client_id`: `0217d40851fad8c6fa09f1ff3464d5fae1531b93802f6a56501bd24644f5b4cc`
- `redirect_uri`: `https://headlamp.devops.com/oauth2/callback`
- `scopes`: `openid profile email`
- `device_code_enabled`: `true`

oauth2-proxy Deployment 关键参数：

```text
--provider=oidc
--oidc-issuer-url=http://192.168.67.201
--redirect-url=https://headlamp.devops.com/oauth2/callback
--upstream=http://headlamp.headlamp.svc.cluster.local:80
--reverse-proxy=true
--set-xauthrequest=true
```

## 3. 原生 OIDC 模式（目标方案）

### 3.1 目标链路

```text
浏览器
  -> Traefik (headlamp.devops.com)
  -> Headlamp Service/Pod
  -> Headlamp 发起 OIDC 登录（GitLab/Keycloak）
  -> 回调到 Headlamp /oidc-callback
  -> Headlamp 获取用户身份/token
  -> Headlamp 使用用户凭据访问 K8s API（需 apiserver OIDC/RBAC 配套）
```

### 3.2 需要改动的组件

| 组件 | 需要改什么 | 原因 |
|---|---|---|
| GitLab OAuth 应用 | 新增/修改 Headlamp 原生 OIDC 应用，回调改为 Headlamp OIDC callback | oauth2-proxy 回调与 Headlamp 原生回调不同 |
| Headlamp Deployment | 添加 `-oidc-*` 参数，去掉或调整 `-in-cluster -unsafe-use-service-account-token` | 让 Headlamp 自己做 OIDC |
| Traefik IngressRoute | 直接指向 Headlamp Service，不再指向 oauth2-proxy-headlamp | 认证下沉到应用 |
| oauth2-proxy | 下线 `oauth2-proxy-headlamp` 实例（如果不再使用） | 避免重复认证层 |
| K8s apiserver | 配置 `--oidc-issuer-url --oidc-client-id --oidc-username-claim --oidc-groups-claim` 等 | 让 K8s API 认可 OIDC token 身份 |
| K8s RBAC | 创建 `ClusterRoleBinding`，将 OIDC 用户/组绑定到 `cluster-admin` 或其他角色 | 实现“最高权限 RBAC” |

### 3.3 Headlamp 原生 OIDC 配置示例

> 以下为示例，请以 Headlamp v0.46.0 实际参数为准；上线前在测试环境验证。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headlamp
  namespace: headlamp
spec:
  template:
    spec:
      serviceAccountName: headlamp
      containers:
        - name: headlamp
          image: ghcr.io/headlamp-k8s/headlamp:v0.46.0
          args:
            - -in-cluster
            - -plugins-dir=/headlamp/plugins
            - -session-ttl=86400
            # 原生 OIDC
            - -oidc-client-id=$(OIDC_CLIENT_ID)
            - -oidc-client-secret=$(OIDC_CLIENT_SECRET)
            - -oidc-idp-issuer-url=http://192.168.67.201
            - -oidc-scopes=openid,profile,email
            # 可选：按实际版本支持情况调整 callback/external url
            # - -oidc-callback-url=https://headlamp.devops.com/oidc-callback
          env:
            - name: OIDC_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: headlamp-oidc
                  key: client-id
            - name: OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: headlamp-oidc
                  key: client-secret
```

注意：如果要“用户身份直通 K8s API RBAC”，通常不要让所有用户共享一个高权限 SA token 作为主要授权来源；应结合 Headlamp 的认证模式和 apiserver OIDC 配置评估。

### 3.4 GitLab OAuth 应用调整

当前 oauth2-proxy 应用：

```text
name=oauth2-headlamp
redirect_uri=https://headlamp.devops.com/oauth2/callback
```

原生 OIDC 方案（示例）：

```text
name=headlamp-oidc
redirect_uri=https://headlamp.devops.com/oidc-callback
scopes=openid profile email
confidential=true
```

> 实际回调路径以 Headlamp 版本文档和运行日志为准，先在测试环境验证。

### 3.5 K8s apiserver OIDC 配置（用户 OIDC -> K8s RBAC 必需）

如果目标是“登录用户的 OIDC 身份由 K8s RBAC 授权”，apiserver 需要信任 OIDC issuer：

```text
--oidc-issuer-url=http://192.168.67.201
--oidc-client-id=<headlamp-client-id>
--oidc-username-claim=preferred_username
--oidc-groups-claim=groups
# GitLab HTTP issuer 场景还要评估 CA/HTTP/issuer 校验限制；生产建议 HTTPS
```

本环境实测 apiserver 当前未发现 `--oidc-*` 参数，因此**不能直接获得“用户 OIDC 身份 -> K8s RBAC”闭环**，除非先改 apiserver。

### 3.6 “最高权限 RBAC”映射示例

> 警告：`cluster-admin` 是全集群最高权限。仅在明确授权、审计完备、短期排障或严格受控场景使用。

#### 方案 A：给特定 OIDC 用户 cluster-admin（推荐于“最高权限但可审计”）

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-oidc-cluster-admin
subjects:
  - kind: User
    name: root   # 取决于 apiserver oidc-username-claim 映射值
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

#### 方案 B：给 OIDC 组 cluster-admin

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-oidc-group-cluster-admin
subjects:
  - kind: Group
    name: digitalsupply   # 取决于 GitLab groups claim 与 apiserver oidc-groups-claim
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

#### 方案 C：当前 oauth2-proxy 模式下“最高权限”（不推荐）

如果继续用 oauth2-proxy + Headlamp SA token，只能把 Headlamp SA 绑定到 cluster-admin：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-sa-cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp
    namespace: headlamp
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

这会导致：**任何通过 oauth2-proxy 认证进入 Headlamp 的人，都共享同一个 cluster-admin SA 身份**，无法做 per-user K8s RBAC 审计隔离。

## 4. 详细配置差异

| 配置项 | oauth2-proxy 模式（当前） | 原生 OIDC 模式 |
|---|---|---|
| Traefik IngressRoute backend | `oauth2-proxy-headlamp.oauth2-proxy.svc:4180` | `headlamp.headlamp.svc:80` |
| ForwardAuth middleware | 无（ReverseProxy） | 无 |
| oauth2-proxy Deployment | 需要 `oauth2-proxy-headlamp` | 可移除该实例 |
| GitLab 回调 | `/oauth2/callback` | `/oidc-callback`（示例，需验证） |
| Headlamp 登录 | 由 oauth2-proxy 完成 | 由 Headlamp 完成 |
| Headlamp 参数 | `-in-cluster -unsafe-use-service-account-token` | 增加 `-oidc-*`；SA token 策略按模式调整 |
| K8s 身份 | 共享 SA | 可按 OIDC 用户身份（需 apiserver OIDC） |
| RBAC 绑定对象 | ServiceAccount | User/Group（OIDC claim 映射） |
| 审计粒度 | 边缘认证用户 != K8s 用户 | 可做到 K8s 用户级审计（前提配置正确） |
| apiserver 配置 | 不需要 OIDC | 需要 OIDC（用户身份直通场景） |
| 故障面 | GitLab + oauth2-proxy + Traefik | GitLab/IdP + Headlamp + apiserver OIDC + RBAC |

## 5. 推荐决策

- **只需要统一登录门禁，不需要 K8s per-user RBAC**：保持 oauth2-proxy 模式，给 Headlamp SA 最小只读权限。
- **需要 per-user K8s RBAC / 审计 / 最小权限**：评估原生 OIDC + apiserver OIDC + RBAC。不要直接给所有人 cluster-admin。
- **用户要求“最高权限 RBAC”**：可绑定特定 OIDC 用户/组到 `cluster-admin`，但必须限制范围、启用审计、保留 break-glass，并评估 GitLab HTTP issuer 在 apiserver OIDC 场景的兼容性与安全性。

## 6. 上线前检查清单

- [ ] 确认 Headlamp v0.46.0 支持的 OIDC 参数与 callback 路径
- [ ] 在 GitLab 创建/更新 OAuth 应用回调 URI
- [ ] 评估 apiserver OIDC 配置变更窗口（控制面滚动）
- [ ] 创建最小权限 RBAC，验证后再考虑 cluster-admin
- [ ] 保留 break-glass 访问（本地 kubeconfig / 管理员通道）
- [ ] 验证登录、登出、token 过期、组映射、审计日志
- [ ] 下线旧 oauth2-proxy-headlamp 实例前确认无流量依赖

## 7. 2026-11-24 实施记录（方案 A）

按确认执行了**方案 A：保持 oauth2-proxy 模式，仅将 Headlamp SA 绑定 cluster-admin**。

```bash
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-cluster-admin
  labels:
    app.kubernetes.io/part-of: headlamp
    app.kubernetes.io/managed-by: opencode
subjects:
  - kind: ServiceAccount
    name: headlamp
    namespace: headlamp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
YAML
```

验证：

```bash
kubectl auth can-i '*' '*' --as=system:serviceaccount:headlamp:headlamp
# yes
```

风险提示：当前仍是 oauth2-proxy 边缘认证 + 共享 Headlamp SA。任何能通过 oauth2-proxy 进入 Headlamp 的用户，都会获得该 SA 的 `cluster-admin` 权限，无法按用户区分 K8s RBAC 审计。建议后续评估 per-user OIDC RBAC（需 apiserver HTTPS OIDC issuer）。
