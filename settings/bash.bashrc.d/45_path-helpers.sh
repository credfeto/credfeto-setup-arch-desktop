# shellcheck shell=sh

# PATH helpers for the sections that sort after this one. A section is sourced
# again in a shell that inherited its PATH (a nested interactive shell, or
# run-dev-update started from a terminal), so an entry is only ever added when
# PATH does not already hold it. They stay defined, under a prefix nothing else
# uses, rather than being unset by whichever section happens to be last.

# Adds a directory to the end of PATH unless PATH already holds it.
# Usage: _bashrc_d_path_append <dir>
_bashrc_d_path_append() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="${PATH:+$PATH:}$1" ;;
    esac
}
