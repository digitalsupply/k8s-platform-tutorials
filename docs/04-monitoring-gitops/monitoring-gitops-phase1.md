# K8s 监控告警 GitOps 改造记录（第一期）

> 集群：`https://10.0.0.168:6443`（kubeadm，v1.35.9）
> 命名空间：`monitoring`
> 记录时间：2026-11-09
> 提交：`9a341c2 feat(monitoring): manage PrometheusRules in GitOps and route alerts to WeCom`

---

## 1. 背景与目标

`monitoring` 命名空间的 kube-prometheus-stack 由 Helm release `prometheus` 管理，
不在 ArgoCD 范围内。命名空间中有 6 个手工 `kubectl apply` 的 PrometheusRule，
存在以下问题：

- 无 Git 记录，无法审计和回滚；
- 与集群实际状态可能漂移；
- `wecom-adapter` 企业微信告警适配器已部署，但 Alertmanager 没有引用它，
  企业微信链路实际不可用。

第一期目标：

1. 把 6 个自建 PrometheusRule 纳入 ArgoCD GitOps；
2. 修复 Alertmanager → wecom-adapter → 企业微信 告警链路。

---

## 2. 改造前现状

### 2.1 监控栈

| 组件 | 版本 | 管理方式 |
|---|---|---|
| kube-prometheus-stack | 83.7.0 | Helm release `prometheus` |
| Prometheus | v3.11.2 | Prometheus Operator |
| Alertmanager | v0.32.0 | Prometheus Operator |
| ArgoCD | v3.5.3 | Helm release `argocd` |

Prometheus 规则选择器：

```yaml
ruleSelector:
  matchLabels:
    release: prometheus
ruleNamespaceSelector: {}
```

即：任意命名空间、带 `release: prometheus` 标签的 PrometheusRule 都会被加载。

### 2.2 规则分布（共 44 个）

| 来源 | 数量 | 原管理方式 |
|---|---:|---|
| kube-prometheus-stack chart | 35 | Helm |
| `monitoring` 自建规则 | 6 | `kubectl apply`（手工） |
| `deeptutor` 团队规则 | 2 | ArgoCD App `deeptutor` |
| `compassio` 团队规则 | 1 | ArgoCD App `compassio` |

`monitoring` 下 6 个自建规则：

| 规则 | 分组 | 告警数 |
|---|---|---:|
| `app-monitoring-alerts` | cert-manager / tekton / traefik / kafka / storage / cnpg | 9 |
| `bsm-coverage-alerts` | bsm.availability / bsm.coverage | 12 |
| `ceph-cluster-alerts` | ceph.health / mon / osd / pg / capacity | 19 |
| `cluster-wide-alerts` | pod / node / otel-demo / workload / cache | 15 |
| `coverage-gap-alerts` | logging / cni / lb / gitops / default-workloads | 11 |
| `tempo3-alerts` | tempo3.availability / intake / query / storage / pipeline | 20 |

### 2.3 Alertmanager 配置链路

```text
platform/monitoring/values.yaml
  └─ alertmanager.config
       └─ Secret alertmanager-prometheus-alertmanager
            └─ Operator 校验/规范化
                 └─ Secret alertmanager-prometheus-alertmanager-generated
                      └─ Alertmanager Pod 挂载
```

改造前只有 `n8n-webhook` 一个 receiver，企业微信适配器未被引用。

---

## 3. 第一期实施：规则纳入 GitOps

### 3.1 新增仓库结构

```text
platform/monitoring/
├── values.yaml
├── README.md
└── rules/
    ├── kustomization.yaml
    ├── app-monitoring-alerts.yaml
    ├── bsm-coverage-alerts.yaml
    ├── ceph-cluster-alerts.yaml
    ├── cluster-wide-alerts.yaml
    ├── coverage-gap-alerts.yaml
    └── tempo3-alerts.yaml

clusters/prod/applications/
└── platform-monitoring-rules.yaml
```

`kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# 所有规则必须保留 label release=prometheus，
# Prometheus CR 的 ruleSelector 依赖该标签做集群范围发现。
resources:
  - app-monitoring-alerts.yaml
  - bsm-coverage-alerts.yaml
  - ceph-cluster-alerts.yaml
  - cluster-wide-alerts.yaml
  - coverage-gap-alerts.yaml
  - tempo3-alerts.yaml
```

### 3.2 ArgoCD Application

`clusters/prod/applications/platform-monitoring-rules.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-monitoring-rules
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  project: default
  source:
    repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
    targetRevision: main
    path: platform/monitoring/rules
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 10
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

> `prune` 只作用在 `platform/monitoring/rules/` 目录，不会删掉 chart 生成的规则。

### 3.3 导出与清理

导出时删除 `uid`、`resourceVersion`、`generation`、`creationTimestamp`、
`managedFields`、`annotations`、`status`，保留 `metadata.labels.release: prometheus`。

同时清理重复告警：

- `MetalLBSpeakerNotReady` 在 `bsm-coverage-alerts` 和 `coverage-gap-alerts`
  中完全重复；
- 保留 `bsm-coverage-alerts`，从 `coverage-gap-alerts` 删除。

### 3.4 结果

| 检查项 | 结果 |
|---|---|
| ArgoCD App `platform-monitoring-rules` | Synced / Healthy |
| revision | `9a341c2339ea993690935bd686ee93378939a313` |
| ArgoCD 跟踪的规则 | 6 个 |
| PrometheusRule 总数 | 44（35 chart + 6 GitOps + 3 团队） |
| Prometheus 加载 | 251 alerting + 94 recording，health 全部 ok |
| `MetalLBSpeakerNotReady` 重复 | 0（仅保留 1 份） |

验证命令：

```bash
kubectl -n argocd get app platform-monitoring-rules
kubectl get prometheusrules -A | grep -E 'app-monitoring|bsm|ceph-cluster|cluster-wide|coverage-gap|tempo3'

kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules \
  | jq '[.data.groups[].rules[]|select(.health!="ok")]|length'
```

---

## 4. 企业微信告警链路修复

### 4.1 现象

`wecom-adapter` Pod 正常运行、`/healthz` 返回 200，但调用企业微信失败：

```text
level=ERROR msg=delivery failed alertname=None state=None
errcode=transport errmsg=URLError: <urlopen error [Errno -3] Try again>
```

`Errno -3` 是 DNS 解析失败（EAI_AGAIN）。

### 4.2 定位过程

1. 从适配器 Pod 内解析域名：

   ```bash
   kubectl -n monitoring exec -i deploy/wecom-adapter -c adapter -- python3 - <<'PY'
   import socket
   for h in ["qyapi.weixin.qq.com", "kubernetes.default.svc.cluster.local"]:
       try:
           print(h, socket.getaddrinfo(h, 443)[0][4])
       except Exception as e:
           print(h, "FAIL", type(e).__name__, e)
   PY
   ```

   结果：全部 `gaierror [Errno -3] Try again`。

2. 直接向 DNS 服务器发包：

   | 目标 | 结果 |
   |---|---|
   | `10.96.0.10:53`（kube-dns ClusterIP） | 超时 |
   | CoreDNS Pod IP `10.244.4.26:53` | 超时 |
   | `8.8.8.8:53` | 成功 |

3. 临时给适配器加一条 allow-all egress NetworkPolicy，DNS 立即恢复，
   确认是 NetworkPolicy 问题。

### 4.3 根因

`wecom-adapter` NetworkPolicy 的 egress 规则：

```yaml
egress:
  - ports:
      - {port: 443, protocol: TCP}
    to:
      - ipBlock: {cidr: 0.0.0.0/0}
  - ports:
      - {port: 53, protocol: UDP}
      - {port: 53, protocol: TCP}
    to:
      - ipBlock: {cidr: 0.0.0.0/0}
```

在 Cilium 下，`ipBlock: 0.0.0.0/0` 能放行到外部 DNS（8.8.8.8），
但**不能匹配 kube-dns ClusterIP 的后端 Pod 身份**，导致集群内 DNS 全部被丢。

### 4.4 修复

显式放行到 kube-dns Pod：

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - {port: 53, protocol: UDP}
      - {port: 53, protocol: TCP}
  - to:
      - ipBlock: {cidr: 0.0.0.0/0}
    ports:
      - {port: 443, protocol: TCP}
```

修复后验证：

```text
dns -> 43.135.106.8
tcp443 -> ok ('43.135.106.8', 443)
```

### 4.5 Alertmanager 路由

更新 `platform/monitoring/values.yaml`：

```yaml
alertmanager:
  config:
    route:
      receiver: n8n-webhook
      routes:
        - matchers:
            - severity =~ "critical|warning"
          receiver: n8n-webhook
          continue: true
        - matchers:
            - severity =~ "critical|warning"
          receiver: wecom
    receivers:
      - name: wecom
        webhook_configs:
          - url: http://wecom-adapter.monitoring.svc:8080/
            send_resolved: true
            max_alerts: 10
      - name: n8n-webhook
        webhook_configs:
          - url: https://***（保持原值）
            send_resolved: true
```

路由效果：

| 级别 | n8n | 企业微信 |
|---|---|---|
| critical / warning | ✅ | ✅ |
| info / none | ✅ | ❌ |

应用方式（沿用 README 约定，`--reuse-values` 保留 Grafana adminPassword）：

```bash
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 \
  -f platform/monitoring/values.yaml \
  --reuse-values
```

Helm revision：9，状态 `deployed`。

### 4.6 验证

1. 适配器直发测试：

   ```text
   http=200
   {"delivered": true, "bytes": 516}
   ```

2. Alertmanager 端到端注入临时告警 `WeComRouteTest`：

   ```bash
   curl -X POST http://localhost:9093/api/v2/alerts \
     -H 'Content-Type: application/json' \
     -d '[{"labels":{"alertname":"WeComRouteTest","severity":"warning", ...}}]'
   ```

   适配器收到多次 `POST 200`，无 delivery failed。

3. 适配器统计：

   | Pod | received | sent | failed |
   |---|---:|---:|---:|
   | `wecom-adapter-7ddcb575f-jthfk` | 5 | 5 | 0 |
   | `wecom-adapter-7ddcb575f-phlxl` | 5 | 4 | 1（修复前空请求） |

4. 测试告警已自动过期清理，无残留。

> 启用路由时，Alertmanager 会把当前已有的 critical/warning 分组补发到企业微信群，
> 属于正常行为。

---

## 5. 遗留问题与后续

1. **n8n webhook 自身异常**
   Alertmanager 日志持续报
   `Post "https://n8n.example.com/...": connection reset by peer`（Cloudflare IP）。
   这是改造前就存在的问题，与企业微信链路无关，建议检查 n8n 服务或 Cloudflare 配置。

2. **wecom-adapter 仍是手工资源**
   Deployment / Service / ConfigMap / NetworkPolicy / Secret 尚未纳入 GitOps；
   本次 NetworkPolicy 修复是 live 变更，README 已记录，但未版本化。

3. **适配器双副本限流**
   2 个副本各自 3s/条，实际是 2 倍速率；如需严格 20 条/分钟，应改单副本或共享限流。

4. **第二期/第三期**
   - 第二期：团队规则 / AlertmanagerConfig 规范化，wecom-adapter 整体 GitOps 化；
   - 第三期：kube-prometheus-stack 整体纳入 ArgoCD。

---

## 6. 变更清单

```text
platform/monitoring/rules/kustomization.yaml
platform/monitoring/rules/app-monitoring-alerts.yaml
platform/monitoring/rules/bsm-coverage-alerts.yaml
platform/monitoring/rules/ceph-cluster-alerts.yaml
platform/monitoring/rules/cluster-wide-alerts.yaml
platform/monitoring/rules/coverage-gap-alerts.yaml
platform/monitoring/rules/tempo3-alerts.yaml
clusters/prod/applications/platform-monitoring-rules.yaml
platform/monitoring/values.yaml
platform/monitoring/README.md
```

集群侧：

- NetworkPolicy `monitoring/wecom-adapter` 更新（DNS egress + 443）；
- Helm release `prometheus` 升级到 revision 9（Alertmanager 增加 wecom receiver）。
