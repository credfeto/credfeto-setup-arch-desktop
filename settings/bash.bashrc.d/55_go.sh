# shellcheck shell=bash
# Depends on GOPATH from 25_xdg-tool-paths.sh and _bashrc_d_path_append from
# 45_path-helpers.sh, both sourced ahead of this file.
if command -v go &> /dev/null; then
    # go is only asked when GOPATH is not set, so the usual shell start and
    # timer run start no process here. It answers with GOPATH whenever that is
    # exported, so the entry is the same either way.
    _bashrc_d_path_append "${GOPATH:-$(go env GOPATH)}/bin"
fi
