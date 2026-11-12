# CNPG 1.22.0 → 1.30.1 升级复盘、踩坑修复与生产加固

> **状态：历史快照（2026-11-08，K8s 1.35.9）**
> 本文是 CNPG 1.22→1.30 升级当时的记录；文中出现的 `calico-node` 镜像只是**借来做宿主机网络调试**，不代表当时还用 Calico。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），**照本文排障前先看现状**：[current-state.md](../../00-cluster-overview/assets/current-state.md)。
> 审计记录见 [19 章](../../19-audit/README.md)。

> 集群：kubeadm v1.35.9（6 节点：m01 / master01 / master02 / worker01-03）
> 数据库：CloudNativePG `pg16-ceph`（PostgreSQL 16.15，2 实例，namespace `cnpg-system`）
> 执行日期：2026-11-08
> 最终版本：CNPG **1.30.1** + Barman Cloud Plugin **0.15.1**

---

## 0. 摘要

本次完成了两件事：

1. **CNPG 1.22.0 → 1.30.1**（跨 8 个 minor，当前最新稳定版，支持 K8s 1.35 / PG 16）。
2. **把上一轮列出的 5 条后续建议全部落地**，其中最关键的是把内置 `barmanObjectStore` 迁移到 **Barman Cloud Plugin**，避免 1.31 移除后备份直接失效。

| 项目 | 升级前 | 升级后 |
|---|---|---|
| CNPG Operator | 1.22.0（EOL） | **1.30.1** |
| 备份方式 | 内置 `spec.backup.barmanObjectStore`（1.31 移除） | **Barman Cloud Plugin 0.15.1** |
| PostgreSQL 镜像 | `ghcr.io/cloudnative-pg/postgresql:16`（浮动 tag） | **`...:16.15`**（同一 digest） |
| 主库更新策略 | `restart`（约 3 分钟停机） | **`switchover`** |
| 弃用字段 | `retentionPolicy` / `maxSyncReplicas` / `minSyncReplicas` | 前两者已移除；后两者被 1.30 webhook 重新补 0 |
| rp_filter | m01=`1`，其余=`2` | **6 节点全部 `2`**，并持久化 |
| 集群状态 | 2/2 healthy | **2/2 healthy** |

---

## 1. 最终状态

```text
NAME        INSTANCES   READY   STATUS                     PRIMARY       IMAGE
pg16-ceph   2           2       Cluster in healthy state   pg16-ceph-3   ghcr.io/cloudnative-pg/postgresql:16.15

conditions:
  Ready=True                 (ClusterIsReady)
  ContinuousArchiving=True   (ContinuousArchivingSuccess)
  LastBackupSucceeded=True   (LastBackupSucceeded)
  Initialized=True           (BootstrapCompleted)
  ConsistentSystemID=True    (Unique)

pods (2/2 = postgres + plugin-barman-cloud native sidecar):
  pg16-ceph-3  2/2 Running  0 restarts  primary
  pg16-ceph-4  2/2 Running  0 restarts  replica
```

复制状态（备库已完全追平）：

```text
pg16-ceph-3  pg_is_in_recovery=f
pg16-ceph-4  pg_is_in_recovery=t  receive=E/B801DFA0  replay=E/B801DFA0
```

数据完整性：`n8n` 库 `public` schema **63 张表**，应用日志出现 `Database connection recovered`。

---

## 2. 时间线

| 时间（CST） | 事件 |
|---|---|
| 17:34 | 盘点、备份 CRD / Cluster / RBAC / webhook |
| 17:35 | 发现 **所有 admission webhook 超时**，暂停升级 |
| 17:36–17:52 | 定位 m01 `rp_filter=1`，修复并验证 webhook 恢复 |
| 17:52 | 升级前即时备份（16 秒完成） |
| 17:54 | 应用 CNPG 1.30.1 manifest |
| 17:55–17:58 | Operator / 实例管理器滚动，主库重启 |
| 17:58:51 | 集群恢复 2/2 healthy |
| 18:00 | 升级后备份验证（20 秒完成） |
| 18:19 | 迁移前备份（内置 barmanObjectStore） |
| 18:19–18:20 | 安装 Barman Cloud Plugin 0.15.1，创建 ObjectStore |
| 18:22 | Cluster 原子切换：插件 + 固定镜像 + switchover + 清理弃用字段 |
| 18:23–18:27 | 插件 sidecar 注入；首次注入需重启主库 |
| 18:27:00 | 集群恢复 2/2 healthy |
| 18:27:51 | 插件方式备份完成（17 秒） |
| 18:28 | ScheduledBackup 切换到 `method: plugin` |

---

## 3. 踩坑点：现象 / 根因 / 原理 / 修复 / 验证

### 3.1 m01 的 `rp_filter=1` 导致全集群 webhook 超时（最隐蔽、影响最大）

**现象**

```text
Error from server (InternalError): failed calling webhook "mcluster.cnpg.io":
failed to call webhook: Post "https://cnpg-webhook-service.cnpg-system.svc:443/...": context deadline exceeded
```

同时：

- `kubectl create backup` 失败；
- cert-manager 的 `Certificate` dry-run 也失败；
- `kubectl top nodes` 报 `Metrics API not available`（metrics-server 也是 webhook/ClusterIP 路径）。

但直连 webhook Pod IP `10.244.5.95:9443` **20ms 返回 200**。

**根因**

- m01（K8s API Server 所在节点，kubectl 实际连 `10.0.0.61:6443`）的 `net.ipv4.conf.{all,eth0,eth1}.rp_filter` 中，接口值为 **1（strict）**；
- 其余 5 个节点都是 **2（loose）**；
- m01 是双网卡：`eth0=10.0.0.61`（管理网）、`eth1=172.16.1.61`（Calico BGP 网）。

**原理**

1. 访问 ClusterIP `10.108.43.21` 时，路由查表按**原始目的地址**走默认路由，源地址选中 `eth0=10.0.0.61`；
2. iptables DNAT 把目的地址改成 Pod IP `10.244.5.95`；
3. 重新路由后，去 `10.244.5.64/26` 的 Calico 路由是 `via 172.16.1.122 dev eth1`，包从 **eth1** 发出；
4. Pod 回 SYN-ACK 到 `10.0.0.61`，回包从 **eth1** 进入；
5. `rp_filter=1`（strict）要求“回包源 IP 必须能从入接口路由回去”。`10.0.0.61` 属于 eth0，不在 eth1 的网段，因此**严格模式直接丢包**；
6. conntrack 里能看到 3 个 SYN-ACK 重传，但本机 socket 永远收不到，最终 10 秒超时。

> `rp_filter` 有效值 = `max(conf/all.rp_filter, conf/<iface>.rp_filter)`。
> 0=关闭，1=严格，2=宽松。

**修复**

```bash
# 临时/立即
echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 2 > /proc/sys/net/ipv4/conf/default/rp_filter
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f"; done

# 持久化
cat >/etc/sysctl.d/99-zz-k8s-rp-filter.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.eth0.rp_filter = 2
net.ipv4.conf.eth1.rp_filter = 2
EOF
sysctl --system
```

本次已在 m01 持久化，并验证 6 个节点全部为 `2`。

**验证**

```bash
kubectl -n cnpg-system annotate cluster pg16-ceph test=ok --dry-run=server
kubectl top nodes
# 均恢复正常
```

**经验**

- K8s + Calico + 双网卡节点，`rp_filter` 应统一为 **2**（或 0），不要用 1。
- 判断方法：host 网络访问 ClusterIP 超时、直连 Pod IP 正常、conntrack 有回包但 socket 收不到 → 优先查 `rp_filter`、非对称路由、`ip rule`。

---

### 3.2 webhook 故障会把“备份”也一起卡死

**现象**：创建 `Backup` CR 被 mutating webhook 拒绝/超时。

**根因**：CNPG 的 webhook `failurePolicy: Fail`，且 Backup/Cluster/ScheduledBackup 的 CREATE/UPDATE 都经过 webhook；webhook 不可达时，**任何**受管资源的写操作都失败。

**原理**：Admission webhook 是同步调用，API Server 在 10s 内拿不到响应就按 failurePolicy 处理；`Fail` = 直接拒绝请求。

**修复**：先修 3.1 的网络路径，而不是删 webhook 或加 `--validate=false`（后者会绕过校验，风险更大）。

**验证**：`kubectl create backup` 成功，dry-run 正常。

---

### 3.3 `kubectl apply --server-side` 与旧 `kubectl-client-side-apply` 字段冲突

**现象**

```text
Apply failed with 4 conflicts: conflicts with "kubectl-client-side-apply"
- .webhooks[name="vbackup.cnpg.io"].rules
- ...
```

**根因**：旧对象由 client-side apply 创建，字段 owner 是 `kubectl-client-side-apply`；新的 server-side apply 想接管同一字段，K8s 拒绝隐式抢所有权。

**原理**：SSA 使用 field manager 记录字段所有权；冲突必须显式解决（force / 改 manifest / 共同管理）。

**修复**

```bash
kubectl apply --server-side --force-conflicts -f cnpg-1.30.1.yaml
```

**验证**：manifest 全部 `serverside-applied`，Operator 正常滚动。

**经验**：从 client-side apply 迁移到 SSA 时，第一次通常要加 `--force-conflicts`；之后保持 SSA 即可。

---

### 3.4 CNPG 1.22 直接跳 1.30（跨 8 个 minor）

**现象**：升级前 1.22.0 已 EOL 约 2 年，文档建议“顺序升级、不要跳版本”。

**根因/原理**：CNPG 的 API 一直是 `v1`，官方说明“同一 API 版本内向后兼容，多数版本可直接升级”；但跨度过大时，CRD 字段、实例管理器协议、默认值可能变化。官方建议顺序升级是为了降低未知风险，不是硬性限制。

**修复前的兼容性核验（本次实际做了）**

- 新 CRD 中仍存在：`maxSyncReplicas`、`minSyncReplicas`、`imageName`、`retentionPolicy`、`barmanObjectStore`、`primaryUpdateStrategy`；
- 1.30.1 支持 K8s 1.36/1.35/1.34（当前 1.35.9）；
- 支持 PG 14–18（当前 16.15）；
- 内置 barmanObjectStore 在 1.30 仍可用（1.31 才移除）；
- 升级前做了即时备份 + 保留 1.22.0 回滚 manifest。

**结果**：直接升级成功。

**经验**：本次是“可接受的一次性跳版”，但**以后不要再次跨这么多 minor**；建议每个 minor 或每两个 minor 跟一次。

---

### 3.5 内置 `barmanObjectStore` 已弃用，1.31 将移除

**现象**：升级到 1.30.1 后，webhook 明确告警：

```text
Native support for Barman Cloud backups and recovery is deprecated and will be
completely removed in CloudNativePG 1.31.0. Found usage in:
spec.backup.barmanObjectStore. Please migrate existing clusters to the new
Barman Cloud Plugin.
```

**根因/原理**：CNPG 从 1.26 起把备份能力迁到 CNPG-I 插件架构，内置实现只是过渡；1.31 会删掉 `spec.backup.barmanObjectStore`。如果不迁移，升级 1.31 时备份配置会失效。

**修复**：迁移到 Barman Cloud Plugin 0.15.1（详见第 4.1 节）。

**验证**：

- Cluster 条件 `ContinuousArchiving=True`；
- sidecar 日志出现 `Archived WAL file`；
- `ObjectStore` 状态识别到历史备份目录：

```json
{"serverRecoveryWindow":{"pg16-ceph":{
  "firstRecoverabilityPoint":"2026-10-09T02:00:13Z",
  "lastSuccessfulBackupTime":"2026-11-08T10:27:51Z"}}}
```

- 插件方式备份 `pg16-ceph-plugin-verify-20261108` 17 秒完成。

---

### 3.6 `primaryUpdateMethod: restart` 导致约 3 分钟停机

**现象**：Operator 升级时，phase 显示 `Primary instance is being restarted without a switchover`，n8n 日志出现约 3 分钟 `ECONNREFUSED 10.111.4.92:5432`，之后自动恢复。

**根因**：Cluster spec 里是 `primaryUpdateMethod: restart`，主库不是“先切到备库再滚动”，而是直接重启主库。

**原理**：

- `switchover`：先把备库提升为主库（秒级），再把旧主库作为备库滚动；
- `restart`：直接停主库、重建 Pod，停机时间 = 关库 + 调度 + 启动 + 恢复。

**修复**：把 `primaryUpdateMethod` 改为 `switchover`（本次已在插件迁移的原子 patch 中完成）。

**验证**：最终 spec：

```text
primaryUpdateMethod = "switchover"
primaryUpdateStrategy = "unsupervised"
```

> 注意：本次插件 sidecar **首次注入**时，即使设置了 `switchover`，1.30 仍会重启主库。这是 1.30 的已知修复逻辑：新 sidecar 还没注入到主库时，无法完成带归档器的干净降级，所以直接重建主库。后续普通滚动会走 switchover。

---

### 3.7 浮动的 PostgreSQL 镜像 tag

**现象**：`imageName: ghcr.io/cloudnative-pg/postgresql:16` 是浮动 tag，下次重启可能被动拉到新的 16.x 构建。

**根因/原理**：tag 会随上游重新发布而移动；生产环境应固定到明确的 minor tag 或 digest。

**修复**：

- 先查当前运行 digest：`sha256:34cd4159...`；
- 查 registry：`16.15` tag 正好指向同一 digest；
- 改为 `ghcr.io/cloudnative-pg/postgresql:16.15`。

> 注意：CNPG **不允许** `imageName` 只写 digest（会报 `Can't use just the image sha as we can't detect upgrades`），必须带 tag。

**验证**：`imageName=ghcr.io/cloudnative-pg/postgresql:16.15`，实际 imageID 与升级前一致，无镜像变更。

---

### 3.8 弃用字段 `maxSyncReplicas` / `minSyncReplicas` / `retentionPolicy`

**现象**：Cluster spec 里有：

```yaml
maxSyncReplicas: 0
minSyncReplicas: 0
backup:
  retentionPolicy: 30d
```

**根因/原理**：

- `maxSyncReplicas` / `minSyncReplicas` 是旧同步复制配置，已由 `spec.postgresql.synchronous` 取代；
- `backup.retentionPolicy` 在插件架构中移到 `ObjectStore.spec.retentionPolicy`。

**修复**：

- `backup.retentionPolicy` → 已移到 `ObjectStore` 的 `30d`；
- `maxSyncReplicas` / `minSyncReplicas` → patch 中已 remove，但 **1.30 的 defaulting webhook 会重新补回 0**（兼容旧 CR）；
- 因此当前 spec 仍能看到这两项 = 0，这是正常的，不需要再处理；等 1.31 移除。

**验证**：

```text
backup = {"target":"prefer-standby"}      # retentionPolicy 已不在
maxSyncReplicas = 0                        # webhook 重新补的默认值
minSyncReplicas = 0
```

---

### 3.9 首次注入 WAL archiver sidecar 必须重启主库

**现象**：插件迁移时 phase 仍是 `Primary instance is being restarted without a switchover`，即使已经设置 `switchover`。

**根因/原理**：Barman Cloud Plugin 以 native sidecar 形式注入每个 PG Pod。已有集群首次启用 `isWALArchiver` 时，主库 Pod 还没有 sidecar；而“干净的 switchover 降级”需要归档器 sidecar 存在，否则可能丢 WAL。CNPG 1.30 的策略是：**直接重建主库 Pod，把 sidecar 注入进去**，然后恢复归档。

**修复/规避**：这是预期行为，不是故障。把插件迁移安排进维护窗口即可；后续滚动会走 `switchover`。

**验证**：迁移后 sidecar 存在且 `restarts=0`，WAL 归档恢复。

---

### 3.10 调试镜像在 m01 拉取失败（Docker Hub 受限）

**现象**：用 `nicolaka/netshoot:latest` 做 hostNetwork 诊断 Pod，在 m01 一直 `Pulling`，无法 Ready。

**根因**：m01 访问 Docker Hub 受限/超时。

**修复/原理**：改用节点上**已经存在**的镜像做诊断：

```bash
quay.io/calico/node:v3.32.2
```

该镜像已由 calico-node DaemonSet 拉取到所有节点，且自带 `iptables`、`ip`、`bash`、`conntrack`，足够做 host 网络诊断。

**经验**：节点级诊断优先用“节点上已有镜像”，不要假设能拉取公网镜像。

---

### 3.11 其他需要知道的默认值变化

1.30 Operator 对 Cluster spec 自动补了以下默认值（正常行为）：

| 字段 | 新值 | 影响 |
|---|---|---|
| `enablePDB` | `true` | 自动创建 `pg16-ceph-primary` PDB，节点 drain 时可能受保护 |
| `postgresql.parameters.wal_level` | `logical` | WAL 体积略增，建议观察 WAL PVC（5Gi） |
| `wal_log_hints` | `on` | 支持 pg_rewind |
| `full_page_writes` | `on` | 正常 |
| `probes.liveness.isolationCheck` | 启用 | 主库隔离检测更严格 |
| `replicationSlots.synchronizeReplicas` | 启用 | 逻辑复制槽自动同步 |
| `primaryLease`（Lease 对象） | 自动创建 | 1.30 的安全主库选举 |

此外，CNPG 集群放在 `cnpg-system` namespace（与 Operator 同 namespace）不是最佳实践，但当前可用；未来可考虑迁到独立 `pg` namespace。

---

## 4. 上一轮“六、后续建议”的落地情况

| # | 建议 | 状态 | 实际动作 |
|---|---|---|---|
| 1 | 升级 1.31 前迁移到 Barman Cloud Plugin | ✅ 已完成 | 安装 plugin 0.15.1，创建 ObjectStore，Cluster 原子切换，ScheduledBackup 改为 plugin |
| 2 | `primaryUpdateMethod` 改为 `switchover` | ✅ 已完成 | 原子 patch 中改为 `switchover` |
| 3 | 固定 PostgreSQL operand 镜像 | ✅ 已完成 | `:16` → `:16.15`（同一 digest） |
| 4 | 清理弃用字段 | ✅ 已完成（部分受 webhook 限制） | 移除 `barmanObjectStore` / `retentionPolicy`；`maxSyncReplicas`/`minSyncReplicas` 被 1.30 重新补 0 |
| 5 | rp_filter 纳入节点初始化 | ✅ 已完成 | m01 持久化；6 节点统一为 2；提供 `enforce-rp-filter.sh` / Ansible / 可选 DaemonSet |

### 4.1 Barman Cloud Plugin 迁移细节

**安装**：`plugin-barman-cloud:v0.15.1` + sidecar `plugin-barman-cloud-sidecar:v0.15.1`，部署在 `cnpg-system`（必须与 Operator 同 namespace）。

**ObjectStore**（`fixes/objectstore-pg16-ceph.yaml`）：

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg16-ceph-store
  namespace: cnpg-system
spec:
  retentionPolicy: "30d"
  configuration:
    destinationPath: s3://pg-backups/
    endpointURL: http://10.0.0.31:7480
    s3Credentials:
      accessKeyId:
        name: pg-backup-s3-creds
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: pg-backup-s3-creds
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
      maxParallel: 2
    data:
      compression: gzip
      jobs: 2
```

**Cluster 原子变更**（`fixes/cluster-plugin-patch.json`）：

```json
[
  {"op":"remove","path":"/spec/backup/barmanObjectStore"},
  {"op":"remove","path":"/spec/backup/retentionPolicy"},
  {"op":"remove","path":"/spec/maxSyncReplicas"},
  {"op":"remove","path":"/spec/minSyncReplicas"},
  {"op":"add","path":"/spec/plugins","value":[{
    "name":"barman-cloud.cloudnative-pg.io",
    "isWALArchiver":true,
    "parameters":{
      "barmanObjectName":"pg16-ceph-store",
      "serverName":"pg16-ceph"
    }
  }]},
  {"op":"replace","path":"/spec/imageName","value":"ghcr.io/cloudnative-pg/postgresql:16.15"},
  {"op":"replace","path":"/spec/primaryUpdateMethod","value":"switchover"}
]
```

**为什么历史备份还能用**：

- 内置配置：`destinationPath: s3://pg-backups/` + `serverName: pg16-ceph`；
- 插件配置：同一 `destinationPath` + 插件参数 `serverName: pg16-ceph`；
- 因此插件看到的仍然是 `s3://pg-backups/pg16-ceph/`，`ObjectStore` 状态直接识别到 2026-10-09 的历史恢复点。

**ScheduledBackup**（`fixes/scheduledbackup-plugin.yaml`）：

```yaml
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

### 4.2 rp_filter 节点初始化

已落地 3 种方式（任选其一，推荐 Ansible）：

| 文件 | 用途 |
|---|---|
| `fixes/99-zz-k8s-rp-filter.conf` | sysctl 持久化配置 |
| `fixes/enforce-rp-filter.sh` | 单节点立即执行 + 持久化 |
| `fixes/ansible-rp-filter.yml` | 纳入节点初始化 Playbook（推荐） |
| `fixes/rp-filter-daemonset.yaml` | 可选：集群内强制新节点生效（常驻 privileged Pod，非首选） |

当前 6 个节点实测：

```text
# 2026-11-11 复核（6 节点一致）：all=0，default/eth0/eth1 仍为 2
m01       all=0 default=2 eth0=2 eth1=2
master01  all=0 default=2 eth0=2 eth1=2
master02  all=0 default=2 eth0=2 eth1=2
worker01  all=0 default=2 eth0=2 eth1=2
worker02  all=0 default=2 eth0=2 eth1=2
worker03  all=0 default=2 eth0=2 eth1=2

# 说明：rp_filter 的实际生效值是 max(all, <iface>)，所以 all=0 + eth*=2 仍等于严格模式(2)。
# 当时表里把 all 也写成 2 —— 与现在的实测不符（也可能当时确实设了 all=2，后被改成 0）。
```

---

## 5. 最终配置清单

### Cluster（关键字段）

```yaml
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:16.15
  primaryUpdateMethod: switchover
  primaryUpdateStrategy: unsupervised
  enablePDB: true
  backup:
    target: prefer-standby
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: pg16-ceph-store
        serverName: pg16-ceph
```

### 组件版本

| 组件 | 版本 |
|---|---|
| CNPG Operator | 1.30.1 |
| Barman Cloud Plugin | 0.15.1 |
| Plugin sidecar | 0.15.1 |
| PostgreSQL | 16.15 |
| cert-manager | v1.19.4（插件 TLS 依赖） |

### 备份清单

```text
pg16-ceph-daily-full-20261108020000   barmanObjectStore   completed
pg16-ceph-pre-upgrade-20261108        barmanObjectStore   completed
pg16-ceph-post-upgrade-20261108       barmanObjectStore   completed
pg16-ceph-before-plugin-20261108      barmanObjectStore   completed
pg16-ceph-plugin-verify-20261108      plugin              completed
```

---

## 6. 验证结果

| 检查项 | 结果 |
|---|---|
| Operator / Plugin Ready | 1/1，restarts=0 |
| 集群 | 2/2 `Cluster in healthy state` |
| 主库 | `pg_is_in_recovery=f` |
| 备库 | `pg_is_in_recovery=t` |
| 复制延迟 | receive = replay = `E/B801DFA0` |
| 数据 | n8n 库 63 张表 |
| WAL 归档 | `ContinuousArchiving=True`，sidecar 日志 `Archived WAL file` |
| 插件备份 | completed，17 秒 |
| ObjectStore | 识别历史恢复点与最新备份时间 |
| ScheduledBackup | `method=plugin` |
| 应用 | n8n `Database connection recovered` |
| 全集群异常 Pod | 仅历史 CI TaskRun Pod（与本次无关） |
| Operator/Plugin 错误 | 最近 5 分钟 0 条 error/warning |

---

## 7. 回滚方案

### 7.1 回滚插件迁移（回到内置 barmanObjectStore）

```bash
# 使用迁移前快照
kubectl apply -f /root/k8s-postmortem/fixes/cluster-before-plugin.yaml
kubectl apply -f /root/k8s-postmortem/fixes/scheduledbackup-before-plugin.yaml
```

> S3 上的数据不会丢；内置实现与插件使用的是同一路径。回滚后 sidecar 会被移除，Pod 会再滚动一次。

### 7.2 回滚 Operator（1.30.1 → 1.22.0，不推荐）

```bash
kubectl apply --server-side --force-conflicts -f /tmp/cnpg-upgrade/cnpg-1.22.0.yaml
```

> CRD 已升级，仅回滚 Operator 镜像存在兼容风险；优先用 7.1 或从备份恢复。

### 7.3 灾难恢复

- 每日 02:00 全量备份 + 连续 WAL 归档；
- 当前可恢复起点：`2026-10-09T02:00:13Z`；
- 恢复方式：新建 Cluster，`bootstrap.recovery.source` 指向 `ObjectStore`，`serverName: pg16-ceph`。

---

## 8. 运维检查清单 / 后续 TODO

### 必做

- [x] 迁移到 Barman Cloud Plugin（1.31 前）
- [x] `primaryUpdateMethod=switchover`
- [x] 固定 PG 镜像 tag
- [x] 清理 `barmanObjectStore` / `retentionPolicy`
- [x] rp_filter 统一并持久化
- [ ] **做一次真实的 PITR 恢复演练**（新建临时 Cluster，从插件备份恢复到指定时间点）
- [ ] 更新监控 Dashboard/告警：内置指标 `cnpg_collector_*` → 插件指标 `barman_cloud_cloudnative_pg_io_*`
- [ ] 检查 WAL PVC（5Gi）使用率：1.30 默认 `wal_level=logical`，WAL 会略增
- [ ] 把 rp_filter 配置合并进节点初始化 Playbook（`fixes/ansible-rp-filter.yml`）

### 建议

- [ ] 把 CNPG 集群从 `cnpg-system` 迁到独立 namespace（如 `pg`）
- [ ] 给插件镜像 / Operator 镜像固定版本并纳入 GitOps
- [ ] 评估 `enablePDB` 对节点 drain 的影响
- [ ] 后续 CNPG 升级不要再次跨 8 个 minor；建议每 1–2 个 minor 跟一次
- [ ] 清理历史 `Backup` CR（`method: barmanObjectStore` 的记录可保留审计，也可归档）
- [ ] 关注 1.31 发布说明，确认插件版本兼容矩阵后再升级

---

## 9. 补充问答

### 9.1 PostgreSQL 16 过期了吗？

**没有。** 截至 2026-11-08：

| 版本 | 发布日期 | EOL | 当前最新 minor |
|---|---|---|---|
| 18 | 2025-09-25 | 2030-11-14 | 18.6 |
| 17 | 2024-09-26 | 2029-11-08 | 17.11 |
| **16** | **2023-09-14** | **2028-11-09** | **16.15**（2026-08-10） |
| 15 | 2022-10-13 | 2027-11-11 | 15.19 |
| 14 | 2021-09-30 | **2026-11-12（4 天后）** | 14.24 |

结论：

- PG16 还能支持约 **2 年**，不是过期版本；
- 本集群运行的 **16.15 就是当前最新 minor**；
- 真正即将 EOL 的是 **PG14（2026-11-12）**，与本集群无关；
- CNPG 1.30 官方支持 PG 14–18，PG16 完全在支持矩阵内。

**是否需要升级到 PG17/18？**

不紧急。建议 2027 年再规划 major upgrade，届时用 CNPG 的 in-place major upgrade（`pg_upgrade`）能力，安排维护窗口、全量备份和恢复演练。现在没有必要为了“版本新”而承担一次大版本升级风险。

### 9.2 为什么 Pod 是 `-3` / `-4`，而不是 `-1` / `-2`？

**你的记忆对了一半：StatefulSet 的 Pod 确实是 `-0`、`-1` 递增序号；但 CloudNativePG 不使用 StatefulSet。**

CNPG 官方 FAQ 明确写着：

> CloudNativePG does not rely on `StatefulSet` resources, and instead manages the underlying PVCs directly...

CNPG 的 Pod 后缀不是 StatefulSet ordinal，而是 **instance serial**（实例序号），记录在：

```yaml
metadata:
  annotations:
    cnpg.io/nodeSerial: "3"   # 或 "4"
```

当前实际状态：

```text
pg16-ceph-3  nodeSerial=3  role=primary
pg16-ceph-4  nodeSerial=4  role=replica
PVC: pg16-ceph-3, pg16-ceph-3-wal, pg16-ceph-4, pg16-ceph-4-wal
status.latestGeneratedNode=4
```

**为什么是 3 和 4：**

- 集群是 219 天前用 CNPG 1.22 创建的；
- 1.22 采用 **全局单调递增计数器**（`status.latestGeneratedNode`）分配序号；
- 每次创建“新实例”（扩缩容、实例被删除后重建等）都会 +1，释放的序号不会复用；
- 经过多次实例重建，序号走到了 4，当前保留的是 3 和 4；
- PVC 也是按序号命名的，所以 Pod/PVC 一起是 3/4。

**CNPG 1.30 已经改进了这个行为：**

> Instance serial numbers are now assigned by reusing the lowest free slot among existing instance names, instead of always incrementing a global counter. Pod and PVC names stay stable across instance recreation... and serials freed by deleted instances are reclaimed. `status.latestGeneratedNode` is deprecated.

也就是说：

- 已经存在的 3/4 **不会改名**（Pod/PVC 名称保持稳定是好事）；
- 以后新建实例会**复用最小空闲序号**（例如 1/2 空着就可能用 1/2）；
- 序号不连续是正常现象，不是故障。

**需要改成 1/2 吗？**

不需要。序号只是实例标识，不影响功能、性能、备份或高可用。要“规范化”成 1/2，只能重建 PVC/实例（涉及数据复制），收益为零、风险不小，不建议做。

**为什么 CNPG 不用 StatefulSet：**

- StatefulSet 的 `0..N-1` 有序生命周期不适合“主库/备库角色”；
- CNPG 需要独立控制每个实例的 Pod、PVC 重挂载、failover、switchover、滚动更新；
- CNPG 直接管理 PVC，并用自定义 Pod Controller 管理实例生命周期（官方 “Custom Pod Controller” 文档有详细说明）。

---

## 附录 A：本次落地的文件

```text
/root/k8s-postmortem/
├── 2026-11-08-cnpg-upgrade-postmortem.md   # 本文档
└── fixes/
    ├── 99-zz-k8s-rp-filter.conf            # sysctl 持久化
    ├── enforce-rp-filter.sh                 # 单节点执行脚本
    ├── ansible-rp-filter.yml                # 节点初始化 Playbook
    ├── rp-filter-daemonset.yaml             # 可选：集群内强制
    ├── objectstore-pg16-ceph.yaml           # ObjectStore
    ├── cluster-plugin-patch.json            # Cluster 原子 patch
    └── scheduledbackup-plugin.yaml          # ScheduledBackup
```

升级过程资产（临时）：

```text
/tmp/cnpg-upgrade/
├── cnpg-1.22.0.yaml                  # 回滚 manifest
├── cnpg-1.30.1.yaml                  # 本次升级 manifest
├── plugin-barman-cloud-0.15.1-release.yaml
├── backup-before/                    # CRD / Cluster / RBAC / webhook 快照
└── cluster-plugin-patch.json
```

---

## 附录 B：关键命令速查

```bash
# 1. 检查所有节点 rp_filter
for p in $(kubectl -n kube-system get pods -l k8s-app=calico-node -o name); do
  n=$(kubectl -n kube-system get $p -o jsonpath='{.spec.nodeName}')
  echo -n "$n: "
  kubectl -n kube-system exec $p -c calico-node -- \
    sh -c 'for i in all default eth0 eth1; do echo -n "$i="; cat /proc/sys/net/ipv4/conf/$i/rp_filter; echo -n " "; done; echo'
done

# 2. 检查 webhook 链路
kubectl -n cnpg-system annotate cluster pg16-ceph check=ok --dry-run=server

# 3. 检查插件注册
kubectl -n cnpg-system logs deploy/cnpg-controller-manager | grep 'Registered plugin'

# 4. 检查 ObjectStore
kubectl -n cnpg-system get objectstore pg16-ceph-store -o yaml

# 5. 检查 sidecar
kubectl -n cnpg-system get pod pg16-ceph-3 \
  -o jsonpath='{range .spec.initContainers[*]}{.name} {.image}{"\n"}{end}'

# 6. 插件方式备份
kubectl -n cnpg-system create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-plugin-backup
  namespace: cnpg-system
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: pg16-ceph
EOF

# 7. 查看恢复窗口
kubectl -n cnpg-system get objectstore pg16-ceph-store -o jsonpath='{.status}'
```

---

**结论：本次升级与加固全部完成，集群 2/2 healthy，备份链路已切到插件并验证通过。唯一还需要补的是“真实 PITR 恢复演练”和监控指标切换。**
