#!/usr/bin/env bash
set -euo pipefail
namespace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="${2:?}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --namespace NAMESPACE"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$namespace" ]] || { echo '--namespace is required' >&2; exit 2; }
echo "삭제 대상: namespace=$namespace DGD=agg-kvbm-qwen3-cxl"
read -r -p '이 DGD만 삭제하시겠습니까? [y/N] ' answer
[[ "$answer" == y || "$answer" == Y ]] || { echo '취소했습니다.'; exit 0; }
kubectl delete dynamographdeployment agg-kvbm-qwen3-cxl -n "$namespace" --ignore-not-found
echo 'CXL mode와 namespace는 변경하지 않았습니다.'
