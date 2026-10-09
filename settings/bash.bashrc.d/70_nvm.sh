# shellcheck shell=bash disable=SC1091
# Depends on NVM_DIR from 25_xdg-tool-paths.sh, sourced ahead of this file.
if [ -f "/usr/share/nvm/init-nvm.sh" ]; then
    # The package's init script creates $NVM_DIR and its symlinks with
    # mkdir -v / ln -v the first time it runs for a user, and that chatter
    # would otherwise land in the dev-update journal, which sources this file
    # through run-dev-update. Only stdout is discarded, so a real failure to
    # create them still reaches stderr.
    # shellcheck source=/dev/null
    . /usr/share/nvm/init-nvm.sh >/dev/null
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" # This loads nvm
[[ $- == *i* ]] && [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" # This loads nvm bash_completion

export NODE_OPTIONS="--max-old-space-size=16384"
