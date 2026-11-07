#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-safety.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME/.local/bin"
printf 'original\n' > "$HOME/.local/bin/claude"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/binary"
chmod +x "$work/binary"
digest=$(sha256sum < "$work/binary");digest=${digest%% *}
args=(--tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --yes)
bash "$repo/install.sh" "${args[@]}" >/dev/null
state="$HOME/.local/share/harness-cpu-compat/tools/claude"
selected=$(readlink "$state/current")
entry_before=$(readlink "$HOME/.local/bin/claude")
printf corrupted >> "$selected/binary"
if bash "$repo/uninstall.sh" --tool claude --yes >/dev/null 2>&1; then fail 'corrupted selected executable accepted'; fi
[[ $(readlink "$HOME/.local/bin/claude") == "$entry_before" ]] || fail 'failed uninstall changed live entry'
cp "$work/binary" "$selected/binary"
bash "$repo/uninstall.sh" --tool claude --yes >/dev/null
# Validate both AGY entries before detaching either of them.
mkdir -p "$HOME/.gemini/bin"
bash "$repo/install.sh" "${args[@]}" --tool agy >/dev/null
primary=$(readlink "$HOME/.gemini/bin/agy")
rm "$HOME/.local/bin/agy"
printf 'unknown alias\n' > "$HOME/.local/bin/agy"
if bash "$repo/uninstall.sh" --tool agy --yes >/dev/null 2>&1; then fail 'unknown alias accepted'; fi
[[ -L "$HOME/.gemini/bin/agy" && $(readlink "$HOME/.gemini/bin/agy") == "$primary" ]] || fail 'bad alias caused partial uninstall'
# SIGKILL must retain only this unfinished operation's recovery, never create a baseline.
mkdir "$work/bin"
cat > "$work/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
for arg; do
 if [[ "$arg" == *'.hcc-new.'* ]]; then kill -KILL "$PPID"; exit 99; fi
done
exec /usr/bin/mv "$@"
FIXTURE
chmod +x "$work/bin/mv"
preimage=$(readlink "$HOME/.local/bin/claude")
set +e
PATH="$work/bin:$PATH" bash "$repo/install.sh" "${args[@]}" > "$work/killed.log" 2>&1
status=$?
set -e
[[ "$status" == 137 ]] || fail "kill injection failed ($status)"
[[ -f "$state/pending" ]] || fail 'SIGKILL left no durable incomplete-publication marker'
if bash "$repo/install.sh" "${args[@]}" >/dev/null 2>&1; then fail 'interrupted install silently retried'; fi
mapfile -t recovery < "$state/pending"
[[ $(readlink "${recovery[0]}/entry/entry") == "$preimage" ]] || fail 'unfinished transaction lost its preimage'
[[ ! -e "$state/original" && ! -e "$state/installed" ]] || fail 'historical baseline metadata recreated'
printf 'PASS safety: selected checksum/unknown alias refusal, SIGKILL transaction recovery and fail-closed retry\n'
