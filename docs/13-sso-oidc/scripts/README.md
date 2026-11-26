# SSO 脚本与配置清单

本目录收录 SSO / OIDC 接入过程中用到的**脚本和配置载荷**（Keycloak↔Ceph、
GitLab OAuth 应用、Headlamp per-user RBAC 等），让文档里的命令可以直接复现。

文档位置：
- [Ceph Dashboard 经 Keycloak 接 GitLab SSO（实战记录）](../../06-storage-ceph/notes/keycloak-gitlab-ceph-saml-sso.md)
- [Keycloak 概念、工作原理与对接](../notes/10-keycloak-realm-concepts-integration.md)

## keycloak-ceph-sso/

Keycloak ↔ Ceph 侧的脚本与 JSON 载荷。

| 文件 | 用途 | 文档对应 |
|---|---|---|
| `ceph-realm.json` | Keycloak realm 导入载荷（含 GitLab OIDC 上游） | 步骤 3 / 第四节 |
| `ceph-realm-with-protocols-failed.json` | **失败的**尝试：加了 `protocols` 字段，Keycloak 26 不认，仅作反面参考 | 坑 6 |
| `ceph-saml-client.json` | Ceph Dashboard 的 SAML client 载荷（证书位置是占位符，由脚本替换） | 步骤 4 / 第五节 |
| `create-saml-client.py` | 通过 Admin API 创建/更新 SAML client，并移除 `role_list` scope | 步骤 4 |
| `e2e-saml-login.py` | 端到端验证 SAML 登录（不开浏览器，走完 4 步拿 access_token） | 步骤 6 |
| `verify-sso-chain.py` | 验证整条跳转链：Ceph → Keycloak → GitLab | 步骤 7 |
| `test-slo-logout.py` | 验证 SAML 单点登出是否真的销毁了 Keycloak 会话 | 坑 25 |
| `repro-user-switch.py` | 复现/验证“换 GitLab 用户后 Ceph 仍是旧用户”：只退 GitLab 会复用 Keycloak 会话，走 Ceph 退出（SLO）才换人 | [19](../notes/19-ceph-sso-switch-user-stale-session.md) |

### 用法

```bash
cd keycloak-ceph-sso

# 1. 先按文档生成 SP 证书
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/saml_sp.key -out /tmp/saml_sp.crt \
  -days 3650 -subj '/CN=ceph-dashboard'

# 2. 创建 SAML client（脚本会读取 ceph-saml-client.json 并替换证书占位符）
python3 create-saml-client.py

# 3. 验证
python3 verify-sso-chain.py     # 跳转链
python3 e2e-saml-login.py       # 端到端登录
python3 test-slo-logout.py      # 登出链路
python3 repro-user-switch.py    # 换用户后仍是旧用户？
```

所有脚本都支持用环境变量覆盖地址和账号，见各文件头部的说明：
`KC_BASE_URL`、`CEPH_DASH_URL`、`KC_REALM`、`KC_USER`、`KC_PASS`、`SP_CERT` 等。

> **注意**：`ceph-realm.json` 里的 `clientSecret` 是 GitLab OAuth 应用的
> 真实 secret。如果这份仓库是公开的，请先替换成你自己的占位值再提交。

## headlamp-rbac/

Headlamp 改为“用户粘贴 k8s Bearer Token”后，按用户签发 token 与验证
RBAC 边界的脚本。

| 文件 | 用途 | 文档对应 |
|---|---|---|
| `get-token.sh` | 为 `root` / `bigdev` 签发对应 ServiceAccount 的 token（默认 24h） | 第六节 |
| `verify-rbac.sh` | 用 `kubectl auth can-i --as=system:serviceaccount:...` 验证权限矩阵 | 第五节 |

### 用法

```bash
cd headlamp-rbac

# 签发 token（stdout 是整行 JWT，提示信息在 stderr）
./get-token.sh root 8h
./get-token.sh bigdev 24h

# 验证两个 SA 的权限边界
./verify-rbac.sh
```

> 签发需要一份能创建 ServiceAccount token 的 kubeconfig（通常是管理员）。
> token 等同于密码，不要提交到仓库或贴到聊天记录。

文档：[17 · Headlamp 登录令牌与按用户 RBAC](../notes/17-headlamp-token-login-per-user-rbac.md)

## gitlab-oauth/

GitLab 侧的 Ruby 脚本，通过 `gitlab-rails runner` 在 GitLab 服务器上执行。

| 文件 | 用途 | 文档对应 |
|---|---|---|
| `query-oauth-apps.rb` | 查询所有 OAuth 应用（含 redirect_uri / scopes） | 坑 22 |
| `fix-oauth-redirect-uri.rb` | 直接改库修正 redirect_uri | 坑 22 |
| `create-oauth-app.rb` | 创建 OAuth 应用（带 `organization_id`） | 步骤 3 |

### 用法

```bash
# 在 GitLab 服务器上（hao@192.168.67.201）
sudo gitlab-rails runner /path/to/query-oauth-apps.rb
sudo gitlab-rails runner /path/to/fix-oauth-redirect-uri.rb
sudo gitlab-rails runner /path/to/create-oauth-app.rb
```

> GitLab 19.5 没有 `OAuthApplication` 这个模型常量，脚本一律用
> `ActiveRecord::Base.connection` 执行 SQL。

## 已有脚本

| 文件 | 用途 |
|---|---|
| `gitlab-create-oauth-app.sh` | 用 GitLab API 创建 OAuth 应用并 seal 成 SealedSecret |
| `verify_sso.sh` | 一键验证 discovery、5 个 UI、ArgoCD、Grafana、Harbor |
