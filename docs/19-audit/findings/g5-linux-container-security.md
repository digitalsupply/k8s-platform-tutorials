# g5 · Linux / 容器 / 中间件 / 安全 审计发现

范围：`docs/05-linux/`、`docs/14-containers/`、`docs/16-middleware-os/`、`docs/18-security/`
方法：只读。文档自述的"真机证据"逐条与 `assets/evidence/` 及本机（m01，10.0.0.61）实测、
集群只读查询（kubectl get / redis-cli INFO）比对。共 17 条，按严重度排序。

---

### [严重度 高] 把 Cilium 说成 `privileged: true`，并据此论证"CNI 必须特权"
- 位置: docs/14-containers/06-container-security.md:65（同错见 14-containers/08-cases.md:200、14-containers/README.md:30、docs/05-linux/04-permissions-ugo-to-capabilities.md:306）
- 原文: 「| `cilium-*` | true | true | `NET_ADMIN,NET_RAW,SYS_ADMIN,SYS_MODULE,SYS_PTRACE,SYS_RESOURCE,...` |」；14/08「Cilium：privileged + hostNetwork + `SYS_ADMIN/SYS_MODULE/SYS_PTRACE`」；14/README「Cilium/CSI 是 privileged」
- 问题: Cilium 不是 privileged 容器。文档四处把它写成 privileged，并由此得出"平台组件 privileged 是必要之恶"的结论；05-linux 章还用这条支撑"CNI/CSI 必须 privileged"的安全判断，方向错了：Cilium 用的是 drop ALL + 精确 cap 的最小权限模型，正好是文档自己想推荐的做法。
- 证据/正确说法:
  `kubectl -n kube-system get pod cilium-h28cj -o json` → `securityContext = {"capabilities":{"add":["CHOWN","KILL","NET_ADMIN","NET_RAW","IPC_LOCK","SYS_MODULE","SYS_ADMIN","SYS_RESOURCE","DAC_OVERRIDE","FOWNER","SETGID","SETUID","SYSLOG"],"drop":["ALL"]},"seLinuxOptions":{"level":"s0","type":"spc_t"}}`，无 `privileged` 字段。
  全集群 138 Pod 中 privileged 容器 10 个，按 namespace 统计 `{'ceph-csi-rbd': 9, 'cicd': 1}`（同目录 assets/evidence/pod-security.txt:31 即此值），即 **rbd.csi.ceph.com-nodeplugin ×9 + buildkitd ×1**，不含任何 cilium。
  另外 caps 里没有 `SYS_PTRACE`/`SYS_CHROOT`：06-container-security.md:78-82 的 bounding 列表（13 个，含 SYSLOG、无 SYS_PTRACE）才是对的，与同文第 65 行的表格自相矛盾。错误源头是 assets/evidence/k8s-security/pod-security-summary.txt:40-45，那里把 6 个 cilium 标成了 `PRIV=True`，与同目录 pod-security.txt 冲突。

### [严重度 中] hostNetwork Pod 数前后不一致（38 vs 35），实测 35
- 位置: docs/05-linux/04-permissions-ugo-to-capabilities.md:16
- 原文: 「38 个 Pod 使用 hostNetwork，10 个 privileged；」
- 问题: 同一文件的"真机证据"和全仓其余位置都是 35。这是全章唯一的"当时的情况"数字，读者会拿它当结论。
- 证据/正确说法: 实测 `kubectl get pods -A -o json`，`spec.hostNetwork == true` 的 Pod = **35**；同文件 299 行 `summary: pods=138 hostNetwork=35 privileged=10 capAdd=19`；assets/evidence/k8s-security/pod-security-summary.txt:141 同值；18-security/10:34、18-security/README:22 也都是 35。

### [严重度 中] `/sys/kernel/security/lsm` 里有 selinux 被当成"SELinux 启用"
- 位置: docs/05-linux/01-kernel.md:212（另见 01-kernel.md:26、218-219）
- 原文: 「- **SELinux**：m01（Rocky）启用；」（§1：「m01 是 SELinux，其他节点是 AppArmor，容器安全策略不能照抄」）
- 问题: lsm 列表只说明该 LSM 模块被编进内核并注册在案，不代表策略生效。判断是否启用要看 `getenforce` / `/sys/fs/selinux/enforce`。结论错位后，"m01 需要 SELinux 标签、容器策略要区别对待"这一整段推论失去前提（而且同文档 218 行又用 containerd `enable_selinux = false` 圆场）。
- 证据/正确说法: 本机 m01 实测 `getenforce` → `Disabled`，而 `cat /sys/kernel/security/lsm` 仍是 `lockdown,capability,landlock,yama,selinux,bpf`——两者可以同时成立。18-security/10:27 与 README:18 记的 `SELinux Disabled` 是对的（assets/evidence/linux-baseline.txt:31 `Disabled`）。正确写法：lsm 列表含 selinux ≠ 启用，应以 `getenforce` 为准；本环境 m01 是 disabled，不是 enforcing。

### [严重度 中] `sudo` 被说成"继承当前环境"，与 02 章直接矛盾
- 位置: docs/05-linux/sudo-su-详解.md:20（表内 20-25 行）
- 原文: 「| `sudo 命令` | 以 root 执行单条命令 | **你自己的密码** | 继承当前环境 |」（`sudo -s` 亦标"保留当前环境"）
- 问题: sudo 默认 `env_reset`，除白名单变量外不继承调用者环境，PATH 被 `secure_path` 覆盖；RHEL/Rocky 默认 sudoers 还有 `always_set_home`，HOME 直接变成目标用户的家目录。这正好和 docs/05-linux/02-userspace.md:245「`sudo` 默认重置 `PATH`/`HOME`，`sudo -E` 才保留环境」相反，同一分类两章给了相反答案。
- 证据/正确说法: 本机 `/etc/sudoers`：`Defaults env_reset` / `Defaults always_set_home` / `Defaults secure_path = /sbin:/bin:/usr/sbin:/usr/bin`；`sudo -u nobody env` 的输出只有 `HISTSIZE/LANG/MAIL/PATH(=secure_path)/LOGNAME/USER/HOME(=目标用户)/SHELL/TERM`，调用者的 PATH/HOME 都不在。正确说法：sudo（`-s`/`-i` 同样）默认重置环境，要保留须 `-E` 且 sudoers 允许 SETENV。

### [严重度 中] 「su 无日志」——su 走 PAM，登录会话和失败都会记录
- 位置: docs/05-linux/sudo-su-详解.md:190
- 原文: 「能 sudo 就别共享 root 密码：sudo 有完整审计日志（`/var/log/auth.log` / `/var/log/secure`），su 无日志。」
- 问题: su 经 `/etc/pam.d/su` → `include system-auth`（pam_unix），成功/失败的会话都写 auth.log/secure，也进 wtmp/lastlog（`last` 可见）。真实差别是"命令级审计"（sudo 记 COMMAND=）而不是"有无日志"。
- 证据/正确说法: 本机实测 `su -s /bin/sh nobody -c 'id -u'` 后 `/var/log/secure` 新增两行：
  `su[139470]: pam_unix(su:session): session opened for user nobody(uid=65534) by root(uid=0)` / `session closed for user nobody`；
  `/etc/pam.d/su` 有 `session include system-auth`、`auth sufficient pam_rootok.so`。失败场景 standard 行是 `FAILED SU (to root) hao on pts/0`。正确表述：su 有会话级日志、无命令行审计；sudo 有 COMMAND 级审计。

### [严重度 中] 「`fs.nr_open` 不能超过 `file-max`」——内核无此约束，且被自身表格否证
- 位置: docs/05-linux/08-kernel-params-limits.md:127
- 原文: 「| `fs.nr_open` | 单进程 fd 上限 | 不能超过 `file-max` |」
- 问题: 两个参数没有大小依赖关系。`fs.nr_open` 的上限是 `sysctl_nr_open_max`（按内存推算），`fs.file-max` 是系统级已分配文件句柄总量上限，完全可以比 nr_open 小。真正的约束是"`LimitNOFILE`/进程 rlimit 不得超过 `fs.nr_open`"（该文 256 行写对了）。
- 证据/正确说法: 同文 145 行的真机表：GitLab 201 `fs.nr_open=1048576`、`fs.file-max=1000000`（nr_open > file-max，系统正常工作）；本机 m01 `fs.nr_open=1073741816`、`fs.file-max=9223372036854775807`。正确说法：nr_open 限制单进程 fd 上限、file-max 限制系统总量，二者独立；`ulimit -n`/`LimitNOFILE` 不得超过 nr_open。

### [严重度 中] 「容器配额由 cgroup 决定」——cgroup 没有磁盘容量配额
- 位置: docs/05-linux/03-filesystem-storage.md:120
- 原文: 「容器里的 `df` 通常显示宿主机根盘大小，不是容器配额；容器配额由 cgroup/文件系统 quota 决定。」
- 问题: cgroup v2 的 io controller 只有带宽/IOPS 限速（`io.max`），没有"可写层最大容量"这种配额。限制容器磁盘占用靠 xfs project quota（`pquota` + `prjquota` 挂载）、overlay 的 `size=` 选项、ext4 quota，或 kubelet 的 ephemeral-storage 驱逐；`df` 的数字来自 statfs 的 superblock，本就不受 cgroup 影响。
- 证据/正确说法: cgroup-v2 `io.max` 字段是 `rbps/wbps/riops/wiops`，无 bytes 上限；kernel 文档 cgroup-v2 "IO" 一节只有权重与限速。正确写法：容量限制 = 文件系统 project quota / overlay size / ephemeral-storage 驱逐；cgroup 只限 IO 速率。05/05:159 的「看 cgroup/`ephemeral-storage`/PVC」也有同样的混淆。

### [严重度 中] 把 apiserver 的 12 个 OS 线程读成"Go GC 并行度不足"，把请求 trace 当成 GC STW
- 位置: docs/05-linux/notes/memory-analysis-m01.md:92（另见 :95）
- 原文: 「kube-apiserver | **12** | 偏低但正常（Go 1.2G 堆仅 12 线程，**说明 GC 并行度不足，是延迟风险**）」；「日志中大量 `Trace ... (total time: 3501ms)`，单请求 3.5s，这是 GC STW + 内存压力的直接症状。」
- 问题: 两个归因都站不住。① Go 的 GC worker 是 goroutine，跑在 `GOMAXPROCS` 个 P 上，不体现为 OS 线程数；用 `/proc/<pid>/status` 的 Threads 判断 GC 并行度没有依据（apiserver 还有大量 netpoller/后台 goroutine，也不会各占一个线程）。② apiserver 的 `Trace[...]` 是 HTTP 请求级 trace（handler/metrics 耗时），不是 GC 日志；Go 的 STW 是亚毫秒到毫秒量级，不可能 3.5s。照这个结论去调 GOGC/GOMEMLIMIT 会偏离真正的根因（同一文档第 6 节自己已经证明是 etcd 超时 + 内存压力）。
- 证据/正确说法: Go runtime 的 STW 只有 sweep termination / mark termination 两个极短阶段，正常 <1ms；apiserver 的慢请求应先看 `apiserver_request_duration_seconds`、`etcd_request_duration_seconds`、inflight limit 与 etcd fsync 延迟。线程数用 `ps -o nlwp`、GC 用 `go_gc_duration_seconds` / `go_memstats_*` 判断，不要用线程数。

### [严重度 中] `oscap --profile cis` 用了简称，datastream 里没有这个 profile id
- 位置: docs/18-security/10-linux-k8s-security.md:352-354
- 原文: 「oscap xccdf eval --profile cis \\ --results /tmp/cis.xml \\ /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml」
- 问题: SSG 的 profile 标识是完整 XCCDF id，`cis` 只是简称，oscap 不做后缀匹配，会直接报 `Invalid profile`（"Profile 'cis' was not found"），命令跑不起来。
- 证据/正确说法: `oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml` 列出的 Profile id 形如 `xccdf_org.ssgproject.content_profile_cis`、`xccdf_org.ssgproject.content_profile_cis_server_l1`、`..._stig`。正确命令：`--profile xccdf_org.ssgproject.content_profile_cis_server_l1`（RHEL9 CIS Level 1 Server）。另外 `--remediate` 与该 profile 组合才是一次性修复，文档 359 行提了但示例里没带。

### [严重度 中] 脱敏把"完整恢复流程"里的命令改成了不可执行
- 位置: docs/05-linux/notes/app-removal-record.md:213
- 原文: 「mysql -uzabbix -p"$(grep -oP 'DBPassword=<redacted>' /etc/zabbix/zabbix_server.conf)" \\」
- 问题: 本意是取密码值（`DBPassword=\K.*`），脱敏把正则体整段换成 `<redacted>`：grep 永远匹配不到，`-p` 拿到空串，命令必然失败；且 `DBPassword=<redacted>` 里的 `<` 在双引号内虽不重定向，但放进 shell 后语义已经完全变了。这一节标题是"完整恢复流程（如需回滚）"，读者照抄会失败。
- 证据/正确说法: 应改成不泄密的写法，例如 `-p"$(awk -F= '/^DBPassword=/{print $2}' /etc/zabbix/zabbix_server.conf)"`，或直接 `mysql --defaults-extra-file=/etc/zabbix/.my.cnf`。同仓 126 处 `<redacted>` 中已有 1 个 .sh 因此语法错误（GROUND-TRUTH 已记录），这条属同类但落在"回滚手册"里，危害更大。

### [严重度 低] `sudo -i -c` 不是合法命令（sudo 无 `-c` 选项）
- 位置: docs/05-linux/sudo-su-详解.md:202
- 原文: 「sudo -i -c 'echo $HOME:$PATH'     # login，$HOME 是 /root，PATH 是 root 的」
- 问题: sudo 的短选项里没有 `-c`（只有 `-C num` 关闭 fd），`sudo -i -c ...` 会直接打印 usage 退出。同一段 201 行的 `sudo su -c` 是对的（`-c` 属于 su），容易让人以为两者通用。
- 证据/正确说法: 本机 `sudo -i -c 'echo hi'` → 输出 usage；`sudo --help` 选项表为 `[-AbEHknPS] [-r role] [-t type] [-C num] ... [-i|-s] [command]`。正确写法：`sudo -i bash -c 'echo $HOME:$PATH'` 或 `sudo bash -lc 'echo $HOME:$PATH'`。

### [严重度 低] Nginx 并发公式漏掉反向代理的"每请求两条连接"
- 位置: docs/16-middleware-os/10-middleware-os-pitfalls.md:246（另见 :445）
- 原文: 「最大并发连接 ≈ worker_processes × worker_connections」
- 问题: `worker_connections` 同时统计客户端连接和 upstream 连接，反向代理场景每条客户端请求额外占一条 upstream 连接，可承载的客户端并发约为总量的一半；文档举的两个实例（compassio frontend、Harbor nginx）都是 proxy 场景，直接套公式会把容量高估一倍。官方还要求 `worker_rlimit_nofile ≥ worker_connections × 2`。
- 证据/正确说法: nginx 官方文档 "worker_connections ... includes, but is not limited to, connections with proxied servers"；示例 `worker_rlimit_nofile 65535` 配 `worker_connections 4096`。建议写成：非代理 ≈ workers×connections；反向代理 ≈ workers×connections/2。

### [严重度 低] 「`docker history` 每一行是一个 layer」
- 位置: docs/14-containers/02-images-layers-overlayfs.md:156
- 原文: 「每一行是一个 layer；修改一层只会新增一层，不会改旧层。」
- 问题: history 的行与镜像层不是一一对应：`ENV/LABEL/CMD/WORKDIR` 等元数据指令只改 config、不产生层（显示 0B），`COPY --from`、被 squash/外部导入的层会显示 `<missing>`，所以行数 ≥ 实际层数。用它能看"哪些指令胖"，但不能当层计数。
- 证据/正确说法: 真实层数用 `docker inspect -f '{{len .RootFS.Layers}}' <img>` 或 `crictl inspecti`；`docker history` 里 0B 行即 metadata-only 指令。文档同节 4.5 的 `docker history` 输出里 "COPY views 20.5kB" 之类可看，但不宜下"一行一层"的结论。

### [严重度 低] m01 启动耗时表的列整体错位
- 位置: docs/05-linux/07-systemd-boot.md:21
- 原文: 「| m01 | 2.0s | - | 3.2s（initrd） | 7.7s | 12.9s |」（列为 firmware / loader / kernel / userspace）
- 问题: 原始输出（同文 148 行）是 `2.033s (kernel) + 3.243s (initrd) + 7.699s (userspace)`。表里把 2.0s 填进 firmware 列、3.2s 填进 kernel 列、把 initrd 标在 kernel 列，等于整体左移一列，读者会以为 m01 有 2 秒固件时间（它根本没有 firmware 分段，且 loader 为空）。
- 证据/正确说法: 第 148 行 `Startup finished in 2.033s (kernel) + 3.243s (initrd) + 7.699s (userspace) = 12.976s`。正确填法：firmware `-`、loader `-`、kernel 2.0s、initrd 3.2s、userspace 7.7s。

### [严重度 低] setgid 的符号写成 `rws`
- 位置: docs/05-linux/04-permissions-ugo-to-capabilities.md:107
- 原文: 「| setgid | `rws`（组位） | 执行时 egid = 文件 group；目录下新文件继承组 |」
- 问题: setgid 出现在**组**执行位，显示为 `s`（`rwxr-sr-x`、`---s--x--x`）；`rws` 是 owner 位 `s` 的写法（setuid）。表格里同一符号被两个概念共用，读者按 `rws` 去识别 setgid 会找错列。
- 证据/正确说法: 本机 m01 `/usr/bin/sudo` 为 `---s--x--x`（4111，setuid 在 owner 位但无读权限）；目录 setgid 典型为 `drwxr-sr-x`。另外"目录下新文件继承组"应补充：新建**子目录**会同时继承 setgid 位。

### [严重度 低] `ctr` 的"默认 namespace 是空的"说法不成立
- 位置: docs/14-containers/01-oci-runtime-stack.md:54（另见 :84、14-containers/07-container-debugging.md:71）
- 原文: 「默认 namespace：空。」/「`ctr` 默认 namespace 是 `default`，不是 `k8s.io`/`moby`。」/「注意 namespace：`k8s.io`/`moby`，默认 namespace 是空的。」
- 问题: ctr 的默认 namespace 名就是字符串 `default`，不是"空"。`ctr namespaces list` 里看不到它，是因为 containerd 的 namespace 只是 boltdb 里的标签、首次写入才落盘——把"没列出来"讲成"是空的"，会让人以为不存在默认域，也解释不了为什么 `ctr images ls` 不报错而是返回空列表。同一文件 54 行与 84 行本身互相打架。
- 证据/正确说法: `ctr images list` 不带 `-n` 时作用于 `default`（含 `ctr run` 创建的容器）；`ctr ns ls` 只列已创建的 namespace 条目。正确表述：默认 namespace 名为 `default`，`ctr ns ls` 通常不显示它。

### [严重度 低] Kafka 堆大小 "1.99GB" 与证据/单位都对不上
- 位置: docs/16-middleware-os/10-middleware-os-pitfalls.md:208（另见 16-middleware-os/README.md:33）
- 原文: 「  MaxHeapSize        = 1.99GB   # 默认 1/4 宿主内存」
- 问题: 证据值是 2082471936 字节 = **1.94 GiB = 2.08 GB**，"1.99GB" 两个单位都不对；同段又说"默认 1/4 宿主内存"（8 GiB × 25% = 2 GiB），三个数字互相解释不通。这类数字会被直接抄进容量规划。
- 证据/正确说法: assets/evidence/kafka-java.txt:40 `size_t MaxHeapSize = 2082471936 {product} {ergonomic}`。应写 `2.08 GB / 1.94 GiB（≈宿主内存 25%）`，或直接引原始字节数。
