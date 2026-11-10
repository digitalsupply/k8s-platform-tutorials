# 07 · Networking：Traefik、Service、DNS、隧道与封装

## 当时的情况

集群入口和网络经历了几次变化：

- 入口从早期 MetalLB + Traefik，演进到 **Cilium L2 Announcements + Traefik**；
- Traefik `v3.7.17` 统一承接 `10.0.0.252:80/443`；
- 所有 Web UI 用 **IngressRoute**（Traefik CRD），不是 Kubernetes Ingress；
- Service 数据面从 kube-proxy IPVS → iptables → **Cilium eBPF**；
- 外部访问还混用 **Cloudflare Tunnel**、Tailscale、内网路由；
- 集群 DNS 曾出现 CoreDNS 解析异常、`ndots`/search 域导致的跨命名空间访问问题。

典型问题：

- `kubectl get ingress` 为空，以为“没有入口”；
- 改了 IngressRoute 但 404，原因是 Host 规则或命名空间不对；
- `https://grafana...` 能开，`http://...` 不跳转，或只对一个域名跳转；
- NodePort 能通、LoadBalancer VIP 不通，或反过来；
- Pod 内解析 `n8n-svc.n8n.svc.cluster.local` 慢/失败；
- Cloudflare Tunnel 断线后告警发不出去；
- kube-proxy 切 nftables 后规则为空，Service 全挂。

## 主要概念与原理

### 1. 请求进入集群的完整路径

```text
客户端
  │ DNS 解析到 10.0.0.252
  ▼
Cilium L2 宣告（ARP/NDP）→ 节点 eth0
  ▼
Traefik Service（LoadBalancer，10.0.0.252:80/443）
  ▼
Traefik Pod（entryPoints: web/websecure）
  ▼
IngressRoute 匹配 Host/Path
  ▼
后端 Service（ClusterIP）→ Cilium eBPF LB → Pod
```

### 2. Traefik 的 entryPoint / router / service

- **entryPoints**：`web`（80，通常只做跳转）、`websecure`（443）；
- **IngressRoute**：`routes[].match` 是 Traefik 规则（`Host()`、`PathPrefix()`）；
- **services**：指向同命名空间的 Service 和 **Service 端口**（不是容器端口）；
- **middlewares**：RedirectScheme、BasicAuth、stripPrefix 等；
- **tls: {}**：用 Traefik 默认自签名证书；指定 `secretName` 才用真实证书。

### 3. IngressRoute 的命名空间约束

IngressRoute 必须和后端 Service **在同一个命名空间**。跨命名空间需要 ExternalName Service
或 Traefik 的 `allowCrossNamespace`（默认关闭）。

### 4. Service 的四种类型

| 类型 | 作用 | 本集群 |
|---|---|---|
| ClusterIP | 集群内虚拟 IP | 大多数服务 |
| NodePort | 每节点 30000–32767 | Traefik 30156/30306 |
| LoadBalancer | 外部 LB + VIP | Traefik `10.0.0.252` |
| ExternalName | CNAME 到外部域名 | 少量 |

### 5. kube-proxy / iptables / eBPF 的分工

- **Service** 只是抽象（VIP + 端口 + selector），本身不转发；
- **kube-proxy** watch API，把 Service 翻译成 iptables/IPVS/nftables 规则；
- **Cilium KPR** 则把 Service 翻译成 eBPF Map，在 socket/TC 层完成 DNAT。

### 6. IPIP 与 VXLAN

| 封装 | 开销 | MTU | 特点 |
|---|---|---|---|
| IPIP | 20 字节外层 IP | 通常 1480 | 简单、只支持 IPv4/IPv6 单协议 |
| VXLAN | 8 字节头 + 14 字节以太网 + 外层 IP/UDP | 通常 1450 | 支持二层扩展、VNI 隔离 |

本集群 Calico 时期用 IPIP Always，Pod MTU 1480；切 Cilium native routing 后恢复 1500。

### 7. DNS 的 search 域与 ndots

Pod 的 `/etc/resolv.conf` 默认：

```text
search <ns>.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

访问 `n8n-svc.n8n.svc.cluster.local` 会先尝试多个 search 后缀；如果 CoreDNS 慢或
NetworkPolicy 挡了 53 端口，就会出现“短域名能通、长域名超时”或相反。

## 踩坑点

### 坑 1：Traefik 环境没有 Ingress

`kubectl get ingress -A` 为空是正常的，入口在 `kubectl get ingressroute -A`。
同理，改 Ingress 不会影响 Traefik 路由。

### 坑 2：IngressRoute 的 Host 用反引号

```yaml
match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
```

Host 内必须是反引号；写成单引号/双引号会导致规则解析失败或 404。

### 坑 3：端口写成了容器端口

IngressRoute 的 `services[].port` 是 **Service 的 port**，不是 Pod 的 `containerPort`。
例如 Grafana Service 是 `80 → 3000`，这里必须写 `80`。

### 坑 4：双域名只改了 HTTPS，没改 HTTP 跳转

Grafana/Prometheus 有 `*.example.local` 和 `*.k8s.local` 两个域名。
HTTPS 主路由用 `||` 同时匹配，但 HTTP 跳转路由只写了其中一个，导致另一个域名
`http://` 访问不跳转。修复时要同时改主路由和跳转路由。

### 坑 5：IngressRoute 与后端不在同一命名空间

IngressRoute 在 `monitoring`，后端 Service 在 `monitoring` 才行。
把 IngressRoute 放到 `default` 指向 `monitoring/prometheus-grafana` 会 404。

### 坑 6：NodePort 通但 VIP 不通

- VIP 由 MetalLB 分配、Cilium L2 宣告；
- 如果宣告节点没有到 VIP 的 ARP/NDP，客户端会超时；
- `externalTrafficPolicy: Local` 时，只有运行 Traefik Pod 的节点能承接；
- 检查 `CiliumL2AnnouncementPolicy` 的 nodeSelector 和 `kubectl get svc traefik`。

### 坑 7：kube-proxy nftables 模式规则为空

本集群曾切到 `--proxy-mode=nftables`，但 `nft list ruleset` 里没有 `KUBE-SERVICES`，
`kube-proxy` 退出码 139。结果 Service 全部不可用。

**修复**：回退 iptables；确认内核 `nf_tables`、`nft` 版本、kube-proxy 版本兼容，
再考虑 nftables。不要在生产直接切。

### 坑 8：Cloudflare Tunnel 断线导致告警静默

n8n 曾通过 Cloudflare Tunnel 暴露给 Alertmanager。Tunnel 断线后 webhook 失败
（`connection reset by peer` 累计 2160 次），但告警本身没有“出口不可用”的告警。

**修复**：告警出口双通道（企业微信直连 + n8n），并给 webhook 失败率加告警；
隧道只作为备用，不作为唯一出口。

### 坑 9：DNS 排障只看 CoreDNS Pod Running

CoreDNS Running 不代表解析正常。要测：

```bash
kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- \
  nslookup n8n-svc.n8n.svc.cluster.local
```

并检查 NetworkPolicy 是否放行 UDP/TCP 53。

## 修复关键

1. **先画链路**：DNS → VIP → L2 宣告 → Traefik → IngressRoute → Service → Pod；
2. **逐层验证**：`dig`/`nslookup` → `curl -v --resolve` → `kubectl port-forward` → Pod 内 curl；
3. **IngressRoute 改动后用 `traefik` dashboard/API 确认路由已加载**；
4. **统一入口**：所有 UI 走 Traefik + IngressRoute，不再混用 NodePort/Ingress；
5. **VIP 只保留一个宣告者**：Cilium L2 与 MetalLB Speaker 不要同时宣告同一 IP；
6. **DNS 与 NetworkPolicy 一起改**：放行 53 端口，避免“CoreDNS 正常但客户端解析失败”；
7. **隧道只做备用**：关键告警出口必须直连或有第二通道。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [traefik-routing-architecture.md](notes/traefik-routing-architecture.md) | 所有 IngressRoute 的域名、后端、TLS、访问链路 |
| [ingressroute-fix-summary.md](notes/ingressroute-fix-summary.md) | IngressRoute 域名修复记录 |
| [loadbalancer-ip-summary.md](notes/loadbalancer-ip-summary.md) | LoadBalancer IP、端口映射、MetalLB 配置 |
| [dns-test-results.md](notes/dns-test-results.md) | DNS 测试数据与推荐方案 |
| [cloudflared-troubleshooting.md](notes/cloudflared-troubleshooting.md) | Cloudflare Tunnel 故障排查 |
| [ipip-vs-vxlan-explained.md](notes/ipip-vs-vxlan-explained.md) | IPIP/VXLAN 封装、MTU 与本集群配置 |
| [kube-proxy-service-iptables-explained.md](notes/kube-proxy-service-iptables-explained.md) | Service/kube-proxy/iptables 的完整数据流 |
| [kube-proxy-nftables-diagnosis.md](notes/kube-proxy-nftables-diagnosis.md) | nftables 模式规则为空的诊断与回退 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/current-ingressroutes.yaml](assets/current-ingressroutes.yaml) | 当前全部 IngressRoute |
| [assets/current-traefik-service.yaml](assets/current-traefik-service.yaml) | 当前 Traefik LoadBalancer Service |
| [assets/current-metallb-config.yaml](assets/current-metallb-config.yaml) | 当前 MetalLB IPAddressPool/L2Advertisement |
| [assets/metallb-config-backup.yaml](assets/metallb-config-backup.yaml) | MetalLB 配置备份 |
| [assets/traefik-svc-backup.yaml](assets/traefik-svc-backup.yaml) | Traefik Service 备份 |

```bash
# 查看入口（不要只看 ingress）
kubectl get ingressroute -A
kubectl -n traefik get svc traefik

# 本机验证 Host 路由（不依赖 DNS）
curl -vk --resolve grafana.example.local:443:10.0.0.252 https://grafana.example.local/

# 查看 Traefik 已加载的路由
kubectl -n traefik port-forward svc/traefik-api 9000:9000
curl -s localhost:9000/api/http/routers | jq .
```

> 所有域名/IP 都是实验环境地址，使用前替换成你的环境。
