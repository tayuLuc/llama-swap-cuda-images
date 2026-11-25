# syntax=docker/dockerfile:1
ARG CUDA_TAG=13.4.2-cudnn-runtime-ubuntu26.04@sha256:44d81ee374c0c00192935010483c5f5fadf47941fe09ead0f0ad48d5c09cc611

# ============================================================
# Stage 1 — fetch all fork binaries (lightweight Alpine stage,
# discarded after COPY, keeping runtime image lean).
# ============================================================
FROM alpine:3.20 AS fetcher
RUN apk add --no-cache curl jq bash
ARG BUILD_MODE=stable
# SELECTION_KEY is a fingerprint of the release tags this build is supposed to
# pack, computed on the runner from select-releases.sh. Docker's layer cache keys
# this RUN on (base, COPYed scripts, BUILD_MODE) only, so without an argument that
# changes with the selection, a build that selects a newer upstream release ships
# the PREVIOUS run's downloaded binaries (measured 24.11: two runs, byte-identical
# linux/amd64 config digest, 31 s apart). Echoing the arg here is what puts it in
# the cache key; changing it re-runs the fetch, identical selection stays cached.
ARG SELECTION_KEY=unkeyed
COPY scripts/fetch-binaries.sh scripts/select-releases.sh /tmp/
RUN echo "fetch-binaries: mode=${BUILD_MODE} selection-key=${SELECTION_KEY}" && \
    chmod +x /tmp/fetch-binaries.sh /tmp/select-releases.sh && \
    /tmp/fetch-binaries.sh "${BUILD_MODE}" /tmp/out && \
    rm -f /tmp/fetch-binaries.sh /tmp/select-releases.sh

# ============================================================
# Stage 2 — llama-swap binary source (CPU minimal image;
# binary is CUDA-agnostic).
# ============================================================
FROM ghcr.io/mostlygeek/llama-swap:cpu AS llama-swap

# ============================================================
# Stage 2b — Basalt Python venv (uv-managed standalone CPython).
#
# basalt's server is Python (serve/ tree) and bin/basalt serve uses a .venv
# placed at the archive root when it is there (docs/platforms.md). The venv
# and the interpreter are built here at their FINAL absolute paths - a venv
# hardcodes the interpreter path in bin/python symlinks and pyvenv.cfg, so
# building at /venv and copying elsewhere is the classic broken move.
#
# uv python install ships python-build-standalone: a self-contained CPython
# (openssl/sqlite bundled) built against glibc 2.17, so it runs on this
# ubuntu base and on a future slimmed base unchanged - no apt python enters
# the runtime image.
# ============================================================
FROM ghcr.io/astral-sh/uv:0.5.9-python3.13-bookworm-slim@sha256:3c1165f681c3f433fae92b87da9d426282b5b7f10a04409ec3be2ccd28778a65 AS basalt-venv
ARG PYTHON_VERSION=3.13
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
COPY --from=fetcher /tmp/out/basalt/requirements.txt /tmp/basalt-requirements.txt
RUN set -eux; \
    uv python install "$PYTHON_VERSION" --no-cache; \
    PYROOT=$(ls -d /opt/uv/python/cpython-${PYTHON_VERSION}.*); \
    uv venv --python "$PYROOT/bin/python${PYTHON_VERSION}" /opt/venv; \
    uv pip install --python /opt/venv/bin/python --no-cache-dir -r /tmp/basalt-requirements.txt; \
    chown -R 10001:10001 /opt/uv /opt/venv

# ============================================================
# Stage 3 — final runtime image
# ============================================================
FROM nvidia/cuda:${CUDA_TAG}

LABEL org.opencontainers.image.title="llama-swap CUDA 13 image" \
      org.opencontainers.image.description="llama-swap + 4 llama.cpp CUDA forks (vanilla/turboquant/atomic/prism) + imp + Infernix + Basalt for CUDA 13.4 / RTX 5090 (sm_120), amd64" \
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

# Basalt: MoE engine (jesdga95/basalt, author's linux-x64 release archive:
# bin/ + serve/ + tools/ + data/ + docs/ + requirements.txt), not a llama.cpp
# fork. bin/basalt serve reads its config (models, port) from basalt_config.json
# - supplied per deployment via the mounted /swap-config, not baked here.
# Nightly mode ships an empty dir (cross-repo lane, no nightly releases).
COPY --from=fetcher --chown=app:app --chmod=755 /tmp/out/basalt /opt/llama/basalt
# The author's documented venv location = .venv at the archive root, which
# bin/basalt serve uses when present. /venv symlink: the venv's scripts carry
# #! shebangs for /opt/venv/bin/python from build time - keep that path alive.
COPY --from=basalt-venv --chown=app:app --chmod=755 /opt/uv /opt/uv
COPY --from=basalt-venv --chown=app:app --chmod=755 /opt/venv /opt/venv
RUN ln -sfn /opt/venv /opt/llama/basalt/.venv

# Basalt gates (same ldd-not---help doctrine as the ffmpeg7 gate above):
# every NEEDED of the 176 MB engine binary must resolve here, libcuda.so.1
# exempt (driver library, injected by the container runtime at launch);
# the standalone interpreter must be self-contained on this base; the venv
# must import everything serve/ needs (requirements.txt, torch-free by design).
# Empty lane dir (nightly): the whole gate is skipped with a note, like infernix.
RUN set -eux; \
    if [ ! -x /opt/llama/basalt/bin/basalt ]; then \
        echo "note: no basalt binaries in this build (cross-repo lane, nightly mode)"; \
        exit 0; \
    fi; \
    for B in basalt basalt-vision; do \
        MISSING=$(LD_LIBRARY_PATH="/usr/local/cuda/lib64:/opt/llama/ffmpeg7${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "/opt/llama/basalt/bin/$B" | awk '/not found/{print $1}' | grep -v -x -e 'libcuda.so.1' || true); \
        if [ -n "$MISSING" ]; then \
            echo "basalt ABI gate failed for $B: unresolved libraries: $MISSING"; \
            LD_LIBRARY_PATH="/usr/local/cuda/lib64:/opt/llama/ffmpeg7${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "/opt/llama/basalt/bin/$B" | grep "not found"; \
            exit 1; \
        fi; \
    done; \
    echo "basalt ABI gate ok (basalt + basalt-vision; libcuda.so.1 exempt)"; \
    PY=$(readlink -f /opt/venv/bin/python); \
    ldd "$PY" | awk '/not found/{print $1}' | grep . && { echo "standalone python gate failed: see not-found above"; exit 1; } || true; \
    "$PY" -c "import sys; print('python', sys.version.split()[0], 'gate ok')"; \
    "$PY" -c "import numpy, jinja2, markupsafe, regex, yaml, tqdm, PIL, pypdf, psutil; print('basalt venv imports ok')"; \
    /opt/venv/bin/python -c "import sys; sys.executable; assert sys.version_info[:2] >= (3, 10), 'serve/ needs py>=3.10'"

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
    if [ ! -x /opt/llama/infernix/infernix-serve ]; then \
        echo "note: no infernix binaries in this build (optional lane, nightly mode)"; \
    else \
        MISSING=$(LD_LIBRARY_PATH=/opt/llama/ffmpeg7 ldd /opt/llama/infernix/infernix-serve | awk '/not found/{print $1}' | grep -v -x -e 'libcuda.so.1' || true); \
        if [ -n "$MISSING" ]; then \
            echo "ffmpeg7 ABI gate failed: unresolved libraries: $MISSING"; \
            LD_LIBRARY_PATH=/opt/llama/ffmpeg7 ldd /opt/llama/infernix/infernix-serve | grep "not found"; \
            exit 1; \
        fi; \
        echo "ffmpeg7 ABI gate ok (libcuda.so.1 exempt: the driver library is injected by the container runtime, absent at build time)"; \
    fi; \
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
