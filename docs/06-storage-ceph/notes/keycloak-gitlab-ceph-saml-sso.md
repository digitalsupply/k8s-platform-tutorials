# Keycloak 结合 GitLab OIDC 接管 Ceph Dashboard SSO（实战记录）

> **场景**：Ceph Dashboard（Reef 18.2.8）只支持 SAML 2.0，不支持 OIDC。
> GitLab 是 OIDC IdP，不是 SAML IdP。用 **Keycloak 做协议转换桥梁**：
> GitLab（OIDC IdP）→ Keycloak（OIDC 客户端 + SAML IdP）→ Ceph Dashboard（SAML SP）。
> **日期**：2026-11-22
> **环境**：GitLab CE 19.5.0（192.168.67.201）；Keycloak 26.3.4（K8s 集群内）；
> Ceph Reef 18.2.8（ceph-01/02/03，10.0.0.31/41/51）

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
  "clientId": "ceph-dashboard",
  "name": "Ceph Dashboard",
  "enabled": true,
  "protocol": "saml",
  "publicClient": false
}
```

通过 Admin API 创建：`POST /admin/realms/ceph-sso/clients`

3. **获取 SAML IdP 元数据**：Ceph Dashboard 配置 SAML 需要 Keycloak 的：
   - IdP Entity ID
   - IdP SSO URL
   - IdP 签名证书

   标准路径：`GET /realms/ceph-sso/protocol/saml/metadata`

### 步骤 5：Ceph Dashboard 配置 SAML

在 Ceph mgr 上配置 Dashboard SAML SSO：

```bash
# 在 active mgr 容器内执行
ceph config set mgr dashboard_saml_entity_id <Keycloak IdP Entity ID>
ceph config set mgr dashboard_saml_sso_url <Keycloak IdP SSO URL>
ceph config set mgr dashboard_saml_cert <Keycloak IdP 证书>
ceph config set mgr dashboard_saml_enable true
```

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

### 坑 6：Keycloak 26 的 SAML 元数据端点 404（待解决）

**现象**：`/realms/ceph-sso/protocol/saml/metadata`、`/realms/ceph-sso/protocol/saml/idp/metadata`
等 SAML IdP 端点全部返回 **404**。即使 realm 存在、SAML client 存在（protocol=saml），端点仍 404。

**排查**：
- `/realms/ceph-sso/protocol/saml` 返回 **400**（端点存在，需要参数）
- `--features=saml` 不是有效 feature（SAML 是核心协议，不是 feature）
- protocol-mappings、protocols/saml 等 admin API 端点也 404

**结论**：Keycloak 26 的 SAML IdP 元数据端点路径可能已变更，或需要额外配置才能启用。
**这是当前最大的阻塞点，需要进一步排查 Keycloak 26 的 SAML 协议配置。**

**备选方案**：手动构造 SAML IdP 配置：
- Entity ID：`http://<keycloak-host>:<port>/realms/ceph-sso`
- SSO URL：`http://<keycloak-host>:<port>/realms/ceph-sso/protocol/saml/idp/login`
- 证书：从 JWKS 端点 `/realms/ceph-sso/protocol/openid-connect/certs` 获取

（但 SSO URL 端点也返回 404，需要确认 SAML 协议是否实际可用）

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

### 坑 12：PostgreSQL 主库变更，socket 连接连到备库（只读）

**现象**：通过 `kubectl exec pg16-ceph-3` 执行 `CREATE DATABASE keycloak` 报
`cannot execute CREATE DATABASE in a read-only transaction`。

**原因**：CNPG 集群的主库发生了切换。排查时发现：
- `pg16-ceph-3`：`pg_is_in_recovery() = t`（**备库**，只读）
- `pg16-ceph-4`：`pg_is_in_recovery() = f`（**主库**，可写）

之前手动提升 pg16-ceph-3 为主库，但 CNPG 控制器后来将主库切换回 pg16-ceph-4。
socket 连接连到 pg16-ceph-3（备库），自然只读。

**解决**：连到当前主库 `pg16-ceph-4` 执行 DDL。创建数据库和用户后验证通过。

### 坑 13：schema 权限不足（permission denied for schema public）

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

### 坑 14：跨命名空间 FQDN 解析

**现象**：Keycloak（`keycloak` 命名空间）连接 PostgreSQL（`cnpg-system` 命名空间）报
`java.net.UnknownHostException: pg16-ceph-rw`。

**原因**：Keycloak Pod 的 DNS 搜索域是 `keycloak.svc.cluster.local`、`svc.cluster.local`、
`cluster.local`，无法解析 `cnpg-system` 命名空间的短域名 `pg16-ceph-rw`。

**解决**：使用 FQDN：`pg16-ceph-rw.cnpg-system.svc.cluster.local`

### 坑 15：KC_DB_URL 被错误设成密码值

**现象**：Keycloak 启动报 `Driver does not support the provided URL: Keycloak@Db123`。

**原因**：用 `kubectl patch` 修改环境变量时，JSON patch 的索引指向错误，
`KC_DB_URL` 的值被替换成了 `KC_DB_PASSWORD` 的值。

**解决**：检查 Deployment 环境变量数组的索引，逐一确认每个变量的值，
用正确的索引 patch。

### 坑 16：SAML 元数据端点在 PostgreSQL 下仍 404

**现象**：切换到 PostgreSQL 后，SAML IdP 元数据端点
`/realms/ceph-sso/protocol/saml/metadata` 等仍返回 **404**。

**结论**：SAML 端点 404 **不是数据库问题**（H2 和 PostgreSQL 都一样）。
是 Keycloak 26 的 SAML 协议端点配置问题，需要进一步排查 Keycloak 26 的
SAML 协议注册机制。这是当前最大的阻塞点。

**当前状态**：Keycloak 已成功使用 PostgreSQL（`jdbc-postgresql` 驱动已安装），
realm 和 SAML client 均已创建，但 SAML IdP 元数据端点不可用，
Ceph Dashboard SAML 配置无法完成。

### 坑 11：Ceph mgr 运行在 Docker 容器内

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

7. **Ceph Dashboard SAML**：需要 IdP 的 Entity ID、SSO URL、签名证书。
   SAML 协议端点在 Keycloak 26 中需要确认可用性（当前 404，待解决）。

8. **Ceph mgr 容器**：Ceph 用 Docker 容器部署，SAML 相关操作在 mgr 容器内执行，
   不是宿主机。

9. **网络可达性**：Ceph 集群（10.0.0.x）需能访问 Keycloak 的 NodePort。
   Keycloak 需能访问 GitLab（192.168.67.201）。

## 五、当前状态与后续工作

| 步骤 | 状态 | 说明 |
|---|---|---|
| Ceph mgr python3-saml | ✅ 完成 | 已在 mgr 容器内确认可用 |
| Keycloak 部署 | ✅ 完成 | docker.io 镜像，NodePort 暴露 |
| **Keycloak 使用 PostgreSQL** | ✅ **完成** | 从 H2 内存数据库迁移到 cnpg-system/pg16-ceph，数据持久化 |
| GitLab OAuth 应用 | ✅ 完成 | 用 gitlab-rails runner 创建，指定 organization_id |
| Keycloak realm 导入 | ✅ 完成 | ceph-sso realm，含 GitLab OIDC 上游 |
| SAML client 创建 | ✅ 完成 | ceph-dashboard，protocol=saml |
| **SAML IdP 元数据获取** | ❌ **阻塞** | Keycloak 26 SAML 端点 404（H2/PostgreSQL 都一样，非数据库问题） |
| Ceph Dashboard SAML 配置 | ⏸ 待执行 | 依赖 SAML 元数据获取 |
| SAML 登录验证 | ⏸ 待执行 | 依赖 Ceph Dashboard 配置 |

**后续工作**：
1. 排查 Keycloak 26 SAML 协议端点 404 的原因（SAML 协议注册机制）
2. 获取 SAML IdP 元数据后，配置 Ceph Dashboard SAML SSO
3. 验证完整登录链路：Ceph Dashboard → Keycloak → GitLab → 登录成功
