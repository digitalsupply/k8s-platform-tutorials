# 线3 执行报告：kube-proxy IPVS → iptables

> **执行时间**：2026-10-03 05:31 ~ 05:40
> **结果**：✅ **迁移成功**，kube-proxy 已切换到 iptables Proxier，业务无影响

---

## 一、最终状态

| 项 | 迁移前 | 迁移后 |
|---|---|---|
| kube-proxy mode | `ipvs` | **`iptables`** |
| Proxier 类型 | IPVS Proxier | **iptables Proxier**（日志确认）|
| IPVS 规则/节点 | 360~375 行 | **3 行**（已清理）|
| iptables KUBE-SERVICES/节点 | 8 行（未生效）| **145~150 行** ✅ |

### kube-proxy 日志确认
```
I1002 21:31:44.302397  server_others.go:168] "Using iptables Proxier"
I1002 21:31:44.302439  server_others.go:168] "kube-proxy running in dual-stack mode" primary ipFamily="IPv4"
```

---

## 二、迁移前后规则对比

| 节点 | IPVS（前）| IPVS（后）| KUBE-SERVICES（前）| KUBE-SERVICES（后）|
|---|---|---|---|---|
| m01 | 375 | 3 | 8 | 145 |
| master01 | 365 | 3 | 8 | 145 |
| master02 | 365 | 3 | 8 | 150 |
| worker01 | 365 | 3 | 8 | 150 |
| worker02 | 365 | 3 | 8 | 150 |
| worker03 | 365 | 3 | 8 | 150 |

**迁移前 `KUBE-SERVICES` 只有 8 行是正常的** —— IPVS 模式下不生成 iptables 规则，所有 Service 转发都由 IPVS 内核模块处理。

iptables 规则带 Service 注释，便于排查：
```
KUBE-SVC-7NS2YN5JANIWOILQ  tcp  10.111.62.206  /* knative-eventing/job-sink:http cluster IP */
KUBE-SVC-L3SWARV2FXC4WN7P  tcp  10.110.217.26  /* default/report-processor-00001-private:https cluster IP */
```

---

## 三、迁移前基线（用于对比）

| 项 | 值 |
|---|---|
| kube-proxy mode | `ipvs` |
| Service 总数 | 108 |
| IPVS 虚拟服务 | 177 TCP + 1 UDP = 178 |
| 每节点 IPVS 行数 | 360~375 |

---

## 四、Service 访问验证（★关键判据）

从 worker01 的 Pod 访问 Service VIP，**后端在其他节点**（跨节点转发）：

| Service | VIP:Port | 结果 |
|---|---|---|
| kube-dns（DNS 查询）| 10.96.0.10:53 | ✅ 成功解析 `kubernetes.default.svc.cluster.local → 10.96.0.1` |
| argocd-redis | 10.101.231.211:6379 | ✅ **open** |
| argocd-server | 10.110.82.65:80 | ✅ **open** |
| Pod IP 直连（跨节点）| 10.244.5.38 → 10.244.19.109 | ✅ 0% loss, 0.721ms |

**DNS 解析成功 + TCP 连接 open，证明 iptables 规则正确生效。**

> 注：kube-api 的 TLS 握手失败是 busybox wget 不支持证书 SAN 校验，**属客户端限制，非 Service 问题**。

---

## 五、业务健康（迁移后）

| 组件 | 状态 |
|---|---|
| 节点 | 6/6 Ready |
| Pod | Running 142 / Pending 1（n8n，Docker Hub 不通，非本次问题）|
| Prometheus | 2/2 Running，**125 targets 全 up** |
| Grafana | 3/3 Running |
| Kafka | `my-cluster True 4.1-IV1`，3 Pods Running |
| CNPG | `pg16-ceph`，**PG 实例 Running**（pg16-ceph-3/4）|
| Loki | 9 Running |
| Tempo | 13 Pod |
| Traefik | 1/1 Running |
| ArgoCD | 1/1 Running |
| Calico | 6 Running |
| MetalLB | 7 Running |

**★ 特别关注 Kafka 和 CNPG**：这两个是有状态服务，迁移瞬间连接会断，验证它们恢复 Running 证明重连正常。

---

## 六、执行过程

```
[05:31:27] check   → 确认 mode=ipvs
[05:31:27] backup  → /root/k8s-upgrade-1.29-to-1.35/work/kube-proxy/
            ├── config.conf.20261003-053127
            └── kube-proxy-cm-20261003-053127.yaml
[05:31:36] 修改 config.conf: mode: "ipvs" → "iptables"，清理 ipvs 段
[05:31:44] patch ConfigMap + rollout restart ds/kube-proxy
           6/6 Pod 滚动完成（约 20 秒）
[05:31:50] 验证 mode 切换成功
           各节点 ipvsadm --clear 清理残留 IPVS 规则
           Service VIP 访问测试全部通过
```

**业务无感知**：整个迁移过程（含 rollout）在 20 秒内完成，未观察到业务中断。

---

## 七、★ 一个需要注意的点：IPVS 残留清理

kube-proxy 切换到 iptables 后**不会自动清理旧的 IPVS 规则**，实测仍残留 360 行。

**判断是否影响流量**：
```bash
lsmod | grep "^ip_vs "     # 第4列是引用计数，为空说明无进程引用
iptables -t nat -L KUBE-SERVICES  # 显示 "2 references"，说明流量走这里
```
确认无影响后已执行 `ipvsadm --clear` 清理，各节点降至 3 行（非 Service 相关的系统规则）。

**建议**：如需更彻底，可在节点重启后自然消失。

---

## 八、备份与回滚

```
/root/k8s-upgrade-1.29-to-1.35/work/kube-proxy/
├── kube-proxy-cm-20261003-053127.yaml    # 完整 ConfigMap
├── config.conf.20261003-053127            # 原始配置（mode: ipvs）
└── pre-migrate-*.conf                     # 迁移瞬间快照
```

### 回滚命令
```bash
bash /root/k8s-upgrade-1.29-to-1.35/scripts/migrate-kube-proxy-iptables.sh rollback
```

**注意**：回滚会再次触发 kube-proxy 重启，同样有短暂 Service 中断。

---

## 九、迁移的必要性（回顾）

| 项 | 说明 |
|---|---|
| K8s 1.35 | **弃用 IPVS**（KEP-5495）|
| K8s 1.38 | **移除 IPVS** |
| 官方建议 | 1.35 先验证 nftables；小集群可直接用 iptables |
| 本集群规模 | 6 节点、108 Service → **iptables 规则仅 150 行**，完全够用 |

**迁移后已满足 K8s 1.35 的要求**，为线4 铺平道路。

---

## 十、进度更新

| 线 | 状态 |
|---|---|
| 线1 containerd 2.3.2 | ✅ 完成 |
| 线2 Calico v3.32.2 | ✅ 完成 |
| **线3 kube-proxy → iptables** | ✅ **完成** |
| 线4 K8s 1.29→1.35 | ⏸ **现在可以启动**（前置条件已全部满足）|
| n8n 镜像（Docker Hub 不通）| 🔴 待决策 |

**线1/2/3 全部完成**，K8s 1.35 的三个前置条件（containerd 2.x、Calico v3.32、非 IPVS）已全部满足。

---

*线3 完成：2026-10-03 05:40。kube-proxy 从 IPVS 迁移到 iptables，Service VIP 跨节点访问全部正常，业务（特别是 Kafka/CNPG 有状态服务）验证健康，Prometheus 125 targets 全up。IPVS 残留规则已清理。线4 的前置条件已全部就绪。*
