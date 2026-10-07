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

- clones any missing reference repositories into `~/work/reference/` over SSH (`git@github.com:credfeto/<repo>.git`): `credfeto-setup-arch-desktop`, `credfeto-global-pre-commit`, `cs-template`, `credfeto-orchestrator`, `claude` and `credfeto-ai-skills`;
- runs `install-dotnet-tools` from `$HOME`;
- symlinks `units/dev-update/dev-update.service` and `dev-update.timer` from the reference clone into `~/.config/systemd/user/` and enables the timer, which starts from the next login;
- runs `dev-update`, which covers the first update until the timer starts.

Any failure stops `dev-install`.

## Usage

### Reference clones

The clones in `~/work/reference/` are reference data, kept separate from working checkouts in `~/work/personal/`, which `dev-update` never touches. The `/usr/local/bin` symlinks and the systemd units resolve into the reference clones, so the timer never runs code that is mid-change in a working checkout.

### dev-update

`dev-update` refuses to run inside a Claude Code session and dies at once when offline. Otherwise it pulls every reference clone, then runs, stopping on the first failure:

- `credfeto-setup-arch-desktop/install.d/dev-scripts`
- `credfeto-global-pre-commit/install --system`
- `claude/install`
- `credfeto-ai-skills/install`
- `credfeto-orchestrator/install-claude-hooks`

It finishes with `update-dotnet-tools`. A lock in `$XDG_RUNTIME_DIR/dev-update.lock` stops a manual run and a timer run overlapping; the second one reports that `dev-update` is already running and exits successfully.

### dev-update timer

`dev-update.timer` starts the service 15 seconds after the user manager starts, then every 30 minutes, each with up to 5 minutes of random delay. The service's `ExecCondition=` runs `network-online`, so an offline tick is skipped quietly rather than marking the unit failed.

The service runs `dev-update` through a login shell (`/bin/sh -lc`), because the user manager does not read `/etc/profile.d`. Timer runs therefore get the same environment that `install` deploys for shells, such as `NUGET_PACKAGES` and `GNUPGHOME`.

Timer runs pull the reference clones over SSH. `SSH_AUTH_SOCK` points at the user `ssh-agent.socket` that `install` enables, so the agent must hold the key.

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
