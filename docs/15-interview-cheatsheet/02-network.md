# 02 · 网络面试题：握手、TIME_WAIT、CLOSE_WAIT、连接错误

> 证据：[`assets/evidence/network-states-*.txt`](assets/evidence/network-states-worker01.txt)、
> [`handshake.txt`](assets/evidence/handshake.txt)、
> [`connect-errors.txt`](assets/evidence/connect-errors.txt)、
> [`close-wait.txt`](assets/evidence/close-wait.txt)。

## 1. TIME_WAIT vs CLOSE_WAIT

### 一句话

**TIME_WAIT**：主动关闭方在 2MSL 等待，保证最后的 ACK 能重发、旧连接报文消散，会自愈；
**CLOSE_WAIT**：被动关闭方收到 FIN 后应用没 `close()`，是应用代码问题。

### 状态机

```text
主动关闭：
ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED
被动关闭：
ESTABLISHED → CLOSE_WAIT → LAST_ACK → CLOSED
```

### 为什么会 TIME_WAIT

- 主动关闭方发送最后一个 ACK 后进入 TIME_WAIT；
- 等 2MSL，防止 ACK 丢失导致对端重发 FIN；
- 让旧连接的重复报文在网络中消散，避免污染新连接。

### 为什么 CLOSE_WAIT 危险

- 收到 FIN 只表示对方不再发数据；
- 应用必须 `close()` 自己的 socket；
- 不 close → CLOSE_WAIT 累积 → fd 耗尽。

### 机器证据

worker01：

```text
established 37
syn-sent    0
time-wait   127
close-wait  0
```

PVE：

```text
time-wait 2
close-wait 0
```

CLOSE_WAIT 实验（客户端关闭、服务端不 close）：

```text
LISTEN     0 1 127.0.0.1:41957 0.0.0.0:*
CLOSE-WAIT 1 0 127.0.0.1:41957 127.0.0.1:43354
close-wait total: 1
```

### 排查

```bash
ss -tan state time-wait | wc -l
ss -tan state close-wait
ss -tanp state close-wait
lsof -p <pid> | grep TCP
```

### 追问

- TIME_WAIT 多要不要调 `tcp_tw_reuse`？客户端可谨慎开，NAT/服务端要小心。
- `tcp_tw_recycle`？已移除，不要用。
- CLOSE_WAIT 怎么修？改代码确保 `close()`/连接池正确释放，不是调内核参数。

## 2. 三次握手为什么不是两次

### 一句话

两次无法确认“客户端能收”、也无法防止历史重复 SYN 建立错误连接；三次才能确认双方收发能力并同步序列号。

### 展开

```text
Client                         Server
  --- SYN(seq=x) ------------>
  <-- SYN+ACK(seq=y,ack=x+1) --
  --- ACK(ack=y+1) ----------->
```

- 第一次：客户端能发；
- 第二次：服务端能收 + 能发；
- 第三次：客户端能收 + 服务端确认客户端能收。

两次的问题：

- 服务端无法确认客户端收到了自己的 SYN；
- 旧连接延迟的 SYN 可能让服务端建立错误连接；
- 序列号同步不完整。

### 机器证据

本机 loopback tcpdump：

```text
127.0.0.1.47432 > 127.0.0.1.18080: Flags [S], seq 419011900 ...
127.0.0.1.18080 > 127.0.0.1.47432: Flags [S.], seq 195709174, ack 419011901 ...
127.0.0.1.47432 > 127.0.0.1.18080: Flags [.], ack 1 ...
```

`S`=SYN，`S.`=SYN+ACK，`.`=ACK。

### 追问

- 第三次 ACK 丢了会怎样？服务端重发 SYN+ACK，客户端重发 ACK。
- SYN 队列/accept 队列？`net.core.somaxconn`、`tcp_max_syn_backlog`。
- SYN flood 怎么防？SYN cookies、限速、防火墙。

## 3. refused / timeout / reset

### 一句话

- **refused**：收到 RST，通常端口没监听/被拒绝；
- **timeout**：没有响应，丢包/防火墙/DROP/路由不可达；
- **reset**：连接建立后被 RST，通信中断/对端崩溃/中间设备重置。

### 机器证据

本机实测：

```text
refused: ConnectionRefusedError [Errno 111] Connection refused
timeout: TimeoutError timed out
reset: ConnectionResetError [Errno 104] Connection reset by peer
```

- refused：连 `127.0.0.1:1`（无监听）；
- timeout：连 `10.255.255.1:81`（黑洞）；
- reset：服务端 `SO_LINGER=0` 后 close。

### 排查

```bash
# 端口是否监听
ss -lntp | grep :80

# 本机 vs 远端
curl -v --max-time 3 http://host:port/
nc -vz host port

# 抓包
tcpdump -i any -nn 'tcp port 80'

# 防火墙
iptables-save | grep :80
nft list ruleset | grep :80
```

### 追问

- refused 一定是端口没开？也可能防火墙 REJECT with tcp-reset。
- timeout 一定是网络？也可能服务端 accept 队列满/应用不响应。
- reset 一定是服务端？也可能是 LB/NAT/防火墙空闲超时。
- `curl` 的 exit code：7=连接失败，28=超时，56=接收失败。

## 一页命令

```bash
ss -s
ss -tan state time-wait | wc -l
ss -tanp state close-wait
tcpdump -i any -nn 'tcp port 80' -c 20
curl -v --max-time 3 http://host:port/
nc -vz host port
```
