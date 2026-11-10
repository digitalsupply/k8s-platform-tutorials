# 为何 GitLab 未使用 80 端口？

## 问题现象

GitLab Nginx 正确监听了 `0.0.0.0:80`，但本地访问 `http://127.0.0.1:80` 出现连接超时。其他端口（8060、8088）正常访问。

## 根本原因

环境中之前部署过 **k3s + Cilium**，但 k3s 已被删除。Cilium 的清理不完整，遗留了以下组件：

1. **iptables/nftables 规则** - Cilium 注入的 mangle/nat 规则仍在生效（约 42 条 CILIUM 相关规则）
2. **CNI 配置** - `/etc/cni/net.d/05-cilium.conflist` 仍存在
3. **网络设备** - `cilium_host`、`cilium_net`、`cilium_vxlan` 虚拟网卡仍存在
4. **运行时文件** - `/run/cilium/` 目录及相关 socket 文件仍存在

### 关键规则

Cilium 遗留的 `CILIUM_PRE_mangle` 规则中：
```text
-A CILIUM_PRE_mangle ! -o lo -m socket --transparent ... -j MARK --set-xmark 0x200/...
```

该规则使用 `-m socket --transparent`（透明代理），会拦截某些本地 socket 流量并打上 mark，可能导致回环（127.0.0.1）到 80 端口的 TCP 连接在内核 netfilter/eBPF 路径中被处理异常，表现为 SYN 包“消失”（tcpdump 抓不到）并最终连接超时。

Cilium agent/daemon 已经不再运行，但这些内核层面的 iptables/eBPF 相关配置残留仍在干扰本地回环流量。

## 为什么不用 80 端口？

- **遗留规则未清理**：k3s 已删除但 Cilium 网络规则残留，清理这些 eBPF/iptables 规则较繁琐且可能影响其他网络组件（如 Tailscale）
- **风险控制**：强制清理 iptables 链（FLUSH CILIUM_*）可能破坏当前系统的网络状态
- **最简解决方案**：直接调整 GitLab Nginx 监听端口到 8088，功能完全不受影响

## 最终决定

采用**端口变更**方式解决：将 `gitlab_rails['nginx']['listen_port']` 设置为 `8088`。

**访问地址**：`http://192.168.67.201:8088/`

这是一个务实的解决方案，既避免了清理遗留网络配置的风险，又确保 GitLab 正常可用。
