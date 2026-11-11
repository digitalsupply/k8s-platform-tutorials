# 15 · 网络故障排查面试题

> 详细证据：[07 网络故障排查](../07-networking/10-network-troubleshooting.md)。

## 1. 起手式四问

**一句话**：影响面、层次、方向、时间点。

**本环境**：先分清 DNS/建连/TLS/TTFB/传输，再看是不是同节点/同 CNI/同 LB。

## 2. 时间特征怎么用

**一句话**：3s 想 SYN 重传，5s 想 DNS，30/60/300s 想 LB/conntrack，RTT 阶梯想重传。

**本环境**：Pod `ndots:5`；Traefik 无显式 timeout；应用 `proxy_read_timeout 600s`。

## 3. `ss -ti` 看什么

**一句话**：rtt、cwnd、retrans、bytes_retrans；单连接信息量最大。

**本环境**：需对具体 dst 跑；当前全局无 ListenOverflow/softnet drop。

## 4. 两个队列

**一句话**：半连接 `tcp_max_syn_backlog`；全连接 `min(listen backlog, somaxconn)`。

**本环境**：somaxconn 4096；syn backlog 512。

## 5. 全连接队列溢出为什么不是报错

**一句话**：内核静默丢 ACK，客户端重传，所以表现为延迟/偶发超时。

**本环境**：`ListenOverflows=0`，暂无。

## 6. TIME_WAIT 大量怎么办

**一句话**：先改连接池/keepalive/长连接，再谈 `tcp_tw_reuse`；不要提 `tcp_tw_recycle`。

**本环境**：TIME_WAIT 185，正常；`tcp_tw_reuse=2`。

## 7. CLOSE_WAIT 大量

**一句话**：本地应用没 `close()`，是代码/连接泄漏，不是内核。

**本环境**：CLOSE_WAIT=1，观察是否增长。

## 8. `tcp_fin_timeout` 能解决 TIME_WAIT 吗

**一句话**：不能，它只影响 FIN_WAIT_2。

**本环境**：60s，TIME_WAIT 仍 2MSL。

## 9. DNS ndots:5

**一句话**：短域名先套 search 域，查询数放大；用 `ndots:2` 或 FQDN 尾点。

**本环境**：Pod resolv.conf 是 `ndots:5` + 3 个 search 域。

## 10. DNS 5 秒超时三因

**一句话**：DNAT 后 conntrack UDP 竞态、CoreDNS 上游超时、UDP 丢包。

**本环境**：CoreDNS 2 副本，Service 10.96.0.10。

## 11. 502 vs 504 vs 499

**一句话**：502 上游断/非法响应；504 上游慢；499 客户端先断。

**本环境**：compassio nginx `proxy_read_timeout 600s`，注意超时倒挂。

## 12. 超时层级

**一句话**：客户端 > LB > Ingress > 应用 > DB，严格递减。

**本环境**：应用 600s，若客户端 30s 会先 499。

## 13. keepalive 三处

**一句话**：客户端→LB、LB→upstream、应用→下游；idle 下游 < 上游。

**本环境**：`tcp_keepalive_time=7200`，大于典型 LB idle，可能复用死连接。

## 14. 为什么偶发 502

**一句话**：上游先关连接（优雅退出缺失/idle 倒挂/keepalive 脏连接）。

**本环境**：Traefik + nginx，发布期要重点看。

## 15. externalTrafficPolicy

**一句话**：`Local` 保源 IP 但无 Pod 节点丢包/分布不均；`Cluster` 可能 SNAT。

**本环境**：Traefik `externalTrafficPolicy=Cluster`，L4 源 IP 不一定保留。

## 16. kube-proxy vs Cilium

**一句话**：kube-proxy 写 iptables/IPVS/nftables；Cilium KPR 用 eBPF map。

**本环境**：`kube-proxy-replacement=true`，kube-proxy DS 不存在。

## 17. L2 vs MetalLB

**一句话**：L2 宣告用 ARP/NDP 把 VIP 引到节点；MetalLB 也可 L2/BGP。

**本环境**：Cilium L2，`traefik-l2` 宣告 10.0.0.252。

## 18. MTU 黑洞

**一句话**：小包通、大包死；`ping -M do -s 1472` 二分，放行 ICMP type3/code4。

**本环境**：native routing，cilium_host MTU 1500，无封装。

## 19. Pod 互不通排查顺序

**一句话**：Endpoints → 同/跨节点 → NetworkPolicy → 路由/ARP → 两端抓包 → MTU → conntrack/端口。

**本环境**：23 条 NetworkPolicy，仅 1 个全选隔离，默认不是全 deny。

## 20. 端口/conntrack 容量

**一句话**：端口 28,232、conntrack 262,144、fd 三者取最小。

**本环境**：`32768-60999`，conntrack 使用 <1%。

## 21. 30 秒总回答

```text
先分影响面/层次/方向/时间点；3s 想 SYN，5s 想 DNS，30/60/300 想 LB/conntrack。
TCP 看 ss -s、ss -lntp、ss -ti；全连接队列溢出会静默丢 ACK。
TIME_WAIT 先改连接池；CLOSE_WAIT 是应用没 close；fin_timeout 不管 TIME_WAIT。
DNS 看 ndots/search，5s 三因；HTTP 502 上游断、504 上游慢、499 客户端断；
超时层级严格递减，keepalive 下游 < 上游。
K8s 看 Endpoints/NetworkPolicy/路由/MTU；Cilium KPR 用 eBPF，不用 kube-proxy。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| 四问 | 影响面/层次/方向/时间 |
| 3s | SYN 重传 |
| 5s | DNS |
| 30/60/300 | LB/conntrack |
| ss -ti | rtt/cwnd/retrans |
| 两个队列 | syn backlog / accept |
| 溢出 | 静默丢 ACK |
| TIME_WAIT | 先连接池 |
| CLOSE_WAIT | 应用没 close |
| fin_timeout | 不管 TIME_WAIT |
| ndots | search 放大 |
| 502/504/499 | 上游断/慢/客户端断 |
| 超时 | 严格递减 |
| keepalive | 下游 < 上游 |
| externalTrafficPolicy | Local 保源 IP |
| Cilium KPR | eBPF 代替 kube-proxy |
| MTU | 小包通大包死 |
| Pod 不通 | Endpoints→策略→路由→抓包 |
| 容量 | 端口/conntrack/fd |
