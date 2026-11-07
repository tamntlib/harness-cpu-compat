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
        for directory in "$HCC_ROOT/tools/$tool" "$HCC_ROOT/releases/$tool" "$HCC_ROOT/tools/$tool/"{original,alias-original,conflicts,history}; do
            [[ ! -L "$directory" && ( ! -e "$directory" || ( -d "$directory" && -O "$directory" ) ) ]] || hcc_die "Unsafe tool directory: $directory"
        done
        for metadata in "$HCC_ROOT/tools/$tool/"{installed,alias-installed,pending,original/fingerprint,alias-original/fingerprint}; do
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
hcc_write_launcher() {
    local destination=$1 tool=$2
    {
        printf '#!/usr/bin/env bash\n# harness-cpu-compat managed launcher v1\n'
        printf 'exec /bin/bash %q %q %q "$@"\n' "$HCC_ROOT/program/lib/runtime.sh" "$HCC_ROOT" "$tool"
    } > "$destination"
    chmod 700 -- "$destination"
    bash -n "$destination"
}
hcc_readonly() {
    local tool entry directory installed current fingerprint
    for tool in "${HCC_TOOLS[@]}"; do
        entry=$(hcc_entry "$tool"); directory=$(hcc_tool_dir "$tool")
        printf '%s: entry=%s\n' "$tool" "$entry"
        [[ ! -e "$directory/pending" ]] || printf '  INCOMPLETE publication; preserve recovery snapshots.\n'
        if [[ -f "$directory/installed" ]]; then
            installed=$(< "$directory/installed"); fingerprint=$(hcc_fingerprint "$entry")
            if [[ "$installed" == "$fingerprint" ]]; then printf '  managed entry intact\n'; else printf '  CONFLICT: entry replaced; explicit --repair required\n'; fi
            if [[ -L "$directory/current" && -f "$directory/current/selection" ]]; then
                printf '  selection: '; tr '\n' ' ' < "$directory/current/selection"; printf '\n'
                if [[ -f "$directory/current/binary" && -f "$directory/current/sha256" ]]; then
                    [[ $(hcc_hash "$directory/current/binary") == "$(< "$directory/current/sha256")" ]] && printf '  binary checksum intact\n' || printf '  CONFLICT: selected binary changed\n'
                fi
            fi
        else printf '  not managed\n'; fi
    done
    for tool in "${HCC_TOOLS[@]}"; do [[ "$tool" != agy ]] || hcc_watch_report; done
    printf 'QEMU: %s\n' "$(command -v qemu-x86_64 || printf 'not found')"
    printf 'AGY IDE: experimental; its updater can replace the wrapper before execution.\n'
}
hcc_check_existing() {
    local tool=$1 directory entry existing expected alias
    directory=$(hcc_tool_dir "$tool"); entry=$(hcc_entry "$tool")
    [[ ! -e "$directory/pending" && ! -L "$directory/pending" ]] || hcc_die "Incomplete publication: $directory/pending; preserve recovery snapshots and resolve it before retrying."
    [[ "$tool" != agy || ! -e "$HCC_ROOT/watch/pending" ]] || hcc_die 'Incomplete watcher repair; preserve recovery material.'
    hcc_check_parent "$entry"
    if [[ "$tool" == agy ]]; then
        local claim="$HOME/.gemini/bin/.hcc-watch-owner"
        if [[ -e "$claim" || -L "$claim" ]]; then
            [[ -f "$claim" && ! -L "$claim" && -O "$claim" && "$(< "$claim")" == "$HCC_ROOT" ]] || hcc_die 'Another state directory or unsafe claim owns the AGY watcher.'
        fi
    fi
    existing=$(hcc_fingerprint "$entry")
    if [[ -f "$directory/installed" ]]; then
        expected=$(< "$directory/installed")
        if [[ "$existing" != "$expected" ]]; then
            [[ "$HCC_REPAIR" == 1 ]] || hcc_die "$tool entry changed outside this tool; close IDE sessions and use --repair to preserve and replace it."
        fi
    fi
    if [[ "$tool" == agy ]]; then
        alias="$HOME/.local/bin/agy"; hcc_check_parent "$alias"
        existing=$(hcc_fingerprint "$alias")
        if [[ -f "$directory/alias-installed" ]]; then
            [[ "$existing" == "$(< "$directory/alias-installed")" ]] || hcc_die 'AGY CLI alias changed outside this tool.'
        fi
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
        mv -T -- "$stage/release" "$release"
    fi
    hcc_copy_program
    mkdir -m 700 -p -- "$directory" "$(dirname -- "$entry")"
    if [[ ! -f "$directory/installed" && -d "$directory/original" ]]; then
        mkdir -m 700 -p -- "$directory/history"
        mv -T -- "$directory/original" "$directory/history/original-$(date +%s)-$$"
        if [[ -d "$directory/alias-original" ]]; then
            mv -T -- "$directory/alias-original" "$directory/history/alias-$(date +%s)-$$"
        fi
    fi
    [[ -d "$directory/original" ]] || hcc_snapshot "$entry" "$directory/original"
    if [[ -f "$directory/installed" && "$preimage" != "$(< "$directory/installed")" ]]; then
        hcc_snapshot "$entry" "$directory/conflicts/$(date +%s)-$$"
    fi
    if [[ "$HCC_MODE" == native ]]; then ln -s -- "$release/binary" "$stage/launcher";
    else hcc_write_launcher "$stage/launcher" "$tool"; fi
    [[ $(hcc_fingerprint "$entry") == "$preimage" ]] || hcc_die 'Entry changed during installation; refusing publication.'
    if [[ "$tool" == agy ]]; then
        [[ $(hcc_fingerprint "$alias") == "$alias_preimage" ]] || hcc_die 'CLI alias changed during installation.'
        [[ -d "$directory/alias-original" ]] || hcc_snapshot "$alias" "$directory/alias-original"
    fi
    old_current=$(readlink -- "$directory/current" 2>/dev/null || true)
    transaction="$stage/transaction"; mkdir -- "$transaction"
    hcc_snapshot "$entry" "$transaction/entry"
    [[ "$tool" != agy ]] || hcc_snapshot "$alias" "$transaction/alias"
    # EXIT rollback also handles a failed publication; SIGKILL remains recoverable from retained state.
    hcc_snapshot "$directory/installed" "$transaction/installed"
    hcc_snapshot "$directory/alias-installed" "$transaction/alias-installed"
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
        printf '%s\n' "$HCC_TX_EXPECTED" > "$directory/alias-installed"
    fi
    [[ $(hcc_fingerprint "$entry") == "$HCC_TX_EXPECTED" ]] || hcc_die 'Entry changed during publication.'
    printf '%s\n' "$HCC_TX_EXPECTED" > "$directory/installed"
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
            hcc_restore "$HCC_TX_DIR/installed" "$directory/installed" || exit 1
            hcc_restore "$HCC_TX_DIR/alias-installed" "$directory/alias-installed" || exit 1
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
hcc_uninstall_tool() {
    local tool=$1 directory entry alias expected
    directory=$(hcc_tool_dir "$tool"); entry=$(hcc_entry "$tool"); alias="$HOME/.local/bin/agy"
    [[ ! -e "$directory/pending" && ! -L "$directory/pending" ]] || hcc_die "Incomplete publication: $directory/pending; recovery material retained."
    [[ -f "$directory/installed" ]] || { hcc_log "$tool is not managed; unchanged."; return; }
    hcc_check_parent "$entry"
    [[ "$tool" != agy ]] || hcc_check_parent "$alias"
    [[ "$tool" != agy || ! -e "$HCC_ROOT/watch/pending" ]] || hcc_die 'Incomplete watcher repair; preserve recovery material.'
    expected=$(< "$directory/installed")
    [[ $(hcc_fingerprint "$entry") == "$expected" ]] || hcc_die "$tool entry changed; refusing to overwrite it. Recovery data retained."
    if [[ "$tool" == agy && -f "$directory/alias-installed" ]]; then
        [[ $(hcc_fingerprint "$alias") == "$(< "$directory/alias-installed")" ]] || hcc_die 'AGY CLI alias changed; refusing uninstall.'
    fi
    [[ -d "$directory/original" ]] || hcc_die 'Original-entry record missing.'
    hcc_verify_snapshot "$directory/original"
    if [[ "$tool" == agy && -f "$directory/alias-installed" ]]; then hcc_verify_snapshot "$directory/alias-original"; fi
    hcc_restore "$directory/original" "$entry"
    if [[ "$tool" == agy && -f "$directory/alias-installed" ]]; then
        hcc_restore "$directory/alias-original" "$alias"; rm -- "$directory/alias-installed"
    fi
    rm -- "$directory/installed"
    hcc_log "$tool launchers restored. Downloaded binaries, backups, and user data were retained."
}
