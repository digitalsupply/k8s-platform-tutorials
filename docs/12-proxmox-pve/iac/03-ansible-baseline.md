# 03 · Ansible 批量基线：把“登录每台机器改一遍”变成 playbook

> 本章目标：用 Ansible 管理现有 6 台 K8s 节点和新克隆的 VM。
> 代码在 [`../assets/iac/ansible/`](../assets/iac/ansible/) 与
> [`../assets/xceuler/ansible/`](../assets/xceuler/ansible/)。
>
> 幂等性、handlers、`--check --diff`、`delegate_to`、动态 inventory、roles 复用、
> 以及“大规模为什么转不可变镜像”的真机输出，见
> [`../../11-gitops-platform/10-iac-evolution.md`](../../11-gitops-platform/10-iac-evolution.md) 第 1 节，
> 证据在 [`../assets/iac/evidence/`](../assets/iac/evidence/)。

## 1. 当时的情况

现有集群是**混合 OS**：

| 节点 | OS | 角色 |
|---|---|---|
| m01 | Rocky Linux 9.6 | control-plane |
| master01 / master02 | Ubuntu 22.04.5 | control-plane |
| worker01 / worker02 / worker03 | Ubuntu 22.04.5 | worker |

手工配置的问题：

- m01 用 `dnf`，其他节点用 `apt`，命令不能照抄；
- 主机名/`/etc/hosts` 每台都要改，漏一台就出现解析问题；
- SSH 加固、sudo、时区、chrony 各台不一致；
- 新克隆的 VM 主机名是 `localhost` 或 FQDN，需要统一；
- 没有 inventory，无法“对全部节点执行同一件事”。

m01 上已有现成 inventory：

```ini
[k8s_all:children]
k8s_cp
k8s_worker

[k8s_cp]
m01        ansible_host=10.0.0.61
master01   ansible_host=10.0.0.121
master02   ansible_host=10.0.0.120

[k8s_worker]
worker01   ansible_host=10.0.0.122
worker02   ansible_host=10.0.0.123
worker03   ansible_host=10.0.0.124
```

## 2. 主要概念

### 2.1 Inventory / Group / Host vars

- **Inventory**：主机清单；
- **Group**：`k8s_cp` / `k8s_worker` / `k8s_all`，Play 可以只对某个组执行；
- **Host vars**：单台差异（IP、角色）；
- **Group vars**：组内共享（版本、网段、镜像仓库）。

### 2.2 幂等与 `--check`

Ansible 的模块应该“执行一次”和“执行 N 次”结果一样。第一次上生产前必须：

```bash
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff --limit worker03
```

`--check` 只报告会改什么，不落地；`--diff` 显示文件差异。

### 2.3 become 与 SSH

- `become: true` → `sudo` 到 root；
- `become_ask_pass: false` → 依赖 NOPASSWD sudo；
- 连接优先用 SSH key，不建议在 inventory 写密码；
- `ansible_ssh_common_args` 可关闭 host key 检查（实验环境），生产不要关。

### 2.4 事实（facts）

`gather_facts: true` 会采集 `ansible_os_family`、`ansible_swaptotal_mb` 等。
混合 OS 的 playbook 用：

```yaml
when: ansible_os_family == "Debian"
when: ansible_os_family == "RedHat"
```

而不是 `when: ansible_distribution == "Ubuntu"`。

## 3. 操作步骤

### 3.1 准备控制机

在 m01（或任意能 SSH 到所有节点的机器）：

```bash
ansible --version
ssh -o BatchMode=yes root@10.0.0.122 true
```

如果 Ansible 没装：

```bash
# Rocky
sudo dnf install -y ansible
# Ubuntu
sudo apt update && sudo apt install -y ansible
```

### 3.2 使用 inventory

```bash
cd docs/12-proxmox-pve/assets/iac/ansible
ansible-inventory -i inventory-k8s.ini --graph
ansible -i inventory-k8s.ini all -m ping
```

预期：

```text
m01 | SUCCESS => {"changed": false, "ping": "pong"}
...
```

如果 `ping` 失败，先解决 SSH，不要急着跑 playbook。

### 3.3 先跑 check

```bash
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff
```

重点看：

- 会不会改 `/etc/hosts`；
- 会不会改 `/etc/fstab`（swap）；
- 会不会重启 sshd；
- 包安装是否命中正确的包管理器。

### 3.4 灰度执行

```bash
# 先一台
ansible-playbook -i inventory-k8s.ini baseline.yml --limit worker03

# 再全量
ansible-playbook -i inventory-k8s.ini baseline.yml
```

### 3.5 验证

```bash
ansible -i inventory-k8s.ini all -m command -a 'hostname; timedatectl show -p Timezone --value'
ansible -i inventory-k8s.ini all -m command -a 'swapon --show'
ansible -i inventory-k8s.ini all -m command -a 'systemctl is-active qemu-guest-agent'
kubectl get nodes -o wide
```

### 3.6 只对新增 VM 执行

```bash
# inventory 里加：
# [k8s_lab]
# k8s-lab-w01 ansible_host=10.0.0.130

ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s_lab
```

## 4. 踩坑点

### 坑 1：`ansible -m ping` 成功但 playbook 失败

`ping` 只用 Python，playbook 可能卡在 `become`、包管理器、SELinux。
看完整错误：

```bash
ansible-playbook ... -vvv --limit worker03
```

### 坑 2：Python 解释器路径不对

Ubuntu 22.04 是 `/usr/bin/python3`；某些最小化镜像没有 Python。
在 inventory 设置：

```ini
ansible_python_interpreter=/usr/bin/python3
```

并确保 guest 装了 `python3`。

### 坑 3：模块依赖没装

如果 playbook 用了 `community.general`、`ansible.posix` 等 collection，要先安装：

```bash
ansible-galaxy collection install community.general ansible.posix
```

本仓库的 `baseline.yml` 只用 `ansible.builtin` + `timedatectl`，不依赖额外 collection；
如果你改成 `community.general.timezone`，记得补装。

### 坑 4：`authorized_key exclusive: true` 把自己锁死

`exclusive` 会删除其他 key。第一次加固时不要用，或先确认新 key 可用。

### 坑 5：SSH 加固后连不上

`PasswordAuthentication no` + key 没注入 = 锁死。
顺序必须是：

1. 确认 key 登录成功；
2. 再设 `ssh_key_only: true`；
3. 保留一个已登录会话，另开窗口验证；
4. 出问题用 PVE 控制台恢复。

### 坑 6：混合 OS 的包名不同

| 用途 | Debian/Ubuntu | Rocky |
|---|---|---|
| SSH 服务 | `ssh` | `sshd` |
| 时间同步 | `chrony` | `chronyd` |
| 容器运行时 | `containerd` | `containerd.io` |

用 `ansible_os_family` 分支，不要硬编码一个发行版。

### 坑 7：`/etc/hosts` 被 cloud-init 覆盖

cloud-init 默认 `manage_etc_hosts: true` 会重写 `/etc/hosts`。
在 user-data 里设 `manage_etc_hosts: false`，或用 Ansible 的 `blockinfile` 加独立标记块。

### 坑 8：`--check` 也会执行 command/shell

`command`/`shell` 模块在 check 模式下默认**不执行**，但有些模块不支持 check。
不要把“验证”写成会改系统的 shell；用 `changed_when: false` + 只读命令。

## 5. 一页命令

```bash
cd docs/12-proxmox-pve/assets/iac/ansible

ansible-inventory -i inventory-k8s.ini --graph
ansible -i inventory-k8s.ini all -m ping

ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff --limit worker03
ansible-playbook -i inventory-k8s.ini baseline.yml --limit worker03
ansible-playbook -i inventory-k8s.ini baseline.yml

ansible -i inventory-k8s.ini all -m command -a 'hostname; swapon --show'
kubectl get nodes -o wide
```
