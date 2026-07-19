# llama-swap CUDA 13.2 image

Docker image bundling **llama-swap** with **all 4 llama.cpp CUDA forks** pre-built
for CUDA 13.2 / RTX 5090 (compute capability 12.0, sm_120) on amd64:

| Fork | Source | Binary path in image |
|------|--------|----------------------|
| vanilla | ggml-org/llama.cpp | `/opt/llama/vanilla/bin/llama-server` |
| turboquant | TheTom/llama-cpp-turboquant | `/opt/llama/turboquant/bin/llama-server` |
| prism | PrismML-Eng/llama.cpp | `/opt/llama/prism/bin/llama-server` |
| atomic | AtomicBot-ai/atomic-llama-cpp-turboquant | `/opt/llama/atomic/bin/llama-server` |

The binaries are fetched at build time from
[`yet-another-llama.cpp-cuda-fork`](https://github.com/tayuLuc/yet-another-llama.cpp-cuda-fork)
GitHub releases (one release per fork × mode).

## Image tags (GHCR: `ghcr.io/tayuLuc/llama-swap-cuda-images`)

- `stable` / `stable-<date>-<runid>` — all 4 forks built from their **latest releases**.
- `nightly` / `nightly-<date>-<runid>` — all 4 forks built from **branch HEADs** (freshest commits).

Both tags contain **all 4 forks**; the difference is the source (release vs branch).

## Run

```bash
docker run --gpus all -p 8080:8080 \
  -v $PWD/models:/models \
  ghcr.io/tayuLuc/llama-swap-cuda-images:stable
```

llama-swap serves on `:8080`. Route a model to a specific fork via
`llama-swap/config.yaml` (pattern match on model name → fork binary).

## Requirements

- NVIDIA driver >= 580.13 (CUDA 13.2)
- `--gpus all` (or explicit device) at runtime

## How it is built

`yet-another-llama.cpp-cuda-fork` detects fork updates (release + branch) and
triggers this workflow via `workflow_dispatch` with `mode=stable|nightly`.
This repo then downloads all 4 fork binaries of that mode and packs one image.
Each build also cuts an **immutable git tag + release** listing the exact fork
tags that went into the image (audit trail).
