# llama-swap image bundling all 4 llama.cpp CUDA 13.2 forks (RTX 5090 / sm_120).
# Binaries are fetched at build time from the source repo's GitHub releases.
ARG CUDA_TAG=13.2.0-cudnn-runtime-ubuntu24.04
FROM nvidia/cuda:${CUDA_TAG}

ENV DEBIAN_FRONTEND=noninteractive

# llama-swap (single static binary) + runtime deps for the bundled llama.cpp bins.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates curl jq libc6 && \
    rm -rf /var/lib/apt/lists/*

# Fetch llama-swap release binary.
ARG LLAMA_SWAP_VERSION=v1.2.0
RUN curl -sL "https://github.com/mostlygeek/llama-swap/releases/download/${LLAMA_SWAP_VERSION}/llama-swap-linux-amd64" \
      -o /usr/local/bin/llama-swap && \
    chmod +x /usr/local/bin/llama-swap

# Build arg: stable or nightly — decides which release set we pack.
ARG BUILD_MODE=stable

# Fetch all 4 fork binaries (CUDA 13.2, amd64) into /opt/llama/<fork>/bin.
COPY scripts/fetch-binaries.sh /tmp/fetch-binaries.sh
RUN chmod +x /tmp/fetch-binaries.sh && \
    /tmp/fetch-binaries.sh "${BUILD_MODE}" /opt/llama && \
    rm -f /tmp/fetch-binaries.sh

# vanilla is the default llama-server on PATH.
ENV PATH="/opt/llama/vanilla/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/llama/vanilla/bin:${LD_LIBRARY_PATH:-}"

# llama-swap config: choose fork per model.
COPY llama-swap/config.yaml /etc/llama-swap/config.yaml

EXPOSE 8080
WORKDIR /models

# Default: serve llama-swap. Override CMD to run a raw llama-server if desired.
CMD ["llama-swap", "--config", "/etc/llama-swap/config.yaml", "--host", "0.0.0.0", "--port", "8080"]
