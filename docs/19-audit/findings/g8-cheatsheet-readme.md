# G8 · 面试速查 + README/当前状态快照 交叉一致性审计

审计对象：
- `docs/15-interview-cheatsheet/` 全部 md（README、00-verification-matrix、01–15 各章、labs、assets/evidence 索引）
- `README.md`（仓库根）、`docs/00-cluster-overview/assets/current-state.md`、`docs/00-cluster-overview/README.md`

基准：[`../assets/ground-truth.md`](../assets/ground-truth.md)（2026-11-11 实测）+ 本次只读 kubectl / Prometheus API 复核。
共 16 条，按严重度排序。

---

### [严重度 高] README 的 PrometheusRule/ServiceMonitor 数字过期且未标口径，与本文档自身冲突
- 位置: README.md:87；docs/00-cluster-overview/assets/current-state.md:201-202
- 原文: 「监控 | Prometheus/Alertmanager/Grafana 正常；PrometheusRule 41 个；ServiceMonitor 14 个」
- 问题: 这两个数字是 `monitoring` **单命名空间**的计数，却被写进"当前集群状态"总表，读者只能理解为全集群。全集群实测是 44 / 27：compassio 1 PM+1 SM、deeptutor 2 PM+1 SM、kube-system 3 SM、ceph-csi-rbd 2 SM，cert-manager / grafana-operator / logging / opentelemetry / tekton-pipelines 各 1。而且同一仓库 `docs/15-interview-cheatsheet/09-observability.md:69` 写的是「27 SM」，与 README 的 14 直接打架——同一集群不可能同时是 14 和 27。`current-state.md:201-202` 更糟：只有两行裸数字 `41` / `14`，没有命令、没有命名空间、没有标签，事后无法判断这是"全集群"还是"monitoring"口径。
- 证据/正确说法: `kubectl get prometheusrule -A | wc -l` → 44（monitoring 41 + deeptutor 2 + compassio 1）；`kubectl get servicemonitor -A | wc -l` → 27（monitoring 14 + 其余 13）。应写「PrometheusRule 44（monitoring 41）、ServiceMonitor 27（monitoring 14）」，或明确标注「仅 monitoring 命名空间」。

### [严重度 高] GitLab 版本 19.4.2 已漂移，且两处写法互相不一致
- 位置: README.md:18；docs/00-cluster-overview/README.md:43
- 原文: 「…；Traefik `v3.7.17`；GitLab CE `19.4.2`。」/「├─ ubuntu01 192.168.67.201  GitLab CE 19.4」
- 问题: 实测 GitLab 是 **19.5.0 Community Edition**，19.4.2 已过期。更麻烦的是同一事实在两处写法不同（根 README 三位 19.4.2、00 全景两位 19.4），既都错又互不一致，说明版本号是手抄没复核。
- 证据/正确说法: `curl http://192.168.67.201/api/v4/version` → `"version":"19.5.0"`，edition `ce`（GROUND-TRUTH.md:60 同结论）。两处都应改为 19.5.0，或统一写成「19.5.x（采集时 19.5.0）」。

### [严重度 高] TIME_WAIT 在同一环境给出 127 / 185 / 189 三个值，其中 185、189 没有任何证据文件
- 位置: docs/15-interview-cheatsheet/README.md:25、README.md:238；00-verification-matrix.md:25、00-verification-matrix.md:348；11-middleware-os.md:111；15-network-troubleshooting.md:39
- 原文: 「worker01 TIME_WAIT 127；实验 CLOSE_WAIT 1」→ 同文件后文「TIME_WAIT/CLOSE_WAIT | 主动关闭/应用没 close | 185 / 1」；矩阵「worker01 TIME_WAIT 127」与「TIME_WAIT | ✅ | 185，正常」；中间件章「TIME_WAIT 189」；网络排查章「TIME_WAIT 185，正常」
- 问题: 这是一份以"真机证据"为卖点的速查，但同一个 `ss` 计数有 3 个值，且都被标成本机实测。`assets/evidence/` 里只有 `network-states-worker01.txt:16` 的 `time-wait 127`，`grep -rn "185" assets/evidence/` 零命中——185/189 是无出处的数字。README.md 第 25 行与第 238 行、矩阵第 25 行与第 348 行都是"同一文件内前后矛盾"。
- 证据/正确说法: `docs/15-interview-cheatsheet/assets/evidence/network-states-worker01.txt:16` → `time-wait 127`；`02-network.md:46` 也引用 127。其余位置应统一为 127（并注明采集时刻），或删除无证据的 185/189。

### [严重度 中] "54 个 Deployment 用 25%/25%" 实测是 51
- 位置: docs/15-interview-cheatsheet/08-cicd-release.md:57；00-verification-matrix.md:169
- 原文: 「54 个 Deployment 用 25%/25%；`metrics-server` 用 25%/0 保证容量。」/「滚动发布 | ✅ | 集群 54 个 25%/25%」
- 问题: 当前集群 rollingUpdate 为 25%/25% 的 Deployment 是 **51** 个。全集群共 74 个 Deployment，其余为 5 个 `0/1`、3 个 `25%/1`、1 个 `25%/0`（metrics-server）、1 个 `1/1`、12 个 Recreate/未设 rollingUpdate。54 既不是"25%/25% 的数量"也不是"Deployment 总数"，是旧快照残留。
- 证据/正确说法: `kubectl get deploy -A -o jsonpath='{...maxSurge}/{...maxUnavailable}' | sort | uniq -c` → `51 25%/25%`、`12 /`、`5 0/1`、`3 25%/1`、`1 25%/50%`、`1 25%/0`、`1 1/1`；总数 74。

### [严重度 中] "52 job（27 ServiceMonitor + 16 PodMonitor）" 括号里的分解只有 43
- 位置: docs/15-interview-cheatsheet/09-observability.md:69；00-verification-matrix.md:197
- 原文: 「白盒 52 job（27 SM + 16 PM）」/「白盒监控 | ✅ | 52 job，27 ServiceMonitor + 16 PodMonitor」
- 问题: 27 + 16 = 43 ≠ 52，差值 9 个 job 没有解释。52 这个总数是对的（Prometheus 当前 52 个 job、114 个 target 全 up），但它们不全来自 ServiceMonitor/PodMonitor——kube-prometheus-stack 自带的 scrapeConfig 直接产生 kubelet、apiserver、kube-etcd、kube-scheduler、kube-controller-manager、coredns、node-exporter、kube-state-metrics、prometheus 等 job。把 52 归因成 27+16 会让读者以为"装 SM/PM 就能覆盖全部白盒 job"。
- 证据/正确说法: `/api/v1/targets?state=active` → 52 distinct job、114 targets、health 全 up；`kubectl get servicemonitor -A` = 27，`get podmonitor -A` = 16。应写「52 job = 27 SM + 16 PM + 9 个 chart 内置 scrapeConfig」。

### [严重度 中] README 的 "kube-proxy 已移除" 漏掉残留 headless Service，正好是误报告警的根因
- 位置: README.md:84
- 原文: 「| kube-proxy | 已移除（DaemonSet/CM/ServiceMonitor 均不存在） |」
- 问题: 括号内三项确实都不存在，但 `kube-system` 仍残留 `Service/prometheus-kube-proxy`（ClusterIP None、10249/TCP、292d、**endpoints 为空**）。本仓库自己记录了两条与之相关的后果：`12-sre.md:63` 的 `KubeProxyDown` 空转 50.9h、Prometheus 里 `job="kube-proxy"` 无 active target。README 作为总览写"已移除"，读者按这条去排查会发现一个无处解释的 Service；`current-state.md` 也没记录这个残留对象。
- 证据/正确说法: `kubectl -n kube-system get svc | grep proxy` → `prometheus-kube-proxy ClusterIP None <none> 10249/TCP 292d`；`get endpoints prometheus-kube-proxy` → 空。应写成「DaemonSet/CM 已删；残留无 endpoints 的 Service prometheus-kube-proxy（chart 未清理），导致 kube-proxy job 无 target」。

### [严重度 中] 证书一栏用 barman 客户端证书（90d）冒充"本环境集群证书"
- 位置: docs/15-interview-cheatsheet/README.md:149
- 原文: 「| 证书 | 按不可撤回设计 | 90d 自签，无 CSR/CRL |」
- 问题: 本集群控制面证书是 kubeadm 默认：leaf 约 1 年（现存 326 天）、CA 10 年（剩 9 年）——同仓库 `05-kubernetes.md:51` 和 `00-verification-matrix.md:105` 都是这么写的。"90d 自签"实际是 CNPG 的 `barman-cloud-client` 证书（`10-irreversibles.md:69` 有明确限定）。放在"本环境实测"列，读者会得出"本集群证书 90 天"的错误结论，而这正是面试里最容易被追问的点。
- 证据/正确说法: `05-kubernetes.md:51`「leaf 326d，CA 9y，rotateCertificates=true」；`10-irreversibles.md:69`「`barman-cloud-client` 90d 自签」。该行应写 kubeadm 的 1y/10y，或注明"示例取自 barman 客户端证书"。

### [严重度 中] 验证矩阵用"零偏差"给"kubelet 可低 3 minor"打 ✅
- 位置: docs/15-interview-cheatsheet/00-verification-matrix.md:101
- 原文: 「| 版本偏差 kubelet≤apiserver 3 minor | ✅ | 6 节点全 1.35.9 |」
- 问题: 6 个节点版本完全一致，恰恰说明这个偏斜规则在本环境**从未被验证**，不能作为"✅ 实测"。这条规则本身是对的（kubelet 不得高于 apiserver，可低至多 3 个 minor），但状态应是 📚（仅原理）或 ⚠️。矩阵其它行对"未复现"的条目都用 📚，此处口径不一致，属于把"配置现状"当"机制证据"。
- 证据/正确说法: `05-kubernetes.md:47` 同一条也写「6 节点全 1.35.9，零偏差」——即零偏斜；`kubectl get node` 全部 v1.35.9。

### [严重度 中] 存储章 Ceph 用量 88G 与两份快照都不符，且未标时间
- 位置: docs/15-interview-cheatsheet/04-storage.md:72
- 原文: 「**本环境**：HEALTH_OK，6 OSD up/in，465 PG active+clean，180G 用 88G。」
- 问题: 同环境 `current-state.md:154` 是「81 GiB used, 99 GiB / 180 GiB avail」（2026-11-10 16:03），GROUND-TRUTH.md:50 是 92 GiB（2026-11-11）。88 GiB 只出现在 `06-storage-ceph/10-storage-basics.md:268` 的更早快照里。面试速查正文没有任何采集时间，读者会把它当当前值；而这一章的定位正是"数字要能对上机器"。
- 证据/正确说法: 三个文件三个值（88 / 81 / 92），只有 88 这处既没写时间也没写命令。应统一引用 current-state 的数值并注明快照时间。

### [严重度 中] "证书轮换 ✅" 但轮换机制一次都没跑过
- 位置: docs/15-interview-cheatsheet/00-verification-matrix.md:105
- 原文: 「| 证书轮换 | ✅ | leaf 326d/CA 9y，rotateCertificates=true |」
- 问题: leaf 还剩 326 天说明根本没到轮换点；`rotateCertificates=true` 只是 kubelet 配置项。同仓库 `05-kubernetes.md:51` 明确写「无 CSRs」，即 kubelet 证书轮换从未触发。用"证书还很新 + 开关打开"证明"轮换可用"，是典型的把静态配置当运行证据；应为 ⚠️（配置正确、机制未验证）。
- 证据/正确说法: `05-kubernetes.md:51`「rotateCertificates=true，无 CSRs」；`kubectl get csr` 为空可复现。

### [严重度 低] conntrack 使用量 947 vs 953
- 位置: docs/15-interview-cheatsheet/11-middleware-os.md:111；00-verification-matrix.md:352
- 原文: 「TIME_WAIT 189、端口 32768–60999、conntrack 947/262144」/「conntrack | ✅ | 953/262144」
- 问题: 同一指标两处不同，都标"本环境实测"。数量级上无害，但它和同节的 TIME_WAIT 189 / 185 一起说明这一批数字是不同时刻拼进去的，读者无法判断哪份是同一快照。
- 证据/正确说法: 两处应取同一次采集值，并注明 `cat /proc/sys/net/netfilter/nf_conntrack_count` 的采集时刻。

### [严重度 低] etcd 快照 keys 8234 vs 8243
- 位置: docs/15-interview-cheatsheet/10-irreversibles.md:63（8243）；对照 05-kubernetes.md:57、00-verification-matrix.md:106、README.md:340（均为 8234）
- 原文: 「**本环境**：快照 133MB/8243 keys；恢复前必须备份当前 etcd 并在测试集群演练。」
- 问题: 同一个快照的 key 数被抄成两个值（数字顺序写反）。虽然不影响结论，但这类"证据数字"在面试场景会被逐字追问。
- 证据/正确说法: 其余三处均为 8234，应统一为 8234。

### [严重度 低] 容器日志轮转文件数 14 vs 17（README 自身就前后不一）
- 位置: 14-logging.md:45、00-verification-matrix.md:324（17）vs 09-observability.md:87、00-verification-matrix.md:202、README.md:132（14）；另 README.md:222 又写 17
- 原文: 「worker 17 个轮转文件，最大约 10.5MB」/「worker01 14 个轮转文件、最大约 10.5MB」/「14 个轮转文件；weekly×4」
- 问题: 同一台 worker 同一时刻的轮转文件数给了两个值，且验证矩阵里第 202 行与第 324 行互相矛盾，README 第 132 行与第 222 行也互相矛盾。"最大约 10.5MB"（>10Mi）本身是对的（kubelet 默认 10Mi 是触发阈值，单文件可略超），说明两次统计的确实是同一目录，只是数量抄错。
- 证据/正确说法: 需重新 `ls /var/log/pods/**/*.log*` 统计一次并统一；若为不同节点（worker01 vs worker），应在文字里写清节点名。

### [严重度 低] README 目录表把 01 描述成 k3s，但主集群是 kubeadm
- 位置: README.md:27
- 原文: 「| [01 Kubernetes](docs/01-kubernetes-k3s/README.md) | Pod 进程模型、k3s 概念、1.29→1.35 升级、控制面/节点/资源/稳定性核心考点 |」
- 问题: 目录名 `01-kubernetes-k3s` 与描述都指向 k3s，但本仓库实际运行的 6 节点集群是 **kubeadm** 部署（`00-cluster-overview/README.md:17`「kubeadm 部署」），1.29→1.35 逐级升级、kube-proxy IPVS→iptables、证书/etcd 备份全部发生在 kubeadm 侧；k3s 只是"三节点最小实验"（`01-kubernetes-k3s/README.md:5-8` 的两段经历，场景 A 才是 k3s）。按 README 描述找"kubeadm 升级"的读者会直接跳过这一章。
- 证据/正确说法: `docs/01-kubernetes-k3s/README.md:6`「kubeadm 生产集群：把 6 节点集群从 v1.29.8 逐级升级到 v1.35.9」。描述应改为「Pod 进程模型（k3s 实验）+ kubeadm 集群 1.29→1.35 升级」。

### [严重度 低] 验证矩阵把 Traefik 的 LB IP 当 "VIP"，与 API VIP 混用
- 位置: docs/15-interview-cheatsheet/00-verification-matrix.md:339
- 原文: 「| Pod/Service CIDR | ✅ | 10.244/16、10.96/12、VIP 10.0.0.252 |」
- 问题: 10.0.0.252 是 Traefik 的 LoadBalancer EXTERNAL-IP；集群/API VIP 是 kube-vip 的 `10.0.0.168:6443`（`10-irreversibles.md:75`、GROUND-TRUTH.md:19）。在"Pod/Service CIDR"这一行笼统写 "VIP"，读者会误以为 apiserver 入口是 10.0.0.252。
- 证据/正确说法: `kubectl -n traefik get svc traefik` → EXTERNAL-IP 10.0.0.252（externalTrafficPolicy=Cluster）；`get svc kubernetes`/kube-vip → 10.0.0.168。应写成「Traefik LB 10.0.0.252 / API VIP 10.0.0.168」。

### [严重度 低] current-state.md 里成片裸数字，脱离命令上下文无法核对
- 位置: docs/00-cluster-overview/assets/current-state.md:201-202、132-134
- 原文: 监控段末尾的 `41` / `14`；存储段末尾的 `     17 Bound` / `17`
- 问题: 快照文件声称"采集方式：只读 kubectl/helm/ceph"，但关键数字是孤立的裸值，既没有命令也没有标题，读者无法确认它是 `-A` 还是单命名空间、是 PV 数还是 PVC 数。上面第 1 条的口径错误正是这样产生的；`17 Bound` 与 `17` 重复两次也没说明后者是 `wc -l`。
- 证据/正确说法: 应写成 `kubectl get prometheusrule -A --no-headers | wc -l → 44`、`kubectl get servicemonitor -A --no-headers | wc -l → 27`、`kubectl get pv --no-headers | wc -l → 17`（17 个 PV 全 Bound 已复核）。

---

## 附：复核过且**正确**的高风险点（不再重复报告）
- Pod 网段 `10.244.0.0/16`、Service 网段 `10.96.0.0/12`：`kube-apiserver --service-cluster-ip-range=10.96.0.0/12`；`kube-dns` ClusterIP 10.96.0.10，Traefik 10.111.240.160 / 10.107.202.109 均落在 10.96/12 内。
- CoreDNS 2 副本、v1.13.1；`ndots:5` + 3 search。
- maxPods 110（`node.status.capacity.pods`）、cgroupDriver=systemd、6 节点全 v1.35.9。
- QoS 73 BestEffort / 65 Burstable / 0 Guaranteed；138 Pod；163 容器。
- PDB 11、HPA 3、CRD 146、ns 29、NetworkPolicy 23、Secret 128、PV 17 全 Bound、PVC 17 全 RWO。
- PSA：25 个 ns 无 label，1 restricted / 1 baseline / 2 privileged（README 的"PSA 仅 4 ns"与 13-security 的明细一致）。
- 探针 51 liveness / 1 preStop；`app-of-apps` prune=false/selfHeal=true；Traefik externalTrafficPolicy=Cluster。
- `tcp_tw_reuse=2`（2 = 仅 loopback，取值合法）、somaxconn 4096、syn backlog 512、keepalive 7200、端口 28232 个。
- 版本偏斜表述「kubelet 不得高于 apiserver、可低 3 minor；kubectl ±1」（01 章与 05 章一致且正确）；kubeadm 证书 1y leaf / 10y CA（现 326d / 9y）。
- etcd 3.6.6、quota 2.1GB、evictionHard memory.available=100Mi / nodefs 10% / imagefs 15%。
- ArgoCD 31 Application；Ceph 18.2.8 HEALTH_OK 6 OSD / 465 PG；kube-proxy DaemonSet 确实不存在。
