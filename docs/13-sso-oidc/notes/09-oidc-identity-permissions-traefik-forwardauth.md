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

**两者都能保护后端**，区别在于**认证决策由谁执行、认证服务在流量路径中的位置**。

**流量路径对比**：

**ReverseProxy 模式**（oauth2-proxy 在路径中，做代理+认证）：
```
浏览器 ──请求──> Traefik ──> oauth2-proxy ──认证通过──> 后端 svc
                         (未认证则拦截，不转发)
```

**ForwardAuth 模式**（oauth2-proxy 在路径外，只做旁路校验）：
```
浏览器 ──请求──> Traefik ──[先问 oauth2-proxy]──> 校验通过 ──> 后端 svc
                          ↑                    (未通过则拦截)
                     子请求（非主流量）
```

**保护能力对比**：

| 维度 | ReverseProxy | ForwardAuth |
|---|---|---|
| **未认证请求** | oauth2-proxy 直接拦截，不到达后端 | Traefik 拦截，不到达后端 |
| **认证决策者** | oauth2-proxy（自己判断） | Traefik（根据 oauth2-proxy 返回值判断） |
| **后端感知** | 后端完全不感知认证，只收到已认证的请求 | 后端也不感知，收到 Traefik 转发的请求 |
| **认证服务位置** | 在流量路径中（代理流量） | 在流量路径外（旁路校验） |
| **跳转登录页** | oauth2-proxy 自己处理，返回 302 给浏览器 | Traefik 需把 401+Location 转成 302 给浏览器 |
| **用户信息透传** | oauth2-proxy 透传 X-Auth-Request 头给后端 | Traefik 可透传头，但需额外配置 |

**核心区别**：两者都能保护后端，但 **ReverseProxy 的认证逻辑封装在 oauth2-proxy 内部**，
跳转、会话管理都由 oauth2-proxy 完成；**ForwardAuth 把认证决策交给 Traefik**，
oauth2-proxy 只提供"放行/拦截"的校验结果。

oauth2-proxy 两种模式都支持。本平台 5 个 UI 全部使用 **ReverseProxy 模式**。

### 3. 本集群为何用 ReverseProxy

**直接原因**：ForwardAuth 模式下，oauth2-proxy 未登录时返回 `401 + Location`
（Location 头指向登录页），但 **Traefik 的 ForwardAuth middleware 无法正确处理
这个 401+Location 组合**，导致跳转登录页不工作——用户未登录时看不到登录页，
直接被拦截。

**ReverseProxy 模式下不存在这个问题**：oauth2-proxy 自己处理整个认证流程，
包括未登录时的 302 跳转登录页，Traefik 只负责把请求交给它，不需要关心认证逻辑。

**对比总结**：

| 问题 | ForwardAuth | ReverseProxy |
|---|---|---|
| 未登录跳转 | Traefik 处理 401+Location，**容易出问题** | oauth2-proxy 直接返回 302，**可靠** |
| 认证流程 | 分散在 Traefik + oauth2-proxy 两处 | 集中在 oauth2-proxy，**简单** |
| 配置复杂度 | 需配置 ForwardAuth middleware + 认证端点 | Traefik 只需指向 oauth2-proxy Service，**简单** |

**结论**：ReverseProxy 模式把认证逻辑收敛在 oauth2-proxy 内部，Traefik 只做"转发"
这一件事，配置更简单、跳转更可靠。本集群 5 个 UI 全部采用此模式。

**流量路径**：

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

## 五、Traefik Middleware 详解

### 1. Middleware 是什么

**Middleware 是 Traefik 的请求处理中间件**，作用于请求从**入口点（entrypoint）到后端服务
（service）**之间的路径上，可以对请求进行**修改、校验、拦截、重定向**等操作。

在 IngressRoute 中，middleware 通过 `middlewares` 字段引用，作用顺序为：
**入口点 → middleware → service**。

```
请求 → 入口点(web/websecure) → [middleware 链] → 后端 Service
```

### 2. Middleware 的作用

| 作用类型 | 说明 | 示例 |
|---|---|---|
| **拦截/重定向** | 不满足条件的请求直接拦截或跳转 | HTTPS 跳转、IP 白名单 |
| **认证** | 验证请求者身份 | BasicAuth、ForwardAuth |
| **修改请求** | 添加/删除/修改请求头或路径 | 添加 X-Forwarded-Proto、重写路径 |
| **限流** | 限制请求频率 | RateLimit（本集群未用） |

### 3. 如何查看

```bash
# 列出所有 middleware
kubectl get middleware -A

# 查看某个 middleware 的详细配置（含类型和参数）
kubectl get middleware <namespace>/<name> -o yaml

# 查看哪些 IngressRoute 引用了哪些 middleware
kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.routes[*].middlewares[*].name}{"\n"}{end}'
```

### 4. 常见类型

| 类型 | spec 字段 | 作用 |
|---|---|---|
| **HTTPS 跳转** | `redirectScheme` | HTTP → HTTPS 永久/临时跳转 |
| **BasicAuth** | `basicAuth` | htpasswd 基础认证 |
| **ForwardAuth** | `forwardAuth` | 转发前向认证服务校验 |
| **Headers** | `headers` | 修改请求头 |
| **IPAllow** | `ipAllowList` | IP 白名单 |
| **路径重写** | `replacePathRegex` / `redirectRegex` | 路径重写/跳转 |

### 5. 本集群 middleware 清单

本集群 Traefik **有 16 个 middleware**，按类型分为 5 类：

| 类型 | 数量 | middleware |
|---|---|---|
| **HTTPS 跳转**（redirectScheme） | 8 | argocd/redirect-to-https、headlamp/headlamp-https-redirect、kube-system/hubble-https-redirect、logging/alloy-https-redirect、monitoring/redirect-to-https、tekton-pipelines/tekton-dashboard-https、traefik/traefik-https-redirect |
| **BasicAuth**（basicAuth） | 3 | kube-system/hubble-ui-auth、logging/alloy-ui-auth、tekton-pipelines/tekton-dashboard-auth |
| **转发头**（headers） | 2 | argocd/argocd-forwarded-headers、tekton-pipelines/tekton-dashboard-strip-auth |
| **路径重写**（replacePathRegex/redirectRegex） | 2 | china-study-free/china-study-free-admin-root、traefik/traefik-root-redirect |
| **IP 允许**（ipAllowList） | 1 | china-study-free/china-study-free-admin-allow |

### 6. 各类 middleware 详解

#### （1）HTTPS 跳转类（8 个）— 最常用

**作用**：HTTP（80 入口）→ HTTPS（443 入口）永久跳转（301）。

| middleware | 命名空间 | 原因 |
|---|---|---|
| `redirect-to-https` | argocd / monitoring | ArgoCD 和 Grafana 的 HTTP 入口跳转 |
| `headlamp-https-redirect` | headlamp | Headlamp HTTP 入口跳转 |
| `hubble-https-redirect` | kube-system | Hubble HTTP 入口跳转 |
| `alloy-https-redirect` | logging | Alloy HTTP 入口跳转 |
| `tekton-dashboard-https` | tekton-pipelines | Tekton HTTP 入口跳转 |
| `traefik-https-redirect` | traefik | Traefik 自身 HTTP 入口跳转 |

**原理**：浏览器访问 `http://xxx` → Traefik 检测到 web 入口 → middleware 返回 301 →
浏览器跳转到 `https://xxx`。

**为什么需要**：安全要求，所有对外服务必须走 HTTPS。每个需要 HTTPS 的业务都有一个
对应的 HTTP 入口 IngressRoute，引用跳转 middleware。

#### （2）BasicAuth 类（3 个）— 遗留配置，已失效

**作用**：htpasswd 基础认证（用户名+密码）。

| middleware | 命名空间 | 状态 |
|---|---|---|
| `hubble-ui-auth` | kube-system | **未被任何 IngressRoute 引用（遗留）** |
| `alloy-ui-auth` | logging | **未被任何 IngressRoute 引用（遗留）** |
| `tekton-dashboard-auth` | tekton-pipelines | **未被任何 IngressRoute 引用（遗留）** |

**为什么存在**：这三个 middleware 是**切换到 oauth2-proxy 之前**的旧配置。当时 Hubble、
Alloy、Tekton 用 Traefik BasicAuth 做认证，后来全部迁移到 oauth2-proxy（ReverseProxy 模式），
这些 BasicAuth middleware 就没人引用了，但没清理。

**当前状态**：已失效，不影响运行。如需清理可以删除。

#### （3）转发头类（2 个）

| middleware | 命名空间 | 配置 | 用途 |
|---|---|---|---|
| `argocd-forwarded-headers` | argocd | `X-Forwarded-Proto: https` | 让 ArgoCD 知道原始请求是 HTTPS，避免协议误判 |
| `tekton-dashboard-strip-auth` | tekton-pipelines | `Authorization: ""` | 清空 Authorization 头，避免与 Tekton 自身的认证冲突 |

**为什么需要**：
- `argocd-forwarded-headers`：ArgoCD 需要知道客户端走的是 HTTPS，用于生成正确的回调地址和跳转链接。
- `tekton-dashboard-strip-auth`：请求经过 Tekton Dashboard 时，可能带有其他认证头，需要清空避免冲突。

#### （4）路径重写类（2 个）

| middleware | 命名空间 | 配置 | 用途 |
|---|---|---|---|
| `china-study-free-admin-root` | china-study-free | `^/$` → `/admin/` | 根路径跳转到管理页面 |
| `traefik-root-redirect` | traefik | `^https?://traefik.xyz/$` → `https://traefik.xyz/dashboard/` | Traefik 根路径跳转到 dashboard |

**为什么需要**：这些服务的根路径本身不提供内容（返回 404），需要把根路径重写到实际页面。

#### （5）IP 允许类（1 个）

| middleware | 命名空间 | 配置 | 用途 |
|---|---|---|---|
| `china-study-free-admin-allow` | china-study-free | `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16` | 管理后台仅允许内网 IP 访问 |

**为什么需要**：china-study-free 的 admin 后台是内部管理功能，限制只有内网地址段可以访问，
防止外网暴露。

### 7. 关键结论

1. **没有 ForwardAuth 类型的 middleware**。本集群所有 oauth2-proxy 认证的 UI
   （headlamp、hubble、alloy、tekton、traefik）都使用 **ReverseProxy 模式**，不使用 ForwardAuth。

2. **3 个 BasicAuth middleware 是遗留配置**：`hubble-ui-auth`、`alloy-ui-auth`、
   `tekton-dashboard-auth` 这三个 basicAuth middleware **未被任何 IngressRoute 引用**，
   是切换到 oauth2-proxy 之前的旧配置，已经失效但没清理。

3. **HTTPS 跳转 middleware** 是唯一在生效的认证相关 middleware，但只做 80→443 跳转，
   不涉及用户认证。

4. 5 个 oauth2-proxy 认证的 UI，其 websecure 入口 IngressRoute **均未引用任何 middleware**，
   直接指向 oauth2-proxy Service。

5. **Middleware 核心理解**：Middleware 是 Traefik 的"请求过滤器/处理器"，在请求到达后端前介入。
   本集群主要用它做 **HTTPS 跳转**（安全基线），认证则全部交给 oauth2-proxy（ReverseProxy 模式），
   Traefik 自身不做认证。

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
