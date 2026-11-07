#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-bootstrap-test.XXXXXX")
wrapper=
cleanup() {
    if [[ -n "$wrapper" ]]; then kill -TERM "$wrapper" 2>/dev/null || :; wait "$wrapper" || :; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home" TMPDIR="$work/temp space" HCC_TEST_ARCHIVE="$work/bundle.tgz" HCC_DOWNLOAD_LOG="$work/downloads"
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME HCC_STATE_DIR TAR_OPTIONS
mkdir -p "$HOME/.gemini/bin" "$TMPDIR" "$work/bin" "$work/source/harness-cpu-compat-main/lib" "$work/unrelated/lib"
for file in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do cp "$repo/$file" "$work/source/harness-cpu-compat-main/$file"; done
tar -czf "$HCC_TEST_ARCHIVE" -C "$work/source" harness-cpu-compat-main
cat > "$work/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -q ]] || exit 90
output=; url=
while (( $# )); do
 case "$1" in
  --output) output=$2; shift 2;;
  https://*) url=$1; shift;;
  *) shift;;
 esac
done
[[ "$url" == https://codeload.github.com/tamntlib/harness-cpu-compat/tar.gz/refs/heads/main && -n "$output" ]] || exit 91
printf '%s\n' "$url" >> "$HCC_DOWNLOAD_LOG"
[[ ${HCC_DOWNLOAD_FAIL:-0} != 1 ]] || exit 22
cp "$HCC_TEST_ARCHIVE" "$output"
[[ ${HCC_DOWNLOAD_LATE_FAIL:-0} != 1 ]] || exit 22
FIXTURE
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
printf 'touch %q\nexit 99\n' "$work/cwd-sourced" > "$work/unrelated/lib/common.sh"
printf '#!/usr/bin/env bash\necho original\n' > "$HOME/.gemini/bin/agy"; chmod +x "$HOME/.gemini/bin/agy"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$work/native binary \$fixture"; chmod +x "$work/native binary \$fixture"
digest=$(sha256sum < "$work/native binary \$fixture");digest=${digest%% *}
cd "$work/unrelated"
if ! cat "$repo/install.sh" | bash -s -- --tool agy --from-binary "$work/native binary \$fixture" --version 1.0.0 --sha256 "$digest" --mode native --yes > "$work/install.log" 2>&1; then fail 'piped install cannot acquire its complete bundle'; fi
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.0 && ! -e "$work/cwd-sourced" ]] || fail 'piped install lost arguments or sourced working-directory code'
shopt -s nullglob
left=("$TMPDIR"/hcc-bootstrap.*); [[ ${#left[@]} == 0 ]] || fail 'successful install leaked temporary bundle'
# The installed launchers/program must not depend on the deleted temporary source.
cat "$repo/uninstall.sh" | bash -s -- --tool agy --yes > "$work/uninstall.log" 2>&1
[[ ! -L "$HOME/.gemini/bin/agy" && $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'piped uninstall did not retain current native version'
left=("$TMPDIR"/hcc-bootstrap.*); [[ ${#left[@]} == 0 ]] || fail 'successful uninstall leaked temporary bundle'
[[ $(wc -l < "$HCC_DOWNLOAD_LOG") == 2 ]] || fail 'bootstrap did not acquire exactly one archive per invocation'
HCC_DOWNLOAD_FAIL=1 bash "$repo/install.sh" --help > /dev/null
HCC_DOWNLOAD_FAIL=1 bash "$repo/uninstall.sh" --help > /dev/null
[[ $(wc -l < "$HCC_DOWNLOAD_LOG") == 2 ]] || fail 'complete checkout attempted a bootstrap download'
for entry in install.sh uninstall.sh; do
    cp "$repo/$entry" "$work/$entry"
    bash "$work/$entry" --help > "$work/help.log"
    if HCC_DOWNLOAD_FAIL=1 bash -s -- --help < "$repo/$entry" > "$work/failed.log" 2>&1; then fail 'failed bootstrap download succeeded'; fi
    left=("$TMPDIR"/hcc-bootstrap.*); [[ ${#left[@]} == 0 ]] || fail 'failed bootstrap leaked temporary files'
done
# Synthetic payloads isolate argument/status forwarding and pre-execution guards.
cat > "$work/payload" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$HCC_EXECUTED"
if IFS= read -r line; then printf '%s' "$line" > "$HCC_INPUT_RECORD"; fi
exit 37
FIXTURE
export HCC_EXECUTED="$work/executed" HCC_INPUT_RECORD="$work/input-record"
for entry in install.sh uninstall.sh; do cp "$work/payload" "$work/source/harness-cpu-compat-main/$entry"; done
make_archive() { tar -czf "$HCC_TEST_ARCHIVE" -C "$work/source" harness-cpu-compat-main; }
make_archive
for entry in install.sh uninstall.sh; do
    rm -f "$HCC_EXECUTED" "$HCC_INPUT_RECORD"
    set +e
    bash -s -- 'argument space' 'literal$;*' '' < "$repo/$entry" > "$work/status.log" 2>&1
    status=$?
    set -e
    printf '%s\0' 'argument space' 'literal$;*' '' > "$work/expected-args"
    [[ $status == 37 && ! -e "$HCC_INPUT_RECORD" ]] && cmp -s "$HCC_EXECUTED" "$work/expected-args" || fail 'piped bootstrap changed arguments, stdin or child exit status'
    printf 'input preserved\n' > "$work/input"
    set +e
    bash "$work/$entry" --help < "$work/input" > "$work/status.log" 2>&1
    status=$?
    set -e
    [[ $status == 37 && $(< "$HCC_INPUT_RECORD") == 'input preserved' ]] || fail 'standalone bootstrap changed stdin or child exit status'
done
reject_archive() {
    local label=$1
    rm -f "$HCC_EXECUTED"
    if bash -s -- --yes < "$repo/install.sh" > "$work/rejected.log" 2>&1; then fail "accepted $label"; fi
    [[ ! -e "$HCC_EXECUTED" ]] || fail "executed $label before validation"
    left=("$TMPDIR"/hcc-bootstrap.*); [[ ${#left[@]} == 0 ]] || fail "leaked $label bootstrap"
}
HCC_DOWNLOAD_LATE_FAIL=1 reject_archive 'download that wrote data but failed'
printf 'not gzip\n' > "$HCC_TEST_ARCHIVE"; reject_archive 'corrupt archive'
make_archive
cp "$HCC_TEST_ARCHIVE" "$work/good.tgz"
head -c 200 "$work/good.tgz" > "$HCC_TEST_ARCHIVE"; reject_archive 'truncated archive'
mv "$work/source/harness-cpu-compat-main/lib/watch.sh" "$work/saved-watch"
make_archive; reject_archive 'missing library'
ln -s "$work/saved-watch" "$work/source/harness-cpu-compat-main/lib/watch.sh"
make_archive; reject_archive 'symlink library'
rm "$work/source/harness-cpu-compat-main/lib/watch.sh"
ln "$work/source/harness-cpu-compat-main/lib/common.sh" "$work/source/harness-cpu-compat-main/lib/watch.sh"
make_archive; reject_archive 'hardlink library'
rm "$work/source/harness-cpu-compat-main/lib/watch.sh"; mv "$work/saved-watch" "$work/source/harness-cpu-compat-main/lib/watch.sh"
tar -czf "$HCC_TEST_ARCHIVE" -C "$work/source" harness-cpu-compat-main harness-cpu-compat-main/install.sh
reject_archive 'duplicate entrypoint'
printf extra > "$work/source/harness-cpu-compat-main/extra"
for replacement in '../escaped' '/absolute-escape' 'harness-cpu-compat-main/../escaped'; do
    tar -P --transform="s|^harness-cpu-compat-main/extra$|$replacement|" -czf "$HCC_TEST_ARCHIVE" -C "$work/source" harness-cpu-compat-main
    reject_archive 'unsafe extra member'
done
rm "$work/source/harness-cpu-compat-main/extra"
make_archive
# A successful-but-short extractor must not turn a valid script into an executable prefix.
cat > "$work/bin/tar" <<'FIXTURE'
#!/usr/bin/env bash
if [[ ${HCC_SHORT_EXTRACT:-0} == 1 && "$*" == *-xOzf* && ${!#} == harness-cpu-compat-main/install.sh ]]; then
 /usr/bin/tar "$@" | head -n 2
 exit 0
fi
exec /usr/bin/tar "$@"
FIXTURE
chmod +x "$work/bin/tar"
HCC_SHORT_EXTRACT=1 reject_archive 'silently shortened entrypoint'
# Ambient tar options cannot change the member selection or trigger extraction hooks.
set +e
TAR_OPTIONS='--exclude=*' bash -s -- --help < "$repo/install.sh" > "$work/tar-options.log" 2>&1
status=$?
set -e
[[ $status == 37 ]] || fail 'bootstrap honored ambient TAR_OPTIONS'
# Default temporary storage is HOME when TMPDIR is absent.
set +e
env -u TMPDIR bash -s -- --help < "$repo/uninstall.sh" > "$work/fallback.log" 2>&1
status=$?
set -e
left=("$HOME"/hcc-bootstrap.*); [[ $status == 37 && ${#left[@]} == 0 ]] || fail 'HOME temporary fallback failed or leaked'
# INT/TERM must cancel the owned child, preserve conventional status and clean up.
cat > "$work/payload" <<'FIXTURE'
#!/usr/bin/env bash
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$HCC_CHILD_PID"
while :; do sleep .02; done
FIXTURE
for entry in install.sh uninstall.sh; do cp "$work/payload" "$work/source/harness-cpu-compat-main/$entry"; done
make_archive
export HCC_CHILD_PID="$work/child-pid"
for entry in install.sh uninstall.sh; do
    for signal in INT TERM; do
        rm -f "$HCC_CHILD_PID"
        env --default-signal=INT,QUIT bash -s -- --yes < "$repo/$entry" > "$work/signal.log" 2>&1 &
        wrapper=$!
        for ((i=0;i<300;i++)); do [[ -f "$HCC_CHILD_PID" ]] && break; sleep .01; done
        [[ -f "$HCC_CHILD_PID" ]] || fail 'bootstrap child did not start'
        child=$(< "$HCC_CHILD_PID")
        kill -s "$signal" "$wrapper"
        set +e
        wait "$wrapper"; status=$?
        set -e
        wrapper=
        expected=130; [[ "$signal" == INT ]] || expected=143
        left=("$TMPDIR"/hcc-bootstrap.*)
        [[ $status == "$expected" && ! -e /proc/$child && ${#left[@]} == 0 ]] || fail "$signal did not cancel/clean the $entry bootstrap"
    done
done
printf 'PASS bootstrap: piped install/uninstall, standalone fallback, argv/stdin/status, local fast path, archive validation, signals and cleanup\n'
