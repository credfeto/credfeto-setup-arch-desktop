#!/usr/bin/env bats
# Acceptance tests for install.d/dev-scripts and install.d/git-environment.

load test_helper

DEV_SCRIPTS="${REPO_DIR}/install.d/dev-scripts"
GIT_ENVIRONMENT="${REPO_DIR}/install.d/git-environment"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    # DEV_SCRIPTS_BIN_DIR is user-writable, so dev-scripts's sudo-avoidance
    # path is exercised - no real root/sudo needed for these tests.
    export DEV_SCRIPTS_BIN_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${DEV_SCRIPTS_BIN_DIR}"
}

@test "dev-scripts symlinks every executable script into the bin dir" {
    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbenv" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/login" ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/buildcheck" ]
    readlink -f "${DEV_SCRIPTS_BIN_DIR}/dbenv" | grep -qF "settings/scripts/db/dbenv"
}

# Copies install.d/dev-scripts and lib/common into a throwaway fake repo
# tree under BATS_TEST_TMPDIR/fake-scripts-repo, so a test can populate
# settings/scripts/ with fixtures without touching the real repo tree, then
# runs the copied dev-scripts against it.
run_dev_scripts_against_fake_repo() {
    mkdir -p "${BATS_TEST_TMPDIR}/fake-scripts-repo/lib" "${BATS_TEST_TMPDIR}/fake-scripts-repo/install.d"
    cp "${REPO_DIR}/lib/common" "${BATS_TEST_TMPDIR}/fake-scripts-repo/lib/common"
    cp "${DEV_SCRIPTS}" "${BATS_TEST_TMPDIR}/fake-scripts-repo/install.d/dev-scripts"
    chmod +x "${BATS_TEST_TMPDIR}/fake-scripts-repo/install.d/dev-scripts"

    run "${BATS_TEST_TMPDIR}/fake-scripts-repo/install.d/dev-scripts"
}

@test "dev-scripts dies on a basename collision across source directories" {
    mkdir -p "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db" "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/development"
    printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db/dup"
    printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/development/dup"
    chmod +x "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db/dup" "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/development/dup"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Duplicate script name"* ]]
    [[ "${output}" == *"dup"* ]]
}

@test "dev-scripts does not link a non-executable sibling data file" {
    mkdir -p "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db"
    printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db/dbtool"
    chmod +x "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db/dbtool"
    # Non-executable data file living alongside a real script, e.g. a
    # config/template file a script reads - must not be linked into
    # DEV_SCRIPTS_BIN_DIR as if it were a standalone command.
    printf 'not a script\n' > "${BATS_TEST_TMPDIR}/fake-scripts-repo/settings/scripts/db/dbtool-config"

    run_dev_scripts_against_fake_repo
    [ "${status}" -eq 0 ]
    [ -L "${DEV_SCRIPTS_BIN_DIR}/dbtool" ]
    [ ! -e "${DEV_SCRIPTS_BIN_DIR}/dbtool-config" ]
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

@test "dev-scripts is idempotent - a second run leaves the same set of symlinks" {
    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    first_count=$(find "${DEV_SCRIPTS_BIN_DIR}" -maxdepth 1 -type l | wc -l)

    run "${DEV_SCRIPTS}"
    [ "${status}" -eq 0 ]
    second_count=$(find "${DEV_SCRIPTS_BIN_DIR}" -maxdepth 1 -type l | wc -l)

    [ "${first_count}" -eq "${second_count}" ]
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
