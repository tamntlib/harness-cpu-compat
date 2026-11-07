#!/usr/bin/env bash
set -euo pipefail
# The same bootstrap preamble is embedded in both public entrypoints.
hcc_bootstrap() {
    local entry=$1 base relative name listing mode owner size rest status
    local -A sizes=()
    shift
    for name in curl tar timeout env mktemp mkdir rm wc; do
        command -v "$name" >/dev/null 2>&1 || { printf 'Error: bootstrap requires %s (install it separately).\n' "$name" >&2; exit 1; }
    done
    base=${TMPDIR:-${HOME:?HOME must be set}}
    [[ "$base" == /* && -d "$base" ]] || { printf 'Error: bootstrap temporary parent must be an existing absolute directory.\n' >&2; exit 1; }
    umask 077
    _hcc_boot_tmp=$(mktemp -d "$base/hcc-bootstrap.XXXXXX")
    hcc_boot_cleanup() {
        local result=$?
        trap - EXIT
        if ! rm -rf -- "$_hcc_boot_tmp"; then
            printf 'Error: could not remove bootstrap directory: %s\n' "$_hcc_boot_tmp" >&2
            (( result != 0 )) || result=1
        fi
        exit "$result"
    }
    hcc_boot_interrupt() {
        local signal=$1 result=$2 pid
        trap '' INT TERM
        for pid in $(jobs -pr); do kill -s "$signal" "$pid" 2>/dev/null || :; done
        wait || :
        exit "$result"
    }
    trap hcc_boot_cleanup EXIT
    trap 'hcc_boot_interrupt INT 130' INT
    trap 'hcc_boot_interrupt TERM 143' TERM
    hcc_boot_run() {
        local input=$1 pid result
        shift
        if [[ "$input" == keep ]]; then env --default-signal=INT,QUIT "$@" <&0 &
        else env --default-signal=INT,QUIT "$@" < /dev/null & fi
        pid=$!
        if wait "$pid"; then result=0; else result=$?; fi
        return "$result"
    }
    hcc_boot_fail() { printf 'Error: bootstrap %s\n' "$*" >&2; exit 1; }
    # One complete archive is one coherent main snapshot; it is not a signed release.
    hcc_boot_run null curl -q --fail --silent --show-error --location --max-redirs 5 \
        --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 90 \
        --max-filesize 8388608 --output "$_hcc_boot_tmp/bundle.tgz" \
        https://codeload.github.com/tamntlib/harness-cpu-compat/tar.gz/refs/heads/main || hcc_boot_fail 'download failed.'
    unset TAR_OPTIONS
    export LC_ALL=C
    timeout 30 tar --quoting-style=escape -tzf "$_hcc_boot_tmp/bundle.tgz" > "$_hcc_boot_tmp/names" || hcc_boot_fail 'archive is incomplete or invalid.'
    while IFS= read -r name; do
        name=${name%/}
        [[ "$name" == harness-cpu-compat-main || "$name" == harness-cpu-compat-main/* ]] || hcc_boot_fail 'archive has an unexpected root.'
        [[ "$name" != *\\* ]] || hcc_boot_fail 'archive has an escaped or ambiguous pathname.'
        case "/$name/" in *'/../'*|*'/./'*|*'//'*) hcc_boot_fail 'archive has an unsafe pathname.';; esac
    done < "$_hcc_boot_tmp/names"
    for relative in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do
        listing=$(timeout 30 tar --quoting-style=escape --numeric-owner --no-wildcards --no-recursion -tvzf "$_hcc_boot_tmp/bundle.tgz" -- "harness-cpu-compat-main/$relative") || hcc_boot_fail "archive is missing $relative."
        [[ "$listing" == -* && "$listing" != *$'\n'* ]] || hcc_boot_fail "archive member is not one regular file: $relative."
        read -r mode owner size rest <<< "$listing"
        [[ "$size" =~ ^[0-9]+$ && ${#size} -le 7 && "$size" -gt 0 && "$size" -le 1048576 ]] || hcc_boot_fail "archive member has an invalid size: $relative."
        sizes[$relative]=$size
    done
    mkdir -- "$_hcc_boot_tmp/lib"
    for relative in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do
        timeout 30 tar --no-wildcards --no-recursion -xOzf "$_hcc_boot_tmp/bundle.tgz" -- "harness-cpu-compat-main/$relative" > "$_hcc_boot_tmp/$relative" || hcc_boot_fail "could not read $relative."
        [[ $(wc -c < "$_hcc_boot_tmp/$relative") == "${sizes[$relative]}" ]] && /bin/bash -n "$_hcc_boot_tmp/$relative" || hcc_boot_fail "invalid Shell file: $relative."
    done
    if hcc_boot_run "$_hcc_boot_input" /bin/bash "$_hcc_boot_tmp/$entry" "$@"; then status=0; else status=$?; fi
    exit "$status"
}
HCC_SOURCE=
_hcc_boot_input=null
if [[ -n ${BASH_SOURCE[0]-} && -f ${BASH_SOURCE[0]} ]]; then
    HCC_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    _hcc_boot_input=keep
fi
_hcc_bundle_complete=1
for _hcc_file in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do
    [[ -n "$HCC_SOURCE" && -f "$HCC_SOURCE/$_hcc_file" && -r "$HCC_SOURCE/$_hcc_file" ]] || _hcc_bundle_complete=0
done
if (( ! _hcc_bundle_complete )); then hcc_bootstrap uninstall.sh "$@"; fi
unset _hcc_boot_input _hcc_bundle_complete _hcc_file
# shellcheck source=lib/common.sh
source "$HCC_SOURCE/lib/common.sh"
source "$HCC_SOURCE/lib/watch.sh"
HCC_WATCH_CONTROL_HELD=0; HCC_UNINSTALL_CLAIM_HELD=0
tool=all; yes=0; dry=0
while (( $# )); do
    case "$1" in
        --tool) (( $# >= 2 )) || hcc_die 'Missing --tool value.'; tool=$2; shift 2;;
        --yes) yes=1; shift;; --dry-run) dry=1; shift;;
        --help|-h) printf 'Usage: ./uninstall.sh [--tool claude|agy|all] [--yes] [--dry-run]\n'; exit 0;;
        *) hcc_die "Unknown argument: $1";;
    esac
done
case "$tool" in claude|agy) HCC_TOOLS=("$tool");; all) HCC_TOOLS=(claude agy);; *) hcc_die 'Invalid tool.';; esac
for dependency in realpath sha256sum readlink dirname; do hcc_need "$dependency"; done
hcc_paths
if (( dry )); then hcc_readonly; printf 'PLAN: restore only owned entries; retain binaries, backups, credentials and user data.\n'; exit 0; fi
[[ -d "$HCC_ROOT" ]] || { printf 'Nothing installed.\n'; exit 0; }
if (( ! yes )); then
    [[ -t 0 ]] || hcc_die 'Use --yes for a noninteractive uninstall.'
    printf 'Restore original %s entries? Close IDE sessions first. [y/N]: ' "$tool" >&2
    read -r answer; [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
hcc_need flock
for selected in "${HCC_TOOLS[@]}"; do
    if [[ "$selected" == agy ]]; then
        hcc_watch_control_lock
        # A first install may have completed while this process waited for the lock.
        if [[ -f "$HCC_ROOT/tools/agy/installed" || -e "$HCC_ROOT/watch/owned" || -e "$HCC_ROOT/watch/enabled" ]]; then
            hcc_watch_claim_acquire; HCC_UNINSTALL_CLAIM_HELD=1
            if [[ -e "$HCC_ROOT/watch/owned" || -e "$HCC_ROOT/watch/enabled" ]]; then hcc_watch_disable keep-lock; fi
        fi
    fi
done
exec 9> "$HCC_ROOT/operation.lock"
flock -w 30 9 || hcc_die 'Another operation holds the installation lock.'
for tool in "${HCC_TOOLS[@]}"; do hcc_uninstall_tool "$tool"; done
if (( HCC_UNINSTALL_CLAIM_HELD )); then hcc_watch_claim_release; fi
flock -u 9; exec 9>&-
hcc_watch_control_unlock
