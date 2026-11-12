# 04 · 权限模型：从 UGO 到 ACL、setuid 与 capability

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 4 节、
> [`k8s-m01/collect.txt`](assets/evidence/k8s-m01/collect.txt) 第 4 节、
> [`assets/evidence/experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt)、
> [`assets/evidence/k8s-security/pod-security-summary.txt`](assets/evidence/k8s-security/pod-security-summary.txt)。
>
> 这一章把“`rwx` 三个字母”一路讲到容器里的 `CAP_SYS_ADMIN`、seccomp 和 `no_new_privs`。

## 1. 当时的情况

- `/etc/shadow` 在 PVE/Ubuntu 上是 `640 root:shadow`，在 m01 上是 `000 root:root`；
- `/usr/bin/sudo`、`passwd`、`su` 带 setuid；`ping` 是 file capability；
- 容器里 **Ceph-CSI nodeplugin、BuildKit 是 `privileged`**；Cilium agent **不是**（`drop: ALL` + 13 个 capability）；
- 普通应用 Pod 有的加了 `SYS_ADMIN`、`DAC_OVERRIDE`；
- 35 个 Pod 使用 hostNetwork，10 个 privileged（9 个 ceph-csi-rbd + 1 个 buildkitd，2026-11-11 实测）；
- 有人把“root 能读”当成“权限没问题”，忽略了 capability/LSM/seccomp。

## 2. 主要概念

### 2.1 UGO：最基础的三组位

```text
-rwxr-xr-x 1 root root ... /usr/bin/ls
 │└┬┘└┬┘└┬┘
 │ │  │  └─ other: r-x
 │ │  └──── group: r-x
 │ └─────── user:  rwx
 └───────── 文件类型
```

八进制：

| 位 | 值 |
|---|---:|
| `r` | 4 |
| `w` | 2 |
| `x` | 1 |
| `rwx` | 7 |
| `r-x` | 5 |
| `rw-` | 6 |

```bash
chmod 750 file      # rwxr-x---
chmod u+x file      # 给 owner 加执行
chown root:shadow /etc/shadow
```

### 2.2 umask：新文件的默认权限

`umask` 是“要拿掉的位”：

```text
文件默认 666 & ~umask
目录默认 777 & ~umask
```

`umask 022`：

- 文件 `644`（`rw-r--r--`）；
- 目录 `755`（`rwxr-xr-x`）。

`umask 077`：

- 文件 `600`；
- 目录 `700`。

真实实验：

```text
$ umask 077; touch umask-077; ls -l
-rw------- ...

$ umask 022; touch umask-022; ls -l
-rw-r--r-- ...
```

### 2.3 ACL：UGO 不够用时

ACL 允许给“某个用户/组”单独授权，而不改变 owner/group：

```bash
setfacl -m u:nobody:r file
getfacl file
```

真实结果：

```text
# file: acl-file
# owner: root
# group: root
user::rw-
user:nobody:r--
group::---
mask::r--
other::---
```

`mask` 是 ACL 的“最大权限”，`getfacl` 里 `#effective` 会显示实际生效值。

### 2.4 setuid / setgid / sticky

| 位 | 符号 | 作用 |
|---|---|---|
| setuid | `rws` | 执行时 euid = 文件 owner |
| setgid | `r-s`（组位为 s，组执行位本身不置位时显示 `S`） | 执行时 egid = 文件 group；目录下新文件继承组 |
| sticky | `rwt` | 目录下只有 owner/root 能删自己的文件（`/tmp`） |

真实实验：

```text
$ cp /usr/bin/id id-suid; chmod 4755 id-suid
-rwsr-xr-x ... id-suid

$ su -s /bin/bash nobody -c './id-suid'
uid=65534(nobody) gid=65534(nogroup) euid=0(root) ...

$ chmod 0755 id-suid
$ su ... './id-suid'
uid=65534(nobody) ... euid=65534(nobody)
```

**setuid 脚本通常被忽略**（内核不执行脚本的 setuid 位），所以不要把安全逻辑写成 setuid shell 脚本。

### 2.5 从 setuid 到 capability：为什么需要“部分 root”

setuid root 给的是**全部 root 权限**。但很多程序只需要一项能力：

- `ping` 只需要 `CAP_NET_RAW`；
- `passwd` 需要改 `/etc/shadow`（`CAP_DAC_OVERRIDE`/`CAP_CHOWN` 等）；
- `tcpdump` 需要 `CAP_NET_RAW`/`CAP_NET_ADMIN`；
- Web 服务绑定 80 端口只需要 `CAP_NET_BIND_SERVICE`。

Linux capability 把 root 权限拆成约 40 个独立位：

| 集合 | 含义 |
|---|---|
| Permitted | 进程“最多可以拥有”的能力 |
| Effective | 当前实际生效的能力 |
| Inheritable | 可被 exec 继承的能力 |
| Bounding | 进程能力上限（不能再获得） |
| Ambient | 非特权程序 exec 后保留的能力 |

查看：

```bash
capsh --print
grep -E 'Cap(Inh|Prm|Eff|Bnd|Amb)' /proc/self/status
getcap -r / 2>/dev/null | head
```

真实实验：

```text
$ cp /bin/ping ping-cap
$ setcap cap_net_raw+ep ping-cap
$ getcap ping-cap
ping-cap cap_net_raw=ep

$ su -s /bin/bash nobody -c './ping-cap -c 1 127.0.0.1'
64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.057 ms
```

没有 setuid、没有 root，只给了一项 `CAP_NET_RAW`。

### 2.6 `no_new_privs`、seccomp、LSM

- **no_new_privs**：进程及子进程不能再通过 setuid/file cap 提权；
- **seccomp**：限制可调用的 syscall；
- **LSM**：SELinux/AppArmor 的强制访问控制。

查看：

```bash
grep -E 'NoNewPrivs|Seccomp|CapEff' /proc/self/status
```

K8s 里对应：

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

### 2.7 容器权限：namespace + capability + LSM + seccomp

容器不是“轻量 VM”，而是：

```text
namespace 隔离（PID/NET/MNT/UTS/IPC/USER）
  + cgroup 限制
  + capability 裁剪
  + seccomp 过滤
  + LSM（SELinux/AppArmor）
```

任何一个没配好，容器都可能突破隔离。

## 3. 真机证据

### 3.1 文件模式

```text
# PVE 宿主
drwxr-xr-x 19 root root ... /
-rw-r-----  1 root shadow ... /etc/shadow
drwx------ 23 root root ... /root
drwxrwxrwt 19 root root ... /tmp
-rwsr-xr-x  1 root root ... /usr/bin/passwd
-rwsr-xr-x  1 root root ... /usr/bin/sudo

# m01（Rocky）
----------   1 root root ... /etc/shadow
-rwsr-xr-x.  1 root root ... /usr/bin/passwd
---s--x--x.  1 root root ... /usr/bin/sudo
```

注意：

- `/etc/shadow` 的 `000` 是**更严格**的权限，但某些工具/审计脚本可能因此读不到；
- `sudo` 的 `---s--x--x` 仍然有 setuid 位，普通用户可执行，但读权限被收紧；
- `/tmp` 的 `t` 是 sticky bit。

### 3.2 setuid 清单（节选）

PVE 宿主：

```text
/usr/sbin/mount.nfs
/usr/sbin/mount.cifs
/usr/lib/dbus-1.0/dbus-daemon-launch-helper
/usr/lib/openssh/ssh-keysign
/usr/bin/chfn
/usr/bin/proxmox-mail-forward
/usr/bin/newuidmap
/usr/bin/newgidmap
/usr/bin/su
/usr/bin/passwd
/usr/bin/sudo
/usr/bin/gpasswd
/usr/bin/ntfs-3g
/usr/bin/umount
/usr/bin/procmail
/usr/bin/newgrp
/usr/bin/mount
```

注意：`find / -xdev -perm -4000` 也会扫到 `/var/lib/docker/overlay2/**` 和
`/var/lib/containerd/**` 里的镜像层——**这不是宿主机的 setuid 程序**。审计时要排除容器存储：

```bash
find / -xdev -path /var/lib/docker -prune -o -path /var/lib/containerd -prune -o \
  -perm -4000 -type f -print 2>/dev/null
```

### 3.3 file capability

```text
# PVE
/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_admin=ep
/usr/bin/ping cap_net_raw=ep

# m01
/usr/local/bin/kube-apiserver cap_net_bind_service=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
coredns cap_net_bind_service=ep
```

### 3.4 当前 shell 的权限

```text
$ capsh --print
Current: =ep
Bounding set =cap_chown,cap_dac_override,...,cap_bpf,cap_checkpoint_restore
Ambient set =

$ grep -E 'Cap|NoNewPrivs|Seccomp' /proc/self/status
CapInh: 0000000000000000
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff
CapBnd: 000001ffffffffff
CapAmb: 0000000000000000
NoNewPrivs: 0
Seccomp: 0
```

root shell 默认拥有几乎全部 capability。**这就是为什么“root 能读”不能代表“最小权限”。**

### 3.5 K8s Pod 权限统计（138 个 Pod）

```text
summary: pods=138 hostNetwork=35 privileged=10 capAdd=19
```

典型：

| Pod | hostNetwork | privileged | added capabilities |
|---|---|---|---|
| `cilium-*` | true | true | `NET_ADMIN,NET_RAW,SYS_ADMIN,SYS_MODULE,SYS_PTRACE,...` |
| `rbd.csi.ceph.com-nodeplugin-*` | true | true | `SYS_ADMIN` |
| `buildkitd-*` | false | true | - |
| `deeptutor-*` | false | false | `CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID` |
| `coredns-*` | false | false | `NET_BIND_SERVICE` |
| `kube-vip-ds-*` | true | false | `NET_ADMIN,NET_RAW` |
| `node-exporter-*` | true | false | - |

这些不是“配置错误”，而是 CNI/CSI/构建器的必要权限；但它们必须有对应的 RBAC/NetworkPolicy/
准入控制，不能随便让业务 Pod 也这样。

## 4. 实验：自己验证 setuid 和 capability

```bash
TMP=$(mktemp -d); chmod 755 "$TMP"

# ACL
echo hello > "$TMP/file"; chmod 600 "$TMP/file"
setfacl -m u:nobody:r "$TMP/file"
getfacl "$TMP/file"
su -s /bin/bash nobody -c "cat $TMP/file"

# setuid
cp /usr/bin/id "$TMP/id-suid"; chmod 4755 "$TMP/id-suid"
su -s /bin/bash nobody -c "$TMP/id-suid"

# capability
cp /bin/ping "$TMP/ping-cap"; setcap cap_net_raw+ep "$TMP/ping-cap"
getcap "$TMP/ping-cap"
su -s /bin/bash nobody -c "$TMP/ping-cap -c 1 127.0.0.1"

rm -rf "$TMP"
```

完整输出见 [`assets/evidence/experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt)。

## 5. 踩坑点

### 坑 1：setuid 脚本无效

Linux 忽略脚本的 setuid 位（`#!` 解释器执行）。需要 setuid 时用二进制/C 程序，
或用 `sudo`/capability 替代。

### 坑 2：`nosuid` 挂载

`/tmp`、`/home`、NFS 常带 `nosuid`；即使文件有 setuid 位也不生效。`findmnt` 看 options。

### 坑 3：capability 在 exec 后丢失

file capability 默认只给 Permitted/Effective，Inheritable 需要显式设置；脚本/解释器
可能把 capability 丢掉。用 `getcap` + `capsh --print` 验证，不要只看 `setcap` 成功。

### 坑 4：`CAP_SYS_ADMIN` 等于“半个 root”

`CAP_SYS_ADMIN` 可以 mount、改 namespace、操作很多内核对象。给业务 Pod 加它，
基本等于放弃隔离。Cilium/CSI 需要它是例外，不是模板。

### 坑 5：`privileged: true` 会关闭大部分隔离

privileged 容器获得所有 capability、所有设备、关闭 seccomp/AppArmor 限制。
不要把“能跑”当成“可以 privileged”。

### 坑 6：`allowPrivilegeEscalation: true`

默认可能允许 setuid/file cap 提权。业务 Pod 应设 `false`，并 `drop: ["ALL"]`。

### 坑 7：`/etc/shadow` 000 导致审计失败

m01 的 `000` 更安全，但某些扫描器/备份工具以非 root 读取会失败。
安全加固要配套调整工具，而不是只看 mode 数字。

### 坑 8：ACL mask 让权限“看起来有但不生效”

`getfacl` 的 `mask` 会限制 named user/group 的最大权限；`#effective` 才是实际。
改 ACL 后要验证实际读/写，不要只看 `+`。

## 6. 一页命令

```bash
id; umask
ls -ld / /root /tmp /etc/shadow
ls -l /usr/bin/passwd /usr/bin/sudo /usr/bin/ping
find / -xdev \( -path /var/lib/docker -o -path /var/lib/containerd \) -prune -o \
  -perm -4000 -type f -print 2>/dev/null
getcap -r / 2>/dev/null | head
getfacl -p /tmp
capsh --print
grep -E 'Cap|NoNewPrivs|Seccomp' /proc/self/status
```
