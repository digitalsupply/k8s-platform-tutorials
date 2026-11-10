# Ceph 集群主机情况报告

| 项目 | 内容 |
|------|------|
| **报告主题** | Ceph 集群三台主机完整情况盘点（硬件 / 系统 / 网络 / 存储 / Ceph / 运行环境 / 风险） |
| **采集时间** | 2026-10-02 14:09 CST |
| **集群 FSID** | `594e535e-d82c-11f0-afa7-bc24112b746f` |
| **集群健康** | `HEALTH_OK` |
| **Ceph 版本** | 守护进程 `18.2.8 (reef)`（16 个全部一致）；宿主机 CLI `ceph-common-17.2.8 (quincy)` |
| **采集方式** | SSH root 免密 → `lscpu` / `free` / `lsblk` / `ip` / `ss` / `ps` / `systemctl` / `docker` / `ceph` 命令 |

---

## 一、总体概览

集群为 **3 节点 KVM 虚拟机**部署的测试/实验环境（总原始容量仅 180 GiB），运行 Ceph Quincy→Reef 18.2.8，提供 CephFS + RGW(S3) + 监控栈。

```
                  ceph-01 (10.0.0.31)              ceph-02 (10.0.0.41)              ceph-03 (10.0.0.51)
                  4 vCPU / 5.6 GB                    4 vCPU / 5.6 GB                    6 vCPU / 7.5 GB
                  ┌──────────────────┐              ┌──────────────────┐              ┌──────────────────┐
  业务网 10.0.0/24 │ mon  mgr(act)    │              │ mon  mgr(standby)│              │ mon              │
                  │ osd.0 osd.5      │              │ osd.1 osd.4      │              │ osd.2 osd.3      │
                  │ mds(active)      │              │ mds(standby)     │              │ mds(standby)     │
                  │ rgw.myrgw        │              │ rgw.myrgw        │              │ (无 RGW)          │
                  │ prometheus       │              │ node-exporter    │              │ alertmanager      │
                  │ grafana          │              │ ─────────────    │              │ node-exporter    │
                  │ node-exporter    │              │ ⚠ NFS / rsync    │              │ ─────────────    │
                  │ ─────────────    │              │ ⚠ php-fpm        │              │ ⚠ ZooKeeper      │
                  │ ⚠ nginx(S3反代)   │              │ ⚠ pushgateway    │              │ ⚠ Redis+Sentinel │
                  └──────────────────┘              │ ⚠ harbor-log     │              └──────────────────┘
  管理网 172.16.1/16 .31 (eth1)                     │ ⚠ zabbix-agent2  │
                                                     └──────────────────┘ .41 (eth1)
```

**数据面现状**：6 OSD 全 `up/in`（运行 9 个月），465 PG 全 `active+clean`，180 GiB 原始容量已用 19 GiB（10.5%）。

---

## 二、主机硬件与操作系统

### 2.1 硬件规格

| 主机 | CPU | 内存 | 系统盘 | OSD 盘 | 机型 |
|------|-----|------|--------|--------|------|
| **ceph-01** | 4 vCPU（1 socket × 4 core） | 5.6 GB | sda 80G（XFS 根 77G） | sdb 30G → osd.0；sdc 30G → osd.5 | QEMU Virtual CPU 2.5+ |
| **ceph-02** | 4 vCPU | 5.6 GB | sda 80G（XFS 根 77G） | sdb 30G → osd.1；sdc 30G → osd.4 | QEMU Virtual CPU 2.5+ |
| **ceph-03** | 6 vCPU | 7.5 GB | **sdc** 80G（XFS 根 77G） | sda 30G → osd.2；sdb 30G → osd.3 | QEMU Virtual CPU 2.5+ |

> ⚠️ **全部为 KVM 虚拟机**（virtio 设备、`QEMU HARDDISK`），非物理机。磁盘 `ROTA=1` 为虚拟盘默认值，不代表真实机械盘。
> ceph-03 的系统盘与其他两台不同（sdc 而非 sda），克隆/扩容时需留意。

### 2.2 操作系统

| 项目 | 三台主机一致情况 |
|------|-----------------|
| 发行版 | Rocky Linux 9.6 (Blue Onyx) |
| 内核 | `5.14.0-570.58.1.el9_6.x86_64` |
| SELinux | **Disabled**（三台均关闭） |
| firewalld | **inactive**（三台均未启用） |
| iptables | `INPUT ACCEPT` / `FORWARD DROP` / `OUTPUT ACCEPT` |
| 时区 | Asia/Shanghai (CST, +0800)，时间已同步 |
| 运行时长 | 约 4 天 19 小时 |

### 2.3 根分区使用率

| 主机 | 根分区 | 已用 | 可用 | 使用率 |
|------|--------|------|------|--------|
| ceph-01 | 77G | 9.9G | 68G | 13% |
| ceph-02 | 77G | **23G** | 55G | **30%** ← 最高（含 Harbor 镜像/容器层） |
| ceph-03 | 77G | 11G | 67G | 15% |

---

## 三、网络配置

### 3.1 网卡与地址

| 主机 | eth0（业务/存储网） | eth1（管理网） | 其他 |
|------|--------------------|----------------|------|
| ceph-01 | 10.0.0.31/24 | 172.16.1.31/16 | docker0 172.17.0.1/16（down）、docker_gwbridge 172.18.0.1/16（down） |
| ceph-02 | 10.0.0.41/24 | 172.16.1.41/16 | docker0（down）、docker_gwbridge（down）、**br-819564b3675f（up，Harbor 网络）**、vethcc98aa6 |
| ceph-03 | 10.0.0.51/24 | **172.16.1.51/16** | docker0（down） |

> ✅ 双网卡配置一致（10.0.0.0/24 + 172.16.1.0/16），MTU 均为 1500。
> ⚠️ ceph-03 无 `docker_gwbridge`，且未安装 zabbix_agent2（另两台有）——与"由 ceph-01/02 克隆而来"的推断一致。

### 3.2 集群网络端口

- mon：`6789`(v1) / `3300`(v2)，三台各自监听本机地址
- osd：6800-6820 区间，每 OSD 占 4 个端口
- mgr：`9283`、`8443`；ceph-01 另有 `7150`、`8765`
- mds：`6800`、`6801`
- rgw：`7480`（ceph-01、ceph-02）

---

## 四、存储与 OSD 布局

### 4.1 OSD 拓扑

| 主机 | OSD ID | 设备 | 容量 | 状态 |
|------|--------|------|------|------|
| ceph-01 | osd.0 | sdb | 30G | up / in |
| ceph-01 | osd.5 | sdc | 30G | up / in |
| ceph-02 | osd.1 | sdb | 30G | up / in |
| ceph-02 | osd.4 | sdc | 30G | up / in |
| ceph-03 | osd.2 | sda | 30G | up / in |
| ceph-03 | osd.3 | sdb | 30G | up / in |

- **存储后端**：BlueStore，OSD 以 LVM 逻辑卷（`ceph_bluestore`）形式挂载
- **OSD Class**：`hdd`（CRUSH 默认层级，单层 host 结构）
- **部署方式**：`ceph-volume` LVM 模式 + `ceph-container`（宿主机**未安装** `ceph-volume` 命令，实际在容器内执行）

### 4.2 容量与 Pool

| 指标 | 数值 |
|------|------|
| 原始总容量 | 180 GiB |
| 已用 | 19 GiB（10.45%） |
| 可用 | 161 GiB |
| Pool 数 | 14 |
| PG 数 | 465（全部 active+clean） |
| 对象数 | 13.46k |

**Pool 清单**：

| Pool | PG | 已用 | 用途 |
|------|----|------|------|
| `.mgr` | 1 | 2.6 MiB | mgr 内部 |
| `cephfs_metadata` | 16 | 243 KiB | CephFS 元数据 |
| `cephfs_data` | 64 | 30 MiB | CephFS 数据 |
| `rbd` | 32 | 12 KiB | 默认 RBD |
| **`k8s-rbd`** | 32 | **4.2 GiB** | **Kubernetes RBD（活跃使用中）** |
| `.rgw.root` | 32 | 228 KiB | RGW 根 |
| `default.rgw.*`（3 个） | 32 | ~24 KiB | RGW 默认 zone |
| `my-zone.rgw.*`（5 个） | 32 | ~1.8 GiB | **my-zone RGW（业务使用中）** |
| `my-zone.rgw.buckets.non-ec` | — | — | 非 EC 桶 |

### 4.3 文件系统与对象存储

- **CephFS**：`cephfs`（metadata pool `cephfs_metadata`，data pool `cephfs_data`），1 active（ceph-01）+ 2 standby
- **RGW**：realm 中 `my-zone`，2 个 daemon（ceph-01 `roocpp`、ceph-02 `socnwm`），端点 `:7480`
- **S3 入口**：ceph-01 nginx 以 `*.rgw.lab.com` 对外提供 80/443，TLS 证书 `rgw.lab.com.crt`

---

## 五、Ceph 服务与配置

### 5.1 守护进程清单

| 角色 | 数量 | 分布 |
|------|------|------|
| mon | 3 | ceph-01、ceph-02、ceph-03（quorum 完整） |
| mgr | 2 | ceph-01（**active**）、ceph-02（standby） |
| mds | 3 | ceph-01（active）、ceph-02、ceph-03（standby） |
| osd | 6 | 每台 2 个 |
| rgw | 2 | ceph-01、ceph-02（1 zone） |
| crash | 3 | 每台一个 |

### 5.2 ceph.conf

```ini
[global]
	fsid = 594e535e-d82c-11f0-afa7-bc24112b746f
	mon_host = [v2:10.0.0.31:3300/0,v1:10.0.0.31:6789/0] [v2:10.0.0.41:3300/0,v1:10.0.0.41:6789/0] [v2:10.0.0.51:3300/0,v1:10.0.0.51:6789/0]
```

> ⚠️ 配置**极简**，未显式声明 `public_network` / `cluster_network`，依赖默认路由判定网络段。双网卡环境下建议显式配置，避免网络识别歧义。

### 5.3 mgr 模块

**已启用**：`balancer`、`crash`、`devicehealth`、`orchestrator`、`pg_autoscaler`、`progress`、`rbd_support`、`status`、`telemetry`、`volumes`、`cephadm`、`dashboard`、`iostat`、`nfs`、`prometheus`、`restful`、`rgw`

> ⚠️ **`telemetry` 已开启** —— 会向 ceph.com 上报匿名使用数据。若环境不允许外联或涉及数据合规，建议 `ceph mgr module disable telemetry`。
> 📌 `nfs` 模块已启用但未使用（ceph-02 跑的是系统原生 NFS，非 Ceph 内置 NFS）。

### 5.4 认证实体（存在冗余）

有效实体：`client.admin`、`client.cephfs`、`client.rbd`、`client.readonly`、`client.kubernetes`、`client.crash.*`、`client.rgw.*`、`mgr.*`、`mds.*`、`osd.0-5`

> ⚠️ **3 个认证实体指向不存在的 Pool**（历史遗留，建议清理）：
> - `client.pve` → `pve-rbd`（Pool 不存在）
> - `client.rbd` → `test-pool`（Pool 不存在）
> - `client.testuser` → `mypool`（Pool 不存在）

### 5.5 监控栈

| 组件 | 位置 | 端口 |
|------|------|------|
| Prometheus | ceph-01（容器，v2.43.0） | 9095 |
| Grafana | ceph-01（容器，ceph-grafana 9.4.7） | 3000 |
| Alertmanager | ceph-03（容器，v0.25.0） | 9093 / 9094 |
| node-exporter | 三台（容器，v1.5.0） | 9100 |

---

## 六、系统基线检查

| 检查项 | ceph-01 | ceph-02 | ceph-03 | 评价 |
|--------|:------:|:------:|:------:|------|
| SELinux | Disabled | Disabled | Disabled | ⚠️ 未启用 |
| firewalld | inactive | inactive | inactive | ⚠️ 未启用 |
| `vm.max_map_count` | 65530 | 65530 | 65530 | ⚠️ **低于 Ceph 推荐值 262144** |
| `net.core.rmem_max` | 212992 | 212992 | 212992 | ⚠️ 偏低（推荐 ≥16 MB） |
| `ulimit -n` | 1024 | 1024 | 1024 | ⚠️ 偏低（OSD 推荐 65536） |
| `/etc/security/limits.d/ceph.conf` | 不存在 | 不存在 | 不存在 | ⚠️ **未创建**，无 memlock/nofile 调优 |
| chrony 时间同步 | ✅ | ✅ | ✅ | 正常 |
| NTP 服务端/客户端 | ✅ | ✅ | ✅ | 正常 |

---

## 七、非 Ceph 业务进程（简要，详见专项报告）

> 完整分析见 `ceph_non_ceph_process_report.md`。

| 主机 | 非 Ceph 业务组件 | 风险 |
|------|-----------------|------|
| ceph-01 | nginx（RGW 的 S3 HTTPS 反向代理）、zabbix_agent2 | 低 |
| ceph-02 | **NFS 服务端**、**rsync**、**孤儿 php-fpm**、**Pushgateway**、**废弃 Harbor（仅 log 存活）**、zabbix_agent2 | 中 |
| ceph-03 | **ZooKeeper 3.8.5（root 运行，JMX 无认证）**、**Redis + Sentinel（口令复用 root）** | **高** |

---

## 八、风险汇总与建议

### 🔴 高危

1. **ZooKeeper JMX 无认证暴露且以 root 运行**（ceph-03:9999）
   `-Dcom.sun.management.jmxremote.authenticate=false`、`ssl=false`，JMX 可远程执行代码，而进程以 **root** 身份运行 → **等价于 root 权限远程代码执行**。
   **建议**：JMX 绑定 `127.0.0.1`、开启认证与 TLS、改用专用低权用户运行。

2. **Redis 弱口令 + 口令复用**（ceph-03:6379）
   `bind 0.0.0.0` + `protected-mode no` + `requirepass "<redacted-password>"`，与集群 root SSH 口令**完全相同**；Redis 泄露即 root 失陷。
   **建议**：改 `bind 127.0.0.1`（或限定内网网段）、开启 `protected-mode yes`、**立即轮换 root 口令**。

### 🟠 中危

3. **OSD/客户端资源限制未调优**：`vm.max_map_count=65530`（应为 262144）、`ulimit -n=1024`（应为 65536）、缺少 `limits.d/ceph.conf`。高负载下可能触发 BlueStore map 数量耗尽与文件句柄不足。
   **建议**：创建 `/etc/security/limits.d/ceph.conf`（`* soft nofile 65536` / `memlock unlimited`），并在 `sysctl.d/` 中固化 `vm.max_map_count=262144`。

4. **孤儿 PHP-FPM**（ceph-02）：无 Web 前端监听（nginx 包已卸载，仅残留 conf），`test.php` 内含明文 MySQL root 凭据 `Root123!`。
   **建议**：停用 php-fpm，清理 `/etc/nginx/conf.d/` 残留配置与测试页面，**修改该 MySQL 口令**。

5. **废弃 Harbor 部署**（ceph-02）：9 个容器 Exited(128) 3 个月，仅 `harbor-log` 因 `RestartPolicy=always` 仍在运行；残留 `harbor_harbor`、`docker_gwbridge` 无主网络；导致根分区使用率达 30%（三台最高）。
   **建议**：确认废弃后整体清理（`docker rm -f` 残留容器、`docker network rm` 无主网络、`docker image prune`）。

6. **NFS / rsync 双备份通道**（ceph-02）：`/playbook-backup` 导出至 `172.16.1.0/24`；rsync 模块 `backup` 对外开放 873 端口且 `use chroot = no`。
   **建议**：确认业务必要性；限制监听地址、启用 chroot、收紧导出范围。

7. **Pushgateway 启用管理 API**（ceph-02:9091，`--web.enable-admin-api` 暴露于 0.0.0.0）。
   **建议**：关闭管理 API 或置于反代 + basic auth 之后。

8. **无主机防火墙**（三台 firewalld 均关闭）：叠加上述 0.0.0.0 监听服务，攻击面偏大。
   **建议**：启用 firewalld，按最小端口清单放行（22、6789、3300、6800-6820、9283、8443、7480 等）。

### 🟡 低危 / 规范类

9. **ceph.conf 未声明 `public_network`/`cluster_network`**：双网卡环境下依赖默认路由，建议显式配置。

10. **`telemetry` 模块开启**：向外上报匿名数据，建议按合规要求评估是否关闭。

11. **3 个认证实体指向不存在的 Pool**（`client.pve` / `client.rbd`→test-pool / `client.testuser`→mypool）：建议 `ceph auth del` 清理。

12. **宿主机 CLI 版本落后**：`ceph-common-17.2.8` vs 守护进程 `18.2.8`。虽当前无故障，但排障时 CLI 行为可能与集群不一致；建议升级到与集群一致的 18.2.8。

13. **zabbix 配置含克隆残留**：ceph-01/02 的 `zabbix_agent2.conf` 同时存在 `Hostname=Zabbix server`（127.0.0.1）与 `Hostname=nfs01|backup`（172.16.1.61）两组生效项，建议清理。

---

## 九、结论

- **Ceph 集群本体健康**：`HEALTH_OK`，6/6 OSD 全 in，465 PG 全 active+clean，mon/mgr/mds 冗余完整，版本统一（18.2.8 reef）。
- **硬件为虚拟机**：3 台 KVM guest，总容量 180 GiB，属测试/实验环境规模；若用于生产需重新规划容量与冗余。
- **系统基线偏弱**：SELinux 与防火墙均关闭，内核/句柄限制未按 Ceph 推荐调优，是后续性能与稳定性隐患。
- **最大的问题在混部的非 Ceph 业务**：ceph-03 的 ZooKeeper（root 运行 + JMX 无认证）与 Redis（口令复用 root）构成高危；ceph-02 承载了废弃的 Harbor、NFS、rsync 等历史负载，职责不单一。

**建议处置顺序**：① ZooKeeper JMX 与 Redis 口令 → ② 轮换 root 口令 → ③ 启用防火墙 + 调优内核/句柄限制 → ④ 清理 ceph-02 孤儿与废弃组件 → ⑤ 配置与认证规范化。

---

*附：完整非 Ceph 进程分析见 `ceph_non_ceph_process_report.md`*
