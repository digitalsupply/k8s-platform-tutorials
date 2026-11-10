# 31 · CI webhook 中断与恢复(2026-10-30)

## 现象

- 10-27 13:24 之后所有 push 都没有产生 PipelineRun,但 GitLab 页面只显示
  webhook「失败」,没有任何告警;
- 10-30 复现:`POST /projects/.../hooks/1/events` 显示 `internal error`、`duration` 为空
   → 请求根本没到达集群(主机名解析失败),不是超时或 5xx。

## 原因

GitLab 主机 `/etc/hosts` 里 `10.0.0.252 ci-compassio.xyz` 的绑定失效了
(该直连路径早期经 Tailscale 建立)。端口与 Traefik 都正常 —— 用
`curl -H "Host: ci-compassio.xyz" http://10.0.0.252/` 仍能打到 EL。

## 处理

1. 给 EL 的 Ingress 增加一条**已能解析**的主机名下的路径规则:

```yaml
- host: el-deeptutor.internal          # GitLab 主机一直能解析这个名字
  http:
    paths:
      - path: /compassio-el            # Tekton EL sink 不校验路径
        pathType: Prefix
        backend: {service: {name: el-compassio-listener, port: {number: 8080}}}
```

2. 把 webhook URL 改为 `http://el-deeptutor.internal/compassio-el`:

```bash
curl -X PUT --header "PRIVATE-TOKEN: $PAT" \
  "http://192.168.67.201/api/v4/projects/digitalsupply%2Fcompassio/hooks/1" \
  --data-urlencode "url=http://el-deeptutor.internal/compassio-el" --data "push_events=true"
```

3. 验证:push 一个只改 `docs/` 的提交 → 应产生 PipelineRun,且
   `check-changes` 为 `false`、build/promote 两个任务被跳过。

## 遗留

- 这条路径规则依赖 deeptutor 的 EL 主机名,deeptutor 改名/下线时要一起改。
- 真正的修法是在 GitLab 主机恢复 `/etc/hosts` 里的 `ci-compassio.xyz`,
  之后把 webhook URL 改回 `http://ci-compassio.xyz/`(Ingress 规则仍保留)。
- **建议加一条告警**:compassio 主分支超过 N 小时没有 PipelineRun,或 webhook
  投递连续失败 → 通知,避免再次「静默停摆三天」。

## 复盘时踩到的第二个坑

用 API 改 webhook URL 时必须**同时带上 `token`**:

```bash
curl -X PUT --header "PRIVATE-TOKEN: $PAT" .../hooks/1 \
  --data-urlencode "url=http://el-deeptutor.internal/compassio-el" \
  --data "push_events=true" \
  --data-urlencode "token=$WEBHOOK_TOKEN"      # ← 漏掉这行会把 token 清空
```

GitLab 的 PUT 是整体替换:不传 `token` 就会把它置空。之后每次投递都**少了
`X-Gitlab-Token` 头**,Tekton 的 gitlab interceptor 判定失败后返回 **202**,
GitLab 侧显示"成功"、EL 侧不打日志、集群里也没有 PipelineRun —— 比原来更难排查。
抓包(`tcpdump -A port 80 and host 10.0.0.252`)才看到请求头里没有该字段。

> 经验:webhook 排查顺序 = 能否解析 → 是否有 token 头 → interceptor 是否放行
> (放行与否都返回 202,只能看 EL 日志里有没有 `ResolvedParams`)。
