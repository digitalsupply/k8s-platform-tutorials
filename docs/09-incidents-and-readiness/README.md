# 09 · 生命周期与生产化：组件下线、清理与差距审计

## 当时的情况

这套集群经历过多次“加法”和“减法”：

- 装过 Knative Serving/Eventing、Tekton demo、Zabbix、MariaDB、nginx/php-fpm；
- 后来因为业务不需要、资源紧张、维护成本高，逐步下线；
- 同时做了一次生产化差距审计，发现“功能齐全”不等于“可生产”。

典型下线对象：

| 对象 | 规模 | 风险点 |
|---|---|---|
| Knative | 3 个 ns、32 CRD、37 ClusterRole、19 APIService、14 PodMonitor | CRD/APIService/Webhook 残留会阻塞 API |
| Tekton demo | demo Pipeline/PVC/Trigger | 容易误删仍在服役的 Tekton 本体 |
| 宿主机应用 | Zabbix/MariaDB/nginx/php-fpm | exporter 依赖、systemd 依赖、端口占用 |
| 旧镜像/磁盘 | 全集群 containerd 92GB | kubelet GC 阈值 85% 从不触发 |

## 主要概念与原理

### 1. 删除一个组件的正确顺序

```text
盘点依赖 → 备份 → 停流量/缩容 → 卸载控制器（Operator/Helm）
→ 删自定义资源 → 删 CRD → 删 Webhook/APIService → 删 RBAC → 删命名空间
→ 验证 API 健康 → 清理监控/告警
```

顺序反了会出现：

- CRD 删了但 CR 还在 → 孤儿对象；
- Webhook 删了但 APIService 还在 → API 请求失败；
- RBAC 删了但 controller 还在 → reconcile 报错；
- 命名空间卡在 `Terminating` → finalizer 阻塞。

### 2. CRD / APIService / Webhook 的区别

| 对象 | 作用 | 删除影响 |
|---|---|---|
| CRD | 定义自定义资源类型 | 删除会级联删除所有 CR |
| APIService | 聚合 API（如 metrics.k8s.io） | 删除/后端不可用会让对应 API 503 |
| ValidatingWebhook | 准入校验 | 删除后校验失效；配置错误会阻塞所有创建 |
| MutatingWebhook | 准入变更 | 同上 |

### 3. Operator 卸载 vs 直接删 CRD

优先用 Operator 的卸载流程（如 `kubectl delete knativeserving`），它会：

- 回收自己创建的工作负载；
- 释放 finalizer；
- 按顺序删除子资源。

直接删 CRD 会跳过这些逻辑，留下大量孤儿资源。

### 4. 生产化基线的五个维度

1. **数据与恢复**：etcd 备份、PVC 备份、恢复演练；
2. **可用性**：多副本、PDB、反亲和、入口/GitOps 不单点；
3. **容量**：磁盘/内存水位、requests/limits、HPA/VPA；
4. **安全**：RBAC、PSA、NetworkPolicy、Secret 加密、审计日志；
5. **运维卫生**：镜像清理、日志保留、告警通道、Runbook。

## 踩坑点

### 坑 1：删除命名空间卡住

Knative 的 namespace 删除时触发了一次 `--timeout`，但实际资源已删完。
`Terminating` 常见原因：

- finalizer 指向的 controller 已删除；
- APIService/Webhook 不可用；
- CRD 已删但 CR 还在。

**修复**：先查 `kubectl get ns <ns> -o json` 的 finalizers，再决定是恢复 controller
还是手工移除 finalizer（最后手段）。

### 坑 2：ClusterRole 名字不含产品名

Knative 的 `addressable-resolver`、`channelable-manipulator`、`source-observer`、
`podspecable-binding`、`kafka-controller` 等角色名字里没有 “knative”。

**修复**：按 label（`duck.knative.dev`、`app.kubernetes.io/name=knative*`）和
Binding 的 subject 双重确认归属，再删。不能只按名字 grep。

### 坑 3：APIService 的 `service: <none>`

Knative 的 19 个 APIService 都是 Local 类型，`service: <none>`。删除它们不会让
apiserver 报错；但如果留着而 CRD 已删，访问对应 API 会 404/503。

### 坑 4：删 CRD 是异步的

`kubectl delete crd` 返回成功不代表已删完。CRD 的 `deletionTimestamp` 可能停留很久，
期间 CR 仍可被创建。要 `kubectl wait --for=delete` 或轮询确认。

### 坑 5：demo 资源和生产资源混在一起

Tekton demo 时期的 PVC、Pipeline、Trigger 有些仍在服役（如 `shared-workspace`）。
清理前必须区分：

- 只属于 demo 的；
- demo 创建但后来被生产复用的；
- 生产后来新建但名字相似的。

**修复**：按 label/ownerReferences/创建时间/引用关系判断，不按名字猜。

### 坑 6：宿主机应用下线忽略 exporter

`mysqld_exporter --config.my-cnf=/etc/prometheus/.my.cnf` 依赖 MariaDB。
直接停 MariaDB，exporter 会持续报错，Prometheus target down。

**修复**：先停/改 exporter，再停数据库；最后删 systemd unit 和端口。

### 坑 7：镜像 GC 阈值导致磁盘长期不回收

kubelet 的 image GC 受 `imageGCHighThresholdPercent=85` 门控，节点没到 85% 就不清理。
本集群 containerd 占 92GB，worker02 根分区 76%。

**修复**：手工 `crictl rmi --prune` + 清理未使用镜像，回收约 52GB；
长期应配置合理的 GC 阈值和镜像仓库保留策略。

### 坑 8：把“组件能跑”当成“生产就绪”

31 个 ArgoCD App、147 个 CRD、单副本 Prometheus/Traefik/ArgoCD、无审计日志、
无 Secret 加密、kubelet 无 reserve，这些都不影响“能跑”，但都是生产风险。

## 修复关键

### 1. 组件下线检查清单

```text
[ ] 业务是否零引用（CR/Service/Ingress/ConfigMap/Secret）
[ ] 是否有跨命名空间引用
[ ] 是否有 ArgoCD Application / Helm release
[ ] 备份 CRD、CR、RBAC、Webhook、APIService、Helm values
[ ] 先卸载 Operator/Helm，再删 CR，再删 CRD
[ ] 删除 Webhook/APIService（确认后端已不存在）
[ ] 按 label + binding subject 删 RBAC
[ ] 删除命名空间并确认不卡 Terminating
[ ] 清理 ServiceMonitor/PodMonitor/PrometheusRule
[ ] 验证 apiserver /metrics、DNS、Ingress、ArgoCD
```

### 2. 生产化优先级

本集群审计结论（`production-readiness-gaps-20261109.md`）：

- **P0（6 项）**：etcd 备份（已补）、审计日志/Secret 加密、关键单副本、磁盘/内存水位、kubelet 未预留；
- **P1（9 项）**：69 个单副本、PDB/HPA/VPA 缺失、PSA/NetworkPolicy/Quota 覆盖不足、安全上下文；
- **P2（8 项）**：测试残留、日志/指标长期存储、告警单通道、NFS SPOF。

最需要先做的 5 件事：

1. ~~etcd 备份~~（已上线每小时快照）；
2. API Server 审计日志 + Secret 静态加密；
3. worker01 磁盘 74%、m01/master02 内存 84%；
4. 入口/GitOps/监控单副本；
5. kubelet `systemReserved`/`kubeReserved`/`evictionHard`。

### 3. 磁盘与镜像清理

```bash
# 只读盘点
kubectl get nodes -o wide
crictl images
crictl ps -a
du -sh /var/lib/containerd

# 清理未使用镜像（确认没有回滚需求）
crictl rmi --prune
```

## 本目录文档

| 文档 | 内容 |
|---|---|
| [knative-removal-record-20261013.md](notes/knative-removal-record-20261013.md) | Knative 全量移除：依赖评估、Operator 卸载、RBAC/CRD/APIService 清理 |
| [tekton-demo-cicd-removal-record-20261028.md](notes/tekton-demo-cicd-removal-record-20261028.md) | Tekton demo 资源清理，保留生产 Tekton |
| [app-removal-record.md](../05-linux/notes/app-removal-record.md) | 宿主机 Zabbix/MariaDB/nginx/php-fpm 下线 |
| [production-readiness-gaps-20261109.md](../00-cluster-overview/notes/production-readiness-gaps-20261109.md) | 生产化差距审计（P0/P1/P2） |
| [k8s-cluster-audit-2026-10-03.md](../01-kubernetes-k3s/notes/k8s-cluster-audit-2026-10-03.md) | 磁盘/镜像/资源巡检与 52GB 回收 |
| [default-ns-pod-provenance.md](../01-kubernetes-k3s/notes/default-ns-pod-provenance.md) | default 命名空间残留 Pod 的来源追踪 |
| [2026-11-09-weekly-postmortem-index.md](notes/2026-11-09-weekly-postmortem-index.md) | 7 轮改造总索引：CNPG、GitOps、Grafana、Sealed Secrets、Vault、存储迁移 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/pre_removal_audit.py](scripts/pre_removal_audit.py) | 按关键字盘点 CRD/APIService/Webhook/RBAC/CR，只读 |
| [scripts/cleanup_checklist.md](scripts/cleanup_checklist.md) | 组件下线检查清单（可打印/复制） |

```bash
# 下线前盘点（以 knative 为例）
python3 docs/09-incidents-and-readiness/scripts/pre_removal_audit.py knative

# 输出包括：CRD、CR 实例数、APIService、Webhook、ClusterRole/Binding、命名空间
```

> 清理是不可逆操作。先备份、先确认零引用、先卸载 Operator，再删 CRD。
