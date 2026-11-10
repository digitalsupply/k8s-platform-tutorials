#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按节点采集 Cilium BPF 数据面信息。

对应教程里的 BPF LB / ipcache / nodeid 分析。
它会：

1. 在指定节点找到 Cilium Pod；
2. 采集 bpf lb / ipcache / nodeid / status / endpoints；
3. 保存 Kubernetes 侧的 Service/Endpoint/Pod 快照，便于对照。

用法：
  python3 collect_cilium_bpf.py --node worker01 --out ./out
"""

import argparse
import json
import os
import shutil
import subprocess
import sys


def run(cmd, timeout=60):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=timeout
        )
    except Exception as exc:  # noqa: BLE001
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


def find_cilium_pod(node):
    res = run(
        [
            "kubectl",
            "-n",
            "kube-system",
            "get",
            "pods",
            "-l",
            "k8s-app=cilium",
            "--field-selector",
            f"spec.nodeName={node}",
            "-o",
            "json",
        ]
    )
    if res.returncode != 0:
        return None, res.stderr.strip()
    try:
        items = json.loads(res.stdout).get("items", [])
    except json.JSONDecodeError:
        return None, "invalid kubectl json"
    if not items:
        return None, f"no cilium pod on node {node}"
    return items[0]["metadata"]["name"], None


def main():
    parser = argparse.ArgumentParser(description="Collect Cilium BPF tables from a node")
    parser.add_argument("--node", required=True, help="node name, e.g. worker01")
    parser.add_argument("--out", default="./cilium-bpf", help="output directory")
    parser.add_argument("--namespace", default="kube-system")
    args = parser.parse_args()

    if not shutil.which("kubectl"):
        print("kubectl not found", file=sys.stderr)
        return 1

    pod, err = find_cilium_pod(args.node)
    if not pod:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    os.makedirs(args.out, exist_ok=True)
    print(f"node={args.node} cilium-pod={pod}")
    print(f"output={os.path.abspath(args.out)}")

    commands = {
        "bpf-lb.txt": ["cilium-dbg", "bpf", "lb", "list"],
        "bpf-ipcache.txt": ["cilium-dbg", "bpf", "ipcache", "list"],
        "bpf-nodeid.txt": ["cilium-dbg", "bpf", "nodeid", "list"],
        "status.txt": ["cilium-dbg", "status", "--verbose"],
        "endpoints.txt": ["cilium-dbg", "endpoint", "list"],
    }

    for filename, cmd in commands.items():
        res = run(
            [
                "kubectl",
                "-n",
                args.namespace,
                "exec",
                pod,
                "--",
                *cmd,
            ]
        )
        path = os.path.join(args.out, filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"$ {' '.join(cmd)}\n")
            f.write(f"# exit={res.returncode}\n\n")
            f.write(res.stdout)
            if res.stderr:
                f.write("\n[stderr]\n")
                f.write(res.stderr)
        print(f"wrote {path} (exit={res.returncode})")

    # Kubernetes 侧快照，方便对照 VIP/Endpoint/Pod IP
    snapshots = {
        "k8s-services.txt": ["get", "svc", "-A", "-o", "wide"],
        "k8s-endpoints.txt": ["get", "endpoints", "-A", "-o", "wide"],
        "k8s-pods.txt": ["get", "pods", "-A", "-o", "wide"],
    }
    for filename, cmd in snapshots.items():
        res = run(["kubectl", *cmd])
        path = os.path.join(args.out, filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"$ kubectl {' '.join(cmd)}\n\n")
            f.write(res.stdout)
            if res.stderr:
                f.write("\n[stderr]\n")
                f.write(res.stderr)
        print(f"wrote {path}")

    print("\n下一步：")
    print("- 用 bpf-lb.txt 找 VIP/端口/后端；")
    print("- 用 bpf-ipcache.txt 看 IP→identity/tunnelendpoint；")
    print("- 用 k8s-endpoints.txt 对照后端 Pod IP；")
    print("- 用 hubble observe / tcpdump 验证实际路径。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
