#!/usr/bin/env python3
"""验证 SAML 单点登出（SLO）是否真的销毁了 Keycloak 会话。

用于排查「点 logout 退出后又被自动登录」的问题。

流程：
  1. 走一遍完整登录，建立 Keycloak 会话
  2. 检查会话状态（应为「自动签发」，即会话仍在）
  3. 走 dashboard 的 logout 链路：/auth/saml2/slo → Keycloak → 回 Ceph
  4. 再检查会话状态（应为「需要重新认证」，即会话已销毁）

用法：
    python3 test-slo-logout.py

环境变量（可选）：
    CEPH_DASH_URL  Ceph Dashboard，默认 https://10.0.0.41:8443
    KC_USER / KC_PASS  ceph-sso realm 的本地账号，默认 admin / Ceph@Admin123

结论判读：
- 第 2 步「自动签发」+ 第 4 步「需要重新认证」→ SLO 正常，
  若你仍看到自动登录，说明 logout 链路没走完（看地址栏是否从
  10.0.0.121 跳回 10.0.0.41）。
- 第 4 步仍是「自动签发」→ Keycloak 会话没被销毁，
  检查是否中途关了页面、或浏览器第三方 Cookie 策略拦截。
"""

import http.cookiejar
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

CEPH = os.environ.get("CEPH_DASH_URL", "https://10.0.0.41:8443").rstrip("/")
KC_USER = os.environ.get("KC_USER", "admin")
KC_PASS = os.environ.get("KC_PASS", "Ceph@Admin123")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
cj = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


op = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=ctx),
    urllib.request.HTTPCookieProcessor(cj),
    NoRedirect,
)


def req(url, data=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    r = urllib.request.Request(url, data=body)
    try:
        x = op.open(r, timeout=25)
        return x.getcode(), x.headers, x.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def form_fields(page):
    forms = re.findall(r'<form[^>]*action="([^"]*)"[^>]*>(.*?)</form>', page, re.S | re.I)
    if not forms:
        return None, {}
    action, inner = forms[0]
    fields = {}
    for m in re.finditer(r"<input([^>]*)>", inner, re.I):
        attrs = m.group(1)
        n = re.search(r'name="([^"]*)"', attrs)
        v = re.search(r'value="([^"]*)"', attrs)
        if n:
            fields[n.group(1)] = (v.group(1) if v else "")
    import html

    return html.unescape(action), fields


def kc_state(tag):
    """访问 Ceph 登录入口并跟到 Keycloak，判断会话状态。"""
    code, h, _ = req(CEPH + "/auth/saml2/login")
    code, h, page = req(h.get("Location", ""))
    if "login-actions/authenticate" in page:
        state = "需要重新认证（会话已销毁）"
    elif "SAMLResponse" in page:
        state = "自动签发断言（会话仍在 → 会自动登录）"
    else:
        state = "未知"
    cookies = sorted(c.name for c in cj if "KEYCLOAK" in c.name)
    print(f"{tag}: {state}  | Keycloak cookie: {cookies}")
    return "SAMLResponse" in page


def main():
    # 登录
    code, h, _ = req(CEPH + "/auth/saml2/login")
    _, _, page = req(h.get("Location", ""))
    action, _ = form_fields(page)
    _, _, page = req(action, {"username": KC_USER, "password": KC_PASS})
    fields = dict(re.findall(r'name="([^"]+)" value="([^"]*)"', page))
    acs = re.search(r'<form[^>]*action="([^"]+)"', page).group(1)
    import html

    req(html.unescape(acs), {"SAMLResponse": fields["SAMLResponse"], "RelayState": fields.get("RelayState", "")})

    alive_before = kc_state("登录后")

    # 走 dashboard logout 的完整 SLO 链路
    code, h, _ = req(CEPH + "/auth/saml2/slo")
    print(f"  Ceph /auth/saml2/slo: {code} -> {(h.get('Location') or '')[:70]}")
    code, h2, _ = req(h.get("Location", ""))
    print(f"  Keycloak 处理 SLO: {code} -> {(h2.get('Location') or '')[:70]}")
    if h2.get("Location"):
        code, h3, _ = req(h2["Location"])
        print(f"  回 Ceph: {code} -> {(h3.get('Location') or '')[:70]}")

    alive_after = kc_state("SLO 之后")

    print()
    if alive_before and not alive_after:
        print("✅ SLO 正常：登录后会话存在，走完 SLO 后会话被销毁。")
        print("   若你仍看到自动登录，说明 logout 链路没走完（地址栏未从 10.0.0.121 跳回 10.0.0.41）。")
        return 0
    if alive_before and alive_after:
        print("❌ SLO 后会话仍在，Keycloak 没有销毁会话。")
        print("   检查是否中途关了页面、或浏览器第三方 Cookie 策略拦截了跳转。")
        return 1
    print("⚠️ 登录后会话就没建立起来，检查 Keycloak 登录是否成功。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
