# shellcheck shell=bash
# Depends on GOPATH from 25_xdg-tool-paths.sh, sourced ahead of this file.
if command -v go &> /dev/null; then
    GOPATH_BIN="$(go env GOPATH)/bin"
    # Skipped when already there, so sourcing this again does not grow PATH.
    case ":$PATH:" in
        *":$GOPATH_BIN:"*) ;;
        *) export PATH="$PATH:$GOPATH_BIN" ;;
    esac
fi
