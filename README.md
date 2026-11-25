# llama-swap CUDA image

Docker image bundling **llama-swap** with **all 4 llama.cpp CUDA forks plus imp, Infernix
and Basalt** pre-built for CUDA 13.4 / RTX 5090 (compute capability 12.0, sm_120) on amd64:

| Fork | Source | Binary path in image |
|------|--------|----------------------|
| vanilla | ggml-org/llama.cpp | `/opt/llama/vanilla/llama-server` |
| turboquant | TheTom/llama-cpp-turboquant | `/opt/llama/turboquant/llama-server` |
| prism | PrismML-Eng/llama.cpp | `/opt/llama/prism/llama-server` |
| atomic | AtomicBot-ai/atomic-llama-cpp-turboquant | `/opt/llama/atomic/llama-server` |
| imp | tayuLuc/imp | `/opt/llama/imp/imp-server` |
| basalt | jesdga95/basalt | `/opt/llama/basalt/bin/basalt` |

**Basalt (jesdga95/basalt) is not a llama.cpp fork either.** A CUDA 13 MoE engine for
Blackwell; the release archive (bin/ + serve/ + tools/ + requirements.txt) is fetched from
**its own repo** (`basalt@jesdga95/basalt` lane, not the forks repo), and its Python server
needs a venv at the archive root - the image builds one from a uv-managed standalone CPython
(at `/opt/llama/basalt/.venv`, symlinked to `/opt/venv`). No system apt python is installed.
Config (`basalt_config.json`) is deployment-supplied, not baked in. The lane is **stable-only**:
nightly ships it empty with a note (a cross-repo lane has no nightly artifact). Launch it as
a llama-swap slot command (`bin/basalt serve --config ...`, OpenAI-compatible endpoint) -
it is not a llama-swap backend plugin, the table row names the binary, not a routable backend.

**Infernix (Wallawalla47/Infernix) is not a llama.cpp fork either**: NInfer-lineage engine,
reads NVIDIA Dense8 + .ngram volumes directly, ships `infernix` + `infernix-serve` at
`/opt/llama/infernix`; binary artifacts built by our own CUDA lane in
`yet-another-llama.cpp-cuda-fork` (kind=infernix) and fetched the same way as the forks.

**imp is not a llama.cpp fork.** It is a separate engine with its own CMake flags,
its own binaries and its own CUDA 13.4 base image; the four forks share llama.cpp's
build. It ships `imp-server` and `imp-cli` under `/opt/llama/imp`.

The binaries are fetched at build time from
[`yet-another-llama.cpp-cuda-fork`](https://github.com/tayuLuc/yet-another-llama.cpp-cuda-fork)
GitHub releases (one release per fork × mode).

## Image tags (GHCR: `ghcr.io/tayuluc/llama-swap-cuda-images`)

- `stable` / `stable-<date>-<runid>` — all 7 engines built from their **latest releases**.
- `nightly` / `nightly-<date>-<runid>` — the forks repo built from **branch HEADs** (freshest commits); lanes with no nightly artifact (`infernix`, `basalt`) ship empty with a note, the image is still tagged.

Both tags contain the same engine roster; the difference is the source (release vs branch).

## Run

```bash
docker run --gpus all -p 8080:8080 \
  -v $PWD/models:/models \
  ghcr.io/tayuluc/llama-swap-cuda-images:stable
```

llama-swap serves on `:8080`. Route a model to a specific fork via
`llama-swap/config.yaml` (pattern match on model name → fork binary).

## Requirements

- NVIDIA driver >= 580.13 (CUDA 13.4; basalt's own floor is R580+)
- `--gpus all` (or explicit device) at runtime

## How it is built

`yet-another-llama.cpp-cuda-fork` detects fork updates (release + branch) and
triggers this workflow via `workflow_dispatch` with `mode=stable|nightly`.
This repo then downloads all 7 engine artifacts of that mode and packs one image.
Each build also cuts an **immutable git tag + release** listing the exact fork
tags that went into the image (audit trail).
