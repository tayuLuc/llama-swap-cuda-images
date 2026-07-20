# llama-swap binary source: official minimal image (carries just the llama-swap binary).
FROM ghcr.io/mostlygeek/llama-swap:cuda AS llama-swap

# llama-swap image bundling all 4 llama.cpp CUDA 13.2 forks (RTX 5090 / sm_120).
# Binaries are fetched at build time from the source repo's GitHub releases.
ARG CUDA_TAG=13.2.0-cudnn-runtime-ubuntu24.04
FROM nvidia/cuda:${CUDA_TAG}

LABEL org.opencontainers.image.title="llama-swap CUDA 13.2 image" \
      org.opencontainers.image.description="llama-swap + 4 llama.cpp CUDA 13.2 forks (vanilla/turboquant/atomic/prism) for RTX 5090 (sm_120), amd64" \
      org.opencontainers.image.source="https://github.com/tayuLuc/llama-swap-cuda-images" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# llama-swap runtime deps + libs for the bundled llama.cpp bins (libgomp = OpenMP).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates curl jq libc6 libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# Match upstream llama-swap image: provide a non-root app user/group (GID/UID 10001)
# so the container can run as --user 10001:10001 without "missing group" errors.
RUN groupadd --system --gid 10001 app && \
    useradd --system --uid 10001 --gid 10001 --home-dir /app --create-home app

# Pull the llama-swap binary from the official minimal image (multi-stage COPY).
COPY --from=llama-swap /app/llama-swap /usr/local/bin/llama-swap
RUN chmod +x /usr/local/bin/llama-swap

# Build arg: stable or nightly — decides which release set we pack.
ARG BUILD_MODE=stable

# Fetch all 4 fork binaries (CUDA 13.2, amd64) into /opt/llama/<fork>/.
COPY scripts/fetch-binaries.sh /tmp/fetch-binaries.sh
RUN chmod +x /tmp/fetch-binaries.sh && \
    /tmp/fetch-binaries.sh "${BUILD_MODE}" /opt/llama && \
    rm -f /tmp/fetch-binaries.sh

# vanilla is the default llama-server on PATH.
# CUDA runtime .so's come from the base nvidia/cuda:13.2-runtime image
# (/usr/local/cuda/lib64); the fork tarballs no longer bundle them.
ENV PATH="/opt/llama/vanilla:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

# llama-swap config: choose fork per model.
COPY llama-swap/config.yaml /etc/llama-swap/config.yaml

EXPOSE 8080
WORKDIR /models

# Run as the non-root app user (matches upstream llama-swap image).
USER app

# Default: serve llama-swap. Override CMD to run a raw llama-server if desired.
CMD ["llama-swap", "--config", "/etc/llama-swap/config.yaml", "--host", "0.0.0.0", "--port", "8080"]
