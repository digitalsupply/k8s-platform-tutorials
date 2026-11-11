# 10 · 网络故障排查：从时间特征到内核/CNI/入口

> 本章基于用户提供的《网络故障排查速查笔记（A4 · 4 页）》抽取结构，
> 结合本集群 2026-11-11 的实际配置与命令输出重写：
> Cilium native routing + KPR、Traefik L2 VIP、CoreDNS、10.0.0.0/24 节点网段。
>
> 原笔记的 14 节（起手式、TCP 状态、内核参数、命令卡、判读表、DNS、HTTP/TLS、
> LB、容器/MTU、指标、容量、12 场景、黑名单、复习顺序）都保留，但数字换成本环境实测。
>
> 证据：[`assets/network-troubleshooting/`](assets/network-troubleshooting/README.md)。

## 0. 本环境链路与关键值

```text
客户端
  → DNS（deeptutor.xyz / *.example.local）
  → Traefik LB 10.0.0.252:80/443（Cilium L2 宣告）
  → Traefik Pod（entryPoints web/websecure）
  → IngressRoute
  → Service ClusterIP（Cilium eBPF KPR）
  → Pod（10.244.x.x，native routing）
```

| 项 | 实测 |
|---|---|
| 节点网段 | `10.0.0.0/24`，worker03 `eth0=10.0.0.124/24`，`eth1=172.16.1.124/16` |
| 默认网关 | `10.0.0.1` |
| Pod CIDR | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` |
| API VIP | `10.0.0.168:6443` |
| 入口 VIP | `10.0.0.252:80/443` |
| CNI | Cilium `routing-mode=native`、`kube-proxy-replacement=true` |
| kube-proxy | **DaemonSet 不存在**（KPR 取代） |
| L2 宣告 | `enable-l2-announcements=true`，`CiliumL2AnnouncementPolicy/traefik-l2` |
| CoreDNS | `10.96.0.10`，2 副本 |
| Traefik Service | `LoadBalancer`，`externalTrafficPolicy=Cluster` |
| Pod DNS | `search compassio.svc.cluster.local svc.cluster.local cluster.local`，`ndots:5` |

## 1. 起手式：四个问题 + 时间特征

| 维度 | 要确认 |
|---|---|
| 影响面 | 单 Pod / 同节点 / 同 AZ / 全区域 / 特定客户端 |
| 层次 | DNS → 建连 → TLS → 首字节 → 传输 |
| 方向 | 入向（LB/NodePort/Ingress）还是出向（NAT/对端） |
| 时间点 | 何时开始 + 最近变更（发布、证书、路由、CNI、DNS） |

时间特征：

| 现象 | 大概率原因 | 本环境对应 |
|---|---|---|
| 几十 ms 卡顿 | Nagle+延迟 ACK、GC、单次排队 | 应用/GC 先看 |
| 约 3s | SYN 重传（1s+2s） | SYN 被丢、backlog、策略 |
| 约 5s | DNS UDP 重传 / conntrack / CoreDNS 上游 | `ndots:5` + 3 个 search 域会放大 |
| 30/60/300s | LB idle、conntrack、NAT 老化 | Traefik 未显式 timeout；应用 `proxy_read_timeout 600s` |
| 与 RTT 成倍阶梯 | TCP 重传/快重传 | `ss -ti` 看 retrans/rtt |
| 锯齿不回落 | 重试风暴/端口/conntrack 耗尽 | 看 `nstat`、端口范围 28,232 |

> 本环境最容易误判的是 DNS：`ndots:5` 让 `api.example.com` 先查 3 个 search 域，
> 再查真实域名，首次解析延迟和 CoreDNS QPS 都会被放大。

## 2. TCP 状态与两个队列

本环境 worker03 实测：

```text
ss -s:
  Total 597, TCP 499 (estab 31, closed 453, timewait 184)
  TIME_WAIT 185
  CLOSE_WAIT 1
```

| 状态/队列 | 含义 | 本环境 |
|---|---|---|
| `SYN_SENT` | 出向建连中；长期停留=不可达/策略 | 未大量 |
| `SYN_RECV` | 半连接堆积=SYN Flood/对端不回 ACK | 未大量 |
| `ESTABLISHED` | `Recv-Q>0` 持续=应用读得慢 | 29 条，未见异常 |
| `FIN_WAIT_1/2` | `FIN_WAIT_2` 多=对端不 close | 未大量 |
| `TIME_WAIT` | 主动关闭方等 2MSL（60s） | 177，正常 |
| `CLOSE_WAIT` | 本地应用没 `close()` | 1，需观察是否增长 |
| 半连接队列 | `tcp_max_syn_backlog` | **512** |
| 全连接队列 | `min(listen backlog, somaxconn)` | `somaxconn=4096` |

关键判读：全连接队列溢出时内核默认静默丢 ACK，客户端靠重传补救，
所以现象是**延迟升高/偶发超时，而不是连接报错**。

本环境：

```text
nstat:
  TcpExtListenOverflows = 0
  TcpExtListenDrops     = 0
  TcpExtTCPTimeouts     = 633（累计）
  TcpExtTCPAbortOnClose = 102620（累计）
softnet_stat 第 2 列 = 0
ethtool rx drops = 0
```

## 3. 内核参数：原笔记建议 vs 本环境

| 参数 | 原笔记建议 | 本环境实测 | 评价 |
|---|---|---|---|
| `net.core.somaxconn` | 4096+ | **4096** | 达标 |
| `net.ipv4.tcp_max_syn_backlog` | 8192 | **512** | 偏低，突发 SYN 可能丢 |
| `net.ipv4.tcp_syncookies` | 1 | **1** | 达标 |
| `net.ipv4.tcp_abort_on_overflow` | 0 | 未显式（默认 0） | 容忍，靠重传 |
| `net.ipv4.tcp_tw_reuse` | 1 | **2** | 已启用；需时间戳/仅出向 |
| `net.ipv4.tcp_tw_recycle` | 已移除 | 不存在 | 不要提 |
| `net.ipv4.tcp_fin_timeout` | 只影响 FIN_WAIT_2 | **60** | 不改变 TIME_WAIT |
| `net.ipv4.ip_local_port_range` | 1024–65535 | **32768–60999**（28,232 个） | 出向高并发可能耗尽 |
| `net.ipv4.tcp_congestion_control` | BBR（跨区域） | **cubic** | 内网可接受；跨境再评估 |
| `net.ipv4.tcp_keepalive_time` | 7200→300 | **7200** | **大于 LB idle，可能复用死连接** |
| `net.ipv4.tcp_keepalive_intvl/probes` | — | 75 / 9 | 默认 |
| `net.ipv4.tcp_rmem` | 三值 | 4096/131072/**6291456** | max 6MB |
| `net.core.rmem_max` | 与 tcp_rmem 匹配 | **212992** | **不匹配**，setsockopt 受限 |
| `net.ipv4.tcp_wmem` | 三值 | 4096/16384/**4194304** | max 4MB |
| `net.core.wmem_max` | 与 tcp_wmem 匹配 | **212992** | **不匹配** |
| `net.netfilter.nf_conntrack_max` | 与 hashsize 1:4 | **262144** | 当前 1010，余量足 |
| `net.netfilter.nf_conntrack_tcp_timeout_established` | 低于 LB idle | **432000（5d）** | 过长，可能保留死会话 |
| `net.ipv4.tcp_mtu_probing` | 1（最后手段） | **0** | native MTU 1500，暂可 |
| `net.core.netdev_max_backlog` | 视 PPS | **1000** | 当前无 drop，需监控 |
| `net.ipv4.tcp_max_tw_buckets` | — | **32768** | 默认 |

结论：

- 本环境 **somaxconn 够、syncookies 开、conntrack 余量足、无 ListenOverflow/softnet drop**；
- 但 `tcp_max_syn_backlog=512` 偏低、`tcp_keepalive_time=7200` 与 LB idle 不匹配、
  `tcp_rmem/wmem max` 与 `rmem_max/wmem_max` 不一致；
- 这些不是“立刻故障”，而是**高并发/长连接/跨 LB 场景的隐患**。

## 4. 命令卡片（按现场顺序）

### A. 链路与地址

```bash
ip -br a
ip r; ip -6 r
ip neigh
ip route get 10.0.0.5
ethtool eth0 | head -20
ethtool -S eth0 | grep -Ei 'drop|err|miss|no_buffer'
```

本环境 worker03：

```text
eth0 10.0.0.124/24
eth1 172.16.1.124/16
default via 10.0.0.1 dev eth0
10.244.0.0/24 via 10.0.0.61
10.244.1.0/24 via 10.0.0.121
10.244.2.0/24 via 10.0.0.120
10.244.3.0/24 via 10.0.0.122
10.244.4.0/24 via 10.0.0.123
10.244.5.0/24 via 10.244.5.157 dev cilium_host
cilium_host mtu 1500
```

`ip route get 10.96.0.10` 显示经默认网关，但 **Service VIP 的实际 DNAT 在 Cilium eBPF**，
不能只看路由表判断数据面。

### B. 连接与状态

```bash
ss -s
ss -lntp
ss -tan state time-wait | wc -l
ss -tan state close-wait | head
ss -ti dst 10.0.0.5
lsof -i :8080; fuser -n tcp 8080
```

本环境：

```text
ss -s: Total 599, TCP 491, estab 29, timewait 176
ss -lntp: Send-Q 4096（cilium/kubelet），128（sshd）
```

`ss -ti` 看 `rtt/cwnd/retrans/bytes_retrans`，是单连接信息量最大的命令。

### C. 统计与丢包

```bash
nstat -az | egrep 'Retrans|Overflow|Drop|Listen'
netstat -s | egrep -i 'retrans|overflow|prune|drop'
cat /proc/net/softnet_stat | awk '{print $1,$2,$3}'
grep NET_RX /proc/softirqs
cat /proc/sys/net/netfilter/nf_conntrack_count
conntrack -S
sar -n DEV 1 3
```

本环境：

```text
ListenOverflows=0, ListenDrops=0, TCPTimeouts=633（累计）
softnet 第 2 列=0
conntrack count=953 / max=262144
```

### D. 抓包（只看三件事）

```bash
tcpdump -i any -nn -s0 -w a.pcap 'host 10.0.0.5 and port 8080'
tcpdump -i eth0 -nn 'tcp[tcpflags] & (tcp-rst) != 0'
tcpdump -i eth0 -nn 'icmp and icmp[icmptype]==3'
tshark -r a.pcap -q -z conv,tcp
```

三件事：谁先 RST、有无重传、有无零窗口。

### E. DNS

```bash
dig +trace +nodnssec example.com
dig @10.96.0.10 api.svc.cluster.local +noall +answer +stats
dig example.com +short; getent hosts example.com
cat /etc/resolv.conf
for i in $(seq 50); do dig +tries=1 +time=1 example.com | grep 'Query time'; done
```

本环境 Pod：

```text
search compassio.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

CoreDNS 2 副本，Service `10.96.0.10`。

### F. 容器 / K8s

```bash
kubectl get pod -o wide
kubectl get ep <svc>
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl run -it --rm dbg --image=nicolaka/netshoot -- bash
PID=$(crictl inspect <cid> | jq .info.pid)
nsenter -t $PID -n tcpdump -i eth0 -nn
hubble observe --pod <pod> --follow
```

本环境：

```text
Cilium native routing：同节点走 lxc veth，跨节点走 10.244.x/24 via 节点 IP
无 kube-proxy DaemonSet；KPR=true
Traefik Service：10.0.0.252，externalTrafficPolicy=Cluster
L2：CiliumL2AnnouncementPolicy/traefik-l2
```

> Cilium KPR 取代 kube-proxy 后，kube-prometheus-stack 曾因 `kubeProxy.enabled: true`
> 保留无 endpoints 的 `prometheus-kube-proxy` Service/ServiceMonitor/Rule；
> 已于 2026-11-11 关闭并清理。详见
> [04 可观测性 4.4](../04-monitoring-gitops/10-observability-engineering.md)。

### G. 链路质量与故障注入

```bash
mtr -rwzbc 100 <host>
iperf3 -c <host> -t 10 -P 4
tc qdisc add dev eth0 root netem delay 100ms 20ms loss 1%
tc -s qdisc show dev eth0
```

## 5. 判读表

| 输出信号 | 结论 | 本环境 |
|---|---|---|
| `ss -ti` retrans>0，rtt 正常 | 链路丢包/限速 | 需单连接抓包 |
| `ss -ti` rtt 升高 + retrans | 拥塞/排队/跨区 | cubic，内网 |
| `ESTABLISHED Recv-Q` 持续>0 | 应用读得慢 | 看应用 |
| `ss -lnt Recv-Q` 接近 Send-Q | accept 队列满 | 当前 0/4096 |
| `nstat ListenOverflows>0` | 全连接队列溢出 | **0** |
| `softnet_stat` 第 2 列增长 | 内核收包队列丢包 | **0** |
| `rx_missed_errors`/`rx_no_buffer` | 网卡/中断不足 | **0** |
| `conntrack_count` 接近 max | 即将丢包 | 953/262144 |
| `nf_conntrack: table full` | 已丢包 | 未出现 |

## 6. DNS：ndots:5 的放大效应

本环境 Pod 的 `/etc/resolv.conf`：

```text
search compassio.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

查 `api.example.com`（ndots=5，3 个 search 域）：

```text
api.example.com.compassio.svc.cluster.local.  NXDOMAIN
api.example.com.svc.cluster.local.            NXDOMAIN
api.example.com.cluster.local.                NXDOMAIN
api.example.com.                              ← 真实查询
```

结果：查询数 ×4，首次解析延迟翻倍，CoreDNS QPS 虚高，日志刷 NXDOMAIN。

优化：

- `dnsConfig` 设 `ndots: 2`；
- 代码里用带尾点的 FQDN（`api.example.com.`）直接绝对查询；
- NodeLocal DNSCache + CoreDNS cache；
- 注意 glibc vs musl（Alpine）vs Go 解析器差异；
- 5 秒超时三因：DNAT 后 conntrack UDP 竞态、CoreDNS 上游超时、UDP 丢包。

本环境 CoreDNS 2 副本，`getent hosts kubernetes.default.svc.cluster.local` 正常。

## 7. HTTP / TLS / 超时层级

| 状态码 | 谁产生 | 首查 |
|---|---|---|
| 502 | 网关收到上游非法响应/连接被重置 | 上游优雅退出、keepalive idle 倒挂、进程重启 |
| 503 | 无可用后端 | 健康检查、Endpoints 为空、限流 |
| 504 | 网关等上游超时 | 上游慢、连接池满、重试风暴 |
| 499 | Nginx 专有：客户端先断开 | 客户端超时 < 服务端 |

本环境：

```text
compassio-frontend nginx: proxy_read_timeout 600s
Traefik args: 未显式设置 respondingTimeouts
kubelet/应用: 需按链路核对
```

超时层级应严格递减：

```text
客户端 30s > LB 25s > Ingress 20s > 应用 15s > DB 10s
```

反例：网关 600s、客户端 30s → 客户端放弃后网关还等，499/资源浪费。

keepalive 三处都要配：客户端→LB、LB→upstream、应用→下游连接池；
idle timeout 必须“下游 < 上游”，否则复用已关闭连接 → 发布期偶发 502。

## 8. 负载均衡与端口

| LVS 模式 | 回程 | 保源 IP | 约束 |
|---|---|---|---|
| NAT | 经 LB | 否（需 TOA） | LB 带宽瓶颈 |
| DR | 直接回客户端 | 是 | 同二层；lo VIP + arp_ignore |
| TUN | 直接回客户端 | 是 | IP 隧道 |

本环境不是 LVS，而是 **Cilium eBPF KPR + L2 Announcement**：

```text
Traefik Service LoadBalancer 10.0.0.252
externalTrafficPolicy=Cluster
CiliumL2AnnouncementPolicy/traefik-l2
无 kube-proxy DaemonSet
```

`externalTrafficPolicy: Cluster` 下 L4 源 IP 不一定保留；
需要真实客户端 IP 时：

- `Local`（代价：无 Pod 节点丢包/分布不均）；
- L7 用 XFF，但只信任可信代理链；
- Cilium LB 的 DSR/源 IP 模式按版本确认。

端口：

```text
ip_local_port_range = 32768–60999 = 28,232 个
tcp_max_tw_buckets = 32768
nf_conntrack_max = 262144
```

短连接打满端口会报 `cannot assign requested address`，先改连接池/长连接。

## 9. 容器 / K8s 网络与 MTU

本环境路径：

```text
Pod eth0 → veth/lxc → cilium_host（10.244.5.157/32）
  → 同节点：lxc veth
  → 跨节点：10.244.x/24 via 节点 IP（native routing）
  → Service：Cilium eBPF DNAT（KPR）
```

MTU：

```text
cilium_host mtu 1500
native routing，无 VXLAN/IPIP 封装
```

对比：

| 模式 | 封装开销 | Pod MTU |
|---|---:|---:|
| Calico BGP underlay | 0 | 1500 |
| Calico IPIP | 20B | 1480 |
| VXLAN | 50B | 1450 |
| Cilium tunnel | 50B | 1450 |
| 云底层 1450 + VXLAN | +50B | 1400 |

Pod 互不通排查顺序：

```text
① Pod Ready / Endpoints
② 同节点还是跨节点
③ NetworkPolicy（选中但无 allow = 全拒；未选中 = 全通；别忘了 DNS egress）
④ 宿主路由 / ARP（ip r / ip neigh）
⑤ 两端 veth 抓包，看包在哪侧消失
⑥ MTU（大包）
⑦ conntrack 满 / 端口耗尽
⑧ 云安全组放行 Pod 网段
```

MTU 黑洞：

```bash
ping -M do -s 1472 <ip>     # 1472+28=1500，二分
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu
```

本环境 native MTU 1500，暂无封装；若改 tunnel 要同步 CNI MTU 和 PMTUD。

## 10. 指标 → 根因

| 指标 | 异常含义 | 首查 |
|---|---|---|
| TCP 重传率 >0.5% | 丢包/限速 | 中间设备、跨 AZ |
| RST 突增 | 后端重启、LB 摘除、conntrack 清理 | 发布事件 |
| DNS P99 + NXDOMAIN 齐升 | ndots/search、CoreDNS 过载 | resolv.conf、副本/缓存 |
| conntrack 使用率 >80% | 长连接泄漏/扫描 | top 会话 |
| ListenOverflow>0 | accept 慢 | 线程模型、somaxconn |
| LB 5xx 按 502/504 拆 | 502=上游断，504=上游慢 | 两条链路 |
| 节点 rx_drop>0 | 软中断/网卡不足 | 多队列、RPS/RFS |
| 跨 AZ RTT 抖动 | 路由/运营商绕行 | mtr 跳点 |

本环境：`ListenOverflows=0`、`softnet drop=0`、`rx drops=0`、`conntrack 0.39%`，
说明当前不是容量/丢包问题，更多要看 DNS/入口/应用。

## 11. 容量与公式

| 度量 | 公式/经验值 | 本环境 |
|---|---|---|
| BDP | 带宽 × RTT | 1Gbps × 1ms ≈ 125KB |
| 单流吞吐 | 窗口 / RTT | 窗口不够跑不满长肥管道 |
| 小包 PPS | 1Gbps + 64B ≈ 1.49Mpps | 小包先撞 PPS |
| 可用端口 | `ip_local_port_range` 长度 | 28,232 |
| 连接上限 | min(fd, 内存, conntrack) | conntrack 262,144 |

## 12. 十二个场景的一句话答法

| 场景 | 答法 |
|---|---|
| P99 超时但 CPU/内存正常 | 按 DNS/建连/TLS/TTFB/传输分桶 → `ss -ti` + tcpdump |
| 偶发 502 | 上游先关连接：优雅退出、idle 倒挂、keepalive 脏连接 |
| 偶发 504 | 上游慢 + 超时层级倒挂 + 重试放大 |
| TIME_WAIT 大量 | 先改连接池/keepalive/长连接，再谈 tw_reuse |
| CLOSE_WAIT 大量 | 代码没 close()，查连接泄漏 |
| DNS 解析慢 5s | ndots/search、conntrack UDP、musl vs glibc |
| Pod 之间不通 | Endpoints → 同/跨节点 → NetworkPolicy → 路由 ARP → 抓包 |
| 大文件上传失败 | MTU/PMTUD 黑洞 |
| 并发上不去 | 端口耗尽 + conntrack + fd |
| 跨机房延迟抖动 | mtr 跳点 + BBR + BDP/窗口 |
| 发布后小比例报错 | 连接复用/h2/SNI/会话保持/旧 Pod IP |
| 拿不到真实 IP | externalTrafficPolicy/DR/XFF 信任链 |

## 13. 面试黑名单

- “先开 `tcp_tw_recycle=1`” —— 已移除，NAT 会误杀；
- “调 `tcp_fin_timeout` 解决 TIME_WAIT” —— 只影响 FIN_WAIT_2；
- “加 backlog 就好了” —— 不看 accept 速度只是拖延；
- “DNS TTL 设 0 便于切换” —— 放大解析 QPS；
- “ping 不通就是 TCP 不通” —— 策略可能只拦 ICMP，反之亦然。

## 14. 复习优先顺序

1. TCP 状态机 + 两个队列 + `ss -ti` 三件套；
2. DNS `ndots/search` 与容器解析链路；
3. K8s 网络路径 + MTU + 抓包；
4. conntrack / iptables / IPVS / eBPF 原理与容量；
5. HTTP 状态码 + 连接池 + 超时层级；
6. L4/L7 选型、云网络、PPS 与成本；
7. 内核参数细节（最后看，先说“先改架构再调参”）。

## 15. 一页命令

```bash
# 链路
ip -br a; ip r; ip neigh; ip route get <ip>
ethtool -S eth0 | grep -Ei 'drop|err|miss|no_buffer'

# 连接/队列
ss -s; ss -lntp
ss -tan state time-wait | wc -l
ss -tan state close-wait | head
ss -ti dst <ip>

# 丢包/容量
nstat -az | egrep 'Retrans|Overflow|Drop|Listen'
cat /proc/net/softnet_stat
cat /proc/sys/net/netfilter/nf_conntrack_count
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
  net.ipv4.tcp_keepalive_time net.ipv4.ip_local_port_range

# DNS
cat /etc/resolv.conf
dig @10.96.0.10 api.svc.cluster.local +noall +answer +stats

# K8s
kubectl get pod -o wide; kubectl get ep <svc>
kubectl get networkpolicy -A
hubble observe --pod <pod> --follow
```
