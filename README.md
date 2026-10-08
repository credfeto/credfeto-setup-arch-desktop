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

Run `install` from a checkout of this repository, as your normal user in a logged-in session (desktop, console or SSH login), not through `sudo` or `su`. It calls `sudo` itself where it needs to, and it needs your systemd user manager to enable the `ssh-agent` user service. It checks both before changing anything: run as root, or where `systemctl --user` cannot reach the user manager, it stops at once with a message saying which. It then runs each step under `install.d/` in turn, including `install.d/dev-scripts`, which symlinks every script under `settings/scripts/` into `/usr/local/bin`.

Then run `dev-install` once, outside a Claude Code session, with the network up and `dotnet` on `PATH`, under the same user and session rules as `install`, which it checks before cloning anything. It:

- clones any missing reference repositories into `~/work/reference/<repo>` over SSH only: `credfeto-setup-arch-desktop`, `credfeto-global-pre-commit`, `cs-template`, `credfeto-orchestrator` and `credfeto-ai-skills` from `git@github.com:credfeto/<repo>.git`, and `claude` from `git@github.com:dnyw4l3n13/claude.git`;
- switches each reference clone to `main` and fast-forwards it (`git pull --ff-only`), so a re-run brings any clone that already existed up to date before anything runs from it;
- runs `install-dotnet-tools` from the `credfeto-setup-arch-desktop` reference clone, not through `PATH`, with `$HOME` as the working directory;
- symlinks `units/dev-update/dev-update.service` and `dev-update.timer` from the reference clone into `~/.config/systemd/user/` and enables the timer;
- runs `dev-update`, which does the first update and then starts the timer. If another `dev-update` (such as a timer run) holds the lock, `dev-install` stops with an error saying to re-run it once that run finishes, rather than reporting success for an update it never ran.

The timer fires straight away when started, so `dev-update` starts it only once its own run has succeeded and released its lock, and one more run follows shortly that finds everything already up to date. Failing to start the timer is not fatal: it is only enabled, so it starts when the user systemd manager next starts.

Any other failure stops `dev-install`.

## Usage

### Reference clones

The clones in `~/work/reference/` are reference data, kept separate from working checkouts in `~/work/personal/`, which `dev-update` never touches. The `/usr/local/bin` symlinks resolve into the reference clones, and the systemd units run `dev-update` and `network-online` straight from the `credfeto-setup-arch-desktop` reference clone, so the timer never runs code that is mid-change in a working checkout. The symlinks remain for running the scripts by hand.

Both `dev-install` and `dev-update` switch each reference clone to `main` and fast-forward it with `git pull --ff-only`. A clone with uncommitted changes, one that cannot be switched to `main`, or one whose `main` has diverged from its upstream stops the run with an error naming the clone. A directory under `~/work/reference/` that is not itself a git clone also stops the run with an error naming it, because git would otherwise act on whichever repository encloses it. Neither script ever forces, resets or stashes a clone, so fix the clone by hand and re-run.

### dev-update

`dev-update` refuses to run inside a Claude Code session and dies at once when offline, or when neither NetworkManager nor systemd-networkd is running, with a message saying which. Otherwise it clones any missing reference repository into `~/work/reference/` over SSH only, from the same owners as `dev-install` (`credfeto` for all but `claude`, which comes from `dnyw4l3n13`), so a deleted or newly added reference repository is restored without re-running `dev-install`; a failed clone is fatal. The exception is `credfeto-setup-arch-desktop` itself: the timer's units are symlinks into that clone, so deleting it stops the timer (see [dev-update timer](#dev-update-timer)) until `dev-install` is re-run. It then switches every reference clone to `main` and fast-forwards it, as described under [Reference clones](#reference-clones), and runs, stopping on the first failure:

- `credfeto-setup-arch-desktop/install.d/dev-scripts`
- `credfeto-global-pre-commit/install --system`
- `claude/install`
- `credfeto-ai-skills/install`
- `credfeto-orchestrator/install-claude-hooks`

It then runs `update-dotnet-tools` from the `credfeto-setup-arch-desktop` reference clone, with `$HOME` as the working directory, and, once the whole run has succeeded and released its lock, starts `dev-update.timer` (a no-op when it is already running). A lock in `$XDG_RUNTIME_DIR/dev-update.lock` stops a manual run and a timer run overlapping; the second one reports that `dev-update` is already running and exits successfully. `dev-install` runs `dev-update --fail-if-running`, which makes that case an error instead.

### dev-update timer

`dev-update.timer` starts the service 15 seconds after the user manager starts, then every 30 minutes, each with up to 5 minutes of random delay. The service's `ExecCondition=` runs `network-online` from the reference clone, so an offline tick is skipped quietly rather than marking the unit failed.

The units in `~/.config/systemd/user/` are symlinks into the `credfeto-setup-arch-desktop` reference clone. If that clone is deleted, a tick that fires while the units are still loaded is skipped quietly, but after the next `systemctl --user daemon-reload` or login the units no longer load and the timer stops firing. Nothing restores the clone on its own, so re-run `dev-install` to clone it again and relink the units.

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
