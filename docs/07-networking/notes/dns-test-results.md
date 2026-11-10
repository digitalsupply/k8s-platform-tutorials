# DNS 测试结果报告

> 测试时间: 2026-09-27  
> 测试环境: Kubernetes 集群内部 (netshoot-debug Pod)  
> 测试目标: 为中国场景选择最快最优质的 DNS 服务器

---

## 1. 测试结果总览

| DNS 服务器 | 延迟 | A 记录 | SRV 记录 | 推荐度 | 说明 |
|------------|------|--------|----------|--------|------|
| **223.5.5.5** | **25ms** | 支持 | 支持 | 首选 | 阿里 DNS，国内最快 |
| **119.29.29.29** | **27ms** | 支持 | 支持 | 备选 | 腾讯 DNS，国内次快 |
| **8.8.8.8** | **62ms** | 支持 | 支持 | 第三 | Google DNS，国际 |
| **1.1.1.1** | **188ms** | 支持 | 支持 | 第四 | Cloudflare，国际 |
| 192.168.67.1 | 不可达 | - | - | 不可用 | 新网络上游 DNS |

---

## 2. 详细测试数据

### 2.1 延迟测试 (Ping)

| DNS 服务器 | 最小延迟 | 平均延迟 | 最大延迟 | 抖动 |
|------------|----------|----------|----------|------|
| 223.5.5.5 | 25.202ms | 25.285ms | 25.370ms | 0.068ms |
| 119.29.29.29 | 26.666ms | 26.810ms | 26.960ms | 0.120ms |
| 8.8.8.8 | 61.816ms | 62.014ms | 62.207ms | 0.159ms |
| 1.1.1.1 | 175.118ms | 188.471ms | 205.483ms | 12.663ms |
| 192.168.67.1 | - | - | - | 不可达 |

### 2.2 SRV 记录解析测试 (cloudflared 需要)

| DNS 服务器 | SRV 记录 | 解析结果 |
|------------|----------|----------|
| 223.5.5.5 | `_v2-origintunneld._tcp.argotunnel.com` | region1.v2.argotunnel.com, region2.v2.argotunnel.com |
| 119.29.29.29 | `_v2-origintunneld._tcp.argotunnel.com` | region1.v2.argotunnel.com, region2.v2.argotunnel.com |
| 8.8.8.8 | `_v2-origintunneld._tcp.argotunnel.com` | region1.v2.argotunnel.com, region2.v2.argotunnel.com |
| 1.1.1.1 | `_v2-origintunneld._tcp.argotunnel.com` | region1.v2.argotunnel.com, region2.v2.argotunnel.com |
| 192.168.67.1 | - | 不可达 |

### 2.3 A 记录解析测试

| DNS 服务器 | 域名 | 解析结果 |
|------------|------|----------|
| 223.5.5.5 | n8ntrace.ccwu.cc | 104.21.18.107, 172.67.181.153 |
| 119.29.29.29 | n8ntrace.ccwu.cc | 104.21.18.107, 172.67.181.153 |
| 8.8.8.8 | n8ntrace.ccwu.cc | 104.21.18.107, 172.67.181.153 |
| 1.1.1.1 | n8ntrace.ccwu.cc | 104.21.18.107, 172.67.181.153 |

---

## 3. 推荐方案

### 方案 1: 使用国内 DNS (推荐)

```yaml
forward . 223.5.5.5 119.29.29.29 1.1.1.1 {
   max_concurrent 1000
}
```

**优点**:
- 国内延迟最低 (25-27ms)
- 支持 SRV 记录解析
- 稳定性好

### 方案 2: 使用公共 DNS

```yaml
forward . 1.1.1.1 8.8.8.8 223.5.5.5 {
   max_concurrent 1000
}
```

**优点**:
- 国际 CDN 优化
- 支持 SRV 记录解析
- 稳定性好

### 方案 3: 混合使用

```yaml
forward . 223.5.5.5 119.29.29.29 8.8.8.8 1.1.1.1 {
   max_concurrent 1000
}
```

**优点**:
- 国内+国际混合
- 自动故障转移
- 最稳定

---

## 4. 结论

### 最佳选择

**推荐使用**: `223.5.5.5` (阿里 DNS) 作为主 DNS

**理由**:
1. 国内延迟最低 (25ms)
2. 支持 SRV 记录解析 (cloudflared 需要)
3. 稳定性好，抖动小 (0.068ms)
4. 国内 CDN 优化

### 备选方案

1. **119.29.29.29** (腾讯 DNS) - 延迟 27ms，与阿里 DNS 互补
2. **8.8.8.8** (Google DNS) - 延迟 62ms，国际备选
3. **1.1.1.1** (Cloudflare) - 延迟 188ms，最后备选

### 不推荐

- **192.168.67.1** - 不可达，无法使用

---

## 5. 修复建议

### 立即修复 (推荐)

```bash
kubectl edit configmap -n kube-system coredns
```

```yaml
forward . 223.5.5.5 119.29.29.29 1.1.1.1 {
   max_concurrent 1000
}
```

### 验证

```bash
# 重启 CoreDNS
kubectl rollout restart deployment -n kube-system coredns

# 测试解析
kubectl exec -n default netshoot-debug -- dig +short SRV _v2-origintunneld._tcp.argotunnel.com

# 测试隧道
curl -I https://n8ntrace.ccwu.cc
```

---

*报告由 DNS 测试生成*
