#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-uninstall-cleanup.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
printf '#!/bin/bash\ncase "$1" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/binary"
chmod +x "$work/binary"
digest=$(sha256sum < "$work/binary"); digest=${digest%% *}
for scenario in symlink-watch dangling-pending top-level-canary program-canary; do
    export HOME="$work/$scenario"
    unset XDG_DATA_HOME XDG_CONFIG_HOME HCC_STATE_DIR
    mkdir -p "$HOME"
    bash "$repo/install.sh" --tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --mode native --yes > "$work/install.log" 2>&1
    root="$HOME/.local/share/harness-cpu-compat"
    if [[ "$scenario" == dangling-pending ]]; then
        mkdir "$root/watch"
        ln -s "$HOME/missing-journal" "$root/watch/pending"
        if bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1; then fail 'dangling pending journal accepted'; fi
        [[ -L "$root/tools/claude/current" ]] || fail 'dangling pending journal allowed mutation'
        continue
    fi
    if [[ "$scenario" == symlink-watch ]]; then
        mkdir "$HOME/foreign-watch"
        printf 'foreign-lock-canary' > "$HOME/foreign-watch/management.lock"
        ln -s "$HOME/foreign-watch" "$root/watch"
        if bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1; then fail 'unsafe watch parent accepted'; fi
        [[ -f "$HOME/foreign-watch/management.lock" ]] || fail 'unsafe watch parent deleted a foreign lock'
        [[ $(< "$HOME/foreign-watch/management.lock") == foreign-lock-canary && -L "$root/tools/claude/current" ]] || fail 'unsafe watch parent mutated state'
    else
        canary="$root/user-note"
        [[ "$scenario" != program-canary ]] || canary="$root/program/user-note"
        printf 'unrelated-canary' > "$canary"
        bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1 || { cat "$work/uninstall.log"; fail 'canary-preserving native handoff failed'; }
        [[ -f "$canary" && $(< "$canary") == unrelated-canary ]] || fail 'unrecognized file deleted'
        [[ ! -e "$root/operation.lock" && ! -e "$root/watch/management.lock" ]] || fail 'canary retained inert locks'
        [[ $("$HOME/.local/bin/claude" --version) == 1.0.0 ]] || fail 'canary preservation broke native handoff'
    fi
done
printf 'PASS final cleanup: symlink-parent refusal, unrelated root/program file preservation and no inert locks\n'
