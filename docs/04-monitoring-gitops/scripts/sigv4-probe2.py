#!/usr/bin/env python3
"""
决定性实验：RGW 能否正确处理「合法的空 aws-chunked 流式载荷」

关键认识（重新解析抓包后得出）：
  minio-go 发的 body 在 **HTTP chunked 层和 aws-chunked 层都是合法的**。
  HTTP 层: 56\\r\\n<86字节>\\r\\n0\\r\\n\\r\\n
  aws 层: 86 字节 == 0;chunk-signature=<sig>\\r\\n\\r\\n  ← 合法空载荷

  所以「minio-go 帧畸形」是误判。真正的疑点是 RGW 解析。

本脚本按 minio-go 的双层分帧原样构造请求，签名则由本实现正确计算
（第 1 步用非空载荷自证实现正确）。
"""
import hashlib
import hmac
import socket
import sys
import datetime
import re

HOST, PORT = "10.0.0.31", 7480
BUCKET = "tempo-traces"
REGION, SERVICE = "us-east-1", "s3"
EMPTY_SHA = hashlib.sha256(b"").hexdigest()


def h(x):
    if isinstance(x, str):
        x = x.encode("utf-8")
    return hashlib.sha256(x).hexdigest()


def build(ak, sk, key, payload, wrap_http_chunked):
    """构造 minio-go 风格请求。payload 为解码前的原始数据。"""
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    path = "/{}/{}".format(BUCKET, key)
    hdrs = {
        "Host": "{}:{}".format(HOST, PORT),
        "User-Agent": "MinIO (linux; amd64) minio-go/v7.0.98",
        "Content-Type": "application/octet-stream",
        "X-Amz-Date": amzdate,
        "X-Amz-Content-Sha256": "STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
        "X-Amz-Decoded-Content-Length": str(len(payload)),
    }

    # --- SigV4 seed（严格对齐 minio-go 的 SignedHeaders 集合）---
    signed = ["host", "x-amz-content-sha256", "x-amz-date",
              "x-amz-decoded-content-length"]
    canon_headers = "".join("{}:{}\n".format(k, hdrs[
        {"host": "Host", "x-amz-content-sha256": "X-Amz-Content-Sha256",
         "x-amz-date": "X-Amz-Date",
         "x-amz-decoded-content-length": "X-Amz-Decoded-Content-Length"}[k]])
        for k in signed)
    creq = "\n".join(["PUT", path, "", canon_headers, ";".join(signed),
                      "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"])
    scope = "{}/{}/{}/aws4_request".format(datestamp, REGION, SERVICE)
    sts = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, h(creq)])

    k = hmac.new(("AWS4" + sk).encode(), datestamp.encode(), hashlib.sha256).digest()
    for part in (REGION, SERVICE, "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    # seed 只用于 Authorization 头；prev 是链上轮转值，两者必须分开
    seed = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    prev = seed

    # --- aws-chunked 编码 ---
    CHUNK = 64 * 1024
    aws = bytearray()
    if payload:
        for off in range(0, len(payload), CHUNK):
            d = payload[off:off + CHUNK]
            c = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev,
                           EMPTY_SHA, h(d)])
            prev = hmac.new(k, c.encode(), hashlib.sha256).hexdigest()
            aws += "{:x};chunk-signature={}\r\n".format(len(d), prev).encode() + d + b"\r\n"
    f = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev, EMPTY_SHA, ""])
    prev = hmac.new(k, f.encode(), hashlib.sha256).hexdigest()
    aws += "0;chunk-signature={}\r\n\r\n".format(prev).encode()

    if wrap_http_chunked:
        body = bytearray()
        # minio-go 的做法：把 aws-chunked 字节流再用 HTTP chunked 包一层
        for off in range(0, len(aws), 0xFFFF) or [0]:
            seg = aws[off:off + 0xFFFF]
            if seg:
                body += "{:x}\r\n".format(len(seg)).encode() + seg + b"\r\n"
        body += b"0\r\n\r\n"
        body = bytes(body)
        te = "Transfer-Encoding: chunked"
    else:
        body = bytes(aws)
        te = "Content-Length: {}".format(len(body))

    raw = "PUT {} HTTP/1.1\r\n".format(path).encode()
    for k2, v in hdrs.items():
        raw += "{}: {}\r\n".format(k2, v).encode()
    raw += ("Authorization: AWS4-HMAC-SHA256 Credential={}/{}, "
            "SignedHeaders={}, Signature={}\r\n".format(
                ak, scope, ";".join(signed), seed)).encode()
    raw += te.encode() + b"\r\n\r\n" + body
    return raw, bytes(aws)


def send(payload, timeout=25):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.sendall(payload)
    buf = b""
    while True:
        try:
            c = s.recv(65536)
        except socket.timeout:
            break
        if not c:
            break
        buf += c
        if b"\r\n\r\n" in buf:
            hh, _, rest = buf.partition(b"\r\n\r\n")
            cl = re.search(rb"Content-Length:\s*(\d+)", hh)
            if cl and len(rest) >= int(cl.group(1)):
                break
    s.close()
    t = buf.decode(errors="replace")
    return t.split("\r\n", 1)[0], t


def show(label, line, txt):
    print("  [{}] {}".format(label, line))
    for tag, name in (("Code", "Code"), ("Message", "Message")):
        m = re.search(r"<{0}>([^<]+)</{0}>".format(tag), txt)
        if m:
            print("        {:8s}= {}".format(name, m.group(1)))
    et = re.search(r'"ETag":\s*"([^"]+)"', txt)
    if et:
        print("        ETag    = {}".format(et.group(1)))


if __name__ == "__main__":
    ak, sk = sys.argv[1], sys.argv[2]
    ok = True

    print("=" * 74)
    print("第 1 步 · 自证：用【纯 aws-chunked + Content-Length】发非空载荷")
    print("         （若这步都失败，说明本实现或 RGW 有别的问题，后续无意义）")
    print("=" * 74)
    for n in (100, 70000):
        data = bytes((i * 7 + n) % 256 for i in range(n))
        raw, aws = build(ak, sk, ".lgmt-v4-plain", data, False)
        line, txt = send(raw)
        show("{} 字节, aws层 {} 字节".format(n, len(aws)), line, txt)
        if "200" not in line:
            ok = False
            print("        ✗ 自证失败，停止")
    if not ok:
        sys.exit(1)

    print()
    print("=" * 74)
    print("第 2 步 · 决定性：0 字节，两种分帧方式对比")
    print("=" * 74)
    results = {}
    for wrap, desc in ((False, "纯 aws-chunked + Content-Length"),
                       (True, "minio-go 双层(HTTP chunked 包 aws-chunked)")):
        raw, aws = build(ak, sk, ".lgmt-v4-empty", b"", wrap)
        line, txt = send(raw)
        print()
        print("  ── {} ".format(desc))
        print("     HTTP body = {!r}".format(raw.split(b"\r\n\r\n", 1)[1]))
        print("     解出的 aws-chunked 载荷 = {!r}".format(aws))
        show("     结果", line, txt)
        results[desc] = "200" in line

    print()
    print("=" * 74)
    for desc, good in results.items():
        print("  {:46s} → {}".format(desc, "200 OK" if good else "拒绝"))
    print()
    if all(results.values()):
        print("  ▶ RGW 能正确处理合法空流式载荷")
        print("    → 缺陷在客户端(minio-go)，代理方案成立")
    elif not any(results.values()):
        print("  ▶ RGW 拒绝**合法**的空流式载荷（两种分帧都拒）")
        print("    → 缺陷在 RGW 17.2.8，对应 Red Hat BZ 2270529 / RHBA-2024:2743")
        print("    → 应修 RGW（升级），代理属于掩盖服务端缺陷的野路子")
    else:
        print("  ▶ 两种分帧结果不同 → RGW 期望的分帧形态与 minio-go 不同")
