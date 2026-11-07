# harness-cpu-compat

User-scoped Shell installers for **Claude Code** and **Antigravity CLI (`agy`)** on Linux x86_64. Try native execution first; use `qemu-x86_64 -cpu max` only when isolated `--version` **and** `--help` probes do not both succeed.

**Experimental compatibility tooling, not a vendor-supported distribution.** Antigravity Remote IDE support is experimental: its independent updater can overwrite the wrapper **before invoking it**. There is no seamless/pre-exec repair guarantee. By default, close affected IDE/CLI sessions, rerun the installer with `--repair`, then reconnect/reload. An optional default-off watcher can repair independently verified replacements as described below. The project never patches IDE JavaScript or changes CPU flags; ordinary installation creates no background units.

## Install

Requirements: Linux x86_64, Bash 4.4+, GNU coreutils, `flock`, `curl`, `jq`, `tar`, and normal system CA certificates. If emulation is needed and `qemu-x86_64` is missing, the foreground installer automatically installs **`qemu-user` through APT on Debian/Ubuntu**, using ordinary sudo when not root. Other dependencies must already be installed; on non-APT systems install QEMU manually. There is no Python, npm, or separate Node.js dependency.

No clone is required:

```bash
curl -fsSL https://raw.githubusercontent.com/tamntlib/harness-cpu-compat/main/install.sh \
  | bash -s -- --tool all --yes
```

Or use a complete local checkout (no bootstrap download):

```bash
git clone https://github.com/tamntlib/harness-cpu-compat.git
cd harness-cpu-compat
./install.sh --tool all
# Or choose one:
./install.sh --tool claude
./install.sh --tool agy
```

Without `--tool`, an interactive terminal asks which tool to install. Noninteractive runs require `--tool` and `--yes`. Install as the intended user, not with sudo. Confirmation (or `--yes`) also accepts conditional system-package installation; it does not provide sudo credentials. Without a controlling terminal or cached authentication, sudo may fail. Package installation runs `apt-get update` then `apt-get install -y --no-install-recommends --reinstall qemu-user`; it does not run a general upgrade. Package changes remain if later application checks fail, and uninstall never removes QEMU. Add `$HOME/.local/bin` to `PATH` if it is not already present; shell profiles are not edited automatically.

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

Removal also supports piping, without a checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/tamntlib/harness-cpu-compat/main/uninstall.sh \
  | bash -s -- --tool all --yes
```

When piped or run as a standalone file without its sibling bundle, either entrypoint downloads one complete `main` source archive over HTTPS. The bootstrap uses a private temporary directory under `TMPDIR`, or HOME when unset, validates all five required regular Shell files, then forwards arguments and child status and removes its temporary files. It never extracts archive-controlled paths into your filesystem. It requires existing `curl`, GNU `tar`, `timeout`, and GNU `env` with `--default-signal` support; the bootstrap itself installs no dependencies, but its foreground installer may install QEMU as described above. Piped execution is noninteractive: use `--yes` for mutations. A standalone script retains its normal stdin.

`main` is mutable: bootstrap follows the current main archive, **not** the raw script's revision, and HTTPS is not an independent code signature. Review the source before execution. Use a complete checkout/archive at an exact commit for a pinned, offline script bundle. A complete local bundle bypasses bootstrap entirely; installed launchers use retained private copies, not the temporary source directory.

`--doctor` and `--dry-run` do not create persistent installation state, download vendor payloads, execute vendor binaries, or probe the emulator. With a complete local bundle they create no directories or downloads at all; piped/standalone use still downloads and temporarily stages the script bundle first. Doctor recognizes current launcher templates/symlinks directly and reports selected paths/mode, vendor artifact checksums, alias conflicts and incomplete publication markers. It is an inspection report, not an authenticated readiness test.

**Use `install.sh` for updates while using this installation.** Direct vendor self-updates and IDE-managed acquisition are outside the managed-update contract; they may replace an entry or alter a private binary. No vendor update settings or environment variables are silently changed. `--repair` explicitly replaces a changed primary entry after artifact verification, without retaining a historical baseline or conflict backup. It does not merge vendor metadata, migrate credentials, or override an interrupted transaction. An altered stored release is refused rather than silently overwritten.

For exact versions, Claude accepts `--version X.Y.Z`, `stable`, or `latest`. AGY's public manifest exposes its current release only: use `latest` or that exact manifest version. A pinned previously downloaded executable can also be explicitly imported:

```bash
./install.sh --tool agy --from-binary /path/to/verified/agy \
  --version 1.5.2 --sha256 '<expected-sha256>' --mode qemu
```

`--mode native` requires both native probes to pass. `--mode qemu` explicitly selects emulation. `--qemu /absolute/path` selects an existing emulator; an invalid explicit path is refused, not replaced through APT. An existing emulator that fails probes is also refused without reinstalling. Native success never installs QEMU. Runtime launches, background repair, doctor, dry-run, disabling repair, and uninstall never invoke APT or sudo. `HCC_PROBE_TIMEOUT=30` changes each probe's timeout (1–99 seconds).

## Optional AGY auto-repair — off by default

```bash
./install.sh --tool agy --auto-repair --yes    # install/update AGY, then opt in
./install.sh --tool all --auto-repair --yes    # auto-repair applies only to AGY
./install.sh --tool agy --no-auto-repair --yes # disable only; no download/reinstall
```

`--repair` repairs once in the foreground; `--auto-repair` enables the background watcher described below. It does not proactively update AGY. The former `--watch-agy` / `--no-watch-agy` option names are no longer accepted.

The watcher requires an already available **systemd user manager**; non-systemd installations remain supported with the default off. The watcher itself never invokes sudo or installs packages, system-level units, inotify-tools, IDE patches, or extra language runtimes; its foreground installation may install missing QEMU as above. An ordinary rerun without watcher flags preserves an earlier explicit opt-in. Claude-only and contradictory watcher flags are refused. Uninstalling AGY stops/removes its owned watcher before native handoff; a subsequent handoff refusal does not re-enable it.

Opt-in creates a state-root-specific user `.path`, bounded oneshot `.service`, and startup/periodic `.timer` in the user unit directory. The directory watch detects rename/replacement; the exact-file watch detects close-after-write. The fallback starts around 30 seconds after activation and rechecks around five minutes after an inactive service, subject to timer accuracy and execution time—not a hard recovery deadline. The service has a two-CPU quota, 1 GiB memory ceiling, no swap, task/time limits and control-group probe cleanup. It does **not** own, kill, restart, or reload your IDE/hub sessions.

On a replacement, the worker snapshots but never executes the incoming pathname. It downloads and checksum-verifies the current official AGY artifact, requires its extracted SHA-256 to match the incoming bytes **exactly**, then probes the independently verified private copy. An older/newer/other-channel or unknown artifact that does not match the public feed is left untouched and reported as blocked; the worker never substitutes a different “latest” binary. A later event or fallback can retry after a temporary feed/network failure. Managed self-events are no-ops without repeat downloads/probes.

Publication is separate from foreground `--repair`: generation-bound launchers refer to the newly verified immutable release, not a mutable `current` pointer. Each public entry is atomically captured into a private recovery directory on **that entry's filesystem**. A no-clobber hardlink publishes its prepared launcher only if the public name is still free. A concurrent vendor file, directory or symlink is never forcibly overwritten. Unchanged captures are discarded after successful publication; captures changed through an open writer are retained with a recovery journal. Previous verified private releases remain available while managed.

**Known limits:** the capture-to-link step briefly makes an entry absent (`ENOENT`). An updater can still exec the native binary before the watcher runs and get `SIGILL`. Rename also cannot stop a writer holding an open descriptor; only the independently verified private copy is executed. Reload/reconnect may be required. There is no hostile same-UID confinement or power-loss durability claim; use owned, trusted directories.

Partial publication or interruption leaves `watch/pending` plus referenced `.hcc-watch-recovery.*` directories beside the public entries. Automatic repair and foreground AGY replacement then refuse to continue: retain those records and reconcile deliberately, not by deleting markers blindly. The two entries and metadata are not one atomic transaction. Disabling does not delete recovery material or stop existing application sessions. Unit-file configuration refresh is also a multi-file operation: an interrupted disabled refresh can require deliberate recovery of the recorded unit configuration; immutable prior snapshots are retained.

Unit names/content hashes and the entry ownership claim are recorded. Ownership snapshots are immutable and content-addressed; an unchanged active watcher does not rewrite its unit baselines on re-enable. A separate management lock serializes all AGY install/enable/disable/uninstall transitions before the operation lock; workers take only the operation lock, so stopping a worker cannot deadlock on the management lock. Modified/foreign units are refused and preserved rather than overwritten or removed; independent state roots cannot reserve the same entry concurrently. Activation failures leave a disabled worker and owned recovery records; inspect errors and use the disable command before retrying. After an interrupted initial reservation, a retained `.hcc-watch-owner` can also require deliberate recovery. `--doctor` reports configured opt-in and the unit identity without contacting the manager; it does not assert that the units are currently active. Use that identity with `systemctl --user status` and `journalctl --user -u <identity>.service` for runtime diagnosis.

## Files and recovery

| Location | Purpose |
|---|---|
| `~/.local/bin/claude` | Claude entry (direct native symlink or QEMU launcher) |
| `~/.gemini/bin/agy` | Exact entry used by AGY and Remote IDE |
| `~/.local/bin/agy` | AGY CLI entry |
| `~/.local/share/harness-cpu-compat/` | Verified releases/versions, current selection, program copy, locks and incomplete-operation recovery |

The state location honors `XDG_DATA_HOME`, or the explicit `HCC_STATE_DIR` override, and must be a dedicated directory within HOME. Set the same override for later inspection/update/uninstall. Paths with spaces work; newline paths are refused. There is no durable pre-install baseline, `original/`, `alias-original/`, `installed`, `alias-installed`, conflict history or equivalent entry-fingerprint database. Launcher identity is checked against generated templates or the current native symlink; vendor artifact checksums and watcher unit ownership are separate safety mechanisms. Credentials, conversations, IDE settings, version sidecars, and vendor data directories are not removed or rewritten.

AGY foreground installs temporarily reserve the same global entry claim, even with the watcher off; uninstall retains that reservation until native handoff and selected-tool cleanup succeed. A different state root cannot publish entries during that interval. Ordinary successful installs release the temporary claim before unlocking; an enabled watcher keeps it. These reservations do not enable services or require systemd. Failed uninstall retains its claim for deliberate recovery.

Uninstall removes compatibility, not the application: it keeps the selected current version in native vendor layout. AGY becomes an ordinary executable at `~/.gemini/bin/agy`, with `~/.local/bin/agy` pointing there. Claude becomes an ordinary file at `~/.local/share/claude/versions/<version>` with `~/.local/bin/claude` pointing to it. Recognized HCC entries are replaced without depending on a historical snapshot; independent native ELF entries already published by a vendor are preserved rather than downgraded. Arbitrary scripts, unresolved links, damaged selections and canonical Claude-version collisions are refused. Native destinations must be independent of HCC state. No vendor or emulator execution, download or package operation is performed during uninstall; removing QEMU emulation can expose the host's original CPU incompatibility.

After successful native handoff, the selected tool's private state and release copies are removed. The other managed tool is preserved. Shared program files and owned watcher records are removed when no tool needs them; the root and stable lock inodes remain as an inert concurrency skeleton. QEMU, credentials and application data are not removed. This state format requires per-release `version` metadata; older stores missing it are refused without automatic migration or consulting historical snapshots.

Publication uses same-directory renames and a per-state `flock`. Ordinary publication errors attempt rollback only while entries still match the transaction's original or newly published bytes. A SIGKILL or concurrent foreign replacement can leave `tools/<tool>/pending`: further install/uninstall fails closed. **Do not delete that marker or run a blanket cleanup.** Keep the referenced staging transaction/captures, inspect the exact entries, and reconcile them deliberately before removing the marker. These are temporary recovery records for a failed operation, not successful-install baseline backups. `--repair` is for a foreign entry replacement, not an interrupted multi-file transaction.

Close IDE and CLI sessions before install, update, repair, or removal. The lock coordinates this project's operations, not vendor processes. This is not an atomic filesystem transaction across all files; `--tool all` installs sequentially and a failed second tool does not undo a successful first tool. Native handoff uses same-parent capture and no-clobber publication, leaving `tools/<tool>/pending` and same-directory captures on interruption or drift. A failed multi-entry handoff is not automatically resumed; retain its journal for deliberate recovery. No unrelated process is stopped or restarted.

## Tests and evidence

```bash
bash tests/run.sh       # offline, synthetic fixtures only; no accounts/vendor bundles
```

The twenty offline suites cover argument/stream/signal transparency, native selection and help failures, checksums and escaped filenames, managed version changes and retained fallbacks, repeat install/native uninstall, corrupted selected artifacts, temporary publication rollback, SIGKILL recovery refusal, default-off watcher management, exact-artifact reconciliation, no-clobber races, open writers, concurrent ownership reservations, cross-root uninstall handoff, first-install/uninstall concurrency, and piped/standalone bootstrap acquisition, archive guards, argument/status forwarding, signals and cleanup. QEMU dependency tests isolate PATH completely and use fake APT/sudo to verify conditional installation, lock-descriptor isolation, failures without entry publication, reuse, and background/read-only boundaries. They mock the publisher/systemd management; real event handling is tested separately.

An opt-in vendor smoke test downloads real binaries and creates a disposable HOME:

```bash
env -i PATH="$PATH" HOME="$HOME" TMPDIR="/path/to/task-scratch" \
  HCC_RUN_VENDOR_SMOKE=1 bash tests/vendor-smoke.sh
```

Additional opt-in acceptance scripts:

- `HCC_RUN_SYSTEMD_WATCH_TEST=1 bash tests/watch-systemd.sh`: real user-manager rename/close-write events with a synthetic publisher; exercises unit argument paths containing spaces, percent, dollar, quotes and backslash.
- `HCC_RUN_VENDOR_SMOKE=1 bash tests/watch-vendor.sh`: supply the previous/next verified binaries, versions and SHA-256 values through the required `HCC_PREVIOUS_AGY_*` / `HCC_NEXT_AGY_*` variables. It uses runtime-only task units and a disposable HOME. Optional `HCC_IDE_NODE`, `HCC_IDE_EXTENSION`, and `HCC_IDE_EXTENSION_SHA256` execute the installed extension’s unchanged Linux promotion function in isolation; no bundle or account data is copied into this repository. Both scripts clean up their task-owned runtime units, not unrelated services.

On a shared VPS, run tests serially under a separate user cgroup with at most two CPUs, explicit memory/time limits, and headroom for existing services.

Verified on **2026-11-07**, in isolation on a generic KVM/QEMU CPU lacking modern instructions:

- In a disposable Ubuntu 24.04 container, missing QEMU is installed through real APT, AGY 1.5.3 passes version/help, deletion of only the container's emulator is repaired through package reinstall, and uninstall retains QEMU. Effective limits were two CPUs (affinity 0–1), 1 GiB RAM and zero swap. This exercises the root package branch; sudo/authentication behavior is covered with offline shims, not real credential prompts. The host QEMU installation was not modified.

- Claude Code **2.1.319**, binary SHA-256 `dabafec82ca1319fa43d8be36a10fc61b1d11821cb98ad5df04ad95e199b8eed`: official download verified; QEMU `--version` and `--help` pass.
- AGY **1.5.2** and **1.5.3**: official payloads verified; wrapper `--version`, `--help`, and isolated `--hub` health endpoint HTTP **200** pass; hub stops on TERM. Version 1.5.3 binary SHA-256: `7ca212748ca0dfda718efbc39a776a104472e7e9344d4b6ea147c543684f96a3`.
- A real managed AGY upgrade **1.5.2 → 1.5.3** selects the new verified artifact, preserves both launcher hashes, retains the previous binary, and passes version/help afterward. Reproduce with `tests/managed-update.sh`, supplying the prior verified binary, version and digest through its documented required environment variables.
- The opt-in watcher automatically recovers a real **1.5.2 → 1.5.3** replacement published through the installed IDE extension’s unchanged Linux promotion function, in a disposable HOME. Immediate native version execution failed with status **132**, then repair selected the exact verified artifact, retained the previous binary, passed version/help, and served hub health HTTP **200**. Runtime test units were removed afterward. This is event-driven recovery, not prevention of the first failure.

These checks **do not prove authenticated AI tasks, interactive TTY workflows, sandbox enforcement, or unmodified Remote IDE cold-start/update integration**. Version-changing managed updates are exercised with synthetic publisher fixtures and the real AGY upgrade above; neither proves survival of independent vendor updaters. QEMU performance and future-release compatibility are not guaranteed. Prefer provider-supported CPU passthrough/a compatible VM CPU model where available.

## Layout and license

Two entry points: `install.sh`, `uninstall.sh`. Shared Shell implementation lives in `lib/`; tests in `tests/`. No proprietary binaries or IDE bundles are redistributed. This project's Shell source is MIT licensed; vendor software retains its own license and terms.
