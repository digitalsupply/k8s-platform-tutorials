#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Alertmanager -> 企业微信群机器人 适配器

为什么需要它
------------
Alertmanager v0.32.0 的原生 `wechat_configs` 只能调用「企业微信自建应用」接口：
`notify/wechat/wechat.go` 里 api_url 被硬编码拼接成 `gettoken` 与 `message/send`。
把 api_url 指向群机器人 webhook 会得到 `.../webhook/send?key=XXXgettoken` -> 404。
而自建应用路线要求可信域名 / 接收消息服务器URL / 可信IP 三重门槛。

本服务接住 Alertmanager 的 webhook 负载，转成群机器人要求的
`{"msgtype":"markdown","markdown":{"content":...}}` 后转发，
从而用「群机器人」这条零门槛通道完成告警投递。

约束与取舍
----------
* 纯标准库，无第三方依赖 -> 镜像只需 python:3.12-alpine
* 群机器人限流 20 条/分钟 -> 发送端串行 + 最小间隔 WECOM_MIN_INTERVAL(默认 3s)
* 企业微信 HTTP 200 但 errcode != 0 时，返回 502 给 Alertmanager，
  使 alertmanager_notifications_failed_total 能反映真实投递结果（而不是假成功）
* markdown content 上限 4096 字节（企业微信硬限制），按 UTF-8 rune 边界截断
* webhook key 来自 Secret 注入，不写死在代码/ConfigMap 里
"""

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0:8080")
WECOM_WEBHOOK_URL = os.environ.get("WECOM_WEBHOOK_URL", "").strip()
MIN_INTERVAL = float(os.environ.get("WECOM_MIN_INTERVAL", "3"))
HTTP_TIMEOUT = float(os.environ.get("WECOM_TIMEOUT", "8"))
MAX_BYTES = int(os.environ.get("MAX_CONTENT_BYTES", "4096"))
MAX_ALERTS = int(os.environ.get("MAX_ALERTS", "10"))

# 严重级别 -> (emoji, 企业微信 markdown 颜色)
# 企业微信 markdown 仅支持 info / comment / warning 三种字体颜色
SEVERITY_STYLE = {
    "critical": ("\U0001f534", "warning"),
    "warning": ("\U0001f7e0", "warning"),
    "info": ("\U0001f535", "info"),
    "none": ("\u26aa", "info"),
}

# 用于在分组内挑最严重的一条来决定标题颜色
SEVERITY_RANK = {"critical": 3, "warning": 2, "info": 1, "none": 0}

# 群机器人限流相关错误码 -> 提示
ERRCODE_HINT = {
    45009: "触发群机器人频率限制（20 条/分钟）",
    93000: "webhook key 无效或机器人已被移除，请重新获取",
    40058: "webhook key 非法",
    40001: "access_token 无效（本通道不该出现，说明配置串了）",
}

_send_lock = threading.Lock()
_last_send_at = [0.0]

_stats_lock = threading.Lock()
_stats = {
    "received": 0,
    "sent": 0,
    "failed": 0,
    "skipped_empty": 0,
    "last_errcode": None,
    "last_error": None,
    "last_sent_at": None,
}


def log(level, msg, **kw):
    parts = ["time=%s" % datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"),
             "level=%s" % level, "msg=%s" % msg]
    for k in kw:
        parts.append("%s=%s" % (k, kw[k]))
    sys.stdout.write(" ".join(parts) + "\n")
    sys.stdout.flush()


def bump(**kw):
    with _stats_lock:
        for k, v in kw.items():
            if k in _stats:
                _stats[k] = v


def bump_stat(key, delta=1):
    with _stats_lock:
        _stats[key] = _stats.get(key, 0) + delta


def set_stat(**kw):
    with _stats_lock:
        _stats.update(kw)


# --------------------------------------------------------------------------
# 文本处理
# --------------------------------------------------------------------------

def humanize_duration(seconds):
    """把秒数写成中文时长（不依赖 sprig / 外部库）。"""
    seconds = int(max(0, seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    if days:
        return "%d\u5929%d\u5c0f\u65f6" % (days, hours)
    if hours:
        return "%d\u5c0f\u65f6%d\u5206" % (hours, minutes)
    if minutes:
        return "%d\u5206%d\u79d2" % (minutes, secs)
    return "%d\u79d2" % secs


def parse_ts(value):
    """解析 Alertmanager 的 RFC3339 时间戳，失败返回 None。

    注意：Alertmanager 对仍 firing 的告警会发 endsAt="0001-01-01T00:00:00Z"
    这个零值哨兵，必须当成「没有结束时间」，否则会渲染出「恢复 01-01」这种垃圾。
    """
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.year < 1971:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def fmt_ts(dt):
    if dt is None:
        return "\u672a\u77e5"
    return dt.astimezone().strftime("%m-%d %H:%M:%S")


def truncate_utf8(text, limit=None):
    """按 UTF-8 字节数截断，且不切碎多字节字符。"""
    limit = limit or MAX_BYTES
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    tail = "\n> \u2026\u5185\u5bb9\u8fc7\u957f\u5df2\u622a\u65ad\uff08%d/%d \u5b57\u8282\uff09" % (
        len(raw), limit)
    budget = max(0, limit - len(tail.encode("utf-8")))
    head = raw[:budget].decode("utf-8", "ignore")
    return head.rstrip() + tail


# --------------------------------------------------------------------------
# 消息渲染
# --------------------------------------------------------------------------

def worst_severity(common_labels, alerts):
    """取分组内最高严重级别。

    不用 commonLabels.severity 是因为它只在「所有告警共有」时才正确；
    一旦 group_by 不含 severity，一个含 critical 的分组会被整体标成橙色，
    反而把最该看的那条降级了。
    """
    best = str((common_labels or {}).get("severity") or "none").lower()
    for alert in alerts or []:
        if not isinstance(alert, dict):
            continue
        sev = str((alert.get("labels") or {}).get("severity") or "").lower()
        if SEVERITY_RANK.get(sev, 0) > SEVERITY_RANK.get(best, 0):
            best = sev
    return best if best in SEVERITY_STYLE else "none"


def alert_title(alert, labels):
    """挑一个人类可读的对象标识。"""
    for key in ("pod", "node", "instance", "container", "deployment"):
        val = labels.get(key)
        if val:
            return "%s=%s" % (key, val)
    for key in ("namespace", "job"):
        val = labels.get(key)
        if val:
            return val
    return labels.get("alertname", "unknown")


def render(payload):
    """Alertmanager webhook payload -> 群机器人 markdown content"""
    if not isinstance(payload, dict):
        # 兼容直接 POST 一个告警数组的测试工具
        payload = {"status": "firing", "alerts": payload if isinstance(payload, list) else []}

    status = str(payload.get("status") or "firing")
    firing = status == "firing"
    common_labels = payload.get("commonLabels") or {}
    common_annotations = payload.get("commonAnnotations") or {}
    alerts = payload.get("alerts") or []

    alertname = common_labels.get("alertname") or "Alerts"
    severity = worst_severity(common_labels, alerts)
    emoji, color = SEVERITY_STYLE[severity]
    namespace = common_labels.get("namespace")
    resolved_color = "info" if not firing else color

    if firing:
        title = "## %s \u7c07\u96c6\u544a\u8b66 \u00b7 %s" % (emoji, alertname)
    else:
        title = "## \u2705 \u7c07\u96c6\u544a\u8b66\u5df2\u6062\u590d \u00b7 %s" % alertname

    lines = [title, ""]

    facts = []
    if namespace:
        facts.append("**\u547d\u540d\u7a7a\u95f4** `%s`" % namespace)
    facts.append("**\u4e25\u91cd\u7ea7\u522b** `<font color=\"%s\">%s</font>`" % (resolved_color, severity.upper()))
    facts.append("**\u6570\u91cf** %d" % len(alerts))
    lines.append("> " + " \u00b7 ".join(facts))
    lines.append("")

    summary = common_annotations.get("summary")
    if summary and not summary.strip():
        summary = None
    if summary:
        lines.append("> %s" % str(summary).replace("\n", " ").strip())
        lines.append("")

    now = datetime.now(timezone.utc)
    for idx, alert in enumerate(alerts[:MAX_ALERTS]):
        if not isinstance(alert, dict):
            continue
        labels = alert.get("labels") or {}
        annotations = alert.get("annotations") or {}
        sev = str(labels.get("severity") or severity).lower()
        _, sev_color = SEVERITY_STYLE.get(sev, SEVERITY_STYLE["none"])

        state = "firing" if alert.get("status") == "firing" else "resolved"
        head = "%d. `%s` \u2014 <font color=\"%s\">%s</font>" % (
            idx + 1, alert_title(alert, labels), sev_color, state.upper())
        lines.append(head)

        detail = annotations.get("summary") or annotations.get("description")
        if detail:
            for line in str(detail).splitlines():
                if line.strip():
                    lines.append("   > %s" % line.strip())
        started = parse_ts(alert.get("startsAt"))
        ended = parse_ts(alert.get("endsAt"))
        if started:
            end_ref = ended if ended and state == "resolved" else now
            elapsed = (end_ref - started).total_seconds()
            tail = "\u89e6\u53d1 %s" % fmt_ts(started)
            if elapsed > 0:
                tail += " \u00b7 \u6301\u7eed %s" % humanize_duration(elapsed)
            if state == "resolved" and ended:
                tail += " \u00b7 \u6062\u590d %s" % fmt_ts(ended)
            lines.append("   > %s" % tail)
        lines.append("")

    hidden = len(alerts) - MAX_ALERTS
    if hidden > 0:
        lines.append("> \u53e6\u6709 %d \u6761\u544a\u8b66\u672a\u5c55\u793a" % hidden)
        lines.append("")

    if summary is None and not alerts:
        lines.append("> \u65e0\u9644\u52a0\u8be6\u60c5")
        lines.append("")

    external = str(payload.get("externalURL") or "").rstrip("/")
    lines.append("---")
    footer = "Alertmanager \u00b7 receiver `wecom` \u00b7 group `%s`" % payload.get("groupKey", "?")
    if external:
        footer += "\n\u67e5\u770b\u5168\u90e8: %s/#/alerts" % external
    lines.append("<font color=\"comment\">%s</font>" % footer)

    return truncate_utf8("\n".join(lines))


# --------------------------------------------------------------------------
# 转发到群机器人
# --------------------------------------------------------------------------

class WecomError(Exception):
    def __init__(self, errcode, errmsg):
        Exception.__init__(self, "errcode=%s errmsg=%s" % (errcode, errmsg))
        self.errcode = errcode
        self.errmsg = errmsg


def post_to_wecom(content):
    body = json.dumps({"msgtype": "markdown", "markdown": {"content": content}},
                      ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        WECOM_WEBHOOK_URL,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8",
                 "User-Agent": "wecom-alert-adapter/1.0"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raise WecomError("http_%d" % exc.code, exc.reason)
    except Exception as exc:  # network / DNS / TLS
        raise WecomError("transport", "%s: %s" % (type(exc).__name__, exc))

    try:
        parsed = json.loads(raw)
    except ValueError:
        raise WecomError("bad_response", raw[:200])
    if not isinstance(parsed, dict):
        raise WecomError("bad_response", raw[:200])
    if parsed.get("errcode") != 0:
        raise WecomError(parsed.get("errcode"), parsed.get("errmsg"))
    return parsed


def deliver(content):
    """串行化 + 限流地投递一条消息。"""
    with _send_lock:
        wait = MIN_INTERVAL - (time.monotonic() - _last_send_at[0])
        if wait > 0:
            time.sleep(wait)
        try:
            return post_to_wecom(content)
        finally:
            _last_send_at[0] = time.monotonic()


def webhook_ready():
    return bool(WECOM_WEBHOOK_URL) and "REPLACE_ME" not in WECOM_WEBHOOK_URL


# --------------------------------------------------------------------------
# HTTP 层
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "wecom-alert-adapter/1.0"

    def _reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            # liveness: 进程还能服务就算活。webhook 没配好不算「不健康」——
            # 重启解决不了；而且让 Pod 保持 Ready，才能把带说明的 503 返回给
            # Alertmanager（否则 Service 无 endpoints，AM 只看到一个
            # "connection refused"，排查时信息量少得多）。
            self._reply(200, {"ok": True, "webhook_configured": webhook_ready()})
        elif path in ("/readyz", "/-/ready"):
            # readiness 语义位，只给人看，不接探针：
            # 一旦接上，key 没配好时 Pod 就永不 Ready，rollout 也会死等。
            ready = webhook_ready()
            self._reply(200 if ready else 503,
                        {"ok": ready, "webhook_configured": ready})
        elif path in ("/stats", "/-/stats"):
            with _stats_lock:
                self._reply(200, dict(_stats))
        else:
            self._reply(404, {"error": "not found",
                              "paths": ["/alerts", "/healthz", "/readyz", "/stats"]})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/alerts", "/"):
            self._reply(404, {"error": "not found"})
            return
        if not webhook_ready():
            log("ERROR", "webhook not configured, rejecting",
                placeholder="REPLACE_ME" in WECOM_WEBHOOK_URL,
                configured=bool(WECOM_WEBHOOK_URL))
            self._reply(503, {"error": "WECOM_WEBHOOK_URL not configured"})
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            log("ERROR", "bad request body", err=str(exc))
            self._reply(400, {"error": "invalid json: %s" % exc})
            return

        bump_stat("received")
        content = render(payload)
        alertname = (payload.get("commonLabels") or {}).get("alertname") \
            if isinstance(payload, dict) else None
        state = payload.get("status") if isinstance(payload, dict) else "?"

        try:
            deliver(content)
        except WecomError as exc:
            hint = ERRCODE_HINT.get(exc.errcode, "")
            set_stat(last_errcode=str(exc.errcode), last_error=str(exc))
            bump_stat("failed")
            log("ERROR", "delivery failed", alertname=alertname, state=state,
                errcode=exc.errcode, errmsg=exc.errmsg, hint=hint)
            self._reply(502, {"delivered": False,
                              "errcode": exc.errcode,
                              "errmsg": exc.errmsg,
                              "hint": hint})
            return

        set_stat(last_errcode=0, last_error=None,
                 last_sent_at=datetime.now(timezone.utc).isoformat())
        bump_stat("sent")
        log("INFO", "delivered", alertname=alertname, state=state,
            bytes=len(content.encode("utf-8")), alerts=len(payload.get("alerts") or []))
        self._reply(200, {"delivered": True, "bytes": len(content.encode("utf-8"))})

    def log_message(self, fmt, *args):
        log("DEBUG", "http", peer=self.address_string(), line=fmt % args)


def main():
    host, _, port = LISTEN_ADDR.rpartition(":")
    port = int(port or 8080)
    log("INFO", "starting", listen=LISTEN_ADDR,
        webhook_configured=webhook_ready(),
        min_interval=MIN_INTERVAL, max_alerts=MAX_ALERTS,
        max_content_bytes=MAX_BYTES, python=sys.version.split()[0])
    if not webhook_ready():
        log("WARN", "WECOM_WEBHOOK_URL 未配置或仍是占位符，"
                    "/alerts 返回 503，/readyz 返回 503（/healthz 仍为 200，"
                    "让 Pod 保持 Ready 以便把错误明确回给 Alertmanager）")
    server = ThreadingHTTPServer((host or "0.0.0.0", port), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("INFO", "shutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()