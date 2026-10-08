#!/usr/bin/env bats
# Regression tests for install's step loop. install runs from a copy in a
# temp tree whose install.d/ holds logging stubs named after the real steps:
# the real steps mutate system state (pacman, sshd, sysctl, ...) and are
# exercised individually by their own bats suites instead.

load test_helper

# The order install must run its steps in.
EXPECTED_STEPS=(
    remove-aur-helpers
    disable-baloo
    harden-system
    pacman-hooks
    configure-pacman
    security-tools
    dash
    configure-network
    harden-ssh
    btrfs-scrub
    firejail
    fail2ban
    enable-services
    shell-prompt
    shell-environment
    configure-flatpak
    git-environment
    dev-scripts
)

# Copies install and lib/common into a temp tree and gives it a logging stub
# for every executable under the real install.d/. Each stub logs its name to
# STEP_LOG and exits 1 when its name is in FAILING_STEP, 0 otherwise. id
# and systemctl are faked as a normal user with a reachable systemd user
# manager, so the session preflight never depends on the host running the
# tests; a test overrides the uid or fails the probe to exercise it.
setup() {
    INSTALL_TREE="${BATS_TEST_TMPDIR}/tree"
    STEP_LOG="${BATS_TEST_TMPDIR}/steps.log"
    mkdir -p "${INSTALL_TREE}/install.d" "${INSTALL_TREE}/lib"
    cp "${REPO_DIR}/install" "${INSTALL_TREE}/install"
    cp "${REPO_DIR}/lib/common" "${INSTALL_TREE}/lib/common"
    : > "${STEP_LOG}"

    setup_fake_bin id systemctl
    seed_fake_output id <<< "1000"

    local _step _name
    for _step in "${REPO_DIR}"/install.d/*; do
        [ -f "${_step}" ] && [ -x "${_step}" ] || continue
        _name="$(basename "${_step}")"
        cat > "${INSTALL_TREE}/install.d/${_name}" <<EOF
#!/bin/sh
printf '%s\n' "${_name}" >> "${STEP_LOG}"
[ "\${FAILING_STEP:-}" != "${_name}" ]
EOF
        chmod +x "${INSTALL_TREE}/install.d/${_name}"
    done
}

@test "install runs every script present under install.d/, once each, in the expected order" {
    run "${INSTALL_TREE}/install"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Done"* ]]
    assert_fake_called '^systemctl --user show-environment$'

    # Every executable under install.d/ is an expected step, so a new script
    # cannot be added without deciding where it runs.
    local _step
    for _step in "${INSTALL_TREE}"/install.d/*; do
        printf '%s\n' "${EXPECTED_STEPS[@]}" | grep -qxF "$(basename "${_step}")"
    done
    [ "$(cat "${STEP_LOG}")" = "$(printf '%s\n' "${EXPECTED_STEPS[@]}")" ]
}

@test "install stops at a failed step, naming it, and runs nothing after it" {
    local _failing _index
    for _index in "${!EXPECTED_STEPS[@]}"; do
        _failing="${EXPECTED_STEPS[${_index}]}"
        : > "${STEP_LOG}"

        run env FAILING_STEP="${_failing}" "${INSTALL_TREE}/install"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"install.d/${_failing} failed"* ]]
        [[ "${output}" != *"Done"* ]]
        [ "$(cat "${STEP_LOG}")" = "$(printf '%s\n' "${EXPECTED_STEPS[@]:0:$((_index + 1))}")" ]
    done
}

@test "install dies as root, saying to run it as the normal user, before running any step" {
    seed_fake_output id <<< "0"

    run "${INSTALL_TREE}/install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"install must not be run as root; run it as your normal user, as it calls sudo itself"* ]]
    [[ "${output}" != *"Installing..."* ]]
    [[ "${output}" != *"Done"* ]]
    [ ! -s "${STEP_LOG}" ]
}

@test "install dies when the systemd user manager cannot be reached, saying to run it from a logged-in session, before running any step" {
    run env FAKE_EXIT_systemctl=1 "${INSTALL_TREE}/install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Cannot reach your systemd user manager; run install from a logged-in session"* ]]
    [[ "${output}" != *"Installing..."* ]]
    [[ "${output}" != *"Done"* ]]
    assert_fake_called '^systemctl --user show-environment$'
    [ ! -s "${STEP_LOG}" ]
}
