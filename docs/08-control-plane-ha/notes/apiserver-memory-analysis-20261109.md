# kube-apiserver 内存占用分析

> 日期：2026-11-09  
> 集群：Kubernetes v1.35.9，3 个 control-plane（stacked etcd）  
> 版本：kube-apiserver v1.35.9  
> 结论先行：**不是泄漏，主要是 watch 数 / CRD-OpenAPI / 对象缓存 / Go 堆造成的；三个 apiserver 的 watch 分布严重不均，导致内存差异很大。**

---

## 1. 实测数据

### 1.1 每个 apiserver 实例（直接访问 6443 获取 /metrics）

| 实例 | WATCH 数 | goroutines | heap alloc | heap inuse | Go sys | RSS |
|---|---:|---:|---:|---:|---:|---:|
| m01 (10.0.0.61) | **72** | 2,454 | 433 MiB | 579 MiB | 919 MiB | **850 MiB** |
| master01 (10.0.0.121) | **641** | 7,396 | 1,207 MiB | 1,377 MiB | 1,866 MiB | **1.66 GiB** |
| master02 (10.0.0.120) | **608** | 6,064 | 709 MiB | 993 MiB | 1,574 MiB | **1.55 GiB** |

`kubectl top` 显示的是 working set，会略低于 RSS：

```text
kube-apiserver-m01        970Mi
kube-apiserver-master01  1499Mi
kube-apiserver-master02  1080Mi
```

**关键相关性：watch 越多的实例，内存越大。**  
m01 只有 72 个 watch，RSS 850MiB；master01/02 有 600+ watch，RSS 1.5–1.7GiB。

### 1.2 集群 API 面

| 项目 | 数量/大小 |
|---|---:|
| 对象总数（apiserver_storage_objects） | 4,638 |
| Events | 1,945 |
| CRD | **148** |
| CRD schema JSON 总量 | 8.2 MB |
| OpenAPI v2 文档 | **13.3 MB** |
| Secrets | 125（14.6 MB，其中 Helm release 36 个 / 14.45 MB） |
| ConfigMaps | 152（0.85 MB） |
| ClusterRole / Binding | 178 / 131 |
| Service / EndpointSlice | 102 / 102 |
| CiliumEndpoint / Identity | 100 / 89 |
| Leases | 75 |
| Webhook 配置 | 21 |
| 转换 Webhook CRD | 9 |
| 聚合 APIService | 1 |
| etcd DB | 126 MB（含 MVCC 历史） |

### 1.3 CRD 按 group 分布

```text
15 hub.traefik.io
14 operator.tekton.dev
13 grafana.integreatly.org
11 postgresql.cnpg.io
10 traefik.io
10 monitoring.coreos.com
10 cilium.io
 9 kafka.strimzi.io
 7 triggers.tekton.dev
 7 tekton.dev
 7 metallb.io
 6 gateway.networking.k8s.io
 6 csi.ceph.io
 4 opentelemetry.io
 4 cert-manager.io
 3 argoproj.io
 ...
```

148 个 CRD 对一个 6 节点集群来说偏多，尤其是 Traefik Hub（15）+ Traefik（10）+ Tekton（30）。

### 1.4 watch 分布

| 实例 | 主要 watch 资源 |
|---|---|
| master01 | pods 29、configmaps 23、services 23、secrets 18、endpoints 13、nodes 8 |
| master02 | **configmaps 122**、secrets 69、pods 23、namespaces 19、services 19、nodes 15 |
| m01 | configmaps 6、secrets 5、pods 4、nodes 3 |

master02 的 **122 个 ConfigMap watch** 非常突出；master01 的 pods/services watch 更多。  
长连接 watch 会“粘”在首次连接的 apiserver 上，不会自动均衡，所以三个实例的内存差异很大。

### 1.5 apiserver 启动参数

```text
--authorization-mode=Node,RBAC
--enable-admission-plugins=NodeRestriction
```

没有设置：

```text
--target-ram-mb
--watch-cache-sizes
--event-ttl
--max-requests-inflight
--max-mutating-requests-inflight
```

即全部使用默认值。apiserver 只设了 CPU request 250m，**没有内存 request/limit**，所以内存可以随缓存增长到节点上限。

---

## 2. 原因排序

### 2.1 第一原因：watch 数（约 600/实例）

- 每个 watch 都有 goroutine、watcher buffer、序列化/反序列化缓冲；
- watch cache 会持有该资源当前对象的 store；
- 609–641 个 watch 对应 6,000–7,400 个 goroutine；
- 估算：从 72 watch / 850MiB 到 641 watch / 1.66GiB，约 **每个 watch 1.2–1.4MiB**（含缓存和 goroutine 开销，粗略）。

为什么这么多：

- 集群里有很多 operator/controller：ArgoCD、CNPG、Strimzi、Tekton、Grafana、cert-manager、VPA、Cilium、MetalLB、Prometheus Operator、Ceph CSI operator、Alloy 等；
- 每个 operator 会 watch 多种资源（ConfigMap、Secret、Pod、Service、EndpointSlice、CRD、CR）；
- 很多 watch 是 **cluster-wide**，不是 namespace-scoped；
- 长连接 watch 不均衡：master02 拿到 122 个 ConfigMap watch，m01 只有 6 个。

### 2.2 第二原因：148 个 CRD 与 OpenAPI

- 148 个 CRD，schema JSON 合计 8.2MB；
- `/openapi/v2` 文档 13.3MB；
- apiserver 需要为所有 CRD 构建并缓存 OpenAPI v2/v3 模型、CRD handler、conversion；
- 这部分是**每个 apiserver 实例的固定成本**，与小节点内存叠加后非常明显；
- Traefik Hub（15）+ Traefik（10）+ Tekton（30）+ Grafana（13）+ CNPG（12）+ Strimzi（10）是主要贡献者。

### 2.3 第三原因：对象数量与 watch cache

- 4,638 个对象；1,945 个 Events；125 个 Secrets（14.6MB）；152 个 ConfigMaps；
- etcd DB 126MB（含历史版本，当前对象数据更小）；
- watch cache 会持有所有被 watch 资源的当前对象；
- Helm release secrets 36 个 / 14.45MB 是 Secrets 的主要部分（argocd v6–v14 每个约 600–700KB）。

### 2.4 第四原因：Go 运行时/GC

- heap alloc 433MiB–1.2GiB；heap inuse 579MiB–1.38GiB；Go sys 919MiB–1.87GiB；
- Go GC 默认 GOGC=100，堆通常会保留约 2× live heap；
- 6,000–7,400 个 goroutine 的栈也是内存的一部分；
- 这不是“泄漏”，而是缓存 + 堆的稳态。

### 2.5 不是主要原因

- **大 CR 对象**：GrafanaDashboard 37 个共 69KB、PrometheusRule 44 个共 237KB、ArgoCD Application 25 个共 272KB，量级很小；
- **ConfigMap 数据**：152 个共 0.85MB；
- **聚合 API**：只有 1 个（metrics-server）；
- **审计/加密**：未启用，不存在相关缓冲；
- **请求并发**：当前 inflight 只有 3 mutating / 1 readOnly，不是高并发导致。

---

## 3. 为什么三个实例差这么多

- watch 是长连接，客户端首次连到哪个 apiserver 就一直在那里；
- API VIP（kube-vip）不会按 watch 数做动态均衡；
- master02 累积了 122 个 ConfigMap watch + 69 个 Secret watch；
- master01 累积了 29 个 Pod watch + 23 个 Service watch；
- m01 只有 72 个 watch，所以内存最低（850MiB）。

这也解释了之前 m01 曾到 2.3GB：当时它可能持有大量 watch；apiserver 在 12:50 UTC 左右重启后 watch 重新分配，m01 只拿到 72 个，内存降到 850MiB。

---

## 4. 建议

### 4.1 立即可做（低风险）

1. **清理 Helm 历史**
   ```bash
   helm history -n argocd argocd
   helm history -n logging loki
   ```
   36 个 Helm release secret / 14.45MB。  
   后续升级统一加 `--history-max 3`，并删除旧的 `sh.helm.release.v1.*` Secret。  
   收益：减少 Secret watch cache 和 etcd 体积（约 10MB 级）。

2. **减少 Events**
   当前 1,945 个。默认 `--event-ttl=1h`，说明最近事件 churn 很高（kubelet/CSI/驱逐）。  
   修复 churn 后事件会自然下降；也可在维护窗口评估 `--event-ttl=30m`。

3. **设置 `--target-ram-mb`**
   例如 2048 或 3072（按节点内存），让 apiserver 按目标内存调整缓存大小。  
   它不是硬限制，但能避免缓存无界增长。  
   通过 kubeadm `extraArgs` 或 `/etc/kubernetes/manifests/kube-apiserver.yaml` 修改，逐台滚动。

4. **调小 Events watch cache**
   ```text
   --watch-cache-sizes=events#100
   ```
   默认 events watch cache 较大；1945 个事件会占用可观内存。

### 4.2 结构性优化（收益最大）

5. **清理未使用的 CRD/operator**
   148 个 CRD 偏多。优先检查：
   - `hub.traefik.io`（15 个）是否使用 Traefik Hub？
   - `gateway.networking.k8s.io`（6 个）是否使用 Gateway API？
   - `csi.ceph.io`（6 个）在迁移到 ceph-csi-operator 后是否有旧 CRD？
   - Tekton/Grafana/CNPG/Strimzi 是否有未使用的 CRD？
   
   每删除一个未使用 CRD，就减少 OpenAPI schema、CRD handler 和潜在 watch。

6. **让 operator 使用 namespace-scoped watch**
   - Prometheus Operator：`--namespaces=...`
   - ArgoCD：按需使用 sharding / 限制管理范围
   - Tekton、Strimzi、CNPG、Grafana Operator：尽量限制 watch 的 namespace
   
   这能直接减少 600+ watch 的数量。

7. **重新分布 watch**
   - 逐个重启重的 apiserver（master01），watch 会重连，可能重新分布；
   - 但这不是永久方案；长期看需要支持 least-connections 的 API LB，或减少 watch。
   - 不要在业务高峰同时重启三个 apiserver。

8. **给 control-plane 加内存**
   4–6GiB 的节点承载 148 CRD + 600+ watch 偏小。  
   建议 master01/master02 至少 8GiB，最好 16GiB；m01 同理。  
   这是最简单、最持久的修复。

### 4.3 监控

9. **按实例采集 apiserver 指标**
   当前 Prometheus 可能只抓 VIP 或一个实例；建议对三个 control-plane 的 6443 分别抓取：
   ```text
   process_resident_memory_bytes
   go_memstats_heap_inuse_bytes
   go_goroutines
   apiserver_longrunning_requests
   apiserver_current_inflight_requests
   ```
   告警：
   - RSS > 节点内存 70%
   - 单实例 watch 数 > 800
   - goroutines > 10k
   - heap_inuse 持续增长不回落

10. **不要给 apiserver 设低内存 limit**
    apiserver 目前只有 CPU request 250m，没有 memory limit。  
    强行设一个低 limit 会导致 OOMKill，反而造成控制面抖动；应通过加内存 + 减少 watch/CRD 解决。

---

## 5. 一句话总结

**apiserver 内存大不是泄漏，而是 148 个 CRD、13.3MB OpenAPI、4,638 个对象、1,945 个 Events 和 600+ watch 共同造成的缓存/堆开销；三个实例的 watch 分布严重不均（m01 72 个，master01/02 600+ 个），所以 master01/02 到 1.5–1.7GiB，而 m01 只有 850MiB。**  
优先做：清理 Helm 历史、减少 CRD/operator watch、设置 `--target-ram-mb`、给 control-plane 加内存。
