#!/usr/bin/env bats
# End-to-end tests for the install.d/ steps that change system state. Every
# privileged step goes through the fake sudo from test_helper, which logs the
# command line and never runs it, and every command a step runs without sudo
# is a logging fake too, so nothing here touches the host. Each step is run
# once with every command succeeding, and once with a single step failing,
# which must stop the script, name the failed step and skip `success`.

bats_require_minimum_version 1.5.0

load test_helper

INSTALL_D="${REPO_DIR}/install.d"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # Empty, so every install-state flag in lib/common reads 0 unless a test
    # adds the binary it probes for.
    export INSTALL_STATE_BIN_DIR="${BATS_TEST_TMPDIR}/state-bin"
    mkdir -p "${INSTALL_STATE_BIN_DIR}"
    # Each test that needs a step to fail sets this for its own run only.
    unset FAKE_SUDO_FAIL
    setup_fake_sudo systemctl pacman flatpak balooctl6 hostnamectl aa-enforce
    seed_fake_output hostnamectl <<< "testhost"
}

# Marks a tool as installed for lib/common's install-state flags.
# Usage: mark_installed <binary-name>
mark_installed() {
    : > "${INSTALL_STATE_BIN_DIR}/$1"
}

# Runs install.d/<name> with the fakes in place. Any VAR=value arguments
# (e.g. FAKE_SUDO_FAIL, FAKE_EXIT_<tool>) are set for that run only, through
# env rather than export, so shellcheck does not flag a cross-@test
# modification (SC2030/SC2031).
# Usage: run_step <name> [VAR=value ...]
run_step() {
    local _step="$1"
    shift
    run env "$@" "${INSTALL_D}/${_step}"
}
