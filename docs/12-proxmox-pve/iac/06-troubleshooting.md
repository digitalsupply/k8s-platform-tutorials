# 06 · 故障排查：Terraform / cloud-init / Ansible / K8s join

> 这一章按“现象 → 根因 → 修复 → 验证”组织，都是本环境真实遇到或高概率遇到的坑。

## 1. Terraform

| 现象 | 根因 | 修复 | 验证 |
|---|---|---|---|
| `401 no ticket` | token 格式错 | `user@realm!tokenid=secret` | `curl -k -H "Authorization: PVEAPIToken=..." https://127.0.0.1:8006/api2/json/version` |
| `403 permission denied` | token 权限不足 | 补 `VM.*`/`Datastore.*`/`Sys.*` | 用同一 token 调 `/nodes/teacher/qemu` |
| `provider ... not cached` | 无法下载 provider | 文件系统镜像/代理 | `terraform init` 显示 `Installed ...` |
| `VM 130 already exists` | VMID 冲突 | 换 VMID 或 `terraform import` | `qm list` |
| `clone failed: storage not found` | 模板/存储名错 | 检查 `template_vmid`/`local-lvm` | `qm config 9010` |
| `timeout waiting for agent` | guest 没装 qemu-guest-agent | 模板注入 agent，或 `agent.enabled=false` | `qm guest cmd <vmid> ping` |
| `apply` 后 CPU 没变 | CPU 不热插拔 | stop/start | guest 内 `lscpu` |
| state 锁/冲突 | 本地 state 多人用 | 远程 backend + 锁 | `terraform plan` |

## 2. cloud-init / 模板

| 现象 | 根因 | 修复 |
|---|---|---|
| guest 没有 IP | cloud-init 盘挂 IDE / 未识别 | 改 `scsi1`，`qm cloudinit dump` 检查 |
| `cloud-init status: error` | 包安装失败/命令不存在 | 看 `/var/log/cloud-init-output.log` |
| 主机名变成 `xxx.local` | 模板 `searchdomain: local` | 删除 searchdomain，或显式 hostname |
| SSH key 不生效 | key 没注入 / `ssh_pwauth` | 控制台登录，检查 `~/.ssh/authorized_keys` |
| 克隆后 machine-id 相同 | 模板 sysprep 不完整 | 清空 `/etc/machine-id` + SSH host key |
| `Unknown network config version: None` | 写了 `network: {config: enabled}` | 删除该配置 |
| `virt-customize` 连不上仓库 | libguestfs 网关写错 | 用 `169.254.2.2`，不是 `10.0.2.2` |
| 模板改不了 | 基盘只读 | `lvchange -prw`，完成后 `-pr` |

## 3. Ansible

| 现象 | 根因 | 修复 |
|---|---|---|
| `UNREACHABLE` | SSH/key/网络 | `ssh -vvv root@ip`；检查 inventory |
| `Missing sudo password` | 没有 NOPASSWD | 配 sudoers，或 `-K` |
| `python not found` | 最小化镜像 | 装 python3，设 `ansible_python_interpreter` |
| `community.general` 找不到 | collection 未装 | `ansible-galaxy collection install community.general` |
| `--check` 报 command 不支持 | 模块不支持 check | 用只读命令 + `changed_when: false` |
| 混合 OS 包名错 | 硬编码 Ubuntu | 用 `ansible_os_family` 分支 |
| SSH 加固后失联 | key 没验证就关密码 | PVE 控制台恢复，先验证 key |
| `/etc/hosts` 被覆盖 | cloud-init `manage_etc_hosts` | 设 false，或用独立 marker block |

## 4. K8s 节点

| 现象 | 根因 | 修复 |
|---|---|---|
| `NotReady` | containerd/kubelet/CNI 异常 | `systemctl status containerd kubelet`；`crictl ps` |
| `SystemdCgroup` 不匹配 | containerd 用 cgroupfs | 改 `SystemdCgroup=true`，重启 containerd |
| pause 拉取失败 | sandbox_image 不可达 | 配 mirror/固定 pause 镜像 |
| join 失败 `token expired` | token 24h 过期 | 重新 `kubeadm token create --print-join-command` |
| join 失败 `ca cert hash` | hash 不匹配 | 从当前集群重新生成 |
| Node 名冲突 | 克隆 VM hostname 相同 | cloud-init/Ansible 设唯一 hostname |
| CNPG webhook 超时 | `rp_filter=1` | 统一 loose(2)，重启 CNPG |
| Ceph-CSI CrashLoop `SIGILL` | CPU 不是 x86-64-v3 | PVE 改 CPU + stop/start |
| `DiskPressure` | 根盘/镜像占满 | `crictl rmi --prune`，重启 kubelet |
| Cilium Pod Pending | 新节点污点/资源/镜像 | `describe pod`、`logs`、检查 tolerations |

## 5. 排障顺序（不要跳）

```text
1. PVE 层：qm status / qm config / pvesm status / lvs
2. guest 启动：cloud-init status / cloud-init-output.log
3. 网络：ip a / ip r / ping gateway / DNS
4. SSH/Ansible：ssh -vvv / ansible -m ping
5. 运行时：systemctl status containerd kubelet / crictl info
6. K8s：kubectl get nodes / describe node / cilium pod logs
7. 应用：kubectl get pods -A / events / CNPG status
```

## 6. 快速收集证据

```bash
# PVE
qm status <vmid>; qm config <vmid>; qm cloudinit dump <vmid> user
pvesm status; lvs -o +data_percent,metadata_percent

# guest（通过 SSH 或 qm terminal）
cloud-init status --long
cat /var/log/cloud-init-output.log
ip -br a; ip r
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter
systemctl status containerd kubelet --no-pager
crictl info
journalctl -u kubelet -n 100 --no-pager

# K8s
kubectl get nodes -o wide
kubectl describe node <node>
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

> 先定位“哪一层”，再谈修复。把 PVE 层的磁盘/网络问题误判成 K8s 问题，
> 是本环境最常见的排障弯路。
