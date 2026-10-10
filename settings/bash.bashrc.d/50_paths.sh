# shellcheck shell=sh

# Each entry is added only when PATH does not already hold it, so sourcing
# this section again (a nested shell, or run-dev-update started from a
# terminal) does not grow PATH.

# JetBrains Toolbox scripts dir (launcher symlinks) - fixed to check -d, not
# the original's -f, since Toolbox creates this as a directory.
if [ -d "$HOME/.local/share/JetBrains/Toolbox/scripts" ]; then
    case ":$PATH:" in
        *":$HOME/.local/share/JetBrains/Toolbox/scripts:"*) ;;
        *) PATH="$PATH:$HOME/.local/share/JetBrains/Toolbox/scripts" ;;
    esac
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$PATH:$HOME/.local/bin" ;;
esac

case ":$PATH:" in
    *":$HOME/.cargo/bin:"*) ;;
    *) PATH="$PATH:$HOME/.cargo/bin" ;;
esac
