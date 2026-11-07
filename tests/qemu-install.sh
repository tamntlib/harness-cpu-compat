#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:?}/hcc-qemu-install.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
setup() {
    case_dir="$work/$1"; mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
    for cmd in bash basename cat chmod cmp cp date dirname env flock grep head ln mkdir mktemp mv readlink realpath rm sha256sum sleep stat timeout tr uname; do
        ln -s "$(command -v "$cmd")" "$case_dir/bin/$cmd"
    done
    printf 'old-entry\n' > "$case_dir/home/.local/bin/claude"
    printf '#!/bin/bash\nprintf "sudo %%s\\n" "$*" >> %q\n[[ "$1" == -- ]] && shift\nexec "$@"\n' "$case_dir/log" > "$case_dir/bin/sudo"
    printf '#!/bin/bash\nprintf "apt %%s\\n" "$*" >> %q\n[[ ! -e /proc/$$/fd/8 && ! -e /proc/$$/fd/9 ]] || exit 88\n[[ "$1" != install ]] || { cp -- %q %q; chmod +x %q; }\n' "$case_dir/log" "$case_dir/qemu" "$case_dir/bin/qemu-x86_64" "$case_dir/bin/qemu-x86_64" > "$case_dir/bin/apt-get"
    printf '#!/bin/bash\n[[ "$1" == -cpu && "$2" == max ]] || exit 90\nshift 2\nexport EMULATED=1\nexec "$@"\n' > "$case_dir/qemu"
    printf '#!/bin/bash\ncase "$1" in --version) echo 1.0.0;; --help) [[ ${EMULATED:-0} == 1 ]] || exit 70; echo help;; esac\n' > "$case_dir/binary"
    chmod +x "$case_dir/bin/sudo" "$case_dir/bin/apt-get" "$case_dir/binary" "$case_dir/qemu"
    digest=$(sha256sum < "$case_dir/binary"); digest=${digest%% *}
}
install_case() {
    env -i HOME="$case_dir/home" TMPDIR="$case_dir" PATH="$case_dir/bin" /bin/bash "$repo/install.sh" --tool claude --from-binary "$case_dir/binary" --version 1.0.0 --sha256 "$digest" --yes "$@" > "$case_dir/out" 2>&1
}
setup install
install_case || { cat "$case_dir/out"; fail 'missing QEMU was not installed'; }
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
printf 'PASS QEMU auto-install: foreground APT, probes, lock FD isolation, reuse, refusals, native/read-only/uninstall/worker boundaries\n'
