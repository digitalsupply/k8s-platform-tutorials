# Keycloak、basicAuth 与 ForwardAuth：概念和区别

> 目的：解释 Keycloak 是什么、basicAuth 是什么，以及它们与 ArgoCD/Harbor
> 已经接入的 GitLab OIDC 有什么区别
> 适用环境：Grafana / ArgoCD / Harbor 已接 GitLab OIDC；Ceph 和
> Traefik/Hubble/Tekton/Alloy 尚未接入
> 最后更新：2026-11-10

## 0. 一句话结论

| 名词 | 一句话 |
|---|---|
| **Keycloak** | 一个专门做身份认证和授权的 IdP（身份提供方），支持 OIDC、SAML、LDAP/AD 联邦、MFA、组/角色 |
| **basicAuth** | HTTP 自带的“用户名:密码”认证，Traefik 用 htpasswd 校验；每个 UI 一套静态密码 |
| **GitLab OIDC** | GitLab 作为 IdP，ArgoCD/Harbor/Grafana 作为客户端；应用自己知道登录用户是谁 |
| **oauth2-proxy** | 一个“认证适配器/代理”，把 OIDC 登录翻译成 Traefik 能用的 ForwardAuth 检查 |
| **Keycloak + oauth2-proxy** | Keycloak 负责登录，oauth2-proxy 负责保护那些本身不支持 OIDC 的 UI |

---

## 1. Keycloak 是什么

Keycloak 是一个开源的 **IAM（Identity and Access Management）** 系统，核心角色是
**IdP（Identity Provider，身份提供方）**。

它负责：

- 用户登录（用户名密码、OTP、WebAuthn、社交登录）；
- 签发 OIDC/OAuth2 token 和 SAML 断言；
- 管理用户、组、角色；
- 联邦已有的用户目录（LDAP / Active Directory）；
- 给不同应用（client）配置不同的回调地址、权限和 token claim；
- 会话管理、登出、暴力破解防护、审计。

### 1.1 Keycloak 的核心概念

| 概念 | 含义 | 类比 |
|---|---|---|
| **Realm** | 租户/命名空间，用户、客户端、角色都隔离在 realm 内 | 一个公司/环境 |
| **Client** | 接入的应用，例如 `grafana`、`argocd`、`harbor`、`ceph` | 一个应用 |
| **User** | 用户账号 | 员工 |
| **Group** | 用户组，可映射到应用角色 | 部门/团队 |
| **Role** | 角色，可分配给用户或组 | 权限 |
| **Mapper** | 决定 token 里带哪些 claim（email、groups、roles） | 字段映射 |
| **Identity Provider** | 上游身份源，例如 LDAP/AD，或另一个 OIDC IdP | 公司 AD |
| **Authentication Flow** | 登录流程，可加 OTP、条件认证 | 登录策略 |

### 1.2 Keycloak 不是什么

- **不是反向代理**：它不转发你的业务流量；
- **不是 basicAuth 的替代品**：它本身不会给一个“没有登录功能”的 UI 加上登录；
- **不是必须的**：只做 Grafana/ArgoCD/Harbor 的 OIDC，GitLab 已经够用；
- **不是用户数据库的唯一选择**：它可以联邦 AD/LDAP，用户密码仍留在 AD。

### 1.3 Keycloak 和 GitLab 作为 IdP 的区别

| 能力 | GitLab OIDC | Keycloak |
|---|---|---|
| OIDC/OAuth2 | ✅ | ✅ |
| SAML 2.0 IdP | ❌（GitLab 是 SAML 的 SP） | ✅ |
| LDAP/AD 联邦 | ❌（GitLab 是 LDAP 客户端） | ✅ |
| MFA 策略 | 主要针对 GitLab 自身 | 可按 client/realm 配置 |
| 组/角色 claim | 有限（`groups`） | 灵活（group/role mapper） |
| 多租户 | 弱 | Realm 级隔离 |
| 身份代理（broker） | 有限 | ✅（可代理 GitLab/AD/其他 OIDC） |

所以：

- **只想让几个支持 OIDC 的应用登录**：GitLab 足够；
- **要接 Ceph（SAML）、要联邦 AD、要做统一 IAM**：需要 Keycloak。

---

## 2. basicAuth 是什么

**basicAuth（HTTP Basic Authentication）** 是 HTTP 协议自带的认证方式：

```http
Authorization: Basic base64(username:password)
```

浏览器收到 `401 WWW-Authenticate: Basic` 后会弹出一个原生登录框，用户输入账号密码，
之后**每个请求**都会带上这个头。

在 Traefik 里通常这样配置：

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: traefik-dashboard-auth
spec:
  basicAuth:
    secret: traefik-dashboard-auth-secret
```

Secret 里是 htpasswd 格式：

```text
users: admin:$apr1$xxxxxxxx$yyyyyyyyyyyyyyyyyyyy
```

### 2.1 basicAuth 的流程

```text
浏览器 ──请求──> Traefik ──校验 htpasswd──> 后端 UI
                  │
                  └── 失败：401 + 浏览器弹框
```

特点：

- 认证在 **Traefik 边缘**完成；
- 后端 UI **完全不知道**登录用户是谁；
- 每个 Middleware/Secret 是一套独立密码；
- 没有 SSO、没有 MFA、没有组/角色、没有登出、没有用户级审计；
- 密码轮换要改 Secret 并通知所有人；
- 依赖 HTTPS，否则密码等于明文传输。

### 2.2 basicAuth 适合什么

- 临时保护内部 Dashboard；
- 单用户/少量运维人员的应急入口；
- 本身完全没有登录体系、也不值得改造的老 UI。

不适合：

- 需要知道“谁登录了”的应用；
- 需要按用户/组做权限的应用；
- 需要 MFA、统一登出、集中停用账号的场景。

---

## 3. 已接 GitLab OIDC 的 ArgoCD/Harbor 与 basicAuth 的区别

ArgoCD/Harbor/Grafana 是 **原生 OIDC 客户端**：

```text
浏览器 ──> ArgoCD/Harbor ──重定向──> GitLab 登录
                │                         │
                └──<── authorization code ─┘
                │
                └── 用 code 换 token，读取 email/groups
```

应用自己完成：

- 生成登录跳转；
- 校验 state/nonce；
- 用 code 换 token；
- 读取 `email`、`groups` 等 claim；
- 建立自己的会话；
- 按组/角色做授权（ArgoCD RBAC、Harbor 项目权限、Grafana org role）。

### 3.1 对比表

| 能力 | basicAuth | 原生 OIDC（ArgoCD/Harbor/Grafana） |
|---|---|---|
| 统一账号 | ❌ 每个 UI 一套 | ✅ 一套 GitLab/Keycloak 账号 |
| SSO | ❌ | ✅ 登录一次，多个应用复用会话 |
| MFA | ❌ | ✅ 由 IdP 决定 |
| 应用知道用户是谁 | ❌ | ✅ `email` / `preferred_username` |
| 组/角色映射 | ❌ 只有 allow/deny | ✅ `groups` → ArgoCD role / Harbor admin |
| 用户级停用 | ❌ 改密码并通知所有人 | ✅ IdP 禁用用户即可 |
| 登出 | ❌ 浏览器缓存凭据 | ✅ 应用/IdP 登出 |
| 审计 | 只能看到 IP | ✅ 能看到具体用户 |
| 密码轮换 | 每个 UI 单独改 | IdP 统一管理 |
| 应用改造成本 | 低（加 Middleware） | 中（应用本身要支持 OIDC） |

### 3.2 关键区别：身份有没有传到应用

- **basicAuth**：Traefik 校验完就结束，后端只知道“请求被放行”，不知道是谁；
- **OIDC**：应用拿到 token，知道 `alice@example.com` 属于 `digitalsupply` 组，
  于是可以给她 ArgoCD Admin 或 Harbor 项目管理员权限。

---

## 4. Keycloak 如何解决 Traefik/Hubble/Tekton/Alloy

先说结论：**Keycloak 本身不能直接保护这些 UI**，因为：

- Traefik Dashboard 没有登录体系；
- Hubble UI 没有登录体系；
- Tekton Dashboard 没有登录体系；
- Alloy UI 没有登录体系。

它们现在只能用 basicAuth。要让它们用 SSO，需要两件东西：

1. **Keycloak（或 GitLab）**：负责登录、签发 token；
2. **oauth2-proxy**：负责把 OIDC 登录翻译成 Traefik 的 ForwardAuth 检查。

### 4.1 架构

```text
                    ┌──────────────────────────────┐
浏览器 ──> Traefik ──┤ ForwardAuth                  │
                    │   └─> oauth2-proxy           │
                    │         └─> Keycloak/GitLab  │
                    └──────────────────────────────┘
                              │ 200 + headers
                              ▼
                         Hubble / Tekton / Alloy / Traefik UI
```

### 4.2 请求流程

1. 浏览器访问 `https://hubble.xyz`；
2. Traefik 把请求交给 `forwardAuth` 地址：
   `http://oauth2-proxy.oauth2-proxy.svc:4180/oauth2/auth`；
3. oauth2-proxy 检查请求里的 session cookie：
   - 没有/过期 → 返回 302 到 Keycloak/GitLab 登录页；
   - 有且有效 → 返回 200，并附带
     `X-Auth-Request-User`、`X-Auth-Request-Groups` 等头；
4. Traefik 收到 200 后，才把原始请求转发给 Hubble/Tekton/Alloy；
5. 用户登录一次后，同一域名下的其他受保护路径复用 cookie。

### 4.3 Traefik 配置示例

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: oauth2-forwardauth
  namespace: traefik
spec:
  forwardAuth:
    address: http://oauth2-proxy.oauth2-proxy.svc:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Groups
      - X-Auth-Request-Email
```

然后把原来 IngressRoute 里的：

```yaml
middlewares:
  - name: hubble-ui-auth   # basicAuth
```

替换为：

```yaml
middlewares:
  - name: oauth2-forwardauth
```

### 4.4 重要澄清

- **Keycloak 不是必须的**：oauth2-proxy 可以直接对接 GitLab OIDC；
- 如果只需要保护 Traefik/Hubble/Tekton/Alloy，
  `oauth2-proxy + GitLab` 就能做，不需要引入 Keycloak；
- 如果还要接 Ceph（SAML）、联邦 AD、做统一 IAM，Keycloak 才值得引入。

### 4.5 ForwardAuth 的局限

- 它只能做“放行/拒绝”，不能替应用做细粒度权限；
- 应用本身仍然不知道用户是谁，除非它主动读取
  `X-Auth-Request-User` 等头；
- 不同域名需要分别配置 cookie/callback，或者使用统一的认证域名；
- 需要防止客户端伪造 `X-Auth-Request-*` 头（只信任 oauth2-proxy 的来源）。

---

## 5. Keycloak 如何解决 Ceph

Ceph 的情况不同：

- Ceph Dashboard 17.2（Quincy）**只支持 SAML 2.0**，不支持 OIDC；
- GitLab 不是 SAML IdP；
- Keycloak 同时支持 SAML 2.0 IdP，所以可以作为 Ceph 的 SAML 身份源。

流程：

```text
浏览器 ──> Ceph Dashboard ──SAML──> Keycloak ──> 用户登录
                │
                └── 根据用户名/组映射 Dashboard 角色
```

前提：

- Ceph mgr 节点安装 `python3-saml`；
- Ceph mgr 能访问 Keycloak 的 SAML metadata URL；
- 有 Ceph admin keyring 执行 `ceph dashboard sso setup saml2`。

这也是为什么“收编 Ceph”必须引入 Keycloak（或其他 SAML IdP），
而不能只靠 GitLab OIDC。

---

## 6. 两条落地路线

### 路线 A：最小改造（不引入 Keycloak）

```text
Grafana/ArgoCD/Harbor ──OIDC──> GitLab
Traefik/Hubble/Tekton/Alloy ──ForwardAuth──> oauth2-proxy ──OIDC──> GitLab
Ceph ── 仍然无法接入（需要 SAML IdP）
```

适合：

- 只想让现有 UI 都用 GitLab 账号登录；
- 不想维护 Keycloak；
- Ceph 暂时保持本地账号。

### 路线 B：统一 IAM（引入 Keycloak）

```text
                    ┌── Grafana/ArgoCD/Harbor (OIDC)
浏览器 ──> Keycloak ─┼── Ceph (SAML)
           (IdP)    └── Traefik/Hubble/Tekton/Alloy
                          └── oauth2-proxy (ForwardAuth)
```

适合：

- 要接 Ceph；
- 要联邦 AD/LDAP；
- 要做 MFA、统一登出、集中用户管理；
- 未来还要接更多系统。

### 路线对比

| 维度 | A：GitLab + oauth2-proxy | B：Keycloak |
|---|---|---|
| 新增组件 | oauth2-proxy | Keycloak + DB + oauth2-proxy |
| Ceph | ❌ 不支持 | ✅ SAML |
| AD/LDAP 联邦 | ❌ | ✅ |
| MFA | 取决于 GitLab | ✅ 可配置 |
| 统一登出/会话 | 弱 | ✅ |
| 运维成本 | 低 | 中 |
| 适合阶段 | 快速补齐 UI 登录 | 长期统一身份 |

---

## 7. 本集群的映射关系

| 系统 | 现在的登录方式 | 目标方式 | 是否需要 Keycloak |
|---|---|---|---|
| Grafana | GitLab OIDC | 保持，或迁 Keycloak | 否 |
| ArgoCD | GitLab OIDC | 保持，或迁 Keycloak | 否 |
| Harbor | GitLab OIDC | 保持，或迁 Keycloak | 否 |
| Ceph Dashboard | 本地账号 | Keycloak SAML | **是** |
| Traefik Dashboard | basicAuth | oauth2-proxy ForwardAuth | 否（可直连 GitLab） |
| Hubble UI | basicAuth | oauth2-proxy ForwardAuth | 否（可直连 GitLab） |
| Tekton Dashboard | basicAuth | oauth2-proxy ForwardAuth | 否（可直连 GitLab） |
| Alloy UI | basicAuth | oauth2-proxy ForwardAuth | 否（可直连 GitLab） |
| GitLab | 自身账号 | 可继续作为 IdP，或改为 Keycloak 客户端 | 取决于路线 |

---

## 8. 常见误区

1. **“装了 Keycloak 所有 UI 就自动有登录了”**
   ❌ 错。Keycloak 只负责认证；不支持 OIDC 的 UI 仍然需要 oauth2-proxy/ForwardAuth。

2. **“basicAuth 就是 SSO”**
   ❌ 错。basicAuth 是每个 UI 一套静态密码，没有统一会话、没有身份传递。

3. **“OIDC 登录成功就有权限了”**
   ❌ 错。OIDC 只解决认证；权限要靠 `groups`/`roles` 映射到应用自己的 RBAC。

4. **“Keycloak 是反向代理”**
   ❌ 错。Keycloak 不转发业务流量；oauth2-proxy 才是认证代理。

5. **“GitLab 可以给 Ceph 做 SAML”**
   ❌ 错。GitLab 是 SAML 的 Service Provider，不是 Identity Provider。

6. **“basicAuth 换个密码就行，不需要改应用”**
   ✅ 对，但代价是没有用户级身份、审计和细粒度权限。

---

## 9. 建议的下一步

1. 如果只想先把 Traefik/Hubble/Tekton/Alloy 统一登录：
   部署 **oauth2-proxy**，直接对接 GitLab OIDC，替换 basicAuth；
2. 如果确定要接 Ceph，或要联邦 AD、做长期统一 IAM：
   部署 **Keycloak**，把 Ceph 用 SAML 接入，再逐步把其他系统迁到 Keycloak；
3. 无论走哪条路线，都保留本地 admin/break-glass，并先把 GitLab 和入口证书的 TLS 补齐。
