#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-distribution.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home" HCC_FIXTURES="$work/feed"
unset XDG_DATA_HOME XDG_CACHE_HOME HCC_STATE_DIR
mkdir -p "$HOME" "$work/bin" "$HCC_FIXTURES"
cat > "$work/bin/curl" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
output=; url=
while (( $# )); do
 case "$1" in
  --output) output=$2;shift 2;;
  --proto|--proto-redir|--connect-timeout|--max-time|--retry) shift 2;;
  https://*) url=$1;shift;; *) shift;;
 esac
done
[[ -n "$output" && -n "$url" ]] || exit 91
case "$url" in
 https://downloads.claude.ai/claude-code-releases/latest) printf '%s\n' "$HCC_TEST_VERSION" > "$output";;
 https://downloads.claude.ai/claude-code-releases/*/manifest.json) cp "$HCC_FIXTURES/claude-manifest" "$output";;
 https://downloads.claude.ai/claude-code-releases/*/linux-x64/claude) cp "$HCC_FIXTURES/cli" "$output";;
 https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json) cp "$HCC_FIXTURES/agy-manifest" "$output";;
 https://storage.googleapis.com/antigravity-public/fixture/antigravity.tar.gz) cp "$HCC_FIXTURES/agy.tar.gz" "$output";;
 *) exit 92;;
esac
FIXTURE
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
make_feed() {
 export HCC_TEST_VERSION=$1
 printf '#!/usr/bin/env bash\ncase "${1:-}" in --version) echo %q;; --help) echo help;; *) echo app;; esac\n' "$1" > "$HCC_FIXTURES/cli"
 chmod +x "$HCC_FIXTURES/cli"
 local sha sha512
 sha=$(sha256sum "$HCC_FIXTURES/cli"); sha=${sha%% *}
 jq -n --arg v "$1" --arg s "$sha" '{version:$v,platforms:{"linux-x64":{checksum:$s}}}' > "$HCC_FIXTURES/claude-manifest"
 tar -czf "$HCC_FIXTURES/agy.tar.gz" -C "$HCC_FIXTURES" cli
 sha512=$(sha512sum "$HCC_FIXTURES/agy.tar.gz"); sha512=${sha512%% *}
 jq -n --arg v "$1" --arg s "$sha512" '{version:$v,url:"https://storage.googleapis.com/antigravity-public/fixture/antigravity.tar.gz",sha512:$s}' > "$HCC_FIXTURES/agy-manifest"
}
make_feed 1.0.0
bash "$repo/install.sh" --tool all --yes >/dev/null
[[ -L "$HOME/.local/bin/claude" ]] || fail 'native success should not add a custom launcher'
[[ $("$HOME/.local/bin/claude" --version) == 1.0.0 && $("$HOME/.gemini/bin/agy" --version) == 1.0.0 ]] || fail 'official-feed fixture installation'
make_feed 1.0.1
bash "$repo/install.sh" --tool all --yes >/dev/null
[[ $("$HOME/.local/bin/claude" --version) == 1.0.1 && $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'managed update stale'
[[ $(find "$HOME/.local/share/harness-cpu-compat/releases/agy" -name binary | wc -l) == 2 ]] || fail 'previous release not retained'
printf corrupt >> "$HCC_FIXTURES/agy.tar.gz"
if bash "$repo/install.sh" --tool agy --yes >/dev/null 2>&1; then fail 'corrupt publisher payload accepted'; fi
[[ $("$HOME/.gemini/bin/agy" --version) == 1.0.1 ]] || fail 'bad download replaced active release'
bash "$repo/uninstall.sh" --tool all --yes >/dev/null
[[ $("$HOME/.local/bin/claude" --version) == 1.0.1 && $(readlink "$HOME/.local/bin/claude") == "$HOME/.local/share/claude/versions/1.0.1" ]] || fail 'current native Claude not retained'
printf 'PASS distribution: synthetic publisher manifests/downloads, native direct execution, two-tool managed update, retained fallback, checksum rejection\n'
