#!/usr/bin/env bash
# Resolve the newest release tag per fork for a mode.
#
# This is the single place tag selection happens. build-image.yml and
# fetch-binaries.sh both call it, so what the release notes claim and what the
# image actually downloads cannot drift apart.
#
# Usage: select-releases.sh <stable|nightly> <fork> [<fork>...]
# Output: one "<fork> <tag-or-empty>" line per fork, in the order given.
# Exit:   1 if any fork has no release for the mode, naming it.
#
# Why pagination is required: GitHub orders /releases by created_at, and this
# source repo creates every tag in one batch, so page 1 holds only stable tags -
# 0 nightly and 0 atomic out of 100. A single page silently dropped the nightly
# mode entirely and the atomic fork, which then skipped quietly.
set -euo pipefail

MODE="${1:?usage: select-releases.sh <stable|nightly> <fork>...}"
shift
FORKS="$*"
[ -n "$FORKS" ] || { echo "!! no forks given" >&2; exit 1; }

# GitHub Actions already exports GITHUB_TOKEN, so CI needs no secret wired up;
# GH_TOKEN is accepted so a local run can reuse `gh auth token`.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")
if [ -z "$TOKEN" ]; then
  echo "!! no token: unauthenticated API allows 60 requests/hour per IP," >&2
  echo "!! and CI runners share IP ranges. Set GITHUB_TOKEN in the workflow." >&2
fi

SRC_REPO="${SRC_REPO:-tayuLuc/yet-another-llama.cpp-cuda-fork}"

fetch_page() {
  curl -s "${AUTH[@]}" "https://api.github.com/repos/${SRC_REPO}/releases?per_page=100&page=$1"
}

alls=()
for page in 1 2 3 4 5 6 7 8 9 10; do
  chunk=$(fetch_page "$page")
  # An unauthenticated rate-limit reply is a JSON object, not an array; counting
  # its keys reported "Loaded 2 releases" and still continued. Fail here.
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
  # Stop once every requested fork has a release of THIS mode. Counting prefixes
  # without the mode is wrong: in the first 200 releases only vanilla and
  # turboquant have nightlies, prism and atomic appear on page 3.
  found=$(printf '%s\n' "${alls[@]}" | jq -s -r --arg forks "$FORKS" --arg nightly "$MODE" '
    add | [.[].tag_name] as $tags
    | ($forks | split(" ")) as $fs
    | [ $fs[] | . as $f
        | (if $nightly == "nightly"
           then ([ $tags[] | select(test("^"+$f+"-nightly-[0-9a-f]+$"))] | length)
           else ([ $tags[] | select(test("^"+$f+"-")) | select(test("nightly") | not)] | length)
           end) ] | map(select(. > 0)) | length')
  [ "$found" -ge "$(echo "$FORKS" | wc -w)" ] && break
done

rels_json=$(printf '%s\n' "${alls[@]}" | jq -s 'add')

status=0
for fork in $FORKS; do
  if [ "$MODE" = "nightly" ]; then
    tag=$(echo "$rels_json" | jq -r --arg f "$fork" \
      '[.[] | select(.tag_name | test("^"+$f+"-nightly-[0-9a-f]+$"))]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  else
    tag=$(echo "$rels_json" | jq -r --arg f "$fork" \
      '[.[] | select(.tag_name | test("^"+$f+"-")) | select(.tag_name | test("nightly") | not)]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  fi
  echo "$fork ${tag:-}"
  [ -n "$tag" ] || status=1
done

# A quiet skip used to ship an image missing a whole backend: the Dockerfile
# COPYs every fork, so the build died later on a missing path instead of naming
# the release that was absent.
exit "$status"