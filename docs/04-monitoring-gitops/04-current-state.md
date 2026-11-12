# 当前集群状态快照（2026-11-10）

> 这是整理文档时的实际状态，后续会变化。
> 命令默认使用 `export KUBECONFIG=~/.kube/deeptutor-config`。

## 1. 集群与版本

| 项 | 值（采集 2026-11-11） |
|---|---|
| Kubernetes | v1.35.9（kubeadm） |
| 节点 | 3 control-plane + 3 worker |
| CNI | Cilium 1.20.4 |
| ArgoCD | v3.5.3 |
| kube-prometheus-stack | 83.7.0 |
| prometheus-operator | v0.90.1 |
| Prometheus | v3.11.2 |
| Alertmanager | v0.32.0 |
| prometheus-adapter | 5.3.0 |

## 2. ArgoCD 应用

| 项 | 状态 |
|---|---|
| 应用总数 | 31 |
| 监控相关 | `platform-monitoring-stack`、`platform-monitoring-crds`、`platform-monitoring-rules`、`platform-monitoring-wecom`、`platform-grafana` 全部 Synced/Healthy |
| 其他 | `platform-sso-oauth2-proxy` 当时为 Synced/Progressing，属于监控之外的独立应用 |

> 监控改造的验收只看监控相关 App；SSO 的 Progressing 不影响本文结论。

## 3. 规则

| 项 | 值 |
|---|---|
| PrometheusRule 总数 | 44 |
| 带 `platform.gitops/managed=true` | 44 |
| 来源 | 35 chart + 6 platform + 2 deeptutor + 1 compassio |
| Prometheus 加载 | 51 alerting groups / 248 alerting rules；16 recording groups / 94 recording rules |
| health 异常 | 0（规则求值本身无错；注意 `KubeProxyDown`/Ceph 两条曾因组件下线而常驻 firing，2026-11-11 已清理） |

## 4. Selector

```yaml
# Prometheus CR
ruleSelector:
  matchLabels:
    release: prometheus
    platform.gitops/managed: "true"

# Alertmanager CR
alertmanagerConfigSelector:
  matchLabels:
    platform.gitops/managed: "true"
alertmanagerConfigNamespaceSelector: {}
```

## 5. CRD

| 项 | 值 |
|---|---|
| 管理 App | `platform-monitoring-crds` |
| 数量 | 10 |
| 版本 | 0.90.1 |
| sync-wave | -10 |
| prune | false |
| 主监控栈 | `skipCrds: true` |

## 6. Alertmanager

| 项 | 值 |
|---|---|
| 路由 | n8n + wecom，两者 `continue: true` |
| 企业微信 | `wecom-adapter` 2 副本，GitOps 管理 |
| webhook | SealedSecret `wecom-adapter` |
| 适配器健康 | `/healthz` 200 |
| DNS | `qyapi.weixin.qq.com` 解析正常 |

## 7. Grafana

| 项 | 值 |
|---|---|
| admin Secret | `prometheus-grafana-admin`（SealedSecret） |
| Deployment 策略 | `Recreate`（规避 RWO 死锁） |
| Dashboard | 37 个，`NoMatchingInstance` 为 0 |
| 登录 | API 200 |

## 8. 验证命令

```bash
export KUBECONFIG=~/.kube/deeptutor-config

# 应用
kubectl -n argocd get applications

# 规则数量与标签
kubectl get prometheusrules -A -o json \
  | jq '{total:(.items|length),
         labelled:([.items[]|select(.metadata.labels["platform.gitops/managed"]=="true")]|length)}'

# 规则健康度
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules \
  | jq '{groups:(.data.groups|length),
         alerts:([.data.groups[].rules[]|select(.type=="alerting")]|length),
         bad:([.data.groups[].rules[]|select(.health!="ok")]|length)}'

# selector
kubectl -n monitoring get prometheus prometheus-prometheus \
  -o jsonpath='{.spec.ruleSelector}{"\n"}'
kubectl -n monitoring get alertmanager prometheus-alertmanager \
  -o jsonpath='{.spec.alertmanagerConfigSelector}{"\n"}'

# CRD
kubectl -n argocd get app platform-monitoring-crds
kubectl get crd -o json | jq -r '.items[]
  | select(.metadata.name|test("monitoring.coreos.com$"))
  | [.metadata.name, .metadata.annotations["operator.prometheus.io/version"]]
  | @tsv'
```

## 9. 已知限制

1. `platform-monitoring-stack` 的 `prune: false`
   - 从 Git 删除 chart 资源不会自动删除集群对象。
2. CRD 由独立 App 管理
   - 升级 chart 时要更新 `platform/monitoring/crds/` 并提交。
3. 运行时状态不在 Git
   - Prometheus TSDB、Alertmanager silences/nflog、PVC 数据。
4. n8n webhook 仍可能失败
   - 当时有 Cloudflare `connection reset`，属于外部 n8n/Cloudflare 问题，
     与企业微信链路无关。
5. 标签不是安全边界
   - 有写权限的人仍可伪造 `platform.gitops/managed=true`；
     真正强制需要 RBAC / Kyverno / OPA。
6. Helm release 仍在（revision 13），但已由 ArgoCD 接管
   - 不要再执行 `helm upgrade/rollback prometheus`。
