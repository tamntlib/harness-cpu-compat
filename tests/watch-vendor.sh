#!/usr/bin/env bash
# Opt-in real binary + real user-manager recovery. No IDE bundle is redistributed.
set -euo pipefail
[[ ${HCC_RUN_VENDOR_SMOKE:-0} == 1 ]] || { printf 'Set HCC_RUN_VENDOR_SMOKE=1\n' >&2; exit 64; }
: "${HCC_PREVIOUS_AGY_BINARY:?}" "${HCC_PREVIOUS_AGY_VERSION:?}" "${HCC_PREVIOUS_AGY_SHA256:?}"
: "${HCC_NEXT_AGY_BINARY:?}" "${HCC_NEXT_AGY_VERSION:?}" "${HCC_NEXT_AGY_SHA256:?}"
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-vendor.XXXXXX")
base=; linked=0; hub=
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$hub" ]] && kill -0 "$hub" 2>/dev/null; then kill -TERM "$hub"; wait "$hub" || true; fi
    if (( linked )); then
        /usr/bin/systemctl --user stop "$base.path" "$base.timer" "$base.service" || result=1
        /usr/bin/systemctl --user disable --runtime "$base.path" "$base.timer" "$base.service" || result=1
        /usr/bin/systemctl --user daemon-reload || result=1
    fi
    printf 'Real watcher evidence retained: %s\n' "$work"
    exit "$result"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home"
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME HCC_STATE_DIR
mkdir -p "$HOME" "$work/bin" "$work/runtime-units"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/systemctl"; chmod +x "$work/bin/systemctl"
export PATH="$work/bin:$PATH"
# Management is mocked only to avoid installing persistent units on the host.
# Identical generated unit files are subsequently linked into the real manager at runtime.
bash "$repo/install.sh" --tool agy --yes --mode qemu --from-binary "$HCC_PREVIOUS_AGY_BINARY" --version "$HCC_PREVIOUS_AGY_VERSION" --sha256 "$HCC_PREVIOUS_AGY_SHA256" --watch-agy
root="$HOME/.local/share/harness-cpu-compat"
old=$(readlink "$root/tools/agy/current")
mapfile -t record < "$root/watch/owned"; base=${record[0]}; config=${record[1]}
for suffix in service path timer; do cp "$config/$base.$suffix" "$work/runtime-units/$base.$suffix"; done
printf '\n[Service]\nCPUAffinity=0 1\n' >> "$work/runtime-units/$base.service"
/usr/bin/systemd-analyze --user verify "$work/runtime-units/$base.service" "$work/runtime-units/$base.path" "$work/runtime-units/$base.timer"
linked=1
/usr/bin/systemctl --user link --runtime "$work/runtime-units/$base.service" "$work/runtime-units/$base.path" "$work/runtime-units/$base.timer"
/usr/bin/systemctl --user daemon-reload
/usr/bin/systemctl --user start "$base.path" "$base.timer"
actual=$(sha256sum < "$HCC_NEXT_AGY_BINARY"); [[ ${actual%% *} == "$HCC_NEXT_AGY_SHA256" ]] || fail 'next fixture digest changed'
cp "$HCC_NEXT_AGY_BINARY" "$work/incoming"
if [[ -n ${HCC_IDE_NODE:-} ]]; then
    : "${HCC_IDE_EXTENSION:?}" "${HCC_IDE_EXTENSION_SHA256:?}"
    # Execute the installed extension's real Linux promotion function in a scoped VM.
    # Only its text is read; this script never patches or loads the IDE extension itself.
    "$HCC_IDE_NODE" - "$HCC_IDE_EXTENSION" "$HCC_IDE_EXTENSION_SHA256" "$work/incoming" "$HOME/.gemini/bin/agy" "$work/promotion.json" <<'NODE'
const fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto');
const [extension,expected,staged,target,receipt]=process.argv.slice(2);
const bytes=fs.readFileSync(extension),sha=b=>crypto.createHash('sha256').update(b).digest('hex');
if(sha(bytes)!==expected)throw Error('Installed extension fingerprint changed');
const text=bytes.toString(),start=text.indexOf('async function ic('),marker='Na.promoteBinarySafely=ic;';
const end=text.indexOf(marker,start);
if(start<0||end<start)throw Error('Unrecognized promotion function');
const source=text.slice(start,end+marker.length),Na={};
const f={asyncContextStart:()=>()=>v=>v};
vm.runInNewContext(source,{f,la:fs,Na,$b:options=>options});
(async()=>{await Na.promoteBinarySafely(staged,target,null,{platform:'linux',fsRename:fs.promises.rename,fsExists:async p=>fs.existsSync(p)});
fs.writeFileSync(receipt,JSON.stringify({extension_sha256:expected,promotion_source_sha256:sha(source),method:'installed Linux promotion function',target},null,2));
})().catch(e=>{console.error(e.message);process.exitCode=1});
NODE
else
    chmod 755 "$work/incoming"; mv -T "$work/incoming" "$HOME/.gemini/bin/agy"
fi
# The immediate updater exec can still fail; do not misrepresent repair as pre-exec interception.
set +e
(ulimit -c 0; timeout -k 2s 15s "$HOME/.gemini/bin/agy" --version) > "$work/immediate-version.log" 2>&1
immediate=$?
set -e
printf 'Immediate post-update version status: %s\n' "$immediate"
for ((i=0;i<400;i++)); do
    control=$(/usr/bin/systemctl --user show --property=ControlGroup --value "$base.service")
    if [[ -n "$control" && -r "/sys/fs/cgroup$control/memory.max" ]]; then
        if { IFS= read -r memory < "/sys/fs/cgroup$control/memory.max" && IFS= read -r cpu < "/sys/fs/cgroup$control/cpu.max" && IFS= read -r swap < "/sys/fs/cgroup$control/memory.swap.max"; } 2>/dev/null; then
            [[ "$memory" == 1073741824 && "$cpu" == '200000 100000' && "$swap" == 0 ]] || fail 'worker resource limits missing'
            printf 'cgroup=%s memory=%s cpu=%s swap=%s\n' "$control" "$memory" "$cpu" "$swap" > "$work/resources.txt"
        fi
    fi
    if [[ ! -e "$root/watch/pending" && -f "$root/tools/agy/current/sha256" ]] && [[ $(< "$root/tools/agy/current/sha256") == "$HCC_NEXT_AGY_SHA256" ]]; then break; fi
    sleep .2
done
[[ -f "$work/resources.txt" && ! -e "$root/watch/pending" ]] || fail 'watcher did not complete bounded repair'
selected=$(readlink "$root/tools/agy/current")
[[ "$selected" != "$old" && -x "$old/binary" && $(< "$selected/sha256") == "$HCC_NEXT_AGY_SHA256" ]] || fail 'wrong artifact selected or fallback lost'
[[ $(timeout -k 2s 30s "$HOME/.gemini/bin/agy" --version) == "$HCC_NEXT_AGY_VERSION" ]] || fail 'primary entry not repaired'
timeout -k 2s 30s "$HOME/.local/bin/agy" --help > "$work/help.txt" 2>&1
port=$((40000+RANDOM%20000))
if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail 'hub test port occupied'; fi
AGY_ENABLE_HUB=1 ANTIGRAVITY_VSCODE_HOST=1 "$HOME/.gemini/bin/agy" --hub "--hub-port=$port" --app_data_dir=antigravity --csrf_token=synthetic-test-only "--add-dir=$HOME" > "$work/hub.log" 2>&1 &
hub=$!;status=
for ((i=0;i<180;i++)); do
    kill -0 "$hub" 2>/dev/null || break
    status=$(curl --silent --output /dev/null --max-time 1 --write-out '%{http_code}' "http://127.0.0.1:$port/healthz" || true)
    [[ "$status" == 200 ]] && break
    sleep .2
done
[[ "$status" == 200 ]] || fail 'repaired generation hub unhealthy'
kill -TERM "$hub"
for ((i=0;i<100;i++)); do kill -0 "$hub" 2>/dev/null || break; sleep .05; done
if kill -0 "$hub" 2>/dev/null; then kill -KILL "$hub"; wait "$hub" || true; hub=; fail 'Hub ignored bounded TERM shutdown'; fi
set +e
wait "$hub";stopped=$?
set -e
hub=
printf 'PASS real vendor watcher: automatic %s -> %s, exact checksum, previous release retained, version/help, hub HTTP200; TERM status=%s; no authenticated task claimed.\n' "$HCC_PREVIOUS_AGY_VERSION" "$HCC_NEXT_AGY_VERSION" "$stopped"
