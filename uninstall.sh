#!/usr/bin/env bash
set -euo pipefail
HCC_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
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
