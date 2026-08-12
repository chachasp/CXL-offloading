#!/usr/bin/env bash
set -euo pipefail

image=""; node=""; cache_gb="64"; tp="1"; output="rendered/dgd-cxl.yaml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) image="${2:?}"; shift 2 ;;
    --node) node="${2:?}"; shift 2 ;;
    --cache-gb) cache_gb="${2:?}"; shift 2 ;;
    --tp) tp="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --image IMAGE --node N [--cache-gb 64] [--tp 1|2] [--output FILE]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$image" && -n "$node" ]] || { echo '--image와 --node는 필수입니다.' >&2; exit 2; }
[[ "$node" =~ ^[0-9]+$ ]] || { echo '--node는 숫자여야 합니다.' >&2; exit 2; }
[[ "$cache_gb" =~ ^[0-9]+$ && "$cache_gb" -ge 1 ]] || { echo '--cache-gb는 양의 정수여야 합니다.' >&2; exit 2; }
[[ "$tp" == 1 || "$tp" == 2 ]] || { echo '--tp는 1 또는 2여야 합니다.' >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/manifests/dgd-template.yaml"
mkdir -p "$(dirname "$output")"
memory_request=$((cache_gb + 64))
memory_limit=$((cache_gb + 96))

sed \
  -e "s|__IMAGE__|$image|g" \
  -e "s|__CXL_NODE__|$node|g" \
  -e "s|__CACHE_GB__|$cache_gb|g" \
  -e "s|__TP__|$tp|g" \
  -e "s|__GPU__|$tp|g" \
  -e "s|__MEMORY_REQUEST__|${memory_request}Gi|g" \
  -e "s|__MEMORY_LIMIT__|${memory_limit}Gi|g" \
  "$template" >"$output"

if grep -q '__[A-Z_]*__' "$output"; then
  echo "Manifest placeholder가 남았습니다: $output" >&2
  exit 1
fi
echo "생성 완료: $output"
echo "검토 후 실행: kubectl apply -n <namespace> -f $output"
