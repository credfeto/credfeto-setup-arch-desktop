# shellcheck shell=bash

if [ -f /etc/os-release ]; then
    # Only the distro ID is extracted (via a subshell) rather than sourcing
    # the whole of /etc/os-release into the shell, which would also export a
    # dozen unrelated, generically-named variables (NAME, VERSION, LOGO, ...).
    # shellcheck source=/dev/null
    LINUX_DISTRIBUTION=$(. /etc/os-release && echo "$ID")
    export LINUX_DISTRIBUTION
fi

export KEYS_SERVER_URL=https://keys.markridgwell.com

# Expand the history size
export HISTFILESIZE=10000
export HISTSIZE=500

# Don't put duplicate lines in the history and do not add lines that start with a space
export HISTCONTROL=erasedups:ignoredups:ignorespace

# Interactive-only: this file is also sourced by non-interactive shells,
# where bind warns that line editing is not enabled.
if [[ $- == *i* ]]; then
    # Disable the bell
    bind "set bell-style visible"

    # Ignore case on auto-completion
    # Note: bind used instead of sticking these in .inputrc
    bind "set completion-ignore-case on"

    # Show auto-completion list automatically, without double tab
    bind "set show-all-if-ambiguous On"

    # Check the window size after each command and, if necessary, update the values of LINES and COLUMNS
    shopt -s checkwinsize

    # Causes bash to append to history instead of overwriting it so if you start a new terminal, you have old session history
    shopt -s histappend
    # Append rather than overwrite: this file is sourced from the
    # /etc/bash.bashrc.d loop, which runs after install.d/shell-prompt's Starship
    # block has already hooked PROMPT_COMMAND to redraw the prompt each command.
    # A plain assignment here would silently wipe that hook, leaving the prompt
    # static (no colours) instead of erroring - so append instead.
    PROMPT_COMMAND+=('history -a')

    # Allow ctrl-S for history navigation (with ctrl-R). stty needs a
    # terminal on stdin, which an interactive shell does not always have (a
    # bash -i with piped or redirected stdin), and fails without one.
    if [ -t 0 ]; then
        stty -ixon
    fi
fi

export EDITOR=nano
export VISUAL=nano
