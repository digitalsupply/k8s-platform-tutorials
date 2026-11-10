> 教程仓库说明：为控制体积并避免公开抓包数据，本目录只保留实验 README、
> analyzer 脚本和小型证据文本；原始 `pcaps/`、`mon/` 数据未包含。

# Cilium eBPF 数据面穿越实验：实机验证报告

实验设计依据：`/root/实验-Hubble-LB-ipcache-tcpdump穿越跟踪.md`
本目录为实机执行后归档的所有证据与脚本。

## 1. 集群事实（本环境实测）

| 项 | 值 |
|---|---|
| 集群 | k3s v1.36.4+k3s1，Cilium 1.20.1，3 节点 |
| 节点 | ubuntu01=192.168.67.201 / ubuntu02=192.168.67.202 / ubuntu03=192.168.67.203 |
| IPAM | cluster-pool，节点 CIDR：.201→10.0.0.0/24，.202→10.0.1.0/24，.203→10.0.2.0/24 |
| 数据面 | `Routing: Network Tunnel[vxlan] Host Legacy`；VXLAN dstport **8472** |
| LB | `Socket LB: Enabled, Coverage: Full`（socket 级选后端） |
| Masquerade | `IPTables [IPv4: Enabled]`（不影响实验对象） |
| 主服务 | `default/nginx` 10.43.66.133:80 → 后端 10.0.2.93:80（nginx-7f8fbb96d-lzw27@.203，revnat=23，slot1） |
| 客户端 | `lab/api-77749c85b4-qbk2n` 10.0.1.137@.202，identity **8219**，endpoint **1817**，镜像 httpd:alpine（wget/nc，无 curl） |
| 后端 | identity **30056**，endpoint **1393**（10.0.2.93@.203） |
| 变体 A | `lab/web` 10.43.162.164:80 → 10.0.1.123（本地.202）+ 10.0.2.178（远端.203），identity **14608** |

cilium pod 按节点名：`cilium-98vtn`@.202、`cilium-wz8bj`@.203、`cilium-q5jp6`@.201。

## 2. 证据面与判据对照（设计 -> 实测）

### 证据面 1：bpf lb list / bpf ipcache list（静态基线）
基线快照见 `lbtables/`、`ipc/`。
- `lb_s202_nginx.txt`：Service 10.43.66.133:80/TCP slot1 → 10.0.2.93:80 revnat=23。
- `ipc_s202.txt`：10.0.1.137 → identity 8219（local）；10.0.2.0/24 与 10.0.2.93 → `tunnelendpoint=192.168.67.203 flags=hastunnel`。
- `ipc_s203.txt`：10.0.2.93 为本地端点 `<none>`。

### 证据面 2：tcpdump 五路同时抓包 pcap/（round 1，25 连发）
抓取点：.202 eth0（外层）/cilium_vxlan（内层）/cilium_host/客户端 veth；.203 eth0/cilium_vxlan/后端 veth。

关键对账（同包逐字节一致）：

| 抓包点 | 内容 | 判据 |
|---|---|---|
| .202 eth0 | `192.168.67.202.X > 192.168.67.203.8472 OTV(flags I)` | 外层 VXLAN，202→203 |
| .202 vxlan | `10.0.1.137.55710 > 10.0.2.93.80 SYN seq=3950726540 TS=3407492508` | 内层已到后端地址 |
| .203 vxlan | 与上**同 seq/同 TS val** | 同一内层包穿越隧道 |
| .203 后端 veth | 收到同 SYN；回程 `10.0.2.93.80 > 10.0.1.137.55710 SYN-ACK seq=2173848320` | 后端正常应答 |
| .202 客户端 veth | 同 SYN-ACK 到达（seq/TS 三处一致） | 隧道往返闭环 |
| .202 cilium_host | **0 包** | 远端后端流量全程 BPF 数据面，零回 host 协议栈 |

### 证据面 3：cilium-dbg monitor（内核事件面）mon/
可用事件：`mon202.jsonl`（会有 2 行启动行与 error 起始行，忽略即可）。
代表性事件（round 2）：
- .202：`trace to-overlay if=cilium_vxlan srcLabel=8219 dstLabel=30056 10.0.1.137->10.0.2.93:80 SYN`
- .203：`trace to-endpoint if=lxc91308ca620b6 8219->30056`（后端口收包）
- .203：`trace to-overlay if=cilium_vxlan 30056->8219 10.0.2.93->10.0.1.137:59704 SYN-ACK`（回程）
- .202：`trace to-endpoint if=lxc2a450382cb83 30056->8219 10.0.2.93->10.0.1.137`（交回客户端）

identity 8219/30056 与 ipcache/endpoint list 完全吻合；mark=0xe05292c2 随隧道载荷传递。

### 证据面 4：socket-LB 的根因定位（本实验最大发现）
补测 `nsenter` 进容器网络栈：容器内 eth0 上 SYN/SYN-ACK 均为后端地址 10.0.2.93（无 ServiceIP）。
决定性证明 `pcap/s202_inside.pcap` + `netstat`：
```
tcp  0  0 10.0.1.137:42413  10.0.2.93:80  ESTABLISHED
```
应用 `nc 10.43.66.133 80`，但内核 socket 实际连接的是 10.0.2.93:80。
结论：**Socket LB（Full）在 connect()/sendmsg 调用点直接选中后端**，包从出生起就带后端地址；
intra-cluster 无 per-packet DNAT/revSNAT/conntrack，故任何抓包点都看不到 ClusterIP——这与
kube-proxy(iptables/ipvs) 模式"应用以为连 ClusterIP、线上却是 Pod IP"截然相反。

变体 A（web Service）佐证：本地后端 10.0.1.123 回包走 `to-endpoint`（无隧道）；
远端 10.0.2.178 走 `to-overlay`（封 VXLAN）。同节点有免隧道直通路径。

## 3. 可复现命令

```bash
# 1) 两节点起 tcpdump（.202 同理换 .203/接口名）
sudo -i bash -c 'nohup tcpdump -nn -i eth0      udp port 8472 -w s202_eth0.pcap >/dev/null 2>&1 &'
sudo -i bash -c 'nohup tcpdump -nn -i cilium_vxlan -w s202_vxlan.pcap >/dev/null 2>&1 &'
sudo -i bash -c 'nohup tcpdump -nn -i lxc2a450382cb83 -w s202_cveth.pcap >/dev/null 2>&1 &'

# 2) 起 monitor（注意 -j，--related-to 用端点 ID，trace 需 -t trace）
kubectl -n kube-system exec cilium-98vtn -- bash -c 'nohup cilium-dbg monitor -j -t trace -t drop --related-to 1817 > /tmp/exp/mon202.jsonl 2>&1 &'

# 3) 发流量（客户端镜像无 curl，用 wget）
kubectl -n lab exec api-77749c85b4-qbk2n -- sh -c \
  'for i in $(seq 1 25); do wget -q -T 2 -O /dev/null http://10.43.66.133/; sleep 0.3; done'

# 4) 收尾：pkill，scp 回 /root/experiment/pcaps，kubectl cp 回 mon/*.jsonl

# 5) 容器内网栈决定性验证
PID=$(crictl inspect <container-id> | jq .info.pid)   # 本实验 api=48385
sudo -i bash -c "nsenter -t $PID -n tcpdump -nn -i eth0 -w inside.pcap tcp port 80 &"
kubectl -n lab exec api-77749c85b4-qbk2n -- sh -c '(sleep 25) | nc 10.43.66.133 80 & sleep 2; netstat -tn | grep ESTABLISHED'
```

## 4. 排障与坑（下次照抄）

- `cilium-dbg monitor` 无 `--output`，用 `-j`；trace 事件默认不收，须 `-t trace -t drop`。
- pod 内 `pkill -f "cilium-dbg monitor"` 会杀死自己 -> 用 `pkill -x cilium-dbg`。
- `kubectl exec ds/cilium` 落点随机 -> 按节点 pod 名（cilium-98vtn/cilium-wz8bj）执行。
- tcpdump 后台跨 ssh 断开即死 -> 单条 ssh 会话内 `timeout 10 tcpdump ... &` 同步发流量。
- kubectl cp 会把文件拉到 pod 执行者 cwd；用绝对路径输出并存到 mon/。
- httpd:alpine 无 curl -> 一律 wget；确认 `pkill tcpdump` 后再 scp，否则只有 24 字节空包。
- Hubble 状态显示 buffer 100%（4095/4095 满）-> 实时追踪以 cilium-dbg monitor 为准。

## 5. 目录内容

```
experiment/
├── README.md          # 本文件
├── pcaps/             # s202_eth0/vxlan/cveth/host、d203_eth0/vxlan/bveth、s202_inside
├── mon/               # mon202.jsonl / mon203.jsonl
├── lbtables/          # lb_s202_nginx.txt / lb_s203_nginx.txt
├── ipc/               # ipc_s202.txt / ipc_s203.txt
├── logs/              # 抓包启动 log（e0.log/v.log/vx.log 等）
└── tools/             # 备用分析脚本
```