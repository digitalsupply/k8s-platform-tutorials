# K8s 运维改造干货合集（2026-11-09）

> 本文是 7 轮改造的总索引 + 核心干货。详细过程在各分文档里。
> 集群：kubeadm v1.35.9，6 节点；ArgoCD v3.5.3。
>
> **归档说明（2026-11-10）**：本文写于改造当周，文中“16 个 Application”是当时数字；
> 截至 2026-11-10 已是 31 个，全部 `Synced/Healthy`。分文档已按主题归入本仓库
> 03/04/06/10/11 等分类，原文件名保持不变。

---

## 0. 一屏总结

| 轮次 | 主题 | 结果 |
|---|---|---|
| 1 | CNPG 1.22 → 1.30.1 | ✅ 完成，2/2 healthy |
| 2 | GitOps 覆盖盘点 | ✅ 完成，识别 P0/P1/P2 |
| 3 | P0 GitOps 落地 | ✅ CNPG / Kafka / CI / app-of-apps 完成 |
| 4 | Grafana Operator Stage A | ✅ 4 Datasource + 37 Dashboard 接管 |
| 5 | Sealed Secrets + open-webui | ✅ 3 个明文 Secret 迁移完成 |
| 6 | Vault + ESO 可行性 | ✅ 分析完成，待决策 |
| 7 | 监控存储 NFS → Ceph RBD | ✅ 迁移完成，旧监控 NFS 已清理；业务 NFS PVC 保留 |

当前 **16 个 ArgoCD Application 全部 `Synced / Healthy`**。

---

## 1. 文档索引

| 文档 | 内容 |
|---|---|
| `2026-11-08-cnpg-upgrade-postmortem.md` | CNPG 升级、rp_filter、barmanObjectStore、PG16 生命周期、实例命名 |
| `2026-11-08-gitops-coverage-and-recommendations.md` | GitOps 覆盖率、P0/P1/P2 建议 |
| `2026-11-08-p0-gitops-execution-log.md` | P0 落地过程、问题、提交记录 |
| `2026-11-08-grafana-operator-stage-a.md` | Grafana Operator Stage A + Ingress/ServiceMonitor/prune |
| `2026-11-08-sealed-secrets-openwebui.md` | Sealed Secrets 安装 + open-webui 迁移 |
| `2026-11-08-vault-eso-feasibility.md` | Vault + ESO 资源核算、unseal、决策矩阵、POC 清单 |
| `2026-11-09-prometheus-nfs-to-ceph-migration.md` | 监控存储 NFS → Ceph RBD 全过程、Ceph full 事故、fsGroup/WAL/CNPG 恢复、运维教程 |
| `2026-11-09-gitlab-repo-access-tutorial.md` | GitLab 仓库获取：SSH / HTTPS PAT / Deploy Token、本机实际方法、ArgoCD 仓库凭据、排错与安全 |

---

## 2. 轮次 1：CNPG 1.22 → 1.30.1

### 核心结果

- CNPG **1.22.0 → 1.30.1**；
- 备份从内置 `barmanObjectStore` 迁移到 **Barman Cloud Plugin 0.15.1**；
- PostgreSQL 镜像固定为 **16.15**；
- `primaryUpdateMethod` 改为 **switchover**。

### 关键踩坑

| 坑 | 根因 | 修复 |
|---|---|---|
| 全集群 webhook 超时 | m01 `rp_filter=1`，双网卡非对称路由 | 改为 `2`，持久化 |
| SSA 字段冲突 | 旧资源是 client-side apply | `--force-conflicts` |
| CNPG 永远 OutOfSync | Operator 回填 `enablePDB`/`probes`/`replicationSlots` | `ignoreDifferences` |
| 1.31 备份失效风险 | 内置 barmanObjectStore 被移除 | 迁移到 Plugin |
| 主库重启 3 分钟 | `primaryUpdateMethod: restart` | 改 `switchover` |

### 结论

- **PG16 没过期**：EOL 2028-11-09，16.15 是当前最新 minor；PG14 才是 2026-11-12 EOL。
- **CNPG 不用 StatefulSet**：Pod 后缀是 instance serial，不是 StatefulSet ordinal；旧版本全局递增，1.30 改为复用最小空闲槽位。

---

## 3. 轮次 2：GitOps 覆盖盘点

### 覆盖率（86 个工作负载）

| 类别 | 数量 |
|---|---:|
| ArgoCD 直接管理 | 11 |
| ArgoCD 间接管理（TektonConfig → Operator） | 12 |
| Helm 管理 | 38 |
| Operator 从手动 CR 创建 | 4 |
| 完全手动 | 21 |

### 结论

- 业务应用基本已 GitOps 化；
- 平台/中间件大部分还没；
- P0：CNPG、Kafka、监控 CR、CI 定义、app-of-apps、Secret。

---

## 4. 轮次 3：P0 GitOps 落地

### 已完成

| P0 项 | 结果 |
|---|---|
| CNPG | Operator / Plugin / Cluster / ObjectStore / ScheduledBackup |
| Kafka | Operator / Kafka / NodePool / Topic |
| CI 定义 | 4 Pipeline / 12 Task / 3 EventListener 等 |
| app-of-apps | 16 个 Application 全部纳入 |

### 关键设计

- 平台 App `prune=false`；
- `ServerSideApply=true`；
- `ignoreDifferences` 处理 Operator 回填；
- 有状态 CR 不自动 prune；
- 不提交 Operator 生成的子资源（Pod/PVC/StatefulSet）。

### 仓库

```text
http://192.168.67.201/digitalsupply/platform-gitops.git
```

---

## 5. 轮次 4：Grafana Operator Stage A

### 结果

- Grafana Operator **v5.25.0**，external 模式；
- **4 个 Datasource**：Prometheus / Alertmanager / Loki / Tempo；
- **37 个 Dashboard CR**，引用现有 ConfigMap；
- 去掉 2 个 k8s-sidecar，Grafana 从 3 容器降为 1 容器；
- Grafana 仍为 Helm Deployment，**PVC/Deployment 未替换**；
- Traefik IngressRoute 纳入 GitOps；
- Operator ServiceMonitor `up`；
- `platform-grafana` `prune=true`，`Grafana` CR 带 `Prune=false`。

### 关键踩坑

| 坑 | 原因 | 修复 |
|---|---|---|
| Datasource PUT 403 | 旧 datasource `readOnly=true` | SQLite `UPDATE data_source SET read_only=0` |
| Dashboard DELETE 400 | 旧 dashboard 在 `dashboard_provisioning` 表 | `DELETE FROM dashboard_provisioning` |
| Operator 连接拒绝 | Grafana 重启后缓存旧连接 | 重启 Operator Pod |
| CRD OutOfSync | API Server 回填 `spec.conversion` | `ignoreDifferences` |

### 经验

从 sidecar 迁移到 Operator，**必须清理 Grafana DB 里的 provisioned/readOnly 标志**，否则 Operator 无法接管。

---

## 6. 轮次 5：Sealed Secrets + open-webui

### 结果

- Sealed Secrets Controller **v0.41.2**，`kube-system`；
- open-webui 的 3 个 Secret 已迁移：
  - `frp-token`
  - `harbor-pull`
  - `open-webui-config`
- 控制器创建的 Secret 数据哈希与迁移前**完全一致**；
- 仓库 HEAD 无明文 Secret；
- 私钥备份：`/root/k8s-postmortem/backup/sealed-secrets-key.yaml`。

### 额外发现（待修复）

| 问题 | 建议 |
|---|---|
| `frpc-config` 里仍有明文 FRP token | 改 `{{ .Envs.FRP_TOKEN }}` + Secret 注入 |
| `harbor-pull` 使用 Harbor admin | 改 robot account + 轮换 admin |
| Git 历史仍有明文 | 轮换 Harbor/FRP/WEBUI/GitLab 凭据 |
| 私钥单点 | 放 Vault/离线保险库，双人审批 |

### 剩余 P0-6

- `cicd/gitlab-auth`
- `cnpg-system/pg-secret`
- `cnpg-system/pg-superuser-secret`
- `cnpg-system/pg-backup-s3-creds`

> 不要迁移 `cnpg-ca-secret`、`cnpg-webhook-cert`，它们由 CNPG Operator 管理。

---

## 7. 轮次 6：Vault + ESO 可行性

### 结论

- **能跑**：约 6–7 Pod，~600m CPU / ~1.2Gi 内存 / 30Gi ceph-rbd；
- **最大代价是 unseal**：on-prem 无云 KMS，节点重启后要人工 3-of-5 解封；
- Vault 是 **BUSL 许可**，介意就评估 **OpenBao**；
- 只要“明文不进 Git” → Sealed Secrets 已够；
- 要审计 / need-to-know / 动态凭据 → Vault + ESO 值得；
- 推荐 **混合模式**：低风险配置留 Sealed Secrets，高价值凭据进 Vault；
- 先做 Phase 1 POC。

---

## 8. 当前架构状态

### ArgoCD（16 个 App，全部 Synced/Healthy）

```text
app-of-apps
├── china-study-free
├── compassio
├── deeptutor
├── open-webui
├── tekton-config
├── tekton-operator
├── platform-cnpg-operator
├── platform-cnpg-plugin
├── platform-cnpg-cluster
├── platform-kafka-operator
├── platform-kafka-cluster
├── platform-cicd
├── platform-grafana-operator
├── platform-grafana
└── platform-sealed-secrets
```

### 组件状态

| 组件 | 状态 |
|---|---|
| CNPG | `pg16-ceph` 2/2 healthy |
| Kafka | `my-cluster` Ready 4.1.2 |
| Tekton | `config` Ready v0.81.3 |
| Grafana | 12.4.3，4 DS / 37 Dashboard / 47 总 Dashboard |
| Sealed Secrets | v0.41.2，3 个 open-webui SealedSecret |
| 存储 | `ceph-rbd-sc` / `nfs-sc`；监控三组件数据盘已迁到 Ceph，旧监控 NFS 已清理 |

---

## 9. 待办清单

### 高优先级

- [x] 监控存储 NFS → Ceph RBD（2026-11-09，Helm values 已入 GitOps）
- [ ] P0-3：Prometheus/Alertmanager CR 从 Helm 迁到 GitOps（维护窗口）
- [ ] P0-6：迁移 `gitlab-auth`、CNPG 3 个 Secret
- [ ] 轮换凭据：Harbor admin、FRP token、WEBUI_SECRET_KEY、GitLab token
- [ ] 轮换 `/root/gitops-p0` remote URL 中的 GitLab token，改用 SSH key 或 credential helper
- [ ] 修复 `frpc-config` 明文 FRP token
- [ ] CNPG PITR 恢复演练
- [ ] CNPG 监控指标从 `cnpg_collector_*` 切到 `barman_cloud_cloudnative_pg_io_*`

### 中优先级

- [ ] Grafana Stage B（替换 Helm Grafana，单独窗口）
- [ ] Vault + ESO Phase 1 POC（如果决定要做）
- [ ] ArgoCD 自身纳入 GitOps（`prune=false`）
- [ ] Namespace/RBAC/NetworkPolicy/Quota 基线
- [ ] 做一次“从零重建”演练

### 低优先级

- [ ] Grafana admin 密码轮换
- [ ] Grafana Ingress 换正式域名 + cert-manager 证书
- [ ] 清理历史 `Backup` CR
- [ ] 评估 etcd encryption at rest

---

## 10. Top 10 经验

1. **rp_filter**：K8s + Calico + 双网卡，统一用 `2`（loose），不要用 `1`。
2. **Webhook 故障会级联**：一个节点网络问题能让全集群 Admission 写入失败。
3. **SSA 迁移**：从 client-side apply 转 SSA，第一次要 `--force-conflicts`。
4. **Operator 回填字段**：ArgoCD 必须配 `ignoreDifferences`，否则永久 OutOfSync。
5. **Helm 子 chart 删除**：`grafana.enabled=false` 可能连 PVC/Secret/Service 一起删；先打 `helm.sh/resource-policy: keep`。
6. **Sealed Secrets 私钥**：是单点信任，丢了全解不开；必须离线/Vault 保管。
7. **明文 Secret 进 Git**：删 HEAD 不够，历史仍在；轮换凭据才是根治。
8. **有状态 CR 不 prune**：CNPG/Kafka/ObjectStore 一律 `prune=false`。
9. **迁移前备份 + 哈希校验**：Secret 迁移用 data 哈希对比，确认零差异。
10. **有状态替换用 canary**：Grafana Stage B、Vault 等，优先新实例并行验证，再切流量。

---

## 11. 备份资产

| 文件 | 说明 |
|---|---|
| `backup/grafana.db` | Grafana SQLite 备份（3.9MB） |
| `backup/grafana-dashboards/*.json` | **47 个 Dashboard JSON，已修正为有效导出（1.2MB）** |
| `backup/prometheus-values-before-grafana-operator.yaml` | Helm values 备份 |
| `backup/sealed-secrets-key.yaml` | **Sealed Secrets 私钥（chmod 600）** |
| `backup/sealed-secrets-pub.pem` | 公钥证书（非敏感） |

> 私钥必须转移到 Vault/离线保险库；不要只留在 `/root` 下。

---

## 12. 2026-11-09 追加：监控存储迁移

- Grafana / Alertmanager / Prometheus 全部迁到 `ceph-rbd-sc`；
- 旧监控 NFS PVC 已在验证后清理（Prometheus 20G 数据、Grafana、Alertmanager）；当前 NFS 仅保留业务 PVC；
- 同时清理 15 个已完成/失败的 Tekton PipelineRun 及其 workspace PVC，NFS 根盘 47G → 26G；
- 迁移中触发 Ceph `k8s-rbd` 100% full，清理 6 个孤儿镜像后恢复 `HEALTH_OK`；
- 关键坑：PVC 名算错、fsGroup 递归 chown 19.3G、WAL 段不连续、worker02 RBD I/O 卡死硬重启、CNPG failover；
- GitOps：`platform/monitoring/values.yaml` + README 已提交（`18fa007`），
  ArgoCD 不管理该 Helm release，不会自动回滚；
- 详情：`2026-11-09-prometheus-nfs-to-ceph-migration.md`。

---

## 13. 一句话

> 业务应用已经 GitOps 化；平台层完成了 CNPG、Kafka、CI、Grafana、Sealed Secrets 五块拼图。剩下的关键动作是：**监控 CR 迁移、剩余 Secret 迁移、凭据轮换、以及决定是否上 Vault + ESO。**
