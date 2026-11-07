#!/usr/bin/env bash
# Explicit live integration check. Supply a previously publisher-verified AGY release.
set -euo pipefail
[[ ${HCC_RUN_VENDOR_SMOKE:-0} == 1 ]] || { printf 'Live downloads require HCC_RUN_VENDOR_SMOKE=1\n' >&2; exit 64; }
: "${HCC_PREVIOUS_AGY_BINARY:?supply a previously verified AGY binary}"
: "${HCC_PREVIOUS_AGY_VERSION:?supply its exact version}"
: "${HCC_PREVIOUS_AGY_SHA256:?supply its verified SHA-256}"
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-real-update.XXXXXX")
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME"
printf 'Disposable managed-update evidence: %s\n' "$work"
bash "$repo/install.sh" --tool agy --yes --mode qemu --from-binary "$HCC_PREVIOUS_AGY_BINARY" \
 --version "$HCC_PREVIOUS_AGY_VERSION" --sha256 "$HCC_PREVIOUS_AGY_SHA256"
current="$HOME/.local/share/harness-cpu-compat/tools/agy/current"
previous=$(readlink "$current")
launcher=$(sha256sum "$HOME/.gemini/bin/agy")
alias=$(sha256sum "$HOME/.local/bin/agy")
timeout -k 2s 30s "$HOME/.gemini/bin/agy" --version
bash "$repo/install.sh" --tool agy --yes --mode qemu
[[ $(readlink "$current") != "$previous" ]] || { printf 'No newer release selected; this does not prove an upgrade.\n' >&2; exit 64; }
[[ $(sha256sum "$HOME/.gemini/bin/agy") == "$launcher" && $(sha256sum "$HOME/.local/bin/agy") == "$alias" ]]
[[ -x "$previous/binary" ]]
actual=$(sha256sum "$previous/binary"); [[ ${actual%% *} == "$HCC_PREVIOUS_AGY_SHA256" ]]
timeout -k 2s 30s "$HOME/.gemini/bin/agy" --version
timeout -k 2s 30s "$HOME/.gemini/bin/agy" --help > "$work/help.txt" 2>&1
bash "$repo/install.sh" --doctor --tool agy
bash "$repo/uninstall.sh" --tool agy --yes
printf 'PASS real AGY managed upgrade: verified new artifact selected, both wrappers unchanged, previous release retained, version/help pass.\n'
