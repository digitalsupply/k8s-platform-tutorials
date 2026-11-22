# OIDC 身份与权限映射 · Traefik ForwardAuth 分析（实测）

> 面向：需要理解各业务 dashboard 通过 GitLab OIDC 登录后的实际身份和权限、
> 以及 Traefik 认证链路的人
> 环境：GitLab CE 19.5.0（`192.168.67.201`），Traefik v3.7.17，oauth2-proxy v7.15.6
> 性质：对 [13 章 README](../README.md) 和 [08 号文档](08-gitlab-oauth-apps-oauth2-proxy.md) 的补充，
> 实测时间 2026-11-22。

---

## 一、GitLab OAuth2 身份：root

所有纳入 OIDC/SSO 的业务，实际走 GitLab OAuth2 授权登录的账号都是 **root**
（GitLab 上的 root 账号，显示名 "lei hao"，不是 harbor 主机的 `hao` SSH 用户）。

**GitLab 侧证据**：`Doorkeeper::AccessToken` 的 `resource_owner_id` 全部为 1（root），
已签发的所有 OAuth token 均归属 root，没有任何一条属于 GitLabDuo。

**root 在 GitLab 的完整身份**：

| 属性 | 值 |
|---|---|
| username | root |
| name | lei hao |
| email | `gitlab_admin_526ef4@example.com` |
| admin | true（GitLab 超级管理员） |
| 所属组 | digitalsupply（**Owner**，access_level=50）、deeptutor（**Owner**，access_level=50） |

> **注意**：GitLab 的 admin 权限只在 GitLab 自身生效。各业务 dashboard 的权限由各自的
> RBAC 独立决定，互不影响。

---

## 二、各业务 dashboard 的登录用户与权限

### 1. Grafana（`grafana.k8s.local`）

| 项 | 值 |
|---|---|
| 登录用户 | root（nickname=root） |
| 权限 | **GrafanaAdmin**（最高权限） |
| 映射机制 | `role_attribute_path` 表达式 |

Grafana 的角色映射配置（`prometheus-grafana` ConfigMap 的 `grafana.ini`）：
```
role_attribute_path = contains(['root'], nickname) && 'GrafanaAdmin'
|| contains(groups[*], 'digitalsupply') && 'GrafanaAdmin'
|| 'Viewer'
```

root 的 nickname 是 `root`，命中第一个条件 → **GrafanaAdmin**。
即使不命中 nickname，root 在 `digitalsupply` 组，也会命中第二个条件 → GrafanaAdmin。

**GrafanaAdmin 权限**：管理用户、组织、数据源、仪表盘、管理员设置等全部功能。

### 2. ArgoCD（`argocd.devops.com`）

| 项 | 值 |
|---|---|
| 登录用户 | root |
| 权限 | **role:admin**（管理员） |
| 映射机制 | `policy.csv` + `scopes: [groups, email]` |

ArgoCD RBAC 配置（`argocd-rbac-cm` ConfigMap）：
```csv
policy.csv:
g, digitalsupply, role:admin
g, gitlab_admin_526ef4@example.com, role:admin

policy.default: role:readonly
scopes: [groups, email]
```

root 命中**两条规则**：
- email = `gitlab_admin_526ef4@example.com` → 匹配第二条 → **role:admin**
- groups 含 `digitalsupply` → 匹配第一条 → **role:admin**

**role:admin 权限**：管理应用同步、项目、仓库、设置、RBAC 等。

### 3. Harbor（`192.168.67.202:8443`）

| 项 | 值 |
|---|---|
| 登录用户 | root（preferred_username=root） |
| 权限 | **Harbor 系统管理员** |
| 映射机制 | `oidc_admin_group=digitalsupply` |

Harbor OIDC 配置（Harbor DB/API）：
```
oidc_user_claim = preferred_username
oidc_groups_claim = groups
oidc_admin_group = digitalsupply
oidc_auto_onboard = true
```

root 在 `digitalsupply` 组 → 命中 `oidc_admin_group` → **Harbor 系统管理员**
（首次登录自动 onboard 并授予管理员）。

**Harbor 管理员权限**：管理项目、用户、机器人账号、复制策略、扫描配置、系统设置等。

### 4. oauth2-proxy 反代的 5 个 UI

| 项 | 值 |
|---|---|
| 登录用户 | root（通过 oauth2-proxy 认证后透传给后端） |
| 权限 | **认证通过后全访问**（无细粒度 RBAC） |
| 映射机制 | oauth2-proxy 只做认证，不做授权 |

5 个 UI 的 oauth2-proxy 配置一致：
```
--oidc-groups-claim=groups
--set-xauthrequest=true    # 透传用户信息到后端 HTTP 头
--reverse-proxy=true
--skip-provider-button=true
```

**关键区别**：oauth2-proxy 只负责**认证**（验证登录、管理会话），**不做授权**
（不检查 groups 做权限细分）。各后端 UI 本身没有基于 OIDC 的 RBAC：

| UI | 域名 | 登录后权限 |
|---|---|---|
| Headlamp | `headlamp.devops.com` | K8s 集群管理前端，登录后全访问（实际 RBAC 取决于 kubeconfig/K8s RBAC 绑定） |
| Hubble UI | `hubble.xyz` | Cilium 可观测性 UI，登录后全访问 |
| Tekton Dashboard | `tekton.xyz` | CI/CD 仪表盘，登录后全访问 |
| Alloy UI | `alloy.xyz` | 日志查看 UI，登录后全访问 |
| Traefik Dashboard | `traefik.xyz` | 反向代理管理，登录后全访问 |

### 5. 权限汇总

| 业务 | 登录用户 | 权限 | 授权机制 |
|---|---|---|---|
| Grafana | root | **GrafanaAdmin** | role_attribute_path 表达式 |
| ArgoCD | root | **role:admin** | policy.csv（groups + email） |
| Harbor | root | **系统管理员** | oidc_admin_group |
| Headlamp | root | 全访问（无细粒度 RBAC） | oauth2-proxy 只认证 |
| Hubble UI | root | 全访问（无细粒度 RBAC） | oauth2-proxy 只认证 |
| Tekton Dashboard | root | 全访问（无细粒度 RBAC） | oauth2-proxy 只认证 |
| Alloy UI | root | 全访问（无细粒度 RBAC） | oauth2-proxy 只认证 |
| Traefik Dashboard | root | 全访问（无细粒度 RBAC） | oauth2-proxy 只认证 |

**关键结论**：

1. 所有业务都用同一个 GitLab 身份 root 登录，权限由各业务自己的 RBAC 独立决定。
2. root 在各业务都是高权限，因为：root 是 GitLab 超级管理员 + 在 `digitalsupply` 组是 Owner
   + 各业务 RBAC 都配置了 `digitalsupply` 组 → 管理员。
3. 三个原生 OIDC 业务（Grafana/ArgoCD/Harbor）有细粒度 RBAC，基于 groups/email/nickname 映射角色。
   五个 oauth2-proxy 业务只有认证没有授权，登录即全访问。
4. **权限放大风险**：`digitalsupply` 组成员在三个原生 OIDC 业务中都是管理员，
   组里加临时成员会直接放大权限到 GrafanaAdmin / ArgoCD admin / Harbor 管理员。

---

## 三、Traefik ForwardAuth 详解

### 1. ForwardAuth 是什么

**ForwardAuth 是 Traefik 的一种中间件（Middleware）类型**，作用是在请求转发到后端之前，
先向认证服务发一个子请求做校验：

```
浏览器 → Traefik → [ForwardAuth middleware] → 认证服务(oauth2-proxy) → 后端
                        ↑
                   先"问"认证服务
```

- 认证服务返回 **2xx** → Traefik 放行，转发给后端
- 认证服务返回 **401/403** → Traefik 拦截，返回认证服务指定的重定向（跳转登录页）

### 2. 与 ReverseProxy 模式的区别

| 模式 | 流量路径 | 认证服务角色 | oauth2-proxy 参数 |
|---|---|---|---|
| **ForwardAuth** | 浏览器 → Traefik → 后端（认证服务只做校验，不代理流量） | 旁路校验 | `--forward-auth` |
| **ReverseProxy** | 浏览器 → Traefik → oauth2-proxy → 后端（oauth2-proxy 先认证再代理） | 代理 + 认证 | `--reverse-proxy=true` |

oauth2-proxy 两种模式都支持。本平台 5 个 UI 全部使用 **ReverseProxy 模式**。

### 3. 历史教训

本平台最初试了 ForwardAuth，但 oauth2-proxy 未登录时返回 **401 + Location**，
Traefik 的 ForwardAuth 中间件无法正确处理跳转，最终改成 **反向代理**：

```
浏览器 -> Traefik -> oauth2-proxy-<host> -> 后端 UI
                         └── GitLab OIDC
```

---

## 四、Headlamp 访问路径分析

**访问 Headlamp Dashboard 不需要经过 ForwardAuth Middleware。**
Headlamp 使用 **ReverseProxy 模式**，不经过任何 ForwardAuth Middleware。

从 headlamp 的 IngressRoute 配置可以直接确认（`headlamp` 命名空间，websecure/443 入口）：

```yaml
spec:
  entryPoints:
  - websecure
  routes:
  - kind: Rule
    match: Host(`headlamp.devops.com`)
    services:
    - name: oauth2-proxy-headlamp    # 直接指向 oauth2-proxy
      namespace: oauth2-proxy
      port: 4180
  # 注意：没有 middlewares 字段！
```

**完整访问路径**：

```
浏览器 → https://headlamp.devops.com
  → Traefik websecure 入口
  → （无任何 middleware）
  → oauth2-proxy-headlamp:4180（ReverseProxy 模式，OIDC 认证）
  → headlamp.headlamp.svc:80（后端 UI）
```

oauth2-proxy 配置了 `--reverse-proxy=true`，自己处理认证和代理，
Traefik 只负责把请求交给它。

**HTTP（80）入口**的 `headlamp-http-redirect` IngressRoute 引用了
`headlamp-https-redirect` middleware，但**只是做 HTTP→HTTPS 跳转**，不是认证。

---

## 五、本集群 Traefik middleware 清单

本集群 Traefik **有 16 个 middleware**，按类型分类：

| 类型 | 数量 | middleware |
|---|---|---|
| **HTTPS 跳转**（redirectScheme） | 8 | argocd/redirect-to-https、headlamp/headlamp-https-redirect、kube-system/hubble-https-redirect、logging/alloy-https-redirect、monitoring/redirect-to-https、tekton-pipelines/tekton-dashboard-https、traefik/traefik-https-redirect |
| **BasicAuth**（basicAuth） | 3 | kube-system/hubble-ui-auth、logging/alloy-ui-auth、tekton-pipelines/tekton-dashboard-auth |
| **转发头**（headers） | 2 | argocd/argocd-forwarded-headers、tekton-pipelines/tekton-dashboard-strip-auth |
| **路径重写**（replacePathRegex/redirectRegex） | 2 | china-study-free/china-study-free-admin-root、traefik/traefik-root-redirect |
| **IP 允许**（ipAllowList） | 1 | china-study-free/china-study-free-admin-allow |

### 关键结论

1. **没有 ForwardAuth 类型的 middleware**。本集群所有 oauth2-proxy 认证的 UI
   （headlamp、hubble、alloy、tekton、traefik）都使用 **ReverseProxy 模式**，不使用 ForwardAuth。

2. **3 个 BasicAuth middleware 是遗留配置**：`hubble-ui-auth`、`alloy-ui-auth`、
   `tekton-dashboard-auth` 这三个 basicAuth middleware **未被任何 IngressRoute 引用**，
   是切换到 oauth2-proxy 之前的旧配置，已经失效但没清理。

3. **HTTPS 跳转 middleware** 是唯一在生效的认证相关 middleware，但只做 80→443 跳转，
   不涉及用户认证。

4. 5 个 oauth2-proxy 认证的 UI，其 websecure 入口 IngressRoute **均未引用任何 middleware**，
   直接指向 oauth2-proxy Service。

---

## 六、验证命令

```bash
# === GitLab root 用户身份 ===
gitlab-rails runner 'puts User.where(id: 1).pluck(:id, :username, :name, :email, :admin, :state).inspect'
gitlab-rails runner 'puts Member.where(user_id: 1).map { |x| [x.source_type, x.source_id, x.access_level] }.inspect'
gitlab-rails runner 'puts Doorkeeper::AccessToken.pluck(:resource_owner_id).inspect'

# === Grafana 角色映射 ===
kubectl -n monitoring get cm prometheus-grafana -o jsonpath='{.data.grafana\.ini}' | grep role_attribute

# === ArgoCD RBAC ===
kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data}'

# === Harbor OIDC 配置 ===
curl -sk -H "Authorization: Basic YWRtaW46SGFyYm9yMTIzNDU=" \
  https://192.168.67.202:8443/api/v2.0/configurations

# === oauth2-proxy 模式确认 ===
kubectl -n oauth2-proxy get deploy oauth2-proxy-headlamp \
  -o jsonpath='{.spec.template.spec.containers[0].args}'

# === Headlamp IngressRoute（确认无 middleware）==
kubectl -n headlamp get ingressroute headlamp -o yaml

# === Traefik middleware 清单 ===
kubectl get middleware -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec}{"\n"}{end}'

# === 检查 BasicAuth middleware 是否被引用 ===
kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.routes[*].middlewares[*].name}{"\n"}{end}'
```
