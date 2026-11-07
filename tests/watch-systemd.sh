#!/usr/bin/env bash
# Opt-in acceptance: real user-manager events, synthetic publisher, disposable HOME.
set -euo pipefail
[[ ${HCC_RUN_SYSTEMD_WATCH_TEST:-0} == 1 ]] || { printf 'Set HCC_RUN_SYSTEMD_WATCH_TEST=1\n' >&2; exit 64; }
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-systemd.XXXXXX")
base=; linked=0
cleanup() {
    local result=$?
    trap - EXIT
    if (( linked )); then
        /usr/bin/systemctl --user stop "$base.path" "$base.timer" "$base.service" || result=1
        /usr/bin/systemctl --user disable --runtime "$base.path" "$base.timer" "$base.service" || result=1
        /usr/bin/systemctl --user daemon-reload || result=1
    fi
    printf 'Systemd acceptance evidence retained: %s\n' "$work"
    exit "$result"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
# Exercise literal spaces, percent, dollar, quote and backslash in all unit arguments.
wf_init "$work/quoted % dollar\$ slash\\ and \"quote\""
mapfile -t record < "$root/watch/owned"; base=${record[0]}; config=${record[1]}
mkdir "$work/runtime-units"
for suffix in service path timer; do cp "$config/$base.$suffix" "$work/runtime-units/$base.$suffix"; done
# Test-only limits/environment; generated ExecStart and both PathChanged lines remain unchanged.
{
    printf '\n[Service]\nCPUAffinity=0 1\nEnvironment='
    source "$repo/lib/common.sh"; source "$repo/lib/watch.sh"
    hcc_watch_quote "PATH=$PATH"; printf ' '; hcc_watch_quote "HCC_FEED=$HCC_FEED"; printf ' '; hcc_watch_quote "HCC_NETWORK_LOG=$HCC_NETWORK_LOG"; printf '\n'
} >> "$work/runtime-units/$base.service"
# Slow only the synthetic fetch so the controller can read the live worker cgroup.
cp "$work/quoted % dollar\$ slash\\ and \"quote\"/bin/curl" "$work/original-curl"
printf '#!/usr/bin/env bash\nsleep .5\nexec /bin/bash %q "$@"\n' "$work/original-curl" > "$(dirname "$HOME")/bin/curl"
chmod +x "$(dirname "$HOME")/bin/curl"
/usr/bin/systemd-analyze --user verify "$work/runtime-units/$base.service" "$work/runtime-units/$base.path" "$work/runtime-units/$base.timer"
linked=1
/usr/bin/systemctl --user link --runtime "$work/runtime-units/$base.service" "$work/runtime-units/$base.path" "$work/runtime-units/$base.timer"
/usr/bin/systemctl --user daemon-reload
/usr/bin/systemctl --user start "$base.path" "$base.timer" "$base.service"
wait_for_version() {
    local wanted=$1 observed= control= value= pid=
    for ((i=0;i<300;i++)); do
        control=$(/usr/bin/systemctl --user show --property=ControlGroup --value "$base.service")
        if [[ -n "$control" && -r "/sys/fs/cgroup$control/memory.max" ]]; then
            # A completed oneshot can lose its cgroup between reads: skip incomplete samples, never call them proof.
            if { IFS= read -r memory < "/sys/fs/cgroup$control/memory.max" && IFS= read -r swap < "/sys/fs/cgroup$control/memory.swap.max" && IFS= read -r cpu < "/sys/fs/cgroup$control/cpu.max"; } 2>/dev/null; then
                [[ "$memory" == 1073741824 && "$swap" == 0 && "$cpu" == '200000 100000' ]] || fail 'live worker resource caps missing'
                printf 'PASS live worker cgroup: %s memory=1GiB swap=0 cpu=2\n' "$control" > "$work/resources.txt"
            fi
        fi
        observed=$(timeout -k 1s 2s "$HOME/.local/bin/agy" --version 2>/dev/null || true)
        [[ "$observed" == "$wanted" && ! -e "$root/watch/pending" ]] && return
        sleep .05
    done
    /usr/bin/journalctl --user -u "$base.service" --no-pager -n 30 >&2
    fail "event repair did not converge to $wanted"
}
wf_feed 1.0.1
cp "$HCC_FEED/cli" "$work/incoming"
mv -T "$work/incoming" "$HOME/.gemini/bin/agy"
wait_for_version 1.0.1
wf_feed 1.0.2
/usr/bin/dd if="$HCC_FEED/cli" of="$HOME/.gemini/bin/agy" conv=fsync status=none
wait_for_version 1.0.2
[[ -f "$work/resources.txt" ]] || fail 'live resource cap not observed'
before=$(sha256sum "$HCC_NETWORK_LOG")
sleep 1
[[ $(sha256sum "$HCC_NETWORK_LOG") == "$before" ]] || fail 'self-event loop repeated network requests'
[[ $(/usr/bin/systemctl --user show --property=ActiveState --value "$base.path") == active ]] || fail 'path trigger failed'
[[ $(/usr/bin/systemctl --user show --property=Result --value "$base.service") == success ]] || fail 'worker ended in failure'
printf 'PASS real systemd watcher: rename and close-write events, special-character unit quoting, convergence, no self-event downloads, resource enforcement\n'
