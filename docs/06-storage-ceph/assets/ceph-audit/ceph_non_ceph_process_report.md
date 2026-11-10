# Ceph 集群主机非 Ceph 进程分析报告

- **采集时间**：2026-10-02
- **集群 ID**：`594e535e-d82c-11f0-afa7-bc24112b746f`
- **集群健康**：`HEALTH_OK`（mon 3/3，osd 6/6 in，mds 1 active + 2 standby，rgw 2 active）
- **系统**：Rocky Linux 9.6，Kernel 5.14.0-570.58.1.el9_6
- **采集方式**：SSH root 免密 → `ps -eo`、`ss -tulnp`、`systemctl`、`docker ps`、配置文件

---

## 一、集群拓扑与角色

| 主机 | 业务 IP | 管理 IP | CPU / 内存 | Ceph 角色 |
|------|---------|---------|-----------|-----------|
| ceph-01 | 10.0.0.31 | 172.16.1.31 | 4C / 5.6G | mon、mgr(active)、**osd.0、osd.5**、mds(cephfs)、**rgw.myrgw**、node-exporter、**prometheus、grafana** |
| ceph-02 | 10.0.0.41 | 172.16.1.41 | 4C / 5.6G | mon、mgr(standby)、**osd.1、osd.4**、mds(standby)、**rgw.myrgw**、node-exporter |
| ceph-03 | 10.0.0.51 | — | 6C / 7.5G | mon、**osd.2、osd.3**、mds(standby)、node-exporter、alertmanager |

> 集群本身运行正常，以下均为**与 Ceph 无关的额外业务进程**。
> Ceph 组件本身通过 `ceph-volume` + systemd 以容器方式运行（`quay.io/ceph/ceph`），容器运行时 Docker 为必需依赖。

---

## 二、ceph-01（10.0.0.31）非 Ceph 进程

| 进程 | PID | 监听 | 说明 |
|------|-----|------|------|
| `nginx` (master + 4 worker) | 1220 / 1374-1379 | `0.0.0.0:80`、`0.0.0.0:443` | **S3 对象存储 HTTPS 反向代理**，`/etc/nginx/conf.d/rgw.conf` 将 `*.rgw.lab.com` 转发至本机 RGW `10.0.0.31:7480`，`proxy_buffering off`、`client_max_body_size 0` |
| `zabbix_agent2` | 926 | `*:10050` | Zabbix 监控 Agent |
| `chronyd` | 381384 | `udp/123` | NTP 客户端/服务端 |
| `rsyslogd` | — | — | 系统日志 |
| `crond` / `auditd` / `irqbalance` / `qemu-ga` / `NetworkManager` / `dbus-broker` / `sshd` | — | 22 | 操作系统基础服务 |

**说明**：nginx 属于 RGW 的 TLS 卸载层，业务上与 Ceph 强相关，但不是 Ceph 自带进程。

---

## 三、ceph-02（10.0.0.41）非 Ceph 进程 —— 问题最集中

### 3.1 NFS 服务端（完整 NFS 栈）

| 进程 | PID | 监听 |
|------|-----|------|
| `rpcbind` | 848 | tcp/udp `111` |
| `rpc.statd` | 1077 | tcp `39777`、udp `40307`/`834` |
| `rpc.mountd` | 1083 | tcp/udp `20048` |
| `rpc.idmapd` | 924 | — |
| `nfsdcld` | 925 | — |
| `nfsd` ×8 | 1121-1128 | `0.0.0.0:2049` |
| `lockd`、`NFSv4 callback` | 1104 / 1193 | — |

导出内容：`/etc/exports` → `/playbook-backup/ 172.16.1.0/24(rw,sync,all_squash)`

### 3.2 Web / PHP 栈（**孤儿进程**）

| 进程 | PID | 监听 |
|------|-----|------|
| `php-fpm` master + pool www ×5 | 957 / 1023-1027 | `127.0.0.1:9000` |

- PHP-FPM 以 `nginx` 用户运行，`pm.max_children=50`
- **nginx 实际未安装**（`rpm -q nginx` → not installed），但 `/etc/nginx/conf.d/` 仍残留 `php-fpm.conf`、`pushgateway.conf`
- 残留文件 `/usr/share/nginx/html/test.php`，内含**硬编码明文凭据**：`root / Root123!`（MySQL）

### 3.3 rsync 守护进程

| 进程 | PID | 监听 |
|------|-----|------|
| `rsync --daemon` | 960 | `0.0.0.0:873` |

模块 `backup` → `/data/backup`（9.1M），`auth users = backup`，`use chroot = no`

### 3.4 Prometheus Pushgateway

| 进程 | PID | 监听 |
|------|-----|------|
| `pushgateway` | 1075 | `0.0.0.0:9091` |

系统级 unit（非容器），`User=pushgateway`，`GOMAXPROCS=2`，启用了 **`--web.enable-admin-api`**。

### 3.5 Harbor 私有仓库 —— **已废弃部署，仅剩日志组件**

| 容器 | 状态 |
|------|------|
| `harbor-log` (goharbor/harbor-log:v2.8.6) | **Up 4 days (healthy)**，`RestartPolicy=always`，网络 `harbor_harbor`，`10514 → 127.0.0.1:1514` |
| `harbor-core` / `harbor-db` / `harbor-jobservice` / `harbor-portal` / `nginx` / `registry` / `registryctl` / `redis` | **Exited (128) 3 months ago** |

harbor-log 容器内进程：`/usr/local/bin/start.sh`(1669) → `crond`(1769) + `sudo -u #10000 rsyslogd`(1773) → `rsyslogd`(1789)
宿主机侧还有 `docker-proxy`(1740) 做端口映射。

残留 Docker 网络：`harbor_harbor`、`docker_gwbridge`（均为无主网络）。

### 3.6 其他

| 进程 | PID | 说明 |
|------|-----|------|
| `zabbix_agent2` | 963 | `Hostname=backup`，Server `172.16.1.61` |
| `gssproxy -D` | 965 | Kerberos 代理 |
| `chronyd` | 431769 | NTP |
| `dockerd` | 1073 | **配置中 `insecure-registries: ["10.0.0.41"]`**（为 Harbor 自用） |

---

## 四、ceph-03（10.0.0.51）非 Ceph 进程

### 4.1 Apache ZooKeeper 3.8.5

| 项 | 值 |
|----|-----|
| 进程 | `java ... QuorumPeerMain`，PID **987**，**以 root 身份运行** |
| 安装路径 | `/usr/local/zookeeper`（源码安装，非 RPM） |
| 内存 | -Xmx1000m，当前 RSS ≈ 84 MB |
| 集群成员 | `10.0.0.51:2888:3888`、`10.0.0.7:2888:3888`、`10.0.0.8:2888:3888` |
| 监听端口 | `2181`(client)、`3888`(election，仅 10.0.0.51)、`8080`(Jetty admin)、`45577`、**`9999`(JMX)** |

> ⚠️ **10.0.0.7 / 10.0.0.8 不属于本 Ceph 集群**，说明这是一套独立部署在外置机器上的 HA 基础设施，与 Ceph 节点混部。

### 4.2 Redis + Sentinel

| 进程 | PID | 监听 | 配置 |
|------|-----|------|------|
| `redis-server` | 1064 | `0.0.0.0:6379` | `bind 0.0.0.0`、**`protected-mode no`**、**`requirepass "<redacted-password>"`**、`appendonly yes` |
| `redis-sentinel` | 1063 | `0.0.0.0:26379` | `monitor mymaster 10.0.0.7 6379 2`；replica：10.0.0.51、10.0.0.8 |

> ⚠️ Redis 口令与集群 **root SSH 口令完全相同**（`<redacted-password>`）。

### 4.3 其他

`rsyslogd`、`chronyd`(408207)、`crond`、`auditd`、`irqbalance`、`qemu-ga`、`NetworkManager`、`dbus-broker`、`sshd`。

---

## 五、汇总：三台主机非 Ceph 业务组件一览

| 组件 | ceph-01 | ceph-02 | ceph-03 | 风险等级 |
|------|:-------:|:-------:|:-------:|---------|
| nginx（S3 反代） | ✅ | ❌(仅残留配置) | — | 低 |
| PHP-FPM（无 Web 前端） | — | ✅ | — | 中 |
| NFS 服务端 | — | ✅ | — | 中 |
| rsync 守护 | — | ✅ | — | 中 |
| Pushgateway | — | ✅ | — | 中 |
| Harbor（仅 log 在跑） | — | ✅ | — | 中 |
| Zabbix Agent | ✅ | ✅ | — | 低 |
| ZooKeeper | — | — | ✅ | **高** |
| Redis + Sentinel | — | — | ✅ | **高** |
| chrony / rsyslog / crond / auditd | ✅ | ✅ | ✅ | 低 |

---

## 六、风险与建议

### 高优先级

1. **ZooKeeper JMX 无认证暴露 + root 运行**（ceph-03:9999）
   `-Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false`，JMX 可直接执行代码，而进程以 root 运行 → 等同于 **root 权限远程代码执行**。
   建议：绑定 `127.0.0.1`、开启认证与 TLS、改用专用低权用户运行。

2. **Redis 弱暴露**（ceph-03:6379）
   `bind 0.0.0.0` + `protected-mode no` + 口令复用 root 口令 `<redacted-password>`。
   建议：改 `bind 127.0.0.1`（或内网网段）、开启 `protected-mode yes`、更换独立强口令。

3. **口令复用**：Redis 口令 = root SSH 口令 = 用户在需求中提供的口令，一旦 Redis 泄露即等于 root 失陷。建议立即轮换 root 口令。

### 中优先级

4. **孤儿 PHP-FPM**（ceph-02）：无 Web 前端监听，`127.0.0.1:9000` 无法访问，纯属资源浪费；`test.php` 含明文 MySQL root 凭据 `Root123!`。建议停用并清理残留 nginx 配置与测试文件。

5. **废弃 Harbor 部署**（ceph-02）：9 个容器 Exited 3 个月，仅 `harbor-log` 因 `RestartPolicy=always` 仍在运行并占用内存；`harbor_harbor`、`docker_gwbridge` 为无主网络。建议整体清理（`docker system prune` + 移除网络）。

6. **NFS + rsync 双备份通道**（ceph-02）：`/playbook-backup` 导出至 `172.16.1.0/24`，rsync 模块 `backup` 对外开放 873 端口且 `use chroot = no`。建议确认业务必要性，限制监听地址并开启 chroot。

7. **Pushgateway 启用管理 API**（ceph-02:9091）：`--web.enable-admin-api` 允许通过 HTTP 清空指标组，暴露在 `0.0.0.0`。建议关闭或置于反向代理 + basic auth 之后。

### 低优先级

8. **Zabbix 配置存在重复陈旧段落**：ceph-01 与 ceph-02 的 `zabbix_agent2.conf` 同时含 `Server=127.0.0.1` / `Hostname=Zabbix server`（第 82、146 行）与 `Server=172.16.1.61` / `Hostname=nfs01|backup`（第 494、496 行），系克隆自旧服务器残留，建议清理。

9. **容器运行时**：三台 Ceph 节点均运行 Docker/containerd，为 `ceph-container` 部署方式所必需（保留）；但 ceph-02 上运行了 Harbor 这类无关业务容器，破坏了节点职责单一性。

---

## 七、结论

Ceph 集群本身状态健康（`HEALTH_OK`，6 OSD 全 in，465 PG active+clean）。但三台节点上**普遍存在与 Ceph 无关的业务负载**：

- **ceph-01**：nginx 做 RGW 的 HTTPS 卸载（与 Ceph 相关性最高的额外进程）
- **ceph-02**：最"不干净"，承载了 NFS 服务端、rsync、孤儿 PHP-FPM、Pushgateway，以及一套**已废弃的 Harbor 私有仓库**（疑似由原 NFS/备份/Zabbix 服务器克隆而来）
- **ceph-03**：运行 **ZooKeeper + Redis/Sentinel**，且其集群伙伴（10.0.0.7 / 10.0.0.8）在本集群之外，属于混部的另一套 HA 基础设施

建议优先处置 **ZooKeeper JMX 无认证 + root 运行** 与 **Redis 弱口令/口令复用** 两项高危问题，其次清理 ceph-02 的孤儿与废弃组件。
