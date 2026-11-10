# Prometheus 等组件存储：NFS → Ceph RBD 迁移可行性评估

> 日期：2026-11-09
> 集群：kubeadm v1.35.9，6 节点
> 当前存储：`nfs-sc`（单机 NFS，`10.0.0.1:/data/nfs`）
> 目标存储：`ceph-rbd-sc`（外部 Ceph，pool `k8s-rbd`）

---

## 0. 结论

| 问题 | 结论 |
|---|---|
| 能迁吗？ | **能**，目标 PVC 全是 RWO，Ceph RBD 支持 |
| 值得迁吗？ | **值得**，NFS 是单机 SPOF，Ceph 有副本/Retain/更好随机 I/O |
| 数据量大吗？ | 不大：Prometheus 19.2G + Alertmanager 12K + Grafana 53M ≈ **19.3G** |
| 最大风险 | Prometheus Operator 的 STS/PVC 重建、Ceph pool 容量、迁移窗口 |
| 推荐顺序 | **Grafana → Alertmanager → Prometheus**，先小后大 |
| 不建议迁 | CI 的临时 workspace PVC（`cicd/pvc-*`） |

---

## 1. 当前 NFS 现状

| 项 | 值 |
|---|---|
| NFS Server | `10.0.0.1` |
| NFS Path | `/data/nfs` |
| Provisioner | `nfs-subdir-external-provisioner` |
| StorageClass | `nfs-sc` |
| ReclaimPolicy | **Delete** |
| 单点风险 | **是**，NFS 服务端是单机 |

### 1.1 使用 `nfs-sc` 的 PVC

| Component | PVC | Size | Used | Access | 说明 |
|---|---|---|---:|---|---|
| Prometheus | `prometheus-prometheus-prometheus-db-...-0` | 100Gi | **19.2G** | RWO | TSDB |
| Alertmanager | `alertmanager-prometheus-alertmanager-db-...-0` | 20Gi | **12K** | RWO | silences/nflog |
| Grafana | `prometheus-grafana` | 10Gi | **53M** | RWO | SQLite + 用户/偏好 |
| china-study-free | `china-study-free-assets` | 8Gi | — | RWO | 业务附件 |
| china-study-free | `china-study-free-reports` | 1Gi | — | RWO | 业务报表 |
| cicd | `frpc-build-ctx` + `pvc-*` × 15 | 2Gi each | — | RWO | Tekton 临时 workspace |
| monitoring | `prometheus-grafana` | 10Gi | 53M | RWO | 同上 |

> 前三项是本次评估的重点。

---

## 2. Ceph RBD 侧能力与限制

| 项 | 值 |
|---|---|
| StorageClass | `ceph-rbd-sc` |
| Provisioner | `rbd.csi.ceph.com` |
| Pool | `k8s-rbd` |
| ReclaimPolicy | **Retain** |
| VolumeBindingMode | `Immediate` |
| CSI 版本 | cephcsi **v3.16.2** |
| Monitors | `10.0.0.31:6789`、`10.0.0.41:6789`、`10.0.0.51:6789` |
| NodePlugin | 3 个 worker 全有 |
| 现有 PVC | 33 个，含 CNPG/Kafka/Loki/n8n 等 |
| 访问模式 | **RWO**（RBD 块设备） |
| CephFS | **未安装** |
| VolumeSnapshot CRD | **未安装**（CSI 里有 csi-snapshotter，但集群没有 snapshot controller/CRD） |

### 2.1 关键限制

1. **RBD 只支持 RWO**。
   - 本次目标组件都是单副本 RWO，**没问题**；
   - 如果未来要做多 Pod 共享同一卷（RWX），需要 **CephFS**，当前没装。
2. **没有 VolumeSnapshot CRD**。
   - 迁移后如果想要快照备份，需要额外安装 snapshot controller + CRD + `VolumeSnapshotClass`；
   - 不装也能迁移，只是没有快照能力。
3. **Ceph pool 容量需要确认**。
   - 当前实际数据约 19.3G，但 Prometheus 新 PVC 逻辑大小 100Gi（thin provisioning）；
   - 需要 Ceph 管理员确认 `k8s-rbd` 剩余空间 > 30–40G。
4. **CSI 组件有重启记录**。
   - nodeplugin 33 天重启 12–14 次；
   - provisioner 80 分钟前重启 5 次；
   - 当前无 error 日志，但迁移前应确认 Ceph 健康、mon 连通性。

---

## 3. 可行性判断

| 组件 | 迁移可行性 | 原因 |
|---|---|---|
| **Grafana** | ✅ 高 | 10Gi / 53M，单副本 RWO，Helm `existingClaim` 可切 |
| **Alertmanager** | ✅ 高 | 20Gi / 12K，单副本 RWO，数据极小 |
| **Prometheus** | ✅ 中高 | 100Gi / 19.2G，单副本 RWO；需要处理 Prometheus Operator 的 STS/PVC 重建 |
| china-study-free assets/reports | ✅ 中 | 业务 PVC，需要停应用 + 改 GitOps 里的 claimName |
| cicd `pvc-*` | ⚠️ 不建议 | Tekton 临时 workspace，迁了意义不大；新 workspace 直接用 `ceph-rbd-sc` 即可 |

**总体：可行，推荐迁移监控三件套；CI 临时卷不迁。**

---

## 4. 收益 vs 代价

### 收益

| 收益 | 说明 |
|---|---|
| 消除 NFS 单点 | NFS 是 `10.0.0.1` 单机；Ceph 有副本 |
| 更好随机 I/O | Prometheus TSDB 写入更适合块存储 |
| Retain 策略 | `ceph-rbd-sc` 是 Retain，误删 PVC 不会立刻丢 PV |
| 统一存储 | 与 CNPG/Kafka/Loki 一致，运维模型统一 |
| 可扩展 | `allowVolumeExpansion: true` |
| 未来可加快照 | 装 snapshot controller 后可做 RBD 快照 |

### 代价/风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 迁移停机 | Prometheus/Alertmanager/Grafana 需停止 | 维护窗口 |
| 数据拷贝 | ~19.3G，NFS → RBD | `rsync -a`，预计几分钟 |
| Prometheus Operator 重建 | `volumeClaimTemplate` 变更会重建 STS | 预创建新 PVC + 新 template 名 |
| Grafana Helm PVC | 不能原地改 SC | 预创建新 PVC + `existingClaim` |
| 权限 | Prometheus/AM 是 UID 1000:2000，Grafana 是 472 | `rsync -a` 保留 UID/GID |
| Ceph 容量 | 需确认 pool 余量 | Ceph 管理员 `ceph df` |
| Ceph CSI 稳定性 | 有重启记录 | 迁移前查日志/健康 |
| 旧 NFS PV Delete | `nfs-sc` 是 Delete | 验证前不要删旧 PVC |

---

## 5. 迁移方案

### 5.1 预检查（必须先做）

```bash
# 1. Ceph 容量（需要 Ceph 管理员或在有 keyring 的环境执行）
ceph df
ceph -s

# 2. 确认 k8s-rbd pool 剩余 > 30G
# 3. 确认 CSI 无 error
kubectl -n ceph-csi-rbd logs deploy/ceph-csi-rbd-provisioner -c csi-provisioner --tail=100
kubectl -n ceph-csi-rbd logs ds/ceph-csi-rbd-nodeplugin --tail=100

# 4. 建一个 20Gi 测试 PVC，确认能 provision/mount/写
# 5. 如需快照：安装 snapshot controller + CRD + VolumeSnapshotClass
```

### 5.2 Grafana（先做，最小）

```bash
# 1. 停 Grafana
kubectl -n monitoring scale deploy/prometheus-grafana --replicas=0

# 2. 创建新 PVC
cat <<'EOF' | kubectl apply -f -
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
EOF

# 3. helper pod 同时挂旧/新 PVC，rsync
#    old: prometheus-grafana (nfs-sc)
#    new: prometheus-grafana-ceph (ceph-rbd-sc)
#    在 helper 里执行：rsync -a /old/ /new/

# 4. 改 Helm values
helm -n monitoring upgrade prometheus prometheus-community/kube-prometheus-stack \
  --version 83.7.0 --reuse-values \
  --set grafana.persistence.existingClaim=prometheus-grafana-ceph

# 5. 启动并验证
kubectl -n monitoring rollout status deploy/prometheus-grafana
# 登录 Grafana，确认 datasource/dashboard/用户正常
```

> 旧 PVC `prometheus-grafana` 先保留，验证 1–2 周后再删。

### 5.3 Alertmanager

```bash
# 1. 缩到 0
kubectl -n monitoring patch alertmanager prometheus-alertmanager \
  --type merge -p '{"spec":{"replicas":0}}'

# 2. 预创建新 PVC（名字按新 template 规则）
#    新 template 名：alertmanager-db-ceph
#    PVC：alertmanager-db-ceph-alertmanager-prometheus-alertmanager-0
#    20Gi，ceph-rbd-sc

# 3. helper pod rsync 旧 -> 新
#    旧：alertmanager-prometheus-alertmanager-db-...-0
#    新：alertmanager-db-ceph-...-0

# 4. 改 Alertmanager CR
#    spec.storage.volumeClaimTemplate.metadata.name: alertmanager-db-ceph
#    spec.storage.volumeClaimTemplate.spec.storageClassName: ceph-rbd-sc
#    spec.replicas: 1

# 5. 验证 silences/config
```

> Alertmanager 数据只有 12K，如果不想折腾，也可以直接空卷启动（会丢 silences，影响很小）。

### 5.4 Prometheus（最后做，数据最大）

```bash
# 1. 缩到 0，等待干净关闭
kubectl -n monitoring patch prometheus prometheus-prometheus \
  --type merge -p '{"spec":{"replicas":0}}'

# 2. 预创建新 PVC
#    新 template 名：prometheus-db-ceph
#    PVC：prometheus-db-ceph-prometheus-prometheus-0
#    100Gi，ceph-rbd-sc

# 3. helper pod 同时挂旧/新 PVC
#    rsync -a /old/ /new/
#    保留 UID/GID（Prometheus 是 1000:2000）
#    删除旧数据里的 lock 文件（如果有）：/new/lock

# 4. 改 Prometheus CR
#    spec.storage.volumeClaimTemplate.metadata.name: prometheus-db-ceph
#    spec.storage.volumeClaimTemplate.spec.storageClassName: ceph-rbd-sc
#    spec.replicas: 1

# 5. 验证
kubectl -n monitoring get prometheus,sts,pvc
kubectl -n monitoring exec prometheus-prometheus-prometheus-0 -c prometheus -- \
  promtool tsdb analyze /prometheus 2>/dev/null | head
# 检查 targets、TSDB、retention
```

> Prometheus Operator 对 STS 的 `volumeClaimTemplates` 是重建行为；**务必先在测试 namespace 做一次 POC**，确认预创建 PVC 能被新 STS 复用。

### 5.5 业务 PVC（可选，后面再做）

- `china-study-free-assets` 8Gi、`china-study-free-reports` 1Gi；
- 需要停应用 → 建新 PVC → rsync → 改 GitOps 里的 `claimName` → 启动；
- 与监控迁移分开做。

### 5.6 CI workspace PVC（不建议迁）

- `cicd/pvc-*` 是 Tekton 临时 workspace；
- 新 Pipeline 的 `volumeClaimTemplate` 直接用 `ceph-rbd-sc` 即可；
- 旧 PVC 可以在确认无引用后清理。

---

## 6. 回滚

- 迁移前 **不要删除旧 NFS PVC**；
- 如果新 PVC 启动失败：
  1. 把 CR/Helm 改回旧 PVC/旧 SC；
  2. 重新启动原组件；
  3. 旧数据仍在 NFS；
- 旧 PVC 保留 1–2 周，确认无误后再删；
- 注意 `nfs-sc` 是 **Delete**，删 PVC 会删 NFS PV 数据，清理前务必确认。

---

## 7. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| Ceph pool 容量不足 | 高 | 迁移前 `ceph df` 确认 > 30G |
| Prometheus Operator 不按预期复用预创建 PVC | 中高 | 先在测试 namespace POC |
| Grafana Helm 尝试替换 PVC | 中 | 用 `persistence.existingClaim` |
| 数据拷贝权限错误 | 中 | `rsync -a` 保留 UID/GID；检查 fsGroup |
| 迁移窗口内告警中断 | 中 | 维护窗口，提前通知 |
| Ceph CSI 重启/健康问题 | 中 | 迁移前查日志、Ceph 健康 |
| 旧 NFS PVC 误删 | 中 | 保留 1–2 周，确认后再删 |
| RBD 只支持 RWO | 低 | 目标组件都是单副本 RWO |
| 没有快照 | 低 | 可选安装 snapshot controller |

---

## 8. 推荐执行顺序与窗口

| 阶段 | 内容 | 预计 |
|---|---|---|
| 0 | Ceph 容量/健康检查 + 20Gi 测试 PVC | 30 分钟 |
| 1 | Grafana 迁移 | 30 分钟 |
| 2 | Alertmanager 迁移 | 20 分钟 |
| 3 | Prometheus 迁移（19.2G 拷贝） | 30–60 分钟 |
| 4 | 验证 + 观察 | 1 天 |
| 5 | 清理旧 NFS PVC（1–2 周后） | — |

总维护窗口建议：**2–3 小时**。

---

## 9. 最终建议

1. **迁移监控三件套（Prometheus / Alertmanager / Grafana）是值得的**：
   - 数据量小（19.3G）；
   - 目标全是 RWO；
   - Ceph 比单机 NFS 更可靠；
   - 统一存储模型。
2. **先 Grafana，再 Alertmanager，最后 Prometheus**，先小后大。
3. **迁移前必须确认 Ceph pool 容量和 CSI 健康**，并做一次 20Gi 测试 PVC。
4. **Prometheus Operator 的 STS 重建行为要先 POC**，不要直接在 prod 上试。
5. **旧 NFS PVC 保留 1–2 周**，不要急着删。
6. **CI 临时 PVC 不迁**；业务 PVC 单独安排。
7. 如果后续需要快照备份，再安装 snapshot controller + `VolumeSnapshotClass`。

---

## 10. 一句话

> **可行、值得、数据量小；主要风险在 Prometheus Operator 的 PVC/STS 重建和 Ceph pool 容量。按 Grafana → Alertmanager → Prometheus 的顺序，在维护窗口内做，旧 PVC 保留回滚即可。**
