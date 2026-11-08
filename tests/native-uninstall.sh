#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-native-uninstall.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export HOME="$work/home"
unset XDG_DATA_HOME XDG_CONFIG_HOME HCC_STATE_DIR
mkdir -p "$HOME" "$work/bin"
printf '#!/bin/bash\n[[ "$1" == -cpu && "$2" == max ]] || exit 90\nshift 2\nexec "$@"\n' > "$work/bin/qemu"
chmod +x "$work/bin/qemu"
root="$HOME/.local/share/harness-cpu-compat"
fixture() {
    printf '#!/bin/bash\ncase "$1" in --version) echo %q;; --help) echo help;; esac\n' "$1" > "$work/binary"
    chmod +x "$work/binary"
    digest=$(sha256sum < "$work/binary"); digest=${digest%% *}
}
install_tool() {
    bash "$repo/install.sh" --tool "$1" --from-binary "$work/binary" --version "$2" --sha256 "$digest" --mode qemu --qemu "$work/bin/qemu" --yes > "$work/install.log" 2>&1
}
fixture 1.0.0
install_tool agy 1.0.0
fixture 1.1.0
install_tool agy 1.1.0
bash "$repo/uninstall.sh" --tool agy --yes > "$work/uninstall.log" 2>&1 || { cat "$work/uninstall.log"; fail 'AGY native handoff failed'; }
[[ -f "$HOME/.gemini/bin/agy" && ! -L "$HOME/.gemini/bin/agy" ]] || fail 'AGY native executable missing'
[[ $(sha256sum < "$HOME/.gemini/bin/agy") == "$digest  -" ]] || fail 'AGY did not retain current version'
[[ -L "$HOME/.local/bin/agy" && $(readlink "$HOME/.local/bin/agy") == "$HOME/.gemini/bin/agy" ]] || fail 'AGY native CLI alias missing'
[[ ! -e "$root/tools/agy" && ! -e "$root/releases/agy" ]] || fail 'AGY successful state was retained'
[[ $("$HOME/.local/bin/agy" --version) == 1.1.0 ]] || fail 'AGY still depends on HCC'
printf 'PASS native AGY uninstall: current version, vendor path, independent native alias, no tool state\n'
fixture 1.2.3-beta
install_tool claude 1.2.3-beta
for name in original alias-original installed alias-installed conflicts history; do
    [[ ! -e "$root/tools/claude/$name" ]] || fail "obsolete persistent metadata remains: $name"
done
bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1 || { cat "$work/uninstall.log"; fail 'Claude native handoff failed'; }
[[ $(readlink "$HOME/.local/bin/claude") == "$HOME/.local/share/claude/versions/1.2.3-beta" ]] || fail 'Claude canonical native layout'
[[ $("$HOME/.local/bin/claude" --version) == 1.2.3-beta ]] || fail 'Claude current version lost'
[[ ! -e "$root/tools/claude" && ! -e "$root/releases/claude" ]] || fail 'Claude successful state was retained'
printf 'PASS no baseline metadata and current prerelease Claude native layout\n'
# A vendor update already placed native bytes at the primary entry: do not downgrade it.
fixture 2.0.0
install_tool agy 2.0.0
printf '\177ELFnewer-vendor-artifact' > "$HOME/.gemini/bin/agy"
chmod +x "$HOME/.gemini/bin/agy"
foreign=$(sha256sum < "$HOME/.gemini/bin/agy")
bash "$repo/uninstall.sh" --tool agy --yes > "$work/uninstall.log" 2>&1 || { cat "$work/uninstall.log"; fail 'independent vendor replacement was not preserved'; }
[[ $(sha256sum < "$HOME/.gemini/bin/agy") == "$foreign" ]] || fail 'native vendor replacement was downgraded'
[[ $(readlink "$HOME/.local/bin/agy") == "$HOME/.gemini/bin/agy" ]] || fail 'alias did not follow preserved vendor primary'
printf 'PASS independent native vendor update preserved without downgrade\n'
fixture 3.0.0
install_tool claude 3.0.0
printf '9.0.0\n' > "$root/tools/claude/current/version"
if bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1; then fail 'version metadata disconnected from selected artifact was accepted'; fi
[[ -L "$root/tools/claude/current" ]] || fail 'bad version metadata lost selected state'
printf '3.0.0\n' > "$root/tools/claude/current/version"
bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1
printf 'PASS selected release version binding\n'
# A canonical native version must not overwrite a different preexisting file.
fixture 4.0.0
install_tool claude 4.0.0
mkdir -p "$HOME/.local/share/claude/versions"
printf 'independent canonical file' > "$HOME/.local/share/claude/versions/4.0.0"
if bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1; then fail 'canonical version collision overwritten'; fi
[[ $(< "$HOME/.local/share/claude/versions/4.0.0") == 'independent canonical file' && ! -e "$root/tools/claude/pending" ]] || fail 'canonical collision mutated state'
rm "$HOME/.local/share/claude/versions/4.0.0"
# A native-looking path whose parent is still in HCC cannot survive state cleanup.
mv "$HOME/.local/share/claude/versions" "$HOME/.local/share/claude/versions-kept"
ln -s "$root/releases/claude" "$HOME/.local/share/claude/versions"
if bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1; then fail 'native parent depending on HCC accepted'; fi
[[ -L "$root/tools/claude/current" && ! -e "$root/tools/claude/pending" ]] || fail 'parent dependency changed state'
rm "$HOME/.local/share/claude/versions"
mv "$HOME/.local/share/claude/versions-kept" "$HOME/.local/share/claude/versions"
bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1
# A newer independent Claude installation is preserved, not replaced with selection 5.0.0.
fixture 5.0.0
install_tool claude 5.0.0
printf '\177ELFindependent-newer-claude' > "$HOME/.local/share/claude/versions/5.1.0"
chmod +x "$HOME/.local/share/claude/versions/5.1.0"
rm "$HOME/.local/bin/claude"
ln -s "$HOME/.local/share/claude/versions/5.1.0" "$HOME/.local/bin/claude"
bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1
[[ $(readlink "$HOME/.local/bin/claude") == "$HOME/.local/share/claude/versions/5.1.0" && ! -e "$HOME/.local/share/claude/versions/5.0.0" ]] || fail 'newer independent Claude downgraded'
# Partial selection cleanup must leave another managed tool and the lock inodes intact.
fixture 6.0.0
install_tool claude 6.0.0
fixture 6.1.0
install_tool agy 6.1.0
locks=$(stat -c '%i' "$root/operation.lock" "$root/watch/management.lock")
mkdir -p "$HOME/.config/example-app"
printf 'user-data-canary' > "$HOME/.config/example-app/settings.json"
qemu_before=$(sha256sum < "$work/bin/qemu")
bash "$repo/uninstall.sh" --tool agy --yes > "$work/uninstall.log" 2>&1
[[ -f "$root/program/lib/runtime.sh" && $("$HOME/.local/bin/claude" --version) == 6.0.0 ]] || fail 'partial uninstall broke other managed tool'
[[ $(stat -c '%i' "$root/operation.lock" "$root/watch/management.lock") == "$locks" ]] || fail 'partial uninstall changed live locks'
bash "$repo/uninstall.sh" --tool claude --yes > "$work/uninstall.log" 2>&1
[[ ! -e "$root" ]] || fail 'final uninstall left HCC files or locks behind'
bash "$repo/uninstall.sh" --tool all --yes > "$work/repeat.log" 2>&1
[[ $(< "$HOME/.config/example-app/settings.json") == user-data-canary && $(sha256sum < "$work/bin/qemu") == "$qemu_before" ]] || fail 'uninstall changed unrelated configuration or emulator'
printf 'PASS native handoff boundaries: canonical collisions, parent independence, newer native preservation, partial/shared cleanup, final root removal and user data\n'
# Review regressions: legitimate symlinked parents and watcher-independent XDG config.
failures=0
basepath=$PATH
for scenario in claude-bin-link claude-versions-link agy-primary-link agy-alias-link claude-external-config agy-external-config; do
    export HOME="$work/environment/$scenario/home"
    unset XDG_CONFIG_HOME
    mkdir -p "$HOME/.local/bin" "$HOME/.gemini/bin" "$HOME/real-bin" "$HOME/native-versions" "$work/environment/$scenario/bin"
    tool=claude
    case "$scenario" in
        claude-bin-link|agy-alias-link) rmdir "$HOME/.local/bin"; ln -s "$HOME/real-bin" "$HOME/.local/bin";;
        agy-primary-link) rmdir "$HOME/.gemini/bin"; ln -s "$HOME/real-bin" "$HOME/.gemini/bin";;
        claude-versions-link) mkdir -p "$HOME/.local/share/claude"; ln -s "$HOME/native-versions" "$HOME/.local/share/claude/versions";;
        *-external-config) export XDG_CONFIG_HOME="$work/environment/$scenario/config"; mkdir -p "$XDG_CONFIG_HOME";;
    esac
    [[ "$scenario" != agy-* ]] || tool=agy
    export HCC_MANAGER_CALLED="$work/environment/$scenario/manager-called"
    printf '#!/bin/bash\ntouch "$HCC_MANAGER_CALLED"\nexit 92\n' > "$work/environment/$scenario/bin/systemctl"
    chmod +x "$work/environment/$scenario/bin/systemctl"
    export PATH="$work/environment/$scenario/bin:$basepath"
    fixture 7.0.0
    install_tool "$tool" 7.0.0
    root="$HOME/.local/share/harness-cpu-compat"
    if ! bash "$repo/uninstall.sh" --tool "$tool" --yes > "$work/uninstall.log" 2>&1; then
        cat "$work/uninstall.log"; printf 'FAIL native environment: %s\n' "$scenario" >&2
        failures=$((failures+1)); continue
    fi
    [[ ! -e "$root/tools/$tool" && ! -e "$root/program" && ! -e "$HCC_MANAGER_CALLED" ]] || fail "state cleanup or default-off manager boundary: $scenario"
    [[ $("$HOME/.local/bin/$tool" --version) == 7.0.0 ]] || fail "native entry broken: $scenario"
    if [[ "$tool" == agy ]]; then
        [[ ! -e "$HOME/.gemini/bin/.hcc-watch-owner" ]] || fail 'completed handoff stranded global claim'
        HCC_STATE_DIR="$HOME/another-root" bash "$repo/install.sh" --tool agy --from-binary "$work/binary" --version 7.0.0 --sha256 "$digest" --mode native --yes > "$work/reinstall.log" 2>&1 || fail 'next state root could not acquire released claim'
    fi
done
(( failures == 0 )) || fail "$failures native environment regressions"
printf 'PASS native environment: canonical slot parents, symlinked CLI/version paths, default-off external XDG config and released cross-root claims\n'
