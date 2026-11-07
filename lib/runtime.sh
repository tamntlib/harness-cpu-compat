#!/usr/bin/env bash
# No network, probing, retries, output decoration, or cleanup on user invocations.
set -euo pipefail
root=${1:?missing installation root}
tool=${2:?missing tool}
shift 2
case "$tool" in claude|agy) ;; *) printf 'Invalid tool\n' >&2; exit 64;; esac
selection="$root/tools/$tool/current/selection"
[[ -f "$selection" ]] || { printf 'Installation missing; run install.sh again.\n' >&2; exit 69; }
mapfile -t config < "$selection"
[[ ${#config[@]} == 3 ]] || { printf 'Invalid selection file\n' >&2; exit 65; }
real=${config[0]}; mode=${config[1]}; qemu=${config[2]}
[[ "$real" == "$root/releases/$tool/"*/binary && -f "$real" && ! -L "$real" && -x "$real" ]] || {
    printf 'Invalid or missing selected executable\n' >&2; exit 69;
}
case "$mode" in
    native) exec "$real" "$@";;
    qemu)
        [[ "$qemu" == /* && -x "$qemu" ]] || { printf 'QEMU missing; run install.sh --doctor.\n' >&2; exit 69; }
        exec "$qemu" -cpu max "$real" "$@";;
    *) printf 'Invalid execution mode\n' >&2; exit 65;;
esac
