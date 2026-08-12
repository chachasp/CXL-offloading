#!/usr/bin/env bash
set -uo pipefail

requested_node=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) requested_node="${2:?--node requires a value}"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--node NUMA_NODE]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

failures=0
warnings=0
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo '=== OS / kernel ==='
uname -a
[[ -r /etc/os-release ]] && sed -n 's/^\(NAME\|VERSION\)=/\1=/p' /etc/os-release

echo '=== NUMA nodes ==='
memory_only_nodes=()
shopt -s nullglob
for dir in /sys/devices/system/node/node[0-9]*; do
  node="${dir##*node}"
  cpus="$(tr -d '[:space:]' <"$dir/cpulist" 2>/dev/null || true)"
  mem_kb="$(awk '/MemTotal/ {print $4; exit}' "$dir/meminfo" 2>/dev/null || true)"
  printf 'node=%s cpulist=%s mem_total_kb=%s\n' "$node" "${cpus:-<empty>}" "${mem_kb:-unknown}"
  [[ -z "$cpus" && "${mem_kb:-0}" -gt 0 ]] && memory_only_nodes+=("$node")
done
shopt -u nullglob
if [[ ${#memory_only_nodes[@]} -eq 0 ]]; then
  fail 'memory-only NUMA node를 찾지 못했습니다. CXL이 아직 Device-DAX일 수 있습니다.'
else
  pass "memory-only NUMA node 후보: ${memory_only_nodes[*]}"
fi

if [[ -n "$requested_node" ]]; then
  node_dir="/sys/devices/system/node/node${requested_node}"
  if [[ ! -d "$node_dir" ]]; then
    fail "지정 node${requested_node}가 없습니다."
  elif [[ -n "$(tr -d '[:space:]' <"$node_dir/cpulist")" ]]; then
    fail "node${requested_node}는 CPU를 보유하므로 strict CXL-only 대상으로 거부됩니다."
  else
    pass "node${requested_node}는 memory-only node입니다."
  fi
fi

echo '=== CXL / DAX read-only inventory ==='
if have cxl; then sudo -n cxl list -vvv 2>/dev/null || cxl list -vvv || warn 'cxl list 실행 실패'; else warn 'cxl CLI 없음'; fi
if have daxctl; then sudo -n daxctl list -R -D -M -u 2>/dev/null || daxctl list -R -D -M -u || warn 'daxctl list 실행 실패'; else warn 'daxctl CLI 없음'; fi
ls -l /dev/dax* 2>/dev/null || true

echo '=== GPU / topology ==='
if have nvidia-smi; then
  nvidia-smi -L || fail 'nvidia-smi -L 실패'
  nvidia-smi topo -m || warn 'nvidia-smi topo -m 실패'
else
  fail 'nvidia-smi 없음'
fi
have numactl && numactl --hardware || warn 'numactl 없음'
have lspci && lspci -Dtv || warn 'lspci 없음'

echo '=== Pinning / cgroup ==='
printf 'ulimit -l: '; ulimit -l
[[ -r /proc/self/status ]] && grep -E 'Cpus_allowed_list|Mems_allowed_list' /proc/self/status || true
for f in /sys/fs/cgroup/cpuset.mems.effective /sys/fs/cgroup/memory.max; do
  [[ -r "$f" ]] && printf '%s: %s\n' "$f" "$(cat "$f")"
done

echo '=== Kubernetes / build tools ==='
for cmd in kubectl docker git python3; do
  have "$cmd" && pass "$cmd 발견: $(command -v "$cmd")" || warn "$cmd 없음"
done
have kubectl && kubectl version --client 2>/dev/null || true
have docker && docker version --format 'Docker client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || true

echo '=== Summary ==='
printf 'failures=%d warnings=%d\n' "$failures" "$warnings"
if [[ $failures -ne 0 ]]; then
  echo 'RESULT: FAIL'
  exit 1
fi
echo 'RESULT: PASS (CUDA registration은 cxl_cuda_probe.py로 별도 확인 필요)'
