# 凭据面收敛（2026-11-12）

起因是 GitOps 覆盖度审计收尾时顺手扫了一遍集群里的 Secret：`glpat-` 出现在 15 处，
其中 `cicd/gitlab-auth` 的 `last-applied-configuration` 注解里躺着完整原文。
这条不在原审计的 169 条里 —— 它属于"能用证据证明、但看文档看不出来"的那一类。

## 1. 处置前的状态（实测）

集群里 5 个互不相同的 GitLab token：

| token | 出现处 | 归属 | scope | 过期 |
|---|---|---|---|---|
| `cicd-agent` | 6 处（ArgoCD 4 个 repo + cicd 2 个 Secret） | **root，admin=True** | `api` | 2027-10-13 |
| `deeptutor-gitops` | 4 处（ArgoCD 2 + cicd 2） | **root，admin=True** | `api`, `write_repository`, `read_repository` | 2027-04-25 |
| 三个死 token | ArgoCD 3 个 repo 条目（`http://10.0.0.200/...`） | 已 401 | - | - |

`scope=api` + `root` 意味着：读写所有仓库、改 CI 变量、建删项目、看全部用户。一个 token
六把钥匙，轮换得同时改六处。

泄露面不止 Secret 的 `data`：

```text
kubectl -n cicd get secret gitlab-auth -o jsonpath='{.metadata.annotations}'
{"kubectl.kubernetes.io/last-applied-configuration":"{...\"stringData\":{\"password\":\"glpat-...\"...}"}
```

`last-applied-configuration` 是 `kubectl apply` 自动写的原文，任何对 Secret 有 `get` 权限的主体
（含大量 CI 的 ServiceAccount、`view` 角色）都能读到，也会被 `kubectl get -o yaml`、备份、
审计日志顺手带出去。**Secret 的 base64 至少还挡了肉眼，这个注解连挡都不挡。**

另外 cicd 的 7 个 Secret 全是 `kubectl apply` 手工建的明文对象，值只活在集群里：
既不在 git，也没有轮换记录。

## 2. 改成的模型

| 用途 | 类型 | scope | 覆盖 | 数量 |
|---|---|---|---|---|
| ArgoCD 拉仓库 | **Deploy Token**（`gitlab+deploy-token-N`） | `read_repository` | 单项目，不能推 | 6 |
| CI clone + 推 gitops 仓 | **Group Access Token**（`ci-rw`） | `read_repository`, `write_repository` | 单 group | 2 |

CI 用 group 而不是项目 token 的原因：一条流水线要**读源码仓**（`digitalsupply/openwebui`）
并**写 gitops 仓**（`digitalsupply/openwebui-gitops`），两个不同项目，项目 token 跨不过去。
group token 只有仓库读写权限，没有 `api`，碰不到 CI 变量、项目设置、用户。

集群侧 7 个 Secret 全部 SealedSecret 化（`platform/secrets/cicd/sealed/`，scope=strict），
`last-applied-configuration` 注解全部清掉。

## 3. 迁移步骤（以及踩到的坑）

### 坑 1：备份的时机

先 `kubectl get secret ... -o json > .backup.json`（0600），确认 `data` 的 sha256 之后再删。
这次备份是在**换完值之后**做的，导致后来要用旧 token 做 revoke 时，备份里已经是新值 ——
最后是从 `opencode_export.json`、`apiserver-remediation-20261109/helm-release-secrets-backup.yaml`
里找回旧 token 才完成 revoke。**先备份再改值。**

### 坑 2：SealedSecret 不接管已存在的 Secret（第二次踩）

```text
failed update: Resource "gitlab-auth" already exists and is not managed by SealedSecret
→ ArgoCD 把整条 Synced=False 判成 app Degraded（实际负载没坏）
```

加 `sealedsecrets.bitnami.com/managed=true` 标签、手工补 ownerReferences 都无效。
有效做法是**删掉 Secret，让控制器重新创建**：

```bash
kubectl -n cicd delete secret gitlab-auth
kubectl -n cicd annotate sealedsecret gitlab-auth seal-adopt=$(date +%s%N)
```

但这次 annotate **没触发重建**，控制器日志是 `update suppressed, no changes in spec` ——
它认为 spec 没变就不重新 Unseal。真正有效的是**连 SealedSecret 一起删**，
让 ArgoCD 用 git 里的密文重建一个 status 为空的 SealedSecret，此时必然走完整 Unseal。

### 坑 3：autoHeal 一次只补一个资源

删完 6 个 SealedSecret 后，`selfHeal` 每轮只 apply 一个（`operationState.operation.sync.
autoHealAttemptsCount` 到 5 就停），等了一分钟只回来 1 个。要么用 ArgoCD API 显式 sync，
要么等它慢慢补。这次是等到的：

```bash
kubectl -n argocd port-forward svc/argocd-server 18444:80   # 注意是 :80（insecure），:443 会 TLS 握手失败
TOKEN=$(curl -s -X POST http://127.0.0.1:18444/api/v1/session \
  -H 'Content-Type: application/json' -d '{"username":"admin","password":"<initial-admin>"}' | jq -r .token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:18444/api/v1/applications/platform-cicd-secrets/sync -d '{}'
```

### 坑 4：同一个 SealedSecret 被两个 app 声明

`platform/cicd/buildkitd/sealed/harbor-auth.sealed.yaml` 和新目录里的
`platform/secrets/cicd/sealed/harbor-auth.sealed.yaml` 都指向 `cicd/harbor-auth`，
tracking-id 每次 sync 来回改。已从新目录移除，`harbor-auth` 归 `platform-buildkitd` 管。

## 4. 验收（实测）

```text
42 个 Application                全部 Synced / Healthy，对象 764 → 771
7 个 cicd Secret                 ownerReferences → SealedSecret（原 0 个）
7 个 cicd Secret 内容            data 每个键的 sha256 迁移前后完全一致
旧 root token                    revoke 后 /api/v4/user 全部 401
新 group token                   git ls-remote 源码仓 + gitops 仓成功；push 到临时分支成功并删除
ArgoCD 仓库凭据                  6 个全部是 gldt- 的 deploy token（user=gitlab+deploy-token-N）
集群里剩余 glpat-                只剩 2 个 ci-rw（group token，无 api scope）
3 个 EventListener               rollout 成功（它们的 deployment 无 secretKeyRef，凭据由
                                 interceptors 运行时读取，所以换 token 不影响已运行的 pod）
```

撤销的旧 token：`cicd-agent`（id=1）、`deeptutor-gitops`（id=2），HTTP 204。
保留的：`ci-rw` × 2（id=3 → digitalsupply，id=4 → deeptutor）。

## 5. 留给以后

- ArgoCD 的 6 个 repo 凭据**没有**入库（它们是 bootstrap 级 Secret，每个集群一套）。
  轮换方式：GitLab 建新 deploy token → `kubectl -n argocd patch secret <name> --type merge
  -p '{"stringData":{"username":"...","password":"..."}}'` → 给全部 app 打 `refresh=hard`。
- `webhook-secret` 三个是 HMAC 校验值，没有对外泄露面，这次只做了入库，没有旋转。
- GitLab 侧建议把 `ci-rw` 的过期时间从 2027-11-12 调到 1 年一换，并开启 token 到期提醒。
- 如果以后要更细：把 `ci-rw` 拆成"每项目一个 project access token + 一个只读 deploy token"，
  代价是流水线要能接受两组凭据（`git-url` 与 `gitops-url` 用不同的 username/password 对）。
