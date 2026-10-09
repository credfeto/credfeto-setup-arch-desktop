#!/usr/bin/env bats
# Regression tests for how install.d/shell-environment deploys its files.
# The script runs end to end against the fake sudo from test_helper, which
# logs each privileged command line and never runs it, so the deployments are
# asserted from that log without touching /etc/profile.d or
# /etc/bash.bashrc.d on the host.

bats_require_minimum_version 1.5.0

load test_helper

SHELL_ENVIRONMENT="${REPO_DIR}/install.d/shell-environment"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
}

# Runs shell-environment against the fake sudo, then writes every file
# deployment it made (each `install` other than the directory creation) to
# ${BATS_TEST_TMPDIR}/deployments, one "<mode> <source> <target>" line each.
run_shell_environment() {
    setup_fake_sudo pacman
    run "${SHELL_ENVIRONMENT}"
    [ "${status}" -eq 0 ]
    grep '^sudo install ' "${FAKE_BIN_LOG}" | grep -v '^sudo install -d ' | sed -E 's/^sudo install -m ([^ ]+) /\1 /' > "${BATS_TEST_TMPDIR}/deployments"
}

# Prints the "<source> <target>" pair every file in settings/<dir> must be
# deployed as, once for each target directory given.
# Usage: expected_deployments <dir> <target-dir> [<target-dir> ...]
expected_deployments() {
    local _dir="$1" _source _target
    shift
    for _source in "${REPO_DIR}/settings/${_dir}"/*; do
        for _target in "$@"; do
            printf '%s %s\n' "${_source}" "${_target}/$(basename "${_source}")"
        done
    done
}

@test "shell-environment deploys no file with cp" {
    # cp gives the destination the *source* file's mode when the destination
    # does not already exist. The working tree is checked out under the
    # user's umask (027 for the reporter), so every deployed file landed as
    # 0640 root:root and no ordinary user could source it. install -m sets
    # the mode explicitly instead, independent of both the checkout mode and
    # of whether the destination happened to exist.
    run ! grep -q 'sudo cp ' "${SHELL_ENVIRONMENT}"
}

@test "shell-environment deploys every file world-readable, with an explicit mode" {
    # 0644, not the 0640 these files used to land as: /etc/profile.d and
    # /etc/bash.bashrc.d are sourced by every user's shell, not just root's.
    run_shell_environment
    [ -s "${BATS_TEST_TMPDIR}/deployments" ]
    run ! grep -vE '^0644 [^ ]+ [^ ]+$' "${BATS_TEST_TMPDIR}/deployments"
}

@test "shell-environment deploys exactly the files under settings/shell-env and settings/bash.bashrc.d, each to its tier" {
    # Compared against the directory listings, so a file added to either
    # directory is deployed without editing the script, and nothing else is.
    run_shell_environment
    expected="$(
        {
            expected_deployments shell-env /etc/profile.d /etc/bash.bashrc.d
            expected_deployments bash.bashrc.d /etc/bash.bashrc.d
        } | sort
    )"
    actual="$(cut -d' ' -f2- "${BATS_TEST_TMPDIR}/deployments" | sort)"
    [ "${actual}" = "${expected}" ]
}

# ── update ───────────────────────────────────────────────────────────────────
# Only the install-selection helper is exercised: update() itself runs the
# real system package manager.

# Creates a stub install script under $HOME/work/<tree> that echoes which
# tree it came from.
make_setup_install() {
    local _dir="${HOME}/work/$1/credfeto-setup-arch-desktop"
    mkdir -p "${_dir}"
    printf '#!/bin/sh\necho "%s install ran"\n' "$1" > "${_dir}/install"
    chmod +x "${_dir}/install"
}

run_update_setup_install() {
    # shellcheck source=../settings/bash.bashrc.d/95_update.sh disable=SC1091
    source "${REPO_DIR}/settings/bash.bashrc.d/95_update.sh"
    run _update_setup_arch_desktop
}

@test "update runs the reference clone's install when it exists" {
    make_setup_install reference
    make_setup_install personal

    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ "${output}" = "reference install ran" ]
}

@test "update falls back to the personal checkout's install without a reference clone" {
    make_setup_install personal

    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ "${output}" = "personal install ran" ]
}

@test "update runs no install when neither checkout exists" {
    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# ── interactive-only bash.bashrc.d sections ─────────────────────────────────
# /etc/bash.bashrc sources bash.bashrc.d in interactive shells, and
# run-dev-update sources it non-interactively, so each interactive-only part
# is checked in both kinds of shell.

SECTIONS_DIR="${REPO_DIR}/settings/bash.bashrc.d"

# Runs the given script in bash with the bash.bashrc.d directory as $1, in an
# interactive shell when the first argument is "interactive". --norc and
# --noprofile keep the host's deployed /etc/bash.bashrc.d out of the shell,
# and +m stops it taking over a terminal for job control. Only stdout is
# asserted: with no terminal, an interactive bash and bind warn on stderr.
# Usage: run_section_shell interactive|non-interactive <script>
run_section_shell() {
    local _mode="$1" _script="$2"
    local -a _flags=(--norc --noprofile +m)
    if [ "${_mode}" = interactive ]; then
        _flags+=(-i)
    fi
    run --separate-stderr bash "${_flags[@]}" -c "${_script}" _ "${SECTIONS_DIR}" < /dev/null
}

# Clears the settings 00_shell-options.sh turns on and gives PROMPT_COMMAND an
# existing hook, sources the section, then prints what it left behind.
# shellcheck disable=SC2016
SHELL_OPTIONS_SCRIPT='
shopt -u checkwinsize histappend
PROMPT_COMMAND=(existing_hook)
. "$1/00_shell-options.sh"
shopt -q checkwinsize && echo checkwinsize
shopt -q histappend && echo histappend
printf "PROMPT_COMMAND=%s\n" "${PROMPT_COMMAND[@]}"
'

@test "00_shell-options.sh in an interactive shell sets the window and history options, appends to PROMPT_COMMAND and frees ctrl-S" {
    setup_fake_bin stty
    run_section_shell interactive "${SHELL_OPTIONS_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'checkwinsize\nhistappend\nPROMPT_COMMAND=existing_hook\nPROMPT_COMMAND=history -a' ]
    assert_fake_called '^stty -ixon$'
}

@test "00_shell-options.sh in a non-interactive shell leaves the shell options, PROMPT_COMMAND and the terminal alone" {
    setup_fake_bin stty
    run_section_shell non-interactive "${SHELL_OPTIONS_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'PROMPT_COMMAND=existing_hook' ]
    refute_fake_called '^stty'
}

@test "40_bash-completion.sh loads bash-completion only in an interactive shell" {
    [ -f /usr/share/bash-completion/bash_completion ] || [ -f /etc/bash_completion ] || skip "bash-completion not installed"
    # bash-completion installs a default (-D) completion; bash has none
    # without it.
    # shellcheck disable=SC2016
    run_section_shell interactive '. "$1/40_bash-completion.sh"; complete -p -D'
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
    # shellcheck disable=SC2016
    run_section_shell non-interactive '. "$1/40_bash-completion.sh"; complete -p -D'
    [ "${status}" -ne 0 ]
}

@test "70_nvm.sh loads nvm's bash completion only in an interactive shell" {
    export NVM_DIR="${BATS_TEST_TMPDIR}/nvm"
    mkdir -p "${NVM_DIR}"
    echo 'nvm_completion_loaded=yes' > "${NVM_DIR}/bash_completion"
    # shellcheck disable=SC2016
    local _script='. "$1/70_nvm.sh"; echo "nvm_completion_loaded=${nvm_completion_loaded:-no}"'
    run_section_shell interactive "${_script}"
    [ "${output}" = 'nvm_completion_loaded=yes' ]
    run_section_shell non-interactive "${_script}"
    [ "${output}" = 'nvm_completion_loaded=no' ]
}

@test "78_socket-cli.sh registers socket's completion only in an interactive shell" {
    local _completion_dir="${HOME}/.local/share/socket/completion"
    mkdir -p "${_completion_dir}"
    echo '_socket_completion() { :; }' > "${_completion_dir}/socket-completion.bash"
    # shellcheck disable=SC2016
    run_section_shell interactive '. "$1/78_socket-cli.sh"; complete -p socket'
    [ "${status}" -eq 0 ]
    [ "${output}" = 'complete -F _socket_completion socket' ]
    # shellcheck disable=SC2016
    run_section_shell non-interactive '. "$1/78_socket-cli.sh"; complete -p socket'
    [ "${status}" -ne 0 ]
}
