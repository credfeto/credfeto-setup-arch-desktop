# shellcheck shell=sh
# Depends on _bashrc_d_path_append from 45_path-helpers.sh, sourced ahead of
# this file.

# JetBrains Toolbox scripts dir (launcher symlinks) - fixed to check -d, not
# the original's -f, since Toolbox creates this as a directory.
if [ -d "$HOME/.local/share/JetBrains/Toolbox/scripts" ]; then
    _bashrc_d_path_append "$HOME/.local/share/JetBrains/Toolbox/scripts"
fi

_bashrc_d_path_append "$HOME/.local/bin"
_bashrc_d_path_append "$HOME/.cargo/bin"
