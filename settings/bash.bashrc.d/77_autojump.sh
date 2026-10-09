# shellcheck shell=bash
# Registers the j completion and a PROMPT_COMMAND hook, so interactive only.
if [[ $- == *i* ]] && [ -f /usr/share/autojump/autojump.sh ]; then
    # shellcheck source=/dev/null
    . /usr/share/autojump/autojump.sh
fi
