# Device-DAX에서 System RAM/NUMA로 전환

이 문서는 안전 경계만 정의합니다. namespace 재구성 명령은 장치와 region
상태에 따라 데이터 손실을 일으킬 수 있으므로 자동 스크립트로 제공하지
않습니다.

## 읽기 전용 확인

```bash
sudo cxl list -vvv
sudo daxctl list -R -D -M -u
ls -l /dev/dax*
numactl --hardware
for n in /sys/devices/system/node/node*; do
  echo "$n cpus=$(cat "$n/cpulist")"
  grep MemTotal "$n/meminfo"
done
```

## 필요한 최종 상태

- `/dev/dax0.0`을 KV backend로 사용하지 않음
- CXL 용량이 Linux System RAM으로 online
- CXL에 대응하는 별도 NUMA node가 보임
- 그 node의 `cpulist`는 비어 있음
- `numactl --hardware`에서 약 640 GB 확인
- Pod의 `Mems_allowed_list`에 해당 node 포함
- 작은 CXL mapping의 `cuMemHostRegister` 성공

## 작업 전 백업할 정보

```bash
sudo cxl list -vvv > cxl-before.json
sudo daxctl list -R -D -M -u > daxctl-before.json
lsmem --json > lsmem-before.json
numactl --hardware > numa-before.txt
```

장비 공급사와 사용 중인 `cxl-cli/daxctl` 버전의 공식 절차를 따라
Device-DAX → system-ram 전환을 수행하십시오. mode 변경, namespace 삭제,
memory online과 reboot는 사람이 출력과 대상을 재확인한 뒤 실행해야 합니다.

## Zone 주의사항

CUDA 등록에는 long-term pinning이 필요합니다. CXL memory가 movable zone으로
online되면 등록이 거부될 수 있습니다. `cat /proc/zoneinfo`와 `lsmem -o
RANGE,SIZE,STATE,REMOVABLE,BLOCK,NODE,ZONES`로 확인하고, 가능하면 공급사가
지원하는 normal/`online_kernel` 방식을 사용하십시오. 최종 판정은 추측이
아니라 `scripts/cxl_cuda_probe.py` 결과로 합니다.

## 복구

KVBM DGD를 먼저 삭제한 뒤 CXL page 사용량이 0인지 확인하십시오. 그 다음에만
공급사 runbook에 따라 memory offline과 Device-DAX 복구를 수행하십시오.
이 저장소의 `uninstall.sh`는 CXL mode를 변경하지 않습니다.
