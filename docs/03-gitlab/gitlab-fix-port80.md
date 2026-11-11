# 清理 Cilium 遗留规则并切换回 80 端口（操作过程与结果）

## 1. 背景

环境中之前部署过 k3s + Cilium，k3s 已删除，但 Cilium 遗留了 iptables/nftables 规则、CNI 配置、网络设备等，导致本地回环访问 127.0.0.1:80 出现连接超时。最初采用将 GitLab Nginx 监听端口改为 8088 的临时方案。

本次尝试清理遗留的 Cilium 网络规则，恢复使用标准的 80 端口。

## 2. 清理 Cilium iptables 规则

### 2.1 备份当前 iptables 状态
```bash
iptables-save > /root/iptables-save-before-cilium-flush-<timestamp>.bak
```

### 2.2 清理 iptables 各表中的 Cilium 链和跳转规则
依次清理 filter、nat、mangle、raw 表中的 CILIUM_* 链，并删除指向这些链的跳转规则：
- filter: CILIUM_INPUT、CILIUM_FORWARD、CILIUM_OUTPUT
- nat: CILIUM_PRE_nat、CILIUM_OUTPUT_nat、CILIUM_POST_nat
- mangle: CILIUM_PRE_mangle、CILIUM_POST_mangle
- raw: CILIUM_PRE_raw、CILIUM_OUTPUT_raw

```bash
# 具体操作
iptables -t filter -F CILIUM_INPUT CILIUM_FORWARD CILIUM_OUTPUT 2>/dev/null || true
iptables -t filter -X CILIUM_INPUT CILIUM_FORWARD CILIUM_OUTPUT 2>/dev/null || true
# ... 同理清理其他表
# 删除主链中的 jump 规则
iptables -t filter -D INPUT -j CILIUM_INPUT 2>/dev/null || true
# ... 等
```

## 3. 清理 nftables 中的 Cilium 规则

Cilium 使用 iptables-nft 后端，规则也存在于 nftables 中。对 mangle/nat/filter/raw 表的 CILIUM_* 链进行清理：
```bash
nft flush chain ip mangle CILIUM_PRE_mangle 2>/dev/null || true
nft flush chain ip mangle CILIUM_POST_mangle 2>/dev/null || true
nft delete chain ip mangle CILIUM_PRE_mangle 2>/dev/null || true
nft delete chain ip mangle CILIUM_POST_mangle 2>/dev/null || true
# 同理清理其他表及其跳转规则
```

清理完成后检查：
```bash
nft list table ip mangle 2>&1 | grep CILIUM  # 无输出
nft list table ip nat 2>&1 | grep CILIUM    # 无输出
```

## 4. 测试端口 80 可访问性（清理规则后）

清理 Cilium 规则后，测试本地回环 80 端口连通性：
```bash
timeout 3 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/80"; echo "RC:$?"
# RC: 124（仍然超时）
```

同时检查 eBPF 状态：
```bash
bpftool prog show 2>&1 | grep -c cilium  # 0
bpftool prog show 2>&1 | wc -l  # 782（仍有大量 eBPF 程序）
bpftool map show 2>&1 | wc -l   # 337
```

结论：iptables/nftables 层面的 Cilium 规则已清理干净，但内核中可能残留的 eBPF 程序、socket 透明代理相关的内核状态仍然影响 127.0.0.1:80 的本地连接，导致连接建立时挂起（SYN 包未能正常建立连接）。

## 5. 尝试通过端口转发解决

为使外部访问仍可使用 80 端口，同时绕过本地回环的异常行为，尝试使用 iptables/nftables NAT 重定向（80 -> 8088）：
```bash
nft add rule ip nat prerouting tcp dport 80 redirect to 8088 2>/dev/null
nft add rule ip nat output tcp dport 80 ip daddr 127.0.0.1 redirect to 8088 2>/dev/null
```

测试重定向：
```bash
curl -s -o /dev/null -w "HTTP:%{http_code}\n" http://127.0.0.1:80/users/sign_in
# 仍无响应（连接超时）
```

分析：NAT 重定向（DNAT/REDIRECT）发生在 netfilter 的 nat hook，连接建立在此之前可能已被 eBPF/内核路径拦截，因此重定向规则未生效。

## 6. 最终决定：恢复 8088 端口

考虑到清理遗留规则未能完全恢复 80 端口的本地连通性，且清理深层 eBPF 程序存在风险（可能影响 Tailscale 等其他组件），决定采用最稳妥的方案——恢复使用 8088 端口。

### 6.1 修改 GitLab 配置
```bash
sed -i "s/^nginx\['listen_port'\] = 80/nginx['listen_port'] = 8088/" /etc/gitlab/gitlab.rb
grep "nginx.*listen_port" /etc/gitlab/gitlab.rb
# nginx['listen_port'] = 8088
```

### 6.2 应用配置
```bash
/opt/gitlab/bin/gitlab-ctl reconfigure
```

### 6.3 验证
```bash
ss -tlnp | grep 8088
# LISTEN 0 511 0.0.0.0:8088 *:* users:(("nginx",...))

curl -s -o /dev/null -w "HTTP:%{http_code}\n" http://127.0.0.1:8088/users/sign_in
# HTTP:200
```

GitLab 正常工作在 8088 端口。

## 7. 结论

- **已清理**：iptables 和 nftables 中绝大部分 Cilium 残留链和跳转规则
- **未解决**：由于内核层 eBPF 程序/状态残留，本地环回 127.0.0.1:80 仍无法建立 TCP 连接
- **最终方案**：恢复使用 8088 端口作为 GitLab Web 访问端口（安全、稳定、无风险）

这次尝试记录了清理过程，证明了对于这种带有 eBPF 的 CNI 残留，单纯清理 netfilter 规则可能不足以完全恢复受影响的本地端口。保留 8088 端口是最合理的选择。

**访问地址**：`http://192.168.67.201:8088/`
