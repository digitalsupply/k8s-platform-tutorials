# SSO / OIDC 全链路凭据获取手册：GitLab、Keycloak、K8s Secret、Ceph、Headlamp 身份 id_token

> 整理时间：2026-11-25  
> 范围：GitLab（所有用户）、Keycloak（自身 + `ceph-sso` 映射）、K8s Secret、Ceph、Headlamp（不同用户身份验证 id_token）  
> 用途：在需要核对、轮换、排障或审计 SSO/OIDC 链路凭据时，按本手册直接执行获取命令。  
> 约定：**本文档只给获取命令，不写任何实际密码/Token 值**；实际值由命令现场输出，切勿落盘、提交仓库或写入日志。

## 0. 执行机器总览

| 目标组件 | 执行机器 / 入口 | 主要工具 |
|---|---|---|
| GitLab（本机命令） | `192.168.67.201`，`ssh root@192.168.67.201` | `gitlab-rails runner`、`sed`、`cat` |
| GitLab（登录 / OAuth） | 任意能访问 GitLab 的机器 | `curl`、`python3` |
| Keycloak | `10.0.0.121:32669`（K8s `keycloak` namespace，经 kubectl 或直连） | `curl`、`kubectl` |
| K8s Secret | 管理节点（有 kubeconfig 的机器，本机即可） | `kubectl` |
| Ceph | 有 `ceph` 配置的机器（本机可用）；Ceph 主机 `ceph-01/02/03` | `ceph` CLI |
| Headlamp / SSO id_token | 任意能访问 GitLab 与业务域名的机器（本机） | `python3` + `ssh`（见第 5 节脚本） |

> 说明：以下命令默认在**有相应权限的运维机**上执行；涉及 `ssh`、`kubectl`、`ceph` 的命令需要对应凭据与 RBAC。

## 1. GitLab（所有用户）

### 1.1 `root` 初始密码

GitLab 首次安装生成的初始密码保存在部署机文件里：

```bash
ssh -o BatchMode=yes root@192.168.67.201 \
  "sed -n 's/^Password: //p' /etc/gitlab/initial_root_password"
```

> 注意：该文件在 `gitlab-ctl reconfigure` 后 **24 小时会被自动删除**。若已不存在，
> 用 `ssh root@192.168.67.201 "gitlab-rake 'gitlab:password:reset[root]'"` 重置。

### 1.2 普通用户（`bigdev` / `smallops`）密码

- 这两个账号是演练时通过 `gitlab-rails runner` 创建的，**密码没有落盘**，创建时设置为临时密码
  （本环境为 `Temp@12345`，仅供演练）。**正式环境请立即修改，不要沿用临时密码。**
- 核对账号信息（ID、邮箱、管理员、组）：

```bash
ssh -o BatchMode=yes root@192.168.67.201 "gitlab-rails runner '
User.where(username: %w[root bigdev smallops]).each do |u|
  puts [u.id, u.username, u.email, u.admin].join(\" | \")
  u.members.each { |m| puts \"   #{m.source.full_path} level=#{m.access_level}\" }
end'"
```

- 重置某个用户密码（需满足 GitLab 密码策略，建议用 Admin UI 操作）：

```bash
ssh -o BatchMode=yes root@192.168.67.201 "gitlab-rails runner '
u = User.find_by_username(%q(bigdev))
u.password = \"NewPass@123\"
u.password_confirmation = \"NewPass@123\"
u.save!
puts u.state
'"
```

### 1.3 GitLab PAT（自动化 / git 推送）

存放在 K8s Secret `gitlab-auth`（namespace `cicd`）中，`username` 与 `token` 同值，属于 GitLab 个人访问令牌（PAT）：

```bash
kubectl -n cicd get secret gitlab-auth -o jsonpath='{.data.username}' | base64 -d
kubectl -n cicd get secret gitlab-auth -o jsonpath='{.data.token}' | base64 -d
```

> 用于 `git push` 等自动化；仅授予所需仓库权限，定期轮换。

### 1.4 GitLab OAuth 应用 client_secret（各 SSO 应用共用 GitLab 侧凭据）

GitLab 侧为每个应用各建了一个 OAuth Application，应用名与用途：

| GitLab OAuth 应用名 | 用途 |
|---|---|
| `grafana` | Grafana 原生 OIDC |
| `argocd` | ArgoCD 原生 OIDC |
| `harbor` | Harbor OIDC |
| `keycloak` | Keycloak `ceph-sso` 的 IdP `gitlab` |
| `oauth2-traefik` / `oauth2-headlamp` / `oauth2-hubble` / `oauth2-alloy` / `oauth2-tekton` | 5 个 oauth2-proxy 实例 |

获取某个应用的 `client_id / client_secret / redirect_uri`：

```bash
ssh -o BatchMode=yes root@192.168.67.201 "gitlab-rails runner '
a = Doorkeeper::Application.find_by_name(%q(oauth2-headlamp))
puts JSON.generate({uid: a.uid, secret: a.secret, redirect_uri: a.redirect_uri})
'"
```

只取 `client_secret`：

```bash
ssh -o BatchMode=yes root@192.168.67.201 \
  "gitlab-rails runner 'puts Doorkeeper::Application.find_by_name(%q(grafana)).secret'"
```

## 2. Keycloak（自身 + `ceph-sso` 映射）

### 2.1 Keycloak 自身管理员

Keycloak 部署在 K8s namespace `keycloak`，对外 `http://10.0.0.121:32669`。
管理员凭据存放在 Secret `keycloak-admin-secret`：

```bash
# 从 Secret 取（推荐，不写明文）
kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-user}' | base64 -d
kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-password}' | base64 -d
```

用管理员账号获取 access_token（后续调用 Admin API 用）：

```bash
TOKEN=$(curl -sS -X POST 'http://10.0.0.121:32669/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' -d 'client_id=admin-cli' \
  -d "username=$(kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-user}' | base64 -d)" \
  -d "password=$(kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-password}' | base64 -d)" \
  | jq -r .access_token)
```

> 另有 `keycloak-db-secret`（`keycloak-db-password`）是数据库密码，仅数据库维护时使用，不参与 SSO。

### 2.2 `ceph-sso` realm 用户与 GitLab 映射

列出 `ceph-sso` 用户：

```bash
curl -sS -H "Authorization: Bearer $TOKEN" \
  'http://10.0.0.121:32669/admin/realms/ceph-sso/users?briefRepresentation=true&max=50' \
  | jq -r '.[] | [.username, .email, .id] | @tsv'
```

查询某用户的 GitLab federated identity（即 Keycloak↔GitLab 的映射）：

```bash
ID=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  'http://10.0.0.121:32669/admin/realms/ceph-sso/users?username=root&exact=true' | jq -r '.[0].id')

curl -sS -H "Authorization: Bearer $TOKEN" \
  "http://10.0.0.121:32669/admin/realms/ceph-sso/users/$ID/federated-identity" | jq -c .
```

- 这些用户是**通过 GitLab broker 首次登录自动导入**的，登录走 GitLab 身份，本身通常没有本地密码；
- 若需要本地密码，可重置（`temporary` 控制是否要求首次登录改密）：

```bash
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "http://10.0.0.121:32669/admin/realms/ceph-sso/users/$ID/reset-password" \
  -d '{"type":"password","value":"NewPass@123","temporary":false}'
```

### 2.3 Keycloak IdP `gitlab` 的 GitLab 侧凭据

`ceph-sso` realm 的 IdP `gitlab` 使用 GitLab OAuth 应用 `keycloak`，其 client_secret 取自 GitLab：

```bash
ssh -o BatchMode=yes root@192.168.67.201 \
  "gitlab-rails runner 'puts Doorkeeper::Application.find_by_name(%q(keycloak)).secret'"
```

## 3. K8s Secret

> 通用取值：`kubectl -n <namespace> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d`

| Secret | Namespace | 关键 key | 用途 / 说明 |
|---|---|---|---|
| `gitlab-auth` | `cicd` | `username`、`token`（`password` 同值） | GitLab PAT，用于 git 推送/自动化 |
| `argocd-oauth` | `argocd` | `client-secret` | ArgoCD 原生 OIDC 的 GitLab client secret |
| `oauth2-alloy` / `oauth2-headlamp` / `oauth2-hubble` / `oauth2-tekton` / `oauth2-traefik` | `oauth2-proxy` | `client-secret`、`cookie-secret` | 5 个 oauth2-proxy 实例；明文由 SealedSecrets 控制器解密后写入，仓库里只存 SealedSecret |
| `grafana-oauth` | `monitoring` | `client-secret` | Grafana 原生 OIDC 的 GitLab client secret |
| `prometheus-grafana-admin` | `monitoring` | `admin-user`、`admin-password` | Grafana 本地管理员 |
| `keycloak-admin-secret` | `keycloak` | `keycloak-admin-user`、`keycloak-admin-password` | Keycloak 管理员 |
| `keycloak-db-secret` | `keycloak` | `keycloak-db-password` | Keycloak 数据库密码 |
| `etcd-backup-s3` | `etcd-backup` | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` | 备份用 Ceph RGW/S3 凭据（非 SSO，相关备份） |

取值示例：

```bash
# oauth2-proxy 某个实例的 client_secret 与 cookie_secret
kubectl -n oauth2-proxy get secret oauth2-headlamp -o jsonpath='{.data.client-secret}' | base64 -d
kubectl -n oauth2-proxy get secret oauth2-headlamp -o jsonpath='{.data.cookie-secret}' | base64 -d

# ArgoCD OIDC client_secret
kubectl -n argocd get secret argocd-oauth -o jsonpath='{.data.client-secret}' | base64 -d

# Grafana OIDC client_secret / Grafana 管理员
kubectl -n monitoring get secret grafana-oauth -o jsonpath='{.data.client-secret}' | base64 -d
kubectl -n monitoring get secret prometheus-grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

> `oauth2-*` 的明文 Secret 是 SealedSecrets 控制器解密后生成的；仓库/GitOps 侧只保留
> `SealedSecret`，直接看明文要走 `kubectl`（需对应 RBAC）。

## 4. Ceph

### 4.1 Ceph 管理员 keyring

在有 `ceph` 配置的机器上执行：

```bash
ceph auth print-key client.admin
```

> 高权限凭据，仅限排障/运维，注意不要外泄。

### 4.2 Ceph Dashboard 用户与角色

SSO 场景下 Ceph 通过 SAML `uid` 匹配本地用户；本地用户密码**不可逆**（存储为哈希，无法“获取”），只能创建/重置：

```bash
# 查看角色
ceph dashboard ac-user-show bigdev   # administrator
ceph dashboard ac-user-show smallops # read-only
ceph dashboard ac-user-show root     # administrator

# 创建用户（密码从 stdin 读取；SSO 登录不使用该密码）
printf 'NewPass@123\n' | ceph dashboard ac-user-create <user> <role>
```

> 本环境 `bigdev`/`smallops`/`root` 的本地密码为演练用临时值；SSO 模式下登录不依赖它。

## 5. Headlamp：不同用户身份验证的 id_token

### 5.1 背景

Headlamp 当前通过 **oauth2-proxy**（GitLab 应用 `oauth2-headlamp`）接入。用户登录 Headlamp 时，
oauth2-proxy 从 GitLab 拿到该用户的 **OIDC id_token**，其中包含身份 claim：

- `sub`：GitLab 用户 ID（如 bigdev=5、smallops=6、root=1）；
- `preferred_username`：用户名；
- `groups`：所在组（oauth2-proxy 的 `--allowed-group` 就是据此校验）。

**不同用户的身份差异，体现在各自 id_token 的 `sub` / `groups` 上。** 要核对某个用户在某个应用下的
身份验证 id_token，使用脚本 [scripts/get_sso_id_token.py](../scripts/get_sso_id_token.py)。

### 5.2 脚本用法

```bash
python3 docs/13-sso-oidc/scripts/get_sso_id_token.py \
  --user bigdev --password 'Temp@12345' --app oauth2-headlamp
```

输出（节选，已解码）：

```json
{
  "user": "bigdev",
  "app": "oauth2-headlamp",
  "id_token_payload": {
    "preferred_username": "bigdev",
    "email": "bigdev@example.com",
    "groups": ["digitalsupply"],
    "sub": "5"
  }
}
```

对比不同用户 / 不同应用：

```bash
# root
python3 docs/13-sso-oidc/scripts/get_sso_id_token.py \
  --user root --password '<root 初始密码>' --app oauth2-headlamp

# smallops
python3 docs/13-sso-oidc/scripts/get_sso_id_token.py \
  --user smallops --password 'Temp@12345' --app oauth2-headlamp

# 换一个应用：Grafana / ArgoCD / Traefik
python3 docs/13-sso-oidc/scripts/get_sso_id_token.py \
  --user bigdev --password 'Temp@12345' --app grafana
```

### 5.3 应用名映射

| 目标 UI | `--app` 参数（GitLab OAuth 应用名） |
|---|---|
| Headlamp | `oauth2-headlamp` |
| Traefik Dashboard | `oauth2-traefik` |
| Hubble | `oauth2-hubble` |
| Alloy | `oauth2-alloy` |
| Tekton | `oauth2-tekton` |
| Grafana | `grafana` |
| ArgoCD | `argocd` |
| Harbor | `harbor` |
| Keycloak IdP（ceph-sso） | `keycloak` |

### 5.4 脚本做了什么（等价手工流程）

1. 通过 `ssh root@192.168.67.201` + `gitlab-rails runner` 读取该 OAuth 应用的
   `client_id / client_secret / redirect_uri`；
2. 以目标用户表单登录 GitLab（`/users/sign_in`）；
3. 访问 `/oauth/authorize`，必要时处理 GitLab 授权同意页（只提交 Authorize 表单）；
4. 用回调里的 `code` 到 `/oauth/token` 换 token，取 `id_token`；
5. 解码并打印 `id_token` 的 payload。

> 也可直接用脚本完成；不建议手工拼 curl 处理 GitLab 的 CSRF / 同意页，容易漏步骤。

## 6. 安全性建议

1. **最小权限**：按用途选择最小凭据——GitLab PAT 仅仓库权限；oauth2-proxy 的 `client-secret`
   只对应单个应用；`cookie-secret` 仅用于会话。不要为省事复用高权限凭据。
2. **不落盘、不入库、不入日志**：本文档只给命令、不给值；获取到的密码/Token 只用于当次操作，
   不要 `echo` 到终端历史、脚本或提交仓库。敏感输出建议重定向到受控文件并尽快清理。
3. **定期轮换**：GitLab PAT、OAuth `client_secret`、Keycloak 管理员、Ceph admin key 等按周期轮换；
   CI 尽量用短期 token/凭据，避免长期有效的高权限凭据。
4. **传输安全**：当前 GitLab 是 **HTTP issuer**（`http://192.168.67.201`）。OIDC/SSO 的
   issuer、回调、token 传输应尽快切到 HTTPS，尤其涉及 apiserver OIDC 时 HTTP 不安全且不被接受。
5. **高权限凭据收敛**：`keycloak-admin-*`、`prometheus-grafana-admin-*`、`ceph client.admin`
   属于高权限，限制可执行机器与人员，开启审计；非必要不要在多台机器保留。
6. **Ceph 本地密码**：不可获取、只可重置；SSO 场景不要用本地密码登录，避免与 SSO 两套身份混淆。
7. **id_token 勿当长期凭据**：id_token 是短期 JWT（含 `exp`），仅用于身份验证与授权判定；
   不要保存为长期凭据。身份授权依赖 `groups` claim，**组名是授权契约，重命名组会导致相关授权失效**。
8. **RBAC 与审计**：查看 K8s Secret 需要 `secrets` 相关 RBAC；每次获取敏感凭据应记录
   操作人、时间、用途，便于追溯。
9. **临时演练账号**：`bigdev`/`smallops` 为临时密码且未强制 2FA，正式使用前改为强密码 + 2FA 或接入目录。
