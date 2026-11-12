# K8s 3M3W + Ceph 磁盘占用分析与两轮清理执行记录

> **状态：历史快照（2026-10，K8s 1.29.8 / Calico / kube-proxy-IPVS）**
> 本文是当时的过程记录与命令，保留原样以便复盘；其中"当前"指当时的当前。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），**照本文排障前先看现状**：[current-state.md](../../00-cluster-overview/assets/current-state.md)。
> 审计记录见 [19 章](../../19-audit/README.md)。

> 环境：Proxmox VE 主机 `teacher`（192.168.2.156 / 10.0.0.1，931.5G NVMe）
> K8s：3 master（m01、master01、master02）+ 3 worker（worker01/02/03），v1.35.9，containerd 2.3.2
> Ceph：ceph-01/02/03（VM 116/117/118），Reef 18.2.8，6 OSD × 30G
> 记录日期：2026-11-05

---

## 0. 总体结论

| 层面 | 容量 | 优化前 | 优化后 | 释放 |
|---|---:|---:|---:|---:|
| Proxmox 根分区 `pve-root` | 94G | 47G (52%) | **42G (47%)** | 约 5G（CI PVC/日志等；Prometheus 21G 未变） |
| `local-lvm` 精简池 | 794.3G | 593.7G (74.77%) | **456.3G (57.45%)** | **约 137G** |
| K8s 节点根盘 | 38–57G/台 | 164G 合计 | 130G 合计（清理后） | 约 34G |
| Ceph 裸容量 | 180G | 20G (11.4%) | 20G (11.4%) | 容量不紧张，但 OSD 在精简池中占 180G |

两轮工作：

1. **第一轮**：清理 K8s 节点上的旧镜像和已完成 Pod。
2. **第二轮**：四项长效治理——kubelet 镜像 GC、Harbor tag 保留策略、Tekton PipelineRun 清理、VM discard + fstrim。

---

# 一、第一轮：清理 K8s 旧镜像与已完成 Pod

## 1.1 背景

K8s 节点根盘使用率：

| 节点 | 根盘 | 使用率 | containerd |
|---|---:|---:|---:|
| m01 | 47G | 49% | 4.0G |
| master01 | 48G | 39% | 2.6G |
| master02 | 38G | 42% | 2.4G |
| worker01 | 57G | 62% | 17G |
| worker02 | 57G | **69%** | 28G |
| worker03 | 57G | 67% | 26G |

其中 worker02/03 已接近 kubelet 默认镜像 GC 阈值 85%，但尚未触发。

同时全集群有：

- 246 个 Pod
- 110 个 Succeeded Pod
- 5 个 Failed Pod
- `cicd` 命名空间 107 个已完成 Tekton 任务 Pod

## 1.2 原因

### （1）CI 每次构建都产生新 tag

Tekton 流水线每次构建会把新 commit 推到 Harbor（`192.168.67.202:8443`），节点拉取后旧 tag 不会自动删除。

worker03 上堆积了 25 个旧 `deeptutor/deeptutor` tag，时间跨度 2026-10-27 至 11-03，合计约 21.5G；worker02 上还有 2 个 deeptutor tag 和约 20 个 compassio 旧 tag。

### （2）kubelet 默认只在磁盘 85% 时 GC

kubelet 默认：

```
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
```

节点在 60%–70% 时不会触发镜像回收，旧 tag 会持续堆积。

### （3）已完成 Pod 仍引用镜像

Succeeded/Failed 的 Pod 对象仍引用着镜像，kubelet 会认为镜像“仍在使用”，不会删除；同时这些 Pod 的日志、可写层也占空间。

## 1.3 原理

安全清理分两层：

1. **删除已完成的 Pod**
   - `kubectl delete pod` 删除 Succeeded/Failed 的 Pod；
   - kubelet 随后回收对应容器、可写层、日志；
   - 释放镜像引用，使镜像可被后续步骤删除。

2. **按“无任何容器引用”删除镜像**
   - 通过 `crictl images -o json` 和 `crictl ps -a -o json` 计算：
     - 镜像的 repoTag/repoDigest/imageID
     - 所有容器（Running + Exited）的 imageRef
   - 仅当镜像完全不被任何容器引用时才删除；
   - 运行中工作负载的镜像、`pause` 沙箱镜像、CI 工具小镜像保留。

> 注意：`crictl rmi --prune` 只删除 `<none>` 悬空镜像，worker03 上只能清约 110M，**清不掉 22G 的有 tag 旧镜像**。必须按 ID 显式删除。

## 1.4 分析数据

### 未被任何容器引用的镜像

| 节点 | 镜像数 | 逻辑大小 | 主要内容 |
|---|---:|---:|---|
| worker03 | 32 | **22.0 GiB** | 25 个 deeptutor tag（约 21.5G）、compassio frontend/backend 旧 tag、`<none>` |
| worker02 | 35 | 5.4 GiB | 2 个 deeptutor（各 1.3G）、约 9 个 backend（各 204M）、约 9 个 frontend（各 26M） |
| worker01 | 4 | 0.6 GiB | kafka 380M、compassio backend 186M、frontend 25M、pause |
| m01 | 15 | 0.4 GiB | 小块旧镜像 |
| 合计 | — | **约 28 GiB** | — |

### worker03 当前正在使用的 deeptutor 镜像

```
192.168.67.202:8443/deeptutor/deeptutor:57a5b316d17998c2ccf08500dd36fe18b3a8367e
```

该 tag 必须保留，其余旧 tag 可删。

### 已完成 Pod 引用的镜像

| 镜像 | 引用次数 | 单镜像大小 |
|---|---:|---:|
| `alpine/git:v2.45.2` | 58 | 约 33M |
| `compassio/buildkit:v0.20.2-rootless` | 26 | 约 99M |
| `deeptutor/git:v2.45.2` | 22 | 约 32M |
| `busybox:1.36` | 3 | 约 2M |
| `compassio/python:3.11-slim` | 1 | 约 47M |

这些工具镜像本身很小，删 Pod 的主要收益是日志和容器可写层，不是那 22G 业务旧镜像。

## 1.5 执行命令

### 1.5.1 删除已完成/失败 Pod

```bash
kubectl delete pods -A --field-selector=status.phase=Succeeded --wait=false
kubectl delete pods -A --field-selector=status.phase=Failed --wait=false

# 验证
kubectl get pods -A --no-headers | wc -l
kubectl get pods -A --field-selector=status.phase=Succeeded --no-headers | wc -l
```

### 1.5.2 计算并删除未被引用的镜像

在目标节点执行：

```bash
python3 - <<'PY' > /tmp/unused_images.txt
import json, subprocess
imgs = json.loads(subprocess.check_output(["crictl","images","-o","json"]))["images"]
ctrs = json.loads(subprocess.check_output(["crictl","ps","-a","-o","json"]))["containers"]
refs = set()
for c in ctrs:
    refs.add(c.get("imageRef",""))
    im = c.get("image") or {}
    refs.add(im.get("image",""))
    refs.add(im.get("imageRef",""))
for i in imgs:
    mine = set(i.get("repoTags",[])) | set(i.get("repoDigests",[])) | {i.get("id")}
    if not (mine & refs):
        print(i["id"], int(i.get("size",0))//2**20, ",".join(i.get("repoTags") or ["<none>"]))
PY

# 人工核对，确认不包含运行中的 tag
cat /tmp/unused_images.txt

# 删除（删除前可再次确认）
awk '{print $1}' /tmp/unused_images.txt | xargs -r crictl rmi
```

本次实际使用的脚本额外保留了：

```
pause、alpine/git、deeptutor/git、buildkit、python:3.11-slim、busybox
```

避免 CI 每次重新拉取小工具镜像。

## 1.6 结果

| 节点 | 清理前 | 清理后（当次） |
|---|---:|---:|
| worker03 | 36G / 66% | **21G / 38%** |
| worker02 | 38G / 69% | **21G / 39%** |
| worker01 | 34G / 62% | 33G / 60% |
| master01 | 18G / 39% | 18G / 39% |
| master02 | 15G / 42% | 15G / 42% |
| m01 | 23G / 49% | 22G / 47% |
| **合计** | **164G** | **130G** |

- Pod：246 → 131（删除 115 个：110 Succeeded + 5 Failed）
- 镜像：删除 82 个，逻辑大小约 28 GiB
- 节点根盘实际释放约 34G（包含已完成 Pod 的日志、可写层）

## 1.7 注意事项

- 删除已完成 Pod 会丢失 K8s 中保留的 Pod 日志（若 Alloy/Loki 已采集，Loki 中仍有）。
- 旧 tag 在 Harbor 中仍可重新 pull（本次清理时 Harbor 可用）。
- 本次保留：运行中镜像、pause、CI 工具镜像。
- 后续必须配合 kubelet GC 和 Harbor 保留策略，否则会再次堆积。

---

# 二、第二轮：四项长效治理

## 2.1 kubelet 镜像 GC

### 背景/原因

第一轮清理后，如果仍使用默认 85% 阈值，节点会再次堆积旧镜像。需要：

- 提前到 70% 触发；
- 增加按时间回收（30 天未使用）；
- 保留最近 24 小时的镜像，避免刚拉取的镜像被误删。

### 原理

kubelet 配置：

```
imageGCHighThresholdPercent: 70
imageGCLowThresholdPercent: 60
imageMinimumGCAge: 24h
imageMaximumGCAge: 720h
```

- 磁盘 ≥70% 开始 GC；
- GC 到 60% 停止；
- 只回收超过 24h 未使用的镜像；
- `imageMaximumGCAge: 720h` 会回收超过 30 天的未使用镜像（即使磁盘未到 70%）。

### 执行命令

在每台节点执行：

```bash
CFG=/var/lib/kubelet/config.yaml
cp -f "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"

sed -i -E '/^imageGCHighThresholdPercent:/d;/^imageGCLowThresholdPercent:/d;/^imageMinimumGCAge:/d;/^imageMaximumGCAge:/d' "$CFG"

cat >> "$CFG" <<'EOF'
imageGCHighThresholdPercent: 70
imageGCLowThresholdPercent: 60
imageMinimumGCAge: 24h
imageMaximumGCAge: 720h
EOF

systemctl restart kubelet
systemctl is-active kubelet
```

验证：

```bash
for n in m01 master01 master02 worker01 worker02 worker03; do
  echo "== $n"
  kubectl get --raw /api/v1/nodes/$n/proxy/configz 2>/dev/null \
  | python3 -c "import json,sys;k=json.load(sys.stdin).get('kubeletconfig',{});print(k.get('imageGCHighThresholdPercent'),k.get('imageGCLowThresholdPercent'),k.get('imageMinimumGCAge'),k.get('imageMaximumGCAge'))"
done
```

### 结果

6 台节点全部生效：

```
70 60 24h0m0s 720h0m0s
```

所有节点保持 Ready。

---

## 2.2 Harbor tag 保留策略

### 背景

Harbor v2.14.5 的 retention API 不是旧版的
`/api/v2.0/projects/{project}/retention/policies`，而是：

- 全局策略：`/api/v2.0/retentions`
- 项目通过 `metadata.retention_id` 关联策略
- 策略 body 必须包含 `scope` 和 `trigger`，否则 Harbor 2.14.5 会在 `retention.go:409` panic（HTTP 500）

现有项目：

| 项目 | retention_id | 原规则 |
|---|---:|---|
| openwebui | 1 | cache 保留 3 个 |
| compassio | 2 | backend/frontend 保留 10 个，cache 保留 15 个 |
| deeptutor | 无 | 无策略 |

### 目标

- `compassio`：backend/frontend/cache 保留最近 **5** 个；buildkit/nginx/node/python 永久保留。
- `deeptutor`：所有仓库保留最近 **5** 个。
- 每天北京时间 03:00 执行。

### 原理

Harbor retention 规则：

- `template: latestPushedK`：按 push 时间保留最新 K 个 artifact。
- `scope_selectors.repository`：匹配仓库名（`**` 表示所有仓库）。
- `tag_selectors`：匹配 tag（`**` 表示所有 tag）。
- `trigger.kind: Schedule` + cron：定时执行。
- `scope.level: project` + `scope.ref: <project_id>`：作用项目。

### 执行命令

```bash
set -a; . /root/openwebuicicd/.secrets/env.sh; set +a
BASE="$HARBOR_URL/api/v2.0"
AUTH=(-u "$HARBOR_USER:$HARBOR_PASS")
```

#### （1）更新 compassio 策略 2

先取原策略，修改 backend/frontend/cache 的 `latestPushedK` 为 5，保留其他 always 规则：

```bash
curl -sk "${AUTH[@]}" "$BASE/retentions/2" -o /tmp/ret2.json

python3 - <<'PY'
import json
d=json.load(open('/tmp/ret2.json'))
for r in d["rules"]:
    pats=[s.get("pattern") for s in r.get("scope_selectors",{}).get("repository",[])]
    if r.get("template")=="latestPushedK" and any(p in ("backend","frontend","cache") for p in pats):
        r.setdefault("params",{})["latestPushedK"]=5
json.dump(d,open('/tmp/ret2-new.json','w'))
PY

curl -sk -X PUT -H 'Content-Type: application/json' \
  --data @/tmp/ret2-new.json "${AUTH[@]}" "$BASE/retentions/2"
```

#### （2）创建 deeptutor 策略并挂载

```bash
cat > /tmp/ret-deeptutor.json <<'JSON'
{
  "algorithm": "or",
  "rules": [
    {
      "action": "retain",
      "template": "latestPushedK",
      "params": {"latestPushedK": 5},
      "scope_selectors": {"repository": [{"decoration": "repoMatches", "kind": "doublestar", "pattern": "**"}]},
      "tag_selectors": [{"decoration": "matches", "kind": "doublestar", "pattern": "**"}]
    }
  ],
  "trigger": {"kind": "Schedule", "settings": {"cron": "0 0 19 * * *"}},
  "scope": {"level": "project", "ref": 8}
}
JSON

curl -sk -X POST -H 'Content-Type: application/json' \
  --data @/tmp/ret-deeptutor.json "${AUTH[@]}" "$BASE/retentions"
# 返回 201，策略 ID 为 3（deeptutor 的 project_id 为 8）

curl -sk -X PUT -H 'Content-Type: application/json' \
  -d '{"metadata":{"public":"true","auto_scan":"true","retention_id":"3"}}' \
  "${AUTH[@]}" "$BASE/projects/8"
```

> cron `0 0 19 * * *` 是 UTC 19:00，即北京时间次日 03:00。

### 结果

| 项目 | retention_id | 规则 |
|---|---:|---|
| compassio | 2 | backend/frontend/cache 最近 5 个；buildkit/nginx/node/python always |
| deeptutor | 3 | 所有仓库最近 5 个 |

已验证：

- 项目 metadata 的 `retention_id` 正确；
- 策略 JSON 的 scope/trigger/rules 正确；
- 当前部署 tag `05f030ac`、`57a5b316` 都在最新 5 个内，不会被删；
- 下次执行时间：北京时间每天 03:00。

---

## 2.3 Tekton PipelineRun 清理

### 背景/原因

Tekton PipelineRun/TaskRun 完成后不会自动删除，Pod 和 workspace PVC 也会保留。长时间积累会占用 etcd、日志和 NFS 空间。

Tekton v1.6.0 的 `PipelineRun`/`TaskRun` CRD **没有** `ttlSecondsAfterFinished` 字段：

```bash
kubectl explain pipelinerun.spec.ttlSecondsAfterFinished
# error: field "ttlSecondsAfterFinished" does not exist
```

因此不能按字段设置 TTL。

### 原理

复用已有的 `cicd-cleanup` CronJob：

- 使用 ServiceAccount `cicd-cleanup`；
- 调用 K8s API 列出已完成 PipelineRun；
- 删除超过 `RETAIN_DAYS` 的 PipelineRun；
- K8s GC 级联删除 TaskRun → Pod → workspace PVC；
- 支持 `cleanup=keep` 标签/注解跳过。

原配置：

```
RETAIN_DAYS=7
schedule: 0 3 * * *
```

改为：

```
RETAIN_DAYS=1
schedule: 0 */6 * * *
```

### 执行命令

```bash
kubectl -n cicd patch cronjob cicd-cleanup --type=json -p='[
  {"op":"replace","path":"/spec/schedule","value":"0 */6 * * *"},
  {"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/env/0/value","value":"1"}
]'
```

Harbor 恢复后移除临时 nodeSelector：

```bash
kubectl -n cicd patch cronjob cicd-cleanup --type=json \
  -p='[{"op":"remove","path":"/spec/jobTemplate/spec/template/spec/nodeSelector"}]'
```

验证：

```bash
kubectl -n cicd get cronjob cicd-cleanup
kubectl -n cicd get jobs | grep cleanup
kubectl -n cicd get pipelineruns --no-headers | wc -l
kubectl -n cicd get pvc --no-headers | wc -l
```

### 结果

执行前：

- PipelineRun 35
- TaskRun 112
- cicd PVC 36

执行后：

- PipelineRun **3**（剩余均为 24h 内，按策略保留）
- TaskRun 随 PipelineRun 级联清理
- cicd PVC **4**

> 手动用 `kubectl create job --from=cronjob/...` 创建 Job 时，CronJob 控制器会把它当作 unexpected job 并回收，导致手动 Job Failed；实际由 CronJob 自己调度的 Job（`cicd-cleanup-29896560`）执行成功。以后直接等定时任务即可。

---

## 2.4 VM discard + fstrim

### 背景

Proxmox `local-lvm` 是 LVM thin pool，所有 VM 磁盘都是 thin LV。

K8s VM 虚拟机内实际使用约 165G，但 thin pool 给它们分配了 264.4G，差额约 99G。

原因：guest 内删除文件后，ext4 的 TRIM 没有传到 Proxmox。

验证：

- 在 master02 上执行 `fstrim -v /`，报告回收 7.6G；
- 但主机 `pvesm status` / `lvs data%` 完全不变；
- 说明 QEMU 没有把 discard 传给 thin LV。

### 原理

QEMU 默认不启用 discard。需要：

1. Proxmox VM 磁盘设置 `discard=on`；
2. 冷启动 VM（QEMU 进程重新加载磁盘参数）；
3. guest 内执行 `fstrim -av`，把 ext4 空闲块以 discard 传给 thin LV；
4. host thin pool 回收空间。

注意：

- **必须冷启动**（`qm shutdown` + `qm start`），guest 内 `reboot` 不会重新加载 QEMU 参数；
- ext4 会记录“已 trim 过”的块，所以要先改配置并冷启动，再执行 fstrim；
- 可选：guest 内 `/etc/lvm/lvm.conf` 设置 `issue_discards = 1`，主要影响 LV 删除/缩小场景，与 fstrim 无直接关系；
- 设置 `ssd=1` 让 guest 认为磁盘是 SSD，改善调度行为。

### 执行命令（逐台）

以 master02（VM 120）为例：

```bash
# 1) 查看当前 scsi0
qm config 120 | grep '^scsi0:'

# 2) 追加 discard=on,ssd=1
CUR=$(qm config 120 | awk -F': ' '/^scsi0:/{print $2}')
qm set 120 --scsi0 "$CUR,discard=on,ssd=1"

# 3) K8s 节点先 drain
kubectl drain master02 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s

# 4) 冷启动
qm shutdown 120 --timeout 240
qm start 120

# 5) 等待 SSH / Node Ready
# 6) guest 内 fstrim
ssh root@10.0.0.120 'fstrim -av; df -h /'

# 7) uncordon
kubectl uncordon master02
```

其余节点同理：

| VM | 节点 | IP |
|---|---|---|
| 119 | m01 | 10.0.0.61 |
| 120 | master02 | 10.0.0.120 |
| 121 | master01 | 10.0.0.121 |
| 122 | worker01 | 10.0.0.122 |
| 123 | worker02 | 10.0.0.123 |
| 124 | worker03 | 10.0.0.124 |

### worker01 的隔离重启

worker01 有 24 个镜像只在本地（grafana/loki/cert-manager/prometheus/n8n/frpc/gitlab-runner 等）。直接 drain 后 Pod 会移到 worker02/03，可能因镜像拉取失败而起不来。

采用“隔离重启”：

```bash
# 1) 先 cordon 其他所有节点
kubectl cordon worker02 worker03 master01 master02 m01

# 2) drain worker01，绕过 PDB
kubectl drain worker01 --ignore-daemonsets --delete-emptydir-data --force \
  --disable-eviction --timeout=300s

# 3) 冷启动 VM 122
qm shutdown 122 --timeout 240
qm start 122

# 4) 等待 SSH / Node Ready，然后 fstrim
ssh root@10.0.0.122 'fstrim -av; df -h /'

# 5) 先恢复 worker01，让 Pod 回到本地镜像
kubectl uncordon worker01
sleep 45

# 6) 再恢复其他节点
kubectl uncordon worker02 worker03 master01 master02 m01
```

这样 worker01 上的 Pod 只可能被调度回 worker01，使用本地镜像，避免 Harbor/上游镜像拉取问题。

### 结果

| VM | 节点 | 系统盘分配率（前 → 后） |
|---|---|---|
| 120 | master02 | 86.04% → **30.69%** |
| 124 | worker03 | 80.72% → **38.96%** |
| 123 | worker02 | 75.87% → **33.81%** |
| 121 | master01 | 85.54% → **30.39%** |
| 119 | m01 | 77.99% → **47.62%** |
| 122 | worker01 | 89.71% → **52.42%** |

精简池：

```
总容量  794.3 GiB
已用    593.7 GiB (74.77%) → 456.3 GiB (57.45%)
可用    200.4 GiB         → 338.0 GiB
实际释放约 137 GiB
```

fstrim 报告（guest 根分区，另含 /boot）：

| 节点 | fstrim 回收 |
|---|---:|
| master02 | 22.7 GiB |
| worker03 | 36.8 GiB |
| worker02 | 36.3 GiB |
| master01 | 29.8 GiB |
| m01 | 23.8 GiB |
| worker01 | 23.6 GiB |

> fstrim 报告的总量大于实际池释放量，因为部分空闲块本来就没有在 thin pool 中分配。

---

# 三、执行中的问题与恢复

## 3.1 Harbor 不可达导致镜像拉取失败

第二轮重启节点时，Harbor（192.168.67.202）和 GitLab（192.168.67.201）正好不可达，重新调度的 Pod 出现 ImagePullBackOff。

处理：

1. 从仍有镜像的节点通过 containerd 导出/导入补齐 **25 个镜像**：

```bash
# 源节点
ctr -n k8s.io images export --platform linux/amd64 /tmp/img.tar <image-ref>
# 目标节点
ctr -n k8s.io images import /tmp/img.tar
```

2. 重启 ceph-csi provisioner，RBD 卷恢复 `attached=True`；
3. 将 VPA/metrics 4 个 Pod 临时调度到有镜像的 worker02；
4. 清理 m01 上 Unknown 的 calico/alloy Pod，触发 DaemonSet 重建。

## 3.2 导入速度

实测 381MB 的 kafka 镜像导入耗时 **9 分 19 秒**，说明大批量镜像同步不适合临时操作；这也是 worker01 采用“隔离重启”而不是“先同步 24 个镜像”的原因。

## 3.3 m01 主机密钥变化

m01（10.0.0.61）的 SSH 主机密钥与 known_hosts 不一致，uptime 较短，疑似重建/恢复过。本次使用临时 known_hosts 连接，未修改系统记录，建议确认该 VM 是否为预期重装。

---

# 四、最终状态

```text
6 个节点全部 Ready
131 个 Pod Running / Ready
1 个 cicd-cleanup Job Pod Completed（正常）
无 Pending / ImagePullBackOff / Unknown

local-lvm:
  已用 456.3 GiB / 794.3 GiB = 57.45%
  可用 338.0 GiB

6 台 K8s VM 全部:
  scsi0 带 discard=on,ssd=1
  fstrim.timer enabled/active
```

关键工作负载均已恢复：grafana、loki、tempo、prometheus、alertmanager、cert-manager、argocd、tekton、kafka、pg16、compassio、deeptutor。

---

# 五、后续可选优化

1. **Ceph OSD 仍是精简池最大占用**
   - 6 × 30G = 180G 全部计费，而 Ceph 实际只存约 20G；
   - 可评估开启 OSD discard 或缩小 OSD 虚拟盘，最多还能释放约 150G。

2. **Prometheus**
   - 当前 15 天 / 25GiB，实际约 21G；
   - 可降为 7 天 / 10GiB，预计再释放约 10G。

3. **Ceph 副本与池**
   - 3 台 Ceph VM 在同一物理机，3 副本没有真实主机级容灾意义；
   - 可评估 pool size 3→2（+50% 可用容量）、清理空池 `default.rgw.*`、空 `rbd` 池、疑似未使用的 cephfs。

4. **Harbor**
   - 观察下一次 03:00 retention 执行结果；
   - 如不需要保留 5 个 tag，可进一步降到 3 个。

---

# 六、优化带来的影响评估（PVE / K8s / Ceph）

> 执行完成时精简池为 57.45% / 可用 338.0 GiB；当前实测 57.55% / 可用 337.2 GiB，属于新增镜像、日志和业务写入带来的正常小幅回升。

## 6.1 对 PVE 主机本身的影响

### （1）正面影响

| 项目 | 优化前 | 当前实测 | 影响 |
|---|---:|---:|---|
| 根分区 `pve-root` | 47G / 94G (52%) | 42G / 94G (**47%**) | 多出约 5G；主要来自 CI PVC/日志清理，PVE 自身更安全 |
| `local-lvm` 精简池 | 593.7G (74.77%) | **457.1G (57.55%)** | 释放约 136.6G，快照/新 VM/备份的回旋空间明显增加 |
| 精简池可用 | 200.4G | **337.2G** | 降低 thin pool 被写满导致 VM 冻结/只读的风险 |
| Swap 使用 | 3.7G / 8G | **0B** | 维护后内存压力明显缓解，主机不再持续换页 |
| 内存可用 | 约 4.3G | 约 8.5G | 多出的可用内存来自 VM 重启/负载重新分布后的状态改善 |
| fstrim.timer | 部分节点未启用 | 6 节点全部 enabled/active | 后续每周自动回收 guest 空闲块，抑制 thin pool 再次膨胀 |

其他正面影响：

- `discard=on` 让 thin LV 能持续收到 guest 的 TRIM，减少“已删除但主机仍占用”的死空间。
- 精简池空闲增加后，Proxmox 快照、`vzdump` 备份、临时克隆的成功率更高。
- 删除已完成 Pod/旧镜像后，节点侧 IO 压力降低，间接减少对同盘 Ceph OSD 的干扰。
- 本次没有修改 `/etc/pve/storage.cfg`、VG、thin pool 大小，PVE 存储结构保持原样，回退成本低。

### （2）负面影响 / 代价

1. **TRIM 的 IO 放大与碎片化**
   - `discard=on` + 周期性 `fstrim` 会在主机 NVMe 上产生短时 IO 峰值；
   - thin pool 的 chunk 释放后可能产生碎片，极端情况下影响后续大块连续写入；
   - 5 台 Ubuntu 节点 + m01（Rocky）的 `fstrim.timer` 默认/已启用，可能在同一时间触发，形成集中 IO 峰值。
   - 建议给各节点错峰：
     ```bash
     systemctl edit fstrim.timer
     # [Timer]
     # RandomizedDelaySec=3600
     ```
     或按节点设置不同的 `OnCalendar`。

2. **快照会阻止部分空间回收**
   - TRIM 只能释放“没有被快照共享”的 chunk；
   - VM119（m01）仍保留 `before_resize` 快照，快照共享的旧数据不会因 fstrim 释放；
   - 如需彻底回收，需要在确认无回滚需求后删除该快照。

3. **VM 冷启动带来的停机**
   - 每台 VM 需要 `qm shutdown` + `qm start` 才能让 `discard=on` 生效；
   - 单台停机约 2–5 分钟，K8s 节点还叠加了 drain/uncordon 和 Pod 重调度时间；
   - 如果维护窗口与 Proxmox 备份/快照任务重叠，可能导致备份失败或快照不一致，需要检查备份计划。

4. **thin pool 空闲不等于 VG 空闲**
   - 释放的 136G 在 `pve-data` thin pool 内部，`pve` VG 的 `VFree` 仍只有 16G；
   - 如果要创建新的**厚置备** LV，仍受 VG 空闲限制；
   - 新建 thin VM 磁盘不受影响。

5. **监控不能放松**
   - 57.55% 是“当前值”，镜像、日志、业务数据还会继续增长；
   - 建议继续监控 `pvesm status` / `lvs data%`，在 70%–75% 设置告警；
   - Ceph 的 180G OSD 仍按 99.99% 计费，是精简池的固定大占用项，不能把 57% 当成“永久安全线”。

6. **m01 SSH 主机密钥变化**
   - m01（10.0.0.61）的 SSH 主机密钥与旧 `known_hosts` 不一致，uptime 较短，疑似重建/恢复；
   - 本次使用临时 known_hosts 连接，未修改系统记录；
   - 属于运维/安全影响，建议确认该 VM 是否为预期重装。

## 6.2 对 K8s 集群的影响

### （1）正面影响

当前节点状态（实测）：

| 节点 | 根盘使用 | 内存（guest） | 说明 |
|---|---:|---:|---|
| m01 | 24G / 47G (51%) | 2.6G / 5.5G | 控制面 + 少量负载 |
| master01 | 18G / 48G (39%) | 2.1G / 5.8G | 控制面 |
| master02 | 15G / 38G (41%) | 2.3G / 3.8G | 内存仍偏紧（top 78%） |
| worker01 | 34G / 57G (62%) | 4.6G / 9.7G | 承载 grafana/loki/cert-manager 等 |
| worker02 | 22G / 57G (**40%**) | 3.1G / 9.7G | 原 69%，改善最明显 |
| worker03 | 25G / 57G (**46%**) | 1.4G / 7.8G | 原 67% |

- **DiskPressure 风险下降**：worker02/03 从 67%–69% 降到 40%–46%，短期不会再触发 kubelet 磁盘驱逐。
- **镜像增长被抑制**：
  - `imageGCHighThresholdPercent=70` 让 GC 更早介入；
  - `imageMaximumGCAge=720h` 会清理 30 天未使用镜像，避免再次堆积 20G+ 旧 tag；
  - 当前所有节点根盘均低于 70%，不会立即触发大规模 GC。
- **Tekton 对象和 NFS 压力下降**：
  - PipelineRun 35→3，TaskRun 级联清理，PVC 36→4；
  - etcd 中 Tekton 对象减少，Tekton Dashboard/备份体积下降；
  - NFS `/data/nfs` 上的 CI 工作区约减少 3G。
- **Pod 对象减少**：246→131，kubelet/API/etcd 的 Pod 管理开销下降。
- **集群健康**：6 节点 Ready，131 Pod Running/Ready，无 Pending/ImagePullBackOff/Unknown。

### （2）负面影响 / 代价

1. **节点重启导致的短暂服务中断**
   - 6 台 K8s VM 逐台冷启动，单台 2–5 分钟；
   - worker01 上的 grafana、loki、tempo、cert-manager、argocd、prometheus 等在重启窗口短暂不可用；
   - 有状态负载（loki、tempo、prometheus、pg16、kafka）发生 Pod 重启和卷重新挂载，恢复期有短暂 503/启动探针失败；
   - 当前均已恢复 Running/Ready。

2. **RBD 卷 attach/detach 抖动**
   - Pod 重调度触发大量 RBD VolumeAttachment 迁移；
   - 恢复期出现过 attach 超时、Multi-Attach 等待，ceph-csi provisioner 重启后恢复；
   - 当前所有 VolumeAttachment 均为 `attached=True`。

3. **worker01 隔离重启的副作用**
   - 为避免 24 个本地-only 镜像拉取失败，先 cordon 了其他 5 个节点；
   - 在 worker01 重启的 2–3 分钟内，新 Pod 无法调度，处于 Pending；
   - 使用 `--disable-eviction` 绕过 PDB，意味着 PDB 保护的负载也被直接删除；
   - 这是“计划内停机”的取舍，不是日常操作方式。

4. **已完成 Pod 删除导致日志/证据丢失**
   - K8s 中保留的 Pod 日志被删除；
   - 5 个 Failed CI Pod 的失败现场被删除；
   - 如果 Loki/Alloy 已采集，日志仍可在 Loki 中查询；
   - 对审计/排障有影响，建议后续对重要失败保留 `cleanup=keep` 或延长 Loki 保留。

5. **Tekton 历史缩短**
   - `RETAIN_DAYS=1` 后，超过 1 天的 PipelineRun/TaskRun 会被删除；
   - Tekton Dashboard/`tkn` 中看不到更早的执行历史；
   - 需要保留的发布记录应打 `cleanup=keep` 标签/注解。

6. **Harbor 保留策略的不可逆性**
   - 每个仓库只保留最近 5 个 tag；
   - 超过 5 个的旧 tag 在下次 03:00 执行后会被删除；
   - 回滚能力被限制在最近 5 个版本；
   - 重要版本应提前打额外 tag 或复制到其他仓库/归档。

7. **镜像 GC 的“再拉取”成本**
   - 70% 阈值 + 24h 最小年龄 + 30 天最大年龄，可能删除当前未使用但未来要用的镜像；
   - 如果 Pod 之后被调度到该节点，需要重新拉取；
   - Harbor 正常时影响很小；Harbor 故障时会变成 ImagePullBackOff 风险。

8. **对 Harbor 的依赖增强**
   - Harbor retention、`cicd-cleanup` CronJob 镜像、Pod 重拉镜像都依赖 Harbor；
   - Harbor 不可达时，节点重启/镜像 GC 后的 Pod 可能起不来；
   - 建议至少增加一个本地 registry mirror，或让 Harbor 具备 HA/备份。

9. **VPA/metrics 的落点变化**
   - metrics-server 和部分 VPA 副本被调度到 worker02；
   - 如果 worker02 故障，`kubectl top` 和 VPA 功能会受影响；
   - 属于可用性上的单点，不是数据风险。

10. **集群容量没有本质变化**
    - 本次释放的是磁盘，不是 CPU/内存；
    - master02 内存仍偏紧（4G，top 78%）；
    - Ceph RBD 仍存在“申请 143GiB / 实际可用约 49GiB”的超额分配风险。

## 6.3 对 Ceph 集群的影响

### （1）直接影响：基本没有

本次操作**没有**修改：

- Ceph OSD / OSD 磁盘
- pool / PG / CRUSH rule
- Ceph Monitor / MGR / RGW / MDS
- Ceph VM（116/117/118）的配置或系统盘

当前实测：

```text
health: HEALTH_OK
mon: 3 daemons, quorum ceph-02,ceph-03,ceph-01
mgr: ceph-02 active, ceph-01 standby
osd: 6 osds: 6 up, 6 in
rgw: 2 daemons active (2 hosts, 1 zones)
usage: 20 GiB used, 160 GiB / 180 GiB avail
pools: 15 pools, 465 pgs, all active+clean
k8s-rbd: 4.5 GiB stored, 14 GiB used (8.47%), max avail 49 GiB
```

因此：

- Ceph 容量、性能、副本策略均无直接变化；
- 本次释放的约 137G **全部来自 K8s VM 系统盘**，没有从 Ceph 回收空间；
- Ceph 的 6×30G OSD 仍然在 PVE 精简池中按 99.99% 计费（约 180G），这是精简池里最大的固定占用项。

### （2）间接影响

1. **共享 NVMe 的 IO 峰值**
   - K8s VM 冷启动、fstrim、Pod 重调度会产生主机 NVMe IO 峰值；
   - Ceph OSD 与 K8s VM 共用同一块 NVMe/thin pool，维护期间可能出现短暂 OSD 延迟抖动；
   - 当前 `HEALTH_OK`，无持续异常。

2. **RBD 客户端 attach/detach 增加**
   - K8s 节点重启导致 RBD 卷在节点间迁移；
   - 恢复期出现 attach 超时/重试，CSI provisioner 重启后恢复；
   - 对 Ceph 来说是一次短时客户端 IO/锁竞争，已恢复。

3. **Ceph 的架构风险没有改变**
   - 3 台 Ceph VM 全部在同一台物理机；
   - 3 副本提供的是“VM 级”冗余，不是“主机级”冗余；
   - 物理机/NVMe 故障仍会同时带走 K8s 和 Ceph。

4. **Ceph 容量规划风险仍在**
   - `k8s-rbd` 单池最大可用约 49GiB；
   - RBD 侧已申请约 143GiB（实际使用 6.5–14GiB），存在超额分配；
   - 本次清理没有增加 Ceph 可用容量，后续不要按大容量随意申请 PVC。

5. **OSD discard 仍未开启**
   - 如果要对 Ceph 的 180G 占用做进一步回收，需要单独给 OSD 磁盘开 `discard=on`，并评估 `bdev_enable_discard` / `bdev_async_discard`；
   - 这会带来 OSD IO 开销和潜在延迟，必须单独安排维护窗口，不能和本次 K8s 维护混在一起。

6. **Ceph quorum/mgr age 约 19h**
   - 当前 `ceph -s` 显示 mon quorum / mgr active age 约 19h；
   - 本次没有重启 Ceph VM，推测是此前主机内存压力/事件导致的重新选举；
   - 当前 HEALTH_OK，建议持续观察 mon/mgr 日志和主机内存。

## 6.4 影响汇总

| 层面 | 主要正面影响 | 主要负面影响/代价 | 是否可接受 |
|---|---|---|---|
| PVE | 精简池释放约 137G；根分区 +5G；Swap 3.7G→0；快照/备份空间更足 | fstrim IO 峰值/碎片化；快照阻止部分回收；VM 冷启动停机；thin pool 空闲不等于 VG 空闲 | 可接受，需错峰 fstrim 与监控 |
| K8s | 节点盘 67–69%→40–46%；镜像 GC 长效生效；Tekton/etcd/NFS 压力下降；246→131 Pod | 节点重启 2–5 分钟中断；RBD attach 抖动；已完成 Pod 日志丢失；Tekton 历史缩短；Harbor 依赖增强 | 可接受，需 Harbor 高可用/本地 mirror |
| Ceph | 无直接变更；HEALTH_OK；维护期未发生数据损坏 | 无容量回收；OSD 仍占 180G；共享 NVMe IO 抖动；3 副本无主机级容灾；RBD 超额分配 | 本次可接受，后续需单独优化 OSD/副本 |

## 6.5 影响缓解与后续动作

1. **PVE**
   - 给 `fstrim.timer` 增加 `RandomizedDelaySec` 或按节点错开；
   - 持续监控 thin pool 使用率，70%–75% 告警；
   - 确认 VM119 的 `before_resize` 快照是否还需要，必要时删除以彻底回收；
   - 检查 Proxmox 备份窗口是否与本次维护冲突，补一次备份校验。

2. **K8s**
   - Harbor 增加本地 mirror/HA，避免 Harbor 故障导致镜像拉取失败；
   - 重要 Tekton 执行打 `cleanup=keep`；
   - 重要失败 Pod 的日志确认已进入 Loki；
   - 观察 `imageMaximumGCAge` 生效后节点镜像数量，确认没有误删；
   - 监控 master02 内存（78%），必要时调整到 6G 或迁移负载；
   - 给 `cicd-cleanup` 增加失败告警，避免 Harbor/镜像问题导致静默失败。

3. **Ceph**
   - 单独评估 OSD 磁盘 `discard=on` + `bdev_enable_discard`，目标回收最多约 150G；
   - 评估 pool size 3→2（同一物理机下 3 副本无真实主机级容灾）；
   - 清理空池 `default.rgw.*`、空 `rbd` 池、疑似未使用的 cephfs；
   - 监控 `k8s-rbd` 实际使用与申请量，避免超额分配继续扩大；
   - 持续观察 mon/mgr quorum age、OSD 延迟和主机内存。

---

# 附录 A：可复用脚本

## A.1 删除无引用镜像

```bash
#!/bin/bash
# /root/cleanup_unused_images.sh
set -e
APPLY="${APPLY:-0}"

python3 - <<'PY'
import json, subprocess, os
imgs = json.loads(subprocess.check_output(["crictl","images","-o","json"]))["images"]
ctrs = json.loads(subprocess.check_output(["crictl","ps","-a","-o","json"]))["containers"]
refs=set()
for c in ctrs:
    refs.add(c.get("imageRef",""))
    im=c.get("image") or {}
    refs.add(im.get("image","")); refs.add(im.get("imageRef",""))

KEEP=("/pause:", "alpine/git:", "deeptutor/git:", "buildkit:",
      "python:3.11-slim", "busybox:")

cand=[]
for i in imgs:
    mine=set(i.get("repoTags",[]))|set(i.get("repoDigests",[]))|{i.get("id")}
    if mine & refs: continue
    cand.append(i)

total=sum(int(i.get("size",0) or 0) for i in cand)
print("candidates=%d logical=%.1f GiB"%(len(cand), total/2**30))
for i in sorted(cand,key=lambda x:-int(x.get("size",0) or 0)):
    tags=",".join(i.get("repoTags") or ["<none>"])
    print(i["id"], int(i.get("size",0) or 0)//2**20, tags)

if os.environ.get("APPLY")!="1":
    print("dry-run; set APPLY=1 to delete")
    raise SystemExit

for i in cand:
    tags=",".join(i.get("repoTags") or [])
    if any(k in tags for k in KEEP):
        print("KEEP", tags); continue
    if subprocess.run(["crictl","ps","-a","-q","--image",i["id"]],
                      capture_output=True,text=True).stdout.strip():
        print("SKIP in-use", i["id"][:19]); continue
    subprocess.run(["crictl","rmi",i["id"]])
PY
```

## A.2 kubelet GC 配置

```bash
#!/bin/bash
# /root/set_kubelet_gc.sh
set -e
CFG=/var/lib/kubelet/config.yaml
cp -f "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
sed -i -E '/^imageGCHighThresholdPercent:/d;/^imageGCLowThresholdPercent:/d;/^imageMinimumGCAge:/d;/^imageMaximumGCAge:/d' "$CFG"
cat >> "$CFG" <<'EOF'
imageGCHighThresholdPercent: 70
imageGCLowThresholdPercent: 60
imageMinimumGCAge: 24h
imageMaximumGCAge: 720h
EOF
systemctl restart kubelet
sleep 6
systemctl is-active kubelet
grep -E '^imageGC|^imageMaximum|^imageMinimum' "$CFG"
```

## A.3 VM discard + fstrim 单台脚本

```bash
#!/bin/bash
# /root/apply_discard.sh <vmid> <node> <ip>
set -euo pipefail
VMID=$1; NODE=$2; IP=$3
BK=/root/vm-conf-backup-$(date +%F)
mkdir -p "$BK"
cp -f "/etc/pve/qemu-server/$VMID.conf" "$BK/$VMID.conf.before-discard"

CUR=$(qm config "$VMID" | awk -F': ' '/^scsi0:/{print $2}')
if [[ "$CUR" != *discard=on* ]]; then
  qm set "$VMID" --scsi0 "$CUR,discard=on,ssd=1"
fi
qm config "$VMID" | grep '^scsi0:'

kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s
qm shutdown "$VMID" --timeout 240
qm start "$VMID"

SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4"
for i in $(seq 1 60); do $SSH root@"$IP" true 2>/dev/null && break; sleep 5; done
for i in $(seq 1 60); do
  s=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$s" == "True" ]] && break; sleep 5
done
kubectl get node "$NODE"

$SSH root@"$IP" 'fstrim -av; df -h / | tail -1'
kubectl uncordon "$NODE"
```

## A.4 worker01 隔离重启脚本

见 `/root/finish_worker01.sh`，核心步骤：

```bash
kubectl cordon worker02 worker03 master01 master02 m01
kubectl drain worker01 --ignore-daemonsets --delete-emptydir-data --force \
  --disable-eviction --timeout=300s
qm shutdown 122 --timeout 240
qm start 122
# 等待 SSH / Ready
ssh root@10.0.0.122 'fstrim -av'
kubectl uncordon worker01
sleep 45
kubectl uncordon worker02 worker03 master01 master02 m01
```

---

# 附录 B：关键验证命令

```bash
# 节点状态
kubectl get nodes

# Pod 状态
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c

# kubelet GC 配置
for n in m01 master01 master02 worker01 worker02 worker03; do
  echo -n "$n "
  kubectl get --raw /api/v1/nodes/$n/proxy/configz 2>/dev/null \
  | python3 -c "import json,sys;k=json.load(sys.stdin).get('kubeletconfig',{});print(k.get('imageGCHighThresholdPercent'),k.get('imageGCLowThresholdPercent'),k.get('imageMinimumGCAge'),k.get('imageMaximumGCAge'))"
done

# 精简池
pvesm status | grep local-lvm
lvs --noheadings -o lv_name,data_percent pve/data

# 各 VM 系统盘分配率
for v in 119 120 121 122 123 124; do
  printf "VM %-3s " $v
  lvs --noheadings -o data_percent pve/vm-$v-disk-0
done

# VM discard 配置
for v in 119 120 121 122 123 124; do
  printf "VM %-3s " $v
  qm config $v | awk -F': ' '/^scsi0:/{print $2}'
done

# Tekton 清理状态
kubectl -n cicd get cronjob cicd-cleanup
kubectl -n cicd get pipelineruns --no-headers | wc -l
kubectl -n cicd get pvc --no-headers | wc -l

# Harbor 保留策略
set -a; . /root/openwebuicicd/.secrets/env.sh; set +a
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/retentions/2" | python3 -m json.tool
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/retentions/3" | python3 -m json.tool
curl -sk -u "$HARBOR_USER:$HARBOR_PASS" "$HARBOR_URL/api/v2.0/projects/deeptutor" | python3 -c "import json,sys;print(json.load(sys.stdin)['metadata'])"
```
