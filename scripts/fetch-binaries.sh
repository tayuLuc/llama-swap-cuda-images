#!/usr/bin/env bash
# Fetch all 4 llama.cpp fork binaries from the source repo's GitHub releases.
# Usage: fetch-binaries.sh <mode: stable|nightly> <dest-dir>
#
# For each fork we pick the LATEST matching release of the requested mode:
#   stable -> release whose tag ends with the upstream release tag (not -nightly-)
#   nightly-> release whose tag ends with -nightly-<sha>
# We never filter by the `prerelease` flag of the SOURCE repo — both stable and
# nightly builds are downloaded and packed into ONE image (all 4 forks together).
set -euo pipefail

MODE="${1:?usage: fetch-binaries.sh <stable|nightly> <dest>}"
DEST="${2:?usage: fetch-binaries.sh <stable|nightly> <dest>}"
SRC_REPO="tayuLuc/yet-another-llama.cpp-cuda-fork"
FORKS="vanilla turboquant prism atomic"

mkdir -p "$DEST"

echo "==> Fetching mode=$MODE binaries for forks: $FORKS"

rels_json=$(curl -s "https://api.github.com/repos/${SRC_REPO}/releases?per_page=100")

for fork in $FORKS; do
  if [ "$MODE" = "nightly" ]; then
    # pick latest release tag matching <fork>-nightly-<sha>
    tag=$(echo "$rels_json" | jq -r --arg f "$fork" \
      '[.[] | select(.tag_name | test("^"+$f+"-nightly-[0-9a-f]+$"))]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  else
    # pick latest release tag matching <fork>-<anything> but NOT -nightly-
    tag=$(echo "$rels_json" | jq -r --arg f "$fork" \
      '[.[] | select(.tag_name | test("^"+$f+"-")) | select(.tag_name | test("nightly") | not)]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  fi

  if [ -z "$tag" ]; then
    echo "!! No $MODE release found for fork=$fork — skipping"
    continue
  fi

  # download the amd64 tarball for this tag
  url=$(echo "$rels_json" | jq -r --arg t "$tag" \
    '.[] | select(.tag_name==$t) | .assets[] | select(.name|test("amd64.tar.gz$")) | .browser_download_url' | head -1)

  if [ -z "$url" ]; then
    echo "!! No amd64 asset for tag=$tag — skipping"
    continue
  fi

  echo "-> $fork: $tag"
  tmp="/tmp/${fork}.tar.gz"
  curl -sL "$url" -o "$tmp"
  tar -xzf "$tmp" -C "$DEST/"
  rm -f "$tmp"
done

echo "==> Done. Layout under $DEST:"
find "$DEST" -name VERSION.txt | sort
