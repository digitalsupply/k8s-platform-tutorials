# 05 Linux 实验手册

> 目标：在真实机器上把 8 个主题各跑一遍。
> 所有实验优先只读；会改系统的实验只在 `/tmp` 或 transient unit 中做，并清理。

## 实验 0：采集一台机器的完整证据

```bash
# 本地
bash docs/05-linux/scripts/collect_linux_evidence.sh > /tmp/$(hostname)-evidence.txt

# 远程
ssh root@10.0.0.61 'bash -s' < docs/05-linux/scripts/collect_linux_evidence.sh > /tmp/m01-evidence.txt
```

对照 [`../assets/evidence/README.md`](../assets/evidence/README.md) 看输出结构。

## 实验 1：内核

```bash
uname -a
cat /proc/cmdline
cat /proc/version
lsmod | head
grep -R . /etc/modules-load.d/ 2>/dev/null
sysctl kernel.pid_max vm.swappiness fs.file-max
cat /sys/kernel/security/lsm
journalctl -k -b --no-pager | tail -30
```

验收：

- 能说出当前内核版本、启动参数、LSM；
- 能解释 `br_netfilter` 与 `net.bridge.bridge-nf-call-iptables` 的关系。

## 实验 2：用户态

```bash
readlink -f /sbin/init
cat /proc/1/comm
ldd --version | head -2
file /bin/ls
readelf -h /bin/ls | head
ldd /bin/ls
ssh root@10.0.0.61 'echo PATH=$PATH'
ssh root@10.0.0.61 'bash -lc "echo PATH=$PATH"'
```

验收：

- 能解释为什么 `ssh host cmd` 和登录 shell 的 `PATH` 不同；
- 能解释 `GLIBC_2.xx not found` 与 CPU `SIGILL` 的区别。

## 实验 3：文件系统

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
df -hT; df -i
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | head
stat -f /
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent 2>/dev/null

TMP=$(mktemp -d); chmod 755 "$TMP"
echo data > "$TMP/file"; ln "$TMP/file" "$TMP/hard"; ln -s "$TMP/file" "$TMP/sym"
ls -li "$TMP/file" "$TMP/hard" "$TMP/sym"
truncate -s 1G "$TMP/sparse"; ls -lh "$TMP/sparse"; du -h "$TMP/sparse"
rm -rf "$TMP"
```

验收：

- 能解释 `df` 与 `du` 的差异；
- 能解释硬链接/符号链接/稀疏文件；
- 能在 PVE 上找到 thin pool（`lvs`）。

## 实验 4：权限（会创建 setuid/capability 副本）

```bash
sudo bash docs/05-linux/scripts/linux_lab_experiments.sh
```

或手动：

```bash
TMP=$(mktemp -d); chmod 755 "$TMP"
cp /usr/bin/id "$TMP/id-suid"; chmod 4755 "$TMP/id-suid"
su -s /bin/bash nobody -c "$TMP/id-suid"
cp /bin/ping "$TMP/ping-cap"; setcap cap_net_raw+ep "$TMP/ping-cap"
su -s /bin/bash nobody -c "$TMP/ping-cap -c 1 127.0.0.1"
rm -rf "$TMP"
```

验收：

- 能解释 `euid=0` 与 `uid=65534`；
- 能解释 capability 比 setuid 更小粒度；
- 能说出 `CAP_SYS_ADMIN` 为什么危险。

## 实验 5：进程

```bash
ps -eo pid,ppid,user,stat,ni,pri,pcpu,pmem,rss,vsz,comm --sort=-rss | head -20
ps -eLf | wc -l
cat /proc/loadavg
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io

sleep 30 & p=$!; renice 10 -p $p; ps -o pid,ni,pri,stat,comm -p $p; kill $p

# 僵尸（用脚本里的实验更稳）
python3 - <<'PY'
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
print("zombie child", pid)
time.sleep(10)
PY
```

验收：

- 能解释 `R/S/D/Z`；
- 能解释 load average 为什么包含 `D`；
- 能解释容器 PID namespace 与宿主机 PID。

## 实验 6：内存

```bash
cat /proc/meminfo
free -h
vmstat 1 3
cat /proc/pressure/memory
sysctl vm.overcommit_memory vm.swappiness
cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.events

free -m
dd if=/dev/zero of=/tmp/cache-test bs=1M count=200 conv=fsync status=none
free -m
rm -f /tmp/cache-test; sync; free -m
```

验收：

- 能解释 `free`/`available`/`buff/cache`；
- 能解释 `Committed_AS` 与 OOM 的关系；
- 能读懂 cgroup `memory.events`。

## 实验 7：systemd 与启动

```bash
systemd-analyze time
systemd-analyze blame | head -20
systemd-analyze critical-chain | head -30
systemctl --failed
systemctl list-timers --all

systemd-run --unit=lab-mem --property=MemoryMax=64M --property=CPUQuota=20% /bin/sleep 30
systemctl show lab-mem -p MemoryMax -p CPUQuota -p TasksMax
cat /sys/fs/cgroup/system.slice/lab-mem.service/memory.max
systemctl stop lab-mem
```

验收：

- 能区分 firmware/loader/kernel/userspace；
- 能解释 `After=` 与 `Requires=`；
- 能用 transient unit 做资源限制实验。

## 实验 8：内核参数与限制

```bash
ulimit -Sn; ulimit -Hn
grep -E 'Max open files|Max processes' /proc/self/limits
systemctl show sshd -p LimitNOFILE -p LimitNPROC
sysctl fs.file-max fs.nr_open kernel.pid_max kernel.threads-max
cat /proc/sys/fs/file-nr

( ulimit -n 4096; ulimit -Sn )
ulimit -Sn
```

验收：

- 能解释 soft/hard、`LimitNOFILE`、`fs.nr_open`、`fs.file-max`；
- 能解释为什么 `ulimit -n` 是 1024，而 systemd 显示 524288；
- 能说出改 sysctl 后如何持久化。

## 清理

```bash
# 确认没有实验残留
ps -ef | grep -E 'lab-|zombie' | grep -v grep
systemctl list-units 'lab-*' --all
ls -d /tmp/linux-lab.* 2>/dev/null
```

> 真实机器上做实验前，先确认不是生产高峰期；不要在生产节点上改 `rp_filter`、swap、
> 文件系统挂载参数，除非你有回滚方案。
