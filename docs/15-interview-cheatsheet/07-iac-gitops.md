# 07 · IaC / Terraform / Ansible / GitOps 面试题

> 详细证据：[11 GitOps 10-iac-evolution](../11-gitops-platform/10-iac-evolution.md)。

## 1. Ansible 幂等性

**一句话**：幂等 = 执行 1 次和 N 次结果一样；用模块描述最终状态，不用裸 `shell`。

**本环境**：`idempotency-handlers.yml` 第一次 `changed=1`，第二次 `changed=0`。

## 2. Ansible handlers

**一句话**：handler 只在 notify 任务 changed 时触发，play 结束统一执行。

**本环境**：第一次触发 `debug`，第二次不触发；`baseline.yml`/`k8s-node.yml` 有 restart sshd/sysctl/containerd/kubelet handlers。

## 3. `--check --diff`

**一句话**：只预演 + 显示文件差异；check 模式不真正装包/起服务，依赖链可能假失败。

**本环境**：worker03 check 发现 `/etc/hosts` 漂移、chrony 待安装；`Enable time sync` 在 check 下假失败，已加 `when: not ansible_check_mode`。

## 4. delegate_to

**一句话**：把某一步委托给另一台主机，常用于“在控制机跑 kubectl/调 API”。

**本环境**：worker play 中 delegate_to localhost 输出 `control node: teacher` / `target node: worker03`。

## 5. inventory 动态化

**一句话**：从 K8s/PVE/云 API 实时生成 inventory，避免手工维护 IP。

**本环境**：`inventory_k8s.py` 读 `kubectl get nodes`，生成 3 cp + 3 worker。

## 6. roles 复用

**一句话**：role 打包 tasks/defaults/handlers/templates/files，playbook 只引用角色。

**本环境**：`roles/preflight` 被 `roles-demo.yml` 复用，输出 kernel/files/swap。

## 7. 什么时候不该用 Ansible

**一句话**：大规模、频繁重建、强一致场景，SSH 推送式配置管理太慢，转不可变镜像/Packer。

**本环境**：6 节点 Ansible 合适；1000 节点默认 forks=10 要分批，且无法保证从干净状态构建。

## 8. Terraform state

**一句话**：state 是真实资源映射；生产必须远端 state + 锁 + 加密。

**本环境**：`terraform state list` 3 台 VM；无 backend、本地 `terraform.tfstate`、有 backup 文件（反面教材）。

## 9. plan 审查

**一句话**：`plan -out=tfplan` + `show` 是变更审批核心，不要直接 apply。

**本环境**：plan 发现 3 台 VM `started=false -> true` 漂移，未 apply。

## 10. drift 检测

**一句话**：`terraform plan` 带 refresh 才对比真实资源；`-refresh=false` 只看 state。

**本环境**：`-refresh=false` 显示 No changes；带 refresh 显示 3 台 VM 漂移。

## 11. 模块化

**一句话**：模块封装一类资源的参数/输出，root module 组合。

**本环境**：Terraform 单模块；生产建议 `modules/proxmox-vm` + `envs/prod`。

## 12. import 存量资源

**一句话**：`terraform import` 把已有资源纳入 state，再补 HCL 对齐；不能先 apply 再 import。

**本环境**：文档给出 `terraform import '...node["k8s-lab-w01"]' teacher/130`；未实际 import 生产资源。

## 13. ArgoCD vs Flux

**一句话**：都是声明式 GitOps；ArgoCD 有强 UI/Application 模型，Flux 更控制器化。

**本环境**：ArgoCD 31 App 全 Synced/Healthy；Flux 未部署。

## 14. 单一事实源 + drift 自动纠正

**一句话**：Git 是唯一事实源，selfHeal 自动纠正漂移，prune 控制删除。

**本环境**：app-of-apps `prune=false/selfHeal=true`；31 App 全 Synced/Healthy。

## 15. PR 即变更审批

**一句话**：MR/PR 是审批入口，合并后自动同步；变更可审计是 GitOps 的免费副产品。

**本环境**：每次提交都有 commit/author/time/diff，ArgoCD 追踪 Git；回滚=revert commit。

## 16. 演进逻辑

| 阶段 | 解决 |
|---|---|
| 雪花服务器 | 每台不一样、重建靠记忆 |
| 配置管理 | 手工改易漂移，用幂等 playbook |
| 不可变基础设施 | 配置漂移/环境不一致，镜像构建一次 |
| GitOps | 变更不可审计/部署靠人，Git 单一事实源 |

**一句话**：后一代不取代前一代；Terraform 管生命周期、cloud-init 管首启、Ansible 管长生命周期 VM、GitOps 管 K8s 工作负载。
