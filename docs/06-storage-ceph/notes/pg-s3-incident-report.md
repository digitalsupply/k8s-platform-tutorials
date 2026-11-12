# pg16-ceph-2 频繁重启 + tempo3 Block 落 S3 失败 —— 根因分析与修复方案

- 报告时间：2026-09-29 11:30 (+08)
- 备份目录：`/root/observability-upgrade-backup-20260929-111055-pg-s3-incident`
- 范围：`cnpg-system/pg16-ceph` 实例 2、`logging/tempo3` block-builder → Ceph RGW 写入路径
- 结论性质：**两个独立问题，无因果关系**（详见 §6 交叉验证）

---

## ⚡ 进展更新（报告出具后）

| 问题 | 状态 |
|---|---|
| 问题 1 `pg16-ceph-2` 重启 | ✅ **已修复完成** —— 归档 pgdata 后删除实例 + 2 个 PVC，CNPG 自动重建为 **`pg16-ceph-4`**，`pg_stat_replication` 确认 streaming，复制槽 `_cnpg_pg16_ceph_4` active，`pg_xact/0000` 恢复 8192 字节，n8n 库未受牵连 |
| 问题 2 tempo3 落 S3 失败 | ✅ **已根治（2026-09-29 16:xx）** —— 诊断反转：缺陷在 **Ceph RGW 17.2.8 服务端**（0 字节 aws-chunked 终止块签名校验拿 seed 当签名比对），**minio-go 无责**。通过 **Ceph 17.2.8 → 18.2.8 (reef) 三节点滚动升级**根治（修复在 18.2.5+）。升级后 0 字节直写 200、`meta.json` 落盘、read_errors 归零、`Tempo3BlockFlushFailing` 恢复、trace 可查询。兼容层代理（从未接流量）**已退役删除** |

**问题 2 的完整根因分析、诊断反转证据、代理设计与升级验证，见：**

# → [`/root/tempo3-s3-compat-report.md`](../../04-monitoring-gitops/notes/tempo3/tempo3-s3-compat-report.md)（§12 为最终结论）

**原「唯一未执行的变更」已取消**：无需改 tempo3 endpoint（保持直连 `10.0.0.31:7480`）；代理四件套已删除，备份在 `manifests/compat-*`。

---

## 0. 一句话结论

| # | 问题 | 根因 | 确定性 | 修复是否需要人工确认 |
|---|---|---|---|---|
| 1 | `pg16-ceph-2` 无限重启 | 数据卷 `pg_xact/0000`（CLOG 事务状态段）被截断为 **0 字节**，startup process 读事务 3047 状态失败 → 退出码 1 → 容器重启循环 | **高**（文件实测 + 错误日志逐字对应） | **是**（标准修法需删 PVC） |
| 2 | tempo3 Block 落 S3 失败 | **（已反转）** 根因在 **Ceph RGW 17.2.8**：0 字节 aws-chunked 终止块签名校验拿 seed（首签名）当终止块签名比对 → 必不等 → 400 `XAmzContentSHA256Mismatch`。minio-go v7.0.98 **无责**。修复在 RGW 18.2.5+ | **高**（pcap 逐字节 + 2×2 判别矩阵 + RGW 调试日志闭合） | ~~是（曾需代理）~~ **否**（已靠升级根治，代理退役） |

---

## 1. 问题 1：pg16-ceph-2 频繁重启

### 【变更】
本节**未做任何变更**，仅取证。

### 【原因】

PostgreSQL 16 的 CLOG（`pg_xact`）每个**段文件 256KB**（SLRU 段 = 32 个 8KB 页）记录事务状态；8KB 是页面大小，不是段大小。
`pg16-ceph-2` 的 `pg_xact/0000` 大小为 **0 字节**：

```
/var/lib/postgresql/data/pgdata/pg_xact/0000   0 字节    (mtime Jun 18 09:10)
```

对照组 `pg16-ceph-3`（健康 primary）同一文件：

```
/var/lib/postgresql/data/pgdata/pg_xact/0000   8192 字节  (mtime Sep 29 02:48)
```

启动日志逐字对应：

```
invalid record length at 1/A30000A0: expected at least 24, got 0
redo is not required
could not access status of transaction 3047
startup process (PID 299) exited with exit code 1
terminating any other active server processes
shutting down due to startup process failure
```

即：startup process 无法从 CLOG 读出事务 3047 的状态 → 主动退出 → 容器 `Completed exit=0` → kubelet 重启 → 无限循环。

### 【实际执行 / 验证结果】

| 事实 | 值 | 取证方式 |
|---|---|---|
| 重启次数 | 110 | `containerStatuses[0].restartCount` |
| 上次终止 | `reason=Completed exit=0`，`02:49:47Z` | `lastState.terminated` |
| 磁盘是否满 | **否**，9.8G 卷仅用 44M | Pod 内 `df -h` |
| 数据最后完整时刻 | **2026-06-18 09:10** | `custom.conf`/`pg_hba.conf`/`pg_xact/0000` 全部同一秒 mtime |
| `base/` 来源 | mtime `May 9 11:31`，与 pg-3 创建时刻一致；卷内同时存在 `cnpg_initialized-pg16-ceph-3` | `ls -la pgdata` |
| 数据库系统标识 | 两实例一致 `7624451931059040276` | 日志 grep |
| 集群状态 | `phase=Failing over`，`Ready=False`，`currentPrimary=targetPrimary=pg16-ceph-3` | CR status |
| pg-3 健康度 | `is_in_recovery=false`（真 primary），WAL 归档 224 成功 / 0 失败 | psql 进真库实测 |
| **实际复制状态** | `pg_stat_replication` **0 行** —— 自 6 月起从未有流复制 | psql |
| 复制槽 | `_cnpg_pg16_ceph_2` `active=false restart_lsn=-`（从未使用，不保留 WAL） | psql |
| WAL 卷占用 | 577M / 4.9G (12%) —— **无磁盘压力风险** | `df -h` |
| 备份 | **无任何 Backup / ScheduledBackup** | `kubectl get backup` |
| 库内容 | `postgres` 7.6MB、`n8n` 13MB、`mytest` 7.7MB，0 张用户表 | psql |
| **业务依赖** | **n8n**（告警 webhook 接收端）`DB_POSTGRESDB_HOST=pg16-ceph-rw.cnpg-system.svc.cluster.local` / `DB= n8n` | Deployment env |

### 【风险】
- **n8n 单点**：n8n 依赖本集群且自身健康，但它跑在一个**没有副本**的 primary 上。pg-3 一旦故障，告警投递链路（`n8n-webhook` receiver）随之失效。
- HA 已缺失约 **103 天**（6/18 至今），期间无人察觉（该 ns 无相关告警）。
- 崩溃循环本身消耗 CPU 与 RBD I/O。

### 【修复方案】（均需人工确认后才执行）

**方案 A（推荐）— 重建副本**：让 CNPG 删除故障实例（Pod + 2 个 PVC），operator 自动用 `pg_basebackup` 从 pg-3 重建。
- 前置确认：pg-3 是唯一数据源且健康 ✅；无备份可回退，但**故障实例本身无可保留数据**（未完成复制，0 用户表）
- 代价：重建期间集群单副本运行
- ⚠️ 涉及**删除 PVC**（`pg16-ceph-2`、`pg16-ceph-2-wal`）→ 属禁止清单，需明确授权

**方案 B — `spec.instances` 2→1→2**：由 CNPG 自行摘除并重建。
- 同样删除 PVC；且中间有一段 0 副本窗口
- 期间 n8n 短暂无 HA

**方案 C（不推荐，仅备选）— 手工补 8192 字节 `pg_xact/0000` 让 postgres 起得来**
- 可行性存疑（CLOG 内容非全零即为伪造），且起来的是一个 CLOG 不可信的副本
- 不解决"为何文件被截断"这一根因

### 【回滚方式】
- 方案 A/B 本身即修复动作，无"回滚"概念；若重建后新实例异常，保留故障卷备份后再次删除重建
- 建议执行前把 `pg16-ceph-2` 与 `pg16-ceph-2-wal` 两个 RBD 镜像做快照留档（本轮未做）

---

## 2. 问题 2：tempo3 Block 落 S3 持续失败

> **【2026-09-29 最终定论】本节原因分析已被后续证据推翻。**
> 抓包字节本身真实（§2 的 pcap 逐字节还原是对的），但**解读错误**：那个"86 字节帧"并非 minio-go 畸形，
> 而是**合法的双层分帧**（HTTP chunked 包 aws-chunked）。真正的缺陷在 **RGW 17.2.8 服务端**校验终止块签名时
> 拿 seed（首签名）当终止块签名比对 → 必不等 → 400。已通过 **Ceph 升级 18.2.8** 根治（修复在 18.2.5+）。
> minio-go v7.0.98 经 aws-cli 逐字节比对无责。以下 §2 内容保留为当时的取证过程存档。

### 【变更】
- 本节**未改任何 tempo3 配置**
- 我曾对 `nocompact.flg` 做过 2 次写入测试（0 字节 / 16 字节），**已恢复为 0 字节**（ETag `d41d8cd9…` = 空内容 MD5）
- 抓包 Pod `lgmt-capture` 与配置探针 Pod `lgmt-tprobe` 已删除，临时文件已清理

### 【原因】

tempo3 对 S3 的写入由其内置 **minio-go v7.0.98** 完成（抓包 `User-Agent: MinIO (linux; amd64) minio-go/v7.0.98`），
对所有 PUT 使用 AWS **流式签名 v4**（`X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD`）+ chunked 分块编码。

**非空对象 —— 编码正确**（`index`，42 字节，写入成功）：

```
2a;chunk-signature=89763cb6…c912\r\n      ← 长度头带分块签名
{"rowGroups":["W47/95gDgQPSabYzgT/WHQ=="]}\r\n   ← 42 字节真实数据
0;chunk-signature=6c09acb0…4eea3\r\n      ← 正常终止块
\r\n
```

**0 字节对象 —— 编码损坏**（`nocompact.flg`，写入失败）：

```
56\r\n                                    ← 裸长度头，缺少 ;chunk-signature=
0;chunk-signature=3414e66b…659a\r\n       ← 这 86 字节 ASCII 文本被当作【载荷】发出
\r\n
0\r\n\r\n                                 ← 终止块
```

即 minio-go 在空载荷分支把"终止块签名"当成了正文发出。
服务端因此收到 **86 字节**正文，而请求头声明 `X-Amz-Decoded-Content-Length: 0`：
RGW 按实际收到的 86 字节算 hash，客户端按 0 字节声明 → 必然不等 →

```
error copying block from local to remote backend, error writing object to s3 backend,
object single-tenant/b1fc56f5-…/nocompact.flg:
The provided 'x-amz-content-sha256' header does not match what was computed.
```

**为什么只有 `nocompact.flg` 失败**：一个 block 里只有它是 0 字节。
`data.parquet`(29780B)、`bloom-0`(102424B)、`index`(42B) 均非空，编码正确 → 全部写入成功。

### 【实际执行 / 验证结果】

**正向确认写入链路本身健康**（用 tempo3 自己的 AK/SK，经 aws-cli）：

| 操作 | 结果 |
|---|---|
| `list-objects-v2` | 200，列出 9 个对象 |
| `put-object .lgmt-writetest` | 200，ETag `62cbce0c…` |
| `put-object nocompact.flg`（0 字节） | 200，ETag `d41d8cd9…` |
| `put-object nocompact.flg`（16 字节） | 200，ETag `b14ad2b9…` |
| `create-multipart-upload` / `abort` | 成功 |

**已排除的假设**（逐项实测，非推断）：

| 假设 | 排除依据 |
|---|---|
| 凭据 / AK-SK 不配对 | 同一把 key 经 aws-cli 写入成功 |
| RGW 端点 / 权限 / 桶策略 | list + put + head 全部 200 |
| 与对象内容（空/非空）相关 | 空与非空两种 `nocompact.flg` 均可被 aws-cli 写入 |
| 与配置变更相关 | 失败自 2026-09-28 21:11 起，早于本轮任何操作 |
| RGW 侧故障 | 同桶同凭据的其它对象持续写入成功（`LastModified` 每 ~10s 刷新） |

**失败仍在持续**（未自愈）：

| 事实 | 值 |
|---|---|
| 起始时间 | bb-2 `2026-09-28 21:11`；bb-0 `2026-09-29 02:23` |
| 当前速率 | 20s 内末尾 2000 行新增 250 条（`last ts` 持续前移） |
| 计数器 | `tempo_ingest_storage_reader_read_errors_total`：bb-0 = **45134**，bb-2 = **5860** |
| 告警 | `Tempo3BlockFlushFailing` **firing** |
| 重试抓包 | 75s 内 535 次 `PUT …/nocompact.flg` = **428 次/分**；每轮还伴随 3 次成功 PUT + 2 次 `GET meta.json` / `GET meta.compacted.json` |
| 桶内对象 | 共 9 个，**无任何 `meta.json`** |

### 【实际影响（已修正的早期判断）】

✅ **确认成立**：flush 循环永远走不完 → `consumeCycle failed` → `meta.json` 从不写入
→ **block 永远进不了 blocklist** → **至今没有任何一个 trace block 可被查询**，
数据只存在于 live-store 内存中，重启即丢。同时以 ~428 次/分 持续对 RGW 发起无效写入。

❌ **已撤回的错误结论**：我在排查中一度判定"旧 span 被反复覆写销毁 = 真实数据丢失"。
**该结论错误**，源于采样竞态（块以 7 次/秒被覆写，`head-object` 与 `get-object` 落在不同时刻）。
25 秒间隔两次下载 `data.parquet` 逐字节比对：**29780 字节，0 字节差异**。
块内容稳定、无损。重复上传是**纯浪费的写放大**（29.7KB × 7/s/块），不是数据丢失。

### 【修复方案】

> **【2026-09-29 已执行并退役】** 下表曾判定"兼容层代理是唯一可行"。实际最终方案是 **Ceph 升级 17.2.8 → 18.2.8**（修复在 18.2.5+），代理方案作废并已退役删除。

| 方案 | 状态 | 说明 |
|---|---|---|
| `signature_version2: true` | ❌ 已离线证伪 | 探针 Pod 跑 `/tempo -config.verify` → `field signature_version2 not found in type s3.Config`，Tempo 3.0.3 不支持该字段 |
| 关闭 `nocompact.flg` 写入 | ❌ 不存在 | 通读 `tempo.yaml` 全文（live_store / block_builder / storage 段），无任何相关开关 |
| 升级 tempo3 镜像 | ❌ 不可行 | **无外网**：`docker.io` / `registry-1.docker.io` 均 HTTP `000`；且无法确认哪个版本修复 |
| **升级 Ceph 17.2.8 → 18.2.8 (reef)** | ✅ **已执行根治** | RGW 终止块校验缺陷仅 18.2.5+ 修复；Ceph 节点有外网，cephadm 滚动升级 ~40 分钟 |
| ~~兼容层代理~~ | ❌ 已退役 | 部署后从未接流量，升级根治后删除 |

### 【风险】
> **（过时，针对已退役的代理方案。升级后实际遇到的风险见 §5/总报告 §7 记录：中途 ceph-03 镜像拉取抖动 + OSD 逐台重启短暂 degraded，均无数据影响）**
- ~~代理进入 tempo3 全部 S3 写入的关键路径，且**进程内持有 secret key** —— 单点与凭据暴露面~~
- ~~tempo3 ConfigMap 变更会触发组件滚动重启（查询侧短暂不可用）~~
- ~~若代理透传逻辑有缺陷，可能放大为写入侧故障（因此必须先离线用真实畸形样本回归）~~

### 【回滚方式】
> **（过时，针对已退役的代理方案。升级本身无回退路径，备份留证于 `/root/observability-upgrade-backup-20260929-154623/ceph-upgrade/`）**
- ~~ConfigMap 改回 `endpoint: 10.0.0.31:7480`（已备份于 `pre-state/tempo3-config.yaml`）→ 回到当前状态~~
- ~~删除 Deployment + Service~~
- ~~恢复后行为与本轮开始时完全一致（失败持续，无新增损害）~~

---

## 3. 交叉验证：两个问题是否相关

| 检验 | 结果 |
|---|---|
| 是否同一 Ceph | **是**。两者是同一套 Ceph（mon `10.0.0.31/41/51`，clusterID `594e535e-…`），只是访问路径不同：PG 走 RBD（pool `k8s-rbd`），tempo3 走 RGW（`10.0.0.31:7480`）。原判断"不是同一个 Ceph"把"不同接入方式"当成了"不同集群" |
| 时间关联 | 否。PG 自 6/18 起坏；S3 失败自 9/28 21:11 起 |
| 数据关联 | 否。PG 库为 `postgres/n8n/mytest`，tempo3 用 Kafka + RGW，不经 PG |
| 同为"存储层" | 仅为表象相似：PG 是**文件被截断**，tempo3 是**客户端编码错误**，无共同成因 |

---

## 4. 本轮自检与纠错记录

| # | 失误 | 发现方式 | 处置 |
|---|---|---|---|
| 1 | 手写 SigV4 两次都签名错误（`canon_headers` 尾部多换行；`%s` 占位符个数不匹配），误把 403 `SignatureDoesNotMatch` 当作 RGW 证据 | 改用 aws-cli 后全部 200 | 弃用手写签名，改用成熟客户端；结论作废 |
| 2 | `CM` 用 `jsonpath='{.data.config\.yaml}'` 取值为空，误判"AK 指纹不一致" | 实际 key 是 `tempo.yaml` | 修正后 AK/SK 指纹与 live 文件一致 |
| 3 | **误判"块内容被覆写 = 数据丢失"** | 25s 间隔两次下载逐字节比对，0 差异 | 已撤回，见 §2 |
| 4 | **误判"chunk 长度声明 86 / 实际 82，长度不符"** | 精确解析后长度自洽，真正差异在 size_line 缺分块签名 | 已撤回并给出正确根因 |
| 5 | 抓包文本化（tcpdump `-A`）把 `\r` 渲染成 `.`，无法还原 chunk 边界 | 改抓 pcap 并按 TCP 序列号重组 | 拿到精确字节 |
| 6 | 重组时未按 seq 排序，落到错误 TCP 流（`含PUT=False`） | 枚举全部 4 条流并逐条判定 | 命中承载 PUT 的流 |
| 7 | 凭据 AK 明文可能随抓包落盘 | 落盘即 `sed` 脱敏，并**回读校验落盘文件中明文 AK 出现次数 = 0** | 合规 |
| 8 | 探针 Pod `lgmt-tprobe` 未等到 `Succeeded`（超时） | 直接读日志已拿到校验输出 | 已删除 |
| 9 | `tempo_live_store_local_*` 系列指标全为 0，容易误判"无失败" | 改用真实指标 `tempo_ingest_storage_reader_read_errors_total` | 告警链路已验证 firing |

**遗留副作用自查**：我写入的 `nocompact.flg` 测试内容已复原为 0 字节；
`nocompact.flg` 在 tempo3 成功写入前会一直保持该状态（对该 marker 语义等价）。
抓包 Pod、探针 Pod、ConfigMap、临时文件均已清理。

---

## 5. 下一步（遗留事项）

> **【2026-09-29 更新】问题 2 已根治，原 P0 项取消。** 详见下表。

| 优先级 | 事项 | 状态 |
|---|---|---|
| ~~P0~~ | ~~问题 2 endpoint 翻转接入兼容层~~ | **已取消** —— Ceph 升级 18.2.8 根治，tempo3 保持直连 `10.0.0.31:7480`，代理退役 |
| P1 | 问题 1 副本重建 | ✅ 已完成（`pg16-ceph-4` streaming 正常） |
| P1 | 补 `pg16-ceph` 监控：`cnpg-system` namespace 零告警，103 天静默与本次故障同源 | ⭕ 遗留未动 |
| P2 | 补 Collector 侧"指标消失"规则、`loki`/`tempo` 数据源纳入 provisioning、tempo3 业务看板 | ⭕ 遗留未动 |

---

## 6. 备份内容

`/root/observability-upgrade-backup-20260929-111055-pg-s3-incident/`

```
pre-state/cnpg-cluster-pg16-ceph.yaml    CNPG Cluster CR 全量（方案 A/B 回滚基准）
pre-state/pg-pods.yaml                   pg16-ceph-2/3 Pod 全量
pre-state/pvcs.yaml                      cnpg-system 全部 PVC
pre-state/tempo3-config.yaml             tempo3 ConfigMap 全量（含 S3 段，密钥不外显）
pre-state/tempo3-config-PREFLIP.yaml     endpoint 翻转前完整快照（1 行变更的回滚源）
pre-state/tempo3-alerts-rule.yaml        tempo3 告警规则
pre-state/{logging-pods,cnpg-pods}.txt   Pod 列表基线
pre-state/bb0-ip.txt                     block-builder-0 PodIP
pg16-ceph-2-pgdata.tar                   故障实例 pgdata 归档 46,735,360 字节（内含 0 字节的 pg_xact/0000，根因实物证据）
manifests/capture-pod.yaml               抓包 Pod（已删除，仅存档）
manifests/compat-{configmap,secret,workload}.yaml  兼容层代理三件套（已落线）
evidence/tcpdump-bb0-rgw.txt             75s 抓包（已脱敏，明文 AK 校验为 0）
evidence/nocompact-replay.pcap           真实畸形请求原始字节（离线回归样本）
```
