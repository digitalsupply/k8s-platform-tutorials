# kube-proxy / Service / iptables 三者关系与工作机制

本文所有规则均来自本集群（Kubernetes v1.35.9，kube-proxy mode=iptables）的真实 `iptables-save` 输出。

---

## 一、一句话概括

**Service 是一个纯抽象（IP + 端口 + 标签选择器），它本身不转发任何流量。kube-proxy 是翻译官，把 Service 抽象翻译成节点上的 iptables 规则；iptables 是真正干活的转发引擎。**

```
Service 对象          →  抽象定义，存在 etcd 里，不参与任何转发
kube-proxy           →  控制器（DaemonSet），持续 watch API Server 并写规则
iptables/netfilter   →  内核态规则，真正完成 DNAT/负载均衡
```

数据流：

```
Pod(应用) 发起请求
    ↓
目标 IP = Service ClusterIP (虚拟 IP，Pod 内不持有)
    ↓
内核 netfilter PREROUTING/OUTPUT 钩子
    ↓
KUBE-SERVICES 链（kube-proxy 生成的入口规则）
    ↓
KUBE-SVC-xxx 链（Service 级，负载均衡点）
    ↓
KUBE-SEP-xxx 链（Endpoint 级，最终 DNAT）
    ↓
真实 Pod IP:targetPort
```

---

## 二、三者的分工

### 2.1 Service：只做定义，不转发

本集群实例：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
spec:
  type: LoadBalancer
  clusterIP: 10.111.240.160      # 虚拟 IP，任意节点都能"接收"
  externalIPs:                    # LoadBalancer 分配的实际入口 IP
    - 10.0.0.252
  selector:
    app.kubernetes.io/name: traefik       # ← 用标签找 Pod
  ports:
    - name: web
      port: 80                          # Service 端口
      targetPort: web                   # 容器端口（8000）
      nodePort: 30156                   # 节点端口
```

Service 提供三种访问入口，**全部是虚拟 IP**：

| 入口 | 地址 | 谁在处理 |
|---|---|---|
| ClusterIP | 10.111.240.160 | KUBE-SVC 链 |
| NodePort | 10.244.x.x:30156 | KUBE-SERVICES 直接匹配端口 |
| LoadBalancer IP | 10.0.0.252 | KUBE-EXT 链 |

### 2.2 kube-proxy：watch + 写规则

kube-proxy 是 DaemonSet，每个节点一个。它做两件事：

1. **watch**：监听 Service / EndpointSlice 变化
   - Service 创建/删除 → 增删 KUBE-SVC 链
   - Pod 扩缩容 → 增删 KUBE-SEP 链

2. **sync**：周期性全量对账（iptables 模式下 `syncPeriod` 默认 30s，最小 1s）

**关键特性**：kube-proxy 是**节点本地的、最终一致的**。它不是数据面，只负责生成规则。

### 2.3 iptables：真正转发

内核模块，根据 netfilter 规则做地址转换。kube-proxy 消失但规则还在，转发依然工作（直到重启节点清空规则）。

---

## 三、完整实例：访问 traefik

### 3.1 背景

```bash
$ kubectl get svc traefik -n traefik -o wide
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
traefik   LoadBalancer   10.111.240.160  10.0.0.252   80:30156/TCP,443:30306/TCP

$ kubectl get endpoints traefik -n traefik -o wide
NAME      ENDPOINTS                          AGE
traefik   10.244.5.94:8000,10.244.5.94:8443   5d21h
```

Pod 实际运行在 worker01（10.244.5.94），但**任意节点**都能访问 ClusterIP。

### 3.2 第一层：KUBE-SERVICES（总入口）

```
-A KUBE-SERVICES -d 10.111.240.160/32 -p tcp \
   --comment "traefik/traefik:web cluster IP" \
   -j KUBE-SVC-UIRTXPNS5NKAPNTY
```

这条挂在 OUTPUT 钩子上（本机发起）：
```
-A OUTPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
```

注意：**匹配的是目的 IP 和端口，不区分源**。所以任意节点上的 Pod 访问 10.111.240.160:80 都会命中。

### 3.3 第二层：KUBE-SVC（Service 级）

```
-A KUBE-SVC-UIRTXPNS5NKAPNTY \
   -m comment --comment "traefik/traefik:web -> 10.244.5.94:8000" \
   -j KUBE-SEP-VB3G2HMZICJNEBN7
```

**只读**，不匹配任何地址条件，纯粹是「跳转到负载均衡点」。

单后端时 KUBE-SVC 通常还带一条 masquerade：
```
-A KUBE-SVC-UNIYKJZDB246XYVX ! -s 10.244.0.0/16 -d 10.110.55.55/32 -p tcp \
   -m comment --comment "...postgres cluster IP" -j KUBE-MARK-MASQ
```
含义：源地址**不在 Pod 网段**（比如从 PVE 宿主机访问）时强制 SNAT。

### 3.4 第三层：KUBE-SEP（最终 DNAT）

```
-A KUBE-SEP-VB3G2HMZICJNEBN7 -s 10.244.5.94/32 \
   -m comment --comment "traefik/traefik:web" -j KUBE-MARK-MASQ
-A KUBE-SEP-VB3G2HMZICJNEBN7 -p tcp \
   -m comment --comment "traefik/traefik:web" \
   -m tcp -j DNAT --to-destination 10.244.5.94:8000
```

**这是唯一真正改变包目的地的地方**：目的地址从 `10.111.240.160:80` 改成 `10.244.5.94:8000`。

第二条的 `-p tcp` 没有 `-d` 限定——因为已经从 KUBE-SVC 进来的包，目的地址必然匹配。

### 3.5 完整链路

```
Pod A 发出: dst=10.111.240.160:80
    ↓
[OUTPUT] → KUBE-SERVICES
    ↓ 匹配 dst=10.111.240.160/32 tcp
KUBE-SVC-UIRTXPNS5NKAPNTY
    ↓
KUBE-SEP-VB3G2HMZICJNEBN7
    ↓
DNAT → dst=10.244.5.94:8000
    ↓
路由到 worker01 → calico veth → Pod
```

---

## 四、负载均衡：看多后端例子

单后端看不出均衡。用 `pg16-ceph-r`（2 个 endpoint）：

```bash
$ kubectl get endpoints -n cnpg-system pg16-ceph-r
10.244.30.173:5432,10.244.5.82:5432
```

对应的 KUBE-SVC 链：

```
-A KUBE-SVC-UNIYKJZDB246XYVX ! -s 10.244.0.0/16 -d 10.110.55.55/32 -p tcp \
    -m comment --comment "cnpg-system/pg16-ceph-r:postgres cluster IP" \
    -j KUBE-MARK-MASQ

-A KUBE-SVC-UNIYKJZDB246XYVX \
    -m comment --comment "...postgres -> 10.244.30.173:5432" \
    -m statistic --mode random --probability 0.50000000000 \
    -j KUBE-SEP-AX3ETT474C356WD3

-A KUBE-SVC-UNIYKJZDB246XYVX \
    -m comment --comment "...postgres -> 10.244.5.82:5432" \
    -j KUBE-SEP-NXOTDSTQW5IPSEPX
```

**关键机制：`--mode random --probability`** ——内核在第一个包上做**随机抽样**，命中 50% 概率就转到第一个后端，否则继续往下匹配。

### 4.1 这是「每连接」均衡，不是「每包」

netfilter 随机模式的概率判定基于 conntrack。**一个 TCP 连接的所有包走同一条路径**（因为连接建立时已确定 DNAT 目标，后续包命中 conntrack 表直接转发）。

所以：
- 1000 个连接 → 约 500 / 500 分布
- 单个长连接 → 全部包都到同一个 Pod

**这是有意的设计**。如果按包随机，一个 TCP 包走 A、下一个走 B，连接就断了。

### 4.2 N 个后端时概率怎么算

`0.5` 是第一条规则，第二条是「兜底」（无 probability 条件）。规律：

| 后端数 | 第1条 | 第2条 | 第3条 | 第4条 |
|---|---|---|---|---|
| 1 | 无 condition（100%）| | | |
| 2 | 0.500 | 无 condition | | |
| 3 | 0.333 | 0.500 | 无 condition | |
| 4 | 0.250 | 0.333 | 0.500 | 无 condition |

即第 i 条概率 = `1/(剩余后端数)`，最后一条不写 probability（100% 兜底）。

---

## 五、NodePort 和 LoadBalancer 的处理

### 5.1 NodePort

每个节点在 30000-32767 范围内开放一个端口，流量从**任意节点**的该端口进来都能转到后端 Pod。

```
-A KUBE-SERVICES -d 10.110.30.61/32 -p tcp \
   --comment "cicd/tekton-demo-listener-nodeport cluster IP" \
   -j KUBE-SVC-P2M5IU5KRFD7NLYW
```

### 5.2 LoadBalancer IP（本集群的 Traefik）

```
-A KUBE-SERVICES -d 10.0.0.252/32 -p tcp \
   --comment "traefik/traefik:web loadbalancer IP" \
   -j KUBE-EXT-UIRTXPNS5NKAPNTY
```

KUBE-EXT 链内容：
```
-A KUBE-EXT-LODJXQNF3DWSNB7B \
   -m comment --comment "masquerade traffic for traefik/traefik:websecure external destinations" \
   -j KUBE-MARK-MASQ
-A KUBE-EXT-LODJXQNF3DWSNB7B -j KUBE-SVC-LODJXQNF3DWSNB7B
```

**KUBE-EXT 比 KUBE-SVC 多一条强制 masquerade**：外部流量进入节点后，源地址不是 Pod IP，需要 SNAT 成节点 IP 才能回包。

---

## 六、KUBE-FIREWALL：ClusterIP 的保护

```
-A INPUT -j KUBE-FIREWALL
-A OUTPUT -j KUBE-FIREWALL

-A KUBE-FIREWALL ! -s 127.0.0.0/8 -d 127.0.0.0/8 \
    -m comment --comment "block incoming localnet connections" \
    -m conntrack ! --ctstate RELATED,ESTABLISHED,DNAT -j DROP
```

含义：目的地址是 `127.0.0.0/8`（localhost）的包，如果源**不是** 127.0.0.0/8 也不属于已有连接，直接 DROP。

**这是防伪造攻击** —— 防止外部构造「源 IP 是 127.0.0.1」的包，绕过认证访问 kubelet 的只读端口(10255)。

---

## 七、完整规则规模

本集群实测：

```
KUBE-SVC 规则:  583 条
KUBE-SEP 规则:  644 条
Service 数量:   108
```

Service(108) < SVC(583) 是因为：
- 一个 Service 多端口 → 多个 KUBE-SVC
- LoadBalancer 类型 → ClusterIP 和 LB IP 各一条

SEP(644) > SVC(583) 是因为多后端 Service 每个 Pod 一条 SEP。

---

## 八、和 IPVS 模式的对比

本集群**曾经是 IPVS**，现已迁移到 iptables。

### 8.1 IPVS 模式的工作方式

IPVS 是内核里的**四层负载均衡器**，需要：
- `ip_vs` 内核模块
- `ipvsadm` 管理工具
- 独立的规则表（`ipvsadm -Ln` 查看）

```
IPVS 模式:  ClusterIP → ipvsadm 表(虚拟服务/真实服务器) → DNAT
iptables 模式: ClusterIP → KUBE-SVC 链 → KUBE-SEP 链 → DNAT
```

### 8.2 对比

| 维度 | iptables | IPVS |
|---|---|---|
| 实现 | netfilter 链遍历 | 内核专用模块 |
| 性能 | 链多时线性遍历（慢） | 哈希表查找（快） |
| 规则规模上限 | 受限（UDP/端口有硬限制） | 大规模场景无压力 |
| 依赖 | 内核自带 | 需 `ip_vs` 模块 + `ipvsadm` |
| 排障 | `iptables-save` 直接看 | `ipvsadm -Ln` |
| 云厂商支持 | 普遍 | 部分已弃用 |

### 8.3 本集群为什么迁到 iptables

1. Service 数 108、规则 600 量级，性能完全够用
2. IPVS 模式在某些内核版本 + kube-proxy 新版本组合下有兼容问题
3. 少一个依赖（`ipvsadm` 服务和 `ip_vs` 配置）
4. 社区主流方向是 iptables（nftables 是更下一代）

**验证方式**（本次实际做的）：
```bash
# 1. 配置层
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode:
#   mode: iptables

# 2. 运行时日志（最权威，kube-proxy 自己打印）
kubectl -n kube-system logs ds/kube-proxy | grep "Using.*proxier"
#   Using iptables Proxier

# 3. 节点上真实规则
ipvsadm -Ln | grep -cE '^(TCP|UDP) '    # 应为 0
iptables-save -t nat | grep -c KUBE-SVC  # 应为 583
```

---

## 九、常见误区

### 误区 1：Service 有个「虚拟网卡」

**没有。** ClusterIP 是纯粹的 iptables 匹配条件，不绑定任何网卡。任何节点都能「接收」这个 IP，因为它只是匹配规则，不是真的地址。

### 误区 2：Pod 里能 ping 通 ClusterIP

**通常不能。** ClusterIP 不是真实地址，只有经过 kube-proxy 规则转换的流量才能命中。`ping` 走 ICMP，而 KUBE-SVC 链只匹配 tcp/udp/sctp。

验证：本集群 `busybox` ping ClusterIP 无响应，但 `wget http://kube-dns.kube-system.svc:9153/metrics` 正常返回 352 行。

### 误区 3：kube-proxy 挂了 Service 就断

**不会立刻断。** kube-proxy 只是控制器，已有规则留在内核里继续工作。真正的影响是：
- 现有流量继续
- **新 Service / Pod 扩缩容不再生效**（直到 sync 恢复）

这正是 kube-proxy 故障时的典型症状：老服务正常，新服务不通。

### 误区 4：headless Service（clusterIP: None）也走 kube-proxy

**不走。** headless Service 直接返回 Pod IP 列表（DNS 层面做负载均衡），kube-proxy 不生成规则。本集群的 Knative activator-service 等就是这类。

### 误区 5：ExternalIP 和 LoadBalancer IP 是一回事

不同。ExternalIP 是用户手动在 Service 里写的；LoadBalancer IP 是控制器（如 metallb）通过 status.loadBalancer.ingress 分配的。本集群 Traefik 的 10.0.0.252 是 LoadBalancer 类型。

---

## 十、常用排查命令

```bash
# 看某个 Service 的完整规则链路
SVCIP=$(kubectl get svc <name> -n <ns> -o jsonpath='{.spec.clusterIP}')
iptables-save -t nat | grep -A5 "$SVCIP"

# 看所有 KUBE-SVC（按注释里的 ns/name 过滤）
iptables-save -t nat | grep 'KUBE-SERVICES' | grep '<ns>/<name>'

# 看某个 Pod IP 相关的所有规则
iptables-save -t nat | grep '<pod-ip>'

# 统计规则规模
iptables-save -t nat | grep -c KUBE-SVC
iptables-save -t nat | grep -c KUBE-SEP

# 确认 kube-proxy 模式（三方交叉验证）
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode:
kubectl -n kube-system logs ds/kube-proxy | grep "Using.*proxier"
ipvsadm -Ln 2>/dev/null | grep -cE '^(TCP|UDP) '

# 追踪某个连接实际走了哪条链
conntrack -L 2>/dev/null | grep <clusterIP>
# 或临时在 KUBE-SERVICES 链加 TRACE
iptables -t nat -I KUBE-SERVICES 1 -j TRACE
```

---

## 十一、总结

| 问题 | 答案 |
|---|---|
| Service 转发流量吗 | 不转发，只是 IP + 端口 + selector 的抽象定义 |
| 谁在转发 | iptables（内核态）|
| kube-proxy 是什么 | 控制器：watch API → 生成 iptables 规则，不在数据面 |
| kube-proxy 挂了的症状 | 老服务正常，新 Service / Pod 扩缩容不生效 |
| 负载均衡怎么做的 | iptables `--mode random --probability`，基于 conntrack 实现**每连接**均衡 |
| Service IP 为什么哪都能访问 | 不是真实地址，是每台节点的 iptables 匹配条件 |
| 本集群为什么用 iptables | 规则量 600 级性能够用，减少依赖，社区主流 |