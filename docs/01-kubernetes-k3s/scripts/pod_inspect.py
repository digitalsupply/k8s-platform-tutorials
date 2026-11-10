#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pod 运行时透视：Pod UID / sandbox / 容器 / PID / cgroup。

这个脚本对应教程里“Pod 到底是怎么跑起来的”那一节。
它分两层工作：

1. 只用 kubectl：拿到 Pod UID、QoS、容器 ID、镜像、节点；
2. 如果能访问节点上的 crictl：进一步拿到 sandbox ID、容器 PID、cgroup 路径。

注意：crictl 需要在节点上以 root 运行；在 Pod 里通常没有权限。
"""

import argparse
import json
import shutil
import subprocess
import sys


def run(cmd):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        ).stdout.strip()
    except Exception as exc:  # noqa: BLE001
        return f"__ERROR__: {exc}"


def kubectl_json(args):
    raw = run(["kubectl", *args, "-o", "json"])
    if raw.startswith("__ERROR__") or not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def crictl_json(args):
    if not shutil.which("crictl"):
        return None
    raw = run(["crictl", *args, "-o", "json"])
    if raw.startswith("__ERROR__") or not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Inspect Pod UID / sandbox / container / PID / cgroup"
    )
    parser.add_argument("namespace")
    parser.add_argument("pod")
    parser.add_argument(
        "--node",
        help="可选：Pod 所在节点（crictl 通常需要在节点上执行；这里仅用于提示）",
    )
    args = parser.parse_args()

    pod = kubectl_json(["get", "pod", args.pod, "-n", args.namespace])
    if not pod:
        print(f"pod {args.namespace}/{args.pod} not found", file=sys.stderr)
        return 1

    md = pod["metadata"]
    spec = pod.get("spec", {})
    status = pod.get("status", {})

    print("=" * 72)
    print(f"Pod: {args.namespace}/{args.pod}")
    print(f"UID: {md.get('uid')}")
    print(f"Node: {spec.get('nodeName')}")
    print(f"QoS: {status.get('qosClass')}")
    print(f"Phase: {status.get('phase')}")
    print(f"PodIP: {status.get('podIP')}  HostIP: {status.get('hostIP')}")
    print("=" * 72)

    print("\n[containers]")
    for cs in status.get("containerStatuses", []) or []:
        print(f"- name: {cs.get('name')}")
        print(f"  containerID: {cs.get('containerID')}")
        print(f"  image: {cs.get('image')}")
        print(f"  ready: {cs.get('ready')}")
        print(f"  restartCount: {cs.get('restartCount')}")

    # 找 sandbox：crictl pods 的 metadata 里有 name/namespace/uid
    sandbox_id = None
    if shutil.which("crictl"):
        pods = crictl_json(["pods"])
        items = (pods or {}).get("items", [])
        for item in items:
            meta = item.get("metadata", {}) or {}
            if (
                meta.get("name") == args.pod
                and meta.get("namespace") == args.namespace
                and (meta.get("uid") in (None, md.get("uid")))
            ):
                sandbox_id = item.get("id")
                break
        if sandbox_id:
            print(f"\n[sandbox] id={sandbox_id}")
            inspect = crictl_json(["inspectp", sandbox_id])
            if inspect:
                print(json.dumps(inspect.get("status", {}), indent=2, ensure_ascii=False))
        else:
            print("\n[sandbox] not found via crictl pods")
    else:
        print("\n[sandbox] crictl not found; run this on the node as root")

    # 用 sandbox ID 找容器
    if sandbox_id and shutil.which("crictl"):
        ps = crictl_json(["ps", "--pod", sandbox_id])
        print("\n[containers via crictl]")
        for c in (ps or {}).get("containers", []):
            cid = c.get("id")
            meta = c.get("metadata", {}) or {}
            print(f"- {meta.get('name')}  id={cid}")
            inspect = crictl_json(["inspect", cid])
            if inspect:
                st = inspect.get("status", {}) or {}
                info = inspect.get("info", {}) or {}
                runtime = info.get("runtimeSpec", {}) or {}
                linux = runtime.get("linux", {}) or {}
                print(f"  pid: {st.get('pid')}")
                print(f"  cgroupsPath: {linux.get('cgroupsPath')}")
                print(f"  namespaces: {json.dumps(linux.get('namespaces', []), ensure_ascii=False)}")
                print(f"  image: {st.get('imageRef')}")

    print("\n提示：")
    print("- 容器内 PID 1 是命名空间视角；宿主机 PID 看 crictl inspect 的 status.pid")
    print("- 同 Pod 容器共享网络命名空间；sandbox 持有 netns")
    print("- cgroup 路径通常包含 Pod UID 和容器 ID")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
