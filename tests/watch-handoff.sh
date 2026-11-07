#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-handoff.XXXXXX")
pid=
cleanup() { touch "$work/release"; [[ -z "$pid" ]] || wait "$pid" || true; rm -rf -- "$work"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
for mode in watched ordinary; do
    wf_init "$work/$mode/fixture"
    binary="$work/$mode/fixture/original-binary"; qemu="$work/$mode/fixture/bin/qemu"
    digest=$(sha256sum < "$binary");digest=${digest%% *}
    if [[ "$mode" == ordinary ]]; then
        bash "$repo/install.sh" --tool agy --no-watch-agy --yes > /dev/null 2>&1
        export HOME="$work/$mode/home"; mkdir -p "$HOME"
        bash "$repo/install.sh" --tool agy --from-binary "$binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$qemu" --yes > "$work/$mode/initial.log" 2>&1
        root="$HOME/.local/share/harness-cpu-compat"
        [[ ! -e "$root/watch/owned" && ! -e "$HOME/.gemini/bin/.hcc-watch-owner" ]] || fail 'ordinary fixture unexpectedly owned a watcher'
    fi
    cat > "$work/$mode/fixture/bin/rm" <<'FIXTURE'
#!/usr/bin/env bash
if [[ ${HCC_HOLD_RESTORE:-0} == 1 ]]; then
 for arg; do
  if [[ "$arg" == "$HOME/.gemini/bin/agy" ]]; then
   touch "$HCC_RESTORE_READY"
   for ((i=0;i<600;i++)); do [[ -f "$HCC_RESTORE_RELEASE" ]] && break; sleep .02; done
  fi
 done
fi
exec /usr/bin/rm "$@"
FIXTURE
    chmod +x "$work/$mode/fixture/bin/rm"
    rm -f "$work/release"
    HCC_HOLD_RESTORE=1 HCC_RESTORE_READY="$work/$mode/ready" HCC_RESTORE_RELEASE="$work/release" bash "$repo/uninstall.sh" --tool agy --yes > "$work/$mode/uninstall.log" 2>&1 &
    pid=$!
    for ((i=0;i<250;i++)); do [[ -f "$work/$mode/ready" ]] && break; sleep .02; done
    [[ -f "$work/$mode/ready" ]] || fail 'uninstall did not reach restoration gate'
    set +e
    HCC_STATE_DIR="$HOME/plain-state" bash "$repo/install.sh" --tool agy --from-binary "$binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$qemu" --yes > "$work/$mode/plain-blocked.log" 2>&1
    plain=$?
    HCC_STATE_DIR="$HOME/second-state" bash "$repo/install.sh" --tool agy --from-binary "$binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$qemu" --watch-agy --yes > "$work/$mode/blocked.log" 2>&1
    second=$?
    touch "$work/release"
    wait "$pid"; first=$?
    pid=
    set -e
    [[ $plain != 0 && $second != 0 && $first == 0 && ! -e "$HOME/plain-state" && ! -e "$HOME/second-state" ]] || fail "global ownership was released before $mode entry restoration completed"
    [[ ! -e "$HOME/.gemini/bin/.hcc-watch-owner" && ! -e "$HOME/.gemini/bin/agy" && ! -L "$HOME/.gemini/bin/agy" && ! -e "$HOME/.local/bin/agy" ]] || fail 'completed uninstall retained reservation or entries'
    # A new root may take ownership only after restoration is complete.
    HCC_STATE_DIR="$HOME/second-state" bash "$repo/install.sh" --tool agy --from-binary "$binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$qemu" --watch-agy --yes > "$work/$mode/handoff.log" 2>&1
    [[ $(< "$HOME/.gemini/bin/.hcc-watch-owner") == "$HOME/second-state" && $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'completed uninstall stranded global ownership'
done
printf 'PASS watcher handoff: watched and ordinary uninstall retain global claim through restoration, then allow a new root\n'
