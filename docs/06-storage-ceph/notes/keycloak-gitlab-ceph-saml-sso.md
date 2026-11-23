# Keycloak 结合 GitLab OIDC 接管 Ceph Dashboard SSO（实战记录）

> **场景**：Ceph Dashboard（Reef 18.2.8）只支持 SAML 2.0，不支持 OIDC。
> GitLab 是 OIDC IdP，不是 SAML IdP。用 **Keycloak 做协议转换桥梁**：
> GitLab（OIDC IdP）→ Keycloak（OIDC 客户端 + SAML IdP）→ Ceph Dashboard（SAML SP）。
> **日期**：2026-11-22（2026-11-23 完成 SAML 链路打通）
> **环境**：GitLab CE 19.5.0（192.168.67.201）；Keycloak 26.3.4（K8s 集群内）；
> Ceph Reef 18.2.8（ceph-01/02/03，10.0.0.31/41/51）
> **结果**：Ceph Dashboard ← Keycloak SAML 登录链路已端到端验证通过

---

## 一、技术选型原因

| 方案 | 说明 | 结论 |
|---|---|---|
| Ceph Dashboard 直接接 GitLab | Ceph Reef Dashboard 只支持 SAML 2.0，GitLab 是 OIDC IdP，**协议不匹配** | ❌ 不可行 |
| 部署 Keycloak 做协议转换 | Keycloak 同时支持 OIDC 客户端（对接 GitLab）和 SAML IdP（给 Ceph），**协议转换桥梁** | ✅ 采用 |
| Keycloak 直接做用户存储 | 不需要，用户仍在 GitLab，Keycloak 只做协议转换和会话管理 | — |

**架构**：

```
用户 → Ceph Dashboard（SAML SP）
           ↓ SAML AuthnRequest
      Keycloak（SAML IdP + OIDC 客户端）
           ↓ OIDC 授权码流程
      GitLab（OIDC IdP）← 用户登录、授权
```

Keycloak 作为中间层：对 Ceph 暴露 SAML IdP，对 GitLab 作为 OIDC 客户端，实现协议转换。

## 二、实施过程

### 步骤 1：Ceph 侧准备

Ceph Dashboard SAML SSO 的前置条件：

1. **Ceph mgr 安装 python3-saml**：Ceph Dashboard 的 SAML 认证由 mgr 模块内的 Python 代码处理，
   需要 `python3-saml` 库。
2. **确认 mgr 运行方式**：本集群 Ceph 用 **cephadm + Docker 容器**部署，mgr 运行在容器内。
   `python3-saml` 需要安装在 **mgr 容器内**，不是宿主机。

**验证**：

```bash
# SSH 到 active mgr 主机（ceph-02，10.0.0.41）
ssh root@10.0.0.41

# 找到 mgr 容器
docker ps | grep mgr

# 容器内验证 python3-saml
docker exec <mgr-container> python3 -c "from onelogin.saml2.auth import OneLogin_Saml2_Auth; print('OK')"
```

> **结果**：`python3-saml` 已安装在 mgr 容器内，`onelogin.saml2` 可正常导入。

### 步骤 2：部署 Keycloak

在 K8s 集群内部署 Keycloak，用 NodePort 暴露给 Ceph 集群访问。

**Deployment**：

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
          valueFrom:
            secretKeyRef: {name: keycloak-admin-secret, key: keycloak-admin-password}
        - name: KC_HEALTH_ENABLED
          value: "true"
        # PostgreSQL（cnpg-system/pg16-ceph 集群）
        - name: KC_DB
          value: "postgres"
        - name: KC_DB_URL
          value: "jdbc:postgresql://pg16-ceph-rw.cnpg-system.svc.cluster.local:5432/keycloak"
        - name: KC_DB_USERNAME
          value: "keycloak"
        - name: KC_DB_PASSWORD
          value: "Keycloak@Db123"
        # 外部访问地址（元数据里的 entityID/SSO URL 都基于它生成）
        - name: KC_HOSTNAME
          value: "http://10.0.0.121:32669"
        - name: KC_HOSTNAME_STRICT
          value: "false"
        ports:
        - containerPort: 8080
```

**Service（NodePort）**：

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
```

**访问方式**：Ceph 集群通过 `http://<K8s节点IP>:<NodePort>` 访问 Keycloak。

### 步骤 3：GitLab 侧创建 OAuth 应用

Keycloak 对接 GitLab OIDC，需要在 GitLab 创建 OAuth 应用，记录 client_id 和 client_secret。

**redirect URI**：`http://<K8s节点IP>:<NodePort>/realms/ceph-sso/broker/gitlab/endpoint`

### 步骤 4：Keycloak 配置

1. **导入 realm**（含 GitLab OIDC 上游）：

```json
{
  "enabled": true,
  "realm": "ceph-sso",
  "displayName": "Ceph SSO",
  "identityProviders": [
    {
      "providerId": "oidc",
      "alias": "gitlab",
      "displayName": "GitLab",
      "config": {
        "issuer": "http://192.168.67.201",
        "authorizationUrl": "http://192.168.67.201/oauth/authorize",
        "tokenUrl": "http://192.168.67.201/oauth/token",
        "userInfoUrl": "http://192.168.67.201/oauth/userinfo",
        "clientId": "<GitLab OAuth client_id>",
        "clientSecret": "<GitLab OAuth client_secret>",
        "authType": "client_secret_basic",
        "loginFlow": "browser",
        "validateSignature": "false"
      }
    }
  ]
}
```

通过 Admin API 导入：`POST /admin/realms`

2. **创建 SAML client**（给 Ceph Dashboard）：

```json
{
  "clientId": "https://10.0.0.41:8443/auth/saml2/metadata",
  "name": "Ceph Dashboard",
  "enabled": true,
  "protocol": "saml",
  "publicClient": false,
  "frontchannelLogout": true,
  "redirectUris": ["https://10.0.0.41:8443/auth/saml2*"],
  "attributes": {
    "saml.client.signature": "true",
    "saml.signing.certificate": "<SP 证书 Base64，去掉 PEM 头尾>",
    "saml.encryption.certificate": "<SP 证书 Base64，去掉 PEM 头尾>",
    "saml.encrypt": "true",
    "saml.server.signature": "true",
    "saml.assertion.signature": "true",
    "saml.authnstatement": "true",
    "saml_name_id_format": "username",
    "saml.force.post.binding": "true",
    "saml_assertion_consumer_url_post": "https://10.0.0.41:8443/auth/saml2",
    "saml_assertion_consumer_url_redirect": "https://10.0.0.41:8443/auth/saml2",
    "saml_single_logout_service_url_redirect": "https://10.0.0.41:8443/auth/saml2/logout"
  },
  "protocolMappers": [
    {
      "name": "uid",
      "protocol": "saml",
      "protocolMapper": "saml-user-attribute-mapper",
      "config": {
        "user.attribute": "username",
        "attribute.name": "uid",
        "attribute.nameformat": "Basic",
        "friendly.name": "uid",
        "jsonType.label": "String"
      }
    }
  ]
}
```

几个关键点：

- **`clientId` 必须等于 Ceph 的 SP EntityID**：
  `<dashboard_base_url>/auth/saml2/metadata`。不是随便起个名字。
- **`uid` 属性映射**：Ceph 默认从断言的 `uid` 属性取用户名
  （`idp_username_attribute`），所以要把 Keycloak 的 `username` 映射成 `uid`。
- **`role_list` scope 必须移除**（见坑 17），否则断言里有重复的 `Role` 属性。

通过 Admin API 创建：`POST /admin/realms/ceph-sso/clients`

3. **获取 SAML IdP 元数据**：Ceph Dashboard 配置 SAML 需要 Keycloak 的：
   - IdP Entity ID
   - IdP SSO URL
   - IdP 签名证书

   **正确路径**（Keycloak 26 实测）：

   ```bash
   GET /realms/ceph-sso/protocol/saml/descriptor
   ```

   > 注意：不是 `/protocol/saml/metadata`，也不是 `/protocol/saml/idp/metadata`。
   > 后两者在 Keycloak 26 中均返回 404（见坑 6）。

### 步骤 5：Ceph Dashboard 配置 SAML

Ceph Dashboard 的 SAML 配置不是 `ceph config set mgr ...`，而是专用命令
`ceph dashboard sso setup saml2`：

```bash
# 在能执行 ceph 命令的节点（ceph-01）上执行
ceph dashboard sso setup saml2 \
  https://10.0.0.41:8443 \
  http://10.0.0.121:32669/realms/ceph-sso/protocol/saml/descriptor \
  uid \
  '' \
  /tmp/saml_sp.crt \
  /tmp/saml_sp.key
```

参数顺序：

```
ceph dashboard sso setup saml2 <ceph_dashboard_base_url> <idp_metadata> \
  [<idp_username_attribute>] [<idp_entity_id>] [<sp_x_509_cert>] [<sp_private_key>]
```

- `ceph_dashboard_base_url`：Dashboard 的外部访问地址，Ceph 用它拼出
  SP EntityID（`<base>/auth/saml2/metadata`）和 ACS（`<base>/auth/saml2`）
- `idp_metadata`：IdP 元数据 URL、`file://` 路径或 XML 文本
- `idp_username_attribute`：从断言里取用户名的属性名（默认 `uid`）
- `sp_x_509_cert` / `sp_private_key`：SP 证书和私钥文件路径。
  **必须两个都给或都不给**：不给时 Ceph 不签 AuthnRequest，也不要求断言签名/加密；
  给定时 Ceph 会签 AuthnRequest，并要求断言签名 + 加密。

> **重要**：这两个路径由 **mgr 进程**读取（不是 ceph CLI 读取）。
> 文件必须存在于 **mgr 容器内**，且 mgr 运行用户（`ceph`）可读。

验证：

```bash
ceph dashboard sso show saml2
curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.0.41:8443/auth/saml2/login
# 303 → 跳转到 Keycloak
```

### 步骤 6：端到端验证

不打开浏览器也能验证整条 SAML 链路（Keycloak 本地用户 → Ceph）。
用一个带 Cookie 的 Python 脚本走完 4 步：

```python
import urllib.request, urllib.parse, http.cookiejar, ssl, re, html

ctx = ssl.create_default_context(); ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
cj = http.cookiejar.CookieJar()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a): return None

op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                 urllib.request.HTTPCookieProcessor(cj), NoRedirect)

def req(url, data=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    r = urllib.request.Request(url, data=body)
    try:
        x = op.open(r, timeout=20)
        return x.getcode(), x.headers, x.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode()

# 1. Ceph → Keycloak（拿 SAMLRequest 重定向）
_, h, _ = req("https://10.0.0.41:8443/auth/saml2/login")
loc = h["Location"]

# 2. 打开 Keycloak 登录页，解析表单
_, _, page = req(loc)
action = re.search(r'<form[^>]*action="([^"]+)"', page).group(1)

# 3. 提交用户名密码，拿 SAMLResponse
_, _, page = req(html.unescape(action), {"username": "admin", "password": "Ceph@Admin123"})
fields = dict(re.findall(r'name="([^"]+)" value="([^"]*)"', page))
acs = html.unescape(re.search(r'<form[^>]*action="([^"]+)"', page).group(1))

# 4. POST 到 Ceph ACS
code, h, _ = req(acs, {"SAMLResponse": fields["SAMLResponse"],
                       "RelayState": fields.get("RelayState", "")})
print(code, h.get("Location"))
```

实测结果：

```
1. ceph login: 303 -> keycloak
2. keycloak login page: 200 form
3. post credentials: 200 (含 SAMLResponse)
4. ceph ACS: 303 -> https://10.0.0.41:8443/#/login?access_token=eyJhbGciOiJIUzI1NiIs...
   ✅ 登录成功，拿到 access_token
```

GitLab 侧（broker）验证：在 Keycloak 授权 URL 后加 `&kc_idp_hint=gitlab`，
会依次跳转：

```
302 /realms/ceph-sso/broker/gitlab/login
302 http://192.168.67.201/oauth/authorize?scope=openid+profile+email&state=...
```

说明 OIDC 上游配置、GitLab OAuth 应用回调地址、scope 都正确。
最后一步需要真实 GitLab 账号在浏览器里输入密码。

## 三、踩坑点（详细）

### 坑 1：quay.io 镜像拉取极慢，docker.io 可用

**现象**：`quay.io/keycloak/keycloak:26.3.4` 拉取超过 7 分钟仍未完成，Pod 一直 `ContainerCreating`。

**原因**：quay.io 镜像仓库网络受限，拉取速度极慢。

**解决**：切换到 `docker.io/keycloak/keycloak:26.3.4`，拉取成功，Pod 正常启动。

### 坑 2：Keycloak 26 的 health 端点在 9000 端口，不在 8080

**现象**：就绪探针探测 `8080/health/ready` 返回 **404**，Pod 一直不就绪。

**原因**：Keycloak 26 使用 Quarkus，管理接口在 **9000 端口**，health 端点 `/health/ready`
在管理接口上，不在 8080 公共服务端口。

**解决**：
- 方案 A：就绪探针改为探测 `/realms/master`（8080 端口，返回 200 即就绪）
- 方案 B：添加 `KC_HEALTH_ENABLED=true` 并在 9000 端口探测

**实际采用**：就绪探针改为探测 `/realms/master`，简单可靠。

### 坑 3：Keycloak 26 的 Admin API 在 8080 端口

**现象**：`/admin/realms/master/identity-providers` 返回 404。

**排查**：探测发现 `/admin/realms/master` 返回 **401**（需要认证，路径存在），
`/admin/realms/master/clients` 返回 **200**。9000 端口的 `/admin/` 返回 404。

**结论**：Admin REST API 在 **8080 端口**，不在 9000 管理端口。
9000 是 Quarkus 管理接口（health/metrics），不是 Admin REST API。

### 坑 4：Keycloak 26 的 OIDC 上游 providerId 是 `oidc`，不是 `openid-connect`

**现象**：Realm 导入返回 **500**，日志报 `Invalid identity provider id [openid-connect]`。

**原因**：Keycloak 26 的 OIDC 身份提供者 `providerId` 是 `oidc`，不是旧版的 `openid-connect`。

**解决**：将 JSON 中的 `providerId` 改为 `oidc`，重新导入成功（201）。

### 坑 5：Keycloak dev 模式用 H2 内存数据库，Pod 重启后数据全丢

**现象**：修改 Deployment 参数（如添加 `--features=saml`）导致 Pod 重启后，
导入的 realm、创建的 SAML client **全部丢失**。

**原因**：`start-dev` 模式使用 **H2 内存数据库**，数据不持久化，Pod 重启即清空。

**解决**：
- 生产环境应使用 PostgreSQL（KC_DB=postgres + 数据库连接配置）
- 修改 Deployment 参数前需重新导入 realm 和创建 client
- 或用 initContainer 在启动时自动导入

### 坑 6：Keycloak 26 的 SAML 元数据端点不是 `/metadata`（已解决）

**现象**：`/realms/ceph-sso/protocol/saml/metadata`、
`/realms/ceph-sso/protocol/saml/idp/metadata` 等路径全部返回 **404**，
导致一度误判为"Keycloak 26 的 SAML 端点未注册"。

**真实原因**：**路径写错了**。Keycloak 的 SAML IdP 元数据端点是：

```
GET /realms/{realm}/protocol/saml/descriptor
```

实测：

| 路径 | 结果 |
|---|---|
| `/realms/ceph-sso/protocol/saml/descriptor` | **200**（3.4 KB XML） |
| `/realms/ceph-sso/protocol/saml/metadata` | 404 |
| `/realms/ceph-sso/protocol/saml/idp/metadata` | 404 |
| `/realms/ceph-sso/protocol/saml/idp/descriptor` | 404 |
| `/realms/ceph-sso/protocol/saml` | 400（存在，需要 SAMLRequest 参数） |

`descriptor` 返回的就是标准 `md:EntityDescriptor`，包含：

```xml
<md:EntityDescriptor entityID="http://10.0.0.121:32669/realms/ceph-sso">
  <md:IDPSSODescriptor WantAuthnRequestsSigned="true" ...>
    <md:KeyDescriptor use="signing">...</md:KeyDescriptor>
    <md:SingleSignOnService Binding="...HTTP-Redirect"
        Location=".../realms/ceph-sso/protocol/saml"/>
  </md:IDPSSODescriptor>
</md:EntityDescriptor>
```

**教训**：Keycloak 的 OIDC 用 `/.well-known/openid-configuration`，
SAML 用 `/protocol/saml/descriptor`。**不要凭直觉猜 `/metadata`**，
直接看官方文档或用 `descriptor`。

### 坑 7：GitLab OAuth 应用创建需要 organization_id

**现象**：用 `gitlab-rails runner` 创建 OAuth 应用时，报
`PG::CheckViolation: violates check constraint "check_77eda6baaa"`。

**原因**：GitLab 19.5 的 `oauth_applications` 表有 CHECK 约束
`organization_id IS NOT NULL`，要求 OAuth 应用必须关联一个 organization。

**解决**：先用 SQL 插入一条 organization 记录，创建 OAuth 应用时指定 `organization_id`。

### 坑 8：GitLab root 密码已改，API 创建 OAuth 应用权限不足

**现象**：
- 用 root 初始密码调用 GitLab API 返回 **401 Unauthorized**（密码已改）
- 用 group token 调用 `/api/v4/applications` 返回 **insufficient_scope**（权限不足）

**原因**：root 密码已修改，initial_root_password 失效；group token 只有
`read_repository,write_repository` 权限，没有创建 OAuth 应用的权限。

**解决**：用 `gitlab-rails runner` 直接在数据库创建 OAuth 应用（绕过 API 权限）。

### 坑 9：gitlab-rails runner 以 gitlab 用户运行，不能写 /root

**现象**：`gitlab-rails runner` 执行 Ruby 脚本时，`File.write("/root/xxx.txt")` 报
`Permission denied (Errno::EACCES)`。

**原因**：`gitlab-rails runner` 以 `gitlab` 系统用户运行，没有 `/root` 目录的写权限。

**解决**：输出到 `/tmp` 目录（gitlab 用户可写）。

### 坑 10：python3-saml 的导入方式是 `onelogin.saml2`，不是 `import saml2`

**现象**：在 mgr 容器内执行 `import saml2` 报 `ModuleNotFoundError`，但
`yum install python3-saml` 显示已安装。

**原因**：python3-saml 库的导入方式是 `from onelogin.saml2.auth import OneLogin_Saml2_Auth`，
不是 `import saml2`。

**验证**：
```bash
docker exec <mgr-container> python3 -c "from onelogin.saml2.auth import OneLogin_Saml2_Auth; print('OK')"
# → OK
```

### 坑 11：PostgreSQL 主库变更，socket 连接连到备库（只读）

**现象**：通过 `kubectl exec pg16-ceph-3` 执行 `CREATE DATABASE keycloak` 报
`cannot execute CREATE DATABASE in a read-only transaction`。

**原因**：CNPG 集群的主库发生了切换。排查时发现：
- `pg16-ceph-3`：`pg_is_in_recovery() = t`（**备库**，只读）
- `pg16-ceph-4`：`pg_is_in_recovery() = f`（**主库**，可写）

之前手动提升 pg16-ceph-3 为主库，但 CNPG 控制器后来将主库切换回 pg16-ceph-4。
socket 连接连到 pg16-ceph-3（备库），自然只读。

**解决**：连到当前主库 `pg16-ceph-4` 执行 DDL。创建数据库和用户后验证通过。

### 坑 12：schema 权限不足（permission denied for schema public）

**现象**：Keycloak 连接 PostgreSQL 后，Liquibase 迁移报
`ERROR: permission denied for schema public`，Pod 反复重启。

**原因**：`keycloak` 数据库用户只有数据库级权限，没有 `public` schema 的 CREATE 权限。
PostgreSQL 中 schema 权限与数据库权限是分开的。

**解决**：在 `keycloak` 数据库的 `public` schema 上授权：
```sql
-- 注意：必须在 keycloak 数据库执行，不是 postgres 数据库
psql -U postgres -d keycloak -c "GRANT ALL ON SCHEMA public TO keycloak;"
```

> **注意**：`GRANT ALL ON SCHEMA public` 必须指定正确的数据库。
> 在 `postgres` 数据库上执行不会对 `keycloak` 数据库生效。

### 坑 13：跨命名空间 FQDN 解析

**现象**：Keycloak（`keycloak` 命名空间）连接 PostgreSQL（`cnpg-system` 命名空间）报
`java.net.UnknownHostException: pg16-ceph-rw`。

**原因**：Keycloak Pod 的 DNS 搜索域是 `keycloak.svc.cluster.local`、`svc.cluster.local`、
`cluster.local`，无法解析 `cnpg-system` 命名空间的短域名 `pg16-ceph-rw`。

**解决**：使用 FQDN：`pg16-ceph-rw.cnpg-system.svc.cluster.local`

### 坑 14：KC_DB_URL 被错误设成密码值

**现象**：Keycloak 启动报 `Driver does not support the provided URL: Keycloak@Db123`。

**原因**：用 `kubectl patch` 修改环境变量时，JSON patch 的索引指向错误，
`KC_DB_URL` 的值被替换成了 `KC_DB_PASSWORD` 的值。

**解决**：检查 Deployment 环境变量数组的索引，逐一确认每个变量的值，
用正确的索引 patch。

### 坑 15：`sp_cert_not_found_and_required`——IdP 元数据覆盖了 Ceph 的安全默认值

**现象**：SAML 配置完成后访问 `https://10.0.0.41:8443/auth/saml2/login` 返回：

```json
{"status": "400 Bad Request", "detail": "Single Sign-On is not configured."}
```

在 mgr 容器里直接实例化 python3-saml 才能看到真实原因：

```
OneLogin_Saml2_Error: Invalid dict settings: sp_cert_not_found_and_required
```

**原因链**（这是整件事最隐蔽的坑）：

1. Ceph 配置 SAML 时，自己算出 `security.authnRequestsSigned = has_sp_cert`
   （没给 SP 证书就是 `false`）；
2. 但 Keycloak 的 IdP 元数据里声明了 `WantAuthnRequestsSigned="true"`；
3. python3-saml 的 `OneLogin_Saml2_IdPMetadataParser.parse()` 会把这一条解析成
   `security.authnRequestsSigned = True`；
4. Ceph 用 `merge_settings()` 做深合并，**元数据的值优先级更高**，覆盖了 Ceph 自己的 `false`；
5. python3-saml 认为"要求签 AuthnRequest 但没有 SP 私钥" → 直接拒绝加载配置。

验证方法：

```python
from onelogin.saml2.idp_metadata_parser import OneLogin_Saml2_IdPMetadataParser as P
print(P.parse(xml)["security"])   # {'authnRequestsSigned': True}
```

**解决**：给 Ceph 提供 SP 证书和私钥，让"签名"这个要求成立。
生成自签证书（10 年）：

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/saml_sp.key -out /tmp/saml_sp.crt \
  -days 3650 -subj '/CN=ceph-dashboard'
```

然后 `ceph dashboard sso setup saml2 ... /tmp/saml_sp.crt /tmp/saml_sp.key`。

**副作用**：Ceph 同时把 `wantAssertionsSigned`、`wantAssertionsEncrypted`、
`nameIdEncrypted` 全部打开，Keycloak 侧必须配合（见坑 16）。

### 坑 16：给了 SP 证书后，Keycloak 必须开启签名校验 + 断言加密

**现象**：登录 POST 回 ACS 后返回：

```json
{"is_authenticated": false, "errors": ["invalid_response"],
 "reason": "The assertion of the Response is not encrypted and the SP requires it"}
```

**原因**：有 SP 证书时 Ceph 生成的安全配置是：

```json
{"nameIdEncrypted": true, "authnRequestsSigned": true,
 "logoutRequestSigned": true, "logoutResponseSigned": true,
 "signMetadata": true, "wantMessagesSigned": true,
 "wantAssertionsSigned": true, "wantAssertionsEncrypted": true}
```

Keycloak 客户端默认不加密断言，也不要求请求签名。

**解决**：把 SP 证书填进 Keycloak 客户端，并打开签名/加密：

| Keycloak 客户端属性 | 值 | 作用 |
|---|---|---|
| `saml.client.signature` | `true` | 要求 AuthnRequest 签名 |
| `saml.signing.certificate` | SP 证书（去掉 PEM 头尾） | 校验 AuthnRequest 签名 |
| `saml.encryption.certificate` | SP 证书（去掉 PEM 头尾） | 加密断言 |
| `saml.encrypt` | `true` | 加密断言 |
| `saml.server.signature` | `true` | 签名 Response |
| `saml.assertion.signature` | `true` | 签名 Assertion |

用 Admin API 更新（`PUT /admin/realms/ceph-sso/clients/{id}`）即可，
证书要用**去掉 `-----BEGIN/END CERTIFICATE-----` 的单行 Base64**。

> 如果不想用加密，就不要给 Ceph 传 SP 证书。两者必须一致，
> 不能"给了 SP 证书但 Keycloak 不加密"。

### 坑 17：默认 `role_list` scope 导致 `duplicated Name`

**现象**：ACS 返回 500，mgr 日志：

```
OneLogin_Saml2_ValidationError: Found an Attribute element with duplicated Name
```

**原因**：Keycloak 的 SAML 客户端默认绑定 `role_list` client scope，
它会给**每个角色输出一个 `<saml:Attribute Name="Role">`**。
测试用户属于 6 个角色 → 断言里 6 个同名 `Role` 属性。
python3-saml 认为同名 Attribute 非法，直接抛异常。

**解决**：把 `role_list` 从客户端的 default client scopes 移除：

```bash
# 先查 scope id
GET /admin/realms/ceph-sso/clients/{clientId}/default-client-scopes
# 再删除
DELETE /admin/realms/ceph-sso/clients/{clientId}/default-client-scopes/{scopeId}
```

Ceph Dashboard 不需要角色属性，移除后断言里只剩 `uid`，问题消失。

### 坑 18：不设 `KC_HOSTNAME`，元数据里全是 `127.0.0.1`

**现象**：通过 port-forward 访问时，`descriptor` 里的
`entityID="http://127.0.0.1:8090/realms/ceph-sso"`，SSO URL 也是 127.0.0.1。
Ceph 配好后浏览器会跳转到 `127.0.0.1`，登录必然失败。

**原因**：Keycloak 用请求的 Host 头生成元数据里的 URL。

**解决**：Keycloak 26 设置 `KC_HOSTNAME` 为**完整外部 URL**：

```yaml
- name: KC_HOSTNAME
  value: "http://10.0.0.121:32669"
- name: KC_HOSTNAME_STRICT
  value: "false"
```

改完后 `descriptor` 的 entityID 变成
`http://10.0.0.121:32669/realms/ceph-sso`，Ceph 侧要重新执行一次
`ceph dashboard sso setup saml2`（元数据 URL 变了）。

### 坑 19：SP 证书文件要"两处都在"，且 mgr 用户可读

**现象 1**：

```
/tmp/saml_sp.crt not valid: cannot create file in /tmp/saml_sp.crt
```

ceph CLI 侧对 `CephFilepath` 参数做本地校验，路径必须存在于**执行 ceph 命令的节点**。

**现象 2**：

```
PermissionError: [Errno 13] Permission denied: '/tmp/saml_sp.key'
```

即使 CLI 校验通过，真正读文件的是 **mgr 进程**（容器内、以 `ceph` 用户运行）。
`/tmp/saml_sp.key` 是 root 600，读不了。

**解决**：

1. 同一路径的文件在 **ceph CLI 节点**和 **mgr 容器内**都存在；
2. `chmod 644`（或改成 ceph 用户可读）。

```bash
docker cp /tmp/saml_sp.crt <mgr>:/tmp/saml_sp.crt
docker cp /tmp/saml_sp.key <mgr>:/tmp/saml_sp.key
docker exec <mgr> chmod 644 /tmp/saml_sp.key /tmp/saml_sp.crt
```

### 坑 20：GitLab 上游 `defaultScope` 只有 `openid`，拿不到用户名

**现象**：`kc_idp_hint=gitlab` 跳转到 GitLab 时 `scope=openid`。
只有 `openid` 时，Keycloak 从 GitLab 拿不到 `preferred_username`/`email`，
broker 会生成 `gitlab.<sub>` 之类的用户名，Ceph 侧找不到同名用户。

**解决**：把 IdP 的 `config.defaultScope` 改为：

```
openid profile email
```

修改后 GitLab 授权 URL 变为 `scope=openid profile email`，
Keycloak 用 `preferred_username` 作为用户名，才能和 Ceph 用户对上。

> **另外**：Ceph Dashboard 只允许**已存在**的用户登录。
> 首次使用某个 SSO 用户前，要先创建同名 dashboard 用户：
> `ceph dashboard ac-user-create <username> -r administrator`
> 否则登录后会被重定向到 `#/sso/404`。

### 坑 21：Ceph mgr 运行在 Docker 容器内

**现象**：宿主机上 `python3 -c "import saml2"` 失败，但 yum 显示 python3-saml 已安装。

**原因**：Ceph 用 cephadm + Docker 容器部署，mgr 运行在容器内。
`python3-saml` 安装在 **容器内**，宿主机的 Python 环境与容器是分开的。

**解决**：在 mgr 容器内验证和操作：`docker exec <mgr-container> python3 ...`

## 四、注意事项

1. **Keycloak 生产环境用 PostgreSQL**：dev 模式的 H2 内存数据库不持久化，
   Pod 重启后数据丢失。生产环境应配置 PostgreSQL（`KC_DB=postgres`）。

2. **Keycloak 镜像源选择**：quay.io 拉取慢，优先用 docker.io 或内网 harbor 镜像。

3. **Keycloak 健康检查**：就绪探针用 `/realms/master`（8080 端口），
   不要用 `/health/ready`（在 9000 管理端口）。

4. **Keycloak Admin API 端口**：Admin REST API 在 8080 端口，
   9000 是 Quarkus 管理接口（health/metrics）。

5. **Keycloak OIDC 上游 providerId**：Keycloak 26 用 `oidc`，不是 `openid-connect`。

6. **GitLab OAuth 应用**：GitLab 19.5 要求 `organization_id` 不为 NULL，
   创建时必须指定。

7. **Ceph Dashboard SAML**：IdP 元数据用 `/realms/{realm}/protocol/saml/descriptor`。
   SP 证书与 Keycloak 客户端的签名/加密开关必须成对配置：
   要么都不开，要么都开。

8. **Ceph mgr 容器**：Ceph 用 Docker 容器部署，SAML 相关操作在 mgr 容器内执行，
   不是宿主机。

9. **网络可达性**：Ceph 集群（10.0.0.x）需能访问 Keycloak 的 NodePort。
   Keycloak 需能访问 GitLab（192.168.67.201）。
   浏览器（终端用户）需要同时能访问 Ceph Dashboard、Keycloak 和 GitLab。

10. **Keycloak `KC_HOSTNAME` 必须是外部可访问的完整 URL**，
    否则元数据里生成 `127.0.0.1`，SAML 跳转必然失败。

11. **Ceph 用户要先存在**：SSO 只做认证，不做授权。
    `ceph dashboard ac-user-create <username> -r administrator` 必须先建好，
    用户名要和 Keycloak 断言里的 `uid` 一致。

12. **SAML 断言大小**：开启断言加密后，Keycloak 会把整个 Assertion 加密，
    调试时看不到属性。需要排错时临时把 `saml.encrypt` 设为 `false`
    （同时 Ceph 侧不能要求加密），定位完再改回来。

## 五、当前状态与后续工作

| 步骤 | 状态 | 说明 |
|---|---|---|
| Ceph mgr python3-saml | ✅ 完成 | 已在 mgr 容器内确认可用（`onelogin.saml2`） |
| Keycloak 部署 | ✅ 完成 | docker.io 镜像，NodePort `32669` |
| Keycloak 使用 PostgreSQL | ✅ 完成 | cnpg-system/pg16-ceph，数据持久化 |
| GitLab OAuth 应用 | ✅ 完成 | 用 gitlab-rails runner 创建，指定 organization_id |
| Keycloak realm 导入 | ✅ 完成 | ceph-sso realm，含 GitLab OIDC 上游 |
| SAML client 创建 | ✅ 完成 | clientId = SP EntityID，含 `uid` 属性映射 |
| SAML IdP 元数据获取 | ✅ 完成 | `/realms/ceph-sso/protocol/saml/descriptor` |
| Ceph Dashboard SAML 配置 | ✅ 完成 | `ceph dashboard sso setup saml2`（含 SP 证书） |
| Keycloak 端 SAML 签名/加密 | ✅ 完成 | 客户端要求签名 + 加密断言 |
| **Ceph ← Keycloak 登录链路** | ✅ **验证通过** | Keycloak 本地用户 → SAML → Ceph 拿到 access_token |
| Keycloak ← GitLab 登录链路 | ✅ 重定向验证 | 跳到 GitLab `/oauth/authorize`，scope 正确；完整登录需 GitLab 账号 |
| 浏览器端完整人工验证 | ⏸ 待人工确认 | 需要一个 GitLab 用户 + 同名 Ceph dashboard 用户 |

**后续工作**：
1. 用真实 GitLab 账号走一遍浏览器登录，确认 `uid` 映射与 Ceph 用户一致
2. 为 GitLab 用户预先创建 Ceph dashboard 用户
   （`ceph dashboard ac-user-create <gitlab-username> -r administrator`）
3. 生产化：Keycloak 改用 `start`（非 dev 模式）+ HTTPS + 正式域名，
   `KC_HOSTNAME` 指向正式域名
4. 证书轮换：SP 证书过期前重新生成并更新 Keycloak 客户端与 Ceph 配置
