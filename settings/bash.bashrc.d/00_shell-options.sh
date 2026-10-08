# shellcheck shell=bash

case $- in
    *i*) iatest=1 ;;
    *) iatest=0 ;;
esac

if [ -f /etc/os-release ]; then
    # Only the distro ID is extracted (via a subshell) rather than sourcing
    # the whole of /etc/os-release into the shell, which would also export a
    # dozen unrelated, generically-named variables (NAME, VERSION, LOGO, ...).
    # shellcheck source=/dev/null
    LINUX_DISTRIBUTION=$(. /etc/os-release && echo "$ID")
    export LINUX_DISTRIBUTION
fi

export KEYS_SERVER_URL=https://keys.markridgwell.com

# Disable the bell
if [[ $iatest -gt 0 ]]; then bind "set bell-style visible"; fi

# Ignore case on auto-completion
# Note: bind used instead of sticking these in .inputrc
if [[ $iatest -gt 0 ]]; then bind "set completion-ignore-case on"; fi

# Show auto-completion list automatically, without double tab
if [[ $iatest -gt 0 ]]; then bind "set show-all-if-ambiguous On"; fi

# Expand the history size
export HISTFILESIZE=10000
export HISTSIZE=500

# Don't put duplicate lines in the history and do not add lines that start with a space
export HISTCONTROL=erasedups:ignoredups:ignorespace

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

# Allow ctrl-S for history navigation (with ctrl-R)
stty -ixon

export EDITOR=nano
export VISUAL=nano
