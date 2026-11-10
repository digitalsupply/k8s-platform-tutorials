# 第二阶段：收编 ArgoCD / Harbor / Ceph

> **阅读校正（2026-11-10 实测）**：原文把 Ceph 版本写成 17.2.8（Quincy）。
> 实际集群为 **18.2.8 Reef**（`ceph versions` 全部 18.2.8）。
> 结论不变：Quincy/Reef 的 Dashboard SSO 都只支持 SAML 2.0，OAuth2/OIDC 需要 Tentacle+。

> 目标：把 GitLab 作为统一身份源，继续接入 ArgoCD、Harbor，并评估 Ceph
> 执行日期：2026-11-10
> 前置：Grafana 已接入 GitLab OIDC（见 `README.md` 第 10 节）

## 1. 结果总览

| 系统 | 结果 | 身份协议 | 说明 |
|---|---|---|---|
| Grafana 12.4.3 | ✅ 已完成 | OIDC | 第一阶段 |
| ArgoCD 3.5.3 | ✅ 已完成 | OIDC | Helm bootstrap，配置已入库 |
| Harbor 2.14.5 | ✅ 已完成 | OIDC | 外部实例，配置在 Harbor DB |
| Ceph Dashboard 17.2.8 | ⛔ 阻塞 | SAML 2.0 | Quincy 不支持 OIDC；GitLab 不是 SAML IdP |
| Traefik / Hubble / Tekton / Alloy | ⏳ 待做 | ForwardAuth | UI 本身无登录体系 |

---

## 2. ArgoCD 接入 GitLab OIDC

### 2.1 现状

ArgoCD 是集群的 bootstrap 组件，由 Helm release `argocd`（chart `argo-cd-10.9.6`，
app `v3.5.3`）安装，**不是由 ArgoCD 自己同步的**。因此采用：

- `platform/argocd/values.yaml` 作为声明式 source of truth；
- 变更通过 `helm upgrade` 应用；
- 这是整个 GitOps 体系里唯一的 bootstrap 例外。

### 2.2 GitLab OAuth Application

| 字段 | 值 |
|---|---|
| name | `argocd` |
| client_id | `7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe` |
| redirect_uri | `https://argocd.devops.com/auth/callback` |
| scopes | `openid profile email` |
| secret | SealedSecret `argocd/argocd-oauth`，key `client-secret` |

### 2.3 配置内容

`platform/argocd/values.yaml`：

```yaml
configs:
  cm:
    url: https://argocd.devops.com
    oidc.config: |
      name: GitLab
      issuer: http://192.168.67.201
      clientID: 7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe
      clientSecret: $argocd-oauth:client-secret
      requestedScopes: ["openid", "profile", "email"]
      requestedIDTokenClaims:
        groups:
          essential: true
      enablePKCEAuthentication: true
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, digitalsupply, role:admin
      g, gitlab_admin_526ef4@example.com, role:admin
    scopes: '[groups, email]'
```

要点：

- `clientSecret: $argocd-oauth:client-secret` 是 ArgoCD 的 Secret 引用语法，
  从同 namespace 的 Secret 读取，不需要把 secret 写进 values；
- GitLab 目前是 HTTP，`issuer` 也用 `http://`。ArgoCD 可以工作，但没有 TLS；
- `groups` claim 缺失时，`email` 作为兜底；GitLab root 的邮箱已加入 admin；
- 默认 `role:readonly`，避免所有登录用户默认有写权限。

### 2.4 应用命令

```bash
helm repo add argo https://argoproj.github.io/argo-helm   # 首次
helm repo update argo

helm -n argocd upgrade argocd argo/argo-cd \
  --version 10.9.6 \
  -f platform/argocd/values.yaml \
  --reuse-values \
  --wait --timeout 4m
```

SealedSecret 需要先创建：

```bash
# client secret 由 scripts/gitlab-create-grafana-oauth-app.sh 的通用逻辑或 API 创建
kubectl apply -f platform/argocd/sealedsecret-argocd-oauth.yaml
kubectl -n argocd get secret argocd-oauth
```

### 2.5 验证

```bash
# 配置已进入 argocd-cm
kubectl -n argocd get cm argocd-cm -o yaml | grep -A12 "oidc.config"

# RBAC 已生效
kubectl -n argocd get cm argocd-rbac-cm -o yaml | sed -n '/^data:/,/^kind:/p'

# ArgoCD 返回 GitLab 授权地址（303）
curl -sk --resolve argocd.devops.com:443:10.0.0.252 \
  -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://argocd.devops.com/auth/login

# /api/v1/settings 能看到 oidcConfig
curl -sk --resolve argocd.devops.com:443:10.0.0.252 \
  https://argocd.devops.com/api/v1/settings | grep -o '"oidcConfig".*'
```

实际结果：

- `/auth/login` 返回 `303`，跳转到 GitLab `/oauth/authorize`，带 PKCE；
- `/api/v1/settings` 返回 `oidcConfig`；
- ArgoCD Pod 正常，`platform-monitoring-stack` 仍为 `Synced / Healthy`。

### 2.6 本地 admin 说明

`argocd-cm` 的 `admin.enabled` 仍为 `true`，本地 admin 未被禁用。
但 `argocd-initial-admin-secret` 里的初始密码可能已被修改，实测用该密码登录返回 401。
因此当前的管理员入口是 **GitLab root / digitalsupply 组**。

如需重置本地 admin：

```bash
# 已登录管理员会话中
argocd account update-password

# 或使用 bcrypt 后 patch argocd-secret 的 admin.password
```

### 2.7 轮换 client secret

```bash
# 1. 在 GitLab 删除并重建 argocd Application，或重新生成 secret
# 2. 重新 seal 到 argocd/argocd-oauth
kubectl -n argocd create secret generic argocd-oauth \
    --dry-run=client -o yaml \
    --from-literal=client-secret='<NEW_SECRET>' \
| kubeseal --namespace argocd --name argocd-oauth \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
    --format yaml \
> platform/argocd/sealedsecret-argocd-oauth.yaml

kubectl apply -f platform/argocd/sealedsecret-argocd-oauth.yaml
kubectl -n argocd rollout restart deploy/argocd-server
```

### 2.8 排错记录（2026-11-10）

实际登录时遇到过两个报错：

#### 错误 1：`invalid_client`

```text
failed to get token: oauth2: "invalid_client"
"Client authentication failed due to unknown client, no client authentication included,
or unsupported authentication method."
```

根因不是 secret 值错误，而是 **Secret 缺少 ArgoCD 标签**：

- ArgoCD 的 `$secret-name:key` 引用只解析带有
  `app.kubernetes.io/part-of: argocd` 标签的 Secret；
- `argocd-oauth` 当时没有标签，ArgoCD 把字面量
  `$argocd-oauth:client-secret` 当作密码发给 GitLab；
- `argocd-server` 日志同时出现：

```text
level=warning msg="secret key does not exist in secret"
```

修复：在 SealedSecret 的 `template.metadata.labels` 加入：

```yaml
labels:
  app.kubernetes.io/part-of: argocd
```

重新 apply 后，Secret 带上标签，警告消失。

#### 错误 2：`data length is less than nonce size`

这是 ArgoCD OIDC **state cookie** 的问题，不是 client secret 错误：

- 常见于升级后浏览器里残留旧的 `argocd.oauthstate` / `argocd.token` cookie；
- 或在深链接/iframe 场景下 cookie 路径不匹配。

修复：

1. 清除 `argocd.devops.com` 的浏览器 cookie；
2. 直接打开
   `https://argocd.devops.com/login?return_url=https%3A%2F%2Fargocd.devops.com%2Fapplications`
3. 重新点击 “Log in via GitLab”。

#### 验证 client secret 是否正确

不依赖浏览器，可以直接用集群里的 Secret 调 GitLab token 端点：

```bash
SEC=$(kubectl -n argocd get secret argocd-oauth -o jsonpath='{.data.client-secret}' | base64 -d)
curl -s -X POST http://192.168.67.201/oauth/token \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=dummy" \
  --data-urlencode "redirect_uri=https://argocd.devops.com/auth/callback" \
  --data-urlencode "client_id=7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe" \
  --data-urlencode "client_secret=$SEC"
```

预期返回：

```json
{"error":"invalid_grant","error_description":"The provided authorization grant is invalid..."}
```

返回 `invalid_grant` 说明 client_id/secret 正确；返回 `invalid_client` 才是 secret 有问题。

#### 验证 state cookie

用 curl 保存 `/auth/login` 的 cookie，再带一个 dummy code 调 callback：

```bash
curl -sk -c /tmp/cj --resolve argocd.devops.com:443:10.0.0.252 \
  -o /dev/null https://argocd.devops.com/auth/login
# 从 Location 里取 state，再请求 /auth/callback?code=dummy&state=...
```

如果返回 `failed to get token: ... invalid_grant`，说明 state cookie 和
client secret 都正常；只有 `invalid_grant` 是因为 code 是假的。

---

## 3. Harbor 接入 GitLab OIDC

### 3.1 现状

Harbor 不在 k8s 内，地址：

```text
https://192.168.67.202:8443
Harbor v2.14.5
external_url = https://192.168.67.202:8443
```

Harbor 的配置存在自己的数据库里，**无法通过 ArgoCD/SealedSecret 管理**。
本节的配置通过 Harbor API 一次性写入，过程记录在本文档中。

### 3.2 GitLab OAuth Application

| 字段 | 值 |
|---|---|
| name | `harbor` |
| client_id | `c7924430a6d02f5e14da2251233eb98c7a880ece868c96758da91ebd7c1ae502` |
| redirect_uri | `https://192.168.67.202:8443/c/oidc/callback` |
| scopes | `openid profile email` |
| secret | 只保存在 Harbor 数据库（不落 Git） |

### 3.3 配置过程

先备份当前 Harbor 配置（不在 Git 中）：

```bash
# 使用 Harbor admin 凭据
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  https://192.168.67.202:8443/api/v2.0/configurations \
  -o /root/harbor-config-backup-20261110.json
chmod 600 /root/harbor-config-backup-20261110.json
```

写入 OIDC 字段（此时 `auth_mode` 仍是 `db_auth`）：

```bash
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  -X PUT -H 'Content-Type: application/json' \
  https://192.168.67.202:8443/api/v2.0/configurations \
  -d '{
    "oidc_name": "GitLab",
    "oidc_endpoint": "http://192.168.67.201",
    "oidc_client_id": "c7924430a6d02f5e14da2251233eb98c7a880ece868c96758da91ebd7c1ae502",
    "oidc_client_secret": "<GITLAB_HARBOR_SECRET>",
    "oidc_groups_claim": "groups",
    "oidc_admin_group": "digitalsupply",
    "oidc_user_claim": "preferred_username",
    "oidc_scope": "openid,profile,email",
    "oidc_auto_onboard": true,
    "oidc_verify_cert": false
  }'
```

确认字段写入后，再切换认证模式（单独一步，便于回滚）：

```bash
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  -X PUT -H 'Content-Type: application/json' \
  https://192.168.67.202:8443/api/v2.0/configurations \
  -d '{"auth_mode":"oidc_auth"}'
```

### 3.4 验证

```bash
# auth_mode 已切换
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  https://192.168.67.202:8443/api/v2.0/systeminfo | grep -o '"auth_mode":"[^"]*"'

# 本地 admin API 仍然可用（break-glass）
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  -o /dev/null -w '%{http_code}\n' \
  https://192.168.67.202:8443/api/v2.0/users/current

# Harbor OIDC 登录入口跳转 GitLab（302）
curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://192.168.67.202:8443/c/oidc/login
```

实际结果：

- `auth_mode=oidc_auth`；
- 本地 admin API 仍返回 `200`，不会被锁死；
- `/c/oidc/login` 返回 `302` 到 GitLab `/oauth/authorize`，带 PKCE；
- `oidc_name=GitLab`。

### 3.5 回滚

Harbor 明确允许本地 `admin` 在 OIDC 模式下继续登录，所以回滚很直接：

```bash
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" \
  -X PUT -H 'Content-Type: application/json' \
  https://192.168.67.202:8443/api/v2.0/configurations \
  -d '{"auth_mode":"db_auth"}'
```

### 3.6 注意事项

- Harbor 要求回调 URI 与 GitLab Application 完全一致；
- `oidc_scope` 用**逗号**分隔（Harbor 的约定，和 Grafana/ArgoCD 的空格不同）；
- GitLab 是 HTTP，`oidc_verify_cert=false` 仅对 HTTPS 有意义，这里主要是接受 HTTP endpoint；
- OIDC 用户首次登录需要确认 Harbor 用户名（auto onboard 打开）；
- 组权限映射依赖 GitLab 的 `groups` claim，缺失时由本地 admin 手工授权。

---

## 4. Ceph Dashboard：为什么这次没收编

### 4.1 版本限制

```text
ceph version 17.2.8 (Quincy)
```

Ceph Dashboard 的 SSO 支持情况：

| Ceph 版本 | 支持 |
|---|---|
| Quincy 17.2 | **SAML 2.0**（`ceph dashboard sso setup saml2`） |
| Reef 18.2 | SAML 2.0 |
| Tentacle+ | SAML 2.0 + OAuth2/OIDC（`mgmt-gateway` + `oauth2-proxy`） |

**Quincy 没有 OAuth2/OIDC 的 Dashboard SSO。** 而 GitLab 是 OIDC/SAML 的
Service Provider（SP），不是 SAML Identity Provider（IdP），所以 GitLab 不能
直接给 Ceph 做 SAML 登录。

### 4.2 还缺什么

要收编 Ceph，至少需要：

1. 一个 SAML 2.0 IdP（推荐 Keycloak）；
2. Ceph mgr 节点安装 `python3-saml`；
3. Ceph mgr 节点能解析 IdP 域名（例如 `sso.k8s.local`）；
4. Ceph 管理员 keyring（`client.admin`），用于执行 `ceph dashboard sso ...`。

当前环境：

- 没有 Keycloak；
- `csi-rbd-secret` 的 `kubernetes` 用户没有 dashboard/mgr 权限；
- 到 Ceph mon 节点（10.0.0.31/41/51）的 SSH 被拒绝，拿不到 admin keyring；
- `sso.k8s.local` 尚未部署。

### 4.3 后续执行步骤（有 Keycloak 后）

```bash
# 1. Keycloak 建 SAML client：ceph-dashboard
#    ACS:     https://<ceph-dashboard>/auth/saml2/
#    Entity:  https://<ceph-dashboard>/auth/saml2/metadata

# 2. 在 Ceph mgr 节点确认 python3-saml
python3 -c 'import onelogin.saml2; print("ok")'

# 3. 配置 SAML
ceph dashboard sso setup saml2 \
  https://<ceph-dashboard> \
  https://sso.k8s.local/realms/platform/protocol/saml/descriptor \
  <username-attribute> \
  <idp-entity-id>

ceph dashboard sso enable saml2
ceph dashboard sso status
```

### 4.4 替代方案

如果不想部署 Keycloak：

- 升级 Ceph 到 Tentacle+，启用 `mgmt-gateway` + `oauth2-proxy`，
  再用 GitLab OIDC；
- 或保持 Ceph 本地账号，暂不纳入统一 SSO。

---

## 5. Traefik / Hubble / Tekton / Alloy：已实施 oauth2-proxy 反向代理

这些 UI 本身没有登录体系，原先各自用 basicAuth middleware：

- `traefik/traefik-dashboard-auth`
- `kube-system/hubble-ui-auth`
- `logging/alloy-ui-auth`
- `tekton-pipelines/tekton-dashboard-auth`

### 5.1 为什么没有用 ForwardAuth

最初尝试了 Traefik `forwardAuth` + `errors` 组合，但 oauth2-proxy 的
`/oauth2/auth` 在未登录时返回 **401 + Location**，浏览器不会自动跟随 401 的
Location，结果页面停在 401/错误页。

因此改为 **oauth2-proxy 反向代理模式**：

```text
浏览器 -> Traefik -> oauth2-proxy-<host> -> 后端 UI
                          └── GitLab OIDC
```

Traefik 把整个 host 路由到 oauth2-proxy；oauth2-proxy 自己处理 `/oauth2/*`
登录回调，并把已认证请求代理到 upstream。

### 5.2 部署结构

| host | oauth2-proxy 实例 | upstream |
|---|---|---|
| `traefik.xyz` | `oauth2-proxy-traefik` | `http://traefik-api.traefik.svc.cluster.local:9000` |
| `hubble.xyz` | `oauth2-proxy-hubble` | `http://hubble-ui.kube-system.svc.cluster.local:80` |
| `alloy.xyz` | `oauth2-proxy-alloy` | `http://alloy.logging.svc.cluster.local:12345` |
| `tekton.xyz` | `oauth2-proxy-tekton` | `http://tekton-dashboard.tekton-pipelines.svc.cluster.local:9097` |

相关文件：

```text
platform/sso/oauth2-proxy/          # Helm chart + ArgoCD App
├── values.yaml                     # 4 个实例、clientID、upstream
├── templates/deployment.yaml
├── templates/service.yaml
├── templates/ingressroutes.yaml    # /oauth2/ 路由
├── templates/traefik-api-service.yaml
└── templates/sealedsecret-*.yaml   # client-secret + cookie-secret

platform/ui/                        # 4 个 host 的 IngressRoute
clusters/prod/applications/platform-sso-oauth2-proxy.yaml
```

### 5.3 关键配置

- 每个 host 一个 GitLab OAuth Application，回调
  `https://<host>/oauth2/callback`；
- 每个实例独立的 32 字符 cookie secret（`openssl rand -hex 16`）；
- cookie 不跨域：`hubble.xyz`、`alloy.xyz` 等没有共享父域，`*.xyz` 是公共后缀；
- `traefik.xyz` 的后端是 Traefik API `:9000`，需要：
  - `--api=true` + `--api.insecure=true`（`traefik-api` 是 ClusterIP，仅集群内可达）；
  - 用 `redirectRegex` 把 `/` 重定向到 `/dashboard/`，因为 API 根路径本身返回 404；
- Traefik 开启：

```yaml
providers:
  kubernetesCRD:
    allowCrossNamespace: true
```

因为 `platform/ui` 里的 IngressRoute 跨 namespace 引用 `oauth2-proxy` 的 Service。

### 5.4 验证

```bash
for h in hubble alloy tekton traefik; do
  curl -sk --resolve $h.xyz:443:10.0.0.252 \
    -o /dev/null -w "$h %{http_code} -> %{redirect_url}\n" https://$h.xyz/
done
```

四个 host 都返回 `302` 到 GitLab `/oauth/authorize`，带 PKCE。

### 5.5 回滚

旧的 basicAuth Middleware/Secret 仍然保留：

- `kube-system/hubble-ui-auth`
- `logging/alloy-ui-auth`
- `tekton-pipelines/tekton-dashboard-auth`
- `traefik/traefik-dashboard-auth`

把 IngressRoute 的 service 改回原 UI、middlewares 挂回 basicAuth 即可。

### 5.6 注意事项

- `.xyz` 域名在公网 DNS 上指向其他 IP；浏览器需要本机 hosts 或内部 DNS
  指向 Traefik VIP `10.0.0.252`，否则会访问到公网同名站点；
- oauth2-proxy 当前固定在 worker02（镜像缓存），所有 worker 缓存后可移除约束；
- 需要真实 GitLab 用户浏览器验证，确认登录后能代理到各 UI。

---

## 6. 当前 SSO 状态

| 系统 | 状态 | 管理方式 |
|---|---|---|
| Grafana | ✅ GitLab OIDC | GitOps（values + SealedSecret） |
| ArgoCD | ✅ GitLab OIDC | Helm bootstrap（values 入库） |
| Harbor | ✅ GitLab OIDC | Harbor DB（文档记录） |
| Ceph | ⛔ 阻塞 | 需要 Keycloak + SAML |
| Traefik/Hubble/Tekton/Alloy | ⏳ 待做 | oauth2-proxy ForwardAuth |

## 7. 安全与后续

1. **GitLab 仍是 HTTP**：OIDC client secret 在内网明文传输，建议尽快给 GitLab 加 TLS；
2. **自签证书**：ArgoCD/Harbor 的 HTTPS 入口仍可能触发浏览器告警；
3. **break-glass**：Grafana 本地 admin、ArgoCD 本地 admin、Harbor 本地 admin 都保留；
4. **组映射验证**：需要真实 GitLab 用户登录一次，确认 `groups` claim；
5. **Keycloak**：如果要做 Ceph 和更统一的 SSO，下一步应部署 Keycloak，
   并考虑把 Grafana/ArgoCD/Harbor 逐步迁移到 Keycloak（GitLab 变为客户端）。
