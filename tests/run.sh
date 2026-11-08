#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
export TMPDIR=${TMPDIR:-${RUNNER_TEMP:-$HOME/.cache/harness-cpu-compat-tests}}
mkdir -p -- "$TMPDIR"
for source in "$repo/install.sh" "$repo/uninstall.sh" "$repo"/lib/*.sh "$repo"/tests/*.sh; do bash -n "$source"; done
for suite in runtime lifecycle robustness distribution safety transactions paths hash-paths watch-management watch-repair watch-races watch-owners watch-validation watch-lifecycle watch-handoff watch-first-install bootstrap qemu-install native-uninstall native-uninstall-faults uninstall-cleanup; do bash "$repo/tests/$suite.sh"; done
printf 'PASS all offline suites\n'
