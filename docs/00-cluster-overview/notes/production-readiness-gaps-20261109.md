# K8s 集群“生产化”差距审计

> 日期：2026-11-09  
> 集群：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker）  
> CNI：Cilium 1.20.4（KPR + Host BPF + BPF masquerade）  
> 规模：133 个 Running Pod，105+ Service  
> 说明：以下按“典型生产基线”评估，不否定当前是有意为之的单机/小集群取舍。

---

## 0. 结论概览

| 级别 | 数量 | 关键词 |
|---|---:|---|
| P0 | 6 | 无 etcd 备份、无审计/加密、关键单副本、磁盘/内存水位、kubelet 未预留 |
| P1 | 9 | 69 个单副本、PDB/HPA/VPA 缺失、PSA/NetworkPolicy/Quota 覆盖不足、安全上下文 |
| P2 | 8 | 测试残留、日志/指标长期存储、告警单通道、NFS SPOF |

**最需要先处理的 5 件事：**

1. ~~etcd 备份 + PVC 备份（当前完全没有）~~ → ✅ 2026-11-09 已加 etcd 小时快照（见 §7）
2. API Server 审计日志 + Secret 静态加密
3. worker01 磁盘 74%、m01/master02 内存 84%
4. 入口/ GitOps / 监控的单副本（Traefik、ArgoCD、Prometheus）
5. kubelet `systemReserved`/`kubeReserved`/`evictionHard` 未配置（分析与建议见 §8）

---

## 1. P0：数据与恢复能力

### 1.1 没有 etcd 备份

现状：

```text
kubectl get cronjob -A          -> No resources found
/var/backups                    -> 空
/etc/cron.d                     -> 只有 barman（CNPG 备份）
Velero                          -> 未安装
```

etcd 本身是健康的：

```text
3 members: m01 / master01 / master02
endpoint health: healthy
DB size: 126 MB (in use 41 MB), quota 2.1 GB
alarms: none
```

但没有快照机制，误删 CRD/Namespace、etcd 数据损坏时无法恢复到指定时间点。

**建议：**

- 每 30 分钟 `etcdctl snapshot save` 到独立存储，保留 7–30 天；
- 至少每季度做一次 restore 演练；
- 关键 PVC（CNPG 已用 barman）之外，补 Velero 或 Kopia 做命名空间级备份。

### 1.2 API Server 没有审计日志，Secret 没有静态加密

`kube-apiserver` 启动参数里只有：

```text
--authorization-mode=Node,RBAC
--enable-admission-plugins=NodeRestriction
```

没有：

```text
--audit-log-path / --audit-policy-file
--encryption-provider-config
```

影响：

- 谁在什么时候 `get secrets`、`exec`、`delete` 无法追溯；
- etcd 磁盘/备份里的 Secret 是 base64 明文；
- 等保/审计场景直接不达标。

**建议：**

- 加 audit policy（Metadata 级别起步，关键资源 RequestResponse）；
- 配置 KMS 或 `aescbc` EncryptionConfiguration，并轮换旧 Secret（`kubectl get secrets -A -o yaml | kubectl replace`）。

### 1.3 kubelet 没有预留系统资源

`kubelet-config` 中没有：

```text
systemReserved
kubeReserved
evictionHard
```

影响：

- 系统进程（containerd、kubelet、sshd）与 Pod 争抢 CPU/内存；
- 节点内存吃紧时，可能先杀系统进程或出现 `FreeDiskSpaceFailed`；
- 没有明确的 eviction 阈值，行为依赖默认值。

**建议：**

```yaml
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
kubeReserved:
  cpu: 300m
  memory: 1Gi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
```

### 1.4 节点水位偏高

| 节点 | 根分区使用 | 内存使用 | 备注 |
|---|---:|---:|---|
| m01 | 54% | **84%** | 4C/5.8G，control-plane |
| master01 | 46% | 53% | 6C/6G |
| master02 | 47% | **84%** | 4C/4G，control-plane |
| worker01 | **74%** | 64% | 持续 `FreeDiskSpaceFailed` |
| worker02 | 46% | 32% | 6C/10G |
| worker03 | 65% | 31% | 4C/8G |

worker01 事件：

```text
Warning FreeDiskSpaceFailed
Insufficient free disk space on the node's image filesystem
(75% of 56.9 GiB used)
```

**建议：**

- worker01 清理镜像/日志/旧 PVC，或扩容磁盘；
- master02/m01 内存 84%，建议加内存或把非必要系统组件迁走；
- 给 imagefs 设 alert（>80% warning，>85% critical）。

### 1.5 关键单副本（无 HA）

| 组件 | 副本 | 影响 |
|---|---:|---|
| Traefik | 1 | 入口全挂（虽然有 NodePort 兜底，但 VIP/Ingress 不可用） |
| ArgoCD（controller/repo/server/redis） | 1 | GitOps 控制面不可用 |
| Prometheus | 1 | 监控中断，历史数据在单 PVC |
| Alertmanager | 1 | 告警中断 |
| cert-manager（3 个组件） | 1 | 证书到期无法续签 |
| sealed-secrets | 1 | 新 Secret 无法解密 |
| ceph-csi-rbd-provisioner | 1 | 新 PVC 无法创建 |
| nfs-provisioner | 1 | NFS PVC 无法创建 |
| Kafka broker | 1 | 消息面单点 |
| Loki（backend/read/write/gateway） | 1 | 日志查询/写入中断 |
| Tempo（distributor/querier/frontend） | 1 | Trace 查询中断 |
| MetalLB controller | 1 | 新 LB IP 无法分配（现有 VIP 不受影响） |

**建议优先级：**

1. Traefik ≥2 副本 + PDB + 反亲和（入口是业务第一跳）
2. ArgoCD repo-server/server ≥2（或至少接受可重建）
3. Prometheus/Alertmanager ≥2（或明确接受监控可丢）
4. cert-manager/sealed-secrets ≥2（控制器本身支持 leader election）
5. Kafka 至少 3 broker（如果消息面重要）

### 1.6 单副本的“伪 HA”组件

- `KafkaNodePool/single-pool` 只有 1 个 broker，但 PDB 设置为 `maxUnavailable: 1`——等于允许整个 Kafka 被驱逐。
- `pg16-ceph` 有 2 个实例 + barman 备份，是当前做得最好的有状态服务。
- `tempo3-block-builder` / `live-store` 是 3 副本，但查询链路仍单副本。

---

## 2. P1：可用性、容量与调度

### 2.1 69 个单副本工作负载

```text
kubectl get deploy,sts -A | replicas=1 -> 69
```

其中不少是内部工具（n8n、open-webui、tekton-dashboard），单副本可以接受；但上面列出的入口、GitOps、监控、证书、存储控制器不应单副本。

### 2.2 PDB 覆盖不足

当前 PDB：

```text
cnpg-system      pg16-ceph-primary（minAvailable 1）
compassio        backend/frontend
kafka            entity-operator / kafka（maxUnavailable 1，单 broker 下无意义）
kube-system      calico-kube-controllers（Calico 已删除，残留）
kube-system      VPA ×3
logging          tempo block-builder / live-store
opentelemetry    otel-collector
```

缺失的重点：

- CoreDNS（2 副本，但无 PDB）
- Cilium agent/operator
- Traefik
- ArgoCD
- cert-manager
- Prometheus / Alertmanager
- Loki gateway/read/write
- MetalLB controller

> 单副本组件加 PDB 意义有限，真正的修复是加副本；但 CoreDNS/Cilium 这种多副本组件必须加 PDB，否则节点 drain 会同时驱逐。

### 2.3 HPA/VPA/拓扑分布

- HPA：只有 2 个 Tekton webhook（min 1 / max 5）。
- VPA：**安装了 VPA 控制器，但没有任何 VPA 对象**，等于闲置。
- `topologySpreadConstraints`：只有 compassio、tempo、wecom-adapter 使用。
- 关键组件没有 `priorityClassName`（只有 ceph-csi 用了 system-critical）。

**建议：**

- 入口/监控/ArgoCD 至少配 `podAntiAffinity`（多副本后）；
- 给关键组件加 `system-cluster-critical` 或自定义 PriorityClass；
- 如果短期不加副本，至少用 VPA 的 `Off` 模式看推荐值，避免拍脑袋配 requests。

### 2.4 NFS 是单点，且回收策略是 Delete

```text
nfs-sc        example.com/nfs   Delete   Immediate
ceph-rbd-sc   rbd.csi.ceph.com  Retain   Immediate
```

- 3 个 PVC 在 NFS 上；
- `nfs-provisioner` 单副本；
- NFS 服务本身不在 K8s 内，故障时这些 PVC 全部不可用；
- `Delete` 策略下误删 PVC 会直接删数据。

**建议：**

- 能迁的迁到 `ceph-rbd-sc`；
- NFS 至少改成 `Retain`；
- nfs-provisioner 加副本或明确接受风险。

### 2.5 组件重启次数偏高

| Pod | 重启 | 备注 |
|---|---:|---|
| ceph-csi-rbd-nodeplugin-dxc2k | 18 | 3h56m 前又重启 |
| ceph-csi-rbd-nodeplugin-rpb86 | 14 | |
| ceph-csi-rbd-nodeplugin-529nc | 12 | |
| kube-apiserver-m01 | 9 | 4d15h 前 |
| compassio-backend | 6 | 7h 内 |
| wecom-adapter ×2 | 5 | |
| tempo3-live-store ×3 | 5 | |
| kube-vip-ds-2lvtm | 5 | |

CSI nodeplugin 反复重启需要查：节点内核、RBD map、`dmesg`、CSI 日志；这类问题会在挂载新卷时放大。

### 2.6 OS/内核不一致

```text
m01        Rocky Linux 9.6   kernel 5.14
master01   Ubuntu 22.04      kernel 5.15
master02   Ubuntu 22.04      kernel 5.15
worker01   Ubuntu 22.04      kernel 5.15
worker02   Ubuntu 22.04      kernel 5.15
worker03   Ubuntu 22.04      kernel 5.15
```

影响：

- 两套包管理/内核参数/日志路径；
- Cilium 的 netkit、Big TCP、部分 XDP 能力受 5.14/5.15 限制；
- 内核安全补丁节奏不一致。

**建议：** 统一 OS 基线，或至少统一内核 minor 版本，并记录差异。

---

## 3. P1：安全与多租户隔离

### 3.1 Pod Security Admission 基本没启用

| Namespace | enforce |
|---|---|
| china-study-free | baseline |
| metallb-system | privileged |
| tekton-pipelines | restricted |
| tekton-pipelines-resolvers | restricted |
| 其余（argocd/logging/monitoring/kafka/cnpg/default…） | 未设置 |

`kube-apiserver` 也没有全局 PSA 配置，等于默认 `privileged`。

**建议：** 先给所有业务命名空间打 `baseline` + `warn=restricted`，再逐步收紧。

### 3.2 NetworkPolicy 覆盖很低

有策略的命名空间：

```text
china-study-free（业务策略 + 探针放行）
kafka（Strimzi 自动生成）
tekton-pipelines（默认拒绝 + 白名单）
monitoring（仅 wecom-adapter）
```

没有默认拒绝、也没有任何策略的：

```text
argocd、logging、cnpg-system、cert-manager、traefik、metallb-system、
nfs-provisioner、gitlab-runner、n8n、open-webui、deeptutor、compassio、default
```

**建议：**

- 先给 `argocd`、`logging`、`monitoring`、`cnpg-system`、`traefik` 加 default-deny；
- 注意 Cilium KPR 下 kubelet 探针源是 host IP，需要显式放行健康端口（本集群已经踩过）。

### 3.3 ResourceQuota / LimitRange 只有 compassio

```text
compassio: resourcequota/compassio-quota + limitrange/compassio-defaults
其余命名空间：无
```

影响：

- 一个命名空间可以吃光节点资源；
- 没有默认 requests/limits，调度器无法准确装箱。

**建议：** 至少给业务命名空间加 `LimitRange` 默认值 + 合理的 `ResourceQuota`。

### 3.4 容器安全上下文覆盖不足

```text
Running Pod 总数：133
runAsNonRoot=true：45
seccompProfile 已设置：71
allowPrivilegeEscalation=false：75
```

特权/高权限工作负载：

| Pod | 原因 | 是否合理 |
|---|---|---|
| ceph-csi-rbd-nodeplugin ×3 | RBD map | 合理，但应限制 |
| cicd/buildkitd | 构建需要 | 高风险，建议隔离节点/命名空间 |
| ceph-csi-rbd-provisioner | CSI | 合理 |
| alloy ×6 | hostPath 读日志 | 合理 |
| node-exporter ×6 | hostNetwork | 合理 |
| kube-vip/etcd/apiserver 等 | 系统组件 | 合理 |

**建议：**

- 业务容器统一 `runAsNonRoot`、`seccompProfile: RuntimeDefault`、`allowPrivilegeEscalation: false`；
- buildkitd 放到独立节点池或至少独立命名空间 + 网络隔离。

### 3.5 凭据与访问控制

| 项 | 现状 |
|---|---|
| Grafana admin | 密码是 `<redacted-grafana-password>`（弱/默认风格），存放在 Secret |
| ArgoCD | `admin.enabled=true`，无 OIDC/Dex connector |
| GitLab 仓库 | `http://192.168.67.201/...` 明文 HTTP，凭据存在 ArgoCD Secret |
| S3/Loki 凭据 | 存在 Helm release，不在 Git（这点做得对），但没有轮换机制 |
| Secret 静态加密 | 无 |
| 镜像签名/准入 | 无 Kyverno/Gatekeeper/Connaisseur |
| 运行时安全 | 无 Falco/Tetragon |

**建议：**

- Grafana 改成强密码并接入 SSO；
- ArgoCD 接 OIDC（GitLab/Keycloak），关闭 admin 或限制；
- 内网 Git 上 TLS，至少避免明文凭据；
- 评估 Kyverno（镜像签名/禁止 latest/强制 requests）与 Tetragon（运行时）。

### 3.6 Ingress TLS 覆盖不全

有 TLS 的：

```text
china-study-free-admin   studyfree-xyz-tls
china-study-free-web     studyfree-xyz-tls
china-study-free-web-admin studyfree-xyz-tls
deeptutor                deeptutor-tls
```

没有 TLS 的：

```text
cicd/china-study-free-el        80
cicd/compassio-el               80
cicd/deeptutor-el               80
compassio                       80
n8n                             80
open-webui                      80
```

Traefik 只设置了 `--entryPoints.websecure.http.tls=true`，没有全局 HTTP→HTTPS 重定向。

**建议：**

- 对面向用户/管理的域名强制 HTTPS（`redirectScheme`）；
- CI webhook 如果必须 HTTP，至少限制来源 IP/加签名校验。

---

## 4. P2：运维卫生与可观测性

### 4.1 显式残留资源

| 资源 | 存在时间 | 建议 |
|---|---:|---|
| `default/netshoot-debug` Deployment（无 tag 镜像） | 185d | 删除 |
| `default/rbd-pvc-test` PVC 1Gi | 219d | 删除 |
| `kube-system` PDB `calico-kube-controllers` | 296d | 删除（Calico 已移除） |
| `tekton-pipelines-resolvers/tekton-pipelines-remote-resolvers` v1.6.0 | 284d | 与新版本重复，确认后删除 |
| `open-webui/frpc` 0/0 | 26d | 确认是否还需要 |
| `tekton-pipelines` 与 `tekton-pipelines-resolvers` 同名 Deployment | 40h/284d | 合并/删除旧版本 |

### 4.2 监控/日志/追踪的长期存储

| 组件 | 副本 | 保留 | 备份 |
|---|---:|---|---|
| Prometheus | 1 | 15d / 25GiB | 无 |
| Alertmanager | 1 | - | 无 |
| Loki | 1 | 120h | 无 |
| Tempo | 1（查询链路） | 依赖配置 | 无 |
| Grafana | 1 | - | 无 |

- 没有 Thanos/Mimir/VictoriaMetrics 长期存储；
- Prometheus/Loki/Grafana 的 PVC 在 Ceph RBD 上，但没有快照/备份策略；
- 只有 CNPG 有 barman 备份。

**建议：**

- 至少给 Prometheus/Loki PVC 加 VolumeSnapshot；
- 关键 dashboard/alert rules 已在 Git（好）；
- 明确“监控数据可丢”的 RPO，否则补远程写。

### 4.3 告警只有单通道

Alertmanager 配置：

```text
route.receiver = n8n-webhook
receivers = [n8n-webhook]
```

所有 `critical|warning` 都进同一个 webhook，没有分级、没有值班升级、没有邮件/IM 兜底。

**建议：**

- 至少加一个独立通道（邮件/企业微信/Slack）；
- critical 与 warning 分开路由；
- 加 Watchdog/DeadMansSwitch 告警，确保告警链路本身可用。

### 4.4 etcd 维护

- 未设置 `--auto-compaction-retention`（当前 DB 126MB/2.1GB，不紧张）；
- 没有 defrag 计划；
- 没有快照（见 P0）。

**建议：** 打开自动 compaction（如 5m/1h），每月 defrag 一次（滚动）。

### 4.5 DNS

- CoreDNS 2 副本，`preferredDuringScheduling` 反亲和（不是 required）；
- 没有 NodeLocal DNSCache。

**建议：** 多节点集群可上 NodeLocal DNSCache，降低 DNS 延迟和 CoreDNS 压力。

### 4.6 其他

- `metrics-server`、`hubble-relay`、`hubble-ui`、`sealed-secrets`、`ceph-csi-provisioner`、`nfs-provisioner` 都是 1 副本；
- `gitlab-runner`、`buildkitd` 单副本，CI 并发/可用性受限；
- `ceph-rbd-sc` 是 `Immediate` binding（不是 `WaitForFirstConsumer`），跨 AZ/节点调度时可能绑到不合适的节点；
- `PriorityClass` 只有系统内置，业务无优先级；
- `automountServiceAccountToken=false 的只有 10 个 Pod；
- 没有 Pod Security Standards 的 `restricted` 全量验证；
- 没有集群级别的 `LimitRange` 默认值。

---

## 5. 已经做得比较“生产”的部分

为避免只列问题，以下现状是加分项：

- 3 个 control-plane + 3 个 etcd member，etcd healthy；
- `authorization-mode=Node,RBAC`；
- Cilium KPR + Host BPF + BPF masquerade + native routing；
- Cilium operator 2 副本，kube-vip 3 副本，CoreDNS 2 副本；
- CNPG 2 实例 + barman 备份 + PDB；
- compassio 有 ReplicaSet 2 副本 + PDB + ResourceQuota + LimitRange + topologySpread；
- 主要业务域名已用 TLS（studyfree.xyz、deeptutor）；
- 关键 dashboard/alert rules、网络组件、监控栈已进入 GitOps；
- 部分命名空间已启用 PSA（tekton restricted、china-study-free baseline）；
- `ceph-rbd-sc` 使用 `Retain`，避免误删 PVC 丢数据。

---

## 6. 建议路线图

### 第一周（P0）

1. etcd 快照 CronJob/外部脚本 + 恢复演练
2. API Server audit policy + Secret 加密
3. worker01 磁盘清理/扩容；m01、master02 内存评估
4. kubelet `systemReserved`/`kubeReserved`/`evictionHard`
5. Traefik 加到 2 副本 + PDB（入口优先）

### 第一个月（P1）

1. ArgoCD、Prometheus、Alertmanager、cert-manager、sealed-secrets 评估 HA
2. CoreDNS/Cilium 加 PDB
3. 业务命名空间补 LimitRange/ResourceQuota
4. argocd/logging/monitoring/cnpg/traefik 加 default-deny NetworkPolicy
5. PSA 全面 `baseline`，逐步 `restricted`
6. 修 CSI nodeplugin 重启、compassio/tempo 重启
7. Kafka 评估 3 broker；NFS 改 Retain 或迁移
8. Grafana 强密码 + SSO；ArgoCD OIDC；Git TLS

### 持续（P2）

1. 清理残留资源（netshoot、rbd-pvc-test、calico PDB、旧 tekton resolvers）
2. 告警双通道 + Watchdog
3. Prometheus/Loki PVC 快照
4. NodeLocal DNSCache（可选）
5. 镜像准入/运行时安全（Kyverno/Tetragon）
6. OS/内核基线统一

---

## 7. 2026-11-09 已处理：etcd 备份 + 残留清理

### 7.1 etcd 备份（已上线）

GitOps：

```text
platform/backup/etcd/
├── namespace.yaml
├── cronjob.yaml
└── README.md
clusters/prod/applications/platform-etcd-backup.yaml
```

实现方式：

- CronJob `etcd-backup/etcd-snapshot`，每小时 `:05`（Asia/Shanghai）；
- 固定调度到 `m01`（control-plane）；
- `hostNetwork: true`，访问 `https://127.0.0.1:2379`；
- 使用 `healthcheck-client.crt/key` + `ca.crt`；
- 直接挂载宿主机 `/usr/local/bin/etcdctl`（静态二进制）；
- **主存储：Ceph RGW S3 `s3://etcd-backups/`（`http://10.0.0.31:7480`）**；
- 本地暂存：m01 `/var/backups/etcd`（24h hourly + 7 daily）；
- S3 lifecycle：`hourly/` 30 天，`daily/` 90 天；
- S3 上传通过只读 chroot 调用宿主机 `/usr/bin/aws`（仅 `CAP_SYS_CHROOT`）。

已手工触发验证（含 S3 上传）：

```text
Snapshot saved at /backup/hourly/etcd-20261109-1544.db
HASH 2a2a6e88  REVISION 58177248  KEYS 9550  SIZE 126 MB
upload: var/backups/etcd/hourly/etcd-20261109-1544.db
        to s3://etcd-backups/hourly/etcd-20261109-1544.db
```

S3 对象：

```text
2026-11-09 15:38:00  126079008 etcd-20261109-1537.db
2026-11-09 15:44:45  126079008 etcd-20261109-1544.db
```

依赖的 Secret（不在 Git）：`etcd-backup/etcd-backup-s3`。

限制：依赖 m01 的 `/usr/bin/aws` 和 `/usr/local/bin/etcdctl`；Ceph RGW 不可用时上传失败，但本地暂存仍保留。

### 7.2 残留清理（已完成）

| 资源 | 处理 | 备份 |
|---|---|---|
| `default/netshoot-debug` Deployment | 删除 | `/root/cleanup-20261109/netshoot-debug.yaml` |
| `default/rbd-pvc-test` PVC | 删除（PV 先改 Delete，底层 RBD 已回收） | `/root/cleanup-20261109/rbd-pvc-test.yaml` |
| `kube-system` PDB `calico-kube-controllers` | 删除（Calico 已不存在） | `/root/cleanup-20261109/calico-pdb.yaml` |
| `tekton-pipelines-resolvers` namespace（v1.6.0 旧 resolvers） | 删除 | `/root/cleanup-20261109/tekton-pipelines-resolvers.yaml` |

验证：

```text
default namespace 只剩 kubernetes Service
kube-system PDB 只剩 VPA ×3
旧 tekton resolvers namespace 不存在
新 resolvers（v1.15.5）仍 Running
TektonConfig Ready=True
```

未删除：`open-webui/frpc`（0/0）是 ArgoCD 管理对象，应由应用仓库决定，不在集群里手工删。

---

## 8. kubelet 预留：是什么、能不能预留

### 8.1 三个字段

```yaml
systemReserved:
  cpu: 100m
  memory: 512Mi
  ephemeral-storage: 1Gi
kubeReserved:
  cpu: 200m
  memory: 1Gi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: 200Mi
  nodefs.available: 10%
  imagefs.available: 15%
```

- `systemReserved`：留给操作系统/sshd/udev 等；
- `kubeReserved`：留给 kubelet、containerd、CNI 等 Kubernetes 系统进程；
- `evictionHard`：低于阈值时 kubelet 主动驱逐 Pod。

公式：

```text
Allocatable = Capacity - systemReserved - kubeReserved - evictionHard
```

当前集群完全没有设置（`/var/lib/kubelet/config.yaml` 和 `kubelet-config` CM 都没有），所以所有容量都可被 Pod 调度，系统进程和 Pod 直接竞争。

### 8.2 当前容量与请求

| 节点 | alloc CPU | requests CPU | alloc Mem | requests Mem | 实际内存 |
|---|---:|---:|---:|---:|---:|
| m01 | 4 | 910m | 5.5Gi | 412Mi | **84%** |
| master01 | 4 | 910m | 5.8Gi | 412Mi | 53% |
| master02 | 4 | 810m | 3.8Gi | 342Mi | **84%** |
| worker01 | 6 | 2910m | 9.8Gi | 6.4Gi | 64% |
| worker02 | 6 | 1310m | 9.8Gi | 3.9Gi | 32% |
| worker03 | 4 | 510m | 7.8Gi | 1.3Gi | 31% |

关键点：**requests 远低于实际使用**（例如 m01 只 request 412Mi，实际用了约 4.7Gi）。这说明大量 Pod 没有 requests/limits，属于 overcommit。

### 8.3 实际应用值（2026-11-09）

先按节点实测“非 Pod 内存/CPU”再定值：

| 节点 | 总内存 | 已用 | Pod 用量 | 非 Pod 用量 | 实际占比 |
|---|---:|---:|---:|---:|---:|
| m01 | 5.5Gi | 4.8Gi | 2.8Gi | 2.0Gi | 84% |
| master01 | 5.8Gi | 3.1Gi | 2.6Gi | 0.5Gi | 53% |
| master02 | 3.8Gi | 3.1Gi | 2.6Gi | 0.5Gi | 84% |
| worker01 | 9.7Gi | 6.3Gi | 5.5Gi | 0.8Gi | 64% |
| worker02 | 9.7Gi | 3.1Gi | 2.6Gi | 0.5Gi | 32% |
| worker03 | 7.8Gi | 2.5Gi | 1.7Gi | 0.8Gi | 31% |

实际写入 `/var/lib/kubelet/config.yaml` 的值：

| 节点 | systemReserved | kubeReserved | evictionHard memory | 预留后 allocatable |
|---|---|---|---|---:|---|
| m01 | 200m / 512Mi | 300m / 1Gi | 200Mi | 3500m / 3.84Gi |
| master01 | 100m / 256Mi | 200m / 768Mi | 200Mi | 3700m / 4.59Gi |
| master02 | 100m / 256Mi | 200m / 512Mi | **100Mi** | 3700m / 2.87Gi |
| worker01 | 150m / 512Mi | 250m / 1Gi | 200Mi | 5600m / 8.01Gi |
| worker02 | 100m / 512Mi | 200m / 1Gi | 200Mi | 5700m / 8.01Gi |
| worker03 | 100m / 512Mi | 200m / 1Gi | 200Mi | 3700m / 6.06Gi |

所有节点 ephemeral-storage：`systemReserved=1Gi`、`kubeReserved=2Gi`。

`kubelet-config` ConfigMap 已同步一个**全局安全基线**（`system 256Mi / kube 512Mi / eviction 100Mi`），保证后续 `kubeadm upgrade` 不会把预留完全清掉；各节点的较大值仍以节点文件为准。

### 8.4 应用结果与注意事项

- 6/6 节点 Ready，所有 Pod Running/Completed，无 MemoryPressure/DiskPressure。
- master02 首次使用 200Mi 阈值时触发了 node-exporter 驱逐；按实际内存改为 **100Mi** 后恢复稳定。
- `kubectl top nodes` 的内存百分比现在按 **allocatable** 计算，m01/master02 会显示 >100%（m01 118%、master02 104%）。这是“实际用量 > allocatable”的显示结果，不代表节点故障；判断健康以 node conditions、eviction 事件和实际可用内存为准。
- m01/master02 内存仍然紧张：建议加内存，或把 Alloy 等非必要 DaemonSet 从 control-plane 节点移走；否则长期处于高水位。
- 每个节点修改前都备份到 `/var/backups/kubelet/config-<node>-<timestamp>.yaml`。
- 回滚：用备份文件覆盖 `/var/lib/kubelet/config.yaml`，`systemctl restart kubelet`。

1. 只改 `kubelet-config` ConfigMap **不会立即生效**；实际配置在每台节点的 `/var/lib/kubelet/config.yaml`。
2. 应用方式：逐节点编辑 `/var/lib/kubelet/config.yaml` → `systemctl restart kubelet`；同时在 `kubelet-config` CM 里同步，保证后续 `kubeadm upgrade` 一致。
3. 重启 kubelet 期间节点会短暂 NotReady，但不会重启业务 Pod；建议维护窗口逐台做。
4. 预留本身不限制 Pod 实际用量，必须配合 requests/limits + `evictionHard`；m01/master02 的根因是 overcommit，不是没预留。
