#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-robustness.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME/.local/bin"
printf 'first original\n' > "$HOME/.local/bin/claude"
cat > "$work/binary" <<'FIXTURE'
#!/usr/bin/env bash
case "${1:-}" in
 --version) echo 1.0.0;;
 --help) [[ ${HCC_EMULATED:-0} == 1 ]] || exit 132; echo help;;
 *) echo application;;
esac
FIXTURE
cat > "$work/qemu-one" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == -cpu && "$2" == max ]] || exit 90
shift 2
export HCC_EMULATED=1
exec "$@"
FIXTURE
cp "$work/qemu-one" "$work/qemu-two"
chmod +x "$work/binary" "$work/qemu-one" "$work/qemu-two"
digest=$(sha256sum "$work/binary");digest=${digest%% *}
args=(--tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --mode auto --qemu "$work/qemu-one" --yes)
bash "$repo/install.sh" "${args[@]}" >/dev/null
selection="$HOME/.local/share/harness-cpu-compat/tools/claude/current/selection"
mapfile -t values < "$selection"
[[ ${values[1]} == qemu ]] || fail 'version-only success hid native help failure'
before=$(readlink "$HOME/.local/share/harness-cpu-compat/tools/claude/current")
if bash "$repo/install.sh" "${args[@]}" --sha256 "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then fail 'bad checksum accepted'; fi
[[ $(readlink "$HOME/.local/share/harness-cpu-compat/tools/claude/current") == "$before" ]] || fail 'failure replaced active selection'
bash "$repo/install.sh" "${args[@]}" --qemu "$work/qemu-two" >/dev/null
mapfile -t values < "$selection"
[[ ${values[2]} == "$work/qemu-two" ]] || fail 'new QEMU selection was ignored'
bash "$repo/uninstall.sh" --tool claude --yes >/dev/null
rm "$HOME/.local/bin/claude"
printf 'new vendor installation\n' > "$HOME/.local/bin/claude"
bash "$repo/install.sh" "${args[@]}" >/dev/null
bash "$repo/uninstall.sh" --tool claude --yes >/dev/null
[[ $("$HOME/.local/bin/claude" --version) == 1.0.0 && -L "$HOME/.local/bin/claude" ]] || fail 'reinstall did not detach current version'
printf 'PASS robustness: native help failure, checksum rejection, active preservation, QEMU reselection, reinstall native handoff\n'
