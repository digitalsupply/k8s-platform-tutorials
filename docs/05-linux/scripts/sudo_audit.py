#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只读的 sudo / SSH 权限审计。

对应教程里的 su/sudo、无密码 SSH、root shell 原理。
检查项：

- UID 0 账户（root 以外是否还有）
- sudoers / sudoers.d 中的 NOPASSWD
- sshd_config 的 PermitRootLogin / PasswordAuthentication
- 当前用户 authorized_keys 中的 command= / from= / no-pty 等限制

不做任何修改；需要读权限，建议用 sudo 运行。
"""

import glob
import os
import re
import subprocess


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def section(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def uid0_accounts():
    out = []
    try:
        res = subprocess.run(["getent", "passwd"], capture_output=True, text=True, check=False)
        for line in res.stdout.splitlines():
            parts = line.split(":")
            if len(parts) >= 4 and parts[3] == "0":
                out.append(parts[0])
    except Exception:  # noqa: BLE001
        for line in read("/etc/passwd").splitlines():
            parts = line.split(":")
            if len(parts) >= 4 and parts[3] == "0":
                out.append(parts[0])
    return out


def sudoers_files():
    files = ["/etc/sudoers"]
    files.extend(glob.glob("/etc/sudoers.d/*"))
    return [f for f in files if os.path.isfile(f)]


def main():
    section("1. UID 0 账户")
    accounts = uid0_accounts()
    print("UID 0 accounts:", ", ".join(accounts) if accounts else "(none?)")
    if len(accounts) > 1:
        print("WARNING: 存在多个 UID 0 账户，请确认是否必要")

    section("2. sudoers 中的 NOPASSWD")
    found = False
    for path in sudoers_files():
        text = read(path)
        for idx, line in enumerate(text.splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            if "NOPASSWD" in line:
                found = True
                print(f"{path}:{idx}: {line.strip()}")
    if not found:
        print("(no NOPASSWD entries found or no permission to read sudoers)")

    section("3. sshd_config")
    sshd = read("/etc/ssh/sshd_config")
    if not sshd:
        print("(cannot read /etc/ssh/sshd_config)")
    else:
        for key in ("PermitRootLogin", "PasswordAuthentication", "PubkeyAuthentication", "AllowUsers", "AllowGroups"):
            matches = [l.strip() for l in sshd.splitlines() if re.match(rf"^\s*{key}\s+", l, re.I)]
            print(f"{key}: {' | '.join(matches) if matches else '(default/not set)'}")
        if re.search(r"^\s*PermitRootLogin\s+yes", sshd, re.I | re.M):
            print("WARNING: PermitRootLogin yes")
        if re.search(r"^\s*PasswordAuthentication\s+yes", sshd, re.I | re.M):
            print("WARNING: PasswordAuthentication yes（建议只允许密钥）")

    section("4. authorized_keys 限制")
    candidates = [os.path.expanduser("~/.ssh/authorized_keys"), "/root/.ssh/authorized_keys"]
    seen = set()
    for path in candidates:
        if path in seen or not os.path.isfile(path):
            continue
        seen.add(path)
        print(f"# {path}")
        text = read(path)
        for idx, line in enumerate(text.splitlines(), 1):
            if not line.strip() or line.strip().startswith("#"):
                continue
            prefix = line.split()[0] if line.split() else ""
            opts = []
            for opt in ("command=", "from=", "no-pty", "no-port-forwarding", "restrict"):
                if opt in prefix:
                    opts.append(opt)
            print(f"  line {idx}: {', '.join(opts) if opts else 'no restrictions'}")
    if not seen:
        print("(no authorized_keys found for current user/root)")

    section("5. 建议")
    print("- 使用 sudo 而不是共享 root 密码；")
    print("- sudoers 用 visudo 修改，尽量按命令/用户最小授权；")
    print("- 禁止 root 密码 SSH，优先普通用户 + sudo；")
    print("- 无密码 SSH 仅用于自动化，并加 from=/command=/restrict 限制。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
