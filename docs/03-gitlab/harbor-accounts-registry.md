# Harbor 账号体系与镜像仓库

## 当时的情况

本环境用 Harbor 作为唯一镜像仓库：

- Harbor **v2.14.5**，安装在 `192.168.67.202`；
- HTTPS `8443`，HTTP `8080` 只做跳转；
- 认证方式为 **OIDC**，身份提供方是 GitLab；
- 5 个项目，部分 public、部分 private；
- 集群和 GitLab Runner 都通过 imagePullSecret 从 Harbor 拉镜像；
- 当前**没有 Robot 账号、没有项目 Webhook、没有复制策略**；
- `harbor-auth` / `harbor-pull` 两个 imagePullSecret 实际都使用 `admin`。

## 主要概念与原理

### 1. 对象模型

```text
Registry
  └── Project（项目）
        └── Repository（仓库）
              └── Tag（标签）
```

- **Project**：权限和配额边界；public/private。
- **Repository**：一个镜像名，例如 `openwebui/open-webui`。
- **Tag**：版本；应配合不可变 tag/保留策略。

### 2. 项目角色

| 角色 | 典型权限 |
|---|---|
| Limited Guest | 只读、不能 pull 私有项目 |
| Guest | 只读 |
| Developer | push/pull |
| Maintainer | 管理项目、扫描、Webhook |
| Project Admin | 项目管理员 |
| System Admin | 全局管理员 |

### 3. 账号类型

| 类型 | 说明 | 用途 |
|---|---|---|
| Local DB user | Harbor 本地用户 | 本地 admin、应急 |
| OIDC user | GitLab 登录后自动 onboard | 普通用户 |
| Robot account | 项目级/系统级机器账号 | CI push、集群 pull |
| System admin | 全局管理员 | 管理 Harbor |

本环境实际是 **OIDC + 本地 admin**：

- 本地 `admin`：`sysadmin_flag=true`；
- 本地 `root`：`sysadmin_flag=false`，邮箱是 GitLab 的占位邮箱
  （`gitlab_admin_<id>@example.com`）；
- 普通用户通过 GitLab OIDC 登录，`auto_onboard=true` 自动创建；
- 自助注册关闭；
- 项目创建限制为 `everyone`（登录用户都能建项目）。

### 4. OIDC 实际配置

| 项 | 值 |
|---|---|
| `auth_mode` | `oidc_auth` |
| `oidc_name` | GitLab |
| `oidc_endpoint` | `http://192.168.67.201` |
| `oidc_client_id` | 与 GitLab OAuth Application `harbor` 对应 |
| `oidc_scope` | `openid,profile,email` |
| `oidc_user_claim` | `preferred_username` |
| `oidc_groups_claim` | `groups` |
| `oidc_auto_onboard` | `true` |
| `oidc_verify_cert` | `false` |
| `oidc_admin_group` | `digitalsupply` |

> **重要安全影响**：GitLab 组 `digitalsupply` 的成员通过 OIDC 登录 Harbor 后，
> 因为 `oidc_admin_group=digitalsupply`，会成为 Harbor 管理员。
> 必须严格控制该组成员。

### 5. Robot 账号

Robot 是 Harbor 推荐给 CI/CD 和集群使用的机器账号：

- 项目级或系统级；
- 权限按 repository + action（pull/push/delete）；
- 有 expiration；
- 生成后只显示一次 secret；
- 适合放到 Kubernetes `imagePullSecret` 或 CI 变量。

本环境**没有创建 Robot**，而是直接用 `admin` 做 pull/push，这是需要改进的点。

### 6. imagePullSecret

Kubernetes 拉私有镜像需要 dockerconfigjson：

```bash
kubectl create secret docker-registry harbor-pull \
  --docker-server=192.168.67.202:8443 \
  --docker-username='robot$project+pull' \
  --docker-password='<robot-secret>' \
  -n <namespace>
```

然后：

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: harbor-pull
```

### 7. 其他能力

- **Trivy 扫描**：镜像漏洞扫描；
- **Immutable tags**：禁止覆盖已有 tag；
- **Retention**：按数量/天数清理 tag；
- **Replication**：多 Harbor 实例复制（本环境未配置）；
- **Proxy Cache**：代理上游 registry（本环境未配置）；
- **Webhook**：push/pull/delete/scan 事件通知（本环境未配置）；
- **Quota**：项目存储/仓库数限制。

## 实际项目

| 项目 | 可见性 | 仓库数 | 成员 |
|---|---|---:|---|
| `library` | Public | 2 | admin（Project Admin） |
| `deeptutor` | Public | 6 | admin（Project Admin） |
| `compassio` | Private | 7 | admin（Project Admin） |
| `openwebui` | Private | 11 | admin（Project Admin） |
| `china-study-free` | Private | 2 | admin（Project Admin） |

- 没有 Robot；
- 没有项目 Webhook；
- 没有 Registry/Replication；
- 所有项目成员只有 `admin`。

## 实际镜像与拉取

集群中使用的 Harbor 镜像示例：

```text
192.168.67.202:8443/china-study-free/web:694f79f
192.168.67.202:8443/compassio/backend:05f030...
192.168.67.202:8443/compassio/frontend:05f030...
192.168.67.202:8443/deeptutor/deeptutor:870f2d...
192.168.67.202:8443/deeptutor/redis:7.4-alpine
192.168.67.202:8443/openwebui/gitlab-runner:alpine-v17.8.3
192.168.67.202:8443/openwebui/kaniko:v1.23.2
```

imagePullSecret：

| namespace | Secret | 实际用户名 |
|---|---|---|
| china-study-free | `harbor-auth` | `admin` |
| cicd | `harbor-auth` | `admin` |
| compassio | `harbor-auth` | `admin` |
| gitlab-runner | `harbor-auth` | `admin` |
| open-webui | `harbor-pull` | `admin` |

## 踩坑点

### 坑 1：OIDC admin group 过大

`digitalsupply` 组的所有成员都会成为 Harbor 管理员。
如果 GitLab 组里有外部人员/临时成员，Harbor 权限会被放大。

### 坑 2：OIDC 使用 HTTP 且不校验证书

`oidc_endpoint` 是 `http://192.168.67.201`，`oidc_verify_cert=false`。
OIDC 流程中的 token/用户信息在明文 HTTP 上传输，存在被截获风险。
应给 GitLab 配 HTTPS，并打开 OIDC 证书校验。

### 坑 3：自签证书

Harbor 使用自签证书（`has_ca_root=false`）。客户端需要：

- 导入 CA 到系统/容器运行时；或
- 配置 insecure registry（不推荐生产）。

### 坑 4：端口不是 80/443

实际是 HTTP 8080（跳转）、HTTPS 8443。
按 80/443 配置会连不上。

### 坑 5：用 admin 做 imagePullSecret

`harbor-auth` / `harbor-pull` 都是 admin。任何能读该 Secret 的 Pod/用户
都拿到了 Harbor 系统管理员凭据。

### 坑 6：Public 项目

`library` 和 `deeptutor` 是 public，镜像可被匿名拉取。
确认里面没有敏感镜像/基础镜像泄露风险。

## 修复关键 / 建议

1. **为每个项目创建 Robot**：
   - 集群 pull-only：`repository:pull`；
   - CI push：`repository:pull,push`；
   - 设置 expiration；
2. **替换 imagePullSecret** 中的 admin 为 Robot；
3. **打开 OIDC 证书校验**，GitLab 上 HTTPS；
4. **收紧 `digitalsupply` 组**，或把 `oidc_admin_group` 改成更小的管理组；
5. **开启 Trivy 扫描**（已启用）并定期看报告；
6. **配置 immutable tag + retention**，避免 tag 覆盖和磁盘膨胀；
7. **需要时再配 Webhook/Replication**，不要默认全开。

## 验证命令

```bash
# 系统信息
curl -k https://192.168.67.202:8443/api/v2.0/systeminfo | jq

# 项目
curl -k -u admin:<password> \
  'https://192.168.67.202:8443/api/v2.0/projects?page_size=100' | jq

# 项目成员
curl -k -u admin:<password> \
  'https://192.168.67.202:8443/api/v2.0/projects/openwebui/members' | jq

# 项目 Robot
curl -k -u admin:<password> \
  'https://192.168.67.202:8443/api/v2.0/projects/openwebui/robots?page_size=100' | jq

# 本地 docker 登录（不要写进历史）
docker login 192.168.67.202:8443 -u 'robot$openwebui+pull'
```

> Harbor 的 admin 密码、数据库密码、OIDC client secret 都在 Harbor 主机
> `/root/harbor/harbor.yml` 或 Harbor DB 中，**不要复制到 Git/文档**。
