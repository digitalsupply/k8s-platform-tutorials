# /root 工作区 md / 脚本盘点（2026-11-10）

> 目的：在删除 10 天前的 md 与相关脚本之前，先把 `/root` 下所有 md / 脚本的去向盘点清楚，
> 确保没有“没统计到”的文件。删除不备份；所有需要保留的内容已进入本教程仓库。
>
> 扫描范围：`/root` 下 `*.md`、`*.sh`、`*.py`、`*.bash`。  
> 排除：上游 vendored 仓库、系统/工具隐藏目录（见文末）。  
> 删除阈值：mtime 早于 **2026-10-31**（10 天前）。

## 1. 已纳入教程、原文件已删除（10 天前）

| 原文件 | 教程位置 | 说明 |
|---|---|---|
| `vm-110-115-archive.md` | [12/notes/vm-110-115-archive.md](../../12-proxmox-pve/notes/vm-110-115-archive.md) | 弱口令已脱敏 |
| `xceuler/README.md` | [12/notes/xceuler-repo-readme.md](../../12-proxmox-pve/notes/xceuler-repo-readme.md) | 原样保留 |
| `xceuler/部署过程.md` | [12/notes/openeuler-batch-deploy-2026-11.md](../../12-proxmox-pve/notes/openeuler-batch-deploy-2026-11.md) | 原样保留 |
| `openwebuicicd/OPENWEBUI-CICD-GITOPS.md` | [10/notes/openwebui-cicd-gitops.md](../../10-cicd-delivery/notes/openwebui-cicd-gitops.md) | 凭据已脱敏 |
| `openwebuicicd/OPENWEBUI-OPS-RUNBOOK.md` | [10/notes/openwebui-ops-runbook.md](../../10-cicd-delivery/notes/openwebui-ops-runbook.md) | 凭据已脱敏 |
| `openwebuicicd/openwebui-gitops/README.md` | [10/assets/openwebui/gitops/README.md](../../10-cicd-delivery/assets/openwebui/gitops/README.md) | 原样保留 |
| `openwebuicicd/scripts/setup-containerd-harbor.sh` | [10/scripts/setup-containerd-harbor.sh](../../10-cicd-delivery/scripts/setup-containerd-harbor.sh) | 凭据已脱敏 |
| `openwebuicicd/scripts/install-frps-vps.sh` | [10/scripts/install-frps-vps.sh](../../10-cicd-delivery/scripts/install-frps-vps.sh) | token 已脱敏 |
| `create_vms.sh` | [12/scripts/create_vms.sh](../../12-proxmox-pve/scripts/create_vms.sh) | VM 批量创建 |
| `nat.sh` | [12/scripts/nat.sh](../../12-proxmox-pve/scripts/nat.sh) | PVE NAT |
| `create-lab-vms.sh` | [12/scripts/create-lab-vms.sh](../../12-proxmox-pve/scripts/create-lab-vms.sh) | 实验 VM |
| `resize-lvm.sh` | [12/scripts/resize-lvm.sh](../../12-proxmox-pve/scripts/resize-lvm.sh) | VM LVM 扩容 |
| `stopallvm.sh` | [12/scripts/stopallvm.sh](../../12-proxmox-pve/scripts/stopallvm.sh) | 批量关机 |
| `start-all-vm.sh` | [12/scripts/start-all-vm.sh](../../12-proxmox-pve/scripts/start-all-vm.sh) | 批量开机 |
| `clean-cloudinit.sh` | [12/scripts/clean-cloudinit.sh](../../12-proxmox-pve/scripts/clean-cloudinit.sh) | 清理 cloud-init ISO |
| `fix-sshv2.sh` | [12/scripts/fix-sshv2.sh](../../12-proxmox-pve/scripts/fix-sshv2.sh) | 弱口令已脱敏 |
| `gen-hosts.sh` | [12/scripts/gen-hosts.sh](../../12-proxmox-pve/scripts/gen-hosts.sh) | 生成 hosts |
| `ssh-hosts.sh` | [12/scripts/ssh-hosts.sh](../../12-proxmox-pve/scripts/ssh-hosts.sh) | 弱口令已脱敏 |
| `civms.sh` | [12/scripts/civms.sh](../../12-proxmox-pve/scripts/civms.sh) | 弱口令已脱敏 |
| `create-k8s-vms.sh` | [12/scripts/create-k8s-vms.sh](../../12-proxmox-pve/scripts/create-k8s-vms.sh) | 密码哈希已脱敏 |
| `openwebuicicd/.secrets/env.sh` | 未入库 | 含真实凭据，按“敏感文件”直接删除，不备份 |

## 2. 10 天内、保留在原位置（已纳入教程或属于工作仓）

| 文件 | 教程位置 / 说明 |
|---|---|
| `k8s-ceph-disk-optimization-2026-11-05.md` | [06/notes/ceph-disk-optimization-2026-11-05.md](../../06-storage-ceph/notes/ceph-disk-optimization-2026-11-05.md) |
| `pve-vg-thinpool-analysis-2026-11-06.md` | [12/notes/pve-vg-thinpool-analysis-2026-11-06.md](../../12-proxmox-pve/notes/pve-vg-thinpool-analysis-2026-11-06.md) |
| `pve-lvm-storage-guide-2026-11-07.md` | [12/notes/pve-lvm-storage-guide-2026-11-07.md](../../12-proxmox-pve/notes/pve-lvm-storage-guide-2026-11-07.md) |
| `pve-vm-disk-location-guide-2026-11-07.md` | [12/notes/pve-vm-disk-location-2026-11-07.md](../../12-proxmox-pve/notes/pve-vm-disk-location-2026-11-07.md) |
| `tekton-history-retention-2026-11-06.md` | [10/notes/tekton-history-retention-2026-11-06.md](../../10-cicd-delivery/notes/tekton-history-retention-2026-11-06.md) |
| `tekton-operator-migration-2026-11-07.md` | [10/notes/tekton-operator-migration-2026-11-07.md](../../10-cicd-delivery/notes/tekton-operator-migration-2026-11-07.md) |
| `tekton-platform-gitops/README.md` | [10/notes/tekton-platform-gitops-readme.md](../../10-cicd-delivery/notes/tekton-platform-gitops-readme.md) |
| `k8s-postmortem/*.md`（8 篇） | 分配至 03/04/06/09/11 的 `notes/` |
| `k8s-postmortem/README.md` | [09/notes/2026-11-09-weekly-postmortem-index.md](../../09-incidents-and-readiness/notes/2026-11-09-weekly-postmortem-index.md) |
| `k8s-postmortem/fixes/enforce-rp-filter.sh` | [06/scripts/enforce-rp-filter.sh](../../06-storage-ceph/scripts/enforce-rp-filter.sh) |
| `k8s-cpu-v3-migration-2026-11-09.md` | [01/notes/cpu-v3-migration-2026-11-09.md](../../01-kubernetes-k3s/notes/cpu-v3-migration-2026-11-09.md) |
| `k8s-ceph-csi-upgrade-operator-2026-11-09.md` | [06/notes/ceph-csi-upgrade-to-operator-2026-11-09.md](../../06-storage-ceph/notes/ceph-csi-upgrade-to-operator-2026-11-09.md) |
| `k8s-ceph-csi-operator-how-it-works-2026-11-09.md` | [06/notes/ceph-csi-operator-how-it-works-2026-11-09.md](../../06-storage-ceph/notes/ceph-csi-operator-how-it-works-2026-11-09.md) |
| `k8s-cnpg-operator-how-it-works-2026-11-09.md` | [06/notes/cnpg-operator-how-it-works-2026-11-09.md](../../06-storage-ceph/notes/cnpg-operator-how-it-works-2026-11-09.md) |
| `k8s-traefik-gitops-remediation-2026-11-09.md` | [07/notes/traefik-gitops-remediation-2026-11-09.md](../../07-networking/notes/traefik-gitops-remediation-2026-11-09.md) |
| `apply_discard.sh` | [12/scripts/apply_discard.sh](../../12-proxmox-pve/scripts/apply_discard.sh) |
| `fix_images.py` | [01/scripts/fix_images.py](../../01-kubernetes-k3s/scripts/fix_images.py) |
| `finish_worker01.sh` | [12/scripts/finish_worker01.sh](../../12-proxmox-pve/scripts/finish_worker01.sh) |
| `gitops-p0/README.md` 及 `platform/**/*.md` | [11/notes/platform-gitops-repo/](../../11-gitops-platform/notes/platform-gitops-repo/) |
| `gitops-p0/scripts/clean-k8s-yaml.py` | [11/scripts/clean-k8s-yaml.py](../../11-gitops-platform/scripts/clean-k8s-yaml.py) |
| `gitops-p0/scripts/gitlab-create-grafana-oauth-app.sh` | [11/scripts/gitlab-create-grafana-oauth-app.sh](../../11-gitops-platform/scripts/gitlab-create-grafana-oauth-app.sh) |

## 3. 排除项（未纳入教程，保留原状）

| 目录 | md/脚本数量 | 原因 |
|---|---:|---|
| `openwebuicicd/open-webui/` | 302 | 上游 open-webui 源码仓库，含自己的文档和脚本 |
| `.oh-my-zsh/` | 437 | shell 框架 |
| `.cache`、`.local`、`.npm`、`.config`、`.opencode`、`.ansible`、`.terraform.d`、`.kube`、`.ssh` | 0 | 系统/工具状态，无 md/脚本 |

## 4. 结果

- 10 天前的 md 和脚本：**21 个文件全部删除**（20 个已入库 + 1 个敏感文件）；
- 10 天内的 md/脚本：保留原位置，均已在教程或工作仓中有对应；
- 未统计的 md/脚本：**0**（排除项已列明数量）。
