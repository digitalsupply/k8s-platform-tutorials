# Keycloak Admin Console 界面与功能详解（基于实际环境）

> 实测环境：`http://10.0.0.121:32669/admin/master/console/`  
> Keycloak 版本：`26.3.4`  
> 采集时间：2026-11-23（通过 Keycloak Admin REST API 采集实际配置并映射到控制台菜单）

## 1. 入口与整体布局

| 项目 | 实际值 | 说明 |
|---|---|---|
| Admin Console | `http://10.0.0.121:32669/admin/master/console/` | 管理控制台入口 |
| OIDC Well-known (master) | `http://10.0.0.121:32669/realms/master/.well-known/openid-configuration` | 协议发现端点 |
| OIDC Well-known (ceph-sso) | `http://10.0.0.121:32669/realms/ceph-sso/.well-known/openid-configuration` | 业务 realm 端点 |
| 管理员账号 | `admin`（master realm） | 存于 `keycloak/keycloak-admin-secret`，不是业务 realm 用户 |

控制台典型布局：

- **左上角 Realm 选择器**：切换当前管理的 realm（`master` / `ceph-sso`）。菜单内容随 realm 变化。
- **左侧导航栏**：Manage（客户端、用户、角色等）、Configure（Realm 设置、认证、IdP 等）。
- **右上角用户菜单**：当前管理员账号、Manage account、Sign out。
- **页面主体**：列表/详情/Tab 表单，通常有 `Add`/`Create`、搜索、表格操作、保存按钮。

## 2. 实际 Realm 总览

| realm | displayName | enabled | loginWithEmail | registration | sslRequired |
| --- | --- | --- | --- | --- | --- |
| master | Keycloak | true | true | false | external |
| ceph-sso | Ceph SSO | true | true | false | external |

说明：
- `master`：Keycloak 管理 realm，用于管理整个实例；不要把业务应用接到这里。
- `ceph-sso`：业务 realm，本环境用于 Ceph Dashboard SSO，并桥接 GitLab OIDC。

## 3. Realm：`master` 实际配置

### 3.1 Realm settings（Realm 设置）

对应控制台：左侧 **Realm settings**。常见 Tab：General、Login、Email、Themes、Keys、Events、Localization、Security defenses、Sessions、Tokens、User registration 等（不同版本略有差异）。

| 配置项 | 实际值 | 说明 |
|---|---|---|
| `realm` | `master` | Realm 名称，URL 前缀的一部分 |
| `displayName` | `Keycloak` | 控制台显示名 |
| `enabled` | `true` | 是否启用 |
| `sslRequired` | `external` | 是否要求 HTTPS（external/none/all） |
| `registrationAllowed` | `false` | 是否允许用户自注册 |
| `loginWithEmailAllowed` | `true` | 是否允许邮箱登录 |
| `duplicateEmailsAllowed` | `false` | 是否允许重复邮箱 |
| `resetPasswordAllowed` | `false` | 是否允许忘记密码 |
| `rememberMe` | `false` | 是否显示 Remember me |
| `verifyEmail` | `false` | 是否要求验证邮箱 |
| `editUsernameAllowed` | `false` | 是否允许修改用户名 |
| `defaultSignatureAlgorithm` | `RS256` | 默认签名算法 |
| `accessTokenLifespan` | `60` | Access Token 生命周期（秒） |
| `ssoSessionIdleTimeout` | `1800` | SSO 会话空闲超时（秒） |
| `ssoSessionMaxLifespan` | `36000` | SSO 会话最大生命周期（秒） |

### 3.2 Clients（客户端）

对应控制台：左侧 **Clients**。用于管理“被 Keycloak 保护/对接”的应用。

功能点：
- **Client list**：查看/搜索客户端，创建新客户端。
- **Client details**：Settings（协议、redirect URI、认证方式）、Keys、Credentials、Roles、Client scopes、Service account roles、Advanced 等。
- **Client type/protocol**：OpenID Connect 或 SAML。

| clientId | name | protocol | enabled | publicClient | redirectUris |
| --- | --- | --- | --- | --- | --- |
| account | ${client_account} | openid-connect | true | true | /realms/master/account/* |
| account-console | ${client_account-console} | openid-connect | true | true | /realms/master/account/* |
| admin-cli | ${client_admin-cli} | openid-connect | true | true |  |
| broker | ${client_broker} | openid-connect | true | false |  |
| ceph-sso-realm | ceph-sso Realm |  | true | false |  |
| master-realm | master Realm |  | true | false |  |
| security-admin-console | ${client_security-admin-console} | openid-connect | true | true | /admin/master/console/* |


### 3.3 Client scopes（客户端作用域）

对应控制台：**Client scopes**。定义可复用的协议映射（mappers）和声明范围，挂到 client 上。

| name | protocol | description |
| --- | --- | --- |
| microprofile-jwt | openid-connect | Microprofile - JWT built-in scope |
| role_list | saml | SAML role list |
| address | openid-connect | OpenID Connect built-in scope: address |
| basic | openid-connect | OpenID Connect scope for add all basic claims to the token |
| profile | openid-connect | OpenID Connect built-in scope: profile |
| web-origins | openid-connect | OpenID Connect scope for add allowed web origins to the access token |
| email | openid-connect | OpenID Connect built-in scope: email |
| service_account | openid-connect | Specific scope for a client enabled for service accounts |
| offline_access | openid-connect | OpenID Connect built-in scope: offline_access |
| saml_organization | saml | Organization Membership |
| phone | openid-connect | OpenID Connect built-in scope: phone |
| organization | openid-connect | Additional claims about the organization a subject belongs to |
| roles | openid-connect | OpenID Connect scope for add user roles to the access token |
| acr | openid-connect | OpenID Connect scope for add acr (authentication context class reference) to the token |


### 3.4 Realm roles（Realm 角色）

对应控制台：**Realm roles**。定义 realm 级别角色，可组合（composite）并分配给用户/组。

| name | composite | clientRole | description |
| --- | --- | --- | --- |
| admin | true | false | ${role_admin} |
| uma_authorization | false | false | ${role_uma_authorization} |
| offline_access | false | false | ${role_offline-access} |
| create-realm | false | false | ${role_create-realm} |
| default-roles-master | true | false | ${role_default-roles} |

### 3.5 Users（用户）

对应控制台：**Users**。管理用户、凭据、角色映射、组、会话、Federated identity。

| username | email | enabled | emailVerified |
| --- | --- | --- | --- |
| admin |  | true | false |


### 3.6 Groups（用户组）

对应控制台：**Groups**。用于组织用户并批量赋予角色/属性。

_（无）_


### 3.7 Sessions（会话）

对应控制台：**Sessions**。查看活跃 SSO 会话，可按用户/客户端查看并登出。

_本次文档采集未逐会话拉取明细；可在控制台 Sessions 页面查看当前活跃会话，也可用 Admin API `/admin/realms/{realm}/client-session-stats` 获取统计。_

### 3.8 Events（事件）

对应控制台：**Events**。分 User events（登录、登出、错误等）和 Admin events（管理员操作审计）。

| 配置项 | 实际值 |
|---|---|
| `eventsEnabled` | `False` |
| `adminEventsEnabled` | `False` |
| `adminEventsDetailsEnabled` | `False` |
| `eventsListeners` | `["jboss-logging"]` |

### 3.9 Authentication（认证）

对应控制台：**Authentication**。管理认证流程（Flows）、Required actions、Policies（Password/OTP/WebAuthn 等）。

功能点：
- **Flows**：Browser、Direct grant、Registration、Reset credentials、First broker login 等流程编排。
- **Required actions**：如 Configure OTP、Verify Email、Update Password。
- **Policies**：密码策略、OTP 策略、WebAuthn 策略。

| alias | description | providerId | topLevel | builtIn |
| --- | --- | --- | --- | --- |
| browser | Browser based authentication | basic-flow | true | true |
| direct grant | OpenID Connect Resource Owner Grant | basic-flow | true | true |
| registration | Registration flow | basic-flow | true | true |
| reset credentials | Reset credentials for a user if they forgot their password or something | basic-flow | true | true |
| clients | Base authentication for clients | client-flow | true | true |
| first broker login | Actions taken after first broker login with identity provider account, which is not yet linked to any Keycloak account | basic-flow | true | true |
| docker auth | Used by Docker clients to authenticate against the IDP | basic-flow | true | true |

### 3.10 Identity providers（身份提供者）

对应控制台：**Identity providers**。配置上游身份源（OIDC/SAML/Social）。Keycloak 作为 broker/client 对接上游 IdP。

_（无）_

### 3.11 User federation（用户联邦）

对应控制台：**User federation**。对接 LDAP/Kerberos 等外部用户目录。

_（无）_

---

## 3. Realm：`ceph-sso` 实际配置

### 3.1 Realm settings（Realm 设置）

对应控制台：左侧 **Realm settings**。常见 Tab：General、Login、Email、Themes、Keys、Events、Localization、Security defenses、Sessions、Tokens、User registration 等（不同版本略有差异）。

| 配置项 | 实际值 | 说明 |
|---|---|---|
| `realm` | `ceph-sso` | Realm 名称，URL 前缀的一部分 |
| `displayName` | `Ceph SSO` | 控制台显示名 |
| `enabled` | `true` | 是否启用 |
| `sslRequired` | `external` | 是否要求 HTTPS（external/none/all） |
| `registrationAllowed` | `false` | 是否允许用户自注册 |
| `loginWithEmailAllowed` | `true` | 是否允许邮箱登录 |
| `duplicateEmailsAllowed` | `false` | 是否允许重复邮箱 |
| `resetPasswordAllowed` | `false` | 是否允许忘记密码 |
| `rememberMe` | `false` | 是否显示 Remember me |
| `verifyEmail` | `false` | 是否要求验证邮箱 |
| `editUsernameAllowed` | `false` | 是否允许修改用户名 |
| `defaultSignatureAlgorithm` | `RS256` | 默认签名算法 |
| `accessTokenLifespan` | `300` | Access Token 生命周期（秒） |
| `ssoSessionIdleTimeout` | `1800` | SSO 会话空闲超时（秒） |
| `ssoSessionMaxLifespan` | `36000` | SSO 会话最大生命周期（秒） |

### 3.2 Clients（客户端）

对应控制台：左侧 **Clients**。用于管理“被 Keycloak 保护/对接”的应用。

功能点：
- **Client list**：查看/搜索客户端，创建新客户端。
- **Client details**：Settings（协议、redirect URI、认证方式）、Keys、Credentials、Roles、Client scopes、Service account roles、Advanced 等。
- **Client type/protocol**：OpenID Connect 或 SAML。

| clientId | name | protocol | enabled | publicClient | redirectUris |
| --- | --- | --- | --- | --- | --- |
| account | ${client_account} | openid-connect | true | true | /realms/ceph-sso/account/* |
| account-console | ${client_account-console} | openid-connect | true | true | /realms/ceph-sso/account/* |
| admin-cli | ${client_admin-cli} | openid-connect | true | true |  |
| broker | ${client_broker} | openid-connect | true | false |  |
| https://10.0.0.41:8443/auth/saml2/metadata | Ceph Dashboard | saml | true | false | https://10.0.0.41:8443/auth/saml2* |
| realm-management | ${client_realm-management} | openid-connect | true | false |  |
| security-admin-console | ${client_security-admin-console} | openid-connect | true | true | /admin/ceph-sso/console/* |


#### 重点 Client：Ceph Dashboard（SAML）

| 字段 | 实际值 |
|---|---|
| `clientId` | `https://10.0.0.41:8443/auth/saml2/metadata` |
| `name` | `Ceph Dashboard` |
| `protocol` | `saml` |
| `enabled` | `True` |
| `publicClient` | `False` |
| `frontchannelLogout` | `True` |
| `standardFlowEnabled` | `True` |
| `implicitFlowEnabled` | `False` |
| `directAccessGrantsEnabled` | `False` |
| `redirectUris` | `["https://10.0.0.41:8443/auth/saml2*"]` |
| `attributes.saml_name_id_format` | `username` |
| `attributes.saml.client.signature` | `true` |
| `attributes.saml.signature.algorithm` | `RSA_SHA256` |
| `attributes.saml.force.post.binding` | `true` |
| `attributes.saml.server.signature` | `true` |
| `attributes.saml.signing.certificate` | `MIIDEzCCAfug...REDACTED...` |
| `attributes.saml_force_name_id_format` | `false` |

### 3.3 Client scopes（客户端作用域）

对应控制台：**Client scopes**。定义可复用的协议映射（mappers）和声明范围，挂到 client 上。

| name | protocol | description |
| --- | --- | --- |
| email | openid-connect | OpenID Connect built-in scope: email |
| profile | openid-connect | OpenID Connect built-in scope: profile |
| basic | openid-connect | OpenID Connect scope for add all basic claims to the token |
| offline_access | openid-connect | OpenID Connect built-in scope: offline_access |
| phone | openid-connect | OpenID Connect built-in scope: phone |
| web-origins | openid-connect | OpenID Connect scope for add allowed web origins to the access token |
| saml_organization | saml | Organization Membership |
| microprofile-jwt | openid-connect | Microprofile - JWT built-in scope |
| role_list | saml | SAML role list |
| acr | openid-connect | OpenID Connect scope for add acr (authentication context class reference) to the token |
| roles | openid-connect | OpenID Connect scope for add user roles to the access token |
| organization | openid-connect | Additional claims about the organization a subject belongs to |
| service_account | openid-connect | Specific scope for a client enabled for service accounts |
| address | openid-connect | OpenID Connect built-in scope: address |


### 3.4 Realm roles（Realm 角色）

对应控制台：**Realm roles**。定义 realm 级别角色，可组合（composite）并分配给用户/组。

| name | composite | clientRole | description |
| --- | --- | --- | --- |
| default-roles-ceph-sso | true | false | ${role_default-roles} |
| offline_access | false | false | ${role_offline-access} |
| uma_authorization | false | false | ${role_uma_authorization} |

### 3.5 Users（用户）

对应控制台：**Users**。管理用户、凭据、角色映射、组、会话、Federated identity。

| username | email | enabled | emailVerified |
| --- | --- | --- | --- |
| admin | admin@example.com | true | true |
| root | gitlab_admin_526ef4@example.com | true | false |


实测补充（Admin API）：
- `admin`：本地用户，无 Federated identity。密码哈希存储，不可反查明文。
- `root`：有 Federated identity `gitlab / userId=1 / userName=root`，由 GitLab OIDC broker 首次登录创建/链接。
- 两者 realm 角色映射当前一致：`default-roles-ceph-sso`（有效含 `offline_access`、`uma_authorization`）。

### 3.6 Groups（用户组）

对应控制台：**Groups**。用于组织用户并批量赋予角色/属性。

_（无）_


### 3.7 Sessions（会话）

对应控制台：**Sessions**。查看活跃 SSO 会话，可按用户/客户端查看并登出。

_本次文档采集未逐会话拉取明细；可在控制台 Sessions 页面查看当前活跃会话，也可用 Admin API `/admin/realms/{realm}/client-session-stats` 获取统计。_

### 3.8 Events（事件）

对应控制台：**Events**。分 User events（登录、登出、错误等）和 Admin events（管理员操作审计）。

| 配置项 | 实际值 |
|---|---|
| `eventsEnabled` | `False` |
| `adminEventsEnabled` | `False` |
| `adminEventsDetailsEnabled` | `False` |
| `eventsListeners` | `["jboss-logging"]` |

### 3.9 Authentication（认证）

对应控制台：**Authentication**。管理认证流程（Flows）、Required actions、Policies（Password/OTP/WebAuthn 等）。

功能点：
- **Flows**：Browser、Direct grant、Registration、Reset credentials、First broker login 等流程编排。
- **Required actions**：如 Configure OTP、Verify Email、Update Password。
- **Policies**：密码策略、OTP 策略、WebAuthn 策略。

| alias | description | providerId | topLevel | builtIn |
| --- | --- | --- | --- | --- |
| browser | Browser based authentication | basic-flow | true | true |
| direct grant | OpenID Connect Resource Owner Grant | basic-flow | true | true |
| registration | Registration flow | basic-flow | true | true |
| reset credentials | Reset credentials for a user if they forgot their password or something | basic-flow | true | true |
| clients | Base authentication for clients | client-flow | true | true |
| first broker login | Actions taken after first broker login with identity provider account, which is not yet linked to any Keycloak account | basic-flow | true | true |
| docker auth | Used by Docker clients to authenticate against the IDP | basic-flow | true | true |

### 3.10 Identity providers（身份提供者）

对应控制台：**Identity providers**。配置上游身份源（OIDC/SAML/Social）。Keycloak 作为 broker/client 对接上游 IdP。

| alias | providerId | enabled | trustEmail | syncMode | clientId | defaultScope |
| --- | --- | --- | --- | --- | --- | --- |
| gitlab | oidc | true | false | IMPORT | ead09e964d457039a35cdba98e67dd8cd853cc84489050594fc9ffbbb940ba96 | openid profile email |


`gitlab` IdP 实测说明：
- 类型：`oidc`，用于将用户认证委托给 GitLab。
- `defaultScope=openid profile email`：向 GitLab 请求基本身份信息。
- `syncMode=IMPORT`：首次 broker 登录导入用户信息到 Keycloak 本地。
- 在 `ceph-sso` 中，它是 Keycloak 作为 **OIDC Client/RP** 对接的上游 IdP。

### 3.11 User federation（用户联邦）

对应控制台：**User federation**。对接 LDAP/Kerberos 等外部用户目录。

_（无）_

---

## 4. 结合本环境的关键链路

```text
浏览器
  -> Ceph Dashboard (SAML SP, https://10.0.0.41:8443)
  -> Keycloak realm ceph-sso (SAML IdP, http://10.0.0.121:32669/realms/ceph-sso/...)
  -> GitLab (OIDC IdP, http://192.168.67.201, Identity Provider alias=gitlab)
```

角色总结：

| 组件 | 在链路中的角色 | 协议 |
|---|---|---|
| Ceph Dashboard | 下游应用 / SAML SP | SAML |
| Keycloak `ceph-sso` | 对 Ceph 是 SAML IdP；对 GitLab 是 OIDC Client/RP；整体是 Identity Broker | SAML + OIDC |
| GitLab | 上游身份源 / OIDC IdP | OIDC |

## 5. 常用排查入口

| 需求 | 控制台位置 | API 示例 |
|---|---|---|
| 看 realm 列表 | 左上角 Realm 切换 | `GET /admin/realms` |
| 看用户 | Users | `GET /admin/realms/ceph-sso/users` |
| 看 federated identity | Users -> 用户详情 -> Identity provider links | `GET /admin/realms/ceph-sso/users/{id}/federated-identity` |
| 看客户端 | Clients | `GET /admin/realms/ceph-sso/clients` |
| 看 IdP | Identity providers | `GET /admin/realms/ceph-sso/identity-provider/instances` |
| 看认证流程 | Authentication -> Flows | `GET /admin/realms/ceph-sso/authentication/flows` |
| 看事件 | Events | `GET /admin/realms/ceph-sso/events/config` |

## 6. 注意事项

- **不要把业务系统接入 master realm**。`master` 只用于管理 Keycloak 本身。
- **密码不可反查**：用户密码是哈希存储，只能重置。
- **角色要两端看**：Keycloak 角色/断言正确，不代表 Ceph Dashboard 已授予对应 Ceph 角色。
- **secret 脱敏**：client secret、IdP client secret、密码等不要写入 Git。
- **版本差异**：Keycloak 26.x Admin Console UI 与旧版本有变化，菜单名称/位置可能略不同，但核心对象一致。
