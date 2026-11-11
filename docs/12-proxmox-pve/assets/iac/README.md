# IaC 代码资产

对应教程：

- [`../../iac/`](../../iac/README.md)：Terraform、cloud-init、Ansible 基础；
- [`../../../11-gitops-platform/10-iac-evolution.md`](../../../11-gitops-platform/10-iac-evolution.md)：Ansible/Terraform/GitOps 的能力边界与演进；
- 一句话版本：[`../../../15-interview-cheatsheet/07-iac-gitops.md`](../../../15-interview-cheatsheet/07-iac-gitops.md)。

```text
assets/iac/
├── cloud-init/
│   ├── k8s-node-user-data.yaml.example   # NoCloud user-data
│   └── k8s-node-meta-data.yaml.example   # instance-id / hostname
├── ansible/
│   ├── ansible.cfg
│   ├── inventory-k8s.ini                 # 静态 inventory：现有 6 台 K8s 节点
│   ├── inventory_k8s.py                  # 动态 inventory：kubectl get nodes
│   ├── group_vars/all.yml                # 版本/网段/镜像仓库
│   ├── baseline.yml                      # 主机基线
│   ├── k8s-node.yml                      # containerd/kubelet/内核
│   ├── k8s-join.yml                      # worker join + 验证
│   ├── delegate-example.yml              # delegate_to 演示
│   ├── roles-demo.yml                    # role 复用演示
│   ├── idempotency-handlers.yml          # 幂等 + handler 演示
│   ├── roles/preflight/                  # 可复用只读预检 role
│   │   ├── defaults/main.yml
│   │   └── tasks/main.yml
│   └── templates/
│       ├── k8s.conf.j2
│       ├── rp-filter.conf.j2
│       └── containerd-hosts.toml.j2
└── evidence/                             # 真机执行输出
    ├── ansible-idempotency-handlers.txt
    ├── ansible-check-diff.txt
    ├── ansible-delegate-roles.txt
    ├── ansible-dynamic-inventory.txt
    └── terraform-state-plan.txt
```

另外 `reference/m01/` 保存了从 m01 采集的 sysctl/containerd/kubeadm/kubelet 实际配置，
用于对照教程参数（不含 Secret/证书/token）。

Terraform 代码复用 `../xceuler/terraform/`：

- `main.tf` / `variables.tf` / `outputs.tf` / `versions.tf`；
- `terraform.tfvars.example`：openEuler web/lb 示例；
- `terraform.tfvars.k8s.example`：3 台 K8s 节点候选 VM（VMID 130–132）。

## 演示playbook

```bash
cd ansible

# 幂等：第一次 changed=1，第二次 changed=0
ansible-playbook -i inventory-k8s.ini idempotency-handlers.yml
ansible-playbook -i inventory-k8s.ini idempotency-handlers.yml

# --check --diff：只预演，不落盘
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff --limit worker03

# delegate_to：控制机执行 vs 目标节点执行
ansible-playbook -i inventory-k8s.ini delegate-example.yml --limit worker03

# role 复用
ansible-playbook -i inventory-k8s.ini roles-demo.yml --limit worker03

# 动态 inventory
ansible-inventory -i inventory_k8s.py --graph
```

真实输出见 `evidence/`。

## 使用前

1. 把 `terraform.tfvars.example` 或 `terraform.tfvars.k8s.example` 复制为 `terraform.tfvars`；
2. 填入真实的 PVE endpoint 和 API token；
3. 确认 VMID/IP 不与现有 119–124 冲突；
4. Ansible inventory 默认用 `root` + `~/.ssh/id_rsa`，按环境修改；
5. 先 `--check --diff`，再 `--limit` 灰度。

## 安全

- 不要提交 `terraform.tfstate`、`terraform.tfvars`、`*.pem`、`*.key`；
- `inventory-k8s.ini` 不写密码；
- `k8s-join.yml` 的 token 用 `-e` 临时传入，不写文件；
- `ssh_key_only` 默认 `false`，确认 key 登录成功后再打开；
- `evidence/` 只保存命令输出，不含 token/密码。
