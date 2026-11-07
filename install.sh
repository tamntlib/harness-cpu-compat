#!/usr/bin/env bash
set -euo pipefail
HCC_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
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
      'AGY watcher: --watch-agy (opt in after install), --no-watch-agy (disable only)' \
      'Rerun this installer to update. No IDE JavaScript is patched.'
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
        --watch-agy|--no-watch-agy)
            [[ "$HCC_WATCH_ACTION" == none ]] || hcc_die 'Specify only one watcher option.'
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
[[ "$HCC_WATCH_ACTION" == none || "$HCC_TOOL" != claude ]] || hcc_die 'Watcher options require AGY, not Claude only.'
case "$HCC_REQUEST_MODE" in auto|native|qemu) ;; *) hcc_die 'Invalid execution mode.';; esac
[[ ${HCC_PROBE_TIMEOUT:-20} =~ ^[1-9][0-9]?$ ]] || hcc_die 'HCC_PROBE_TIMEOUT must be 1..99 seconds.'
[[ -z "$HCC_FROM" || "$HCC_TOOL" != all ]] || hcc_die '--from-binary requires one explicit tool.'
for dependency in uname realpath sha256sum readlink dirname tr; do hcc_need "$dependency"; done
hcc_paths
if (( HCC_DOCTOR )); then hcc_readonly; exit 0; fi
if (( HCC_DRY )); then
    hcc_readonly
    printf 'Watcher request: %s (no unit writes or manager calls)\n' "$HCC_WATCH_ACTION"
    printf 'PLAN: install %s; mode=%s; release=%s; backups=%s/tools/<tool>/original\n' "$HCC_TOOL" "$HCC_REQUEST_MODE" "$HCC_REQUEST_VERSION" "$HCC_ROOT"
    printf 'AGY entry: %s/.gemini/bin/agy; CLI entries: %s/.local/bin/{claude,agy}\n' "$HOME" "$HOME"
    printf 'No files changed. Close IDE sessions before installation/repair; reload afterward.\n'
    exit 0
fi
if [[ "$HCC_WATCH_ACTION" == --no-watch-agy ]]; then
    (( HCC_YES )) || hcc_die 'Use --yes to explicitly disable the watcher.'
    hcc_need flock
    hcc_watch_disable
    exit 0
fi
for dependency in flock timeout env cp mv chmod mkdir mktemp cmp grep head date bash; do hcc_need "$dependency"; done
if [[ -z "$HCC_FROM" ]]; then for dependency in curl jq tar sha512sum; do hcc_need "$dependency"; done; fi
for tool in "${HCC_TOOLS[@]}"; do hcc_check_existing "$tool"; done
if [[ "$HCC_WATCH_ACTION" == --watch-agy ]]; then hcc_watch_init; hcc_watch_validate_units; hcc_watch_manager_check; fi
if (( ! HCC_YES )); then
    [[ -t 0 ]] || hcc_die 'Use --yes for a noninteractive installation.'
    printf 'Install %s in this user account? Existing entries will be backed up. Close IDE sessions first. [y/N]: ' "$HCC_TOOL" >&2
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
if [[ "$HCC_WATCH_ACTION" == --watch-agy ]]; then hcc_watch_enable; fi
if [[ "$HCC_TOOL" != claude && ! -f "$HCC_ROOT/watch/enabled" ]]; then hcc_watch_claim_release; fi
HCC_WATCH_CLAIM_NEW=0
flock -u 9; exec 9>&-
hcc_watch_control_unlock
hcc_log 'Installation verified with isolated --version and --help probes.'
hcc_log 'Add ~/.local/bin to PATH if needed. For AGY IDE support, reload the affected window.'
hcc_log 'AGY IDE support is experimental: its updater may overwrite the wrapper. Rerun with --repair while IDE sessions are closed.'
