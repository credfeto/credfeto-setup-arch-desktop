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

Run `install` from a checkout of this repository, as your normal user in a logged-in session (desktop, console or SSH login), not through `sudo` or `su`. It calls `sudo` itself where it needs to, and it needs your systemd user manager to enable the `ssh-agent` user service. It checks both before changing anything: run as root, or where `systemctl --user` cannot reach the user manager, it stops at once with a message saying which. It then runs each step under `install.d/` in turn, including `install.d/dev-scripts`, which copies the files git tracks under `lib/` and `settings/scripts/` into a root-owned, world-readable folder, `/usr/local/lib/credfeto-setup-arch-desktop`, and symlinks every script in that copy into `/usr/local/bin`, so every account can run them without reading your home folder. Untracked and ignored files are never copied. Editing a script in the checkout does not change the installed copy until `install` (or `install.d/dev-scripts`) is run again; an uncommitted edit to a tracked file is copied as it stands. A run that finds any tracked file added, removed, edited or with its execute bit changed makes a new copy and switches to it in one step, keeping the previous copy and deleting older ones; a run that finds nothing changed keeps the current copy and only checks the links, so a long-running script is never left without its copy by repeated timer runs. A lock file beside the copy, `/usr/local/lib/.credfeto-setup-arch-desktop.lock`, stops two runs (a manual one, or another account's timer run) installing at the same time: the second run says it is waiting and waits up to 5 minutes for the first to finish, then stops with an error naming the lock if it is still held.

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

The clones in `~/work/reference/` are reference data, kept separate from working checkouts in `~/work/personal/`, which `dev-update` never touches. `dev-update` reinstalls the `/usr/local/bin` scripts from the reference clone, making a new root-owned copy of its tracked files whenever they have changed, and the systemd units run `dev-update` and `network-online` straight from the `credfeto-setup-arch-desktop` reference clone, so the timer never runs code that is mid-change in a working checkout. The symlinks remain for running the scripts by hand.

Both `dev-install` and `dev-update` switch each reference clone to `main` and fast-forward it with `git pull --ff-only`. A clone with uncommitted changes, one that cannot be switched to `main`, or one whose `main` has diverged from its upstream stops the run with an error naming the clone. A directory under `~/work/reference/` that is not itself a git clone also stops the run with an error naming it, because git would otherwise act on whichever repository encloses it. Neither script ever forces, resets or stashes a clone, so fix the clone by hand and re-run.

### dev-update

`dev-update` refuses to run inside a Claude Code session and dies at once when offline, or when neither NetworkManager nor systemd-networkd is running, with a message saying which. Otherwise it clones any missing reference repository into `~/work/reference/` over SSH only, from the same owners as `dev-install` (`credfeto` for all but `claude`, which comes from `dnyw4l3n13`), so a deleted or newly added reference repository is restored without re-running `dev-install`; a failed clone is fatal. The exception is `credfeto-setup-arch-desktop` itself: the timer's units are symlinks into that clone, so deleting it stops the timer (see [dev-update timer](#dev-update-timer)) until `dev-install` is re-run. It then switches every reference clone to `main` and fast-forwards it, as described under [Reference clones](#reference-clones), and runs, stopping on the first failure:

- `credfeto-setup-arch-desktop/install.d/dev-scripts`, from the reference clone
- `credfeto-global-pre-commit/install --system`
- `claude/install --system`
- `credfeto-ai-skills/install --system`
- `credfeto-orchestrator/install-claude-hooks --system`

Each `--system` installer runs from a published snapshot of its repository rather than from the reference clone, as described under [Published snapshots](#published-snapshots). It then runs `update-dotnet-tools` from the `credfeto-setup-arch-desktop` reference clone, with `$HOME` as the working directory, and, once the whole run has succeeded and released its lock, starts `dev-update.timer` (a no-op when it is already running). A lock in `$XDG_RUNTIME_DIR/dev-update.lock` stops a manual run and a timer run overlapping; the second one reports that `dev-update` is already running and exits successfully. `dev-install` runs `dev-update --fail-if-running`, which makes that case an error instead.

### Published snapshots

Before running a repository's `--system` installer, `dev-update` publishes that repository to `/usr/local/share/development`, so that what the installer sets up system-wide never points into a reference clone. Set `DEV_PUBLISH_DIR` to publish somewhere else.

When the clone's committed `HEAD` has changed since the current snapshot was made, the publish exports it with `git archive` into a new directory named `<repo>-<UTC timestamp>Z`, so untracked and uncommitted files are never published. Each snapshot records the git tree it was made from in a hidden `.published-tree` file at its root; when the clone's committed tree matches the current snapshot's, the publish keeps that snapshot, makes and removes nothing, and the installer runs from it as before. The snapshot is owned by `root:root`, with directories at mode 755 and files writable only by root. The `<repo>` symlink is then switched to the new snapshot in one atomic rename, so an installer never sees a half-written tree. The previous snapshot is kept, so anything still using it keeps working, and any older ones are removed. A lock file in the publish directory, `.publish.lock`, stops two accounts publishing at the same time: the second run says it is waiting and waits up to 5 minutes for the first to finish, then stops with an error naming the lock if it is still held.

An installer that does not support `--system` stops the run with an error naming it.

### dev-update timer

`dev-update.timer` starts the service 15 seconds after the user manager starts, then every 30 minutes, each with up to 5 minutes of random delay. The service's `ExecCondition=` runs `network-online` from the reference clone, so an offline tick is skipped quietly rather than marking the unit failed.

The units in `~/.config/systemd/user/` are symlinks into the `credfeto-setup-arch-desktop` reference clone. If that clone is deleted, a tick that fires while the units are still loaded is skipped quietly, but after the next `systemctl --user daemon-reload` or login the units no longer load and the timer stops firing. Nothing restores the clone on its own, so re-run `dev-install` to clone it again and relink the units.

The service runs `dev-update` through a login shell (`/bin/sh -lc`), because the user manager does not read `/etc/profile.d`. That shell is the POSIX `sh` rather than bash, so a timer run reads `~/.profile` and never `~/.bash_profile` or `~/.bashrc`. The `units/dev-update/run-dev-update` wrapper, which is a bash script, first sources every `settings/bash.bashrc.d` section from the reference clone, which a non-interactive shell never reads. Timer runs therefore get the tool environment of an interactive shell, from two places. The `/etc/profile.d` variables, such as `NUGET_PACKAGES`, `GNUPGHOME`, `NVM_DIR` and the [.NET environment](#net-environment), are the ones `install` or `install-latest-dotnet` last deployed. The tool setup, such as nvm's Node.js, Go and bun on `PATH`, comes from the reference clone's sections, so the two can differ until `install` is run again after the clone has moved on. `PATH` has the same order as in an interactive shell, where `~/.bun/bin` and nvm's Node.js directory come ahead of `/usr/bin`.

Timer runs clone and fast-forward the reference clones over SSH. `SSH_AUTH_SOCK` points at the user `ssh-agent.socket` that `install` enables, so the agent must hold the key.

Timer runs have no terminal, so the `sudo` calls in `dev-scripts`, the `cfwf` copy, publishing the snapshots and the `--system` installers need passwordless `sudo`. Without it the timer run fails at `dev-scripts`.

```sh
systemctl --user list-timers dev-update.timer
journalctl --user -u dev-update.service
```

### network-online

`network-online` exits 0 when online and 1 when offline, under either NetworkManager or systemd-networkd, and 255 when neither is active.

### update

The interactive `update` shell function updates system packages, then runs `install` from `~/work/reference/credfeto-setup-arch-desktop` when that clone exists, otherwise from `~/work/personal/credfeto-setup-arch-desktop`.

### .NET environment

`settings/dotnet-env/dotnet.conf` is the only place the .NET environment is defined: `DOTNET_ROOT` and the other `DOTNET_*` settings, one `NAME=value` per line. Values may hold only letters, digits and `. _ / : + -`. Edit that list, then re-run `install-latest-dotnet` (or `install.d/dotnet-environment`) to apply it; never edit the generated files, which the next run overwrites. Once `install-latest-dotnet` has switched to a new SDK, and only then, it generates from the list, so every kind of session gets the same values:

- `/etc/environment.d/60-dotnet.conf`, for systemd user sessions and the units they start, such as `systemd-run --user` and user timers. It appends the SDK to `PATH` (`PATH=$PATH:/usr/share/dotnet`).
- `/etc/profile.d/60_dotnet.sh` and `/etc/bash.bashrc.d/60_dotnet.sh`, for login shells and every interactive bash. They export the values and add the SDK and `$HOME/.dotnet/tools`, where `dotnet tool install --global` puts tools, to `PATH`, each once.
- A block between `# BEGIN credfeto-setup-arch-desktop dotnet` and `# END credfeto-setup-arch-desktop dotnet` in `/etc/security/pam_env.conf`, for SSH and console logins, with one `NAME DEFAULT=value` line per setting. A re-run replaces the block, so there is only ever one. pam_env cannot append to `PATH`, so the block has no `PATH` line.
- A `/usr/local/bin/dotnet` link to the SDK's `dotnet`, so anything with a minimal `PATH`, such as cron or an SSH command, finds it. Something other than a link already at that path is left alone, with a warning.

`install` runs `install.d/dotnet-environment` too, which does the same for the SDK at `/usr/share/dotnet` and does nothing when no SDK is installed there. The files reach only sessions started after they were written, so log out and back in after the first install.

`uninstall-dotnet` removes all of the above (the link only while it points at this SDK), then the SDK's live link and every install folder `install-latest-dotnet` made. It never runs `dotnet` and leaves each user's `~/.dotnet` alone. It refuses to run inside a Claude Code session, and stops when an `install-latest-dotnet` run holds its lock.

## Changelog

See [CHANGELOG.md][changelog].

## Contributing

See [CONTRIBUTING.md][contributing].

## Security

See [SECURITY.md][security].

[changelog]: CHANGELOG.md
[contributing]: CONTRIBUTING.md
[security]: SECURITY.md
