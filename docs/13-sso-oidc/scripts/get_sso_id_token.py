#!/usr/bin/env python3
"""获取指定 GitLab 用户在某个 OAuth 应用下的 OIDC id_token，并解码身份 claim。

用途：核对“不同用户身份验证”的 id_token（`sub` / `preferred_username` / `email` / `groups` 等）。
例如验证 Headlamp（应用 `oauth2-headlamp`）在用户登录后拿到的身份，或对比 root/bigdev/smallops
在各应用下的 `groups` 差异。

流程：
  1. 通过 ssh + gitlab-rails runner 读取 GitLab OAuth 应用的 client_id / client_secret / redirect_uri；
  2. 以目标用户在 GitLab 登录（表单登录）；
  3. 走 /oauth/authorize（必要时处理 GitLab 授权同意页）；
  4. 用 code 换 token，取 id_token；
  5. 解码并打印 id_token 的 payload。

环境变量：
  GITLAB_URL     默认 http://192.168.67.201
  GITLAB_SSH    默认 root@192.168.67.201（用于读取 OAuth 应用信息）

用法：
  python3 get_sso_id_token.py --user bigdev --password '...' --app oauth2-headlamp
  python3 get_sso_id_token.py --user smallops --password '...' --app grafana

说明：
  - 只读取，不修改任何 GitLab/业务对象；
  - 密码只用于本次登录，不落盘。
"""
import argparse
import base64
import json
import re
import subprocess
import sys

import requests

requests.packages.urllib3.disable_warnings()

GITLAB = __import__("os").environ.get("GITLAB_URL", "http://192.168.67.201")
GITLAB_SSH = __import__("os").environ.get("GITLAB_SSH", "root@192.168.67.201")
SCOPES = "openid profile email"


def fetch_app(app):
    """通过 ssh + gitlab-rails runner 读取 OAuth 应用信息。"""
    ruby = (
        "puts JSON.generate({"
        "uid: Doorkeeper::Application.find_by_name(%%q(%s)).uid, "
        "secret: Doorkeeper::Application.find_by_name(%%q(%s)).secret, "
        "redirect_uri: Doorkeeper::Application.find_by_name(%%q(%s)).redirect_uri})"
        % (app, app, app)
    )
    remote = f"gitlab-rails runner '{ruby}'"
    out = subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", GITLAB_SSH, remote],
        text=True,
    ).strip()
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"无法解析 GitLab OAuth 应用信息: {out!r}") from exc


def hidden_inputs(html):
    out = {}
    for tag in re.findall(r"<input\b[^>]*>", html):
        name = re.search(r'name="([^"]+)"', tag)
        value = re.search(r'value="([^"]*)"', tag)
        if name:
            out[name.group(1)] = value.group(1) if value else ""
    return out


def gitlab_login(session, user, password):
    r = session.get(f"{GITLAB}/users/sign_in", timeout=20)
    m = re.search(r'name="authenticity_token" value="([^"]+)"', r.text)
    if not m:
        raise RuntimeError("登录页未找到 CSRF token")
    r = session.post(
        f"{GITLAB}/users/sign_in",
        data={
            "authenticity_token": m.group(1),
            "user[login]": user,
            "user[password]": password,
            "user[remember_me]": "0",
        },
        allow_redirects=False,
        timeout=20,
    )
    if r.status_code != 302:
        raise RuntimeError(f"GitLab 登录失败: HTTP {r.status_code}")


def authorize(session, url):
    """完成 /oauth/authorize，返回带 code 的回调地址。"""
    r = session.get(url, allow_redirects=False, timeout=20)
    if r.status_code in (301, 302, 303, 307, 308):
        loc = r.headers["Location"]
        if "/users/sign_in" in loc:
            raise RuntimeError("授权时未登录，请先登录")
        return loc
    if r.status_code != 200:
        raise RuntimeError(f"authorize HTTP {r.status_code}")

    # GitLab 的 "Redirecting" 页面：code 在链接里
    m = re.search(r'(https?://[^"\'<>\s]+?\bcode=[0-9a-f]+[^"\'<>\s]*)', r.text)
    if m:
        return m.group(1).replace("&amp;", "&")

    # consent 页：GitLab 同时渲染 Authorize 与 Deny（_method=delete）两个表单，只提交 Authorize
    for form in re.findall(r"<form\b.*?</form>", r.text, re.S):
        if 'value="delete"' in form:
            continue
        data = hidden_inputs(form)
        if "client_id" not in data:
            continue
        data.setdefault("commit", "Authorize")
        rr = session.post(
            f"{GITLAB}/oauth/authorize", data=data, allow_redirects=False, timeout=20
        )
        loc = rr.headers.get("Location", "")
        if loc:
            return loc
        m = re.search(r'(https?://[^"\'<>\s]+?\bcode=[0-9a-f]+[^"\'<>\s]*)', rr.text)
        if m:
            return m.group(1).replace("&amp;", "&")
    raise RuntimeError("未能完成 GitLab authorize")


def decode_id_token(id_token):
    parts = id_token.split(".")
    if len(parts) != 3:
        raise RuntimeError(f"id_token 不是 JWT: {id_token[:40]}")
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--app", required=True, help="GitLab OAuth 应用名，如 oauth2-headlamp / grafana / argocd / harbor")
    args = ap.parse_args()

    app = fetch_app(args.app)
    client_id = app["uid"]
    client_secret = app["secret"]
    redirect_uri = app["redirect_uri"]

    session = requests.Session()
    session.verify = False
    session.headers["User-Agent"] = "get-sso-id-token/1.0"

    gitlab_login(session, args.user, args.password)

    authorize_url = (
        f"{GITLAB}/oauth/authorize?client_id={client_id}"
        f"&response_type=code&scope={SCOPES.replace(' ', '+')}"
        f"&state=idtoken-probe&redirect_uri={redirect_uri}"
    )
    callback = authorize(session, authorize_url)
    m = re.search(r"code=([0-9a-f]+)", callback)
    if not m:
        raise RuntimeError(f"回调里没有 code: {callback}")
    code = m.group(1)

    r = session.post(
        f"{GITLAB}/oauth/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
        },
        timeout=20,
    )
    if r.status_code != 200:
        raise RuntimeError(f"换 token 失败: HTTP {r.status_code} {r.text[:200]}")
    token = r.json()
    if "id_token" not in token:
        raise RuntimeError(f"响应里没有 id_token: {list(token)}")

    payload = decode_id_token(token["id_token"])
    print(json.dumps(
        {
            "user": args.user,
            "app": args.app,
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "id_token_payload": payload,
        },
        indent=2,
        ensure_ascii=False,
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
