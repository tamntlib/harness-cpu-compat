#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-qemu-install.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
setup() {
    case_dir="$work/$1"; mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
    for cmd in bash basename cat chmod cmp cp date dirname env flock grep head ln mkdir mktemp mv readlink realpath rm rmdir sha256sum sleep stat timeout tr uname; do
        ln -s "$(command -v "$cmd")" "$case_dir/bin/$cmd"
    done
    printf 'old-entry\n' > "$case_dir/home/.local/bin/claude"
    printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> %q\n[[ "$1" == -- ]] && shift\nexec "$@"\n' "$case_dir/log" > "$case_dir/bin/sudo"
    printf '#!/bin/bash\nprintf "apt %%s\\n" "$*" >> %q\n[[ ! -e /proc/$$/fd/8 && ! -e /proc/$$/fd/9 ]] || exit 88\n[[ "$1" != install ]] || { cp -- %q %q; chmod +x %q; printf installed > %q; }\n' "$case_dir/log" "$case_dir/qemu" "$case_dir/bin/qemu-x86_64" "$case_dir/bin/qemu-x86_64" "$case_dir/package" > "$case_dir/bin/apt-get"
    printf '#!/bin/bash\nif [[ -f %q ]]; then cat %q; else echo "dpkg-query: no packages found matching qemu-user" >&2; exit 1; fi\n' "$case_dir/package" "$case_dir/package" > "$case_dir/bin/dpkg-query"
    printf '#!/bin/bash\n[[ "$1" == -cpu && "$2" == max ]] || exit 90\nshift 2\nexport EMULATED=1\nexec "$@"\n' > "$case_dir/qemu"
    printf '#!/bin/bash\ncase "$1" in --version) echo 1.0.0;; --help) [[ ${EMULATED:-0} == 1 ]] || exit 70; echo help;; esac\n' > "$case_dir/binary"
    chmod +x "$case_dir/bin/sudo" "$case_dir/bin/apt-get" "$case_dir/bin/dpkg-query" "$case_dir/binary" "$case_dir/qemu"
    digest=$(sha256sum < "$case_dir/binary"); digest=${digest%% *}
}
install_case() {
    local terminal=()
    if [[ ${package_terminal:-1} == 1 ]]; then terminal=("$(command -v python3)" "$repo/tests/tty-run.py" "${package_answer:-y}"); fi
    "${terminal[@]}" env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool claude --from-binary "$case_dir/binary" --version 1.0.0 --sha256 "$digest" --yes "$@" > "$case_dir/out" 2>&1
}
uninstall_case() {
    local terminal=()
    if [[ ${package_terminal:-1} == 1 ]]; then terminal=("$(command -v python3)" "$repo/tests/tty-run.py" "${package_answer:-y}"); fi
    "${terminal[@]}" env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash "$repo/uninstall.sh" --tool claude --yes "$@" > "$case_dir/uninstall-out" 2>&1
}
purge_shim() {
    printf '#!/bin/bash\n[[ ! -e /proc/$$/fd/8 && ! -e /proc/$$/fd/9 ]] || exit 88\n[[ "$*" == *APT::Get::AutomaticRemove=false* ]] || exit 89\nprintf "apt %%s\\n" "$*" >> %q\nif [[ "$1" == -s ]]; then printf "%%s\\n" %q; elif [[ %q == fail ]]; then exit 66; else rm -f -- %q %q; fi\n' "$case_dir/log" "${purge_plan:-Purg qemu-user [1.0]}" "${purge_result:-ok}" "$case_dir/package" "$case_dir/bin/qemu-x86_64" > "$case_dir/bin/apt-get"
}
setup no-package-consent
if package_terminal=0 install_case < /dev/null; then fail '--yes bypassed the independent QEMU confirmation'; fi
[[ ! -e "$case_dir/log" && $(< "$case_dir/home/.local/bin/claude") == old-entry ]] || fail 'missing package consent mutated state'
setup install
install_case || { cat "$case_dir/out"; fail 'missing QEMU was not installed'; }
[[ -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'HCC-installed package has no removal provenance'
[[ $(< "$case_dir/log") == *$'apt update\n'* && $(< "$case_dir/log") == *'apt install -y --no-install-recommends --reinstall qemu-user' ]] || fail 'APT command contract'
[[ $(HOME="$case_dir/home" PATH="$case_dir/bin" "$case_dir/home/.local/bin/claude" --version) == 1.0.0 ]] || fail 'installed launcher cannot run'
before=$(< "$case_dir/log")
install_case || fail 'repeat installation'
[[ $(< "$case_dir/log") == "$before" ]] || fail 'existing QEMU was reinstalled'
# Failure paths must preserve the public entry and never select a release.
refused() {
    if install_case "$@"; then fail 'unexpected installation success'; fi
    [[ $(< "$case_dir/home/.local/bin/claude") == old-entry ]] || fail 'failure changed public entry'
    [[ ! -e "$case_dir/home/.local/share/harness-cpu-compat/tools/claude/current" ]] || fail 'failure changed selection'
}
no_packages() { [[ ! -e "$case_dir/log" ]] || fail 'unexpected APT/sudo action'; }
setup explicit
refused --qemu "$case_dir/missing"
no_packages
setup native-failure
refused --mode native
no_packages
setup existing-failure
printf '#!/bin/bash\nexit 77\n' > "$case_dir/bin/qemu-x86_64"; chmod +x "$case_dir/bin/qemu-x86_64"
refused
no_packages
setup no-apt
rm "$case_dir/bin/apt-get"
refused
grep -q 'requires APT' "$case_dir/out" || fail 'unsupported package manager message'
no_packages
if (( EUID != 0 )); then
    setup no-sudo
    rm "$case_dir/bin/sudo"
    refused
    grep -q 'requires sudo or root' "$case_dir/out" || fail 'missing sudo message'
    no_packages
    setup auth-failure
    printf '#!/bin/bash\nexit 1\n' > "$case_dir/bin/sudo"
    refused
    no_packages
fi
for phase in update install; do
    setup "fail-$phase"
    printf '#!/bin/bash\necho "apt $*" >> %q\n[[ "$1" != %q ]]\n' "$case_dir/log" "$phase" > "$case_dir/bin/apt-get"
    refused
    if [[ "$phase" == update ]]; then
        ! grep -q 'apt install' "$case_dir/log" || fail 'install followed update failure'
    fi
done
setup absent-after-install
printf '#!/bin/bash\nexit 0\n' > "$case_dir/bin/apt-get"
refused
setup bad-after-install
printf '#!/bin/bash\nexit 78\n' > "$case_dir/qemu"
refused
grep -q 'changes are retained' "$case_dir/out" || fail 'missing package retention warning'
# Native success, inspection and uninstall never need package privileges.
setup native-success
printf '#!/bin/bash\ncase "$1" in --version) echo 1.0.0;; --help) echo help;; esac\n' > "$case_dir/binary"
digest=$(sha256sum < "$case_dir/binary"); digest=${digest%% *}
install_case || fail 'native install failed'
for mode in --doctor --dry-run; do
    HOME="$case_dir/home" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool claude "$mode" >/dev/null
 done
HOME="$case_dir/home" PATH="$case_dir/bin" /bin/bash "$repo/uninstall.sh" --tool claude --yes >/dev/null
no_packages
setup forced
install_case --mode qemu || fail 'forced QEMU installation'
before=$(< "$case_dir/log")
rm "$case_dir/bin/qemu-x86_64"
if HOME="$case_dir/home" PATH="$case_dir/bin" "$case_dir/home/.local/bin/claude" --version > "$case_dir/runtime-out" 2>&1; then fail 'runtime unexpectedly repaired missing QEMU'; fi
HOME="$case_dir/home" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool agy --no-auto-repair --yes > "$case_dir/disable-out" 2>&1
[[ $(< "$case_dir/log") == "$before" ]] || fail 'runtime/disable installed packages'
setup no-consent
# Omit --yes, retain noninteractive stdin.
if env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool claude --from-binary "$case_dir/binary" --version 1.0.0 --sha256 "$digest" < /dev/null > "$case_dir/out" 2>&1; then fail 'noninteractive consent bypass'; fi
no_packages
# The shared probe's default is deny, including misleading environment values.
setup worker-denied
mkdir "$case_dir/probe"
cp "$case_dir/binary" "$case_dir/probe/binary"
if env -i HOME="$case_dir/home" PATH="$case_dir/bin" HCC_ALLOW_PACKAGE_INSTALL=1 HCC_YES=1 /bin/bash -c 'source "$1/lib/common.sh"; HCC_VERSION=1.0.0; hcc_probe "$2/probe" qemu ""' -- "$repo" "$case_dir" > "$case_dir/out" 2>&1; then fail 'shared worker probe installed packages'; fi
no_packages
setup remove-owned
install_case || fail 'owned package fixture install failed'
purge_shim
uninstall_case || { cat "$case_dir/uninstall-out"; fail 'owned package removal failed'; }
[[ ! -e "$case_dir/package" && ! -e "$case_dir/home/.local/share/harness-cpu-compat" ]] || fail 'confirmed uninstall did not remove owned QEMU and HCC state'
for answer in n EOF; do
    setup "decline-install-$answer"
    if package_answer=$answer install_case; then fail 'declined QEMU installation succeeded'; fi
    no_packages
    [[ $(< "$case_dir/home/.local/bin/claude") == old-entry ]] || fail 'declined package install changed entry'
done
setup preexisting-package
printf installed > "$case_dir/package"
install_case || fail 'preexisting package reinstall failed'
[[ ! -e "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'preexisting package became HCC owned'
before=$(< "$case_dir/log")
uninstall_case || fail 'preexisting package uninstall failed'
[[ $(< "$case_dir/log") == "$before" && -f "$case_dir/package" && ! -e "$case_dir/home/.local/share/harness-cpu-compat" ]] || fail 'preexisting package removed or HCC cleanup incomplete'
for answer in n EOF no-tty; do
    setup "keep-owned-$answer"
    install_case || fail 'keep-owned fixture install failed'
    before=$(< "$case_dir/log")
    if [[ "$answer" == no-tty ]]; then package_terminal=0 uninstall_case < /dev/null || fail 'noninteractive keep failed';
    else package_answer=$answer uninstall_case || fail 'declined removal failed'; fi
    [[ $(< "$case_dir/log") == "$before" && -f "$case_dir/package" && ! -e "$case_dir/home/.local/share/harness-cpu-compat" ]] || fail 'declined removal invoked APT or left HCC state'
done
setup partial
install_case || fail 'partial fixture install failed'
env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool agy --from-binary "$case_dir/binary" --version 1.0.0 --sha256 "$digest" --mode qemu --yes > "$case_dir/other-out" 2>&1 || fail 'other tool install failed'
before=$(< "$case_dir/log")
uninstall_case --tool agy || fail 'partial uninstall failed'
[[ $(< "$case_dir/log") == "$before" && -L "$case_dir/home/.local/share/harness-cpu-compat/tools/claude/current" && -f "$case_dir/package" ]] || fail 'partial uninstall offered or removed shared QEMU'
purge_shim
uninstall_case || fail 'last tool package removal failed'
[[ ! -e "$case_dir/home/.local/share/harness-cpu-compat" && ! -e "$case_dir/package" ]] || fail 'final removal retained package/state'
for scenario in forbidden-plan installing-plan invalid-plan purge-failure; do
    setup "$scenario"
    install_case || fail 'purge refusal fixture install failed'
    case "$scenario" in
        forbidden-plan) purge_plan=$'Purg qemu-user [1.0]\nRemv unrelated-package [1.0]' purge_shim;;
        installing-plan) purge_plan=$'Purg qemu-user [1.0]\nInst unrelated-package [1.0]' purge_shim;;
        invalid-plan) purge_plan='unparseable package output' purge_shim;;
        purge-failure) purge_result=fail purge_shim;;
    esac
    if uninstall_case; then fail 'unsafe/failed purge reported success'; fi
    [[ -f "$case_dir/package" && -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'failed purge lost ownership'
    [[ ! -e "$case_dir/home/.local/share/harness-cpu-compat/operation.lock" && ! -e "$case_dir/home/.local/share/harness-cpu-compat/program" ]] || fail 'failed purge retained locks/runtime'
    [[ $(readlink "$case_dir/home/.local/bin/claude") == "$case_dir/home/.local/share/claude/versions/1.0.0" ]] || fail 'failed purge undid native handoff'
    purge_shim
    uninstall_case || fail 'metadata-only purge retry failed'
    [[ ! -e "$case_dir/home/.local/share/harness-cpu-compat" && ! -e "$case_dir/package" ]] || fail 'purge retry retained state'
done
setup agy-purge-failure
install_case --tool agy || fail 'AGY purge-failure fixture install failed'
purge_result=fail purge_shim
if uninstall_case --tool agy; then fail 'AGY purge failure reported success'; fi
[[ ! -e "$case_dir/home/.gemini/bin/.hcc-watch-owner" && -f "$case_dir/home/.gemini/bin/agy" && ! -L "$case_dir/home/.gemini/bin/agy" ]] || fail 'package failure stranded AGY claim or lost native primary'
purge_shim
uninstall_case --tool agy || fail 'AGY metadata-only retry failed'
setup already-removed-package
install_case || fail 'already removed package fixture install failed'
before=$(< "$case_dir/log")
rm "$case_dir/package"
package_terminal=0 uninstall_case < /dev/null || fail 'already removed package cleanup failed'
[[ $(< "$case_dir/log") == "$before" && ! -e "$case_dir/home/.local/share/harness-cpu-compat" ]] || fail 'absent package caused APT or left HCC state'
setup failed-probe-owned
printf '#!/bin/bash\nexit 78\n' > "$case_dir/qemu"
refused
[[ -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'failed probe lost package ownership'
purge_shim
uninstall_case || fail 'failed application install package cleanup failed'
[[ ! -e "$case_dir/home/.local/share/harness-cpu-compat" && ! -e "$case_dir/package" ]] || fail 'failed-install package cleanup incomplete'
setup owned-reinstall
install_case || fail 'owned reinstall fixture failed'
rm "$case_dir/bin/qemu-x86_64"
install_case || fail 'owned package repair failed'
[[ -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'reinstall forgot HCC ownership'
setup unknown-dpkg
printf '#!/bin/bash\necho "unreadable database" >&2\nexit 2\n' > "$case_dir/bin/dpkg-query"
refused
no_packages
setup malformed-ownership
mkdir -p "$case_dir/home/.local/share/harness-cpu-compat"
printf 'arbitrary-package\n' > "$case_dir/home/.local/share/harness-cpu-compat/qemu-package"
refused
no_packages
setup symlink-ownership
mkdir -p "$case_dir/home/.local/share/harness-cpu-compat"
printf 'hcc-qemu-package-v1\nqemu-user\n' > "$case_dir/foreign-record"
ln -s "$case_dir/foreign-record" "$case_dir/home/.local/share/harness-cpu-compat/qemu-package"
refused
no_packages
setup declined-record-delete-failure
install_case || fail 'record-delete failure fixture install failed'
rm "$case_dir/bin/rm"
printf '#!/bin/bash\nfor path in "$@"; do [[ "$path" != "$HOME/.local/share/harness-cpu-compat/qemu-package" ]] || exit 44; done\nexec %q "$@"\n' "$(command -v rm)" > "$case_dir/bin/rm"
chmod +x "$case_dir/bin/rm"
if package_answer=n uninstall_case; then fail 'failed ownership-record deletion reported success'; fi
[[ -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'failed record delete lost retry state'
setup piped-package-consent
for command in tar gzip wc; do ln -s "$(command -v "$command")" "$case_dir/bin/$command"; done
mkdir -p "$case_dir/bundle/harness-cpu-compat-main/lib"
for file in install.sh uninstall.sh lib/common.sh lib/runtime.sh lib/watch.sh; do cp "$repo/$file" "$case_dir/bundle/harness-cpu-compat-main/$file"; done
tar -czf "$case_dir/archive.tgz" -C "$case_dir/bundle" harness-cpu-compat-main
printf '#!/bin/bash\nwhile (( $# )); do if [[ "$1" == --output ]]; then output=$2; shift 2; else shift; fi; done\ncp -- %q "$output"\n' "$case_dir/archive.tgz" > "$case_dir/bin/curl"
chmod +x "$case_dir/bin/curl"
"$(command -v python3)" "$repo/tests/tty-run.py" y env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash -c 'cat "$1/install.sh" | bash -s -- --tool claude --from-binary "$2" --version 1.0.0 --sha256 "$3" --yes' -- "$repo" "$case_dir/binary" "$digest" > "$case_dir/pipe-out" 2>&1 || { cat "$case_dir/pipe-out"; fail 'piped install lost controlling-terminal confirmation'; }
[[ -f "$case_dir/home/.local/share/harness-cpu-compat/qemu-package" ]] || fail 'piped install lost provenance'
purge_shim
"$(command -v python3)" "$repo/tests/tty-run.py" y env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash -c 'cat "$1/uninstall.sh" | bash -s -- --tool claude --yes' -- "$repo" > "$case_dir/pipe-out" 2>&1 || { cat "$case_dir/pipe-out"; fail 'piped uninstall lost controlling-terminal confirmation'; }
[[ ! -e "$case_dir/package" && ! -e "$case_dir/home/.local/share/harness-cpu-compat" ]] || fail 'piped package removal incomplete'
printf 'PASS QEMU dependency lifecycle: independent TTY consent, negative/EOF/headless defaults, provenance/reuse, preexisting retention, partial/final removal, purge allowlist/failure/retry, unsafe-state refusal and piped TTY confirmation\n'
