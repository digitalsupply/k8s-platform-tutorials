#!/usr/bin/env bash
# 05 Linux 实验：权限、ACL、capability、文件系统、内存、进程、systemd 限制。
# 只在 /tmp 下创建临时文件，退出时清理；需要 root（setuid/setcap/systemd-run）。
#
# 用法：sudo bash linux_lab_experiments.sh
#
# 警告：会短暂创建 200MiB 文件、setuid 副本、transient systemd unit；
#       不要在生产高峰期执行。

set -uo pipefail

TMP=$(mktemp -d /tmp/linux-lab.XXXXXX)
UNIT="linux-lab-memlimit-$$"
BG_PIDS=()
cleanup() {
  for p in "${BG_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  systemctl stop "$UNIT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

section() { printf '\n\n===== %s =====\n' "$*"; }
run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || printf '[exit=%s]\n' "$?"
}
run_sh() {
  printf '\n$ %s\n' "$*"
  bash -c "$*" 2>&1 || printf '[exit=%s]\n' "$?"
}

section "0. 环境"
run_sh 'id; umask; uname -r; date -Is'
chmod 755 "$TMP"

section "1. UGO / umask"
run_sh "umask 077; touch $TMP/umask-077; ls -l $TMP/umask-077"
run_sh "umask 022; touch $TMP/umask-022; ls -l $TMP/umask-022"

section "2. ACL：UGO 不够用时"
run_sh "echo hello-acl > $TMP/acl-file; chmod 600 $TMP/acl-file; ls -l $TMP/acl-file"
run_sh "setfacl -m u:nobody:r $TMP/acl-file; getfacl -p $TMP/acl-file"
run_sh "su -s /bin/bash nobody -c 'cat $TMP/acl-file'"

section "3. setuid：以文件所有者身份运行"
run_sh "cp /usr/bin/id $TMP/id-suid; chmod 4755 $TMP/id-suid; ls -l $TMP/id-suid"
run_sh "su -s /bin/bash nobody -c '$TMP/id-suid'"
run_sh "chmod 0755 $TMP/id-suid; su -s /bin/bash nobody -c '$TMP/id-suid'"

section "4. file capability：只给一项能力，而不是整个 root"
if command -v setcap >/dev/null 2>&1 && command -v getcap >/dev/null 2>&1; then
  run_sh "cp /bin/ping $TMP/ping-cap; chmod 755 $TMP/ping-cap; setcap cap_net_raw+ep $TMP/ping-cap; getcap $TMP/ping-cap"
  run_sh "su -s /bin/bash nobody -c '$TMP/ping-cap -c 1 127.0.0.1'"
  run_sh "setcap -r $TMP/ping-cap; getcap $TMP/ping-cap || true"
else
  echo "setcap/getcap not installed, skip"
fi

section "5. 硬链接 / 符号链接 / 稀疏文件"
run_sh "echo data > $TMP/file; ln $TMP/file $TMP/hard; ln -s $TMP/file $TMP/sym; ls -li $TMP/file $TMP/hard $TMP/sym; stat -c '%n inode=%i links=%h size=%s blocks=%b' $TMP/file $TMP/hard $TMP/sym"
run_sh "truncate -s 1G $TMP/sparse; ls -lh $TMP/sparse; du -h $TMP/sparse; stat -c 'size=%s blocks=%b' $TMP/sparse"

section "6. 页缓存与可用内存"
run_sh "free -m"
run_sh "dd if=/dev/zero of=$TMP/cache bs=1M count=200 conv=fsync status=none; free -m; rm -f $TMP/cache; sync; free -m"

section "7. 进程优先级与僵尸进程"
run_sh "sleep 30 & p=\$!; renice 10 -p \$p >/dev/null; ps -o pid,ppid,ni,pri,stat,comm -p \$p; kill \$p"

cat > "$TMP/zombie.py" <<'PY'
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
open('/tmp/linux-lab-zombie.pid', 'w').write(str(pid))
time.sleep(30)
PY
python3 "$TMP/zombie.py" &
ZPARENT=$!
BG_PIDS+=("$ZPARENT")
sleep 1
ZPID=$(cat /tmp/linux-lab-zombie.pid 2>/dev/null || true)
if [[ -n "${ZPID:-}" ]]; then
  run_sh "ps -o pid,ppid,stat,comm -p $ZPID; grep -E '^(Name|State|PPid|Uid)' /proc/$ZPID/status 2>/dev/null"
fi
kill "$ZPARENT" 2>/dev/null || true
rm -f /tmp/linux-lab-zombie.pid

section "8. cgroup v2 + systemd 资源限制"
run_sh "systemd-run --unit=$UNIT --property=MemoryMax=64M --property=CPUQuota=20% --property=TasksMax=16 /bin/sleep 30"
run_sh "systemctl show $UNIT -p MemoryMax -p CPUQuota -p TasksMax -p LimitNOFILE -p LimitNPROC"
run_sh "systemctl status $UNIT --no-pager | head -12"
run_sh "cat /sys/fs/cgroup/system.slice/$UNIT.service/memory.max 2>/dev/null; cat /sys/fs/cgroup/system.slice/$UNIT.service/cpu.max 2>/dev/null"
run_sh "systemctl stop $UNIT"

section "9. ulimit 是进程属性，不是全局"
run_sh 'ulimit -n; (ulimit -n 64; ulimit -n); ulimit -n'

section "10. 结束"
run_sh 'date -Is'
