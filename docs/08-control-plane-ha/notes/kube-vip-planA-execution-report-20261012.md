# kube-vip 方案 A 执行报告：worker kubelet 切换至 VIP

> 依据：`/root/kube-vip-apiserver-analysis.md` 第 7.4 节「方案 A（推荐，改动最小）」
> 目标：把 worker 的 `kubelet.conf` 从 `10.0.0.61:6443`（m01，单点）切换到 VIP `10.0.0.168:6443`，让 worker kubelet 走 HA 入口
> 集群：6 节点（3 CP + 3 worker），kube-vip v1.2.4，ARP/L2
> 执行时间：2026-10-12 16:53–16:55 CST　执行方式：逐台滚动（worker01 → worker02 → worker03）

---

## 一、执行结论

✅ **方案 A 执行成功。3 台 worker 的 kubelet 已全部改走 VIP `10.0.0.168:6443`，集群 6/6 节点 Ready，无异常 Pod。**

| 节点 | IP | 改前 kubelet server | 改后 kubelet server | kubelet 状态 | 到 VIP 的实际连接 |
|---|---|---|---|---|---|
| worker01 | 10.0.0.122 | `https://10.0.0.61:6443` | `https://10.0.0.168:6443` | active | ESTAB → `10.0.0.168:6443` |
| worker02 | 10.0.0.123 | `https://10.0.0.61:6443` | `https://10.0.0.168:6443` | active | ESTAB → `10.0.0.168:6443` |
| worker03 | 10.0.0.124 | `https://10.0.0.61:6443` | `https://10.0.0.168:6443` | active | ESTAB → `10.0.0.168:6443` |

---

## 二、对原始「方案 A」的一处必要修正（重要）

原分析建议：*“文件里已存在指向 `10.0.0.168:6443` 的 `kubernetes` cluster，只需把 context/cluster 改成它”*。

**实测发现该 `kubernetes` 条目不可直接用**——它只有 `server`，**没有 `certificate-authority-data`**（属历史遗留的“死条目”）。在 worker01 上做无损实测（不改生效配置、不重启）：

| 测试 | 配置 | 结果 |
|---|---|---|
| A | `default-cluster`（**保留 CA**）的 server 改为 VIP | ✅ `system:node:worker01`，`/healthz` = ok |
| B | 直接切到 `kubernetes` 条目（VIP，**无 CA**） | ❌ `tls: failed to verify certificate: x509: certificate signed by unknown authority` |

> 因此采用**等效且更稳妥**的最小改动：**保留 `default-cluster` 的 CA，把它的 `server` 单行从 `10.0.0.61:6443` 改为 `10.0.0.168:6443`**。效果与方案 A 完全一致（worker kubelet 走 VIP），且不会破坏 TLS 校验。

---

## 三、前置校验（变更前全部通过）

| 检查项 | 结果 |
|---|---|
| apiserver 证书 SAN 是否含 VIP | ✅ 含 `IP Address:10.0.0.168`（同时含 `10.0.0.61/120/121`、`127.0.0.1`、`10.96.0.1`） |
| kube-vip 是否 3 控制面齐备 | ✅ 3/3 Running（m01 / master01 / master02） |
| VIP 实际归属 | ✅ 在 **master01（10.0.0.121）eth0**，`10.0.0.168/24 secondary` |
| VIP 可访问性 | ✅ `admin.conf`（走 VIP）`kubectl` 正常，`/healthz` = ok |
| 每台 worker：旧 server 出现次数 | ✅ 恰好 1 处（保证单行替换不误伤） |
| 每台 worker：`current-context` | ✅ `default-context` |
| 每台 worker：CA 数据存在 | ✅ 存在 |

---

## 四、变更内容（逐台，单行 diff）

每台均先 `cp -a` 原地备份，再单行替换，最后重启 kubelet。以 worker01 为例：

```diff
5c5
<     server: https://10.0.0.61:6443
---
>     server: https://10.0.0.168:6443
```

实际命令（脚本 `/root/planA-switch-worker.sh`）：

```bash
cp -a /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.planAbak.<TS>
sed -i 's|https://10.0.0.61:6443|https://10.0.0.168:6443|' /etc/kubernetes/kubelet.conf
systemctl restart kubelet
```

> 注：kubelet **不热加载** kubeconfig（历史实测），必须重启 kubelet 才生效。

---

## 五、变更后验证

### 5.1 节点与工作负载

```
NAME       STATUS                     ROLES           AGE    VERSION
m01        Ready,SchedulingDisabled   control-plane   268d   v1.35.9
master01   Ready                      control-plane   268d   v1.35.9
master02   Ready                      control-plane   268d   v1.35.9
worker01   Ready                      <none>          268d   v1.35.9
worker02   Ready                      <none>          268d   v1.35.9
worker03   Ready                      <none>          268d   v1.35.9
```

- 全命名空间非 `Running/Completed` 的 Pod：**空**（无异常工作负载）。
- 集群 `/healthz`：**ok**。
- 三台 worker 上 kubelet 到 `:6443` 的连接：**全部指向 `10.0.0.168:6443`**（VIP）；到 `10.0.0.61:6443` 的 kubelet 连接为 **0**。
- 身份自证（用改后的 kubelet.conf）：`system:node:worker0X`（`system:nodes` 组），端点连通性 OK。

### 5.2 变更前后对照文件

备份目录：`/root/kube-vip-planA-backup-20261012-165306/`

```
kubelet.conf.worker01.BEFORE / .AFTER
kubelet.conf.worker02.BEFORE / .AFTER
kubelet.conf.worker03.BEFORE / .AFTER
```

节点上原地备份：`/etc/kubernetes/kubelet.conf.planAbak.20261012-165401|165422|165434`

---

## 六、遗留项（方案 A 范围之外，未改动）

方案 A 只覆盖 worker 的 kubelet。分析报告仍列出的以下问题**本次未处理**，单点风险尚未完全消除：

| # | 事项 | 现状 | 建议 |
|---|---|---|---|
| 1 | **kube-proxy 仍统一连 m01** | 实测各节点 `kube-proxy` 仍 ESTAB 到 `10.0.0.61:6443`（来自 `kube-system/kube-proxy` configmap） | 把该 configmap 的 `server` 改为 `https://10.0.0.168:6443`，再滚动重启 kube-proxy DaemonSet |
| 2 | `kubeadm-config` 的 `controlPlaneEndpoint` 仍是 `10.0.0.61:6443` | 未来 `kubeadm join` / 升级会继续生成指向 m01 的 kubeconfig | 改为 VIP `10.0.0.168:6443` |
| 3 | worker/master 的 `kubelet.conf` 中含无 CA 的 `kubernetes` 死条目 | 未被 `current-context` 引用，无实际影响；现与 `default-cluster` 同为 VIP，冗余 | 后续整理时可删除该条目 |
| 4 | m01 处于 `SchedulingDisabled` 却曾是全集群唯一 API 入口 | 本方案已让 worker kubelet 摆脱该单点；kube-proxy 仍依赖 | 处理完第 1 项后即可彻底闭环 |

---

## 七、回滚方法（如需）

```bash
# 单台回滚（以 worker01 为例）
ssh root@10.0.0.122
cp -a /etc/kubernetes/kubelet.conf.planAbak.20261012-165401 /etc/kubernetes/kubelet.conf
systemctl restart kubelet
```

或从本机备份目录恢复：

```bash
sshpass -p '****' scp /root/kube-vip-planA-backup-20261012-165306/kubelet.conf.worker01.BEFORE \
    root@10.0.0.122:/etc/kubernetes/kubelet.conf
sshpass -p '****' ssh root@10.0.0.122 'systemctl restart kubelet'
```

---

## 八、一句话总结

> 已按方案 A 将 **worker01/02/03 的 kubelet** 从 m01 单点（`10.0.0.61`）切到 **VIP `10.0.0.168`**（保留 CA 的最小改动），6/6 节点 Ready、Pod 正常、kubelet 实际连接均已走 VIP；**kube-proxy 与 `controlPlaneEndpoint` 仍指向 m01，属下一步收尾项**。
