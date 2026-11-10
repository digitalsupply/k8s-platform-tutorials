# 配套资产：Monitoring GitOps YAML / Python

本目录是教程中监控 GitOps 改造的**可参考清单**，与原始平台仓库的路径对应关系如下：

| 本目录 | 原始平台仓库路径 |
|---|---|
| `applications/` | `clusters/prod/applications/platform-monitoring-*.yaml` |
| `rules/` | `platform/monitoring/rules/` |
| `wecom/` | `platform/monitoring/wecom/` |
| `stack/values.yaml` | `platform/monitoring/values.yaml` |
| `stack/sealedsecret-grafana-admin.yaml` | `platform/monitoring/stack/sealedsecret-grafana-admin.yaml` |
| `crds/` | `platform/monitoring/crds/` |

## 脱敏说明

- GitLab 地址：`https://gitlab.example.com/...`（原为内网地址）；
- n8n webhook：`https://n8n.example.com/webhook/k8s-alerts`（原值已删除）；
- `wecom/sealedsecret.yaml`、`stack/sealedsecret-grafana-admin.yaml` 中的
  `encryptedData` 是占位符，必须用你自己集群的 SealedSecrets 控制器重新生成；
- 规则里的 `10.x.x.x` / `192.168.x.x` 是实验环境地址，不能从公网访问；
- 生产使用前请全部替换为你自己的环境。

## 应用方式

### 1. PrometheusRule

```bash
kubectl apply --dry-run=client -k rules/
kubectl apply -k rules/
```

规则必须带：

```yaml
metadata:
  labels:
    release: prometheus
    platform.gitops/managed: "true"
```

`rules/kustomization.yaml` 会自动给所有 PrometheusRule 打上白名单标签。

### 2. CRD

```bash
kubectl apply --server-side --force-conflicts -k crds/
```

这些 CRD 来自 kube-prometheus-stack 83.7.0，对应 prometheus-operator 0.90.1。
升级 chart 时同步更新本目录。

### 3. wecom-adapter

`adapter.py` 是从集群 ConfigMap 中取出的实际脚本；
`configmap.yaml` 是内嵌了脚本的 ConfigMap 清单。

修改脚本后重新生成 ConfigMap：

```bash
kubectl -n monitoring create configmap wecom-adapter-script \
  --from-file=adapter.py \
  --dry-run=client -o yaml > wecom/configmap.yaml
```

生成真实 SealedSecret：

```bash
kubectl -n monitoring create secret generic wecom-adapter \
  --from-literal=webhook-url='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...' \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
> wecom/sealedsecret.yaml

kubectl apply -k wecom/
```

### 4. 监控栈

`stack/values.yaml` 是 kube-prometheus-stack 的 values，不是可以直接
`kubectl apply` 的清单。使用 Helm 或 ArgoCD：

```bash
helm template prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 -n monitoring \
  -f stack/values.yaml > /tmp/stack.yaml
```

ArgoCD 的 Application 示例在 `applications/`，使用前把
`repoURL`、`path`、`valueFiles` 改成你自己的仓库路径。

## 目录速览

```text
manifests/
├── applications/       # 4 个 ArgoCD Application 示例
├── rules/              # 6 个 PrometheusRule + Kustomize 白名单 patch
├── wecom/              # Deployment/Service/ConfigMap/NetworkPolicy/adapter.py
├── stack/              # values.yaml + Grafana admin SealedSecret 示例
└── crds/               # 10 个 prometheus-operator CRD
```

## 注意

- `applications/` 里的 `path` 是原始平台仓库的路径；本教程仓库的目录结构不同，
  直接应用到 ArgoCD 前需要调整。
- `wecom/sealedsecret.yaml` 和 `stack/sealedsecret-grafana-admin.yaml` 是**示例**，
  不能直接解密使用。
- `crds/` 约 4.4MB，主要来自上游 chart，升级时建议用 `helm show crds` 重新生成。
