# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash scripts that update Docker Engine, Compose and Buildx on Synology NAS devices (DSM 6/7) by replacing the binaries inside the Container Manager / Docker package. There is no build step. The scripts run as root on someone's NAS, so a half-finished run can leave Docker unusable.

`AGENTS.md` holds upstream's contribution rules (scope, PR rules, safety rules, AI disclosure). Read it before changing behavior; the points that most often shape code are repeated under "Conventions" below.

## Fork layout

- `upstream` = `telnetdoogie-labs/synology-docker`; `origin` = the user's fork.
- `main` mirrors `upstream/main`. `local` is `main` plus the fork-only features, kept as commits on top.
- Fork-only features (not in upstream, keep them when syncing):
  - Buildx and the `docker compose` plugin installed to `/usr/local/lib/docker/cli-plugins` (`--buildx`, `--target buildx`), included in backup/restore.
  - A fallback NAT `MASQUERADE` rule in DSM's `DEFAULT_POSTROUTING` chain (`--masq-subnet`, also in `fix_ipforward.sh`).
- Upstream has force-rewritten `main` before. If a merge of `upstream/main` conflicts across many unrelated files, check `git merge-base` — re-apply the fork's diff onto the new `main` instead of merging.

## Commands

Tests only run inside the disposable image (they write fake DSM paths such as `/var/packages/ContainerManager`, and refuse to run elsewhere). Docker Desktop must be running.

```bash
# build once, then run the whole suite
docker build -t synology-docker-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/workspace:ro" synology-docker-tests

# one case: file name in tests/cases/ without .sh
docker run --rm -v "$PWD:/workspace:ro" synology-docker-tests bash tests/run.sh apply_update

# ShellCheck, as CI runs it (must report nothing)
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x ./*.sh tests/*.sh tests/cases/*.sh tests/lib/*.sh
```

On this Windows checkout, from Git Bash: prefix `docker run` with `MSYS_NO_PATHCONV=1` and use `C:/Projects/synology-docker` instead of `$PWD` for the mount.

CI (`.github/workflows/ci.yml`) runs the suite, ShellCheck, and a Bash 4.3 run of `syno_docker_list_containers.sh` with an empty docker stub.

`.gitattributes` forces LF on `*.sh`. A script that shows up with CRLF in the working tree fails `shell_syntax` with `$'{\r'` errors; delete it and `git checkout --` it.

## Architecture

### `syno_docker_update.sh` (the updater)

One file, structured as constants → globals → functions → `main`. `main` parses options into globals, then a `case` on the command (`update`, `install`, `download`, `restore`, `backup`, `logger`, `only_script`, `start`, `stop`, `validate`) runs a fixed sequence of functions. Reading that `case` block is the fastest way to see a workflow's order.

Function name prefixes carry meaning:

- `detect_*` / `define_*` / `validate_*` — read state, decide what will happen, and stop early. Everything that can fail should fail here, before `execute_stop_syno`.
- `execute_*` — do the work (backup, download, extract, stop, install, edit config, start).

Things that span several functions:

- **Skip flags.** `skip_docker_update`, `skip_compose_update`, `skip_buildx_update`, `skip_driver_update` are set by `validate_target` (from `--target`) and again by `define_update` (component already at its target, unless `--force`). Every `execute_*` function checks them. A new component needs a flag in all of: `validate_target`, `define_update`, the "nothing to do" check at the end of `define_update`, and the early-return guards in `execute_install_bin` / `execute_restore_bin`.
- **Step counter.** Each workflow sets `total_steps`; `define_update`, `define_setup_steps` and `define_storage_driver` adjust it as steps are skipped or added; `print_status` prints `Step N from M`. Adding a step means updating the workflow's starting number and the skip adjustments.
- **Versions are never pinned.** Latest Engine comes from the download index, Compose and Buildx from the GitHub releases API, all through `curl_https_update` (HTTPS-only, TLS 1.2). A failed lookup terminates; there is no default-version fallback. The one pin is `PINNED_RUNC_VERSION`, used only when the bundled runc is known to break on 5.x kernels.
- **Version-dependent setup.** `define_setup_steps` turns on the iptables raw modules for Engine 28+ and the AppArmor profile for 29+; these call the sibling scripts `install_iptables_modules.sh` and `install_apparmor_profile.sh` via `SCRIPT_DIR`.
- **`start-stop-status` editing.** `execute_update_script` rewrites DSM's package start script on a temp copy and `mv`s it into place. It inserts a block before the `$DockerUpdaterBin postdaemonup` line (dockerd must be up, because it creates the `DOCKER-FORWARD` chain): FORWARD policy/jump, a line that starts `syno_docker_forward_guard.sh`, and the fork's MASQUERADE line. Old copies of each inserted line are deleted first so re-runs are idempotent — any new inserted line needs a matching delete. `fix_ipforward.sh` and `switch_forward.sh` are standalone helpers that make the same edit and must stay consistent with it.
- **Generated code runs under `/bin/sh`.** Lines inserted into `start-stop-status` and `syno_docker_forward_guard.sh` must be POSIX `sh`; the `#!/bin/bash` scripts may use Bash, but only up to 4.3.

The script ends with `if [ "${BASH_SOURCE[0]}" == "$0" ]; then main "$@"; fi`, so it can be sourced without running — the tests depend on this.

### Other scripts

- `syno_docker_forward_guard.sh` — long-running `sh` loop started from `start-stop-status`; re-adds Docker's FORWARD jumps after DSM's firewall rewrites them, and exits with dockerd.
- `install_iptables_modules.sh` — downloads kernel modules for the NAS's kernel/platform from `synology-kernelmodules` and verifies them against the published `SHA256SUMS`. `--check` is the read-only preflight the updater uses.
- `syno_docker_list_containers.sh`, `container_recreate.sh`, `syno_docker_switch_logger.sh` — helpers for moving containers off Synology's removed `db` log driver.
- `tests/check-dsm-runtime.sh` — optional prerequisite probe users run on the NAS; it is separate from the updater's own checks.

### Tests

`tests/run.sh` runs each file in `tests/cases/` in a fresh Bash process. A case sources `tests/lib/test_env.sh`, calls `init_update_fixture` (resets the fake package folder and **sources the updater**), then overrides externals as shell functions (`docker`, `curl`, `runc`, …) and either calls `main …` or individual functions with globals set directly. `tests/lib/update_run_fixture.sh` provides fuller mocks (versions, `synopkg`, a `curl` that serves files by URL basename and logs URLs).

Consequences worth knowing:

- Cases run with `set -euo pipefail` and an `ERR` trap, so updater code that tolerates a failing pipeline in production (for example a version probe for something not installed) needs an explicit `|| true`.
- All cases share one container. State written outside the fake package folder persists between cases unless `init_update_fixture` removes it.
- `init_update_fixture` pins `target_buildx_version` (as `--buildx` would) and the fixture's `docker` mock reports that version, so cases that aren't about Buildx see nothing to update. A case with its own `curl` mock that forces an update must serve the Buildx download.
- Mocked tests are not NAS tests; never report DSM compatibility from them.

## Conventions

From `AGENTS.md` and the existing code:

- Fail closed: a failed lookup, download, check, copy or write terminates with a clear message (`cmd || terminate "…"`). No guessed fallbacks.
- Do everything checkable before stopping Container Manager; never overwrite a backup; use private temp dirs.
- Bash 4.3 compatible: under `set -u`, expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
- Only tools DSM ships (`jq`, `curl`, `realpath`, `timeout`, …). No new languages, tools or dependencies.
- 2-space indentation; no reformatting of untouched code; conventional commit titles (`fix(update): …`, `feat: …`, `test: …`).
- Behavior changes get a case in `tests/cases/`: one file per behavior, named for what it protects, arrange → act → expect, using the named `expect_*` assertions. Don't weaken an existing assertion to get a pass.
- User-facing commands printed by the scripts must work when pasted (quote with `printf %q`).
