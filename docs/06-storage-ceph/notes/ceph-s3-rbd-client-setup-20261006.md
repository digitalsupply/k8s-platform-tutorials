# 在 10.0.0.61 上部署 S3 / Ceph 客户端并验证 Ceph RBD 与对象存储

- **执行时间**：2026-10-06 16:40 – 16:55 (CST)
- **执行主机**：`m01` / **10.0.0.61**（Rocky Linux 9.6，x86_64，root）
- **关联文档**：`ceph-rbd-released-pg-backup-implementation-20261005.md`（PG 备份体系落地报告）
- **目标**：不依赖 K8s Pod，直接在 10.0.0.61 上用 `aws` / `s3cmd` / `ceph` / `rbd` 查看备份对象与 RBD 镜像
- **状态**：✅ 安装完成，读写权限、RBD、RGW 三类验证全部通过

---

## 1. 起点：本机原有能力和缺口

| 工具 | 部署前状态 | 用途 |
|------|-----------|------|
| `aws` CLI v2 (2.15.31) | ✅ 已有 `/usr/bin/aws` | S3 读写（走 RGW） |
| `s3cmd` | ❌ 缺失 | S3 读写、`ls -r` 递归清单 |
| `ceph` / `rbd` / `radosgw-admin` | ❌ 缺失 | 集群状态、RBD 镜像、RGW 用户与配额 |
| `/etc/ceph/ceph.conf` + admin keyring | ❌ 缺失（仅备份目录里有一份） | Ceph 客户端认证 |
| S3 凭据文件 | ❌ 缺失 | 访问 `pg-backups` / `loki-*` / `tempo-traces` |

网络连通性先做了确认（全部可达）：

```
10.0.0.31:6789  OPEN   mon
10.0.0.31:3300  OPEN   mon (v2)
10.0.0.41:6789  OPEN   mon
10.0.0.51:6789  OPEN   mon
10.0.0.31:7480  OPEN   RGW (http 200)
10.0.0.41:7480  OPEN   RGW (第二个 RGW 实例)
```

---

## 2. 安装步骤

### 步骤 1：安装 s3cmd（EPEL）

```bash
dnf install -y s3cmd
# → s3cmd-2.4.0-14.el9.noarch
s3cmd --version
# → s3cmd version 2.4.0
```

### 步骤 2：添加与集群同版本的 Ceph 客户端仓库并安装 ceph-common

集群实际版本（来自 `observability-upgrade-backup-20260929-154623/ceph-upgrade/versions.json` 与 `ceph -s`）：

```
ceph version 17.2.8 (f817ceb7...) quincy (stable)   # mon/mgr/osd/mds/rgw 全部 17.2.8
```

因此仓库选用 **Quincy 17.2.8 / EL9**（客户端与集群主版本对齐，避免 mon 协议/特性不匹配）：

```bash
cat > /etc/yum.repos.d/ceph-quincy.repo <<'EOF'
[ceph-quincy]
name=Ceph Quincy 17.2.8 for EL9 (matches cluster version)
baseurl=https://download.ceph.com/rpm-17.2.8/el9/x86_64
enabled=1
gpgcheck=1
type=rpm-md
gpgkey=https://download.ceph.com/keys/release.asc
EOF

dnf install -y ceph-common
# → ceph-common-2:17.2.8-0.el9.x86_64
#   连带安装 librados2 / librbd1 / librgw2 / python3-rbd / python3-rgw 等
```

安装后可用命令：

```
/usr/bin/ceph          /usr/bin/rbd          /usr/bin/radosgw-admin
```

> 说明：`ceph-volume` 属于部署工具（cephadm/ceph-volume 包），客户端验证不需要。

### 步骤 3：部署 Ceph 配置与 admin keyring

密钥来源：`/root/observability-upgrade-backup-20260929-154623/ceph-upgrade/`

```bash
install -m 644 /root/observability-upgrade-backup-20260929-154623/ceph-upgrade/ceph.conf \
               /etc/ceph/ceph.conf
install -m 600 -o root -g root \
               /root/observability-upgrade-backup-20260929-154623/ceph-upgrade/ceph.client.admin.keyring \
               /etc/ceph/ceph.client.admin.keyring
```

`/etc/ceph/ceph.conf` 内容（fsid + 3 个 mon）：

```ini
[global]
	fsid = 594e535e-d82c-11f0-afa7-bc24112b746f
	mon_host = [v2:10.0.0.31:3300/0,v1:10.0.0.31:6789/0] \
	           [v2:10.0.0.41:3300/0,v1:10.0.0.41:6789/0] \
	           [v2:10.0.0.51:3300/0,v1:10.0.0.51:6789/0]
```

`ceph.client.admin.keyring` 权限 **600**（内含 admin secret，等同集群最高权限）。

### 步骤 4：AWS CLI 凭据与配置（多 profile）

`/root/.aws/config`：

```ini
[default]
region = us-east-1
output = json
s3 =
    addressing_style = path
endpoint_url = http://10.0.0.31:7480

[profile pg-backup]      ; CNPG 备份专用（本次报告主体）
[profile loki-admin]     ; Loki chunks/ruler
[profile tempo]          ; Tempo traces
# 三个 profile 均为同样的 region / path 寻址 / endpoint_url
```

`/root/.aws/credentials`（权限 600）：

```ini
[default]        # 与 pg-backup 同一对 key，`aws s3` 不带 --profile 即操作备份桶
[pg-backup]
[loki-admin]
[tempo]
```

要点：

- **`addressing_style = path`**：RGW 端点是裸 IP（`10.0.0.31:7480`），虚拟主机式 `bucket.10.0.0.31` 无法解析，必须走 path 式。
- **`endpoint_url` 写进 config**：AWS CLI v2 ≥ 2.13 支持（本机 2.15.31），因此命令行**无需**再带 `--endpoint-url`。
- `region` 用 `us-east-1`：RGW 不校验 region 名，仅用于 SigV4 签名串。

### 步骤 5：s3cmd 配置（两份）

`/root/.s3cfg`（pg-backup 用户，默认配置）与 `/root/.s3cfg-loki`（loki-admin 用户），均 600：

```ini
[default]
host_base = 10.0.0.31:7480
host_bucket = 10.0.0.31:7480     # 不含 %(bucket)s → 强制 path 式请求
use_https = False
access_key = <20 位 RGW access key>
secret_key = <40 位 RGW secret key>
signature_v2 = False             # RGW 支持 SigV4，必须用 v4
cloudfront_host = 10.0.0.31:7480
```

---

## 3. 密钥与凭据清单

| 用途 | 凭据 | RGW 用户 | 密钥来源文件 | 落地位置（均 600） |
|------|------|----------|--------------|--------------------|
| PG 备份（`s3://pg-backups`） | `<redacted-s3-access-key>` / `<redacted>` | `pg-backup` | `ceph-rbd-released-pg-backup-implementation-20261005.md` §2 步骤3 | `~/.aws/credentials`（default、pg-backup）、`~/.s3cfg` |
| Loki（`loki-chunks`、`loki-ruler`、`loki-admin`） | `<redacted-s3-access-key>` / `<redacted>` | `loki-admin` | `observability-upgrade-backup-20260928-172244/phase2/loki-values-all.yaml`、`…/secrets/logging-secrets.yaml`（base64 已核对一致） | `~/.aws/credentials`（loki-admin）、`~/.s3cfg-loki` |
| Tempo（`tempo-traces`） | `<redacted-s3-access-key>` / `<redacted>` | tempo 用户 | `…/phase2/tempo-values-all.yaml` | `~/.aws/credentials`（tempo） |
| Ceph 集群管理 | admin keyring `<redacted-ceph-key>` | `client.admin` | `observability-upgrade-backup-20260929-154623/ceph-upgrade/ceph.client.admin.keyring` | `/etc/ceph/ceph.client.admin.keyring` |

> 所有密钥均为集群既有凭据，**本次未新建任何账号**，只做了本地落地；`chmod 600` 后仅 root 可读。

---

## 4. 验证结果

### 4.1 S3：aws CLI（profile = pg-backup / default）

```bash
aws s3 ls
# 2026-10-05 21:37:43 pg-backups          ← 该用户仅可见自己的桶（最小权限生效）

aws s3 ls s3://pg-backups/
# PRE pg16-ceph/

aws s3 ls s3://pg-backups/pg16-ceph/base/
# PRE 20261005T134311/        ← 首次（10-05 演练）备份
# PRE 20261006T020002/        ← 今天凌晨 02:00 定时任务自动生成 ✅ 定时链路在跑

aws s3 ls s3://pg-backups/ --recursive | wc -l
# 111

aws s3 ls s3://pg-backups/ --recursive --summarize | tail -2
# Total Objects: 111
#    Total Size: 19409482          (18.5 MiB)
```

读取最新一次备份的元数据（证明对象可完整下载）：

```bash
aws s3 cp s3://pg-backups/pg16-ceph/base/20261006T020002/backup.info -
# START WAL LOCATION: 4/B2014090 (file 0000000D00000004000000B2)
# BACKUP FROM: standby
# START TIMELINE: 13
# copy_stats={'total_time': 12.93 ...}
# data_checksums=off            ← 与原报告 §7 遗留项一致，仍为 off
```

**写权限 round-trip 测试**（写入 → 列出 → 删除 → 确认清空，未留下垃圾对象）：

```bash
aws s3 cp /tmp/_s3test.txt s3://pg-backups/_client-verify/m01.txt   # Completed
aws s3 ls s3://pg-backups/_client-verify/                            # m01.txt
aws s3 rm s3://pg-backups/_client-verify/m01.txt --recursive         # delete
aws s3 ls s3://pg-backups/                                           # 仅剩 pg16-ceph/ ✅
```

其他 profile：

```bash
aws s3 ls --profile loki-admin   # loki-admin / loki-chunks / loki-ruler
aws s3 ls --profile tempo        # tempo-traces
```

### 4.2 S3：s3cmd

```bash
s3cmd ls                              # s3://pg-backups
s3cmd ls -r s3://pg-backups/          # 逐对象列出 base/ 与 wals/
s3cmd info s3://pg-backups/
#   Location:  my-zg
#   ACL: CloudNativePG Backup: FULL_CONTROL
s3cmd -c /root/.s3cfg-loki ls         # loki-admin / loki-chunks / loki-ruler
```

`ls -r` 摘要（10-06 备份已出现）：

```
2026-10-05 13:43      6641433  s3://pg-backups/pg16-ceph/base/20261005T134311/data.tar.gz
2026-10-06 02:00      6848144  s3://pg-backups/pg16-ceph/base/20261006T020002/data.tar.gz
2026-10-05 13:39        62924  s3://pg-backups/pg16-ceph/wals/0000000C00000004/…0063.gz
...（WAL 已推进到 0000000D00000004000000CB.gz，最近一条 10-06 16:44）
```

> WAL 持续推进到当前时刻 ⇒ **归档链路实时正常**，不只是"有历史备份"。

### 4.3 Ceph / RBD（admin keyring）

```bash
ceph -s
# health: HEALTH_OK
# mon: 3 daemons quorum ceph-02,ceph-03,ceph-01
# mds: 1/1 up + 2 standby；osd: 6 up/in；rgw: 2 daemons active
# pools: 15, objects: 14.28k, 15 GiB used / 164 GiB avail
# pgs: 465 active+clean

ceph osd lspools
# 41 my-zone.rgw.buckets.index
# 42 my-zone.rgw.buckets.data
# 43 rbd              ← 空池
# 44 k8s-rbd          ← K8s PVC 实际使用
# 13/14 cephfs_metadata / cephfs_data

rbd ls -p k8s-rbd -l
# 11 个 csi-vol-* 镜像（1/5/10/20 GiB 不等）

rbd du -p k8s-rbd
# <TOTAL>  91 GiB 虚拟 / 4.6 GiB 实际占用

rbd info k8s-rbd/csi-vol-cdfecb4f-0acb-442b-a845-fa28cd25f2eb
# size 20 GiB in 5120 objects, format 2, features layering, snapshot_count: 0

ceph fs ls
# name: cephfs, metadata pool: cephfs_metadata, data pools: [cephfs_data]

radosgw-admin user info --uid=pg-backup     # key/caps/op_mask 与报告一致
radosgw-admin bucket stats --bucket=pg-backups
# 111 objects / 19,409,482 bytes（与 aws --summarize 完全一致）
```

本机 `rbd showmapped` 为空 —— 10.0.0.61 **没有**本地映射的 RBD 设备（也不应有，K8s 节点映射走 cephcsi），属预期。

---

## 5. 本次验证中发现的问题（需要你决策）

### 🟠 1. `pg-backup` 用户配额**并未生效**

原报告 §2 步骤 3 记录了 `radosgw-admin quota set --uid=pg-backup --max-size 20G --max-objects 100000`，但实测：

```bash
radosgw-admin user info --uid=pg-backup
# "bucket_quota": { "enabled": false, "max_size": -1, "max_objects": -1 }
# "user_quota":   { "enabled": false, "max_size": -1, "max_objects": -1 }
```

即 **20 GB / 10 万对象的保护不存在**，备份一旦膨胀无人设限。当前用量仅 18.5 MiB，风险低但应在近期补上：

```bash
radosgw-admin quota set --uid=pg-backup --quota-type=user --max-size 20G --max-objects 100000
radosgw-admin quota enable --uid=pg-backup --quota-type=user
```

> 本次**未执行**（属于对生产用户策略的变更，等你确认）。

### 🟡 2. 版本表述不一致

原报告写"RGW 版本（Reef 18.2.8 的 `radosgw-admin`）"，但 `versions.json`、`ceph -s` 与本机新装客户端均为 **Quincy 17.2.8**（mon/mgr/osd/rgw 全部 17.2.8）。本次按 17.2.8 装客户端，功能验证全部通过。建议以后以 `ceph versions` 输出为准。

### 🟡 3. 备份桶里有一个 `.partial.gz` 残留

```
s3://pg-backups/pg16-ceph/wals/0000000C00000004/0000000C0000000400000068.partial.gz   47,996 bytes
```

`.partial` 是 barman 归档未完成的中间文件（10-05 时间线切换瞬间产生），不影响恢复（正式的 `…0068.gz` 也在），但可在下次巡检时删除。

### ✅ 4. 定时备份已在 10-06 02:00 自动触发

`20261006T020002` 备份完成（12.9 秒，`BACKUP FROM: standby`），证明 `ScheduledBackup` 不是一次性的，`retentionPolicy: 30d` 之下的持续链路正常。

---

## 6. 常用命令速查（10.0.0.61 上直接可用）

```bash
# ---- S3 / 对象存储 ----
aws s3 ls                                            # 我能看见哪些桶（pg-backup）
aws s3 ls s3://pg-backups/                           # 桶内层级
aws s3 ls s3://pg-backups/ --recursive --summarize   # 全量清单 + 总量
aws s3 cp s3://pg-backups/pg16-ceph/base/<ID>/backup.info -   # 看某次备份元数据
aws s3 cp s3://pg-backups/.../data.tar.gz /tmp/      # 下载恢复用
aws s3 ls --profile loki-admin                       # Loki 桶
aws s3 ls --profile tempo                            # Tempo 桶

s3cmd ls -r s3://pg-backups/                         # 等价清单（递归）
s3cmd info s3://pg-backups/                          # 位置/ACL/版本化
s3cmd -c /root/.s3cfg-loki ls                        # 切换到 loki 凭据
s3cmd du s3://pg-backups/                            # 桶用量

# ---- Ceph 集群 ----
ceph -s                       ceph df               # 集群与容量
ceph osd lspools              ceph fs ls
ceph health detail            ceph versions

# ---- RBD ----
rbd ls -p k8s-rbd -l                                # K8s 卷镜像清单
rbd du -p k8s-rbd                                   # 虚拟/实际占用
rbd info k8s-rbd/<image>                            # 单镜像详情
rbd snap ls k8s-rbd/<image>                         # 快照（csi 快照）
rbd showmapped                                      # 本机是否 map 了镜像

# ---- RGW 管理侧 ----
radosgw-admin user info --uid=pg-backup
radosgw-admin user stats --uid=pg-backup
radosgw-admin bucket stats --bucket=pg-backups
radosgw-admin zonegroup list
```

**临时改用其他端点**（例如备用 RGW `10.0.0.41:7480`）：

```bash
aws s3 ls --endpoint-url http://10.0.0.41:7480
s3cmd --host=10.0.0.41:7480 --host-bucket=10.0.0.41:7480 ls
```

---

## 7. 安全与维护说明

1. **权限**：`/root/.aws/credentials`、`/root/.s3cfg*`、`/etc/ceph/ceph.client.admin.keyring` 均 `600 root:root`。admin keyring 可读写整个集群，不要复制到非必要主机。
2. **吊销**：如需作废某组凭据，`radosgw-admin user rm --uid=<uid>` 或 `radosgw-admin key rm --uid=<uid>`；本地同步删除对应 profile 即可。
3. **未新增账号**：本次全部复用既有 RGW 用户与 admin keyring，不引入新的权限面。
4. **清理**：
   ```bash
   rm -f /root/.aws/config /root/.aws/credentials /root/.s3cfg /root/.s3cfg-loki
   rm -f /etc/yum.repos.d/ceph-quincy.repo
   dnf remove -y s3cmd ceph-common       # 如需完全还原
   ```
5. **证书/明文**：RGW 走 HTTP（7480），密钥与数据在内网明文传输 —— 与集群现状一致，属于已知遗留项（原报告 §7 未覆盖），如需加密需先给 RGW 配 TLS。

---

## 8. 本次变更清单

| 类型 | 对象 | 说明 |
|------|------|------|
| 新增文件 | `/etc/yum.repos.d/ceph-quincy.repo` | Ceph 17.2.8 EL9 客户端仓库 |
| 新增文件 | `/etc/ceph/ceph.conf`、`/etc/ceph/ceph.client.admin.keyring` | 从既有备份目录复制，keyring 600 |
| 新增文件 | `/root/.aws/config`、`/root/.aws/credentials` | 4 个 profile，credentials 600 |
| 新增文件 | `/root/.s3cfg`、`/root/.s3cfg-loki` | s3cmd 双凭据，600 |
| 新增软件 | `s3cmd-2.4.0-14.el9`、`ceph-common-17.2.8` | dnf 安装，连带 librados/librbd/python3-rbd 等 |
| 集群侧 | **无任何变更** | 未建用户、未建桶、未改配额；测试对象已删除 |
| K8s 侧 | **无任何变更** | 未触碰 CNPG/Secret/ScheduledBackup |

---

## 9. 附录：备份空间占用快照（2026-10-06 17:00 CST）

统计口径：`s3://pg-backups`（WAL 归档 + 全量备份），数据源三处交叉核对 —— `aws s3 ls --summarize`、按前缀分组统计、`radosgw-admin bucket stats`，三者一致。

### 9.1 逻辑占用（对象大小合计）

| 分类 | 对象数 | 逻辑大小 | 占比 |
|------|--------|----------|------|
| **全量（`base/`）** | 4 | **12.87 MiB**（13,492,460 B） | 69% |
| ├ `20261005T134311`（首次 + 演练） | 2 | 6.34 MiB | |
| └ `20261006T020002`（今晨 02:00 定时） | 2 | 6.53 MiB | |
| **WAL（`wals/`）** | 109 | **5.72 MiB**（5,996,677 B） | 31% |
| **合计** | **113** | **18.59 MiB**（19,489,137 B） | 100% |

```bash
# 复现统计
aws s3 ls s3://pg-backups/ --recursive --summarize | tail -2
# Total Objects: 113 / Total Size: 19489137

radosgw-admin bucket stats --bucket=pg-backups
# rgw.main: num_objects=113, size=19489137 (18.59 MiB), size_actual=19771392 (18.86 MiB)
```

> WAL 中含 1 个 `0000000C0000000400000068.partial.gz`（47,996 B）残留，见 §5.3。

### 9.2 Ceph 物理落盘占用

数据池 `my-zone.rgw.buckets.data` 为 **replicated size 3 / min_size 2**（`ceph osd dump` 确认）：

| 项 | 值 |
|----|----|
| 逻辑（RGW `size`） | 18.59 MiB |
| 逻辑（RGW `size_actual`，含对象对齐） | 18.86 MiB |
| **裸占用 ≈ ×3 副本** | **≈ 55.8 – 56.6 MiB** |
| 索引池 `my-zone.rgw.buckets.index` 条目 | 几十 KB ×3，可忽略 |

对照整个池（含 Loki / Tempo / 所有桶）：

```
my-zone.rgw.buckets.data   stored 463 MiB → stored_raw 1.39 GiB（3 副本）
pg-backups 占该池逻辑量约 4%
```

### 9.3 增长预测（`retentionPolicy: 30d` 滚动保留）

| 项 | 速率 | 30 天累计 |
|----|------|-----------|
| 全量 | ≈ 6.5 MiB/天（每日 02:00，12.9 秒完成） | ≈ 195 MiB |
| WAL | ≈ 5.7 MiB/天（过去 27 小时 109 段实测） | ≈ 171 MiB |
| **稳态逻辑总量** | | **≈ 366 MiB** |
| **稳态裸占用（3 副本）** | | **≈ 1.1 GiB** |

安全边界：

- 集群 180 GiB 总量、`ceph df` 可用 164 GiB → 占比 < 1%，**无需扩容**
- pg-backup 用户配额若按报告补齐 20 GB → 稳态 366 MiB 仅用 1.8%，余量充足
- ⚠️ 前提是**配额先生效**（当前 `enabled: false`，见 §5.1），否则异常膨胀（例如 barman 重复全量、WAL 归档风暴）无任何上限保护

### 9.4 快照采集命令（可定期复跑做巡检）

```bash
aws s3 ls s3://pg-backups/ --recursive | awk '{
  s+=$3; n++;
  if ($4 ~ /\/base\//) {bs+=$3; bn++} else if ($4 ~ /\/wals\//) {ws+=$3; wn++}
} END {
  printf "base %d obj %.2f MiB | wals %d obj %.2f MiB | TOTAL %d obj %.2f MiB\n",
         bn, bs/1048576, wn, ws/1048576, n, s/1048576
}'

ceph osd dump | grep "pool 42"          # 确认副本数
ceph df | grep my-zone.rgw.buckets.data # 池级用量
```

---

## 10. 附录：防容量失控机制（循环存储）核查 —— 2026-10-06 17:40 CST

**结论：循环存储（时间轮转）已配置且经 dry-run 实证会连带清理 WAL；但"容量硬上限"这一层目前全部缺失/未生效。**

### 10.1 机制 A：CNPG `retentionPolicy: 30d` —— 时间轮转（唯一在位的机制）

```bash
kubectl get cluster -n cnpg-system pg16-ceph -o jsonpath='{.spec.backup.retentionPolicy}{"\n"}'
# 30d
```

官方实现：每次新备份完成后，operator 执行 `barman-cloud-backup-delete --retention-policy "RECOVERY WINDOW OF 30 DAYS"`，删除超过 30 天的 base backup，**并同时删除不再被任何剩余备份需要的 WAL**（即 WAL 不会无限堆积）。

**实测证据**（在 `pg16-ceph-3` 容器内执行，全部 `--dry-run` 只列不删；事后确认对象数仍为 113、总字节 19,489,137 不变）：

```bash
K="kubectl -n cnpg-system exec pg16-ceph-3 -c postgres --"
export AWS_ACCESS_KEY_ID=<redacted-s3-access-key> AWS_SECRET_ACCESS_KEY=<redacted>

# A) 模拟到期清理：当前无 >30d 备份 → 无输出（符合预期）
$K barman-cloud-backup-delete -r "RECOVERY WINDOW OF 1 DAYS" --dry-run \
    --endpoint-url http://10.0.0.31:7480 --cloud-provider aws-s3 s3://pg-backups/ pg16-ceph

# B) 模拟删除 10-05 那次全量 → 2 个 base 对象 + 74 个 WAL 对象一并进删除列表
$K barman-cloud-backup-delete -b 20261005T134311 --dry-run ...
# Skipping deletion of objects ['pg16-ceph/base/20261005T134311/data.tar.gz',
#                               'pg16-ceph/base/20261005T134311/backup.info'] due to --dry-run
# Skipping deletion of objects ['pg16-ceph/wals/0000000D00000004/0000000D0000000400000068.gz',
#   ... 一路到 ...00B1.gz] due to --dry-run          ← 74 个 WAL 对象

# C) 模拟删除 10-06 最新全量 → 只删自己的 2 个对象，WAL 全保留
$K barman-cloud-backup-delete -b 20261006T020002 --dry-run ...
# Skipping deletion of objects ['pg16-ceph/base/20261006T020002/data.tar.gz',
#                               'pg16-ceph/base/20261006T020002/backup.info'] due to --dry-run
```

| dry-run 场景 | 删除的 base | 删除的 WAL | 解读 |
|---|---|---|---|
| 按时间策略（1 天窗口） | 0 | 0 | 当前无到期对象，机制静默等待 |
| 删除旧备份 `20261005T134311` | 2 | **74** | ✅ 旧备份过期时，其独占区间 WAL 一并清 |
| 删除新备份 `20261006T020002` | 2 | 0 | ✅ 旧备份仍需这些 WAL 做 PITR，绝不误删 |

**两点风险提示**：

1. **首次真实清理要等到 ≈2026-11-05**（备份超 30d 后的下一次备份完成时触发），至今**从未实测**（原报告 §7 P2 已标注；社区亦有 `retentionPolicy` 未生效的 issue 先例）。建议先用 `7d` 短周期跑一轮验证。
2. **跨时间线残留死角**：dry-run B 的删除列表**不含** `wals/0000000C00000004/` 目录（5 个 WAL + `.history` + `.partial.gz`），即切换时间线前的旧 WAL **不会被自动清理**，合计约 223 KB（228,681 B）：

   ```
   0000000C0000000400000063.gz 62,924   …0064.gz 51,354   …0065.gz 18,823
   0000000C0000000400000066.gz 30,913   …0067.gz 16,542   …0068.partial.gz 47,996
   0000000D.history.gz 129
   ```

   量极小，但机制上需要手动兜底（见 §10.4 第 4 条）。

### 10.2 机制 B：容量硬上限 —— **全部缺失/未生效**

| 层级 | 状态 | 实测证据 |
|------|------|----------|
| RGW 用户配额 20 GB / 100,000 对象 | ❌ **未生效** | `user_quota: {enabled: false, max_size: -1, max_objects: -1}` |
| Bucket 配额 | ❌ 未设置 | `bucket_quota: {enabled: false, max_size: -1}` |
| S3 Lifecycle 过期规则（RGW 支持） | ❌ 未设置 | `s3cmd info s3://pg-backups/` → `Expiration rule: none` |
| Ceph 池配额 `target_max_bytes` | ❌ 未设置 | `ceph osd pool get ... all` 无配额（且池为全池共享，不宜单限备份） |
| 集群容量兜底 | ✅ 充裕 | 可用 164 GiB；30 天稳态 ≈1.1 GiB（§9.3） |

**现状等价于：只有"时间轮转"一条腿，没有"容量硬上限"另一条腿。** 一旦 retention 因 bug 或配置失效（社区有先例），没有任何东西拦截无限增长。缓解因素是自然上限很低：库仅 16.5 MB，即使永不清理，日增也只有约 12 MiB（全量 6.5 + WAL 5.7）。

### 10.3 各机制对比

| | 机制 A：`retentionPolicy: 30d` | 机制 B：配额/生命周期 |
|---|---|---|
| 类型 | 软性、按时间轮转 | 硬性、按容量熔断 |
| 覆盖对象 | base backup + 其独占 WAL | 用户/桶内全部写入 |
| 生效条件 | 需 >30d 备份 + 下一次备份触发 | 实时检查 |
| 当前状态 | ✅ 已配置，逻辑经 dry-run 实证 | ❌ 全部未启用 |
| 失效后果 | 缓慢无限增长 | 无兜底 |
| 超限行为 | 无（只删旧的） | **拒绝写入** → 归档报错（响亮失败，反而暴露问题） |

### 10.4 建议动作（均**未执行**，待确认）

1. **补配额硬兜底（最优先，2 条命令）**
   ```bash
   radosgw-admin quota set --uid=pg-backup --quota-type=user --max-size 20G --max-objects 100000
   radosgw-admin quota enable --uid=pg-backup --quota-type=user
   ```
   > 配额超限时 RGW 拒绝写入 → 备份与 WAL 归档会报错。这是"响亮的失败"，恰好呼应原报告最担心的"假健康/静默失败"问题。
2. **短期验证轮转**：将 `retentionPolicy` 临时改为 `7d`（或另建测试 ScheduledBackup），观察一轮真实删除后改回 `30d` —— 落实原报告 §7 P2。
3. **加容量/新鲜度告警**：对 `radosgw-admin bucket stats --bucket=pg-backups` 的 `size` / `num_objects` 建告警，或纳入周巡检 `s3cmd du s3://pg-backups/`；同时补上原报告 §7 的"备份超 26h 未成功"告警。
4. **手动清理残留（可选，约 223 KB）**
   ```bash
   aws s3 rm s3://pg-backups/pg16-ceph/wals/0000000C00000004/ --recursive
   aws s3 rm s3://pg-backups/pg16-ceph/wals/0000000D.history.gz
   ```
   > 删除前请确认 `20261005T134311` 这次备份不再需要从时间线 12 恢复；若不放心可只删 `…partial.gz`。

---

*执行时间：2026-10-06 16:40–16:55 CST ｜ 集群侧零变更 ｜ 验证：S3 读写 round-trip + RBD 清单 + RGW 用户/桶统计三方一致 ｜ §9 占用快照补记于 2026-10-06 17:00 CST ｜ §10 循环存储机制核查补记于 2026-10-06 17:40 CST*
