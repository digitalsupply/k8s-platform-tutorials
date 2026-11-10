# 02 · Cilium / eBPF：看懂 BPF 数据面

## 当时的情况

案例集群使用 **Cilium 1.20.4**，数据面是 eBPF + VXLAN，IPAM 使用
`cluster-pool`。排查 Service 不通、NodePort 异常、Pod 间访问不一致时，
需要直接读 Cilium 的 BPF 表，而不是只看 Kubernetes 的 Service/Endpoint。

当时的核心疑问：

- `cilium-dbg bpf lb list` 里 `0.0.0.0`、SLOT 0/1、REVNAT 是什么意思？
- 为什么同一个 Service 的条目不是连续的？
- NodePort 为什么会出现两条 REVNAT？
- `bpf ipcache list` 里的 identity、tunnelendpoint、flags 怎么解释？
- 如何用 Hubble / tcpdump 验证一个请求到底走了哪条路径？

## 主要概念与原理

### 1. eBPF 的四个核心

| 概念 | 作用 |
|---|---|
| Program | 挂到内核钩子（XDP、TC、kprobe、tracepoint 等）上执行的程序 |
| Map | 内核与用户态共享的键值存储，BPF 表就是 Map |
| Hook | 程序被触发的时机/位置 |
| Helper | 内核提供给 BPF 程序的函数 |

Cilium 的 LB、ipcache、identity、conntrack 等都是 BPF Map。

### 2. Cilium 数据面的几张关键表

- **LB map**：Service VIP/端口 → 后端 Pod；
- **ipcache**：IP → identity / tunnel endpoint / flags；
- **identity**：标签集合的数值化身份，用于安全策略；
- **nodeid**：节点 ID 与节点 IP 的映射；
- **conntrack**：连接跟踪，决定回包路径。

### 3. SLOT 与 REVNAT

- `SLOT 0`：Service 的“定义”条目（VIP:port → 0.0.0.0 或后端）；
- `SLOT 1..N`：实际后端；
- `REVNAT`：反向 NAT 条目，保证回包正确；
- NodePort 可能同时有“通配入口”和“节点 IP 入口”两个视图，因此出现两条 REVNAT。

### 4. identity 与 tunnelendpoint

- 相同 identity 通常表示同一组标签/同一个 Deployment 的副本；
- `tunnelendpoint=0.0.0.0` 表示本机直投，不走隧道；
- `tunnelendpoint=<节点IP>` 表示走 VXLAN；
- `flags=hastunnel` / `<none>` 可以帮助判断本地/远端。

## 踩坑点

### 坑 1：把 `0.0.0.0` 当成“没有后端”

`0.0.0.0` 是通配入口，不是空后端。判断是否有后端要看 SLOT 1..N。

### 坑 2：条目按 Service 连续排列

BPF hash map 不保证顺序；同一个 Service 的 SLOT 可能分散。
不要用“相邻行”推断归属。

### 坑 3：NodePort 只有一条 REVNAT

NodePort 可能有“通配 + 节点 IP”两个入口视图，REVNAT 可能是两条。
看到两条不要误判为重复配置。

### 坑 4：`kubectl exec ds/cilium` 随机节点

不同节点的 LB/ipcache 表不同。必须指定 `spec.nodeName`，否则结论不可复现。

### 坑 5：只看 Service/Endpoint，不看 BPF 表

Kubernetes 对象正常不代表数据面正常；VIP→Pod 的映射在 BPF map 里。
要用 `bpf lb list` + `ipcache` 交叉验证。

## 修复关键 / 排查方法

1. 先确认节点，拿到该节点的 Cilium Pod；
2. `cilium-dbg bpf lb list` 看 VIP/端口/后端；
3. `cilium-dbg bpf ipcache list` 看 IP→identity/tunnel；
4. `cilium-dbg bpf nodeid list` 看节点映射；
5. 用 `hubble observe` 或 tcpdump 验证实际路径；
6. 对照 Service/Endpoint/Pod 的 IP，确认没有“对象正常、数据面错误”。

## 配套脚本

[`scripts/collect_cilium_bpf.py`](scripts/collect_cilium_bpf.py)

```bash
python3 scripts/collect_cilium_bpf.py --node worker01 --out ./cilium-bpf
```

会采集：

```text
bpf-lb.txt
bpf-ipcache.txt
bpf-nodeid.txt
status.txt
endpoints.txt
k8s-services.txt
k8s-endpoints.txt
k8s-pods.txt
```

脚本会自动找到指定节点的 Cilium Pod，避免 `kubectl exec ds/cilium` 打错节点。

## 文档列表

| 文档 | 内容 |
|---|---|
| [Cilium-EBPF数据面实战教程.md](Cilium-EBPF数据面实战教程.md) | 从 BPF LB/ipcache/nodeid 看数据面全貌 |
| [Cilium-eBPF数据面实战教程-完整版.md](Cilium-eBPF数据面实战教程-完整版.md) | 完整整合版，含更多示例 |
| [PodIP规划与Cilium-eBPF生产安装.md](PodIP规划与Cilium-eBPF生产安装.md) | Pod IP 规划、Cilium 生产安装参数 |
| [cilium-bpf-ipcache解析.md](cilium-bpf-ipcache解析.md) | ipcache 字段、identity、tunnelendpoint |
| [cilium-bpf-lb-analysis.md](cilium-bpf-lb-analysis.md) | BPF LB 输出逐类解析 |
| [cilium-bpf-lb多轮问答汇总.md](cilium-bpf-lb多轮问答汇总.md) | LB 表多轮问答与易错点 |
| [ebpf-四核心概念实战.md](ebpf-四核心概念实战.md) | Program/Map/Hook/Helper 实战 |
| [实验-Hubble-LB-ipcache-tcpdump穿越跟踪.md](实验-Hubble-LB-ipcache-tcpdump穿越跟踪.md) | 用 Hubble/tcpdump 追踪一次请求穿越数据面 |

> 文档中的 BPF 表来自特定节点/版本；不同 Cilium 版本字段可能略有差异。
