# IaC / GitOps 演进证据

对应教程：[`../../10-iac-evolution.md`](../../10-iac-evolution.md)。

| 文件 | 内容 |
|---|---|
| `gitops-state.txt` | ArgoCD 31 App、app-of-apps syncPolicy、Flux 缺失、git log |
| `argocd-audit.txt` | `argocd_gitops_audit.py` 输出：31 Synced/Healthy、仓库/路径、prune/selfHeal |

Ansible / Terraform 证据在 12 章：

- [`12-proxmox-pve/assets/iac/evidence/ansible-idempotency-handlers.txt`](../../../12-proxmox-pve/assets/iac/evidence/ansible-idempotency-handlers.txt)
- `ansible-check-diff.txt`
- `ansible-delegate-roles.txt`
- `ansible-dynamic-inventory.txt`
- `terraform-state-plan.txt`

## 关键结论

- Ansible 幂等：第一次 changed=1，第二次 changed=0；handler 只第一次触发；
- `--check --diff` 能看漂移，但 check 模式不真正装包，依赖服务可能假失败；
- delegate_to 控制机 teacher / 目标 worker03；
- 动态 inventory 3 cp + 3 worker；role preflight 复用成功；
- Terraform 3 台 VM 本地 state、无 backend/lock；`-refresh=false` 无变化，带 refresh 发现 3 台 `started=false→true`；
- ArgoCD 31 App 全 Synced/Healthy，Flux 未部署；
- app-of-apps `prune=false/selfHeal=true`，Git 变更可审计。
