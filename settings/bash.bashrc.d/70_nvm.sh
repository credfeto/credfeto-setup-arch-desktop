# shellcheck shell=bash disable=SC1091
# Depends on NVM_DIR from 25_xdg-tool-paths.sh, sourced ahead of this file.
if [ -f /usr/share/nvm/nvm.sh ]; then
    # The package's init-nvm.sh is not sourced: it loads bash_completion in
    # every shell, interactive or not. Its set-up is done here instead, with
    # the same NVM_DIR default.
    if [ -z "${NVM_DIR:-}" ]; then
        NVM_DIR="$HOME/.nvm"
        if [ -n "${XDG_CONFIG_HOME:-}" ]; then
            NVM_DIR="$XDG_CONFIG_HOME/nvm"
        fi
    fi
    export NVM_DIR

    # "nvm exec" and some third-party scripts expect nvm.sh and nvm-exec
    # under NVM_DIR.
    if [ ! -e "$NVM_DIR" ]; then
        mkdir -p "$NVM_DIR"
    fi
    # -e is also false for a dangling link, which -f replaces: without it ln
    # would fail on the link's name in every shell and never repair it.
    if [ ! -e "$NVM_DIR/nvm.sh" ]; then
        ln -sf /usr/share/nvm/nvm.sh "$NVM_DIR/nvm.sh"
    fi
    if [ ! -e "$NVM_DIR/nvm-exec" ]; then
        ln -sf /usr/share/nvm/nvm-exec "$NVM_DIR/nvm-exec"
    fi

    # shellcheck source=/dev/null
    . /usr/share/nvm/nvm.sh
    if [[ $- == *i* ]]; then
        # shellcheck source=/dev/null
        . /usr/share/nvm/bash_completion
    fi
elif [ -s "${NVM_DIR:-}/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    if [[ $- == *i* ]] && [ -s "$NVM_DIR/bash_completion" ]; then
        # shellcheck source=/dev/null
        . "$NVM_DIR/bash_completion"
    fi
fi

export NODE_OPTIONS="--max-old-space-size=16384"
