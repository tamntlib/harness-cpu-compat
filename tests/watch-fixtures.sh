#!/usr/bin/env bash
# Synthetic publisher/manager fixtures, never vendor bundles or account data.
wf_binary() {
    local version=$1 destination=$2
    printf '#!/usr/bin/env bash\ncase "${1:-}" in\n --version) echo %q;;\n --help) [[ ${HCC_TEST_EMULATED:-0} == 1 ]] || exit 132; echo help;;\n *) printf "app-%%s\\n" %q;;\nesac\n' "$version" "$version" > "$destination"
    chmod +x "$destination"
}
wf_feed() {
    local version=$1 digest
    mkdir -p "$HCC_FEED"
    wf_binary "$version" "$HCC_FEED/cli"
    tar -czf "$HCC_FEED/payload.tar.gz" -C "$HCC_FEED" cli
    digest=$(sha512sum < "$HCC_FEED/payload.tar.gz"); digest=${digest%% *}
    jq -n --arg version "$version" --arg digest "$digest" '{version:$version,url:"https://storage.googleapis.com/antigravity-public/fixture/agy.tar.gz",sha512:$digest}' > "$HCC_FEED/manifest.json"
}
wf_init() {
    local directory=$1
    export HOME="$directory/home" HCC_FEED="$directory/feed" HCC_NETWORK_LOG="$directory/network.log" HCC_SYSTEMCTL_LOG="$directory/systemctl.log"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME HCC_STATE_DIR
    mkdir -p "$HOME" "$directory/bin"
    cat > "$directory/bin/systemctl" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HCC_SYSTEMCTL_LOG"
FIXTURE
    cat > "$directory/bin/qemu" <<'FIXTURE'
#!/usr/bin/env bash
[[ "$1" == -cpu && "$2" == max ]] || exit 90
shift 2; export HCC_TEST_EMULATED=1; exec "$@"
FIXTURE
    cat > "$directory/bin/curl" <<'FIXTURE'
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
printf '%s\n' "$url" >> "$HCC_NETWORK_LOG"
case "$url" in
 https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json) cp "$HCC_FEED/manifest.json" "$output";;
 https://storage.googleapis.com/antigravity-public/fixture/agy.tar.gz) cp "$HCC_FEED/payload.tar.gz" "$output";;
 *) exit 92;;
esac
FIXTURE
    chmod +x "$directory/bin/"*
    export PATH="$directory/bin:$WF_BASE_PATH"
    wf_binary 1.0.0 "$directory/original-binary"
    local digest; digest=$(sha256sum < "$directory/original-binary");digest=${digest%% *}
    bash "$repo/install.sh" --tool agy --from-binary "$directory/original-binary" --version 1.0.0 --sha256 "$digest" --mode qemu --qemu "$directory/bin/qemu" --watch-agy --yes > "$directory/install.log" 2>&1
    root="$HOME/.local/share/harness-cpu-compat"
}
