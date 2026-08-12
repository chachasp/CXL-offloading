#!/usr/bin/env bash
set -euo pipefail
namespace=""; node=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="${2:?}"; shift 2 ;;
    --node) node="${2:?}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --namespace NS --node N"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$namespace" && -n "$node" ]] || { echo '--namespace와 --node는 필수입니다.' >&2; exit 2; }

selector='nvidia.com/dynamo-graph-deployment-name=agg-kvbm-qwen3-cxl,nvidia.com/dynamo-component-type=worker'
pod="$(kubectl get pod -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$pod" ]] || { echo 'Worker Pod을 찾지 못했습니다.' >&2; exit 1; }
echo "worker_pod=$pod"

kubectl get pod -n "$namespace" "$pod" -o wide
logs="$(kubectl logs -n "$namespace" "$pod" --all-containers --tail=2000)"
printf '%s\n' "$logs" | grep -F 'allocated and CUDA-registered strict CXL NUMA G2 storage' >/dev/null || {
  echo 'CXL allocator 성공 로그가 없습니다.' >&2; exit 1;
}
printf '%s\n' "$logs" | grep -E "cxl_numa_node(=|: ?)$node|cxl_numa_node=$node" >/dev/null || {
  echo "allocator 로그에서 node=$node를 확인하지 못했습니다." >&2; exit 1;
}
if printf '%s\n' "$logs" | grep -Eiq 'strict CXL placement failed|CUDA could not register|out of memory|CUDA error|worker.*crash'; then
  echo '실패 패턴이 worker 로그에 있습니다.' >&2
  exit 1
fi

service='agg-kvbm-qwen3-cxl-frontend'
echo "별도 터미널에서 실행: kubectl port-forward -n $namespace svc/$service 8000:8000"
echo '그 다음 README의 sample inference를 실행하십시오.'
echo 'PLACEMENT RESULT: PASS'
