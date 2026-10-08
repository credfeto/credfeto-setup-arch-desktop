# shellcheck shell=bash

update() {
    if [ -f /usr/bin/topgrade ]; then
        # Update system packages - exclude things that are managed separately
        /usr/bin/topgrade -y \
            --disable=containers \
            --disable=dotnet \
            --disable=jetbrains_aqua \
            --disable=jetbrains_clion \
            --disable=jetbrains_datagrip \
            --disable=jetbrains_dataspell \
            --disable=jetbrains_gateway \
            --disable=jetbrains_goland \
            --disable=jetbrains_idea \
            --disable=jetbrains_mps \
            --disable=jetbrains_phpstorm \
            --disable=jetbrains_pycharm \
            --disable=jetbrains_rider \
            --disable=jetbrains_rubymine \
            --disable=jetbrains_rustrover \
            --disable=jetbrains_toolbox \
            --disable=node \
            --disable=pnpm
    else
        # Update flatpaks if they're present
        [ -f /usr/bin/flatpak ] && flatpak update -y

        # Update system packages using the native tool
        if [ -f /usr/bin/yay ]; then
            yay -Syu --noconfirm
            # Deliberately the real rm, not the interactive rm alias (12_safe-aliases.sh).
            # shellcheck disable=SC2033
            sudo rm -fr /var/cache/pacman/pkg/download-*
            yay -Sc --noconfirm
        elif [ -f /usr/bin/pacman ]; then
            # Deliberately the real pacman, not the pacman alias (85_pacman.sh).
            # shellcheck disable=SC2033
            sudo pacman -Syu --noconfirm
        elif [ -f /usr/bin/apt ]; then
            sudo apt update && sudo apt dist-upgrade -y && sudo apt auto-remove -y
        fi
    fi

    _update_setup_arch_desktop
}

# Prefers the reference clone, which dev-update keeps current, over a
# development checkout that may be mid-change. The reference path mirrors the
# DEV_REFERENCE_DIR default in lib/common, which this deployed file cannot
# source.
_update_setup_arch_desktop() {
    local reference="$HOME/work/reference/credfeto-setup-arch-desktop/install"
    local personal="$HOME/work/personal/credfeto-setup-arch-desktop/install"

    if [ -f "$reference" ]; then
        "$reference"
    elif [ -f "$personal" ]; then
        "$personal"
    fi
}
