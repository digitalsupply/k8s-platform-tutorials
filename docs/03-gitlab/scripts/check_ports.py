#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitLab / 端口冲突排查辅助脚本。

对应教程里的 GitLab 8088→80 排查。它会只读地收集：

- 端口监听（ss）
- iptables / nftables 中与 80/8088/cilium 相关的规则
- 本机 HTTP 探测结果
- GitLab 进程/服务提示

用法：
  sudo python3 check_ports.py --ports 80,8088 --urls http://127.0.0.1:8088
"""

import argparse
import shutil
import subprocess
import sys


def run(cmd, timeout=20):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=timeout
        )
    except Exception as exc:  # noqa: BLE001
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


def section(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def main():
    parser = argparse.ArgumentParser(description="Check listeners and firewall rules for GitLab ports")
    parser.add_argument("--ports", default="80,8088")
    parser.add_argument("--urls", default="http://127.0.0.1:8088/")
    args = parser.parse_args()

    ports = [p.strip() for p in args.ports.split(",") if p.strip()]

    section("1. 端口监听 (ss -lntp)")
    if shutil.which("ss"):
        res = run(["ss", "-lntp"])
        lines = [l for l in res.stdout.splitlines() if any(f":{p} " in l or l.endswith(f":{p}") for p in ports)]
        print("\n".join(lines) if lines else "(no matching listeners or permission denied)")
        if res.stderr:
            print("[stderr]", res.stderr.strip())
    else:
        print("ss not found")

    section("2. iptables 中与端口/Cilium 相关的规则")
    if shutil.which("iptables-save"):
        res = run(["iptables-save"])
        keys = ["cilium"] + [f":{p}" for p in ports] + [f"dport {p}" for p in ports]
        lines = [l for l in res.stdout.splitlines() if any(k in l for k in keys)]
        print("\n".join(lines[:120]) if lines else "(no matching rules)")
    else:
        print("iptables-save not found")

    section("3. nftables 中与端口/Cilium 相关的规则")
    if shutil.which("nft"):
        res = run(["nft", "list", "ruleset"])
        keys = ["cilium"] + [f":{p}" for p in ports] + [f"dport {p}" for p in ports]
        lines = [l for l in res.stdout.splitlines() if any(k in l for k in keys)]
        print("\n".join(lines[:120]) if lines else "(no matching rules)")
    else:
        print("nft not found")

    section("4. HTTP 探测")
    for url in [u.strip() for u in args.urls.split(",") if u.strip()]:
        if not shutil.which("curl"):
            print("curl not found")
            break
        res = run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code} %{remote_ip}:%{remote_port}", "--max-time", "5", url])
        print(f"{url} -> {res.stdout or res.stderr}")

    section("5. GitLab 服务提示")
    if shutil.which("gitlab-ctl"):
        res = run(["gitlab-ctl", "status"])
        print(res.stdout[:3000] if res.stdout else res.stderr[:1000])
    else:
        print("gitlab-ctl not found (not a GitLab Omnibus node?)")

    print("\n结论提示：")
    print("- 先看 ss 是否有进程监听；")
    print("- 再看 iptables/nftables 是否有重定向/Cilium 规则；")
    print("- 最后用 curl -v 区分 127.0.0.1 和节点 IP 的行为。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
