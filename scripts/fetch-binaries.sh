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

MODE="${1:?usage: fetch-binaries.sh <stable|nightly|--print-lanes> <dest>}"
DEST="${2:-}"
SRC_REPO="${SRC_REPO:-tayuLuc/yet-another-llama.cpp-cuda-fork}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# name|asset regex|required binaries[|repo][|strip-components][|required files]
# The forks all ship llama-server. imp is a separate engine and ships
# imp-server/imp-cli under a differently named asset. basalt ships a whole tree
# (bin/ serve/ tools/ data/ docs/ requirements.txt) under a versioned top
# directory, from its own repo - hence the strip and repo fields.
BACKENDS='vanilla|llama\.cpp.*vanilla.*amd64\.tar\.gz$|llama-server
turboquant|llama\.cpp.*turboquant.*amd64\.tar\.gz$|llama-server
prism|llama\.cpp.*prism.*amd64\.tar\.gz$|llama-server
atomic|llama\.cpp.*atomic.*amd64\.tar\.gz$|llama-server
imp|imp-cuda13\.4-imp-[a-z]+-amd64\.tar\.gz$|imp-server
infernix|infernix-cuda-13\.[0-9]+-infernix-stable-amd64\.tar\.gz$|infernix infernix-serve
basalt|basalt-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz$|bin/basalt bin/basalt-vision|jesdga95/basalt|1|requirements.txt'

NAMES=$(printf '%s\n' "$BACKENDS" | awk -F'|' '{ if ($4 != "") print $1"@"$4; else print $1 }')

# Single source of truth for the lane list: the workflow's tags step asks this
# script instead of keeping its own copy (a repo rename edited one list and the
# fingerprint and the download drifted - the comment in build-image.yml).
if [ "$MODE" = "--print-lanes" ]; then
  echo "$NAMES"
  exit 0
fi
[ -n "$DEST" ] || { echo "usage: fetch-binaries.sh <stable|nightly> <dest>" >&2; exit 2; }

mkdir -p "$DEST"

echo "==> Fetching mode=$MODE binaries for: $(echo "$NAMES" | tr '\n' ' ')"

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
# ${AUTH[@]+"${AUTH[@]}"}: an empty array under set -u is an unbound variable on
# bash 3.2 (the macOS shell our probes run) - expand defensively.
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")

# Resolve every backend's tag in one pass; a missing one fails the whole run
# rather than shipping an image that is quietly one backend short. Exception:
# lanes listed in OPTIONAL_NIGHTLY (select-releases.sh) may be absent in nightly
# mode, and get an empty directory below so the Dockerfile COPY still resolves.
selected=$("$HERE/select-releases.sh" "$MODE" $NAMES) || {
  echo "!! FAILED: at least one required backend has no $MODE release" >&2
  exit 1
}

# Asset URLs come from the release list of each lane's repo, cached per repo in
# $tmprels. Page 1 holds the tags select-releases.sh picked for the forks repo
# (it walks pages until every backend is visible, newest-first); cross-repo lanes
# are selected from their newest non-prerelease, which is on page 1 of their
# repo - the page walk here is the safety net, not the selector.
tmprels=$(mktemp -d)
trap 'rm -rf "$tmprels"' EXIT
rels_for() {
  local key
  key=$(echo "$1" | tr '/@' '__')
  if [ ! -s "$tmprels/$key" ]; then
    local out="[]" page n
    # 10 pages, mirroring select-releases.sh: a selector that walks to page N
    # must never pick a tag the fetcher is too short-sighted to find - the
    # "No matching asset" red lands on a tag the build was told to pack.
    for page in 1 2 3 4 5 6 7 8 9 10; do
      local chunk
      chunk=$(curl -s "${AUTH[@]+"${AUTH[@]}"}" "https://api.github.com/repos/${1}/releases?per_page=100&page=${page}")
      # An unauthenticated rate-limit reply is a JSON object and jq 'length'
      # counts its keys as releases - the class select-releases.sh carries a
      # guard for. Die naming the class; never count keys.
      if ! echo "$chunk" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "!! $1: page ${page}: GitHub did not return an array (rate limit or auth?)" >&2
        exit 1
      fi
      n=$(echo "$chunk" | jq 'length')
      [ "$n" -eq 0 ] && break
      out=$(jq -s 'add' <<<"$out$(printf '%s\n' "$chunk")")
      [ "$n" -lt 100 ] && break
    done
    echo "$out" > "$tmprels/$key"
  fi
  cat "$tmprels/$key"
}

missing=""
while IFS=' ' read -r name tag; do
  [ -n "$name" ] || continue
  lane="${name%%@*}"
  if [ -z "$tag" ]; then
    # An optional lane with no tag in this mode: ship the image without it and
    # leave an empty directory, so COPY resolves and the runtime slot for that
    # engine is the thing that is missing - named in this line, not in a build
    # that died on a path.
    echo "-> $lane: no $MODE release, optional lane, shipping image without it"
    mkdir -p "$DEST/$lane"
    # The basalt venv stage COPYes requirements.txt unconditionally, so a fully
    # empty lane dir fails that COPY (and the build) in nightly. The stub keeps
    # the dir non-empty - a 0-byte requirements builds an empty venv, and the
    # basalt gate skips on the missing binary. The dir must also be dereferencable
    # by the final-stage symlink; the RUN mkdir -p there is the primary fix,
    # this stub is the belt.
    [ "$lane" = "basalt" ] && : > "$DEST/$lane/requirements.txt"
    continue
  fi

  row=$(printf '%s\n' "$BACKENDS" | grep "^${lane}|" || true)
  pattern=$(printf '%s' "$row" | cut -d'|' -f2)
  want_bins=$(printf '%s' "$row" | cut -d'|' -f3)
  lane_repo=$(printf '%s' "$row" | cut -d'|' -f4)
  strip=$(printf '%s' "$row" | cut -d'|' -f5)
  want_files=$(printf '%s' "$row" | cut -d'|' -f6)
  [ -n "$lane_repo" ] || lane_repo="$SRC_REPO"

  url=$(rels_for "$lane_repo" | jq -r --arg t "$tag" --arg p "$pattern" \
    '.[] | select(.tag_name==$t) | .assets[] | select(.name|test($p)) | .browser_download_url' | head -1)

  if [ -z "$url" ]; then
    echo "!! No matching asset for $lane at tag=$tag ($lane_repo)" >&2
    missing="$missing $lane"
    continue
  fi

  echo "-> $lane: $tag ($lane_repo)"
  tmp="/tmp/${lane}.tar.gz"
  # -f: without it curl writes an error page into the tarball and the failure
  # surfaces at tar, one backend later than it should.
  curl -sfL "${AUTH[@]+"${AUTH[@]}"}" "$url" -o "$tmp"
  if [ -n "$strip" ]; then
    # basalt packs a versioned top directory (basalt-v0.5.7-linux-x64/); the
    # image path /opt/llama/basalt is its archive root, so flatten one level.
    mkdir -p "$DEST/$lane"
    tar -xzf "$tmp" -C "$DEST/$lane" --strip-components="$strip"
  else
    tar -xzf "$tmp" -C "$DEST/"
  fi
  rm -f "$tmp"

  # Verify the result, not the download: a truncated tarball used to pass here
  # and fail later in the Dockerfile on a missing COPY path.
  for b in ${want_bins//,/ }; do
    if [ ! -x "$DEST/$lane/$b" ]; then
      echo "!! $lane: $tag unpacked without $b" >&2
      missing="$missing $lane"
    fi
  done
  # requirements.txt feeds the venv stage in the Dockerfile; a tree without it
  # fails there as a cryptic uv error, name it here.
  for f in $want_files; do
    if [ ! -f "$DEST/$lane/$f" ]; then
      echo "!! $lane: $tag unpacked without $f" >&2
      missing="$missing $lane"
    fi
  done
done <<< "$selected"

if [ -n "$missing" ]; then
  echo "!! FAILED: no usable binaries for:$missing (mode=$MODE)" >&2
  exit 1
fi

echo "==> Done. Layout under $DEST:"
find "$DEST" -name VERSION.txt | sort