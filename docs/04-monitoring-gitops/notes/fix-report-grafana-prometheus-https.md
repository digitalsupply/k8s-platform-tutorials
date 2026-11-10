# Grafana / Prometheus 访问故障修复报告

- **日期**：2026-10-06
- **现象**：浏览器访问 `https://grafana.example.local/`、`https://prometheus.k8s.local/` 打不开（后者报「响应时间太长」）
- **访问方式**：Tailscale 远程访问，hosts 文件映射到 `10.0.0.252`（Traefik LoadBalancer IP）
- **结论**：Pod 全部正常，问题为两处配置错误：
  1. IngressRoute 引用了不存在的证书解析器 `default`，Traefik 直接丢弃了 HTTPS 路由
  2. MetalLB 的 L2 广告只配在 `eth1`，而 `10.0.0.252` 属于 `eth0` 网段（10.0.0.0/24），外部机器 ARP 无应答导致连接超时

---

## 一、环境信息

| 组件 | 值 |
|---|---|
| Traefik | `traefik/traefik-59b795db8-827mj`，v3.6.2，1/1 Running |
| Grafana | `monitoring/prometheus-grafana-fb7445bf9-lvmkz`，3/3 Running |
| Traefik Service | `traefik/traefik` LoadBalancer，`10.0.0.252`（80/443） |
| MetalLB 地址池 | `lb-pool-eth1`：172.16.1.220-250；`lb-pool-tailscale`：10.0.0.252-10.0.0.252 |
| 节点网卡 | eth0：10.0.0.0/24；eth1：172.16.1.0/16 |
| 节点 | m01(10.0.0.61)、master01/02、worker01/02/03 |

Traefik 启动参数中**没有配置任何 `certificatesResolvers`**（无 ACME/LetsEncrypt），
入口 `websecure` 开启了全局 TLS：`--entryPoints.websecure.http.tls=true`。

---

## 二、故障 1：https://grafana.example.local/ 打不开

### 排查过程

1. 所有相关 pod 状态正常，Traefik 无重启、无 crash。
2. Traefik 日志发现关键报错：

   ```
   ERR Router uses a nonexistent certificate resolver
       certificateResolver=default
       routerName=monitoring-grafana-8e63b5797962b54f2404@kubernetescrd
   ```

   同样的报错也出现在 `monitoring-prometheus`、`monitoring-grafana-http-redirect`、
   `monitoring-prometheus-http-redirect` 等路由器上。

3. 检查 `monitoring/grafana` IngressRoute，原始配置为：

   ```yaml
   spec:
     entryPoints: [websecure]
     tls:
       certResolver: default    # ← Traefik 里根本不存在名为 default 的证书解析器
     routes:
       - match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
         services: [{name: prometheus-grafana, port: 80}]
   ```

### 根因

Traefik 遇到路由器引用了**不存在的 certificate resolver** 时，会直接**丢弃整个路由器**，
而不是忽略该字段。因此 `websecure`(443) 入口上没有任何匹配 `grafana.example.local`
的路由 → HTTPS 访问失败。

集群内部测试之所以"看起来是通的"，是因为从集群内/节点发起的请求在本机就被
kube-proxy DNAT 处理，与外部链路不同。

### 修复

删除 IngressRoute 中的 `tls.certResolver`（改为 `tls: {}`，使用 Traefik 默认证书），
并补充 HTTP→HTTPS 跳转路由（当日 13:57~13:59 已完成）：

- `monitoring/grafana`：`tls: {}`
- `monitoring/grafana-http-redirect`（web 入口，80 → 443）
- `monitoring/prometheus`、`monitoring/prometheus-http-redirect`：同类处理

### 验证

```bash
curl -sk --resolve grafana.example.local:443:10.0.0.252 https://grafana.example.local/
# → HTTP 302, location: /login
curl -skL --resolve grafana.example.local:443:10.0.0.252 https://grafana.example.local/
# → final HTTP 200, url=https://grafana.example.local/login
```

> 注意：当前证书为 Traefik 自签名默认证书（`CN=TRAEFIK DEFAULT CERT`），
> 浏览器会提示「不安全」，属预期现象，详见第五节。

---

## 三、故障 2：https://prometheus.k8s.local/ 响应时间太长（超时）

### 排查过程

1. 路由规则问题：`monitoring/prometheus` IngressRoute 的 match 被改成了只剩
   `Host(`prom.example.local`)`，用户实际访问的 `prometheus.k8s.local` 不匹配
   ——即使网络通了也会 404。

2. 网络连通性问题（核心）：

   - 集群内测试（netshoot pod、节点本机）访问 `10.0.0.252:443` 正常：
     `iptables -t nat -L KUBE-EXTERNAL-SERVICES` 中存在
     `traefik/traefik:websecure loadbalancer IP tcp dpt:443` 规则，
     即 kube-proxy 在节点本地完成 DNAT，**不经过 ARP**，因此集群内永远"是通的"。
   - 外部视角实测（在节点 m01 上模拟外网链路）：

     ```bash
     arping -I eth0 -c 3 10.0.0.252   # ← 0 response（eth0 网段无人应答 ARP）
     ip neigh show dev eth0 | grep 10.0.0.252   # → FAILED
     arping -I eth1 -c 2 10.0.0.252   # ← 有应答（eth1 网段正常）
     ```

3. 检查 MetalLB 配置：

   ```yaml
   # IPAddressPool lb-pool-tailscale
   addresses: [10.0.0.252-10.0.0.252]

   # L2Advertisement l2adv-tailscale（修复前）
   interfaces: [eth1]                # ← 只在 eth1 广告
   ipAddressPools: [lb-pool-tailscale]
   ```

### 根因

`10.0.0.252` 属于 `10.0.0.0/24`（节点 eth0 网段），
但 MetalLB 只在 **eth1**（172.16.1.0/16）上对该 IP 做 L2/ARP 广告。

外部机器（含 Tailscale 子网路由落地后的流量）访问 `10.0.0.252` 时需要在
`10.0.0.0/24` 网段上 ARP 解析该 IP → **无人应答** → TCP 连接一直等待 →
浏览器报「响应时间太长 / 无法连接」。

同一地址池分配的 `10.0.0.253`（knative kourier）存在同样问题，被本次修复一并解决。

### 修复

**修复 1：MetalLB L2 广告增加 eth0**

```bash
kubectl patch l2advertisement l2adv-tailscale -n metallb-system \
  --type merge -p '{"spec":{"interfaces":["eth0","eth1"]}}'
```

**修复 2：IngressRoute 恢复 prometheus.k8s.local 主机名匹配**

```bash
kubectl patch ingressroute prometheus -n monitoring --type merge \
  -p '{"spec":{"routes":[{"kind":"Rule",
       "match":"Host(`prom.example.local`) || Host(`prometheus.k8s.local`)",
       "services":[{"name":"prometheus-operated","port":9090}]}]}}'
```

### 验证

```bash
# ARP 修复后：eth0 / eth1 均有应答
arping -I eth0 -c 3 10.0.0.252   # ← 3 response（修复前为 0）
arping -I eth1 -c 2 10.0.0.252   # ← 有应答

# MetalLB 日志确认重新广播
{"event":"serviceAnnounced","ips":["10.0.0.252"],"pool":"lb-pool-tailscale","protocol":"layer2"}

# 路由生效
curl -sk --resolve prometheus.k8s.local:443:10.0.0.252 https://prometheus.k8s.local/
# → HTTP 302（修复前为 404）
curl -sk --resolve grafana.example.local:443:10.0.0.252 https://grafana.example.local/
# → HTTP 302，最终 /login 200
```

用户浏览器复测通过。

---

## 四、变更清单

| # | 资源 | 变更 |
|---|---|---|
| 1 | `monitoring/ingressroute/grafana` | 删除 `tls.certResolver: default`，改为 `tls: {}` |
| 2 | `monitoring/ingressroute/grafana-http-redirect` | 新增：web 入口 80 → 443 跳转 |
| 3 | `monitoring/ingressroute/prometheus` | 删除 `certResolver`；match 恢复为 `prom.example.local \|\| prometheus.k8s.local` |
| 4 | `monitoring/ingressroute/prometheus-http-redirect` | 新增：web 入口 80 → 443 跳转 |
| 5 | `metallb-system/l2advertisement/l2adv-tailscale` | `interfaces: [eth1]` → `[eth0, eth1]` |

---

## 五、遗留事项 / 建议

1. **证书不受信任（预期现象）**
   当前使用 Traefik 自签名默认证书，浏览器会警告。`example.local` 无法通过公网
   CA 签发，如需消除警告：
   - 搭建内部 CA，用 cert-manager 签发并挂载到 Traefik；或
   - 在公司内部 DNS 使用真实域名 + 泛域名证书，配置
     `--certificatesResolvers.<name>.acme` 或挂载已有证书。
   在此之前，浏览器需手动点击「高级 → 继续访问」。

2. **Tailscale 侧确认（如后续再出现超时）**
   在客户端机器执行：
   ```bash
   ip route get 10.0.0.252     # 应走 tailscale0
   ping -c 3 10.0.0.252
   tailscale status            # 子网路由需 advertised 且 approved
   ```
   并在 Tailscale admin console 确认子网路由覆盖 `10.0.0.0/24`。

3. **域名统一**
   prometheus 同时存在 `prometheus.k8s.local` 与 `prom.example.local` 两个主机名，
   grafana 存在 `grafana.example.local` 与 `grafana.k8s.local`。建议统一为一套域名，
   避免后续再出现"改了 match 导致某个域名 404"的问题。

4. **MetalLB 地址池与网卡对应关系**
   `lb-pool-tailscale` 的 IP 落在 eth0 网段却长期只在 eth1 广告，属于配置错位。
   后续新增地址池时，确认 `L2Advertisement.interfaces` 与 IP 所属网卡一致。

---

## 附：本次排查用到的关键命令

```bash
# 1. 总览：pod / ingress / ingressroute
kubectl get pods -A | grep -iE "grafana|traefik"
kubectl get ingressroute -A

# 2. Traefik 日志找根因
kubectl logs -n traefik deploy/traefik | grep -iE "ERR|warn"

# 3. 集群内模拟外部访问（区分集群内/外链路）
kubectl exec -n default netshoot-debug -- \
  curl -sk --resolve grafana.example.local:443:10.0.0.252 https://grafana.example.local/

# 4. 验证 ARP 层（外部超时的决定性证据）
arping -I eth0 -c 3 10.0.0.252
ip neigh show dev eth0 | grep 10.0.0.252

# 5. kube-proxy 是否本地 DNAT（解释"集群内为何正常"）
iptables -t nat -L KUBE-EXTERNAL-SERVICES -n | grep 10.0.0.252

# 6. MetalLB 配置与广播确认
kubectl get ipaddresspool l2advertisement -n metallb-system -o yaml
kubectl logs -n metallb-system -l component=speaker | grep -i announce
```
