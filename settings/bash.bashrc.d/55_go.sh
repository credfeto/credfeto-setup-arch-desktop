# shellcheck shell=bash
# Depends on GOPATH from 25_xdg-tool-paths.sh and _bashrc_d_path_append from
# 45_path-helpers.sh, both sourced ahead of this file.
if command -v go &> /dev/null; then
    _bashrc_d_path_append "$(go env GOPATH)/bin"
fi
