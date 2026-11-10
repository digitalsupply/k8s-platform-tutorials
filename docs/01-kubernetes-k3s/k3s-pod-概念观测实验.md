# 剖开一个 Pod：一条命令链观测全部运行时概念

> 实验环境：本集群 ubuntu01（root）。目标：仅用只读观测 + 一次低风险滚动重启，把前文所有概念（ps aux、进程↔Pod↔容器↔shim、k3s 单进程模型、沙箱 vs Pod、netns/pidns 隔离、cgroup、overlay、UID 映射、生命周期）串成一条可复现的实验链。
> 全程不需要 `kubectl delete`，仅最后可选 `rollout restart`（秒级自动恢复）。

---

## 0. 工具清单（先检查）

```bash
which kubectl crictl ps pstree nsenter findmnt ip ss witr
# 本机均已具备；witr 仅在 ubuntu01 有
```

## 实验对象速查（本机预分配）

| 观察对象 | Pod | pause(PID) | shim(PID) | 业务进程(PID) | 沙箱ID | 网络模式 |
|---|---|---|---|---|---|---|
| A | cilium-q5jp6 | 1385 | 1358 | cilium-agent 1695 | 59b3674… | **hostNetwork** |
| B | coredns-…p6qlr | 2289 | 2251 | coredns 2453 | b10050a… | 普通 Pod |
| C | hubble-ui-…nd4nt | 2208 | 2184 | nginx 2426 + backend 2551 | 50d6834… | 普通 Pod，**2 容器** |

（PID 会变，用 `pgrep -f <进程>` / `crictl` 现查即可。）

---

## Checkpoint 1 — Pod 的三层对象：UID / 沙箱 ID / 容器 ID

**观测：**
```bash
kubectl get pod cilium-q5jp6 -n kube-system -o custom-columns=UID:.metadata.uid,NAME:.metadata.name
crictl pods  | grep cilium-q5jp6            # 第1列 POD ID = 沙箱ID
crictl ps    | grep cilium-q5jp6            # 第1列 = 业务容器ID
# 同一个 Pod 出现第三个 ID：cgroup 里的容器 scope
cat /proc/1695/cgroup
```

**预期现象：** 三个 ID 各不相同 → `UID(671e6ca3…) ≠ 沙箱ID(59b3674…) ≠ 容器ID(32107abe…)`。
对应概念：**Pod 是租约（UID 不变），沙箱是门卡（每次入住换号）**。

---

## Checkpoint 2 — k3s 单二进制：没有独立 kubelet / etcd 进程

**观测：**
```bash
ps -ef | grep -E 'kubelet|etcd' | grep -v grep     # 预期：空！
pstree -ap 861                                       # k3s server 内嵌所有控制面
ss -tlnp | grep k3s                                 # 6443=apiserver 10250=kubelet 10257/8/9
ls /var/lib/rancher/k3s/server/db/                   # state.db = SQLite，非 etcd
```

**预期现象：** 一切控制面都在 PID 861 里（pstree 只见 `{k3s-server}` 线程）；containerd(1007) 是它的**子进程**。
对应概念：**k3s 单进程全家桶 + containerd 内嵌**。

---

## Checkpoint 3 — 父链：systemd → shim → 容器进程

**观测：**
```bash
pstree -ap 1358    # shim → pause(1385) + cilium-agent(1695) + health(1927)
witr --pid 1358    # 告诉你：这是 containerd-shim-runc-v2，父是 systemd，service=k3s.service
witr -s cilium-agent          # 父链一行字
witr --port 4244  --short     # 从端口反查进程与父链
ps -o pid,ppid,comm -p 1695 1385   # PPID 都指向 1358
```

**预期现象：** 所有容器内进程 PPID = shim，shim PPID = 1（被 systemd 收养）。
对应概念：**containerd→shim→runc 三级松开**，`witr` 反向追溯"为什么它存在"。

---

## Checkpoint 4 — 同 Pod 容器共享网络命名空间（含 hostNetwork 对照组）

**观测：**
```bash
readlink /proc/1/ns/net        # 宿主 netns
readlink /proc/2208/ns/net     # hubble-ui pause
readlink /proc/2426/ns/net     #  frontend
readlink /proc/2551/ns/net     #  backend
readlink /proc/2289/ns/net     # coredns pause
readlink /proc/2453/ns/net     # coredns主进程
readlink /proc/1695/ns/net     # cilium-agent
# 全部一个 inode 号码 → 属于同一 netns
```

**预期现象（本机实测值）：**
```
宿主 init      → net:[4026531840]
hubble-ui 三个  → 都是 net:[4026532403]   ← 同 Pod 全共享
coredns 两个    → 都是 net:[4026532517]   ← 不同 Pod 不同网
cilium-agent    → net:[4026531840]        ← hostNetwork = 与宿主同网
```
对应概念：**pause 门房持网络命名空间；hostNetwork 的 pod 直接睡宿主的网**。

---

## Checkpoint 5 — PID 命名空间：容器里的 PID 1 是宿主的外卖

**观测：**
```bash
cat /proc/2551/status | grep -E 'Pid:|NSpid'
# 预期 NSpid:  2551  1   → 宿主视角 2551，容器视角 PID 1
crictl exec 32107abec9bb ps -ef | head -3   # 容器里看不到宿主进程
ps -ef | grep cilium-agent                  # 宿主却能看到容器内进程
```
对应概念：**PID 隔离是"视角差"，进程本尊全局唯一（同一个 2551）**。

---

## Checkpoint 6 — 容器 ID 的活证据：网络命名空间 inode ↔ 容器

**观测：**
```bash
# 通过 netns inode 反查属主容器
for p in 1695 2453 2426 2551; do printf '%s ' $p; readlink /proc/$p/ns/net; done | sort -k2
# 与 Checkpoint 4 交叉 → net:[4026532403] 内部装的正是 hubble-ui 的 frontend+backend
```
对应概念：**一切都从 PID 出发、靠 cgroup 与 ns inode 归位到 Pod/容器**。

---

## Checkpoint 7 — cgroup 分层：一眼看全 Pod UID + 容器 ID

**观测：**
```bash
cat /proc/2208/cgroup   # pause
cat /proc/2426/cgroup   # frontend
findmnt -t cgroup -o TARGET,OPTIONS | head        # cgroup v2 单层级
systemctl status kubepods.slice --no-pager 2>/dev/null | head -5
```
**预期现象（本机实测）：**
```
kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod91171a93_….slice/
   cri-containerd-b38003…frontend.scope
   cri-containerd-30cb62…backend.scope
   cri-containerd-50d6834…pause.scope
```
同一个 `pod91171a93`(=Pod UID) 下三个 scope：一个业务容器一个 scope + pause。
对应概念：**cgroup 是 Pod/容器在场证明，UID 与容器 ID 同时暴露**。

---

## Checkpoint 8 — overlay 文件系统：镜像层与可写层

**观测：**
```bash
findmnt -t overlay | grep -m1 'b38003\|32107'    # 容器 rootfs
cat /proc/2426/mounts | grep -E 'overlay|/ ' | head -3
# 只读 lowerdir 一串(镜像层) + upperdir 单个(可写层)
# 写测试（可选、不破坏镜像）：
crictl exec <frontend容器ID> sh -c 'echo probe > /tmp/probe && cat /tmp/probe'
```
对应概念：**容器文件系统 = lowerdir(只读) + upperdir(可写)**；删除容器丢 upper，不伤镜像。

---

## Checkpoint 9 — ps aux 实战回放：USER/STAT/中括号

**观测：**
```bash
ps aux | grep -E 'cilium-agent|coredns|kworker|pause' | grep -v grep
```
**预期现象：**
| 行 | 看点 |
|---|---|
| `[kworker/…]` | VSZ/RSS=0、root、中括号 = 内核线程 |
| `parkware 2426` | USER=1001 是容器内 uid；TTY=?；VsZ≫RSS |
| `/pause` | USER 65535（nobody 体系） |
对应概念：**ps aux 各列 + USER 列揭示容器 uid 直映宿主**。

---

## Checkpoint 10（可选、安全）— 生命周期：滚动重启见证"换门卡"

```bash
before=$(crictl pods | grep coredns | awk '{print $1}')
kubectl rollout restart deployment/coredns -n kube-system
watch -n1 'kubectl get pods -n kube-system | grep coredns'
curlt -dps → 再查：POD ID / UID / 容器 ID 全变；旧容器变 Exited 保留
crictl ps -a | grep coredns    # 旧容器 Exited（= 历史上 attempt1 那批的由来）
```
| | 重启前 | 重启后 |
|---|---|---|
| 沙箱ID | b10050a… | 新值 ← **换门卡** |
| Pod UID | ce599b1a… | **新值（新租约）** |
| 旧容器 | — | Exited 保留 |

**可选进阶**：`kubectl logs` 看 `-o jsonpath` 的 `metadata.deletionTimestamp`；或对 `kubectl get pod … -o yaml | grep -A1 'pod.kubernetes.io/lifecycle'`（k3s 标记）。
对应概念：**lifecycle 重建 = 换租约 + 换门卡，旧容器退场留备案（Exited）**。

---

## 概念 ↔ 实验对照表（速查）

| # | 前置概念 | 观测手段 | 一句话结论（本机实测） |
|---|---|---|---|
| 1 | Pod UID ≠ 沙箱 ID ≠ 容器 ID | kubectl uid / crictl pod,ps / cgroup | 一张图三个 ID |
| 2 | k3s 单进程、无 etcd/kubelet | pstree 861 / ss / state.db | 全家桶在 PID 861 |
| 3 | systemd→shim→runc 启动链 | pstree / witr | 容器进程 PPID=shim，shim PPID=1 |
| 4 | 网络命名空间共享 | readlink /proc/*/ns/net | 同 Pod 同 inode；cilium=hostNet |
| 5 | PID 命名空间 | NSpid / crictl exec ps | 2551=容器里 PID1 |
| 6 | 进程→容器 反向定位 | ns inode | 一切从 PID 出发归位 |
| 7 | cgroup 分层 | /proc/*/cgroup | kubepods→Pod UID→容器 scope |
| 8 | overlay 文件系统 | findmnt / mounts | lower 只读 + upper 可写 |
| 9 | ps aux 各列/USER | ps aux | 内核线程括号、uid 直映宿主 |
| 10 | 生命周期/沙箱重建 | rollout restart | 换门卡(沙箱)、新租约(UID)、旧容器 Exited |

---

## 收尾

```bash
# 若做了什么只读以外的改动（本实验除可选的 rollout 外没有），确认恢复：
kubectl get pods -A | grep -v Running | head
# 可选：把观测过程固化为脚本保存到 /home/hao/observe-pod.sh
```

> 核心心法：**Pod = 租约(UID), 沙箱 = 门卡(沙箱ID), 容器 = 租客, shim = 楼管, pause = 门房, runc = 开锁人**。
> 实验跑完，你对 `ps aux`→`witr`→`crictl`→`/proc` 的关系就有了肌肉记忆。