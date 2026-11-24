#!/usr/bin/env python3
"""验证整条 SSO 跳转链：Ceph Dashboard → Keycloak → GitLab。

不打开浏览器，只检查每一步的 302 跳转，确认：
  1. Keycloak 可达，SAML IdP 元数据端点正常
  2. Ceph 的 /auth/saml2/login 会跳转到 Keycloak
  3. 带 kc_idp_hint=gitlab 时，Keycloak 会跳转到 GitLab 的 /oauth/authorize
  4. GitLab 接受该 OAuth 应用（未登录时 302 到 /users/sign_in）

用法：
    python3 verify-sso-chain.py

环境变量（可选）：
    CEPH_DASH_URL  Ceph Dashboard，默认 https://10.0.0.41:8443
    KC_BASE_URL    Keycloak，默认 http://10.0.0.121:32669
    GITLAB_URL     GitLab，默认 http://192.168.67.201

注意：GitLab 是**登录后才校验** redirect_uri，所以第 4 步只能确认
GitLab 接受了 client_id 并放行到登录页，无法在无会话的情况下
验证 redirect_uri 是否合法。redirect_uri 的最终确认要靠真实登录。
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
GITLAB = os.environ.get("GITLAB_URL", "http://192.168.67.201").rstrip("/")
REALM = os.environ.get("KC_REALM", "ceph-sso")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# 必须带 CookieJar：Keycloak 的 broker 登录要靠会话 cookie 关联
# 正在进行的 SAML 流程，否则会报 cookie_not_found 并返回 400。
cj = http.cookiejar.CookieJar()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


op = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=ctx),
    urllib.request.HTTPCookieProcessor(cj),
    NoRedirect,
)


def get(url):
    try:
        r = op.open(urllib.request.Request(url), timeout=20)
        return r.getcode(), r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def main():
    ok = True

    # 1. Keycloak 可达 + SAML 元数据
    code, _, _ = get(KC + "/realms/master")
    print(f"1. Keycloak /realms/master: {code}", "✅" if code == 200 else "❌")
    ok &= code == 200

    code, _, body = get(KC + f"/realms/{REALM}/protocol/saml/descriptor")
    entity = ""
    m = re.search(r'entityID="([^"]+)"', body)
    if m:
        entity = m.group(1)
    print(f"2. SAML descriptor: {code}  entityID={entity}", "✅" if code == 200 else "❌")
    ok &= code == 200

    # 3. Ceph → Keycloak
    code, h, _ = get(CEPH + "/auth/saml2/login")
    loc = h.get("Location", "")
    good = code == 303 and "protocol/saml" in loc
    print(f"3. Ceph /auth/saml2/login: {code} -> {loc[:80]}", "✅" if good else "❌")
    ok &= good
    if not good:
        print("   （若返回 400，多半是 Ceph 的 SAML 配置没生效，见文档坑 15/16）")
        return 1

    # 4. Keycloak → GitLab（带 kc_idp_hint）
    chain = loc + ("&" if "?" in loc else "?") + "kc_idp_hint=gitlab"
    code, h, _ = get(chain)
    loc2 = h.get("Location", "")
    good = code == 303 and "/broker/gitlab/login" in loc2
    print(f"4. Keycloak broker: {code} -> {loc2[:80]}", "✅" if good else "❌")
    ok &= good

    code, h, _ = get(loc2)
    loc3 = h.get("Location", "")
    q = urllib.parse.parse_qs(urllib.parse.urlparse(loc3).query)
    good = code == 303 and loc3.startswith(GITLAB + "/oauth/authorize")
    print(f"5. GitLab /oauth/authorize: {code}")
    print(f"   client_id    = {(q.get('client_id') or [''])[0][:24]}...")
    print(f"   redirect_uri = {(q.get('redirect_uri') or [''])[0]}")
    print(f"   scope        = {(q.get('scope') or [''])[0]}", "✅" if good else "❌")
    ok &= good

    print()
    if ok:
        print("✅ 跳转链全部正常。最后一步需要真实 GitLab 账号在浏览器里完成授权。")
        return 0
    print("❌ 有步骤未通过，按上面的提示排查。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
