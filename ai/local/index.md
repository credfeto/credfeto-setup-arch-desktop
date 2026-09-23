<!-- Globally Maintained -->
# Local instructions

This is an index of local instructions that apply to just this project.

* Ensure consistency across this file with respect to the global instructions.
* This file should be considered an index of local instructions.
* Each file other than this one should be named in the format `<category>.instructions.md` where `<category>` is the category of the file and all related rules should be listed there.
* `<category>.instructions.md` files should be placed in this directory.
* `<category>.instructions.md` files should maintain a backlink to this file.
* If this is the [git@github.com:credfeto/cs-template.git](https://github.com/credfeto/cs-template) repository, this folder should not have any other instructions than this file.
* This file should not be modified in [git@github.com:credfeto/cs-template.git](https://github.com/credfeto/cs-template), but can be modified in forks and other repositories as needed.
* The rules above this point in the file should be considered global rules.

## Instruction Files
<!-- Locally Maintained -->
| File | Load When | Covers |
| --- | --- | --- |
| [arch-packages.instructions.md](arch-packages.instructions.md) | Any install script or package management work is present | AUR helper prohibition, allowed package sources, removal steps |
| [file-modes.instructions.md](file-modes.instructions.md) | Any work deploys a file or a tree onto the machine (`install.d/`, `hooks/`, a `settings/scripts/*` script that writes outside the repo) | `install -m` over `cp` for single files, `umask 022` plus `chmod -R a+rX` for extracted trees, modes to use, why `sudo` does not reset the umask |
| [install-structure.instructions.md](install-structure.instructions.md) | Any work touches `install`, `install.d/`, or `lib/common` | `install.d/` + `lib/common` pattern, script shape, naming convention, calling convention, install-state flags |
| [shell-config.instructions.md](shell-config.instructions.md) | Any work touches `settings/shell-env/`, `settings/bash.bashrc.d/`, or `install.d/shell-environment` | Origin (partial live-paste port of a sibling repo's bashrc), profile.d vs bash.bashrc.d deployment tiers, file naming/load order, adding a new section, known AUR-helper policy exception |
