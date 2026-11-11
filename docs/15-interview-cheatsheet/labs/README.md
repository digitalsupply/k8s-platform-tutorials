# 面试题实验手册

> 目标：把“一句话答案”变成能在机器上复现的证据。
> 除特别说明，全部只读；实验只在 `/tmp`/loopback。

## 1. 硬链接 / 软链接 / 稀疏文件

```bash
TMP=$(mktemp -d); chmod 755 "$TMP"
echo data > "$TMP/file"
ln "$TMP/file" "$TMP/hard"
ln -s "$TMP/file" "$TMP/sym"
ls -li "$TMP/file" "$TMP/hard" "$TMP/sym"
stat -c '%n inode=%i links=%h size=%s blocks=%b' "$TMP/file" "$TMP/hard" "$TMP/sym"

truncate -s 1G "$TMP/sparse"
ls -lh "$TMP/sparse"; du -h "$TMP/sparse"
rm -rf "$TMP"
```

## 2. 僵尸进程

```bash
sudo bash docs/05-linux/scripts/linux_lab_experiments.sh
# 或看输出里的第 7 节：ps -o stat 显示 Z，/proc/<pid>/status State: Z
```

## 3. load 高 CPU 低

```bash
cat /proc/loadavg
vmstat 1 3
cat /proc/pressure/io
ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'
```

本机不一定有 D 状态；GitLab 201 的 IO PSI 是真实压力证据。

## 4. free 的 cache

```bash
free -h
cat /proc/meminfo | grep -E 'MemAvailable|Cached|AnonPages'
```

## 5. df/du 不一致（deleted open file）

```bash
python3 - <<'PY'
import os, time
p='/tmp/df-du-deleted.bin'
with open(p,'wb') as f: f.write(b'x'*(200*1024*1024))
f=open(p,'rb'); os.unlink(p)
print('deleted but open'); time.sleep(5)
PY
# 另一个窗口
lsof +L1 2>/dev/null | grep df-du-deleted
```

## 6. ulimit / systemd

```bash
ulimit -Sn; ulimit -Hn
grep 'Max open files' /proc/self/limits
systemctl show sshd -p LimitNOFILE
sysctl fs.file-max fs.nr_open
```

## 7. cgroup v2

```bash
stat -fc '%T' /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
cat /sys/fs/cgroup/cgroup.subtree_control
```

## 8. 三次握手抓包

```bash
python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 &
S=$!
tcpdump -i lo -c 10 -nn 'tcp port 18080' > /tmp/handshake.txt 2>/dev/null &
T=$!
sleep 1
curl -s -o /dev/null http://127.0.0.1:18080/
sleep 1
kill $S 2>/dev/null; wait $T 2>/dev/null
cat /tmp/handshake.txt
```

## 9. TIME_WAIT / CLOSE_WAIT

```bash
ss -s
for s in established syn-sent time-wait close-wait; do
  printf '%-12s ' "$s"; ss -tan state $s | tail -n +2 | wc -l
done
```

CLOSE_WAIT 实验：

```bash
python3 - <<'PY'
import socket, time, subprocess
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(('127.0.0.1',0)); port=srv.getsockname()[1]; srv.listen(1)
cli=socket.create_connection(('127.0.0.1',port)); conn,_=srv.accept()
cli.close(); time.sleep(1)
print(subprocess.run(['ss','-tan','sport','=',':'+str(port)],capture_output=True,text=True).stdout)
conn.close(); srv.close()
PY
```

## 10. refused / timeout / reset

```bash
python3 - <<'PY'
import socket, threading, time
try: socket.create_connection(('127.0.0.1',1),timeout=2)
except Exception as e: print('refused:',type(e).__name__,e)
try: socket.create_connection(('10.255.255.1',81),timeout=2)
except Exception as e: print('timeout:',type(e).__name__,e)
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(('127.0.0.1',0)); port=srv.getsockname()[1]; srv.listen(1)
def server():
    c,_=srv.accept(); c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,b'\x01\x00\x00\x00\x00\x00\x00\x00'); c.close()
t=threading.Thread(target=server); t.start()
try:
    c=socket.create_connection(('127.0.0.1',port),timeout=2); time.sleep(.2)
    c.sendall(b'hello'); time.sleep(.2); c.recv(10)
except Exception as e: print('reset:',type(e).__name__,e)
finally: t.join(timeout=2); srv.close()
PY
```

## 11. OOMKilled / Evicted

```bash
kubectl describe pod <pod> | grep -i -E 'oom|evict|exit|reason'
kubectl describe node <node> | grep -i pressure
kubectl get pods -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name,.status.reason] | @tsv' | grep -i evicted
cat /sys/fs/cgroup/.../memory.events
journalctl -k | grep -i oom
```

## 12. tini / PID 1

```bash
PID=$(ps -eo pid,args | awk '/frpc/ && !/awk/ {print $1; exit}')
grep -E '^(Name|Pid|PPid|NSpid)' /proc/$PID/status
crictl inspect <id> | jq '.info.runtimeSpec.process.args'
```

`NSpid: 2236 1` 表示容器内 PID 1。

## 13. epoll

```bash
PID=$(docker inspect -f '{{.State.Pid}}' nginx 2>/dev/null)
for p in $(docker top nginx -eo pid 2>/dev/null | tail -n +2); do
  ls -l /proc/$p/fd 2>/dev/null | grep eventpoll
done
```

或任意高并发进程：

```bash
ls -l /proc/<pid>/fd | grep eventpoll
cat /proc/<pid>/fdinfo/<fd>
```

## 14. Ubuntu 24.04 / Rocky 9

```bash
# Ubuntu 24.04
. /etc/os-release; echo "$PRETTY_NAME"
python3 --version
netplan --version 2>/dev/null | head -1
python3 -c "import distutils; print(distutils.__file__)" 2>&1
python3 -S -c "import distutils" 2>&1 | head -2

# Rocky 9
. /etc/os-release; echo "$PRETTY_NAME"
dnf --version | head -1
nmcli --version
nft --version
getenforce
ls /etc/sysconfig/network-scripts
```

> 本手册的命令都可以在仓库 `assets/evidence/` 找到对应输出。
