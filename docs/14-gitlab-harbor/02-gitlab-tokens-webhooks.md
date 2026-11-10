# 02 · GitLab Token 与 Webhook 全解

## 当时的情况

本环境里 GitLab 同时承担：

- 代码仓库（ArgoCD 拉取 GitOps 仓库）；
- CI 触发源（Runner、Webhook）；
- 身份提供方（Harbor/ArgoCD/Grafana 的 OIDC/OAuth）。

因此 GitLab 的 token 和 webhook 实际上贯穿了整条 GitOps/CI-CD 链路。
当前环境有一个明显问题：**自动化大量使用 root 的 PAT 或 root 密码**。

## 主要概念与原理

### 1. Token 类型总览

| 类型 | 归属 | 用途 | 典型场景 |
|---|---|---|---|
| Personal Access Token (PAT) | 用户 | 调 API / clone / push | 个人自动化、脚本 |
| Project Access Token | 项目 | 项目级 API/仓库访问 | 单项目 CI/ArgoCD |
| Group Access Token | 组 | 组内多项目访问 | 团队级自动化 |
| Deploy Token | 项目/组 | 只读/读写仓库、registry | ArgoCD 拉 GitOps 仓库、CI 拉依赖 |
| Deploy Key | 项目 | SSH 公钥，读/写 | 只读部署、服务器拉代码 |
| CI_JOB_TOKEN | 作业 | 作业内临时凭据 | clone 当前项目、调 Job API、registry |
| Runner Authentication Token | Runner | Runner 与 GitLab 认证 | 注册/运行 Runner |
| Webhook Secret Token | Hook | 校验 webhook 来源 | 接收端验证 `X-Gitlab-Token` |
| OAuth Client Secret | OAuth App | OIDC/OAuth 客户端认证 | Harbor/ArgoCD/Grafana SSO |
| Registry Credentials | 用户/Robot | 镜像 push/pull | Harbor（本环境不是 GitLab Registry） |

### 2. PAT 的 Scope

常见 scope：

- `read_repository` / `write_repository`：Git clone/push；
- `api`：完整 API（权力很大）；
- `read_api`：只读 API；
- `read_registry` / `write_registry`：GitLab Registry（本环境未启用）；
- `sudo`：以其他用户身份操作（管理员，极危险）。

最小权限原则：

- ArgoCD 拉仓库：`read_repository` 或 deploy token；
- CI 更新 GitOps tag：`write_repository`；
- 只调 API：`read_api` 或 `api`（按需）；
- 不要给 `sudo`。

### 3. Webhook 的组成

一个 GitLab Webhook 包含：

```text
URL             接收端地址
Secret token    放到 X-Gitlab-Token 头
Trigger events  push / tag / MR / pipeline / job / deployment / release ...
SSL verification
```

GitLab 发送时带：

```text
X-Gitlab-Event: Push Hook
X-Gitlab-Token: <secret>
Content-Type: application/json
```

接收端必须：

1. 校验 `X-Gitlab-Token`；
2. 按 `X-Gitlab-Event` 分发；
3. 快速返回 2xx；
4. 做幂等（同一 commit 可能重试）。

### 4. 实际 Token 清单（只列元数据）

| Token | 所属 | Scope | 过期 | 说明 |
|---|---|---|---|---|
| `deeptutor-gitops` | root | `api`, `write_repository`, `read_repository` | 2027-04-25 | 很可能是 CI 更新 GitOps 仓库用 |
| `cicd-agent` | root | `api` | 2027-10-13 | CI/自动化 API 用 |

实际情况：

- **没有 Deploy Token / Deploy Key**；
- **没有项目/组级 CI Variable**（`Ci::Variable` 为空）；
- **GitLab Registry 未启用**；
- Runner token 存在 `gitlab-runner-config` ConfigMap 中（未在文档中展示）；
- ArgoCD 的 GitLab repo secret 全部使用 **username=root + password**，
  没有使用 deploy token/PAT。

### 5. 实际 Webhook 清单

| 项目 | 目标 | 事件 | Secret | SSL 校验 |
|---|---|---|---|---|
| `digitalsupply/compassio` | `http://el-deeptutor.internal/compassio-el` | push | 有 | 关闭 |
| `deeptutor/deeptutor` | `http://el-deeptutor.internal` | push | 有 | 关闭 |
| `digitalsupply/ChinaStudyFree` | `http://10.0.0.252/china-study-free-hook` | push | 有 | 默认 |

没有 group hook / system hook。

> 这些 webhook 的目标是 Tekton EventListener（`el-deeptutor.internal`）
> 或内部接收端，不是 ArgoCD。ArgoCD 是通过轮询/自动同步 Git 仓库工作的。

### 6. 网络限制

GitLab 在 `192.168.67.0/24`，集群在 `10.0.0.0/24`，二者没有路由。
所以：

- GitLab 直接 webhook 到集群内 EventListener **不可靠/不可达**；
- openwebui 的 CI 采用 **集群内 Runner 轮询 GitLab**，再在集群内创建
  Tekton PipelineRun（见 [03 GitLab CI/CD 到 GitOps](03-gitlab-cicd-gitops.md)）；
- `el-deeptutor.internal` / `10.0.0.252` 的 hook 是给已有网络路径的场景用的。

## 踩坑点

### 坑 1：用 root PAT 做所有自动化

当前两个 PAT 都属于 root，且 scope 很宽。泄露一个等于泄露整个 GitLab。

### 坑 2：ArgoCD 用 root 密码拉仓库

ArgoCD repo secret 的 `username=root`、`password=...`，不是 deploy token。
建议换成只读 deploy token 或 `read_repository` 的 project access token。

### 坑 3：以为 Webhook 配了 URL 就行

没有校验 secret token 的接收端等于允许任何人伪造 push 事件。
本环境 3 个 hook 都配置了 secret（`token=true`），但接收端必须真的校验
`X-Gitlab-Token`。

### 坑 4：SSL 校验关闭

`el-deeptutor.internal` 两个 hook 的 `enable_ssl_verification=false`。
内网自签证书可以理解，但要确保网络边界可信，或导入 CA。

### 坑 5：把 CI 变量写在 `.gitlab-ci.yml` 里

本环境没有项目/组级 CI Variable；如果直接在 YAML 写密码/token，
会随仓库泄露。应该用 GitLab CI/CD Variables（masked/protected）
或 Kubernetes Secret + service account。

### 坑 6：混淆 CI_JOB_TOKEN 和 PAT

`CI_JOB_TOKEN` 是作业内临时凭据，不能当长期 PAT 用；
访问其他项目/registry 需要显式授权。

## 修复关键 / 建议

1. **按消费者拆 token**：
   - ArgoCD：只读 deploy token / project access token；
   - CI 更新 GitOps：`write_repository` 的 project access token；
   - 人工 API：个人 `read_api` PAT；
   - Runner：使用 runner authentication token，不要复用 PAT。
2. **设置过期时间**，定期轮换；
3. **Webhook 校验 secret**，记录最近 deliveries；
4. **CI 变量用 masked/protected**，不要进 Git；
5. **Harbor 镜像凭据用 Robot**（见 [04 Harbor 账号与镜像仓库](04-harbor-accounts-registry.md)），不要用 Harbor admin；
6. **GitLab 开启 2FA/HTTPS**，至少保护 root。

## 示例

### 创建只读 deploy token（UI/API）

```text
Project -> Settings -> Repository -> Deploy tokens
Name: argocd-readonly
Scopes: read_repository
Expires: 按需
```

ArgoCD repo secret 用 `username/password` 或 `sshPrivateKey`，不要把 token
写进 Application 清单。

### Webhook 接收端校验（Python 示例）

```python
import hmac
from flask import Flask, request, abort

app = Flask(__name__)
SECRET = b"<your-webhook-secret>"

@app.post("/gitlab-hook")
def hook():
    got = request.headers.get("X-Gitlab-Token", "").encode()
    if not hmac.compare_digest(got, SECRET):
        abort(401)
    event = request.headers.get("X-Gitlab-Event", "")
    # 按 event 处理；注意幂等
    return {"ok": True}
```

### 验证当前 token/webhook 元数据

```bash
# PAT 元数据（不输出 token）
gitlab-rails runner 'PersonalAccessToken.pluck(:id,:name,:scopes,:revoked,:expires_at,:user_id)'

# Webhook 元数据（不输出 secret）
gitlab-rails runner 'ProjectHook.pluck(:id,:project_id,:url,:push_events,:enable_ssl_verification)'

# 判断 hook 是否配置了 secret（只看布尔值）
gitlab-rails runner 'ProjectHook.pluck(:id,:project_id).each { |id,pid| h=ProjectHook.find(id); puts [id,pid,h.token.present?].join("\t") }'
```
