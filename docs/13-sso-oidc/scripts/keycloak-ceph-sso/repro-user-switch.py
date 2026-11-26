#!/usr/bin/env python3
"""复现 / 验证：GitLab 换用户登录后，Ceph Dashboard 是否还停在旧用户。

背景
----
Ceph Dashboard 的 SSO 链路是：

    Ceph (SAML SP)  ←→  Keycloak realm `ceph-sso` (SAML IdP)
                              ←broker→  GitLab (OIDC IdP)

这里有三层彼此独立的会话：

1. GitLab 会话（`_gitlab_session`）
2. Keycloak SSO 会话（`KEYCLOAK_IDENTITY` / `KEYCLOAK_SESSION`，realm 级）
3. Ceph Dashboard 会话（HttpOnly cookie `token`，JWT，默认 8h）

**退出 GitLab 只会清第 1 层。** 只要第 2 层还在，Ceph 再登录时 Keycloak 会直接
用旧身份签发断言，不会去问 GitLab —— 于是看起来"换人失败"。

本脚本用纯标准库模拟同一个浏览器（共享 cookie jar），验证：

  A. GitLab 退出 → 换 bigdev 登录 → 再进 Ceph：仍是 smallops（Keycloak 会话复用）
  B. 走 Ceph 的退出链路（POST /api/auth/logout → SLO）→ 再进 Ceph：变成 bigdev

用法
----
    # 只读验证（会真的登录/退出 ceph-sso 的会话，但不删别人的会话）
    python3 repro-user-switch.py

    # 先强制清空 realm 内所有会话（会踢掉所有在线用户），再做完整验证
    python3 repro-user-switch.py --clean

环境变量
--------
    CEPH_DASH_URL  默认 https://10.0.0.41:8443
    KC_BASE_URL    默认 http://10.0.0.121:32669
    GITLAB_URL     默认 http://192.168.67.201
    KC_REALM       默认 ceph-sso
    KC_ADMIN_USER / KC_ADMIN_PASS   仅 --clean / 会话统计需要
    GL_USER_A / GL_PASS_A           默认 smallops / Temp@12345
    GL_USER_B / GL_PASS_B           默认 bigdev   / Temp@12345

退出码：0 = 行为符合预期；1 = 出现异常（附诊断输出）
"""
import argparse
import base64
import html
import http.cookiejar
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

CEPH = os.environ.get("CEPH_DASH_URL", "https://10.0.0.41:8443").rstrip("/")
KC = os.environ.get("KC_BASE_URL", "http://10.0.0.121:32669").rstrip("/")
GITLAB = os.environ.get("GITLAB_URL", "http://192.168.67.201").rstrip("/")
REALM = os.environ.get("KC_REALM", "ceph-sso")
KC_ADMIN_USER = os.environ.get("KC_ADMIN_USER", "admin")
KC_ADMIN_PASS = os.environ.get("KC_ADMIN_PASS", "")
USER_A = os.environ.get("GL_USER_A", "smallops")
PASS_A = os.environ.get("GL_PASS_A", "Temp@12345")
USER_B = os.environ.get("GL_USER_B", "bigdev")
PASS_B = os.environ.get("GL_PASS_B", "Temp@12345")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
JAR = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=CTX),
    urllib.request.HTTPCookieProcessor(JAR),
    NoRedirect,
)
CEPH_API_HEADERS = {"Accept": "application/vnd.ceph.api.v1.0+json"}


def http(url, data=None, raw=None, headers=None):
    body = raw if raw is not None else (
        urllib.parse.urlencode(data).encode() if data else None)
    req = urllib.request.Request(url, data=body, headers=headers or {})
    try:
        r = OPENER.open(req, timeout=25)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def kc_admin(method, path, token, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        KC + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=20)
        raw = r.read().decode()
        return r.getcode(), (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def kc_token():
    code, _, body = http(KC + "/realms/master/protocol/openid-connect/token", {
        "grant_type": "password", "client_id": "admin-cli",
        "username": KC_ADMIN_USER, "password": KC_ADMIN_PASS})
    if code != 200:
        sys.exit(f"Keycloak 管理员登录失败（设置 KC_ADMIN_PASS）: HTTP {code}")
    return json.loads(body)["access_token"]


def kc_sessions(token, username):
    _, users = kc_admin("GET", f"/admin/realms/{REALM}/users?username={username}&exact=true", token)
    if not users:
        return 0
    _, sess = kc_admin("GET", f"/admin/realms/{REALM}/users/{users[0]['id']}/sessions", token)
    return len(sess or [])


def kc_logout_all(token):
    code, _ = kc_admin("POST", f"/admin/realms/{REALM}/logout-all", token)
    print(f"  Keycloak logout-all: HTTP {code}")


def first_form(page):
    m = re.search(r"<form[^>]*action=\"([^\"]*)\"[^>]*>(.*?)</form>", page, re.S | re.I)
    if not m:
        return None, {}
    fields = {}
    for i in re.finditer(r"<input([^>]*)>", m.group(2), re.I):
        n = re.search(r'name="([^"]*)"', i.group(1))
        v = re.search(r'value="([^"]*)"', i.group(1))
        if n:
            fields[n.group(1)] = html.unescape(v.group(1) if v else "")
    return html.unescape(m.group(1)), fields


def gitlab_login(user, password):
    """GitLab 表单登录（与浏览器一致：先取 CSRF）。"""
    for _ in range(4):
        code, h, page = http(GITLAB + "/users/sign_in")
        if code in (301, 302, 303, 307, 308) and h.get("Location"):
            continue
        break
    m = re.search(r'name="authenticity_token" value="([^"]+)"', page)
    if not m:
        sys.exit(f"GitLab 登录页异常（HTTP {code}）")
    code, _, _ = http(GITLAB + "/users/sign_in", {
        "authenticity_token": m.group(1),
        "user[login]": user, "user[password]": password, "user[remember_me]": "0"})
    if code != 302:
        sys.exit(f"GitLab 登录 {user} 失败: HTTP {code}")


def gitlab_logout():
    """只清 GitLab 自己的 cookie —— 相当于在 GitLab 点“退出”。"""
    n = 0
    host = urllib.parse.urlparse(GITLAB).hostname
    for c in list(JAR):
        if c.domain.lstrip(".") == host:
            JAR.clear(c.domain, c.path, c.name)
            n += 1
    print(f"  GitLab 退出（清除 {n} 个 GitLab cookie；Keycloak 会话不动）")


def ceph_login(label):
    """走 Ceph → Keycloak →（必要时）GitLab，返回 Ceph 最终身份。"""
    code, h, _ = http(CEPH + "/auth/saml2/login")
    url = urllib.parse.urljoin(CEPH, h.get("Location") or "")
    hops = []
    for _ in range(15):
        if not url:
            break
        code, h, body = http(url)
        hops.append(f"{code} {url.split('?')[0].replace('https://', '').replace('http://', '')[:52]}")
        if "SAMLResponse" in body and "<form" in body:
            action, fields = first_form(body)
            code, h, _ = http(action, {"SAMLResponse": fields["SAMLResponse"],
                                       "RelayState": fields.get("RelayState", "")})
            break
        link = re.search(r'href="([^"]*(?:/broker/|code=)[^"]*)"', body)
        if link:
            url = urllib.parse.urljoin(url, html.unescape(link.group(1)))
            continue
        loc = h.get("Location")
        if code in (301, 302, 303, 307, 308) and loc:
            url = urllib.parse.urljoin(url, loc)
            continue
        print(f"  [{label}] 卡住: {code} {url[:70]}")
        return None
    tok = re.search(r"access_token=([^&#]+)", h.get("Location") or "")
    if not tok:
        print(f"  [{label}] 没拿到 Ceph access_token（跳转链: {' -> '.join(hops)}）")
        return None
    payload = tok.group(1).split(".")[1]
    payload += "=" * (-len(payload) % 4)
    who = json.loads(base64.urlsafe_b64decode(payload)).get("username")
    print(f"  [{label}] Ceph 身份 = {who}")
    return who


def ceph_ui_logout():
    """Ceph 前端“退出”按钮的实际链路：POST /api/auth/logout → SLO。"""
    code, _, body = http(CEPH + "/api/auth/logout", raw=b"", headers=CEPH_API_HEADERS)
    if code != 200:
        print(f"  /api/auth/logout HTTP {code}: {body[:120]}")
        return False
    redirect_url = json.loads(body).get("redirect_url") or ""
    print(f"  /api/auth/logout -> redirect_url={redirect_url!r}")
    url = urllib.parse.urljoin(CEPH + "/", redirect_url)
    hops = []
    for _ in range(6):
        if not url:
            break
        code, h, _ = http(url)
        hops.append(f"{code} {url.split('?')[0][:52]}")
        url = h.get("Location")
    print("  SLO: " + " -> ".join(hops))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clean", action="store_true", help="先 POST /logout-all 清空 realm 会话")
    args = ap.parse_args()

    token = None
    if args.clean or KC_ADMIN_PASS:
        token = kc_token()
    if args.clean:
        print("0. 清空 ceph-sso 全部会话")
        kc_logout_all(token)

    print(f"1. GitLab 登录 {USER_A}，进 Ceph")
    gitlab_login(USER_A, PASS_A)
    who1 = ceph_login(USER_A)
    if token:
        print(f"   Keycloak 会话数: {USER_A}={kc_sessions(token, USER_A)} {USER_B}={kc_sessions(token, USER_B)}")

    print(f"2. 只退出 GitLab，改用 {USER_B} 登录，再进 Ceph")
    gitlab_logout()
    gitlab_login(USER_B, PASS_B)
    who2 = ceph_login("GitLab 已换人")

    print("3. 走 Ceph 自己的退出链路（SLO）")
    ceph_ui_logout()
    if token:
        print(f"   SLO 后 Keycloak 会话数: {USER_A}={kc_sessions(token, USER_A)} {USER_B}={kc_sessions(token, USER_B)}")

    print("4. 再进 Ceph")
    who3 = ceph_login("SLO 之后")

    print()
    print(f"结果: ① {who1}  ② 只退 GitLab → {who2}  ③ 退 Ceph(SLO) → {who3}")
    ok = (who1 == USER_A and who2 == USER_A and who3 == USER_B)
    if ok:
        print("✅ 符合预期：GitLab 退出不影响 Keycloak 会话；Ceph 退出走完 SLO 后才会换人。")
        return 0
    print("❌ 与预期不符，检查：SLO 是否走完、是否存在多个 Keycloak 会话、"
          "浏览器是否拦截了跨站跳转/cookie。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
