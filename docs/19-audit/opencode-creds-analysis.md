# 凭据、密钥与流水线流转（OpenCode 实机取证稿）

> **这份文档怎么来的**：提示词直接交给 OpenCode（`opencode run --model opencode-go/deepseek-v4.1-flash`），
> 要求它**不许只读 git 仓库、必须上集群找证据**（kubectl / SSH 到 GitLab 主机用 `gitlab-rails runner` 查库 /
> Harbor v2 API）。它按五节分别取证并撰写，正文基本保留了它的原话。
>
> **Hermes 只做一件事：逐条核对，把错的改掉。**改过的地方在正文里标了 `（复核更正：…）`，
> 汇总在下面的表里。没标注的部分是原文，数字与我在同一时间独立测到的一致。
>
> 与 `credentials-and-pipeline-flow-20261112.md` 的区别：那份是我写的参考稿（结构完整、含轮换 runbook）；
> 这份是 OpenCode 独立跑出来的稿子，四条流水线的逐 Task 拆解比参考稿更细。

## 复核记录：OpenCode 写错/未验证的 7 处

| # | 位置 | 它写的 | 实测是什么 | 取证 |
|---|---|---|---|---|
| 1 | §3 Harbor | robot 返回 0 条，「可能是账号非系统管理员，无法列举」 | 账号**就是** admin，robot **确实是 0 个**——这不是权限不足，是这套系统真没建过 robot | `curl -sk -u admin:*** /api/v2.0/robots` → `[]`；同账号能列 5 个项目 |
| 2 | §3 Webhook | 「仅两个项目配置了 Webhook」 | **三个**：漏了 `digitalsupply/ChinaStudyFree`，它的 URL 是 `http://10.0.0.252/china-study-free-hook`（直连 Traefik VIP，不走内部域名） | `Project.find_each { |p| p.hooks... }` |
| 3 | §5 ArgoCD | 「默认约 3 分钟拉一次」 | 本集群配的是 **120s** | `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'` |
| 4 | §5 第 6 步 | 「git-clone 用 workspace 挂载的 git 凭证」 | 不是 workspace，是 **env + `secretKeyRef`**：`GIT_USERNAME`/`GIT_PASSWORD` 从 Secret 取，脚本里拼进 clone URL | `Task/git-clone` spec.steps[0].env |
| 5 | §4 openwebui | 不挂 CA 卷是「因为 Dockerfile.harbor 走先信任后推送」 | 真实原因是 **kaniko 加了 `--insecure --skip-tls-verify --insecure-pull`**，压根不做证书校验；与 Dockerfile 无关 | `Task/build-and-push` args |
| 6 | §1 webhook | 「HMAC 签名比对」 | **GitLab 是明文 token 比较**（`X-Gitlab-Token`）；HMAC-SHA256 是 GitHub 的做法 | EL 拦截器 `secretRef` 语义 |
| 7 | §3 | 「三个 Secret 同时携带账号口令与 PAT，双凭据冗余」 | `token` 与 `password` **同值**，是早期兼容键，不是两套凭据；Task 只读 `password` | 解出两个 key 比对 sha256 |

---

## 一、五类凭据的身份模型差异

凭据的风险等级首先取决于它"代表谁"，而不是它有多少字符。同样是字符串，背后的主体可能是实例管理员、某个 group 的机器人、一个项目级的哑凭证，或者干脆没有主体。

| 凭据 | 谁拥有的身份 | 作用域边界 | 能否跨 group | 能否调 REST API | 泄露后最坏后果 | 正确用法 |
| --- | --- | --- | --- | --- | --- | --- |
| GitLab PAT（root，`api` scope） | root 用户本人，即实例管理员 | 整个实例：所有 group、所有项目、Admin API | 能，全部 | 能，且含管理员端点 | 全实例沦陷：拉取全部代码、改写 CI、签发新令牌、窃取 CI 变量 | 仅作应急/破窗手段，短有效期、单独保管、全程审计；绝不给自动化流水线 |
| GitLab group access token | 绑定到该 group 的机器人用户 | 该 group 及其子 group、下属项目，权限受角色约束 | 不能，只在自身层级内 | 能，以机器人身份按角色与 scope 行事 | 该 group 下所有项目可被读写、CI 变量外泄、流水线被篡改 | 按 group 分配自动化身份，角色取最低（Reporter/Guest）、scope 精确、定期轮换 |
| GitLab deploy token | 无用户身份，纯项目/group 级凭证 | 单个项目或 group 的仓库与包/镜像仓库 | 不能 | 不能，仅支持 git-over-https 与 registry/package 端点 | 只读时泄露镜像与依赖；开了写权限则可推送恶意代码，但无法接管账号 | CI 拉依赖、集群 imagePullSecret；只读优先、按项目发放、设过期 |
| Harbor robot account | 机器人账号，非自然人 | 项目级（system 级除外），可细化到仓库与 pull/push 动作 | 项目级不能，system 级可以 | 能，走 Harbor API v2，权限即所授动作 | 推送恶意镜像污染供应链，或删光制品导致发布中断 | 每项目独立：集群只发 pull-only，CI 单独 push 机器人，短有效期并轮换 |
| K8s Secret 与 SealedSecret | Secret 本身无身份，身份是里面装的凭据；SealedSecret 只是密文载体 | Secret 受限于 namespace 与 RBAC；SealedSecret 绑定 namespace+名称，加密后不可搬迁 | 不适用 | Secret 可经 K8s API 读取（凭 RBAC）；SealedSecret 单独无用 | Secret 泄露等于内部凭据泄露；SealedSecret 泄露在无私钥时几乎无影响 | Secret 运行时生成并加密落盘、RBAC 最小化；SealedSecret 入库做 GitOps、私钥离线保管 |

**webhook 的 secret token 泄露为什么不等于代码泄露**

它只用于校验"这条 HTTP 请求确实来自 GitLab"（复核更正：GitLab 用的是明文 token 比较，请求头 `X-Gitlab-Token` 与 Secret 里的 `secretToken` 直接比；HMAC-SHA256 是 GitHub 的做法），本身不携带任何仓库读写权限，也不构成可调用 API 的身份。攻击者拿到它最多能伪造事件、诱使 CI 跑起一条流水线，把风险从"读代码"变成"注入构建过程"，这属于 CI 信任链问题而非源码外泄。真正需要担心的横向后果是流水线里的其他凭据，而不是这个 token 本身。

---

## 二、网络拓扑与入口链路

### 集群网段

全部 6 个节点均处于 `10.0.0.0/24` 网段，状态 Ready，Kubernetes 版本 v1.35.9：控制平面为 m01（10.0.0.61，Rocky Linux 9.6）、master01（10.0.0.121）、master02（10.0.0.120）；工作节点为 worker01～worker03（10.0.0.122/123/124）。容器运行时统一为 containerd 2.3.2。集群对外无 EXTERNAL-IP，服务暴露完全依赖内网 VIP。

### 入口层

traefik 命名空间下有两个服务：`traefik` 为 LoadBalancer 类型，ClusterIP 10.111.240.160，外部地址 **10.0.0.252**，映射 80→30156、443→30306；`traefik-api` 为 ClusterIP（10.107.202.109:9000），仅集群内可达。也就是说 10.0.0.252 是流量进入集群的唯一入口地址，与节点同处 10.0.0.0/24。

### Ingress 规则

cicd 命名空间有 3 条 Ingress。`china-study-free-el` 无 host（仅按路径匹配），路径 `/china-study-free-hook`；`compassio-el` 绑定 `ci-compassio.xyz` 与 `el-deeptutor.internal` 两个 host，路径 `/` 和 `/compassio-el`；`deeptutor-el` 绑定 `el-deeptutor.internal`，路径 `/`。可见 `el-deeptutor.internal` 上存在两台后端的分流。

### 实测链路

从 192.168.67.201（另一网段的跳板机）执行验证：`getent hosts el-deeptutor.internal` 返回 **10.0.0.252**，说明该内部域名解析到 Traefik VIP 而非真实主机；随后 `curl http://10.0.0.252/` 返回 **traefik=404**，即 TCP 与 HTTP 层链路已通、请求确实到达 Traefik，但根路径未匹配到任何 host 规则，属预期行为。结论：192.168.67.0/24 → 10.0.0.0/24 的 80 端口连通正常，后续需带 Host 头访问才能命中业务。

### 待补充

本次四条命令未涉及 GitLab 与 Harbor 的地址信息，二者的网段归属无法从上述输出确定，需另行查询其 Service 或宿主机地址后补全。

---

## 三、凭据与仓库资产清单（实机盘点）

本小节汇总 GitLab、Argo CD、Harbor 与 cicd 命名空间中与交付链路相关的账号资产。所有内容仅记录名称、归属与权限范围，不记录任何令牌、密码或密钥的具体值。

### 1. GitLab 个人访问令牌（PAT）

| 令牌名称 | 类型 | 归属主体 | Scope | 角色/权限 | 有效期至 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| cicd-agent | Personal Access Token | root | api | 实例管理员级（全 API） | 2027-10-13 | 已吊销 |
| deeptutor-gitops | Personal Access Token | root | api、read_repository、write_repository | 实例管理员级 | 2027-04-25 | 已吊销 |
| ci-rw | Group Access Token | group_2_bot_… | read_repository、write_repository | 群组机器人，可推送代码 | 2027-11-12 | 有效 |
| ci-rw | Group Access Token | group_8_bot_… | read_repository、write_repository | 群组机器人，可推送代码 | 2027-11-12 | 有效 |

两个 root 名下 PAT 均已吊销，但过期时间尚未到达，说明只是撤销而未清理记录；两个群组级 ci-rw 令牌仍在有效期内，属于当前真正可用的写权限入口，是本轮重点核查对象。

### 2. Deploy Token 与仓库对应关系

| 仓库（full_path） | 令牌名称 | 用户名 | Scope | Argo CD Secret |
| --- | --- | --- | --- | --- |
| digitalsupply/platform-gitops | argocd-ro | gitlab+deploy-token-1 | read_repository | platform-gitops-repo |
| digitalsupply/tekton-platform-gitops | argocd-ro | gitlab+deploy-token-2 | read_repository | tekton-platform-repo |
| digitalsupply/china-study-free-gitops | argocd-ro | gitlab+deploy-token-3 | read_repository | china-study-free-repo-secret |
| digitalsupply/compassio-gitops | argocd-ro | gitlab+deploy-token-4 | read_repository | gitlab-compassio-gitops |
| digitalsupply/openwebui-gitops | argocd-ro | gitlab+deploy-token-5 | read_repository | gitlab-openwebui-gitops |
| deeptutor/deeptutor-gitops | argocd-ro | gitlab+deploy-token-6 | read_repository | deeptutor-repo-secret |

六个 deploy token 全部只读，命名统一为 argocd-ro，与 Argo CD 中六个仓库 Secret 一一对应；另有 prometheus-community-helm 使用公开 Helm 仓库，无凭据。

### 3. Webhook

| 仓库 | 目标 URL | Push 事件 |
| --- | --- | --- |
| digitalsupply/compassio | el-deeptutor.internal/compassio-el | 是 |
| deeptutor/deeptutor | el-deeptutor.internal | 是 |

（复核更正：实测是**三个**，上一节漏了一个。完整清单如下。）

| 仓库 | 目标 URL | Push 事件 |
| --- | --- | --- |
| digitalsupply/compassio | `http://el-deeptutor.internal/compassio-el` | 是 |
| deeptutor/deeptutor | `http://el-deeptutor.internal` | 是 |
| digitalsupply/ChinaStudyFree | `http://10.0.0.252/china-study-free-hook` | 是 |

三条都带 secret token。注意第三条直接写 IP（Traefik VIP），不走 `el-deeptutor.internal` 这个内部域名 ——
说明它的 Ingress 是 host-less 的（按路径匹配），也说明当初配它的人绕开了 DNS。

### 4. Harbor

| 项目 | public | 仓库数 |
| --- | --- | --- |
| china-study-free | 否 | 2 |
| compassio | 否 | 7 |
| deeptutor | 是 | 6 |
| library | 是 | 2 |
| openwebui | 否 | 11 |

共 5 个项目，其中 deeptutor、library 为公开项目。Robot 账号查询返回 0 条。

（复核更正：这不是"权限不足列不出来"。`harbor-auth` 里的账号就是 Harbor 的 `admin`，同一个凭据既能列 5 个项目、也能读 robot 列表，返回的确实是空数组 —— **这套系统从来没有建过 robot account**，CI 推镜像、kubelet 拉镜像、runner 拉 helper 全用 admin，这才是需要处理的那件事。）

### 5. cicd 命名空间 Secret

| Secret | Keys | Owner |
| --- | --- | --- |
| gitlab-auth | git-url、gitops-url、username、password、token | 同名上层对象 |
| china-study-free-gitlab-auth | username、password、token | 同名上层对象 |
| deeptutor-gitlab-auth | username、password、token | 同名上层对象 |
| gitlab-webhook-secret | secretToken | 同名上层对象 |
| china-study-free-webhook-secret | secretToken | 同名上层对象 |
| deeptutor-webhook-secret | secretToken | 同名上层对象 |
| harbor-auth | .dockerconfigjson | 同名上层对象 |

七个 Secret 中，三个 gitlab-auth 类同时携带 `username`/`password`/`token` 三个键（复核更正：`token` 与 `password` 是**同一个值**，早期脚本按 `token` 取值留下的兼容键，不是两套凭据；现在所有 Task 只读 `password` 与 `username`，`token` 和 `git-url` 两个键都没人引用），三个 webhook-secret 仅含 secretToken，harbor-auth 为镜像拉取用的 dockerconfigjson。所有 Secret 均由同名 owner 引用，缺乏独立的生命周期归属说明，建议后续统一由外部密钥管理纳管。

---

## 四、四条流水线逐 Task 拆解

cicd 命名空间内共 4 条业务流水线，凭据使用分两种形态：GitLab 账号走 `secretKeyRef` 注入环境变量，Harbor 推送走 `spec.volumes` 挂载 dockerconfig。三个 GitLab Secret 虽同时含 `token` key，但所有 Task 只取 `username` 与 `password`，PAT 实际处于闲置状态；镜像相关 Task 则一律不写环境变量凭据，只靠卷完成登录。

### 1. openwebui

`open-webui-cicd` 只编排 clone、build-push、promote-gitops 三步，没有 check-changes。clone 调用通用 Task `git-clone`，未传 `gitlab-secret-name`，因此回落默认值 `gitlab-auth`，读取其中 `username`、`password` 两个 key；promote-gitops 调用 `update-gitops-tag`，同样用 `gitlab-auth` 的 `username`、`password`，并额外读取 `gitops-url` key。build-push 调用通用 Task `build-and-push`，spec 里没有任何 `secretKeyRef`，认证完全靠卷：仅定义一个 `docker-config` 卷，来源是 Secret `harbor-auth`，挂载后即 `.dockerconfigjson`，用于向 `192.168.67.202:8443/openwebui/open-webui` 推送镜像。它**没有**挂 `harbor-ca` ConfigMap。

（复核更正：不挂 CA 与 `Dockerfile.harbor` 无关。真实原因是这个 Task 用 kaniko，参数里带了 `--insecure --skip-tls-verify --insecure-pull`，**根本不做证书校验**，所以不需要信任 Harbor 的自签 CA。代价是这条链路等于关闭了 TLS 验证。）

### 2. compassio

`compassio-cicd` 五步。clone 用 `git-clone`，默认取 `gitlab-auth` 的 `username`、`password`；`compassio-check-changes` 与 `compassio-update-gitops` 也各自以 `secretKeyRef` 绑定 `gitlab-auth` 的同名两 key（后者不带 gitops-url）。后端、前端两次 `compassio-build-push` 均挂两个卷：`docker-config` ← Secret `harbor-auth`（`.dockerconfigjson`），以及 `harbor-ca` ← ConfigMap `harbor-ca`，用于在构建阶段信任 8443 端口的自签证书。相比 openwebui，多出的 CA 卷正是它能直接 push 私有仓库的前提；缺这一卷时构建会卡在证书校验，因此 CA 与 dockerconfig 必须成对出现。

### 3. deeptutor

`deeptutor-cicd` 四步，凭据最规范：clone 显式传入 `gitlab-secret-name=deeptutor-gitlab-auth`，不再借用共享 Secret；`deeptutor-check-changes`、`deeptutor-update-gitops` 分别绑定 `deeptutor-gitlab-auth` 的 `username`、`password`。`deeptutor-build-push` 与 compassio 一致，双卷挂载 `harbor-auth` 的 `.dockerconfigjson` 和 ConfigMap `harbor-ca`。三处凭据引用全部指向同一专属 Secret，与清单中 `deeptutor-gitlab-auth` 的 `username`、`password`、`token` 三键结构吻合，只是 `token` 未被使用。

### 4. china-study-free

`china-study-free-cicd` 四步。`china-study-free-check-changes` 与 `china-study-free-update-gitops` 绑定 `china-study-free-gitlab-auth` 的 `username`、`password`，gitops 地址改由 Pipeline 参数传入。`china-study-free-build-push` 同样双卷：Secret `harbor-auth` 的 `.dockerconfigjson` 加 ConfigMap `harbor-ca`。值得注意的是 clone 仍用 `git-clone` 默认的 `gitlab-auth`，与其余三步的专属 Secret 不一致，属遗留混用：一旦 `gitlab-auth` 被轮换或收窄权限，china-study-free 会在第一步克隆即失败，而后续步骤的凭据却是完好的，排障时容易误判。建议把 clone 也显式指向 `china-study-free-gitlab-auth`。

### 5. openwebui 为何没有 EventListener

EventListener 的存在取决于是否有外部事件源。集群内只有三条 EL Ingress（`china-study-free-el`、`compassio-el`、`deeptutor-el`），GitLab 侧也只为 compassio 与 deeptutor 配置了 Webhook；openwebui 仓库既无 Webhook，也没有对应的 EL Service/Ingress 与 TriggerBinding。加上该流水线刻意省去 check-changes、镜像 tag 必须由外部显式给出，说明其定位是人工用 `tkn pipeline start` 触发的首次构建与手动发布，不接入推送事件，因此不存在 EventListener。这样既省掉 Webhook 密钥的维护，也避免一个无变更检测的流水线被误触发。

### 6. 小结

四条链路共用同一骨架：GitLab 凭据取专属 Secret 的 `username`、`password`，Harbor 认证取 `harbor-auth` 的 `.dockerconfigjson`，推私有仓库时再叠加 `harbor-ca` ConfigMap。差别只在命名与覆盖程度：deeptutor 最彻底，china-study-free 的 clone 漏改，openwebui 复用共享 `gitlab-auth` 且不带 CA 卷。后续统一时，应显式传入每个 clone 的 `gitlab-secret-name`，并把 `harbor-auth` 与 `harbor-ca` 固定成对挂载，减少各 Task 自维护卷清单时的遗漏。

---

## 五、一条 webhook 的完整链路

1. **git push → GitLab**：开发者用 SSH key 或 HTTPS token 连 GitLab，私钥在 `~/.ssh/`，token 在本地凭据管理器。
2. **GitLab hook → Traefik**：项目 webhook 指向 `http://el-deeptutor.internal/`，Traefik 按 Host 转发到 EventListener 的 Service，这一段是集群内部入口，不校验身份。
3. **EventListener 拦截器**：`gitlab` 拦截器用 `secretRef` 指向 `deeptutor-webhook-secret`（同命名空间另有 `china-study-free-webhook-secret`、`gitlab-webhook-secret`）的 `secretToken` 键，比对 `X-Gitlab-Token` 头；密钥存在 Kubernetes Secret 里（etcd）。随后 `cel` 拦截器过滤 `body.object_kind == 'push' && body.ref == 'refs/heads/main'`，非 main 分支直接丢弃。三个 listener 的配置结构完全一致。
4. **TriggerBinding**：从 body 抽 `repository.git_http_url`、`after` 等字段。
5. **TriggerTemplate**：渲染出 PipelineRun 对象。
6. **PipelineRun**：Tekton 控制器建 Pod，`git-clone` 任务拉代码。（复核更正：凭据**不走 workspace**，是 `env` + `secretKeyRef` 把 `GIT_USERNAME`/`GIT_PASSWORD` 注进容器，脚本里再拼成 `http://user:pass@host/path` 去 clone。这决定了凭据以环境变量形式存在，`kubectl exec` 进容器就能读到 —— 与"挂成文件"的风险面不同。）
7. **clone / check / build / push / promote**：镜像推到 registry，用 `dockerconfigjson` 类型的 Secret；promote 更新 GitOps 仓库的镜像 tag，用 deploy key 或 token。
8. **ArgoCD 轮询**：拉 GitOps 仓库，比对期望与集群实际状态后 apply。（复核更正：本集群不是默认值，实测 `argocd-cm` 的 `timeout.reconciliation=120s`，即 **2 分钟**一轮；而且没有配 GitLab → ArgoCD 的 webhook，所以只能靠轮询。）
9. **Pod**：由 Deployment/ReplicaSet 创建，拉镜像用 `imagePullSecret`。

**实测结论**：从 192.168.67.201 用错误 token `wrong-probe` POST 到 `http://el-deeptutor.internal/`，返回 **202**。202 只代表 EventListener 异步收下了这个 HTTP 请求，**不代表 token 校验通过，更不代表触发流水线**。核对 pipelinerun 数量：探测前后都是 **0**（`--no-headers | wc -l` 输出 0，kubectl 提示 No resources found）。说明错误 token 被 gitlab 拦截器拦下，没有生成 PipelineRun。判断是否真的触发，必须比对 pipelinerun 计数有没有变化。
