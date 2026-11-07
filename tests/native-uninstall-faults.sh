#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-native-faults.XXXXXX")
trap 'exec 7>&-; rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
basepath=$PATH
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME HCC_STATE_DIR
for fault in copy-fail copy-short before-capture link-file link-directory link-symlink alias-link killed-capture open-writer; do
    export HOME="$work/$fault/home" HCC_NATIVE_FAULT=$fault HCC_NATIVE_MARKER="$work/$fault/injected"
    mkdir -p "$HOME" "$work/$fault/bin"
    printf '#!/bin/bash\n[[ "$1" == -cpu && "$2" == max ]] || exit 90\nshift 2; exec "$@"\n' > "$work/$fault/qemu"
    printf '#!/bin/bash\ncase "$1" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/$fault/app"
    chmod +x "$work/$fault/qemu" "$work/$fault/app"
    digest=$(sha256sum < "$work/$fault/app"); digest=${digest%% *}
    PATH="$basepath" bash "$repo/install.sh" --tool agy --from-binary "$work/$fault/app" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/$fault/qemu" --yes > "$work/$fault/install.log" 2>&1
    root="$HOME/.local/share/harness-cpu-compat"
    selected=$(readlink "$root/tools/agy/current")
    primary_before=$(sha256sum < "$HOME/.gemini/bin/agy")
    alias_before=$(sha256sum < "$HOME/.local/bin/agy")
    if [[ "$fault" == open-writer ]]; then exec 7<> "$HOME/.gemini/bin/agy"; fi
    cat > "$work/$fault/bin/cp" <<'FIXTURE'
#!/bin/bash
if [[ ${!#} == *'/prepared' && "$HCC_NATIVE_FAULT" == copy-* ]]; then
    touch "$HCC_NATIVE_MARKER"; printf short > "${!#}"
    [[ "$HCC_NATIVE_FAULT" == copy-short ]] && exit 0
    exit 18
fi
exec /usr/bin/cp "$@"
FIXTURE
    cat > "$work/$fault/bin/mv" <<'FIXTURE'
#!/bin/bash
if [[ ${!#} == *'/captured' && "$PWD" == "$HOME/.gemini/bin" && ! -e "$HCC_NATIVE_MARKER" ]]; then
    case "$HCC_NATIVE_FAULT" in
      before-capture) touch "$HCC_NATIVE_MARKER"; printf foreign > "$HOME/.gemini/bin/agy";;
      killed-capture) /usr/bin/mv "$@"; touch "$HCC_NATIVE_MARKER"; kill -KILL "$PPID"; exit 99;;
    esac
fi
exec /usr/bin/mv "$@"
FIXTURE
    cat > "$work/$fault/bin/ln" <<'FIXTURE'
#!/bin/bash
previous=${@: -2:1}
if [[ "$previous" == *'/prepared' && ! -e "$HCC_NATIVE_MARKER" ]]; then
    case "$HCC_NATIVE_FAULT:$PWD" in
      link-file:"$HOME/.gemini/bin") touch "$HCC_NATIVE_MARKER"; printf foreign > "$HOME/.gemini/bin/agy";;
      link-directory:"$HOME/.gemini/bin") touch "$HCC_NATIVE_MARKER"; mkdir "$HOME/.gemini/bin/agy"; printf foreign > "$HOME/.gemini/bin/agy/keep";;
      link-symlink:"$HOME/.gemini/bin") touch "$HCC_NATIVE_MARKER"; /usr/bin/ln -s /missing-vendor-target "$HOME/.gemini/bin/agy";;
      alias-link:"$HOME/.local/bin") touch "$HCC_NATIVE_MARKER"; printf foreign > "$HOME/.local/bin/agy";;
      open-writer:"$HOME/.gemini/bin") touch "$HCC_NATIVE_MARKER"; printf foreign-open-writer >&7;;
    esac
fi
exec /usr/bin/ln "$@"
FIXTURE
    chmod +x "$work/$fault/bin/"*
    export PATH="$work/$fault/bin:$basepath"
    if bash "$repo/uninstall.sh" --tool agy --yes > "$work/$fault/uninstall.log" 2>&1; then fail "native fault accepted: $fault"; fi
    exec 7>&-
    [[ -e "$HCC_NATIVE_MARKER" && -f "$root/tools/agy/pending" && $(readlink "$root/tools/agy/current") == "$selected" && -f "$selected/binary" ]] || fail "fault lost recovery or selected release: $fault"
    case "$fault" in
      copy-*) [[ $(sha256sum < "$HOME/.gemini/bin/agy") == "$primary_before" && $(sha256sum < "$HOME/.local/bin/agy") == "$alias_before" ]] || fail 'bad native copy was published';;
      before-capture|link-file) [[ $(< "$HOME/.gemini/bin/agy") == foreign ]] || fail 'foreign primary overwritten';;
      link-directory) [[ $(< "$HOME/.gemini/bin/agy/keep") == foreign ]] || fail 'foreign directory overwritten';;
      link-symlink) [[ $(readlink "$HOME/.gemini/bin/agy") == /missing-vendor-target ]] || fail 'foreign symlink overwritten';;
      alias-link) [[ $(< "$HOME/.local/bin/agy") == foreign && $(sha256sum < "$HOME/.gemini/bin/agy") == "$digest  -" ]] || fail 'alias race clobbered foreign entry or lost current native primary';;
      open-writer)
        mapfile -t transaction < "$root/tools/agy/pending"
        grep -q foreign-open-writer "${transaction[3]}/captured" || fail 'changed capture discarded';;
    esac
    if bash "$repo/uninstall.sh" --tool agy --yes >/dev/null 2>&1; then fail 'pending native handoff retried automatically'; fi
    [[ ! -e "$root/tools/agy/original" && ! -e "$root/tools/agy/installed" ]] || fail 'obsolete persistent fingerprints created'
done
printf 'PASS native uninstall faults: short/failed copies, capture/link/file/directory/symlink/alias races, SIGKILL, open-writer recovery\n'
