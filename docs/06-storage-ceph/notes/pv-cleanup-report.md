# Kubernetes 失效 PV 清理 — 完整步骤与执行报告

> **执行日期**：2026-10-06
> **集群上下文**：`kubernetes-admin@kubernetes`
> **客户端版本**：kubectl v1.35.9
> **执行结果**：✅ 成功删除 **10 个失效 PV（95Gi）**，清理后集群剩余 **18 个 PV 全部 Bound 且健康**（2026-10-05 当时快照；2026-11-11 复核 17 个）

---

## 1. 背景与判定标准

一个 PV 属于「失效无用」需要**同时**满足以下条件：

| # | 条件 | 说明 |
|---|------|------|
| ① | `status.phase = Released` 或 `Failed` | PVC 已被删除，PV 已释放，**永远不会重新绑定** |
| ② | `spec.claimRef` 指向的 PVC 不存在（或已被新 PV 占用） | 即使同名 PVC 存在，其绑定的也是**新 PV**，旧 PV 的 claimRef 里固化了旧 UID，无法回绑 |
| ③ | 无任何 Pod / 工作负载在使用 | Released 状态本身已保证没有 Pod 挂载 |

**不满足上述条件的 PV 一律保留**（尤其是 `Bound` 状态的，删了会导致数据卷脱挂载）。

### 集群 PV 状态分布（清理前）

```
28 个 PV 总计
├── 18 个  Bound     ← 正常在用，保留
└── 10 个  Released  ← 失效垃圾，本次清理目标
      ├── 9 个 ceph-rbd-sc（Retain 策略）
      └── 1 个 nfs-sc     （Retain 策略）
```

### 失效 PV 清单（10 个，共 95Gi）

| PV | 容量 | StorageClass | 原 claimRef | 状态 |
|---|---|---|---|---|
| `pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-3baa45e6-2064-4817-8eef-dbc2d64d90a7` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-438afc60-2ec7-4d18-97f5-40a1b9934e80` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-5046dd85-3c71-4625-8e12-81ec785fd00f` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-e4e45b3b-2338-4919-a5c1-cf71c0aea6c5` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-77c2a7cb-a7dd-4487-a35c-cc9868e91979` | 10Gi | ceph-rbd-sc | logging/data-loki-write-0 | Released |
| `pvc-ac2ccc31-af11-4c53-9e33-0df94e72bd44` | 10Gi | ceph-rbd-sc | logging/data-loki-backend-0 | Released |
| `pvc-28b685a9-f530-4a0b-ace6-c8f4091ab8cf` | 10Gi | ceph-rbd-sc | cnpg-system/pg16-ceph-2 | Released |
| `pvc-c6bcf716-11ff-48e8-85fc-8a2691382326` | 5Gi | ceph-rbd-sc | cnpg-system/pg16-ceph-2-wal | Released |
| `pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd` | 10Gi | nfs-sc | default/test-pvc | Released |

> **典型案例**：Loki 的 `data-loki-backend-0` PVC 曾被删除重建，新 PVC 绑定到了**新 PV**（`pvc-5dc9836b...`），
> 而 6 个旧 PV 的 claimRef 中固化的还是**旧 UID**，因此永远无法回绑 —— 是典型的「失效残留」。
> `cnpg-system/pg16-ceph-2` 则是该 PostgreSQL 实例已下线（现存实例为 pg16-ceph-3 / pg16-ceph-4）。

---

## 2. 第一步：盘点与识别

### 2.1 查看所有 PV 及其状态

```bash
kubectl get pv -o wide
# 按状态汇总数量
kubectl get pv --no-headers | awk '{print $5}' | sort | uniq -c
```

### 2.2 列出所有现存 PVC

```bash
kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' | sort -u
```

### 2.3 自动识别失效 PV（核心脚本）

```bash
# 生成现存 PVC 列表
kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' | sort -u > /tmp/existing_pvc.txt

# 逐条判定：非 Bound 的都是垃圾；Bound 但 PVC 已消失的是异常
kubectl get pv --no-headers | awk '{print $1"|"$2"|"$5"|"$6}' | \
while IFS='|' read -r name cap status claim; do
  if [ "$status" = "Bound" ]; then
    if grep -q "^${claim}$" /tmp/existing_pvc.txt; then
      echo "KEEP   $name  $status  $claim"
    else
      echo "BAD    $name  $status 但PVC不存在  $claim"
    fi
  else
    echo "JUNK   $name  $status  claim=$claim"
  fi
done
```

**本次输出**：18 行 `KEEP`，10 行 `JUNK`（全部 `Released`），0 行 `BAD`。

---

## 3. 第二步：备份（必做！）

删除前**必须**先导出 YAML，以便误删时回滚：

```bash
BK=/tmp/opencode/pv-backup
mkdir -p "$BK"

# 全量备份
kubectl get pv -o yaml > "$BK/all-pv-$(date +%Y%m%d-%H%M%S).yaml"

# 生成待删清单
kubectl get pv --no-headers | awk '$5=="Released"{print $1}' > "$BK/junk-pv.txt"

# 逐个备份
while read pv; do
  kubectl get pv "$pv" -o yaml > "$BK/${pv}.yaml"
done < "$BK/junk-pv.txt"

ls -la "$BK"
```

本次备份位置：`/tmp/opencode/pv-backup/`（含全量 YAML + 10 个单体 YAML + 待删清单）。

---

## 4. 第三步：删除前安全校验

**关键一步**：确认待删 PV 没有被任何 PVC 引用，全部计数必须为 `0`：

```bash
while read pv; do
  n=$(kubectl get pvc --all-namespaces -o json | grep -c "\"$pv\"" || true)
  echo "$pv -> 被PVC引用次数: $n"
done < /tmp/opencode/pv-backup/junk-pv.txt
```

**本次结果：10 个 PV 全部为 `0`，校验通过。**

再确认一次没有工作负载受影响：

```bash
# 应无输出
kubectl get pods -A --no-headers | grep -iE 'Error|CrashLoop|Pending' 
```

---

## 5. 第四步：执行删除

> ⚠️ **为什么是安全的**：这些 PV 的 `persistentVolumeReclaimPolicy` 均为 **`Retain`**，
> 删除 PV **K8s 对象**不会触碰底层 Ceph RBD 镜像 / NFS 目录，数据仍然完好保留（详见第 7 节）。

```bash
while read pv; do
  kubectl delete pv "$pv" --wait=false
done < /tmp/opencode/pv-backup/junk-pv.txt

# 等待并确认删除完成
sleep 5
kubectl get pv --no-headers | wc -l   # 期望输出 18
```

**本次输出**（10/10 全部成功）：

```
persistentvolume "pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f" deleted
persistentvolume "pvc-28b685a9-f530-4a0b-ace6-c8f4091ab8cf" deleted
persistentvolume "pvc-3baa45e6-2064-4817-8eef-dbc2d64d90a7" deleted
persistentvolume "pvc-438afc60-2ec7-4d18-97f5-40a1b9934e80" deleted
persistentvolume "pvc-5046dd85-3c71-4625-8e12-81ec785fd00f" deleted
persistentvolume "pvc-77c2a7cb-a7dd-4487-a35c-cc9868e91979" deleted
persistentvolume "pvc-ac2ccc31-af11-4c53-9e33-0df94e72bd44" deleted
persistentvolume "pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd" deleted
persistentvolume "pvc-c6bcf716-11ff-48e8-85fc-8a2691382326" deleted
persistentvolume "pvc-e4e45b3b-2338-4919-a5c1-cf71c0aea6c5" deleted
```

### 如果删除卡住（存在 finalizer 未清理）

```bash
# 查看是否卡在 Terminating
kubectl get pv | grep Terminating

# 仅在确认安全后备份并移除 finalizer
kubectl get pv <name> -o yaml > /tmp/<name>.yaml
kubectl patch pv <name> -p '{"metadata":{"finalizers":null}}'
```

---

## 6. 第五步：删除后验证

```bash
# 1) 状态分布：应全部为 Bound
kubectl get pv --no-headers | awk '{print $5}' | sort | uniq -c
# 输出：  18 Bound

# 2) 每个 Bound PV 都必须有对应的活 PVC（无输出 = 全部正常）
kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' | sort -u > /tmp/after_pvc.txt
kubectl get pv --no-headers | awk '{print $6}' | sort -u | while read c; do
  grep -q "^$c$" /tmp/after_pvc.txt || echo "MISSING PVC: $c"
done

# 3) 业务负载健康检查
kubectl get pods -A --no-headers | grep -vE 'Running|Completed' 
```

**本次验证结果**：
- ✅ 18/18 PV 全部 `Bound`
- ✅ 所有 Bound PV 均有对应的活 PVC（0 缺失）
- ✅ 业务 Pod 全部正常（Loki、CNPG、Prometheus、Kafka、n8n、Tekton 等存储挂载无异常）
- ⚠️ `kube-system` 下 6 个 `kube-proxy` 处于 `CreateContainerError` —— 属于**既有的容器运行时问题，与本次 PV 清理无关**（清理前即存在）

---

## 7. 第六步（可选）：清理底层存储数据

PV 对象删了，但 `Retain` 策略下底层数据**仍占用空间**。确认这些数据不再需要后，可做深度清理：

### 7.1 已删除 PV 对应的底层数据位置

| PV | 容量 | 底层数据位置 |
|---|---|---|
| `pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f` | 10Gi | RBD 镜像 `csi-vol-543be5ab-8bbf-46d7-a5d3-6bf81cbdb736` @ pool `k8s-rbd` |
| `pvc-28b685a9-f530-4a0b-ace6-c8f4091ab8cf` | 10Gi | RBD 镜像 `csi-vol-554bcd63-61e2-47f3-91b8-1b48259c28a1` @ pool `k8s-rbd` |
| `pvc-3baa45e6-2064-4817-8eef-dbc2d64d90a7` | 10Gi | RBD 镜像 `csi-vol-38df406d-6de2-493a-9e12-1940e7a5c24b` @ pool `k8s-rbd` |
| `pvc-438afc60-2ec7-4d18-97f5-40a1b9934e80` | 10Gi | RBD 镜像 `csi-vol-2b7f06b9-da7d-473d-b7c4-4f8002a06141` @ pool `k8s-rbd` |
| `pvc-5046dd85-3c71-4625-8e12-81ec785fd00f` | 10Gi | RBD 镜像 `csi-vol-da2dad7d-6b85-43a1-bbc2-bc238f53eeee` @ pool `k8s-rbd` |
| `pvc-77c2a7cb-a7dd-4487-a35c-cc9868e91979` | 10Gi | RBD 镜像 `csi-vol-34935be4-ea1d-4d8b-8668-a2fd3111678a` @ pool `k8s-rbd` |
| `pvc-ac2ccc31-af11-4c53-9e33-0df94e72bd44` | 10Gi | RBD 镜像 `csi-vol-92d1adea-2df0-46e6-b3ef-22471b737056` @ pool `k8s-rbd` |
| `pvc-c6bcf716-11ff-48e8-85fc-8a2691382326` | 5Gi | RBD 镜像 `csi-vol-85352ea6-baf7-4c87-a439-d296f4592985` @ pool `k8s-rbd` |
| `pvc-e4e45b3b-2338-4919-a5c1-cf71c0aea6c5` | 10Gi | RBD 镜像 `csi-vol-465fa860-90c1-43b2-b045-c099f86e0989` @ pool `k8s-rbd` |
| `pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd` | 10Gi | NFS 导出 `/data/nfs/default-test-pvc-pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd` @ `10.0.0.1` |

### 7.2 删除 RBD 镜像（共 9 个，85Gi）

在有 `ceph`/`rbd` CLI 的节点或容器内执行：

```bash
# 先确认镜像列表
rbd ls -p k8s-rbd | grep csi-vol-

# 逐个确认后删除（建议先核对 imageName 与上表一致）
rbd rm k8s-rbd/csi-vol-543be5ab-8bbf-46d7-a5d3-6bf81cbdb736
rbd rm k8s-rbd/csi-vol-554bcd63-61e2-47f3-91b8-1b48259c28a1
rbd rm k8s-rbd/csi-vol-38df406d-6de2-493a-9e12-1940e7a5c24b
rbd rm k8s-rbd/csi-vol-2b7f06b9-da7d-473d-b7c4-4f8002a06141
rbd rm k8s-rbd/csi-vol-da2dad7d-6b85-43a1-bbc2-bc238f53eeee
rbd rm k8s-rbd/csi-vol-34935be4-ea1d-4d8b-8668-a2fd3111678a
rbd rm k8s-rbd/csi-vol-92d1adea-2df0-46e6-b3ef-22471b737056
rbd rm k8s-rbd/csi-vol-85352ea6-baf7-4c87-a439-d296f4592985
rbd rm k8s-rbd/csi-vol-465fa860-90c1-43b2-b045-c099f86e0989
```

无本机 CLI 时可临时进 provisioner Pod：

```bash
kubectl exec -n ceph-csi-rbd deploy/ceph-csi-rbd-provisioner -c csi-rbdplugin -- \
  rbd ls -p k8s-rbd
```

> ⚠️ **RBD 镜像删除不可逆**，执行前请再三确认这些 Loki / CNPG 旧实例数据确实不再需要。
> 也可以先 `rbd snap ls` / 导出镜像做归档，观察一段时间再删。

### 7.3 清理 NFS 目录（10Gi）

```bash
ssh root@10.0.0.1
ls -ld /data/nfs/default-test-pvc-pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd
# 确认无误后再删
rm -rf /data/nfs/default-test-pvc-pvc-acf5c152-a627-4a94-9295-d2ddc115b2cd
```

---

## 8. 回滚 / 恢复方法

若误删，用第 3 节的备份恢复：

```bash
kubectl apply -f /tmp/opencode/pv-backup/pvc-1eaaa4c3-83c1-41e0-9e9b-24def179b98f.yaml
# 或恢复全量
kubectl apply -f /tmp/opencode/pv-backup/all-pv-20261006-152715.yaml
```

因底层数据未删，恢复 PV 对象后卷内容完整无损。

---

## 9. 预防措施（避免再次堆积）

### 9.1 定期巡检脚本

```bash
#!/usr/bin/env bash
# pv-gc-check.sh — 只报告，不删除
set -euo pipefail

kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' | sort -u > /tmp/.pvc_now.txt

echo "== 非 Bound 的 PV（失效残留）=="
kubectl get pv --no-headers | awk '$5!="Bound"{printf "  %-45s %-10s %s\n", $1, $5, $6}'

echo "== Bound 但 PVC 已消失的 PV（异常）=="
kubectl get pv --no-headers | awk '$5=="Bound"{print $1"|" $6}' | \
while IFS='|' read -r pv claim; do
  grep -q "^${claim}$" /tmp/.pvc_now.txt || echo "  $pv -> $claim"
done

echo "== Failed 状态 PV =="
kubectl get pv --no-headers | awk '$5=="Failed"{print "  "$1}'
```

### 9.2 建议

| 措施 | 说明 |
|---|---|
| **按需改用 `Delete` 回收策略** | 对临时/测试 PVC 用 `Delete`，PV 删除时自动清底层数据，不会堆积 |
| **StatefulSet 用完即删 PVC** | Loki / CNPG 这类实例下线时，**连同 PVC 一起删**，否则 Retain 的 PV 必然残留 |
| **定期跑巡检脚本** | 建议加入 CronJob 或运维周报，及时发现 Released / Failed PV |
| **删除前永远先备份 YAML** | `kubectl get pv <name> -o yaml > backup.yaml` 一条命令的成本，换完全可回滚 |
| **底层数据清理需单独评审** | RBD 镜像 / NFS 目录删除不可逆，应与 PV 对象清理分开授权执行 |

---

## 10. 执行结果汇总

| 项目 | 结果 |
|---|---|
| 清理前 PV 总数 | 28（18 Bound + 10 Released） |
| 本次删除 | **10 个 Released PV，共 95Gi**（9 个 ceph-rbd 85Gi + 1 个 NFS 10Gi） |
| 清理后 PV 总数 | **18，全部 Bound**（当时快照；2026-11-11 为 17） |
| YAML 备份 | ✅ `/tmp/opencode/pv-backup/`（11 个文件） |
| 安全校验 | ✅ 删除前 0 引用，删除后 PVC 全在、Pod 全正常 |
| 底层数据 | ⏸ 保留未删（Retain 策略），待人工评审后再做第 7 节深度清理 |
| 回滚能力 | ✅ 可用备份一键 `kubectl apply` 恢复 |

---

## 附录：本次使用的完整命令序列

```bash
# ---- 1. 盘点 ----
kubectl get pv -o wide
kubectl get pv --no-headers | awk '{print $5}' | sort | uniq -c
kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' | sort -u

# ---- 2. 识别失效 PV ----
kubectl get pv --no-headers | awk '$5!="Bound"{print $1}'

# ---- 3. 备份 ----
BK=/tmp/opencode/pv-backup; mkdir -p "$BK"
kubectl get pv -o yaml > "$BK/all-pv-$(date +%Y%m%d-%H%M%S).yaml"
kubectl get pv --no-headers | awk '$5=="Released"{print $1}' > "$BK/junk-pv.txt"
while read pv; do kubectl get pv "$pv" -o yaml > "$BK/${pv}.yaml"; done < "$BK/junk-pv.txt"

# ---- 4. 安全校验（必须全 0）----
while read pv; do
  kubectl get pvc -A -o json | grep -c "\"$pv\"" || true
done < "$BK/junk-pv.txt"

# ---- 5. 删除 ----
while read pv; do kubectl delete pv "$pv" --wait=false; done < "$BK/junk-pv.txt"
sleep 5; kubectl get pv --no-headers | wc -l    # 期望 18

# ---- 6. 验证 ----
kubectl get pv --no-headers | awk '{print $5}' | sort | uniq -c   # 期望 18 Bound
kubectl get pods -A --no-headers | grep -vE 'Running|Completed'
```
