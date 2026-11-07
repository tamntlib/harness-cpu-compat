#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-runtime.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$repo/lib/runtime.sh" ]] || fail 'runtime dispatcher is not implemented'
mkdir -p "$work/state/tools/agy" "$work/state/releases/agy/example"
real="$work/state/releases/agy/example/binary"
cat > "$real" <<'FIXTURE'
#!/usr/bin/env bash
case "${1:-}" in
  inspect)
    shift
    printf 'cwd=%s\nenv=%s\n' "$PWD" "${HCC_EXAMPLE:-}"
    printf '<%s>\n' "$@"
    cat
    printf 'stderr-preserved\n' >&2
    exit 17;;
  signal) printf '%s\n' "$$" > "$PID_FILE"; exec sleep 30;;
esac
FIXTURE
cat > "$work/qemu" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == -cpu && "$2" == max ]] || exit 90
shift 2
exec "$@"
FIXTURE
chmod +x "$real" "$work/qemu"
printf '%s\n' "$real" qemu "$work/qemu" > "$work/state/releases/agy/example/selection"
ln -s ../../releases/agy/example "$work/state/tools/agy/current"
set +e
printf 'stdin-preserved\n' | HCC_EXAMPLE='literal value' bash "$repo/lib/runtime.sh" "$work/state" agy inspect 'space value' '' '$(not-executed)' > "$work/out" 2> "$work/err"
status=$?
set -e
[[ $status == 17 ]] || fail "exit status $status"
expected=$(printf 'cwd=%s\nenv=literal value\n<space value>\n<>\n<$(not-executed)>\nstdin-preserved' "$PWD")
[[ $(< "$work/out") == "$expected" ]] || fail 'arguments/cwd/env/stdin/stdout changed'
[[ $(< "$work/err") == stderr-preserved ]] || fail 'stderr changed'
PID_FILE="$work/pid" bash "$repo/lib/runtime.sh" "$work/state" agy signal &
pid=$!
for ((i=0;i<100;i++)); do [[ -f "$work/pid" ]] && break; sleep .02; done
[[ $(< "$work/pid") == "$pid" ]] || fail 'dispatcher did not exec backend'
kill -TERM "$pid"
set +e
wait "$pid"; status=$?
set -e
[[ $status == 143 ]] || fail "TERM status $status"
printf 'PASS runtime: arguments, empty/metacharacters, cwd, environment, streams, exit status, TERM, exec identity\n'
