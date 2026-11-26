# Ceph Dashboard 换用户登录仍显示旧用户：Keycloak 会话复用排查（2026-11-25）

## 一、结论速览

**不是 Ceph 的 bug，也不是 GitLab 换人没成功**，而是三层会话里**Keycloak 的 realm 会话**没有退出：

- 退出 GitLab 只清掉 **GitLab 自己的会话**；
- Keycloak 仍然持有 `smallops` 的 SSO 会话（`KEYCLOAK_IDENTITY` / `KEYCLOAK_SESSION`）；
- 再进 Ceph 时，Keycloak 发现"我已经有会话了"，**直接用旧身份签发 SAML 断言，根本不再去问 GitLab**；
- 于是 GitLab 里明明是 `bigdev`，Ceph 里还是 `smallops`。

Ceph 自己的"退出"会走 **SAML 单点登出（SLO）**，会销毁 Keycloak 会话；只要这条链路走完，
下次登录就是新用户。实测（脚本，2026-11-25）：

```text
①  GitLab=smallops  → Ceph=smallops
②  只退出 GitLab，换 bigdev 登录 → Ceph 仍是 smallops      ← 会话复用
③  走 Ceph 退出（POST /api/auth/logout → SLO）→ Ceph=bigdev
```

## 二、三层会话，各退各的

| 层 | 浏览器里的凭据 | 谁能清掉 | 备注 |
|---|---|---|---|
| GitLab | `_gitlab_session`（`192.168.67.201`） | GitLab 右上角退出 | 与 Ceph/Keycloak 无关 |
| **Keycloak** | `KEYCLOAK_IDENTITY`、`KEYCLOAK_SESSION`（`10.0.0.121`，path `/realms/ceph-sso/`） | **Ceph 退出触发的 SLO**，或 Keycloak 控制台退出，或管理员 `logout-all` | **决定"你是谁"的就是这一层** |
| Ceph Dashboard | `token`（`10.0.0.41`，HttpOnly、SameSite=Strict，JWT） | `POST /api/auth/logout` 清 cookie；`/auth/saml2/logout` 也会清 | 默认 TTL 8h（`ceph dashboard get-jwt-token-ttl` = 28800） |

关键点：SAML 客户端的 `saml_name_id_format = username`，断言里的 `uid` 取自 **Keycloak 会话中的用户**，
而不是"GitLab 当前登录的人"。所以只要 Keycloak 会话还是 smallops，Ceph 就一定是 smallops。

## 三、为什么"退了 Ceph 还是旧用户"

按可能性排序：

1. **SLO 链路没走完（最常见）**。点退出后地址栏必须完整经过
   `10.0.0.41 → 10.0.0.121 → 10.0.0.41`。中途关页面、点"后退"、被浏览器拦截，
   Keycloak 会话就没销毁；回到 Ceph 时它还在，于是"秒登录"成旧用户。
2. **只退了 GitLab（或只退了 Keycloak）**。见第一节第 ② 步，这是设计行为，不是故障。
3. **存在多个 Keycloak 会话**。SLO 只销毁 LogoutRequest 对应的那一个；实测同一用户
   在 `ceph-sso` 里可能同时存在多个会话（每次未带 cookie 的登录都会新建一个）。
4. **跨站跳转 / 跨站 cookie 被浏览器策略拦截**。Ceph 是 `https://10.0.0.41:8443`，
   Keycloak 是 `http://10.0.0.121:32669`，属于跨站；无痕/严格隐私模式可能打断链路。
5. **另一个标签页还持有有效 Ceph token**。`token` cookie 默认 8h，别的标签页会看起来"又自动登录了"。

## 四、实测复现（可直接运行）

脚本：[scripts/keycloak-ceph-sso/repro-user-switch.py](../scripts/keycloak-ceph-sso/repro-user-switch.py)

```bash
cd docs/13-sso-oidc/scripts/keycloak-ceph-sso

# 只验证（会真实登录/退出 ceph-sso）
python3 repro-user-switch.py

# 先清空 realm 内所有会话（会踢掉所有在线用户），再做完整验证
KC_ADMIN_PASS='<keycloak admin 密码>' python3 repro-user-switch.py --clean
```

输出（2026-11-25 实测）：

```text
0. 清空 ceph-sso 全部会话
  Keycloak logout-all: HTTP 200
1. GitLab 登录 smallops，进 Ceph
  [smallops] Ceph 身份 = smallops
   Keycloak 会话数: smallops=1 bigdev=0
2. 只退出 GitLab，改用 bigdev 登录，再进 Ceph
  GitLab 退出（清除 3 个 GitLab cookie；Keycloak 会话不动）
  [GitLab 已换人] Ceph 身份 = smallops
3. 走 Ceph 自己的退出链路（SLO）
  /api/auth/logout -> redirect_url='auth/saml2/slo'
  SLO: 303 https://10.0.0.41:8443/auth/saml2/slo -> 302 http://10.0.0.121:32669/realms/ceph-sso/protocol/sam -> 303 https://10.0.0.41:8443/auth/saml2/logout -> 200 https://10.0.0.41:8443/#/login
   SLO 后 Keycloak 会话数: smallops=0 bigdev=0
4. 再进 Ceph
  [SLO 之后] Ceph 身份 = bigdev
✅ 符合预期：GitLab 退出不影响 Keycloak 会话；Ceph 退出走完 SLO 后才会换人。
```

## 五、立即恢复：把自己从旧身份里弄出来

按顺序尝试：

1. **完整走一次 Ceph 退出**：Dashboard 右上角用户菜单 → **Log out**，
   盯住地址栏确认经过 `10.0.0.41 → 10.0.0.121 → 10.0.0.41` 并停在 `#/login`。
   若中途被拦，换无痕窗口重来。
2. **手动删 cookie**（仍然不行时）：
   - `10.0.0.41` 的 `token`
   - `10.0.0.121` 的 `KEYCLOAK_IDENTITY`、`KEYCLOAK_SESSION`
3. **管理员强制下线**（会踢掉 `ceph-sso` 里所有人，慎用）：

```bash
TOKEN=$(curl -sS -X POST 'http://10.0.0.121:32669/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=$(kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-user}' | base64 -d)" \
  -d "password=$(kubectl -n keycloak get secret keycloak-admin-secret -o jsonpath='{.data.keycloak-admin-password}' | base64 -d)" \
  | jq -r .access_token)

curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  'http://10.0.0.121:32669/admin/realms/ceph-sso/logout-all'
```

4. **查某个用户还剩几个会话**：

```bash
ID=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  'http://10.0.0.121:32669/admin/realms/ceph-sso/users?username=smallops&exact=true' | jq -r '.[0].id')
curl -sS -H "Authorization: Bearer $TOKEN" \
  "http://10.0.0.121:32669/admin/realms/ceph-sso/users/$ID/sessions" | jq -c '.[] | {id, start:(.start/1000|todate), lastAccess:(.lastAccess/1000|todate), ipAddress}'
```

> Keycloak **26.3.4** 上 `DELETE /admin/realms/ceph-sso/users/{id}/sessions` 实测返回 **404**
> （单会话 `DELETE .../sessions/{sid}` 同样 404），所以清理用 `logout-all` 或让用户自己退。

## 六、下次怎么定位：Keycloak 事件已开启

已在 `ceph-sso` realm 开启事件审计（`eventsEnabled=true`，保留 7 天），覆盖
`LOGIN / LOGIN_ERROR / LOGOUT / LOGOUT_ERROR / CODE_TO_TOKEN / IDENTITY_PROVIDER_LOGIN` 等。

```bash
curl -sS -H "Authorization: Bearer $TOKEN" \
  'http://10.0.0.121:32669/admin/realms/ceph-sso/events?max=25' \
  | jq -r '.[] | [(.time/1000|strftime("%m-%d %H:%M:%S")), .type, (.details.username // "-"), (.details.identity_provider // "-"), (.clientId // "-")] | @tsv'
```

实测输出：

```text
11-25 07:05:08  LOGIN    bigdev   gitlab  https://10.0.0.41:8443/auth/saml2/metadata
11-25 07:05:08  LOGOUT   smallops -       https://10.0.0.41:8443/auth/saml2/metadata
11-25 07:05:08  LOGIN    smallops -       https://10.0.0.41:8443/auth/saml2/metadata
11-25 07:05:07  LOGIN    smallops gitlab  https://10.0.0.41:8443/auth/saml2/metadata
```

判读方法：

- 只有 `LOGIN`、**没有对应的 `LOGOUT`** → 退出没走 SLO，Keycloak 会话还在；
- `LOGIN` 事件的 `identity_provider` 为空 → 是 Keycloak 会话复用（没去 GitLab）；
  为 `gitlab` → 真的经过 GitLab broker 重新认证了；
- 有 `LOGOUT_ERROR` → SLO 请求被拒（签名/会话索引问题），需要单独排查。

## 七、加固建议

1. **先改认知**：GitLab 退出 ≠ 全局退出。要换人必须退 **Keycloak**（走 Ceph 退出即可），
   或者用无痕窗口。这是 broker SSO 的固有语义，不是故障。
2. **缩短 Keycloak 会话窗口**（当前 `ssoSessionIdleTimeout=1800`、`ssoSessionMaxLifespan=36000`）：
   闲置 15 分钟、最长 8 小时更符合运维平台；改完"忘了退"也不会一直沿用旧身份。
3. **缩短 Ceph JWT TTL**（当前 8h）：

   ```bash
   ceph dashboard set-jwt-token-ttl 3600   # 1 小时
   ```

   注意：它**不能**替代 SLO，只是减少残留 token（比如另一个标签页）的影响。
4. **保留事件审计**，定期看 `LOGOUT_ERROR` 与"有 LOGIN 无 LOGOUT"的账号。
5. **要彻底做到"切 GitLab 用户即生效"**，只能让 Keycloak 每次强制重新认证：
   SAML 没有 `prompt=login` 这类参数，需要把 Ceph 改成 OIDC 客户端并带 `prompt=login`，
   或让 GitLab 登出回调 Keycloak（GitLab 不支持 backchannel logout）。
   当前接受"退出 Ceph 才换人"的语义，并在运维手册里写清楚。

## 八、本次变更

| 项 | 内容 |
|---|---|
| Keycloak `ceph-sso` realm | 开启 events（保留 7 天，15 类事件） |
| 新增脚本 | `docs/13-sso-oidc/scripts/keycloak-ceph-sso/repro-user-switch.py` |
| 新增文档 | 本篇 |
| 未改动 | Ceph SAML 配置、Keycloak 客户端、GitLab OAuth 应用 |
