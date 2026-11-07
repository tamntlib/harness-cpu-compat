#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-transactions.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir "$work/bin"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/binary"
chmod +x "$work/binary"
digest=$(sha256sum "$work/binary");digest=${digest%% *}
cat > "$work/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
for arg; do
 if [[ "$arg" == *'.hcc-new.'* && ! -f "$HCC_FAULT_MARKER" ]]; then
   touch "$HCC_FAULT_MARKER"
   if [[ "$HCC_FAULT" == foreign ]]; then printf 'concurrent-vendor-entry\n' > "$HOME/.local/bin/claude"; fi
   exit 19
 fi
done
exec /usr/bin/mv "$@"
FIXTURE
cat > "$work/bin/cp" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}
if [[ "$last" == *'.hcc-restore.'* ]]; then
 case "$HCC_FAULT" in
  partial-copy) printf 'partial-copy\n' > "$last"; exit 18;;
  silent-short-copy) printf 'partial-copy\n' > "$last"; exit 0;;
 esac
fi
exec /usr/bin/cp "$@"
FIXTURE
chmod +x "$work/bin/mv" "$work/bin/cp"
for fault in ordinary foreign partial-copy silent-short-copy; do
 export HOME="$work/$fault" HCC_FAULT=$fault HCC_FAULT_MARKER="$work/$fault-marker"
 mkdir -p "$HOME/.local/bin"
 printf 'original\n' > "$HOME/.local/bin/claude"
 if PATH="$work/bin:$PATH" bash "$repo/install.sh" --tool claude --from-binary "$work/binary" --version 1.0.0 --sha256 "$digest" --yes > "$work/$fault.log" 2>&1; then fail 'publication fault did not fail'; fi
 state="$HOME/.local/share/harness-cpu-compat/tools/claude"
 if [[ "$fault" == ordinary ]]; then
   [[ $(< "$HOME/.local/bin/claude") == original ]] || fail 'ordinary rollback lost original'
   [[ ! -e "$state/pending" ]] || fail 'successful rollback left a blocking transaction marker'
 elif [[ "$fault" == foreign ]]; then
   [[ $(< "$HOME/.local/bin/claude") == concurrent-vendor-entry ]] || fail 'rollback clobbered concurrent vendor replacement'
   [[ -f "$state/pending" ]] || fail 'foreign drift lost pending recovery marker'
 else
   [[ $(< "$HOME/.local/bin/claude") == original ]] || fail 'partial recovery copy was published'
   [[ -f "$state/pending" ]] || fail 'incomplete recovery lost its pending marker'
 fi
done
printf 'PASS transactions: rollback preserves originals, foreign drift and incomplete-copy failures retain recovery markers\n'
