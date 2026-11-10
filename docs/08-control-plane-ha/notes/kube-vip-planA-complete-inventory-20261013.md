# kube-vip / API Server 访问关系：方案 A 完整执行清单与现状盘点

> 依据：`/root/kube-vip-apiserver-analysis.md`（第 7.4 节 方案 A）及 `/root/kube-vip-planA-execution-report-20261012.md` 的遗留项
> 集群：6 节点（3 control-plane + 3 worker），kube-vip v1.2.4（ARP/L2），K8s v1.35.9，iptables 模式
> VIP：`10.0.0.168:6443`，当前持有者 **master01（10.0.0.121）**
> 执行时间：2026-10-12 ~ 2026-10-13　方式：逐台/滚动变更，变更前均备份

---

## 一、总体结论

✅ **HA 入口闭环完成。** worker 的 kubelet 与全集群 kube-proxy 已统一改走 VIP `10.0.0.168:6443`，`kubeadm-config` 未来入口也改为 VIP。
集群 **6/6 节点 Ready**、无异常 Pod、`/healthz` = ok、VIP 稳定在 master01。

| 项目 | 状态 |
|---|---|
| worker kubelet → VIP | ✅ 已切（方案 A 主体，2026-10-12） |
| 全集群 kube-proxy → VIP | ✅ 已切（2026-10-13） |
| `kubeadm-config.controlPlaneEndpoint` → VIP | ✅ 已改（2026-10-13，面向未来 join/升级） |
| 前置校验（VIP 证书 SAN / kube-vip 健康） | ✅ 通过 |
| 遗留：`kubelet.conf` 无 CA 死条目清理 | ⚠️ 未做（无功能影响，见 §5） |

---

## 二、完整变更清单（本次全部改动）

| # | 日期 | 对象 | 位置 | 变更前 | 变更后 | 生效方式 | 备份 |
|---|---|---|---|---|---|---|---|
| 1 | 2026-10-12 | worker01 kubelet | `/etc/kubernetes/kubelet.conf` | `server: https://10.0.0.61:6443` | `server: https://10.0.0.168:6443` | `systemctl restart kubelet` | 见 §6 |
| 2 | 2026-10-12 | worker02 kubelet | 同上 | 同上 | 同上 | 同上 | 见 §6 |
| 3 | 2026-10-12 | worker03 kubelet | 同上 | 同上 | 同上 | 同上 | 见 §6 |
| 4 | 2026-10-13 | kube-proxy 集群配置 | `kube-system/kube-proxy` ConfigMap → `data.kubeconfig.conf` | `server: https://10.0.0.61:6443` | `server: https://10.0.0.168:6443` | `rollout restart ds/kube-proxy`（6/6 滚动） | 见 §6 |
| 5 | 2026-10-13 | kubeadm 集群配置 | `kube-system/kubeadm-config` ConfigMap → `data.ClusterConfiguration` | `controlPlaneEndpoint: 10.0.0.61:6443` | `controlPlaneEndpoint: 10.0.0.168:6443` | 即时（供 join/升级读取） | 见 §6 |

> ⚠️ **对原方案 A 的一处修正**：原分析建议「把 context 切到文件里已有的 `kubernetes` 条目」。实测该条目**只有 server、没有 CA**，直接使用会 TLS 失败（`x509: certificate signed by unknown authority`）。故采用等效最小改动——**保留 `default-cluster` 的 CA，仅把其 `server` 单行改为 VIP**。

---

## 三、当前「谁连谁」完整清单（变更后现状）

| 客户端 | 范围 | 访问的 API Server | 说明 |
|---|---|---|---|
| **手工 `kubectl` / 运维** (`admin.conf`) | 3 CP | **VIP `10.0.0.168:6443`** → 落到 master01 | HA 入口 ✅ |
| **kubelet** — m01 | m01 | `https://127.0.0.1:6443`（本机回环） | bootstrap 节点，保持回环 |
| **kubelet** — master01 | master01 | `https://10.0.0.121:6443`（本机） | kubeadm 默认 |
| **kubelet** — master02 | master02 | `https://10.0.0.120:6443`（本机） | kubeadm 默认 |
| **kubelet** — worker01/02/03 | 3 worker | **VIP `https://10.0.0.168:6443`** | ✅ 本次已切（原为 m01） |
| **kube-proxy**（全部 6 节点） | 6 | **VIP `https://10.0.0.168:6443`** | ✅ 本次已切（原全为 m01） |
| **kube-controller-manager.conf** | 各 CP | **本节点 IP**（m01→`.61`，master01→`.121`，master02→`.120`） | kubeadm 默认，本地绑定 |
| **kube-scheduler.conf** | 各 CP | **本节点 IP**（同上） | kubeadm 默认，本地绑定 |
| **super-admin.conf** | 仅 m01 | `https://10.0.0.61:6443`（真实 IP） | 保留的 break-glass 通道 |
| **普通业务 Pod（in-cluster）** | 全集群 | **Service ClusterIP `10.96.0.1:443`** → 负载均衡到 3 台 apiserver | 随机 1/3 分摊 |
| **kube-vip（数据面）** | 3 CP | `127.0.0.1:6443`（回环，cp_enable） | VIP 健康探测走本地 |
| **kube-apiserver** | 各 CP | 本机 etcd `https://127.0.0.1:2379` | 不访问其他 apiserver |

### 数据面示意（Pod → apiserver）

```
Pod → Service ClusterIP 10.96.0.1:443
        │ 命中本节点 kube-proxy 写入的 iptables 规则
        ▼
   random 1/3 → 10.0.0.61:6443  (m01)
   random 1/3 → 10.0.0.121:6443 (master01)
   random 1/3 → 10.0.0.120:6443 (master02)
```

---

## 四、验证证据（变更后）

### 4.1 节点与工作负载

```
NAME       STATUS                     ROLES           AGE    VERSION
m01        Ready,SchedulingDisabled   control-plane   269d   v1.35.9
master01   Ready                      control-plane   269d   v1.35.9
master02   Ready                      control-plane   269d   v1.35.9
worker01   Ready                      <none>          269d   v1.35.9
worker02   Ready                      <none>          269d   v1.35.9
worker03   Ready                      <none>          269d   v1.35.9
```

- 全命名空间非 `Running/Completed` Pod：**空**
- 集群 `/healthz`：**ok**
- kube-vip：**3/3 Running**（m01 / master01 / master02）
- VIP 位置：master01 `eth0` → `inet 10.0.0.168/24 ... secondary`

### 4.2 连接实测（六节点 kube-proxy）

| 节点 | kube-proxy → VIP `10.0.0.168:6443` | kube-proxy → m01 `10.0.0.61:6443` |
|---|---|---|
| m01 | ✅ 1 | 0 |
| master01 | ✅ 1 | 0 |
| master02 | ✅ 1 | 0 |
| worker01 | ✅ 1 | 0 |
| worker02 | ✅ 1 | 0 |
| worker03 | ✅ 1 | 0 |

- worker kubelet（三台）：ESTAB → `10.0.0.168:6443`，到 m01 的 kubelet 连接为 **0**
- kube-proxy 日志：`"Caches are synced"`（service / endpoint slice / serviceCIDR），无错误

### 4.3 前置校验留档

- apiserver 证书 SAN 含 **`IP Address:10.0.0.168`**（另含 `10.0.0.61/120/121`、`127.0.0.1`、`10.96.0.1`）
- 方案 A 落地前的无损对照实测（worker01）：
  - `default-cluster` 保留 CA + server 改 VIP → ✅ `system:node:worker01`，`/healthz` ok
  - 直接切 `kubernetes` 条目（无 CA） → ❌ TLS `x509: certificate signed by unknown authority`

---

## 五、剩余 / 可选事项（未执行）

| # | 事项 | 现状 | 影响 | 建议 |
|---|---|---|---|---|
| 1 | `kubelet.conf` 中**无 CA 的 `kubernetes` 死条目** | master01 / master02 / worker01-03 各 1 条（`server=https://10.0.0.168:6443`，无 CA，未被 `current-context` 引用）；m01 的同名条目已是本机回环且生效 | 仅配置冗余，**无功能影响** | 可择期清理；涉及 kubelet 重启（控制面会重启静态 Pod），建议在维护窗口做 |
| 2 | CM / Scheduler 仍连**本节点** apiserver | kubeadm 默认行为 | 单节点本地故障时不自切（可接受） | 如追求极致 HA 可后续统一到 VIP |
| 3 | m01 仍为 `SchedulingDisabled`（已 cordon） | 非本次范围 | 不影响 API 入口（已用 VIP） | 视规划决定是否恢复调度 |
| 4 | `super-admin.conf` 仍指 `10.0.0.61`（真实 IP） | 有意保留的 break-glass 通道 | 无 | 建议保留 |

---

## 六、备份文件清单与回滚

### 6.1 备份位置

| 变更 | 备份目录 | 文件 |
|---|---|---|
| 变更 1–3（worker kubelet） | `/root/kube-vip-planA-backup-20261012-165306/` | `kubelet.conf.worker0{1,2,3}.BEFORE` / `.AFTER` |
| 变更 1–3（节点原地） | 各 worker 节点 | `/etc/kubernetes/kubelet.conf.planAbak.20261012-1654{01,22,34}` |
| 变更 4–5（kube-proxy / kubeadm-config） | `/root/kube-vip-planA-followup-backup-20261013-081319/` | `kube-proxy-cm-BEFORE.yaml` / `-AFTER.yaml`、`kubeadm-config-cm-BEFORE.yaml` / `-AFTER.yaml`、`kube-proxy-ds-BEFORE.yaml` / `-AFTER.yaml` |

### 6.2 回滚命令

```bash
# 回滚 1–3：worker kubelet（以 worker01 为例）
ssh root@10.0.0.122
cp -a /etc/kubernetes/kubelet.conf.planAbak.20261012-165401 /etc/kubernetes/kubelet.conf
systemctl restart kubelet

# 回滚 4：kube-proxy
kubectl -n kube-system replace -f /root/kube-vip-planA-followup-backup-20261013-081319/kube-proxy-cm-BEFORE.yaml
kubectl -n kube-system rollout restart ds/kube-proxy

# 回滚 5：kubeadm-config
kubectl -n kube-system replace -f /root/kube-vip-planA-followup-backup-20261013-081319/kubeadm-config-cm-BEFORE.yaml
```

---

## 七、一句话总结

> **控制面静态 Pod 各连本机 apiserver；worker 的 kubelet 与全集群 kube-proxy 已统一走 VIP `10.0.0.168`；`kubeadm-config` 入口也改为 VIP；业务 Pod 经 ClusterIP 负载均衡到 3 台 apiserver——m01 单点已在客户端侧消除。**
