# Open WebUI CI/CD + GitOps 资产

对应文档：[../../notes/openwebui-cicd-gitops.md](../../notes/openwebui-cicd-gitops.md)、
[../../notes/openwebui-ops-runbook.md](../../notes/openwebui-ops-runbook.md)。

```text
openwebui/
├── cicd/           Tekton Task/Pipeline/EventListener + Harbor CA
├── runner/         GitLab Runner（k8s executor）
└── gitops/
    ├── base/       Namespace/Secret/Deployment/Service/Ingress/frpc（images 不写在这里）
    ├── overlays/prod/  Kustomize overlay，CI 只改这里的 newTag
    └── argocd/     Application 与仓库凭据
```

脱敏说明：

- GitLab PAT、Runner token、Harbor admin/robot 密码、FRP token 已替换为 `<redacted-...>`；
- `base/00-namespace-and-secrets.yaml` 是**迁移前**的明文 Secret 示例，保留用于对照；
  生产应改为 SealedSecret / ExternalSecret；
- `harbor-ca.crt` 是内网自签 CA 公钥，可按需替换。

使用前：

1. 替换 GitLab/Harbor 地址、项目路径、镜像仓库；
2. 重新创建 Secret，不要复用示例中的占位值；
3. `kubectl kustomize overlays/prod` 确认 image tag 只在 overlay 生效。
