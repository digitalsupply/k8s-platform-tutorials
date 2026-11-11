# 网络故障排查：本环境实测

对应教程：[`../../10-network-troubleshooting.md`](../../10-network-troubleshooting.md)。

## 文件

| 文件 | 内容 |
|---|---|
| `baseline.txt` | worker03 地址/路由/ARP、ss、nstat、conntrack、softnet、ethtool |
| `kernel.txt` | somaxconn、syn backlog、tw_reuse、keepalive、端口范围、缓冲区、conntrack |
| `dns-cni.txt` | Pod resolv.conf/ndots、CoreDNS、Cilium 模式、Traefik LB/L2 |
| `mtu.txt` | cilium_host MTU 1500、native routing 路由、Pod IP |

## 关键实测

```text
节点: eth0 10.0.0.124/24, eth1 172.16.1.124/16, default via 10.0.0.1
Pod: 10.244.0.0/16；Service: 10.96.0.0/12；入口 VIP: 10.0.0.252
CNI: Cilium native routing, kube-proxy-replacement=true, kube-proxy DS 不存在
L2: CiliumL2AnnouncementPolicy/traefik-l2
Traefik: LoadBalancer 10.0.0.252, externalTrafficPolicy=Cluster
CoreDNS: 10.96.0.10, 2 副本；Pod ndots:5
```

内核/队列：

```text
somaxconn=4096
tcp_max_syn_backlog=512
tcp_syncookies=1
tcp_tw_reuse=2
tcp_fin_timeout=60
ip_local_port_range=32768-60999（28,232）
tcp_congestion_control=cubic
tcp_keepalive_time=7200
tcp_mtu_probing=0
netdev_max_backlog=1000
nf_conntrack_max=262144 / count≈950
conntrack established timeout=432000（5d）
tcp_rmem max=6MB / rmem_max=208KB（不匹配）
```

队列/丢包：

```text
ss -s: Total ~597, TCP ~499, estab 31, timewait 185
ListenOverflows=0, ListenDrops=0
softnet 第 2 列=0
ethtool rx drops=0
conntrack 使用率 <1%
```

## 结论

- 当前不是丢包/队列瓶颈；主要风险在 DNS ndots、超时层级、keepalive 与 LB idle 不匹配；
- `tcp_max_syn_backlog=512` 偏低，突发 SYN 可能丢；
- `tcp_rmem/wmem max` 与 `rmem_max/wmem_max` 不一致，窗口调优会被 setsockopt 限制；
- Cilium native routing 无封装，MTU 1500；改 tunnel 要同步 CNI MTU/PMTUD。
