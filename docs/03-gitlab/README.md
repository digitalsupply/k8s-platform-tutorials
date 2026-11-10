# 03 · GitLab：安装、端口 80 与 Cilium 遗留规则

## 当时的情况

在实验节点上安装 **GitLab CE 19.4.2（Omnibus）**。
环境里同时运行 Cilium，端口 80 被占用/受 Cilium 的 eBPF/iptables 规则影响，
GitLab 最初监听 **8088**。目标是把 GitLab 切到 80，过程中遇到：

- 改了 `external_url` 但 nginx 仍然监听 8088；
- Cilium 的 iptables/nftables 规则与端口行为相互影响；
- 清理 Cilium 规则后，集群网络和 GitLab 访问都出现变化；
- 最终选择保留 8088，并在 80 上做重定向。

这个案例的价值不在“GitLab 怎么装”，而在于**端口冲突排查和清理 CNI 规则的边界**。

## 主要概念与原理

### 1. Omnibus GitLab

GitLab Omnibus 把 nginx、puma、sidekiq、postgres、redis 等打包在一起，
统一由 `gitlab-ctl reconfigure` 生成配置。

关键配置：

```ruby
external_url 'http://<host>:8088'
nginx['listen_port'] = 8088
nginx['listen_https'] = false
```

- `external_url` 决定对外 URL；
- `nginx['listen_port']` 才决定 nginx 实际监听端口；
- 两者不一致时，会出现“配置看起来改了，但端口没变”。

### 2. Cilium 与 iptables/nftables

Cilium 的 eBPF 数据面可能绕过部分 iptables 链，但仍然会创建/使用一些
iptables/nftables 规则（例如 NodePort、masquerade、策略相关）。
清理这些规则会影响集群网络，不能只把它当成“GitLab 的端口问题”。

### 3. 端口占用判断

```bash
ss -lntp | grep ':80 '
ss -lntp | grep ':8088 '
iptables-save | grep -i cilium
nft list ruleset | grep -i cilium
```

要区分：

- 进程监听（nginx）；
- iptables/nftables 规则；
- Cilium LB/NodePort；
- 本机对自身 IP 的访问路径。

## 踩坑点

### 坑 1：只改 `external_url`

`external_url` 改了，但 `nginx['listen_port']` 还是 8088，端口不会变。
必须同时改 `listen_port`，再 `gitlab-ctl reconfigure`。

### 坑 2：把 Cilium 规则当垃圾直接清

Cilium 规则可能承载 NodePort/LB/策略功能。清理前要备份，
并确认集群里没有依赖这些规则的流量。

### 坑 3：80 端口“看起来没被占用”

`ss` 没看到进程，不代表没有 iptables/nftables 重定向或 Cilium LB。
要同时看 `ss`、`iptables-save`、`nft list ruleset`。

### 坑 4：本机访问和节点 IP 访问结果不同

`127.0.0.1:80` 和 `<node-ip>:80` 可能走不同规则。
排查时要用 `curl -v` 分别测试，并看目标 IP/端口。

### 坑 5：`reconfigure` 不是瞬间完成

GitLab reconfigure 会重启多个服务；端口切换期间可能短暂不可用。
不要在业务高峰期操作。

## 修复关键

1. **先确认目标**：是否真的必须用 80；如果只是访问方便，80→8088
   重定向是更小的改动。
2. **改 GitLab 配置**：`external_url` + `nginx['listen_port']` 同时改。
3. **清理 Cilium 规则前备份**：`iptables-save`、`nft list ruleset`。
4. **分层验证**：`ss` → `iptables/nftables` → `curl` → 浏览器。
5. **保留回滚路径**：记录原配置和规则，必要时恢复 8088。

## 文档列表

| 文档 | 内容 |
|---|---|
| [gitlab-19.4-install.md](gitlab-19.4-install.md) | GitLab CE 19.4.2 Omnibus 安装全过程 |
| [gitlab-port80-explanation.md](gitlab-port80-explanation.md) | 为什么没有直接用 80 端口 |
| [gitlab-port-80-troubleshooting.md](gitlab-port-80-troubleshooting.md) | 8088→80 的完整排查时间线 |
| [gitlab-fix-port80.md](gitlab-fix-port80.md) | 清理 Cilium 遗留规则并测试 80 |
| [gitlab-port80-cleanup-final.md](gitlab-port80-cleanup-final.md) | 最终方案：80→8088 重定向与清理总结 |

> 安装文档中的初始 root 密码已脱敏；实际部署请立即修改默认密码。
