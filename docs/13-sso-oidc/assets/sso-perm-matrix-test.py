#!/usr/bin/env python3
"""SSO 权限矩阵端到端验证（bigdev / smallops）。

用真实的 GitLab 账号走完整的 Authorization Code 登录，再调用各系统的
"我是谁 / 我能做什么" 接口，证明两个用户的权限不同。

环境变量：
  SSO_TEST_PASSWORD   必填，测试账号密码
  GITLAB_URL          默认 http://192.168.67.201
  INGRESS_VIP         默认 10.0.0.252（Traefik VIP）
  HARBOR_URL          默认 https://192.168.67.202:8443

用法：
  SSO_TEST_PASSWORD='...' python3 sso-perm-matrix-test.py

说明：
  - 只访问业务 UI 和 GitLab，不修改任何集群对象；
  - 通过 patch socket.getaddrinfo 把 grafana.k8s.local / traefik.xyz /
    argocd.devops.com / headlamp.devops.com 指到 INGRESS_VIP，
    不需要改 /etc/hosts；
  - 退出码 0 表示全部符合预期，1 表示有失败/不符合项。
"""
import json
import os
import re
import socket
import sys
import urllib.parse

import requests

requests.packages.urllib3.disable_warnings()

VIP = os.environ.get("INGRESS_VIP", "10.0.0.252")
GITLAB = os.environ.get("GITLAB_URL", "http://192.168.67.201")
HARBOR = os.environ.get("HARBOR_URL", "https://192.168.67.202:8443")
PASSWORD = os.environ.get("SSO_TEST_PASSWORD", "")
USERS = ["bigdev", "smallops"]
HOSTS = {"grafana.k8s.local", "traefik.xyz", "argocd.devops.com", "headlamp.devops.com"}

_orig_gai = socket.getaddrinfo


def _patched_gai(host, port, *args, **kwargs):
    if host in HOSTS:
        return _orig_gai(VIP, port, *args, **kwargs)
    return _orig_gai(host, port, *args, **kwargs)


socket.getaddrinfo = _patched_gai


def new_session():
    s = requests.Session()
    s.verify = False
    s.headers["User-Agent"] = "sso-perm-matrix-test/1.0"
    return s


def gitlab_login(s, user):
    r = s.get(f"{GITLAB}/users/sign_in", timeout=20)
    m = re.search(r'name="authenticity_token" value="([^"]+)"', r.text)
    if not m:
        raise RuntimeError("no csrf token on GitLab sign-in page")
    r = s.post(
        f"{GITLAB}/users/sign_in",
        data={
            "authenticity_token": m.group(1),
            "user[login]": user,
            "user[password]": PASSWORD,
            "user[remember_me]": "0",
        },
        allow_redirects=False,
        timeout=20,
    )
    if r.status_code != 302:
        raise RuntimeError(f"GitLab login failed for {user}: HTTP {r.status_code}")


def _hidden_inputs(html):
    out = {}
    for tag in re.findall(r"<input\b[^>]*>", html):
        name = re.search(r'name="([^"]+)"', tag)
        if not name:
            continue
        value = re.search(r'value="([^"]*)"', tag)
        out[name.group(1)] = value.group(1) if value else ""
    return out


def authorize(s, url):
    """完成 GitLab /oauth/authorize（含 consent 页），返回回跳应用的 URL。"""
    r = s.get(url, allow_redirects=False, timeout=20)
    if r.status_code in (301, 302, 303, 307, 308):
        loc = r.headers["Location"]
        if "/users/sign_in" in loc:
            raise RuntimeError(f"not logged in when authorizing: {loc}")
        return loc
    if r.status_code != 200:
        raise RuntimeError(f"authorize HTTP {r.status_code}")

    # GitLab 的 "Redirecting" 页面已经把 code 放在链接里
    m = re.search(
        r'(https?://[^"\'<>\s]+\?[^"\'<>\s]*\bcode=[0-9a-f]+[^"\'<>\s]*)', r.text
    )
    if m:
        return m.group(1).replace("&amp;", "&")

    # consent 页：GitLab 同时渲染 Authorize 表单和 Deny 表单（带 _method=delete），
    # 必须只提交 Authorize 那个表单。
    for form in re.findall(r"<form\b.*?</form>", r.text, re.S):
        if 'value="delete"' in form:
            continue
        data = _hidden_inputs(form)
        if "client_id" not in data:
            continue
        data.setdefault("commit", "Authorize")
        rr = s.post(f"{GITLAB}/oauth/authorize", data=data, allow_redirects=False, timeout=20)
        loc = rr.headers.get("Location", "")
        if loc:
            return loc
        m = re.search(
            r'(https?://[^"\'<>\s]+\?[^"\'<>\s]*\bcode=[0-9a-f]+[^"\'<>\s]*)', rr.text
        )
        if m:
            return m.group(1).replace("&amp;", "&")
    raise RuntimeError("could not complete GitLab authorize flow")


def add(result, user, app, status, detail):
    result.append({"user": user, "app": app, "status": status, "detail": detail})


def test_grafana(user, result):
    s = new_session()
    gitlab_login(s, user)
    r = s.get("https://grafana.k8s.local/login/generic_oauth", allow_redirects=False, timeout=20)
    if r.status_code not in (301, 302, 303, 307, 308):
        add(result, user, "grafana", "FAIL", f"login start HTTP {r.status_code}")
        return
    s.get(authorize(s, r.headers["Location"]), allow_redirects=True, timeout=20)
    me = s.get("https://grafana.k8s.local/api/user", timeout=20)
    if me.status_code != 200:
        add(result, user, "grafana", "FAIL", f"/api/user HTTP {me.status_code}")
        return
    j = me.json()
    add(
        result,
        user,
        "grafana",
        "OK",
        {"login": j.get("login"), "isGrafanaAdmin": j.get("isGrafanaAdmin")},
    )


def test_argocd(user, result):
    s = new_session()
    gitlab_login(s, user)
    r = s.get("https://argocd.devops.com/auth/login", allow_redirects=False, timeout=20)
    if r.status_code not in (301, 302, 303, 307, 308):
        add(result, user, "argocd", "FAIL", f"login start HTTP {r.status_code}")
        return
    s.get(authorize(s, r.headers["Location"]), allow_redirects=True, timeout=20)
    info = s.get("https://argocd.devops.com/api/v1/session/userinfo", timeout=20)
    if info.status_code != 200:
        add(result, user, "argocd", "FAIL", f"userinfo HTTP {info.status_code}")
        return
    j = info.json()
    # 写操作探针：readonly 会在 RBAC 层 403，admin 会走到参数校验
    probe = s.post(
        "https://argocd.devops.com/api/v1/applications",
        json={"application": {"metadata": {"name": "", "namespace": "argocd"}, "spec": {}}},
        timeout=20,
    )
    add(
        result,
        user,
        "argocd",
        "OK",
        {
            "username": j.get("username"),
            "groups": j.get("groups"),
            "create_app_probe_http": probe.status_code,
            "verdict": "admin" if probe.status_code != 403 else "readonly",
        },
    )


def test_harbor(user, result):
    s = new_session()
    gitlab_login(s, user)
    r = s.get(f"{HARBOR}/c/oidc/login", allow_redirects=False, timeout=20)
    if r.status_code not in (301, 302, 303, 307, 308):
        add(result, user, "harbor", "FAIL", f"oidc login start HTTP {r.status_code}")
        return
    s.get(authorize(s, r.headers["Location"]), allow_redirects=True, timeout=20)
    me = s.get(f"{HARBOR}/api/v2.0/users/current", timeout=20)
    if me.status_code != 200:
        add(result, user, "harbor", "FAIL", f"/users/current HTTP {me.status_code}")
        return
    j = me.json()
    # 系统管理员才能列全部用户
    probe = s.get(f"{HARBOR}/api/v2.0/users?page=1&page_size=1", timeout=20)
    add(
        result,
        user,
        "harbor",
        "OK",
        {
            "username": j.get("username"),
            "admin_role_in_auth": j.get("admin_role_in_auth"),
            "list_users_http": probe.status_code,
            "verdict": "admin" if probe.status_code == 200 else "non-admin",
        },
    )


def test_oauth2_proxy(user, result, app, start_url, expect):
    s = new_session()
    gitlab_login(s, user)
    r = s.get(start_url, allow_redirects=False, timeout=20)
    if r.status_code not in (301, 302, 303, 307, 308):
        add(result, user, app, "FAIL", f"start HTTP {r.status_code}")
        return
    loc = urllib.parse.urljoin(start_url, r.headers["Location"])
    if "/oauth2/start" in loc:
        r = s.get(loc, allow_redirects=False, timeout=20)
        if r.status_code not in (301, 302, 303, 307, 308):
            add(result, user, app, "FAIL", f"oauth2/start HTTP {r.status_code}")
            return
        loc = r.headers["Location"]
    r = s.get(authorize(s, loc), allow_redirects=False, timeout=20)
    detail = {"callback_http": r.status_code}
    if r.status_code in (301, 302, 303, 307, 308):
        rr = s.get(
            urllib.parse.urljoin(start_url, r.headers.get("Location", "/")),
            allow_redirects=True,
            timeout=20,
        )
        detail["protected_http"] = rr.status_code
        detail["verdict"] = "allowed" if rr.status_code < 400 else "denied"
    else:
        detail["verdict"] = "denied" if r.status_code == 403 else f"http {r.status_code}"
    add(result, user, app, "OK" if detail["verdict"] == expect else "MISMATCH", detail)


def main():
    if not PASSWORD:
        print("SSO_TEST_PASSWORD is required", file=sys.stderr)
        return 2
    result = []
    for user in USERS:
        for fn in (test_grafana, test_argocd, test_harbor):
            try:
                fn(user, result)
            except Exception as exc:  # noqa: BLE001
                add(result, user, fn.__name__.replace("test_", ""), "ERROR", repr(exc))
        for app, url, expect in (
            ("traefik (oauth2-proxy)", "https://traefik.xyz/dashboard/", "allowed" if user == "bigdev" else "denied"),
            ("headlamp (oauth2-proxy)", "https://headlamp.devops.com/", "allowed" if user == "bigdev" else "denied"),
        ):
            try:
                test_oauth2_proxy(user, result, app, url, expect)
            except Exception as exc:  # noqa: BLE001
                add(result, user, app, "ERROR", repr(exc))

    print(json.dumps(result, indent=2, ensure_ascii=False))
    bad = [r for r in result if r["status"] in ("FAIL", "ERROR", "MISMATCH")]
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
