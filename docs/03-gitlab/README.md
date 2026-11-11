# 03 · GitLab / Harbor：代码、身份与镜像

> 本分类原来只记录 GitLab 安装与 80/8088 端口排障；现在整合了 GitLab 账号/
> Token/Webhook/CI-CD 与 Harbor 账号/镜像仓库，作为“研发交付基础设施”总入口。

## 当时的情况

本环境用 **GitLab CE** 做代码与身份中心，用 **Harbor** 做镜像仓库：

> **部署位置修正**：GitLab `192.168.67.201` 和 Harbor `192.168.67.202` **不是物理机**，
> 而是 Windows Hyper-V 宿主 `SYZX-HY2-TX`（`192.168.67.110`）上的
> `ubuntu01` / `ubuntu02` 虚拟机。宿主层（VM 状态、VHDX、虚拟交换机）也会影响它们。
> 证据见 [00 Hyper-V 宿主](../00-cluster-overview/assets/hyperv-host-20261111/README.md)。

```text
GitLab（192.168.67.201:80）
  ├── 用户/组/项目
  ├── PAT / Deploy Token / Webhook
  ├── OAuth/OIDC 提供方（Grafana/ArgoCD/Harbor）
  └── CI 触发源
        │
        ▼
集群内 GitLab Runner（gitlab-runner ns）
        │
        ▼
Tekton（cicd ns）→ Kaniko → Harbor（192.168.67.202:8443）→ GitOps tag → ArgoCD
```

GitLab 与集群不在同一网段（`192.168.67.0/24` ↔ `10.0.0.0/24` 无路由），
所以没有采用 GitLab 直接 webhook 到集群 EventListener 的方案，而是
**集群内 Runner 轮询 GitLab，再在集群内创建 Tekton PipelineRun**。

## 实际环境

| 组件 | 地址 | 版本 | 关键配置 |
|---|---|---|---|
| GitLab | `http://192.168.67.201` | 19.5.0 CE | 端口 80；本地 DB 认证；容器 registry 未启用 |
| Harbor | `https://192.168.67.202:8443` | v2.14.5 | OIDC（GitLab 为 IdP）；8080 只做跳转 |
| GitLab Runner | 集群 `gitlab-runner` ns | — | Kubernetes executor；tag `cicd` |
| Tekton | 集群 `cicd` ns | — | openwebui/deeptutor/compassio/china-study-free 四条 pipeline |
| ArgoCD | 集群 `argocd` ns | v3.5.3 | 监听 GitOps 仓库并自动同步 |

## 当前状态速览

### GitLab

- 用户：`root`（管理员）、`GitLabDuo`（服务账号）；
- 组：`digitalsupply`、`deeptutor`；
- 11 个项目，全部 private；
- 注册关闭，2FA 未强制，Web 密码登录开启；
- 保护分支：所有项目 `main`；
- PAT：`deeptutor-gitops`、`cicd-agent`，都属于 root；
- Deploy Token / Deploy Key：无；
- 项目级 CI Variable：无；
- Webhook：3 个项目级 hook，push 事件，均配置 secret token；
- GitLab Container Registry：未启用。

### Harbor

- 认证：`oidc_auth`，GitLab 为 OIDC 提供方；
- 本地 admin：`admin`（sysadmin）；OIDC 用户自动 onboard；
- 项目：`library`(public,2)、`deeptutor`(public,6)、`compassio`(private,7)、
  `openwebui`(private,11)、`china-study-free`(private,2)；
- Robot / 项目 Webhook / 复制：均无；
- imagePullSecret：`harbor-auth` / `harbor-pull`，实际都使用 `admin`；
- Trivy 已通过 `docker-compose.override.yml` 切到 `public.ecr.aws`。

## 文档索引

### GitLab 安装与端口（历史记录）

| 文档 | 内容 |
|---|---|
| [notes/install-and-port.md](notes/install-and-port.md) | 安装、8088→80、Cilium 遗留规则、Runner 资产索引（写于 19.4.2/8088 时期） |
| [gitlab-19.4-install.md](gitlab-19.4-install.md) | GitLab CE 19.4.2 Omnibus 安装全过程 |
| [gitlab-port80-explanation.md](gitlab-port80-explanation.md) | 为什么没有直接用 80 端口 |
| [gitlab-port-80-troubleshooting.md](gitlab-port-80-troubleshooting.md) | 8088→80 的完整排查时间线 |
| [gitlab-fix-port80.md](gitlab-fix-port80.md) | 清理 Cilium 遗留规则并测试 80 |
| [gitlab-port80-cleanup-final.md](gitlab-port80-cleanup-final.md) | 80→8088 重定向与清理总结 |

### GitLab 账号、Token、Webhook

| 文档 | 内容 |
|---|---|
| [accounts-roles.md](accounts-roles.md) | 用户/组/项目/角色、可见性、认证方式、OAuth/OIDC 提供方 |
| [tokens-webhooks.md](tokens-webhooks.md) | PAT、项目/组 token、deploy token/key、CI_JOB_TOKEN、runner token、webhook secret 的概念与实际清单 |
| [notes/gitlab-repo-access-tutorial-2026-11-09.md](notes/gitlab-repo-access-tutorial-2026-11-09.md) | SSH / HTTPS PAT / Deploy Token 克隆与 ArgoCD 凭据实操 |

### GitLab CI/CD 与 GitOps

| 文档 | 内容 |
|---|---|
| [cicd-gitops.md](cicd-gitops.md) | Runner、`.gitlab-ci.yml`、Tekton、Kaniko、Harbor、更新 GitOps tag |
| [assets/gitlab-runner-config.yaml](assets/gitlab-runner-config.yaml) | 当前 runner `runners.toml`（token 已脱敏） |
| [assets/gitlab-runner-deployment.yaml](assets/gitlab-runner-deployment.yaml) | 当前 GitLab Runner Deployment |
| [assets/argocd-repo-secret.example.yaml](assets/argocd-repo-secret.example.yaml) | ArgoCD 仓库凭据示例 |

### Harbor 账号与镜像仓库

| 文档 | 内容 |
|---|---|
| [harbor-accounts-registry.md](harbor-accounts-registry.md) | Harbor OIDC、账号体系、项目角色、Robot、镜像仓库、扫描、复制、保留 |
| [harbor-config-pitfalls.md](harbor-config-pitfalls.md) | 实际配置、8080/8443、自签证书、Trivy 修复、imagePullSecret 安全 |

## 主要概念与原理

- **GitLab 三层对象**：User → Group → Project；角色 Guest/Reporter/Developer/
  Maintainer/Owner；可见性 Private/Internal/Public。
- **GitLab Token**：PAT、项目/组 access token、deploy token、deploy key、
  CI_JOB_TOKEN、runner token、webhook secret、OAuth client secret。
- **GitLab Webhook**：事件 + URL + secret token；
  接收端校验 `X-Gitlab-Token`，按 `X-Gitlab-Event` 分发。
- **GitLab OIDC**：GitLab 作为 OAuth/OIDC 提供方，Harbor/ArgoCD/Grafana
  通过 OAuth Application 接入。
- **Harbor 对象**：Project → Repository → Tag；项目角色、Robot、OIDC 用户、
  imagePullSecret、Trivy、Retention、Replication、Webhook。
- **CI/CD 链路**：GitLab → Runner → Tekton → Kaniko → Harbor → GitOps tag →
  ArgoCD。

## 踩坑点（汇总）

1. **旧文档的 8088/19.4.2 已过时**：当前 GitLab 是 19.5.0 / 80；
   安装排障文档仅作历史记录。
2. **GitLab 容器 Registry 未启用**：镜像统一走 Harbor，不要配 GitLab Registry。
3. **root PAT / ArgoCD root 密码**：自动化大量使用 root，权限过大；
   应改用 deploy token / read-only PAT。
4. **Webhook 网络不通**：GitLab 无法直接访问 `10.0.0.0/24`；
   openwebui 用集群内 Runner，其他 hook 指向 EventListener。
5. **Harbor OIDC 管理员组**：`oidc_admin_group=digitalsupply`，
   该 GitLab 组成员会成为 Harbor 管理员。
6. **Harbor OIDC 使用 HTTP 且 `oidc_verify_cert=false`**；
   自签证书 `has_ca_root=false`，客户端需要 CA/insecure。
7. **imagePullSecret 使用 admin**：`harbor-auth` / `harbor-pull` 都是 admin；
   应改成项目级 Robot。
8. **Trivy 变量前缀**：必须用 `SCANNER_TRIVY_DB_REPOSITORY` 和
   `SCANNER_TRIVY_JAVA_DB_REPOSITORY`，`TRIVY_DB_REPOSITORY` 不生效。

## 修复关键 / 建议

- GitLab：按组/项目分配角色；管理员开 2FA；用 deploy token/PAT 替代 root；
- Webhook：校验 secret，开启 SSL 校验，监控 recent deliveries；
- CI：Runner 使用专用 ServiceAccount，Harbor 用 Robot，CI 变量 masked/protected；
- Harbor：Robot 替代 admin，打开 OIDC 证书校验，收紧 admin group，
  配置 immutable tag/retention/scanning；
- 不要把密码/token/client secret/runner token/webhook secret 写入 Git。

## 与其他分类的关系

- [10 CI/CD 交付](../10-cicd-delivery/README.md)：Tekton/BuildKit/EventListener 的深度细节；
- [13 SSO / OIDC](../13-sso-oidc/README.md)：GitLab 作为 IdP、oauth2-proxy 反代；
- [11 GitOps 平台化](../11-gitops-platform/README.md)：ArgoCD app-of-apps、SealedSecrets；
- 本文档聚焦 **GitLab 账号/Token/Webhook + Runner/Tekton 配置 + Harbor 账号/镜像仓库**。

## 阅读顺序

```text
notes/install-and-port.md       # 先看历史安装/端口坑
  → accounts-roles.md           # 账号/组/项目/角色
  → tokens-webhooks.md          # Token/Webhook
  → notes/gitlab-repo-access…   # 实际克隆/凭据
  → cicd-gitops.md              # Runner/Tekton/Harbor/GitOps
  → harbor-accounts-registry.md # Harbor 账号/项目/Robot
  → harbor-config-pitfalls.md   # 端口/证书/Trivy/imagePullSecret
```
