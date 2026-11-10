# 07 · systemd 与启动流程：从 UEFI 到 target

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 7 节、
> [`k8s-m01`](assets/evidence/k8s-m01/collect.txt)、[`k8s-worker01`](assets/evidence/k8s-worker01/collect.txt)、
> [`gitlab-201`](assets/evidence/gitlab-201/collect.txt)、[`harbor-202`](assets/evidence/harbor-202/collect.txt)、
> [`experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt) 第 8 节。
>
> 这一章回答：**机器从按下电源到业务 Ready，中间发生了什么；为什么 PVE 启动要 3 分 55 秒；
> 为什么 `network-online.target` 会拖慢 13 秒；`systemd-run` 怎么临时限内存/CPU。**

## 1. 当时的情况

同一套集群，启动时间差异很大：

| 主机 | firmware | loader | kernel | userspace | 总时间 |
|---|---:|---:|---:|---:|---:|
| PVE 宿主 | **3min 4s** | 8.5s | 12.9s | 29.4s | **3min 55s** |
| m01 | 2.0s | - | 3.2s（initrd） | 7.7s | 12.9s |
| worker01 | - | - | 4.1s | 19.0s | 23.1s |
| GitLab 201 | 100ms | 232ms | 533ms | 6.7s | 7.6s |
| Harbor 202 | 32ms | 240ms | 577ms | 5.1s | 5.9s |

PVE 的 3 分钟 firmware 是**硬件/BIOS 初始化**，不是 Linux 慢；worker01 的 13.6 秒
`systemd-networkd-wait-online` 才是用户态瓶颈；Harbor 的 `apt-daily-upgrade` 39 秒是
启动后定时任务，不一定阻塞登录。

## 2. 主要概念

### 2.1 启动链路

```text
电源
  → UEFI/BIOS 初始化（firmware）
  → bootloader（GRUB/systemd-boot）
  → 加载 kernel + initramfs
  → kernel 初始化（驱动、挂载 root）
  → PID 1 systemd
  → sysinit.target → basic.target → multi-user/graphical.target
  → 业务服务
```

- **firmware**：主板/固件初始化，PVE 宿主可能因为阵列卡/网卡/内存训练很慢；
- **loader**：GRUB 菜单/加载内核；
- **kernel**：解压、初始化驱动、挂载 root；
- **initramfs**：临时根文件系统，加载存储/网络驱动；
- **systemd**：按 unit 依赖启动服务。

### 2.2 Unit 类型

| 类型 | 作用 | 例子 |
|---|---|---|
| `.service` | 服务 | `sshd.service` |
| `.socket` | socket 激活 | `sshd.socket` |
| `.timer` | 定时器 | `apt-daily.timer` |
| `.mount` | 挂载 | `etc-pve.mount` |
| `.target` | 目标/分组 | `multi-user.target` |
| `.slice` | cgroup 分组 | `system.slice` |
| `.path` | 文件/目录触发 | `cups.path` |

### 2.3 依赖与顺序

| 指令 | 含义 |
|---|---|
| `Requires=` | 强依赖，被依赖单元失败则本单元失败 |
| `Wants=` | 弱依赖，失败不影响本单元 |
| `After=` | 启动顺序：本单元在之后 |
| `Before=` | 启动顺序：本单元在之前 |
| `WantedBy=` | 被哪个 target 拉入 |
| `PartOf=` | 停止/重启联动 |

**`After` 不产生依赖**，只排序；`Wants` 不保证顺序。两者要配合。

### 2.4 target

```bash
systemctl get-default
systemctl list-dependencies multi-user.target | head
```

常见：

- `multi-user.target`：多用户命令行；
- `graphical.target`：图形界面（PVE/Ubuntu 默认）；
- `rescue.target` / `emergency.target`：救援。

### 2.5 journald

```bash
journalctl -b                 # 本次启动
journalctl -b -p err          # 本次启动 error 及以上
journalctl -u kubelet -n 100  # 某个服务
journalctl --disk-usage
```

日志持久化：

- `/var/log/journal/` 存在 → 持久；
- 不存在 → `/run/log/journal/`，重启丢；
- `Storage=volatile`/`persistent` 在 `/etc/systemd/journald.conf`。

## 3. 真机证据

### 3.1 PVE 宿主：firmware 是瓶颈

```text
$ systemd-analyze time
Startup finished in 3min 4.240s (firmware) + 8.500s (loader) + 12.866s (kernel) + 29.424s (userspace)
= 3min 55.031s
graphical.target reached after 29.397s in userspace.

$ systemd-analyze blame | head
16.853s pve-guests.service
16.398s pve-daily-update.service
 2.913s systemd-modules-load.service
 2.572s logrotate.service
 2.474s ifupdown2-pre.service
 2.473s systemd-udev-settle.service
```

critical-chain：

```text
graphical.target @29.397s
└─multi-user.target @29.397s
  └─pvescheduler.service @28.168s +1.228s
    └─pve-guests.service @11.299s +16.853s
      └─pve-ha-lrm.service @10.132s +1.154s
        └─pveproxy.service @8.066s +2.054s
          └─pvedaemon.service @6.535s +1.515s
            └─pve-cluster.service @5.476s +1.024s
              └─rrdcached.service @5.413s +60ms
                └─time-sync.target @5.409s
                  └─chrony.service @5.299s +89ms
                    └─network.target @5.278s
                      └─networking.service @3.378s +1.899s
```

- `pve-guests.service` 16.8s：启动/恢复 VM；
- `pve-daily-update.service` 16.4s：PVE 更新检查（可调整）；
- firmware 3 分钟：硬件层，systemd 管不了。

### 3.2 m01：dnf-makecache 拖慢

```text
Startup finished in 2.033s (kernel) + 3.243s (initrd) + 7.699s (userspace) = 12.976s
multi-user.target reached after 3.631s in userspace.

23.010s dnf-makecache.service
 4.206s kdump.service
```

`dnf-makecache` 23 秒是**启动后异步**的包缓存刷新，不一定阻塞 target；
但会占 I/O/CPU。

### 3.3 worker01：network-online 13.6 秒

```text
Startup finished in 4.085s (kernel) + 18.978s (userspace) = 23.063s
graphical.target reached after 18.354s in userspace

13.648s systemd-networkd-wait-online.service
 5.646s apt-daily-upgrade.service
 1.582s systemd-random-seed.service
 1.563s man-db.service
 1.354s cloud-init-local.service
 1.328s motd-news.service
 1.201s apt-daily.service
 1.164s containerd.service
```

`systemd-networkd-wait-online` 在等网络“online”，常见于双网卡/静态 IP/云环境。
如果业务不依赖网络 online，可以改用 `network.target` 或调整 `RequiredForOnline=`。

### 3.4 GitLab 201 / Harbor 202

```text
# GitLab
7.608s total, 6.539s userspace
2.029s systemd-networkd-wait-online.service
1.872s systemd-tmpfiles-setup.service
1.091s apt-daily-upgrade.service
 702ms cloud-init.service
 502ms docker.service

# Harbor
5.917s total, 4.888s userspace
39.491s apt-daily-upgrade.service（启动后定时任务）
1.842s docker.service
1.589s systemd-networkd-wait-online.service
```

Harbor 的 `apt-daily-upgrade` 39 秒出现在 blame 里，但 target 4.9 秒就到了；
说明它是异步任务，不是登录阻塞。

### 3.5 临时 unit 限资源

```text
$ systemd-run --unit=linux-lab-memlimit-2043899 \
  --property=MemoryMax=64M --property=CPUQuota=20% --property=TasksMax=16 /bin/sleep 30
Running as unit: linux-lab-memlimit-2043899.service

$ systemctl show ... -p MemoryMax -p CPUQuota -p TasksMax
MemoryMax=67108864
TasksMax=16

$ cat /sys/fs/cgroup/system.slice/.../memory.max
67108864
$ cat .../cpu.max
20000 100000
```

这比“临时改 `/etc/systemd/system`”更适合实验/排障。

## 4. 实验：分析启动与限制

```bash
# 启动时间
systemd-analyze time
systemd-analyze blame | head -20
systemd-analyze critical-chain | head -30

# 当前 target / 失败单元
systemctl get-default
systemctl --failed
systemctl list-units --state=running | head

# 日志
journalctl -b --no-pager | head -40
journalctl -b -p err --no-pager | tail -30
journalctl -u kubelet -n 50 --no-pager

# 临时 unit
systemd-run --unit=lab-sleep --property=MemoryMax=64M --property=CPUQuota=20% /bin/sleep 30
systemctl status lab-sleep --no-pager
systemctl stop lab-sleep
```

## 5. 踩坑点

### 坑 1：把 firmware 时间算到 Linux 头上

PVE 3 分钟 firmware 是硬件初始化；`systemd-analyze` 已经分开显示。
要优化只能看 BIOS/阵列卡/网卡启动项，不是改 systemd。

### 坑 2：`After=` 当成依赖

`After=network.target` 只排序，不保证网络可用；要 `Wants=network-online.target` +
`After=network-online.target`，并确认 wait-online 的判定。

### 坑 3：`network-online` 拖慢启动

双网卡/静态 IP/云环境常等不到“online”。检查：

```bash
systemctl status systemd-networkd-wait-online
networkctl status
```

按业务需要决定是否 `RequiredForOnline=no`。

### 坑 4：改了 unit 不 `daemon-reload`

```bash
systemctl daemon-reload
systemctl restart <service>
```

否则 systemd 还用旧配置。

### 坑 5：`Type=oneshot` 与 `RemainAfterExit`

oneshot 服务退出后默认 inactive；需要 `RemainAfterExit=yes` 才保持 active。
不要把长期进程写成 oneshot。

### 坑 6：启动失败没有日志

```bash
systemctl status <unit> -l --no-pager
journalctl -u <unit> -b --no-pager
systemctl cat <unit>
```

`status` 的 `-l` 显示完整日志，不要只看最后一行。

### 坑 7：`apt-daily`/`dnf-makecache` 占资源

这些 timer 在启动后异步跑，可能和业务高峰重叠。可以：

```bash
systemctl list-timers --all
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
```

或改 `RandomizedDelaySec`/`OnCalendar`。

### 坑 8：journal 占满 `/var/log/journal`

```bash
journalctl --disk-usage
journalctl --vacuum-size=500M
```

并在 `/etc/systemd/journald.conf` 设 `SystemMaxUse=`。

### 坑 9：cloud-init 与 network 顺序

cloud-init 依赖 network-online；网络慢会拖慢首启。K8s 节点首启可能几分钟，
不要误判为“VM 坏了”。

## 6. 一页命令

```bash
systemd-analyze time
systemd-analyze blame | head -20
systemd-analyze critical-chain | head -30
systemctl get-default
systemctl --failed
systemctl list-timers --all
journalctl -b -p err --no-pager | tail -30
journalctl -u kubelet -n 50 --no-pager
systemctl cat <unit>
systemctl show <unit> -p LimitNOFILE -p MemoryMax -p CPUQuota
```
