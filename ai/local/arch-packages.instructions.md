# Arch Package Management Instructions

> Load when: any install script or package management work is present in this repo.

[Back to Local Instructions Index](index.md)

## AUR Helpers

AUR helpers (`yay`, `paru`, `trizen`, `aurman`, `pikaur`, or any other tool that installs from the AUR directly) **must not be installed** on the target system.

- If any AUR helper is detected, the install script **must remove it** using `pacman -Rns --noconfirm <package>`.
- Never add calls to AUR helpers in any install script in this repo.
- Never add `yay`, `paru`, or any other AUR helper as a dependency or installation step.

## Package Sources

Packages **must** only be installed from one of these sources:

- Official Arch repositories (`pacman -S`)
- [Chaotic AUR](https://aur.chaotic.cx/) — a pre-built binary mirror; install via `pacman -S` after the repo is configured

Direct AUR builds (i.e. cloning a PKGBUILD and running `makepkg`) are **prohibited** in install scripts in this repo.

## Removing AUR Helpers

The install script must explicitly remove known AUR helpers if present. Use `pacman -Qq` to check before attempting removal:

```sh
pacman -Qq yay >/dev/null 2>&1 && sudo pacman -Rns --noconfirm yay
pacman -Qq paru >/dev/null 2>&1 && sudo pacman -Rns --noconfirm paru
```

If new AUR helpers are discovered in the wild, add them to this removal block and update this file.
