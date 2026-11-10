# 线2 执行报告：Calico 升级（两步完成）

> **执行时间**：2026-10-03 05:08 ~ 05:30
> **结果**：✅ **v3.27.4 → v3.30.7 → v3.32.2 两步全部完成**，跨节点网络双向正常

---

## 一、最终状态

| 项 | 升级前 | 升级后 |
|---|---|---|
| calico/node | `docker.io/calico/node:v3.27.4` | **`quay.io/calico/node:v3.32.2`** |
| calico/kube-controllers | `docker.io/calico/kube-controllers:v3.27.4` | **`quay.io/calico/kube-controllers:v3.32.2`** |
| calico/cni | docker.io/calico/cni | quay.io/calico/cni |
| 节点覆盖 | 6/6 | **6/6 全部 v3.32.2** |

### 配置保持验证（★升级前后完全一致）

| 配置 | 值 | 状态 |
|---|---|---|
| `calico_backend` | `bird` | ✅ 保持 |
| `CLUSTER_TYPE` | `k8s,bgp` | ✅ 保持 |
| IPPool ipipMode | `Always` | ✅ 保持 |
| IPPool cidr | `10.244.0.0/16` | ✅ 保持 |
| `CALICO_IPV4POOL_VXLAN` | `Never` | ✅ 保持 |
| `bpfConnectTimeLoadBalancing` | `TCP` | ✅ **v3.32 仍支持** |
| `bpfHostNetworkedNATWithoutCTLB` | `Enabled` | ✅ **v3.32 仍支持** |

**★ 之前标记「待核实」的 BPF 字段问题已排除**：v3.30.7 和 v3.32.2 manifest 都保留这两个字段，apply 无报错。

---

## 二、跨节点网络验证（Calico 升级的核心判据）

| 阶段 | 方向 | 结果 |
|---|---|---|
| 升级前基线 | worker01 → worker02 | 0% loss, avg 0.610ms |
| 3.30.7 后 | a→b | 0% loss, avg 0.718ms |
| 3.30.7 后 | b→a | 0% loss, avg 0.590ms |
| **3.32.2 后** | a→b | **0% loss, avg 0.775ms** |
| **3.32.2 后** | b→a | **0% loss, avg 0.560ms** |

**IPIP Always封装保持有效，跨节点 Pod 网络无中断。**

---

## 三、业务健康（最终）

| 组件 | 状态 |
|---|---|
| 节点 | 6/6 Ready |
| Pod | Running 142 / Pending 1（n8n，Docker Hub 不通，非本次问题）|
| Prometheus | 2/2 Running |
| Grafana | 3/3 Running |
| Kafka | `my-cluster True 4.1-IV1` |
| CNPG | `pg16-ceph` 正常 |
| Loki | 9 Running |
| Traefik | 1/1 Running |
| ArgoCD | 1/1 Running |
| Tekton | 7 Running |
| MetalLB | 7 Running |

---

## 四、执行过程

### 步骤1：v3.27.4 → v3.30.7

```
[05:08:49] 备份 → /root/k8s-upgrade-1.29-to-1.35/work/calico/backup-20261003-050849
            含 crds.yaml (16M) / calico-node / calico-config / ippool / felixconfiguration
[05:10:47] apply --server-side --force-conflicts成功
            kube-controllers 滚动完成
            calico-node 滚动 4/6 后超时（maxUnavailable=1 限制）
            → 手动强制删除 2 个旧 Pod后完成 6/6
[05:15:47] 版本 3.27.4 → 3.30.7，配置全部保持，6 节点 Ready
```

### 步骤2：v3.30.7 → v3.32.2

```
[05:25:09] apply 成功，daemonset "successfully rolled out"（一次完成，无需干预）
            版本 3.30.7 → 3.32.2，配置全部保持，6 节点 Ready
```

**两步对比**：3.30→3.32 一次滚动成功，而 3.27→3.30 需要手动干预。原因是 3.27→3.30 跨越更大，且当时有 Pod 卡在 Terminating。

---

## 五、遇到的问题

### 1. GitHub raw 不通（与线1 同一问题）

```
curl: (35) OpenSSL SSL_connect: 连接被对方重设
raw.githubusercontent.com:443
```

**解决**：改用 `ghproxy.net` 镜像：
```bash
curl -fsSL -o calico-v3.32.2.yaml   https://ghproxy.net/https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml
```
**→ 脚本已改为「本地优先 → GitHub 直连 → ghproxy 镜像」三级回退。**

### 2. 镜像仓库从 docker.io 变为 quay.io

| 版本 | 镜像仓库 |
|---|---|
| v3.27.4（原）| `docker.io/calico/*` |
| v3.30.7 | `docker.io/calico/*` |
| **v3.32.2** | **`quay.io/calico/*`** |

**这是官方上游的选择**（Calico 从 3.31 起改用 quay.io）。

**风险**：`docker.io` 在本集群不通，而 `quay.io` 可达。**升级前已实测验证**：
```bash
crictl pull quay.io/calico/node:v3.32.2
→ Image is up to date for sha256:c5f89ea6b761...
```
**若不预验证，升级后 calico-node 会全部 ImagePullBackOff。**

### 3. calico-node 滚动卡在 4/6

```
Waiting for daemon set "calico-node" rollout to finish: 4 out of 6 new pods have been updated...
error: timed out waiting for the condition
```

**根因**：DS 的 `maxUnavailable=1` + m01/worker02 上的旧 Pod 卡在 Terminating 状态（重启数 42/43，历史遗留）。

**解决**：强制删除旧 Pod，rollout 随即完成。
```bash
kubectl -n kube-system delete pod calico-node-snf2k --grace-period=0 --force
```

---

## 六、★ 升级前的重要确认（避免了潜在故障）

升级前对 manifest 逐项核对，确认了 4 件事：

| # | 检查项 | 结果 | 若不检查的后果 |
|---|---|---|---|
| 1 | manifest 的 `calico_backend` 默认值 | `bird` ✓ | 若为 `felix`，BGP 路由失效 |
| 2 | manifest 的 `CALICO_IPV4POOL_IPIP` | `Always` ✓ | **若为 Never，跨节点网络直接断** |
| 3 | manifest 是否含 IPPool 实例 | 不含（只是 CRD 定义） | 若含，会用 192.168.0.0/16 覆盖现有 10.244.0.0/16 |
| 4 | BPF 字段是否仍支持 | 两个都在 ✓ | apply 报错或配置被重置 |

**第 3 项尤其重要** —— manifest 里有 `kind: IPPool` 字样，但那是 **CRD schema 定义**，不是实例。如果误判为「会覆盖」并强行处理，反而可能出错。

---

## 七、备份位置

```
/root/k8s-upgrade-1.29-to-1.35/work/calico/backup-20261003-050849/
├── crds.yaml (16M)              # 全部 CRD
├── calico-node.yaml             # DS v3.27.4
├── calico-kube-controllers.yaml # Deployment v3.27.4
├── calico-config.yaml           # ConfigMap
├── ippool.yaml                  # default-ipv4-ippool
├── felixconfiguration.yaml      # Felix BPF 配置
└── typha-cfg.yaml               # 空（未用 Typha）
```

### 回滚方式
```bash
cd /root/k8s-upgrade-1.29-to-1.35/work/calico/backup-20261003-050849
kubectl apply -f crds.yaml
kubectl apply -f calico-node.yaml
kubectl apply -f calico-kube-controllers.yaml
kubectl apply -f calico-config.yaml
kubectl apply -f ippool.yaml
kubectl apply -f felixconfiguration.yaml
```

---

## 八、线2 后续

**Calico 升级已完成**，官方测试矩阵（v3.32）明确覆盖 K8s 1.34/1.35/1.36，为线4 铺平了道路。

**建议观察** 12-24 小时后启动线3（kube-proxy IPVS → iptables）。

---

## 九、进度更新

| 线 | 状态 |
|---|---|
| 线1 containerd 2.3.2 | ✅ 完成 |
| **线2 Calico v3.32.2** | ✅ **完成** |
| 线3 kube-proxy IPVS→iptables | ⏸ 待启动 |
| 线4 K8s 1.29→1.35 | ⏸ 脚本待写 |
| n8n 镜像（Docker Hub 不通）| 🔴 待决策 |

---

*线2 完成：2026-10-03 05:30。Calico v3.27.4 → v3.30.7 → v3.32.2 两步升级成功，6/6 节点 v3.32.2，配置（BIRD/IPIP Always/BPF）全部保持，跨节点网络双向 0% 丢包，业务全绿。升级前确认 manifest 默认值与本集群一致，避免了跨节点网络中断风险。*
