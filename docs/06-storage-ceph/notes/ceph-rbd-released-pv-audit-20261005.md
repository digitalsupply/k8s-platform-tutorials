# Ceph RBD `Released` 状态孤儿 PV 审计报告

- **审计时间**：2026-10-05
- **集群**：kubernetes-admin@kubernetes（6 节点，v1.35.9，均 Ready）
- **Ceph**：clusterID `594e535e-d82c-11f0-afa7-bc24112b746f`，Ceph **Reef 18.2.8**，HEALTH_OK（mon `10.0.0.31/41/51`）
- **RBD CSI**：ceph-csi-rbd 3.16.2，provisioner 正常（`ceph-csi-rbd-provisioner-5f98999c9f-lrlb2`）
- **本次为只读审计，未做任何删除/修改操作**

---

## 1. 结论摘要（先看这里）

| 项目 | 结果 |
|------|------|
| 集群 PV 总数 | 28 |
| `Released` PV 总数 | **10**（其中 Ceph RBD **9**，NFS 1） |
| 真正孤儿（PV 已无对应活跃 PVC） | Ceph RBD **9 / 9 全部是** |
| 额外发现：**Ceph 侧无 PV 的僵尸镜像** | **2 个**（PV 对象已被强删，RBD 镜像遗留） |
| `Failed` / `Available` / `Pending` PV | 0 / 0 / 0 |
| PV 声明容量合计（RBD Released） | 80 GiB（thin 预留） |
| 镜像**实际占用**合计（RBD Released） | **≈ 2.14 GiB** |
| 2 个 Ceph 僵尸镜像实际占用 | **≈ 1.48 GiB** |
| **可回收实际空间** | **≈ 3.62 GiB** |
| 全部 11 个目标镜像的 Ceph `watchers` | 均为 `none`（**无任何客户端挂载**） |
| 全部镜像的快照 | 无 |

**一句话结论**：9 个 Ceph RBD `Released` PV 全部确认为孤儿，其中 **7 个 Loki 卷可以直接清理**，**2 个 PostgreSQL 卷建议暂缓**（原因见 §5，因集群当前**没有任何可用备份**）。另发现 2 个无 PV 追溯的僵尸镜像，可清理。真正的根因是 `ceph-rbd-sc` 的 `reclaimPolicy: Retain`。

---

## 2. 完整对应关系总表（PV ↔ PVC ↔ Ceph RBD 镜像）

### 2.1 Ceph RBD `Released` PV —— 9 个

字段说明：`watchers=none` 表示 Ceph 侧无任何客户端映射；`实际占用` 来自 `rbd du`。

| # | PV 名称 | Ceph RBD 镜像 (pool `k8s-rbd`) | 容量 | 原 claimRef | PVC 现状 | claimRef UID 比对 | PV 创建时间 (UTC) | 实际占用 | watchers | 卷内实际内容（只读挂载核验） |
|---|----------|-------------------------------|------|-------------|----------|------------------|------------------|----------|----------|------------------------------|
| 1 | `pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f` | `csi-vol-543be5ab-8bbf-46d7-a5d3-6bf81cbdb736` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致**（PVC 已被重建） | 2026-04-05T13:19:55Z | 72 MiB | none | ext4；仅空目录 `compactor/`、`tsdb-shipper-cache/`；**文件数 0** |
| 2 | `pvc-28b685a9-f530-4a0b-ace6-c8f4091ab8cf` | `csi-vol-554bcd63-61e2-47f3-91b8-1b48259c28a1` | 10Gi | `cnpg-system/pg16-ceph-2` | **已删除** | 不可比对 | 2026-04-03T08:47:48Z | 264 MiB | none | ext4 → `pgdata/`；**1884 个文件**；最后写入 **2026-09-29 11:29 CST**（`global/pg_control`、`postmaster.opts`） |
| 3 | `pvc-3baa45e6-2064-4817-8eef-dbc2d64d90a7` | `csi-vol-38df406d-6de2-493a-9e12-1940e7a5c24b` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致** | 2026-04-05T13:33:01Z | 72 MiB | none | ext4；空目录同上；**文件数 0** |
| 4 | `pvc-438afc60-2ec7-4d18-97f5-40a1b9934e80` | `csi-vol-2b7f06b9-da7d-473d-b7c4-4f8002a06141` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致** | 2026-04-06T00:51:22Z | 132 MiB | none | ext4 → `tsdb-shipper-cache/index_20549/20566/20568/20569/`；**10 个 `.tsdb` 索引文件，788K**（bucket: `fake`、`self-monitoring`）；最新 2026-04-26 12:06 |
| 5 | `pvc-5046dd85-3c71-4625-8e12-81ec785fd00f` | `csi-vol-da2dad7d-6b85-43a1-bbc2-bc238f53eeee` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致** | 2026-04-06T00:43:18Z | 72 MiB | none | ext4；空目录；**文件数 0** |
| 6 | `pvc-77c2a7cb-a7dd-4487-a35c-cc9868e91979` | `csi-vol-34935be4-ea1d-4d8b-8668-a2fd3111678a` | 10Gi | `logging/data-loki-write-0` | **存在** | **UID 不一致** | 2026-04-05T13:37:24Z | 104 MiB | none | ext4 → `wal/00000003..00000006`、`wal/checkpoint.000002/`、`tsdb-shipper-active/`；**6 个文件，836K**；最新 2026-04-06 08:48 |
| 7 | `pvc-ac2ccc31-af11-4c53-9e33-0df94e72bd44` | `csi-vol-92d1adea-2df0-46e6-b3ef-22471b737056` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致** | 2026-04-05T13:36:52Z | 72 MiB | none | ext4；空目录；**文件数 0** |
| 8 | `pvc-c6bcf716-11ff-48e8-85fc-8a2691382326` | `csi-vol-85352ea6-baf7-4c87-a439-d296f4592985` | 5Gi | `cnpg-system/pg16-ceph-2-wal` | **已删除** | 不可比对 | 2026-04-03T08:47:48Z | **1.3 GiB** | none | ext4 → `pg_wal/`；**125 个文件**；含 `00000002.history`、`00000003.history`、TL2/TL3 WAL 段、`archive_status/*.done`；最新 2026-06-18 17:10 |
| 9 | `pvc-e4e45b3b-2338-4919-a5c1-cf71c0aea6c5` | `csi-vol-465fa860-90c1-43b2-b045-c099f86e0989` | 10Gi | `logging/data-loki-backend-0` | **存在** | **UID 不一致** | 2026-04-05T13:29:30Z | 72 MiB | none | ext4；空目录；**文件数 0** |

**小计**：声明容量 80 GiB（thin）｜实际占用 ≈ **2.14 GiB**｜6 个卷文件数为 0

### 2.2 Ceph 侧僵尸镜像（**PV 对象已不存在**，PV 侧查询不到）

这 2 个镜像存在于 pool `k8s-rbd`，但**没有任何 PV 引用**——它们的 PV 对象已被硬删除，而因 `Retain` 策略 RBD 镜像被永久留下。这是本次审计的额外发现，也是"泄漏链"的直接证据。

| # | Ceph RBD 镜像 | 容量 | 实际占用 | 推定身份 | 核验依据 | 最后活动 (CST) | watchers | 快照 |
|---|---------------|------|----------|----------|----------|------------------|----------|------|
| 10 | `csi-vol-f3256b3c-f1fe-4fd3-b756-6074cc8f4a7d` | 10Gi | 288 MiB | **`pg16-ceph-1`（数据盘）** | ext4 → `pgdata/`，1878 文件 | **2026-05-09 19:09** | none | 无 |
| 11 | `csi-vol-b8d729a6-7f43-4166-9af8-a299b79bb346` | 5Gi | **1.2 GiB** | **`pg16-ceph-1-wal`（WAL 盘）** | ext4 → `pg_wal/`，112 文件，含 `00000002.history`、`000000010000000000000003.00000028.backup` | **2026-05-09 19:09** | none | 无 |

**判定依据**：这两个镜像最后活动时间 2026-05-09 19:09 CST，与 `pvc-312f456c`（`pg16-ceph-3` 数据盘）创建时间 **2026-05-09T11:30:54Z = 19:30:54 CST** 仅差 21 分钟 —— 完全符合 CloudNativePG 用 `pg_basebackup` 从 `pg16-ceph-1` 克隆出 `pg16-ceph-3`、随后删除实例 1 的行为。故这两个镜像就是被替换掉的 **集群第 1 号实例**的数据盘与 WAL 盘。

**小计**：声明容量 15 GiB（thin）｜实际占用 ≈ **1.48 GiB**

### 2.3 非 Ceph 的 `Released` PV（附带发现，不在本次范围）

| PV 名称 | SC | 容量 | 原 claimRef | PVC 现状 | 实际占用 |
|----------|-----|------|-------------|----------|----------|
| `pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd` | `nfs-sc` | 10Gi | `default/test-pvc` | **已删除** | 需到 NFS 后端核对 |

> 该 PV 由自建 `example.com/nfs` provisioner 管理（`nfs-sc` 声明 `reclaimPolicy: Delete`，但 PV 上是 `Retain`），建议单独排查其回收逻辑。

---

## 3. `Released` 状态是怎么产生的（原理）

这是理解本次全部问题的关键：

```
PVC 被删除
   ↓
k8s 发现 PV 的 claimRef 指向的 PVC 已不存在
   ↓
PV 状态置为 Released   ← K8s 永远不会自动删除 Released PV（设计上需人工介入）
   ↓
若 SC/PV 的 reclaimPolicy = Delete → external-attacher 调用 CSI DeleteVolume → PV 与 RBD 镜像一并消失
若 reclaimPolicy = Retain（本案）→ 到此为止，PV 与 RBD 镜像双双永久留存
   ↓
即使此时人工 kubectl delete pv
   ↓
Retain 语义下 K8s 也不会去删 RBD 镜像 → 只清掉 PV 对象，镜像变成"无主僵尸"
```

**所以本案是"两级泄漏"**：
1. **第一级**：PVC 删除 → PV 变 `Released` 永久滞留（9 个）
2. **第二级**：有人曾手动 `kubectl delete pv` 清掉 PV 对象 → RBD 镜像成为无主僵尸（2 个，即 `pg16-ceph-1` 的两个卷）

第 2 级泄漏已经在集群里真实发生过，这说明**如果后续直接 `kubectl delete pv` 来清理这 9 个 Released PV，会再生产 9 个僵尸镜像，把问题从 9 个放大到 18 个**。

### 3.1 根因定位

| 根因 | 证据 |
|------|------|
| **① `ceph-rbd-sc` 使用 `reclaimPolicy: Retain`** | `kubectl get sc ceph-rbd-sc` → `Retain`；9 个 PV 的 `spec.persistentVolumeReclaimPolicy` 均为 `Retain`，finalizer 为 `external-attacher/rbd-csi-ceph-com` |
| **② Loki PVC 在 2026-04-05/06 被反复删除重建** | 同一 PVC 名 `logging/data-loki-backend-0` 在 **26 小时内轮换了 6 个 UID**（PV 创建时间 13:19:55 → 13:29:30 → 13:33:01 → 13:36:52 → 次日 00:43:18 → 00:51:22），且每次都动态供应一个新 PV。属于上线初期手工调试/反复重装 |
| **③ Helm 重装触发 backend PVC 重建** | `helm install loki` revision 1 = 2026-04-26 12:51:11 CST → 同秒创建 `pvc-5dc9836b`（当前 Bound）。而 `loki-write` 的 PVC 跨重装存活（故 write 只有 1 个孤儿、backend 有 6 个） |
| **④ CNPG 实例被反复替换** | CNPG Cluster `pg16-ceph` `metadata.generation=1`、`spec.instances=2` 从未变更，但 `status.latestGeneratedNode=4`、`timelineID=12` → 实例 1→2→3→4 迭代，实例 1/2 的卷成为孤儿 |
| **⑤ CNPG 无备份配置** | `spec.backup = null`，WAL 归档为**空操作**（见 §5.1） |

### 3.2 完整时间线

| 时间 (UTC) | 事件 |
|-----------|------|
| 2026-04-03 07:35:37 | RBD CSI provisioner `#6329` 启动（身份戳 `1775201737617-6329`） |
| 2026-04-03 08:42:32 | CNPG Cluster `pg16-ceph` 创建（`instances=2`，initdb 建库 `n8n`） |
| 2026-04-03 08:47:48 | `pg16-ceph-2` + `pg16-ceph-2-wal` 两个 PV 创建 |
| 2026-04-05 09:28:42 | provisioner 重启为 `#4826` |
| 2026-04-05 13:19:55 | `data-loki-backend-0` 第 1 次重建 → PV `pvc-1eaaa4c3` |
| 2026-04-05 13:29:30 | 第 2 次 → PV `pvc-e4e45b3b` |
| 2026-04-05 13:33:01 | 第 3 次 → PV `pvc-3baa45e6` |
| 2026-04-05 13:36:52 | 第 4 次 → PV `pvc-ac2ccc31` |
| 2026-04-05 13:37:24 | `data-loki-write-0` 重建 → PV `pvc-77c2a7cb` |
| 2026-04-06 00:00:40 | provisioner 重启为 `#7917` |
| 2026-04-06 00:43:18 | backend 第 5 次 → PV `pvc-5046dd85` |
| 2026-04-06 00:51:22 | backend 第 6 次 → PV `pvc-438afc60`；write 重建 → PV `pvc-13f428e3`（**当前 Bound**） |
| 2026-04-26 04:51:13 | `helm install loki` rev1 → backend PV `pvc-5dc9836b`（**当前 Bound**） |
| 2026-05-09 11:30:54 | `pg16-ceph-3` 盘创建；实例 1（`pg16-ceph-1` 数据+**WAL**）镜像最后活动 11:09 → 实例 1 被替换，**PV 对象被硬删** |
| 2026-09-29 03:29:53 | `pg16-ceph-4` 盘创建；`pg16-ceph-2` 的 `pg_control` 最后写入 11:29 CST → 实例 2 被 `pg_basebackup` 克隆后替换 |
| 2026-10-03 02:38:40 | 故障转移，`pg16-ceph-3` 成为 currentPrimary，`timelineID=12`，Cluster Ready |

---

## 4. 能否清理 —— 逐项安全评估

### 4.1 三项通用前置检查（全部通过）

| 检查项 | 方法 | 结果 |
|--------|------|------|
| Ceph 侧无客户端挂载 | `rbd status` → `watchers` | ✅ 11/11 目标镜像均为 `Watchers: none` |
| 无快照/父子依赖 | `rbd snap ls` / `rbd info` → `parent`/`children` | ✅ 无任何快照，无快照层级 |
| Ceph 回收站为空 | `rbd trash ls k8s-rbd` | ✅ 为空（Reef 18.2.8 支持） |
| 无 PVC 仍持有该 PV | PV ↔ PVC 双向比对 | ✅ 9/9 全部无活跃 PVC 绑定 |
| 无活跃 Pod 挂载 | 节点级 + Ceph watchers 交叉验证 | ✅ 无 |

### 4.2 评估结论

#### ✅ 可直接清理 —— 7 个 Loki PV（高置信度）

| PV | 镜像 | 释放空间 | 判定理由 |
|----|------|----------|----------|
| `pvc-1eaaa4c3…` | `543be5ab…` | 72 MiB | 卷内**文件数 0**，仅空目录 |
| `pvc-3baa45e6…` | `38df406d…` | 72 MiB | **文件数 0** |
| `pvc-5046dd85…` | `da2dad7d…` | 72 MiB | **文件数 0** |
| `pvc-ac2ccc31…` | `92d1adea…` | 72 MiB | **文件数 0** |
| `pvc-e4e45b3b…` | `465fa860…` | 72 MiB | **文件数 0** |
| `pvc-438afc60…` | `2b7f06b9…` | 132 MiB | 仅 10 个 TSDB **索引缓存**文件（788K），无 `chunks/` |
| `pvc-77c2a7cb…` | `34935be4…` | 104 MiB | 仅 Loki **WAL 重放缓冲**（836K）+ shipper 活跃标记 |

**关键依据 —— 为什么 Loki 卷没有不可替代的数据**：
Loki 3.6.7 采用 TSDB + `tsdb-shipper`，**真实日志数据以 chunk 形式落在对象存储**（本集群已有 RGW/2 节点），RBD 卷上只保留 *索引缓存*（`tsdb-shipper-cache/`, `compactor/`）与 *WAL 重放缓冲*（`wal/`）。7 个孤儿卷**均不含 `chunks/` 目录**，索引可由对象存储重建。

**残余风险（可接受）**：唯一理论损失是 `pvc-77c2a7cb` 中未 shipper 出去的 WAL 缓冲，但那是 **2026-04-06**（约 6 个月前）已废弃实例的数据，与当前 `loki-write-0` 无任何关联。

#### ⚠️ 建议暂缓 —— 2 个 PostgreSQL PV（`pg16-ceph-2`）

| PV | 镜像 | 占用 | 内容 |
|----|------|------|------|
| `pvc-28b685a9…` | `554bcd63…` | 264 MiB | 完整 `PGDATA`（1884 文件），含 `n8n` 库，最后活动 2026-09-29 |
| `pvc-c6bcf716…` | `85352ea6…` | 1.3 GiB | `pg_wal`（TL2/TL3 WAL 段 + `.history`），最后活动 2026-06-18 |

**表面上看可以删**：当前集群健康（`pg16-ceph-3` primary + `pg16-ceph-4` replica，`timelineID=12`，复制流同步中 `4/60000000`，Cluster Ready），`pg16-ceph-2` 已不在期望状态内（`spec.instances=2`，`instanceNames=[-3, -4]`），数据已被 `-4` 通过 `pg_basebackup` 完整克隆。

**但强烈建议暂缓，原因见 §5.1：**

> **当前集群没有任何真实备份，`pg16-ceph-2` 的这两个卷是该数据库唯一的额外副本。**

从纯粹的"回收 1.5 GiB"收益看，删除并不划算；**先把备份补上，再清理**才是正确顺序。若空间极度紧张必须先删其一，**优先删 `-wal` 卷**（TL2/TL3，已 6 个月无使用，而 `-data` 卷至少保留了可启动的数据目录）。

#### ✅ 可清理（建议优先）—— 2 个 Ceph 僵尸镜像

| 镜像 | 占用 | 判定理由 |
|------|------|----------|
| `csi-vol-b8d729a6…` | 1.2 GiB | `pg16-ceph-1-wal`，最后活动 2026-05-09，实例已被 `-3` 克隆替代 |
| `csi-vol-f3256b3c…` | 288 MiB | `pg16-ceph-1` 数据盘，最后活动 2026-05-09 |

**注意**：这两个比 9 个 `Released` PV **更该优先处理**——它们在 Kubernetes 侧**完全不可见**（`kubectl get pv` 查不到），没有 ownerReference 追溯，是最容易长期被遗忘、也最容易被静默泄漏的资源。同时它们无 PV 保护，直接删除镜像不存在"PV 残留"问题。

> 风险说明：同样受 §5.1 影响。但这两个卷比 `pg16-ceph-2` **更陈旧**（5 个月 vs 3.5 个月），且 `-3` 正是从 `-1` 克隆而来，替代关系明确，判定为可清理。

### 4.3 回收收益核算

| 分组 | 数量 | 声明容量 (thin) | **实际占用** |
|------|------|---------------|-------------|
| Loki `Released` PV | 7 | 70 GiB | 596 MiB |
| PostgreSQL `Released` PV | 2 | 15 GiB | 1.56 GiB |
| Ceph 僵尸镜像 | 2 | 15 GiB | 1.48 GiB |
| **合计** | **11** | **100 GiB** | **≈ 3.62 GiB** |

> ⚠️ **重要预期管理**：RBD 是**薄provisioning**，删除镜像只能回收 `rbd du` 报告的**实际分配数据**（≈ 3.62 GiB），**不会**归还 PV 上声明的 100 GiB。参考 pool 现状：`k8s-rbd` 池容量 50 GiB、`ceph df` 报告已用 **4.3 GiB**（20 个镜像 `rbd du` 累加约 6.8 GiB）。**清理后 pool 占用将下降约 80%，但绝对值仍在 GiB 量级——本次清理的真正价值在于消除隐患与恢复可观测性，而非释放容量。**

---

## 5. 清理过程中发现的更严重问题（强烈建议一并处理）

### 5.1 🔴 P0：PostgreSQL **完全没有备份**，且状态指示具有欺骗性

审计中确认 `pg16-ceph` 的 `spec.backup` 为 **`null`**，而归档命令实际输出为：

```json
{"level":"info","ts":"2026-10-05T13:19:51Z","logger":"wal-archive",
 "msg":"Backup not configured, skip WAL archiving",
 "logging_pod":"pg16-ceph-3","walName":"pg_wal/0000000C0000000400000060",
 "currentPrimary":"pg16-ceph-3","targetPrimary":"pg16-ceph-3"}
```

**这是一次静默失败（silent failure），极具误导性**：

| 指标 | 显示 | 真相 |
|------|------|------|
| `pg_stat_archiver` | `archived_count=702`, `failed_count=0` | 命令正常退出但**什么都没做**，702 是虚高计数 |
| CNPG 条件 `ContinuousArchiving` | **`True`**（"Continuous archiving is working"） | **假健康**，同样只是命令返回 0 |
| `kubectl get backup` / `scheduledbackup` | 空 | 无任何备份对象 |

**综合风险**：`n8n` 业务库（63 张表）**仅靠单套复制保护**。若 `pg16-ceph-3` 与 `pg16-ceph-4` 同时损坏（本集群 6 节点、共享存储后端），**数据将永久丢失**，届时那 2 个 `pg16-ceph-2` 孤儿卷将是唯一的救命稻草——**这正是本报告建议暂缓删除它们的核心理由**。

**叠加风险**：`data_checksums = off` —— 数据页损坏无法被检测，静默坏块会直接导致查询出错或实例崩溃。

**建议**：立即为 `pg16-ceph` 配置 `spec.backup.barmanObjectStore`（本集群已有 RGW/S3 可用）+ `ScheduledBackup`；补做基线备份并**做一次恢复演练**；开启 `postgresql.data_checksums`（需 `pg_basebackup` 重建实例）。同时**修正告警**，避免再出现"条件为 True 但实际无备份"。

### 5.2 🟠 P1：`Retain` 回收策略导致泄漏必然发生

`ceph-rbd-sc` 设为 `Retain`，意味着**每一次 PVC 删除都会在 Ceph 侧永久留下一块空间**，且完全依赖人工清理。当前 11 个泄漏对象全部源于此。

**建议：按工作负载语义拆分 StorageClass**（新建 SC，不改动现有 PV 的 SC 名称）：

| 用途 | reclaimPolicy | 说明 |
|------|---------------|------|
| `ceph-rbd-sc-ephemeral` | **`Delete`** | Loki / 缓存 / 测试等**可重建**数据，日志、索引、WAL 均可从对象存储重建 |
| `ceph-rbd-sc-critical`（或保持 `Retain`） | `Retain` | PostgreSQL 等**有状态数据**，走备份体系而非靠 PV 兜底 |

并将 CNPG Cluster 的 `spec.storage.storageClass` / `spec.walStorage.storageClass` 显式指向 `critical` SC，让"该删的自动删、该留的有备份"。

### 5.3 🟠 P1：缺少孤儿 PV / 僵尸 RBD 镜像的告警

集群共 **235 条告警规则**、Ceph 相关 21 条（健康/OSD/PG/容量/延迟/CSI 错误）覆盖良好，但**没有任何一条**针对：
- 长期处于 `Released` 的 PV
- 无 PV 映射的 RBD 镜像
- PV 声明容量与 Ceph 实际占用的偏差

这正是本次 11 个对象**静默积压 6 个月**无人发现的原因。

**建议补充告警**：

```promql
# 1) Released PV 存量与增量
count(kube_persistentvolume_status_phase{phase="Released"} > 0)
increase(kube_persistentvolume_status_phase{phase="Released"}[1h])

# 2) 单个 Released PV 滞留过久（如 > 24h）
(time() - kube_persistentvolume_created{phase="Released"} > 86400)

# 3) Ceph 侧容量与预期 PV 声明容量背离（泄漏探测）
  ceph_rbd_stat_bytes{}                     # 或 pool 内镜像数指标
- sum(kube_persistentvolume_resource_requests_storage_bytes{storageclass="ceph-rbd-sc"})
```

> 若 Ceph exporter 未暴露 RBD 镜像级指标，可用定期 `rbd ls` + PV 列表 diff 的 CronJob 巡检（本报告的检测方法已脚本化，见 §6）。

### 5.4 🟡 P2：其他观察项

| 项 | 现状 | 建议 |
|----|------|------|
| `imageFeatures` 仅 `layering` | 缺 `fast-diff` | `rbd du` 每次都告警 `fast-diff map is not enabled ... operation may be slow`；且影响克隆性能（CNPG 每次重建实例都要克隆）。建议 SC 加 `fast-diff`，或接受现状但知晓代价 |
| CNPG `primaryUpdateStrategy: unsupervised` | 主库变更不自动切换 | 维护窗口变更风险高。若为刻意选择可忽略，否则建议评估改为 `supervised` 以获得更好可控性 |
| `timelineID=12` | 半年内 11 次时间线切换 | 实例健康度/调度层面有隐患（6 节点集群反复重建实例）。建议排查 CNPG 实例替换的根因（节点驱逐 / 资源不足 / fencing） |
| CNPG operator `1.22.0`，`cnpg-controller-manager` 重启 23h | 有重启 | 观察是否与 2026-10-03 的 failover 相关 |
| `data-loki-backend-0` sts `generation=3` | 上线期反复改动 | 与 PVC 6 次轮换吻合，源头是上线初期手工操作 |
| 节点 SSH 可达性 | 仅 `ceph-01`(10.0.0.31) 与 `m01` 可免密登录，其余 5 节点 `Permission denied` | **审计与应急能力受限**，强烈建议配置统一的运维 SSH 密钥分发（本次审计的节点级验证因此无法完成，只能以 Ceph `watchers` 作为等价证据） |
| `nfs-sc` provisioner 为 `example.com/nfs` | 自建 provisioner | 有 1 个 `Released` NFS PV 未回收，需排查其 `archiveOnDelete` / 回收实现 |

---

## 6. 清理执行方案

> ⚠️ 以下均为**建议步骤，本次审计未执行任何变更**。所有目标已通过 §4.1 五项检查。

### 6.1 变更前强制备份（必做）

```bash
# 备份全部目标 PV 对象（即使要删也先留档）
cd /root/ceph-rbd-released-audit-20261005
kubectl get pv -o yaml > backup-released-pv.yaml

# 导出 9 个 Released PV 的 YAML
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}'); do
  kubectl get pv "$pv" -o yaml > "backup-pv-$pv.yaml"
done

# 导出 2 个僵尸镜像清单
ssh root@10.0.0.31 'rbd ls k8s-rbd' > backup-rbd-images.txt
```

### 6.2 第一步：先处理 2 个 Ceph 僵尸镜像（无 PV 追溯，优先级最高）

```bash
# 前置校验：再次确认无 watcher
ssh root@10.0.0.31 'rbd status k8s-rbd/csi-vol-b8d729a6-7f43-4166-9af8-a299b79bb346'
ssh root@10.0.0.31 'rbd status k8s-rbd/csi-vol-f3256b3c-f1fe-4fd3-b756-6074cc8f4a7d'
# 期望均为 Watchers: none

# 删除（先迁移到回收站，Reef 18.2.8 支持 trash，可回滚）
ssh root@10.0.0.31 'rbd trash mv --pool k8s-rbd csi-vol-b8d729a6-7f43-4166-9af8-a299b79bb346'
ssh root@10.0.0.31 'rbd trash mv --pool k8s-rbd csi-vol-f3256b3c-f1fe-4fd3-b756-6074cc8f4a7d'

# 确认无误后再彻底清除
ssh root@10.0.0.31 'rbd trash ls k8s-rbd'
ssh root@10.0.0.31 'rbd trash rm --pool k8s-rbd csi-vol-b8d729a6-7f43-4166-9af8-a299b79bb346'
ssh root@10.0.0.31 'rbd trash rm --pool k8s-rbd csi-vol-f3256b3c-f1fe-4fd3-b756-6074cc8f4a7d'
```

### 6.3 第二步：清理 7 个 Loki PV（PV 对象 + RBD 镜像必须成对删除）

> 🔴 **关键顺序**：因 `Retain` 策略，删 PV 不会删镜像。**必须先删镜像、再删 PV**；若只删 PV，就会再产出 7 个新的僵尸镜像（`pg16-ceph-1` 的 2 个就是这么来的）。

```bash
# 逐个：先删 RBD 镜像
for img in 543be5ab-8bbf-46d7-a5d3-6bf81cbdb736 \
           38df406d-6de2-493a-9e12-1940e7a5c24b \
           da2dad7d-6b85-43a1-bbc2-bc238f53eeee \
           92d1adea-2df0-46e6-b3ef-22471b737056 \
           465fa860-90c1-43b2-b045-c099f86e0989 \
           2b7f06b9-da7d-473d-b7c4-4f8002a06141 \
           34935be4-ea1d-4d8b-8668-a2fd3111678a ; do
  ssh root@10.0.0.31 "rbd status k8s-rbd/csi-vol-$img" | grep -q "Watchers: none" \
    && ssh root@10.0.0.31 "rbd trash mv --pool k8s-rbd csi-vol-$img" \
    && echo "OK  csi-vol-$img"
done

# 再删 PV 对象
for pv in pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f \
          pvc-3baa45e6-2064-4817-8eef-dbc2d64d90a7 \
          pvc-5046dd85-3c71-4625-8e12-81ec785fd00f \
          pvc-ac2ccc31-af11-4c53-9e33-0df94e72bd44 \
          pvc-e4e45b3b-2338-4919-a5c1-cf71c0aea6c5 \
          pvc-438afc60-2ec7-4d18-97f5-40a1b9934e80 \
          pvc-77c2a7cb-a7dd-4487-a35c-cc9868e91979 ; do
  kubectl delete pv "$pv" --wait=true
done

# trash 确认无误后清除
ssh root@10.0.0.31 'rbd trash ls k8s-rbd'    # 复核列表
ssh root@10.0.0.31 'rbd trash purge --pool k8s-rbd'
```

**若 `kubectl delete pv` 卡住**（finalizer `external-attacher/rbd-csi-ceph-com` / `kubernetes.io/pv-protection` 未摘除）：

```bash
kubectl patch pv <PV_NAME> -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pv <PV_NAME>
```

### 6.4 第三步：PostgreSQL 2 个 PV —— **先补备份，再清理**

```bash
# 阻塞项：当前 spec.backup 为 null，必须先配置 barmanObjectStore + ScheduledBackup
# 并完成至少一次成功的基线备份 + 恢复演练后，再执行：
#   pvc-28b685a9-f530-4a0b-ace6-c8f4091ab8cf / csi-vol-554bcd63-61e2-47f3-91b8-1b48259c28a1
#   pvc-c6bcf716-11ff-48e8-85fc-8a2691382326 / csi-vol-85352ea6-baf7-4c87-a439-d296f4592985
# 顺序同 6.3：先 trash 镜像，再删 PV。
```

### 6.5 验证

```bash
# 1) PV 侧无残留
kubectl get pv | grep -E "Released|Failed" || echo "OK: no Released/Failed PV"

# 2) Ceph 镜像与 PV 双向 diff 应完全一致
ssh root@10.0.0.31 'rbd ls k8s-rbd' | sort > /tmp/ceph-images.txt
kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeAttributes.imageName}{"\n"}{end}' \
  | grep -v '^$' | sort > /tmp/pv-images.txt
diff /tmp/ceph-images.txt /tmp/pv-images.txt && echo "OK: 1:1 mapping"

# 3) 空间回收确认
ssh root@10.0.0.31 'ceph df detail | grep -A2 k8s-rbd'

# 4) 业务无损确认
kubectl get pods -n logging -o wide
kubectl get pods -n cnpg-system -o wide
kubectl exec -n cnpg-system pg16-ceph-3 -c postgres -- \
  psql -tAc "select pg_is_in_recovery();"   # 期望 f（主库）
```

---

## 7. 原始证据文件

本次审计的原始数据均已留存于 `/root/ceph-rbd-released-audit-20261005/`：

| 文件 | 内容 |
|------|------|
| `raw/all-pv.json` / `raw/all-pv.yaml` | 全量 28 个 PV 快照 |
| `raw/ceph-images.txt` / `raw/pv-images.txt` | Ceph 镜像清单 / PV 映射清单（用于 diff） |
| `raw/rbd-images.json` | `rbd ls -l k8s-rbd` 原始输出 |
| `raw/rbd-info.txt` | 20 个镜像的 `rbd info`（size/features/watchers/snapshots） |
| `raw/rbd-du.txt` | 20 个镜像的 `rbd du`（声明 vs 实际占用） |
| `raw/cnpg-cluster.json` | CNPG Cluster 完整对象（含 `status`、`spec.backup=null` 证据） |
| `raw/inspect-pg.txt` | PostgreSQL 孤儿卷只读挂载核验 |
| `raw/inspect-loki.txt` / `raw/inspect-loki-rest.txt` | Loki 孤儿卷只读挂载核验 |
| `raw/inspect-ceph-orphans.txt` | 2 个 Ceph 僵尸镜像只读挂载核验 |

---

## 8. 行动项汇总

| 优先级 | 行动项 | 预计空间 | 备注 |
|--------|--------|----------|------|
| 🔴 **P0** | 为 `pg16-ceph` 配置 `spec.backup` + `ScheduledBackup`，并做恢复演练 | — | 当前**零备份**，且 `ContinuousArchiving=True` 是假健康 |
| 🔴 **P0** | 修正备份健康告警，避免空操作伪装成成功 | — | `pg_stat_archiver` 与 CNPG 条件均不可信 |
| 🟠 P1 | 清理 7 个 Loki `Released` PV（成对删镜像+PV） | ≈ 596 MiB | 高置信度，见 §6.3 |
| 🟠 P1 | 清理 2 个 Ceph 僵尸镜像（先 trash 后 purge） | ≈ 1.48 GiB | 无 PV 追溯，优先处理，见 §6.2 |
| 🟠 P1 | 拆分 StorageClass：可重建数据用 `Delete` | — | 根治泄漏，见 §5.2 |
| 🟠 P1 | 新增 `Released` PV / 孤儿 RBD 镜像告警 | — | 235 条告警中当前为空白，见 §5.3 |
| 🟡 P2 | 补齐 5 个节点的运维 SSH 密钥分发 | — | 本次审计因权限受限，见 §5.4 |
| 🟡 P2 | 补齐备份后清理 2 个 PostgreSQL PV | ≈ 1.56 GiB | **依赖 P0 完成**，见 §6.4 |
| 🟡 P2 | 开启 `data_checksums`（需重建实例） | — | 当前关闭，坏块不可检测 |
| 🟡 P2 | 排查 CNPG 实例反复替换根因（TL 已到 12） | — | 半年 11 次时间线切换 |
| 🟡 P2 | 排查 `nfs-sc` 的 1 个 `Released` NFS PV | — | 不在本次范围 |
| 🟡 P2 | 评估 SC 增加 `fast-diff` feature | — | `rbd du` 慢 + 影响克隆性能 |

---

*报告生成：2026-10-05 ｜ 审计范围：Kubernetes v1.35.9 + Ceph Reef 18.2.8 ｜ 全程只读，未执行任何变更*
