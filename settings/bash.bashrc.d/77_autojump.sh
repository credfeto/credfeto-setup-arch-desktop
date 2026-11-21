# shellcheck shell=bash
# Registers the j completion and a PROMPT_COMMAND hook, so interactive only.
if [[ $- == *i* ]] && [ -f "${CREDFETO_TEST_ROOT:-}/usr/share/autojump/autojump.sh" ]; then
    # shellcheck source=/dev/null
    . "${CREDFETO_TEST_ROOT:-}/usr/share/autojump/autojump.sh"
fi
