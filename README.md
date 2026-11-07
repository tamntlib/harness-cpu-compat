# harness-cpu-compat

User-scoped Shell installers for **Claude Code** and **Antigravity CLI (`agy`)** on Linux x86_64. Try native execution first; use `qemu-x86_64 -cpu max` only when isolated `--version` **and** `--help` probes do not both succeed.

**Experimental compatibility tooling, not a vendor-supported distribution.** Antigravity Remote IDE support is experimental: its independent updater can overwrite the wrapper **before invoking it**. There is no transparent self-repair guarantee. Close affected IDE/CLI sessions, rerun the installer with `--repair`, then reconnect/reload. The project does not patch IDE JavaScript, install background services, or change CPU flags.

## Install

Requirements: Linux x86_64, Bash 4.4+, GNU coreutils, `flock`, `curl`, `jq`, `tar`, and normal system CA certificates. Emulation additionally needs **`qemu-x86_64`** (usually the `qemu-user` package). Install dependencies with your distribution's package manager; these scripts never run sudo or install packages. There is no Python, npm, or separate Node.js dependency.

```bash
git clone https://github.com/tamntlib/harness-cpu-compat.git
cd harness-cpu-compat
./install.sh --tool all
# Or choose one:
./install.sh --tool claude
./install.sh --tool agy
```

Without `--tool`, an interactive terminal asks which tool to install. Noninteractive runs require `--tool` and `--yes`. Install as the intended user, not with sudo. Add `$HOME/.local/bin` to `PATH` if it is not already present; shell profiles are not edited automatically.

```bash
claude --version
agy --version
```

Installation downloads official release manifests and payloads over HTTPS, checks their published SHA-256 (Claude) or SHA-512 (AGY), and probes the verified executable in a disposable HOME with a minimal environment and time limits. Native success installs a direct symlink, not a compatibility launcher. Otherwise a Shell launcher execs QEMU against the unchanged private binary. Arguments (including `--hub`/`--version`), environment, cwd, streams, signals, and exit status are forwarded; runtime invocations do not perform network requests, probes, cleanup, or version selection.

Checksums fetched from the publisher are integrity checks, not independent signatures. An explicit `--from-binary` import uses the checksum **you supply**; source provenance is then your responsibility.

## Inspect, update, and remove

```bash
./install.sh --doctor
./install.sh --dry-run --tool all
./install.sh --tool all --yes           # managed foreground update
./install.sh --tool agy --repair --yes  # preserve/replace a foreign-updated entry
./uninstall.sh --tool all
```

`--doctor` and `--dry-run` do not create directories, download anything, execute vendor binaries, or probe the emulator. Doctor reports entry ownership, selected paths/mode, stored binary checksums, and incomplete publication markers. It is an inspection report, not an authenticated readiness test.

**Use `install.sh` for updates while using this installation.** Direct vendor self-updates and IDE-managed acquisition are outside the managed-update contract; they may replace an entry or alter a private binary. No vendor update settings or environment variables are silently changed. `--repair` preserves a changed entry in `conflicts/` before replacing it. It does not merge vendor metadata, migrate credentials, or override an interrupted transaction. An altered stored release is refused rather than silently overwritten.

For exact versions, Claude accepts `--version X.Y.Z`, `stable`, or `latest`. AGY's public manifest exposes its current release only: use `latest` or that exact manifest version. A pinned previously downloaded executable can also be explicitly imported:

```bash
./install.sh --tool agy --from-binary /path/to/verified/agy \
  --version 1.5.2 --sha256 '<expected-sha256>' --mode qemu
```

`--mode native` requires both native probes to pass. `--mode qemu` explicitly selects emulation. `--qemu /absolute/path` selects an existing emulator. `HCC_PROBE_TIMEOUT=30` changes each probe's timeout (1–99 seconds).

## Files and recovery

| Location | Purpose |
|---|---|
| `~/.local/bin/claude` | Claude entry (direct native symlink or QEMU launcher) |
| `~/.gemini/bin/agy` | Exact entry used by AGY and Remote IDE |
| `~/.local/bin/agy` | AGY CLI entry |
| `~/.local/share/harness-cpu-compat/` | Releases, selection, program copy, backups, recovery records |

The state location honors `XDG_DATA_HOME`, or the explicit `HCC_STATE_DIR` override, and must be a dedicated directory within HOME. Set the same override for later inspection/update/uninstall. Paths with spaces work; newline paths are refused. Original regular files and symlinks are backed up before entry replacement. Credentials, conversations, IDE settings, version sidecars, and vendor data directories are not removed or rewritten.

Uninstall restores only entries still matching the project's recorded fingerprints. Changed entries or corrupted backups cause refusal. Binaries, rollback releases, backups, and the program copy are retained deliberately; there is no automatic garbage collector. Installing again after an uninstall captures the new baseline and archives the earlier backup.

Publication uses same-directory renames and a per-state `flock`. Ordinary publication errors attempt rollback only while entries still match the transaction's original or newly published bytes. A SIGKILL or concurrent foreign replacement can leave `tools/<tool>/pending`: further install/uninstall fails closed. **Do not delete that marker or run a blanket cleanup.** Keep the referenced staging transaction and original snapshots, inspect the exact entries, and restore them deliberately before removing the marker. `--repair` is for a foreign entry replacement, not an interrupted multi-file transaction.

Close IDE and CLI sessions before install, update, repair, or removal. The lock coordinates this project's operations, not vendor processes. This is not an atomic filesystem transaction across all files; `--tool all` installs sequentially and a failed second tool does not undo a successful first tool. An interrupted/failed multi-entry uninstall is not automatically resumable: retry can refuse an already-restored entry, requiring deliberate restoration from the retained, verified snapshots. No unrelated process is stopped or restarted.

## Tests and evidence

```bash
bash tests/run.sh       # offline, synthetic fixtures only; no accounts/vendor bundles
```

Offline suites cover argument/stream/signal transparency, native selection and help failures, checksums, managed version changes and retained fallbacks, repeat install/uninstall, foreign updater replacement and repair, corrupted backups, rollback, and SIGKILL recovery refusal.

An opt-in vendor smoke test downloads real binaries and creates a disposable HOME:

```bash
env -i PATH="$PATH" HOME="$HOME" TMPDIR="/path/to/task-scratch" \
  HCC_RUN_VENDOR_SMOKE=1 bash tests/vendor-smoke.sh
```

On a shared VPS, run tests serially under a separate user cgroup with at most two CPUs, explicit memory/time limits, and headroom for existing services.

Verified on **2026-11-07**, in isolation on a generic KVM/QEMU CPU lacking modern instructions:

- Claude Code **2.1.319**, binary SHA-256 `dabafec82ca1319fa43d8be36a10fc61b1d11821cb98ad5df04ad95e199b8eed`: official download verified; QEMU `--version` and `--help` pass.
- AGY **1.5.2** and **1.5.3**: official payloads verified; wrapper `--version`, `--help`, and isolated `--hub` health endpoint HTTP **200** pass; hub stops on TERM. Version 1.5.3 binary SHA-256: `7ca212748ca0dfda718efbc39a776a104472e7e9344d4b6ea147c543684f96a3`.
- A real managed AGY upgrade **1.5.2 → 1.5.3** selects the new verified artifact, preserves both launcher hashes, retains the previous binary, and passes version/help afterward. Reproduce with `tests/managed-update.sh`, supplying the prior verified binary, version and digest through its documented required environment variables.

These checks **do not prove authenticated AI tasks, interactive TTY workflows, sandbox enforcement, or unmodified Remote IDE cold-start/update integration**. Version-changing managed updates are exercised with synthetic publisher fixtures and the real AGY upgrade above; neither proves survival of independent vendor updaters. QEMU performance and future-release compatibility are not guaranteed. Prefer provider-supported CPU passthrough/a compatible VM CPU model where available.

## Layout and license

Two entry points: `install.sh`, `uninstall.sh`. Shared Shell implementation lives in `lib/`; tests in `tests/`. No proprietary binaries or IDE bundles are redistributed. This project's Shell source is MIT licensed; vendor software retains its own license and terms.
