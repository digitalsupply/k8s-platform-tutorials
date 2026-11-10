#!/usr/bin/env python3
"""只读识别“孤儿 PV”：Released/Failed 且没有对应 PVC（或 UID 不一致）。

依赖 python3 + kubectl。不会删除任何资源。

用法：
    python3 find_orphan_pv.py
    python3 find_orphan_pv.py --format json
"""
import argparse
import json
import subprocess
import sys


def kget(args):
    p = subprocess.run(["kubectl"] + args + ["-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return json.loads(p.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=("table", "json"), default="table")
    args = ap.parse_args()

    pvs = kget(["get", "pv"])["items"]
    pvcs = kget(["get", "pvc", "-A"])["items"]
    claims = {(i["metadata"]["namespace"], i["metadata"]["name"]): i["metadata"]["uid"]
              for i in pvcs}

    rows = []
    for pv in pvs:
        meta = pv["metadata"]
        phase = pv.get("status", {}).get("phase", "Unknown")
        ref = pv.get("spec", {}).get("claimRef") or {}
        ns, name, uid = ref.get("namespace"), ref.get("name"), ref.get("uid")
        if phase not in ("Released", "Failed"):
            continue
        current = claims.get((ns, name)) if ns and name else None
        if current is None:
            reason = "PVC 不存在"
        elif uid and current != uid:
            reason = "同名 PVC 但 UID 不一致"
        else:
            reason = "同名 PVC UID 一致（需人工确认）"
        rows.append({
            "pv": meta["name"],
            "phase": phase,
            "capacity": pv.get("spec", {}).get("capacity", {}).get("storage", ""),
            "storage_class": pv.get("spec", {}).get("storageClassName", ""),
            "claim": f"{ns}/{name}" if ns and name else "",
            "reason": reason,
            "volume_handle": pv.get("spec", {}).get("csi", {}).get("volumeHandle", ""),
        })

    if args.format == "json":
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    if not rows:
        print("没有发现 Released/Failed PV。")
        return
    print(f"{'PV':<45} {'状态':<10} {'容量':<8} {'StorageClass':<15} {'原 PVC':<40} 判定")
    print("-" * 150)
    for r in rows:
        print(f"{r['pv']:<45} {r['phase']:<10} {r['capacity']:<8} "
              f"{r['storage_class']:<15} {r['claim']:<40} {r['reason']}")
    print()
    print("注意：删除前还要确认 Ceph 侧 watchers=none、无快照依赖、备份可用。")
    print("删除顺序：先 kubectl delete pv，再 rbd rm <image>。")


if __name__ == "__main__":
    main()
