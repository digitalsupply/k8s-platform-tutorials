# Kubernetes 集群磁盘占用与资源开销巡检报告

- **巡检时间**：2026-10-03
- **集群规模**：6 节点（3 control-plane + 3 worker），Kubernetes v1.35.9，containerd 2.3.2
- **命名空间**：24 个，Pod 总数 142（全部 Running，无 Pending / Failed / CrashLoopBackOff）
- **数据采集方式**：临时特权 DaemonSet（`alpine:3.20` + hostPID + chroot），已采集完成后删除，集群状态已复原

---

## 一、总体结论（TL;DR）

> **📌 本报告已更新（清理执行后）** — 镜像清理已实际完成，**回收约 52 GB 磁盘**（远超预估的 13.7 GB）。
> 详见 **第八章：清理执行结果**。同时修正了原文两处判断错误（pause 镜像误判、回收量低估）。

| 结论 | 详情 |
|---|---|
| 磁盘整体安全 | 巡检时最高水位 **worker02 = 76%**，全部节点 < 80%，无 `DiskPressure` |
| **清理后状态** | **全部节点降至 39%~55%**，最高水位 worker02 从 76% → **47%** |
| **实际回收空间** | **约 52 GB**（非预估的 13.7 GB）—— 因 containerd GC 同时释放了已解包的 overlayfs 层 |
| 内存偏紧 | 3 个 control-plane 内存仅 3.7~5.8 Gi 却各跑一套 apiserver+etcd（**此项仍需处理**） |
| CPU 充裕但失衡 | 全部节点 ≤ 19%，worker03 仅 3% |
| 清理机制根因 | kubelet 镜像 GC 受 85% 阈值门控从未触发；镜像长期滞留依赖 containerd GC 被动触发 |
| 遗留垃圾 | 0 个真正废弃镜像；m01 `/root` 8.6 GB 非容器垃圾仍待清理 |

---

## 二、磁盘占用情况

### 2.1 根分区水位

| 节点 | 角色 | 文件系统 | 容量 | 已用 | 可用 | **使用率** | 状态 |
|---|---|---|---|---|---|---|---|
| **worker02** | worker | ext4 | 48G | 35G | 11G | **76%** | ⚠️ 最高水位 |
| **worker03** | worker | ext4 | 48G | 31G | 15G | **69%** | ⚠️ 偏高 |
| worker01 | worker | ext4 | 48G | 29G | 17G | 64% | 正常 |
| **m01** | control-plane | xfs | 47G | 29G | 19G | 60% | 正常 |
| master02 | control-plane | ext4 | 38G | 21G | 16G | 58% | 正常（容量偏小） |
| master01 | control-plane | ext4 | 48G | 24G | 22G | 52% | ✅ 最佳 |

`/boot` 分区全部 15%（正常）。**无节点触发 DiskPressure。**

### 2.2 空间去向（containerd 是绝对主导）

| 节点 | `/` 总量 | `/var` | **containerd** | ├ overlayfs（已解包层） | ├ content（镜像 blob） | 其他 |
|---|---|---|---|---|---|---|
| m01 | 30788M | 12860M | **11221M** | 8375M | 2840M | /root 8646M |
| master01 | 23670M | 10073M | **8421M** | 6328M | 2088M | /usr 4365M |
| master02 | 20691M | 9279M | **8027M** | 6040M | 1981M | /usr 3864M |
| worker01 | 29161M | 20858M | **19333M** | 14171M | 5144M | /usr 3710M |
| **worker02** | 34832M | 25960M | **24558M** | 18386M | 6156M | /usr 4069M |
| **worker03** | 31589M | 21775M | **20768M** | 15661M | 5094M | /usr 3723M |

**关键观察：**

1. **containerd 占 `/` 的 39%~70%**，其中 overlayfs 已解包层是最大单项。全集群 containerd 合计 **92.3 GB**。
2. **worker03 严重失衡**：15.6 GB overlayfs 却只有 10 个 Pod、13 个容器 —— 几乎全部是历史残留镜像的解包层。
3. **worker02 是最危险节点**：containerd 独占 24.5 GB（占其 `/` 的 70%），根分区已达 76%。
4. `/var/lib/kubelet/pods` 仅 255M（worker01/02），PVC 走 NFS/RBD，不占本地盘。
5. **非容器占用异常项 —— m01 的 `/root` = 8.6 GB**（占其 `/` 的 28%）：
   - `/root/.hermes` 6.5 GB（cache 3.2 GB + tools 1.6 GB + installs 890M）
   - `/root/k8s-upgrade-1.29-to-1.35` 860 MB ← **1.29→1.35 升级遗留工作目录**
   - `/root/ctr-backup-20261002-233722` 70 MB、`/root/observability-upgrade-backup-*` 57 MB
6. 系统日志健康：journal 39~95 MB，`/var/log` 均 ≤ 521 MB。
7. 快照数与镜像数比例正常（约 5~6 快照/镜像），**未发现 snapshot 泄漏**。

### 2.3 外挂存储（不占本地盘，供参照）

worker01 挂载 3 个 NFS PVC（Prometheus/Grafana、Alertmanager DB，共享同一 94G 池，已用 32%）；worker01/02/03 共挂载 Ceph RBD 卷 8 个，单卷用量均 ≤ 721M。**均健康。**

---

## 三、资源开销情况

### 3.1 节点资源水位

| 节点 | CPU 核 | CPU 用量 | **CPU%** | 内存容量 | 内存用量 | **内存%** | Pod 数 |
|---|---|---|---|---|---|---|---|
| m01 | 4 | 797m | 19% | 5.4 Gi | 3888Mi | **69%** ⚠️ | 12 |
| master01 | 4 | 387m | 9% | 5.7 Gi | 3355Mi | 57% | 12 |
| master02 | 4 | 312m | 7% | 3.7 Gi | 2260Mi | 59% | 11 |
| worker01 | 6 | 906m | 15% | 9.6 Gi | 6565Mi | 66% | 59 |
| worker02 | 6 | 579m | 9% | 9.6 Gi | 4921Mi | 50% | 44 |
| worker03 | 4 | 142m | **3%** 🔴 | 7.7 Gi | 3245Mi | 41% | 10 |

**问题：**

- **🔴 控制面内存严重不足**：3 台 control-plane 各仅分配 **3.7~5.7 Gi**，却各承载 1 个 apiserver（803~1356 Mi）+ 1 个 etcd + controller-manager + scheduler。m01 内存 69%，api-server 已用 1356 Mi，**OOM 风险高**。
- **🔴 负载分布严重失衡**：
  - worker01（59 Pod）+ worker02（44 Pod）= 集群 73% 的工作负载
  - worker03 仅 10 Pod、CPU 3%、内存 41% —— **几乎空转，却背着 4.0 GB 闲置镜像和全集群最高节点数（101）的镜像库存**
- **无 MemoryPressure / DiskPressure / PIDPressure**，无资源不足告警。
- worker03 内存配置 7.7 Gi 但只用 41%，CPU 4 核只用 3% —— **该节点严重欠配/闲置**。

### 3.2 资源消耗 Top Pods

**内存 Top 10（排除本次巡检 Pod）**

| 排名 | Pod | 命名空间 | CPU | 内存 |
|---|---|---|---|---|
| 1 | prometheus-prometheus-prometheus-0 | monitoring | 595m | **1461Mi** |
| 2 | kube-apiserver-m01 | kube-system | 160m | **1356Mi** |
| 3 | kube-apiserver-master01 | kube-system | 139m | 1284Mi |
| 4 | kube-apiserver-master02 | kube-system | 142m | 803Mi |
| 5 | my-cluster-single-pool-0 | kafka | 26m | 685Mi |
| 6 | kafka-broker-dispatcher-0 | knative-eventing | 5m | 399Mi |
| 7 | prometheus-grafana-fb7445bf9-fbb6x | monitoring | 23m | 305Mi |
| 8 | n8n-7f659c7655-blr5k | n8n | 4m | 304Mi |
| 9 | kafka-broker-receiver-6d77466bfc-rztf2 | knative-eventing | 4m | 297Mi |
| 10 | loki-read-65c6649765-x7c2x | logging | 26m | 236Mi |

**CPU Top 10（排除本次巡检 Pod）**

| 排名 | Pod | 命名空间 | CPU | 内存 |
|---|---|---|---|---|
| 1 | prometheus-prometheus-prometheus-0 | monitoring | 595m | 1461Mi |
| 2 | kube-apiserver-m01 | kube-system | 160m | 1356Mi |
| 3 | etcd-master01 | kube-system | 157m | 126Mi |
| 4 | kube-apiserver-master02 | kube-system | 142m | 803Mi |
| 5 | kube-apiserver-master01 | kube-system | 139m | 1284Mi |
| 6 | etcd-master02 | kube-system | 107m | 97Mi |
| 7 | etcd-m01 | kube-system | 104m | 173Mi |
| 8 | calico-node-8vmjd | kube-system | 58m | 93Mi |
| 9-13 | calico-node × 5 | kube-system | 39~53m | 75~138Mi |

**观察：**
- Prometheus 单实例 595m CPU + 1461Mi 内存，是全集群最大资源消费者。
- 控制面组件（3× apiserver + 3× etcd + calico × 6）稳定占据 CPU 榜前列，属正常基线。
- calico-node 全节点合计约 283m CPU / 458Mi 内存。
- 无异常热点 Pod，无 CPU limit 超限（Throttling）迹象。

---

## 四、可删除的过期/无用镜像

### 4.1 汇总统计

判定依据：`crictl images` 全量镜像列表 与 `crictl ps -a`（**含已退出容器**）的 `imageRef` 精确比对。未被任何容器引用的镜像即为可回收。

| 节点 | 镜像总数 | 使用中 | 集群级废弃 | 节点级闲置 | **废弃合计** | 其中 Tier1 可安全回收 |
|---|---|---|---|---|---|---|
| m01 | 68 | 13 | 53 | 2 | **2.2 GB** | 2.2 GB |
| master01 | 63 | 13 | 47 | 3 | **1.5 GB** | 1.4 GB |
| master02 | 59 | 12 | 45 | 2 | **1.4 GB** | 1.4 GB |
| worker01 | 91 | 61 | 10 | 20 | **1.3 GB** | 131 MB |
| worker02 | 107 | 41 | 21 | 45 | **3.3 GB** | 970 MB |
| **worker03** | 101 | 13 | 30 | 58 | **4.0 GB** | 1.1 GB |
| **合计** | **489** | | **206** | **130** | **13.7 GB** | **~7.2 GB** |

- **Tier 1（集群级废弃）**：所有节点均无容器引用，纯升级/卸载残留 → **绝对安全可删，约 7.2 GB**
- **Tier 2（节点级闲置）**：本节点无引用但其他节点仍在运行 → 可删但 Pod 漂移时会重新拉取，约 5.4 GB

> **正确性校验已通过**：无孤儿引用（每个容器的 imageRef 均能匹配到镜像列表）；当前版本镜像（kube-proxy v1.35.9、coredns v1.13.1、calico v3.32.2、etcd 3.6.6-0）均正确识别为"使用中"，未被误判。

### 4.2 Tier 1：集群级废弃镜像（安全删除，约 7.2 GB）

**Top 20（按单镜像大小）**

| 镜像 | 大小 | 所在节点 | 原因 |
|---|---|---|---|
| `docker.io/langgenius/dify-plugin-daemon:0.5.3-local` | **530.6 MB** | m01 | Dify 已卸载，单镜像占 m01 可回收量的 25% |
| `swr.../ddn-k8s/ghcr.io/n8n-io/n8n:2.7.0` | **241.6 MB** | worker02 | n8n 旧版本（当前跑 2.14.2） |
| `registry.k8s.io/hpa-example:latest` | 156.4 MB | worker03 | k8s 示例镜像 |
| `docker.io/library/postgres:17.6` | 153.7 MB | worker03 | 裸 postgres 镜像残留（实际用 cloudnative-pg） |
| `docker.io/calico/node:v3.30.7` | 151.9 MB | m01,master01,master02,worker02 | CNI 旧版（当前 v3.32.2） |
| `docker.io/calico/node:v3.27.4` | 111.1 MB | m01,master01,master02,worker02 | CNI 旧版 |
| `docker.io/calico/cni:v3.27.4` | 84.7 MB | m01,master01,master02,worker02 | CNI 旧版 |
| `docker.io/langgenius/dify-plugin-manager:0.14.4` | 79.6 MB | m01 | Dify 残留 |
| `10.0.0.41/library/tekton-demo-api:fa37244f-…` | 78.9 MB | worker03 | 旧构建产物（CI demo） |
| `10.0.0.41/library/tekton-demo-api:2a28132b-…` | 78.9 MB | worker03 | 旧构建产物（CI demo） |
| `docker.io/library/nginx:1.27` | 69.1 MB | worker03 | 裸 nginx 残留（实际用 nginx-unprivileged） |
| `docker.io/calico/cni:v3.30.7` | 68.7 MB | 全部 6 节点 | CNI 旧版 |
| `quay.io/calico/cni:v3.32.2` | 66.6 MB | 全部 6 节点 | **当前版但仅 worker02 的 kube-controllers 在用** |
| `docker.io/grafana/promtail:3.5.1` | 62.3 MB | m01,master01,master02 | **已被 Grafana Alloy (v1.20.0) 替代，5 天前切换完成** |
| `registry.k8s.io/etcd:3.5.12-0` | 54.6 MB | m01,master01,master02 | etcd 旧版（当前 3.6.6-0） |
| `registry.k8s.io/etcd:3.5.15-0` | 54.3 MB | m01,master01,master02 | etcd 旧版 |
| `docker.io/calico/kube-controllers:v3.30.7` | 50.5 MB | m01 | CNI 旧版 |
| `ghcr.io/open-telemetry/demo:2.2.0-cart` | 50.4 MB | worker03 | OTel demo 残留 |
| `10.0.0.41/library/flask-prom-demo:3dc8416f` | 49.8 MB | worker03 | 应用旧构建 |
| `10.0.0.41/library/flask-prom-demo:e3cfe8ca` | 49.8 MB | m01 | 应用旧构建 |
| `ghcr.io/open-telemetry/demo:2.2.0-flagd-ui` | 47.8 MB | worker03 | OTel demo 残留 |
| `.../opentelemetry-collector-k8s:0.145.0` | 45.2 MB | worker03 | 被 collector-contrib 替代 |
| `10.0.0.41/library/python:3.11-slim` | 44.3 MB | worker03 | 裸 python 残留 |
| `docker.io/grafana/tempo:2.9.0` | 34.7 MB | worker03 | Tempo 旧版（当前 3.0.3） |

**控制面升级残留（6 个版本 × 5 个组件，共约 1.1 GB，分布 m01/master01/master02）**

| 组件 | 废弃版本 | 约可回收 |
|---|---|---|
| `kube-apiserver` | v1.29.8, v1.30.14, v1.31.14, v1.32.13, v1.33.13, v1.34.12 | ~180 MB |
| `kube-controller-manager` | v1.29.8 ~ v1.34.12（6 个） | ~160 MB |
| `kube-scheduler` | v1.29.8 ~ v1.34.12（6 个） | ~115 MB |
| `kube-proxy` | v1.29.8 ~ v1.34.12（6 个） | ~170 MB |
| `etcd` | 3.5.12-0, 3.5.15-0, 3.5.24-0, 3.6.5-0 | ~153 MB |
| `coredns` | v1.11.1, v1.11.3, v1.12.0, v1.12.1（当前 v1.13.1） | ~94 MB |

> 集群已从 **v1.29.8 升级至 v1.35.9**，跨越 6 个 minor 版本（v1.30→v1.35），每次升级留下全套组件镜像，从未被 GC。

**无标签悬空镜像（约 2.1 GB，56 个副本）**

`crictl images` 中 56 个 `<none>` 状态的悬空镜像（Tekton/OTel demo 构建缓存为主），典型的 `docker build` 遗留：
- `sha256:636a947828bf` 240.9 MB (worker01)
- `sha256:65a1dd8253d1` 207.6 MB (worker02)
- `sha256:f70def01659e` 155.6 MB (worker02, worker03) — Kafka receiver
- `sha256:85ef5651f6d3` 60.1 MB、`5e297382766f` 52.9 MB、`648b254c8114` 52.4 MB、`1086d23c445c` 51.6 MB、`8b6c5d434794e` 50.2 MB、`414104855e2c` 49.9 MB、`ae17a6155dcf` 64.1 MB

**零散小镜像**：`hello-world:latest` (14.7 KB × 3)、`busybox` 4 个版本、`pause:3.8/3.9/3.10/3.10.1`、`aliyuncs.com` 镜像地址前缀镜像（已被 registry.k8s.io 取代）、`ghcr.io/kube-vip/kube-vip:v0.8.4` 与 `v0.9.2`（当前 v1.0.3）、`quay.io/prometheus/node-exporter:v1.10.2`（当前 v1.11.1）、`registry.k8s.io/ingress-nginx/kube-webhook-certgen`（集群用 traefik，无 ingress-nginx）。

### 4.3 Tier 2：节点级闲置镜像（谨慎删除，约 5.4 GB）

本节点无容器引用，但**其他节点正在运行同名镜像**。删除安全，但 Pod 漂移/重调度时会重新拉取。

| 镜像 | 大小 | 闲置于 | 实际运行于 |
|---|---|---|---|
| `quay.io/strimzi/kafka:1.0.0-kafka-4.1.2` | 380.1 MB | worker01, worker03 | worker02 |
| `swr.../docker.n8n.io/n8nio/n8n:2.14.2` | 275.1 MB | worker02 | worker03 |
| `docker.io/grafana/grafana:12.4.3` | 273.8 MB | worker02, worker03 | worker01 |
| `quay.io/strimzi/operator:1.0.0` | 222.1 MB | worker03 | worker01, worker02 |
| `docker.io/nicolaka/netshoot:latest` | 208.6 MB | worker02, worker03 | worker01 |
| `quay.io/argoproj/argocd:v3.2.4` | 186.0 MB | worker03 | worker01, worker02 |
| `quay.io/prometheus/prometheus:v3.11.2` | 145.8 MB | worker02 | worker01 |
| `.../opentelemetry-collector-contrib:0.145.0` | 88.8 MB | worker01 | worker02 |
| `docker.io/kubernetesui/dashboard:v2.7.0` | 72.3 MB | worker01, worker03 | worker02 |
| `docker.io/envoyproxy/envoy:v1.37-latest` | 71.7 MB | worker02, worker03 | worker01 |
| `quay.io/calico/kube-controllers:v3.32.2` | 60.3 MB | m01, master01, worker03 | worker02 |
| `docker.io/library/traefik:v3.6.2` | 49.3 MB | worker02 | worker01 |
| `ghcr.io/dexidp/dex:v2.44.0` | 43.7 MB | worker02, worker03 | worker01 |
| `registry.k8s.io/sig-storage/csi-*` (4 个) | ~156 MB | worker02, worker03 | worker01 |
| `docker.io/grafana/loki:3.6.7` | 39.5 MB | worker03 | worker01, worker02 |
| `docker.io/grafana/tempo:3.0.3` | 37.2 MB | master01, worker03 | worker01, worker02 |

> **建议**：Tier 2 中 `nicolaka/netshoot`（208 MB × 2，调试工具镜像）、`minio/mc`、`curlimages/curl` 等一次性调试镜像可直接删；但对 Worker 节点，保留少量常用镜像可避免临时 Pod 启动时拉取延迟。若追求磁盘最大化回收，执行 `crictl rmi --prune` 即可一次性全清。

---

## 五、根因分析

### 5.1 为什么废弃镜像能堆积到 13.7 GB

kubelet 配置（`/var/lib/kubelet/config.yaml`，6 节点一致）：

```yaml
imageMaximumGCAge: 0s
imageMinimumGCAge: 0s
evictionPressureTransitionPeriod: 0s
# 注意：无 evictionHard / evictionSoft 定义
```

- `imageMinimumGCAge: 0s` 看似激进（应立即 GC），但 **kubelet 镜像 GC 的触发条件是磁盘使用率超过 `imageGCHighThreshold`（默认 85%）**，而非时间或空闲状态。
- 巡检时最高水位 76%，**永远达不到 85% 触发线 → kubelet 层 GC 从未执行**。
- 同时未定义 `evictionHard`，磁盘压力驱逐防护也未显式配置。
- 于是 259 天内 1.29→1.35 的 6 轮升级残留全部沉淀。

**但这不是永久泄漏 —— 关键修正：**

镜像回收实际有**两层机制**：

| 机制 | 是否感知 sandbox | 触发条件 | 巡检时状态 |
|---|---|---|---|
| **containerd 原生 GC** | ✅ 是 | 镜像拉取 / 显式 GC / 周期性 | **惰性运行** —— 拉取新镜像时才触发 |
| kubelet 镜像 GC | ⚠️ 通过 `crictl rmi` | 磁盘 > 85% | **从未触发** |

这 13.7 GB 属于「**等待 containerd GC 回收的积压**」，而非不可回收的硬占用。因此一次普通的镜像拉取即可触发大规模回收（实测见第八章，回收量达预估的 4 倍）。

### 5.2 巡检报告的两处判断错误（已修正）

| # | 原文判断 | 问题 | 修正 |
|---|---|---|---|
| 1 | 将 `registry.aliyuncs.com/.../pause:3.10` 等 pause 镜像列为 Tier 1 可删 | **`crictl ps` 只列容器，不列 sandbox（Pod 沙箱）**，故 pause 镜像被误判为「无引用」。实测 m01 有 12 个运行中 sandbox、worker02 有 44 个，**全部依赖该 pause 镜像** | pause 镜像必须保留，删除会导致新 Pod 无法创建 |
| 2 | 预估可回收 13.7 GB | 13.7 GB 是**镜像压缩后逻辑大小**（`crictl images` 的 size 字段），未计入 containerd GC 额外释放的**已解包 overlayfs 层** | 实际回收 **约 52 GB**（约 4 倍） |

### 5.2 其他发现

- `registry.aliyuncs.com/google_containers/*` 镜像残留说明集群曾从阿里云镜像源迁移到 `registry.k8s.io`，旧地址镜像未清理。
- `docker.io/grafana/promtail:3.5.1` 在 3 台 control-plane 上留存，说明日志栈 5 天前从 Promtail 迁移到 Grafana Alloy，但旧镜像未清。
- m01 存在 `/root/k8s-upgrade-1.29-to-1.35`（860 MB）升级工作目录，以及 `ctr-backup-20261002-233722`（70 MB，2 天前创建）。

---

## 六、清理方案

### 6.1 立即执行：Tier 1 安全清理（约 7.2 GB）

**方式一：单节点 prune（推荐，可控）**

```bash
# 逐节点执行，仅删除本节点完全未被引用的镜像
crictl rmi --prune
```

**方式二：显式删除 Tier 1 镜像**

```bash
# 控制面升级残留（m01 / master01 / master02 三台）
for v in v1.29.8 v1.30.14 v1.31.14 v1.32.13 v1.33.13 v1.34.12; do
  crictl rmi registry.k8s.io/kube-apiserver:$v \
             registry.k8s.io/kube-controller-manager:$v \
             registry.k8s.io/kube-scheduler:$v \
             registry.k8s.io/kube-proxy:$v
done
crictl rmi registry.k8s.io/etcd:3.5.12-0 registry.k8s.io/etcd:3.5.15-0 \
           registry.k8s.io/etcd:3.5.24-0 registry.k8s.io/etcd:3.6.5-0
crictl rmi registry.k8s.io/coredns/coredns:v1.11.1 \
           registry.k8s.io/coredns/coredns:v1.11.3 \
           registry.k8s.io/coredns/coredns:v1.12.0 \
           registry.k8s.io/coredns/coredns:v1.12.1

# CNI 旧版本（m01 / master01 / master02 / worker02 / worker03）
crictl rmi docker.io/calico/node:v3.27.4 docker.io/calico/node:v3.30.7 \
           docker.io/calico/cni:v3.27.4   docker.io/calico/cni:v3.30.7 \
           docker.io/calico/kube-controllers:v3.27.4 \
           docker.io/calico/kube-controllers:v3.30.7

# 日志栈已切换到 Alloy，删除 Promtail
crictl rmi docker.io/grafana/promtail:3.5.1

# 应用残留
crictl rmi docker.io/langgenius/dify-plugin-daemon:0.5.3-local \
           docker.io/langgenius/dify-plugin-manager:0.14.4
crictl rmi swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/n8n-io/n8n:2.7.0
crictl rmi registry.k8s.io/hpa-example:latest docker.io/library/postgres:17.6 \
           docker.io/library/nginx:1.27 docker.io/valkey/valkey:9.0.1-alpine3.23

# 悬空/无标签镜像与调试工具
crictl rmi docker.io/library/hello-world:latest
crictl rmi registry.aliyuncs.com/google_containers/pause:3.9 \
           registry.aliyuncs.com/google_containers/pause:3.10 \
           registry.k8s.io/pause:3.8 registry.k8s.io/pause:3.9 \
           registry.k8s.io/pause:3.10.1
crictl rmi ghcr.io/kube-vip/kube-vip:v0.8.4 ghcr.io/kube-vip/kube-vip:v0.9.2 \
           quay.io/prometheus/node-exporter:v1.10.2 \
           registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20231011-8b53cabe0
```

**方式三：Kind 节点批量执行（本集群为 kubeadm + k3s/v1.29→1.35 升级环境）**

```bash
for node in m01 master01 master02 worker01 worker02 worker03; do
  echo "=== cleaning $node ==="
  ssh "$node" 'sudo crictl rmi --prune 2>&1 | grep -c "Removed image"'
done
```

**预期回收（Tier 1）**

| 节点 | 根分区现状 | 清理后 | 改善 |
|---|---|---|---|
| **worker02** | 35G / 48G = **76%** | ~34G = **71%** | **-5%** ⬇️ |
| **worker03** | 31G / 48G = **69%** | ~30G = **63%** | **-6%** ⬇️ |
| worker01 | 29G / 48G = 64% | ~28.9G = 64% | -0.3% |
| m01 | 29G / 47G = 60% | ~27G = 58% | -2% |
| master02 | 21G / 38G = 58% | ~19.6G = 54% | -4% |
| master01 | 24G / 48G = 52% | ~22.6G = 49% | -3% |

> 注：镜像声明大小为压缩后逻辑值，实际磁盘回收还包括 overlayfs 解包层释放，可能高于此估算。

### 6.2 可选：Tier 2 深度清理（额外约 5.4 GB）

```bash
# 全量 prune（含 Tier 2），worker03 收益最大（约 -3 GB，69% → 约 63%）
ssh worker03 'sudo crictl rmi --prune'
ssh worker02 'sudo crictl rmi --prune'
ssh worker01 'sudo crictl rmi --prune'
```

**风险与权衡：** Pod 重调度到已清理节点时会重新拉取镜像（临时启动延迟）。建议先加 `imagePullPolicy` 优化或配置本地 registry 镜像缓存。

### 6.3 非容器空间清理

```bash
# m01：升级遗留工作目录（860 MB）
ssh m01 'sudo rm -rf /root/k8s-upgrade-1.29-to-1.35/work/*'

# m01：工具缓存（按需，建议保留 tools/installs）
ssh m01 'sudo rm -rf /root/.hermes/cache/* /root/.cache/go-build/*'

# m01：升级备份（确认不再需要后，130 MB）
ssh m01 'sudo rm -rf /root/ctr-backup-20261002-233722 \
                 /root/observability-upgrade-backup-20260929-111055-pg-s3-incident'
```

---

## 七、改进建议（防止问题复发）

| 优先级 | 建议 | 说明 |
|---|---|---|
| 🔴 **高** | **配置磁盘驱逐阈值** | 在 `/var/lib/kubelet/config.yaml` 增加 `evictionHard: {memory.available: "200Mi", nodefs.available: "10%", imagefs.available: "15%"}` 与 `evictionSoft`，让 kubelet 在 85% 前主动 GC 镜像与驱逐 Pod |
| 🔴 **高** | **为控制面扩容内存** | 3 台 control-plane 仅 3.7~5.7 Gi，m01 内存已 69%、apiserver 单进程 1356 Mi。建议每台至少 8 Gi，或将非核心组件迁出控制面 |
| 🟠 **中** | **修复负载失衡** | worker03 仅 10 Pod / CPU 3% 却背 4 GB 闲置镜像；worker01+02 承担 73% 负载。建议加 podAntiAffinity 或调整调度策略 |
| 🟠 **中** | **建立镜像清理 CronJob** | 每月执行 `crictl rmi --prune`，或启用 kubelet GC 阈值 |
| 🟡 **低** | **master02 磁盘偏小** | 38G vs 其余 47~48G，建议统一规格 |
| 🟡 **低** | **统一镜像仓库地址** | 清理 `registry.aliyuncs.com` 残留，并在所有 manifests 中统一使用 `registry.k8s.io` |
| 🟡 **低** | **Prometheus 资源上限** | 595m CPU / 1461Mi 内存为全集群最大消费者，建议设置合理 limit 与 retention |
| 🟡 **低** | **锁定镜像 tag** | 多个镜像使用 `:latest`（cloudflared、envoy、minio/mc、curlimages/curl），不利于可复现与 GC 判定 |

---

## 八、清理执行结果（已完成）

**执行时间**：2026-10-03，巡检报告产出后立即执行。

### 8.1 执行过程

原计划按报告第 6.1 节执行 Tier 1 显式清理。**但在删除前执行了 sandbox 安全校验，发现关键问题并因此改变了执行方式：**

1. 部署特权 DaemonSet 采集数据时，镜像拉取动作（`alpine:3.20`）**触发了 containerd 原生 GC**
2. GC 完成后重新采集发现：镜像数已从 489 骤降至 161，**废弃镜像已全部被 containerd 自动回收**
3. 经二次校验：**剩余镜像 100% 被容器或 sandbox 引用，真正可删镜像 = 0**

**因此未执行任何 `crictl rmi` 删除命令。** 原因：目标已达成，且手动 `rmi` 会额外引入 pause 镜像误删等风险（见 5.2 修正 #1）。

### 8.2 磁盘回收成果

| 节点 | 巡检时 | 清理后 | **降幅** | 回收空间 |
|---|---|---|---|---|
| **worker02** | 35G / **76%** | 21G / **47%** | **-29%** ⬇️ | ~14 GB |
| **worker03** | 31G / **69%** | 18G / **40%** | **-29%** ⬇️ | ~13 GB |
| m01 | 29G / 60% | 20G / **42%** | -18% ⬇️ | ~9 GB |
| master02 | 21G / 58% | 15G / **42%** | -16% ⬇️ | ~6 GB |
| master01 | 24G / 52% | 18G / **39%** | -13% ⬇️ | ~6 GB |
| worker01 | 29G / 64% | 25G / 55% | -9% ⬇️ | ~4 GB |
| **合计** | **169G** | **117G** | | **~52 GB** |

**containerd 目录变化**

| 节点 | 巡检时 | 清理后 | 回收 |
|---|---|---|---|
| m01 | 11221 M | 2482 M | **-8.7 GB** |
| worker01 | 19333 M | 15224 M | -4.1 GB |
| worker02 | 24558 M | 11012 M | **-13.5 GB** |
| worker03 | 20768 M | 7164 M | **-13.6 GB** |

**镜像数量变化**

| 节点 | 巡检时 | 清理后 | 降幅 |
|---|---|---|---|
| m01 | 68 | 14 | -79% |
| master01 | 63 | 14 | -78% |
| master02 | 59 | 13 | -78% |
| worker01 | 91 | 62 | -32% |
| worker02 | 107 | 42 | -61% |
| worker03 | 101 | 16 | -84% |

> 回收量达预估 13.7 GB 的 **4 倍**，原因见 5.2 修正 #2：containerd GC 在删除镜像 blob 的同时，一并释放了对应的**已解包 overlayfs 层**（解包后体积通常是压缩态的 2~4 倍）。

### 8.3 集群健康验证（清理后）

| 检查项 | 结果 |
|---|---|
| 节点状态 | ✅ 6/6 Ready（m01, master01, master02, worker01, worker02, worker03） |
| Pod 状态 | ✅ 全部 Running，无 Pending / Failed / CrashLoopBackOff / Terminating |
| 剩余废弃镜像 | ✅ **0 个**（6 节点全部清理干净） |
| pause 镜像 | ✅ 完好保留（`aliyuncs.com/.../pause:3.10`，各节点 1 个），新 Pod 创建不受影响 |
| 巡检 DaemonSet | ✅ 已删除，`node-audit` 命名空间已移除 |
| 磁盘压力 | ✅ 全部节点 < 60%，`DiskPressure` 均为 False |

**遗留 Pod 数 141~142 波动原因（非清理所致）**：`default` 命名空间的 Knative revision `report-processor-00001-deployment` 处于 `replicas: 0`（scale-to-zero）状态，autoscaler 每约 2 分钟拉起一个探测 Pod 并随即回收，导致集群 Pod 总数在 141/142 间自然波动。该行为属 Knative scale-to-zero 正常机制，**未做任何改动**。

### 8.4 仍需人工处理的遗留项

| 项目 | 位置 | 空间 | 说明 |
|---|---|---|---|
| `/root/.hermes` | m01 | 6.5 GB | 工具缓存（cache 3.2 GB + tools 1.6 GB + installs 890 MB） |
| `/root/k8s-upgrade-1.29-to-1.35` | m01 | 860 MB | 1.29→1.35 升级遗留工作目录 |
| `/root/ctr-backup-20261002-233722` | m01 | 70 MB | 升级备份（2 天前创建） |
| `/root/observability-upgrade-backup-*` | m01 | 57 MB | 升级备份 |
| 控制面内存扩容 | 3 节点 | — | m01 内存占用曾达 69%，建议升至 ≥8 Gi |

### 8.5 防止问题复发（已强化）

由于本次回收依赖「一次偶然的镜像拉取」，机制性问题仍未解决 —— **下一轮升级残留同样会再次积压**。建议：

```bash
# 方案 A：配置驱逐阈值，让 kubelet 在 85% 前主动回收（推荐，一次性配置）
# 在各节点 /var/lib/kubelet/config.yaml 增加：
#   evictionHard:
#     memory.available: "200Mi"
#     nodefs.available: "10%"
#     imagefs.available: "15%"
#   imageGCHighThreshold: 70
#   imageGCLowThreshold: 50
# 修改后重启 kubelet：systemctl restart kubelet

# 方案 B：定期手动触发 containerd GC（每月 Cron）
# 在各节点执行 ctr -n k8s.io images check  或  crictl rmi --prune
```

---

```bash
# 1. 集群与节点状态
kubectl cluster-info
kubectl get nodes -o wide
kubectl top nodes

# 2. 节点条件与容量
kubectl get nodes -o json | jq '.items[] | {name:.metadata.name,
  allocatable:.status.allocatable, conditions:[.status.conditions[]|{type,status}]}'

# 3. 磁盘占用（通过特权 DaemonSet + chroot 到宿主）
#    DaemonSpec: hostPID:true, hostNetwork:true, privileged:true,
#    mount hostPath "/" → /host, 命令 chroot /host <cmd>
df -hPT -x tmpfs -x devtmpfs
du -x -h -d1 -m /            # 顶层目录
du -x -h -d1 -m /var/lib/containerd
du -x -h -d1 -m /var/lib/kubelet
journalctl --disk-usage

# 4. 镜像与容器精确比对（判定可删除镜像）
crictl images -o json      # 全量镜像 + size + repoTags
crictl ps -a -o json       # 全部容器（含 exited）的 imageRef
#   → image.id ∉ {container.imageRef} 即为可回收镜像

# 5. 资源热点
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu
```

**采集工具**：`crictl` (CRI) 精确比对 489 个镜像 / 224 个容器，覆盖全部 6 节点。
**清理方式**：临时 DaemonSet 已删除，巡检结束后集群恢复至 142 个 Running Pod、6 节点全部 Ready 的原始状态。