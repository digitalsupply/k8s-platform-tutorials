# Traefik 域名路由配置与访问链路详解

- **集群**：Kubernetes v1.35.9 + Traefik v3.6.2 + MetalLB
- **统一入口**：`traefik/traefik` LoadBalancer Service，IP `10.0.0.252`
  - `web`：80 → 容器 8000（仅做 HTTP→HTTPS 跳转）
  - `websecure`：443 → 容器 8443（所有业务 HTTPS 流量）
- **文档范围**：集群内所有 IngressRoute 的域名配置、匹配的 Service、完整访问链路

---

## 一、域名总览

| 域名 | 别名（同一后端） | 后端 Service | 端口 | IngressRoute | TLS |
|---|---|---|---|---|---|
| `grafana.example.local` | `grafana.k8s.local` | `monitoring/prometheus-grafana` | 80→3000 | `monitoring/grafana` | 默认自签名 |
| `prometheus.k8s.local` | `prom.example.local` | `monitoring/prometheus-operated` | 9090（headless） | `monitoring/prometheus` | 默认自签名 |
| `argocd.devops.com` | （无） | `argocd/argocd-server` | 80 | `argocd/argocd` | **真实证书** `argocd-tls` |
| `dashboard.k8s.local` | （无） | `kubernetes-dashboard/kubernetes-dashboard` | 443（https 后端） | `kubernetes-dashboard/kubernetes-dashboard` | 默认自签名 |
| `traefik.example.com` | （无） | `api@internal`（Traefik 内置） | - | `traefik/traefik-dashboard` | 默认自签名 + BasicAuth |

**分类**：
- **双域名服务**：Grafana、Prometheus —— 一条规则里用 `||` 同时匹配两个 Host
- **单域名服务**：ArgoCD、Dashboard、Traefik 自身面板

> 为什么 Grafana/Prometheus 有双域名：历史迁移遗留（`*.example.local` 与 `*.k8s.local`
> 两套内部域名并行）。**注意：双域名只存在于 HTTPS 主路由中，HTTP(80) 跳转路由
> 只写了其中一个域名**——这是当前配置中的不一致点，详见第六节。

---

## 二、双域名服务配置详解（Grafana / Prometheus）

### 2.1 Grafana —— `monitoring/grafana` IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring        # ← IngressRoute 必须和后端 Service 同命名空间
spec:
  entryPoints:
    - websecure                # ← 只挂 443 入口
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
      #      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      #      两个 Host 用 ||（或）连接，命中任意一个即转发
      #      Host() 内必须用反引号 `，不是引号 '
      services:
        - name: prometheus-grafana   # ← 同命名空间（monitoring）内的 Service 名
          port: 80                   # ← Service 的 port（不是容器端口）
  tls: {}                            # ← 空对象 = 启用 443 但用 Traefik 默认自签名证书
```

### 2.2 Prometheus —— `monitoring/prometheus` IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: prometheus
  namespace: monitoring
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`prom.example.local`) || Host(`prometheus.k8s.local`)
      services:
        - name: prometheus-operated   # ← prometheus-operator 自动创建的 Service
          port: 9090
  tls: {}
```

### 2.3 双域名匹配原理

Traefik 对每条 Rule 做布尔表达式求值：

```
Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
```

- `Host()` 匹配的是 TLS **SNI**（HTTPS）或 HTTP **Host 头**，与目标 IP 无关
- `||` 是"或"，`&&` 是"且"，可用括号组合
- 两个域名最终走到**完全相同**的后端 Service——对 Traefik 来说只是两条等价规则
- 多个 IngressRoute 若 match 重叠，Traefik 按创建时间先到先得（不建议依赖此行为）

### 2.4 配套的 HTTP→HTTPS 跳转路由（80 入口）

```yaml
# monitoring/grafana-http-redirect
spec:
  entryPoints:
    - web                      # ← 挂 80 入口
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`)    # ⚠ 只写了 example.local，漏了 grafana.k8s.local
      middlewares:
        - name: redirect-to-https             # ← 引用同命名空间的 Middleware
      services:
        - name: prometheus-grafana
          port: 80
```

```yaml
# monitoring/redirect-to-https Middleware
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace monitoring
spec:
  redirectScheme:
    scheme: https
    permanent: true            # → GET/HEAD 返回 301，其它方法返回 308（实测：curl GET=301，-X POST=308）
```

**效果**：`http://grafana.example.local/` → 308 → `https://grafana.example.local/`。
而 `http://grafana.k8s.local/` 因 match 未包含该域名，**不会跳转**（走 Traefik 默认 404）。
访问者必须自己敲 `https://` 才能打开。

---

## 三、单域名服务配置详解

### 3.1 ArgoCD —— 真实证书 + 请求头中间件

```yaml
# argocd/argocd IngressRoute
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`argocd.devops.com`)        # 单域名，无 ||
      middlewares:
        - name: argocd-forwarded-headers      # 补发 X-Forwarded-Proto
      services:
        - name: argocd-server
          port: 80
          scheme: http                        # 显式声明后端是 http
  tls:
    secretName: argocd-tls                    # ★ 使用 K8s Secret 里的真实证书
```

```yaml
# argocd/argocd-forwarded-headers Middleware
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"   # 告诉 ArgoCD 外层是 https，避免它错误地 302 回 http
```

**与其他服务的差异**：
- `tls.secretName` 指向 `argocd` 命名空间中的 Secret `argocd-tls`（类型 `kubernetes.io/tls`），
  浏览器**不报证书错误**（前提是签发该证书的 CA 被浏览器信任）
- 中间件链：请求先过 `argocd-forwarded-headers`，再转发给后端

### 3.2 Kubernetes Dashboard —— https 后端 + ServersTransport

```yaml
# kubernetes-dashboard/kubernetes-dashboard IngressRoute
spec:
  entryPoints: [web, websecure]     # ★ 同时挂 80 和 443，80 上没有跳转中间件
  routes:
    - kind: Rule
      match: Host(`dashboard.k8s.local`)
      services:
        - name: kubernetes-dashboard
          port: 443                 # ← Service 端口就是 443
          scheme: https             # ← 后端 Pod 提供 HTTPS（自签名）
          serversTransport: k8s-dashboard-transport   # ← 引用同命名空间 ServersTransport
  tls: null
```

```yaml
# kubernetes-dashboard/k8s-dashboard-transport ServersTransport
spec:
  insecureSkipVerify: true          # Traefik → 后端不校验证书（后端是自签的）
  serverName: kubernetes-dashboard  # SNI 校验用的名称
```

**访问机制差异**：Traefik 到后端这一跳本身是 HTTPS，需要 `scheme: https` +
`ServersTransport` 放行自签证书，否则 Traefik 因证书校验失败而 502。

### 3.3 Traefik 自身面板 —— 内置服务 + 路径限制

```yaml
# traefik/traefik-dashboard（Helm 安装时生成）
spec:
  entryPoints: [web, websecure]
  routes:
    - kind: Rule
      match: Host(`traefik.example.com`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))
      #      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      #      Host 与 Path 组合：只有该域名下的 /api 和 /dashboard 路径才匹配
      middlewares:
        - name: traefik-dashboard-auth        # BasicAuth（htpasswd Secret）
      services:
        - kind: TraefikService                # ★ 不是 K8s Service，是 Traefik 内置服务
          name: api@internal
```

---

## 四、匹配的 Service 详解

IngressRoute 的 `services[].name/port` 指向**同命名空间**的 K8s Service。
Traefik 通过 Kubernetes API watch Service/Endpoints，拿到 Pod IP 后直连。

### 4.1 Grafana 后端

```yaml
# monitoring/prometheus-grafana Service（Helm chart grafana-11.6.1 创建）
spec:
  type: ClusterIP
  clusterIP: 10.101.49.32
  ports:
    - name: http-web
      port: 80                # ← IngressRoute 里写的就是这个 80
      targetPort: grafana     # ← 命名端口，对应容器端口名
  selector:
    app.kubernetes.io/instance: prometheus
    app.kubernetes.io/name: grafana
```

```yaml
# 对应 Pod（prometheus-grafana-xxx）容器端口
ports:
  - containerPort: 3000
    name: grafana             # ← targetPort "grafana" 解析到 3000
```

**端口映射链**：`IngressRoute port:80` → `Service port:80` → `targetPort:grafana` → `Container 3000`

### 4.2 Prometheus 后端

```yaml
# monitoring/prometheus-operated Service（prometheus-operator 自动创建）
spec:
  clusterIP: None             # ★ Headless Service——按域名解析出所有 Pod IP
  ports:
    - name: http-web
      port: 9090              # ← IngressRoute 里写的 9090
      targetPort: http-web    # → 容器 9090
  selector:
    app.kubernetes.io/name: prometheus
```

headless（`clusterIP: None`）对 Traefik 转发没有区别：Traefik 读的是
Endpoints/EndpointSlice（Pod IP 列表），而不是 clusterIP。

### 4.3 端口规则速查

| 概念 | 说明 | 本例值 |
|---|---|---|
| IngressRoute `port` | 必须等于 Service 的 `spec.ports[].port` | grafana:80 / prom:9090 |
| Service `port` | ClusterIP 上暴露的端口 | 同上 |
| `targetPort` | 转发到 Pod 的端口（数字或容器端口名） | grafana→3000 / http-web→9090 |
| 容器端口 | Pod 实际监听的端口 | 3000 / 9090 |

---

## 五、完整访问链路（从浏览器到 Pod）

以 `https://grafana.example.local/` 为例，10 步全链路：

```
┌─────────────┐
│  浏览器      │ hosts: grafana.example.local → 10.0.0.252
└──────┬──────┘
       │ ① DNS 解析（/etc/hosts 命中，无 DNS 查询）
       ▼
┌──────────────────────────────────────────────┐
│ ② TCP + TLS 握手 → 10.0.0.252:443           │
│    TLS ClientHello 携带 SNI=grafana.example.local │
└──────┬───────────────────────────────────────┘
       │ ③ 到达 10.0.0.0/24 网段，ARP 解析 10.0.0.252
       │   → MetalLB speaker 应答（l2adv-tailscale 在 eth0/eth1 广告）
       │   → 包发往持有该 IP 的节点
       ▼
┌──────────────────────────────────────────────┐
│ ④ 节点 kube-proxy                            │
│    iptables KUBE-EXTERNAL-SERVICES           │
│    DNAT 10.0.0.252:443 → Traefik Pod IP:8443 │
└──────┬───────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────┐
│ ⑤ Traefik Pod (traefik-xxx) :8443 websecure │
│    entryPoint 过滤：只有挂了 websecure 的路由参与 │
└──────┬───────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────┐
│ ⑥ Host 规则匹配                              │
│    Host(`grafana.example.local`) ✓ 命中      │
│    （prometheus / argocd 等规则不匹配，跳过）  │
└──────┬───────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────┐
│ ⑦ TLS 终止                                   │
│    tls: {} → Traefik 默认自签名证书            │
│    （argocd 则用 secretName=argocd-tls 的证书）│
└──────┬───────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────┐
│ ⑧ 中间件链（如有）                            │
│    grafana 主路由无中间件；80 跳转路由才有     │
│    redirect-to-https                         │
└──────┬───────────────────────────────────────┘
       ▼
┌──────────────────────────────────────────────┐
│ ⑨ Service 转发                               │
│    prometheus-grafana.monitoring:80          │
│    → Endpoints → Pod IP (10.244.x.x):3000    │
│    （Traefik 直连 Pod IP，不经 Service IP）    │
└──────┬───────────────────────────────────────┘
       ▼
┌─────────────┐
│ Grafana Pod │ :3000 返回 302 → /login → 200  │
└─────────────┘
```

### 5.1 HTTP(80) 访问的分叉链路

```
http://grafana.example.local/
  ①~④ 同上，但 DNAT 到 Traefik Pod:8000 (web 入口)
  ⑤ entryPoint=web 过滤
  ⑥ 命中 grafana-http-redirect 规则
  ⑦ 执行 redirect-to-https 中间件 → 返回 308 Location: https://... 
  （不接触任何后端 Service）

http://grafana.k8s.local/
  ⑥ web 入口中没有任何规则匹配该 Host
  → Traefik 默认 404（不会跳转到 https！）
```

### 5.2 链路上每一层的职责与故障表现

| 层 | 职责 | 故障时的典型表现 |
|---|---|---|
| hosts/DNS | 域名→10.0.0.252 | `ERR_NAME_NOT_RESOLVED` |
| MetalLB ARP | 10.0.0.252 在网段内可解析 | 连接超时「响应时间太长」（本次故障 2） |
| kube-proxy DNAT | LB IP → Traefik Pod | 集群外超时但集群内正常（本次故障 2 的表现） |
| Traefik entryPoint | 按 80/443 分流 | 80 能开 443 打不开，或反之 |
| Host 规则匹配 | 域名→路由 | **404**（Traefik 收到了但没有规则命中） |
| tls 字段 | 证书选择 | certResolver 不存在 → **整个路由被丢弃 → 404**（本次故障 1） |
| 中间件 | 跳转/改头/鉴权 | 循环跳转、401、后端收到错误的协议头 |
| Service/Endpoints | 转发到 Pod | `allowEmptyServices=false` 时 503 |
| 后端 Pod | 业务响应 | 5xx、超时（Pod 内应用层错误） |

---

## 六、当前配置中的不一致点（建议整改）

### 6.1 HTTP 跳转路由漏写别名域名

| 服务 | HTTPS 主路由 match | HTTP 跳转路由 match | 后果 |
|---|---|---|---|
| grafana | `grafana.example.local \|\| grafana.k8s.local` | 仅 `grafana.example.local` | `http://grafana.k8s.local` 不跳转，404 |
| prometheus | `prom.example.local \|\| prometheus.k8s.local` | 仅 `prom.example.local` | `http://prometheus.k8s.local` 不跳转，404 |

**整改方式**：跳转路由的 match 与主路由保持一致，例如

```yaml
match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
```

### 6.2 Dashboard 挂了 web 但无跳转

`kubernetes-dashboard` 的 IngressRoute `entryPoints: [web, websecure]`，
80 上直接暴露后端（scheme https）而非 308 跳转，与其他服务模式不统一。

### 6.3 证书体系不统一

| 服务 | TLS 配置 | 浏览器表现 |
|---|---|---|
| argocd | `secretName: argocd-tls`（真实证书） | 信任则无警告 |
| grafana / prometheus / dashboard / traefik | `tls: {}` 或 null（默认自签名） | 报「不安全」需手动放行 |

如需消除警告，用内部 CA + cert-manager 给各域名签发证书，替换 `tls: {}` 为
`tls: { secretName: <签发的secret> }`。公网 CA 无法为 `*.local` 域名签发。

---

## 七、运维操作速查

### 7.1 给已有服务增加一个别名域名

```bash
# 以 grafana 为例，新增 alias.example.org
kubectl edit ingressroute grafana -n monitoring
# match 改为：
#   Host(`grafana.example.local`) || Host(`grafana.k8s.local`) || Host(`alias.example.org`)
# 同时给该域名在客户端 hosts / 内部 DNS 加解析
# （可选）同步修改 grafana-http-redirect 的 match
```

### 7.2 新增一个单域名服务的标准模板

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp                 # 与后端 Service 同命名空间
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`myapp.example.local`)
      services:
        - name: myapp-svc
          port: 8080
  tls: {}                          # 或 secretName: <真实证书>
---
# 80 → 443 跳转（match 必须与上面一致！）
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp-http-redirect
  namespace: myapp
spec:
  entryPoints: [web]
  routes:
    - kind: Rule
      match: Host(`myapp.example.local`)
      middlewares:
        - name: redirect-to-https
      services:
        - name: myapp-svc
          port: 8080
---
# Middleware（若目标命名空间还没有）
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: myapp
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

### 7.3 常用排查命令

```bash
# 查看所有路由及其后端
kubectl get ingressroute -A -o wide

# 查看某条路由的 match 与 services
kubectl get ingressroute <name> -n <ns> -o yaml | grep -A8 'match:'

# 查看 Traefik 侧配置错误（certResolver 不存在等）
kubectl logs -n traefik deploy/traefik --since=10m | grep -iE 'err|warn'

# 集群内模拟外部 Host 访问（绕过 DNS）
kubectl exec -n default netshoot-debug -- \
  curl -skI --resolve <域名>:443:10.0.0.252 https://<域名>/

# 验证 ARP 层（外部超时的排查起点）
arping -I eth0 -c 3 10.0.0.252

# 查看 Service 后端 Pod
kubectl get endpoints <svc> -n <ns>

# 查看证书是哪个（默认自签 or secretName）
echo | openssl s_client -connect 10.0.0.252:443 -servername <域名> 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

---

## 附录：本集群全部 IngressRoute 原始配置（已脱敏时间戳）

```yaml
# ========== monitoring/grafana（双域名） ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: grafana, namespace: monitoring}
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
      services:
        - {name: prometheus-grafana, port: 80}
  tls: {}
---
# ========== monitoring/grafana-http-redirect ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: grafana-http-redirect, namespace: monitoring}
spec:
  entryPoints: [web]
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`)
      middlewares: [{name: redirect-to-https}]
      services:
        - {name: prometheus-grafana, port: 80}
---
# ========== monitoring/prometheus（双域名） ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: prometheus, namespace: monitoring}
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`prom.example.local`) || Host(`prometheus.k8s.local`)
      services:
        - {name: prometheus-operated, port: 9090}
  tls: {}
---
# ========== monitoring/prometheus-http-redirect ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: prometheus-http-redirect, namespace: monitoring}
spec:
  entryPoints: [web]
  routes:
    - kind: Rule
      match: Host(`prom.example.local`)
      middlewares: [{name: redirect-to-https}]
      services:
        - {name: prometheus-operated, port: 9090}
---
# ========== monitoring/redirect-to-https Middleware ==========
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: redirect-to-https, namespace: monitoring}
spec:
  redirectScheme: {scheme: https, permanent: true}
---
# ========== argocd/argocd（单域名 + 真实证书） ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: argocd, namespace: argocd}
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`argocd.devops.com`)
      middlewares: [{name: argocd-forwarded-headers}]
      services:
        - {name: argocd-server, port: 80, scheme: http}
  tls: {secretName: argocd-tls}
---
# ========== argocd/argocd-forwarded-headers Middleware ==========
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: argocd-forwarded-headers, namespace: argocd}
spec:
  headers:
    customRequestHeaders: {X-Forwarded-Proto: "https"}
---
# ========== kubernetes-dashboard（单域名 + https 后端） ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: kubernetes-dashboard, namespace: kubernetes-dashboard}
spec:
  entryPoints: [web, websecure]
  routes:
    - kind: Rule
      match: Host(`dashboard.k8s.local`)
      services:
        - name: kubernetes-dashboard
          port: 443
          scheme: https
          serversTransport: k8s-dashboard-transport
  tls: null
---
# ========== kubernetes-dashboard/k8s-dashboard-transport ==========
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata: {name: k8s-dashboard-transport, namespace: kubernetes-dashboard}
spec:
  insecureSkipVerify: true
  serverName: kubernetes-dashboard
---
# ========== traefik/traefik-dashboard（内置 api@internal） ==========
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: {name: traefik-dashboard, namespace: traefik}
spec:
  entryPoints: [web, websecure]
  routes:
    - kind: Rule
      match: Host(`traefik.example.com`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))
      middlewares: [{name: traefik-dashboard-auth}]
      services:
        - kind: TraefikService
          name: api@internal
```

---

*生成时间：2026-10-06，基于集群实时配置导出。*
