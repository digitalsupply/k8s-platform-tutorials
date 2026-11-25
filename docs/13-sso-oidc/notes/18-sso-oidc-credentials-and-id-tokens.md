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
| Headlamp / SSO id_token | 运维机（能 `ssh root@192.168.67.201` 且能访问 `http://192.168.67.201`） | `python3`（仅标准库）+ `ssh`，命令见第 5.2 节 |
| Headlamp 控制台粘贴的 Token | 有 kubeconfig 的管理机（本机） | `kubectl create token`（见第 6 节） |

> 说明：以下命令默认在**有相应权限的运维机**上执行；涉及 `ssh`、`kubectl`、`ceph` 的命令需要对应凭据与 RBAC。

## 速查：关键凭据一览

| 凭据 | 获取命令（执行机器） | 详细位置 |
|---|---|---|
| **GitLab `root` 账号密码** | `ssh root@192.168.67.201 "sed -n 's/^Password: //p' /etc/gitlab/initial_root_password"` | [1.1](#11-gitlab-root-账号密码) |
| GitLab 普通用户密码（`bigdev`/`smallops`） | 临时密码，无落盘；通过 Admin UI / `gitlab-rails runner` 设置 | [1.2](#12-普通用户bigdev--smallops密码) |
| GitLab PAT（推送/自动化） | `kubectl -n cicd get secret gitlab-auth -o jsonpath='{.data.token}' \| base64 -d` | [1.3](#13-gitlab-pat自动化--git-推送) |
| GitLab OAuth `client_secret` | `ssh root@192.168.67.201 "gitlab-rails runner 'puts Doorkeeper::Application.find_by_name(%q(grafana)).secret'"` | [1.4](#14-gitlab-oauth-应用-client_secret各-sso-应用共用-gitlab-侧凭据) |
| Keycloak 管理员 | `kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-password}' \| base64 -d` | [2.1](#21-keycloak-自身管理员) |
| `ceph-sso` 用户 / GitLab 映射 | Keycloak Admin API（见 2.2） | [2.2](#22-ceph-sso-realm-用户与-gitlab-映射) |
| K8s Secret（oauth2-* 等） | `kubectl -n <ns> get secret <name> -o jsonpath='{.data}'` | [3](#3-k8s-secret) |
| Ceph admin key | `ceph auth print-key client.admin` | [4.1](#41-ceph-管理员-keyring) |
| Headlamp 用户 id_token | 复制第 5.2 节整段命令执行（只改 `APP`/`USER_NAME`/`USER_PW`） | [5](#5-headlamp不同用户身份验证的-id_token) |
| **Headlamp 弹窗要粘贴的 Token** | `kubectl -n headlamp create token headlamp-root --duration=24h` | 第 6 节 |

## 1. GitLab（所有用户）

### 1.1 GitLab `root` 账号密码

`root` 是 GitLab 全局管理员。其密码是**首次安装生成的初始密码**，保存在部署机文件里，
这是当前唯一能“直接获取” root 密码的方式（GitLab 库内只存哈希，无法反查）：

```bash
# 执行机器：192.168.67.201（GitLab 本机）
ssh -o BatchMode=yes root@192.168.67.201 \
  "sed -n 's/^Password: //p' /etc/gitlab/initial_root_password"
```

> 注意：该文件在 `gitlab-ctl reconfigure` 后 **24 小时会被自动删除**。若已不存在，
> 用 `ssh root@192.168.67.201 "gitlab-rake 'gitlab:password:reset[root]'"` 重置，
> 或改用 GitLab 管理员在 Admin UI 重置。

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

**不同用户的身份差异，体现在各自 id_token 的 `sub` / `groups` 上。** 下面这条命令可以直接复制执行：
只用 Python 3 标准库，**不依赖仓库里的任何脚本文件，也不需要 pip 安装依赖**。

> 注意：如果你要的是 Headlamp 页面 `…/c/main/token` 弹窗里**粘贴**的那个 token，它不是 id_token，
> 而是 k8s ServiceAccount token —— 直接看本文第 6 节。

### 5.2 获取命令（复制即可执行）

**执行机器**：任意一台满足以下两个条件的运维机（本文场景就是平时执行 `kubectl` 的那台）：

- 能 `ssh root@192.168.67.201`（用于读取该 OAuth 应用的 `client_id/secret/redirect_uri`）；
- 能访问 `http://192.168.67.201`（GitLab 登录、换 token）。

```bash
# 只改首行三个变量：APP / USER_NAME / USER_PW
APP=oauth2-headlamp USER_NAME=bigdev USER_PW='Temp@12345' python3 - <<'PY'
# 获取指定 GitLab 用户在某 OAuth 应用下的 OIDC id_token，并解码身份 claim。
# 只依赖 Python 标准库；通过 ssh 读取 GitLab OAuth 应用凭据，不需要任何额外脚本文件。
# 环境变量：GITLAB / GITLAB_SSH / APP / USER_NAME / USER_PW
import base64, http.cookiejar, json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request

GITLAB = os.environ.get("GITLAB", "http://192.168.67.201")
SSH = os.environ.get("GITLAB_SSH", "root@192.168.67.201")
APP = os.environ.get("APP", "oauth2-headlamp")
USER = os.environ.get("USER_NAME", "bigdev")
PW = os.environ.get("USER_PW", "")

ruby = (
    "puts JSON.generate({uid: Doorkeeper::Application.find_by_name(%q(" + APP + ")).uid, "
    "secret: Doorkeeper::Application.find_by_name(%q(" + APP + ")).secret, "
    "redirect_uri: Doorkeeper::Application.find_by_name(%q(" + APP + ")).redirect_uri})"
)
if SSH in ("", "local"):
    out = subprocess.check_output(["gitlab-rails", "runner", ruby], text=True).strip()
else:
    out = subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", SSH, "gitlab-rails runner '" + ruby + "'"], text=True
    ).strip()
creds = json.loads(out)

jar = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(jar))
opener.addheaders = [("User-Agent", "id-token-probe/1.0")]


def call(url, data=None):
    try:
        r = opener.open(urllib.request.Request(url, data=data), timeout=20)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


# 1) 表单登录 GitLab
_, _, body = call(GITLAB + "/users/sign_in")
m = re.search(r'name="authenticity_token" value="([^"]+)"', body)
if not m:
    sys.exit("登录页未找到 CSRF token")
code, _, _ = call(GITLAB + "/users/sign_in", urllib.parse.urlencode({
    "authenticity_token": m.group(1),
    "user[login]": USER,
    "user[password]": PW,
    "user[remember_me]": "0",
}).encode())
if code != 302:
    sys.exit(f"GitLab 登录失败: HTTP {code}（检查用户名/密码）")

# 2) 走 /oauth/authorize 拿 code（必要时提交授权同意页）
auth_url = (
    f"{GITLAB}/oauth/authorize?client_id={creds['uid']}&response_type=code"
    f"&scope=openid+profile+email&state=idtoken-probe"
    f"&redirect_uri={urllib.parse.quote(creds['redirect_uri'], safe='')}"
)
code, h, body = call(auth_url)
callback = h.get("Location") if code in (301, 302, 303, 307, 308) else None
if not callback:
    m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', body)
    if m:
        callback = m.group(1).replace("&amp;", "&")
    else:
        for form in re.findall(r"<form\b.*?</form>", body, re.S):
            if 'value="delete"' in form:  # 跳过 Deny 表单
                continue
            data = {}
            for tag in re.findall(r"<input\b[^>]*>", form):
                n = re.search(r'name="([^"]+)"', tag)
                v = re.search(r'value="([^"]*)"', tag)
                if n:
                    data[n.group(1)] = v.group(1) if v else ""
            if "client_id" not in data:
                continue
            data.setdefault("commit", "Authorize")
            c, hh, bb = call(GITLAB + "/oauth/authorize", urllib.parse.urlencode(data).encode())
            callback = hh.get("Location") if c in (301, 302, 303, 307, 308) else None
            if not callback:
                m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', bb)
                if m:
                    callback = m.group(1).replace("&amp;", "&")
            break
if not callback:
    sys.exit("未能完成 GitLab authorize")
m = re.search(r"code=([0-9a-f]+)", callback)
if not m:
    sys.exit(f"回调里没有 code: {callback}")

# 3) code 换 token，取 id_token 并解码 payload
code, _, body = call(GITLAB + "/oauth/token", urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "code": m.group(1),
    "client_id": creds["uid"],
    "client_secret": creds["secret"],
    "redirect_uri": creds["redirect_uri"],
}).encode())
if code != 200:
    sys.exit(f"换 token 失败: HTTP {code} {body[:300]}")
tok = json.loads(body)
if "id_token" not in tok:
    sys.exit(f"响应里没有 id_token: {list(tok)}")

p = tok["id_token"].split(".")[1]
p += "=" * (-len(p) % 4)
payload = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({"user": USER, "app": APP, "client_id": creds["uid"],
                  "id_token_payload": payload}, indent=2, ensure_ascii=False))
PY
```

换用户 / 换 UI 只改首行三个变量，代码块原样复用：

```bash
APP=oauth2-headlamp USER_NAME=smallops USER_PW='Temp@12345' python3 - <<'PY'   # smallops 看 Headlamp
APP=grafana          USER_NAME=bigdev   USER_PW='Temp@12345' python3 - <<'PY'   # bigdev 看 Grafana
```

只想看关键 claim 时，在首行末尾加管道（代码块不变）：

```bash
APP=oauth2-headlamp USER_NAME=bigdev USER_PW='Temp@12345' \
python3 - <<'PY' | jq -c '{user, sub: .id_token_payload.sub, groups: .id_token_payload.groups}'
# 获取指定 GitLab 用户在某 OAuth 应用下的 OIDC id_token，并解码身份 claim。
# 只依赖 Python 标准库；通过 ssh 读取 GitLab OAuth 应用凭据，不需要任何额外脚本文件。
# 环境变量：GITLAB / GITLAB_SSH / APP / USER_NAME / USER_PW
import base64, http.cookiejar, json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request

GITLAB = os.environ.get("GITLAB", "http://192.168.67.201")
SSH = os.environ.get("GITLAB_SSH", "root@192.168.67.201")
APP = os.environ.get("APP", "oauth2-headlamp")
USER = os.environ.get("USER_NAME", "bigdev")
PW = os.environ.get("USER_PW", "")

ruby = (
    "puts JSON.generate({uid: Doorkeeper::Application.find_by_name(%q(" + APP + ")).uid, "
    "secret: Doorkeeper::Application.find_by_name(%q(" + APP + ")).secret, "
    "redirect_uri: Doorkeeper::Application.find_by_name(%q(" + APP + ")).redirect_uri})"
)
if SSH in ("", "local"):
    out = subprocess.check_output(["gitlab-rails", "runner", ruby], text=True).strip()
else:
    out = subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", SSH, "gitlab-rails runner '" + ruby + "'"], text=True
    ).strip()
creds = json.loads(out)

jar = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(jar))
opener.addheaders = [("User-Agent", "id-token-probe/1.0")]


def call(url, data=None):
    try:
        r = opener.open(urllib.request.Request(url, data=data), timeout=20)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


# 1) 表单登录 GitLab
_, _, body = call(GITLAB + "/users/sign_in")
m = re.search(r'name="authenticity_token" value="([^"]+)"', body)
if not m:
    sys.exit("登录页未找到 CSRF token")
code, _, _ = call(GITLAB + "/users/sign_in", urllib.parse.urlencode({
    "authenticity_token": m.group(1),
    "user[login]": USER,
    "user[password]": PW,
    "user[remember_me]": "0",
}).encode())
if code != 302:
    sys.exit(f"GitLab 登录失败: HTTP {code}（检查用户名/密码）")

# 2) 走 /oauth/authorize 拿 code（必要时提交授权同意页）
auth_url = (
    f"{GITLAB}/oauth/authorize?client_id={creds['uid']}&response_type=code"
    f"&scope=openid+profile+email&state=idtoken-probe"
    f"&redirect_uri={urllib.parse.quote(creds['redirect_uri'], safe='')}"
)
code, h, body = call(auth_url)
callback = h.get("Location") if code in (301, 302, 303, 307, 308) else None
if not callback:
    m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', body)
    if m:
        callback = m.group(1).replace("&amp;", "&")
    else:
        for form in re.findall(r"<form\b.*?</form>", body, re.S):
            if 'value="delete"' in form:  # 跳过 Deny 表单
                continue
            data = {}
            for tag in re.findall(r"<input\b[^>]*>", form):
                n = re.search(r'name="([^"]+)"', tag)
                v = re.search(r'value="([^"]*)"', tag)
                if n:
                    data[n.group(1)] = v.group(1) if v else ""
            if "client_id" not in data:
                continue
            data.setdefault("commit", "Authorize")
            c, hh, bb = call(GITLAB + "/oauth/authorize", urllib.parse.urlencode(data).encode())
            callback = hh.get("Location") if c in (301, 302, 303, 307, 308) else None
            if not callback:
                m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', bb)
                if m:
                    callback = m.group(1).replace("&amp;", "&")
            break
if not callback:
    sys.exit("未能完成 GitLab authorize")
m = re.search(r"code=([0-9a-f]+)", callback)
if not m:
    sys.exit(f"回调里没有 code: {callback}")

# 3) code 换 token，取 id_token 并解码 payload
code, _, body = call(GITLAB + "/oauth/token", urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "code": m.group(1),
    "client_id": creds["uid"],
    "client_secret": creds["secret"],
    "redirect_uri": creds["redirect_uri"],
}).encode())
if code != 200:
    sys.exit(f"换 token 失败: HTTP {code} {body[:300]}")
tok = json.loads(body)
if "id_token" not in tok:
    sys.exit(f"响应里没有 id_token: {list(tok)}")

p = tok["id_token"].split(".")[1]
p += "=" * (-len(p) % 4)
payload = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({"user": USER, "app": APP, "client_id": creds["uid"],
                  "id_token_payload": payload}, indent=2, ensure_ascii=False))
PY
```

`root` 的密码不要手抄，用命令替换现场读取（代码块不变，只改首行）：

```bash
APP=oauth2-headlamp USER_NAME=root \
USER_PW="$(ssh root@192.168.67.201 "sed -n 's/^Password: //p' /etc/gitlab/initial_root_password")" \
python3 - <<'PY'
# 获取指定 GitLab 用户在某 OAuth 应用下的 OIDC id_token，并解码身份 claim。
# 只依赖 Python 标准库；通过 ssh 读取 GitLab OAuth 应用凭据，不需要任何额外脚本文件。
# 环境变量：GITLAB / GITLAB_SSH / APP / USER_NAME / USER_PW
import base64, http.cookiejar, json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request

GITLAB = os.environ.get("GITLAB", "http://192.168.67.201")
SSH = os.environ.get("GITLAB_SSH", "root@192.168.67.201")
APP = os.environ.get("APP", "oauth2-headlamp")
USER = os.environ.get("USER_NAME", "bigdev")
PW = os.environ.get("USER_PW", "")

ruby = (
    "puts JSON.generate({uid: Doorkeeper::Application.find_by_name(%q(" + APP + ")).uid, "
    "secret: Doorkeeper::Application.find_by_name(%q(" + APP + ")).secret, "
    "redirect_uri: Doorkeeper::Application.find_by_name(%q(" + APP + ")).redirect_uri})"
)
if SSH in ("", "local"):
    out = subprocess.check_output(["gitlab-rails", "runner", ruby], text=True).strip()
else:
    out = subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", SSH, "gitlab-rails runner '" + ruby + "'"], text=True
    ).strip()
creds = json.loads(out)

jar = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(jar))
opener.addheaders = [("User-Agent", "id-token-probe/1.0")]


def call(url, data=None):
    try:
        r = opener.open(urllib.request.Request(url, data=data), timeout=20)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


# 1) 表单登录 GitLab
_, _, body = call(GITLAB + "/users/sign_in")
m = re.search(r'name="authenticity_token" value="([^"]+)"', body)
if not m:
    sys.exit("登录页未找到 CSRF token")
code, _, _ = call(GITLAB + "/users/sign_in", urllib.parse.urlencode({
    "authenticity_token": m.group(1),
    "user[login]": USER,
    "user[password]": PW,
    "user[remember_me]": "0",
}).encode())
if code != 302:
    sys.exit(f"GitLab 登录失败: HTTP {code}（检查用户名/密码）")

# 2) 走 /oauth/authorize 拿 code（必要时提交授权同意页）
auth_url = (
    f"{GITLAB}/oauth/authorize?client_id={creds['uid']}&response_type=code"
    f"&scope=openid+profile+email&state=idtoken-probe"
    f"&redirect_uri={urllib.parse.quote(creds['redirect_uri'], safe='')}"
)
code, h, body = call(auth_url)
callback = h.get("Location") if code in (301, 302, 303, 307, 308) else None
if not callback:
    m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', body)
    if m:
        callback = m.group(1).replace("&amp;", "&")
    else:
        for form in re.findall(r"<form\b.*?</form>", body, re.S):
            if 'value="delete"' in form:  # 跳过 Deny 表单
                continue
            data = {}
            for tag in re.findall(r"<input\b[^>]*>", form):
                n = re.search(r'name="([^"]+)"', tag)
                v = re.search(r'value="([^"]*)"', tag)
                if n:
                    data[n.group(1)] = v.group(1) if v else ""
            if "client_id" not in data:
                continue
            data.setdefault("commit", "Authorize")
            c, hh, bb = call(GITLAB + "/oauth/authorize", urllib.parse.urlencode(data).encode())
            callback = hh.get("Location") if c in (301, 302, 303, 307, 308) else None
            if not callback:
                m = re.search(r'(https?://[^"\'<>\s]+?code=[0-9a-f]+[^"\'<>\s]*)', bb)
                if m:
                    callback = m.group(1).replace("&amp;", "&")
            break
if not callback:
    sys.exit("未能完成 GitLab authorize")
m = re.search(r"code=([0-9a-f]+)", callback)
if not m:
    sys.exit(f"回调里没有 code: {callback}")

# 3) code 换 token，取 id_token 并解码 payload
code, _, body = call(GITLAB + "/oauth/token", urllib.parse.urlencode({
    "grant_type": "authorization_code",
    "code": m.group(1),
    "client_id": creds["uid"],
    "client_secret": creds["secret"],
    "redirect_uri": creds["redirect_uri"],
}).encode())
if code != 200:
    sys.exit(f"换 token 失败: HTTP {code} {body[:300]}")
tok = json.loads(body)
if "id_token" not in tok:
    sys.exit(f"响应里没有 id_token: {list(tok)}")

p = tok["id_token"].split(".")[1]
p += "=" * (-len(p) % 4)
payload = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({"user": USER, "app": APP, "client_id": creds["uid"],
                  "id_token_payload": payload}, indent=2, ensure_ascii=False))
PY
```

> 如果就在 GitLab 主机（`192.168.67.201`）上执行，可以省掉 `ssh`，加前缀
> `GITLAB=http://127.0.0.1 GITLAB_SSH=local`（需 root 权限调用 `gitlab-rails`）。

### 5.3 实测结果（2026-11-25）

| 用户 | `APP` | `sub` | `preferred_username` | `groups` |
|---|---|---|---|---|
| `bigdev` | `oauth2-headlamp` | `5` | `bigdev` | `["digitalsupply"]` |
| `smallops` | `oauth2-headlamp` | `6` | `smallops` | `["deeptutor"]` |
| `root` | `oauth2-headlamp` | `1` | `root` | `["digitalsupply","deeptutor"]` |

完整 payload 示例（`bigdev` / Headlamp，节选，`aud` 已截断）：

```json
{
  "user": "bigdev",
  "app": "oauth2-headlamp",
  "client_id": "0217d408…b4cc",
  "id_token_payload": {
    "sub": "5",
    "preferred_username": "bigdev",
    "email": "bigdev@example.com",
    "groups": ["digitalsupply"],
    "groups_direct": ["digitalsupply"],
    "iss": "http://192.168.67.201",
    "exp": 1795581577,
    "iat": 1795581457
  }
}
```

### 5.4 应用名映射

| 目标 UI | `APP`（GitLab OAuth 应用名） |
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

### 5.5 命令做了什么

1. 通过 `ssh root@192.168.67.201` + `gitlab-rails runner` 读取该 OAuth 应用的
   `client_id / client_secret / redirect_uri`（**只读**，不修改 GitLab 任何对象）；
2. 以目标用户表单登录 GitLab：`GET /users/sign_in` 取 CSRF，再 `POST /users/sign_in`；
3. 访问 `/oauth/authorize` 拿 `code`；若该应用尚未被该用户授权，自动提交**同意页**
   （GitLab 同时渲染 Authorize 与 Deny 两个表单，只提交 Authorize）；
4. 用回调地址里的 `code` 调 `/oauth/token` 换 token，取 `id_token`；
5. 解码 JWT payload 并打印。

> 关键点：命令**不会真的访问** `redirect_uri`（`https://headlamp.devops.com/oauth2/callback`），
> 只是从 `Location` 头里把 `code` 取出来，所以执行机器不需要能解析这些业务域名。
> 手工用 `curl` 拼这套流程很容易漏掉 CSRF / 同意页，建议直接用上面的代码。

## 6. Headlamp 控制台粘贴的 Token（k8s Bearer Token）

### 6.1 先分清两个 token

打开 `https://headlamp.devops.com`，GitLab 登录后若出现
**“Please paste your authentication token.”**（`…/c/main/token`），它要的是
**Kubernetes ServiceAccount Bearer Token**，**不是**第 5 节的 OIDC id_token。

| 对比项 | OIDC id_token（第 5 节） | k8s Bearer Token（本节） |
|---|---|---|
| 签发者 | GitLab | kube-apiserver |
| 谁生成 | oauth2-proxy 自动完成 | `kubectl create token` |
| `sub` | GitLab 用户 ID，如 `1`、`5`、`6` | `system:serviceaccount:headlamp:headlamp-root` |
| 证明什么 | “你是 GitLab 的哪个用户” | “以哪个 k8s 身份操作集群” |
| 喂给谁 | oauth2-proxy（用户看不到） | Headlamp 的 **Headlamp Cluster Authentication** 弹窗 |
| 有效期 | `120` 秒 | `--duration` 决定，默认 1h |
| 能不能互换 | 不能，apiserver 不认 GitLab 的 id_token | 不能，oauth2-proxy 不认 k8s token |

> 为什么会弹这个：Headlamp 已移除 `-unsafe-use-service-account-token`，不再自动拿 Pod 里的
> SA token 当登录身份。GitLab 登录只通过了 oauth2-proxy 那一层，进集群还需要一个 **k8s 身份**。
> 设计与权限矩阵见 [17-headlamp-token-login-per-user-rbac.md](17-headlamp-token-login-per-user-rbac.md)。

### 6.2 获取命令

**执行机器**：任意一台**有能创建 ServiceAccount token 的 kubeconfig** 的机器（管理员机器，本文即本机）。
`bigdev` / `smallops` 没有集群 kubeconfig，**发不了这个 token**，必须由管理员代发。

```bash
# root（GitLab root / lei hao）：全集群权限（cluster-admin）
kubectl -n headlamp create token headlamp-root --duration=24h

# bigdev：受限权限（权限清单见 17 号文档第五节）
kubectl -n headlamp create token headlamp-bigdev --duration=24h
```

输出是**一整行 JWT**，复制后粘贴到 Headlamp 弹窗，点 **Authenticate** 即可。

当前存在的用户 SA（2026-11-25 实测）：

```text
NAME              AGE
headlamp          （已收回业务权限，不要再用它登录）
headlamp-root     绑定 ClusterRole/cluster-admin
headlamp-bigdev   绑定 ClusterRole/headlamp-bigdev
```

> 没有 `headlamp-smallops`：`smallops` 目前**没有** Headlamp 用的 ServiceAccount。
> 需要给它发 token 的话，先建 SA + ClusterRoleBinding，再签 token。

### 6.3 粘贴前先确认拿到的是哪个身份

```bash
kubectl -n headlamp create token headlamp-root --duration=10m \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null \
  | jq -c '{sub, sa: ."kubernetes.io".serviceaccount.name, exp, iat}'
```

预期（实测）：

```json
{"sub":"system:serviceaccount:headlamp:headlamp-root","sa":"headlamp-root","exp":1795584313,"iat":1795583713}
```

> `sub` 不是 GitLab 用户 ID，也不是 Keycloak UUID；它是 k8s SA 身份。
> 贴错 SA 就等于用错权限。

### 6.4 有效期、续期与吊销

- 有效期由 `--duration` 决定：默认 **1 小时**，最小 **10 分钟**，实测 `24h` 可用，建议 `8h`～`24h`；
- Headlamp 侧 `-session-ttl=86400` 只管浏览器 cookie，**不能延长** token 本身；
- 过期后 Headlamp 请求变 401/403，重新 `create token` 再粘贴即可；
- 单个 token 是**无状态 JWT，无法单独吊销**；怀疑泄漏就删 SA（该 SA 的所有 token 立即失效），
  ArgoCD 会自动从 Git 恢复：

```bash
kubectl -n headlamp delete serviceaccount headlamp-root   # 慎用：root 全权限 token 会一起失效
```

- `kubectl create token` 的输出会进 shell history，建议直接管道到剪贴板/文件，用完清理：

```bash
kubectl -n headlamp create token headlamp-root --duration=8h > /tmp/headlamp-root.jwt && chmod 600 /tmp/headlamp-root.jwt
# 粘贴完成后
shred -u /tmp/headlamp-root.jwt
```

## 7. 安全性建议

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
