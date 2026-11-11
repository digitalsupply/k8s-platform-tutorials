# G2 审计：Cilium/eBPF 数据面 + 网络（docs/02-cilium-ebpf、docs/07-networking）

审计范围：`docs/02-cilium-ebpf/**` 与 `docs/07-networking/**` 下全部 Markdown（含 notes/ labs/ experiment/ assets/ 内的 md）。
判定基准：[`../assets/ground-truth.md`](../assets/ground-truth.md) + 2026-11-11 只读实测（kubectl get/exec 只读、cilium-dbg、helm template 本地渲染、curl、本地 iptables/CoreDNS/Traefik 文档核对）。
共 25 条，按严重度排序。

---

### [高] `kubeProxyReplacement=strict` 在 Cilium 1.20.4 上会让 helm 直接失败

- 位置: docs/02-cilium-ebpf/Cilium-EBPF数据面实战教程.md:339；docs/02-cilium-ebpf/Cilium-eBPF数据面实战教程-完整版.md:346；docs/02-cilium-ebpf/PodIP规划与Cilium-eBPF生产安装.md:226
- 原文: 「--set kubeProxyReplacement=strict \」
- 问题: `strict` 是 Cilium 1.13 之前的三态写法。1.20.4 的 chart 在渲染阶段就会 fail，只接受 `true`/`false`，三处「生产安装」命令照抄会 100% 装不上（连 helm 都出不了 manifest）。
- 证据/正确说法: 本机拉取官方 chart 渲染实测：
  ```
  $ helm template t /tmp/ciliumchart/cilium --set kubeProxyReplacement=strict
  Error: execution error at (cilium/templates/cilium-configmap.yaml:77:5):
  kubeProxyReplacement must be explicitly set to a valid value (true or false) to continue.
  ```
  正确写法：`--set kubeProxyReplacement=true`（对应 `cilium-config` 里 `kube-proxy-replacement: "true"`，与实测一致）。

### [高] `ipam.operator.clusterPoolIPv4PodCIDR` 已废弃：`--set` 静默不生效，且默认 Pod CIDR 不是 10.0.0.0/16

- 位置: docs/02-cilium-ebpf/Cilium-EBPF数据面实战教程.md:337（同段 :307 称「默认 10.0.0.0/16」）；Cilium-eBPF数据面实战教程-完整版.md:344、:320；PodIP规划与Cilium-eBPF生产安装.md:224、:102
- 原文: 「--set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16」／「从 `--cluster-pool-ipv4-cidr`（默认 10.0.0.0/16）」
- 问题: 1.13 起该键已改名 `clusterPoolIPv4PodCIDRList`（数组）。`--set` 一个模板不再读取的键，helm 不报错但 CIDR 完全没生效——排障时最难发现的那类错误。同时「默认 10.0.0.0/16」是错的。
- 证据/正确说法: chart 1.20.4 实测：
  ```
  $ helm template t ... --set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16 | grep cluster-pool-ipv4-cidr
  cluster-pool-ipv4-cidr: "10.0.0.0/8"        # 设了等于没设
  $ helm template t ... --set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.0.0.0/16}' | grep cluster-pool-ipv4-cidr
  cluster-pool-ipv4-cidr: "10.0.0.0/16"
  ```
  `helm show values` 中默认值为 `clusterPoolIPv4PodCIDRList: ["10.0.0.0/8"]`；`values.schema.json` 的 `ipam.operator` 只列 `clusterPoolIPv4PodCIDRList/clusterPoolIPv4MaskSize/...`，没有单数键。

### [高] kube-proxy nftables 修复命令的 JSON Patch 写成 `values`，命令必然失败

- 位置: docs/07-networking/notes/kube-proxy-nftables-diagnosis.md:96、:128
- 原文: 「kubectl patch ds -n kube-system kube-proxy --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command","values":[...]}]'」
- 问题: RFC 6902 的 `replace` 只认 `value`，`values` 是非法成员，apiserver 会直接拒绝（缺 value），后面的「结果：DaemonSet 命令行已改为 --proxy-mode=iptables」不可能发生。文档给的是「照抄即可修复」的步骤，实际会卡在这里。
- 证据/正确说法: `kubectl patch --type=json` 走 JSON Patch 语义，操作对象必须含 `value` 字段；正确写法 `{"op":"replace","path":".../command","value":["/usr/local/bin/kube-proxy","--proxy-mode=iptables","--hostname-override=$(NODE_NAME)","--kubeconfig=/var/lib/kube-proxy/kubeconfig.conf"]}`。另外 container 的 `command` 若原本未设置，`replace` 也会报 path 不存在，应先用 `add`。

### [高] 同一起 nftables 事故，两份文档结论互斥；「Calico BPF 兜底」与本集群 Calico 配置不符

- 位置: docs/07-networking/README.md:158 与 docs/07-networking/notes/kube-proxy-nftables-diagnosis.md:70-73
- 原文: 「`kube-proxy` 退出码 139。结果 Service 全部不可用。」 vs 「Calico BPF 在数据面兜底，ClusterIP/NodePort 仍可达 / 服务实际未中断，但完全依赖 Calico BPF」
- 问题: 两处对同一事件给出相反结论。诊断文档把「服务没断」归因于 Calico eBPF 数据面，但本集群 Calico 是 BIRD + iptables 后端（`calico_backend: bird`），`FELIX_BPFENABLED` 从未设置，02 目录自己也写了这一点；没有 kube-proxy 就没有任何组件为 ClusterIP 做 DNAT，服务不可能「未中断」。此外 139 是 `nft list tables` 的退出码（128+11/SIGSEGV），不是 kube-proxy 的退出码。
- 证据/正确说法: `docs/02-cilium-ebpf/assets/calico-phase0/calico-config.yaml:2` 为 `calico_backend: bird`；`docs/02-cilium-ebpf/README.md:87` 与 `notes/cilium-calico-migration-analysis-20261107.md:72` 均写「FELIX_BPFENABLED 未开启，不是 Calico eBPF 数据面」。诊断文档自己也只给出 `bpfConnectTimeLoadBalancing: TCP`（这只是 Felix 的 BPF 相关配置项，不代表 BPF 数据面启用）。正确说法：iptables 模式下 kube-proxy 不写规则 = ClusterIP/NodePort 不可用，与 README 一致。

### [中] kube-proxy 文档把 NodePort 的访问地址写成 Pod 网段 `10.244.x.x:30156`

- 位置: docs/07-networking/notes/kube-proxy-service-iptables-explained.md:68
- 原文: 「| NodePort | 10.244.x.x:30156 | KUBE-SERVICES 直接匹配端口 |」
- 问题: NodePort 监听在每个节点的**节点 IP**（本集群 10.0.0.61-124）上，10.244.0.0/16 是 Pod 网段，节点不会在 Pod 网段上开 NodePort；同一文档 3.1 节的示例（`10.0.0.61:30156`、`192.168.67.202:30080`）也自相矛盾。
- 证据/正确说法: `kubectl -n traefik get svc traefik` → `80:30156/TCP,443:30306/TCP`，实测 `curl http://10.0.0.61:30156` 200；节点 IP 见 `kubectl get nodes -o wide`（10.0.0.61/120/121/122/123/124）。应写 `任意节点IP:30156`。

### [中] Traefik Service 的 `externalIPs` 字段张冠李戴：10.0.0.252 是 loadBalancer ingress，不是 externalIPs

- 位置: docs/07-networking/notes/kube-proxy-service-iptables-explained.md:52-53（同文 :366「误区 5」又说是 LoadBalancer，内部矛盾）
- 原文: 「externalIPs: # LoadBalancer 分配的实际入口 IP  - 10.0.0.252」
- 问题: `spec.externalIPs` 是用户手写的附加 IP；10.0.0.252 来自 MetalLB 写入的 `status.loadBalancer.ingress`。两者在 iptables 里走不同链（externalIPs 不进 `KUBE-EXT-*` 的 LB 语义），文档前半段据此演示 LB 链路，结论会跑偏。
- 证据/正确说法: `kubectl -n traefik get svc traefik -o jsonpath='{.spec.externalIPs}|{.status.loadBalancer.ingress}'` → `|[{"ip":"10.0.0.252","ipMode":"VIP"}]`（`externalIPs` 为空）。

### [中] VXLAN 封装开销算成 76 字节：漏了 UDP 头，又把内层 IP 头重复计入

- 位置: docs/07-networking/notes/ipip-vs-vxlan-explained.md:186
- 原文: 「开销 = 14(以太头) + 20(IP) + 8(VXLAN) + 14(以太头) + 20(IP) = 76 字节」
- 问题: 一个字都没提外层 UDP 8 字节，同时把内层 IP 头（属于原始报文，不是封装成本）算进开销。结果与同文 5.4 节的 `1500-50=1450`、以及第 219 行的对比表自相矛盾（那里写 50 字节）。按 76 字节算 MTU 应是 1424，与全文其余数字全部冲突。
- 证据/正确说法: 正确开销 = 外层 IP 20 + UDP 8 + VXLAN 8 + 内层以太网 14 = 50 → MTU 1450。Cilium 官方 Routing 文档同样表述为「50 bytes per network packet for VXLAN」。

### [中] Calico VXLAN 默认 VNI 写成 1；`FELIX_VXLANMDS`/多播分发 MAC 不存在

- 位置: docs/07-networking/notes/ipip-vs-vxlan-explained.md:171、:199
- 原文: 「VNI = 0x000001 (calico VXLAN 默认 VNI=1)」／「需要 `FELIX_VXLANMDS` 指定多播分发 MAC（默认 `224.0.0.100`）」
- 问题: Calico 的 VXLAN VNI 默认是 **4096**（Felix `VXLANVNI`），不是 1；Calico 的 VXLAN 是**单播**实现（每节点一条 vxlan.calico FDB），根本不存在「多播分发 MAC 224.0.0.100」这东西，也不存在 `FELIX_VXLANMDS` 这个环境变量——写成「需要配置」会让读者去找一个不存在的开关。
- 证据/正确说法: Tigera Felix 配置参考：`VXLANVNI ... Schema Integer Default 4096`；Calico 相关 issue 亦说明「Calico uses 4096 for VXLAN ID」。Calico 实际存在的相关键是 `FELIX_VXLANMTU`、`FELIX_VXLANVNI`、`FELIX_VXLANPORT`。

### [中] IPIP 封装的外层源地址写成 tunl0 的 10.244.30.64（应为物理网卡地址）

- 位置: docs/07-networking/notes/ipip-vs-vxlan-explained.md:75、:99、:104
- 原文: 「外层 IP Header src = 10.244.30.64 (源节点 tunl0)」「中间物理网络只认外层：src 10.244.30.64 → dst 172.16.1.122」
- 问题: 外层头由内核按「到 dst 172.16.1.122 的路由」选取源地址，即出接口 eth1 的 172.16.1.124；Calico 的 tunl0 是 `ipip any`、不持有可路由地址。若外层源真是 10.244.30.64，物理网络无法回包——这正是「为什么必须封装」要解决的问题本身，逻辑上自相矛盾（同文 62 行又说下一跳是 172.16.1.x 的 eth1）。
- 证据/正确说法: 同文 3.2 节第 5 步已经说「物理网卡 eth0 发出」，且 56-59 行路由为 `via 172.16.1.122 dev tunl0 onlink`——onlink 表示外层走 eth1，外层 src=172.16.1.124。正确表述：外层 src=节点 eth1 IP，dst=对端节点 eth1 IP。

### [中] 「MetalLB L2 会把 VIP 加到 leader 节点网卡上」——L2 模式并不绑地址

- 位置: docs/02-cilium-ebpf/notes/metallb-speaker-to-cilium-l2-replacement-report-20261109.md:336、:389
- 原文: 「MetalLB L2 会把 VIP 加到 leader 节点网卡上；Cilium L2 不这样做，而是用 BPF 直接应答 ARP。」／表格「VIP 是否加到网卡 | 是（leader 节点 eth0）」
- 问题: MetalLB 的 L2 模式从来不给网卡配 VIP，它用 speaker 自己应答 ARP/NDP（用自己的 MAC 回答），所以 `ip addr` 里看不到 VIP。把「是否绑网卡」当成 MetalLB 与 Cilium L2 的关键差异是错的——两者在这一点上行为相同，真正差异在选主机制（memberlist vs Lease）与是否需要常驻组件。
- 证据/正确说法: MetalLB 官方文档：Layer 2 mode "does not require the IPs to be bound to the network interfaces of your worker nodes. It works by responding to ARP requests on your local network directly, to give the machine's MAC address to clients."

### [中] 「permanent: true → 返回 308」与实测不符（GET 是 301，非 GET 才是 308）

- 位置: docs/07-networking/notes/traefik-routing-architecture.md:116（同文 :119、:330 复用该结论）
- 原文: 「permanent: true  # → 返回 308，而非 307」
- 问题: Traefik 的 redirectScheme 在 permanent 下对 GET/HEAD 返回 **301**，仅对非 GET 方法返回 308。文档把 308 当默认结果，写进排障/验收判据（「http 应返回 308」）会误判正常为异常。
- 证据/正确说法: 现网同一 Middleware（`monitoring/redirect-to-https`, `permanent: true`）实测：
  ```
  $ curl -s -D- -o /dev/null -H 'Host: grafana.k8s.local' http://10.0.0.252/
  HTTP/1.1 301 Moved Permanently
  $ curl -s -D- -o /dev/null -X POST -H 'Host: grafana.k8s.local' http://10.0.0.252/
  HTTP/1.1 308 Permanent Redirect
  ```

### [中] 链路图把 LoadBalancer 的 DNAT 画在 `KUBE-EXTERNAL-SERVICES` 链上（错表、错链，且该链在 ETP=Cluster 下为空）

- 位置: docs/07-networking/notes/traefik-routing-architecture.md:283-285
- 原文: 「④ 节点 kube-proxy / iptables KUBE-EXTERNAL-SERVICES / DNAT 10.0.0.252:443 → Traefik Pod IP:8443」
- 问题: `KUBE-EXTERNAL-SERVICES` 在 **filter 表**，只为 `externalTrafficPolicy: Local` 的 LB/NodePort 生成（用于在无本地后端的节点上丢弃），不做 DNAT；LB IP 的 DNAT 在 **nat 表** 的 `KUBE-SERVICES → KUBE-EXT-<svc>`（同文 5.2 节自己就是这么画的）。本文又声明 Traefik 是 `externalTrafficPolicy: Cluster`，此时该链连规则都没有。另外该节点已无 kube-proxy（Cilium KPR 接管）。
- 证据/正确说法: `docs/07-networking/assets/network-troubleshooting/dns-cni.txt:18-19`：`Error from server (NotFound): daemonsets.apps "kube-proxy" not found`、`externalTrafficPolicy=Cluster`。正确链路：eth0 → Cilium BPF LB（`lb4_services` 中 `10.0.0.252:443` 前端）→ DNAT 到 10.244.4.63:8443。

### [中] 由「每个节点都有 LB 前端条目」推出「各节点都在宣告外部 IP」（推论错误）

- 位置: docs/02-cilium-ebpf/cilium-bpf-lb多轮问答汇总.md:124-135
- 原文: 「每个节点都有 LB 声明 → 使用 BGP 或 MetalLB 模式，各节点都在宣告外部 IP」
- 问题: Cilium KPR 下每个 agent 都会把 Service 前端写进本节点 `lb4_services`，这是「本节点能处理该 VIP」的必要条件，与谁对外宣告 VIP 无关。L2 模式同一时刻只有一个节点应答 ARP（本集群由 Lease 决定），LB 条目在 6 个节点上都有。
- 证据/正确说法: 两个节点 `cilium-dbg bpf lb list` 都含 `10.0.0.252:80/443`（revnat 分别为 10/11 与 20/21，说明是节点本地编号），而宣告者只有一个：
  ```
  $ kubectl -n kube-system get lease | grep l2
  cilium-l2announce-traefik-traefik   worker03
  ```
  正确判据：宣告者看 Lease / `metallb_speaker_announced`，LB 条目只说明「本节点已编程」。

### [中] 「netfilter 随机模式的概率判定基于 conntrack」——概率与 conntrack 无关

- 位置: docs/07-networking/notes/kube-proxy-service-iptables-explained.md:199（同文 :408 总结重复）
- 原文: 「netfilter 随机模式的概率判定基于 conntrack。一个 TCP 连接的所有包走同一条路径」
- 问题: `-m statistic --mode random --probability` 是无状态 PRNG，每个包独立抽样，完全不查 conntrack。一致性来自另一个机制：连接的首包完成 DNAT 后写入 conntrack，后续包命中 ESTABLISHED 的 NAT 记录，**根本不重新遍历** `KUBE-SVC/SEP`。把原因写成「概率基于 conntrack」会让人误以为 statistic 模块有流感知能力（它没有：UDP 每个包都会重新抽样）。
- 证据/正确说法: `iptables-extensions(8)`：`statistic --mode random --probability p: Randomly match a packet with probability p`（无连接状态概念）。正确表述：随机抽样只在「新建连接的首包」发生，后续包由 conntrack NAT 复用同一后端。

### [中] 实验文档里的 `cagent bpf ip list` / `cagent bpf ep list` 子命令不存在

- 位置: docs/02-cilium-ebpf/labs/01-basics/README.md:61；labs/06-service/README.md:50-51；labs/07-troubleshoot/README.md:32-33
- 原文: 「cagent bpf ip list           # IP 与身份的对应」「cagent bpf ep list        # endpoint」
- 问题: cilium-dbg 的 `bpf` 子命令只有 `ct/endpoint/ipcache/lb/nat/nodeid/policy/...`，没有 `ip` 也没有 `ep`，执行只会打印帮助并以非 0 退出，实验步骤 4/5 直接断掉。
- 证据/正确说法: 实测：
  ```
  $ kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ip list
  Direct access to local BPF maps
  Usage:
    cilium-dbg bpf [command]
  ```
  `cilium-dbg bpf --help` 列出的是 `ipcache  Manage the IPCache mappings for IP/CIDR <-> Identity`。正确命令：`bpf ipcache list`、`bpf endpoint list`（`cagent.sh` 里调用的 `cilium` 在镜像中确实存在，这一层没问题）。

### [中] 「必须先删 Calico 再装 Cilium，不能并存」与 Cilium 官方 chaining 及本仓自己的执行报告矛盾

- 位置: docs/02-cilium-ebpf/notes/cilium-ebpf-evaluation.md:54
- 原文: 「**迁移复杂度** — 必须先删 Calico 再装 Cilium，不能并存」
- 问题: Cilium 支持 generic-veth chaining 与 Calico 共存（`05-cilium.conflist` 里 `calico → portmap → cilium-cni`），本仓 `notes/cilium-chaining-migration-20261108.md` 就是一整篇「Cilium 与 Calico 共存跑了 1 天多」的执行报告。把「不能并存」写进评估结论，会让读者放弃风险最低的第一步（chaining 试点）。
- 证据/正确说法: 同目录 `cilium-chaining-migration-20261108.md:15、:243-253`：`CNI Chaining: generic-veth`、BGP 仍走 Calico、Cilium 6/6 Ready。正确说法：全量替换时 Calico 必须先移除；但 chaining 试点是官方支持且本集群验证过的低风险路径（注意共存期须固定 `IP_AUTODETECTION_METHOD`，见该文 2.2 节）。

### [中] 教程把 L2 Announcements / LB IPAM 标为「未启用」，与实测矛盾（同一文档还写「继续使用 MetalLB」）

- 位置: docs/02-cilium-ebpf/notes/cilium-tutorial-basic-to-advanced-20261109.md:41、:663（同文 :181、:623 同）
- 原文: 「| Cilium LB IPAM / L2 Announcement | ❌ | 继续使用 MetalLB |」「Ingress VIP：10.0.0.252（MetalLB L2 -> Traefik）」
- 问题: 实测已开 L2 宣告且 MetalLB speaker 已下线：能力矩阵给「❌」，会让读者以为 VIP 仍靠 MetalLB speaker 宣告；而 02 目录的 L2 迁移报告写的是当天已切换完成——两篇同日文档结论相反。另外「启用方式 `enableLBIPAM=true`」也不对：只做 L2 宣告不需要开 LB IPAM（`enable-lb-ipam=false` 时照样宣告）。
- 证据/正确说法: `cilium-config`: `enable-l2-announcements=true`；`kubectl get ciliuml2announcementpolicies` → `traefik-l2`（serviceSelector `io.kubernetes.service.namespace: traefik`，interfaces `^eth0$`）；Lease `cilium-l2announce-traefik-traefik → worker03`；`metallb` speaker `DESIRED=0`。正确写法：L2 宣告开关是 `l2announcements.enabled=true`（本次实际用的就是它）。

### [中] 「v1alpha1 期望 clusterCIDRs（复数数组）」——该字段不存在，`clusterCIDR` 才是正确字段名

- 位置: docs/02-cilium-ebpf/notes/cilium-calico-migration-analysis-20261107.md:99；docs/07-networking/notes/kube-proxy-nftables-diagnosis.md:77-78
- 原文: 「当前 kube-proxy ConfigMap 使用 `clusterCIDR`（单数），而 v1alpha1 期望 `clusterCIDRs`（复数数组）」
- 问题: KubeProxyConfiguration v1alpha1 只有 `clusterCIDR`（string，双栈用逗号分隔），没有 `clusterCIDRs` 数组字段。照这条「配置债」去改，会因未知字段被 strict 解码拒绝（或至少不生效），而真正的 detect-local 告警原因是「DetectLocalMode=ClusterCIDR 但 clusterCIDR 为空」。日志里的 `clusterCIDRs=null` 只是 kube-proxy 内部结构体的日志键名。
- 证据/正确说法: Kubernetes API 参考：`clusterCIDR [Required] string` —「clusterCIDR is the CIDR range of the pods in the cluster. (For dual-stack clusters, this can be a comma-separated dual-stack pair of CIDR ranges.)」。修法：确保 `clusterCIDR: 10.244.0.0/16` 写在 `config.conf` 里（或被 `--cluster-cidr` 提供），不要新增 `clusterCIDRs`。

### [中] 全量切换把 6 个节点（含 3 个控制面）一次性 drain 并 `--disable-eviction --force`，未给出风险提示

- 位置: docs/02-cilium-ebpf/notes/calico-to-cilium-full-cutover-20261109.md:102-109
- 原文: 「kubectl cordon m01 master01 master02 worker01 worker02 worker03 ... kubectl drain $n --ignore-daemonsets --delete-emptydir-data --force --disable-eviction --timeout=300s」
- 问题: `--disable-eviction` 直接绕过 Eviction API 与 PDB（等于把「优雅驱逐」降级成 delete），`--force` 连非控制器管理的 Pod 一起删；再叠加「所有节点同时 drain」，DNS/Ingress/metrics-server 全停。文档后文的「故障 1：cilium-secrets 卡 Terminating」「metrics APIService 不可用」正是这个操作顺序造成的（控制面节点上的 metrics-server 被驱逐 → APIService 失效 → namespace finalizer 卡住），但文中把它记成独立故障，没有回指根因。
- 证据/正确说法: 同文 226-254 行的事故链；`--disable-eviction` 的语义见 `kubectl drain --help`（"force drain to use delete, even if eviction would fail"）。更安全的顺序：先 drain 3 个 worker（保留控制面/核心 addon），确认 CNI 切换与 CoreDNS 正常后再处理控制面；需要保 PDB 语义时不要用 `--disable-eviction`。

### [低] Geneve 的 MTU 开销写成 1442（应为 1450，与 VXLAN 相同）

- 位置: docs/02-cilium-ebpf/notes/cilium-tutorial-basic-to-advanced-20261109.md:164；docs/02-cilium-ebpf/notes/calico-to-cilium-full-cutover-20261109.md:462
- 原文: 「Geneve：约 1442」「改 VXLAN/Geneve（MTU 1450/1442）」
- 问题: Geneve 与 VXLAN 都是 UDP 承载的二层封装，头部同样 8 字节：20(外 IP)+8(UDP)+8(Geneve)+14(内以太)=50，MTU 同为 1450。1442 意味着 58 字节开销，没有对应的封装形态（只有加 IPsec/额外选项才可能）。
- 证据/正确说法: Cilium Routing 文档对封装统一给「50 bytes per network packet」；同仓 `07-networking/10-network-troubleshooting.md:394-395` 的表格也写 VXLAN 50B→1450、Cilium tunnel 50B→1450。

### [低] CoreDNS `forward .` 的服务器顺序不等于主备（默认 policy random）

- 位置: docs/07-networking/notes/dns-test-results.md:59、:72、:85、:101
- 原文: 「forward . 223.5.5.5 119.29.29.29 1.1.1.1」＋「**推荐使用**: 223.5.5.5 作为主 DNS」
- 问题: forward 插件默认 `policy random`，会在上游列表里随机挑选（并做健康检查剔除），写在前面的 223.5.5.5 并不会成为「主」。若目标是「主用国内、失败回落国际」，需要显式 `policy sequential`，并按延迟/可用性分组；否则等于四个上游平摊。
- 证据/正确说法: CoreDNS forward 插件默认策略为 random（可选 `policy random|round_robin|sequential`）。建议写法：`forward . 223.5.5.5 119.29.29.29 { policy sequential }` 再配一个备用块，或在注释里说明「随机分摊」。

### [低] 用 kubelet 只读端口 10255 解释 KUBE-FIREWALL 的防护目标（该端口 1.19 起已移除）

- 位置: docs/07-networking/notes/kube-proxy-service-iptables-explained.md:267
- 原文: 「防止外部构造「源 IP 是 127.0.0.1」的包，绕过认证访问 kubelet 的只读端口(10255)」
- 问题: kubelet 的只读端口（`--read-only-port`，默认 10255）在 1.16 弃用、1.19 起彻底移除；本集群 1.35 不存在该监听。拿它当「为什么需要这条 DROP」的理由，属于引用已废弃的攻击面（这条规则本身仍在，保护的是所有仅监听 127.0.0.1 的本机服务）。
- 证据/正确说法: 现网 `ss -lntp` 无 10255 监听；kubelet 参数中 `readOnlyPort` 已不可用。正确表述：该规则阻止外部伪造 127.0.0.0/8 源地址访问**本机回环上监听的服务**（kubelet 10250 的 localhost 端点、sidecar 探针端口等）。

### [低] LoadBalancer 清单仍列已下线的 kourier/10.0.0.253；l2adv-tailscale 的接口表与自身资产不符

- 位置: docs/07-networking/notes/loadbalancer-ip-summary.md:12、:43
- 原文: 「| kourier | knative-serving | **10.0.0.253** | 80 (节点端口 30226) |」「| l2adv-tailscale | eth1 | lb-pool-tailscale |」
- 问题: knative 已整体下线（无 knative-serving 命名空间），集群里只有 traefik 一个 LoadBalancer Service，10.0.0.253 没有使用者；`L2Advertisement/l2adv-tailscale` 的实际 interfaces 是 `[eth0, eth1]`，也在 eth0 上宣告 10.0.0.252 所在的池——表格只写 eth1 会让人误判「10.0.0.252 是在 eth1 上宣告的」。
- 证据/正确说法: `kubectl get svc -A | grep LoadBalancer` 仅 `traefik 10.0.0.252`；`docs/07-networking/assets/current-metallb-config.yaml:62-67` 为 `interfaces: [eth0, eth1]`；`lb-pool-tailscale` 地址段 `10.0.0.252-10.0.0.253`。

### [低] 「Pod 实际运行在 worker01（10.244.5.94）」——10.244.5.0/24 属于 worker03

- 位置: docs/07-networking/notes/kube-proxy-service-iptables-explained.md:100、:103
- 原文: 「traefik 10.244.5.94:8000,10.244.5.94:8443」／「Pod 实际运行在 worker01（10.244.5.94）」
- 问题: 本集群按节点分 /24，10.244.5.0/24 = worker03（10.244.3.0/24 才是 worker01）。用错节点的快照去做「任意节点都能访问 ClusterIP」的演示，会把读者引到错误的节点上抓包。
- 证据/正确说法: `kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR` → `worker01 10.244.3.0/24`、`worker03 10.244.5.0/24`；`cilium-dbg status`（worker03）`IPAM: 46/254 allocated from 10.244.5.0/24`；当前 `kubectl -n traefik get endpoints traefik` → `10.244.4.63:8000,8443`（worker02）。

### [低] 「ping -s 1472 看似能过，但加上 ICMP 头就超了」——对 `-s` 语义的解释有误

- 位置: docs/02-cilium-ebpf/README.md:92-93
- 原文: 「IPIP 外层 20 字节 + 内层 20 字节，1500 的 underlay 只能承载 1480 的 Pod MTU。`ping -s 1472` 看似能过，但加上 ICMP 头就超了。」
- 问题: `ping -s` 指定的是 ICMP **载荷**长度，1472+8(ICMP)+20(IP)=1500，正好是 underlay MTU，所以它能过是因为「测的是 underlay」，与「加头就超」无关；要验证 1480 的 Pod MTU 应发 `-s 1452`（1452+28=1480）。按原文的解释，读者会把「1472 能通」误当成「1480 不成立」的证据，方向反了。
- 证据/正确说法: 同仓 `07-networking/notes/ipip-vs-vxlan-explained.md:369-373` 给出的算法才是对的（`-s 1472 → 1500` 测 underlay；`-s 1452` 测 IPIP 下的 1480）。建议统一为 `ping -M do -s 1452 <pod-ip>`。
