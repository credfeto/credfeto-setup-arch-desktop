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

@test "dev-update.service is skipped when offline and runs dev-update from /usr/local/bin" {
    local _service="${DEV_UPDATE_UNITS}/dev-update.service"
    grep -qx 'Type=oneshot' "${_service}"
    grep -qx 'ExecCondition=/usr/local/bin/network-online' "${_service}"
    grep -qx 'ExecStart=/usr/local/bin/dev-update' "${_service}"
}

@test "dev-update units install symlinks both units into the user unit directory" {
    setup_fake_bin systemctl
    run "${DEV_UPDATE_UNITS}/install"
    [ "${status}" -eq 0 ]

    local _unit
    for _unit in dev-update.service dev-update.timer; do
        [ -L "${HOME}/.config/systemd/user/${_unit}" ]
        [ "$(readlink -f "${HOME}/.config/systemd/user/${_unit}")" = "$(readlink -f "${DEV_UPDATE_UNITS}/${_unit}")" ]
    done
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
