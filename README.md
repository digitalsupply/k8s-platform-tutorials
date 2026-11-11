# K8s 平台工程实战教程

这是一套从**真实集群排障与改造**中整理出来的教程，不是纯理论笔记。

每个分类都保留四件事：

1. **当时的情况**：改造前是什么状态、为什么要做；
2. **主要概念与原理**：理解问题需要的背景；
3. **踩坑点**：现象、根因、错误做法；
4. **修复关键**：真正解决问题的动作。

以及对应的**文档、YAML、Python/Shell 脚本**，按分类放在一起，能直接对照复现。

> 最后整理：2026-11-10  
> 案例环境：kubeadm Kubernetes `v1.35.9`，3 control-plane + 3 worker；  
> Cilium `1.20.4`（KPR + Host BPF + BPF masquerade + native routing）；  
> ArgoCD `v3.5.3`；kube-prometheus-stack `83.7.0`；prometheus-operator `0.90.1`；  
> Ceph Reef `18.2.8`（外部 3 节点）；Traefik `v3.7.17`；GitLab CE `19.4.2`。

---

## 目录

| 分类 | 内容 | 适合谁 |
|---|---|---|
| [00 集群全景](docs/00-cluster-overview/README.md) | 拓扑、版本、边界、生产化差距、当前实况快照 | 第一次接触这套环境的人 |
| [01 Kubernetes](docs/01-kubernetes-k3s/README.md) | Pod 进程模型、k3s 概念、1.29→1.35 升级、控制面/节点/资源/稳定性核心考点 | 想真正看懂 Pod 与升级的人 |
| [02 Cilium / eBPF](docs/02-cilium-ebpf/README.md) | eBPF 核心概念、Calico→Cilium 全量迁移、KPR、L2 Announcements、Hubble | 排查 Service/NodePort/LB/网络策略的人 |
| [03 GitLab / Harbor](docs/03-gitlab/README.md) | GitLab 安装/端口、账号/角色、Token/Webhook、Runner/Tekton、Harbor OIDC/Robot/镜像仓库 | 做 GitLab 运维、CI/CD、镜像仓库与权限治理的人 |
| [04 Monitoring GitOps](docs/04-monitoring-gitops/README.md) | Prometheus/Alertmanager/WeCom、Loki/Alloy、Tempo、Grafana、规则 GitOps、指标基数/PromQL/日志轮转/Trace 采样/成本治理 | 做 K8s 可观测性与告警治理的人 |
| [05 Linux](docs/05-linux/README.md) | 内核、用户态、文件系统、权限 UGO→capability、进程、内存、systemd、参数限制 | Linux 基础与主机层运维 |
| [06 Storage / Ceph](docs/06-storage-ceph/README.md) | RBD/CSI、PV 回收、CNPG 备份、RGW、PV 泄漏、分区/LVM/RAID/文件系统基础 | 管存储、PVC、数据库备份、磁盘/文件系统的人 |
| [07 Networking](docs/07-networking/README.md) | Traefik/IngressRoute、Service/iptables、DNS、隧道、IPIP/VXLAN | 排查入口、DNS、Service 不通的人 |
| [08 Control Plane HA](docs/08-control-plane-ha/README.md) | kube-vip、API VIP、apiserver 内存、etcd 备份/恢复 | 管控制面高可用的人 |
| [09 生命周期与生产化](docs/09-incidents-and-readiness/README.md) | Knative/Tekton/宿主机应用下线、清理、生产化审计、三个不可逆（操作/状态/决策） | 做组件治理与生产化的人 |
| [10 CI/CD 交付](docs/10-cicd-delivery/README.md) | GitLab→Tekton→BuildKit→Harbor→ArgoCD、Webhook、BuildKit 排障、流水线阶段/缓存/分层/tag/发布/回滚 | 做 GitOps/CI-CD 的人 |
| [11 GitOps 平台化](docs/11-gitops-platform/README.md) | app-of-apps、覆盖盘点、Sealed Secrets、Vault/ESO 取舍、IaC 演进（Ansible/Terraform/GitOps） | 想把集群真正交给 Git 的人 |
| [12 Proxmox VE](docs/12-proxmox-pve/README.md) | PV/VG/LV、LVM-thin、VM 磁盘、discard、Terraform/cloud-init/Ansible IaC、KVM/QEMU/virtio/IMDS/引导 | 管宿主机、VM、磁盘容量与批量建机的人 |
| [13 SSO / OIDC](docs/13-sso-oidc/README.md) | GitLab 作为 IdP、Grafana/ArgoCD/Harbor 原生 OIDC、oauth2-proxy 反代、Ceph SAML 阻塞 | 做统一登录与平台安全的人 |
| [14 Containers](docs/14-containers/README.md) | Docker/containerd/CRI/OCI、镜像层、overlay、生命周期、网络、存储、capability、排障 | 管容器运行时、镜像、Pod 安全与 CI 构建的人 |
| [15 面试速查](docs/15-interview-cheatsheet/README.md) | Linux/网络/存储/K8s/虚拟化/IaC/CI-CD/可观测性/三个不可逆 一句话答案 + 真机证据 + 纠偏 | 面试复习、快速定位知识盲区 |
| [16 中间件 OS 层](docs/16-middleware-os/README.md) | Redis/MySQL/Kafka/Nginx/Java 的 THP、overcommit、page cache、fd、cgroup、JVM 容器化 | 管中间件、做 OS 调优的人 |
| [17 SRE](docs/17-sre/README.md) | SLI/SLO/Error Budget、burn rate 多窗口、症状告警、SEV/IC、Postmortem、变更相关性 | 做 SRE、值班、事故管理的人 |

---

## 怎么读

1. **先读 00**，建立节点、网络、存储、入口、可观测性的地图；
2. **再按问题选分类**：Service 不通看 02/07，告警不响看 04，PVC 不回收看 06，控制面抖动看 08；
3. **每个分类先读 README**，再看 `notes/` 里的原始过程记录；
4. **需要复现时看 `assets/` / `scripts/`**，但不要直接 apply 到生产，先替换 IP、域名、凭据。

推荐学习顺序（从概念到工程）：

```text
01 Pod/进程模型
  → 07 Service/iptables/DNS
  → 02 Cilium/eBPF
  → 04 可观测性
  → 06 存储与备份
  → 08 控制面 HA
  → 09 生命周期
  → 10 CI/CD
  → 11 GitOps 平台化
  → 12 PVE/宿主机
  → 13 SSO/OIDC
  → 14 容器运行时
  → 15 面试速查
```

---

## 当前集群状态（2026-11-10 快照，2026-11-11 补充 Hyper-V 宿主）

> 完整快照见 [00-cluster-overview/assets/current-state.md](docs/00-cluster-overview/assets/current-state.md)。

| 项 | 状态 |
|---|---|
| 节点 | 6/6 Ready，`v1.35.9`，containerd `2.3.2` |
| CNI | Cilium `1.20.4`，6/6 agent Running |
| Service 数据面 | `KubeProxyReplacement=True`，Host BPF，BPF masquerade，native routing |
| kube-proxy | 已移除（DaemonSet/CM/ServiceMonitor 均不存在） |
| 入口 | Traefik `10.0.0.252`，Cilium L2 宣告；MetalLB Speaker 已缩容到 0，Controller 保留 |
| ArgoCD | 31 个 Application，全部 Synced/Healthy |
| 监控 | Prometheus/Alertmanager/Grafana 正常；PrometheusRule 41 个；ServiceMonitor 14 个 |
| 日志 | Loki `3.6.7` + Alloy `v1.20.0` |
| 追踪 | Tempo `3.0.3`（tempo-distributed） |
| 存储 | Ceph Reef `18.2.8`，`HEALTH_OK`；17 个 PV 全部 Bound |
| 备份 | etcd 每小时快照（`etcd-backup/etcd-snapshot`）；CNPG Barman 备份 |
| 交付 | GitLab Runner + Tekton + BuildKit + Harbor + ArgoCD |
| GitLab/Harbor 宿主 | Windows Hyper-V `SYZX-HY2-TX` `192.168.67.110`；`ubuntu01`/`ubuntu02` VM（非物理机） |
| 统一登录 | GitLab OIDC：Grafana/ArgoCD/Harbor 原生；Traefik/Hubble/Alloy/Tekton 走 oauth2-proxy |

> 数字会变。把 `current-state.md` 当“某个时刻的证据”，而不是永久配置。

---

## 配套 YAML / Python / Shell 索引

| 分类 | 配套资产 |
|---|---|
| 00 集群全景 | [`cluster_inventory.py`](docs/00-cluster-overview/scripts/cluster_inventory.py)、[`current-state.md`](docs/00-cluster-overview/assets/current-state.md)、[`hyperv-host-20261111/`](docs/00-cluster-overview/assets/hyperv-host-20261111/README.md) |
| 01 Kubernetes | [`pod_inspect.py`](docs/01-kubernetes-k3s/scripts/pod_inspect.py)、[`collect_k8s_interview_evidence.sh`](docs/01-kubernetes-k3s/scripts/collect_k8s_interview_evidence.sh)、[`upgrade-scripts/`](docs/01-kubernetes-k3s/assets/upgrade-scripts/)、[`interview-evidence/`](docs/01-kubernetes-k3s/assets/interview-evidence/m01-evidence.txt) |
| 02 Cilium/eBPF | [`labs/`](docs/02-cilium-ebpf/labs/README.md)、[`experiment/`](docs/02-cilium-ebpf/experiment/README.md)、[`collect_cilium_bpf.py`](docs/02-cilium-ebpf/scripts/collect_cilium_bpf.py)、[`assets/`](docs/02-cilium-ebpf/assets/) |
| 03 GitLab/Harbor | [`check_ports.py`](docs/03-gitlab/scripts/check_ports.py)、[`assets/`](docs/03-gitlab/assets/)、账号/Token/Webhook、CI-CD、Harbor 文档 |
| 04 Monitoring | [`manifests/`](docs/04-monitoring-gitops/manifests/README.md)、[`assets/`](docs/04-monitoring-gitops/assets/)、[`observability-engineering/`](docs/04-monitoring-gitops/assets/observability-engineering/README.md)、[`gen-dashboards.py`](docs/04-monitoring-gitops/assets/gen-dashboards.py) |
| 05 Linux | [`collect_linux_evidence.sh`](docs/05-linux/scripts/collect_linux_evidence.sh)、[`linux_lab_experiments.sh`](docs/05-linux/scripts/linux_lab_experiments.sh)、[`sudo_audit.py`](docs/05-linux/scripts/sudo_audit.py)、[`grow-lvm.sh`](docs/05-linux/scripts/grow-lvm.sh) |
| 06 Storage/Ceph | [`find_orphan_pv.py`](docs/06-storage-ceph/scripts/find_orphan_pv.py)、[`ceph_csi_inventory.py`](docs/06-storage-ceph/scripts/ceph_csi_inventory.py)、[`inspect-released-pv.sh`](docs/06-storage-ceph/scripts/inspect-released-pv.sh)、[`rbd-du.sh`](docs/06-storage-ceph/scripts/rbd-du.sh)、[`ceph-csi-operator/`](docs/06-storage-ceph/assets/ceph-csi-operator/)、[`cnpg/`](docs/06-storage-ceph/assets/cnpg/) |
| 07 Networking | [`current-ingressroutes.yaml`](docs/07-networking/assets/current-ingressroutes.yaml)、[`current-metallb-config.yaml`](docs/07-networking/assets/current-metallb-config.yaml) |
| 08 Control Plane | [`kube-vip-ha-daemonset-FIXED.yaml`](docs/08-control-plane-ha/assets/kube-vip-ha-daemonset-FIXED.yaml)、[`planA-switch-worker.sh`](docs/08-control-plane-ha/scripts/planA-switch-worker.sh)、[`etcd-snapshot-cronjob.yaml`](docs/08-control-plane-ha/assets/etcd-snapshot-cronjob.yaml) |
| 09 生命周期 | [`pre_removal_audit.py`](docs/09-incidents-and-readiness/scripts/pre_removal_audit.py)、[`cleanup_checklist.md`](docs/09-incidents-and-readiness/scripts/cleanup_checklist.md) |
| 10 CI/CD | [`tekton/`](docs/10-cicd-delivery/assets/tekton/)（Task/Pipeline/Trigger/EventListener/BuildKit）、[`tekton-operator/`](docs/10-cicd-delivery/assets/tekton-operator/)、[`openwebui/`](docs/10-cicd-delivery/assets/openwebui/)、[`pipeline-release/`](docs/10-cicd-delivery/assets/pipeline-release/README.md)、[`tekton_retention_audit.py`](docs/10-cicd-delivery/scripts/tekton_retention_audit.py) |
| 11 GitOps | [`app-of-apps.yaml`](docs/11-gitops-platform/assets/argocd/app-of-apps.yaml)、[`sealed-secrets/`](docs/11-gitops-platform/assets/sealed-secrets/)、[`10-iac-evolution.md`](docs/11-gitops-platform/10-iac-evolution.md)、[`clean-k8s-yaml.py`](docs/11-gitops-platform/scripts/clean-k8s-yaml.py)、[`argocd_gitops_audit.py`](docs/11-gitops-platform/scripts/argocd_gitops_audit.py) |
| 12 Proxmox | [`pve_storage_report.py`](docs/12-proxmox-pve/scripts/pve_storage_report.py)、[`pve-state/`](docs/12-proxmox-pve/assets/pve-state/)、[`xceuler/`](docs/12-proxmox-pve/assets/xceuler/)、[`iac/`](docs/12-proxmox-pve/iac/README.md)、[`kvm-cloud-boot/`](docs/12-proxmox-pve/assets/kvm-cloud-boot/README.md)、[`vm-configs/`](docs/12-proxmox-pve/assets/vm-configs/) |
| 13 SSO/OIDC | [`verify_sso.sh`](docs/13-sso-oidc/scripts/verify_sso.sh)、[`oauth2-proxy/`](docs/13-sso-oidc/assets/oauth2-proxy/)、[`argocd-values.yaml`](docs/13-sso-oidc/assets/argocd-values.yaml) |
| 14 Containers | [`collect_container_evidence.sh`](docs/14-containers/scripts/collect_container_evidence.sh)、[`assets/evidence/`](docs/14-containers/assets/evidence/README.md)、[`labs/`](docs/14-containers/labs/README.md) |
| 15 面试速查 | [`assets/evidence/`](docs/15-interview-cheatsheet/assets/evidence/README.md)、[`labs/`](docs/15-interview-cheatsheet/labs/README.md)、Linux/网络/存储/K8s/虚拟化/IaC/CI-CD/可观测性/不可逆 一句话答案 |
| 16 中间件 OS | [`assets/evidence/`](docs/16-middleware-os/assets/evidence/README.md)、[`collect_middleware_os.sh`](docs/16-middleware-os/scripts/collect_middleware_os.sh)、Redis/Kafka/Nginx/Java 真机配置 |
| 17 SRE | [`10-slo-incident-alerting.md`](docs/17-sre/10-slo-incident-alerting.md)、[`slo/`](docs/17-sre/assets/slo/compassio-slo-rules.yaml)、[`templates/`](docs/17-sre/assets/templates/postmortem.md)、[`evidence/`](docs/17-sre/assets/evidence/README.md) |

说明：

- Python 脚本只依赖标准库和系统命令（`kubectl`/`crictl`/`ss`/`iptables`/`nft`/`ceph`/`rbd`）；
- `pod_inspect.py`、`collect_cilium_bpf.py`、`cluster_inventory.py` 需要能访问集群；
- `sudo_audit.py`、`check_ports.py`、`find_orphan_pv.py`、`pre_removal_audit.py` 是**只读**诊断脚本；
- 升级/迁移/清理脚本是当时环境的产物，**执行前必须改 IP、节点名、版本和凭据**。

---

## 仓库结构

```text
k8s-platform-tutorials/
├── README.md
└── docs/
    ├── 00-cluster-overview/
    │   ├── README.md              # 分类导读：情况/原理/坑/修复
    │   ├── notes/                 # 原始过程记录
    │   ├── assets/                # 快照、备份、导出的 YAML
    │   └── scripts/               # Python/Shell 工具
    ├── 01-kubernetes-k3s/
    ├── 02-cilium-ebpf/
    ├── 03-gitlab/
    ├── 04-monitoring-gitops/
    ├── 05-linux/
    ├── 06-storage-ceph/
    ├── 07-networking/
    ├── 08-control-plane-ha/
    ├── 09-incidents-and-readiness/
    ├── 10-cicd-delivery/
    ├── 11-gitops-platform/
    ├── 12-proxmox-pve/
    ├── 13-sso-oidc/
    ├── 14-containers/
    ├── 15-interview-cheatsheet/
    ├── 16-middleware-os/
    └── 17-sre/
```

每个分类目录的统一约定：

- `README.md`：导读（当时情况 / 概念原理 / 踩坑点 / 修复关键 / 文档与资产索引）；
- `notes/`：当时写的过程记录、审计报告、执行报告（保留原始细节）；
- `assets/`：YAML、JSON、配置备份、当前状态快照；
- `scripts/`：Python/Shell 工具，优先只读、可重复执行。

---

## 脱敏与免责声明

- 文档中的 `10.x.x.x`、`192.168.x.x`、`*.k8s.local`、`*.example.local` 等均为实验环境地址，
  属于 RFC1918 私有网段，不能从公网访问；请替换成你自己的环境。
- 所有真实密码、token、webhook URL、私钥、GitLab Runner token 都已替换为
  `<redacted-...>` 或 `example.invalid`。
- 命令中的命名空间、release 名、镜像版本、节点名需要按你的环境调整。
- 生产环境操作前请先在测试集群验证，尤其是：
  - CRD 升级/删除；
  - CNI 全量切换；
  - PVC/PV/RBD 清理；
  - etcd 快照恢复；
  - NetworkPolicy 与 iptables/nftables 清理；
  - kube-vip/VIP 故障注入。

---

## 相关仓库

- GitLab：<http://192.168.67.201/digitalsupply/k8s-platform-tutorials>
- GitHub：<https://github.com/digitalsupply/k8s-platform-tutorials>

> 两边的 `main` 分支保持同一份内容；提交以本地工作区为准。
