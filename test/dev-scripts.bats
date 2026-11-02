#!/usr/bin/env bats
# Acceptance tests for install.d/dev-scripts and install.d/git-environment.

load test_helper

DEV_SCRIPTS="${REPO_DIR}/install.d/dev-scripts"
GIT_ENVIRONMENT="${REPO_DIR}/install.d/git-environment"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # git-environment writes the global config, so it gets one of the test's
    # own in place of the none test_helper gives every suite.
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
    # DEV_SCRIPTS_BIN_DIR is user-writable, so dev-scripts's sudo-avoidance
    # path is exercised - no real root/sudo needed for these tests.
    export DEV_SCRIPTS_BIN_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${DEV_SCRIPTS_BIN_DIR}"
    # Likewise user-writable; only the chown of each copy to root goes through
    # the fake sudo, which logs it without running it.
    export DEV_SCRIPTS_LIB_DIR="${BATS_TEST_TMPDIR}/lib/credfeto-setup-arch-desktop"
    setup_fake_sudo
    # The throwaway repo tree run_dev_scripts_against_fake_repo runs in.
    FAKE_SCRIPTS_REPO="${BATS_TEST_TMPDIR}/fake-scripts-repo"
}

@test "dev-scripts symlinks every executable script into the bin dir" {
    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbenv" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/login" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/buildcheck" ]
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/dbenv")" = "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbenv" ]
    [[ "$(readlink -f "${DEV_SCRIPTS_BIN_DIR}/dbenv")" != "${REPO_DIR}/"* ]]
}

# The run lock dev-scripts takes beside DEV_SCRIPTS_LIB_DIR.
dev_scripts_lock_file() {
    printf '%s/.%s.lock' "$(dirname "${DEV_SCRIPTS_LIB_DIR}")" "$(basename "${DEV_SCRIPTS_LIB_DIR}")"
}

# The versioned copies made beside DEV_SCRIPTS_LIB_DIR, oldest first.
lib_copies() {
    find "$(dirname "${DEV_SCRIPTS_LIB_DIR}")" -mindepth 1 -maxdepth 1 -type d -name "$(basename "${DEV_SCRIPTS_LIB_DIR}")-*Z" -printf '%f\n' | sort
}

@test "dev-scripts copies lib and every script folder into a root-owned versioned folder" {
    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_LIB_DIR}" ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/lib/common" ]
    local _dir
    for _dir in db development general git linux; do
        [ -d "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/${_dir}" ]
    done
    [ -x "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbenv" ]
    [ "$(lib_copies | wc -l)" -eq 1 ]
    assert_fake_called "^sudo chown -R root:root ${DEV_SCRIPTS_LIB_DIR}-[0-9]{8}T[0-9]{6}\\.[0-9]+Z\$"
    # The copy it switched to is kept, not cleaned up as unfinished.
    refute_fake_called '^sudo rm -rf '
}

# Copies install.d/dev-scripts and lib/common into a throwaway fake repo
# tree at FAKE_SCRIPTS_REPO, so a test can populate settings/scripts/ with
# fixtures without touching the real repo tree. dev-scripts copies only what
# git tracks, so the first call makes the tree a git repo and tracks
# everything in it then; a file a test adds afterwards stays untracked.
prepare_fake_repo() {
    mkdir -p "${FAKE_SCRIPTS_REPO}/lib" "${FAKE_SCRIPTS_REPO}/install.d"
    cp "${REPO_DIR}/lib/common" "${FAKE_SCRIPTS_REPO}/lib/common"
    cp "${DEV_SCRIPTS}" "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    chmod +x "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"

    if [ ! -e "${FAKE_SCRIPTS_REPO}/.git" ]; then
        git init --quiet "${FAKE_SCRIPTS_REPO}"
        git -C "${FAKE_SCRIPTS_REPO}" add -A
    fi
}

# Prepares the fake repo, then runs the copied dev-scripts against it.
run_dev_scripts_against_fake_repo() {
    prepare_fake_repo

    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
}

@test "dev-scripts copies only tracked files, leaving out untracked and ignored ones" {
    add_fake_dev_script
    printf 'secret.conf\n' > "${FAKE_SCRIPTS_REPO}/.gitignore"
    printf 'password\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/secret.conf"
    prepare_fake_repo
    printf 'notes\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/notes.txt"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/untracked-tool"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/untracked-tool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/lib/common" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/secret.conf" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/notes.txt" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/untracked-tool" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/untracked-tool" ]
}

@test "dev-scripts copies the working-tree content of a tracked file, including an uncommitted edit" {
    add_fake_dev_script
    prepare_fake_repo
    printf '#!/bin/sh\necho edited\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(cat "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool")" = "$(printf '#!/bin/sh\necho edited')" ]
}

@test "dev-scripts skips a tracked file deleted from the working tree" {
    add_fake_dev_script
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/gone-tool"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/gone-tool"
    prepare_fake_repo
    rm "${FAKE_SCRIPTS_REPO}/settings/scripts/db/gone-tool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/gone-tool" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/gone-tool" ]
}

@test "dev-scripts makes a new copy without a file once it is no longer tracked" {
    add_fake_dev_script
    printf 'data\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-data"
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-data" ]
    local _first
    _first="$(readlink "${DEV_SCRIPTS_LIB_DIR}")"

    git -C "${FAKE_SCRIPTS_REPO}" rm --cached --quiet settings/scripts/db/dbtool-data
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ -f "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-data" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-data" ]
}

@test "dev-scripts copies a tracked executable in a subfolder of a source folder but does not link it" {
    add_fake_dev_script
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db/helpers"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/helpers/nested-tool"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/helpers/nested-tool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(stat -c '%a' "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/helpers/nested-tool")" = "755" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbtool" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/nested-tool" ]
}

@test "dev-scripts dies, changing nothing, when no file under lib or the script folders is tracked" {
    add_fake_dev_script
    prepare_fake_repo
    git -C "${FAKE_SCRIPTS_REPO}" rm -r --cached --quiet lib settings

    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No tracked files to copy under ${FAKE_SCRIPTS_REPO}"* ]]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    [ -z "$(ls -A "${DEV_SCRIPTS_BIN_DIR}")" ]
}

@test "dev-scripts dies, changing nothing, when it is not run from a git checkout" {
    add_fake_dev_script
    prepare_fake_repo
    rm -rf "${FAKE_SCRIPTS_REPO}/.git"

    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${FAKE_SCRIPTS_REPO} is not a git checkout"* ]]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    [ -z "$(ls -A "${DEV_SCRIPTS_BIN_DIR}")" ]
}

@test "dev-scripts dies on a basename collision across source directories" {
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db" "${FAKE_SCRIPTS_REPO}/settings/scripts/development"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dup"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/development/dup"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dup" "${FAKE_SCRIPTS_REPO}/settings/scripts/development/dup"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Duplicate script name"* ]]
    [[ "${output}" == *"dup"* ]]
}

@test "dev-scripts does not link a non-executable sibling data file" {
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
    # Non-executable data file living alongside a real script, e.g. a
    # config/template file a script reads - must not be linked into
    # DEV_SCRIPTS_BIN_DIR as if it were a standalone command.
    printf 'not a script\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-config"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbtool" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/dbtool-config" ]
}

# A fixture script that finds lib/common the way the real scripts do, three
# folders up from its own real path, and fails when it cannot source it.
# Usage: add_fake_lib_script <name>
add_fake_lib_script() {
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db"
    cat > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/$1" <<'EOF'
#!/bin/sh
SCRIPTDIR="$(dirname "$(readlink -f "$0")")"
BASEDIR="$(dirname "$(dirname "$(dirname "$SCRIPTDIR")")")"
. "$BASEDIR/lib/common" || exit 1
success "$(basename "$0") ran"
EOF
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/$1"
}

@test "dev-scripts copies every file with an explicit mode, whatever the umask" {
    add_fake_lib_script dbtool
    printf 'not a script\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-config"
    chmod 600 "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-config"
    chmod 700 "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"

    umask 027
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(stat -c %a "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool")" = "755" ]
    [ "$(stat -c %a "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-config")" = "644" ]
    [ "$(stat -c %a "${DEV_SCRIPTS_LIB_DIR}/lib/common")" = "644" ]
    [ "$(stat -c %a "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db")" = "755" ]
    [ "$(stat -c %a "$(readlink -f "${DEV_SCRIPTS_LIB_DIR}")")" = "755" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/dbtool-config" ]
}

@test "dev-scripts links still run once the source checkout is unreadable" {
    [ "$(id -u)" -ne 0 ] || skip "root can read an unreadable directory"
    add_fake_lib_script dbtool

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    chmod 000 "${FAKE_SCRIPTS_REPO}"

    run "${DEV_SCRIPTS_BIN_DIR}/dbtool"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dbtool ran"* ]]
}

@test "dev-scripts replaces a link into the checkout with one into the lib folder" {
    add_fake_lib_script dbtool
    ln -s "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool" "${DEV_SCRIPTS_BIN_DIR}/dbtool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/dbtool")" = "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

@test "dev-scripts removes a live link into another checkout for a script it does not install" {
    add_fake_dev_script
    # A script that exists only on a branch of another checkout, linked by an
    # earlier install from there; it still resolves, into that home folder.
    local _branch_scripts="${BATS_TEST_TMPDIR}/${OTHER_CHECKOUT_SCRIPTS}/db"
    mkdir -p "${_branch_scripts}"
    printf '#!/bin/sh\nexit 0\n' > "${_branch_scripts}/branch-tool"
    chmod +x "${_branch_scripts}/branch-tool"
    ln -s "${_branch_scripts}/branch-tool" "${DEV_SCRIPTS_BIN_DIR}/branch-tool"
    ln -s /bin/true "${DEV_SCRIPTS_BIN_DIR}/unrelated"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/branch-tool" ]
    [ ! -L "${DEV_SCRIPTS_BIN_DIR}/branch-tool" ]
    [ -f "${_branch_scripts}/branch-tool" ]
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/unrelated")" = "/bin/true" ]
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/dbtool")" = "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

@test "dev-scripts keeps a live link into the lib folder" {
    add_fake_dev_script
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    : > "${FAKE_BIN_LOG}"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Removing stale symlink"* ]]
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/dbtool")" = "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

@test "dev-scripts prunes the link of a script removed since the last install" {
    add_fake_lib_script dbtool
    add_fake_lib_script oldtool
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/oldtool" ]

    rm "${FAKE_SCRIPTS_REPO}/settings/scripts/db/oldtool"
    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    [ "${status}" -eq 0 ]
    [ ! -L "${DEV_SCRIPTS_BIN_DIR}/oldtool" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbtool" ]
}

# The fake sudo logs the removal of a copy without running it, so a test
# asserts on the logged command rather than on the copy being gone.
# Each run edits dbtool first, as a run with nothing changed keeps the copy.
@test "dev-scripts switches to a new copy on each changed run, keeping only the previous one" {
    add_fake_lib_script dbtool
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_SCRIPTS_LIB_DIR}")"

    printf '# run 2\n' >> "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    [ "${status}" -eq 0 ]
    local _second
    _second="$(readlink "${DEV_SCRIPTS_LIB_DIR}")"
    [ "${_second}" != "${_first}" ]
    [ "$(lib_copies)" = "$(printf '%s\n' "${_first}" "${_second}" | sort)" ]
    refute_fake_called '^sudo rm -rf '

    printf '# run 3\n' >> "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
    run "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts"
    [ "${status}" -eq 0 ]
    local _third _lib_parent
    _third="$(readlink "${DEV_SCRIPTS_LIB_DIR}")"
    _lib_parent="$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    # Through sudo although the folder holding the copies is writable, as
    # each copy belongs to root.
    [ -w "${_lib_parent}" ]
    assert_fake_called "^sudo rm -rf ${_lib_parent}/${_first}\$"
    refute_fake_called "^sudo rm -rf ${_lib_parent}/(${_second}|${_third})\$"
    [ ! -e "$(dirname "${DEV_SCRIPTS_LIB_DIR}")/.$(basename "${DEV_SCRIPTS_LIB_DIR}").tmp" ]

    run "${DEV_SCRIPTS_BIN_DIR}/dbtool"
    [ "${status}" -eq 0 ]
}

@test "dev-scripts keeps the current copy when nothing has changed, but still checks the links" {
    add_fake_dev_script
    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    local _first
    _first="$(readlink "${DEV_SCRIPTS_LIB_DIR}")"
    rm "${DEV_SCRIPTS_BIN_DIR}/dbtool"
    : > "${FAKE_BIN_LOG}"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${DEV_SCRIPTS_LIB_DIR} already matches the checkout; keeping it"* ]]
    [[ "${output}" != *"Copying dev scripts"* ]]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" = "${_first}" ]
    [ "$(lib_copies)" = "${_first}" ]
    refute_fake_called '^sudo '
    [ "$(readlink "${DEV_SCRIPTS_BIN_DIR}/dbtool")" = "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

# Runs dev-scripts against the fake repo once, so a test can change the
# checkout and run it again; prints the copy the first run switched to.
# Run directly rather than through run, so this helper never reads status.
first_copy_of_fake_repo() {
    add_fake_dev_script
    printf 'data\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-data"
    prepare_fake_repo
    "${FAKE_SCRIPTS_REPO}/install.d/dev-scripts" > /dev/null 2>&1 || return 1
    readlink "${DEV_SCRIPTS_LIB_DIR}"
}

@test "dev-scripts makes a new copy when a tracked file's content changes" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    printf 'changed\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-data"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ "$(cat "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-data")" = "changed" ]
}

@test "dev-scripts makes a new copy when a tracked file's execute bit changes" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-data"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ "$(stat -c '%a' "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-data")" = "755" ]
}

@test "dev-scripts makes a new copy when an executable file stops being executable" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    chmod -x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ "$(stat -c '%a' "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool")" = "644" ]
}

@test "dev-scripts makes a new copy when a file starts being tracked" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    printf 'more\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool-more"
    git -C "${FAKE_SCRIPTS_REPO}" add settings/scripts/db/dbtool-more

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool-more" ]
}

# Replaces find with one that lists everything the real find does but then
# exits 1, as find does when it meets a folder it cannot read part-way
# through, so only its status shows the listing cannot be trusted.
fail_find_after_listing() {
    local _real_find
    _real_find="$(command -v find)"
    replace_fake find <<EOF
#!/bin/sh
"${_real_find}" "\$@"
exit 1
EOF
}

@test "dev-scripts makes a new copy when it cannot list all of the current one" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    fail_find_after_listing

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

@test "dev-scripts makes a new copy when the lib link dangles" {
    local _first
    _first="$(first_copy_of_fake_repo)"
    rm -rf "$(dirname "${DEV_SCRIPTS_LIB_DIR}")/${_first:?}"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DEV_SCRIPTS_LIB_DIR}")" != "${_first}" ]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/dbtool" ]
}

@test "dev-scripts prunes a stale symlink left by a renamed/removed script, leaves unrelated symlinks alone" {
    # A symlink from a prior run, pointing at a script that no longer exists.
    ln -s "${REPO_DIR}/settings/scripts/db/no-longer-here" "${DEV_SCRIPTS_BIN_DIR}/no-longer-here"
    # An unrelated symlink this script must not touch.
    ln -s /bin/true "${DEV_SCRIPTS_BIN_DIR}/unrelated"

    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/no-longer-here" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/unrelated" ]
}

# Links made by earlier versions point into whichever checkout ran
# dev-scripts last, so a run from one must also prune the other's links,
# live or dangling. The other checkout lives outside REPO_DIR.
OTHER_CHECKOUT_SCRIPTS="other-checkout/credfeto-setup-arch-desktop/settings/scripts"

@test "dev-scripts prunes a dangling symlink into another checkout's settings/scripts" {
    local _scripts="${BATS_TEST_TMPDIR}/${OTHER_CHECKOUT_SCRIPTS}"
    mkdir -p "${_scripts}/db"
    # The script was removed from a checkout that still exists.
    ln -s "${_scripts}/db/removed-script" "${DEV_SCRIPTS_BIN_DIR}/removed-script"
    # The whole checkout is gone, so not even its directories resolve.
    ln -s "${BATS_TEST_TMPDIR}/deleted/credfeto-setup-arch-desktop/settings/scripts/db/gone" "${DEV_SCRIPTS_BIN_DIR}/gone"

    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ ! -L "${DEV_SCRIPTS_BIN_DIR}/removed-script" ]
    [ ! -L "${DEV_SCRIPTS_BIN_DIR}/gone" ]
}

@test "dev-scripts keeps a dangling symlink that points outside any settings/scripts tree" {
    ln -s "${BATS_TEST_TMPDIR}/unrelated-tool/bin/missing" "${DEV_SCRIPTS_BIN_DIR}/missing"
    ln -s "${BATS_TEST_TMPDIR}/other-repo/settings/scripts/db/missing-too" "${DEV_SCRIPTS_BIN_DIR}/missing-too"

    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/missing" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/missing-too" ]
}

@test "dev-scripts is idempotent - a second run leaves the same set of symlinks" {
    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    first_count=$(find "${DEV_SCRIPTS_BIN_DIR}" -maxdepth 1 -type l | wc -l)

    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    second_count=$(find "${DEV_SCRIPTS_BIN_DIR}" -maxdepth 1 -type l | wc -l)

    [ "${first_count}" -eq "${second_count}" ]
}

# Puts a fake sudo first on PATH that exits 1 when its first argument (the
# wrapped command) is the given name, and exits 0 without doing anything
# otherwise, then makes DEV_SCRIPTS_BIN_DIR read-only so dev-scripts routes
# its changes through sudo. Lets a test fail exactly one dev_scripts_sudo
# step without any real root/sudo.
# Usage: fail_sudo_for <command-name>
fail_sudo_for() {
    replace_fake sudo <<EOF
#!/bin/sh
[ "\$1" = "$1" ] && exit 1
exit 0
EOF
    chmod 555 "${DEV_SCRIPTS_BIN_DIR}"
}

teardown() {
    # Restored so bats can clean up a bin dir or fake repo a test locked down.
    chmod 755 "${DEV_SCRIPTS_BIN_DIR}" 2>/dev/null || true
    chmod 755 "${FAKE_SCRIPTS_REPO}" 2>/dev/null || true
    chmod 755 "$(dirname "${DEV_SCRIPTS_LIB_DIR}")" 2>/dev/null || true
}

# A single executable fixture script in the fake repo, so the link step has
# exactly one deterministic target.
add_fake_dev_script() {
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db"
    printf '#!/bin/sh\nexit 0\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
    chmod +x "${FAKE_SCRIPTS_REPO}/settings/scripts/db/dbtool"
}

@test "dev-scripts fails, naming the bin dir, when creating it fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    add_fake_dev_script
    fail_sudo_for install

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create ${DEV_SCRIPTS_BIN_DIR}"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

@test "dev-scripts fails, naming the link, when linking a script fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    add_fake_dev_script
    fail_sudo_for ln

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to link ${DEV_SCRIPTS_BIN_DIR}/dbtool"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

@test "dev-scripts fails, naming the link, when removing a stale symlink fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    add_fake_dev_script
    ln -s "${FAKE_SCRIPTS_REPO}/settings/scripts/db/no-longer-here" "${DEV_SCRIPTS_BIN_DIR}/no-longer-here"
    fail_sudo_for rm

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to remove stale symlink ${DEV_SCRIPTS_BIN_DIR}/no-longer-here"* ]]
    [[ "${output}" != *"Linking"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

# Asserts the run removed the copy it made but never switched to, through
# sudo; the fake sudo logs the removal without running it.
assert_unswitched_copy_removed() {
    assert_fake_called "^sudo rm -rf ${DEV_SCRIPTS_LIB_DIR}-[0-9]{8}T[0-9]{6}\\.[0-9]+Z\$"
}

# Makes the folder holding DEV_SCRIPTS_LIB_DIR read-only, so dev-scripts
# routes every change it makes there through the fake sudo, which runs
# nothing and fails the command line matching FAKE_SUDO_FAIL, then runs
# dev-scripts against the fake repo with one fixture script. The run lock is
# made first, as the fake sudo would not create it. The caller
# asserts on the run in its own @test body: shellcheck treats each body as
# a subshell, so reading status or output in a helper defined after other
# tests' runs is flagged (SC2030/SC2031).
# Usage: run_with_lib_step_failing <grep -E pattern>
run_with_lib_step_failing() {
    add_fake_dev_script
    LIB_PARENT="$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    mkdir -p "${LIB_PARENT}"
    : > "$(dev_scripts_lock_file)"
    chmod 555 "${LIB_PARENT}"
    export FAKE_SUDO_FAIL="$1"

    run_dev_scripts_against_fake_repo
}

# As run_with_lib_step_failing, but with no run lock made first, so a test
# can fail a step of making it; with no pattern, no sudo call fails.
# Usage: run_with_lock_step_failing [<grep -E pattern>]
run_with_lock_step_failing() {
    add_fake_dev_script
    mkdir -p "$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    chmod 555 "$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    export FAKE_SUDO_FAIL="${1:-}"

    run_dev_scripts_against_fake_repo
}

@test "dev-scripts fails, naming the lock, when creating the run lock fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lock_step_failing '^touch '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create $(dev_scripts_lock_file)"* ]]
    [[ "${output}" != *"Copying dev scripts"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

@test "dev-scripts fails, naming the lock, when making the run lock readable fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lock_step_failing '^chmod 0644 '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create $(dev_scripts_lock_file)"* ]]
    [[ "${output}" != *"Copying dev scripts"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

@test "dev-scripts fails, naming the lock and changing nothing, when the run lock cannot be opened" {
    [ "$(id -u)" -ne 0 ] || skip "root can read a file with no permissions"
    mkdir -p "$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    : > "$(dev_scripts_lock_file)"
    chmod 000 "$(dev_scripts_lock_file)"

    run_with_lock_step_failing
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to open $(dev_scripts_lock_file)"* ]]
    [[ "${output}" != *"Copying dev scripts"* ]]
    [ -z "$(lib_copies)" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    [ -z "$(ls -A "${DEV_SCRIPTS_BIN_DIR}")" ]
}

@test "dev-scripts waits for the lock, then stops, naming it and changing nothing, when another run never releases it" {
    mkdir -p "$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    : > "$(dev_scripts_lock_file)"
    exec 8<"$(dev_scripts_lock_file)"
    flock -n 8

    run env RUN_LOCK_WAIT_SECONDS=1 "${DEV_SCRIPTS}"
    exec 8<&-
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Waiting up to 1s for another dev-scripts install to release $(dev_scripts_lock_file)"* ]]
    [[ "${output}" == *"Timed out after 1s waiting for another dev-scripts install to release $(dev_scripts_lock_file)"* ]]
    [ -z "$(lib_copies)" ]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    [ -z "$(ls -A "${DEV_SCRIPTS_BIN_DIR}")" ]
}

@test "dev-scripts waits for another run to release the lock, then installs" {
    mkdir -p "$(dirname "${DEV_SCRIPTS_LIB_DIR}")"
    : > "$(dev_scripts_lock_file)"
    hold_lock_in_background "$(dev_scripts_lock_file)" 2

    run env RUN_LOCK_WAIT_SECONDS=30 "${DEV_SCRIPTS}"
    wait "${LOCK_HOLDER_PID}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Waiting up to 30s for another dev-scripts install to release $(dev_scripts_lock_file)"* ]]
    [[ "${output}" == *"Dev scripts installed"* ]]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbenv" ]
}

@test "dev-scripts fails, naming the folder, when creating the lib folder's parent fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^mkdir -p '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to create ${LIB_PARENT}"* ]]
}

@test "dev-scripts fails, naming the folder, when creating the new copy fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^mkdir -m 755 '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to create ${DEV_SCRIPTS_LIB_DIR}-"* ]]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails, naming the folder, when creating a folder in the copy fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^install -d '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to create ${DEV_SCRIPTS_LIB_DIR}-"*"/lib"* ]]
    assert_unswitched_copy_removed
}

@test "dev-scripts warns, still failing, when removing an unfinished copy fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^(install -d |rm -rf )'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to create ${DEV_SCRIPTS_LIB_DIR}-"*"/lib"* ]]
    [[ "${output}" == *"Failed to remove the unfinished copy ${DEV_SCRIPTS_LIB_DIR}-"* ]]
}

@test "dev-scripts fails, naming the file, when copying a file fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^install -m '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to copy lib/common to ${DEV_SCRIPTS_LIB_DIR}-"* ]]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails, naming the copy, when giving it to root fails" {
    add_fake_dev_script
    export FAKE_SUDO_FAIL='^chown '

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to make ${DEV_SCRIPTS_LIB_DIR}-"*" owned by root"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails, naming the copy, when creating the switch link fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^ln -sfn '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to create a link to ${DEV_SCRIPTS_LIB_DIR}-"* ]]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails, naming the lib folder, when switching it to the new copy fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    run_with_lib_step_failing '^mv -T '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to switch ${DEV_SCRIPTS_LIB_DIR} to ${DEV_SCRIPTS_LIB_DIR}-"* ]]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails, naming the copy, when removing an old copy fails" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
    local _old="${DEV_SCRIPTS_LIB_DIR}-20000101T000000.000000000Z"
    mkdir -p "${_old}"
    run_with_lib_step_failing '^rm -rf '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [[ "${output}" == *"Failed to remove the old copy ${_old}"* ]]
}

@test "dev-scripts refuses a new copy name that already exists, leaving that folder alone" {
    add_fake_dev_script
    local _taken="${DEV_SCRIPTS_LIB_DIR}-20000101T000000.000000000Z"
    mkdir -p "${_taken}"
    : > "${_taken}/kept"
    setup_fake_bin date
    seed_fake_output date <<< "20000101T000000.000000000Z"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${_taken} already exists; move it aside, then re-run"* ]]
    [ -f "${_taken}/kept" ]
    refute_fake_called '^sudo rm -rf '
}

@test "dev-scripts removes its unfinished copy when it is sent SIGTERM while copying" {
    add_fake_dev_script
    local _real_install
    _real_install="$(command -v install)"
    # The first file copy into the new copy sends dev-scripts a SIGTERM, as a
    # Ctrl-C mid-copy would; every other install runs for real.
    replace_fake install <<EOF
#!/bin/sh
case "\$*" in
    -d*) ;;
    *"${DEV_SCRIPTS_LIB_DIR}-"*)
        kill -TERM "\${PPID}"
        exit 0
        ;;
esac
exec "${_real_install}" "\$@"
EOF

    run_dev_scripts_against_fake_repo
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"Dev scripts installed"* ]]
    [ ! -e "${DEV_SCRIPTS_LIB_DIR}" ]
    assert_unswitched_copy_removed
}

@test "dev-scripts fails when the new copy cannot be named" {
    add_fake_dev_script
    setup_fake_bin date
    export FAKE_EXIT_date=1

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to name a new copy of the dev scripts"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

# Replaces git with one that fails when its arguments contain the given
# text and runs the real git otherwise.
# Usage: fail_git_for <text>
fail_git_for() {
    local _real_git
    _real_git="$(command -v git)"
    replace_fake git <<EOF
#!/bin/sh
case "\$*" in
    *"$1"*) exit 1 ;;
esac
exec "${_real_git}" "\$@"
EOF
}

@test "dev-scripts fails when the files to copy cannot be listed" {
    add_fake_dev_script
    fail_git_for ' ls-files '

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to list the files to copy from ${FAKE_SCRIPTS_REPO}"* ]]
    [[ "${output}" != *"Dev scripts installed"* ]]
}

@test "dev-scripts prunes a dangling relative symlink that resolves into its own checkout" {
    add_fake_dev_script
    ln -s "../$(basename "${FAKE_SCRIPTS_REPO}")/settings/scripts/db/gone" "${DEV_SCRIPTS_BIN_DIR}/gone"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ ! -L "${DEV_SCRIPTS_BIN_DIR}/gone" ]
}

@test "dev-scripts installs the copy and links nothing when there are no executable scripts" {
    mkdir -p "${FAKE_SCRIPTS_REPO}/settings/scripts/db"
    printf 'not a script\n' > "${FAKE_SCRIPTS_REPO}/settings/scripts/db/data"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dev scripts installed"* ]]
    [[ "${output}" != *"Linking"* ]]
    [ -f "${DEV_SCRIPTS_LIB_DIR}/settings/scripts/db/data" ]
    [ -z "$(find "${DEV_SCRIPTS_BIN_DIR}" -mindepth 1)" ]
}

# ── git-environment ──────────────────────────────────────────────────────────

@test "git-environment configures the expected global git identity and behaviour" {
    setup_fake_bin gpg
    seed_fake_output gpg <<'EOF'
pub:u:4096:1:ABCDEF1234567890:1234567890:::u:::scESC::::::23::0:
fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:
uid:u::::1234567890::HASH::Mark Ridgwell <credfeto@users.noreply.github.com>::::::::::0:
EOF

    run "${GIT_ENVIRONMENT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Git environment configured"* ]]

    run git config --global user.name
    [ "${output}" = "Mark Ridgwell" ]

    run git config --global user.email
    [ "${output}" = "credfeto@users.noreply.github.com" ]

    run git config --global user.signingkey
    [ "${output}" = "0123456789ABCDEF0123456789ABCDEF01234567" ]

    run git config --global commit.gpgsign
    [ "${output}" = "true" ]

    run git config --global pull.rebase
    [ "${output}" = "true" ]

    local -A _expected=(
        [tag.gpgSign]="true"
        [init.defaultBranch]="main"
        [rebase.updateRefs]="true"
        [rerere.enabled]="true"
        [merge.conflictStyle]="zdiff3"
        [fetch.parallel]="16"
        [fetch.writeCommitGraph]="true"
        [submodule.recurse]="true"
        [push.followTags]="true"
        [transfer.fsckObjects]="true"
        [feature.manyFiles]="true"
        [diff.algorithm]="histogram"
        [diff.colorMoved]="default"
        [branch.sort]="-committerdate"
        [tag.sort]="version:refname"
    )
    local _key
    for _key in "${!_expected[@]}"; do
        run git config --global "${_key}"
        # Name the key on failure: the associative array's iteration order
        # is arbitrary, so the bare assertion alone would not say which key.
        [ "${output}" = "${_expected[${_key}]}" ] || { echo "${_key}: expected '${_expected[${_key}]}', got '${output}'" >&2; return 1; }
    done

    run git config --global url."git@github.com:".insteadOf
    [ "${output}" = "https://github.com/" ]

    # Base must carry the same trailing slash as insteadOf's value - git's
    # url rewrite is a literal prefix substitution, so a missing slash here
    # drops the separator between host and path in every rewritten URL.
    run git config --global url."https://aur.markridgwell.com/".insteadOf
    [ "${output}" = "https://aur.archlinux.org/" ]
}

@test "git-environment dies rather than enabling gpgsign when no signing key is found" {
    setup_fake_bin gpg
    # No seeded output - fake gpg prints nothing, as real gpg would for an
    # account with no matching key.

    run "${GIT_ENVIRONMENT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No GPG key found"* ]]

    run git config --global commit.gpgsign
    [ "${status}" -ne 0 ]

    run git config --global tag.gpgSign
    [ "${status}" -ne 0 ]
}

@test "git-environment fails, naming the option, when the global git config cannot be written" {
    setup_fake_bin gpg
    # The lock file git writes beside the config cannot be created in a
    # directory that does not exist.
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/missing-dir/gitconfig"

    run "${GIT_ENVIRONMENT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to set git config user.name"* ]]
    [[ "${output}" != *"Git environment configured"* ]]
    refute_fake_called '^gpg '
}
