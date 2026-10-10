# shellcheck shell=sh
# Depends on _bashrc_d_path_prepend from 45_path-helpers.sh, sourced ahead of
# this file.
if [ -d "$HOME/.bun" ]; then
    # bun
    export BUN_INSTALL="$HOME/.bun"
    # Prepended, not appended: bun must stay ahead of whatever an earlier
    # section has put in front, such as nvm's node.
    _bashrc_d_path_prepend "$BUN_INSTALL/bin"
fi
