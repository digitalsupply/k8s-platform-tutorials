# 22 · 从 `git push` 到上线的 CI/CD 全链路详解

> **日期**：2026-10-18
> **范围**：代码仓 `git push` → GitLab webhook → Tekton Triggers → Tekton Pipeline（BuildKit 构建）→ Harbor → GitOps 仓 → ArgoCD → K8s 滚动发布。
> **口径**：以**运行中集群的实态**为准 —— Tekton Pipelines `v1.6.0`、Triggers `v0.34.0`、ArgoCD `v3.5.3`、Traefik（MetalLB）`10.0.0.252`。
> **姊妹文档**：`docs/20`（架构分析与改进建议）、`docs/21`（直连 webhook + 隧道退休纪要）、`docs/02`（CI/CD 运维手册）、`docs/01`（全过程实录）。

---

## 一、一张图看懂全链路

```
 ┌────────────┐  git push（HTTPS）      ┌────────────────────────────────────┐
 │ 开发者/CI   │ ───────────────────────▶│ GitLab 192.168.67.201              │
 └────────────┘                         │  digitalsupply/compassio（代码仓）  │
                                        │  digitalsupply/compassio-gitops（部署仓）│
                                        └───────────────┬────────────────────┘
                                                        │ project webhook: http://ci-compassio.xyz/
                                                        │ (X-Gitlab-Event: Push Hook, X-Gitlab-Token)
                                                        │ 网络：/etc/hosts → 10.0.0.252（内网 via 192.168.67.156）
                                                        ▼
                                        ┌────────────────────────────────────┐
                                        │ Traefik LoadBalancer 10.0.0.252 :80 │
                                        │   Ingress ci-compassio.xyz → svc     │
                                        │   el-compassio-listener:8080         │
                                        └───────────────┬────────────────────┘
                                                        ▼  ns=cicd
   ┌────────────────────────────────────────────────────────────────────────────────┐
   │ EventListener compassio-listener（controller 托管 ClusterIP 8080/9000）         │
   │   ① gitlab ClusterInterceptor：校验 X-Gitlab-Token + 仅 Push Hook               │
   │   ② TriggerBinding compassio-binding：checkout_sha / repository.git_http_url     │
   │   ③ TriggerTemplate compassio-template：渲染 PipelineRun                        │
   │        compassio-triggered-<随机后缀>                                            │
   └───────────────────────────────────┬────────────────────────────────────────────┘
                                       ▼
   ┌────────────────────────────────────────────────────────────────────────────────┐
   │ Pipeline compassio-cicd（SA=pipeline，workspace=shared-workspace，PVC nfs-sc 256Mi）│
   │                                                                                │
   │   clone(git-clone) ──┬──▶ build-push-backend  ┐                                 │
   │                      └──▶ build-push-frontend ┤ 并行                            │
   │                                               ▼                                 │
   │                            promote-gitops（runAfter 两个构建）                    │
   └────────────────────────────────────────────────────────────────────────────────┘
        │ build-push-*                                    │ promote-gitops
        │ buildctl → buildkitd.cicd.svc:1234              │ git clone compassio-gitops
        ▼                                                 │ sed 改 newTag → commit & push
   ┌───────────────────────────────┐                      ▼
   │ Harbor 192.168.67.202:8443    │            ┌───────────────────────────────────┐
   │  compassio/backend  :<SHA>    │            │ compassio-gitops / overlays/prod   │
   │  compassio/frontend :<SHA>    │            │   images.newTag = <SHA>            │
   │  auto_scan(Trivy)             │            └───────────────┬───────────────────┘
   └───────────────────────────────┘                            │ ArgoCD 轮询/Webhook 发现变更
                                                                ▼
                                     ┌────────────────────────────────────────────────┐
                                     │ ArgoCD Application compassio                    │
                                     │   repo=gitops  path=overlays/prod  target=main  │
                                     │   automated{prune:false, selfHeal:true}         │
                                     │   → kustomize build → diff → apply              │
                                     └───────────────┬────────────────────────────────┘
                                                     ▼
                       ns=compassio：backend×2 + frontend×2
                       （Deployment 滚动更新 → 探针就绪 → Service/Ingress 切流）
```

---

## 二、设计哲学（三条主线）

1. **推(Push)与拉(Pull)分离——CI 出物、CD 收敛**
   CI **只做两件事**：把代码编译成不可变镜像、把镜像 tag 写进部署仓。CI **从不** `kubectl apply`。
   真正改变集群的是 ArgoCD 持续把「部署仓的期望状态」拉平到集群。好处：发布动作 = 一次可审计的 git commit；集群状态可从 git 完全重建。
2. **不可变 tag——`image-tag = commit SHA`**
   每次提交产生 40 位 SHA 作为镜像 tag，天然可追溯/可回滚/防 `latest` 漂移。部署仓里的 `newTag` 就是「当前线上跑的是哪次提交」。
3. **关注点分离——代码仓 ≠ 部署仓**
   `compassio`（应用代码）与 `compassio-gitops`（部署期望状态）是两个仓。代码仓的变化**不直接**影响线上；只有 GitOps 仓的变更才会被 ArgoCD 应用到集群。这条隔离线是整套体系的"安全阀"。

---

## 三、组件与角色清单

| # | 组件 | 版本/地址 | 在链路中的职责 | 配置出处 |
|---|---|---|---|---|
| 1 | **GitLab** | 192.168.67.201（自建 omnibus） | 代码托管 + 触发 webhook | 私有仓 |
| 2 | **项目 Webhook** | `http://ci-compassio.xyz/` | push 时向 EL 投递事件 | GitLab 项目设置 + `cicd/` |
| 3 | **Traefik** | LoadBalancer `10.0.0.252` | 七层入口，路由 `ci-compassio.xyz` | 集群 IngressClass `traefik` |
| 4 | **Ingress** `compassio-el` | host `ci-compassio.xyz` | → `el-compassio-listener:8080` | `cicd/04-eventlistener.yaml` |
| 5 | **EventListener** `compassio-listener` | Triggers `v0.34.0` | 接收 HTTP、跑拦截器、按触发器分发 | `cicd/04-eventlistener.yaml` |
| 6 | **ClusterInterceptor** `gitlab` | core-interceptors | 校验 token / 事件类型 | 集群内建 + EL 引用 |
| 7 | **TriggerBinding** `compassio-binding` | v1beta1 | 从 body 抽取字段 | `cicd/03-trigger.yaml` |
| 8 | **TriggerTemplate** `compassio-template` | v1beta1 | 渲染 PipelineRun（含 pod 模板/PVC） | `cicd/03-trigger.yaml` |
| 9 | **Pipeline** `compassio-cicd` | `tekton.dev/v1` | 编排 clone→build×2→promote | `cicd/02-pipeline.yaml` |
| 10 | **Task** `git-clone` | alpine/git:v2.45.2 | 克隆代码到 workspace | 集群已装（label: openwebui-cicd） |
| 11 | **Task** `compassio-build-push` | BuildKit client | 构建并推 Harbor | `cicd/01-tasks.yaml` |
| 12 | **Task** `compassio-update-gitops` | alpine/git | 改 tag、提交部署仓 | `cicd/01-tasks.yaml` |
| 13 | **BuildKit daemon** `buildkitd` | `v0.20.2-rootless`，TCP 1234 | 无守护 docker 的镜像构建引擎 | `cicd/06-buildkit.yaml` |
| 14 | **Harbor** | 192.168.67.202:8443（自签证书） | 镜像仓 + Trivy 扫描 | 集群外部 |
| 15 | **GitOps 仓** `compassio-gitops` | Kustomize base+overlay | 部署期望状态（唯一真源） | 私有仓 |
| 16 | **ArgoCD** | `v3.5.3`，ns=`argocd` | 拉取部署仓并收敛集群 | `cicd/05-argocd-application.yaml` |
| 17 | **业务命名空间** `compassio` | CNPG + Redis + backend×2 + frontend×2 | 最终运行态 | `deploy/k8s`（种子） |

> **命名空间边界**：CI 的一切（EL/Pipeline/Task/BuildKit/凭据）在 `cicd`；业务在 `compassio`；ArgoCD 在 `argocd`。三层各自独立，互不越权。

---

## 四、逐步流转（Step 0 → 11）

> 每一步统一按 **发生什么 / 原理 / 配置出处 / 怎么验证** 四段讲。

### Step 0 — 开发者 `git push`

- **发生什么**：开发者向 `http://192.168.67.201/digitalsupply/compassio.git` 的 `main` 推提交。
- **原理**：这是**唯一**的人工入口。之后一切都是自动的。推送的 `HEAD` 提交 SHA（如 `c9344111af14c7b1dd5e2ba210cc6d6b249418ed`）将作为镜像 tag 贯穿全链路。
- **验证**：`git log --oneline -1`。

### Step 1 — GitLab 接收 push 并投递 webhook

- **发生什么**：GitLab 收到 push，匹配项目 Webhook（Push events），由后台 `WebHookWorker` 出站 HTTP POST 到 `http://ci-compassio.xyz/`。
- **原理**：
  - GitLab 会带 **`X-Gitlab-Event: Push Hook`** 和 **`X-Gitlab-Token: <redacted>`** 两个头；后者就是 EL 侧校验来源的依据。
  - **私网目标必须放行**：`ci-compassio.xyz` 解析到 `10.0.0.252`（RFC1918），GitLab 默认会**拒绝**向本地网络投递（报 `URL is blocked: Requests to the local network are not allowed`）。必须保持全局设置 `allow_local_requests_from_hooks_and_services = true`。
  - **Sidekiq 缓存坑**：改完该设置后，Sidekiq/WebHookWorker 可能短时缓存旧值，紧接着的一两次 push 仍会被拦；等缓存过期即恢复（API 的 `resend` 不受此影响）。
- **配置出处**：GitLab 全局设置（API）+ 项目 Webhook。命令见 `docs/02 §四`。
- **验证**：项目 → Settings → Webhooks → 最近交付记录（`response_status` 应为 `202`）。

### Step 2 — 网络路径：GitLab → 集群入口

- **发生什么**：出站流量按 GitLab 主机的路由表把 `10.0.0.252` 送到正确的下一跳。
- **原理**：
  - `/etc/hosts`：`10.0.0.252 ci-compassio.xyz`（免 DNS）。
  - 静态路由：`10.0.0.0/24 via 192.168.67.156 dev eth0`（main 表）+ `ip rule to 10.0.0.0/24 lookup main priority 5265`。
  - **关键坑**：下一跳是 **`.156`**，不是默认网关 **`.1`**；`.1` 会黑洞（`curl` 返回 `000`）。
  - 规则 `5265` 优先级高于 Tailscale 的 `5270`，且**只匹配 `10.0.0.0/24`**，因此不影响 Tailscale 的 peer 流量（100.x）——两者不冲突。
  - 持久化于 systemd `k8s-internal-route.service`。
- **验证**：`ip route get 10.0.0.252` → `via 192.168.67.156 dev eth0`。

### Step 3 — Traefik / Ingress 路由

- **发生什么**：Traefik（MetalLB 分配的 `10.0.0.252:80`）按 Host 头 `ci-compassio.xyz` 命中 Ingress `compassio-el`，转发到 Service `el-compassio-listener:8080`。
- **原理**：EL 由 triggers controller 管理；controller 会为它**自动创建一个 ClusterIP Service**（端口 `8080` 数据面、`9000` 指标）。Ingress 只暴露 `8080`。
  - ⚠️ **不要手工声明同名 Service**：否则 controller 报 `services "el-compassio-listener" already exists` → reconcile 失败 → **EL 的 spec（含 interceptor）永远不下发**，webhook 停留在旧行为（这是本项目踩过的坑，详见 `docs/21`）。
- **配置出处**：`cicd/04-eventlistener.yaml`（Ingress 段）。
- **验证**：`kubectl get eventlistener compassio-listener -n cicd` 的 `Service / Ready` 条件须为 `True`。

### Step 4 — EventListener 受理 + Interceptor 校验

- **发生什么**：EL 的 sink 接收到 POST，先跑 `gitlab` ClusterInterceptor，再进入触发器处理。
- **原理**：
  - Interceptor 读取 `secretRef`（`cicd/gitlab-webhook-secret` 的 `secretToken`），要求请求头 `X-Gitlab-Token` 与其相等；`eventTypes` 白名单只放行 `Push Hook`。
  - **重要语义**：Tekton 的 HTTP sink **无论事件是否被拦截，都返回 `202 Accepted`**。因此 **`202` ≠ 触发成功**——排查时不能只看状态码，要看是否真的产生了 PipelineRun。
  - Interceptor 运行在 `tekton-triggers-core-interceptors`；被丢弃时可到该组件日志看 `Continue:false`。
- **配置出处**：`cicd/04-eventlistener.yaml`（`interceptors` 段）。
- **验证**：
  ```bash
  # 会被拦（token 错）但仍返回 202 —— 证明确实是"拦截生效"而非"没通"
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'X-Gitlab-Event: Push Hook' -H 'X-Gitlab-Token: <redacted>' \
    http://ci-compassio.xyz/
  # 看是否真的产生了 PipelineRun
  kubectl get pipelinerun -n cicd --sort-by=.metadata.creationTimestamp | tail
  ```

### Step 5 — TriggerBinding → TriggerTemplate → PipelineRun

- **发生什么**：
  1. **Binding** 从 webhook body 抽取两个字段 → `gitrevision = body.checkout_sha`、`gitrepositoryurl = body.repository.git_http_url`。
  2. **Template** 用这两个参数渲染出一个 **PipelineRun**，名字前缀 `compassio-triggered-`（`generateName` 自动补随机后缀）。
- **原理**：
  - Template 里 `$(tt.params.gitrevision)` 即提交 SHA，被同时用作 **`git-revision`（clone 哪个提交）** 和 **`image-tag`（镜像打什么 tag）** —— 这就是"tag = SHA"的落点。
  - **pod 模板**：`taskRunTemplate` 指定了运行 CI pod 的关键约束 —— `serviceAccountName: pipeline`、`nodeSelector: kubernetes.io/hostname: worker03`、容忍 control-plane 污点、`imagePullSecrets: harbor-auth`。
  - **workspace**：`volumeClaimTemplate` 声明一块 `256Mi` 的 `nfs-sc`（`ReadWriteOnce`）PVC，`shared-workspace` 名字把它绑给整条 Pipeline 的各个 Task，实现**跨 Task 共享文件**（clone 下来的源码、以及后续 promote 用的 git 目录）。
  - ⚠️ **`nodeSelector: worker03` 是当前的脆弱点**：worker03 一旦出现 `node.kubernetes.io/disk-pressure:NoSchedule` 污点，`promote-gitops` 会卡 `Pending`（见 `docs/20 §六-6`）。
- **配置出处**：`cicd/03-trigger.yaml`。
- **验证**：
  ```bash
  kubectl get pipelinerun -n cicd -o yaml | grep -A3 'compassio.cicd/commit'
  ```

### Step 6 — Tekton 解析 Pipeline，展开 TaskRun 拓扑

- **发生什么**：PipelineRun 引用 `Pipeline compassio-cicd`，controller 按 `runAfter` 展开为四个 TaskRun：
  ```
  clone ──▶ build-push-backend  ──┐
        └─▶ build-push-frontend ──┴─▶ promote-gitops
  ```
- **原理**：
  - 两个 `build-push-*` 只有 `runAfter: [clone]`，彼此**无依赖 → 并行**；`promote-gitops` 依赖两者都完成 → **串行收尾**。
  - 每个 TaskRun 起一个 Pod，按 Step 顺序执行；所有 Pod 共享同一个 `shared-workspace` PVC。
- **配置出处**：`cicd/02-pipeline.yaml`。
- **验证**：`kubectl get taskrun -n cicd | grep <pipelinerun>`。

### Step 7 — `clone`：拉源码到 workspace

- **发生什么**：`git-clone` Task 把代码仓在指定 revision（=push 的 SHA）克隆进 `shared-workspace/source`。
- **原理**：这是一次**普通 git 拉取**（不需要 Harbor）；用到的镜像 `alpine/git:v2.45.2` 由 `imagePullSecrets: harbor-auth` 从 Harbor 拉取。
- **验证**：`kubectl logs -n cicd <taskrun>-clone-pod -c step-clone`（耗时通常 <10s）。

### Step 8 — `build-push-*`：BuildKit 构建并推送 Harbor

- **发生什么**：两个 Task 分别以 `source/backend`、`source/frontend` 为 context，用 `buildctl` 让集群内的 `buildkitd` 构建镜像，并 `push` 到 Harbor。
- **原理（本项目的核心工程点）**：
  - **无 Docker daemon**：`buildctl` 只是客户端，真正的构建发生在 `buildkitd`（`tcp://buildkitd.cicd.svc.cluster.local:1234`）。镜像名：`192.168.67.202:8443/compassio/{backend,frontend}:<SHA>`。
  - **凭据流**：Task 把 Secret `harbor-auth`（`.dockerconfigjson`）挂成 `/root/.docker/config.json`，并以 `DOCKER_CONFIG=/root/.docker` 指路 → `buildctl push` 用该凭据登录 Harbor。
  - **TLS 校验（已恢复）**：输出不再带 `registry.insecure`。但必须给**客户端**注入 Harbor CA：脚本先把系统 CA 与 `harbor-ca` 合并，再 `export SSL_CERT_FILE` —— 因为 `buildctl` 客户端自己会做 registry token 交换（2026-10-14~10-20 就是卡在这一点，详见 `docs/23`）。
  - **内联缓存**：`--export-cache type=inline` 把缓存元数据写进镜像；配合 buildkitd 侧配置。
  - **基础镜像走镜像源**：`buildkitd.toml` 把 `docker.io` 映射到 `docker.1ms.run` 与华为 SWR 代理（本环境无 Docker Hub 直连）；Harbor 域配了 CA bundle（initContainer 拼装）。
  - **rootless daemon + 非 root 客户端**：daemon 以 `runAsNonRoot`（group 1000）+ `seccompProfile: Unconfined` 跑 —— **`RuntimeDefault` 实测不兼容**（rootlesskit 报 `fork/exec /proc/self/exe: operation not permitted`）；Task 已改用镜像默认 uid 1000（原 `runAsUser: 0` 已去掉）。
  - **持久缓存**：daemon 的 `home` 卷是 hostPath `/var/lib/buildkitd-cache`（m01），跨 Pod 重启保留；NFS/Ceph 因 rootless `lchown` / m01 缺 RBD CSI 不可用（见 `docs/23`）。
- **配置出处**：`cicd/01-tasks.yaml`（`compassio-build-push`）、`cicd/06-buildkit.yaml`。
- **验证**：
  ```bash
  kubectl logs -n cicd <taskrun>-build-push-backend-pod -c step-build   # 末尾 "Pushed image: ..."
  curl -sk https://192.168.67.202:8443/api/v2.0/projects/compassio/repositories | head
  ```

### Step 9 — `promote-gitops`：把 tag 写进部署仓

- **发生什么**：克隆 `compassio-gitops` → `sed` 改写 `overlays/prod/kustomization.yaml` 里**所有** `newTag:` → commit → `git push origin HEAD:main`。
- **原理**：
  - **这就是"发布"这个动作**：把「线上应该跑 `<SHA>`」写成一次可审计的 git commit（提交信息形如 `ci(compassio): promote image tag <SHA>`）。
  - **幂等保护**：`git diff --quiet` 命中（tag 没变）就直接 `exit 0`，不产生空提交。
  - **凭据**：复用 `cicd/gitlab-auth` 的 username/password（PAT）；gitops URL 是 Task 参数，不写死进 Secret。
  - ⚠️ **并发/全量替换风险**：`sed` 一次性重写**所有** `newTag`，且 `git pull --ff-only + push HEAD:main` 在两次快速 push 并发时，后到者会 non-fast-forward 失败（见 `docs/20 §六-5/P1`）。
- **配置出处**：`cicd/01-tasks.yaml`（`compassio-update-gitops`）。
- **验证**：`git -C <gitops> log --oneline -1` 应出现 `promote image tag <SHA>`。

### Step 10 — ArgoCD 发现变更并收敛

- **发生什么**：ArgoCD 监测到 `compassio-gitops` 的 `main` 变化（默认轮询 + 可配 webhook），对 Application `compassio` 做一次同步：`kustomize build overlays/prod` → 与集群现况 diff → apply。
- **原理**：
  - Application 定义：`repoURL=…/compassio-gitops.git`、`targetRevision=main`、`path=overlays/prod`、目标 `namespace=compassio`、`server=https://kubernetes.default.svc`。
  - **`syncPolicy.automated`**：`selfHeal:true`（集群被手改会自愈回 git 态）、`prune:false`（**删除 git 中的资源不会联动删除集群对象**——有意保护 CNPG/Redis 等有状态资源）、`CreateNamespace=true`。
  - **Kustomize 的作用**：overlay 用 `images[].newTag` 把 base 里的镜像 tag 替换成 `<SHA>`，并用 JSON patch 把 backend/frontend 副本数改成 2。**CI 改的就是这个 `newTag`。**
  - **真源提醒**：ArgoCD 盯的是**部署仓** `compassio-gitops`；本代码仓里的 `deploy/k8s` 只是**种子/模板**。二者并不完全等同（部署仓还多出 `06-frpc.yaml`、`secret-patch.yaml` 等），以部署仓为准。
- **配置出处**：`cicd/05-argocd-application.yaml`、`compassio-gitops/overlays/prod/kustomization.yaml`。
- **验证**：`kubectl get application compassio -n argocd` → `Synced / Healthy`，`status.sync.revision` = 最新 gitops commit。

### Step 11 — K8s 滚动发布

- **发生什么**：新的 backend/frontend Deployment 被 apply，触发滚动更新：起新 ReplicaSet → 等 readiness 探针通过 → 逐步替换旧 Pod → 更新 Service endpoints → Ingress 继续对外。
- **原理**：
  - backend 探针：`/api/health`（readiness）、`/api/health/live`（liveness）；frontend：`/`。
  - 有资源 requests/limits；frontend 通过 `BACKEND_HOST=compassio-backend` 注入 nginx 上游。
  - 对外入口仍是 `compassio.xyz` → `compassio-frontend:80`，与 CI 的 `ci-compassio.xyz` 是**两条独立 Ingress**。
- **验证**：`kubectl -n compassio rollout status deploy/compassio-backend`；`kubectl -n compassio get pods`。

---

### 4.5 小结：声明与实例（Binding / Template / PipelineRun 与 Pipeline / Task）

把 Step 5–6 那两步抽象出来看，整条链路就是一条"**取数 → 填模板 → 生成实例 → 展开子任务**"的数据流：

```text
GitLab POST 的 JSON body
  │ ① TriggerBinding「compassio-binding」：用 $(body.*) 从事件里抽字段
  ▼ 输出一组 params
      gitrevision      = body.checkout_sha
      gitrepositoryurl = body.repository.git_http_url
  │ ② TriggerTemplate「compassio-template」：spec.params 接收，resourcetemplates 渲染
  ▼
PipelineRun「compassio-triggered-<id>」   ← 真实对象，交由 controller 执行
  └─ ③ 展开为 TaskRun × 4 → Pod × 4
```

**① `TriggerBinding`（取数，ns 级）**
```yaml
spec.params:
  - { name: gitrevision,      value: "$(body.checkout_sha)" }
  - { name: gitrepositoryurl, value: "$(body.repository.git_http_url)" }
```
- `$(body.*)` 是**事件 JSON 路径表达式**；多个 binding 的输出会**合并**成一份 params。
- **解耦点**：把"GitLab 私有的事件结构"翻译成"平台无关参数"（换 GitHub 只需改这一层）。

**② `TriggerTemplate`（模板，ns 级）**
```yaml
spec:
  params:                                  # 声明"接受哪些入参"，名字要与 binding 输出对上
    - { name: gitrevision, default: main }
    - { name: gitrepositoryurl }
  resourcetemplates:                       # 要创建的资源模板（可多个、可为任意 K8s 资源）
    - kind: PipelineRun
      metadata: { generateName: compassio-triggered- }
      spec:
        params:
          - { name: git-url,      value: "$(tt.params.gitrepositoryurl)" }
          - { name: git-revision, value: "$(tt.params.gitrevision)" }
          - { name: image-tag,    value: "$(tt.params.gitrevision)" }   # ★ tag = 同一个 SHA
        pipelineRef: { name: compassio-cicd }
```
- `$(tt.params.*)` = 模板变量（与 `$(body.*)` 是**两套**表达式，勿混）。
- **"clone 哪个提交"与"镜像打什么 tag"共用同一个 SHA** —— 这就是"tag = commit SHA"的落点。

**③ `PipelineRun`（实例）** —— 实测 `compassio-triggered-bq7zk`：
```yaml
metadata:
  labels:
    compassio.cicd/commit: 0033a6594409ddd324b555e112bf893a04b67539
    tekton.dev/pipeline: compassio-cicd
    triggers.tekton.dev/eventlistener: compassio-listener      # ← 证明"由 trigger 创建"
    triggers.tekton.dev/trigger: gitlab-push
spec:
  params: [ {name: git-url, value: http://192.168.67.201/…}, {name: git-revision, value: 0033a659…}, {name: image-tag, value: 0033a659…} ]
  pipelineRef: { name: compassio-cicd }
  taskRunTemplate: { serviceAccountName: pipeline, podTemplate: { nodeSelector: worker03 } }
  workspaces: [ { name: shared-workspace, volumeClaimTemplate: { 256Mi nfs-sc } } ]
```
> `triggers.tekton.dev/*` 标签是**判据**：有=trigger 建的；没有=有人手工 `kubectl create` 的。

**对接点：全靠"名字逐字相同"，无静态校验**

| 握手 | 靠的字段 | 本集群值 |
|---|---|---|
| EL → Binding | `triggers[].bindings[].ref` | `compassio-binding` |
| EL → Template | `triggers[].template.ref` | `compassio-template` |
| **Binding 输出 → Template 入参** | **参数名一致** | `gitrevision` / `gitrepositoryurl` |
| Template → PipelineRun | `resourcetemplates[].spec.pipelineRef.name` | `compassio-cicd` |
| PipelineRun 参数 → Pipeline 参数 | `spec.params[].name` 两边一致 | `git-url` / `git-revision` / `image-tag` |
| workspace 传递 | `workspaces[].name` | `shared-workspace` |

**`Pipeline` vs `PipelineRun`**：**一个是定义，一个是执行**

| 维度 | `Pipeline` | `PipelineRun` |
|---|---|---|
| 是什么 | 流程**定义**（Task 列表、依赖、参数/workspace 声明）| 该 Pipeline 的**一次运行实例** |
| 类比 | 类 / 函数定义 / 剧本 | 对象 / 函数调用 / 一场演出 |
| 生命周期 | 长期存在（apply 后不变）| 跑完即终态，作为记录留存（可删）|
| 谁创建 | 人工 / ArgoCD apply | **Trigger 渲染创建**（本项目）；也可 `tkn`/`kubectl` 补跑 |
| 关键字段 | `spec.params` / `spec.tasks` / `spec.workspaces` | `spec.pipelineRef` / `spec.params` / `spec.workspaces` / `spec.taskRunTemplate` |
| 运行状态 | ❌ | ✅ `status.conditions`（Succeeded/Failed）+ 子 TaskRun |

**层级关系（本项目）**
```text
PipelineRun compassio-triggered-bq7zk     ← 一次执行（每次 push 新建）
  ├─ Pipeline compassio-cicd              ← 定义（pipelineRef 指向它，长期不变）
  ├─ params: git-revision=0033a659…        ← 本次具体值
  └─ TaskRun × 4                           ← 每个 Task 一次执行
        clone / build-push-backend / build-push-frontend / promote-gitops
        └─ 每个 TaskRun 起一个 Pod（step 容器） ← 真正干活
```
> 同一逻辑也适用于 **`Task` ⇄ `TaskRun`**：Pipeline 里写 `taskRef: compassio-build-push`（定义），运行时生成 `TaskRun …-build-push-backend`（实例），TaskRun 再起 Pod。

**为什么拆这么多层**：Binding 吸收「事件源差异」，Template 吸收「建什么/怎么建」，Pipeline 只描述「怎么构建」→ 与"谁触发"无关，故既能被 trigger 自动化跑，也能 `tkn` 手工补跑。

**坑**
- 参数名靠字符串匹配，写错**运行时**才报错（`params not found` / `missing params`）。
- 混用 `$(body.*)` 与 `$(tt.params.*)`。
- Template 用 `generateName`（唯一），PipelineRun 传参名须与 Pipeline 的 `spec.params[].name` 一致。
- 每次 run 新建一块 `pvc-*`（`volumeClaimTemplate`）会长期堆积。

```bash
kubectl get triggerbinding,triggertemplate -n cicd -o yaml
kubectl get pipeline compassio-cicd -n cicd -o yaml
kubectl describe pipelinerun <name> -n cicd
kubectl get pipelinerun <name> -n cicd -o jsonpath='{.metadata.labels}{"\n"}{.spec.params}{"\n"}'
```

---

### 4.6 从定义到执行：Pipeline / Task 如何实例化为 TaskRun

**先精确定义**（补上 TaskRun/Pod 这两个"执行态"）：

| 对象 | 本质 | 说明 |
|---|---|---|
| `Task` | 任务的**蓝图** | `spec.steps`（容器步骤）+ `params`/`workspaces` 声明 |
| `Pipeline` | 流水线的**编排模板** | `spec.tasks[]` 每项 = **pipelineTask 名** + `taskRef`（用哪个 Task）+ `runAfter`（依赖）+ params/workspace **映射** |
| `PipelineRun` | **一次执行实例** | 绑定 `pipelineRef` + 本次 `params` + `workspaces` + `taskRunTemplate`；"某 commit"是通过 params 绑进去的 |
| `TaskRun` | **Pipeline 里一个 task 条目的一次执行**（不是"Task 的一次执行"）| 由 controller 按条目创建 |
| `Pod` | TaskRun 的**执行载体** | 每个 Step → 一个容器 `step-<name>` |

**谁负责"落到 TaskRun"**：不是 Trigger、也不是 Task，而是 **`tekton-pipelines-controller`**：

```text
PipelineRun 创建
   │ controller 读 spec.pipelineRef → 取 Pipeline 的 spec
   ▼
按 spec.tasks[].runAfter 建 DAG
   │ 依赖满足时，为每个 task 条目创建 1 个 TaskRun
   ▼
TaskRun 创建
   │ taskruns controller 读 taskRef → 取 Task 的 spec.steps
   ▼
Pod 创建（每个 step → 容器 step-<name>）
```

**① Pipeline 里的 4 个"条目"**（`spec.tasks[]`，本集群实测）：

```text
name=clone                taskRef=git-clone                runAfter=None
name=build-push-backend   taskRef=compassio-build-push      runAfter=[clone]
name=build-push-frontend  taskRef=compassio-build-push      runAfter=[clone]
name=promote-gitops       taskRef=compassio-update-gitops   runAfter=[build-push-backend, build-push-frontend]
```

**② `runAfter` 形成 DAG**

```text
clone ──┬─▶ build-push-backend  ──┐
        └─▶ build-push-frontend ──┴─▶ promote-gitops
```
两个 build 无相互依赖 → **并行**；promote 等两者都成功。

**③ 为每个条目创建 TaskRun —— "具象化"规则**

| TaskRun 字段 | 从哪来（实测）|
|---|---|
| `metadata.name` | `<PipelineRun名>-<pipelineTask名>` → `compassio-triggered-2rhbs-build-push-backend` |
| `metadata.ownerReferences` | → `PipelineRun/compassio-triggered-2rhbs`（删 run 级联删 TaskRun）|
| `metadata.labels` | `tekton.dev/pipelineRun`、`tekton.dev/pipelineTask=build-push-backend`、`tekton.dev/task=compassio-build-push`、`tekton.dev/memberOf=tasks` |
| `spec.taskRef` | 条目的 `taskRef.name` → `compassio-build-push` |
| `spec.params` | 条目 params，**变量被替换为真实值**（见 ④）|
| `spec.workspaces` | Pipeline 的 `shared-workspace` → Task 声明的 `source` → 绑定 PVC |
| `spec.serviceAccountName` / `podTemplate` | 从 PipelineRun 的 `taskRunTemplate` **下传**（`pipeline` / nodeSelector worker03 / harbor-auth）|

**④ 参数替换链（"如何对接"的核心）**

```text
Pipeline 条目:  image: "$(params.image-repository-backend):$(params.image-tag)"
                                        │                        │
PipelineRun:    image-repository-backend = 192.168.67.202:8443/compassio/backend
                image-tag                = 0b7b7ab24bc7e6db0cd782c879b74dbbee4b3c28
                                        ▼
TaskRun:        params.image = 192.168.67.202:8443/compassio/backend:0b7b7ab2…
                                        ▼
Task step:      buildctl … --output type=image,name=$(params.image),push=true
```
> 这里就是"commit → 镜像 tag"真正落地的地方；任务间传值用 `$(tasks.<name>.results.<x>)`。

**⑤ TaskRun → Pod**

```text
TaskRun …-build-push-backend
  status.podName = …-build-push-backend-pod
  status.steps   = [(build, Completed)]
Pod containers   = [step-build]
```
TaskRun 还会把解析后的 Task 快照存进 **`status.taskSpec`**（含 steps/params），便于审计与重放。

**全景图**

```text
Task/compassio-build-push  (蓝图: steps=[build], params=[image,context,dockerfile,cache-repo])
            ▲ taskRef
Pipeline/compassio-cicd    (模板: tasks[].name + taskRef + runAfter)
            ▲ pipelineRef
PipelineRun/…-2rhbs        (一次执行: params git-url/git-revision/image-tag)
            │ controller 按 DAG 逐条实例化
            ▼
TaskRun × 4                (…-clone / …-build-push-backend / …-build-push-frontend / …-promote-gitops)
            │ controller 取 Task.spec.steps
            ▼
Pod × 4                    (容器 step-clone / step-build / step-build / step-patch-and-commit)
```

**四个关键结论**

1. **TaskRun 是"条目级"的**：一个 `Task` 可被多个条目引用 → `compassio-build-push` **一个 Task 生成两个 TaskRun**（backend/frontend）。
2. **TaskRun 不是一次性全建**：只有依赖满足才建 → `promote-gitops` 的 TaskRun 出现最晚。
3. **PipelineRun ≠ Pipeline 快照**：它只存 `pipelineRef` 名 + 本次参数，展开发生在 controller 里；但每个 TaskRun 的 `status.taskSpec` 会有 Task 快照。
4. **ownerReferences 级联链**：`Pod → TaskRun → PipelineRun`；删 PipelineRun 会连带删 TaskRun 与 Pod。

```bash
# Pipeline 的条目与依赖
kubectl get pipeline compassio-cicd -n cicd -o json |
  jq -r '.spec.tasks[] | "\(.name)  ->  \(.taskRef.name)  after=\(.runAfter)"'
# controller 记账：该 run 建了哪些 TaskRun（pipelineTask 一一对应）
kubectl get pipelinerun compassio-triggered-2rhbs -n cicd \
  -o jsonpath='{range .status.childReferences[*]}{.kind}/{.name}  pipelineTask={.pipelineTaskName}{"\n"}{end}'
# TaskRun -> Pod
kubectl get taskrun compassio-triggered-2rhbs-build-push-backend -n cicd \
  -o jsonpath='pod={.status.podName}{"\n"}'
```

---

## 五、各阶段涉及的 K8s 资源与查看命令

> 与 §四 的 Step 一一对应；资源名均为**本集群实态**，`<...>` 为通配。命令在可访问集群的机器（本项目为 m01）执行。

### 5.0 资源分布总览

| 命名空间 | 承载阶段 | 关键资源 |
|---|---|---|
| `cicd` | 触发 + 编排 + 构建 + 凭据 | Ingress/EL/Trigger/Pipeline/Task/BuildKit/PVC/Secret |
| `tekton-pipelines` | Tekton 控制面（集群共享） | 7 个 Deployment（pipelines/triggers 的 controller、webhook、core-interceptors、dashboard） |
| `traefik` | 七层入口 | Deployment/Service `traefik`（LB `10.0.0.252`）、IngressClass `traefik` |
| `argocd` | CD 收敛 | Application `compassio`、`argocd-application-controller`(STS)/`repo-server`/`server`/`redis` |
| `compassio` | 业务运行态 | backend/frontend/redis/pg + Ingress `compassio` |

### 5.1 触发入口阶段（Step 1–4：webhook → Traefik → EL）

| 资源 | 名称 | 作用 |
|---|---|---|
| Ingress | `cicd/compassio-el` | host `ci-compassio.xyz` → svc `el-compassio-listener:8080` |
| Service | `cicd/el-compassio-listener`（ClusterIP `8080`,`9000`）| 入口后端（**由 controller 生成，勿手工建**）|
| Deployment | `cicd/el-compassio-listener` | EL 的 sink 进程（label `eventlistener=compassio-listener`）|
| Pod | `cicd/el-compassio-listener-<rs>-<rand>` | 实际处理 HTTP 请求 |
| EventListener | `cicd/compassio-listener` | 触发器 + interceptor 定义 |
| ClusterInterceptor | `gitlab`（集群级）| 校验 `X-Gitlab-Token` / `Push Hook` |
| TriggerBinding | `cicd/compassio-binding` | 抽取 `checkout_sha` / `git_http_url` |
| TriggerTemplate | `cicd/compassio-template` | 渲染 PipelineRun |
| Secret | `cicd/gitlab-webhook-secret` | interceptor 的 `secretToken` |
| IngressClass / Deployment | `traefik` / `traefik/traefik` | 七层入口与负载均衡地址 `10.0.0.252` |

```bash
# 入口与后端
kubectl get ingress compassio-el -n cicd -o wide
kubectl get svc el-compassio-listener -n cicd -o wide
kubectl get deploy,pods -n cicd -l eventlistener=compassio-listener -o wide
# EL 及其条件（Service/Ready 必须为 True）
kubectl get eventlistener compassio-listener -n cicd -o yaml
kubectl wait --for=condition=Ready eventlistener/compassio-listener -n cicd --timeout=30s
# 触发器对象
kubectl get clusterinterceptor gitlab -o yaml
kubectl get triggerbinding,triggertemplate -n cicd
# 看不到 PipelineRun 时，先看这两个控制面
kubectl logs -n tekton-pipelines deploy/tekton-triggers-controller --tail=80
kubectl logs -n tekton-pipelines deploy/tekton-triggers-core-interceptors --tail=80
# 入口层
kubectl get deploy,svc -n traefik
kubectl get ingressclass
```

#### 5.1.1 EventListener：是「声明」，不是「在跑的东西」

它是一份**触发器清单**，回答三件事：**用哪个身份、收什么事件、怎么处理**。控制器按它**派生**出 `deploy/el-compassio-listener` 与 `svc/el-compassio-listener`（ownerReference 均指回 EL），并以 `--el-name/--el-namespace` 启动 sink，**sink 反过来去 API 读这个 EL** —— 所以改 EL 是**热加载**，不必重启 Pod。

`spec` 字段：

| 字段 | 本集群值 | 含义 |
|---|---|---|
| `serviceAccountName` | `pipeline` | sink pod 的**身份**（决定能读/能建什么）|
| `namespaceSelector: {}` | 空 | 只处理本命名空间（= sink 参数 `--is-multi-ns=false`）|
| `resources: {}` | 空 | 未给 sink 容器设 requests/limits |
| `triggers[].interceptors` | `ClusterInterceptor gitlab` + params | 先跑拦截器（校验 token / 事件类型）|
| `triggers[].bindings` | `compassio-binding` | 再抽参 |
| `triggers[].template` | `compassio-template` | 最后渲染 → 建 PipelineRun |

> **执行顺序固定：`interceptors → bindings → template`**；任一 interceptor 返回 `continue:false` 即中止（但 HTTP 早已返回 202）。

`status` 条件：

| 条件 | 含义 |
|---|---|
| `address.url` | sink 的集群内地址（= Service `:8080`），控制器写回 |
| `Available` / `Progressing` | sink **Deployment** 的可用性 |
| `Deployment` / `Service` | 控制器是否**成功建出**派生物（缺一不可）|
| `Ready` | 上面都 OK 的汇总条件 |
| `configuration.generatedName` | 派生资源名前缀（`el-compassio-listener`）|

> **佐证"改动真的生效"**：本集群 EL 的 `generation: 2`，且 `Ready`/`Service` 的 `lastTransitionTime = 2026-10-18T09:10:51` —— 正是**删掉手工同名 Service、controller 恢复 reconcile** 的时刻（此前卡在 generation 1，interceptor 一直下不去）。

#### 5.1.2 ServiceAccount `pipeline`：复用来的、权限过大的身份

- **复用**：label 为 `app.kubernetes.io/part-of: openwebui-cicd`（openwebui 遗留，`2026-03-15` 创建），compassio 直接借用。
- **一个 SA 两用**：既是 **EL sink pod 的身份**（使 sink 能读配置、建 PipelineRun），也是 **CI Task pod 的身份**（TriggerTemplate 的 `taskRunTemplate.serviceAccountName`）。
- **`imagePullSecrets: [harbor-auth]` 挂在 SA 上**（不在 Pod/Deployment 模板里）：所以 `kubectl get deploy el-compassio-listener -o jsonpath='…imagePullSecrets'` 是空的，但 Pod 照样能从 Harbor 拉私有镜像 —— EL pod 与 CI task pod 都靠它。
- **RBAC 仅一条集群级绑定**：`ClusterRoleBinding/pipeline-edit-binding → ClusterRole/edit`（subject = SA `cicd/pipeline`）。`edit` 是 K8s **聚合默认角色**（`aggregationRule`，Tekton 的 CR 权限借此并入）。
  - 实测该 SA 可**全集群** `create/delete/patch` `pipelineruns/taskruns/pods/configmaps/pvc` 及 triggers 各类 CR。
  - 它**实际只需要**：`get/list/watch` EL/Binding/Template/ClusterInterceptor + `create` PipelineRun（cicd 内）。
  - ⚠️ 属**权限面收敛**待办（与 §6.5 密钥治理、core-interceptors 可读全集群 Secret 同类）。

```bash
kubectl get sa pipeline -n cicd -o yaml
kubectl get clusterrolebinding pipeline-edit-binding -o yaml
kubectl auth can-i --list --as=system:serviceaccount:cicd:pipeline -n cicd | head -30
```

#### 5.1.3 第 2 步的数据流（sink 读配置 → 建 PipelineRun）

```text
EL Pod 里的 sink（SA=pipeline，token 来自 projected 卷）
  │ 用 SA token 调 API server：
  ├─ GET eventlisteners/compassio-listener
  ├─ GET triggerbindings/compassio-binding
  ├─ GET triggertemplates/compassio-template
  └─ GET clusterinterceptors/gitlab            # 拿到 core-interceptors 服务地址 + CA
  │ （interceptor 通过之后）
  └─ CREATE pipelineruns/compassio-triggered-<id>
```

> **webhook Secret 不在这一步读**：EL pod 只挂了 projected 的 `kube-api-access` token 卷，**未挂** `gitlab-webhook-secret`；真正去读该 Secret 的是第 4~5 步的 **core-interceptors**（它有自己的集群级 secrets 读权限）。

#### 5.1.4 RBAC：谁给谁、如何协同、是否自动生成

**先记 5 类对象**（回答"谁 · 给谁 · 什么权限 · 在哪生效"）：

| 对象 | 回答 | 要点 |
|---|---|---|
| Subject | **谁** | `User`/`Group`/`ServiceAccount`（SA 必须写 `namespace/name`）|
| Role | 能做什么（**本 ns**）| 只能被 RoleBinding 引用 |
| ClusterRole | 能做什么（集群级）| 可被 ClusterRoleBinding（全集群）**或** RoleBinding（收窄到单 ns）引用 |
| RoleBinding | 把权限给谁，**仅本 ns** | `roleRef` 可指 Role 或 ClusterRole |
| ClusterRoleBinding | 把权限给谁，**全集群** | `roleRef` 只能指 ClusterRole |

> 铁律：**实际权限 = 命中该 Subject 的所有 binding 的并集**（没有 deny）；**ClusterRoleBinding 一律全集群生效**。

**本链路真实对象**

| SA（身份）| 被谁授权（binding）| 授予的角色 | 范围 |
|---|---|---|---|
| `cicd/pipeline` | `ClusterRoleBinding/pipeline-edit-binding` | `ClusterRole/edit`（聚合）| **全集群** |
| `tekton-pipelines/tekton-triggers-core-interceptors` | `ClusterRoleBinding/tekton-triggers-core-interceptors` | `ClusterRole/tekton-triggers-core-interceptors`（`secrets get/list/watch`）| 全集群读 Secret |
| 同上 | `ClusterRoleBinding/…-secrets` | `ClusterRole/…-secrets` | clusterinterceptors + 自身证书 |
| 同上 | `RoleBinding/…`（ns tekton-pipelines）| `Role/…` | 本 ns |
| `tekton-pipelines/tekton-pipelines-controller` | `ClusterRoleBinding/…-tenant-access` | `ClusterRole/…-tenant-access`（**跨 ns** 建 pods/pvc）| 全集群 |
| 同上 | `ClusterRoleBinding/…-cluster-access` | `ClusterRole/…-cluster-access`（读写 pipelineruns/taskruns）| 全集群 |
| `tekton-pipelines/tekton-triggers-controller` | `ClusterRoleBinding/tekton-triggers-controller-admin` | `ClusterRole/tekton-triggers-admin` | 全集群 |
| （与本链路无关）| `RoleBinding/cicd/openwebui-runner-binding` | `Role/cicd/openwebui-runner-role` | subject 是 **`gitlab-runner/*` 的 SA** |

**协同（一次 push 的时间线）**

```text
① Triggers controller   SA tekton-pipelines/tekton-triggers-controller
     CRB tekton-triggers-controller-admin → ClusterRole tekton-triggers-admin
     → 依据 EL 派生 deploy/svc el-compassio-listener
② EL sink pod           SA cicd/pipeline
     CRB pipeline-edit-binding → ClusterRole edit（全集群）
     → GET EL/Binding/Template/ClusterInterceptor、CREATE PipelineRun
   ├─（interceptor）sink 调 core-interceptors 服务
   │   ③ core-interceptors pod   SA tekton-pipelines/tekton-triggers-core-interceptors
   │        CRB tekton-triggers-core-interceptors → **跨 ns** 读 cicd/gitlab-webhook-secret
④ Pipelines controller  SA tekton-pipelines/tekton-pipelines-controller
     CRB …-tenant-access → 在 **cicd ns** 建 Pod / PVC
⑤ CI Task pod           SA cicd/pipeline（又是它，来自 taskRunTemplate）
```

**"那个 pod"到底是谁**

| 说法 | 实际对象 |
|---|---|
| 拦截器后端 pod | `tekton-pipelines/tekton-triggers-core-interceptors-<rs>-<rand>`（SA `tekton-triggers-core-interceptors`，容器同名）|
| CI task pod | `cicd/compassio-triggered-<id>-{clone,build-push-backend,build-push-frontend,promote-gitops}-pod`（SA `pipeline`，容器 `step-<步名>`，如 `step-build`）|

**这些 RBAC 是自动生成的吗？—— 三种来源，看标签即可判定**

| 对象 | 来源 | 判据 |
|---|---|---|
| `ClusterRole/tekton-triggers-*`、`ClusterRoleBinding/tekton-triggers-*` | **Tekton Triggers 安装清单自带** | label `app.kubernetes.io/part-of=tekton-triggers`、`instance=default` |
| `ClusterRole/tekton-pipelines-*` | **Tekton Pipelines 安装清单自带** | label `part-of=tekton-pipelines` |
| `ClusterRole/edit` | **K8s 自举自带**的默认**聚合**角色 | label `kubernetes.io/bootstrapping=rbac-defaults` + `aggregate-to-admin=true` |
| `ClusterRoleBinding/pipeline-edit-binding` | **人工创建**（非自动）| **无任何 managed-by / part-of 标签** |

> 即：Tekton 的那几条是装 Tekton 时随 `release.yaml`（`kubectl apply`）一起建好的；`edit` 是 K8s 自己的；**唯独把 `edit` 绑给 `cicd/pipeline` 的 `pipeline-edit-binding` 是手动建的** —— 也正是最该收敛的一条。

**坑**
- ClusterRole 与 Role 可同名、两种 Binding 也可同名 → 判断一定看 `roleRef.kind` + `subjects`。
- RoleBinding 引 ClusterRole = 把集群级权限集**收窄到单 ns** 授予（`openwebui-runner-binding` 即此）。
- 权限是并集，且 `automountServiceAccountToken` 默认 true → Pod 自动带 token。
- `cicd/pipeline` 一 SA 两用（sink + task pod）→ **构建 pod 也带全集群 `edit`**（越权面）。

```bash
kubectl auth can-i --list --as=system:serviceaccount:cicd:pipeline -n cicd
kubectl get clusterrolebinding -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name
kubectl get rolebinding -n cicd -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SUBJECTS:.subjects[*].name
kubectl get clusterrole tekton-triggers-core-interceptors -o yaml   # 看 labels 判来源
kubectl get clusterrolebinding pipeline-edit-binding -o yaml        # labels 为空 -> 人工创建
```

> 入口层为何用内置 `Ingress` 而非 Traefik CRD、两者差异与选型，见 **§5.8**。

### 5.2 编排与执行阶段（Step 5–9：PipelineRun → TaskRun → Pod）

| 资源 | 名称 | 作用 |
|---|---|---|
| PipelineRun | `cicd/compassio-triggered-<id>` | 一次触发的实例；label `compassio.cicd/commit=<SHA>` |
| TaskRun | `…-clone` / `…-build-push-backend` / `…-build-push-frontend` / `…-promote-gitops` | 每个 Task 的一次执行 |
| Pod | `<taskrun>-pod` | 执行 step 容器（label `tekton.dev/taskRun=<taskrun>`）|
| Pipeline | `cicd/compassio-cicd` | 编排定义（clone→build×2→promote）|
| Task | `cicd/git-clone`、`compassio-build-push`、`compassio-update-gitops` | 步骤定义 |
| PVC | `cicd/pvc-<hash>`（256Mi `nfs-sc`）| `volumeClaimTemplate` 自动创建，owner=PipelineRun，供 `shared-workspace` |
| ServiceAccount | `cicd/pipeline` | CI pod 身份 |
| ClusterRoleBinding | `pipeline-edit-binding` → ClusterRole `edit` | 授予 `pipeline` 的权限（⚠️ 是**集群级** edit，偏宽）|
| Secret | `cicd/gitlab-auth`、`cicd/harbor-auth` | 拉代码 / 推镜像 |

```bash
# 运行实例
kubectl get pipelinerun -n cicd --sort-by=.metadata.creationTimestamp
kubectl describe pipelinerun <name> -n cicd           # 看 status/conditions/参数
kubectl get taskrun -n cicd | grep <pipelinerun>
# 该 run 的所有 pod（Tekton 标签）
kubectl get pods -n cicd -l tekton.dev/pipelineRun=<name> -o wide
kubectl logs -n cicd <taskrun>-pod -c step-<步名>   # 步名: clone / build / patch-and-commit
# workspace PVC（owner 指向该 run）
kubectl get pvc -n cicd --sort-by=.metadata.creationTimestamp | tail
# 权限
kubectl get clusterrolebinding pipeline-edit-binding -o yaml
```

> **标签速查（Tekton/Triggers 打的）**：`tekton.dev/pipelineRun`、`tekton.dev/pipelineTask`、`tekton.dev/taskRun`、`triggers.tekton.dev/eventlistener`、`triggers.tekton.dev/trigger`、`triggers.tekton.dev/triggers-eventid`。据此可把「事件 → PipelineRun → TaskRun → Pod」一路串起来。

#### 5.2.1 一次 push 到底生成了什么

**① 形态：绝大多数是 API 对象，不是 Pod**

| 对象 | 形态 | 会有 Pod 吗 |
|---|---|---|
| `TriggerBinding` / `TriggerTemplate` | CR（**配置**）| ❌ |
| `Pipeline` / `Task` | CR（**定义**）| ❌ |
| `EventListener` | CR（**声明**）| ✅ 控制器派生出 Deployment → **1 个常驻 sink pod** |
| `PipelineRun` | CR（**运行记录**）| ❌ 不直接 |
| `TaskRun` | CR（**运行记录**）| ✅ **每个 TaskRun 起 1 个 Pod** |
| `Pod` | 真正干活的容器 | ✔ |

> 所以 `compassio-triggered-77tht-*-pod` 这几个 Pod **不是** Binding/Template 的，而是 **4 个 TaskRun 的** Pod。

**② `Pipeline` 是定义，`PipelineRun` 是它的一次实例**

TriggerTemplate 渲染出的就是 PipelineRun，其 `spec.pipelineRef.name` = `compassio-cicd` —— 即"这次运行按 `compassio-cicd` 的剧本跑"。（Pipeline 只是剧本，PipelineRun 是"这一场演出"。）

**③ 一次 `git push` = 几个 PipelineRun？→ 正常 1 个**

- 判据：label `compassio.cicd/commit`。实测：`64740aed→1`、`0033a659→1`、`a0dfe6ec→1`；`d65640d→2`（例外：**测试时手动 resend/重试**同一事件）。
- 是"**每次 push 一个 run**"，不是"每个 commit 一个 run"：一次 push 可含多个提交，但 webhook 只投递**一次** push 事件，tag 取 `checkout_sha`（本次推送的最新提交）。
- 只有 **`Push Hook`** 触发（interceptor 白名单）；重试 / resend / `tkn start` 才会多出 run。

**④ PipelineRun 的产物（4 类）**

| 产物 | 内容 | 谁产出 |
|---|---|---|
| Harbor 镜像 | `…/compassio/backend:<SHA>`、`…/frontend:<SHA>` | Step 8 |
| GitOps 仓提交 | `ci(compassio): promote image tag <SHA>` → 交由 ArgoCD 上线 | Step 9 |
| 子对象 | TaskRun × 4、Pod × 4、PVC `pvc-<hash>` | controller 展开 |
| 状态 | `status.conditions`（Succeeded/Failed）+ `status.taskRuns` | Tekton |

> PipelineRun **无 ownerReference**（sink 直接建）→ **会一直留存**；TaskRun 有 `owner=PipelineRun`，删 run 会级联删 TaskRun/Pod。

**⑤ `Task` ⇄ `TaskRun` 映射（与阶段对应）**

| 阶段 | `taskRef`（Task = 定义）| TaskRun（实例）| Pod |
|---|---|---|---|
| Step 7 clone | `git-clone` | `…-clone` | `…-clone-pod` |
| Step 8 构建（并行）| `compassio-build-push` | `…-build-push-backend` | `…-build-push-backend-pod` |
| Step 8 构建（并行）| `compassio-build-push` | `…-build-push-frontend` | `…-build-push-frontend-pod` |
| Step 9 提 tag | `compassio-update-gitops` | `…-promote-gitops` | `…-promote-gitops-pod` |

> 一个 Task 定义被复用：`compassio-build-push` → **两个** TaskRun（backend/frontend）。
> 交接链（owner 关系）：`Pod --owner--> TaskRun --owner--> PipelineRun`。

**⑥ 为什么那 4 个 Pod 显示 `0/1 Completed`（正常，不是异常）**

- `0/1` = "1 个容器里 0 个在运行"（容器已退出）；`Completed` = **正常跑完**。**已完成的 Task Pod 就长这样**。
- 4 个 Pod 的 `AGE` 略有差异（clone 最早 → promote 最晚），正对应执行顺序 clone → build×2（并行）→ promote。
- Pod 作为记录保留，故几小时后仍在（`AGE 5h58m` 等）。

```bash
# 某 commit 的所有 run
kubectl get pipelinerun -n cicd -l compassio.cicd/commit=<SHA>
# run → TaskRun → Pod
kubectl get taskrun -n cicd -l tekton.dev/pipelineRun=compassio-triggered-77tht
kubectl get pods -n cicd -l tekton.dev/taskRun=compassio-triggered-77tht-clone
# owner 链一屏看全
kubectl get pipelinerun,taskrun,pod -n cicd -l tekton.dev/pipelineRun=compassio-triggered-77tht \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,OWNER:.metadata.ownerReferences[*].kind'
```

#### 5.2.2 workspace PVC：存什么、为何用 `nfs-sc` 而不是 Ceph

**结论**：这块 PVC 是"**一次构建的临时源码中转盘**"，不是持久数据盘 —— NFS 的「可多 Pod 共享 + 删除即回收 + 创建轻量」正好匹配；Ceph RBD 的「单节点挂载 + Retain + 重 attach」反而是负优化。

**实测内容**（把某次 run 的 PVC 只读挂载后查看）：

```text
/ws
├── source/   5.3M   ← 应用仓浅克隆（182 文件，.git 2.0M；git clone --depth 1）
│   └── .git/ backend/ frontend/ deploy/ cicd/ docs/ testdata/
└── gitops/   356K   ← compassio-gitops 的克隆（.git 296K）
    └── overlays/ base/
总计 5.6M
```

| 目录 | 谁写 | 内容 | 谁读 |
|---|---|---|---|
| `source/` | `clone`（`git-clone`）| 应用仓在 `checkout_sha` 的**浅克隆** | 两个 build 任务读 `source/backend`、`source/frontend` 作构建上下文 |
| `gitops/` | `promote-gitops` | `compassio-gitops` 的克隆 | 改 `overlays/prod/kustomization.yaml` 的 `newTag` 后 push |

**不在这块 PVC 里的**（容易误会）：BuildKit 缓存（在 `buildkitd` 的 hostPath `/var/lib/buildkitd-cache`，节点 m01）、镜像（Harbor）、构建产物（`buildctl push` 直接推走，不落盘）。

**两个 SC 的实测差异**

| 维度 | `nfs-sc`（现用）| `ceph-rbd-sc` |
|---|---|---|
| provisioner | `example.com/nfs` | `rbd.csi.ceph.com` |
| 底层 | NFS `10.0.0.1:/data/nfs/cicd-pvc-…` | Ceph RBD 块设备（pool `k8s-rbd`）|
| 访问模式能力 | **多 Pod / 多节点共享**（本质 RWX 型）| **RWO**（同一时刻只能挂一个节点）|
| reclaimPolicy | **Delete**（随 PVC 自动清）| **Retain**（留 PV，需人工清）|
| 允许扩容 | ❌ | ✅ |
| 典型用途 | 共享、临时、轻量 | 持久、单挂载、强 IO（数据库）|

**为什么不用 Ceph（5 条）**

1. **workspace 要"共享"**：同一 PipelineRun 的 3~4 个 TaskRun 共用，两个 build 还**并行** → 需多 Pod 同时挂。RBD 是 RWO，当前能跑只因 `nodeSelector: worker03` 把所有 CI Pod 钉在同一节点"绕过"；NFS 天然共享，不依赖该约束。
2. **数据是临时的**：源码丢了重 clone 即可，不需要持久化/多副本/快照。`nfs-sc` 的 `Delete` 用完即清；`ceph-rbd-sc` 的 `Retain` 会攒 PV 要人工处理。
3. **创建频率高**：每个 run 建一块。RBD 要建 image + attach/detach（慢、且 multi-attach 有风险）；NFS provisioner 只是建目录。
4. **性能用不上**：几 MB 源码读写，无 IOPS/延迟需求。Ceph 块存储留给 **CNPG 数据库**（`compassio-pg-1` 正是 `ceph-rbd-sc` 10Gi）。
5. **隔离**：CI 高频 churn 放 NFS，不干扰数据库所在的 Ceph。

**配额：已从 2Gi 收敛到 256Mi，并加了清理 CronJob（2026-10-21）**

```text
修复前：26 块 × 2Gi = 52Gi（声明总量），单块实际仅 ~5.6M
修复后：新 run 用 256Mi；旧 run 由 CronJob 按 7 天保留期清理
```
- 生命周期：`volumeClaimTemplate` 生成，`owner=PipelineRun`，`reclaimPolicy=Delete` → 删 PipelineRun 时自动回收（级联 TaskRun/Pod/PVC）。
- **CronJob `cicd/cicd-cleanup`**（`cicd/07-cleanup.yaml`）：每天 03:00 删除 7 天前已结束的 PipelineRun；跳过 Running 与带 `cleanup=keep` 的 run；删除后由 K8s GC 回收 PVC。可用 `DRY_RUN=true` 预演。
- 该 Tekton 版本（v1.6.0）**不支持** `PipelineRun.spec.ttlSecondsAfterFinished`，所以用 CronJob 实现。
- 占用的是 **NFS 服务器 `10.0.0.1:/data/nfs`**，**不是** worker03 本地盘（故与之前的 `disk-pressure` 无关，那是 containerd imagefs）。

```bash
# 这块 workspace 的 SC / 大小 / 归属
kubectl get pvc -n cicd --sort-by=.metadata.creationTimestamp | tail
kubectl get pvc <pvc-name> -n cicd -o jsonpath='{.spec.storageClassName} {.spec.accessModes} {.spec.resources.requests.storage} owner={.metadata.ownerReferences[0].name}{"\n"}'
# NFS 实际后端路径
kubectl get pv <pv-name> -o jsonpath='{.spec.nfs.server}:{.spec.nfs.path}{"\n"}'
# 两个 SC 对比
kubectl get sc nfs-sc ceph-rbd-sc -o custom-columns='NAME:.metadata.name,PROV:.provisioner,RECLAIM:.reclaimPolicy'
```

### 5.3 构建引擎（Step 8：BuildKit）

| 资源 | 名称 | 作用 |
|---|---|---|
| Deployment | `cicd/buildkitd` | 常驻构建引擎（nodeSelector `m01`）|
| Service | `cicd/buildkitd`（ClusterIP `:1234`）| `buildctl` 连接目标 `buildkitd.cicd.svc.cluster.local:1234` |
| ConfigMap | `cicd/buildkitd-config` | `buildkitd.toml`（docker.io 镜像源 + Harbor CA）|
| ConfigMap | `cicd/buildkitd-ca`、`cicd/harbor-ca` | Harbor 自签 CA（initContainer 拼 bundle）|
| Pod | `cicd/buildkitd-<rs>-<rand>` | 单副本；缓存挂 hostPath `/var/lib/buildkitd-cache`（跨重启保留）|

```bash
kubectl get deploy,svc -n cicd buildkitd -o wide
kubectl get cm buildkitd-config -n cicd -o yaml
kubectl logs -n cicd deploy/buildkitd --tail=40
# 手工验证 daemon 与 workers
kubectl exec -n cicd deploy/buildkitd -- buildctl --addr tcp://127.0.0.1:1234 debug workers
```

> **客户端也要信任 Harbor CA**：`buildctl` 客户端会自己做 registry token 交换，而客户端镜像的 CA 库不含 Harbor 自签 CA。
> Task 挂载 `harbor-ca`，并在脚本里 `cat 系统CA + harbor.crt > /tmp/ca-bundle.crt` 后 `export SSL_CERT_FILE`。漏了会报
> `x509: certificate signed by unknown authority`（2026-10-14~10-20 正是卡在这里，见 `docs/23`）。

### 5.4 发布与收敛阶段（Step 10：ArgoCD）

| 资源 | 名称 | 作用 |
|---|---|---|
| Application | `argocd/compassio` | 盯 `compassio-gitops` 的 `overlays/prod` |
| AppProject | `argocd/default` | 项目边界 |
| StatefulSet | `argocd/argocd-application-controller` | 执行 sync（diff/apply）|
| Deployment | `argocd/argocd-repo-server` | 拉仓 + `kustomize build` |
| Deployment | `argocd/argocd-server` | API/UI |
| Deployment | `argocd/argocd-redis` | 缓存 |
| ConfigMap | `argocd/argocd-cm`、`argocd-rbac-cm` | 全局配置/RBAC |

```bash
kubectl get application compassio -n argocd -o wide
kubectl get application compassio -n argocd -o jsonpath='{.status.sync.status} {.status.health.status} rev={.status.sync.revision}{"\n"}'
kubectl describe application compassio -n argocd     # 看 operationState / 失败原因
# 触发一次同步（CLI 优先；无 CLI 时 patch Application 顶层 operation 字段）
argocd app sync compassio
kubectl -n argocd patch application compassio --type merge -p '{"operation":{"sync":{}}}'
# 渲染结果对照（不看集群也能预演）
argocd app manifests compassio   # 或 git 侧: kustomize build overlays/prod
kubectl logs -n argocd statefulset/argocd-application-controller --tail=80
```

### 5.5 业务运行态（Step 11）

| 资源 | 名称 | 作用 |
|---|---|---|
| Deployment | `compassio/compassio-backend`(×2)、`compassio-frontend`(×2)、`compassio-redis` | 应用工作负载 |
| Service | `compassio-backend:8000`、`compassio-frontend:80`、`compassio-redis:6379` | 内部访问 |
| Ingress | `compassio/compassio`（host `compassio.xyz`）| 用户侧入口 |
| Cluster(CNPG) | `compassio/compassio-pg`（pod `compassio-pg-1`）| 数据库 |
| Service | `compassio-pg-rw` / `-ro` / `-r`（`:5432`）| CNPG 读写/只读/任意 |
| Secret | `compassio-app-secrets`、`compassio-db-credentials`、`compassio-pg-*` | 运行时凭据 |

```bash
kubectl -n compassio rollout status deploy/compassio-backend
kubectl -n compassio get deploy,svc,ingress,pods -o wide
kubectl -n compassio get cluster compassio-pg -o wide
kubectl -n compassio rollout history deploy/compassio-backend
```

### 5.6 控制面常驻组件（Tekton）

```bash
kubectl get deploy,svc -n tekton-pipelines -o wide
# pipelines: controller / webhook / events
# triggers : controller / webhook / core-interceptors
kubectl logs -n tekton-pipelines deploy/tekton-pipelines-controller --tail=80
```

### 5.7 一键看全链路（排障起手式）

```bash
NS=cicd
echo "== 入口 ==" ; kubectl get ingress compassio-el -n $NS -o wide
echo "== EL    ==" ; kubectl get eventlistener compassio-listener -n $NS -o wide
echo "== 最近 CI =="; kubectl get pipelinerun -n $NS --sort-by=.metadata.creationTimestamp | tail -4
echo "== TaskRun =="; kubectl get taskrun -n $NS --sort-by=.metadata.creationTimestamp | tail -8
echo "== ArgoCD =="  ; kubectl get application compassio -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
echo "== 业务   ==" ; kubectl -n compassio get deploy -o wide
```

### 5.8 入口层对象：内置 `Ingress` 与 `IngressRoute`(CRD) 的差异

> 回答一个常见疑问：“`ci-compassio.xyz` 这个 host 配在哪个 CRD 里？” 答案：配在**内置的 `Ingress`**（`networking.k8s.io/v1`）里，**不是 CRD**。Traefik 的 CRD 在本集群装了，但**这条链路没用到**。

**本集群实态**：Traefik `v3.6.2`（chart `traefik-37.4.0`），同时启用 `kubernetesIngress` 与 `kubernetesCRD` 两个 provider —— 所以标准 `Ingress` 与 `IngressRoute` **可以并存**，路由统一到同一套流量。

两类入口对象在本集群的真实分工：

- **标准 `Ingress`**（只需 host + 路径转发）：`cicd/compassio-el`（`ci-compassio.xyz`）、`compassio/compassio`（`compassio.xyz`）。
- **Traefik CRD**（需要中间件/TLS）：`argocd/argocd`（`IngressRoute` + `Middleware` + `tls`）、`monitoring/grafana`、`monitoring/prometheus`、`traefik/traefik-dashboard`。

```yaml
# 标准 Ingress（内置，任何 controller 都认）
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  ingressClassName: traefik
  rules:
    - host: ci-compassio.xyz
      http:
        paths:
          - path: /              # pathType: Prefix
            backend: { service: { name: el-compassio-listener, port: { number: 8080 } } }
---
# IngressRoute（Traefik 私有 CRD）
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`argocd.devops.com`)          # Traefik 规则表达式
      middlewares: [{ name: argocd-forwarded-headers }]
      services: [{ name: argocd-server, port: 80, scheme: http }]
  tls: { secretName: argocd-tls }
```

| 维度 | 标准 `Ingress`（networking.k8s.io/v1）| `IngressRoute`（traefik.io/v1alpha1）|
|---|---|---|
| API 归属 | K8s **内置**资源 | **CRD**（需先装 Traefik CRDs）|
| 可移植性 | 高：换 controller 基本不改清单 | 低：绑定 Traefik |
| 入口选择 | `ingressClassName` | `spec.entryPoints: [web, websecure]` |
| 路由匹配 | `host` + `path`(+`pathType`)，表达力弱 | Traefik 表达式：`Host()/PathPrefix()/Headers()/Method()/Query()/正则`，可 `&&` / `\|\|` 组合 |
| 中间件 | 只能靠**注解**（字符串、无 schema、controller 私有）| `Middleware` CR：**结构化、可复用、可组合**（限流/重试/熔断/header 改写/basic-auth/forward-auth/IP 白名单…）|
| TLS | `spec.tls[{hosts, secretName}]` | `spec.tls.{secretName, options, certResolver}` |
| 权重/金丝雀/镜像 | ❌ 不支持 | ✅ `TraefikService`（weighted / mirroring / loadbalancer）|
| TCP / UDP | ❌ 不支持 | ✅ `IngressRouteTCP` / `IngressRouteUDP` |
| 健康检查 / sticky / LB 策略 | ❌（Ingress 层无）| ✅ `services[].healthCheck`、`sticky`、`serversTransport` |
| 显式优先级 | ❌ 隐式（按 path 长度规则）| ✅ `routes[].priority` |
| 配置校验 | 注解无 schema，写错难发现 | CRD schema 校验 |
| 跨命名空间引用 | N/A | `middlewares: [{ name, namespace }]` |

**选型建议**
- 需求只是「host + 路径转发」→ 用**标准 `Ingress`**（本项目 `ci-compassio.xyz` / `compassio.xyz` 即如此），最简、最可移植。
- 需要 **HTTPS 跳转 / 转发头改写 / 限流 / 认证 / 金丝雀权重 / TCP-UDP / 健康检查** 任一 → 才上 **`IngressRoute` + `Middleware`**（如 argocd / grafana）。
- 两者可混用，但**同一 host+path 不要双写**，否则谁生效取决于 Traefik 规则 `priority`，排查困难。

**常见坑**
- **CRD group 版本**：Traefik **v2** 是 `traefik.containo.us/v1alpha1`，**v3** 改为 `traefik.io/v1alpha1`；别与 Traefik Hub 的 `hub.traefik.io/*` 混淆。
- `IngressRoute` 在未装 CRD 的集群 `apply` 会报 `no matches for kind`；`Middleware` 默认须与 `IngressRoute` 同 ns（跨 ns 要显式写 `namespace`）。
- 标准 Ingress 的 Traefik 注解是字符串：**写错不报错、只是静默不生效**。
- 想走“标准但更强”的路线可关注 **Gateway API**（Traefik v3 已支持）。

**查看命令**
```bash
kubectl get ingress -A -o wide
kubectl get ingressroute,middleware -A -o wide
kubectl get ingress compassio-el -n cicd -o yaml
kubectl get ingressroute argocd -n argocd -o yaml
kubectl get crd | grep traefik.io
kubectl explain ingressroute.spec --recursive
kubectl get deploy traefik -n traefik -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

## 六、关键原理专题

### 6.1 为什么 tag 用 commit SHA，而不是 `latest`/版本号

- **可追溯**：看到线上镜像 tag 就知道对应哪次提交。
- **可回滚**：把部署仓 `newTag` 改回上一个 SHA 即完成回滚（无需重新构建）。
- **无漂移**：同一个 tag 永远指向同一份构建产物。

### 6.2 为什么 CI 不直接 `kubectl apply`（GitOps 拉模型）

- **单向数据流**：git 是期望状态的唯一真源，集群是它的投影；CI 只改 git。
- **自愈**：ArgoCD `selfHeal` 会把被手工改动/漂移的资源拉回 git 态。
- **可审计**：每次发布是一次 commit，谁、何时、把哪个 SHA 推上线一目了然。

### 6.3 Task 之间如何共享文件（workspace / PVC）

`PipelineRun` 用 `volumeClaimTemplate` 生成一块 PVC，并命名为 `shared-workspace`；各 Task 通过 `workspaces: - name: X, workspace: shared-workspace` 声明挂载点。于是 `clone` 写的源码能被并行的两个 build Task 读取，`promote` 也能在其中操作 git 目录。

### 6.4 Interceptor 的位置与「202 语义」

Interceptor 在 **EL sink 收到请求之后、创建 PipelineRun 之前**执行。被拦截的事件会被静默丢弃，但 HTTP 层仍回 `202`。**因此"webhook 交付 202"只证明网络通，不证明触发了构建**；判断是否真触发，要看 PipelineRun 是否新增。

### 6.5 凭据是怎么流动的（谁用哪个 Secret）

| 阶段 | Secret | 挂载/使用方式 |
|---|---|---|
| clone / promote 拉推 git | `cicd/gitlab-auth`（username/password 注入 Task 环境变量 → 拼进 URL |
| push 镜像 Harbor | `cicd/harbor-auth`（`.dockerconfigjson`）| 挂成 `/root/.docker/config.json` + `DOCKER_CONFIG` |
| EL 校验 webhook 来源 | `cicd/gitlab-webhook-secret`（`secretToken`）| interceptor `secretRef` |
| CI Pod 拉取镜像 | `imagePullSecrets: harbor-auth` | podTemplate |
| 业务运行时（DB/JWT/LLM）| `compassio/compassio-app-secrets` | 业务 Deployment env |

> ⚠️ `compassio-app-secrets` 目前以占位符方式存在于 gitops 仓并被渲染注入，属"密钥进 git"问题（见 `docs/20 §六-2`）。

### 6.6 BuildKit 镜像源与 CA 的由来

`buildkitd.toml` 把 `docker.io` 的拉取重定向到国内镜像源，并为 Harbor 域绑定自签 CA；`initContainer` 把系统 CA 与 Harbor CA 拼成 `/bundle/ca-bundle.crt` 供 daemon 使用。这是在**无外网直连**环境下能构建的关键。

> **但只配 daemon 不够**：daemon 与 `buildctl` 客户端是**两套信任库**。客户端会自己做 registry token 交换，必须通过挂载 `harbor-ca` + `SSL_CERT_FILE` 注入；否则报 `x509: certificate signed by unknown authority`（详见 `docs/23`）。

### 6.7 Kustomize 的 `images.newTag` 到底改了什么

base 中 Deployment 的 `image` 形如 `…/compassio/backend:v0.0.1`；overlay 的
```yaml
images:
  - name: 192.168.67.202:8443/compassio/backend
    newTag: <SHA>
```
会**按镜像名匹配**并把 tag 换成 `<SHA>`。CI 的 `sed` 正是逐行改写这里的 `newTag`。

---

## 七、配置清单（逐文件）

| 文件 | 作用 | 关键点 |
|---|---|---|
| `cicd/01-tasks.yaml` | 两个自定义 Task | `compassio-build-push`（buildctl→buildkitd→Harbor；**TLS 校验已恢复**，需挂 `harbor-ca` + `SSL_CERT_FILE`；`DOCKER_CONFIG`）；`compassio-update-gitops`（改 newTag、幂等、推部署仓） |
| `cicd/02-pipeline.yaml` | Pipeline 编排 | 4 Task；`image-tag` 无默认值（必须由 Trigger/手工传入） |
| `cicd/03-trigger.yaml` | Binding + Template | 抽取 `checkout_sha`/`git_http_url`；渲染 PipelineRun；`nodeSelector worker03` + `nfs-sc` 256Mi + `SA=pipeline` |
| `cicd/07-cleanup.yaml` | 旧 run 清理 | CronJob 每天 03:00 删 7 天前的 PipelineRun（级联回收 PVC）；`DRY_RUN` 可预演 |
| `cicd/04-eventlistener.yaml` | EL + Ingress | `gitlab` interceptor；Ingress `ci-compassio.xyz`→`:8080`；**勿手工建同名 Service** |
| `cicd/05-argocd-application.yaml` | ArgoCD Application | `prune:false`、`selfHeal:true`、`CreateNamespace:true` |
| `cicd/06-buildkit.yaml` | BuildKit daemon | mirrors + Harbor CA；rootless + `Unconfined`（`RuntimeDefault` 实测不兼容）；hostPath 缓存 `/var/lib/buildkitd-cache`；resources；svc `:1234` |
| `deploy/k8s/base/*` | 业务基线（种子） | Namespace/CNPG/Redis/backend/frontend/Ingress/可观测三件套 |
| `deploy/k8s/overlays/prod/*` | prod 覆盖（种子） | `images.newTag` + `replicas=2` |
| `compassio-gitops/*` | **部署真源** | ArgoCD 实际同步对象；比 `deploy/k8s` 多 `06-frpc.yaml`、`secret-patch.yaml` |

---

## 八、网络路径一览

```
[GitLab ubuntu01 192.168.67.201]
   /etc/hosts: 10.0.0.252 ci-compassio.xyz
   route:      10.0.0.0/24 via 192.168.67.156 dev eth0   (main 表)
   rule :      to 10.0.0.0/24 lookup main pref 5265       (< Tailscale 5270)
   systemd:    k8s-internal-route.service（持久化）
        │  （Tailscale table 52 保留给其它流量，互不冲突）
        ▼
[Traefik LB 10.0.0.252 :80] → Ingress ci-compassio.xyz → svc el-compassio-listener:8080
```

- **连通自检**（GitLab 主机上）：`curl -H 'Host: ci-compassio.xyz' http://10.0.0.252/` → **400**（EL 只吃 POST，400 即"通"）。
- **注意**：触发链路的"入站"依赖这条内网路由；它由 GitLab 主机的 systemd 单元维护，属需要监控的单点（见 `docs/20 §六-6b`）。

---

## 九、真实耗时与观测点（实测，无并发争用）

| 阶段 | 典型耗时 | 说明 |
|---|---|---|
| `clone` | ~7s | 纯 git 拉取 |
| `build-push-backend` | ~190–275s | 主要耗时；BuildKit 实测 272s（apt 202s + pip 42s），受镜像源与缓存影响 |
| `build-push-frontend` | ~95–125s | 与 backend 并行；BuildKit 实测 94s |
| `promote-gitops` | ~6–8s | git 操作 |
| **端到端（push → 镜像就绪）** | **~4–5 min** | BuildKit 实测约 4.8 min（clone 7s + backend 272s）|
| ArgoCD 收敛 | 轮询周期内（默认约 3 min）或 webhook 触发 | 取决于是否配置了 git webhook |

**常用观测命令**：

```bash
# 最近 CI
kubectl get pipelinerun -n cicd --sort-by=.metadata.creationTimestamp | tail
kubectl get taskrun -n cicd | grep <pipelinerun>
# 单步日志
kubectl logs -n cicd <taskrun>-build-push-backend-pod -c step-build
# ArgoCD 状态
kubectl get application compassio -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# BuildKit
kubectl get pods -n cicd -l app=buildkitd
```

---

## 十、故障定位索引

| 症状 | 去哪个文档 |
|---|---|
| push 后没有 PipelineRun，但 webhook 返回 202 | 本文 §4 Step 4（202 语义）+ `docs/02 §四`（token/事件类型） |
| GitLab 报 `URL is blocked: Requests to the local network` | `docs/02 §四`（`allow_local_requests=true` + Sidekiq 缓存坑） |
| EL 报 `services "el-compassio-listener" already exists`，interceptor 不生效 | 本文 §4 Step 3 + `docs/21` |
| 改了 tag 但集群没变 | 查 ArgoCD（`Synced?`）、查 Harbor 是否有对应 tag（`docs/02 §四`） |
| promote/build 卡 `Pending` | 查 worker03 `disk-pressure` 污点（`docs/20 §六-6`） |
| 私网路由不通（curl 000） | 本文 §八（下一跳必须是 `.156`） |

---

## 十一、演进记录

- **2026-10-18**：触发链路由 SSH 反向隧道改为直连 ingress，并加 `gitlab` interceptor 来源校验；补内网静态路由 `via 192.168.67.156`；修掉 EL 手工 Service 冲突 bug。详见 `docs/21`。
- **2026-10-20**：查清 BuildKit 无法构建的根因（`buildctl` **客户端** CA 未注入），修复后由 Kaniko 切回 BuildKit，并恢复 TLS 校验（去掉 `registry.insecure`）。详见 `docs/23`。
- 架构分析与待办（质量门禁、密钥治理、CI 节点硬绑等）见 `docs/20`。

---

*本文为全链路"是什么 / 怎么走 / 为什么"的详解，面向交接与排障；架构评判与改进优先级见 `docs/20`，日常命令见 `docs/02`。*
