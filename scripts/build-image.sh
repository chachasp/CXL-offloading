#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <registry/image:tag>" >&2
  exit 2
fi
image="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/UPSTREAM.lock"
source "$lock_file"

echo "[1/3] Patch가 고정된 Dynamo commit에 적용되는지 확인합니다."
verify_dir="$repo_root/.build/dynamo-verify"
if [[ ! -d "$verify_dir/.git" ]]; then
  mkdir -p "$repo_root/.build"
  git clone --filter=blob:none "$DYNAMO_REPOSITORY" "$verify_dir"
fi
git -C "$verify_dir" fetch --depth 1 origin "$DYNAMO_COMMIT"
git -C "$verify_dir" checkout --detach "$DYNAMO_COMMIT"
git -C "$verify_dir" reset --hard "$DYNAMO_COMMIT"
git -C "$verify_dir" clean -ffd
test "$(git -C "$verify_dir" rev-parse HEAD)" = "$DYNAMO_COMMIT"
git -C "$verify_dir" apply --check "$repo_root/patches/dynamo-v1.3.0-cxl-numa.patch"

echo "[2/3] Custom KVBM image를 빌드합니다: $image"
docker build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "DYNAMO_COMMIT=$DYNAMO_COMMIT" \
  --label "org.opencontainers.image.revision=$DYNAMO_COMMIT" \
  --tag "$image" \
  --file "$repo_root/Dockerfile" \
  "$repo_root"

echo '[3/3] Image의 KVBM version을 확인합니다.'
docker run --rm --entrypoint python3 "$image" -c \
  'import importlib.metadata as m; print("kvbm=" + m.version("kvbm"))'
echo "BUILD RESULT: PASS"
echo "다음 명령은 자동 실행하지 않았습니다: docker push $image"
