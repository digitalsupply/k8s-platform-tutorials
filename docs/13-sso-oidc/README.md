# 13 · GitLab SSO / OIDC：把平台 UI 收进统一身份

## 当时的情况

2026-11-10 之前，集群里每个 Web UI 都是一套独立账号：

| 系统 | 改造前登录方式 | 问题 |
|---|---|---|
| Grafana | 本地 `admin` + 密码 | 密码共享、离职难回收、无审计 |
| ArgoCD | 本地 `admin` + 初始密码 | 初始密码可能已改，团队共用 |
| Harbor | `db_auth` 本地账号 | 与 GitLab 账号两套 |
| Traefik Dashboard | Traefik basicAuth | 一套 htpasswd 共用 |
| Hubble UI | basicAuth | 同上 |
| Alloy UI | basicAuth | 同上 |
| Tekton Dashboard | basicAuth | 同上 |
| Ceph Dashboard | 本地账号 | 无法接 OIDC（见下文） |

身份源选择：GitLab CE **19.5.0**，地址 `http://192.168.67.201`。
它本身支持 OAuth2/OIDC discovery，已经在用 GitLab 做代码托管和 CI，直接拿它当 IdP 最省事。

目标：

1. Grafana / ArgoCD / Harbor 用**原生 OIDC**；
2. Traefik / Hubble / Alloy / Tekton 这些**没有登录体系**的 UI，用 `oauth2-proxy` 做反向代理；
3. 保留本地 admin / basicAuth 作为 break-glass；
4. 所有 client secret 只进 SealedSecret，不进 Git。

当天真正动手时，先遇到的不是 OIDC 问题，而是 **GitLab 自身坏了**：
`POST /api/v4/applications` 返回 500，根分区 100%，还有 **196 条数据库迁移没跑**。
修完 GitLab 才开始接 SSO。

## 主要概念与原理

### 1. 认证、授权、SSO

| 概念 | 回答的问题 | 本平台例子 |
|---|---|---|
| **认证 Authentication** | 你是谁 | GitLab 登录、MFA |
| **授权 Authorization** | 你能做什么 | ArgoCD `role:admin`、Grafana `GrafanaAdmin`、Harbor 项目管理员 |
| **SSO** | 多个系统信任同一个 IdP，登录一次复用会话 | 登录 GitLab 后访问 Grafana/ArgoCD |

SSO **只统一认证，不统一权限**。同一个人在 Grafana 可以是 Viewer，在 ArgoCD 可以是 admin，
权限仍由各系统自己的 RBAC/角色映射决定。

### 2. OAuth2 与 OIDC

- **OAuth2** 是授权框架：应用如何拿到访问资源的 token；
- **OIDC** 是 OAuth2 之上的认证层：额外返回 **ID Token**，告诉应用“用户是谁”。

四个角色：

| 角色 | 本平台对应 |
|---|---|
| Resource Owner | 用户 |
| Client | Grafana / ArgoCD / Harbor / oauth2-proxy |
| Authorization Server | GitLab |
| Resource Server | GitLab API / `/oauth/userinfo` |

OIDC discovery：

```bash
curl -s http://192.168.67.201/.well-known/openid-configuration | jq .
```

关键端点：

| 端点 | 作用 |
|---|---|
| `/.well-known/openid-configuration` | 发现文档 |
| `/oauth/authorize` | 浏览器登录入口 |
| `/oauth/token` | 后端 code 换 token |
| `/oauth/userinfo` | 读取用户信息 |
| `/oauth/discovery/keys` | 校验 ID Token 签名的公钥 |

### 3. Authorization Code + PKCE

本平台全部使用 **Authorization Code Flow + PKCE（S256）**：

```text
1. 浏览器访问 Grafana/ArgoCD/oauth2-proxy
2. 应用 302 到 GitLab /oauth/authorize
   ?client_id=...&redirect_uri=...&scope=openid profile email
   &state=随机值&nonce=随机值&code_challenge=...
3. 用户在 GitLab 登录（可带 MFA）
4. GitLab 302 回应用回调地址，带 code
5. 应用后端 POST /oauth/token：
   grant_type=authorization_code
   code=...
   code_verifier=...
   client_id=...
   client_secret=...
6. GitLab 返回 id_token + access_token
7. 应用校验签名、issuer、audience、nonce，读取 email/groups
8. 应用建立自己的会话
```

关键参数：

| 参数 | 作用 | 常见错误 |
|---|---|---|
| `client_id` | 应用标识 | 写错 → `invalid_client` |
| `client_secret` | 应用密码 | 写错/没解析 → `invalid_client` |
| `redirect_uri` | 回调地址 | 与 GitLab 不一致 → `redirect_uri_mismatch` |
| `scope` | 请求的 claim | **Grafana/ArgoCD 用空格；Harbor 用逗号** |
| `state` | 防 CSRF | cookie 丢失 → `data length is less than nonce size` |
| `nonce` | 防重放 | 同上 |
| `code_challenge` | PKCE，防 code 拦截 | 未启用会有安全告警 |

### 4. ID Token 常见 claim

| claim | 含义 | 本平台用途 |
|---|---|---|
| `sub` | 用户唯一 ID | 用户主键 |
| `email` | 邮箱 | ArgoCD 兜底管理员 |
| `preferred_username` | 用户名 | Grafana/Harbor 登录名 |
| `nickname` | 昵称/用户名 | Grafana root 判断 |
| `groups` | 用户组 | Grafana/ArgoCD/Harbor 角色映射 |
| `iss` | 签发者 | 必须等于 issuer |
| `aud` | 受众 | 必须包含 client_id |

### 5. 四种接入方式

| 方式 | 认证在哪 | 应用知道用户吗 | 适用 |
|---|---|---|---|
| **basicAuth** | Traefik | ❌ | 临时保护 Dashboard |
| **ForwardAuth** | 外部认证服务 | 部分（通过 header） | 应用能接受 `X-Auth-Request-*` |
| **反向代理** | oauth2-proxy | ✅ | 应用无登录体系，最通用 |
| **原生 OIDC** | 应用自己 | ✅ | Grafana/ArgoCD/Harbor |
| **SAML** | IdP + 应用 | ✅ | Ceph Quincy/Reef Dashboard |

本平台最终选择：

```text
原生 OIDC：Grafana、ArgoCD、Harbor
反向代理：Traefik、Hubble、Alloy、Tekton（oauth2-proxy）
SAML：Ceph（当前缺 SAML IdP，暂缓）
```

### 6. oauth2-proxy 的两种模式

- **ForwardAuth**：Traefik 先把请求发到 oauth2-proxy `/oauth2/auth`，通过后再转发给后端；
- **反向代理**：Traefik 把整个 host 直接转给 oauth2-proxy，oauth2-proxy 登录后代理到 upstream。

本平台最初试了 ForwardAuth，但 oauth2-proxy 未登录时返回 **401 + Location**，
浏览器不会自动跟随 401 的 Location，页面停在错误页。
最终改成**反向代理**：

```text
浏览器 -> Traefik -> oauth2-proxy-<host> -> 后端 UI
                         └── GitLab OIDC
```

### 7. Cookie 与 State

OIDC 依赖浏览器 cookie 保存 `state`/`nonce`：

- `--cookie-secure=true`：只通过 HTTPS 发送；
- `--cookie-samesite=lax`：兼顾跳转和 CSRF；
- `--cookie-expire=24h`：会话有效期；
- cookie secret 必须是 **16/24/32 字节**，本平台统一用 `openssl rand -hex 16`（32 字符）。

### 8. SealedSecret 与 GitOps

所有 client secret / cookie secret 都通过 SealedSecret 进入集群：

```text
明文 secret → kubeseal 用集群公钥加密 → SealedSecret 提交 Git
                                    → controller 用私钥解密 → Secret
```

注意：

- SealedSecret 与 **namespace/name** 绑定，改名/换 namespace 需要重新加密；
- 私钥在集群 `kube-system/sealed-secrets-key*`，**必须离线备份**；
- 私钥丢失后，Git 里的 SealedSecret 全部无法解密。

## 当天完成的变更

| 系统 | 结果 | 协议/方式 | 配置位置 |
|---|---|---|---|
| GitLab | ✅ 修复 + 作为 IdP | OIDC Provider | GitLab 自身 |
| Grafana 12.4.3 | ✅ | 原生 OIDC | `platform/monitoring/values.yaml` + SealedSecret |
| ArgoCD 3.5.3 | ✅ | 原生 OIDC + PKCE | `platform/argocd/values.yaml`（Helm bootstrap） |
| Harbor 2.14.5 | ✅ | 原生 OIDC | Harbor DB（API 写入） |
| Traefik | ✅ | oauth2-proxy 反向代理 | `platform/sso/oauth2-proxy` + `platform/ui` |
| Hubble | ✅ | oauth2-proxy 反向代理 | 同上 |
| Alloy | ✅ | oauth2-proxy 反向代理 | 同上 |
| Tekton | ✅ | oauth2-proxy 反向代理 | 同上 |
| Ceph 18.2.8 Reef | ⛔ 阻塞 | SAML 2.0 | 需要 Keycloak 等 SAML IdP |

### 1. 先修 GitLab：磁盘 100% + 196 条迁移

第一次创建 OAuth Application 时返回 500：

```text
PG::UndefinedTable: relation "oauth_application_granular_scopes" does not exist
```

排查结果：

| 项 | 值 |
|---|---|
| GitLab | 19.5.0 CE |
| 未执行迁移 | 196 条 |
| 根分区 | 100%（仅剩约 100M） |

处理：

1. 清理 `/root/.npm`、`/root/.cache` 等可再生缓存，给根分区留出空间；
2. 备份 `gitlab.rb`、`gitlab-secrets.json`，并做 GitLab backup（约 725M）；
3. 执行：

   ```bash
   gitlab-rake db:migrate
   gitlab-rake db:migrate:status | grep '  down '
   ```

4. 确认 `oauth_application_granular_scopes` 表存在，GitLab Web/API 恢复；
5. 再创建 OAuth Application。

> 这一步很关键：IdP 自己数据库没迁移完，后面所有 OIDC 都会失败。

### 2. GitLab OAuth Application

当天一共创建了 7 个 Application（client ID 不是秘密，secret 只返回一次）：

| 应用 | redirect URI | scopes |
|---|---|---|
| `grafana` | `https://grafana.k8s.local/login/generic_oauth` | `openid profile email` |
| `argocd` | `https://argocd.devops.com/auth/callback` | `openid profile email` |
| `harbor` | `https://192.168.67.202:8443/c/oidc/callback` | `openid profile email` |
| `oauth2-hubble` | `https://hubble.xyz/oauth2/callback` | `openid profile email` |
| `oauth2-alloy` | `https://alloy.xyz/oauth2/callback` | `openid profile email` |
| `oauth2-tekton` | `https://tekton.xyz/oauth2/callback` | `openid profile email` |
| `oauth2-traefik` | `https://traefik.xyz/oauth2/callback` | `openid profile email` |

创建后 secret 只显示一次，立即 seal 成 SealedSecret，不落 Git。

### 3. Grafana：原生 OIDC

`platform/monitoring/values.yaml` 关键段：

```yaml
grafana:
  envValueFrom:
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
      secretKeyRef:
        name: grafana-oauth
        key: client-secret
  grafana.ini:
    users:
      auto_assign_org_role: Viewer
    auth:
      disable_login_form: false          # 保留 break-glass
    auth.generic_oauth:
      enabled: true
      name: GitLab
      allow_sign_up: true
      client_id: '<GITLAB_APPLICATION_ID>'
      scopes: openid profile email        # 空格分隔
      auth_url: http://192.168.67.201/oauth/authorize
      token_url: http://192.168.67.201/oauth/token
      api_url: http://192.168.67.201/oauth/userinfo
      login_attribute_path: preferred_username
      name_attribute_path: name
      email_attribute_path: email
      use_pkce: true
      use_refresh_token: true
      role_attribute_path: "contains(['root'], nickname) && 'GrafanaAdmin' || contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' || 'Viewer'"
      role_attribute_strict: false
      allow_assign_grafana_admin: true
```

并新增 `platform/monitoring/stack/sealedsecret-grafana-oauth.yaml`，
**必须把它加进同目录 `kustomization.yaml` 的 `resources`**。

### 4. ArgoCD：原生 OIDC + RBAC

ArgoCD 是 bootstrap 组件，由 Helm 安装，不能自己同步自己，所以配置写在
`platform/argocd/values.yaml`，通过 `helm upgrade` 应用：

```yaml
configs:
  cm:
    url: https://argocd.devops.com
    oidc.config: |
      name: GitLab
      issuer: http://192.168.67.201
      clientID: <GITLAB_APPLICATION_ID>
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

应用：

```bash
kubectl apply -f platform/argocd/sealedsecret-argocd-oauth.yaml

helm -n argocd upgrade argocd argo/argo-cd \
  --version 10.9.6 \
  -f platform/argocd/values.yaml \
  --reuse-values --wait --timeout 4m
```

### 5. Harbor：原生 OIDC

Harbor 不在 K8s 里，配置存在自己的数据库，不能 GitOps。流程：

1. 先备份 `/api/v2.0/configurations`；
2. 写入 OIDC 字段（此时仍是 `db_auth`）；
3. 单独一步切 `auth_mode=oidc_auth`；
4. 验证本地 admin API 仍可用，OIDC 登录 302 到 GitLab。

关键点：

- 回调 URI 必须完全一致；
- Harbor 的 `oidc_scope` 用**逗号**：`openid,profile,email`；
- 保留本地 admin 作为 break-glass；
- 回滚只需把 `auth_mode` 改回 `db_auth`。

### 6. Traefik / Hubble / Alloy / Tekton：oauth2-proxy 反向代理

部署 4 个独立实例，每个 host 一个 GitLab OAuth Application：

| host | oauth2-proxy | upstream |
|---|---|---|
| `traefik.xyz` | `oauth2-proxy-traefik` | `traefik-api.traefik.svc:9000` |
| `hubble.xyz` | `oauth2-proxy-hubble` | `hubble-ui.kube-system.svc:80` |
| `alloy.xyz` | `oauth2-proxy-alloy` | `alloy.logging.svc:12345` |
| `tekton.xyz` | `oauth2-proxy-tekton` | `tekton-dashboard.tekton-pipelines.svc:9097` |

为什么是 4 个实例而不是 1 个：

- `*.xyz` 是公共后缀，`hubble.xyz` / `alloy.xyz` / `tekton.xyz` / `traefik.xyz`
  之间没有共享父域，cookie 无法跨域；
- 每个实例有独立的 OAuth Application、回调地址和 cookie secret；
- 单实例做多 host 会把 cookie/回调/密钥耦合在一起。

关键参数：

```text
--provider=oidc
--oidc-issuer-url=http://192.168.67.201
--scope=openid profile email
--code-challenge-method=S256
--oidc-groups-claim=groups
--redirect-url=https://<host>/oauth2/callback
--cookie-secure=true
--cookie-samesite=lax
--reverse-proxy=true
--skip-provider-button=true
--upstream=<后端 Service>
```

Traefik 需要：

```yaml
providers:
  kubernetesCRD:
    allowCrossNamespace: true   # platform/ui 跨 namespace 引用 oauth2-proxy Service
```

`traefik.xyz` 的后端是 Traefik API `:9000`，需要：

- `--api=true` + `--api.insecure=true`（`traefik-api` 是 ClusterIP，仅集群内可达）；
- 把 `/` 重定向到 `/dashboard/`，因为 API 根路径本身 404。

### 7. Ceph：为什么没接

实际集群是 **Ceph 18.2.8 Reef**。Ceph Dashboard 的 SSO 支持情况：

| 版本 | Dashboard SSO |
|---|---|
| Quincy 17.2 | SAML 2.0 |
| Reef 18.2 | SAML 2.0 |
| Tentacle+ | SAML 2.0 + OAuth2/OIDC（mgmt-gateway + oauth2-proxy） |

GitLab 是 OIDC/SAML 的 **SP**，不是 SAML IdP，所以不能直接给 Ceph 做 SAML 登录。
要收编 Ceph，至少需要：

1. 部署 Keycloak 之类 SAML IdP；
2. Ceph mgr 安装 `python3-saml`；
3. mgr 能解析 IdP 域名；
4. 有 `client.admin` keyring。

当前环境缺 Keycloak、缺 Ceph admin keyring，所以本轮只记录阻塞原因，不做强改。

## 架构

```text
                    ┌── Grafana      (原生 OIDC)
                    ├── ArgoCD       (原生 OIDC + PKCE)
浏览器 ──> GitLab ──┼── Harbor       (原生 OIDC)
          (IdP)     │
                    └── oauth2-proxy ──┬── traefik.xyz
                                       ├── hubble.xyz
                                       ├── alloy.xyz
                                       └── tekton.xyz
                                              │
                                              └── 后端 UI

Ceph Dashboard ──> 需要 SAML IdP（Keycloak），当前未接入
```

## 踩坑点

### 坑 1：GitLab 磁盘 100% + 迁移未跑，OAuth API 直接 500

现象是 `POST /api/v4/applications` 500，错误里是 `oauth_application_granular_scopes` 表不存在。
根因不是 OIDC 配置，而是 GitLab 升级后 **196 条迁移没执行**，且根分区已满。

**修复**：清缓存 → 备份 → `gitlab-rake db:migrate` → 确认 `down` 为 0 → 再创建 Application。

### 坑 2：scopes 分隔符各系统不同

- Grafana / ArgoCD / oauth2-proxy：`openid profile email`（空格）；
- Harbor：`openid,profile,email`（逗号）。

写成逗号给 Grafana，会被当成一个 scope，报
`scopes doesn't match those configured on the server`。

### 坑 3：SealedSecret 没加进 kustomization

只提交 `sealedsecret-grafana-oauth.yaml`，没加到 `kustomization.yaml` 的 `resources`，
ArgoCD 不会下发，Deployment 一直等 Secret，出现“Deployment 等 Secret、Secret 等同步”的死锁。

### 坑 4：ArgoCD 的 `$secret:key` 只认带标签的 Secret

`clientSecret: $argocd-oauth:client-secret` 只会从带
`app.kubernetes.io/part-of: argocd` 标签的 Secret 解析。
缺标签时 ArgoCD 把整个字符串当密码发给 GitLab，报：

```text
failed to get token: oauth2: "invalid_client"
```

日志同时出现：

```text
level=warning msg="secret key does not exist in secret"
```

**修复**：在 SealedSecret 的 `template.metadata.labels` 加：

```yaml
labels:
  app.kubernetes.io/part-of: argocd
```

### 坑 5：`invalid_client` 和 `invalid_grant` 要分清

直接用集群里的 Secret 调 token 端点：

```bash
SEC=$(kubectl -n argocd get secret argocd-oauth -o jsonpath='{.data.client-secret}' | base64 -d)
curl -s -X POST http://192.168.67.201/oauth/token \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode code=dummy \
  --data-urlencode redirect_uri=https://argocd.devops.com/auth/callback \
  --data-urlencode client_id=<CLIENT_ID> \
  --data-urlencode client_secret="$SEC"
```

- 返回 `invalid_grant`：client_id/secret 正确，只是 code 是假的；
- 返回 `invalid_client`：client_id/secret/标签有问题。

### 坑 6：`data length is less than nonce size`

这是 ArgoCD OIDC **state cookie** 的问题，不是 secret 错误：

- 升级后浏览器残留旧的 `argocd.oauthstate` / `argocd.token`；
- 深链接/iframe 下 cookie 路径不匹配。

**修复**：清 `argocd.devops.com` 的 cookie，直接打开
`https://argocd.devops.com/login?return_url=https%3A%2F%2Fargocd.devops.com%2Fapplications`
重新登录。

### 坑 7：ForwardAuth 的 401 + Location 不会自动跳转

oauth2-proxy 的 `/oauth2/auth` 未登录时返回 **401 + Location**。
Traefik ForwardAuth 只把它当“未通过”，浏览器不会自动跟随 401 的 Location，
页面停在 401/错误页。

**修复**：改成**反向代理模式**，Traefik 把整个 host 转给 oauth2-proxy，
由 oauth2-proxy 自己 302 到 GitLab。

### 坑 8：cookie secret 长度不对

oauth2-proxy 要求 16/24/32 字节。用：

```bash
openssl rand -hex 16    # 32 个字符，对应 16 字节
```

报错：

```text
cookie_secret must be 16, 24, or 32 bytes
```

### 坑 9：跨 namespace 引用 Service/Middleware 被拒

`platform/ui` 里的 IngressRoute 在 `logging`/`kube-system`/`tekton-pipelines`/`traefik`
命名空间，却要引用 `oauth2-proxy` 命名空间的 Service。

**修复**：Traefik 开：

```yaml
providers:
  kubernetesCRD:
    allowCrossNamespace: true
```

### 坑 10：Traefik API 根路径 404

`traefik.xyz` 的 upstream 是 Traefik API `:9000`，根路径 `/` 本身返回 404。
**修复**：

- `--api=true` + `--api.insecure=true`；
- 用 `redirectRegex` 把 `/` 重定向到 `/dashboard/`；
- 新建稳定的 `traefik-api` ClusterIP Service 指向 9000。

### 坑 11：`.xyz` 域名可能解析到公网

`hubble.xyz`、`alloy.xyz`、`tekton.xyz`、`traefik.xyz` 在公网 DNS 上可能指向别人的站点。
浏览器必须通过本机 hosts 或内部 DNS 指向 Traefik VIP `10.0.0.252`，
否则会访问到公网同名站点。

### 坑 12：GitLab 是 HTTP，issuer 没有 TLS

当前 issuer 是 `http://192.168.67.201`：

- ArgoCD/oauth2-proxy 允许 HTTP issuer，但 token/secret 在内网明文传输；
- 浏览器地址栏没有锁；
- 生产必须给 GitLab 上 TLS，再改 issuer/回调地址。

### 坑 13：Ceph 不是 OIDC 应用

Ceph Dashboard 不是“配置一下 OIDC”就能接：
Quincy/Reef 只支持 SAML 2.0，GitLab 不是 SAML IdP。
必须先有 Keycloak/ADFS 之类 SAML IdP。

### 坑 14：oauth2-proxy 临时固定 worker02

镜像首次拉取慢，4 个实例临时 `nodeSelector: worker02`。
所有 worker 缓存镜像后应移除，否则 worker02 故障会同时打掉 4 个 UI 登录入口。

### 坑 15：不要关掉本地 admin

任何 SSO 改造都必须保留 break-glass：

- Grafana：`disable_login_form: false`；
- ArgoCD：`admin.enabled: true`；
- Harbor：本地 admin 仍可 API 登录；
- basicAuth Middleware/Secret 保留，回滚时直接挂回。

### 坑 16：SealedSecret 私钥没有离线备份

私钥只在集群 `kube-system/sealed-secrets-key*`，集群重建/etcd 丢失后
Git 里的 SealedSecret 全部解不开。必须：

```bash
umask 077
kubectl -n kube-system get secret <sealed-secrets-key> -o yaml \
  > sealed-secrets-key-$(date +%Y%m%d).yaml
chmod 600 sealed-secrets-key-*.yaml
```

离线保存，不进 Git。

## 修复关键 / 操作手册

### 新增一个原生 OIDC 应用

以 `foo` 为例：

1. GitLab 创建 OAuth Application：
   - redirect URI：`https://foo.example.com/auth/callback`（以应用文档为准）
   - scopes：`openid profile email`
2. 把 client secret 做成 SealedSecret：

   ```bash
   kubectl -n <ns> create secret generic foo-oauth \
       --dry-run=client -o yaml \
       --from-literal=client-secret='<SECRET>' \
   | kubeseal --namespace <ns> --name foo-oauth \
       --controller-name sealed-secrets-controller \
       --controller-namespace kube-system \
       --format yaml \
   > platform/<app>/sealedsecret-foo-oauth.yaml
   ```

3. 在应用配置里填 issuer / client_id / client_secret / redirect_uri / scopes；
4. 配置组/角色映射；
5. 验证跳转、回调、claim、角色。

### 新增一个 oauth2-proxy 保护的 UI

1. GitLab 创建 Application，回调 `https://foo.xyz/oauth2/callback`；
2. 生成 client secret + cookie secret；
3. 创建 `oauth2-proxy/oauth2-foo` SealedSecret；
4. 在 `platform/sso/oauth2-proxy/values.yaml` 的 `instances` 增加：

   ```yaml
   - name: foo
     host: foo.xyz
     clientID: <client_id>
     secretName: oauth2-foo
     upstream: http://foo.default.svc.cluster.local:8080
   ```

5. 把 `foo.xyz` 的 IngressRoute 指向 `oauth2-proxy-foo:4180`；
6. 提交、同步、验证。

### 验证命令

```bash
# 1. OIDC discovery
curl -s http://192.168.67.201/.well-known/openid-configuration | jq .

# 2. 四个 oauth2-proxy UI 都应 302 到 GitLab
for h in hubble alloy tekton; do
  curl -sk --resolve $h.xyz:443:10.0.0.252 \
    -o /dev/null -w "$h %{http_code} %{redirect_url}\n" https://$h.xyz/
done

# traefik.xyz 根路径先跳 /dashboard/，再跳 GitLab
curl -sk --resolve traefik.xyz:443:10.0.0.252 \
  -o /dev/null -w "%{http_code} %{redirect_url}\n" https://traefik.xyz/dashboard/

# 3. ArgoCD 应 303 到 GitLab
curl -sk --resolve argocd.devops.com:443:10.0.0.252 \
  -o /dev/null -w "%{http_code} %{redirect_url}\n" https://argocd.devops.com/auth/login

# 4. Grafana 登录页应出现 GitLab
curl -sk --resolve grafana.k8s.local:443:10.0.0.252 \
  https://grafana.k8s.local/login | grep -o GitLab | head -1

# 5. Harbor 登录应 302 到 GitLab
curl -sk -o /dev/null -w "%{http_code} %{redirect_url}\n" \
  https://192.168.67.202:8443/c/oidc/login
```

### 轮换 secret

- **GitLab OAuth secret**：GitLab 删除重建 Application（或 renew）→ 重新 seal → apply →
  `rollout restart` 对应应用；
- **oauth2-proxy cookie secret**：`openssl rand -hex 16` → 重新 seal → restart →
  用户重新登录；
- **ArgoCD secret**：重新 seal 时保留 `app.kubernetes.io/part-of: argocd` 标签；
- 轮换后用 token 端点验证 `invalid_grant`（而不是 `invalid_client`）。

### 回滚

| 系统 | 回滚 |
|---|---|
| Grafana | `auth.generic_oauth.enabled=false`，提交同步 |
| ArgoCD | 从 values 移除 `oidc.config`，`helm upgrade`，保留本地 admin |
| Harbor | `auth_mode=db_auth` |
| oauth2-proxy UI | IngressRoute 改回原 UI + basicAuth middleware |
| Ceph | 未改，无需回滚 |

### 安全清单

- [ ] GitLab 上 TLS，issuer/回调改 HTTPS
- [ ] Traefik 使用可信证书（当前默认自签）
- [ ] Sealed Secrets 私钥离线备份
- [ ] client secret / cookie secret 不进 Git
- [ ] 保留本地 admin / basicAuth 作为 break-glass
- [ ] 设置 `--trusted-proxy-ip`（当前未设置，信任所有 `X-Forwarded-*`）
- [ ] GitLab 开启 MFA
- [ ] 定期轮换 secret
- [ ] 监控 oauth2-proxy `/ping` 与登录失败日志
- [ ] ArgoCD 默认 `role:readonly`，管理员按组/邮箱提升

## 当前状态（2026-11-10 实测）

| 检查项 | 结果 |
|---|---|
| GitLab | 19.5.0 CE，OIDC discovery 200，issuer `http://192.168.67.201` |
| GitLab OAuth Applications | 7 个（Grafana/ArgoCD/Harbor/4 个 oauth2-proxy） |
| Grafana | `https://grafana.k8s.local/login` 返回 200，页面含 GitLab |
| ArgoCD | `/auth/login` 返回 303，跳 GitLab `/oauth/authorize`，带 PKCE |
| Harbor | `auth_mode=oidc_auth`，`oidc_provider_name=GitLab`，`/c/oidc/login` 302 |
| Hubble | 302 到 GitLab，带 PKCE |
| Alloy | 302 到 GitLab，带 PKCE |
| Tekton | 302 到 GitLab，带 PKCE |
| Traefik | `/dashboard/` 302 到 GitLab，带 PKCE |
| oauth2-proxy | 4 个 Deployment 1/1 Running，v7.15.6 |
| Ceph | 18.2.8 Reef，Dashboard 仍为本地账号；OIDC 不可用，需 SAML IdP |

## 本目录文档

| 文档 | 内容 |
|---|---|
| [01-sso-overview.md](notes/01-sso-overview.md) | 平台 SSO 总体方案、分阶段落地、风险与回滚 |
| [02-sso-ops-tutorial.md](notes/02-sso-ops-tutorial.md) | SSO 基础概念 + 运维手册（新增应用、轮换、排错表） |
| [03-phase2-argocd-harbor-ceph.md](notes/03-phase2-argocd-harbor-ceph.md) | ArgoCD/Harbor 接入过程、Ceph 阻塞分析、oauth2-proxy 反向代理 |
| [04-keycloak-basicauth-forwardauth.md](notes/04-keycloak-basicauth-forwardauth.md) | Keycloak、basicAuth、ForwardAuth、oauth2-proxy 的区别 |
| [05-grafana-sso.md](notes/05-grafana-sso.md) | Grafana 三种 SSO 方案与完整命令 |
| [06-argocd-helm-bootstrap.md](notes/06-argocd-helm-bootstrap.md) | ArgoCD Helm bootstrap、OIDC/RBAC 与关键坑 |
| [07-sealed-secrets.md](notes/07-sealed-secrets.md) | Sealed Secrets 方案与迁移记录（含历史备份路径说明） |
| [00-notes-index.md](notes/00-notes-index.md) | 原始文档索引与版本勘误 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/oauth2-proxy/values.yaml](assets/oauth2-proxy/values.yaml) | 4 个 oauth2-proxy 实例、host、clientID、upstream |
| [assets/oauth2-proxy/deployment.yaml](assets/oauth2-proxy/deployment.yaml) | Helm 模板：oauth2-proxy Deployment |
| [assets/oauth2-proxy/ingressroutes.yaml](assets/oauth2-proxy/ingressroutes.yaml) | `/oauth2/*` 回调路由模板 |
| [assets/oauth2-proxy/service.yaml](assets/oauth2-proxy/service.yaml) | 每个实例的 ClusterIP Service |
| [assets/oauth2-proxy/argocd-application.yaml](assets/oauth2-proxy/argocd-application.yaml) | ArgoCD Application（sync-wave 20） |
| [assets/argocd-values.yaml](assets/argocd-values.yaml) | ArgoCD OIDC + RBAC values |
| [assets/monitoring-values.yaml](assets/monitoring-values.yaml) | Grafana OIDC values |
| [assets/ui/](assets/ui/) | Traefik/Hubble/Alloy/Tekton 的 IngressRoute |
| [scripts/gitlab-create-oauth-app.sh](scripts/gitlab-create-oauth-app.sh) | 创建 GitLab OAuth Application 并生成 SealedSecret（secret 不打印） |
| [scripts/verify_sso.sh](scripts/verify_sso.sh) | 一键验证 discovery、4 个 UI、ArgoCD、Grafana、Harbor |

> 所有 client secret / cookie secret 都在 SealedSecret 中，本仓库不复制密文。
> 示例中的 client ID 不是秘密；secret 已脱敏。
