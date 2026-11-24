# 多用户 SSO 权限矩阵：`bigdev` / `smallops` 全链路实测

> 实测时间：2026-11-24  
> 环境：GitLab CE 19.5.0（`http://192.168.67.201`）、Grafana、ArgoCD、Harbor 2.14.5、
> oauth2-proxy v7.15.6（5 个实例）、Keycloak（`ceph-sso` realm）、Ceph 18.2.8 Reef Dashboard。  
> 目的：新建两个普通 GitLab 用户，让它们在不同业务 UI 上拿到**不同的实际权限**，
> 并给出可复现的验证步骤。此前所有 UI 都只验证过 `root`，看不出授权差异。

## 1. 结论先看

| 系统 | 认证方式 | 授权规则 | `bigdev` | `smallops` | 实测证据 |
|---|---|---|---|---|---|
| Grafana | 原生 OIDC | `role_attribute_path`：`digitalsupply` → `GrafanaAdmin`，其他 → `Viewer` | **GrafanaAdmin** | **Viewer** | `/api/user` 的 `isGrafanaAdmin`：`true` / `false` |
| ArgoCD | 原生 OIDC | `policy.csv`：`g, digitalsupply, role:admin`；默认 `role:readonly` | **admin** | **readonly** | 创建 Application 探针：500（通过 RBAC，进入参数校验）/ 403 `permission denied` |
| Harbor | 原生 OIDC | `oidc_admin_group=digitalsupply`，用户在组内即系统管理员 | **管理员** | **普通用户** | `admin_role_in_auth`：`true` / `false`；列全部用户 200 / 403 |
| Traefik Dashboard | oauth2-proxy | `--allowed-group=digitalsupply` | **允许** | **403** | 真实登录后 `/dashboard/`：200 / 403 |
| Headlamp | oauth2-proxy | `--allowed-group=digitalsupply` | **允许** | **403** | 真实登录后 `/`：200 / 403 |
| Hubble / Alloy / Tekton | oauth2-proxy | `--allowed-group=digitalsupply` + `--allowed-group=deeptutor` | 允许 | 允许 | 真实登录后 200；不在两个平台组内的 GitLab 用户 403 |
| Ceph Dashboard | Keycloak `ceph-sso` SAML | Ceph 本地用户角色 | **administrator** | **read-only** | `ceph dashboard ac-user-show` |
| Keycloak `ceph-sso` | GitLab broker（OIDC） | 只负责认证；无业务授权 | 可登录、自动导入 | 可登录、自动导入 | broker 登录回跳带 `code`，federated identity 为 `gitlab/userId=5/6` |

两个用户的 GitLab 身份：

| 用户 | GitLab ID | 组 | 组内角色 | 说明 |
|---|---|---|---|---|
| `bigdev` | 5 | `digitalsupply` | Developer (30) | 平台/开发管理员样本 |
| `smallops` | 6 | `deeptutor` | Developer (30) | 普通运维样本 |

> 关键点：SSO **只统一认证**。差异来自各系统读取 GitLab 的 `groups` claim 后做的本地授权，
> 而不是 GitLab 里给用户点了什么“SSO 权限”。

## 2. GitLab 侧实施

### 2.1 创建用户

GitLab 19.5 已启用多组织（组织表默认只有 `Default`，ID=1）。直接 `User.new` 会连续报
`Namespace can't be blank` / `Namespace organization can't be blank`，必须同时构造 namespace：

```ruby
# gitlab-rails runner
def make_user(username, name, email)
  return User.find_by_username(username) if User.find_by_username(username)

  u = User.new(
    username: username, name: name, email: email,
    password: "Temp@12345", password_confirmation: "Temp@12345"
  )
  u.skip_confirmation!
  u.namespace = Namespace.new(path: username, name: name, organization_id: 1)
  u.save!
  u
end

bigdev   = make_user("bigdev",   "Big Dev",   "bigdev@example.com")
smallops = make_user("smallops", "Small Ops", "smallops@example.com")
```

结果：

```text
5 | bigdev   | Big Dev   | bigdev@example.com   | active | false
6 | smallops | Small Ops | smallops@example.com | active | false
```

> 临时密码仅用于本次演练，正式使用前必须修改或禁用账号。

### 2.2 加入组

```ruby
ds = Group.find_by_path("digitalsupply")   # id=2
dt = Group.find_by_path("deeptutor")       # id=8

ds.add_member(bigdev,   Gitlab::Access::DEVELOPER)
dt.add_member(smallops, Gitlab::Access::DEVELOPER)
```

验证：

```text
member: Namespace digitalsupply level=30   # bigdev (id=5)
member: Namespace deeptutor    level=30   # smallops (id=6)
```

### 2.3 让 ID Token 带上 `groups`

GitLab 的 `doorkeeper-openid_connect` 默认只把 `groups` 放进 `/oauth/userinfo`，
**不放进 ID Token**。Grafana 走 userinfo 还能工作，但 ArgoCD（显式要求 ID Token 的
`groups`）和 oauth2-proxy 的组校验会拿不到组。因此把 claim 的返回位置补上 `:id_token`：

```bash
f=/opt/gitlab/embedded/service/gitlab-rails/config/initializers/doorkeeper_openid_connect.rb
cp "$f" "$f.bak-$(date +%F-%H%M%S)"
sed -i 's/o.claim(:groups) do/o.claim(:groups, response: [:id_token, :user_info]) do/' "$f"
grep -n 'o.claim(:groups' "$f"
gitlab-ctl restart
```

修改后第 73 行应为：

```ruby
o.claim(:groups, response: [:id_token, :user_info]) do |user|
```

实测 ID Token（Authorization Code 换到 `id_token` 后解码）：

```json
// bigdev
{"preferred_username": "bigdev", "email": "bigdev@example.com", "groups": ["digitalsupply"], "sub": "5"}
// smallops
{"preferred_username": "smallops", "email": "smallops@example.com", "groups": ["deeptutor"], "sub": "6"}
```

快速核对（浏览器里完成一次 OAuth，拿到回调 URL 中的 `code` 后）：

```bash
CID=78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228   # grafana
SECRET=$(ssh root@192.168.67.201 'gitlab-rails runner "puts Doorkeeper::Application.find_by(name: %q(grafana)).secret"')
curl -s -X POST http://192.168.67.201/oauth/token \
  -d grant_type=authorization_code -d code='<code>' \
  -d client_id="$CID" -d client_secret="$SECRET" \
  -d redirect_uri='https://grafana.k8s.local/login/generic_oauth' \
| jq -r .id_token \
| python3 -c "import sys,base64,json;t=sys.stdin.read().strip().split('.')[1];t+='='*(-len(t)%4);print(json.dumps(json.loads(base64.urlsafe_b64decode(t)),ensure_ascii=False,indent=2))" \
| jq '{preferred_username,groups}'
```

> **升级注意**：这个 initializer 属于 Omnibus 包内文件，`gitlab-ctl upgrade` / 包升级会被覆盖。
> 升级后必须重新 `grep` 确认；否则 ArgoCD/oauth2-proxy 的组授权会静默失效。

## 3. 各系统实施细节

### 3.1 Grafana

现有配置已经支持组映射，只是此前没有非 root 用户验证过：

```ini
[auth.generic_oauth]
allow_assign_grafana_admin = true
login_attribute_path = preferred_username
role_attribute_path = contains(['root'], nickname) && 'GrafanaAdmin' || contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' || 'Viewer'
role_attribute_strict = false
```

- `bigdev` → `GrafanaAdmin`（server admin）；
- `smallops` → `Viewer`（组织内只读）；
- `role_attribute_strict=false` 表示匹配不到也允许登录，落到 `Viewer`。

### 3.2 ArgoCD

`argocd-rbac-cm`：

```csv
g, digitalsupply, role:admin
g, gitlab_admin_526ef4@example.com, role:admin
```

`policy.default=role:readonly`；同时 `argocd-cm` 已声明：

```yaml
requestedIDTokenClaims:
  groups:
    essential: true
```

这要求 GitLab 必须在 **ID Token** 里给 `groups`，所以 2.3 的改动是 ArgoCD 的前提。
未匹配到 `digitalsupply` 的 `smallops` 落到 `role:readonly`。

### 3.3 Harbor

Harbor 配置（`/api/v2.0/configurations`）：

```json
{
  "auth_mode": "oidc_auth",
  "oidc_name": "GitLab",
  "oidc_endpoint": "http://192.168.67.201",
  "oidc_groups_claim": "groups",
  "oidc_user_claim": "preferred_username",
  "oidc_admin_group": "digitalsupply",
  "oidc_auto_onboard": true,
  "oidc_scope": "openid,profile,email"
}
```

- 组在 `digitalsupply` → Harbor 系统管理员；
- 其他用户自动 onboard（`oidc_auto_onboard=true`），默认只能看到公开项目/自己创建的项目；
- Harbor 在**登录时**读取组，移出组后需要重新登录/刷新会话才降权。

### 3.4 oauth2-proxy：全部 5 个实例按组收敛

`platform-gitops` 仓库 `platform/sso/oauth2-proxy/values.yaml` 增加按实例的组白名单：

```yaml
  - name: traefik
    host: traefik.xyz
    ...
    allowedGroups:
      - digitalsupply

  - name: headlamp
    host: headlamp.devops.com
    ...
    allowedGroups:
      - digitalsupply

  - name: hubble
    host: hubble.xyz
    ...
    allowedGroups:
      - digitalsupply
      - deeptutor

  # alloy、tekton 与 hubble 相同：两个组都放行
```

模板 `templates/deployment.yaml` 渲染为：

```yaml
- --oidc-groups-claim=groups
{{- range .allowedGroups }}
- --allowed-group={{ . }}
{{- end }}
```

已提交并同步：

```text
platform-gitops commit 4ce5c25  sso(oauth2-proxy): restrict traefik/headlamp to digitalsupply
platform-gitops commit 725cb0a  sso(oauth2-proxy): gate hubble/alloy/tekton by digitalsupply+deeptutor
ArgoCD Application platform-sso-oauth2-proxy revision 725cb0a, Synced/Healthy
```

线上参数核对：

```text
oauth2-proxy-traefik   --allowed-group=digitalsupply
oauth2-proxy-headlamp  --allowed-group=digitalsupply
oauth2-proxy-hubble    --allowed-group=digitalsupply --allowed-group=deeptutor
oauth2-proxy-alloy     --allowed-group=digitalsupply --allowed-group=deeptutor
oauth2-proxy-tekton    --allowed-group=digitalsupply --allowed-group=deeptutor
```

行为：OIDC 回调成功后 oauth2-proxy 校验 `groups`，不匹配直接返回 403，
不会把请求转发给上游。`smallops` 因此在 Traefik/Headlamp 上被挡在认证层；
Hubble/Alloy/Tekton 则放行两个平台组，其他 GitLab 用户（例如未来新增的第三方账号）一律 403。

> Headlamp 仍存在“通过认证即共享 SA 权限”的问题：
> `ClusterRoleBinding/headlamp-cluster-admin` 把 `headlamp/headlamp` SA 绑到 `cluster-admin`，
> 任何被 allowed-group 放行的人实际都是集群管理员。详见
> [14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md](14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md)。

### 3.5 Ceph Dashboard + Keycloak `ceph-sso`

Ceph 只做授权、不做认证：它从 SAML 断言里取 `uid`，再到自己的用户表找同名用户。
所以 **Keycloak 用户**和 **Ceph 用户**都要存在：

```bash
# 密码文件方式（位置参数：ac-user-create <user> <role>）
printf 'TempCeph@12345\n' > /tmp/bigdev.pwd
ceph -i /tmp/bigdev.pwd dashboard ac-user-create bigdev administrator
printf 'TempCeph@12345\n' > /tmp/smallops.pwd
ceph -i /tmp/smallops.pwd dashboard ac-user-create smallops read-only
rm -f /tmp/bigdev.pwd /tmp/smallops.pwd
```

结果：

```json
{"username": "bigdev",   "roles": ["administrator"]}
{"username": "smallops", "roles": ["read-only"]}
```

Keycloak 侧：

- `ceph-sso` realm 的 IdP `gitlab`（OIDC，`syncMode` 未显式设置 = 默认 `IMPORT`）；
- SAML client `https://10.0.0.41:8443/auth/saml2/metadata` 有 mapper：`uid` ← `username`；
- `first broker login` 流程里的 **Review Profile 已设为 DISABLED**，否则每个新用户首次登录
  都会停在“Update Account Information”页面；
- 首次 broker 登录会自动创建同名 Keycloak 用户并写入 federated identity。

实测自动导入结果：

```text
bigdev    kc_id=6148d963-…  federated: gitlab/userId=5, userName=bigdev
smallops  kc_id=41c199e1-…  federated: gitlab/userId=6, userName=smallops
```

登录链路：

```text
Ceph Dashboard (10.0.0.41:8443)
  -> Keycloak ceph-sso (SAML)
  -> Keycloak 里点 GitLab / 或已有 broker 会话
  -> GitLab 登录
  -> 回 Keycloak，首次自动建用户
  -> SAML 断言 uid=bigdev / smallops
  -> Ceph 查本地用户表，按 administrator / read-only 授权
```

## 4. 实测结果（2026-11-24）

用真实账号跑完整 Authorization Code 登录，结果如下（节选）：

```json
{"user":"bigdev","app":"grafana","detail":{"login":"bigdev","isGrafanaAdmin":true}}
{"user":"bigdev","app":"argocd","detail":{"username":"bigdev@example.com",
  "groups":["digitalsupply","bigdev@example.com"],
  "create_app_probe_http":500,"verdict":"admin"}}
{"user":"bigdev","app":"harbor","detail":{"username":"bigdev",
  "admin_role_in_auth":true,"list_users_http":200,"verdict":"admin"}}
{"user":"bigdev","app":"traefik (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"bigdev","app":"headlamp (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}

{"user":"smallops","app":"grafana","detail":{"login":"smallops","isGrafanaAdmin":false}}
{"user":"smallops","app":"argocd","detail":{"username":"smallops@example.com",
  "groups":["deeptutor","smallops@example.com"],
  "create_app_probe_http":403,"verdict":"readonly"}}
{"user":"smallops","app":"harbor","detail":{"username":"smallops",
  "admin_role_in_auth":false,"list_users_http":403,"verdict":"non-admin"}}
{"user":"smallops","app":"traefik (oauth2-proxy)","detail":{"callback_http":403,"verdict":"denied"}}
{"user":"smallops","app":"headlamp (oauth2-proxy)","detail":{"callback_http":403,"verdict":"denied"}}

{"user":"bigdev","app":"hubble (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"bigdev","app":"alloy (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"bigdev","app":"tekton (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"smallops","app":"hubble (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"smallops","app":"alloy (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
{"user":"smallops","app":"tekton (oauth2-proxy)","detail":{"protected_http":200,"verdict":"allowed"}}
```

说明：

- ArgoCD 的 `create_app_probe` 故意提交空名字：`bigdev` 通过 RBAC 后进入参数校验（500），
  `smallops` 直接被 RBAC 拒绝（403）。探针不会创建任何对象。
- Harbor 的 `sysadmin_flag` 对两者都是 `false`，但 `admin_role_in_auth` 才是 OIDC 管理员组的
  判定结果：`bigdev=true`，且能列全部用户；`smallops=false`，列用户 403。
- ArgoCD 的 `groups` 里会额外出现邮箱（ArgoCD 自身行为），不影响 `g, digitalsupply` 匹配。

## 5. 复现与验收

### 5.1 自动化脚本

仓库内提供两个脚本（都不修改业务对象）：

| 脚本 | 作用 | 依赖环境变量 |
|---|---|---|
| [assets/sso-perm-matrix-test.py](../assets/sso-perm-matrix-test.py) | 跑 Grafana/ArgoCD/Harbor/Traefik/Headlamp 的真实登录与权限探针 | `SSO_TEST_PASSWORD` |
| [assets/keycloak-broker-provision-test.py](../assets/keycloak-broker-provision-test.py) | 验证 Keycloak `ceph-sso` 自动导入 + broker 登录（会临时建/删一个 client） | `KEYCLOAK_ADMIN_PASSWORD`、`SSO_TEST_PASSWORD` |

```bash
cd docs/13-sso-oidc/assets
SSO_TEST_PASSWORD='<bigdev/smallops 密码>' python3 sso-perm-matrix-test.py
KEYCLOAK_ADMIN_PASSWORD='<master admin 密码>' SSO_TEST_PASSWORD='<密码>' \
  python3 keycloak-broker-provision-test.py
```

第一个脚本退出码 0 表示每个用户的 8 项检查（Grafana/ArgoCD/Harbor + 5 个 oauth2-proxy
实例）全部符合预期；第二个脚本退出码 0 表示两个用户都
完成带 `code` 的回跳（首次运行会自动导入用户，重复运行验证已有 federated identity 的登录）。

### 5.2 手工验收（浏览器无痕窗口）

1. **GitLab**：分别登录 `bigdev` / `smallops`，确认 `digitalsupply` / `deeptutor` 组；
2. **Grafana**：`https://grafana.k8s.local` → `bigdev` 左侧有 Server Admin，`smallops` 没有；
3. **ArgoCD**：`https://argocd.devops.com` → `bigdev` 能进 Settings 并创建 Application；
   `smallops` 只能看，创建入口/写入被拒；
4. **Harbor**：`https://192.168.67.202:8443` → `bigdev` 有“系统管理”，
   `smallops` 没有；`smallops` 仍可自动 onboard 并浏览公开项目；
5. **Traefik**：`https://traefik.xyz/dashboard/` → `bigdev` 200，`smallops` 403；
6. **Headlamp**：`https://headlamp.devops.com` → `bigdev` 200，`smallops` 403；
7. **Ceph**：`https://10.0.0.41:8443` → GitLab 登录后，`bigdev` 可进 Cluster/配置，
   `smallops` 仅只读页面；
8. **Hubble / Alloy / Tekton**：两者都可进（已收敛到 `digitalsupply` + `deeptutor` 两个组）。

> 清理 cookie：每个 UI 用独立无痕窗口，避免 GitLab 会话复用导致“看起来直接进去了”。

### 5.3 快速核对命令

```bash
# GitLab 用户与组
ssh root@192.168.67.201 'gitlab-rails runner "
User.where(username: %w[bigdev smallops]).each { |u|
  puts [u.id, u.username, u.admin].join(\"|\")
  u.members.each { |m| puts \"  #{m.source_type} #{m.source&.full_path} level=#{m.access_level}\" }
}"'

# oauth2-proxy 线上参数
for d in traefik headlamp hubble alloy tekton; do
  printf '%-9s ' "$d"
  kubectl -n oauth2-proxy get deploy oauth2-proxy-$d \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | jq -r '[.[] | select(startswith("--allowed-group"))] | join(",")'
done

# Ceph 角色
ceph dashboard ac-user-show bigdev   | jq '{username,roles}'
ceph dashboard ac-user-show smallops | jq '{username,roles}'
```

## 6. 回滚

| 层 | 操作 |
|---|---|
| GitLab 用户 | `User.find_by_username("bigdev").block!` 或删除；从组移除 |
| Grafana | 无需改动；用户下次登录按组重新落角色（可同时在 UI 里禁用用户） |
| ArgoCD | 无需改动；从组移除后重新登录即落 `role:readonly` |
| Harbor | 无需改动；移出 `digitalsupply` 后重新登录降为普通用户 |
| oauth2-proxy | 删除 `allowedGroups` 或 revert `4ce5c25`，ArgoCD 自动同步 |
| Keycloak | 删除 `ceph-sso` 里的 `bigdev`/`smallops`；如需恢复审核页，把 Review Profile 改回 `REQUIRED` |
| Ceph | `ceph dashboard ac-user-disable bigdev` / `ac-user-delete` |

## 7. 注意事项

1. **临时密码**：GitLab 是 `Temp@12345`，Ceph 是 `TempCeph@12345`，均只用于演练，
   正式使用前必须修改；账号当前未强制 2FA。
2. **initializer 不持久**：GitLab 包升级会覆盖 `doorkeeper_openid_connect.rb`，
   升级后务必确认 `groups` 仍在 `id_token` 里。
3. **组名是授权契约**：`digitalsupply` 同时是 Grafana/ArgoCD/Harbor 的管理组，
   也是 Traefik/Headlamp 的放行组；重命名组会导致全部授权失效。
4. **Headlamp 的集群管理员问题**：放行即等于 `cluster-admin`（共享 SA），
   只适合完全可信的组；要按人授权必须改原生 OIDC + apiserver OIDC（当前受 HTTP issuer 限制）。
5. **Hubble / Alloy / Tekton 已收敛到两个平台组**：`digitalsupply` 与 `deeptutor` 可进，
   其他 GitLab 账号 403。若要进一步只留 `digitalsupply`，删掉 `deeptutor` 那一行即可
   （步骤与 Traefik 相同，改 `values.yaml` 后 ArgoCD 自动同步）。
6. **oauth2-proxy 每次登录都会弹 consent**：它请求里带 `approval_prompt=force`；
   如不想每次确认，可在 GitLab 把对应 OAuth Application 标为 trusted（会降低确认强度，自行权衡）。
7. **Keycloak Review Profile 被关闭**：影响 `ceph-sso` realm 所有首次 broker 登录，
   新用户将直接以 GitLab 的邮箱/用户名建号；如需人工审核资料，改回 `REQUIRED`。
8. **Ceph 用户必须先建**：Keycloak 登录成功但 Ceph 用户不存在时，Dashboard 会报
   `UserDoesNotExist` 并跳回 SSO 错误页；新增用户时先建 Ceph 账号。
