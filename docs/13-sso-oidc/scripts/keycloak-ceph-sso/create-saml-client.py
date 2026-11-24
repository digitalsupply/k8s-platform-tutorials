#!/usr/bin/env python3
"""创建 / 更新 Keycloak 里给 Ceph Dashboard 用的 SAML client。

读取同目录的 ceph-saml-client.json，把占位符 <SP_CERT_BODY> 替换成
SP 证书的实际内容（去掉 PEM 头尾的单行 Base64），然后通过 Admin API
创建或更新 client，并移除默认的 role_list client scope。

用法：
    # 先生成 SP 证书（见文档「步骤 5」）
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /tmp/saml_sp.key -out /tmp/saml_sp.crt \
      -days 3650 -subj '/CN=ceph-dashboard'

    python3 create-saml-client.py

环境变量（可选，覆盖默认值）：
    KC_BASE_URL   Keycloak 外部地址，默认 http://10.0.0.121:32669
    KC_ADMIN_USER 管理台用户名，默认 admin
    KC_ADMIN_PASS 管理台密码，默认 Keycloak@123
    KC_REALM      realm 名，默认 ceph-sso
    SP_CERT       SP 证书路径，默认 /tmp/saml_sp.crt

注意：SP 证书与签名/加密开关必须成对。给了 SP 证书就要开
saml.client.signature / saml.encrypt，否则 Ceph 侧会报
"The assertion of the Response is not encrypted"。
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("KC_BASE_URL", "http://10.0.0.121:32669").rstrip("/")
ADMIN_USER = os.environ.get("KC_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("KC_ADMIN_PASS", "Keycloak@123")
REALM = os.environ.get("KC_REALM", "ceph-sso")
SP_CERT_PATH = os.environ.get("SP_CERT", "/tmp/saml_sp.crt")
HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT_JSON = os.path.join(HERE, "ceph-saml-client.json")


def api(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers=headers,
        method=method,
    )
    try:
        resp = urllib.request.urlopen(req, timeout=20)
        return resp.getcode(), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def get_admin_token():
    body = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": ADMIN_USER,
            "password": ADMIN_PASS,
        }
    ).encode()
    req = urllib.request.Request(
        BASE + "/realms/master/protocol/openid-connect/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=20).read())["access_token"]


def strip_pem(path):
    """读取证书文件，去掉 PEM 头尾，返回单行 Base64。"""
    with open(path, "r", encoding="utf-8") as f:
        lines = [l.strip() for l in f if "-----" not in l and l.strip()]
    body = "".join(lines)
    print(f"SP 证书: {path} → {len(body)} 字符")
    return body


def main():
    if not os.path.exists(SP_CERT_PATH):
        sys.exit(f"找不到 SP 证书 {SP_CERT_PATH}，请先按文档生成")

    cert_body = strip_pem(SP_CERT_PATH)

    with open(CLIENT_JSON, "r", encoding="utf-8") as f:
        client = json.load(f)
    client.pop("_comment", None)

    # 替换证书占位符
    for key, value in list(client.get("attributes", {}).items()):
        if value == "<SP_CERT_BODY>":
            client["attributes"][key] = cert_body

    token = get_admin_token()
    client_id = client["clientId"]

    # 先查是否已存在
    code, body = api("GET", f"/admin/realms/{REALM}/clients?clientId=" + urllib.parse.quote(client_id), token=token)
    existing = []
    if code == 200:
        try:
            existing = json.loads(body)
        except ValueError:
            existing = []

    if existing:
        cid = existing[0]["id"]
        code, _ = api("PUT", f"/admin/realms/{REALM}/clients/{cid}", client, token=token)
        print(f"client 更新: HTTP {code}（clientId={client_id}）")
        client_id_for_scope = cid
    else:
        code, body = api("POST", f"/admin/realms/{REALM}/clients", client, token=token)
        print(f"client 创建: HTTP {code}")
        if code not in (201, 204):
            print("  失败:", body[:300])
            return
        code, body = api("GET", f"/admin/realms/{REALM}/clients?clientId=" + urllib.parse.quote(client_id), token=token)
        client_id_for_scope = json.loads(body)[0]["id"]

    # 移除默认的 role_list scope：它会为每个角色输出一个 Name="Role" 的属性，
    # python3-saml 遇到同名属性会报 "Found an Attribute element with duplicated Name"
    code, body = api("GET", f"/admin/realms/{REALM}/clients/{client_id_for_scope}/default-client-scopes", token=token)
    if code == 200:
        for scope in json.loads(body):
            if scope.get("name") in ("role_list", "roles"):
                sid = scope["id"]
                c2, _ = api("DELETE", f"/admin/realms/{REALM}/clients/{client_id_for_scope}/default-client-scopes/{sid}", token=token)
                print(f"移除 client scope: {scope['name']} → HTTP {c2}")

    print("完成。可用以下命令验证：")
    print(f"  curl -s {BASE}/realms/{REALM}/protocol/saml/descriptor | head -c 200")


if __name__ == "__main__":
    main()
