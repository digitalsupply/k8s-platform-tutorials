# 12-IaC · Proxmox + Terraform + cloud-init + Ansible

> 这是 [12 Proxmox VE](../README.md) 的实践子章节：用代码创建、配置、批量管理 VM，
> 并把新节点安全接入现有 K8s 集群。
>
> 目标不是“背 Terraform 语法”，而是把下面这条链路跑通、跑稳、可回滚：

```text
Terraform（PVE API）
  → 克隆黄金模板
  → cloud-init（首启：用户/网络/SSH/包）
  → Ansible（基线：hostname/hosts/时区/SSH/内核/containerd/kubelet）
  → kubeadm join（worker）
  → Cilium/ArgoCD 接管（现有集群）
```

## 1. 这套环境的事实

| 项 | 值 |
|---|---|
| PVE | `8.4.13`，宿主机 `teacher`，LVM-thin `local-lvm` |
| Terraform | `1.16.4`，provider `bpg/proxmox` `0.116.0` |
| 模板 | VMID `9010`，openEuler 24.03 LTS SP4，UEFI + virtio-scsi |
| Ansible | core `2.14.18` |
| K8s | `v1.35.9`，3 control-plane + 3 worker，Cilium `1.20.4` KPR |
| 节点网络 | `10.0.0.0/24`，API VIP `10.0.0.168:6443` |
| CPU | 现有 K8s 节点均为 `x86-64-v3` |

## 2. 怎么读

| 章节 | 内容 | 适合 |
|---|---|---|
| [01 Terraform](01-terraform-proxmox.md) | API token、provider、state、克隆、plan/apply/destroy | 第一次用 Terraform 管 PVE |
| [02 cloud-init](02-cloudinit-golden-template.md) | 黄金模板、NoCloud、snippet、sysprep、guest-agent | 建模板/克隆后没 IP/SSH 不通 |
| [03 Ansible 基线](03-ansible-baseline.md) | inventory、playbook、混合 OS、check/diff、灰度 | 批量改 6 台节点 |
| [04 K8s 节点](04-k8s-node-baseline.md) | 内核参数、containerd、kubelet、join、Cilium | 把新 VM 加入现有集群 |
| [05 批量管理](05-batch-ops.md) | 安全重启、扩容、discard、巡检、销毁 | 日常运维/容量治理 |
| [06 故障排查](06-troubleshooting.md) | 现象→根因→修复→验证 | 出问题时先查这里 |
| [11 IaC 演进](../../11-gitops-platform/10-iac-evolution.md) | Ansible 幂等/handlers/check/delegate/inventory/roles、Terraform state/plan/drift/import、GitOps | 想搞清 IaC 边界与演进 |
| [labs/](labs/README.md) | 5 个可动手实验（含清理） | 想按步骤练一遍 |

推荐顺序：**01 → 02 → 03 → 04 → 05 → 06**。只看不练容易漏掉“模板/网络/版本”这些环境坑。

## 3. 目录与代码

```text
12-proxmox-pve/
├── README.md                 # PVE 存储/容量/VM 磁盘原理
├── iac/                      # 本章：IaC 教程
│   ├── 01-terraform-proxmox.md
│   ├── 02-cloudinit-golden-template.md
│   ├── 03-ansible-baseline.md
│   ├── 04-k8s-node-baseline.md
│   ├── 05-batch-ops.md
│   ├── 06-troubleshooting.md
│   └── labs/README.md
├── notes/                    # 原始过程记录
├── scripts/                  # pve_storage_report.py / apply_discard.sh 等
└── assets/
    ├── xceuler/              # 实际 openEuler 批量部署代码
    │   ├── terraform/        # main.tf / variables.tf / tfvars 示例
    │   └── ansible/          # inventory / playbook
    └── iac/                  # 本章新增的 K8s 场景代码
        ├── cloud-init/       # user-data / meta-data 示例
        └── ansible/          # baseline.yml / k8s-node.yml / k8s-join.yml
```

## 4. 三条边界

### 4.1 Terraform 不配置 guest 内部

Terraform 只保证“VM 存在、规格对、cloud-init 盘挂对”。
用户、包、sysctl、containerd 是 cloud-init/Ansible 的事。

### 4.2 cloud-init 只管第一次

改 user-data 不会自动重跑。最终状态必须由 Ansible 收敛。

### 4.3 Ansible 不创建 VM

Ansible 假定“机器已经存在且能 SSH”。VM 生命周期归 Terraform/`qm`。

## 5. 安全与生产化

- API token、SSH 私钥、join token 不进 Git；
- `terraform.tfstate` 不进 Git，生产用加密远程 backend；
- `terraform destroy` 前必须 `terraform state list` + `plan -destroy`；
- Ansible 先 `--check --diff`，再 `--limit` 灰度，最后全量；
- 生产 K8s 不要加“来历不明”的节点；实验节点用独立 VMID/IP；
- 删 VM 前先 `kubectl drain` + `kubectl delete node`。

## 6. 从零跑一遍（最短路径）

```bash
# 1) Terraform 建一台测试 VM
cd docs/12-proxmox-pve/assets/xceuler/terraform
cp terraform.tfvars.k8s.example terraform.tfvars
terraform init && terraform plan -out=tfplan && terraform apply tfplan

# 2) 看 cloud-init
ssh hao@10.0.0.130 'cloud-init status --long; hostname'

# 3) Ansible 基线
cd ../../iac/ansible
ansible -i inventory-k8s.ini all -m ping
ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s_lab --check --diff

# 4) K8s 前置（不 join）
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s_lab --check --diff

# 5) 清理
cd ../../xceuler/terraform
terraform destroy -target='proxmox_virtual_environment_vm.node["k8s-lab-w01"]'
```

> `k8s_lab` 组需要你在 `inventory-k8s.ini` 里自行添加：
> `[k8s_lab]` + `k8s-lab-w01 ansible_host=10.0.0.130`。
> 真实 join 生产集群前，先读 [04 章](04-k8s-node-baseline.md) 的版本/网络/回滚要求。
