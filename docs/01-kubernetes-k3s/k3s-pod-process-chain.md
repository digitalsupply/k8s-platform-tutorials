# k3s Pod 与系统进程对应关系 · 启动链路全解

> 基于三节点实测（ubuntu01 控制面 + ubuntu02/03 worker）：`ps -ef`、`pstree`、`ss -tlnp`、`kubectl`、`crictl`、`witr` 交叉验证。
> 集群：3 节点 k3s v1.36.4+k3s1（containerd 2.3.4，Ubuntu 24.04），控制面存储 = **内嵌 SQLite**（无 etcd），CNI = **Cilium**。

---

## 1. k3s 启动链路（系统开机 → 集群就绪）

### 1.1 整体时序图

```
Linux 内核启动
   └─ systemd (PID 1, /sbin/init)
        │  开机加载 k3s.service（Type=notify, Restart=always, Delegate=yes）
        ├─ ExecStartPre: modprobe br_netfilter / overlay   ← 网络转发与容器文件系统支撑
        └─ ExecStart:  /usr/local/bin/k3s server (PID 861)
             │
             ├─ ① 初始化数据目录 /var/lib/rancher/k3s/
             │     · 解压内嵌二进制 → data/<hash>/bin/{containerd, containerd-shim-runc-v2, ...}
             │     · 初始化存储：内嵌 SQLite (kine) → server/db/state.db  【非 etcd】
             │
             ├─ ② 单进程内以 goroutine 启动全部控制面组件（pstree 显示为 {k3s-server} 线程）
             │     · kube-apiserver       → 监听 *:6443
             │     · k3s supervisor API   → 监听 127.0.0.1:6444（server↔agent 通信）
             │     · kube-controller-manager → 127.0.0.1:10257
             │     · kube-scheduler          → 127.0.0.1:10259
             │     · kube-cloud-controller   → 127.0.0.1:10258
             │     · kubelet（进程内，非独立 kubelet 二进制）→ *:10250 + 127.0.0.1:10248(健康检查)
             │     · k3s Agent 部分（register、tunnel）
             │
             ├─ ③ fork 出内嵌 containerd 子进程 (PID 1007)
             │     · socket: /run/k3s/containerd/containerd.sock
             │     · 配置:  /var/lib/rancher/k3s/agent/etc/containerd/config.toml
             │     · 与 k3s 一起同属 /system.slice/k3s.service cgroup
             │
             └─ ④ 部署内嵌 addon（server/manifests 中的 yaml）
                   · coredns / metrics-server / local-path-provisioner
                   · traefik（helm-install-* Job）→ 自动生成 svclb-traefik DaemonSet(ServiceLB)
                   · 集群就绪 → kubelet 开始调度调度系统 Pod
```

### 1.2 关键设计：单进程 vs 标准 K8s

| 组件 | 标准 K8s | 本集群 |
|---|---|---|
| kube-apiserver | 独立进程 | k3s server 进程内 goroutine |
| kubelet | 独立 `kubelet` 二进制 | **k3s server/agent 进程内** |
| controller-manager | 独立进程 | 进程内（:10257） |
| scheduler | 独立进程 | 进程内（:10259） |
| etcd | 独立进程 | 无；SQLite(kine) `state.db`（单 server 时） |
| containerd | 独立守护进程 | **k3s 的子进程**（非 systemd 服务） |
| 容器运行时二进制的宿主位置 | /usr/bin | `/var/lib/rancher/k3s/data/<hash>/bin/` |

> 所以 `ps -ef | grep kubelet` 在本机**查不到独立 kubelet 进程**——它藏在 PID 861 内部。

---

## 2. 单 Pod 的启动链路（容器如何生出来）

**进程级链路（本机实测）：**

```
k3s server (861) ──kine/scheduler/controllerManager── kubelet(进程内)
   │  kubelet 调用 CRI(gRPC over containerd.sock)
   ▼
containerd (1007)  ──spawn──▶ containerd-shim-runc-v2 (PPID 重新挂到 1/systemd)
   │                            │  （仍属 k3s.service cgroup，经 shim.sock 与 containerd 通信）
   │                            ▼
   │                         runc 启动容器进程 ──▶ 容器内 PID 1 = 应用进程
   ▼
crictl / kubelet 拉镜像 → containerd 快照(overlay: lowerdir 只读镜像层 + upperdir 可写层)
```

**Pod 内部时序**（以本机 cilium-envoy 为例）：

1. 调度器选中节点 → kubelet → containerd 创建 **Pod 沙箱**：`containerd-shim-runc-v2`(PID 1290) 拉起 `/pause`(PID 1314)，建立**共享网络命名空间**（未分配 Pod IP 由 CNI 负责）
2. CRI 调用 Cilium CNI → cilium-agent 分配 Pod IP、下发路由与策略
3. 依次启动业务容器：`cilium-envoy-starter`(1415) → `cilium-envoy`(1431)，其网络视图与 pause 完全一致（同 netns）

**为什么 shim 的父进程是 PID 1？**
containerd 启动的 shim 会自行 daemonize，被 systemd 收养（PPID=1），但 cgroup 仍归属 `k3s.service`——containerd 只通过 shim UNIX socket 与之通讯。这也是 `witr` 输出 `systemd(1) → containerd-shim → 应用` 的原因。

### 2.1 沙箱(sandbox) vs Pod：形象比喻

**Pod 是"租约档案"，沙箱是"门卡"。**

| 角色 | 现实比喻 | 真实身份 |
|---|---|---|
| Pod | 一份长期租约 | **Pod UID = 档案号/合同号**，Pod 存活期内不变 |
| Pod UID | 档案号（合同期不变） | `kubectl get pod -o jsonpath='{.metadata.uid}'` |
| 沙箱 | 为履约当前发的门卡（钥匙+水电总表） | 沙箱 ID，`crictl pods` 的 POD ID、shim 的 `-id` |
| 容器进程 | 住进来的租客 | 业务程序 |
| pause | 门房，只管公共网络 | 持共享网络命名空间 |
| 网络命名空间 | 这间的公共宽带(共享、各看各的墙) | NETNS |
| shim | 楼管，盯租客在不在 | 每 Pod 一个 |
| runc | 开锁进门的人 | 启动器 |

**为什么沙箱 ID 每次"换房"就变？**

| 事件 | Pod UID（档案号） | 沙箱 ID（门卡） |
|---|---|---|
| 节点重启（断电） | **不变** | **重换** |
| containerd 崩溃重建沙箱 | 不变 | 重换 |
| `kubectl delete pod`（退租） | 档案销毁 | 门卡作废 |
| Deployment 重建新 Pod | 全新档案号 | 全新门卡 |

**典型错觉**：`witr --pid 1358` 的 `-id 59b3674...` 常被当容器 ID——其实那是**沙箱 ID**（Pod 的门卡号）；真正的业务容器 ID（如 `32107abec9bb`）藏在 cgroup scope 里。

**一句话**：沙箱是 Pod 在机器上"临时住下的那间房"，Pod 是"谁和谁住一起"的业务合同。

---

## 3. 系统进程 ↔ Pod 对应关系（本机实测表）

### 3.1 控制面/运行时进程（宿主侧，非容器）

| 系统进程 | PID | 对应 Pod/组件 | 说明 |
|---|---|---|---|
| `k3s server` | 861 | 集群控制面（apiserver/kubelet/调度器/CCM…） | 单二进制全内嵌 |
| `containerd` | 1007 | 所有 Pod 的容器运行时 | k3s 子进程，CRI gRPC :10010 |
| `containerd-shim-runc-v2` ×8 | 1246/1290/1358/2091/2125/2184/2222/2251/2304 | 每个**运行中容器**一个 shim | PPID=1，管理单个容器生命周期 |
| ciilium-agent 的宿主网卡/路由 | — | 节点数据面 | hostNetwork，非容器 |

### 3.2 Pod 沙箱（pause）→ shim 对应（每 Pod 一个）

| pause PID | 属主 shim PID | 所辖 Pod | 启动时间 |
|---|---|---|---|
| 1385 | 1358 | cilium-q5jp6（cilium-agent） | 05:41:49 |
| 1314 | 1290 | cilium-envoy-v26ns | 05:41:49 |
| 1268 | 1246 | cilium-operator-… （operator 也回自 pause? 见下） | 05:41:49 |
| 2143 | 2091 | metrics-server-… | 05:41:49 |
| 2156 | 2125 | local-path-provisioner-… | 05:41:49 |
| 2208 | 2184 | hubble-ui-…（frontend+backend 同沙箱） | 05:41:49 |
| 2270 | 2222 | hubble-relay-… | 05:41:49 |
| 2289 | 2251 | coredns-… | 05:41:49 |
| 2338 | 2304 | svclb-traefik-…（lb-tcp-80 + lb-tcp-443 同沙箱） | 05:41:49 |

### 3.3 容器内进程 → shim → Pod 完整链路

| 容器内进程（PID） | shim(PID) | Pod | 容器 |
|---|---|---|---|
| cilium-agent 1695 ← health-responder 1927 | 1358 | cilium-q5jp6 | cilium-agent |
| cilium-envoy-st 1415 → cilium-envoy 1431 | 1290 | cilium-envoy-v26ns | cilium-envoy |
| cilium-operator-generic 15282 | 1246 | cilium-operator-… | cilium-operator |
| /metrics-server 2399 | 2091 | metrics-server-… | metrics-server |
| local-path-provisioner 2364 | 2125 | local-path-… | local-path-provisioner |
| nginx master 2426 → worker×2 2631/2632 | 2184 | hubble-ui-… | frontend |
| /usr/bin/backend 2551 | 2184 | hubble-ui-… | backend |
| hubble-relay 2466 | 2222 | hubble-relay-… | hubble-relay |
| /coredns 2453 | 2251 | coredns-… | coredns |
| entry 2497（lb-tcp-80） | 2304 | svclb-traefik-… | lb-tcp-80 |
| entry 2572（lb-tcp-443） | 2304 | svclb-traefik-… | lb-tcp-443 |

> 同一 shim 可对应同 Pod 的多个容器（hubble-ui、svclb 各一个 shim 管多个容器）+ 同 Pod 的 pause。

---

## 4. 各 Pod 的作用与来源

k3s 的 Pod 分两类来源：**内嵌 addon（k3s 自动部署）** 与 **用户/Helm 手动部署**。

### 4.1 kube-system —— 集群基础设施

| Pod | 来源 | 作用 | 通信/端口特征（本机） |
|---|---|---|---|
| `cilium-*`（DaemonSet×3） | Helm（Cilium） | **CNI 数据面**：PodCIDR 分配、eBPF 路由/转发、网络策略、**替代 kube-proxy 的 Service 转发**、Hubble 抓包、HostFirewall | hostNetwork；监听 4240/4244/9879/9890 |
| `cilium-envoy-*`(DS×3) | Helm | Cilium 的 Envoy 代理，承载 L7 网络安全策略与高级可观测 | Pod IP，由 cilium-agent 下发 bootstrap 配置 |
| `cilium-operator*`(Dep×2) | Helm | 全局管理：IPAM 地址池、CEP(ciliumendpoint) 清理同步、网络策略与 kvstore 等；2 副本做 HA | 集群内 |
| `svclb-traefik-*`(DS×3) | k3s ServiceLB 自动 | 为 LoadBalancer 型 svc 生成每个节点的引流 Pod，2 容器(80/443)把流量送往 traefik | 每节点监听 80/443 |
| `traefik-64…` 1 副本 | k3s 内嵌 addon(HelmJob) | Ingress 控制器，宿 7 层路由 | 由 svclb DaemonSet 供流量 |
| `coredns-*` | k3s 内嵌 addon | 集群 DNS（svc kube-dns，53/9153） | ClusterIP 10.43.0.10 |
| `metrics-server-*` | k3s 内嵌 addon | 供 `kubectl top` / HPA 的指标聚合 | 端口 10250(kubelet) |
| `local-path-provisioner-*` | k3s 内嵌 addon | 动态 LocalPV 供给（节点本地目录做 PV） | 集群内 |
| `hubble-relay-*` | Cilium 组件 | 汇总各节点 cilium-agent 的流量流，向 Hubble UI 供 API | ClusterIP 10.43.148.231 |
| `hubble-ui-*`（2 容器） | Cilium 组件 | Hubble 可视化界面：frontend=nginx 静态页、backend=gRPC/API 转换 | NodePort 8081:30080 |
| `helm-install-traefik(-crd)-*` | k3s 内嵌 manifests | 一次性 Helm 安装 Job（已 Completed） | 无 |

### 4.2 default / lab —— 用户负载

| Pod | 副本 | 作用 |
|---|---|---|
| `nginx-*` | 1 | 演示/测试应用（ClusterIP svc nginx） |
| `curl` | 1 | 定时调试工具（周期 curl 完成后被 Always 策略重启，211 次） |
| `web-*` | 2 | lab 业务前端，跨 02/03 双副本 |
| `api-*` | 1 | lab 业务后端（ClusterIP，未被 Ingress 暴露） |
| `test-*` | 1 | lab 压测/测试进程（238 次重启，原因同 curl：exitCode=0） |

---

## 5. 从 k3s.service 参数反推架构

实测 `/etc/systemd/system/k3s.service` 的 ExecStart 参数：

```
k3s server --write-kubeconfig-mode 644
           --flannel-backend=none      ← 关掉 flannel，由 Cilium 接管 CNI
           --disable-kube-proxy       ← 关掉 kube-proxy，由 Cilium 的 eBPF 做 Service 转发
           --disable-network-policy   ← 关掉 k8s 原生 netpol，交给 Cilium NetworkPolicy
```

这解释了为什么没有 flannel/kube-proxy 相关进程、却有完整的 Cilium 堆栈——本集群是标准的 **"k3s + Cilium 数据面"** 组合。

---

## 6. worker 节点链路补齐（ubuntu02 / ubuntu03）

> 通过 `ssh hao@192.168.67.20{2,3}` + `sudo -i`（免密）远程实测。

### 6.1 worker 引擎与 server 完全同构（agent 模式）

worker 节点进程模型与 ubuntu01 的"agent 侧"一致，只是**没有控制面组件**：

```
systemd(1)
   └─ k3s agent            ← ubuntu02: PID 859 / ubuntu03: PID 864
        ├─ 内嵌 kubelet        → *:10250（+ 127.0.0.1:10248 健康检查）
        ├─ supervisor 回连     → 127.0.0.1:6444
        └─ containerd 子进程   ← ubuntu02: PID 997 / ubuntu03: PID 1000（CRI :10010）
             └─ containerd-shim-runc-v2 ×7（PPID=1）→ runc → 容器进程
```

特征核对（与 ubuntu01 完全一致）：
- `k3s agent` 单一进程内嵌 kubelet，**无独立 kubelet 二进制**
- containerd 是 agent 的子进程；shims 全部 PPID=1、cgroup 归 `k3s-agent.service`
- 运行时二进制同款：`/var/lib/rancher/k3s/data/5a9973ddf4c7ec074f657c06287e0e6a07a24ecafd6d326827f70ef1e95bdd2d/bin/`

### 6.2 ubuntu02（192.168.67.202）shim ↔ Pod 总表

| Pod | 容器 | 容器主进程 | pause PID | shim PID | witr 父链确认 |
|---|---|---|---|---|---|
| cilium-98vtn | cilium-agent | cilium-agent **1573** | 1259 | 1230 | systemd→shim1230→cilium-agent |
| cilium-envoy-dn5zt | cilium-envoy | cilium-envoy-st **1239** | 1148 | 1123 | 同上模式 |
| cilium-operator-rqrrt | cilium-operator | cilium-operator **15022** | 1193 | 1164 | systemd→shim1164→operator |
| svclb-traefik-zgwgq | lb-tcp-80 / 443 | entry **1946** / entry **2120** | 1865 | 1842 | 每节点一个 LB 沙箱管两个端口容器 |
| lab/api | api | **httpd 2182** ← 意外发现 | 2008 | 1983 | systemd→shim1983→httpd |
| lab/web | web | **sh 2163**（入口脚本） | 2052 | 2027 | systemd→shim2027→sh |
| lab/test | test | **sleep 39039** ← 重启元凶 | 2090 | 2066 | systemd→shim2066→sleep |

### 6.3 ubuntu03（192.168.67.203）shim ↔ Pod 总表

| Pod | 容器 | 容器主进程 | pause PID | shim PID | witr 父链确认 |
|---|---|---|---|---|---|
| cilium-wz8bj | cilium-agent | cilium-agent **1506** | 1221 | 1180 | systemd→shim1180→cilium-agent |
| cilium-envoy-vdffm | cilium-envoy | cilium-envoy-st **1214** | 1159 | 1135 | 同上模式 |
| svclb-traefik-svqfh | lb-tcp-80 / 443 | entry **2095** / entry **2163** | 1999 | 1946 | — |
| traefik | traefik | **traefik 2069** | 1903 | 1858 | systemd→shim1858→traefik |
| default/nginx | nginx | nginx master **2281** | 1888 | 1839 | systemd→shim1839→nginx: |
| default/curl | curl | **sleep 38638** ← 重启元凶 | 1957 | 1910 | systemd→shim1910→sleep |
| lab/web | web | **sh 2122**（入口脚本） | 2022 | 1985 | systemd→shim1985→sh |

### 6.4 worker 补齐带来的新发现

1. **api 容器 = Apache httpd**：`lab/api` 的 PID 1 是 httpd，不是自定义二进制。
2. **web 容器 PID1 = sh**：入口是 shell 脚本再 exec 主程序（过度包装，重启语义被外壳吞掉）。
3. **curl/test 重启真相坐实**：两者容器 PID1 都是 `sleep`——脚本执行完毕进入 sleep 等待，因 `restartPolicy: Always` 每周期被循环拉起（curl 211 次 / test 238 次）。
4. **全集群 shim 数对称**：每节点都是「3 Cilium 沙箱 + 1 svclb 沙箱 + 业务沙箱」= 7 个运行容器（+1 pause），控制面节点额外多出 hubble 系 3 个沙箱。
5. **三节点 `k3s agent`/`k3s server` 都无独立 kubelet/containerd 部署**——k3s 的"嵌入式"设计在 agent 端贯彻到底。

---

## 7. 排查锚点速查

| 想查什么 | 命令 |
|---|---|
| 各容器进程挂在哪个 shim/容器 | `pstree -ap 861`（看 shim 子树） |
| containerd socket 是否活着 | `ss -xln \| grep containerd` |
| 某 Pod 在宿主的容器→进程 | `crictl ps` + `ps -ef \| grep <pod>` |
| 进程为什么不正常（父链/端口） | `witr --pid <pid>` |
| k3s 实际启动参数 | `cat /etc/systemd/system/k3s.service` |
| 存储类型（etcd or sqlite） | `ls /var/lib/rancher/k3s/server/db/`（有 state.db = SQLite） |
| k3s 数据版本目录 | `ls /var/lib/rancher/k3s/data/` |

---

## 核心结论

1. **k3s 是"单二进制全家桶"**：apiserver/kubelet/调度器/CCM 全在 `k3s server` 一个进程的 goroutine 里，containerd 是它的子进程——这是与传统 K8s 进程模型最大的差异。
2. **容器由 containerd→shim→runc 逐级拉起**，shim daemonize 后被 systemd 收养；每 Pod 一个 pause 沙箱持有网络命名空间。
3. **本集群用 Cilium 完整替换了 flannel + kube-proxy + 原生 netpol**，并顺带部署 Hubble 可观测组件。
4. **系统 Pod 大部分是 k3s 内嵌 addon**（coredns/metrics-server/local-path/traefik+svclb），业务负载集中在 lab 命名空间。