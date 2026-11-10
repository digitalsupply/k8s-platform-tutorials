# 13 · SSO / OIDC 原始文档索引

这些文档来自 `platform-gitops` 仓库，是当天实施时写的设计与执行记录。
为了保留现场，正文基本未改；下面标注两处需要在阅读时校正的地方。

| 文档 | 内容 |
|---|---|
| [01-sso-overview.md](01-sso-overview.md) | 总体方案、分阶段、风险与回滚 |
| [02-sso-ops-tutorial.md](02-sso-ops-tutorial.md) | 基础概念 + 运维手册 |
| [03-phase2-argocd-harbor-ceph.md](03-phase2-argocd-harbor-ceph.md) | ArgoCD/Harbor 接入、Ceph 阻塞、oauth2-proxy 反向代理 |
| [04-keycloak-basicauth-forwardauth.md](04-keycloak-basicauth-forwardauth.md) | Keycloak 与 basicAuth/ForwardAuth 的区别 |
| [05-grafana-sso.md](05-grafana-sso.md) | Grafana SSO 三种方案 |
| [06-argocd-helm-bootstrap.md](06-argocd-helm-bootstrap.md) | ArgoCD bootstrap 与 OIDC/RBAC |
| [07-sealed-secrets.md](07-sealed-secrets.md) | Sealed Secrets 迁移记录 |

## 阅读校正

1. **Ceph 版本**：原始文档写作 “Ceph Dashboard 17.2.8（Quincy）”。
   2026-11-10 实测集群为 **18.2.8 Reef**（`ceph versions` 全部 18.2.8）。
   结论不变：Quincy/Reef 的 Dashboard SSO 都只支持 **SAML 2.0**，
   OAuth2/OIDC 要到 Tentacle+ 的 mgmt-gateway 方案。
2. **Sealed Secrets 私钥备份路径**：`07-sealed-secrets.md` 里记录的
   `/root/k8s-postmortem/backup/sealed-secrets-key.yaml` 在当前环境已不存在。
   请重新从集群 Secret 导出并离线保存，详见分类 README 的「坑 16」。
