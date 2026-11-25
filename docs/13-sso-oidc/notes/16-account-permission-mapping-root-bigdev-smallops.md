# 账号与业务权限映射：`root` / `bigdev` / `smallops`

> 实测时间：2026-11-24  
> 范围：GitLab（IdP）+ Grafana、ArgoCD、Harbor、Traefik、Headlamp、Hubble、Alloy、
> Tekton、Ceph Dashboard、Keycloak `ceph-sso`。  
> 目的：把三个账号的**凭据来源、GitLab 权限、登录后在各业务系统的实际权限、
> 对应配置**整理成一份可直接查阅和交接的表；所有权限结论都来自真实登录，不是推测。

## 1. 账号总览

### 1.1 身份与凭据

| 用户名 | 密码 | 密码存放位置 | GitLab ID | GitLab 管理员 | 邮箱 |
|---|---|---|---|---|---|
| `root` | 部署时生成的初始密码 | 部署机 `/etc/gitlab/initial_root_password`（`Password:` 行） | 1 | **是** | `gitlab_admin_526ef4@example.com` |
| `bigdev` | `Temp@12345` | 本演练临时设置，未落盘 | 5 | 否 | `bigdev@example.com` |
| `smallops` | `Temp@12345` | 本演练临时设置，未落盘 | 6 | 否 | `smallops@example.com` |

补充说明：

- `root` 的密码文件是 GitLab 首次安装生成的，**`gitlab-ctl reconfigure` 后 24 小时会被自动删除**；
  本环境该文件仍在，且 2026-11-24 用其登录验证通过。文件一旦消失，只能
  `gitlab-rake "gitlab:password:reset[root]"` 重置。
- `bigdev` / `smallops` 是普通账号（`admin=false`），仅用于 SSO 权限演练，
  **正式使用前必须改密码或禁用**；当前未强制 2FA。
- Ceph Dashboard 里另有本地密码（`TempCeph@12345`），但 **SSO 登录不使用它**：
  Ceph 只从 SAML 断言取 `uid` 再查本地用户，本地密码仅在关掉 SSO 时才会用到。

### 1.2 GitLab 组与角色

| 用户名 | 组 | 组内角色 | 说明 |
|---|---|---|---|
| `root` | `digitalsupply` | Owner (50) | 同时是 `deeptutor` Owner；管理员账号 |
| `root` | `deeptutor` | Owner (50) | 同上 |
| `bigdev` | `digitalsupply` | Developer (30) | 平台/开发管理员样本 |
| `smallops` | `deeptutor` | Developer (30) | 普通运维样本 |

> **GitLab 组是整套 SSO 授权的唯一契约**。业务系统不看 GitLab 的“管理员”开关，
> 只看 ID Token / userinfo 里的 `groups`。所以 `bigdev` 在 GitLab 里不是管理员，
> 但在 Grafana/ArgoCD/Harbor 里是管理员——因为它在 `digitalsupply` 组里。

## 2. 业务权限矩阵

| 业务系统 | 认证方式 | 授权依据 | `root` | `bigdev` | `smallops` |
|---|---|---|---|---|---|
| GitLab | 本地账号 | GitLab 自身角色 | 全局管理员 | 组成员 | 组成员 |
| Grafana | 原生 OIDC | `role_attribute_path` 读 `nickname` / `groups` | **GrafanaAdmin** | **GrafanaAdmin** | **Viewer** |
| ArgoCD | 原生 OIDC | `policy.csv` 读 `groups`，默认 `role:readonly` | **admin** | **admin** | **readonly** |
| Harbor | 原生 OIDC | `oidc_admin_group=digitalsupply` | **系统管理员** | **系统管理员** | **普通用户**（自动 onboard） |
| Traefik Dashboard | oauth2-proxy | `--allowed-group=digitalsupply` | **允许** | **允许** | **403** |
| Headlamp | oauth2-proxy + 粘贴 k8s token | `--allowed-group=digitalsupply` + per-user SA RBAC | **cluster-admin**（`headlamp-root`） | **只读 + 工作负载读写**（`headlamp-bigdev`） | **403** |
| Hubble | oauth2-proxy | `--allowed-group=digitalsupply,deeptutor` | **允许** | **允许** | **允许** |
| Alloy | oauth2-proxy | `--allowed-group=digitalsupply,deeptutor` | **允许** | **允许** | **允许** |
| Tekton | oauth2-proxy | `--allowed-group=digitalsupply,deeptutor` | **允许** | **允许** | **允许** |
| Ceph Dashboard | Keycloak `ceph-sso` SAML | Ceph 本地用户角色 | **administrator** | **administrator** | **read-only** |
| Keycloak `ceph-sso` | GitLab broker（OIDC） | 不做业务授权 | 可登录（自动导入） | 可登录（自动导入） | 可登录（自动导入） |

一句话总结：

- `root`：全平台最高权限，等价于“平台管理员 + 应急账号”；
- `bigdev`：平台管理员（除 GitLab 全局管理员外，业务侧与 root 同级）；
- `smallops`：只读/受限用户（ArgoCD 只读、Grafana Viewer、Harbor 普通用户、
  Traefik/Headlamp 拒绝、Ceph 只读），但可看可观测性三件套（Hubble/Alloy/Tekton）。

### 2.1 逐个系统的“权限体现在哪”

| 系统 | 管理员能看到/做到 | 受限用户看到/做到 | 实测判据 |
|---|---|---|---|
| Grafana | 左侧 `Server Admin` 菜单，可管用户/组织/插件 | 只有 Dashboard 浏览 | `/api/user` → `isGrafanaAdmin` |
| ArgoCD | Settings、创建/同步/删除 Application | 只读列表和详情，写操作 403 | 创建 Application 探针：500（过 RBAC）/ 403 |
| Harbor | “系统管理”（用户、项目、注册表、复制） | 只能看有权限的项目 | `admin_role_in_auth` + 列用户 200/403 |
| Traefik | Dashboard 全量路由/服务/Middleware | 登录即 403 | `/dashboard/` 200 / 403 |
| Headlamp | 集群资源全量读写（`headlamp-root`） | 只读 + 工作负载读写（`headlamp-bigdev`，需粘贴 token） | `/` 200；`/api/v1/nodes` 200 / 403 |
| Hubble | 流量视图 | 同左（放行） | `/` 200 |
| Alloy | 采集配置/指标浏览器 | 同左（放行） | `/` 200 |
| Tekton | Pipeline/PipelineRun 管理 | 同左（放行） | `/` 200 |
| Ceph | Cluster/配置/用户管理 | 只读页面 | `ceph dashboard ac-user-show` |

## 3. 认证链路与权限判定

```text
浏览器
  │
  ├─ Grafana / ArgoCD / Harbor ── OIDC Authorization Code ──┐
  │                                                          │
  ├─ Traefik/Headlamp/Hubble/Alloy/Tekton ── oauth2-proxy ───┤
  │        （ForwardAuth，每个 host 一个实例）                │
  │                                                          ▼
  │                                                   GitLab (IdP)
  │                                                   /oauth/authorize
  │                                                   /oauth/token
  │                                                   id_token + userinfo
  │                                                          │
  └─ Ceph Dashboard ── SAML ── Keycloak ceph-sso ── OIDC broker ┘
                                     │
                                     └─ 取 uid=username，写 SAML 断言
```

判定顺序（以 oauth2-proxy 为例）：

1. GitLab 认证成功，oauth2-proxy 拿到 `id_token`；
2. 读 `--oidc-groups-claim=groups`；
3. 与每个 `--allowed-group` 求交集；
4. 有交集 → 种 cookie、转发上游；无交集 → **403，不转发**。

Grafana/ArgoCD/Harbor 不走 oauth2-proxy，各自读 claim 后做本地授权，
因此它们的规则是“**登录时求值**”：改组之后需要重新登录（或等会话刷新）才生效。

## 4. 关键配置清单

### 4.1 GitLab：ID Token 必须带 `groups`

文件：`/opt/gitlab/embedded/service/gitlab-rails/config/initializers/doorkeeper_openid_connect.rb`

```ruby
# 第 73 行（修改后）
o.claim(:groups, response: [:id_token, :user_info]) do |user|
```

默认只有 `:user_info`。ArgoCD 用 `requestedIDTokenClaims.groups.essential=true` 强制要求
ID Token 带组，oauth2-proxy 也只读 ID Token，所以这个补丁是**前置条件**。

验证：

```bash
ssh root@192.168.67.201 "grep -n 'o.claim(:groups' \
  /opt/gitlab/embedded/service/gitlab-rails/config/initializers/doorkeeper_openid_connect.rb"
```

> 升级警告：这是 Omnibus 包内文件，`gitlab-ctl upgrade` / 包升级会覆盖。
> 升级后必须复查，否则 ArgoCD 会退回 `role:readonly`、oauth2-proxy 会拒绝所有人。

### 4.2 Grafana

`monitoring/prometheus-grafana` ConfigMap 的 `grafana.ini`：

```ini
[auth.generic_oauth]
name = GitLab
enabled = true
allow_sign_up = true
allow_assign_grafana_admin = true
login_attribute_path = preferred_username
role_attribute_path = contains(['root'], nickname) && 'GrafanaAdmin' || contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' || 'Viewer'
role_attribute_strict = false
```

- `root` 命中 `nickname` 分支；
- `bigdev` 命中 `digitalsupply` 分支；
- `smallops` 两个分支都不命中 → `Viewer`；
- `role_attribute_strict=false` 保证不匹配也能登录。

### 4.3 ArgoCD

`argocd/argocd-rbac-cm`：

```csv
g, digitalsupply, role:admin
g, gitlab_admin_526ef4@example.com, role:admin
```

```yaml
policy.default: role:readonly
policy.matchMode: glob
scopes: [groups, email]
```

`argocd/argocd-cm`：

```yaml
oidc.config: |
  name: GitLab
  issuer: http://192.168.67.201
  clientID: 7cde3dbfe3800036588275af741b36e60d882b18acda08cf25bc9637200038fe
  clientSecret: $argocd-oauth:client-secret
  requestedScopes: ["openid", "profile", "email"]
  requestedIDTokenClaims:
    groups:
      essential: true
  enablePKCEAuthentication: true
url: https://argocd.devops.com
```

- `bigdev` / `root` 命中 `g, digitalsupply, role:admin`；
- `root` 还额外命中按邮箱写死的规则；
- `smallops` 只落 `policy.default=role:readonly`。

### 4.4 Harbor

`/api/v2.0/configurations` 关键项：

```json
{
  "auth_mode": "oidc_auth",
  "oidc_name": "GitLab",
  "oidc_endpoint": "http://192.168.67.201",
  "oidc_client_id": "<harbor OAuth app>",
  "oidc_groups_claim": "groups",
  "oidc_user_claim": "preferred_username",
  "oidc_admin_group": "digitalsupply",
  "oidc_auto_onboard": true,
  "oidc_scope": "openid,profile,email",
  "oidc_verify_cert": false
}
```

- 组在 `digitalsupply` → 系统管理员；
- 其他用户自动创建（onboard），默认无系统管理权限；
- 组变更在**下次登录**生效。

### 4.5 oauth2-proxy（5 个实例）

`platform-gitops` → `platform/sso/oauth2-proxy/values.yaml`：

| 实例 | host | 上游 | `allowedGroups` |
|---|---|---|---|
| `hubble` | `hubble.xyz` | `hubble-ui.kube-system:80` | `digitalsupply`, `deeptutor` |
| `alloy` | `alloy.xyz` | `alloy.logging:12345` | `digitalsupply`, `deeptutor` |
| `tekton` | `tekton.xyz` | `tekton-dashboard.tekton-pipelines:9097` | `digitalsupply`, `deeptutor` |
| `traefik` | `traefik.xyz` | `traefik-api.traefik:9000` | `digitalsupply` |
| `headlamp` | `headlamp.devops.com` | `headlamp.headlamp:80` | `digitalsupply` |

模板 `templates/deployment.yaml` 把 `allowedGroups` 渲染成重复参数：

```yaml
- --oidc-groups-claim=groups
{{- range .allowedGroups }}
- --allowed-group={{ . }}
{{- end }}
```

Git 记录：

```text
4ce5c25  sso(oauth2-proxy): restrict traefik/headlamp to digitalsupply
725cb0a  sso(oauth2-proxy): gate hubble/alloy/tekton by digitalsupply+deeptutor
```

ArgoCD `platform-sso-oauth2-proxy` 当前 revision `725cb0a`，`Synced/Healthy`。

线上核对：

```bash
for d in hubble alloy tekton traefik headlamp; do
  printf '%-9s ' "$d"
  kubectl -n oauth2-proxy get deploy oauth2-proxy-$d \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | jq -r '[.[] | select(startswith("--allowed-group"))] | join(",")'
done
```

```text
hubble    --allowed-group=digitalsupply,--allowed-group=deeptutor
alloy     --allowed-group=digitalsupply,--allowed-group=deeptutor
tekton    --allowed-group=digitalsupply,--allowed-group=deeptutor
traefik   --allowed-group=digitalsupply
headlamp  --allowed-group=digitalsupply
```

> **2026-11-25 更新**：Headlamp 已改为“GitLab 认证 + 粘贴 k8s Bearer Token”，
> 不再共享 `headlamp` SA 的权限。`root` 用 `headlamp-root`（`cluster-admin`），
> `bigdev` 用 `headlamp-bigdev`（只读 + 工作负载读写），`smallops` 仍在
> oauth2-proxy 层 403。上面“放行即集群管理员”的描述已过时，详见
> [17-headlamp-token-login-per-user-rbac.md](17-headlamp-token-login-per-user-rbac.md)。

### 4.6 Keycloak `ceph-sso`

| 对象 | 值 |
|---|---|
| realm | `ceph-sso` |
| IdP alias | `gitlab`（OIDC，GitLab issuer `http://192.168.67.201`） |
| IdP `syncMode` | 未显式设置 = 默认 `IMPORT` |
| `first broker login` → Review Profile | `DISABLED`（首次登录不再停在补资料页） |
| SAML client | `https://10.0.0.41:8443/auth/saml2/metadata` |
| SAML mapper | `uid` ← `username` |
| 本地管理员 | `admin`（仅 Admin Console 用，不参与业务登录） |

`ceph-sso` 当前用户与 federated identity：

```text
admin     本地账号（admin@example.com）
root      broker 导入，gitlab/userId=1，userName=root，邮箱 gitlab_admin_526ef4@example.com
bigdev    broker 导入，gitlab/userId=5，userName=bigdev
smallops  broker 导入，gitlab/userId=6，userName=smallops
```

### 4.7 Ceph Dashboard

Ceph 只做授权，用户必须在 Ceph 本地存在：

```bash
ceph dashboard ac-user-show root      # administrator
ceph dashboard ac-user-show bigdev    # administrator
ceph dashboard ac-user-show smallops  # read-only
```

创建命令（位置参数：`ac-user-create <user> <role>`，密码从 stdin 读）：

```bash
printf 'TempCeph@12345\n' > /tmp/u.pwd
ceph -i /tmp/u.pwd dashboard ac-user-create smallops read-only
rm -f /tmp/u.pwd
```

> 新增 Ceph 用户时**先建 Ceph 账号**。否则 Keycloak 认证成功，但 Ceph 找不到同名用户，
> 会报 `UserDoesNotExist` 并跳回 SSO 错误页。

## 5. 实测验证（2026-11-24）

脚本：`docs/13-sso-oidc/assets/sso-perm-matrix-test.py`
（真实走完 GitLab 登录 + 各系统回调，不修改任何业务对象）。

```bash
# bigdev + smallops
SSO_TEST_PASSWORD='Temp@12345' python3 sso-perm-matrix-test.py

# 追加 root（密码从部署机读取）
ROOT_PW=$(ssh root@192.168.67.201 "sed -n 's/^Password: //p' /etc/gitlab/initial_root_password")
SSO_USERS=root SSO_PASSWORD_ROOT="$ROOT_PW" python3 sso-perm-matrix-test.py
```

结果（24 项检查全部符合预期）：

| 检查项 | `root` | `bigdev` | `smallops` |
|---|---|---|---|
| Grafana `/api/user` | `isGrafanaAdmin=true` | `true` | `false` |
| ArgoCD `session/userinfo` | `admin`（探针 500） | `admin`（探针 500） | `readonly`（探针 403） |
| Harbor `/users/current` | `admin_role_in_auth=true`，列用户 200 | `true`，200 | `false`，403 |
| Traefik `/dashboard/` | 200 | 200 | **403** |
| Headlamp `/` | 200 | 200 | **403** |
| Hubble `/` | 200 | 200 | 200 |
| Alloy `/` | 200 | 200 | 200 |
| Tekton `/` | 200 | 200 | 200 |

ArgoCD 返回的组（可用于判断匹配结果）：

```text
root      ["digitalsupply", "deeptutor", "gitlab_admin_526ef4@example.com"]
bigdev    ["digitalsupply", "bigdev@example.com"]
smallops  ["deeptutor", "smallops@example.com"]
```

> ArgoCD 会把邮箱也塞进 `groups`，这是它自身的行为，不影响
> `g, digitalsupply` 这类规则匹配。

Keycloak broker 自动导入验证脚本：
`docs/13-sso-oidc/assets/keycloak-broker-provision-test.py`
（退出码 0 表示两个用户的 broker 登录都回跳带 `code`，federated identity 正确）。

## 6. 日常运维

### 6.1 新增一个用户

1. GitLab 建用户（`gitlab-rails runner` 或 Admin UI），**必须同时建 namespace**
   （多组织环境下缺 `organization_id` 会报 `Namespace organization can't be blank`）；
2. 加入 `digitalsupply`（管理员样本）或 `deeptutor`（普通样本）；
3. 让用户在浏览器里登录一次 Grafana/ArgoCD/Harbor：
   - Grafana/ArgoCD 自动建用户；
   - Harbor 因 `oidc_auto_onboard=true` 自动 onboard；
4. 如需 Ceph：先 `ceph dashboard ac-user-create <user> <role>`，再走一次 Ceph 登录；
5. 如需 Hubble/Alloy/Tekton/Traefik/Headlamp：确认用户所在组在对应
   `allowedGroups` 里，否则会被 403。

### 6.2 调整某人在某系统的权限

| 想要的效果 | 做法 | 生效时机 |
|---|---|---|
| Grafana/ArgoCD/Harbor 提权/降权 | 把用户加入/移出 `digitalsupply` | 重新登录后 |
| 只改 Ceph 角色 | `ceph dashboard ac-user-create`（改角色）或删用户重建 | 重新登录后 |
| 改 Traefik/Headlamp 放行范围 | 改 `allowedGroups` 并推送 | ArgoCD 同步 + 下次请求 |
| 临时封禁某人 | GitLab `block!`，或各系统禁用本地用户 | GitLab 侧立即（新登录失败） |

### 6.3 收回/清理

```ruby
# GitLab：从组移除 + 禁用
Group.find_by_path("digitalsupply").remove_member(User.find_by_username("bigdev"))
User.find_by_username("bigdev").block!
```

```bash
# Ceph
ceph dashboard ac-user-disable smallops
# Keycloak
# Admin Console → ceph-sso → Users → 删除对应用户
```

`allowedGroups` 的回滚：删掉对应行或 revert `725cb0a` / `4ce5c25`。

### 6.4 GitLab 升级后必查

```bash
ssh root@192.168.67.201 "grep -n 'o.claim(:groups' \
  /opt/gitlab/embedded/service/gitlab-rails/config/initializers/doorkeeper_openid_connect.rb"
# 期望：o.claim(:groups, response: [:id_token, :user_info]) do |user|
```

不在就重新应用补丁并 `gitlab-ctl restart`，否则 ArgoCD/oauth2-proxy 的组授权会静默失效。

## 7. 风险与注意事项

1. **密码**：`bigdev`/`smallops` 使用临时密码且未强制 2FA；`root` 仍在使用部署初始密码。
   生产化前应改为强密码 + 2FA，或接入企业目录。
2. **`root` 权限过大**：GitLab 全局管理员 + 所有业务系统管理员 + `cluster-admin`
   （Headlamp 的 `headlamp-root` SA）。日常操作应使用 `bigdev`，`root` 仅作应急。
3. **Headlamp 的授权模型（2026-11-25 已更新）**：不再共享 `headlamp` SA，
   改为“GitLab 认证 + 粘贴 k8s token”；`root` → `headlamp-root`（`cluster-admin`），
   `bigdev` → `headlamp-bigdev`（只读 + 工作负载读写）。残留风险是 `bigdev`
   可在所有命名空间建 Pod、可读全集群 Secret，详见
   [17-headlamp-token-login-per-user-rbac.md](17-headlamp-token-login-per-user-rbac.md)。
4. **组名是硬契约**：`digitalsupply` 同时被 Grafana、ArgoCD、Harbor、Traefik、
   Headlamp 引用；`deeptutor` 被 Hubble/Alloy/Tekton 引用。重命名组会导致
   对应系统授权全部失效。
5. **会话缓存**：Grafana/ArgoCD/Harbor 的组权限在登录时求值；改组后旧会话不会立刻变，
   需要重新登录或等 token 刷新。
6. **oauth2-proxy 每次登录都弹 GitLab 授权页**：请求里带 `approval_prompt=force`；
   若要去掉，在 GitLab 把对应 OAuth Application 标记为 trusted（会降低确认强度）。
7. **Keycloak Review Profile 已关闭**：`ceph-sso` 所有首次 broker 登录都会直接建号；
   如需人工审核资料，把 `first broker login` 里的 Review Profile 改回 `REQUIRED`。
8. **HTTP issuer**：GitLab 目前是 `http://192.168.67.201`，所有 OIDC 客户端都开了
   “允许非 TLS issuer / 跳过证书校验”。上 TLS 前不要把 `--insecure-oidc-allow-unverified-email`
   之类的宽松选项带到生产。
9. **Ceph 用户与 Keycloak 用户必须成对存在**：只建一边会出现
   “认证成功但 Dashboard 报 `UserDoesNotExist`”。

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| [15-multi-user-permission-matrix-bigdev-smallops.md](15-multi-user-permission-matrix-bigdev-smallops.md) | 本轮实施过程：建号、`groups` 补丁、逐系统配置、实测输出 |
| [09-oidc-identity-permissions-traefik-forwardauth.md](09-oidc-identity-permissions-traefik-forwardauth.md) | OIDC 身份与权限映射原理、ForwardAuth 机制 |
| [12-keycloak-ceph-sso-account-and-topology.md](12-keycloak-ceph-sso-account-and-topology.md) | Keycloak `ceph-sso` 账号与拓扑 |
| [14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md](14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md) | Headlamp 两种接入方式与 `cluster-admin` 问题 |
| [../assets/sso-perm-matrix-test.py](../assets/sso-perm-matrix-test.py) | 三用户 × 8 系统的真实登录验证脚本 |
| [../assets/keycloak-broker-provision-test.py](../assets/keycloak-broker-provision-test.py) | Keycloak broker 自动导入验证脚本 |
| [../../03-gitlab/accounts-roles.md](../../03-gitlab/accounts-roles.md) | GitLab 账号体系与角色基线 |
