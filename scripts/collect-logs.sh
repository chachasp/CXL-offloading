#!/usr/bin/env bash
set -uo pipefail
namespace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="${2:?}"; shift 2 ;;
    -h|--help) echo "Usage: sudo $0 [--namespace NS]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$repo_root/logs/cxl-kvbm-$stamp"
mkdir -p "$out"

uname -a >"$out/uname.txt" 2>&1
numactl --hardware >"$out/numactl.txt" 2>&1 || true
nvidia-smi -q >"$out/nvidia-smi-q.txt" 2>&1 || true
nvidia-smi topo -m >"$out/nvidia-topo.txt" 2>&1 || true
cxl list -vvv >"$out/cxl-list.json" 2>&1 || true
daxctl list -R -D -M -u >"$out/daxctl-list.json" 2>&1 || true
for dir in /sys/devices/system/node/node[0-9]*; do
  [[ -d "$dir" ]] || continue
  node="${dir##*node}"
  cp "$dir/cpulist" "$out/node${node}-cpulist.txt" 2>/dev/null || true
  cp "$dir/meminfo" "$out/node${node}-meminfo.txt" 2>/dev/null || true
done
dmesg --level=err,warn >"$out/dmesg-warn-error.txt" 2>&1 || true

if [[ -n "$namespace" ]] && command -v kubectl >/dev/null 2>&1; then
  kubectl get pods -n "$namespace" -o wide >"$out/k8s-pods.txt" 2>&1 || true
  kubectl get events -n "$namespace" --sort-by=.lastTimestamp >"$out/k8s-events.txt" 2>&1 || true
  while read -r pod; do
    [[ -n "$pod" ]] || continue
    safe_pod="${pod//[^a-zA-Z0-9_.-]/_}"
    kubectl logs -n "$namespace" "$pod" --all-containers --tail=5000 >"$out/pod-$safe_pod.log" 2>&1 || true
    kubectl describe pod -n "$namespace" "$pod" >"$out/pod-$safe_pod-describe.txt" 2>&1 || true
  done < <(kubectl get pod -n "$namespace" -l nvidia.com/dynamo-graph-deployment-name=agg-kvbm-qwen3-cxl -o name 2>/dev/null | sed 's|pod/||')
fi

archive="$out.tar.gz"
tar -C "$(dirname "$out")" -czf "$archive" "$(basename "$out")"
echo "수집 완료: $archive"
echo 'Secret, kubeconfig, token은 수집하지 않았습니다. 외부 반출 전 hostname/BDF/Pod 이름은 직접 검토하십시오.'
