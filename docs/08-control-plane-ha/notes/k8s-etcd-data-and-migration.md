# Kubernetes etcd：数据存放、核心特性与集群迁移指南

> 适用对象：kubeadm、二进制 / systemd、k3s、RKE2、Kubespray、OpenShift 等自建集群；EKS / GKE / AKS 等托管集群会单独标注。
> 更新日期：2026-11-05

## 目录

- [一、etcd 数据存在哪](#一etcd-数据存在哪)
- [二、etcd 的重要特性](#二etcd-的重要特性)
- [三、集群迁移注意事项](#三集群迁移注意事项)
- [四、数据目录：是谁的？在哪？具体路径？](#四数据目录是谁的在哪儿具体路径)
- [五、常用 etcdctl / etcdutl 命令速查](#五常用-etcdctl--etcdutl-命令速查)
- [六、本集群故障场景实战（3 节点 etcd）](#六本集群故障场景实战3-节点-etcd)
- [七、参考资料](#七参考资料)

---

## 一、etcd 数据存在哪

### 1.1 结论

etcd 的数据**不在内存里持久化，也不在 kube-apiserver 里**，而是落在每个 etcd 成员所在节点的本地磁盘目录中，由 etcd 启动参数 `--data-dir` 指定。

Kubernetes 只是 etcd 的客户端：kube-apiserver 通过 2379 端口读写 etcd，所有 API 对象最终都进入这个目录里的 bbolt 数据库 + WAL 日志。

具体路径取决于部署方式：

| 部署方式 | 典型数据目录 | 说明 |
|---|---|---|
| kubeadm 默认（stacked etcd） | `/var/lib/etcd` | etcd 以 **static Pod** 跑在控制平面节点，hostPath 把宿主机 `/var/lib/etcd` 挂进容器；清单在 `/etc/kubernetes/manifests/etcd.yaml` |
| kubeadm 外部 etcd | `--data-dir` 指定，常见 `/var/lib/etcd` 或 `/var/lib/etcd/default.etcd` | 由你自己的 systemd / 二进制启动参数决定 |
| k3s（嵌入式 etcd） | `/var/lib/rancher/k3s/server/db/etcd` | 未启用 embedded etcd 时默认是 sqlite：`.../server/db/state.db` |
| RKE2 | `/var/lib/rancher/rke2/server/db/etcd` | 同上 |
| Kubespray | `/var/lib/etcd`（变量 `etcd_data_dir`） | 视 inventory 配置 |
| OpenShift | `/var/lib/etcd/member` | 静态 Pod 方式 |
| EKS / GKE / AKS 等托管集群 | 看不到 | etcd 由云厂商托管，只暴露 API，不能直接快照 / 登录 |

> 注意：etcd 二进制自身的默认目录是 `$HOME/default.etcd`，`/var/lib/etcd` 是 kubeadm / 发行版约定的路径。**一定要以实际启动参数为准，不要凭印象。**
>
> 更详细的归属关系、目录内部结构和各发行版具体路径见[第四节](#四数据目录是谁的在哪儿具体路径)。

### 1.2 数据目录结构

```
/var/lib/etcd/
└── member/
    ├── wal/     # Write-Ahead Log，每次事务先落 WAL，保证崩溃恢复
    │   └── 0000000000000000-0000000000000000.wal
    └── snap/    # 周期性快照 + 当前数据库文件
        ├── db              # bbolt(BoltDB) 主数据库文件
        └── *.snap          # 历史快照
```

- `member/snap/db` 是真正的键值数据库文件；`member/wal/*.wal` 是预写日志。
- 数据目录还隐含**集群 / 成员身份信息**（cluster ID、member ID），所以**不能把运行中的目录直接 `cp` 到另一台机器启动**，否则会出现相同 member ID 的双写 / 脑裂。
- TLS 证书不在数据目录，而在 `/etc/kubernetes/pki/etcd/`（`ca.crt`、`server.crt/key`、`peer.crt/key`、`healthcheck-client.*`、`apiserver-etcd-client.*`）。

### 1.3 如何快速确认本集群的位置

```bash
# 1) 看进程启动参数（最准）
ps -ef | grep '[e]tcd'
# 或
systemctl cat etcd | grep -i data-dir

# 2) kubeadm stacked：看 static pod 清单
grep -n -- '--data-dir' /etc/kubernetes/manifests/etcd.yaml

# 3) 看成员与健康状态
export ETCDCTL_API=3
etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# 4) 看数据目录大小
du -sh /var/lib/etcd
ls -lh /var/lib/etcd/member/wal /var/lib/etcd/member/snap
```

### 1.4 数据目录里到底存了什么

Kubernetes 的 key 默认以 `--etcd-prefix=/registry` 为前缀（kube-apiserver 参数），例如：

- `/registry/pods/<namespace>/<name>`
- `/registry/services/specs/...`、`/registry/services/endpoints/...`
- `/registry/configmaps/...`、`/registry/secrets/...`
- `/registry/namespaces/...`、`/registry/nodes/...`
- `/registry/events/...`（事件量大，通常带 lease / TTL）
- `/registry/masterleases/...`（控制平面主节点租约）等

所以 etcd 里不只是"业务数据"，**集群的所有状态（RBAC、CRD、Lease、Event、Service 端点、控制器状态）都在里面**。

---

## 二、etcd 的重要特性

| 特性 | 含义 | 对 K8s 的意义 |
|---|---|---|
| **Raft 共识** | Leader 选举 + 日志复制 + 多数派提交 | 强一致；奇数成员，3 节点容忍 1 台故障，5 节点容忍 2 台 |
| **强一致 / 线性一致读写** | 写成功即已提交到多数派；读默认线性一致 | API 写成功后不会"读不到"；resourceVersion 语义可靠 |
| **MVCC + Revision** | 每个事务生成全局递增 revision，保留历史版本 | 支撑 `resourceVersion`、List + Watch、乐观并发（CAS） |
| **Watch（长连接）** | 客户端可从某个 revision 开始订阅 key 变化 | kube-apiserver 的 informer / watch cache 基础；避免轮询 |
| **事务 Txn** | 多 key 原子操作 + Compare（CAS） | K8s 更新对象时的乐观锁（resourceVersion 不匹配则冲突） |
| **Lease / TTL** | 租约绑定 key，需定期 KeepAlive，过期自动删除 | Event TTL、节点租约、控制器主备选举 |
| **扁平 Key Space + 前缀范围查询** | 按字典序排列，支持 prefix / range | 天然适合 `/registry/...` 这种层级命名 |
| **Compaction / Defrag** | compaction 清理历史版本；defrag 回收文件空洞 | 不 compact 会撑爆 quota；bbolt 删数据不自动缩文件 |
| **Quota（默认 2GiB）** | 超过 `--quota-backend-bytes` 触发 NOSPACE 告警，集群变只读 | 生产必须监控 db 大小，定期 compact / defrag |
| **快照 Snapshot** | 一致性备份，可离线恢复 | 唯一的官方备份 / 迁移手段（`etcdctl` / `etcdutl snapshot`） |
| **mTLS + 证书认证** | peer / client 双向 TLS；也支持 RBAC | K8s 用客户端证书认证，**不启用 etcd 自带 auth 用户体系** |
| **Learner 成员** | 新成员先以 learner 加入，不参与投票，追平后 promote | 安全扩容 / 替换成员，避免拖慢 quorum |
| **gRPC API / clientv3** | 高性能 gRPC，另有 HTTP/JSON gateway | apiserver 通过 clientv3 访问 |
| **CP 系统（CAP）** | 网络分区时优先一致性，失去多数派则不可写 | 机房断网 / 脑裂时宁可不可用，也不会写出冲突数据 |

**几个容易忽略的点：**

- 性能瓶颈通常是**磁盘 fsync 延迟和网络 RTT**，不是 CPU。生产要用本地 SSD / NVMe，不要放 NFS / iSCSI。
- 不适合存大对象、高写入量；单个请求有大小限制，大 ConfigMap / 大 CRD 会显著撑大 DB。
- bbolt **删除数据不会自动缩小文件**，必须 defrag；defrag 会阻塞该成员，需逐个维护窗口做。
- etcd 的"高可用"依赖**多数派**：偶数成员不会增加容错，2 节点反而比 1 节点更脆弱。
- etcd 默认 quota 是 2GiB（`--quota-backend-bytes`），超限后集群进入只读（NOSPACE），必须先 compaction + defrag + 解除告警。

---

## 三、集群迁移注意事项

先明确你属于哪种迁移，处理方式完全不同：

| 场景 | 是否保留集群身份 | 推荐方式 |
|---|---|---|
| A. 只换 etcd 节点 / IP（控制平面不动） | 保留 | 逐台 `member add`(learner) → 追平 → `promote` → `member remove`；或快照恢复 + 更新 apiserver `--etcd-servers` |
| B. 整个控制平面搬到新机器 / 新机房 | 保留 | 快照 + PKI + 配置一起迁移；旧集群必须停机；worker 重新指向新 apiserver |
| C. 换集群 / 换云 / 换发行版 | 不保留 | 新建集群 + Velero / 清单 / PV 数据迁移；托管 etcd 无法直接快照 |
| D. stacked → 外部 etcd / 版本升级 | 保留 | 先备份，再按官方升级路径逐个小版本滚动；stacked→external 无官方原地转换，通常"恢复 + 改 apiserver 指向" |

### 3.1 迁移前必须做的准备

**备份四件套（缺一不可）：**

1. **etcd 快照**（数据）
2. **PKI 证书**：`/etc/kubernetes/pki/`（尤其 etcd、CA、apiserver、`sa.key` / `sa.pub`）
3. **集群配置**：`/etc/kubernetes/manifests/`、kubeadm-config、kubelet 配置、CNI 配置、云厂商 cloud-config、kubeconfig
4. **加密配置**：如果启用了 `EncryptionConfiguration`，密钥文件必须一起备份，否则恢复后 Secret 无法解密

```bash
# 备份：用 etcdctl snapshot save（3.6 仍如此）；etcdutl 只负责 status / restore
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-$(date +%F-%H%M).db

# 校验快照完整性 + 看 revision / hash
etcdutl snapshot status /opt/etcd-*.db -w table
```

**同时检查：**

```bash
etcdctl endpoint status --cluster -w table   # leader、raftIndex、dbSize、isLearner
etcdctl endpoint health --cluster
etcdctl member list -w table
df -h /var/lib/etcd
kubeadm certs check-expiration               # 证书是否临近过期
chronyc tracking / timedatectl               # 时钟偏差（租约 / 心跳 / TLS 都敏感）
```

**必须在测试环境做一次"恢复演练"**，确认快照能起、apiserver 能连、对象数量对得上。没演练过的备份等于没有备份。

### 3.2 通用红线（最容易踩的坑）

- **不要在 etcd 运行时直接复制 data-dir**：WAL 可能不一致。要么 `snapshot save`，要么停服后复制。
- **不要把同一份 data-dir 同时起在两个节点**：cluster ID / member ID 相同会导致脑裂 / 数据损坏。
- **永远保持多数派可用**：3 节点最多同时坏 1 台；迁移时一次只动一台，确认追平再动下一台。
- **旧集群在切换完成前不要继续对外服务**：否则快照之后的新写入会丢；最终切换要有维护窗口（freeze writes）。
- **新旧集群不能同时连同一批 worker 提供服务**，切换要用 LB / VIP / DNS 做原子切换。
- **证书 SAN 要覆盖新 IP / DNS**：换 IP 后 peer / server 证书若不含新地址，TLS 直接握手失败。需要重新签发（或用同一 CA 加 SAN），`apiserver-etcd-client` 证书也要匹配。
- **防火墙 / 网络**：2379（client）、2380（peer）双向放通；peer 流量不要走 NAT；跨机房注意 RTT 和 MTU。
- **磁盘**：本地 SSD，预留至少 2 倍 db 大小空间；迁移前可先 compact（+ 维护窗口 defrag）缩小快照体积。
- **不要同时做两件事**：迁机器和升版本、换 CNI、换证书分开做，否则故障无法定位。
- **版本兼容**：etcd 只能逐个小版本升级（如 3.4→3.5→3.6），且要用 K8s 当前版本支持的 etcd 版本；快照恢复用**同版本或更高版本**的 etcdutl，不要降级恢复。
- **托管集群（EKS / GKE / AKS）没有 etcd 快照**：只能做资源级迁移（Velero、PV / 存储快照、IaC 重建），不要幻想"导出 etcd"。

### 3.3 场景 A：只替换 etcd 成员（推荐滚动方式）

```bash
# 1) 新节点以 learner 加入（不参与投票，不影响 quorum）
etcdctl member add etcd-4 \
  --peer-urls=https://10.0.0.4:2380 --learner=true

# 2) 新节点用相同 token / 集群信息启动，等待追平
etcdctl endpoint status --cluster -w table   # 看 raftIndex 是否接近 leader

# 3) 追平后提升为投票成员
etcdctl member promote <new-member-id>

# 4) 确认健康后，移除旧成员（一次只移除一个）
etcdctl member remove <old-member-id>
```

替换 IP 时：`etcdctl member update <id> --peer-urls=https://<new-ip>:2380`，然后逐个重启 apiserver 并更新其 `--etcd-servers` 列表。

### 3.4 场景 B：快照恢复到新集群 / 新机房

核心命令：

```bash
# 在旧集群做最终快照（切换窗口内，先冻结写入）
# 注意：保存快照只能用 etcdctl，etcdutl 不提供 save
etcdctl snapshot save final.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=... --cert=... --key=...

# 在新节点恢复到全新 data-dir（不要覆盖旧目录）
# K8s 场景强烈建议加 --bump-revision + --mark-compacted，见下方说明
etcdutl snapshot restore final.db \
  --name etcd-1 \
  --initial-cluster etcd-1=https://10.0.0.11:2380,etcd-2=https://10.0.0.12:2380,etcd-3=https://10.0.0.13:2380 \
  --initial-cluster-token k8s-etcd-new \
  --initial-advertise-peer-urls https://10.0.0.11:2380 \
  --bump-revision 1000000000 \
  --mark-compacted \
  --data-dir /var/lib/etcd-new
```

要点：

- 3 节点恢复时，**所有成员都用同一份快照执行 restore**；每个节点只改自己的 `--name`、`--initial-advertise-peer-urls`、peer URL 和 `--data-dir`，`--initial-cluster` 与 `--initial-cluster-token` 必须一致。
- **K8s 场景务必用 `--bump-revision` + `--mark-compacted`**：快照 revision 落后于集群当前 revision 时，apiserver 的 informer / watch cache 可能不会正确刷新，导致控制器行为异常。`--bump-revision` 把 revision 往前推（例如 10 亿），`--mark-compacted` 把这些"虚构"的 revision 标记为已压缩，强制所有 watch 重新 list。
- `etcdutl snapshot restore` 会**重写 member ID 和 cluster ID**，恢复出来的是一个全新逻辑集群，不会误加入旧集群；但旧集群仍必须**完全停机**，避免两套集群同时对外服务、写入分叉。
- 启动时 `--initial-cluster-state=new`。
- 只有 quorum 彻底不可恢复时才用 `--force-new-cluster`（这是 etcd 启动参数，不是 restore 参数；会覆盖成员关系，慎用）。
- 恢复后更新每台 apiserver 的 `--etcd-servers`、`--etcd-cafile/certfile/keyfile`，以及 static pod 清单里的对应参数。
- kubeadm stacked 集群，官方做法是**停 kubelet → 移走 `/etc/kubernetes/manifests` → 恢复到 `/var/lib/etcd` → 移回 manifests → 起 kubelet**，严格按官方文档，不要热覆盖数据目录。

### 3.5 全控制平面搬迁（保留集群身份）的额外注意

- **worker 的 kubelet.conf 里 `server:` 指向 apiserver 地址**。最好用 VIP / DNS 保持地址不变；否则要逐台更新 kubelet 配置并重启 kubelet。
- 保留**同一套 CA**，已有 worker 的 kubelet 客户端证书才继续有效；换 CA 等于所有节点重新 bootstrap。
- 节点主机名 / nodeName 尽量不变（kubelet 证书 CN 是 `system:node:<nodeName>`）；IP 变了要设置 `--node-ip`，kubelet serving 证书 SAN 也要更新。
- 控制平面迁移期间 **worker 上的 Pod 继续运行**，但调度、Service Endpoint 更新、证书轮换、HPA 等会停；要预留维护窗口。
- kubeadm join token 默认 24h 过期、证书 1 年过期，搬迁前先 `kubeadm certs check-expiration`，必要时续期。
- 迁移期间**降低写入压力**：暂停大批量 Job / CronJob、大规模滚动发布、CI 部署，避免 Event 洪水把 etcd 打爆。

### 3.6 切换后验证清单

```bash
kubectl get --raw='/readyz?verbose'
kubectl get --raw='/livez?verbose'
kubectl get --raw='/healthz/etcd'
etcdctl endpoint health --cluster
etcdctl endpoint status --cluster -w table
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running
kubectl get cs 2>/dev/null || true

# 功能验证：能读、能写、能 watch
kubectl create ns migrate-test
kubectl -n migrate-test create configmap t --from-literal=a=b
kubectl -n migrate-test get cm t -w
kubectl -n migrate-test delete ns migrate-test
```

重点比对：**对象数量（Pod / Service / ConfigMap / CRD / RBAC）、CRD 是否齐全、Service Endpoint 是否恢复、controller-manager / scheduler 日志无 etcd 报错、dbSize 与 raftIndex 正常。**

### 3.7 回滚预案

- 旧 etcd 数据目录和快照**保留一个观察窗口**再删除。
- 旧集群停机但**不要销毁**，回滚时先确保新集群完全停止，再启旧集群，避免两套集群同时持有相同 cluster ID。
- 记录切换时间点、快照 revision、DNS / LB 变更，回滚时按同一路径反向操作。

---

## 四、数据目录：是谁的？在哪？具体路径？

### 4.1 一句话回答

**这个数据目录是 etcd 服务进程（etcd server）自己的数据目录，不是 Kubernetes 的、不是 kube-apiserver 的、也不是 kubelet 的。**
它在**每个 etcd 成员所在的那台机器（通常是控制平面节点）的本地磁盘上**，路径由该 etcd 进程的 `--data-dir` 参数决定；kubeadm 默认是宿主机上的 `/var/lib/etcd`。

### 4.2 归属关系（谁写、谁读、谁拥有）

| 问题 | 答案 |
|---|---|
| 谁的数据？ | **etcd 进程**。每个 etcd member 各自维护一份 `--data-dir`，互相独立 |
| 谁在写？ | etcd server 自己（Raft 提交后写 WAL + backend） |
| 谁在读？ | etcd server 自己；kube-apiserver 只通过 2379 端口用 gRPC 访问，**不直接读写文件** |
| 物理位置？ | etcd 进程所在节点的本地磁盘，通常在 `/var/lib/...` 或系统数据分区 |
| 路径谁决定？ | etcd 的 `--data-dir`；优先级：命令行 > 环境变量 `ETCD_DATA_DIR` > 配置文件 > 默认值 |
| 默认值？ | etcd 二进制默认 `$HOME/default.etcd`；kubeadm 显式设为 `/var/lib/etcd` |
| 几个节点几份？ | **每个 member 一份完整副本**（Raft 复制，不是分片）；3 节点就是 3 份 |
| 删了会怎样？ | 该成员数据丢失；若多数成员都删，集群数据不可恢复。**`rm -rf /var/lib/etcd` 是毁灭性操作** |

> 关键认知：kube-apiserver 本身是**无状态**的（除了内存里的 watch cache），它不保存"数据库文件"。你在 etcd 目录里看到的数据，就是整个集群的"唯一事实来源"。

### 4.3 容易混淆的目录对照表

生产上经常把几个 `/var/lib/...` 搞混，这里一次说清：

| 路径 | 属于谁 | 里面是什么 | 迁移时是否必须带走 |
|---|---|---|---|
| `/var/lib/etcd` | **etcd** | 集群全部 API 对象、Lease、RBAC、CRD 等 | **是**（用快照，不要直接拷目录） |
| `/var/lib/kubelet` | kubelet | Pod 目录、卷挂载点、static pod、kubelet 证书 | 一般不需要；PV 数据另算 |
| `/var/lib/containerd`、`/var/lib/docker` | 容器运行时 | 镜像、容器读写层 | 不需要 |
| `/etc/kubernetes` | kubeadm / K8s 组件 | static pod 清单、kubeconfig、配置 | **是** |
| `/etc/kubernetes/pki` | K8s PKI | CA、apiserver、etcd、SA 证书密钥 | **是** |
| `/etc/kubernetes/pki/etcd` | etcd PKI | etcd 的 CA、server、peer、client 证书 | **是** |
| `/etc/cni/net.d`、`/var/lib/cni` | CNI 插件 | 网络配置、IPAM 状态 | 视情况（重建可恢复） |
| `/var/lib/calico`、`/var/lib/cilium` | CNI 插件 | IPAM / 节点状态 | 视情况 |
| `/var/log/pods`、`/var/log/containers` | kubelet / 运行时 | 容器日志 | 否 |
| `/var/lib/etcd` **在 worker 节点上** | — | 通常**不存在**，worker 不跑 etcd | — |

### 4.4 目录内部逐项说明

```
/var/lib/etcd/                      # --data-dir 根目录（宿主机路径）
├── member/                         # 当前 member 的本地状态
│   ├── wal/                        # Write-Ahead Log，预写日志
│   │   ├── 0000000000000000-0000000000000000.wal
│   │   └── 0000000000000001-0000000000000000.wal
│   └── snap/                       # 快照与后端数据库
│       ├── db                      # bbolt 主数据库（全量 key/value）
│       ├── 0000000000000001-0000000000000000.snap
│       └── *.tmp                   # 临时文件
```

| 文件 / 目录 | 作用 | 说明 |
|---|---|---|
| `member/wal/*.wal` | 预写日志 | 每次写事务先 append + fsync，再应用到 backend；崩溃后靠 WAL 回放。每段约 64 MB，写满自动滚动 |
| `member/snap/db` | **数据主体** | bbolt（BoltDB）单文件数据库，包含所有 key、revision、lease、auth、membership 元数据 |
| `member/snap/*.snap` | etcd 内部快照 | etcd 自己定期生成，用于成员追赶 / 恢复；与 `etcdctl snapshot save` 导出的文件同源但用途不同 |
| `member/snap/*.tmp` | 临时文件 | 生成快照过程中的中间文件，正常关闭会清理 |
| 目录权限 | 安全 | 通常 `0700`，属主 `root` 或 `etcd` 用户；不要随意改权限 |

> `etcdctl endpoint status` 里的 `dbSize` 是**后端逻辑大小**；实际磁盘占用 = `db` + `wal` + 历史 `.snap`，通常比 `dbSize` 大。用 `du -sh` 看实际占用，用 `ls -lh` 看文件表观大小。

### 4.5 各部署方式的具体路径

| 部署方式 | 宿主机具体路径 | 备注 |
|---|---|---|
| **kubeadm stacked etcd** | `/var/lib/etcd` | static Pod `etcd.yaml` 里 `hostPath: /var/lib/etcd`，容器内 `--data-dir=/var/lib/etcd`，两者是同一目录 |
| **kubeadm 外部 etcd（官方 systemd 示例）** | `/var/lib/etcd` 或 `/var/lib/etcd/default.etcd` | 以 `ExecStart` 里的 `--data-dir` 为准 |
| **etcd 二进制（未指定）** | `$HOME/default.etcd` | 仅测试会用，生产一定显式指定 |
| **k3s（embedded etcd）** | `/var/lib/rancher/k3s/server/db/etcd` | 默认 sqlite 时是 `/var/lib/rancher/k3s/server/db/state.db` |
| **RKE2** | `/var/lib/rancher/rke2/server/db/etcd` | 同上 |
| **Kubespray** | `/var/lib/etcd` | 由 `etcd_data_dir` 变量控制 |
| **OpenShift / RHCOS** | `/var/lib/etcd/member` | etcd 以 static Pod 运行 |
| **Talos Linux** | `/var/lib/etcd` | 位于系统分区，需通过 `talosctl` 访问 |
| **EKS / GKE / AKS** | 不可见 | 托管控制平面，云厂商管理，无宿主机访问权限 |

### 4.6 精确定位命令（按可靠性排序）

```bash
# 1) 最准：看进程真实启动参数
ps -eo pid,args | grep '[e]tcd'
tr '\0' ' ' < /proc/$(pgrep -x etcd | head -1)/cmdline; echo

# 2) systemd 部署
systemctl cat etcd
systemctl show etcd -p ExecStart

# 3) kubeadm static pod：看 hostPath 和 --data-dir
grep -nE 'data-dir|hostPath|path:' /etc/kubernetes/manifests/etcd.yaml
kubectl -n kube-system get pod etcd-$(hostname) -o yaml | grep -A6 'volumes:'

# 4) 看进程实际打开的文件（需要 lsof）
lsof -p $(pgrep -x etcd | head -1) | grep -E 'db|wal'

# 5) 看目录本身
ls -ld /var/lib/etcd
du -sh /var/lib/etcd
find /var/lib/etcd -maxdepth 3 -type f | head

# 6) 集群视角：成员、大小、leader
etcdctl endpoint status --cluster -w table
etcdctl member list -w table
```

**判断技巧：**

- 如果 `/etc/kubernetes/manifests/etcd.yaml` 存在，且里面有 `hostPath: /var/lib/etcd`，就是 **kubeadm stacked**。
- 如果 `ps` 看到的 etcd 进程带 `--data-dir=/xxx`，那就是**外部 etcd**，以该路径为准。
- 如果宿主机上根本没有 etcd 进程，只有 kube-apiserver 指向某个远程地址，就是**外部 / 托管 etcd**，数据不在本机。
- `kubectl -n kube-system get pod` 里能看到 `etcd-<节点名>` 的是 static pod（mirror pod），删掉它不会删数据，kubelet 会重建。

### 4.7 多节点时数据是怎么放的

- etcd 使用 **Raft 复制**：每个 member 都保存**完整数据副本**，不是分片。
- 3 个控制平面节点 = **3 份完整数据**；`dbSize` 基本一致，WAL 因写入时序略有差异。
- **任意一个健康成员的快照都能恢复整个集群**，不需要把三份拼起来。
- 因此磁盘规划要按"每节点一份"算，而不是"三节点共一份"。
- 恢复时注意 member 身份：**直接复制 data-dir** 会保留原 cluster ID / member ID，绝不能和原集群同时启动；用 `etcdutl snapshot restore` 会重写这两个 ID、生成新逻辑集群，但旧集群仍应停机，避免两套集群同时服务导致写入分叉。

### 4.8 针对数据目录的迁移注意事项

1. **不要在 etcd 运行时 `cp` / `tar` 数据目录**：WAL 和 db 可能不一致，恢复出来是坏的。用 `etcdctl snapshot save`（etcdutl 只做 status / restore）。
2. **停服后复制整目录也不是首选**：只能同版本、同集群身份使用，且绝不能和原集群同时启动；快照更安全、可校验。
3. **恢复必须用新目录**：例如 `--data-dir /var/lib/etcd-new`，确认数据正确后再切换，不要直接覆盖旧目录。
4. **快照不包含 PKI / 配置 / 加密密钥**：`/etc/kubernetes/pki`、manifests、`EncryptionConfiguration` 要单独备份；否则 Secret 恢复后读不出来。
5. **磁盘预留 ≥ 2 倍**：恢复、defrag、快照都需要额外空间；inode 也要检查。
6. **不要放网络存储**：NFS / iSCSI / 云盘多挂载会显著增加 fsync 延迟，甚至损坏 WAL。
7. **权限 / SELinux / AppArmor**：恢复后属主、`0700` 权限、SELinux label 要正确，否则 etcd 起不来。
8. **不要删除 `/var/lib/etcd` 来"重置"**：这是清空整个集群状态；真要重置，先确认已有可用快照和回滚方案。
9. **迁移前可先 compact + defrag**：减小 db 和快照体积；defrag 会阻塞成员，必须逐台在维护窗口做。
10. **监控 quota**：默认 2GiB，超限触发 NOSPACE 只读；迁移前确认 `dbSize` 和 `--quota-backend-bytes` 留有余量。

---

## 五、常用 etcdctl / etcdutl 命令速查

> 约定：`etcdctl` 用于**在线**访问集群（2379）；`etcdutl` 用于**离线**操作数据目录 / 快照文件。
> 下面命令默认在**控制平面节点**上执行，证书路径按 kubeadm 默认值；外部 etcd 请换成自己的路径。

### 5.0 先设置环境变量（避免每条命令重复写证书）

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

# 之后可直接简写
etcdctl member list -w table
etcdctl endpoint status --cluster -w table
```

> 也可以写成 alias：
> `alias etcdctl='etcdctl --endpoints=$ETCDCTL_ENDPOINTS --cacert=$ETCDCTL_CACERT --cert=$ETCDCTL_CERT --key=$ETCDCTL_KEY'`

### 5.1 集群 / 成员状态

```bash
# 成员列表（ID、名称、peer URL、client URL、是否 learner）
etcdctl member list -w table

# 每个成员的 leader / term / raft index / db 大小 / 是否 learner / 错误
etcdctl endpoint status --cluster -w table

# 健康检查（逐成员 + 汇总）
etcdctl endpoint health --cluster
etcdctl endpoint health --cluster -w table

# JSON 输出，便于脚本/jq 处理
etcdctl endpoint status --cluster -w json

# 主动把 leader 迁到指定成员（维护前常用）
etcdctl move-leader <member-id>
```

`endpoint status` 关键列含义：

| 列 | 含义 | 异常信号 |
|---|---|---|
| `DB SIZE` | 后端数据库逻辑大小 | 接近 quota（默认 2GiB）要处理 |
| `IS LEADER` | 是否 leader | 无 leader 或频繁切换说明不稳定 |
| `IS LEARNER` | 是否 learner | 新成员追平前为 true |
| `RAFT INDEX` / `RAFT APPLIED INDEX` | 已提交 / 已应用日志索引 | 成员之间差距持续拉大说明落后 |
| `ERRORS` | 成员错误 | 非空要排查网络 / 磁盘 / 证书 |

### 5.2 键值读写与查看

```bash
# 基本读写
etcdctl put /demo/foo bar
etcdctl get /demo/foo
etcdctl del /demo/foo

# 按前缀查看（K8s 对象都在 /registry 下）
etcdctl get /registry/namespaces --prefix --keys-only
etcdctl get /registry/pods --prefix
etcdctl get /registry/pods --prefix --keys-only | wc -l

# 分页 / 限制条数
etcdctl get /registry/events --prefix --limit=20 --keys-only

# 看历史版本（MVCC）
etcdctl get /registry/namespaces/default --rev=12345

# 只看值
etcdctl get /demo/foo --print-value-only
```

> ⚠️ **绝对不要在生产执行** `etcdctl del /registry --prefix`，这等于删除集群所有 API 对象。

### 5.3 Watch（观察变更）

```bash
# 监听某前缀的实时变更（类似 kubectl get -w 的底层）
etcdctl watch /registry/pods --prefix

# 从指定 revision 开始补事件
etcdctl watch /registry/pods --prefix --rev=12345

# 交互式 watch
etcdctl watch -i
```

> 大量 watch 会占用连接和内存；排障时短时间用，别长期挂生产。

### 5.4 Lease / TTL

```bash
# 申请一个 60 秒租约
etcdctl lease grant 60
# 输出：lease 694d... granted with TTL(60s)

# 绑定 key 到租约（key 会随租约过期自动删除）
etcdctl put /demo/tmp hello --lease=694d...

# 续约（前台持续保活，Ctrl-C 停止）
etcdctl lease keep-alive 694d...

# 查看租约剩余时间和关联 key
etcdctl lease timetolive 694d... --keys

# 列出所有租约
etcdctl lease list

# 主动撤销（关联 key 立即删除）
etcdctl lease revoke 694d...
```

K8s 的 Event TTL、节点租约、控制器主备选举都依赖 Lease，排障时可从这里看。

### 5.5 维护：compact / defrag / alarm

```bash
# 1) 先看是否已有 NOSPACE 告警
etcdctl alarm list

# 2) 查看当前 revision（endpoint status 的 RAFT APPLIED INDEX 近似）
etcdctl endpoint status -w json

# 3) 压缩历史版本（保留最近 rev）
etcdctl compact <revision>

# 4) 碎片整理（bbolt 不会自动缩文件，必须 defrag）
#    单成员执行；多成员必须逐台做，避免同时阻塞 quorum
etcdctl defrag --endpoints=https://10.0.0.11:2379
# 3.5+ 也支持 --cluster，但内部仍是逐台串行，建议手动逐台确认
# etcdctl defrag --cluster

# 5) 解除 NOSPACE 告警（compact + defrag 完成后再执行）
etcdctl alarm disarm
```

> `defrag` 会阻塞该成员、可能触发 leader 切换，务必在维护窗口逐台执行，并确认上一台恢复健康后再做下一台。

### 5.6 备份 / 校验 / 恢复

```bash
# ── 备份（在线，唯一入口是 etcdctl）────────────────────────
ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-$(date +%F-%H%M).db

# ── 校验（etcdutl）────────────────────────────────────────
etcdutl snapshot status /opt/etcd-2026-11-05-1200.db -w table
# 3.5 及以前也可用：etcdctl snapshot status <file> -w table

# ── 恢复（离线，必须先停 etcd；3.6 起恢复只能由 etcdutl 执行）──
etcdutl snapshot restore /opt/etcd-2026-11-05-1200.db \
  --name etcd-1 \
  --initial-cluster etcd-1=https://10.0.0.11:2380,etcd-2=https://10.0.0.12:2380,etcd-3=https://10.0.0.13:2380 \
  --initial-cluster-token k8s-etcd-new \
  --initial-advertise-peer-urls https://10.0.0.11:2380 \
  --bump-revision 1000000000 \
  --mark-compacted \
  --data-dir /var/lib/etcd-new

# ── 离线 defrag / 校验数据目录 ──────────────────────────────
etcdutl defrag --data-dir /var/lib/etcd
# hashkv 接的是 db 文件路径，不是 --data-dir
etcdutl hashkv /var/lib/etcd/member/snap/db
```

> **etcd 3.6 起的分工**：保存快照只能用 `etcdctl snapshot save`，恢复只能用 `etcdutl snapshot restore`，不要混用。
> 恢复 Kubernetes 数据时务必带 `--bump-revision` + `--mark-compacted`，否则 informer / watch cache 可能不刷新。

**带保留策略的备份脚本示例：**

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR=/opt/etcd-backup
RETENTION_DAYS=7
mkdir -p "$BACKUP_DIR"

export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key

FILE="$BACKUP_DIR/etcd-$(date +%F-%H%M%S).db"
etcdctl snapshot save "$FILE"
etcdutl snapshot status "$FILE" -w table

# 清理过期备份
find "$BACKUP_DIR" -name 'etcd-*.db' -mtime +"$RETENTION_DAYS" -delete
```

### 5.7 kubeadm 环境下的快捷用法

```bash
# 1) 找到 etcd static pod（mirror pod）
kubectl -n kube-system get pod -l component=etcd -o wide

# 2) 直接进 etcd 容器执行（etcd 镜像自带 etcdctl；证书由 hostPath 挂载）
#    注意：镜像可能没有 shell，不要用 sh -c，直接传参数
kubectl -n kube-system exec -it etcd-<节点名> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# 3) 从 apiserver 侧确认 etcd 健康（最贴近真实链路）
kubectl get --raw='/healthz/etcd'
kubectl get --raw='/readyz?verbose' | grep -i etcd

# 4) 用 crictl 定位容器（kubectl 不可用时）
crictl ps | grep etcd
crictl exec -it <container-id> etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

### 5.8 常用排查组合

```bash
# 对象数量 Top（看哪类资源把 db 撑大）
etcdctl get /registry --prefix --keys-only \
  | awk -F/ '{print "/"$2"/"$3}' | sort | uniq -c | sort -rn | head -20

# Event 数量（事件洪水是 db 暴涨常见原因）
etcdctl get /registry/events --prefix --keys-only | wc -l

# 当前 db 大小 + 告警 + leader 一览
etcdctl endpoint status --cluster -w table
etcdctl alarm list

# 性能 / 数据规模评估（部分版本为实验特性，勿在生产高峰期跑）
etcdctl check perf
etcdctl check datascale --prefix=/registry

# 成员间数据是否一致（hashkv）
etcdctl endpoint hashkv --cluster -w table
```

### 5.9 危险命令清单（生产禁用 / 慎用）

| 命令 | 后果 |
|---|---|
| `etcdctl del /registry --prefix` | 删除所有 K8s 对象，集群"看起来被清空" |
| `rm -rf /var/lib/etcd/*` | 删除该成员全部数据；多数成员执行则集群不可恢复 |
| 运行中 `cp -a /var/lib/etcd` | 备份可能不一致，恢复失败 |
| `etcdctl member remove <leader>` | 触发重新选举，短时间不可写 |
| 同时 defrag 多个成员 | 可能丢失 quorum，集群不可用 |
| `--force-new-cluster` | 丢弃其他成员，仅限灾难恢复最后手段 |
| 同一快照在新旧集群同时启动 | cluster ID 冲突、脑裂、数据损坏 |

### 5.10 版本差异速记

| 版本 | 变化 |
|---|---|
| 3.4+ | 默认 API v3，`ETCDCTL_API=3` 可省略；支持 learner |
| 3.5 | `etcdctl snapshot save/restore` 仍可用；`etcdutl` 提供 `snapshot status` / `restore` |
| 3.6+ | **保存只能用 `etcdctl snapshot save`，恢复只能用 `etcdutl snapshot restore`**；恢复 K8s 数据加 `--bump-revision` + `--mark-compacted` |
| 通用 | `etcdctl` 管在线，`etcdutl` 管离线；恢复用**同版本或更高版本**工具，不要降级 |

---

## 六、本集群故障场景实战（3 节点 etcd）

> 本章基于当前这套集群的实测数据，不是通用示例。命令默认在 **m01** 上执行；访问远程 etcd 时把 `--endpoints` 换成存活节点。

### 6.1 本集群基线（2026-11-05 实测）

| 项目 | 实测值 |
|---|---|
| Kubernetes | v1.35.9 |
| etcd | 3.6.6（镜像 `registry.k8s.io/etcd:3.6.6-0`） |
| 控制平面 | m01 `10.0.0.61`、master01 `10.0.0.121`、master02 `10.0.0.120` |
| etcd 成员 ID | m01 `33b9f76d476bb4e1`、master01 `60d3248b467e33c9`、master02 `5c24992f12ba0ec2` |
| Leader / Cluster ID | master02 / `2141133850346081760`（`0x1db6d5e486714de0`） |
| 数据目录 | 三节点均 `/var/lib/etcd`；db ≈ 118–119 MB，WAL ≈ 367 MB |
| 配额 | 默认 2 GiB（`etcd_server_quota_backend_bytes=2147483648`），当前 db 用量 119 MB |
| apiserver 连接 | `--etcd-servers=https://127.0.0.1:2379`，**每台只连本机 etcd** |
| 磁盘 | m01 根分区 47 GB，已用 51%，剩 24 GB；`/var/lib/etcd`、`/var/log`、`/var/lib/containerd` 在同一个 XFS 根分区 |
| 控制平面证书 | 2027-10-03 到期（约剩 331 天），CA 2036 年到期 |
| kubelet | client 证书自动轮换（当前 2027-10-02）；serving 为自签名 `kubelet.crt`，2027-01-16 到期；`serverTLSBootstrap` 未开启 |
| 工具版本 | 宿主机 `etcdctl 3.5.12`、**没有 etcdutl**；容器内 `etcdctl/etcdutl 3.6.6` |
| 当前健康 | 3/3 healthy，无 alarm，leader 变更 1 次，proposals failed 0，fsync p99 < 16 ms，健康检查 13–16 ms |
| 历史信号 | m01 的 kube-apiserver 重启 9 次；上一次退出日志是 `127.0.0.1:2379 connect: connection refused` |

**两个本集群特有的关键点：**

1. 每台 apiserver 只连 `127.0.0.1:2379`，本机 etcd 一挂，本机 apiserver 就不可用；但另外两台 apiserver 仍可服务。
2. 三个 etcd 静态 Pod 的 `--initial-cluster` **都只写了自己**，且没有 `--initial-cluster-state`。平时有数据目录时无所谓，但**数据目录一旦丢失，etcd 会按 `new` 启动成一个全新的单节点集群**，而不是重新加入原集群。这是下面场景一最大的坑。

---

### 6.2 场景一：m01 的 `/var/lib/etcd` 被误删，怎么恢复？

#### 第一步：判断是"单成员丢数据"还是"quorum 已丢"

```bash
# 在 m01 上看 etcd 是否还在跑、是否还持有已删除的文件
crictl ps | grep etcd
lsof +L1 2>/dev/null | grep -E 'etcd|/var/lib/etcd' || true

# 从另外两台看集群是否还有多数派
export E="--endpoints=https://10.0.0.120:2379,https://10.0.0.121:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

etcdctl $E endpoint health --cluster
etcdctl $E member list -w table
```

- **2/3 健康**：只是 m01 一个成员坏了，走下面的 **member replace**（推荐，不丢数据、不换 cluster ID）。
- **只剩 0–1 个健康**：quorum 已丢，只能做 **全量快照恢复**（见 6.3），三台都恢复。

> 如果 m01 的 etcd 进程还活着但文件已被 `rm`，它只是靠已打开的文件描述符在撑；**不要直接重启**，否则会按当前 manifest 起一个新单节点集群。按下面的步骤先移走 manifest。

#### 第二步：正确恢复（member replace）

```bash
# 1) 停掉 m01 的 etcd 静态 Pod（只动 etcd，不动 apiserver/controller/scheduler）
mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
sleep 5
ss -lntp | grep -E '2379|2380' || echo "m01 etcd 已停止"

# 2) 在 m01 上通过 master01/02 确认 2/3 quorum（$E 同上）
etcdctl $E endpoint health --cluster
etcdctl $E member list -w table

# 3) 移除坏成员（本集群 m01 的 ID）
etcdctl $E member remove 33b9f76d476bb4e1
# 此时只剩 2 个投票成员，quorum=2，两台都必须保持健康，动作要快

# 4) 以 learner 重新加入（同 name、同 peer URL，会生成新的 member ID）
etcdctl $E member add m01 --peer-urls=https://10.0.0.61:2380 --learner
# 记下输出的新 member ID 和 --initial-cluster 字符串

# 5) 清空 m01 的旧数据目录（确认已无可用数据）
mv /var/lib/etcd /var/lib/etcd.broken.$(date +%s)
install -d -m 700 /var/lib/etcd

# 6) 修改 /root/etcd.yaml.bak，再原子放回
#    --initial-cluster 改成 member add 输出的完整三个成员
#    新增 --initial-cluster-state=existing
#    保持 --data-dir=/var/lib/etcd、证书、listen/advertise URL 不变
vi /root/etcd.yaml.bak
grep -E 'initial-cluster|initial-cluster-state|initial-cluster-token|data-dir' /root/etcd.yaml.bak
mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml

# 7) 观察追平
kubectl -n kube-system logs -f etcd-m01
# 另一个窗口：
etcdctl $E member list -w table
etcdctl $E endpoint status --cluster -w table
# 看 m01 的 RAFT APPLIED INDEX 是否接近 leader

# 8) 追平后 promote 为投票成员
etcdctl $E member promote <new-member-id>
etcdctl $E endpoint health --cluster
etcdctl $E alarm list

# 9) 本机 apiserver 会自动重连 127.0.0.1:2379；确认
kubectl get --raw /healthz/etcd
kubectl -n kube-system get pod etcd-m01 kube-apiserver-m01

# 10) 立刻补一份新快照
kubectl -n kube-system exec etcd-m01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/after-recover.db
mv /var/lib/etcd/after-recover.db /opt/
```

**关键说明：**

- `--initial-cluster-state=existing` 必须加。否则空数据目录 + `new` 会新建一个单节点集群。
- `--initial-cluster` 要写**完整的三成员列表**；只写 m01 自己也会变成单节点集群。
- `--initial-cluster-token` 必须与现有集群一致。本集群 manifest 没写，默认是 `etcd-cluster`；如果你们改过，以其他节点为准。
- 本集群其他两台的 manifest 也只有自己，这是**潜在隐患**：任何一台数据目录丢失后自动重启，都会起单节点集群。建议后续把三份 manifest 的 `--initial-cluster` 都改成完整列表（有数据时该参数被忽略，改完滚动重启即可）。

#### 更稳的变体：先加第 4 个临时成员

如果有一台空闲节点，可以：

1. 新节点以 learner 加入（4 成员，quorum 仍为 3，容错反而更好）；
2. 追平后 promote；
3. `member remove` 掉 m01；
4. 再按上面的方式把 m01 加回来。

这样全程不会出现"只剩 2 个投票成员"的脆弱窗口，但需要额外一台机器。

#### 绝对不要做的事

- **不要对单个成员执行 `etcdutl snapshot restore`**：restore 会生成新的 cluster ID，见 6.3。
- **不要把健康成员的 `/var/lib/etcd` 直接 `cp -a` 到 m01**：会复制 member ID，导致身份冲突。
- **不要在 etcd 运行时 `rm -rf /var/lib/etcd/*` 后直接重启**：会触发上面的单节点新集群陷阱。

---

### 6.3 场景二：快照恢复后 cluster ID 变了，会怎样？为什么其他节点连不上？

#### 为什么会变

`etcdutl snapshot restore` 不是"把旧 db 原样放回目录"，它在 3.6 里的关键动作是：

1. 复制快照中的 db；
2. `TrimMembershipFromBackend()`：**清掉快照里的旧成员关系**；
3. 用 `--initial-cluster` 和 `--initial-cluster-token` 调 `NewClusterFromURLsMap()`；
4. `genID()` 用成员 ID 的 SHA1 生成**新的 cluster ID**。

成员 ID 的算法是：

```
memberID = SHA1(排序后的 peerURL 字符串拼接 + token) 的前 8 字节
clusterID = SHA1(排序后的 memberID 拼接) 的前 8 字节
```

所以：

- 新 cluster ID **不是随机的**，由 `--initial-cluster`（各成员 peer URL）和 `--initial-cluster-token` 决定；
- 三台机器用**完全相同**的 `--initial-cluster` 和 token 恢复，会得到**相同的新 cluster ID**，可以组成新集群；
- 任何一台的参数不同（少写成员、IP 不同、token 不同），它的 cluster ID 就和其他两台不同，**组不起来**；
- 新 cluster ID 通常**不等于旧 cluster ID**，因为旧集群的成员可能是后续 `member add` 进来的（member ID 带时间戳），和 restore 时按 URL+token 重算的结果不同。

按本集群当前三个 peer URL + 默认 token `etcd-cluster` 推算，restore 出来的 cluster ID 约为 `13231401151294225617`（`0xb79f613e7f963cd1`），而当前是 `2141133850346081760`（`0x1db6d5e486714de0`）。**两者不同**，这就是"恢复后 ID 变了"的具体来源（实际值以 restore 后 `endpoint status` 为准）。

#### 变了会怎样

- 旧的 master01/master02 仍持有**旧 cluster ID**。它们和恢复出来的 m01 建立 peer 连接时，会在 Raft 消息里校验 cluster ID，发现不一致后拒绝：
  - 典型日志：`cluster ID mismatch`、`unmatched cluster ID`、`failed to find member ... in cluster ...`；
  - 表现为 m01 一直连不上、成员无法同步，甚至 etcd 反复重启。
- 如果只恢复了 m01，并让 m01 的 apiserver 连它（本集群正是 `127.0.0.1:2379`），那么：
  - m01 的 apiserver 看到的是**新集群**（如果按单成员恢复，就是一个只有 m01 的空集群）；
  - master01/master02 的 apiserver 看到的仍是**旧集群**；
  - 通过 LB 访问时，请求落到不同 apiserver 会看到不同状态，出现"有时有资源、有时没有"的 API 层脑裂。
- 如果 apiserver 的 `--etcd-servers` 同时列了新旧成员，etcd 客户端会在多个 endpoint 间负载，读写落到两套集群，**比连不上更危险**。

#### 正确做法：全量恢复，三台参数完全一致

```bash
# 1) 三台都停 etcd（移走各节点 manifests 里的 etcd.yaml）
# 2) 用 3.6.6 的 etcdutl（宿主机没装，可从 etcd 镜像取，或安装同版本）
etcdutl snapshot restore /path/final.db \
  --name m01 \
  --initial-cluster m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380 \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls https://10.0.0.61:2380 \
  --bump-revision 1000000000 \
  --mark-compacted \
  --data-dir /var/lib/etcd-new
```

另外两台只改 `--name`、`--initial-advertise-peer-urls`、`--data-dir`，**`--initial-cluster` 和 token 必须逐字一致**。

恢复后：

- 三台用新数据目录启动，形成新 cluster ID 的集群；
- 更新每台 apiserver 的 `--etcd-servers`（本集群是 `127.0.0.1`，IP 不变则不用改）；
- 绝对不要把新旧成员混在一个 `--etcd-servers` 列表里；
- PKI 不变，kubelet 证书继续有效；但 revision 被 bump，所有 watch 会重新 list；
- `--bump-revision` + `--mark-compacted` 是 K8s 场景的必选项，避免 informer 缓存不刷新。

#### 想保留原 cluster ID 怎么办

只能用 **member replace**（6.2），不能用 snapshot restore。restore 的设计目标就是"创建一个新的逻辑集群"，不是"原地复活一个成员"。

---

### 6.4 场景三：apiserver 报 `etcdserver: request timed out`，从哪几个方向查？

#### 先理解这个错误

`etcdserver: request timed out` 是 **etcd 服务端**返回的 `ErrTimeout`：请求在 etcd 内部等待提案提交 / apply / 线性一致读时超时。它不等于 apiserver 的 HTTP 超时，也不等于网络不通。

本集群的第一分叉点是：

```bash
# 本集群每台 apiserver 都只连本机 etcd
grep etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml
# --etcd-servers=https://127.0.0.1:2379
```

- **只有一台 apiserver 报错** → 先查那台的本地 etcd（进程、磁盘、leader、日志）。
- **三台都报错** → 查共同因素：leader、网络、磁盘、配额、全局负载。

本集群已有先例：m01 的 apiserver 上一次退出，日志就是大量 `dial tcp 127.0.0.1:2379: connect: connection refused`。本地 etcd 一挂，本机 apiserver 必然不可用。

#### 排查方向一：quorum / leader

```bash
etcdctl $E endpoint health --cluster
etcdctl $E endpoint status --cluster -w table
etcdctl $E member list -w table
etcdctl $E alarm list
```

重点看：

- 是否有成员 `unhealthy` / `ERRORS` 非空；
- `IS LEADER` 是否频繁变化（本集群启动以来 leader 变更仅 1 次，基线很稳）；
- `RAFT APPLIED INDEX` 是否持续落后；
- 是否有 `NOSPACE` alarm。

#### 排查方向二：磁盘 / fsync

```bash
# etcd 自身指标
curl -s --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  https://127.0.0.1:2379/metrics | grep -E \
  'etcd_disk_wal_fsync_duration_seconds|etcd_disk_backend_commit_duration_seconds|etcd_server_slow_apply_total'

# 主机侧
iostat -x 1 5
vmstat 1 5
dmesg -T | tail -50
df -h /var/lib/etcd
```

本集群当前基线：fsync 99% 以上在 16 ms 内，backend commit 也在毫秒级，`slow_apply_total=4`，`proposals_failed_total=0`。如果排障时这些值明显变差（fsync p99 > 100 ms、slow apply 快速增长），基本就是磁盘或 IO 问题。

#### 排查方向三：配额 / compaction / defrag

```bash
etcdctl $E endpoint status -w table      # DB SIZE
etcdctl $E alarm list
curl -s ... https://127.0.0.1:2379/metrics | grep -E \
  'etcd_mvcc_db_total_size_in_bytes|etcd_server_quota_backend_bytes|etcd_mvcc_db_total_size_in_use_in_bytes'
```

本集群：db 119 MB / quota 2 GiB，in-use 约 30 MB，空间充足；但如果长期不 compact/defrag，db 会持续膨胀，接近 quota 时写入变慢甚至只读。

#### 排查方向四：网络 / 时钟

```bash
ping -c 20 10.0.0.120
ping -c 20 10.0.0.121
mtr -rwc 20 10.0.0.120
chronyc tracking
ss -s
```

etcd 对 RTT 和时钟敏感。跨机房、NAT、MTU 不一致、丢包都会导致心跳/选举异常。本集群三台在 `10.0.0.0/24`，正常情况下 RTT 应 < 1 ms。

#### 排查方向五：请求负载

```bash
# apiserver 侧 etcd 请求耗时
kubectl get --raw /metrics | grep -E 'etcd_request_duration_seconds_(sum|count)'

# Event 数量（事件洪水是常见元凶）
kubectl -n kube-system exec etcd-m01 -- etcdctl ... get /registry/events --prefix --keys-only | wc -l

# 大型 LIST / 大对象
kubectl get --raw /metrics | grep apiserver_request_duration_seconds
```

本集群 events create 平均约 4 ms（sum 2.44 s / 601 次），属于正常。若某个资源 LIST 特别慢，或 Event 数量暴涨，会拖慢 etcd。

#### 排查方向六：apiserver 自身

```bash
kubectl -n kube-system logs kube-apiserver-m01 --tail=300 | grep -iE \
  'etcdserver|timed out|connection refused|slow'
kubectl -n kube-system logs kube-apiserver-m01 --previous --tail=300
kubectl -n kube-system get pod kube-apiserver-m01 -o wide
```

看 apiserver 是否 CPU/内存打满、是否在反复重启（m01 已重启 9 次）、是否只有本机 etcd 连不上。

#### 处理方向对照

| 根因 | 处理 |
|---|---|
| 磁盘慢 / IO 饱和 | 换本地 SSD、降低同盘负载、迁移 containerd/日志到独立盘 |
| db 膨胀 / 接近 quota | `compact` + 逐台 `defrag` + `alarm disarm` |
| 成员掉线 / quorum 危险 | 先恢复成员（6.2），不要继续压测 |
| 网络丢包 / 时钟漂移 | 修网络、校准 NTP/chrony |
| 事件 / 大 LIST 压力 | 降低 Event 产生、缩短 Event TTL、拆分大对象 |
| 本机 etcd 挂了 | 先看本机 etcd，必要时临时把 apiserver 指向其他 etcd（需改 manifest 并重启） |
| 单纯调大超时 | 只能缓解，不能根治，最后一项才考虑 |

---

### 6.5 场景四：证书过期时，kubelet 和 apiserver 分别在哪一步失败？

#### 核心原则

证书校验发生在 **TLS 握手阶段**，在 HTTP 认证/授权之前。所以证书过期时看到的是 `x509: certificate has expired or is not yet valid`，而不是 401/403。

#### 失败点对照表

| 证书 | 使用方向 | 过期后在哪一步失败 | 现象 | 修复 |
|---|---|---|---|---|
| kubelet client 证书（`system:node:m01`） | kubelet → apiserver | kubelet 发起 mTLS 握手时 | Node `NotReady`，kubelet 日志 x509 过期；Pod 继续跑但无法上报状态 | 删除旧证书，确保 bootstrap token 有效，重启 kubelet，`kubectl certificate approve` 新 CSR |
| kubelet serving 证书（本集群为自签名 `kubelet.crt`） | apiserver / metrics-server → kubelet | 对端校验 serving 证书时 | 取决于客户端是否校验：`kubectl logs/exec` 可能正常；metrics-server/Prometheus 可能失败 | 开启 `serverTLSBootstrap` + 轮换，批准 CSR；或更换证书 |
| apiserver serving 证书（`apiserver.crt`） | 所有客户端 → apiserver | 客户端与 apiserver 的 TLS 握手 | kubectl、kubelet、controller-manager、scheduler 全部连不上，x509 过期 | `kubeadm certs renew` 后重启 apiserver 静态 Pod |
| apiserver-etcd-client 证书 | apiserver → etcd | apiserver 作为 etcd 客户端握手 | apiserver 启动/请求失败，`/readyz/etcd` 失败，API 不可用 | renew 后重启 apiserver |
| apiserver-kubelet-client 证书 | apiserver → kubelet | apiserver 访问 kubelet 时握手 | `kubectl logs/exec/port-forward` 失败，核心 API 仍可用 | renew 后重启 apiserver |
| front-proxy-client 证书 | apiserver → 聚合 API | 聚合层 TLS 握手 | `metrics.k8s.io` 等聚合 API 失败 | renew 后重启 apiserver |
| controller-manager / scheduler 的 kubeconfig 客户端证书 | 组件 → apiserver | 组件与 apiserver 握手 | 控制器/调度器 leader 选举失败、不工作 | `kubeadm certs renew` 后重启对应静态 Pod |

#### 本集群的实际日期

- 控制平面证书（apiserver、apiserver-etcd-client、apiserver-kubelet-client、front-proxy-client、etcd server/peer/healthcheck）：**2027-10-03** 到期；
- CA / etcd-ca / front-proxy-ca：**2036 年**到期；
- kubelet client 证书：**2027-10-02** 到期，`rotateCertificates: true`，会自动轮换；
- kubelet serving 自签名证书 `kubelet.crt`：**2027-01-16** 到期，是三张里**最近**的一个。

#### 为什么本集群的 kubelet serving 过期不一定立刻断 logs/exec

本集群 apiserver 没有配置 `--kubelet-certificate-authority`：

```bash
grep kubelet-certificate-authority /etc/kubernetes/manifests/kube-apiserver.yaml
# 无输出
```

这意味着 apiserver → kubelet 的客户端默认不校验证书（`InsecureSkipVerify`），所以即使 `kubelet.crt` 过期，`kubectl logs/exec` 通常仍能用；但 **metrics-server、Prometheus 等自行校验的客户端会失败**。另外 `kubelet.crt` 只有 `DNS:m01`，没有 IP SAN，apiserver 又优先用 `InternalIP` 连接，所以它本来就不适合做严格校验。

生产建议开启：

```yaml
# /var/lib/kubelet/config.yaml
serverTLSBootstrap: true
```

并给 kubelet 加 `--rotate-server-certificates=true`，重启后批准 kubelet 的 serving CSR。这样 serving 证书由集群 CA 签发并自动轮换。

#### 证书续期命令

```bash
# 查看所有证书到期时间
kubeadm certs check-expiration

# 续期控制平面证书（不包含 kubelet 证书）
kubeadm certs renew all

# 逐个重启静态 Pod 让新证书生效（不要三台同时重启）
# 方式一：crictl 找到容器后 stopp/rm，kubelet 会自动重建
crictl ps | grep -E 'kube-apiserver|kube-controller-manager|kube-scheduler|etcd'
# 方式二：临时移走 manifest 再放回
```

kubelet client 证书过期且自动轮换失败时：

```bash
# 确认 bootstrap token 仍有效；过期则新建
kubeadm token create --ttl 1h

# 删除过期证书，重启 kubelet 触发新 CSR
mv /var/lib/kubelet/pki/kubelet-client-current.pem /root/
systemctl restart kubelet

# 批准新 CSR
kubectl get csr
kubectl certificate approve <csr-name>
```

---

### 6.6 场景五：Master 磁盘满了会发生什么？为什么 etcd 会先崩？

#### 本集群的磁盘现状

```bash
df -h /var/lib/etcd /var/log /var/lib/containerd
# 全部是 /dev/mapper/rl-root，47G，已用 51%，剩 24G

du -sh /var/lib/etcd /var/lib/containerd /var/log
# /var/lib/etcd        480M（WAL 367M + db 114M）
# /var/lib/containerd  3.6G
# /var/log             270M
```

也就是说：**etcd 并不是占空间最多的，containerd 镜像和日志才是大头**；但它们和 etcd 在**同一个根分区**，所以镜像/日志/事件洪水把盘写满时，etcd 会跟着遭殃。

#### 磁盘满后的连锁反应

| 阶段 | 发生什么 |
|---|---|
| 1. 磁盘使用率升高 | kubelet 触发 `DiskPressure`，开始镜像 GC、驱逐 Pod；containerd 写镜像层变慢/失败 |
| 2. etcd 写 WAL 失败 | `write /var/lib/etcd/member/wal/...: no space left on device`，etcd 可能 panic 退出，static Pod 进入 CrashLoop |
| 3. 本机 apiserver 失败 | 本集群 apiserver 只连 `127.0.0.1:2379`，本机 etcd 一挂，本机 apiserver 立即不可用；另外两台暂时正常 |
| 4. 多数派危险 | 如果 2 台 master 都满，etcd 失去 quorum，整个集群 API 不可写 |
| 5. 控制器/调度器失效 | controller-manager、scheduler 的 Lease 续约失败，停止工作 |
| 6. kubelet 受影响 | 无法写日志、无法更新 Node 状态，Node 变 `NotReady`；已运行的 Pod 通常还能撑一段 |
| 7. 容器运行时受影响 | containerd 无法创建新容器/写层，Pod 重启失败 |

#### 为什么 etcd 会"先崩"

- etcd 的每次写事务都要 **append WAL + fsync**，磁盘满时 `write/fsync` 直接返回 `ENOSPC`，etcd 会 panic 退出；
- bbolt 数据库需要继续增长，快照还会在 `member/snap` 下生成临时文件，进一步吃空间；
- kube-apiserver 是**无状态**的，本身不写大文件（除非开了 audit log），所以它能撑得比 etcd 久；
- kubelet/containerd 对短时间写失败有一定容忍，已运行的容器不会立刻死；
- 所以 etcd 是"对写盘最敏感"的组件，最先以崩溃/不可用表现出来，随后才轮到 apiserver 报错、控制器失效、Node NotReady。

另外要区分两种"满"：

- **quota 满**（默认 2 GiB）：etcd 返回 `mvcc: database space exceeded`，集群进入只读，但进程还在；
- **物理磁盘满**：WAL/db 写不进去，etcd 直接 panic/退出，更严重。

本集群 quota 是 2 GiB，磁盘剩 24 GB，短期不会碰到 quota；但同盘还有 3.6 GB 容器镜像和持续增长的日志，物理磁盘满的风险更现实。

#### 应急处理

```bash
# 1) 看空间和"已删除但仍被占用"的文件
df -h
du -x -h --max-depth=1 / 2>/dev/null | sort -h | tail -20
lsof +L1 2>/dev/null | head -50

# 2) 安全释放空间（按优先级）
crictl rmi --prune                 # 清理未使用镜像
journalctl --vacuum-size=200M      # 清理 systemd journal
find /var/log/pods -type f -size +100M -print   # 先确认再删
# 删除 /opt 下旧 etcd 快照（保留最近几份）
# 不要删 /var/lib/etcd/member/snap/db

# 3) 如果 etcd 已在 CrashLoop：先停掉重启循环，避免反复写坏数据
mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
# 释放空间后，再检查并启动
mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml

# 4) 启动后检查 alarm / quota
etcdctl $E alarm list
etcdctl $E endpoint status --cluster -w table
# 若 NOSPACE：
etcdctl $E compact <revision>
etcdctl $E defrag --endpoints=https://10.0.0.61:2379   # 逐台
etcdctl $E alarm disarm

# 5) 数据目录损坏时，才走快照恢复（6.3）
```

#### 预防措施

1. **给 `/var/lib/etcd` 独立磁盘/分区**，不要和 containerd、日志共用根分区。
2. etcd quota 设为磁盘容量的合理比例（例如 2 GiB quota + 至少 10 GiB 空闲），并监控 `etcd_mvcc_db_total_size_in_bytes`。
3. containerd/kubelet 日志轮转，设置 `imageGCHighThresholdPercent`/`LowThresholdPercent`（本集群是 70/60）。
4. 定期 `compact` + 逐台 `defrag`，快照移到别的机器/对象存储。
5. 监控 `node_filesystem_avail_bytes`、`DiskPressure`、etcd `NOSPACE` alarm。
6. 控制 Event 产生量，避免事件洪水把 db 撑大。
7. 如果开了 audit log，不要写在本机根分区。

---

### 6.7 五个场景速查

| 场景 | 第一时间做什么 | 关键判断 |
|---|---|---|
| 单成员数据目录被删 | 移走该节点 etcd manifest，确认 2/3 quorum，再 member remove/add | **不要直接重启**，否则本集群 manifest 会起单节点新集群 |
| 快照恢复后 cluster ID 变了 | 停掉所有旧成员，三台用同一 `--initial-cluster` + token 全量恢复 | 旧节点会报 `cluster ID mismatch`；不能新旧混用 |
| apiserver 报 request timed out | 先分是单台还是三台；单台查本机 etcd，三台查 leader/磁盘/网络/配额 | 本集群 apiserver 只连 `127.0.0.1` |
| 证书过期 | `kubeadm certs check-expiration`，先看最近到期的那张 | TLS 握手阶段失败，表现为 x509，不是 401/403 |
| Master 磁盘满 | 立刻释放空间，停 etcd 重启循环，检查 alarm/数据完整性 | etcd 对 fsync 最敏感，通常最先崩 |

---

## 七、参考资料

- Kubernetes 官方文档：*Operating etcd clusters for Kubernetes*  
  https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes 官方文档：*kubeadm upgrade / etcd 恢复*  
  https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#restoring-an-etcd-cluster
- etcd 官方文档：*Maintenance*（compact / defrag / snapshot）  
  https://etcd.io/docs/latest/op-guide/maintenance/
- etcd 官方文档：*Disaster recovery*（snapshot restore / force-new-cluster）  
  https://etcd.io/docs/latest/op-guide/recovery/
- etcd 官方文档：*Configuration*（`--data-dir` 等参数与优先级）  
  https://etcd.io/docs/latest/op-guide/configuration/
