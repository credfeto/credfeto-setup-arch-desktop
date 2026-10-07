# credfeto-setup-arch-desktop

Scripts and settings that set up, harden and keep up to date an Arch Linux desktop used for development.

## Overview

`install` configures the machine: packages, hardening, shell environment and the helper scripts linked into `/usr/local/bin`. `dev-install` and `dev-update` then keep a set of reference clones of the development tooling repositories current, refreshed by a user systemd timer every 30 minutes.

## Quick Start

```sh
./install
dev-install
```

## Installation

Run `install` from a checkout of this repository. It runs each step under `install.d/` in turn, including `install.d/dev-scripts`, which symlinks every script under `settings/scripts/` into `/usr/local/bin`.

Then run `dev-install` once, outside a Claude Code session, with the network up and `dotnet` on `PATH`. It:

- clones any missing reference repositories into `~/work/reference/<repo>` over SSH only: `credfeto-setup-arch-desktop`, `credfeto-global-pre-commit`, `cs-template`, `credfeto-orchestrator` and `credfeto-ai-skills` from `git@github.com:credfeto/<repo>.git`, and `claude` from `git@github.com:dnyw4l3n13/claude.git`;
- switches each reference clone to `main` and fast-forwards it (`git pull --ff-only`), so a re-run brings any clone that already existed up to date before anything runs from it;
- runs `install-dotnet-tools` from `$HOME`;
- symlinks `units/dev-update/dev-update.service` and `dev-update.timer` from the reference clone into `~/.config/systemd/user/` and enables the timer;
- runs `dev-update`, which covers the first update until the timer starts.

The timer starts when the user systemd manager next starts: a reboot, or a fresh login once no other session, lingering or leftover process (such as a tmux server) keeps the manager running. To start it at once, which also triggers a run straight away:

```sh
systemctl --user start dev-update.timer
```

Any failure stops `dev-install`.

## Usage

### Reference clones

The clones in `~/work/reference/` are reference data, kept separate from working checkouts in `~/work/personal/`, which `dev-update` never touches. The `/usr/local/bin` symlinks resolve into the reference clones, and the systemd units run `dev-update` and `network-online` straight from the `credfeto-setup-arch-desktop` reference clone, so the timer never runs code that is mid-change in a working checkout. The symlinks remain for running the scripts by hand.

Both `dev-install` and `dev-update` switch each reference clone to `main` and fast-forward it with `git pull --ff-only`. A clone with uncommitted changes, one that cannot be switched to `main`, or one whose `main` has diverged from its upstream stops the run with an error naming the clone. Neither script ever forces, resets or stashes a clone, so fix the clone by hand and re-run.

### dev-update

`dev-update` refuses to run inside a Claude Code session and dies at once when offline. Otherwise it clones any missing reference repository into `~/work/reference/` over SSH only, from the same owners as `dev-install` (`credfeto` for all but `claude`, which comes from `dnyw4l3n13`), so a deleted or newly added reference repository is restored without re-running `dev-install`; a failed clone is fatal. It then switches every reference clone to `main` and fast-forwards it, as described under [Reference clones](#reference-clones), and runs, stopping on the first failure:

- `credfeto-setup-arch-desktop/install.d/dev-scripts`
- `credfeto-global-pre-commit/install --system`
- `claude/install`
- `credfeto-ai-skills/install`
- `credfeto-orchestrator/install-claude-hooks`

It finishes with `update-dotnet-tools`. A lock in `$XDG_RUNTIME_DIR/dev-update.lock` stops a manual run and a timer run overlapping; the second one reports that `dev-update` is already running and exits successfully.

### dev-update timer

`dev-update.timer` starts the service 15 seconds after the user manager starts, then every 30 minutes, each with up to 5 minutes of random delay. The service's `ExecCondition=` runs `network-online` from the reference clone, so an offline tick, or one where the clone is missing, is skipped quietly rather than marking the unit failed.

The service runs `dev-update` through a login shell (`/bin/sh -lc`), because the user manager does not read `/etc/profile.d`. Timer runs therefore get the same environment that `install` deploys for shells, such as `NUGET_PACKAGES` and `GNUPGHOME`.

Timer runs clone and fast-forward the reference clones over SSH. `SSH_AUTH_SOCK` points at the user `ssh-agent.socket` that `install` enables, so the agent must hold the key.

Timer runs have no terminal, so the `sudo` calls in `dev-scripts`, the `cfwf` copy and `install --system` need passwordless `sudo`. Without it the timer run fails at `dev-scripts`.

```sh
systemctl --user list-timers dev-update.timer
journalctl --user -u dev-update.service
```

### network-online

`network-online` exits 0 when online and 1 when offline, under either NetworkManager or systemd-networkd, and 255 when neither is active.

### update

The interactive `update` shell function updates system packages, then runs `install` from `~/work/reference/credfeto-setup-arch-desktop` when that clone exists, otherwise from `~/work/personal/credfeto-setup-arch-desktop`.

## Changelog

See [CHANGELOG.md][changelog].

## Contributing

See [CONTRIBUTING.md][contributing].

## Security

See [SECURITY.md][security].

[changelog]: CHANGELOG.md
[contributing]: CONTRIBUTING.md
[security]: SECURITY.md
