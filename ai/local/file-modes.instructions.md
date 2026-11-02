# Deployed File Mode Instructions

> Load when: any work deploys a file or a tree onto the machine, i.e. touches `install.d/`, `hooks/`, or a `settings/scripts/*` script that writes outside the repo.

[Back to Local Instructions Index](index.md)

## The Rule

A deployed file's mode must be set **explicitly** by the deploying command. Never let it come from the working tree's checkout mode, from the mode of whatever happened to be at the destination already, or from the caller's umask.

This repo is worked on under a `027` umask, so anything that inherits a mode lands `root:root` with nothing for group or other. Everything that then reads it as an ordinary user fails, usually silently: a `/etc/bash.bashrc.d/*.sh` loader sources nothing, `systemctl cat` cannot read a unit, an installed `dotnet` cannot be executed.

## Per-File Deployment

Use `sudo install -m <mode> <src> <dest>`, or `install -m <mode> <src> <dest>` without `sudo` for a file that goes under the user's home (`install.d/firejail`). **Never `cp`, with or without `sudo`**:

- Destination does not exist: `cp` gives it the **source** file's mode, i.e. the working tree's checkout mode.
- Destination does exist: `cp` silently keeps the **destination's** mode, so the result depends on what was there before and is not reproducible across machines.

Without `sudo` the same two cases apply, and a new file's mode is also masked by the caller's umask.

`install -m` sets the mode explicitly in every case. Give it the full target path, not the target directory, so the command line names the file it writes and a test can assert the mode per target.

Modes: `0644` by default; `0755` for anything that must be executable, including a NetworkManager dispatcher script, which NetworkManager silently ignores otherwise; `0640` for audit rules; `0600` for usbguard rules. Anything tighter than `0644` needs a stated reason.

## Whole-Tree Deployment (Archive Extraction)

`install -m` does not scale to a tree of thousands of files, so both of these are required, not either/or:

- **`umask 022`** before anything is created. Two separate stages each apply the caller's umask, so fixing one leaves the other to re-break the modes:
  - `tar` takes the archive's own modes only for the superuser, or when given `-p`. An ordinary user without it extracts a `0755` member as `0750`.
  - `cp` masks the source mode with the umask again on the way out, so even a correctly extracted `0755` source lands `0750`.
  - `sudo` does not rescue either: it inherits the caller's umask rather than replacing it with the sudoers default. Verify with `sudo -n sh -c 'umask'`.
- **`sudo chmod -R a+rX <root>`** after the copies, in the function that creates the files. This states the guarantee where the files are produced rather than resting on a umask set far above, and still holds for an archive member shipped with a restrictive mode of its own. `+X` adds execute only where some class already has it or the target is a directory, so a data file cannot become executable.

Setting the mode on the install root alone is not enough: `install-latest-dotnet` already had `sudo chmod 755 /usr/share/dotnet` and everything under it was still root-only.

An archive extracted without `cp` needs only an explicit mode after the extraction: `publish_reference_repo` in `lib/common` extracts `git archive HEAD` of a reference clone with `tar`, then sets `chmod -R u=rwX,go=rX` on the snapshot before handing it to root with `sudo chown -R root:root`.

A tree small enough to copy file by file needs no archive: `install.d/dev-scripts` copies the files git tracks under `lib/` and the `settings/scripts/` folders (their working-tree content, listed with `list_tracked_files` from `lib/common`) with `install -d -m 755` per folder and `install -m 755` or `install -m 644` per file, by the source's execute bit, under `umask 022`, then hands the copy to root with `sudo chown -R root:root`. A run that finds the current copy already matching the tracked files, content and execute bits keeps it rather than making another.

Both make a new root-owned folder beside a stable link and switch the link to it with the shared `lib/common` helpers (`versioned_folder_name`, `switch_versioned_link`, `prune_versioned_folders`), under a run lock, keeping the current and previous folders and removing older ones with `sudo rm -rf`, since only root can empty a root-owned folder. Neither makes a new folder when nothing has changed: `publish_reference_repo` records the git tree each snapshot was made from in a hidden `.published-tree` file at its root and keeps a snapshot whose record matches the clone's committed tree.

## Verification

Modes under a hard-coded system path cannot be proved by the bats suites, because running the deployment for real would mutate the host. Where the destination is overridable instead, as `DEV_SCRIPTS_BIN_DIR` and `DEV_SCRIPTS_LIB_DIR` are for `install.d/dev-scripts`, point it at the test's temporary directory, run the step for real under a restrictive umask and read the modes back with `stat` (`test/dev-scripts.bats`). Otherwise assert the deploying command: run the step against the fake sudo from `test/test_helper.bash`, which logs each command line without running it, and check the mode each `install -m` was given (`test/shell-environment.bats`, and `test/install-steps.bats` for the other `install.d/` steps); where the script cannot be run at all, assert the construct statically (`test/general.bats`). A deployment under the user's home is different: the suites run with `HOME` in the test's temporary directory, so run the step for real under a restrictive umask, onto a destination that already exists with another mode, and read the modes back with `stat` (the `firejail` tests in `test/install-steps.bats`). `test/install-steps.bats` also fails when any line under `install`, `install.d/`, `units/` or `lib/` runs `cp` as a command, with or without `sudo`; it makes no exception, because nothing there needs one: the only whole-tree copy that uses `cp` is in `settings/scripts/general/install-latest-dotnet`, outside its search; `publish_reference_repo` in `lib/common` extracts its archive with `tar`, and `install.d/dev-scripts` copies its tree with `install -m`. Confirm the actual modes by re-running the install on the machine and checking with `stat -c '%A %U:%G %n'`.
