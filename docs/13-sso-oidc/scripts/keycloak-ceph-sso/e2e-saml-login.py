#!/usr/bin/env python3
"""端到端验证 Ceph Dashboard ← Keycloak 的 SAML 登录链路（不打开浏览器）。

走完 4 步：
  1. 访问 Ceph 的 /auth/saml2/login，拿到跳转 Keycloak 的 SAMLRequest
  2. 打开 Keycloak 登录页，解析表单
  3. 提交用户名密码，拿到 SAMLResponse
  4. POST 到 Ceph 的 ACS，确认拿到 access_token

用法：
    python3 e2e-saml-login.py

环境变量（可选）：
    CEPH_DASH_URL  Ceph Dashboard 地址，默认 https://10.0.0.41:8443
    KC_BASE_URL    Keycloak 地址，默认 http://10.0.0.121:32669
    KC_USER        登录用的 Keycloak 用户名（ceph-sso realm 的本地账号），默认 admin
    KC_PASS        对应密码，默认 Ceph@Admin123

注意：
- 这个脚本验证的是「Keycloak 本地账号 → SAML → Ceph」这一段。
  走 GitLab 的完整链路需要浏览器里点 "Or sign in with GitLab"。
- Ceph 侧必须已经存在与断言 uid 同名的 dashboard 用户，
  否则会跳 #/sso/404（见文档坑 23）。
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
KC = os.environ.get("KC_BASE_URL", "http://10.0.0.121:32669").rstrip("/")
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
            fields[n.group(1)] = html_unescape(v.group(1)) if v else ""
    return html_unescape(action), fields


def html_unescape(s):
    import html

    return html.unescape(s or "")


def main():
    # 1. Ceph → Keycloak
    code, h, _ = req(CEPH + "/auth/saml2/login")
    loc = h.get("Location")
    print("1. ceph login:", code, "-> keycloak" if loc and "protocol/saml" in loc else loc)
    if not loc:
        sys.exit("Ceph 没有跳转到 Keycloak，检查 SAML 是否配置好")

    # 2. Keycloak 登录页
    code, h, page = req(loc)
    has_form = "<form" in page
    print("2. keycloak login page:", code, "form" if has_form else "no-form")
    if not has_form:
        # 可能 Keycloak 已有会话，直接返回了自动提交的断言表单
        if "SAMLResponse" in page:
            print("   （Keycloak 已有会话，跳过登录表单，直接走第 4 步）")
            action, fields = loc, {}
        else:
            sys.exit("Keycloak 返回了非预期页面")
    else:
        action, fields = form_fields(page)
        print("   action:", (action or "").split("?")[0])

    # 3. 提交用户名密码
    if has_form:
        fields["username"] = KC_USER
        fields["password"] = KC_PASS
        code, h, page = req(action, fields)
        print("3. post credentials:", code)
        action2, fields2 = form_fields(page)
    else:
        action2, fields2 = form_fields(page)
        print("3. (复用已有会话)")

    if "SAMLResponse" not in fields2:
        sys.exit("没有拿到 SAMLResponse，检查 Keycloak 登录是否成功")
    print("   response form action:", (action2 or "")[:60], "| has SAMLResponse: True")

    # 4. POST 到 Ceph ACS
    code, h, page = req(
        action2,
        {"SAMLResponse": fields2["SAMLResponse"], "RelayState": fields2.get("RelayState", "")},
    )
    loc = h.get("Location", "")
    print("4. ceph ACS:", code, "->", (loc or page[:200])[:120])
    if "access_token" in loc:
        print("   ✅ 登录成功，拿到 access_token")
        return 0
    print("   ❌ 未拿到 access_token，常见原因：")
    print("      - Ceph 里没有断言 uid 对应的 dashboard 用户（会跳 #/sso/404）")
    print("      - 断言签名/加密校验失败（检查 Keycloak 客户端的证书与开关）")
    return 1


if __name__ == "__main__":
    sys.exit(main())
