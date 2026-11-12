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

# The SSH clone URL each reference repo is expected to come from: claude is
# owned by dnyw4l3n13, every other reference repo by credfeto.
# Usage: expected_clone_url <repo>
expected_clone_url() {
    case "$1" in
        claude) printf '%s\n' "git@github.com:dnyw4l3n13/claude.git" ;;
        *) printf '%s\n' "git@github.com:credfeto/$1.git" ;;
    esac
}

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
# "none" for neither network manager), `--user start` exits with
# FAKE_EXIT_systemctl_start when that is set, and every other call exits with
# FAKE_EXIT_systemctl (default 0), plus
# nm-online and systemd-networkd-wait-online, whose exit codes come from
# FAKE_EXIT_nm_online and FAKE_EXIT_systemd_networkd_wait_online. Any extra
# arguments are further tools to fake via setup_fake_bin.
setup_fake_network() {
    local _active="$1"
    shift
    setup_fake_bin nm-online systemd-networkd-wait-online "$@"
    replace_fake systemctl <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
if [ "\$1" = "is-active" ]; then
    [ "\$3" = "${_active}" ]
    exit
fi
if [ "\$2" = "start" ] && [ -n "\${FAKE_EXIT_systemctl_start:-}" ]; then
    exit "\${FAKE_EXIT_systemctl_start}"
fi
exit "\${FAKE_EXIT_systemctl:-0}"
EOF
    export SYSTEMD_NETWORKD_WAIT_ONLINE="${FAKE_BIN_DIR}/systemd-networkd-wait-online"
}

# Creates an executable stub at <root>/<relpath> that logs "<relpath> <args>"
# to the fake log and exits with the given code.
# Usage: make_logging_stub <root> <relpath> [<exit-code>]
make_logging_stub() {
    local _path="$1/$2"
    mkdir -p "$(dirname "${_path}")"
    write_fake_script "${_path}" "$2" <<EOF
#!/bin/sh
printf '%s %s\n' "$2" "\$*" >> "\${FAKE_BIN_LOG}"
exit ${3:-0}
EOF
}

# Creates an executable stub at <root>/<relpath> that logs "<name> <cwd>" to
# the fake log, so a test can see which directory it was run from, and exits
# with the value of the named variable (default 0). Also puts a decoy of the
# same name on PATH that logs "PATH <name>", so a test can prove the stub was
# run from <root> rather than looked up on PATH.
# Usage: make_cwd_logging_stub <root> <relpath> <exit-variable>
make_cwd_logging_stub() {
    local _path="$1/$2" _name
    _name="$(basename "$2")"
    mkdir -p "$(dirname "${_path}")"
    write_fake_script "${_path}" "$2" <<EOF
#!/bin/sh
printf '%s %s\n' "${_name}" "\$(pwd)" >> "\${FAKE_BIN_LOG}"
exit "\${$3:-0}"
EOF
    replace_fake "${_name}" <<EOF
#!/bin/sh
printf 'PATH %s\n' "${_name}" >> "\${FAKE_BIN_LOG}"
EOF
}

# Lines of the fake log in order, minus the network and session probes.
logged_steps() {
    grep -vE '^(systemctl is-active|nm-online|systemd-networkd-wait-online|id) |^systemctl --user show-environment$' "${FAKE_BIN_LOG}"
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

# ── require_network ──────────────────────────────────────────────────────────

# Runs lib/common's require_network against a stand-in network check that
# exits with the given status.
# Usage: run_require_network <status>
run_require_network() {
    local _check="${BATS_TEST_TMPDIR}/network-check"
    printf '#!/bin/sh\nexit %s\n' "$1" > "${_check}"
    chmod +x "${_check}"
    run sh -c '. "$1"; require_network "$2"; echo "carried on"' sh "${REPO_DIR}/lib/common" "${_check}"
}

@test "require_network returns when the network check succeeds" {
    run_require_network 0
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"carried on"* ]]
}

@test "require_network dies reporting no network connection when the check exits 1" {
    run_require_network 1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No network connection"* ]]
    [[ "${output}" != *"carried on"* ]]
}

@test "require_network dies reporting no supported network manager when the check exits 255" {
    run_require_network 255
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No supported network manager (NetworkManager or systemd-networkd) is running"* ]]
    [[ "${output}" != *"No network connection"* ]]
    [[ "${output}" != *"carried on"* ]]
}

@test "require_network dies naming any other exit status of the check" {
    run_require_network 127
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"failed with exit status 127"* ]]
    [[ "${output}" != *"No network connection"* ]]
    [[ "${output}" != *"carried on"* ]]
}

# ── clone_reference_repo ─────────────────────────────────────────────────────

# Runs lib/common's clone_reference_repo for dnyw4l3n13/claude against the
# real git, with the reference tree at the given directory, which must
# already hold a claude directory so nothing is cloned. git never searches
# above BATS_TEST_TMPDIR, so the result does not depend on where the tests
# are run from.
# Usage: run_clone_reference_repo <reference-dir>
run_clone_reference_repo() {
    run sh -c 'DEV_REFERENCE_DIR="$2" GIT_CEILING_DIRECTORIES="$3"; export DEV_REFERENCE_DIR GIT_CEILING_DIRECTORIES; . "$1"; clone_reference_repo dnyw4l3n13/claude; echo "carried on"' \
        sh "${REPO_DIR}/lib/common" "$1" "${BATS_TEST_TMPDIR}"
}

@test "clone_reference_repo accepts an existing directory that is a git clone" {
    local _ref="${BATS_TEST_TMPDIR}/reference"
    git init -q "${_ref}/claude"
    run_clone_reference_repo "${_ref}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"carried on"* ]]
    [[ "${output}" != *"Cloning"* ]]
}

@test "clone_reference_repo dies naming an existing directory that is not a git clone but sits inside another repo" {
    local _parent="${BATS_TEST_TMPDIR}/dotfiles"
    git init -q "${_parent}"
    mkdir -p "${_parent}/reference/claude"
    # Precondition: plain git run there acts on the enclosing repo.
    [ "$(GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR}" git -C "${_parent}/reference/claude" rev-parse --show-toplevel)" = "$(readlink -f "${_parent}")" ]
    run_clone_reference_repo "${_parent}/reference"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${_parent}/reference/claude exists but is not a git clone; move or delete it, then re-run"* ]]
    [[ "${output}" != *"carried on"* ]]
}

@test "clone_reference_repo dies naming an existing directory that is in no git repo at all" {
    local _ref="${BATS_TEST_TMPDIR}/reference"
    mkdir -p "${_ref}/claude"
    run_clone_reference_repo "${_ref}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${_ref}/claude exists but is not a git clone"* ]]
    [[ "${output}" != *"carried on"* ]]
}

# ── dev-update ───────────────────────────────────────────────────────────────

# Fakes git, logging every call. Any call exits with FAKE_EXIT_git when that
# is set and non-zero. Otherwise:
# - `git clone <url> <dest>` copies <dest>'s basename from FAKE_CLONE_SOURCE
#   when present, or else creates an empty directory;
# - `git -C <path> status --porcelain` reports a modified file when <path>'s
#   basename is FAKE_GIT_DIRTY, and a clean tree otherwise;
# - `git -C <path> switch` and `git -C <path> pull` exit with
#   FAKE_EXIT_git_switch and FAKE_EXIT_git_pull (default 0);
# - `git -C <path> rev-parse --show-toplevel` prints <path> resolved, so
#   every existing directory reads as a clone, or its parent when <path>'s
#   basename is FAKE_GIT_NOT_TOPLEVEL, as for a plain directory inside an
#   enclosing repo;
# - `git -C <path> rev-parse HEAD^{tree}` exits with
#   FAKE_EXIT_git_rev_parse_tree when that is set and non-zero, and
#   otherwise prints as every clone's tree the contents of FAKE_GIT_TREE_FILE
#   when that is set, so a test can move HEAD during a run, or else
#   FAKE_GIT_TREE (default tree-0);
# - `git -C <path> archive --format=tar -o <file> <tree-ish>` exits with
#   FAKE_EXIT_git_archive when that is set and non-zero, and otherwise
#   writes a tar of everything in <path> to <file>.
setup_fake_git() {
    FAKE_CLONE_SOURCE="${BATS_TEST_TMPDIR}/clone-source"
    mkdir -p "${FAKE_CLONE_SOURCE}"
    replace_fake git <<EOF
#!/bin/sh
# Read before the call is logged, so a test that moves HEAD once it sees
# the call in the log cannot change the tree this call prints.
_tree="\${FAKE_GIT_TREE:-tree-0}"
if [ -n "\${FAKE_GIT_TREE_FILE:-}" ]; then
    _tree="\$(cat "\${FAKE_GIT_TREE_FILE}")"
fi
printf 'git %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
[ "\${FAKE_EXIT_git:-0}" -eq 0 ] || exit "\${FAKE_EXIT_git}"
if [ "\$1" = "clone" ]; then
    if [ -d ${FAKE_CLONE_SOURCE@Q}/"\$(basename "\$3")" ]; then
        cp -R ${FAKE_CLONE_SOURCE@Q}/"\$(basename "\$3")" "\$3"
    else
        mkdir -p "\$3"
    fi
    exit 0
fi
if [ "\$1" = "-C" ]; then
    case "\$3" in
        status)
            if [ "\$(basename "\$2")" = "\${FAKE_GIT_DIRTY:-}" ]; then
                printf ' M README.md\n'
            fi
            ;;
        switch) exit "\${FAKE_EXIT_git_switch:-0}" ;;
        pull) exit "\${FAKE_EXIT_git_pull:-0}" ;;
        archive)
            [ "\${FAKE_EXIT_git_archive:-0}" -eq 0 ] || exit "\${FAKE_EXIT_git_archive}"
            tar -C "\$2" -cf "\$6" .
            ;;
        rev-parse)
            if [ "\$4" = "HEAD^{tree}" ]; then
                [ "\${FAKE_EXIT_git_rev_parse_tree:-0}" -eq 0 ] || exit "\${FAKE_EXIT_git_rev_parse_tree}"
                printf '%s\n' "\${_tree}"
            elif [ "\$(basename "\$2")" = "\${FAKE_GIT_NOT_TOPLEVEL:-}" ]; then
                dirname "\$(readlink -f "\$2")"
            else
                readlink -f "\$2"
            fi
            ;;
    esac
fi
exit 0
EOF
}

# Prints the fake log lines expected when a reference clone is brought up
# to date: a clean status check, a switch to main and a fast-forward pull.
# Usage: expected_reference_update <repo>
expected_reference_update() {
    local _path="${HOME}/work/reference/$1"
    printf '%s\n' \
        "git -C ${_path} status --porcelain" \
        "git -C ${_path} switch main" \
        "git -C ${_path} pull --ff-only"
}

# Asserts the run never forced, reset or stashed a reference clone.
refute_destructive_git() {
    refute_fake_called '^git .*( reset| stash| --force| -f( |$)| -C [^ ]+ clean)'
}

# Prints, with mask_publish_names applied, the fake log lines expected when a
# reference repo is published and one of its installers is run from the
# snapshot: the read of HEAD's tree, the archive of HEAD, the chown to root
# and the installer itself.
# Usage: expected_published_step <repo> <installer>
expected_published_step() {
    printf '%s\n' \
        "git -C ${HOME}/work/reference/$1 rev-parse HEAD^{tree}" \
        "git -C ${HOME}/work/reference/$1 archive --format=tar -o ARCHIVE tree-0" \
        "sudo chown -R root:root ${DEV_PUBLISH_DIR}/$1-SNAPSHOT" \
        "$1/$2 --system"
}

# Replaces the temporary archive path and the snapshot timestamps in the
# lines read from stdin, which differ from run to run.
mask_publish_names() {
    sed -E -e 's/ -o [^ ]+ ([^ ]+)$/ -o ARCHIVE \1/' -e 's/-[0-9]{8}T[0-9]{6}\.[0-9]+Z$/-SNAPSHOT/'
}

# Lists the snapshot directories published for the given repo, oldest first.
# Usage: published_snapshots <repo>
published_snapshots() {
    find "${DEV_PUBLISH_DIR}" -mindepth 1 -maxdepth 1 -type d -name "$1-*Z" -printf '%f\n' | sort
}

# Online under NetworkManager (or the given active unit, as for
# setup_fake_network), every reference clone present, every install step a
# logging stub; git and the reference clone's update-dotnet-tools are faked
# so nothing reaches a real remote or the real dotnet tool restore.
# update-dotnet-tools logs the directory it was run from. Snapshots are
# published into a writable directory in the test tree, so only the chown to
# root goes through the fake sudo, which logs it without running it.
# Usage: setup_dev_update_fixture [<active-unit>]
setup_dev_update_fixture() {
    setup_fake_network "${1:-NetworkManager.service}"
    setup_fake_sudo
    setup_fake_git
    export DEV_PUBLISH_DIR="${BATS_TEST_TMPDIR}/published"
    local _repo _step
    for _repo in "${REFERENCE_REPOS[@]}"; do
        mkdir -p "${HOME}/work/reference/${_repo}"
    done
    for _step in "${DEV_UPDATE_STEPS[@]}"; do
        make_logging_stub "${HOME}/work/reference" "${_step}"
    done
    make_cwd_logging_stub "${HOME}/work/reference" \
        credfeto-setup-arch-desktop/settings/scripts/general/update-dotnet-tools \
        FAKE_EXIT_update_dotnet_tools
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
    [[ "${output}" == *"No supported network manager (NetworkManager or systemd-networkd) is running"* ]]
    [[ "${output}" != *"No network connection"* ]]
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

@test "dev-update --fail-if-running dies without doing anything while another run holds the lock" {
    setup_dev_update_fixture
    exec 8>"${XDG_RUNTIME_DIR}/dev-update.lock"
    flock -n 8

    run "${LINUX_DIR}/dev-update" --fail-if-running

    exec 8>&-
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Another dev-update is running; re-run dev-install when it finishes"* ]]
    [[ "${output}" != *"dev-update is already running"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
}

@test "dev-update --fail-if-running runs normally when the lock is free" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update" --fail-if-running
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment updated"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "systemctl --user start dev-update.timer" ]
}

@test "dev-update dies on an unknown argument without doing anything" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update" --bogus
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Usage: dev-update [--fail-if-running]"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
    [ ! -e "${XDG_RUNTIME_DIR}/dev-update.lock" ]
}

@test "dev-update holds the lock while its steps run" {
    setup_dev_update_fixture
    # A second dev-update started from inside a step must find the lock held.
    write_fake_script "${HOME}/work/reference/claude/install" claude/install <<EOF
#!/bin/sh
${LINUX_DIR@Q}/dev-update > ${BATS_TEST_TMPDIR@Q}/nested.out 2>&1
printf 'nested dev-update exited %s\n' "\$?" >> "\${FAKE_BIN_LOG}"
EOF

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    grep -qxF "nested dev-update exited 0" "${FAKE_BIN_LOG}"
    grep -qF "dev-update is already running" "${BATS_TEST_TMPDIR}/nested.out"
    run grep -qF "Running " "${BATS_TEST_TMPDIR}/nested.out"
    [ "${status}" -eq 1 ]
}

@test "dev-update does not pass the lock file descriptor on to the steps it runs" {
    setup_dev_update_fixture
    # A process a step leaves behind keeps every fd it inherited, so an
    # inherited lock fd would keep the lock held after dev-update ends.
    write_fake_script "${HOME}/work/reference/claude/install" claude/install <<EOF
#!/bin/sh
for _fd in /proc/\$\$/fd/*; do
    case "\$(readlink "\${_fd}")" in
        *dev-update.lock) printf 'lock fd inherited\n' >> "\${FAKE_BIN_LOG}" ;;
    esac
done
printf 'claude/install ran\n' >> "\${FAKE_BIN_LOG}"
EOF

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    grep -qxF "claude/install ran" "${FAKE_BIN_LOG}"
    run grep -qxF "lock fd inherited" "${FAKE_BIN_LOG}"
    [ "${status}" -eq 1 ]
}

@test "dev-update dies when XDG_RUNTIME_DIR is not set" {
    setup_dev_update_fixture
    run env -u XDG_RUNTIME_DIR "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"XDG_RUNTIME_DIR is not set"* ]]
}

@test "dev-update switches every reference repo to main and fast-forwards it, then runs each install step in order" {
    setup_dev_update_fixture
    cd "${BATS_TEST_TMPDIR}"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment updated"* ]]

    local _repo
    expected="$(
        for _repo in "${REFERENCE_REPOS[@]}"; do
            printf '%s\n' "git -C ${HOME}/work/reference/${_repo} rev-parse --show-toplevel"
            expected_reference_update "${_repo}"
        done
        printf '%s\n' \
            "systemctl --user daemon-reload" \
            "credfeto-setup-arch-desktop/install.d/dev-scripts "
        expected_published_step credfeto-global-pre-commit install
        expected_published_step claude install
        expected_published_step credfeto-ai-skills install
        expected_published_step credfeto-orchestrator install-claude-hooks
        printf '%s\n' \
            "update-dotnet-tools ${HOME}" \
            "systemctl --user start dev-update.timer"
    )"
    [ "$(logged_steps | mask_publish_names)" = "${expected}" ]
    refute_destructive_git
}

@test "dev-update dies on a reference clone with uncommitted changes, naming it, and runs nothing after" {
    setup_dev_update_fixture
    run env FAKE_GIT_DIRTY=cs-template "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Uncommitted changes in ${HOME}/work/reference/cs-template"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "git -C ${HOME}/work/reference/cs-template status --porcelain" ]
    refute_destructive_git
}

@test "dev-update dies naming a reference directory that is not a git clone, and never switches or pulls it" {
    setup_dev_update_fixture
    run env FAKE_GIT_NOT_TOPLEVEL=cs-template "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${HOME}/work/reference/cs-template exists but is not a git clone"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "git -C ${HOME}/work/reference/cs-template rev-parse --show-toplevel" ]
    refute_fake_called '^git -C [^ ]+/cs-template (status|switch|pull)'
    refute_fake_called '^credfeto-setup-arch-desktop/install\.d/dev-scripts'
}

@test "dev-update dies if a reference clone cannot be switched to main, and runs nothing after" {
    setup_dev_update_fixture
    run env FAKE_EXIT_git_switch=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to switch ${HOME}/work/reference/credfeto-setup-arch-desktop to main"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "git -C ${HOME}/work/reference/credfeto-setup-arch-desktop switch main" ]
    refute_destructive_git
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

@test "dev-update warns and still completes when starting the timer fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_systemctl_start=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not start dev-update.timer"* ]]
    [[ "${output}" != *"Could not reload systemd user units"* ]]
    [[ "${output}" == *"Dev environment updated"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "systemctl --user start dev-update.timer" ]
}

@test "dev-update starts the timer only once the lock is released" {
    setup_dev_update_fixture
    # The fake systemctl reports whether the lock is still held when the
    # timer is started; a timer started under the lock would fire at once
    # and have its service exit "already running".
    replace_fake systemctl <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
if [ "\$2" = "start" ]; then
    if flock -n ${XDG_RUNTIME_DIR@Q}/dev-update.lock true; then
        printf 'lock free at timer start\n' >> "\${FAKE_BIN_LOG}"
    else
        printf 'lock held at timer start\n' >> "\${FAKE_BIN_LOG}"
    fi
fi
[ "\$1" = "is-active" ] && [ "\$3" != "NetworkManager.service" ] && exit 1
exit 0
EOF

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    grep -qxF "lock free at timer start" "${FAKE_BIN_LOG}"
}

@test "dev-update does not reload systemd if a pull fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_git_pull=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    refute_fake_called '^systemctl --user daemon-reload'
}

@test "dev-update runs the reference clone's update-dotnet-tools from \$HOME, not the one on PATH" {
    setup_dev_update_fixture
    cd "${BATS_TEST_TMPDIR}"
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    grep -qxF "update-dotnet-tools ${HOME}" "${FAKE_BIN_LOG}"
    [[ "${output}" == *"Running ${HOME}/work/reference/credfeto-setup-arch-desktop/settings/scripts/general/update-dotnet-tools..."* ]]
    refute_fake_called '^PATH '
}

@test "dev-update dies if update-dotnet-tools fails" {
    setup_dev_update_fixture
    run env FAKE_EXIT_update_dotnet_tools=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to update dotnet tools"* ]]
    [[ "${output}" != *"Dev environment updated"* ]]
    refute_fake_called '^systemctl --user start '
}

@test "dev-update dies if a reference clone cannot be fast-forwarded, and runs nothing after" {
    setup_dev_update_fixture
    run env FAKE_EXIT_git_pull=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to fast-forward ${HOME}/work/reference/credfeto-setup-arch-desktop"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "git -C ${HOME}/work/reference/credfeto-setup-arch-desktop pull --ff-only" ]
    refute_destructive_git
}

@test "dev-update clones a missing reference repo over SSH before updating it" {
    setup_dev_update_fixture
    rm -rf "${HOME}/work/reference/cs-template"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment updated"* ]]

    local _ref="${HOME}/work/reference"
    grep -qxF "git clone git@github.com:credfeto/cs-template.git ${_ref}/cs-template" "${FAKE_BIN_LOG}"
    refute_fake_called 'https://'
    [ "$(grep -c '^git clone ' "${FAKE_BIN_LOG}")" -eq 1 ]
    [ "$(grep -n -m 1 -xF "git clone git@github.com:credfeto/cs-template.git ${_ref}/cs-template" "${FAKE_BIN_LOG}" | cut -d: -f1)" \
        -lt "$(grep -n -m 1 -xF "git -C ${_ref}/cs-template status --porcelain" "${FAKE_BIN_LOG}" | cut -d: -f1)" ]
}

@test "dev-update uses the reference tree DEV_REFERENCE_DIR points at" {
    setup_dev_update_fixture
    local _ref="${BATS_TEST_TMPDIR}/elsewhere"
    mv "${HOME}/work/reference" "${_ref}"

    run env DEV_REFERENCE_DIR="${_ref}" "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Publishing ${_ref}/claude to "* ]]
    [[ "${output}" == *"Running ${DEV_PUBLISH_DIR}/claude/install --system..."* ]]
    local _repo
    for _repo in "${REFERENCE_REPOS[@]}"; do
        grep -qxF "git -C ${_ref}/${_repo} pull --ff-only" "${FAKE_BIN_LOG}"
    done
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-update creates the reference tree when it is missing" {
    setup_dev_update_fixture
    # The fake clone copies from FAKE_CLONE_SOURCE into a parent that must
    # already exist, so this also proves dev-update creates the tree.
    cp -R "${HOME}/work/reference/." "${FAKE_CLONE_SOURCE}/"
    rm -rf "${HOME}/work/reference"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^git clone git@github\.com:' "${FAKE_BIN_LOG}")" -eq "${#REFERENCE_REPOS[@]}" ]
    local _repo
    for _repo in "${REFERENCE_REPOS[@]}"; do
        grep -qxF "git clone $(expected_clone_url "${_repo}") ${HOME}/work/reference/${_repo}" "${FAKE_BIN_LOG}"
    done
    refute_fake_called 'https://'
}

@test "dev-update dies if cloning a missing reference repo fails" {
    setup_dev_update_fixture
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
    local _index _failing _later
    for _index in "${!DEV_UPDATE_STEPS[@]}"; do
        _failing="${DEV_UPDATE_STEPS[_index]}"
        setup_dev_update_fixture
        make_logging_stub "${HOME}/work/reference" "${_failing}" 3

        run "${LINUX_DIR}/dev-update"
        [ "${status}" -eq 1 ]
        if [ "${_failing}" = "${DEV_UPDATE_STEPS[0]}" ]; then
            [[ "${output}" == *"Failed to run ${HOME}/work/reference/${_failing}"* ]]
        else
            [[ "${output}" == *"Failed to run ${DEV_PUBLISH_DIR}/${_failing}"* ]]
        fi
        for _later in "${DEV_UPDATE_STEPS[@]:_index+1}"; do
            refute_fake_called "^${_later//./\\.} "
        done
        refute_fake_called '^update-dotnet-tools'
        refute_fake_called '^systemctl --user start '

        rm -rf "${HOME}/work/reference" "${DEV_PUBLISH_DIR}"
    done
}

@test "dev-update dies if claude/install is missing or not executable" {
    local _break
    for _break in "rm" "chmod -x"; do
        setup_dev_update_fixture
        ${_break} "${HOME}/work/reference/claude/install"

        run "${LINUX_DIR}/dev-update"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"Not found or not executable: ${DEV_PUBLISH_DIR}/claude/install"* ]]
        refute_fake_called '^credfeto-ai-skills/install'
        refute_fake_called '^update-dotnet-tools'
        refute_fake_called '^systemctl --user start '

        rm -rf "${HOME}/work/reference" "${DEV_PUBLISH_DIR}"
    done
}

@test "dev-update runs a published installer with --system even when its text never mentions --system" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Running ${DEV_PUBLISH_DIR}/credfeto-orchestrator/install-claude-hooks --system..."* ]]
    assert_fake_called '^credfeto-orchestrator/install-claude-hooks --system$'
    assert_fake_called '^update-dotnet-tools '

    # The published copy dev-update ran, not the reference clone, is the one whose text must lack --system.
    run grep -q -e '--system' "${DEV_PUBLISH_DIR}/credfeto-orchestrator/install-claude-hooks"
    [ "${status}" -eq 1 ]
}

@test "dev-update runs each system installer from its published snapshot, not the reference clone" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Running ${DEV_PUBLISH_DIR}/claude/install --system..."* ]]
    [[ "${output}" != *"Running ${HOME}/work/reference/claude/install"* ]]
    local _repo
    for _repo in credfeto-global-pre-commit claude credfeto-ai-skills credfeto-orchestrator; do
        [ -L "${DEV_PUBLISH_DIR}/${_repo}" ]
        [[ "$(readlink "${DEV_PUBLISH_DIR}/${_repo}")" =~ ^${_repo}-[0-9]{8}T[0-9]{6}\.[0-9]+Z$ ]]
        assert_fake_called "^git -C ${HOME}/work/reference/${_repo} archive --format=tar -o [^ ]+ tree-0\$"
        assert_fake_called "^sudo chown -R root:root ${DEV_PUBLISH_DIR}/${_repo}-[0-9]{8}T[0-9]{6}\\.[0-9]+Z\$"
    done
    [ ! -e "${DEV_PUBLISH_DIR}/credfeto-setup-arch-desktop" ]
    [ -x "${DEV_PUBLISH_DIR}/claude/install" ]
    [ ! -e "${DEV_PUBLISH_DIR}/.claude.tmp" ]
    # Each snapshot it switched to is kept, not cleaned up as unfinished.
    refute_fake_called '^sudo rm -rf '
}

@test "dev-update publishes snapshots with directories readable by all but writable only by their owner" {
    setup_dev_update_fixture
    mkdir -p "${HOME}/work/reference/claude/nested"
    chmod 777 "${HOME}/work/reference/claude/nested"
    printf 'data\n' > "${HOME}/work/reference/claude/nested/file"
    chmod 666 "${HOME}/work/reference/claude/nested/file"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    local _snapshot
    _snapshot="${DEV_PUBLISH_DIR}/$(readlink "${DEV_PUBLISH_DIR}/claude")"
    [ "$(stat -c '%a' "${_snapshot}")" = "755" ]
    [ "$(stat -c '%a' "${_snapshot}/nested")" = "755" ]
    [ "$(stat -c '%a' "${_snapshot}/nested/file")" = "644" ]
    [ "$(stat -c '%a' "${_snapshot}/install")" = "755" ]
}

@test "dev-update creates a publish directory every account can read even under a strict umask" {
    setup_dev_update_fixture

    run sh -c 'umask 077 && exec "$1"' sh "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(stat -c '%a' "${DEV_PUBLISH_DIR}")" = "755" ]
    [ "$(stat -c '%a' "${DEV_PUBLISH_DIR}/$(readlink "${DEV_PUBLISH_DIR}/claude")")" = "755" ]
}

# The fake sudo logs the removal of a snapshot without running it, so the
# test asserts on the logged command rather than on the snapshot being gone.
# Each run publishes a different committed tree, as a run with nothing new
# keeps the snapshot it has.
@test "dev-update never prunes the snapshots of a sibling whose name starts with the repo's and a digit" {
    setup_dev_update_fixture
    # A sibling repo's current snapshot, named claude-2-<stamp>, which a looser
    # claude-<digit>...Z glob would also match.
    local _sibling="${DEV_PUBLISH_DIR}/claude-2-20000101T000000.000000000Z"
    mkdir -p "${_sibling}"
    ln -s "${_sibling##*/}" "${DEV_PUBLISH_DIR}/claude-2"
    # And one of claude's own, older than the two it keeps.
    local _old="${DEV_PUBLISH_DIR}/claude-20000101T000000.000000000Z"
    mkdir -p "${_old}"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    assert_fake_called "^sudo rm -rf ${_old}\$"
    refute_fake_called "^sudo rm -rf ${_sibling}\$"
    [ -d "${_sibling}" ]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude-2")" = "${_sibling##*/}" ]
}

@test "dev-update keeps the previous snapshot of a published repo and removes any older one" {
    setup_dev_update_fixture
    local _run _first _second _third
    for _run in 1 2 3; do
        run env FAKE_GIT_TREE="tree-${_run}" "${LINUX_DIR}/dev-update"
        [ "${status}" -eq 0 ]
        case "${_run}" in
            1) _first="$(readlink "${DEV_PUBLISH_DIR}/claude")" ;;
            2)
                _second="$(readlink "${DEV_PUBLISH_DIR}/claude")"
                refute_fake_called "^sudo rm -rf ${DEV_PUBLISH_DIR}/claude-"
                ;;
            3) _third="$(readlink "${DEV_PUBLISH_DIR}/claude")" ;;
        esac
    done

    [ "${_first}" != "${_second}" ]
    [ "${_second}" != "${_third}" ]
    # Through sudo although DEV_PUBLISH_DIR is writable, as each snapshot
    # belongs to root.
    [ -w "${DEV_PUBLISH_DIR}" ]
    assert_fake_called "^sudo rm -rf ${DEV_PUBLISH_DIR}/${_first}\$"
    refute_fake_called "^sudo rm -rf ${DEV_PUBLISH_DIR}/(${_second}|${_third})\$"
}

@test "dev-update dies, naming the snapshot, when removing an old snapshot fails, and runs nothing after it" {
    setup_dev_update_fixture
    local _old="${DEV_PUBLISH_DIR}/claude-20000101T000000.000000000Z"
    mkdir -p "${_old}"

    run env FAKE_SUDO_FAIL='^rm -rf .*/claude-' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to remove the old snapshot ${_old}"* ]]
    refute_fake_called '^claude/install'
    refute_fake_called '^systemctl --user start '

    # The clean-up of an unfinished snapshot is disarmed once the link is
    # switched, so the die in the prune leaves the new, live snapshot alone:
    # the only removal is the failed one of the old snapshot.
    local _live
    _live="$(readlink "${DEV_PUBLISH_DIR}/claude")"
    [ "${_live}" != "${_old##*/}" ]
    [ "$(grep -c '^sudo rm -rf ' "${FAKE_BIN_LOG}")" -eq 1 ]
    assert_fake_called "^sudo rm -rf ${_old}\$"
    refute_fake_called "^sudo rm -rf ${DEV_PUBLISH_DIR}/${_live}\$"
    [[ "${output}" != *"unfinished snapshot"* ]]
}

@test "dev-update dies if publishing a reference repo fails, and runs nothing after it" {
    setup_dev_update_fixture
    run env FAKE_SUDO_FAIL='^chown -R root:root .*/claude-' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"owned by root"* ]]
    assert_unswitched_snapshot_removed claude
    refute_fake_called '^claude/install'
    refute_fake_called '^update-dotnet-tools'
    refute_fake_called '^systemctl --user start '
}

teardown() {
    # Restored so bats can clean up a publish directory a test locked down.
    [ -z "${DEV_PUBLISH_DIR:-}" ] || chmod 755 "${DEV_PUBLISH_DIR}" 2>/dev/null || true
}

# The lock publish_reference_repo takes in DEV_PUBLISH_DIR.
publish_lock_file() {
    printf '%s/.publish.lock' "${DEV_PUBLISH_DIR}"
}

# Asserts the run removed, through sudo, the snapshot of the given repo it
# made but never switched to; the fake sudo logs it without running it.
# Usage: assert_unswitched_snapshot_removed <repo>
assert_unswitched_snapshot_removed() {
    assert_fake_called "^sudo rm -rf ${DEV_PUBLISH_DIR}/$1-[0-9]{8}T[0-9]{6}\\.[0-9]+Z\$"
}

# Asserts the run died before publishing or installing anything.
refute_any_publish() {
    [ -z "$(published_snapshots credfeto-global-pre-commit)" ]
    [ ! -e "${DEV_PUBLISH_DIR}/credfeto-global-pre-commit" ]
    refute_fake_called '^credfeto-global-pre-commit/install'
    refute_fake_called '^systemctl --user start '
}

# Makes DEV_PUBLISH_DIR read-only, so every change lib/common makes there
# goes through the fake sudo, which runs nothing; no run lock exists yet
# unless the caller made one first.
lock_down_publish_dir() {
    mkdir -p "${DEV_PUBLISH_DIR}"
    chmod 555 "${DEV_PUBLISH_DIR}"
}

@test "dev-update waits for the publish lock, then stops, naming it and publishing nothing, when another run never releases it" {
    setup_dev_update_fixture
    mkdir -p "${DEV_PUBLISH_DIR}"
    : > "$(publish_lock_file)"
    exec 7<"$(publish_lock_file)"
    flock -n 7

    run env RUN_LOCK_WAIT_SECONDS=1 "${LINUX_DIR}/dev-update"
    exec 7<&-
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Waiting up to 1s for another publish to release $(publish_lock_file)"* ]]
    [[ "${output}" == *"Timed out after 1s waiting for another publish to release $(publish_lock_file)"* ]]
    refute_any_publish
}

@test "dev-update waits for another run to release the publish lock, then publishes" {
    setup_dev_update_fixture
    mkdir -p "${DEV_PUBLISH_DIR}"
    : > "$(publish_lock_file)"
    hold_lock_in_background "$(publish_lock_file)" 10

    run env RUN_LOCK_WAIT_SECONDS=30 "${LINUX_DIR}/dev-update"
    wait "${LOCK_HOLDER_PID}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Waiting up to 30s for another publish to release $(publish_lock_file)"* ]]
    [ -L "${DEV_PUBLISH_DIR}/credfeto-global-pre-commit" ]
    assert_fake_called '^credfeto-global-pre-commit/install'
}

@test "dev-update fails, naming the lock, when creating the publish lock fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir

    run env FAKE_SUDO_FAIL='^touch ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create $(publish_lock_file)"* ]]
    refute_any_publish
}

@test "dev-update fails, naming the lock, when making the publish lock readable fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir

    run env FAKE_SUDO_FAIL='^chmod 0644 ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create $(publish_lock_file)"* ]]
    refute_any_publish
}

@test "dev-update dies, naming the repo, when a snapshot cannot be named, and publishes nothing" {
    setup_dev_update_fixture
    setup_fake_bin date

    run env FAKE_EXIT_date=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to name a snapshot of credfeto-global-pre-commit"* ]]
    refute_any_publish
}

# Makes DEV_PUBLISH_DIR read-only with the publish lock already in it, so a
# publish reaches its switch with every change routed through the fake sudo,
# which runs nothing and fails the command line matching FAKE_SUDO_FAIL.
lock_down_publish_dir_with_lock() {
    mkdir -p "${DEV_PUBLISH_DIR}"
    : > "$(publish_lock_file)"
    lock_down_publish_dir
}

@test "dev-update dies, naming the snapshot, when creating the switch link fails, and runs nothing after it" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir_with_lock

    run env FAKE_SUDO_FAIL='^ln -sfn ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create a link to ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    refute_fake_called '^sudo mv -T '
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    refute_any_publish
}

@test "dev-update dies, naming the link, when switching it to the new snapshot fails, and runs nothing after it" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir_with_lock

    run env FAKE_SUDO_FAIL='^mv -T ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to switch ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit to ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    # Only the unswitched snapshot is removed: no prune runs after a failed switch.
    [ "$(grep -c '^sudo rm -rf ' "${FAKE_BIN_LOG}")" -eq 1 ]
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    refute_any_publish
}

@test "dev-update removes the snapshot it was making when archiving the clone fails, and runs nothing after it" {
    setup_dev_update_fixture

    run env FAKE_EXIT_git_archive=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to archive ${HOME}/work/reference/credfeto-global-pre-commit"* ]]
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    [ ! -e "${DEV_PUBLISH_DIR}/credfeto-global-pre-commit" ]
    refute_fake_called '^credfeto-global-pre-commit/install'
    refute_fake_called '^systemctl --user start '
}

@test "dev-update removes the snapshot it was making when extracting the archive fails, and runs nothing after it" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir_with_lock

    run env FAKE_SUDO_FAIL='^tar -x ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to extract credfeto-global-pre-commit into ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    refute_any_publish
}

@test "dev-update removes the snapshot it was making when setting its permissions fails, and runs nothing after it" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir_with_lock

    run env FAKE_SUDO_FAIL='^chmod -R u=rwX,go=rX ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to set permissions on ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    refute_any_publish
}

@test "dev-update warns, still failing, when removing an unfinished snapshot fails" {
    setup_dev_update_fixture

    run env FAKE_EXIT_git_archive=1 FAKE_SUDO_FAIL='^rm -rf ' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to archive ${HOME}/work/reference/credfeto-global-pre-commit"* ]]
    [[ "${output}" == *"Failed to remove the unfinished snapshot ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    refute_fake_called '^systemctl --user start '
}

@test "dev-update dies, publishing nothing, when a folder stands where the publish link goes" {
    setup_dev_update_fixture
    local _link="${DEV_PUBLISH_DIR}/credfeto-global-pre-commit"
    mkdir -p "${_link}"
    : > "${_link}/hand-made"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${_link} exists but is not a symlink; move it aside, then re-run"* ]]
    [ ! -L "${_link}" ]
    [ -f "${_link}/hand-made" ]
    [ -z "$(published_snapshots credfeto-global-pre-commit)" ]
    refute_fake_called '^git -C .* archive '
    refute_fake_called '^sudo rm -rf '
    refute_fake_called '^credfeto-global-pre-commit/install'
    refute_fake_called '^systemctl --user start '
}

@test "dev-update records the committed tree in a hidden file at the root of each snapshot" {
    setup_dev_update_fixture
    run env FAKE_GIT_TREE=tree-a "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(cat "${DEV_PUBLISH_DIR}/claude/.published-tree")" = "tree-a" ]
}

@test "dev-update archives the tree it records, not HEAD" {
    setup_dev_update_fixture
    run env FAKE_GIT_TREE=tree-a "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    assert_fake_called "^git -C ${HOME}/work/reference/claude archive --format=tar -o [^ ]+ tree-a\$"
    refute_fake_called '^git -C .* archive .* HEAD$'
}

@test "dev-update publishes the tree it read even when HEAD moves while it waits for the publish lock" {
    setup_dev_update_fixture
    local _tree_file="${BATS_TEST_TMPDIR}/clone-tree"
    printf 'tree-before\n' > "${_tree_file}"
    mkdir -p "${DEV_PUBLISH_DIR}"
    : > "$(publish_lock_file)"
    hold_lock_in_background "$(publish_lock_file)" 10
    # Moves every clone's HEAD as soon as the first publish has read its
    # tree, while that publish waits for the lock.
    (
        _tries=0
        until grep -q 'credfeto-global-pre-commit rev-parse HEAD\^{tree}$' "${FAKE_BIN_LOG}" 2>/dev/null || [ "${_tries}" -ge 100 ]; do
            _tries=$((_tries + 1))
            sleep 0.1
        done
        printf 'tree-after\n' > "${_tree_file}"
    ) > /dev/null 2>&1 3>&- &
    local _mover=$!

    run env FAKE_GIT_TREE_FILE="${_tree_file}" RUN_LOCK_WAIT_SECONDS=30 "${LINUX_DIR}/dev-update"
    wait "${_mover}"
    wait "${LOCK_HOLDER_PID}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${DEV_PUBLISH_DIR}/credfeto-global-pre-commit/.published-tree")" = "tree-before" ]
    assert_fake_called "^git -C ${HOME}/work/reference/credfeto-global-pre-commit archive --format=tar -o [^ ]+ tree-before\$"
    refute_fake_called '^git -C .* archive .* HEAD$'
}

@test "dev-update keeps a snapshot that already holds the clone's committed tree, and still runs its installer" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_PUBLISH_DIR}/claude")"
    : > "${FAKE_BIN_LOG}"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${DEV_PUBLISH_DIR}/claude already holds the committed tree of ${HOME}/work/reference/claude; keeping it"* ]]
    [[ "${output}" != *"Publishing ${HOME}/work/reference/claude to "* ]]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude")" = "${_first}" ]
    [ "$(published_snapshots claude)" = "${_first}" ]
    refute_fake_called '^git -C .* archive '
    refute_fake_called '^sudo chown '
    refute_fake_called '^sudo rm -rf '
    assert_fake_called '^claude/install --system$'
    assert_fake_called '^systemctl --user start '
}

@test "dev-update publishes a new snapshot once the clone's committed tree changes" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_PUBLISH_DIR}/claude")"

    run env FAKE_GIT_TREE=tree-1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude")" != "${_first}" ]
    [ "$(cat "${DEV_PUBLISH_DIR}/claude/.published-tree")" = "tree-1" ]
}

@test "dev-update replaces a snapshot that has no record of its tree" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_PUBLISH_DIR}/claude")"
    # As a snapshot published before the record existed.
    rm "${DEV_PUBLISH_DIR}/${_first}/.published-tree"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude")" != "${_first}" ]
    [ -f "${DEV_PUBLISH_DIR}/claude/.published-tree" ]
}

@test "dev-update replaces a snapshot whose record of its tree is empty" {
    setup_dev_update_fixture
    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_PUBLISH_DIR}/claude")"
    : > "${DEV_PUBLISH_DIR}/${_first}/.published-tree"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude")" != "${_first}" ]
    [ "$(cat "${DEV_PUBLISH_DIR}/claude/.published-tree")" = "tree-0" ]
}

@test "dev-update publishes a new snapshot when the publish link dangles" {
    setup_dev_update_fixture
    mkdir -p "${DEV_PUBLISH_DIR}"
    ln -s claude-20000101T000000.000000000Z "${DEV_PUBLISH_DIR}/claude"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Publishing ${HOME}/work/reference/claude to "* ]]
    [ "$(readlink "${DEV_PUBLISH_DIR}/claude")" != "claude-20000101T000000.000000000Z" ]
    [ -f "${DEV_PUBLISH_DIR}/claude/.published-tree" ]
    assert_fake_called '^claude/install --system$'
}

@test "dev-update dies, publishing nothing, when the clone's committed tree cannot be read" {
    setup_dev_update_fixture

    run env FAKE_EXIT_git_rev_parse_tree=1 "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to read the committed tree of ${HOME}/work/reference/credfeto-global-pre-commit"* ]]
    refute_any_publish
}

@test "dev-update removes the snapshot it was making when recording its tree fails, and runs nothing after it" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    setup_dev_update_fixture
    lock_down_publish_dir_with_lock

    run env FAKE_SUDO_FAIL='^tee .*/\.published-tree$' "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to record the published tree in ${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-"* ]]
    assert_unswitched_snapshot_removed credfeto-global-pre-commit
    refute_any_publish
}

@test "dev-update refuses a snapshot name that already exists, leaving that folder alone" {
    setup_dev_update_fixture
    local _taken="${DEV_PUBLISH_DIR}/credfeto-global-pre-commit-20000101T000000.000000000Z"
    mkdir -p "${_taken}"
    : > "${_taken}/kept"
    setup_fake_bin date
    seed_fake_output date <<< "20000101T000000.000000000Z"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${_taken} already exists; move it aside, then re-run"* ]]
    [ -f "${_taken}/kept" ]
    refute_fake_called '^sudo rm -rf '
    refute_fake_called '^credfeto-global-pre-commit/install'
}

@test "dev-update fails, naming the lock, when the publish lock cannot be opened" {
    [ "$(id -u)" -ne 0 ] || skip "root can read a file with no permissions"
    setup_dev_update_fixture
    mkdir -p "${DEV_PUBLISH_DIR}"
    : > "$(publish_lock_file)"
    chmod 000 "$(publish_lock_file)"
    lock_down_publish_dir

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to open $(publish_lock_file)"* ]]
    refute_any_publish
}

# ── dev-install ──────────────────────────────────────────────────────────────

# Online under NetworkManager with dotnet present. The cloned
# credfeto-setup-arch-desktop carries the real units/dev-update and
# lib/common, so its units install runs for real against the fake
# systemctl, plus a logging stub in place of dev-update.
# install-dotnet-tools logs the directory it was run from. Pass another
# active unit (as for setup_fake_network) to change the network manager.
# id reports a normal user, and the fake systemctl answers the session probe,
# so the preflight passes whoever runs the tests.
# Usage: setup_dev_install_fixture [<active-unit>]
setup_dev_install_fixture() {
    setup_fake_network "${1:-NetworkManager.service}" dotnet id
    seed_fake_output id <<< "1000"
    setup_fake_git

    local _clone="${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop"
    mkdir -p "${_clone}/units"
    cp -R "${REPO_DIR}/lib" "${_clone}/lib"
    cp -R "${REPO_DIR}/units/dev-update" "${_clone}/units/dev-update"
    make_logging_stub "${_clone}" settings/scripts/linux/dev-update
    make_cwd_logging_stub "${_clone}" settings/scripts/general/install-dotnet-tools \
        FAKE_EXIT_install_dotnet_tools
}

@test "dev-install dies inside a Claude Code session" {
    setup_dev_install_fixture
    run env CLAUDECODE=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must not be run from a Claude Code session"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install dies as root, saying to run it as the normal user, before cloning anything" {
    setup_dev_install_fixture
    seed_fake_output id <<< "0"
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"dev-install must not be run as root; run it as your normal user, as it calls sudo itself"* ]]
    [ -z "$(logged_steps)" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install dies when the systemd user manager cannot be reached, saying to run it from a logged-in session, before cloning anything" {
    setup_dev_install_fixture
    run env FAKE_EXIT_systemctl=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Cannot reach your systemd user manager; run dev-install from a logged-in session"* ]]
    assert_fake_called '^systemctl --user show-environment$'
    [ -z "$(logged_steps)" ]
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

@test "dev-install dies when neither network manager is active, before cloning anything" {
    setup_dev_install_fixture none
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No supported network manager (NetworkManager or systemd-networkd) is running"* ]]
    [[ "${output}" != *"No network connection"* ]]
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
        grep -qxF "git clone $(expected_clone_url "${_repo}") ${HOME}/work/reference/${_repo}" "${FAKE_BIN_LOG}"
    done
    refute_fake_called 'https://'
}

@test "dev-install clones claude from dnyw4l3n13 and the other reference repos from credfeto, into owner-free paths" {
    setup_dev_install_fixture
    cd "${BATS_TEST_TMPDIR}"

    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]

    local _ref="${HOME}/work/reference"
    grep -qxF "git clone git@github.com:dnyw4l3n13/claude.git ${_ref}/claude" "${FAKE_BIN_LOG}"
    refute_fake_called '^git clone git@github\.com:credfeto/claude\.git'
    [ "$(grep -c '^git clone git@github\.com:credfeto/' "${FAKE_BIN_LOG}")" -eq 5 ]
    [ "$(grep -c '^git clone git@github\.com:dnyw4l3n13/' "${FAKE_BIN_LOG}")" -eq 1 ]
    refute_fake_called 'https://'
}

@test "dev-install clones each reference repo, switches it to main and fast-forwards it, then installs in order" {
    setup_dev_install_fixture
    cd "${BATS_TEST_TMPDIR}"

    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]

    local _repo
    expected="$(
        for _repo in "${REFERENCE_REPOS[@]}"; do
            printf '%s\n' "git clone $(expected_clone_url "${_repo}") ${HOME}/work/reference/${_repo}"
            expected_reference_update "${_repo}"
        done
        printf '%s\n' \
            "install-dotnet-tools ${HOME}" \
            "systemctl --user daemon-reload" \
            "systemctl --user enable dev-update.timer" \
            "settings/scripts/linux/dev-update --fail-if-running"
    )"
    [ "$(logged_steps)" = "${expected}" ]
    refute_destructive_git
}

@test "dev-install switches an already-present reference clone to main and fast-forwards it before running the units installer" {
    setup_dev_install_fixture
    mkdir -p "${HOME}/work/reference"
    cp -R "${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop" "${HOME}/work/reference/credfeto-setup-arch-desktop"

    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]

    local _path="${HOME}/work/reference/credfeto-setup-arch-desktop"
    refute_fake_called '^git clone .*/credfeto-setup-arch-desktop\.git'
    [ "$(grep -A 2 -xF "git -C ${_path} status --porcelain" "${FAKE_BIN_LOG}")" = "$(expected_reference_update credfeto-setup-arch-desktop)" ]
    [ "$(grep -n -m 1 -xF "git -C ${_path} pull --ff-only" "${FAKE_BIN_LOG}" | cut -d: -f1)" \
        -lt "$(grep -n -m 1 -xF "systemctl --user daemon-reload" "${FAKE_BIN_LOG}" | cut -d: -f1)" ]
    refute_destructive_git
}

@test "dev-install dies on a reference clone that is dirty, cannot be switched to main or cannot be fast-forwarded, and runs nothing after" {
    local _path _case _override _message _last
    for _case in dirty switch pull; do
        setup_dev_install_fixture
        mkdir -p "${HOME}/work/reference/claude"
        _path="${HOME}/work/reference/claude"
        case "${_case}" in
            dirty)
                _override="FAKE_GIT_DIRTY=claude"
                _message="Uncommitted changes in ${_path}"
                _last="git -C ${_path} status --porcelain"
                ;;
            switch)
                _override="FAKE_EXIT_git_switch=1"
                _message="Failed to switch ${HOME}/work/reference/credfeto-setup-arch-desktop to main"
                _last="git -C ${HOME}/work/reference/credfeto-setup-arch-desktop switch main"
                ;;
            pull)
                _override="FAKE_EXIT_git_pull=1"
                _message="Failed to fast-forward ${HOME}/work/reference/credfeto-setup-arch-desktop"
                _last="git -C ${HOME}/work/reference/credfeto-setup-arch-desktop pull --ff-only"
                ;;
        esac

        run env "${_override}" "${LINUX_DIR}/dev-install"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"${_message}"* ]]
        [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "${_last}" ]
        refute_destructive_git

        rm -rf "${HOME}/work/reference" "${FAKE_CLONE_SOURCE}"
    done
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

@test "dev-install runs the reference clone's install-dotnet-tools from \$HOME, not the one on PATH" {
    setup_dev_install_fixture
    cd "${BATS_TEST_TMPDIR}"
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    grep -qxF "install-dotnet-tools ${HOME}" "${FAKE_BIN_LOG}"
    [[ "${output}" == *"Running ${HOME}/work/reference/credfeto-setup-arch-desktop/settings/scripts/general/install-dotnet-tools..."* ]]
    refute_fake_called '^PATH '
}

@test "dev-install dies if install-dotnet-tools fails" {
    setup_dev_install_fixture
    run env FAKE_EXIT_install_dotnet_tools=1 "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to install dotnet tools"* ]]
    refute_fake_called '^systemctl --user (daemon-reload|enable)'
}

@test "dev-install symlinks the units from the reference clone and enables the timer" {
    setup_dev_install_fixture
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]

    assert_dev_update_units_linked_to "${HOME}/work/reference/credfeto-setup-arch-desktop/units/dev-update"
    assert_fake_called '^systemctl --user daemon-reload$'
    assert_fake_called '^systemctl --user enable dev-update\.timer$'
}

@test "dev-install runs the reference clone's dev-update as its last step and leaves starting the timer to it" {
    setup_dev_install_fixture
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "settings/scripts/linux/dev-update --fail-if-running" ]
    refute_fake_called '^systemctl --user start '
}

@test "dev-install dies, saying to re-run it, when another dev-update holds the lock" {
    setup_dev_install_fixture
    # The clone's real dev-update, so the held lock is met as in a real run.
    cp "${LINUX_DIR}/dev-update" "${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop/settings/scripts/linux/dev-update"
    exec 8>"${XDG_RUNTIME_DIR}/dev-update.lock"
    flock -n 8

    run "${LINUX_DIR}/dev-install"

    exec 8>&-
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Another dev-update is running; re-run dev-install when it finishes"* ]]
    [[ "${output}" != *"dev-update is already running"* ]]
    [[ "${output}" != *"Dev environment installed"* ]]
    refute_fake_called '^systemctl --user start '
}

@test "dev-install dies before doing anything when DEV_REFERENCE_DIR is not the default, naming the default" {
    setup_dev_install_fixture
    local _ref="${BATS_TEST_TMPDIR}/elsewhere"
    run env DEV_REFERENCE_DIR="${_ref}" "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DEV_REFERENCE_DIR is set to ${_ref}, but only the default ${HOME}/work/reference is supported"* ]]
    [ ! -s "${FAKE_BIN_LOG}" ]
    [ ! -e "${_ref}" ]
    [ ! -e "${HOME}/work/reference" ]
}

@test "dev-install accepts DEV_REFERENCE_DIR set to the default" {
    setup_dev_install_fixture
    run env DEV_REFERENCE_DIR="${HOME}/work/reference" "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev environment installed"* ]]
}

@test "dev-install dies if dev-update fails" {
    setup_dev_install_fixture
    make_logging_stub "${FAKE_CLONE_SOURCE}/credfeto-setup-arch-desktop" settings/scripts/linux/dev-update 1
    run "${LINUX_DIR}/dev-install"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to run"*"settings/scripts/linux/dev-update"* ]]
    refute_fake_called '^systemctl --user start '
}

# ── install-fp ───────────────────────────────────────────────────────────────

@test "install-fp installs every candidate flatpak package" {
    setup_fake_bin flatpak
    run "${LINUX_DIR}/install-fp"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak install -y com\.brave\.Browser$'
    assert_fake_called '^flatpak install -y org\.mozilla\.firefox$'
    assert_fake_called '^flatpak install -y com\.opera\.Opera$'
    assert_fake_called '^flatpak install -y com\.discordapp\.Discord$'
    assert_fake_called '^flatpak install -y com\.spotify\.Client$'
    assert_fake_called '^flatpak install -y com\.todoist\.Todoist$'
    assert_fake_called '^flatpak install -y com\.bitwarden\.desktop$'
    assert_fake_called '^flatpak install -y org\.mozilla\.Thunderbird$'
    assert_fake_called '^flatpak install -y com\.github\.iwalton3\.jellyfin-media-player$'
    assert_fake_called '^flatpak install -y com\.ktechpit\.whatsie$'
    [ "$(grep -c '^flatpak install -y ' "${FAKE_BIN_LOG}")" -eq 10 ]
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
    # Any further arguments are more tools to fake via setup_fake_bin.
    setup_fake_bin "${@:2}"
    replace_fake flatpak <<EOF
#!/bin/sh
printf 'flatpak %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
if [ "\$1 \$2" = "list --app" ]; then
    printf '%s\n' "$1"
fi
exit 0
EOF
}

# Runs login with a PATH of the fakes plus links to only the host tools login
# itself uses, so whether streamlink and stream are installed on the host
# cannot change what it does: a real stream never exits and would hold bats'
# output open.
run_login() {
    local _host_tools="${BATS_TEST_TMPDIR}/login-host-tools" _tool
    mkdir -p "${_host_tools}"
    for _tool in dirname readlink grep; do
        ln -sf "$(type -P "${_tool}")" "${_host_tools}/${_tool}"
    done
    run env PATH="${FAKE_BIN_DIR}:${_host_tools}" "${LINUX_DIR}/login"
}

@test "login only launches candidate apps that are actually installed" {
    setup_fake_flatpak_with_installed "$(printf 'com.discordapp.Discord\norg.mozilla.firefox\ncom.some.UnrelatedApp')"
    run_login
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
    assert_fake_called '^flatpak run org\.mozilla\.firefox$'
    refute_fake_called '^flatpak run com\.some\.UnrelatedApp'
    refute_fake_called '^flatpak run com\.spotify\.Client'
    [[ "${output}" == *"Login complete"* ]]
}

@test "login gives Brave its Ozone/Wayland flags, no other app gets them" {
    setup_fake_flatpak_with_installed "$(printf 'com.brave.Browser\ncom.discordapp.Discord')"
    run_login
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.brave\.Browser --enable-feature=UseOzonePlatform --ozone-platform=wayland'
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
}

@test "login starts the paults_aquaescape stream only when streamlink is installed" {
    setup_fake_flatpak_with_installed "" stream
    run_login
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"streamlink found"* ]]
    refute_fake_called '^stream '
}

@test "login starts the stream when streamlink is present" {
    setup_fake_flatpak_with_installed "" streamlink stream

    run_login
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"streamlink found, starting stream"* ]]
    assert_fake_called '^stream paults_aquaescape$'
}

# -- tmux-here ----------------------------------------------------------------

# A fake tmux that logs every call and reports has-session as failing (no
# session) unless the marker file $BATS_TEST_TMPDIR/session-exists is present.
setup_fake_tmux() {
    # FAKE_EXIT_tmux would apply to every subcommand of the stock fake, so
    # this one is written out to fail only has-session.
    replace_fake tmux <<EOF
#!/bin/sh
printf 'tmux %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
if [ "\$1" = "has-session" ] && [ ! -f ${BATS_TEST_TMPDIR@Q}/session-exists ]; then
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

@test "a fake reads its marker file under a temporary directory whose name holds a quote, a dollar and a backslash" {
    local BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR}/odd\"\$name\\dir"
    mkdir -p "${BATS_TEST_TMPDIR}/proj"
    setup_fake_tmux
    touch "${BATS_TEST_TMPDIR}/session-exists"
    cd "${BATS_TEST_TMPDIR}/proj"

    run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    refute_fake_called 'new-session'
    assert_fake_called '^tmux attach-session -t =proj-[0-9]+$'
}
