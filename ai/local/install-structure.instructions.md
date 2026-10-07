# Install Script Structure Instructions

> Load when: any work touches `install`, `install.d/`, or `lib/common`.

[Back to Local Instructions Index](index.md)

## Pattern

`install` is a thin orchestrator, not a place for feature logic:

- It resolves `BASEDIR`, sources `lib/common`, then runs each `install.d/*` script from one loop over an ordered list of step names.
- Each install feature/hardening step lives in its own standalone, executable POSIX `sh` script under `install.d/`.
- `lib/common` holds helpers and state shared across scripts (`die`/`success`/`info`, the install-state flags) so nothing is duplicated between `install` and the `install.d/*` scripts.

## `install.d/` Script Shape

Every `install.d/*` script:

- Has its own shebang (`#! /bin/sh`) and is directly executable, not just callable from `install`.
- Resolves its own `BASEDIR` the same way `install` does, shown below.
- Sources `lib/common` for `die`/`success`/`info` and the install-state flags rather than duplicating them.
- Defines one function named after its purpose (e.g. `install_dash`, `harden_ssh`) and calls it as the script's last line, so the script's own exit status is the function's return status.

`BASEDIR` resolution, identical in every script:

```sh
SCRIPTDIR="$(dirname "$(readlink -f "$0")")"
BASEDIR="$(dirname "$SCRIPTDIR")"
```

## Naming Convention

One rule, no exceptions: kebab-case the function name (underscores → hyphens), then drop a leading `install-` if present, since that's already implied by living under `install.d/`.

Examples already applied:

| Function | Script |
| --- | --- |
| `install_shell_prompt` | `shell-prompt` |
| `remove_aur_helpers` | `remove-aur-helpers` |
| `harden_system` | `harden-system` |
| `install_pacman_hooks` | `pacman-hooks` |
| `configure_pacman` | `configure-pacman` |
| `install_security_tools` | `security-tools` |
| `install_dash` | `dash` |
| `configure_network` | `configure-network` |
| `harden_ssh` | `harden-ssh` |
| `install_btrfs_scrub` | `btrfs-scrub` |
| `install_firejail` | `firejail` |
| `install_fail2ban` | `fail2ban` |
| `enable_services` | `enable-services` |
| `configure_flatpak` | `configure-flatpak` |
| `install_shell_environment` | `shell-environment` |
| `install_git_environment` | `git-environment` |
| `install_dev_scripts` | `dev-scripts` |

## Calling Convention in `install`

`install` runs every step from a single `for STEP in ...; do` loop over the step names, in the order they must run, and calls each one as `"$BASEDIR/install.d/$STEP" || die "install.d/$STEP failed"`:

- Every step is `|| die`-wrapped, with no bare calls, because every step's exit status is meaningful (see [Failure Handling Inside a Script](#failure-handling-inside-a-script)). A non-zero exit always means the step did not finish, so `install` stops rather than printing `Done` over it.
- The name list is the only place the order lives, so the call and its error message cannot disagree about which step failed.
- When adding a new `install.d/*` script, add its name to the list at the point it must run. `test/install.bats` fails until every executable under `install.d/` is in the list and the list matches the order the test expects.

## Failure Handling Inside a Script

A step's exit status must mean "finished" or "failed", nothing else:

- Guard every command that can fail with `|| die "<what failed, naming the target>"`, so the script stops at the first failure and the message says which file, package or service was involved.
- Never end the function on a short-circuited `[ cond ] && cmd`, which returns non-zero when the condition is false and so reports a failure that did not happen. Write the condition as an `if`/`fi` block, so a false condition leaves the status at 0.
- Do not feed a loop whose body calls `die` from a pipe when the script must stop on that `die` and the loop is not the function's last statement: the loop runs in a subshell, and `die` only ends that subshell. Feed it from a here-doc or a glob instead, or check the pipeline's status with `|| die`.
- End the function on `success "<message>"` and call the function as the script's last line, so the script exits 0 only when every guarded command succeeded.

## Reference Clone Location

`DEV_REFERENCE_DIR` in `lib/common` (default `~/work/reference`) is where the reference clones live, and is overridable so a test can point it at a temp dir. Every script that sources `lib/common` must use it rather than repeat the path. `settings/bash.bashrc.d/95_update.sh` and `units/dev-update/dev-update.service` cannot source `lib/common`, so they repeat the default path, each with a comment saying so; change all three together.

## Install-State Flags

`DOCKER_INSTALLED`, `INCUS_INSTALLED`, `FLATPAK_INSTALLED`, and `ZOOM_INSTALLED` live in `lib/common`, recomputed every time it is sourced (cheap `[ -f ... ]` checks), rather than being computed once in `install` and exported. This keeps every `install.d/*` script correct when run standalone, without depending on `install` having run first. The probes look in `INSTALL_STATE_BIN_DIR` (default `/usr/bin`), so a test can point it at a temp dir and control each flag without depending on what the host has installed. If a new flag turns out to be needed by more than one script, add it here the same way, as an `if`/`fi` block (not a trailing `[ cond ] && VAR=1`) so sourcing `lib/common` always exits 0 regardless of which flags end up set.
