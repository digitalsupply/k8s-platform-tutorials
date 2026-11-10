# Knative 全量移除记录

- **执行时间**：2026-10-13 14:46 – 15:00 (CST)
- **集群**：k8s v1.35.9（m01 / master01 / master02 / worker01-03）
- **范围**：仅集群组件（按确认：本地文档、notes yaml、Grafana json 保留）
- **备份**：`/root/knative-full-removal-backup-20261013-144632`（19M）

---

## 一、移除前的安全评估

| 检查项 | 结论 |
|---|---|
| 业务负载 | **零**。`ksvc` / `broker` / `trigger` / `pingsource` / `kafkasource` / `sequence` / `parallel` 全空 |
| 跨命名空间引用 | 扫描 11 个 knative API group，非 knative 命名空间**零命中** |
| 10-08 的 demo 残留 | 已于 2026-10-08 提前清理，备份在 `knative-demo-cleanup-backup-20261008-223708` |
| ArgoCD | 无相关 Application |
| Strimzi Kafka | 独立运行，无 knative 创建的 topic（现存 `tempo-traces` 属 Strimzi 保留） |
| cert-manager | 无 knative 关联的 Issuer / Certificate |
| MetalLB | `lb-pool-tailscale = 10.0.0.252-253`；traefik 占 .252，kourier 占 .253。**仅释放 .253，地址池未改动** |

### 移除前的组件清单

| 位置 | 数量 |
|---|---|
| 命名空间 | `knative-serving` / `knative-eventing` / `knative-operator` |
| Serving | 7 Deployment（含 `3scale-kourier-gateway` + envoy）+ 9 Service（含 LB `kourier`=10.0.0.253）+ 15 ConfigMap |
| Eventing | 7 Deployment + 1 StatefulSet(0/0) + 4 Service + 25 ConfigMap |
| Operator | 2 Deployment，Helm release `knative-operator` v1.22.1 (rev 2) |
| CRD | 32 |
| ClusterRole | 37（22 个名字含 knative，15 个为 eventing/kafka 聚合角色，需按标签识别） |
| ClusterRoleBinding | 18（15 个 subject 在 knative ns，含 3 个名字不含 knative 的） |
| Webhook | 10 |
| APIService | 19（全部 `service: <none>`，Local 类型，删除不会产生 apiserver 报错） |
| 监控 | 14 PodMonitor + 2 ServiceMonitor + PrometheusRule 中 1 个告警组 |

---

## 二、执行步骤

| # | 动作 | 结果 |
|---|---|---|
| 0 | 全量备份（ns 资源 / 集群级 / 监控 / helm manifest+values） | 19M，15 个文件 |
| 1 | `kubectl delete knativeserving knative-serving` —— **走 operator 优雅卸载** | 11s 完成，finalizer `knativeservings.operator.knative.dev` 正常释放，serving + kourier 全部回收 |
| 2 | 删除 `knative-serving` / `knative-eventing` 命名空间 | serving 触发一次 `--timeout` 但实际已删除完成 |
| 3 | `helm uninstall knative-operator` + 删除 `knative-operator` ns | 完成，Helm release 清零 |
| 4 | 校验剩余 webhook 的 rules（确认仅作用于 `sinkbindings.sources.knative.dev`，不会阻塞无关 API） | 无阻塞风险 |
| 5 | 删除 Webhook(1) + APIService(18) + ClusterRoleBinding(15) | 无残留引用 |
| 6 | 删除 ClusterRole(37)，**删前双重校验**：① 列表全部存在 ② 按 `duck.knative.dev` / `app.kubernetes.io/name=knative*` 标签反查无遗漏 | 全部命中，零误删 |
| 7 | 复核零 CR 实例后删除 30 个 CRD | 异步完成 |
| 8 | 从 `app-monitoring-alerts` 摘除 `knative-eventing.rules` 组 | 保留 6 组：cert-manager / tekton / traefik / kafka / storage / cnpg |

**关键安全点**：ClusterRole 中 `addressable-resolver`、`channelable-manipulator`、`source-observer`、`podspecable-binding`、`kafka-controller`、`kafka-webhook-eventing` 等**名字不含 knative**，已通过 label 与 binding subject 双重确认归属后才删除；Strimzi 的 `strimzi-*` 角色未受波及。

---

## 三、验收结果

| 项 | 状态 |
|---|---|
| knative 命名空间 | **0** |
| knative CRD | **0** |
| Webhook / APIService | **0 / 0** |
| ClusterRole / Binding | **0 / 0**（含 knative 标签反查） |
| knative pod / service | **0 / 0** |
| PodMonitor / ServiceMonitor | **0** |
| PrometheusRule 中 knative | **0** |
| Helm release | **0** |
| `/apis` 发现 | 41 groups，**无 knative group**，解析正常 |
| 节点 | 6/6 Ready |
| 异常 pod | 无 |

### 邻居组件完好性

- **traefik**：`1/1 Running`（7d16h 未重启），`http(s)://10.0.0.252` 返回 404（入口存活，无匹配路由属正常）
- **10.0.0.253**：已释放，无法连接 ✅
- **MetalLB**：`lb-pool-eth1` / `lb-pool-tailscale` 两个地址池完好，traefik 正常持有 .252
- **Strimzi Kafka**（`kafka` ns）、**cert-manager**、**monitoring** 均 Active

---

## 四、备份与回滚

备份目录 `/root/knative-full-removal-backup-20261013-144632/`：

```
cluster-scoped/  crds.yaml (32 CRD 全文)  crd-names.txt  rbac.yaml
                 webhooks.yaml  apiservices.yaml  knativeserving-cr.yaml
                 namespaces.yaml  helm-knative-operator-manifest.yaml
                 helm-knative-operator-values.yaml
namespaces/      knative-serving-all.yaml  knative-eventing-all.yaml
                 knative-operator-all.yaml   （all,cm,sa,secret,networkpolicy,ingress,pdb）
monitoring/      app-monitoring-alerts.yaml（改动前原件）  monitors.yaml
```

回滚思路（如需重装）：
1. 优先用 Helm 重装 operator：`helm install knative-operator ...`（manifest/values 已备份）
2. `kubectl apply -f cluster-scoped/knativeserving-cr.yaml` 恢复 Serving（含 kourier ingress 配置）
3. Eventing 为 kubectl apply 安装，按 `namespaces/knative-eventing-all.yaml` 恢复
4. 监控：`kubectl apply -f monitoring/app-monitoring-alerts.yaml` 还原告警组

---

## 五、按约定保留未删除的内容

- `/root/knative-architecture-and-labs.md`
- `/root/cloud-native-notes/k8s/knative/`（11 个实验 yaml）
- `/root/grafana-dashboards-20260930/knative-eventing.json`
- `/root/knative-demo-cleanup-backup-20261008-223708/`（10-08 demo 备份）
