#!/usr/bin/env bash
# Explicit opt-in: downloads vendor binaries; uses only a disposable HOME.
set -euo pipefail
[[ ${HCC_RUN_VENDOR_SMOKE:-0} == 1 ]] || { printf 'Set HCC_RUN_VENDOR_SMOKE=1 to allow official downloads.\n' >&2; exit 64; }
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-vendor.XXXXXX")
pid=
cleanup() { if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; wait "$pid" || true; fi; }
trap cleanup EXIT
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME"
printf 'Disposable vendor evidence: %s\n' "$work"
bash "$repo/install.sh" --tool all --yes
for tool in claude agy; do
 timeout -k 2s 30s "$HOME/.local/bin/$tool" --version
 timeout -k 2s 30s "$HOME/.local/bin/$tool" --help > "$work/$tool-help.txt"
done
port=$((40000 + RANDOM % 20000))
if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then printf 'Port in use; rerun smoke test.\n' >&2; exit 1; fi
AGY_ENABLE_HUB=1 ANTIGRAVITY_VSCODE_HOST=1 "$HOME/.gemini/bin/agy" --hub "--hub-port=$port" \
 --app_data_dir=antigravity --csrf_token=synthetic-test-only "--add-dir=$HOME" > "$work/hub.stdout" 2> "$work/hub.stderr" &
pid=$!
status=
for ((i=0;i<180;i++)); do
 kill -0 "$pid" 2>/dev/null || break
 status=$(curl --silent --output /dev/null --max-time 1 --write-out '%{http_code}' "http://127.0.0.1:$port/healthz" || true)
 [[ "$status" == 200 ]] && break
 sleep .2
done
[[ "$status" == 200 ]] || { printf 'AGY hub failed; inspect disposable logs.\n' >&2; exit 1; }
printf 'PASS vendor AGY wrapper hub: /healthz HTTP %s\n' "$status"
kill -TERM "$pid"
for ((i=0;i<100;i++)); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; wait "$pid" || true; pid=; printf 'Hub did not stop on TERM\n' >&2; exit 1; fi
set +e
wait "$pid"; stopped=$?
set -e
pid=
printf 'Hub stopped after TERM: status=%s\n' "$stopped"
bash "$repo/install.sh" --doctor
bash "$repo/uninstall.sh" --tool all --yes
printf 'PASS vendor smoke: official checksums, isolated installation, actual version/help, hub health and TERM; no authenticated task tested.\n'
