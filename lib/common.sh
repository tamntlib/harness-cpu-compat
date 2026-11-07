#!/usr/bin/env bash
# Shared implementation for the two public Shell entry points.
set -euo pipefail
hcc_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
hcc_log() { printf '%s\n' "$*" >&2; }
hcc_need() { command -v "$1" >/dev/null 2>&1 || hcc_die "Missing dependency: $1 (install it separately)."; }
hcc_valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][A-Za-z0-9.-]+)?$ ]]; }
hcc_plain_path() { [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }
hcc_hash() { local line; line=$(sha256sum < "$1"); printf '%s\n' "${line%% *}"; }
hcc_fingerprint() {
    local p=$1
    if [[ -L "$p" ]]; then printf 'link:%s\n' "$(readlink -- "$p")";
    elif [[ -f "$p" ]]; then printf 'file:%s\n' "$(hcc_hash "$p")";
    elif [[ -e "$p" ]]; then hcc_die "Not a regular file/symlink: $p";
    else printf 'absent\n'; fi
}
hcc_paths() {
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || hcc_die 'Only Linux x86_64 is supported.'
    hcc_plain_path "$HOME" || hcc_die 'HOME must be an absolute single-line path.'
    HCC_USER_HOME=$(realpath -m -- "$HOME")
    HCC_ROOT=$(realpath -m -- "${HCC_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness-cpu-compat}")
    hcc_plain_path "$HCC_ROOT" || hcc_die 'Invalid state directory.'
    [[ "$HCC_ROOT" == "$HCC_USER_HOME/"* && "$HCC_ROOT" != "$HCC_USER_HOME/.local/bin" && "$HCC_ROOT" != "$HCC_USER_HOME/.gemini/bin" ]] || hcc_die 'State must be a dedicated directory inside HOME.'
    [[ ! -e "$HCC_ROOT" || ( -d "$HCC_ROOT" && -O "$HCC_ROOT" && ! -L "$HCC_ROOT" ) ]] || hcc_die 'State directory must be owned and not a symlink.'
    local directory tool metadata resolved
    for directory in "$HCC_ROOT"/{tools,releases,program,program/lib,staging}; do
        [[ ! -L "$directory" && ( ! -e "$directory" || ( -d "$directory" && -O "$directory" ) ) ]] || hcc_die "Unsafe state directory: $directory"
    done
    for tool in claude agy; do
        for directory in "$HCC_ROOT/tools/$tool" "$HCC_ROOT/releases/$tool"; do
            [[ ! -L "$directory" && ( ! -e "$directory" || ( -d "$directory" && -O "$directory" ) ) ]] || hcc_die "Unsafe tool directory: $directory"
        done
        for metadata in "$HCC_ROOT/tools/$tool/pending"; do
            [[ ! -L "$metadata" && ( ! -e "$metadata" || ( -f "$metadata" && -O "$metadata" ) ) ]] || hcc_die "Unsafe state file: $metadata"
        done
        if [[ -e "$HCC_ROOT/tools/$tool/current" || -L "$HCC_ROOT/tools/$tool/current" ]]; then
            resolved=$(realpath -m -- "$HCC_ROOT/tools/$tool/current")
            [[ -L "$HCC_ROOT/tools/$tool/current" && "$resolved" == "$HCC_ROOT/releases/$tool/"* ]] || hcc_die 'Selected release escapes its store.'
        fi
    done
    metadata="$HCC_ROOT/operation.lock"
    [[ ! -L "$metadata" && ( ! -e "$metadata" || ( -f "$metadata" && -O "$metadata" ) ) ]] || hcc_die 'Unsafe operation lock.'
}
hcc_entry() { case "$1" in claude) printf '%s/.local/bin/claude\n' "$HOME";; agy) printf '%s/.gemini/bin/agy\n' "$HOME";; esac; }
hcc_check_parent() {
    local p=$1 parent
    parent=$(realpath -m -- "$(dirname -- "$p")")
    [[ "$parent" == "$HCC_USER_HOME/"* ]] || hcc_die "Destination escapes HOME: $p"
    while [[ ! -e "$parent" ]]; do parent=$(dirname -- "$parent"); done
    [[ -d "$parent" && -O "$parent" && -w "$parent" ]] || hcc_die "Destination parent is not owned/writable: $p"
    [[ ! -e "$p" && ! -L "$p" || -O "$p" ]] || hcc_die "Destination is not owned: $p"
}
hcc_tool_dir() { printf '%s/tools/%s\n' "$HCC_ROOT" "$1"; }
hcc_snapshot() {
    local entry=$1 destination=$2
    mkdir -m 700 -p -- "$destination"
    hcc_fingerprint "$entry" > "$destination/fingerprint"
    if [[ -e "$entry" || -L "$entry" ]]; then cp -a -- "$entry" "$destination/entry"; fi
}
hcc_verify_snapshot() {
    local saved=$1
    [[ -f "$saved/fingerprint" && ! -L "$saved/fingerprint" && $(hcc_fingerprint "$saved/entry") == "$(< "$saved/fingerprint")" ]] || hcc_die "Recovery snapshot changed: $saved"
}
hcc_restore() {
    local saved=$1 entry=$2 temporary
    hcc_verify_snapshot "$saved"
    if [[ -e "$saved/entry" || -L "$saved/entry" ]]; then
        temporary="${entry}.hcc-restore.$$"
        [[ ! -e "$temporary" && ! -L "$temporary" ]] || hcc_die 'Unexpected restore temporary file.'
        cp -a -- "$saved/entry" "$temporary" || { hcc_log 'Restore copy failed; original entry was not replaced.'; return 1; }
        [[ $(hcc_fingerprint "$temporary") == "$(< "$saved/fingerprint")" ]] || { hcc_log 'Restore copy fingerprint mismatch; original entry was not replaced.'; return 1; }
        mv -Tf -- "$temporary" "$entry" || return 1
    else rm -f -- "$entry" || return 1; fi
}
hcc_download() {
    local url=$1 destination=$2
    [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* ]] || hcc_die 'Downloads require HTTPS.'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --retry 2 --output "$destination" "$url"
}
hcc_acquire() {
    local tool=$1 stage=$2 version=$3 from=$4 digest=$5 base url expected actual payload member listing
    if [[ -n "$from" ]]; then
        hcc_valid_version "$version" || hcc_die 'Local import requires --version X.Y.Z.'
        [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || hcc_die 'Local import requires --sha256 DIGEST.'
        [[ -f "$from" && ! -L "$from" ]] || hcc_die 'Import must be a regular binary file, not a symlink.'
        cp -- "$from" "$stage/binary"
        [[ $(hcc_hash "$stage/binary") == "${digest,,}" ]] || hcc_die 'Local binary checksum mismatch.'
        HCC_VERSION=$version
    elif [[ "$tool" == claude ]]; then
        base=https://downloads.claude.ai/claude-code-releases
        if [[ "$version" == latest || "$version" == stable ]]; then
            hcc_download "$base/$version" "$stage/channel"
            version=$(< "$stage/channel")
        fi
        hcc_valid_version "$version" || hcc_die 'Invalid Claude version.'
        hcc_download "$base/$version/manifest.json" "$stage/manifest.json"
        expected=$(jq -er --arg version "$version" 'select(.version == $version) | .platforms["linux-x64"].checksum | strings' "$stage/manifest.json") || hcc_die 'Invalid Claude manifest.'
        [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || hcc_die 'Claude checksum missing/invalid.'
        hcc_download "$base/$version/linux-x64/claude" "$stage/binary"
        [[ $(hcc_hash "$stage/binary") == "${expected,,}" ]] || hcc_die 'Claude checksum mismatch.'
        HCC_VERSION=$version
    else
        base=https://antigravity-cli-auto-updater-974169037036.us-central1.run.app
        hcc_download "$base/manifests/linux_amd64.json" "$stage/manifest.json"
        HCC_VERSION=$(jq -er '.version | strings' "$stage/manifest.json") || hcc_die 'AGY version missing.'
        hcc_valid_version "$HCC_VERSION" || hcc_die 'Invalid AGY manifest version.'
        [[ "$version" == latest || "$version" == "$HCC_VERSION" ]] || hcc_die 'AGY feed only offers its current release; use --version latest.'
        url=$(jq -er '.url | strings' "$stage/manifest.json") || hcc_die 'AGY artifact URL missing.'
        expected=$(jq -er '.sha512 | strings' "$stage/manifest.json") || hcc_die 'AGY checksum missing.'
        [[ "$expected" =~ ^[a-fA-F0-9]{128}$ ]] || hcc_die 'Invalid AGY checksum.'
        [[ "$url" == https://storage.googleapis.com/antigravity-public/* || "$url" == "$base/"* ]] || hcc_die 'Unexpected AGY artifact host/path.'
        payload="$stage/payload"
        hcc_download "$url" "$payload"
        actual=$(sha512sum < "$payload"); actual=${actual%% *}
        [[ "$actual" == "${expected,,}" ]] || hcc_die 'AGY checksum mismatch.'
        case "$url" in
            *.tar.gz|*.tgz)
                listing=$(tar -tzf "$payload") || hcc_die 'Invalid AGY archive.'
                case "$listing" in antigravity|agy|cli) member=$listing;; *) hcc_die 'Unsupported AGY archive layout; expected one executable.';; esac
                listing=$(tar -tvzf "$payload") || hcc_die 'Cannot inspect AGY archive.'
                [[ "$listing" == -* && "$listing" != *$'\n'* ]] || hcc_die 'Archive member must be one regular file.'
                tar -xOzf "$payload" -- "$member" > "$stage/binary";;
            *) cp -- "$payload" "$stage/binary";;
        esac
    fi
    chmod 700 -- "$stage/binary"
    HCC_DIGEST=$(hcc_hash "$stage/binary")
}
hcc_probe_command() {
    local stage=$1 flag=$2; shift 2
    (
        ulimit -c 0
        cd -- "$stage/probe-home"
        timeout --signal=TERM --kill-after=2s "${HCC_PROBE_TIMEOUT:-20}s" \
            env -i HOME="$stage/probe-home" XDG_CONFIG_HOME="$stage/probe-home/config" \
            XDG_CACHE_HOME="$stage/probe-home/cache" TMPDIR="$stage/probe-home" \
            PATH="$PATH" LANG=C TERM=dumb "$@" "$flag" < /dev/null
    ) > "$stage/probe-output" 2> "$stage/probe-error"
}
hcc_probe_pair() {
    local stage=$1; shift
    hcc_probe_command "$stage" --version "$@" || return 1
    local reported
    reported=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$stage/probe-output" | head -n 1) || return 1
    [[ "$reported" == "${HCC_VERSION%%[-+]*}" ]] || return 1
    hcc_probe_command "$stage" --help "$@"
}
hcc_install_qemu() {
    command -v apt-get >/dev/null 2>&1 || hcc_die 'Automatic QEMU installation requires APT (Debian/Ubuntu); install qemu-user manually on this system.'
    local privilege=()
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 || hcc_die 'Installing qemu-user requires sudo or root; install it manually, then rerun as the intended user.'
        privilege=(sudo --)
    fi
    hcc_log 'QEMU is missing: installing system package qemu-user through APT. Sudo may ask for your password.'
    hcc_log 'System package changes are retained even if a later application install fails; uninstall.sh does not remove QEMU.'
    # Package scripts must not inherit this installation's management/operation locks.
    ( umask 022; "${privilege[@]}" apt-get update ) 8>&- 9>&- || hcc_die 'APT update failed (including possible sudo authentication failure); the current tool was not published.'
    ( umask 022; "${privilege[@]}" apt-get install -y --no-install-recommends --reinstall qemu-user ) 8>&- 9>&- || hcc_die 'APT qemu-user installation failed; the current tool was not published.'
}
hcc_probe() {
    local stage=$1 requested=$2 qemu=$3 allow_package_install=${4:-0}
    mkdir -m 700 -- "$stage/probe-home"
    if [[ "$requested" != qemu ]]; then
        if hcc_probe_pair "$stage" "$stage/binary"; then HCC_MODE=native; HCC_QEMU=; return; fi
        [[ "$requested" != native ]] || hcc_die 'Native version/help probe failed; nothing selected.'
        hcc_log 'Native version/help probe failed. Trying QEMU; this alone does not identify the exact CPU fault.'
    fi
    if [[ -z "$qemu" ]]; then
        qemu=$(command -v qemu-x86_64 || true)
        if [[ ( -z "$qemu" || ! -x "$qemu" ) && "$allow_package_install" == 1 ]]; then
            hcc_install_qemu
            hash -r
            qemu=$(command -v qemu-x86_64 || true)
        fi
    fi
    [[ -n "$qemu" && -x "$qemu" ]] || hcc_die 'QEMU is required for emulation; install qemu-user or rerun the foreground installer without an invalid --qemu override.'
    HCC_QEMU=$(realpath -- "$qemu")
    hcc_plain_path "$HCC_QEMU" || hcc_die 'Invalid QEMU path.'
    hcc_probe_pair "$stage" "$HCC_QEMU" -cpu max "$stage/binary" || hcc_die 'QEMU version/help probe failed; nothing selected.'
    HCC_MODE=qemu
}
hcc_copy_program() {
    local relative source destination temporary
    for relative in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do
        source="$HCC_SOURCE/$relative"; destination="$HCC_ROOT/program/$relative"
        mkdir -m 700 -p -- "$(dirname -- "$destination")"
        if [[ -f "$destination" ]] && cmp -s -- "$source" "$destination"; then continue; fi
        temporary="${destination}.tmp.$$"
        cp -- "$source" "$temporary"; chmod 700 -- "$temporary"; mv -Tf -- "$temporary" "$destination"
    done
}
hcc_render_launcher() {
    local tool=$1 generation=${2:-}
    if [[ -n "$generation" ]]; then
        printf '#!/usr/bin/env bash\n# harness-cpu-compat immutable AGY generation\n'
        printf 'exec /bin/bash %q --generation %q %q %q "$@"\n' "$HCC_ROOT/program/lib/runtime.sh" "$HCC_ROOT" "$tool" "$generation"
    else
        printf '#!/usr/bin/env bash\n# harness-cpu-compat managed launcher v1\n'
        printf 'exec /bin/bash %q %q %q "$@"\n' "$HCC_ROOT/program/lib/runtime.sh" "$HCC_ROOT" "$tool"
    fi
}
hcc_write_launcher() {
    hcc_render_launcher "$2" > "$1"
    chmod 700 -- "$1"
    bash -n "$1"
}
hcc_is_managed() {
    local entry=$1 tool=$2 release=$3
    if [[ -L "$entry" ]]; then
        [[ $(readlink -- "$entry") == "$release/binary" ]]
    elif [[ -f "$entry" ]]; then
        cmp -s -- "$entry" <(hcc_render_launcher "$tool") ||
            cmp -s -- "$entry" <(hcc_render_launcher "$tool" "$release")
    else return 1; fi
}
hcc_is_independent_native() {
    local entry=$1 resolved
    [[ -f "$entry" && -x "$entry" ]] || return 1
    resolved=$(realpath -e -- "$entry") || return 1
    [[ "$resolved" != "$HCC_ROOT/"* ]] || return 1
    # Do not classify arbitrary scripts as independent of HCC state.
    [[ $(head -c 4 -- "$entry") == $'\177ELF' ]]
}
hcc_readonly() {
    local tool entry directory
    for tool in "${HCC_TOOLS[@]}"; do
        entry=$(hcc_entry "$tool"); directory=$(hcc_tool_dir "$tool")
        printf '%s: entry=%s\n' "$tool" "$entry"
        [[ ! -e "$directory/pending" ]] || printf '  INCOMPLETE publication; preserve transaction recovery.\n'
        if [[ -L "$directory/current" ]]; then
            hcc_selected "$tool"
            if hcc_is_managed "$entry" "$tool" "$SELECT_RELEASE"; then printf '  managed entry intact\n';
            else printf '  CONFLICT: entry replaced; explicit --repair required\n'; fi
            if [[ "$tool" == agy ]] && ! hcc_is_managed "$HOME/.local/bin/agy" agy "$SELECT_RELEASE"; then printf '  CONFLICT: CLI alias replaced\n'; fi
            printf '  selection: %s %s %s\n' "$SELECT_BINARY" "$SELECT_MODE" "$SELECT_QEMU"
            printf '  binary checksum intact\n'
        else printf '  not managed\n'; fi
    done
    for tool in "${HCC_TOOLS[@]}"; do [[ "$tool" != agy ]] || hcc_watch_report; done
    printf 'QEMU: %s\n' "$(command -v qemu-x86_64 || printf 'not found')"
    printf 'AGY IDE: experimental; its updater can replace the wrapper before execution.\n'
}
hcc_check_existing() {
    local tool=$1 directory entry alias
    directory=$(hcc_tool_dir "$tool"); entry=$(hcc_entry "$tool")
    [[ ! -e "$directory/pending" && ! -L "$directory/pending" ]] || hcc_die "Incomplete publication: $directory/pending; preserve transaction recovery."
    [[ "$tool" != agy || ! -e "$HCC_ROOT/watch/pending" ]] || hcc_die 'Incomplete watcher repair; preserve recovery material.'
    hcc_check_parent "$entry"
    if [[ "$tool" == agy ]]; then
        local claim="$HOME/.gemini/bin/.hcc-watch-owner"
        if [[ -e "$claim" || -L "$claim" ]]; then
            [[ -f "$claim" && ! -L "$claim" && -O "$claim" && "$(< "$claim")" == "$HCC_ROOT" ]] || hcc_die 'Another state directory or unsafe claim owns the AGY watcher.'
        fi
        alias="$HOME/.local/bin/agy"; hcc_check_parent "$alias"
    fi
    if [[ -L "$directory/current" ]]; then
        hcc_selected "$tool"
        if ! hcc_is_managed "$entry" "$tool" "$SELECT_RELEASE"; then
            [[ "$HCC_REPAIR" == 1 ]] || hcc_die "$tool entry changed outside this tool; close IDE sessions and use --repair."
        fi
        if [[ "$tool" == agy ]]; then
            hcc_is_managed "$alias" agy "$SELECT_RELEASE" || hcc_die 'AGY CLI alias changed outside this tool.'
        fi
    elif [[ -f "$entry" ]] && grep -aq '^# harness-cpu-compat' "$entry"; then
        hcc_die 'An unrecognized HCC launcher exists; preserve its state and resolve ownership first.'
    fi
}
hcc_install_tool() {
    local tool=$1 directory entry stage release preimage alias alias_preimage old_current transaction engine_key
    directory=$(hcc_tool_dir "$tool"); entry=$(hcc_entry "$tool")
    hcc_check_existing "$tool"
    preimage=$(hcc_fingerprint "$entry")
    alias="$HOME/.local/bin/agy"; alias_preimage=
    [[ "$tool" != agy ]] || alias_preimage=$(hcc_fingerprint "$alias")
    stage=$(mktemp -d "$HCC_ROOT/staging/$tool.XXXXXX")
    HCC_STAGE=$stage
    hcc_acquire "$tool" "$stage" "$HCC_REQUEST_VERSION" "$HCC_FROM" "$HCC_EXPECTED"
    hcc_probe "$stage" "$HCC_REQUEST_MODE" "$HCC_REQUEST_QEMU" 1
    engine_key=$(printf '%s\n' "$HCC_MODE" "$HCC_QEMU" | sha256sum); engine_key=${engine_key%% *}
    release="$HCC_ROOT/releases/$tool/$HCC_VERSION-$HCC_DIGEST-$HCC_MODE-${engine_key:0:12}"
    if [[ -e "$release" ]]; then
        [[ -d "$release" && ! -L "$release" && $(hcc_hash "$release/binary") == "$HCC_DIGEST" ]] || hcc_die 'Existing release changed; refusing to overwrite it.'
    else
        mkdir -m 700 -p -- "$(dirname -- "$release")"
        mkdir -m 700 -- "$stage/release"
        cp -- "$stage/binary" "$stage/release/binary"; chmod 700 "$stage/release/binary"
        printf '%s\n' "$release/binary" "$HCC_MODE" "$HCC_QEMU" > "$stage/release/selection"
        printf '%s\n' "$HCC_DIGEST" > "$stage/release/sha256"
        printf '%s\n' "$HCC_VERSION" > "$stage/release/version"
        mv -T -- "$stage/release" "$release"
    fi
    [[ -f "$release/version" && ! -L "$release/version" && $(< "$release/version") == "$HCC_VERSION" ]] || hcc_die 'Release version metadata missing or changed.'
    hcc_copy_program
    mkdir -m 700 -p -- "$directory" "$(dirname -- "$entry")"
    if [[ "$HCC_MODE" == native ]]; then ln -s -- "$release/binary" "$stage/launcher";
    else hcc_write_launcher "$stage/launcher" "$tool"; fi
    [[ $(hcc_fingerprint "$entry") == "$preimage" ]] || hcc_die 'Entry changed during installation; refusing publication.'
    if [[ "$tool" == agy ]]; then
        [[ $(hcc_fingerprint "$alias") == "$alias_preimage" ]] || hcc_die 'CLI alias changed during installation.'
    fi
    old_current=$(readlink -- "$directory/current" 2>/dev/null || true)
    transaction="$stage/transaction"; mkdir -- "$transaction"
    hcc_snapshot "$entry" "$transaction/entry"
    [[ "$tool" != agy ]] || hcc_snapshot "$alias" "$transaction/alias"
    # EXIT rollback also handles a failed publication; SIGKILL remains recoverable from retained state.
    HCC_TX_DIR=$transaction; HCC_TX_TOOL=$tool; HCC_TX_OLD=$old_current
    HCC_TX_EXPECTED=$(hcc_fingerprint "$stage/launcher")
    printf '%s\n' "$transaction" "$old_current" > "$directory/pending.new.$$"
    mv -Tf -- "$directory/pending.new.$$" "$directory/pending"
    HCC_TX_ACTIVE=1
    ln -s -- "$release" "$directory/current.new.$$"; mv -Tf -- "$directory/current.new.$$" "$directory/current"
    cp -a -- "$stage/launcher" "${entry}.hcc-new.$$"; mv -Tf -- "${entry}.hcc-new.$$" "$entry"
    if [[ "$tool" == agy ]]; then
        mkdir -m 700 -p -- "$(dirname -- "$alias")"
        cp -a -- "$stage/launcher" "${alias}.hcc-new.$$"; mv -Tf -- "${alias}.hcc-new.$$" "$alias"
        [[ $(hcc_fingerprint "$alias") == "$HCC_TX_EXPECTED" ]] || hcc_die 'CLI alias changed during publication.'
    fi
    [[ $(hcc_fingerprint "$entry") == "$HCC_TX_EXPECTED" ]] || hcc_die 'Entry changed during publication.'
    rm -- "$directory/pending"
    HCC_TX_ACTIVE=0
    hcc_log "$tool installed: version=$HCC_VERSION mode=$HCC_MODE sha256=$HCC_DIGEST"
    rm -rf -- "$stage"; HCC_STAGE=
}
hcc_cleanup() {
    local status=$? directory entry alias
    trap - EXIT
    if [[ ${HCC_TX_ACTIVE:-0} == 1 ]]; then
        directory=$(hcc_tool_dir "$HCC_TX_TOOL"); entry=$(hcc_entry "$HCC_TX_TOOL")
        if (
            # An independent vendor updater is not covered by our lock. Never overwrite its drift.
            actual=$(hcc_fingerprint "$entry")
            [[ "$actual" == "$HCC_TX_EXPECTED" || "$actual" == "$(< "$HCC_TX_DIR/entry/fingerprint")" ]] || exit 1
            if [[ "$HCC_TX_TOOL" == agy ]]; then
                alias="$HOME/.local/bin/agy"; actual=$(hcc_fingerprint "$alias")
                [[ "$actual" == "$HCC_TX_EXPECTED" || "$actual" == "$(< "$HCC_TX_DIR/alias/fingerprint")" ]] || exit 1
            fi
            hcc_restore "$HCC_TX_DIR/entry" "$entry" || exit 1
            if [[ "$HCC_TX_TOOL" == agy ]]; then hcc_restore "$HCC_TX_DIR/alias" "$alias" || exit 1; fi
            if [[ -n "$HCC_TX_OLD" ]]; then
                ln -s -- "$HCC_TX_OLD" "$directory/current.rollback.$$" && mv -Tf -- "$directory/current.rollback.$$" "$directory/current" || exit 1
            else rm -f -- "$directory/current" || exit 1; fi
            rm -- "$directory/pending" || exit 1
        ); then hcc_log 'Publication failed; rolled back owned entries. Recovery snapshots retained.'
        else hcc_log 'Publication failed with drift or recovery failure; no further overwrite. Pending marker and recovery snapshots retained.'; fi
    elif [[ -n ${HCC_STAGE:-} && -d "$HCC_STAGE" ]]; then rm -rf -- "$HCC_STAGE"; fi
    if [[ ${HCC_WATCH_CLAIM_NEW:-0} == 1 && ! -e "$HCC_ROOT/watch/enabled" ]]; then
        local claim="$HOME/.gemini/bin/.hcc-watch-owner"
        if [[ -f "$claim" && ! -L "$claim" && $(< "$claim") == "$HCC_ROOT" ]]; then rm -- "$claim"; fi
    fi
    exit "$status"
}
hcc_selected() {
    local tool=$1 path metadata
    path="$HCC_ROOT/tools/$tool/current"
    [[ -L "$path" ]] || hcc_die 'Selected release is missing.'
    SELECT_RELEASE=$(realpath -e -- "$path")
    [[ "$SELECT_RELEASE" == "$HCC_ROOT/releases/$tool/"* && ! -L "$SELECT_RELEASE" ]] || hcc_die 'Selected release escapes its store.'
    for metadata in binary sha256 selection version; do
        [[ -f "$SELECT_RELEASE/$metadata" && ! -L "$SELECT_RELEASE/$metadata" && -O "$SELECT_RELEASE/$metadata" ]] || hcc_die 'Selected release metadata is missing or unsafe.'
    done
    SELECT_BINARY="$SELECT_RELEASE/binary"
    SELECT_DIGEST=$(< "$SELECT_RELEASE/sha256")
    SELECT_VERSION=$(< "$SELECT_RELEASE/version")
    [[ "$SELECT_DIGEST" =~ ^[a-f0-9]{64}$ && -x "$SELECT_BINARY" && $(hcc_hash "$SELECT_BINARY") == "$SELECT_DIGEST" ]] || hcc_die 'Selected binary checksum changed.'
    hcc_valid_version "$SELECT_VERSION" || hcc_die 'Selected version is invalid.'
    local -a selection
    mapfile -t selection < "$SELECT_RELEASE/selection"
    [[ ${#selection[@]} == 3 && ${selection[0]} == "$SELECT_BINARY" ]] || hcc_die 'Selected execution metadata changed.'
    SELECT_MODE=${selection[1]}; SELECT_QEMU=${selection[2]}
    case "$SELECT_MODE" in native) [[ -z "$SELECT_QEMU" ]] || hcc_die 'Invalid native selection.';; qemu) hcc_plain_path "$SELECT_QEMU" || hcc_die 'Invalid emulator selection.';; *) hcc_die 'Invalid selection mode.';; esac
    local engine_key
    engine_key=$(printf '%s\n' "$SELECT_MODE" "$SELECT_QEMU" | sha256sum); engine_key=${engine_key%% *}
    [[ "$SELECT_RELEASE" == "$HCC_ROOT/releases/$tool/$SELECT_VERSION-$SELECT_DIGEST-$SELECT_MODE-${engine_key:0:12}" ]] || hcc_die 'Selected version, checksum or execution metadata does not match its release.'
}
hcc_native_parent() {
    local parent
    hcc_check_parent "$1"
    parent=$(realpath -m -- "$(dirname -- "$1")")
    [[ "$parent" != "$HCC_ROOT" && "$parent" != "$HCC_ROOT/"* ]] || hcc_die 'Native destination still depends on HCC state.'
}
hcc_native_slot() {
    local entry=$1 source=$2 expected=$3 parent
    hcc_native_parent "$entry"
    mkdir -m 700 -p -- "$(dirname -- "$entry")"
    parent=$(realpath -e -- "$(dirname -- "$entry")")
    NATIVE_SLOT=$(mktemp -d "$parent/.hcc-watch-recovery.XXXXXX")
    printf '%s\n' "$entry" "$NATIVE_SLOT" >> "$NATIVE_JOURNAL"
    cp -- "$source" "$NATIVE_SLOT/prepared" || hcc_die 'Cannot prepare native executable; retain pending recovery.'
    chmod 755 -- "$NATIVE_SLOT/prepared"
    [[ $(hcc_hash "$NATIVE_SLOT/prepared") == "$expected" ]] || hcc_die 'Native executable copy checksum mismatch; retain pending recovery.'
}
hcc_native_link_slot() {
    local parent
    hcc_native_parent "$1"
    mkdir -m 700 -p -- "$(dirname -- "$1")"
    parent=$(realpath -e -- "$(dirname -- "$1")")
    NATIVE_SLOT=$(mktemp -d "$parent/.hcc-watch-recovery.XXXXXX")
    printf '%s\n' "$1" "$NATIVE_SLOT" >> "$NATIVE_JOURNAL"
    ln -s -- "$2" "$NATIVE_SLOT/prepared"
}
hcc_native_publish() {
    hcc_watch_publish "$1" "$2" "$3" || hcc_die 'Native publication failed; preserve pending recovery.'
}
hcc_native_cleanup_slot() {
    local slot=$1 expected=$2
    [[ $(hcc_fingerprint "$slot/captured") == "$expected" ]] || hcc_die 'Captured entry changed; preserve pending recovery.'
    rm -rf -- "$slot"
}
hcc_uninstall_tool() {
    local tool=$1 directory entry alias primary_before alias_before stage primary_slot= alias_slot= native= primary_needed=0 alias_needed=0 canonical_slot=
    directory=$(hcc_tool_dir "$tool"); entry=$(hcc_entry "$tool"); alias="$HOME/.local/bin/agy"
    [[ ! -e "$directory/pending" && ! -L "$directory/pending" ]] || hcc_die 'Incomplete publication; preserve recovery material.'
    [[ -L "$directory/current" ]] || { hcc_log "$tool is not managed; unchanged."; return; }
    hcc_selected "$tool"
    hcc_native_parent "$entry"
    [[ "$tool" != agy || ! -e "$HCC_ROOT/watch/pending" ]] || hcc_die 'Incomplete watcher repair; preserve recovery material.'
    primary_before=$(hcc_fingerprint "$entry")
    if [[ "$primary_before" == absent ]] || hcc_is_managed "$entry" "$tool" "$SELECT_RELEASE"; then primary_needed=1;
    else hcc_is_independent_native "$entry" || hcc_die 'Unknown entry; refusing native handoff or state deletion.'; fi
    if [[ "$tool" == agy ]]; then
        hcc_native_parent "$alias"
        alias_before=$(hcc_fingerprint "$alias")
        if [[ "$alias_before" == absent ]] || hcc_is_managed "$alias" agy "$SELECT_RELEASE"; then alias_needed=1;
        else hcc_is_independent_native "$alias" || hcc_die 'Unknown alias; refusing native handoff or state deletion.'; fi
    elif (( primary_needed )); then
        native="$HOME/.local/share/claude/versions/$SELECT_VERSION"
        hcc_native_parent "$native"
        if [[ -e "$native" || -L "$native" ]]; then
            [[ -f "$native" && ! -L "$native" && -x "$native" && $(hcc_hash "$native") == "$SELECT_DIGEST" ]] || hcc_die 'Canonical Claude version already exists with different bytes.'
        fi
    fi
    stage=$(mktemp -d "$HCC_ROOT/staging/uninstall.$tool.XXXXXX")
    printf '%s\n' native-uninstall "$stage" > "$stage/journal"
    ln -T -- "$stage/journal" "$directory/pending" || hcc_die 'Cannot reserve native handoff journal.'
    NATIVE_JOURNAL="$directory/pending"
    if [[ "$tool" == agy ]]; then
        if (( primary_needed )); then
            hcc_native_slot "$entry" "$SELECT_BINARY" "$SELECT_DIGEST"; primary_slot=$NATIVE_SLOT
        fi
        if (( alias_needed )); then
            hcc_native_link_slot "$alias" "$entry"; alias_slot=$NATIVE_SLOT
        fi
        if (( primary_needed )); then hcc_native_publish "$entry" "$primary_slot" "$primary_before"; fi
        if (( alias_needed )); then hcc_native_publish "$alias" "$alias_slot" "$alias_before"; fi
        if (( primary_needed )); then
            [[ -f "$entry" && ! -L "$entry" && $(hcc_hash "$entry") == "$SELECT_DIGEST" ]] || hcc_die 'Native AGY handoff changed; preserve recovery.'
        else [[ $(hcc_fingerprint "$entry") == "$primary_before" ]] || hcc_die 'Independent native entry changed; preserve recovery.'; fi
        if (( alias_needed )); then
            [[ -L "$alias" && $(readlink -- "$alias") == "$entry" ]] || hcc_die 'Native AGY alias changed; preserve recovery.'
        else [[ $(hcc_fingerprint "$alias") == "$alias_before" ]] || hcc_die 'Independent native alias changed; preserve recovery.'; fi
    elif (( primary_needed )); then
        if [[ ! -e "$native" ]]; then
            hcc_native_slot "$native" "$SELECT_BINARY" "$SELECT_DIGEST"; canonical_slot=$NATIVE_SLOT
            hcc_native_publish "$native" "$canonical_slot" absent
        fi
        hcc_native_link_slot "$entry" "$native"; alias_slot=$NATIVE_SLOT
        hcc_native_publish "$entry" "$alias_slot" "$primary_before"
        [[ $(hcc_hash "$native") == "$SELECT_DIGEST" && -L "$entry" && $(readlink -- "$entry") == "$native" ]] || hcc_die 'Native Claude handoff changed; preserve recovery.'
    else [[ $(hcc_fingerprint "$entry") == "$primary_before" ]] || hcc_die 'Independent native entry changed; preserve recovery.'; fi
    # Native paths and their resolved parents no longer depend on the HCC store.
    [[ $(realpath -e -- "$entry") != "$HCC_ROOT/"* ]] || hcc_die 'Entry still depends on HCC state.'
    [[ "$tool" != agy || $(realpath -e -- "$alias") != "$HCC_ROOT/"* ]] || hcc_die 'Alias still depends on HCC state.'
    [[ -z "$primary_slot" ]] || hcc_native_cleanup_slot "$primary_slot" "$primary_before"
    [[ -z "$canonical_slot" ]] || hcc_native_cleanup_slot "$canonical_slot" absent
    if [[ -n "$alias_slot" ]]; then
        if [[ "$tool" == agy ]]; then hcc_native_cleanup_slot "$alias_slot" "$alias_before";
        else hcc_native_cleanup_slot "$alias_slot" "$primary_before"; fi
    fi
    rm -rf -- "$directory" "$HCC_ROOT/releases/$tool" "$stage"
    hcc_log "$tool compatibility removed; current version retained in native layout. Native CPU compatibility is not guaranteed."
}
hcc_uninstall_shared_cleanup() {
    # Keep lock inodes stable for installers already waiting on them.
    if [[ ! -L "$HCC_ROOT/tools/agy/current" && ! -e "$HCC_ROOT/tools/agy/pending" && ! -e "$HCC_ROOT/watch/pending" && ! -e "$HCC_ROOT/watch/enabled" ]] &&
       [[ -e "$HCC_ROOT/watch/owned" || -L "$HCC_ROOT/watch/owned" ]]; then
        hcc_watch_init
        if (( ${#WRECORD[@]} )); then
            hcc_watch_validate_units
            rm -rf -- "$WDIR/units"
            rm -- "$WDIR/owned"
        fi
    fi
    if [[ ! -L "$HCC_ROOT/tools/claude/current" && ! -L "$HCC_ROOT/tools/agy/current" && ! -e "$HCC_ROOT/tools/claude/pending" && ! -e "$HCC_ROOT/tools/agy/pending" && ! -e "$HCC_ROOT/watch/pending" && ! -e "$HCC_ROOT/watch/enabled" ]]; then
        rm -rf -- "$HCC_ROOT/program"
    fi
}
