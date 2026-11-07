#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-management.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home space" HCC_SYSTEMCTL_LOG="$work/systemctl.log"
unset XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME HCC_STATE_DIR
mkdir -p "$HOME" "$work/bin"
cat > "$work/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HCC_SYSTEMCTL_LOG"
if [[ ${HCC_MANAGER_QUERY_FAIL:-0} == 1 && "$*" == *'show --property=FragmentPath'* ]]; then exit 1; fi
if [[ ${HCC_MANAGER_FAIL:-0} == 1 && "$*" == *is-active* ]]; then exit 1; fi
exit 0
FIXTURE
cat > "$work/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
printf 'Unexpected network request\n' >&2
exit 92
FIXTURE
cat > "$work/bin/qemu" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == -cpu && "$2" == max ]] || exit 90
shift 2; exec "$@"
FIXTURE
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/binary"
chmod +x "$work/bin/"* "$work/binary"
export PATH="$work/bin:$PATH"
digest=$(sha256sum "$work/binary");digest=${digest%% *}
args=(--tool agy --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/bin/qemu" --yes)
root="$HOME/.local/share/harness-cpu-compat"
if ! XDG_CONFIG_HOME="$work/unrelated-config" bash "$repo/install.sh" "${args[@]}" > "$work/install.log" 2>&1; then fail 'default-off installation validated unrelated systemd configuration'; fi
[[ ! -e "$HCC_SYSTEMCTL_LOG" && ! -d "$HOME/.config/systemd" && ! -e "$root/watch/enabled" ]] || fail 'default installation enabled or contacted systemd'
primary_before=$(sha256sum "$HOME/.gemini/bin/agy")
if HCC_MANAGER_QUERY_FAIL=1 bash "$repo/install.sh" "${args[@]}" --watch-agy > "$work/query-failed.log" 2>&1; then fail 'failed unit ownership query was treated as an empty manager inventory'; fi
[[ $(sha256sum "$HOME/.gemini/bin/agy") == "$primary_before" && ! -e "$root/watch/enabled" ]] || fail 'unknown manager ownership mutated AGY'
if ! bash "$repo/install.sh" "${args[@]}" --watch-agy > "$work/enable.log" 2>&1; then fail 'opt-in --watch-agy is not supported'; fi
[[ -f "$root/watch/enabled" ]] || fail 'explicit watcher enable missing'
shopt -s nullglob
units=("$HOME/.config/systemd/user/"hcc-agy-watch-*.path)
[[ ${#units[@]} == 1 ]] || fail 'owned path unit missing'
[[ -f "$HOME/.gemini/bin/.hcc-watch-owner" ]] || fail 'entry owner claim missing'
primary_before=$(sha256sum "$HOME/.gemini/bin/agy")
alias_before=$(sha256sum "$HOME/.local/bin/agy")
if HCC_STATE_DIR="$HOME/second-state" bash "$repo/install.sh" "${args[@]}" --watch-agy > "$work/second-root.log" 2>&1; then fail 'second state root stole watcher ownership'; fi
[[ $(sha256sum "$HOME/.gemini/bin/agy") == "$primary_before" && $(sha256sum "$HOME/.local/bin/agy") == "$alias_before" && ! -e "$HOME/second-state" ]] || fail 'ownership rejection happened after entry mutation'
# Modified unit files are preserved, including on uninstall, before manager/tool mutations.
unit=${units[0]}
printf '# manual change\n' >> "$unit"
modified=$(sha256sum "$unit"); manager_before=$(sha256sum "$HCC_SYSTEMCTL_LOG")
if bash "$repo/install.sh" --tool agy --no-watch-agy --yes > /dev/null 2>&1; then fail 'modified unit was removed'; fi
if bash "$repo/uninstall.sh" --tool agy --yes > /dev/null 2>&1; then fail 'uninstall ignored modified unit ownership'; fi
[[ $(sha256sum "$unit") == "$modified" && $(sha256sum "$HCC_SYSTEMCTL_LOG") == "$manager_before" && $(sha256sum "$HOME/.gemini/bin/agy") == "$primary_before" ]] || fail 'modified unit refusal changed data or contacted manager'
mapfile -t ownership < "$root/watch/owned"
cp "$root/watch/units/${ownership[3]}" "$unit"
# Omitted option preserves an earlier explicit opt-in and makes no manager calls.
before=$(sha256sum "$HCC_SYSTEMCTL_LOG")
bash "$repo/install.sh" "${args[@]}" > "$work/repeat.log" 2>&1
[[ -f "$root/watch/enabled" && $(sha256sum "$HCC_SYSTEMCTL_LOG") == "$before" ]] || fail 'ordinary rerun changed watcher state'
bash "$repo/install.sh" --tool agy --no-watch-agy --dry-run > "$work/dry.log"
bash "$repo/install.sh" --doctor --tool agy > "$work/doctor.log"
[[ -f "$root/watch/enabled" && $(sha256sum "$HCC_SYSTEMCTL_LOG") == "$before" ]] || fail 'inspection changed watcher or contacted manager'
# Disable is management-only: no vendor download, reinstall, or removal of launchers.
launcher=$(sha256sum "$HOME/.gemini/bin/agy")
bash "$repo/install.sh" --tool agy --no-watch-agy --yes
[[ ! -e "$root/watch/enabled" && ! -e "$HOME/.gemini/bin/.hcc-watch-owner" ]] || fail 'disable left enabled claim'
units=("$HOME/.config/systemd/user/"hcc-agy-watch-*)
[[ ${#units[@]} == 0 && $(sha256sum "$HOME/.gemini/bin/agy") == "$launcher" ]] || fail 'disable changed launcher or retained units'
bash "$repo/install.sh" "${args[@]}" --watch-agy > "$work/reenable.log" 2>&1
bash "$repo/uninstall.sh" --tool agy --yes
[[ ! -e "$root/watch/enabled" && ! -e "$HOME/.gemini/bin/agy" ]] || fail 'uninstall did not disable watcher first'
: > "$HCC_SYSTEMCTL_LOG"
if HCC_MANAGER_FAIL=1 bash "$repo/install.sh" "${args[@]}" --watch-agy > "$work/activation-failed.log" 2>&1; then fail 'manager acceptance without active triggers was reported as enabled'; fi
[[ ! -e "$root/watch/enabled" ]] || fail 'failed activation retained enabled flag'
grep -q 'disable --now' "$HCC_SYSTEMCTL_LOG" || fail 'activation failure did not stop its owned triggers'
printf 'PASS watcher management: default off, explicit enable, preserved opt-in, readonly inspection, management-only disable, uninstall cleanup, activation readback\n'
