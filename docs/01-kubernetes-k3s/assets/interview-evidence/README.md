# K8s 核心考点证据（2026-11-11）

对应教程：[`../../10-k8s-core-evidence.md`](../../10-k8s-core-evidence.md)。

所有命令只读；唯一写入是临时 `interview-lab` namespace（LimitRange/Quota 实验），已删除。

| 文件 | 内容 |
|---|---|
| `m01-evidence.txt` | 主采集：版本、控制面参数、apiserver、etcd、备份、kubelet/CRI/CNI/CSI、QoS、LimitRange/Quota/PDB、探针、证书、节点、CRD/Webhook、多租户、Gateway/Cilium |
| `etcd-metrics-summary.txt` | etcd WAL fsync/backend commit p99、DB size、leader |
| `operator-logs.txt` | CNPG/Ceph-CSI Operator reconcile 日志（证明 Operator 模式） |
| `hpa-vpa-pdb.txt` | HPA 3、VPA 0、PDB 11、LimitRange/Quota |
| `scheduler-events.txt` | 调度事件、Pod→Node 分布 |
| `controller-reconcile.txt` | Deployment→RS ownerReferences、controller-manager 参数 |
| `probes-topology.txt` | 探针/preStop、topologySpread 细节 |
| `prestop-zones.txt` | preStop 示例、节点 zone label |
| `cert-gateway-absent.txt` | Gateway 资源为空、KEDA/Velero/Kured 缺失 |
| `kubelet-certs.txt` | cgroupDriver、rotateCertificates、CSR |
| `drain-dryrun.txt` | worker03 drain dry-run |
| `limitrange-quota-lab.txt` | LimitRange 默认注入 + ResourceQuota used |
| `apiservice-cilium.txt` | metrics APIService、kubectl top、Cilium 配置 |
| `cilium-status.txt` | Cilium KPR/native/Hubble 状态 |

## 关键结论

- apiserver：`Node,RBAC` + `NodeRestriction`，3 副本；
- etcd：3.6.6、3 member、133MB/37MB、quota 2.1GB、WAL fsync p99 1ms；
- QoS：BestEffort 73、Burstable 65、Guaranteed 0；98 容器无 requests；
- LimitRange 实验：无 resources 的 Pod 被注入 100m/128Mi，QoS=Guaranteed；
- PDB 11 个，CNPG primary allowed disruptions=0；
- 探针：liveness 51/readiness 53/startup 10/preStop 1；
- topology：29 个 Deployment 有约束，但 Tempo 的 `topology.kubernetes.io/zone` 节点没有；
- 证书：leaf 326d，CA 9y，rotateCertificates=true；
- 备份：etcd 每小时 133MB/8234 keys 上传 S3，未做生产恢复演练；
- 扩展：146 CRD、12 Validating/9 Mutating webhook、metrics APIService 可用；
- 缺失：NPD、Kured、Velero、KEDA 未部署；Gateway API 只有 CRD，无资源。
