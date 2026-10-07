#!/usr/bin/env bats
# Acceptance tests for settings/scripts/linux/.

load test_helper

LINUX_DIR="${SCRIPTS_DIR}/linux"

REFERENCE_REPOS=(
    credfeto-setup-arch-desktop
    credfeto-global-pre-commit
    cs-template
    credfeto-orchestrator
    claude
    credfeto-ai-skills
)

DEV_UPDATE_STEPS=(
    credfeto-setup-arch-desktop/install.d/dev-scripts
    credfeto-global-pre-commit/install
    claude/install
    credfeto-ai-skills/install
    credfeto-orchestrator/install-claude-hooks
)

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # These tests run from inside Claude Code sessions too, where CLAUDECODE=1
    # is inherited and would make dev-update/dev-install refuse to run.
    unset CLAUDECODE
    # Keeps the units install and the dev-update lock inside the test tree
    # rather than the real user config and runtime directories.
    unset XDG_CONFIG_HOME
    export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}"
}

# Fakes systemctl so `is-active` succeeds only for the given unit (pass
# "none" for neither network manager) and every other call exits with
# FAKE_EXIT_systemctl (default 0), plus
# nm-online and systemd-networkd-wait-online, whose exit codes come from
# FAKE_EXIT_nm_online and FAKE_EXIT_systemd_networkd_wait_online. Any extra
# arguments are further tools to fake via setup_fake_bin.
setup_fake_network() {
    local _active="$1"
    shift
    setup_fake_bin nm-online systemd-networkd-wait-online "$@"
    cat > "${FAKE_BIN_DIR}/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ "\$1" = "is-active" ]; then
    [ "\$3" = "${_active}" ]
    exit
fi
exit "\${FAKE_EXIT_systemctl:-0}"
EOF
    chmod +x "${FAKE_BIN_DIR}/systemctl"
    export SYSTEMD_NETWORKD_WAIT_ONLINE="${FAKE_BIN_DIR}/systemd-networkd-wait-online"
}

# Creates an executable stub at <root>/<relpath> that logs "<relpath> <args>"
# to the fake log and exits with the given code.
# Usage: make_logging_stub <root> <relpath> [<exit-code>]
make_logging_stub() {
    local _path="$1/$2"
    mkdir -p "$(dirname "${_path}")"
    cat > "${_path}" <<EOF
#!/bin/sh
printf '%s %s\n' "$2" "\$*" >> "${FAKE_BIN_LOG}"
exit ${3:-0}
EOF
    chmod +x "${_path}"
}

# Lines of the fake log in order, minus the network probes.
logged_steps() {
    grep -vE '^(systemctl is-active|nm-online|systemd-networkd-wait-online) ' "${FAKE_BIN_LOG}"
}

# ── network-online ───────────────────────────────────────────────────────────

@test "network-online exits 0 when NetworkManager reports online" {
    setup_fake_network NetworkManager.service
    run "${LINUX_DIR}/network-online"
    [ "${status}" -eq 0 ]
    assert_fake_called '^nm-online -q -t 0$'
    refute_fake_called '^systemd-networkd-wait-online'
}

@test "network-online exits 1 when NetworkManager reports offline" {
    setup_fake_network NetworkManager.service
    run env FAKE_EXIT_nm_online=2 "${LINUX_DIR}/network-online"
    [ "${status}" -eq 1 ]
}

@test "network-online exits 0 when systemd-networkd reports online" {
    setup_fake_network systemd-networkd.service
    run "${LINUX_DIR}/network-online"
    [ "${status}" -eq 0 ]
    assert_fake_called '^systemd-networkd-wait-online --any --timeout=1 -q$'
    refute_fake_called '^nm-online'
}

@test "network-online exits 1 when systemd-networkd reports offline" {
    setup_fake_network systemd-networkd.service
    run env FAKE_EXIT_systemd_networkd_wait_online=1 "${LINUX_DIR}/network-online"
    [ "${status}" -eq 1 ]
}

@test "network-online exits 255 when neither network manager is active" {
    setup_fake_network none
    run "${LINUX_DIR}/network-online"
    [ "${status}" -eq 255 ]
    [[ "${output}" == *"Neither NetworkManager nor systemd-networkd is active"* ]]
    refute_fake_called '^nm-online'
    refute_fake_called '^systemd-networkd-wait-online'
}

# ── dev-update ───────────────────────────────────────────────────────────────

# Fakes git so `git clone <url> <dest>` copies <dest>'s basename from
# FAKE_CLONE_SOURCE when present (otherwise creates an empty directory),
# logs the call and exits with FAKE_EXIT_git.
setup_fake_git_clone() {
    FAKE_CLONE_SOURCE="${BATS_TEST_TMPDIR}/clone-source"
    mkdir -p "${FAKE_CLONE_SOURCE}"
    cat > "${FAKE_BIN_DIR}/git" <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >> "${FAKE_BIN_LOG}"
[ "\${FAKE_EXIT_git:-0}" -eq 0 ] || exit "\${FAKE_EXIT_git}"
if [ "\$1" = "clone" ]; then
    if [ -d "${FAKE_CLONE_SOURCE}/\$(basename "\$3")" ]; then
        cp -R "${FAKE_CLONE_SOURCE}/\$(basename "\$3")" "\$3"
    else
        mkdir -p "\$3"
    fi
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/git"
}

# Online under NetworkManager (or the given active unit, as for
# setup_fake_network), every reference clone present, every install step a
# logging stub; git and update-dotnet-tools are faked so nothing reaches a
# real remote or the real dotnet tool restore. update-dotnet-tools logs the
# directory it was run from.
# Usage: setup_dev_update_fixture [<active-unit>]
setup_dev_update_fixture() {
    setup_fake_network "${1:-NetworkManager.service}" git
    cat > "${FAKE_BIN_DIR}/update-dotnet-tools" <<EOF
#!/bin/sh
printf 'update-dotnet-tools %s\n' "\$(pwd)" >> "${FAKE_BIN_LOG}"
exit "\${FAKE_EXIT_update_dotnet_tools:-0}"
EOF
    chmod +x "${FAKE_BIN_DIR}/update-dotnet-tools"
    local _repo _step
    for _repo in "${REFERENCE_REPOS[@]}"; do
        mkdir -p "${HOME}/work/reference/${_repo}"
    done
    for _step in "${DEV_UPDATE_STEPS[@]}"; do
        make_logging_stub "${HOME}/work/reference" "${_step}"
    done
}

@test "dev-update dies inside a Claude Code session" {
    setup_dev_update_fixture
    run env CLAUDECODE=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must not be run from a Claude Code session"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
}

@test "dev-update dies at once when offline" {
    setup_dev_update_fixture
    run env FAKE_EXIT_nm_online=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No network connection"* ]]
    [ -z "$(logged_steps)" ]
}

@test "dev-update dies when neither network manager is active" {
    setup_dev_update_fixture none
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Neither NetworkManager nor systemd-networkd is active"* ]]
    [ -z "$(logged_steps)" ]
}

@test "dev-update exits 0 without doing anything while another run holds the lock" {
    setup_dev_update_fixture
    exec 8>"${XDG_RUNTIME_DIR}/dev-update.lock"
    flock -n 8

    run "${LINUX_DIR}/dev-update"

    exec 8>&-
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dev-update is already running"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
}

@test "dev-update dies when XDG_RUNTIME_DIR is not set" {
    setup_dev_update_fixture
    run env -u XDG_RUNTIME_DIR "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"XDG_RUNTIME_DIR is not set"* ]]
}

@test "dev-update pulls every reference repo, then runs each install step in order" {
    setup_dev_update_fixture
    cd "${BATS_TEST_TMPDIR}"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment updated"* ]]

    local _ref="${HOME}/work/reference"
    expected="$(printf '%s\n' \
        "git -C ${_ref}/credfeto-setup-arch-desktop pull" \
        "git -C ${_ref}/credfeto-global-pre-commit pull" \
        "git -C ${_ref}/cs-template pull" \
        "git -C ${_ref}/credfeto-orchestrator pull" \
        "git -C ${_ref}/claude pull" \
        "git -C ${_ref}/credfeto-ai-skills pull" \
        "systemctl --user daemon-reload" \
        "credfeto-setup-arch-desktop/install.d/dev-scripts " \
        "credfeto-global-pre-commit/install --system" \
        "claude/install " \
        "credfeto-ai-skills/install " \
        "credfeto-orchestrator/install-claude-hooks " \
        "update-dotnet-tools ${HOME}")"
    [ "$(logged_steps)" = "${expected}" ]
}

@test "dev-update warns and still completes when the systemd user reload fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_systemctl=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not reload systemd user units"* ]]
    [[ "${output}" == *"Dev environment updated"* ]]
    assert_fake_called '^credfeto-setup-arch-desktop/install\.d/dev-scripts'
    assert_fake_called '^update-dotnet-tools'
}

@test "dev-update does not reload systemd if a pull fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_git=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    refute_fake_called '^systemctl --user daemon-reload'
}

@test "dev-update runs update-dotnet-tools from \$HOME" {
    setup_dev_update_fixture
    cd "${BATS_TEST_TMPDIR}"
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    grep -qxF "update-dotnet-tools ${HOME}" "${FAKE_BIN_LOG}"
}

@test "dev-update dies if update-dotnet-tools fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_update_dotnet_tools=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to update dotnet tools"* ]]
    [[ "${output}" != *"Dev environment updated"* ]]
}

@test "dev-update dies if a pull fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_git=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to pull"*"credfeto-setup-arch-desktop"* ]]
    refute_fake_called '^credfeto-setup-arch-desktop/install\.d/dev-scripts'
}

@test "dev-update clones a missing reference repo over SSH before pulling it" {
    setup_dev_update_fixture
    setup_fake_git_clone
    rm -rf "${HOME}/work/reference/cs-template"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment updated"* ]]

    local _ref="${HOME}/work/reference"
    grep -qxF "git clone git@github.com:credfeto/cs-template.git ${_ref}/cs-template" "${FAKE_BIN_LOG}"
    refute_fake_called 'https://'
    [ "$(grep -c '^git clone ' "${FAKE_BIN_LOG}")" -eq 1 ]
    [ "$(grep -n -m 1 -xF "git clone git@github.com:credfeto/cs-template.git ${_ref}/cs-template" "${FAKE_BIN_LOG}" | cut -d: -f1)" \
        -lt "$(grep -n -m 1 -xF "git -C ${_ref}/cs-template pull" "${FAKE_BIN_LOG}" | cut -d: -f1)" ]
}

@test "dev-update creates the reference tree when it is missing" {
    setup_dev_update_fixture
    setup_fake_git_clone
    # The fake clone copies from FAKE_CLONE_SOURCE into a parent that must
    # already exist, so this also proves dev-update creates the tree.
    cp -R "${HOME}/work/reference/." "${FAKE_CLONE_SOURCE}/"
    rm -rf "${HOME}/work/reference"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^git clone git@github\.com:credfeto/' "${FAKE_BIN_LOG}")" -eq "${#REFERENCE_REPOS[@]}" ]
}

@test "dev-update dies if cloning a missing reference repo fails" {
    setup_dev_update_fixture
    setup_fake_git_clone
    rm -rf "${HOME}/work/reference/credfeto-setup-arch-desktop"

    run env FAKE_EXIT_git=128 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to clone credfeto-setup-arch-desktop"* ]]
    assert_fake_called '^git clone git@github\.com:credfeto/credfeto-setup-arch-desktop\.git '
    refute_fake_called '^git -C '
    refute_fake_called '^credfeto-setup-arch-desktop/install\.d/dev-scripts'
    refute_fake_called '^update-dotnet-tools'
}

@test "dev-update treats every install step failing as fatal" {
    local _failing
    for _failing in "${DEV_UPDATE_STEPS[@]}"; do
        setup_dev_update_fixture
        make_logging_stub "${HOME}/work/reference" "${_failing}" 3

        run "${LINUX_DIR}/dev-update"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"Failed to run ${HOME}/work/reference/${_failing}"* ]]
        refute_fake_called '^update-dotnet-tools'

        rm -rf "${HOME}/work/reference"
    done
}

@test "dev-update dies if claude/install is missing or not executable" {
    local _break
    for _break in "rm" "chmod -x"; do
        setup_dev_update_fixture
        ${_break} "${HOME}/work/reference/claude/install"

        run "${LINUX_DIR}/dev-update"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"Not found or not executable"*"claude/install"* ]]
        refute_fake_called '^credfeto-ai-skills/install'

        rm -rf "${HOME}/work/reference"
    done
}

# ── dev-install ──────────────────────────────────────────────────────────────

# Online under NetworkManager with dotnet present. The cloned
# credfeto-setup-arch-desktop carries the real units/dev-update and
# lib/common, so its units install runs for real against the fake
# systemctl, plus a logging stub in place of dev-update.
# install-dotnet-tools logs the directory it was run from.
setup_dev_install_fixture() {
    setup_fake_network NetworkManager.service dotnet
    setup_fake_git_clone

    local _clone="${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop"
    mkdir -p "${_clone}/units"
    cp -R "${REPO_DIR}/lib" "${_clone}/lib"
    cp -R "${REPO_DIR}/units/dev-update" "${_clone}/units/dev-update"
    make_logging_stub "${_clone}" settings/scripts/linux/dev-update

    cat > "${FAKE_BIN_DIR}/install-dotnet-tools" <<EOF
#!/bin/sh
printf 'install-dotnet-tools %s\n' "\$(pwd)" >> "${FAKE_BIN_LOG}"
exit "\${FAKE_EXIT_install_dotnet_tools:-0}"
EOF
    chmod +x "${FAKE_BIN_DIR}/install-dotnet-tools"
}

@test "dev-install dies inside a Claude Code session" {
    setup_dev_install_fixture
    run env CLAUDECODE=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must not be run from a Claude Code session"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install dies at once when offline, before cloning anything" {
    setup_dev_install_fixture
    run env FAKE_EXIT_nm_online=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No network connection"* ]]
    [ -z "$(logged_steps)" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install dies when dotnet is not on PATH" {
    setup_dev_install_fixture
    rm "${FAKE_BIN_DIR}/dotnet"
    # The real dotnet lives in /usr/bin, so PATH is cut down to the fakes
    # plus only the tools the scripts need before the dotnet check.
    local _minbin="${BATS_TEST_TMPDIR}/minbin"
    mkdir -p "${_minbin}"
    ln -s "$(which dirname)" "${_minbin}/dirname"
    ln -s "$(which readlink)" "${_minbin}/readlink"

    run env PATH="${FAKE_BIN_DIR}:${_minbin}" "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"dotnet is not on PATH"* ]]
    [ -z "$(logged_steps)" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install creates the reference tree, clones every repo over SSH, then installs" {
    setup_dev_install_fixture
    cd "${BATS_TEST_TMPDIR}"

    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment installed"* ]]
    [ -d "${HOME}/work/reference" ]

    local _repo
    for _repo in "${REFERENCE_REPOS[@]}"; do
        grep -qxF "git clone git@github.com:credfeto/${_repo}.git ${HOME}/work/reference/${_repo}" "${FAKE_BIN_LOG}"
    done
    refute_fake_called 'https://'
}

@test "dev-install clones only the reference repos that are missing" {
    setup_dev_install_fixture
    mkdir -p "${HOME}/work/reference/cs-template" "${HOME}/work/reference/claude"

    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    refute_fake_called '^git clone .*/cs-template\.git'
    refute_fake_called '^git clone .*/claude\.git'
    assert_fake_called '^git clone git@github\.com:credfeto/credfeto-ai-skills\.git '
    [ "$(grep -c '^git clone ' "${FAKE_BIN_LOG}")" -eq 4 ]
}

@test "dev-install dies if a clone fails" {
    setup_dev_install_fixture
    run env FAKE_EXIT_git=128 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to clone credfeto-setup-arch-desktop"* ]]
    refute_fake_called '^install-dotnet-tools'
}

@test "dev-install runs install-dotnet-tools from \$HOME" {
    setup_dev_install_fixture
    cd "${BATS_TEST_TMPDIR}"
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    grep -qxF "install-dotnet-tools ${HOME}" "${FAKE_BIN_LOG}"
}

@test "dev-install dies if install-dotnet-tools fails" {
    setup_dev_install_fixture
    run env FAKE_EXIT_install_dotnet_tools=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to install dotnet tools"* ]]
    refute_fake_called '^systemctl --user'
}

@test "dev-install symlinks the units from the reference clone and enables the timer" {
    setup_dev_install_fixture
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]

    assert_dev_update_units_linked_to "${HOME}/work/reference/credfeto-setup-arch-desktop/units/dev-update"
    assert_fake_called '^systemctl --user daemon-reload$'
    assert_fake_called '^systemctl --user enable dev-update\.timer$'
}

@test "dev-install runs the reference clone's dev-update as its last step" {
    setup_dev_install_fixture
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "settings/scripts/linux/dev-update " ]
}

@test "dev-install dies if dev-update fails" {
    setup_dev_install_fixture
    make_logging_stub "${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop" settings/scripts/linux/dev-update 1
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to run"*"settings/scripts/linux/dev-update"* ]]
}

# ── install-fp ───────────────────────────────────────────────────────────────

@test "install-fp installs every candidate flatpak package" {
    setup_fake_bin flatpak
    run "${LINUX_DIR}/install-fp"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak install -y com\.brave\.Browser'
    assert_fake_called '^flatpak install -y com\.ktechpit\.whatsie'
    [[ "${output}" == *"All flatpak packages installed"* ]]
}

# ── logout ───────────────────────────────────────────────────────────────────

@test "logout updates/cleans flatpaks then runs a full pacman/AUR upgrade" {
    setup_fake_bin flatpak yay
    run "${LINUX_DIR}/logout"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak update -y'
    assert_fake_called '^flatpak uninstall --unused -y'
    assert_fake_called '^yay -Syu --noconfirm'
}

# ── login ────────────────────────────────────────────────────────────────────

setup_fake_flatpak_with_installed() {
    # $1: newline-separated list of installed app IDs `flatpak list` reports.
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    mkdir -p "${FAKE_BIN_DIR}"
    : > "${FAKE_BIN_LOG}"
    cat > "${FAKE_BIN_DIR}/flatpak" <<EOF
#!/bin/sh
printf 'flatpak %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ "\$1 \$2" = "list --app" ]; then
    printf '%s\n' "$1"
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/flatpak"
    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

@test "login only launches candidate apps that are actually installed" {
    setup_fake_flatpak_with_installed "$(printf 'com.discordapp.Discord\norg.mozilla.firefox\ncom.some.UnrelatedApp')"
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
    assert_fake_called '^flatpak run org\.mozilla\.firefox$'
    refute_fake_called '^flatpak run com\.some\.UnrelatedApp'
    refute_fake_called '^flatpak run com\.spotify\.Client'
    [[ "${output}" == *"Login complete"* ]]
}

@test "login gives Brave its Ozone/Wayland flags, no other app gets them" {
    setup_fake_flatpak_with_installed "$(printf 'com.brave.Browser\ncom.discordapp.Discord')"
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.brave\.Browser --enable-feature=UseOzonePlatform --ozone-platform=wayland'
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
}

@test "login starts the paults_aquaescape stream only when streamlink is installed" {
    setup_fake_flatpak_with_installed ""
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"streamlink found"* ]]
    refute_fake_called '^stream '
}

@test "login starts the stream when streamlink is present" {
    setup_fake_flatpak_with_installed ""
    cat > "${FAKE_BIN_DIR}/streamlink" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "${FAKE_BIN_DIR}/stream" <<EOF
#!/bin/sh
printf 'stream %s\n' "\$*" >> "${FAKE_BIN_LOG}"
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/streamlink" "${FAKE_BIN_DIR}/stream"

    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"streamlink found, starting stream"* ]]
    assert_fake_called '^stream paults_aquaescape$'
}

# -- tmux-here ----------------------------------------------------------------

# A fake tmux that logs every call and reports has-session as failing (no
# session) unless the marker file $BATS_TEST_TMPDIR/session-exists is present.
setup_fake_tmux() {
    setup_fake_bin tmux
    # FAKE_EXIT_tmux applies to every subcommand, so the stock fake is
    # replaced with one that fails only has-session.
    cat > "${FAKE_BIN_DIR}/tmux" <<EOF
#!/bin/sh
printf 'tmux %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ "\$1" = "has-session" ] && [ ! -f "${BATS_TEST_TMPDIR}/session-exists" ]; then
    exit 1
fi
exit 0
EOF
    unset TMUX
}

@test "tmux-here creates a session in the current directory then attaches when none exists" {
    setup_fake_tmux
    mkdir -p "${BATS_TEST_TMPDIR}/my.project"
    cd "${BATS_TEST_TMPDIR}/my.project"

    run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    assert_fake_called '^tmux new-session -d -s my_project-[0-9]+ -c .*/my\.project$'
    assert_fake_called '^tmux attach-session -t =my_project-[0-9]+$'
}

@test "tmux-here only attaches when the session already exists" {
    setup_fake_tmux
    touch "${BATS_TEST_TMPDIR}/session-exists"
    mkdir -p "${BATS_TEST_TMPDIR}/proj"
    cd "${BATS_TEST_TMPDIR}/proj"

    run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    refute_fake_called 'new-session'
    assert_fake_called '^tmux attach-session -t =proj-[0-9]+$'
}

@test "tmux-here switches client instead of attaching when already inside tmux" {
    setup_fake_tmux
    touch "${BATS_TEST_TMPDIR}/session-exists"
    mkdir -p "${BATS_TEST_TMPDIR}/proj"
    cd "${BATS_TEST_TMPDIR}/proj"

    TMUX=/tmp/fake,1,0 run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    refute_fake_called 'attach-session'
    assert_fake_called '^tmux switch-client -t =proj-[0-9]+$'
}

@test "tmux-here gives same-named directories in different places different sessions" {
    setup_fake_tmux
    mkdir -p "${BATS_TEST_TMPDIR}/a/proj" "${BATS_TEST_TMPDIR}/b/proj"

    cd "${BATS_TEST_TMPDIR}/a/proj"
    run "${LINUX_DIR}/tmux-here"
    cd "${BATS_TEST_TMPDIR}/b/proj"
    run "${LINUX_DIR}/tmux-here"

    [ "$(grep '^tmux attach-session' "${FAKE_BIN_LOG}" | sort -u | wc -l)" -eq 2 ]
}
