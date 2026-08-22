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
### Fixed
- Fixed missing trailing newlines in units/auto-update scripts
- Removed tracked .idea/.gitignore file that was already in .gitignore
- Use sudo when removing root-owned sysctl config files installed by the install script
- Fixed install script failing with "hostname: not found" on Arch by using hostnamectl --static instead of the hostname command, which also preserves the full configured hostname (e.g. local domain suffix) instead of truncating it
- Fix Starship prompt colours being silently disabled by the bash.bashrc.d PROMPT_COMMAND overwrite
### Changed
- Refactored install script into named functions for readability and easier future extraction into separate install.d/ scripts
- Split the monolithic install script into standalone install.d/ scripts sharing lib/common, so each installation step can be run and understood independently
### Deprecated
### Removed
- Removed yay and paru AUR helpers from install script; direct AUR package installs are prohibited
### Deployment Changes
<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->
## [0.0.0] - Project created