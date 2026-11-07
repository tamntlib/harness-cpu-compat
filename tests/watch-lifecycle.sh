#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-lifecycle.XXXXXX")
pid=; disabler=
cleanup() { touch "$work/release"; [[ -z "$pid" ]] || wait "$pid" || true; [[ -z "$disabler" ]] || wait "$disabler" || true; rm -rf -- "$work"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
wf_init "$work/copy"
cat > "$work/copy/bin/cp" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}
if [[ ${HCC_BREAK_SNAPSHOT:-0} == 1 && "$last" == *'/watch/units/'* ]]; then printf 'partial snapshot\n' > "$last"; exit 18; fi
exec /usr/bin/cp "$@"
FIXTURE
chmod +x "$work/copy/bin/cp"
digest=$(sha256sum < "$work/copy/original-binary");digest=${digest%% *}
args=(--tool agy --from-binary "$work/copy/original-binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/copy/bin/qemu" --auto-repair --yes)
snapshots() { for file in "$root/watch/units/"*; do [[ -f "$file" ]] && printf '%s %s\n' "$(sha256sum < "$file")" "$file"; done; }
before=$(snapshots)
HCC_BREAK_SNAPSHOT=1 bash "$repo/install.sh" "${args[@]}" > "$work/copy/refresh.log" 2>&1 || true
[[ $(snapshots) == "$before" ]] || fail 're-enable I/O failure corrupted an existing watcher ownership baseline'
bash "$repo/install.sh" --tool agy --no-auto-repair --yes > "$work/copy/disable.log" 2>&1 || fail 'unit refresh failure stranded watcher disable'
# Concurrent install/disable or install/uninstall must serialize manager transitions, not only files.
for operation in disable uninstall; do
    wf_init "$work/$operation"
    export HCC_MANAGER_ACTIVE="$work/$operation/active" HCC_LOCK_ATTEMPT="$work/$operation/lock-attempt"
    touch "$HCC_MANAGER_ACTIVE"
    cat > "$work/$operation/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HCC_SYSTEMCTL_LOG"
case "$*" in
 *' disable --now '*) rm -f "$HCC_MANAGER_ACTIVE";;
 *' enable --now '*) touch "$HCC_MANAGER_ACTIVE";;
esac
FIXTURE
    cat > "$work/$operation/bin/flock" <<'FIXTURE'
#!/usr/bin/env bash
[[ ${HCC_IS_DISABLE:-0} != 1 ]] || touch "$HCC_LOCK_ATTEMPT"
exec /usr/bin/flock "$@"
FIXTURE
    cat > "$work/$operation/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}; previous=${@: -2:1}
if [[ ${HCC_HOLD_INSTALL:-0} == 1 && "$last" == "$HOME/.gemini/bin/agy" && "$previous" == *'.hcc-new.'* ]]; then
 touch "$HCC_INSTALL_READY"
 for ((i=0;i<600;i++)); do [[ -f "$HCC_INSTALL_RELEASE" ]] && break; sleep .02; done
fi
exec /usr/bin/mv "$@"
FIXTURE
    chmod +x "$work/$operation/bin/"*
    digest=$(sha256sum < "$work/$operation/original-binary");digest=${digest%% *}
    args=(--tool agy --from-binary "$work/$operation/original-binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/$operation/bin/qemu" --auto-repair --yes)
    rm -f "$work/release"
    HCC_HOLD_INSTALL=1 HCC_INSTALL_READY="$work/$operation/install-ready" HCC_INSTALL_RELEASE="$work/release" bash "$repo/install.sh" "${args[@]}" > "$work/$operation/install.log" 2>&1 &
    pid=$!
    for ((i=0;i<250;i++)); do [[ -f "$work/$operation/install-ready" ]] && break; sleep .02; done
    [[ -f "$work/$operation/install-ready" ]] || fail 'installer did not reach deterministic management race gate'
    if [[ "$operation" == disable ]]; then
        HCC_IS_DISABLE=1 bash "$repo/install.sh" --tool agy --no-auto-repair --yes > "$work/$operation/disable.log" 2>&1 &
    else
        HCC_IS_DISABLE=1 bash "$repo/uninstall.sh" --tool agy --yes > "$work/$operation/disable.log" 2>&1 &
    fi
    disabler=$!
    for ((i=0;i<250;i++)); do [[ -f "$HCC_LOCK_ATTEMPT" ]] && break; sleep .02; done
    [[ -f "$HCC_LOCK_ATTEMPT" ]] || fail 'disable did not reach its lock gate'
    touch "$work/release"
    wait "$pid";pid=
    wait "$disabler";disabler=
    last=
    while IFS= read -r line; do case "$line" in *' disable --now '*|*' enable --now '*) last=$line;; esac; done < "$HCC_SYSTEMCTL_LOG"
    [[ "$last" == *' disable --now '* && ! -e "$HCC_MANAGER_ACTIVE" && ! -e "$root/watch/enabled" ]] || fail "$operation reported success after a later manager activation"
    if [[ "$operation" == uninstall ]]; then [[ -f "$HOME/.gemini/bin/agy" && ! -L "$HOME/.gemini/bin/agy" ]] || fail 'serialized uninstall did not detach native entry'; fi
done
printf 'PASS watcher lifecycle: immutable refresh baselines and serialized install/disable/uninstall manager transitions\n'
