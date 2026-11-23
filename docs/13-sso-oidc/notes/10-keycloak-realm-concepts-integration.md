# Keycloak 概念、工作原理与对接（Ceph / GitLab / 平台既有系统）

> **环境**（2026-11-23 实测）：
> GitLab CE 19.5.0 `http://192.168.67.201`；Keycloak 26.3.4（K8s `keycloak` 命名空间，NodePort `32669`）；
> Ceph Reef 18.2.8（Dashboard `https://10.0.0.41:8443`，只支持 SAML 2.0）；
> 平台既有 OIDC 系统：ArgoCD、Grafana、Harbor、Traefik/Headlamp/Alloy/Hubble/Tekton（oauth2-proxy）
>
> **性质**：概念解释 + 原理流程 + 各系统对比 + **各对接类型的 GitLab 侧/平台侧配置步骤 + 账号映射与 RBAC** + 本环境手动设置步骤。
> 账号映射的实测基础：GitLab 用户 `root`（id=1，email `gitlab_admin_526ef4@example.com`，
> 组 `[deeptutor, digitalsupply]`）在 ArgoCD / Grafana / Harbor / Keycloak / Ceph / oauth2-proxy 各侧的落点。
> 与 [01-sso-overview.md](01-sso-overview.md)（总体方案）、[04-keycloak-basicauth-forwardauth.md](04-keycloak-basicauth-forwardauth.md)（Keycloak 与 basicAuth 的区别）、
> [08-gitlab-oauth-apps-oauth2-proxy.md](08-gitlab-oauth-apps-oauth2-proxy.md)（oauth2-proxy）、
> [09-oidc-identity-permissions-traefik-forwardauth.md](09-oidc-identity-permissions-traefik-forwardauth.md)（身份与权限映射）互补。
>
> **配套实战记录**：[Ceph Dashboard 经 Keycloak 接 GitLab SSO](../../06-storage-ceph/notes/keycloak-gitlab-ceph-saml-sso.md)

---

## 一、Realm 是什么，和 Keycloak 是什么关系

### 1. 一句话定义

**一个 Keycloak 实例（一个进程 / 一个 Deployment）下面可以有多个互相隔离的 realm；
realm 就是一个互相隔离的"租户"，用户、客户端、角色、身份提供者、会话都按 realm 隔离。**

类比关系：

| 类比对象 | 角色 | 本环境的对应 |
|---|---|---|
| K8s 集群 | 一个物理/逻辑平台 | 一个 Keycloak 实例 |
| K8s namespace | 命名空间，资源互相隔离 | **一个 realm** |
| GitLab 实例 / GitLab 实例下的 group | 平台 / 租户 | Keycloak 实例 / realm |
| 一个 Docker 容器里装的一套应用 | 一套服务 | 一个 Keycloak 实例 |

### 2. Realm 隔离了哪些东西

同一个 Keycloak 实例里的两个 realm，**完全互不可见、互不影响**：

| 资源 | 隔离范围 |
|---|---|
| 用户（User） | 用户名只在 realm 内唯一。`master` 里的 `admin` 和 `ceph-sso` 里的 `admin` 是两个完全不同的用户 |
| 客户端（Client） | `clientId` 只在 realm 内唯一；A 的客户端 B 看不到 |
| 角色（Role） | realm 内定义，跨 realm 不通用 |
| 身份提供者（Identity Provider） | 每个 realm 可以配自己的上游 IdP（比如各自连不同的 GitLab） |
| 认证流程（Authentication Flow） | 可按 realm 定制 |
| 会话（Session / SSO） | **按 realm 隔离**：登录了 A 不代表登录了 B |
| 协议端点地址 | 每个 realm 有自己独立的端点前缀：`/realms/<realm>/...` |

### 3. master realm

Keycloak 启动时自动存在一个 `master` realm，它是**管理 realm**：

- 管理控制台的账号（本环境是 `admin`）属于 `master`，不在任何业务 realm 里；
- 管理 REST API 也是以 `master` 为鉴权基础（`/admin/realms/...`，注意要带 realm 前缀）；
- **业务系统的登录永远不要走 master**，要建自己的业务 realm。

> 本环境就是两个 realm：`master`（管理）+ `ceph-sso`（业务，给 Ceph 用）。

### 4. realm 与 Keycloak 端点的关系

所有端点都以 realm 为前缀，这是理解"为什么 Keycloak 是协议桥"的基础：

```
http://10.0.0.121:32669/realms/ceph-sso/.well-known/openid-configuration   # OIDC 发现
http://10.0.0.121:32669/realms/ceph-sso/protocol/saml/descriptor           # SAML IdP 元数据
http://10.0.0.121:32669/realms/ceph-sso/protocol/saml                     # SAML SSO 端点
http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint             # OIDC 上游回调（broker）
```

同一个 realm 同时暴露 OIDC 和 SAML 两套协议端点，**这就是它能做协议转换的根因**。

---

## 二、Keycloak 的工作原理

### 1. 核心对象

| 对象 | 含义 | 本环境实例 |
|---|---|---|
| **Realm** | 租户/命名空间 | `master`、`ceph-sso` |
| **Client（客户端）** | Keycloak **作为 IdP 时**，对接的下游应用。一个 client 绑定一种协议（OIDC 或 SAML） | `https://10.0.0.41:8443/auth/saml2/metadata`（SAML，给 Ceph） |
| **Identity Provider（上游 IdP）** | Keycloak **作为客户端时**，对接的上游身份源。`providerId` 是 `oidc` 或 `saml`，`alias` 是引用名 | `gitlab`（providerId `oidc`，指向 192.168.67.201） |
| **Protocol Mapper（协议映射）** | 把 Keycloak 内部用户属性/声明，映射成下游协议需要的属性 | `uid`：`username → uid`（SAML 属性映射，Ceph 靠它取用户名） |
| **Client Scope（客户端作用域）** | 挂在 client 上的一组 mapper/策略，控制下发哪些属性 | 默认的 `saml_organization`；**`role_list` 已移除**（会产出重复 `Role` 属性） |
| **Authentication Flow** | 登录流程编排（浏览器表单、上游跳转、注册等） | 默认 browser flow；上游跳转靠 `kc_idp_hint` 或流程编排 |
| **User / Role / Group** | 用户与授权模型 | `admin`（本地测试）、`root`（GitLab 经 broker 进来的用户） |

**关键认知**：Keycloak 里的 "Client" 和 "Identity Provider" 是**两个方向**的东西：

```
下游应用（Ceph） ←SAML→ [ Client ]  ← 这是 Keycloak 当 IdP 时给下游的入口
上游 IdP（GitLab） ←OIDC→ [ Identity Provider ] ← 这是 Keycloak 当客户端时连上游的出口
```

一个 realm 里可以同时存在：**对下游的 SAML Client** + **对上游的 OIDC Identity Provider**。
两者在同一个 realm、同一个进程里，会话打通，就完成了"协议转换 + 单点登录"。

### 2. 一次 SAML 登录的完整流程（Ceph ← Keycloak，本环境真实链路）

```
浏览器
  │ 1. 访问 https://10.0.0.41:8443/
  ▼
Ceph Dashboard（SAML SP）
  │ 2. /auth/saml2/login：用 SP 证书签 AuthnRequest，HTTP-Redirect 到 IdP
  │    GET http://10.0.0.121:32669/realms/ceph-sso/protocol/saml?SAMLRequest=...&RelayState=<ACS>
  ▼
Keycloak（SAML IdP，realm=ceph-sso）
  │ 3. 校验 AuthnRequest（签名、clientId、RelayState）
  │ 4. 本地没有会话 → 走登录流程：显示 Keycloak 登录页，页面上有 GitLab 按钮；
  │    点 GitLab（或授权 URL 带 kc_idp_hint=gitlab 时直接跳转）
  │    302 http://192.168.67.201/oauth/authorize?client_id=...&redirect_uri=<broker回调>&scope=openid profile email
  ▼
GitLab（OIDC IdP，身份源头）
  │ 5. 用户登录 + 授权 → 302 回 Keycloak，带 code
  ▼
Keycloak（OIDC 客户端）
  │ 6. POST http://192.168.67.201/oauth/token（client_secret）换 token
  │ 7. GET /oauth/userinfo 取用户信息，按 syncMode=IMPORT 建/更新本地用户
  │    GitLab 的 preferred_username → Keycloak username（本环境是 root）
  │ 8. 建立 Keycloak 会话（SSO cookie），按请求签发 SAML Response
  │    响应签名 + 断言加密，断言里带 NameID 和 uid 属性
  │    POST 到 ACS: https://10.0.0.41:8443/auth/saml2
  ▼
Ceph Dashboard（SAML SP）
  │ 9. 校验签名/解密断言，从 uid 属性取出用户名
  │ 10. 在 dashboard 用户表里查这个用户（不存在 → 跳 #/sso/404 死循环）
  │ 11. 生成 access_token，303 → /#/login?access_token=...
  ▼
浏览器进入 Dashboard
```

**Keycloak 在这条链路里实际干了 4 件事**：

1. **协议转换**：对 Ceph 说 SAML，对 GitLab 说 OIDC，两边协议互不相识；
2. **会话/SSO**：登录一次后，本机浏览器在 Keycloak 有会话，后续不再重复走 GitLab；
3. **属性映射**：把 GitLab 的身份（`preferred_username`）映射成 Ceph 能识别的 `uid`；
4. **签名与加密**：按 Ceph 的 SP 配置，签发/加密 SAML 断言（本环境是签名 + 加密断言）。

### 3. Keycloak 作为 OIDC 客户端连 GitLab 的流程（细节）

```
Keycloak broker 登录
  → 302 GitLab /oauth/authorize
      client_id      = ead09e...（GitLab OAuth 应用的 client_id）
      redirect_uri   = http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint
      response_type  = code
      scope          = openid profile email
      state          = ...
  → GitLab 校验 redirect_uri（必须逐字符一致）→ 用户登录 → 授权
  → 302 回 Keycloak，带 code
  → Keycloak 带 client_secret 调 /oauth/token 换 access_token / id_token
  → Keycloak 调 /oauth/userinfo 拿用户属性
  → 映射为 Keycloak 用户，进入会话
```

**两个最容易出错的点**（本环境都踩过）：

- `redirect_uri` 必须与 GitLab 应用里注册的**完全一致**（协议、主机、端口、路径），
  GitLab 是**登录之后才校验**，未登录时用 curl 测只会得到 302 到 `/users/sign_in`，看不出来；
- `scope` 必须是 `openid profile email`，只有 `openid` 拿不到用户名/邮箱，
  Keycloak 会生成 `gitlab.<sub>` 这种用户名，Ceph 侧找不到同名用户。

### 4. 为什么需要 Keycloak（而不是直接让 Ceph 连 GitLab）

| 系统 | 支持的协议 | 能不能直连 GitLab（OIDC） |
|---|---|---|
| ArgoCD | OIDC（内置 Dex） | ✅ 能 |
| Grafana | OIDC（generic oauth） | ✅ 能 |
| Harbor | OIDC | ✅ 能 |
| oauth2-proxy | OIDC 客户端 | ✅ 能 |
| **Ceph Dashboard（Reef 18.2.8）** | **只支持 SAML 2.0** | ❌ **不能** |

Ceph Dashboard 的 SSO 只有 SAML 协议入口，GitLab 对外提供的是 OIDC，**协议不匹配**，
所以必须有一个"同时会说两种协议"的中间层。Keycloak 天生就是干这个的：
它一边是 SAML IdP（对 Ceph），一边是 OIDC 客户端（对 GitLab）。

---

## 三、本环境的真实结构（2026-11-23 实测）

### 1. Keycloak 实例

| 项 | 值 |
|---|---|
| 部署方式 | K8s `Deployment`，命名空间 `keycloak`（Helm 仓库 DNS 不可达，改为裸 Deployment） |
| 镜像 | `docker.io/keycloak/keycloak:26.3.4` |
| 启动参数 | `start-dev --http-port=8080`（开发模式，**非生产**） |
| 外部访问 | `http://10.0.0.121:32669`（NodePort 32669，任意节点 IP 均可访问） |
| 管理台账号 | `admin` / 密码见 Secret `keycloak-admin-secret` 的 key `keycloak-admin-password` |
| 健康检查 | 就绪探针探测 `/realms/master`（8080）；metrics/health 在 9000 管理端口 |
| 持久化 | PostgreSQL：`pg16-ceph-rw.cnpg-system.svc.cluster.local:5432/keycloak`，用户 `keycloak` |
| 关键环境变量 | `KC_HOSTNAME=http://10.0.0.121:32669`（决定元数据里的 URL） |

#### 部署没有走 GitOps（实测确认）

**Keycloak 是手工 `kubectl` 部署的，不在 ArgoCD 管理范围内。**证据：

| 检查项 | 结果 |
|---|---|
| ArgoCD 应用列表 | 共 **43** 个应用，**没有任何 keycloak 相关的应用** |
| Deployment / Service 的 `argocd.argoproj.io/tracking-id` 标签 | **不存在** |
| Helm 的 `meta.helm.sh/release-name` 注解 | **不存在** |
| `platform-gitops` 仓库 `platform/sso/` 目录 | 只有 `oauth2-proxy` 的清单和文档，**没有 Keycloak 部署清单** |
| `keycloak-admin-secret` | 手工创建的 `Opaque` Secret，**不是 SealedSecret** |
| 资源创建时间 | `2026-11-22T14:40:19Z`，与手工部署时间吻合 |

**原因**：当时 Helm 仓库 `charts.keycloak.org` **DNS 不可达**（内网环境），
所以放弃 Helm，改用裸 `Deployment` + `NodePort` 直接 `kubectl apply`。
（镜像源也从 `quay.io` 换成了 `docker.io`，见 Ceph 那篇文档的坑 1。）

**带来的问题**：

- 后续所有调整（加 PostgreSQL、设 `KC_HOSTNAME`、建 SAML client、导入 realm）
  都是 `kubectl patch` / Admin API 操作，**不在 Git 里**；
- 没有版本记录、无法审计、无法回滚，重建集群要全部重做一遍；
- 与集群里其他 43 个由 ArgoCD 管理的应用**不一致**。

**补进 GitOps 的做法**（本集群的约定）：

1. 在 `platform-gitops` 仓库新增 `platform/sso/keycloak/`，写入：
   `Namespace`、`SealedSecret`（管理员密码、DB 密码）、`Deployment`、`Service`；
2. 在 `clusters/prod/applications/` 新增 `platform-keycloak.yaml`
   （`app-of-apps` 会自动创建 Application，格式参照 `platform-sso-oauth2-proxy.yaml`）；
3. 资源已存在，用 `argocd app adopt` 让 ArgoCD **接管**而不是重建
   （否则 `prune: true` 会先删掉再创建，导致短暂中断）；
4. **注意**：GitOps 只能管**部署**（Deployment/Service/Secret），
   **管不到 realm 内容**（realm、client、IdP 配置都在 PostgreSQL 的运行期数据里）。
   要声明式管理 realm，需要额外做 realm 导入（initContainer 或 Admin API 脚本）。

### 2. `ceph-sso` realm 的内容

| 对象 | 值 | 说明 |
|---|---|---|
| Realm | `ceph-sso`（displayName "Ceph SSO"） | 业务 realm |
| 上游 IdP | `alias=gitlab`，`providerId=oidc` | 对接 GitLab `http://192.168.67.201` |
| 上游配置 | issuer / authorizationUrl / tokenUrl / userInfoUrl | 四个端点全指向 GitLab |
| 上游 scope | `openid profile email` | 没有 profile/email 就取不到用户名 |
| 上游同步 | `syncMode=IMPORT` | 首次登录自动建用户 |
| 下游 Client | `clientId=https://10.0.0.41:8443/auth/saml2/metadata`，protocol `saml` | 给 Ceph Dashboard |
| 下游 mapper | `uid`：`username → uid` | Ceph 靠 `uid` 取用户名 |
| 用户 | `root`（GitLab broker 进来）、`admin`（本地测试） | |

### 3. GitLab 侧的 9 个 OAuth 应用

GitLab 是**身份源头**，平台里每接入一个系统就建一个 OAuth 应用（回调地址必须逐字符精确匹配）：

| # | 应用名 | 回调地址（redirect_uri） | 用途 |
|---|---|---|---|
| 1 | `grafana` | `https://grafana.k8s.local/login/generic_oauth` | Grafana 原生 OIDC |
| 2 | `argocd` | `https://argocd.devops.com/auth/callback` | ArgoCD 原生 OIDC |
| 3 | `harbor` | `https://192.168.67.202:8443/c/oidc/callback` | Harbor OIDC |
| 4 | `oauth2-hubble` | `https://hubble.xyz/oauth2/callback` | oauth2-proxy |
| 5 | `oauth2-alloy` | `https://alloy.xyz/oauth2/callback` | oauth2-proxy |
| 6 | `oauth2-tekton` | `https://tekton.xyz/oauth2/callback` | oauth2-proxy |
| 7 | `oauth2-traefik` | `https://traefik.xyz/oauth2/callback` | oauth2-proxy |
| 8 | `oauth2-headlamp` | `https://headlamp.devops.com/oauth2/callback` | oauth2-proxy |
| 9 | **`keycloak`** | `http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint` | **Keycloak 的 OIDC 客户端** |

---

## 四、Keycloak ↔ GitLab 对接（Keycloak 作为 OIDC 客户端）

### 手动步骤

1. **在 GitLab 建 OAuth 应用**

   - 名字：`keycloak`
   - Redirect URI：**必须**是 `http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint`
     （格式：`http://<Keycloak外部地址>/realms/<realm>/broker/<IdP别名>/endpoint`）
   - Scopes：`openid profile email`

   > GitLab 19.5 的 `oauth_applications` 表有 `CHECK (organization_id IS NOT NULL)`，
   > 通过 Admin UI 或 `gitlab-rails runner` 建应用时都要带上 `organization_id`。

2. **在 Keycloak 建 realm + 上游 IdP**

   ```bash
   # 用 master 的 admin 通过 Admin API 创建 realm（JSON 导入）
   curl -X POST http://10.0.0.121:32669/admin/realms \
     -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
     --data @/tmp/ceph_realm.json
   ```

   realm JSON 里 IdP 的关键字段：

   ```json
   {
     "realm": "ceph-sso",
     "enabled": true,
     "identityProviders": [{
       "providerId": "oidc",          // 注意：是 oidc，不是 openid-connect
       "alias": "gitlab",
       "config": {
         "issuer": "http://192.168.67.201",
         "authorizationUrl": "http://192.168.67.201/oauth/authorize",
         "tokenUrl": "http://192.168.67.201/oauth/token",
         "userInfoUrl": "http://192.168.67.201/oauth/userinfo",
         "clientId": "<GitLab 应用 client_id>",
         "clientSecret": "<GitLab 应用 client_secret>",
         "authType": "client_secret_basic",
         "defaultScope": "openid profile email",
         "syncMode": "IMPORT",
         "validateSignature": "false"
       }
     }]
   }
   ```

3. **设置 `KC_HOSTNAME`**

   不改的话，元数据里的 entityID/SSO URL 会生成成 `127.0.0.1:8090`（port-forward 的地址），
   浏览器跳转必然失败：

   ```yaml
   - name: KC_HOSTNAME
     value: "http://10.0.0.121:32669"
   - name: KC_HOSTNAME_STRICT
     value: "false"
   ```

4. **验证 broker 跳转**（不需要真实登录，看 302 链即可）

   ```bash
   # 1) Ceph 发起 SAML 请求，拿到 Keycloak SSO URL
   # 2) 手动加 kc_idp_hint=gitlab，看是否跳到 GitLab 的 authorize
   curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' \
     "http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/login?session_code=xxx"
   # → 302 http://192.168.67.201/oauth/authorize?...&scope=openid profile email
   ```

   校验 `redirect_uri` 参数是否与 GitLab 应用里注册的一致，是这一步最关键的检查。

---

## 五、Keycloak ↔ Ceph 对接（Keycloak 作为 SAML IdP）

### 手动步骤

1. **拿 IdP 元数据**

   ```bash
   curl -s http://10.0.0.121:32669/realms/ceph-sso/protocol/saml/descriptor
   ```

   > 正确路径是 `/protocol/saml/descriptor`。
   > `/protocol/saml/metadata`、`/protocol/saml/idp/metadata` 在 Keycloak 26 里都是 404，
   > 这曾让人误以为"SAML 端点没注册"，其实是路径写错了。

2. **在 Keycloak 建 SAML Client（给 Ceph）**

   ```json
   {
     "clientId": "https://10.0.0.41:8443/auth/saml2/metadata",
     "name": "Ceph Dashboard",
     "protocol": "saml",
     "enabled": true,
     "publicClient": false,
     "redirectUris": ["https://10.0.0.41:8443/auth/saml2*"],
     "attributes": {
       "saml.client.signature": "true",
       "saml.signing.certificate": "<SP 证书，去掉 PEM 头尾>",
       "saml.encryption.certificate": "<SP 证书，去掉 PEM 头尾>",
       "saml.encrypt": "true",
       "saml.server.signature": "true",
       "saml.assertion.signature": "true",
       "saml_assertion_consumer_url_post": "https://10.0.0.41:8443/auth/saml2",
       "saml_single_logout_service_url_redirect": "https://10.0.0.41:8443/auth/saml2/logout"
     },
     "protocolMappers": [{
       "name": "uid",
       "protocol": "saml",
       "protocolMapper": "saml-user-attribute-mapper",
       "config": {"user.attribute": "username", "attribute.name": "uid",
                  "attribute.nameformat": "Basic", "jsonType.label": "String"}
     }]
   }
   ```

   注意点：

   - `clientId` 必须等于 Ceph 的 **SP EntityID**：`<dashboard_base_url>/auth/saml2/metadata`；
   - **移除默认的 `role_list` client scope**：它会给每个角色输出一个 `Name="Role"` 的属性，
     python3-saml 遇到同名属性会报 `Found an Attribute element with duplicated Name`；
   - SP 证书与签名/加密开关必须**成对**：给了 SP 证书，就要开签名校验 + 加密断言。

3. **在 Ceph 生成 SP 证书并配置 SAML**

   ```bash
   # 在 mgr 所在主机（ceph-02，10.0.0.41）生成自签证书
   openssl req -x509 -newkey rsa:2048 -nodes \
     -keyout /tmp/saml_sp.key -out /tmp/saml_sp.crt \
     -days 3650 -subj '/CN=ceph-dashboard'

   # 文件必须同时存在于 ceph CLI 节点和 mgr 容器内，且 mgr 用户可读
   docker cp /tmp/saml_sp.crt <mgr容器>:/tmp/saml_sp.crt
   docker cp /tmp/saml_sp.key <mgr容器>:/tmp/saml_sp.key
   docker exec <mgr容器> chmod 644 /tmp/saml_sp.key /tmp/saml_sp.crt

   # 在能执行 ceph 命令的节点（ceph-01）执行
   ceph dashboard sso setup saml2 \
     https://10.0.0.41:8443 \
     http://10.0.0.121:32669/realms/ceph-sso/protocol/saml/descriptor \
     uid '' /tmp/saml_sp.crt /tmp/saml_sp.key
   ```

   参数含义：`<dashboard_base_url> <idp_metadata> [idp_username_attribute] [idp_entity_id] [sp_cert] [sp_key]`。

4. **在 Ceph 建用户（关键，否则死循环）**

   Ceph **只认证不授权**：断言里的用户在 dashboard 用户表里不存在，会跳 `#/sso/404`，
   而页面再次触发登录 → 死循环。

   ```bash
   printf 'CephSsoOnly@2026' > /tmp/root_pwd
   ceph -i /tmp/root_pwd dashboard ac-user-create root administrator
   ceph dashboard ac-user-show root
   ```

   > `-i` 是 **ceph 的全局选项**，必须写在 `dashboard` 之前；文件必须**非空**；角色是**位置参数**。

5. **验证**

   ```bash
   # 状态
   curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.0.41:8443/auth/saml2/login
   # → 303（会跳转到 Keycloak）

   # 端到端（不用浏览器，见 Ceph 那篇文档的步骤 6）
   ```

---

## 六、各系统对比：Keycloak / GitLab / ArgoCD / Grafana / oauth2-proxy / Ceph

### 1. 总表

| 组件 | 本质角色 | 协议 | 身份来源（用户从哪来） | 认证 | 授权 |
|---|---|---|---|---|---|
| **GitLab** | **身份源头（IdP）** | OIDC（本环境用 OIDC；GitLab 自身也能作为 SAML SP 去接外部 IdP） | GitLab 自己的用户库 | 提供登录、签发 token | 提供用户/group，**不负责应用内授权** |
| **Keycloak** | **IAM 平台 / 协议桥** | 既是 **SAML IdP**，又是 **OIDC 客户端** | 可以是本地用户，也可以上游拉取（本环境上游是 GitLab） | 认证、会话/SSO、属性映射、签名加密 | 有角色/组模型，本场景未启用 |
| **ArgoCD** | 应用（自带 Dex） | 原生 OIDC | **直连 GitLab** | 直接走 GitLab OIDC | 用 GitLab group 映射 RBAC |
| **Grafana** | 应用 | 原生 generic OAuth / OIDC | **直连 GitLab** | 直接走 GitLab OIDC | Grafana org/role |
| **Harbor** | 应用 | 原生 OIDC | **直连 GitLab** | 直接走 GitLab OIDC | Harbor 自己的项目权限 |
| **oauth2-proxy**（`oauth2-headlamp`、`oauth2-traefik`、alloy、hubble、tekton） | **认证代理**（反向代理 / ForwardAuth），不是 IdP 也不是应用 | OIDC 客户端 | **直连 GitLab** | 自己做登录、管会话 cookie、给后端透传身份头 | **只认证，不做授权**（登录即全访问） |
| **Ceph Dashboard** | 应用（SAML SP） | **只支持 SAML 2.0** | **经 Keycloak**（Keycloak 又连 GitLab） | 原生 SAML，协议不匹配无法直连 GitLab | Ceph dashboard 用户 + 角色 |

### 2. 四类接入方式

```
① 应用原生 OIDC       ArgoCD、Grafana、Harbor
   应用内置 OIDC 客户端，直接填 GitLab 的 issuer/client_id/callback → 直连

② 反向代理认证        oauth2-proxy（oauth2-headlamp / oauth2-traefik / ...）
   应用本身不碰 OIDC，前面加一层 oauth2-proxy：拦截请求 → 跳 GitLab 登录 → 写 cookie → 放行

③ 认证旁路校验        Traefik ForwardAuth + oauth2-proxy
   Traefik 做决策，先问 oauth2-proxy"放行还是拦截"，再决定是否转发

④ IdP 协议桥接       Keycloak → Ceph
   两边协议不匹配，由 Keycloak 在中间做协议转换 + 会话 + 属性映射
```

### 3. 具体到本环境的三组差异

**Keycloak 与 GitLab**

- GitLab 是**身份源头**，是所有系统最终信任的用户库；它本身不是"统一登录中心"，
  它是"源 IdP"，每个系统各自去连它。
- Keycloak 是**中间层**，它自己没有用户（本环境），用户来自 GitLab；
  它的价值是**把 GitLab 的 OIDC 身份翻译成 Ceph 能认的 SAML**。
- 关系是**上下游**，不是同类竞品：`GitLab(IdP) → Keycloak(IdP 客户端 + SAML IdP) → Ceph(SP)`。

**ArgoCD / Grafana 与 Keycloak**

- 两者都是**应用**，都**原生支持 OIDC**，所以**不需要中间层**，直接配 GitLab 即可；
- 它们与 Keycloak 的区别：Keycloak 对它们是"可选的上层 IdP"，但没必要多一层；
  对 Ceph 则是"必须的协议转换器"。
- 如果未来想让"登录一次、多系统通用"，理论上可以把 Keycloak 设为这些应用的上游 IdP，
  但当前架构是"各应用直连 GitLab"，Keycloak 只服务 Ceph。

**oauth2-headlamp / oauth2-traefik（oauth2-proxy）与 Keycloak**

| 对比维度 | oauth2-proxy（oauth2-headlamp / oauth2-traefik） | Keycloak |
|---|---|---|
| 本质 | **认证代理/反向代理**，不是 IdP | **IAM 平台 / IdP** |
| 是否产生身份断言 | 否，它只下发自己的 **cookie** | 是，下发 **OIDC token / SAML 断言** |
| 对接方式 | 应用无感知，被代理的后端只看到 cookie/头 | 应用必须原生支持对应协议（SAML/OIDC） |
| 授权能力 | **只认证，不做授权**（登录即全访问） | 有角色/组模型，可做授权 |
| 对接 GitLab | 自己当 OIDC 客户端，直连 | 也当 OIDC 客户端，但**再当 SAML IdP** 给下游 |
| 本环境实例 | 5 个：headlamp / traefik / alloy / hubble / tekton | 1 个，服务于 Ceph |

**为什么 Ceph 不用 oauth2-proxy 而用 Keycloak？**

- Ceph Dashboard **原生只支持 SAML**，它的 SSO 入口就是 SAML 协议；
  oauth2-proxy 能给它加一层 cookie 认证，但那是**绕过 Ceph 原生 SSO**，
  SLO（单点登出）、dashboard 内的用户管理等能力都用不上；
- Keycloak 走的是 Ceph **官方支持的 SAML 路径**，且 GitLab 仍是唯一身份源；
- Ceph 的授权仍然依赖自己的 dashboard 用户表（`ac-user-create`），
  无论用哪种认证方式，用户都得先在 Ceph 里存在。

---

## 七、不同对接类型的配置与账号映射（GitLab 侧 / ArgoCD 侧 / Keycloak 侧 / oauth2-proxy 侧）

> 本环境实测账号映射基础数据（GitLab，2026-11-23）：

```
GitLab 用户 root（id=1）
  name      = lei hao
  email     = gitlab_admin_526ef4@example.com
  groups    = [deeptutor, digitalsupply]

GitLab 组 digitalsupply（id=2）
  members   = [root, group_2_bot_35e9209087a1fe4fbd59b1682cceb642]
```

下面所有映射都基于这一条身份记录。

### 7.1 账号映射的总原则

GitLab 是**唯一身份源**，各平台不自己建用户，而是从 OIDC 返回的 **claims** 里取身份。
OIDC 里与"我是谁"相关的标准 claim：

| Claim | 含义 | 本环境 root 的值 |
|---|---|---|
| `sub` | 用户唯一标识（稳定，但可读性差） | `1`（GitLab 用户 id） |
| `preferred_username` | 用户名 | `root` |
| `email` | 邮箱 | `gitlab_admin_526ef4@example.com` |
| `name` | 姓名 | `lei hao` |
| `groups` | 所属组（需 GitLab 侧开启/应用申请） | `["deeptutor","digitalsupply"]` |

映射分三个维度，**不同平台用的维度不一样**，这是配置时最容易搞错的地方：

| 维度 | 说明 | 本环境用到的平台 |
|---|---|---|
| **用户标识** | 用 `preferred_username` / `email` / `sub` 区分是谁 | 全部平台 |
| **组** | 用 `groups` 做批量授权 | ArgoCD、Grafana、Harbor |
| **角色** | 由平台按规则把身份翻译成自己的角色 | ArgoCD（role:admin）、Grafana（GrafanaAdmin）、Ceph（administrator） |

**三种接入类型的映射差异**：

| 接入类型 | 平台从哪个 claim 取身份 | 授权在哪一层配 | 本环境 root 的授权结果 |
|---|---|---|---|
| **原生 OIDC**（ArgoCD、Grafana） | `groups` / `email` / `nickname`，按平台规则翻译 | 平台自己的 RBAC（rbac-cm / role_attribute_path） | ArgoCD `role:admin`；Grafana `GrafanaAdmin` |
| **oauth2-proxy**（oauth2-headlamp、oauth2-traefik） | 默认取 `email` 作为用户标识，透传 `X-Auth-Request-*` 头 | **后端自己做**（本环境后端不校验） | 无授权，登录即全访问 |
| **Keycloak 桥接**（Ceph） | `preferred_username → Keycloak username → SAML uid` | **Ceph dashboard 用户表** | Ceph `administrator` |

**一条完整映射链**（root 的旅程）：

```
GitLab root
   │  OIDC claims: sub=1, preferred_username=root, email=gitlab_admin_526ef4@example.com,
   │                groups=[deeptutor, digitalsupply], name=lei hao
   │
   ├─→ ArgoCD     groups 里的 digitalsupply → policy.csv g, digitalsupply → role:admin
   ├─→ Grafana    nickname=root / groups 含 digitalsupply → role_attribute_path → GrafanaAdmin
   ├─→ oauth2-proxy(headlamp)  email → X-Auth-Request-User，无授权
   ├─→ Keycloak   preferred_username=root → 本地用户 root（仅认证，无角色）
   │      └─→ Ceph  uid=root → dashboard 用户 root → administrator
   └─→ Harbor     groups 含 digitalsupply → admin（oidc_admin_group=digitalsupply）
```

### 7.2 GitLab 侧：为每种对接类型建 OAuth 应用

**通用规则**（适用于所有对接类型）：

| 规则 | 说明 |
|---|---|
| **一个对接方一个应用** | 回调地址各不相同，共用一个应用会导致 redirect_uri 冲突 |
| **redirect_uri 精确匹配** | 协议、主机、端口、路径一个字符都不能差，GitLab **登录后才校验** |
| **scopes 至少 `openid profile email`** | 少 `profile`/`email` 就取不到用户名和邮箱 |
| **需要 groups 就申请 group 权限** | GitLab 的 id_token 默认带 `groups`，但应用要申请到相应 scope |
| **confidential=true** | 机密客户端，secret 用 Secret/SealedSecret 保存，不写进仓库 |
| **organization_id 必填** | GitLab 19.5 的 `oauth_applications` 有 `CHECK (organization_id IS NOT NULL)` |

**现有 9 个应用与用途对照**：

| # | 应用名 | redirect_uri | 使用方 | 接入类型 |
|---|---|---|---|---|
| 1 | `grafana` | `https://grafana.k8s.local/login/generic_oauth` | Grafana | 原生 OIDC |
| 2 | `argocd` | `https://argocd.devops.com/auth/callback` | ArgoCD | 原生 OIDC |
| 3 | `harbor` | `https://192.168.67.202:8443/c/oidc/callback` | Harbor | 原生 OIDC |
| 4 | `oauth2-headlamp` | `https://headlamp.devops.com/oauth2/callback` | oauth2-proxy | 反向代理 |
| 5 | `oauth2-traefik` | `https://traefik.xyz/oauth2/callback` | oauth2-proxy | 反向代理 |
| 6 | `oauth2-alloy` | `https://alloy.xyz/oauth2/callback` | oauth2-proxy | 反向代理 |
| 7 | `oauth2-hubble` | `https://hubble.xyz/oauth2/callback` | oauth2-proxy | 反向代理 |
| 8 | `oauth2-tekton` | `https://tekton.xyz/oauth2/callback` | oauth2-proxy | 反向代理 |
| 9 | `keycloak` | `http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint` | Keycloak | 协议桥接 |

**建应用的三种方式**：

1. **Admin UI**：GitLab → Admin Area → Applications → New application（适合少量、手动场景）
2. **API**（推荐，可脚本化、可纳入 GitOps）：

```bash
# 仓库里已有脚本：docs/13-sso-oidc/scripts/gitlab-create-oauth-app.sh
export GITLAB_TOKEN='<admin api token>'
export GITLAB_URL='http://192.168.67.201'
APP_NAME=oauth2-headlamp
REDIRECT_URI=https://headlamp.devops.com/oauth2/callback
SCOPES='openid profile email'

curl -X POST "http://192.168.67.201/api/v4/applications" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --data-urlencode "name=${APP_NAME}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "scopes=${SCOPES}" \
  --data-urlencode "confidential=true"
# secret 只返回一次，立刻写入 Secret / SealedSecret
```

3. **gitlab-rails runner**（API 权限不足、或需要指定 `organization_id` 时）：

```ruby
# /tmp/create_oauth.rb
require 'oauth2'
oauth = OAuth2::Client.new(
  "http://192.168.67.201/oauth/token",
  "http://192.168.67.201/oauth/authorize",
  client_id: "x", client_secret: "y"
)
# 或直接走内部模型/SQL，务必带上 organization_id
```

> 应用的 **client secret 只返回一次**，丢失后只能删掉重建（会中断在用的服务）。
> 建议创建后立刻加密存进 K8s Secret，仓库里只放 client_id。

**验证 GitLab 侧配置**：

```bash
# OIDC 发现（GitLab 是否暴露 OIDC）
curl -s http://192.168.67.201/.well-known/openid-configuration | python3 -m json.tool | head -20

# 授权端点是否接受该应用（未登录会 302 到 /users/sign_in，说明 client_id/redirect_uri 被接受）
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -G \
  "http://192.168.67.201/oauth/authorize" \
  --data-urlencode "client_id=<client_id>" \
  --data-urlencode "redirect_uri=<redirect_uri>" \
  --data-urlencode "response_type=code" --data-urlencode "scope=openid profile email"
```

### 7.3 ArgoCD：OIDC 配置 + RBAC（GitLab root → role:admin）

#### 7.3.1 GitLab 侧

建 `argocd` 应用：redirect_uri = `https://argocd.devops.com/auth/callback`，
scopes = `openid profile email`，confidential。

client_id：`7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe`
client secret：存进 argocd 命名空间的 Secret `argocd-oauth`（key `client-secret`）

#### 7.3.2 ArgoCD 侧：`argocd-cm` 的 OIDC 配置（真实值）

```yaml
# kubectl -n argocd edit cm argocd-cm
data:
  oidc.config: |
    name: GitLab
    issuer: http://192.168.67.201
    clientID: 7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe
    clientSecret: $argocd-oauth:client-secret     # 引用 Secret，不写明文
    requestedScopes: ["openid", "profile", "email"]
    requestedIDTokenClaims:
      groups:
        essential: true                            # 强制 GitLab 在 id_token 里返回 groups
    enablePKCEAuthentication: true
```

要点：

- `issuer` 必须与 GitLab 的 `/.well-known/openid-configuration` 里的 `issuer` **完全一致**；
- `requestedIDTokenClaims.groups.essential: true` 是 **RBAC 能按组授权的前提**，
  GitLab 没返回 `groups` 时，`policy.csv` 里所有 `g,` 规则都不生效；
- `clientSecret` 用 `$argocd-oauth:client-secret` 引用，格式是 `$<secret名>:<key名>`。

#### 7.3.3 ArgoCD 侧：`argocd-rbac-cm`（真实值）

```yaml
# kubectl -n argocd edit cm argocd-rbac-cm
data:
  policy.csv: |
    g, digitalsupply, role:admin
    g, gitlab_admin_526ef4@example.com, role:admin
  policy.default: role:readonly
  policy.matchMode: glob
  scopes: '[groups, email]'
```

**逐行解释**：

| 行 | 含义 |
|---|---|
| `g, digitalsupply, role:admin` | **group 规则**：`g` 前缀表示匹配身份的 `groups`，组 `digitalsupply` 的成员给 `role:admin`。root 在 GitLab 属于 `digitalsupply`，所以拿到 admin |
| `g, gitlab_admin_526ef4@example.com, role:admin` | 同样是 `g` 规则，但匹配的是 `scopes` 里声明的 **email**：ArgoCD 把 email 也当作一个"组名"来匹配。这是给 root 的**显式兜底授权** |
| `policy.default: role:readonly` | 不匹配任何规则的人只给只读 |
| `policy.matchMode: glob` | 规则值支持 glob（`*`、`?`） |
| `scopes: '[groups, email]'` | **声明从哪些 claim 里取匹配主体**。只有把 `email` 加进来，上面那条 email 形式的规则才会被匹配 |

> `scopes` 是关键：不写 `email`，`g, gitlab_admin_526ef4@example.com` 这行**不会生效**。
> `g` = group，`u` = user，`p` = project；第一列写什么，取决于 `scopes` 里有哪些来源。

#### 7.3.4 手动步骤

```bash
# 1) GitLab 建应用（见 7.2），记录 client_id / secret

# 2) 把 secret 存进 argocd 命名空间
kubectl -n argocd create secret generic argocd-oauth \
  --from-literal=client-secret='<client_secret>' \
  --dry-run=client -o yaml | kubectl apply -f -
# 生产环境用 SealedSecret，避免明文进仓库

# 3) 配置 OIDC
kubectl -n argocd edit cm argocd-cm
#   → 在 data 里填 oidc.config（见 7.3.2）

# 4) 配置 RBAC
kubectl -n argocd edit cm argocd-rbac-cm
#   → 按 7.3.3 填写 policy.csv / policy.default / matchMode / scopes

# 5) 重启 argocd-server 让 OIDC 配置生效（RBAC 变更可热加载）
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server
```

#### 7.3.5 验证

```bash
# 看当前登录用户是谁、属于哪些组
argocd account get-current-user
# 或
argocd admin account get-user gitlab_admin_526ef4@example.com

# 检查 RBAC 解析结果
argocd admin RBAC get

# 用 API 看身份映射（需要先拿到 session token）
curl -s "https://argocd.devops.com/api/v1/account" -H "Authorization: bearer <token>" | python3 -m json.tool
```

**验证要点**：登录后 `get-current-user` 应显示 `gitlab_admin_526ef4@example.com`，
`RBAC get` 应能看到它命中 `role:admin`；若只拿到 readonly，
优先检查 `scopes` 是否包含 `email`、`requestedIDTokenClaims.groups` 是否生效。

### 7.4 Keycloak：账号映射与 RBAC（GitLab root → Ceph administrator）

#### 7.4.1 映射链（四跳，每一跳都是一个坑点）

```
① GitLab id_token   preferred_username = root
② Keycloak broker   按 syncMode=IMPORT，用 preferred_username 建/更新本地用户
                    → realm ceph-sso 里的用户 username = root
③ Keycloak 断言      protocol mapper「uid」把 username 映射成 SAML 属性 uid=root
④ Ceph Dashboard    从 uid 取用户名，查 dashboard 用户表
                    → 必须存在用户 root，且角色是 administrator
```

**本环境实测**：Keycloak 侧 **没有做任何授权**——
`ceph-sso` realm 的角色只有 `default-roles-ceph-sso`、`offline_access`、`uma_authorization`
（全是默认角色），`root` 用户没有 realm 角色，也没有组。
**授权发生在 Ceph 侧**（dashboard 用户的角色）。

#### 7.4.2 Ceph 侧授权配置（实际生效的）

```bash
# 建用户（SSO 用户也必须先存在，否则 #/sso/404 死循环）
printf 'CephSsoOnly@2026' > /tmp/root_pwd
ceph -i /tmp/root_pwd dashboard ac-user-create root administrator

# 改角色
ceph dashboard ac-user-set-roles root administrator

# 确认
ceph dashboard ac-user-show root
# → {"username":"root","roles":["administrator"],"enabled":true}
```

#### 7.4.3 如果想让 Keycloak 侧也做授权（本环境未启用，供扩展）

Keycloak 可以通过 **realm 角色 / 组 + protocol mapper** 把角色写进断言或 token：

1. 在 realm 建角色：`POST /admin/realms/ceph-sso/roles` → `{"name":"ceph-admin"}`
2. 把角色分配给用户：`POST /admin/realms/ceph-sso/users/{root-id}/role-mappings/realm` → `[{"id":..,"name":"ceph-admin"}]`
3. 给 SAML client 加 **角色映射 mapper**（`saml-role-list-mapper`）：
   - `attribute.name` = `roles`（下发给断言的属性名）
   - `single.attribute.value` / `single.attribute.name` 按需配置
4. 或用 **client scope** 挂 mapper，让多个 client 复用同一套角色映射
5. Ceph 侧可改用自定义属性名（`ceph dashboard sso setup saml2 ... <idp_username_attribute>` 只改用户名属性，
   角色仍需在 Ceph 内维护——Ceph 目前不读 SAML 角色属性）

> 结论：**当前架构下 Keycloak 只做认证和协议转换，授权统一在各业务系统自己的用户表里**
> （Ceph 用 dashboard 用户，ArgoCD 用 rbac-cm，Grafana 用 role_attribute_path）。
> 这也是"认证集中、授权分散"的常见做法，避免把业务权限模型搬进 IdP。

#### 7.4.4 手动步骤与验证

```bash
# 1) GitLab 建 keycloak 应用（见 7.2）：redirect_uri 必须是
#    http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint

# 2) Keycloak 导入 realm + IdP（见第四节），设置 KC_HOSTNAME

# 3) 建 SAML client + uid mapper（见第五节），移除 role_list scope

# 4) Ceph 建用户（见 7.4.2）

# 5) 验证 Keycloak 侧的用户映射
curl -s "http://10.0.0.121:32669/admin/realms/ceph-sso/users?username=root&exact=true" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -m json.tool

# 6) 验证断言里的属性（临时把 saml.encrypt 关掉后抓 SAMLResponse 解码）
#    应能看到 <saml:Attribute Name="uid">root</saml:Attribute>

# 7) 端到端验证（见 Ceph 那篇文档的步骤 6）
```

### 7.5 oauth2-proxy（oauth2-headlamp / oauth2-traefik）

#### 7.5.1 GitLab 侧

建应用：名字 `oauth2-headlamp`，
redirect_uri = `https://headlamp.devops.com/oauth2/callback`，
scopes = `openid profile email`。

client_id：`0217d40851fad8c6fa09f1ff3464d5fae1531b93802f6a56501bd24644f5b4cc`

#### 7.5.2 oauth2-proxy 侧配置（真实值）

Deployment 关键 `args`：

```yaml
args:
  - --provider=oidc
  - --oidc-issuer-url=http://192.168.67.201
  - --provider-display-name=GitLab
  - --email-domain=*                                  # 内网放宽：不限制邮箱域名
  - --insecure-oidc-allow-unverified-email=true       # 内网放宽：允许未验证邮箱
  - --scope=openid profile email
  - --code-challenge-method=S256
  - --oidc-groups-claim=groups
  - --redirect-url=https://headlamp.devops.com/oauth2/callback
  - --cookie-secure=true
  - --cookie-samesite=lax
  - --cookie-expire=24h
  - --reverse-proxy=true                              # 反向代理模式
  - --set-xauthrequest=true                          # 透传 X-Auth-Request-* 头给后端
  - --skip-provider-button=true                      # 不显示"选择账号"，直接走 GitLab
  - --http-address=0.0.0.0:4180
  - --upstream=http://headlamp.headlamp.svc.cluster.local:80
  - --silence-ping-logging=true
env:
  - name: OAUTH2_PROXY_CLIENT_ID
    value: 0217d40851fad8c6fa09f1ff3464d5fae1531b93802f6a56501bd24644f5b4cc
  - name: OAUTH2_PROXY_CLIENT_SECRET
    valueFrom: {secretKeyRef: {name: oauth2-headlamp, key: client-secret}}
  - name: OAUTH2_PROXY_COOKIE_SECRET
    valueFrom: {secretKeyRef: {name: oauth2-headlamp, key: cookie-secret}}
```

IngressRoute（Traefik）把外部域名指向 oauth2-proxy 的 4180：

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: headlamp
spec:
  entryPoints: [websecure]
  routes:
  - kind: Rule
    match: Host(`headlamp.devops.com`)
    services:
      name: oauth2-proxy-headlamp     # 或对应 Service
      port: 4180
```

#### 7.5.3 账号映射

- oauth2-proxy **不做授权**，它只认证 + 管会话 cookie；
- 身份通过 **`X-Auth-Request-*` 请求头**透传给后端（需要 `--set-xauthrequest=true`）：

| 头 | 来源 | 本环境 root 的值 |
|---|---|---|
| `X-Auth-Request-User` | `--oidc-email-claim`（默认 `email`；旧名 `--user-id-claim` 已弃用） | `gitlab_admin_526ef4@example.com` |
| `X-Auth-Request-Email` | email claim | `gitlab_admin_526ef4@example.com` |
| `X-Auth-Request-Groups` | `--oidc-groups-claim`（本环境设为 `groups`） | `deeptutor,digitalsupply` |
| `X-Auth-Request-Preferred-Username` | 用户名 | `root` |

- 想让 `X-Auth-Request-User` 用用户名而不是邮箱，加 `--oidc-email-claim=preferred_username`；
- **后端必须自己读取这些头做授权**。本环境的 Headlamp/Traefik/Alloy/Hubble/Tekton
  都没有做细粒度校验，**登录即全访问**（见 09 号文档的权限映射表）。

#### 7.5.4 手动步骤

```bash
# 1) GitLab 建应用（见 7.2），记录 client_id / secret

# 2) 建 Secret（client secret + cookie secret）
kubectl -n oauth2-proxy create secret generic oauth2-headlamp \
  --from-literal=client-secret='<client_secret>' \
  --from-literal=cookie-secret='<随机长串，如 openssl rand -base64 48>' \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) 部署 oauth2-proxy（Deployment + Service，见 7.5.2）
#    Service 端口 4180，selector 匹配 oauth2-proxy-headlamp

# 4) 配置 Traefik IngressRoute，把 headlamp.devops.com 指向 oauth2-proxy 的 4180

# 5) 验证
kubectl -n oauth2-proxy get pods,svc
# 未登录访问应返回 401 + Location 指向 GitLab 授权地址
curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' https://headlamp.devops.com/
# → 401 https://192.168.67.201/oauth/authorize?...
```

**若要做授权**（本环境未做）：

- 方案 A：后端自己读 `X-Auth-Request-Groups` 校验（需要在后端加代码）；
- 方案 B：用 Traefik **ForwardAuth** 模式，让 Traefik 拿 oauth2-proxy 的判定结果做放行/拦截，
  配合 GitLab 组做规则（见 09 号文档的 ForwardAuth 章节）；
- 方案 C：oauth2-proxy 的 `--whitelist-domain` 只限制能登录的域名，**不是授权**，别误用。

### 7.6 账号映射汇总（root 在各平台的最终结果）

| 平台 | 取的 claim | 配置位置 | root 的结果 |
|---|---|---|---|
| ArgoCD | `groups` / `email` | `argocd-rbac-cm` | `role:admin` |
| Grafana | `nickname` / `groups` | `role_attribute_path` | `GrafanaAdmin` |
| Harbor | `groups` | Harbor `oidc_admin_group=digitalsupply` | admin |
| Keycloak | `preferred_username` | realm IdP `syncMode=IMPORT` | 用户 `root`，无角色 |
| Ceph Dashboard | SAML `uid` | `ceph dashboard ac-user-*` | 用户 `root` + `administrator` |
| oauth2-proxy(headlamp/traefik) | `email`（默认） | `--oidc-email-claim` / `--oidc-groups-claim` | 透传头，无授权 |

### 7.7 注意事项

#### GitLab 侧

1. **redirect_uri 必须逐字符一致**，GitLab **登录后才校验**：
   未登录用 curl 测只会得到 302 到 `/users/sign_in`，看不出问题。
   改了 Keycloak 的 `KC_HOSTNAME`、realm 名、IdP 别名后，GitLab 应用的回调地址必须同步改。
2. **secret 只返回一次**，立即加密存进 K8s Secret / SealedSecret；
   丢失只能删应用重建，会中断正在使用该应用的服务。
3. **scopes 至少 `openid profile email`**：只有 `openid` 拿不到 `preferred_username`/`email`，
   下游要么生成不可读的用户名，要么直接授权失败。
4. **groups 不是默认全给**：需要组授权的平台（ArgoCD/Grafana/Harbor）要在应用里申请到组权限，
   并确认 id_token 里确实返回了 `groups`（可用 `requestedIDTokenClaims.groups.essential: true` 强制）。
5. **一个对接方一个应用**，不要共用：回调地址不同，共用必然报 redirect_uri 不合法。
6. **GitLab 19.5 的 `oauth_applications` 有 `CHECK (organization_id IS NOT NULL)`**，
   用 `gitlab-rails runner` 建应用时必须带上 `organization_id`。
7. 改 GitLab 的 `external_url` 后，所有应用的 issuer 和回调地址都要同步。

#### ArgoCD 侧

1. **OIDC 配置改动必须重启 `argocd-server`** 才生效；RBAC（`argocd-rbac-cm`）是热加载的。
2. **`scopes` 里没写 `email`，`g, <email>` 形式的规则不会生效**——这是最常见的"配了不生效"。
3. **`requestedIDTokenClaims.groups.essential: true`** 是按组授权的前提；
   GitLab 没返回 `groups` 时，所有 `g,` 规则都失效，用户只会落到 `policy.default`。
4. `policy.csv` 第一列语义：`g`=组、`u`=用户、`p`=项目，**取决于 `scopes` 声明了哪些来源**。
5. `clientSecret` 用 `$argocd-oauth:client-secret` 引用，**不要写明文**进 ConfigMap（ConfigMap 不是加密存储）。
6. `policy.matchMode: glob` 时规则值支持 `*`，注意别写成过宽的 `*` 导致所有人拿到 admin。
7. 验证用 `argocd admin account get-user <身份>` / `argocd admin RBAC get`，
   不要只凭"能登录"判断授权正确。

#### Keycloak 侧

1. **映射链四跳，任何一跳断掉都表现为登录异常**，排查要逐跳验证：
   GitLab claims → Keycloak 用户 → SAML 属性 → Ceph 用户。
2. **Keycloak 默认只认证不授权**：本环境 realm 里没有自定义角色/组，
   授权完全在业务系统。若要在 Keycloak 侧做授权，必须额外配角色 + role mapper + client scope。
3. **用户名是最关键的一环**：`preferred_username` 决定 Keycloak 用户名，
   再决定 SAML `uid`，最终决定 Ceph 里要建哪个用户。
   改映射前先确认下游用户表里有没有同名用户。
4. **realm 名、IdP 别名一旦变更，GitLab 应用的 redirect_uri 必须同步**
   （回调地址里含 realm 和别名）。
5. `syncMode`：`IMPORT` 首次登录建用户；`JIT` 每次登录同步属性；
   需要用户属性变更实时生效时用 `JIT`，但要确认下游能接受。
6. `defaultScope` 要包含 `profile email`，否则取不到用户名/邮箱。

#### oauth2-proxy 侧

1. **oauth2-proxy 只认证、不授权**，别把它当 RBAC 用；
   要授权必须由后端或 Traefik ForwardAuth 实现。
2. **要透传身份必须开 `--set-xauthrequest=true`**，否则后端拿不到任何用户信息。
3. **`--oidc-email-claim` 默认是 `email`**（旧名 `--user-id-claim` 已弃用）：
   用户标识会是邮箱而不是用户名，需要用户名时显式设 `--oidc-email-claim=preferred_username`。
4. **`cookie-secret` 必须是随机长串**（如 `openssl rand -base64 48`），
   泄露等于可以伪造会话；轮换会踢掉所有在线用户。
5. **`--email-domain=*` 和 `--insecure-oidc-allow-unverified-email=true` 是内网简化配置**，
   公网/对互联网暴露的服务不要用，改用域名白名单 + GitLab 侧成员权限控制。
6. `--whitelist-domain` 只限制"谁能用这个域名登录"，**不是授权**。
7. `--skip-provider-button=true` 适合单 IdP 场景；将来接多个 IdP 时要去掉，否则用户无法选择。

#### 通用

1. **先确认平台从哪个 claim 取身份**，再配授权——
   ArgoCD 用 groups/email、Grafana 用 nickname/groups、Keycloak 用 preferred_username、
   oauth2-proxy 默认用 email，配置前先看该平台的文档，别照抄。
2. **测试顺序**：先验证 OIDC discovery 和授权跳转（未登录 302），
   再验证用户映射（登录后身份是否正确），最后验证授权（角色是否符合预期）。
   顺序反了会浪费大量时间。
3. **授权变更与身份变更要分开验证**：能登录 ≠ 授权正确，
   要用平台的查询命令确认实际角色。
4. **任何一方改 host/域名，三方都要同步**：GitLab 应用的 redirect_uri、
   平台侧的 issuer/回调地址、浏览器访问的地址。
5. **不要把 secret 写进仓库**：ConfigMap、YAML 文件都是明文，
   用 SealedSecret / External Secrets / K8s Secret 管理。

## 八、手动设置完整步骤（结合本环境，可照抄）

### 步骤 0：确认现状

```bash
# GitLab OAuth 应用列表（通过 gitlab-rails runner 查库）
sudo gitlab-rails runner /tmp/q.rb      # select id,name,redirect_uri from oauth_applications

# Keycloak 是否就绪
kubectl -n keycloak get pods
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.121:32669/realms/master

# Ceph Dashboard
sshpass -p 'rootroot.' ssh root@10.0.0.31 'ceph mgr services'
# → {"dashboard": "https://10.0.0.41:8443/"}
```

### 步骤 1：部署 Keycloak（K8s）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: keycloak
        image: docker.io/keycloak/keycloak:26.3.4
        args: ["start-dev", "--http-port=8080"]
        env:
        - name: KEYCLOAK_ADMIN
          value: "admin"
        - name: KEYCLOAK_ADMIN_PASSWORD
          valueFrom: {secretKeyRef: {name: keycloak-admin-secret, key: keycloak-admin-password}}
        - name: KC_HEALTH_ENABLED
          value: "true"
        - name: KC_DB
          value: "postgres"
        - name: KC_DB_URL
          value: "jdbc:postgresql://pg16-ceph-rw.cnpg-system.svc.cluster.local:5432/keycloak"
        - name: KC_DB_USERNAME
          value: "keycloak"
        - name: KC_DB_PASSWORD
          valueFrom: {secretKeyRef: {name: keycloak-db-secret, key: keycloak-db-password}}
        - name: KC_HOSTNAME
          value: "http://10.0.0.121:32669"
        - name: KC_HOSTNAME_STRICT
          value: "false"
        ports:
        - containerPort: 8080
```

> 数据库密码建议放独立的 Secret（`keycloak-db-secret`）。开发验证阶段也可以直接用明文
> 环境变量 `KC_DB_PASSWORD`，但**不要**把密码误填进 `KC_DB_URL`（本环境踩过这个坑），
> 也不要用短域名（跨命名空间必须用 FQDN）。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  type: NodePort
  selector: {app: keycloak}
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 32669
```

PostgreSQL 侧要先建库和用户，并给 schema 授权：

```sql
-- 在 pg16-ceph 主库执行
CREATE DATABASE keycloak;
CREATE USER keycloak WITH PASSWORD 'Keycloak@Db123';
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
GRANT ALL ON SCHEMA public TO keycloak;
```

### 步骤 2：GitLab 建 OAuth 应用

- Redirect URI：`http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint`
- Scopes：`openid profile email`

### 步骤 3：Keycloak 建 realm + GitLab IdP

```bash
TOKEN=$(curl -s -X POST http://10.0.0.121:32669/realms/master/protocol/openid-connect/token \
  -d 'grant_type=password&client_id=admin-cli&username=admin&password=<管理员密码>' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl -X POST http://10.0.0.121:32669/admin/realms \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/ceph_realm.json
```

### 步骤 4：Keycloak 建 SAML Client（给 Ceph）

```bash
curl -X POST http://10.0.0.121:32669/admin/realms/ceph-sso/clients \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/ceph_saml_client.json
# 之后要移除 role_list scope，见第五节
```

### 步骤 5：Ceph 生成 SP 证书并配置 SAML

见第五节第 3 步。

### 步骤 6：创建 Ceph dashboard 用户

```bash
ceph -i /tmp/root_pwd dashboard ac-user-create root administrator
```

### 步骤 7：验证

```bash
# 元数据可用
curl -s http://10.0.0.121:32669/realms/ceph-sso/protocol/saml/descriptor | head -c 200

# Ceph 能发起 SAML 登录
curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' https://10.0.0.41:8443/auth/saml2/login
# → 303 到 Keycloak

# 端到端（Keycloak 本地用户 → SAML → Ceph 拿 access_token）
# 见 ../../06-storage-ceph/notes/keycloak-gitlab-ceph-saml-sso.md 的「步骤 6」
```

浏览器侧完整链路：访问 `https://10.0.0.41:8443` → 登录 → 点 GitLab → 授权 → 回到 Dashboard。

---

## 九、概念速查与常见坑

### 1. 速查表

| 概念 | 一句话 |
|---|---|
| Realm | Keycloak 的租户/命名空间，用户、客户端、角色、会话按它隔离 |
| Client | Keycloak 当 IdP 时给**下游应用**的入口，绑定一种协议（OIDC/SAML） |
| Identity Provider | Keycloak 当客户端时对接的**上游**，`providerId=oidc`/`saml` |
| Protocol Mapper | 内部属性 → 协议属性的映射（本环境：`username → uid`） |
| Client Scope | 挂在 client 上的 mapper/策略集合（本环境移除了 `role_list`） |
| `KC_HOSTNAME` | 生成元数据 URL 的基准，必须是外部可访问的完整地址 |
| Broker | Keycloak 作为上游 IdP 客户端的登录流程（OIDC 回调端点在 `/broker/<alias>/endpoint`） |
| SP EntityID | Ceph 的 SAML 实体标识，等于 `<base_url>/auth/saml2/metadata`，要填进 Keycloak clientId |
| ACS | 断言消费地址，`<base_url>/auth/saml2`，要填进 Keycloak 的断言消费服务 URL |

### 2. 常见坑（详见 Ceph 那篇文档）

| 坑 | 表现 | 根因 |
|---|---|---|
| SAML 元数据 404 | 以为 SAML 端点没注册 | 路径应该是 `/protocol/saml/descriptor` |
| `sp_cert_not_found_and_required` | Dashboard 报 "Single Sign-On is not configured" | IdP 元数据的 `WantAuthnRequestsSigned=true` 覆盖了 Ceph 的默认值，必须给 SP 证书 |
| 断言必须加密 | `The assertion of the Response is not encrypted` | 给了 SP 证书，Keycloak 要开 `saml.encrypt=true` |
| `duplicated Name` | ACS 返回 500 | 默认 `role_list` scope 产出多个同名 `Role` 属性 |
| 元数据里是 127.0.0.1 | 跳转到本机 | 没设 `KC_HOSTNAME` |
| `#/sso/404` 死循环 | 在 404 和 Keycloak 之间来回跳 | Ceph 里没有断言对应的用户，需先 `ac-user-create` |
| `redirect URI included is not valid` | GitLab 登录后报错 | GitLab 应用回调地址与 Keycloak 发送的不一致（GitLab 登录后才校验） |
| 用户名不对 | 登录后 404 | GitLab 上游 `defaultScope` 缺 `profile email`，取不到 `preferred_username` |

### 3. 相关文档

- [01-sso-overview.md](01-sso-overview.md) — 总体方案与分阶段
- [04-keycloak-basicauth-forwardauth.md](04-keycloak-basicauth-forwardauth.md) — Keycloak 与 basicAuth/ForwardAuth 的区别
- [05-grafana-sso.md](05-grafana-sso.md) — Grafana 的三种 SSO 方案
- [08-gitlab-oauth-apps-oauth2-proxy.md](08-gitlab-oauth-apps-oauth2-proxy.md) — GitLab OAuth 应用与 oauth2-proxy
- [09-oidc-identity-permissions-traefik-forwardauth.md](09-oidc-identity-permissions-traefik-forwardauth.md) — 身份与权限映射、ForwardAuth
- [../../06-storage-ceph/notes/keycloak-gitlab-ceph-saml-sso.md](../../06-storage-ceph/notes/keycloak-gitlab-ceph-saml-sso.md) — Ceph 接 Keycloak 实战（含全部踩坑）

---

## 十、登录页的账号归属、认证流程与退出登录

> 本章回答两个最常见的实操疑问：**SAML 跳转后那个登录框该填谁的账号**，
> 以及**为什么退出后又被自动登录**。均为本环境 2026-11-23 实测。

### 10.1 那个登录表单是谁的

访问 `http://10.0.0.121:32669/realms/ceph-sso/protocol/saml?SAMLRequest=...`
时出现的账号密码框，是 **Keycloak 自己**的本地账号登录表单，
属于 **`ceph-sso` 这个 realm**。

**不是 Ceph 的，也不是 Keycloak 管理台的。**

| 账号 | 归属 | 用途 | 能不能填在这个表单 |
|---|---|---|---|
| Ceph dashboard 账号（如 `root`） | Ceph 自己的用户表 | Ceph 的**授权**（角色） | ❌ 整个 SAML 流程里根本不接收 Ceph 密码 |
| Keycloak 管理台 `admin` | Keycloak **master** realm | 管理台、Admin API | ❌ 不在 `ceph-sso` realm，用不了 |
| **Keycloak `ceph-sso` realm 的用户** | Keycloak 业务 realm | **这个表单** | ✅ 就是它 |

**为什么 Ceph 的账号用不上**：SAML 是**断言式**认证。
Ceph 把登录请求发给 Keycloak，Keycloak 认证通过后**签发断言**，
Ceph 只负责校验断言、从 `uid` 属性取出用户名、然后查自己的用户表做授权。
**密码在 Ceph 这一侧完全不参与**，所以没有"填 Ceph 密码"这一步。

**本环境的实际情况**：

- `ceph-sso` realm 里的本地用户只有测试账号 `admin`（密码见创建时设置）；
- 真正的业务用户 `root` 是 **GitLab 经 broker 进来的**，**没有本地密码**，
  只能通过页面上的 **"Or sign in with GitLab"** 按钮登录。

所以：

- 想用**本地账号**登录 → 填 Keycloak `ceph-sso` realm 里的用户（本环境只有测试账号 `admin`）；
- 想用**真实业务账号**登录 → 点 **"Or sign in with GitLab"**，用 GitLab 账号。

### 10.2 认证流程：表单和 "Or sign in with GitLab" 的关系

Keycloak 的登录行为由 realm 的 **browser 认证流程**决定。
本环境 `ceph-sso` 的 browser flow 顶层执行（实测）：

| 优先级 | providerId | 名称 | 要求（requirement） |
|---|---|---|---|
| 10 | `auth-cookie` | Cookie | ALTERNATIVE |
| 20 | `auth-spnego` | Kerberos | DISABLED |
| 25 | `identity-provider-redirector` | **Identity Provider Redirector** | **ALTERNATIVE** |
| 10 | `conditional-user-configured` | Condition - user configured | REQUIRED |
| 20 | `organization` | Organization Identity-First Login | ALTERNATIVE |
| 10 | `auth-username-password-form` | **Username Password Form** | **REQUIRED** |
| 10 | `conditional-user-configured` | Condition - user configured | REQUIRED |
| 20 | `auth-otp-form` | OTP Form | ALTERNATIVE |
| ... | 其余（WebAuthn、恢复码等） | — | DISABLED |

**结论**：

- `identity-provider-redirector` **已经在流程里**（priority 25，ALTERNATIVE）
  → 所以页面上会出现 **"Or sign in with GitLab"** 按钮；
- 但 `auth-username-password-form` 是 **REQUIRED**（priority 10，排在更前面）
  → **必须先过本地账号表单**，所以每次都会先弹出账号密码框。

**想让 GitLab 成为默认、跳过本地表单**：

在 **Keycloak 管理台**操作（Keycloak 26.3.4 的 Admin REST API 上
`executions/{id}` 的更新/配置端点返回 404，建议用管理台 UI）：

1. 登录 `http://10.0.0.121:32669/admin/`（master realm 的 `admin`）
2. 左侧 Realm → 选 **ceph-sso** → **Authentication** → **Flows**
3. 点 **browser** 流程 → 展开
4. 找到 **Identity Provider Redirector** → 点开 → **Requirement** 改成 **REQUIRED**
5. 找到 **Username Password Form** → 点开 → **Requirement** 改成 **DISABLED**
6. 保存

改完后，访问 Ceph 的 SAML 登录入口会**直接 302 跳到 GitLab 授权页**，不再出现本地表单。

> **代价**：改完后 **本地账号将无法登录**（流程里没有表单了）。
> 本环境的本地用户只有测试账号 `admin`，如果还需要用它做端到端验证，
> 记得保留表单，或另建一个专用 realm。

### 10.3 退出登录与"退出后又被自动登录"

#### 退出登录实际发生了什么

Ceph Dashboard 的退出按钮调用 `POST /api/auth/logout`，
当 SSO 已启用时，接口返回：

```json
{"redirect_url": "auth/saml2/slo"}
```

浏览器随后依次走完这条 **SAML 单点登出（SLO）** 链路（本环境实测）：

```
1. Ceph  POST /api/auth/logout
   → 返回 redirect_url = auth/saml2/slo
2. Ceph  GET /auth/saml2/slo
   → 用 SP 私钥签 LogoutRequest，303 跳到
     http://10.0.0.121:32669/realms/ceph-sso/protocol/saml?SAMLRequest=<LogoutRequest>
3. Keycloak  处理 LogoutRequest
   → 销毁 Keycloak 会话，302 回
     https://10.0.0.41:8443/auth/saml2/logout?SAMLResponse=<LogoutResponse>
4. Ceph  GET /auth/saml2/logout
   → 303 到 https://10.0.0.41:8443/#/login
```

**实测验证**（脚本走完整链路）：

| 阶段 | Keycloak 会话 | 再次访问 `/auth/saml2/login` 的结果 |
|---|---|---|
| 登录后 | 存在（`KEYCLOAK_IDENTITY`、`KEYCLOAK_SESSION`） | **直接签发断言**（自动登录） |
| 走完 SLO 链路后 | **已销毁**（两个 cookie 被清除） | **显示登录表单**（需要重新认证） |

**也就是说：SLO 机制在本环境是正常工作的**，退出时 Keycloak 会话确实被销毁。

#### 那为什么你还会看到"退出后又自动登录"

既然 SLO 有效，出现自动登录通常是下面几种情况：

1. **SLO 链路没有走完**
   退出过程中地址栏会经过 `10.0.0.41 → 10.0.0.121 → 10.0.0.41`。
   如果中途关了页面、点了"后退"、或跨站跳转被浏览器拦截，
   **第 3 步的 Keycloak 会话销毁就没执行**，会话还在 → 下次访问自动登录。

2. **浏览器的第三方 Cookie 策略**
   Keycloak 的会话 cookie 属于 `10.0.0.121`，而当前页面在 `10.0.0.41`，
   属于**跨站（第三方）cookie**。部分浏览器/隐私模式会限制其写入或清除，
   导致会话状态不一致。

3. **存在多个会话**
   SLO 只销毁 **LogoutRequest 里 NameID 对应的那个会话**。
   如果之前用不同账号登录过，其他会话可能仍然有效。

4. **退出的位置不对**
   如果是从 **GitLab 页面**或 **Keycloak 页面**退出，
   那只清掉了那一侧的会话，Ceph 和 Keycloak 的会话可能还在。

5. **`#/login` 页面会自动再次触发登录**
   退出后落在 `#/login`，这个页面会立刻检查登录态，
   发现没有 token 就自动跳转 `/auth/saml2/login`。
   只要 Keycloak 会话还在，这一跳就是"瞬间自动登录"，看起来就像没退出。

#### 怎么真正退出干净

- **确认链路走完**：退出时盯着地址栏，必须看到从 `10.0.0.121` 跳回 `10.0.0.41` 并停在 `#/login`。
- **手动清 Keycloak 会话**：在浏览器里删除 `10.0.0.121` 这个站点的 cookie
  （重点是 `KEYCLOAK_IDENTITY`、`KEYCLOAK_SESSION`），再访问 Dashboard。
- **注意 GitLab 的会话是独立的**：退出 Ceph **不会**退出 GitLab。
  如果 Keycloak 配置成自动跳 GitLab（见 10.2 的改动），
  而 GitLab 还处于登录状态，那么下次登录会**静默完成**——
  这是标准 SSO 行为，不是 bug。

### 10.4 顺带解释：`10.0.0.31:8443` 为什么会跳到 `10.0.0.41:8443`

Ceph Dashboard 由 **active mgr** 提供，`ceph mgr services` 显示：

```json
{"dashboard": "https://10.0.0.41:8443/"}
```

本集群 active mgr 在 **ceph-02（10.0.0.41）**。访问 `10.0.0.31:8443`（ceph-01）时，
会 **303 重定向**到当前 active mgr 的地址 `https://10.0.0.41:8443/`，
之后的 SAML 跳转才从 `10.0.0.41` 发起。

**这不是配置问题**，是 Ceph mgr 高可用的正常行为：
Dashboard 永远由当前 active mgr 对外提供，其他节点收到请求会转发/重定向。
如果 mgr 发生切换，Dashboard 地址会随之变化（`ceph mgr services` 可随时确认）。
