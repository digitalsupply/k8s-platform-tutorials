# 10 · 三个「不可逆」：操作、状态、决策

> 面试里能把这三条随口说清，通常比背十个命令更能说明你“知道后果”。
>
> **不可逆操作**：`rm -rf`、`mkfs`、`dd`、`wipefs`、`drop database`、`kubectl delete ns`
> → 先备份、先 dry-run、先 `--dry-run=server`。
>
> **不可逆状态**：XFS 不能缩、LVM 缩容可能损数据、etcd 恢复会回退整个集群状态、证书签发后无法撤回。
>
> **不可逆决策**：分区方案、集群网络 CIDR、资源命名规范、云区域选择
> → 事后无法补救，必须在设计阶段定好。
>
> 本章的每条都附本环境实测：
> [`assets/three-irreversibles/`](assets/three-irreversibles/README.md)。

## 1. 不可逆操作

### 1.1 为什么叫“不可逆”

| 操作 | 不可逆点 | 事后能不能补救 |
|---|---|---|
| `rm -rf` | 文件 inode/数据块被释放 | 只能靠备份/快照；`extundelete` 不保证 |
| `mkfs` | 覆盖文件系统元数据 | 几乎不能；等于重新开始 |
| `dd of=/dev/...` | 直接覆盖块设备 | 不能；写多少坏多少 |
| `wipefs` | 抹掉文件系统/分区签名 | 不能；数据可能还在但不可挂载 |
| `DROP DATABASE` | 删除数据库目录/元数据 | 只能靠备份/PITR |
| `kubectl delete ns` | 级联删除 namespace 内所有资源 | 只能靠 Git/备份重建；PVC 可能一起没 |

### 1.2 先备份

- 文件：快照/对象存储版本控制/异地备份；
- 磁盘：`dd` 前先确认 `lsblk`、`blkid`、`wipefs --no-act`；
- 数据库：`pg_dump`/PITR，且**做过恢复演练**；
- K8s：`kubectl get all,cm,secret,ingress,pvc -n <ns> -o yaml > backup.yaml`
  （Secret 要脱敏），以及 GitOps 仓；
- etcd：`etcdctl snapshot save` + `snapshot status` + 定期恢复演练。

### 1.3 先 dry-run

本环境实测：

```text
$ rm --dry-run -rf /tmp/irreversible-demo
rm: unrecognized option '--dry-run'
```

`rm` **没有** dry-run。替代做法是先 `find`/`ls` 预览，或用 `rsync --dry-run --delete`：

```text
$ rsync -a --delete --dry-run -v /tmp/empty/ /tmp/irreversible-demo/
deleting old/junk.txt
deleting old/
deleting keep/data.txt
deleting keep/
(DRY RUN)
```

`mkfs`、`wipefs` 有只读预览：

```text
$ mkfs.xfs -N -f /dev/loop0        # 只打印参数，不写盘
$ wipefs --no-act /dev/loop0       # 只显示签名，不擦除
```

`dd` **没有** dry-run；只能先确认设备：

```text
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
$ blkid /dev/sdX
```

证据：[`evidence/rm-rsync-dryrun.txt`](assets/three-irreversibles/evidence/rm-rsync-dryrun.txt)、
[`evidence/xfs-wipefs-lab.txt`](assets/three-irreversibles/evidence/xfs-wipefs-lab.txt)、
[`evidence/dd-safe.txt`](assets/three-irreversibles/evidence/dd-safe.txt)。

### 1.4 先 `--dry-run=server`

`kubectl delete ns` 实测：

```text
$ kubectl delete ns irreversible-lab --dry-run=client
namespace "irreversible-lab" deleted (dry run)
$ kubectl get ns irreversible-lab
irreversible-lab   Active   1s          # 仍然存在

$ kubectl delete ns irreversible-lab --dry-run=server
namespace "irreversible-lab" deleted (server dry run)
$ kubectl get ns irreversible-lab
irreversible-lab   Active   1s          # 仍然存在

$ kubectl delete ns irreversible-lab
namespace "irreversible-lab" deleted
```

区别：

| 模式 | 请求到 apiserver | 走 admission/webhook | 能发现 |
|---|---|---|---|
| `--dry-run=client` | 否（多数资源只本地校验） | 否 | 参数/语法错误 |
| `--dry-run=server` | 是 | 是 | RBAC、webhook、finalizer、配额、不可变字段 |

**删除 namespace 前必须用 server dry-run**，因为 namespace 删除会触发级联和 finalizer，
client dry-run 看不到这些。

证据：[`evidence/kubectl-dryrun.txt`](assets/three-irreversibles/evidence/kubectl-dryrun.txt)。

### 1.5 数据库：不是所有 DROP 都能回滚

本环境 PostgreSQL 16.15 实测：

```sql
BEGIN;
DROP TABLE t;
ROLLBACK;
SELECT count(*) FROM t;   -- 1，表回来了
```

表级 DDL 在事务里可以回滚。但：

```sql
BEGIN;
DROP DATABASE irreversible_lab;
-- ERROR: DROP DATABASE cannot run inside a transaction block
```

`DROP DATABASE` **不能**放进事务，没有 rollback 安全网。只能：

1. `pg_dump` / PITR 备份；
2. 在副本/临时库演练恢复；
3. 确认连接、权限、对象归属；
4. 再执行。

证据：[`evidence/postgres-drop-database.txt`](assets/three-irreversibles/evidence/postgres-drop-database.txt)。

## 2. 不可逆状态

### 2.1 XFS 不能缩

本环境用 512MB loop 设备实测：

```text
$ xfs_growfs -D 32768 /mnt/xfs
[EXPERIMENTAL] try to shrink unused space 32768, old size is 131072
xfs_growfs: XFS_IOC_FSGROWFSDATA xfsctl failed: Invalid argument
exit=1
after: data blocks=131072   # 大小没变
```

XFS 只支持 grow，不支持 shrink。要缩小 XFS：

```text
备份 → mkfs 新分区 → 恢复数据
```

不能靠 `lvreduce` 直接缩底层 LV，否则文件系统会损坏。

### 2.2 LVM 缩容可能损数据

LVM 本身可以缩，但顺序必须是：

```text
umount
  → e2fsck -f
  → resize2fs <lv> <new-size>     # 先缩文件系统
  → lvreduce -L <new-size> <lv>   # 再缩 LV
  → mount + 校验数据
```

本环境实测：

```text
$ lvreduce --test -L 512M /dev/vg-irrev/lv-irrev
WARNING: Reducing active and open logical volume to 512.00 MiB.
THIS MAY DESTROY YOUR DATA (filesystem etc.)
Do you really want to reduce ...? [y/n]: [n]
Logical volume ... NOT reduced.
```

如果先 `lvreduce` 再 `resize2fs`，文件系统会认为块设备比实际大，
轻则 `fsck` 报错，重则数据丢失。

安全缩 ext4 的实测：

```text
before: 800M LV, 770M fs, 101M used
umount → e2fsck → resize2fs 400M → lvreduce -L 400M
after:  400M LV, 376M fs, 101M used
sha256(data.bin) 不变
```

注意：

- **XFS 没有 shrink 工具**，只能备份重建；
- ext4 可以缩，但必须先缩 FS 再缩 LV；
- 缩之前必须确认文件系统使用量 < 目标大小；
- 生产必须先在快照/副本上演练。

证据：[`evidence/lvm-shrink-lab.txt`](assets/three-irreversibles/evidence/lvm-shrink-lab.txt)。

### 2.3 etcd 恢复会回退整个集群状态

本环境 etcd 快照：

```text
snapshot 11:05  revision 60,243,742  keys 8243  size 133MB
now      12:02  revision 60,290,176
gap      46,434 revisions / 约 57 分钟
```

恢复这个快照意味着：

- 11:05 之后创建/修改的**所有**资源回退：Deployment、Service、ConfigMap、Secret、RBAC、CRD、Lease、Job……
- 不是“只回滚某个 namespace”；
- 控制器会按旧状态重新 reconcile，可能重建已删除的 Pod、覆盖新配置；
- etcd 集群 ID/成员信息可能变化，恢复后要重新加入/重启 apiserver；
- 证书、外部数据库、PVC 数据**不会**跟着回退，容易出现状态不一致。

所以 etcd 恢复是“全集群时间机器”，不是单资源回滚。恢复前必须：

1. 确认快照时间点与业务损失窗口；
2. 停写/隔离流量；
3. 备份当前 etcd（哪怕已经坏了）；
4. 在测试集群演练恢复；
5. 恢复后逐项校验 API、控制器、证书、外部依赖。

证据：[`evidence/etcd-rollback.txt`](assets/three-irreversibles/evidence/etcd-rollback.txt)。

### 2.4 证书签发后无法撤回

本环境 cert-manager 证书：

```text
name: barman-cloud-client
issuer: selfsigned-issuer
duration: 2160h (90d)
renewBefore: 360h (15d)
notAfter: Feb 6 10:19:48 2027 GMT
Kubernetes CSR objects: none
cert-manager CertificateRequest: barman-cloud-client-1 等签发记录
```

严格说证书可以“吊销”（CRL/OCSP），但工程上要按**不可撤回**处理：

- 很多客户端不检查 CRL/OCSP，吊销列表传播慢；
- 自签/内部 CA 没有统一吊销基础设施；
- 证书一旦泄露，最可靠的是**短 TTL + 轮换**，而不是指望吊销；
- 删除 Secret 只能让本集群不再使用，不能保证外部已拷贝的证书失效。

实践：

- 内部证书 90d 以内，关键证书 24h–7d；
- 自动轮换（cert-manager）；
- 私钥不落 Git、不进镜像；
- 泄露时：轮换 + 改信任根 + 审计访问，而不是只点“revoke”。

证据：[`evidence/certificates.txt`](assets/three-irreversibles/evidence/certificates.txt)。

## 3. 不可逆决策

### 3.1 集群网络 CIDR

本环境：

```text
node network        10.0.0.0/24
controlPlaneEndpoint 10.0.0.168:6443
podSubnet           10.244.0.0/16
serviceSubnet       10.96.0.0/12
```

这些一旦铺开就很难改：

- Pod CIDR 写进了 CNI 配置、路由、NetworkPolicy、Cilium identity、Service 后端；
- Service CIDR 写进了 kube-apiserver、kube-proxy、CoreDNS、证书 SAN；
- 节点网段与办公网/VPN/云上 VPC 重叠时，迁移代价极高；
- 不是“10.0.0.0/8 用完”的问题，而是**重叠和路由**问题。

设计阶段要确认：

- 节点/Pod/Service 三段不重叠；
- 与办公网、VPN、IDC、云上 VPC 不重叠；
- 预留足够大的 Pod CIDR（每节点 /24 或更大）；
- LB/VIP 段单独规划。

证据：[`evidence/cluster-decisions.txt`](assets/three-irreversibles/evidence/cluster-decisions.txt)。

### 3.2 分区与存储方案

本环境 PVE 根盘：

```text
Partition Table: gpt
1  1MB    bios_grub
2  1GB    fat32  boot, esp
3  999GB  LVM
```

PVE 用 LVM-thin：

```text
pve/data  794.30g
pve/root   96.00g
pve/swap    8.00g
```

这些决策的后果：

- 选 XFS → 以后不能缩；
- 选 LVM-thin → 可以快照/精简，但池满会拖垮所有 VM；
- 选 MBR → 2TB 限制、分区数量限制；
- 选单盘 → 没有冗余，重建只能靠备份；
- 根盘分区布局改起来通常要重装。

Hyper-V 的 Ubuntu VHDX 也是 MBR + 固定分区（见
[12 虚拟化](../12-proxmox-pve/10-kvm-qemu-virtio-cloud-boot.md)）。

### 3.3 资源命名规范

命名不是“好看”，而是 API 契约：

- namespace 名进入 DNS：`svc.ns.svc.cluster.local`；
- label 进入 Prometheus/Loki/ArgoCD 选择器；
- app 名进入 Helm release、ArgoCD Application、Dashboard、告警；
- 改名 = 迁移，伴随 DNS/证书/监控/权限/CI 全面调整。

建议在第一天定好：

```text
<env>-<domain>-<component>      例如 prod-payment-api
<team>-<system>-<resource>      例如 platform-monitoring-prometheus
```

并写进模板/脚手架，而不是靠 code review 记忆。

### 3.4 云区域 / 可用区

本环境是 on-prem，不涉及云区域；但面试常问：

- 区域决定延迟、合规（数据驻留）、可用区容灾、云产品价格；
- 数据引力一旦形成，迁移成本极高；
- 多区域 active-active 需要应用/数据库改造，不是“加个 DNS”；
- 选错区域，后期只能重建或长期忍受延迟。

原则：**先定数据驻留/合规/延迟，再定区域；区域不是部署细节，是架构决策。**

## 4. 一页检查清单

### 4.1 执行不可逆操作前

```text
[ ] 目标确认：lsblk/blkid/df/kubectl get -o yaml
[ ] 备份：快照/对象存储/pg_dump/etcd snapshot
[ ] 预览：find/rsync --dry-run/wipefs --no-act/mkfs -N
[ ] K8s：kubectl delete --dry-run=server
[ ] DB：在副本上演练恢复，确认 PITR 可用
[ ] 变更窗口/回滚方案/联系人
[ ] 执行后验证：挂载/查询/健康检查/业务 smoke test
```

### 4.2 面试 30 秒回答

```text
不可逆操作：rm -rf、mkfs、dd、wipefs、drop database、kubectl delete ns
  → 先备份、先 dry-run、先 --dry-run=server。

不可逆状态：XFS 不能缩、LVM 缩容可能丢数据、etcd 恢复回退整个集群、
  证书签发后按不可撤回处理。

不可逆决策：分区方案、集群 CIDR、命名规范、云区域
  → 设计阶段定死，事后只能重建/迁移。
```

### 4.3 常见误区

| 误区 | 现实 |
|---|---|
| `rm -rf` 有 dry-run | 没有；用 `find`/`rsync --dry-run` |
| `kubectl delete --dry-run=client` 足够 | 不够；要 `--dry-run=server` 才走 admission |
| XFS 可以 `lvreduce` 缩 | 不能；XFS 只支持 grow |
| LVM 缩容先缩 LV 再缩 FS | 反了；先 `resize2fs` 再 `lvreduce` |
| etcd 恢复只影响 etcd | 影响整个集群状态，外部数据不跟着回退 |
| 证书可以随时吊销 | 客户端不一定检查 CRL/OCSP；按不可撤回设计 |
| CIDR 以后可以改 | 改 Pod/Service CIDR 基本等于重建集群 |

## 5. 一页命令

```bash
# 文件/磁盘预览
find /path -maxdepth 2 -print
rsync -a --delete --dry-run -v /empty/ /target/
mkfs.xfs -N -f /dev/sdX
wipefs --no-act /dev/sdX
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

# K8s
kubectl delete ns <ns> --dry-run=server
kubectl get all,cm,secret,pvc -n <ns> -o yaml > backup.yaml

# 数据库
pg_dump -Fc <db> > <db>.dump
pg_restore --list <db>.dump

# etcd
etcdctl snapshot save snapshot.db
etcdctl snapshot status snapshot.db --write-out=table
etcdctl endpoint status --write-out=table

# 证书
kubectl get certificate -A
openssl x509 -in tls.crt -noout -subject -issuer -dates
```
