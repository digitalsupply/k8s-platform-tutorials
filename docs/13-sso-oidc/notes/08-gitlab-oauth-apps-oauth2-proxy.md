# GitLab 实例 OAuth 应用管理 · OIDC 用户归属 · oauth2-proxy 形态（实测）

> 面向：需要管理 GitLab Admin 区 OAuth 应用、排查 OIDC 登录身份、维护 oauth2-proxy 反代的人  
> 环境：GitLab CE **19.5.0**（`192.168.67.201`），集群内 oauth2-proxy **v7.15.6**  
> 性质：对 [13 章 README](../README.md) 的补充与实测校正。  
> 原文（2026-11-10）记录的是改造当天的状态；2026-11-18 复核集群；**2026-11-24 通过 `gitlab-rails runner` 再次验证 Doorkeeper 应用/Token/用户归属**。

---

## 1. GitLab Admin 区：Instance OAuth applications

管理入口：**Admin Area → Applications → Instance OAuth applications**
（页面描述：管理本实例上可使用 GitLab 作为 OAuth provider 的应用）。

### 1.1 页面列与数据库字段对应

| 页面列 | 数据库字段（`oauth_applications` 表） | 含义 |
|---|---|---|
| Name | `name` | 应用名（仅命名，无技术含义，见 1.2） |
| Callback URL | `redirect_uri` | 授权回调地址，必须与消费端精确一致 |
| Trusted | `trusted` | 是否受信任客户端（跳过部分安全校验） |
| Confidential | `confidential` | 是否机密客户端（可安全保管 client_secret） |
| Device authorization grant | `device_code_enabled` | 是否允许设备授权码流程（RFC 8628） |

页面渲染逻辑来自 GitLab 源码：
`app/views/admin/applications/index.html.haml`
（`trusted? ? 'Yes' : 'No'`、`confidential? ? 'Yes' : 'No'`、
`device_code_enabled? ? 'Yes' : 'No'`）。

### 1.2 `oauth2-` 前缀只是命名，没有技术含义

2026-11-24 通过 `gitlab-rails runner` 实测，当前实例共有 **9 个** OAuth 应用（`Doorkeeper::Application`）：5 个带 `oauth2-` 前缀（headlamp/traefik/tekton/alloy/hubble），4 个不带（grafana/argocd/harbor/keycloak）。**前缀是创建者起的名字，GitLab 不解析、不区分、不据此做任何处理**。

| id | name | client_id (uid) | redirect_uri | confidential | trusted | scopes | device_code_enabled |
|---:|---|---|---|---:|---:|---|---:|
| 1 | grafana | `78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228` | `https://grafana.k8s.local/login/generic_oauth` | true | false | `openid profile email` | false |
| 2 | argocd | `7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe` | `https://argocd.devops.com/auth/callback` | true | false | `openid profile email` | false |
| 3 | harbor | `c7924430a6d02f5e14da2251233eb98c7a880ece868c96758da91ebd7c1ae502` | `https://192.168.67.202:8443/c/oidc/callback` | true | false | `openid profile email` | false |
| 4 | oauth2-hubble | `9876a0d08f77da5f2f4313eff0567c5a929f1808c7f7e201bdd8e70d9e07f2f0` | `https://hubble.xyz/oauth2/callback` | true | false | `openid profile email` | false |
| 5 | oauth2-alloy | `20fc4475cbbe2899f7708a5c1dc66e769901cae806d8fd4112f70c6a559c7a68` | `https://alloy.xyz/oauth2/callback` | true | false | `openid profile email` | false |
| 6 | oauth2-tekton | `89b4d5ace9b9478f5b6de2a426039aa5b542ded7eb1d78c9cfe59de33cf8dc6f` | `https://tekton.xyz/oauth2/callback` | true | false | `openid profile email` | false |
| 7 | oauth2-traefik | `65d70294ac5fe9e81ee1702a60dc3f6290cf2af3920f7a941ccf05d220ca9a91` | `https://traefik.xyz/oauth2/callback` | true | false | `openid profile email` | false |
| 12 | oauth2-headlamp | `0217d40851fad8c6fa09f1ff3464d5fae1531b93802f6a56501bd24644f5b4cc` | `https://headlamp.devops.com/oauth2/callback` | true | false | `openid profile email` | true |
| 18 | keycloak | `ead09e964d457039a35cdba98e67dd8cd853cc84489050594fc9ffbbb940ba96` | `http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint` | true | false | `openid profile email` | true |

实测观察：

- **统一字段**：9 个应用均为 `confidential=true`、`trusted=false`、`scopes=openid profile email`、`owner_id=nil`（创建时未记录归属用户）。
- **差异字段**：仅 `oauth2-headlamp`（id 12）和 `keycloak`（id 18）的 `device_code_enabled=true`，其余为 `false`。
- **回调地址由消费端决定**：Grafana 用 `/login/generic_oauth`，ArgoCD 用 `/auth/callback`，Harbor 用 `/c/oidc/callback`，oauth2-proxy 实例用 `/oauth2/callback`，Keycloak broker 用 `/realms/ceph-sso/broker/gitlab/endpoint`。与应用名无关。

### 1.3 三个布尔列的选型含义

- **Trusted = No**：所有应用都走标准安全校验，没有放宽特权，正确做法。
- **Confidential = Yes**：客户端能安全保管 client_secret，走标准授权码流程。
- **Device authorization grant**：开启后，**没有浏览器、无法接收回调的设备**（CLI、终端工具）
  可以走"设备码"流程：设备上显示一个码，用户在另一台有浏览器的设备上输入该码完成授权，
  全程不依赖回调地址跳转。`oauth2-headlamp` 是唯一开启的——Headlamp 存在需要设备码
  流程的登录场景。该开关与命名前缀无关，是功能选择。

> 补充：带 `oauth2-` 前缀的应用回调都是 `https://<host>/oauth2/callback`，而不带前缀的
> 分别是 `/login/generic_oauth`（Grafana）、`/auth/callback`（ArgoCD）、`/c/oidc/callback`（Harbor）。
> **回调路径是各消费端自己定义的**，创建应用时填进 `redirect_uri` 即可，与应用叫什么名字无关。

---

## 2. OIDC 引用的 GitLab 用户：实际是 **root**

### 2.1 机制：应用不绑定用户，授权时谁登录即谁

OAuth/OIDC 应用只是"客户端注册"，**不绑定任何用户**。在授权那一步，
哪个 GitLab 账号登录并点击 Authorize，id_token 里的身份（`sub` / `preferred_username` /
`email` / `groups`）就是谁。理论上 root、GitLabDuo 以及任何能登录的账号都能完成授权，
**二者均可**。

### 2.2 实测证据：本集群实际主要用的是 root

2026-11-24 在 GitLab 主机（`ubuntu01`）执行 `gitlab-rails runner` 验证：

```bash
gitlab-rails runner 'puts Doorkeeper::AccessToken.pluck(:resource_owner_id).inspect'
# 输出：[1, 1, 1, ..., nil, 1, ..., 1]（共 83 个 token，82 个为 1，1 个为 nil）

gitlab-rails runner 'puts User.pluck(:id,:username,:admin).inspect'
# 输出：[[2, "GitLabDuo", false], [4, "group_8_bot_d1d3ff08189686931e3bae8fa3ed52a7", false], [3, "group_2_bot_35e9209087a1fe4fbd59b1682cceb642", false], [1, "root", true]]

gitlab-rails runner 'puts Doorkeeper::Application.pluck(:id,:name,:uid,:owner_id).inspect'
# 输出：9 个应用，owner_id 均为 nil（见 1.2）
```

结论：

- 83 个已签发 access token 中，**82 个 `resource_owner_id=1`（root）**，**1 个为 `nil`**。
- 没有任何 token 归属 `GitLabDuo` 或 bot 用户。
- `nil` 表示该 token 无关联资源所有者（常见于 client credentials 等非用户授权场景），需结合 token/application 类型单独确认；不影响“用户 OIDC 登录主要由 root 完成”的结论。

### 2.3 验证命令

```bash
# 查看用户列表（id 1 = root）
gitlab-rails runner 'puts User.pluck(:id,:username,:admin).inspect'

# 查看 OAuth 应用（name / client_id(uid) / 归属 owner_id）
gitlab-rails runner 'puts Doorkeeper::Application.pluck(:id,:name,:uid,:owner_id).inspect'

# 查看已签发 token 的归属用户
gitlab-rails runner 'puts Doorkeeper::AccessToken.pluck(:resource_owner_id).inspect'
```

---

## 3. 三端原生 OIDC 配置（集群实测，纯配置、不改代码）

GitLab 是标准 OAuth2/OIDC 提供方（授权码 + PKCE + id_token/userinfo）。
原生支持 OIDC 的应用只需声明"提供方是谁、端点在哪、客户端凭据"，**不碰任何代码**。

### 3.1 Grafana：纯 ConfigMap

Grafana 12.4.3，配置在 `monitoring` 命名空间 `prometheus-grafana` ConfigMap 的
`grafana.ini` 的 `[auth.generic_oauth]`：

```ini
[auth.generic_oauth]
enabled = true
name = GitLab
client_id = 78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228
api_url = http://192.168.67.201/oauth/userinfo
auth_url = http://192.168.67.201/oauth/authorize
token_url = http://192.168.67.201/oauth/token
scopes = openid profile email
email_attribute_path = email
login_attribute_path = preferred_username
name_attribute_path = name
role_attribute_path = contains(['root'], nickname) && 'GrafanaAdmin' || contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' || 'Viewer'
role_attribute_strict = false
allow_sign_up = true
allow_assign_grafana_admin = true
use_pkce = true
use_refresh_token = true
```

**登录页 "GitLab" 按钮的机制（重要）**：不是改了前端代码。Grafana 登录页是标准 SPA，
前端不写死按钮，启动后向后端查询"已启用哪些认证方式"，后端根据 grafana.ini 的 auth 配置
返回 provider 列表，前端**动态渲染按钮**。`name = GitLab` 直接变成按钮文字。
改这份 ConfigMap 后 Grafana 重载配置即可生效。

### 3.2 ArgoCD：纯 ConfigMap（+Secret）

ArgoCD 3.5.3，配置在 `argocd` 命名空间 `argocd-cm` 的 `oidc.config`：

```yaml
name: GitLab
issuer: http://192.168.67.201
clientID: 7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe
clientSecret: $argocd-oauth:client-secret   # 存于 secret argocd-oauth
requestedScopes: ["openid", "profile", "email"]
requestedIDTokenClaims:
  groups:
    essential: true          # ArgoCD RBAC 依赖 groups 声明
enablePKCEAuthentication: true
```

> GitLab 是 HTTP，ArgoCD 允许 http issuer、无 TLS。

### 3.3 Harbor：不在 K8s，配置在 Harbor DB/API

Harbor 是独立主机（`192.168.67.202:8443`）的 docker-compose 部署，OIDC 配置存于
Harbor DB/API，**不适用"改 K8s ConfigMap"**，通过 Harbor UI/API 配置：

```yaml
auth_mode: oidc_auth
oidc_name: GitLab
oidc_endpoint: http://192.168.67.201
oidc_client_id: <GitLab OAuth 应用 harbor 的 client_id>
oidc_scope: openid,profile,email          # Harbor 用逗号分隔
oidc_user_claim: preferred_username
oidc_groups_claim: groups
oidc_auto_onboard: true
oidc_verify_cert: false                    # GitLab 是 HTTP，关闭证书校验
oidc_admin_group: digitalsupply            # 该组成员登录即 Harbor 管理员
```

配置后确认 `systeminfo.auth_mode` 已切换。

**三端共同的成功要点**：

1. **回调地址精确匹配**（协议、域名、端口、路径一字符都不能差）；
2. **HTTP issuer**：GitLab 是 `http://192.168.67.201`，各端必须接受不安全 HTTP；
3. **groups 声明**：ArgoCD 将其设为 essential，Grafana 用 `groups[*]` 判角色，
   Harbor 用它判管理员——这套 RBAC 全靠 GitLab id_token 携带的 `groups`；
4. **Scope 统一 `openid profile email`**。

---

## 4. oauth2-proxy 在 K8s 里的形态（实测）

### 4.1 资源形态：Deployment（Pod）+ Service + Secret，**没有 ConfigMap**

`oauth2-proxy` 命名空间下，每个 Web UI 对应一套，共 **5 套**：

| 资源类型 | 数量 | 名称 | 说明 |
|---|---|---|---|
| **Deployment** | 5 | `oauth2-proxy-headlamp/hubble/tekton/alloy/traefik` | 核心载体，1 副本，无状态 |
| **Pod** | 5 | `oauth2-proxy-*-<随机串>` | 实际进程，1/1 Running |
| **Service** | 5 | 同名 ClusterIP | 端口 **4180**，集群内入口 |
| **Secret** | 5 | `oauth2-headlamp` 等 | Opaque，2 个 key：`client-secret`、`cookie-secret` |
| **ConfigMap** | **0** | — | 无业务 CM（仅自动生成的 kube-root-ca.crt） |

镜像：`quay.io/oauth2-proxy/oauth2-proxy:v7.15.6`。

### 4.2 配置注入：全部写在 Deployment 里，分两处

**启动参数（args）**，写在 Deployment 容器 spec 里（以 headlamp 为例）：

```text
--provider=oidc
--oidc-issuer-url=http://192.168.67.201
--provider-display-name=GitLab
--email-domain=*
--insecure-oidc-allow-unverified-email=true
--scope=openid profile email
--code-challenge-method=S256
--oidc-groups-claim=groups
--redirect-url=https://headlamp.devops.com/oauth2/callback
--cookie-secure=true
--cookie-samesite=lax
--cookie-expire=24h
--reverse-proxy=true
--set-xauthrequest=true
--http-address=0.0.0.0:4180
--upstream=http://headlamp.headlamp.svc.cluster.local:80
```

**环境变量（env）**，三类：

| 变量 | 注入方式 |
|---|---|
| `OAUTH2_PROXY_CLIENT_ID` | **明文直接写在 Deployment 里**（client_id 本身非敏感，实测值即 GitLab `oauth2-headlamp` 应用的 uid） |
| `OAUTH2_PROXY_CLIENT_SECRET` | 从 Secret `oauth2-headlamp` 的 `client-secret` 注入 |
| `OAUTH2_PROXY_COOKIE_SECRET` | 从 Secret `oauth2-headlamp` 的 `cookie-secret` 注入（会话 Cookie 签名密钥） |

**改 oauth2-proxy 配置 = 改 Deployment**（args + env），Secret 只管凭据。

### 4.3 五实例与 Web UI 映射（实测）

| oauth2-proxy 实例 | 上游（--upstream） | GitLab 应用 | 回调地址 |
|---|---|---|---|
| oauth2-proxy-headlamp | `headlamp.headlamp.svc:80` | oauth2-headlamp | `https://headlamp.devops.com/oauth2/callback` |
| oauth2-proxy-hubble | `hubble-ui.kube-system.svc:80` | oauth2-hubble | `https://hubble.xyz/oauth2/callback` |
| oauth2-proxy-tekton | `tekton-dashboard.tekton-pipelines.svc:9097` | oauth2-tekton | `https://tekton.xyz/oauth2/callback` |
| oauth2-proxy-alloy | `alloy.logging.svc:12345` | oauth2-alloy | `https://alloy.xyz/oauth2/callback` |
| oauth2-proxy-traefik | `traefik-api.traefik.svc:9000` | oauth2-traefik | `https://traefik.xyz/oauth2/callback` |

### 4.4 流量链路

```text
浏览器
  → Traefik IngressRoute（oauth2-proxy 命名空间下的 CRD，如 oauth2-headlamp，含 http-redirect 变体）
  → Service（ClusterIP:4180）
  → Pod（oauth2-proxy 进程：登录页、跳 GitLab 授权、回调、透传）
  → --upstream 指向的 Web UI Pod
```

---

## 5. Web UI OIDC 对接全景：原生 vs 反代

对接成败取决于**客户端是否实现标准 OAuth2 授权码流程**，与 Web UI 本身无关：

| Web UI | 是否原生支持 | 本集群落地方式 |
|---|---|---|
| Grafana | ✅ 原生 | ConfigMap（`[auth.generic_oauth]`） |
| ArgoCD | ✅ 原生 | ConfigMap（`oidc.config`） |
| Harbor | ✅ 原生 | Harbor DB/API（`auth_mode=oidc_auth`） |
| Headlamp | ✅ 原生支持 | 本集群走 oauth2-proxy 反代（统一方案） |
| Hubble UI | ❌ 无内置登录 | oauth2-proxy 反向代理 |
| Tekton Dashboard | ❌ 无内置登录 | oauth2-proxy 反向代理 |
| Alloy UI | ❌ 无内置登录 | oauth2-proxy 反向代理 |
| Traefik Dashboard | ❌ 无内置登录 | oauth2-proxy 反向代理 |

**核心原理**：GitLab 是标准 OAuth2/OIDC 提供方，不关心客户端是谁。
原生支持的直接配置；不支持的，在前面放一个标准 OAuth2 反代（oauth2-proxy），
由反代完成登录页、跳转、校验和透传，后端 Web UI 完全不用改。**零代码改动，纯配置。**

---

## 6. GitLab SSO 对接验证（2026-11-24 实测）

### 6.1 GitLab 侧证据

在 GitLab 主机执行：

```bash
gitlab-rails runner 'puts User.pluck(:id,:username,:admin).inspect'
# [[2, "GitLabDuo", false], [4, "group_8_bot_d1d3ff08189686931e3bae8fa3ed52a7", false], [3, "group_2_bot_35e9209087a1fe4fbd59b1682cceb642", false], [1, "root", true]]

gitlab-rails runner 'puts Doorkeeper::Application.pluck(:id,:name,:uid,:owner_id).inspect'
# 9 个应用，owner_id 均为 nil；uid 与集群侧 clientID 一致（见 1.2）

gitlab-rails runner 'puts Doorkeeper::AccessToken.pluck(:resource_owner_id).inspect'
# 83 个 token：82 个为 1(root)，1 个为 nil
```

### 6.2 GitLab 应用到集群消费端映射

| GitLab 应用 | client_id (uid) | 消费端 | 对接方式 | 集群侧配置位置 | 回调地址 |
|---|---|---|---|---|---|
| grafana | `78775c9...` | Grafana | 原生 OIDC (`auth.generic_oauth`) | `monitoring` Helm values / `prometheus-grafana` 配置 | `https://grafana.k8s.local/login/generic_oauth` |
| argocd | `7cde3dbf...` | ArgoCD | 原生 OIDC (`oidc.config`) | `argocd/argocd-cm` + `argocd-oauth` Secret | `https://argocd.devops.com/auth/callback` |
| harbor | `c7924430...` | Harbor | 原生 OIDC (`auth_mode=oidc_auth`) | Harbor 外部主机 DB/API | `https://192.168.67.202:8443/c/oidc/callback` |
| oauth2-hubble | `9876a0d0...` | Hubble UI | oauth2-proxy 反代 | `oauth2-proxy` Deployment/Secret | `https://hubble.xyz/oauth2/callback` |
| oauth2-alloy | `20fc4475...` | Alloy UI | oauth2-proxy 反代 | `oauth2-proxy` Deployment/Secret | `https://alloy.xyz/oauth2/callback` |
| oauth2-tekton | `89b4d5ac...` | Tekton Dashboard | oauth2-proxy 反代 | `oauth2-proxy` Deployment/Secret | `https://tekton.xyz/oauth2/callback` |
| oauth2-traefik | `65d70294...` | Traefik Dashboard | oauth2-proxy 反代 | `oauth2-proxy` Deployment/Secret | `https://traefik.xyz/oauth2/callback` |
| oauth2-headlamp | `0217d408...` | Headlamp | oauth2-proxy 反代 | `oauth2-proxy` Deployment/Secret | `https://headlamp.devops.com/oauth2/callback` |
| keycloak | `ead09e96...` | Keycloak `ceph-sso` Identity Provider `gitlab` | Keycloak OIDC broker（上游 IdP） | `ceph-sso` realm IdP 配置 | `http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint` |

### 6.3 集群侧验证命令

```bash
# Grafana OIDC
kubectl -n monitoring get cm prometheus-grafana -o jsonpath='{.data.grafana\.ini}' | grep -A30 '\[auth.generic_oauth\]'

# ArgoCD OIDC
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.oidc\.config}'

# oauth2-proxy 实例与配置
kubectl -n oauth2-proxy get deploy,svc,secret
kubectl -n oauth2-proxy get deploy oauth2-proxy-headlamp -o jsonpath='{.spec.template.spec.containers[0].args}'

# Keycloak GitLab IdP（验证 clientId 与 GitLab 应用 uid 一致）
# 通过 Keycloak Admin API 查询 ceph-sso realm identity-provider/instances/gitlab
```

### 6.4 验证结论

- GitLab Doorkeeper 应用 `uid` 与集群侧 `clientID`/`client_id` 一一对应，可验证 SSO 对接关系。
- `keycloak` 应用（id 18）对应 Keycloak `ceph-sso` realm 的 GitLab OIDC Identity Provider，说明 GitLab 也作为 Keycloak 的上游身份源。
- access token 归属显示主要为 `root`（id 1），符合当前平台由 root 完成 OIDC 授权的实测证据。
