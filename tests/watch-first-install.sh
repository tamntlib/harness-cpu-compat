#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-first.XXXXXX")
basepath=$PATH
installer=; uninstaller=
cleanup() {
    for mode in ordinary watched; do [[ ! -d "$work/$mode" ]] || touch "$work/$mode/install-release" "$work/$mode/restore-release"; done
    [[ -z "$installer" ]] || wait "$installer" || true
    [[ -z "$uninstaller" ]] || wait "$uninstaller" || true
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for mode in ordinary watched; do
    export HOME="$work/$mode/home" HCC_GATE="$work/$mode"
    unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME HCC_STATE_DIR
    mkdir -p "$HOME" "$HCC_GATE/bin"
    export PATH="$HCC_GATE/bin:$basepath"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$HCC_GATE/binary"
    cat > "$HCC_GATE/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
if [[ ${HCC_HOLD_INSTALL:-0} == 1 && ${!#} == "$HOME/.gemini/bin/agy" ]]; then
 touch "$HCC_GATE/install-ready"
 for ((i=0;i<1000;i++)); do [[ -f "$HCC_GATE/install-release" ]] && break; sleep .01; done
fi
exec /usr/bin/mv "$@"
FIXTURE
    cat > "$HCC_GATE/bin/flock" <<'FIXTURE'
#!/usr/bin/env bash
[[ ${HCC_IS_UNINSTALL:-0} != 1 ]] || touch "$HCC_GATE/uninstall-at-lock"
exec /usr/bin/flock "$@"
FIXTURE
    cat > "$HCC_GATE/bin/rm" <<'FIXTURE'
#!/usr/bin/env bash
if [[ ${HCC_IS_UNINSTALL:-0} == 1 ]]; then
 for arg; do
  if [[ "$arg" == "$HOME/.gemini/bin/agy" ]]; then
   touch "$HCC_GATE/restore-ready"
   for ((i=0;i<1000;i++)); do [[ -f "$HCC_GATE/restore-release" ]] && break; sleep .01; done
  fi
 done
fi
exec /usr/bin/rm "$@"
FIXTURE
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$HCC_GATE/manager.log"\n' > "$HCC_GATE/bin/systemctl"
    chmod +x "$HCC_GATE/binary" "$HCC_GATE/bin/"*
    digest=$(sha256sum < "$HCC_GATE/binary"); digest=${digest%% *}
    args=(--tool agy --from-binary "$HCC_GATE/binary" --version 1.0.0 --sha256 "$digest" --mode native --yes)
    watch=(); [[ "$mode" != watched ]] || watch=(--watch-agy)
    HCC_HOLD_INSTALL=1 bash "$repo/install.sh" "${args[@]}" "${watch[@]}" > "$HCC_GATE/install.log" 2>&1 & installer=$!
    for ((i=0;i<500;i++)); do [[ -f "$HCC_GATE/install-ready" ]] && break; sleep .01; done
    [[ -f "$HCC_GATE/install-ready" ]] || fail 'first install did not reach publication gate'
    root="$HOME/.local/share/harness-cpu-compat"
    [[ ! -e "$root/tools/agy/installed" && ! -e "$root/watch/owned" ]] || fail 'fixture is not a first install'
    HCC_IS_UNINSTALL=1 bash "$repo/uninstall.sh" --tool agy --yes > "$HCC_GATE/uninstall.log" 2>&1 & uninstaller=$!
    for ((i=0;i<500;i++)); do [[ -f "$HCC_GATE/uninstall-at-lock" ]] && break; sleep .01; done
    [[ -f "$HCC_GATE/uninstall-at-lock" ]] || fail 'uninstall did not reach a lock'
    touch "$HCC_GATE/install-release"
    wait "$installer"; installer=
    for ((i=0;i<500;i++)); do [[ -f "$HCC_GATE/restore-ready" ]] && break; sleep .01; done
    [[ -f "$HCC_GATE/restore-ready" ]] || fail 'uninstall did not re-evaluate the completed install'
    second=1
    if [[ "$mode" == ordinary ]]; then
        set +e
        HCC_STATE_DIR="$HOME/second-state" bash "$repo/install.sh" "${args[@]}" --watch-agy > "$HCC_GATE/second-install.log" 2>&1
        second=$?
        set -e
    fi
    touch "$HCC_GATE/restore-release"
    wait "$uninstaller"; uninstaller=
    [[ $second != 0 && ! -e "$root/watch/enabled" && ! -e "$HOME/.gemini/bin/.hcc-watch-owner" ]] || fail "first $mode install let uninstall bypass ownership or watcher shutdown"
    [[ ! -e "$HOME/.gemini/bin/agy" && ! -L "$HOME/.gemini/bin/agy" && ! -e "$HOME/.local/bin/agy" && ! -L "$HOME/.local/bin/agy" ]] || fail 'restoration did not complete'
done
printf 'PASS first-install concurrency: uninstall re-evaluates eligibility under management lock, retains ownership and disables newly enabled watcher\n'
