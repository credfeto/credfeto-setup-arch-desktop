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

# Prints the PATH recorded by the stub dev-update.
recorded_path() {
    sed -n 's/^PATH=//p' "${BATS_TEST_TMPDIR}/dev-update.env"
}

# Succeeds when the PATH recorded by the stub dev-update has the given entry.
recorded_path_has() {
    [[ ":$(recorded_path):" == *":$1:"* ]]
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
    # ~/.local/bin and ~/.cargo/bin are appended, so nothing in them shadows
    # a system binary in timer runs.
    [[ ":$(recorded_path):" == *":/usr/bin:/bin"*":${HOME}/.local/bin:${HOME}/.cargo/bin:"* ]]
    # bun is prepended, as nvm's Node.js directory is, so those two do come
    # ahead of /usr/bin. That is deliberate: it is the order every interactive
    # shell has, and timer runs are meant to find the same tools.
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

@test "run-dev-update adds no PATH entry twice when its caller has already loaded the sections" {
    local _run _path _entry
    _run="$(setup_run_dev_update_tree)"
    mkdir -p "${HOME}/.bun/bin"
    run run_with_clean_tool_env "${_run}" < /dev/null
    [ "${status}" -eq 3 ]
    _path="$(recorded_path)"
    # Second run, started with the PATH the first one built, as a manual run
    # from a terminal is.
    run run_with_clean_tool_env PATH="${_path}" "${_run}" < /dev/null
    [ "${status}" -eq 3 ]
    for _entry in "${HOME}/.local/bin" "${HOME}/.cargo/bin" "${HOME}/.bun/bin"; do
        [ "$(recorded_path | tr ':' '\n' | grep -cxF "${_entry}")" -eq 1 ]
    done
}

@test "run-dev-update sources the remaining sections and starts dev-update when a section assigns the names the wrapper might use" {
    local _run _env="${BATS_TEST_TMPDIR}/dev-update.env"
    _run="$(setup_run_dev_update_tree)"
    mkdir -p "${HOME}/.bun/bin"
    # Sorts ahead of every section but the first, so the rest are sourced
    # after it has run.
    cat > "${BATS_TEST_TMPDIR}/clone/settings/bash.bashrc.d/01_clobber.sh" <<'EOF'
section=/nonexistent/section.sh
sections=(/nonexistent/section.sh)
BASEDIR=/nonexistent
SCRIPTDIR=/nonexistent
EOF
    run --separate-stderr run_with_clean_tool_env "${_run}" < /dev/null
    [ "${status}" -eq 3 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    # Set by 60_dotnet.sh and 75_bun.sh, which sort after the stub.
    grep -qx 'DOTNET_NOLOGO=true' "${_env}"
    grep -qx "PATH=${HOME}/.bun/bin:.*" "${_env}"
}

@test "run-dev-update reports a section that assigns one of its read-only names, and still starts its own dev-update" {
    local _run _env="${BATS_TEST_TMPDIR}/dev-update.env"
    _run="$(setup_run_dev_update_tree)"
    cat > "${BATS_TEST_TMPDIR}/clone/settings/bash.bashrc.d/01_clobber.sh" <<'EOF'
RUN_DEV_UPDATE_COMMAND=/nonexistent/dev-update
EOF
    run --separate-stderr run_with_clean_tool_env "${_run}" < /dev/null
    [ "${status}" -eq 3 ]
    [[ "${stderr}" == *"RUN_DEV_UPDATE_COMMAND: readonly variable"* ]]
    grep -qx 'DOTNET_NOLOGO=true' "${_env}"
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

# Sources the section named by $2 from the bash.bashrc.d directory in $1, on
# its own apart from the shared PATH helpers, which the PATH sections cannot
# run without. Run through run_section_shell non-interactive, this is one
# section as run-dev-update sources it: in a non-interactive bash with no
# terminal and the caller's tool settings cleared.
# shellcheck disable=SC2016
SOURCE_SECTION_SCRIPT='. "$1/45_path-helpers.sh"; . "$1/$2"'

@test "every bash.bashrc.d section writes nothing to stdout or stderr when sourced on its own by a non-interactive bash" {
    local _section _offenders=""
    for _section in "${SECTIONS_DIR}"/*.sh; do
        run_section_shell non-interactive "${SOURCE_SECTION_SCRIPT}" "${_section##*/}"
        if [ -n "${output}" ] || [ -n "${stderr}" ]; then
            _offenders+="${_section##*/}: ${output}${stderr}"$'\n'
        fi
    done
    printf '%s' "${_offenders}"
    [ -z "${_offenders}" ]
}

# Sources every section of the bash.bashrc.d directory in $2, one after the
# other in filename order in the same shell, as run-dev-update does, so a
# section runs with whatever the earlier ones set up. The completions,
# PROMPT_COMMAND and shell options are listed before and after, and whatever
# differs is written to the file in $3, which is left empty when nothing does.
# The script's own names are prefixed so that no section can change them.
# shellcheck disable=SC2016
ALL_SECTIONS_SCRIPT='
_units_test_interactive_state() {
    # nvm is left out: /usr/share/nvm/init-nvm.sh registers its completion
    # unconditionally, which credfeto/credfeto-setup-arch-desktop#73 tracks.
    # Remove this filter when that is fixed.
    complete -p 2> /dev/null | grep -v -e "-F __nvm nvm\$"
    declare -p PROMPT_COMMAND 2> /dev/null
    shopt -p
    shopt -po
}
_units_test_before="$(_units_test_interactive_state)"
for _units_test_section in "$2"/*.sh; do
    . "${_units_test_section}"
done
_units_test_after="$(_units_test_interactive_state)"
diff <(printf "%s\n" "${_units_test_before}") <(printf "%s\n" "${_units_test_after}") > "$3"
true
'

# Usage: run_all_sections_non_interactively <sections-dir>
run_all_sections_non_interactively() {
    run_section_shell non-interactive "${ALL_SECTIONS_SCRIPT}" "$1" "${BATS_TEST_TMPDIR}/interactive-state.diff"
}

@test "the bash.bashrc.d sections, sourced in order by a non-interactive bash, write nothing and leave no completion, prompt hook or shell option behind" {
    local _state="${BATS_TEST_TMPDIR}/interactive-state.diff"
    mkdir -p "${HOME}/.bun/bin"
    run_all_sections_non_interactively "${SECTIONS_DIR}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    # Written last, so its presence shows every section was sourced.
    [ -e "${_state}" ]
    cat "${_state}"
    [ ! -s "${_state}" ]
}

@test "the check on the sections sourced in order reports a completion, a prompt hook and a shell option that a section leaves unguarded" {
    local _sections="${BATS_TEST_TMPDIR}/unguarded" _state="${BATS_TEST_TMPDIR}/interactive-state.diff"
    mkdir -p "${_sections}"
    cat > "${_sections}/10_unguarded.sh" <<'EOF'
complete -W "one two" unguarded_tool
PROMPT_COMMAND+=('unguarded_hook')
shopt -s histappend
set -o noclobber
EOF
    run_all_sections_non_interactively "${_sections}"
    [ "${status}" -eq 0 ]
    grep -q 'unguarded_tool' "${_state}"
    grep -q 'unguarded_hook' "${_state}"
    grep -q '^> shopt -s histappend$' "${_state}"
    grep -q '^> set -o noclobber$' "${_state}"
}

@test "70_nvm.sh sets up nvm silently on a home that has no NVM_DIR yet" {
    [ -f /usr/share/nvm/init-nvm.sh ] || skip "nvm package not installed"
    run_section_shell non-interactive "${SOURCE_SECTION_SCRIPT}" 70_nvm.sh
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
    run_section_shell non-interactive "${SOURCE_SECTION_SCRIPT}" 70_nvm.sh
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
    # install -m, not cp, so neither unit takes the checkout's mode.
    assert_fake_called '^sudo install -m 0644 .*/auto-update\.service /etc/systemd/system/auto-update\.service$'
    assert_fake_called '^sudo install -m 0644 .*/auto-update\.timer /etc/systemd/system/auto-update\.timer$'
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
