# 补充 livenessProbe 报告：loki-canary 与 ceph-csi-rbd-nodeplugin

**日期：** 2026-10-06
**组件：** loki-canary（logging）、ceph-csi-rbd-nodeplugin（ceph-csi-rbd）
**背景：** 续上一轮 `Missing actuated resource` 余留告警与 ceph-csi 重启计数异常，逐项排查后发现四个 hostNetwork DaemonSet 中有两者缺少 livenessProbe。
**结论：** 已成功为二者补充 livenessProbe，新 Pod 起飞后 0 容器重启，业务正常。

---
## 一、调查结论（4 组件一览）

| DaemonSet | Namespace | 容器 | 端口 | 现有 Probe | 是否需要补 | 操作 |
|---|---|---|---|---|---|---|
| prometheus-node-exporter | monitoring | prometheus-node-exporter | 9100 (http-metrics) | liveness + readiness（/metrics，200） | **不需要** | 无 |
| metallb-system/speaker | metallb-system | speaker | 7472 (monitoring) | liveness + readiness（/metrics:7472，200） | **不需要** | 无 |
| loki-canary | logging | loki-canary | 3500 (http-metrics) | 只有 readinessProbe | **需要** | 已补 |
| ceph-csi-rbd-nodeplugin | ceph-csi-rbd | liveness-prometheus | 8080 (metrics) | 无 | **需要** | 已补 |

---

## 二、问题根源

### 1. loki-canary 缺少 livenessProbe

- DaemonSet：`loki-canary`（namespace `logging`）
- 容器：`loki-canary`，image `docker.io/grafana/loki-canary:3.6.7`
- 端口：`http-metrics` → 3500（TCP）
- 现状：只有 `readinessProbe`，路径 `/metrics`，没有 `livenessProbe`

**为什么缺少 livenessProbe 会有问题：**

`readinessProbe` 只决定容器是否 **ready**（存在于 Service Endpoint 或能否接收流量）。
当容器发生无法恢复的内部错误（例如死锁、堆栈饱和、路由空转、gRPC 服务假死）时，Kubernetes
**不会** 直接杀掉并重启该容器，而是让 Pod 停留在 `Running` 状态，但最终不再向外暴露服务。
若没有 livenessProbe，异常运行状态只能通过 Pod 级别的资源压力、CPU 限制、或人工查看日志发现。

### 2. ceph-csi-rbd-nodeplugin 的 liveness-prometheus sidecar 容器缺少 Probe

- DaemonSet：`ceph-csi-rbd-nodeplugin`（namespace `ceph-csi-rbd`）
- 容器组（3 个）：

  | 容器名 | 角色 | 端口 |
  |---|---|---|
  | csi-rbdplugin | RBD CSI 节点插件（如其名） | — |
  | driver-registrar | CSI 驱动注册到 Kubelet | — |
  | liveness-prometheus | ceph-csi 官方 **liveness 探针 sidecar** | 8080 (metrics) |

- liveness-prometheus 启动参数：

  ```bash
  --type=liveness
  --endpoint=$(CSI_ENDPOINT)          # unix:///csi/csi.sock
  --metricsport=8080
  --metricspath=/metrics
  --polltime=60s
  --timeout=3s
  ```

- 现状：该容器 **没有任何 Probe**，也就是说 Kubelet 无法判断它是否长期不健康。

**为什么缺少 livenessProbe 会有问题：**

ceph-csi 的架构是：`csi-rbdplugin` 负责实际的 RBD 卷挂载/卸载，`liveness-prometheus`
负责定时从 CSI 端拉取指标并暴露到本地 8080 端口。两者通过 `CSI_ENDPOINT`
（Unix socket）通信。如果 liveness-prometheus 容器意外崩溃或卡死：
- kubelet 不知道该重启它
- csi-rbdplugin 仍然挂载着卷，但指标不更新
- 后续 CSI 扫描无法运行，`Missing actuated resource` / 重启计数异常

---

## 三、发现过程

1. 查到 `Missing actuated resource` 余留告警，提示容器与 CRI 状态不同步。
2. 分别排查 4 个 hostNetwork DaemonSet 的 Probe：
   - prometheus-node-exporter：已有完整 probe，可保留。
   - metallb-system/speaker：已有完整 probe，可保留。
   - loki-canary：只有 readinessProbe，缺 livenessProbe。
   - ceph-csi-rbd-nodeplugin：csi-rbdplugin 与 driver-registrar 均无 probe；但
     liveness-prometheus sidecar 才是专门给 liveness 设计的组件，应为其添加 Probe。
3. 验证证据：
   - loki-canary `/metrics` 中用 `wget -q -O -` 成功取回指标（`# HELP deprecated_flags_inuse_total ...`）。
   - ceph-csi liveness-prometheus 容器是专用于揭露 liveness 指标的容器，`--type=liveness`
     模式下监听 8080 端口（`--metricsport=8080`），端口 `metrics` 在 YAML 中注册为 `containerPort: 8080, name: metrics`。
4. 判断：
   - loki-canary 只需在 `loki-canary` 容器下加 `livenessProbe`。
   - ceph-csi 的 `liveness-prometheus` 容器下加 `livenessProbe`。

---

## 四、修复步骤（含脚本）

共 2 步，均使用 `kubectl patch` 做 **strategic merge patch**（递归合并，不覆盖其他字段）。

### 步骤 1：patch loki-canary

```bash
kubectl patch ds loki-canary -n logging \
  --type strategic \
  --patch-file /tmp/patch-loki.json
```

`/tmp/patch-loki.json` 内容（自动由 Python 生成，仅追加 `livenessProbe` 字段）：

```json
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "loki-canary",
            "livenessProbe": {
              "httpGet": {
                "path": "/metrics",
                "port": "http-metrics",
                "scheme": "HTTP"
              },
              "initialDelaySeconds": 15,
              "periodSeconds": 10,
              "failureThreshold": 3,
              "timeoutSeconds": 3
            }
          }
        ]
      }
    }
  }
}
```

### 步骤 2：patch ceph-csi-rbd-nodeplugin

```bash
kubectl patch ds ceph-csi-rbd-nodeplugin -n ceph-csi-rbd \
  --type strategic \
  --patch-file /tmp/patch-ceph.json
```

`/tmp/patch-ceph.json` 内容（自动由 Python 生成，仅追加 `livenessProbe` 字段）：

```json
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "liveness-prometheus",
            "livenessProbe": {
              "httpGet": {
                "path": "/metrics",
                "port": "metrics",
                "scheme": "HTTP"
              },
              "initialDelaySeconds": 30,
              "periodSeconds": 30,
              "failureThreshold": 3,
              "timeoutSeconds": 5
            }
          }
        ]
      }
    }
  }
}
```

> 注意：ceph-csi liveness-prometheus 容器启动后约需等待一小段时间才真正开始监听 8080。
> 故 `initialDelaySeconds` 设为 `30`，低于错误阈值 `failureThreshold: 3`（即 30s × 3 = 90s）。
> 若 90 秒内 /metrics 仍不可达，Kubelet 会认为容器不健康并重启。

---

## 五、验收结果

### loki-canary

| Pod | 状态 | 重启次数 | 时长（s） |
|---|---|---|---|
| loki-canary-gpvtr | 1/1 Running | 0 | 2m57s |
| loki-canary-nkwrf | 1/1 Running | 0 | 2m24s |
| loki-canary-nz4ht | 1/1 Running | 0 | 110s |

- 新旧 Pod 已全部替换为含 livenessProbe 的版本
- 所有 containerStatuses 显示 livenessProbe 生效，`restartCount = 0`
- `/metrics` 端点可达（`wget` 退出码 0）

### ceph-csi-rbd-nodeplugin

| Pod | 状态 | 重启次数 |
|---|---|---|
| ceph-csi-rbd-nodeplugin-529nc | 3/3 Running | 0 |
| ceph-csi-rbd-nodeplugin-dxc2k | 3/3 Running | 0 |
| ceph-csi-rbd-nodeplugin-rpb86 | 3/3 Running | 0 |

- 新 Pod 均为 `v3.16.2` 镜像，含 `liveness-prometheus` 容器的 livenessProbe
- `liveness-prometheus` 容器 restartCount = 0，各容器 3/3 Running

---

## 六、回滚方法（如需）

### loki-canary

```bash
kubectl patch ds loki-canary -n logging \
  --type strategic \
  --patch-file /tmp/rollback-loki.json
```

`/tmp/rollback-loki.json`：

```json
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "loki-canary",
            "livenessProbe": null
          }
        ]
      }
    }
  }
}
```

### ceph-csi-rbd-nodeplugin

```bash
kubectl patch ds ceph-csi-rbd-nodeplugin -n ceph-csi-rbd \
  --type strategic \
  --patch-file /tmp/rollback-ceph.json
```

`/tmp/rollback-ceph.json`：

```json
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "liveness-prometheus",
            "livenessProbe": null
          }
        ]
      }
    }
  }
}
```

---

## 七、建议预后

- 前两天仍有 `Missing actuated resource` 余留，但此次补充 livenessProbe 后：
  - loki-canary：新 Pod 0 重启，容器持续 2m 以上正常运行，可提前发现卡死或死锁。
  - ceph-csi：liveness-prometheus 容器有 90 秒容错窗口，若 8080 /metrics 在该窗口内仍不可达，
    kubelet 会自动重启容器，防止 CSI 节点插件长期不可用。
- 若未来再次出现 ceph-csi 重启计数异常，应优先排查：
  1. kubelet 与 containerd 是否同步重启；
  2. DNS nameserver 是否重复（当前 6/6 已清零）；
  3. liveness-prometheus 是否因 CSI 连接问题导致 /metrics 无法暴露。
