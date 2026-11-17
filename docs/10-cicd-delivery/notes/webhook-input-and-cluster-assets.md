# Webhook 作为 CI/CD 输入信息的原理与集群实测资源清单

> 主题：为什么 CI/CD 流水线的"输入信息"是 webhook，以及集群中承载 webhook 链路的各类资源。
> 所有结论均来自本集群（10.0.0.0/16，GitLab `192.168.67.201`）实机取证，非文档转述。
> 取证时间：2026-11-17。

## 一、为什么 webhook 是 CI/CD 的输入信息

CI/CD 的核心问题是：**当代码发生变化时，自动触发构建与部署**。要实现"自动触发"，系统必须有一个信号源，通知流水线"有事情发生了，请开始工作"。

在这个架构里，**webhook 就是这个信号源，也就是流水线的输入信息**。

### 1. webhook 的本质

webhook 是一种"**由事件源主动向接收方发起 HTTP 回调**"的机制。与传统的"接收方轮询"不同，webhook 是"事件源推送"：

- **事件源**（GitLab）：当仓库发生 push、合并请求等事件时，主动向预先配置的 URL 发起 HTTP POST。
- **接收方**（集群里的 Tekton EventListener）：在 URL 上接收请求，解析事件内容，触发后续流水线。

所以 webhook 承担的是 **"事件通知 + 事件数据载体"** 的双重角色：
1. **通知作用**：告诉流水线"有 push 事件，请处理"。
2. **数据载体**：HTTP POST 的 body 里携带了这次 push 的完整信息（分支、commit SHA、仓库地址、改动文件等），这些就是流水线的**输入参数**。

### 2. 为什么用 webhook 而不是轮询

| 方式 | 机制 | 问题 |
|---|---|---|
| 轮询 | 流水线定时去 GitLab 查"有没有新提交" | 延迟高、空转浪费资源、无法实时 |
| webhook | GitLab 事件发生时立即推送 | 实时、高效、事件内容完整 |

webhook 把"事件源的变化"转化为"流水线的输入"，是事件驱动架构的标准做法。**没有 webhook 这个输入，流水线就不会自动启动**——这就是"输入信息是 webhook"的含义。

### 3. webhook 输入里包含什么

以本集群 deeptutor 项目的 Push Hook 为例，GitLab 推送的 webhook body 包含（实测从真实 PipelineRun 反推）：

| 字段 | 含义 | 被流水线用作 |
|---|---|---|
| `body.repository.git_http_url` | 仓库地址 | 流水线的 `git-url` 参数（clone 源） |
| `body.after` | 本次 push 的 tip commit SHA | 流水线的 `git-revision` / `image-tag` |
| `body.before` | 上一个 tip commit SHA | 流水线的 `git-before`（用于变更对比） |
| `body.object_kind` | 事件类型（`push`） | CEL 拦截器过滤条件 |
| `body.ref` | 分支引用（如 `refs/heads/main`） | CEL 拦截器过滤条件 |

这些字段经 TriggerBinding 提取后，直接成为 PipelineRun 的参数，驱动后续 clone、构建、部署。**webhook body 就是流水线的输入数据。**

## 二、webhook 请求如何进入集群

webhook 从 GitLab 发出后，需要经过网络路由才能到达集群里处理它的组件。实测本集群的入口链路：

```
GitLab (192.168.67.201)
  │  HTTP POST  (X-Gitlab-Event: Push Hook, X-Gitlab-Token: <webhook token>)
  ▼
Traefik Ingress (10.0.0.252:80)
  │  按 Ingress 规则路由
  ▼
EventListener Service (el-deeptutor-listener:8080)
  │
  ▼
EventListener (Tekton Triggers 控制器管理的 Deployment)
```

实测的 Ingress 配置（`cicd/deeptutor-el`）：
- host：`el-deeptutor.internal`
- path：`/`
- 后端：`el-deeptutor-listener` Service 的 8080 端口

GitLab 项目 Webhook 里配置的 URL 即 `http://el-deeptutor.internal/`，与该 Ingress 规则对应。

## 三、集群中承载 webhook 链路的资源清单（实测）

以下是集群中与 webhook 链路直接相关的资源，按在链路中的位置分类。所有名称、配置均来自 `kubectl` 实机查询。

### 1. 网络入口层

| 资源 | 命名空间 | 实测配置 | 作用 |
|---|---|---|---|
| Ingress `deeptutor-el` | cicd | host `el-deeptutor.internal`，path `/` → `el-deeptutor-listener:8080` | 把外部 webhook 请求路由到 EL Service |
| Ingress `compassio-el` | cicd | host `ci-compassio.xyz`（path `/`）、host `el-deeptutor.internal`（path `/compassio-el`）→ `el-compassio-listener` | compassio 的 webhook 入口（同 Ingress 承载两个 host） |
| Ingress `china-study-free-el` | cicd | path `/china-study-free-hook` → `el-china-study-free-listener` | china-study-free 的 webhook 入口（按路径区分） |

> 三个项目的 webhook 入口分别用不同 Ingress，路由方式不同：deeptutor 用独立 host，compassio 用同 Ingress 多 host 多路径，china-study-free 用独立路径。

### 2. EventListener 层（接收并校验 webhook）

| 资源 | 命名空间 | 实测配置要点 | 作用 |
|---|---|---|---|
| EventListener `deeptutor-listener` | cicd | serviceAccountName `pipeline`；trigger `gitlab-push`；拦截器：gitlab + cel；Binding `deeptutor-binding`；Template `deeptutor-template` | 接收 webhook，经拦截器校验后触发 PipelineRun |
| EventListener `compassio-listener` | cicd | 结构同上，引用 `gitlab-webhook-secret` | compassio 的 webhook 接收端 |
| EventListener `china-study-free-listener` | cicd | 结构同上，引用 `china-study-free-webhook-secret` | china-study-free 的 webhook 接收端 |
| Service `el-deeptutor-listener` | cicd | clusterIP `10.107.145.92`，port 8080→8080 | EL 的服务端点，Ingress 转发目标 |
| Deployment `el-deeptutor-listener` | cicd | 由 Tekton Triggers 控制器托管 | EL 的实际运行载体 |

### 3. 拦截器（webhook 校验核心）

EventListener 上挂的 ClusterInterceptor 是校验 webhook 的关键环节，实测 deeptutor 的拦截器配置：

**`gitlab` 拦截器（来源校验）**：
- `secretRef`：`deeptutor-webhook-secret` / `secretToken`
- `eventTypes`：`[Push Hook]`
- 作用：读取 Secret 中的 `secretToken`，与请求头 `X-Gitlab-Token` 做**明文字符串比较**；同时限定只接受 `Push Hook` 事件类型。

**`cel` 拦截器（内容过滤）**：
- `filter`：`body.object_kind == 'push' && body.ref == 'refs/heads/main'`
- 作用：只放行 push 到 main 分支的事件，其它分支直接丢弃。

> **重要实测发现**：真正读取 webhook Secret 的不是 EL pod 本身，而是 Tekton **core-interceptors**（ServiceAccount `tekton-triggers-core-interceptors`）。实测 `kubectl auth can-i get secrets/deeptutor-webhook-secret -n cicd --as=system:serviceaccount:tekton-pipelines:tekton-triggers-core-interceptors` 返回 **yes**。EL pod 只挂载了 `kube-api-access` token，未挂载 webhook Secret。

### 4. Secret 层（webhook 与 git 凭据）

| Secret | 命名空间 | 键 | 类型 | 作用 |
|---|---|---|---|---|
| `deeptutor-webhook-secret` | cicd | `secretToken` | 共享验证密钥 | 校验 webhook 请求是否来自 GitLab（明文比对） |
| `gitlab-webhook-secret` | cicd | `secretToken` | 共享验证密钥 | compassio 的 webhook 校验 |
| `china-study-free-webhook-secret` | cicd | `secretToken` | 共享验证密钥 | china-study-free 的 webhook 校验 |
| `deeptutor-gitlab-auth` | cicd | `username`/`password`/`token` | Basic Auth（机器人账号） | git clone / git push（应用仓 + gitops 仓） |
| `gitlab-auth` | cicd | `username`/`password`/`token`/`git-url`/`gitops-url` | Basic Auth（机器人账号） | compassio/openwebui 流水线的 git 凭据 |
| `harbor-auth` | cicd | `.dockerconfigjson` | docker config | 构建镜像推送 Harbor 的凭据 |

所有 Secret 均由 SealedSecret 管理（ownerReferences 指向对应 SealedSecret），密文落 etcd。

### 5. 触发器定义层（解析 webhook 输入）

| 资源 | 命名空间 | 实测配置 | 作用 |
|---|---|---|---|
| TriggerBinding `deeptutor-binding` | cicd | 提取 `gitrepositoryurl`←`body.repository.git_http_url`、`gitrevision`←`body.after`、`gitbefore`←`body.before` | 从 webhook body 提取字段 |
| TriggerTemplate `deeptutor-template` | cicd | 生成 PipelineRun，参数映射 git-url/git-revision/git-before/image-tag | 把提取的字段组装成 PipelineRun |

TriggerBinding 是"输入解析器"——它把 webhook body 这个输入信息拆解成流水线参数；TriggerTemplate 是"执行器模板"——把参数组装成可执行的 PipelineRun。

### 6. 流水线执行层

| 资源 | 命名空间 | 实测配置 | 作用 |
|---|---|---|---|
| Pipeline `deeptutor-cicd` | cicd | 4 个 Task：clone → check-changes → build-push → update-gitops（后两个受 `when` 控制） | 定义 CI/CD 流程 |
| Task `git-clone` | cicd | 用 `deeptutor-gitlab-auth` 的 username+password 做 Basic Auth clone | 拉取代码 |
| Task `deeptutor-check-changes` | cicd | 对比 before/after 改动文件，输出 need-build | 文档变更判定 |
| Task `deeptutor-build-push` | cicd | BuildKit 构建，`harbor-auth` 推镜像 | 构建并推送 |
| Task `deeptutor-update-gitops` | cicd | 改 gitops 仓 kustomization.yaml 的 newTag，push | 更新期望状态 |
| PipelineRun `deeptutor-cicd-ptv57` | cicd | 实测成功，4 TaskRun 完成，耗时约 22 分钟 | 一次真实执行记录 |

### 7. GitOps 同步层（webhook 链路的终点）

| 资源 | 命名空间 | 实测配置 | 作用 |
|---|---|---|---|
| Application `deeptutor` | argocd | source `http://192.168.67.201/deeptutor/deeptutor-gitops.git`，path `overlays/prod`，automated sync | 监听 gitops 仓变化并同步部署 |
| Secret `deeptutor-repo-secret` | argocd | repository secret，url 指向 deeptutor-gitops.git | ArgoCD 拉 gitops 仓的凭据（给 ArgoCD 自己用） |
| Deployment `deeptutor` | deeptutor | 镜像 `192.168.67.202:8443/deeptutor/deeptutor:6b85abb...` | 最终部署结果 |

## 四、webhook 作为输入的完整数据流（以 deeptutor 为例）

把以上资源串成一条完整链路，每一跳标注"用什么钥匙、访问谁"：

```
开发者 git push 到 deeptutor/deeptutor.git 的 main 分支
  │
  ▼ GitLab 事件触发
GitLab 发送 webhook POST
  │  请求头：X-Gitlab-Event: Push Hook
  │          X-Gitlab-Token: <webhook token>
  │  body：包含 ref / before / after / repository 等
  ▼
Traefik Ingress (deeptutor-el, host: el-deeptutor.internal)
  │
  ▼
EventListener (el-deeptutor-listener)
  │  ① gitlab 拦截器：读 deeptutor-webhook-secret/secretToken，
  │                  与 X-Gitlab-Token 明文比对 + 限定 Push Hook
  │  ② cel 拦截器：过滤 object_kind=push && ref=refs/heads/main
  ▼
TriggerBinding (deeptutor-binding)：提取 git-url / gitrevision / gitbefore
  │
  ▼
TriggerTemplate (deeptutor-template)：生成 PipelineRun
  │
  ▼
PipelineRun (deeptutor-cicd)
  ├─ clone：用 deeptutor-gitlab-auth(username+password) Basic Auth 拉代码
  ├─ check-changes：对比改动，判定 need-build
  ├─ build-push：BuildKit 构建 + harbor-auth 推镜像（tag=commit SHA）
  └─ update-gitops：用 deeptutor-gitlab-auth 改 gitops 仓 newTag 并 push
  │
  ▼ ArgoCD 轮询 gitops 仓（用 deeptutor-repo-secret）
Application deeptutor 自动同步 → 部署到 deeptutor 命名空间
```

**关键点**：webhook 是整个链路的起点和输入。它携带的事件数据经 TriggerBinding 解析后，驱动整条流水线。没有 webhook，就没有自动触发；webhook 的内容不准确，流水线的输入参数就会出错。

## 五、webhook token 工作原理

webhook 链路中最关键的校验环节是 webhook token，这里单独讲清其原理。

### 1. 性质：共享验证密钥，非身份凭据

webhook token（`deeptutor-webhook-secret` 的 `secretToken`）**不授予任何权限，不能调用任何 API**。它的本质是 GitLab 与接收方之间的**共享验证密钥**，唯一作用是验证 webhook 请求确实来自 GitLab。

它与 API token 有本质区别：

| | webhook token | API token |
|---|---|---|
| 作用 | 验证请求来源（明文比对） | 证明调用者身份（带 scope） |
| 是否授予权限 | 否 | 是（按 scope） |
| 传输方式 | `X-Gitlab-Token` 请求头 | `PRIVATE-TOKEN` 请求头 |
| 泄露后果 | 可伪造 webhook 触发构建 | 可按 scope 调用 API |

### 2. 工作方式：明文字符串比较

GitLab 发送 webhook 时，把配置的 Secret token 放在 `X-Gitlab-Token` 请求头里。集群侧的 `gitlab` 拦截器从 Secret 读出 `secretToken`，与请求头做**明文字符串相等比较**。

注意：这是**明文比较，不是 HMAC 签名**。HMAC-SHA256 是 GitHub webhook 的做法，GitLab 用的是明文 token 比对。

### 3. 实测验证

以本集群 deeptutor 为例（webhook token 长度 32 字符）：

| 测试场景 | HTTP 响应 | 是否触发 PipelineRun |
|---|---|---|
| 无 token | 202 | 否（拦截器拒绝） |
| 错误 token | 202 | 否（拦截器拒绝） |
| 正确 token + Push Hook + main 分支 | 202 | **是**（PipelineRun 数量增加） |
| 正确 token + Push Hook + 非 main 分支 | 202 | 否（CEL 拦截器丢弃） |

**重要提醒**：Tekton 的 EventListener 在拦截器校验失败时，HTTP 仍返回 **202**。**202 只代表 EL 收到了请求，不代表校验通过或触发成功**。排查时必须检查是否有新 PipelineRun 产生及其状态，不能只看 HTTP 状态码。

### 4. 安全边界

因为是明文比较，webhook token 防的是"不知道 token 的随机伪造"，**防不了"知道 token 的定向伪造"**——知道 token 的人可以构造任意 payload 触发构建。因此链路后端的 `check-changes`、CEL 过滤等逻辑也是必要的兜底。

## 六、集群中 webhook 相关资源的速查总表

| 类别 | 资源 | 命名空间 | 一句话作用 |
|---|---|---|---|
| 入口 | Ingress `deeptutor-el` | cicd | webhook 请求路由入口 |
| 接收 | EventListener `deeptutor-listener` | cicd | 接收 webhook，挂拦截器 |
| 端点 | Service `el-deeptutor-listener` | cicd | EL 的 Service 端点 |
| 校验 | ClusterInterceptor `gitlab` | 集群级 | 明文比对 webhook token + 限定事件类型 |
| 校验 | ClusterInterceptor `cel` | 集群级 | 按 body 内容过滤（仅 main 分支 push） |
| 密钥 | Secret `deeptutor-webhook-secret` | cicd | 存放 webhook 校验用的 secretToken |
| 解析 | TriggerBinding `deeptutor-binding` | cicd | 从 webhook body 提取输入参数 |
| 组装 | TriggerTemplate `deeptutor-template` | cicd | 把参数组装成 PipelineRun |
| 执行 | Pipeline `deeptutor-cicd` | cicd | 定义 CI/CD 流程 |
| 执行 | PipelineRun `deeptutor-cicd-*` | cicd | 每次触发的实际执行记录 |
| Git 凭据 | Secret `deeptutor-gitlab-auth` | cicd | clone/push 用的 Basic Auth |
| 镜像凭据 | Secret `harbor-auth` | cicd | 推镜像到 Harbor |
| GitOps | Application `deeptutor` | argocd | 监听 gitops 仓自动同步 |
| GitOps | Secret `deeptutor-repo-secret` | argocd | ArgoCD 拉 gitops 仓的凭据 |

## 七、小结

1. **webhook 是 CI/CD 的输入信息**：它是事件源（GitLab）向接收方（集群）推送的事件通知与数据载体，没有 webhook 就没有自动触发，webhook body 的内容直接构成流水线的输入参数。

2. **集群中 webhook 链路由多层资源协作承载**：从 Ingress 入口 → EventListener 接收 → 拦截器校验 → TriggerBinding 解析 → TriggerTemplate 组装 → PipelineRun 执行 → GitOps 同步，每一层有对应的 K8s 资源。

3. **webhook token 是共享验证密钥**：通过明文比对 `X-Gitlab-Token` 请求头来验证请求来源，不授予任何权限，与 API token 性质不同。校验失败时 HTTP 仍返回 202，需以 PipelineRun 实际状态为准。

4. **整条链路各用一把钥匙**：webhook token 验来源、git 凭据读写代码、Harbor 凭据推镜像、ArgoCD 凭据拉配置，互不通用。
