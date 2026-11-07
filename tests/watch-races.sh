#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-watch-races.XXXXXX")
trap 'exec 7>&-; rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
WF_BASE_PATH=$PATH
source "$repo/tests/watch-fixtures.sh"
for fault in before-capture before-capture-symlink parent-swap link-file link-directory link-symlink alias-link killed-capture open-writer; do
    wf_init "$work/$fault"; wf_feed 1.0.1
    export HCC_RACE_MODE=$fault HCC_RACE_MARKER="$work/$fault/injected"
    printf 'concurrent-foreign-entry\n' > "$work/$fault/foreign"
    export HCC_RACE_FOREIGN="$work/$fault/foreign"
    old=$(readlink "$root/tools/agy/current")
    cp "$HCC_FEED/cli" "$HOME/.gemini/bin/agy"
    if [[ "$fault" == open-writer ]]; then exec 7<> "$HOME/.gemini/bin/agy"; fi
    cat > "$work/$fault/bin/mv" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}
if [[ "$last" == *'/captured' && "$PWD" == "$HOME/.gemini/bin" && ! -e "$HCC_RACE_MARKER" ]]; then
 case "$HCC_RACE_MODE" in
  before-capture) touch "$HCC_RACE_MARKER"; /usr/bin/cp "$HCC_RACE_FOREIGN" "$HOME/.gemini/bin/agy";;
  before-capture-symlink) touch "$HCC_RACE_MARKER"; rm "$HOME/.gemini/bin/agy"; /usr/bin/ln -s /nonexistent-fixture-target "$HOME/.gemini/bin/agy";;
  parent-swap)
   touch "$HCC_RACE_MARKER"; slot=$(basename "$(dirname "$last")")
   /usr/bin/mv "$HOME/.gemini/bin" "$HOME/.gemini/kept"
   mkdir -p "$HOME/.gemini/bin/$slot"
   /usr/bin/cp "$HCC_RACE_FOREIGN" "$HOME/.gemini/bin/agy"
   printf 'untrusted prepared replacement\n' > "$HOME/.gemini/bin/$slot/prepared";;
  killed-capture) /usr/bin/mv "$@"; touch "$HCC_RACE_MARKER"; kill -KILL "$PPID"; exit 99;;
 esac
fi
exec /usr/bin/mv "$@"
FIXTURE
    cat > "$work/$fault/bin/ln" <<'FIXTURE'
#!/usr/bin/env bash
last=${!#}; previous=${@: -2:1}
if [[ "$previous" == *'/prepared' && ! -e "$HCC_RACE_MARKER" ]]; then
 case "$HCC_RACE_MODE:$PWD" in
  link-file:"$HOME/.gemini/bin") touch "$HCC_RACE_MARKER"; /usr/bin/cp "$HCC_RACE_FOREIGN" "$HOME/.gemini/bin/agy";;
  link-directory:"$HOME/.gemini/bin") touch "$HCC_RACE_MARKER"; mkdir "$HOME/.gemini/bin/agy"; /usr/bin/cp "$HCC_RACE_FOREIGN" "$HOME/.gemini/bin/agy/sentinel";;
  link-symlink:"$HOME/.gemini/bin") touch "$HCC_RACE_MARKER"; /usr/bin/ln -s /nonexistent-fixture-target "$HOME/.gemini/bin/agy";;
  alias-link:"$HOME/.local/bin") touch "$HCC_RACE_MARKER"; /usr/bin/cp "$HCC_RACE_FOREIGN" "$HOME/.local/bin/agy";;
  open-writer:"$HOME/.gemini/bin") touch "$HCC_RACE_MARKER"; printf 'written-through-open-descriptor\n' >&7;;
 esac
fi
exec /usr/bin/ln "$@"
FIXTURE
    chmod +x "$work/$fault/bin/mv" "$work/$fault/bin/ln"
    set +e
    bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > "$work/$fault/worker.log" 2>&1
    status=$?
    set -e
    [[ -f "$HCC_RACE_MARKER" ]] || fail "fault did not reach publication boundary: $fault"
    if [[ "$fault" == open-writer ]]; then
        exec 7>&-
        [[ $status == 0 && ! -e "$root/watch/pending" ]] || fail 'open writer prevented verified private-copy publication'
        [[ $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'writer changed executable selected by wrapper'
        actual=$(sha256sum "$(readlink "$root/tools/agy/current")/binary"); wanted=$(sha256sum "$HCC_FEED/cli")
        [[ ${actual%% *} == "${wanted%% *}" ]] || fail 'unverified captured bytes entered private release'
    else
        [[ $status != 0 && -f "$root/watch/pending" && $(readlink "$root/tools/agy/current") == "$old" ]] || fail "race committed or lost recovery marker: $fault"
        case "$fault" in
            before-capture|parent-swap|link-file) [[ $(< "$HOME/.gemini/bin/agy") == concurrent-foreign-entry ]] || fail 'foreign file lost';;
            before-capture-symlink|link-symlink) [[ -L "$HOME/.gemini/bin/agy" && $(readlink "$HOME/.gemini/bin/agy") == /nonexistent-fixture-target ]] || fail 'foreign symlink lost';;
            link-directory) [[ $(< "$HOME/.gemini/bin/agy/sentinel") == concurrent-foreign-entry ]] || fail 'foreign directory lost';;
            alias-link)
                [[ $(< "$HOME/.local/bin/agy") == concurrent-foreign-entry ]] || fail 'foreign alias lost'
                [[ $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'partially published primary ran stale mutable current';;
        esac
        if bash "$repo/lib/watch.sh" --reconcile "$root" "$HOME" > /dev/null 2>&1; then fail 'interrupted publication silently retried'; fi
    fi
done
printf 'PASS watcher races: capture/link/alias drift, directory and symlink destinations, SIGKILL journal, open-writer isolation and immutable partial publication\n'
