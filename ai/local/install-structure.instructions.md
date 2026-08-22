# Install Script Structure Instructions

> Load when: any work touches `install`, `install.d/`, or `lib/common`.

[Back to Local Instructions Index](index.md)

## Pattern

`install` is a thin orchestrator, not a place for feature logic:

- It resolves `BASEDIR`, sources `lib/common`, then calls each `install.d/*` script in order.
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

Whether `install` wraps a script's call in `|| die "install.d/<name> failed"` depends on what that script's exit status actually means:

- **`|| die` it** when the script's own body calls `die` on a real failure path (currently `harden-ssh`, whose hostname-lookup guard was already `die`-guarded before this pattern existed) - the script's exit status is meaningful and non-zero means something genuinely went wrong, so `install` must stop rather than silently continue past it.
- **Call it bare** otherwise - most scripts' exit status is just whatever their function's last statement happens to return, and several end on a short-circuited `[ cond ] && cmd` that legitimately returns non-zero when the condition is false (e.g. `remove-aur-helpers` when no AUR helper is installed, `harden-system` when `ZOOM_INSTALLED=0`). Wrapping those in `|| die` would make `install` abort on cases that are not actually failures.

Note the trade-off this involves for a script whose body calls `die`: the caller can only see the child's overall exit status, not *which* statement inside it failed, so `|| die` on the caller side aborts on any non-zero exit from the script, not only the one that goes through the internal `die` guard (e.g. for `harden-ssh`, a plain `sudo cp`/`sudo tee` failure now aborts `install` too, where pre-#17 it would have been silently ignored since `harden_ssh` ran in-process and was called bare). This is an accepted, security-motivated widening, not a bug: preserving "the internal `die` aborts everything" is more important than preserving "an unrelated command failure inside the function doesn't abort", and a plain process boundary can't have both.

`shell-prompt` is `|| die`-wrapped too, from when it was first introduced (#16); it currently has no internal failure path (it always ends on `success`, which returns 0), so the wrapper is inert today rather than load-bearing, but it's pre-existing and out of scope for this pattern's rollout to revisit.

When adding a new `install.d/*` script, check what its **last statement** returns in the common case before deciding which form to use, and if it calls `die` anywhere, wrap the call in `install` with `|| die`.

## Install-State Flags

`DOCKER_INSTALLED`, `INCUS_INSTALLED`, `FLATPAK_INSTALLED`, and `ZOOM_INSTALLED` live in `lib/common`, recomputed every time it is sourced (cheap `[ -f ... ]` checks), rather than being computed once in `install` and exported. This keeps every `install.d/*` script correct when run standalone, without depending on `install` having run first. If a new flag turns out to be needed by more than one script, add it here the same way, as an `if`/`fi` block (not a trailing `[ cond ] && VAR=1`) so sourcing `lib/common` always exits 0 regardless of which flags end up set.
