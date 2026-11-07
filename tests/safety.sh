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
digest=$(sha256sum "$work/binary");digest=${digest%% *}
args=(--tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --yes)
bash "$repo/install.sh" "${args[@]}" >/dev/null
state="$HOME/.local/share/harness-cpu-compat/tools/claude"
printf corrupted > "$state/original/entry"
if bash "$repo/uninstall.sh" --tool claude --yes >/dev/null 2>&1; then fail 'corrupted original restored'; fi
[[ $("$HOME/.local/bin/claude" --version) == 1.0.0 ]] || fail 'failed uninstall changed live entry'
printf 'original\n' > "$state/original/entry"
bash "$repo/uninstall.sh" --tool claude --yes >/dev/null
# Verify all AGY backups before restoring either of its two entry points.
mkdir -p "$HOME/.gemini/bin"
printf 'agy original\n' > "$HOME/.gemini/bin/agy"
printf 'alias original\n' > "$HOME/.local/bin/agy"
bash "$repo/install.sh" "${args[@]}" --tool agy >/dev/null
agy_state="$HOME/.local/share/harness-cpu-compat/tools/agy"
printf corrupted > "$agy_state/alias-original/entry"
primary=$(readlink "$HOME/.gemini/bin/agy")
if bash "$repo/uninstall.sh" --tool agy --yes >/dev/null 2>&1; then fail 'corrupted alias backup accepted'; fi
[[ -L "$HOME/.gemini/bin/agy" && $(readlink "$HOME/.gemini/bin/agy") == "$primary" ]] || fail 'bad alias backup caused partial uninstall'
# SIGKILL after current-selection publication must not silently establish a new baseline on retry.
mkdir "$work/bin"
cat > "$work/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
for arg; do
 if [[ "$arg" == *'.hcc-new.'* ]]; then kill -KILL "$PPID"; exit 99; fi
done
exec /usr/bin/mv "$@"
FIXTURE
chmod +x "$work/bin/mv"
set +e
PATH="$work/bin:$PATH" bash "$repo/install.sh" "${args[@]}" > "$work/killed.log" 2>&1
status=$?
set -e
[[ "$status" == 137 ]] || fail "kill injection failed ($status)"
[[ -f "$state/pending" ]] || fail 'SIGKILL left no durable incomplete-publication marker'
if bash "$repo/install.sh" "${args[@]}" >/dev/null 2>&1; then fail 'interrupted install silently replaced recovery baseline'; fi
[[ $(< "$state/original/entry") == original ]] || fail 'original recovery material lost'
printf 'PASS safety: corrupted-backup refusal, SIGKILL interruption marker and fail-closed retry\n'
