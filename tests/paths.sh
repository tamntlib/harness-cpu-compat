#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-paths.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME" "$work/outside"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/binary"
chmod +x "$work/binary"
digest=$(sha256sum "$work/binary");digest=${digest%% *}
args=(--tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --yes)
root="$HOME/.local/share/harness-cpu-compat"
mkdir -p "$root"
ln -s "$work/outside" "$root/releases"
if bash "$repo/install.sh" "${args[@]}" >/dev/null 2>&1; then fail 'state symlink wrote outside HOME'; fi
[[ ! -e "$work/outside/claude" ]] || fail 'outside state modified'
rm "$root/releases"
bash "$repo/install.sh" "${args[@]}" >/dev/null
mv "$HOME/.local/bin" "$HOME/bin-saved"
cp -a "$HOME/bin-saved/claude" "$work/outside/claude"
ln -s "$work/outside" "$HOME/.local/bin"
if bash "$repo/uninstall.sh" --tool claude --yes >/dev/null 2>&1; then fail 'uninstall followed parent symlink outside HOME'; fi
[[ -L "$work/outside/claude" ]] || fail 'outside entry overwritten'
printf 'PASS paths: refuse state-directory and uninstall-parent escapes\n'
