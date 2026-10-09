#!/usr/bin/env bash
# Fetch every backend binary from the source repo's GitHub releases.
#
# Usage: fetch-binaries.sh <stable|nightly> <dest-dir>
#
# Tag selection lives in select-releases.sh so this download and the release
# notes written by build-image.yml can never disagree about what was packed.
#
# The llama.cpp forks all ship llama-server. imp is a separate engine and ships
# imp-server/imp-cli under a differently named asset, so each backend carries
# its own asset pattern and binary list instead of one hardcoded name.
set -euo pipefail

MODE="${1:?usage: fetch-binaries.sh <stable|nightly> <dest>}"
DEST="${2:?usage: fetch-binaries.sh <stable|nightly> <dest>}"
SRC_REPO="${SRC_REPO:-tayuLuc/yet-another-llama.cpp-cuda-fork}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# name|asset regex|required binaries
BACKENDS='vanilla|llama\.cpp.*vanilla.*amd64\.tar\.gz$|llama-server
turboquant|llama\.cpp.*turboquant.*amd64\.tar\.gz$|llama-server
prism|llama\.cpp.*prism.*amd64\.tar\.gz$|llama-server
atomic|llama\.cpp.*atomic.*amd64\.tar\.gz$|llama-server
imp|imp-cuda13\.4-[a-z]+-amd64\.tar\.gz$|imp-server'

NAMES=$(printf '%s\n' "$BACKENDS" | cut -d'|' -f1)

mkdir -p "$DEST"

echo "==> Fetching mode=$MODE binaries for: $(echo "$NAMES" | tr '\n' ' ')"

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")

# Resolve every backend's tag in one pass; a missing one fails the whole run
# rather than shipping an image that is quietly one backend short.
selected=$("$HERE/select-releases.sh" "$MODE" $NAMES) || {
  echo "!! FAILED: at least one backend has no $MODE release" >&2
  exit 1
}

# Asset URLs come from the same releases; page 1 holds the tags we just picked
# because select-releases.sh walks until every backend is visible.
rels_json=$(curl -s "${AUTH[@]}" \
  "https://api.github.com/repos/${SRC_REPO}/releases?per_page=100&page=1")

missing=""
while IFS=' ' read -r name tag; do
  [ -n "$name" ] || continue
  [ -n "$tag" ] || { missing="$missing $name"; continue; }

  row=$(printf '%s\n' "$BACKENDS" | grep "^${name}|" || true)
  pattern=$(printf '%s' "$row" | cut -d'|' -f2)
  want_bins=$(printf '%s' "$row" | cut -d'|' -f3)

  url=$(echo "$rels_json" | jq -r --arg t "$tag" --arg p "$pattern" \
    '.[] | select(.tag_name==$t) | .assets[] | select(.name|test($p)) | .browser_download_url' | head -1)

  if [ -z "$url" ]; then
    echo "!! No matching asset for $name at tag=$tag" >&2
    missing="$missing $name"
    continue
  fi

  echo "-> $name: $tag"
  tmp="/tmp/${name}.tar.gz"
  # -f: without it curl writes an error page into the tarball and the failure
  # surfaces at tar, one backend later than it should.
  curl -sfL "${AUTH[@]}" "$url" -o "$tmp"
  tar -xzf "$tmp" -C "$DEST/"
  rm -f "$tmp"

  # Verify the result, not the download: a truncated tarball used to pass here
  # and fail later in the Dockerfile on a missing COPY path.
  for b in ${want_bins//,/ }; do
    if [ ! -x "$DEST/$name/$b" ]; then
      echo "!! $name: $tag unpacked without $b" >&2
      missing="$missing $name"
    fi
  done
done <<< "$selected"

if [ -n "$missing" ]; then
  echo "!! FAILED: no usable binaries for:$missing (mode=$MODE)" >&2
  exit 1
fi

echo "==> Done. Layout under $DEST:"
find "$DEST" -name VERSION.txt | sort