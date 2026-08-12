# 설계

## 목표와 비목표

목표는 KVBM G2의 KV payload를 지정된 CXL memory-only NUMA node에만
할당하고, 일반 DRAM fallback을 검출해 worker 시작을 실패시키는 것입니다.
일반 프로세스 메모리, metadata, CUDA/NCCL control buffer까지 CXL로 옮기는
것은 목표가 아닙니다. SSD G3도 활성화하지 않습니다.

## Upstream 수정 지점

기준은 Dynamo `v1.3.1` commit
`a49702e4432e7fa43cbc88175bddb31604340f19`입니다.

- `lib/llm/src/block_manager/storage/cuda.rs`
  - G2 host layout에서 쓰는 `PinnedAllocator::allocate`가
    `DYN_KVBM_CXL_NUMA_NODE`를 읽습니다.
  - 변수가 없으면 upstream 동작을 그대로 유지합니다.
  - 변수가 있으면 `PinnedStorage::new_cxl_numa`만 호출합니다.
- `lib/memory/src/pinned.rs`
  - CXL 전용 mmap/mbind/fault/placement/CUDA-register RAII 경로를 추가합니다.
  - CUDA host allocation과 CXL mmap의 해제 방법을 구분합니다.

## 데이터 경로

성공하는 시스템에서:

```text
vLLM TP rank의 GPU KV block (G1)
        ↕ KVBM CUDA transfer
CUDA-registered CXL NUMA mapping (G2)
```

이 설계는 GPU가 CXL protocol로 직접 접근한다고 주장하지 않습니다. 실제
전송은 PCIe/CUDA host-memory copy로 분류하며, root complex와 driver 내부
경로는 Nsight/CUPTI 및 hardware counter로 별도 측정해야 합니다.

## 왜 memory-only node만 허용하는가

CPU가 있는 node는 일반 DIMM DRAM과 CXL이 같은 node에 섞일 수 있어
`move_pages()` 결과만으로 CXL residency를 증명할 수 없습니다. 이 MVP는
`cpulist`가 비어 있는 CXL memory-only node만 허용함으로써 판정을
보수적으로 만듭니다.

## 실패 원칙

- node가 없거나 CPU를 보유: 실패
- `mbind` 실패: 실패
- 한 page라도 다른 node: 실패
- `cuMemHostRegister` 실패: 실패
- DRAM fallback: 없음

이는 가용성보다 CXL placement 증명을 우선하는 실험 정책입니다.

## TP=2

KVBM의 `tensor_parallel` mode에서는 각 worker가 KV block shard를 가집니다.
각 rank의 G2 allocator가 동일 CXL memory-only node를 사용합니다. 두 GPU가
같은 CPU socket에 있어도 rank별 PCIe 거리와 bandwidth는 다를 수 있으므로
rank별 metrics를 비교해야 합니다.

## Kubernetes의 역할

Kubernetes는 CXL을 별도 extended resource로 알 필요가 없습니다. System
RAM으로 online된 CXL은 Pod의 address space에서 NUMA policy로 접근합니다.
Kubernetes는 GPU 수, 총 memory request/limit, IPC_LOCK capability와 Pod
lifecycle을 관리합니다. 실제 CXL node 선택과 residency 증명은 allocator가
담당합니다.
