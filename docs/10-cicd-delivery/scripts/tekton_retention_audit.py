#!/usr/bin/env python3
"""Tekton 历史保留/清理只读审计。

统计 PipelineRun / TaskRun 的数量、状态、年龄，检查 TektonConfig Pruner 和旧 CronJob。
不删除任何资源。

用法: python3 tekton_retention_audit.py [--format md|json] [--days 30]
"""

import argparse
import datetime as dt
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


def items(obj):
    return (obj or {}).get("items", [])


def age_days(ts):
    if not ts:
        return None
    try:
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (dt.datetime.now(dt.timezone.utc) - t).days


def summarize(objs):
    phases, old = {}, 0
    for o in objs:
        st = o.get("status", {})
        cond = (st.get("conditions") or [{}])[-1].get("type", "Unknown")
        key = cond
        if o.get("status", {}).get("completionTime"):
            key = "Completed"
        phases[key] = phases.get(key, 0) + 1
    return phases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["md", "json"], default="md")
    ap.add_argument("--days", type=int, default=30)
    args = ap.parse_args()

    prs = items(kube(["get", "pipelinerun", "-A", "-o", "json"]))
    trs = items(kube(["get", "taskrun", "-A", "-o", "json"]))
    tcs = items(kube(["get", "tektonconfig", "-o", "json"]))
    cjs = items(kube(["-n", "cicd", "get", "cronjob", "-o", "json"]))

    old_prs = [p for p in prs if (age_days(p.get("metadata", {}).get("creationTimestamp")) or 0) > args.days]
    old_trs = [t for t in trs if (age_days(t.get("metadata", {}).get("creationTimestamp")) or 0) > args.days]

    pruner = None
    if tcs:
        pruner = tcs[0].get("spec", {}).get("pruner")
        pruner = pruner if pruner is not None else tcs[0].get("spec", {}).get("tektonpruner")

    warnings = []
    if len(prs) > 500:
        warnings.append(f"PipelineRun 数量 {len(prs)} > 500，建议开启/收紧 Pruner")
    if old_prs:
        warnings.append(f"超过 {args.days} 天的 PipelineRun: {len(old_prs)}")
    if not pruner:
        warnings.append("TektonConfig 未配置 pruner/tektonpruner")
    elif isinstance(pruner, dict) and pruner.get("disabled") is True:
        warnings.append("TektonConfig pruner.disabled=true，当前不会自动清理历史")
    if cjs:
        warnings.append("仍有自定义清理 CronJob: " + ", ".join(c["metadata"]["name"] for c in cjs))

    result = {
        "pipelineruns": {"total": len(prs), "olderThanDays": len(old_prs),
                         "phases": summarize(prs),
                         "namespaces": sorted({p["metadata"].get("namespace") for p in prs})},
        "taskruns": {"total": len(trs), "olderThanDays": len(old_trs)},
        "tektonConfig": [t["metadata"]["name"] for t in tcs],
        "pruner": pruner,
        "cleanupCronJobs": [c["metadata"]["name"] for c in cjs],
        "warnings": warnings,
    }

    if args.format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    print("# Tekton 历史保留审计\n")
    print(f"- PipelineRun: {len(prs)}（>{args.days} 天: {len(old_prs)}）")
    print(f"- TaskRun: {len(trs)}（>{args.days} 天: {len(old_trs)}）")
    print(f"- 命名空间: {', '.join(result['pipelineruns']['namespaces']) or '-'}")
    print(f"- TektonConfig: {', '.join(result['tektonConfig']) or '-'}")
    print(f"- 自定义清理 CronJob: {', '.join(result['cleanupCronJobs']) or '-'}")
    print()
    print("## PipelineRun 状态分布\n")
    print("| 状态 | 数量 |")
    print("|---|---|")
    for k, v in sorted(result["pipelineruns"]["phases"].items()):
        print(f"| {k} | {v} |")
    print()
    print("## Pruner 配置\n")
    print("```yaml")
    print(json.dumps(pruner, ensure_ascii=False, indent=2, default=str) if pruner else "# 未配置")
    print("```")
    print()
    print("## 警告\n")
    if warnings:
        for w in warnings:
            print(f"- ⚠️ {w}")
    else:
        print("- 无")


if __name__ == "__main__":
    main()
