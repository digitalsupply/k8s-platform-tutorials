# 组件下线检查清单

> 复制到变更单/工单里逐项勾选。任何一项不确认，不要开始删除。

## 1. 依赖确认

- [ ] 业务 CR 实例数为 0（`kubectl get <cr> -A`）
- [ ] 没有 Service/Ingress/IngressRoute 指向该组件
- [ ] 没有 ConfigMap/Secret 被其他工作负载引用
- [ ] 没有跨命名空间引用
- [ ] 没有 ArgoCD Application / Helm release 继续管理
- [ ] 没有 CronJob/Job 依赖
- [ ] 监控/告警规则已确认归属

## 2. 备份

- [ ] 命名空间内全部资源 YAML
- [ ] CRD + CR 全量 YAML
- [ ] ClusterRole / ClusterRoleBinding / Webhook / APIService
- [ ] Helm values / release manifest
- [ ] 相关 PVC 数据（如需要）
- [ ] 备份文件校验可读、大小正常

## 3. 执行顺序

- [ ] 停流量 / 缩容到 0
- [ ] **先删 CR**（此时 controller 还在，由它走完 finalizer；这一步不能放到卸载之后）
- [ ] 卸载 Operator 或 Helm release（`helm uninstall` 不删 `crds/` 里的 CRD）
- [ ] 删除 CRD（会**级联删除**剩余 CR，不可恢复；`kubectl wait --for=delete`）
- [ ] 删除 Webhook，再删 APIService
- [ ] 按 label + binding subject 删除 RBAC
- [ ] 删除命名空间（确认不卡 `Terminating`）
- [ ] 清理 ServiceMonitor/PodMonitor/PrometheusRule
- [ ] 清理 Grafana Dashboard / 数据源

## 4. 验证

- [ ] `kubectl get --raw='/readyz?verbose'` 正常
- [ ] `kubectl get apiservice` 无 `False`
- [ ] CoreDNS / Ingress / ArgoCD 正常
- [ ] Prometheus targets 无新增 down
- [ ] 相关告警已删除，无残留 firing
- [ ] 节点/Pod 资源已释放

## 5. 回滚预案

- [ ] 记录删除前的资源清单
- [ ] 确认 CRD/CR 可重新 apply
- [ ] 确认 Operator/Helm 可重装
- [ ] 确认 PVC/数据未被不可逆删除
- [ ] 明确回滚决策人和时间窗口
