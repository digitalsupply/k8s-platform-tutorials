# 凭据、密钥与流水线数据流：GitLab / Harbor / Tekton / ArgoCD 全景

> 这份文档回答一个问题：**这套 CI/CD 里到底有多少把"钥匙"，每一把是谁造的、谁能用、用它开哪扇门、门后是什么。**
>
> 全部结论来自实机取证（2026-11-12），不是照着设计文档反推。取证方式列在 §11，包括
> GitLab Rails 直查、Harbor API 直查、Kubernetes API 直查、以及一次真实的 webhook 伪造请求。
> 文中出现的 token/密码一律不写值，只写"是什么、在哪、谁能读"。

---

## 目录

1. [先分清六类"钥匙"](#1-先分清六类钥匙)
2. [系统拓扑与可达性](#2-系统拓扑与可达性)
3. [本集群的凭据清单（实测）](#3-本集群的凭据清单实测)
4. [一条链路走完：从 git push 到 Pod 起来](#4-一条链路走完从-git-push-到-pod-起来)
5. [四条流水线对照](#5-四条流水线对照)
6. [三个最容易混的对照关系](#6-三个最容易混的对照关系)
7. [当前的风险面](#7-当前的风险面)
8. [轮换 runbook](#8-轮换-runbook)
9. [附：取证命令](#9-附取证命令)

---

## 1. 先分清六类"钥匙"

这是全文的基础。很多"凭据用错了"的事故，本质是把这六类东西当成一类在换。

### 1.1 GitLab 侧：五种 token，权限模型完全不同

| 类型 | 属于谁 | 谁能创建 | scope 能到多大 | 能否跨 group | 典型用途 | 本集群用在哪 |
|---|---|---|---|---|---|---|
| **Personal access token (PAT)** | 某个**用户** | 用户自己 | 取决于用户权限；root 创建的 `api` scope = 全站 | 能（因为是人） | 脚本/自动化冒充人 | ~~已全部 revoke~~ |
| **Group access token** | group 的 **bot 用户** | group Owner | 该 group 内一个角色（Developer/Maintainer）+ 仓库 scope | **不能**（只在本 group） | CI 读写本 group 的仓 | 2 个 `ci-rw` |
| **Project access token** | 项目的 bot 用户 | 项目 Maintainer | 单项目 | 不能 | 单项目自动化 | 未使用 |
| **Deploy token** | 项目本身（不是用户） | 项目 Maintainer | 只有 `read_repository` / `read_registry` 这类"取"的权限 | 不能（天生一对一） | 只读拉代码/拉镜像 | 6 个 `argocd-ro` |
| **CI job token** | 当前 job | 无（自动） | job 生命周期内、项目白名单内 | 受限 | 流水线里互相调 API | 未使用 |

三条容易踩的差别：

- **PAT 的 `api` scope 是最贵的钥匙**。它等于"以这个人的身份调 GitLab REST API"——改保护分支、
  加成员、删项目、读别人的 token 列表，都能干。之前 `cicd-agent` / `deeptutor-gitops` 两个 PAT
  都属于 root、都带 `api`，只要在集群任何一个 Secret 里躺着，拿到它的人就等于拿到 GitLab 的 root。
  这就是为什么它们的 revoke 是这轮收敛里最重要的一步。
- **Group access token 的边界是 group**。它看起来像"CI 通用账号"，但拿 digitalsupply 的 token
  去 clone `deeptutor/deeptutor.git` 会 401 —— 这不是 token 坏了，是跨了边界。
  这条边界正是 deeptutor 流水线被打断的原因（§5.3）。
- **Deploy token 不能调 API**。它只走 git/registry 的 HTTP Basic，没有 REST 能力。
  所以 ArgoCD 用它拉仓是天然安全的：即使密文泄露，也只能读那几个仓。

### 1.2 Harbor 侧：admin 账号 vs robot account

| | Harbor admin | robot account |
|---|---|---|
| 身份 | 系统管理员，能进 UI、改配置、建项目、删仓库 | 项目内的"机器人"，只能按 project 授权 pull/push/delete |
| 能做什么 | 一切 | 见授权表；不能登录 UI 做管理 |
| 过期 | 不过期 | 可设过期时间 |
| 适合谁用 | 人 | 机器（CI 推镜像、kubelet 拉镜像） |

本集群的现状是：**robot account 数量 = 0，所有机器场景都用 admin**（见 §3.2）。这是这套系统里
最大的一处权限过宽。

### 1.3 Kubernetes 侧：Secret / SealedSecret / dockerconfigjson / SA token

| 东西 | 本质 | 谁读它 |
|---|---|---|
| `Secret`（Opaque） | etcd 里的 base64，**不是加密**；有 RBAC 就能读明文 | Pod / 任何有 get secret 权限的 SA |
| `SealedSecret` | 用 sealed-secrets controller 的**公钥**加密的密文，只能被**本集群**的私钥解开 | 只有 controller 能解，解出来的产物就是普通 Secret |
| `dockerconfigjson` | Docker 客户端格式的仓库凭据（`{"auths": {"<registry>": {"auth": base64(user:pass)}}}`） | kubelet（imagePullSecrets）、kaniko、buildctl |
| ServiceAccount token | 集群内身份（`/var/run/secrets/kubernetes.io/serviceaccount/token`） | Pod 里的进程，用来调 kube-apiserver |

`SealedSecret` 的价值只有一个：**密文可以进 git**。它的 scope 有三种，本仓库全用 `strict`，
意味着密文绑定 `namespace/name`，改名字或换 namespace 都解不开。

### 1.4 ArgoCD 侧：repository secret 不是给应用用的

ArgoCD 的 `Secret` 带 `argocd.argoproj.io/secret-type: repository` 标签时，语义完全变了：
**它不是"给某个 Pod 挂的环境变量"，而是"ArgoCD 自己 clone 这个 git 仓时要用的凭据"。**

```text
读它的人：argocd-repo-server（ArgoCD 的组件）
用途：     git clone http://<username>:<password>@<url>
后果：     只有 ArgoCD 能拉起这个仓的代码；
           它和"应用 Pod 拉 Harbor 镜像用的 secret"没有任何关系
```

本集群有 6 个这种 secret，全部是 deploy token（§3.4）。

### 1.5 webhook secret：它是"门锁校验"，不是"身份"

这是最常被误解的一类。GitLab webhook 的 `Secret token` 不授予任何权限，它的作用只有：

```text
GitLab 发 POST 时带上 X-Gitlab-Token: <secret>
Tekton EventListener 的 gitlab 拦截器拿它和 Secret 里的 secretToken 比
不一致 → 事件被丢弃，不生成 PipelineRun
```

所以泄露 webhook secret 的后果是"别人能伪造触发你的流水线"（消耗资源、推 garbage 镜像），
**不是**"别人能读你的代码"。这两件事的量级差很远，但经常被混为一谈。

本集群三条 webhook 都带 token，且实测**校验真的生效**（§4.2 有取证）。

> 补充：GitHub 的 webhook 用 HMAC-SHA256 签名（`X-Hub-Signature-256`），GitLab 用的是明文 token 比较。
> 前者防重放更强，后者实现简单。Tekton 的 `gitlab` 拦截器走的是后者。

---

## 2. 系统拓扑与可达性

```text
┌──────────────────────────── 192.168.67.0/24（虚拟化网段） ────────────────────────────┐
│                                                                                      │
│   GitLab 192.168.67.201 (ubuntu01)          Harbor 192.168.67.202:8443                │
│   ├─ 11 个项目，全 private                  ├─ 5 个项目（见 §3.2）                     │
│   ├─ 2×group token, 6×deploy token          ├─ 0 robot account                       │
│   └─ /etc/hosts: el-deeptutor.internal      └─ 自签 CA（集群里以 ConfigMap harbor-ca 分发）
│              → 10.0.0.252                                                            │
└──────────────────────────────────┬───────────────────────────────────────────────────┘
                                   │  路由是双向的（实测，见下）
┌──────────────────────────────────┴───────────────────────────────────────────────────┐
│  Kubernetes 10.0.0.0/16，VIP 10.0.0.168:6443，6 节点                                   │
│                                                                                      │
│  ┌ ns: cicd ─────────────────────────────────────────────────────────────────────┐    │
│  │ Tekton: Task ×12 / Pipeline ×4 / EventListener ×3 / TriggerBinding ×3 / TT ×3 │    │
│  │ buildkitd (buildctl 的守护进程)   gitlab-runner 在 ns: gitlab-runner          │    │
│  │ EL Service ← Ingress ← Traefik LB 10.0.0.252                                  │    │
│  └───────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                      │
│  ┌ ns: argocd ───────────────────────────────────────────────────────────────────┐    │
│  │ 42 个 Application / 771 个对象；6 个 repository secret = 6 个 deploy token     │    │
│  │ 轮询间隔 120s（没有配 webhook，靠轮询发现 gitops 仓的新 commit）               │    │
│  └───────────────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**可达性是这套设计的核心约束**，两个方向：

| 方向 | 是否通 | 证据 |
|---|---|---|
| 集群 → GitLab / Harbor | 通 | 所有 clone / push / image push 都在跑 |
| GitLab → 集群（Traefik 10.0.0.252） | 通 | GitLab 主机 `/etc/hosts` 把 `el-deeptutor.internal` 指到 `10.0.0.252`；实测 `curl http://10.0.0.252/` → 404（Traefik 收到了，只是没匹配路由） |

> **历史包袱**：`digitalsupply/openwebui` 仓库里的 `.gitlab-ci.yml` 注释写着"192.168.67.0/24 到
> 10.0.0.0/24 没有路由，所以 GitLab 无法回调 EventListener"。这条注释在**写下时可能是对的**，
> 现在的实测结果是能通（上面第二条）。但 openwebui 至今仍走 gitlab-runner 路线，
> 于是四条流水线里出现了**两套触发机制并存**（§5.1）。这条注释是理解现状的关键：
> 它不是设计选择，是当时的网络限制留下的疤痕。

---

## 3. 本集群的凭据清单（实测）

### 3.1 GitLab（192.168.67.201）

| 名称 | 类型 | 归属 | scope | 角色 | 有效期 | 消费者 |
|---|---|---|---|---|---|---|
| `ci-rw` | group access token | group `digitalsupply` (id=2) 的 bot | `read_repository`,`write_repository` | Developer | 2027-11-12 | compassio / china-study-free / openwebui 的 clone+push |
| `ci-rw` | group access token | group `deeptutor` (id=8) 的 bot | 同上 | Developer | 2027-11-12 | deeptutor 的 clone+push |
| `argocd-ro` ×6 | deploy token | 各自项目 | `read_repository` | — | 无 | ArgoCD 拉 6 个 gitops 仓 |
| ~~`cicd-agent`~~ | PAT (root) | root | `api` | — | — | **已 revoke** |
| ~~`deeptutor-gitops`~~ | PAT (root) | root | `api`,`write_repository`,`read_repository` | — | — | **已 revoke** |

6 个 deploy token 对应的仓（username 形如 `gitlab+deploy-token-N`）：

```text
deploy-token-1  digitalsupply/platform-gitops
deploy-token-2  digitalsupply/tekton-platform-gitops
deploy-token-3  digitalsupply/china-study-free-gitops
deploy-token-4  digitalsupply/compassio-gitops
deploy-token-5  digitalsupply/openwebui-gitops
deploy-token-6  deeptutor/deeptutor-gitops
```

### 3.2 Harbor（192.168.67.202:8443）

| 项目 | public | 仓库数 | 谁在推 | 谁在拉 |
|---|---|---|---|---|
| `openwebui` | **false** | 11 | openwebui 流水线（kaniko） | open-webui ns（`harbor-pull`）、gitlab-runner helper、buildkitd 自身 |
| `compassio` | **false** | 7 | compassio 流水线（buildctl） | compassio ns |
| `deeptutor` | **true** | 6 | deeptutor 流水线（buildctl） | deeptutor ns（**无 imagePullSecrets**）、buildkitd 拉基础镜像 |
| `china-study-free` | **false** | 2 | china-study-free 流水线（buildctl） | china-study-free ns |
| `library` | **true** | 2 | — | — |

**robot account = 0**。所有机器场景统一用 admin，凭据形态是一份 `kubernetes.io/dockerconfigjson`
Secret，被四个地方引用：

```text
cicd/harbor-auth             ← buildkitd 的 imagePullSecrets（拉 buildkit 镜像自身）
                             ← build 类 Task 的 spec.volumes（DOCKER_CONFIG=/kaniko/.docker 或 /home/user/.docker）
                             ← PipelineRun 的 podTemplate.imagePullSecrets（拉 task 镜像、kaniko、git）
gitlab-runner/harbor-auth    ← runner 自己 + 它创建的 job pod（image_pull_secrets）
compassio/harbor-auth        ← compassio-backend / frontend
china-study-free/harbor-auth ← china-study-free
open-webui/harbor-pull       ← 同一份 admin 凭据，只是换了个名字
```

实测这 5 个 Secret 里的 `auth` 字段解出来是**同一个 admin 账号、同一个密码**
（密码 sha256 前 8 位一致）—— 不是"各自一份 admin 凭据"，是同一份被复制到 5 个地方。
轮换时必须 5 处一起改，漏一处就是一个 ImagePullBackOff 或一条推镜像失败。

`deeptutor` 项目为什么是 public？**因为 buildkitd 守护进程没有 registry 凭据**：
deeptutor 的 Dockerfile 基础镜像 `deeptutor/node:22-slim`、`deeptutor/python:3.11-slim`
放在**同一个私有项目里**，而 pull 是守护进程做的（不是 buildctl 客户端做的），守护进程只能匿名拉。
把它设成 public 是让构建能跑通的最省事办法 —— 代价是任何人都能匿名拉走 deeptutor 的镜像。

### 3.3 Kubernetes（ns `cicd`）

全部由 SealedSecret 拥有（`ownerReferences` 指向同名 SealedSecret），密文在
`platform-gitops/platform/secrets/cicd/sealed/`。

| Secret | keys | 用途 | 消费者 |
|---|---|---|---|
| `gitlab-auth` | `username`,`password`,`token`,`git-url`,`gitops-url` | digitalsupply 的 group token + 两条 URL | `git-clone`（默认值）、`compassio-check-changes`、`compassio-update-gitops`、`update-gitops-tag`（openwebui） |
| `deeptutor-gitlab-auth` | `username`,`password`,`token` | deeptutor 的 group token | `deeptutor-check-changes`、`deeptutor-update-gitops`、`git-clone`（显式传参） |
| `china-study-free-gitlab-auth` | `username`,`password`,`token` | 同样是 digitalsupply token，独立一份 | `china-study-free-check-changes`、`china-study-free-update-gitops` |
| `gitlab-webhook-secret` | `secretToken` | compassio 的 webhook 校验 | `compassio-listener` 的 gitlab 拦截器 |
| `deeptutor-webhook-secret` | `secretToken` | deeptutor 的 webhook 校验 | `deeptutor-listener` |
| `china-study-free-webhook-secret` | `secretToken` | china-study-free 的 webhook 校验 | `china-study-free-listener` |
| `harbor-auth` | `.dockerconfigjson` | Harbor **admin** | 见 §3.2 |

> `token` 键是为了兼容早期脚本写的（和 `password` 同值）。`git-url` 键现在没有任何 Task 引用
> —— 只有 `gitops-url` 被 `update-gitops-tag` 用。留着不碍事，但轮换时容易漏。

### 3.4 ArgoCD（ns `argocd`）

| Secret | type label | url | username 形态 |
|---|---|---|---|
| `platform-gitops-repo` | repository | `.../digitalsupply/platform-gitops.git` | `gitlab+deploy-token-1` |
| `tekton-platform-repo` | repository | `.../digitalsupply/tekton-platform-gitops.git` | `gitlab+deploy-token-2` |
| `china-study-free-repo-secret` | repository | `.../digitalsupply/china-study-free-gitops.git` | `gitlab+deploy-token-3` |
| `gitlab-compassio-gitops` | repository | `.../digitalsupply/compassio-gitops.git` | `gitlab+deploy-token-4` |
| `gitlab-openwebui-gitops` | repository | `.../digitalsupply/openwebui-gitops.git` | `gitlab+deploy-token-5` |
| `deeptutor-repo-secret` | repository | `.../deeptutor/deeptutor-gitops.git` | `gitlab+deploy-token-6` |

`username` 前缀 `gitlab+deploy-token-N` 是 GitLab 给 deploy token 生成的固定用户名格式 ——
**看到这个前缀就能确定它是 deploy token，不是人**。

### 3.5 四条流水线各用哪把钥匙（一页看懂）

```text
                  clone 源码          推镜像              推 gitops 仓        拉镜像（部署时）
openwebui         gitlab-auth         harbor-auth(admin)  gitlab-auth         open-webui/harbor-pull
                  (digitalsupply)     kaniko 直推         (digitalsupply)     (admin)
compassio         gitlab-auth         harbor-auth(admin)  gitlab-auth         compassio/harbor-auth
                  (digitalsupply)     buildctl            (digitalsupply)     (admin)
deeptutor         deeptutor-gitlab-auth  harbor-auth      deeptutor-gitlab-auth  无（项目 public）
                  (deeptutor)         buildctl            (deeptutor)
china-study-free  china-study-free-gitlab-auth  harbor-auth  china-study-free-gitlab-auth  china-study-free/harbor-auth
                  (digitalsupply 的 token，独立一份)  buildctl   (同左)
```

注意 deeptutor 那一行：**clone 和 push 都必须用 deeptutor 的 token**，因为它跨了 group。
其余三条都在 digitalsupply 里，用同一把钥匙就够。

---

## 4. 一条链路走完：从 git push 到 Pod 起来

以 compassio 为例（webhook 路线），把每一跳的"谁访问谁、用什么钥匙、钥匙在哪"写全。

### 4.1 阶段 0：钥匙是怎么进集群的

```text
人（git 里）      → SealedSecret 密文（platform/secrets/cicd/sealed/*.yaml）
                      ↓ ArgoCD sync（platform-cicd-secrets 这个 Application）
sealed-secrets    → 用集群私钥解密 → 生成/更新同名 Secret（cicd/gitlab-auth 等）
controller
                      ↓
Pod               → env valueFrom.secretKeyRef（进环境变量）
                  → spec.volumes[].secret（挂成文件，如 .dockerconfigjson → config.json）
```

要点：**git 里永远只有密文**。`kubeseal` 只用公钥，所以拿仓库的人解不开；能解开的只有集群里那一个
controller 的私钥。密文 scope=strict，绑死 `cicd/gitlab-auth` 这个名字和命名空间。

### 4.2 阶段 1：触发

```text
开发者 git push origin main
   ↓
GitLab 192.168.67.201 收到 push
   ↓ 读取项目 Webhook（digitalsupply/compassio → http://el-deeptutor.internal/compassio-el）
   ↓ 带 X-Gitlab-Token: <gitlab-webhook-secret/secretToken>、X-Gitlab-Event: Push Hook
   ↓ GitLab /etc/hosts: el-deeptutor.internal = 10.0.0.252
Traefik（LB 10.0.0.252:80）→ Ingress `compassio-el` → Service `el-compassio-listener:8080`
   ↓
EventListener `compassio-listener`
   ├─ 拦截器 1（ClusterInterceptor `gitlab`）：比对 secretRef secretToken —— 不一致直接丢
   └─ 拦截器 2（ClusterInterceptor `cel`）：
        body.object_kind == 'push' && body.ref == 'refs/heads/main'
        不是 main 分支、不是 push 事件 → 丢
   ↓ 通过
TriggerBinding `compassio-binding`
   ├─ gitrevision     ← body.checkout_sha
   ├─ gitbefore       ← body.before
   └─ gitrepositoryurl ← body.repository.git_http_url
   ↓
TriggerTemplate `compassio-template`
   → 生成 PipelineRun（generateName: compassio-triggered-）
       workspaces: shared-workspace = volumeClaimTemplate(256Mi, nfs-sc)
       podTemplate: imagePullSecrets=[harbor-auth], nodeSelector=worker03
       serviceAccountName: pipeline
```

**实测：这条校验是真的生效。** 从 GitLab 主机发一个"格式正确但 token 错误"的 push payload：

```text
POST http://el-deeptutor.internal/  (X-Gitlab-Token: wrong-token-probe)
→ HTTP 202 {"eventListener":"deeptutor-listener", ...}
→ kubectl get pipelinerun：**没有**新建记录
```

202 是 EventListener 的固定应答（"我收到了"），真正决定要不要跑的是拦截器。token 不对就静默丢弃 ——
这就是为什么"webhook 配错了"很难发现：GitLab 侧看到的是 202，流水线不跑，中间没有任何报错。
反过来，payload 格式不对时 EventListener 日志会明确报 `Invalid event body format`。

### 4.3 阶段 2：clone 源码

```text
Task `git-clone`（cicd-defs.yaml:1114）
  env GIT_USERNAME ← secretKeyRef $(params.gitlab-secret-name)/username
  env GIT_PASSWORD ← secretKeyRef $(params.gitlab-secret-name)/password
  params.gitlab-secret-name 默认 "gitlab-auth"
  内容：git clone http://$GIT_USERNAME:$GIT_PASSWORD@<host>/<path> <workspace>/source
```

- 谁访问谁：**Pod → GitLab（HTTP Basic）**
- 钥匙：group access token，`read_repository`
- 存哪：`cicd/gitlab-auth`（密文在 git）
- 谁创建：人（经 kubeseal），ArgoCD 负责每次 sync 时保持其存在
- 失败长什么样：`HTTP Basic: Access denied ... improperly scoped` —— 跨 group 就是这个错

`$(params.gitlab-secret-name)` 这个间接层是 2026-11-12 加的，起因见 §5.3。

### 4.4 阶段 3：判断"该不该构建"

```text
Task `compassio-check-changes`
  用同一个 secret 再 clone 一次（或复用），比较 before..after 的改动路径
  → 只改文档就不构建，把 need-build 传给后面的 when 条件
```

这一跳的价值是省机器：docs-only 的 commit 不该占一个 buildkit 构建。
代价是它**也需要凭据**——只修 `git-clone` 忘了修这里，后果是"docs-only 判断静默失效"
（每次都构建，看起来只是慢了）。

### 4.5 阶段 4：构建并推镜像（两种做法）

**A. kaniko 直推（只有 openwebui 用）**

```text
Task `build-and-push`（:412）
  image: 192.168.67.202:8443/openwebui/kaniko:v1.23.2
  spec.volumes: docker-config ← Secret cicd/harbor-auth 的 .dockerconfigjson → config.json
  DOCKER_CONFIG=/kaniko/.docker   ← kaniko 从这里读 registry 凭据
  args: --destination=<image> --insecure --skip-tls-verify --cache-repo=.../openwebui/cache
```

kaniko 在 Pod 内部完成构建和推送，不需要守护进程、不需要特权。

**B. buildctl → buildkitd（其余三条）**

```text
Task `deeptutor-build-push` 等（:526 起）
  image: 192.168.67.202:8443/compassio/buildkit:v0.20.2-rootless
  env BUILDKIT_HOST=tcp://buildkitd.cicd.svc.cluster.local:1234
  spec.volumes:
    docker-config ← Secret cicd/harbor-auth → /home/user/.docker/config.json（推镜像的凭据）
    harbor-ca     ← ConfigMap cicd/harbor-ca → /etc/harbor-ca/ca.crt（Harbor 的自签 CA）
  脚本：cat 系统 CA + harbor-ca > /tmp/ca-bundle.crt; export SSL_CERT_FILE=/tmp/ca-bundle.crt
        buildctl build --output type=image,name=<image>,push=true
```

两个细节值得记住：

- **CA 为什么要手动合并**：`buildctl` 客户端自己会和 Harbor 做 token 交换（HTTP 层），
  客户端镜像的 CA 库不认识 Harbor 的自签 CA → 报 `x509: certificate signed by unknown authority`。
  **推**是客户端做的（所以带凭据），**拉基础镜像**是守护进程做的（所以不带凭据，见 §3.2 的 public 问题）。
- `buildkitd` 的 `buildkitd.toml` 里给 `docker.io` 配了两个镜像加速，给 `192.168.67.202:8443`
  配了 `ca = /bundle/ca-bundle.crt`。加速站配错/挂掉时，构建会卡在拉基础镜像这一步。

### 4.6 阶段 5：把新 tag 写回 gitops 仓

```text
Task `compassio-update-gitops` / `deeptutor-update-gitops` / `update-gitops-tag`
  env GIT_USERNAME ← <对应 secret>/username
  env GIT_PASSWORD ← <对应 secret>/password
  env GITOPS_URL   ← params.gitops-url（或 secret 的 gitops-url 键）
  脚本：
    AUTH_URL="http://$GIT_USERNAME:$GIT_PASSWORD@host/path"     ← 临时拼，不落盘
    git clone $AUTH_URL  /  git remote set-url origin $AUTH_URL
    sed -i 's#^( *newTag:).*#\1 <IMAGE_TAG>#' overlays/prod/kustomization.yaml
    git config user.name "<app>-cicd-bot"; git commit; git push origin main
```

- 谁访问谁：**Pod → 对应 `*-gitops` 仓（HTTP Basic，写）**
- 钥匙：同一把 group access token（`write_repository`）
- 这是整条链路里**唯一需要写权限**的一跳，也是 token 权限不能只给只读的原因
- 实测：普通 push 能过，`--force` 会被 GitLab 的 `pre-receive hook declined` 拒掉
  —— 保护分支存在、允许 Developer 正常提交、禁止强推，这是 gitops 仓该有的形态

### 4.7 阶段 6：ArgoCD 发现变化并部署

```text
ArgoCD（每 120s 轮询一次；本集群没有配 GitLab → ArgoCD 的 webhook）
   ↓ 用 repository secret（deploy token，只读）clone 对应 gitops 仓
   ↓ 渲染 kustomize overlay（此时 newTag 已是你刚推的值）
   ↓ 与集群现状 diff → 不同就 sync（ServerSideApply）
   ↓
Deployment 滚动更新 → kubelet 去 Harbor 拉新镜像
   ↓ 用 ns 里的 imagePullSecrets（admin 或 harbor-pull）
   ↓
Pod 起来，链路结束
```

- 谁访问谁：**argocd-repo-server → GitLab（只读）**、**kubelet → Harbor（拉镜像）**、**ArgoCD → kube-apiserver**
- 三把钥匙互不相干：deploy token（读 git）、dockerconfigjson（读 registry）、SA token（改集群）
- **没有 webhook**：ArgoCD 靠轮询，所以从"CI 推完 gitops"到"集群更新"最多有 2 分钟延迟。
  这也是为什么手工验证时要 `argocd app get` 等几分钟，而不是立刻看

---

## 5. 四条流水线对照

### 5.1 总表

| | openwebui | compassio | deeptutor | china-study-free |
|---|---|---|---|---|
| 触发方式 | **GitLab CI (gitlab-runner)** | GitLab webhook → EL | GitLab webhook → EL | GitLab webhook → EL |
| GitLab webhook | **无** | 有（token 校验） | 有 | 有 |
| EventListener | 无 | `compassio-listener` | `deeptutor-listener` | `china-study-free-listener` |
| 构建器 | **kaniko**（Pod 内） | buildctl → buildkitd | buildctl → buildkitd | buildctl → buildkitd |
| 镜像项目 | `openwebui/*` | `compassio/*`（前后端两个） | `deeptutor/*` | `china-study-free/*` |
| 源码仓 | digitalsupply/openwebui | digitalsupply/compassio | **deeptutor/deeptutor** | digitalsupply/ChinaStudyFree |
| clone 凭据 | `gitlab-auth` | `gitlab-auth` | **`deeptutor-gitlab-auth`** | `china-study-free-gitlab-auth` |
| gitops 仓 | `openwebui-gitops` | `compassio-gitops` | `deeptutor-gitops` | `china-study-free-gitops` |
| 调度约束 | — | nodeSelector=worker03 | — | — |
| workspace | 10Gi（CI 里定义） | 256Mi | 2Gi | 2Gi |

### 5.2 openwebui：为什么它是"异类"

它的触发完全绕开了 Tekton Triggers：

```text
git push → GitLab → 该项目的 runner（openwebui-k8s-runner，tags=[cicd]）
   ↓ runner 在集群内的 job pod 里执行 .gitlab-ci.yml
   ↓ 读 /var/run/secrets/kubernetes.io/serviceaccount/token（SA = cicd/pipeline）
   ↓ curl -X POST https://kubernetes.default.svc/apis/tekton.dev/v1/namespaces/cicd/pipelineruns
   ↓ 只能 main 分支（rules: if $CI_COMMIT_BRANCH == "main"）
PipelineRun `open-webui-ci-*` → Pipeline `open-webui-cicd` → 与其它三条同样跑 Tekton
```

也就是：**runner 只负责"按一下按钮"，真正的活全在 Tekton 里**。这样设计的好处是同一个
Pipeline 也能 `tkn pipeline start` 手工跑；坏处是多了一层超出必要的东西：

- runner 自己需要一把 **runner token**（身份凭据，注册用，存在
  `gitlab-runner/gitlab-runner-config` 这个 Secret 里，挂成 `/etc/gitlab-runner/config.toml`）
- runner 的 job pod 需要 **Harbor 凭据**拉 CI 镜像（`image_pull_secrets = ["harbor-auth"]`）
- runner 需要 **K8s 权限**：`cicd/pipeline` 这个 SA 被绑到了 **ClusterRole/edit（整个集群）**，
  才能真正创建 PipelineRun；另有 `cicd/openwebui-runner-role` 提供更窄的等价能力

按现在的可达性（GitLab 能到 10.0.0.252），openwebui 完全可以改成和其它三条一样的 webhook 路线，
把这层拆掉。这是可选优化，不是故障。

### 5.3 deeptutor：唯一跨 group 的那条

```text
group digitalsupply (id=2)              group deeptutor (id=8)
 ├ digitalsupply/openwebui              └ deeptutor/deeptutor
 ├ digitalsupply/compassio                 deeptutor/deeptutor-gitops
 ├ digitalsupply/ChinaStudyFree
 └ ...gitops 四仓
```

凭据按 group 切分后，deeptutor 的 clone 和 gitops push 都必须用 `deeptutor-gitlab-auth`。
共用 Task `git-clone` 的 `secretKeyRef` 原先写死 `gitlab-auth`，于是这条流水线在
凭据收敛的当天就被打断了 —— 这是真实的回归，不是理论风险。

修法是给 `git-clone` 加参数，而不是复制一份 Task：

```yaml
# Task git-clone（cicd-defs.yaml:1136）
- name: gitlab-secret-name
  default: gitlab-auth            # 其它三条不传参，行为不变
# 两处 secretKeyRef.name: $(params.gitlab-secret-name)

# Pipeline deeptutor-cicd（:268）
- name: gitlab-secret-name
  value: deeptutor-gitlab-auth
```

验证是实跑 TaskRun，不是读 YAML：

```text
用 deeptutor-gitlab-auth  → True Succeeded  Cloned commit 8eaa141
用 gitlab-auth（故意错）   → False StepFailed  fatal: Authentication failed
用默认值跑 openwebui       → True Succeeded  （证明没回归）
```

### 5.4 compassio 与 china-study-free：正常的两条

- 源码仓和 gitops 仓都在 `digitalsupply`，一把 token 通吃
- compassio 有两个 build 任务（后端 `source/backend`、前端 `source/frontend`），
  两个镜像分别在 `compassio/backend`、`compassio/frontend`
- china-study-free 的 `node-image` 指向 **deeptutor 项目**里的 `deeptutor/node:22-slim`
  —— 这是个隐式耦合：deeptutor 项目一旦变 private，这条流水线立刻构建失败，因为它自己
  也没有认证拉基础镜像的能力（同 §3.2 的机制）。所以"deeptutor 项目 public"这件事
  其实是**两条流水线**共同依赖的

---

## 6. 三个最容易混的对照关系

### 6.1 webhook secret ≠ API token

| | webhook secret | API token |
|---|---|---|
| 作用 | 证明"这个请求来自 GitLab" | 证明"我是谁、我能做什么" |
| 泄露后果 | 别人能伪造触发你的流水线 | 别人能读/改你的代码、仓库设置 |
| 能否读到代码 | 不能 | 能（视 scope） |
| 本集群位置 | `cicd/*-webhook-secret`（3 份）+ GitLab 项目设置里各一份 | `cicd/*-gitlab-auth`（3 份） |

两者必须**两边一致**：GitLab 项目里改 secret token 而不同步改集群里的 Secret，
后果是流水线静默不触发（HTTP 202 一切正常）。这是最隐蔽的一类故障。

### 6.2 Secret 与 SealedSecret 不是"两种 Secret"

`SealedSecret` 只是**密文的载体**，不是能用的 Secret。链路永远是：

```text
SealedSecret（git 里的密文） --controller 解密--> Secret（集群里的明文）--> Pod 挂载/环境变量
```

所以：`kubectl get secret cicd/gitlab-auth` 能读到明文（base64 只是编码），
而 `kubectl get sealedsecret` 读到的是密文。删掉 SealedSecret 不会删 Secret
（除非有 ownerReference 反过来的关系），但下次 sync 会重建 —— 这也是接管已有 Secret 时的坑。

### 6.3 ArgoCD 的 repository secret ≠ 应用拉镜像的 secret

```text
argocd/xxx-repo-secret       → 给 argocd-repo-server 用，读 git（deploy token）
<app-ns>/harbor-auth|harbor-pull → 给 kubelet 用，读 registry（dockerconfigjson）
```

两者都叫 "secret"、都存凭据、都影响"代码能不能到集群"，但作用点完全不同：
前者错了 → ArgoCD 报 `repository not found` / `authentication required`；
后者错了 → Pod 卡在 `ImagePullBackOff`。

---

## 7. 当前的风险面

按"泄露后能干什么"排序，不按"看起来严不严重"排序。

### 7.1 Harbor admin 通用（最该改的一条）

`admin` 凭据出现在 5 个地方（§3.2），能做的包括：删项目、删镜像、改项目成员、建 robot、
改系统配置。任何一条 CI 流水线被塞进恶意 Dockerfile（比如 `RUN curl ... | sh` 或构建期窃取
`/home/user/.docker/config.json`），攻击者拿到的就是 Harbor 的完全控制权。

正确形态：每个 project 一个 robot account，只给 `push`（CI）或 `pull`（kubelet），
按项目隔离，设过期。这件事不需要停机，可以逐项目切换：建 robot → 改 Secret → 重启消费方 → 观察。

### 7.2 `deeptutor` 项目是 public

任何人（包括外网，如果 Harbor 暴露）可以匿名 `docker pull 192.168.67.202:8443/deeptutor/deeptutor:<tag>`
——镜像里通常含应用代码、依赖、有时还有配置。设成 public 的唯一理由是 buildkitd 没有凭据
（§3.2）。把 robot account 建起来之后，这个项目就可以关掉 public。

### 7.3 `cicd/pipeline` SA 绑的是 ClusterRole/edit（集群级）

```text
clusterrolebinding pipeline-edit-binding → ServiceAccount cicd/pipeline → ClusterRole/edit
```

edit 是集群范围读写绝大多数资源的权限。任何用这个 SA 跑的 Pod（流水线 Pod、runner job Pod）
都能改别的 namespace 的 Deployment、读别的 namespace 的 ConfigMap。
真实需要的能力只有"在 cicd ns 里创建 PipelineRun"，`cicd/openwebui-runner-role` 就是那个更窄的版本。

### 7.4 gitlab-runner 的 SA 能 `*` 操作 secrets

`gitlab-runner-manager` 这个 Role 给了 `secrets: *`（在 `gitlab-runner` ns）。这是 runner
创建 job pod 时挂 secret 所必需的，但意味着 runner 的 job 容器能读该 ns 的所有 Secret。
目前该 ns 只有 runner 自己和 harbor-auth，影响可控。

### 7.5 其它

| 项 | 现状 | 影响 |
|---|---|---|
| `gitlab-auth` 里的 `token` 键与 `password` 同值 | 早期兼容 | 轮换时两处都要改，容易漏一处导致"改了一半" |
| `git-url` 键已无人引用 | 遗留 | 轮换时误以为还要改 |
| 6 个 deploy token 到期 2027-11-12 | 与 `ci-rw` 同一天 | 届时 6 个 Application 同时拉不到仓 |
| 2 个 `ci-rw` 到期 2027-11-12 | — | 到期当天 4 条流水线同时断，需提前换 |
| ArgoCD 无 webhook（轮询 120s） | — | 最多 2 分钟延迟；配 webhook 可做到秒级 |
| webhook 拦截器静默丢弃 | 设计如此 | 配错时不报错，只能看 EL 日志或 `kubectl get pipelinerun` |

---

## 8. 轮换 runbook

按**依赖顺序**改，否则中间会有一段"流水线跑不通"。

### 8.1 换某个 group 的 `ci-rw`

```text
1. GitLab → 对应 group → Settings → Access tokens → 新建同 scope token（先别删旧的）
2. kubeseal 封新的 → 覆盖 platform/secrets/cicd/sealed/<name>.sealed.yaml
3. commit + push platform-gitops → ArgoCD sync（或手动 kubectl annotate 触发）
4. 验证：对每个消费方跑一次真实 clone
     git ls-remote http://ci-rw:<new>@192.168.67.201/digitalsupply/<repo>.git
5. 验证写：在 *-gitops 仓推一个空提交（普通 push 能过、force 被拒 = 保护分支正常）
6. 观察一轮真实流水线（PipelineRun Succeeded）
7. 删旧 token
```

坑：`gitlab-auth` 里 `password` 和 `token` 两个键都要更新（虽然只有 `password` 被 Task 读）。

### 8.2 换 deploy token（ArgoCD 用）

```text
1. 对应项目 → Settings → Repository → Deploy tokens → 新建（scope=read_repository）
2. 更新 argocd ns 里的 repository secret（username=gitlab+deploy-token-N，password=新值）
3. argocd app get 任意一个 app → 确认 Synced；或直接 argocd repo list
4. 删旧 deploy token
```

注意：ArgoCD 的 repo secret **不在 git 里**（它们是 bootstrap 级、每个集群一套），
所以轮换是"改集群 + 记文档"，不是改仓库。

### 8.3 换 Harbor admin → robot account（推荐做法）

```text
1. Harbor → 项目 → Robots → 新建（openwebui: push+pull；compassio: push+pull；
   deeptutor: push+pull；china-study-free: push+pull；拉取方只要 pull）
2. 生成 dockerconfigjson，逐项替换：
   cicd/harbor-auth（build Task 的 DOCKER_CONFIG + buildkitd 的 imagePullSecrets）
   gitlab-runner/harbor-auth
   compassio/harbor-auth、china-study-free/harbor-auth、open-webui/harbor-pull
3. 逐个消费方重启（buildkitd、runner、Deployment）
4. 验证：跑一条流水线；kubectl rollout restart 一个 app 看 imagePull 成功
5. 全部切完后 → Harbor 把 deeptutor 项目改回 private
6. 最后再考虑禁用 admin 的日常使用（admin 仍保留给人登录用）
```

坑：`kaniko` 与 `buildctl` 读的路径不同（`/kaniko/.docker` vs `/home/user/.docker`），
但**读的是同一份 `.dockerconfigjson` 的 `config.json`**，换的时候两个 Task 都要验证。

### 8.4 换 webhook secret

```text
1. 生成新随机值
2. 改 GitLab 项目 Webhook 里的 Secret token
3. 同步改 cicd/<x>-webhook-secret 的 secretToken（kubeseal 重封 + ArgoCD sync）
   —— 顺序无所谓，但中间那一小段时间流水线不触发（202 但无 PipelineRun）
4. 验证：真推一个 commit，看有没有 PipelineRun 生成
```

**验证必须看 PipelineRun 有没有出现，不能看 GitLab 返回码** —— 返回 202 是常态。

---

## 9. 附：取证命令

这些命令可以复现本文所有数字（不含密文值）。

```bash
# ---- GitLab：token / webhook / 仓库（在 GitLab 主机上执行）
gitlab-rails runner 'PersonalAccessToken.find_each { |t| puts "#{t.user&.username} #{t.name} #{t.scopes.join(",")} revoked=#{t.revoked?} #{t.expires_at}" }'
gitlab-rails runner 'Project.find_each { |p| p.hooks.each { |h| puts "#{p.full_path} -> #{h.url} push=#{h.push_events} token_set=#{h.token.present?}" } }'
gitlab-rails runner 'Project.find_each { |p| p.deploy_tokens.each { |t| puts "#{p.full_path} #{t.name} #{t.username} #{t.scopes.join(",")}" } }'
getent hosts el-deeptutor.internal      # → 10.0.0.252

# ---- Harbor：项目公开状态与 robot 数量
# （用任意有权限的凭据调 REST；本文用的是 cicd/harbor-auth 里的账号，只读 GET）
curl -sk -u <user>:<pass> https://192.168.67.202:8443/api/v2.0/projects?page_size=50 | jq '.[] | {name, public: .metadata.public, repo_count}'
curl -sk -u <user>:<pass> https://192.168.67.202:8443/api/v2.0/robots | jq length    # → 0

# ---- K8s：Secret 的形状（只看 key 名，不看值）
kubectl -n cicd get secret -o json | jq -r '.items[] | "\(.metadata.name)\t\(.data|keys|join(","))"'
kubectl -n cicd get secret gitlab-auth -o json | jq -r '.metadata.ownerReferences[].name'
kubectl -n argocd get secret -o json | jq -r '.items[] | select(.metadata.labels["argocd.argoproj.io/secret-type"]=="repository") | "\(.metadata.name)\t\(.data.url|@base64d)"'

# ---- Tekton：谁引用了哪个 secret 的哪个 key
kubectl -n cicd get task,pipeline,triggerbinding,triggertemplate,eventlistener -o json | jq -r '
  .. | objects | select(.secretKeyRef) | "\(.secretKeyRef.name)/\(.secretKeyRef.key)"' | sort | uniq -c

# ---- 触发链路是否通（不需要泄露 token）
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://el-deeptutor.internal/ \
  -H "X-Gitlab-Token: wrong" -H "X-Gitlab-Event: Push Hook" -H "Content-Type: application/json" \
  -d '{"object_kind":"push","ref":"refs/heads/main","before":"a","after":"b","repository":{"git_http_url":"http://x/y.git"}}'
# → 202（EL 收到）；随后 kubectl -n cicd get pipelinerun 应**没有**新记录

# ---- RBAC 现状
kubectl get clusterrolebinding pipeline-edit-binding -o jsonpath='{.subjects}'
kubectl -n gitlab-runner get role gitlab-runner-manager -o jsonpath='{.rules}'

# ---- ArgoCD 轮询间隔
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'   # → 120s
```

---

## 10. 一句话总结

这套系统的凭据可以概括成三层：

```text
第一层：GitLab 的 token（分 group、分只读/读写）——决定"代码能不能进来、能不能写回"
第二层：Harbor 的凭据（当前是 admin 一把梭）——决定"镜像能不能推、能不能拉"
第三层：Kubernetes 的 SA token（pipeline SA 是集群级 edit）——决定"流水线能改集群的哪些东西"
```

三层之间没有共享关系，各自独立轮换。**最容易出错的地方不是某一层配错，而是
"一条流水线同时用到三层，而每一层的边界不一样"** —— deeptutor 跨 group 那次就是典型：
第一层的边界（group）和第三层的实现（共用 Task 写死 secret 名）撞在一起，报错却是第一层的
`Access denied`，看起来像 token 坏了。
