#!/usr/bin/env bash
# Resolve the newest release tag per fork for a mode.
#
# This is the single place tag selection happens. build-image.yml and
# fetch-binaries.sh both call it, so what the release notes claim and what the
# image actually downloads cannot drift apart.
#
# Usage: select-releases.sh <stable|nightly> <fork> [<fork>...]
# A lane may be "<name>@<owner>/<repo>": releases are then selected from that
# repo's latest non-prerelase (basalt ships v0.5.7-style tags from its own repo,
# the forks repo tags are "<fork>-<sha>" batches). Cross-repo lanes have no
# nightly concept: like OPTIONAL_NIGHTLY lanes, they are skipped in nightly mode.
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
  # $1 = lane; $2 = repo whose release list the asset lines come from (default
  # SRC_REPO). The asset lines are taken from the release this selection picked,
  # i.e. the newest release of the mode, which is exactly what the `tag` below
  # resolves to. Keeping the lookup on published_at (not on the tag string)
  # avoids re-implementing the tag regex a second time here.
  [ -n "${SELECT_ASSETS_FILE:-}" ] && [ -n "$1" ] || return 0
  local repo="${2:-$SRC_REPO}"
  # Local on purpose: the main loop keeps the forks-repo list in the global
  # rels_json; clobbering it from here would poison the next lane's selection.
  local rels_json
  rels_json=$(rels_of "$repo")
  echo "$rels_json" | jq -r --arg f "$1" --arg nightly "$MODE" '
      (if $nightly == "nightly"
       then ([ .[] | select(.tag_name | test("^"+$f+"-nightly-[0-9a-f]+$")) ])
       else ([ .[] | select(.tag_name | test("^"+$f+"-")) | select(.tag_name | test("nightly") | not) | select(.prerelease | not) ])
       end)
      | sort_by(.published_at) | (last // empty) | .assets[]?
      | "\($f) \(.id) \(.size) \(.updated_at)"' >> "$SELECT_ASSETS_FILE"
  # Cross-repo lanes carry plain version tags (v0.5.7), not "<lane>-..." tags:
  # the fork-prefix regex above matches nothing, select them by recency instead.
  case "$repo" in
    "$SRC_REPO") ;;
    *)
      echo "$rels_json" | jq -r --arg f "$1" --arg asset_pat "$ASSET_PAT_CROSS" '
        [ .[] | select(.prerelease | not)
          | select(.tag_name | test("-(nightly|rc|alpha|beta)[0-9.]*$"; "i") | not)
          | select(.assets | any(.name | test($asset_pat))) ]
        | sort_by(.published_at) | (last // empty) | .assets[]?
        | "\($f) \(.id) \(.size) \(.updated_at)"' >> "$SELECT_ASSETS_FILE"
      ;;
  esac
}

# Lanes that are optional in nightly mode (space separated, env-overridable).
OPTIONAL_NIGHTLY="${OPTIONAL_NIGHTLY:-infernix}"

# GitHub Actions already exports GITHUB_TOKEN, so CI needs no secret wired up;
# GH_TOKEN is accepted so a local run can reuse `gh auth token`.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
AUTH=()
# ${AUTH[@]+"${AUTH[@]}"}: an empty array under set -u is an unbound variable on
# bash 3.2 (the macOS shell our probes run) - expand defensively.
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")
if [ -z "$TOKEN" ]; then
  echo "!! no token: unauthenticated API allows 60 requests/hour per IP," >&2
  echo "!! and CI runners share IP ranges. Set GITHUB_TOKEN in the workflow." >&2
fi

SRC_REPO="${SRC_REPO:-tayuLuc/yet-another-llama.cpp-cuda-fork}"
# Loose asset predicate shared between selection and the fetch regex: an
# upstream packaging rename must fail at selection (tag not found = loud),
# not between tag and download (tag green, asset missing = red build, late).
ASSET_PAT_CROSS="${ASSET_PAT_CROSS:-linux-x64\.tar\.gz$}"

# Releases for one repo, cached across the run (cross-repo lanes re-read them).
RELS_CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$RELS_CACHE_DIR"' EXIT
rels_of() {
  local key cache
  key=$(echo "$1" | tr '/@' '__')
  cache="$RELS_CACHE_DIR/$key.json"
  [ -s "$cache" ] || fetch_all_pages "$1" > "$cache"
  cat "$cache"
}

# All pages of a repo's release list. The forks repo needs page walking (tags are
# created in batches, page 1 = stable only - see header); a small cross-repo lane
# is covered by its first pages too, and the walk stops on a short page.
fetch_all_pages() {
  local repo="$1" page chunk n
  local out="[]"
  for page in 1 2 3 4 5 6 7 8 9 10; do
    chunk=$(curl -s "${AUTH[@]+"${AUTH[@]}"}" "https://api.github.com/repos/${repo}/releases?per_page=100&page=$page")
    if ! echo "$chunk" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "!! ${repo}: page ${page}: GitHub did not return an array (rate limit or auth?)" >&2
      echo "$chunk" | head -c 200 >&2
      echo >&2
      exit 1
    fi
    n=$(echo "$chunk" | jq 'length')
    [ "$n" -eq 0 ] && break
    # Hard-fail: keeping the old accumulation on a jq error silently drops a
    # page from the dataset the asset fingerprint is computed from - tags.txt
    # would name a tag whose asset ids are absent, a stale cache key in the
    # run 163/303 shape. set -e killing the run names the real problem.
    out=$(jq -s 'add' <<<"$out$(printf '%s\n' "$chunk")")
    [ "$n" -lt 100 ] && break
  done
  echo "$out"
}

fetch_page() {
  curl -s "${AUTH[@]+"${AUTH[@]}"}" "https://api.github.com/repos/${SRC_REPO}/releases?per_page=100&page=$1"
}

alls=()
# Full walk of up to 10 pages, no early stop. The stop condition this replaces
# counted ANY lane release as visible: a prerelease on page 1 satisfied it, the
# main loop (which filters prereleases) then found no tag and died status=1
# while a real release sat on page 2; a lane whose newest release published on
# a later page got the stale older tag - the run 163 class. Ten GETs per build
# against an authenticated 5000/h budget is the cheap cure.
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
done

# Cross-repo-only invocations never page the forks repo: alls stays empty, and
# "${alls[@]}" under set -u dies on bash 3.2 (local probes) - expand defensively.
rels_json=$(printf '%s\n' "${alls[@]+"${alls[@]}"}" | jq -s 'add // []')

status=0
for fork in $FORKS; do
  lane="${fork%%@*}"
  repo="$SRC_REPO"
  [ "$fork" != "$lane" ] && repo="${fork#*@}"

  if [ "$repo" != "$SRC_REPO" ]; then
    # Cross-repo lane (basalt): their own release train, plain v-tags, no
    # nightly concept - the newest non-prerelease release is the contract.
    # Nightly mode: the author's prebuilt archive lags their branch HEADs
    # anyway, and demanding a nightly tag would kill every nightly build
    # (the infernix lesson) - image ships without the lane, named on stdout.
    if [ "$MODE" = "nightly" ]; then
      echo "   $lane: cross-repo lane, no nightly releases (optional, image ships without it)" >&2
      echo "$lane "
      continue
    fi
    tag=$(rels_of "$repo" | jq -r --arg asset_pat "$ASSET_PAT_CROSS" '
      [ .[] | select(.prerelease | not)
        | select(.tag_name | test("-(nightly|rc|alpha|beta)[0-9.]*$"; "i") | not)
        | select(.assets | any(.name | test($asset_pat))) ]
      | sort_by(.published_at) | (last // empty) | .tag_name')
  elif [ "$MODE" = "nightly" ]; then
    tag=$(echo "$rels_json" | jq -r --arg f "$lane" \
      '[.[] | select(.tag_name | test("^"+$f+"-nightly-[0-9a-f]+$"))]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  else
    tag=$(echo "$rels_json" | jq -r --arg f "$lane" \
      '[.[] | select(.tag_name | test("^"+$f+"-")) | select(.tag_name | test("nightly") | not) | select(.prerelease | not)]
       | sort_by(.published_at) | .[-1].tag_name // empty')
  fi
  echo "$lane ${tag:-}"
  emit_assets "$lane" "$repo"
  [ -n "$tag" ] && continue
  if [ "$MODE" = "nightly" ]; then
    case " $OPTIONAL_NIGHTLY " in *" $lane "*)
      echo "   $lane: no nightly tag (optional lane in nightly mode)" >&2
      continue ;;
    esac
  fi
  status=1
done

# A quiet skip used to ship an image missing a whole backend: the Dockerfile
# COPYs every fork, so the build died later on a missing path instead of naming
# the release that was absent.
exit "$status"