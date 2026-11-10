# kube-apiserver 内存治理执行记录

> 日期：2026-11-09  
> 集群：Kubernetes v1.35.9，3 control-plane + 3 worker  
> 目标：按《apiserver-memory-analysis-20261109.md》的建议，降低 apiserver 内存/减少 API 面，并记录全过程  
> 结论：**清理 Helm 历史有效；CRD 清理大部分被 Traefik ArgoCD app 回滚；apiserver 滚动重启只临时重置/重新分布 watch，不能永久降低总内存。最终仍建议加内存 + 减少 watch/operator。**

---

## 0. 执行摘要

| 动作 | 结果 |
|---|---|
| 清理 23 个未使用 CRD | 2 个 policy CRD 删除成功；21 个 Hub/Gateway CRD 被 `platform-traefik` ArgoCD app 重新创建；最终 146 个 CRD |
| 清理 Helm release 历史 | 36 → 22 个 release secret，14.45MB → 7.85MB（释放约 6.6MB） |
| apiserver 滚动重启 | master01 → master02 → m01，均 10s 内恢复；watch 分布临时变化后重新收敛 |
| `--target-ram-mb` | **1.35.9 已不存在该参数**，未设置 |
| `--watch-cache-sizes` | 1.35.9 中非零值等价于“启用 watch cache”，不能调大小；未设置 |
| 每实例监控 | 已存在 `prometheus-apiserver` ServiceMonitor，三个实例均 `up=1`，无需改动 |
| 最终健康 | 6/6 节点 Ready，所有 Pod Running/Completed，`/readyz ok` |

---

## 1. 基线（执行前）

### 1.1 每实例 watch / 内存

| 实例 | WATCH | goroutines | heap inuse | RSS | `kubectl top` |
|---|---:|---:|---:|---:|---:|
| m01 (10.0.0.61) | 72 | 2,454 | 579MiB | 850MiB | 970Mi |
| master01 (10.0.0.121) | 641 | 7,396 | 1,377MiB | 1.66GiB | 1499Mi |
| master02 (10.0.0.120) | 608 | 6,064 | 993MiB | 1.55GiB | 1080Mi |

### 1.2 API 面

```text
CRD: 148
OpenAPI v2: 13,329,705 bytes
对象总数: 4,638
Events: 1,945
Secrets: 125 / 14.6MB（Helm release secret 36 个 / 14.45MB）
ConfigMaps: 152 / 0.85MB
Helm release secret: 36
Webhook 配置: 21
聚合 APIService: 1
```

### 1.3 关键结论回顾

- 不是泄漏；内存随 watch 数、CRD/OpenAPI、对象缓存增长。
- 三个实例 watch 分布严重不均：m01 72，master01/02 600+。
- 1.35.9 的 `--target-ram-mb` 不存在；`--watch-cache-sizes` 只能通过 `0` 禁用缓存，非零值不改变大小。
- 每实例监控已经存在（`prometheus-apiserver`），三个实例都被 Prometheus 抓取。

---

## 2. 执行步骤

### 2.1 备份

目录：`/root/apiserver-remediation-20261109/`

```text
crds-to-remove.txt                  # 计划删除的 23 个 CRD
crds-removed-backup.yaml            # 23 个 CRD 的完整 YAML 备份
helm-release-secrets-backup.yaml    # 所有 Helm release secret 备份（14MB）
helm-secrets-deleted.txt            # 实际删除的 14 个 secret 列表
restart-apiserver.sh                # 本次使用的滚动重启脚本
```

### 2.2 CRD 清理（23 个候选）

候选：

```text
15 × hub.traefik.io
 6 × gateway.networking.k8s.io
 2 × policy.networking.k8s.io
```

删除前确认：

- 所有候选 CR 数量为 0；
- 没有 Hub controller；
- Cilium/Traefik 未使用 Gateway API。

执行：

```bash
kubectl get crd $(cat crds-to-remove.txt) -o yaml > crds-removed-backup.yaml
kubectl delete crd $(cat crds-to-remove.txt) --timeout=180s
```

删除后：

```text
CRD: 148 -> 125
OpenAPI v2: 13,329,705 -> 12,299,266 bytes
```

**但约 1–2 分钟后，21 个 CRD 被重新创建：**

```text
15 × hub.traefik.io
 6 × gateway.networking.k8s.io
```

原因：

- `platform-traefik` ArgoCD Application 管理 Traefik chart 42.3.1；
- Traefik chart 的 `crds/` 目录包含 Hub CRD 和 `gateway-standard-install.yaml`；
- `platform-traefik` 配置了 `automated.selfHeal: true`，删除后再次 sync 会重建；
- Chart 模板还包含 `gateway.yaml`、`gatewayclass.yaml`、`hub-admission-controller.yaml`。

最终：

```text
CRD: 146（148 - 2 个 policy CRD）
OpenAPI v2: 13,231,606 bytes（仅减少约 98KB）
```

> 结论：这 21 个 CRD 属于 Traefik chart 的一部分，不是“孤儿 CRD”。  
> 要永久移除，需要修改 `platform-traefik` app（`helm.skipCrds: true` 并关闭 Hub/Gateway），属于 ingress 变更；本次未做，因为收益很小（约 1MB OpenAPI）且可能影响 Traefik。

### 2.3 Helm history 清理

36 个 release secret / 14.45MB。保留每个 release 最新 3 个 revision，删除更旧的。

执行结果：

```text
argocd:       revisions [6,8,9,10,11,12,13,14] -> keep [12,13,14]
cilium:       revisions [1,2,3,4] -> keep [2,3,4]
tempo3:       revisions [1..6] -> keep [4,5,6]
prometheus:   revisions [1..8] -> keep [6,7,8]
alloy/loki:   各 3 个，全部保留
cert-manager/vpa/otel-operator: 少于 3 个，全部保留
```

结果：

```text
Helm release secrets: 36 -> 22
数据量: 14,449,640 -> 7,851,872 bytes（释放约 6.6MB）
```

验证：

```bash
helm list -A                 # 所有 release 仍 deployed
helm -n argocd history argocd
helm -n logging history loki
```

> 说明：Traefik 已迁移到 ArgoCD `platform-traefik`，不再有 Helm release secret；本次清理没有涉及 Traefik（删除列表里没有 traefik group）。

### 2.4 apiserver 滚动重启

目的：

- 重置各实例内存；
- 观察 watch 是否能重新分布；
- 不修改 static pod manifest（因为 `--target-ram-mb` 不存在，`--watch-cache-sizes` 不能调大小）。

方法：

- 在目标 control-plane 节点启动一个 privileged + hostPID 的一次性 Pod；
- `nsenter` 到宿主机，`crictl stop` 当前 `kube-apiserver` 容器；
- kubelet 自动重启 static pod；
- 等待 `https://<node>:6443/healthz` 返回 ok，再继续下一个节点。

执行顺序：master01 → master02 → m01。

#### 第一次：master01

```text
stopped kube-apiserver container fbfed03d...
new container af0b28051... Running (attempt 5)
apiserver 10.0.0.121 healthy after 10s
```

30 秒后：

| 实例 | WATCH | RSS |
|---|---:|---:|
| m01 | 201 | 1.05GiB |
| master01 | 250 | 968MiB |
| master02 | **824** | **1.82GiB** |

> master01 的 watch 重连后大量落到 master02，master02 变成最重。

#### 第二次：master02

```text
stopped kube-apiserver container 7a6de91c...
new container 1238a82a4... Running (attempt 5)
apiserver 10.0.0.120 healthy after 10s
```

30 秒后：

| 实例 | WATCH | RSS |
|---|---:|---:|
| m01 | 499 | 1.25GiB |
| master01 | 494 | 1.71GiB |
| master02 | 311 | 867MiB |

> 分布暂时比较均衡（499/494/311）。

#### 第三次：m01

```text
stopped kube-apiserver container 00523d34...
new container 64642ba9b... Running (attempt 11)
apiserver 10.0.0.61 healthy after 10s
```

30 秒后：

| 实例 | WATCH | RSS |
|---|---:|---:|
| m01 | 68 | 845MiB |
| master01 | **677** | **1.99GiB** |
| master02 | 572 | 1.65GiB |

2 分钟后（稳定）：

| 实例 | WATCH | RSS | `kubectl top` |
|---|---:|---:|---:|
| m01 | 70 | 695MiB | 766Mi |
| master01 | 676 | 1.71GiB | 1576Mi |
| master02 | 572 | 1.60GiB | 1610Mi |

> **结论：watch 重新收敛回“m01 轻、master01/02 重”的原始分布。滚动重启只能临时重置内存，不能永久均衡。**

### 2.5 未执行的项

| 项 | 原因 |
|---|---|
| `--target-ram-mb` | kube-apiserver 1.35.9 已无此参数 |
| `--watch-cache-sizes=events#100` | 1.35.9 中非零值等价于“启用缓存”，不能调大小 |
| `--event-ttl=30m` | 可选；本次不缩短事件保留，避免影响排障 |
| 加内存 | 硬件变更，本次无法执行 |
| operator namespace-scoped watch | 需要逐个 operator 评估，风险较高，未在本次执行 |
| 删除 Traefik Hub/Gateway CRD | 被 `platform-traefik` ArgoCD app 重建；需改 app，收益小 |

---

## 3. 最终状态

### 3.1 集群

```text
6/6 节点 Ready
所有 Pod Running/Completed
/readyz = ok
ArgoCD platform-traefik / platform-etcd-backup / platform-alloy-config 等 Synced
```

### 3.2 apiserver

```text
kube-apiserver-m01        766Mi   70 watches
kube-apiserver-master01  1576Mi  676 watches
kube-apiserver-master02  1610Mi  572 watches
```

### 3.3 API 面

```text
CRD: 146
OpenAPI v2: 13.23MB
Helm release secrets: 22 / 7.85MB
```

### 3.4 与执行前对比

| 指标 | 执行前 | 执行后 | 变化 |
|---|---:|---:|---:|
| CRD | 148 | 146 | -2 |
| OpenAPI v2 | 13.33MB | 13.23MB | -0.1MB |
| Helm release secret | 36 / 14.45MB | 22 / 7.85MB | -14 / -6.6MB |
| m01 watch/RSS | 72 / 850MiB | 70 / 695MiB | 基本不变 |
| master01 watch/RSS | 641 / 1.66GiB | 676 / 1.71GiB | 略升 |
| master02 watch/RSS | 608 / 1.55GiB | 572 / 1.60GiB | 略升 |
| 总 RSS | ~4.06GiB | ~4.01GiB | 基本不变 |

> 说明：`kubectl top` 是 working set，和 RSS 有差异；表中 RSS 来自 `process_resident_memory_bytes`。

---

## 4. 经验与结论

1. **Helm history 清理是确定有效的低风险优化**：36→22，释放 6.6MB，rollback 仍保留 3 个 revision。
2. **CRD 清理必须先确认 ownership**：Traefik chart 自带的 Hub/Gateway CRD 会被 ArgoCD `selfHeal` 重建；不是“孤儿 CRD”。
3. **滚动重启不能解决 watch 不均衡**：watch 长连接会重新粘到 master01/02，m01 仍然最轻。重启只适合临时重置内存。
4. **1.35.9 没有 `--target-ram-mb`，`--watch-cache-sizes` 也不能调大小**：网上的旧建议不适用于这个版本。
5. **真正有效的下一步只有两个方向**：
   - 给 master01/master02 加内存（8–16GiB）；
   - 减少 watch 数（operator namespace scoping / 移除不用的 operator）。
6. **每实例监控已经存在**：`prometheus-apiserver` ServiceMonitor 抓取三个 6443，`up=1`；无需新增。
7. **Traefik 已迁移到 ArgoCD `platform-traefik`**（chart 42.3.1，app v3.7.17），旧的 Helm release secret 不存在；这是正常迁移，不是本次清理造成的。

---

## 5. 后续建议

### 5.1 最高优先级：加内存

master01/master02 目前 4–6GiB，承载 146 CRD + 1,300 总 watch，偏小。  
建议：

- master01/master02：至少 8GiB，最好 16GiB；
- m01：8GiB；
- 加内存后再观察 `process_resident_memory_bytes` 和 `go_memstats_heap_inuse_bytes`。

### 5.2 减少 watch

当前单实例 572–676 watch，主要来自：

- ArgoCD（多资源 watch）
- Prometheus Operator
- Grafana Operator
- Tekton（operator/triggers/resolvers）
- Strimzi / CNPG
- cert-manager
- Cilium
- MetalLB
- VPA

建议逐个评估 namespace-scoped watch：

- Prometheus Operator：`--namespaces=monitoring,compassio,deeptutor`（需确认所有 PrometheusRule/ServiceMonitor 所在命名空间）
- ArgoCD：sharding 或限制管理范围
- Tekton/Strimzi/CNPG/Grafana Operator：按需限制 watch namespace

### 5.3 Traefik CRD（可选）

如果要永久移除 Hub/Gateway CRD：

1. 修改 `clusters/prod/applications/platform-traefik.yaml`，在 Helm source 加 `skipCrds: true`；
2. 在 `platform/traefik/values.yaml` 关闭 Hub/Gateway（如果 chart 支持）；
3. 再删除 21 个 CRD；
4. 确认 Traefik Ingress 正常。

收益：约 1MB OpenAPI；风险：ingress 变更。**本次未做。**

### 5.4 Helm 历史

后续所有 `helm upgrade` 加：

```bash
--history-max 3
```

### 5.5 监控告警

对三个 apiserver 的 6443 增加告警：

```text
process_resident_memory_bytes > 70% 节点内存
apiserver_longrunning_requests{verb="WATCH"} > 800
go_goroutines > 10000
go_memstats_heap_inuse_bytes 持续增长不回落
```

### 5.6 可选

- `--event-ttl=30m`（减少 1,945 个 Events 的保留；本次未做）
- 修复 worker03 image filesystem 80% 警告（与 apiserver 无关）

---

## 6. 回滚

### 6.1 恢复 CRD

```bash
kubectl apply -f /root/apiserver-remediation-20261109/crds-removed-backup.yaml
```

> 21 个 Traefik CRD 已被 ArgoCD 重建；apply 是幂等的。  
> 2 个 policy CRD 会从备份恢复。

### 6.2 恢复 Helm release 历史（可选）

```bash
kubectl apply -f /root/apiserver-remediation-20261109/helm-release-secrets-backup.yaml
```

### 6.3 apiserver 重启

本次只 `crictl stop` 容器，没有修改 static pod manifest；无需回滚。  
如需再次重启，使用：

```bash
/root/apiserver-remediation-20261109/restart-apiserver.sh <node> <node-ip>
```

---

## 7. 证据文件

```text
/root/apiserver-remediation-20261109/
├── crds-to-remove.txt
├── crds-removed-backup.yaml
├── helm-release-secrets-backup.yaml
├── helm-secrets-deleted.txt
└── restart-apiserver.sh
```

相关分析文档：

- `/root/apiserver-memory-analysis-20261109.md`
- `/root/production-readiness-gaps-20261109.md`
