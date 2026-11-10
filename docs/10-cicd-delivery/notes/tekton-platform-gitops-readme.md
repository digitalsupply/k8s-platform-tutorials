# Tekton Platform GitOps

本仓库用于管理 Tekton Operator、TektonConfig 和 ArgoCD Application。

## 目录

```text
operator/release.yaml              # Tekton Operator v0.81.3 官方 release（vendored）
config/tektonconfig.yaml           # TektonConfig：Pipelines/Triggers/Dashboard + 生产保留策略
argocd/tekton-operator-app.yaml    # ArgoCD Application：安装 Operator
argocd/tekton-config-app.yaml      # ArgoCD Application：安装/管理 TektonConfig
```

## 当前版本

| 组件 | 版本 |
|---|---|
| Tekton Operator | v0.81.3 |
| Tekton Pipelines | v1.15.5 |
| Tekton Triggers | v0.37.2 |
| Tekton Dashboard | v0.71.0 |
| Tekton Pruner | v0.4.4 |

## 安装顺序

1. 创建 ArgoCD repo secret（指向本仓库）。
2. apply `argocd/tekton-operator-app.yaml`，等待 `tekton-operator` Deployment Ready。
3. apply `argocd/tekton-config-app.yaml`，等待 Tekton 组件升级/就绪。
4. 验证 CR、版本、Pruner。
5. 停用旧的 `cicd` 清理 CronJob（`cicd-cleanup`）。

## 保留策略

`TektonConfig.spec.tektonpruner`（事件驱动 Pruner）：

- `ttlSecondsAfterFinished: 2592000`（30 天）
- `successfulHistoryLimit: 200`
- `failedHistoryLimit: 100`

不再使用“只保留 1 天”的激进策略。旧的 `cicd-cleanup` CronJob 已删除。

## 配置说明

- `pruner.disabled: true` + `tektonpruner.disabled: false`：启用事件驱动 Pruner。
- `result.disabled: true`、`chain.disabled: true`：当前没有 Results/Chains 存储，先关闭。
- `dashboard.readonly: true`：Dashboard 只读。
- `platforms.kubernetes.pipelinesAsCode.enable: false`：Kubernetes 环境不需要 Pipelines-as-Code，避免额外组件阻塞 Ready。
- `argocd/tekton-operator-app.yaml` 对 CRD 的 `spec.conversion` / `spec.preserveUnknownFields` 做了 `ignoreDifferences`，避免 API Server 默认值导致永久 OutOfSync。

## 注意

- `TektonConfig.spec.pruner` 与 `spec.tektonpruner` 不能同时启用。
- 从 standalone 迁移前必须备份 CRD、Tekton CR、命名空间资源和 etcd。
- ArgoCD Application 使用 `prune: false`，避免误删 CRD/资源。
- 升级 Operator 时，GCS `latest` 可能滞后；以 GitHub Releases 的 `v0.81.x` 为准，并使用 GitHub Release asset（`release.yaml`）。
