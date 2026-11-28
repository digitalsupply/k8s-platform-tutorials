# Headlamp 登录令牌与按用户 RBAC（2026-11-25）

> 实测环境：K8s `v1.35.9`、Headlamp `v0.46.0`、GitLab CE `19.5.0`、
> oauth2-proxy `v7.15.6`。
>
> 前置阅读：
> [14 · oauth2-proxy vs 原生 OIDC](14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md)、
> [09 · 身份与权限](09-oidc-identity-permissions-traefik-forwardauth.md)。

## 一、结论速览

| 项目 | 现状 |
|---|---|
| 入口认证 | oauth2-proxy + GitLab OIDC，只放行 `digitalsupply` 组 |
| Headlamp 自身 | 已去掉 `-unsafe-use-service-account-token`，改为**用户粘贴 Bearer Token** |
| K8s 授权 | 按 token 身份 `system:serviceaccount:headlamp:<sa>` 走 RBAC |
| `root`（leihao） | `headlamp-root` SA → `ClusterRole/cluster-admin` |
| `bigdev` | `headlamp-bigdev` SA → `ClusterRole/headlamp-bigdev`（只读 + 工作负载读写） |
| `smallops` / 其他人 | 没有 SA、也拿不到 token → 无 K8s 权限（oauth2-proxy 先 403） |

一句话：**GitLab 登录只决定“能不能打开 Headlamp 页面”；打开后还要粘贴一个
k8s token，才决定“能在集群里做什么”。**

---

## 二、访问链路：两层认证

```text
浏览器
  │  ① 身份认证：你是谁
  ▼
Traefik（headlamp.devops.com）
  ▼
oauth2-proxy-headlamp ──OIDC──> GitLab
  │  - 校验 GitLab 登录
  │  - --allowed-group=digitalsupply，不在组内直接 403
  ▼
Headlamp UI
  │  ② 集群授权：你能做什么
  │  弹出 “Headlamp Cluster Authentication”
  │  粘贴 k8s Bearer Token
  ▼
Headlamp backend ──Authorization: Bearer <token>──> kube-apiserver
                                                     └─ RBAC 按 token 身份判定
```

关键点：**oauth2-proxy 的 `X-Forwarded-User` 只是 HTTP 头，不是 k8s 凭据。**
apiserver 不认 HTTP 头，只认 token / 客户端证书。所以 Headlamp 必须拿到一个
apiserver 能验证的 token，才能替用户访问集群。

---

## 三、为什么现在要输入令牌

### 1. 触发变更的参数

`platform-gitops` 仓库 `platform/headlamp/manifests/manifests.yaml`：

```yaml
args:
  - "-in-cluster"
  - "-in-cluster-context-name=main"
  - "-plugins-dir=/headlamp/plugins"
  - "-session-ttl=86400"
  # 已移除 -unsafe-use-service-account-token
```

`-unsafe-use-service-account-token` 的作用：让 Headlamp **直接使用 Pod 里挂载的
`headlamp` SA token** 去调 apiserver。这样所有登录用户共享同一份 K8s 身份，
参数名里的 `unsafe` 就是这个意思。

移除后：

- Headlamp 不再自动使用 SA token；
- 每个请求必须由用户提供 Bearer Token；
- 没有 token 时，请求到 apiserver 的身份是 `system:anonymous`。

实测（port-forward 到 Headlamp，直接看 apiserver 的返回）：

```bash
# 不带 token
curl -s -H 'Accept: application/json' \
  http://127.0.0.1:18084/clusters/main/api/v1/namespaces
```

```json
{
  "kind": "Status",
  "status": "Failure",
  "message": "namespaces is forbidden: User \"system:anonymous\" cannot list resource \"namespaces\" in API group \"\" at the cluster scope",
  "reason": "Forbidden",
  "code": 403
}
```

带上 token 后，身份就变成 token 里的 `sub`：

```json
{
  "iss": "https://kubernetes.default.svc.cluster.local",
  "sub": "system:serviceaccount:headlamp:headlamp-bigdev",
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "kubernetes.io": {
    "namespace": "headlamp",
    "serviceaccount": { "name": "headlamp-bigdev", "uid": "..." }
  }
}
```

### 2. 这个“令牌”不是 OIDC 的 ID Token

这一点最容易混淆：

| | OIDC ID Token | 本文的 k8s Token |
|---|---|---|
| 签发者 | GitLab | kube-apiserver（ServiceAccount token） |
| 用途 | 向应用证明“用户是谁” | 向 apiserver 证明“这个 k8s 身份” |
| 消费者 | oauth2-proxy / Headlamp 前端 | kube-apiserver |
| 能直接调 apiserver | ❌ | ✅ |
| 谁生成 | oauth2-proxy 自动完成 | `kubectl create token` |

两者都是 JWT，所以看起来很像，但 issuer、audience、信任链完全不同。
Headlamp 登录框只写 “token”，指的是**后者**。

### 3. 为什么不用 GitLab 的 ID Token 直接调 apiserver

需要 apiserver 配置 `--oidc-issuer-url` 等参数，而且 issuer 必须是 HTTPS。
本环境：

- GitLab 是 `http://192.168.67.201`（无 TLS）；
- apiserver 没有任何 `--oidc-*` 参数。

所以 GitLab 签发的 token 不会被 apiserver 信任。详见
[14 号文档](14-headlamp-oauth2-proxy-vs-native-oidc-rbac.md) 第 8 节。

---

## 四、常见误解：改 `serviceAccountName` 为 `headlamp-root` 能免 token 吗？

### 1. 结论：不能（仅改 serviceAccountName）

只把 Headlamp Deployment 的 `serviceAccountName` 从 `headlamp` 改成
`headlamp-root`，**不会**让任何 GitLab 用户自动获得全集群权限。
用户仍然必须自己粘贴 token；不粘贴时，请求身份仍是 `system:anonymous`。

### 2. 实测证据

对真实 Headlamp Pod 做对照（该 Pod 挂载的是 `headlamp` SA 的合法 token）：

| 请求方式 | apiserver 认为的身份 | 结果 |
|---|---|---|
| 不粘贴任何 token | `system:anonymous` | **403** |
| 粘贴 `headlamp-root` 的 token | `system:serviceaccount:headlamp:headlamp-root` | 200（全权） |
| 粘贴 `headlamp-bigdev` 的 token | `system:serviceaccount:headlamp:headlamp-bigdev` | namespaces 200 / nodes 403（受限） |

**关键**：不粘贴 token 时身份是 `system:anonymous`，而不是 Pod 挂载的
`headlamp` SA。这证明 **Headlamp 根本没有使用 Pod 挂载的 SA token**，
它只认用户粘贴的 token。

### 3. 原因：没有 `-unsafe-use-service-account-token`

Headlamp 的参数里**没有** `-unsafe-use-service-account-token`，所以它
**不使用** Pod 挂载的 SA token，只使用用户粘贴的 token。

把 `serviceAccountName` 改成 `headlamp-root`，只是让 `headlamp-root` 的
cluster-admin token **被挂载进 Pod 的文件系统**，但 Headlamp **不会拿它
去调 apiserver**。因此：

- 不粘贴 token → 仍是 `system:anonymous` → 403；
- 粘贴自己的 bigdev token → 仍是受限；
- **没有任何人因为“SA 改成了 headlamp-root”而自动获得全权。**

### 4. 什么情况下才会成立

改 `serviceAccountName` 为 `headlamp-root`，**并且**重新加上
`-unsafe-use-service-account-token`：

```yaml
args:
  - "-in-cluster"
  - "-in-cluster-context-name=main"
  - "-plugins-dir=/headlamp/plugins"
  - "-session-ttl=86400"
  - "-unsafe-use-service-account-token"   # ← 加上这个
```

这时 Headlamp 会**直接用 Pod 挂载的 SA token** 调 apiserver。因为 SA 是
`headlamp-root`（绑 cluster-admin），所以**任何能通过 GitLab 登录、打开
Headlamp Web UI 的人，都自动以 `headlamp-root` 身份获得全集群全权限**。

这正是我们当初**刻意移除**的不安全模式——所有登录用户共享同一个高权 SA
身份，`smallops`、`bigdev`、任何人都是集群管理员。手动粘贴 token，就是
为了避免这个共享高权身份的问题。

### 5. 额外风险：高权 token 被挂进 Web 组件

即使不加 `-unsafe-use-service-account-token`，把 `headlamp-root`
（cluster-admin token）挂载进 Headlamp Pod 的**文件系统**，本身也是风险：
一旦该 Pod 被攻破或有人能 `exec` 进去，就能从
`/var/run/secrets/kubernetes.io/serviceaccount/token` 读出全权 token。

**不要把高权 SA 挂给面向多用户的 Web 组件。**

### 6. 反过来看：低权 Pod SA 也不是边界，**签发权限才是**

上面说的是“别把高权 token 挂进 Pod”。另一面同样重要：**把 Headlamp Pod
的 SA 换成低权的 `headlamp`，并不能阻止别人拿到 `headlamp-root` 的权限**。

原因不在 Headlamp，而在**谁能给 `headlamp-root` 签 token**。K8s 1.35 的
`ClusterRole/edit` 就含 `create serviceaccounts/token` 和
`impersonate serviceaccounts`，还能建 Pod 并指定任意 `serviceAccountName`。
本集群的 `cicd/pipeline` 直接绑定了 `edit`，实测三条路径都能拿到
`headlamp-root`：

```bash
# A. 以 pipeline 身份直接给 headlamp-root 签 token
kubectl -n headlamp create token headlamp-root \
  --as=system:serviceaccount:cicd:pipeline

# B. impersonate
kubectl --token="$PIPE_TOKEN" auth can-i get nodes \
  --as=system:serviceaccount:headlamp:headlamp-root   # yes

# C. 建一个 serviceAccountName: headlamp-root 的 Pod（dry-run 通过）
kubectl -n headlamp run evil --image=busybox:1.37 --restart=Never \
  --as=system:serviceaccount:cicd:pipeline \
  --overrides='{"spec":{"serviceAccountName":"headlamp-root"}}' \
  --dry-run=server
```

此外，`headlamp-bigdev` 自己虽不能签 token/impersonate，但它能在 `headlamp`
命名空间建 Pod，同样可以走链路 C。CSI 的两个 SA 也能签 `headlamp-root`
token（`auth can-i` 对它们给假阴性，需实测）。

**所以边界要画在“谁能签发/冒用/承载 SA”上，而不是“Headlamp Pod 用哪个 SA”上。**
修补方向：把 `pipeline` 的 `edit` 降为 `cicd` 命名空间级、用准入策略禁止
Pod 使用 `headlamp-root`/`headlamp-bigdev`、收敛 CSI 的 token 权限。
完整方案见
[18-security/13 第七节](../../18-security/13-rbac-identity-binding-comparison.md#七谁拥有-edit-权限如何提权怎么修)。

---

## 五、当前 GitOps 配置

### 1. Headlamp Deployment

`platform/headlamp/manifests/manifests.yaml` 的关键部分：

```yaml
spec:
  template:
    spec:
      serviceAccountName: headlamp
      containers:
        - name: headlamp
          image: ghcr.io/headlamp-k8s/headlamp:v0.46.0
          args:
            - "-in-cluster"
            - "-in-cluster-context-name=main"
            - "-plugins-dir=/headlamp/plugins"
            - "-session-ttl=86400"
```

没有 `-unsafe-use-service-account-token`，也没有 `-oidc-*`。

### 2. 用户 ServiceAccount 与绑定

`platform/headlamp/manifests/headlamp-user-rbac.yaml`：

```text
ServiceAccount  headlamp/headlamp-root
ServiceAccount  headlamp/headlamp-bigdev

ClusterRoleBinding  headlamp-root-cluster-admin
  subject: ServiceAccount headlamp/headlamp-root
  roleRef: ClusterRole/cluster-admin

ClusterRoleBinding  headlamp-bigdev-limited
  subject: ServiceAccount headlamp/headlamp-bigdev
  roleRef: ClusterRole/headlamp-bigdev
```

> **为什么是 ServiceAccount 而不是 User？**
>
> `kubectl create token` 生成的身份是
> `system:serviceaccount:headlamp:<sa>`，不是 GitLab 用户名，也不是 k8s
> `User`。之前绑定的 `kind: User, name: root` / `name: bigdev` 对 SA token
> **完全不生效**——实测 `kubectl auth can-i --as=root` 是 yes，但用
> `headlamp-root` 的 token 访问仍然 403。这是本轮踩到的第一个坑。

### 3. 收回 `headlamp` SA 的权限

`headlamp` SA 已经不再参与 apiserver 请求，所以它的绑定也一并收回：

- 删除 `ClusterRoleBinding/headlamp-admin`（`ClusterRole/view`）
- 删除 `ClusterRoleBinding/headlamp-cluster-read`
- 删除手工创建的 `ClusterRoleBinding/headlamp-cluster-admin`

现在：

```bash
kubectl auth can-i --list --as=system:serviceaccount:headlamp:headlamp
```

只剩 `system:authenticated` 的基线权限（discovery、basic-user，以及
Tekton 的集群级只读），没有任何业务资源的读写。

> 为什么连只读也不留？因为 `headlamp-cluster-read` 里含 `nodes`，会连带
> 放出 `nodes/proxy`（可直连 kubelet API），对一个已经不再使用的 SA 来说
> 是多余攻击面。

### 4. ArgoCD 管理关系

`platform-headlamp` 应用当前管理的资源：

```text
Namespace/headlamp
ServiceAccount/headlamp
ServiceAccount/headlamp-root
ServiceAccount/headlamp-bigdev
Service/headlamp
Deployment/headlamp
ClusterRole/headlamp-bigdev
ClusterRole/headlamp-cluster-read
ClusterRoleBinding/headlamp-root-cluster-admin
ClusterRoleBinding/headlamp-bigdev-limited
```

> 注意：**本地 `kubectl apply` 会被 ArgoCD 按 GitLab `main` 回滚。**
> 改配置必须提交并 push 到 GitLab，再等自动同步或手动触发。

---

## 六、权限矩阵

### 1. 三账号总览

| 账号 | GitLab 组 | 能打开 Headlamp | 登录用 token | K8s 权限 |
|---|---|---|---|---|
| `root`（leihao） | `digitalsupply` | ✅ | `headlamp-root` | `cluster-admin`（全集群） |
| `bigdev` | `digitalsupply` | ✅ | `headlamp-bigdev` | 只读 + 工作负载读写 |
| `smallops` | `deeptutor` | ❌（oauth2-proxy 403） | 无 | 无 |

### 2. `root`（`headlamp-root` → `cluster-admin`）

全集群、全资源、全动作，包括：

- 创建/删除/修改任意工作负载；
- `exec` 进任意容器；
- 读取任意 Secret 明文；
- 创建/修改 RBAC（可给自己或他人提权）；
- 访问 `nodes/proxy`（直连 kubelet）；
- `impersonate` 其他身份。

### 3. `bigdev` 能做什么

| 类别 | 具体动作 |
|---|---|
| 集群级只读 | namespaces、pods、services、configmaps、secrets（**只读**）、events、PV/PVC、storageclasses、serviceaccounts、endpoints、resourcequotas、limitranges |
| 工作负载只读 | deployments、daemonsets、statefulsets、replicasets |
| 其他只读 | CRD、`metrics.k8s.io`（nodes/pods）、ingresses |
| 日志 | `pods/log` get |
| 工作负载写 | pods、services、configmaps、deployments 的 `create/delete/update/patch`（**所有命名空间**） |

### 4. `bigdev` 不能做什么

| 动作 | 结果 | 原因 |
|---|---|---|
| `exec` / `attach` / `port-forward` 进容器 | ❌ | 未授 `pods/exec` 等子资源 |
| 写 Secret | ❌ | 只授了 get/list/watch |
| 创建/修改 RBAC | ❌ | 未授 roles / clusterroles / bindings 写 |
| 看 Nodes | ❌ | 未授 `nodes` |
| `nodes/proxy` | ❌ | 未授 `nodes`，避免子资源被带出 |
| `impersonate` | ❌ | 未授 |
| 创建/删除 Namespace | ❌ | 只授了 get/list/watch |
| 写 statefulsets / daemonsets / jobs / cronjobs | ❌ | 只读或未授 |

### 5. 实测结果

`kubectl auth can-i --as=system:serviceaccount:headlamp:<sa>`：

| 动作 | headlamp-root | headlamp-bigdev |
|---|---|---|
| `list namespaces` | ✅ | ✅ |
| `list pods` | ✅ | ✅ |
| `create pods` | ✅ | ✅ |
| `delete deployments` | ✅ | ✅ |
| `get secrets` | ✅ | ✅ |
| `create clusterrolebindings` | ✅ | ❌ |
| `exec pods` | ✅ | ❌ |
| `get nodes` | ✅ | ❌ |
| `get nodes/proxy` | ✅ | ❌ |
| `impersonate users` | ✅ | ❌ |

通过 Headlamp 的 HTTP 代理实测（`/clusters/main/...`）：

| 请求 | headlamp-root | headlamp-bigdev |
|---|---|---|
| `GET /api/v1/namespaces` | 200 | 200 |
| `GET /api/v1/nodes` | 200 | **403** |
| `GET /api/v1/secrets` | 200 | 200 |
| `POST configmap`（default） | — | **201** |
| `DELETE configmap`（default） | — | **200** |
| `POST namespace` | — | **403** |
| `POST pod/exec` | — | **403** |
| 不带 token | **403 `system:anonymous`** | **403 `system:anonymous`** |

---

## 七、获取令牌的完整步骤

### 1. 前提

- 需要一份**能创建 ServiceAccount token 的 kubeconfig**。
  这通常是管理员（`root` kubeconfig）；`bigdev` / `smallops` 没有集群
  kubeconfig，拿不到这个权限。
- 目标 SA 已由 ArgoCD 创建（`platform-headlamp` 已 Synced）。

### 2. 确认 SA 存在

```bash
kubectl -n headlamp get serviceaccount headlamp-root headlamp-bigdev
```

预期：

```text
NAME             SECRETS   AGE
headlamp-root    0         1h
headlamp-bigdev  0         1h
```

### 3. 签发 token

```bash
# root（leihao）：全集群权限
kubectl -n headlamp create token headlamp-root --duration=24h

# bigdev：受限权限
kubectl -n headlamp create token headlamp-bigdev --duration=24h
```

输出是一整行 JWT，形如：

```text
eyJhbGciOiJSUzI1NiIsImtpZCI6Ii4uLiJ9.eyJhdWQiOlsiaHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjLmNsdXN0ZXIubG9jYWwiXSwiZXhwIjoxNzk1NTc2ODM0LCJpYXQiOjE3OTU1NzYyMzQsImlzcyI6Imh0dHBzOi8va3ViZXJuZXRlcy5kZWZhdWx0LnN2Yy5jbHVzdGVyLmxvY2FsIiwia3ViZXJuZXRlcy5pbyI6eyJuYW1lc3BhY2UiOiJoZWFkbGFtcCIsInNlcnZpY2VhY2NvdW50Ijp7Im5hbWUiOiJoZWFkbGFtcC1iaWdkZXYiLCJ1aWQiOiIuLi4ifX0sIm5iZiI6MTc5NTU3NjIzNCwic3ViIjoic3lzdGVtOnNlcnZpY2VhY2NvdW50OmhlYWRsYW1wOmhlYWRsYW1wLWJpZ2RldiJ9...
```

### 4. 在浏览器里登录

1. 打开 `https://headlamp.devops.com`；
2. 先走 GitLab 登录（必须是 `digitalsupply` 组，否则 403）；
3. Headlamp 显示 **“Headlamp Cluster Authentication”**；
4. 把整行 JWT 粘贴进去，点 **Authenticate**；
5. 进入集群视图。

> token 会被 Headlamp 存在浏览器 cookie 里，受 `-session-ttl=86400`
> 控制；但 token 本身的有效期由 `--duration` 决定，两者独立。

### 5. 验证拿到的是哪个身份

```bash
# 解出 JWT 的 sub
kubectl -n headlamp create token headlamp-bigdev --duration=10m \
  | cut -d. -f2 \
  | tr '_-' '/+' \
  | base64 -d 2>/dev/null \
  | python3 -m json.tool | grep '"sub"'
```

预期：

```json
"sub": "system:serviceaccount:headlamp:headlamp-bigdev",
```

也可以直接用 RBAC 验证：

```bash
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-bigdev \
  create clusterrolebindings
# no
```

### 6. 用脚本一键完成

仓库里提供了两个脚本（见
[scripts/headlamp-rbac](../scripts/headlamp-rbac/)）：

```bash
cd docs/13-sso-oidc/scripts/headlamp-rbac

# 签发（第一个参数：root | bigdev；第二个参数：有效期，默认 24h）
./get-token.sh bigdev 24h

# 验证两个 SA 的权限边界
./verify-rbac.sh
```

### 7. 有效期与续期

- `kubectl create token` 默认 **1 小时**，最小 **10 分钟**；
- `--duration=24h` 实测可用；
- token 过期后，Headlamp 里的请求会变成 401/403，重新签发再粘贴即可；
- 建议 8h～24h，不要签发超长期 token。

### 8. 吊销

- 单个 bound token 是**无状态 JWT，不能单独吊销**；
- 删除 SA 会让该 SA 的**所有 token 立即失效**：

```bash
kubectl -n headlamp delete serviceaccount headlamp-bigdev
```

- ArgoCD 会从 Git 恢复 SA 和绑定，再重新签发新 token 即可；
- 如果怀疑泄漏，优先删 SA，而不是只换 token。

---

## 八、常见问题 / 踩坑

1. **403 `system:anonymous`**
   没有粘贴 token，或请求没带上 `Authorization` 头。

2. **403 `system:serviceaccount:headlamp:xxx`**
   token 有效，但 RBAC 没绑定，或绑错了主体。

3. **`auth can-i --as=root` 是 yes，token 登录还是 403**
   `User` 绑定对 SA token 不生效。token 身份是
   `system:serviceaccount:headlamp:<sa>`，必须绑 ServiceAccount。

4. **本地 `kubectl apply` 后几分钟又变回去**
   ArgoCD 按 GitLab `main` 回滚了。先 push，再同步。

5. **给了 `get nodes`，`get nodes/proxy` 也跟着变 yes**
   RBAC 没有“减法”，子资源会被父资源规则带出。只能去掉 `nodes`。

6. **`--duration=5m` 报错**
   bound token 最短 10 分钟：
   `spec.expirationSeconds: Invalid value: 300: may not specify a duration less than 10 minutes`。

7. **粘贴后仍 401**
   多半是复制时带了换行/空格，或复制了多行输出。确认是**一整行**。

8. **用 `headlamp` SA 的 token 登录**
   现在这个 SA 已经没有业务权限（以前是 `cluster-admin`）。请用
   `headlamp-root` / `headlamp-bigdev`。

9. **把 `-unsafe-use-service-account-token` 加回去**
   所有登录用户又会共享 SA 身份，per-user RBAC 失效。不要加。

10. **换浏览器/无痕窗口要重新粘贴**
    token 存在 cookie 里，换会话就没了。

11. **`kubectl --token` 被客户端证书覆盖，查不到 SA 真实权限**
    在带**客户端证书**的 kubeconfig 下，用 `kubectl --token=<SA token>`
    来“扮演” SA 是**无效**的：客户端证书的身份会**覆盖** token，实际查的
    仍是管理员权限，会误判。

    ```bash
    # 错误做法：被客户端证书覆盖，仍显示管理员权限
    kubectl --token="$TOKEN" auth can-i '*' '*'          # yes（错误）
    # 正确做法：用 --as 明确模拟 SA 身份
    kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-root '*' '*'
    ```

    **模拟 SA 身份用 `--as`；要真实验证就用挂载该 SA 的 Pod 调 apiserver。**

---

## 九、安全注意事项

1. **token 等同于密码**
   不要提交到 Git、不要贴到聊天/文档、不要放进工单。文档里的 token
   一律是占位符。

2. **`bigdev` 能读全集群 Secret（只读）**
   包括数据库密码、OAuth client secret、其他 SA token。不能接受的话，
   把 `headlamp-bigdev` 规则里的 `secrets` 一行删掉——代价是 Secret
   页面 403，其他功能不受影响。

3. **`bigdev` 能在所有命名空间创建 Pod（最大残留风险）**
   包括 `kube-system`。如果集群没有限制 `privileged` / `hostPath` /
   `hostNetwork`，用户可以创建一个挂载宿主机根目录的 Pod，拿到节点
   root，再横向拿到集群管理员。**更直接的路径**是建一个
   `serviceAccountName: headlamp-root` 的 Pod，Pod 内直接就是
   cluster-admin（实测 server dry-run 通过，见第四节第 6 小节）。
   **这已经超出“只读 + 工作负载读写”的本意。** 建议至少做一项：
   - 把写权限从 `ClusterRole` 改成指定命名空间的 `RoleBinding`；
   - 用准入策略（ValidatingAdmissionPolicy/Kyverno）禁止 Pod 使用
     `headlamp-root`/`headlamp-bigdev` 这类 access-only SA；
   - 上 Pod Security Admission `restricted`，禁止 `privileged`、`hostPath`、
     `hostNetwork`；
   - 只给 Deployment 的 `patch`（重启/扩缩容），不给 Pod `create`。

4. **审计粒度只到 SA，不到人**
   apiserver 审计日志里只有
   `system:serviceaccount:headlamp:headlamp-bigdev`，看不到 GitLab 用户。
   多人共用一个 token 时无法区分到人。需要按人审计就一人一 SA。

5. **oauth2-proxy 的组门禁仍是第一道闸**
   `smallops`（`deeptutor`）在认证层就 403，连 token 输入框都看不到。
   但不要只依赖这一层——SA 的 RBAC 才是最终边界。

6. **保留 break-glass**
   本地 kubeconfig / cluster-admin 证书要留一份，避免 Headlamp 或
   GitLab 故障时无法管理集群。

---

## 十、验证记录（2026-11-25）

```bash
# 1. 部署参数：不应再有 unsafe 参数
kubectl -n headlamp get deploy headlamp \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
# ["-in-cluster","-in-cluster-context-name=main",
#  "-plugins-dir=/headlamp/plugins","-session-ttl=86400"]

# 2. 绑定主体：应为 ServiceAccount
kubectl get clusterrolebinding headlamp-root-cluster-admin headlamp-bigdev-limited \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.roleRef.name}{" "}{.subjects[0].kind}/{.subjects[0].name}{"\n"}{end}'
# headlamp-root-cluster-admin -> cluster-admin ServiceAccount/headlamp-root
# headlamp-bigdev-limited -> headlamp-bigdev ServiceAccount/headlamp-bigdev

# 3. headlamp SA 已无业务权限
kubectl auth can-i --list --as=system:serviceaccount:headlamp:headlamp | head

# 4. ArgoCD 托管资源
kubectl -n argocd get app platform-headlamp \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{"\n"}{end}' | sort
```

实测结论：

- `headlamp-root`：读、写、`exec`、RBAC、`nodes/proxy`、`impersonate` 全部 yes；
- `headlamp-bigdev`：读和工作负载写 yes；`exec`、RBAC 写、`nodes`、
  `nodes/proxy`、`impersonate` 全部 no；
- 不带 token：`system:anonymous`，403；
- `headlamp` SA：无业务资源权限。

---

## 十一、与原生 OIDC 的关系 / 后续

当前是 **“oauth2-proxy 认证 + 手动粘贴 k8s token”**，不是真正的
“用户 OIDC 身份直通 K8s RBAC”。

要免粘贴、做到真正的 per-user 身份，需要三件事同时成立：

1. Headlamp 开启原生 OIDC（`-oidc-*`）；
2. apiserver 配置 `--oidc-issuer-url` 等参数，信任同一个 issuer；
3. issuer 必须是 **HTTPS**。

本环境的阻塞点：

- GitLab 是 `http://192.168.67.201`，没有 TLS；
- apiserver 当前没有任何 `--oidc-*` 参数；
- 改控制面需要维护窗口和回滚预案。

可行路径：用已经部署的 Keycloak 做 HTTPS issuer（前面加 TLS），
apiserver 配 `--oidc-issuer-url=https://<keycloak>`，Headlamp 开 `-oidc-*`，
RBAC 绑 `User`/`Group`。在此之前，当前方案是可用折中：

- 认证统一到 GitLab；
- 授权按 SA 分离；
- 代价是每个会话要粘贴一次 token。

---

## 十二、变更清单

`platform-gitops`：

| 提交 | 内容 |
|---|---|
| `e3351a4` | 新增 `headlamp-root` / `headlamp-bigdev` SA，绑定改为 ServiceAccount 主体 |
| `32fde2f` | 收回 `headlamp` SA 的 `view` / `headlamp-cluster-read` 绑定 |

`k8s-platform-tutorials`：

| 文件 | 内容 |
|---|---|
| `docs/13-sso-oidc/notes/17-headlamp-token-login-per-user-rbac.md` | 本文 |
| `docs/13-sso-oidc/scripts/headlamp-rbac/get-token.sh` | 签发 token |
| `docs/13-sso-oidc/scripts/headlamp-rbac/verify-rbac.sh` | 验证权限边界 |
