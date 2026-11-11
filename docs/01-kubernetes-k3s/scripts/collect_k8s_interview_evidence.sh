#!/usr/bin/env bash
# 只读采集 K8s 核心考点证据（在 control-plane 节点执行）。
# 不创建/删除资源；不读取 Secret 内容。

set -uo pipefail
section() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '[exit=%s]\n' "$?"; }
run_sh() { printf '\n$ %s\n' "$*"; bash -c "$*" 2>&1 || printf '[exit=%s]\n' "$?"; }

section "0. 版本/节点"
run_sh 'date -Is; hostname'
run_sh 'kubectl version 2>/dev/null | head -5'
run_sh 'kubeadm version -o short 2>/dev/null'
run_sh 'kubectl get nodes -o wide'

section "1. 控制面静态 Pod 参数"
for p in kube-apiserver-m01 etcd-m01 kube-scheduler-m01 kube-controller-manager-m01; do
  run_sh "kubectl -n kube-system get pod $p -o jsonpath='{.spec.containers[0].command}' 2>/dev/null | tr ',' '\\n' | sed 's/^\\[\"//; s/\"\\]$//'"
done

section "2. apiserver：认证/授权/准入/健康"
run_sh 'kubectl get --raw /readyz?verbose 2>/dev/null | tail -20'
run_sh 'kubectl auth can-i get pods -n default'
run_sh 'kubectl auth can-i create pods -n kube-system'
run_sh 'kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations 2>/dev/null'
run_sh 'kubectl get apiservice 2>/dev/null | head -20'

section "3. etcd：健康/状态/成员/告警/指标"
run_sh 'kubectl -n kube-system exec etcd-m01 -- etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health 2>&1'
run_sh 'kubectl -n kube-system exec etcd-m01 -- etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint status --write-out=table 2>&1'
run_sh 'kubectl -n kube-system exec etcd-m01 -- etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list --write-out=table 2>&1'
run_sh 'kubectl -n kube-system exec etcd-m01 -- etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key alarm list 2>&1'
run_sh 'kubectl get --raw "/api/v1/namespaces/kube-system/pods/etcd-m01:2381/proxy/metrics" 2>/dev/null | grep -E "^etcd_disk_wal_fsync_duration_seconds|^etcd_disk_backend_commit_duration_seconds|^etcd_server_has_leader|^etcd_mvcc_db_total_size" | grep -v "_bucket" | head -20'

section "4. etcd 备份"
run_sh 'kubectl -n etcd-backup get cronjob,pods 2>/dev/null'
run_sh 'kubectl -n etcd-backup logs -l job-name --tail=20 2>/dev/null | tail -30'

section "5. kubelet / CRI / CNI / CSI"
run_sh 'systemctl show kubelet -p ExecStart -p LimitNOFILE 2>/dev/null'
run_sh 'grep -E "cgroupDriver|containerRuntimeEndpoint|clusterDNS|systemReserved|kubeReserved|evictionHard" /var/lib/kubelet/config.yaml 2>/dev/null | head -30'
run_sh 'crictl version 2>/dev/null; crictl info 2>/dev/null | head -30'
run_sh 'ls -l /etc/cni/net.d 2>/dev/null; cat /etc/cni/net.d/*.conflist 2>/dev/null | head -40'
run_sh 'kubectl -n kube-system get ds cilium -o wide 2>/dev/null'
run_sh 'kubectl get csidriver 2>/dev/null; kubectl get sc 2>/dev/null'

section "6. NPD / kured / Velero / KEDA"
run_sh 'kubectl get ds -A 2>/dev/null | grep -Ei "node-problem|npd|kured" || echo "NPD/kured not found"'
run_sh 'kubectl get ns velero keda 2>/dev/null; kubectl get crd 2>/dev/null | grep -Ei "velero|keda" || echo "Velero/KEDA not found"'

section "7. requests/limits/QoS"
run_sh 'kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json,sys,collections
d=json.load(sys.stdin); c=collections.Counter(); no_req=0; no_lim=0
for p in d[\"items\"]:
  c[p.get(\"status\",{}).get(\"qosClass\",\"Unknown\")]+=1
  for x in p[\"spec\"].get(\"containers\",[]):
    r=x.get(\"resources\",{}); 
    if not r.get(\"requests\"): no_req+=1
    if not r.get(\"limits\"): no_lim+=1
print(\"QoS:\",dict(c)); print(\"containers_without_requests:\",no_req); print(\"containers_without_limits:\",no_lim)
"'
run_sh 'kubectl describe node m01 2>/dev/null | sed -n "/Allocated resources/,/Events/p" | head -30'

section "8. LimitRange / ResourceQuota / PDB"
run_sh 'kubectl get limitrange,resourcequota,pdb -A 2>/dev/null'

section "9. 探针/优雅退出/拓扑打散"
run_sh 'kubectl get deploy -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); l=r=s=0; pre=0; grace={}
for x in d[\"items\"]:
  sp=x[\"spec\"]; tpl=sp.get(\"template\",{}).get(\"spec\",{})
  grace[x[\"metadata\"][\"namespace\"]+\"/\"+x[\"metadata\"][\"name\"]]=tpl.get(\"terminationGracePeriodSeconds\",30)
  for c in tpl.get(\"containers\",[]):
    if c.get(\"livenessProbe\"): l+=1
    if c.get(\"readinessProbe\"): r+=1
    if c.get(\"startupProbe\"): s+=1
    if c.get(\"lifecycle\",{}).get(\"preStop\"): pre+=1
print(\"liveness\",l,\"readiness\",r,\"startup\",s,\"preStop\",pre)
print(\"grace samples\",dict(list(grace.items())[:10]))
"'
run_sh 'kubectl get deploy -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); n=0
for x in d[\"items\"]:
  tpl=x[\"spec\"].get(\"template\",{}).get(\"spec\",{})
  if tpl.get(\"topologySpreadConstraints\") or tpl.get(\"affinity\"):
    print(x[\"metadata\"][\"namespace\"]+\"/\"+x[\"metadata\"][\"name\"], \"topology\" if tpl.get(\"topologySpreadConstraints\") else \"affinity\"); n+=1
print(\"with scheduling constraints:\",n)
"'

section "10. 版本偏差/证书"
run_sh 'kubectl get nodes -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d[\"items\"]:
  print(n[\"metadata\"][\"name\"], n[\"status\"][\"nodeInfo\"][\"kubeletVersion\"], n[\"status\"][\"nodeInfo\"][\"containerRuntimeVersion\"])
"'
run_sh 'kubeadm certs check-expiration 2>&1 | head -40'
run_sh 'kubectl get csr 2>/dev/null | head -10'

section "11. 节点条件/污点/自愈"
run_sh 'kubectl get nodes -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d[\"items\"]:
  c=[(x[\"type\"],x[\"status\"]) for x in n[\"status\"][\"conditions\"] if x[\"type\"] in (\"Ready\",\"MemoryPressure\",\"DiskPressure\",\"PIDPressure\")]
  t=n[\"spec\"].get(\"taints\",[])
  print(n[\"metadata\"][\"name\"], c, t)
"'

section "12. CRD / Operator / Webhook"
run_sh 'kubectl get crd 2>/dev/null | wc -l'
run_sh 'kubectl get deploy -A 2>/dev/null | grep -Ei "cnpg|ceph|strimzi|argocd|grafana-operator|sealed" | head -20'
run_sh 'kubectl get validatingwebhookconfigurations -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for x in d[\"items\"]: print(x[\"metadata\"][\"name\"], [(w.get(\"failurePolicy\"), w.get(\"name\")) for w in x.get(\"webhooks\",[])])
"'

section "13. 多租户/PSA/NetworkPolicy/HPA/VPA"
run_sh 'kubectl get ns 2>/dev/null'
run_sh 'kubectl get networkpolicy -A 2>/dev/null | head -20'
run_sh 'kubectl get role,rolebinding -A 2>/dev/null | head -30'
run_sh 'kubectl get ns -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d[\"items\"]:
  l=n[\"metadata\"].get(\"labels\",{})
  p={k:v for k,v in l.items() if \"pod-security\" in k}
  if p: print(n[\"metadata\"][\"name\"],p)
"'
run_sh 'kubectl get hpa,vpa -A 2>/dev/null'

section "14. Gateway API / Cilium"
run_sh 'kubectl get crd 2>/dev/null | grep gateway.networking'
run_sh 'kubectl get gatewayclass,gateway,httproute -A 2>/dev/null | head -20'
run_sh 'cilium status 2>/dev/null | head -30'

section "15. 结束"
run_sh 'date -Is'
