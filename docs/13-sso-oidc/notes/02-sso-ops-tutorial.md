# SSO 运维与基础概念教程

> 面向：需要维护 Grafana / ArgoCD / Harbor / Traefik / Hubble / Alloy / Tekton 登录体系的人
> 环境：GitLab 作为当前 IdP；oauth2-proxy 负责无原生登录 UI 的反向代理
> 最后更新：2026-11-10

---

## 第一部分：基础概念

### 1. 认证 vs 授权

| 概念 | 回答的问题 | 例子 |
|---|---|---|
| **认证（Authentication）** | 你是谁？ | 输入用户名密码、GitLab 登录、MFA |
| **授权（Authorization）** | 你能做什么？ | ArgoCD 只读、Harbor 项目管理员、Grafana Editor |

SSO 只解决“认证”，权限仍由每个系统自己的 RBAC/角色决定。

### 2. 身份、IdP、SP、SSO

| 名词 | 含义 |
|---|---|
| **Identity** | 一个用户身份，通常有 `sub`、`email`、`username`、`groups` |
| **IdP（Identity Provider）** | 负责认证和签发身份凭证的系统，例如 GitLab、Keycloak、AD |
| **SP（Service Provider）** | 信任 IdP 的应用，例如 Grafana、ArgoCD、Harbor |
| **SSO（Single Sign-On）** | 登录一次，多个 SP 复用同一个 IdP 会话 |

```text
用户 ──登录──> IdP ──token/断言──> SP
                │
                └── 其他 SP 复用会话
```

### 3. OAuth2 与 OIDC

**OAuth2** 是授权框架，解决“应用如何拿到访问资源的 token”。
**OIDC** 是建立在 OAuth2 之上的认证层，额外提供 **ID Token**，告诉应用“用户是谁”。

#### 3.1 四个角色

| 角色 | 在本平台是谁 |
|---|---|
| Resource Owner | 用户 |
| Client | Grafana / ArgoCD / Harbor / oauth2-proxy |
| Authorization Server | GitLab（或 Keycloak） |
| Resource Server | GitLab API / 用户信息端点 |

#### 3.2 常见端点

| 端点 | 作用 |
|---|---|
| `/.well-known/openid-configuration` | OIDC 发现文档，列出所有端点 |
| `/oauth/authorize` | 浏览器登录入口 |
| `/oauth/token` | 后端用 code 换 token |
| `/oauth/userinfo` | 用 access token 读取用户信息 |
| `/oauth/discovery/keys` | 校验 ID Token 签名的公钥 |

#### 3.3 Authorization Code Flow（本平台使用）

```text
1. 浏览器访问 Grafana
2. Grafana 302 到 IdP /authorize
   ?client_id=...&redirect_uri=...&scope=openid profile email
   &state=随机值&nonce=随机值&code_challenge=...
3. 用户在 IdP 登录（可带 MFA）
4. IdP 302 回 Grafana /login/generic_oauth?code=...&state=...
5. Grafana 后端 POST /token，带 code + client_secret + code_verifier
6. IdP 返回 id_token + access_token
7. Grafana 校验签名、issuer、audience、nonce，读取 email/groups
8. Grafana 建立自己的会话
```

#### 3.4 关键参数

| 参数 | 作用 | 常见错误 |
|---|---|---|
| `client_id` | 应用标识 | 写错 → `invalid_client` / `unknown client` |
| `client_secret` | 应用密码 | 写错/没解析 → `invalid_client` |
| `redirect_uri` | 回调地址 | 与 IdP 配置不一致 → `redirect_uri_mismatch` |
| `scope` | 请求的权限/claim | GitLab 用空格分隔，Harbor 用逗号 |
| `state` | 防 CSRF | cookie 丢失 → `data length is less than nonce size` |
| `nonce` | 防重放 | 同上 |
| `code_challenge` | PKCE，防 code 拦截 | 未启用会有安全警告 |

#### 3.5 ID Token 里常见的 claim

| claim | 含义 | 用途 |
|---|---|---|
| `sub` | 用户唯一 ID | 用户主键 |
| `email` | 邮箱 | 用户识别/兜底 |
| `preferred_username` | 用户名 | 登录名 |
| `nickname` | 昵称/用户名 | GitLab 常用 |
| `groups` | 用户组 | 角色映射 |
| `iss` | 签发者 | 必须与 issuer 一致 |
| `aud` | 受众 | 必须包含 client_id |

### 4. SAML 与 LDAP

#### 4.1 SAML 2.0

- 基于 XML 断言，企业常用；
- 角色：IdP 和 SP；
- SP 提供 metadata（ACS URL、Entity ID），IdP 提供 metadata；
- 登录流程：SP → IdP 登录 → IdP POST SAMLResponse 到 SP 的 ACS。

Ceph Dashboard 17.2 只支持 SAML，所以需要 Keycloak 这类 SAML IdP。

#### 4.2 LDAP / AD

- 目录协议，存用户、组、邮箱；
- Grafana 可以直接 `bind` LDAP；
- Keycloak 可以联邦 LDAP/AD，再把用户以 OIDC/SAML 发给应用。

常见字段：

| 字段 | 含义 |
|---|---|
| Bind DN | 用来查询目录的服务账号 |
| Search Base | 从哪个 OU 开始搜 |
| Search Filter | 例如 `(&(objectClass=user)(sAMAccountName=%s))` |
| Group DN | 组路径，用于角色映射 |

### 5. Cookie、Session、State

OIDC 登录依赖浏览器 cookie：

- **会话 cookie**：登录后应用保存的 session；
- **state cookie**：登录过程中保存 `state`/`nonce`，回调时校验；
- **cookie domain**：cookie 对哪个域名生效；
- **Secure**：只通过 HTTPS 发送；
- **SameSite**：跨站请求是否带 cookie。

常见错误：

- 清 cookie 后好了 → 旧 cookie/密钥不匹配；
- 不同子域登录不共享 → cookie domain 不对；
- HTTP 下 `Secure` cookie 不生效 → 必须 HTTPS。

### 6. basicAuth、ForwardAuth、反向代理

| 方式 | 认证在哪 | 应用知道用户吗 | 适用 |
|---|---|---|---|
| **basicAuth** | Traefik | ❌ | 临时保护 Dashboard |
| **ForwardAuth** | 外部认证服务 | 部分（通过 header） | 应用无登录体系，但能接受 header |
| **反向代理** | oauth2-proxy | ✅（可传 header） | 应用无登录体系，最通用 |
| **原生 OIDC** | 应用自己 | ✅ | Grafana/ArgoCD/Harbor |

本平台最终选择：

- 原生 OIDC：Grafana、ArgoCD、Harbor；
- 反向代理：Traefik、Hubble、Alloy、Tekton（oauth2-proxy）；
- SAML：Ceph（待 Keycloak）。

### 7. Keycloak 核心概念

| 概念 | 含义 |
|---|---|
| Realm | 租户/环境 |
| Client | 接入的应用 |
| User / Group / Role | 用户、组、角色 |
| Mapper | 把用户属性写进 token |
| Identity Provider | 上游身份源（AD/LDAP/其他 OIDC） |
| Authentication Flow | 登录流程（OTP、条件认证） |

Keycloak 不是反向代理；它只负责认证和签发凭证。

---

## 第二部分：本平台现状

### 8. 架构

```text
原生 OIDC：
  浏览器 -> Grafana/ArgoCD/Harbor -> GitLab OIDC

无原生登录：
  浏览器 -> Traefik -> oauth2-proxy-<host> -> 后端 UI
                          └── GitLab OIDC

待接入：
  Ceph Dashboard -> Keycloak SAML（需要先部署 Keycloak）
```

### 9. 系统清单

| 系统 | 地址 | 登录方式 | GitOps 管理 |
|---|---|---|---|
| Grafana | `https://grafana.k8s.local` | GitLab OIDC | ✅ values + SealedSecret |
| ArgoCD | `https://argocd.devops.com` | GitLab OIDC | ⚠️ Helm bootstrap |
| Harbor | `https://192.168.67.202:8443` | GitLab OIDC | ❌ 外部系统 |
| Traefik | `https://traefik.xyz` | oauth2-proxy | ✅ platform-ui + sso app |
| Hubble | `https://hubble.xyz` | oauth2-proxy | ✅ platform-ui + sso app |
| Alloy | `https://alloy.xyz` | oauth2-proxy | ✅ platform-ui + sso app |
| Tekton | `https://tekton.xyz` | oauth2-proxy | ✅ platform-ui + sso app |
| Ceph | — | 未接入 | ❌ 需要 Keycloak |

### 10. 当前 OAuth Application（client ID 不是秘密）

| 应用 | GitLab Application name | client_id |
|---|---|---|
| Grafana | `grafana` | `78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228` |
| ArgoCD | `argocd` | `7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe` |
| Harbor | `harbor` | `c7924430a6d02f5e14da2251233eb98c7a880ece868c96758da91ebd7c1ae502` |
| Hubble | `oauth2-hubble` | `9876a0d08f77da5f2f4313eff0567c5a929f1808c7f7e201bdd8e70d9e07f2f0` |
| Alloy | `oauth2-alloy` | `20fc4475cbbe2899f7708a5c1dc66e769901cae806d8fd4112f70c6a559c7a68` |
| Tekton | `oauth2-tekton` | `89b4d5ace9b9478f5b6de2a426039aa5b542ded7eb1d78c9cfe59de33cf8dc6f` |
| Traefik | `oauth2-traefik` | `65d70294ac5fe9e81ee1702a60dc3f6290cf2af3920f7a941ccf05d220ca9a91` |

---

## 第三部分：运维手册

### 11. 新增一个“原生 OIDC”应用

以接入一个新应用 `foo` 为例：

1. 在 GitLab 创建 OAuth Application：
   - redirect URI：`https://foo.example.com/auth/callback`（以应用文档为准）
   - scopes：`openid profile email`
2. 把 client secret 做成 SealedSecret：
   ```bash
   kubectl -n <app-namespace> create secret generic foo-oauth \
       --dry-run=client -o yaml \
       --from-literal=client-secret='<SECRET>' \
   | kubeseal --namespace <app-namespace> --name foo-oauth \
       --controller-name sealed-secrets-controller \
       --controller-namespace kube-system \
       --format yaml \
   > platform/<app>/sealedsecret-foo-oauth.yaml
   ```
3. 在应用的配置里填：
   - issuer：`http://192.168.67.201`
   - client_id / client_secret
   - redirect_uri
   - scopes
   - 组/角色映射
4. 验证：
   - `/auth/login` 或登录页是否跳转 IdP；
   - IdP 是否接受 client_id/redirect_uri；
   - 回调后能否拿到 email/groups；
   - 角色是否正确。

### 12. 新增一个“oauth2-proxy 保护”的 UI

以新增 `foo.xyz` 为例：

1. GitLab 创建 OAuth Application：
   - redirect URI：`https://foo.xyz/oauth2/callback`
2. 生成两个 secret：
   ```bash
   CLIENT_SECRET='<gitlab-app-secret>'
   COOKIE_SECRET="$(openssl rand -hex 16)"   # 必须 32 个字符
   ```
3. 创建 SealedSecret：
   ```bash
   kubectl -n oauth2-proxy create secret generic oauth2-foo \
       --dry-run=client -o yaml \
       --from-literal=client-secret="$CLIENT_SECRET" \
       --from-literal=cookie-secret="$COOKIE_SECRET" \
   | kubeseal --namespace oauth2-proxy --name oauth2-foo \
       --controller-name sealed-secrets-controller \
       --controller-namespace kube-system \
       --format yaml \
   > platform/sso/oauth2-proxy/templates/sealedsecret-foo.yaml
   ```
4. 在 `platform/sso/oauth2-proxy/values.yaml` 的 `instances` 增加：
   ```yaml
   - name: foo
     host: foo.xyz
     clientID: <client_id>
     secretName: oauth2-foo
     upstream: http://foo.default.svc.cluster.local:8080
   ```
5. 把 `foo.xyz` 的 IngressRoute 改成指向：
   ```yaml
   services:
     - name: oauth2-proxy-foo
       namespace: oauth2-proxy
       port: 4180
   ```
6. 提交、同步、验证：
   ```bash
   curl -sk --resolve foo.xyz:443:10.0.0.252 \
     -o /dev/null -w '%{http_code} %{redirect_url}\n' https://foo.xyz/
   ```
   期望 `302` 到 GitLab `/oauth/authorize`。

### 13. 轮换 secret

#### 13.1 GitLab OAuth Application secret

1. 在 GitLab 删除并重建 Application，或使用 GitLab 的 renew secret（如果版本支持）；
2. 重新 `kubeseal` 到对应 SealedSecret；
3. `kubectl apply -f` 或提交 Git 让 ArgoCD 同步；
4. 重启对应应用：
   ```bash
   kubectl -n <ns> rollout restart deploy/<app>
   ```
5. 用 `curl` 验证 token 端点返回 `invalid_grant`（code 假）而不是 `invalid_client`。

#### 13.2 oauth2-proxy cookie secret

1. 生成新的 32 字符 secret：`openssl rand -hex 16`；
2. 重新 seal `oauth2-<name>`；
3. `kubectl -n oauth2-proxy rollout restart deploy/oauth2-proxy-<name>`；
4. 用户需要重新登录（旧 cookie 失效）。

#### 13.3 ArgoCD client secret 的标签

ArgoCD 的 `$secret-name:key` 只解析带标签的 Secret：

```yaml
metadata:
  labels:
    app.kubernetes.io/part-of: argocd
```

缺标签会导致 `invalid_client`，并出现日志：

```text
level=warning msg="secret key does not exist in secret"
```

### 14. 用户、组、角色映射

| 系统 | 配置 | 示例 |
|---|---|---|
| Grafana | `role_attribute_path` | `contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' \|\| 'Viewer'` |
| ArgoCD | `argocd-rbac-cm` | `g, digitalsupply, role:admin` |
| Harbor | `oidc_admin_group` | `digitalsupply` |
| oauth2-proxy | `--oidc-groups-claim=groups` | 透传 `X-Auth-Request-Groups` |

注意：

- GitLab 的 `groups` claim 可能不包含所有组；
- 组路径要写全（如 `digitalsupply/devops`）；
- 先用一个测试用户确认 claim，再配置正式 RBAC。

### 15. 验证命令

#### 15.1 OIDC discovery

```bash
curl -s http://192.168.67.201/.well-known/openid-configuration | jq .
```

#### 15.2 登录跳转

```bash
curl -sk --resolve hubble.xyz:443:10.0.0.252 \
  -o /dev/null -w '%{http_code} %{redirect_url}\n' https://hubble.xyz/
```

#### 15.3 client secret 是否正确

```bash
SEC=$(kubectl -n oauth2-proxy get secret oauth2-hubble -o jsonpath='{.data.client-secret}' | base64 -d)
curl -s -X POST http://192.168.67.201/oauth/token \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode code=dummy \
  --data-urlencode redirect_uri=https://hubble.xyz/oauth2/callback \
  --data-urlencode client_id=9876a0d08f77da5f2f4313eff0567c5a929f1808c7f7e201bdd8e70d9e07f2f0 \
  --data-urlencode client_secret="$SEC"
```

- `invalid_grant`：client 认证通过，只是 code 假；
- `invalid_client`：client_id/secret 有问题。

#### 15.4 查看日志

```bash
kubectl -n oauth2-proxy logs deploy/oauth2-proxy-hubble --tail=100
kubectl -n argocd logs deploy/argocd-server --tail=100 | grep -i oidc
kubectl -n monitoring logs deploy/prometheus-grafana -c grafana --tail=100 | grep -i oauth
```

### 16. 故障排查表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| `invalid_client` | client secret 错/未解析；ArgoCD Secret 缺标签 | 检查 Secret、标签、重启 Pod |
| `data length is less than nonce size` | 旧 OIDC state cookie | 清 cookie，或直接访问 `/login` |
| `redirect_uri_mismatch` | 回调地址与 IdP 配置不一致 | 两边改成完全一样（含端口/路径） |
| 登录后 401 循环 | cookie domain / Secure / SameSite 不对 | 确认 HTTPS；检查 cookie 域名 |
| 404（切换路由后） | Traefik 跨 namespace middleware 被禁用 | 开 `allowCrossNamespace` 或把 middleware 放到同 namespace |
| 502/503 | oauth2-proxy 的 upstream 不通 | 检查 Service/DNS/端口 |
| `cookie_secret must be 16, 24, or 32 bytes` | cookie secret 长度不对 | 用 `openssl rand -hex 16` |
| 登录后 404 `page not found`（Traefik） | upstream 根路径 404 / API 未开 | 开 `--api.insecure=true`，把 `/` 重定向到 `/dashboard/` |
| 角色一直是 Viewer | `groups` claim 缺失或路径不匹配 | 解码 ID token，修正映射 |
| GitLab 创建 Application 500 | 数据库迁移未完成 | 跑 `gitlab-rake db:migrate` |
| 登录后跳到 `/` 而不是原页面 | oauth2-proxy 没带 `rd` | 可接受；或配置 `rd` |

### 17. 回滚

#### 17.1 单个 UI 回滚到 basicAuth

把 IngressRoute 的 service 改回原 UI，并挂回 basicAuth middleware：

```yaml
middlewares:
  - name: hubble-ui-auth
services:
  - name: hubble-ui
    port: 80
```

旧的 basicAuth Middleware/Secret 仍然保留。

#### 17.2 关闭 oauth2-proxy

```bash
kubectl -n argocd patch application platform-ui --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 修改 IngressRoute 回 basicAuth，再恢复 auto-sync
```

#### 17.3 Ceph

仍然使用本地账号，不影响。

### 18. 安全清单

- [ ] GitLab 尽快上 TLS（当前是 HTTP）；
- [ ] 生产入口使用可信证书（Traefik 默认自签）；
- [ ] Sealed Secrets 私钥离线备份；
- [ ] 所有 client secret / cookie secret 不进 Git；
- [ ] 保留本地 admin 作为 break-glass；
- [ ] 限制 oauth2-proxy 的 `--trusted-proxy-ip`（当前未设置，信任所有 X-Forwarded-*）；
- [ ] 为 GitLab/Keycloak 开启 MFA；
- [ ] 定期轮换 client secret 和 cookie secret；
- [ ] 监控 oauth2-proxy `/ping` 和登录失败日志。

### 19. 监控与日志

| 组件 | 检查 |
|---|---|
| oauth2-proxy | `kubectl -n oauth2-proxy get pods`；`/ping`；日志 |
| Traefik | `kubectl -n traefik logs deploy/traefik`；router 错误 |
| Grafana | `kubectl -n monitoring logs deploy/prometheus-grafana -c grafana` |
| ArgoCD | `kubectl -n argocd logs deploy/argocd-server` |
| Harbor | Harbor 日志/Harbor API `/api/v2.0/systeminfo` |
| GitLab | GitLab 日志、OAuth Application 列表 |

### 20. GitOps 边界

| 资源 | 管理方式 |
|---|---|
| Grafana OIDC 配置 | `platform/monitoring/values.yaml` |
| Grafana client secret | `platform/monitoring/stack/sealedsecret-grafana-oauth.yaml` |
| ArgoCD OIDC 配置 | `platform/argocd/values.yaml`（Helm bootstrap） |
| ArgoCD client secret | `platform/argocd/sealedsecret-argocd-oauth.yaml` |
| oauth2-proxy | `platform/sso/oauth2-proxy/`（Helm chart + ArgoCD App） |
| UI IngressRoute | `platform/ui/` |
| Harbor OIDC | 外部 Harbor DB，不在 Git |
| GitLab OAuth Application | 外部 GitLab，不在 Git |
| Ceph SAML | 待 Keycloak，不在 Git |

---

## 附录：常用命令

```bash
# 查看所有 OAuth Application
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  http://192.168.67.201/api/v4/applications | jq .

# 生成 32 字符 cookie secret
openssl rand -hex 16

# 查看 oauth2-proxy 日志
kubectl -n oauth2-proxy logs deploy/oauth2-proxy-hubble --tail=100

# 测试登录跳转
curl -sk --resolve hubble.xyz:443:10.0.0.252 \
  -o /dev/null -w '%{http_code} %{redirect_url}\n' https://hubble.xyz/

# 测试 client secret
# （见 15.3）
```
