# Keycloak `ceph-sso` 账号、上下游角色与 Ceph/GitLab 对接说明

> 基于集群实测（2026-11-23）整理，回答以下问题：
> - `ceph-sso` realm 里的 `admin` 密码是什么？
> - `root` 账号从哪里来？是否继承 GitLab？与 `admin` 有何区别、权限是否一致？
> - Keycloak 作为上游/下游时分别是谁的上下游？
> - Keycloak 作为 GitLab 客户端时是什么功能的客户端？
> - Keycloak 作为 Ceph 的 IdP 是什么角色？

## 1. 现象：Ceph 本地账号密码在 Keycloak 登录页无效

Ceph Dashboard 已接入 SAML SSO 后，浏览器访问 `https://10.0.0.41:8443/` 会被 303 重定向到 Keycloak：

```text
https://10.0.0.41:8443/
  -> http://10.0.0.121:32669/realms/ceph-sso/protocol/saml?SAMLRequest=...
  -> /realms/ceph-sso/login-actions/authenticate?... 
```

这个页面是 **Keycloak `ceph-sso` realm 的登录页**，不是 Ceph Dashboard 本地认证页。因此：

- **Ceph Dashboard 本地账号/密码** 不会在 Keycloak 这个页面验证通过。
- 需要使用 **Keycloak `ceph-sso` realm 的本地用户**，或通过该 realm 配置的 **GitLab IdP** 登录。

## 2. `ceph-sso` realm 实测账号情况

通过 Keycloak Admin API 查询（`GET /admin/realms/ceph-sso/users`）：

| 用户名 | 邮箱 | 启用 | 邮箱已验证 | Federated Identity | 说明 |
|---|---|---:|---:|---|---|
| `admin` | `admin@example.com` | true | true | 无 | Keycloak 本地用户 |
| `root` | `gitlab_admin_526ef4@example.com` | true | false | `gitlab / userId=1 / userName=root` | 通过 GitLab IdP broker 登录后创建/链接的用户 |

### 2.1 `admin` 用户密码是什么？

`ceph-sso` 的 `admin` 是 **Keycloak realm 本地用户**，密码以哈希形式存储在 Keycloak 数据库中，**无法直接反查明文**。

可确认的是：

- Keycloak **master realm** 管理员账号为 `admin`，密码存放在 `keycloak/keycloak-admin-secret`（key: `keycloak-admin-password`），用于登录 Keycloak Admin Console：
  - `http://10.0.0.121:32669/admin/master/console`
- 该 master 管理员 **不是** `ceph-sso` realm 的登录用户；它只用于管理 Keycloak。

如果需要 `ceph-sso` 的 `admin` 登录密码，只能重置：

```bash
# 示例：通过 Admin API 重置 ceph-sso realm 用户密码（需先获取 master admin token）
KC_URL="http://10.0.0.121:32669"
# ADMIN_TOKEN 获取方式见 08-keycloak-admin-token-cluster.md

USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/ceph-sso/users?username=admin" | jq -r '.[0].id')

curl -sS -X PUT \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/ceph-sso/users/${USER_ID}/reset-password" \
  -d '{"type":"password","value":"<NEW_PASSWORD>","temporary":false}'
```

> 重置密码是实际变更操作，执行前应确认目标用户和新密码。

### 2.2 `root` 账号从哪里来？是否继承自 GitLab？

`root` **不是简单继承 GitLab 密码的本地账号**，而是 **GitLab 身份通过 Keycloak Identity Brokering 首次登录后，在 `ceph-sso` realm 中创建/链接的用户**。

实测 federated identity：

```json
[
  {
    "identityProvider": "gitlab",
    "userId": "1",
    "userName": "root"
  }
]
```

含义：

- `identityProvider=gitlab`：该用户关联到 `ceph-sso` realm 中 alias 为 `gitlab` 的 Identity Provider。
- `userId=1, userName=root`：对应 GitLab 侧的 `root` 用户（GitLab 用户 ID 1）。
- 该用户在 Keycloak 中有自己的本地记录（email、enabled、role mapping 等），但**认证来源可关联到 GitLab**。

当前 GitLab IdP 配置（实测）：

```json
{
  "alias": "gitlab",
  "providerId": "oidc",
  "enabled": true,
  "trustEmail": false,
  "firstBrokerLoginFlowAlias": null,
  "config": {
    "clientId": "ead09e964d457039a35cdba98e67dd8cd853cc84489050594fc9ffbbb940ba96",
    "defaultScope": "openid profile email",
    "syncMode": "IMPORT"
  }
}
```

`syncMode=IMPORT` 表示 Keycloak 在 broker 登录时导入用户信息到本地 realm 用户；后续认证行为取决于 IdP/link/flow 配置。它**不等于**把 GitLab 密码复制到 Keycloak 数据库。

### 2.3 `root` 与 `admin` 的区别

| 对比项 | `admin` (ceph-sso) | `root` (ceph-sso) |
|---|---|---|
| 来源 | Keycloak 本地创建 | GitLab IdP broker 首次登录后创建/链接 |
| Federated Identity | 无 | `gitlab / userId=1 / userName=root` |
| 邮箱 | `admin@example.com` | `gitlab_admin_526ef4@example.com` |
| emailVerified | true | false |
| Keycloak realm 角色 | `default-roles-ceph-sso`（有效含 `offline_access`, `uma_authorization`） | 同左 |
| 本地密码 | 有（哈希存储，不可读） | 可能无本地密码或由 broker 流程设置；不可读 |
| 适合登录方式 | Keycloak 本地表单 | GitLab IdP 登录（推荐）；本地密码是否可用取决于账号状态 |

### 2.4 权限是否一致？

**在 Keycloak `ceph-sso` realm 内**，两者当前 realm 角色映射一致：

- 直接角色：`default-roles-ceph-sso`
- 有效角色：`default-roles-ceph-sso`、`offline_access`、`uma_authorization`

这说明它们在 Keycloak realm 层面没有额外的 realm-admin 差异。

**但最终能在 Ceph Dashboard 做什么，不只由 Keycloak realm 角色决定**，还取决于：

1. Keycloak SAML Client 给 Ceph 下发的断言/属性（如 `username`/`uid`）。
2. Ceph Dashboard 侧 SAML 用户映射与角色（Ceph 自己的用户/角色体系）。
3. Ceph Dashboard 是否已创建对应用户、赋予什么 Ceph 角色。

因此，“Keycloak 里角色一样”不等于“Ceph Dashboard 权限一定完全一样”，需要同时检查 Ceph Dashboard 的 SAML 用户/角色配置。

## 3. Keycloak 在这条链路中的上下游关系

这套环境里，Keycloak 不是单纯的“上游”或“下游”，而是 **身份代理/协议桥（Identity Broker + Protocol Bridge）**：

```text
用户浏览器
   │
   ▼
Ceph Dashboard (10.0.0.41:8443)
   │  SAML SP / Service Provider / 下游应用
   │  发起 SAML AuthnRequest
   ▼
Keycloak (10.0.0.121:32669, realm=ceph-sso)
   │  对 Ceph：SAML IdP
   │  对 GitLab：OIDC Client / RP
   │  可做协议转换：下游 SAML <-> 上游 OIDC
   ▼
GitLab (192.168.67.201)
      OIDC IdP / 上游身份源
```

结论：

| 视角 | Keycloak 是谁 | 对方是谁 |
|---|---|---|
| 从 Ceph Dashboard 看 | **上游 IdP**（SAML Identity Provider） | Ceph Dashboard 是下游 SP/Client |
| 从 GitLab 看 | **下游客户端**（OIDC Client / Relying Party） | GitLab 是上游 IdP |
| 从整个链路看 | **中间 Broker/桥** | 向下对接应用，向上对接身份源 |

## 4. Keycloak 作为 GitLab 的客户端是什么功能？

在 GitLab 侧，Keycloak 对应的是一个 **OAuth/OIDC 应用（Client）**；在 Keycloak 侧，对应 `ceph-sso` realm 的 **Identity Provider: `gitlab` (providerId=oidc)**。

它的功能不是“GitLab 管理客户端”，而是：

- 让 Keycloak 把用户认证**委托给 GitLab**；
- Keycloak 作为 OIDC Client，从 GitLab 获取 `openid profile email` 范围的身份信息；
- Keycloak 将 GitLab 用户映射/链接为 `ceph-sso` realm 中的本地用户（broker user）；
- 后续 Keycloak 再根据下游应用协议（这里是 SAML）签发断言给 Ceph。

可以把它理解为：**“身份源接入/联合登录”客户端**，用于 Identity Brokering。

## 5. Keycloak 作为 Ceph 的 IdP 是什么功能？

在 Ceph 侧，Ceph Dashboard 配置为 SAML SP；Keycloak `ceph-sso` realm 中的 Ceph Client 是：

```json
{
  "clientId": "https://10.0.0.41:8443/auth/saml2/metadata",
  "name": "Ceph Dashboard",
  "protocol": "saml",
  "enabled": true,
  "publicClient": false,
  "redirectUris": ["https://10.0.0.41:8443/auth/saml2*"]
}
```

Keycloak 在这里的功能是：

- 作为 **SAML 2.0 IdP** 接收 Ceph 的 AuthnRequest；
- 完成用户认证（本地认证或跳转 GitLab IdP）；
- 按 SAML Client 配置签发断言，返回给 Ceph ACS：`https://10.0.0.41:8443/auth/saml2`；
- 把用户名等属性映射为 Ceph 需要的 SAML 属性（如 `uid`/`username` 映射）。

## 6. 排查与操作建议

1. **不要用 Ceph 本地密码登录 Keycloak 页面**。先确认页面是否有 GitLab 登录按钮；有则优先走 GitLab。
2. **需要本地登录时**，重置 `ceph-sso` realm 内对应用户密码，不要去改 master admin。
3. **区分三类账号**：
   - Ceph Dashboard 本地账号
   - Keycloak `ceph-sso` realm 用户
   - Keycloak `master` realm 管理员
4. **权限排查要两端看**：Keycloak 角色/断言 + Ceph Dashboard 用户角色。
5. **自动化脚本获取 Keycloak Admin Token**：参考 `08-keycloak-admin-token-cluster.md`，优先使用 service account + 最小权限。