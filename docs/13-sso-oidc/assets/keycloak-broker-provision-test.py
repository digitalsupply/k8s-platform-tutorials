#!/usr/bin/env python3
"""验证 Keycloak ceph-sso realm 能否把 GitLab 用户自动导入并完成 broker 登录。

流程：
  1. 在 ceph-sso realm 临时建一个 public OIDC client（默认 sso-perm-test）；
  2. 用 bigdev / smallops 走 kc_idp_hint=gitlab 的完整登录；
  3. 断言最终跳回 http://localhost:9999/cb?code=...；
  4. 检查 Keycloak 用户及其 federated identity（gitlab/userId=...）；
  5. 删除临时 client（失败也会删）。

环境变量：
  KEYCLOAK_ADMIN_PASSWORD   必填，master realm admin 密码
  SSO_TEST_PASSWORD         必填，bigdev/smallops 的 GitLab 密码
  KEYCLOAK_URL              默认 http://10.0.0.121:32669
  KEYCLOAK_ADMIN_USER       默认 admin
  KEYCLOAK_REALM            默认 ceph-sso
  GITLAB_URL                默认 http://192.168.67.201

注意：
  - 会创建/删除一个临时 Keycloak client；
  - 首次登录会真实创建 ceph-sso 用户并写 federated identity，
    这是预期行为（Review Profile 已设为 DISABLED）；
  - 不对 Keycloak/Ceph 做其他修改。
"""
import json
import os
import re
import sys
import urllib.parse

import requests

requests.packages.urllib3.disable_warnings()

KC = os.environ.get("KEYCLOAK_URL", "http://10.0.0.121:32669")
REALM = os.environ.get("KEYCLOAK_REALM", "ceph-sso")
GITLAB = os.environ.get("GITLAB_URL", "http://192.168.67.201")
ADMIN_USER = os.environ.get("KEYCLOAK_ADMIN_USER", "admin")
ADMIN_PW = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "")
USER_PW = os.environ.get("SSO_TEST_PASSWORD", "")
CLIENT = "sso-perm-test"
REDIRECT = "http://localhost:9999/cb"


def admin_token():
    r = requests.post(
        f"{KC}/realms/master/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": ADMIN_USER,
            "password": ADMIN_PW,
        },
        timeout=20,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def ensure_client(tok):
    h = {"Authorization": f"Bearer {tok}"}
    r = requests.get(
        f"{KC}/admin/realms/{REALM}/clients", params={"clientId": CLIENT}, headers=h, timeout=20
    )
    if r.json():
        return
    requests.post(
        f"{KC}/admin/realms/{REALM}/clients",
        headers=h,
        json={
            "clientId": CLIENT,
            "name": "temporary broker-flow test",
            "enabled": True,
            "publicClient": True,
            "standardFlowEnabled": True,
            "directAccessGrantsEnabled": False,
            "redirectUris": [REDIRECT],
        },
        timeout=20,
    ).raise_for_status()


def delete_client(tok):
    h = {"Authorization": f"Bearer {tok}"}
    r = requests.get(
        f"{KC}/admin/realms/{REALM}/clients", params={"clientId": CLIENT}, headers=h, timeout=20
    )
    for c in r.json():
        requests.delete(f"{KC}/admin/realms/{REALM}/clients/{c['id']}", headers=h, timeout=20)


def hidden(html):
    out = {}
    for tag in re.findall(r"<input\b[^>]*>", html):
        n = re.search(r'name="([^"]+)"', tag)
        v = re.search(r'value="([^"]*)"', tag)
        if n:
            out[n.group(1)] = v.group(1) if v else ""
    return out


def gitlab_login(s, user):
    r = s.get(f"{GITLAB}/users/sign_in", timeout=20)
    tok = re.search(r'name="authenticity_token" value="([^"]+)"', r.text).group(1)
    s.post(
        f"{GITLAB}/users/sign_in",
        data={
            "authenticity_token": tok,
            "user[login]": user,
            "user[password]": USER_PW,
            "user[remember_me]": "0",
        },
        timeout=20,
    )


def gitlab_authorize(s, url):
    r = s.get(url, allow_redirects=False, timeout=20)
    if r.status_code in (301, 302, 303, 307, 308):
        return r.headers["Location"]
    if r.status_code != 200:
        raise RuntimeError(f"gitlab authorize HTTP {r.status_code}")
    m = re.search(
        r'(https?://[^"\'<>\s]+\?[^"\'<>\s]*\bcode=[0-9a-f]+[^"\'<>\s]*)', r.text
    )
    if m:
        return m.group(1).replace("&amp;", "&")
    for form in re.findall(r"<form\b.*?</form>", r.text, re.S):
        if 'value="delete"' in form:
            continue
        data = hidden(form)
        if "client_id" not in data:
            continue
        data.setdefault("commit", "Authorize")
        rr = s.post(f"{GITLAB}/oauth/authorize", data=data, allow_redirects=False, timeout=20)
        if rr.status_code in (301, 302, 303, 307, 308):
            return rr.headers["Location"]
        m = re.search(
            r'(https?://[^"\'<>\s]+\?[^"\'<>\s]*\bcode=[0-9a-f]+[^"\'<>\s]*)', rr.text
        )
        if m:
            return m.group(1).replace("&amp;", "&")
    raise RuntimeError("gitlab authorize could not be completed")


def broker_login(user):
    s = requests.Session()
    gitlab_login(s, user)
    auth = (
        f"{KC}/realms/{REALM}/protocol/openid-connect/auth?client_id={CLIENT}"
        f"&redirect_uri={urllib.parse.quote(REDIRECT, safe='')}"
        "&response_type=code&scope=openid&kc_idp_hint=gitlab&state=probe"
    )
    steps = []
    r = s.get(auth, allow_redirects=False, timeout=20)
    if r.status_code not in (302, 303, 307):
        return {"result": "failed", "steps": steps, "body": r.text[:300]}
    loc = gitlab_authorize(s, r.headers["Location"])
    steps.append(("gitlab->broker", loc[:120]))
    for _ in range(10):
        r = s.get(loc, allow_redirects=False, timeout=20)
        steps.append((r.status_code, r.headers.get("Location", "")[:120]))
        if r.status_code in (301, 302, 303, 307, 308):
            loc = r.headers["Location"]
            if loc.startswith(REDIRECT):
                has_code = "code=" in loc
                return {
                    "result": "broker-login-ok" if has_code else "no-code",
                    "redirect_has_code": has_code,
                    "steps": steps,
                }
            continue
        if r.status_code == 200:
            # GitLab 的 Redirecting 页面（code 在链接里）
            m = re.search(
                r'(https?://[^"\'<>\s]+\?[^"\'<>\s]*\bcode=[0-9a-f]+[^"\'<>\s]*)', r.text
            )
            if m:
                loc = m.group(1).replace("&amp;", "&")
                continue
            # Keycloak 的确认页（Review Profile / 首次登录表单）
            action = None
            data = None
            for form in re.findall(r"<form\b.*?</form>", r.text, re.S):
                if 'value="delete"' in form:
                    continue
                m = re.search(r'action="([^"]+)"', form)
                inputs = hidden(form)
                if m and inputs:
                    action = urllib.parse.urljoin(r.url, m.group(1).replace("&amp;", "&"))
                    data = inputs
                    break
            if not action or data is None:
                return {"result": "unexpected-page", "steps": steps, "body": r.text[:300]}
            data.setdefault("commit", "Authorize")
            loc = action
            # 表单是 POST，这里直接发请求
            rr = s.post(loc, data=data, allow_redirects=False, timeout=20)
            steps.append(("form-post", rr.status_code, rr.headers.get("Location", "")[:120]))
            loc = rr.headers.get("Location", "")
            if not loc:
                return {"result": "form-no-redirect", "steps": steps}
            continue
        return {"result": f"http-{r.status_code}", "steps": steps}
    return {"result": "loop-ended", "steps": steps}


def main():
    if not ADMIN_PW or not USER_PW:
        print("KEYCLOAK_ADMIN_PASSWORD and SSO_TEST_PASSWORD are required", file=sys.stderr)
        return 2
    tok = admin_token()
    ensure_client(tok)
    out = {}
    try:
        for user in ("bigdev", "smallops"):
            out[user] = broker_login(user)
    finally:
        h = {"Authorization": f"Bearer {tok}"}
        users = requests.get(
            f"{KC}/admin/realms/{REALM}/users", params={"max": 50}, headers=h, timeout=20
        ).json()
        out["keycloak_users"] = [
            {"username": u["username"], "id": u["id"], "email": u.get("email")} for u in users
        ]
        out["federated_identities"] = {}
        for u in users:
            if u["username"] in ("bigdev", "smallops"):
                out["federated_identities"][u["username"]] = requests.get(
                    f"{KC}/admin/realms/{REALM}/users/{u['id']}/federated-identity",
                    headers=h,
                    timeout=20,
                ).json()
        delete_client(tok)

    print(json.dumps(out, indent=2, ensure_ascii=False))
    ok = all(
        out[u].get("redirect_has_code")
        and out["federated_identities"].get(u)
        for u in ("bigdev", "smallops")
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
