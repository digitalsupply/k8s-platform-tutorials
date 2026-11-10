# openEuler 虚拟机批量部署全过程（Proxmox + cloud-init + Terraform + Ansible）

> 目标：在 Proxmox VE 宿主机 `teacher` 上，批量创建 3 台 openEuler 虚拟机。
>
> | 主机名 | VMID | IP | 配置 | 用户 |
> |---|---|---|---|---|
> | web01 | 125 | 10.0.0.7 | 2 vCPU / 2 GiB | hao |
> | sweb01 | 126 | 10.0.0.8 | 2 vCPU / 2 GiB | hao |
> | lb01 | 127 | 10.0.0.9 | 2 vCPU / 2 GiB | hao |
>
> 要求：使用 cloud-init + Ansible + Terraform；用户 `hao`；SSH 仅密钥登录（关闭密码认证）。

---

## 一、环境与前期调研

| 项目 | 情况 |
|---|---|
| Proxmox 节点名 | `teacher` |
| 网络 | `vmbr1` = 10.0.0.1/24（目标网段，NAT 到 `vmbr0`）；`vmbr0` = 192.168.67.156/24；`vmbr2` = 172.16.1.1/16 |
| 存储 | `local`（dir，含 snippets）、`local-lvm`（lvmthin） |
| 宿主机内存 | 紧张：约 57 GiB / 62 GiB 已用，可用约 5 GiB |
| 已运行 VM | 116–124（内存之和已超过物理内存，属于超分） |
| Terraform | v1.16.4（`/usr/bin/terraform`） |
| Ansible | 初始未安装，后经 `apt install ansible` 安装（7.7.0） |
| 本地 openEuler 介质 | 仅 DVD 安装 ISO：`/var/lib/vz/template/iso/openEuler-24.03-LTS-SP4-x86_64-dvd.iso` |

### 关键决策

1. 本地只有 DVD 安装盘，**不能直接配合 cloud-init**。经确认（用户选择）改为**下载 openEuler 24.03-LTS-SP4 的云镜像 qcow2**。
2. 该主机是 Proxmox VE，无 libvirt，因此采用 **Proxmox 原生方式**：
   - 用 Terraform（`bpg/proxmox` provider）基于“黄金模板”克隆出 VM，并借助 Proxmox 的 cloud-init 完成首启初始化；
   - 用 Ansible 做克隆后的统一配置。

---

## 二、准备黄金镜像

### 1. 下载并校验云镜像

- 目标文件：`/root/xceuler/images/openEuler-24.03-LTS-SP4-x86_64.qcow2`
- `.xz` 的 sha256：`02bf2efa55b1c921ad3c8c5c563bd12cd601892d9906a1167b67254f884282b2`（已校验通过）。

### 2. 离线注入 cloud-init 与 hostname

云镜像默认**没有 cloud-init**，从本地 DVD 离线安装：

- 安装 `cloud-init-23.4.1`、`hostname-3.23`；
- 新增 `/etc/cloud/cloud.cfg.d/99-proxmox.cfg`：

  ```yaml
  datasource_list: [ NoCloud, ConfigDrive, None ]
  datasource:
    NoCloud:
      dsmode: local
  system_info:
    default_user:
      name: hao
      lock_passwd: true
      groups: [wheel, adm, systemd-journal]
      sudo: "ALL=(ALL) NOPASSWD:ALL"
      shell: /bin/bash
  ```

- 新增 `/etc/cloud/ds-identify.cfg`：`policy: search,found=all,maybe=all,notfound=enabled`
- 新增 `/etc/cloud/templates/hosts.openeuler.tmpl`
- 在 grub 中强制 `net.ifnames=0 biosdevname=0`（BIOS 与 UEFI 两套 cfg 均重新生成）
- 执行 **sysprep**：清空 `machine-id`、删除 SSH host key、清理 cloud-init 状态/NetworkManager 连接/日志。

### 3. 踩过的坑（重要）

1. **不要**在 `cloud.cfg.d` 中写 `network: {config: enabled}`。cloud-init 23.4 会把它当成实例网络配置（`{"config":"enabled"}`），触发
   `RuntimeError: Unknown network config version: None`。datasource 的 network-config 会自动生效，无需该配置。
2. 镜像缺少 `hostname` 命令，导致 `update_hostname` 报错 —— 通过安装 `hostname-3.23` 解决。
3. **IDE 光驱不可用**：guest 内核只认 `ata1/ata2: PATA`，没有 ATAPI，`ide2` 上的 cloud-init 盘检测不到。因此 **cloud-init 盘必须挂到 virtio-scsi（`scsi1`）**。

---

## 三、创建黄金模板（VMID 9010）

- 名称：`tmpl-openeuler2403`
- 关键配置（`/etc/pve/qemu-server/9010.conf`）：

  ```
  bios: ovmf
  scsihw: virtio-scsi-single
  scsi0: local-lvm:base-9010-disk-1,iothread=1,size=40G
  scsi1: local-lvm:vm-9010-cloudinit,media=cdrom      # cloud-init 盘
  efidisk0: local-lvm:base-9010-disk-0,...
  ciuser: hao
  nameserver: 223.5.5.5
  agent: enabled=1
  ```

- 端到端测试通过后，标记为模板：`template: 1`。
- 已验证：cloud-init `status: done`、主机名正确、`eth0` 静态 IP `10.0.0.7/24`、`hao` 密钥登录、`sudo NOPASSWD` 正常。
- 清空模板上的 `ipconfig0`，交由 Terraform 按 VM 单独设置。
- **移除 `searchdomain: local`**，避免 cloud-init 把主机名设置成 FQDN（如 `web01.local`）。

### 补充：向模板注入 qemu-guest-agent

模板启用了 `agent: enabled=1`，但镜像里没有 `qemu-guest-agent`，会导致 Terraform `started=true` 等待 agent 而超时。因此离线补装：

```sh
# 模板基盘原为只读，先临时改为可写
lvchange -prw /dev/pve/base-9010-disk-1

# 宿主机上用 HTTP 暴露 DVD，供 libguestfs 应用内的 guest 使用
nohup python3 -m http.server 8899 --directory /mnt/dvd &

# 用 virt-customize 进入 guest 安装（libguestfs 应用网关是 169.254.2.2，不是 10.0.2.2！）
virt-customize -a /dev/pve/base-9010-disk-1 \
  --run-command 'printf "[dvd]\nname=dvd\nbaseurl=http://169.254.2.2:8899\nenabled=1\ngpgcheck=0\n" > /etc/yum.repos.d/dvd.repo' \
  --run-command 'dnf -y --disablerepo="*" --enablerepo=dvd install qemu-guest-agent' \
  --run-command 'ln -sf /usr/lib/systemd/system/qemu-guest-agent.service /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service'

# 再次 sysprep（virt-customize 会随机化 machine-id，需清空）
# 清空 machine-id、host key、cloud-init 状态、日志
# 完成后恢复只读
lvchange -pr /dev/pve/base-9010-disk-1
```

> 注意：`virt-customize --attach` 挂 ISO 会触发 `inspect_os: sgdisk: Invalid partition data!`，所以改用 HTTP 提供仓库。

---

## 四、Terraform 批量创建（`/root/xceuler/terraform/`）

### 1. 解决 provider 下载被墙

GitHub release 下载地址 `objects.githubusercontent.com` 超时，但 `gh-proxy.com` 可用。做法：

```sh
# 通过代理下载 provider zip，解压后放入文件系统镜像目录
curl -L -o proxmox.zip \
  "https://gh-proxy.com/https://github.com/bpg/terraform-provider-proxmox/releases/download/v0.116.0/terraform-provider-proxmox_0.116.0_linux_amd64.zip"

mkdir -p /root/.terraform.d/plugins/registry.terraform.io/bpg/proxmox/0.116.0/linux_amd64
# 放入可执行文件 terraform-provider-proxmox_v0.116.0

# /root/.terraformrc 使用文件系统镜像
cat > /root/.terraformrc <<'EOF'
provider_installation {
  filesystem_mirror {
    path    = "/root/.terraform.d/plugins"
    include = ["registry.terraform.io/bpg/proxmox"]
  }
  direct { exclude = ["registry.terraform.io/bpg/proxmox"] }
}
EOF
```

### 2. 文件清单

- `versions.tf`：provider 配置（endpoint / API token / insecure）
- `variables.tf`：变量，含 `vms` 映射
- `main.tf`：`for_each` 创建三台 VM
- `outputs.tf`：输出主机名 → IP/用户
- `terraform.tfvars`：API 地址、token、节点名、模板 VMID

`main.tf` 核心：

```hcl
resource "proxmox_virtual_environment_vm" "node" {
  for_each  = var.vms                 # web01/sweb01/lb01
  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  bios          = "ovmf"              # 保持模板固件，避免被默认 seabios 覆盖
  scsi_hardware = "virtio-scsi-single"

  clone { vm_id = var.template_vmid, full = true }

  agent { enabled = true }

  initialization {
    interface = "scsi1"               # cloud-init 盘在 virtio-scsi
    dns { servers = [var.vm_dns] }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.vm_prefix_length}"  # 10.0.0.x/24
        gateway = var.vm_gateway                              # 10.0.0.1
      }
    }
    user_account {
      username = var.vm_user          # hao
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }

  network_device { bridge = var.vm_bridge, model = "virtio" }   # vmbr1
  started = true
}
```

### 3. 执行

```sh
cd /root/xceuler/terraform
terraform init
terraform validate
terraform plan
terraform apply -auto-approve
```

结果：`Apply complete! Resources: 3 added, 0 changed, 0 destroyed.`

---

## 五、Ansible 统一配置（`/root/xceuler/ansible/`）

### 1. 安装

```sh
apt-get install -y ansible     # 7.7.0
```

### 2. 文件清单

- `ansible.cfg`：inventory、免 host key 校验、become=sudo、pipelining
- `inventory.ini`：

  ```ini
  [openeuler]
  web01  ansible_host=10.0.0.7
  sweb01 ansible_host=10.0.0.8
  lb01   ansible_host=10.0.0.9

  [openeuler:vars]
  ansible_user=hao
  ansible_ssh_private_key_file=/root/.ssh/id_rsa
  ansible_python_interpreter=/usr/bin/python3
  ```

- `playbook.yml` 任务：
  1. 确保 `hao` 用户存在并加入 `wheel/adm/systemd-journal`；
  2. 写入 `/etc/sudoers.d/90-hao`（NOPASSWD，`visudo` 校验）；
  3. 确保**多把**授权公钥存在（`admin_pubkeys` 列表，见第十一节）；
  4. **设置短主机名**（`web01`，而非 `web01.local`）；
  5. 维护 `/etc/hosts`（`127.0.1.1 <hostname>`，并归一化 `127.0.0.1` 主机名行）；
  6. 写入 `/etc/ssh/sshd_config.d/99-keyonly.conf`（`PasswordAuthentication no` 等），并重启 sshd；
  7. 确保 `qemu-guest-agent` 已启用并运行。

### 3. 执行

```sh
cd /root/xceuler/ansible
ansible openeuler -m ansible.builtin.ping      # 连通性
ansible-playbook playbook.yml --diff
ansible-playbook playbook.yml                  # 第二次验证幂等：changed=0
```

---

## 六、最终验收

Terraform 输出：

```
vms = {
  lb01   = { ip = "10.0.0.9", user = "hao", vmid = 127 }
  sweb01 = { ip = "10.0.0.8", user = "hao", vmid = 126 }
  web01  = { ip = "10.0.0.7", user = "hao", vmid = 125 }
}
```

SSH 验证（`BatchMode=yes` 强制只用密钥）：

```
web01:  host=web01  ip=10.0.0.7  cloud-init=done  sudo=NOPASSWD OK
sweb01: host=sweb01 ip=10.0.0.8  cloud-init=done  sudo=NOPASSWD OK
lb01:   host=lb01   ip=10.0.0.9  cloud-init=done  sudo=NOPASSWD OK
```

- `sshd -T`：`passwordauthentication no`、`kbdinteractiveauthentication no`
- `qemu-guest-agent`：`active`
- `terraform plan`：**No changes**（无漂移）

---

## 七、注意事项与遗留问题

1. **历史命名与 VM 118**：已存在的、无关的 VM **118** 名字叫 `db01`（IP 10.0.0.51，运行中）。本次在 10.0.0.9（VMID **127**）上的机器最初也叫 `db01`，后已改名为 **`lb01`** 以避开重名。
2. **provider 下载**：本机访问 GitHub release 被墙，使用 `gh-proxy.com` 下载 + 文件系统镜像方式安装。
3. **cloud-init 盘位置**：必须在 `scsi1`（virtio-scsi），IDE CD-ROM guest 识别不到。
4. **searchdomain**：模板已移除，克隆体也不会再生成 FQDN；已存在的三台也已清理。
5. Terraform 请在 `/root/xceuler/terraform` 目录下执行（状态文件为本地 `terraform.tfstate`）。
6. 宿主机内存紧张，三台新 VM 采用 2 GiB/台的小规格，避免过度超分。

---

## 八、常用命令速查

```sh
# 查看 VM
qm list

# Terraform
cd /root/xceuler/terraform && terraform plan && terraform apply -auto-approve

# Ansible（幂等）
cd /root/xceuler/ansible && ansible-playbook playbook.yml

# 登录
ssh -i /root/.ssh/id_rsa hao@10.0.0.7 'hostname; hostname -I; sudo -n true && echo sudo-ok'
```

---

## 九、变更记录：VM 127 由 `db01` 改名为 `lb01`

为避开与已存在 VM 118（同名 `db01`）重名，把 10.0.0.9（VMID 127）上的主机改名为 `lb01`。做法：**用 Terraform 状态迁移做原地改名**，避免销毁重建。

1. 修改 `terraform/variables.tf` 中 `vms` 映射：`db01` → `lb01`（VMID/IP 不变）。
2. 迁移 Terraform 状态中的资源键：

   ```sh
   cd /root/xceuler/terraform
   terraform state mv \
     'proxmox_virtual_environment_vm.node["db01"]' \
     'proxmox_virtual_environment_vm.node["lb01"]'
   ```

3. 应用（只改 VM 名称，**原地更新**，不会重建）：

   ```sh
   terraform plan     # ~ name = "db01" -> "lb01"，0 to add / 0 to destroy
   terraform apply -auto-approve
   ```

4. 修改 `ansible/inventory.ini`：`db01` → `lb01`，然后重跑 playbook 改 guest 主机名与 `/etc/hosts`：

   ```sh
   cd /root/xceuler/ansible
   ansible-playbook playbook.yml --diff
   ```

   playbook 同时会把 `/etc/hosts` 里的 `127.0.0.1 db01.local db01` 与 `127.0.1.1 db01`
   规范为 `lb01` 对应条目（已加入“归一化 127.0.0.1 主机名行”任务）。

5. 验证：

   ```sh
   qm list                              # 127 lb01
   ssh hao@10.0.0.9 'hostname'          # lb01
   terraform plan                       # No changes
   ```

---

## 十、SSH 连接与主机密钥说明（排障）

### 1. 正确的登录方式

镜像**禁止 root 登录**，必须用 `hao`：

```sh
ssh hao@10.0.0.7
```

若直接执行 `ssh 10.0.0.7`（默认走 `root@`），会看到：

```
Please login as the user "hao" rather than the user "root".
```

### 2. 方便起见：宿主机上的 SSH 别名

已在 `/root/.ssh/config` 增加如下配置，使 `ssh 10.0.0.7`、`ssh web01`、`ssh lb01` 等都以 `hao` 登录：

```sshconfig
# openEuler cloud VMs (Terraform-managed: web01/sweb01/lb01)
Host web01
    HostName 10.0.0.7
Host sweb01
    HostName 10.0.0.8
Host lb01
    HostName 10.0.0.9
Host web01 sweb01 lb01 10.0.0.7 10.0.0.8 10.0.0.9
    User hao
    IdentityFile /root/.ssh/id_rsa
    StrictHostKeyChecking accept-new
```

效果：

```
ssh 10.0.0.7 -> web01  OK as hao      ssh web01  -> web01  OK as hao
ssh 10.0.0.8 -> sweb01 OK as hao      ssh sweb01 -> sweb01 OK as hao
ssh 10.0.0.9 -> lb01   OK as hao      ssh lb01   -> lb01   OK as hao
```

### 3. 主机密钥变更（REMOTE HOST IDENTIFICATION HAS CHANGED）

**现象**：

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Host key verification failed.
```

**原因**：`known_hosts` 里保留的是**旧占用该 IP 的机器**的主机密钥。典型场景：

- 早期用黄金模板（VMID 9010）在 10.0.0.7 做过端到端测试，把模板的主机密钥记到了 `known_hosts`；
- 之后克隆出的 web01 首启**会重新生成自己的 SSH 主机密钥**（每台 VM 独立一份），与模板不同；
- 于是 IP 复用、密钥不匹配，严格校验直接拒绝连接。

**处理**：删除该 IP 的旧密钥记录后重连即可（重连时会自动写入新密钥）：

```sh
# 在发起 SSH 的客户端上执行：
ssh-keygen -f ~/.ssh/known_hosts -R 10.0.0.7
ssh hao@10.0.0.7
```

本次已在 Proxmox 宿主机上清理了 10.0.0.7 / 10.0.0.8 / 10.0.0.9 的旧记录：

```sh
ssh-keygen -f /root/.ssh/known_hosts -R 10.0.0.7
ssh-keygen -f /root/.ssh/known_hosts -R 10.0.0.8
ssh-keygen -f /root/.ssh/known_hosts -R 10.0.0.9
```

> 提示：只要**重建 VM 并复用同一 IP**，就可能再次出现该告警，属正常现象，用 `ssh-keygen -R <IP>` 清一下即可。从其他机器（如笔记本）连接时，需在**那台机器**上执行同样的清理。

---

## 十一、新增 SSH 登录公钥（`hao` 用户）

把其他客户端的公钥加入三台 VM 上 `hao` 用户的 `authorized_keys`，统一由 Ansible 的 `admin_pubkeys` 列表管理，**幂等、可重复**。

### 1. 在 playbook 中登记公钥

编辑 `/root/xceuler/ansible/playbook.yml` 的 `vars.admin_pubkeys`：

```yaml
  vars:
    admin_pubkeys:
      - "{{ lookup('file', '/root/.ssh/id_rsa.pub') }}"                 # 宿主机 root@teacher
      - "<YOUR_SSH_PUBLIC_KEY>"
```

对应任务（自动遍历列表）：

```yaml
    - name: Ensure the admin SSH public keys are authorized
      ansible.builtin.authorized_key:
        user: "{{ admin_user }}"
        key: "{{ item }}"
        state: present
        exclusive: false
      loop: "{{ admin_pubkeys }}"
```

### 2. 应用

```sh
cd /root/xceuler/ansible
ansible-playbook playbook.yml --diff     # 首次：写入新公钥
ansible-playbook playbook.yml            # 再次：changed=0（幂等）
```

### 3. 验证

```sh
for ip in 10.0.0.7 10.0.0.8 10.0.0.9; do
  echo "== $ip =="
  ssh -o BatchMode=yes hao@$ip 'cat ~/.ssh/authorized_keys'
done
```

完成后，持有对应私钥的客户端即可直接登录，例如从 m01：

```sh
ssh -i ~/.ssh/id_ed25519 hao@10.0.0.7     # 或 10.0.0.8 / 10.0.0.9
```

> 说明：
> - 该公钥由 **Ansible 统一管理**。若日后只执行 `terraform apply` 重建 VM 而**未**重跑 Ansible，新机器上不会自动带这把钥匙；按流程再执行一次 `ansible-playbook playbook.yml` 即可。
> - 如需“裸克隆”（不跑 Ansible）也自带该公钥，可将其一并烤进黄金模板（VMID 9010，做法见第三节的 `virt-customize`）。



