# Ceph 集群主机 —— 发现与操作全记录

| 项目 | 内容 |
|------|------|
| **文档版本** | v2.0（含 ceph-01 zabbix 清除、Redis 评估、内存审计） |
| **执行时间** | 2026-10-02 21:08 ~ 21:50 CST |
| **集群 FSID** | `594e535e-d82c-11f0-afa7-bc24112b746f` |
| **涉及主机** | ceph-01 (10.0.0.31)、ceph-02 (10.0.0.41)、ceph-03 (10.0.0.51) |
| **执行原则** | 先备份 → 停服务 → 卸载 → 逐项验证；**Harbor 全程保留未动** |
| **最终状态** | Ceph `HEALTH_OK`；已完成 4 项清除 + 1 项评估 |
| **操作清单** | php-fpm ✅ / zabbix(ceph-02) ✅ / zookeeper ✅ / zabbix(ceph-01) ✅ / Redis ⏸已评估待决 |

---

## 一、主机总览

| 主机 | 业务 IP | 管理 IP | CPU / 内存 | 系统盘 | OSD |
|------|---------|---------|-----------|--------|-----|
| ceph-01 | 10.0.0.31 | 172.16.1.31 | 4 vCPU / 5.6 G | sda 80G | osd.0→sdb、osd.5→sdc |
| ceph-02 | 10.0.0.41 | 172.16.1.41 | 4 vCPU / 5.6 G | sda 80G | osd.1→sdb、osd.4→sdc |
| ceph-03 | 10.0.0.51 | 172.16.1.51 | 6 vCPU / 7.5 G | **sdc** 80G | osd.2→sda、osd.3→sdb |

**共性**：Rocky Linux 9.6 / Kernel `5.14.0-570.58.1.el9_6` / **KVM 虚拟机**（virtio + QEMU HARDDISK）/ SELinux **Disabled** / firewalld **inactive** / iptables `INPUT ACCEPT`

**Ceph**：守护进程 18.2.8 reef（16 个全一致）、宿主机 CLI `ceph-common-17.2.8`、6 OSD 全 in、465 PG 全 active+clean、14 个 Pool（`k8s-rbd` 活跃承载 4.2 GiB）

---

## 二、非 Ceph 已启用服务与内存占用

> 数据源：`systemctl list-unit-files --state=enabled` + `systemctl show -p MemoryCurrent`（cgroup 精确计费），清理后实测

### 2.1 ceph-01（内存 5665 MB / 已用 3891 MB）

| 服务 | 内存 | 端口 | 状态 |
|---|---:|---|---|
| `rsyslog` | 118.7 MB | — | ⚠️ 偏高 |
| `auditd` | 30.5 MB | — | 保留 |
| `sshd` | 10.4 MB | 22 | 保留 |
| `NetworkManager` | 8.5 MB | — | 保留 |
| `qemu-guest-agent` | 3.3 MB | — | 保留 |
| `nginx` | 2.5 MB（RSS 实测 21.8 MB / 5 进程） | 80, 443 | 保留（RGW 的 S3 反代） |
| `dbus-broker` / `chronyd` / `crond` / `irqbalance` | 1.3 / 1.2 / 1.1 / 0.7 MB | — | OS 基础 |
| ~~`zabbix-agent2`~~ | ~~66.4 MB~~ | ~~10050~~ | ✅ **已清除** |

### 2.2 ceph-02（内存 5665 MB / 已用 3269 MB）

| 服务 | 内存 | 端口 | 状态 |
|---|---:|---|---|
| `rsyslog` | 58.5 MB | — | ⚠️ 偏高 |
| `auditd` | 27.2 MB | — | 保留 |
| `pushgateway` | 16.2 MB | 9091 | 🟠 保留，开管理 API |
| `NetworkManager` | 10.1 MB | — | 保留 |
| `sshd` | 9.3 MB | 22 | 保留 |
| `qemu-guest-agent` | 3.7 MB | — | 保留 |
| `dbus-broker` | 2.1 MB | — | 保留 |
| `rpcbind` | 1.6 MB | 111 | 保留（**NFS 依赖不可删**） |
| `crond` | 1.4 MB | — | 保留 |
| `rsyncd` | 1.0 MB | 873 | 🟠 保留，备份通道 |
| `chronyd` / `irqbalance` | 0.9 / 0.8 MB | — | OS 基础 |
| `nfs-server` | 0（**内核态**） | 111, 2049, 20048 | 8 个 nfsd 线程，内存记在内核 slab，不计 cgroup |
| `harbor-log`（容器） | 9.5 MB | 1514→10514 | ✅ **按要求保留** |
| ~~`php-fpm`~~ | ~~—~~ | ~~9000~~ | ✅ **已清除** |
| ~~`zabbix-agent2`~~ | ~~66 MB~~ | ~~10050~~ | ✅ **已清除** |

### 2.3 ceph-03（内存 7680 MB / 已用 2517 MB）

| 服务 | 内存 | 端口 | 状态 |
|---|---:|---|---|
| `rsyslog` | 96.0 MB | — | ⚠️ 偏高 |
| `auditd` | 40.0 MB | — | 保留 |
| `redis` | 33.4 MB | 6379 | ⏸ **已评估，建议清除** |
| `NetworkManager` | 12.2 MB | — | 保留 |
| `redis-sentinel` | 11.1 MB | 26379 | ⏸ **已评估，建议清除** |
| `sshd` | 8.8 MB | 22 | 保留 |
| `qemu-guest-agent` | 4.1 MB | — | 保留 |
| `dbus-broker` / `crond` / `irqbalance` / `chronyd` | 2.3 / 1.3 / 1.0 / 1.0 MB | — | OS 基础 |
| ~~`zookeeper`~~ | ~~190 MB~~ | ~~2181,3888,8080,9999,45577~~ | ✅ **已清除** |

### 2.4 隐性内存占用（不体现在服务列表中）

| 项目 | ceph-01 | ceph-02 | ceph-03 | 说明 |
|---|---|---|---|---|
| **`rsyslog` 三台合计** | 118.7 | 58.5 | 96.0 | **273 MB**，异常偏高，建议查日志量与轮转 |
| `auditd` 三台合计 | 30.5 | 27.2 | 40.0 | 97.7 MB |
| **`kdump` 预留** | 192–512 MB | 192–512 MB | 192–512 MB | `crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M`，三台均 enabled，**从可用内存扣除但不计入 `free` 的 used**；KVM 虚拟机内实用价值有限 |
| `dockerd` 守护进程 | 274 MB | 315 MB | 387 MB | ceph-container 必需 |

### 2.5 容器内存占比对照（证明 Ceph 是内存主体）

| 主机 | 容器合计 | Ceph 容器 | 非 Ceph 容器 |
|---|---|---|---|
| ceph-01 | 52.9% | 52.7% | — |
| ceph-02 | 42.3% | 42.1% | harbor-log 0.17% |
| ceph-03 | 20.8% | 20.8% | — |

---

## 三、Harbor 异常状态专项说明

用户曾提出疑问："主容器退出了但日志容器还在跑，这不合理吧？" —— 经排查，**该状态完全自洽**。

### 3.1 事实

```
宿主机启动时刻:  2026-09-27 18:47:18 CST

容器            RestartPolicy  ExitCode  StartedAt             FinishedAt
harbor-core     always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
harbor-db       always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
harbor-jobservice always       128       2026-06-18T08:49:03   2026-06-18T13:23:08
harbor-portal   always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
nginx           always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
registry        always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
registryctl     always         128       2026-06-18T08:49:02   2026-06-18T13:23:18
redis           always         128       2026-06-18T08:49:02   2026-06-18T13:23:08
harbor-log      always         (运行中)   2026-09-27T10:47:28   2026-06-18T13:23:18
```

### 3.2 解释

1. **10 个容器在 `2026-06-18 13:23:08` 同一秒集体停止**（ExitCode 128）—— 典型大规模停止事件，而非单容器崩溃。
2. **策略全为 `always` 却都没自动重启** —— 说明停止是**人为触发**。Docker 对被显式 `stop` 的容器会记下"人工停止"标记，即使策略为 `always` 也不重启。
3. **`harbor-log` 是唯一例外**：它在 `2026-09-27T10:47:28 UTC` 启动，与宿主机开机时刻（`10:47:18 UTC`）**精确吻合**。它从未被人工停止，故开机后被 Docker 自动拉起。
4. **无任何 systemd 单元 / rc.local / cron** 引用 Harbor —— 排除人为保活机制。

### 3.3 结论与端口现状

这是**宿主机重启导致的不对称恢复**。Harbor 早已废弃（停于 6-18），harbor-log 只是搭便车存活。

ceph-02 上 Harbor **实际对外无任何开放端口**：

| 容器 | 原始意图端口（HostConfig.PortBindings） | 现状 |
|---|---|---|
| `nginx` | `0.0.0.0:80` | 已停止，不监听 |
| `harbor-log` | `127.0.0.1:1514 → 10514` | **仅回环**，外网不可达（本就是内部日志收集用） |

配置位于 `/opt/harbor/harbor.yml` 与 `/opt/harbor/docker-compose.yml`。

---

## 四、Redis 评估（ceph-03，待决）

### 4.1 评估结论：**已失效的孤儿，建议清除**

| 检查项 | 结果 | 判读 |
|---|---|---|
| 版本 / 进程 | 6.2.20，PID 1064，uptime 5 天 | — |
| **角色** | `role: slave`，`master_host: 10.0.0.7` | 它是**副本**，非主库 |
| **主从链路** | **`master_link_status: down`** | 主库失联，**已停止同步** |
| 友节点 | 10.0.0.7:6379、10.0.0.8:6379 **均不可达** | 三节点 HA 瓦解 |
| 实际数据量 | **895.62 KB** | 几乎为空 |
| 键内容 | db0: `foo` `demo` `site`；db11: `age` `name` | **全是测试垃圾键** |
| 持久化文件 | `dump.rdb` 161 B、`appendonly.aof` 161 B | 与"空"一致 |
| 客户端 | `connected_clients: 3`，`ss` 显示**全部是 sentinel 自身回环连接** | **无外部应用接入** |
| Sentinel 行为 | 对 10.0.0.7 / 10.0.0.8 连接**卡在 SYN-SENT** | 持续空转重试 |
| 本机配置引用 | `/etc/systemd/system`、`/opt`、`/root` 中**无任何** redis/zookeeper 引用 | 无本地消费者 |
| 外部依赖核查 | ceph-02 `/root/HivisionIDPhotos/docker-compose.yml` **不引用** redis/zookeeper | 无关 |

### 4.2 说明

Redis 与已删除的 ZooKeeper 属**同一套架构**（集群友均为 `10.0.0.7` / `10.0.0.8`），现已整体瘫痪：副本失联、无 quorum、无客户端，仅剩 5 个测试键。删除可释放 **44.5 MB** 及 6379 / 26379 两个对外监听端口。

⚠️ 独立于删不删 Redis：`requirepass "<redacted-password>"` 与集群 root SSH 口令相同，**建议尽快轮换**。

---

## 五、已执行操作清单

### 5.1 ceph-02 — 清除 PHP-FPM

**① 清除残留文件**

| 操作 | 结果 |
|---|---|
| `rm -rf /etc/nginx` | ✅（php-fpm.conf、pushgateway.conf、ssl 自签证书；nginx 包早已卸载） |
| `rm -rf /usr/share/nginx` | ✅ 删除 `html/test.php`（含明文 MySQL 凭据 `root/Root123!`） |
| `rm -f /etc/httpd/conf.d/php.conf` | ✅ 删除指向 php-fpm socket 的死配置 |
| `rm -rf /var/log/php-fpm /var/lib/php/{session,opcache}` | ✅ 清空日志与运行时目录 |

**② 卸载软件包**
```
dnf remove -y php-fpm php php-cli php-common php-gd php-mbstring \
             php-mysqlnd php-opcache php-pdo php-xml
```

**③ 连带移除**（依赖自动解析）：`httpd`、`httpd-core`、`httpd-filesystem`、`httpd-tools`、`nginx-filesystem`、`mod_http2`、`mod_lua`、`mailcap`、`rocky-logos-httpd`、`xml-common`
> httpd 原已 `inactive + disabled`，唯一用途即承载 php，属同一套废弃 LNMP 空壳。

**验证**：`inactive` / `disabled` / 无 php 包 / 无 php 进程 / 9000 未监听 ✅

### 5.2 ceph-02 — 删除 Zabbix Agent

```
systemctl stop zabbix-agent2 && systemctl disable zabbix-agent2
dnf remove -y zabbix-agent2 zabbix-agent2-plugin-postgresql zabbix-agent2-plugin-mongodb
rm -rf /etc/zabbix /var/log/zabbix /var/lib/zabbix
```
**验证**：单元 `not-found` / 无包 / 无进程 / **10050 已释放** ✅

### 5.3 ceph-03 — 卸载 ZooKeeper

删除前飞行前检查：本节点 `not currently serving requests`、**0 客户端**，集群友 10.0.0.7 / 10.0.0.8 均 `No route to host` → **已丧失 quorum、实质瘫痪，删除零影响**。

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | 备份 `/usr/local/zookeeper/{conf,bin}` 与 `zoo.cfg` | ✅ |
| 2 | `systemctl stop zookeeper` | ✅ PID 987 以 `status=143`(SIGTERM) 优雅退出 |
| 3 | `systemctl disable zookeeper` | ✅ |
| 4 | `rm -f /etc/systemd/system/zookeeper.service` + `daemon-reload` | ✅ |
| 5 | `rm -rf /usr/local/zookeeper` | ✅ |
| 6 | `systemctl reset-failed zookeeper` | ✅ 状态由 `failed` 归位 `inactive` |

**验证**：java 进程 **0**（按进程名核实）/ 2181、2888、3888、8080、**9999**、45577 全部释放 / 内存 ↓约 330 MB ✅

### 5.4 ceph-01 — 删除 Zabbix Agent（v2.0 新增）

```
systemctl stop zabbix-agent2 && systemctl disable zabbix-agent2
dnf remove -y zabbix-agent2 zabbix-agent2-plugin-postgresql zabbix-agent2-plugin-mongodb
rm -rf /etc/zabbix /var/log/zabbix /var/lib/zabbix
```

**删除前留档的克隆残留配置**（ceph-01 与 ceph-02 同款）：
```
82:  Server=127.0.0.1
135: ServerActive=127.0.0.1
146: Hostname=Zabbix server          ← 克隆自旧 Zabbix Server
494: Server=172.16.1.61
496: Hostname=nfs01                  ← 克隆自旧 nfs01
```

**验证**：单元 `not-found` / 无包 / 无进程 / **10050 已释放** / **nginx 未受影响**（active，5 进程，80/443 正常，10 个 Ceph 容器在跑）✅

**至此三台主机 zabbix 全部清除完毕。**

### 5.5 备份留存

| 主机 | 路径 | 内容 |
|---|---|---|
| ceph-01 | `/root/cleanup-backup-20261002-214721/` | `zabbix_agent2.conf.bak`、`zabbix-data-logs.tgz` |
| ceph-02 | `/root/cleanup-backup-20261002-210824/` | `php-fpm-config.tgz`、`nginx-conf-residue.tgz`、`httpd-php-conf.tgz`、`test.php.bak`、`zabbix_agent2.conf.bak`、Harbor 基线指纹 3 个 txt |
| ceph-03 | `/root/cleanup-backup-20261002-212250/` | `zoo.cfg.bak`、`zookeeper-conf-logs.tgz`（16K） |

**回滚方式**：从 tar 包还原；zabbix / php / zookeeper 可从 Rocky 9 AppStream 或原版本号重装。

---

## 六、操作后最终状态校验

### 6.1 Ceph 集群

```
health: HEALTH_OK                          ← 全程未受影响
mon: 3 daemons, quorum ceph-02,ceph-03,ceph-01
mgr: ceph-01.egryfx(active), standbys: ceph-02.wzbtbx
mds: 1/1 daemons up, 2 standby
osd: 6 osds: 6 up, 6 in (since 9M)
rgw: 2 daemons active (2 hosts, 1 zones)
volumes: 1/1 healthy
```

### 6.2 各主机剩余非 Ceph 监听端口

| 主机 | 剩余非 Ceph 端口 | 已消失 |
|---|---|---|
| ceph-01 | `80`, `443`（nginx）、`123`（chronyd） | ~~10050~~（zabbix） |
| ceph-02 | `111`, `2049`, `20048`, `39777`, `45753`（NFS）、`873`（rsync）、`9091`（pushgateway）、`1514`（harbor-log） | ~~9000~~（php-fpm）、~~10050~~（zabbix） |
| ceph-03 | `6379`（redis）、`26379`（sentinel） | ~~2181, 2888, 3888, 8080, 9999, 45577~~（zookeeper） |

### 6.3 Harbor 完好性验证（专项）

| 检查项 | 清理前基线 | 清理后现状 | 结论 |
|---|---|---|---|
| 容器 ID | `c522157e3180cb8e...` | 一致 | ✅ |
| 状态 / 健康 | running / healthy | running / healthy | ✅ |
| **StartedAt** | `2026-09-27T10:47:28.230520786Z` | **完全一致**（未重启） | ✅ |
| 重启策略 / 网络 | always / harbor_harbor | 一致 | ✅ |
| 端口映射 | `127.0.0.1:1514→10514` | 在位 | ✅ |
| 容器数 / 网络数 | 10 / 1 | 10 / 1 | ✅ |

**Harbor 全程未受任何影响**（`StartedAt` 未变即证明进程从未被重启）。

---

## 七、遗留风险与后续待办

### ✅ 已完成

- ceph-02 php-fpm 全套清除（进程/包/配置/明文凭据）
- ceph-02 + ceph-01 zabbix agent 清除
- ceph-03 ZooKeeper 卸载
- ceph-02 内存最大单体非 Ceph 进程（zabbix 66 MB）已消除

### 🔴 高危（未处置）

1. **Redis 口令复用 root 口令**（ceph-03:6379）：`bind 0.0.0.0` + `protected-mode no` + `requirepass "<redacted-password>"`，与 root SSH 口令完全相同。
   **建议**：**立即轮换 root 口令**；如保留 Redis 则改绑内网、开启 `protected-mode yes`、改独立强口令。

### 🟠 中危（未处置）

2. **系统基线不达标**（三台一致）：`vm.max_map_count=65530`（应 262144）、`ulimit -n=1024`（应 65536）、缺 `/etc/security/limits.d/ceph.conf`
3. **无主机防火墙**：三台 firewalld 均关闭，叠加 0.0.0.0 监听服务，攻击面偏大
4. **NFS / rsync 备份通道**（ceph-02）：`/playbook-backup` 导出至 `172.16.1.0/24`；rsync `use chroot = no`，873 对外开放
5. **Pushgateway 开管理 API**（ceph-02:9091，`--web.enable-admin-api` 暴露 0.0.0.0）
6. **rsyslog 内存异常**（三台合计 273 MB，ceph-01 单台 118.7 MB）——查日志量与轮转策略
7. **kdump 预留 192–512 MB/台**，5.6 GB 节点上浪费可观，KVM 内实用价值有限

### 🟡 低危 / 规范（未处置）

8. `ceph.conf` 未声明 `public_network` / `cluster_network`
9. `telemetry` mgr 模块开启，向 ceph.com 上报匿名数据
10. 3 个认证实体指向不存在的 Pool：`client.pve`(pve-rbd)、`client.rbd`(test-pool)、`client.testuser`(mypool)
11. 宿主机 CLI `ceph-common-17.2.8` 落后于守护进程 `18.2.8`

### ⏸ 待决

12. **是否清除 ceph-03 的 Redis + Sentinel**（评估已完成，见第四章，建议清除，释放 44.5 MB）

### 建议处置顺序

① 轮换 root 口令 → ② 决定 Redis 去留 → ③ 防火墙 + 内核/句柄调优 → ④ 收紧 NFS/rsync/Pushgateway → ⑤ rsyslog 与 kdump 优化 → ⑥ 配置与认证规范化

---

## 八、附：关联文档

| 文档 | 内容 |
|---|---|
| `ceph_cluster_host_report.md` | 集群主机完整情况（硬件/OS/网络/存储/Ceph/基线/风险） |
| `ceph_non_ceph_process_report.md` | 非 Ceph 进程专项分析 |
| 本文档 | 发现汇总 + 操作全记录 + 内存审计 + Redis 评估 |
