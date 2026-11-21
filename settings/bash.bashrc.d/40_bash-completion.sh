# shellcheck shell=bash
# Enable bash programmable completion features in interactive shells.
# (The other half of the upstream zachbrowne.me block this was drawn from
# sourced /etc/bashrc, which doesn't exist on Arch - intentionally left out.)
if [[ $- == *i* ]]; then
    if [ -f "${CREDFETO_TEST_ROOT:-}/usr/share/bash-completion/bash_completion" ]; then
        # shellcheck source=/dev/null
        . "${CREDFETO_TEST_ROOT:-}/usr/share/bash-completion/bash_completion"
    elif [ -f "${CREDFETO_TEST_ROOT:-}/etc/bash_completion" ]; then
        # shellcheck source=/dev/null
        . "${CREDFETO_TEST_ROOT:-}/etc/bash_completion"
    fi
fi
