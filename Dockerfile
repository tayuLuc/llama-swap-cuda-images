# syntax=docker/dockerfile:1
ARG CUDA_TAG=13.2.0-cudnn-runtime-ubuntu24.04

# ============================================================
# Stage 1 — fetch all fork binaries (lightweight Alpine stage,
# discarded after COPY, keeping runtime image lean).
# ============================================================
FROM alpine:3.20 AS fetcher
RUN apk add --no-cache curl jq bash
ARG BUILD_MODE=stable
COPY scripts/fetch-binaries.sh /tmp/fetch-binaries.sh
RUN chmod +x /tmp/fetch-binaries.sh && \
    /tmp/fetch-binaries.sh "${BUILD_MODE}" /tmp/out && \
    rm -f /tmp/fetch-binaries.sh

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

# Runtime deps for the bundled llama.cpp binaries (libgomp = OpenMP).
# ca-certificates kept for any HTTPS calls at runtime (model downloads etc).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates libc6 libgomp1 && \
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

# vanilla is the default llama-server on PATH.
# CUDA runtime .so's come from the nvidia/cuda base image (/usr/local/cuda/lib64).
ENV PATH="/opt/llama/vanilla:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

# llama-swap config.
COPY --chown=app:app llama-swap/config.yaml /etc/llama-swap/config.yaml

EXPOSE 8080
WORKDIR /models

# Run as the non-root app user (matches upstream llama-swap image).
USER app

CMD ["llama-swap", "--config", "/etc/llama-swap/config.yaml", "--host", "0.0.0.0", "--port", "8080"]
