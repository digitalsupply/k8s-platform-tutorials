# IaC 实验手册

> 目标：用一台**临时 VM**（VMID 130 / IP 10.0.0.130）把 Terraform → cloud-init → Ansible → K8s 前置
> 跑一遍。不要直接拿 119–124 的现有节点做实验。

## 实验 0：前置检查

```bash
# PVE 侧
pveversion
qm list | grep -E '130|131|132' || echo "VMID 130-132 空闲"
pvesm status
lvs -o lv_name,lv_size,data_percent pve/data

# Terraform
terraform version
ls /root/.terraform.d/plugins/registry.terraform.io/bpg/proxmox/

# Ansible
ansible-playbook --version
ssh -o BatchMode=yes root@10.0.0.61 true
```

如果 VMID 130–132 已被占用，换一组空闲 VMID/IP，并同步修改 `vms` map。

## 实验 1：Terraform plan/apply

```bash
cd docs/12-proxmox-pve/assets/xceuler/terraform
cp terraform.tfvars.k8s.example terraform.tfvars
# 只保留一台，减少资源占用：
# vms = { k8s-lab-w01 = { vmid = 130, ip = "10.0.0.130" } }

terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

验收：

```bash
qm list | grep 130
qm config 130 | grep -E 'cpu:|memory:|net0:|ipconfig0:|scsi1:'
ping -c1 10.0.0.130
```

## 实验 2：cloud-init 调试

```bash
qm cloudinit dump 130 user
qm cloudinit dump 130 network
ssh hao@10.0.0.130 'cloud-init status --long; hostname; hostname -f; ip -br a'
ssh hao@10.0.0.130 'sudo systemctl is-active qemu-guest-agent'
```

故意破坏一次（可选）：

```bash
qm set 130 --cicustom "user=local:snippets/does-not-exist.yaml"
qm start 130
# 观察 cloud-init 报错，再用正确 snippet 恢复
```

验收：

- `cloud-init status` 为 `done`；
- 主机名是短名 `k8s-lab-w01`，不是 `k8s-lab-w01.local`；
- `eth0` 是 `10.0.0.130/24`；
- `hao` 可以免密 sudo。

## 实验 3：Ansible 基线

在 `inventory-k8s.ini` 增加：

```ini
[k8s_lab]
k8s-lab-w01 ansible_host=10.0.0.130
```

执行：

```bash
cd ../iac/ansible    # 或 docs/12-proxmox-pve/assets/iac/ansible
ansible-inventory -i inventory-k8s.ini --graph
ansible -i inventory-k8s.ini k8s_lab -m ping

ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s_lab --check --diff
ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s_lab
```

验收：

```bash
ansible -i inventory-k8s.ini k8s_lab -m command -a 'hostname; timedatectl show -p Timezone --value; swapon --show'
ansible -i inventory-k8s.ini k8s_lab -m command -a 'systemctl is-active qemu-guest-agent'
```

## 实验 4：K8s 前置（不 join）

```bash
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s_lab --check --diff
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s_lab
```

验收：

```bash
ansible -i inventory-k8s.ini k8s_lab -m command -a 'sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter'
ansible -i inventory-k8s.ini k8s_lab -m command -a 'containerd --version; grep -E "SystemdCgroup|sandbox_image" /etc/containerd/config.toml'
ansible -i inventory-k8s.ini k8s_lab -m command -a 'kubelet --version; kubeadm version -o short'
```

**不要**在实验里直接 join 生产集群。要练 join，先单独起一个 kubeadm 实验集群，
或在维护窗口用可回滚的 worker 节点，并准备好：

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
ssh root@<node> 'kubeadm reset -f; rm -rf /etc/cni/net.d/*'
```

## 实验 5：清理

```bash
# 如果只是实验，不 join，直接销毁
cd ../../xceuler/terraform
terraform state list
terraform destroy -target='proxmox_virtual_environment_vm.node["k8s-lab-w01"]'

# PVE 侧确认
qm list | grep 130 || echo "destroyed"
fstrim -av
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py
```

## 常见失败点

| 现象 | 先看 |
|---|---|
| `terraform init` 卡住 | `.terraformrc` 镜像路径、provider 版本 |
| VM 启动但没有 IP | `qm cloudinit dump 130 network`、`scsi1` |
| SSH 不通 | `qm terminal 130`、cloud-init 日志、key |
| Ansible ping 不通 | `ssh -vvv`、inventory 的 `ansible_host` |
| containerd 起不来 | `journalctl -u containerd`、config.toml 语法 |
| kubelet 起不来 | `journalctl -u kubelet`、swap、containerd socket |

> 实验结束后一定销毁临时 VM。thin pool 只有 794GiB，且 VG 只剩 16GiB，
> 不要留下“实验残留”占着磁盘。
