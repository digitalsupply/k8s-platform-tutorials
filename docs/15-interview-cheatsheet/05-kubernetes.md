# 05 · Kubernetes 面试核心考点

> 详细证据与原理：[01 Kubernetes 10-k8s-core-evidence](../01-kubernetes-k3s/10-k8s-core-evidence.md)。
> 本章是“一句话 + 本环境实测状态 + 纠偏”。

## 控制面

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| kube-apiserver | 认证→授权→准入；唯一直接读写 etcd 的入口 | `--authorization-mode=Node,RBAC`；`NodeRestriction`；3 副本/readyz 全过 |
| etcd | 对 fsync 敏感；独立 SSD；监控 WAL fsync；低峰逐节点 defrag；quota 2GB | 3.6.6，3 member，133MB/37MB，quota 2.1GB，WAL fsync p99 1ms，无 alarm |
| kube-scheduler | Filter→Score→Reserve/Permit/Bind | `--leader-elect=true`；事件 `Successfully assigned` |
| kube-controller-manager | 运行 controller，持续 reconcile | `--controllers=*`；RS ownerRef=Deployment；CNPG/Ceph operator reconcile |

## 节点面

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| kubelet | 节点 agent；cgroup driver 必须与运行时一致，推荐 systemd | cgroupDriver=systemd；containerd 2.3.2；rotateCertificates=true |
| CRI | 容器运行时接口；containerd/CRI-O；dockershim 已移除 | containerd 2.3.2，`crictl` OK |
| CNI | Pod IP/互通/NetworkPolicy | Cilium 1.20.4，6/6，KPR=true，native |
| CSI | PV 创建/挂载/扩容/快照 | `rbd.csi.ceph.com`，17 PV RWO |
| node-problem-detector | 上报 NodeCondition/Event | **未部署**；靠 kubelet + node-exporter |

## 资源模型

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| requests/limits | requests 管调度/QoS；limits 管 CPU throttle/内存 OOM | 73 BestEffort、65 Burstable、0 Guaranteed；98 容器无 requests |
| QoS 三档 | Guaranteed=req=limit；Burstable 部分；BestEffort 不设 | 无 Guaranteed；大量 BestEffort |
| LimitRange/Quota | LimitRange 默认/最小/最大；Quota 总量/对象/存储 | compassio 有 LR+Quota；实验验证注入默认值→Guaranteed |
| 超卖比 | requests 超卖提利用率，但要监控/驱逐/QoS | m01 cpu req 24%/limit 38%；mem req 6%/limit 47% |
| 拓扑打散/反亲和 | 看 maxSkew/topologyKey/whenUnsatisfiable | 29 个 Deployment 有约束；Tempo 用 `topology.kubernetes.io/zone` 但节点无此 label，**实际 no-op** |

## 稳定性发布

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| PDB | 限制自愿中断的最少可用/最大不可用 | 11 个 PDB；CNPG primary allowed=0；Kafka minAvailable=0 |
| 探针三件套 | startup 保护慢启动；readiness 控流量；liveness 重启 | live 51/ready 53/startup 10/preStop 1 |
| 优雅退出 | 摘 Endpoint→preStop→SIGTERM→grace | `china-study-free` preStop sleep 5 + grace 30；多数无 preStop |

## 升级运维

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| 版本偏差 | 先控制面后节点；kubelet 最多老 3 minor | 6 节点全 1.35.9，零偏差 |
| cordon/drain | cordon 不可调度；drain 驱逐；看 PDB/DS/local storage | dry-run worker03 显示 30+ Pod 驱逐、DS 忽略、节点未真正 cordon |
| 节点自愈 | Node Controller+kubelet+NPD/云控制器 | 6 节点 Ready；压力全 False；NPD 未部署 |
| kured | 检测 reboot-required，逐台重启 | **未部署** |
| 证书轮换 | check/renew + kubelet rotation + 备份 | leaf 326d，CA 9y，rotateCertificates=true，无 CSRs |

## 备份容灾

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| etcd 快照恢复 | save/restore 是底线；必须演练 | 每小时 CronJob，133MB/8234 keys，上传 S3；未做生产恢复 |
| Velero | 备份/迁移资源+PV；CSI/restic/kopia | **未部署**；只有 etcd+CNPG 备份 |

## 扩展

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| CRD/Operator | CRD 定义对象；Operator 封装运维知识 | 146 CRD；Ceph-CSI/CNPG/Strimzi/Grafana/Sealed/Argo |
| Admission Webhook | Mutating/Validating；Fail 会阻塞资源操作 | 12 Validating/9 Mutating；多数 failurePolicy=Fail |
| API Aggregator | 自定义 APIService 聚合进 apiserver | metrics.k8s.io + external.metrics 均 True；top 正常 |

## 多租户

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| 多租户隔离 | Namespace+RBAC+NetworkPolicy+Quota/LimitRange+PSA | 29 ns、23 NetworkPolicy；Quota/LR 只有 compassio；PSA 只有 4 个 ns |

## 进阶

| 考点 | 一句话答案 | 本环境实测 |
|---|---|---|
| KEDA | 事件驱动扩缩 0→1→N | **未部署** |
| VPA/HPA | VPA 调 requests，HPA 调副本；别同指标打架 | HPA 3；VPA controller 有、VPA 对象 0 |
| Cilium | eBPF Pod 网络/Service LB/NetworkPolicy | 1.20.4，KPR=true，native，Hubble OK |
| Gateway API | GatewayClass/Gateway/HTTPRoute | 6 CRD 已装，**0 个 Gateway/HTTPRoute 资源**；入口仍 Traefik IngressRoute |

## 本环境纠偏（重点）

1. **“配置了 topologySpread 就一定打散”**  
   Tempo 用 `topology.kubernetes.io/zone`，但节点只有 `zone=test-a/test-b`，没有标准 zone label，
   spread 实际不生效。`topologyKey` 必须在节点上有对应 label。

2. **“有 PDB 就安全”**  
   `pg16-ceph-primary` minAvailable=1，当前 allowed disruptions=0，drain 主库节点会被阻止；
   Kafka PDB `minAvailable=0` 基本没有保护。

3. **“探针越多越好”**  
   本集群 51 liveness/53 readiness，但只有 1 个 preStop。liveness 过激会雪崩重启；
   优雅退出不能只靠 probe。

4. **“装了 Gateway API CRD 就是用了 Gateway API”**  
   只有 CRD，没有 GatewayClass/Gateway/HTTPRoute；实际入口是 Traefik IngressRoute。

5. **“Velero/KEDA/Kured 是标配”**  
   本环境都没有部署；不要假设面试环境一定有。

6. **“有 etcd 备份就等于有容灾”**  
   备份成功 ≠ 能恢复；必须做恢复演练。本环境只验证了快照状态。
