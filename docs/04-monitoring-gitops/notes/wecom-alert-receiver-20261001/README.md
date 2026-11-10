# 企业微信告警出口接入（Alertmanager）

调研时间：2026-10-01
依据：`/root/alerting-coverage-audit-20260930.md` §5 P0-1（告警单出口 + 自指依赖）
状态：**已切换为「企业微信群机器人」路线并上线，双出口已生效。**

### 已生效配置

| 项 | 值 |
|---|---|
| receiver | `wecom`（企业微信自建应用） |
| corp_id | `wwd98e843d2350fa9c` |
| agent_id | `1000003` |
| 接收对象 | `to_tag: "1"`（标签 test） |
| 路由 | `severity =~ "critical\|warning"` → wecom（`continue: true`）→ n8n-webhook |
| 上线时间 | 2026-10-01 15:56 |
| 生效验证 | `/api/v2/receivers` → `[{n8n-webhook},{wecom}]`，路由树与预期一致 |

### 验证结果（已闭环）

- 群机器人路线：adapter → 群机器人 Webhook，**零门槛（无需域名/可信IP/可见范围）**。
- 实测：2026-10-01T08:26:21～08:27:51 期间，wecom receiver 共 5 次 `Notify success`（AlertmanagerClusterFailedToSendAlerts、AlertmanagerFailedToSendAlerts、KubeContainerWaiting、KubePodNotReady、Phase2FixVerification 各 1 次），n8n 侧近 20m `failed_total` 仍为 0。
- 当前状态：`/api/v2/receivers` 含 `wecom` + `n8n-webhook`，双发保持解耦（continue: true）。

---

## 结论：群机器人路线是正确选项

**Alertmanager v0.32.0 的 `wechat_configs` 只实现了「企业微信自建应用」API。**

源码依据 `notify/wechat/wechat.go`：

```go
// 1) 换取 access_token
u := n.conf.APIURL.Copy()
u.Path += "gettoken"
parameters.Add("corpsecret", tmpl(apiSecret))
parameters.Add("corpid", tmpl(string(n.conf.CorpID)))

// 2) 发送应用消息
postMessageURL := n.conf.APIURL.Copy()
postMessageURL.Path += "message/send"
q.Set("access_token", n.accessToken)
```

`api_url` 是**路径直接拼接**的。填群机器人地址会变成
`.../webhook/send?key=XXXgettoken` → 必定 404。
**没有任何配置方式能让 `wechat_configs` 投递到群机器人。**

---

## 四个必填校验（全部实测确认）

| 字段 | 必填 | 缺失时 operator 报错 |
|---|---|---|
| `api_secret` | ✅ | `no global Wechat Api Secret set either inline or in a file` |
| `corp_id` | ✅ | `no global Wechat CorpID set` |
| `api_url` | ❌ | 默认 `https://qyapi.weixin.qq.com/cgi-bin/` |
| `agent_id` | ❌ schema 层面 | 但业务必需（应用消息必须有 AgentId） |
| `to_party`/`to_tag`/`to_user` | ❌ | 至少要一个，否则消息无人接收 |

> `chat_id` 在二进制里存在（`ChatID.yaml:"chat_id"`）但 `WechatConfig` 结构体没有该字段，
> **无法通过 YAML 配置**——这是 Alertmanager 侧的能力缺口。

---

## 配置方式（群机器人路线）

```bash
cd /root/wecom-alert-receiver-20261001

# 企业微信群 -> 群设置 -> 群机器人 -> 添加，复制 Webhook 地址
./apply.sh --webhook-url 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<redacted>

# 只更新适配器，不切换 Alertmanager
./apply.sh --webhook-url '...' --no-switch-am

# 回滚 Alertmanager 配置
./apply.sh --rollback-am backup/alertmanager.yaml.<ts>

# 查看状态
./apply.sh --status
```

脚本特性：幂等、自动备份、使用 amtool 校验配置、热加载生效、端到端实测。

---


脚本幂等：自动备份 → 渲染模板 → 校验无残留占位符 → 写入 Secret →
等待 operator reconcile → 打印生效 receiver。config-reloader 热加载，**无需重启 Alertmanager**。

验证：
```bash
kubectl exec -n monitoring alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  wget -qO- http://127.0.0.1:9093/api/v2/receivers
# 期望: [{"name":"n8n-webhook"},{"name":"wecom"}]
```

冒烟：当前有 5 条 warning 活跃告警，写入后 ~30s 内应出现在企业微信。

---

## 路由改造（已在 `alertmanager.yaml` 模板中）

```yaml
route:
  routes:
  - receiver: wecom
    matchers: [severity =~ "critical|warning"]
    continue: true          # 继续匹配下一条子路由 → n8n 仍收到
  - receiver: n8n-webhook
    matchers: [severity =~ "critical|warning"]
```

子路由顺序即优先级：先企业微信，再 n8n。`continue: true` 保证两边都收到，
n8n 侧通知不丢。`info` / `Watchdog` 仍只走根 receiver（n8n）。

---

## 四条必须遵守的约束（均已实测，不是猜测）

### 1. 路由必须写在基础 Secret，不能写 AlertmanagerConfig CR
operator 会给 CR 的一级路由**强制注入** `namespace: <CR 所在命名空间>` 匹配器，
导致 monitoring 之外命名空间的告警永远收不到企业微信。

### 2. `{{ secret }}` 模板不可用
- 基础 Secret 里的 `{{ secret }}` operator **不会解析** —— 实测原样透传进生成配置，
  所有通知会 POST 到字面量 `{{ secret "..." }}` 而全部失败。
- `AlertmanagerConfig` CR 侧：`apiSecret` 是 SecretKeySelector（可用），
  但 `apiURL` 被 CRD `^https?://.+$` pattern 校验 + operator admission 真实 parse URL 双重卡死，
  模板方案被完全堵死。

→ **URL 与凭据只能写字面量**，存在 Secret 对象里（受 RBAC + etcd 静态加密保护），不放 CR。
→ 换凭据走 `apply.sh`。

### 3. v0.32.0 强校验 api_secret + corp_id
任一为空，operator 直接拒绝生成配置并进入热循环报错：
```
sync "monitoring/prometheus-alertmanager" failed: provision alertmanager configuration:
failed to initialize from secret: no global Wechat Api Secret set either inline or in a file
```
注意此时**生成配置保持旧值**，AM 不会崩，但 operator 每几秒刷一次错误。

### 4. 模板函数白名单 —— 没有 sprig
`template.DefaultFuncs` 只有：
```
toUpper toLower title trimSpace join match safeHtml safeUrl urlUnescape
reReplaceAll stringSlice date tz since humanizeDuration toJson list append dict
```
外加 text/template 内建：`len index slice print printf if range with eq ne lt le gt ge not and or`

**不可用**：`default` `add` `sub` `trunc` `regexReplaceAll` 等 sprig 函数。
标签/注解缺失时 map 取值返回空串，必须用 `if` 兜底，不能用 `| default`。

渲染验证（`amtool template render`，v0.32.0 真实引擎）：
- 10 条告警 → 799 字节，正确截断到 8 条并提示省略
- 单条告警 + 无 summary/description + 无 node/pod → 正确回落到 alertname 与 `-`

---

## 建议的后续优化（本次未做，属审计其他条目）

- `repeat_interval: 12h` 对 critical 过长 → 建议 critical 走 `group_interval: 1m` / `repeat_interval: 1h`（审计 §7 阶段三 #14）
- Alertmanager `replicas: 1` → 提至 2（审计 P1-5）
- `inhibit_rules` 4 条逻辑失效（审计 P2-3）
- 双发后企业微信与 n8n 都会收到，注意 `group_by` 含 `namespace`，跨命名空间会分成多条消息

---

## 回滚

```bash
cd /root/wecom-alert-receiver-20261001
LATEST=$(ls -t backup/alertmanager.yaml.* | head -1)
kubectl patch secret alertmanager-prometheus-alertmanager -n monitoring --type=json \
  -p='[{"op":"replace","path":"/data/alertmanager.yaml","value":"'$(base64 -w0 "$LATEST")"'"}]'
```

原始配置（审计时状态，仅 n8n-webhook）：
`backup/alertmanager.yaml.orig`

---

## 文件

| 文件 | 说明 |
|---|---|
| `alertmanager.yaml` | 完整配置模板（凭据为占位符） |
| `apply.sh` | 凭据注入脚本（幂等，带备份与校验） |
| `backup/alertmanager.yaml.orig` | 审计时的原始配置 |
| `backup/alertmanager.yaml.*` | 每次 apply 的自动备份 |