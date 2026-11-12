# 监控栈契约（配置事实，不是状态快照）

> **本文件已降级**：原来这里是一份"当前状态快照"，与 `00-cluster-overview/assets/current-state.md` 重复，
> 两份一起漂移（例如 PrometheusRule 数量 44 与实际 43 不一致）。
> 2026-11-11 起：**所有会变的数字一律去** [current-state](../00-cluster-overview/assets/current-state.md) **取**（§3 对象计数、§4 组件版本、§5 Prometheus 运行态）。
>
> 本文件只保留**不随环境变化的契约**：selector 怎么配、CRD 归谁管、Alertmanager 有哪些接收器、Grafana 的部署约束。
> 命令默认使用 `export KUBECONFIG=~/.kube/deeptutor-config`。

## 1. 版本

版本会变，本文不再维护 —— 直接看 [current-state](../00-cluster-overview/assets/current-state.md) §4 组件版本。
本文只记**与监控栈强绑定**的一条：chart 是 `kube-prometheus-stack`，operator 由该 chart 一起装，
所以升级 either 一起升；`prometheus-adapter` 是独立 release。

## 2. ArgoCD 应用（只列名单，数量见 current-state §3）

监控相关 5 个：`platform-monitoring-stack`、`platform-monitoring-crds`、`platform-monitoring-rules`、
`platform-monitoring-wecom`、`platform-grafana`。
`platform-alloy-config` 管 Alloy 配置，`platform-grafana-operator` 管 Grafana 的 CRD/operator。
验收只看这 5 个是不是 Synced/Healthy；应用总数与健康度实时值见 [current-state](../00-cluster-overview/assets/current-state.md) §3 / `kubectl -n argocd get applications`。

> 监控改造的验收只看监控相关 App；SSO 的 Progressing 不影响本文结论。

## 3. 规则（数量见 current-state §3 / §5，这里只讲归属）

- 所有 PrometheusRule 都带 `platform.gitops/managed: "true"`（**这是硬约束**：不带就被 ruleSelector 丢掉，规则静默失效）；
- 来源分四类：chart 自带（kube-prometheus-stack 35 个左右）+ platform 自建 + 业务命名空间自建（deeptutor/compassio）；
- 每条自建规则必须两个标签齐全：`release: prometheus` + `platform.gitops/managed: "true"`。

规则条数、组数、求值错误数、firing 列表 —— 见 [current-state](../00-cluster-overview/assets/current-state.md) §5。

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
| Dashboard | 数量会变（本文不记）；验收看 Grafana 里 `NoMatchingInstance` 为 0 |
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
