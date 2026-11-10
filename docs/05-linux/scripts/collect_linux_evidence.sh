#!/usr/bin/env bash
# 只读采集 Linux 证据：内核/用户态/文件系统/权限/进程/内存/systemd/限制。
#
# 用法：
#   bash collect_linux_evidence.sh > evidence.txt
#   ssh root@host 'bash -s' < collect_linux_evidence.sh > evidence.txt
#
# 所有命令只读；不读取 /etc/shadow、Secret、kubeconfig、私钥。
# 输出用于教程举证，可按需删减。

set -uo pipefail

section() { printf '\n\n===== %s =====\n' "$*"; }
run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || printf '[exit=%s]\n' "$?"
}
run_sh() {
  printf '\n$ %s\n' "$*"
  bash -c "$*" 2>&1 || printf '[exit=%s]\n' "$?"
}
have() { command -v "$1" >/dev/null 2>&1; }

section "0. 采集元信息"
run_sh 'date -Is; hostname; hostname -f 2>/dev/null; whoami; id; uptime'
run_sh 'cat /etc/os-release 2>/dev/null | head -8'

section "1. 内核"
run uname -a
run_sh 'cat /proc/cmdline'
run_sh 'cat /proc/version'
run_sh 'cat /proc/sys/kernel/osrelease; cat /proc/sys/kernel/version'
run_sh 'ls -1 /boot 2>/dev/null | head -30'
run_sh 'cat /etc/default/grub 2>/dev/null | grep -v "^#" | head -20'
run_sh 'lsmod 2>/dev/null | head -40'
run_sh 'cat /proc/sys/kernel/pid_max; cat /proc/sys/kernel/threads-max; cat /proc/sys/kernel/randomize_va_space'
run_sh 'cat /proc/sys/kernel/kptr_restrict; cat /proc/sys/kernel/dmesg_restrict; cat /proc/sys/kernel/perf_event_paranoid'
run_sh 'cat /sys/kernel/security/lsm 2>/dev/null; cat /sys/module/apparmor/parameters/enabled 2>/dev/null'
run_sh 'journalctl -k -b --no-pager 2>/dev/null | tail -40'

section "2. 用户态 / libc / 启动"
run_sh 'readlink -f /sbin/init; cat /proc/1/comm; cat /proc/1/cgroup'
run_sh 'systemctl --version 2>/dev/null | head -3'
run_sh 'ldd --version 2>/dev/null | head -2; getconf GNU_LIBC_VERSION 2>/dev/null'
run_sh 'file /bin/ls 2>/dev/null; readelf -h /bin/ls 2>/dev/null | head -12'
run_sh 'getent passwd | head -15'
run_sh 'getent group | head -15'
run_sh 'who -a 2>/dev/null | head -10; last -n 5 2>/dev/null'
run_sh 'env | grep -E "^(PATH|LANG|SHELL|HOME|USER)=" | sort'

section "3. 文件系统与存储"
run_sh 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,ROTA,SCHED 2>/dev/null'
run_sh 'df -hT; echo; df -i'
run_sh 'findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | head -40'
run_sh 'cat /etc/fstab 2>/dev/null | grep -v "^#" | sed "/^$/d"'
run_sh 'mount | head -30'
run_sh 'cat /proc/diskstats | head -20'
run_sh 'stat -f / 2>/dev/null'
run_sh 'df -h / /var /var/lib/containerd /var/lib/kubelet 2>/dev/null'
if have losetup; then run_sh 'losetup -a 2>/dev/null | head'; fi
if have pvs; then
  run_sh 'pvs 2>/dev/null; vgs 2>/dev/null; lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent 2>/dev/null'
fi
if have tune2fs; then run_sh 'tune2fs -l $(findmnt -n -o SOURCE /) 2>/dev/null | grep -E "Filesystem volume name|Filesystem features|Block count|Inode count|Reserved block count|Mount count|Last checked|Errors behavior"'; fi
if have xfs_info; then run_sh 'xfs_info / 2>/dev/null | head -20'; fi
run_sh 'du -xhd1 / 2>/dev/null | sort -h | tail -15'

section "4. 权限模型"
run_sh 'umask; id; ls -ld / /root /tmp /etc/shadow /usr/bin/passwd /usr/bin/sudo 2>/dev/null'
run_sh 'ls -l /usr/bin/passwd /usr/bin/sudo /usr/bin/ping /usr/bin/su 2>/dev/null'
run_sh 'find / -xdev -perm -4000 -type f 2>/dev/null | head -60'
if have getcap; then run_sh 'getcap -r / 2>/dev/null | head -80'; fi
if have getfacl; then run_sh 'getfacl -p /tmp 2>/dev/null'; fi
if have capsh; then run_sh 'capsh --print 2>/dev/null'; fi
run_sh 'grep -E "^(Uid|Gid|Groups|Cap|NoNewPrivs|Seccomp|Speculation)" /proc/self/status'

section "5. 进程"
run_sh 'ps -eo pid,ppid,user,stat,ni,pri,pcpu,pmem,rss,vsz,comm --sort=-rss | head -25'
run_sh 'ps -eLf 2>/dev/null | wc -l; cat /proc/loadavg; cat /proc/pressure/cpu 2>/dev/null; cat /proc/pressure/memory 2>/dev/null; cat /proc/pressure/io 2>/dev/null'
for p in 1; do
  run_sh "cat /proc/$p/status 2>/dev/null | head -30"
  run_sh "ls -l /proc/$p/exe /proc/$p/cwd /proc/$p/root 2>/dev/null"
done
run_sh 'lsns 2>/dev/null | head -20'
run_sh 'systemctl list-units --type=service --state=running --no-pager 2>/dev/null | head -30'

section "6. 内存"
run_sh 'cat /proc/meminfo'
run free -h
if have vmstat; then run_sh 'vmstat 1 3'; fi
run_sh 'cat /proc/vmstat | grep -E "^(pgscan|pgsteal|pgmajfault|oom_kill|compact|nr_free_pages|nr_slab)" | head -30'
run_sh 'cat /proc/sys/vm/overcommit_memory; cat /proc/sys/vm/overcommit_ratio; cat /proc/sys/vm/swappiness; cat /proc/sys/vm/min_free_kbytes; cat /proc/sys/vm/dirty_ratio; cat /proc/sys/vm/dirty_background_ratio; cat /proc/sys/vm/vfs_cache_pressure'
run_sh 'cat /proc/buddyinfo; cat /proc/pagetypeinfo 2>/dev/null | head -20'
if have slabtop; then run_sh 'slabtop -o 2>/dev/null | head -25'; fi
if have systemd-cgtop; then run_sh 'systemd-cgtop -b -n 1 2>/dev/null | head -20'; fi
run_sh 'cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.events 2>/dev/null'

section "7. systemd 与启动"
run_sh 'systemd-analyze time 2>/dev/null; systemd-analyze blame 2>/dev/null | head -20; systemd-analyze critical-chain 2>/dev/null | head -30'
run_sh 'systemctl list-unit-files --state=enabled --no-pager 2>/dev/null | head -35'
run_sh 'journalctl -b --no-pager 2>/dev/null | head -40'
run_sh 'journalctl -b -p err --no-pager 2>/dev/null | tail -30'
if have bootctl; then run_sh 'bootctl status 2>/dev/null | head -30'; fi
if have efibootmgr; then run_sh 'efibootmgr -v 2>/dev/null | head -20'; fi

section "8. 内核参数与资源限制"
run_sh 'ulimit -a'
run_sh 'cat /etc/security/limits.conf 2>/dev/null | grep -v "^#" | sed "/^$/d"'
run_sh 'for f in /etc/security/limits.d/*.conf; do [ -f "$f" ] && { echo "### $f"; grep -v "^#" "$f" | sed "/^$/d"; }; done 2>/dev/null'
run_sh 'cat /proc/sys/fs/file-nr; cat /proc/sys/fs/file-max; cat /proc/sys/fs/nr_open'
run_sh 'cat /proc/sys/net/core/somaxconn; cat /proc/sys/net/ipv4/ip_local_port_range; cat /proc/sys/net/ipv4/tcp_max_syn_backlog'
run_sh 'sysctl kernel.pid_max kernel.threads-max vm.overcommit_memory vm.swappiness fs.file-max net.core.somaxconn net.ipv4.ip_forward net.ipv4.conf.all.rp_filter 2>/dev/null'
for svc in containerd kubelet sshd ssh docker; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    run_sh "systemctl show ${svc}.service -p LimitNOFILE -p LimitNPROC -p LimitCORE -p MemoryMax -p CPUQuota 2>/dev/null"
  fi
done

section "9. K8s / 容器运行时（如存在）"
if have kubectl; then
  run_sh 'kubectl get nodes -o wide 2>/dev/null | head -10'
  run_sh 'kubectl top nodes 2>/dev/null | head -10'
fi
if have crictl; then
  run_sh 'crictl version 2>/dev/null; crictl info 2>/dev/null | head -40'
fi
if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
  run_sh 'systemctl status containerd --no-pager 2>/dev/null | head -20'
fi
if systemctl list-unit-files kubelet.service >/dev/null 2>&1; then
  run_sh 'systemctl status kubelet --no-pager 2>/dev/null | head -20'
fi

section "10. Ceph 客户端（如存在）"
if have ceph; then
  run_sh 'ceph -s 2>/dev/null'
  run_sh 'ceph df detail 2>/dev/null | head -40'
  run_sh 'ceph osd tree 2>/dev/null'
  run_sh 'ceph versions 2>/dev/null'
fi

section "11. 结束"
run_sh 'date -Is'
