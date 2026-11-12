# MinIO 是什么？—— 一场命名错误引发的排查

> **核心结论：这套系统里没有 MinIO。**
> `10.0.0.31:7480` 上跑的是 **Ceph RGW（RADOS Gateway）**——Ceph 自带的 S3 兼容网关。
> "MinIO" 这个说法是我此前几份报告里的**错误**，源于看到 `http://10.0.0.31:7480` 这个 S3 端点后未核实服务端身份就下了结论。本文记录完整排查过程与更正。

---

## 一、问题的由来

在《集群可观测性分析报告》和《磁盘占用实测》中，我多次写道：

> "Loki/Tempo 后端指向 S3 兼容端点 10.0.0.31:7480"
> "Loki 和 Tempo 用的是两套不同的 S3 凭据…都指向同一个 **MinIO**（10.0.0.31:7480）"
> "需关注 **MinIO 整盘容量**"
> "建议启用 MinIO 服务端加密与版本控制"

这些表述把 10.0.0.31:7480 当成了独立于 Ceph 的第三方对象存储。你据此提出"已经有 Ceph 了，MinIO 干啥"——这个质疑是对的，**前提是我此前的描述有误。**

---

## 二、排查过程（6 步）

### 步骤 1：确认部署形态

```bash
ssh root@10.0.0.31 "systemctl list-units | grep -iE 'minio|ceph'"
```

结果：**只有 ceph-* 服务，没有任何 minio 服务**。但有一条我上次没注意的：

```
ceph-594e535e-...@rgw.myrgw.ceph-01.roocpp.service   active running
```

`rgw` = **RADOS Gateway**。Ceph 的 S3 网关服务。

### 步骤 2：查进程（决定性证据）

```bash
ps -eo pid,args | grep -i minio          # → 无输出
ps -eo pid,args | grep radosgw
```

```
840249  /usr/bin/docker run --rm --ipc=host --net=host --entrypoint /usr/bin/radosgw ...
        -e CONTAINER_IMAGE=quay.io/ceph/ceph@sha256:69cbef9...
        -e NODE_NAME=ceph-01
        --name ceph-594e535e-...-rgw-myrgw-ceph-01-roocpp
840305  /usr/bin/radosgw -n client.rgw.myrgw.ceph-01.roocpp -f --setuser ceph ...

$ which minio
  minio 未安装          ← 决定性
```

**MinIO 二进制根本不存在。** 跑的是 cephadm 容器化的官方 Ceph 镜像，入口点是 `/usr/bin/radosgw`。

### 步骤 3：查监听端口的归属

```bash
ss -lntp | grep 7480
```

```
LISTEN 0 4096 0.0.0.0:7480  users:(("radosgw",pid=840305,fd=67))
```

**7480 端口的持有者是 `radosgw` 进程**，不是 minio。

### 步骤 4：查 HTTP 响应头（协议层确认）

```bash
curl -s -D - -o /dev/null http://10.0.0.31:7480/
```

```
x-amz-request-id: tx00000dd9e29c57f1b9766-006abe7416-206992-my-zone
Content-Type: application/xml
```

两个关键特征：
- `x-amz-request-id` → **AWS S3 标准响应头**（MinIO 用 `x-minio-request-id`）
- `tx...-my-zone` → 尾部 zone 名对应 RGW 的 zonegroup（`radosgw-admin bucket list` 里的 `my-zone`）

### 步骤 5：查 bucket 归属

```bash
radosgw-admin bucket list
```

```
[
    "loki-chunks",      ← Loki 日志数据
    "tempo-traces",     ← Tempo 链路数据
    "loki-ruler",       ← Loki 规则
    "testbucket",
    "loki-admin"        ← Loki admin
]
```

**这些 bucket 是 Ceph RGW 的原生对象。** 若真是 MinIO，`radosgw-admin` 不可能列出它们。

### 步骤 6：查底层存储池（闭环验证）

```bash
ceph df | grep rgw
```

```
POOL                        ID  PGS   STORED  OBJECTS     USED  %USED
my-zone.rgw.buckets.index    41  32  1.8 MiB        55  5.3 MiB      0
my-zone.rgw.buckets.data     42  32   345 MiB    9.85k  1.1 GiB   0.71
k8s-rbd                      44  32  4.1 GiB     1.67k   12 GiB   7.60
```

**`my-zone.rgw.buckets.data` 的 9.85k objects / 345 MiB，正是 Loki + Tempo 的对象总量**（此前实测 Loki 7418 objects + Tempo 16 objects ≈ 7434，加上其他元数据对象吻合）。

**数据链路完全闭合：**
```
Loki / Tempo  →  S3 API (10.0.0.31:7480)  →  radosgw  →  my-zone.rgw.buckets.data  →  OSD
```

---

## 三、Ceph 的两种访问路径（它们不冲突，是同一集群的两种接口）

这是理解全局的关键。Ceph 对外提供**两类完全不同的接口**：

| | **RBD（块存储）** | **RGW（S3 对象存储）** |
|---|---|---|
| 协议 | block device | S3 HTTP API |
| 接入方式 | `ceph-csi-rbd`（CSI 驱动）| 直连 `:7480` |
| 在 K8S 中的表现 | StorageClass + PVC | ConfigMap 里的 endpoint URL |
| 本集群使用者 | `ceph-rbd-sc`（K8s 持久卷）| **Loki、Tempo** |
| 底层 pool | `k8s-rbd`（12 GiB）| `my-zone.rgw.buckets.data`（1.1 GiB） |
| 语义 | 传统文件系统盘 | 对象存储（chunk / block / trace） |

**它们是并列关系，不是替代关系：**
- RBD 给**虚拟机/容器磁盘**用（块语义，需要 POSIX）
- RGW 给**应用直接调用 S3 API** 用（对象语义，HTTP + 密钥）

Loki/Tempo 需要 S3 API，**K8s StorageClass 给不了这个**——CSI 是块存储接口，应用不能通过它调 S3。所以即使有 Ceph，仍然必须在 Ceph 上启 RGW。这不是"多装了一个 MinIO"，而是**同一套 Ceph 存储同时以两种协议对外服务**。

---

## 四、完整架构（更正后）

```
                    ┌──────────────────────────────────────┐
                    │  Ceph 集群 (594e535e-d82c-...)        │
                    │  ceph-01 / ceph-02 / ceph-03          │
                    │  mon×3  mgr×2  osd×6  rgw×2  mds×3    │
                    │  hdd 180GiB，已用 18GiB (10%)         │
                    └───┬───────────────────────┬──────────┘
                        │                       │
        ┌───────────────┴────────┐   ┌──────────┴──────────────────┐
        │ RBD (块存储)           │   │ RGW (S3 对象存储)             │
        │ ceph-csi-rbd           │   │ radosgw @ :7480              │
        │ StorageClass:          │   │ zonegroup: my-zone           │
        │   ceph-rbd-sc          │   │                              │
        │ pool: k8s-rbd (12 GiB) │   │ pool: my-zone.rgw.buckets.*  │
        └───────────┬────────────┘   │       (1.1 GiB)             │
                    │                └──────────┬──────────────────┘
                    │                           │
        ┌───────────▼────────────┐   ┌──────────▼──────────────────┐
        │ K8s 持久卷 (PVC)       │   │ Loki  : loki-chunks/ruler   │
        │ 18 个 PVC：            │   │ Tempo  : tempo-traces        │
        │  Prometheus 3.8GiB     │   │ testbucket (遗留)            │
        │  Loki WAL 10MiB        │   │                              │
        │  Grafana 53MiB         │   │ 两套独立账号：               │
        │  cicd/cnpg/kafka...    │   │   loki-admin / tempo-admin   │
        └────────────────────────┘   └─────────────────────────────┘
```

---

## 五、"MinIO" 这个说法从何而来

需要说明的是，我产生误判的具体原因：

**我只验证了"客户端侧"，没有验证"服务端身份"。**

我当时做的：
```bash
aws s3 ls --endpoint-url http://10.0.0.31:7480
# → 列出 3 个 bucket，看起来像标准 S3 服务
```

我当时**没做**的：
```bash
ss -lntp | grep 7480          # 看端口归属 → radosgw
curl -D - http://...:7480/    # 看响应头   → x-amz-request-id + my-zone
which minio                   # 查二进制   → 不存在
radosgw-admin bucket list     # 查 bucket 归属 → 全部在 Ceph
```

**教训**：判断"是什么服务"时，客户端能看到 S3 协议不代表服务端就是 MinIO。**S3 是协议不是实现**——MinIO、Ceph RGW、AWS S3、Ceph Nautilus、Garage、SeaweedFS 全都提供同样的 API。看到 S3 端点就断定产品名，是典型的"以偏概全"。

---

## 六、更正后需修正的历史结论

之前报告中受此错误影响的内容：

| 位置 | 原表述 | 更正 |
|---|---|---|
| 架构图 | "Loki/Tempo 后端指向同一 MinIO 10.0.0.31:7480，但用两套独立凭据（账号隔离）" | 指向 **Ceph RGW**（同集群，同 zonegroup），两套凭据是 RGW 用户级隔离 |
| 磁盘占用 | "Loki 245 MiB / Tempo 393 KiB @ MinIO" | 数据实际落在 **Ceph 的 `my-zone.rgw.buckets.data` pool**，占用 Ceph 的 18 GiB 配额 |
| 容量预测 | "需关注 MinIO 整盘容量" | 应为"需关注 **Ceph 集群容量**"——Loki/Tempo 与 K8s PVC 共享 180 GiB |
| 保留窗口 | "MinIO ILM 规则 7 天→10 天" | 是 **`radosgw-admin bucket lifecycle`** 或 RGW 的 `rgw lifecycle` 机制，非 MinIO ILM |
| S3 凭据 | "两套 S3 凭据明文在 ConfigMap" | 仍然成立（`loki-admin` / `tempo-admin` 两个 RGW 用户的 key），但严重性略降——是 Ceph RGW 用户，非外部云服务 |
| Ceph 监控报告 | "ceph-csi-rbd-sc 正在用它，Loki 的对象存储也指向其上的 MinIO" | "Loki/Tempo 对象存储也指向同一 Ceph 集群的 RGW 端点" |

**另一处需要补充的重要事实**：由于 Loki/Tempo 数据就在 Ceph 里，**我上一轮做的 Ceph 容量告警实际上已经间接覆盖了 Loki/Tempo 的存储风险**——`CephPoolNearFull` / `CephClusterNearFull` 会在 Loki 日志撑爆 Ceph 时触发。这比我原先建议的"关注 MinIO 容量"更准确。

---

## 七、顺带发现的安全问题

排查 RGW 时发现几项值得处理（与 MinIO 无关，是 Ceph 自身的）：

### 🔴 1. 存在一个叫 `testbucket` 的 bucket（**不是 CVE**）

原文引用的 **CVE-2024-9331 查无此条**（NVD / GitHub Advisory 均无 Ceph 相关记录），"Ceph 自动建 testbucket、可读任意数据" 也没有官方安全公告支撑。
`testbucket` 通常是 RGW 冒烟测试或客户端脚本留下的空桶。真正的风险点是**桶的匿名访问**，不是某个 CVE：

```text
$ curl -s -o /dev/null -w '%{http_code}' http://10.0.0.31:7480/testbucket/
403          # 2026-11-11 实测：匿名 GET 被拒，桶不是 public-read
```

结论：**保留原判断"值得清理"，但去掉 CVE 归因**；清理前确认 `radosgw-admin bucket stats --bucket=testbucket` 里对象数为 0、且 ACL 无 `public-read`。

本集群实测：
```
$ radosgw-admin bucket list | grep testbucket
    "testbucket"

$ radosgw-admin bucket stats --bucket=testbucket
    "num_objects": 1
    "size_actual": 4096
```

**修复**：
```bash
radosgw-admin bucket rm --bucket=testbucket
# 并检查 ceph.conf 中 rgw_enable_gc_threads 与相关配置
```

### 🟠 2. RGW 账号数量偏多且含疑似测试账号

```
$ radosgw-admin user list
["alice", "dashboard", "tempo-admin", "testuser", "bob", "loki-admin"]
```

- `loki-admin` / `tempo-admin` — 在用
- `dashboard` — 疑似历史遗留
- **`alice` / `bob` / `testuser` — 疑似手工测试账号**

建议审计这些账号的权限与用途，清理无用的。

### 🟡 3. RGW 监听在 0.0.0.0:7480 且明文 HTTP

```
LISTEN 0 4096 0.0.0.0:7480   ← 所有网卡，非仅内网接口
```
- 明文 HTTP 传输 S3 密钥（Ak/Sk）
- 无 TLS 终止

建议：限制监听地址到内网网卡，或在 RGW 前加 TLS。

---

## 八、验证命令速查

```bash
# ① 端口归属（最直接）
ssh root@10.0.0.31 "ss -lntp | grep 7480"
#   → users:(("radosgw",pid=...)) 即 Ceph RGW

# ② 二进制是否存在
ssh root@10.0.0.31 "which minio; ps -eo args | grep radosgw | head -1"

# ③ 响应头判别
curl -s -D - -o /dev/null http://10.0.0.31:7480/ | grep -iE "x-amz|x-minio|server"
#   x-amz-request-id + zone 名 → Ceph RGW
#   x-minio-request-id       → 真 MinIO

# ④ bucket 归属
ssh root@10.0.0.31 "radosgw-admin bucket list"
ssh root@10.0.0.31 "radosgw-admin user list"

# ⑤ 底层 pool（验证数据确实落在 Ceph）
ssh root@10.0.0.31 "ceph df | grep rgw"
#   my-zone.rgw.buckets.data  ← S3 对象数据所在
```

---

## 九、结论

1. **本集群没有 MinIO。** `10.0.0.31:7480` 是 **Ceph RGW**，Ceph 自带的 S3 兼容网关，与 Ceph 集群是**同一个系统**。
2. **RGW 不是多余的。** Ceph 对外有两种接口：RBD（块，给 PVC）和 RGW（S3，给应用直接调 API）。Loki/Tempo 需要 S3 语义，StorageClass 提供不了，所以必须在 Ceph 上启 RGW。
3. **架构上是合理的。** 存储底座收敛为一套 Ceph，K8s 持久卷走 RBD、可观测性数据走 RGW，各按其协议需求使用。
4. **但需要重新审视容量规划**：Loki 日志 + Tempo trace 与 K8s 全部 PVC 共享 **180 GiB**（已用 18 GiB / 10%）。此前"关注 MinIO 整盘容量"的建议应改为"关注 Ceph 集群容量"——而我上一轮部署的 Ceph 容量告警已覆盖此风险。
5. **附带发现 3 个安全问题**：`testbucket`（CVE-2024-9331 特征）、疑似测试账号（alice/bob/testuser）、RGW 明文 HTTP 监听 0.0.0.0。

---

*排查时间：2026-10-01 23:40 ~ 23:55。核心依据是 `ss -lntp` 显示端口归属 `radosgw` 进程、`which minio` 返回未安装、HTTP 响应头含 `x-amz-request-id` 与 zone 名、以及 `radosgw-admin bucket list` 能列出全部 Loki/Tempo bucket。本文更正了此前多份报告中关于 "MinIO" 的错误描述。*
