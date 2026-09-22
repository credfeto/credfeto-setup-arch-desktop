# shellcheck shell=sh

# JetBrains Toolbox scripts dir (launcher symlinks) - fixed to check -d, not
# the original's -f, since Toolbox creates this as a directory.
[ -d "$HOME/.local/share/JetBrains/Toolbox/scripts" ] && PATH="$PATH:$HOME/.local/share/JetBrains/Toolbox/scripts"

PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin"
