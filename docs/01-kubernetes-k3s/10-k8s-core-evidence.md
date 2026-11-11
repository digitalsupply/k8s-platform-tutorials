# 10 · Kubernetes 核心考点：控制面、节点、资源、稳定性与扩展

> 这一章把 K8s 面试核心考点全部落到本集群：
> **v1.35.9，3 control-plane + 3 worker，Cilium 1.20.4，containerd 2.3.2，ArgoCD 31 App。**
>
> 证据：[`assets/interview-evidence/`](assets/interview-evidence/README.md)。
> 一句话版本：[15 面试速查 05-kubernetes](../15-interview-cheatsheet/05-kubernetes.md)。

## 1. 控制面

### 1.1 kube-apiserver

**一句话**：请求三阶段 **认证 → 授权 → 准入**；apiserver 是唯一直接读写 etcd 的入口。

**本集群**：

- `--authorization-mode=Node,RBAC`
- `--enable-admission-plugins=NodeRestriction`
- `--etcd-servers=https://127.0.0.1:2379`
- 3 个 apiserver 静态 Pod：m01/master01/master02
- `/readyz` 全过

```bash
kubectl -n kube-system get pod kube-apiserver-m01 -o jsonpath='{.spec.containers[0].command}'
kubectl get --raw /readyz?verbose
kubectl auth can-i create pods -n kube-system
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
```

**注意**：认证方式包括 client CA、bootstrap token、service account token、webhook；
授权是 Node/RBAC；准入包括内置插件 + Mutating/ValidatingWebhook。

### 1.2 etcd

**一句话**：对磁盘 fsync 极敏感，必须独立 SSD；监控 `etcd_disk_wal_fsync_duration`；低峰逐节点 `defrag`；quota 默认 2GB。

**本集群**：

```text
etcd 3.6.6, storage 3.6.0
3 members: m01 / master01 / master02
DB 133MB, in-use 37MB, quota 2.1GB
WAL fsync p99 ≈ 1ms, backend commit p99 ≈ 2ms
no alarms
hourly snapshot 133MB, 8234 keys, upload S3
```

```bash
kubectl -n kube-system exec etcd-m01 -- etcdctl ... endpoint health
kubectl -n kube-system exec etcd-m01 -- etcdctl ... endpoint status --write-out=table
kubectl -n kube-system exec etcd-m01 -- etcdctl ... member list --write-out=table
kubectl -n kube-system exec etcd-m01 -- etcdctl ... alarm list
```

**注意**：

- etcd 只有 36MB in-use / 2.1GB quota，暂不需要 defrag；
- defrag 会阻塞，必须逐节点、低峰；
- 备份有，但**恢复演练**才是关键；本环境只验证了快照状态，未做生产恢复。

### 1.3 kube-scheduler

**一句话**：Filter 过滤不可调度节点 → Score 打分 → Reserve/Permit/Bind；本集群 scheduler `--leader-elect=true`。

**证据**：

```text
kubectl get events -A | grep Scheduled
etcd-backup ... Successfully assigned ... to m01
```

调度结果在 `kubectl get pods -o wide` 的 NODE 列。

> 没有直接抓 scheduler 的 Filter/Score 日志；调度事件和节点分布是结果证据。

### 1.4 kube-controller-manager

**一句话**：运行 Deployment/RS/Node/Endpoint 等 controller，持续 reconcile 期望状态。

**证据**：

- `--controllers=*`、`--leader-elect=true`
- Deployment → ReplicaSet ownerReferences
- CNPG/Ceph-CSI operator 日志持续 reconcile
- 31 个 ArgoCD App Synced/Healthy

```bash
kubectl -n open-webui get deploy,rs
kubectl -n open-webui get rs -o jsonpath='{.items[0].metadata.ownerReferences}'
kubectl -n cnpg-system logs deploy/cnpg-controller-manager --tail=20
```

## 2. 节点面

### 2.1 kubelet

**一句话**：节点核心 agent；cgroup driver 必须与运行时一致，1.22+ 推荐 systemd，cgroup v2 必须一致。

**本集群**：

```text
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
rotateCertificates: true
kubelet v1.35.9
```

### 2.2 CRI

**一句话**：容器运行时接口；本集群 containerd 2.3.2，dockershim 已移除。

```bash
crictl version
crictl info
ctr namespaces list
```

### 2.3 CNI

**一句话**：负责 Pod IP、互通、NetworkPolicy；本集群 Cilium 1.20.4。

**证据**：

```text
/etc/cni/net.d/05-cilium.conflist
cilium DS 6/6 Ready
KubeProxyReplacement: True
Routing: Network Native, Host BPF
```

### 2.4 CSI

**一句话**：负责 PV 创建/挂载/扩容/快照，与 PV/PVC/StorageClass 联动。

**本集群**：

```text
CSIDriver rbd.csi.ceph.com (attachRequired=true)
StorageClass ceph-rbd-sc (Retain), nfs-sc (Delete)
17 PV 全 Bound，全部 ReadWriteOnce
```

### 2.5 node-problem-detector

**一句话**：采集节点硬件/内核/运行时问题，上报 NodeCondition/Event。

**本集群**：**未部署**（`kubectl get ds -A | grep node-problem` 无结果）。
节点异常目前靠 kubelet NodeCondition + Prometheus node-exporter/alert 规则发现。

## 3. 资源模型

### 3.1 requests / limits

**一句话**：requests 决定调度预留与 QoS；limits 决定运行时限制：CPU throttle，内存 OOM。

**本集群真实情况**：

```text
QoS: BestEffort 73, Burstable 65, Guaranteed 0
containers_without_requests: 98
containers_without_limits: 112
```

> 这是风险：73 个 BestEffort Pod 在节点压力时最先被驱逐，且大量容器无 requests/limits。

### 3.2 QoS 三档

**一句话**：Guaranteed（requests=limits）、Burstable（部分设置）、BestEffort（不设置）；压力时按 BestEffort → Burstable → Guaranteed 驱逐。

**本集群**：没有 Guaranteed；大量 BestEffort。关键业务应至少 Burstable + 合理 limits。

### 3.3 LimitRange / ResourceQuota

**一句话**：LimitRange 给 namespace 默认/最小/最大；ResourceQuota 限制 namespace 总量/对象数/存储。

**本集群**：

```text
compassio/limitrange/compassio-defaults
compassio/resourcequota/compassio-quota
  pods 4/20, requests.cpu 90m/1, requests.memory 448Mi/3Gi
  limits.cpu 900m/10, limits.memory 1408Mi/10Gi
```

**实验验证**：临时 namespace 加 LimitRange（default=defaultRequest）后，未写 resources 的 Pod
被注入 `100m/128Mi`，QoS 变成 **Guaranteed**；ResourceQuota used 同步增加。实验后已删除 namespace。
证据：[`limitrange-quota-lab.txt`](assets/interview-evidence/limitrange-quota-lab.txt)。

### 3.4 超卖比

**一句话**：用 requests 超卖提高利用率，但必须配合监控、驱逐阈值、QoS 和关键业务保障。

**本集群 m01**：

```text
Allocated resources:
cpu requests 855m (24%), limits 1350m (38%)
memory requests 270Mi (6%), limits 1856Mi (47%)
```

> m01 超卖不高；真正问题是大量 BestEffort、无 requests，调度器无法准确预留。

### 3.5 拓扑打散 / 反亲和

**一句话**：`topologySpreadConstraints` / podAntiAffinity 用于跨节点/可用区打散；看 `maxSkew`、`topologyKey`、`whenUnsatisfiable`。

**本集群**：

- 29 个 Deployment 带 affinity/topologySpread；
- `compassio`、`wecom-adapter` 用 `kubernetes.io/hostname`，有效；
- `tempo3-*` 用 `topology.kubernetes.io/zone`，但节点**没有这个 label**，只有 `zone=test-a/test-b`，
  所以 zone 打散实际是 no-op。

这是一个典型“配置了但没生效”的坑：`topologyKey` 必须在节点上存在。

## 4. 稳定性发布

### 4.1 PDB

**一句话**：限制自愿中断期间最少可用/最大不可用；没有 PDB，drain/升级可能打穿业务。

**本集群**：11 个 PDB。

```text
cnpg-system/pg16-ceph-primary  minAvailable=1  allowedDisruptions=0
kafka/my-cluster-kafka         minAvailable=0  allowedDisruptions=1
compassio/backend              maxUnavailable=1
...
```

- `pg16-ceph-primary` 当前 **allowed disruptions 0**，drain 主库所在节点会被 PDB 阻止；
- Kafka PDB `minAvailable=0` 等于没有保护。

### 4.2 探针三件套

**一句话**：startup 保护慢启动，readiness 控制流量，liveness 触发重启；liveness 过激会雪崩重启。

**本集群**：

```text
liveness 51, readiness 53, startup 10, preStop 1
```

多数 Deployment 有 liveness/readiness，10 个有 startup；只有 `china-study-free` 有 preStop。

### 4.3 优雅退出

**一句话**：Endpoint 摘除 → preStop/排空 → SIGTERM → `terminationGracePeriodSeconds`；端点更新与进程退出存在竞态。

**本集群**：

- `china-study-free`：preStop `sleep 5`，`terminationGracePeriodSeconds: 30`；
- 其余大多数 Deployment 没有 preStop（1/…），依赖应用自己处理 SIGTERM。

```bash
kubectl -n china-study-free get deploy china-study-free -o yaml | grep -A10 preStop
```

## 5. 升级运维

### 5.1 版本偏差策略

**一句话**：先升控制面再升节点；kubelet 最多比 apiserver 老 3 个 minor，不能跳大版本。

**本集群**：6 节点全部 `v1.35.9`，containerd `2.3.2`，零偏差。

### 5.2 cordon / drain

**一句话**：cordon 标记不可调度；drain 驱逐 Pod；要考虑 PDB、DaemonSet、local storage、force。

**验证**：

```bash
kubectl drain worker03 --dry-run=client --ignore-daemonsets --delete-emptydir-data
# node/worker03 cordoned (dry run)
# evicting pod ... (dry run)
# 节点没有被真正 cordon
```

dry-run 显示 worker03 上有 30+ Pod 会被驱逐，DaemonSet 被忽略；实际 drain 还要过 PDB。

### 5.3 节点自愈

**一句话**：Node Controller + kubelet + 云控制器 + NPD 联动；NotReady 打污点、驱逐、修复/重建。

**本集群**：

- 6 节点 `Ready=True`，Memory/Disk/PIDPressure 全 False；
- control-plane 有 `node-role.kubernetes.io/control-plane:NoSchedule` 污点；
- NPD **未部署**，节点自愈主要靠 kubelet + 监控告警 + 人工/脚本。

### 5.4 kured

**一句话**：检测 `/var/run/reboot-required`，用锁/注解逐台重启，避免内核升级同时重启。

**本集群**：**未部署**。内核升级需要人工按“cordon → drain → 重启 → uncordon”编排。

### 5.5 证书轮换

**一句话**：监控证书过期，`kubeadm certs check-expiration/renew`；kubelet 证书轮换；备份证书/kubeconfig。

**本集群**：

```text
leaf certs expire 2027-10-03, residual 326d
CA expire 2036-01-14, residual 9y
kubelet rotateCertificates: true
kubectl get csr -> No resources found
```

## 6. 备份容灾

### 6.1 etcd 快照恢复

**一句话**：`etcdctl snapshot save/restore` 是底线；必须定期恢复演练。

**本集群**：

- CronJob `etcd-backup/etcd-snapshot`，`5 * * * *`；
- 最新快照 133MB，8234 keys，上传 S3；
- 本次只验证了快照生成/状态，没有做生产恢复（避免影响集群）。

### 6.2 Velero

**一句话**：备份/迁移 K8s 资源和 PV，支持 CSI 快照/restic/kopia、定时、跨集群。

**本集群**：**未部署**（无 `velero` namespace/CRD）。
当前备份只有 etcd 快照 + CNPG Barman + PVC 数据（RBD/NFS 无应用级备份编排）。

## 7. 扩展

### 7.1 CRD / Operator

**一句话**：CRD 定义对象，Operator 用 controller 封装运维知识。

**本集群**：

- 146 个 CRD；
- Ceph-CSI Operator、CNPG、Strimzi、Grafana Operator、Sealed Secrets、ArgoCD；
- Ceph-CSI 日志显示 `Driver/ClientProfile` reconcile；
- CNPG 日志显示 `Cluster/ScheduledBackup` default/validate/reconcile。

### 7.2 Admission Webhook

**一句话**：Mutating/Validating 在准入阶段修改/校验；自研 webhook 挂了且 `failurePolicy=Fail` 会让集群无法创建/更新。

**本集群**：

- 12 个 ValidatingWebhookConfiguration、9 个 Mutating；
- 大多数 `failurePolicy=Fail`（cert-manager、CNPG、Tekton、MetalLB）；
- Prometheus admission 是 `Ignore`。

> 这是可用性风险：webhook 后端故障 + Fail 会阻塞对应资源操作。生产要评估 `failurePolicy`、超时、HA。

### 7.3 API Aggregator

**一句话**：把自定义 APIService 聚合进 apiserver，统一入口；要处理证书、HA、权限、稳定性。

**本集群**：

```text
v1beta1.metrics.k8s.io -> kube-system/metrics-server (True)
v1beta1.external.metrics.k8s.io -> monitoring/prometheus-adapter (True)
kubectl top nodes 正常
```

## 8. 多租户

### 8.1 多租户隔离

**一句话**：Namespace + RBAC + NetworkPolicy + Quota/LimitRange + PSA；PSP 1.25 已移除。

**本集群**：

- 29 个 namespace；
- 23 个 NetworkPolicy；
- RBAC Role/RoleBinding 大量存在；
- LimitRange/Quota 只有 `compassio` 一个租户有；
- PSA 标签只有 4 个 namespace：
  - `china-study-free` baseline
  - `etcd-backup` privileged
  - `metallb-system` privileged
  - `tekton-pipelines` restricted

> 大多数业务 namespace 没有 PSA/Quota/LimitRange，隔离不完整。

## 9. 进阶

### 9.1 KEDA

**一句话**：事件驱动扩缩（Kafka/Prometheus/队列），适合 0→1→N；与 HPA 互补但避免同指标冲突。

**本集群**：**未部署**（无 KEDA namespace/CRD）。

### 9.2 VPA 与 HPA

**一句话**：VPA 调 requests/limits，HPA 调副本；不要同时基于 CPU/Memory 打架。

**本集群**：

- HPA 3 个：`compassio-backend`、Tekton 两个 webhook；
- VPA controller 已安装，但 **0 个 VPA 对象**；
- 不存在 VPA/HPA 同指标冲突（因为没 VPA 对象），但也没有 VPA 推荐。

### 9.3 Cilium

**一句话**：eBPF 实现 Pod 网络、Service LB、NetworkPolicy，可替代 kube-proxy。

**本集群**：

```text
Cilium 1.20.4, 6/6
KubeProxyReplacement: True
Routing: Network Native, Host BPF
Masquerading: BPF
Hubble: Ok
```

### 9.4 Gateway API

**一句话**：Ingress 的下一代模型，GatewayClass/Gateway/HTTPRoute 分角色。

**本集群**：

- 6 个 Gateway API CRD 已安装；
- **没有任何 GatewayClass/Gateway/HTTPRoute 资源**；
- 实际入口仍用 Traefik IngressRoute。

> “装了 CRD”不等于“用了 Gateway API”；这是面试常见混淆点。

## 10. 一页命令

```bash
# 控制面
kubectl -n kube-system get pod kube-apiserver-m01 -o jsonpath='{.spec.containers[0].command}'
kubectl get --raw /readyz?verbose
kubectl -n kube-system exec etcd-m01 -- etcdctl ... endpoint status --write-out=table
kubectl get events -A | grep Scheduled

# 节点
grep -E 'cgroupDriver|rotateCertificates' /var/lib/kubelet/config.yaml
crictl version; crictl info
kubectl get csidriver,sc

# 资源
kubectl get pods -A -o json | jq -r '.items[].status.qosClass' | sort | uniq -c
kubectl get limitrange,resourcequota,pdb -A
kubectl describe node m01 | sed -n '/Allocated resources/,/Events/p'

# 稳定性
kubectl get pdb -A
kubectl drain worker03 --dry-run=client --ignore-daemonsets --delete-emptydir-data

# 证书/备份
kubeadm certs check-expiration
kubectl get csr
kubectl -n etcd-backup get cronjob,pods

# 扩展/多租户
kubectl get crd | wc -l
kubectl get validatingwebhookconfigurations -o json | jq ...
kubectl get apiservice | grep metrics
kubectl get ns,networkpolicy,resourcequota,limitrange -A
kubectl get hpa,vpa -A
```
