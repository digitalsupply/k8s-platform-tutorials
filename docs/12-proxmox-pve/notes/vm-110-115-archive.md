# 虚拟机 110–115 归档说明(删除前完整记录)

| 项目 | 内容 |
|------|------|
| 文档生成时间 | 2026-09-27 |
| Proxmox VE | pve-manager/8.4.13/5b08ebc2823dd9cb |
| 宿主机节点 | `teacher` |
| 宿主机硬件 | Intel Xeon Gold 6138 @ 2.00GHz ×2 socket / 40 核 80 线程 / 64 GB |
| 内核 | 6.8.12-15-pve(UEFI 启动,SecureBoot 关闭) |
| 适用范围 | VMID 110, 111, 112, 113, 114, 115 |
| 删除原因 | 以 openEuler-24.03-LTS-SP4 重建 3 台 VM 取代原 6 台 LB/Web 架构 |
| 备份状态 | **无任何 vzdump 备份**,本文档为唯一可恢复依据 |

---

## 1. 角色与规格总览

| VMID | 主机名 | 角色 | vmbr1 (10.0.0.0/24) | vmbr2 (172.16.1.0/16) | CPU | 内存 | 磁盘 |
|-----:|--------|------|----------------------|----------------------|-----|------|------|
| 110 | `lb01` | 负载均衡节点 1 | 10.0.0.5/24 | 172.16.1.5/16 | 1 socket × 2 cores | 8192 MB | 20 GB |
| 111 | `lb02` | 负载均衡节点 2 | 10.0.0.6/24 | 172.16.1.6/16 | 1 socket × 2 cores | 6144 MB | 20 GB |
| 112 | `web01` | Web 前端节点 1 | 10.0.0.7/24 | 172.16.1.7/16 | 1 socket × 4 cores | 6144 MB | 50 GB |
| 113 | `web02` | Web 前端节点 2 | 10.0.0.8/24 | 172.16.1.8/16 | 1 socket × 4 cores | 6144 MB | 50 GB |
| 114 | `sweb01` | 静态 Web 节点 1 | 10.0.0.9/24 | 172.16.1.9/16 | 1 socket × 4 cores | 6144 MB | 50 GB |
| 115 | `sweb02` | 静态 Web 节点 2 | 10.0.0.10/24 | 172.16.1.10/16 | 1 socket × 4 cores | 6144 MB | 50 GB |

**合计资源:** CPU 20 vCPU、内存 39 GB、系统盘 240 GB。

删除后可从 LVM-Thin 池释放的配置容量:240 GB(实际已分配数据量见第 6 节)。

---

## 2. 身份标识(重建时如需保持一致可复用)

| VMID | 主机名 | net0 MAC (vmbr1) | net1 MAC (vmbr2) | SMBIOS UUID | VM Generation ID |
|-----:|--------|------------------|------------------|-------------|------------------|
| 110 | lb01 | `BC:24:11:0B:10:E3` | `BC:24:11:88:AD:0B` | `3c541c42-6f1a-48f0-af5f-9a0badb5d56f` | `2d91d4af-123b-4015-8d7a-d5371af441db` |
| 111 | lb02 | `BC:24:11:14:F9:E0` | `BC:24:11:3A:35:52` | `3fce49dc-3c3a-450f-b229-bbaba83952fe` | `4e4f74c5-c10d-483e-9ab9-27a75265da90` |
| 112 | web01 | `BC:24:11:E7:75:16` | `BC:24:11:11:BB:98` | `7a3a4c6f-2d6e-4c0c-a8ee-24d9d09e5e82` | `2f97b62d-1693-4090-8a14-5bb1ba510d59` |
| 113 | web02 | `BC:24:11:C2:C2:FF` | `BC:24:11:B7:70:5C` | `2d760f7b-d293-4ed4-a31f-afa116822954` | `63418c3c-29cc-4a31-bd60-c302fb32ff72` |
| 114 | sweb01 | `BC:24:11:E7:7E:CE` | `BC:24:11:5C:45:49` | `6182b175-6b92-44ae-9be2-c4bcebcc9296` | `59e03ace-e9da-4f0b-bd50-1f9352d6145e` |
| 115 | sweb02 | `BC:24:11:BC:6E:D1` | `BC:24:11:F5:2E:89` | `75f329d5-1a6e-4f19-84be-7d4db341c4af` | `49de776f-5914-487f-8d12-7b4e89315f5d` |

6 台机器 `meta: creation-qemu=9.2.0`,`ctime=1759141482` = **2025-09-29 18:24:42 CST**,为同一批脚本批量创建。

---

## 3. 网络拓扑

```
                       宿主机 teacher (PVE 8.4.13)
                       Xeon Gold 6138 ×2 / 64 GB / LVM-Thin
                                 │
   物理口 eno1np0 ───── vmbr0 ──┴── 192.168.67.156/24   [管理网 / 上联网关 192.168.67.1]
                                 │
             ┌───────────────────┴───────────────────┐
     iptables MASQUERADE                    iptables MASQUERADE
             │                                       │
   ┌─────────▼──────────────┐            ┌───────────▼──────────────┐
   │ vmbr1  10.0.0.1/24     │            │ vmbr2  172.16.1.1/16     │
   │ 业务/管理网             │            │ 服务/集群网              │
   │ gateway = 10.0.0.1     │            │ gateway = 172.16.1.1     │
   └─────────┬──────────────┘            └───────────┬──────────────┘
             │                                       │
      lb01    .5    ← 负载均衡 VIP 归属节点         .5
      lb02    .6                                    .6
      web01   .7                                    .7
      web02   .8                                    .8
      sweb01  .9                                    .9
      sweb02  .10                                   .10
             │                                       │
        (本批 6 台,双网卡末位完全一致)  ...
      nfs01   .31                                   .31      ← 保留
      backup  .41                                   .41      ← 保留
      db01    .51                                   .51      ← 保留
      m01     .61                                   .61      ← 保留(K8s)
```

**设计特点**
- **双网卡对称配对**:每台 VM 两张网卡分别接入 vmbr1 / vmbr2,IP 末位完全一致(`.5/.5`、`.10/.10`),管理定位直观。
- vmbr1、vmbr2 均为 `bridge-ports none` 的纯内部网桥,分别经 iptables NAT 从 vmbr0 出网。
- 两网段地址由 `10.0.0.0/24` 与 `172.16.1.0/16` 组成,网关分别为 `.1`(宿主在两个网桥上的地址)。

**宿主机 `/etc/network/interfaces` 相关片段(供参照)**

```
auto vmbr0
iface vmbr0 inet static
        address 192.168.67.156/24
        gateway 192.168.67.1
        bridge-ports eno1np0
        bridge-stp off
        bridge-fd 0

auto vmbr1
iface vmbr1 inet static
    address 10.0.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE

auto vmbr2
iface vmbr2 inet static
    address 172.16.1.1/16
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up iptables -t nat -A POSTROUTING -s 172.16.1.0/16 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 172.16.1.0/16 -o vmbr0 -j MASQUERADE
```

---

## 4. 完整配置(每台的 `qm config` 原文)

### VM 110 — lb01
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 2
cpu: x86-64-v2-AES
ide2: local-lvm:vm-110-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.5/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.5/16
memory: 8192
meta: creation-qemu=9.2.0,ctime=1759141482
name: lb01
nameserver: 192.168.2.1
net0: virtio=BC:24:11:0B:10:E3,bridge=vmbr1
net1: virtio=BC:24:11:88:AD:0B,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-110-disk-0,iothread=1,size=20G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=3c541c42-6f1a-48f0-af5f-9a0badb5d56f
sockets: 1
vmgenid: 2d91d4af-123b-4015-8d7a-d5371af441db
```

### VM 111 — lb02
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 2
cpu: x86-64-v2-AES
ide2: local-lvm:vm-111-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.6/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.6/16
memory: 6144
meta: creation-qemu=9.2.0,ctime=1759141482
name: lb02
nameserver: 192.168.2.1
net0: virtio=BC:24:11:14:F9:E0,bridge=vmbr1
net1: virtio=BC:24:11:3A:35:52,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-111-disk-0,iothread=1,size=20G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=3fce49dc-3c3a-450f-b229-bbaba83952fe
sockets: 1
vmgenid: 4e4f74c5-c10d-483e-9ab9-27a75265da90
```

### VM 112 — web01
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 4
cpu: x86-64-v2-AES
ide2: local-lvm:vm-112-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.7/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.7/16
memory: 6144
meta: creation-qemu=9.2.0,ctime=1759141482
name: web01
nameserver: 192.168.2.1
net0: virtio=BC:24:11:E7:75:16,bridge=vmbr1
net1: virtio=BC:24:11:11:BB:98,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-112-disk-0,iothread=1,size=50G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=7a3a4c6f-2d6e-4c0c-a8ee-24d9d09e5e82
sockets: 1
vmgenid: 2f97b62d-1693-4090-8a14-5bb1ba510d59
```

### VM 113 — web02
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 4
cpu: x86-64-v2-AES
ide2: local-lvm:vm-113-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.8/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.8/16
memory: 6144
meta: creation-qemu=9.2.0,ctime=1759141482
name: web02
nameserver: 192.168.2.1
net0: virtio=BC:24:11:C2:C2:FF,bridge=vmbr1
net1: virtio=BC:24:11:B7:70:5C,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-113-disk-0,iothread=1,size=50G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=2d760f7b-d293-4ed4-a31f-afa116822954
sockets: 1
vmgenid: 63418c3c-29cc-4a31-bd60-c302fb32ff72
```

### VM 114 — sweb01
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 4
cpu: x86-64-v2-AES
ide2: local-lvm:vm-114-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.9/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.9/16
memory: 6144
meta: creation-qemu=9.2.0,ctime=1759141482
name: sweb01
nameserver: 192.168.2.1
net0: virtio=BC:24:11:E7:7E:CE,bridge=vmbr1
net1: virtio=BC:24:11:5C:45:49,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-114-disk-0,iothread=1,size=50G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=6182b175-6b92-44ae-9be2-c4bcebcc9296
sockets: 1
vmgenid: 59e03ace-e9da-4f0b-bd50-1f9352d6145e
```

### VM 115 — sweb02
```
agent: enabled=1
boot: order=scsi0;ide2
cicustom: user=local:snippets/force-password-login.yaml
cipassword: **********
ciupgrade: 0
ciuser: root
cores: 4
cpu: x86-64-v2-AES
ide2: local-lvm:vm-115-cloudinit,media=cdrom,size=4M
ipconfig0: ip=10.0.0.10/24,gw=10.0.0.1
ipconfig1: ip=172.16.1.10/16
memory: 6144
meta: creation-qemu=9.2.0,ctime=1759141482
name: sweb02
nameserver: 192.168.2.1
net0: virtio=BC:24:11:BC:6E:D1,bridge=vmbr1
net1: virtio=BC:24:11:F5:2E:89,bridge=vmbr2
numa: 0
ostype: l26
scsi0: local-lvm:vm-115-disk-0,iothread=1,size=50G
scsihw: virtio-scsi-single
searchdomain: local
smbios1: uuid=75f329d5-1a6e-4f19-84be-7d4db341c4af
sockets: 1
vmgenid: 49de776f-5914-487f-8d12-7b4e89315f5d
```

---

## 5. 配套配置

### 5.1 Cloud-Init 用户数据片段
路径:`/var/lib/vz/snippets/force-password-login.yaml`

```yaml
#cloud-config
ssh_pwauth: true
ssh_authorized_keys: []
users:
  - name: root
    plain_text_passwd: '<redacted-weak-password>'
    lock_passwd: false
    shell: /bin/bash
chpasswd:
  expire: False
disable_root: false
write_files:
  - path: /etc/ssh/sshd_config.d/90-proxmox-password-auth.conf
    permissions: '0644'
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
runcmd:
  - systemctl restart sshd
```

6 台 VM 共用的登录信息:root / `<redacted-weak-password>`,允许 root 密码登录,SSH 密钥被清空。

### 5.2 主机名与 /etc/hosts 生成脚本
路径:`/root/gen-hosts.sh`,通过 Proxmox snippet 注入静态 hosts,内容为 `172.16.1.x → 主机名` 映射(脚本中 `qm set --cicustom` 一行已被注释,故目前各 VM 仍使用 `force-password-login.yaml`)。映射表中 110–115 部分:

```
[110]="172.16.1.5  lb01"
[111]="172.16.1.6  lb02"
[112]="172.16.1.7  web01"
[113]="172.16.1.8  web02"
[114]="172.16.1.9  sweb01"
[115]="172.16.1.10 sweb02"
```

### 5.3 存储
`/etc/pve/storage.cfg`:
```
dir: local
    path /var/lib/vz
    content vztmpl,iso,backup

lvmthin: local-lvm
    thinpool data
    vgname pve
    content images,rootdir
```

---

## 6. 磁盘占用(Thin Pool `pve/data`,删除前)

| VMID | 卷名 | 容量 | 已用比例 | 估算实占 |
|-----:|------|------|---------:|---------:|
| 110 | vm-110-disk-0 | 20 GB | 57.60% | ~11.5 GB |
| 111 | vm-111-disk-0 | 20 GB | 45.75% | ~9.2 GB |
| 112 | vm-112-disk-0 | 50 GB | 26.86% | ~13.4 GB |
| 113 | vm-113-disk-0 | 50 GB | 47.52% | ~23.8 GB |
| 114 | vm-114-disk-0 | 50 GB | 52.36% | ~26.2 GB |
| 115 | vm-115-disk-0 | 50 GB | 32.63% | ~16.3 GB |

另有 6 个 4 MB 的 `vm-1xx-cloudinit` 卷(均 9.38% 占用)。

**注意:数据无备份。** 上表仅为容量统计,不含内容快照。删除后磁盘数据不可恢复,本批 VM 的系统内数据(网站内容、配置文件、日志)将全部丢失。

---

## 7. 删除操作记录

执行命令(逐台,带 `purge=1` 彻底清理配置与磁盘):
```bash
for id in 110 111 112 113 114 115; do
    qm destroy $id --purge=1
done
```

- 状态确认:6 台均为 `stopped`,删除前无需停机。
- 删除后释放:配置容量 240 GB;Thin Pool 实际回收约 100.4 GB(第 6 节估算值之和)。
- Thin Pool `pve/data` 删除前占用 78.56%,删除后预期降至约 65%。

**执行状态:待确认后执行。**

---

## 8. 后续重建计划(3 台 openEuler 取代原 6 台)

### 8.1 可用镜像
```
local:iso/openEuler-24.03-LTS-SP4-x86_64-dvd.iso   4.6 GB   (已上传,2026-09-27)
local:iso/Rocky-9.6-x86_64-minimal.iso           2.1 GB
local:iso/ubuntu-22.04.5-live-server-amd64.iso   2.0 GB
local:iso/ubuntu-24.04.5-live-server-amd64.iso   3.9 GB
```

### 8.2 IP 复用建议
原 110–115 占用的地址在删除后即为可用:

| 原地址 | 原主机名 | 建议归属新 VM |
|--------|----------|---------------|
| 10.0.0.5 / 172.16.1.5 | lb01 | 新 VM 1 |
| 10.0.0.6 / 172.16.1.6 | lb02 | 新 VM 2 |
| 10.0.0.7 / 172.16.1.7 | web01 | 新 VM 3 |
| 10.0.0.8 / 172.16.1.8 | web02 | (回收备用) |
| 10.0.0.9 / 172.16.1.9 | sweb01 | (回收备用) |
| 10.0.0.10 / 172.16.1.10 | sweb02 | (回收备用) |

### 8.3 与 openEuler 相关的重要差异
- openEuler 24.03 LTS SP4 的 dvd 版镜像**自带 cloud-init**,但 Proxmox 需要以 `local:iso/openEuler-24.03-LTS-SP4-x86_64-dvd.iso` 作为安装介质,再用 `ide2` 挂 Cloud-Init 盘(`local-lvm:vm-<id>-cloudinit`)的方式无法直接完成安装 —— 需先走图形/文本安装,装完再挂 Cloud-Init 盘做首次初始化,或改用 `cloudinit: user=local:snippets/xxx.yaml` 并将安装盘与 Cloud-Init 盘分离。
- `force-password-login.yaml` 中的 `plain_text_passwd` 与 sshd 配置对 openEuler 同样适用,但建议同时改为密钥认证。
- 现有脚本 `create_vms.sh`、`create-lab-vms.sh`、`create-k8s-vms.sh` 可作为新建参考模板。

---

## 9. 风险与注意事项

1. **数据不可恢复**:6 台 VM 无备份,删除后原 LB 配置、Web 站点内容、静态资源全部丢失。若尚有留存价值,应先执行 `vzdump` 备份再删除。
2. **弱口令风险**:6 台统一 root 密码 `<redacted-weak-password>` 且禁用密钥认证,LAN 内任意主机可完全控制这批机器。重建时应改为密钥认证。
3. **DNS 配置不自洽**:所有 VM 的 `nameserver` 指向 `192.168.2.1`,但宿主机管理网是 `192.168.67.0/24`,该 DNS 在本环境不存在,内网域名解析会失败。重建时应改为 `10.0.0.1` / `172.16.1.1` 或真实 DNS 地址。
4. **宿主机资源偏紧**:64 GB 内存当前已用 44.8 GB(剩余约 11.5 GB),3 台 openEuler 建议单台不超过 8 GB,合计不超过 24 GB。
5. **Thin Pool 容量**:全池 794 GB,删除前占用 78.56%。116/117/118 上 6 块 30 GB 数据盘已写满(99.98–99.99%),是池容量的主要增长点,新建 VM 前建议先评估这三台的处理方案。
6. **与 K8s 集群并存**:119–124(m01、master01/02、worker01–03)正在运行,重建时注意避免端口冲突(db01 的 3306 等)及 IP 重复。

---

*本文档由 Proxmox VE `qm config` / `pvesm` / `lvs` 输出整理,生成于 2026-09-27。*
