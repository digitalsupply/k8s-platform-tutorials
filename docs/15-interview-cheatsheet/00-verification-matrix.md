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

## 五、虚拟化 / 云主机 / 引导

| 断言 | 状态 | 证据 |
|---|---|---|
| KVM 虚拟化 CPU，QEMU 模拟设备 | ✅ | QEMU 9.2.0、/dev/kvm、qm showcmd |
| virtio 是半虚拟化驱动 | ✅ | Guest virtio_net/scsi/balloon；Hyper-V hv_netvsc |
| virsh 是 libvirt CLI | ✅ | virsh/libvirtd 未安装；PVE 用 qm |
| 云主机看不到真实 SMART | ✅ | Guest QEMU HARDDISK/Virtual Disk；smartctl 无真实盘 |
| 云主机有 steal time | ✅ | vmstat st 列；当前 0，机制存在 |
| 云主机不能改物理网卡 | ✅ | ethtool 显示 virtio_net/hv_netvsc |
| IMDS 169.254.169.254 | ✅ | 所有 Guest curl 超时；无云元数据 |
| IMDSv2 防 SSRF | 📚 | 本环境无 IMDS，按 AWS 通用流程 |
| cloud-init 调试 | ✅ | status/analyze/log；201 首启 apt 121s |
| Packer 金镜像 | ⚠️ | Packer 1.16.2 + proxmox 1.2.4 已装；示例 validate 通过，未完整 build |
| 云镜像 vs ISO | ✅ | openEuler qcow2 + cloud-init；Ubuntu build.info/cloudimg-rootfs；ISO 仅安装介质 |
| UEFI/Secure Boot | ✅ | 9010 UEFI 无 SecureBoot；Hyper-V Gen2 Off；K8s Legacy |
| PXE/网络引导 | ⚠️ | Hyper-V UEFI 有 EFI Network 项；本环境无 PXE 服务 |
| initramfs 缺驱动会起不来 | ✅ | KVM virtio_scsi、Hyper-V hv_storvsc 均在 initramfs |

## 六、IaC / Terraform / Ansible / GitOps

| 断言 | 状态 | 证据 |
|---|---|---|
| Ansible 幂等 | ✅ | 第一次 changed=1，第二次 changed=0 |
| Ansible handlers | ✅ | 第一次触发，第二次不触发 |
| `--check --diff` | ✅ | worker03 发现 hosts/chrony 漂移，check 模式假失败已修 |
| delegate_to | ✅ | control node teacher / target worker03 |
| 动态 inventory | ✅ | inventory_k8s.py 生成 3 cp + 3 worker |
| roles 复用 | ✅ | roles/preflight 被 roles-demo 复用 |
| 大规模不适合 Ansible | 📚 | 6 节点合适；1000 节点需分批/转镜像 |
| Terraform state | ✅ | 3 台 VM 本地 state，无 backend/lock |
| plan 审查 | ✅ | 3 台 VM started false→true，未 apply |
| drift 检测 | ✅ | `-refresh=false` 无变化；带 refresh 发现 3 台漂移 |
| 模块化 | 📚 | 当前单模块；生产建议 modules/envs |
| import 存量资源 | 📚 | 文档命令；未 import 生产资源 |
| ArgoCD/Flux | ✅ | ArgoCD 31 App；Flux 未部署 |
| 单一事实源/selfHeal | ✅ | app-of-apps prune=false/selfHeal=true |
| PR 即审批/可审计 | ✅ | git log + ArgoCD tracking |
| 演进逻辑 | ✅ | 雪花→配置管理→不可变→GitOps，均有本环境证据 |

## 七、CI/CD / 镜像 / 发布 / 回滚

| 断言 | 状态 | 证据 |
|---|---|---|
| 流水线阶段化 | ✅ | clone→check-changes→双 build 并行→promote |
| build once | ✅ | 应用 tag 40 位 SHA，GitOps 只改 newTag |
| 构建缓存 | ✅ | 源码不变全 CACHED；只改 src 仅 src 层重建 |
| COPY 依赖清单单独层 | ✅ | buildctl `#5 CACHED` / `#6 DONE` |
| 多阶段减小镜像 | ✅ | frontend 25.4MB/11 层，history 无 node_modules |
| 应用 tag 用 SHA | ✅ | compassio/deeptutor 全 SHA40 |
| 禁止 latest | ⚠️ | 基础镜像仍有 `latest`；openwebui 有 `manual-test1` |
| tag 不可变 | ❌ | Harbor immutable rules = 0 |
| 滚动发布 | ✅ | 集群 54 个 25%/25%；lab 4 秒完成 |
| 蓝绿 | ✅ | lab selector blue→green，响应变化 |
| 金丝雀 | ⚠️ | Argo Rollouts 未装；Traefik 权重可分流 |
| Feature Flag | ❌ | 无 flag 系统；ConfigMap 仅静态开关 |
| 1 分钟回滚 | ✅/⚠️ | rollout undo 4 秒；不含定位/审批/DB |
| expand-contract | ✅ | PG16.15 实测每步 2–3ms；独立库已清理 |
| Harbor 扫描/保留 | ⚠️ | compassio/deeptutor 开扫描；openwebui 关；保留 5 个 |
| 依赖锁定 | ⚠️ | 有 lock/registry 参数；部分基础镜像浮动 tag |
| docker buildx | ✅ | 0.30.1 + remote driver 连 BuildKit 0.20.2 |
| buildx 拉 Harbor 基础镜像 | ❌ | daemon 侧 CA 仍 x509（client 与 daemon 信任链不同） |
| SBOM/provenance | 📚 | buildx 支持；本环境未启用 |

## 八、可观测性

| 断言 | 状态 | 证据 |
|---|---|---|
| 指标四类型 | ✅ | Counter/Gauge/Histogram/Summary；`compassio_users_total` 是 Gauge |
| 基数决定内存 | ✅ | 260,359 series，RSS 1.57GiB/4GiB，约 6KB/series |
| `user_id` 不能进 label | ✅ | 业务只用 role（3 series）；数学上 100k 用户会到千万级 |
| 基数 OOM 可复现 | ✅ | 15 万 series + 128Mi → OOMKilled exit 137，重启 3 次 |
| 高基数 label 识别 | ✅ | `id` 1306、`uid` 695、`path` 804 series |
| series churn | ✅ | 24h +31,003（+13.5%）；创建 7.2k/h、删除 0.66k/h |
| `rate()` 需 2 样本 | ✅ | `[10s]/[30s]` 0 series；`[1m]` 6 series |
| `irate` vs `rate` | ✅ | idle CPU 0.856 vs 0.877 |
| 先 `sum by` 再聚合 | ✅ | `sum by (verb)` 9 条；全局 28.6/s |
| `histogram_quantile` | ✅ | 不聚合 188 条/122 NaN；`sum by (le)` 后 p99=0.0229s |
| bucket 选择 | ✅ | 10 个桶（0.005–60s），0.1–1s 跨度过大 |
| 黑盒监控 | ❌ | 0 Probe、无 blackbox exporter |
| 白盒监控 | ✅ | 52 job，27 ServiceMonitor + 16 PodMonitor |
| 四层监控 | ✅ | 基础设施/中间件/应用/业务均有实际指标 |
| 业务指标 | ✅ | `compassio_users_total` 887 学生、LLM 27.6k/24h、DeepTutor 轮次 |
| 日志结构化 | ⚠️ | Alloy `stage.json=0`、`sampling=0` |
| 日志量/保留 | ✅ | 624MB/24h、214 万行、5d |
| 容器日志轮转 | ✅ | kubelet 默认 10Mi×5；14 个轮转文件、最大约 10.5MB |
| 宿主机日志轮转 | ✅ | logrotate weekly×4；journald 20.4M |
| Trace context 传播 | 📚 | W3C `traceparent`；OTel Collector 0.145.0 |
| 头部/尾部采样 | ❌ | Collector 仅 batch，无采样 |
| Trace 覆盖 | ⚠️ | Tempo 6.8 万 span/天；spanmetrics 0 series |
| 长期存储 | ❌ | Thanos/VM/Mimir 均未部署，Prometheus 本地 15d |
| 成本治理 | ✅ | 指标 17.9GB/15d，日志 0.6GB/天；每 series 成本已量化 |
| kube-proxy 残留 | ✅ | `kubeProxy.enabled=false`；Service/SM/Rule/CM 已删；ArgoCD Synced |

## 九、三个「不可逆」

| 断言 | 状态 | 证据 |
|---|---|---|
| `rm` 无 dry-run | ✅ | `rm --dry-run` 报 `unrecognized option` |
| `rsync --dry-run` 可预览删除 | ✅ | 列出 deleting old/junk.txt 等，未删除 |
| `mkfs -N` / `wipefs --no-act` | ✅ | 只打印参数/签名，不写盘 |
| `dd` 无 dry-run | ✅ | `dd --help` 无 dry-run；安全实验只写文件 |
| `delete ns --dry-run` | ✅ | client/server 后对象仍 Active；server 走 admission |
| `DROP TABLE` 可回滚 | ✅ | `BEGIN; DROP TABLE; ROLLBACK` 后行数仍 1 |
| `DROP DATABASE` 无事务 | ✅ | 报 `cannot run inside a transaction block` |
| XFS 不能 shrink | ✅ | `xfs_growfs -D` 返回 Invalid argument，blocks 不变 |
| LVM 缩容顺序 | ✅ | `lvreduce --test` 警告；ext4 先 resize2fs 后 lvreduce，sha256 不变 |
| etcd 恢复回退全集群 | ✅ | 快照 revision 60,243,742 vs 当前 60,290,176，约 57 分钟 |
| 证书不可撤回 | ✅/📚 | 90d 自签、无 CSR/CRL；按短期轮换设计 |
| CIDR 不可逆 | ✅ | pod 10.244/16、svc 10.96/12、节点 10.0.0/24、VIP 10.0.0.168 |
| 分区方案不可逆 | ✅ | PVE GPT：bios_grub + ESP + LVM；pve/data 794G |
| 命名规范不可逆 | 📚 | DNS/label/ArgoCD 都依赖名字；改名等于迁移 |
| 云区域不可逆 | 📚 | on-prem 不涉及；合规/延迟优先 |

## 十、中间件 OS 层

| 断言 | 状态 | 证据 |
|---|---|---|
| THP 差异 | ✅ | m01 `always`；worker `madvise` |
| overcommit/swappiness | ✅ | 所有节点 overcommit=1、swappiness=60 |
| somaxconn/backlog | ✅ | somaxconn 4096；Redis tcp-backlog 511 |
| Redis maxmemory/policy | ✅ | 384M/allkeys-lru、400M/noeviction、ArgoCD 0 无上限 |
| Redis fork COW | ✅ | RDB 1.5MB、AOF 2.8MB |
| MySQL 未部署 | ✅ | K8s/PVE 均无 mysqld；用 PG 16.15 对照 |
| MySQL O_DIRECT/fsync 概念 | 📚 | 无 MySQL 实测；PG fsync=on、fdatasync |
| PG 连接承载 | ✅ | max_connections=100，当前 13 |
| Kafka 单 broker/RF=1 | ✅ | Strimzi 4.1.2，1 replica |
| Kafka 堆/Xmx | ✅ | 只有 `-Xms128M`，MaxHeap 1.99G，无 memory limit |
| Kafka fd | ✅ | soft 1024，低于 100k 建议 |
| Kafka 磁盘/page cache | ✅ | 20G PVC，248M 数据；节点 buff/cache 3.7G |
| Nginx worker×connections | ✅ | 6×1024；Harbor 2×3096 |
| Nginx worker auto vs limit | ✅ | 0.1 CPU limit 起 6 worker |
| Nginx client_max_body_size | ✅ | Harbor 为 0（无上限） |
| Nginx fd | ✅ | soft 1024，worker_rlimit_nofile 未设 |
| Java 容器感知 | ✅ | JDK 21 检测 cgroups v2 |
| MaxRAMPercentage | ✅ | 512Mi：默认 128M，75%→384M |
| CPU limit/GC/JIT | ✅ | 500m：GC=0、CICompilerCount=2、nproc=6 |
| metaspace/direct | ✅ | Kafka MaxMetaspace unlimited、MaxDirect 0 |
| 连接池公式 | ✅ | 10×20 > 100 会打满 |

## 十一、SRE / SLO / 事故

| 断言 | 状态 | 证据 |
|---|---|---|
| SLI 排除健康检查 | ✅ | 总请求 p99 21ms，业务 p99 219ms；健康占 99.93% |
| 业务低流量 | ✅ | 1,948 请求/7d，约 0.0032 req/s |
| 99.9% budget | ✅ | 1.95 错误/7d、8.35/30d；当前 0 个 5xx |
| 99.9% 现实性 | ✅ | backend/Redis 单副本，CNPG 单区域 |
| Burn rate 公式 | ✅ | `error_ratio/(1-SLO)`；当前 burn=0 |
| 多窗口 burn | ⚠️ | 只有 apiserver 4 条；业务 0 条 |
| 告警规则画像 | ✅ | 251 条；critical 82；runbook 137/251 |
| 长期 firing | ✅ | 5 条非 Watchdog；最长 50.9h |
| `KubeProxyDown` 误报 | ✅ | `absent(up{job="kube-proxy"})`；Cilium KPR 无此 job |
| Ceph 告警误报 | ✅ | `ceph_health_status`/`ceph_mon_quorum_status` 0 series |
| Alertmanager 同根因 | ✅ | 两条发送失败告警各发一次；inhibit 只匹配同名 |
| Alertmanager 配置 | ✅ | group_by alertname/ns/sev；wait 30s；repeat 12h |
| 无 for 规则 | ✅ | 10 条（含 Watchdog/InfoInhibitor） |
| MTTD 案例 | ✅ | 重启告警 FIRING 16h~1.5d |
| MTTR 案例 | ✅ | 人工处置约 2h05m |
| SEV/IC 模板 | 📚 | 已补模板；环境无正式 on-call/status page |
| Postmortem 模板 | ✅ | 时间线/影响/5 Whys/行动项模板 |
| 变更相关性 | ✅ | 7 轮中 3 轮直接触发故障（43%） |
| Blackbox/Probe | ❌ | 0 Probe，无 blackbox |
| 业务 SLO | ❌ | 无正式 SLO/burn 规则 |

## 十二、Linux / K8s / 云原生安全

| 断言 | 状态 | 证据 |
|---|---|---|
| sudo 最小权限 | ❌ | m01 `cloud-user NOPASSWD:ALL` |
| capabilities 裁剪 | ⚠️ | 99/163 drop ALL；10 privileged |
| no_new_privs | ⚠️ | 93/163 allowPrivilegeEscalation=false；backend NNP=0 |
| SSH 加固 | ❌ | root yes、密码 yes、agent forwarding yes |
| SSH CA | ❌ | 无 `TrustedUserCAKeys`；每节点 2 个 authorized_keys |
| auditd | ❌ | m01 active 0 规则；Ubuntu inactive |
| AIDE/Falco | ❌ | 均未安装/部署 |
| PAM faillock/pwquality | ❌ | faillock 无；Ubuntu pwquality 无 |
| SELinux/AppArmor | ⚠️ | SELinux disabled；AppArmor 22 profiles；Pod 注解 0 |
| 内核硬化 | ⚠️ | m01 dmesg_restrict=0/ptrace_scope=0 |
| 安全补丁 | ❌ | m01 245 security（4 critical）；Ubuntu 51 |
| livepatch/kpatch | ❌ | 未安装 |
| PSA 覆盖 | ❌ | 25 ns 无 label；1 restricted/1 baseline/2 privileged |
| securityContext | ⚠️ | 46 runAsNonRoot / 89 readOnlyRoot / 93 NNP / 99 drop ALL |
| seccomp | ❌ | 123 none / 39 RuntimeDefault / 1 Unconfined |
| privileged/hostNetwork/hostPath | ❌ | 10 / 35 / 41 |
| apiserver audit | ❌ | 无 audit policy |
| etcd 静态加密 | ❌ | 无 encryption provider |
| Secret 外部化 | ⚠️ | 128 Secret；Sealed Secrets；无 Vault/ESO |
| RBAC/SA token | ❌ | 3 cluster-admin；125/138 自动挂 SA token |
| NetworkPolicy | ❌ | 23 条；仅 1 个全选隔离 |
| mTLS/零信任 | ❌ | Cilium mesh-auth=false；无 mesh/SPIRE |
| 镜像扫描 | ⚠️ | compassio/deeptutor 开；openwebui 关 |
| 漏洞门禁 | ❌ | prevent_vul 全无；deeptutor 1740 漏洞 |
| 镜像签名/SBOM | ❌ | cosign/notation/syft/trivy 均无 |
| CIS/OpenSCAP | ❌ | 未安装 oscap/lynis |
| 等保/国密 | 📚 | 有要求/方法，环境未实现 |

## 十三、日志体系

| 断言 | 状态 | 证据 |
|---|---|---|
| `copytruncate` 不中断但可能丢日志 | ✅ | 真机 inode 不变、复制/截断窗口 |
| `create` 需 HUP 重开 | ✅ | 旧 inode 被 rename；nginx USR1/mariadb -1 |
| logrotate `su` | ✅ | Ubuntu `su root adm`；Ceph `su root ceph` |
| journald 持久化 | ❌ | `/var/log/journal` 不存在 |
| journald 容量控制 | ❌ | 无 `Storage/SystemMaxUse` |
| json-file max-size | ⚠️ | Harbor 用 syslog；无 daemon.json 全局限制 |
| kubelet 日志限制 | ⚠️ | 未显式设置；默认 10Mi×5 |
| 容器日志轮转 | ✅ | worker 17 个轮转文件，最大约 10.5MB |
| DaemonSet vs Sidecar | ✅ | Alloy DaemonSet 6 Pod；无应用 sidecar |
| 结构化 JSON | ⚠️ | backend JSON；frontend/redis 文本 |
| 日志采样 | ❌ | Alloy `sampling=0` |
| 采集侧脱敏 | ❌ | Alloy `stage.replace/regex=0` |
| Loki 标签基数 | ⚠️ | 75 streams；filename 102/pod 97 |
| Loki 保留 | ✅ | 5d / 120h |
| 日志成本量化 | ✅ | 0.6GB/天、2.1M 行/天、5d ≈ 2.87GiB |
| trace_id 关联 | ⚠️ | 日志有 trace_id，但未提取为 metadata |

## 十四、网络故障排查

| 断言 | 状态 | 证据 |
|---|---|---|
| 节点网络/默认网关 | ✅ | eth0 10.0.0.124/24，default 10.0.0.1 |
| Pod/Service CIDR | ✅ | 10.244/16、10.96/12、VIP 10.0.0.252 |
| Cilium native/KPR | ✅ | routing-mode=native、KPR=true、无 kube-proxy DS |
| L2 宣告 | ✅ | CiliumL2AnnouncementPolicy/traefik-l2 |
| Traefik LB | ✅ | 10.0.0.252，externalTrafficPolicy=Cluster |
| CoreDNS | ✅ | 10.96.0.10，2 副本 |
| Pod ndots | ✅ | `ndots:5` + 3 个 search |
| somaxconn | ✅ | 4096 |
| syn backlog | ⚠️ | 512，低于 8192 建议 |
| syncookies | ✅ | 1 |
| TIME_WAIT | ✅ | 185，正常 |
| CLOSE_WAIT | ⚠️ | 1，需观察 |
| ListenOverflows | ✅ | 0 |
| softnet drop | ✅ | 0 |
| conntrack | ✅ | 953/262144 |
| keepalive | ❌ | 7200，大于典型 LB idle |
| 端口范围 | ⚠️ | 28,232 个，可能耗尽 |
| tcp_rmem/rmem_max | ⚠️ | max 6MB vs 208KB，不匹配 |
| MTU | ✅ | native 1500，无封装 |
| DNS 5s 三因 | ✅ | ndots/conntrack/CoreDNS |
| 502/504/499 | ✅ | 超时层级/上游断/客户端断 |
| 容量公式 | ✅ | BDP/PPS/端口/conntrack |

## 十五、结论

- **能一句话说清**：先看 [README](README.md) 的两张速查表；
- **需要追问**：看 `01-linux.md` / `02-network.md` / `03-cloud-native.md` / `04-storage.md` / `05-kubernetes.md`；
- **需要证据**：看各章 `assets/evidence`；
- **需要纠偏**：看 ⚠️ 行，不要背绝对话。

> 本矩阵会随集群变化失效。换环境请重新采集，不要直接复用数字。
