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

@test "dev-update.service is skipped when offline and runs run-dev-update from the reference clone through a login shell" {
    local _service="${DEV_UPDATE_UNITS}/dev-update.service"
    grep -qx 'Type=oneshot' "${_service}"
    grep -qx 'ExecCondition=%h/work/reference/credfeto-setup-arch-desktop/settings/scripts/linux/network-online' "${_service}"
    # A login shell reads /etc/profile, and so /etc/profile.d, which the user
    # manager does not; run-dev-update adds the bash.bashrc.d settings.
    grep -qx 'ExecStart=/bin/sh -lc %h/work/reference/credfeto-setup-arch-desktop/units/dev-update/run-dev-update' "${_service}"
    [ "$(grep -c '^ExecCondition=' "${_service}")" -eq 1 ]
    [ "$(grep -c '^ExecStart=' "${_service}")" -eq 1 ]
}

@test "dev-update.service points SSH_AUTH_SOCK at the user ssh-agent socket" {
    grep -qx 'Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket' "${DEV_UPDATE_UNITS}/dev-update.service"
}

# Copies run-dev-update and the bash.bashrc.d sections it sources into a
# clone-shaped tree under the test dir, with a stub dev-update that records
# the environment it was started with and exits 3, so the real dev-update
# never runs. Prints the path of the copied run-dev-update.
setup_run_dev_update_tree() {
    local _root="${BATS_TEST_TMPDIR}/clone"
    mkdir -p "${_root}/units/dev-update" "${_root}/settings/bash.bashrc.d" "${_root}/settings/scripts/linux"
    cp "${DEV_UPDATE_UNITS}/run-dev-update" "${_root}/units/dev-update/"
    cp "${REPO_DIR}/settings/bash.bashrc.d/50_paths.sh" "${REPO_DIR}/settings/bash.bashrc.d/60_dotnet.sh" "${_root}/settings/bash.bashrc.d/"
    cat > "${_root}/settings/scripts/linux/dev-update" <<EOF
#!/bin/sh
{
    printf 'PATH=%s\n' "\${PATH}"
    printf 'DOTNET_NOLOGO=%s\n' "\${DOTNET_NOLOGO:-}"
    printf 'DOTNET_ROOT=%s\n' "\${DOTNET_ROOT:-}"
} > "${BATS_TEST_TMPDIR}/dev-update.env"
exit 3
EOF
    chmod +x "${_root}/settings/scripts/linux/dev-update"
    printf '%s\n' "${_root}/units/dev-update/run-dev-update"
}

@test "run-dev-update starts dev-update with the PATH and dotnet settings from bash.bashrc.d, passing on its exit status" {
    local _run _env="${BATS_TEST_TMPDIR}/dev-update.env"
    _run="$(setup_run_dev_update_tree)"
    run env -u DOTNET_NOLOGO -u DOTNET_ROOT PATH=/usr/bin:/bin "${_run}"
    [ "${status}" -eq 3 ]
    grep -qx "PATH=/usr/bin:/bin.*:${HOME}/.local/bin:${HOME}/.cargo/bin.*" "${_env}"
    grep -qx 'DOTNET_NOLOGO=true' "${_env}"
    if [ -d /usr/share/dotnet ]; then
        grep -qx 'DOTNET_ROOT=/usr/share/dotnet' "${_env}"
        grep -q '^PATH=.*:/usr/share/dotnet$' "${_env}"
    fi
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
