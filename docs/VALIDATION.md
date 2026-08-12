# 검증과 Benchmark 계획

## 단계별 gate

1. `preflight.sh`: CXL memory-only node, topology와 도구 확인
2. `cxl_cuda_probe.py`: 64 MiB 전 page placement와 CUDA 등록 확인
3. custom image import: `kvbm==1.3.1`
4. 64 GiB G2로 worker 시작과 allocator 성공 로그 확인
5. deterministic correctness 비교
6. 30분 stability test
7. 128→256 GiB로 용량 확대
8. no-offload, DRAM G2, CXL G2 benchmark
9. 향후 2 GPU에서 TP=2 전 과정을 별도로 반복

## 비교 행렬

| ID | GPU/TP | 구성 |
|---|---:|---|
| B0 | 1/1 | no offload |
| B1 | 1/1 | upstream KVBM DRAM G2 |
| B2 | 1/1 | patched KVBM CXL G2 |
| T0 | 2/2 | no offload |
| T1 | 2/2 | upstream KVBM DRAM G2 |
| T2 | 2/2 | patched KVBM CXL G2 |

TP=1과 TP=2의 원시 처리량을 직접 비교하지 말고 동일 GPU 수 안에서 비교한
뒤 requests/s/GPU와 tokens/s/GPU도 기록합니다.

## Workload

- 입력 길이: 약 1K, 3K, 6K token
- unique prompt: cache miss/offload 비용
- repeated prefix: cache hit와 restore 효과
- multi-turn: 실제 재사용과 eviction
- concurrency: 1→8→32→128→500 순서로 증가
- 각 조건 warm-up 후 최소 5분 측정

## 필수 지표

- successful requests/s, output tokens/s, 오류율
- p50/p99 TTFT, p50/p99 ITL
- GPU HBM과 utilization
- CXL node MemFree/used 변화
- KVBM hit/miss/eviction과 D2H/H2D block counters
- worker restart, OOMKill, GPU Xid, kernel warning

## CXL residency 합격 기준

다음을 모두 만족해야 합니다.

- allocator가 G2의 모든 page를 `move_pages()`로 지정 node에서 확인
- 성공 로그에 지정 `cxl_numa_node`와 allocation bytes가 기록
- 다른 node가 발견되었을 때 worker가 fail-fast하는 negative test 성공
- workload 중 CXL node의 사용량이 cache pool만큼 증가
- DGD에서 `DYN_KVBM_CXL_NUMA_NODE`를 제거한 DRAM baseline과 명확히 구분

## Correctness

temperature 0, 동일 prompt와 seed로 no-offload와 CXL-offload의 응답을
비교합니다. 문자열 결과 외에도 오류율, finish reason과 token usage를
저장합니다. 모델/backend가 완전 deterministic하지 않으면 token-level 허용
기준을 사전에 정하고, corruption·NaN·잘못된 길이는 허용하지 않습니다.
