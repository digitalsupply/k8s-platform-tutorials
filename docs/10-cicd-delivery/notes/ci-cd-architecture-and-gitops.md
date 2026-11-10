# Compassio GitOps / CI-CD 架构与配置分析

> 分析对象：`/root/compassio` 仓库中的 `cicd/`、`deploy/`、`backend/Dockerfile`、`frontend/Dockerfile`、
> `frontend/nginx.conf.template` 及 `docs/01`、`docs/02`、`docs/03` 等运维文档。
> 初版**只做分析与建议，不改动任何现有文件**；2026-10-18 的落地改动见下方"更新"。

> **更新（2026-10-18，已落地）**：本轮完成的改动，正文相应条目以 ✅/⚠️ 标注：
> 1. **webhook 直连 + 来源校验**（原 P0#1 → ✅）：GitLab hook 由 `http://127.0.0.1:18080/`（SSH 隧道）改为
>    `http://ci-compassio.xyz/`；EL 加 `gitlab` ClusterInterceptor（校验 `X-Gitlab-Token` + 仅收 `Push Hook`）。
> 2. **隧道退休**：m01 `gitlab-el-tunnel.service` `disable --now`，NodePort 30081 一并移除。
> 3. **内网直连路由**：GitLab 主机加 `10.0.0.0/24 via 192.168.67.156`（systemd `k8s-internal-route.service`），
>    Tailscale 退居备用。
> 4. **修掉潜伏 bug**：`04-eventlistener.yaml` 手工声明的同名 Service 导致 controller reconcile 失败、
>    EL 配置永不下发 —— 已改为交 controller 托管 ClusterIP。
> 5. **实测暴露新弱点**（⚠️）：CI 把所有 task pod 硬钉 worker03，worker03 触发 `disk-pressure` 时
>    `promote-gitops` 卡 `Pending`（本轮真实发生）。
>
> 变更详情与证据见 `docs/21-直连Webhook与隧道退休纪要.md`。
> 全链路「是什么 / 怎么走 / 为什么」的逐步详解见 `docs/22-从push到上线的CI-CD全链路详解.md`。
>
> **构建器补充（2026-10-20）**：10-14 曾尝试 BuildKit 失败并回滚 Kaniko（集群实际跑 Kaniko 达 6 天，repo 写在前的 BuildKit 清单未 apply）；
> 10-20 定位到真正根因是 **`buildctl` 客户端 CA 未注入**，修复后已切回 **BuildKit** 并完成真实构建。
> 排障与切换全过程见 `docs/23-BuildKit构建器排障与切换纪要.md`。

---

## 一、定位与总体评价

一套**基于 Tekton + BuildKit + Harbor + ArgoCD 的 Pull-based GitOps 交付链路**，运行在自建 K8s（Traefik + MetalLB + CNPG + Redis + LGTM 可观测栈）上，服务对象是内网单一业务系统 Compassio（FastAPI + Vue3）。

一句话概括数据流：

```
git push → GitLab webhook → Tekton(构建→推 Harbor→改 gitops 仓 tag) → ArgoCD(自动同步) → K8s 滚动发布
```

整体设计**思路正确、边界清晰、可复刻**，属于"教科书式的 GitOps 骨架"，对小型/单团队内网交付完全够用；本轮补齐了**触发来源校验**、去掉了**隧道单点**，当前短板集中在 **CI 质量门禁缺失、高可用与并发健壮性不足、凭据管理偏手工、CI 节点硬绑单点** 四个方面。

---

## 二、端到端流程（实测还原）

```
                        ┌───────────────────────────────────────────────┐
 开发者 git push ──────▶│ GitLab 192.168.67.201 (digitalsupply/compassio)│
                        └───────────────┬───────────────────────────────┘
                                        │ webhook: http://ci-compassio.xyz/
                                        │ (直连: GitLab /etc/hosts → 10.0.0.252
                                        │  经内网路由 via 192.168.67.156；Tailscale 备用)
                                        ▼
                        ┌───────────────────────────────────────────────┐
                        │ Traefik LB 10.0.0.252 → Ingress ci-compassio.xyz│
                        │ K8s ns=cicd                                    │
                        │ EventListener compassio-listener               │
                        │   └ gitlab interceptor (X-Gitlab-Token 校验)   │
                        │   └ TriggerBinding  (checkout_sha, git_http_url)│
                        │   └ TriggerTemplate → PipelineRun              │
                        │        compassio-triggered-<id>                │
                        │        (nodeSelector worker03 ⚠️, PVC nfs-sc 256Mi)│
                        │   Service el-compassio-listener: ClusterIP     │
                        │     8080/9000（由 triggers controller 托管）    │
                        └───────────────┬───────────────────────────────┘
                                        ▼
                Pipeline compassio-cicd (workspace: shared-workspace)
                ┌──────────────┬───────────────────┬──────────────────────┐
                │ git-clone    │ build-push-backend │ build-push-frontend  │  ← 两构建并行
                │ (tektonhub)  │ buildctl→buildkitd │ buildctl→buildkitd   │
                └──────┬───────┴─────────┬─────────┴──────────┬───────────┘
                       │                 ▼                    ▼
                       │        BuildKit(m01:1234) 构建镜像，docker.io→镜像源
                       │                 │ push (insecure)
                       │                 ▼
                       │        Harbor 192.168.67.202:8443/compassio/{backend,frontend}:<commitSHA>
                       │                 │ (auto_scan / Trivy)
                       ▼                 │
              promote-gitops ────────────┘
              sed overlays/prod/kustomization.yaml 双 newTag → commit/push
                       │  (gitops 仓 compassio-gitops)
                       ▼
              ArgoCD Application "compassio" (automated + selfHeal + CreateNamespace, prune=false)
                       │
                       ▼
              ns=compassio: CNPG compassio-pg + Redis + backend×2 + frontend×2 + Traefik Ingress compassio.xyz
```

关键参数：`image-tag = commit SHA`（不可变 tag，好习惯）；`runAfter` 让两个构建并行、promote 在两个构建之后。

---

## 三、组件清单

| 层 | 组件 | 位置 / 版本 | 配置源 | 说明 |
|---|---|---|---|---|
| 源码 | GitLab（自建）| 192.168.67.201 | 私有仓 | app 仓 + `compassio-gitops` 仓 |
| 触发 | Tekton Triggers | EventListener/Binding/Template `v1beta1` | `cicd/03`,`04` | 经 Traefik Ingress `ci-compassio.xyz`；EL 挂 `gitlab` interceptor；Service 由 controller 托管 ClusterIP |
| 触发入口 | 直连 ingress | GitLab 主机 `systemd k8s-internal-route.service`（`10.0.0.0/24 via 192.168.67.156`）| systemd | 原 SSH 隧道 + NodePort 30081 已退休；Tailscale 备用 |
| 编排 | Tekton Pipeline | `tekton.dev/v1` | `cicd/02` | clone → build×2 → promote |
| 构建 | BuildKit（moby）| `v0.20.2-rootless`，buildkitd TCP 1234 | `cicd/06` | `buildctl` 客户端；需给**客户端**注入 Harbor CA（`SSL_CERT_FILE`，见 `docs/23`）|
| 构建备选 | Kaniko | `v1.23.2` | `cicd/99-kaniko-tasks.yaml.bak` | 应急回滚路径；2026-10-14~10-20 曾为现役（见 `docs/23`）|
| 仓库 | Harbor | 192.168.67.202:8443（自签证书）| 集群外部 | 项目 `compassio`，auto_scan(Trivy) |
| GitOps | ArgoCD Application | `argoproj.io/v1alpha1` | `cicd/05` | automated + selfHeal，`prune:false` |
| 清单 | Kustomize | base + overlays/prod | `deploy/k8s` | base 5 资源 + prod 副本补丁 |
| 数据库 | CloudNativePG | `compassio-pg`, instances=1 | `deploy/k8s/base/01` | storageClass `ceph-rbd-sc` 10Gi |
| 缓存 | Redis | `redis:7-alpine` | `deploy/k8s/base/01` | `appendonly no` |
| 入口 | Traefik Ingress | `compassio.xyz` | `deploy/k8s/base/03` | 用户侧手动改 hosts |
| 可观测 | ServiceMonitor + PrometheusRule + Grafana Dashboard | `monitoring.coreos.com` | `deploy/k8s/base/04`,`05` | LGTM 接入 |

**凭据（集群 Secret）**：`cicd/gitlab-auth`（username/password/token）、`cicd/harbor-auth`（dockerconfigjson）、`cicd/gitlab-webhook-secret`（`secretToken`，interceptor 校验用）、`compassio/compassio-app-secrets`（DATABASE_URL/JWT_SECRET/SECRET_KEY/LLM_*）、`compassio/compassio-db-credentials`、argocd 仓专用 `gitlab-compassio-gitops`。

---

## 四、配置逐项解读（结合代码）

### 4.1 `cicd/01-tasks.yaml`
- **`compassio-build-push`**：`buildctl build --frontend dockerfile.v0 --output type=image,...,push=true --export-cache type=inline`。
  - **已恢复 TLS 校验**：不再使用 `registry.insecure`。
  - **客户端 CA 是硬要求**：脚本先 `cat /etc/ssl/certs/ca-certificates.crt /etc/harbor-ca/ca.crt > /tmp/ca-bundle.crt` 并 `export SSL_CERT_FILE`，否则 `buildctl` 客户端做 registry token 交换时报 `x509: certificate signed by unknown authority`（详见 `docs/23`）。
  - `workingDir` 用 `$(params.context)` 拼 build context，`DOCKER_CONFIG=/home/user/.docker` 由 `harbor-auth` 挂载。
  - **✅ 已非 root**：去掉 `runAsUser: 0`，用镜像默认 uid 1000（2026-10-20 验证通过）。
- **`compassio-update-gitops`**：`alpine/git` 克隆 gitops 仓 → `sed` 重写**所有** `newTag:` 行 → commit → `git push origin HEAD:main`。
  - 幂等保护：`git diff --quiet` 命中即退出。
  - 凭据来自 `gitlab-auth`，gitops URL 参数化（不写死进 secret）。

### 4.2 `cicd/02-pipeline.yaml`
- 4 个 Task：`clone` → 并行 `build-push-backend/frontend` → `promote-gitops`。
- **无 test / lint / 安全扫描 / 部署后冒烟**任何步骤。
- `image-tag` 无默认值，只能由 Trigger 或手工传入。

### 4.3 `cicd/03-trigger.yaml` / `04-eventlistener.yaml`
- TriggerBinding 取 `body.checkout_sha`、`body.repository.git_http_url`。
- **✅ 来源校验（本次新增）**：EL 挂 `gitlab` ClusterInterceptor，要求 `X-Gitlab-Token == cicd/gitlab-webhook-secret(secretToken)`，且 `X-Gitlab-Event: Push Hook`。注意 Tekton 语义：**拦截失败时 HTTP 仍返回 `202`**，不代表触发成功（排查时别看错状态码）。
- TriggerTemplate 固定 `serviceAccountName: pipeline`、`nodeSelector: worker03`（⚠️ 见 §六-6）、`nfs-sc` 256Mi PVC、`imagePullSecrets: harbor-auth`。
  - **PVC 生命周期**：每个 PipelineRun 通过 `volumeClaimTemplate` 建一块 256Mi PVC（owner=PipelineRun），删 run 时级联回收；默认不清理会累积，已用 `cicd/07-cleanup.yaml` 的 CronJob 每天清理 7 天前的 run（详见 `docs/22 §5.2.2`）。
- **✅ Service 归属改为 controller**：不再手工声明 `el-compassio-listener`（原 NodePort 30081 已移除），由 triggers controller 创建 ClusterIP（8080/9000）。手工声明**同名** Service 会让 controller 报 `services "el-compassio-listener" already exists` → reconcile 失败 → **EL 的 spec 变更（含 interceptor）永不下发**（本次踩坑，详见 `docs/21`）。

### 4.4 `cicd/05-argocd-application.yaml`
- `syncPolicy.automated`: `prune:false`、`selfHeal:true`、`CreateNamespace=true`。
- `prune:false` 是**有意**避免误删数据资源（如 CNPG/Redis），需接受"删清单不删对象"的长期漂移。

### 4.5 `cicd/06-buildkit.yaml`
- `buildkitd.toml`：`docker.io → [docker.1ms.run, swr.cn-north-4...]` 镜像源；Harbor 域配 `ca`。
- initContainer 拼 CA bundle；buildkitd `runAsNonRoot/runAsGroup=1000` + `seccompProfile Unconfined`（**实测 `RuntimeDefault` 会导致 rootlesskit 起不来**：`fork/exec /proc/self/exe: operation not permitted`）。
- **状态卷用 hostPath `/var/lib/buildkitd-cache`**（m01），**跨 Pod 重启保留缓存**；`emptyDir` 已弃用。
  - 为什么不用 PVC：`nfs-sc` 不支持 rootless snapshotter 的 `lchown`（`operation not permitted`）；`ceph-rbd-sc` 的 CSI 节点插件未装在 m01（`CSINode m01 does not contain driver rbd.csi.ceph.com`）。
- 已加资源 requests/limits（`500m/1Gi` ~ `2/4Gi`）。

### 4.6 `deploy/k8s`
- base：Namespace + CNPG Cluster（instances=1）+ Redis Deployment/Service（无 PVC）+ backend/frontend Deployment/Service + Traefik Ingress + 可观测三件套。
- `overlays/prod`：仅 `images.newTag` + 两处 `replicas=2` 的 JSON patch。
- `compassio-app-secrets` 以 `stringData` 承载，值均为占位符 `RENDER_AT_DEPLOY`（由 gitops 私有仓在首推前渲染真实值）。
- backend 有 readiness(`/api/health`)/liveness(`/api/health/live`)、资源 requests/limits；frontend 有 `/` 探针。

### 4.7 镜像与前端
- backend 基础镜像 `compassio/python:3.11-slim` + apt/pip 国内源升级 + 去 CVE。
- frontend 多阶段 node22-alpine → nginx:alpine，同样切 aliyun 源。
- `nginx.conf.template` 用 `${BACKEND_HOST}` 注入上游，`proxy_read_timeout 600s`（适配批量 bcrypt 导入），`/index.html` 禁缓存、`/assets/` 长缓存。

---

## 五、优点（做得好的地方）

1. **职责分离干净**：CI 只负责"构建镜像 + 改 tag"，CD（ArgoCD）只负责"同步 git 期望状态"——标准 GitOps 分工，避免 CI 直接 `kubectl apply`。
2. **不可变 tag**：`image-tag = commit SHA`，天然可追溯、可回滚、避免 `latest` 漂移。
3. **GitOps 仓与代码仓分离**：部署清单独立仓（`compassio-gitops`），把"发布动作"变成一次可审计的 git commit。
4. **promote 幂等**：`git diff --quiet` 命中即退出，避免空提交。
5. **构建器现代化 + 可回滚**：主用 BuildKit（kaniko 现役替代），保留 `99-kaniko-tasks.yaml.bak` 作为明确回退路径。
6. **镜像源本地化**：`buildkitd.toml` 配 mirror、基础镜像转入 Harbor、pip/npm/apt 全切国内源——在无外网直连环境下是务实且关键的设计。
7. **供应链留有一道关**：Harbor `auto_scan`（Trivy）在推镜像时自动扫描；Dockerfile 主动升 OS 包消除 CVE，安全意识可见。
8. **可观测性到位**：ServiceMonitor 抓 `/metrics`，PrometheusRule 覆盖后端存活、P95 延迟、LLM 等待、预取失效、回退率、Redis 依赖，Grafana 看板自动注入；告警表达式有"三条件同时成立才告警"的去噪设计（见 `04` 的 PrefetchIneffective）。
9. **应用侧健壮性**：backend 有就绪/存活探针与资源配额，前端启动依赖后端、nginx 超时针对业务调优。
10. **文档与可复刻性**：`docs/02` 有"复刻指南""凭据矩阵""故障树"，`docs/01/03` 记录坑位，运维可交班。
11. **✅ 触发来源校验已补齐**（本次）：webhook 从"仅靠私网隔离"升级为"token 校验 + 事件类型白名单"，伪造 push 无法再触发构建。
12. **✅ 隧道单点已消除**（本次）：触发入口不再依赖 m01 的 systemd/sshd/NodePort，改为经 Traefik 的直连 ingress，且内网路由（`via 192.168.67.156`）与 Tailscale 并存互不冲突。

---

## 六、缺点与风险（按优先级）

### P0 — 安全与正确性
1. ~~**Webhook 无来源校验**~~ **✅ 已解决（2026-10-18）**：EL 已加 `gitlab` ClusterInterceptor（`X-Gitlab-Token` 校验 + 仅 `Push Hook`），webhook 直连 `ci-compassio.xyz`、NodePort 已移除。**残留注意**：目标是私网地址（`10.0.0.252`），GitLab 侧 `allow_local_requests_from_hooks_and_services` 必须保持 `true`；进一步收窄可用 `outbound_local_requests_allowlist`（坑位详见 `docs/21`）。
2. **凭据明文进 git**：`compassio-app-secrets`（含 `DATABASE_URL`、`SECRET_KEY`、`LLM_API_KEY`）以 `stringData` 明文提交到 gitops 仓。虽然仓是内网私有，但等于把生产密钥交给"任何有读权限的人/任何一次误 clone"，与文档"不要在 git 历史之外留存明文"的初衷相悖。
3. **CI 无质量门禁**：Pipeline 里**没有** `pytest` / `npm run build`（作为任务）/ lint / 单测。也就是说**镜像在测试全绿之前就已推送并 promote**；`backend && python -m pytest` 目前只在开发机手动跑（README）。一旦有人 push 未过测代码，会直接上线。
4. **镜像签名/校验**：✅ BuildKit 主链路**已恢复 TLS 校验**（去掉 `registry.insecure`，客户端注入 CA）；⚠️ 但 Kaniko 回滚路径仍 `--skip-tls-verify --insecure-pull`，且两家都**无镜像签名**（cosign）。Harbor 换正式证书后可彻底移除 CA 注入。

### P1 — 健壮性与高可用
5. **并发构建竞态**：无 PipelineRun 并发控制（无 `concurrency`/队列），两次快速 push 会并行，`promote-gitops` 都 `git pull --ff-only` + `push HEAD:main`，后到者 non-fast-forward 失败 → 流水线红、tag 落后。`sed` 又一次性重写**全部** `newTag`，并发下会互相覆盖。
6. **触发入口的单点已钝化，但未根除**：~~SSH 隧道 → NodePort 30081~~ 已退休（✅ 改直连 ingress）。但浮现两个新的单点：
   - **(a) ⚠️ CI 硬绑 worker03（本轮实测暴露）**：TriggerTemplate 给**所有** task pod `nodeSelector: worker03`。worker03 一旦出现 `node.kubernetes.io/disk-pressure:NoSchedule` 污点（本轮 imagefs 冲到 85% 触发），`promote-gitops` 直接卡 `Pending`，整条流水线卡死；而 `build` 步骤因先于污点调度、反而"看起来正常"。
   - **(b) 触发路由依赖**：GitLab 主机到 `10.0.0.0/24` 需经内网 `via 192.168.67.156`（否则默认网关 `.1` 黑洞），systemd `k8s-internal-route.service` 与 Tailscale 二者任一失配即静默失效。
7. **数据库单实例**：CNPG `instances: 1`，DB 无 HA、无读写分离；备份依赖手动 `kubectl cnpg backup`。
8. ~~**BuildKit 无持久缓存**~~ **✅ 部分解决（2026-10-20）**：`emptyDir` 已改 **hostPath `/var/lib/buildkitd-cache`**（m01），跨 Pod 重启保留（实测重启后热构建 25s、全 `CACHED`）；已加 requests/limits。**剩余**：单副本、无 NetworkPolicy；hostPath 不跨节点（buildkitd 本就钉在 m01）。
9. **应用无高可用编排**：2 副本但**无 `podAntiAffinity`/`topologySpreadConstraints`**，可能被调度到同一节点；无 HPA、无 PDB、无 `strategy`/`revisionHistoryLimit` 显式声明。
10. **回滚靠手工**：没有 ArgoCD Rollback 流程、没有 Image Updater 自动比对、没有 `kubectl rollout undo` 剧本；回滚 = 人肉改 gitops 仓 tag 再 push（或直接改 Harbor）。

### P2 — 工程细节
11. ~~**`runAsUser: 0` 与 rootless buildkitd 语义冲突**~~ **✅ 已解决（2026-10-20）**：Task 已去掉 `runAsUser: 0`，用镜像默认 uid 1000，构建验证通过。**残留**：daemon 仍 `seccompProfile: Unconfined` —— 实测 `RuntimeDefault` 会让 rootlesskit 起不来，属 rootless buildkit 的硬约束（已在清单中注明原因）。
12. **`.bak` 文件留在活跃目录**：`99-kaniko-tasks.yaml.bak` 若被 `kubectl apply -f cicd/` 整目录误吃（命名以 `99` 开头但后缀 `.bak` 通常不匹配 `*.yaml`，风险较低），或新人误读——建议移入 `cicd/legacy/` 或加显著 README 注释。（注：`find` 显示它是 `.bak`，正常 glob 不会匹配。）
13. **镜像 tag 非 digest 固定**：基础镜像 `compassio/python:3.11-slim` 等固定 tag 而非 digest；且 mirror 镜像源（`docker.1ms.run`、华为 SWR 代理）属第三方，供应链上无版本锚定。
14. **`prune:false` 的漂移**：长期使用会出现"git 里已删、集群里还在"的对象；需配套定期人工审计。
15. **无 CI 失败通知**：Pipeline 失败没有 Alertmanager/webhook/IM 通知（只有 PrometheusRule 的业务告警），失败靠人看 `kubectl get pipelineruns`。
16. ~~**EL 用 NodePort 直暴露绕过 Ingress**~~ **✅ 已解决（2026-10-18）**：NodePort 已移除，EL 只经 Ingress `ci-compassio.xyz` 暴露，回到 Traefik 的集中策略点。
17. **文档双份源**：`docs/03-*` 有两个不同文件（`03-代码架构与质量分析.md` 与 `03-首次上线纪要.md`），编号冲突易误引。

---

## 七、改进建议（可落地，按优先级）

> 以下为建议；条目 1、6 已于 2026-10-18 落地（标 ✅），其余待办。

### 立刻做（P0）
1. ✅ **已完成（2026-10-18）**：EL 加 `gitlab` interceptor（token + `Push Hook`），NodePort 已移除，只经 Ingress 暴露。落地形态：
   ```yaml
   interceptors:
     - ref: { name: gitlab, kind: ClusterInterceptor }
       params:
         - { name: secretRef, value: { secretName: gitlab-webhook-secret, secretKey: secretToken } }
         - { name: eventTypes, value: ["Push Hook"] }
   ```
   并在 GitLab 项目 hook 填同一 Secret Token。注意：目标是私网地址，`allow_local_requests_from_hooks_and_services` 需保持 `true`。
2. **把测试接进 Pipeline**（质量门禁）：
   - 新增 `run-tests` Task：backend `pip install -r requirements-dev.txt && pytest -q`；frontend `npm ci && npm run build`（作为构建前置，而不是构建时才第一次编译）。
   - 在 `build-push-backend/frontend` 之前 `runAfter: [run-tests]`，测试失败即整条 Pipeline 停在构建前。
3. **凭据移出 git**：改用 **Sealed Secrets / SOPS+age / External Secrets Operator** 三者之一，gitops 仓只存密文；或至少把 `compassio-app-secrets` 从 base 移除，改为部署时 `kubectl create secret` / ArgoCD `secretGenerator` + 外部注入。
4. **恢复 TLS 校验**：✅ BuildKit 主链路已去掉 `registry.insecure`（客户端注入 CA，见 `docs/23`）；余下：给 Harbor 换正式证书（cert-manager 已装）、清理 Kaniko 回滚路径的 `--skip-tls-verify`；对基础镜像逐步改 **digest 固定**。

### 尽快做（P1）
5. **给 Pipeline/PipelineRun 加并发与去重**：
   - 用 Tekton `Pipeline` 的 `pipelineRunSpec` 或触发器 Template 里加 `labels` + ArgoCD 风格的 `concurrency`（Tekton v0.5x 支持 `pipelineSpec`…实践上最简：在 TriggerTemplate 里以 `gitrevision` 去重 / 用 `EventListener` 的 `--el-events` 保证串行）。最小可行：`promote-gitops` 用 `git push --force-with-lease` 或加 `git pull --rebase` 重试，`sed` 改为**按镜像名精确替换**而非重写所有 `newTag`。
6. ✅ **已完成（2026-10-18）**：隧道已退休；GitLab 主机加 `10.0.0.0/24 via 192.168.67.156`（systemd `k8s-internal-route.service`，rule `to 10.0.0.0/24 lookup main prio 5265`），webhook 直打 `ci-compassio.xyz`。
6b. **⚠️ 给 CI podTemplate 加 disk-pressure 容忍 / 去掉 worker03 硬绑**（本轮实测新增）：在 TriggerTemplate 的 podTemplate 加
   `tolerations: [{ key: node.kubernetes.io/disk-pressure, operator: Exists, effect: NoSchedule }]`，
   或直接去掉 `nodeSelector: worker03`（workspace 用 `nfs-sc`，通常可跨节点），并给节点加镜像/日志 GC 或扩容，避免再用"节点一满、promote 卡死"。
7. **数据库 HA**：CNPG `instances: 2~3`（或至少配 `backup.barmanObjectStore` 定时备份 + PITR），把 `kubectl cnpg backup` 从"手动"升级为 schedule。
8. ✅ **BuildKit 持久化与限额（部分完成）**：缓存已改 hostPath `/var/lib/buildkitd-cache`（NFS/Ceph 均不可行，见 §4.5），并加 requests/limits；剩余：2 副本 + 反亲和、为 `cicd`/`compassio` 加 **NetworkPolicy**。
9. **应用高可用**：backend/frontend 加 `podAntiAffinity`（或 `topologySpreadConstraints`），显式声明 `strategy.rollingUpdate`、`revisionHistoryLimit`；视负载加 HPA；给关键工作负载加 PDB。
10. **回滚剧本**：约定"回滚 = 把 gitops 仓 `newTag` revert 到上一个 SHA（或 `argocd app rollback`）"，写进 `docs/02` 并演练一次。

### 逐步做（P2）
11. ✅ Task 步骤已非 root（uid 1000）。`seccompProfile` 仍为 `Unconfined`：**已实测 `RuntimeDefault` 不兼容**（rootlesskit `fork/exec /proc/self/exe: operation not permitted`），除非改用非 rootless 或调整 rootlesskit 能力，否则维持现状并在清单注明原因。
12. `99-kaniko-tasks.yaml.bak` 移入 `cicd/legacy/` 并加 `README`，避免误用。
13. 增加 **CI 失败通知**：PrometheusRule 加 `TektonPipelineRunFailed` 告警（或 EventListener 出错后 webhook 到 IM/邮件）。
14. 基础镜像从 tag 改 digest；镜像源（1ms.run/SWR）如需保留，记录其漂移风险并定期比对 digest。
15. 明确 `prune` 策略：对纯无状态资源（Deployment/Service/Ingress）可开 `prune:true`，对有状态资源（CNPG/Redis/Secret）用 `Prune=false` annotation 单独豁免——比"全局 false"更精确。
16. 统一文档编号：把 `docs/03-*` 两份改名（如 `03a`/`03b`），避免引用歧义。
17. 可选：引入 **ArgoCD Image Updater** 或 **Argo Rollouts**（金丝雀/蓝绿），把当前"双副本滚动"升级为可灰度、可自动回滚的发布。

---

## 八、一页速查（结论）

| 维度 | 评级 | 一句话 |
|---|---|---|
| 流程正确性 | ★★★★☆ | 标准 GitOps 分工，tag 不可变，promote 幂等 |
| 可复刻/文档 | ★★★★☆ | 复刻指南 + 故障树 + 坑位清单，交班友好 |
| 可观测性 | ★★★★☆ | Metrics/Rule/Dashboard 齐备且有去噪 |
| 安全 | ★★★☆☆ | ✅ webhook 来源校验已补、公网面收敛；余：密钥进 git、TLS 全跳过 |
| CI 质量门禁 | ★☆☆☆☆ | 无测试/扫描门禁，未过测即上线 |
| 高可用/健壮 | ★★☆☆☆ | DB 单实例、构建缓存易失、无 PDB/HPA/反亲和、并发竞态；⚠️ CI 硬绑 worker03 |
| 运维自动化 | ★★★☆☆ | ✅ 隧道单点已除；回滚/备份/通知仍依赖手工 |

**最需要先做的（更新）**：① ~~EventListener 加 GitLab interceptor + 去 NodePort~~ ✅ 已完成；② Pipeline 前置 `pytest`/`npm build` 门禁；③ 密钥改 Sealed Secrets/SOPS 并恢复 Harbor TLS 校验；④ ⚠️ 给 CI podTemplate 加 `disk-pressure` 容忍 / 去掉 worker03 硬绑。

---

*初版为静态代码/清单分析；2026-10-18 的 P0#1（webhook 直连 + interceptor）、隧道退休、内网路由、EL Service 归属等改动已在真实集群落地并验证（见文首"更新"与 `docs/21-直连Webhook与隧道退休纪要.md`）。2026-10-20 完成 BuildKit 切换与加固（客户端 CA、hostPath 缓存、资源限额、非 root 客户端），并**实测确认 buildkitd 与 `RuntimeDefault` seccomp 不兼容**；详见 `docs/23`。构建耗时与镜像元数据以 `docs/22 §九` 实测为准。*
