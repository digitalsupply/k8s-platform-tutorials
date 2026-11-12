# 10 · 三个「不可逆」面试题

> 详细证据：[09 三个不可逆](../09-incidents-and-readiness/10-three-irreversibles.md)。

## 1. 三个不可逆是什么

**一句话**：不可逆操作、不可逆状态、不可逆决策。

**本环境**：每条都有真机实验，见 `09/assets/three-irreversibles/evidence/`。

## 2. 不可逆操作有哪些

**一句话**：`rm -rf`、`mkfs`、`dd`、`wipefs`、`drop database`、`kubectl delete ns`。

**本环境**：`rm` 没有 dry-run；`mkfs -N`/`wipefs --no-act`/`rsync --dry-run` 可预览；`delete ns` 用 `--dry-run=server`。

## 3. 为什么 `--dry-run=client` 不够

**一句话**：client 只本地校验；server 才走 apiserver、admission、webhook、RBAC、finalizer。

**本环境**：`delete ns --dry-run=client` 和 server 都显示 deleted，但只有 server 能发现准入/级联问题。

## 4. `rm -rf` 怎么防

**一句话**：先 `find`/`ls` 预览，或用 `rsync --dry-run --delete`；生产用快照/回收站。

**本环境**：`rm --dry-run` 直接报 `unrecognized option`。

## 5. `dd` 怎么防

**一句话**：`dd` 没有 dry-run；先 `lsblk`/`blkid` 确认设备，绝不猜 `/dev/sdX`。

**本环境**：`dd --help` 无 dry-run；安全实验只写 `/tmp` 文件。

## 6. `DROP DATABASE` 能回滚吗

**一句话**：不能；它不能放在事务里，没有 rollback。

**本环境**：`BEGIN; DROP TABLE` 可 rollback；`BEGIN; DROP DATABASE` 报 `cannot run inside a transaction block`。

## 7. XFS 能缩容吗

**一句话**：不能；XFS 只支持 grow，缩只能备份重建。

**本环境**：`xfs_growfs -D 32768` 返回 `Invalid argument`，blocks 仍是 131072。

## 8. LVM 缩容怎么才安全

**一句话**：umount → e2fsck → resize2fs → lvreduce，顺序反了会丢数据。

**本环境**：`lvreduce --test` 明确警告 `THIS MAY DESTROY YOUR DATA`；ext4 按顺序缩容后数据 sha256 不变。

## 9. etcd 恢复回退什么

**一句话**：回退整个集群状态，不是单个 namespace。

**本环境**：快照 revision 60,243,742，当前 60,290,176，约 57 分钟；这期间所有资源变更都会丢。

## 10. etcd 恢复后要注意什么

**一句话**：集群 ID/成员可能变、apiserver 要重启、控制器会按旧状态 reconcile、外部数据不跟着回退。

**本环境**：快照 133MB/8234 keys；恢复前必须备份当前 etcd 并在测试集群演练。

## 11. 证书能撤回吗

**一句话**：技术上能吊销，但客户端不一定检查 CRL/OCSP，工程上按不可撤回处理。

**本环境**：`barman-cloud-client` 90d 自签、无 CSR/CRL；靠短 TTL + cert-manager 轮换。

## 12. 为什么 CIDR 是不可逆决策

**一句话**：Pod/Service CIDR 写进 CNI、路由、apiserver、CoreDNS，改基本等于重建集群。

**本环境**：podSubnet `10.244.0.0/16`、serviceSubnet `10.96.0.0/12`、节点 `10.0.0.0/24`、VIP `10.0.0.168`。

## 13. 分区方案为什么不可逆

**一句话**：分区表/文件系统/LVM 布局改起来通常要重装或长时间停机。

**本环境**：PVE 根盘 GPT（bios_grub + ESP + LVM），`pve/data` 794G LVM-thin；XFS 不能缩。

## 14. 命名规范为什么不可逆

**一句话**：namespace/label/app 名进入 DNS、监控、告警、RBAC、ArgoCD，改名等于迁移。

**本环境**：`svc.ns.svc.cluster.local`、Prometheus/Loki label、ArgoCD Application 都依赖名字。

## 15. 云区域怎么选

**一句话**：先看合规/数据驻留/延迟，再看价格；区域错了只能重建或长期忍受。

**本环境**：on-prem 不涉及；原则同样适用于多 IDC/多可用区。

## 16. 面试 30 秒怎么答

```text
不可逆操作：rm -rf、mkfs、dd、wipefs、drop database、kubectl delete ns
  → 先备份、先 dry-run、先 --dry-run=server。

不可逆状态：XFS 不能缩、LVM 缩容可能丢数据、etcd 恢复回退整个集群、
  证书签发后按不可撤回处理。

不可逆决策：分区、CIDR、命名、区域
  → 设计阶段定死，事后只能重建/迁移。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| 操作 | rm/mkfs/dd/wipefs/drop db/delete ns |
| K8s dry-run | client 本地；server 走 admission |
| rm | 没有 dry-run；find/rsync 预览 |
| dd | 没有 dry-run；先 lsblk/blkid |
| DROP DATABASE | 不能进事务，无 rollback |
| XFS | 只能 grow，不能 shrink |
| LVM | 先 resize2fs 再 lvreduce |
| etcd | 恢复 = 全集群时间机器 |
| 证书 | 按不可撤回设计，短 TTL + 轮换 |
| CIDR | 改 = 重建集群 |
| 分区 | 改 = 重装/停机 |
| 命名 | 改 = 迁移 |
| 区域 | 合规/延迟优先 |
