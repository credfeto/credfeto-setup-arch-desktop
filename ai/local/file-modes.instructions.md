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

## Verification

Modes under a system path cannot be proved by the bats suites: the destination is a hard-coded real path, and running the deployment for real would mutate the host. Assert the deploying command instead: run the step against the fake sudo from `test/test_helper.bash`, which logs each command line without running it, and check the mode each `install -m` was given (`test/shell-environment.bats`, and `test/install-steps.bats` for the other `install.d/` steps); where the script cannot be run at all, assert the construct statically (`test/general.bats`). A deployment under the user's home is different: the suites run with `HOME` in the test's temporary directory, so run the step for real under a restrictive umask, onto a destination that already exists with another mode, and read the modes back with `stat` (the `firejail` tests in `test/install-steps.bats`). `test/install-steps.bats` also fails when any line under `install`, `install.d/`, `units/` or `lib/` runs `cp` as a command, with or without `sudo`; it makes no exception, because nothing there needs one: the only whole-tree copy is in `settings/scripts/general/install-latest-dotnet`, outside its search. Confirm the actual modes by re-running the install on the machine and checking with `stat -c '%A %U:%G %n'`.
