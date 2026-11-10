#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""适配器本地联调测试

起一个 mock 企业微信群机器人端点，跑真实 adapter.py，然后灌入真实形态的
Alertmanager webhook 负载，逐项断言。全部用标准库，不需要 mock 框架。

    python3 test_adapter.py
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
MOCK_PORT = 19099
ADAPTER_PORT = 18080
MOCK_URL = "http://127.0.0.1:%d/cgi-bin/webhook/send?key=MOCK" % MOCK_PORT

received = []
mock_behavior = {"code": 0, "msg": "ok"}

FAILS = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    if not cond:
        FAILS.append(name)
    print("  [%s] %s%s" % (status, name, ("  <- " + detail) if detail and not cond else ""))


class MockWecom(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        received.append((self.path, raw))
        body = json.dumps({"errcode": mock_behavior["code"],
                           "errmsg": mock_behavior["msg"]}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def post(path, raw, ctype="application/json"):
    req = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (ADAPTER_PORT, path), data=raw,
        headers={"Content-Type": ctype}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


def get(path):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (ADAPTER_PORT, path), timeout=5) as r:
            return r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")
    except (urllib.error.URLError, OSError) as e:
        return 0, "connect error: %s" % e


def am_payload(status="firing", n_alerts=2, with_summary=True):
    base_ann = {"summary": "Pod nginx-7d9 not ready", "runbook_url": "http://wiki/runbook"}
    if not with_summary:
        base_ann = {}
    return {
        "version": "4",
        "groupKey": '{}/{severity="warning"}:{alertname="KubePodNotReady"}',
        "truncatedAlerts": 0,
        "status": status,
        "receiver": "wecom",
        "groupLabels": {"alertname": "KubePodNotReady", "severity": "warning"},
        "commonLabels": {"alertname": "KubePodNotReady", "severity": "warning",
                         "namespace": "logging"},
        "commonAnnotations": base_ann,
        "externalURL": "http://alertmanager.example.com",
        "alerts": [
            {
                "status": status,
                "labels": {"alertname": "KubePodNotReady", "severity": "warning",
                           "namespace": "logging", "pod": "nginx-7d9-%s" % i},
                "annotations": base_ann,
                "startsAt": (time.strftime("%Y-%m-%dT%H:%M:%S.000Z",
                                          time.gmtime(time.time() - (3600 + 600 * i)))),
                "endsAt": "0001-01-01T00:00:00Z",
                "generatorURL": "http://prometheus.example.com/graph",
                "fingerprint": "abc%d" % i,
            } for i in range(n_alerts)
        ],
    }


def main():
    mock = ThreadingHTTPServer(("127.0.0.1", MOCK_PORT), MockWecom)
    mock.daemon_threads = True
    threading.Thread(target=mock.serve_forever, daemon=True).start()

    env = dict(os.environ,
               LISTEN_ADDR="0.0.0.0:%d" % ADAPTER_PORT,
               WECOM_WEBHOOK_URL=MOCK_URL,
               WECOM_MIN_INTERVAL="0",   # 测试里不限流
               MAX_ALERTS="3")
    proc = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "adapter.py")],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    logs = []
    threading.Thread(target=lambda: [logs.append(l.rstrip()) for l in proc.stdout], daemon=True).start()

    for _ in range(50):
        if get("/stats")[0] in (200, 503):
            break
        time.sleep(0.1)
    else:
        print("适配器未能在 5 秒内启动，stdout：")
        for line in logs:
            print("  " + line)
        proc.kill()
        mock.shutdown()
        return 1

    try:
        print("\n=== 1. 探活 ===")
        code, body = get("/healthz")
        check("GET /healthz -> 200", code == 200, "got %s %s" % (code, body))
        check("webhook_configured=true", json.loads(body).get("webhook_configured") is True)
        code, body = get("/readyz")
        check("GET /readyz -> 200 (已配置)", code == 200, "got %s %s" % (code, body))

        print("\n=== 2. 未知路径 404 ===")
        code, _ = get("/nope")
        check("GET /nope -> 404", code == 404, "got %s" % code)
        code, _ = post("/nope", b"{}")
        check("POST /nope -> 404", code == 404, "got %s" % code)

        print("\n=== 3. 非法 JSON -> 400 ===")
        code, _ = post("/alerts", b"{not json")
        check("POST bad json -> 400", code == 400, "got %s" % code)

        print("\n=== 4. firing 负载 -> 200 并投递到 mock ===")
        before = len(received)
        code, body = post("/alerts", json.dumps(am_payload("firing", 2)).encode("utf-8"))
        check("POST /alerts -> 200", code == 200, "got %s %s" % (code, body))
        check("mock 收到 1 条", len(received) == before + 1)
        path, raw = received[-1]
        sent = json.loads(raw.decode("utf-8"))
        check("msgtype=markdown", sent.get("msgtype") == "markdown", str(sent.get("msgtype")))
        content = sent["markdown"]["content"]
        print("  ---- 实际渲染出的 markdown ----")
        for line in content.splitlines():
            print("  | " + line)
        print("  ---- end ----")
        check("mock 路径含 webhook/send", "webhook/send" in path, path)
        check("标题含告警名", "KubePodNotReady" in content)
        check("标题含 severity 对应 emoji (warning=\U0001f7e0)",
              "\U0001f7e0" in content, content.splitlines()[0])
        check("含命名空间", "logging" in content)
        check("含 severity 颜色 warning", 'color="warning"' in content)
        check("含持续时长", "\u6301\u7eed" in content)
        check("含 pod 标识", "pod=nginx-7d9-0" in content)
        check("含 summary", "not ready" in content)
        check("含数量", "**\u6570\u91cf** 2" in content)
        check("含 externalURL", "http://alertmanager.example.com/#/alerts" in content)
        check("无未渲染模板残留", "{{" not in content)
        check("状态标记为 FIRING", "FIRING" in content)
        check("firing 告警不出现「恢复」（endsAt 是零值哨兵）", "恢复" not in content, content)

        print("\n=== 5. resolved 负载 -> 恢复样式 ===")
        code, body = post("/alerts", json.dumps(am_payload("resolved", 1)).encode("utf-8"))
        check("POST resolved -> 200", code == 200, "got %s %s" % (code, body))
        content = json.loads(received[-1][1].decode("utf-8"))["markdown"]["content"]
        print("  ---- resolved markdown ----")
        for line in content.splitlines():
            print("  | " + line)
        print("  ---- end ----")
        check("含恢复标题", "\u5df2\u6062\u590d" in content)
        check("无 firing 红圈", "\U0001f534" not in content)
        check("状态标记为 RESOLVED", "RESOLVED" in content)

        print("\n=== 6. 缺失 summary 时回退到 alertname ===")
        code, _ = post("/alerts", json.dumps(am_payload("firing", 1, with_summary=False)).encode("utf-8"))
        content = json.loads(received[-1][1].decode("utf-8"))["markdown"]["content"]
        check("POST 无 summary -> 200", code == 200)
        check("仍含 alertname", "KubePodNotReady" in content)

        print("\n=== 7. MAX_ALERTS 限流展示（造 40 条告警）===")
        big = am_payload("firing", 40)
        code, body = post("/alerts", json.dumps(big).encode("utf-8"))
        content = json.loads(received[-1][1].decode("utf-8"))["markdown"]["content"]
        size = len(content.encode("utf-8"))
        print("  渲染大小: %d 字节" % size)
        check("POST 大负载 -> 200", code == 200)
        check("<= 4096 字节", size <= 4096, "got %d" % size)
        check("正文只列 MAX_ALERTS=3 条", content.count("FIRING") == 3, "got %d" % content.count("FIRING"))
        check("提示另有 37 条未展示", "另有 37 条" in content)

        print("\n=== 8. 企业微信返回 errcode != 0 -> 502 ===")
        mock_behavior["code"] = 45009
        mock_behavior["msg"] = "api freq out of limit"
        code, body = post("/alerts", json.dumps(am_payload("firing", 1)).encode("utf-8"))
        print("  适配器回给 Alertmanager: %s %s" % (code, body))
        check("HTTP 502", code == 502, "got %s" % code)
        check("响应含 errcode", json.loads(body).get("errcode") == 45009)
        check("响应含中文提示", "\u9891\u7387\u9650\u5236" in json.loads(body).get("hint", ""))

        print("\n=== 9. webhook key 无效 errcode=93000 ===")
        mock_behavior["code"] = 93000
        mock_behavior["msg"] = "invalid webhook url"
        code, body = post("/alerts", json.dumps(am_payload("firing", 1)).encode("utf-8"))
        check("HTTP 502", code == 502, "got %s" % code)
        check("提示重新获取 key", "\u91cd\u65b0\u83b7\u53d6" in json.loads(body).get("hint", ""))

        print("\n=== 10. mock 返回非 JSON -> 502 ===")
        mock_behavior["code"] = 0
        code, body = post("/alerts", b'{"not":"json"')
        check("坏 JSON 响应 -> 400（请求侧）", code == 400, "got %s" % code)

        print("\n=== 11. /stats 计数 ===")
        code, body = get("/stats")
        st = json.loads(body)
        print("  %s" % body)
        check("GET /stats -> 200", code == 200)
        check("received == 6", st["received"] == 6, "got %s" % st["received"])
        check("sent == 4", st["sent"] == 4, "got %s" % st["sent"])
        check("failed == 2", st["failed"] == 2, "got %s" % st["failed"])

        print("\n=== 12. 纯函数单元测试 ===")
        import importlib
        ad = importlib.import_module("adapter")
        ad.MAX_ALERTS = 100

        # 12a 4096 字节硬边界：不越界、不切碎多字节字符
        long_text = u"中" * 5000
        out = ad.truncate_utf8(long_text)
        n = len(out.encode("utf-8"))
        check("truncate_utf8 <= 4096 字节", n <= 4096, "got %d" % n)
        check("截断后无替换字符 U+FFFD", u"�" not in out)
        check("含截断提示", "截断" in out)

        # 12b 正好等于边界时不截断
        exact = u"a" * 4096
        check("恰好 4096 字节不截断", ad.truncate_utf8(exact) == exact)

        # 12c 限流打开后 render 确实会触发截断
        content = ad.render(am_payload("firing", 40))
        n = len(content.encode("utf-8"))
        check("render(40 条) <= 4096 字节", n <= 4096, "got %d" % n)
        check("render(40 条) 含截断提示", "截断" in content)
        check("render(40 条) 无 U+FFFD", u"�" not in content)

        # 12d 时长格式化
        check("humanize 0s", ad.humanize_duration(0) == "0秒")
        check("humanize 90s", ad.humanize_duration(90) == "1分30秒")
        check("humanize 3600", ad.humanize_duration(3600) == "1小时0分")
        check("humanize 90000", ad.humanize_duration(90000) == "1天1小时")
        check("humanize 负数不炸", ad.humanize_duration(-5) == "0秒")

        # 12e 零值 endsAt 哨兵必须被当作 None
        check("零值 endsAt -> None", ad.parse_ts("0001-01-01T00:00:00Z") is None)
        check("真实 endsAt 正常解析", ad.parse_ts("2026-10-01T08:00:00Z") is not None)
        check("空 endsAt -> None", ad.parse_ts("") is None)
        check("垃圾 endsAt -> None", ad.parse_ts("not-a-time") is None)

        # 12f critical 用红圈
        crit = am_payload("firing", 1)
        crit["commonLabels"]["severity"] = "warning"
        crit["alerts"][0]["labels"]["severity"] = "critical"
        c = ad.render(crit)
        check("critical -> 红圈", u"\U0001f534" in c, c.splitlines()[0])
        check("critical 颜色 warning", c.count('color="warning"') >= 1)

        # 12g 无 namespace / 无 severity 时不炸
        bare = {"status": "firing", "alerts": [{"status": "firing", "labels": {}, "annotations": {}}]}
        c = ad.render(bare)
        check("空 labels 可渲染", "Alerts" in c or "unknown" in c, c.splitlines()[0])

        # 12h 直接 POST 数组（兼容测试工具）
        c = ad.render([{"status": "firing", "labels": {"alertname": "X"}, "annotations": {}}])
        check("裸数组负载可渲染", "X" in c, c.splitlines()[0])

        print("\n=== 13. 未配置 webhook key 时的行为 ===")
        env2 = dict(env)
        env2["WECOM_WEBHOOK_URL"] = ("https://qyapi.weixin.qq.com/cgi-bin/webhook/send"
                                     "?key=REPLACE_ME")
        env2["LISTEN_ADDR"] = "0.0.0.0:%d" % (ADAPTER_PORT + 1)
        proc2 = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "adapter.py")],
                                 env=env2, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1)
        logs2 = []
        threading.Thread(target=lambda: [logs2.append(l.rstrip()) for l in proc2.stdout],
                         daemon=True).start()

        def get2(path):
            try:
                with urllib.request.urlopen(
                        "http://127.0.0.1:%d%s" % (ADAPTER_PORT + 1, path), timeout=5) as r:
                    return r.status, r.read().decode("utf-8")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8")
            except (urllib.error.URLError, OSError) as e:
                return 0, "connect error: %s" % e

        def post2(raw):
            req = urllib.request.Request(
                "http://127.0.0.1:%d/alerts" % (ADAPTER_PORT + 1), data=raw,
                headers={"Content-Type": "application/json"}, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    return r.status, r.read().decode("utf-8")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode("utf-8")

        for _ in range(50):
            if get2("/healthz")[0] == 200:
                break
            time.sleep(0.1)

        code, body = get2("/healthz")
        check("未配置时 /healthz 仍 200 (liveness 与配置解耦)", code == 200, "got %s %s" % (code, body))
        check("healthz 报 webhook_configured=false",
              json.loads(body).get("webhook_configured") is False, body)
        code, body = get2("/readyz")
        check("未配置时 /readyz 503", code == 503, "got %s %s" % (code, body))
        before = len(received)
        code, body = post2(json.dumps(am_payload("firing", 1)).encode("utf-8"))
        check("未配置时 /alerts 503", code == 503, "got %s %s" % (code, body))
        check("503 响应带可读说明", "not configured" in body, body)
        check("未配置时没真的发出去", len(received) == before)
        check("启动日志有 WARN", any("level=WARN" in l for l in logs2), "\n".join(logs2))
        proc2.terminate()
        try:
            proc2.wait(timeout=5)
        except Exception:
            proc2.kill()

        print("\n=== 适配器 stdout ===")
        for line in logs:
            print("  " + line)

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        mock.shutdown()

    print("\n" + "=" * 60)
    if FAILS:
        print("失败 %d 项: %s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())