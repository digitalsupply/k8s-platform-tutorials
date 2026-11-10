# PVE VG / LVM-thin 布局分析与容量“甜点”

> 主机：`teacher`（Proxmox VE，931.5G NVMe）
> 日期：2026-11-06
> 数据来源：`pvs` / `vgs` / `lvs` / `pvesm` / `dmsetup` / `df` 实测

---

## 0. 结论先行

1. **当前布局是 PVE 安装器 LVM-thin 的典型默认分配**：root 96G + swap 8G + thin pool 794.3G + 元数据 16.2G + VG 空闲 16G。
2. **96G 根分区不算小**：当前 45G 已用、45G 可用；PVE OS 本身约 10G，其余是 NFS/Prometheus、ISO、Docker 等“非 OS”内容。
3. **“大部分空间给 VM 镜像”是合理的**：thin pool 占 VG 的 85.4%，当前实际使用 59.77%，还有约 319G 可分配。
4. **真正的短板不是 96G root，而是 VG 只剩 16G**：
   - `lvm.conf` 配置了 `thin_pool_autoextend_threshold=70`、`percent=20`；
   - pool 到 70% 时想扩 20%（约 159G），但 VG 只有 16G，**autoextend 会失败**；
   - 同时 thin pool 带 `queue_if_no_space`，写满后 VM 可能表现为卡死。
5. **甜点不是一个固定比例**，而是：
   ```
   root = OS + 本地 ISO/备份 + 额外服务 + 20% 余量
   VG 空闲 = max(3–5% VG, 一次 autoextend 的量)
   data = VG - root - swap - tmeta - spare - VG 空闲
   ```
6. **这台机器现在最值得做的**：
   - 把 `/data/nfs`（23G，Prometheus 21G）从根分区迁走；
   - 给 VG 增加 30–50G 余量，或把 autoextend 调到 2–5% 并监控；
   - 在 pool 到 65%–70% 前主动处理，不要依赖自动扩容。

---

## 1. 当前实际布局

### 1.1 PV / VG

```text
PV             PSize    PFree  Used
/dev/nvme0n1p3 <930.51g 16.00g <914.51g

VG  VSize    VFree  Ext   #Ext   Free
pve <930.51g 16.00g 4.00m 238210 4096
```

- 单块 NVMe：`/dev/nvme0n1p3`，约 930.51G；
- 单个 VG：`pve`；
- VG 剩余：64M × 4096 = 16G。

### 1.2 LV 分配

| 项目 | 大小 | 类型 | 占 VG | 作用 |
|---|---:|---|---:|---|
| `pve-root` | 96G | linear / ext4 | 10.3% | PVE 系统、日志、ISO/模板、本地备份 |
| `pve-swap` | 8G | linear | 0.86% | 主机 swap |
| `data_tdata` | 794.3G | linear → thin pool 数据区 | 85.4% | VM 磁盘、快照、克隆 |
| `data_tmeta` | 8.1G | linear | 0.87% | thin pool 元数据，约 data 的 1% |
| `lvol0_pmspare` | 8.1G | linear | 0.87% | thin pool 元数据备用/修复 |
| **VG 空闲** | **16G** | 未分配 | **1.7%** | 元数据扩展/应急 |

合计：

```
96 + 8 + 794.3 + 8.1 + 8.1 + 16 = 930.5G
```

### 1.3 当前使用率

```text
root:    45G / 94G  (51%)
swap:    0B / 8G
data:    59.77%  (thin pool)
meta:    1.99%
```

thin pool 细节：

```text
LV   LSize   Data%  Meta%  Chunk
data 794.30g 59.77  1.99   64.00k
```

`dmsetup status pve-data-tpool`：

```text
0 1665777664 thin-pool 386 42207/2123776 7778885/13013888 - rw discard_passdown queue_if_no_space - 1024
```

含义：

- `42207/2123776`：元数据块使用 1.99%；
- `7778885/13013888`：数据块使用 59.77%；
- `discard_passdown`：TRIM/discard 会传递给底层，之前的 fstrim 能生效；
- `queue_if_no_space`：pool 满时 IO 排队等待，而不是立即报错。

### 1.4 `pvesm` 视角

```text
local      dir       98.5G   46.8G used   47.5%
local-lvm  lvmthin  794.3G  474.8G used   59.77%
```

- `local`（dir）在根分区，内容：`vztmpl, iso, backup`；
- `local-lvm`（lvmthin）使用 `pve/data`，内容：`images, rootdir`。

### 1.5 根分区里到底是什么

```text
/var/lib/vz      8.4G   （其中 ISO 8.3G）
/data            23G    （NFS + Prometheus 21G）
/var/lib/docker  3.1G   （Docker 已停止）
/var/log         0.6G
```

因此 96G 根分区中：

- PVE OS + 基础软件：约 10G；
- 其余约 35G 是 ISO、NFS/Prometheus、Docker、日志等。

**这不是 LVM 分割的问题，而是“额外服务放进了根分区”。**

---

## 2. 当初是怎么分的

从实际布局看，这是 PVE 安装器选择 **LVM-thin** 时的典型默认结果：

1. 整块 NVMe 建一个 PV；
2. 建 VG `pve`；
3. 切出 `pve-root` 96G（ext4）；
4. 切出 `pve-swap` 8G；
5. 剩余空间创建 thin pool：
   - `data_tdata` 放数据；
   - `data_tmeta` 放元数据，约 1%；
   - `lvol0_pmspare` 作为元数据备用；
6. 剩余 16G 保留为 VG 空闲（安装器默认/对齐/余量）。

没有看到自定义 LVM profile，`lvs` 的 `LProfile` 为空；thin pool 处于 `monitored` 状态。

---

## 3. 这样分的好处

### 3.1 OS 与 VM 磁盘隔离

- PVE 系统、日志、ISO、模板、备份在 `pve-root`；
- VM 磁盘在 `local-lvm`；
- VM 的大量写入不会直接碎片化/塞满 ext4 根分区。

### 3.2 Thin provisioning

- VM 虚拟磁盘按需分配；
- 创建 200G 虚拟盘≠立刻占 200G；
- 当前 pool 实际使用 59.77%，仍有约 319G 可分配；
- 适合实验/多 VM 场景。

### 3.3 快照、克隆、回滚

LVM-thin 是 Proxmox 快照、链接克隆、模板克隆的基础：

- 快照只保存变化 chunk；
- 克隆共享未修改 chunk；
- 创建/回滚速度快。

### 3.4 discard/TRIM 可工作

`discard_passdown` 已开启，因此：

- VM 内 `fstrim` 能把空闲块还给 thin pool；
- 之前的 `discard=on + fstrim` 优化能真正释放空间；
- 后续每周 fstrim 可抑制 pool 再次膨胀。

### 3.5 元数据与 spare 分离

- `tmeta` 约 1% 是 LVM thin 的推荐比例；
- `lvol0_pmspare` 用于元数据损坏时的修复；
- `monitored` 表示 dmeventd 在监控 thin pool。

### 3.6 swap 独立

- 8G swap 不和根分区抢空间；
- 当前 swap 使用 0，维护后内存压力已缓解；
- PVE 不做休眠，8G 对 62G 内存足够。

---

## 4. 代价与风险

### 4.1 根分区 96G 是固定成本

- `pve-root` 是 **linear LV**，96G 实打实占用，不能 thin 超分；
- 这 96G 不能直接给 VM 用；
- 当前 45G 已用、45G 可用，说明 96G 本身不紧张；
- 如果根分区只有 32–48G，在当前 NFS/ISO/Docker 都放根分区的情况下会很紧。

### 4.2 thin pool 是共享故障域

所有 VM 磁盘共享 `data`：

- pool 满 → 所有 VM 写入受影响；
- `tmeta` 损坏 → 所有 thin 卷受影响；
- 同一块 NVMe 故障 → PVE + 所有 VM 一起丢失。

### 4.3 最大隐患：autoextend 空间不够

实际 `lvm.conf`：

```ini
thin_pool_autoextend_threshold = 70
thin_pool_autoextend_percent   = 20
```

含义：

- pool 到 **70%** 时自动扩容；
- 扩容量为当前 pool 的 **20%**：

```
794.3G × 20% ≈ 158.9G
```

但 VG 只剩 **16G**。

结果：

- pool 到 70% 时，dmeventd 想扩 159G，实际只有 16G；
- **autoextend 失败**，pool 继续增长；
- 到 100% 时 `queue_if_no_space` 生效，VM 可能卡死。

当前 pool 使用 59.77%，距离 70% 还有约 10 个百分点，约 **80G** 写入空间。不能等它自动扩。

### 4.4 `queue_if_no_space` 的风险

`dmsetup` 显示 `queue_if_no_space`：

- pool 满时 IO 不是立刻报错，而是排队；
- VM 可能表现为“卡死/无响应”；
- 比直接报错更隐蔽，排障更困难；
- 必须避免 pool 到 100%。

### 4.5 thin 超分风险

- 虚拟磁盘总量远大于 794G；
- 当前实际使用 59.77%，仍有约 319G；
- 如果所有 VM 同时写满，pool 会耗尽；
- 需要监控“实际数据使用”，不是只看申请容量。

### 4.6 性能代价

- thin pool 每次写入要更新元数据，比 raw 直通多一层开销；
- 快照/克隆是写时复制；
- fstrim/discard 会带来短时 IO 峰值和碎片化；
- 快照越多，元数据压力和性能影响越大。

### 4.7 根分区不能轻易缩

- `pve-root` 是 ext4 on linear LV；
- 缩容需要卸载、fsck、resize2fs、lvreduce；
- 风险高，通常需要停机/救援环境；
- 扩容可以在线做，但需要 VG 有空闲；
- 当前 16G VG 空闲也不足以大幅扩 root。

---

## 5. “PVE OS 空间少了，但多给 VM 合理吗？”

**基本正确，但要区分两件事：**

### 5.1 96G 根分区并不算少

- PVE OS 本身约 10G；
- 当前 45G 已用、45G 可用；
- 对纯 PVE 虚拟机宿主，32–64G 通常够；
- 96G 已经比较宽裕。

### 5.2 真正占根分区的是“非 OS”内容

```text
/data            23G   ← NFS + Prometheus
/var/lib/vz      8.4G  ← ISO 8.3G
/var/lib/docker  3.1G  ← Docker 已停
/var/log         0.6G
```

如果把这些迁走/删除，根分区实际可能只占 10–15G，32–48G 就够。

### 5.3 “大部分给 VM 镜像”是正确的方向

- PVE 的主要工作是跑 VM；
- VM 磁盘放在 thin pool 合理；
- 85% 给 thin pool 属于偏激进但可接受；
- **问题不是 pool 大，而是 VG 空闲太小，撑不起 autoextend。**

---

## 6. 容量“甜点”怎么定

### 6.1 公式

```text
root = OS(8–12G)
       + 日志/apt(2–3G)
       + ISO/模板
       + 本地备份
       + 额外服务(NFS/Prometheus 等)
       + 20% 余量

swap = 4–8G

tmeta = data × 1%
spare = tmeta（修复用）

VG 空闲 = max(3–5% VG, 一次 autoextend 的量)

data = VG - root - swap - tmeta - spare - VG 空闲
```

### 6.2 这台机器的当前 vs 建议

| 项目 | 当前 | 建议 |
|---|---:|---|
| root | 96G (10.3%) | 保留 96G；若 NFS 迁走可降到 64G |
| swap | 8G | 保留 |
| tmeta + spare | 16.2G (1.7%) | 保留（约 1% + 1%） |
| data pool | 794.3G (85.4%) | 当前可用；75–80% 更稳，或保持但补 VG 余量 |
| VG 空闲 | 16G (1.7%) | **30–50G（3–5%）**，或覆盖一次小比例 autoextend |
| autoextend | 70% / 20% | 与 16G 空闲不匹配；改为 2–5%，或加盘 |

### 6.3 如果重新安装/重建

| 方案 | root | swap | tmeta+spare | VG 空闲 | data |
|---|---:|---:|---:|---:|---:|
| A. 纯 PVE 宿主 | 64G | 8G | 16.2G | 46.5G (5%) | 795.8G |
| B. 含 NFS/ISO | 96G | 8G | 16.2G | 46.5G (5%) | 763.8G |
| C. 坚持 20% autoextend | 96G | 8G | 16.2G | 158.9G (17%) | 651.4G |

说明：

- A 和 B 的 data 大小与当前 794G 接近，因为 **root 减少的部分被 VG 空闲增加抵消**；
- C 为了 20% autoextend 留 159G，pool 只剩 651G，对实验室通常太保守；
- 更实际的做法是 **B + 把 autoextend 改成 2–5%**，或者加一块盘专门做 VG 余量。

### 6.4 不建议做的事

- 不要在线缩 `pve-root`（风险高）；
- 不要把 thin pool 用到 100%（`queue_if_no_space` 会让 VM 卡死）；
- 不要在 VG 只有 16G 时依赖 `70%/20%` autoextend；
- 不要把 NFS/Prometheus 长期放在 PVE 根分区；
- 不要只看“thin pool 还有 319G”就忽略 VG 只剩 16G——两者不是一回事。

---

## 7. 当前最值得做的三件事

### 7.1 把 `/data/nfs` 从根分区迁走

`/data` 占 23G，其中 Prometheus 21G，是根分区最大的非 OS 占用，也是 PVE 系统盘被写满的风险来源。

建议：

- 迁到独立 LV（需要 VG 空闲，当前只有 16G，不够）；
- 或迁到独立 SSD/HDD；
- 或迁到独立 VM/外部 NFS。

迁走后：

- 根分区可降到 64G 甚至 48G；
- PVE 管理面不再受 Prometheus 增长影响；
- 根分区风险显著下降。

### 7.2 给 VG 增加 30–50G 余量，或调整 autoextend

当前 16G 撑不起 `70%/20%`。

方案 A：加一块小盘进 VG，留 30–50G 空闲。

方案 B：把 `thin_pool_autoextend_percent` 调到 2–5%：

```ini
# /etc/lvm/lvm.conf
thin_pool_autoextend_threshold = 70
thin_pool_autoextend_percent   = 3
```

- 3% × 794G ≈ 23.8G，仍略高于 16G；
- 2% ≈ 15.9G，刚好接近当前空闲；
- 修改后重启 `lvm2-monitor` / `dmeventd` 使其生效。

方案 C：不依赖 autoextend，在 pool 到 65%–70% 前主动清理/迁移 VM。

### 7.3 监控三件事

```bash
lvs -o lv_name,data_percent,metadata_percent,seg_monitor pve/data
vgs -o vg_name,vg_size,vg_free
dmsetup status pve-data-tpool
```

告警建议：

- `data%` ≥ 65% 预警；
- `data%` ≥ 70% 必须处理；
- `meta%` ≥ 70% 预警；
- `VG free` < 3% 预警；
- 看到 `queue_if_no_space` 要特别小心。

### 7.4 顺带清理根分区（释放的是 root，不是 pool）

```bash
# 确认不再需要后
umount /mnt/dvd
rm -f /var/lib/vz/template/iso/*.iso
rm -rf /var/lib/docker/overlay2
journalctl --vacuum-size=200M
```

- ISO 8.3G、Docker 3.1G，合计约 11G；
- 这些释放的是根分区，不会增加 thin pool 空间；
- 但能降低 PVE 系统盘风险。

### 7.5 更大的优化在 Ceph OSD

当前 Ceph 的 6×30G = 180G OSD 在 thin pool 中按 99.99% 计费，而 Ceph 实际只存约 20G。

- 如果评估后缩小 OSD 虚拟盘或开启 OSD discard，可能回收约 150G；
- 这比“root 96G vs 64G”的收益大得多；
- 但需要单独的 Ceph 维护窗口和风险评估。

---

## 8. 实测命令附录

### 8.1 查看 PV/VG

```bash
pvs -o pv_name,pv_size,pv_free,pv_used
vgs -o vg_name,vg_size,vg_free,vg_extent_size,vg_extent_count,vg_free_count
```

### 8.2 查看 LV / thin pool

```bash
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent,seg_monitor,devices
lvs -o lv_name,lv_size,data_percent,metadata_percent,chunk_size pve/data
```

### 8.3 查看 thin pool 状态

```bash
dmsetup status pve-data-tpool
```

关注：

- `discard_passdown`：TRIM 是否下传；
- `queue_if_no_space`：满时是否排队；
- 数据块/元数据块使用比例。

### 8.4 查看 autoextend 配置

```bash
lvmconfig --type default activation/thin_pool_autoextend_threshold
lvmconfig --type default activation/thin_pool_autoextend_percent
grep -nE 'thin_pool_autoextend' /etc/lvm/lvm.conf
```

### 8.5 查看 PVE 存储

```bash
pvesm status
cat /etc/pve/storage.cfg
df -hT /
du -sh /var/lib/vz /data /var/lib/docker /var/log
```

### 8.6 本次实测关键值

```text
PV:            /dev/nvme0n1p3  930.51G  PFree 16G
VG:            pve             930.51G  VFree 16G
root:          96G linear ext4  45G used / 94G total (51%)
swap:          8G linear        0B used
data:          794.3G thin-pool 59.77% used
tmeta:         8.1G             1.99% used
pmspare:       8.1G
chunk:         64K
autoextend:    70% / 20%
thin pool:     discard_passdown, queue_if_no_space
```

---

## 9. 一句话总结

**96G 给 PVE 不算多，当前 45G 空闲也够用；85% 给 thin pool 是“偏向虚拟机”的合理选择，但这台机器真正的短板是 VG 只剩 16G，撑不起 70%/20% 的 autoextend，以及 NFS/Prometheus 23G 放在根分区。优先迁走 NFS、补 30–50G VG 余量或调小 autoextend，比重新划分 96G 根分区更划算。**
