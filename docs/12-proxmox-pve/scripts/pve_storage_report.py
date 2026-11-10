#!/usr/bin/env python3
"""PVE / LVM-thin 容量与风险只读报告。

在 Proxmox 宿主机上执行，读取 pvs / vgs / lvs / pvesm / lvm.conf，
给出 thin pool 使用率、VG 余量、autoextend 是否可能失败等结论。

用法:
    python3 pve_storage_report.py
    python3 pve_storage_report.py --format json
"""

import argparse
import json
import re
import subprocess
import sys


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def rows(text, sep=None):
    if sep:
        return [[c.strip() for c in line.split(sep)] for line in text.splitlines() if line.strip()]
    return [line.split() for line in text.splitlines() if line.strip()]


def parse_lvm_conf():
    conf = {}
    try:
        with open("/etc/lvm/lvm.conf") as fh:
            for line in fh:
                m = re.match(r"\s*(thin_pool_autoextend_threshold|thin_pool_autoextend_percent)\s*=\s*(\d+)", line)
                if m:
                    conf[m.group(1)] = int(m.group(2))
    except OSError:
        pass
    return conf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["md", "json"], default="md")
    args = ap.parse_args()

    pvs = rows(run(["pvs", "--noheadings", "--units", "g", "--nosuffix",
                    "--separator", "|", "-o", "pv_name,vg_name,pv_size,pv_free"]), "|")
    vgs = rows(run(["vgs", "--noheadings", "--units", "g", "--nosuffix",
                    "--separator", "|", "-o", "vg_name,vg_size,vg_free,vg_extent_count,vg_free_count"]), "|")
    lvs = rows(run(["lvs", "--noheadings", "--units", "g", "--nosuffix",
                    "--separator", "|", "-o",
                    "lv_name,vg_name,lv_size,pool_lv,data_percent,metadata_percent"]), "|")
    pvesm = run(["pvesm", "status"])

    conf = parse_lvm_conf()
    threshold = conf.get("thin_pool_autoextend_threshold", 80)
    percent = conf.get("thin_pool_autoextend_percent", 20)

    pools = []
    for r in lvs:
        if len(r) < 6:
            continue
        name, vg, size, pool, data_pct, meta_pct = r[:6]
        if not pool and data_pct not in ("", "-"):
            try:
                d = float(data_pct)
            except ValueError:
                continue
            pools.append({"name": name, "vg": vg, "sizeGiB": float(size),
                          "dataPercent": d, "metaPercent": float(meta_pct or 0)})

    vg_info = []
    for r in vgs:
        if len(r) < 5:
            continue
        vg_info.append({"name": r[0], "sizeGiB": float(r[1]), "freeGiB": float(r[2]),
                        "extentCount": int(r[3]), "freeExtents": int(r[4])})

    warnings = []
    for p in pools:
        vg = next((v for v in vg_info if v["name"] == p["vg"]), None)
        if vg:
            grow = p["sizeGiB"] * percent / 100.0
            if grow > vg["freeGiB"]:
                warnings.append(
                    f"thin pool {p['name']} 到 {threshold}% 时 autoextend 需要约 {grow:.1f}GiB，"
                    f"但 VG {vg['name']} 只剩 {vg['freeGiB']:.1f}GiB；若不先扩 VG 或调小 autoextend_percent，扩容会失败")
            if p["dataPercent"] >= threshold:
                warnings.append(f"thin pool {p['name']} 使用率 {p['dataPercent']:.1f}% 已达到阈值 {threshold}%")
        if p["dataPercent"] >= 75:
            warnings.append(f"thin pool {p['name']} 使用率 {p['dataPercent']:.1f}%，建议在 70% 前处理")
        if p["metaPercent"] >= 70:
            warnings.append(f"thin pool {p['name']} 元数据使用率 {p['metaPercent']:.1f}%")

    for v in vg_info:
        if v["freeGiB"] < 16:
            warnings.append(f"VG {v['name']} 仅剩 {v['freeGiB']:.1f}GiB 未分配空间")

    result = {
        "host": run(["hostname"]),
        "pveVersion": run(["pveversion"]),
        "pvs": [{"name": r[0], "vg": r[1], "sizeGiB": float(r[2]), "freeGiB": float(r[3])}
                for r in pvs if len(r) >= 4],
        "vgs": vg_info,
        "thinPools": pools,
        "autoextend": {"thresholdPercent": threshold, "growPercent": percent},
        "pvesm": pvesm,
        "warnings": warnings,
    }

    if args.format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    print("# PVE / LVM-thin 容量报告\n")
    print(f"- 主机: `{result['host']}`")
    print(f"- 版本: `{result['pveVersion']}`")
    print(f"- autoextend: threshold={threshold}% grow={percent}%")
    print()
    print("## PV / VG\n")
    print("| PV | VG | Size(GiB) | Free(GiB) |")
    print("|---|---|---|---|")
    for p in result["pvs"]:
        print(f"| {p['name']} | {p['vg']} | {p['sizeGiB']:.2f} | {p['freeGiB']:.2f} |")
    print()
    print("| VG | Size(GiB) | Free(GiB) |")
    print("|---|---|---|")
    for v in vg_info:
        print(f"| {v['name']} | {v['sizeGiB']:.2f} | {v['freeGiB']:.2f} |")
    print()
    print("## Thin Pool\n")
    print("| Pool | VG | Size(GiB) | Data% | Meta% | 一次 autoextend 需要(GiB) |")
    print("|---|---|---|---|---|---|")
    for p in pools:
        grow = p["sizeGiB"] * percent / 100.0
        print(f"| {p['name']} | {p['vg']} | {p['sizeGiB']:.2f} | {p['dataPercent']:.2f} | "
              f"{p['metaPercent']:.2f} | {grow:.1f} |")
    print()
    print("## pvesm status\n")
    print("```text")
    print(pvesm or "-")
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
