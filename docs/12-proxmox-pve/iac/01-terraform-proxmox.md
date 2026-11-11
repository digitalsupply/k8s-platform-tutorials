# 01 · Terraform 管理 Proxmox VE：从 API Token 到批量克隆

> 本章目标：用 Terraform 把“手工 `qm clone` + `qm set`”变成可 review、可重复、可销毁的代码。
> 代码在 [`../assets/xceuler/terraform/`](../assets/xceuler/terraform/)，本章解释每一段为什么这么写。
>
> state 后端、plan 审查、drift 检测、模块化、import 存量资源的实战与证据，
> 见 [`../../11-gitops-platform/10-iac-evolution.md`](../../11-gitops-platform/10-iac-evolution.md) 第 2 节。

## 1. 当时的情况

原来的建机方式是 root 脚本：

```bash
qm clone 100 125 --name web01 --full
qm set 125 --cores 2 --memory 2048
qm set 125 --net0 virtio,bridge=vmbr1
...
```

能跑，但有四个问题：

1. **不可 review**：改一个 IP/CPU 只能看 shell 历史；
2. **不可重复**：VMID 冲突、磁盘残留、cloud-init 盘挂错都要人工判断；
3. **不可回收**：删 VM 时忘了删磁盘/快照，thin pool 越用越满；
4. **没有状态**：不知道“哪些 VM 是这套代码创建的”，无法做漂移检测。

这台环境的实际版本：

| 组件 | 版本 |
|---|---|
| Proxmox VE | `8.4.13` |
| Terraform | `1.16.4` |
| Provider | `bpg/proxmox` `0.116.0` |
| 黄金模板 | VMID `9010`（openEuler 24.03 LTS SP4） |
| 存储 | `local-lvm`（LVM-thin） |
| 网络 | `vmbr1` 10.0.0.0/24 |

## 2. 主要概念

### 2.1 Terraform 的三层对象

```text
HCL 配置（main.tf / variables.tf）
  → terraform plan（对比 state 与真实 API）
  → Proxmox API（/api2/json）
  → VM / 磁盘 / cloud-init / 网络
```

- **Provider**：把 HCL 翻译成 Proxmox API 调用；
- **State**：记录“代码创建了哪些真实资源”，默认 `terraform.tfstate`；
- **Plan**：只读 diff，不落盘；**Apply** 才真正改集群。

### 2.2 为什么用 API Token 而不是 root 密码

- token 可以单独授权、单独吊销；
- 不需要把 root 密码写进环境变量/CI；
- 权限可以收敛到“只管理 VM/存储”，而不是整个 PVE。

本集群的 token 形式：

```text
terraform@pve!terraform=<secret>
```

用户名是 `terraform@pve`，token 名是 `terraform`。

### 2.3 `for_each` 比 `count` 更适合 VM

```hcl
resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.vms
  name     = each.key
  vm_id    = each.value.vmid
}
```

好处：

- 增删一台 VM 不会导致后面所有 VM 重建（`count` 会）；
- `each.key` 直接是主机名，`terraform output` 可读性好；
- 配合 `vms` map，IP/VMID 一眼能对账。

## 3. 操作步骤

### 3.1 创建 API Token

在 PVE 宿主机执行（按最小权限调整）：

```bash
pveum user add terraform@pve

pveum role add TerraformProv -privs "\
Datastore.Allocate Datastore.AllocateSpace Datastore.Audit \
Pool.Allocate Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU \
VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory \
VM.Config.Network VM.Config.Options VM.Migrate VM.PowerMgmt VM.Snapshot"

pveum acl modify / --users terraform@pve --roles TerraformProv
pveum user token add terraform@pve terraform --privsep 0
```

> token secret 只显示一次；丢失只能重新生成。不要写进 Git。

### 3.2 配置 Terraform

```bash
cd docs/12-proxmox-pve/assets/xceuler/terraform
cp terraform.tfvars.example terraform.tfvars
# 填入 endpoint / token / node / template_vmid
```

`versions.tf` 的关键点：

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.60.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true
  ssh { agent = false }
}
```

- `insecure = true`：PVE 默认自签证书；
- `ssh { agent = false }`：Terraform 就跑在 PVE 上，不需要额外 SSH 配置；
- 生产建议固定 provider 版本 + 提交 `.terraform.lock.hcl`。

### 3.3 初始化与计划

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
```

如果 provider 下载被墙，本机用了文件系统镜像：

```hcl
# /root/.terraformrc
provider_installation {
  filesystem_mirror {
    path    = "/root/.terraform.d/plugins"
    include = ["registry.terraform.io/bpg/proxmox"]
  }
  direct {
    exclude = ["registry.terraform.io/bpg/proxmox"]
  }
}
```

把 provider zip 解压到：

```text
/root/.terraform.d/plugins/registry.terraform.io/bpg/proxmox/0.116.0/linux_amd64/
```

再 `terraform init`，日志会显示 `Installed bpg/proxmox v0.116.0 (unauthenticated)`。

### 3.4 创建 VM

```bash
terraform apply tfplan
terraform output
```

`main.tf` 的关键配置：

| 配置 | 原因 |
|---|---|
| `clone { full = true }` | 生成独立磁盘，避免模板/其他 VM 共享 base 卷 |
| `bios = "ovmf"` | 与 openEuler 模板的 UEFI 一致 |
| `scsi_hardware = "virtio-scsi-single"` | 与模板控制器一致 |
| `initialization.interface = "scsi1"` | openEuler guest 不识别 IDE cloud-init 盘 |
| `agent { enabled = true }` | Terraform 等待 guest agent，才能确认启动完成 |
| `cpu.type = var.vm_cpu_type` | K8s 节点需要 `x86-64-v3`；openEuler 普通 VM 可用 v2 |

### 3.5 用同一套代码创建 K8s 节点候选 VM

```bash
cp terraform.tfvars.k8s.example terraform.tfvars
terraform plan
```

示例会创建：

```text
k8s-lab-w01  10.0.0.130  VMID 130
k8s-lab-w02  10.0.0.131  VMID 131
k8s-lab-w03  10.0.0.132  VMID 132
```

> 不要直接用 119–124 的 VMID/IP；这些是现有集群节点。
> 真正加入集群前，先看第 04 章的版本/内核/containerd 对齐要求。

### 3.6 验证

```bash
qm list | grep -E '130|131|132'
qm config 130 | grep -E 'cpu:|memory:|net0:|ipconfig0:|scsi1:'
terraform output -json
ssh hao@10.0.0.130 'hostname; cloud-init status --long'
```

### 3.7 销毁

```bash
# 只销毁一个（从 vms map 里移除后 apply，或 -target）
terraform destroy -target='proxmox_virtual_environment_vm.node["k8s-lab-w01"]'

# 全部销毁（确认 state 只包含测试 VM）
terraform destroy
```

销毁会删 VM 磁盘；`local-lvm` 的空间是否真正释放，取决于 `discard`/`fstrim`，见第 05 章。

## 4. 踩坑点

### 坑 1：token 字符串格式写错

`api_token` 必须是：

```text
user@realm!tokenid=secret
```

只写 secret、或把 `!` 写成 `:`，都会 401。

### 坑 2：provider 下载超时

`terraform init` 卡在 `registry.terraform.io`。解决：

- 使用文件系统镜像（本机方案）；
- 或给 Terraform 配代理；
- 不要把 `.terraform/` 目录提交到 Git。

### 坑 3：VMID 冲突

`qm clone` 会报 `VM 130 already exists`。Terraform 也可能因为 state 里没有该 VM 而尝试重建。
先 `qm list` / `qm config` 确认，再决定 import 还是换 VMID：

```bash
terraform import 'proxmox_virtual_environment_vm.node["k8s-lab-w01"]' teacher/130
```

### 坑 4：`full = false` 导致磁盘共享

链接克隆的磁盘依赖模板 base 卷；模板一删，所有克隆都坏。
建独立 VM 用 `full = true`。

### 坑 5：CPU 型号不是热插拔

改 `cpu.type` 后 `terraform apply` 可能只改配置，guest 内 `lscpu` 仍是旧型号。
必须 stop/start：

```bash
qm shutdown 130 --timeout 120
qm start 130
```

### 坑 6：cloud-init 盘挂 IDE 不生效

openEuler 镜像里没有 ATAPI，`ide2` 的 cloud-init 盘检测不到。
必须挂 `scsi1`（或模板实际使用的 virtio-scsi 控制器）。

### 坑 7：state 里有敏感信息

`terraform.tfstate` 包含 VM 配置、cloud-init 用户数据，可能含 SSH key/密码。
不要提交；生产用加密的远程 backend（S3 + 锁）。

### 坑 8：没有 remote backend，多人不能协作

本地 state 只能一个人操作；多人同时 apply 会互相覆盖。
至少做到：

- state 文件权限 600；
- 操作前备份；
- 生产用对象存储 backend + DynamoDB/锁。

## 5. 一页命令

```bash
cd docs/12-proxmox-pve/assets/xceuler/terraform
terraform init
terraform fmt -check && terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output
qm list | grep -E '130|131|132'

# 清理
terraform destroy
```
