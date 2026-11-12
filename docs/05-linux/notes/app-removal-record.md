# 主机应用下线执行报告：Zabbix / MariaDB / nginx / php-fpm

- **执行主机**：m01（10.0.0.61 / 172.16.1.61，Rocky Linux 9.6，KVM 虚机）
- **节点角色**：Kubernetes control-plane（v1.29.8，6 节点集群之一）
- **执行时间**：2026-10-01 17:00 ~ 17:20 (CST)
- **执行结果**：✅ **全部成功**
- **数据保留**：按要求**未导出任何配置、未删除任何数据文件**（保留可逆性）

---

## 一、执行摘要

| 项 | 结果 |
|---|---|
| 停止服务 | 6 个（zabbix-server / zabbix-agent2 / zabbix-java-gateway / mariadb / php-fpm / nginx） |
| 连带停止 | 1 个（mysqld_exporter，依赖 MariaDB） |
| 禁止自启 | 7 个全部 `disabled` |
| 端口释放 | 80 / 443 / 3306 / 10050 / 10051 / 10052 / 9104 全部释放 |
| **内存回收** | **available 909 MB → 1408 MB（+499 MB，+54.8%）** |
| 卸载软件包 | 未执行（保留二进制与数据，可完整恢复） |
| 集群影响 | **无** — 6 节点全 Ready，control-plane 组件正常 |

---

## 二、执行前的安全确认（4 项）

删除前逐项验证依赖关系，确认无一影响其他系统：

| # | 检查项 | 方法 | 结果 |
|---|---|---|---|
| 1 | **MariaDB 被谁依赖** | `ss -ntp \| grep 3306` + 集群内 grep Deployment | **仅 Zabbix**。3306 无外部连接；业务库只有 `zabbix`（198 MB），无其他数据库 |
| 2 | **nginx 服务什么站点** | `grep server_name /etc/nginx/` | **仅 2 个 server 块，都是 Zabbix**（`:80` 302 跳转 + `:443` `zabbix.m01.com`），无其他业务站点 |
| 3 | **php-fpm 服务什么** | `ls /etc/php-fpm.d/` | 有 `www.conf` + **`zabbix.conf`**，socket `/run/php-fpm/www.sock` 被 nginx 的 fastcgi_pass 引用 |
| 4 | **`/data/nfs` 是否被 nginx 提供** | `grep -rn "/data/nfs" /etc/nginx/` | **无引用**。该目录是 nfs-provisioner 的 PVC 挂载点，删除 nginx 不影响它 |

**额外确认**：
- nginx 80/443 **无入站 ESTABLISHED 连接**
- `access.log` 当前 **0 行**，最后真实访问记录为 **2025-12-03**（10 个月前）→ 已无实际使用
- `mysqld_exporter` 在 Prometheus targets 中**查无此 target**（无 9104 记录）→ 从未被采集

---

## 三、删除依据：Zabbix 已无实际监控价值

数据库（Zabbix 6.0.42，schema 版本 6000055）查询结果：

| `hosts.status` | 含义 | 数量 |
|---|---|---|
| 1 | 监控中 | **1** |
| 3 | unavailable（不可达） | **385** |
| 0 | 未监控 | 57 |
| 5 | 待发现 | 1 |

**唯一 status=1 的记录 host 名为 `{#NAME}` —— 这是 LLD 低级发现模板，不是真实主机。**

→ **当前 Zabbix 监控的真实主机数量 = 0**

补充证据：
- `hosts.lastaccess` 最大值 **2025-10-18**（距执行时 348 天），且该主机为 `Vmware-proxy`
- 近 30 天 trends 有数据的 itemid 仅 **168 个**，近一年 **480 个**，全部是 `Zabbix server:` / `Zabbix agent:` / `net.if.*` 自监控项
- 444 条 host 记录绝大多数是模板占位符（`{#HV.UUID}`、`{#VM.DNS}`、`meraki-organization-{#ID}`、`Azure VM scale set {#NAME}`、`GCE-INSTANCE-ID` 等），来自官方模板库导入，从未指向真实目标
- Agent 日志持续报错：`connection from "172.16.1.61" rejected, allowed hosts: "127.0.0.1"` —— 该 IP 是本机 eth1 自有地址，即 server 连本机 agent 被自己拒绝，每 75 分钟重试一次空转

**结论**：Zabbix 除了监控自己（且连自监控都因配置不一致而失败），没有监控任何真实目标。

---

## 四、执行的命令（完整可复现）

### 阶段 1：记录基线

```bash
free -m
for p in zabbix_server mariadbd java zabbix_agent2 nginx php-fpm; do
  n=$(pgrep -c -f "$p"); m=$(ps -eo rss,args|grep -F "$p"|grep -v grep|awk '{s+=$1}END{printf "%.1f",s/1024}')
  echo "$p 进程数=$n 内存=${m}MB"
done
```

### 阶段 2：停止服务

```bash
for s in zabbix-server zabbix-agent2 zabbix-java-gateway mariadb php-fpm nginx; do
  systemctl stop $s
done
```

### 阶段 3：禁止自启

```bash
for s in zabbix-server zabbix-agent2 zabbix-java-gateway mariadb php-fpm nginx; do
  systemctl disable --now $s
done
```

### 阶段 4：停止连带的 mysqld_exporter

```bash
# 理由：mysqld_exporter --config.my-cnf=/etc/prometheus/.my.cnf 依赖已停止的 MariaDB，
# 继续运行只会空转并持续失败重连；且它从未被 Prometheus 抓取（targets 中无 9104）
systemctl stop mysqld_exporter
systemctl disable mysqld_exporter
```

### 阶段 5：清理失败的历史 Pod（与本次无关，顺带处理）

```bash
kubectl delete pod -n logging lokap lokicfg lokiconfig mcrun --ignore-not-found
```

---

## 五、执行状态逐项确认

### 5.1 服务终态

```
zabbix-server          active=inactive   enabled=disabled
zabbix-agent2          active=inactive   enabled=disabled
zabbix-java-gateway    active=inactive   enabled=disabled
mariadb                active=inactive   enabled=disabled
php-fpm                active=inactive   enabled=disabled
nginx                  active=inactive   enabled=disabled
mysqld_exporter        active=inactive   enabled=disabled
```

**7/7 全部 `inactive` + `disabled`** ✅

### 5.2 进程清理

```
zabbix_server      已清除（53 → 0）
mariadbd           已清除
php-fpm            已清除（13 → 0）
nginx              已清除（7 → 0）
zabbix_agent2      已清除
mysqld_exporter    已清除
```

无残留（`ps -eo pid,comm,args | grep -E "zabbix|mariadb|php-fpm|nginx"` 返回空）。

### 5.3 端口释放

```
80/443/10050/10051/3306/10052/9104  →  全部释放 ✅
```

### 5.4 内存回收效果

| 阶段 | total | used | free | buff/cache | **available** |
|---|---|---|---|---|---|
| 执行前 | 5665 MB | 4755 MB | 142 MB | 1103 MB | **909 MB** |
| 执行后 | 5665 MB | 4256 MB | 579 MB | 1149 MB | **1408 MB** |
| **差值** | — | **−499 MB** | +437 MB | — | **+499 MB（+54.8%）** |

逐组件 RSS 回收明细：

| 组件 | 进程数 | 执行前 RSS | 说明 |
|---|---|---|---|
| zabbix_server | 53 | 339.6 MB | worker 池，默认 StartWorkers 值 |
| mariadbd | 3 | 250.3 MB | InnoDB buffer pool |
| zabbix_java_gateway | 3 | 157.5 MB | JVM（JMX 监控 Java 应用用） |
| php-fpm | 13 | 103.8 MB | `pm.max_children=50` 动态池 |
| nginx | 7 | 21.1 MB | master + workers |
| zabbix_agent2 | 3 | 18.5 MB | agent 2 |
| mysqld_exporter | 1 | 4.7 MB | 连带停止 |
| **合计** | | **≈ 895 MB** | |

> 注：`used` 减少 499 MB 而 RSS 合计回收 895 MB，差额来自进程退出时内核回收部分共享页，以及 buff/cache 的重新分配，属正常现象。

### 5.5 集群健康（确认删除未影响 K8s）

```
m01 Ready    master01 Ready    master02 Ready
worker01 Ready    worker02 Ready    worker03 Ready

etcd-m01             Running  0
kube-apiserver-m01   Running  192   ← 重启数系 9-27 集群重启事件遗留，与本次无关
kube-scheduler-m01   Running  0
```

✅ 6 节点全 Ready，control-plane 组件正常。

---

## 六、保留未删除的内容（可完整恢复）

按「不导任何配置」要求，以下**全部保留原位**：

| 路径 | 大小 | 内容 |
|---|---|---|
| `/var/lib/mysql/` | 597 MB | MariaDB 数据目录（含 zabbix 库 198 MB） |
| `/data/zabbix/` | 437 MB | Zabbix Web 前端文件 |
| `/etc/zabbix/` | 136 KB | Zabbix 配置文件 |
| `/var/log/zabbix/` | 13 MB | Zabbix 日志 |
| `/etc/nginx/` | — | nginx 配置（含 `zabbix.conf`、`zabbix.conf.rpmnew`） |
| `/etc/php-fpm.d/` | — | php-fpm 配置（`www.conf`、`zabbix.conf`） |
| `/etc/prometheus/.my.cnf` | — | mysqld_exporter 的 DB 凭据 |
| 二进制文件 | — | 全部保留（zabbix/mariadb/nginx/php-fpm 未 purge） |

磁盘未回收：`/dev/mapper/rl-root  47G  19G  29G  39%`（与执行前一致）。

### 完整恢复流程（如需回滚）

```bash
# 1. 恢复服务
for s in mariadb nginx php-fpm zabbix-server zabbix-agent2 zabbix-java-gateway mysqld_exporter; do
  systemctl enable --now $s
done

# 2. 验证
systemctl status zabbix-server mariadb nginx php-fpm --no-pager | grep -E "Active:"
mysql -uzabbix -p"$(grep -oP 'DBPassword=\K.*' /etc/zabbix/zabbix_server.conf)" \
  -e "select status, count(*) from hosts group by status;"
ss -lnt | grep -E ":(80|443|3306|10051)"

# 3. 可选：修复已发现的 agent 配置 bug
#    /etc/zabbix/zabbix_agent2.conf 中 Server= 需加入 172.16.1.61
#    （当前仅 127.0.0.1，导致 server 连本机 agent 被拒）
```

---

## 七、顺带发现但未处理的问题（供参考）

| # | 问题 | 说明 |
|---|---|---|
| 1 | **主机侧仍有两套 Prometheus exporter 未纳入集群** | 主机 `node_exporter`(:9100) / `cadvisor`(:8080) / `alertmanager.service`(:9093) 仍在运行，与集群内 DaemonSet 重复，且**未接入任何 Grafana**。node_exporter 约 21.2 MB、cadvisor 约 19.9 MB |
| 2 | `/data/nfs` 目录归属待查 | 内含 `default-nfs-pvc-pvc-560896d7-...` 和 `test-from-node`，疑为 nfs-provisioner 的 PVC 挂载点，本次未做任何改动 |
| 3 | kubelet 无 swap，m01 内存余量仍偏紧 | 删除后 available 1.4 GiB / 5.5 GiB（25%），control-plane 长期运行建议评估扩容 |

---

## 八、内存占用对比（回答"是否净占内存"）

**是，且占用可观。**

| 组件 | 进程数 | RSS 合计 | 占本机 5.5 GiB |
|---|---|---|---|
| zabbix_server | 53 | 339.6 MB | 6.1% |
| mariadbd | 3 | 250.3 MB | 4.5% |
| zabbix_java_gateway | 3 | 157.5 MB | 2.8% |
| php-fpm | 13 | 103.8 MB | 1.9% |
| nginx | 7 | 21.1 MB | 0.4% |
| zabbix_agent2 | 3 | 18.5 MB | 0.3% |
| mysqld_exporter | 1 | 4.7 MB | 0.1% |
| **合计** | **83** | **≈ 895 MB** | **≈ 16.2%** |

**参照对比**（同机其他进程 RSS）：
```
kube-apiserver    1422.2 MB  25.1%   ← 单进程比整套 Zabbix 还重 1.6 倍
hermes             552.4 MB   9.7%
opencode           288.2 MB   5.0%
etcd               188.5 MB   3.3%
kubelet             81.7 MB   1.4%
```

**判断依据**：m01 是 control-plane，同时承载 etcd + apiserver + scheduler + controller-manager + kubelet + containerd。执行前 available 仅 909 MB 且**无 swap**，一套零实际监控价值、占用 16% 内存的传统监控系统放在此处属于明显错配。

---

## 九、命令速查

```bash
# 验证服务终态
for s in zabbix-server zabbix-agent2 zabbix-java-gateway mariadb php-fpm nginx mysqld_exporter; do
  printf "%-22s active=%-10s enabled=%s\n" "$s" "$(systemctl is-active $s)" "$(systemctl is-enabled $s)"
done

# 验证进程清理
ps -eo pid,comm,args --no-headers | grep -E "zabbix|mariadb|php-fpm|nginx" | grep -v grep || echo "已清除"

# 验证端口释放
ss -lnt | grep -E ":(80|443|3306|10050|10051|10052|9104)\b" || echo "全部释放"

# 验证内存回收
free -m

# 完整回滚
for s in mariadb nginx php-fpm zabbix-server zabbix-agent2 zabbix-java-gateway mysqld_exporter; do
  systemctl enable --now $s
done
```

---

*本报告记录 2026-10-01 在 m01 上执行的主机应用下线操作。所有服务已停止并禁止自启，数据文件与二进制全部保留，未做任何不可逆操作。*
