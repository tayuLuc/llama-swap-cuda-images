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

# GitHub Actions already exports GITHUB_TOKEN, so CI needs no secret configured;
# GH_TOKEN is accepted so a local run can reuse `gh auth token`.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")
if [ -z "$TOKEN" ]; then
  echo "!! no token: unauthenticated API allows 60 requests/hour per IP," >&2
  echo "!! and CI runners share IP ranges. Set GITHUB_TOKEN in the workflow." >&2
fi

# Paginate: GitHub orders /releases by created_at. A repo whose tags were all
# created in one batch (nightly CI running since setup) puts every stable tag on
# page 1 and every nightly on a later page, so a single 100-item window silently
# lost the nightly mode entirely and the `atomic` fork.
alls=()
for page in 1 2 3 4 5 6 7 8 9 10; do
  chunk=$(curl -s ${AUTH[@]+"${AUTH[@]}"} "https://api.github.com/repos/${SRC_REPO}/releases?per_page=100&page=${page}")
  # An unauthenticated rate-limit reply is a JSON object, not an array: counting
  # its keys silently yielded "2 releases" and an image with no backends. Fail here.
  if ! echo "$chunk" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "!! page ${page}: GitHub did not return an array (rate limit or auth?)" >&2
    echo "$chunk" | head -c 200 >&2
    echo >&2
    exit 1
  fi
  n=$(echo "$chunk" | jq 'length')
  [ "$n" -eq 0 ] && break
  alls+=("$chunk")
  [ "$n" -lt 100 ] && break
  # Пагинация нужна только из-за порядка created_at: свежие nightly лежат на
  # второй странице. Как только все четыре форка видны в окне, идти дальше незачем.
  found=$(printf '%s\n' "${alls[@]}" | jq -s -r --arg forks "$FORKS" \
    '[add[].tag_name] | map(split("-")[0]) | unique | length')
  [ "$found" -ge 4 ] && { echo "==> all $found forks visible after page $page"; break; }
done
rels_json=$(printf '%s\n' "${alls[@]}" | jq -s 'add')
echo "==> Loaded $(echo "$rels_json" | jq 'length') releases from ${SRC_REPO}"

missing=""

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
    echo "!! No $MODE release found for fork=$fork" >&2
    missing="$missing $fork"
    continue
  fi

  # download the amd64 tarball for this tag
  # Match only fork-specific tarballs (llama.cpp-cuda-13.2-<fork>-*.tar.gz),
  # NOT the shared cuda-runtime asset that ships alongside vanilla releases.
  url=$(echo "$rels_json" | jq -r --arg t "$tag" --arg f "$fork" \
    '.[] | select(.tag_name==$t) | .assets[] | select(.name|test("llama\\.cpp.*" + $f + ".*amd64\\.tar\\.gz$")) | .browser_download_url' | head -1)

  if [ -z "$url" ]; then
    echo "!! No amd64 asset for tag=$tag (fork=$fork)" >&2
    missing="$missing $fork"
    continue
  fi

  echo "-> $fork: $tag"
  tmp="/tmp/${fork}.tar.gz"
  curl -sL "$url" -o "$tmp"
  tar -xzf "$tmp" -C "$DEST/"
  rm -f "$tmp"
done

# A quiet skip used to ship an image missing a whole backend: the Dockerfile
# COPYs every fork, so the build died later on a missing path instead of naming
# the release that was absent.
if [ -n "$missing" ]; then
  echo "!! FAILED: no binaries for fork(s):$missing (mode=$MODE)" >&2
  exit 1
fi

echo "==> Done. Layout under $DEST:"
find "$DEST" -name VERSION.txt | sort
