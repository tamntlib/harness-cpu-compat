#!/usr/bin/env bash
# Optional systemd-user integration. Sourcing this file has no side effects.
hcc_watch_safe_text() { [[ "$1" != *[[:cntrl:]]* ]] || hcc_die 'Watcher paths cannot contain control characters.'; }
hcc_watch_quote() {
    local value=$1 context=${2:-literal}
    hcc_watch_safe_text "$value"
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//%/%%}
    [[ "$context" != exec ]] || value=${value//\$/\$\$}
    printf '"%s"' "$value"
}
hcc_watch_init() {
    local digest
    hcc_watch_safe_text "$HOME"; hcc_watch_safe_text "$HCC_ROOT"
    WDIR="$HCC_ROOT/watch"
    [[ ! -L "$WDIR" && ( ! -e "$WDIR" || ( -d "$WDIR" && -O "$WDIR" ) ) ]] || hcc_die 'Unsafe watcher state directory.'
    digest=$(printf '%s\n' "$HCC_ROOT" | sha256sum); digest=${digest%% *}
    WUNIT="hcc-agy-watch-${digest:0:16}"
    WCONFIG=$(realpath -m -- "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user")
    if [[ -e "$WDIR/owned" || -L "$WDIR/owned" ]]; then
        [[ -f "$WDIR/owned" && ! -L "$WDIR/owned" && -O "$WDIR/owned" ]] || hcc_die 'Unsafe watcher ownership record.'
        mapfile -t WRECORD < "$WDIR/owned"
        [[ ${#WRECORD[@]} == 5 && ${WRECORD[0]} == "$WUNIT" ]] || hcc_die 'Invalid watcher ownership record.'
        WCONFIG=${WRECORD[1]}
    else WRECORD=(); fi
    hcc_watch_safe_text "$WCONFIG"
    [[ "$WCONFIG" == "$HCC_USER_HOME/"* && $(realpath -m -- "$WCONFIG") == "$WCONFIG" ]] || hcc_die 'Watcher unit directory must remain inside HOME.'
    WCLAIM="$HOME/.gemini/bin/.hcc-watch-owner"
    for path in "$WDIR/enabled" "$WDIR/pending" "$WCLAIM"; do
        [[ ! -L "$path" && ( ! -e "$path" || ( -f "$path" && -O "$path" ) ) ]] || hcc_die "Unsafe watcher state: $path"
    done
    [[ ! -L "$WDIR/units" && ( ! -e "$WDIR/units" || ( -d "$WDIR/units" && -O "$WDIR/units" ) ) ]] || hcc_die 'Unsafe watcher unit snapshots.'
}
hcc_watch_validate_units() {
    local suffix index=2 actual baseline digest
    for suffix in service path timer; do
        actual="$WCONFIG/$WUNIT.$suffix"
        hcc_check_parent "$actual"
        if (( ${#WRECORD[@]} )); then
            digest=${WRECORD[index]}; baseline="$WDIR/units/$digest"
            [[ "$digest" =~ ^[a-f0-9]{64}$ && -f "$baseline" && ! -L "$baseline" && $(hcc_hash "$baseline") == "$digest" ]] || hcc_die 'Watcher unit snapshot changed.'
            if [[ -e "$actual" || -L "$actual" ]]; then
                [[ -f "$actual" && ! -L "$actual" && $(hcc_hash "$actual") == "$digest" ]] || hcc_die "Watcher unit modified; preserving it: $actual"
            elif [[ -f "$WDIR/enabled" ]]; then hcc_die "Enabled watcher unit missing: $actual"; fi
        else
            [[ ! -e "$actual" && ! -L "$actual" ]] || hcc_die "Foreign unit already exists: $actual"
        fi
        index=$((index+1))
    done
    if [[ -e "$WCLAIM" ]]; then [[ $(< "$WCLAIM") == "$HCC_ROOT" ]] || hcc_die 'Another state directory owns this AGY watcher.'; fi
}
hcc_watch_manager_check() {
    local suffix fragment
    hcc_need systemctl
    systemctl --user show-environment > /dev/null || hcc_die 'The systemd user manager is unavailable.'
    for suffix in service path timer; do
        fragment=$(systemctl --user show --property=FragmentPath --value "$WUNIT.$suffix" 2>/dev/null) || hcc_die 'Cannot establish loaded watcher unit ownership.'
        [[ -z "$fragment" || "$fragment" == "$WCONFIG/$WUNIT.$suffix" ]] || hcc_die 'A different loaded unit owns this watcher identity.'
    done
}
hcc_watch_generate() {
    local destination=$1
    mkdir -m 700 -p -- "$destination"
    {
        printf '[Unit]\nDescription=Verified AGY wrapper reconciliation\nStartLimitIntervalSec=60s\nStartLimitBurst=10\n\n[Service]\nType=oneshot\n'
        printf 'ExecStart=/bin/bash '; hcc_watch_quote "$HCC_ROOT/program/lib/watch.sh" exec
        printf ' --reconcile '; hcc_watch_quote "$HCC_ROOT" exec; printf ' '; hcc_watch_quote "$HOME" exec; printf '\n'
        printf 'Environment="PATH=/usr/local/bin:/usr/bin:/bin"\nSlice=app.slice\nCPUQuota=200%%\nMemoryMax=1G\nMemorySwapMax=0\nTasksMax=128\nTimeoutStartSec=180s\nLimitCORE=0\nKillMode=control-group\nUMask=0077\n'
    } > "$destination/$WUNIT.service"
    {
        printf '[Unit]\nDescription=Observe AGY entry replacement and close-write\n\n[Path]\n'
        # PathChanged consumes the whole raw path, unlike ExecStart/Environment: quotes are literal.
        printf 'PathChanged=%s/.gemini/bin\nPathChanged=%s/.gemini/bin/agy\n' "${HOME//%/%%}" "${HOME//%/%%}"
        printf '\nUnit=%s.service\n\n[Install]\nWantedBy=default.target\n' "$WUNIT"
    } > "$destination/$WUNIT.path"
    {
        printf '[Unit]\nDescription=AGY watcher startup and missed-event fallback\n\n[Timer]\nOnActiveSec=30s\nOnUnitInactiveSec=5min\nAccuracySec=30s\nUnit=%s.service\n\n[Install]\nWantedBy=timers.target\n' "$WUNIT"
    } > "$destination/$WUNIT.timer"
}
hcc_watch_claim_acquire() {
    local temporary
    WCLAIM="$HOME/.gemini/bin/.hcc-watch-owner"
    [[ ! -L "$WCLAIM" && ( ! -e "$WCLAIM" || ( -f "$WCLAIM" && -O "$WCLAIM" ) ) ]] || hcc_die 'Unsafe AGY entry ownership claim.'
    hcc_check_parent "$HOME/.gemini/bin/agy"
    mkdir -m 700 -p -- "$HOME/.gemini/bin"
    temporary=$(mktemp "$HOME/.gemini/bin/.hcc-watch-claim.XXXXXX")
    printf '%s\n' "$HCC_ROOT" > "$temporary"
    if ln -T -- "$temporary" "$WCLAIM" 2>/dev/null; then HCC_WATCH_CLAIM_NEW=1;
    else
        rm -- "$temporary"
        [[ -f "$WCLAIM" && ! -L "$WCLAIM" && $(< "$WCLAIM") == "$HCC_ROOT" ]] || hcc_die 'Another state root reserved AGY watcher ownership.'
        return
    fi
    rm -- "$temporary"
}
hcc_watch_claim_release() {
    local claim="$HOME/.gemini/bin/.hcc-watch-owner"
    if [[ -e "$claim" || -L "$claim" ]]; then
        [[ -f "$claim" && ! -L "$claim" && -O "$claim" && $(< "$claim") == "$HCC_ROOT" ]] || hcc_die 'AGY entry claim changed; refusing ownership release.'
        rm -- "$claim"
    fi
    HCC_WATCH_CLAIM_NEW=0
}
hcc_watch_triggers_ready() {
    local suffix
    for suffix in path timer; do
        systemctl --user is-enabled --quiet "$WUNIT.$suffix" || return 1
        systemctl --user is-active --quiet "$WUNIT.$suffix" || return 1
    done
}
hcc_watch_enable() {
    local suffix temporary digest baseline staged index
    local -a digests=()
    hcc_watch_init
    [[ -L "$HCC_ROOT/tools/agy/current" && ! -e "$HCC_ROOT/tools/agy/pending" && ! -e "$WDIR/pending" ]] || hcc_die 'A complete managed AGY installation is required before enabling its watcher.'
    hcc_selected agy
    hcc_is_managed "$HOME/.gemini/bin/agy" agy "$SELECT_RELEASE" && hcc_is_managed "$HOME/.local/bin/agy" agy "$SELECT_RELEASE" || hcc_die 'AGY entries drifted before watcher enable.'
    hcc_watch_validate_units; hcc_watch_manager_check
    mkdir -m 700 -p -- "$WDIR" "$WCONFIG" "$WDIR/units"
    temporary=$(mktemp -d "$WDIR/enable.XXXXXX")
    hcc_watch_generate "$temporary"
    index=2
    for suffix in service path timer; do
        digest=$(hcc_hash "$temporary/$WUNIT.$suffix"); digests+=("$digest")
        if [[ -f "$WDIR/enabled" ]]; then
            [[ "$digest" == "${WRECORD[index]}" && $(< "$WDIR/enabled") == "$HCC_ROOT" ]] || hcc_die 'Disable the watcher before changing its unit configuration.'
        fi
        index=$((index+1))
    done
    # Ownership baselines are immutable by digest. A failed preparation never truncates an old baseline.
    if [[ ! -f "$WDIR/enabled" ]]; then
        index=0
        for suffix in service path timer; do
            digest=${digests[index]}; baseline="$WDIR/units/$digest"
            if [[ -e "$baseline" || -L "$baseline" ]]; then
                [[ -f "$baseline" && ! -L "$baseline" && $(hcc_hash "$baseline") == "$digest" ]] || hcc_die 'Immutable unit snapshot changed.'
            else
                staged=$(mktemp "$WDIR/units/.prepare.XXXXXX")
                if ! cp -- "$temporary/$WUNIT.$suffix" "$staged"; then rm -f -- "$staged"; hcc_die 'Cannot prepare unit ownership snapshot.'; fi
                [[ $(hcc_hash "$staged") == "$digest" ]] || { rm -f -- "$staged"; hcc_die 'Prepared unit snapshot checksum mismatch.'; }
                ln -T -- "$staged" "$baseline" || hcc_die 'Unit snapshot publication conflict.'
                rm -- "$staged"
            fi
            index=$((index+1))
        done
        index=0
        for suffix in service path timer; do
            staged="$WCONFIG/$WUNIT.$suffix.hcc-new.$$"
            cp -- "$temporary/$WUNIT.$suffix" "$staged" || hcc_die 'Cannot stage owned unit file.'
            [[ $(hcc_hash "$staged") == "${digests[index]}" ]] || hcc_die 'Prepared unit file checksum mismatch.'
            index=$((index+1))
        done
        for suffix in service path timer; do mv -Tf -- "$WCONFIG/$WUNIT.$suffix.hcc-new.$$" "$WCONFIG/$WUNIT.$suffix"; done
        printf '%s\n' "$WUNIT" "$WCONFIG" "${digests[@]}" > "$temporary/owned"
        mv -Tf -- "$temporary/owned" "$WDIR/owned"
    fi
    hcc_watch_claim_acquire
    if [[ ! -f "$WDIR/enabled" ]]; then printf '%s\n' "$HCC_ROOT" > "$temporary/enabled"; mv -Tf -- "$temporary/enabled" "$WDIR/enabled"; fi
    if systemctl --user daemon-reload && systemctl --user enable --now "$WUNIT.path" "$WUNIT.timer" &&
       hcc_watch_triggers_ready; then
        rm -rf -- "$temporary"
        hcc_log 'AGY watcher enabled explicitly. Recovery may still require an IDE reload.'
    else
        rm -f -- "$WDIR/enabled"
        systemctl --user disable --now "$WUNIT.path" "$WUNIT.timer" || hcc_log 'Stopping failed activation triggers needs manual recovery.'
        systemctl --user stop "$WUNIT.service" || hcc_log 'Stopping failed activation worker needs manual recovery.'
        hcc_log 'Watcher activation failed; disabled state and owned recovery records retained.'
        return 1
    fi
}
hcc_watch_control_lock() {
    [[ ${HCC_WATCH_CONTROL_HELD:-0} != 1 ]] || return 0
    local directory="$HCC_ROOT/watch" lock
    [[ ! -L "$directory" && ( ! -e "$directory" || ( -d "$directory" && -O "$directory" ) ) ]] || hcc_die 'Unsafe watcher management directory.'
    mkdir -m 700 -p -- "$directory"
    lock="$directory/management.lock"
    [[ ! -L "$lock" && ( ! -e "$lock" || ( -f "$lock" && -O "$lock" ) ) ]] || hcc_die 'Unsafe watcher management lock.'
    exec 8> "$lock"
    flock -w 30 8 || hcc_die 'Watcher management operation is busy.'
    HCC_WATCH_CONTROL_HELD=1
}
hcc_watch_control_unlock() {
    if [[ ${HCC_WATCH_CONTROL_HELD:-0} == 1 ]]; then
        flock -u 8; exec 8>&-; HCC_WATCH_CONTROL_HELD=0
    fi
}
hcc_watch_disable() {
    local suffix keep=${1:-} present=0
    if [[ ! -e "$HCC_ROOT/watch" && ! -L "$HCC_ROOT/watch" ]]; then hcc_log 'AGY watcher is off.'; return; fi
    # Management lock serializes enable/disable/uninstall; workers use ONLY operation.lock.
    hcc_watch_control_lock
    hcc_watch_init
    if (( ${#WRECORD[@]} == 0 )); then
        [[ ! -e "$WDIR/enabled" ]] || hcc_die 'Watcher ownership record missing.'
        [[ "$keep" == keep-lock ]] || hcc_watch_control_unlock
        hcc_log 'AGY watcher is off.'; return
    fi
    hcc_watch_validate_units
    for suffix in service path timer; do [[ ! -e "$WCONFIG/$WUNIT.$suffix" && ! -L "$WCONFIG/$WUNIT.$suffix" ]] || present=1; done
    if [[ ! -e "$WDIR/enabled" && "$present" == 0 && ( ! -e "$WCLAIM" || "$keep" == keep-lock ) ]]; then
        [[ "$keep" == keep-lock ]] || hcc_watch_control_unlock
        hcc_log 'AGY watcher is already disabled.'; return
    fi
    hcc_watch_manager_check
    # Stop the worker before operation.lock: it never takes management.lock, avoiding inversion.
    systemctl --user disable --now "$WUNIT.path" "$WUNIT.timer" || return 1
    systemctl --user stop "$WUNIT.service" || return 1
    exec 9> "$HCC_ROOT/operation.lock"
    flock -w 30 9 || hcc_die 'Watcher operation is busy.'
    hcc_watch_init; hcc_watch_validate_units
    rm -f -- "$WDIR/enabled"
    for suffix in service path timer; do rm -f -- "$WCONFIG/$WUNIT.$suffix"; done
    if [[ "$keep" != keep-lock ]]; then hcc_watch_claim_release; fi
    systemctl --user daemon-reload || return 1
    flock -u 9; exec 9>&-
    [[ "$keep" == keep-lock ]] || hcc_watch_control_unlock
    hcc_log 'AGY watcher disabled; binaries, launchers and recovery records retained.'
}
hcc_watch_report() {
    if [[ ! -e "$HCC_ROOT/watch/owned" && ! -e "$HCC_ROOT/watch/enabled" && ! -L "$HCC_ROOT/watch" ]]; then printf 'AGY watcher: off\n'; return; fi
    hcc_watch_init
    if [[ -f "$WDIR/enabled" ]]; then printf 'AGY watcher: opted in (%s); manager activity not queried\n' "$WUNIT";
    else printf 'AGY watcher: off\n'; fi
    [[ ! -e "$WDIR/pending" ]] || printf 'AGY watcher: INCOMPLETE repair; preserve its journal and same-directory recovery slots.\n'
}
hcc_watch_prepare_slot() {
    local entry=$1 release=$2 parent
    hcc_check_parent "$entry"
    parent=$(realpath -e -- "$(dirname -- "$entry")")
    WSLOT=$(mktemp -d "$parent/.hcc-watch-recovery.XXXXXX")
    if [[ "$HCC_MODE" == native ]]; then ln -s -- "$release/binary" "$WSLOT/prepared";
    else
        hcc_render_launcher agy "$release" > "$WSLOT/prepared"
        chmod 700 -- "$WSLOT/prepared"; bash -n "$WSLOT/prepared"
    fi
}
hcc_watch_publish() (
    # Both rename endpoints and the no-clobber link are on the pinned parent's filesystem.
    local entry=$1 slot=$2 expected=$3 parent name actual relative parent_identity
    parent=$(dirname -- "$slot"); name=$(basename -- "$entry")
    [[ $(realpath -e -- "$(dirname -- "$entry")") == "$parent" ]] || { hcc_log 'Entry parent changed before capture.'; exit 1; }
    cd -- "$parent"
    [[ $(pwd -P) == "$parent" ]] || exit 1
    parent_identity=$(stat -c '%d:%i' -- .)
    relative=$(basename -- "$slot")
    [[ "$relative" == .hcc-watch-recovery.* && -d "$relative" && ! -L "$relative" ]] || exit 1
    if [[ "$expected" != absent ]]; then
        mv -T -- "$name" "$relative/captured" || exit 1
        actual=$(hcc_fingerprint "$relative/captured") || exit 1
        if [[ "$actual" != "$expected" ]]; then
            # Restore an unexpected capture only into a still-free public name.
            ln -P -T -- "$relative/captured" "$name" 2>/dev/null || true
            hcc_log 'Entry changed at capture; retained recovery journal and captured entry.'
            exit 1
        fi
    fi
    ln -P -T -- "$relative/prepared" "$name" || { hcc_log 'Concurrent publication won; foreign entry left untouched.'; exit 1; }
    [[ $(stat -c '%d:%i' -- "$parent") == "$parent_identity" && $(realpath -e -- "$(dirname -- "$entry")") == "$parent" ]] || { hcc_log 'Entry parent moved during publication; preserve recovery state.'; exit 1; }
)
hcc_watch_worker_cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n ${WSTAGE:-} && ! -e "$WDIR/pending" ]]; then rm -rf -- "$WSTAGE"; fi
    exit "$status"
}
hcc_watch_reconcile() {
    local directory entry alias old_current intended alias_expected real expected selected mode qemu release engine_key desired
    hcc_paths; hcc_watch_init
    [[ -f "$WDIR/enabled" ]] || return 0
    exec 9> "$HCC_ROOT/operation.lock"
    flock -n 9 || { hcc_log 'AGY operation busy; leaving reconciliation to the next event/fallback.'; return 0; }
    hcc_paths; hcc_watch_init
    [[ -f "$WDIR/enabled" ]] || return 0
    [[ ! -e "$WDIR/pending" && ! -e "$HCC_ROOT/tools/agy/pending" ]] || hcc_die 'Incomplete repair; preserve journal and recovery slots before retrying.'
    hcc_watch_validate_units
    [[ -f "$WCLAIM" && $(< "$WCLAIM") == "$HCC_ROOT" && $(< "$WDIR/enabled") == "$HCC_ROOT" ]] || hcc_die 'Watcher enablement/entry ownership changed.'
    directory="$HCC_ROOT/tools/agy"; entry="$HOME/.gemini/bin/agy"; alias="$HOME/.local/bin/agy"
    hcc_selected agy
    hcc_check_parent "$entry"; hcc_check_parent "$alias"
    hcc_is_managed "$alias" agy "$SELECT_RELEASE" || hcc_die 'CLI alias changed; automatic overwrite refused.'
    alias_expected=$(hcc_fingerprint "$alias")
    old_current=$(readlink -- "$directory/current")
    selected=$(realpath -e -- "$directory/current")
    [[ "$selected" == "$HCC_ROOT/releases/agy/"* && ! -L "$selected/binary" && -f "$selected/binary" && -f "$selected/sha256" && ! -L "$selected/sha256" && -f "$selected/selection" && ! -L "$selected/selection" ]] || hcc_die 'Selected private release is invalid.'
    expected=$(< "$selected/sha256")
    [[ "$expected" =~ ^[a-f0-9]{64}$ && $(hcc_hash "$selected/binary") == "$expected" ]] || hcc_die 'Selected private binary changed.'
    mapfile -t selection < "$selected/selection"
    [[ ${#selection[@]} == 3 && ${selection[0]} == "$selected/binary" ]] || hcc_die 'Private selection changed.'
    qemu=${selection[2]}
    intended=$(hcc_fingerprint "$entry")
    if hcc_is_managed "$entry" agy "$SELECT_RELEASE"; then return 0; fi
    [[ -f "$entry" && ! -L "$entry" ]] || hcc_die 'Only an ordinary incoming vendor executable can be adopted automatically.'
    sleep .2
    [[ $(hcc_fingerprint "$entry") == "$intended" ]] || hcc_die 'Incoming artifact is still changing; retry on a later event.'
    WSTAGE=$(mktemp -d "$HCC_ROOT/staging/watch.XXXXXX")
    trap hcc_watch_worker_cleanup EXIT
    cp -- "$entry" "$WSTAGE/incoming"
    [[ $(hcc_fingerprint "$WSTAGE/incoming") == "$intended" && $(hcc_fingerprint "$entry") == "$intended" ]] || hcc_die 'Incoming artifact changed while snapshotting.'
    mkdir -- "$WSTAGE/verified"
    # Verification precedes ALL execution. Sidecar/version output from an unknown file is not trusted.
    hcc_acquire agy "$WSTAGE/verified" latest '' ''
    [[ "$intended" == "file:$HCC_DIGEST" ]] || hcc_die 'Incoming bytes do not match the current publisher-verified AGY artifact; left untouched.'
    hcc_probe "$WSTAGE/verified" auto "$qemu"
    [[ $(hcc_fingerprint "$entry") == "$intended" && $(hcc_fingerprint "$alias") == "$alias_expected" ]] || hcc_die 'Entries changed during verification.'
    engine_key=$(printf '%s\n' "$HCC_MODE" "$HCC_QEMU" | sha256sum); engine_key=${engine_key%% *}
    release="$HCC_ROOT/releases/agy/$HCC_VERSION-$HCC_DIGEST-$HCC_MODE-${engine_key:0:12}"
    if [[ -e "$release" || -L "$release" ]]; then
        [[ -d "$release" && ! -L "$release" && ! -L "$release/binary" && $(hcc_hash "$release/binary") == "$HCC_DIGEST" && ! -L "$release/selection" ]] || hcc_die 'Existing private release changed.'
        printf '%s\n' "$release/binary" "$HCC_MODE" "$HCC_QEMU" | cmp -s -- - "$release/selection" || hcc_die 'Existing release selection changed.'
    else
        mkdir -- "$WSTAGE/release"
        cp -- "$WSTAGE/verified/binary" "$WSTAGE/release/binary"
        chmod 700 -- "$WSTAGE/release/binary"
        [[ $(hcc_hash "$WSTAGE/release/binary") == "$HCC_DIGEST" ]] || hcc_die 'Prepared release copy changed.'
        printf '%s\n' "$release/binary" "$HCC_MODE" "$HCC_QEMU" > "$WSTAGE/release/selection"
        printf '%s\n' "$HCC_DIGEST" > "$WSTAGE/release/sha256"
        printf '%s\n' "$HCC_VERSION" > "$WSTAGE/release/version"
        mv -T -- "$WSTAGE/release" "$release"
    fi
    [[ -f "$release/version" && ! -L "$release/version" && $(< "$release/version") == "$HCC_VERSION" ]] || hcc_die 'Release version metadata missing or changed.'
    hcc_watch_prepare_slot "$entry" "$release"; WPRIMARY_SLOT=$WSLOT
    hcc_watch_prepare_slot "$alias" "$release"; WALIAS_SLOT=$WSLOT
    desired=$(hcc_fingerprint "$WPRIMARY_SLOT/prepared")
    [[ $(hcc_fingerprint "$WALIAS_SLOT/prepared") == "$desired" ]] || hcc_die 'Prepared launchers differ.'
    printf '%s\n' "$WSTAGE" "$old_current" "$WPRIMARY_SLOT" "$WALIAS_SLOT" "$release" "$intended" "$alias_expected" "$desired" > "$WSTAGE/journal"
    ln -T -- "$WSTAGE/journal" "$WDIR/pending" || hcc_die 'Cannot create exclusive watcher recovery journal.'
    hcc_watch_publish "$entry" "$WPRIMARY_SLOT" "$intended"
    hcc_watch_publish "$alias" "$WALIAS_SLOT" "$alias_expected"
    # Both entry publications succeeded; current selection is sufficient state.
    ln -s -- "$release" "$directory/current.watch-new.$$"
    mv -Tf -- "$directory/current.watch-new.$$" "$directory/current"
    if [[ $(hcc_fingerprint "$WPRIMARY_SLOT/captured") == "$intended" ]]; then rm -rf -- "$WPRIMARY_SLOT";
    else cp -- "$WSTAGE/journal" "$WPRIMARY_SLOT/journal"; hcc_log 'Changed captured vendor bytes retained for deliberate recovery.'; fi
    if [[ $(hcc_fingerprint "$WALIAS_SLOT/captured") == "$alias_expected" ]]; then rm -rf -- "$WALIAS_SLOT";
    else cp -- "$WSTAGE/journal" "$WALIAS_SLOT/journal"; hcc_log 'Changed captured alias retained for deliberate recovery.'; fi
    rm -- "$WDIR/pending"
    hcc_log "AGY watcher repaired version=$HCC_VERSION mode=$HCC_MODE sha256=$HCC_DIGEST. Reload/reconnect may still be necessary."
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    [[ $# == 3 && $1 == --reconcile ]] || { printf 'Private watcher entry point: --reconcile STATE HOME\n' >&2; exit 64; }
    HCC_SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
    source "$HCC_SOURCE/lib/common.sh"
    export HCC_STATE_DIR=$2 HOME=$3
    umask 077
    hcc_watch_reconcile
fi
