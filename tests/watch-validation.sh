#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-validation.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
for fault in checksum archive qemu alias private; do
    wf_init "$work/$fault"; wf_feed 1.0.1
    cp "$HCC_FEED/cli" "$HOME/.gemini/bin/agy"
    old=$(readlink "$root/tools/agy/current")
    case "$fault" in
        checksum) printf broken >> "$HCC_FEED/payload.tar.gz";;
        archive)
            mkdir "$work/$fault/bad"
            ln -s /nonexistent-fixture-target "$work/$fault/bad/cli"
            tar -czf "$HCC_FEED/payload.tar.gz" -C "$work/$fault/bad" cli
            digest=$(sha512sum < "$HCC_FEED/payload.tar.gz"); digest=${digest%% *}
            jq --arg digest "$digest" '.sha512=$digest' "$HCC_FEED/manifest.json" > "$work/$fault/manifest"
            mv "$work/$fault/manifest" "$HCC_FEED/manifest.json";;
        qemu) rm "$work/$fault/bin/qemu";;
        alias) printf 'foreign alias\n' > "$HOME/.local/bin/agy";;
        private) printf 'changed\n' >> "$old/binary";;
    esac
    if [[ "$fault" == checksum || "$fault" == archive ]]; then
        printf '#!/usr/bin/env bash\ntouch %q\necho 1.0.1\n' "$work/$fault/UNTRUSTED_EXECUTED" > "$HOME/.gemini/bin/agy"
        chmod +x "$HOME/.gemini/bin/agy"
    fi
    before=$(sha256sum "$HOME/.gemini/bin/agy")
    if bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > "$work/$fault/rejected.log" 2>&1; then fail "invalid $fault accepted"; fi
    [[ $(sha256sum "$HOME/.gemini/bin/agy") == "$before" && $(readlink "$root/tools/agy/current") == "$old" && ! -e "$root/watch/pending" && ! -e "$work/$fault/UNTRUSTED_EXECUTED" ]] || fail "invalid $fault executed or mutated entries"
    if [[ "$fault" == alias || "$fault" == private ]]; then [[ ! -e "$HCC_NETWORK_LOG" ]] || fail 'local drift was discovered after network work'; fi
done
wf_init "$work/retry"; wf_feed 1.0.1
cp "$HCC_FEED/cli" "$HOME/.gemini/bin/agy"
cp "$work/retry/bin/curl" "$work/retry/curl-original"
printf '#!/usr/bin/env bash\nexit 22\n' > "$work/retry/bin/curl"
if bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > /dev/null 2>&1; then fail 'network failure reported success'; fi
cp "$work/retry/curl-original" "$work/retry/bin/curl"; chmod +x "$work/retry/bin/curl"
bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > "$work/retry/recovered.log" 2>&1
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'transient failure permanently suppressed retry'
printf 'PASS watcher validation: checksum/archive/emulator/alias/private drift refusal, no untrusted execution, transient fetch retry\n'
