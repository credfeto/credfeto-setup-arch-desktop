# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
### Added
- Added .ai-instructions and ai/local/index.md from cs-template standard
- Local firejail override for shellcheck to allow bats/pre-commit test fixtures in /run/user/<uid> and /tmp
- Render /etc/ssh/sshd_config.d/14_KeyServer.conf at install time with the per-machine hostname baked in, enabling AuthorizedKeysCommand lookups against the central key server
- Added a system-wide coloured Starship bash prompt, giving every interactive shell a themed prompt with visually distinct root styling, without overriding a user's own Starship config
- Added a system-wide shell environment (env vars, aliases, functions) deployed via a new install.d/shell-environment step, sourced from /etc/profile.d and a new /etc/bash.bashrc.d/, so every user's interactive shell and non-interactive tooling gets the same XDG-aware environment, ll/ls aliases, and an update() helper that runs this repo's own install script
- Migrated desktop-scoped dev scripts (dbappsettings, dbenv, querydb, pre-commit-check, and a batch of build/git/linux tooling scripts) from credfeto/scripts and credfeto-orchestrator into a new install.d/dev-scripts step, symlinking them into /usr/local/bin so a fresh desktop setup needs only this one repo; also added a new install.d/git-environment step for git identity/signing/behaviour config
- Added a new install.d/configure-pacman step that enables pacman's ILoveCandy, CheckSpace, and VerbosePkgLists options, giving package operations a progress indicator, a pre-flight disk-space check, and full package lists on every machine this repo sets up
- Disable and purge the baloo file indexer (balooctl6) during install when present, reducing background indexing overhead
- Set CLAUDE_CODE_TMPDIR to the XDG runtime directory so Claude Code uses the per-session tmpfs instead of the shared system temp directory
- Extended the global git configuration with rerere, zdiff3 conflict markers, histogram diffs, parallel fetch, commit-graph writing, object integrity checks, tag signing and other recommended defaults, so every machine gets safer and faster git behaviour out of the box
- Added a tmux-here command that attaches to the tmux session for the current directory, creating it first if it does not exist, so each project directory keeps its own persistent terminal session
- Added a dev-install command that clones the six tooling repos into ~/work/reference over SSH, installs the .NET tools, installs a user systemd timer and runs dev-update, refusing inside a Claude Code session, when offline or without dotnet
- Added a network-online command that reports whether NetworkManager or systemd-networkd has a working connection
- Added a user systemd timer that runs dev-update from the ~/work/reference clone shortly after login and then every 30 minutes, skipping quietly when offline
- Added a required CI check that runs the bats shell test suite on every pull request to main and fails when any test fails, is skipped or does not run
- Added the Credfeto.Build.Dotnet.Server dotnet tool to the tools installed by install-dotnet-tools
- Added a bats test pinning the symlinked /usr/share/dotnet layout install-latest-dotnet produces, as the global pre-commit hook expects (#110)
### Fixed
- Fixed missing trailing newlines in units/auto-update scripts
- Use sudo when removing root-owned sysctl config files installed by the install script
- Fixed install script failing with "hostname: not found" on Arch by using hostnamectl --static instead of the hostname command, which also preserves the full configured hostname (e.g. local domain suffix) instead of truncating it
- Fix Starship prompt colours being silently disabled by the bash.bashrc.d PROMPT_COMMAND overwrite
- pre-commit-check now fails fast when the current branch is behind its own upstream or the remote default branch, instead of running checks against stale code
- pre-commit-check no longer blocks commits as behind immediately after a local rebase that has not yet been pushed
- dev-update now waits for network via systemd-networkd (using systemd-networkd-wait-online) as well as NetworkManager (using nm-online), so it works on hosts that don't run NetworkManager
- Stopped shellcheck following system files sourced by the shell configuration, and updated stale install-dotnet-tools and dev-update test fixtures, so pre-commit-check passes again
- Removed tracked .idea/.gitignore file that was already in .gitignore
- Clone the claude reference repo from its real owner (git@github.com:dnyw4l3n13/claude.git) instead of credfeto.
- Dev-scripts now fails when sudo, install or link steps fail, instead of silently continuing with broken symlinks
- Install and every install.d script now fail fast with explicit error messages when deployment steps fail, instead of silently continuing; units/auto-update/install, benchmark-test-affected, install-latest-dotnet, update-dotnet-sdk and dbenv were similarly hardened with || die guards and here-doc loops so that subshell exit codes no longer vanish
- dev-update no longer lets the processes it starts inherit its run lock, so a leftover ssh or gpg process can no longer keep the lock after a run ends and silently stop every later timer run
- Install the audit and apparmor packages before enabling auditd and apparmor, so install no longer stops on a machine without them
- The dev-update timer now runs with the ~/.local/bin and .NET PATH and DOTNET_ROOT settings from bash.bashrc.d, so timer runs find dotnet and user-installed tools
- update-dotnet-sdk no longer deletes global.json before replacing it, so a failed move leaves the original in place
- dev-update now starts the dev-update timer once a successful run has released its lock, so the timer runs without waiting for the next login and never collides with the run that started it
- dev-scripts now removes dangling /usr/local/bin links into either the personal or the reference checkout, so a script removed upstream no longer leaves a broken command on PATH
- dev-install and dev-update now report when neither NetworkManager nor systemd-networkd is running, instead of claiming there is no network connection
- fail2ban is now installed before its jail config is copied, so install no longer stops on a fresh machine where /etc/fail2ban/jail.d does not exist yet
- configure-network now skips its NetworkManager-specific configuration on hosts where NetworkManager is not running, such as systemd-networkd hosts, so install no longer stops there
- install and dev-install now stop before changing anything when run as root or without a reachable systemd user session, instead of failing partway through
- configure-network now moves NetworkManager onto systemd-resolved before removing dnsmasq, so a failure partway through can no longer leave DNS pointing at a missing dnsmasq
- dev-install and dev-update now refuse a reference clone directory that is not a git clone, instead of running git in an enclosing repository
- dev-install now fails when another dev-update run holds the lock, instead of reporting success without updating
- dev-install and dev-update now run the .NET tool install and update scripts from the reference clone instead of whichever copy is on PATH
- dev-update timer runs now source every bash.bashrc.d section under bash, so nvm's Node.js and npm, Go and bun are on PATH and the npm global install step no longer fails
- bash.bashrc.d sections no longer write terminal-only errors or nvm first-run output, or register autojump's completion and prompt hook, when sourced by a non-interactive shell
- The shell environment installer and run-dev-update now fail with a clear error when no shell config sections are found, instead of the installer reporting success with nothing deployed
- Installed config files, units and scripts now get explicit permissions instead of inheriting the installing user's umask, so their modes are the same on every machine
- Shell sections no longer leave a stray iatest variable set in every shell
- Re-sourcing the bash.bashrc.d sections no longer adds duplicate PATH entries for paths, Go, .NET and bun, and the Go section now adds the bin directory of the first GOPATH entry when GOPATH lists several
- 70_nvm.sh loads nvm once and registers its completion only in an interactive shell; it now replaces dangling nvm.sh or nvm-exec links in NVM_DIR instead of failing with 'File exists' on every shell start and dev-update timer run
- The bats test suite no longer corrupts the developer's repository when run from a git commit hook in a linked worktree
- The bats test suite no longer reads the developer's global or system git configuration files
- pacman-sync no longer reports failed when checkupdates finds no updates (exit code 2), and enable-services installs fakeroot, which checkupdates needs to run
- configure-flatpak: fail when flatpak remotes fails instead of treating it as no flathub remote (#59)
- install-latest-dotnet finds the .NET tool manifest at ~/dotnet-tools.json, so re-runs no longer fail when a manifest already exists
- The login tests no longer launch the host's real stream script, which could hang the test suite
- install-latest-dotnet builds the new SDK install beside the live one and switches to it in a single rename, so a failed or interrupted run leaves the existing dotnet working; a first-run install is moved aside to a dotnet-legacy-<stamp> folder and put back in place if it cannot be switched, and a run stops rather than removing or overwriting a folder when its new dotnet-<stamp> or dotnet-legacy-<stamp> name is already taken
- buildtest restores the .NET code-analysis ruleset when the override tool fails part-way through or a signal (Ctrl-C, TERM or HUP) stops the run, instead of leaving the ruleset changed
- install-latest-dotnet keeps its temporary files under /var/tmp and removes them when the run ends, including when it fails or a signal (Ctrl-C, TERM or HUP) stops it, checks free disk space before downloading (filesystems are told apart by UUID so btrfs subvolumes count as one, falling back to device id), and takes one system-wide run lock beside the install, opened read-only, so a lock owned by root or another account never blocks a run and XDG_RUNTIME_DIR is no longer needed
- benchmark-test-affected and fetch remove their temporary files when a signal (Ctrl-C, TERM or HUP) stops them, instead of leaving them behind
- section_reading in the test helper now fails, naming the section and line, when the system directory appears inside a command substitution within a double-quoted string, instead of silently rewriting it with nested quotes mis-read (#94)
- Installed dev scripts are now copied into a root-owned, world-readable versioned folder beside /usr/local/lib/credfeto-setup-arch-desktop, switched in one step with the previous copy kept, and the /usr/local/bin links point there instead of into the checkout, so every account can run them (#103); the copy is replaced only when install or dev-update runs and the scripts have changed
- Dev-scripts keep the current copy when nothing has changed, so long-running scripts are not left without their copy
- Old root-owned dev-scripts copies and dev-update snapshots are removed with sudo, so an account other than the one that created them can still clear them out
- install-latest-dotnet stops instead of installing a partial .NET SDK when the extracted files cannot be listed
- dev-update publish takes a lock and waits up to five minutes for another account's publish, so two accounts cannot prune each other's root-owned snapshots under /usr/local/share/development
- dev-scripts and dev-update publish stop, changing nothing, when a real folder stands where their /usr/local link goes, instead of failing at the switch after the work is done
- dev-scripts removes /usr/local/bin links that still point into a checkout, live as well as dangling, and links to scripts that are tracked but no longer executable, so a command installed from one account's branch, or a script that lost its execute bit, no longer fails for every other account
- Dev-scripts copy only git-tracked files, so untracked, ignored and private files in the checkout are never made world-readable; tracked symlinks are skipped with a warning, so a link to a private file is never copied
- Shell environment and sshd drop-ins are deployed only from git-tracked files, so an untracked or private file left beside them never reaches /etc/profile.d, /etc/bash.bashrc.d or /etc/ssh/sshd_config.d; tracked symlinks are skipped with a warning
- Unfinished dev-scripts copies are removed when a run fails or is stopped, and unfinished dev-update snapshots are removed when a publish fails (a signal mid-publish can leave one until the repo next changes), so half-filled root-owned folders no longer pile up under /usr/local; a copy that the /usr/local/lib link already points at is never removed
- Dev-scripts installs take a run lock and wait up to five minutes for another run to release it, instead of failing, and read the checkout only once the lock is held, so a manual install and the dev-update timer no longer clash or copy a stale list
- dev-update prunes only its own snapshots, so a published repo whose name extends another's, such as claude-2 beside claude, keeps its snapshots
- Shell environment, sshd drop-ins and dev-scripts refuse to deploy unless run from the top of a git clone, printing one clear error before anything is installed instead of a second misleading one, and never deploy files that an enclosing repository tracks; outside a clone nothing is created under /usr/local, including dev-scripts' lock
- dev-update keeps the published snapshot when the committed tree has not changed, so a process started from a snapshot is no longer cut off after two runs and nothing is rebuilt when the tree is unchanged; the archive is exactly the tree recorded for the snapshot, even if HEAD moves while publish waits for its lock
- Shell environment, sshd drop-ins and dev-scripts refuse to deploy from a checkout with unresolved merge conflicts, so conflict markers are never copied into /etc or the scripts copy and a duplicate-script error no longer misleads
- Set the .NET environment (DOTNET_ROOT, DOTNET_* settings, PATH) for all users and every session type, not just interactive bash (#106)
- dev-update no longer refuses a published installer whose text does not mention --system; installers are judged only by their exit code (#124)
### Changed
- Refactored install script into named functions for readability and easier future extraction into separate install.d/ scripts
- Split the monolithic install script into standalone install.d/ scripts sharing lib/common, so each installation step can be run and understood independently
- Deduplicated die/success/info/warn helper scripts across settings/scripts/* by sourcing the shared lib/common (now with a TTY-guarded warn added), instead of each script hand-rolling its own copy
- NetworkManager now uses systemd-resolved instead of dnsmasq for DNS resolution; the previous dnsmasq drop-ins, service, and package are removed on next install run if present
- dev-update now waits for the network before pulling repos and runs update-dotnet-tools before completing
- The update command runs the install from the ~/work/reference clone when present, falling back to the ~/work/personal checkout
- dev-update now clones any missing ~/work/reference repo over SSH, switches each reference clone to main and fast-forwards it (stopping on a dirty or diverged clone), runs every tooling installer with any failure being fatal, refuses inside a Claude Code session, stops at once when offline, and exits quietly when another run is in progress
- The cd aliases, Go section and distro lookup in the shell sections no longer start extra processes, so shell start and timer runs are faster
- Shell script tests now use fake versions of nvm, autojump, Go and .NET instead of skipping when these tools are not installed
- dev-update now publishes the reference repos (credfeto-global-pre-commit, claude, credfeto-ai-skills and credfeto-orchestrator) as root-owned, timestamped snapshots under /usr/local/share/development, switches a symlink to each new snapshot atomically, and runs their installers with --system from that snapshot, so system-wide installs never point into a reference clone that can change or be removed
- install-latest-dotnet installs only the .NET 10 and 11 SDKs, no longer 8.0 and 9.0
- install-latest-dotnet now installs and updates all the dotnet tools through install-dotnet-tools and update-dotnet-tools instead of only PowerShell, which also moves any global dotnet tools into the $HOME tool manifest; a tool that fails to install no longer stops the run
- Quoted temporary-directory paths in generated bats fake and stub scripts
### Deprecated
### Removed
- Removed yay and paru AUR helpers from install script; direct AUR package installs are prohibited
- Removed dead ~/work/personal/scripts/* PATH entries from the shell environment config; that directory was never populated and the repo's own dev-scripts are already installed onto PATH via /usr/local/bin
### Deployment Changes

<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->

## [0.0.0] - Project created