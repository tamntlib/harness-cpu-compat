#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-lifecycle.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$repo/install.sh" && -f "$repo/uninstall.sh" ]] || fail 'installer/uninstaller are not implemented'
export HOME="$work/home space"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME/.gemini/bin" "$work/bin"
cat > "$work/binary" <<'FIXTURE'
#!/usr/bin/env bash
case "${1:-}" in
 --version) printf '1.0.0\n';;
 --help) printf 'fixture help\n';;
 *) printf '<%s>\n' "$@";;
esac
FIXTURE
cat > "$work/bin/qemu" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == -cpu && "$2" == max ]] || exit 90
shift 2
exec "$@"
FIXTURE
chmod +x "$work/binary" "$work/bin/qemu"
digest=$(sha256sum "$work/binary");digest=${digest%% *}
printf 'original-vendor-entry\n' > "$HOME/.gemini/bin/agy"
base=(--tool agy --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/bin/qemu" --yes)
snapshot() { find "$HOME" -type f -exec sha256sum {} + | sort; }
before=$(snapshot)
bash "$repo/install.sh" --doctor --tool all >/dev/null
bash "$repo/install.sh" --dry-run "${base[@]}" >/dev/null
[[ $(snapshot) == "$before" ]] || fail 'doctor/dry-run wrote files'
bash "$repo/install.sh" "${base[@]}"
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'AGY wrapper cannot run'
[[ $("$HOME/.local/bin/agy" 'space value' '') == $'<space value>\n<>' ]] || fail 'CLI alias arguments'
[[ ! -e "$HOME/.local/share/harness-cpu-compat/tools/agy/original" ]] || fail 'obsolete original snapshot created'
entry=$(sha256sum "$HOME/.gemini/bin/agy")
bash "$repo/install.sh" "${base[@]}"
[[ $(sha256sum "$HOME/.gemini/bin/agy") == "$entry" ]] || fail 'repeat install changed launcher'
# A vendor update replaces the wrapper before the wrapper has any chance to run.
printf 'foreign-update\n' > "$HOME/.gemini/bin/agy"
if bash "$repo/install.sh" "${base[@]}" >/dev/null 2>&1; then fail 'foreign replacement silently overwritten'; fi
if bash "$repo/uninstall.sh" --tool agy --yes >/dev/null 2>&1; then fail 'uninstall overwrote foreign replacement'; fi
[[ $(< "$HOME/.gemini/bin/agy") == foreign-update ]] || fail 'foreign replacement lost'
bash "$repo/install.sh" "${base[@]}" --repair
bash "$repo/uninstall.sh" --tool agy --yes
[[ ! -L "$HOME/.gemini/bin/agy" && $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'current AGY not detached to native layout'
[[ $(readlink "$HOME/.local/bin/agy") == "$HOME/.gemini/bin/agy" ]] || fail 'native CLI alias missing'
bash "$repo/uninstall.sh" --tool agy --yes
printf 'PASS lifecycle: read-only inspection, install, repeat, foreign-update refusal, explicit repair, current native handoff, repeat uninstall\n'
