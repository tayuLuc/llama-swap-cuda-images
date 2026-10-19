# syntax=docker/dockerfile:1
ARG CUDA_TAG=13.4.2-cudnn-runtime-ubuntu26.04@sha256:44d81ee374c0c00192935010483c5f5fadf47941fe09ead0f0ad48d5c09cc611

# ============================================================
# Stage 1 — fetch all fork binaries (lightweight Alpine stage,
# discarded after COPY, keeping runtime image lean).
# ============================================================
FROM alpine:3.20 AS fetcher
RUN apk add --no-cache curl jq bash
ARG BUILD_MODE=stable
COPY scripts/fetch-binaries.sh scripts/select-releases.sh /tmp/
RUN chmod +x /tmp/fetch-binaries.sh /tmp/select-releases.sh && \
    /tmp/fetch-binaries.sh "${BUILD_MODE}" /tmp/out && \
    rm -f /tmp/fetch-binaries.sh /tmp/select-releases.sh

# ============================================================
# Stage 2 — llama-swap binary source (CPU minimal image;
# binary is CUDA-agnostic).
# ============================================================
FROM ghcr.io/mostlygeek/llama-swap:cpu AS llama-swap

# ============================================================
# Stage 3 — final runtime image
# ============================================================
FROM nvidia/cuda:${CUDA_TAG}

LABEL org.opencontainers.image.title="llama-swap CUDA 13.2 image" \
      org.opencontainers.image.description="llama-swap + 4 llama.cpp CUDA 13.2 forks (vanilla/turboquant/atomic/prism) for RTX 5090 (sm_120), amd64" \
      org.opencontainers.image.source="https://github.com/tayuLuc/llama-swap-cuda-images" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps for the bundled binaries.
#  ca-certificates  any HTTPS calls at runtime (model downloads etc)
#  libgomp1         OpenMP, used by llama.cpp
#  libcurl4/jpeg    imp links both: without them imp-server dies at exec with
#                   "error while loading shared libraries: libcurl.so.4". The
#                   CUDA runtime base ships neither.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        ca-certificates libc6 libgomp1 libcurl4 libjpeg-turbo8 curl && \
    rm -rf /var/lib/apt/lists/*

# Non-root app user (GID/UID 10001 matches upstream llama-swap image).
RUN groupadd --system --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --home-dir /app --create-home app

# llama-swap binary — multi-stage COPY sets ownership; chmod for execute.
COPY --chown=app:app --from=llama-swap /app/llama-swap /usr/local/bin/llama-swap
RUN chmod +x /usr/local/bin/llama-swap

# Fork binaries from the fetcher stage.
# COPY --chown + --chmod sets ownership and permissions in one instruction,
# replacing manual tar --owner / chmod +x in the script.
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/vanilla /opt/llama/vanilla
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/turboquant /opt/llama/turboquant
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/prism /opt/llama/prism
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/atomic /opt/llama/atomic
# imp is a separate engine, not a llama.cpp fork: imp-server/imp-cli, CUDA 13.4.
# libcudart.so.13 already exists in the 13.x base, so no CUDA asset is needed.
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/imp /opt/llama/imp
# Infernix: NInfer-lineage engine (Dense8/NVFP4 reader), not a llama.cpp fork.
# ffmpeg/curl shared libs installed above; libcudart comes from the CUDA base.
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/infernix /opt/llama/infernix

# vanilla is the default llama-server on PATH.
# CUDA runtime .so's come from the nvidia/cuda base image (/usr/local/cuda/lib64).
ENV PATH="/opt/llama/vanilla:${PATH}"
# ffmpeg 7 ABI: all fork binaries (Infernix and the llama.cpp lanes) carry
# NEEDED libav*60/58/7 with versioned symbols LIBAV*_* — built on Ubuntu 24.04.
# SONAME aliases are NOT enough: ffmpeg 8 does not export the old version
# nodes. Install the real noble packages --download-only (they would conflict
# with the resolute system ffmpeg), unpack them to a private directory and put
# it on LD_LIBRARY_PATH. -t noble pins the whole dependency closure to noble so
# every NEEDED soname comes from the same distro the binaries were built on.
# Drop when the lanes build on 26.04 or upstream ships ffmpeg-8 binaries.
RUN set -eux; \
    echo 'deb http://archive.ubuntu.com/ubuntu noble main universe' > /etc/apt/sources.list.d/noble.list; \
    apt-get update -qq; \
    mkdir -p /tmp/ff7 /opt/llama/ffmpeg7; \
    apt-get install -y -d -t noble --no-install-recommends libavcodec60 libavformat60 libavutil58 libswscale7; \
    cd /var/cache/apt/archives; \
    for f in ./*.deb; do dpkg -x "$f" /tmp/ff7; done; \
    find /tmp/ff7/usr/lib/x86_64-linux-gnu -maxdepth 1 -name '*.so.*' -exec mv -t /opt/llama/ffmpeg7/ {} +; \
    if LD_LIBRARY_PATH=/opt/llama/ffmpeg7 /opt/llama/infernix/infernix-serve --help 2>&1 | grep -q "not found"; then \
        echo "ffmpeg7 ABI gate failed: infernix-serve still cannot resolve libraries"; exit 1; fi; \
    rm -rf /tmp/ff7 /var/cache/apt/archives /var/lib/apt/lists/* /etc/apt/sources.list.d/noble.list
ENV LD_LIBRARY_PATH="/opt/llama/ffmpeg7"

ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

# llama-swap config.
COPY --chown=app:app llama-swap/config.yaml /etc/llama-swap/config.yaml

EXPOSE 8080
WORKDIR /models

# Run as the non-root app user (matches upstream llama-swap image).
USER app

CMD ["llama-swap", "--config", "/etc/llama-swap/config.yaml", "--host", "0.0.0.0", "--port", "8080"]
