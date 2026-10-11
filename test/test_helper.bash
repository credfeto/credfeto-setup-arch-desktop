#!/usr/bin/env bash
# Shared helpers for the bats suites covering settings/scripts/ and the
# install.d/ mechanism that deploys them.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Consumed by the .bats files that `load test_helper`, not by this file
# itself, so shellcheck's single-file analysis can't see the use.
# shellcheck disable=SC2034
SCRIPTS_DIR="${REPO_DIR}/settings/scripts"
SECTIONS_DIR="${REPO_DIR}/settings/bash.bashrc.d"

# Creates fake executables on a PATH prefix, so a script under test invokes
# the fakes instead of real system tools. Each fake logs its own name plus
# arguments to $FAKE_BIN_LOG, echoes back any canned output seeded via
# seed_fake_output, and exits 0 unless FAKE_EXIT_<tool> overrides it.
#
# Usage: setup_fake_bin <tool-name> [<tool-name> ...]
setup_fake_bin() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    FAKE_BIN_OUTPUT_DIR="${BATS_TEST_TMPDIR}/fakebin-output"
    mkdir -p "${FAKE_BIN_DIR}" "${FAKE_BIN_OUTPUT_DIR}"
    : > "${FAKE_BIN_LOG}"

    local _tool _varname
    for _tool in "$@"; do
        # Tool names may contain hyphens (e.g. update-dotnet-sdk), which are
        # not valid in a bash variable name - sanitised to underscores for
        # the FAKE_EXIT_<tool> override lookup below.
        _varname="FAKE_EXIT_${_tool//-/_}"
        cat > "${FAKE_BIN_DIR}/${_tool}" <<EOF
#!/bin/sh
printf '%s %s\n' "${_tool}" "\$*" >> "${FAKE_BIN_LOG}"
if [ -f "${FAKE_BIN_OUTPUT_DIR}/${_tool}" ]; then
    cat "${FAKE_BIN_OUTPUT_DIR}/${_tool}"
fi
exit "\${${_varname}:-0}"
EOF
        chmod +x "${FAKE_BIN_DIR}/${_tool}"
    done

    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

# Creates the fakes setup_fake_bin would, plus a fake sudo that never runs
# the command it wraps: it logs "sudo <command line>" to $FAKE_BIN_LOG, then
# exits 1 when that command line matches the grep -E pattern in
# $FAKE_SUDO_FAIL (read when sudo runs, so a test sets it before the run) and
# 0 otherwise. Lets an install.d/ script be run end to end, with exactly one
# privileged step failing, without real root or any change to the host.
#
# Usage: setup_fake_sudo [<tool-name> ...]
setup_fake_sudo() {
    setup_fake_bin "$@"
    cat > "${FAKE_BIN_DIR}/sudo" <<EOF
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ -n "\${FAKE_SUDO_FAIL:-}" ] && printf '%s\n' "\$*" | grep -qE "\${FAKE_SUDO_FAIL}"; then
    exit 1
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/sudo"
}

# Replaces a fake created by setup_fake_bin with a script read from stdin,
# for a tool whose fake has to do more than log and echo canned output.
# Usage: replace_fake <tool-name> <<'EOF' ... EOF
replace_fake() {
    cat > "${FAKE_BIN_DIR}/$1"
    chmod +x "${FAKE_BIN_DIR}/$1"
}

# Seeds canned stdout for a fake tool created by setup_fake_bin.
# Usage: seed_fake_output <tool-name> <<< "canned output"
seed_fake_output() {
    cat > "${FAKE_BIN_OUTPUT_DIR}/$1"
}

# Asserts the fake invocation log contains a line matching the given
# grep -E pattern.
assert_fake_called() {
    grep -qE "$1" "${FAKE_BIN_LOG}"
}

# Asserts the fake invocation log does NOT contain a line matching the
# given grep -E pattern.
refute_fake_called() {
    ! grep -qE "$1" "${FAKE_BIN_LOG}"
}

# Asserts each dev-update unit in the user unit directory is a symlink that
# resolves to the same unit under the given directory.
# Usage: assert_dev_update_units_linked_to <units-dir>
assert_dev_update_units_linked_to() {
    local _unit _link
    for _unit in dev-update.service dev-update.timer; do
        _link="${HOME}/.config/systemd/user/${_unit}"
        [ -L "${_link}" ] || return 1
        [ "$(readlink -f "${_link}")" = "$(readlink -f "$1/${_unit}")" ] || return 1
    done
}

# Runs a command with the caller's tool settings cleared and a minimal PATH,
# so the nvm, Go, bun or dotnet setup of whoever runs the suite cannot leak
# into what the code under test produces. LINUX_DISTRIBUTION is cleared too:
# a shell that has loaded 00_shell-options.sh exports it, and 85_pacman.sh
# does nothing without it. The XDG base directories are set to where
# 20_xdg-dirs.sh puts them, under HOME, rather than left as the caller has
# them: tools place their own directories from these (70_nvm.sh puts
# NVM_DIR under XDG_CONFIG_HOME), so the caller's values would send what the
# code under test creates to the real ~/.config of whoever runs the suite.
# HOME must therefore already be the test's own, and the command is not run
# when it is not. Leading VAR=value arguments are applied after all of this
# (env reads them), so a test can start from another PATH, or give a tool
# variable a known value, without repeating the list.
# Usage: run_with_clean_tool_env [<VAR=value> ...] <command> [<arg> ...]
run_with_clean_tool_env() {
    if [[ "${HOME}" != "${BATS_TEST_TMPDIR}"/* ]]; then
        echo "run_with_clean_tool_env: HOME (${HOME}) is not under the test's temporary directory" >&2
        return 1
    fi
    env -u NVM_DIR -u GOPATH -u BUN_INSTALL -u DOTNET_NOLOGO -u DOTNET_ROOT -u LINUX_DISTRIBUTION \
        XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share" \
        XDG_STATE_HOME="${HOME}/.local/state" XDG_CACHE_HOME="${HOME}/.cache" \
        PATH=/usr/bin:/bin "$@"
}

# Runs the given script in bash with the bash.bashrc.d directory as $1, in an
# interactive shell (as /etc/bash.bashrc sources the sections) or in a
# non-interactive one (as run-dev-update does). Either kind starts from
# run_with_clean_tool_env's environment, so every suite means the same thing
# by "non-interactive"; leading VAR=value arguments are passed on to it.
# --norc and --noprofile keep the host's deployed /etc/bash.bashrc.d out of
# the shell, and +m stops it taking over a terminal for job control. Stdin is
# /dev/null, so the shell has no terminal, and an interactive run's stderr
# cannot be asserted empty: an interactive bash with no terminal warns there
# that it has no job control. Any further arguments reach the script as $2
# onwards. Leaves stdout in $output and stderr in $stderr.
# Usage: run_section_shell [<VAR=value> ...] interactive|non-interactive <script> [<arg> ...]
run_section_shell() {
    local -a _env=() _flags=(--norc --noprofile +m)
    while [[ "$1" == *=* ]]; do
        _env+=("$1")
        shift
    done
    local _mode="$1" _script="$2"
    shift 2
    case "${_mode}" in
        interactive) _flags+=(-i) ;;
        non-interactive) ;;
        *)
            echo "run_section_shell: unknown mode '${_mode}'" >&2
            return 1
            ;;
    esac
    run --separate-stderr run_with_clean_tool_env "${_env[@]}" bash "${_flags[@]}" -c "${_script}" _ "${SECTIONS_DIR}" "$@" < /dev/null
}

# Writes a stand-in for nvm into the given directory: an nvm.sh that adds the
# given label to ${BATS_TEST_TMPDIR}/nvm-loads each time it is sourced, and a
# bash_completion that leaves the label in nvm_completion_loaded.
# Usage: write_fake_nvm <dir> <label>
write_fake_nvm() {
    mkdir -p "$1"
    printf 'echo %s >> "%s"\n' "$2" "${BATS_TEST_TMPDIR}/nvm-loads" > "$1/nvm.sh"
    printf 'nvm_completion_loaded=%s\n' "$2" > "$1/bash_completion"
}

# Creates a stand-in for the nvm package's directory, labelled "package", and
# prints its path.
setup_fake_nvm_package() {
    local _package="${BATS_TEST_TMPDIR}/nvm-package"
    write_fake_nvm "${_package}" package
    : > "${_package}/nvm-exec"
    printf '%s\n' "${_package}"
}

# Writes a copy of 70_nvm.sh that looks for the nvm package in the given
# directory wherever the section names /usr/share/nvm, so a test decides
# whether the package is there and what it holds. The section itself has no
# way to be pointed at another directory, and needs none. Prints the copy's
# path.
# Usage: nvm_section_reading <package-dir>
nvm_section_reading() {
    local _copy="${BATS_TEST_TMPDIR}/nvm-sections/70_nvm.sh"
    mkdir -p "${_copy%/*}"
    sed "s|/usr/share/nvm|$1|g" "${SECTIONS_DIR}/70_nvm.sh" > "${_copy}"
    # The existence test, both loads and both links moved, and nothing still
    # names the real package.
    grep -q -F "[ -f $1/nvm.sh ]" "${_copy}" || return 1
    grep -q -F ". $1/nvm.sh" "${_copy}" || return 1
    grep -q -F ". $1/bash_completion" "${_copy}" || return 1
    grep -q -F "ln -sf $1/nvm.sh " "${_copy}" || return 1
    grep -q -F "ln -sf $1/nvm-exec " "${_copy}" || return 1
    ! grep -q -F /usr/share/nvm "${_copy}" || return 1
    printf '%s\n' "${_copy}"
}
