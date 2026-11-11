# Linux 真机证据索引（2026-11-10）

这些目录保存从实际机器采集的**只读**命令输出，用于 05 章各篇教程的举证。
不是模拟数据；命令、主机名、版本、数字都来自当天环境。

## 1. 采集对象

| 目录 | 主机 | 地址 | 系统 | 角色 |
|---|---|---|---|---|
| `pve-host/` | teacher | 192.168.67.156 | Debian 12 / PVE 8.4.13 | Proxmox 宿主机 |
| `k8s-m01/` | m01 | 10.0.0.61 | Rocky Linux 9.6 | K8s control-plane |
| `k8s-master01/` | master01 | 10.0.0.121 | Ubuntu 22.04.5 | K8s control-plane |
| `k8s-master02/` | master02 | 10.0.0.120 | Ubuntu 22.04.5 | K8s control-plane |
| `k8s-worker01/` | worker01 | 10.0.0.122 | Ubuntu 22.04.5 | K8s worker |
| `k8s-worker02/` | worker02 | 10.0.0.123 | Ubuntu 22.04.5 | K8s worker |
| `k8s-worker03/` | worker03 | 10.0.0.124 | Ubuntu 22.04.5 | K8s worker |
| `gitlab-201/` | ubuntu01 | 192.168.67.201 | Ubuntu 24.04.4 | GitLab CE（Hyper-V VM） |
| `harbor-202/` | ubuntu02 | 192.168.67.202 | Ubuntu 24.04.4 | Harbor（Hyper-V VM） |

每个目录的 `collect.txt` 包含 11 个部分：

```text
0 元信息     1 内核       2 用户态/libc
3 文件系统   4 权限       5 进程
6 内存       7 systemd    8 内核参数与限制
9 K8s/容器   10 Ceph 客户端
```

## 2. 额外证据

| 文件 | 内容 |
|---|---|
| `experiments/linux-lab.txt` | 在 PVE 宿主机 `/tmp` 做的真实实验：umask/ACL/setuid/capability/硬链接/稀疏文件/页缓存/僵尸进程/systemd 限制 |
| `k8s-security/pod-security-summary.txt` | 138 个 Pod 的 hostNetwork/hostPID/privileged/capabilities/seccomp 统计 |
| `k8s-security/worker01-cgroup.txt` | worker01 的 kubepods cgroup v2 树、memory.max/current 样本 |

## 3. Ceph 的采集边界

Ceph mon 节点 `10.0.0.31/41/51` 的 root SSH 被拒绝（`Permission denied (publickey,...)`），
PVE `qm guest exec` 也被禁用（`Command guest-exec has been disabled`）。
因此：

- 主机层的 Ceph OSD/磁盘明细没有采到；
- 集群层证据从 **m01 的 Ceph 客户端**采集：`ceph -s`、`ceph df detail`、`ceph osd tree`、`ceph versions`；
- 见 `k8s-m01/collect.txt` 第 10 节。

## 4. 没有采集什么

- `/etc/shadow`、私钥、kubeconfig、Secret、token；
- 进程完整环境变量（`/proc/*/environ`）；
- 应用请求体/数据库内容。

## 5. 复现

```bash
# 在任意主机本地
bash docs/05-linux/scripts/collect_linux_evidence.sh > evidence.txt

# 远程
ssh root@10.0.0.61 'bash -s' < docs/05-linux/scripts/collect_linux_evidence.sh > m01.txt

# 权限/内存/systemd 实验（只在 /tmp，退出清理）
sudo bash docs/05-linux/scripts/linux_lab_experiments.sh
```

> 证据是“某个时刻”的快照。数字会变，结论要结合当时的负载、启动时间和配置看。
