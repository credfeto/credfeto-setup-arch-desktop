# shellcheck shell=sh

# PATH helpers for the sections that sort after this one. A section is sourced
# again in a shell that inherited its PATH (a nested interactive shell, or
# run-dev-update started from a terminal), so neither helper ever leaves PATH
# holding an entry twice. They stay defined, under a prefix nothing else
# uses, rather than being unset by whichever section happens to be last.

# Adds a directory to the end of PATH unless PATH already holds it.
# Usage: _bashrc_d_path_append <dir>
_bashrc_d_path_append() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="${PATH:+$PATH:}$1" ;;
    esac
}

# Puts a directory at the front of PATH, exactly once: every entry PATH
# already has for it is taken out first, so the directory moves back ahead of
# whatever has since been put in front of it rather than being added again.
# Parameter expansion only, so no process is started.
# Usage: _bashrc_d_path_prepend <dir>
_bashrc_d_path_prepend() {
    _bashrc_d_path_rest=":$PATH:"
    while :; do
        case "$_bashrc_d_path_rest" in
            *":$1:"*) _bashrc_d_path_rest="${_bashrc_d_path_rest%%":$1:"*}:${_bashrc_d_path_rest#*":$1:"}" ;;
            *) break ;;
        esac
    done
    _bashrc_d_path_rest="${_bashrc_d_path_rest#:}"
    _bashrc_d_path_rest="${_bashrc_d_path_rest%:}"
    PATH="$1${_bashrc_d_path_rest:+:$_bashrc_d_path_rest}"
    unset _bashrc_d_path_rest
}
