#!/usr/bin/env bats
# Tests for the NetworkManager dispatcher scripts under hooks/networkmanager/.

bats_require_minimum_version 1.5.0

load test_helper

TIMESYNCD_HOOK="${REPO_DIR}/hooks/networkmanager/10-update-timesyncd"
UUID="0b7a6c1e-3f2d-4e5a-9c8b-1d2e3f4a5b6c"

setup() {
    setup_fake_bin systemctl
    export TIMESYNCD_CONF_DIR="${BATS_TEST_TMPDIR}/timesyncd.conf.d"
    export TIMESYNCD_SYSTEMCTL="${FAKE_BIN_DIR}/systemctl"
    DROP_IN="${TIMESYNCD_CONF_DIR}/${UUID}.conf"
}

# Runs the hook as NetworkManager's dispatcher does: interface and action as
# arguments, connection details in the environment. Leading VAR=value
# arguments are added to that environment.
# Usage: run_timesyncd_hook [<VAR=value> ...] <action>
run_timesyncd_hook() {
    local -a _env=()
    while [[ "$1" == *=* ]]; do
        _env+=("$1")
        shift
    done
    run --separate-stderr env "${_env[@]}" "${TIMESYNCD_HOOK}" eth0 "$1"
}

# Succeeds when the configuration directory holds nothing but the given
# files, so a test sees any temporary file the hook left behind.
# Usage: assert_conf_dir_holds_only [<file-name> ...]
assert_conf_dir_holds_only() {
    [ "$(find "${TIMESYNCD_CONF_DIR}" -mindepth 1 -printf '%f\n' | sort)" = "$(printf '%s\n' "$@" | sed '/^$/d' | sort)" ]
}

# Writes a fake for a core tool the hook runs, read from stdin, into a
# directory of its own and sets HOOK_PATH to a PATH that finds it first. Kept
# off the suite's own PATH because bats itself runs tools such as mktemp and
# rm, and a fake there would break bats rather than the hook.
# Usage: fake_hook_tool <tool-name> <<'EOF' ... EOF
fake_hook_tool() {
    local _dir="${BATS_TEST_TMPDIR}/hook-bin"
    mkdir -p "${_dir}"
    write_fake_script "${_dir}/$1" "$1"
    HOOK_PATH="${_dir}:${PATH}"
}

fail_hook_tool() {
    fake_hook_tool "$1" <<'EOF'
#!/bin/sh
exit 1
EOF
}

seed_existing_drop_in() {
    mkdir -p "${TIMESYNCD_CONF_DIR}"
    printf '[Time]\nNTP=old.example.invalid\n' > "${DROP_IN}"
}

@test "10-update-timesyncd up writes the DHCP NTP servers to a drop-in and restarts timesyncd" {
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.1 10.0.0.2" up
    [ "${status}" -eq 0 ]
    [ "$(cat "${DROP_IN}")" = "$(printf '[Time]\nNTP=10.0.0.1 10.0.0.2')" ]
    assert_conf_dir_holds_only "${UUID}.conf"
    assert_fake_called '^systemctl restart systemd-timesyncd\.service$'
}

@test "10-update-timesyncd dhcp4-change replaces the drop-in with the new NTP servers" {
    seed_existing_drop_in
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.3" dhcp4-change
    [ "${status}" -eq 0 ]
    [ "$(cat "${DROP_IN}")" = "$(printf '[Time]\nNTP=10.0.0.3')" ]
    assert_conf_dir_holds_only "${UUID}.conf"
    assert_fake_called '^systemctl restart systemd-timesyncd\.service$'
}

@test "10-update-timesyncd makes the drop-in readable by everyone whatever the umask" {
    umask 077
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.1" up
    [ "${status}" -eq 0 ]
    [ "$(stat -c '%a' "${DROP_IN}")" = "644" ]
}

@test "10-update-timesyncd down removes the drop-in and restarts timesyncd" {
    seed_existing_drop_in
    run_timesyncd_hook CONNECTION_UUID="${UUID}" down
    [ "${status}" -eq 0 ]
    [ ! -e "${DROP_IN}" ]
    assert_fake_called '^systemctl restart systemd-timesyncd\.service$'
}

@test "10-update-timesyncd does nothing without a CONNECTION_UUID" {
    run_timesyncd_hook CONNECTION_UUID= DHCP4_NTP_SERVERS="10.0.0.1" up
    [ "${status}" -eq 0 ]
    [ ! -e "${TIMESYNCD_CONF_DIR}" ]
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd does nothing on up when DHCP gave no NTP servers" {
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS= up
    [ "${status}" -eq 0 ]
    [ ! -e "${TIMESYNCD_CONF_DIR}" ]
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd fails, keeping the old drop-in and leaving no temp file, when the write fails" {
    seed_existing_drop_in
    # A link to /dev/full makes the write itself fail, for any user, and
    # removing it removes only the link.
    local _temp="${DROP_IN}.failing"
    ln -s /dev/full "${_temp}"
    fake_hook_tool mktemp <<EOF
#!/bin/sh
printf '%s\n' '${_temp}'
EOF
    run_timesyncd_hook PATH="${HOOK_PATH}" CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.3" up
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to write ${DROP_IN}"* ]]
    [ "$(cat "${DROP_IN}")" = "$(printf '[Time]\nNTP=old.example.invalid')" ]
    assert_conf_dir_holds_only "${UUID}.conf"
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd fails, keeping the old drop-in and leaving no temp file, when the move fails" {
    seed_existing_drop_in
    fail_hook_tool mv
    run_timesyncd_hook PATH="${HOOK_PATH}" CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.3" up
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to write ${DROP_IN}"* ]]
    [ "$(cat "${DROP_IN}")" = "$(printf '[Time]\nNTP=old.example.invalid')" ]
    assert_conf_dir_holds_only "${UUID}.conf"
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd fails when the temporary file cannot be created" {
    fail_hook_tool mktemp
    run_timesyncd_hook PATH="${HOOK_PATH}" CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.1" up
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to create a temporary file for ${DROP_IN}"* ]]
    assert_conf_dir_holds_only
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd fails when the configuration directory cannot be created" {
    : > "${TIMESYNCD_CONF_DIR}"
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.1" up
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to create ${TIMESYNCD_CONF_DIR}"* ]]
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd up fails when timesyncd cannot be restarted" {
    run_timesyncd_hook CONNECTION_UUID="${UUID}" DHCP4_NTP_SERVERS="10.0.0.1" FAKE_EXIT_systemctl=1 up
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to restart systemd-timesyncd.service"* ]]
}

@test "10-update-timesyncd down fails, without restarting timesyncd, when the drop-in cannot be removed" {
    seed_existing_drop_in
    fail_hook_tool rm
    run_timesyncd_hook PATH="${HOOK_PATH}" CONNECTION_UUID="${UUID}" down
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to remove ${DROP_IN}"* ]]
    [ -e "${DROP_IN}" ]
    refute_fake_called '^systemctl '
}

@test "10-update-timesyncd down fails when timesyncd cannot be restarted" {
    run_timesyncd_hook CONNECTION_UUID="${UUID}" FAKE_EXIT_systemctl=1 down
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"Failed to restart systemd-timesyncd.service"* ]]
}

# install-network-manager-dhcp-hook

@test "install-network-manager-dhcp-hook installs the dispatcher script executable" {
    setup_fake_sudo
    run "${REPO_DIR}/hooks/networkmanager/install-network-manager-dhcp-hook"
    [ "${status}" -eq 0 ]
    assert_fake_called "^sudo install -m 0755 ${REPO_DIR}/hooks/networkmanager/10-update-timesyncd /etc/NetworkManager/dispatcher\.d/10-update-timesyncd$"
}

@test "install-network-manager-dhcp-hook fails when the install fails" {
    setup_fake_sudo
    run env FAKE_SUDO_FAIL='^install ' "${REPO_DIR}/hooks/networkmanager/install-network-manager-dhcp-hook"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to install /etc/NetworkManager/dispatcher.d/10-update-timesyncd"* ]]
}
