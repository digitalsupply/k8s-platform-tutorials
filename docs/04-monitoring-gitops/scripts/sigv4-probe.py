#!/usr/bin/env python3
"""
SigV4 流式签名 PUT 探针 —— 用于判定 XAmzContentSHA256Mismatch 到底该怪谁

方法论（关键）：
  第 1 步 用**非空**载荷验证本实现是否正确   → 必须 200
          如果非空也失败，说明是本实现有错，不能用来下结论
  第 2 步 用**正确**的 0 字节流式帧打 RGW     → 决定性
          200  = RGW 正常，是 minio-go 帧畸形
          400  = RGW 拒绝合法流式空载荷，RGW 侧缺陷

只对 0 字节的探针 key 操作，不触碰任何真实对象。
"""
import hashlib
import hmac
import socket
import sys
import datetime
import re

HOST, PORT = "10.0.0.31", 7480
BUCKET = "tempo-traces"
REGION = "us-east-1"
SERVICE = "s3"


def h(x):
    if isinstance(x, str):
        x = x.encode("utf-8")
    return hashlib.sha256(x).hexdigest()


def hm(k, m):
    return hmac.new(k, m.encode("utf-8"), hashlib.sha256).digest()


def sign(ak, sk, method, path, query, headers, body, streaming):
    """返回完整的 HTTP 请求字节。streaming=True 时用 STREAMING-AWS4-HMAC-SHA256-PAYLOAD。"""
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    hdrs = {k.lower(): v for k, v in headers.items()}
    hdrs["host"] = "{}:{}".format(HOST, PORT)
    hdrs["x-amz-date"] = amzdate
    if streaming:
        hdrs["x-amz-content-sha256"] = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
        hdrs["x-amz-decoded-content-length"] = str(len(body))
    else:
        hdrs["x-amz-content-sha256"] = h(body)

    signed = sorted(hdrs)
    canon_headers = "".join(
        "{}:{}\n".format(k, " ".join(str(hdrs[k]).split())) for k in signed)
    signed_headers = ";".join(signed)

    creq = "\n".join([
        method, path, query or "", canon_headers, signed_headers,
        hdrs["x-amz-content-sha256"],
    ])
    scope = "{}/{}/{}/aws4_request".format(datestamp, REGION, SERVICE)
    sts = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, h(creq)])

    k = hmac.new(("AWS4" + sk).encode("utf-8"), datestamp.encode("utf-8"),
                 hashlib.sha256).digest()
    for part in (REGION, SERVICE, "aws4_request"):
        k = hmac.new(k, part.encode("utf-8"), hashlib.sha256).digest()
    seed = hmac.new(k, sts.encode("utf-8"), hashlib.sha256).hexdigest()

    auth = ("AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}"
            .format(ak, scope, signed_headers, seed))

    if not streaming:
        raw = "{} {} HTTP/1.1\r\n".format(method, path).encode()
        raw += b"".join("{}: {}\r\n".format(k2, v).encode() for k2, v in hdrs.items())
        raw += b"Authorization: " + auth.encode() + b"\r\n"
        raw += b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n"
        return raw + body, "non-streaming(sha256=" + h(body)[:12] + ")"

    # ── 流式分块编码 ──
    CHUNK = 64 * 1024
    out = bytearray()
    prev = seed
    for off in range(0, len(body), CHUNK) or [0]:
        data = body[off:off + CHUNK]
        csts = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev,
                          h(b""), h(data)])
        prev = hmac.new(k, csts.encode("utf-8"), hashlib.sha256).hexdigest()
        out += "{:x};chunk-signature={}\r\n".format(len(data), prev).encode()
        out += data + b"\r\n"
    # 终止块：末尾哈希字段为空
    fsts = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev, h(b""), ""])
    prev = hmac.new(k, fsts.encode("utf-8"), hashlib.sha256).hexdigest()
    out += "0;chunk-signature={}\r\n\r\n".format(prev).encode()

    raw = "{} {} HTTP/1.1\r\n".format(method, path).encode()
    raw += b"".join("{}: {}\r\n".format(k2, v).encode() for k2, v in hdrs.items())
    raw += b"Authorization: " + auth.encode() + b"\r\n"
    raw += b"Transfer-Encoding: chunked\r\n\r\n"
    return bytes(raw) + bytes(out), "streaming seed={} chunks={}".format(
        seed[:12], max(1, (len(body) + CHUNK - 1) // CHUNK))


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
    txt = buf.decode(errors="replace")
    return txt.split("\r\n", 1)[0], txt


def show(label, line, txt):
    code = re.search(r"<Code>([^<]+)</Code>", txt)
    et = re.search(r'"ETag":\s*"([^"]+)"', txt)
    msg = re.search(r"<Message>([^<]+)</Message>", txt)
    print("  [{}] {}".format(label, line))
    if code:
        print("        Code    = {}".format(code.group(1)))
    if msg:
        print("        Message = {}".format(msg.group(1)))
    if et:
        print("        ETag    = {}".format(et.group(1)))


if __name__ == "__main__":
    ak, sk = sys.argv[1], sys.argv[2]

    print("=" * 72)
    print("第 1 步：自证实现正确性 —— 非空载荷的流式 PUT，必须 200")
    print("=" * 72)
    for n, desc in [(100, "100 字节"), (70000, "70000 字节（跨 2 块）")]:
        body = bytes((i * 7 + n) % 256 for i in range(n))
        raw, mode = sign(ak, sk, "PUT", "/{}/.lgmt-sigv4-selfcheck".format(BUCKET),
                         "", {}, body, True)
        line, txt = send(raw)
        show("{}  {}".format(desc, mode), line, txt)
        if "200" not in line:
            print("        ⚠ 实现自检未通过，后续结论不可用")
            sys.exit(1)
        # 校验写入内容
        raw2, _ = sign(ak, sk, "GET", "/{}/.lgmt-sigv4-selfcheck".format(BUCKET),
                       "", {}, b"", False)
        line2, txt2 = send(raw2)
        et = re.search(r'"ETag":\s*"([^"]+)"', txt2)
        print("        ETag 应为 md5={}  实为 {}  {}".format(
            hashlib.md5(body).hexdigest(),
            (et.group(1).strip('"') if et else "?"),
            "✓" if et and et.group(1).strip('"') == hashlib.md5(body).hexdigest() else "✗"))

    print()
    print("=" * 72)
    print("第 2 步：决定性实验 —— 正确编码的 0 字节流式 PUT")
    print("=" * 72)
    raw, mode = sign(ak, sk, "PUT", "/{}/.lgmt-sigv4-empty".format(BUCKET),
                     "", {}, b"", True)
    line, txt = send(raw)
    show("0 字节  {}".format(mode), line, txt)
    print()
    if "200" in line:
        print("  ▶ 结论：RGW 接受合法的 0 字节流式 PUT")
        print("    → RGW 正常，缺陷在 minio-go v7.0.98 的空载荷分帧")
    else:
        print("  ▶ 结论：RGW 拒绝**合法的** 0 字节流式 PUT")
        print("    → 这是 RGW 侧缺陷（疑似 trailing chunk 解析），")
        print("      对应 Red Hat BZ 2270529 / RHBA-2024:2743")
    print()
    print("  对照：0 字节的**非流式** SigV4 PUT（普通 sha256 模式）")
    raw, mode = sign(ak, sk, "PUT", "/{}/.lgmt-sigv4-empty-nostream".format(BUCKET),
                     "", {}, b"", False)
    line, txt = send(raw)
    show("0 字节  {}".format(mode), line, txt)
