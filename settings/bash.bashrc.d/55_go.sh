# shellcheck shell=bash
# Depends on GOPATH from 25_xdg-tool-paths.sh and _bashrc_d_path_append from
# 45_path-helpers.sh, both sourced ahead of this file.
if command -v go &> /dev/null; then
    # go is only asked when GOPATH is not set, so the usual shell start and
    # timer run start no process here. It answers with GOPATH whenever that is
    # exported, so the entry is the same either way.
    _bashrc_d_gopath="${GOPATH:-$(go env GOPATH)}"
    # GOPATH is a colon-separated list, and go install writes to the bin
    # directory of its first entry.
    _bashrc_d_path_append "${_bashrc_d_gopath%%:*}/bin"
    unset _bashrc_d_gopath
fi
