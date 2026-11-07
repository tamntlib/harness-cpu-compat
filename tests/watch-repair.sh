#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-repair.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
wf_init "$work/normal"
wf_feed 1.0.1
old=$(readlink "$root/tools/agy/current")
new_digest=$(sha256sum "$HCC_FEED/cli");new_digest=${new_digest%% *}
cp "$HCC_FEED/cli" "$work/incoming"
mv -T "$work/incoming" "$HOME/.gemini/bin/agy"
bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > "$work/repair.log" 2>&1
[[ $("$HOME/.local/bin/agy" --version) == 1.0.1 ]] || fail 'worker did not adopt exact verified updater artifact and repair both entries'
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'primary repair stale'
selected=$(readlink "$root/tools/agy/current")
[[ "$selected" != "$old" && -f "$old/binary" && $(< "$selected/sha256") == "$new_digest" ]] || fail 'new selection/fallback mismatch'
[[ ! -e "$root/watch/pending" ]] || fail 'successful repair left pending marker'
before=$(sha256sum "$HCC_NETWORK_LOG")
bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME"
[[ $(sha256sum "$HCC_NETWORK_LOG") == "$before" ]] || fail 'self event repeated downloads'
# Unknown candidate must not be executed, nor silently replaced with feed latest.
printf '#!/usr/bin/env bash\ntouch %q\necho 1.0.2\n' "$work/UNTRUSTED_EXECUTED" > "$work/unknown"
chmod +x "$work/unknown"
cp "$work/unknown" "$HOME/.gemini/bin/agy"
unknown=$(sha256sum "$HOME/.gemini/bin/agy")
if bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > "$work/rejected.log" 2>&1; then fail 'unknown publisher mismatch accepted'; fi
[[ ! -e "$work/UNTRUSTED_EXECUTED" && $(sha256sum "$HOME/.gemini/bin/agy") == "$unknown" && $(readlink "$root/tools/agy/current") == "$selected" ]] || fail 'rejection executed or overwrote untrusted candidate'
# The disabled worker is a no-op even if a conflicting entry remains.
bash "$repo/install.sh" --tool agy --no-watch-agy --yes
before=$(sha256sum "$HCC_NETWORK_LOG")
bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME"
[[ $(sha256sum "$HCC_NETWORK_LOG") == "$before" ]] || fail 'disabled worker downloaded artifacts'
# Verified native success must use direct symlinks and never execute QEMU.
wf_init "$work/native"
wf_feed 1.0.1
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.1;; --help) echo help;; esac\n' > "$HCC_FEED/cli"
chmod +x "$HCC_FEED/cli"
tar -czf "$HCC_FEED/payload.tar.gz" -C "$HCC_FEED" cli
archive_digest=$(sha512sum < "$HCC_FEED/payload.tar.gz");archive_digest=${archive_digest%% *}
jq --arg digest "$archive_digest" '.sha512=$digest' "$HCC_FEED/manifest.json" > "$work/native-manifest"
mv "$work/native-manifest" "$HCC_FEED/manifest.json"
printf '#!/usr/bin/env bash\ntouch %q\nexit 90\n' "$work/QEMU_UNEXPECTED" > "$work/native/bin/qemu"
chmod +x "$work/native/bin/qemu"
cp "$HCC_FEED/cli" "$HOME/.gemini/bin/agy"
bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME"
[[ -L "$HOME/.gemini/bin/agy" && -L "$HOME/.local/bin/agy" && ! -e "$work/QEMU_UNEXPECTED" && $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'native-compatible artifact unnecessarily wrapped/emulated'
printf 'PASS watcher repair: exact verified candidate, immutable selection, fallback retention, self-event no-op, untrusted rejection, disabled no-op, native direct execution\n'
