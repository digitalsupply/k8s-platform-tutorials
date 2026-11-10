# Grafana SSO / LDAP 接入方案

> 目标：把 `https://grafana.k8s.local` 的登录从本地 admin 账号切换为统一身份认证
> 当前 Grafana：12.4.3（OSS），kube-prometheus-stack 83.7.0
> 最后更新：2026-11-10
> 密保前提：所有 client secret / bind password 必须走 SealedSecret，禁止明文入库

## 1. SSO、LDAP、OIDC 到底是什么

| 名词 | 是什么 | 在 Grafana 里的位置 |
|---|---|---|
| **SSO** | 单点登录：多个系统信任同一个身份提供方（IdP），登录一次即可访问全部 | 一种效果，不是协议 |
| **LDAP** | 目录访问协议。AD（Windows 域）本质就是 LDAP + Kerberos。存用户、组、邮箱 | `[auth.ldap]` + `ldap.toml` |
| **OIDC / OAuth2** | 基于 HTTP 的认证/授权协议。IdP 签发 token，应用校验 token 并读取用户/组声明 | `[auth.generic_oauth]` |
| **SAML** | 企业常用的另一种 SSO 协议 | **Grafana OSS 不支持，只有 Enterprise/Cloud 支持** |

两种接入模式：

```text
模式 1（直连目录）  Grafana ──LDAP──> AD / OpenLDAP
                    优点：组件少；缺点：Grafana 自己处理密码、没有 MFA、只能覆盖 Grafana

模式 2（联邦 IdP）  Grafana ──OIDC──> Keycloak / Dex / GitLab ──LDAP──> AD / OpenLDAP
                    优点：统一 SSO、MFA、组映射、以后 ArgoCD/Harbor/GitLab 都能接
                    缺点：多一个需要运维的组件
```

**推荐模式 2。** LDAP 只在“已经有现成 AD/OpenLDAP 且短期不想引入 IdP”时才直连。

## 2. 当前集群能不能接？——能

实测结果（2026-11-10）：

| 检查项 | 结果 | 影响 |
|---|---|---|
| Grafana 版本 | 12.4.3 OSS | 支持 OIDC + LDAP；不支持 SAML |
| 集群内 LDAP/AD | 未发现 | 方案 C 需要一个外部目录服务 |
| ArgoCD Dex | Pod 在跑，但 `argocd-cm` 没有 `dex.config`，无 connector | 目前不能当 IdP 用 |
| 外部 GitLab | `http://192.168.67.201`，OIDC discovery 返回 200 | 可直接作为方案 A 的 IdP |
| Grafana Pod → GitLab | `http://192.168.67.201/.well-known/openid-configuration` = 200，26ms | 网络通，token 交换没问题 |
| `grafana.k8s.local` | IngressRoute 已存在，HTTPS 使用 Traefik 默认自签证书 | 登录可用，浏览器会提示证书 |
| `sso.k8s.local` | 未配置 | 方案 B 需要加 DNS / hosts |

结论：**能接。** 有三条落地路径：

| 方案 | 新增组件 | 适用场景 | 工作量 |
|---|---|---|---|
| **A. GitLab OIDC** | 0 | 团队本来就用 GitLab，想最快让 Grafana 单点登录 | 0.5 天 |
| **B. Keycloak** | Keycloak + PostgreSQL | 要做统一 SSO，未来接 AD、ArgoCD、Harbor、GitLab | 1～2 天 |
| **C. Grafana 直连 LDAP/AD** | 0（需已有目录） | 公司已有 AD，且只关心 Grafana | 0.5 天 |

推荐顺序：**先做 A 验证链路，再评估 B 做长期统一身份；有 AD 时 B 通过 User Federation 对接 AD。**

---

## 3. 方案 A：GitLab OIDC（最快，零新增组件）

> 前提：GitLab 版本支持 OIDC discovery（当前实例已确认支持），Grafana Pod 能访问 GitLab。

### 3.1 在 GitLab 创建 OAuth 应用

推荐由 GitLab 管理员在 **Admin Area → Applications** 创建（用户级应用也可以，但管理员应用更稳定）：

| 字段 | 值 |
|---|---|
| Name | `grafana` |
| Redirect URI | `https://grafana.k8s.local/login/generic_oauth` |
| Scopes | `openid`、`profile`、`email` |
| Confidential | 勾选 |

创建后保存 **Application ID** 和 **Secret**（Secret 只显示一次）。

> 也可以用仓库里的 `scripts/gitlab-create-grafana-oauth-app.sh` 一步完成
> “创建 Application + 生成 SealedSecret”，脚本不会把 secret 打印到终端。

也可以走 API（需要 admin token）：

```bash
curl --request POST \
  --header "PRIVATE-TOKEN: <GITLAB_ADMIN_TOKEN>" \
  "http://192.168.67.201/api/v4/applications" \
  --data "name=grafana" \
  --data "redirect_uri=https://grafana.k8s.local/login/generic_oauth" \
  --data "scopes=openid profile email" \
  --data "confidential=true"
```

### 3.2 把 client secret 做成 SealedSecret

```bash
cd /path/to/platform-gitops

kubectl -n monitoring create secret generic grafana-oauth \
    --dry-run=client -o yaml \
    --from-literal=client-secret='<GITLAB_APPLICATION_SECRET>' \
| kubeseal \
    --namespace monitoring \
    --name grafana-oauth \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
    --format yaml \
> platform/monitoring/stack/sealedsecret-grafana-oauth.yaml
```

**必须把新文件加入 `platform/monitoring/stack/kustomization.yaml` 的 `resources`**，
否则 ArgoCD（Kustomize）不会下发这个 SealedSecret，Deployment 会一直卡在
`CreateContainerConfigError` / `PodInitializing`：

```yaml
resources:
  - sealedsecret-grafana-admin.yaml
  - sealedsecret-grafana-oauth.yaml
```

### 3.3 修改 `platform/monitoring/values.yaml`

在 `grafana:` 下追加（不要动已有字段）：

```yaml
grafana:
  # client secret 只从 Secret 注入，不写进 grafana.ini
  envValueFrom:
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
      secretKeyRef:
        name: grafana-oauth
        key: client-secret

  grafana.ini:
    users:
      # OIDC 自动创建的用户默认只读；管理员通过下面的 role_attribute_path 提升
      auto_assign_org_role: Viewer

    auth:
      # 保留本地登录表单，作为 IdP 故障时的 break-glass
      disable_login_form: false

    auth.generic_oauth:
      enabled: true
      name: GitLab
      allow_sign_up: true
      client_id: '<GITLAB_APPLICATION_ID>'
      # 多个 scope 用空格分隔；写成逗号会被当成一个 scope 而报错
      scopes: openid profile email
      auth_url: http://192.168.67.201/oauth/authorize
      token_url: http://192.168.67.201/oauth/token
      api_url: http://192.168.67.201/oauth/userinfo
      login_attribute_path: preferred_username
      name_attribute_path: name
      email_attribute_path: email
      use_pkce: true
      use_refresh_token: true
      # GitLab 把用户所属组放在 ID token 的 groups claim 里。
      # 组路径示例：digitalsupply/devops
      role_attribute_path: "contains(groups[*], 'digitalsupply/devops') && 'GrafanaAdmin' || 'Viewer'"
      role_attribute_strict: false
      allow_assign_grafana_admin: true
```

说明：

- `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` 会覆盖 `grafana.ini` 中的同名配置，Secret 不需要热更新；
- `auth_url` 是浏览器访问的地址，必须是用户能打开的地址；
- `token_url` / `api_url` 是 Grafana Pod 访问的地址，可以用内网 IP；
- `oauth_auto_login` 保持默认 `false`，确认 SSO 可用后再考虑开启；
- 若 GitLab 返回的 `groups` 不是数组（老版本），把 `role_attribute_path` 先写成 `"'Viewer'"`，再手工把第一个管理员提升为 Admin。

### 3.4 提交、同步、验证

```bash
git add platform/monitoring/values.yaml \
        platform/monitoring/stack/sealedsecret-grafana-oauth.yaml
git commit -m "feat(monitoring): add GitLab OIDC login for grafana"
git push

kubectl -n argocd annotate application platform-monitoring-stack \
  argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd get application platform-monitoring-stack -w
```

验证：

```bash
# 配置已进入 ConfigMap
kubectl -n monitoring get cm prometheus-grafana -o yaml | grep -A20 "auth.generic_oauth"

# Pod 已拿到 client secret
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'test -n "$GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET" && echo ok'

# Grafana 能访问 GitLab
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" http://192.168.67.201/.well-known/openid-configuration'
```

浏览器打开 `https://grafana.k8s.local/login`，应出现 **Sign in with GitLab**。首次登录后：

- 用户自动创建，默认 `Viewer`；
- 属于 `digitalsupply/devops` 组的用户应为 `GrafanaAdmin`；
- 本地 `admin` 账号仍可登录，用于 break-glass。

### 3.5 回滚

把 `grafana.ini` 里的 `auth.generic_oauth.enabled` 改为 `false`，提交推送即可。
OAuth 创建的用户会保留在数据库里，不影响本地 admin 登录。

---

## 4. 方案 B：Keycloak（统一 SSO，长期方案）

> 适合：有 AD/OpenLDAP 需要联邦、未来要让 ArgoCD/Harbor/GitLab 共用一套身份。
> 组件：Keycloak 26.x + PostgreSQL（复用现有 CNPG Operator）。

### 4.1 目录结构（建议）

```text
platform/keycloak/
├── namespace.yaml
├── database.yaml                 # CNPG Cluster keycloak-db
├── keycloak.yaml                 # Deployment + Service
├── ingress.yaml                  # sso.k8s.local
├── realm-configmap.yaml          # realm platform + client grafana/argocd
├── sealedsecret-admin.yaml       # Keycloak 管理员密码
└── sealedsecret-oidc.yaml        # Grafana client secret
```

ArgoCD Application 放 `clusters/prod/applications/platform-keycloak.yaml`，sync-wave 设在 `platform-monitoring-stack` 之前（例如 `-5`）。

### 4.2 数据库（CNPG）

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
  namespace: keycloak
spec:
  instances: 1
  storage:
    size: 5Gi
    storageClassName: ceph-rbd-sc
  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
```

CNPG 会自动生成 `keycloak-db-app` Secret，包含 `username` / `password` / `jdbc-uri`。

### 4.3 Keycloak Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.2
          args: ["start", "--import-realm"]
          env:
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://keycloak-db-rw.keycloak.svc:5432/keycloak
            - name: KC_DB_USERNAME
              valueFrom:
                secretKeyRef: {name: keycloak-db-app, key: username}
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef: {name: keycloak-db-app, key: password}
            - name: KC_HOSTNAME
              value: https://sso.k8s.local
            - name: KC_HTTP_ENABLED
              value: "true"
            - name: KC_PROXY_HEADERS
              value: xforwarded
            - name: KC_HEALTH_ENABLED
              value: "true"
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom:
                secretKeyRef: {name: keycloak-admin, key: username}
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: {name: keycloak-admin, key: password}
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet: {path: /health/ready, port: 9000}
            initialDelaySeconds: 20
          livenessProbe:
            httpGet: {path: /health/live, port: 9000}
            initialDelaySeconds: 60
          volumeMounts:
            - name: realm-import
              mountPath: /opt/keycloak/data/import
      volumes:
        - name: realm-import
          configMap:
            name: keycloak-realm
```

Service 与 IngressRoute：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: keycloak
  namespace: keycloak
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`sso.k8s.local`)
      services:
        - name: keycloak
          port: 8080
  tls: {}
```

> 需要把 `sso.k8s.local` 解析到 Traefik VIP（内部 DNS 或各客户端 hosts）。

### 4.4 Realm 与 Client

`realm-configmap.yaml` 的核心内容：

```json
{
  "realm": "platform",
  "enabled": true,
  "displayName": "Platform SSO",
  "sslRequired": "external",
  "registrationAllowed": false,
  "roles": {
    "realm": [
      {"name": "platform-admin"},
      {"name": "grafana-admin"}
    ]
  },
  "groups": [
    {"name": "platform-admins"},
    {"name": "platform-viewers"}
  ],
  "clients": [
    {
      "clientId": "grafana",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "PLACEHOLDER",
      "redirectUris": ["https://grafana.k8s.local/login/generic_oauth"],
      "webOrigins": ["https://grafana.k8s.local"],
      "standardFlowEnabled": true,
      "attributes": {"pkce.code.challenge.method": "S256"},
      "protocolMappers": [
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "claim.name": "groups",
            "full.path": "true",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true"
          }
        }
      ]
    }
  ]
}
```

realm import 不会替换环境变量，所以 `secret` 先用占位值，首次启动后用一次性 Job 写入真实 secret：

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-bootstrap-grafana-client
  namespace: keycloak
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: kcadm
          image: quay.io/keycloak/keycloak:26.2
          command: ["/bin/sh", "-ec"]
          args:
            - |
              /opt/keycloak/bin/kcadm.sh config credentials \
                --server http://keycloak:8080 --realm master \
                --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD"
              CID=$(/opt/keycloak/bin/kcadm.sh get clients -r platform \
                -q clientId=grafana --fields id --format csv --noquotes | tail -1)
              /opt/keycloak/bin/kcadm.sh update clients/$CID -r platform \
                -s secret="$GRAFANA_CLIENT_SECRET"
          env:
            - name: KC_ADMIN_USER
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: username}}
            - name: KC_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: password}}
            - name: GRAFANA_CLIENT_SECRET
              valueFrom: {secretKeyRef: {name: grafana-oauth, key: client-secret}}
```

### 4.5 Grafana 接 Keycloak

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
      disable_login_form: false
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      scopes: openid profile email
      auth_url: https://sso.k8s.local/realms/platform/protocol/openid-connect/auth
      # token/api 走集群内 Service，避免被 Traefik 自签证书卡住
      token_url: http://keycloak.keycloak.svc:8080/realms/platform/protocol/openid-connect/token
      api_url: http://keycloak.keycloak.svc:8080/realms/platform/protocol/openid-connect/userinfo
      use_pkce: true
      role_attribute_path: "contains(groups[*], '/platform-admins') && 'GrafanaAdmin' || 'Viewer'"
      role_attribute_strict: false
      allow_assign_grafana_admin: true
```

要点：

- 浏览器走 `https://sso.k8s.local`，Grafana 后端走 `http://keycloak.keycloak.svc:8080`，两边都不受自签证书影响；
- Keycloak 的 `KC_HOSTNAME` 固定为外部地址，保证 `iss` / 回调一致；
- `full.path=true` 让组名带前导 `/`，所以映射写 `/platform-admins`。

### 4.6 联邦 AD / OpenLDAP（有域环境时）

Keycloak Admin Console → **User Federation → Add provider → LDAP**：

| 字段 | AD 示例 | OpenLDAP 示例 |
|---|---|---|
| Vendor | Active Directory | Other |
| Connection URL | `ldaps://ad.corp.local:636` | `ldap://openldap.corp.local:389` |
| Bind DN | `CN=svc-keycloak,OU=ServiceAccounts,DC=corp,DC=local` | `cn=admin,dc=corp,dc=local` |
| Bind credential | 走 SealedSecret 注入，不要写进 Git | 同左 |
| Users DN | `OU=Users,DC=corp,DC=local` | `ou=people,dc=corp,dc=local` |
| Username attribute | `sAMAccountName` | `uid` |
| UUID attribute | `objectGUID` | `entryUUID` |
| Group DN | `OU=Groups,DC=corp,DC=local` | `ou=groups,dc=corp,dc=local` |
| Group name attribute | `cn` | `cn` |
| Group membership | `member` | `member` |

联邦后：

- AD 组会同步成 Keycloak 组；
- Grafana 的 `groups` claim 直接来自 Keycloak；
- 需要 MFA 时在 Keycloak 里配 OTP/WebAuthn，Grafana 不需要改。

### 4.7 后续：ArgoCD 也接入同一 IdP（可选）

```yaml
# argocd-cm
url: https://argocd.devops.com
oidc.config: |
  name: Keycloak
  issuer: https://sso.k8s.local/realms/platform
  clientID: argocd
  clientSecret: $argocd-oidc:client-secret
  requestedScopes: ["openid", "profile", "email", "groups"]
  requestedIDTokenClaims:
    groups:
      essential: true
```

`argocd-rbac-cm`：

```yaml
policy.csv: |
  g, /platform-admins, role:admin
```

> 注意：ArgoCD 会严格校验 OIDC issuer 的 TLS 证书。Traefik 默认自签证书会导致
> `x509: certificate signed by unknown authority`。要么给 `sso.k8s.local` 签发内部 CA
> 并让 ArgoCD 信任，要么暂时只让 Grafana 接入（Grafana 的 token/api 走内网 HTTP）。

---

## 5. 方案 C：Grafana 直连 LDAP / AD

前提：已有一个 Grafana Pod 能访问的 LDAP/AD，且有只读服务账号。

Grafana 的 Helm chart 已经预留了这条路：Secret `prometheus-grafana-admin` 里本来就有
`ldap-toml` 字段（当前为空），chart 的 `grafana.ldap.existingSecret` 正是读这个 key。

### 5.1 填写 ldap.toml

```toml
verbose_logging = false

[[servers]]
host = "ad.corp.local"
port = 636
use_ssl = true
start_tls = false
ssl_skip_verify = false

bind_dn = "CN=svc-grafana,OU=ServiceAccounts,DC=corp,DC=local"
bind_password = "<BIND_PASSWORD>"

search_filter = "(&(objectClass=user)(sAMAccountName=%s))"
search_base_dns = ["OU=Users,DC=corp,DC=local"]

[servers.attributes]
username = "sAMAccountName"
member_of = "memberOf"
email = "mail"
name = "displayName"

[[servers.group_mappings]]
group_dn = "CN=Grafana Admins,OU=Groups,DC=corp,DC=local"
org_role = "Admin"

[[servers.group_mappings]]
group_dn = "*"
org_role = "Viewer"
```

把完整内容写入 Secret 的 `ldap-toml` 字段，再重新 seal：

```bash
kubectl -n monitoring create secret generic prometheus-grafana-admin \
    --dry-run=client -o yaml \
    --from-literal=admin-user=admin \
    --from-literal=admin-password='<当前密码>' \
    --from-file=ldap-toml=./ldap.toml \
| kubeseal --merge-into platform/monitoring/stack/sealedsecret-grafana-admin.yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system
```

### 5.2 启用 LDAP

```yaml
grafana:
  ldap:
    enabled: true
    existingSecret: prometheus-grafana-admin   # chart 读取其中的 ldap-toml
  grafana.ini:
    auth.ldap:
      enabled: true
      allow_sign_up: true
      config_file: /etc/grafana/ldap.toml
```

> 注意：`ldap-toml` 为空时不要打开 `ldap.enabled`，否则 Grafana 会启动失败。
> bind 密码存放在 SealedSecret 里，虽然是密文，仍建议使用最小权限只读账号。

---

## 6. 验证清单

无论走哪个方案，上线后至少确认：

```bash
# 1. Grafana 配置生效
kubectl -n monitoring get cm prometheus-grafana -o yaml | grep -E "generic_oauth|auth.ldap"

# 2. Secret 已注入
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'env | grep -E "GF_AUTH_(GENERIC_OAUTH|LDAP)" | sed "s/=.*/=<set>/"'

# 3. Grafana 能访问 IdP
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" <IdP discovery URL>'

# 4. 本地 admin 仍可登录（break-glass）
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -u admin:<密码> http://127.0.0.1:3000/api/user'

# 5. 新用户角色正确
#    浏览器登录后：Administration → Users，确认 org role
```

常见问题：

| 现象 | 原因 | 处理 |
|---|---|---|
| 点登录后 400 `redirect_uri_mismatch` | GitLab/Keycloak 里回调地址与 `root_url` 不一致 | 必须是 `https://grafana.k8s.local/login/generic_oauth` |
| 回调后 500 / `token exchange failed` | Grafana 访问不到 token_url，或 client secret 不对 | 在 Pod 内 curl token_url；检查 Secret |
| `x509: certificate signed by unknown authority` | IdP 用自签证书 | keycloak 走内网 http；或给内部 CA 加信任 |
| 登录成功但角色一直是 Viewer | `groups` claim 缺失或路径不匹配 | 解码 ID token 看 `groups`，修正 `role_attribute_path` |
| 自动跳转 SSO 后本地登录消失 | 开了 `oauth_auto_login` | 关掉，保留 `admin` break-glass |

## 7. 改造建议（前提不满足时）

1. **GitLab 目前是 HTTP**：OAuth 授权码和 client secret 会在内网明文传输。
   建议给 GitLab 加 TLS（内部 CA 或 Let's Encrypt DNS-01），再切换 `auth_url` / `token_url` 为 HTTPS。
2. **统一 DNS**：把 `grafana.k8s.local`、`sso.k8s.local`、`argocd.devops.com` 都放进内部 DNS，
   不要依赖客户端 hosts，否则 SSO 回调会在部分机器上失败。
3. **证书**：Traefik 默认自签证书只能“能用”，不适合作为长期 SSO 入口。
   建议用 cert-manager 建一个内部 CA（或企业 CA）签发 `*.k8s.local`。
4. **Sealed Secrets 私钥**：必须离线备份。私钥丢失后所有 SealedSecret（包括 OIDC client secret）都无法恢复。
5. **网络策略**：如果后续上 NetworkPolicy，记得放行 Grafana → IdP 的 443/8080，
   以及浏览器 → IdP 的入口。
6. **身份源治理**：先确定“谁是企业身份源”（GitLab 账号 / AD / 独立 Keycloak）。
   不要让 Grafana 同时开启 LDAP 和 OIDC，容易出现同名用户和角色冲突。
7. **分阶段上线**：
   - 第一阶段：OIDC 开启，但保留本地 admin，`oauth_auto_login=false`；
   - 第二阶段：验证组映射和 MFA；
   - 第三阶段：再考虑关闭本地登录表单（仍保留 admin 应急）。

## 8. 参考

- Grafana Generic OAuth：<https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/>
- Grafana LDAP：<https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/ldap/>
- GitLab OIDC：<https://docs.gitlab.com/ee/integration/openid_connect_provider.html>
- Keycloak Server Admin：<https://www.keycloak.org/docs/latest/server_admin/>
- 同仓库：`GRAFANA-PASSWORD-ROTATION.md`、`platform/secrets/README.md`
