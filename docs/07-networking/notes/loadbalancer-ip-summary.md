# LoadBalancer IP 地址总结

> 更新时间: 2026-09-28

---

## LoadBalancer 服务

| 服务 | 命名空间 | 外部 IP | HTTP 端口 | HTTPS 端口 | 用途 |
|------|----------|---------|-----------|------------|------|
| traefik | traefik | **10.0.0.252** | 80 (节点端口 30156) | 443 (节点端口 30306) | 集群入口控制器 |
| kourier | knative-serving | **10.0.0.253** | 80 (节点端口 30226) | 443 (节点端口 31123) | Knative 服务网关 |

---

## 远程访问 (Tailscale)

由于 Tailscale 只广播了 `10.0.0.x` 子网路由，LoadBalancer IP 已迁移到 `10.0.0.x` 网段。

### 访问地址

| 服务 | HTTP | HTTPS |
|------|------|-------|
| Traefik 入口 | http://10.0.0.252 | https://10.0.0.252 |
| Knative Kourier | http://10.0.0.253 | https://10.0.0.253 |

---

## MetalLB 配置

### IPAddressPool

| 名称 | 地址范围 | 用途 |
|------|----------|------|
| lb-pool-eth1 | 172.16.1.220-172.16.1.250 | 旧地址池 (未使用) |
| lb-pool-tailscale | 10.0.0.252-10.0.0.253 | Tailscale 远程访问 |

### L2Advertisement

| 名称 | 接口 | 地址池 |
|------|------|--------|
| l2adv-eth1 | eth1 | lb-pool-eth1 |
| l2adv-tailscale | eth1 | lb-pool-tailscale |

---

## 端口映射详情

### traefik (10.0.0.252)

| 服务端口 | 节点端口 | 协议 | 用途 |
|----------|----------|------|------|
| 80 | 30156 | TCP | HTTP 入口 |
| 443 | 30306 | TCP | HTTPS 入口 |

### kourier (10.0.0.253)

| 服务端口 | 节点端口 | 协议 | 用途 |
|----------|----------|------|------|
| 80 | 30226 | TCP | HTTP 入口 |
| 443 | 31123 | TCP | HTTPS 入口 |

---

## 验证命令

```bash
# 检查 LoadBalancer 服务状态
kubectl get svc -A | grep LoadBalancer

# 测试 Traefik 访问
curl -I http://10.0.0.252
curl -I https://10.0.0.252

# 测试 Kourier 访问
curl -I http://10.0.0.253
curl -I https://10.0.0.253

# 检查 MetalLB 配置
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

---

## 备注

- **旧 IP (172.16.1.x)**: 由于 Tailscale 只广播了 10.0.0.x 子网，172.16.1.x 网段无法从远程访问
- **新 IP (10.0.0.x)**: 已配置为 Tailscale 可访问的地址
- **MetalLB 模式**: L2 模式，通过 ARP 响应分配 IP

---

*报告由 kubectl 自动生成*
