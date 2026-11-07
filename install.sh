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
if (( ! _hcc_bundle_complete )); then hcc_bootstrap install.sh "$@"; fi
unset _hcc_boot_input _hcc_bundle_complete _hcc_file
# shellcheck source=lib/common.sh
source "$HCC_SOURCE/lib/common.sh"
source "$HCC_SOURCE/lib/watch.sh"
usage() {
    printf '%s\n' \
      'Usage: ./install.sh --tool claude|agy|all [--yes] [--mode auto|native|qemu]' \
      '       ./install.sh --doctor [--tool claude|agy|all]' \
      '       ./install.sh --dry-run --tool claude|agy|all' \
      'Options: --version latest|stable|X.Y.Z, --qemu /absolute/path, --repair' \
      'Local import: --from-binary PATH --version X.Y.Z --sha256 DIGEST' \
      'AGY auto-repair: --auto-repair (opt in after install), --no-auto-repair (disable only)' \
      'Rerun this installer to update. Missing QEMU is installed via APT (sudo when needed). No IDE JavaScript is patched.'
}
HCC_WATCH_CONTROL_HELD=0; HCC_WATCH_CLAIM_NEW=0
HCC_TOOL=; HCC_YES=0; HCC_DOCTOR=0; HCC_DRY=0; HCC_REPAIR=0; HCC_WATCH_ACTION=none
HCC_REQUEST_MODE=auto; HCC_REQUEST_VERSION=latest; HCC_REQUEST_QEMU=; HCC_FROM=; HCC_EXPECTED=
while (( $# )); do
    case "$1" in
        --tool|--mode|--version|--qemu|--from-binary|--sha256)
            (( $# >= 2 )) || hcc_die "Missing value for $1"
            case "$1" in
                --tool) HCC_TOOL=$2;; --mode) HCC_REQUEST_MODE=$2;; --version) HCC_REQUEST_VERSION=$2;;
                --qemu) HCC_REQUEST_QEMU=$2;; --from-binary) HCC_FROM=$2;; --sha256) HCC_EXPECTED=$2;;
            esac; shift 2;;
        --yes) HCC_YES=1; shift;; --doctor) HCC_DOCTOR=1; shift;;
        --dry-run) HCC_DRY=1; shift;; --repair) HCC_REPAIR=1; shift;;
        --auto-repair|--no-auto-repair)
            [[ "$HCC_WATCH_ACTION" == none ]] || hcc_die 'Specify only one auto-repair option.'
            HCC_WATCH_ACTION=$1; shift;;
        --help|-h) usage; exit 0;; *) hcc_die "Unknown argument: $1";;
    esac
done
if [[ -z "$HCC_TOOL" ]]; then
    if (( HCC_DOCTOR )); then HCC_TOOL=all
    elif [[ -t 0 && "$HCC_YES" == 0 ]]; then
        printf 'Install which tool? [claude/agy/all]: ' >&2; read -r HCC_TOOL
    else usage >&2; hcc_die 'Specify --tool claude|agy|all.'; fi
fi
case "$HCC_TOOL" in claude|agy) HCC_TOOLS=("$HCC_TOOL");; all) HCC_TOOLS=(claude agy);; *) hcc_die 'Invalid tool.';; esac
[[ "$HCC_WATCH_ACTION" == none || "$HCC_TOOL" != claude ]] || hcc_die 'Auto-repair options require AGY, not Claude only.'
case "$HCC_REQUEST_MODE" in auto|native|qemu) ;; *) hcc_die 'Invalid execution mode.';; esac
[[ ${HCC_PROBE_TIMEOUT:-20} =~ ^[1-9][0-9]?$ ]] || hcc_die 'HCC_PROBE_TIMEOUT must be 1..99 seconds.'
[[ -z "$HCC_FROM" || "$HCC_TOOL" != all ]] || hcc_die '--from-binary requires one explicit tool.'
for dependency in uname realpath sha256sum readlink dirname tr cmp; do hcc_need "$dependency"; done
hcc_paths
if (( HCC_DOCTOR )); then hcc_readonly; exit 0; fi
if (( HCC_DRY )); then
    hcc_readonly
    printf 'Auto-repair request: %s (no unit writes or manager calls)\n' "$HCC_WATCH_ACTION"
    printf 'PLAN: install %s; mode=%s; release=%s; store=%s/releases/<tool>\n' "$HCC_TOOL" "$HCC_REQUEST_MODE" "$HCC_REQUEST_VERSION" "$HCC_ROOT"
    printf 'AGY entry: %s/.gemini/bin/agy; CLI entries: %s/.local/bin/{claude,agy}\n' "$HOME" "$HOME"
    printf 'No files changed. Close IDE sessions before installation/repair; reload afterward.\n'
    exit 0
fi
if [[ "$HCC_WATCH_ACTION" == --no-auto-repair ]]; then
    (( HCC_YES )) || hcc_die 'Use --yes to explicitly disable auto-repair.'
    hcc_need flock
    hcc_watch_disable
    exit 0
fi
for dependency in flock timeout env cp mv chmod mkdir mktemp cmp grep head date bash; do hcc_need "$dependency"; done
if [[ -z "$HCC_FROM" ]]; then for dependency in curl jq tar sha512sum; do hcc_need "$dependency"; done; fi
for tool in "${HCC_TOOLS[@]}"; do hcc_check_existing "$tool"; done
if [[ "$HCC_WATCH_ACTION" == --auto-repair ]]; then hcc_watch_init; hcc_watch_validate_units; hcc_watch_manager_check; fi
if (( ! HCC_YES )); then
    [[ -t 0 ]] || hcc_die 'Use --yes for a noninteractive installation.'
    printf 'Install %s in this user account? Existing entries may be replaced; no historical baseline backup is kept. If emulation needs missing QEMU, APT will install system package qemu-user (sudo when needed). Close IDE sessions first. [y/N]: ' "$HCC_TOOL" >&2
    read -r answer; [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
umask 077
mkdir -m 700 -p -- "$HCC_ROOT" "$HCC_ROOT/staging"
if [[ "$HCC_TOOL" != claude ]]; then hcc_watch_control_lock; fi
exec 9> "$HCC_ROOT/operation.lock"
flock -w 30 9 || hcc_die 'Another operation holds the installation lock.'
HCC_STAGE=; HCC_TX_ACTIVE=0
trap hcc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$HCC_TOOL" != claude ]]; then hcc_watch_claim_acquire; fi
for tool in "${HCC_TOOLS[@]}"; do hcc_install_tool "$tool"; done
if [[ "$HCC_WATCH_ACTION" == --auto-repair ]]; then hcc_watch_enable; fi
if [[ "$HCC_TOOL" != claude && ! -f "$HCC_ROOT/watch/enabled" ]]; then hcc_watch_claim_release; fi
HCC_WATCH_CLAIM_NEW=0
flock -u 9; exec 9>&-
hcc_watch_control_unlock
hcc_log 'Installation verified with isolated --version and --help probes.'
hcc_log 'Add ~/.local/bin to PATH if needed. For AGY IDE support, reload the affected window.'
hcc_log 'AGY IDE support is experimental: its updater may overwrite the wrapper. Rerun with --repair while IDE sessions are closed.'
