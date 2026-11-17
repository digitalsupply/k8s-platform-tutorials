# 3 节点 etcd 集群单成员数据目录误删恢复实战

> **日期**：2026-11-17
> **场景**：3 节点 etcd 集群（m01、master01、master02），master02 的 `/var/lib/etcd/member` 数据目录被误删，etcd 无法启动。利用快照 + `member remove/add` + 从 leader 同步的方式安全恢复。
> **集群**：Kubernetes v1.35.9，6 节点（3 control-plane + 3 worker），etcd 3.6.6，kubeadm 部署
> **原则**：全程不破坏集群可用性，3 节点即使短暂降为 2 节点仍保持 quorum

---

## 一、环境信息

### etcd 集群拓扑

| 成员 | 节点 | Pod IP | Peer URL | Client URL | Member ID (hex) |
|---|---|---|---|---|---|
| m01 | m01 | 10.0.0.61 | https://10.0.0.61:2380 | https://10.0.0.61:2379 | 33b9f76d476bb4e1 |
| master01 | master01 | 10.0.0.121 | https://10.0.0.121:2380 | https://10.0.0.121:2379 | 60d3248b467e33c9 |
| master02 | master02 | 10.0.0.120 | https://10.0.0.120:2380 | https://10.0.0.120:2379 | 5c24992f12ba0ec2（原） |

- **集群 ID**：`1db6d5e486714de0`
- etcd 为 kubeadm 静态 Pod，数据目录宿主机路径 `/var/lib/etcd`，证书路径 `/etc/kubernetes/pki/etcd`
- etcd 启用 TLS：client 和 peer 均需证书认证
- 静态 Pod 清单路径：`/etc/kubernetes/manifests/etcd.yaml`

### SSH 访问

| 节点 | 地址 | 用户名 | 密码 |
|---|---|---|---|
| m01 | 10.0.0.61 | root | rootroot. |
| master01 | 10.0.0.121 | root | rootroot. |
| master02 | 10.0.0.120 | root | rootroot. |

> 密码含末尾点号 `rootroot.`

---

## 二、恢复前检查

### 2.1 确认集群健康状态

从健康成员 master01 检查集群状态（**必须带 TLS 证书**，否则连不上）：

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379,https://10.0.0.120:2379,https://10.0.0.61:2379 \
  member list -w table
```

**输出**：

```
+------------------+---------+----------+-------------------------+-------------------------+------------+
|        ID        | STATUS  |   NAME   |       PEER ADDRS        |      CLIENT ADDRS       | IS LEARNER |
+------------------+---------+----------+-------------------------+-------------------------+------------+
| 33b9f76d476bb4e1 | started |      m01 |  https://10.0.0.61:2380 |  https://10.0.0.61:2379 |      false |
| 5c24992f12ba0ec2 | started | master02 | https://10.0.0.120:2380 | https://10.0.0.120:2379 |      false |
| 60d3248b467e33c9 | started | master01 | https://10.0.0.121:2380 | https://10.0.0.121:2379 |      false |
+------------------+---------+----------+-------------------------+-------------------------+------------+
```

**端点健康**：

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379,https://10.0.0.120:2379,https://10.0.0.61:2379 \
  endpoint health
```

**输出**：3 个端点全部 `healthy`。

### 2.2 确认 master02 静态 Pod 结构

```bash
kubectl -n kube-system get pod etcd-master02 -o jsonpath='{.spec.volumes[*]}{"\n"}'
```

**输出**：

```
etcd-certs: hostPath=/etc/kubernetes/pki/etcd
etcd-data: hostPath=/var/lib/etcd
```

数据目录在宿主机 `/var/lib/etcd`，可通过 SSH 直接操作。

### 2.3 确认 SSH 可达

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 'hostname'
# 输出: master02
```

---

## 三、恢复流程

### 步骤 1：从健康成员制作快照

**从 master01（健康成员）制作快照**，作为恢复数据源：

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  snapshot save /var/lib/etcd/snapshot-before-recovery.db
```

**输出**：

```
Snapshot saved at /var/lib/etcd/snapshot-before-recovery.db
Server version 3.6.0
```

快照大小约 131 MB，保存在 master01 宿主机 `/var/lib/etcd/snapshot-before-recovery.db`。

### 步骤 2：传输快照到 master02

**SCP 在 sshpass 环境下会静默失败**（被信号中断），改用 **SSH 管道传输**：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.121 \
  "cat /var/lib/etcd/snapshot-before-recovery.db" | \
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 \
  "cat > /tmp/snapshot-before-recovery.db && echo '传输完成'"
```

**验证**：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 \
  "ls -lh /tmp/snapshot-before-recovery.db && file /tmp/snapshot-before-recovery.db"
# -rw-r--r-- 1 root root 126M ... /tmp/snapshot-before-recovery.db
# /tmp/snapshot-before-recovery.db: data
```

### 步骤 3：下载 etcdctl 到 master02

master02 宿主机默认没有 `etcdctl`。**etcd 3.6.6 的 `etcdctl` 移除了 `snapshot restore` 子命令**（`snapshot` 下只有 `save`），需要下载 **etcd 3.5.x 的 etcdctl** 来执行恢复：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  cd /tmp
  curl -sSL -o etcd-v3.5.13-linux-amd64.tar.gz \
    https://github.com/etcd-io/etcd/releases/download/v3.5.13/etcd-v3.5.13-linux-amd64.tar.gz
  tar xzf etcd-v3.5.13-linux-amd64.tar.gz
  cp etcd-v3.5.13-linux-amd64/etcdctl /usr/local/bin/etcdctl35
  chmod +x /usr/local/bin/etcdctl35
  /usr/local/bin/etcdctl35 version
'
# etcdctl version: 3.5.13
# API version: 3.5
```

> **踩坑点 1**：etcd 3.6.6 的 `etcdctl snapshot restore` 子命令不存在。`etcdctl snapshot --help` 只列出 `save`。3.6 将 restore 功能迁移到了 `etcdutl`，但 `etcdutl` 同样不包含完整的 restore 引导参数。**跨版本恢复快照时，用 3.5.x 的 etcdctl 执行 `snapshot restore` 是可行的**，快照文件兼容。

### 步骤 4：停止 master02 的 etcd

etcd 是 kubeadm 静态 Pod，由 kubelet 管理。**必须先移走静态 Pod 清单防止 kubelet 自动重启**，再杀进程：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  # 备份静态 Pod 清单
  cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak-recovery
  # 移走清单，防止 kubelet 自动拉起
  mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.disabled
  # 杀掉 etcd 进程
  pkill -9 -x etcd
  sleep 2
  pgrep -x etcd && echo "WARN: etcd 仍在运行" || echo "etcd 已彻底停止"
'
```

> **踩坑点 2**：SIGTERM 可能无法优雅停止 etcd（进程仍在），需要 `pkill -9` 强制杀。

### 步骤 5：模拟数据目录误删

> **安全操作**：先备份原始数据目录，再删除，保留兜底。

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  # 备份原始数据目录（兜底）
  cp -a /var/lib/etcd /var/lib/etcd.bak-recovery
  # 删除数据目录（模拟误删事故）
  rm -rf /var/lib/etcd/member
  ls -la /var/lib/etcd/
'
```

**输出**：`/var/lib/etcd/` 下 `member` 目录已删除，只剩空目录。

### 步骤 6：从集群中移除 master02 成员

**从健康成员 master01 执行**。移除后集群降为 2 节点，仍保持 quorum，集群继续可用：

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  member remove 5c24992f12ba0ec2
```

**输出**：

```
Member 5c24992f12ba0ec2 removed from cluster 1db6d5e486714de0
```

> **踩坑点 3**：`member remove` 的 ID 参数**必须用十六进制格式**（如 `5c24992f12ba0ec2`），不能用十进制。传十进制会报 `strconv.ParseUint: value out of range`。从 `member list -w table` 的 ID 列直接复制即可。

**移除后确认**：集群剩 2 个成员（m01、master01），均 `started` 且 `healthy`。

### 步骤 7：在 master02 上恢复快照

> **踩坑点 4**：`snapshot restore` 必须指定 `--data-dir=/var/lib/etcd`，否则数据会写入当前工作目录下的 `master02.etcd/` 子目录，导致后续 etcd 启动找不到数据。

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  nohup etcdctl35 snapshot restore /tmp/snapshot-before-recovery.db \
    --name=master02 \
    --initial-cluster=m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380 \
    --initial-advertise-peer-urls=https://10.0.0.120:2380 \
    --data-dir=/var/lib/etcd \
    > /tmp/etcd-restore.log 2>&1 &
  sleep 6
  cat /tmp/etcd-restore.log
'
```

**关键输出**：

```
restoring snapshot  {"path": "/tmp/snapshot-before-recovery.db", "wal-dir": "/var/lib/etcd/member/wal", "data-dir": "/var/lib/etcd", "snap-dir": "/var/lib/etcd/member/snap"}
Trimming membership information from the backend...
added member  {"cluster-id": "b79f613e7f963cd1", ...}
restored snapshot  {"path": "/tmp/snapshot-before-recovery.db", ...}
```

> **踩坑点 5**：`snapshot restore` 会创建一个**新的集群 ID**（`b79f613e7f963cd1`），与原集群 ID（`1db6d5e486714de0`）不同。这意味着恢复后的数据目录里的集群 ID 与原集群不匹配，**不能直接用 `--initial-cluster-state=existing` 启动**——etcd 会卡住，端口在监听但健康检查超时。

> **踩坑点 6**：`etcdctl35 snapshot restore` **不支持 `--initial-cluster-state` 参数**（3.5.13 中该 flag 不存在），会报 `unknown flag: --initial-cluster-state`。

### 步骤 8：将 master02 重新加入集群

从健康成员 master01 执行 `member add`，获取新成员 ID 和正确的启动参数：

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  member add master02 --peer-urls=https://10.0.0.120:2380
```

**输出**：

```
Member 8306a0d461e197d2 added to cluster 1db6d5e486714de0

ETCD_NAME="master02"
ETCD_INITIAL_CLUSTER="m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://10.0.0.120:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
```

新成员 ID：`8306a0d461e197d2`，集群 ID：`1db6d5e486714de0`（与原集群一致）。

### 步骤 9：关键决策——放弃 snapshot restore 的数据，从 leader 同步

由于 `snapshot restore` 创建了不匹配的集群 ID，直接用恢复的数据目录启动 etcd 会卡死。**正确做法是：丢弃 snapshot restore 产生的数据目录，清空后用 `--initial-cluster-state=existing` 启动 etcd，让它从 leader 自动同步全量数据。**

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.120 'true' 2>/dev/null
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  # 杀掉 snapshot restore 启动的 etcd（如果还在跑）
  pkill -9 -x etcd
  sleep 2
  # 删除 snapshot restore 产生的错误数据目录
  rm -rf /var/lib/etcd/member
  # 移走静态 Pod 清单（防止 kubelet 用旧 flags 干扰）
  mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.disabled
  # 用 etcd 3.6.6 二进制 + --initial-cluster-state=existing 启动
  # 空数据目录 + existing = 从 leader 全量同步
  nohup /tmp/etcd-v3.6.6-linux-amd64/etcd \
    --name=master02 \
    --initial-cluster=m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380 \
    --initial-cluster-state=existing \
    --initial-advertise-peer-urls=https://10.0.0.120:2380 \
    --data-dir=/var/lib/etcd \
    --advertise-client-urls=https://10.0.0.120:2379 \
    --listen-client-urls=https://127.0.0.1:2379,https://10.0.0.120:2379 \
    --listen-peer-urls=https://10.0.0.120:2380 \
    --cert-file=/etc/kubernetes/pki/etcd/server.crt \
    --key-file=/etc/kubernetes/pki/etcd/server.key \
    --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \
    --client-cert-auth=true \
    --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt \
    --peer-key-file=/etc/kubernetes/pki/etcd/peer.key \
    --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \
    --peer-client-cert-auth=true \
    --listen-metrics-urls=http://127.0.0.1:2381,http://10.0.0.120:2381 \
    --snapshot-count=10000 \
    > /tmp/etcd-recovery.log 2>&1 &
  echo "etcd PID: $!"
  sleep 8
  cat /tmp/etcd-recovery.log
'
```

**关键日志输出**（证明恢复成功）：

```
starting local member  {"local-member-id":"8306a0d461e197d2","cluster-id":"1db6d5e486714de0"}
receiving database snapshot  {"remote-snapshot-sender-id":"33b9f76d476bb4e1","incoming-snapshot-index":69650469}
received and saved database snapshot  {"incoming-snapshot-size":"136 MB"}
restored snapshot  [index: 69650469, term: 118]
recovered/added member from store  {"cluster-id":"1db6d5e486714de0","local-member-id":"8306a0d461e197d2"}
ready to serve client requests
serving client traffic securely  address="10.0.0.120:2379"
```

**关键点**：
- `local-member-id` 和 `cluster-id` 与原集群**完全一致**
- 从 leader（m01）接收了 136 MB 快照并恢复
- `--initial-cluster-state=existing` + 空数据目录 = etcd 自动从 leader 全量同步

### 步骤 10：更新静态 Pod 清单并交还 kubelet

更新 `/etc/kubernetes/manifests/etcd.yaml`，将 `--initial-cluster` 改为完整 3 节点配置，并添加 `--initial-cluster-state=existing`：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  # 确认清单内容（已更新）
  grep "initial-cluster" /etc/kubernetes/manifests/etcd.yaml.disabled
  # 杀掉手动启动的 etcd
  kill $(pgrep -x etcd)
  sleep 3
  # 恢复静态 Pod 清单
  mv /etc/kubernetes/manifests/etcd.yaml.disabled /etc/kubernetes/manifests/etcd.yaml
'
```

**更新后的清单参数**：

```yaml
- --initial-cluster=m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380
- --initial-cluster-state=existing
```

> **踩坑点 7**：kubelet 可能用**缓存的 mirror pod spec**（旧 flags）启动 etcd，即使清单文件已更新。表现为 etcd 进程用的还是 `--initial-cluster=master02=https://10.0.0.120:2380`（只有自身）。**解决：杀掉 etcd → 移走清单 → 等 kubelet 清理 → 移回清单**，强制 kubelet 重新读取。

### 步骤 11：重启 kubelet 恢复 kube-apiserver

kube-apiserver 在 etcd 宕机期间进入 CrashLoopBackOff，需要重启 kubelet 清除退避状态：

```bash
sshpass -p 'rootroot.' ssh -o StrictHostKeyChecking=no root@10.0.0.120 '
  systemctl restart kubelet
  sleep 15
  pgrep -x kube-apiserver && echo "apiserver 在运行" || echo "apiserver 未运行"
  ss -tlnp | grep 6443
'
```

**输出**：

```
apiserver 在运行
LISTEN 0  4096  *:6443  *:*  users:(("kube-apiserver",pid=11318,fd=4))
```

> **安全说明**：3 节点 etcd 集群，即使 master02 短暂不可用，剩余 2 节点仍保持 quorum（>50%），集群 API 不受影响。重启 kubelet 期间 master02 上的静态 Pod 会短暂重启，但不影响整体集群。

---

## 四、恢复验证

### 4.1 K8s API 健康

```bash
kubectl get nodes
```

**输出**：

```
NAME       STATUS   ROLES           AGE    VERSION
m01        Ready    control-plane   304d   v1.35.9
master01   Ready    control-plane   304d   v1.35.9
master02   Ready    control-plane   304d   v1.35.9
worker01   Ready    <none>          304d   v1.35.9
worker02   Ready    <none>          304d   v1.35.9
worker03   Ready    <none>          304d   v1.35.9
```

### 4.2 etcd 集群成员

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379,https://10.0.0.120:2379,https://10.0.0.61:2379 \
  member list -w table
```

**输出**：

```
+------------------+---------+----------+-------------------------+-------------------------+------------+
|        ID        | STATUS  |   NAME   |       PEER ADDRS        |      CLIENT ADDRS       | IS LEARNER |
+------------------+---------+----------+-------------------------+-------------------------+------------+
| 33b9f76d476bb4e1 | started |      m01 |  https://10.0.0.61:2380 |  https://10.0.0.61:2379 |      false |
| 60d3248b467e33c9 | started | master01 | https://10.0.0.121:2380 | https://10.0.0.121:2379 |      false |
| 8306a0d461e197d2 | started | master02 | https://10.0.0.120:2380 | https://10.0.0.120:2379 |      false |
+------------------+---------+----------+-------------------------+-------------------------+------------+
```

### 4.3 etcd 端点健康

```bash
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379,https://10.0.0.120:2379,https://10.0.0.61:2379 \
  endpoint health
```

**输出**：

```
https://10.0.0.61:2379 is healthy: successfully committed proposal: took = 14.375571ms
https://10.0.0.121:2379 is healthy: successfully committed proposal: took = 14.678546ms
https://10.0.0.120:2379 is healthy: successfully committed proposal: took = 19.93497ms
```

### 4.4 etcd Pod 状态

```bash
kubectl -n kube-system get pods -l component=etcd -o wide
```

**输出**：

```
NAME            READY   STATUS    RESTARTS   AGE     IP           NODE       NOMINATED NODE   READINESS GATES
etcd-m01        1/1     Running   7 (6h38m ago)  45d   10.0.0.61    m01        <none>           <none>
etcd-master01   1/1     Running   5 (6h38m ago)  45d   10.0.0.121   master01   <none>           <none>
etcd-master02   1/1     Running   0              6m39s 10.0.0.120   master02   <none>           <none>
```

### 4.5 master02 静态 Pod 状态

```bash
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=master02
```

**输出**：

```
NAME                               READY   STATUS    RESTARTS         AGE     IP           NODE       NOMINATED NODE   READINESS GATES
cilium-xb4n8                       1/1     Running   2 (6h38m ago)    4d5h    10.0.0.120   master02   <none>           <none>
etcd-master02                      1/1     Running   0                6m40s   10.0.0.120   master02   <none>           <none>
kube-apiserver-master02            1/1     Running   17 (2m59s ago)   45d    10.0.0.120   master02   <none>           <none>
kube-controller-manager-master02   1/1     Running   7 (26m ago)      45d    10.0.0.120   master02   <none>           <none>
kube-scheduler-master02            1/1     Running   7 (26m ago)      45d    10.0.0.120   master02   <none>           <none>
kube-vip-ds-nfxvf                  1/1     Running   7 (47m ago)      43d    10.0.0.120   master02   <none>           <none>
```

**全部 1/1 Running，恢复完成。**

---

## 五、踩坑记录汇总

| # | 踩坑点 | 现象 | 原因 | 解决方法 |
|---|---|---|---|---|
| 1 | etcd 3.6.6 无 `snapshot restore` | `etcdctl snapshot --help` 只列出 `save`，无 `restore` 子命令 | 3.6 将 restore 迁移到 `etcdutl` | 下载 etcd 3.5.x 的 etcdctl 执行 `snapshot restore`，快照兼容跨版本 |
| 2 | `snapshot restore` 不支持 `--initial-cluster-state` | `Error: unknown flag: --initial-cluster-state` | 3.5.13 的 restore 子命令无此 flag | 去掉该参数，3.5 的 restore 默认即新集群模式 |
| 3 | `snapshot restore` 未指定 `--data-dir` | 数据写入 `master02.etcd/` 子目录，非 `/var/lib/etcd/` | 默认在当前工作目录创建以 `--name` 命名的目录 | 必须加 `--data-dir=/var/lib/etcd` |
| 4 | `snapshot restore` 产生不匹配的集群 ID | 恢复后 etcd 启动卡死，端口监听但健康检查超时 | restore 创建新集群 ID（`b79f...`），与原集群 ID（`1db6...`）不同 | **放弃 restore 的数据，清空数据目录，用 `--initial-cluster-state=existing` 从 leader 全量同步** |
| 5 | `member remove` 用十进制 ID | `strconv.ParseUint: value out of range` | `member remove` 参数要求十六进制 | 从 `member list -w table` 的 ID 列直接复制 hex 值 |
| 6 | SCP 在 sshpass 下静默失败 | 传输无报错但目标文件不存在 | sshpass + scp 兼容性问题，进程被信号中断 | 改用 SSH 管道 `cat | ssh "cat > file"` 传输 |
| 7 | kubelet 用缓存的 mirror pod spec 启动 etcd | 清单已更新，但 etcd 进程仍用旧 `--initial-cluster` | kubelet 缓存了旧的 pod spec | 杀掉 etcd → 移走清单 → 等清理 → 移回清单，强制重新读取 |
| 8 | kube-apiserver CrashLoopBackOff | etcd 恢复后 apiserver 仍不启动 | 退避期内 kubelet 不主动重启 | `systemctl restart kubelet` 清除退避状态 |
| 9 | SSH 下 `pkill -f` 误杀自身 | SSH 连接中断 | `pkill -f "snapshot restore"` 匹配到 SSH 命令行中的脚本文本 | 用 `pkill -9 -x etcd`（精确进程名）或按 PID `kill -9` |

---

## 六、注意事项与安全规范

### 6.1 核心原则

1. **先快照，再操作**：任何恢复操作前，先从健康成员制作快照，这是唯一的数据源。
2. **保持 quorum**：3 节点集群移除 1 个成员后剩 2 节点，仍保持 quorum（>50%），集群继续可用。**绝对不要在 2 节点集群中再移除成员**，否则会失去 quorum。
3. **TLS 证书必带**：本集群 etcd 启用了 TLS，所有 `etcdctl` 命令必须带 `--cacert`、`--cert`、`--key`，否则连不上。
4. **静态 Pod 清单先移走再杀进程**：kubeadm 静态 Pod 由 kubelet 管理，不移走清单 kubelet 会自动重启 etcd。
5. **数据目录先备份再删**：操作前 `cp -a` 备份，留兜底。

### 6.2 snapshot restore vs 从 leader 同步

| 方式 | 适用场景 | 优点 | 缺点 |
|---|---|---|---|
| `snapshot restore` | 需要恢复到特定时间点的数据 | 精确恢复历史数据 | 产生新集群 ID，需额外处理才能加入原集群 |
| `--initial-cluster-state=existing` + 空目录 | 数据目录丢失/误删，只需恢复到当前最新状态 | 从 leader 自动全量同步，集群 ID 自动匹配，最简单可靠 | 只能恢复到当前状态，不能回溯历史 |

**推荐**：对于"数据目录误删"场景，**直接用 `--initial-cluster-state=existing` + 空数据目录从 leader 同步**，是最安全、最简洁的方式。`snapshot restore` 适用于需要恢复到特定时间点的场景。

### 6.3 member ID 格式

- `member list -w table` 显示的是**十六进制** ID（如 `5c24992f12ba0ec2`）
- `member list -w json` 显示的是**十进制** ID（如 `6639600178107649730`）
- `member remove` 和 `member add` 的参数**必须用十六进制**

### 6.4 kubelet 缓存问题

kubelet 可能用缓存的 mirror pod spec 启动静态 Pod，即使清单文件已更新。表现为进程 flags 与清单不一致。**解决：杀掉进程 → 移走清单 → 等待 kubelet 清理 → 移回清单**，或 `systemctl restart kubelet`。

### 6.5 清理

恢复完成后清理临时文件：

```bash
# master02 上
rm -f /tmp/snapshot-before-recovery.db
rm -rf /var/lib/etcd.bak-recovery
rm -f /etc/kubernetes/manifests/etcd.yaml.bak-recovery
rm -f /tmp/etcd-restore.log /tmp/etcd-recovery.log
# 保留 etcdctl 二进制以备后用
```

---

## 七、完整恢复命令速查

```bash
# === 1. 从健康成员制作快照 ===
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  snapshot save /var/lib/etcd/snapshot.db

# === 2. 传输快照到受损节点（SSH 管道）===
sshpass -p 'rootroot.' ssh root@10.0.0.121 \
  "cat /var/lib/etcd/snapshot.db" | \
sshpass -p 'rootroot.' ssh root@10.0.0.120 \
  "cat > /tmp/snapshot.db"

# === 3. 从集群移除受损成员（hex ID）===
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  member remove 5c24992f12ba0ec2

# === 4. 停止受损节点 etcd（移走清单 + 杀进程）===
sshpass -p 'rootroot.' ssh root@10.0.0.120 '
  cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
  mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.disabled
  pkill -9 -x etcd
'

# === 5. 删除受损数据目录（先备份）===
sshpass -p 'rootroot.' ssh root@10.0.0.120 '
  cp -a /var/lib/etcd /var/lib/etcd.bak
  rm -rf /var/lib/etcd/member
'

# === 6. 重新加入集群，获取新 member ID 和启动参数 ===
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379 \
  member add master02 --peer-urls=https://10.0.0.120:2380

# === 7. 用 --initial-cluster-state=existing 启动 etcd（从 leader 同步）===
sshpass -p 'rootroot.' ssh root@10.0.0.120 '
  nohup etcd \
    --name=master02 \
    --initial-cluster=m01=https://10.0.0.61:2380,master01=https://10.0.0.121:2380,master02=https://10.0.0.120:2380 \
    --initial-cluster-state=existing \
    --initial-advertise-peer-urls=https://10.0.0.120:2380 \
    --data-dir=/var/lib/etcd \
    [其余参数同静态 Pod 清单] \
    > /tmp/etcd.log 2>&1 &
  sleep 8
  cat /tmp/etcd.log  # 确认：cluster-id 与原集群一致，received snapshot，ready to serve
'

# === 8. 更新静态 Pod 清单 + 交还 kubelet ===
sshpass -p 'rootroot.' ssh root@10.0.0.120 '
  # 更新 etcd.yaml 的 --initial-cluster 为完整 3 节点配置
  # 添加 --initial-cluster-state=existing
  kill $(pgrep -x etcd)
  sleep 3
  mv /etc/kubernetes/manifests/etcd.yaml.disabled /etc/kubernetes/manifests/etcd.yaml
'

# === 9. 重启 kubelet 恢复 apiserver ===
sshpass -p 'rootroot.' ssh root@10.0.0.120 'systemctl restart kubelet'

# === 10. 验证 ===
kubectl get nodes
kubectl -n kube-system get pods -l component=etcd -o wide
kubectl -n kube-system exec etcd-master01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://10.0.0.121:2379,https://10.0.0.120:2379,https://10.0.0.61:2379 \
  endpoint health
```
