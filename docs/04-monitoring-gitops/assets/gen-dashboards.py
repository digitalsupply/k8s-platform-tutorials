#!/usr/bin/env python3
"""生成 8 个组件监控看板 JSON（Grafana v9 schema，datasource uid=prometheus）"""
import json, os

DS = {"type": "prometheus", "uid": "prometheus"}
OUT = "/root/grafana-dashboards-20260930"
os.makedirs(OUT, exist_ok=True)

def ts(title, expr, legend, unit="", pos=(0,0,12,8), extra=None):
    p = {
        "id": None, "type": "timeseries", "title": title,
        "gridPos": {"h": pos[1], "w": pos[0], "x": pos[2], "y": pos[3]},
        "datasource": DS,
        "fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10, "stacking": {"mode": "none"}, "showPoints": "never"}, "unit": unit}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True}, "tooltip": {"mode": "multi"}},
        "targets": [{"expr": expr, "legendFormat": legend, "refId": "A", "datasource": DS}],
    }
    if extra: p.update(extra)
    return p

def stat(title, expr, legend, unit="", color="green", pos=(0,0,4,6), thresholds=(1, 2)):
    return {
        "id": None, "type": "stat", "title": title,
        "gridPos": {"h": pos[1], "w": pos[0], "x": pos[2], "y": pos[3]},
        "datasource": DS,
        "fieldConfig": {"defaults": {"unit": unit,
            "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}, {"color": "green", "value": thresholds[0]}, {"color": "red", "value": thresholds[1]}]},
            "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "colorMode": "value", "graphMode": "area", "textMode": "value"},
        "targets": [{"expr": expr, "legendFormat": legend, "refId": "A", "datasource": DS}],
    }

def gauge(title, expr, legend, unit="percent", pos=(0,0,4,6), maxv=100):
    return {
        "id": None, "type": "gauge", "title": title,
        "gridPos": {"h": pos[1], "w": pos[0], "x": pos[2], "y": pos[3]},
        "datasource": DS,
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": maxv,
            "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}},
            "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "showThresholdLabels": False, "showThresholdMarkers": True},
        "targets": [{"expr": expr, "legendFormat": legend, "refId": "A", "datasource": DS}],
    }

def table(title, expr, pos=(0,0,12,8)):
    return {
        "id": None, "type": "table", "title": title,
        "gridPos": {"h": pos[1], "w": pos[0], "x": pos[2], "y": pos[3]},
        "datasource": DS,
        "fieldConfig": {"defaults": {"custom": {"filterable": True}}, "overrides": []},
        "options": {"showHeader": True},
        "targets": [{"expr": expr, "legendFormat": "__auto", "format": "table", "instant": True, "refId": "A", "datasource": DS}],
    }

def dash(title, uid, panels, tags=None):
    for i, p in enumerate(panels): p["id"] = i + 1
    return {
        "annotations": {"list": []},
        "editable": True, "graphTooltip": 1,
        "title": title, "uid": uid,
        "panels": panels,
        "refresh": "30s",
        "schemaVersion": 39, "version": 0,
        "tags": tags or ["apps"],
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {}, "timezone": "utc",
        "templating": {"list": []},
        "__inputs": [], "__requires": [],
    }

dashboards = {}

# ── 1. cert-manager ────────────────────────────────────────────────
cert_panels = [
    stat("证书总数", 'count(certmanager_certificate_expiration_timestamp_seconds)', 'certs', pos=(0,0,3,5)),
    stat("Ready 证书", 'count(certmanager_certificate_ready_status{condition="True"} == 1)', 'ready', pos=(0,0,3,5)),
    stat("非 Ready 证书", 'count(certmanager_certificate_ready_status{condition="False"})', 'notready', color="red", pos=(0,0,3,5)),
    stat("组件 up", 'count(up{job=~"cert-manager.*"})', '', pos=(0,0,3,5)),
    ts("证书到期倒计时(天)", '(certmanager_certificate_expiration_timestamp_seconds - time()) / 86400', '{{name}}', unit="d", pos=(12,6,0,5)),
    ts("controller 同步速率", 'sum by (pod) (rate(certmanager_controller_sync_call_count[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,11)),
    ts("reconcile 错误速率", 'sum by (pod) (rate(controller_runtime_reconcile_errors_total{job="cert-manager-cainjector"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,17)),
    ts("reconcile 并发 worker", 'sum by (pod) (controller_runtime_active_workers{job="cert-manager-cainjector"})', '{{pod}}', pos=(12,6,0,23)),
]
dashboards["cert-manager"] = dash("Cert-Manager 总览", "cm-cert-manager-overview", cert_panels, ["cert-manager"])

# ── 2. Tekton ──────────────────────────────────────────────────────
tek_panels = [
    stat("运行中 PipelineRun", 'sum(tekton_pipelines_controller_running_pipelineruns)', '', pos=(0,0,3,5)),
    stat("运行中 TaskRun", 'sum(tekton_pipelines_controller_running_taskruns)', '', pos=(0,0,3,5)),
    stat("Events 接收(累计)", 'sum(eventlistener_event_received_count)', '', pos=(0,0,3,5)),
    stat("controller up", 'count(up{job=~"tekton.*|cicd/tekton.*"})', '', pos=(0,0,3,5)),
    ts("TaskRun 完成速率", 'sum(rate(tekton_pipelines_controller_taskrun_total[5m]))', 'taskruns', unit="ops", pos=(12,6,0,5)),
    ts("Pipeline controller reconcile 速率", 'sum by (pod) (rate(tekton_pipelines_controller_reconcile_count[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,11)),
    ts("workqueue 深度", 'sum by (pod) (tekton_pipelines_controller_workqueue_depth)', '{{pod}}', pos=(12,6,0,17)),
    ts("workqueue retries 速率", 'sum by (pod) (rate(tekton_pipelines_controller_workqueue_retries_total[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,23)),
    ts("webhook 请求速率", 'sum by (pod) (rate(tekton_pipelines_webhook_request_count[5m]))', '{{pod}}', unit="rps", pos=(12,6,0,29)),
    ts("EventListener HTTP 延迟 p95", 'histogram_quantile(0.95, sum by (le) (rate(eventlistener_http_duration_seconds_bucket[5m])))', '{{pod}}', unit="s", pos=(12,6,0,35)),
]
dashboards["tekton"] = dash("Tekton CI/CD 总览", "cm-tekton-overview", tek_panels, ["tekton"])

# ── 3. Traefik ─────────────────────────────────────────────────────
trf_panels = [
    gauge("Reload 成功", 'traefik_config_last_reload_success', 'reload', unit="bool", maxv=1, pos=(0,0,3,5)),
    stat("入口请求速率", 'sum(rate(traefik_entrypoint_requests_total[5m]))', '', unit="rps", pos=(0,0,3,5)),
    stat("打开连接数", 'sum(traefik_open_connections)', '', pos=(0,0,3,5)),
    stat("5xx 比例", 'sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) / clamp_min(sum(rate(traefik_service_requests_total[5m])), 0.0001)', '', unit="percentunit", pos=(0,0,3,5)),
    ts("入口请求速率 by entrypoint", 'sum by (entrypoint) (rate(traefik_entrypoint_requests_total[5m]))', '{{entrypoint}}', unit="rps", pos=(12,6,0,5)),
    ts("请求速率 by service/code", 'sum by (service, code) (rate(traefik_service_requests_total[5m]))', '{{service}} {{code}}', unit="rps", pos=(12,6,0,11)),
    ts("5xx 错误速率 by service", 'sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[5m]))', '{{service}}', unit="rps", pos=(12,6,0,17)),
    ts("TLS 证书到期倒计时(天)", '(min by (domain) (traefik_tls_certs_not_after) - time()) / 86400', '{{domain}}', unit="d", pos=(12,6,0,23)),
    ts("配置 reload 次数", 'sum by (pod) (rate(traefik_config_reloads_total[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,29)),
]
dashboards["traefik"] = dash("Traefik 入口流量", "cm-traefik-overview", trf_panels, ["traefik"])

# ── 4. Strimzi Kafka ───────────────────────────────────────────────
str_panels = [
    stat("管理资源数", 'count(strimzi_resources)', '', pos=(0,0,3,5)),
    stat("reconcile 速率", 'sum(rate(strimzi_reconciliations_total[5m]))', '', unit="ops", pos=(0,0,3,5)),
    stat("reconcile 失败(累计)", 'sum(strimzi_reconciliations_failed_total)', '', pos=(0,0,3,5)),
    stat("operator up", 'up{job="kafka/strimzi-cluster-operator"}', '', pos=(0,0,3,5)),
    table("资源状态", 'strimzi_resource_state', pos=(12,8,0,5)),
    ts("reconcile 速率 by kind", 'sum by (kind) (rate(strimzi_reconciliations_total[5m]))', '{{kind}}', unit="ops", pos=(12,6,0,13)),
    ts("reconcile 失败 by kind", 'sum by (kind) (rate(strimzi_reconciliations_failed_total[5m]))', '{{kind}}', unit="ops", pos=(12,6,0,19)),
    ts("证书到期(天)", '(strimzi_certificate_expiration_timestamp_ms / 1000 - time()) / 86400', '{{kind}} {{type}}', unit="d", pos=(12,6,0,25)),
    ts("JVM 堆内存", 'sum by (pod) (jvm_memory_usage_after_gc{area="heap"})', '{{pod}}', unit="bytes", pos=(12,6,0,31)),
    ts("JVM GC 开销", 'sum by (pod) (jvm_gc_overhead)', '{{pod}}', unit="percentunit", pos=(12,6,0,37)),
]
dashboards["strimzi"] = dash("Strimzi Kafka 总览", "cm-strimzi-kafka-overview", str_panels, ["kafka"])

# ── 5. ArgoCD ──────────────────────────────────────────────────────
argo_panels = [
    stat("cluster 连接", 'count(argocd_cluster_connection_status == 1)', '', pos=(0,0,3,5)),
    stat("git 请求速率", 'sum(rate(argocd_git_request_total[5m]))', '', unit="rps", pos=(0,0,3,5)),
    stat("redis 请求速率", 'sum(rate(argocd_redis_request_total[5m]))', '', unit="rps", pos=(0,0,3,5)),
    stat("cluster 缓存过期数", 'count(argocd_cluster_cache_age_seconds > 300)', '', pos=(0,0,3,5)),
    ts("cluster 缓存年龄", 'argocd_cluster_cache_age_seconds', '{{server}}', unit="s", pos=(12,6,0,5)),
    ts("git lsremote 失败累计", 'sum by (pod) (argocd_git_lsremote_fail_total)', '{{pod}}', pos=(12,6,0,11)),
    ts("kubectl 请求速率", 'sum by (pod) (rate(argocd_kubectl_requests_total[5m]))', '{{pod}}', unit="rps", pos=(12,6,0,17)),
    ts("controller reconcile 速率", 'sum by (pod) (rate(controller_runtime_reconcile_total{job="argocd/argocd"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,23)),
    ts("controller reconcile 错误", 'sum by (pod) (rate(controller_runtime_reconcile_errors_total{job="argocd/argocd"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,29)),
]
dashboards["argocd"] = dash("ArgoCD GitOps 总览", "cm-argocd-overview", argo_panels, ["argocd"])

# ── 6. CNPG ────────────────────────────────────────────────────────
cnpg_panels = [
    stat("controller up", 'up{job="cnpg-system/cnpg-controller-manager"}', '', pos=(0,0,3,5)),
    stat("leader 状态", 'leader_election_master_status{job="cnpg-system/cnpg-controller-manager"}', '', pos=(0,0,3,5)),
    stat("active workers", 'sum(controller_runtime_active_workers{job="cnpg-system/cnpg-controller-manager"})', '', pos=(0,0,3,5)),
    stat("webhook 请求速率", 'sum by (job) (rate(controller_runtime_webhook_requests_total{job="cnpg-system/cnpg-controller-manager"}[5m]))', '', unit="rps", pos=(0,0,3,5)),
    ts("reconcile 速率", 'sum by (pod) (rate(controller_runtime_reconcile_total{job="cnpg-system/cnpg-controller-manager"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,5)),
    ts("reconcile 错误速率", 'sum by (pod) (rate(controller_runtime_reconcile_errors_total{job="cnpg-system/cnpg-controller-manager"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,11)),
    ts("webhook 请求速率 by pod", 'sum by (pod) (rate(controller_runtime_webhook_requests_total{job="cnpg-system/cnpg-controller-manager"}[5m]))', '{{pod}}', unit="rps", pos=(12,6,0,17)),
    ts("APIServer 请求速率", 'sum by (job) (rate(rest_client_requests_total{job="cnpg-system/cnpg-controller-manager"}[5m]))', '{{job}}', unit="rps", pos=(12,6,0,23)),
]
dashboards["cnpg"] = dash("CloudNativePG 总览", "cm-cnpg-overview", cnpg_panels, ["cnpg"])

# ── 7. Knative Eventing ────────────────────────────────────────────
kne_panels = [
    stat("controlplane up", 'up{job="knative-eventing/knative-eventing-controlplane"}', '', pos=(0,0,3,5)),
    stat("ingress up", 'up{job="kafka-broker-ingress"}', '', pos=(0,0,3,5)),
    stat("workqueue 深度", 'sum(controller_workqueue_depth{job="knative-eventing/knative-eventing-controlplane"})', '', pos=(0,0,3,5)),
    stat("事件分发延迟 max", 'max(event_dispatch_latencies_ms_max)', '', unit="ms", pos=(0,0,3,5)),
    ts("reconcile 速率", 'sum by (pod) (rate(controller_reconcile_count{job="knative-eventing/knative-eventing-controlplane"}[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,5)),
    ts("workqueue 深度趋势", 'sum by (pod) (controller_workqueue_depth{job="knative-eventing/knative-eventing-controlplane"})', '{{pod}}', pos=(12,6,0,11)),
    ts("kafka producer 字节速率(in)", 'sum by (pod) (rate(kafka_producer_incoming_byte_total[5m]))', '{{pod}}', unit="Bps", pos=(12,6,0,17)),
    ts("kafka producer 错误", 'sum by (pod) (rate(kafka_producer_failed_authentication_total[5m]))', '{{pod}}', unit="ops", pos=(12,6,0,23)),
    ts("事件分发延迟(ms)", 'event_dispatch_latencies_ms_max', '{{pod}}', unit="ms", pos=(12,6,0,29)),
]
dashboards["knative-eventing"] = dash("Knative Eventing 总览", "cm-knative-eventing-overview", kne_panels, ["knative"])

# ── 8. MetalLB + Ceph CSI ──────────────────────────────────────────
net_panels = [
    stat("MetalLB controller up", 'up{job="metallb-system/metallb-controller"}', '', pos=(0,0,3,5)),
    stat("CSI provisioner up", 'up{job="ceph-csi-rbd-provisioner-http-metrics"}', '', pos=(0,0,3,5)),
    stat("CSI nodeplugin up", 'up{job="ceph-csi-rbd-nodeplugin-http-metrics"}', '', pos=(0,0,3,5)),
    stat("CSI liveness", 'min(csi_liveness)', '', pos=(0,0,3,5)),
    gauge("地址池利用率", 'max by (pool) (metallb_allocator_addresses_in_use_total / clamp_min(metallb_allocator_addresses_total, 1) * 100)', '{{pool}}', pos=(12,6,0,5)),
    ts("地址池已用地址", 'metallb_allocator_addresses_in_use_total', '{{pool}}', pos=(12,6,0,11)),
    ts("地址池总地址", 'metallb_allocator_addresses_total', '{{pool}}', pos=(12,6,0,17)),
    ts("k8s client 更新错误累计", 'sum by (pod) (metallb_k8s_client_update_errors_total)', '{{pod}}', pos=(12,6,0,23)),
    ts("k8s client 更新速率", 'sum by (pod) (rate(metallb_k8s_client_updates_total[5m]))', '{{pod}}', pos=(12,6,0,29)),
]
dashboards["metallb-cephcsi"] = dash("MetalLB & Ceph CSI", "cm-metallb-cephcsi", net_panels, ["metallb", "ceph"])

# 写文件
for name, d in dashboards.items():
    path = os.path.join(OUT, f"{name}.json")
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  ✓ {name}.json  ({len(d['panels'])} panels)")
print(f"\n输出目录: {OUT}")