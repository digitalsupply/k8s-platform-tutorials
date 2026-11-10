#!/usr/bin/env python3
"""
判别 RGW 17.2.8 对「最后一块(零长)」的 string_to_sign 究竟用哪条规则。

背景（已由源码定位）：
  rgw_op.cc:1390 是 XAmzContentSHA256Mismatch 的唯一抛出点
     if (s->auth.completer) { if (!s->auth.completer->complete()) return -ERR_...; }
  complete() -> is_signature_mismatched() -> calc_chunk_signature(payload_hash)
  calc_chunk_signature() (rgw_auth_s3.cc:1101) 把 payload_hash 作为最后一个字段拼进去。

AWS 规范：最后一块（零长）的最后一个字段必须**留空**。
疑点：RGW 把 sha256("") 填了进去。

本脚本枚举几种「最后一块」的签名算法，各自签名后打 RGW，看哪个返回 200。
再对非空载荷重复一遍，确认规则是否一致。
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
EMPTY = hashlib.sha256(b"").hexdigest()


def h(x):
    if isinstance(x, str):
        x = x.encode()
    return hashlib.sha256(x).hexdigest()


def build(ak, sk, key, payload, final_rule, wrap=True):
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
    signed = ["host", "x-amz-content-sha256", "x-amz-date",
              "x-amz-decoded-content-length"]
    m = {"host": "Host", "x-amz-content-sha256": "X-Amz-Content-Sha256",
         "x-amz-date": "X-Amz-Date",
         "x-amz-decoded-content-length": "X-Amz-Decoded-Content-Length"}
    canon = "".join("{}:{}\n".format(k, hdrs[m[k]]) for k in signed)
    creq = "\n".join(["PUT", path, "", canon, ";".join(signed),
                      "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"])
    scope = "{}/{}/{}/aws4_request".format(datestamp, REGION, SERVICE)
    sts = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, h(creq)])
    k = hmac.new(("AWS4" + sk).encode(), datestamp.encode(), hashlib.sha256).digest()
    for p in (REGION, SERVICE, "aws4_request"):
        k = hmac.new(k, p.encode(), hashlib.sha256).digest()
    seed = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()

    def mac(s):
        return hmac.new(k, s.encode(), hashlib.sha256).hexdigest()

    out = bytearray()
    prev = seed
    for off in range(0, len(payload), 65536):
        d = payload[off:off + 65536]
        prev = mac("\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope,
                              prev, EMPTY, h(d)]))
        out += "{:x};chunk-signature={}\r\n".format(len(d), prev).encode() + d + b"\r\n"

    # ── 最后一块：按不同规则算签名 ──
    pre = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev, EMPTY])
    if final_rule == "A":          # AWS 规范 / minio-go：末字段留空
        sts_final = pre + "\n"
    elif final_rule == "B":        # RGW 疑似：末字段再填一次 sha256("")
        sts_final = pre + "\n" + EMPTY
    elif final_rule == "C":        # 末字段不填，且连 sha256("") 那行都不要
        sts_final = "\n".join(["AWS4-HMAC-SHA256-PAYLOAD", amzdate, scope, prev])
    else:
        raise ValueError(final_rule)
    prev = mac(sts_final)
    out += "0;chunk-signature={}\r\n\r\n".format(prev).encode()

    body = bytearray()
    if wrap:
        for off in range(0, len(out), 0xFFFF) or [0]:
            seg = out[off:off + 0xFFFF]
            if seg:
                body += "{:x}\r\n".format(len(seg)).encode() + seg + b"\r\n"
        body += b"0\r\n\r\n"
        te = "Transfer-Encoding: chunked"
    else:
        body = bytes(out)
        te = "Content-Length: {}".format(len(body))

    raw = "PUT {} HTTP/1.1\r\n".format(path).encode()
    for k2, v in hdrs.items():
        raw += "{}: {}\r\n".format(k2, v).encode()
    raw += ("Authorization: AWS4-HMAC-SHA256 Credential={}/{}, "
            "SignedHeaders={}, Signature={}\r\n".format(
                ak, scope, ";".join(signed), seed)).encode()
    return raw + te.encode() + b"\r\n\r\n" + bytes(body), sts_final


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


def code_of(txt):
    m = re.search(r"<Code>([^<]+)</Code>", txt)
    return m.group(1) if m else "-"


if __name__ == "__main__":
    ak, sk = sys.argv[1], sys.argv[2]
    RULES = [("A", "末字段留空（AWS规范/minio-go）"),
             ("B", "末字段填 sha256(\"\")（RGW 疑似做法）"),
             ("C", "只到 sha256(\"\") 为止，不带尾分隔符")]

    for size in (0, 100):
        data = bytes((i * 7 + size) % 256 for i in range(size))
        print("=" * 76)
        print("载荷 {} 字节".format(size))
        print("=" * 76)
        for rule, desc in RULES:
            key = ".lgmt-matrix-{}b-{}".format(size, rule)
            raw, sts_final = build(ak, sk, key, data, rule)
            line, txt = send(raw)
            ok = "200" in line
            print("  规则{} {:34s} -> {:22s} {}".format(
                rule, desc, line.split(" ", 1)[1] if " " in line else line,
                "✓ 接受" if ok else "✗ " + code_of(txt)))
            print("        RGW 侧 string_to_sign 末段 = {!r}".format(sts_final[-30:]))
        print()
