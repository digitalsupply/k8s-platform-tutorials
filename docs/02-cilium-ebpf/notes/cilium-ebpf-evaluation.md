# Cilium eBPF 切换评估报告

## 当前集群状态

| 项目 | 值 |
|------|-----|
| K8s 版本 | 1.35.9 |
| Calico | v3.32.2 (BPF + IPIP) |
| kube-proxy | iptables 模式（刚修复） |
| 存储 | Ceph RGW 10.0.0.31:7480 |
| 节点 | 6 台（3 CP + 3 worker） |
| 节点 | 内核 | nftables | BTF |
|------|------|----------|-----|
| m01 | 5.14.0-570.58.1.el9_6 | v1.0.9 | ✓ |
| master01 | 5.15.0-179-generic | v1.0.2 | ✓ |
| master02 | 5.15.0-179-generic | v1.0.2 | ✓ |
| worker01 | 5.15.0-179-generic | v1.0.2 | ✓ |
| worker02 | 5.15.0-179-generic | v1.0.2 | ✓ |
| worker03 | 5.15.0-179-generic | v1.0.2 | ✓ |

## 可行性分析

### 兼容性

| 要求 | 最低 | 当前 | 达标 |
|------|------|------|------|
| K8s | 1.26+ | 1.35.9 | ✓ |
| 内核 | 5.10 | 5.14 / 5.15 | ✓ |
| BTF | 推荐 | m01 有 | 需验其余节点 |
| 架构 | amd64/arm64 | x86_64 | ✓ |

Cilium v1.18+ 官方支持 K8s 1.35。社区确认 v1.18.6 可运行在 K8s 1.35。

### Cilium 取代的功能
- kube-proxy：eBPF 直接实现 Service/NodePort 转发
- Calico 网络策略：CiliumNetworkPolicy 替代
- Calico BPF：Cilium eBPF 数据面更完整

### Cilium 无法直接替代的
- Ceph CSI 存储网络（需保留 Calico 或 Cilium 兼容模式）
- Calico IPIP 隧道（Cilium 可选 IPIP/VXLAN/WireGuard）

## 优点

1. **彻底解决 nftables segfault** — 不再依赖 nftables 用户态工具
2. **性能** — eBPF 连接跟踪 + 直接路由，延迟低于 iptables
3. **可观测性** — Hubble 集成，提供 L3/L4/L7 流量可视化
4. **网络策略** — 基于身份而非 IP，支持 L7 HTTP 策略
5. **kube-proxy-free** — 移除 kube-proxy 组件，减少维护面
6. **自动故障恢复** — eBPF 程序内核态运行，不依赖 userspace 守护进程

## 缺点与风险

1. **迁移复杂度** — 必须先删 Calico 再装 Cilium，不能并存
2. **停机风险** — CNI 切换期间网络中断，需维护窗口
3. **Ceph 兼容性** — Ceph CSI 依赖 CNI 路由，需验证 Cilium IPAM 与 Ceph 网络不冲突
4. **Knative/Kourier** — 当前 Knative 用 Kourier (Traefik)，Cilium 不影响但需验证 Ingress
5. **Kafka** — Broker 间通信依赖 Calico IPIP，切换后需用 Cilium BPF 或 IPIP 模式
6. **BTF 一致性** — 其余 5 台节点 BTF 状态未知，不均一可能导致回退
7. **回滚困难** — Calico 清理后若 Cilium 出问题，无快速回退路径
8. **运维成本** — 团队熟悉 Calico，Cilium 学习曲线

## 关键验证项

- [ ] 所有 6 台节点 `/sys/kernel/btf/vmlinux` 存在
- [ ] Ceph CSI  pod 在 Cilium 下正常通信
- [ ] Knative Kourier Ingress 正常
- [ ] Kafka  broker 间通信正常
- [ ] ArgoCD 应用同步正常
- [ ] L3/L4 网络策略迁移（CalicoNetworkPolicy → CiliumNetworkPolicy）

## 推荐的评估步骤

1. 在非生产环境先行测试 Cilium v1.18/1.19 安装
2. 逐个节点验证 BTF 状态
3. 准备 Calico → Cilium 迁移 checklist（包括 IPPool、CIDR、NetworkPolicy）
4. 选择业务低峰期执行迁移
5. 保留 Calico 配置备份，必要时可快速还原

## 结论

**可行，但风险中等。** K8s 1.35 + 内核 5.14/5.15 满足最低要求，BTF 在 m01 已确认。最大的不确定因素是 Ceph CSI 和 Kafka 在 Cilium eBPF 模式下的兼容性，建议先在非生产环境完整验证后再决定。
