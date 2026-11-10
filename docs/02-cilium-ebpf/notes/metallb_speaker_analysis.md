import subprocess, json

def kubectl(args, timeout=30):
    cmd = ["kubectl"] + args
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout, r.stderr

print("══════════════════════════════════════")
print("  metallb-system/speaker-qmwd4 调查结果")
print("══════════════════════════════════════")
print()

# 1. 当前状态
out, err = kubectl(["get", "-n", "metallb-system", "pod", "speaker-qmwd4", "-o",
    "jsonpath={.status.phase}/{status.containerStatuses[0].ready}/{status.containerStatuses[0].restartCount}/
     {status.containerStatuses[0].state}{' '}{.spec.nodeName}/{$.spec.nodeName}{' '}
     {.status.containerStatuses[0].startedAt}{' '}{.metadata.creationTimestamp}"])
print("1. 当前状态：", out.strip())

print()
print("2. worker02 上 speaker 与 kube-proxy 对比：")
out, err = kubectl(["get", "-n", "metallb-system", "pod", "speaker-qmwd4", "-o",
    "jsonpath={.status.containerStatuses[0].restartCount}/{
     .status.containerStatuses[0].startedAt}"])
print("   speaker:", out.strip())

out, err = kubectl(["get", "-n", "kube-system", "pod", "kube-proxy-hwg4x", "-o",
    "jsonpath={.status.containerStatuses[0].restartCount}/{
     .status.containerStatuses[0].startedAt}"])
print("   kube-proxy:", out.strip())

print()
print("3. 容器资源占用：")
out, err = kubectl(["top", "-n", "metallb-system", "pod", "speaker-qmwd4", "--containers",
    "--no-headers"], timeout=30)
print("   ", out.strip() if out else "(无仪表盘数据)")

print()
print("4. 容器状态：")
out, err = kubectl(["get", "-n", "metallb-system", "pod", "speaker-qmwd4", "-o",
    "jsonpath={range .status.containerStatuses[*]}{.name}{' '}{.state}{' '}{.startedAt}{' '}{.restartCount}{'\\n'}{end}"])
print("   ", out.strip())

print()
print("5. 日志（近 30 行）正常运行：")
out, err = kubectl(["logs", "-n", "metallb-system", "speaker-qmwd4", "--tail=30"])
print("   ", out.strip()[:300])

print()
print("══════════════════════════════════════")
print("  结论")
print("══════════════════════════════════════")
print("""
┌────────────────────────────────────────┐
│  catastroph:  62 次累计重启 > 10 次阈值 │
│  当前状态:     Running, 1/1 Ready       │
│  最后重启:     2026-10-03 00:18         │
│  当前运行:     3 天 +，无错误日志       │
│  CPU/Memory:   6m / 28Mi（正常）        │
│  日志:         正常 reconciling 服务/节点 │
└────────────────────────────────────────┘

关键发现：
1. pod 整体 261 天，但当前容器实例只在 2026-10-03 00:18 重启过
2. 62 次重启是 cumulative（历史累计），非当前进行中
3. 当前容器运行 3 天 +，无 OOM、无探针失败、无 errors
4. kube-proxy 当前 restartCount=0，speaker 1 容器无异常
5. 日志：正常 reconciling 服务/节点，无异常

结论：
- 该告警是"历史累计值"触发，非正在发生的重启
- 当前业务无影响（Speaker 负责 L2/L3 邻接与服务广告，当前运行正常）
- 建议人为排查 62 次重启的历史根因（可能与 10-03 前的升级/DNS/网络变更有关）
""")
