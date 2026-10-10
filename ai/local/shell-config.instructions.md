# Shell Config Instructions

> Load when: any work touches `settings/shell-env/`, `settings/bash.bashrc.d/`, or `install.d/shell-environment`.

[Back to Local Instructions Index](index.md)

## Origin

This content is a curated, partial port of a sibling repo's `../mybash/.bashrc` (not part of this repo), done live in chat: the user pastes the specific sections they actually use, and unused aliases/functions are dropped rather than ported wholesale. Do not port a section that hasn't been explicitly requested; when auditing for gaps, list what's missing and let the user decide rather than adding it unasked.

## Pattern

Two deployment tiers, both filled from small, single-purpose section files (one concern per file, numbered for load order) rather than one large script:

- **`settings/shell-env/`**: env vars genuinely needed outside interactive bash (GUI apps, systemd user units, non-interactive scripts) - e.g. `XDG_*`, `TMP`/`TMPDIR`, `SSH_AUTH_SOCK`. Deployed by `install.d/shell-environment` to **both** `/etc/profile.d/<name>` (login shells, GUI sessions - already auto-sourced by the system, no loader block needed) **and** `/etc/bash.bashrc.d/<name>` (every interactive bash shell - see below). Must stay POSIX `sh`-safe (`# shellcheck shell=sh`) since `/etc/profile.d` may be sourced by a non-bash shell, and must be idempotent (guard exports, don't unconditionally append to `PATH`) since a login-interactive shell sources both tiers.
- **`settings/bash.bashrc.d/`**: everything bash-only (aliases, functions, tool `PATH` setup, `bind`/`shopt`/`stty` calls, bash-only syntax like `[[ ]]` or `$'...'`). Deployed only to `/etc/bash.bashrc.d/<name>`, sourced via one guarded `# BEGIN/END credfeto-setup-arch-desktop bash.bashrc.d` block appended to `/etc/bash.bashrc` (same marker style as the existing Starship block in `install.d/shell-prompt`), so it reaches every interactive shell system-wide, not just login shells - `/etc/profile.d` alone would not.
  - Every section is **also** sourced, in filename order, by `units/dev-update/run-dev-update` in a non-interactive bash with no terminal (the `dev-update` systemd user unit), so timer runs see the same tools on `PATH` as an interactive shell. Put anything interactive-only (`bind`, `shopt`, `stty`, `PROMPT_COMMAND`, `complete` and completion scripts) behind an interactive check (`[[ $- == *i* ]]`, or `00_shell-options.sh`'s `iatest` within that file), and keep env exports and `PATH` changes outside it. A command that needs a terminal on stdin (`stty`) also needs `[ -t 0 ]` inside that check, because an interactive shell is not always on a terminal (`bash -i` with piped or redirected stdin). Aliases and functions are harmless there and need no guard.
  - A section is sourced again in a shell that inherited its `PATH` (a nested interactive shell, or `run-dev-update` started from a terminal), so add a `PATH` entry only when it is not already there. For an append, call `_bashrc_d_path_append <dir>` rather than writing the test out. It is defined in `45_path-helpers.sh`, which is POSIX `sh` because `sh` sections call it, and which every section that changes `PATH` must sort after. A test that sources one such section on its own sources `45_path-helpers.sh` first. For a prepend, test only whether `PATH` already starts with the entry, so it still moves back ahead of whatever an earlier section has since put in front. `test/units.bats` fails if any section writes to stdout or stderr when sourced non-interactively.

Do **not** put aliases/functions/env vars needed by ordinary desktop terminals into `/etc/profile.d` alone: on Arch, a normal terminal window opens a non-login interactive shell, which sources `/etc/bash.bashrc`, not `/etc/profile`.

## File Naming and Load Order

`NN_name.sh`, two-digit numeric prefix, same convention as `settings/sshd/` and `settings/sysctl/`. Numbers matter: since `/etc/bash.bashrc.d/*.sh` is sourced in filename order and mixes both tiers together, an env file a later file depends on (e.g. `25_xdg-tool-paths.sh` setting `NVM_DIR`, consumed by `70_nvm.sh`) must sort earlier. Leave gaps (10s) between numbers so a new file can be inserted without renumbering everything else.

## Adding a New Section

1. Decide the tier: does anything outside bash need it (GUI apps, `sh` scripts, systemd units other than `dev-update`)? If yes → `settings/shell-env/`; otherwise → `settings/bash.bashrc.d/`, guarding any interactive- or terminal-only part as described above.
2. Add the file with the next free number in the right range, `# shellcheck shell=sh` or `# shellcheck shell=bash` as appropriate.
3. Nothing to add to `install.d/shell-environment`: it deploys every `*.sh` file in each directory from a loop, with `sudo install -m 0644`, so a new file is deployed to its tier's targets automatically. Keep it that way rather than adding per-file lines, which can be forgotten and leave a file silently undeployed. Never `sudo cp`; see [file-modes.instructions.md](file-modes.instructions.md) for why, and for the modes to use. `test/shell-environment.bats` runs the script against the fake sudo and fails unless the deployed files match the two directory listings exactly, each with mode `0644`.
4. If porting from the source `.bashrc`: fix real bugs found along the way (e.g. a `mkdir` targeting the wrong path, an unguarded var that can resolve to empty) rather than porting them faithfully, but call out the fix rather than silently changing behaviour beyond what was asked.

## Known Accepted Policy Conflict

`85_pacman.sh`'s `pacman-rebuild-aur()` function calls the AUR helper `yay`, which conflicts with [arch-packages.instructions.md](arch-packages.instructions.md)'s AUR-helper prohibition. This is a deliberate, user-confirmed exception (not an oversight) for machines where an AUR helper is kept outside this repo's own installs; `install.d/remove-aur-helpers` still removes `yay` wherever this repo's own install script runs. Do not "fix" this by removing the function without being asked.
