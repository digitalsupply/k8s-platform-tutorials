# G6 · 存储（06-storage-ceph）与 PVE（12-proxmox-pve）审计发现

审计范围：`docs/06-storage-ceph/`、`docs/12-proxmox-pve/` 全部 Markdown（含 `notes/`、`assets/`、`iac/`）。
核对基准：[`../assets/ground-truth.md`](../assets/ground-truth.md) + 本次只读实测（`ceph -s` / `ceph versions` / `ceph df` / `ceph osd df tree` / `kubectl get sc,pv,csidriver,ds,deploy` / CRD schema / `sysctl` / 仓库内 `assets/pve-state`）。未对集群与 PVE 做任何写操作。

---

### [严重度 高] Ceph 被写成 20.2.0 Tentacle，实际是 18.2.8 reef

- 位置: docs/06-storage-ceph/notes/ceph-csi-upgrade-to-operator-2026-11-09.md:5
- 原文: 「**Ceph**：外部 Ceph **20.2.0 Tentacle**（mon: `10.0.0.31/41/51:6789`）」
- 问题: 同一集群在 06/README.md:9（Reef `18.2.8`）、ceph-rbd-released-pv-audit-20261005.md:5、ceph-s3-rbd-client-setup-20261006.md:299 都写 18.2.8；这篇 11-09 的升级记录却写成 20.2.0 Tentacle（比 reef 晚两个大版本），属于事实漂移，且会让读者按 Tentacle 的特性/命令去排障。
- 证据/正确说法: `ceph versions` 实测 16 个守护进程全部为 `ceph version 18.2.8 (efac5a5...) reef (stable)`（mon 3 / mgr 2 / osd 6 / mds 3 / rgw 2）；`ceph -s` 显示 3 mon、6 osd、15 pools/465 pgs。应写 **18.2.8 reef**。

---

### [严重度 高] 恢复演练的 YAML 用了不存在的 `spec.recovery` 字段，且缺 externalClusters

- 位置: docs/06-storage-ceph/notes/ceph-rbd-released-pg-backup-implementation-20261005.md:595-611
- 原文: 「spec: / instances: 1 / storage: { size: 10Gi } / recovery: / source: pg16-ceph / recoveryTarget: / targetTime: "2026-10-05 14:00:00+08"」
- 问题: CloudNativePG 的恢复入口在 `spec.bootstrap.recovery`，`spec` 下没有 `recovery` 字段；该文档自己在上文（步骤 5，第 205 行）就演示过 API server 的 strict decoding 会直接拒绝未知字段，所以这段「CNPG 原生恢复（推荐，生产使用）」照抄会 apply 失败。另外 `recovery.source` 必须指向 `spec.externalClusters[].name`，只写 `source: pg16-ceph` 而不定义 externalClusters 也没有可用数据源。
- 证据/正确说法: `kubectl get crd clusters.postgresql.cnpg.io` 的 schema 中 `spec` 键为 affinity/backup/bootstrap/.../storage/superuserSecret/...，**无 `recovery`**；`spec.bootstrap` 键为 `initdb / pg_basebackup / recovery`。同仓库 cnpg-operator-how-it-works-2026-11-09.md:757-769 给出的正确形态是 `bootstrap.recovery.source` + `externalClusters[].plugin(barmanObjectName/serverName)`，两篇文档对同一操作给出的写法互相冲突。

---

### [严重度 高] 把 CNI 写成 Calico（实际是 Cilium），并据此给出跑不通的排障命令

- 位置: docs/06-storage-ceph/notes/cnpg-upgrade-postmortem-2026-11-08.md:103、338、695-700（另见 ceph-csi-restart-analysis.md:216、ceph-disk-optimization-2026-11-05.md:616）
- 原文: 「m01 是双网卡：eth0=10.0.0.61（管理网）、eth1=172.16.1.61（**Calico BGP 网**）」；「`quay.io/calico/node:v3.32.2` 该镜像已由 **calico-node DaemonSet** 拉取到所有节点」；「for p in $(kubectl -n kube-system get pods -l **k8s-app=calico-node** -o name); do ... kubectl ... exec $p -c **calico-node** -- ...」
- 问题: 本集群 CNI 是 Cilium 1.20.4、已移除 kube-proxy，没有 calico-node DaemonSet，也没有 calico/node 镜像。附录 B 的「批量查 rp_filter」命令会返回空列表（不是报错，静默什么都不做），3.10 节推荐的诊断镜像也拉不到；§4.2 的根因叙述把 eth1 说成 Calico BGP 网同样与事实不符。restart-analysis:216 的「Calico 6Running」、disk-optimization:616 的「清理 m01 上 Unknown 的 calico/alloy Pod」是同一处命名错误。
- 证据/正确说法: `kubectl get ds -A` 只有 `kube-system/cilium 6/6`；节点 `/etc/cni/net.d/05-cilium.conflist`；`cilium-config` 中 kube-proxy-replacement=true。查 rp_filter 应 `kubectl -n kube-system get pods -l k8s-app=cilium -o name` + `-c cilium-agent`，诊断镜像用节点上真实存在的 `quay.io/cilium/cilium:v1.20.4`。

---

### [严重度 中] PV 总数写 18，实测 17（同篇文档内部也自相矛盾）

- 位置: docs/06-storage-ceph/README.md:273；docs/06-storage-ceph/notes/pv-cleanup-report.md:6、154、190、326；docs/06-storage-ceph/notes/minio-vs-ceph-rgw-analysis.md:167
- 原文: 「本集群最终删除 **10 个失效 PV（95Gi）**，集群剩余 **18 个 PV** 全部 Bound。」「清理后 PV 总数 | **18，全部 Bound**」「`kubectl get pv --no-headers | wc -l   # 期望输出 18`」「18 个 PVC：」
- 问题: 实测 17 个 PV（全部 Bound），06/README.md:305 与 10-storage-basics.md:15、321 以及 assets/csi-pv-pvc.txt 也都是 17。清理前总数因此应为 27（17 Bound + 10 Released），而 pv-cleanup-report.md:24-27、324 写「28 个 PV 总计 / 18 Bound」。数字被系统性多算 1，读者按 18 去核对会误判少了一个卷。
- 证据/正确说法: `kubectl get pv --no-headers | wc -l` → 17，`kubectl get pv` 全部 Bound；`kubectl get pvc -A` 亦为 17。应统一为 17（清理后）/27（清理前）。

---

### [严重度 中] 同一套「Released PV 清理」流程给出相反顺序，且「会再生产僵尸镜像」的说法不成立

- 位置: docs/06-storage-ceph/README.md:139-140；docs/06-storage-ceph/notes/ceph-rbd-released-pv-audit-20261005.md:322；docs/06-storage-ceph/notes/pv-cleanup-report.md:144-150、229-247
- 原文: README「先删 PV，再删 Ceph RBD image。顺序反了会泄漏。」；审计「**必须先删镜像、再删 PV**；若只删 PV，就会再产出 7 个新的僵尸镜像」
- 问题: 三篇文档对同一破坏性操作给出互相冲突的顺序，其中 pv-cleanup-report 实际执行的是「先 `kubectl delete pv`（10 个，--wait=false），底层镜像保留待第 7 节再删」。另外「只删 PV 会再产出 7 个新僵尸镜像」表述不准确：镜像本来就在，删 PV 只是丢失 PV→image 的映射，不会新建镜像；真正的风险是无法再自动对账。这份 runbook 是运维直接照做的对象，顺序描述必须唯一。
- 证据/正确说法: `Retain` 下 `kubectl delete pv` 不会触发 CSI DeleteVolume（代码事实，pv-cleanup-report:144-145 自己也这么写）。可行且可审计的顺序只有一种表述：先导出 PV→`volumeAttributes.imageName` 对照表 → 确认 `watchers: none`、无快照 → 删 PV 对象（或先 `rbd trash mv`）→ 再按对照表删/清空 trash 中的镜像；无论先后，都必须保留映射表。

---

### [严重度 中] 拿一个已被撤销的 CVE 编号给 `testbucket` 定性

- 位置: docs/06-storage-ceph/notes/minio-vs-ceph-rgw-analysis.md:222-224
- 原文: 「Ceph 官方安全公告 **CVE-2024-9331**：Ceph 在特定配置下会自动创建名为 `testbucket` 的 bucket，攻击者可读取任意 bucket 数据。」
- 问题: CVE-2024-9331 已被 CNA 撤销（未使用该编号），不是 Ceph 的漏洞；把它当作「testbucket 的已知特征」会让读者按一个不存在的公告去做安全处置，也掩盖了 testbucket 更常见的来源（s3-tests / 手工建桶）。
- 证据/正确说法: CVE 官方记录（cve.org）显示 Assigner=Forescout、`Rejected Reason: This CVE ID was unused by the CNA`，NVD 亦为 Not Found；Ceph 官方 CVE 列表中没有该编号。正确做法：删掉这个编号，只说「`testbucket` 是测试遗留桶，确认无对象后 `radosgw-admin bucket rm --bucket=testbucket --purge-objects`」，并按 RGW 用户 caps 做权限收敛。

---

### [严重度 中] `radosgw-admin caps add` 的用法错误，并据此得出「子命令不存在」的结论

- 位置: docs/06-storage-ceph/notes/ceph-rbd-released-pg-backup-implementation-20261005.md:175、182
- 原文: 「radosgw-admin caps add --uid=pg-backup --bucket=pg-backups "read,write,delete"」；「`caps add` 也报 `Command not found`」
- 问题: `caps add` 是 radosgw-admin 的真实子命令（不是缺失），但它没有 `--bucket` 参数，cap 也不是 `"read,write,delete"` 这种写法——RGW 的 caps 是 `<scope>=<perm>` 形式（如 `buckets=read,write`）。照这条命令执行只会得到参数错误，文档却把它记成「版本不支持」，从而放弃了最小权限授权。
- 证据/正确说法: `radosgw-admin caps add`（本机 ceph 17.2.8 客户端）会被解析为合法命令并提示缺少 uid；正确写法为 `radosgw-admin caps add --uid=pg-backup --caps="buckets=read,write"`。若只想限制单桶，应使用 bucket policy（S3 `PutBucketPolicy`）而不是 user caps，因为 caps 是全局 scope 粒度。

---

### [严重度 中] PE 大小写成 64M，导致「64M × 4096 = 16G」算式自相矛盾

- 位置: docs/12-proxmox-pve/notes/pve-vg-thinpool-analysis-2026-11-06.md:45
- 原文: 「VG 剩余：64M × 4096 = 16G。」
- 问题: 同一文档第 40 行给的 `vg_extent_size` 是 `4.00m`，第 41 行是 238210 个 PE；按 64MiB 计算 4096 个 extent 是 256 GiB，与 16 GiB 相差 16 倍。这个数字被用来支撑「VG 只剩 16G，autoextend 必然失败」的核心结论，算式写错会直接削弱结论可信度。
- 证据/正确说法: `vgs` 实测 `Ext 4.00m / #Ext 238210 / Free 4096`（assets/pve-state/lvm-report.txt），4096 × 4 MiB = 16 GiB；930.51 GiB / 4 MiB = 238210.5 也自洽。应改为「4M × 4096 = 16G」。

---

### [严重度 中] 断言 PG 与 Tempo 用的「不是同一个 Ceph」，且交叉验证表未随诊断反转更新

- 位置: docs/06-storage-ceph/notes/pg-s3-incident-report.md:235、238
- 原文: 「是否同一 Ceph | 否。PG 用 `ceph-rbd-sc`（clusterID `594e535e-…`，pool `k8s-rbd`）；tempo3 用 RGW `10.0.0.31:7480`」；「tempo3 是**客户端编码错误**」
- 问题: RBD 与 RGW 是同一 Ceph 集群的两种接口，不是两套存储——同目录 minio-vs-ceph-rgw-analysis.md:120-121、208-209 明确写「数据链路：S3 API → radosgw → `my-zone.rgw.buckets.data` → OSD」「与 K8s PVC 共享 180 GiB」。这里为了让「两个问题无因果关系」成立，把存储层说成两套，反而掩盖了真实的相关性（同盘、同 OSD、同容量池）。第 238 行「客户端编码错误」也与本文档开头（第 114-118 行）已推翻该结论、定论为 RGW 服务端缺陷相矛盾。
- 证据/正确说法: `ceph df` 同时列出 `k8s-rbd`（RBD）与 `my-zone.rgw.buckets.data`（RGW）在同一个 cluster id `594e535e-d82c-11f0-afa7-bc24112b746f` 下；`ceph -s` 的 rgw 段即该集群的 2 个 radosgw。正确表述：同一 Ceph、不同接口，容量与故障域共享。

---

### [严重度 中] 把「删除主库 Pod」称为 switchover（那是 failover）

- 位置: docs/12-proxmox-pve/iac/05-batch-ops.md:86-91
- 原文: 「有 CNPG 主库的节点，先做 switchover：… `kubectl -n cnpg-system delete pod <primary-pod>` # 等 primary 切换、2/2 ready」
- 问题: 删 Pod 触发的是一次非计划 failover（无切换目标、可能有未复制事务丢失），CNPG 的 switchover 是显式指定目标实例的受控切换。把它写成「先做 switchover」会让维护窗口里的人以为做的是平滑切换。同仓库 compassio-pg-redis-ops-plan.md:428 恰恰警告「不要直接 `kubectl delete pod` 主库来『测试切换』，那会走非计划 failover」，两处指导相反。
- 证据/正确说法: 受控切换用 `kubectl cnpg promote <cluster> <target-instance>`，或给目标 Pod 打 `cnpg.io/switchover` 注解；删 Pod 只应作为 failover 演练，且在维护窗口内明确标注「非计划切换、允许丢最近事务」。

---

### [严重度 中] 用 `discard_passdown` 解释 guest fstrim 为何能释放 pool 空间（因果错位）

- 位置: docs/12-proxmox-pve/notes/pve-vg-thinpool-analysis-2026-11-06.md:90、164-167
- 原文: 「`discard_passdown`：TRIM/discard 会传递给底层，之前的 fstrim 能生效」；「`discard_passdown` 已开启，因此：- VM 内 `fstrim` 能把空闲块还给 thin pool」
- 问题: `discard_passdown` 只决定 thin-pool 是否把 discard 继续下传到 PV（这里是 NVMe），它不决定 pool 是否回收 chunk。guest 的 TRIM 能不能到达 pool，取决于 VM 磁盘是否 `discard=on`（QEMU 是否把 UNMAP 传给 virtio-scsi）。该文档自己的同系列证据就否证了这个因果：ceph-disk-optimization-2026-11-05.md:473-475 记录「在 master02 执行 fstrim 报告回收 7.6G，但主机 pvesm/lvs 完全不变」，那时 `discard_passdown` 已经是开着的，直到给 VM 加 `discard=on` 并冷启动后才释放 137G。
- 证据/正确说法: `dmsetup status pve-data-tpool` 的 `discard_passdown` 管下传；释放 pool 空间靠 guest→virtio-scsi 的 discard（PVE 侧 `discard=on`）+ pool 回收 chunk。文档应把「能还给 pool」归因到 `discard=on`，「能顺带 trim 物理盘」才归因到 `discard_passdown`。

---

### [严重度 中] 「限流/锁用独立 DB」并不能避免被淘汰

- 位置: docs/06-storage-ceph/notes/compassio-pg-redis-ops-plan.md:276-277
- 原文: 「缓存 key 用 `volatile-lru` + TTL；限流/锁用独立 DB 或独立实例，避免被缓存淘汰。」
- 问题: Redis 的 `maxmemory` 与淘汰策略是**实例级**的，`SELECT` 出来的逻辑 DB 不隔离内存；把限流 key 放进 db1、缓存放 db0，在 `allkeys-lru` 下照样会被淘汰（`volatile-lru` 下只要限流 key 也带 TTL 同样会被淘汰）。这条建议会让人误以为已经做了隔离。
- 证据/正确说法: 当前实例启动参数为 `--maxmemory 384mb --maxmemory-policy allkeys-lru --appendonly no`（同文档 1.3 节）。要与缓存隔离只能**独立实例**（或 Redis Cluster 的不同分片），或者给限流 key 不放 TTL 并改用 `noeviction` + 容量规划 + 监控。

---

### [严重度 中] 「virt-customize 会随机化 machine-id」不成立，且示例命令会误伤宿主机

- 位置: docs/12-proxmox-pve/iac/02-cloudinit-golden-template.md:156-157（另见 12-proxmox-pve/README.md:123、notes/openeuler-batch-deploy-2026-11.md:117）
- 原文: 「# virt-customize 会随机化 machine-id，需要再次清空 / truncate -s 0 /etc/machine-id   # 在 guest 内或 chroot 执行」
- 问题: 两点。(1) 重置 machine-id 是 `virt-sysprep` 的 `machine-id` 操作（语义是清空，首次启动由 systemd 重新生成），`virt-customize(1)` 没有 machine-id 相关操作/参数，不会「随机化」它；把 sysprep 的行为记在 customize 头上，会让人以为只需跑 customize 就已完成 sysprep。(2) 这条 `truncate` 在宿主 shell 里执行时作用于 PVE 宿主机的 `/etc/machine-id`（不是镜像内的），一旦照抄会清空宿主机 machine-id，影响依赖 machine-id 的服务（journald 持久日志目录、DHCP DUID 等）。
- 证据/正确说法: libguestfs `virt-customize(1)` 的选项表无 machine-id 项；`virt-sysprep(1)` 才有 `--operation machine-id`（清空 /etc/machine-id 与 /var/lib/dbus/machine-id）。镜像内操作应写成 `virt-customize -a ... --run-command 'truncate -s 0 /etc/machine-id'` 或 `guestfish --rw -a ... -i truncate /etc/machine-id`。

---

### [严重度 低] `df` 的 45G/94G 被标成 51%，同一行数字也对不上

- 位置: docs/12-proxmox-pve/notes/pve-vg-thinpool-analysis-2026-11-06.md:67、478；docs/12-proxmox-pve/notes/pve-vm-disk-location-2026-11-07.md:190
- 原文: 「root:    45G / 94G  (51%)」；「/dev/mapper/pve-root   94G   45G   45G   51%   /」
- 问题: 45/94 = 47.9%，不是 51%；而且 45G used + 45G avail ≠ 94G total（差 4G，恰是 ext4 保留块之外的取整误差）。这处输出被当作「实测 df」引用，百分比和可用量都不自洽。
- 证据/正确说法: 45/94 ≈ 48%；若 used=45、avail=45、total=94，则应为 47.9% 且 avail 写 49G。按 assets/pve-state/df.txt 的口径（28G/94G/32%）也只是不同时间点，不能混用。

---

### [严重度 低] 告警 PromQL 用了不存在的标签/非法表达式

- 位置: docs/06-storage-ceph/notes/ceph-rbd-released-pv-audit-20261005.md:259、262-263
- 原文: 「(time() - kube_persistentvolume_created{phase="Released"} > 86400)」；「  ceph_rbd_stat_bytes{}                     # 或 pool 内镜像数指标
- sum(kube_persistentvolume_resource_requests_storage_bytes{storageclass="ceph-rbd-sc"})」
- 问题: `kube_persistentvolume_created` 只有 `persistentvolume` 标签，没有 `phase`，该表达式永远选不到序列；第 3 条则是一个裸指标名加注释再减另一个指标，不是合法 PromQL（没有运算符、注释也不能出现在表达式中间），粘进规则文件会直接解析失败。
- 证据/正确说法: 阶段信息在 `kube_persistentvolume_status_phase{phase="Released"}`，创建时间在 `kube_persistentvolume_created`，需要 `on(persistentvolume)` 之类的向量匹配组合，例如 `time() - (kube_persistentvolume_created * on(persistentvolume) group_left kube_persistentvolume_status_phase{phase="Released"}) > 86400`（或改用 `kube_persistentvolume_status_phase == 1 and on(...) ...`）。

---

### [严重度 低] CLOG 段大小说成 8KB（8KB 是页，段是 256KB）

- 位置: docs/06-storage-ceph/notes/pg-s3-incident-report.md:41
- 原文: 「PostgreSQL 16 的 CLOG（`pg_xact`）以 8KB 为一个段文件记录事务状态。」
- 问题: `pg_xact` 的 SLRU 段文件是 256KB（32 个 8KB 页）；8KB 是页大小。文档随后用「健康实例 `pg_xact/0000` 是 8192 字节」做对照（第 51 行），恰好说明它把「初始只写了一页」误当成「段大小 8KB」，会让读者以为 8192 字节就是完整的段。
- 证据/正确说法: `pg_xact` 每个段文件 256KB（`BLCKSZ=8KB`，`SLRU_PAGES_PER_SEGMENT=32`）；新库的 `0000` 常只有 8KB，是因为只用到第一页，随事务推进增长到 256KB 后切到 `0001`。

---

### [严重度 低] 「一页命令」的磁盘扩容少了 LV/文件系统两步，照抄 `df` 不会变

- 位置: docs/12-proxmox-pve/iac/05-batch-ops.md:262-264
- 原文: 「qm resize 122 scsi0 +20G / qm set 122 --scsi0 local-lvm:vm-122-disk-0,discard=on,ssd=1,iothread=1,size=80G / ssh root@10.0.0.122 'growpart /dev/sda 2; pvresize /dev/sda2; fstrim -av'」
- 问题: 只扩了块设备和分区/PV，没有 `lvextend` + `resize2fs/xfs_growfs`，根文件系统仍是原大小；与本篇 3.5 节和坑 5（第 219 行）自己写的完整步骤不一致。速查块最容易被照抄，缺步骤会得出「qm resize 没用」的错误结论。
- 证据/正确说法: 完整三步：PVE `qm resize` → guest `growpart` + `pvresize` + `lvextend -l +100%FREE` + `resize2fs`（xfs 用 `xfs_growfs /`，且必须挂载状态执行）。

---

### [严重度 低] 第 8 章的子标题编号仍是 7.x

- 位置: docs/12-proxmox-pve/10-kvm-qemu-virtio-cloud-boot.md:436-473
- 原文: 「## 8. 引导细节：UEFI、Secure Boot、PXE、initramfs」→「### 7.1 本环境的引导方式」「### 7.2 PXE/网络引导」「### 7.3 initramfs 缺驱动的真实风险」
- 问题: 章节号与子节号不一致（8 下面挂 7.x），交叉引用和目录锚点会对不上；同篇第 7 章（云镜像 vs ISO）也用了 7.1-7.4，出现两组 7.1/7.2/7.3。
- 证据/正确说法: 应改为 8.1/8.2/8.3，或把该节提前为第 7 章并顺延。

---

### [严重度 低] 「只有 PATA、没有 ATAPI」是概念混淆，据此解释 IDE cloud-init 盘不可用

- 位置: docs/12-proxmox-pve/iac/02-cloudinit-golden-template.md:136（另见 notes/openeuler-batch-deploy-2026-11.md:75、286）
- 原文: 「**cloud-init 盘必须挂 `scsi1`**：openEuler guest 只有 PATA，没有 ATAPI，`ide2` 检测不到」
- 问题: ATAPI 不是与 PATA 并列的控制器，而是 ATA 上承载 CD-ROM 的协议；说「有 PATA 没有 ATAPI」自相矛盾（PATA 控制器 + libata 通常就带 ATAPI/sr_mod）。真正原因更可能是该云镜像的 initramfs 未包含 `ata_piix`/`sr_mod`，首启时没有 `/dev/sr0`，与「ATAPI 不存在」无关。按错误根因排查会去换控制器类型，而不是补 initramfs 模块。
- 证据/正确说法: 结论（把 cloud-init 盘放 `scsi1`）是对的，但解释应写成「镜像 initramfs 缺 IDE/ATAPI 驱动，`ide2` 的 CD-ROM 在首启阶段不可见；virtio-scsi 由 `virtio_scsi` 驱动，镜像内已有」。

---

### [严重度 低] rp_filter「6 节点全部为 2」的实测表与现状不符（all 实际为 0）

- 位置: docs/06-storage-ceph/notes/cnpg-upgrade-postmortem-2026-11-08.md:454-463（另见 06-storage-ceph/README.md:247）
- 原文: 「m01       all=2 default=2 eth0=2 eth1=2」（六节点同）；README「统一节点 `rp_filter=0` 并持久化」
- 问题: 三处说法互不一致：表格说 all=2，README 坑 13 说改成 0，而实际生效值取决于 Cilium 写的 `99-zzz-override_cilium.conf`（排序在 `99-zz-k8s-rp-filter.conf` 之后）。m01 实测 `net.ipv4.conf.all.rp_filter = 0`、`eth0 = 2`，即「all=0、接口=2」，有效值 max(all,iface)=2。表格里「all=2」这一列已经过期；README 的「=0」与脚本/配置文件（=2）也不一致。
- 证据/正确说法: 本机 `sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth0.rp_filter` → `0` / `2`；`/etc/sysctl.d/99-zzz-override_cilium.conf` 含 `net.ipv4.conf.all.rp_filter = 0`。文档应写成「接口级=2，all 被 Cilium 覆盖为 0，有效值 2」，并说明以 `sysctl` 实际值为准。
