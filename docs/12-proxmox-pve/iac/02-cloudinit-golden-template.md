# 02 · 黄金模板与 cloud-init：让 VM 第一次启动就可用

> 本章目标：把“装系统、改 IP、加用户、配 SSH”从人工安装变成**模板 + cloud-init**。
> 示例在 [`../assets/iac/cloud-init/`](../assets/iac/cloud-init/)；
> 真实 openEuler 建模板过程见 [`../notes/openeuler-batch-deploy-2026-11.md`](../notes/openeuler-batch-deploy-2026-11.md)。

## 1. 当时的情况

最开始是“下载 DVD ISO → 手动安装 → 进系统改 IP → 加 SSH key”，一台 20 分钟，还容易漏：

- 主机名有时是 `web01.local`，有时是 `web01`；
- cloud-init 盘挂在 `ide2`，openEuler 根本不识别；
- 模板基盘是只读的，`virt-customize` 直接失败；
- `qemu-guest-agent` 没装，Terraform `started=true` 一直等 agent 超时；
- 模板里残留 machine-id / SSH host key，克隆出来的机器身份重复。

后来改成：

```text
云镜像 qcow2
  → 离线注入 cloud-init + qemu-guest-agent
  → 创建模板 9010（UEFI + virtio-scsi）
  → Terraform 克隆 + cloud-init 首启
  → Ansible 做最终基线
```

## 2. 主要概念

### 2.1 cloud-init 的 NoCloud 数据源

Proxmox 的 cloud-init 盘本质是一个小 ISO，里面有两个文件：

| 文件 | 作用 |
|---|---|
| `user-data` | 用户、SSH key、包、`runcmd`、`write_files` |
| `meta-data` | `instance-id`、`local-hostname` |

PVE 还支持 `network-config`（由 `ipconfig0/1` 生成）。guest 里的 cloud-init 通过
`datasource_list: [NoCloud, ConfigDrive, None]` 找到它。

### 2.2 两种用法

| 方式 | 谁生成 cloud-init | 适合 |
|---|---|---|
| Provider 生成 | Terraform `initialization.user_account` + `ip_config` | 简单、字段少、和 Terraform 强绑定 |
| PVE snippet | 手写 `user-data`/`meta-data`，`cicustom` 引用 | 需要 `write_files`/`runcmd`/复杂网络 |

本仓库两种都有：

- `assets/xceuler/terraform/main.tf`：Provider 生成；
- `assets/iac/cloud-init/*.example`：snippet 方式；
- 现有 K8s 节点（119–124）用的是 `/var/lib/vz/snippets/worker0X-user.yml` + `cicustom`。

### 2.3 cloud-init 只负责“第一次”

cloud-init 的很多模块只在**首次启动**执行（per-instance）。改 snippet 后，已经初始化过的 VM
不会自动重跑。重新初始化要：

```bash
qm cloudinit update <vmid>
# 或在 guest 内
cloud-init clean --logs --reboot
```

生产上不要把 cloud-init 当配置管理工具；**最终状态交给 Ansible**。

## 3. 操作步骤

### 3.1 准备云镜像

```bash
cd /root/xceuler/images
sha256sum openEuler-24.03-LTS-SP4-x86_64.qcow2
# 与官方/镜像站公布值比对
```

本环境实际校验值（`.xz`）：

```text
02bf2efa55b1c921ad3c8c5c563bd12cd601892d9906a1167b67254f884282b2
```

### 3.2 离线注入 cloud-init

openEuler 云镜像默认没有 cloud-init，需要离线补：

- `cloud-init-23.4.1`
- `hostname-3.23`
- `/etc/cloud/cloud.cfg.d/99-proxmox.cfg`：

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

- `/etc/cloud/ds-identify.cfg`：

```text
policy: search,found=all,maybe=all,notfound=enabled
```

- grub 强制 `net.ifnames=0 biosdevname=0`（BIOS/UEFI 两套 cfg 都重新生成）；
- sysprep：清空 `/etc/machine-id`、删除 SSH host key、清理 cloud-init 状态/NetworkManager 连接/日志。

> **不要**在 `cloud.cfg.d` 写 `network: {config: enabled}`。cloud-init 23.4 会把它当成
> 实例网络配置 `{"config":"enabled"}`，报 `Unknown network config version: None`。
> NoCloud 的 network-config 会自动生效。

### 3.3 创建模板 9010

关键 `qm config`：

```text
bios: ovmf
scsihw: virtio-scsi-single
scsi0: local-lvm:base-9010-disk-1,iothread=1,size=40G
scsi1: local-lvm:vm-9010-cloudinit,media=cdrom      # cloud-init 盘
efidisk0: local-lvm:base-9010-disk-0,efitype=4m,pre-enrolled-keys=0
ciuser: hao
nameserver: 223.5.5.5
agent: enabled=1
template: 1
```

注意：

- **cloud-init 盘必须挂 `scsi1`**：openEuler guest 只有 PATA，没有 ATAPI，`ide2` 检测不到；
- 模板上不要保留 `ipconfig0`，交给 Terraform 按 VM 设置；
- 移除 `searchdomain: local`，否则 cloud-init 可能把主机名设成 FQDN；
- 模板基盘是只读的，注入前 `lvchange -prw`，完成后 `lvchange -pr`。

### 3.4 注入 qemu-guest-agent

模板启用了 `agent: enabled=1`，但镜像里没有 agent，Terraform 会等超时。

```bash
lvchange -prw /dev/pve/base-9010-disk-1

# 宿主机上把 DVD 目录用 HTTP 暴露给 libguestfs
nohup python3 -m http.server 8899 --directory /mnt/dvd &

virt-customize -a /dev/pve/base-9010-disk-1 \
  --run-command 'printf "[dvd]\nname=dvd\nbaseurl=http://169.254.2.2:8899\nenabled=1\ngpgcheck=0\n" > /etc/yum.repos.d/dvd.repo' \
  --run-command 'dnf -y --disablerepo="*" --enablerepo=dvd install qemu-guest-agent' \
  --run-command 'ln -sf /usr/lib/systemd/system/qemu-guest-agent.service /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service'

# virt-customize 会随机化 machine-id，需要再次清空
truncate -s 0 /etc/machine-id   # 在 guest 内或 chroot 执行
```

> libguestfs 应用环境的网关是 **`169.254.2.2`**，不是 `10.0.2.2`。写错会一直连接超时。

### 3.5 使用 snippet 方式的 user-data

示例：[`../assets/iac/cloud-init/k8s-node-user-data.yaml.example`](../assets/iac/cloud-init/k8s-node-user-data.yaml.example)

```yaml
#cloud-config
hostname: k8s-lab-w01
fqdn: k8s-lab-w01.local
manage_etc_hosts: false
users:
  - name: hao
    groups: [wheel, sudo, adm, systemd-journal]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - <YOUR_SSH_PUBLIC_KEY>
ssh_pwauth: false
disable_root: true
packages: [qemu-guest-agent, curl, jq, chrony]
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ hostnamectl, set-hostname, k8s-lab-w01 ]
```

放到 PVE snippet 目录并挂载：

```bash
cp k8s-node-user-data.yaml.example /var/lib/vz/snippets/k8s-lab-w01-user.yaml
cp k8s-node-meta-data.yaml.example /var/lib/vz/snippets/k8s-lab-w01-meta.yaml

qm set 130 --cicustom "user=local:snippets/k8s-lab-w01-user.yaml,meta=local:snippets/k8s-lab-w01-meta.yaml"
qm cloudinit update 130
```

### 3.6 验证

```bash
qm cloudinit dump 130 user
qm cloudinit dump 130 network

ssh hao@10.0.0.130 'hostname; cloud-init status --long; systemctl is-active qemu-guest-agent'
```

guest 内：

```bash
cloud-init status --long
sudo cat /var/log/cloud-init-output.log
sudo cloud-init query --all | head
```

## 4. 踩坑点

### 坑 1：cloud-init 盘挂 IDE

openEuler 内核没有 ATAPI，`ide2` 上的 cloud-init 盘不会被识别。改 `scsi1`。

### 坑 2：模板基盘只读

`virt-customize` 报 `Permission denied` / `read-only`。先：

```bash
lvchange -prw /dev/pve/base-9010-disk-1
# 完成后
lvchange -pr /dev/pve/base-9010-disk-1
```

### 坑 3：libguestfs 网关写错

应用环境网关是 `169.254.2.2`；`10.0.2.2` 是 QEMU user-mode 网络，不是 libguestfs。

### 坑 4：machine-id 重复

`virt-customize` 会随机化 machine-id，但 sysprep 后又被清空/重建。
克隆前确认模板 `/etc/machine-id` 为空，首次启动由 systemd 生成。

### 坑 5：主机名变成 FQDN

模板里 `searchdomain: local` 会让 cloud-init 把 `web01` 设成 `web01.local`。
删掉 searchdomain，或在 cloud-init 里显式 `hostname` + `manage_etc_hosts: false`。

### 坑 6：cloud-init 不重跑

改了 user-data，已初始化的 VM 不会变。`qm cloudinit update` 只更新 ISO，不重跑；
需要 guest 内 `cloud-init clean --reboot`，或重建 VM。

### 坑 7：SSH 密码登录被禁用

示例里 `ssh_pwauth: false`、`disable_root: true`。如果 SSH key 没注入成功，
会直接锁死。先用控制台验证 key 登录，再加固 SSH。

### 坑 8：cloud-init 状态不是 done

`cloud-init status` 可能是 `error`/`degraded`。看：

```bash
sudo cloud-init status --long
sudo journalctl -u cloud-init --no-pager
sudo cat /var/log/cloud-init-output.log
```

常见原因：包安装失败（无外网）、`runcmd` 命令不存在、磁盘只读。

## 5. 一页命令

```bash
# 模板
qm config 9010 | grep -E 'bios|scsihw|scsi0|scsi1|ciuser|agent|template'

# 新建测试 VM
qm clone 9010 130 --name k8s-lab-w01 --full
qm set 130 --cores 4 --memory 4096 --cpu x86-64-v3
qm set 130 --net0 virtio,bridge=vmbr1
qm set 130 --ipconfig0 ip=10.0.0.130/24,gw=10.0.0.1
qm set 130 --cicustom "user=local:snippets/k8s-lab-w01-user.yaml,meta=local:snippets/k8s-lab-w01-meta.yaml"
qm start 130

# 验证 / 清理
qm cloudinit dump 130 user
ssh hao@10.0.0.130 'cloud-init status --long; hostname -f'
qm stop 130 && qm destroy 130
```
