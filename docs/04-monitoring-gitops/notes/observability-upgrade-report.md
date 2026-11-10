# Ceph 集群诊断报告

> 生成时间: 2026-09-28 15:07 CST  
> 诊断节点: 10.0.0.31 (Ceph 管理节点)  
> 集群状态: HEALTH_WARN

---

## 1. 执行摘要

| 项目 | 状态 | 说明 |
|------|------|------|
| **集群健康** | ⚠️ WARN | 时钟偏移告警 |
| **PG 状态** | ✅ 正常 | 433 个 PG 全部 active+clean |
| **OSD 状态** | ✅ 正常 | 6 个 OSD 全部 up |
| **数据可用性** | ✅ 正常 | 数据可正常读写 |
| **时间同步** | ❌ 异常 | NTP 未同步，时钟偏移 |

**核心问题**: 集群存在时钟偏移，可能影响数据一致性和集群稳定性。

---

## 2. 集群基本信息

### 2.1 节点列表

| 节点 | IP | 角色 | 状态 |
|------|-----|------|------|
| ceph-01 | 10.0.0.31 | Mon + OSD | ✅ |
| ceph-02 | 10.0.0.32 | Mon + OSD | ✅ |
| ceph-03 | 10.0.0.33 | Mon + OSD | ✅ |
| ceph-04 | 10.0.0.34 | OSD | ✅ |
| ceph-05 | 10.0.0.35 | OSD | ✅ |
| ceph-06 | 10.0.0.36 | OSD | ✅ |

### 2.2 存储池状态

| 存储池 | PG 数 | 副本数 | 状态 |
|--------|-------|--------|------|
| rbd | 128 | 3 | ✅ active+clean |
| cephfs-data | 32 | 3 | ✅ active+clean |
| cephfs-metadata | 8 | 3 | ✅ active+clean |
| .rgw.root | 32 | 3 | ✅ active+clean |
| ... | ... | ... | ✅ |

**总计**: 433 个 PG，全部 active+clean

---

## 3. 问题诊断

### 3.1 时钟偏移告警 ⚠️

#### 告警详情

```
[WRN] MON_CLOCK_SKEW: clock skew detected on mon.ceph-03, mon.ceph-01
    mon.ceph-03 clock skew 0.110279s > max 0.05s (latency 0.0010179s)
    mon.ceph-01 clock skew 0.231388s > max 0.05s (latency 0.00093146s)
```

#### 影响分析

| 影响项 | 严重程度 | 说明 |
|--------|----------|------|
| 数据一致性 | 🔴 高 | 可能导致数据写入冲突 |
| 集群稳定性 | 🟡 中 | 可能触发不必要的 failover |
| 监控准确性 | 🟡 中 | 时间戳不准确影响监控 |
| 快照可靠性 | 🟡 中 | 快照时间点可能不一致 |

### 3.2 时间同步状态 ❌

#### 系统时间状态

```bash
# 当前节点时间状态
Local time: Mon 2026-0-28 15:07:48 CST
Universal time: Mon 2026-09-28 07:07:48 UTC
System clock synchronized: no
NTP service: active
```

#### NTP 同步状态

```bash
# chrony 跟踪状态
Reference ID    : 00000000 ()
Stratum         : 0
System time     : 0.000000098 seconds slow of NTP time
Last offset     : +0.000000000 seconds
RMS offset      : 0.000000000 seconds
Frequency       : 0.000 ppm slow
Residual freq   : +0.000 ppm
Skew            : 0.000 ppm
Root delay      : 1.000000000 seconds
Root dispersion : 0.000000000 seconds
Update interval : 0.0 seconds
Leap status     : Not synchronised
```

**问题**: NTP 服务运行中但未成功同步，系统时间比 NTP 时间慢约 0.1 秒。

---

## 4. 根本原因分析

### 4.1 可能原因

| 原因 | 可能性 | 说明 |
|------|--------|------|
| **NTP 服务器不可达** | 🔴 高 | 网络问题或 NTP 服务器故障 |
| **防火墙阻止** | 🟡 中 | UDP 123 端口被阻止 |
| **NTP 配置错误** | 🟡 中 | 配置了错误的 NTP 服务器 |
| **系统时间被手动修改** | 🟢 低 | 人为操作导致 |
| **VM 时钟问题** | 🟡 中 | 虚拟化环境时钟同步问题 |

### 4.2 排查步骤

#### 步骤 1: 检查 NTP 服务器连通性

```bash
# 测试 NTP 服务器连通性
ntpdate -q pool.ntp.org
# 或
chronyc sources -v
```

#### 步骤 2: 检查防火墙规则

```bash
# 检查 iptables
iptables -L -n | grep 123
# 检查 firewalld
firewall-cmd --list-all | grep ntp
```

#### 步骤 3: 检查 NTP 配置

```bash
# 查看 NTP 配置
cat /etc/chrony.conf
# 或
cat /etc/ntp.conf
```

#### 步骤 4: 检查系统日志

```bash
# 查看 NTP 相关日志
journalctl -u chronyd
# 或
grep ntp /var/log/messages
```

---

## 5. 解决方案

### 5.1 临时解决（立即执行）

#### 方案 A: 强制同步时间

```bash
# 停止 NTP 服务
systemctl stop chronyd

# 手动同步时间
ntpdate -u pool.ntp.org
# 或
chronyd -q 'server pool.ntp.org iburst'

# 重启 NTP 服务
systemctl start chronyd

# 验证同步状态
chronyc tracking
```

#### 方案 B: 使用其他 NTP 服务器

```bash
# 编辑 NTP 配置
vi /etc/chrony.conf

# 添加可靠的 NTP 服务器（阿里云）
server ntp.aliyun.com iburst
server ntp1.aliyun.com iburst
server ntp2.aliyun.com iburst
server ntp3.aliyun.com iburst
server ntp4.aliyun.com iburst
server ntp5.aliyun.com iburst
server ntp6.aliyun.com iburst
server ntp7.aliyun.com iburst

# 重启服务
systemctl restart chronyd
```

### 5.2 长期解决（推荐配置）

#### 配置可靠的 NTP 服务器

```bash
# /etc/chrony.conf 推荐配置
# 阿里云 NTP 服务器（国内推荐）
server ntp.aliyun.com iburst minpoll 4 maxpoll 6
server ntp1.aliyun.com iburst minpoll 4 maxpoll 6
server ntp2.aliyun.com iburst minpoll 4 maxpoll 6
server ntp3.aliyun.com iburst minpoll 4 maxpoll 6
server ntp4.aliyun.com iburst minpoll 4 maxpoll 6
server ntp5.aliyun.com iburst minpoll 4 maxpoll 6
server ntp6.aliyun.com iburst minpoll 4 maxpoll 6
server ntp7.aliyun.com iburst minpoll 4 maxpoll 6

# 本地时钟（作为后备）
local stratum 10

# 允许快速同步
makestep 1.0 3

# 日志记录
logdir /var/log/chrony
log tracking measurements statistics
```

#### 配置防火墙

```bash
# 允许 NTP 流量
firewall-cmd --add-service=ntp --permanent
firewall-cmd --reload

# 或 iptables
iptables -A INPUT -p udp --dport 123 -j ACCEPT
iptables -A OUTPUT -p udp --sport 123 -j ACCEPT
```

#### 配置自动同步

```bash
# 启用 NTP 服务
systemctl enable chronyd
systemctl start chronyd

# 设置开机同步
echo "chronyc makestep" >> /etc/rc.local
chmod +x /etc/rc.local
```

### 5.3 监控建议

```bash
# 创建监控脚本
cat > /usr/local/bin/check_ntp.sh << 'EOF'
#!/bin/bash
# 检查 NTP 同步状态
STATUS=$(chronyc tracking | grep "Leap status" | awk '{print $4}')
if [ "$STATUS" != "Normal" ]; then
    echo "NTP 同步异常: $STATUS"
    # 发送告警
    # curl -X POST ... 
fi
EOF

chmod +x /usr/local/bin/check_ntp.sh

# 添加到 crontab
echo "*/5 * * * * /usr/local/bin/check_ntp.sh" | crontab -
```

---

## 6. 验证步骤

### 6.1 验证时间同步

```bash
# 查看同步状态
chronyc tracking

# 查看时间源
chronyc sources -v

# 查看系统时间
timedatectl status
```

### 6.2 验证集群状态

```bash
# 检查 Ceph 集群状态
ceph -s
ceph health detail

# 检查 OSD 状态
ceph osd status
ceph osd tree
```

### 6.3 验证应用状态

```bash
# 检查相关 Pod 状态
kubectl get pods -n logging
kubectl get pods -n monitoring
kubectl get pods -n kube-system | grep ceph
```

---

## 7. 预防措施

### 7.1 定期维护

| 任务 | 频率 | 命令 |
|------|------|------|
| 检查 NTP 同步 | 每日 | `chronyc tracking` |
| 检查 Ceph 健康 | 每小时 | `ceph -s` |
| 检查系统时间 | 每周 | `timedatectl status` |
| 更新 NTP 配置 | 每月 | 审查配置文件 |

### 7.2 告警配置

```yaml
# Prometheus 告警规则示例
- alert: NTPOutOfSync
  expr: node_timex_sync_status != 1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "NTP 同步异常"
    description: "节点 {{ $labels.instance }} NTP 同步状态异常"

- alert: CephClockSkew
  expr: ceph_health_status{check="CLOCK_SKEW"} == 1
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Ceph 时钟偏移"
    description: "Ceph 集群检测到时钟偏移"
```

---

## 8. 总结

### 问题根因
- **直接原因**: NTP 时间同步失败，导致 Ceph 集群时钟偏移
- **根本原因**: NTP 服务器配置不当或网络连接问题
- **影响范围**: 日志和追踪数据可能丢失或不一致
- **当前状态**: 需要立即修复 NTP 同步

### 优先级
1. **P0 - 立即修复**: 恢复 NTP 时间同步
2. **P1 - 短期**: 配置可靠的 NTP 服务器
3. **P2 - 中期**: 部署监控和告警
4. **P3 - 长期**: 定期维护和优化

### 下一步行动
1. 执行临时修复命令强制同步时间
2. 配置可靠的 NTP 服务器
3. 验证 Ceph 集群状态
4. 部署监控和告警
5. 文档化运维流程

---

*报告生成时间: 2026-09-28 15:15 CST*
*诊断工具: kubectl, ceph, chronyc*
