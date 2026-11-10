# 实验 04:网络策略 L7 — 应用层安全

**目标**:深入 HTTP 层,精确控制允许哪些方法和路径,这是 Calico 较难做到的、Cilium 的核心优势。(需要 CiliumNetworkPolicy + envoy 代理)

## 背景知识

L3/L4 策略只能按 IP/端口判断。而 **L7 策略** 能理解应用协议(HTTP、gRPC、DNS):
- 限制 HTTP **方法**(GET/POST…)
- 限制 **路径**(只允许 `/`、`/api/*`…)
- 限制 **主机名**、请求头
- 结合 `toFQDNs` 控制出站域名(而不只是 IP)

实现原理:Cilium 在需要 L7 检查的 endpoint 前注入 **envoy** 代理,流量经 envoy 解析后再转发。

> ⚠️ 注意:默认的 nginx/httpd 镜像返回静态页,为了演示 L7 路径,我们用 nginx 的多路径
> (根路径 `/` 和不存在路径 `/secret` 会有区别),并通过 monitor/envoy 观察。

## 步骤

### 1. L7 HTTP 策略:只允许来自 test 的 GET / 

`04-http-get.yaml`:web 的 ingress 只放行 `role=curl` 的 pod,并且**只允许 HTTP GET `/`**(其它方法/路径拒绝)。

```bash
kubectl apply -f 04-http-get.yaml
```

### 2. 验证 L7 生效

```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')

# GET / -> 200 (放行)
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "GET /:%{http_code}\n" http://web.lab.svc.cluster.local/

# GET /secret -> 403 (路径不在白名单,被 envoy 拒绝)
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "GET /secret:%{http_code}\n" http://web.lab.svc.cluster.local/secret

# POST / -> 403 (方法不被允许)
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "POST /:%{http_code}\n" -X POST http://web.lab.svc.cluster.local/

# 非 curl 身份 -> 403/阻塞 (l3 层就被拦)
WEBPOD=$(kubectl get pod -n lab -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n lab $WEBPOD -- curl -s -o /dev/null -w "web->web:%{http_code}\n" --max-time 6 http://web.lab.svc.cluster.local/ || echo "blocked"
```

在另一终端用 `cilium monitor` 观察 L7 层的 dropped 事件。

### 3. 用 toFQDNs 控制出站域名

`04-egress-fqdn.yaml`:只允许 web 出站到 `cn.bing.com` 或 `example.com` 的 443(DNS 除外)。

```bash
kubectl apply -f 04-egress-fqdn.yaml
```

验证(web pod 内,目标需可解析可达):
```bash
kubectl exec -n lab $(kubectl get pod -n lab -l app=web -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 https://example.com/ || echo "blocked"
```

> ⚠️ 沙箱外网受限,若外部域名不可达,重点观察策略本身如何被规则化
> (可在 monitor 或 `cilium bpf policy` 里确认 toFQDNs 已生成对应 IP 规则)。

### 4. 清理

```bash
kubectl delete -f 04-http-get.yaml -f 04-egress-fqdn.yaml
```

## 验证要点

- [ ] GET / 返回 200
- [ ] GET /secret 返回 403 (路径白名单拦截)
- [ ] POST / 返回 403 (方法拦截)
- [ ] 非 curl 身份被拦截(enforcement 在 L3 即断)
- [ ] monitor 能看到 L7 层 drop

## 思考

1. L7 拦截和 L3/L4 拦截在数据路径上有什么不同?(提示:envoy 参与)
2. toFQDNs 相比"放行某个 IP"的优势?当域名解析 IP 变化时谁更安全?
