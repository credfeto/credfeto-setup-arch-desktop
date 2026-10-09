# shellcheck shell=bash
# Depends on GOPATH from 25_xdg-tool-paths.sh, sourced ahead of this file.
if command -v go > /dev/null 2>&1; then
    GOPATH_BIN="$(go env GOPATH)/bin"
    export PATH="$PATH:$GOPATH_BIN"
fi
