# Cilium BPF LB 表输出详解分析

## 一、输出格式说明

```
SERVICE ADDRESS                BACKEND ADDRESS (REVNAT_ID) (SLOT)
  虚拟服务地址(前端)              真实后端地址    (反向NAT ID)  (槽位号)
```

| 字段 | 含义 |
|------|------|
| SERVICE ADDRESS | Kubernetes Service 的虚拟 IP（ClusterIP/NodePort/LoadBalancer）+ 端口/协议 |
| BACKEND ADDRESS | 后端 Pod 的真实 IP + 端口/协议 |
| REVNAT_ID | 反向 NAT 编号，**相同 REVNAT_ID 的条目属于同一个 Service** |
| SLOT | **0 = 前端入口（Service 定义）**，**1+ = 后端 Pod（实际转发目标）** |
| `[标签]` | Service 类型注解，如 ClusterIP、NodePort、LoadBalancer、HostPort、non-routable |

---

## 二、机器/节点识别

输出中有 **3 个节点 IP**（作为 Service 的外部地址出现）：

```
192.168.67.201  ← 节点1 (同时运行 kube-apiserver:6443)
192.168.67.202  ← 节点2 (当前 BPF 表所在节点，本机)
192.168.67.203  ← 节点3
```

**如何判断当前输出来自哪台机器？**

看 NodePort 和 HostPort 的 `0.0.0.0` 条目——这些是本机监听的：

```
0.0.0.0:30135/TCP (0)   [NodePort, non-routable]    ← 本机监听
0.0.0.0:30080/TCP (0)   [NodePort, non-routable]    ← 本机监听
0.0.0.0:80/TCP (0)      [HostPort, non-routable]    ← 本机监听
0.0.0.0:443/TCP (0)     [HostPort, non-routable]    ← 本机监听
```

同时看各节点的 NodePort 后端都有条目，说明这是 **Cilium kube-proxy replacement 模式**下，每台节点都维护完整的 Service 映射表。

---

## 三、分类详解（附输出示例）

### 类别 1：ClusterIP Service

**特征：** 只有集群内部可访问，标签含 `ClusterIP, non-routable`

#### 示例 A：简单 ClusterIP → 单 Pod

```
REVNAT_ID=5
10.43.0.1:443/TCP (0)          0.0.0.0:0 (5) (0) [ClusterIP, non-routable]   ← 前端(SLOT=0)
10.43.0.1:443/TCP (1)          192.168.67.201:6443/TCP (5) (1)                ← 后端(SLOT=1)
```

> **解读：** Service `10.43.0.1:443` 是 `kubernetes` Service（apiserver），流量转发到 `192.168.67.201:6443`（节点1上的 kube-apiserver）

#### 示例 B：ClusterIP → 多 Pod（负载均衡）

```
REVNAT_ID=27
10.43.162.164:80/TCP (0)       0.0.0.0:0 (27) (0) [ClusterIP, non-routable]  ← 前端
10.43.162.164:80/TCP (1)       10.0.1.123:80/TCP (27) (1)                    ← 后端 Pod 1
10.43.162.164:80/TCP (2)       10.0.2.178:80/TCP (27) (2)                    ← 后端 Pod 2
```

> **解读：** Service `10.43.162.164:80` 有 2 个后端 Pod（10.0.1.123 和 10.0.2.178），**轮询负载均衡**

#### 示例 C：ClusterIP 无后端（Endpoints 为空）

```
10.43.66.133:0/ANY (0)         0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.148.231:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
10.43.162.164:0/ANY (0)        0.0.0.0:0 (0) (0) [ClusterIP, non-routable]
```

> **解读：** 端口为 `0/ANY`，无后端 Pod → **headless Service 或 Endpoints 为空** 的 Service

---

### 类别 2：NodePort Service

**特征：** 通过 `<任意节点IP>:NodePort` 访问，标签含 `NodePort`

```
REVNAT_ID=9
0.0.0.0:30135/TCP (0)          0.0.0.0:0 (9) (0) [NodePort, non-routable]         ← 前端
0.0.0.0:30135/TCP (1)          10.0.2.216:8443/TCP (9) (1)                        ← 后端 Pod
192.168.67.202:30135/TCP (0)   0.0.0.0:0 (10) (0) [NodePort]                     ← 节点2前端
192.168.67.202:30135/TCP (1)   10.0.2.216:8443/TCP (10) (1)                      ← 节点2后端
```

> **解读：** NodePort `30135` 在所有节点上监听，统一转发到 Pod `10.0.2.216:8443`

```
REVNAT_ID=11
0.0.0.0:31124/TCP (0)          0.0.0.0:0 (11) (0) [NodePort, non-routable]
0.0.0.0:31124/TCP (1)          10.0.2.216:8000/TCP (11) (1)
192.168.67.202:31124/TCP (0)   0.0.0.0:0 (12) (0) [NodePort]
192.168.67.202:31124/TCP (1)   10.0.2.216:8000/TCP (12) (1)
```

> **解读：** NodePort `31124` → Pod `10.0.2.216:8000`

---

### 类别 3：LoadBalancer Service

**特征：** 有外部 IP（LoadBalancer IP），标签含 `LoadBalancer`

```
REVNAT_ID=18
192.168.67.201:443/TCP (0)     0.0.0.0:0 (18) (0) [LoadBalancer]                ← 前端
192.168.67.201:443/TCP (1)     10.0.2.216:8443/TCP (18) (1)                     ← 后端
192.168.67.201:0/ANY (0)       0.0.0.0:0 (0) (0) [LoadBalancer, non-routable]   ← headless 条目
```

> **解读：** LoadBalancer IP `192.168.67.201:443` → Pod `10.0.2.216:8443`

```
REVNAT_ID=19
192.168.67.202:80/TCP (0)      0.0.0.0:0 (19) (0) [LoadBalancer]                ← 前端
192.168.67.202:80/TCP (1)      10.0.2.216:8000/TCP (19) (1)                     ← 后端
```

> **解读：** LoadBalancer IP `192.168.67.202:80` → Pod `10.0.2.216:8000`

**所有 LoadBalancer Service 汇总：**

| LoadBalancer IP | 端口 | 后端 Pod |
|----------------|------|---------|
| 192.168.67.201 | 443 | 10.0.2.216:8443 |
| 192.168.67.201 | 80 | 10.0.2.216:8000 |
| 192.168.67.202 | 443 | 10.0.2.216:8443 |
| 192.168.67.202 | 80 | 10.0.2.216:8000 |
| 192.168.67.203 | 443 | 10.0.2.216:8443 |
| 192.168.67.203 | 80 | 10.0.2.216:8000 |

> **分析：** 3 个节点都有 LoadBalancer IP，说明使用了 **BGP 或 MetalLB** 模式，每个节点都在宣告这些外部 IP

---

### 类别 4：HostPort Service

**特征：** 绑定到节点宿主机端口，标签含 `HostPort`

```
REVNAT_ID=21
0.0.0.0:80/TCP (0)             0.0.0.0:0 (21) (0) [HostPort, non-routable]     ← 前端
0.0.0.0:80/TCP (1)             10.0.1.163:80/TCP (21) (1)                       ← 后端

REVNAT_ID=22
0.0.0.0:443/TCP (0)            0.0.0.0:0 (22) (0) [HostPort, non-routable]     ← 前端
0.0.0.0:443/TCP (1)            10.0.1.163:443/TCP (22) (1)                      ← 后端
```

> **解读：** Cilium Agent 或 kube-proxy 的 HostPort 功能，将节点的 80/443 端口直接映射到 Pod `10.0.1.163`

---

### 类别 5：DNS Service（kube-dns）

**特征：** 专用 DNS ClusterIP `10.43.0.10`

```
REVNAT_ID=1
10.43.0.10:53/TCP (0)          0.0.0.0:0 (1) (0) [ClusterIP, non-routable]
10.43.0.10:53/TCP (1)          10.0.0.4:53/TCP (1) (1)

REVNAT_ID=2
10.43.0.10:53/UDP (0)          0.0.0.0:0 (2) (0) [ClusterIP, non-routable]
10.43.0.10:53/UDP (1)          10.0.0.4:53/UDP (2) (1)

REVNAT_ID=3
10.43.0.10:9153/TCP (0)        0.0.0.0:0 (3) (0) [ClusterIP, non-routable]
10.43.0.10:9153/TCP (1)        10.0.0.4:9153/TCP (3) (1)
```

> **解读：** kube-dns Pod 运行在 `10.0.0.4`，提供 TCP/UDP 53（DNS）和 TCP 9153（metrics）

---

## 四、后端 Pod 所在节点推断

根据 Pod CIDR 模式 `10.0.X.Y`，可以推断 Pod 分布：

| Pod IP | 推测节点 | 运行的服务 |
|--------|---------|-----------|
| 10.0.0.4 | 节点1 (10.0.0.0/24) | kube-dns |
| 10.0.0.17 | 节点1 | 某应用服务 (端口 8081) |
| 10.0.0.61 | 节点1 | kubelet (10250) |
| 10.0.0.75 | 节点1 | 某代理服务 (端口 4245) |
| 10.0.1.123 | 节点2 (10.0.1.0/24) | Web 服务 (端口 80) |
| 10.0.1.137 | 节点2 | Web 服务 (端口 80) |
| 10.0.1.163 | 节点2 | HostPort 服务 (端口 80/443) |
| 10.0.2.93 | 节点3 (10.0.2.0/24) | Web 服务 (端口 80) |
| 10.0.2.178 | 节点3 | Web 服务 (端口 80) |
| **10.0.2.216** | **节点3** | **最繁忙的 Pod (端口 8000/8443)** |

> **10.0.2.216** 是后端出现频率最高的 Pod，承载了几乎所有 LoadBalancer 和 NodePort 流量

---

## 五、核心规则总结

| 规则 | 说明 |
|------|------|
| **SLOT=0** | Service 前端入口（虚拟 IP 定义），`0.0.0.0:0` 表示仅作占位 |
| **SLOT=1+** | 实际后端 Pod，**这才是流量真正转发到的地方** |
| **相同 REVNAT_ID** | 属于同一个 Service 的前后端配对 |
| **`non-routable`** | 仅限集群内部路由，不可从外部访问 |
| **`0.0.0.0:端口`** | 本机监听的入口（NodePort/HostPort） |
| **`192.168.67.20X:端口`** | 特定节点 IP 绑定的入口 |
