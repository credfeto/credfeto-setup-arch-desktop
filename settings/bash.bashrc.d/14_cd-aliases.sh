# shellcheck shell=bash
# Change-directory-up aliases: N dots = N-1 directories up, extending the
# original 2-5 dot set up to 10 dots / 9 levels (raise the 10 below if you
# need to go further). Each depth gets both a dots-only alias (the common
# convention) and a "cd"-prefixed alias (matching the original cd.. alias).
# The dots are built by appending, not with $(seq ...), so sourcing this
# forks nothing.
_cd_up_dots=".."
_cd_up_path=".."
while [ "${#_cd_up_dots}" -le 10 ]; do
    # shellcheck disable=SC2139
    alias "$_cd_up_dots"="cd $_cd_up_path"
    # shellcheck disable=SC2139
    alias "cd$_cd_up_dots"="cd $_cd_up_path"
    _cd_up_dots="$_cd_up_dots."
    _cd_up_path="../$_cd_up_path"
done
unset _cd_up_path _cd_up_dots
