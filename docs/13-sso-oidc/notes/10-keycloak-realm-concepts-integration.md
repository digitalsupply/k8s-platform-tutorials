# Keycloak 概念、工作原理与对接（Ceph / GitLab / 平台既有系统）

> **环境**（2026-11-23 实测）：
> GitLab CE 19.5.0 `http://192.168.67.201`；Keycloak 26.3.4（K8s `keycloak` 命名空间，NodePort `32669`）；
> Ceph Reef 18.2.8（Dashboard `https://10.0.0.41:8443`，只支持 SAML 2.0）；
> 平台既有 OIDC 系统：ArgoCD、Grafana、Harbor、Traefik/Headlamp/Alloy/Hubble/Tekton（oauth2-proxy）
>
> **性质**：概念解释 + 原理流程 + 各系统对比 + 本环境手动设置步骤。
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

## 七、手动设置完整步骤（结合本环境，可照抄）

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

## 八、概念速查与常见坑

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
