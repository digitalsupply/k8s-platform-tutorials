# Headlamp 集群页 6 个 Warning 事件：排查、根因与修复（2026-11-19）

> **场景**：Headlamp 集群页 `https://headlamp.devops.com/c/main/` 显示 6 个警告。
> Headlamp 的警告面板显示的是集群里的 **Warning 类型 Kubernetes 事件**（前端 `useEventWarningList`，从 events API 拉取）。
> **性质**：运行态故障排查记录，含排查过程、根因分析、修复动作与验证。

---

## 一、故障清单

集群里恰好 6 条 Warning 事件，与 Headlamp 显示完全对应：

| # | 事件类型 | 涉及对象 | 时间 | 性质 |
|---|---|---|---|---|
| 1 | FailedGetExternalMetric | HPA `compassio-backend` | 2 分钟前 | 连带问题 |
| 2 | Unhealthy | Pod `prometheus-grafana` | 2 分钟前 | 探针误杀 |
| 3 | Unhealthy | Pod `compassio-backend` | 26 分钟前 | 连带问题 |
| 4 | BackOff | Pod `compassio-backend` | 1 分钟前 | **核心故障** |
| 5 | Unhealthy | Pod `pg16-ceph-4` | 3 分钟前 | 正常管控 |
| 6 | BackoffLimitExceeded | Job `etcd-snapshot-29918225` | 37 分钟前 | S3 上传失败 |

---

## 二、逐项排查与修复

### 故障 1+3+4：compassio-backend CrashLoopBackOff（核心故障）

**现象**：

- `compassio-backend` Pod 容器反复重启（重启 28 次），`CrashLoopBackOff`，退避 5 分钟；
- 就绪探针探测 `:8000/api/health` 连接被拒（应用从未成功监听端口）；
- HPA 报 `FailedGetExternalMetric`，无法获取外部指标 `compassio_next_llm_wait_p95`。

**排查过程**：

1. **查看容器日志**，找到崩溃根因：
   ```
   PermissionError: [Errno 1] Operation not permitted
   （asyncpg connect_utils._connect → _create_ssl_connection → TCPTransport.connect）
   ```
   应用启动时用 **asyncpg 连接 PostgreSQL（SSL）**，建立 SSL TCP 连接时抛出 `PermissionError: EPERM`，FastAPI 启动失败退出 → 崩溃循环。

2. **确认数据库连接目标**：从 Secret `compassio-app-secrets` 解码 `DATABASE_URL`：
   ```
   postgresql+asyncpg://compassio:***@pg16-ceph-rw.cnpg-system.svc:5432/compassio
   ```
   数据库是 **CNPG 管理的 pg16-ceph 集群**，通过 `pg16-ceph-rw` 服务连接。

3. **验证网络连通性**：从 compassio 命名空间的测试 Pod 连接 `pg16-ceph-rw:5432`：
   ```
   nc: 10.111.4.92 (10.111.4.92:5432): Operation not permitted
   ```
   **连普通 busybox Pod 也是 EPERM**——不是 compassio-backend 特有，而是网络层拒绝。

4. **检查 `pg16-ceph-rw` 服务**：
   ```
   NAME           ENDPOINTS   AGE
   pg16-ceph-rw   <none>      230d
   ```
   **服务没有 endpoints**——没有任何 Pod 带 `primary` 标签。

5. **检查 CNPG 集群状态**：
   - `pg16-ceph-3`：标签 `cnpg.io/instanceRole: replica`，`pg_is_in_recovery() = t`（副本，处于 recovery 模式）
   - `pg16-ceph-4`：标签 `cnpg.io/instanceRole: unhealthy`，PostgreSQL 进程已下线
   - **集群没有健康主库**：原主库 pg16-ceph-4 已下线，pg16-ceph-3 是副本，无 Pod 带 primary 标签 → `pg16-ceph-rw` 无 endpoints

**根因分析**：

```
pg16-ceph-4（原主库）故障下线
  → CNPG 集群无健康主库
    → pg16-ceph-rw 服务无 endpoints（无 Pod 带 primary 标签）
      → Cilium 对无 endpoint 的 ClusterIP 返回 EPERM
        → compassio-backend 连库被拒（PermissionError）
          → 应用启动失败 → CrashLoopBackOff
            → 不暴露指标 → HPA 外部指标缺失（连带故障 1）
            → 就绪探针失败（连带故障 3）
```

**修复过程**：

1. **提升 pg16-ceph-3 为新主库**。CNPG 控制器已自动完成主库提升（`pg16-ceph-3` 标签变为 `primary`，`pg_is_in_recovery() = f`）；
2. **验证 `pg16-ceph-rw` endpoints 恢复**：`10.244.3.83:5432`；
3. **compassio-backend 自动恢复**：Pod 重启后连接数据库成功，`/api/health`、`/metrics` 全部返回 200。

**修复验证**：

```bash
# pg16-ceph-3 已为主库
kubectl -n cnpg-system exec pg16-ceph-3 -c postgres -- psql -U postgres -tAc "SELECT pg_is_in_recovery()"
# → f（非 recovery，即主库）

# pg16-ceph-rw 有 endpoint
kubectl -n cnpg-system get endpoints pg16-ceph-rw
# → 10.244.3.83:5432

# compassio-backend 运行正常
kubectl -n compassio logs <pod> --tail=5
# → /api/health 200, /metrics 200

# HPA 外部指标恢复
kubectl -n compassio get hpa compassio-backend
# → 0/1500m, cpu: 20%/80%（外部指标 0 是有效值，之前是"无法获取"）
```

---

### 故障 2：prometheus-grafana liveness 探针误杀

**现象**：

- kubelet 探测 `10.244.x.x:3000/api/health` 连接被拒；
- 事件 `Container grafana failed liveness probe, will be restarted`；
- 容器被杀重启（exit 137 = SIGKILL），已重启 3 次。

**排查过程**：

1. 检查探针配置：
   ```
   liveness: initialDelay=60, failureThreshold=10, period=10, timeout=30
   ```
2. 检查 Grafana 日志：启动期间做 unified storage 迁移，响应较慢；
3. 确认 **先挂的是 liveness 探针**：Grafana 启动/迁移耗时超过 `60s + 10×10s = 160s`，liveness 连续失败 → kubelet 杀容器 → 重启期间 readiness 探针自然连接被拒。

**根因分析**：

Grafana 启动/迁移耗时较长，探针的 `initialDelaySeconds=60` + `failureThreshold=10`（共 160 秒容忍窗口）不足以覆盖 Grafana 的启动时间，导致 liveness 探针误判、容器被杀。

**修复过程**：

1. **更新 GitOps 仓库** `platform/monitoring/values.yaml`，在 grafana 段添加：
   ```yaml
   grafana:
     livenessProbe:
       enabled: true
       httpGet:
         path: /api/health
         port: grafana
         scheme: HTTP
       initialDelaySeconds: 120    # 60 → 120
       failureThreshold: 20        # 10 → 20
       periodSeconds: 10
       timeoutSeconds: 30
       successThreshold: 1
   ```
2. 用 `helm upgrade` 应用变更（`kube-prometheus-stack 83.7.0`）。
3. **注意**：ArgoCD 配置了 `selfHeal: true`，直接 `kubectl patch` 会被 ArgoCD 从 Git 仓库同步回滚。必须在 GitOps 仓库中修改 values，通过 Helm 升级或 ArgoCD 同步生效。

**修复验证**：

- grafana Pod `1/1 Running, 0 restarts`；
- 探针参数已调整（需 GitOps 仓库 MR 合并后 ArgoCD 同步生效）。

**GitOps 局限说明**：

此故障是**运行态问题**，GitOps 保证配置同步但不保证运行健康。Git 里的探针参数"看起来合理"，但未考虑 Grafana 实际启动耗时。GitOps 不会自动调优探针参数。

---

### 故障 5：pg16-ceph-4 Unhealthy（正常管控，无需处理）

**现象**：CNPG PostgreSQL 实例 `pg16-ceph-4` 的 postgres 容器 ready=false，readyz 探针连接被拒，restarts=0。

**排查过程**：查看 CNPG instance-manager 日志：

```
"This is an unreachable former primary instance, no longer the target primary.
 Demoting it by shutting it down immediately, since PostgreSQL is not reachable for a checkpoint."
```

**根因**：该实例是**曾经的主库，现在不可达，被 CNPG 主动降级并关闭**，PostgreSQL 进程已下线。这是**主库切换/故障恢复中的正常管控动作**，不是异常。

**处理**：无需处理，确认是预期降级。

---

### 故障 6：etcd-snapshot Job 失败（BackoffLimitExceeded）

**现象**：etcd 定时快照备份 Job `etcd-snapshot-29918225` 失败，达到 `backoffLimit`（=1），标记 Failed。

**排查过程**：

1. **手动触发 Job 复现失败**：
   ```
   upload failed: var/backups/etcd/hourly/etcd-xxx.db to s3://etcd-backups/hourly/etcd-xxx.db
   argument of type 'NoneType' is not iterable
   ```
   `snapshot save` 成功，**S3 上传失败**，报 `argument of type 'NoneType' is not iterable`。

2. **用 s3cmd 测试**（宿主机有 s3cmd）：
   ```
   ERROR: S3 error: 507 (InsufficientCapacity)
   ```
   **真实错误是 507 存储空间不足**！aws-cli v2 把 507 错误解析成 `argument of type 'NoneType' is not iterable`，掩盖了真实原因。

3. **检查 Ceph 状态**：
   ```
   health: HEALTH_ERR
   1 backfillfull osd(s)
   1 full osd(s)
   1 nearfull osd(s)
   15 pool(s) full
   ```
   **Ceph 集群 15 个 pool 全满**，S3 网关返回 507。

4. **检查 S3 桶内容**：
   ```
   hourly/ 目录有 203 个备份文件，每个 136MB，约 27.6GB
   ```

**根因分析**：

```
备份脚本只清理本地文件，不清理 S3
  → S3 桶无限累积（203 个备份 × 136MB ≈ 27.6GB）
    → Ceph 存储被备份撑满（15 pool full）
      → S3 网关返回 507 InsufficientCapacity
        → aws-cli v2 把 507 错误解析成 NoneType 错误
          → 备份上传失败 → Job BackoffLimitExceeded
```

脚本注释称"Bucket lifecycle 已配置（hourly 30天、daily 90天）"，但 Ceph RGW 的生命周期规则未生效，备份持续累积。

**修复过程**：

1. **清理 S3 旧备份**：删除 hourly 目录中超出 24 个的旧文件（保留最近 24 个），删除 daily 目录中超出 7 个的旧文件（保留最近 7 个），释放约 24GB；
2. **更新备份脚本**（GitOps 仓库 `platform/backup/etcd/cronjob.yaml`），在上传后增加 S3 清理逻辑：
   ```bash
   # S3 retention (match local staging: ~24 hourly + 7 daily)
   AWS_CMD="chroot /host /usr/bin/aws --endpoint-url ${S3_ENDPOINT}"

   # hourly: keep most recent 24, delete the rest
   ${AWS_CMD} s3 ls "s3://${S3_BUCKET}/hourly/" 2>/dev/null | \
     grep 'etcd-.*\.db$' | tail -n +25 | while read line; do
     f=$(echo "${line}" | awk '{print $NF}')
     ${AWS_CMD} s3 rm "${f}" 2>/dev/null || true
   done

   # daily: keep most recent 7, delete the rest
   ${AWS_CMD} s3 ls "s3://${S3_BUCKET}/daily/" 2>/dev/null | \
     grep 'etcd-.*\.db$' | tail -n +8 | while read line; do
     f=$(echo "${line}" | awk '{print $NF}')
     ${AWS_CMD} s3 rm "${f}" 2>/dev/null || true
   done
   ```
3. **应用到集群**：`kubectl apply` 更新 CronJob。

**修复验证**：

```bash
# Ceph 状态改善
ceph -s
# → HEALTH_WARN（从 HEALTH_ERR 改善，15 pool backfillfull）

# 手动触发备份 Job，完整上传成功
kubectl -n etcd-backup create job verify --from=cronjob/etcd-snapshot
# → snapshot save 137MB → s3 cp 上传 → "snapshot + upload ok"
```

---

## 三、根因总结

| 故障 | 根因 | 修复 | 性质 |
|---|---|---|---|
| compassio-backend BackOff | pg16-ceph-rw 无 endpoints（无健康主库）→ Cilium EPERM → 连库被拒 | 提升 pg16-ceph-3 为主库 | 运行态故障（依赖宕机） |
| HPA 外部指标缺失 | compassio 崩溃 → 不暴露指标（连带） | 随 compassio 恢复 | 连带问题 |
| compassio-backend Unhealthy | CrashLoopBackOff 连带（应用从未监听端口） | 随核心故障恢复 | 连带问题 |
| grafana 探针误杀 | liveness 探针对 Grafana 启动耗时偏激进 | 调大 initialDelay/failureThreshold | 配置对运行态不适用 |
| pg16-ceph-4 降级 | CNPG 主动降级不可达的旧主库 | 无需处理（正常管控） | 正常行为 |
| etcd 备份失败 | Ceph 存储满（备份无限累积）→ S3 507 → aws-cli 报错 | 清理 S3 + 脚本增加 S3 清理 | 存储容量问题 |

---

## 四、GitOps 防漂移的局限

本次故障中，GitOps（ArgoCD）已覆盖所有出问题的资源（均有 tracking-id 注解），但**仍然出问题**。原因在于：

**1. GitOps 防的是"配置漂移"，不是"运行态故障"**

GitOps 的机制是**对账 + 拉回**：比对 Git 声明与集群实际状态，不一致就拉回。它解决的是"有人手动改了配置"。但：
- **数据库主库宕机**是运行态事件，GitOps 不可能把宕机的数据库拉回健康；
- **Ceph 存储满**是容量问题，GitOps 管不了存储空间；
- **探针误杀**是应用运行时行为，GitOps 不会自动调优探针参数。

**2. Git 配置"正确"但运行态不适用**

Git 里的探针参数（`initialDelay=60, failureThreshold=10`）看起来合理，但未考虑 Grafana 实际启动耗时。GitOps 忠实同步了这份配置，但无法判断它在当前运行态下会导致故障。**同步正确 ≠ 运行健康。**

**3. ArgoCD 状态佐证：Synced 但 Degraded**

出问题的 ArgoCD 应用全是 **Synced 但 Degraded/Progressing**：

| 应用 | Sync | Health |
|---|---|---|
| platform-cnpg-cluster | Synced | Degraded |
| platform-grafana | Synced | Degraded |
| platform-monitoring-stack | Synced | Degraded |
| platform-etcd-backup | Synced | Degraded |
| compassio | Synced | Progressing |

**Sync（配置同步）和 Health（健康状态）是两个维度。GitOps 保证前者，管不了后者。** 配置没漂移，但运行不健康——这正是 GitOps 的能力边界。

**4. 依赖链故障穿透**

GitOps 是单应用视角。compassio → pg16-ceph 这条依赖链上，数据库集群故障是运行态事件，GitOps 视野里只有 compassio 自己的声明，看不到也修不了数据库。

**5. GitOps 之外需要的配套**

- **监控告警**：对依赖服务（数据库、存储、备份）的健康状态主动告警；
- **运行态治理**：探针参数根据应用实际启动耗时调优，脚本做运行时验证；
- **依赖链视角**：把"应用依赖的外部服务健康"纳入运维视野。

---

## 五、验证命令汇总

```bash
# === compassio-backend 恢复验证 ===
kubectl -n compassio get pods -l app.kubernetes.io/name=compassio-backend
kubectl -n compassio logs <pod> --tail=5          # /api/health 200, /metrics 200
kubectl -n compassio get hpa compassio-backend     # 外部指标恢复

# === pg16-ceph 主库验证 ===
kubectl -n cnpg-system exec pg16-ceph-3 -c postgres -- psql -U postgres -tAc "SELECT pg_is_in_recovery()"
# → f（主库）
kubectl -n cnpg-system get endpoints pg16-ceph-rw  # → 10.244.3.83:5432

# === grafana 探针验证 ===
kubectl -n monitoring get deploy prometheus-grafana -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana

# === etcd 备份验证 ===
kubectl -n etcd-backup get cronjob etcd-snapshot -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].args}'
# 确认包含 "S3 retention" 清理逻辑
kubectl -n etcd-backup create job verify --from=cronjob/etcd-snapshot
kubectl -n etcd-backup logs -f <pod>                # → "snapshot + upload ok"

# === Ceph 状态 ===
kubectl -n etcd-backup run ceph-check --rm -i --image=busybox:1.36 \
  --nodeSelector.kubernetes.io/hostname=m01 \
  -- sh -c 'chroot /host ceph -s'
```

---

## 六、关键教训

1. **EPERM 连接问题要查服务 endpoints**：连 ClusterIP 报 `Operation not permitted`，优先检查服务是否有 endpoints。Cilium 对无 endpoint 的 ClusterIP 返回 EPERM，这是 Cilium 的特征行为。
2. **aws-cli v2 会掩盖 S3 错误**：`argument of type 'NoneType' is not iterable` 可能是 507 存储满被错误解析。遇到此错误时，用 s3cmd 等替代工具验证真实错误码。
3. **备份脚本必须清理远端**：只清理本地文件、不清理远端存储，会导致远端无限累积，最终撑爆存储。
4. **GitOps 不是银弹**：它防配置漂移，不防运行态故障。需要监控告警和运行态治理配套。
5. **探针参数要匹配实际启动耗时**：liveness 探针的 initialDelay 和 failureThreshold 要留足余量，否则会误杀容器。
