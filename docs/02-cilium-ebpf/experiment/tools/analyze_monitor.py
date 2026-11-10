#!/usr/bin/env python3
# 解析本实验产物：mon/*.jsonl -> 事件流摘要；可直接用于复现/重放分析
import json, sys, glob

def main(mon_path_glob):
    for f in sorted(glob.glob(mon_path_glob)):
        print("=" * 88); print(f)
        for line in open(f):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            s = (d.get("summary") or {})
            l3 = s.get("l3") or {}
            tcp = s.get("tcp") or ""
            flags = "".join(x for x in ["SYN", "ACK", "FIN", "RST"] if x + "=true" in tcp)
            print(f"{d.get('observationPoint') or (d.get('tracepoint') or {}).get('subtype') or '?':24} "
                  f"{d.get('srcLabel')}->{d.get('dstLabel')}  {l3.get('src')}->{(l3.get('dst') or '')} "
                  f":{s.get('l4', {}).get('dst', '')}  {flags:6} if={d.get('ifindex')}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "./mon/mon*.jsonl")