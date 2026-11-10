# Cilium BPF LB 表 · 多轮问答汇总

> 本文档汇总了对 `cilium-dbg bpf lb list` 输出的一系列讨论：从输出解读、字段含义，到 Slot/Revnat 机制、NodePort/HostPort、Headless Service 等概念。

---

## 目录

1. [BPF LB 输出格式详解](#一bpf-lb-输出格式详解)
2. [机器/节点识别](#二机器节点识别)
3. [Q1：`0.0.0.0:0` 是什么 Pod？](#q1-00000-是什么-pod)
4. [Q2：Slot 0 和 Slot 1 到底怎么区分？](#q2-slot-0-和-slot-1-到底怎么区分)
5. [Q3：SVC 和 Pod 对应关系为什么没按顺序？](#q3-svc-和-pod-对应关系为什么没按顺序)
6. [Q4：`0.0.0.0:30080` 是什么 Service？](#q4-0000030080-是什么-service)
7. [Q5：本机"任何 IP"是什么意思？](#q5-本机任何-ip是什么意思)
8. [Q6：NodePort 和 HostPort 的区别](#q6-nodeport-和-hostport-的区别)
9. [Q7：Headless Service 适用场景详解](#q7-headless-service-适用场景详解)
10. [附录：本次分析所用 BPF 原始输出](#附录本次分析所用-bpf-原始输出)

---

## 一、BPF LB 输出格式详解

```
SERVICE ADDRESS                BACKEND ADDRESS (REVNAT_ID) (SLOT)
  虚拟服务地址(前端)              真实后端地址    (反向NAT ID)  (槽位号)
```

### 字段含义

| 字段 | 含义 |
|------|------|
| SERVICE ADDRESS | Kubernetes Service 的虚拟 IP（ClusterIP/NodePort/LoadBalancer）+ 端口/协议 |
| BACKEND ADDRESS | 后端 Pod 的真实 IP + 端口/协议 |
| REVNAT_ID | 反向 NAT 编号，**需要结合上下文判断关联**（见 Q2/Q3） |
| SLOT | Service 地址下的条目槽位编号（见 Q2） |
| `[标签]` | Service 类型注解：ClusterIP、NodePort、LoadBalancer、HostPort、non-routable、InternalLocal |

### 标签速查

| 标签 | 含义 |
|------|------|
| `ClusterIP` | 集群内部虚拟 IP 服务 |
| `NodePort` | 节点端口暴露 |
| `LoadBalancer` | 外部负载均衡 IP（BGP/MetalLB 等） |
| `HostPort` | Pod 直接占用宿主机端口 |
| `non-routable` | 仅限集群内部/本地，不可对外路由 |
| `InternalLocal` | 内部流量本地优先（internalTrafficPolicy: Local） |

---

## 二、机器/节点识别

通过输出可以识别出 **3 个节点的 IP**：

```
192.168.67.201  ← 节点1 (Ubuntu01，同时运行 kube-apiserver:6443)
192.168.67.202  ← 节点2 (Ubuntu02，本 BPF 表所属节点)
192.168.67.203  ← 节点3
```

**判断 BPF 表所属节点的方法：**

- 输出中 NodePort 的**具体 IP 条目**（`192.168.67.202:30080/30135/31124`）全部为 **.202**，且 `.201/.203` 只有 LoadBalancer 条目
- 说明本次 dump 来自 **Ubuntu02（.202）上运行的 cilium-agent**
- `0.0.0.0:端口` 是"本机监听"的通配条目
- 各节点均维护完整的 Service 映射 → **Cilium 的 kube-proxy replacement 模式**

---

## 三、分类详解（附示例）

### 类别 1：ClusterIP Service

**特征：** 仅集群内部可访问，标签含 `ClusterIP, non-routable`

**示例 A：ClusterIP → 单后端（kubernetes/apiserver）**

```
REVNAT_ID=5
10.43.0.1:443/TCP (0)          0.0.0.0:0 (5) (0) [ClusterIP, non-routable]   ← SLOT 0 定义
10.43.0.1:443/TCP (1)          192.168.67.201:6443/TCP (5) (1)                ← SLOT 1 后端
```

**示例 B：ClusterIP → 多后端（负载均衡）**

```
REVNAT_ID=27
10.43.162.164:80/TCP (0)       0.0.0.0:0 (27) (0) [ClusterIP, non-routable]  ← 定义
10.43.162.164:80/TCP (1)       10.0.1.123:80/TCP (27) (1)                    ← 后端 Pod 1
10.43.162.164:80/TCP (2)       10.0.2.178:80/TCP (27) (2)                    ← 后端 Pod 2
```

**示例 C：ClusterIP 无后端（headless 或 Endpoints 为空）**

```
10.43.66.133:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.148.231:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.162.164:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
```

### 类别 2：NodePort Service

**特征：** 所有节点监听统一端口（30000-32767），标签含 `NodePort`

```
REVNAT_ID=11
0.0.0.0:31124/TCP (0)          0.0.0.0:0 (11) (0) [NodePort, non-routable]
0.0.0.0:31124/TCP (1)          10.0.2.216:8000/TCP (11) (1)
192.168.67.202:31124/TCP (0)   0.0.0.0:0 (12) (0) [NodePort]
192.168.67.202:31124/TCP (1)   10.0.2.216:8000/TCP (12) (1)
```

### 类别 3：LoadBalancer Service

**特征：** 有外部 IP，标签含 `LoadBalancer`

```
REVNAT_ID=18
192.168.67.201:443/TCP (0)     0.0.0.0:0 (18) (0) [LoadBalancer]
192.168.67.201:443/TCP (1)     10.0.2.216:8443/TCP (18) (1)
```

**LoadBalancer 汇总：**

| LoadBalancer IP | 端口 | 后端 Pod |
|----------------|------|---------|
| 192.168.67.201 | 443 | 10.0.2.216:8443 |
| 192.168.67.201 | 80 | 10.0.2.216:8000 |
| 192.168.67.202 | 443 | 10.0.2.216:8443 |
| 192.168.67.202 | 80 | 10.0.2.216:8000 |
| 192.168.67.203 | 443 | 10.0.2.216:8443 |
| 192.168.67.203 | 80 | 10.0.2.216:8000 |

> 每个节点都有 LB 声明 → 使用 **BGP 或 MetalLB** 模式，各节点都在宣告外部 IP

### 类别 4：HostPort Service

**特征：** Pod 占用宿主机端口，标签含 `HostPort`

```
REVNAT_ID=21 / 22
0.0.0.0:80/TCP (0)             0.0.0.0:0 (21) (0) [HostPort, non-routable]
0.0.0.0:80/TCP (1)             10.0.1.163:80/TCP (21) (1)
0.0.0.0:443/TCP (0)            0.0.0.0:0 (22) (0) [HostPort, non-routable]
0.0.0.0:443/TCP (1)            10.0.1.163:443/TCP (22) (1)
```

### 类别 5：DNS Service（kube-dns / CoreDNS）

```
REVNAT_ID=1 / 2 / 3
10.43.0.10:53/TCP (0)        0.0.0.0:0 (1) (0) [ClusterIP, non-routable]
10.43.0.10:53/TCP (1)        10.0.0.4:53/TCP (1) (1)
10.43.0.10:53/UDP (1)        10.0.0.4:53/UDP (2) (1)
10.43.0.10:9153/TCP (1)      10.0.0.4:9153/TCP (3) (1)
```

### 后端 Pod 分布推断

| Pod IP | 推测节点 (PodCIDR) | 运行的服务 |
|--------|---------|-----------|
| 10.0.0.4 | 10.0.0.0/24 | kube-dns (CoreDNS) |
| 10.0.0.17 | 10.0.0.0/24 | 应用服务 (8081) |
| 10.0.0.61 | 10.0.0.0/24 | kubelet (10250) |
| 10.0.0.75 | 10.0.0.0/24 | 代理服务 (4245) |
| 10.0.1.123 | 10.0.1.0/24 | Web (80) |
| 10.0.1.137 | 10.0.1.0/24 | Web (80) |
| 10.0.1.163 | 10.0.1.0/24 | HostPort 服务 (80/443) |
| 10.0.2.93 | 10.0.2.0/24 | Web (80) |
| 10.0.2.178 | 10.0.2.0/24 | Web (80) |
| **10.0.2.216** | **10.0.2.0/24** | **最繁忙的 Pod (8000/8443)，承载几乎所有 LB/NodePort 流量** |

---

## Q1：`0.0.0.0` 是什么 Pod？

**不是任何 Pod，也不是任何机器，是"占位符 / 通配符"。**

- SLOT 0 条目代表 Service 的"前端定义"，本身不接收流量
- 后端地址 `0.0.0.0:0` = 该条目**没有关联后端**，用于登记 Service 存在并承载 REVNAT_ID
- 真正的转发目标在 **SLOT 1+** 中

```
REVNAT_ID=5
┌─────────────────────────────────────────────┐
│ SLOT 0 (定义)  10.43.0.1:443 → 0.0.0.0:0   │ ← 占位，无真实后端
│ SLOT 1 (后端)  10.43.0.1:443 → 192.168.67.201:6443 ← 真实转发目标
└─────────────────────────────────────────────┘
```

---

## Q2：Slot 0 和 Slot 1 到底怎么区分？

**不是简单"前端/后端"。** 二者是**同一 Service 地址下、不同 BPF Map Key 的条目**。

### 本质：BPF Map Key 结构

```
Cilium 的 lb4_services map 的 Key 是：
(Service IP, 端口, 协议, SLOT号)

10.43.0.1:443:TCP + SLOT 0  →  Service 元数据条目
10.43.0.1:443:TCP + SLOT 1  →  第 1 个后端条目
10.43.0.1:443:TCP + SLOT 2  →  第 2 个后端条目（若有）
```

### 用途对照

| SLOT | 存储内容 | 作用 |
|------|---------|------|
| **SLOT 0** | Service 元数据（REVNAT_ID、类型标志、`0.0.0.0:0` 占位） | 声明 Service 存在，建立 "虚拟 IP → REVNAT_ID" 映射，供反向 NAT |
| **SLOT 1+** | 真实后端地址（Pod/Node IP） | 数据面实际转发的目标 |

### 数据包转发流程

```
包到达 10.43.0.1:443
   ├─ 1. 查 SLOT 0 → 确认合法 Service、拿到 REVNAT_ID、类型
   ├─ 2. 负载均衡哈希 (Maglev/随机) 选出一个后端 ID
   ├─ 3. 查 SLOT N → 得到真实目标 192.168.67.201:6443
   └─ 4. DNAT 转发，REVNAT_ID 记入 conntrack，回包时还原
```

**一句话：** SLOT 0 = "服务登记表"（含 REVNAT_ID），SLOT 1+ = "后端地址表"；共用同一 Service IP，靠 SLOT 字段区分。

---

## Q3：SVC 和 Pod 的对应关系为什么没按顺序？

**观察正确。** 同一 Service 的条目**不连续显示**。

### 举例（REVNAT_ID=27）

```
第22行附近↓ 10.43.162.164:80/TCP (0)   0.0.0.0:0 (27) (0)   定义
第30行附近↓ 10.43.162.164:80/TCP (2)   10.0.2.178:80 (27) (2) 后端B
第33行附近↓ 10.43.162.164:80/TCP (1)   10.0.1.123:80 (27) (1) 后端A 反而在最后
```

### 原因

`cilium-dbg bpf lb list` 是**直接遍历 BPF 哈希表**（`lb4_services`）逐个输出：

- 顺序由 BPF Map 的**内部哈希桶结构**决定，与 Service 逻辑无关
- 同一 Service 的不同 SLOT 因 Key 哈希到不同桶，**散落各处**
- `0/ANY` 占位条目、各节点 NodePort 条目也交错其中

### 判断分组的正确依据

| 依据 | 用途 |
|------|------|
| **REVNAT_ID 相同** | 通常属于同一 Service 逻辑（注意：NodePort 通配/具体 IP 会各占一个 ID） |
| **SLOT** | slot 0 = 定义，slot 1+ = 后端 |

**推荐命令：** `cilium-dbg service list` 输出 K8s Service 层级的清晰分组。

---

## Q4：`0.0.0.0:30080` 是什么 Service？

```
REVNAT_ID=24
0.0.0.0:30080/TCP (0)   0.0.0.0:0     (24) (0) [NodePort, non-routable]   ← 定义
0.0.0.0:30080/TCP (1)   10.0.0.17:8081 (24) (1)                          ← 后端

REVNAT_ID=25
192.168.67.202:30080/TCP (0)  0.0.0.0:0 (25) (0) [NodePort]
192.168.67.202:30080/TCP (1)  10.0.0.17:8081/TCP (25) (1)
```

**结论：**

- `0.0.0.0:30080` **不是 K8s Service IP**，是 NodePort 的**通配入口** = "本机任意 IP 上的 30080 端口"
- REVNAT 24 和 25 是**同一个 SVC 的两个监听视图**（业务上都是 30080 → Pod 10.0.0.17:8081）
- `non-routable`：通配条目只在本机生效，具体 IP 条目才参与对外
- 验证真实 Service 类型：`kubectl get svc -A | grep 30080`

---

## Q5：本机"任何 IP"是什么意思？

### 关键澄清 1：机器 ≠ 执行命令的机器

- 在 Ubuntu01 敲命令，但 `kubectl exec ds/cilium` 钻进的是**某个 cilium-agent Pod**（DaemonSet）
- 从输出看 NodePort 具体条目全为 `.202` → **本 BPF 表属于 Ubuntu02 的 cilium-agent**
- 你要查哪台节点，就 exec 进那台节点上的 cilium pod：

```bash
kubectl -n kube-system get pod -o wide -l k8s-app=cilium
kubectl -n kube-system exec <对应节点上的cilium-pod> -- \
  cilium-dbg bpf lb list | grep 30080
```

### 关键澄清 2：节点其实有多个 IP

对外网卡虽只有 192.168.67.202，但**数据面角度的本机地址**包括：

| 地址 | 接口 | 说明 |
|------|------|------|
| 192.168.67.202 | eth0 | 物理网卡 IP |
| 10.0.2.x | cilium_host | Pod CIDR 网关/路由 IP |
| 10.0.x.y | cilium_vxlan | 隧道接口 IP |
| 127.0.0.1 | lo | loopback |
| 10.0.2.xx | host 侧 veth | 本机 Pod 的 IP |

**`0.0.0.0:30080` 的实际语义：**

> 不管包目的 IP 是**本机哪个地址**（物理网卡、cilium_host、隧道口、本机 Pod IP），只要端口是 30080，就按该 NodePort Service 兜底处理。

- 这是 BPF 数据面的**通配匹配语义**，不是"某台机器的具体 IP"
- 后端 `10.0.0.17:8081` 在本机（Ubuntu02），属于**本地交付**，因此能直接转发

---

## Q6：NodePort 和 HostPort 的区别

### 对比表

| | NodePort | HostPort |
|---|---|---|
| 定义位置 | **Service** 级别（type: NodePort） | **Pod** 级别（container.ports.hostPort） |
| 生效范围 | **所有节点** 都监听同一端口 | **只有该 Pod 所在节点** 监听 |
| 转发方式 | 走 Service 负载均衡，**任选后端 Pod** | 直连本机的**那个特定 Pod** |
| 端口范围 | 30000～32767 | 无限制 |
| 本质 | 集群层面的服务暴露 | 宿主机与容器的端口映射 |

### 用 BPF 输出举例

**NodePort（30080 → Pod 8081）**

```
0.0.0.0:30080/TCP (1)        10.0.0.17:8081/TCP (24) (1)
192.168.67.202:30080/TCP (1) 10.0.0.17:8081/TCP (25) (1)
```

- 所有节点都监听 30080，访问任何节点 IP:30080 都能到达后端

**HostPort（Pod 占宿主机 80/443）**

```
0.0.0.0:80/TCP (1)   10.0.1.163:80/TCP (21) (1)
0.0.0.0:443/TCP (1)  10.0.1.163:443/TCP (22) (1)
```

- 只有运行该 Pod 的节点有 80/443，其他节点没有对应监听

### 场景对比

```
访问 任意节点IP:31124  ✔  NodePort：任何节点都通
访问 10.0.1.163所在节点:80 ✔  HostPort
访问 其他节点:80         ✘  HostPort 只有所在节点有
```

---

## Q7：Headless Service 适用场景详解

### 定义

不加 ClusterIP（`clusterIP: None`）、不做负载均衡，DNS 直接把**所有后端 IP** 返回给客户端。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  clusterIP: None               # ← 关键
  selector:
    app: my-app
  ports:
    - port: 80
```

### DNS 行为差异

```
普通 Service:     dig my-app.svc → 返回一个 ClusterIP (VIP)
Headless(有selector): dig my-app.svc → 返回全部 Pod IP
                      dig pod-1.my-app.svc → 单个 Pod 的 IP（稳定记录）
Headless(无selector): dig external-db.svc → 返回手动 Endpoints（可指向集群外）
```

### 适用案例

**案例 1：StatefulSet 有状态应用（Kafka/ES/MongoDB/ZooKeeper）—— 需要稳定网络标识**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka-broker
spec:
  clusterIP: None
  selector: { app: kafka }
  ports: [{ name: tcp, port: 9092 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: kafka }
spec:
  serviceName: kafka-broker    # 指向 headless
  replicas: 3
```

- Pod 名稳定：kafka-0 / kafka-1 / kafka-2
- `kafka-1.kafka-broker.svc` 返回固定 Pod IP，重建后名字不变、IP 自动更新
- 集群成员互相发现、主从复制、重连都靠"名字"，而非易变的 IP

**案例 2：客户端需要拿全部后端自己实现负载均衡/采集**

Prometheus 抓取所有 exporter 指标（不能用 LB 随机漂移）：

```
metrics-svc.svc → [10.0.1.123:9100, 10.0.2.178:9100, ...]
```

**案例 3：无 selector 指向集群外资源（旧系统/外部数据库）**

```yaml
kind: Service
metadata: { name: legacy-db }
spec:
  clusterIP: None
---
kind: Endpoints
metadata: { name: legacy-db }
subsets:
  - addresses:
      - ip: 192.168.100.5
      - ip: 192.168.100.6
    ports: [{ port: 3306 }]
```

- 应用固定 DNS 访问，扩缩容只改 Endpoints，零代码改动

**案例 4：业务需精确连接特定副本（读库分流等）**

```
dig +short replica-2.prod-db.svc → 10.0.2.93
客户端 net.Dial("replica-2.prod-db.svc:3306")
```

### 与 BPF 输出的关联

前面出现 `0/ANY`、无后端、`non-routable` 的条目即 headless Service：

```
10.43.66.133:0/ANY (0)    0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.148.231:0/ANY (0)   0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.162.164:0/ANY (0)   0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
```

服务级条目存在、但**无 LB 后端** → Cilium 不需要为它们做负载均衡，客户端直连 Pod IP。

验证：`kubectl get svc -A | grep None`

### 什么时候别用

| 场景 | 该用 |
|------|------|
| 稳定虚拟入口、自动故障转移 | 普通 ClusterIP Service |
| 端口负载均衡/宿主机统一暴露 | NodePort / LoadBalancer |
| 无状态应用（NGINX、API 网关） | 普通 Service |

**一句话：** 应用需要"知道所有后端"（数据库发现、全量采集、直连指定副本、外接系统）用 headless；只想"访问一个稳定入口"用普通 Service。

---

## 附录：本次分析所用 BPF 原始输出

```
SERVICE ADDRESS                BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.43.66.133:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.135.247:443/TCP (0)      0.0.0.0:0 (6) (0) [ClusterIP, InternalLocal, non-routable]
192.168.67.202:443/TCP (0)     0.0.0.0:0 (20) (0) [LoadBalancer]
192.168.67.201:443/TCP (0)     0.0.0.0:0 (18) (0) [LoadBalancer]
192.168.67.203:443/TCP (1)     10.0.2.216:8443/TCP (16) (1)
192.168.67.201:80/TCP (0)      0.0.0.0:0 (17) (0) [LoadBalancer]
192.168.67.201:80/TCP (1)      10.0.2.216:8000/TCP (17) (1)
10.43.146.251:443/TCP (0)      0.0.0.0:0 (14) (0) [ClusterIP, non-routable]
192.168.67.202:30135/TCP (0)   0.0.0.0:0 (10) (0) [NodePort]
10.43.148.231:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.162.164:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
192.168.67.202:31124/TCP (1)   10.0.2.216:8000/TCP (12) (1)
192.168.67.203:443/TCP (0)     0.0.0.0:0 (16) (0) [LoadBalancer]
10.43.135.247:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.174.55:80/TCP (1)        10.0.1.137:80/TCP (28) (1)
10.43.99.249:443/TCP (0)       0.0.0.0:0 (4) (0) [ClusterIP, non-routable]
10.43.66.133:80/TCP (0)        0.0.0.0:0 (23) (0) [ClusterIP, non-routable]
10.43.146.251:443/TCP (1)      10.0.2.216:8443/TCP (14) (1)
192.168.67.202:31124/TCP (0)   0.0.0.0:0 (12) (0) [NodePort]
0.0.0.0:31124/TCP (1)          10.0.2.216:8000/TCP (11) (1)
192.168.67.203:80/TCP (1)      10.0.2.216:8000/TCP (15) (1)
192.168.67.202:30080/TCP (1)   10.0.0.17:8081/TCP (25) (1)
10.43.73.132:8081/TCP (1)      10.0.0.17:8081/TCP (26) (1)
10.43.146.251:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.146.251:80/TCP (1)       10.0.2.216:8000/TCP (13) (1)
10.43.162.164:80/TCP (0)       0.0.0.0:0 (27) (0) [ClusterIP, non-routable]
0.0.0.0:80/TCP (0)             0.0.0.0:0 (21) (0) [HostPort, non-routable]
10.43.135.247:443/TCP (1)      192.168.67.202:4244/TCP (6) (1)
10.43.162.164:80/TCP (2)       10.0.2.178:80/TCP (27) (2)
10.43.73.132:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
0.0.0.0:443/TCP (1)            10.0.1.163:443/TCP (22) (1)
192.168.67.203:80/TCP (0)      0.0.0.0:0 (15) (0) [LoadBalancer]
10.43.162.164:80/TCP (1)       10.0.1.123:80/TCP (27) (1)
10.43.174.55:80/TCP (0)        0.0.0.0:0 (28) (0) [ClusterIP, non-routable]
192.168.67.202:80/TCP (0)      0.0.0.0:0 (19) (0) [LoadBalancer]
10.43.0.10:53/UDP (0)          0.0.0.0:0 (2) (0) [ClusterIP, non-routable]
10.43.0.1:443/TCP (0)          0.0.0.0:0 (5) (0) [ClusterIP, non-routable]
192.168.67.202:80/TCP (1)      10.0.2.216:8000/TCP (19) (1)
10.43.146.251:80/TCP (0)       0.0.0.0:0 (13) (0) [ClusterIP, non-routable]
0.0.0.0:80/TCP (1)             10.0.1.163:80/TCP (21) (1)
10.43.0.10:9153/TCP (1)        10.0.0.4:9153/TCP (3) (1)
10.43.0.10:9153/TCP (0)        0.0.0.0:0 (3) (0) [ClusterIP, non-routable]
10.43.0.10:53/UDP (1)          10.0.0.4:53/UDP (2) (1)
0.0.0.0:30135/TCP (0)          0.0.0.0:0 (9) (0) [NodePort, non-routable]
10.43.0.10:53/TCP (1)          10.0.0.4:53/TCP (1) (1)
192.168.67.203:0/ANY (0)       0.0.0.0:0 (0) (0) [LoadBalancer, non-routable]
10.43.174.55:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.148.231:80/TCP (0)       0.0.0.0:0 (7) (0) [ClusterIP, non-routable]
0.0.0.0:443/TCP (0)            0.0.0.0:0 (22) (0) [HostPort, non-routable]
0.0.0.0:31124/TCP (0)          0.0.0.0:0 (11) (0) [NodePort, non-routable]
10.43.66.133:80/TCP (1)        10.0.2.93:80/TCP (23) (1)
10.43.0.1:443/TCP (1)          192.168.67.201:6443/TCP (5) (1)
10.43.73.132:8081/TCP (0)      0.0.0.0:0 (26) (0) [ClusterIP, non-routable]
0.0.0.0:30135/TCP (1)          10.0.2.216:8443/TCP (9) (1)
10.43.99.249:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
192.168.67.202:30135/TCP (1)   10.0.2.216:8443/TCP (10) (1)
10.43.0.1:0/ANY (0)            0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.99.249:443/TCP (1)       10.0.0.61:10250/TCP (4) (1)
10.43.148.231:80/TCP (1)       10.0.0.75:4245/TCP (7) (1)
192.168.67.202:30080/TCP (0)   0.0.0.0:0 (25) (0) [NodePort]
0.0.0.0:30080/TCP (1)          10.0.0.17:8081/TCP (24) (1)
0.0.0.0:30080/TCP (0)          0.0.0.0:0 (24) (0) [NodePort, non-routable]
192.168.67.202:443/TCP (1)     10.0.2.216:8443/TCP (20) (1)
10.43.0.10:53/TCP (0)          0.0.0.0:0 (1) (0) [ClusterIP, non-routable]
192.168.67.201:443/TCP (1)     10.0.2.216:8443/TCP (18) (1)
192.168.67.201:0/ANY (0)       0.0.0.0:0 (0) (0) [LoadBalancer, non-routable]
10.43.0.10:0/ANY (0)           0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
```