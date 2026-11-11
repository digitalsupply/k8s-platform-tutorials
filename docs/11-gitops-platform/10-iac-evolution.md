# 10 · IaC 与 GitOps 演进：Ansible、Terraform、ArgoCD

> 这一章回答：**什么时候用 Ansible，什么时候用 Terraform，什么时候必须上 GitOps；
> 以及“雪花服务器 → 配置管理 → 不可变基础设施 → GitOps”每一代到底解决什么痛点。**
>
> 证据：[`assets/iac-evolution/`](assets/iac-evolution/README.md)。
> 一句话版本：[15 面试速查 07-iac-gitops](../15-interview-cheatsheet/07-iac-gitops.md)。

## 1. Ansible

### 1.1 幂等性

**一句话**：幂等 = 执行 1 次和执行 N 次结果一样；Ansible 模块描述“最终状态”，不是“执行命令”。

本环境实验：

```bash
ansible-playbook -i inventory-k8s.ini idempotency-handlers.yml
# 第一次：changed=1，handler 触发
ansible-playbook -i inventory-k8s.ini idempotency-handlers.yml
# 第二次：changed=0，handler 不触发
```

真实输出：

```text
first:  changed=1  handler: directory was created or mode changed
second: changed=0  no handler
```

> 反例：`command`/`shell` 默认不幂等，必须配 `creates`/`removes`/`changed_when`，
> 或者改用 `file`/`template`/`package`/`service` 等模块。

### 1.2 handlers

**一句话**：handler 只在 notify 的任务 `changed` 时触发，且默认在 play 结束统一执行一次。

本环境：

- `baseline.yml`：`Restart sshd`；
- `k8s-node.yml`：`Apply sysctl`、`Restart containerd`、`Restart kubelet`；
- `idempotency-handlers.yml`：第一次 changed 触发，第二次不触发。

```yaml
tasks:
  - file: path=/tmp/demo state=directory
    notify: Handler only on change
handlers:
  - name: Handler only on change
    debug: msg="changed"
```

### 1.3 `--check --diff`

**一句话**：`--check` 只预演，`--diff` 显示文件差异；但 check 模式不会真正安装包/启动服务，依赖链可能假失败。

本环境：

```bash
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff --limit worker03
```

真实发现：

- `/etc/hosts` 缺少 `127.0.1.1 worker03` 和 Ansible 管理的 hosts block；
- `chrony` 将被安装（`systemd-timesyncd` 将被移除）；
- check 模式下 `chrony` 服务尚不存在，最初的 `Enable time sync` 会假失败；
  已在 `baseline.yml` 加 `when: not ansible_check_mode` 规避。

> 教训：`--check` 不是“完整 dry-run”。涉及包安装后启动服务、创建后 chown 的链路，
> 要么加条件，要么接受 check 的局限。

### 1.4 delegate_to

**一句话**：`delegate_to` 把某一步委托给另一台主机执行，常用于“在控制机跑 kubectl/调 API”，
而不是在目标节点上跑。

本环境实验：

```yaml
- hosts: k8s_worker
  tasks:
    - command: hostname
      delegate_to: localhost
      run_once: true
```

输出：

```text
control node: teacher
target node:  worker03
```

典型场景：

- 在控制机执行 `kubectl`；
- 调 PVE/Harbor API；
- 更新负载均衡/ DNS；
- 从控制机生成证书再分发。

### 1.5 inventory 动态化

**一句话**：动态 inventory 从 K8s/PVE/云 API 实时生成主机清单，避免手工维护 IP。

本环境新增：

```text
assets/iac/ansible/inventory_k8s.py
```

它执行 `kubectl get nodes -o json`，按 control-plane/worker 分组，输出 Ansible JSON inventory。

```bash
./inventory_k8s.py --list
ansible-inventory -i inventory_k8s.py --graph
```

真实结果：6 个节点（3 cp + 3 worker），worker 带 `zone=test-a/test-b`。

> 动态 inventory 的坑：API 限流、缓存、离线时不可用；生产通常加缓存/重试。

### 1.6 roles 复用

**一句话**：role 把 tasks/defaults/handlers/templates/files/vars 打包，playbook 只引用角色名。

本环境新增：

```text
assets/iac/ansible/roles/preflight/
├── defaults/main.yml
└── tasks/main.yml
assets/iac/ansible/roles-demo.yml
```

执行：

```bash
ansible-playbook -i inventory-k8s.ini roles-demo.yml --limit worker03
```

输出：

```text
kernel: 5.15.0-202-generic
files: ['/etc/kubernetes/kubelet.conf', '/etc/containerd/config.toml']
swap: []
```

> role 适合“跨环境复用”；一次性脚本不必强行 role 化。

### 1.7 什么时候不该用 Ansible

**一句话**：规模很大、节点频繁重建、需要强一致时，SSH 推送式配置管理会变成瓶颈；转不可变镜像/Packer。

原因：

- 默认 `forks=10`（本环境 `ansible.cfg`），1000 台要分批；
- SSH 连接、Python 启动、包管理都有开销；
- 每台机器的历史状态不同，幂等只能保证“最终状态”，不能保证“从干净状态构建”；
- 配置漂移/手工改动仍然可能存在。

更适合：

- 小到中等规模、长生命周期 VM；
- 网络设备/宿主机基线；
- 一次性迁移/编排；
- 与 Terraform/cloud-init 配合做“首启后配置”。

不适合：

- 大规模弹性扩容（用镜像/cloud-init/K8s）；
- 需要严格不可变的场景（Packer/容器镜像）；
- 高频变更（GitOps 更合适）。

## 2. Terraform

### 2.1 state 管理

**一句话**：state 是 Terraform 对真实资源的映射；生产必须远端 state + 锁，不能放本地。

本环境：

```bash
terraform state list
# proxmox_virtual_environment_vm.node["lb01"]
# proxmox_virtual_environment_vm.node["sweb01"]
# proxmox_virtual_environment_vm.node["web01"]

grep -R backend *.tf
# 无 backend block -> 本地 state
ls -lh terraform.tfstate*
```

这是**反面教材**：本地 state、无锁、无版本历史；多人同时 apply 会互相覆盖。

生产示例：

```hcl
terraform {
  backend "s3" {
    bucket         = "tf-state-prod"
    key            = "proxmox/k8s/terraform.tfstate"
    region         = "cn-hangzhou"
    dynamodb_table = "tf-lock"
    encrypt        = true
  }
}
```

或 GitLab HTTP backend / Terraform Cloud；核心是**远端 + 锁 + 加密 + 版本**。

### 2.2 plan 审查

**一句话**：`terraform plan -out=tfplan` 是变更审批的核心；不要直接 `apply`。

```bash
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

本环境 `plan` 发现真实漂移：

```text
# proxmox_virtual_environment_vm.node["lb01"] will be updated in-place
~ started = false -> true
# 3 台 VM 都会被启动
Plan: 0 to add, 3 to change, 0 to destroy.
```

说明 state 里 `started=true`，实际 VM 125–127 是 stopped；Terraform 想把它们启动。

> 这条 plan **没有 apply**，只作为 drift 证据。

### 2.3 drift 检测

**一句话**：`terraform plan` 带 refresh 才能对比真实资源；`-refresh=false` 只看 state，检测不到漂移。

本环境：

```bash
terraform plan -refresh=false
# No changes（只对比 state）

terraform plan
# 3 台 VM started false -> true（真实漂移）
```

生产应定时跑 `terraform plan`（CI schedule），有 diff 就告警，而不是等人手动发现。

### 2.4 模块化

**一句话**：模块把“创建一类资源”的参数/输出封装，root module 只组合模块。

本环境 Terraform 是单文件/单模块（`main.tf`/`variables.tf`），没有 child module。
生产建议：

```text
modules/
├── proxmox-vm/        # VM 规格、clone、cloud-init
└── k8s-node/          # K8s 节点变量/标签
envs/
└── prod/
    ├── main.tf
    └── terraform.tfvars
```

### 2.5 import 存量资源

**一句话**：`terraform import` 把已存在资源纳入 state，再写 HCL 对齐；不能反过来“先 apply 再 import”。

```bash
terraform import 'proxmox_virtual_environment_vm.node["k8s-lab-w01"]' teacher/130
```

坑：

- import 只写 state，不生成 HCL；
- 需要手工补配置，`plan` 对齐；
- 资源地址/key 必须和 `for_each` 一致；
- 先备份 state。

## 3. GitOps

### 3.1 ArgoCD vs Flux

| 项 | ArgoCD | Flux |
|---|---|---|
| 模型 | Application/AppProject + UI | GitRepository/Kustomization/HelmRelease |
| 多集群 | 原生 | 原生 |
| UI | 强 | 弱 |
| 本环境 | **已用**，31 App | **未部署** |

### 3.2 声明式 + 单一事实源

本环境：

```text
app-of-apps -> clusters/prod/applications/
31 个 Application，全部 Synced/Healthy
syncPolicy: automated prune=false selfHeal=true
```

Git 是唯一事实源；集群状态应等于 Git 渲染结果。

### 3.3 drift 自动纠正

`selfHeal: true` 会在集群漂移时自动改回 Git 状态。
本环境 31 个 App 全部 `Synced/Healthy`，`app-of-apps` 和多数 App 都开 `selfHeal=true`。

> 风险：手工 hotfix 会被覆盖；紧急变更也要走 Git，或先暂停 auto-sync。

### 3.4 PR 即变更审批

GitLab MR / GitHub PR 是审批入口；合并后 ArgoCD 自动同步。

“**GitOps 把变更可审计性变成免费副产品**”：

- 每次变更都有 commit/PR/author/time/diff；
- ArgoCD 的 sync 记录对应 Git commit；
- 回滚 = revert commit；
- 不需要额外“变更管理系统”就能回答“谁在什么时候改了什么”。

本仓库自身就是例子：

```text
$ git log --oneline -8
cd55dea docs(virt): verify cloud images ...
50bfd15 docs(virt): add KVM/QEMU ...
1334b35 docs(infra): correct GitLab/Harbor topology ...
...
```

### 3.5 GitOps 不适用什么

- 数据库 schema migration（需要应用/Job 编排）；
- 一次性 bootstrap（ArgoCD 自己怎么装）；
- 密钥明文（要 SealedSecret/ESO/SOPS）；
- 强顺序/外部副作用（用 Job/Operator/CI）。

## 4. 演进逻辑：每一代解决什么

```text
雪花服务器
  → 配置管理（Ansible/Puppet/Chef）
  → 不可变基础设施（Packer/云镜像/容器）
  → GitOps（ArgoCD/Flux）
```

| 阶段 | 痛点 | 解决 | 本环境证据 |
|---|---|---|---|
| 雪花服务器 | 每台不一样、重建靠记忆 | 文档/脚本 | VM 110–115 归档、手工 `qm set` |
| 配置管理 | 手工改容易漂移 | 幂等 playbook | `baseline.yml`、`k8s-node.yml` |
| 不可变基础设施 | 配置漂移、环境不一致 | 镜像构建一次、运行期不改 | openEuler qcow2、Ubuntu cloud image、Packer 示例 |
| GitOps | 变更不可审计、部署靠人 | Git 单一事实源 + 自动同步 | ArgoCD 31 App、app-of-apps |

> 不是“后一代完全取代前一代”：
> Terraform 管基础设施生命周期，cloud-init 管首启，Ansible 管长生命周期 VM 的基线，
> GitOps 管 K8s 内工作负载；四者按边界组合。

## 5. 一页命令

```bash
# Ansible
ansible-inventory -i inventory_k8s.py --graph
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff --limit worker03
ansible-playbook -i inventory-k8s.ini roles-demo.yml --limit worker03
ansible-playbook -i inventory-k8s.ini idempotency-handlers.yml

# Terraform
terraform state list
terraform plan -out=tfplan
terraform show tfplan
terraform plan              # 带 refresh 才能检测 drift
terraform import 'proxmox_virtual_environment_vm.node["name"]' teacher/130

# GitOps
kubectl -n argocd get applications
kubectl -n argocd get application app-of-apps -o jsonpath='{.spec.syncPolicy}'
python3 docs/11-gitops-platform/scripts/argocd_gitops_audit.py
```
