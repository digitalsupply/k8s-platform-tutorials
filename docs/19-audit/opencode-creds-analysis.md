# CI/CD 凭据全景：GitLab / Harbor / Kubernetes / ArgoCD / Tekton

> 取证对象：四条流水线 `openwebui`、`compassio`、`deeptutor`、`china-study-free`。
> 取证方式：全部结论以实机为准 —— `kubectl`、SSH 到 GitLab 主机执行只读 `gitlab-rails runner`、Harbor v2 API、以及从 Pod 内发起的连通性测试。
> 取证时间：2026-11-12。
> 安全约定：本文只记录“凭据是什么类型、在哪个 Secret 的哪个 key、谁能读”，**不记录任何 token/密码/密文的值**；命令中的凭据一律用变量或占位符表示。

---

## 0. 一页速查

| 项 | 实测值 | 依据 |
|---|---|---|
| GitLab | CE 19.5.0，11 个项目、2 个 group、4 个用户 | `gitlab-rails runner 'puts Gitlab::VERSION; puts Project.count'` |
| Harbor | v2.14.5-c83198c6，5 个项目、0 个 robot、admin 单账号贯通 | `GET /api/v2.0/systeminfo`、`/api/v2.0/robots` |
| 集群 | 6 节点（10.0.0.61 / .120–.124），Traefik LB `10.0.0.252` | `kubectl get nodes -o wide`、`kubectl -n traefik get svc` |
| Tekton | Pipelines v1.15.5，Triggers v0.37.2，`cicd` 内 12 个 Task、4 条 Pipeline、3 个 EventListener | `kubectl -n cicd get task,pipeline` |
| ArgoCD | v3.5.3，42 个 Application，全部 automated sync，`timeout.reconciliation=120s` | `kubectl -n argocd get applications`、`argocd-cm` |
| `cicd` Secret | 7 个：6 个 GitLab 相关 + `harbor-auth` | `kubectl -n cicd get secret -o json` |
| GitLab 有效 token | 2 个 group access token（group 2 / group 8）+ 6 个 deploy token | `PersonalAccessToken` / `DeployToken` 表 |
| Harbor 认证 | 5 个 dockerconfig Secret + GitLab 主机的 docker config，**同一份 admin 凭据** | 逐份解出后比较 `user:pass` 的 SHA-256 |
| 触发模型 | 3 条 webhook 推模型 + 1 条 Runner 拉模型（openwebui） | GitLab `web_hooks`、`.gitlab-ci.yml` |
| 最高风险 | `digitalsupply` group token 可写 `platform-gitops`，ArgoCD 有集群通配权限 | 见 §6 R1 |

三个最需要记住的结论：

1. **两条不同来源的凭据都能走到“集群管理员”**：`digitalsupply` group token 能写 `platform-gitops` 的 `main`（实测 dry-run 通过鉴权），而 ArgoCD application-controller 的 ClusterRole 是 `*/*/*`；另一条是 `cicd/pipeline` SA 绑定了 `ClusterRole/edit`，任一流水线 Pod 都能读全集群 Secret、在任意 namespace 建 Pod。
2. **Harbor 侧根本没有 robot**：所有构建、拉取、推送都用同一个 admin；这份 admin 口令同时存在于 5 个 K8s Secret 和 GitLab 主机的 `/root/.docker/config.json`，轮换任何一处不同步都会断链。
3. **`gitlab-auth` 与 `china-study-free-gitlab-auth` 是同一个 token 的两个副本**，名字不同只是障眼法；轮换时必须同时改，漏一个就静默失效。

---

## 1. 概念辨析

### 1.1 GitLab 的五种“钥匙”

先给结论：**它们不是同一种东西的不同叫法，而是五种身份模型**。判断风险时看“它代表谁、能碰到什么”，不要看字符串长度。

| 类型 | 身份主体 | 作用域 | 能否跨 group | 能否调 REST API | 本环境是否使用 |
|---|---|---|---|---|---|
| Personal access token (PAT) | 一个真实用户 | 该用户能访问的一切，受 scope 限制 | 能 | 能（取决于 scope） | 仅历史遗留，已吊销 |
| Group access token | 该 group 的 bot 用户 | 该 group 及其子 group 的项目 | 不能 | 能，但受 scope 限制 | **是**，`ci-rw` × 2 |
| Project access token | 该项目的 bot 用户 | 单个项目 | 不能 | 能，但受 scope 限制 | 否 |
| Deploy token | 无用户身份的项目级凭证 | 单个项目（或 group）的仓库/包/镜像 | 不能 | 基本不能（只覆盖 git/registry 端点） | **是**，`argocd-ro` × 6 |
| CI job token | 一次 CI job 的临时身份 | 当前项目及白名单 | 不能 | 有限（job 相关端点） | 否（四条流水线都未用） |

#### PAT（personal access token）

- 身份就是创建它的那个用户。这里数据库里只剩两条 root 的 PAT：
  - `cicd-agent`：root，scope `api`，2026-10-13 创建，**已吊销**；
  - `deeptutor-gitops`：root，scope `api` + `read_repository` + `write_repository`，2026-10-27 创建，**已吊销**。
- 它们代表“实例管理员”，因为 root 是 `admin=true`；`api` scope 再加 admin，等于可以改项目、读 CI 变量、签发新 token、走 Admin API。
- **现在没有任何有效 PAT**。这一点很关键：如果还有系统拿 root PAT 做自动化，它已经坏了；反过来，泄露面已经收敛。
- 依据：`ssh root@192.168.67.201 'gitlab-rails runner "PersonalAccessToken.find_each { ... }"'`；`User.find_each` 显示 root 为 admin。

#### Group access token

- 创建后 GitLab 会生成一个 bot 用户，用户名形如 `group_2_bot_<hash>`；token 的“所有者”是这个 bot，不是人。
- 它的权限 = bot 在该 group 的成员角色 ∩ token 的 scope。本环境两个 bot 都是 **Maintainer（access_level=40）**。
- 本环境只有两个有效 token：
  - id=3，bot `group_2_bot_35e9…`，属于 `digitalsupply`（group 2），scope `read_repository, write_repository`，2027-11-12 到期；
  - id=4，bot `group_8_bot_d1d3…`，属于 `deeptutor`（group 8），scope 同上，同日到期。
- **不能跨 group**：用 id=3 去 `git ls-remote` `deeptutor/deeptutor.git` 会被 401；用 id=4 去 `digitalsupply/*` 同样被拒。
- **不能调 REST API**：scope 里没有 `api`，请求 `/api/v4/projects/10` 返回 `403 insufficient_scope`。
- 一个容易误解的点：Secret 里的 `username=ci-rw` 只是 token 名字，**不是身份**。实测把用户名换成任意字符串，只要密码是这个 group token，Git 仍然认证成功；GitLab 是用 token 反查 bot 的。deploy token 则相反，用户名必须精确匹配（见下）。
- 依据：`PersonalAccessToken.find_each`、`Group#members`、`git ls-remote` 交叉测试、`curl -H "PRIVATE-TOKEN: …" /api/v4/projects/10`。

#### Project access token

- 和 group token 同一套机制，只是 bot 只在一个项目里。它适合“一条流水线只碰一个仓库”的场景。
- 本环境 **没有使用**：有效 token 表里只有两个 group bot，没有项目 bot。四条流水线都是“源码仓 + GitOps 仓”两仓操作，项目 token 跨不过去，这是当初选 group token 的直接原因（`platform/secrets/cicd/README.md` 也这么写）。
- 依据：token 表只有 id 3/4 两个 bot；项目成员里没有项目级 bot。

#### Deploy token

- 没有用户身份，是项目级的“哑凭证”。用户名固定为 `gitlab+deploy-token-N`，密码只在创建时显示一次。
- 本环境有 6 个，全部叫 `argocd-ro`，scope 只有 `read_repository`，2027-11-12 到期，分别绑到 6 个 GitOps 仓库：
  - `deploy-token-1` → `digitalsupply/platform-gitops`
  - `deploy-token-2` → `digitalsupply/tekton-platform-gitops`
  - `deploy-token-3` → `digitalsupply/china-study-free-gitops`
  - `deploy-token-4` → `digitalsupply/compassio-gitops`
  - `deploy-token-5` → `digitalsupply/openwebui-gitops`
  - `deploy-token-6` → `deeptutor/deeptutor-gitops`
- **只能读自己那一个仓库**：用 `deploy-token-1` 读 `openwebui-gitops` 被拒；**不能推**：`git push --dry-run` 返回 `You are not allowed to upload code`（403）。
- **REST API 基本不可用**：`/api/v4/projects` 返回 `200 []`，`/api/v4/projects/10` 返回 404，仓库树端点也 404。它只适合 git-over-HTTP。
- 用户名必须精确：用任意用户名替换 `gitlab+deploy-token-1`，`git ls-remote` 直接失败。
- 依据：`DeployToken.find_each`、逐仓库 `git ls-remote`、`git push --dry-run`、API 测试。

#### CI job token

- 每个 CI job 自动注入 `CI_JOB_TOKEN`，生命周期 = 该 job，默认只能访问当前项目（以及显式白名单）。
- 本环境四条流水线 **都没有用它**：openwebui 的 `.gitlab-ci.yml` 只把 job 当作“触发器”，用 Pod 的 Kubernetes ServiceAccount token 去 POST PipelineRun；另外三条根本不经过 GitLab Runner。
- 因此这里不存在“CI job token 跨项目克隆”的配置，也不存在对应的泄露面。
- 依据：`Project.find(1).repository.blob_at("main", ".gitlab-ci.yml")` 全文；三个 webhook 项目的仓库里没有 `.gitlab-ci.yml`。

### 1.2 Harbor robot account 与 admin 的差别

| 维度 | robot account | admin |
|---|---|---|
| 身份 | 机器账号，非自然人 | Harbor 内置超级管理员 |
| 作用域 | 项目级或 system 级，可细分到 repository 与 pull/push/delete/scan 动作 | 全部项目、用户、robot、配置、复制、GC |
| 凭证展示 | secret 只在创建时返回一次 | 人可重置、可登录 UI |
| 典型用途 | CI 推镜像、集群拉镜像，按项目隔离 | 初始化、运维、应急 |
| 泄露后果 | 只影响被授权项目/动作 | 可推任意项目、删任意镜像、建用户/robot、改配置 |

本环境的实测结果很直接：

- `GET /api/v2.0/robots` 返回 `X-Total-Count: 0`、body `[]`；用同一个 admin 账号能正常列出 5 个项目，所以**不是权限不足，而是确实一个 robot 都没建**。
- 四个业务项目的 members 只有 `admin`（role=`projectAdmin`）。
- `cicd/harbor-auth`、`compassio/harbor-auth`、`china-study-free/harbor-auth`、`gitlab-runner/harbor-auth`、`open-webui/harbor-pull` 五份 dockerconfig 解出来的 `user:pass` 哈希完全一致；GitLab 主机 `/root/.docker/config.json` 里的 Harbor 条目也是同一份。
- 结论：**Harbor 的自动化身份就是 admin 本人**，没有最小权限。`deeptutor` 项目是 public，所以它的 Deployment 看起来“不需要凭据”，但构建推送仍然用 admin。
- 依据：`curl -sk -u "$HARBOR_USER:$HARBOR_PASS" https://192.168.67.202:8443/api/v2.0/robots`、`/projects/{name}/members`、逐份 dockerconfig 哈希比对、`ssh root@192.168.67.201 'cat /root/.docker/config.json'`（只计算哈希，不落值）。

### 1.3 Kubernetes Secret 与 SealedSecret 的关系

```
明文 Secret（工作负载真正消费的东西）
   ▲ 创建/更新，ownerReference 指回
SealedSecret CRD（Git 里的密文；spec.encryptedData + spec.template）
   ▲ 用控制器的公钥加密，绑定 namespace/name
sealed-secrets-controller（kube-system，持有私钥）
```

- **Secret 是运行时的载体**：Pod 通过 `secretKeyRef`、volume、`imagePullSecrets` 消费它；RBAC 控制谁能读。
- **SealedSecret 只是“可入库的密文信封”**：它不是 Secret 的替代品，控制器解密后才生成同名 Secret，并设置 `ownerReferences`。所以 Git 里只能看到密文，集群里仍然有明文 Secret。
- **加密边界是“集群 + 控制器私钥”**：任何能读 `kube-system` 里私钥 Secret 的人都能解出全部 SealedSecret；它不是 KMS，不提供“使用时才解密”的隔离。
- 本环境：
  - 控制器 `sealed-secrets-controller` 0.41.2，私钥 Secret `kube-system/sealed-secrets-keybh4kb`（2026-11-08 创建，`kubernetes.io/tls`，含 `tls.crt`/`tls.key`）。
  - `cicd` 的 7 个 Secret 全部有 `ownerReferences → SealedSecret`，且都没有 `kubectl.kubernetes.io/last-applied-configuration` 注解。
  - 密文来源：6 个 GitLab 相关在 `platform-gitops.git` 的 `platform/secrets/cicd/sealed/`（ArgoCD 应用 `platform-cicd-secrets`，directory recurse）；`harbor-auth` 在 `platform/cicd/buildkitd/sealed/`（应用 `platform-buildkitd`）。
  - 控制器 ClusterRole 对 `secrets` 有 `get/list/create/update/delete/watch`（全集群），这是它能“落地 Secret”的必要条件，也是它成为高价值目标的原因。
- 依据：`kubectl -n cicd get secret -o json`（ownerReferences/annotations）、`kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key`、`kubectl get clusterrole secrets-unsealer -o json`、`kubectl -n argocd get application platform-cicd-secrets -o json`。

历史坑（为什么现在要 SealedSecret）：迁移前这些 Secret 是 `kubectl apply` 手工建的，`last-applied-configuration` 注解里保留着完整的 GitLab token 原文；迁移时先删 Secret 再让 ArgoCD 用密文重建，才没有把明文继续写回集群。当前 `china-study-free/harbor-auth` 仍带这个注解，属于**未清干净的残留**（见 §6 R8）。

### 1.4 ArgoCD repository secret 的特殊之处

它和普通 Secret 的差别不在类型，而在“ArgoCD 用一套约定去发现它”：

- 必须放在 ArgoCD 所在 namespace（本环境 `argocd`）。
- 必须带 label `argocd.argoproj.io/secret-type=repository`；ArgoCD 只扫描这类 Secret。
- 数据键是约定好的：`type`（git/helm）、`url`、`username`、`password`、可选 `insecure`、`sshPrivateKey` 等。ArgoCD 以 `url` 作为匹配键：Application 的 `repoURL` 必须与某条 Secret 的 `url` 对上，才拿得到凭据。
- 它不是 `imagePullSecrets`，不参与 kubelet 拉镜像；它是 ArgoCD 自己拉 Git/Helm 仓时用的。
- **凭据是 base64 明文**（K8s Secret 的常规编码），不是加密；ArgoCD 的 server/repo-server 必须能读到它。
- 它通常**不由 ArgoCD 自己管理**（避免“用仓库里的清单改仓库凭据”的循环），本环境全部是人工 `kubectl` 创建，没有 ownerReferences，也不在 Git 里。

本环境 7 条：

| Secret | URL | 身份 | 额外键 | 创建时间 |
|---|---|---|---|---|
| `platform-gitops-repo` | `digitalsupply/platform-gitops.git` | deploy-token-1 | — | 2026-11-08 |
| `tekton-platform-repo` | `digitalsupply/tekton-platform-gitops.git` | deploy-token-2 | — | 2026-11-07 |
| `china-study-free-repo-secret` | `digitalsupply/china-study-free-gitops.git` | deploy-token-3 | `insecure=true` | 2026-11-05 |
| `gitlab-compassio-gitops` | `digitalsupply/compassio-gitops.git` | deploy-token-4 | — | 2026-10-14 |
| `gitlab-openwebui-gitops` | `digitalsupply/openwebui-gitops.git` | deploy-token-5 | — | 2026-10-13 |
| `deeptutor-repo-secret` | `deeptutor/deeptutor-gitops.git` | deploy-token-6 | `insecure=true` | 2026-10-27 |
| `prometheus-community-helm` | `https://prometheus-community.github.io/helm-charts` | 无（公开 Helm） | `name` | 2026-11-09 |

注意：六个 Git 仓库地址都是 **HTTP**（不是 HTTPS）；`insecure` 只出现在其中两条，说明 ArgoCD 对 HTTP 的容忍并不完全一致，迁移到 HTTPS 时要逐条验证。

另一个特殊点：这些 Secret 的读取者是 ArgoCD 的组件，而 `argocd-application-controller` 的 ClusterRole 是 `apiGroups=["*"] resources=["*"] verbs=["*"]`。也就是说，**能改 ArgoCD 的 repo secret 或 repo 内容的人，距离“改整个集群”只有一次 sync**。

依据：`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository -o json`、`kubectl get clusterrole argocd-application-controller -o json`。

### 1.5 webhook secret token 与 API token 的本质区别

| 维度 | webhook secret token | API token（PAT/group/project/deploy） |
|---|---|---|
| 代表谁 | 不代表任何身份 | 代表一个用户或 bot |
| 作用 | 证明“请求方知道这个共享字符串” | 认证 + 授权，能调 API/读写仓库 |
| 作用域 | 只对该 webhook 入口有意义 | GitLab 全局/group/项目，按 scope |
| 能否反查权限 | 不能 | 能 |
| 轮换影响 | 只影响 webhook 投递 | 影响所有消费者 |
| 本环境存放 | `*-webhook-secret` 的 `secretToken` | `*-gitlab-auth` 的 `password`/`token` |

本环境的 webhook token 是 GitLab 项目设置里的 “Secret token”，GitLab 发送时放在 `X-Gitlab-Token` 头；Tekton 的 `gitlab` interceptor 把它与 Secret 里的 `secretToken` 做**明文字符串比较**（不是 HMAC 签名）。它只能防“不知道 token 的人伪造 push”，不能防“知道 token 的人伪造任意 payload”。

实测：

- 用错误 token 向 deeptutor listener POST 一个 `ref=refs/heads/main` 的合成 body：EventListener 返回 HTTP 202（202 只表示“收下了”，不代表校验通过），但 `PipelineRun` 数量保持 0。
- 用正确 token 发同样的 body：创建一个 `deeptutor-cicd-*` PipelineRun（因仓库 URL 是伪造的，clone 会失败）；随后删除该测试 run。
- 三个项目的 hook token 与三个 K8s Secret 的 `secretToken` 做 SHA-256 比对，**全部一致**。

依据：`kubectl -n cicd get eventlistener -o json`、`kubectl -n cicd get secret *-webhook-secret`、`curl -X POST -H "X-Gitlab-Token: …" http://10.0.0.252/`、`kubectl -n cicd logs el-deeptutor-listener`、GitLab `WebHookLog`。

### 1.6 前缀与字段速查

| 看到什么 | 是什么 |
|---|---|
| `glpat-…` | GitLab personal/group/project access token 的密码值 |
| `glrt-…` | GitLab Runner authentication token |
| `gitlab+deploy-token-N` | deploy token 的固定用户名 |
| `X-Gitlab-Token` | GitLab webhook 的 secret token 头 |
| `kubernetes.io/dockerconfigjson` | 容器 registry 凭据，键固定为 `.dockerconfigjson` |
| `argocd.argoproj.io/secret-type=repository` | ArgoCD 仓库凭据标记 |
| `bitnami.com/v1alpha1 SealedSecret` | 可入库的加密 Secret 信封 |

---

## 2. 拓扑与可达性

### 2.1 组件与网段

| 组件 | 地址 | 说明 | 依据 |
|---|---|---|---|
| GitLab CE 19.5.0 | `192.168.67.201`（主机 `ubuntu01`，Omnibus） | 2 个 group、11 个项目；`/etc/hosts` 有 `10.0.0.252 el-deeptutor.internal` | `ssh … hostname -I`、`grep /etc/hosts` |
| Harbor | `192.168.67.202:8443` | 自签 CA，CN=`192.168.67.202`，有效期到 2036；`auth_mode=oidc_auth`，但 admin 本地口令仍可用 | `GET /api/v2.0/systeminfo`、`openssl s_client` |
| Kubernetes 节点 | `10.0.0.61`、`10.0.0.120`–`10.0.0.124` | 6 节点，Pod 网段 `10.244.0.0/16`，Service 观测在 `10.97`–`10.111` | `kubectl get nodes -o wide`、`ip route` |
| Traefik | `10.0.0.252:80/443` | MetalLB pool `lb-pool-tailscale`（`10.0.0.252-253`）；entrypoint `web`=80、`websecure`=443 | `kubectl -n traefik get svc`、`ipaddresspool` |
| Tekton EventListener | `el-*.cicd.svc:8080` | 三个 listener，ClusterIP，无 NetworkPolicy | `kubectl -n cicd get svc,networkpolicy` |
| buildkitd | `buildkitd.cicd.svc:1234` | 无 TLS、无认证的 gRPC 入口 | `kubectl -n cicd get svc buildkitd` |
| ArgoCD | `argocd` ns，`argocd-server` 为 ClusterIP | 没有 Ingress，UI 只能 port-forward 或集群内访问 | `kubectl -n argocd get svc,ingress` |
| GitLab Runner | `gitlab-runner` ns | 只注册在 `digitalsupply/openwebui`，Kubernetes executor | `Ci::Runner.find_each`、`runners.toml` |

### 2.2 谁访问谁

```
开发者 --git push(HTTPS/SSH)--> GitLab 192.168.67.201
GitLab --webhook HTTP + X-Gitlab-Token--> Traefik 10.0.0.252:80
Traefik --Host/Path--> EventListener svc:8080
EventListener --SA token--> kube-apiserver（创建 PipelineRun）
Tekton Pod --group token--> GitLab（clone 源码、push GitOps）
Tekton Pod --harbor-auth(admin)--> buildkitd:1234 / Harbor:8443
ArgoCD repo-server --deploy token--> GitLab（只读 GitOps）
ArgoCD controller --SA(cluster-admin)--> kube-apiserver（apply）
kubelet --imagePullSecrets--> Harbor:8443
GitLab Runner --runner token--> GitLab（领取 openwebui job）
Runner job Pod --SA token--> kube-apiserver（创建 PipelineRun）
sealed-secrets --私钥--> kube-apiserver（解密 SealedSecret）
```

### 2.3 实测连通性矩阵

| 源 → 目标 | 方法 | 结果 | 解读 |
|---|---|---|---|
| 本机（10.0.0.61）→ GitLab:80 | `curl /users/sign_in` | 200 | 通 |
| 本机 → Harbor:8443 | `curl -k /api/v2.0/health` | 200 | 通 |
| Pod（cicd）→ GitLab:80 | `wget`（临时 Pod） | 200 | 集群到 GitLab 通 |
| Pod → Harbor:8443 | `wget --no-check-certificate` | 200 | 集群到 Harbor 通 |
| Pod → `10.0.0.252:80` | `wget` | 404 | **通**（404 是 Traefik 无匹配路由，不是网络失败） |
| Pod → `el-deeptutor.internal` | `nslookup` | NXDOMAIN | 集群 DNS 不解析该名字；它只存在于 GitLab 的 `/etc/hosts` |
| GitLab → Harbor:8443 | `curl -k /api/v2.0/health` | 200 | 通 |
| GitLab → `10.0.0.252` | `curl /` | 404 | 通 |
| GitLab → `el-deeptutor.internal` | `curl /` | 400 | 通（400 是 EventListener 对 GET 的响应） |
| GitLab → 中国项目 webhook | `WebHookLog` | 202 | 通，最近 2026-11-06，23 次 |
| GitLab → deeptutor webhook | `WebHookLog` | 202 | 通，最近 2026-11-08，13 次 |
| GitLab → compassio webhook | `WebHookLog` | 无记录 | 配置存在，但当前表里 **0 条投递记录**；无法证明端到端成功 |
| `gitlab-auth` → `platform-gitops` push | `git push --dry-run` | 非 fast-forward 拒绝 | **鉴权通过**，只是本地历史落后；说明有推权限 |
| `gitlab-auth` → `deeptutor/*` | `git ls-remote` | 401 | 跨 group 被拒 |
| deploy token → 自己的仓库 | `git ls-remote` | OK | 只读有效 |
| deploy token → 别的 GitOps 仓库 | `git ls-remote` | 401 | 项目级隔离有效 |
| deploy token → push | `git push --dry-run` | 403 | 只读，不能推 |
| 无 imagePullSecrets 的 Pod → 私有 Harbor 镜像 | `kubectl run` | `no basic auth credentials` | **节点没有全局 Harbor 凭据**，私有镜像必须显式 imagePullSecret |

网络结论：

- GitLab 主机有一条 `10.0.0.0/24 via 192.168.67.156` 的静态路由（`ssh … ip route`），所以 **webhook 推模型现在是通的**。
- `.gitlab-ci.yml` 里“GitLab cannot reach the cluster”的注释是 2026-10-13 设计时的历史事实，不是当前事实；openwebui 仍保留 Runner 拉模型，属于“没迁移”，不是“不能迁移”。
- 集群内没有 NetworkPolicy，EventListener 的 8080 和 buildkitd 的 1234 对所有 Pod 开放；Traefik 的 webhook 入口走 **HTTP 80**，没有 TLS、没有 IP allowlist。
- Harbor 使用自签证书，因此 Task 里要么挂 `harbor-ca` 合并信任库（buildkit 系列），要么直接用 `--insecure --skip-tls-verify`（kaniko）。

---

## 3. 凭据清单（实测）

### 3.1 GitLab 侧

#### 用户

| id | 用户名 | 类型 | 状态 |
|---|---|---|---|
| 1 | `root` | 真人管理员 | active |
| 2 | `GitLabDuo` | 内置 | active |
| 3 | `group_2_bot_35e9209087a1fe4fbd59b1682cceb642` | group 2 bot | active |
| 4 | `group_8_bot_d1d3ff08189686931e3bae8fa3ed52a7` | group 8 bot | active |

依据：`User.find_each { |u| ... }`。

#### Token

| id | 名称 | 类型 | 归属 | 角色 | scope | 创建 | 到期 | 状态 | 消费者 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `cicd-agent` | PAT | root | 实例管理员 | `api` | 2026-10-13 | 2027-10-13 | **revoked** | 历史 `gitlab-auth` |
| 2 | `deeptutor-gitops` | PAT | root | 实例管理员 | `api` + repo 读写 | 2026-10-27 | 2027-04-25 | **revoked** | 历史 deeptutor |
| 3 | `ci-rw` | Group AT | `digitalsupply` bot | Maintainer(40) | `read_repository`,`write_repository` | 2026-11-12 12:14 | 2027-11-12 | active | `gitlab-auth`、`china-study-free-gitlab-auth` |
| 4 | `ci-rw` | Group AT | `deeptutor` bot | Maintainer(40) | 同上 | 2026-11-12 12:14 | 2027-11-12 | active | `deeptutor-gitlab-auth` |

关键点：

- id=3 一个 token 覆盖 `digitalsupply` 下 9 个项目（含 `platform-gitops`、三个业务 GitOps 仓、`k8s-platform-tutorials`）。
- id=4 只覆盖 `deeptutor` 下 2 个项目。
- 两个 token 都没有 `api` scope，所以调不了项目设置/用户 API；但 **`write_repository` + Maintainer 足以改 `main` 的内容**（protected branch 的 push access level 就是 40）。
- 依据：`PersonalAccessToken.find_each`、`Group#members`、`protected_branches`、`git ls-remote`/`git push --dry-run`。

#### Deploy token

见 §1.1 的六个；全部 `read_repository`、2027-11-12 到期、单项目。消费者是 ArgoCD 的 6 条 repository secret。

#### Runner

| 项 | 值 |
|---|---|
| id | 3 |
| 描述 | `openwebui-k8s-runner` |
| 类型 | project_type |
| 绑定项目 | 仅 `digitalsupply/openwebui` |
| 创建 | 2026-10-13 08:36 |
| 最近联系 | 2026-11-12 13:14（存活） |
| token 存放 | `gitlab-runner/gitlab-runner-config` 的 `runners.toml`，owner 为 SealedSecret |
| executor | Kubernetes，namespace `gitlab-runner`，`image_pull_secrets=["harbor-auth"]` |

依据：`Ci::Runner.find_each`、`kubectl -n gitlab-runner get secret gitlab-runner-config -o json`、`runners.toml`（已脱敏）。

#### Webhook

| 项目 | URL | 事件 | token 存放 | 投递记录 |
|---|---|---|---|---|
| `digitalsupply/compassio` | `http://el-deeptutor.internal/compassio-el` | push only | `cicd/gitlab-webhook-secret` / `secretToken` | **0 条** |
| `deeptutor/deeptutor` | `http://el-deeptutor.internal` | push only | `cicd/deeptutor-webhook-secret` / `secretToken` | 13 条，最近 202 |
| `digitalsupply/ChinaStudyFree` | `http://10.0.0.252/china-study-free-hook` | push only | `cicd/china-study-free-webhook-secret` / `secretToken` | 23 条，最近 202 |
| `digitalsupply/openwebui` | 无 | — | — | 走 Runner，不走 webhook |

三个 hook 的共同配置：`push_events=true`，merge/tag/note/issue/pipeline 事件全 false，`enable_ssl_verification=false`，无分支过滤（分支过滤在 Tekton CEL 里）。三个 hook token 与三个 Secret 的 `secretToken` SHA-256 一致。

compassio 的 0 条投递是一个**明确的证据缺口**：hook 存在、URL 路径可达（GET 返回 400 说明 listener 在），但当前 `WebHookLog` 里没有任何一次投递记录（历史日志也可能被清理）；不能声称它端到端跑通过。

#### GitLab 主机上的“旁路凭据”

| 文件 | 内容类型 | 风险 |
|---|---|---|
| `/etc/gitlab/initial_root_password` | root 初始密码（745 字节，2026-10-12） | 若未改密，等于 GitLab 管理员 |
| `/root/.kube/config` | 含 client certificate/key 的 kubeconfig | 直接集群身份 |
| `/root/.kube/deeptutor-config` | 另一份 kubeconfig | 同上 |
| `/root/.docker/config.json` | Harbor admin + 阿里云 registry 凭据 | Harbor 管理员 |
| `/root/cicd-credentials-architecture.md` | 人工整理的全景笔记 | 不含明文，但泄露架构 |

这些不在 K8s Secret 里，无法用 K8s RBAC 管；它们的保护完全依赖 GitLab 主机的 SSH/登录安全。

依据：`ssh root@192.168.67.201 'ls -l /etc/gitlab/initial_root_password; ls -l /root/.kube; ls -l /root/.docker'`（只列文件，不读值）。

### 3.2 Harbor 侧

| 项目 | id | 公开 | 仓库数 | 创建 | owner |
|---|---|---|---|---|---|
| `library` | 1 | 是 | 2 | 2026-10-13 | admin |
| `openwebui` | 6 | 否 | 11 | 2026-10-13 | admin |
| `compassio` | 7 | 否 | 7 | 2026-10-13 | admin |
| `deeptutor` | 8 | **是** | 6 | 2026-10-27 | admin |
| `china-study-free` | 9 | 否 | 2 | 2026-11-05 | admin |

- robot：**0**（`X-Total-Count: 0`）。
- 项目成员：四个业务项目都只有 `admin` / `projectAdmin`。
- 用户 API：`X-Total-Count: 1`，仅 `root`；admin 是内置管理员，不出现在该列表里（未进一步验证其用户记录）。
- 审计日志：`X-Total-Count: 0`，没有可用的推送/删除审计。
- 项目 webhook：四个项目均为 `[]`，Harbor 不向外发事件。

公开性实测：

- `deeptutor/deeptutor` 的匿名 token + manifest 请求返回 200；
- `openwebui/open-webui`、`compassio/backend`、`china-study-free/web` 的匿名 manifest 返回 401；
- `_catalog` 匿名 401。
- 结论：只有 deeptutor 是匿名可拉，其余私有；私有项目的匿名 token 端点虽然会发 token，但拿 token 取 manifest 仍 401（权限判定正确）。

依据：`GET /api/v2.0/projects`、`/projects/{name}/robots`（404，2.14 已改为系统级 `/robots`）、`/projects/{name}/members`、`/audit-logs`、匿名 `/service/token` + manifest。

### 3.3 `cicd` namespace 的 Secret

| Secret | 类型 | keys | 用途 | owner |
|---|---|---|---|---|
| `gitlab-auth` | Opaque | `git-url`, `gitops-url`, `username`, `password`, `token` | openwebui / compassio / china-study-free 的 clone 与 GitOps 写回 | SealedSecret |
| `china-study-free-gitlab-auth` | Opaque | `username`, `password`, `token` | china-study-free 的 check/update | SealedSecret |
| `deeptutor-gitlab-auth` | Opaque | `username`, `password`, `token` | deeptutor 的 clone/check/update | SealedSecret |
| `gitlab-webhook-secret` | Opaque | `secretToken` | compassio EventListener 校验 | SealedSecret |
| `deeptutor-webhook-secret` | Opaque | `secretToken` | deeptutor EventListener 校验 | SealedSecret |
| `china-study-free-webhook-secret` | Opaque | `secretToken` | china-study-free EventListener 校验 | SealedSecret |
| `harbor-auth` | `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | Harbor admin 的 pull/push 凭据 | SealedSecret |

几个细节：

- `gitlab-auth.token` 与 `gitlab-auth.password` **同值**；Task 只读 `password`，`token` 是早期兼容键。
- `gitlab-auth.git-url` **没有消费者**（所有 Task 的源码 URL 来自 Pipeline 参数）；`gitops-url` 只被 `update-gitops-tag` 读取。
- `china-study-free-gitlab-auth` 的 `token` 与 `gitlab-auth` **完全相同**；两个名字不是两套权限。
- `harbor-auth` 的 `.dockerconfigjson` 解出来是 `admin`，与另外四个 namespace 的 Harbor 凭据同值。
- 全部 7 个 Secret 创建于 2026-11-12 12:22–12:25（`harbor-auth` 为 08:28 重建），都由 SealedSecret 控制器落地，没有 `last-applied` 注解。
- 同 namespace 还有 `harbor-ca`、`buildkitd-config`、`buildkitd-ca`、`cicd-cleanup-script` 四个 ConfigMap，以及 PVC `frpc-build-ctx`（2Gi）。

依据：`kubectl -n cicd get secret -o json`、`kubectl -n cicd get task -o json`（逐 Task 的 `secretKeyRef`）。

#### 谁能读这些 Secret

| 主体 | 权限 | 范围 | 依据 |
|---|---|---|---|
| `cicd/pipeline` SA | `ClusterRole/edit`（ClusterRoleBinding `pipeline-edit-binding`） | **全集群** Secret 读写、Pod 创建 | `kubectl auth can-i get secrets --as=… -n kube-system` → yes |
| `gitlab-runner/default`、`gitlab-runner/gitlab-runner` SA | Role `openwebui-runner-role` | `cicd` 内 secrets get/list/watch + pipelineruns 增删改查 | `kubectl auth can-i get secrets --as=… -n cicd` → yes |
| `argocd/argocd-application-controller` SA | ClusterRole `*/*/*` | 全集群 | `kubectl get clusterrole argocd-application-controller` |
| `kube-system/sealed-secrets-controller` SA | ClusterRole `secrets-unsealer` | 全集群 Secret CRUD | `kubectl get clusterrole secrets-unsealer` |
| 人类 kubeconfig | 取决于证书/绑定 | GitLab 主机上的 `/root/.kube/config` 含 client cert | 文件存在性 |

这意味着：**任一 Tekton Task Pod（用 `pipeline` SA）都能用该 SA token 调 kube-apiserver 读全集群 Secret，包括 sealed-secrets 的私钥和所有业务库密码**（Pod 里没有 `kubectl` 也能用 `curl` + token 做到）。这不是“可能”，`kubectl auth can-i` 已明确返回 yes。

### 3.4 业务 namespace 的 Harbor 凭据

| namespace | Secret | 类型 | owner | 使用者 |
|---|---|---|---|---|
| `cicd` | `harbor-auth` | dockerconfigjson | SealedSecret | 构建 Task、TriggerTemplate 的 imagePullSecrets |
| `compassio` | `harbor-auth` | dockerconfigjson | **无（kubectl 手工）** | `compassio-backend/frontend` 的 imagePullSecrets |
| `china-study-free` | `harbor-auth` | dockerconfigjson | **无（kubectl 手工）**，并带 `last-applied-configuration` | `china-study-free` Deployment |
| `gitlab-runner` | `harbor-auth` | dockerconfigjson | SealedSecret | runner 的 helper/job 镜像拉取 |
| `open-webui` | `harbor-pull` | dockerconfigjson | SealedSecret | SA `open-webui`、`frpc` 的 imagePullSecrets |
| `deeptutor` | 无 | — | — | 项目 public，匿名拉取 |

补充实测：

- `compassio` 的 Pod 显式带 `imagePullSecrets: [harbor-auth]`；`china-study-free` 的 Pod 同样；`open-webui` 的 Deployment 本身不写，但 SA `open-webui` 带 `harbor-pull`，Pod 会继承。
- `deeptutor` 的 Deployment 没有 pull secret，Harbor 项目 public，所以能拉。
- 在一个没有 pull secret 的临时 Pod 里拉 `openwebui/alpine:3.20`，报 `no basic auth credentials`；说明**节点层没有全局 Harbor 凭据**，私有镜像必须显式 secret。
- `gitlab-runner` 的 manager Pod 没有 imagePullSecrets，但镜像 `IfNotPresent` 且已在节点缓存；一旦调度到没有缓存的节点，存在拉取失败风险（未实际触发，标记为隐患）。

依据：`kubectl -n <ns> get secret,deploy,sa -o json`、临时 Pod `audit-pull` 的 `ErrImagePull` 事件。

### 3.5 ArgoCD 的 repository secret

见 §1.4 表。补充：

- 全部 7 条都是人工创建，`ownerReferences` 为空，Git 仓库里搜不到 `secret-type: repository` 清单。
- `argocd-initial-admin-secret` 仍存在（创建于 2026-01-17），未被删除。
- ArgoCD 没有 Ingress；`argocd-server` 是 ClusterIP，UI 暴露面为零（除非 port-forward）。
- `argocd-server` 的 Role 对 `argocd` namespace 的 secrets 有全部动词；`argocd-application-controller` 则是全集群通配。

依据：`kubectl -n argocd get secret -l …`、`kubectl -n argocd get role argocd-server -o json`、`kubectl -n argocd get svc,ingress`。

### 3.6 SealedSecret 清单（与本文相关的）

| namespace | SealedSecret | 用途 | 状态 |
|---|---|---|---|
| `cicd` | `gitlab-auth`、`china-study-free-gitlab-auth`、`deeptutor-gitlab-auth` | Git 凭据 | Synced |
| `cicd` | `gitlab-webhook-secret`、`deeptutor-webhook-secret`、`china-study-free-webhook-secret` | webhook 校验 | Synced |
| `cicd` | `harbor-auth` | Harbor admin | Synced |
| `gitlab-runner` | `gitlab-runner-config` | `runners.toml` | Synced |
| `gitlab-runner` | `harbor-auth` | runner 镜像拉取 | Synced |
| `open-webui` | `harbor-pull` | 业务镜像拉取 | Synced |
| `argocd` | `argocd-oauth` | ArgoCD OIDC | Synced |

注意 `compassio/harbor-auth`、`china-study-free/harbor-auth` 不在上表：它们是明文 Secret，不在 GitOps 里；`china-study-free` 的那份还带 `last-applied-configuration`。

### 3.7 谁创建了这些对象

| 对象 | 创建者/来源 | 证据 |
|---|---|---|
| 两个有效 group token（id 3/4） | root 于 2026-11-12 12:14 创建；bot 用户由 GitLab 自动生成 | `PersonalAccessToken.created_at`、`User.id=3/4` |
| 两个已吊销 root PAT（id 1/2） | root 于 2026-10-13 / 2026-10-27 创建，11-12 收敛时吊销 | `PersonalAccessToken.revoked` |
| 6 个 deploy token | root 于 2026-11-12 12:14 创建，`argocd-ro` | `DeployToken.created_at` |
| 3 个 webhook | 项目初始化时由 root/维护者在 GitLab 项目设置里添加；GitLab 不记录“操作人” | `web_hooks.created_at`（10-13/10-27/11-05）；操作人**未验证** |
| Runner id=3 | 管理员于 2026-10-13 注册，仅绑 openwebui | `Ci::Runner.created_at` |
| `cicd` 的 6 个 GitLab Secret 密文 | hao 提交到 `platform/secrets/cicd/sealed/`（commit `42e10d2`） | `git log -- platform/secrets/cicd` |
| `cicd/harbor-auth` 密文 | hao 提交到 `platform/cicd/buildkitd/sealed/`（commit `63e4455`） | `git log -- platform/cicd/buildkitd` |
| `cicd` 7 个明文 Secret | sealed-secrets 控制器从 SealedSecret 解密生成 | `ownerReferences` + `managedFields` |
| `compassio/harbor-auth`、`china-study-free/harbor-auth` | 人工 `kubectl` 创建（10-14 / 11-05），无 owner、无 Git 来源 | `creationTimestamp`、`ownerReferences=[]` |
| ArgoCD 7 条 repository secret | 人工 `kubectl` 创建（10-13 至 11-09），不在 Git | `creationTimestamp`、Git 仓库中搜不到 `secret-type: repository` |
| Tekton Task/Pipeline/EL/Binding/Template | ArgoCD 应用 `platform-cicd` 同步（Git 提交 `e6c915e` 等） | `argocd.argoproj.io/tracking-id: platform-cicd:…` |
| `argocd-initial-admin-secret` | ArgoCD Helm chart 安装时生成（2026-01-17） | `creationTimestamp` |
| Harbor 5 个项目 | Harbor admin（owner_id=1）在 10-13 至 11-05 创建 | `/api/v2.0/projects` 的 `owner_name/creation_time` |

---

## 4. 四条流水线逐条拆解

### 4.1 openwebui：Runner 拉模型（没有 webhook）

**触发路径**

```
git push main
  → GitLab 项目 digitalsupply/openwebui
  → project runner id=3（集群内，轮询 GitLab）
  → 执行 .gitlab-ci.yml 的 trigger-tekton job
  → 用 Pod 的 ServiceAccount token POST PipelineRun 到 kube-apiserver
  → Tekton 跑 open-webui-cicd
```

- Runner 只绑 `digitalsupply/openwebui`；job 镜像 `192.168.67.202:8443/openwebui/gitlab-runner:alpine-v17.8.3`，tag `cicd`。
- `.gitlab-ci.yml` 明确写了“runner 在集群内、GitLab 到 10.0.0.0/24 当时不通”，这是历史设计原因；现在 GitLab 已能到 `10.0.0.252`，但这条流水线没迁移。
- job 里 `TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)`，直接 `curl` K8s API，创建 `generateName=open-webui-ci-` 的 PipelineRun；权限来自 `openwebui-runner-binding`（把 `gitlab-runner` ns 的 `default`/`gitlab-runner` SA 绑到 `cicd` 的 Role）。
- 该 Role 除了 `pipelineruns` 增删改查，还给了 `secrets/configmaps/serviceaccounts/pvc` 的 **get/list/watch**。也就是说，一个 CI job 可以读走 `cicd` 的全部 7 个 Secret。

**Task 与钥匙**

| 顺序 | Task | 用哪个 Secret 的哪个 key | 访问谁 | 说明 |
|---|---|---|---|---|
| 1 | `git-clone` | `gitlab-auth` / `username`+`password`（默认参数） | `192.168.67.201/digitalsupply/openwebui.git` | env 注入，脚本拼 `http://user:pass@host/path` |
| 2 | `build-and-push`（kaniko） | `harbor-auth` / `.dockerconfigjson`（volume 成 `/kaniko/.docker/config.json`） | Harbor `openwebui/open-webui` | 参数含 `--insecure --skip-tls-verify --insecure-pull`、`--cache-repo=…/openwebui/cache`、`--build-arg USE_SLIM=true` |
| 3 | `update-gitops-tag` | `gitlab-auth` / `username`+`password`+`gitops-url` | `digitalsupply/openwebui-gitops.git` | `sed` 改 `overlays/prod/kustomization.yaml` 的 `newTag`，commit/push `main` |

- 镜像：`192.168.67.202:8443/openwebui/open-webui:<short SHA>`（当前部署 `a077c804`）。
- 没有 `check-changes`，所以每次 push 都会构建。
- 没有挂 `harbor-ca`，靠 kaniko 的 `--skip-tls-verify` 绕过自签证书。
- PipelineRun 的 `taskRunTemplate` 设置 `serviceAccountName=pipeline`、`imagePullSecrets=[harbor-auth]`、workspace 10Gi `nfs-sc`。

**部署侧**

- ArgoCD `open-webui` → `openwebui-gitops.git` `overlays/prod`，automated + selfHeal + prune。
- Deployment 当前 replicas=0（2026-10-27 为省资源暂停）；SA `open-webui` 带 `harbor-pull`，Pod 继承。
- 当前 GitOps `newTag=a077c804`，与 Harbor 制品和 Deployment 镜像一致。

**现状/证据**

- GitLab CI 共 10 条 pipeline；2026-10-13 可见的 7 条中 5 条成功、2 条取消；runner 最近联系 2026-11-12 13:14，仍存活。
- 项目最后一次 push 是 2026-10-13，所以之后没有 pipeline 属于“没有新提交”，不是触发坏了。
- 依据：`Project.find(1).ci_pipelines`、`.gitlab-ci.yml`、`Ci::Runner`、`kubectl -n cicd get pipeline open-webui-cicd -o json`、`kubectl -n open-webui get deploy,sa`。

### 4.2 compassio：标准 webhook 模型

**触发路径**

```
push main
  → GitLab hook (token=gitlab-webhook-secret)
  → http://el-deeptutor.internal/compassio-el
  → Traefik (Host=el-deeptutor.internal, Path=/compassio-el)
  → Service el-compassio-listener:8080
  → EventListener compassio-listener
      gitlab interceptor: secretRef=cicd/gitlab-webhook-secret/secretToken
      CEL: body.object_kind == 'push' && body.ref == 'refs/heads/main'
  → TriggerBinding compassio-binding:
      gitrevision=body.checkout_sha
      gitbefore=body.before
      gitrepositoryurl=body.repository.git_http_url
  → TriggerTemplate compassio-template
  → PipelineRun compassio-cicd
```

**Task 与钥匙**

| 顺序 | Task | Secret/key | 访问谁 | 产物 |
|---|---|---|---|---|
| 1 | `git-clone` | `gitlab-auth` / `username`+`password` | `digitalsupply/compassio.git` | workspace `source` |
| 2 | `compassio-check-changes` | `gitlab-auth` / `username`+`password` | 同一仓库（fetch before） | 结果 `need-build`，只对 `backend/* frontend/*` 变更构建 |
| 3 | `compassio-build-push`（backend） | `harbor-auth` / `.dockerconfigjson`；另挂 `harbor-ca` | buildkitd `:1234` → Harbor `compassio/backend` | `buildctl … push=true`，inline cache |
| 4 | `compassio-build-push`（frontend） | 同上 | Harbor `compassio/frontend` | 同上 |
| 5 | `compassio-update-gitops` | `gitlab-auth` / `username`+`password` | `digitalsupply/compassio-gitops.git` | `sed newTag`，commit/push `main` |

- 触发模板把 `image-tag` 设为 `checkout_sha`（40 位）；两个镜像同 tag。
- 构建阶段用 buildkit 而不是 kaniko：客户端镜像 `compassio/buildkit:v0.20.2-rootless`，`BUILDKIT_HOST=tcp://buildkitd.cicd.svc.cluster.local:1234`，脚本先把 `harbor-ca` 合并进系统 CA 再 push。
- PipelineRun 固定 `nodeSelector=worker03` 并容忍 control-plane taint；workspace 256Mi。
- 部署侧 ArgoCD `compassio` → `compassio-gitops.git` `overlays/prod`，两个 `newTag` 都是 `05f030ac…`；Pod 显式 `imagePullSecrets: [harbor-auth]`。

**现状/证据**

- GitLab `WebHookLog` 对该项目 **0 条**；hook 创建于 2026-10-13、最后修改 2026-10-30，当前没有投递记录。
- 因此“compassio webhook 端到端成功”**未验证**；只能确认 listener 路径可达（GET `/compassio-el` 返回 400）、token 配置存在且与 Secret 一致。
- 依据：`kubectl -n cicd get eventlistener compassio-listener -o json`、`kubectl -n cicd get pipeline compassio-cicd -o json`、`WebHookLog.where(project_id: 3).count`。

### 4.3 deeptutor：跨 group 的显式凭据

**触发路径**

```
push main
  → GitLab hook (token=deeptutor-webhook-secret)
  → http://el-deeptutor.internal/
  → Traefik (Host=el-deeptutor.internal, Path=/)
  → Service el-deeptutor-listener:8080
  → EventListener deeptutor-listener（结构同 compassio）
  → TriggerBinding deeptutor-binding: after / before / git_http_url
  → PipelineRun deeptutor-cicd
```

**Task 与钥匙**

| 顺序 | Task | Secret/key | 访问谁 | 产物 |
|---|---|---|---|---|
| 1 | `git-clone` | **`deeptutor-gitlab-auth`**（显式 `gitlab-secret-name`）/ `username`+`password` | `deeptutor/deeptutor.git` | workspace |
| 2 | `deeptutor-check-changes` | **`deeptutor-gitlab-auth`** / `username`+`password` | 同一仓库 | 结果门控 |
| 3 | `deeptutor-build-push` | `harbor-auth` / `.dockerconfigjson`；`harbor-ca` | buildkitd → Harbor `deeptutor/deeptutor` | target `production`；PyPI 清华、npm npmmirror、Debian 阿里云、Node/Python 基础镜像走 Harbor `deeptutor/*` |
| 4 | `deeptutor-update-gitops` | **`deeptutor-gitlab-auth`** / `username`+`password` | `deeptutor/deeptutor-gitops.git` | `sed newTag`，push `main` |

- 这是四条里唯一显式传 `gitlab-secret-name` 的；因为源码仓和 GitOps 仓都在 `deeptutor` group（group 8），`gitlab-auth`（group 2）跨不过去。
- 镜像 tag 是 40 位 `after`；部署侧 `newTag=870f2dbe…` 与 Harbor 制品一致。
- Harbor `deeptutor` 项目 public，Deployment 没有 imagePullSecret，Pod 匿名拉取。

**现状/证据**

- WebHookLog 13 条，最近 2026-11-08，状态 202；端到端链路的“GitLab → Traefik → EL”已被真实投递证明。
- 用错误 token 发合成请求不会生成 PipelineRun；正确 token 会生成（测试 run 已删除）。
- 依据：`kubectl -n cicd get pipeline deeptutor-cicd -o json`、`kubectl -n cicd get task deeptutor-* -o json`、`WebHookLog`。

### 4.4 china-study-free：直连 VIP + 同 group 的重复凭据

**触发路径**

```
push main
  → GitLab hook (token=china-study-free-webhook-secret)
  → http://10.0.0.252/china-study-free-hook   （没有 Host，直接打 Traefik VIP）
  → Ingress china-study-free-el（无 host 规则，path=/china-study-free-hook）
  → Service el-china-study-free-listener:8080
  → EventListener china-study-free-listener
  → TriggerBinding china-study-free-binding: after / before / git_http_url
  → PipelineRun china-study-free-cicd
```

**Task 与钥匙**

| 顺序 | Task | Secret/key | 访问谁 | 产物 |
|---|---|---|---|---|
| 1 | `git-clone` | `gitlab-auth`（默认）/ `username`+`password` | `digitalsupply/ChinaStudyFree.git` | workspace |
| 2 | `china-study-free-check-changes` | `china-study-free-gitlab-auth` / `username`+`password` | 同一仓库 | 结果门控（docs 模式） |
| 3 | `china-study-free-build-push` | `harbor-auth` / `.dockerconfigjson`；`harbor-ca` | buildkitd → Harbor `china-study-free/web` | target `runtime`；Node 基础镜像 `deeptutor/node:22-slim` |
| 4 | `china-study-free-update-gitops` | `china-study-free-gitlab-auth` / `username`+`password`；`gitops-url` 来自 Pipeline 参数 | `digitalsupply/china-study-free-gitops.git` | `sed newTag`，push `main` |

- clone 用 `gitlab-auth`，check/update 用 `china-study-free-gitlab-auth`，但两者 **是同一个 token**；所谓“china 专属凭据”只是名字，隔离为零。
- 部署侧 `newTag=694f79f`（7 位短 SHA），与 Harbor 制品一致；而 TriggerTemplate 默认写的是 `after`（40 位）。这说明当前这个 tag 不是最近一次按模板触发的产物（可能是手工/旧版本流水线），**具体来源未验证**。
- 部署 Pod 显式 `imagePullSecrets: [harbor-auth]`。

**现状/证据**

- WebHookLog 23 条，最近 2026-11-06，状态 202；`http://10.0.0.252/...` 路径被真实投递证明。
- 依据：`kubectl -n cicd get ingress china-study-free-el -o json`、`kubectl -n cicd get pipeline china-study-free-cicd -o json`、`WebHookLog`、Harbor artifacts。

### 4.5 四条线对比

| 维度 | openwebui | compassio | deeptutor | china-study-free |
|---|---|---|---|---|
| 触发 | GitLab Runner 拉 | webhook 推 | webhook 推 | webhook 推 |
| GitLab hook | 无 | 有，0 投递 | 有，13 投递 | 有，23 投递 |
| clone 凭据 | `gitlab-auth`（group 2） | `gitlab-auth`（group 2） | `deeptutor-gitlab-auth`（group 8） | `gitlab-auth`（group 2） |
| GitOps 写回凭据 | `gitlab-auth` | `gitlab-auth` | `deeptutor-gitlab-auth` | `china-study-free-gitlab-auth`（同 group 2） |
| 构建器 | kaniko | buildkitd | buildkitd | buildkitd |
| Harbor 项目 | `openwebui` | `compassio` | `deeptutor`（public） | `china-study-free` |
| 镜像 tag | 短 SHA `a077c804` | 全 SHA `05f030ac…` | 全 SHA `870f2dbe…` | 短 SHA `694f79f` |
| 拉取凭据 | SA `harbor-pull` | `harbor-auth` | 无（public） | `harbor-auth` |
| check-changes | 无 | 有 | 有 | 有 |
| 当前部署 | replicas=0（暂停） | 2 个 Deployment | 1 个 Deployment | 1 个 Deployment |

### 4.6 当初为什么这么设计

以下区分“有直接证据”和“合理推断”：

| 设计 | 原因 | 证据/性质 |
|---|---|---|
| openwebui 用 Runner 拉、其余用 webhook 推 | 2026-10-13 设计时 GitLab 到 `10.0.0.0/24` 没有路由，只能让集群内 Runner 主动轮询；后来路由补上了，但这条线没迁移 | `.gitlab-ci.yml` 注释 + GitLab 主机现有 `10.0.0.0/24 via 192.168.67.156`（直接证据） |
| CI 用 group token 而非 project token | 一条流水线要读源码仓、写另一个 GitOps 仓，两个项目同 group；project token 跨不过去 | `platform/secrets/cicd/README.md` + token 归属（直接证据） |
| ArgoCD 每仓一个 deploy token | ArgoCD 只需要读 GitOps 仓，deploy token 单项目、只读、无 API，边界最小 | 6 个 `argocd-ro` 的 scope/绑定（直接证据） |
| webhook 用 Secret token | GitLab 原生支持，不需要给 GitLab 一个“能调 API 的身份”，只需要证明请求来自 GitLab | hook 配置 + interceptor `secretRef`（直接证据） |
| 密文入库用 SealedSecret | 之前 `kubectl apply` 的明文 Secret 在 `last-applied-configuration` 里泄露了 token；SealedSecret 让 Git 里只有密文 | README 的迁移记录 + 当前 ownerRefs（直接证据） |
| Harbor 全线用 admin | 没有做 robot  onboarding；早期项目少，admin 最省事 | robots=0、members 只有 admin（直接证据；动机为推断） |
| 保留 `check-changes` | 文档/注释类改动不构建，节省构建时间 | Task 的 `docs-patterns`/`build-patterns` 与 `when` 门控（直接证据） |
| tag 用 commit SHA | 可追溯到具体提交，避免 `latest` 漂移 | 四条线的 tag 规则（直接证据） |
| CI 只写 GitOps、不直接 apply 集群 | CI 不需要 kubeconfig；集群状态由 ArgoCD 收敛，避免 CI 持有集群写权限 | Task 只 `git push` + ArgoCD application（直接证据） |
| ArgoCD 开 selfHeal | 手工改动会被纠回，保证 Git 是唯一事实源 | 42 个 app 的 syncPolicy（直接证据） |
| `pipeline` SA 用 `edit` | 为了让 EL/Task 能创建 PipelineRun，直接给了内置 `edit`；没有按最小权限拆分 | ClusterRoleBinding（直接证据；动机为推断） |

---

## 5. 一条完整链路（以 deeptutor 为例）

下面每一跳都标“谁访问谁 + 用哪把钥匙 + 钥匙存在哪 + 如何验证”。

### 第 0 跳：开发者 → GitLab

- **谁访问谁**：开发者的 git 客户端 → `http://192.168.67.201`。
- **钥匙**：开发者自己的 GitLab 账号（HTTPS 密码/PAT，或 SSH key）。不是本文管理的自动化凭据。
- **验证**：`git ls-remote http://192.168.67.201/deeptutor/deeptutor.git`。

### 第 1 跳：GitLab → webhook

- **谁访问谁**：GitLab 的 webhook 投递器 → `http://el-deeptutor.internal/`（`/etc/hosts` 解析到 `10.0.0.252`）。
- **钥匙**：项目 hook 的 Secret token，放在 `X-Gitlab-Token` 头；对应 `cicd/deeptutor-webhook-secret` 的 `secretToken`。
- **存在哪**：GitLab 数据库 `web_hooks.token` + K8s Secret（SealedSecret 解密后）。
- **验证**：`WebHookLog` 有 202 记录；错误 token 不生成 PipelineRun。
- **注意**：这一段是 HTTP 80，没有 TLS；token 在同二层网络里可被嗅探。

### 第 2 跳：Traefik → EventListener

- **谁访问谁**：Traefik（`10.0.0.252:80`）→ `el-deeptutor-listener.cicd.svc:8080`。
- **钥匙**：无。集群内 Service 不做认证。
- **存在哪**：不适用。
- **验证**：`kubectl -n cicd get ingress deeptutor-el -o json`、`curl -H 'Host: el-deeptutor.internal' http://10.0.0.252/` 返回 400（listener 在）。

### 第 3 跳：EventListener 拦截器

- **谁访问谁**：Tekton Triggers sink → K8s API 读 Secret（用 EL Pod 的 `pipeline` SA）。
- **钥匙**：`deeptutor-webhook-secret` 的 `secretToken`；interceptor 做明文字符串比较。
- **存在哪**：`cicd` namespace 的 Secret（SealedSecret 落地）。
- **验证**：`kubectl -n cicd get eventlistener deeptutor-listener -o json`；EL 日志出现 `ResolvedParams` 与 `creating resource pipelineruns`。

### 第 4 跳：TriggerBinding

- **谁访问谁**：EventListener 内部，无网络访问。
- **钥匙**：无。
- **映射**：`repository.git_http_url → gitrepositoryurl`、`after → gitrevision`、`before → gitbefore`。
- **验证**：`kubectl -n cicd get triggerbinding deeptutor-binding -o json`。

### 第 5 跳：TriggerTemplate → PipelineRun

- **谁访问谁**：EventListener → kube-apiserver（`POST /apis/tekton.dev/v1/namespaces/cicd/pipelineruns`）。
- **钥匙**：EL 的 `pipeline` SA token（Projected ServiceAccount token，自动挂载）。
- **存在哪**：Pod 内 `/var/run/secrets/kubernetes.io/serviceaccount/token`；对应 ClusterRoleBinding `pipeline-edit-binding` → `ClusterRole/edit`。
- **验证**：`kubectl -n cicd get sa pipeline`、`kubectl auth can-i create pipelineruns --as=system:serviceaccount:cicd:pipeline -n cicd`。

### 第 6 跳：PipelineRun → TaskRun Pod

- **谁访问谁**：Tekton controller → kube-apiserver → kubelet → 创建 Pod。
- **钥匙**：controller 自己的 SA；Pod 使用 `serviceAccountName=pipeline`，并带 `imagePullSecrets=[harbor-auth]`。
- **存在哪**：TriggerTemplate 的 `taskRunTemplate`。
- **验证**：`kubectl -n cicd get pipelinerun <name> -o json` 的 `spec.taskRunTemplate`。

### 第 7 跳：clone（Task → GitLab）

- **谁访问谁**：Task Pod → `http://192.168.67.201/deeptutor/deeptutor.git`。
- **钥匙**：`deeptutor-gitlab-auth` 的 `username` + `password`（env `GIT_USERNAME`/`GIT_PASSWORD`）。
- **存在哪**：`cicd/deeptutor-gitlab-auth`（SealedSecret `deeptutor-gitlab-auth` 解密）。
- **验证**：`git ls-remote` 用同一凭据成功；Task 脚本把凭据拼进 `http://user:pass@host/path`。
- **风险**：凭据以环境变量存在，`kubectl exec` 或 `/proc/<pid>/environ` 可读；Task Pod 还有 `pipeline` SA，能直接读 Secret。

### 第 8 跳：check-changes（Task → GitLab）

- **谁访问谁**：Task Pod → 同一仓库（fetch `before`，diff）。
- **钥匙**：同 `deeptutor-gitlab-auth`。
- **存在哪**：同上。
- **验证**：Task 结果 `need-build`；失败时 fail-open（仍然构建）。
- **门控**：Pipeline 的 `when` 读 `$(tasks.check-changes.results.need-build) == "true"`，为 false 时跳过 build/promote。

### 第 9 跳：build（Task → buildkitd → Harbor）

- **谁访问谁**：Task Pod → `buildkitd.cicd.svc:1234`（gRPC，无 TLS/认证）；buildkitd → `192.168.67.202:8443`。
- **钥匙**：Task 挂载 `harbor-auth` 的 `.dockerconfigjson` 到 `/home/user/.docker`；`buildctl` 用这份 config 做 registry token 交换，buildkitd 完成 push。
- **存在哪**：`cicd/harbor-auth`（SealedSecret）+ Task 的 volume。
- **验证**：`kubectl -n cicd get task deeptutor-build-push -o json` 的 volume；Harbor artifacts 出现对应 tag。
- **风险**：buildkitd 是 privileged + hostPath，且 1234 对全集群开放；任何 Pod 都能提交构建请求。

### 第 10 跳：promote（Task → GitOps 仓）

- **谁访问谁**：Task Pod → `http://192.168.67.201/deeptutor/deeptutor-gitops.git`。
- **钥匙**：`deeptutor-gitlab-auth` 的 `username` + `password`。
- **存在哪**：同上。
- **动作**：`sed -i` 改 `overlays/prod/kustomization.yaml` 的唯一 `newTag` 行 → `git add/commit/push origin HEAD:main`。
- **验证**：Git 提交作者是 `deeptutor-cicd-bot`；`main` 是 protected，但 Maintainer（bot 的角色）可推。

### 第 11 跳：ArgoCD 拉仓

- **谁访问谁**：ArgoCD repo-server（或代它读取凭据的 argocd-server）→ `http://192.168.67.201/deeptutor/deeptutor-gitops.git`。
- **钥匙**：`argocd/deeptutor-repo-secret` 的 `username`（`gitlab+deploy-token-6`）+ `password`。
- **存在哪**：`argocd` namespace 的 repository secret（base64 明文，人工创建，不在 Git）。
- **节奏**：`timeout.reconciliation=120s`，jitter 60s；没有 GitLab → ArgoCD 的 webhook，所以最坏约 3 分钟。
- **验证**：`kubectl -n argocd get application deeptutor -o json` 的 `status.sync.revision`；`argocd-cm` 的 `timeout.reconciliation`。

### 第 12 跳：ArgoCD apply

- **谁访问谁**：ArgoCD application-controller → kube-apiserver。
- **钥匙**：`argocd-application-controller` SA token；ClusterRole 是 `*/*/*`。
- **存在哪**：`argocd` namespace 的 SA + ClusterRoleBinding。
- **验证**：`kubectl get clusterrole argocd-application-controller -o json`；`kubectl -n argocd get application deeptutor` 为 Synced/Healthy。

### 第 13 跳：kubelet 拉镜像 → Pod 起来

- **谁访问谁**：节点 kubelet → Harbor:8443。
- **钥匙**：deeptutor 没有 imagePullSecret，因为项目 public；compassio/china 用 `harbor-auth`，openwebui 用 SA 的 `harbor-pull`。
- **存在哪**：对应 namespace 的 Secret 或 SA。
- **验证**：`kubectl -n deeptutor get deploy deeptutor -o json` 的镜像；Pod `Running`；临时无 secret Pod 拉私有镜像会 `ErrImagePull`。

### 变体：openwebui 的前两跳

```
git push → GitLab → runner 轮询到 job
  → job Pod 用 SA token POST PipelineRun
  → 后续 clone/build/promote 与上面第 7–13 跳相同（只是 secret/项目不同）
```

关键差异：**没有 GitLab → Traefik 的 webhook**，因此也没有 `X-Gitlab-Token` 这一段；取而代之的是 runner 的 `runners.toml` token（GitLab 侧）和 job Pod 的 SA token（K8s 侧）。

---

## 6. 风险面（按“泄露后最坏后果”排序）

排序原则：先看“拿到这把钥匙的人最终能控制什么”，再看“这把钥匙有多少副本、是否容易被读到”。观感（例如“密码太长”）不参与排序。

### R1. `digitalsupply` group token → 写 `platform-gitops` → ArgoCD → 整个集群

**最坏后果**：集群管理员。攻击者不需要碰 Harbor，也不需要 K8s 权限。

链路：

1. 拿到 `gitlab-auth`（或同值的 `china-study-free-gitlab-auth`）的 `password`/`token`；
2. 以 `ci-rw` 身份 push 到 `digitalsupply/platform-gitops` 的 `main`（该 bot 是 Maintainer，protected branch 的 push access level=40；实测 `git push --dry-run` 已通过鉴权，仅因非 fast-forward 被拒）；
3. `platform-cicd` / `platform-cicd-secrets` / `platform-buildkitd` 等 Application 是 automated + selfHeal，120s 内同步；
4. 可以改 Tekton Task/EventListener（用 `pipeline` SA 的 `edit` 权限进一步拿全集群 Secret），也可以直接加一个挂 `hostPath: /` 的 privileged Pod；
5. `argocd-application-controller` 本身是 `*/*/*`，apply 不受 namespace 限制。

**证据**：

- `git push --dry-run` 到 `platform-gitops` 返回非 fast-forward（鉴权通过）；到 `deeptutor-gitops` 返回 401（跨 group 被拒）。
- `git log` 显示 `compassio-gitops` / `deeptutor-gitops` 的 `main` 上有 `ci-rw` 的空提交（“verify ci-rw can push protected main”）。
- `protected_branches`：`main` 的 push/merge access level 都是 40，`allow_force_push=false`。
- `argocd-application-controller` ClusterRole：`apiGroups=["*"], resources=["*"], verbs=["*"]`。
- `platform-cicd` syncPolicy：automated + selfHeal。

**现有控制**：token 只有 repo scope、无 `api`；`main` 是 protected（但 Maintainer 可推）；token 有到期日。
**为什么仍排第一**：这些控制只限制了“不能用 API 改设置”，没有限制“改 GitOps 内容”；而 GitOps 内容就是集群期望状态。

### R2. `cicd/pipeline` SA = `ClusterRole/edit`（全集群）

**最坏后果**：全集群 Secret 泄露 + 任意 namespace 起 Pod → 集群管理员。

- `kubectl auth can-i get secrets --as=system:serviceaccount:cicd:pipeline -n kube-system` → **yes**；
- `kubectl auth can-i create pods --as=… -n kube-system` → **yes**；
- 所有 Task Pod、EventListener Pod 都用这个 SA（TriggerTemplate `serviceAccountName=pipeline`，EL `serviceAccountName=pipeline`）。
- 只要能让一条流水线跑起来（webhook token、仓库写权限、或直接创建 PipelineRun），就能在 Task 脚本里读走 `sealed-secrets-keybh4kb`、业务库密码、Harbor admin，再起 privileged Pod。

**现有控制**：`edit` 不允许改 RBAC（不能给自己提权到 cluster-admin），但“读所有 Secret + 起 Pod”已经足够拿到节点/集群。
**为什么排第二**：它是“身份”而不是一把静态字符串，利用需要一次 Pod 执行；但一旦利用，后果与 R1 同级。

### R3. Harbor admin（5 个 Secret + GitLab 主机同一份）

**最坏后果**：供应链投毒 + 镜像删除 DoS；可向任意项目推任意 tag。

- 所有构建 Task 都挂 `harbor-auth`；runner job 也通过 `image_pull_secrets` 拿同一份；`compassio`/`china-study-free` 的 Deployment 直接用它拉镜像。
- Harbor admin 能改项目、建 robot/user、删制品；`deeptutor` 还是 public，推上去的镜像可被匿名拉取。
- 结合 ArgoCD 自动同步：如果某个 tag 被覆盖（Harbor 是否开启 tag immutability 未验证），下一次 Pod 重建就会拉起被替换的镜像。
- 当前没有 Harbor 审计日志（`X-Total-Count: 0`），投毒后难以追溯。

**现有控制**：Harbor 在 192.168.67.0/24，非公网；镜像 tag 是 commit SHA（但可被覆盖）。
**为什么排第三**：它控制“制品”，不直接控制“集群 API”；要变成集群接管还需要应用 Pod 有更高权限或配合 R1/R2。

### R4. GitLab Runner job 的 SA → 读走 `cicd` 全部 Secret

**最坏后果**：拿到 R1 + R3 的钥匙。

- `openwebui-runner-role` 对 `cicd` 的 `secrets` 有 `get/list/watch`；
- 绑定给 `gitlab-runner` namespace 的 `default` 和 `gitlab-runner` 两个 SA；
- 任何能在这个 project runner 上跑 job 的人（= 能 push `digitalsupply/openwebui` 的人，或拿到 runner token 的人）都能在 `.gitlab-ci.yml` 里加一步 `kubectl get secret -n cicd -o yaml`。
- 该 Role 还允许创建/删除 PipelineRun，可反复触发构建。

**现有控制**：runner 只绑定一个项目；project 是 private。
**为什么排第四**：利用门槛是“能改 openwebui 仓库或 runner”，但成功后直接获得 R1/R3 的钥匙。

### R5. webhook secret token + 可达的 EventListener

**最坏后果**：用攻击者控制的源码构建镜像，并把它 promote 到 GitOps，最终部署进业务 namespace。

- TriggerTemplate 的 `gitrepositoryurl` 来自 `body.repository.git_http_url`，`image-tag` 来自 `body.after`；也就是说，**payload 决定 clone 哪个仓库、用什么 tag**，而镜像仓库是模板里写死的。
- 知道 token 的人可以构造 push payload：clone 攻击者仓库 → build → push 到 `openwebui/open-webui:<attacker-tag>`（或 compassio/deeptutor/china 的固定仓库）→ update-gitops 把 `newTag` 改成该 tag → ArgoCD 部署。
- EL 通过 Traefik `10.0.0.252:80` 暴露，无 IP allowlist、无 TLS、无 NetworkPolicy；token 是静态的，不会随 push 轮换。
- 实测：错误 token 不生成 PipelineRun，正确 token 生成；说明校验有效，但也说明“拿到 token 就能触发”。

**现有控制**：token 高熵；CEL 只允许 `push` + `main`；`git-clone` 会用 CI 的 group token 去 clone payload 给的 URL（如果 URL 是攻击者仓库，group token 会作为 Basic Auth 发给攻击者的 HTTP 服务器——**这是额外的凭据外带风险**）。
**为什么排第五**：需要先拿到 token；拿到后能部署任意镜像到单个业务 namespace，但不直接拿集群 API。

### R6. GitLab 主机的 root 旁路凭据

**最坏后果**：GitLab 管理员 + 集群身份 + Harbor 管理员。

- `/etc/gitlab/initial_root_password` 仍在（745 字节，2026-10-12）；是否已改密**未验证**。
- `/root/.kube/config` 含 client certificate/key；`/root/.kube/deeptutor-config` 是第二份。
- `/root/.docker/config.json` 含 Harbor admin（哈希与 `harbor-auth` 一致）。
- 主机上还有 `/root/ChinaStudyFree`、`/root/DeepTutor`、`/root/deeptutor-gitops` 等仓库副本。
- 这意味着“GitLab 主机被登录”≈ 全部失守；而 GitLab 本身是互联网/办公网可访问的服务。

**为什么排第六**：它不是某一条流水线的 Secret，而是“所有 Secret 的上游”；但利用前提是拿到主机登录权限，不是拿到某个 token。

### R7. sealed-secrets 私钥（单副本）

**最坏后果**：解密 Git 里所有 SealedSecret；丢失则所有密文无法重建。

- `kube-system/sealed-secrets-keybh4kb` 是唯一私钥；没有看到备份 Secret/离线备份的证据。
- 控制器对全集群 Secret 有 CRUD；拿到它的 SA 或节点 root 就能读私钥。
- 私钥泄露后，Git 里的密文全部失效（攻击者可解出 GitLab group token、webhook token、Harbor admin）。
- 私钥丢失后，`platform-cicd-secrets` / `platform-buildkitd` 无法在新集群重建，必须重新封印所有密文。

**为什么排第七**：它本身不是“日常使用的钥匙”，但它是所有 SealedSecret 的根；一旦泄露，R1/R3 同时成立。

### R8. 明文/注解残留的副本

**最坏后果**：扩大 R3 的泄露面，且难以彻底轮换。

- `compassio/harbor-auth` 是手工 Secret，无 owner，值 = Harbor admin。
- `china-study-free/harbor-auth` 同样手工，且 `last-applied-configuration` 注解里带完整 `.dockerconfigjson`（515 字节），等于在 etcd/备份里存了两份。
- `gitlab-auth` 与 `china-study-free-gitlab-auth` 是同一 token 的两个 Secret；轮换只改一个会导致另一条流水线静默 401。
- 依据：`kubectl -n compassio get secret harbor-auth -o json`、`kubectl -n china-study-free get secret harbor-auth -o json`、token 哈希比对。

### R9. 6 个 deploy token

**最坏后果**：只读对应 GitOps 仓库；可看到 sealed 密文和部署清单，但不能推、不能调 API。

- 单项目、`read_repository`、2027-11-12 到期；实测跨项目 401、push 403、API 基本 404。
- 风险主要是“信息泄露”（仓库结构、镜像 tag、内部地址），不足以直接提权。
- 依据：`DeployToken.find_each`、逐仓库 `ls-remote`、`push --dry-run`。

### R10. `deeptutor` 项目 public

**最坏后果**：匿名拉取镜像，泄露应用二进制/依赖/配置默认值；不能推。

- 匿名 token + manifest 200；`_catalog` 仍 401。
- 如果镜像里误带构建期凭据（例如 `ARG`/层缓存），会直接公开。
- 依据：匿名 `/service/token` + manifest 测试。

### R11. 可观测性与传输面

- Harbor 审计日志为空；GitLab WebHookLog 只有 deeptutor/china 有记录，compassio 为 0。
- webhook 走 HTTP 80，无 TLS；GitLab hook `enable_ssl_verification=false`。
- `cicd` 没有 NetworkPolicy；buildkitd 1234 无认证；EL 8080 集群内全网可达。
- `gitlab-runner` manager 无 imagePullSecrets，依赖节点缓存（隐患）。
- 这些不直接“泄露后最坏”，但会显著降低发现与止损速度，故列在最后。

### 风险排序一览

| 排名 | 凭据/身份 | 最坏后果 | 关键依据 |
|---|---|---|---|
| 1 | `digitalsupply` group token | 集群管理员（经 GitOps/ArgoCD） | dry-run 鉴权通过、ArgoCD `*/*/*` |
| 2 | `cicd/pipeline` SA（edit） | 全集群 Secret + 任意 Pod | `auth can-i` 全 yes |
| 3 | Harbor admin（多副本） | 供应链投毒/删镜像 | 0 robot、5+1 份同值 |
| 4 | runner job SA | 读走 `cicd` 全部 Secret | Role 含 secrets get/list |
| 5 | webhook secret token | 任意镜像构建 + 部署 | payload 控制 URL/tag |
| 6 | GitLab 主机 root 旁路 | GitLab+集群+Harbor | 初始密码/kubeconfig/docker config |
| 7 | sealed-secrets 私钥 | 解密全部密文 / 丢失断链 | 单副本 |
| 8 | 明文/注解副本 | 扩大 R3 | `last-applied` 仍存在 |
| 9 | deploy token | 只读仓库 | 单项目、只读 |
| 10 | public deeptutor | 镜像内容公开 | 匿名 200 |

---

## 7. 轮换 runbook（按依赖顺序）

### 7.0 前置（不要跳）

1. **备份根**：把 `kube-system/sealed-secrets-keybh4kb` 导出到离线介质（不要进 Git，不要贴终端）。
2. **冻结变更**：暂停四条流水线的自动触发（临时禁用 webhook / runner），避免轮换中产生半旧半新的构建。
3. **记录基线**：对 7 个 `cicd` Secret 的每个 key 计算 SHA-256（只存哈希，不存值）；记录 ArgoCD 42 个 app 的 Synced/Healthy 状态。
4. **准备封印环境**：`kubeseal` 可用（GitLab 主机上有 `/usr/local/bin/kubeseal`），拿到控制器公钥证书；`--scope strict -n cicd --name <secret>`。
5. **原则**：先建新、验证、再撤旧；任何时候不要把值写进 shell history/终端输出；临时文件 `chmod 600` 并在结束后删除。

### 7.1 第一步：GitLab group token（影响面最大）

**依赖顺序**：先换 GitLab 身份，再换 K8s 里的副本；否则新 Secret 指向已撤销的旧 token。

1. 在 GitLab 为 `digitalsupply`（group 2）和 `deeptutor`（group 8）各建一个新的 group access token：
   - 角色：Maintainer（因为要推 protected `main`；若把 `main` 的 push access level 降到 Developer，可用 Developer）。
   - scope：只勾 `read_repository`、`write_repository`；不要 `api`。
   - 到期：按组织策略（当前是 1 年）。
2. 更新三个 Secret 的**两个副本**：
   - `gitlab-auth` 与 `china-study-free-gitlab-auth` 必须写入**同一个新 token**（否则 china 线断）；
   - `deeptutor-gitlab-auth` 写入 group 8 的新 token；
   - `username` 可保持 `ci-rw`（它只是 token 名，不参与认证；但为可读性建议与 token 名一致）。
3. 重新封印并提交：
   ```bash
   kubectl -n cicd create secret generic gitlab-auth \
     --from-literal=username=ci-rw \
     --from-literal=password="$NEW_TOKEN" \
     --from-literal=token="$NEW_TOKEN" \
     --from-literal=git-url=http://192.168.67.201/digitalsupply/openwebui.git \
     --from-literal=gitops-url=http://192.168.67.201/digitalsupply/openwebui-gitops.git \
     --dry-run=client -o yaml \
   | kubeseal --cert cert.pem --scope strict -n cicd --name gitlab-auth - \
   > platform/secrets/cicd/sealed/gitlab-auth.sealed.yaml
   ```
   对 `china-study-free-gitlab-auth`、`deeptutor-gitlab-auth` 重复；注意 `strict` 绑定 namespace+name，改名会解不开。
4. 提交 `platform-gitops`，让 `platform-cicd-secrets` 同步；确认新 Secret 的 `ownerReferences` 仍指向 SealedSecret，且 7 个 key 的哈希符合预期。
5. 重启三个 EventListener（让 interceptor 重新读取 Secret；Task Pod 每次新建会读新值）：
   ```bash
   kubectl -n cicd rollout restart deploy/el-china-study-free-listener \
     deploy/el-compassio-listener deploy/el-deeptutor-listener
   ```
6. 验证（用新 token，不打印值）：
   - `git ls-remote` 四个源码仓 + 四个 GitOps 仓；
   - `git push --dry-run` 到各 GitOps `main`（非 fast-forward 是可接受的“鉴权通过”信号；403 才是失败）；
   - `curl -H "PRIVATE-TOKEN: $NEW" /api/v4/projects` 应返回 **403 insufficient_scope**（证明没有 `api` scope）。
7. 全部通过后，在 GitLab 撤销旧 token（id 3/4）。**先别删旧 Secret**，留 24h 回滚窗口。

**失败回滚**：把旧 token 重新封印回三个 Secret，ArgoCD sync，重启 EL；旧 token 在撤销前一直有效。

### 7.2 第二步：deploy token + ArgoCD repository secret

1. 为 6 个 GitOps 仓库各建一个新的 deploy token（`argocd-ro`，`read_repository`，到期日一致）。
2. 更新 6 条 ArgoCD repository secret 的 `password`（`username` 形如 `gitlab+deploy-token-N`，新 token 的编号会变，必须同步改 `username`）。
3. 硬刷新 ArgoCD：
   ```bash
   kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
   ```
   或 port-forward `svc/argocd-server` 后 `POST /api/v1/applications/<app>/sync`。
4. 验证：每个 Application 仍 `Synced/Healthy`；`argocd-repo-server` 日志无 401；用新 deploy token 对各自仓库 `git ls-remote` 成功、对别的仓库 401、push 403。
5. 撤销旧 deploy token（6 个）。

**注意**：ArgoCD repo secret 是 base64 明文，更新时不要用 `kubectl edit` 把值留在 shell history；用临时文件 + `kubectl apply` 后删除。

### 7.3 第三步：webhook secret token

webhook token 是单值，无法“新旧并存”，所以要接受一个很短的切换窗口。

1. 生成新的高熵随机串（例如 32 字节 base64）。
2. 在 GitLab 项目设置里把 hook 的 Secret token 改为新值；同时对三个项目操作。
3. 立即更新三个 `*-webhook-secret` 的 `secretToken`（重新封印 + ArgoCD sync），并重启三个 EL。
4. 验证：
   - 用**错误** token 发 `ref=refs/heads/main` 的合成请求：应返回 202 但不产生 PipelineRun；
   - 用**正确** token 发 `ref=refs/heads/audit-test` 的合成请求：应 202 且不产生 PipelineRun（CEL 拒绝）；
   - 真实 push 一次（或等下一次 push），确认 `WebHookLog` 202 且 PipelineRun 出现。
5. 若失败：把 GitLab hook token 和 Secret 同时改回旧值，重启 EL。

**注意**：不要用“HTTP 202”判断成功；202 只代表 EL 收下。必须比对 PipelineRun 数量/日志。

### 7.4 第四步：GitLab Runner token

1. 在 GitLab 项目 `digitalsupply/openwebui` 的 CI/CD → Runners 里重置 runner authentication token。
2. 更新 `gitlab-runner/gitlab-runner-config` 的 `runners.toml`（重新封印 `platform/gitlab-runner/sealed/config.sealed.yaml`），保持 `name/id/url/executor/image_pull_secrets` 不变。
3. `kubectl -n gitlab-runner rollout restart deploy/gitlab-runner`。
4. 验证：runner 日志出现 “Checking for jobs”；手动跑一次 openwebui pipeline（或 push 一个空提交），确认 job 成功创建 PipelineRun。
5. 旧 token 在重置时即失效，无需额外撤销。

### 7.5 第五步：Harbor（从 admin 迁到 robot）

**最小版（只轮换 admin）**：

1. 在 Harbor UI/API 改 admin 密码；
2. 更新 5 个 dockerconfig Secret（`cicd`、`compassio`、`china-study-free`、`gitlab-runner`、`open-webui`）+ GitLab 主机 `/root/.docker/config.json`；
3. 验证：`/api/v2.0/users` 用新口令 200；四个业务 namespace 各重启一个 Pod 能拉镜像；buildkit/kaniko 各跑一次构建。
4. 删除 `china-study-free/harbor-auth` 的 `last-applied-configuration`（重新 apply 一份不带注解的 Secret，或改成 SealedSecret）。

**推荐版（robot 化，顺带解决 R3）**：

1. 为每个项目建两个 robot：
   - `ci-push-<project>`：`push`、`pull`（仅该项目）；
   - `k8s-pull-<project>`：`pull`（仅该项目）。
2. 把构建 Task 的 `harbor-auth` 换成对应项目的 push robot；把业务 namespace 的 pull secret 换成 pull robot；`cicd` 里为每个项目准备独立 Secret（不要再共用一个 `harbor-auth`）。
3. `openwebui` 基础镜像（kaniko、runner）需要 pull 权限，给 `k8s-pull-openwebui`。
4. 验证每个 robot 只能 push/pull 自己项目（用 Harbor API 的 `/service/token` + manifest 做正/负测试）。
5. 全部切换后，再轮换 admin 密码，并把 admin 限制为人工运维使用。

**顺序理由**：robot 迁移会同时改 5 个消费点，放在 GitLab/Runner 之后，避免“身份换了但构建还没验证”时无从判断是哪一层坏了。

### 7.6 第六步：集群身份与明文清理

1. **`cicd/pipeline` SA**：把 `ClusterRole/edit` 换成 namespace Role，只允许：
   - `tekton.dev` 的 `pipelineruns`/`taskruns` 创建与状态更新；
   - 读取本流水线实际需要的 Secret（按 name 的 `resourceNames` 白名单）；
   - 不再允许 `pods`、`secrets`（全集群）。
2. **`openwebui-runner-role`**：去掉 `secrets` 的 get/list/watch；如果 job 只需要创建 PipelineRun，保留 `pipelineruns` 即可。
3. **ArgoCD application-controller**：评估能否从 `*/*/*` 降为显式资源列表；至少限制 `cluster-admin` 级别的写操作。
4. **明文清理**：把 `compassio/harbor-auth`、`china-study-free/harbor-auth` 改成 SealedSecret；删除 `last-applied-configuration`；删除 `argocd-initial-admin-secret`（改密后）。
5. **GitLab 主机**：改 root 密码、删除 `initial_root_password`；把 `/root/.kube/config` 的 client cert 换成短期 token/SSO；把 Harbor 凭据从 `/root/.docker/config.json` 移除或改用 robot。

**验证**：

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:cicd:pipeline -n kube-system   # 期望 no
kubectl auth can-i create pods  --as=system:serviceaccount:cicd:pipeline -n kube-system   # 期望 no
kubectl auth can-i get secrets --as=system:serviceaccount:gitlab-runner:default -n cicd   # 期望 no
kubectl -n cicd get pipelineruns                                                          # 仍能正常创建/运行
```

### 7.7 第七步：sealed-secrets 私钥（最后做）

1. 先备份当前私钥 Secret（离线、加密）。
2. 若只是备份：验证能在隔离环境用 `kubeseal --recovery-unseal` 解出（不要打印明文）。
3. 若要轮换密钥：生成新密钥对 → 重新封印所有 SealedSecret（`cicd` 7 个、`gitlab-runner` 2 个、`open-webui` 1 个、`argocd-oauth` 等）→ 确认新 Secret 正常 → 再删除旧密钥。
4. 验证：随机挑一个 Secret，`ownerReferences` 正常、Pod 能正常消费；删除一个 Secret 让控制器从 SealedSecret 重建。

### 轮换依赖图

```
sealed 私钥（备份最早，轮换最后）
        │
GitLab group token ──► cicd/gitlab-auth + china + deeptutor ──► EL 重启 ──► 流水线验证
        │
GitLab deploy token ──► ArgoCD repo secret ──► hard refresh ──► app 仍 Synced
        │
GitLab webhook token ──► 三个 hook + 三个 Secret（同步切换）
        │
GitLab runner token ──► runners.toml Secret ──► runner 重启
        │
Harbor admin/robot ──► 5 个 dockerconfig + GitLab 主机 ──► 拉/推验证
        │
集群 RBAC / 明文清理 / root 旁路
```

### 轮换验收清单

- [ ] 3 个源码仓 + 4 个 GitOps 仓 `ls-remote` 成功（用新 group token）。
- [ ] `push --dry-run` 到各 GitOps `main` 不是 403。
- [ ] `PRIVATE-TOKEN` 调 `/api/v4/projects` 返回 403（证明没有 `api` scope）。
- [ ] 6 个 ArgoCD Application 仍 Synced/Healthy，repo-server 无 401。
- [ ] 错误 webhook token 不产生 PipelineRun；正确 token 能产生。
- [ ] Runner 能领取 job 并创建 PipelineRun。
- [ ] Harbor 每个项目用对应 robot 能 pull/push，跨项目被拒。
- [ ] `pipeline` SA 不再能读 `kube-system` Secret、不再能在 `kube-system` 建 Pod。
- [ ] `gitlab-runner` SA 不再能读 `cicd` Secret。
- [ ] 7 个 `cicd` Secret 无 `last-applied-configuration`；`compassio`/`china` 的 Harbor 凭据已 SealedSecret 化。
- [ ] sealed 私钥有离线备份；删除一个 Secret 能自动重建。

---

## 8. 未验证 / 证据缺口

明确列出，避免把推测写成事实：

1. **compassio webhook 端到端**：hook 配置存在、路径可达、token 一致，但 `WebHookLog` 为 0；没有真实投递证据。
2. **china-study-free 的 `694f79f` 短 tag 来源**：与当前 TriggerTemplate 的 40 位 `after` 不一致，可能是手工/旧版本流水线产物；未查 GitLab 历史 pipeline。
3. **Harbor tag immutability**：没有查项目配置；因此“覆盖已有 tag”是否可行未定。
4. **Harbor audit**：`X-Total-Count: 0`，无法还原“谁在何时推了哪个 tag”。
5. **root 初始密码是否仍有效**：文件存在，但未尝试登录；不能断言“未改密”。
6. **GitLab 主机 `/root/.kube/config` 的实际权限**：只确认含 client cert/key，未用该 kubeconfig 执行 `auth can-i`。
7. **ArgoCD repo-server 读取 repository secret 的具体路径**：`argocd-repo-server` Role 的 `rules` 为 null，可能由 `argocd-server` 代读；未做抓包/源码级确认。
8. **sealed-secrets 私钥备份**：未在集群外发现备份证据；不能断言“没有备份”，只能说“未验证”。
9. **runner manager 无 imagePullSecrets 的实际影响**：当前镜像在节点缓存中（`IfNotPresent`），未触发重新调度；是否会在新节点拉取失败未实测。
10. **ArgoCD 轮询节奏**：配置是 120s + jitter 60s；实际从 push 到 Pod 更新的端到端延迟未做秒级测量。
11. **`compassio` 的 `ci-compassio.xyz` 入口**：Ingress 里有这条 host 规则，但 GitLab hook 用的是 `el-deeptutor.internal`；前者是否有 DNS/证书未验证。
12. **Harbor admin 的用户记录**：`/users` 只返回 `root`，但项目成员显示 `admin`；admin 是内置账号，未进一步核对数据库。

---

## 附录 A：取证命令（可复现，均不输出密钥值）

```bash
# 集群对象
kubectl get nodes -o wide
kubectl -n cicd get secret -o json
kubectl -n cicd get task,pipeline,eventlistener,triggerbinding,triggertemplate -o json
kubectl -n cicd get ingress,svc -o json
kubectl -n argocd get applications -o json
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository -o json
kubectl get clusterrole argocd-application-controller -o json
kubectl auth can-i get secrets --as=system:serviceaccount:cicd:pipeline -n kube-system
kubectl auth can-i get secrets --as=system:serviceaccount:gitlab-runner:default -n cicd

# GitLab（只读）
ssh root@192.168.67.201 'gitlab-rails runner "Project.find_each { |p| p.hooks.each { |h| puts [p.full_path,h.url].join(\" | \") } }"'
ssh root@192.168.67.201 'gitlab-rails runner "PersonalAccessToken.find_each { |t| puts [t.id,t.name,t.scopes.inspect,t.expires_at,t.revoked].join(\" | \") }"'
ssh root@192.168.67.201 'gitlab-rails runner "DeployToken.find_each { |t| puts [t.id,t.name,t.username,t.scopes.inspect,t.expires_at].join(\" | \") }"'
ssh root@192.168.67.201 'gitlab-rails runner "Ci::Runner.find_each { |r| puts [r.id,r.description,r.runner_type].join(\" | \") }"'

# Harbor（只读）
HARBOR_USER=$(...); HARBOR_PASS=$(...)   # 从 cicd/harbor-auth 解出，不落盘/不回显
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" https://192.168.67.202:8443/api/v2.0/projects
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" https://192.168.67.202:8443/api/v2.0/robots
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" https://192.168.67.202:8443/api/v2.0/projects/openwebui/repositories
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" https://192.168.67.202:8443/api/v2.0/audit-logs

# 网络
kubectl -n cicd run audit-net --rm -i --restart=Never --image=... -- sh -c \
  'wget -q -O /dev/null http://192.168.67.201/users/sign_in && echo gitlab-ok'
ssh root@192.168.67.201 'ip route; getent hosts el-deeptutor.internal; curl -s -o /dev/null -w "%{http_code}\n" http://10.0.0.252/'
```

## 附录 B：术语表

| 术语 | 含义 |
|---|---|
| GitOps | 把“期望状态”写进 Git，由 ArgoCD 持续对齐集群 |
| promote | CI 把新镜像 tag 写回 GitOps 仓库，触发 ArgoCD 部署 |
| EventListener | Tekton Triggers 的 HTTP 入口，负责校验与创建 PipelineRun |
| Interceptor | EL 里的前置校验/过滤（本环境是 gitlab token + CEL） |
| TriggerBinding | 从 webhook body 抽取参数 |
| TriggerTemplate | 用参数渲染 PipelineRun |
| workspace | Tekton Task 之间共享的存储（本环境是 `nfs-sc` PVC） |
| imagePullSecret | kubelet 拉私有镜像时使用的 dockerconfigjson |
| robot account | Harbor 的机器账号，按项目/动作授权 |
| SealedSecret | 用控制器公钥加密、可安全入库的 Secret 信封 |
| protected branch | GitLab 分支保护；本环境 `main` 允许 Maintainer 推 |

---

**一句话总结**：这套 CI/CD 的“身份收敛”只完成了一半 —— GitLab 侧从 root PAT 换成了两个 group token，Harbor 侧仍是 admin 单账号，集群侧仍把 `edit` 绑给流水线 SA；而 GitOps 仓库的写权限与 ArgoCD 的集群通配权限连在一起，使得“一个 group token”就足以等价于“集群管理员”。
