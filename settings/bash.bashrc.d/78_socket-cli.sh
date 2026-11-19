# shellcheck shell=bash disable=SC1091
# Socket CLI completion for "socket"
if [[ $- == *i* ]] && [ -f "$HOME/.local/share/socket/completion/socket-completion.bash" ]; then
    # Load the tab completion script
    # shellcheck source=/dev/null
    . "$HOME/.local/share/socket/completion/socket-completion.bash"
    # Tell bash to use this function for tab completion of this function
    complete -F _socket_completion socket
fi
