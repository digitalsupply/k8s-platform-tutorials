# CNPG 资产

| 文件 | 说明 |
|---|---|
| `cluster.yaml` | `Cluster pg16-ceph` 的目标状态（2 实例、PostgreSQL 16） |
| `objectstore.yaml` | Barman Cloud Plugin 的 `ObjectStore`（S3/RGW） |
| `scheduledbackup.yaml` | 每日 base backup |
| `sealedsecret-pg-*.yaml` | 数据库用户、超级用户、S3 凭据（SealedSecret 密文） |
| `plugin-barman-cloud-0.15.1.yaml` | Barman Cloud Plugin 清单 |
| `cnpg-1.30.1.yaml` | CNPG Operator 1.30.1 all-in-one 清单 |
| `live/` | 从集群导出的 Cluster/ObjectStore/ScheduledBackup 实时状态（已去运行时字段） |

注意：

- 内置 `barmanObjectStore` 在 CNPG 1.31 将移除，本目录已经是 Plugin 方案；
- `spec.instances`、`status`、默认值会被 Operator 回写，ArgoCD 需要 `ignoreDifferences`；
- SealedSecret 只能被本集群的 controller 解密，换集群必须重新密封。
