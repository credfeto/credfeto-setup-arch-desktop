# shellcheck shell=sh
# Sourced from both /etc/profile.d and /etc/bash.bashrc.d - keep POSIX-safe.

# Guarded on XDG_RUNTIME_DIR being set - it isn't in every context (e.g.
# `sudo -s`, some cron/service contexts); without the guard these would all
# resolve to the empty string, which is worse than leaving them unset.
if [ -n "$XDG_RUNTIME_DIR" ]; then
    [ -z "$TMP" ] && export TMP="$XDG_RUNTIME_DIR"
    [ -z "$TMPDIR" ] && export TMPDIR="$XDG_RUNTIME_DIR"
    [ -z "$TEMP" ] && export TEMP="$XDG_RUNTIME_DIR"
    [ -z "$TEMPDIR" ] && export TEMPDIR="$XDG_RUNTIME_DIR"
    [ -z "$CLAUDE_CODE_TMPDIR" ] && export CLAUDE_CODE_TMPDIR="$XDG_RUNTIME_DIR"
fi
