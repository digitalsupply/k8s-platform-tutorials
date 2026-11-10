# 02 · 用户态：init、libc、ELF、登录 shell 与环境

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt)
> 第 2 节、[`k8s-m01/collect.txt`](assets/evidence/k8s-m01/collect.txt) 第 2 节。
>
> 这一章回答：**一个命令从输入到执行，中间经过谁；为什么同一份二进制在另一台机器上跑不起来；
> 为什么 `ssh host cmd` 和登录后的 shell 环境不一样。**

## 1. 当时的情况

同一套脚本在 9 台机器上执行，遇到：

- Ubuntu 22.04 的 glibc 2.35、Rocky 9.6 的 2.34、Ubuntu 24.04 的 2.39；
- 有的机器 `python3` 在 `/usr/bin`，有的最小镜像没有；
- `ssh host 'echo $PATH'` 和登录后 `echo $PATH` 不一样；
- `sudo` 后 `HOME`/`PATH` 变了，脚本找不到命令；
- 一个在 24.04 编译的二进制，在 22.04 上报 `GLIBC_2.38 not found`；
- Ceph-CSI 镜像在旧 CPU 上 `SIGILL`，不是 glibc 问题，而是 **CPU 基线**问题。

## 2. 主要概念

### 2.1 用户态与内核态的边界

```text
shell / python / nginx / kubelet
  │  普通指令（ring 3）
  │  syscall（open/read/write/fork/execve/mmap/...）
  ▼
内核（ring 0）
  │  文件系统、网络、内存、调度、设备
  ▼
硬件
```

用户态不能直接访问磁盘/网卡/页表；必须通过 syscall。`strace` 就是观察这条边界。

### 2.2 ELF 与动态链接

Linux 可执行文件通常是 ELF：

```text
ELF header
  ├─ program headers（如何加载到内存）
  ├─ .text / .data / .bss
  ├─ .dynamic（依赖哪些库）
  └─ .interp（动态链接器路径）
```

```bash
file /bin/ls
readelf -h /bin/ls | head
readelf -d /bin/ls | grep NEEDED
ldd /bin/ls
```

- **静态链接**：把 libc 打进二进制，体积大、可移植；
- **动态链接**：运行时由 `/lib64/ld-linux-x86-64.so.2` 加载 `libc.so.6` 等；
- 动态链接的二进制依赖 **glibc 版本** 和 **CPU 基线**。

### 2.3 init 与 systemd

所有进程的祖先是 PID 1：

```bash
readlink -f /sbin/init
cat /proc/1/comm
cat /proc/1/cgroup
```

本环境全部是 systemd：

| 主机 | systemd | glibc |
|---|---|---|
| PVE 宿主 | 252 | 2.36 |
| m01 | 252 | 2.34 |
| worker01 | 249 | 2.35 |
| GitLab 201 | 255 | 2.39 |
| Harbor 202 | 255 | 2.39 |

systemd 负责启动服务、挂载、socket、timer、cgroup，详见第 07 章。

### 2.4 登录 shell vs 非登录 shell

| 场景 | 读取的启动文件（bash） | 典型 |
|---|---|---|
| 登录 shell | `/etc/profile`、`~/.bash_profile`/`~/.profile` | `ssh host`、`su -` |
| 交互非登录 | `~/.bashrc` | 打开终端 |
| 非交互 | 通常不读启动文件 | `ssh host 'cmd'`、脚本 |

所以：

```bash
ssh host 'echo $PATH'      # 非交互，可能没有 /usr/local/bin
ssh host 'bash -lc "echo $PATH"'  # 登录 shell
```

### 2.5 用户、组与 PAM

```bash
id
getent passwd | head
getent group | head
```

- UID 0 = root；
- 系统服务用户（`www-data`、`git`、`systemd-resolve`）通常 `nologin`；
- 登录认证由 PAM 完成（`/etc/pam.d/`），`su`/`sudo`/`sshd` 都走 PAM；
- `/etc/shadow` 存密码哈希，普通用户不可读。

## 3. 真机证据

### 3.1 PID 1 与 systemd

```text
$ readlink -f /sbin/init; cat /proc/1/comm; cat /proc/1/cgroup
/usr/lib/systemd/systemd
systemd
0::/init.scope
```

所有主机一致：systemd 作为 PID 1，cgroup v2 的 `/init.scope`。

### 3.2 glibc / 动态链接

```text
# PVE 宿主
$ ldd --version | head -2
ldd (Debian GLIBC 2.36-9+deb12u13) 2.36

# m01
$ ldd --version | head -2
ldd (GNU libc) 2.34

# worker01
$ ldd --version | head -2
ldd (Ubuntu GLIBC 2.35-0ubuntu3.15) 2.35

# GitLab/Harbor
$ ldd --version | head -2
ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39
```

查看一个二进制的依赖：

```bash
$ file /bin/ls
/bin/ls: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2, ...

$ ldd /bin/ls
linux-vdso.so.1
libselinux.so.1 => /lib/x86_64-linux-gnu/libselinux.so.1
libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
/lib64/ld-linux-x86-64.so.2
```

### 3.3 用户与组

```text
$ getent passwd | head
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
...
```

注意：

- `x` 只是占位，真实哈希在 `/etc/shadow`；
- `nologin` 表示不能交互登录；
- 服务用户（`git`、`www-data`、`lxd`）的 UID 不是 0，但可能有文件/端口权限。

### 3.4 环境变量

```bash
$ env | grep -E '^(PATH|LANG|SHELL|HOME|USER)=' | sort
HOME=/root
LANG=C.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash
USER=root
```

`ssh host 'cmd'` 的环境通常比登录 shell 少；脚本要显式设置 `PATH`，不要依赖交互式配置。

## 4. 实验：从 syscall 到动态链接

```bash
# 1. 看 ELF 头和依赖
file /bin/ls
readelf -h /bin/ls | head -15
readelf -d /bin/ls | grep NEEDED
ldd /bin/ls

# 2. 看 syscall（需要 strace）
strace -f -e trace=openat,read,write /bin/ls /tmp 2>&1 | head -30

# 3. 看登录/非登录 shell 差异
ssh root@10.0.0.61 'echo PATH=$PATH'
ssh root@10.0.0.61 'bash -lc "echo PATH=$PATH"'

# 4. 看进程的 libc/解释器
cat /proc/1/maps | grep -E 'libc|ld-linux' | head
```

> `strace` 可能未安装；没有就以 `readelf`/`ldd` 为主，不要为了实验装一堆包。

## 5. 踩坑点

### 坑 1：`GLIBC_2.xx not found`

在 Ubuntu 24.04（glibc 2.39）编译的二进制，拿到 22.04（2.35）运行：

```text
./app: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

解决：

- 在目标发行版/容器里编译；
- 用静态链接（Go/Rust 常用）；
- 用多阶段构建 + 兼容的基础镜像；
- 不要用“复制 libc”这种危险做法。

### 坑 2：CPU 基线不是 glibc

Ceph-CSI 3.18 标准镜像要求 `x86-64-v3`。旧 CPU（v2）上容器启动即 `SIGILL`，
不是 `GLIBC not found`。检查：

```bash
grep -m1 '^flags' /proc/cpuinfo | grep -o avx2
qm config <vmid> | grep '^cpu:'
```

### 坑 3：`ssh host 'cmd'` 找不到命令

非交互 shell 不读 `.bashrc`/`.profile`，`PATH` 可能不含 `/usr/local/bin`。
脚本里写绝对路径，或：

```bash
ssh host 'bash -lc "command"'
```

### 坑 4：`sudo` 改变环境

`sudo` 默认重置 `PATH`/`HOME`，`sudo -E` 才保留环境（受 `sudoers` 限制）。
脚本里不要依赖 `sudo` 继承当前 `PATH`。

### 坑 5：locale 影响排序/大小写

`LANG=C` 与 `LANG=zh_CN.UTF-8` 下 `sort`、`grep -i`、文件名大小写行为可能不同。
自动化脚本建议显式 `LC_ALL=C`。

### 坑 6：把 32 位/ARM 二进制拷到 x86_64

`file` 看架构；`exec format error` 多半是架构不匹配，不是权限。

### 坑 7：systemd 服务找不到用户环境

systemd 不读 `~/.bashrc`；服务要写 `Environment=`/`EnvironmentFile=`，并注意 `PATH`。

## 6. 一页命令

```bash
id
getent passwd | head
readlink -f /sbin/init
cat /proc/1/comm
ldd --version | head -2
file /bin/ls
readelf -h /bin/ls | head
ldd /bin/ls
env | sort | head
ssh root@host 'echo $PATH'
ssh root@host 'bash -lc "echo $PATH"'
```
