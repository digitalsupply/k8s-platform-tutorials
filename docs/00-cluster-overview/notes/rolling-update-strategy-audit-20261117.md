# K8s 滚动更新策略审计：maxSurge / maxUnavailable / minAvailable 异常资源

> 审计日期：2026-11-17
> 审计范围：本集群全部 Deployment（76 个）与 StatefulSet（12 个）
> 审计口径：以 `.spec.strategy.rollingUpdate`（Deployment）和 `.spec.updateStrategy.rollingUpdate`（StatefulSet）的实际取值为准，不含 Pod 模板内字段。

## 一、概念讲解

滚动更新（Rolling Update）是 Deployment / StatefulSet 在镜像或配置变更时，**不中断服务地逐批替换旧 Pod** 的机制。控制它节奏的核心字段有三个：

### 1. maxSurge（最大超出副本数）

- **含义**：滚动更新过程中，**允许比期望副本数（replicas）多创建的 Pod 上限**。
- **作用**：决定“先起多少新 Pod、再停多少旧 Pod”的激进程度。
- **取值**：百分比（如 `25%`）或绝对数（如 `1`）。
- **举例**：replicas=4、maxSurge=25% → 最多可临时达到 5 个 Pod（4+1）。新 Pod 先起来，验证通过后再下线旧 Pod，超出的部分会逐步回收。

> maxSurge=0 表示**完全不创建多余副本**，即“先停一个旧 Pod，再起一个新 Pod”的原地替换，更新期间总副本数不会超过期望值，但可用副本数会先下降。

### 2. maxUnavailable（最大不可用副本数）

- **含义**：滚动更新过程中，**允许处于不可用（未就绪/已下线）状态的 Pod 上限**。
- **作用**：决定更新期间服务“最多能少几个副本”的容忍度，直接关系到**更新期间的可用性底线**。
- **取值**：百分比（如 `25%`）或绝对数（如 `1`、`0`）。
- **举例**：replicas=4、maxUnavailable=25% → 最多允许 1 个 Pod 不可用。

> maxUnavailable=0 是最严格配置：**更新期间不允许任何 Pod 不可用**。只有当新 Pod 完全 Ready 后，旧 Pod 才会被停止，保证全程副本数不降。代价是更新更慢、需要 maxSurge≥1 配合，否则会卡住（新 Pod 没地方起，旧 Pod 不能停）。

### 3. minAvailable（最小可用副本数）

- **含义**：更新期间**必须保持可用的 Pod 数量下限**，是 maxUnavailable 的“反向表达”。
- **关系**：`minAvailable = replicas − maxUnavailable`。
- **说明**：原生 Deployment/StatefulSet 的 API 字段里**没有直接的 `minAvailable` 字段**，它是从 maxUnavailable 推导出来的语义概念；在 Argo Rollouts、部分 Operator CRD 中会作为显式字段出现。在原生资源里，**保证 minAvailable 的手段就是调低 maxUnavailable**。

### 三者协同示例（replicas=4）

| maxSurge | maxUnavailable | 更新行为 | 可用性保证(minAvailable) |
|---|---|---|---|
| 25% | 25% | 先起 1 个新，Ready 后停 1 个旧，循环 | ≥ 3 |
| 0 | 1 | 停 1 旧 → 起 1 新，总副本先降后升 | ≥ 3 |
| 25% | 0 | 先起 1 新，Ready 后才停旧，全程不降 | = 4（最稳） |
| 50% | 50% | 激进，可同时 2 新 2 旧 | ≥ 2（最险） |

## 二、集群现状：多数资源的配置基线

本次审计 76 个 Deployment，配置分布如下：

| 策略类别 | 数量 | 说明 |
|---|---|---|
| **RollingUpdate，maxSurge=25% / maxUnavailable=25%** | **53** | **绝对多数**，即 K8s 默认值，绝大多数组件采用 |
| Recreate（先全停再全起） | 12 | 不滚动，更新期间副本直接归零 |
| 非默认 RollingUpdate | 11 | 下面重点分析的“异常”资源 |

**结论**：`25% / 25%` 是本集群的默认基线。下面把**与基线不一样的 11 个 Deployment** 作为重点异常对象列出，并单独说明 12 个 Recreate 策略资源。

## 三、重点异常资源（非默认 RollingUpdate，共 11 个）

这些资源虽然都用了 RollingUpdate，但 maxSurge / maxUnavailable 取值与集群主流的 25%/25% 不同。按异常类型分四组：

### A 组：maxUnavailable 取绝对数 1（3 个）

基线是 `25%`，这里改用**绝对数 `1`**。对单副本资源，`1` 等价于“允许该唯一副本下线”，可用性比 25% 更宽松；对多副本资源则更严格。

| 命名空间/资源 | replicas | maxSurge | maxUnavailable | minAvailable | 解读 |
|---|---|---|---|---|---|
| `kube-system/coredns` | 2 | 25% | **1** | 1 | DNS 是关键组件，限制最多 1 个不可用，2 副本下即保留 1 个可用 |
| `kube-system/hubble-relay` | 1 | 25% | **1** | 0 | 单副本，更新时允许该副本下线，存在短暂无中继窗口 |
| `kube-system/hubble-ui` | 1 | 25% | **1** | 0 | 单副本 UI，允许下线，影响可接受 |

### B 组：maxUnavailable=0，最严格（1 个）

| 命名空间/资源 | replicas | maxSurge | maxUnavailable | minAvailable | 解读 |
|---|---|---|---|---|---|
| `kube-system/metrics-server` | 1 | 25% | **0** | 1 | 更新期间零中断，单副本下新 Pod 必须先 Ready 再停旧，最稳但更新最慢 |

### C 组：maxSurge=0，原地替换（5 个）

maxSurge=0 表示**不创建多余副本**，采用“停一旧、起一新”的串行替换。更新期间总副本数不超期望值，但对单副本资源意味着**先下线再上线**，存在短暂不可用窗口（配合 maxUnavailable=1）。

| 命名空间/资源 | replicas | maxSurge | maxUnavailable | minAvailable | 解读 |
|---|---|---|---|---|---|
| `traefik/traefik` | 1 | **0** | 1 | 0 | 入口网关单副本，更新时先停再起，存在短暂路由中断风险 |
| `logging/loki-read` | 1 | **0** | 1 | 0 | 日志读取层，单副本串行替换 |
| `logging/tempo3-distributor` | 1 | **0** | 1 | 0 | Tempo 分发器，单副本串行替换 |
| `logging/tempo3-querier` | 1 | **0** | 1 | 0 | Tempo 查询器，单副本串行替换 |
| `logging/tempo3-query-frontend` | 1 | **0** | 1 | 0 | Tempo 查询前端，单副本串行替换 |

> 这组的共性：都是**单副本 + 无多余副本缓冲**，更新期间必然出现“可用数先降到 0 再回升”。对 traefik 这类入口组件需特别关注中断时长。

### D 组：maxUnavailable=50%，最激进（1 个）

| 命名空间/资源 | replicas | maxSurge | maxUnavailable | minAvailable | 解读 |
|---|---|---|---|---|---|
| `kube-system/cilium-operator` | 2 | 25% | **50%** | 1 | 2 副本下允许 1 个（50%）不可用，可用性底线最低。Cilium operator 非业务关键路径，容忍度较高，但仍是集群中**最激进**的取值 |

### E 组：绝对数 maxSurge=1 / maxUnavailable=1（1 个）

| 命名空间/资源 | replicas | maxSurge | maxUnavailable | minAvailable | 解读 |
|---|---|---|---|---|---|
| `monitoring/wecom-adapter` | 2 | **1** | **1** | 1 | 用绝对数而非百分比，2 副本下最多 1 新 1 旧，等价于“先起 1 新、Ready 后停 1 旧”，与 25%/25% 效果接近，但写法不同 |

## 四、Recreate 策略资源（12 个，与滚动更新完全不同）

这些资源**不滚动**，更新时**先把所有旧 Pod 删除，再创建新 Pod**，更新期间副本数直接归零。适用于**单副本、无状态、可短暂中断**的组件，或强依赖一次性切换的服务。

| 命名空间/资源 | replicas | 说明 |
|---|---|---|
| `argocd/argocd-notifications-controller` | 1 | ArgoCD 通知控制器，单副本可中断 |
| `ceph-csi-rbd/rbd.csi.ceph.com-ctrlplugin` | 1 | CSI 插件控制器，重启切换 |
| `china-study-free/china-study-free` | 1 | 业务应用，单副本 |
| `cicd/buildkitd` | 1 | 构建守护进程，切换期无构建 |
| `cnpg-system/barman-cloud` | 1 | CNPG 云备份组件 |
| `compassio/frpc` | 1 | FRP 客户端 |
| `deeptutor/deeptutor` | 1 | 业务应用，单副本 |
| `deeptutor/redis` | 1 | Redis 单副本，切换期短暂中断 |
| `kafka/my-cluster-entity-operator` | 1 | Kafka 实体操作器 |
| `monitoring/prometheus-grafana` | 1 | Grafana 单副本，切换期 UI 中断 |
| `open-webui/frpc` | 0 | 当前无副本（缩容到 0） |
| `open-webui/open-webui` | 0 | 当前无副本（缩容到 0） |

## 五、StatefulSet 现状

12 个 StatefulSet 全部使用默认 RollingUpdate，**均未显式设置 maxUnavailable，等价于 maxUnavailable=0**（默认行为：单副本时逐个更新，多副本时按序更新且不额外限制不可用数）。也未设置 `partition`（分片更新），因此**没有异常项**。

| 命名空间/资源 | replicas | maxUnavailable | 说明 |
|---|---|---|---|
| `logging/tempo3-block-builder` | 3 | 0（默认） | 3 副本，按序更新 |
| `logging/tempo3-live-store` | 3 | 0（默认） | 3 副本，按序更新 |
| 其余 10 个 | 1 | 0（默认） | 单副本，逐个更新 |

> StatefulSet 的 minAvailable 同样由 `replicas − maxUnavailable` 推导，本集群 StatefulSet 因未设 maxUnavailable，默认保证全部副本可用（minAvailable = replicas）。

## 六、异常资源汇总与建议

### 异常资源总表

| 组别 | 资源 | 异常点 | 风险评估 |
|---|---|---|---|
| A | coredns、hubble-relay、hubble-ui | maxUnavailable=1（绝对数） | 低～中，符合各组件定位 |
| B | metrics-server | maxUnavailable=0（最严） | 无中断，最稳，推荐保持 |
| C | traefik、loki-read、tempo3-distributor/querier/query-frontend | maxSurge=0（无缓冲） | **中**，单副本更新时存在中断窗口，traefik 尤需关注 |
| D | cilium-operator | maxUnavailable=50%（最激进） | 中，可用性底线最低，建议评估是否需收紧 |
| E | wecom-adapter | maxSurge=1/maxUnavailable=1（绝对数） | 低，效果接近默认 |
| Recreate | 12 个单副本资源 | 无滚动，更新期归零 | 按组件性质接受，单副本无状态组件可保持 |

### 建议

1. **traefik（maxSurge=0, maxUnavailable=1）**：作为集群唯一入口，单副本下更新必然短暂中断。建议至少提升为 `maxSurge=1, maxUnavailable=0`，先起新 Pod Ready 后再停旧，消除中断；或考虑多副本 + 健康探针。
2. **cilium-operator（maxUnavailable=50%）**：取值激进，建议评估是否收紧到 25%，降低更新期可用性风险。
3. **C 组日志组件（maxSurge=0）**：若为单副本部署，建议评估能否接受更新中断；若不能，可调整为 `maxSurge=1, maxUnavailable=0`。
4. **Recreate 资源**：单副本无状态组件采用 Recreate 是合理选择，保持即可；`open-webui` 两个资源当前副本为 0，关注是否为预期缩容。
5. **metrics-server（maxUnavailable=0）**：最严格配置，推荐作为单副本关键组件的模板，保持。

## 七、审计方法

```bash
# 收集全部 Deployment 的滚动更新策略
kubectl get deploy -A -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    ru=i['spec'].get('strategy',{}).get('rollingUpdate',{})
    print(i['metadata']['namespace']+'/'+i['metadata']['name'],
          'surge='+str(ru.get('maxSurge','-')),
          'unavail='+str(ru.get('maxUnavailable','-')))
"

# 收集全部 StatefulSet 的更新策略
kubectl get sts -A -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    ru=i['spec'].get('updateStrategy',{}).get('rollingUpdate',{})
    print(i['metadata']['namespace']+'/'+i['metadata']['name'],
          'unavail='+str(ru.get('maxUnavailable','-')))
"
```
