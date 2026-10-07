# shellcheck shell=bash disable=SC1091
# Depends on NVM_DIR from 25_xdg-tool-paths.sh, sourced ahead of this file.
if [ -f "/usr/share/nvm/init-nvm.sh" ]; then
    # shellcheck source=/dev/null
    . /usr/share/nvm/init-nvm.sh
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" # This loads nvm bash_completion

export NODE_OPTIONS="--max-old-space-size=16384"
