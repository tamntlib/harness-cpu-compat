#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-hash-paths.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
source "$repo/lib/common.sh"
file="$work/back\\slash"
printf 'content\n' > "$file"
expected=$(sha256sum < "$file");expected=${expected%% *}
[[ $(hcc_hash "$file") == "$expected" ]] || { printf 'FAIL: path escaping contaminated the artifact digest\n' >&2; exit 1; }
printf 'PASS hash paths: SHA-256 output independent of filename escaping\n'
