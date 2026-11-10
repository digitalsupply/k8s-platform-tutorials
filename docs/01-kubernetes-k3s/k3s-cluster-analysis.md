# k3s 集群进程与 Pod 全面分析

> 基于本机（ubuntu01，控制平面）实测：`ps aux`、`crictl`、cgroup、`kubectl`、`witr` 多工具交叉分析。
> 集群：3 节点 k3s v1.36.4+k3s1，containerd 2.3.4，Ubuntu 24.04，Cilium CNI + Hubble。

---

## 1. ps aux 输出详解

`ps aux` 是查看所有进程（BSD 风格）的常用命令，输出各列含义：

| 列名 | 含义 |
|------|------|
| **USER** | 进程所属用户 |
| **PID** | 进程 ID |
| **%CPU** | CPU 使用率（占单个核的百分比，多核最多可达 100%×核数） |
| **%MEM** | 内存使用率（RSS / 物理内存总量） |
| **VSZ** | 虚拟内存大小（KB），进程申请的全部虚拟地址空间 |
| **RSS** | 常驻内存大小（KB），实际占用的物理内存 |
| **TTY** | 进程关联的终端，`?` 表示无终端（如守护进程） |
| **STAT** | 进程状态，见下方详解 |
| **START** | 启动时间 |
| **TIME** | 累计消耗 CPU 时间 |
| **COMMAND** | 命令行/程序路径 |

### STAT 状态码详解（主字符 + 修饰符组合）

主状态：

- `R` running，正在运行/可运行
- `S` sleeping，可中断睡眠（等待事件）
- `D` device I/O，不可中断睡眠（通常在磁盘 I/O）
- `T` stopped，被暂停（如 Ctrl+Z）
- `Z` zombie，僵尸进程（已结束但未被父进程回收）

修饰符（跟在主字符后）：

- `<` 高优先级
- `N` 低优先级（nice）
- `L` 有页面锁定在内存
- `s` session leader（会话首进程）
- `l` 多线程
- `+` 位于前台进程组

例子：`Ss` = 会话首进程且可中断睡眠；`R+` = 前台正在运行；`Z` = 僵尸。

### 易混点

- VSZ 一般 ≥ RSS，因为虚拟地址包含未实际分配的部分（如共享库、mmap）
- 多个进程可能共享同一物理内存，所以 RSS 之和会偏大
- `aux` 实际上等于 `-aux`（BSD 风格），`x` 才包含无终端进程；`a` 表示所有用户的进程

---

## 2. 本机 ps aux 实测解读（ubuntu01）

### 总体印象

本机是 k3s 集群**控制平面节点**，运行 systemd + k3s server + containerd + Cilium 全家桶 + 大量容器。

### 重点进程

| 进程 | PID | 说明 |
|----|----|----|
| `/sbin/init` | 1 | systemd，`Ss`=会话首进程、可中断睡眠 |
| `tailscaled` | 789 | Tailscale VPN，TIME 47:06，占 1.7% CPU |
| `k3s server` | 861 | 本机最重进程：TIME 228:24，RSS ≈745MB（18.8% → 反推内存约 4GB） |
| `opencode` | 37364 | VSZ ≈70GB（mmap 假象），RSS 仅 738MB |
| `/pause` | ×8 | k8s 每 Pod 一个的沙箱容器，USER=65535(nobody)，只占 ~700KB |
| 大量 `[kworker/...]` | — | 内核线程，VSZ/RSS 均为 0 |

### 本机 STAT 实例

| 值 | 含义 |
|----|------|
| `Ss` / `Ssl` / `SLsl` | 可中断睡眠 + 首进程[+多线程]；multipathd 带 `L`（页面锁定） |
| `R+` / `Rs` | 正在运行的进程（`ps aux` 自身 `Rs`，`+` 表示前台） |
| `I` / `I<` / `SN` | 空闲内核线程；`<` 高优先级，`N` 低优先级（ksmd=内存去重） |
| `Ss+` / `S+` | 前台会话进程（tmux、bash、sudo、opencode） |

### 内核线程的特征（带中括号的 COMMAND）

`ps` 的大括号 `[...]` 表示**内核线程（kernel thread）**，不带括号的是普通用户态进程：

| | 带括号 `[...]` | 不带括号 |
|---|---|---|
| 归属 | 内核线程（kthreadd 派生的） | 用户态进程/程序 |
| 所有者 | 永远显示 root | 真实用户 |
| VSZ/RSS | 都是 0（不占用户态内存） | 有实际数值 |
| 是否可 kill | `kill` 无效 | 可正常 kill |

**注意**：容器进程（如 `/pause`、`nginx: worker process`）也显示成普通可执行文件，括号与否只区分"内核态/用户态"，不区分"宿主/容器"。

---

## 3. 集群全景（kubectl 视角）

### 拓扑

| 节点 | 角色 | IP | CPU/Mem | 承载 |
|----|----|----|----|----|
| ubuntu01 | control-plane | 192.168.67.201 | 2C / 3.9Gi | 控制面 + 几乎所有系统 Pod（**内存 74%** 最满） |
| ubuntu02 | worker | 192.168.67.202 | 2C / 3.9Gi | cilium/envoy/svclb + lab 一半 |
| ubuntu03 | worker | 192.168.67.203 | 2C / 3.9Gi | traefik、nginx、svclb + lab 一半 |

- Pod CIDR 每节点 **10.0.{节点序号}.0/24**（01→10.0.0.x、02→10.0.1.x、03→10.0.2.x）
- 负载：ubuntu01 内存 74% / CPU 12%，02 与 03 约 28%/5%

### 全部 25 个 Pod 归类

**① DaemonSet（每节点一个，各 3 个）**

- `cilium-*`（3）：CNI 数据面，hostNetwork（IP=节点 192.168.67.20x）
- `cilium-envoy-*`（3）：cilium 的 envoy 代理（HostPolicy + L7）
- `svclb-traefik-*`（3）：k3s 服务 LB，每 Pod 2 容器（lb-tcp-80 / lb-tcp-443）

**② Deployment —— 系统组件（除 operator 外均单副本且全在 ubuntu01）**

- `cilium-operator` 2 副本（01+02）：唯一做 HA 的组件
- `coredns`、`hubble-relay`、`hubble-ui`(2 容器: nginx+backend)、`local-path-provisioner`、`metrics-server`：各 1 副本

**③ 流量入口**

- `traefik`（1 副本 @ubuntu03）：svc `traefik` LoadBalancer 三节点 IP 全暴露，NodePort 80:31124 / 443:30135
- `helm-install-traefik-*` ×2：11 天前一次性安装 Job，Completed

**④ 业务工作负载（lab，9d）**

- `web` ×2（02+03）：跨节点双副本
- `api` ×1（02）：ClusterIP 仅集群内可访问
- `test` ×1（02）：定时压测型（见异常）

**⑤ default 命名空间**

- `nginx` ×1（03）：ClusterIP svc
- `curl` ×1（03）：定时调试型（见异常）

### 异常与建议

1. **控制面内存 74%、CPU 12%**：系统 Pod 全挤在 ubuntu01。建议 coredns/traefik 多副本 + `topologySpreadConstraints` 分散。
2. **`curl`(211 重启) / `test`(238 重启)**：**不是故障**，lastState 显示 exitCode=0、reason=Completed，约 1 小时跑完一次因 `restartPolicy: Always` 被拉起。建议改 CronJob 或 `restartPolicy: OnFailure`。
3. **手风琴式依赖**：svclb-traefik(DaemonSet) → traefik(单副本@03)，后者挂则入口瘫痪，建议 ≥2 副本。
4. **coredns 单副本在控制面**：DNS 单点风险，建议 ≥2。
5. **api/web 全是 ClusterIP 未被 Ingress 暴露**：外部访问规则未配置。

---

## 4. 容器进程分析（crictl + cgroup）

### 本机运行中容器 → 进程映射（kube-system）

| PID | 容器内用户 | 进程 | 所在 Pod | 容器 |
|----|----|----|----|----|
| 1695 | root | `cilium-agent` | cilium-q5jp6 | cilium-agent |
| 1927 | root | `cilium-health-responder` | cilium-q5jp6 | cilium-agent 子进程 |
| 1431 | root | `cilium-envoy` | cilium-envoy-v26ns | cilium-envoy |
| 15282 | root | `cilium-operator-generic` | cilium-operator-… | cilium-operator |
| 2453 | 65532 | `/coredns` | coredns-… | coredns |
| 2466 | 65532 | `hubble-relay` | hubble-relay-… | hubble-relay |
| 2399 | hao | `metrics-server` | metrics-server-… | metrics-server |
| 2364 | root | `local-path-provisioner` | local-path… | local-path-provisioner |
| 2426 | 1001 | `nginx: master` | hubble-ui-… | frontend |
| 2631/2632 | 1001 | `nginx: worker` | hubble-ui-… | frontend |
| 2551 | 1001 | `/usr/bin/backend` | hubble-ui-… | backend |
| 2497 | root | `/bin/sh /usr/bin/entry` | svclb-traefik-… | lb-tcp-80 |
| 2572 | root | `/bin/sh /usr/bin/entry` | svclb-traefik-… | lb-tcp-443 |

每个 Pod 还带一个 `/pause`（USER=65535 nobody）。

### Kubernetes 机制解读

1. **pause 容器 = Pod 沙箱**：专门持有网络命名空间供同 Pod 容器共享，行为就是挂住。
2. **init 容器已完成**：cilium-agent 里 `install-cni-binaries`、`mount-bpf-fs`、`mount-cgroup`、`apply-sysctl-overwrites`、`clean-cilium-state`、`config` 全部 Exited——初始化完成后退出。
3. **真实子进程**：`cilium-health-responder`(1927) 的 PPID 是 `cilium-agent`(1695)，容器内程序自行 fork。

### USER 列玄机（UID 不隔离）

- **root**：cilium 系与 LB 容器因需要 CAP/挂载 BPF 以 root 跑
- **1001**：hubble-ui 容器内 UID 映射到宿主同名用户
- **65535 / 65532**：nobody 体系（pause/coredns/hubble-relay），宿主无此 uid 显示纯数字
- **hao**：metrics-server 容器 UID 恰为宿主 `hao` 的 uid，ps 直接显示用户名 → 容器用户隔离弱，靠 namespace/seccomp/capabilities 而非 UID

### Exited 存量 = 集群升级痕迹

9 天前（ATTEMPT 1）和 11 天前（ATTEMPT 0，helm）的整套旧容器以 Exited 保留：同一批 Pod（coredns/hubble/cilium/metrics…）的上一版本实例。**约 46 小时前集群完成过一次整体更新（attempt 1→2）**。

### 根文件系统与运行时

- 每个容器根文件系统为 overlay 挂载，lowerdir=只读镜像层、upperdir=可写层（镜像层可跨容器共享）
- 宿主上 `containerd-shim-runc-v2` 每容器一个 shim 进程（不在 kubepods cgroup），负责生命周期与信号转发

---

## 5. witr 逐进程分析（本机全部容器进程）

`witr` 通过追踪进程父链解释"为什么这个进程/端口在运行"。

### 父链铁律

所有容器进程：`systemd(1) → containerd-shim-runc-v2 → 应用进程`，Source=`kubernetes (container)`。
即 k8s 通过 containerd 的 shim 拉起进程——**shim 是容器 PID 1 的直接父进程**（kubelet 只下发配置）。

### 本机各 Pod witr 结果

| Pod | 进程 | 容器 | 用户 | 警告 |
|----|----|----|----|----|
| cilium-q5jp6 | `cilium-agent` 1695 | 32107abec9bb | root | 监听公网接口 / 以 root 运行 |
| cilium-agent 子进程 | `cilium-health-responder` 1927 | 同上 | root | — |
| cilium-envoy-v26ns | `cilium-envoy` 1431 | 9fa56cadd204 | root | — |
| cilium-envoy 启动器 | `cilium-envoy-starter` 1415 | 同上 | root | — |
| cilium-operator | `cilium-operator-generic` 15282 | 67e6c7666b4e | root | — |
| coredns | `/coredns` 2453 | 8f6c3310fc3c | 65532 | 可疑工作目录 `/` |
| hubble-relay | `hubble-relay` 2466 | 864578c02682 | 65532 | — |
| metrics-server | `/metrics-server` 2399 | 9b9f6106e7c9 | hao | — |
| local-path-provisioner | `local-path-prov` 2364 | 1dda05d1d16a | root | — |
| hubble-ui/frontend | `nginx` master 2426 | b38003b4ae5a | 1001 | 可疑工作目录 `/` |
| hubble-ui/backend | `/usr/bin/backend` 2551 | 30cb6228c52f | 1001 | — |
| svclb-traefik/lb-tcp-80 | `entry` 2497 | 88e1f2398c9c | root | 以 root / 工作目录 `/` |
| svclb-traefik/lb-tcp-443 | `entry` 2572 | 755fd0c1fd51 | root | 以 root / 工作目录 `/` |
| 各 Pod 沙箱 | `pause` ×8 | 各自 | 65535 | — |

### witr 聚合洞察

1. **无孤儿进程**：所有容器进程来源均为 kubernetes，挂在 containerd shim 下。
2. **真实父子关系**：`cilium-envoy-starter(1415) → cilium-envoy(1431)`；`cilium-agent(1695) → cilium-health-responder(1927)`。
3. **安全警告均为容器化常态**：以 root 运行（cilium 系、svclb LB）与工作目录 `/` 是镜像默认，非真实风险；LB 脚本以 root 监听 0.0.0.0:80/443 值得留意。
4. **cilium-agent 套接字揭示职责**：监听 `0.0.0.0:4244`、`192.168.67.201:4240`、`127.0.0.1:9879`(metrics)、`:9890`、`:40617`——节点数据面核心。
5. **Started 列可当重启探针**：多数进程统一 `05:41:49`（46h 前整体重启），operator `21:21:32`（restart=4）。

### 局限

`witr` 仅分析本机进程；ubuntu02/03 上的 `cilium-98vtn`、`web`、`api`、`test`、`curl`、`traefik` 需在对应节点执行。

---

## 6. 工具速查

```bash
ps aux                          # 查看所有进程
ps -eo pid,ppid,user,stat,comm,cgroup | grep kubepods   # 找容器进程(cgroup 归属)
crictl ps -a                    # 列出本机全部容器(含已退出)
crictl pods                     # 列出本机 Pod
kubectl get pods -A -o wide     # 集群全量 Pod
kubectl get nodes -o wide       # 节点视图
kubectl top nodes               # 实时资源占用
witr <进程名|--pid xxx|--port xxx>   # 进程来源/父链/端口分析
```

---

## 结论

该集群健康运转：**无孤儿/可疑进程**，witr 确认所有容器进程皆由 containerd shim 正常派生；主要风险是**控制面负载集中（74% 内存）**、coredns/traefik 单副本无 HA、以及两个定时重启产生噪音的 curl/test 调试 Pod。容器进程的安全告警（root、工作目录 `/`）均属容器化常规现象。