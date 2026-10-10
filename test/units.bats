#!/usr/bin/env bats
# Tests for the systemd units under units/ and their installers.

bats_require_minimum_version 1.5.0

load test_helper

DEV_UPDATE_UNITS="${REPO_DIR}/units/dev-update"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # Keeps the symlinks inside the test tree rather than the real user
    # unit directory.
    unset XDG_CONFIG_HOME
}

# ── dev-update units ─────────────────────────────────────────────────────────

@test "dev-update.timer fires shortly after startup, then every 30 minutes with jitter" {
    local _timer="${DEV_UPDATE_UNITS}/dev-update.timer"
    grep -qx 'OnStartupSec=15s' "${_timer}"
    grep -qx 'OnUnitActiveSec=30min' "${_timer}"
    grep -qx 'RandomizedDelaySec=5min' "${_timer}"
    grep -qx 'WantedBy=timers.target' "${_timer}"
}

@test "dev-update.timer has no Persistent= setting, which only applies to OnCalendar=" {
    run ! grep -q '^Persistent=' "${DEV_UPDATE_UNITS}/dev-update.timer"
}

@test "dev-update.service is skipped when offline and runs run-dev-update from the reference clone through a POSIX login shell" {
    local _service="${DEV_UPDATE_UNITS}/dev-update.service"
    grep -qx 'Type=oneshot' "${_service}"
    grep -qx 'ExecCondition=%h/work/reference/credfeto-setup-arch-desktop/settings/scripts/linux/network-online' "${_service}"
    # Why /bin/sh and not bash: see the comment above ExecStart.
    grep -qx 'ExecStart=/bin/sh -lc %h/work/reference/credfeto-setup-arch-desktop/units/dev-update/run-dev-update' "${_service}"
    [ "$(grep -c '^ExecCondition=' "${_service}")" -eq 1 ]
    [ "$(grep -c '^ExecStart=' "${_service}")" -eq 1 ]
}

@test "dev-update.service points SSH_AUTH_SOCK at the user ssh-agent socket" {
    grep -qx 'Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket' "${DEV_UPDATE_UNITS}/dev-update.service"
}

# Runs a command with the caller's tool settings cleared and a minimal PATH,
# so the nvm, Go, bun or dotnet setup of whoever runs the suite cannot leak
# into what the sections under test produce.
run_with_clean_tool_env() {
    env -u NVM_DIR -u GOPATH -u BUN_INSTALL -u DOTNET_NOLOGO -u DOTNET_ROOT PATH=/usr/bin:/bin "$@"
}

# Copies run-dev-update, the lib/common it reports errors through and every
# bash.bashrc.d section it sources into a clone-shaped tree under the test
# dir, with a stub dev-update that records the environment it was started with
# and exits 3, so the real dev-update never runs. Prints the path of the
# copied run-dev-update.
setup_run_dev_update_tree() {
    local _root="${BATS_TEST_TMPDIR}/clone"
    mkdir -p "${_root}/units/dev-update" "${_root}/settings/scripts/linux" "${_root}/lib"
    cp "${DEV_UPDATE_UNITS}/run-dev-update" "${_root}/units/dev-update/"
    cp "${REPO_DIR}/lib/common" "${_root}/lib/"
    cp -r "${REPO_DIR}/settings/bash.bashrc.d" "${_root}/settings/"
    cat > "${_root}/settings/scripts/linux/dev-update" <<EOF
#!/bin/sh
{
    printf 'PATH=%s\n' "\${PATH}"
    printf 'DOTNET_NOLOGO=%s\n' "\${DOTNET_NOLOGO:-}"
    printf 'DOTNET_ROOT=%s\n' "\${DOTNET_ROOT:-}"
    printf 'NVM_DIR=%s\n' "\${NVM_DIR:-}"
} > "${BATS_TEST_TMPDIR}/dev-update.env"
exit 3
EOF
    chmod +x "${_root}/settings/scripts/linux/dev-update"
    printf '%s\n' "${_root}/units/dev-update/run-dev-update"
}

# Succeeds when the PATH recorded by the stub dev-update has the given entry.
recorded_path_has() {
    local _path
    _path="$(sed -n 's/^PATH=//p' "${BATS_TEST_TMPDIR}/dev-update.env")"
    [[ ":${_path}:" == *":$1:"* ]]
}

@test "run-dev-update starts dev-update with the tool settings from every bash.bashrc.d section, silently, passing on its exit status" {
    local _run _env="${BATS_TEST_TMPDIR}/dev-update.env" _gopath
    _run="$(setup_run_dev_update_tree)"
    mkdir -p "${HOME}/.bun/bin"
    run --separate-stderr run_with_clean_tool_env "${_run}" < /dev/null
    [ "${status}" -eq 3 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    recorded_path_has /usr/bin
    recorded_path_has "${HOME}/.local/bin"
    recorded_path_has "${HOME}/.cargo/bin"
    grep -qx "PATH=${HOME}/.bun/bin:.*" "${_env}"
    grep -qx 'DOTNET_NOLOGO=true' "${_env}"
    if [ -d /usr/share/dotnet ]; then
        grep -qx 'DOTNET_ROOT=/usr/share/dotnet' "${_env}"
        recorded_path_has /usr/share/dotnet
    fi
    if [ -x /usr/bin/go ]; then
        _gopath="$(run_with_clean_tool_env go env GOPATH)"
        recorded_path_has "${_gopath}/bin"
    fi
    if [ -f /usr/share/nvm/init-nvm.sh ]; then
        grep -qx "NVM_DIR=${HOME}/.nvm" "${_env}"
    fi
}

@test "run-dev-update fails without starting dev-update when bash.bashrc.d holds no sections or is missing" {
    local _run _sections="${BATS_TEST_TMPDIR}/clone/settings/bash.bashrc.d" _state
    _run="$(setup_run_dev_update_tree)"
    rm "${_sections}"/*.sh
    for _state in empty missing; do
        run --separate-stderr run_with_clean_tool_env "${_run}" < /dev/null
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"No bash.bashrc.d sections found in ${_sections}"* ]]
        [ ! -e "${BATS_TEST_TMPDIR}/dev-update.env" ]
        # The second pass runs with the directory gone.
        [ "${_state}" = missing ] || rmdir "${_sections}"
    done
    [ ! -e "${_sections}" ]
}

@test "run-dev-update fails without starting dev-update when lib/common is missing" {
    local _run
    _run="$(setup_run_dev_update_tree)"
    rm "${BATS_TEST_TMPDIR}/clone/lib/common"
    run --separate-stderr run_with_clean_tool_env "${_run}" < /dev/null
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"lib/common"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/dev-update.env" ]
}

# Sources one bash.bashrc.d section the way run-dev-update does: in a
# non-interactive bash with no terminal and the caller's tool settings
# cleared. Leaves stdout in $output and stderr in $stderr.
# Usage: run_section_non_interactively <section-path>
run_section_non_interactively() {
    # shellcheck disable=SC2016
    run --separate-stderr run_with_clean_tool_env bash -c '. "$1"' _ "$1" < /dev/null
}

@test "every bash.bashrc.d section writes nothing to stdout or stderr when sourced by a non-interactive bash" {
    local _section _offenders=""
    for _section in "${REPO_DIR}"/settings/bash.bashrc.d/*.sh; do
        run_section_non_interactively "${_section}"
        if [ -n "${output}" ] || [ -n "${stderr}" ]; then
            _offenders+="${_section##*/}: ${output}${stderr}"$'\n'
        fi
    done
    printf '%s' "${_offenders}"
    [ -z "${_offenders}" ]
}

@test "70_nvm.sh sets up nvm silently on a home that has no NVM_DIR yet" {
    [ -f /usr/share/nvm/init-nvm.sh ] || skip "nvm package not installed"
    run_section_non_interactively "${REPO_DIR}/settings/bash.bashrc.d/70_nvm.sh"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    # Proves the first-use setup ran, so the silence above is not vacuous.
    [ -L "${HOME}/.nvm/nvm.sh" ]
}

@test "70_nvm.sh still reports a failure to set up NVM_DIR on stderr" {
    [ -f /usr/share/nvm/init-nvm.sh ] || skip "nvm package not installed"
    # A regular file where NVM_DIR should be makes the symlinks fail.
    : > "${HOME}/.nvm"
    run_section_non_interactively "${REPO_DIR}/settings/bash.bashrc.d/70_nvm.sh"
    [ -z "${output}" ]
    [[ "${stderr}" == *"${HOME}/.nvm/nvm.sh"* ]]
}

@test "dev-update units install symlinks both units into the user unit directory" {
    setup_fake_bin systemctl
    run "${DEV_UPDATE_UNITS}/install"
    [ "${status}" -eq 0 ]

    assert_dev_update_units_linked_to "${DEV_UPDATE_UNITS}"
}

@test "dev-update units install replaces an existing unit file with the symlink" {
    setup_fake_bin systemctl
    mkdir -p "${HOME}/.config/systemd/user"
    printf 'stale\n' > "${HOME}/.config/systemd/user/dev-update.service"

    run "${DEV_UPDATE_UNITS}/install"
    [ "${status}" -eq 0 ]
    [ -L "${HOME}/.config/systemd/user/dev-update.service" ]
}

@test "dev-update units install reloads the user manager, then enables the timer" {
    setup_fake_bin systemctl
    run "${DEV_UPDATE_UNITS}/install"
    [ "${status}" -eq 0 ]
    expected="$(printf '%s\n' \
        'systemctl --user daemon-reload' \
        'systemctl --user enable dev-update.timer')"
    [ "$(cat "${FAKE_BIN_LOG}")" = "${expected}" ]
}

@test "dev-update units install dies if systemctl fails" {
    setup_fake_bin systemctl
    run env FAKE_EXIT_systemctl=1 "${DEV_UPDATE_UNITS}/install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to reload the user systemd manager"* ]]
}

# ── auto-update units ────────────────────────────────────────────────────────

@test "auto-update units install copies both units and enables the timer" {
    setup_fake_sudo
    run "${REPO_DIR}/units/auto-update/install"
    [ "${status}" -eq 0 ]
    assert_fake_called '^sudo cp .*/auto-update\.timer /etc/systemd/system/auto-update\.timer$'
    assert_fake_called '^sudo systemctl enable --now auto-update\.timer$'
}

@test "auto-update units install fails, naming the step, when reloading systemd fails" {
    setup_fake_sudo
    export FAKE_SUDO_FAIL='^systemctl daemon-reload'
    run "${REPO_DIR}/units/auto-update/install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to reload the systemd manager"* ]]
    refute_fake_called 'enable --now auto-update\.timer'
}
