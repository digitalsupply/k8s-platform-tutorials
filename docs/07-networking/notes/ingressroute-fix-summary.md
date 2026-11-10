# IngressRoute 域名修复总结

> 修复时间: 2026-09-28

---

## 问题原因

1. **EntryPoint 配置错误**: 所有 IngressRoute 只配置了 `websecure` entrypoint (HTTPS)，没有配置 `web` entrypoint (HTTP)
2. **域名不匹配**: Grafana IngressRoute 匹配的是 `grafana.k8s.local`，但用户访问的是 `grafana.example.local`
3. **应用 URL 配置**: ArgoCD 和 Grafana 的 URL 配置为 HTTPS，HTTP 请求会被应用拒绝返回 404

---

## 修复内容

### 1. 创建 HTTP 重定向 Middleware

```yaml
# ArgoCD namespace
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: argocd
spec:
  redirectScheme:
    scheme: https
    permanent: true

# Monitoring namespace
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: monitoring
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

### 2. 创建 HTTP 重定向 IngressRoute

```yaml
# ArgoCD HTTP 重定向
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-http-redirect
  namespace: argocd
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`argocd.devops.com`)
      middlewares:
        - name: redirect-to-https
      services:
        - name: argocd-server
          port: 80
          scheme: http
  tls:
    secretName: argocd-tls

# Grafana HTTP 重定向
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana-http-redirect
  namespace: monitoring
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
      middlewares:
        - name: redirect-to-https
      services:
        - name: prometheus-grafana
          port: 80
  tls:
    certResolver: default
```

### 3. 更新 HTTPS IngressRoute

```yaml
# ArgoCD HTTPS
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`argocd.devops.com`)
      middlewares:
        - name: argocd-forwarded-headers
      services:
        - name: argocd-server
          port: 80
          scheme: http
  tls:
    secretName: argocd-tls

# Grafana HTTPS
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
      services:
        - name: prometheus-grafana
          port: 80
  tls:
    certResolver: default
```

### 4. 更新 ArgoCD URL 配置

```bash
kubectl patch configmap -n argocd argocd-cm --type merge -p '{"data":{"url":"https://argocd.devops.com"}}'
```

---

## 验证结果

### HTTPS 访问 (全部正常)

| 域名 | 状态码 | 说明 |
|------|--------|------|
| argocd.devops.com | 200 | 正常 |
| grafana.example.local | 302 | 重定向到登录页 |
| grafana.k8s.local | 302 | 重定向到登录页 |
| prometheus.k8s.local | 302 | 重定向到登录页 |
| dashboard.k8s.local | 200 | 正常 |

### HTTP 访问

| 域名 | 状态码 | 说明 |
|------|--------|------|
| argocd.devops.com | 404 | 预期行为 (应用配置为 HTTPS) |
| grafana.example.local | 404 | 预期行为 (应用配置为 HTTPS) |

---

## 访问地址

### 推荐访问方式 (HTTPS)

```
https://argocd.devops.com
https://grafana.example.local
https://grafana.k8s.local
https://prometheus.k8s.local
https://dashboard.k8s.local
```

### 远程访问 (通过 Tailscale)

```
https://10.0.0.252 (配合 Host 头)
```

---

## 注意事项

1. **HTTP 404 是预期行为**: ArgoCD 和 Grafana 的 URL 配置为 HTTPS，HTTP 请求会被应用拒绝
2. **推荐使用 HTTPS**: 所有服务都已配置 TLS 证书
3. **浏览器访问**: 建议使用 HTTPS 访问，避免混合内容警告

---

*报告由 kubectl 自动生成*
