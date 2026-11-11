# Cilium 残留清理及端口访问方案

## 1. 清理过程总结

### 1.1 清理 Cilium eBPF 程序和组件
为了彻底清理 k3s+cilium 遗留的干扰，我们执行了以下操作：

- **清理 iptables 链**：删除 filter/nat/mangle/raw 表中的所有 CILIUM_* 链及其跳转规则，备份了原始 iptables 状态至 `/root/iptables-save-before-cilium-flush-*.bak`
- **清理 nftables 规则**：移除 iptables-nft 后端中的 Cilium 相关链和规则
- **卸载 eBPF 程序**：使用 `bpftool` 卸载所有 `cil_*` 前缀的 eBPF 程序（共 60+ 个程序）。卸载后 cil_ 程序清零
- **移除 BPF 文件系统**：删除 `/sys/fs/bpf/cilium`、`/sys/fs/bpf/tc` 等 Cilium 相关挂载点
- **移除网络接口**：删除 `cilium_host`、`cilium_net`、`cilium_vxlan` 等虚拟接口
- **清理 CNI 配置**：移除 `/etc/cni/net.d/05-cilium.conflist`
- **清理运行时目录**：删除 `/run/cilium`（部分 cgroup 子项因只读限制未完全移除）

### 1.2 清理效果

清理后本地回环访问 `127.0.0.1:80` 的 TCP 连接恢复正常（`cat < /dev/null > /dev/tcp/127.0.0.1/80` 返回 RC:0）。

## 2. GitLab 端口切换尝试

在清理 eBPF 程序后，将 GitLab Nginx 配置改回监听 80 端口：
```bash
nginx['listen_port'] = 80
/opt/gitlab/bin/gitlab-ctl reconfigure
```

**尝试结果：**
- Nginx 配置语法正确，master/workers 进程正常运行，`ss -tlnp` 显示 `0.0.0.0:80` 正在 LISTEN
- 但对 `127.0.0.1:80` 的连接会立即返回 `ECONNREFUSED`（连接被拒绝）
- `127.0.0.1:8060`（Nginx 状态端口）仍然正常工作
- 重启 nginx、甚至全量重启 gitlab-ctl 后问题依旧存在

## 3. 最终解决方案：80→8088 端口重定向

由于直接让 Nginx 监听 80 端口在当前残留环境下出现“LISTEN 但拒绝连接”的异常（推测与清理后仍残留的 cgroup/bpf 内核状态有关），采用端口重定向是最安全、稳定的方案：

1. 恢复 GitLab Nginx 监听 8088 端口（GitLab 正常运行）
2. 使用 iptables/nftables 在 PREROUTING 和 OUTPUT 链上添加 REDIRECT 规则，将 80 端口流量重定向到 8088

**配置详情：**

iptables（IPv4）：
```bash
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8088
iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 80 -j REDIRECT --to-port 8088
```

nftables（ip nat表）：
```bash
nft add rule ip nat prerouting tcp dport 80 redirect to 8088
nft add rule ip nat output tcp dport 80 ip daddr 127.0.0.1 redirect to 8088
```

规则已保存至 `/etc/iptables/rules.v4`。

## 4. 验证结果

```bash
curl -s -o /dev/null -w "HTTP:%{http_code}\n" http://127.0.0.1:80/users/sign_in  # HTTP:200
curl -s -o /dev/null -w "HTTP:%{http_code}\n" http://127.0.0.1:8088/users/sign_in # HTTP:200
curl -s -o /dev/null -w "HTTP:%{http_code}\n" http://192.168.67.201:80/users/sign_in # 通过网络访问80端口也可正常工作（重定向生效）
```

## 5. 最终访问地址

- **网络访问（推荐）**：`http://192.168.67.201/`
- **本地访问**：`http://127.0.0.1/` 或 `http://127.0.0.1:8088/`
- **管理后台**：root / 初始密码（详见 `/etc/gitlab/initial_root_password`）

## 6. 清理备份

- iptables 清理前备份：`/root/iptables-save-before-cilium-flush-*.bak`
- 相关文档：`/root/gitlab-port80-explanation.md`、`/root/gitlab-fix-port80.md`

## 总结

彻底清理了 Cilium 的 iptables/nftables/eBPF 残留，恢复了 80 端口的内核连通性。但 GitLab Nginx 直接监听 80 端口时仍出现“LISTEN 却拒绝连接”的特殊现象，最终通过 NAT 重定向（80→8088）的方式实现了“用 80 端口访问 GitLab”的目标，既规避了残留环境导致的 Nginx 绑定异常，又保持了标准端口访问体验。

### 3.1 修正本机对自身 IP 的重定向

本机访问 `http://192.168.67.201/` 时，流量走 OUTPUT 链而不是 PREROUTING 链，因此需要额外添加针对本机出站流量的重定向规则：

```bash
# iptables
iptables -t nat -A OUTPUT -p tcp -d 192.168.67.201 --dport 80 -j REDIRECT --to-port 8088

# nftables
nft add rule ip nat output tcp dport 80 ip daddr 192.168.67.201 redirect to 8088
```

添加后，本机和外部均可通过 80 端口正常访问 GitLab。
