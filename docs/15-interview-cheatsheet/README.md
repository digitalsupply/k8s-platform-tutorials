# 15 · 面试一句话答案：Linux / 网络 / 云原生

> 这不是又一份“八股表”。每题给：
>
> 1. **一句话答案**（面试可直接说）；
> 2. **机器实证 / 本环境纠偏**（避免背错）；
> 3. **追问与易错点**；
> 4. **详细章节链接**。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)。
> 详细原理：[05 Linux](../05-linux/README.md)、[07 Networking](../07-networking/README.md)、
> [14 Containers](../14-containers/README.md)。

## 一页速查

| 知识点 | 一句话答案 | 本环境实证/纠偏 |
|---|---|---|
| 软链接 vs 硬链接 | 硬链接同 inode、不可跨 FS、不可链目录；软链接独立 inode、存目标路径 | 05 实验：`file`/`hard` 同 inode `1070350`，`sym` 独立 `1070351` |
| 僵尸进程怎么清 | `kill -9` 无效；杀父进程或让父进程 `wait()` | 05 实验：`State: Z`，`PPid` 指向父进程 |
| 负载高 CPU 低 | 有 `D` 状态进程卡在 IO/NFS；看 `vmstat` 的 `b`、`wchan`、PSI | PVE load 8.21/40 核；GitLab IO PSI `full 35.95`；本环境无持续 D |
| free 的 cache 要不要清 | 不用；cache 可回收，看 `available` | worker01 `free` 332Mi 但 `available` 5.9Gi |
| TIME_WAIT vs CLOSE_WAIT | TIME_WAIT 主动关闭方，会自愈；CLOSE_WAIT 应用没 `close()` | worker01 TIME_WAIT 127；实验 CLOSE_WAIT 1 |
| 三次握手为什么不是两次 | 防历史重复 SYN + 确认双方收发能力 | tcpdump 抓到 SYN / SYN-ACK / ACK |
| refused / timeout / reset | refused=有 RST；timeout=无响应；reset=建立后被重置 | 本机实测三种异常 |
| df 和 du 不一致 | 文件已删除但被进程持有；`lsof +L1` | 200MiB 删除文件仍被 Python 打开，`(deleted)` |
| 改 ulimit 不生效 | systemd 服务要改 unit `LimitNOFILE`；`limits.conf` 不一定管 systemd | m01 soft 1024/hard 524288，systemd `LimitNOFILE=524288` |
| cgroup v1/v2 | v1 各控制器多层级；v2 统一单层级 + controllers 委托 | 所有主机 `cgroup2fs`，controllers 统一 |
| OOMKilled vs Evicted | OOMKilled=超 cgroup memory limit 被内核杀；Evicted=节点压力被 kubelet 驱逐 | 当前无 OOM/Evicted；6 节点压力条件全 False |
| Ubuntu 24.04 迁移坑 | netplan 1.x、Python 3.12、apt 新 solver；distutils 从 stdlib 移除 | 24.04.4 / Python 3.12.3 / netplan 1.1.2 / apt 2.8.4；setuptools 仍提供 shim |
| Rocky 9 vs CentOS 7 | NetworkManager、nftables、chrony、dnf、cgroup v2 | `network-scripts` 包未装但 ifcfg 文件仍在；SELinux 本机 disabled |
| SELinux vs AppArmor | SELinux 标签/上下文；AppArmor 路径 | m01 SELinux disabled；Ubuntu AppArmor enabled |
| 容器为什么要 tini | PID 1 不自动回收僵尸、默认不处理 SIGTERM | frpc `NSpid: 2236 1`，没有 tini |
| epoll 为什么快 | 红黑树 + 就绪链表，只返回就绪 fd | Harbor nginx worker `anon_inode:[eventpoll]`；注意“零拷贝”说法不准确 |

## 一页速查（存储专题）

| 知识点 | 一句话答案 | 本环境实证/纠偏 |
|---|---|---|
| 分区与设备 | GPT/MBR 要懂；`lsblk`/`blkid`/`parted`；设备名会漂移，用 UUID/by-id/udev | PVE GPT、m01 MBR、worker GPT；`by-uuid`/`by-id` 都有 |
| LVM 核心 | PV→VG→LV；扩通常在线，缩通常离线；`pvmove` | PVE VG 930.51G，root 96G，pool 794.3G，VG 空闲 16G |
| LVM thin pool 满 | 可能 I/O 挂起/不可写，业务连锁；不是绝对整个 VG 只读 | pool 66.35%，autoextend 需 158.9G，VG 只剩 16G |
| RAID 选型 | 0/1/5/6/10；看容量、故障域、重建窗口、write hole | PVE 单 NVMe，无 md RAID；冗余靠 Ceph 副本 |
| 文件系统选型 | XFS 不能缩；ext4 离线可缩；ZFS/btrfs 复杂 | PVE/worker/GitLab/Harbor ext4；m01 XFS |
| fstab 挂载 | `noatime`；`nobarrier`/`barrier=0` 有风险；外部盘必须 `nofail` | 本机无外部 fstab 数据盘；K8s 卷由 runtime 挂 |
| 安全挂载 | 数据盘 `noexec,nosuid,nodev` | 通用建议 |
| NFS | hard/soft/timeo/retrans；`intr` 基本无效；stale handle 重挂 | NFSv4.2 `hard,timeo=600,retrans=2` |
| Ceph 排障 | `ceph -s` + PG 状态 + OSD up/in | HEALTH_OK，6 OSD up/in，465 PG active+clean |
| 云盘 | IOPS/吞吐/突发积分/快照一致性 | 本环境无云盘，仅原理 |
| 容器存储 CSI | CSI + PV/PVC/StorageClass；emptyDir 节点临时 | `ceph-rbd-sc`/`nfs-sc`，17 PV Bound |
| RWO 语义 | 单节点读写，不是单 Pod | 17 个 PVC 全 RWO；无 local-path |
| 数据可靠性 | SMART 看寿命/坏道；dmesg medium error 先备份换盘 | NVMe 0% used、0 media errors、7 unsafe shutdowns |

## 一页速查（Kubernetes）

| 层面 | 一句话 | 本环境实测 |
|---|---|---|
| apiserver | 认证→授权→准入；唯一读写 etcd | Node,RBAC + NodeRestriction；3 副本 |
| etcd | fsync 敏感；2GB quota；低峰 defrag | 3.6.6，133MB/37MB，quota 2.1GB，WAL p99 1ms |
| scheduler | Filter→Score→Reserve/Permit/Bind | 事件 `Successfully assigned` |
| controller-manager | controller 持续 reconcile | `--controllers=*`；RS ownerRef |
| kubelet/CRI | cgroup driver 一致；containerd/CRI-O | systemd + containerd 2.3.2 |
| CNI/CSI | Pod 网络/策略；PV/挂载/扩容 | Cilium 1.20.4；rbd.csi.ceph.com |
| requests/limits/QoS | 调度预留 vs 运行时限制 | 73 BestEffort/65 Burstable/0 Guaranteed |
| LimitRange/Quota | namespace 默认值/总量限制 | compassio 有；实验验证注入 |
| 拓扑/PDB/探针 | 打散、保可用、控流量 | 29 约束；11 PDB；1 个 preStop |
| 升级/证书/备份 | 版本偏差、cordon/drain、快照 | 全 1.35.9；leaf 326d；etcd 快照 133MB |
| 扩展/多租户 | CRD/Operator/Webhook/PSA | 146 CRD；12+9 webhook；PSA 仅 4 ns |
| 进阶 | KEDA/VPA/HPA/Cilium/Gateway API | KEDA 无；VPA 0 对象；Gateway 仅 CRD |

## 一页速查（虚拟化 / 云主机 / 引导）

| 题 | 一句话 | 本环境实测 |
|---|---|---|
| KVM/QEMU | KVM 虚拟化 CPU，QEMU 模拟设备；virtio 半虚拟化 | QEMU 9.2.0、/dev/kvm；Guest virtio_net/scsi |
| virsh | libvirt CLI，不是 KVM 本身 | 未安装 libvirtd/virsh；PVE 用 qm |
| 云 vs 物理 | 无真实 SMART、虚拟网卡/CPU/DMI、可能有 steal | QEMU HARDDISK/Virtual Disk；DMI QEMU/Microsoft |
| IMDSv2 | PUT token+TTL+hop limit，防 SSRF | 本环境无 IMDS，169.254.169.254 超时 |
| cloud-init | status/analyze/log 三件套 | 201 done，首启 apt 121s；m01 degraded |
| Packer | 不可变镜像，变更走新镜像 | 1.16.2 + proxmox 1.2.4 已装；示例 validate 通过 |
| 引导 | UEFI/Secure Boot/PXE/initramfs 驱动 | K8s Legacy；9010 UEFI 无 SecureBoot；Hyper-V Gen2 Off |

## 一页速查（IaC / GitOps）

| 题 | 一句话 | 本环境实测 |
|---|---|---|
| Ansible 幂等 | 执行 1 次和 N 次结果一样 | 第一次 changed=1，第二次 changed=0 |
| handlers | 只在 changed 时触发 | 第一次触发，第二次不触发 |
| `--check --diff` | 预演+文件 diff；不真装包 | worker03 发现 hosts/chrony 漂移；check 假失败已修 |
| delegate_to | 某一步委托给另一台主机 | teacher / worker03 |
| 动态 inventory | 从 API 生成主机清单 | inventory_k8s.py 3 cp + 3 worker |
| roles | tasks/defaults/handlers 打包复用 | roles/preflight |
| 何时不用 Ansible | 大规模/频繁重建转镜像 | 6 节点合适；1000 节点需分批 |
| Terraform state | 远端+锁+加密 | 当前本地 state，无 backend（反面） |
| plan/drift | plan 带 refresh 才检测 drift | `-refresh=false` 无变化；真实 plan 3 台漂移 |
| GitOps | Git 单一事实源 + selfHeal | ArgoCD 31 App；Flux 未部署 |

## 二、本环境纠偏（面试别背绝对话）

### 1. “Rocky 9 把 network-scripts 全删了”

不准确。本机：

```text
$ rpm -q network-scripts
未安装软件包 network-scripts

$ ls /etc/sysconfig/network-scripts
ifcfg-ens18  ifcfg-eth0  ifcfg-eth1  readme-ifcfg-rh.txt
```

- `network-scripts` 包确实不再默认安装；
- 但 ifcfg 文件仍可由 NetworkManager 读取/兼容；
- 真正变化是 **NetworkManager + nmcli + nftables + chrony + dnf + cgroup v2**。

### 2. “Rocky 默认 SELinux enforcing”

本机 m01：

```text
$ grep '^SELINUX=' /etc/selinux/config
SELINUX=disabled

$ getenforce
Disabled
```

Rocky/RHEL 的**默认目标**是 enforcing，但实验室/镜像可能关闭。
面试要说“机制”，不要断言“所有 Rocky 都 enforcing”。

### 3. “Ubuntu 24.04 没有 distutils”

准确说法：**Python 3.12 从标准库移除了 distutils**，但 `python3-setuptools` 可能提供
`setuptools._distutils` 兼容层。

本机：

```text
$ python3 -c "import distutils; print(distutils.__file__)"
/usr/lib/python3/dist-packages/setuptools/_distutils/__init__.py

$ python3 -S -c "import distutils"
ModuleNotFoundError: No module named 'distutils'
```

所以：

- 裸 Python、无 setuptools：会失败；
- 装了 setuptools：可能还能 import；
- 新代码应改用 `setuptools`/`packaging`，不要依赖 stdlib distutils。

### 4. “epoll 完全不拷贝”

不准确。`epoll_wait` 仍会把**就绪事件**拷贝到用户态；它避免的是：
- 每次遍历整个 fd 集合（O(n)）；
- 把整个 fd 集合反复拷贝。

准确说：**红黑树管理 fd，就绪链表回调，只返回就绪事件**。

### 5. “OOMKilled 和 Evicted 是一回事”

不是：

- **OOMKilled**：容器 cgroup 内存超 `memory.max`，内核 OOM killer 杀进程，Pod 重启；
- **Evicted**：节点 Memory/Disk/PIDPressure，kubelet 驱逐 Pod，Pod 可能被重建到别的节点。

本环境当前没有 OOM/Evicted 历史；6 节点压力条件全 `False`。机制仍要会。

### 6. “配置了 topologySpread 就一定打散”

本集群 Tempo 用 `topology.kubernetes.io/zone`，但节点只有 `zone=test-a/test-b`，
没有标准 `topology.kubernetes.io/zone` label，所以 zone 打散实际是 no-op。

### 7. “有 PDB 就安全”

`pg16-ceph-primary` minAvailable=1，当前 allowed disruptions=0，drain 主库节点会被阻止；
Kafka PDB `minAvailable=0` 基本没有保护。PDB 要同时看 `ALLOWED DISRUPTIONS`。

### 8. “装了 Gateway API CRD 就是用了 Gateway API”

本集群只有 6 个 Gateway API CRD，**0 个 GatewayClass/Gateway/HTTPRoute**；
实际入口仍是 Traefik IngressRoute。

### 9. “Velero/KEDA/Kured/NPD 是标配”

本环境 **都没有部署**；节点自愈/重启编排/备份迁移不能假设有这些组件。

### 10. “有 etcd 备份就等于有容灾”

备份成功 ≠ 能恢复。本环境验证了每小时快照 133MB/8234 keys/上传 S3，
但**没有做生产恢复演练**。

### 11. “Ansible 一定幂等”

只有用幂等模块才幂等；`shell`/`command` 默认不幂等，必须配 `creates/removes/changed_when`。

### 12. “`terraform plan -refresh=false` 能检测 drift”

不能。它只看 state；带 refresh 的 `terraform plan` 才发现 3 台 VM `started=false→true`。

### 13. “GitOps 能管一切”

数据库 migration、一次性 bootstrap、明文 Secret 不适合直接塞 GitOps；
需要 Job/Operator/SealedSecret 等配合。

## 三、详细章节

| 文件 | 内容 |
|---|---|
| [01-linux.md](01-linux.md) | 硬/软链接、僵尸、load、free、df/du、ulimit、cgroup、Ubuntu/Rocky、SELinux/AppArmor、epoll |
| [02-network.md](02-network.md) | TIME_WAIT/CLOSE_WAIT、三次握手、refused/timeout/reset |
| [03-cloud-native.md](03-cloud-native.md) | OOMKilled vs Evicted、tini、cgroup 与容器 |
| [04-storage.md](04-storage.md) | 分区、LVM、RAID、文件系统、fstab、NFS、Ceph、云盘、CSI、SMART |
| [05-kubernetes.md](05-kubernetes.md) | 控制面/节点/资源/QoS/PDB/探针/升级/备份/扩展/多租户/进阶 |
| [06-virtualization-boot.md](06-virtualization-boot.md) | KVM/QEMU/virtio/virsh、云 vs 物理、IMDSv2、cloud-init、Packer、云镜像 vs ISO、UEFI/PXE/initramfs |
| [07-iac-gitops.md](07-iac-gitops.md) | Ansible 幂等/handlers/check/delegate/inventory/roles、Terraform state/plan/drift/import、GitOps、演进 |
| [00-verification-matrix.md](00-verification-matrix.md) | 60+ 条断言的验证状态（✅/⚠️/❌/📚） |
| [labs/README.md](labs/README.md) | 复现实验 |
| [assets/evidence/](assets/evidence/README.md) | 机器输出 |

## 四、怎么用

1. 先看“一页速查”，能一句话说清；
2. 再看详细章节的“为什么”和“追问”；
3. 面试前跑一遍 [labs](labs/README.md) 的只读命令；
4. 不要把本环境的数字当通用结论，换机器要重新采集。

> 面试官要的不是“背答案”，而是你能从现象定位到内核/网络/运行时/编排层。
> 这一章的所有答案都能在本仓库找到证据。
