# 05 · 批量管理：开关机、扩容、discard、巡检与销毁

> 本章目标：把“逐台登录/逐台 qm”变成可编排的批量操作，并且**不把 K8s 弄挂**。
> 这是 IaC 里最容易出事的一章：Terraform 管“存在性”，Ansible 管“配置”，
> K8s 管“工作负载”，三者顺序错了就会造成中断。

## 1. 当时的情况

- 6 台 K8s 节点、3 台 Ceph、若干业务 VM 都在同一台 PVE 上；
- 早期批量脚本 `start-all-vm.sh` / `stopallvm.sh` 直接循环 `qm start/stop`；
- 没有 drain/uncordon，VM 一关，Pod 直接失联；
- worker01 曾因磁盘 85% 触发 `DiskPressure`，CSI nodeplugin 被驱逐；
- thin pool 到 65% 后，VM 内删文件不回收，`data%` 不降；
- 没有统一的“哪些 VM 属于哪套环境”的清单。

## 2. 主要概念

### 2.1 三层工具的边界

| 层 | 工具 | 负责 | 不负责 |
|---|---|---|---|
| 虚拟化 | Terraform / `qm` | VM 存在、CPU/内存/磁盘/网络 | guest 内配置 |
| 配置 | cloud-init / Ansible | 用户、包、sysctl、containerd、kubelet | VM 创建/删除 |
| 集群 | kubectl / ArgoCD | Node、Pod、PV、应用 | 宿主机/VM |

**顺序**：

```text
创建：Terraform → cloud-init → Ansible → kubeadm join → ArgoCD
维护：cordon/drain → 宿主操作 → uncordon → 验证
销毁：kubectl drain/delete node → Terraform destroy → fstrim
```

### 2.2 安全批量操作的三条规则

1. **先 K8s 后 VM**：先 `cordon/drain`，再关机；
2. **串行/小批量**：`serial: 1` 或一次一台，不要 `for` 循环全关；
3. **每步验证**：节点 Ready、Cilium Pod Running、CNPG healthy、PVC Bound。

### 2.3 `qm` 与 Terraform 的分工

- 临时操作（开关机、扩容、discard）用 `qm`；
- **持久变更**（CPU/内存/磁盘大小/网络）应改 Terraform 代码再 apply；
- 只用 `qm` 改、不改代码，下次 `terraform apply` 可能被改回去（漂移）。

## 3. 操作步骤

### 3.1 批量巡检

```bash
# PVE 侧
qm list
pvesm status
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py

# K8s 侧
kubectl get nodes -o wide
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get pvc -A | grep -v Bound

# Ansible 侧
ansible -i inventory-k8s.ini all -m command -a 'uptime; df -h /; swapon --show'
```

### 3.2 安全重启一台 K8s 节点 VM

```bash
NODE=worker03
VMID=124

kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=600s

qm shutdown "$VMID" --timeout 120
# 等 qm status 变为 stopped
qm start "$VMID"
# 等 node Ready
kubectl wait --for=condition=Ready "node/$NODE" --timeout=600s
kubectl uncordon "$NODE"

kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium -o wide | grep "$NODE"
```

有 CNPG 主库的节点，先做 switchover：

```bash
kubectl -n cnpg-system get cluster pg16-ceph -o jsonpath='{.status.currentPrimary}'
kubectl -n cnpg-system delete pod <primary-pod>
# 等 primary 切换、2/2 ready
```

### 3.3 批量开关机（非 K8s 节点）

```bash
# 按 VMID 列表串行
for id in 125 126 127; do
  qm shutdown "$id" --timeout 120
  while [ "$(qm status "$id" | awk '{print $2}')" != "stopped" ]; do sleep 2; done
done
```

K8s 节点不要用这种无 drain 的循环；用 3.2 的滚动方式。

### 3.4 扩容 CPU/内存

```bash
# 在线改内存（guest 支持热插拔时）
qm set 122 --memory 12288
qm config 122 | grep memory

# CPU 型号/核数通常需要 stop/start
qm shutdown 122 --timeout 120
qm set 122 --cores 8 --cpu x86-64-v3
qm start 122
```

改完回到 Terraform 代码同步，否则下次 apply 会改回。

### 3.5 扩容磁盘

PVE 侧：

```bash
qm resize 122 scsi0 +20G
qm config 122 | grep scsi0
```

guest 侧（LVM）：

```bash
growpart /dev/sda 2
pvresize /dev/sda2
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h /
```

> 先确认分区布局，不要照抄 `/dev/sda2`。Rocky/Ubuntu 的 VG 名不同。

### 3.6 discard / fstrim

```bash
# 每台 VM 的磁盘加 discard
qm set 122 --scsi0 local-lvm:vm-122-disk-0,discard=on,ssd=1,iothread=1,size=60G

# guest 内
fstrim -av
```

批量脚本（会 drain/重启）：

```bash
bash docs/12-proxmox-pve/scripts/apply_discard.sh 122 worker01 10.0.0.122
```

验证：

```bash
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
pvesm status
```

### 3.7 批量 Ansible

```bash
# 只跑一个组
ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s_worker

# 串行，一台失败停
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s_worker --serial 1

# 只检查
ansible-playbook -i inventory-k8s.ini baseline.yml --check --diff
```

### 3.8 销毁

```bash
# 先从 K8s 摘除
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>

# 再销毁 VM
terraform destroy -target='proxmox_virtual_environment_vm.node["k8s-lab-w01"]'

# 最后回收 thin pool
fstrim -av
```

## 4. 踩坑点

### 坑 1：先关 VM 再 drain

Pod 直接失联，CNPG 可能触发非预期 failover，Cilium 节点状态异常。
顺序必须是 `cordon → drain → 关机`。

### 坑 2：一次关多台控制面

etcd 失去 quorum，API Server 不可用。控制面必须**逐台**，并确认 etcd 3/3 healthy。

### 坑 3：m01 是 kubeconfig 默认入口

本机 kubeconfig 指向 `10.0.0.61:6443`。关 m01 前准备 VIP kubeconfig：

```bash
cp ~/.kube/config /tmp/kubeconfig-vip
kubectl --kubeconfig /tmp/kubeconfig-vip config set-cluster kubernetes \
  --server=https://10.0.0.168:6443
```

### 坑 4：`qm set --memory` 不等于 guest 看到

有些 OS 需要内存热插拔支持；不生效就 stop/start。改 CPU 型号必须 stop/start。

### 坑 5：`qm resize` 后 guest 没扩

只扩了块设备，分区/文件系统没扩。必须 `growpart + pvresize + lvextend + resize2fs/xfs_growfs`。

### 坑 6：discard 增加 I/O

`fstrim` 在低负载时执行；不要和备份/CI 构建高峰重叠。

### 坑 7：thin pool 满导致所有 VM 卡死

`queue_if_no_space` 会让 I/O 挂起，不是立刻报错。保持 `data% < 70%`，
并监控 VG 空闲（本机只有 16GiB，autoextend 会失败）。

### 坑 8：Terraform 与 qm 漂移

手工 `qm set` 改了 CPU/内存，Terraform state 还是旧值；下次 apply 可能改回。
临时操作后要么改代码，要么记录“已知漂移”。

### 坑 9：`terraform destroy` 误删生产

`terraform destroy` 会删 state 里所有资源，包括数据盘。执行前：

```bash
terraform state list
terraform plan -destroy
```

并确认 state 没有混入生产 VM。

## 5. 一页命令

```bash
# 巡检
qm list
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py
kubectl get nodes -o wide

# 安全重启 K8s 节点
kubectl cordon worker03
kubectl drain worker03 --ignore-daemonsets --delete-emptydir-data
qm shutdown 124 --timeout 120 && qm start 124
kubectl wait --for=condition=Ready node/worker03 --timeout=600s
kubectl uncordon worker03

# 扩容 + discard
qm resize 122 scsi0 +20G
qm set 122 --scsi0 local-lvm:vm-122-disk-0,discard=on,ssd=1,iothread=1,size=80G
ssh root@10.0.0.122 'growpart /dev/sda 2; pvresize /dev/sda2; fstrim -av'

# Terraform 销毁
terraform state list
terraform plan -destroy
terraform destroy -target='proxmox_virtual_environment_vm.node["k8s-lab-w01"]'
```
