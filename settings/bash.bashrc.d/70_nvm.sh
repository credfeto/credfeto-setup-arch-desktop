# shellcheck shell=bash disable=SC1091
# Depends on NVM_DIR from 25_xdg-tool-paths.sh, sourced ahead of this file.
if [ -f "/usr/share/nvm/init-nvm.sh" ]; then
    # init-nvm.sh's first run echoes mkdir -v / ln -v; drop stdout so it stays
    # out of the dev-update journal, while real failures still reach stderr.
    # shellcheck source=/dev/null
    . /usr/share/nvm/init-nvm.sh >/dev/null
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" # This loads nvm
[[ $- == *i* ]] && [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" # This loads nvm bash_completion

export NODE_OPTIONS="--max-old-space-size=16384"
