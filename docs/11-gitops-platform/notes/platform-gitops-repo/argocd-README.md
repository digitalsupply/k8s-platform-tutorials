# ArgoCD 配置（bootstrap 例外）

> **状态：已作废（Keycloak 时代的 SSO 方案）**
> 这套设计没有落地：平台最终用 **GitLab CE 作为 OIDC IdP**（Grafana/ArgoCD/Harbor 原生 OIDC，
> Traefik/Hubble/Alloy/Tekton 走 oauth2-proxy）。本文里的 `sso.k8s.local`、Keycloak realm、SAML 流程**都不是当前配置**。
> 当前方案见 [13 章 README](../../../13-sso-oidc/README.md)。



ArgoCD 是平台的 bootstrap 组件，由 Helm release `argocd` 安装，**不能由 ArgoCD
自己同步自己的配置**。因此本目录的 `values.yaml` 是声明式 source of truth，
变更通过 `helm upgrade` 应用。

## 文件

| 文件 | 作用 |
|---|---|
| `values.yaml` | OIDC 与 RBAC 配置 |
| `sealedsecret-argocd-oauth.yaml` | GitLab OAuth client secret（SealedSecret） |

## 首次 / 变更应用

```bash
helm repo add argo https://argoproj.github.io/argo-helm   # 首次
helm repo update argo

kubectl apply -f platform/argocd/sealedsecret-argocd-oauth.yaml

helm -n argocd upgrade argocd argo/argo-cd \
  --version 10.9.6 \
  -f platform/argocd/values.yaml \
  --reuse-values \
  --wait --timeout 4m
```

## 验证

```bash
kubectl -n argocd get cm argocd-cm -o yaml | grep -A12 "oidc.config"
kubectl -n argocd get cm argocd-rbac-cm -o yaml | sed -n '/^data:/,/^kind:/p'

curl -sk --resolve argocd.devops.com:443:10.0.0.252 \
  -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://argocd.devops.com/auth/login
```

预期 `303` 跳转到 GitLab `/oauth/authorize`。

## 权限模型

- 所有 OIDC 登录用户默认 `role:readonly`；
- `digitalsupply` 组和 GitLab root 邮箱为 `role:admin`；
- 本地 `admin` 仍启用，作为 break-glass；`argocd-initial-admin-secret` 中的
  初始密码可能已被修改。

## 注意

- GitLab 目前是 HTTP，`issuer` 为 `http://192.168.67.201`，没有 TLS；
- 修改 `values.yaml` 后必须执行上面的 `helm upgrade`，ArgoCD 不会自动同步；
- client secret 轮换见 `platform/sso/PHASE2-ARGOCD-HARBOR-CEPH.md`。

## 关键坑

### client secret 的 Secret 必须带 ArgoCD 标签

`oidc.config` 里的 `$argocd-oauth:client-secret` 只会从带有
`app.kubernetes.io/part-of: argocd` 标签的 Secret 中解析。缺这个标签时，
ArgoCD 会把整个字符串 `$argocd-oauth:client-secret` 当作密码发给 GitLab，
表现为：

```text
failed to get token: oauth2: "invalid_client"
```

修复：在 SealedSecret 的 `template.metadata.labels` 加上：

```yaml
labels:
  app.kubernetes.io/part-of: argocd
```

### `data length is less than nonce size`

这是 ArgoCD OIDC state cookie 的旧 cookie/路径问题，不是 client secret 错误。
清除浏览器里 `argocd.devops.com` 的 cookie（尤其是 `argocd.oauthstate`、
`argocd.token`），或直接访问：

```text
https://argocd.devops.com/login?return_url=https%3A%2F%2Fargocd.devops.com%2Fapplications
```

然后重新走一次登录即可。

