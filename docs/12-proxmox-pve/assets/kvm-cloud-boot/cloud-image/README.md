# 云镜像 vs ISO 模板：本环境实测

对应教程：[`../../10-kvm-qemu-virtio-cloud-boot.md`](../../../10-kvm-qemu-virtio-cloud-boot.md) 第 7 节。

## 1. 结论

| 对象 | 是云镜像吗 | 证据 |
|---|---|---|
| PVE openEuler 模板 9010 | **是** | openEuler qcow2，40GiB 虚拟/2.86GiB 实占，ext4 rootfs + vfat boot，`/etc/cloud/cloud.cfg`，`citype: nocloud`，cloud-init 盘 `scsi1` |
| Hyper-V ubuntu01/02 | **是** | `/etc/cloud/build.info` = `server/20260826`，`LABEL=cloudimg-rootfs`，无 `/var/log/installer`，NoCloud seed `/dev/sr0` |
| ISO 文件 | 不是模板，只是安装介质 | `openEuler-24.03-LTS-SP4-x86_64-dvd.iso`、`ubuntu-24.04.5-live-server-amd64.iso` |

## 2. 云镜像 vs 普通 ISO 模板

| 维度 | 云镜像 | ISO 安装模板 |
|---|---|---|
| 本质 | 已安装好的磁盘（qcow2/vhdx/raw） | 安装介质，必须跑 installer |
| 首启 | cloud-init 注入用户/网络/SSH | 安装器交互或 preseed/kickstart |
| 分区 | 镜像预定义 | 安装器按配置生成 |
| 默认用户 | 镜像内置（ubuntu/cloud-user），通常禁 root | 安装时创建 |
| 速度 | 克隆秒级 | 安装 10–30 分钟 |
| 可复现 | 镜像 digest/版本 | 依赖安装器/网络/应答文件 |
| 定制 | cloud-init user-data | 安装时选包/分区/驱动 |
| 诊断 | `build.info`、`cloudimg-rootfs`、无 installer log | `/var/log/installer`、anaconda 日志 |
| 不可变 | 天然适合 | 需 sysprep/清理 |

## 3. 本环境证据

openEuler 云镜像：

```text
qemu-img info: virtual 40 GiB, disk 2.86 GiB
virt-filesystems: /dev/sda1 vfat 2.0G, /dev/sda2 ext4 rootfs 37G
virt-cat /etc/cloud/cloud.cfg: disable_root: true, ssh_pwauth: false
```

Ubuntu cloud image：

```text
/etc/cloud/build.info: build_name server / serial 20260826
/etc/fstab: LABEL=cloudimg-rootfs / ext4 ...
/var/log/installer: No such file or directory
cloud-init: DataSourceNoCloud [seed=/dev/sr0]
```

ISO：

```text
openEuler DVD 4.6G: LABEL=openEuler-24.03-LTS-SP4-x86_64
Ubuntu live-server 3.9G: LABEL=Ubuntu-Server 24.04.5 LTS amd64
```

## 4. 工具安装与测试

| 工具 | 版本 | 用途 |
|---|---|---|
| qemu-img | 9.2.0 | 看镜像格式/虚拟大小/实占 |
| libguestfs | 1.48.2 | `virt-cat`/`virt-filesystems` 直接读镜像 |
| cloud-localds | cloud-image-utils 0.33 | 生成 NoCloud `cidata` ISO |
| Packer | 1.16.2 | 金镜像构建 |
| packer-plugin-proxmox | 1.2.4 | Proxmox clone/iso builder |

测试：

```bash
qemu-img info openEuler-...qcow2
virt-filesystems -a openEuler-...qcow2 --all --long -h
virt-cat -a openEuler-...qcow2 /etc/cloud/cloud.cfg

cloud-localds seed.iso user-data.yaml meta-data.yaml
file seed.iso        # ISO 9660 'cidata'
isoinfo -l -i seed.iso

packer fmt -check packer-proxmox.pkr.hcl
packer validate packer-proxmox.pkr.hcl
```

## 5. 文件

| 文件 | 内容 |
|---|---|
| `openEuler-image.txt` | openEuler 云镜像 qemu-img/virt-filesystems/cloud.cfg |
| `ubuntu-gitlab-201.txt` | Ubuntu cloud image build.info/fstab/partitions/no installer |
| `ubuntu-harbor-202.txt` | 同上（Harbor） |
| `iso-media.txt` | ISO label/大小/类型 |
| `tools-test.txt` | cloud-localds + packer fmt/validate |
| `install-tools.txt` | 已安装工具/版本/插件 |
| `packer-proxmox.pkr.hcl` | Packer `proxmox-clone` 示例（validate 通过） |
