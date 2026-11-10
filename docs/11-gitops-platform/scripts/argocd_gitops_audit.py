#!/usr/bin/env python3
"""ArgoCD GitOps 覆盖与漂移只读审计。

输出每个 Application 的 Sync/Health、源码仓库/路径、自动同步策略；
标记 OutOfSync/Degraded、未开 prune/selfHeal、没有 automated 的 App。

用法: python3 argocd_gitops_audit.py [--format md|json]
"""

import argparse
import json
import subprocess
import sys


def kube(args):
    r = subprocess.run(["kubectl"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["md", "json"], default="md")
    ap.add_argument("--argocd-ns", default="argocd")
    args = ap.parse_args()

    obj = kube(["-n", args.argocd_ns, "get", "applications.argoproj.io", "-o", "json"])
    apps = (obj or {}).get("items", [])

    rows, warnings = [], []
    for a in apps:
        spec = a.get("spec", {})
        src = spec.get("source") or (spec.get("sources") or [{}])[0]
        auto = (spec.get("syncPolicy", {}) or {}).get("automated", {}) or {}
        row = {
            "name": a["metadata"]["name"],
            "sync": a.get("status", {}).get("sync", {}).get("status"),
            "health": a.get("status", {}).get("health", {}).get("status"),
            "repoURL": src.get("repoURL"),
            "path": src.get("path"),
            "targetRevision": src.get("targetRevision"),
            "automated": bool(auto),
            "prune": auto.get("prune"),
            "selfHeal": auto.get("selfHeal"),
        }
        rows.append(row)
        if row["sync"] not in (None, "Synced") or row["health"] not in (None, "Healthy"):
            warnings.append(f"{row['name']}: {row['sync']}/{row['health']}")
        if not row["automated"]:
            warnings.append(f"{row['name']}: 未启用 automated sync")

    repos = sorted({r["repoURL"] for r in rows if r["repoURL"]})
    result = {
        "total": len(rows),
        "synced": sum(1 for r in rows if r["sync"] == "Synced"),
        "healthy": sum(1 for r in rows if r["health"] == "Healthy"),
        "automated": sum(1 for r in rows if r["automated"]),
        "repos": repos,
        "applications": rows,
        "warnings": warnings,
    }

    if args.format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    print("# ArgoCD GitOps 审计\n")
    print(f"- Application 总数: {result['total']}")
    print(f"- Synced: {result['synced']}；Healthy: {result['healthy']}；automated: {result['automated']}")
    print(f"- 仓库: {', '.join(repos) or '-'}")
    print()
    print("| Application | Sync | Health | Repo/Path | Automated | Prune | SelfHeal |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['name']} | {r['sync']} | {r['health']} | `{r['repoURL']}` / `{r['path']}` | "
              f"{r['automated']} | {r['prune']} | {r['selfHeal']} |")
    print()
    print("## 警告\n")
    if warnings:
        for w in warnings:
            print(f"- ⚠️ {w}")
    else:
        print("- 无")


if __name__ == "__main__":
    main()
