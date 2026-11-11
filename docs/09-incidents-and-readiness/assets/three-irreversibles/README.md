# 三个「不可逆」：本环境实测

对应教程：[`../../10-three-irreversibles.md`](../../10-three-irreversibles.md)。

## 证据

| 文件 | 内容 |
|---|---|
| `evidence/kubectl-dryrun.txt` | `--dry-run=client` vs `--dry-run=server`，对象仍在，真实删除 |
| `evidence/rm-rsync-dryrun.txt` | `rm` 无 dry-run；`rsync --dry-run --delete` 预览 |
| `evidence/dd-safe.txt` | `dd` 无 dry-run；安全写文件 vs 危险写块设备 |
| `evidence/xfs-wipefs-lab.txt` | `mkfs.xfs -N`、`wipefs --no-act`、XFS shrink 失败、`wipefs -a` |
| `evidence/lvm-shrink-lab.txt` | `lvreduce --test` 警告；ext4 安全缩容顺序；数据校验 |
| `evidence/postgres-drop-database.txt` | 表 DDL 可回滚；`DROP DATABASE` 不能在事务里 |
| `evidence/etcd-rollback.txt` | 快照 revision 60,243,742 vs 当前 60,290,176；约 57 分钟回退窗口 |
| `evidence/certificates.txt` | 90d 自签证书、无 CSR/CRL；轮换而非吊销 |
| `evidence/cluster-decisions.txt` | Pod/Service CIDR、节点网段、PVE GPT/LVM 布局 |

## 关键结论

- `rm`/`dd` 没有 dry-run；`mkfs -N`、`wipefs --no-act`、`rsync --dry-run` 可预览；
- `kubectl --dry-run=client` 不经过 admission，删除 namespace 必须用 `--dry-run=server`；
- XFS 只支持 grow；实测 shrink 返回 `Invalid argument`，blocks 不变；
- LVM 缩容必须先 `resize2fs` 再 `lvreduce`；`lvreduce --test` 会明确警告可能丢数据；
- `DROP DATABASE` 不能放进事务，没有 rollback；
- etcd 快照恢复会回退整个集群状态，不是单 namespace；
- 证书按不可撤回设计：短 TTL + 自动轮换，不能依赖 CRL/OCSP；
- CIDR/分区/命名/区域是设计期决策，事后只能重建或迁移。

## 安全说明

- 所有 XFS/LVM 实验都在 `/tmp` 的 loop 设备上完成，已清理；
- 数据库实验使用独立 `irreversible_lab` 库，已删除；
- namespace dry-run 实验使用 `irreversible-lab`，已删除；
- 没有对生产磁盘、生产库、生产 namespace 执行破坏性操作。
