# Cloudflare Tunnel 故障排查报告

> 生成时间: 2026-09-27  
> 问题 Pod: `n8n/cloudflared-5c87595bb7-4tf6x`  
> 隧道 ID: `07391243-972c-4029-8a7e-69169854b2c9`  
> 公网域名: `n8ntrace.ccwu.cc`

---

## 1. 问题现象

访问 `https://n8ntrace.ccwu.cc/` 报错，无法打开 n8n 页面。

**用户反馈**: 3 个月前能正常访问，没有进行任何影响它的操作。

---

## 0. 修复结果 (2026-09-27)

### 问题根因
网络从 `192.168.2.x` 迁移到 `192.168.67.x` 后，CoreDNS 的 `forward . /etc/resolv.conf` 配置指向了不可达的上游 DNS (`192.168.2.1`)，导致所有外部域名解析失败。

### 修复步骤
1. **CoreDNS 配置更新** — 将 `forward` 改为公共 DNS (223.5.5.5, 119.29.29.29, 1.1.1.1)
2. **cloudflared DNS 配置** — 添加 `dnsConfig` 使用集群 DNS 解析内部服务名
3. **重启 CoreDNS 和 cloudflared**

### 验证结果
- 隧道状态: 正常 (4 条连接全部注册)
- 预检状态: 全部 PASS (DNS/UDP/TCP/Cloudflare API)
- 公网访问: `https://n8ntrace.ccwu.cc` 正常

---

## 2. 当前状态

### 2.1 Pod 状态

| 项目 | 值 |
|------|-----|
| Pod 名称 | `cloudflared-5c87595bb7-4tf6x` |
| 状态 | **CrashLoopBackOff** |
| 重启次数 | 44+ |
| 运行节点 | worker02 |
| 容器镜像 | `cloudflare/cloudflared:latest` |

### 2.2 n8n 状态

| 项目 | 值 |
|------|-----|
| Pod 名称 | `n8n-5674d5b9cf-7z2km` |
| 状态 | Running (1/1) |
| 重启次数 | 10 |

---

## 3. 原因分析

### 3.1 根本原因

**上游 DNS 服务器 (192.168.2.1) 不可达** — CoreDNS 的 `forward` 配置指向了不可达的上游 DNS，导致所有外部域名解析失败。

### 3.2 问题链路

```
cloudflared 启动
    │
    ▼
尝试解析 _v2-origintunneld._tcp.argotunnel.com
    │
    ▼
使用集群 DNS (10.96.0.10 = kube-dns)
    │
    ▼
kube-dns 转发到上游 DNS (192.168.2.1:53)
    │
    ▼
192.168.2.1 不可达 (i/o timeout)
    │
    ▼
返回 "server misbehaving"
    │
    ▼
cloudflared 无法发现 Cloudflare Edge 节点
    │
    ▼
隧道连接失败 → CrashLoopBackOff
```

### 3.3 关键证据

#### CoreDNS 配置
```yaml
forward . /etc/resolv.conf {
   max_concurrent 1000
}
```

#### CoreDNS 日志错误
```
[ERROR] plugin/errors: 2 n8ntrace.ccwu.cc. A: read udp 10.244.28.100:34530->192.168.2.1:53: i/o timeout
[ERROR] plugin/errors: 2 stats.grafana.org. A: read udp 10.244.28.100:48730->192.168.2.1:53: i/o timeout
```

#### DNS 测试结果
| 上游 DNS | 状态 | 说明 |
|----------|------|------|
| 192.168.2.1 | ❌ 不可达 | CoreDNS 当前使用 |
| 1.1.1.1 | ✅ 正常 | 可解析 n8ntrace.ccwu.cc |
| 8.8.8.8 | ✅ 正常 | 可解析 n8ntrace.ccwu.cc |

### 3.4 为什么 3 个月前能访问？

**确认原因: 网络环境变更**

用户确认服务器从 `192.168.2.x` 网段迁移到了 `192.168.67.x` 网段。

- **旧网络**: `192.168.2.x`，上游 DNS 为 `192.168.2.1`（当时可达）
- **新网络**: `192.168.67.x`，`192.168.2.1` 已不可达

### 3.5 为什么"没有进行操作"却出问题？

**原因: 网络迁移导致上游 DNS 不可达**

1. CoreDNS 配置使用 `forward . /etc/resolv.conf`
2. Pod 内的 `/etc/resolv.conf` 仍然指向旧网络 DNS (`192.168.2.1`)
3. 网络迁移后，`192.168.2.1` 在新网络中不可达
4. 导致所有外部域名解析失败

**时间线:**
```
3 个月前: 网络在 192.168.2.x，192.168.2.1 可达 → 正常
    │
    ▼
网络迁移: 服务器迁移到 192.168.67.x
    │
    ▼
现在: 192.168.2.1 不可达 → DNS 解析失败 → 隧道断开
```

---

## 4. 解决方案

### 方案 1: 修改 CoreDNS 使用新网络的上游 DNS (推荐)

**优点**: 一次性解决，所有 Pod 都能受益，符合网络迁移后的环境

**操作**:

```bash
kubectl edit configmap -n kube-system coredns
```

修改 Corefile，将 forward 改为新网络的上游 DNS：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        template ANY AAAA . {
            rcode NOERROR
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . 192.168.67.1 1.1.1.1 8.8.8.8 {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

> **注意**: 请将 `192.168.67.1` 替换为新网络的实际上游 DNS 地址

**验证**:

```bash
# 重启 CoreDNS
kubectl rollout restart deployment -n kube-system coredns

# 等待就绪
kubectl rollout status deployment -n kube-system coredns

# 测试解析
kubectl exec -n default netshoot-debug -- nslookup n8ntrace.ccwu.cc

# 测试隧道
curl -I https://n8ntrace.ccwu.cc
```

---

### 方案 2: 直接使用公共 DNS (最简单)

**优点**: 不依赖网络环境，最稳定

**操作**:

```bash
kubectl edit configmap -n kube-system coredns
```

```yaml
forward . 1.1.1.1 8.8.8.8 223.5.5.5 {
   max_concurrent 1000
}
```

---

### 方案 3: 修改 cloudflared 使用公共 DNS

**优点**: 只影响 cloudflared，不依赖集群 DNS

**操作**:

```bash
kubectl edit deployment -n n8n cloudflared
```

在 `spec.template.spec` 中添加：

```yaml
dnsPolicy: "None"
dnsConfig:
  nameservers:
    - 1.1.1.1
    - 8.8.8.8
  searches:
    - n8n.svc.cluster.local
    - svc.cluster.local
    - cluster.local
```

**验证**:

```bash
kubectl rollout restart deployment -n n8n cloudflared
kubectl rollout status deployment -n n8n cloudflared
kubectl logs -n n8n -l app=cloudflared --tail=30
```

---

## 5. 验证清单

修复后请逐项验证：

| 检查项 | 命令 | 预期结果 |
|--------|------|----------|
| CoreDNS 状态 | `kubectl get pods -n kube-system -l k8s-app=kube-dns` | Running |
| 上游 DNS 可达性 | `kubectl exec -n default netshoot-debug -- nslookup n8ntrace.ccwu.cc 192.168.67.1` | 正常解析 |
| DNS 解析 | `kubectl exec -n default netshoot-debug -- nslookup n8ntrace.ccwu.cc` | 正常解析 |
| cloudflared 状态 | `kubectl get pods -n n8n` | Running (1/1) |
| 隧道连接 | `kubectl logs -n n8n -l app=cloudflared` | 无 DNS 错误 |
| 公网访问 | `curl -I https://n8ntrace.ccwu.cc` | HTTP 200 |
| n8n 页面 | 浏览器访问 | 正常显示 |

---

## 6. 预防措施

1. **监控 CoreDNS**: 添加告警规则，DNS 解析失败时及时通知
2. **使用可靠的公共 DNS**: 避免依赖单一上游 DNS
3. **定期检查 DNS 配置**: 确保 forward 配置正确
4. **避免使用 latest 镜像**: 使用固定版本，避免意外更新
5. **网络迁移时更新 DNS 配置**: 网络环境变更时，同步更新 CoreDNS 的 forward 配置
6. **文档化网络架构**: 记录上游 DNS 地址和网络拓扑，便于排查

---

## 7. 相关资源

- [CoreDNS forward 插件](https://coredns.io/plugins/forward/)
- [Cloudflare 1.1.1.1](https://developers.cloudflare.com/1.1.1.1/)
- [cloudflared DNS 配置](https://github.com/cloudflare/cloudflared/issues/27546)

---

*报告由 kubectl 日志分析生成*
