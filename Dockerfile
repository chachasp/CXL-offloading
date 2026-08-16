# syntax=docker/dockerfile:1.7
# Experimental overlay build. scripts/build-image.sh supplies the pinned source
# and is the supported entry point; direct `docker build` requires network access.
ARG BASE_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0
FROM ${BASE_IMAGE} AS kvbm-builder
USER root
ARG DYNAMO_COMMIT=8ce9e22f11576402102ea9d8b8e46233f5430a0d
ENV CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup PATH=/opt/cargo/bin:${PATH}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git patchelf pkg-config python3-dev && \
    rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
RUN git clone https://github.com/ai-dynamo/dynamo.git /src/dynamo && \
    cd /src/dynamo && git checkout --detach "${DYNAMO_COMMIT}" && \
    test "$(git rev-parse HEAD)" = "${DYNAMO_COMMIT}"
COPY patches/dynamo-v1.3.0-cxl-numa.patch /tmp/cxl.patch
RUN cd /src/dynamo && git apply --check /tmp/cxl.patch && git apply /tmp/cxl.patch
RUN python3 -m pip install --no-cache-dir 'maturin>=1,<2' patchelf && \
    cd /src/dynamo/lib/bindings/kvbm && \
    maturin build --release --out /wheelhouse

ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
COPY --from=kvbm-builder /wheelhouse /tmp/wheelhouse
RUN python3 -m pip install --no-cache-dir --no-deps --force-reinstall /tmp/wheelhouse/kvbm-*.whl && \
    rm -rf /tmp/wheelhouse
USER 1000
LABEL org.opencontainers.image.source="https://github.com/chachasp/CXL-offloading" \
      org.opencontainers.image.description="Experimental strict CXL NUMA G2 allocator for Dynamo KVBM 1.3.0"
