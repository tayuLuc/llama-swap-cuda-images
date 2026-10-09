#!/usr/bin/env bash
# Keep only the newest N audit releases per mode; delete the rest.
#
# Usage: prune-releases.sh [--apply] [N_STABLE [N_NIGHTLY]]
#   default: dry run. Nothing is deleted without --apply.
#   default N_STABLE=1, N_NIGHTLY=1.
#
# Unlike the source repo, these releases carry NO assets: they are audit
# records ("which fork tags got packed, under which image tag"). Verified: 0 of
# the 100 most recent have a single asset. The buildable artifacts live in
# ghcr.io under the moving `stable`/`nightly` aliases, so deleting an old audit
# release loses no downloadable output - only the running record.
#
# The tag embeds the run id (nightly-20261009-37892188710), so every run mints a
# new release even when the image is byte-identical. That is what produced two
# releases a day: the 00:17 schedule plus the trigger-swap dispatch.
#
# Deletes the git tag alongside the release, otherwise the tag list keeps
# growing even after the release list is clean.
set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
N_STABLE="${1:-1}"
N_NIGHTLY="${2:-1}"

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "!! need GH_TOKEN/GITHUB_TOKEN" >&2; exit 1; }
AUTH=(-H "Authorization: token $TOKEN")
REPO="${SRC_REPO:-tayuLuc/llama-swap-cuda-images}"

alls=()
for page in 1 2 3 4 5 6 7 8 9 10; do
  chunk=$(curl -s "${AUTH[@]}" \
    "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}")
  echo "$chunk" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "!! page ${page}: GitHub did not return an array (rate limit?)" >&2
    exit 1
  }
  n=$(echo "$chunk" | jq 'length')
  [ "$n" -eq 0 ] && break
  alls+=("$chunk")
  [ "$n" -lt 100 ] && break
done
rels=$(printf '%s\n' "${alls[@]}" | jq -s 'add')

echo "==> loaded $(echo "$rels" | jq 'length') releases from ${REPO}"
echo "==> policy: keep ${N_STABLE} stable + ${N_NIGHTLY} nightly"

total=0
for mode in stable nightly; do
  if [ "$mode" = "stable" ]; then keep="$N_STABLE"; else keep="$N_NIGHTLY"; fi
  tags=""
  ntags=0
  # test(), not a bare string: select() treats any non-empty string as true, so a
  # literal ("^"+$m+"-") matched every release. Keep this comment OUTSIDE the
  # command substitution - a comment between the line continuation and the jq
  # program swallows the program, and jq then falls back to `.` and prints the
  # whole array as one blob.
  jqprog='[ .[] | select(.tag_name | test("^"+$m+"-")) ] | sort_by(.published_at) | reverse | .[] | .tag_name'
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    tags="${tags}${t}
"
    ntags=$((ntags + 1))
  done < <(echo "$rels" | jq -r --arg m "$mode" "$jqprog")
  [ "$ntags" -eq 0 ] && continue
  drop=$(( ntags > keep ? ntags - keep : 0 ))
  if [ "$drop" -eq 0 ]; then
    echo "  ${mode}: ${ntags} всего, ничего не трогаем"
    continue
  fi
  echo "  ${mode}: ${ntags} всего, оставляем ${keep}, удаляем ${drop}"
  # Herestring, not a pipe: a piped while runs in a subshell and the counter
  # below is lost, which reports "deleted 0" after deleting everything.
  i=0
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    i=$((i + 1))
    [ "$i" -le "$keep" ] && continue
    if [ "$APPLY" -eq 1 ]; then
      echo "      - $tag  удаляю"
      gh release delete "$tag" --repo "$REPO" --yes >/dev/null 2>&1
      gh api -X DELETE "/repos/${REPO}/git/refs/tags/${tag}" >/dev/null 2>&1 || true
      total=$((total + 1))
    else
      echo "      - $tag  (был бы удалён)"
      total=$((total + 1))
    fi
  done <<< "$tags"
done

if [ "$APPLY" -eq 0 ]; then
  echo "==> СУХОЙ ПРОГОН: ничего не удалено. Повторить с --apply, чтобы выполнить."
else
  echo "==> удалено релизов: $total"
fi