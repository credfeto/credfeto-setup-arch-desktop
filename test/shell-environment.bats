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
