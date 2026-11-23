# Keycloak `$ADMIN_TOKEN` 是什么？集群环境获取与使用指南

> 适用场景：需要通过脚本或 `curl` 调用 Keycloak Admin REST API，在多节点/集群环境下获取管理员访问令牌。
>
> 说明：本文中的 `$ADMIN_TOKEN` 是 Shell 变量命名约定，不是 Keycloak 内置配置项。

## 1. `$ADMIN_TOKEN` 是什么

`$ADMIN_TOKEN` 通常是脚本/文档里常用的一个 **Shell 环境变量**，用于保存 **Keycloak 管理员访问令牌（Admin Access Token）**。

| 项目 | 说明 |
|---|---|
| **本质** | OAuth 2.0/OIDC Access Token，通常是 JWT |
| **作用** | 调用 Keycloak Admin REST API 时作为 Bearer 凭证 |
| **使用位置** | HTTP Header：`Authorization: Bearer $ADMIN_TOKEN` |
| **有效期** | 有时效（响应中的 `expires_in`），过期后需重新获取 |
| **作用范围** | 由获取 token 的用户/客户端角色决定，不是“天然全权限” |

示例：

```http
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

## 2. 集群环境下的关键点

Keycloak 集群通常是“多节点 + 共享外部数据库 + LB/Ingress 统一入口”。在这种架构下：

| 关注点 | 说明 |
|---|---|
| **统一入口** | 通过 LB/Ingress 域名访问，不要直连单个 Pod/节点 IP；节点可能重建或漂移。 |
| **共享状态** | 管理员用户、realm、client、realm keys 等存储在共享数据库中，集群节点状态一致。 |
| **Token 通用性** | Access Token 由 realm 密钥签发/验证。经 LB 从集群获取的 token，可用于后续经 LB 发往任意节点的 Admin API 请求。 |
| **路径差异** | Keycloak 17+（Quarkus）默认无 `/auth` 前缀；旧版 WildFly 常见 `/auth/...`。以实际部署为准。 |
| **HTTPS/Hostname** | 对外应使用 HTTPS；确保 `hostname`/代理头配置正确，否则 token 端点或回调行为可能异常。 |
| **时钟同步** | 集群节点和客户端机器需 NTP 同步，避免 token 因时间偏差出现“未生效/已过期”。 |
| **凭证安全** | 不要把 token/password 写入日志、代码库或明文 CI 变量；优先用 Secret/Vault 注入。 |

架构简图：

```text
curl/脚本
   │
   ▼
LB / Ingress (https://keycloak.example.com)
   │
   ├──> Keycloak node-1 ─┐
   ├──> Keycloak node-2 ─┼──> Shared DB (users/realms/keys)
   └──> Keycloak node-3 ─┘
```

## 3. 详细步骤

### 步骤 1：确认集群访问信息

先确定统一访问地址和 API 前缀：

```bash
# 集群统一入口（LB/Ingress）
export KEYCLOAK_URL="https://keycloak.example.com"

# Keycloak 17+（Quarkus）默认路径
export TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
export ADMIN_API_BASE="${KEYCLOAK_URL}/admin"

# 旧版 WildFly 如果配置了 /auth 前缀，则改为：
# export TOKEN_ENDPOINT="${KEYCLOAK_URL}/auth/realms/master/protocol/openid-connect/token"
# export ADMIN_API_BASE="${KEYCLOAK_URL}/auth/admin"
```

验证端点可达：

```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
  "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration"
```

返回 `200` 表示入口和 realm 路径正常。

### 步骤 2：准备管理员凭据

两种常见方式：

| 方式 | 适用场景 | 优点 | 注意 |
|---|---|---|---|
| **A. bootstrap 管理员账号密码** | 初始化、临时排障 | 简单直接 | 密码敏感，`admin-cli` 需允许 Direct Access Grants |
| **B. Service Account 客户端** | CI/CD、自动化运维 | 可最小权限、易轮换 | 需预先创建 client 并分配角色 |

> bootstrap admin 账号来自首次部署配置，不同版本环境变量名可能为 `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` 或 `KC_BOOTSTRAP_ADMIN_USERNAME`/`KC_BOOTSTRAP_ADMIN_PASSWORD`。集群中该账号信息存于共享数据库。

### 步骤 3：获取 `ADMIN_TOKEN`

#### 方式 A：管理员密码 + `admin-cli`

```bash
export ADMIN_USER="admin"
read -r -s -p "Admin password: " ADMIN_PASSWORD; echo

ADMIN_TOKEN=$(curl -sS --fail-with-body \
  -X POST "${TOKEN_ENDPOINT}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${ADMIN_USER}" \
  --data-urlencode "password=${ADMIN_PASSWORD}" \
  | jq -r '.access_token')

if [ -z "${ADMIN_TOKEN}" ] || [ "${ADMIN_TOKEN}" = "null" ]; then
  echo "获取 ADMIN_TOKEN 失败，请检查凭据、client_id、端点和 Keycloak 日志。" >&2
  exit 1
fi

export ADMIN_TOKEN
```

说明：

- `admin-cli` 是 Keycloak 常见内置客户端，用于命令行/脚本获取 token。
- 若 `admin-cli` 被禁用、或未开启 Direct Access Grants，此方式会失败。
- 密码包含特殊字符时，使用 `--data-urlencode` 比手工拼接更安全。

#### 方式 B：Service Account + `client_credentials`（推荐）

**一次性准备（Admin Console）：**

1. 选择管理目标对应的 realm（全局管理通常在 `master`）。
2. 创建 Client，例如 `cluster-admin-automation`。
3. 设置 `Client authentication: On`。
4. 关闭不需要的登录流程，按需开启 `Service accounts roles`。
5. 在 Service Account Roles 中授予最小必要角色（避免直接给全局超管）。
6. 记录 `client_id` 和 `client_secret`，存入 Secret/Vault。

**获取 token：**

```bash
export CLIENT_ID="cluster-admin-automation"
read -r -s -p "Client secret: " CLIENT_SECRET; echo

ADMIN_TOKEN=$(curl -sS --fail-with-body \
  -X POST "${TOKEN_ENDPOINT}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  | jq -r '.access_token')

if [ -z "${ADMIN_TOKEN}" ] || [ "${ADMIN_TOKEN}" = "null" ]; then
  echo "获取 ADMIN_TOKEN 失败，请检查 client_id/client_secret、服务账号角色和端点。" >&2
  exit 1
fi

export ADMIN_TOKEN
```

### 步骤 4：校验 Token 是否可用

不要只看变量非空，建议实际调用一个只读 Admin API：

```bash
curl -sS --fail-with-body \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API_BASE}/realms" | jq '.[].realm'
```

如需排查 token 内容（注意不要泄露完整 token）：

```bash
echo "${ADMIN_TOKEN}" | awk -F. '{print $2}' | base64 -d 2>/dev/null | jq '{iss,azp,exp,preferred_username}'
```

检查重点：

- `iss`：是否为预期的 Keycloak realm URL。
- `azp`：签发给哪个 client。
- `exp`：过期时间（Unix timestamp）。

### 步骤 5：使用 `ADMIN_TOKEN` 调用 Admin REST API

所有 Admin API 请求都带上 Bearer token：

```bash
# 查看 master realm 信息
curl -sS --fail-with-body \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API_BASE}/realms/master" | jq '{realm,enabled}'

# 查看用户（分页）
curl -sS --fail-with-body \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API_BASE}/realms/master/users?first=0&max=20" | jq '.[].username'
```

集群说明：请求经 LB 分发到不同 Keycloak 节点是正常的。只要 token 未过期、签名有效、权限足够，不需要会话粘滞。

### 步骤 6：处理过期与自动化

- **短期使用**：token 是短期凭证，任务结束后清理变量。
- **过期重取**：根据 `expires_in` 提前刷新，或遇到 `401` 时重新获取一次再重试。
- **自动化首选**：CI/CD 优先使用 `client_credentials` + Secret 管理。
- **最小权限**：只授予脚本需要的 realm-management 角色，避免使用全局管理员。
- **审计**：生产环境保留 Keycloak/Admin API 调用审计，便于追踪自动化操作。

## 4. 常见问题排查

| 现象 | 可能原因 | 处理建议 |
|---|---|---|
| `401 Unauthorized` | token 过期、无效、发错 realm/端点 | 重新获取 token；检查 `Authorization` 头；检查 `iss` 与 API 路径。 |
| `403 Forbidden` | token 有效但权限不足 | 检查用户/服务账号角色，按最小权限补齐。 |
| `invalid_grant` | 用户名密码错误、用户禁用、策略限制 | 检查 bootstrap admin 凭据；确认账号属于 `master` realm。 |
| `unauthorized_client` / direct grant 不允许 | `admin-cli` 未开启 Direct Access Grants 或客户端策略限制 | 检查 client 配置；生产自动化改用 `client_credentials`。 |
| 集群偶发 401/重定向/404 | 访问了单节点地址、路径前缀不一致、hostname/proxy 配置不一致 | 统一走 LB 域名；确认所有节点配置一致；核对 `/auth` 前缀和代理头设置。 |
| token 刚拿到就过期/未生效 | 节点或客户端时钟漂移 | 校准 NTP；检查容器与宿主机时间。 |
| 返回 HTML 登录页而非 JSON | API 路径错误或被前端/代理改写 | 用 `curl -v` 检查实际 URL、响应头和重定向。 |

## 5. 安全建议

- 使用 HTTPS 调用 token 端点和 Admin API，避免凭证和 token 在网络中泄露。
- 不要在 shell history、CI 日志、Git 仓库中保存密码、client secret 或 token。
- 排障时避免 `set -x` 打印敏感变量；必要时使用临时文件或 Secret 挂载。
- 生产自动化使用专用 service account，并定期轮换 secret。
- 将 `$ADMIN_TOKEN` 视为高价值临时凭证，最小化使用范围和存活时间。
