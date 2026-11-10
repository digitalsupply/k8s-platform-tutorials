# openEuler 批量部署资产（Terraform + Ansible）

对应文档：[../../notes/openeuler-batch-deploy-2026-11.md](../../notes/openeuler-batch-deploy-2026-11.md)。

| 路径 | 说明 |
|---|---|
| `terraform/versions.tf` | Terraform/provider 版本约束 |
| `terraform/main.tf` | 克隆黄金模板、CPU/内存/磁盘/网络、cloud-init |
| `terraform/variables.tf` | 变量定义 |
| `terraform/outputs.tf` | VM IP/VMID 输出 |
| `terraform/terraform.tfvars.example` | 变量示例（Proxmox API token 已脱敏） |
| `terraform/.terraform.lock.hcl` | provider 版本锁定 |
| `ansible/inventory.ini` | 3 台 openEuler 主机清单 |
| `ansible/playbook.yml` | 统一配置 playbook |
| `ansible/ansible.cfg` | Ansible 配置 |

未包含：

- `terraform.tfstate` / `.tf_pw.env`：含真实状态和密码，不入库；
- 云镜像 qcow2/xz：体积过大，按文档中的下载地址自行获取并校验 sha256。

使用前：

1. 复制 `terraform.tfvars.example` 为 `terraform.tfvars`，填入真实 endpoint/token；
2. 确认模板 VMID、存储、网桥与你的环境一致；
3. `terraform plan` 先看变更，再 `apply`；
4. Ansible inventory 的用户/密钥按实际修改。
