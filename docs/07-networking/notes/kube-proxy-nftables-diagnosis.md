# kube-proxy nftables 模式诊断与修复报告

> **状态：历史快照（Calico + kube-proxy 时代，Cilium 迁移前）**
> 本文记录的是 kube-proxy nftables 实验与当时的 Calico 配置，**文中"Calico BPF 兜底"的结论已被审计更正**（见下方 §6 的更正块）。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），**照本文排障前先看现状**：[current-state.md](../../00-cluster-overview/assets/current-state.md)。
> 审计记录见 [19 章](../../19-audit/README.md)。

## 诊断过程

### 1. 确认当前模式

```
kubectl get configmap -n kube-system kube-proxy -o yaml
```

结果：`mode: nftables`，`nftables.masqueradeAll: true`

```
ps aux | grep kube-proxy
# /usr/local/bin/kube-proxy --proxy-mode=nftables --hostname-override=m01
```

### 2. 检查 nftables 规则

```
nft list ruleset
# 返回空 — 没有任何 nftables 规则

nft list tables
# exit 139 — 无表
```

主机上 nftables 规则集完全为空。

### 3. 检查 iptables 规则

```
iptables -t nat -L -n
# 仅 KUBE-KUBELET-CANARY（空），无 KUBE-SERVICES/KUBE-MARK-MASQ
```

iptables 侧也无 kube-proxy 规则。

### 4. 检查 kube-proxy 日志

```
kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50
```

关键发现：
- `Using nftables Proxier` — 确认进入 nftables 模式
- **每 2 分钟重复**：`Deleting stale nftables chains ipFamily="IPv4" numChains=10`
- 无实际错误日志，但规则从未被创建

### 5. 发现 nft 二进制崩溃（根因）

```
dmesg | grep 'nft\[.*\]: segfault'
```

结果：至少 21 次 segfault，分布在内核 5.14.0-570.58.1.el9_6：

```
nft[3898924]: segfault at 0 ip 0000000000000000 error 14 in nft[55dd26a51000+2000]
nft[3902509]: segfault at 0 ip 0000000000000000 error 14 in nft[558389342000+2000]
...
```

- nftables v1.0.9 (Old Doc Yak #3) 空指针解引用崩溃
- 每次 kube-proxy 尝试调用 nft 安装规则时触发 segfault
- 规则从未成功写入内核

### 6. 检查服务面

- Calico FelixConfiguration：`bpfConnectTimeLoadBalancing: TCP`，`nftablesMode: Auto`
- Calico IPPool：`natOutgoing: true`，`ipipMode: Always`
- **更正（2026-11-11 审计）**：本集群 Calico 是 `calico_backend: bird` + iptables，`FELIX_BPFENABLED` 从未开启，**没有 BPF 数据面兜底**。
  没有 kube-proxy 就没有组件为 ClusterIP 做 DNAT —— 与 [07/README.md](../README.md) 的"Service 全部不可用"一致；
  本文原结论"服务未中断"是当时的猜测，未经抓包/连通性证据支持。

### 7. 配置问题

- `clusterCIDR: 10.244.0.0/16`（单数）→ KubeProxyConfiguration v1alpha1 期望 `clusterCIDRs`（复数数组）
- 日志警告：`Detect-local-mode set to ClusterCIDR, but no cluster CIDR specified for primary IP family clusterCIDRs=null`

## 修复过程

### 步骤 1：修改 configmap — mode nftables → iptables

```
kubectl patch configmap -n kube-system kube-proxy --type=merge \
  -p '{"data":{"config.conf":"...mode: iptables..."}}'
```

结果：configmap 已更新。

### 步骤 2：修改 DaemonSet 命令行

```
kubectl patch ds -n kube-system kube-proxy --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command",
        "value":["/usr/local/bin/kube-proxy","--proxy-mode=iptables",
                   "--hostname-override=$(NODE_NAME)"]}]'
```

结果：DaemonSet 命令行已改为 `--proxy-mode=iptables`。

### 步骤 3：重启 pod

```
kubectl delete pods -n kube-system -l k8s-app=kube-proxy
```

结果：6 个 pod 全部重建，状态 Running (1/1)，0 restart。

### 步骤 4：发现启动卡死 — 缺 --kubeconfig

修复后 kube-proxy 卡在 "Waiting for caches to sync" 超过 7 分钟。

诊断发现：
- 进程 TCP 连接状态：`SYN-SENT 10.0.0.61:58090 → 10.96.0.1:443`
- 10.96.0.1 是 Kubernetes ClusterIP（API server 的 svc IP）
- kube-proxy 走了 in-cluster config（因为 `--kubeconfig` 参数缺失）
- in-cluster config 指向 10.96.0.1:443，但 ClusterIP 依赖 kube-proxy 自身规则路由
- 形成死锁：kube-proxy 需要 API server 来加载规则，但 API server 的 ClusterIP 需要 kube-proxy 规则才能路由

根因：DaemonSet 命令行缺少 `--kubeconfig=/var/lib/kube-proxy/kubeconfig.conf`，导致 kube-proxy 忽略 configmap 中的 `server: https://10.0.0.61:6443`，改走 in-cluster config 连 10.96.0.1。

### 步骤 5：补上 --kubeconfig 参数

```
kubectl patch ds -n kube-system kube-proxy --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command",
        "value":["/usr/local/bin/kube-proxy","--proxy-mode=iptables",
                   "--hostname-override=$(NODE_NAME)",
                   "--kubeconfig=/var/lib/kube-proxy/kubeconfig.conf"]}]'
```

重启 pod 后正常。

## 修复后状态

| 检查项 | 结果 |
|--------|------|
| 进程命令行 | `--proxy-mode=iptables --kubeconfig=/var/lib/kube-proxy/kubeconfig.conf` |
| nft segfault | 修复后 dmesg 无新 segfault |
| iptables KUBE-SERVICES | 已安装，8+ 条服务规则 |
| iptables KUBE-MARK-MASQ | 170 references，活跃 |
| iptables KUBE-NODEPORTS | 30080/30226/30156 等 NodePort 规则 |
| sync 指标 | `kubeproxy_sync_proxy_rules_last_timestamp_seconds` 最新 |
| 服务连通性 | NodePort 30080 可达，ClusterIP 可达 |

## 遗留问题

1. **nftables v1.0.9 segfault** — 仍存在于系统，未修复（升级 nftables 包或降内核）
2. **clusterCIDR → clusterCIDRs** — configmap 中字段名错误，未修正
3. **DaemonSet command 而非 args** — 当前用 `command` 覆盖了容器入口点，非标准做法，建议改为 `args`

## 影响评估

- 服务当前正常，kube-proxy iptables 规则已生效
- nft 二进制崩溃仍存在但不再被 kube-proxy 调用
- Calico BPF 仍运行，与 kube-proxy iptables 模式并存
