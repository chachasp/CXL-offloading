# KVBM + CXL NUMA KV Cache Offloading

이 저장소는 NVIDIA Dynamo/KVBM v1.3.0의 G2 KV payload를 일반 DRAM이
아니라 **System RAM으로 등록된 CXL memory-only NUMA node에만** 배치하는
실험용 패치와 설치·검증 도구입니다.

> 현재 상태: 소스와 배포 도구는 로컬 정적 검사를 수행했지만, 작성 환경에는
> H100/CXL/Kubernetes가 없어 실제 GPU·CXL 실행은 아직 검증하지 못했습니다.
> 첫 배포는 반드시 64 GiB 이하의 작은 G2 cache로 시작하십시오.

## 무엇을 바꾸는가

기본 KVBM G2는 `cuMemHostAlloc`로 CUDA pinned host memory를 만듭니다. 이
패치는 G2 allocator에 `DYN_KVBM_CXL_NUMA_NODE`가 설정된 경우 다음의
fail-fast 경로를 추가합니다.

```text
GPU HBM (G1)
    ↕ CUDA copy
CXL System RAM NUMA node (G2 KV payload)

일반 DRAM: Dynamo/vLLM/PyTorch, metadata와 소형 control buffer에만 사용
```

1. anonymous `mmap`
2. `mbind(MPOL_BIND)`로 지정한 CXL NUMA node에 정책 설정
3. 모든 page를 fault-in
4. `move_pages()`로 **모든 page**의 node를 검사
5. 전부 CXL node에 있을 때만 `cuMemHostRegister`로 CUDA 등록
6. 한 page라도 다른 node이거나 CUDA 등록이 실패하면 worker 시작 실패

즉, KV payload가 DRAM으로 조용히 fallback하는 동작은 허용하지 않습니다.
다만 운영체제와 inference runtime까지 DRAM을 전혀 사용하지 않는다는 뜻은
아닙니다.

## 고정된 버전

- Dynamo/KVBM: `v1.3.0`, commit
  `8ce9e22f11576402102ea9d8b8e46233f5430a0d`
- vLLM: `0.23.0`
- PyTorch/CUDA: `2.11.0+cu130` / CUDA `13.0`
- 모델: `Qwen/Qwen3-30B-A3B-FP8`

정확한 값은 [UPSTREAM.lock](UPSTREAM.lock)에 있습니다.

## 매우 중요한 전제

- CXL은 Device-DAX가 아니라 Linux **System RAM/NUMA node**여야 합니다.
- 대상 CXL node의 `cpulist`가 비어 있는 memory-only node여야 합니다.
- CXL zone이 long-term page pinning을 허용해야 합니다. 가능하면
  `online_kernel`/normal zone 구성을 사용하십시오.
- Kubernetes container의 `cpuset.mems`에 CXL node가 포함되어야 합니다.
- Pod memory limit에는 CXL G2 cache와 runtime DRAM이 모두 계산됩니다.
- CXL namespace 변환과 reboot는 이 저장소가 자동 실행하지 않습니다.

## 가장 쉬운 설치 순서

아래 명령은 사내 서버에서 실행합니다. `<...>` 값만 환경에 맞게 바꾸십시오.

### 1. 저장소 받기

```bash
git clone https://github.com/chachasp/CXL-offloading.git
cd CXL-offloading
```

### 2. CXL node 확인

```bash
sudo ./scripts/preflight.sh
```

출력에서 `cpulist`가 비어 있고 약 640 GB를 가진 CXL memory-only node 번호를
확인하십시오. 예를 들어 node가 `2`라면 이후 명령의 `<CXL_NODE>`는 `2`입니다.
Device-DAX만 보이면 먼저 [CXL 모드 전환 문서](docs/CXL_MODE_CONVERSION.md)를
읽으십시오.

### 3. 작은 CUDA 등록 probe

```bash
sudo python3 scripts/cxl_cuda_probe.py --node <CXL_NODE> --size-mib 64
```

`RESULT: PASS`가 아니면 image를 빌드해도 KVBM G2가 시작되지 않습니다.
이때 `sudo ./scripts/collect-logs.sh` 결과를 전달하십시오.

### 4. custom image 빌드와 registry push

```bash
export IMAGE=<사내-registry>/dynamo-vllm-cxl:v1.3.0-1
./scripts/build-image.sh "$IMAGE"
docker push "$IMAGE"
```

`build-image.sh`는 고정된 upstream commit을 clone하고 patch 적용 전후를
검증한 뒤 이 저장소의 Dockerfile로 KVBM wheel을 다시 빌드합니다.

### 5. TP=1 DGD 생성

처음에는 64 GiB cache를 권장합니다.

```bash
./scripts/render-manifest.sh \
  --image "$IMAGE" --node <CXL_NODE> --cache-gb 64 --tp 1 \
  --output rendered/dgd-cxl-tp1.yaml
```

생성 파일의 PVC 이름, namespace용 Secret 이름을 기존 DGD와 비교한 뒤:

```bash
export NAMESPACE=<namespace>
kubectl apply -n "$NAMESPACE" -f rendered/dgd-cxl-tp1.yaml
kubectl wait -n "$NAMESPACE" --for=condition=Ready pod \
  -l nvidia.com/dynamo-graph-deployment-name=agg-kvbm-qwen3-cxl \
  --timeout=1800s
```

### 6. CXL 배치와 응답 검증

```bash
./scripts/verify-deployment.sh --namespace "$NAMESPACE" --node <CXL_NODE>
```

성공 조건은 다음 세 가지가 모두 충족되는 것입니다.

- worker log에 `allocated and CUDA-registered strict CXL NUMA G2 storage`
- 해당 로그의 `cxl_numa_node`가 지정 node와 일치
- sample inference 성공 및 worker crash/GPU OOM 없음

allocator가 시작 전에 모든 G2 page를 검사하므로 큰 cache는 첫 시작에 시간이
걸립니다. 초기 64 GiB 검증 후 128→256 GiB 순으로 늘리십시오.

## 향후 TP=2

두 GPU를 같은 CPU socket에 장착한 뒤 먼저 topology를 다시 확인하십시오.

```bash
nvidia-smi topo -m
lspci -Dtv
numactl --hardware
```

그 다음 `--tp 2`로 manifest를 생성합니다.

```bash
./scripts/render-manifest.sh \
  --image "$IMAGE" --node <CXL_NODE> --cache-gb 128 --tp 2 \
  --output rendered/dgd-cxl-tp2.yaml
```

`KVBM_CACHE_PARALLELISM=tensor_parallel`을 사용합니다. `cache-gb`가 rank별인지
전체인지 최종 image에서 metrics로 확인한 뒤 640 GB를 넘지 않게 조정하십시오.

## 제거와 rollback

```bash
./scripts/uninstall.sh --namespace "$NAMESPACE"
kubectl apply -n "$NAMESPACE" -f <기존-DGD.yaml>
```

제거 스크립트는 DGD만 삭제하며 CXL mode, namespace, kernel memory block을
변경하지 않습니다.

## 실패 시 수집할 자료

```bash
sudo ./scripts/collect-logs.sh --namespace "$NAMESPACE"
```

생성된 `logs/cxl-kvbm-*.tar.gz`에는 token, kubeconfig, Secret 값이 포함되지
않도록 수집 대상을 제한했습니다. 그래도 외부 반출 전 hostname·BDF·Pod 이름을
검토하십시오.

## 문서

- [설계와 데이터 경로](docs/DESIGN.md)
- [Device-DAX → System RAM 전환 시 주의사항](docs/CXL_MODE_CONVERSION.md)
- [검증과 benchmark](docs/VALIDATION.md)
- [알려진 한계](docs/KNOWN_LIMITATIONS.md)
- [조사 보고서](docs/cxl-kv-offloading-research-report.html)
