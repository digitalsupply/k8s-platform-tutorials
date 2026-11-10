# 14 · GitLab / Harbor：账号、Token、Webhook 与 CI/CD 链路

## 当时的情况

本环境用 **GitLab CE** 做代码与身份中心，用 **Harbor** 做镜像仓库，
CI/CD 采用：

```text
GitLab Push
  -> 集群内 GitLab Runner（gitlab-runner namespace）
  -> Tekton PipelineRun（cicd namespace）
  -> Kaniko 构建镜像
  -> 推送 Harbor（192.168.67.202:8443）
  -> 更新 GitOps 仓库镜像 tag
  -> ArgoCD 自动同步到集群
```

GitLab 与集群不在同一网段（`192.168.67.0/24` ↔ `10.0.0.0/24` 没有路由），
所以不能依赖 GitLab 直接回调集群的 EventListener；实际采用的是
**集群内 Runner 主动轮询 GitLab，再在集群内创建 Tekton PipelineRun**。

## 实际环境

| 组件 | 地址 | 版本 | 关键配置 |
|---|---|---|---|
| GitLab | `http://192.168.67.201` | 19.5.0 CE | 端口 80；本地 DB 认证；容器 registry 未启用 |
| Harbor | `https://192.168.67.202:8443` | v2.14.5 | OIDC（GitLab 为 IdP）；HTTP 8080 跳转 |
| GitLab Runner | 集群 `gitlab-runner` ns | — | Kubernetes executor；tag `cicd` |
| Tekton | 集群 `cicd` ns | — | 4 条 pipeline：openwebui/deeptutor/compassio/china-study-free |
| ArgoCD | 集群 `argocd` ns | v3.5.3 | 监听 GitOps 仓库并自动同步 |

## 账号与仓库现状

| 项 | 实际值 |
|---|---|
| GitLab 用户 | `root`（管理员）、`GitLabDuo`（服务账号） |
| GitLab 组 | `digitalsupply`、`deeptutor`（均 private） |
| GitLab 项目 | 11 个，全部 private |
| GitLab 注册 | 关闭（`signup_enabled=false`） |
| GitLab 2FA | 未强制 |
| GitLab PAT | 2 个，均属于 `root` |
| GitLab Deploy Token | 无 |
| GitLab Deploy Key | 无 |
| GitLab Webhook | 3 个项目级 hook，push 事件，均配置 secret token |
| GitLab Registry | 未启用 |
| Harbor 认证 | `oidc_auth`（GitLab OIDC） |
| Harbor 项目 | 5 个（library、deeptutor 公开；其余 private） |
| Harbor Robot | 无 |
| Harbor Webhook | 无 |
| Harbor 复制 | 无 |

## 文档列表

| 文档 | 内容 |
|---|---|
| [01-gitlab-accounts-roles.md](01-gitlab-accounts-roles.md) | GitLab 用户/组/项目/角色、可见性、认证方式、OAuth/OIDC |
| [02-gitlab-tokens-webhooks.md](02-gitlab-tokens-webhooks.md) | PAT、项目/组 token、deploy token/key、CI_JOB_TOKEN、runner token、webhook token 的概念与实际清单 |
| [03-gitlab-cicd-gitops.md](03-gitlab-cicd-gitops.md) | Runner、`.gitlab-ci.yml`、Tekton、Harbor、更新 GitOps tag 的完整链路 |
| [04-harbor-accounts-registry.md](04-harbor-accounts-registry.md) | Harbor 账号体系、OIDC、项目角色、Robot、镜像仓库、扫描、复制、保留 |
| [05-harbor-config-pitfalls.md](05-harbor-config-pitfalls.md) | Harbor 实际配置、端口/证书、Trivy 修复、imagePullSecret 安全 |

## 阅读建议

1. 先看 01/02，理解 GitLab 的身份和凭据模型；
2. 再看 03，理解 CI 为什么用 Runner + Tekton，而不是直接 webhook；
3. 最后看 04/05，理解 Harbor 的 OIDC/项目/Robot 与镜像拉取。

> 文档中的密码、token、client secret、runner token、webhook secret 均为
> 占位或已脱敏；内网地址是实验环境 RFC1918 地址。
