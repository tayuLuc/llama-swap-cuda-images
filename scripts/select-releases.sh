#!/usr/bin/env bash
# Resolve the newest release tag per fork for a mode.
#
# This is the single place tag selection happens. build-image.yml and
# fetch-binaries.sh both call it, so what the release notes claim and what the
# image actually downloads cannot drift apart.
#
# Usage: select-releases.sh <stable|nightly> <fork> [<fork>...]
# Output: one "<fork> <tag-or-empty>" line per fork, in the order given.
# Exit:   1 if any REQUIRED fork has no release for the mode, naming it.
#         Lanes in OPTIONAL_NIGHTLY (default: infernix) may be absent in
#         nightly mode: Infernix publishes no Linux releases, we build it from
#         source and tag it stable, so an <fork>-nightly-<sha> tag for it
#         cannot exist - demanding one made every nightly build die.
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

# Side channel for the build cache fingerprint. The stdout contract stays
# "<fork> <tag>" so fetch-binaries.sh keeps parsing it. Why the side channel is
# needed: the forks repo rebuilds the SAME commit (same tag, same fingerprint)
# and republishes the release with a DIFFERENT asset - measured 24.11, run 163
# republished infernix-f9c2e42cb3e9 (an ubuntu24.04 build, asset 569667644 B)
# over run 161's ffmpeg-8 build (asset 570635562 B) at the same tag. Run 303
# keyed its fetch layer on tags.txt only, hit the buildx cache and shipped the
# old asset while its own ABI gate ran on cached layers. Asset id and size make
# the cache die when upstream content moves under an unchanged tag.
ASSET_LINES=""
if [ -n "${SELECT_ASSETS_FILE:-}" ]; then
  : > "$SELECT_ASSETS_FILE"
fi
emit_assets() {
  # $1 = fork; the asset lines are taken from the release this selection picked,
  # i.e. the newest release of the mode, which is exactly what the `tag` below
  # resolves to. Keeping the lookup on published_at (not on the tag string)
  # avoids re-implementing the tag regex a second time here.
  [ -n "${SELECT_ASSETS_FILE:-}" ] && [ -n "$1" ] || return 0
  echo "$rels_json" | jq -r --arg f "$1" --arg nightly "$MODE" '
      (if $nightly == "nightly"
       then ([ .[] | select(.tag_name | test("^"+$f+"-nightly-[0-9a-f]+$")) ])
       else ([ .[] | select(.tag_name | test("^"+$f+"-")) | select(.tag_name | test("nightly") | not) ])
       end)
      | sort_by(.published_at) | (last // empty) | .assets[]?
      | "\($f) \(.id) \(.size) \(.updated_at)"' >> "$SELECT_ASSETS_FILE"
}

# Lanes that are optional in nightly mode (space separated, env-overridable).
OPTIONAL_NIGHTLY="${OPTIONAL_NIGHTLY:-infernix}"

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
  # Required count: in nightly mode optional lanes do not count towards the
  # "every fork is visible" stop condition, they can never become visible.
  required=$(printf '%s\n' $FORKS | jq -Rs --arg opt "$OPTIONAL_NIGHTLY" --arg mode "$MODE" '
    split("\n") | map(select(length > 0)) as $fs | ($opt | split(" ")) as $o
    | (if $mode == "nightly" then ($fs | map(select(. as $f | $o | index($f) | not))) else $fs end)
    | length')
  [ "$found" -ge "$required" ] && break
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
  emit_assets "$fork"
  [ -n "$tag" ] && continue
  if [ "$MODE" = "nightly" ]; then
    case " $OPTIONAL_NIGHTLY " in *" $fork "*)
      echo "   $fork: no nightly tag (optional lane in nightly mode)" >&2
      continue ;;
    esac
  fi
  status=1
done

# A quiet skip used to ship an image missing a whole backend: the Dockerfile
# COPYs every fork, so the build died later on a missing path instead of naming
# the release that was absent.
exit "$status"