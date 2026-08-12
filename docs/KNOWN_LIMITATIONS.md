# 알려진 한계

- H100/CXL server에서 아직 실행하지 못한 실험 코드입니다.
- CXL System RAM을 CUDA에 등록할 수 있는지는 zone type과 NVIDIA driver의
  실제 동작에 달려 있습니다. 등록 실패 시 DRAM staging fallback은 없습니다.
- allocator가 시작 시 모든 G2 page를 fault하고 검사하므로 큰 pool의 시작
  시간이 길고 첫 allocation 순간 memory bandwidth를 크게 사용합니다.
- memory-only NUMA node만 지원합니다. DRAM과 CXL이 섞인 node는 거부합니다.
- CXL NUMA node가 여러 장치에 interleave되어 있으면 page의 node residency는
  증명하지만 특정 CMM module까지 구분하지는 않습니다.
- GPU→CXL 직접 DMA를 보장하거나 주장하지 않습니다.
- TP=2는 코드 구조에 포함했지만 두 번째 GPU 장착 후 실제 검증이 필요합니다.
- Kubernetes memory cgroup에는 CXL G2도 포함되므로 limit가 작으면 OOM kill될
  수 있습니다.
- top-level Dockerfile의 custom wheel build는 사내 registry/network와 NIXL
  개발 library 상태에 영향을 받습니다. 실패하면 `collect-logs.sh`와 전체
  Docker build log가 필요합니다.
