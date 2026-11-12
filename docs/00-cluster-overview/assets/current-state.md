# 当前状态：唯一数字源

> **采集方式**：`python3 docs/00-cluster-overview/assets/collect_current_state.py`（只读 kubectl）
> **采集时间**：2026-11-11 23:5x CST，集群 v1.35.9
> **性质**：快照。集群会继续变化，本文随时可能落后于现实；落后时**以重跑脚本的输出为准**。

## 0. 这一页的规矩（读之前先看）

1. **全仓库唯一数字源**。凡"现在是多少 / 现在是什么版本 / 现在有几个"——只在这里改数字，
   其他章节一律写「见 [current-state](../../00-cluster-overview/assets/current-state.md)」或直接链接到本文的锚点。
2. 其他章节里的表格可以保留（它们讲**结构**：谁连谁、哪个组件干什么），但**不要在里面填会变的数字**。
   已经在章节里写死的数字如果与本文冲突，以本文为准。
3. 更新方式：重跑采集脚本，替换下面 `BEGIN GENERATED` 与 `END GENERATED` 之间的内容；
   手写部分（§8 之后）只在拓扑/配置变化时才改，并追加一行到 §12 变更历史。
4. 历史快照不删：`notes/` 里带"历史快照"状态头的文档保持原值不动；旧版本文（2026-11-10 的原始 dump）
   留在 [current-state-raw-20261110.md](current-state-raw-20261110.md)，用于对比"当时是什么样"。

常用锚点：`#1-版本`、`#2-节点与容量`、`#3-对象计数`、`#4-组件版本`、`#5-prometheus-运行态`、
`#6-存储`、`#7-入口`、`#8-ceph`、`#9-外部宿主机`、`#10-入口路由与鉴权`、`#11-保留期与告警链路`。

<!-- BEGIN GENERATED -->

### 1. 版本

| 组件 | 版本 |
|---|---|
| Kubernetes | server v1.35.9 / client v1.35.9 |

### 2. 节点与容量

| 节点 | 角色 | kubelet | runtime | OS | CPU/内存 |
|---|---|---|---|---|---|
| m01 | control-plane | v1.35.9 | 2.3.2 | Rocky 9.6 | 4C / 5.5Gi (allocatable 4023428Ki) |
| master01 | control-plane | v1.35.9 | 2.3.2 | Ubuntu 22.04.5 | 4C / 5.8Gi (allocatable 4810024Ki) |
| master02 | control-plane | v1.35.9 | 2.3.2 | Ubuntu 22.04.5 | 4C / 3.8Gi (allocatable 3116336Ki) |
| worker01 | worker | v1.35.9 | 2.3.2 | Ubuntu 22.04.5 | 6C / 9.7Gi (allocatable 8401696Ki) |
| worker02 | worker | v1.35.9 | 2.3.2 | Ubuntu 22.04.5 | 6C / 9.7Gi (allocatable 8401692Ki) |
| worker03 | worker | v1.35.9 | 2.3.2 | Ubuntu 22.04.5 | 4C / 7.8Gi (allocatable 6350120Ki) |

### 3. 对象计数

| 对象 | 数量 |
|---|---|
| namespaces | 29 |
| pods | 138 |
| deployments | 74 |
| statefulsets | 12 |
| daemonsets | 7 |
| services | 107 |
| cronjobs | 1 |
| PVC | 17 |
| PV | 17 |
| StorageClass | 2 |
| ServiceMonitor | 26 |
| PodMonitor | 16 |
| PrometheusRule | 43 |
| IngressRoute | 19 |
| ArgoCD Application | 31 |

### 4. 组件版本

| 层 | 组件 | 版本 |
|---|---|---|
| CNI | Cilium | v1.20.4 |
| 数据面 | kube-proxy | 已移除（Cilium KPR 取代） |
| 运行时 | containerd | 2.3.2 |
| etcd | etcd | 3.6.6-0 |
| DNS | CoreDNS | v1.13.1 |
| 监控 | Prometheus | v3.11.2 |
| 监控 | Grafana | 12.4.3 |
| 监控 | Alertmanager | v0.32.0 |
| 日志 | Loki | 3.6.7 |
| 追踪 | Tempo | 3.0.3 |
| 采集 | Alloy | v1.20.0 |
| GitOps | ArgoCD | v3.5.3 |
| 入口 | Traefik | v3.7.17 |
| 数据库 | CNPG operator | v0.15.1 |
| 存储 | Ceph-CSI RBD | v3.18.2 |

### 5. Prometheus 运行态

| 指标 | 值 |
|---|---|
| alerting rules | 51 组 / 248 条 |
| recording rules | 16 组 / 94 条 |
| 规则求值错误 | 0 |
| target | 115 个，up 115 |
| retention.time | 15d |
| retention.size | 25GiB |
| firing | InfoInhibitor, Watchdog |

### 6. 存储

| 项 | 值 |
|---|---|
| StorageClass | ceph-rbd-sc, nfs-sc |
| PV 总数 / 非 Bound | 17 / 0 |
| PVC 总数 / 非 Bound | 17 / 0 |
| 默认 SC 回收策略 | ceph-rbd-sc = Retain（删除后需手工清 RBD 镜像） |

### 7. 入口

| 项 | 值 |
|---|---|
| Traefik Service 类型 | LoadBalancer |
| Traefik LB 地址 | 10.0.0.252 |
| API VIP | 10.0.0.168 |

<!-- END GENERATED -->

### 8. Ceph

| 项 | 值（`ceph -s`，2026-11-11） |
|---|---|
| 集群 ID | `594e535e-d82c-11f0-afa7-bc24112b746f` |
| 版本 / 健康 | **18.2.8 reef** / `HEALTH_OK` |
| mon | 3 个（ceph-01/02/03 = `10.0.0.31/41/51`），quorum 正常 |
| mgr | active `ceph-02`，standby `ceph-01`（**ceph-03 无 mgr**，ScrapeConfig 只抓前两台） |
| OSD | 6 个（每台 VM 2 个，class `hdd`），6 up / 6 in |
| pools / pgs | 15 pools / 465 pgs，全 `active+clean` |
| 对象 / 容量 | 19.88k objects / 32 GiB；**98 GiB used，82 GiB / 180 GiB avail** |
| RGW | 2 daemons active（`http://10.0.0.31:7480`），bucket 无 lifecycle 规则 |
| 备份 | CNPG barman → 同一套 Ceph 的 S3（`s3://pg-backups/`），**同集群，不构成容灾** |

### 9. 外部宿主机

| 宿主机 | 地址 | 角色 | 承载 |
|---|---|---|---|
| Proxmox `teacher` | `192.168.67.156` / `10.0.0.1`（同机双网段） | PVE 8.4.13，内核 6.8.12-15-pve，80 线程 / 62 GiB | K8s 6 节点（VM 119–124）、Ceph 3 节点（VM 116/117/118 = nfs01/backup/db01） |
| Windows `SYZX-HY2-TX` | `192.168.67.110` | Windows 10 Pro + Hyper-V | `ubuntu01`（GitLab 19.5.0，201，2C/8G）、`ubuntu02`（Harbor 2.14.5，202，2C/6G）、`ubuntu03`(Off)、`kali`(Off) |

PVE 存储：`local-lvm` thin，PE **4 MiB**，Free PE 4096 = **16 GiB**；根文件系统 94 G / 已用 29 G（32%）。

### 10. 入口路由与鉴权

| 入口 | IngressRoute 后端 | 鉴权方式 |
|---|---|---|
| `argocd.*` | `argocd-server` | ArgoCD 自带 OIDC/Dex（**不过 oauth2-proxy**） |
| `grafana.*` | `prometheus-grafana` | Grafana 原生 `auth.generic_oauth`（**不过 oauth2-proxy**） |
| `hubble.*` | `oauth2-proxy-hubble` | oauth2-proxy（反向代理）+ Traefik `basicAuth` 中间件 |
| `alloy.*` | `oauth2-proxy-alloy` | 同上 |
| `tekton.*` | `oauth2-proxy-tekton` | 同上 |
| `traefik-xyz.*` | `oauth2-proxy-traefik` | 同上 |
| `prometheus.*` | `prometheus-operated` | 无（内网） |

> 关键点：oauth2-proxy 是**反向代理模式**（IngressRoute 的服务直接写 `oauth2-proxy-<host>`），
> 不是 ForwardAuth；ArgoCD 与 Grafana 走各自的原生 OIDC，不在 oauth2-proxy 后面。

### 11. 保留期与告警链路

| 信号 | 组件 | 有效保留 | 备注 |
|---|---|---|---|
| Metrics | Prometheus v3.11.2 | **15d / 25GiB** | 本地 PVC（`ceph-rbd-sc`） |
| 告警 | Alertmanager v0.32.0 | 120h | 本地 PVC |
| Logs | Loki 3.6.7 | 120h | Ceph RGW，bucket 无 lifecycle |
| Traces | Tempo 3.0.3 | 120h | `tempo3-config` 的 `block_retention` |

告警接收器：`n8n-webhook`（集群内 `http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts`）、
`wecom`（企业微信群机器人）。**没有 SMTP**，`default-email` 存在但无 route 引用。
抑制规则 3 条（InfoInhibitor / 同 namespace warning / Node 级联）。

### 12. 变更历史（只记影响"数字"的改动）

| 日期 | 改了什么 | 依据 |
|---|---|---|
| 2026-11-10 | 本文首版（原 `current-state.md` 原始 dump） | 存档为 `current-state-raw-20261110.md` |
| 2026-11-11 | 改为"结构化 + 生成式"：数字由 `collect_current_state.py` 产出，手写部分只留拓扑/配置 | 本次审计第三轮 |
| 2026-11-11 | Ceph ScrapeConfig 收敛到 ceph-01/02（ceph-03 无 mgr）；`ceph_*` 1090 序列 | platform-gitops + live patch |
| 2026-11-11 | 告警规则 CNI 家族去重，规则 250 → **248**；n8n webhook 改回集群内 | platform-gitops `742e8e8` / `eca603e` |
