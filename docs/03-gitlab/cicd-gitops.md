# GitLab CI/CD 到 GitOps：Runner + Tekton + Harbor + ArgoCD

## 当时的情况

本环境的目标是：

```text
GitLab push -> 构建镜像 -> 推 Harbor -> 更新 GitOps 仓库 tag -> ArgoCD 同步
```

但有一个硬限制：

> GitLab 在 `192.168.67.0/24`，Kubernetes 集群在 `10.0.0.0/24`，
> 两者之间没有路由。GitLab 无法直接访问集群内的 Tekton EventListener。

因此没有采用“GitLab Webhook 触发 EventListener”的常规方案，而是：

```text
GitLab Push
  -> 集群内 GitLab Runner（Kubernetes executor）轮询任务
  -> Runner 用 Pod 的 ServiceAccount token 调 K8s API
  -> 创建 Tekton PipelineRun（cicd namespace）
  -> Tekton: git-clone -> build-and-push（Kaniko）-> update-gitops-tag
  -> ArgoCD 检测 GitOps 仓库变化并同步
```

## 主要概念与原理

### 1. GitLab Runner

| 项 | 实际值 |
|---|---|
| Runner | `openwebui-k8s-runner` |
| 类型 | project_type（项目级） |
| 状态 | active |
| Tag | `cicd` |
| Executor | `kubernetes` |
| Namespace | `gitlab-runner` |
| Helper image | `192.168.67.202:8443/openwebui/gitlab-runner-helper:x86_64-v17.8.3` |
| imagePullSecrets | `harbor-auth` |
| 配置 | ConfigMap `gitlab-runner-config` 的 `runners.toml` |

Runner token 在 ConfigMap 中（本文不展示）。

### 2. `.gitlab-ci.yml` 实际结构

openwebui 的 CI 只做一件事：**触发 Tekton**。

```yaml
stages:
  - trigger

variables:
  K8S_NS: "cicd"
  PIPELINE_NAME: "open-webui-cicd"
  K8S_API: "https://kubernetes.default.svc"

trigger-tekton:
  stage: trigger
  image: 192.168.67.202:8443/openwebui/gitlab-runner:alpine-v17.8.3
  tags:
    - cicd
  script:
    - |
      TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
      CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      # 生成 PipelineRun JSON，POST 到 K8s API
      # params: git-url / git-revision / image-repository / image-tag
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: on_success
    - when: never
```

关键参数：

```text
git-url          http://192.168.67.201/digitalsupply/openwebui.git
git-revision     $CI_COMMIT_SHA
image-repository 192.168.67.202:8443/openwebui/open-webui
image-tag        $CI_COMMIT_SHORT_SHA
workspace        PVC 10Gi, storageClassName=nfs-sc
serviceAccount   pipeline
```

> Runner 镜像里没有 `kubectl`，所以脚本直接用 Pod 的 ServiceAccount token
> 调 Kubernetes API，而不是 `kubectl create`。

### 3. Tekton 流水线

`cicd` namespace 里实际有：

```text
pipeline: china-study-free-cicd
pipeline: compassio-cicd
pipeline: deeptutor-cicd
pipeline: open-webui-cicd

task: git-clone
task: build-and-push
task: update-gitops-tag
task: china-study-free-build-push / check-changes / update-gitops
task: compassio-build-push / check-changes / update-gitops
task: deeptutor-build-push / check-changes / update-gitops

serviceaccount: pipeline
```

`open-webui-cicd` 的 task 链：

| Task | 作用 |
|---|---|
| `clone` | `git-clone`，拉 GitLab 仓库 |
| `build-push` | `build-and-push`，Kaniko 构建并推 Harbor |
| `promote-gitops` | `update-gitops-tag`，更新 GitOps 仓库的 `newTag` |

Kaniko 镜像本身也来自 Harbor：

```text
192.168.67.202:8443/openwebui/kaniko:v1.23.2
```

### 4. 更新 GitOps tag

`update-gitops-tag` 的核心逻辑：

```sh
cd "$(workspaces.source.path)"
DIR="${GITOPS_SUBDIR}"

# 用 GITOPS_URL + GIT_USERNAME + GIT_PASSWORD 克隆/更新 GitOps 仓库
git clone "$AUTH_URL" "$DIR"
cd "$DIR"

# 把 prod overlay 里的 newTag 改成新镜像 tag
sed -i "s#^\( *newTag:\).*#\1 ${IMAGE_TAG}#" "$KUSTOMIZE_PATH"

git add "$KUSTOMIZE_PATH"
git commit -m "$COMMIT_MSG"
git push origin HEAD:main
```

提交后：

```text
GitOps repo main 更新 -> ArgoCD 检测到差异 -> 自动 sync -> 新镜像上线
```

实际 CI 更新的是 `openwebui-gitops` 的 prod overlay（`newTag` 行）。

### 5. 实际镜像与拉取

集群中有这些 Harbor 镜像：

```text
192.168.67.202:8443/china-study-free/web:694f79f
192.168.67.202:8443/compassio/backend:05f030...
192.168.67.202:8443/compassio/frontend:05f030...
192.168.67.202:8443/deeptutor/deeptutor:870f2d...
192.168.67.202:8443/openwebui/gitlab-runner:alpine-v17.8.3
192.168.67.202:8443/openwebui/open-webui:<short-sha>
```

imagePullSecret：

| namespace | Secret |
|---|---|
| china-study-free | `harbor-auth` |
| cicd | `harbor-auth` |
| compassio | `harbor-auth` |
| gitlab-runner | `harbor-auth` |
| open-webui | `harbor-pull` |

> 这两个 Secret 实际都使用 Harbor 的 `admin` 账号（见 [04 Harbor 账号](harbor-accounts-registry.md) / [05 配置与坑](harbor-config-pitfalls.md)）。
> 推荐改成项目级 Robot 账号。

## 踩坑点

### 坑 1：以为 GitLab 能直接 Webhook 到 Tekton

网段没有路由。正确做法是集群内 Runner 轮询 + 集群内创建 PipelineRun。

### 坑 2：Runner 镜像没有 kubectl

在 `trigger-tekton` 脚本里用 `kubectl create` 会直接失败。
实际是读 `/var/run/secrets/kubernetes.io/serviceaccount/token`，
用 `curl` 调 K8s API。

### 坑 3：PipelineRun 不能用固定 name

用 `metadata.generateName` 让 K8s 生成唯一名字；
如果硬写 `metadata.name`，重复触发会 409。

### 坑 4：`newTag` sed 改错文件

如果 `KUSTOMIZE_PATH` 指向错误的 overlay，脚本会“执行成功但没变化”，
ArgoCD 也不会更新。必须确认改的是目标 overlay 的 `newTag` 行。

### 坑 5：Harbor 证书/凭据

Runner、Kaniko、helper image 都要从 Harbor 拉镜像：

- 自签证书需要节点/客户端信任，或配置 insecure registry；
- imagePullSecret 必须存在，否则 Pod 卡在 `ImagePullBackOff`；
- 用 admin 做 pull secret 权限过大，建议 Robot。

### 坑 6：CI 变量没有集中管理

当前没有 GitLab 项目/组级 CI Variable；敏感值容易散落在 YAML/脚本里。
应该用 masked/protected variables 或 K8s Secret。

## 修复关键 / 建议

1. **保持 Runner 在集群内**，不要试图从 GitLab 直接回调集群；
2. **Runner 使用专用 ServiceAccount**，只允许创建 PipelineRun；
3. **Harbor 用 Robot 账号**，区分 pull-only 和 push；
4. **Kaniko/helper 镜像固定 digest**，避免 tag 漂移；
5. **GitOps 更新只改目标 overlay 的 newTag**，并加提交信息；
6. **CI 变量 masked/protected**，不要把 token 写进 YAML；
7. **保护 main 分支**，CI 只在 main 上触发部署。

## 验证命令

```bash
# Runner 配置（token 已脱敏）
kubectl -n gitlab-runner get cm gitlab-runner-config -o json \
  | jq -r '.data["runners.toml"]'

# Tekton pipeline/task
kubectl -n cicd get pipeline,task

# 最近 PipelineRun
kubectl -n cicd get pipelinerun --sort-by=.metadata.creationTimestamp | tail -10

# 查看某个 PipelineRun
kubectl -n cicd get pipelinerun <name> -o yaml

# 手动触发（示例）
tkn pipeline start open-webui-cicd -n cicd \
  -p git-url=http://192.168.67.201/digitalsupply/openwebui.git \
  -p git-revision=<sha> \
  -p image-repository=192.168.67.202:8443/openwebui/open-webui \
  -p image-tag=manual-test
```
