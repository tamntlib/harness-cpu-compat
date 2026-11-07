#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-owners.XXXXXX")
pid=
cleanup() { touch "$work/release"; [[ -z "$pid" ]] || wait "$pid" || true; rm -rf -- "$work"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
wf_init "$work/fixture"
bash "$repo/install.sh" --tool agy --no-watch-agy --yes > /dev/null 2>&1
cat > "$work/fixture/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}; previous=${@: -2:1}
if [[ ${HCC_OWNER_HOLD:-0} == 1 && "$last" == "$HOME/.gemini/bin/agy" && "$previous" == *'.hcc-new.'* ]]; then
 touch "$HCC_OWNER_READY"
 for ((i=0;i<500;i++)); do [[ -f "$HCC_OWNER_RELEASE" ]] && break; sleep .02; done
fi
exec /usr/bin/mv "$@"
FIXTURE
chmod +x "$work/fixture/bin/mv"
digest=$(sha256sum < "$work/fixture/original-binary");digest=${digest%% *}
args=(--tool agy --from-binary "$work/fixture/original-binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$work/fixture/bin/qemu" --watch-agy --yes)
HCC_OWNER_HOLD=1 HCC_OWNER_READY="$work/ready" HCC_OWNER_RELEASE="$work/release" bash "$repo/install.sh" "${args[@]}" > "$work/first.log" 2>&1 &
pid=$!
for ((i=0;i<250;i++)); do [[ -f "$work/ready" ]] && break; sleep .02; done
[[ -f "$work/ready" ]] || fail 'first installer did not reach publication gate'
set +e
HCC_STATE_DIR="$HOME/second-state" bash "$repo/install.sh" "${args[@]}" > "$work/second.log" 2>&1
second=$?
touch "$work/release"
wait "$pid"; first=$?
pid=
set -e
[[ $second != 0 && $first == 0 && $(< "$HOME/.gemini/bin/.hcc-watch-owner") == "$root" ]] || fail 'concurrent state roots raced past ownership reservation and published conflicting launchers'
[[ ! -e "$HOME/second-state" ]] || fail 'losing state root mutated installation state'
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'winning installation unusable'
printf 'PASS watcher owners: atomic pre-publication claim serializes independent state roots\n'
