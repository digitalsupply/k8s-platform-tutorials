# Ceph-CSI Operator 资产

本目录保存 2026-11-09 升级/迁移前后的关键 YAML。

| 文件 | 说明 |
|---|---|
| `drivers-values.yaml` | `platform-ceph-csi-drivers` 的 Helm values（Driver + CephConnection + ClientProfile） |
| `drivers-resources/imageset.yaml` | Ceph-CSI 镜像集（升级时用于固定 sidecar 版本） |
| `storageclass.yaml` | StorageClass `ceph-rbd-sc`（Retain） |
| `sealedsecret-csi-rbd-secret.yaml` | RBD 认证 Secret 的 SealedSecret（密文） |
| `backup-20261109/` | 升级前从集群导出的 CSIDriver、RBAC/Workloads ConfigMap、StorageClass |
| `live/` | 迁移完成后从集群导出的 Driver/CephConnection/ClientProfile/StorageClass/CSIDriver |

说明：

- `helm list -n ceph-csi-rbd` 为空是预期状态：驱动由 Operator 根据 CR 生成；
- `live/` 里的 YAML 已去掉 `metadata.managedFields`、`resourceVersion`、`status` 等运行时字段；
- 实际使用前请替换 mon 地址、clusterID、pool、Secret 名称。
