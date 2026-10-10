# shellcheck shell=sh
if [ -d "$HOME/.bun" ]; then
    # bun
    export BUN_INSTALL="$HOME/.bun"
    # Skipped only when bun already leads PATH, so sourcing this again does
    # not grow PATH. Membership alone is not enough: bun must stay ahead of
    # whatever an earlier section has since put in front, such as nvm's node.
    case "$PATH" in
        "$BUN_INSTALL/bin:"*) ;;
        *) export PATH="$BUN_INSTALL/bin:$PATH" ;;
    esac
fi
