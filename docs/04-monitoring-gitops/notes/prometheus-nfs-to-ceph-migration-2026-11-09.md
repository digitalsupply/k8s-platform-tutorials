# Prometheus / Alertmanager / Grafana 存储迁移：NFS → Ceph RBD 全过程与运维手册

> 日期：2026-11-09（本地时间 UTC+8）
> 集群：kubeadm v1.35.9，3 master + 3 worker
> 监控栈：kube-prometheus-stack 83.7.0，namespace `monitoring`
> Ceph：Reef 18.2.8，3 mon / 6 OSD，pool `k8s-rbd`，StorageClass `ceph-rbd-sc`
> 结果：三个组件全部运行在 Ceph RBD 上；ArgoCD 16 个 App 全部 `Synced / Healthy`；旧监控 NFS 数据已在验证后清理

---

## 0. 一屏结论

| 组件 | 新 PVC | 容量 | 数据量 | 状态 |
|---|---|---:|---:|---|
| Grafana | `prometheus-grafana-ceph` | 10Gi | 53.3M | 1/1 Running，47 Dashboard / 4 Datasource |
| Alertmanager | `alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0` | 20Gi | 16K | 2/2 Running，API 200 |
| Prometheus | `prometheus-db-ceph-prometheus-prometheus-prometheus-0` | 100Gi | 19.3G | 2/2 Running，ready=200，120 targets up |

2026-11-09 验证完成后，旧监控 NFS PVC 已按运维要求删除，NFS 回滚路径不再可用。
如需回滚，只能依赖备份（`k8s-postmortem/backup`）或 Ceph 快照/备份。

| 组件 | 旧 NFS PVC | 容量 | 最终状态 |
|---|---|---:|---|
| Grafana | `prometheus-grafana` | 10Gi | 已删除（曾从 Released PV 恢复，后清理） |
| Alertmanager | `alertmanager-prometheus-alertmanager-db-alertmanager-prometheus-alertmanager-0` | 20Gi | 已删除 |
| Prometheus | `prometheus-prometheus-prometheus-db-prometheus-prometheus-prometheus-0` | 100Gi | 已删除 |

GitOps 仓库已固化存储配置：

```text
commit 18fa007
feat(monitoring): persist Ceph RBD storage values and migration runbook
platform/monitoring/values.yaml
platform/monitoring/README.md
platform/grafana/README.md
```

> 重要：`monitoring` 的 kube-prometheus-stack 是 **Helm release，不由 ArgoCD 管理**。
> ArgoCD 不会自动回滚本次存储变更；`platform-grafana` 只管理 external 模式的 Grafana CR。

---

## 1. 背景与方案

### 1.1 为什么迁移

原监控数据盘全部在单机 NFS（`10.0.0.1:/data/nfs`，StorageClass `nfs-sc`）：

- NFS 是单点，宿主机/网络故障会影响 Prometheus、Alertmanager、Grafana；
- NFS 上大量小文件，Prometheus TSDB 写入和 compact 延迟不稳定；
- 无法利用 Ceph 的多副本和故障域。

### 1.2 为什么选 `ceph-rbd-sc`

- 集群已有 Ceph RBD CSI（v3.16.2），pool `k8s-rbd`，副本数 3；
- `ceph-rbd-sc` 回收策略 `Retain`，误删 PVC 不会立即丢数据；
- RBD 对 Prometheus TSDB 这种顺序写 + 随机读的场景比 NFS 稳；
- 成本可控：thin provisioning，100Gi PVC 只按实际写入计费。

### 1.3 迁移顺序

按影响面从小到大：

```text
Grafana (10Gi, 53M) → Alertmanager (20Gi, 16K) → Prometheus (100Gi, 19.3G)
```

每一步都保留旧 PVC，确认新盘稳定后再清理（本次最终清理见 7.7）。

---

## 2. 迁移前预检查

### 2.1 Ceph 健康与容量

```bash
ceph -s
ceph df
```

迁移开始时：

```text
health: HEALTH_OK
usage:  20 GiB used, 160 GiB / 180 GiB avail
k8s-rbd  MAX AVAIL ≈ 48 GiB
```

> 注意：`k8s-rbd` 是 3 副本，48GiB 的 `MAX AVAIL` 不是“还能写 48GiB 数据”，
> 而是按最紧张 OSD 估算的可用量。实际可用容量约为裸容量 / 3。

### 2.2 CSI 与 StorageClass

```bash
kubectl get sc ceph-rbd-sc -o yaml
kubectl -n ceph-csi-rbd get pods
```

确认：

- provisioner / nodeplugin 全部 Running；
- `ceph-rbd-sc` 的 `provisioner: rbd.csi.ceph.com`；
- `reclaimPolicy: Retain`。

### 2.3 20Gi 测试 PVC

先创建一个 20Gi 测试 PVC，确认 thin provisioning 和绑定正常，再迁移生产数据：

```bash
kubectl -n monitoring apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-migration-test
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd-sc
  resources:
    requests:
      storage: 20Gi
EOF

kubectl -n monitoring wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/ceph-migration-test --timeout=120s
```

测试完成后删除 PVC/PV。

### 2.4 备份

- Grafana：`/root/k8s-postmortem/backup/grafana.db` + 47 个 Dashboard JSON；
- Helm values：`helm -n monitoring get values prometheus -o yaml`；
- Prometheus/Alertmanager CR：`kubectl -n monitoring get prometheus,alertmanager -o yaml`；
- 旧 NFS PVC 暂时保留；本次在验证完成后已清理，见 7.7。

---

## 3. 迁移执行

### 3.1 Grafana（10Gi，53.3M）

#### 1）停 Grafana

```bash
kubectl -n monitoring scale deploy/prometheus-grafana --replicas=0
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana
```

#### 2）创建新 PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-grafana-ceph
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd-sc
  resources:
    requests:
      storage: 10Gi
```

Bound 后 PV 为 `pvc-aebfac42-a961-4b21-9440-b175989ba2dc`。

#### 3）helper Pod 拷贝

同时挂载旧 NFS PVC `prometheus-grafana` 和新 PVC `prometheus-grafana-ceph`：

```bash
cp -a /old/. /new/
sync
```

结果：

```text
old: 53.3M
new: 53.3M
owner: 472:472（grafana）
```

#### 4）切换 Helm

```bash
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 --reuse-values \
  --set grafana.persistence.existingClaim=prometheus-grafana-ceph
```

验证：

```text
health=200
dashboards=47
datasources=4
```

#### 5）一个后续才发现的坑

Helm 在把 `grafana.persistence.existingClaim` 切到新 PVC 后，
**删除了原来由 chart 管理的旧 PVC `prometheus-grafana`**，
对应 NFS PV 变成 `Released`。

处理见 4.6：从 Released PV 恢复旧 PVC，并把回收策略改为 `Retain`。
该旧 PVC 在最终清理阶段也已删除（见 7.7）。

### 3.2 Alertmanager（20Gi，16K）

#### 1）缩到 0

```bash
kubectl -n monitoring patch alertmanager prometheus-alertmanager \
  --type merge -p '{"spec":{"replicas":0}}'
```

#### 2）创建新 PVC

注意最终 PVC 名：

```text
alertmanager-db-ceph + alertmanager-prometheus-alertmanager-0
= alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd-sc
  resources:
    requests:
      storage: 20Gi
```

PV：`pvc-6d3e4030-94a0-435b-b382-a6158e8caefd`。

#### 3）拷贝数据

旧 PVC：

```text
alertmanager-prometheus-alertmanager-db-alertmanager-prometheus-alertmanager-0
```

数据量只有 16K，`cp -a` 即可。

#### 4）切换 CR

```bash
kubectl -n monitoring patch alertmanager prometheus-alertmanager --type merge -p '{
  "spec": {
    "replicas": 1,
    "storage": {
      "volumeClaimTemplate": {
        "metadata": {"name": "alertmanager-db-ceph"},
        "spec": {
          "storageClassName": "ceph-rbd-sc",
          "accessModes": ["ReadWriteOnce"],
          "resources": {"requests": {"storage": "20Gi"}}
        }
      }
    }
  }
}'
```

验证：

```text
2/2 Running
amtool /api/v2/status = 200
```

### 3.3 Prometheus（100Gi，19.3G）

这是本次迁移的核心，也是事故集中点。

#### 1）停 Prometheus

```bash
kubectl -n monitoring patch prometheus prometheus-prometheus \
  --type merge -p '{"spec":{"replicas":0}}'
```

#### 2）创建新 PVC

最终 PVC 名：

```text
prometheus-db-ceph + prometheus-prometheus-0
= prometheus-db-ceph-prometheus-prometheus-prometheus-0
```

PV：`pvc-271e64b9-9e9b-46d9-9901-487a5927734c`。

#### 3）第一次拷贝（错误 PVC 名称）

第一次把数据拷到了一个少一层 `prometheus` 的 PVC：

```text
prometheus-db-ceph-prometheus-prometheus-0   ← 错误，Operator 不会使用
```

Prometheus 启动后实际使用的是 Operator 自动创建的空 PVC：

```text
prometheus-db-ceph-prometheus-prometheus-prometheus-0
```

**教训：** `volumeClaimTemplate.metadata.name` 只是前缀，最终 PVC 名由 Operator 拼接；
迁移前先用 `kubectl get pvc` 或 `kubectl get sts -o yaml` 确认 Operator 实际使用的 PVC。

#### 4）删除错误 PVC，重新拷贝

```bash
kubectl -n monitoring delete pvc prometheus-db-ceph-prometheus-prometheus-0
kubectl delete pv pvc-57d14997-6868-44ac-83ec-7d0e77ad9a3c
```

重新从旧 NFS PVC 拷贝 19.3G 到正确 PVC：

```bash
cp -a /old/. /new/
rm -f /new/lock
chown -R 1000:2000 /new
```

#### 5）切换 CR

```bash
kubectl -n monitoring patch prometheus prometheus-prometheus --type merge -p '{
  "spec": {
    "replicas": 1,
    "storage": {
      "volumeClaimTemplate": {
        "metadata": {"name": "prometheus-db-ceph"},
        "spec": {
          "storageClassName": "ceph-rbd-sc",
          "accessModes": ["ReadWriteOnce"],
          "resources": {"requests": {"storage": "100Gi"}}
        }
      }
    }
  }
}'
```

#### 6）fsGroup 递归 chown（第一次启动失败）

Pod 卡在 `Init:0/1` 长达 5 分钟以上。根因是 CR 默认：

```yaml
securityContext:
  fsGroup: 2000
```

kubelet 在挂载 RBD 后对 19.3G、大量小文件递归 chown，I/O 被打满。

尝试过：

1. 加 `fsGroupChangePolicy: OnRootMismatch`；
2. 用 helper 把 PVC 根目录设为 `1000:2000` + `2777`（setgid）；
3. 删除卡住的 Pod / 旧 helper；
4. 最终去掉 CR 里的 `fsGroup`，保留 `fsGroupChangePolicy: OnRootMismatch`。

最终 live CR：

```json
{"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":2000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}
```

Pod 启动时间从“卡 30 分钟”降到“约 30 秒”。

#### 7）WAL 损坏（第二次启动失败）

启动时报：

```text
opening storage failed: get segment range: segments are not sequential
failed to read meta.json for a block during repair process; skipping
```

原因：第二次拷贝完成后 helper 卡在 `sync`，被 force delete，WAL 里多了一个失败启动产生的 `00000000` 段，和 `checkpoint.00002401` + `2402..2408` 不连续。

修复：

1. 从旧 NFS PVC 重新 `cp -a` 整个 `wal/`；
2. 删除失败启动产生的 `00000000`；
3. 删除损坏的 block `01M6A337J4DWKFVPY3E5TYHN1S`；
4. 启动后 WAL 回放正常。

验证历史数据：

```bash
curl -s "http://prometheus-prometheus.monitoring:9090/api/v1/query?query=node_load1&time=2026-11-08T12:00:00Z"
```

返回 2026-11-08 的数据，确认历史未丢。

---

## 4. 事故与恢复

### 4.1 Ceph `k8s-rbd` 100% full（最严重）

#### 现象

```text
HEALTH_ERR 1 full osd(s); 15 pool(s) full
k8s-rbd  STORED 42 GiB  USED 127 GiB  %USED 100.00  MAX AVAIL 0 B
```

但 `ceph -s` 显示集群还有：

```text
usage: 133 GiB used, 47 GiB / 180 GiB avail
```

#### 根因

1. `k8s-rbd` 是 3 副本，42GiB 实际数据产生 127GiB 裸写入；
2. 集群只剩 47GiB 裸容量，且分布不均；
3. `osd.2` 先达到 full ratio，`ceph df` 的 `MAX AVAIL` 取最紧张 OSD，直接变成 0；
4. 迁移过程中还产生了多个孤儿 RBD 镜像（包括算错名字、已经拷入 19.3G 数据的 100Gi PVC），进一步吃满空间。

#### 影响

- Prometheus / Alertmanager / Grafana 新 Pod 全部 `FailedMount` / `MountDevice DeadlineExceeded`；
- CSI provisioner 卡在 `Volume ID ... already exists`；
- CNPG 主库 `pg16-ceph-4` 所在 worker02 的 RBD I/O 卡死，触发 failover；
- 最终 worker02 kubelet 进入 D 状态，只能 `qm reset 123` 硬重启。

#### 处理

1. 用 `rbd ls -l k8s-rbd` 列出所有镜像；
2. 用 `kubectl get pv` 的 `spec.csi.volumeHandle` 与镜像名对比，找出没有 PV 引用的孤儿；
3. `rbd status` 确认 `Watchers: none`；
4. `rbd rm` 删除。

本次删除的孤儿镜像：

| 镜像 | 大小 | 说明 |
|---|---:|---|
| `csi-vol-0f7a4eed-fbbc-4567-86aa-ea520dd53698` | 100Gi | 算错名字的 Prometheus PVC，已拷入 19.3G |
| `csi-vol-180ba90b-227c-4553-8f52-5703635acea1` | 20Gi | 无 PV 引用 |
| `csi-vol-554bcd63-61e2-47f3-91b8-1b48259c28a1` | 10Gi | 无 PV 引用 |
| `csi-vol-85352ea6-baf7-4c87-a439-d296f4592985` | 5Gi | 无 PV 引用 |
| `csi-vol-bf69cb70-2570-4863-b35c-a2aaf8f3beff` | 10Gi | 无 PV 引用 |
| `csi-vol-99074b93-39e1-4b08-900c-402cca6c5306` | — | 已删除 ceph2 PVC 的 Released PV 镜像 |

清理后：

```text
HEALTH_OK
k8s-rbd  STORED 21 GiB  USED 63 GiB  %USED 42.88  MAX AVAIL 28 GiB
```

#### 经验

- **不要只看 `HEALTH_OK`**，要看 `MAX AVAIL` 和 `ceph osd df`；
- 单个 OSD full 会让整个 pool 显示 0 B；
- 迁移前先清理孤儿镜像，或至少预留 30% 裸容量；
- 3 副本池的可用数据量约为裸容量 / 3。

### 4.2 CSI / RWO 挂载卡死

现象：

```text
MountVolume.MountDevice failed ... DeadlineExceeded
Aborted ... Volume ID ... already exists
FailedAttachVolume ... Volume is already used by pod(s) ...
FailedAttachVolume ... Volume is already exclusively attached to one node
```

原因：

- Ceph 满，`rbd map` 写日志失败；
- 旧 Pod/helper 未真正退出，RBD 仍被 watcher 占用；
- worker02 硬重启后，旧 VolumeAttachment 残留。

处理顺序：

1. 先恢复 Ceph 容量（见 4.1）；
2. 确认旧 Pod 已退出，必要时 force delete；
3. 检查 `kubectl get volumeattachment | grep <pv>`；
4. 在节点上确认没有残留 `rbd` map / mount；
5. 再删除/重建 Pod，让 attach-detach controller 重新挂载。

> 在 `MAX AVAIL = 0` 时反复重试挂载没有意义，只会制造更多卡住的 GRPC 请求。

### 4.3 worker02 I/O 卡死与硬重启

现象：

- worker02 `NotReady`；
- kubelet 变成僵尸进程；
- `sync`、`jbd2`、`rbd` 等进程 D 状态；
- SSH 能进，但 `systemctl restart kubelet` 卡住。

处理：

```bash
qm reset 123
```

worker02 恢复 Ready 后：

- Prometheus 被调度到 worker03/worker02 重新挂载；
- CNPG `pg16-ceph-4` 触发 failover 到 `pg16-ceph-3`；
- 最终 CNPG `2/2 healthy`。

经验：RBD I/O 卡死时，不要反复 `systemctl restart kubelet`；
先确认节点是否还有 I/O 进展，必要时硬重启，避免长时间拖垮整个集群。

### 4.4 CNPG failover

worker02 硬重启后，CNPG 自动执行：

```text
Current primary isn't healthy, initiating a failover from pg16-ceph-4
Failing over from pg16-ceph-4 to pg16-ceph-3
```

恢复结果：

```text
primary=pg16-ceph-3
ready=2/2
phase=Cluster in healthy state
pg16-ceph-rw -> 10.244.3.183:5432
```

> 这次 failover 是节点故障触发的，不是存储迁移本身的问题；
> 但 Ceph 满导致 RBD I/O 卡死，是 failover 的间接原因。

### 4.5 Grafana Operator Dashboard 同步失败 / ArgoCD Degraded

现象：

- `platform-grafana` ArgoCD `Degraded`；
- 37 个 `GrafanaDashboard` 的 `DashboardSynchronized=False`；
- Operator 日志：

```text
dial tcp 10.101.49.32:80: connect: operation not permitted
```

原因：Grafana Pod 重启期间，Operator 连不上 `prometheus-grafana.monitoring.svc:80`，
错误状态被缓存；Grafana 恢复后 Operator 没有立即重试。

处理：

```bash
kubectl -n grafana-operator rollout restart deploy/grafana-operator
```

重启后：

```text
DashboardSynchronized=True: 37
platform-grafana: Synced / Healthy
```

### 4.6 Grafana 旧 PVC 被 Helm 删除

切换 `grafana.persistence.existingClaim` 后，Helm 删除了 chart 管理的旧 PVC
`prometheus-grafana`，NFS PV 变成 `Released`。

恢复步骤：

```bash
PV=pvc-b5fb0054-d756-4f93-a756-2a75ef20fffb

# 1) 保护数据
kubectl patch pv $PV --type merge \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 2) 清除旧 claimRef，让 PV 变 Available
kubectl patch pv $PV --type json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'

# 3) 用 volumeName 重新绑定旧 PVC
kubectl -n monitoring apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-grafana
  namespace: monitoring
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-sc
  volumeName: $PV
  resources:
    requests:
      storage: 10Gi
EOF
```

结果：

```text
prometheus-grafana   Bound   pvc-b5fb0054-...   10Gi   nfs-sc
PV reclaimPolicy: Retain
```

Grafana 当前仍使用 `prometheus-grafana-ceph`。恢复出的旧 PVC 在最终清理阶段已删除（见 7.7）。

---

## 5. 最终状态

### 5.1 组件

```text
prometheus-prometheus-prometheus-0    2/2 Running
alertmanager-prometheus-alertmanager-0 2/2 Running
prometheus-grafana-...                1/1 Running
```

### 5.2 StorageClass / PVC

| PVC | SC | 容量 | 状态 |
|---|---|---:|---|
| `prometheus-db-ceph-prometheus-prometheus-prometheus-0` | `ceph-rbd-sc` | 100Gi | Bound |
| `alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0` | `ceph-rbd-sc` | 20Gi | Bound |
| `prometheus-grafana-ceph` | `ceph-rbd-sc` | 10Gi | Bound |
| `prometheus-prometheus-prometheus-db-...`（旧） | `nfs-sc` | 100Gi | 已删除（2026-11-09 清理） |
| `alertmanager-prometheus-alertmanager-db-...`（旧） | `nfs-sc` | 20Gi | 已删除（2026-11-09 清理） |
| `prometheus-grafana`（旧） | `nfs-sc` | 10Gi | 已删除（2026-11-09 清理） |

> 清理后 NFS 上只保留业务 PVC：`china-study-free-assets`、`china-study-free-reports`、`cicd/frpc-build-ctx`。

### 5.3 验证结果

```text
Prometheus ready=200
up targets=120
历史数据查询（2026-11-08）= success
Grafana health=200, dashboards=47, datasources=4
Alertmanager API=200
CNPG pg16-ceph: primary=pg16-ceph-3, ready=2/2, Cluster in healthy state
Ceph: HEALTH_OK
k8s-rbd: STORED 21 GiB, USED 63 GiB, 42.88%, MAX AVAIL 28 GiB
ArgoCD: 16/16 Synced / Healthy
全集群无异常 Pod
```

### 5.4 存储配置

```text
Prometheus:
  retention=15d / 25GiB
  pvc=prometheus-db-ceph
  sc=ceph-rbd-sc
  securityContext.fsGroupChangePolicy=OnRootMismatch

Alertmanager:
  pvc=alertmanager-db-ceph
  sc=ceph-rbd-sc

Grafana:
  existingClaim=prometheus-grafana-ceph
  sc=ceph-rbd-sc
```

---

## 6. GitOps 仓库变更

仓库：

```text
http://192.168.67.201/digitalsupply/platform-gitops.git
（SSH：git@192.168.67.201:digitalsupply/platform-gitops.git）
```

本次提交：

```text
18fa007 feat(monitoring): persist Ceph RBD storage values and migration runbook
```

新增/修改：

| 文件 | 作用 |
|---|---|
| `platform/monitoring/values.yaml` | kube-prometheus-stack 的存储、保留策略、Alertmanager 路由、fsGroupChangePolicy |
| `platform/monitoring/README.md` | 当前状态、升级/回滚、PVC 迁移手册、已知坑 |
| `platform/grafana/README.md` | Grafana 新 PVC 与 ArgoCD 管理边界 |

### 6.1 为什么 ArgoCD 不会回滚

- `monitoring` 的 kube-prometheus-stack 是 Helm release，不在任何 ArgoCD Application 的 source path 里；
- `platform-grafana` 只管理 external 模式的 `Grafana` CR，不包含 Deployment/PVC/StorageClass；
- 因此 ArgoCD 的 `selfHeal` 不会改 Prometheus/Alertmanager 的 storage，也不会改 Grafana 的 `existingClaim`。

风险点只有一个：**有人用旧 values 或 `helm upgrade` 不带 `-f platform/monitoring/values.yaml`**。
标准命令见第 7.2 节。

> 如果未来要把 monitoring 整体迁到 ArgoCD，必须按 `platform/monitoring/README.md` 的“历史方案”执行：
> 先关闭 Helm 子 chart，再创建同名 CR，并新增 `platform-monitoring` App。
> 本次没有执行，避免和 Helm release 所有权冲突。

---

## 7. 运维教程

### 7.1 日常检查（建议每天）

```bash
# 1) 组件
kubectl -n monitoring get pods -o wide | \
  grep -E 'prometheus-prometheus-0|alertmanager-prometheus|prometheus-grafana'

# 2) PVC
kubectl -n monitoring get pvc | grep -E 'ceph|nfs-sc'

# 3) Prometheus
kubectl -n monitoring run prom-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  sh -c 'curl -s -o /dev/null -w "ready=%{http_code}\n" \
  http://prometheus-prometheus.monitoring:9090/-/ready'

# 4) Grafana
kubectl -n monitoring get secret prometheus-grafana \
  -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

### 7.2 标准 Helm 升级

```bash
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 \
  -f platform/monitoring/values.yaml \
  --reuse-values
```

必须带 `--reuse-values`：

- 保留未写入 Git 的 `grafana.adminPassword`；
- 保留 Helm release 中其他运行时覆盖值。

升级后检查：

```bash
kubectl -n monitoring rollout status deploy/prometheus-grafana
kubectl -n monitoring get pods -l 'app.kubernetes.io/name in (prometheus,alertmanager,grafana)'
kubectl -n monitoring get prometheus prometheus-prometheus \
  -o jsonpath='{.spec.storage.volumeClaimTemplate.metadata.name} {.spec.storage.volumeClaimTemplate.spec.storageClassName}{"\n"}'
```

### 7.3 Ceph 容量监控（重点）

建议监控：

| 指标 | 告警阈值 | 说明 |
|---|---|---|
| `ceph_health_status` | != 0 | 非 HEALTH_OK |
| `ceph_osd_nearfull_ratio` | > 0.80 | OSD 接近 full |
| `ceph_pool_max_avail` (`k8s-rbd`) | < 20GiB | pool 可用量 |
| `ceph_pool_percent_used` | > 80% | pool 使用率 |
| `ceph_osd_full_ratio` | 触发即 P0 | 单 OSD full 会拖垮整个 pool |

命令：

```bash
ceph -s
ceph df
ceph df detail | grep -E 'POOL|k8s-rbd'
ceph osd df tree
```

**不要只看 `HEALTH_OK`。** 只要 `MAX AVAIL` 接近 0，就应立即清理孤儿镜像或扩容 OSD。

### 7.4 孤儿 RBD 镜像清理

```bash
# 1) 列出镜像
rbd -p k8s-rbd ls -l

# 2) 列出所有 PV 的 volumeHandle
kubectl get pv -o json | python3 - <<'PY'
import sys,json
d=json.load(sys.stdin)
for p in d['items']:
    if p['spec'].get('storageClassName')=='ceph-rbd-sc':
        h=(p['spec'].get('csi') or {}).get('volumeHandle','')
        print(p['metadata']['name'], p['status']['phase'], h.split('-')[-1])
PY

# 3) 对没有 PV 引用的镜像确认无 watcher
rbd -p k8s-rbd status csi-vol-<uuid>
# Watchers: none

# 4) 删除
rbd -p k8s-rbd rm csi-vol-<uuid>
```

注意：

- 先确认 `Watchers: none`；
- 先确认没有 PV/PVC 引用；
- `ceph-rbd-sc` 是 Retain，删除 PVC 不会自动删镜像；
- 删除后看 `ceph df` 的 `MAX AVAIL` 是否恢复。

### 7.5 通用 PVC 迁移手册（适用于其他 StatefulSet）

```text
1. 记录组件当前 PVC 名、容量、挂载点
2. 缩容到 0，确认 Pod 真正退出
3. 创建目标 PVC（ceph-rbd-sc）
4. helper Pod 同时挂载旧/新 PVC
5. tar 流式拷贝，保留 owner/permission
6. 设置目标根目录 group + setgid（如需要）
7. 修改 CR/Helm 的 volumeClaimTemplate 名称和 storageClassName
8. 启动，验证 API/数据/历史
9. 保留旧 PVC，观察 3–7 天
10. 清理旧 PVC 和孤儿 RBD 镜像
```

关键检查：

```bash
# Operator 实际使用的 PVC
kubectl -n monitoring get sts <sts> -o yaml | grep -A5 volumeClaimTemplates
kubectl -n monitoring get pod <pod> -o jsonpath='{range .spec.volumes[*]}{.name}={.persistentVolumeClaim.claimName}{"\n"}{end}'

# 目标 PVC 的 PV/镜像
kubectl -n monitoring get pvc <pvc> -o jsonpath='{.spec.volumeName}{"\n"}'
```

### 7.6 回滚说明（NFS 数据已清理）

2026-11-09 验证完成后，三个旧监控 NFS PVC 已删除，**NFS 回滚路径不再可用**。
下面的命令仅作为历史参考；直接执行会创建新的空 NFS PVC，不会恢复旧数据。

```bash
# 仅作参考：旧 NFS 数据已删除，执行后是空盘
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 --reuse-values \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.metadata.name=prometheus-db \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=nfs-sc \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.metadata.name=alertmanager-db \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=nfs-sc \
  --set grafana.persistence.existingClaim=prometheus-grafana \
  --set grafana.persistence.storageClassName=nfs-sc
```

如果确实需要回滚：

- Grafana：使用 `/root/k8s-postmortem/backup/grafana.db` 和 Dashboard JSON 恢复；
- Prometheus：从 TSDB 快照/备份恢复（本次没有保留 NFS 旧盘）；
- Alertmanager：配置在 Git/Helm values 中，数据本身只有 silences/通知状态，可重建。

> 结论：**Ceph 是唯一数据副本**。后续应给 `k8s-rbd` 增加快照/备份策略，避免单集群故障导致监控历史不可恢复。

### 7.7 旧 NFS 清理记录（已执行 2026-11-09）

清理前 `/data/nfs` 有 21 个目录，全部被 Bound PV 引用，没有孤儿目录。
本次按“两类都清理”执行：

1. **旧监控 NFS PVC（3 个）**

```bash
kubectl -n monitoring delete pvc \
  prometheus-prometheus-prometheus-db-prometheus-prometheus-prometheus-0 \
  alertmanager-prometheus-alertmanager-db-alertmanager-prometheus-alertmanager-0 \
  prometheus-grafana
```

- Prometheus/Alertmanager 的 `nfs-sc` PV 回收策略是 `Delete`，NFS 目录自动删除；
- Grafana 的 PV 是 `Retain`，手动删除 PV 和目录：

```bash
kubectl delete pv pvc-b5fb0054-d756-4f93-a756-2a75ef20fffb
rm -rf /data/nfs/monitoring-prometheus-grafana-pvc-b5fb0054-d756-4f93-a756-2a75ef20fffb
```

2. **Tekton 已完成/失败 PipelineRun（15 个）**

```bash
kubectl -n cicd delete pipelinerun --all
```

PipelineRun 删除后，其 ownerRef 级联删除 15 个 workspace PVC（2Gi/个）及 NFS 目录。
保留 `cicd/frpc-build-ctx`（无 ownerRef，是常驻构建上下文）。

清理结果：

```text
NFS 根盘：47G used -> 26G used（可用 43G -> 64G）
/data/nfs 目录：21 个 -> 3 个
剩余 NFS PVC：
  china-study-free/china-study-free-assets   8Gi
  china-study-free/china-study-free-reports  1Gi
  cicd/frpc-build-ctx                         2Gi
Released PV：无
```

> 注意：`frpc-build-ctx` 和 `china-study-free-*` 是当前业务 PVC，不要误删。

---

## 8. 踩坑清单

| # | 坑 | 根因 | 修复 |
|---|---|---|---|
| 1 | 新 PVC 名少一层 `prometheus` | `volumeClaimTemplate.name` 只是前缀 | 先查 Operator 实际 PVC 名，再拷贝 |
| 2 | Ceph 100% full / 所有挂载失败 | 3 副本 + 孤儿镜像 + 单 OSD full | 清孤儿镜像，确认 `MAX AVAIL > 0` |
| 3 | `Volume ID already exists` | CSI 重试与已删除 PVC 竞态 | 删除 Released PV/孤儿镜像，重启 Pod |
| 4 | `FailedAttachVolume` 跨节点 | RWO 卷旧 Pod/旧 attachment 未释放 | 确认旧 Pod 退出，force delete，必要时重启 kubelet |
| 5 | Pod 卡 `Init:0/1` | fsGroup 递归 chown 19.3G | `fsGroupChangePolicy: OnRootMismatch` + 根目录 setgid + 去掉 fsGroup |
| 6 | `segments are not sequential` | WAL 段缺失/多出 `00000000` | 从旧 PVC 重拷 `wal/`，删除失败启动产生的段 |
| 7 | worker02 NotReady / kubelet 僵尸 | RBD I/O D 状态 | `qm reset 123` 硬重启 |
| 8 | CNPG failover 卡住 | 主库节点 RBD I/O 卡死 | 节点恢复后 CNPG 自动完成 failover |
| 9 | Grafana Operator Dashboard False | Grafana 重启期间 Operator 连接失败 | 重启 Operator |
| 10 | Grafana 旧 PVC 消失 | Helm 删除 chart 管理的旧 PVC | 从 Released PV 恢复 PVC，PV 改 Retain |

---

## 9. 命令附录

### 9.1 关键对象

```text
Prometheus PVC:  prometheus-db-ceph-prometheus-prometheus-prometheus-0
Prometheus PV:   pvc-271e64b9-9e9b-46d9-9901-487a5927734c
Prometheus 镜像: csi-vol-e07faa22-d0f3-4275-8d1b-37040ced8ef7

Alertmanager PVC: alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0
Alertmanager PV:  pvc-6d3e4030-94a0-435b-b382-a6158e8caefd
Alertmanager 镜像: csi-vol-3b7c6f25-b13b-402c-8b36-2ec985ec081f

Grafana PVC:  prometheus-grafana-ceph
Grafana PV:   pvc-aebfac42-a961-4b21-9440-b175989ba2dc
Grafana 镜像: csi-vol-f34d561a-bbd3-4ba9-bc2e-ac07f2d0caed

旧 Prometheus PVC:  prometheus-prometheus-prometheus-db-prometheus-prometheus-prometheus-0
旧 Alertmanager PVC: alertmanager-prometheus-alertmanager-db-alertmanager-prometheus-alertmanager-0
旧 Grafana PVC:      prometheus-grafana（已恢复，PV pvc-b5fb0054...，Retain）
```

### 9.2 Ceph 检查

```bash
ceph -s
ceph df
ceph df detail | grep -E 'POOL|k8s-rbd'
ceph osd df tree
rbd -p k8s-rbd ls -l
```

### 9.3 Kubernetes 检查

```bash
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get pvc
kubectl get volumeattachment | grep pvc-
kubectl -n monitoring get prometheus prometheus-prometheus -o yaml
kubectl -n monitoring get alertmanager prometheus-alertmanager -o yaml
```

### 9.4 Helm 检查

```bash
helm -n monitoring history prometheus
helm -n monitoring get values prometheus -o yaml
helm -n monitoring get manifest prometheus | grep -A10 'kind: Prometheus'
```

---

## 10. 一句话总结

> 存储迁移本身是成功的：三个组件都跑在 Ceph RBD 上，历史数据完整；旧监控 NFS 数据已在验证后清理，后续回滚需依赖备份/快照。
> 真正的教训不是“Ceph 不能用”，而是 **迁移前必须确认目标 PVC 名称、Ceph `MAX AVAIL`、以及 fsGroup 行为**；
> 这三件事任何一个没确认，都可能把一次普通迁移变成集群级故障。
