# GitLab 账号体系与角色

## 当时的情况

GitLab 是本环境的代码仓库和身份中心：

- 安装在 `192.168.67.201`，Omnibus 方式，**19.5.0 CE**；
- `external_url` 是 `http://192.168.67.201`，当前监听 80；
- 容器 registry **未启用**；
- 只有两个用户：`root` 和 `GitLabDuo`；
- 11 个项目、2 个组，全部 private；
- 同时作为 Grafana、ArgoCD、Harbor 等系统的 OAuth/OIDC 提供方。

这个规模下，“谁能登录、谁能推代码、谁能改 CI、谁能进 ArgoCD/Harbor”
基本都绕不开 GitLab 的账号和组。

## 主要概念与原理

### 1. 三层对象

```text
User（用户）
  └── Group（组 / namespace）
        └── Project（项目 / repository）
```

- **User**：登录主体；可以是普通用户或 service account。
- **Group**：团队/命名空间，可嵌套；组权限会向下继承到项目。
- **Project**：代码仓库、Issue、CI/CD、Webhook 的归属对象。

### 2. 可见性

| 级别 | 值 | 含义 |
|---|---:|---|
| Private | 0 | 只有成员可见 |
| Internal | 10 | 登录用户可见 |
| Public | 20 | 所有人可见 |

本环境所有组和项目都是 **Private（0）**。

### 3. 角色（Role）

| 角色 | 典型权限 |
|---|---|
| Guest | 看 Issue，不能看代码 |
| Reporter | 看代码、下载、看 CI 结果 |
| Developer | 推送分支、创建 MR、跑 CI |
| Maintainer | 改项目设置、保护分支、Webhook、CI 变量 |
| Owner | 删除项目、转移项目、管理成员 |

组角色会继承到项目；项目可以单独覆盖成员角色。

### 4. 认证方式

GitLab 支持：

- 本地数据库用户名/密码；
- LDAP / Active Directory；
- SAML / OIDC（作为客户端）；
- OAuth2 / OIDC **提供方**（给别的系统做 SSO）。

本环境 `gitlab.rb` 只配置了 `external_url`，没有 LDAP/OIDC 客户端配置，
所以 GitLab 本身使用**本地数据库认证**；同时通过 OAuth Application 给
Grafana、ArgoCD、Harbor 等提供 SSO。

### 5. 实际用户与组

| 用户 | 管理员 | 说明 |
|---|---|---|
| `root` | 是 | 初始管理员，当前自动化也大量使用它 |
| `GitLabDuo` | 否 | 服务账号（非管理员） |

| 组 | 可见性 |
|---|---|
| `digitalsupply` | Private |
| `deeptutor` | Private |

### 6. 实际项目（11 个，均 Private）

```text
digitalsupply/openwebui
digitalsupply/openwebui-gitops
digitalsupply/compassio
digitalsupply/compassio-gitops
digitalsupply/ChinaStudyFree
digitalsupply/china-study-free-gitops
digitalsupply/tekton-platform-gitops
digitalsupply/platform-gitops
digitalsupply/k8s-platform-tutorials
deeptutor/deeptutor
deeptutor/deeptutor-gitops
```

### 7. 实例设置

| 设置 | 实际值 |
|---|---|
| 注册 | 关闭 |
| 2FA | 未强制 |
| Web 密码登录 | 开启 |
| 默认项目可见性 | Private |
| 默认组可见性 | Private |
| 保护分支 | 所有项目 `main`，禁止 force push |
| GitLab 容器 Registry | 未启用 |

### 8. GitLab 作为 SSO 提供方

实际存在这些 OAuth Application：

| 应用 | 回调地址（示例） | Scope |
|---|---|---|
| `grafana` | `https://grafana.k8s.local/login/generic_oauth` | openid profile email |
| `argocd` | `https://argocd.devops.com/auth/callback` | openid profile email |
| `harbor` | `https://192.168.67.202:8443/c/oidc/callback` | openid profile email |
| `oauth2-hubble` | `https://hubble.xyz/oauth2/callback` | openid profile email |
| `oauth2-alloy` | `https://alloy.xyz/oauth2/callback` | openid profile email |
| `oauth2-tekton` | `https://tekton.xyz/oauth2/callback` | openid profile email |
| `oauth2-traefik` | `https://traefik.xyz/oauth2/callback` | openid profile email |

> `harbor` 这个 OAuth Application 就是 Harbor OIDC 的来源；
> Harbor 的 `oidc_client_id` 与它对应。client secret 不在文档中。

## 踩坑点

### 坑 1：认为 GitLab 有 LDAP/OIDC 登录

实际没有；GitLab 是本地 DB 认证。SSO 是 GitLab 作为**提供方**给别的系统用。

### 坑 2：以为有 GitLab Container Registry

`gitlab-ctl status` 没有 registry 进程，`gitlab.rb` 也没有 registry 配置。
本环境的镜像仓库是 **Harbor**，不要按 GitLab Registry 的地址去 push。

### 坑 3：沿用旧文档的 8088

早期排障时 GitLab 曾在 8088；当前 `external_url` 是
`http://192.168.67.201`，监听 80。看旧文档时要注意时间点。

### 坑 4：所有自动化都用 root

ArgoCD 的 GitLab repo secret、CI/脚本里大量使用 `root`。
这不是最小权限：一旦泄露，影响整个 GitLab。

### 坑 5：2FA 未强制、密码登录开启

管理员账号只有密码保护；建议至少给 root 开 2FA，或接入企业 SSO。

## 修复关键 / 建议

1. **按组/项目分配角色**，不要共用 root；
2. 给 ArgoCD/CI 建 **project/group access token 或 deploy token**，
   只给 `read_repository`（需要推送时再给 `write_repository`）；
3. 管理员开启 2FA，或接入 LDAP/OIDC；
4. 保护 `main`（已做），禁止 force push；
5. 私有项目保持 Private，不要为了省事改成 Public；
6. 如果启用 GitLab Registry，再单独规划 registry 证书和权限；
   当前镜像统一走 Harbor。

## 验证命令

```bash
# 版本与状态
cat /opt/gitlab/embedded/service/gitlab-rails/VERSION
gitlab-ctl status

# 用户/组/项目（只读元数据）
gitlab-rails runner 'User.pluck(:id,:username,:admin,:state)'
gitlab-rails runner 'Group.pluck(:id,:full_path,:visibility_level)'
gitlab-rails runner 'Project.pluck(:id,:path_with_namespace,:visibility_level)'

# OAuth 应用（不输出 secret）
gitlab-rails runner 'Doorkeeper::Application.pluck(:id,:name,:scopes,:redirect_uri)'
```

> 生产环境修改角色/2FA/SSO 前先在测试项目验证，避免把管理员锁在门外。
