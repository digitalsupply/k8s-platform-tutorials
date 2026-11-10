# 10 · CI/CD 交付：GitLab → Tekton → BuildKit → Harbor → ArgoCD

## 当时的情况

这是一套**Pull-based GitOps** 交付链路，服务内网业务系统（FastAPI + Vue3）：

```text
git push
  → GitLab（192.168.67.201）
  → Webhook
  → Traefik 10.0.0.252
  → Tekton EventListener（ns=cicd）
  → Pipeline：clone → build backend/frontend（并行）→ promote-gitops
  → BuildKit → Harbor（192.168.67.202:8443）
  → GitOps 仓（overlays/prod 改 image tag）
  → ArgoCD 自动同步
  → K8s 滚动发布
```

当时的真实状态并不“教科书”：

- 仓库里写的是 **BuildKit**，集群里实际跑的是 **Kaniko**，漂移了 6 天；
- BuildKit 起不来的根因是 **buildctl 客户端 CA** 没注入，不是 daemon；
- EventListener 的 Service 被手工声明，controller reconcile 失败，配置一直没下发；
- Webhook 最初走 SSH 隧道到 `127.0.0.1:18080`，隧道是单点；
- 后来直连 `ci-compassio.xyz`，又因 GitLab 主机 `/etc/hosts` 失效静默中断 3 天；
- CI 把所有 task pod 硬钉 worker03，worker03 触发 `disk-pressure` 时 promote 卡 Pending。

2026-11 又完成了三件交付层的事：

- **Tekton 从 standalone 迁到 Operator v0.81.3**，纳入 ArgoCD，保留策略从 1 天改为 30 天；
- **Open WebUI 全链路 CI/CD + GitOps**（GitLab → Runner → Tekton → Harbor → ArgoCD → Traefik），
  以及后续的资源右规格化、frpc 暴露、暂停/恢复；
- 对 Tekton 历史保留做了独立研究：`ttlSecondsAfterFinished` 不存在、Pruner/Results 的取舍。

## 主要概念与原理

### 1. Tekton 的对象模型

| 对象 | 作用 |
|---|---|
| `Task` | 一组 step（容器），定义输入/输出/workspace |
| `Pipeline` | Task 的 DAG，`runAfter` 控制顺序 |
| `PipelineRun` | 一次 Pipeline 执行 |
| `TriggerBinding` | 从 webhook body 提取变量 |
| `TriggerTemplate` | 用变量渲染 PipelineRun |
| `EventListener` | 接收 webhook，触发 Trigger |
| `Interceptor` | 校验/过滤 webhook（本集群用 GitLab token） |

### 2. EventListener 的 Service 由谁创建

Tekton Triggers 的 controller 会根据 EventListener 自动创建 Service。
如果手工再声明一个同名 Service，controller reconcile 会失败，**EL 配置永远不会下发**。
所以 Service 必须交给 controller 托管。

### 3. BuildKit 的 daemon 与 client

- `buildkitd`：常驻 daemon，监听 `tcp://0.0.0.0:1234` 或 unix socket；
- `buildctl`：客户端，把构建请求发给 daemon；
- 客户端要信任 Harbor 的 **自签 CA**，否则 `x509: certificate signed by unknown authority`；
- daemon 侧和 client 侧都要配 CA，缺一不可。

### 4. Harbor 与镜像 tag

- Harbor 项目 `compassio/backend`、`compassio/frontend`；
- tag 用 commit SHA，保证可追溯；
- 开启 Trivy 自动扫描；
- CI 推送后，GitOps 仓只改 `images.newTag`，不直接 `kubectl set image`。

### 5. ArgoCD 的同步

- ArgoCD 轮询 GitOps 仓（或 webhook）；
- 发现 `overlays/prod` 的 tag 变化后 sync；
- 生产环境建议 `selfHeal=true` + `prune=true`，但要注意 CRD/Job 的 prune 行为。

### 6. Webhook 的来源校验

- GitLab 发送 `X-Gitlab-Token`；
- Tekton 的 `ClusterInterceptor` 校验 token，并只接受 `Push Hook`；
- 没有校验的 webhook 等于公开的“任意触发构建”入口。

### 7. Tekton 的安装形态：standalone vs Operator

| 形态 | 管理方式 | 升级/保留 |
|---|---|---|
| standalone | `kubectl apply` 官方 release YAML | 组件各自升级，无统一 CR |
| Operator | `TektonConfig` CR + Operator | 统一版本、内置 Pruner、Dashboard/Trigger 一起管 |
| Helm | chart | 社区维护，版本可能滞后 |

Operator 不是“更重的 standalone”，它把 Pipelines/Triggers/Dashboard/Pruner 的版本和配置
收敛到一个 `TektonConfig`，并由 controller 持续 reconcile。

### 8. Tekton 历史保留的四代方案

1. `ttlSecondsAfterFinished`：**PipelineRun/TaskRun 没有这个字段**，不能照搬 Job；
2. 自定义 CronJob + `tkn`/脚本：本集群早期方案，只保留 1 天；
3. Operator Pruner：`TektonConfig.spec.pruner`，按数量/天数清理；
4. Tekton Results + 激进清理：对象存到外部，K8s 里只留少量，适合审计/回滚。

删除 PipelineRun 会级联删除 TaskRun → Pod → `volumeClaimTemplate` PVC，
但**不会**删除外部日志、Results、Git 里的定义。

### 9. GitOps 的“构建产物”边界

CI 负责：

- 构建镜像、推 Harbor（tag = commit SHA）；
- 修改 GitOps 仓的 `newTag` 并 commit；
- 不直接 `kubectl apply`。

ArgoCD 负责：

- 拉 GitOps 仓、渲染 Kustomize；
- 同步到集群、自愈漂移。

这条边界一旦打破（CI 直接改集群），Git 就不再是唯一事实来源。

## 踩坑点

### 坑 1：BuildKit 的 CA 只修了 daemon，没修 client

daemon 日志显示 `x509`，于是给 daemon 挂了 `buildkitd-ca` ConfigMap。
但真正失败的是 `buildctl` 客户端：它不信任 Harbor 自签 CA。

**修复**：

```yaml
# Task 的 build step
env:
  - name: SSL_CERT_FILE
    value: /certs/harbor-ca.crt
volumeMounts:
  - name: harbor-ca
    mountPath: /certs
```

并把 `harbor-ca` Secret/ConfigMap 挂进 Task Pod。修复后镜像 history 出现 `# buildkit`，
Harbor 里也能看到 BuildKit 生成的 layer。

### 坑 2：仓库与集群漂移 6 天

10-14 尝试 BuildKit 失败后回滚到 `99-kaniko-tasks.yaml.bak`，但仓库里的 `01-tasks.yaml`
仍写着 BuildKit。之后 6 天所有镜像都是 Kaniko 构建，没人发现。

**修复**：

- 以集群 `last-applied-configuration` 为准核对；
- 在 CI 里加“repo 与集群 Task 镜像一致性”检查；
- 构建日志/镜像 history 作为判据，不只看 Task YAML。

### 坑 3：EventListener 的 Service 冲突

`04-eventlistener.yaml` 手工声明了同名 Service，controller 无法接管，EL 配置永不下发。
表现是 webhook 能打到 Service，但 PipelineRun 不产生。

**修复**：删掉手工 Service，让 controller 创建 ClusterIP；用 `kubectl get el -o yaml`
确认 status 和 address。

### 坑 4：Webhook 主机名解析失败是“静默”的

GitLab 页面只显示 webhook “失败”，`POST /hooks/1/events` 返回 `internal error`、
`duration` 为空，说明请求根本没出 GitLab 主机。

根因：`/etc/hosts` 里 `10.0.0.252 ci-compassio.xyz` 的绑定失效。

**修复**：

1. 临时给 EL 加一条已能解析的主机名路径（如 `el-deeptutor.internal/compassio-el`）；
2. 改 webhook URL 指向该路径；
3. 恢复 `/etc/hosts` 后改回 `http://ci-compassio.xyz/`；
4. 加告警：主分支超过 N 小时没有 PipelineRun，或 webhook 连续失败。

> 用 GitLab API 改 webhook 时，`PUT` 必须同时带上 `token`，否则会把已有 token 清空。

### 坑 5：CI Pod 硬钉 worker03

Pipeline 的 nodeSelector 固定 worker03。worker03 磁盘到 85% 触发 `disk-pressure`，
task pod 无法调度，`promote-gitops` 卡 Pending。

**修复**：去掉硬钉，改用节点亲和/资源请求，或给 CI 单独节点池；同时加磁盘水位告警。

### 坑 6：SSH 隧道是单点

早期 GitLab webhook 通过 `ssh -R 18080` 隧道到集群，隧道一断 CI 全停。
后来改为内网直连（GitLab 主机加 `10.0.0.0/24 via 192.168.67.156` 路由），
Tailscale 退居备用。

**教训**：交付链路的入口不能依赖一条人工维护的隧道。

### 坑 7：docs-only 提交也触发全量构建

用 `check-changes` Task 判断变更路径；只改 `docs/` 时跳过 build/promote。
否则每次改文档都构建镜像，浪费时间和 Harbor 存储。

### 坑 8：rootless BuildKit 的权限

`buildkitd` 用 rootless 模式时，需要正确的 `securityContext`、`/var/lib/buildkit` 权限、
以及 `--oci-worker-no-process-sandbox` 等参数；否则会报 `permission denied` 或
`failed to mount`。

### 坑 9：Tekton Operator 版本选错会降级 Pipelines

GCS 的 `latest` 是旧的；v0.77.0 的 Operator 会把已装的 Pipelines 降级。最终选 v0.81.3，
并确认它支持的 Pipelines/Triggers/Dashboard/Pruner 版本矩阵。**不要用 `latest` 升 Operator。**

### 坑 10：`prune: false` 不是“不删除”，而是“不自动删”

ArgoCD Application 的 `prune: false` 只阻止同步时删除 Git 里已移除的资源；
手工删 CRD/Namespace 仍会级联删除。Tekton 这类有大量 CR 的组件，建议先 `prune: false`，
确认资源归属后再开。

### 坑 11：只保留 1 天把排障证据也删了

早期 `cicd-cleanup` 只留 1 天，PipelineRun/TaskRun/Pod/PVC 全被清掉，
失败构建无法回看。生产应按成功/失败分级：成功 7–30 天，失败 30–90 天，
长期审计用 Tekton Results。

### 坑 12：Open WebUI 的 `images:` 写进了 base

Kustomize 的 `images:` 如果写在 `base/kustomization.yaml`，所有 overlay 都会被强制同一个 tag，
CI 改 `overlays/prod` 不生效。**`images:` 只能出现在 overlay**，base 只保留资源定义。

## 修复关键

1. **先让链路可见**：EventListener status、PipelineRun、TaskRun、webhook 投递记录，四处对齐；
2. **再保证可重复**：Task 镜像/版本固定，repo 与集群一致，构建参数不靠手工；
3. **CA 两侧都配**：daemon + client（`SSL_CERT_FILE`）；
4. **去掉单点**：隧道→直连，单节点→可调度，单副本→多副本（至少 EL/controller）；
5. **加质量门禁**：`check-changes`、镜像扫描、构建失败告警、webhook 失败告警；
6. **GitOps 闭环**：CI 只改 GitOps 仓 tag，ArgoCD 负责部署，禁止 CI 直接改集群。

7. **Tekton 迁移顺序**：备份 → 选 Operator 版本 → 装 Operator（`prune: false`）→ 建 `TektonConfig`
   → 验证现有 Pipeline/Task 仍在 → 删旧清理 CronJob → 开 Pruner；
8. **保留策略按环境分级**：实验 7–30 天，生产成功 30–90 天、失败更久，审计用 Results；
9. **每次改 Kustomize 先 render**：`kubectl kustomize overlays/prod` 确认 image tag 真的变了。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [ci-cd-architecture-and-gitops.md](notes/ci-cd-architecture-and-gitops.md) | GitOps/CI-CD 架构、配置分析、改进建议 |
| [ci-cd-pipeline-end-to-end.md](notes/ci-cd-pipeline-end-to-end.md) | 从 push 到上线的全链路逐步详解 |
| [buildkit-troubleshooting.md](notes/buildkit-troubleshooting.md) | BuildKit 起不来、Kaniko 漂移、客户端 CA 根因 |
| [ci-webhook-recovery.md](notes/ci-webhook-recovery.md) | Webhook 静默中断 3 天的定位与恢复 |
| [ci-cd-operations-manual.md](notes/ci-cd-operations-manual.md) | CI/CD 运维手册 |
| [webhook-direct-and-tunnel-retirement.md](notes/webhook-direct-and-tunnel-retirement.md) | 直连 Webhook 与 SSH 隧道退休 |
| [tekton-operator-migration-2026-11-07.md](notes/tekton-operator-migration-2026-11-07.md) | Tekton standalone → Operator v0.81.3 + GitOps 执行记录 |
| [tekton-history-retention-2026-11-06.md](notes/tekton-history-retention-2026-11-06.md) | Tekton 历史保留：TTL 不存在、CronJob、Operator Pruner、Results |
| [openwebui-cicd-gitops.md](notes/openwebui-cicd-gitops.md) | Open WebUI 全链路 CI/CD + GitOps 建设 |
| [openwebui-ops-runbook.md](notes/openwebui-ops-runbook.md) | Open WebUI 项目/集群运维手册与历史记录 |
| [tekton-platform-gitops-readme.md](notes/tekton-platform-gitops-readme.md) | Tekton 平台 GitOps 仓库的目录、版本、安装顺序与保留策略 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/tekton/01-tasks.yaml](assets/tekton/01-tasks.yaml) | clone/build/promote Task |
| [assets/tekton/02-pipeline.yaml](assets/tekton/02-pipeline.yaml) | Pipeline DAG |
| [assets/tekton/03-trigger.yaml](assets/tekton/03-trigger.yaml) | TriggerBinding/Template |
| [assets/tekton/04-eventlistener.yaml](assets/tekton/04-eventlistener.yaml) | EventListener + GitLab interceptor |
| [assets/tekton/05-argocd-application.yaml](assets/tekton/05-argocd-application.yaml) | ArgoCD Application |
| [assets/tekton/06-buildkit.yaml](assets/tekton/06-buildkit.yaml) | BuildKit daemon/Service/CA |
| [assets/tekton/07-cleanup.yaml](assets/tekton/07-cleanup.yaml) | 清理任务 |
| [assets/tekton/08-check-changes.yaml](assets/tekton/08-check-changes.yaml) | docs-only 变更跳过构建 |
| [assets/tekton/99-kaniko-tasks.yaml.bak](assets/tekton/99-kaniko-tasks.yaml.bak) | 回滚用的 Kaniko 版本 |
| [assets/tekton-operator/](assets/tekton-operator/) | Operator release、TektonConfig、两个 ArgoCD Application |
| [assets/tekton-migration-backup-2026-11-07/](assets/tekton-migration-backup-2026-11-07/) | 迁移前 CR/CRD/清理任务备份（Secret 已剔除） |
| [assets/openwebui/](assets/openwebui/) | Open WebUI 的 Tekton Task/Pipeline、Runner、Kustomize（凭据已脱敏） |
| [scripts/tekton_retention_audit.py](scripts/tekton_retention_audit.py) | 只读统计 PipelineRun/TaskRun 数量、年龄、Pruner 状态 |
| [scripts/setup-containerd-harbor.sh](scripts/setup-containerd-harbor.sh) | 节点 containerd 信任 Harbor CA 的配置脚本 |

```bash
# 查看一次 PipelineRun 的完整链路
kubectl -n cicd get pipelinerun --sort-by=.metadata.creationTimestamp
kubectl -n cicd get taskrun -l tekton.dev/pipelineRun=<run> -o wide
kubectl -n cicd logs <taskrun-pod> -c step-build

# 验证 EventListener
kubectl -n cicd get el -o yaml
kubectl -n cicd get svc | grep el-
```

> Tekton YAML 中的 GitLab/Harbor 地址、token、webhook secret 已脱敏。
> 使用前替换成你的环境，并确保 `X-Gitlab-Token` 校验开启。
