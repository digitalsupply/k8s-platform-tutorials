# Open WebUI 项目 / 集群运维手册（现状 + 历史工作记录 + 操作手册）

> 更新日期：2026-10-27  
> 适用集群：`kubernetes-admin@kubernetes`（K8s v1.35.9）  
> 适用目录：`/root/openwebuicicd`  
> 配套文档：`OPENWEBUI-CICD-GITOPS.md`（流水线建设细节；注意其 §5 含明文凭据，分享前必须脱敏）

---

## 0. 当前状态速览

| 项目 | 当前状态 |
|---|---|
| Open WebUI 应用 | **已暂停**，Deployment `open-webui` 为 `0/0` |
| frpc 隧道 | **已暂停**，Deployment `frpc` 为 `0/0` |
| ArgoCD Application | `open-webui`：**Synced / Healthy**，revision `36211cc` |
| Pod | `open-webui` 命名空间下 **Pod 数量为 0** |
| 对外访问 | 本地 Ingress `cngpt.ccwu.cc` 返回 **503**；公网 frpc 入口同时不可用 |
| 数据 | PVC `open-webui-data` **Bound**，10Gi，SQLite 数据完整保留 |
| 镜像 | `192.168.67.202:8443/openwebui/open-webui:a077c804`（225.4 MiB） |
| 恢复方式 | `git revert 36211cc` → push → ArgoCD 自动同步 |
| 手动改副本 | **不要用** `kubectl scale`，会被 ArgoCD `selfHeal` 改回 |

**一句话：应用处于“停机保配置”状态，所有 Deployment / Service / Ingress / Secret / PVC / 镜像 / 数据均保留，可随时恢复。**

> ✅ **m01 故障已恢复（2026-10-27 22:45）**
> 22:27 m01（10.0.0.61，Proxmox VM 119）因 **BuildKit 重型构建导致内存/CPU 资源耗尽**而 NotReady；
> 22:44:37 优雅重启无效后执行 `qm reset 119`；**22:45:33 节点 Ready**，etcd / apiserver / controller-manager / scheduler 全部恢复。
> 已清理 m01 上 15 GiB 遗留 BuildKit 缓存（根分区 77% → 47%），kubeconfig 已切回原 context。
> 详细复盘、证据和后续加固建议见 §6.9。当前 deeptutor 构建仍在 worker03 上运行，BuildKit 资源上限风险尚未消除。

---

## 1. 系统架构

### 1.1 逻辑架构图

```text
开发机 / Git push
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│ GitLab  192.168.67.201:80   (gitlab-ce 19.5.0)              │
│   digitalsupply/openwebui          ← 应用源码                │
│   digitalsupply/openwebui-gitops   ← Kustomize GitOps 配置   │
└──────────────────────┬──────────────────────────────────────┘
                       │ ① Runner 主动轮询（出站，GitLab 无需入站）
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ GitLab Runner  ns: gitlab-runner                            │
│   runner id=3  openwebui-k8s-runner  online                 │
│   作业 Pod 使用 default SA，调用 Kubernetes API              │
└──────────────────────┬──────────────────────────────────────┘
                       │ ② POST PipelineRun
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Tekton Pipeline open-webui-cicd   ns: cicd  (v1.6.0)        │
│   [git-clone] → [build-and-push/Kaniko] → [update-gitops-tag]│
└───────────┬───────────────────────────────────┬─────────────┘
            │ ③ push image                       │ ④ commit newTag
            ▼                                    ▼
┌───────────────────────────┐       ┌──────────────────────────────────┐
│ Harbor 192.168.67.202:8443│       │ GitLab openwebui-gitops          │
│ project: openwebui        │       │ overlays/prod/kustomization.yaml │
│ v2.14.5                   │       │ newTag: <commit-sha>             │
└───────────────────────────┘       └──────────────────┬───────────────┘
                                                       │ ⑤ poll ~3 min
                                                       ▼
                                        ┌──────────────────────────────┐
                                        │ ArgoCD ns: argocd (v3.5.3)   │
                                        │ auto-sync + selfHeal + prune │
                                        └──────────────┬───────────────┘
                                                       │ ⑥ apply
                                                       ▼
                                        ┌──────────────────────────────┐
                                        │ ns: open-webui               │
                                        │ Deployment / Service /       │
                                        │ Ingress / PVC / Secret       │
                                        └──────────────┬───────────────┘
                                                       │ ⑦ HTTP
                                                       ▼
                                        ┌──────────────────────────────┐
                                        │ Traefik LB 10.0.0.252        │
                                        │ cngpt.ccwu.cc:80             │
                                        └──────────────┬───────────────┘
                                                       │ ⑧ 可选公网隧道
                                                       ▼
                                        ┌──────────────────────────────┐
                                        │ frpc → VPS 49.233.210.176    │
                                        │ http://www.cngpt.ccwu.cc:8089│
                                        └──────────────────────────────┘
```

> 当前应用和 frpc 均为 0 副本，因此 ⑦⑧ 路径暂时不可用。

### 1.2 组件与版本

| 组件 | 地址 / 命名空间 | 版本 / 说明 |
|---|---|---|
| Kubernetes | — | **v1.35.9**，containerd 2.3.2 |
| GitLab | `http://192.168.67.201` | **19.5.0**（建设文档写的是 19.4.2，已升级） |
| Harbor | `https://192.168.67.202:8443` | **v2.14.5-c83198c6**，自签名证书 |
| ArgoCD | `argocd` | **v3.5.3** |
| Tekton Pipelines | `tekton-pipelines` | **v1.6.0** + Triggers + Dashboard |
| GitLab Runner | `gitlab-runner` | 镜像 `openwebui/gitlab-runner:alpine-v17.8.3`，id=3 |
| Traefik | `traefik` | LoadBalancer `10.0.0.252`，ingressClass `traefik` |
| MetalLB | `metallb-system` | pool `10.0.0.252-253` |
| 存储 | — | `ceph-rbd-sc`（RBD，Retain）、`nfs-sc`（NFS，Delete） |
| 监控 | `monitoring` | Prometheus + Grafana + Alertmanager；Prometheus 保留 15d / 25GiB |
| 日志 | `logging` | Loki + Tempo + Alloy |
| 消息 | `kafka` | Strimzi 单 broker |
| 数据库 | `cnpg-system` | CloudNativePG `pg16-ceph`（Open WebUI **未使用**） |
| 自动化 | `n8n` | 独立业务，与本项目无关 |

### 1.3 网络约束（方案选型依据）

| 方向 / 目标 | 状态 | 影响 |
|---|---|---|
| GitLab → K8s 集群（10.0.0.0/24） | ❌ 不通 | 无法用 GitLab Webhook 直接触发 Tekton EventListener |
| 集群 → GitLab `192.168.67.201:80` | ✅ | Runner 可主动轮询 |
| 集群 → Harbor `192.168.67.202:8443` | ✅ | 可拉取/推送镜像 |
| 集群 → PyPI / npm / ghcr / quay | ✅ | 构建依赖可用 |
| Docker Hub / gcr.io / github.com | ❌ | 基础镜像必须预置到 Harbor |
| cdn.jsdelivr.net / download.cypress.io | ❌ | 前端构建与依赖安装需绕过 |
| huggingface.co | ❌ | SLIM 镜像下 RAG / Whisper 模型不可用 |

**设计结论：** 集群内 GitLab Runner 主动轮询 GitLab，拿到任务后调用 Tekton API 创建 PipelineRun；Tekton 只负责构建和提交 GitOps tag；ArgoCD 负责最终 apply。集群始终是 Git 的追随者。

### 1.4 运行态请求路径

```text
浏览器
  ├─ http://cngpt.ccwu.cc              （内网 hosts → 10.0.0.252）
  └─ http://www.cngpt.ccwu.cc:8089     （公网 → VPS frps → frpc → Traefik）
        ↓
Traefik (10.0.0.252:80)
        ↓  Ingress host cngpt.ccwu.cc
Service open-webui:80
        ↓
Pod open-webui:8080
  ├─ container open-webui
  └─ sidecar opencode-proxy:11435（注入 x-opencode-session，转发到上游）
        ↓
SQLite /app/backend/data/webui.db（PVC open-webui-data）
```

---

## 2. 仓库、目录与制品

### 2.1 GitLab 项目

| 项目 | ID | 用途 | 可见性 | 最近活动 |
|---|---:|---|---|---|
| `digitalsupply/openwebui` | 1 | Open WebUI 源码 + `.gitlab-ci.yml` + `Dockerfile.harbor` | private | 2026-10-13 |
| `digitalsupply/openwebui-gitops` | 2 | Kustomize base/overlay、ArgoCD 源 | private | 2026-10-27 |
| `digitalsupply/compassio` | 3 | 同集群其他项目（非本项目） | — | 2026-10-27 |
| `digitalsupply/compassio-gitops` | 4 | 同集群其他项目 | — | 2026-10-27 |
| `deeptutor/deeptutor` | 5 | 同集群其他项目（当前有故障） | — | 2026-10-27 |
| `deeptutor/deeptutor-gitops` | 6 | 同集群其他项目 | — | 2026-10-27 |

应用仓库的 remote：

```text
origin   http://root:<PAT>@192.168.67.201/digitalsupply/openwebui.git
upstream https://github.com/open-webui/open-webui.git
```

> ⚠️ PAT 明文写在 `.git/config` 和 `.secrets/env.sh` 中，详见 §6 安全注意事项。

### 2.2 本地目录（当前工作目录）

```text
/root/openwebuicicd/
├── open-webui/                    # 应用源码仓库（origin: digitalsupply/openwebui）
├── openwebui-gitops/              # GitOps 仓库克隆（origin: digitalsupply/openwebui-gitops）
│   ├── base/
│   │   ├── 00-namespace-and-secrets.yaml
│   │   ├── 10-open-webui.yaml     # PVC / Secret / Deployment / Service / Ingress
│   │   ├── frpc.yaml              # frpc 隧道
│   │   ├── kustomization.yaml
│   │   └── nginx.conf             # opencode-proxy 配置
│   └── overlays/prod/kustomization.yaml   # 镜像 tag + 副本数
├── deploy/
│   ├── cicd/                      # Tekton Task / Pipeline 参考清单
│   └── runner/                    # GitLab Runner 部署清单
├── scripts/
│   ├── setup-containerd-harbor.sh
│   └── install-frps-vps.sh
├── .secrets/env.sh                # 600，GitLab/Harbor/K8s 凭据
├── OPENWEBUI-CICD-GITOPS.md       # 原有流水线建设长文
└── OPENWEBUI-OPS-RUNBOOK.md       # 本文
```

> 旧的 `gitops-openwebui/` 已确认无用并删除（不是 Git 仓库、kustomize 无法构建、frpc 清单指向不存在的 `frp` 命名空间）。删除前备份在 `/tmp/opencode/gitops-openwebui-backup-20261026.tar.gz`（临时目录，可丢）。

### 2.3 Harbor 项目与镜像

Harbor v2.14.5，项目 `openwebui` 为 **private**，共 11 个仓库。

| 镜像 | Tag | 大小 | 用途 |
|---|---|---:|---|
| `openwebui/open-webui` | `a077c804` | 225.4 MiB | **当前业务镜像** |
| `openwebui/open-webui` | `manual-test1` | 225.4 MiB | 手工测试镜像 |
| `openwebui/frpc` | `v0.61.2` | 9.7 MiB | 公网隧道客户端 |
| `openwebui/nginx-unprivileged` | `1.29-alpine` | 22.0 MiB | opencode-proxy sidecar |
| `openwebui/kaniko` | `v1.23.2` | 29.6 MiB | Tekton 构建器 |
| `openwebui/gitlab-runner` | `alpine-v17.8.3` | — | Runner 作业镜像 |
| `openwebui/gitlab-runner-helper` | `x86_64-v17.8.3` | 30.4 MiB | Runner helper（替代不可达的 registry.gitlab.com） |
| `openwebui/uv` | `0.12.10` | 21.9 MiB | 后端依赖安装 |
| `openwebui/python` | `3.11-slim-bookworm` | 47.6 MiB | 后端基础镜像 |
| `openwebui/node` | `22-alpine3.20` | 53.5 MiB | 前端构建基础镜像 |
| `openwebui/alpine` | `3.20` | 3.5 MiB | 通用基础镜像 |
| `openwebui/cache` | — | — | Kaniko 构建缓存（0 artifacts） |

同集群其他 Harbor 项目：

| 项目 | 仓库数 | 说明 |
|---|---:|---|
| `compassio` | 7 | backend/frontend/nginx/node/python/buildkit/cache |
| `deeptutor` | 3 | busybox/git/redis（业务镜像 `deeptutor:init` 当前缺失） |
| `library` | 0 | 空 |

### 2.4 镜像与 Tag 规范

```text
192.168.67.202:8443/openwebui/open-webui:<git-short-sha>
```

- Tag 使用提交短 SHA，不可变、可追溯。
- CI 每次成功构建都会把 `overlays/prod/kustomization.yaml` 的 `newTag` 改成新 SHA。
- 基础镜像/工具镜像也放在 `openwebui` 项目，避免访问 Docker Hub / gcr.io / github.com。

### 2.5 凭据与 Secret 分布（不记录明文）

| Secret / 文件 | 命名空间 | 内容 |
|---|---|---|
| `.secrets/env.sh` | 本地 | GitLab PAT、Harbor 账号、K8s 地址等，权限 600 |
| `gitlab-auth` | `cicd` | GitLab username/password/token/git-url/gitops-url |
| `harbor-auth` | `cicd` | Harbor dockerconfigjson（构建推送） |
| `harbor-auth` | `gitlab-runner` | Harbor dockerconfigjson（拉取 helper） |
| `harbor-pull` | `open-webui` | kubelet 拉取业务镜像 |
| `open-webui-config` | `open-webui` | `WEBUI_SECRET_KEY` |
| `gitlab-openwebui-gitops` | `argocd` | ArgoCD 拉取 GitOps 仓库 |
| `frp-token` | `open-webui` | frpc 认证 token |
| `open-webui-data` | `open-webui` | PVC，SQLite 数据 |

> 本文不复制任何密码/token。需要时执行 `source /root/openwebuicicd/.secrets/env.sh`。

---

## 3. Kubernetes 集群现状

### 3.1 节点与容量

| 节点 | 角色 | CPU | 内存 | IP | 备注 |
|---|---|---:|---:|---|---|
| m01 | control-plane | 4 | 5.5 GiB | 10.0.0.61 | 2026-10-27 曾因 BuildKit 构建资源耗尽 NotReady，重启并清理缓存后恢复 |
| master01 | control-plane | 4 | 5.8 GiB | 10.0.0.121 | |
| master02 | control-plane | 4 | 3.7 GiB | 10.0.0.120 | 内存使用率最高 |
| worker01 | worker | 6 | 9.7 GiB | 10.0.0.122 | GitLab Runner、Prometheus、Loki |
| worker02 | worker | 6 | 9.7 GiB | 10.0.0.123 | Kafka、CNPG、Traefik |
| worker03 | worker | 4 | 7.7 GiB | 10.0.0.124 | Open WebUI、compassio、deeptutor |

- 总可分配：**28 vCPU / 约 41.7 GiB 内存**
- 命名空间：**23 个**
- Deployment / StatefulSet / DaemonSet：约 **79 个**
- PVC：**32 个**

### 3.2 即时资源水位（2026-10-27 22:52，m01 重启后）

| 节点 | CPU | 内存 | 根分区磁盘 |
|---|---:|---:|---:|
| m01 | 356m / 8% | 2730 Mi / 49% | **47.0%**（清理 15G 缓存后） |
| master01 | 446m / 11% | 3940 Mi / 67% | 41.9% |
| master02 | 463m / 11% | 2895 Mi / 75% | 44.5% |
| worker01 | 716m / 11% | 6027 Mi / 61% | **72.4%** |
| worker02 | 415m / 6% | 6258 Mi / 63% | 62.8% |
| worker03 | 509m / 12% | 3572 Mi / 45% | 66.4% |

近 7 天集群整体：

| 指标 | 7 天平均 | 7 天峰值 |
|---|---:|---:|
| CPU | **2.03 核（约 7%）** | 2.96 核 |
| 内存 | **18.0 GiB（约 43%）** | 19.1 GiB |

> 集群整体空闲；主要占用来自 `kube-system`、`monitoring`、`logging`、`kafka`、`cnpg`，不是 Open WebUI。

### 3.3 关键命名空间

| 命名空间 | 内容 | 与本项目关系 |
|---|---|---|
| `open-webui` | open-webui + frpc | **本项目运行态（当前 0 副本）** |
| `cicd` | Tekton Pipeline/Task/Trigger、清理 CronJob | 本项目构建流水线 |
| `gitlab-runner` | GitLab Runner | 本项目触发器 |
| `argocd` | ArgoCD 及 Application | 本项目 GitOps 控制器 |
| `monitoring` | Prometheus / Grafana / Alertmanager | 观测 |
| `logging` | Loki / Tempo / Alloy | 日志 |
| `kafka` | Strimzi Kafka | 独立 |
| `cnpg-system` | CloudNativePG | 独立；Open WebUI 未使用 |
| `compassio` | compassio 业务 | 同集群其他项目 |
| `deeptutor` | deeptutor 业务 | 同集群其他项目，当前异常 |

### 3.4 存储

| StorageClass | Provisioner | ReclaimPolicy | 用途 |
|---|---|---|---|
| `ceph-rbd-sc` | `rbd.csi.ceph.com` | **Retain** | Open WebUI、Kafka、CNPG、compassio 等 |
| `nfs-sc` | `example.com/nfs` | Delete | Tekton Workspace、Prometheus/Grafana、Loki 等 |

Open WebUI：

```text
PVC: open-webui-data
状态: Bound
容量: 10Gi
模式: RWO
StorageClass: ceph-rbd-sc
实际使用: 约 5 MiB（0.05%）
挂载: /app/backend/data
```

> RBD 是瘦分配，10Gi 只是逻辑上限；实际 Ceph 占用很小，但容量规划/告警仍会按 10Gi 计。
> PV 回收策略是 `Retain`，即使 PVC 被误删，底层 RBD 卷仍保留，可人工恢复。

### 3.5 Service / Ingress

| Namespace | Ingress | Host | 状态 |
|---|---|---|---|
| `open-webui` | `open-webui` | `cngpt.ccwu.cc` | 存在；应用暂停中，返回 503 |
| `compassio` | `compassio` | `compassio.xyz` | 正常 |
| `cicd` | `compassio-el` | `ci-compassio.xyz` | 正常 |
| `cicd` | `deeptutor-el` | `el-deeptutor.internal` | 正常 |
| `deeptutor` | `deeptutor` | `deeptutor.xyz` | 后端镜像异常 |
| `n8n` | `n8n-ingress` | `n8n.zeroth.com` | 正常 |

Traefik LoadBalancer：`10.0.0.252`。内网访问需在 hosts 中配置：

```text
10.0.0.252 cngpt.ccwu.cc
```

### 3.6 ArgoCD Application

| Application | 仓库 | Path | Revision | Sync | Health |
|---|---|---|---|---|---|
| `open-webui` | `digitalsupply/openwebui-gitops` | `overlays/prod` | `36211cc` | Synced | **Healthy** |
| `compassio` | `digitalsupply/compassio-gitops` | `overlays/prod` | `7f1fe29c` | Synced | Healthy |
| `deeptutor` | `deeptutor/deeptutor-gitops` | `overlays/prod` | `c769a415` | Synced | **Degraded** |

`open-webui` 的同步策略：

```yaml
automated:
  prune: true        # Git 中删除的资源会被清理
  selfHeal: true     # 手工改动会被改回 Git 状态
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
```

### 3.7 当前 Open WebUI 工作负载规格

| 项 | 值 |
|---|---|
| Deployment | `open-webui/open-webui`，**replicas 0** |
| 策略 | `Recreate`（RWO + SQLite，避免新旧 Pod 争卷） |
| 容器 | `open-webui` + `opencode-proxy` |
| 镜像 | `openwebui/open-webui:a077c804` + `nginx-unprivileged:1.29-alpine` |
| CPU requests / limits | `100m / 500m` |
| Memory requests / limits | `512Mi / 1Gi` |
| sidecar requests / limits | `10m/16Mi`，`100m/64Mi` |
| 探针 | startup `/health` 30s×30；readiness 10s；liveness 30s |
| 环境 | `DATA_DIR=/app/backend/data`、`WEBUI_URL=http://cngpt.ccwu.cc`、`OFFLINE_MODE=true`、`WEBUI_AUTH=True`、关闭遥测 |
| Service | `open-webui:80` → Pod `8080` |
| PVC | `open-webui-data` 10Gi，挂载 `/app/backend/data` |
| 数据 | SQLite `webui.db`（约 0.8 MiB），1 个用户 / 4 个会话 |

暂停前实测（Prometheus 7 天）：

| 指标 | 实际值 |
|---|---:|
| CPU 平均 / 峰值 | 约 10m / 16m |
| 内存平均 / 峰值 | 约 304 MiB / 316 MiB |
| CPU 限流 | 0% |
| 7 天请求数 | 824 次（大部分是 version 轮询） |
| P95 延迟 | 0.26 秒 |
| 7 天入站/出站 | 约 82 MiB / 96 MiB |

---

## 4. 历史工作记录（按时间线）

> 依据：GitLab 提交记录、ArgoCD history、Tekton/GitLab Pipeline 记录、现有建设文档，以及本次会话的实际操作。
> 时间均为 2026 年。

### 4.0 项目开始前的集群基础（既有设施）

以下设施在 Open WebUI 项目之前就已存在，本项目直接复用：

- K8s 集群 v1.35.9，6 节点（3 control-plane + 3 worker），Calico、CoreDNS、MetalLB、Traefik。
- ArgoCD v3.5.3、Tekton v1.6.0、Ceph CSI RBD、NFS Provisioner、cert-manager。
- Prometheus/Grafana/Alertmanager（15 天保留）、Loki/Tempo/Alloy、Kafka、CloudNativePG、n8n。
- `cicd` 命名空间中有一套旧的 `tekton-demo-cicd`，指向已下线的 `10.0.0.41` / `10.0.0.200`，未删除，仅保留。

### 4.1 2026-10-13：CI/CD + GitOps 流水线建设

| 工作 | 结果 |
|---|---|
| 网络探测 | 确认 GitLab → 集群 10.0.0.0/24 不通；集群 → GitLab/Harbor 出站正常 |
| Harbor 基础镜像预置 | 创建 `openwebui` 项目；预置 alpine/node/python/uv/kaniko/runner/helper 等 |
| 节点 containerd 配置 | 为 `192.168.67.202:8443` 配置 `certs.d`，信任 Harbor 自签名证书 |
| Tekton 信任 Harbor CA | 给 `tekton-pipelines-webhook` / `controller` 注入 CA（`kubectl patch`，升级后易失） |
| GitLab 项目 | `digitalsupply/openwebui`（源码）、`digitalsupply/openwebui-gitops`（GitOps） |
| GitLab PAT | 写入 `.secrets/env.sh` 与集群 Secret |
| GitLab Runner | 集群内 runner（id=3，tag `cicd`，k8s executor），使用 Harbor helper 镜像 |
| Runner RBAC | 授权 `default` SA 和 `gitlab-runner` SA，补 `pods/exec`、`pods/attach` |
| `.gitlab-ci.yml` | main push → 用 SA token POST PipelineRun 到 Tekton API（runner 无 kubectl） |
| Tekton Task | `git-clone`、`build-and-push`、`update-gitops-tag` |
| Tekton Pipeline | `open-webui-cicd`：clone → build/push → 改 GitOps tag |
| Dockerfile 适配 | 新增 `Dockerfile.harbor`：Harbor 基础镜像、Kaniko 兼容、跳过不可达外网下载 |
| Kustomize | `base/` + `overlays/prod/`；镜像 tag 只在 overlay 中改写 |
| ArgoCD | 新建 Application `open-webui`，auto-sync + selfHeal + prune |
| 首次发布 | 镜像 `a077c804`（225.4 MiB）→ Harbor → GitOps → K8s → `/health` 通过 |
| 端到端验证 | GitLab Pipeline #3~#10 全部 success；Argo 自动同步约 75 秒 |

关键提交（应用仓库）：

```text
fa4be157b ci: Harbor/kaniko-compatible Dockerfile
5bed2f6db ci: gitlab ci to trigger tekton pipelinerun on main push
d72234a81 ci: skip cypress binary download
aa23c3979 ci: skip onnxruntime-node CUDA binary download
60b1e4576 ci: build frontend with vite directly
f61751b20 ci: raise node heap for vite build (OOM)
c37e9204a ci: disable sourcemaps and raise node heap (OOM)
0b5f2eab8 chore: e2e pipeline verification
a077c804b chore: e2e verify 102047
```

### 4.2 2026-10-13：opencode-proxy sidecar

| 工作 | 结果 |
|---|---|
| 新增 `opencode-proxy` | nginx-unprivileged sidecar，监听 11435 |
| 注入 header | 代理到 opencode 上游时加 `x-opencode-session: open-webui-cngpt` |
| 固定上游 IP | 避免 DNS/解析问题；`proxy_ssl_name=opencode.ai` 保留 SNI |
| ConfigMap 滚动 | 用 `configMapGenerator` 生成哈希名，改 nginx.conf 自动触发 Pod 重建 |
| 流式支持 | `proxy_buffering off`、超时 900s，支持 SSE |

相关 GitOps 提交：

```text
5a8bea0 feat(open-webui): add opencode-proxy sidecar
21dc49b fix(open-webui): pin opencode upstream IP + configMapGenerator rollout
```

### 4.3 2026-10-14：frpc 公网暴露

| 工作 | 结果 |
|---|---|
| 背景 | Cloudflare Tunnel 在本网络严重不稳定，改用 VPS frp |
| 方案 | 集群内 frpc 主动拨号到 `49.233.210.176:7000`，由 VPS frps 暴露 HTTP |
| 公网入口 | `http://www.cngpt.ccwu.cc:8089`（腾讯云封 80/443，因域名未备案） |
| 初始版本 | 部署在独立 `frp` 命名空间 |
| 重构 | 移到 `base/frpc.yaml`，运行在 `open-webui` 命名空间，由 ArgoCD 管理 |
| 修复 | 给 frpc ServiceAccount 加 `imagePullSecrets: harbor-pull`，解决私有镜像拉取 |
| 配置 | `hostHeaderRewrite=cngpt.ccwu.cc`，兼容 www 子域；`loginFailExit=false` 防止瞬时断网 CrashLoop |

相关提交：

```text
5ee9e70 feat(frpc): expose open-webui through public VPS via frp tunnel
b359c20 refactor(frpc): move frpc into base for GitOps management
56fed70 fix(frpc): pull frpc image via SA imagePullSecrets (harbor-pull)
```

### 4.4 2026-10-26：资源分析与右规格化

分析结论：

- 集群 28 核 / 41.7 GiB，7 天平均 CPU 2.02 核（7%）、内存 17.9 GiB（43%）。
- Open WebUI 实际约 **7–16m CPU / 304–316 MiB 内存**，但申请 `500m / 2Gi`，limit `2 / 8Gi`。
- 内存 limit `8Gi` 大于 worker03 可分配内存 `7.66GiB`，存在节点级 OOM 风险。
- PVC 10Gi 实际只用约 5 MiB。
- 访问量极低：7 天 824 次请求，1 用户 / 4 会话。

调整（commit `6c69d48`）：

| 容器 | 调整前 | 调整后 |
|---|---|---|
| open-webui CPU req/limit | 500m / 2 | **100m / 500m** |
| open-webui Mem req/limit | 2Gi / 8Gi | **512Mi / 1Gi** |
| opencode-proxy CPU req/limit | 20m / 500m | **10m / 100m** |
| opencode-proxy Mem req/limit | 32Mi / 256Mi | **16Mi / 64Mi** |

worker03 调度预留变化：

```text
CPU requests:    1010m (25%)  → 600m (15%)
Memory requests: 2818Mi (35%) → 1266Mi (16%)
CPU limits:      4300m (107%) → 2400m (60%)
Memory limits:   11072Mi (141%) → 3712Mi (47%)
```

同一天还完成了：

- 确认 `gitops-openwebui/` 是无用的本地旧副本（非 Git 仓库、kustomize 构建失败、frpc 清单指向不存在的 `frp` 命名空间），删除。
- 删除前备份到 `/tmp/opencode/gitops-openwebui-backup-20261026.tar.gz`。
- 更新 `OPENWEBUI-CICD-GITOPS.md` 中过期路径。
- 将 GitLab GitOps 仓库正式克隆到 `/root/openwebuicicd/openwebui-gitops`。

### 4.5 2026-10-27：暂停应用（当前状态）

| 工作 | 结果 |
|---|---|
| 修改 overlay | `open-webui` 与 `frpc` 副本数均设为 **0** |
| 提交 | `36211cc chore: pause open-webui and frpc (replicas 0)` |
| 同步 | ArgoCD `Synced / Healthy`，revision `36211cc` |
| 结果 | 命名空间内 Pod 数 0；Deployment `0/0`；PVC `Bound`；Service/Ingress/Secret/ConfigMap 保留 |
| 访问 | 本地 Ingress 返回 503；公网 frpc 入口同时不可用 |
| 释放 | 调度预留 130m CPU / 560Mi 内存；实际内存约 300Mi |
| 数据 | SQLite 数据未动，PVC 保留 |

### 4.6 版本 / 提交对应关系

| 时间 | ArgoCD revision | 内容 |
|---|---|---|
| 2026-10-13 08:09 | `29e67e6` | 初始 GitOps base + overlay |
| 2026-10-13 10:17 | `f608d9b` | 修复 base images transformer 覆盖 overlay tag |
| 2026-10-13 10:36 | `e37d135` | 镜像 tag `a077c804` |
| 2026-10-13 12:21 | `5a8bea0` | opencode-proxy sidecar |
| 2026-10-13 12:45 | `21dc49b` | 固定上游 IP + ConfigMap hash |
| 2026-10-14 04:09 | `b359c20` | frpc 移入 base |
| 2026-10-14 04:19 | `56fed70` | frpc imagePullSecrets 修复 |
| 2026-10-26 13:52 | `6c69d48` | 资源右规格化 |
| 2026-10-27 14:21 | `36211cc` | 暂停（0 副本） |

### 4.7 踩坑记录汇总

| 问题 | 根因 | 解决 |
|---|---|---|
| GitLab Webhook 无法触发 | GitLab → 集群 10.0.0.0/24 无路由 | 集群内 Runner 主动轮询 |
| `git clone -b <sha>` 失败 | `-b` 只接受分支/tag，且 `--depth 1` | 浅克隆默认分支 + `git fetch` 精确 commit |
| ArgoCD `HTTP Basic: Access denied` | 仓库凭据缓存在 Redis | 清 Redis + 重启 repo-server/controller |
| Runner 报 `pods/exec` 无权限 | 作业 Pod 使用 `default` SA | RoleBinding 同时授权两个 SA，补 `pods/exec`/`pods/attach` |
| GitLab 19 注册 token | 传统 `runners_token` 已废弃 | API 预注册，保存一次性 `glrt-` token |
| Harbor 自签名证书 | containerd/Tekton 不信任 | 节点 `certs.d` + Tekton CA 注入 |
| helper 镜像拉取失败 | registry.gitlab.com 不可达 | helper 改用 Harbor 副本 |
| Kaniko 不支持 BuildKit mount | `RUN --mount=from=` | 独立 stage + `COPY --from` |
| 前端构建 OOM | vite 默认 2GB + sourcemap | `NODE_OPTIONS=8192` + 关闭 sourcemap |
| cypress/onnx/jsdelivr/HF 不可达 | 外网限制 | 环境变量跳过、vite 直出、`USE_SLIM=true` |
| frpc CrashLoop | 登录失败默认退出 | `loginFailExit=false` |
| frpc 私有镜像拉取失败 | SA 没有 imagePullSecrets | SA 增加 `harbor-pull` |
| 手工 scale 被改回 | ArgoCD `selfHeal: true` | 只改 Git，不直接改集群 |
| 旧目录误用 | 非 Git 仓库、结构过期 | 删除，统一使用 `openwebui-gitops/` |

---

## 5. 运维命令手册

### 5.1 环境准备

```bash
# 所有命令建议先加载凭据（不要把内容打印到终端历史/日志）
cd /root/openwebuicicd
source .secrets/env.sh

# 确认当前 context
kubectl config current-context

# 2026-10-27 m01 故障期间曾临时切换到 master02；22:51 已切回原 context。
# 备用 context 仍保留，m01 再次异常时可使用：
# kubectl config use-context kubernetes-admin@kubernetes-master02
# 切回：
# kubectl config use-context kubernetes-admin@kubernetes
```

### 5.2 状态检查（最常用）

```bash
# 应用与 Argo 状态
kubectl -n argocd get application open-webui -o wide
kubectl -n open-webui get deploy,pods,pvc,svc,ingress

# 当前副本与镜像
kubectl -n open-webui get deploy open-webui \
  -o jsonpath='{.spec.replicas}{" "}{.spec.template.spec.containers[0].image}{"\n"}'

# 资源实际占用
kubectl top pod -n open-webui --containers
kubectl top nodes

# 查看事件
kubectl -n open-webui get events --sort-by=.lastTimestamp

# 应用健康（恢复后）
kubectl -n open-webui port-forward svc/open-webui 8080:80
curl -s http://127.0.0.1:8080/health
```

### 5.3 暂停 / 恢复应用

#### 恢复（当前最可能需要）

```bash
cd /root/openwebuicicd/openwebui-gitops

# 方式一：回滚“暂停”提交（最干净，保留 Git 历史）
git revert 36211cc
git push origin main

# 方式二：手工把 overlay 中两个 count 改为 1
#   open-webui: count: 1
#   frpc:       count: 1
# 然后 commit + push

# 触发 ArgoCD 立即检查（可选）
kubectl -n argocd annotate application open-webui \
  argocd.argoproj.io/refresh=normal --overwrite

# 观察
kubectl -n argocd get application open-webui -o wide
kubectl -n open-webui get pods -w
```

恢复后验证：

```bash
# Pod 应 2/2 Running
kubectl -n open-webui get pods -o wide

# 健康检查
kubectl -n open-webui exec deploy/open-webui -c open-webui -- \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5).read().decode())"

# 本地 Ingress
curl -s -H 'Host: cngpt.ccwu.cc' http://10.0.0.252/health

# 公网（frpc 恢复后）
curl -s http://www.cngpt.ccwu.cc:8089/health
```

#### 再次暂停

```bash
cd /root/openwebuicicd/openwebui-gitops
# 编辑 overlays/prod/kustomization.yaml，把 open-webui 和 frpc 的 count 改为 0
git diff
git add overlays/prod/kustomization.yaml
git commit -m "chore: pause open-webui and frpc (replicas 0)"
git push origin main
```

> 不要用 `kubectl scale deploy/open-webui --replicas=0` 作为长期方案；ArgoCD 会在几分钟内按 Git 状态改回去。临时调试可以用，但必须知道会被还原。

### 5.4 发布新版本（正常 CI/CD）

```bash
cd /root/openwebuicicd/open-webui
# 修改代码
git add .
git commit -m "feat: xxx"
git push origin main
```

自动流程：

1. GitLab CI 创建 Pipeline（项目 1）。
2. 集群内 Runner 轮询到任务，POST `open-webui-cicd` PipelineRun。
3. Tekton：clone → Kaniko 构建并推送 Harbor → 修改 GitOps `newTag` 并 push。
4. ArgoCD 约 1–3 分钟同步新 tag。
5. Deployment `Recreate`，短暂中断后新 Pod 上线。

查看 Pipeline：

```bash
# GitLab 侧
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$GITLAB_APP_ID/pipelines?per_page=5" | python3 -m json.tool

# Tekton 侧
kubectl -n cicd get pipelinerun,taskrun,pods \
  -l app.kubernetes.io/part-of=openwebui-cicd

# 具体 PipelineRun
kubectl -n cicd describe pipelinerun <name>
kubectl -n cicd logs <build-pod> -c step-build
```

> 注意：应用当前是 0 副本。即使 CI 构建成功并更新 GitOps tag，**副本数仍由 overlay 的 `count: 0` 决定**，不会自动拉起。要上线必须先恢复副本数。

### 5.5 手动触发 Tekton（绕过 GitLab）

```bash
kubectl create -f - <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: open-webui-manual-
  namespace: cicd
  labels:
    app.kubernetes.io/part-of: openwebui-cicd
spec:
  pipelineRef:
    name: open-webui-cicd
  taskRunTemplate:
    serviceAccountName: pipeline
  timeouts:
    pipeline: 90m0s
  params:
    - name: git-url
      value: "http://192.168.67.201/digitalsupply/openwebui.git"
    - name: git-revision
      value: main
    - name: image-repository
      value: "192.168.67.202:8443/openwebui/open-webui"
    - name: image-tag
      value: "manual-$(date +%s)"
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
          storageClassName: nfs-sc
EOF
```

构建日志（Pod 已退出时）：

```bash
POD=$(kubectl -n cicd get pods -l tekton.dev/pipelineRun=<pr-name> -o name | head -1)
kubectl -n cicd logs "$POD" -c step-build

# 如果 Pod 已删除，从节点 containerd 取：
NODE=$(kubectl -n cicd get pod <pod> -o jsonpath='{.status.hostIP}')
CID=$(kubectl -n cicd get pod <pod> \
  -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's#containerd://##')
ssh root@$NODE "crictl logs $CID | tail -60"
```

### 5.6 ArgoCD 操作

```bash
# 状态
kubectl -n argocd get application open-webui -o wide
kubectl -n argocd get application open-webui -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'

# 强制刷新 Git（不触发 sync）
kubectl -n argocd annotate application open-webui \
  argocd.argoproj.io/refresh=normal --overwrite

# 查看历史 revision
kubectl -n argocd get application open-webui -o json \
  | python3 -c 'import sys,json; [print(h["id"],h["revision"][:8],h["deployedAt"]) for h in json.load(sys.stdin)["status"]["history"]]'

# 回滚镜像 tag（推荐，走 Git）
cd /root/openwebuicicd/openwebui-gitops
sed -i 's/newTag: .*/newTag: <old-tag>/' overlays/prod/kustomization.yaml
git commit -am "rollback: open-webui to <old-tag>" && git push origin main
```

**ArgoCD 凭据缓存问题**（如果改过 repo secret 后报 `HTTP Basic: Access denied`）：

```bash
RPASS=$(kubectl -n argocd get secret argocd-redis -o jsonpath='{.data.auth}' | base64 -d)
kubectl -n argocd exec deploy/argocd-redis -- redis-cli -a "$RPASS" FLUSHALL
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

### 5.7 Harbor 操作

```bash
source /root/openwebuicicd/.secrets/env.sh

# 列出项目
curl -ksS -u "$HARBOR_USER:$HARBOR_PASS" \
  "$HARBOR_URL/api/v2.0/projects?page_size=50" | python3 -m json.tool

# 列出 openwebui 仓库
curl -ksS -u "$HARBOR_USER:$HARBOR_PASS" \
  "$HARBOR_URL/api/v2.0/projects/openwebui/repositories?page_size=100" | python3 -m json.tool

# 查看 open-webui 的 tag
curl -ksS -u "$HARBOR_USER:$HARBOR_PASS" \
  "$HARBOR_URL/api/v2.0/projects/openwebui/repositories/open-webui/artifacts?page_size=20&with_tag=true" \
  | python3 -m json.tool

# 登录/拉取（示例，密码不要写进脚本）
docker login 192.168.67.202:8443 -u "$HARBOR_USER" -p "$HARBOR_PASS"
docker pull 192.168.67.202:8443/openwebui/open-webui:a077c804
```

> Harbor 是自签名证书；节点 containerd 已配置 `certs.d`，本机 docker 可能需要 `--tls-verify=false` 或导入 CA。

### 5.8 GitLab API 常用查询

```bash
source /root/openwebuicicd/.secrets/env.sh

# 项目列表
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects?per_page=100&simple=true" | python3 -m json.tool

# openwebui 最近 Pipeline
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$GITLAB_APP_ID/pipelines?per_page=5" | python3 -m json.tool

# Runner 状态
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/runners/all" | python3 -m json.tool
```

### 5.9 SQLite 数据备份 / 恢复

数据库：`/app/backend/data/webui.db`，位于 PVC `open-webui-data`。

**应用运行时在线备份：**

```bash
kubectl -n open-webui exec deploy/open-webui -c open-webui -- \
  python - <<'PY'
import sqlite3
src = sqlite3.connect('/app/backend/data/webui.db')
dst = sqlite3.connect('/app/backend/data/webui.db.backup')
src.backup(dst)
dst.close(); src.close()
print('backup done')
PY

kubectl -n open-webui cp \
  open-webui-<pod>:/app/backend/data/webui.db.backup ./webui.db.backup
```

**应用暂停（0 副本）时备份：**

需要临时 Pod 挂载 PVC（RWO 必须确保没有其他 Pod 使用）：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: owui-db-backup
  namespace: open-webui
spec:
  restartPolicy: Never
  containers:
    - name: backup
      image: 192.168.67.202:8443/openwebui/open-webui:a077c804
      command: ["python", "-c"]
      args:
        - |
          import sqlite3
          s=sqlite3.connect('/data/webui.db')
          d=sqlite3.connect('/data/webui.db.backup')
          s.backup(d); d.close(); s.close()
          print('done')
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: open-webui-data
```

```bash
kubectl apply -f backup-pod.yaml
kubectl -n open-webui wait --for=condition=Ready pod/owui-db-backup --timeout=120s
kubectl -n open-webui cp owui-db-backup:/data/webui.db.backup ./webui.db.backup
kubectl -n open-webui delete pod owui-db-backup
```

**恢复：**

1. 确保应用为 0 副本（避免写冲突）。
2. 用临时 Pod 把备份文件写回 `/data/webui.db`。
3. 删除临时 Pod，恢复副本数。
4. 校验 `PRAGMA integrity_check;` 和用户/会话数。

> 现有目录里有两个历史手工备份：`webui.db.bak-20261013125203`、`webui.db.bak-20261014124839`。目前**没有自动备份 CronJob**，这是当前最大的数据风险。

### 5.10 CI 遗留资源清理

当前 `cicd` 中约有 **15 个 PipelineRun、63 个 Pod、17 个 PVC**，其中大量是已完成的历史 Pod。

`cicd-cleanup` CronJob（每天 03:00，`RETAIN_DAYS=7`）只删除 **PipelineRun**，依赖 ownerReference 级联；**独立 TaskRun / 手工 Pod / 未被 PipelineRun 拥有的 PVC 不会被清理**。

安全清理（先看再删）：

```bash
# 查看已完成的 Pod
kubectl -n cicd get pods --field-selector status.phase=Succeeded

# 删除 7 天前的已完成 Pod（示例）
kubectl -n cicd get pods --field-selector status.phase=Succeeded \
  -o json | python3 - <<'PY'
import sys,json,datetime,subprocess
now=datetime.datetime.now(datetime.timezone.utc)
for p in json.load(sys.stdin)['items']:
    ts=datetime.datetime.fromisoformat(p['metadata']['creationTimestamp'].replace('Z','+00:00'))
    if (now-ts).days > 7:
        print(p['metadata']['name'])
        # subprocess.run(['kubectl','-n','cicd','delete','pod',p['metadata']['name']])
PY

# 查看无主 PVC（确认后再删）
kubectl -n cicd get pvc -o custom-columns='NAME:.metadata.name,SIZE:.spec.resources.requests.storage,CREATED:.metadata.creationTimestamp,OWNER:.metadata.ownerReferences[*].kind'
```

> 删除 PVC 会丢构建缓存，但不会影响 Open WebUI 的 `open-webui-data`（在另一个命名空间）。

### 5.11 故障排查速查

| 症状 | 检查 | 处理 |
|---|---|---|
| push 后没有 Pipeline | GitLab Runner 是否 online；GitLab CI 是否 success | `kubectl -n gitlab-runner logs deploy/gitlab-runner`；重建 runner |
| PipelineRun 卡住 | `kubectl -n cicd describe pipelinerun <name>` | 看 conditions / taskrun 事件 |
| 构建失败 | `step-build` 日志 | 对照 §4.7 的 Kaniko/OOM/网络问题 |
| ImagePullBackOff | 镜像是否存在、`harbor-pull` 是否可用 | Harbor API 查 tag；检查 imagePullSecrets |
| Argo 不同步 | Application 状态、repo secret | 刷新；必要时清 Redis 缓存 |
| 应用 503 | Pod 是否 0 副本；Service endpoints | 恢复副本；`kubectl get endpoints open-webui` |
| 数据库锁 | 是否有多个 Pod 挂同一 RWO PVC | 确保 1 副本，策略 Recreate |
| Pod OOMKilled | `kubectl describe pod`，看 lastState | Git 中提高 memory limit（当前 1Gi） |
| 节点 DiskPressure | `kubectl describe node`，磁盘使用率 | 清理镜像/日志；关注 m01、worker01 |

---

## 6. 注意事项与已知风险

### 6.1 暂停状态相关

1. 当前 `open-webui` 和 `frpc` 都是 **0 副本**；`cngpt.ccwu.cc` 返回 **503**，公网 8089 也不可用，这是预期行为。
2. 恢复必须走 Git（`git revert 36211cc` 或把 overlay 的 count 改回 1），不要只 `kubectl scale`。
3. 暂停不会删除 PVC；但**不要**从 Git 中删除 `open-webui-data` 的 PVC 定义，否则 ArgoCD `prune` 会删除 PVC（虽然 PV 是 `Retain`，恢复需人工操作）。
4. 暂停期间没有运行中的 Pod，不能直接 `kubectl exec` 查数据库；备份需临时 Pod（见 §5.9）。

### 6.2 数据与可用性

1. **SQLite + RWO PVC** 决定了只能单副本、`Recreate`；发布时会短暂中断。
2. **没有自动备份**：只有手工 `.bak` 文件。建议增加 CronJob 定期 `sqlite3 .backup` 到独立 PVC/对象存储。
3. PVC 10Gi 实际只用约 5 MiB；RBD 瘦分配，物理占用小，但逻辑配额仍按 10Gi 计。
4. PV 回收策略 `Retain`；PVC 误删后底层 RBD 卷仍保留，可人工恢复。

### 6.3 GitOps / ArgoCD

1. `selfHeal: true`：任何 `kubectl edit/scale/patch` 都会被改回 Git 状态。
2. `prune: true`：从 Git 删除资源会真的删除集群资源（包括 PVC，需特别小心）。
3. 仓库凭据缓存在 Redis；修改 repo secret 后必须 `FLUSHALL` + 重启（见 §5.6）。
4. `open-webui` Application 当前 revision `36211cc`；历史见 §4.6。
5. 旧 ReplicaSet 有多个 0/0 记录，属于正常历史版本；`revisionHistoryLimit` 默认 10，不影响运行。

### 6.4 资源与容量

1. 资源右规格化后：requests `100m/512Mi`，limits `500m/1Gi`；如果未来启用文档解析、RAG、嵌入模型，1Gi 可能不够，需监控 OOM 并提高 limit。
2. 暂停释放的调度预留只有 **130m CPU / 560Mi 内存**，实际内存约 **300Mi**；不要期待大幅降低集群水位。
3. 节点压力点：
   - `m01`：事故重启后内存 49%、根分区 **47%**（已清理 15G 缓存）；但仍需关注 BuildKit 构建；
   - `master02` 内存 75%；
   - `worker01` 根分区 **72.4%**；
   - `worker03` 根分区约 66%，当前 BuildKit 缓存/构建仍在增长。
   建议关注磁盘清理和内存峰值。
4. 集群整体 7 天平均 CPU 约 2 核（7%）、内存 18 GiB（43%），仍有较大余量；主要占用在系统/监控/日志组件，而不是业务应用。

### 6.5 CI/CD 与网络

1. GitLab → 集群无入站路由；不要尝试配置 GitLab Webhook 直连 EventListener。
2. Docker Hub / gcr.io / github.com / huggingface.co 不可达；新增依赖前先确认，必要时预置到 Harbor。
3. `Dockerfile.harbor` 是针对本环境的定制文件；上游 `Dockerfile` 保持原样。上游更新后需重新评估适配。
4. Kaniko 不支持部分 BuildKit 语法；新增 Dockerfile 特性前先本地验证。
5. Tekton 的 Harbor CA 注入是 `kubectl patch`，**Tekton 升级后会丢失**，需重新执行。
6. `USE_SLIM=true`：RAG / Whisper / 嵌入模型不预置；当前网络下相关功能不可用。
7. 未部署 Ollama；模型连接在 Open WebUI 设置中手工配置（或通过 opencode-proxy）。
8. Ingress 未配置 TLS，当前是 HTTP；公网通过 VPS 8089 也是 HTTP。

### 6.6 清理与遗留

1. `cicd` 有 15 个 PipelineRun、63 个 Pod、17 个 PVC；`cicd-cleanup` 只清理 PipelineRun，独立 TaskRun/Pod/PVC 会堆积。
2. 旧演示流水线 `tekton-demo-*` 仍指向已下线的 `10.0.0.41` / `10.0.0.200`，未删除；不要误用。
3. 旧的 `gitops-openwebui/` 已删除；如发现其他旧副本，不要用于发布，统一使用 `openwebuicicd/openwebui-gitops/`。
4. `monitoring` 的 NFS PVC 上报的容量/使用量三家完全相同（约 41 GiB），是 NFS 导出统计口径问题，不能据此判断单个 PVC 真实用量。

### 6.7 安全（重要）

1. **明文凭据**：
   - `.secrets/env.sh`（600）含 GitLab PAT、Harbor 账号、VPS token 等；
   - `OPENWEBUI-CICD-GITOPS.md` §5 直接写了 GitLab PAT、Harbor admin 密码、Harbor robot 密码；
   - 应用/GitOps 仓库的 `.git/config` remote URL 内嵌 PAT；
   - `base/frpc.yaml` 内含 frp token 明文。
   > 建议：轮换所有凭据；文档分享前脱敏；改用 SSH/credential helper 或 GitLab Deploy Token；敏感值放 Secret Manager，不写进 Git。
2. Harbor 项目 `openwebui` 是 private，必须使用 `harbor-pull` imagePullSecrets。
3. GitLab Runner token `glrt-` 只在创建时返回一次，妥善保存；连续健康检查失败会被禁用 1 小时。
4. 当前为内网验证环境，未启用 TLS、未做网络策略、未做外部安全扫描。

### 6.8 同集群其他项目（现状，不属于 Open WebUI）

| 项目 | 状态 | 备注 |
|---|---|---|
| `compassio` | Argo Synced/Healthy | 业务正常，`compassio.xyz` |
| `deeptutor` | Argo Synced/**Degraded** | Pod `ImagePullBackOff`：`192.168.67.202:8443/deeptutor/deeptutor:init` not found |
| `n8n` | 运行中 | 约 3m CPU / 320Mi 内存 |
| `kafka` | 运行中 | 单 broker，约 1.8 GiB |
| `cnpg-system` | 运行中 | PostgreSQL，Open WebUI 未使用 |
| `monitoring` / `logging` | 运行中 | 集群主要资源占用来源之一 |

> 处理 deeptutor 需要单独排查其 Harbor 镜像/构建流水线，不在本文范围内。

### 6.9 m01 控制面节点 NotReady 事故复盘（2026-10-27，已恢复）

#### 结论

**根因：BuildKit 在 m01 上执行 DeepTutor 重型构建，内存/CPU 被耗尽，导致 kubelet/containerd/SSH/API 全部失去响应。**

不是硬件故障，也不是 etcd 数据损坏；是**构建负载跑在资源不足的控制面节点上**导致的节点级资源饥饿。m01 已硬重启恢复，数据与 etcd 正常。

#### 时间线

| 时间（CST） | 事件 |
|---|---|
| 21:58 | m01 正常：load 0.3，CPU 10%，可用内存 1.3 GiB，根分区可用 23.5 GB |
| 22:00 | DeepTutor PipelineRun `deeptutor-cicd-714876c0` 开始构建；BuildKit 开始占用资源 |
| 22:04 | CPU 54.8%，可用内存 **0.4 GiB**，BuildKit 内存 2.2 GiB，根分区可用 18.5 GB |
| 22:15–22:17 | containerd/kubelet 出现大量 `ExecSync ... context deadline exceeded`；buildkitd 进入 CrashLoopBackOff；构建报 `failed to receive status ... graceful_stop` |
| 22:16 | **load1 49.22，可用内存 0.2 GiB，BuildKit 内存 5.0 GiB**，节点指标开始断采 |
| 22:27 | kubelet 停止上报（`NodeStatusUnknown`） |
| 22:30 | Node 正式变为 **NotReady**；SSH/API/控制台登录开始超时 |
| 22:32–22:39 | containerd ttrpc/event stream 超时；`systemd-logind` 会话创建超时；`hermes` 网关看门狗报 liveness 失败 |
| 22:43 | buildkitd 已在 worker03 上重新拉起（Deployment 当前 `nodeSelector: worker03`） |
| 22:44:37 | `qm reboot 119`（ACPI）无响应，Ctrl+Alt+Del 也无效；执行 **`qm reset 119` 硬重启** |
| 22:45:33 | **m01 Ready**；etcd/apiserver/controller-manager/scheduler 全部恢复 |
| 22:47 | 清理 m01 上 **15 GiB** 遗留 BuildKit 缓存，根分区 **77% → 47%** |
| 22:51 | kubeconfig 切回原 context `kubernetes-admin@kubernetes`；m01 API `/healthz` 返回 200 |

#### 关键证据

Prometheus 1 分钟粒度（m01）：

| 时间 | load1 | CPU% | 可用内存 GiB | 根分区可用 GiB | BuildKit CPU | BuildKit 内存 MiB |
|---|---:|---:|---:|---:|---:|---:|
| 21:58 | 0.3 | 10.0 | 1.4 | 23.5 | 0.0 | 150 |
| 22:00 | 1.2 | 31.0 | 1.2 | 23.1 | 1.3 | 833 |
| 22:04 | 3.7 | 54.8 | **0.4** | 18.5 | 2.8 | 2232 |
| **22:16** | **49.2** | — | **0.2** | 18.0 | 1.8 | **5047** |
| 22:20 | 3.5 | 69.6 | 2.1 | 17.1 | 3.6 | 1262 |
| 22:26 | 1.6 | 29.3 | 1.9 | 12.2 | 1.5 | 1793 |
| 22:30 | — | — | — | 12.1 | 2.7 | — |

磁盘与缓存：

```text
/var/lib/buildkitd-cache  15 GiB（清理前）
根分区可用：25.3 GB（22:00）→ 12.4 GB（22:30），约 13 GB 被构建缓存/中间层消耗
BuildKit 缓存快照包含 Next.js / Rust 工具链（librustc_driver、libLLVM、next-swc 等）
```

日志证据：

- `/var/log/messages` 22:15–22:17：kubelet/containerd 大量 `ExecSync ... timeout 10s exceeded`、`context deadline exceeded`。
- 同一时间 BuildKit 构建失败：`failed to receive status: rpc error ... closing transport ... graceful_stop`。
- 22:30: `systemd-logind: Failed to start session scope ... Connection timed out`（控制台/SSH 登录挂起）。
- 22:39: `hermes ... Gateway event loop missed 3 consecutive liveness probes`（节点资源饥饿的连带症状，不是根因）。

#### 根因链

```text
DeepTutor push
  → Tekton build-push Pod（调度在 worker03/worker02）
  → BUILDKIT_HOST=tcp://buildkitd.cicd.svc:1234
  → 实际构建发生在 buildkitd Pod 所在节点（当时是 m01）
  → buildkitd: privileged + max-parallelism=4 + limits 4 CPU / 8 GiB
  → m01 只有 4 vCPU / 5.5 GiB，无 swap
  → 构建缓存写入 15 GiB，内存峰值 5.0 GiB，load1 49
  → 可用内存仅 0.2 GiB；kubelet/containerd/CRI 全部超时
  → kubelet 停止上报；m01 NotReady；SSH/API/控制台挂起
```

关键设计问题：

1. **buildkitd 的内存 limit 8 GiB 大于 m01 可分配内存 5.5 GiB**，容器可以吃光整台节点；8 GiB 也大于当前 worker03 的 7.66 GiB。
2. **`max-parallelism = 4`**，在 4 核节点上并发 4 个重型构建步骤，CPU/内存峰值不可控。
3. **特权 + hostPath 缓存**：构建缓存直接写 `/var/lib/buildkitd-cache`，没有容量上限/GC。
4. **构建 Pod 与 BuildKit 不在同一节点**，容易误判“构建在 worker03 上，不会影响 m01”；实际上所有 `buildctl` 请求都打到 m01 的 buildkitd。
5. **journald 未持久化**（`/var/log/journal` 不存在），重启后上一 boot 的 journal 丢失，只能靠 `/var/log/messages` + Prometheus 复盘。
6. 控制面节点已有 `NoSchedule` taint，但历史 buildkitd Pod 仍在 m01 上运行；迁移/重建时需确认新 Pod 不再落到控制面。

#### 已执行的恢复操作

```bash
# 1. 优雅重启失败（guest agent 未运行，ACPI 无响应）
qm reboot 119

# 2. Ctrl+Alt+Del 也无效，执行硬重启
qm reset 119

# 3. 节点恢复
kubectl get node m01        # Ready
kubectl -n kube-system exec etcd-m01 -- etcdctl ... endpoint health
# https://127.0.0.1:2379 is healthy

# 4. 清理 m01 上已迁移的 BuildKit 缓存
rm -rf /var/lib/buildkitd-cache/*
df -h /                     # 77% → 47%，可用 26G

# 5. 切回原 kubeconfig
kubectl config use-context kubernetes-admin@kubernetes
```

当前状态：

| 项目 | 状态 |
|---|---|
| 6 个节点 | 全部 **Ready** |
| m01 | Ready；load ~0.22；内存 49%；根分区 **47%** |
| etcd | 3/3 成员 `started`；m01 endpoint healthy |
| m01 系统 Pod | calico/etcd/apiserver/controller-manager/scheduler/kube-proxy/kube-vip 全部 Running |
| kubeconfig | `kubernetes-admin@kubernetes`（10.0.0.61）；master02 备用 context 保留 |
| 备份 | `~/.kube/config.bak-20261027-m01` |

#### 后续加固建议（按优先级）

1. **限制 buildkitd 资源（P0）**：当前 `limits: 4 CPU / 8 GiB`、`max-parallelism=4` 仍然危险。
   ```bash
   # 建议值（等当前构建结束或维护窗口执行，会重启 buildkitd）
   kubectl -n cicd set resources deploy/buildkitd -c buildkitd \
     --requests=cpu=500m,memory=1Gi \
     --limits=cpu=2,memory=4Gi

   # buildkitd-config: max-parallelism 4 → 2
   kubectl -n cicd edit cm buildkitd-config
   kubectl -n cicd rollout restart deploy/buildkitd
   ```
2. **给 BuildKit 缓存设上限/定期清理**：`/var/lib/buildkitd-cache` 当前在 worker03 上会继续增长；建议加节点 CronJob 或 BuildKit GC，磁盘使用 >70% 告警。
3. **把 buildkitd 放到 worker01/worker02 或专用构建节点**：worker01/02 为 6 核 / 9.7 GiB，比 worker03（4 核 / 7.66 GiB）更适合；不要放控制面。
4. **限制并发构建**：DeepTutor / CompassIO 不要同时跑重型构建；可在 Tekton 侧加并发锁或 `PipelineRun` 串行化。
5. **持久化 journald**：所有节点执行 `mkdir -p /var/log/journal`，`journald.conf` 设 `Storage=persistent`、`SystemMaxUse=2G`，否则下次故障仍无本地历史日志。
6. **监控告警**：node load > 2×核数持续 5 分钟、可用内存 < 10%、根分区 > 80%、`up{job="kubelet"}=0`、容器 OOMKilled、BuildKit 缓存目录大小。
7. **通用规则**：任何容器 memory limit 不应大于节点可分配内存的 60%；禁止在控制面节点跑构建负载。
8. **宿主机存储风险（独立问题）**：Proxmox `dmeventd` 报 `Insufficient free space: 40669 extents needed, but only 4096 available`；`pve` VG 仅剩 16 GiB，`local-lvm` thin pool 72.41%，多个旧 VM 磁盘 LV 已 99.99%。建议扩容 VG 或清理旧 VM/快照，避免后续 thin pool 自动扩容失败。

#### 当前遗留风险

- `deeptutor-cicd-fontfix` 构建仍在 worker03 上运行；worker03 根分区约 66%，内存约 45%。如果构建进入 Rust/Next.js 编译高峰，仍可能再次出现高内存/高 CPU。
- buildkitd 仍是 `4 CPU / 8 GiB` 上限、`max-parallelism=4`；在加固前不要并发触发多个重型构建。
- 旧的 buildkitd ReplicaSet（多个 0/0）保留在 `cicd`，属于历史记录；不影响运行。

> 该事故与 Open WebUI 无关；Open WebUI 仍为 0 副本，PVC 数据和 ArgoCD 状态未受影响。


---

## 7. 恢复演练 Checklist

需要恢复 Open WebUI 时按顺序执行：

- [ ] 确认当前没有其他人在改 GitOps 仓库：`git -C /root/openwebuicicd/openwebui-gitops status`
- [ ] 恢复副本：`git revert 36211cc && git push origin main`（或手工改 count=1）
- [ ] 触发 Argo 刷新：`kubectl -n argocd annotate application open-webui argocd.argoproj.io/refresh=normal --overwrite`
- [ ] 确认 Argo：`Synced / Healthy`，revision 为新提交
- [ ] 确认 Pod：`2/2 Running`，无 CrashLoop/OOM
- [ ] 确认应用：`/health` 返回 `{"status":true}`
- [ ] 确认 Service endpoints 非空：`kubectl -n open-webui get endpoints open-webui`
- [ ] 确认本地 Ingress：`curl -H 'Host: cngpt.ccwu.cc' http://10.0.0.252/health`
- [ ] 确认公网：`curl http://www.cngpt.ccwu.cc:8089/health`（frpc 也恢复后）
- [ ] 确认数据：用户数 / 会话数符合预期（登录 Web UI 检查）
- [ ] 观察 10 分钟资源：`kubectl top pod -n open-webui`
- [ ] 如果 OOMKilled：在 Git 中把 memory limit 调到 2Gi，再同步

回滚暂停：

```bash
cd /root/openwebuicicd/openwebui-gitops
git revert <恢复提交的 SHA>
git push origin main
```

---

## 8. 附录

### 8.1 端点速查

| 用途 | 地址 |
|---|---|
| GitLab | `http://192.168.67.201` |
| Harbor | `https://192.168.67.202:8443` |
| Harbor 项目 | `openwebui` / `compassio` / `deeptutor` |
| K8s API | `https://10.0.0.61:6443`（kubeconfig 当前 context） |
| ArgoCD | `argocd` 命名空间；`kubectl -n argocd get app` |
| Tekton | `cicd` 命名空间；Pipeline `open-webui-cicd` |
| Traefik LB | `10.0.0.252` |
| 内网访问 | `http://cngpt.ccwu.cc`（hosts → 10.0.0.252） |
| 公网访问 | `http://www.cngpt.ccwu.cc:8089`（frpc，当前暂停） |
| 应用健康 | `GET /health` |
| Prometheus | `monitoring` 命名空间，`prometheus-prometheus:9090` |
| Grafana | `monitoring` 命名空间，`prometheus-grafana:80` |

### 8.2 关键文件

| 文件 | 说明 |
|---|---|
| `/root/openwebuicicd/open-webui/` | 应用源码；`.gitlab-ci.yml`、`Dockerfile.harbor` |
| `/root/openwebuicicd/openwebui-gitops/base/10-open-webui.yaml` | PVC/Secret/Deployment/Service/Ingress |
| `/root/openwebuicicd/openwebui-gitops/base/frpc.yaml` | frpc 隧道 |
| `/root/openwebuicicd/openwebui-gitops/overlays/prod/kustomization.yaml` | 镜像 tag + 副本数（当前 0） |
| `/root/openwebuicicd/deploy/cicd/` | Tekton Task/Pipeline 参考 |
| `/root/openwebuicicd/deploy/runner/` | Runner 部署参考 |
| `/root/openwebuicicd/.secrets/env.sh` | 凭据（600） |
| `/root/openwebuicicd/OPENWEBUI-CICD-GITOPS.md` | 详细建设记录（含明文凭据，注意脱敏） |

### 8.3 变更记录（本次会话）

| 日期 | 变更 | 提交 / 操作 |
|---|---|---|
| 2026-10-26 | Open WebUI 资源右规格化 | `6c69d48` |
| 2026-10-26 | 删除无用 `gitops-openwebui/` | 本地删除，备份在 `/tmp/opencode/` |
| 2026-10-26 | 建立正式 GitOps 本地克隆 | `/root/openwebuicicd/openwebui-gitops` |
| 2026-10-27 | 暂停 Open WebUI + frpc | `36211cc`，Argo revision `36211cc` |
| 2026-10-27 | m01 NotReady：BuildKit 构建资源耗尽，硬重启恢复 | 22:44:37 `qm reset 119`；22:45:33 Ready |
| 2026-10-27 | 清理 m01 遗留 BuildKit 缓存 15 GiB | 根分区 77% → 47% |
| 2026-10-27 | kubeconfig 切回原 context | `kubernetes-admin@kubernetes` |
| 2026-10-27 | 创建本运维手册 | 本文件 |

### 8.4 当前快照（2026-10-27）

```text
ArgoCD:
  open-webui   Synced / Healthy   36211cc
  compassio    Synced / Healthy   7f1fe29c
  deeptutor    Synced / Degraded  c769a415

Open WebUI:
  Deployment open-webui   0/0
  Deployment frpc         0/0
  Pods                    0
  PVC open-webui-data     Bound 10Gi
  Ingress cngpt.ccwu.cc   503
  Image a077c804          225.4 MiB
  SQLite                  约 0.8 MiB，1 user / 4 chats

集群:
  6 nodes / 28 vCPU / 41.7 GiB
  23 namespaces / 79 workloads / 32 PVC
  7d avg CPU 2.03 cores (7%) / MEM 18.0 GiB (43%)

m01:
  Ready, load ~0.22, MEM 49%, disk 47%
  etcd 3/3 members started
  kubeconfig = kubernetes-admin@kubernetes (10.0.0.61)

BuildKit（当前风险）:
  buildkitd node = worker03
  limits = 4 CPU / 8 GiB (大于 worker03 7.66 GiB，未加固)
  max-parallelism = 4
  deeptutor-cicd-fontfix build 仍在运行
```
