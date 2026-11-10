# Open WebUI CI/CD + GitOps 流水线建设文档

> 构建日期：2026-10-13
> 目标：`git push` → 自动构建镜像 → 推送 Harbor → 自动同步 K8s → 通过 Traefik 对外暴露服务
>
> **当前状态（2026-10-27）：应用与 frpc 已暂停为 0 副本，PVC / 配置 / 镜像保留。**
> 最新现状、全量历史、运维命令与风险清单见同目录
> [`OPENWEBUI-OPS-RUNBOOK.md`](openwebui-ops-runbook.md)。
> 注意：本文 §5 含明文凭据，分享前请脱敏并轮换凭据。

---

## 目录

1. [总体架构](#1-总体架构)
2. [环境现状与拓扑](#2-环境现状与拓扑)
3. [关键网络约束（选型的核心依据）](#3-关键网络约束选型的核心依据)
4. [仓库与制品规划](#4-仓库与制品规划)
5. [凭据与密钥管理](#5-凭据与密钥管理)
6. [基础镜像的 Harbor 预置](#6-基础镜像的-harbor-预置)
7. [节点 containerd 配置](#7-节点-containerd-配置)
8. [GitOps 仓库（Kustomize）](#8-gitops-仓库kustomize)
9. [Argo CD 配置](#9-argo-cd-配置)
10. [Tekton 流水线](#10-tekton-流水线)
11. [GitLab Runner（触发器）](#11-gitlab-runner触发器)
12. [服务暴露与 DNS](#12-服务暴露与-dns)
13. [端到端验证结果](#13-端到端验证结果)
14. [日常使用](#14-日常使用)
15. [排障手册](#15-排障手册)
16. [注意事项与已知限制](#16-注意事项与已知限制)
17. [安全建议](#17-安全建议)

---

## 1. 总体架构

```
                          ┌──────────────────────────────────────┐
   git push ─────────────▶│ GitLab  192.168.67.201:80            │
   (digitalsupply/        │  项目: openwebui (源码)              │
    openwebui)            │  项目: openwebui-gitops (Kustomize)  │
                          └──────────────┬───────────────────────┘
                                         │ ① Runner 主动轮询（出站）
                                         ▼
                          ┌──────────────────────────────────────┐
                          │ GitLab Runner (集群内, k8s executor) │
                          │  ns: gitlab-runner                   │
                          └──────────────┬───────────────────────┘
                                         │ ② 调用 Tekton API 创建 PipelineRun
                                         ▼
     ┌───────────────────────────────────────────────────────────────────────┐
     │ Tekton Pipeline: open-webui-cicd      (ns: cicd)                      │
     │                                                                        │
     │   [clone]  ─▶  [build-push]  ─▶  [promote-gitops]                     │
     │    git clone    Kaniko 构建          改写 overlays/prod/kustomization │
     │    from GitLab  推送到 Harbor          newTag 并 commit/push           │
     └────────┬───────────────────────────────────────────┬───────────────────┘
              │ ③ push 镜像                                │ ④ commit GitOps 仓库
              ▼                                            ▼
     ┌──────────────────────┐              ┌──────────────────────────────────┐
     │ Harbor               │              │ GitLab: openwebui-gitops         │
     │ 192.168.67.202:8443  │              │  overlays/prod → newTag: <sha>   │
     │ project: openwebui   │              └──────────────┬───────────────────┘
     └──────────────────────┘                             │ ⑤ 自动检测（poll ~3min）
                                                          ▼
                                          ┌──────────────────────────────────┐
                                          │ Argo CD (argocd ns)              │
                                          │  auto-sync + self-heal + prune   │
                                          └──────────────┬───────────────────┘
                                                          │ ⑥ apply
                                                          ▼
                                          ┌──────────────────────────────────┐
                                          │ K8s ns: open-webui               │
                                          │  Deployment / Service / Ingress  │
                                          │  PVC 10Gi (ceph-rbd-sc)          │
                                          └──────────────┬───────────────────┘
                                                          │ ⑦ HTTP
                                                          ▼
                                          ┌──────────────────────────────────┐
                                          │ Traefik (LB 10.0.0.252)         │
                                          │  http://cngpt.ccwu.cc            │
                                          └──────────────────────────────────┘
```

**设计要点：集群永远是 Git 的追随者。** 流水线不直接 `kubectl apply` 变更，
而是提交一次 Git commit，由 Argo CD 拉取并同步。因此任何时刻集群里运行的版本
都能从 Git 历史中精确复现。

---

## 2. 环境现状与拓扑

| 组件 | 地址 | 版本 / 说明 |
|------|------|-------------|
| GitLab | `192.168.67.201` | Omnibus **gitlab-ce 19.4.2**（Ubuntu 24.04, ubuntu01） |
| Harbor | `192.168.67.202:8443` | **v2.14.5**（Ubuntu 24.04, ubuntu02） |
| K8s 控制面 | `10.0.0.61`(m01) / `10.0.0.120`(master02) / `10.0.0.121`(master01) | **v1.35.9**, containerd 2.3.2 |
| K8s 工作节点 | `10.0.0.122/123/124` (worker01/02/03) | 同上 |
| Argo CD | argocd ns | **v3.5.3**（既有，本次新建 Application） |
| Tekton | tekton-pipelines ns | **v1.6.0** + Triggers + Dashboard（既有） |
| Traefik | traefik ns | LoadBalancer，`10.0.0.252`，ingressClass `traefik` |
| MetalLB | metallb-system | pool `10.0.0.252-253`（tailscale pool） |
| 存储类 | `ceph-rbd-sc`（RBD）、`nfs-sc`（NFS） | 本方案 PVC 用 `ceph-rbd-sc` |

**说明：**
- GitLab 的 Web/API 实际监听在 `:8088`，宿主机通过 iptables/nftables 的
  `REDIRECT` 把 `:80` 透明转到 `8088`。因此**对外统一使用 `http://192.168.67.201`
  （80 端口）**，所有配置文件中都不出现 `8088`。
- 集群里 `cicd` ns 中原本存在一套演示用流水线（`tekton-demo-cicd`），指向已下线
  的 `10.0.0.41`(旧 Harbor) 与 `10.0.0.200`(旧 GitLab)，凭证已失效。
  本次新增的流水线使用独立命名（`open-webui-cicd`），与旧对象互不干扰，
  旧对象保留未删除。

---

## 3. 关键网络约束（选型的核心依据）

这是整个方案选型的**决定性因素**，请务必理解：

### 3.1 GitLab 无法入站访问集群 ❌

```
$ ssh root@192.168.67.201 'curl -m5 http://10.0.0.252/'
10.0.0.252:80 -> 000        # 无响应
$ ssh root@192.168.67.201 'curl -m5 http://10.0.0.61:30080/'
10.0.0.61:30080 -> 000
$ ssh root@192.168.67.201 'nc -z 10.0.0.61 6443'
closed
```

GitLab 主机路由表仅有 `default via 192.168.67.1`，到 `10.0.0.0/24` 无有效路径
（能 ping 通 `10.0.0.1` 是教师机双网卡造成的假象）。因此：

> **GitLab → Tekton EventListener 的 Webhook 方案在本网络下不可行。**

### 3.2 出站方向完全正常 ✅

```
集群 → GitLab (192.168.67.201:80)        ✅
集群 → Harbor (192.168.67.202:8443)      ✅
集群 → PyPI / npm / ghcr.io / quay.io    ✅
```

### 3.3 由此确定的触发方案

| 方案 | 可行性 | 结论 |
|------|--------|------|
| GitLab Webhook → EventListener | ❌ 网络不通 | 放弃 |
| 教师机做 Webhook 中继 | ⚠️ 可行但增加单点 | 备选 |
| **集群内 GitLab Runner 主动轮询 → 调 Tekton API** | ✅ 仅需出站 | **采用** |

Runner 运行在集群内部，由它**主动向 GitLab 轮询**取任务（GitLab 无需入站），
拿到任务后用 ServiceAccount 令牌直接向 Tekton API 创建 `PipelineRun`。
这是 GitLab 官方推荐的 runner-k8s-executor 模式，网络要求最低、最稳定。

### 3.4 镜像仓库不可达清单

| 站点 | 状态 | 影响与对策 |
|------|------|-----------|
| `registry-1.docker.io` / `hub.docker.com` | ❌ 全网不可达 | 基础镜像预置到 Harbor |
| `gcr.io` | ❌ 不可达 | Kaniko 预置到 Harbor；Tekton webhook 需注入 CA |
| `registry.gitlab.com` | ❌ 不可达 | runner-helper 预置到 Harbor |
| `github.com` | ❌ 不可达 | 见 §16 Dockerfile 三处适配 |
| `download.cypress.io` | ❌ 不可达 | `CYPRESS_INSTALL_BINARY=0` |
| `cdn.jsdelivr.net` | ❌ 不可达 | 前端改用 `vite build` 直出 |
| `huggingface.co` | ❌ 不可达 | 构建 `USE_SLIM=true` 变体 |
| `pypi.org` / `files.pythonhosted.org` | ✅ 200 | 直接使用 |
| `registry.npmjs.org` | ✅ 200 | 直接使用 |
| `ghcr.io` / `quay.io` / `mcr.microsoft.com` / `registry.k8s.io` | ✅ 可达 | 已通过节点镜像加速使用 |

---

## 4. 仓库与制品规划

### GitLab 项目

| 项目 | 路径 | 用途 | 可见性 |
|------|------|------|--------|
| 应用源码 | `digitalsupply/openwebui` | Open WebUI 源码 + `.gitlab-ci.yml` + `Dockerfile.harbor` | private |
| GitOps 配置 | `digitalsupply/openwebui-gitops` | Kustomize base/overlay | private |

本地仓库的 remote 已重整：

```bash
git remote rename origin upstream     # 保留上游 open-webui/open-webui
git remote add origin http://root:<PAT>@192.168.67.201/digitalsupply/openwebui.git
```

### 镜像命名规范

```
192.168.67.202:8443/openwebui/open-webui:<git-commit-sha>
```

**Tag = 提交短 SHA**，不可变、可追溯。Harbor 中另有基础镜像与工具镜像：

| 镜像 | 用途 |
|------|------|
| `openwebui/open-webui:<sha>` | 业务镜像 |
| `openwebui/node:22-alpine3.20` | 前端构建基础镜像 |
| `openwebui/python:3.11-slim-bookworm` | 后端运行基础镜像 |
| `openwebui/uv:0.12.10` | uv 包管理器（COPY --from 用） |
| `openwebui/kaniko:v1.23.2` | 构建器 |
| `openwebui/gitlab-runner:alpine-v17.8.3` | Runner |
| `openwebui/gitlab-runner-helper:x86_64-v17.8.3` | Runner 作业 helper |
| `openwebui/cache` | Kaniko 构建缓存 |

---

## 5. 凭据与密钥管理

> ⚠️ 以下凭据在建设过程中生成，明文记录于此以便运维。**生产环境请按 §17 轮换。**

| 凭据 | 值 | 存放位置 |
|------|-----|----------|
| GitLab root 初始密码 | 见 GitLab `/etc/gitlab/initial_root_password` | GitLab 主机 |
| GitLab PAT（`api` scope） | `<redacted-gitlab-pat>` | `.secrets/env.sh`、argocd/gitlab-auth secret |
| GitLab Runner token | `glrt-...`（存于 `/root/.gitlab_runner_glrt`） | runner ConfigMap |
| Harbor admin | `admin` / `<redacted-harbor-admin-password>` | 各 secret |
| Harbor robot | `robot$openwebui+ci-pipeline` / `<redacted-harbor-robot-password>` | 备用 |

集群内 Secret 分布：

| Secret | Namespace | 内容 |
|--------|-----------|------|
| `gitlab-auth` | `cicd` | `username`/`password`/`token`/`git-url`/`gitops-url` |
| `harbor-auth` | `cicd` | dockerconfigjson（Harbor admin） |
| `harbor-auth` | `gitlab-runner` | dockerconfigjson |
| `gitlab-openwebui-gitops` | `argocd` | Argo CD 拉取 GitOps 仓库的凭据 |
| `harbor-pull` | `open-webui` | kubelet 拉取镜像用（由 GitOps 管理） |
| `open-webui-config` | `open-webui` | `WEBUI_SECRET_KEY` |

本地备份：`/root/openwebuicicd/.secrets/env.sh`（`chmod 600`）。

---

## 6. 基础镜像的 Harbor 预置

由于 Docker Hub / gcr.io 不可达，构建所需基础镜像统一从可达镜像加速源同步进 Harbor。

```bash
# 前提：DOCKER_CONFIG 指向含 Harbor 凭据的 config.json
export DOCKER_CONFIG=/root/.crane-auth

crane copy --insecure --platform linux/amd64 \
  docker.1ms.run/library/node:22-alpine3.20 \
  192.168.67.202:8443/openwebui/node:22-alpine3.20

crane copy --insecure --platform linux/amd64 \
  docker.1ms.run/library/python:3.11-slim-bookworm \
  192.168.67.202:8443/openwebui/python:3.11-slim-bookworm

crane copy --insecure --platform linux/amd64 \
  ghcr.io/astral-sh/uv:0.12.10 \
  192.168.67.202:8443/openwebui/uv:0.12.10

crane copy --insecure --platform linux/amd64 \
  gcr.m.daocloud.io/kaniko-project/executor:v1.23.2 \
  192.168.67.202:8443/openwebui/kaniko:v1.23.2

crane copy --insecure --platform linux/amd64 \
  docker.1ms.run/gitlab/gitlab-runner:alpine-v17.8.3 \
  192.168.67.202:8443/openwebui/gitlab-runner:alpine-v17.8.3

crane copy --insecure --platform linux/amd64 \
  docker.1ms.run/gitlab/gitlab-runner-helper:x86_64-v17.8.3 \
  192.168.67.202:8443/openwebui/gitlab-runner-helper:x86_64-v17.8.3
```

> **坑点记录：** `crane` 在处理含 `$` 的 Harbor 机器人账号
> （`robot$openwebui+ci-pipeline`）时会出现 401（其凭据处理会把 `$` 处理异常）。
> 预置镜像时改用 `admin` 账号即可；集群内 Kaniko 走 dockerconfigjson，不受影响。

---

## 7. 节点 containerd 配置

Harbor 使用**自签名证书**（`CN=192.168.67.202, O=Harbor`），所有 6 个节点均需
配置 `skip_verify` 才能拉取。脚本：`scripts/setup-containerd-harbor.sh`

```bash
# /etc/containerd/certs.d/192.168.67.202:8443/hosts.toml
server = "https://192.168.67.202:8443"

[host."https://192.168.67.202:8443"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
```

批量下发：

```bash
for node in 10.0.0.61 10.0.0.120 10.0.0.121 10.0.0.122 10.0.0.123 10.0.0.124; do
  scp scripts/setup-containerd-harbor.sh root@$node:/tmp/
  ssh root@$node 'bash /tmp/setup-harbor.sh'
done
```

> 注意：脚本会 `systemctl restart containerd`。已在 6 个节点全部执行并确认节点
> 恢复 `Ready`。**新增节点时必须重复此步骤。**

### Tekton 信任 Harbor CA

Tekton webhook 在创建 Pod 前会解析 step 镜像的 digest，必须能校验 Harbor 证书。
做法是导出证书并挂载进 Tekton 组件：

```bash
echo | openssl s_client -connect 192.168.67.202:8443 -servername 192.168.67.202 2>/dev/null \
  | openssl x509 > deploy/cicd/harbor-ca.crt

kubectl create configmap harbor-ca --from-file=ca.crt=deploy/cicd/harbor-ca.crt -n tekton-pipelines
kubectl create configmap harbor-ca --from-file=ca.crt=deploy/cicd/harbor-ca.crt -n cicd

# 为 tekton-pipelines-webhook 与 tekton-pipelines-controller 挂载
kubectl -n tekton-pipelines patch deploy tekton-pipelines-webhook --type=json -p '[
  {"op":"add","path":"/spec/template/spec/volumes",
   "value":[{"name":"harbor-ca","configMap":{"name":"harbor-ca","defaultMode":420}}]},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts",
   "value":[{"name":"harbor-ca","mountPath":"/etc/ssl/certs/harbor-ca.crt","subPath":"ca.crt","readOnly":true}]}
]'
# controller 同理（其 volumes 数组已存在，需分两次 patch）
kubectl -n tekton-pipelines rollout restart deploy/tekton-pipelines-webhook deploy/tekton-pipelines-controller
```

> ⚠️ **Tekton 升级后这些 patch 会丢失**，需重新执行。

---

## 8. GitOps 仓库（Kustomize）

```
openwebui-gitops/
├── README.md
├── argocd/                      # Argo CD 自身配置（备份用，非 Argo CD 管理范围）
│   ├── application.yaml
│   └── repo-secret.yaml
├── base/
│   ├── 00-namespace-and-secrets.yaml    # ns / SA / harbor-pull / imagePullSecrets
│   ├── 10-open-webui.yaml              # PVC / Secret / Deployment / Service / Ingress
│   └── kustomization.yaml
└── overlays/prod/
    └── kustomization.yaml      # ← CI 改写 newTag 的唯一位置
```

### 关键设计：`images:` 只能出现在 overlay

```yaml
# base/kustomization.yaml —— 故意不写 images:
labels:
  - includeSelectors: false
    pairs:
      app.kubernetes.io/part-of: openwebui-pipeline
      app.kubernetes.io/managed-by: argocd
```

> 🔴 **踩坑记录：** 最初 base 和 overlay 都写了 `images:`，结果 Kustomize 先执行
> base 的 transformer 再执行 overlay 的，最终生效的是 **base 的 `latest`**，
> 导致 CI 推了新 tag 但集群一直跑 `latest`。**transformer 是"最后一个赢"，
> 因此只有最外层 overlay 能定义镜像。** 现已从 base 移除并注释说明。

### 渲染验证

```bash
kubectl kustomize overlays/prod | grep 'image:'
# → image: 192.168.67.202:8443/openwebui/open-webui:a077c804
```

### 工作负载规格

| 项 | 值 |
|----|-----|
| 副本 | 1（Open WebUI 为有状态应用，PVC 为 RWO，不易水平扩展） |
| 策略 | `Recreate`（避免新旧 Pod 争抢 RWO 卷） |
| 端口 | 8080（容器内），Service 80 → 8080 |
| 存储 | PVC 10Gi，`ceph-rbd-sc`，挂载 `/app/backend/data` |
| CPU | request 500m / limit 2 |
| 内存 | request 2Gi / limit 8Gi |
| 探针 | startup(30s×30) → readiness(/health,10s) → liveness(/health,30s) |
| 环境变量 | `DATA_DIR`、`WEBUI_URL=http://cngpt.ccwu.cc`、`OFFLINE_MODE=true`、`WEBUI_AUTH=True`、关闭遥测 |

`OFFLINE_MODE=true` 是必要的：本环境无法访问 huggingface.co，关闭后启动时跳过
插件依赖安装（见运行日志 `Offline mode enabled, skipping installation of requirements`）。

---

## 9. Argo CD 配置

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: open-webui
  namespace: argocd
spec:
  source:
    repoURL: http://192.168.67.201/digitalsupply/openwebui-gitops.git
    targetRevision: main
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: open-webui
  syncPolicy:
    automated:
      prune: true          # 删除 GitOps 中已移除的资源
      selfHeal: true       # 人工改动会被自动纠正回 Git 状态
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

仓库凭据 Secret（**必须**带 `argocd.argoproj.io/secret-type: repository` 标签）：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-openwebui-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://192.168.67.201/digitalsupply/openwebui-gitops.git
  username: root
  password: <PAT>
```

> 🔴 **重大踩坑记录（务必了解）：** 凭据正确（`git ls-remote` 在 repo-server
> Pod 内成功），但 Argo CD 持续报
> `authentication required: HTTP Basic: Access denied`。
> 根因是 **Argo CD 把仓库凭据缓存在 Redis 中**，secret 变更后不会失效，
> 重启 Pod 也没用（缓存是共享的）。**解决办法：**
>
> ```bash
> RPASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
> kubectl -n argocd exec deploy/argocd-redis -- redis-cli -a "$RPASS" FLUSHALL
> kubectl -n argocd rollout restart deploy/argocd-repo-server statefulset/argocd-application-controller
> ```
>
> 注意：`redis-cli` 未带 `-a` 时返回 `NOAUTH Authentication required`，**必须带密码**。
> 今后修改仓库凭据请按此流程操作。

---

## 10. Tekton 流水线

位于 `cicd` ns，命名空间 `openwebui-cicd`。流水线图：

```
clone ──▶ build-push ──▶ promote-gitops
```

### Pipeline 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `git-url` | `http://192.168.67.201/digitalsupply/openwebui.git` | 应用仓库 |
| `git-revision` | `main` | 分支 / tag / **commit SHA** |
| `image-repository` | `192.168.67.202:8443/openwebui/open-webui` | 目标仓库 |
| `image-tag` | （必填） | 镜像 tag |

### Task 1：`git-clone`

用 `alpine/git:v2.45.2`，凭据从 `gitlab-auth` secret 通过
`valueFrom.secretKeyRef` 注入环境变量（不落盘、不进日志）。

支持三种 revision：
```sh
# 始终浅克隆默认分支（快），再按需 fetch 精确 commit
git clone --depth 1 --no-single-branch "$AUTH_URL" "$TARGET"
cd "$TARGET"
git fetch --depth 1 origin "$GIT_REVISION" 2>/dev/null \
  && git checkout -q FETCH_HEAD \
  || { git checkout -q "$GIT_REVISION" 2>/dev/null \
       || git checkout -q "origin/$GIT_REVISION"; }
```

> 🔴 **踩坑记录：** CI 传的是 `CI_COMMIT_SHA`，而 `git clone -b <sha>` 只接受
> 分支/tag，`--depth 1` 时报 `Could not find remote branch`。故改为上面的
> "浅克隆默认分支 + fetch 精确 commit" 方案。仓库约 460MB，全量克隆非常慢，
> 务必保持浅克隆。

### Task 2：`build-and-push`

Kaniko（镜像来自 Harbor）：

```yaml
image: 192.168.67.202:8443/openwebui/kaniko:v1.23.2
args:
  - --dockerfile=.../Dockerfile.harbor
  - --context=.../source
  - --destination=$(params.image)
  - --build-arg
  - USE_SLIM=true
  - --insecure            # Harbor 自签名
  - --skip-tls-verify
  - --insecure-pull
  - --cache=true
  - --cache-repo=192.168.67.202:8443/openwebui/cache
  - --single-snapshot
  - --verbosity=info
```

### Task 3：`update-gitops-tag`

```sh
git clone "$AUTH_URL" gitops          # 带凭据克隆 GitOps 仓库
sed -i "s#^\( *newTag:\).*#\1 ${IMAGE_TAG}#" overlays/prod/kustomization.yaml
git commit -m "ci(open-webui): promote image tag ${IMAGE_TAG}"
git push origin HEAD:main
```

无变更时（`git diff --quiet`）直接退出 0，不产生空提交。

提交身份：`openwebui-cicd-bot <openwebui-cicd-bot@users.noreply.local>`。

---

## 11. GitLab Runner（触发器）

**这是绕过 §3.1 网络限制的关键组件。**

### 为什么不用 Tekton Triggers

GitLab 无法入站访问集群，Webhook 送不到 EventListener。Runner 在集群内**主动
轮询** GitLab，只需出站连接。

### 部署要点

```yaml
# ns: gitlab-runner，executor = kubernetes
[[runners]]
  executor = "kubernetes"
  url = "http://192.168.67.201"
  token = "glrt-..."
  [runners.kubernetes]
    namespace = "gitlab-runner"
    executor_namespace = "gitlab-runner"
    image_pull_secrets = ["harbor-auth"]
    # registry.gitlab.com 不可达，helper 镜像改用 Harbor 副本
    helper_image = "192.168.67.202:8443/openwebui/gitlab-runner-helper:x86_64-v17.8.3"
    helper_image_pull_policy = "IfNotPresent"
```

### RBAC 关键点（踩坑记录）

k8s executor 把**作业 Pod** 跑在 `executor_namespace` 下、用该 ns 的
**`default` ServiceAccount**，而不是 runner 自己的 SA。因此 RoleBinding
必须同时授权两个身份：

```yaml
subjects:
  - kind: ServiceAccount
    name: default
    namespace: gitlab-runner
  - kind: ServiceAccount
    name: gitlab-runner
    namespace: gitlab-runner
```

另需 `pods/exec`、`pods/attach` 权限（attach 策略执行脚本所需），
否则报 `cannot create resource "pods/exec"`。

### GitLab 19 注册令牌

GitLab 19 已废弃 instance/project 传统 `runners_token`（`valid_runner_registrars`
仅为 `['project','group']`）。正确方式是调 API 预注册 runner 并取回 `glrt-` token：

```bash
curl -X POST "$GITLAB_URL/api/v4/user/runners" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --data-urlencode "runner_type=project_type" \
  --data-urlencode "project_id=1" \
  --data-urlencode "description=openwebui-k8s-runner" \
  --data-urlencode "paused=false" \
  --data-urlencode "run_untagged=false" \
  --data-urlencode "tag_list=cicd"
# → {"id":3,"token":"glrt-...","token_expires_at":null}
```

> 注意：**`glrt-` token 只在创建时返回一次**，之后 API 不再显示，需妥善保存。
> 另外该 token 一旦连续 3 次健康检查失败，GitLab 会**禁用 runner 1 小时**；
> 调试期间反复失败会遇到 `Runner is unhealthy and will be disabled for 1h0m0s`，
> 需等待或删除重建 runner。

### `.gitlab-ci.yml`（在源码仓库中）

该文件**只做一件事**：向 Tekton API POST 一个 PipelineRun。因为 runner 镜像里
没有 `kubectl`，故直接调 CRD 接口：

```bash
TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

curl -sS --cacert "$CACERT" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${K8S_API}/apis/tekton.dev/v1/namespaces/${K8S_NS}/pipelineruns" \
  --data-binary @/tmp/pr.json
```

触发条件：仅 `main` 分支 push。

---

## 12. 服务暴露与 DNS

- **Ingress**：`ingressClassName: traefik`，host `cngpt.ccwu.cc`，path `/`（Prefix）
- **Traefik LB**：`10.0.0.252`（MetalLB `lb-pool-tailscale`）
- **未配置 TLS**（当前 8443 是 Harbor 的，Traefik 未签发该域名证书），
  如需 HTTPS 请用 cert-manager 签发证书后开启

### hosts 映射（已在 7 台主机下发）

```bash
echo "10.0.0.252 cngpt.ccwu.cc" >> /etc/hosts
```

已下发到：6 个 K8s 节点 + teacher 机。

**生产环境建议**改为正式 DNS 解析，届时把 Ingress 的 `host` 改成正式域名即可，
无需改动其它配置。

验证：

```bash
$ curl -I http://cngpt.ccwu.cc/
HTTP/1.1 200 OK
$ curl http://cngpt.ccwu.cc/health
{"status":true}
```

---

## 13. 端到端验证结果

### 最终状态

```
$ kubectl -n argocd get application open-webui -o wide
NAME        SYNC STATUS   HEALTH STATUS   REVISION
open-webui  Synced        Healthy         741a533...

$ kubectl -n open-webui get deploy open-webui -o jsonpath='{.spec.template.spec.containers[0].image}'
192.168.67.202:8443/openwebui/open-webui:a077c804

$ kubectl -n open-webui get pods
open-webui-597749589d-b9psp   1/1   Running   0   10.244.19.106   worker03

$ kubectl -n open-webui get pvc
open-webui-data   Bound   10Gi   RWO   ceph-rbd-sc

$ curl -s http://cngpt.ccwu.cc/health
{"status":true}
```

### 自动化验证记录

| 验证项 | 方法 | 结果 |
|--------|------|------|
| GitLab push 自动触发 | push 提交 | ✅ 自动创建 PipelineRun |
| Tekton 三阶段串联 | `kubectl get pipelinerun` | ✅ Succeeded |
| 镜像推送 Harbor | Harbor API | ✅ `a077c804` 225.4MB |
| GitOps 自动改 tag | GitLab commits | ✅ `ci(open-webui): promote image tag a077c804` |
| Argo CD 自动同步 | 观察 REVISION 变化 | ✅ 自动跟踪 |
| Argo CD 自动检测新提交 | 手动 push 一次 GitOps 提交，不做任何刷新 | ✅ **约 75 秒内自动同步** |
| 服务可用性 | `curl /health` | ✅ 200 `{"status":true}` |

**结论：全自动闭环已打通，`git push` 后无需任何人工干预。**

### 镜像瘦身说明

SLIM 变体镜像 **225.4 MB**（非 SLIM 版因要打包 torch/模型，通常 >2GB）。

---

## 14. 日常使用

### 触发一次构建部署

```bash
cd /root/openwebuicicd/open-webui
# 改代码...
git add .
git commit -m "feat: xxx"
git push origin main
```

之后：
1. GitLab CI 自动触发（看 https://192.168.67.201 流水线）
2. Tekton 构建推送镜像（约 3-10 分钟，缓存命中后更快）
3. 自动提交 GitOps tag
4. Argo CD 约 1-3 分钟内同步上线

### 查看进度

```bash
# Tekton
kubectl -n cicd get pipelineruns -l app.kubernetes.io/part-of=openwebui-cicd
kubectl -n cicd get taskruns -l tekton.dev/pipelineRun=<PR名>

# Kaniko 日志（Pod 已退出时 kubectl logs 取不到，需从节点 containerd 取）
NODE=$(kubectl -n cicd get pod <PR>-build-push-pod -o jsonpath='{.status.hostIP}')
CID=$(kubectl -n cicd get pod <PR>-build-push-pod -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's#containerd://##')
ssh root@$NODE "crictl logs $CID | tail -40"

# Argo CD
kubectl -n argocd get application open-webui -o wide
```

### 手动触发（绕过 GitLab）

```bash
kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: open-webui-manual-
  namespace: cicd
spec:
  pipelineRef: {name: open-webui-cicd}
  taskRunTemplate: {serviceAccountName: pipeline}
  timeouts: {pipeline: 90m0s0s}
  params:
    - {name: git-url, value: "http://192.168.67.201/digitalsupply/openwebui.git"}
    - {name: git-revision, value: main}
    - {name: image-repository, value: "192.168.67.202:8443/openwebui/open-webui"}
    - {name: image-tag, value: manual-$(date +%s)}
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources: {requests: {storage: 10Gi}}
          storageClassName: nfs-sc
EOF
```

### 回滚

```bash
# 方式一：改 GitOps tag（推荐，有 Git 记录）
cd /tmp/openwebui-gitops
sed -i 's/newTag: .*/newTag: <上一个可用tag>/' overlays/prod/kustomization.yaml
git commit -am "rollback: open-webui to <tag>" && git push origin main

# 方式二：Argo CD 回滚到上一版本
kubectl -n argocd patch application open-webui --type=merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}'   # 或在 UI 点 History 回滚
```

### 修改配置（如换域名/副本数）

改 `openwebui-gitops` 仓库 → push → Argo CD 自动生效。**不要**直接
`kubectl edit` Deployment，`selfHeal: true` 会在几分钟内改回去。

---

## 15. 排障手册

### 症状：GitLab push 后没有 Tekton 任务

```bash
# 1. Runner 是否在线
kubectl -n gitlab-runner get pods
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=20
# 2. GitLab CI 是否成功
curl -s -H "PRIVATE-TOKEN: $TOKEN" "$URL/api/v4/projects/1/pipelines?ref=main&per_page=1"
# 3. Runner 在 GitLab 侧是否 online
curl -s -H "PRIVATE-TOKEN: $TOKEN" "$URL/api/v4/runners/all"
```

| 日志关键字 | 原因 | 处理 |
|-----------|------|------|
| `403 Forbidden` on `/api/v4/jobs/request` | runner token 无效/被禁用 | 重新注册 runner 取 `glrt-` |
| `only http or https scheme supported` | config 缺 `url` | 补 `url = "http://192.168.67.201"` |
| `cannot create resource "pods/exec"` | RBAC 缺 pods/exec | 补 `pods/exec`,`pods/attach` |
| `ImagePullBackOff` helper | registry.gitlab.com 不可达 | 确认 `helper_image` 指向 Harbor |

### 症状：TaskRun 卡在 PodCreationFailed

看 `status.conditions[0].message`：

| 报错关键字 | 原因 | 处理 |
|-----------|------|------|
| `dial tcp ... gcr.io ... i/o timeout` | Tekton 无法解析 step 镜像 | 把镜像换成 Harbor 里的副本 |
| `x509: certificate signed by unknown authority` | Harbor 自签名 | 注入 CA 到 tekton webhook/controller（§7） |
| `unable to create task run pod` | 其它 | 检查 `tkn describe` |

### 症状：Argo CD 报 `HTTP Basic: Access denied`（但凭据没错）

**这是 Redis 缓存问题**，见 §9 的踩坑记录，执行 `FLUSHALL` + 重启。

### 症状：构建失败

Kaniko 日志要点对照：

| 报错 | 原因 | 对策 |
|------|------|------|
| `Could not resolve host: digitalsupply` | URL 拼接错误 | 检查任务里 host/path 拆分逻辑 |
| `Remote branch <sha> not found` | `-b` 传了 SHA | 用 §10 的浅克隆+fetch 方案 |
| `npm error ... download.cypress.io` | 外网不可达 | `CYPRESS_INSTALL_BINARY=0` |
| `npm error ... ETIMEDOUT ... github.com` | onnxruntime 拉原生包 | `ONNXRUNTIME_NODE_INSTALL_CUDA=skip` |
| `No wheel bundled for: micropip...` | jsdelivr 不可达 | 前端改 `npx vite build` |
| `FATAL ERROR: ... JavaScript heap out of memory` | Node 内存不足 | 调高 `NODE_OPTIONS`，关闭 sourcemap |
| `OSError: We couldn't connect to 'https://huggingface.co'` | HF 不可达 | `--build-arg USE_SLIM=true` |
| `crictl ... content digest ... not found` | containerd 缓存不全 | 节点上 `crictl rmi` 后重新 pull |

### 症状：Pod ImagePullBackOff 但镜像在 Harbor

检查 `harbor-pull` secret 是否存在、`openwebui` 项目是否 private
（本项目为 private，必须配 imagePullSecrets）。

---

## 16. 注意事项与已知限制

### 16.1 Dockerfile 的三处 CI 适配（重要）

上游 `Dockerfile` 假定可以访问公网，本环境不行。已生成
**`Dockerfile.harbor`**（副本），流水线专用。上游 `Dockerfile` **保持原样未改**。

```dockerfile
# ① 基础镜像指向 Harbor
FROM --platform=$BUILDPLATFORM 192.168.67.202:8443/openwebui/node:22-alpine3.20 AS build
FROM 192.168.67.202:8443/openwebui/python:3.11-slim-bookworm AS base

# ② Kaniko 不支持 BuildKit 的 RUN --mount=from=，改为独立 stage + COPY --from
FROM 192.168.67.202:8443/openwebui/uv:0.12.10 AS uvbin
FROM 192.168.67.202:8443/openwebui/python:3.11-slim-bookworm AS base
COPY --from=uvbin /uv /bin/uv

# ③ 跳过外网下载
ENV CYPRESS_INSTALL_BINARY=0            # download.cypress.io 不可达
ENV ONNXRUNTIME_NODE_INSTALL_CUDA=skip  # github.com 不可达（onnxruntime-node 原生包）
RUN sed -i "s/sourcemap: true/sourcemap: false/" vite.config.ts && \
    npx vite build                        # 跳过 pyodide（cdn.jsdelivr.net 不可达）
ENV NODE_OPTIONS="--max-old-space-size=8192"
```

> ⚠️ 若上游更新 `Dockerfile`，需重新评估这些适配是否仍需要。

### 16.2 SLIM 变体的取舍

`USE_SLIM=true` 的代价：**RAG / Whisper / 嵌入模型不再预置到镜像**，
首次使用时需要能访问 huggingface.co 下载。当前环境无法访问，因此：

> **RAG 检索、语音转写等需要模型的功能在本环境不可用**（会报连接错误）。
> 如需启用，需先解决 huggingface 访问（内网代理 / modelscope 镜像 / 手动预置模型目录）。

### 16.3 内存与构建时长

- 前端 `vite build` 峰值内存约 4~5 GB，worker 节点仅 9GB，**必须**：
  1. 关闭 sourcemap（否则约翻倍，必 OOM）
  2. `NODE_OPTIONS=--max-old-space-size=8192`
- 控制面节点已打 taint（`node-role.kubernetes.io/control-plane`），
  构建 Pod 只可能落到 worker，符合预期
- 冷构建约 9~10 分钟（缓存命中后约 3~5 分钟）。GitLab CI 默认 job timeout
  1 小时，Tekton pipeline timeout 已设 90 分钟，留有余量

### 16.4 网络限制汇总

以下功能在当前网络下**不可用**，如需启用要单独规划：
- `huggingface.co`（RAG 模型、Whisper 模型）
- `github.com` / `gcr.io` / `docker.io` / `cdn.jsdelivr.net` / `download.cypress.io`
- GPU 相关功能（`USE_CUDA=true`）——本环境无 GPU

### 16.5 未部署 Ollama

按你的选择，本次**未部署 Ollama**。需要在 Open WebUI 界面
（⚙️ Settings → Connections）手工配置 OpenAI 兼容端点，例如：
```
http://<你的ollama或llm服务>:11434/v1
```

### 16.6 单副本限制

PVC 为 RWO + `Recreate` 策略，目前只能跑 1 副本。若要扩容，需：
换成 RWX 的 `nfs-sc` 存储类，并把策略改回 `RollingUpdate`，
同时移除对本地卷的独占假设。

### 16.7 Tekton Patch 易失

§7 中对 tekton webhook/controller 的 CA 注入是 `kubectl patch`，
**Tekton 升级后会被覆盖**，需重新执行。

### 16.8 旧演示资源未清理

`cicd` ns 中旧的 `tekton-demo-*`（PipelineRun/Task/EventListener 等）
仍指向已下线的 `10.0.0.41` / `10.0.0.200`，**未删除**，仅作保留。
如需清理可执行：

```bash
kubectl -n cicd delete pipeline tekton-demo-cicd
kubectl -n cicd delete eventlistener,triggertemplate,triggerbinding -l app.kubernetes.io/part-of!=openwebui-cicd
```

---

## 17. 安全建议

当前为内网验证环境，以下**尚未实施**，生产环境请务必处理：

1. **轮换所有明文凭据**（§5 表格中的全部）：GitLab PAT、Harbor admin、
   Harbor robot、`WEBUI_SECRET_KEY`
2. **GitLab 不要用 root**：建专用 CI 用户（最小权限：read_repository +
   write_repository），替换 runner 与 Argo CD 中的凭据
3. **Harbor 项目改用 robot 账号**做 CI 推送：admin 权限过大
4. **GitLab 启用 HTTPS**，避免 PAT 明文过网
5. **Harbor 换受信任证书**，去掉 `--insecure` / `skip_verify`
6. **Argo CD 开启 RBAC**：`projects` 中限定 `sourceRepos` 与 `destinations`
7. **GitLab 项目改私有 + 保护 main 分支**，禁止直接 push
8. **`.secrets/` 加入 `.gitignore`**（当前不在任何仓库内，但需保持）
9. **清理节点上的临时文件**：`/tmp/setup-harbor.sh`、`/tmp/mk*.rb` 等

---

## 附：文件清单

### 本仓库（`/root/openwebuicicd`）

```
.secrets/env.sh                        # 全部凭据（chmod 600，勿提交）
scripts/setup-containerd-harbor.sh     # 节点 containerd 配置脚本
deploy/cicd/
  00-setup.yaml                        # ns secrets + SA
  10-task-git-clone.yaml               # clone task
  20-task-build-and-push.yaml          # kaniko build task
  30-task-update-gitops-tag.yaml       # gitops tag task
  40-pipeline-open-webui.yaml          # pipeline
  harbor-ca.crt                        # Harbor CA
deploy/runner/
  00-runner-setup.yaml                 # ns + runner ConfigMap（含 token）
  01-runner-rbac-and-deployment.yaml   # SA/Role/RoleBinding/Deployment
open-webui/                            # 应用源码（Git origin = GitLab）
  .gitlab-ci.yml                       # CI 触发器
  Dockerfile.harbor                    # CI 专用 Dockerfile
```

### 应用仓库 `digitalsupply/openwebui`

| 分支 | 说明 |
|------|------|
| `main` | CI/CD 源，默认分支 |
| `upstream` remote | 指向 github.com/open-webui/open-webui，用于同步上游 |

### GitOps 仓库 `digitalsupply/openwebui-gitops`

| 路径 | 说明 |
|------|------|
| `base/` | 环境无关清单 |
| `overlays/prod/kustomization.yaml` | **CI 改写 newTag 的位置** |
| `argocd/` | Argo CD 配置备份 |

### 集群命名空间

| ns | 内容 |
|----|------|
| `open-webui` | 业务负载（Argo CD 管理） |
| `cicd` | Tekton 任务/Pipeline/Secret |
| `gitlab-runner` | Runner + RBAC |
| `argocd` | Application + 仓库凭据 |
| `tekton-pipelines` | Tekton（已注入 Harbor CA） |

---

## 附录 A：OpenCode Zen (Go) 模型接入

> 追加于 2026-10-13，解决 Open WebUI 调用 `opencode.ai/zen/go` 报错的问题。

### A.1 三个阶段的问题与定位

**阶段 1 — `OpenAI: Network Problem`**

根因是 Base URL 末尾多了一个空格：

```
实际存储： "https://opencode.ai/zen/go/v1␣"
拼接后变成： /zen/go/v1%20/models   （%20 = 空格）
服务端返回： 404 + text/html
→ Open WebUI 报 "Attempt to decode JSON with unexpected mimetype"
```

URL 末尾的空格肉眼完全看不出来，建议配置后用 Home/End 键确认光标紧贴 `v1`。

**阶段 2 — `Request is missing x-opencode-session`**

这是**服务端策略性拒绝，不是网络问题**。opencode.ai 的 Go 端点专为编程 Agent
设计，官方文档要求客户端满足三条：

| # | 要求 | Open WebUI v0.12 |
|---|------|-----------------|
| 1 | 发送典型 coding agent 流量 | ✅ |
| 2 | 使用自己的 User-Agent（而非通用 SDK 名） | ❌ `openai/1.x` |
| 3 | 每个会话带稳定的 `x-opencode-session` 头 | ❌ **完全不发送** ← 触发报错 |

实测对比（同一 Pod 内）：

```bash
# 不带头（报错）
curl https://opencode.ai/zen/go/v1/models
#   → "Request is missing x-opencode-session and cannot be routed efficiently."

# 带头（正常）
curl -H "x-opencode-session: test-123" https://opencode.ai/zen/go/v1/models
#   → 200 + 完整模型列表
```

**Open WebUI 无法自行配置这个头。** 源码 `backend/open_webui/utils/headers.py` 中
可发送的头只有 `Content-Type`、`Authorization`（以及
`ENABLE_FORWARD_USER_INFO_HEADERS=true` 时的 `X-OpenWebUI-*` 固定头族），
**没有任何扩展自定义头的能力**。文档里另一个端点
`https://opencode.ai/inference/go/v1`（面向第三方应用直连）在本环境实测不通
（`code=000`），因此只能加代理。

### A.2 方案：Pod 内 nginx sidecar

在 Open WebUI Pod 里加一个 sidecar，监听 **仅回环地址** `127.0.0.1:11435`，
注入所需请求头后转发到真实端点。

```
Open WebUI ──http──▶ 127.0.0.1:11435 (nginx sidecar)
                        │  注入 x-opencode-session
                        │  注入专用 User-Agent
                        ▼
                    https://opencode.ai/zen/go/v1  (固定 172.65.90.21:443)
```

**Open WebUI 连接设置：**

| 项 | 值 |
|----|-----|
| Base URL | `http://127.0.0.1:11435/v1` |
| API Key | 你的 opencode.ai key（原样透传，不经过代理改写） |

### A.3 ⚠️ 关键坑点：Cloudflare 部分 IP 不可达

opencode.ai 在 Cloudflare 后面，本网络**只有 4 个 anycast 地址中的 1 个可达**：

| IP | 实测结果 |
|----|----------|
| `172.65.90.21` | ✅ HTTP 200，~0.33s |
| `172.65.90.20` | ❌ TCP 连接永不完成 |
| `172.65.90.22` | ❌ TCP 连接永不完成 |
| `172.65.90.23` | ❌ TCP 连接永不完成 |

若直接用域名做 `proxy_pass`，nginx 会轮询全部 A 记录 → **约 75% 的请求挂起
30 秒后超时**。实测 `max_fails` / `fail_timeout` 自愈**无效**（nginx 仍会重试
坏 IP 并等满超时）。

**解决办法：在 ConfigMap 中固定可达 IP**，`proxy_ssl_name opencode.ai` 保证
SNI 与证书校验仍然正确。

```nginx
upstream opencode_zen {
  server 172.65.90.21:443;
}
```

**若日后 opencode.ai 故障或 IP 变更，重新探测：**

```bash
kubectl -n open-webui exec deploy/... -c open-webui -- sh -c '
for ip in $(getent ahostsv4 opencode.ai | awk "{print \$1}" | sort -u); do
  curl -s -o /dev/null -m 20 -w "$ip %{http_code} %{time_total}s\n" \
    --resolve "opencode.ai:443:$ip" https://opencode.ai/zen/go/v1/models
done'
```

取返回 200 的那个 IP，改 `base/nginx.conf` 后提交即可。

### A.4 ⚠️ 关键坑点：ConfigMap 用 subPath 挂载不会热更新

最初把 nginx 配置放在静态 ConfigMap 里、用 `subPath` 挂载到
`/etc/nginx/nginx.conf`。**Kubernetes 的 subPath 挂载不会把 ConfigMap 更新推送到
已运行的容器**——改完 ConfigMap 后 Pod 内文件纹丝不动，必须重启 Pod。

同时因为 Argo CD 开着 `selfHeal: true`，直接 `kubectl apply` 改 ConfigMap
**会被自动回滚成 Git 里的版本**，让人误以为改了没生效。

**正确做法：用 `configMapGenerator` 生成带 hash 的 ConfigMap。**

```yaml
# base/kustomization.yaml
configMapGenerator:
  - name: opencode-proxy
    files:
      - nginx.conf
    options:
      disableNameSuffixHash: false
```

生成 `opencode-proxy-<hash>`，Kustomize 自动改写 Deployment 里的
`configMap.name`。配置一改 → 名字变 → Pod template 变 → **自动滚动重建**。

> 配合上面「一切变更走 GitOps」的原则：**不要用 `kubectl apply` 直接改
> Argo CD 管理的资源**，会被 selfHeal 回滚。改 `base/nginx.conf` 提交即可。

### A.5 代理关键参数

| 参数 | 值 | 原因 |
|------|-----|------|
| `proxy_connect_timeout` | `10s` | 坏 IP 快速失败而非长时间挂起 |
| `proxy_send_timeout` / `proxy_read_timeout` | `900s` | 流式对话可能持续数分钟 |
| `proxy_buffering` | `off` | SSE 流式响应不能缓冲 |
| `proxy_cache` | `off` | 同上 |
| `proxy_ssl_server_name` / `proxy_ssl_name` | `on` / `opencode.ai` | 连的是裸 IP，但 SNI 与证书校验仍用真实域名 |
| `x-opencode-session` | `open-webui-cngpt`（固定值） | 固定值使本实例流量落到同一上游后端，prompt cache 命中率最高 |

> 关于 session id：规范做法是"每个会话一个稳定 id"，但 Open WebUI 只在
> `ENABLE_FORWARD_USER_INFO_HEADERS=true` 时才把 chat id 作为
> `X-OpenWebUI-Chat-Id` 发出来（需改环境变量并重新构建镜像）。
> 当前单人多会话场景，固定值效果等价且实现简单。

### A.6 验证结果

```
连续 12 次请求：成功 12 / 失败 0，响应 0.31~0.35s
模型列表：正常返回（deepseek-v4-pro、glm-5.3、kimi-k3 等 30+ 模型）
Pod 状态：2/2 Running（open-webui + opencode-proxy）
```

### A.7 相关文件

| 文件 | 说明 |
|------|------|
| `openwebui-gitops/base/nginx.conf` | 代理配置（含 IP 固定与头部注入） |
| `openwebui-gitops/base/kustomization.yaml` | `configMapGenerator` 声明 |
| `openwebui-gitops/base/10-open-webui.yaml` | sidecar 容器定义 |

> 注：`openwebui-gitops/` 是 GitLab `digitalsupply/openwebui-gitops`
> 仓库的本地克隆（当前工作目录下），实际生效副本以该仓库 `main` 分支为准。

---

## 附：常用命令速查

```bash
source /root/openwebuicicd/.secrets/env.sh   # 载入凭据

# —— 观察 ——
kubectl -n argocd get application open-webui -w
kubectl -n open-webui get pods -w
kubectl -n cicd get pipelineruns -l app.kubernetes.io/part-of=openwebui-cicd

# —— 重跑 Argo CD（改凭据后必做）——
RPASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
kubectl -n argocd exec deploy/argocd-redis -- redis-cli -a "$RPASS" FLUSHALL
kubectl -n argocd rollout restart deploy/argocd-repo-server statefulset/argocd-application-controller

# —— 重新同步 ——
kubectl -n argocd annotate application open-webui argocd.argoproj.io/refresh=hard --overwrite

# —— 校验 GitOps 渲染 ——
kubectl kustomize /tmp/openwebui-gitops/overlays/prod | grep image:

# —— 服务检查 ——
curl -s http://cngpt.ccwu.cc/health

# —— 看 Open WebUI 日志 ——
kubectl -n open-webui logs -l app.kubernetes.io/name=open-webui -f
```