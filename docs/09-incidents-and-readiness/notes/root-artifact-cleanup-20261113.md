# /root 老旧软件/安装包清理（2026-11-13）

> 范围：K8s 6 节点（m01/master01/master02/worker01-03）、Ceph 3 节点（ceph-01/02/03）、
> GitLab 201、Harbor 202。只删除**已确认不再被进程/容器使用**的旧版本、安装包和重复副本；
> 保留 etcd/升级快照、活跃项目、Hermes 运行目录、Harbor 离线安装包。

## 删除清单

### K8s 节点

| 对象 | 原因 | 约大小 |
|---|---|---:|
| `/root/ctr-backup-20261002-*` | containerd 1.7.22 升级前备份；当前 2.3.2 | 64M × 9 |
| `containerd-1.7.22-linux-amd64.tar.gz` | 旧安装包；当前 2.3.2 | 46M × 5 |
| `runc.amd64` | 旧 runc 安装包；当前 1.4.3 | 11M × 5 |
| `/root/runsc` | 与 `/usr/local/bin/runsc` 同 hash 的重复副本 | 64M × 5 |
| `/root/containerd-shim-runsc-v1` | 与已安装副本同 hash | 29M × 4 |
| `k9s_Linux_amd64.tar.gz` | 旧安装包；`/usr/local/bin/k9s` 已存在 | 40M |
| `argocd-linux-amd64` | 旧 CLI 安装包；`/usr/local/bin/argocd` 已存在 | 147M |
| `istio-1.22.6` | 无 Istio 命名空间/工作负载；`istioctl` 已单独安装 | 147M |

### Ceph 节点

| 对象 | 原因 | 约大小 |
|---|---|---:|
| `node_exporter-1.8.2.linux-amd64` | 旧安装包；实际用容器 v1.5.0 | 20M × 3 |
| `mysqld_exporter-0.15.1.linux-amd64` | 无 mysqld 进程 | 16M |
| `apache-zookeeper-3.8.5-bin.tar.gz` | 无 ZooKeeper 进程 | 15M |
| `haog_nginx.tar.gz` | 旧镜像归档；无对应容器 | 58M |
| `kafka_2.13-3.8.1` | 旧 Kafka 目录；无 Kafka 进程；K8s 侧 Kafka 4.1.2 | 121M |

### GitLab 201 / Harbor 202

| 对象 | 原因 | 约大小 |
|---|---|---:|
| `/root/lazygit` | 与 `/usr/local/bin/lazygit` 同 hash | 19M |
| `/root/lazygit.tar.gz` | 旧安装包 | 6.7M |
| `/root/harbor/harbor.v2.14.5.tar.gz` | Harbor 离线安装包内的重复镜像归档；Harbor 已运行 | 722M |

## 保留项（明确不删）

- K8s `k8s-upgrade-1.29-to-1.35/work/`：etcd 升级快照 + manifest 备份（数据，不是旧版本）；
- `etcd-snapshot-2026-01-15.db`：历史备份；
- `/root/.hermes`（6.2G）：进程正在运行（gateway/browser harness），不是旧版本；
- `/root/.cache/ms-playwright`：Hermes 浏览器依赖；
- `ChinaStudyFree`、`DeepTutor`、`pi-textbook`、`human-atlas` 等：活跃项目仓库；
- `/root/harbor-offline-installer-v2.14.5.tgz`：保留一份 Harbor 离线恢复包；
- `HivisionIDPhotos`、`wordpress`：未确认是纯旧版本还是应用/数据，暂不删除。

## 验证

```text
kubectl get nodes                         6/6 Ready，v1.35.9
kubectl get pods -A（非 Running/Completed） 无
containerd 2.3.2 / runc 1.4.3 / runsc     正常
ceph -s                                   HEALTH_OK，6 OSD up/in
docker ps（ceph-02）                       Ceph 容器正常
Harbor 202                                HTTP 200，10 容器 running
```

## 结果

- K8s 侧约回收 **1.6GiB**；
- Ceph 侧约回收 **264MiB**；
- Harbor 侧约回收 **721MiB**；
- GitLab 侧约回收 **25MiB**；
- 合计约 **2.6GiB**。

> 没有删除任何运行中的二进制、容器、etcd/PVC 数据或项目仓库。
