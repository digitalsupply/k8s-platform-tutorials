# GitLab 端口 8088 未切换到 80 —— 完整排查记录

- **日期**：2026-10-13
- **主机**：`192.168.67.201`（eth0），tailscale 节点 `100.94.131.119`
- **现象**：GitLab 配置已改为 80 端口，但外部仍看到 8088 开放
- **结论**：**两个独立故障叠加**。配置层有重复的 `listen_port` 覆盖；网络层有遗留的 nat REDIRECT 规则把 80 转发到已失效的 8088

---

## 目录

1. [问题现象](#1-问题现象)
2. [环境基线](#2-环境基线)
3. [排查时间线](#3-排查时间线)
   - [阶段 A：端口盘点](#31-阶段-a端口盘点)
   - [阶段 B：GitLab 配置层](#32-阶段-bgitlab-配置层)
   - [阶段 C：reconfigure 与矛盾出现](#33-阶段-creconfigure-与矛盾出现)
   - [阶段 D：排除防火墙](#34-阶段-d排除防火墙)
   - [阶段 E：按网卡分裂的线索](#35-阶段-e按网卡分裂的线索)
   - [阶段 F：抓包定位](#36-阶段-f抓包定位)
   - [阶段 G：根因确认](#37-阶段-g根因确认)
   - [阶段 H：修复与验证](#38-阶段-h修复与验证)
4. [根因分析](#4-根因分析)
5. [改动清单](#5-改动清单)
6. [验证结果](#6-验证结果)
7. [排查方法论复盘](#7-排查方法论复盘)
8. [遗留事项与风险](#8-遗留事项与风险)
9. [回滚手册](#9-回滚手册)
10. [附录：完整命令清单](#10-附录完整命令清单)

---

## 1. 问题现象

用户报告："GitLab 不是已经改为 80 端口了吗？为啥 8088 还在开放"

核心矛盾在排查中途才显现——**表面现象与底层事实严重不符**：

| 观测方式 | 看到的端口 |
|---|---|
| `gitlab.rb` 配置 | 80（`external_url "http://192.168.67.201"`，无端口即 80） |
| 实际建立的连接 | 8088 |

且修复过程中出现了更反直觉的现象：**`ss` 显示 80 在监听，但 curl 访问 80 被拒绝连接**。

---

## 2. 环境基线

| 项目 | 值 |
|---|---|
| GitLab 部署方式 | Omnibus，`/opt/gitlab` |
| 配置文件 | `/etc/gitlab/gitlab.rb` |
| nginx 二进制 | `/opt/gitlab/embedded/sbin/nginx` |
| nginx 前缀 | `-p /var/opt/gitlab/nginx` |
| 生成配置目录 | `/var/opt/gitlab/nginx/conf/` |
| 主机名解析 | `lo 127.0.0.1/8`；`eth0 192.168.67.201/24`；`tailscale0 100.94.131.119/32` |
| 防火墙 | ufw `inactive`；iptables filter 全 `ACCEPT`；firewalld 未安装 |
| 其他网络组件 | tailscaled、cilium（Cilium 链存在但为空）、nft 混合模式 |
| 备份目录 | `/etc/gitlab/gitlab.rb.bak.20261013-070010`；`/root/nft-ruleset.bak.20261013-070235`；`/root/iptables-save.bak.20261013-070235` |

**关键网络拓扑**

```
                    ┌──────────────────────────────────┐
  外部访问 :80 ────►│  nat PREROUTING/OUTPUT            │
                    │  REDIRECT tcp/80 → :8088  ← 故障源 │
                    └──────────────┬───────────────────┘
                                   │
              ┌────────────────────┴────────────────────┐
              │  nginx 实际监听                         │
              │   0.0.0.0:80   ← 修复后                 │
              │   (原 0.0.0.0:8088)                    │
              └────────────────────┬────────────────────┘
                                   │  内部
              ┌────────────────────┴────────────────────┐
              │  gitlab-workhorse 127.0.0.1:9229       │
              │  puma          127.0.0.1:8080           │
              │  sidekiq       127.0.0.1:8082 / 8092    │
              └─────────────────────────────────────────┘
```

---

## 3. 排查时间线

### 3.1 阶段 A：端口盘点

**命令**
```bash
ss -tlnp
ls /etc/nginx/conf.d/ /etc/nginx/sites-enabled/
```

**结果**

nginx 监听两个端口：

```
LISTEN 0 511  0.0.0.0:8060  users:(("nginx",pid=160354,...))
LISTEN 0 511  0.0.0.0:8088  users:(("nginx",pid=160354,...))
```

GitLab 组件（均正常，绑 127.0.0.1）：

| 组件 | 端口 |
|---|---|
| gitlab-workhors | 9229 |
| gitaly | 9236 |
| puma (ruby) | 8080 |
| sidekiq (ruby) | 8082 / 8092 |
| gitlab-kas | 8150–8155 |
| gitlab-exporter | 9168 |
| postgres_export | 9187 |
| alertmanager | 9093 / 9094 |
| prometheus | 9090 |
| node_exporter | 9100 |
| redis_exporter | 9121 |

**第一处异常信号**：`/etc/nginx/` 不存在（独立系统 nginx 未安装），`/var/opt/gitlab/nginx/etc/` 也不存在。说明这是 Omnibus 自带 nginx，配置路径不同——后续改从 `/var/opt/gitlab/nginx/conf/` 入手。

---

### 3.2 阶段 B：GitLab 配置层

**命令**
```bash
grep -nE "external_url|listen_port|..." /etc/gitlab/gitlab.rb | grep -v "^\s*#"
```

**关键发现 —— `listen_port` 写了两遍**

```
32:   external_url "http://192.168.67.201"      ← 期望的 80

2049: gitlab_rails['nginx']['listen_port'] = 8088
3816: gitlab_rails['nginx']['listen_port'] = 8088   ← 重复！
```

第 3816 行的上下文（文件末尾追加处）：

```ruby
## Path where the generated Helm values file is written.
# oak['components']['openbao']['helm_values_path'] = '/etc/gitlab/openbao-helm-values.yaml'
gitlab_rails['nginx']['listen_port'] = 8088     # ← 误留的第二处
```

第 2049 行是 Omnibus 默认模板中的反代覆盖项，位于文档注释下方：

```ruby
##! **Override only if you use a reverse proxy**
##! Docs: https://docs.gitlab.com/omnibus/settings/nginx.html#setting-the-nginx-listen-port
gitlab_rails['nginx']['listen_port'] = 8088
```

**关键发现 —— 配置从未生效**

| 文件 | mtime |
|---|---|
| `/etc/gitlab/gitlab.rb` | 2026-10-13 **02:08** |
| `/var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf`（生成物） | 2026-10-12 **11:49** |

配置比生成物新 **15 小时** → 改完 `gitlab.rb` 后**从未执行** `gitlab-ctl reconfigure`。

**验证生成物内容**

```bash
grep -nE "^\s*listen|server_name" /var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf
```

```
35:  listen *:8088 default_server;
38:  server_name 192.168.67.201;
```

以及监控端口来源：

```bash
grep -rn "listen" /var/opt/gitlab/nginx/conf/
```

```
/var/opt/gitlab/nginx/conf/nginx-status.conf:2:    listen *:8060;
/var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf:35:  listen *:8088 default_server;
```

> ⚠ 阶段 B 的判断是"nginx 没监听 80"。这个结论是对的，但它**不是完整答案**——见阶段 C 之后。

---

### 3.3 阶段 C：reconfigure 与矛盾出现

**动作**：备份 `gitlab.rb` → 注释掉 2049、3816 两行 → `ruby -c` 校验 → 检查防火墙 → 执行 reconfigure。

```bash
cp -a /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.bak.$(date +%Y%m%d-%H%M%S)
/opt/gitlab/embedded/bin/ruby -c /etc/gitlab/gitlab.rb   # → Syntax OK
grep -nE "^\s*gitlab_rails\['nginx'\]\['listen_port'\]" /etc/gitlab/gitlab.rb
# → 无输出（覆盖已清除）
/opt/gitlab/bin/gitlab-ctl reconfigure
```

**reconfigure 输出（节选）**
```
[2026-10-13T07:00:29+00:00] INFO: template[/var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf] sending restart action to runit_service[nginx] (delayed)
Recipe: nginx::enable
  * runit_service[nginx] action restart (up to date)
[2026-10-13T07:00:29+00:00] INFO: Cinc Client Run complete in 3.967557233 seconds
Infra Phase complete, 3/909 resources updated in 04 seconds
gitlab Reconfigured!
```

**验证结果**

```bash
grep -nE "^\s*listen|server_name" /var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf
```

```
35:  listen *:80 default_server;      ← 端口已切换
38:  server_name 192.168.67.201;
```

```bash
ss -tlnp | grep -E ':(80|8088|8060|8080)\b'
```

```
LISTEN 0 511  0.0.0.0:8060  users:(("nginx",pid=184180,fd=8),...)
LISTEN 0 1024 127.0.0.1:8080  users:(("ruby",pid=158984,...))    ← puma，未变
LISTEN 0 511  0.0.0.0:80    users:(("nginx",pid=184180,fd=7),...) ← 80 已建立
```

8088 已消失，80 已监听。**但是**——

```bash
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/
# → 000
```

**全连接失败。矛盾诞生：内核显示 LISTEN，应用层却 Connection refused。**

---

### 3.4 阶段 D：排除防火墙

**命令与结果**

```bash
# nginx 自身是否健康
/opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t
# → syntax is ok / test is successful

tail -20 /var/log/gitlab/nginx/error.log
# → 空

ps -o pid,stat,wchan,cmd -p 184178,184179,184180
# → master: sigsuspend; worker: ep_poll  ← 进程健康
```

```bash
iptables -S | grep -vE "^P|^-N|^-F"
```

```
-P INPUT ACCEPT
-P FORWARD ACCEPT
-P OUTPUT ACCEPT
-A INPUT -m comment --comment "cilium-feeder: CILIUM_INPUT" -j CILIUM_INPUT
-A INPUT -j ts-input
-A FORWARD ... -j CILIUM_FORWARD
-A FORWARD -j ts-forward
-A OUTPUT ... -j CILIUM_OUTPUT
-A ts-forward -i tailscale0 -j MARK --set-xmark 0x40000/0xff0000
-A ts-forward -m mark --mark 0x40000/0xff0000 -j ACCEPT
-A ts-forward -s 100.64.0.0/10 -o tailscale0 -j DROP
-A ts-forward -o tailscale0 -j ACCEPT
-A ts-input -s 100.94.131.119/32 -i lo -j ACCEPT
-A ts-input -i tailscale0 -j ACCEPT
-A ts-input -p udp -m udp --dport 41641 -j ACCEPT
-A ts-input -s 100.115.92.0/23 ! -i tailscale0 -j RETURN
-A ts-input -s 100.64.0.0/10 ! -i tailscale0 -j DROP
```

**filter 表全 ACCEPT，无任何 REJECT/DROP 命中端口 80**（127.0.0.1 走完 ts-input 全链路后落到 policy ACCEPT）。

```bash
nft list ruleset | head -60
```

`table ip mangle`、`table ip raw` 全 `policy accept`，无跳转。

```bash
# 排除特权端口 / 端口耗尽
sysctl net.ipv4.ip_unprivileged_port_start net.ipv4.ip_local_port_range
# → 1024 / 32768 60999   ← 正常
```

```bash
# 内核视角确认 socket 真实存在
awk '$2 ~ /:0050$/' /proc/net/tcp
```

```
25: 00000000:0050 00000000:0000 0A ... uid 0 ino 5890912 1 ffff8b2a82c10000 100
```

`00000000:0050` = `INADDR_ANY:80`，`0A` = `TCP_LISTEN`，uid 0 —— **socket 确实存在且处于监听态**。

```bash
ss -ltnpe | grep ':80\b'
```

```
LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",...)) ino:5890912 sk:258ba4 cgroup:/gitlab.slice/gitlab-runsvdir.service
```

**阶段 D 结论：进程健康、配置合法、无防火墙拦截、内核 socket 正常。排除"服务侧"和"filter 表"两个方向。**

---

### 3.5 阶段 E：按网卡分裂的线索

突破口来自一组对照测试——同一个 nginx、同一个端口，**按目的地址不同而分裂**：

```bash
for p in 8060 8080 9229 8150; do curl ... http://127.0.0.1:$p/; done
```

| 目标 | 结果 |
|---|---|
| `127.0.0.1:8060` | 404（通） |
| `127.0.0.1:8080` | 302（通） |
| `127.0.0.1:9229` | 404（通） |
| `127.0.0.1:8150` | 426（通） |

**同在 127.0.0.1 上，其他端口全通，只有 80 不通** —— 排除网络栈级故障，问题与端口号本身强相关。

进一步用 Python 拿到精确 errno，并横向对比地址族：

```bash
python3 -c "
import socket
for tgt in [('127.0.0.1',80),('192.168.67.201',80),('100.94.131.119',80),('127.0.0.1',8060)]:
    s=socket.socket(); s.settimeout(5)
    try: s.connect(tgt); print(tgt,'OK')
    except Exception as e: print(tgt,type(e).__name__,e)
    finally: s.close()
"
```

| 目标 | 结果 |
|---|---|
| `127.0.0.1:80` | **ConnectionRefusedError [Errno 111]** |
| `192.168.67.201:80` | **ConnectionRefusedError [Errno 111]** |
| `100.94.131.119:80` | **OK**（curl 实测 HTTP **302**） |
| `127.0.0.1:8060` | OK |

**决定性线索**：`100.94.131.119:80`（tailscale0）能返回真实的 GitLab 302 跳转，说明 **nginx 在 80 上工作完全正常**。

> 💡 **「tailscale 通、lo 和 eth0 不通」这个模式指向按 (源/目的地址, 接口) 匹配的网络规则**——典型就是 nat 表里的 REDIRECT/DNAT。它不可能出现在 filter 表，所以阶段 D 的排查方向是对的，只是层选错了。

---

### 3.6 阶段 F：抓包定位

```bash
timeout 12 tcpdump -ni lo -c 6 'tcp port 80' & sleep 3
curl -s -o /dev/null --max-time 5 http://127.0.0.1/
wait
```

**输出**

```
07:02:07.420070 IP 127.0.0.1.80 > 127.0.0.1.39424: Flags [R.], seq 0, ack 3997291218, win 0, length 0
1 packet captured
```

**读法**：
- 源端口是 `80` 而不是 `8088` —— 因为 conntrack/nat 规则在应答方向把端口改回了原始的 80
- `Flags [R.]` = RST+ACK，**服务端主动拒绝**
- 只有 1 个包被抓到，**SYN 根本没有到达 nginx**

> 关键判据：nginx `error.log` 空、访问日志无记录，说明 SYN 从未被应用层接收 —— 是内核/netfilter 层在连接建立之前就终结了它。这也与"nginx 进程健康却不通"完全自洽。

---

### 3.7 阶段 G：根因确认

之前用 `nft list ruleset | head -60` 截断了输出，**恰好切掉了 `table ip nat`**。这次完整 dump：

```bash
nft list ruleset | sed -n '/table ip filter/,$p'
```

**命中的部分：**

```
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport 80 redirect to :8088                            # handle 30
    }
    chain output {
        type nat hook output priority dstnat; policy accept;
        tcp dport 80 ip daddr 127.0.0.1 redirect to :8088         # handle 31
        tcp dport 80 ip daddr 192.168.67.201 redirect to :8088     # handle 33
    }
    chain OUTPUT {                                                  # ← iptables 翻译而来
        type nat hook output priority dstnat; policy accept;
        ip daddr 192.168.67.201 tcp dport 80 counter packets 0 bytes 0 redirect to :8088
    }
    chain PREROUTING { type nat hook prerouting priority dstnat; policy accept; }
    chain INPUT     { type nat hook input priority srcnat; policy accept; }
    chain POSTROUTING{ type nat hook postrouting priority srcnat; policy accept; }
    chain postrouting { type nat hook postrouting priority srcnat; policy accept; }
    chain CILIUM_OUTPUT_nat { }
    chain CILIUM_POST_nat { }
    chain ts-postrouting { }
}
```

**根因锁定**：存在一组把 **80 → 8088** 的 nat REDIRECT 规则。
- `handle 30`（prerouting）覆盖**所有来源**的入站 80 流量 → 故 `192.168.67.201:80` 被拒
- `handle 31`（output）针对本机 loopback 访问 → 故 `127.0.0.1:80` 被拒
- 这两条**唯独没有匹配 tailscale 来源地址**，tailscale 客户端的连接是经 `tailscale0` 进入、走 socket 层直连而绕过了本地 DNAT 路径 → 故 `100.94.131.119:80` 能通

nginx 早已不监听 8088 → REDIRECT 目标为空 → 内核回 RST。

**追溯规则来源**

```bash
iptables -t nat -S
```

```
# Table `nat' contains incompatible base-chains, use 'nft' tool to list them.
-P PREROUTING ACCEPT
-P INPUT ACCEPT
-P OUTPUT ACCEPT
-P POSTROUTING ACCEPT
-N CILIUM_OUTPUT_nat
-N CILIUM_POST_nat
-N ts-postrouting
-A OUTPUT -d 192.168.67.201/32 -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 8088
```

> 注意开头的告警：nft 与 iptables 两套基链并存（`iptables-nft` 兼容层），且规则重复。`iptables` 那条计数为 0，从未命中；**实际生效的是 nft 原生的 handle 30/31/33**。

```bash
ls -la /etc/nftables.conf
grep -rln "8088" /etc/nftables.conf /etc/sysconfig/nftables.conf /etc/nftables.d/ ...
```

```
-rwxr-xr-x 1 root root 243 Oct 19 2023 /etc/nftables.conf
```

`/etc/nftables.conf` 是 2023 年的空模板，**不含 8088**，不含上述规则：

```
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input  { type filter hook input priority filter; }
    chain forward{ type filter hook forward priority filter; }
    chain output { type filter hook output priority filter; }
}
```

→ 这些 nat 规则是**纯运行时注入，未持久化**到任何配置文件。

---

### 3.8 阶段 H：修复与验证

**备份**
```bash
nft list ruleset > /root/nft-ruleset.bak.$(date +%Y%m%d-%H%M%S)
iptables-save  > /root/iptables-save.bak.$(date +%Y%m%d-%H%M%S)
```

**删除规则**
```bash
nft delete rule ip nat prerouting handle 30
nft delete rule ip nat output     handle 31
nft delete rule ip nat output     handle 33
iptables -t nat -D OUTPUT -d 192.168.67.201/32 -p tcp --dport 80 -j REDIRECT --to-ports 8088
```

**残留检查**
```bash
nft list ruleset | grep 8088          # → 已无
iptables-save -t nat | grep 8088     # → 已无
```

**验证**
```bash
ss -tlnp | grep -E ':(80|8060|8088)\b'
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/            # 302
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.67.201/        # 302
curl -s -o /dev/null -w "%{http_code}\n" http://100.94.131.119/        # 302
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8088/        # 000 拒绝
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/users/sign_in  # 200
```

**服务状态**：`gitlab-ctl status` 全部 `run`，无异常。

---

## 4. 根因分析

### 故障层 1：GitLab 配置层

```
external_url "http://192.168.67.201"      →  期望端口 80
       │
       ├─ 被覆盖 ─→ gitlab_rails['nginx']['listen_port'] = 8088   (第 2049 行)
       │             gitlab_rails['nginx']['listen_port'] = 8088   (第 3816 行，重复)
       ▼
nginx 实际监听 8088
```

三个叠加因素：

1. `listen_port` 优先级高于 `external_url` 推导出的端口
2. 同一覆盖项**被写了两次**（2049 模板处 + 3816 末尾追加处），维护时容易只删一处
3. **改完从未 `reconfigure`** —— `gitlab.rb` mtime 比生成配置新 15 小时，配置是"纸面"的

### 故障层 2：网络层（真正的"8088 还开放"来源）

用户最初使用"80 → 8088"的 nat 端口映射方式对外暴露服务。GitLab 改为直监 80 后，这组 REDIRECT 规则变成了**指向死端口的陷阱**：

```
客户端 → :80
         ↓ nat PREROUTING (handle 30) REDIRECT → :8088
         ↓ 8088 无监听进程
       内核 RST  →  客户端 Connection refused
```

**为什么这个故障极具迷惑性**：

| 现象 | 原因 |
|---|---|
| `ss` 显示 80 在监听，但连不上 | socket 确实建立了，但 nat 把 SYN 改道到 8088 |
| `gitlab.rb` 已经是 80，看起来没问题 | 配置层和实际生效层不一致（未 reconfigure） |
| tailscale 能访问，局域网不能 | REDIRECT 规则未覆盖 tailscale 来源地址 |
| nginx 日志完全空白 | SYN 未到应用层，不是应用故障 |

---

## 5. 改动清单

| # | 对象 | 位置 | 原值 → 新值 | 备份 |
|---|---|---|---|---|
| 1 | `gitlab.rb` | 第 2049 行 | `listen_port = 8088` → 注释 | `gitlab.rb.bak.20261013-070010` |
| 2 | `gitlab.rb` | 第 3816 行 | 重复的 `listen_port = 8088` → 注释 | 同上 |
| 3 | GitLab 服务 | — | `gitlab-ctl reconfigure` | — |
| 4 | nft `nat prerouting` | handle 30 | 删除 `redirect to :8088` | `nft-ruleset.bak.20261013-070235` |
| 5 | nft `nat output` | handle 31 | 删除 `redirect to :8088` | 同上 |
| 6 | nft `nat output` | handle 33 | 删除 `redirect to :8088` | 同上 |
| 7 | iptables `nat OUTPUT` | — | 删除 `REDIRECT --to-ports 8088` | `iptables-save.bak.20261013-070235` |

> `listen_port` 采用**注释而非物理删除**，保留原值与官方文档链接，回滚仅需去掉 `# ` 前缀，并在每处附加了变更日期与原因。

### 变更后的生效配置

```ruby
external_url "http://192.168.67.201"   # 第 32 行，端口 80

##! **Override only if you use a reverse proxy**
##! Docs: https://docs.gitlab.com/omnibus/settings/nginx.html#setting-the-nginx-listen-port
##! 2026-10-13: 已移除 8088 覆盖，端口改由 external_url 决定(80)。原值 8088。
# gitlab_rails['nginx']['listen_port'] = 8088     # 第 2049 行
```

```nginx
# /var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf
server {
  listen *:80 default_server;      # 第 35 行
  server_name 192.168.67.201;
```

---

## 6. 验证结果

### 端口状态

```
LISTEN 0 511  0.0.0.0:8060   nginx   ← 监控状态页，仍对外（见遗留事项）
LISTEN 0 511  0.0.0.0:80     nginx   ← GitLab 主站
LISTEN 0 1024 127.0.0.1:8080 ruby    ← puma，未受影响
```

`8088` 已完全消失。

### HTTP 实测

| 目标 | 修复前 | 修复后 |
|---|---|---|
| `http://127.0.0.1/` | 000 拒绝 | **302** → `/users/sign_in` |
| `http://192.168.67.201/` | 000 拒绝 | **302** |
| `http://100.94.131.119/` | 302 | **302** |
| `http://127.0.0.1:8088/` | 302 | **000 拒绝（预期）** |
| `http://127.0.0.1/users/sign_in` | — | **200** |

### 服务健康

`gitlab-ctl status` 全部 `run`：

```
nginx, puma, sidekiq, postgresql, redis, gitaly,
gitlab-workhorse, gitlab-kas, gitlab-exporter,
prometheus, alertmanager, node-exporter,
postgres-exporter, redis-exporter, logrotate
```

---

## 7. 排查方法论复盘

本次排查中最有价值的判据，按有效性排序：

### 7.1「同一 socket，按目的地址分裂」→ 必查 nat 层

`100.94.131.119:80` 通而 `127.0.0.1:80` / `192.168.67.201:80` 不通。

同一个 `0.0.0.0:80` 监听 socket 不会自己区别对待不同网卡 —— 差异必然来自**按地址/接口匹配的规则**。而 filter 表全 ACCEPT 已排除，剩下最可能的层就是 **nat（DNAT/REDIRECT）**。

> 一般而言：`Connection refused` 若来自 filter 规则的 `REJECT`，用 `iptables -S` 直接可见；**若是 nat 重定向到了死端口，filter 表里什么都没有**，必须查 nat。

### 7.2「`ss` 说在监听，curl 说连不上」= 高优先级矛盾信号

这个矛盾一旦出现，就证明**内核 socket 状态与连接建立路径不一致**，应立刻怀疑 nat/透明代理，而不是继续纠结应用配置。

### 7.3 抓包确认 SYN 是否到达应用层

```
07:02:07.420070 IP 127.0.0.1.80 > 127.0.0.1.39424: Flags [R.], seq 0, ...
```

- 有 RST 无 SYN-ACK，且 nginx 日志无记录 → SYN 被内核层终结
- 源端口显示为 `80` 而非 `8088` → **conntrack 把应答端口改回了原始端口，是 nat 改道的直接指纹**

### 7.4 对照组设计比穷举更快

在同一 `127.0.0.1` 上批量测试 8060/8080/9229/8150 全部正常，只有 80 失败 —— 一步把"网络栈故障"和"应用故障"同时排除，把范围收敛到端口号维度。

### 7.5 不要用 `head` 截断关键输出

本案例中 `nft list ruleset | head -60` **恰好切掉了 `table ip nat`**，导致第一轮排查完全看不到根因。排查网络问题时应完整 dump，或按表定向过滤：

```bash
nft list table ip nat        # 定向查询
nft -a list chain ip nat output   # 带 handle，便于后续 delete
```

`-a`（list-handles）在这里非常关键：修复时需要按 handle 精确删除单条规则，而非整链清空。

### 7.6 配置文件 mtime vs 生成物 mtime

判断"配置到底生效没有"，最快的方式是比较源配置与生成配置的修改时间：

```bash
ls -la --time-style=long-iso /etc/gitlab/gitlab.rb \
                     /var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf
```

源比生成物新 → **必然没跑 reconfigure**。

---

## 8. 遗留事项与风险

### 🔴 高：明文 HTTP + 裸 IP

```
external_url "http://192.168.67.201"
```

`http://` 无 TLS，且使用裸 IP 而非域名。登录密码、personal access token、CI job token 全部**明文传输**。经 tailscale 隧道尚可（已加密），但走 eth0 / 同网段任何人抓包即得。

**建议**：配置域名 + Let's Encrypt，`external_url "https://gitlab.example.com"`。

### 🟡 中：注入源未清除（会复发）

那两条 nat REDIRECT 规则**是运行时注入的，没有写进任何配置文件**，`/etc/nftables.conf` 是 2023 年的空模板。

- 好的一面：重启后自然消失
- **风险**：如果是在某个部署脚本 / 运维命令 / 初始化流程里做的"80→8088"映射，**下次执行会重新注入，故障重现**

**行动项**：全局搜索部署脚本与 shell 历史中是否存在 8088 相关配置，例如：

```bash
grep -rn "8088" /etc /usr/local/bin /opt /root --include="*.sh" \
     --include="*.yml" --include="*.yaml" --include="*.conf" 2>/dev/null
history | grep -iE "8088|redirect"
```

### 🟡 中：8060 监控端口对外暴露

`/var/opt/gitlab/nginx/conf/nginx-status.conf:2` 绑的是 `*:8060` 而非 `127.0.0.1:8060`，外部可直接访问 `/nginx_status`，泄露连接数、请求状态等信息。

本次未改动（用户未授权）。**修复方式**：

```ruby
nginx['listen_port'] = '127.0.0.1:8060'
```

然后 `gitlab-ctl reconfigure`。

### 🟢 低：nft / iptables 双栈混用

```
# Table `nat' contains incompatible base-chains, use 'nft' tool to list them.
```

nft 原生基链（`prerouting`/`output`/`postrouting` 小写）与 iptables 兼容层基链（`PREROUTING`/`OUTPUT` 大写）并存，且本次发现的 8088 规则在两套里**都有**（iptables 那条计数 0 未命中，nft 那条命中）。

同类规则分散在两套体系里，是本次排查耗时的主因之一。建议后续统一到单一管理面，避免"删了一处另一处还在"。

### ⚠️ 附带风险：`/etc/nftables.conf` 含 `flush ruleset`

```bash
#!/usr/sbin/nft -f
flush ruleset
```

若有人执行 `nft -f /etc/nftables.conf`，会**清空整个规则集**，连带冲掉 tailscale 与 cilium 的规则，导致 tailscale 断连、容器网络异常。此文件虽非本次故障来源，但属于潜在地雷。

---

## 9. 回滚手册

### 场景 A：需要恢复"80 → 8088 端口映射"（回到修复前状态）

```bash
# 1. 恢复 GitLab 监听 8088
sed -i 's|^# gitlab_rails\['"'"'nginx'"'"'\]\['"'"'listen_port'"'"'\] = 8088|gitlab_rails['"'"'nginx'"'"']['"'"'listen_port'"'"'] = 8088|' \
    /etc/gitlab/gitlab.rb
/opt/gitlab/bin/gitlab-ctl reconfigure

# 2. 恢复 nat REDIRECT
nft add rule ip nat prerouting tcp dport 80 redirect to :8088
nft add rule ip nat output tcp dport 80 ip daddr 127.0.0.1     redirect to :8088
nft add rule ip nat output tcp dport 80 ip daddr 192.168.67.201 redirect to :8088
iptables -t nat -A OUTPUT -d 192.168.67.201/32 -p tcp --dport 80 \
         -j REDIRECT --to-ports 8088
```

### 场景 B：完整还原到排查前

```bash
cp -a /etc/gitlab/gitlab.rb.bak.20261013-070010 /etc/gitlab/gitlab.rb
/opt/gitlab/bin/gitlab-ctl reconfigure
nft -f /root/nft-ruleset.bak.20261013-070235
iptables-restore < /root/iptables-save.bak.20261013-070235
```

> ⚠ `nft -f` 会 `flush ruleset`，还原后需确认 tailscale 与 cilium 规则已回位：
> `nft list ruleset | grep -c ts-input` 应大于 0。

---

## 10. 附录：完整命令清单

```bash
# ── 阶段 A：端口盘点 ─────────────────────────────────
ss -tlnp
ls /etc/nginx/conf.d/ /etc/nginx/sites-enabled/

# ── 阶段 B：GitLab 配置层 ────────────────────────────
grep -nE "external_url|listen_port|nginx\['listen" /etc/gitlab/gitlab.rb | grep -v "^\s*#"
sed -n '2040,2056p;3808,3822p' /etc/gitlab/gitlab.rb
ls -la --time-style=long-iso /etc/gitlab/gitlab.rb /var/opt/gitlab/nginx/conf/service_conf/gitlab-rails.conf
grep -rn "listen" /var/opt/gitlab/nginx/conf/
tr '\0' ' ' < /proc/$(pgrep -o nginx)/cmdline

# ── 阶段 C：修改与 reconfigure ───────────────────────
cp -a /etc/gitlab/gitlab.rb /etc/gitlab/gitlab.rb.bak.$(date +%Y%m%d-%H%M%S)
/opt/gitlab/embedded/bin/ruby -c /etc/gitlab/gitlab.rb
/opt/gitlab/bin/gitlab-ctl reconfigure

# ── 阶段 D：排除服务与防火墙 ─────────────────────────
/opt/gitlab/embedded/sbin/nginx -p /var/opt/gitlab/nginx -t
tail -20 /var/log/gitlab/nginx/error.log
ps -o pid,stat,wchan,cmd -p <nginx pids>
ufw status; iptables -S; firewall-cmd --list-all
nft list ruleset
sysctl net.ipv4.ip_unprivileged_port_start net.ipv4.ip_local_port_range
awk 'NR==1 || $2 ~ /:0050$/' /proc/net/tcp
ss -ltnpe | grep ':80\b'

# ── 阶段 E：对照测试 ─────────────────────────────────
for p in 8060 8080 9229 8150; do curl -s -o /dev/null -w "$p -> %{http_code}\n" http://127.0.0.1:$p/; done
python3 -c "
import socket
for t in [('127.0.0.1',80),('192.168.67.201',80),('100.94.131.119',80),('127.0.0.1',8060)]:
    s=socket.socket(); s.settimeout(5)
    try: s.connect(t); print(t,'OK')
    except Exception as e: print(t,type(e).__name__,e)
    finally: s.close()"

# ── 阶段 F：抓包 ─────────────────────────────────────
timeout 12 tcpdump -ni lo -c 6 'tcp port 80' & sleep 3; curl --max-time 5 http://127.0.0.1/; wait

# ── 阶段 G：根因确认 ─────────────────────────────────
nft list ruleset | sed -n '/table ip filter/,$p'      # 勿用 head 截断
nft -a list chain ip nat prerouting
nft -a list chain ip nat output
iptables -t nat -S
cat /etc/nftables.conf

# ── 阶段 H：修复与验证 ───────────────────────────────
nft list ruleset > /root/nft-ruleset.bak.$(date +%Y%m%d-%H%M%S)
iptables-save  > /root/iptables-save.bak.$(date +%Y%m%d-%H%M%S)
nft delete rule ip nat prerouting handle 30
nft delete rule ip nat output handle 31
nft delete rule ip nat output handle 33
iptables -t nat -D OUTPUT -d 192.168.67.201/32 -p tcp --dport 80 -j REDIRECT --to-ports 8088
nft list ruleset | grep 8088 || echo "nft clean"
iptables-save -t nat | grep 8088 || echo "iptables clean"
ss -tlnp | grep -E ':(80|8060|8088)\b'
/opt/gitlab/bin/gitlab-ctl status
```

---

**文档版本**：v1.0　**完成时间**：2026-10-13 07:05 UTC　**状态**：已修复并验证
