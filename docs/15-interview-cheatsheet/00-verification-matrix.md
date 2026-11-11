# 全部面试断言的验证矩阵

> 状态说明：
>
> - ✅ **实测**：本环境有直接命令输出；
> - ⚠️ **部分/纠偏**：结论成立但有前提，或本环境只能验证一部分；
> - ❌ **本环境不具备**：组件未部署/无对应硬件；
> - 📚 **仅原理**：无法在本环境安全复现，只保留通用结论。
>
> 证据根目录：
> [05 Linux](../05-linux/assets/evidence/README.md)、
> [06 Storage](../06-storage-ceph/assets/storage-basics/README.md)、
> [14 Containers](../14-containers/assets/evidence/README.md)、
> [01 K8s](../01-kubernetes-k3s/assets/interview-evidence/m01-evidence.txt)、
> [15 面试证据](assets/evidence/README.md)。

## 一、Linux / 进程 / 内存 / systemd

| 断言 | 状态 | 证据/说明 |
|---|---|---|
| 硬链接同 inode，软链接独立 inode | ✅ | 05 实验：inode 1070350 vs 1070351 |
| 僵尸进程 `kill -9` 无效，需父进程 wait | ✅ | 05 实验：`State: Z`，`PPid` |
| 负载高 CPU 低是 D 状态/IO 阻塞 | ⚠️ | PVE load 8.21/40 核；GitLab IO PSI 35.95；未持续制造 D |
| free 的 cache 可回收，看 available | ✅ | worker01 free 332Mi/available 5.9Gi |
| TIME_WAIT 主动关闭方，会自愈 | ✅ | worker01 TIME_WAIT 127 |
| CLOSE_WAIT 是应用没 close | ✅ | 实验制造 CLOSE_WAIT=1 |
| 三次握手 SYN/SYN-ACK/ACK | ✅ | tcpdump loopback |
| refused/timeout/reset 区别 | ✅ | 本机实测三种异常 |
| df/du 不一致常见 deleted open file | ✅ | 200MiB 删除文件，`lsof +L1` |
| 改 ulimit 不一定影响 systemd 服务 | ⚠️ | m01 soft 1024/hard 524288；systemd 524288 |
| cgroup v1 多层级，v2 统一 | ✅ | 所有主机 cgroup2fs |
| Ubuntu 24.04 distutils 从 stdlib 移除 | ⚠️ | Python 3.12.3；setuptools 提供 shim，`-S` 失败 |
| Rocky 9 用 NM/nft/chrony/dnf | ✅ | nmcli 1.52/nft 1.0.9/chrony 4.6.1 |
| Rocky 9 不再有 network-scripts | ⚠️ | 包未装但 ifcfg 文件仍在 |
| Rocky 默认 SELinux enforcing | ⚠️ | 本机 `SELINUX=disabled`，默认目标≠实际 |
| SELinux 标签 vs AppArmor 路径 | ✅ | m01 selinux、Ubuntu apparmor |
| 容器 PID1 需要 tini 处理信号/僵尸 | ✅ | frpc `NSpid: 2236 1`，无 tini |
| epoll 红黑树+就绪链表 | ✅ | nginx worker `anon_inode:[eventpoll]` |
| epoll “零拷贝” | ⚠️ | 仍拷贝就绪事件，避免整表遍历/拷贝 |

## 二、网络

| 断言 | 状态 | 证据 |
|---|---|---|
| TIME_WAIT 2MSL | ✅ | `ss` 127 个 TIME_WAIT；状态机 |
| CLOSE_WAIT 是代码问题 | ✅ | 实验 CLOSE_WAIT，未 close |
| 三次握手防历史 SYN/确认双工 | ✅ | tcpdump |
| refused=有 RST | ✅ | `ConnectionRefusedError` |
| timeout=无响应 | ✅ | `TimeoutError`（黑洞 IP） |
| reset=建立后 RST | ✅ | `ConnectionResetError`（SO_LINGER=0） |

## 三、存储 / 磁盘 / 文件系统

| 断言 | 状态 | 证据/说明 |
|---|---|---|
| GPT/MBR 区别、设备名会漂移 | ✅ | PVE GPT、m01 MBR、worker GPT；by-uuid/by-id |
| LVM PV→VG→LV | ✅ | PVE VG 930.51G，root 96G，pool 794.3G |
| LVM 在线扩缩容 | ⚠️ | 扩通常在线，缩通常离线且看 FS |
| thin pool 满拖死业务 | ⚠️ | pool 66.35%，VG 16G，autoextend 158.9G；不是绝对全 VG 只读 |
| RAID 0/1/5/6/10 | 📚 | PVE 单 NVMe，无 md RAID；冗余靠 Ceph |
| RAID5/6 write hole | 📚 | 无 RAID 环境，未复现 |
| XFS 不能缩，ext4 可离线缩 | ✅ | m01 XFS、worker/PVE ext4；无在线缩容 |
| noatime 提性能 | ⚠️ | 通用；本机 fstab 无显式 noatime |
| nobarrier 风险 | ⚠️ | 现代 ext4 基本忽略；`barrier=0` 才危险 |
| 外部盘必须 nofail | ⚠️ | 本机无外部 fstab 数据盘；原理 |
| noexec/nosuid/nodev 安全挂载 | 📚 | 本机无独立数据盘 |
| NFS hard/soft/timeo/retrans | ✅ | NFSv4.2 hard,timeo=600,retrans=2 |
| NFS intr 可中断 | ⚠️ | 现代内核基本忽略 |
| stale handle | 📚 | 未制造；通用 |
| Ceph PG/OSD 排障 | ✅ | HEALTH_OK，6 up/in，465 active+clean |
| 云盘 IOPS/突发积分/快照 | ❌/📚 | 本环境无云盘 |
| CSI + PV/PVC/SC | ✅ | rbd.csi.ceph.com，17 PV Bound |
| RWO=单节点不是单 Pod | ✅ | 17 PVC 全 RWO |
| local-path 节点绑定 | 📚 | 本环境无 local-path |
| SMART 看寿命/坏道 | ✅ | 0% used、0 media errors、7 unsafe shutdowns |
| dmesg medium error 是坏道先兆 | ✅ | 所有主机当前无命中，作为基线 |

## 四、Kubernetes

| 断言 | 状态 | 证据/说明 |
|---|---|---|
| apiserver 认证→授权→准入 | ✅ | `Node,RBAC` + NodeRestriction + webhooks |
| apiserver 唯一读写 etcd | ✅ | 静态 Pod args |
| etcd 对 fsync 敏感/2GB quota | ✅ | 3.6.6，2.1GB quota，WAL p99 1ms |
| etcd 低峰逐节点 defrag | 📚 | 未执行；DB 133MB/in-use 37MB，无 alarm |
| scheduler Filter→Score→Bind | ⚠️ | 事件 `Successfully assigned`；未抓 Filter/Score 日志 |
| controller-manager reconcile | ✅ | RS ownerRef、Operator 日志 |
| kubelet cgroup driver 一致 | ✅ | cgroupDriver=systemd，containerd 2.3.2 |
| CRI containerd/CRI-O | ✅ | containerd 2.3.2 |
| CNI 负责 Pod 网络/策略 | ✅ | Cilium 1.20.4，KPR=true，native |
| CSI 负责 PV | ✅ | rbd.csi.ceph.com，17 PV |
| NPD 上报 NodeCondition | ❌ | 未部署 |
| requests 调度/limits 运行时 | ✅ | QoS 统计、节点 allocated |
| QoS 三档驱逐顺序 | ✅ | 73 BestEffort/65 Burstable/0 Guaranteed |
| LimitRange/Quota | ✅ | compassio + 临时实验注入默认值 |
| 超卖比 | ⚠️ | m01 req/limit 24%/38% CPU；大量无 requests |
| topologySpread/反亲和 | ⚠️ | 29 个有约束；Tempo 用标准 zone label 但节点没有，实际 no-op |
| PDB 限制自愿中断 | ✅ | 11 PDB；CNPG primary allowed=0 |
| 探针三件套 | ✅ | live 51/ready 53/startup 10 |
| 优雅退出 preStop+SIGTERM+grace | ⚠️ | 只有 1 个 preStop；china-study-free sleep5+grace30 |
| 版本偏差 kubelet≤apiserver 3 minor | ✅ | 6 节点全 1.35.9 |
| cordon/drain | ✅ | worker03 dry-run 30+ Pod，未真正 cordon |
| 节点自愈 | ⚠️ | 6 节点 Ready，压力 False；未注入故障 |
| kured | ❌ | 未部署 |
| 证书轮换 | ✅ | leaf 326d/CA 9y，rotateCertificates=true |
| etcd snapshot save/restore | ⚠️ | snapshot 133MB/8234 keys/S3；未做恢复演练 |
| Velero | ❌ | 未部署 |
| CRD/Operator | ✅ | 146 CRD，Ceph/CNPG/Strimzi 等 |
| Admission Webhook failurePolicy=Fail | ✅ | 12 Validating/9 Mutating，多数 Fail |
| API Aggregator | ✅ | metrics.k8s.io + external.metrics True |
| 多租户隔离 | ⚠️ | 29 ns/23 NetworkPolicy；QL/LR 只有 compassio；PSA 4 ns |
| KEDA | ❌ | 未部署 |
| VPA/HPA | ⚠️ | HPA 3；VPA controller 有、VPA 对象 0 |
| Cilium eBPF | ✅ | 1.20.4，KPR=true，Hubble OK |
| Gateway API | ⚠️ | 6 CRD 已装，0 个 Gateway/HTTPRoute |

## 五、结论

- **能一句话说清**：先看 [README](README.md) 的两张速查表；
- **需要追问**：看 `01-linux.md` / `02-network.md` / `03-cloud-native.md` / `04-storage.md` / `05-kubernetes.md`；
- **需要证据**：看各章 `assets/evidence`；
- **需要纠偏**：看 ⚠️ 行，不要背绝对话。

> 本矩阵会随集群变化失效。换环境请重新采集，不要直接复用数字。
