#!/usr/bin/env bats
# Acceptance tests for settings/scripts/git/.

load test_helper

GIT_DIR_SCRIPTS="${SCRIPTS_DIR}/git"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
    remove_codegraph_from_path
}

# Takes codegraph off PATH, so fetch cannot find the codegraph of whoever
# runs the suite and index the scratch repos with it. Each PATH directory
# holding a codegraph is swapped for a per-test directory of symlinks to
# everything else in it, so a codegraph installed beside git (in /usr/bin,
# say) does not take git with it. A test that wants one puts a fake on PATH
# afterwards. Fails when codegraph can still be found, or git can no longer
# be.
remove_codegraph_from_path() {
    local _dir _source _shadow _kept="" _entries
    IFS=: read -r -a _entries <<< "${PATH}"
    for _dir in "${_entries[@]}"; do
        if [ -x "${_dir:-.}/codegraph" ]; then
            _source="$(cd "${_dir:-.}" && pwd)" || return 1
            _shadow="$(mktemp -d "${BATS_TEST_TMPDIR}/path-without-codegraph.XXXXXX")" || return 1
            ln -s "${_source}"/* "${_shadow}/" || return 1
            rm -f "${_shadow}/codegraph"
            _dir="${_shadow}"
        fi
        _kept="${_kept:+${_kept}:}${_dir}"
    done
    export PATH="${_kept}"
    hash -r
    ! command -v codegraph > /dev/null && command -v git > /dev/null
}

# Puts a fake codegraph on PATH that logs its arguments and the directory it
# ran in to $FAKE_BIN_LOG, and exits with FAKE_EXIT_codegraph (0 when unset).
# A successful init leaves the .codegraph/.gitignore the real one writes,
# which ignores the index but not itself.
setup_fake_codegraph() {
    ensure_fake_bin_dir
    : > "${FAKE_BIN_LOG}"
    replace_fake codegraph <<'EOF'
#!/bin/sh
printf 'codegraph %s (in %s)\n' "$*" "$(pwd)" >> "${FAKE_BIN_LOG}"
if [ "${FAKE_EXIT_codegraph:-0}" -eq 0 ] && [ "$1" = init ]; then
    mkdir -p .codegraph
    printf '*\n!.gitignore\n' > .codegraph/.gitignore
fi
exit "${FAKE_EXIT_codegraph:-0}"
EOF
}

# Prints how many lines of the repo's info/exclude are exactly .codegraph/.
# Usage: codegraph_exclude_count <repo>
codegraph_exclude_count() {
    if [ ! -e "$1/.git/info/exclude" ]; then
        echo 0
        return
    fi
    grep -cxF '.codegraph/' "$1/.git/info/exclude" || true
}

make_bare_remote_and_clone() {
    local _name="$1"
    local _remote="${BATS_TEST_TMPDIR}/remotes/${_name}.git"
    local _clone="${BATS_TEST_TMPDIR}/repos/${_name}"
    mkdir -p "$(dirname "${_remote}")"
    git init --quiet --bare "${_remote}"
    git clone --quiet "${_remote}" "${_clone}"
    git -C "${_clone}" commit --quiet --allow-empty -m "initial"
    git -C "${_clone}" push --quiet
}

# Clones a repo as make_bare_remote_and_clone does, points origin/HEAD at the
# remote's default branch, then leaves the clone on a new branch with no
# upstream, so fetch --switch-to-main skips the first rebase and goes straight
# to switching to the default branch. The default branch's name is left in
# DEFAULT_BRANCH_NAME.
# Usage: make_clone_on_feature_branch <name>
make_clone_on_feature_branch() {
    local _clone="${BATS_TEST_TMPDIR}/repos/$1"
    make_bare_remote_and_clone "$1"
    git -C "${_clone}" remote set-head origin --auto > /dev/null
    DEFAULT_BRANCH_NAME="$(git -C "${_clone}" rev-parse --abbrev-ref HEAD)"
    git -C "${_clone}" checkout --quiet -b feature
}

# Asserts the last fetch skipped repo-a, and only repo-a, for the given reason
# without finishing it.
# Usage: assert_skipped_repo_a <reason>
assert_skipped_repo_a() {
    [ "${status}" -eq 0 ] || return 1
    [[ "${output}" == *"0 repo(s) fetched, 1 repo(s) skipped"* ]] || return 1
    [[ "${output}" == *"repo-a ($1)"* ]] || return 1
    [[ "${output}" != *"Done with"* ]]
}

# Asserts the last fetch skipped repo-a because a rebase was already in
# progress, without starting or aborting a rebase there.
assert_skipped_rebase_in_progress() {
    assert_skipped_repo_a "rebase in progress" || return 1
    [[ "${output}" == *"Rebase already in progress in ${BATS_TEST_TMPDIR}/repos/repo-a"* ]] || return 1
    refute_fake_called ' rebase( |$)' || return 1
    refute_fake_called 'rebase --abort'
}

# Runs fetch over a single clone whose git fails the given arguments, and
# asserts it skipped the clone for the given reason without finishing it.
# Usage: assert_fetch_skips_when_git_fails <git-arguments> <reason>
assert_fetch_skips_when_git_fails() {
    make_bare_remote_and_clone repo-a
    fail_git_for "$1"
    cd "${BATS_TEST_TMPDIR}/repos" || return 1
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "$2"
}

# Asserts the last fetch skipped repo-a because the codegraph index could not
# be excluded, without starting codegraph init or leaving an index behind.
assert_skipped_before_codegraph_init() {
    assert_skipped_repo_a "could not initialise codegraph" || return 1
    refute_fake_called '^codegraph' || return 1
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
}

ORIGINAL_GLOBAL_JSON='{"sdk":{"version":"11.0.0","allowPrerelease":true}}'

# Runs update-dotnet-sdk against a repo holding ORIGINAL_GLOBAL_JSON, with
# dotnet listing the given SDK version and mv failing.
# Usage: run_update_dotnet_sdk_with_failing_mv <sdk-version>
run_update_dotnet_sdk_with_failing_mv() {
    # Real mv is shadowed only for the script run; the fixture is set up
    # with the real tools first.
    mkdir -p "${BATS_TEST_TMPDIR}/repo"
    printf '%s' "${ORIGINAL_GLOBAL_JSON}" > "${BATS_TEST_TMPDIR}/repo/global.json"
    cd "${BATS_TEST_TMPDIR}/repo" || exit
    setup_fake_bin git dotnet mv
    seed_fake_output dotnet <<< "$1"

    run env DOTNET_PREVIEW_VERSION=11 FAKE_EXIT_mv=1 "${GIT_DIR_SCRIPTS}/update-dotnet-sdk"
}

# Asserts the last run died naming global.json, left it exactly as it was
# and committed nothing.
assert_global_json_kept_after_failed_replace() {
    [ "${status}" -eq 1 ] || return 1
    [[ "${output}" == *"Could not replace ${BATS_TEST_TMPDIR}/repo/global.json"* ]] || return 1
    [ "$(cat "${BATS_TEST_TMPDIR}/repo/global.json")" = "${ORIGINAL_GLOBAL_JSON}" ] || return 1
    refute_fake_called '^git '
}

# ── fetch ────────────────────────────────────────────────────────────────────

@test "fetch dies on an unrecognised argument" {
    run "${GIT_DIR_SCRIPTS}/fetch" --bogus
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown argument: --bogus"* ]]
}

@test "fetch fetches and rebases every repo found under the current directory" {
    make_bare_remote_and_clone repo-a
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
}

@test "fetch does not exclude a repo whose path merely contains \"cache\", only ones under a literal .cache directory" {
    make_bare_remote_and_clone mycache-tools
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
}

@test "fetch skips a repo with no configured origin" {
    mkdir -p "${BATS_TEST_TMPDIR}/repos/no-origin"
    git init --quiet "${BATS_TEST_TMPDIR}/repos/no-origin"
    git -C "${BATS_TEST_TMPDIR}/repos/no-origin" commit --quiet --allow-empty -m "initial"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"0 repo(s) fetched, 1 repo(s) skipped"* ]]
    [[ "${output}" == *"could not determine origin"* ]]
}

@test "fetch skips a repo it cannot fetch" {
    assert_fetch_skips_when_git_fails "fetch --prune --prune-tags" "could not fetch"
    [[ "${output}" == *"Could not fetch ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
}

@test "fetch skips a repo whose remote refs cannot be updated" {
    assert_fetch_skips_when_git_fails "remote update origin --prune" "could not update remote refs"
    [[ "${output}" == *"Could not update remote refs for ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
}

@test "fetch skips a repo whose status cannot be read" {
    assert_fetch_skips_when_git_fails "status --porcelain" "could not read status"
    [[ "${output}" == *"Could not read status for ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
}

@test "fetch removes its repo list when it is sent SIGTERM" {
    mkdir -p "${BATS_TEST_TMPDIR}/repos/repo-a/.git"
    local _tmp="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${_tmp}"
    # A git that sends fetch SIGTERM when asked to fetch, as a Ctrl-C during
    # a slow fetch would, and succeeds at everything else.
    replace_fake git <<'EOF'
#!/bin/sh
case " $* " in
    *" fetch "*)
        kill -TERM "${PPID}"
        ;;
esac
exit 0
EOF
    cd "${BATS_TEST_TMPDIR}/repos"

    TMPDIR="${_tmp}" run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"repo(s) fetched"* ]]
    [ -z "$(ls -A "${_tmp}")" ]
}

@test "fetch skips a repo whose rebase fails, after aborting the rebase" {
    make_bare_remote_and_clone repo-a
    fail_git_for ' rebase '
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not rebase"
    [[ "${output}" == *"Could not rebase ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    assert_fake_called 'rebase --abort$'
}

@test "fetch does not abort a rebase that succeeded" {
    make_bare_remote_and_clone repo-a
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    assert_fake_called ' rebase$'
    refute_fake_called 'rebase --abort'
}

@test "fetch skips a clean repo with a rebase in progress on a branch with an upstream, without aborting it" {
    make_bare_remote_and_clone repo-a
    mkdir "${BATS_TEST_TMPDIR}/repos/repo-a/.git/rebase-apply"
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_rebase_in_progress
}

@test "fetch skips a repo whose rebase state cannot be read, without rebasing it" {
    make_bare_remote_and_clone repo-a
    fail_git_for "rev-parse --git-path rebase-merge"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "rebase in progress"
}

@test "fetch --switch-to-main leaves an interactive rebase paused on edit where it stopped" {
    local _clone="${BATS_TEST_TMPDIR}/repos/repo-a" _stopped_at
    make_clone_on_feature_branch repo-a
    git -C "${_clone}" commit --quiet --allow-empty -m "feature work"
    GIT_SEQUENCE_EDITOR="sed -i 's/^pick/edit/'" git -C "${_clone}" rebase --quiet -i HEAD~1 > /dev/null 2>&1
    [ -d "${_clone}/.git/rebase-merge" ]
    [ -z "$(git -C "${_clone}" status --porcelain)" ]
    _stopped_at="$(git -C "${_clone}" rev-parse HEAD)"
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    assert_skipped_rebase_in_progress
    refute_fake_called 'checkout'
    [ -d "${_clone}/.git/rebase-merge" ]
    [ "$(git -C "${_clone}" rev-parse HEAD)" = "${_stopped_at}" ]
}

@test "fetch --switch-to-main switches a repo whose feature branch rebase fails to the default branch, after aborting the rebase" {
    local _clone="${BATS_TEST_TMPDIR}/repos/repo-a" _other="${BATS_TEST_TMPDIR}/other" _feature_head
    make_clone_on_feature_branch repo-a
    # The feature branch and the remote's default branch change the same
    # line, so rebasing the feature branch onto it conflicts for real.
    git -C "${_clone}" branch --quiet --set-upstream-to "origin/${DEFAULT_BRANCH_NAME}"
    printf 'feature\n' > "${_clone}/conflict.txt"
    git -C "${_clone}" add conflict.txt
    git -C "${_clone}" commit --quiet -m "feature work"
    _feature_head="$(git -C "${_clone}" rev-parse HEAD)"
    git clone --quiet "${BATS_TEST_TMPDIR}/remotes/repo-a.git" "${_other}"
    printf 'upstream\n' > "${_other}/conflict.txt"
    git -C "${_other}" add conflict.txt
    git -C "${_other}" commit --quiet -m "upstream work"
    git -C "${_other}" push --quiet
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not rebase feature in ${_clone}; switching to ${DEFAULT_BRANCH_NAME} anyway."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    assert_fake_called 'rebase --abort$'
    assert_fake_called "checkout ${DEFAULT_BRANCH_NAME}$"
    [ "$(git -C "${_clone}" symbolic-ref --short HEAD)" = "${DEFAULT_BRANCH_NAME}" ]
    [ "$(git -C "${_clone}" rev-parse HEAD)" = "$(git -C "${_clone}" rev-parse "origin/${DEFAULT_BRANCH_NAME}")" ]
    [ "$(git -C "${_clone}" rev-parse feature)" = "${_feature_head}" ]
}

@test "fetch --switch-to-main skips a repo on the default branch whose rebase fails, after aborting the rebase" {
    make_bare_remote_and_clone repo-a
    git -C "${BATS_TEST_TMPDIR}/repos/repo-a" remote set-head origin --auto > /dev/null
    fail_git_for ' rebase '
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    assert_skipped_repo_a "could not rebase"
    [[ "${output}" == *"Could not rebase ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    assert_fake_called 'rebase --abort$'
    refute_fake_called 'checkout'
}

@test "fetch --switch-to-main skips a repo that cannot switch to the default branch" {
    make_clone_on_feature_branch repo-a
    fail_git_for ' checkout '
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    assert_skipped_repo_a "could not switch to ${DEFAULT_BRANCH_NAME}"
    [[ "${output}" == *"Could not switch to ${DEFAULT_BRANCH_NAME} in ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
}

@test "fetch --switch-to-main skips a repo whose default branch rebase fails, after aborting the rebase" {
    make_clone_on_feature_branch repo-a
    fail_git_for ' rebase '
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    assert_skipped_repo_a "could not rebase ${DEFAULT_BRANCH_NAME}"
    [[ "${output}" == *"Could not rebase ${DEFAULT_BRANCH_NAME} in ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    assert_fake_called "checkout ${DEFAULT_BRANCH_NAME}$"
    assert_fake_called 'rebase --abort$'
}

@test "fetch --switch-to-main rebases the default branch without aborting it" {
    make_clone_on_feature_branch repo-a
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [ "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" rev-parse --abbrev-ref HEAD)" = "${DEFAULT_BRANCH_NAME}" ]
    assert_fake_called ' rebase$'
    refute_fake_called 'rebase --abort'
}

@test "fetch --switch-to-main does not rebase a default branch with no upstream" {
    make_clone_on_feature_branch repo-a
    git -C "${BATS_TEST_TMPDIR}/repos/repo-a" branch --unset-upstream "${DEFAULT_BRANCH_NAME}"
    fake_git
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No valid upstream for ${DEFAULT_BRANCH_NAME}. Skipping rebase."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [ "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" symbolic-ref --short HEAD)" = "${DEFAULT_BRANCH_NAME}" ]
    refute_fake_called ' rebase$'
}

@test "fetch --switch-to-main switches a clean repo whose current branch cannot be read to the default branch" {
    make_clone_on_feature_branch repo-a
    fail_git_for "rev-parse --abbrev-ref HEAD"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not determine current branch for ${BATS_TEST_TMPDIR}/repos/repo-a."* ]]
    [[ "${output}" == *"Switching to ${DEFAULT_BRANCH_NAME} branch..."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [[ "${output}" != *"Skipped repositories:"* ]]
    [ "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" symbolic-ref --short HEAD)" = "${DEFAULT_BRANCH_NAME}" ]
}

@test "fetch --switch-to-main does not switch a repo with pending changes whose current branch cannot be read" {
    make_clone_on_feature_branch repo-a
    printf 'pending\n' > "${BATS_TEST_TMPDIR}/repos/repo-a/pending.txt"
    fail_git_for "rev-parse --abbrev-ref HEAD"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch" --switch-to-main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Pending changes in working folder. Skipping switch to ${DEFAULT_BRANCH_NAME}."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [ "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" symbolic-ref --short HEAD)" = "feature" ]
}

@test "fetch initialises codegraph in a repo without a .codegraph index and still counts it as fetched" {
    make_bare_remote_and_clone repo-a
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Initialising codegraph for ${BATS_TEST_TMPDIR}/repos/repo-a..."* ]]
    [[ "${output}" == *"Done with ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}"
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
    [ -z "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" status --porcelain)" ]
}

@test "fetch does not list .codegraph/ twice when info/exclude already excludes it" {
    make_bare_remote_and_clone repo-a
    mkdir -p "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info"
    printf '%s\n' '# kept' '.codegraph/' > "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    assert_fake_called '^codegraph init '
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
    grep -qxF '# kept' "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
}

@test "fetch adds .codegraph/ on its own line when info/exclude does not end in a newline" {
    make_bare_remote_and_clone repo-a
    mkdir -p "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info"
    printf '%s' '# no newline' > "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
    grep -qxF '# no newline' "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
    [ -z "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" status --porcelain)" ]
}

@test "fetch still rebases a repo on the run after it initialised codegraph there" {
    make_bare_remote_and_clone repo-a
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Initialising codegraph for ${BATS_TEST_TMPDIR}/repos/repo-a..."* ]]
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Pending changes"* ]]
    [[ "${output}" == *"No pending changes in working folder. Rebasing..."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
}

@test "fetch skips a repo whose codegraph index cannot be excluded" {
    make_bare_remote_and_clone repo-a
    setup_fake_codegraph
    fail_git_for "rev-parse --git-path info/exclude"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not initialise codegraph"
}

@test "fetch excludes the codegraph index in a git directory kept outside the work tree" {
    local _git_dir="${BATS_TEST_TMPDIR}/gitdirs/repo-a"
    make_bare_remote_and_clone origin-only
    mkdir -p "$(dirname "${_git_dir}")"
    git clone --quiet --separate-git-dir "${_git_dir}" "${BATS_TEST_TMPDIR}/remotes/origin-only.git" "${BATS_TEST_TMPDIR}/repos/repo-a"
    rm -rf "${BATS_TEST_TMPDIR}/repos/origin-only"
    [[ "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" rev-parse --git-path info/exclude)" == /* ]]
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}"
    [ "$(grep -cxF '.codegraph/' "${_git_dir}/info/exclude")" -eq 1 ]
    [ -z "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" status --porcelain)" ]
}

@test "fetch skips a repo whose info directory cannot be created" {
    make_bare_remote_and_clone repo-a
    rm -rf "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info"
    : > "${BATS_TEST_TMPDIR}/repos/repo-a/.git/info"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_before_codegraph_init
}

@test "fetch skips a repo whose info/exclude cannot take the newline it lacks" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only file"
    local _exclude="${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
    make_bare_remote_and_clone repo-a
    mkdir -p "$(dirname "${_exclude}")"
    printf '%s' '# no newline' > "${_exclude}"
    chmod 444 "${_exclude}"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_before_codegraph_init
    [ "$(cat "${_exclude}")" = '# no newline' ]
}

@test "fetch skips a repo whose info/exclude cannot have .codegraph/ appended" {
    [ "$(id -u)" -ne 0 ] || skip "root can write a read-only file"
    local _exclude="${BATS_TEST_TMPDIR}/repos/repo-a/.git/info/exclude"
    make_bare_remote_and_clone repo-a
    mkdir -p "$(dirname "${_exclude}")"
    : > "${_exclude}"
    chmod 444 "${_exclude}"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_before_codegraph_init
    [ ! -s "${_exclude}" ]
}

@test "fetch initialises codegraph on the run after it could not exclude the index" {
    make_bare_remote_and_clone repo-a
    setup_fake_codegraph
    fail_git_for "rev-parse --git-path info/exclude"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"repo-a (could not initialise codegraph)"* ]]
    refute_fake_called '^codegraph'
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
    rm "${FAKE_BIN_DIR}/git"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}"
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
    [ -z "$(git -C "${BATS_TEST_TMPDIR}/repos/repo-a" status --porcelain)" ]
}

@test "fetch initialises codegraph in every repo when init reads its stdin" {
    make_bare_remote_and_clone repo-a
    make_bare_remote_and_clone repo-b
    replace_fake codegraph <<'EOF'
#!/bin/sh
cat > /dev/null
printf 'codegraph %s (in %s)\n' "$*" "$(pwd)" >> "${FAKE_BIN_LOG}"
EOF
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 repo(s) fetched, 0 repo(s) skipped"* ]]
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}"
    grep -qxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-b)" "${FAKE_BIN_LOG}"
}

@test "fetch excludes but does not initialise a .codegraph index that already exists" {
    make_bare_remote_and_clone repo-a
    mkdir "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [[ "${output}" != *"Initialising codegraph"* ]]
    refute_fake_called '^codegraph'
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
}

@test "fetch does not list a pre-existing .codegraph index in info/exclude twice over two runs" {
    make_bare_remote_and_clone repo-a
    mkdir "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph"
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    refute_fake_called '^codegraph'
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
}

@test "fetch skips a repo whose pre-existing .codegraph index cannot be excluded" {
    make_bare_remote_and_clone repo-a
    mkdir "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph"
    setup_fake_codegraph
    fail_git_for "rev-parse --git-path info/exclude"
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not exclude codegraph index"
    [[ "${output}" == *"Could not exclude the codegraph index for ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    refute_fake_called '^codegraph'
}

@test "fetch rebases a clean repo with a pre-existing un-excluded .codegraph index on the first run" {
    local _repo="${BATS_TEST_TMPDIR}/repos/repo-a"
    local _pusher="${BATS_TEST_TMPDIR}/pusher"
    make_bare_remote_and_clone repo-a
    mkdir "${_repo}/.codegraph"
    : > "${_repo}/.codegraph/codegraph.db"
    [[ "$(git -C "${_repo}" status --porcelain)" == *"?? .codegraph/"* ]]
    git clone --quiet "${BATS_TEST_TMPDIR}/remotes/repo-a.git" "${_pusher}"
    git -C "${_pusher}" commit --quiet --allow-empty -m "upstream"
    git -C "${_pusher}" push --quiet
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Pending changes"* ]]
    [[ "${output}" == *"No pending changes in working folder. Rebasing..."* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [ "$(git -C "${_repo}" rev-parse HEAD)" = "$(git -C "${_pusher}" rev-parse HEAD)" ]
    refute_fake_called '^codegraph'
    [ "$(codegraph_exclude_count "${_repo}")" -eq 1 ]
}

@test "fetch skips a repo whose codegraph init fails" {
    make_bare_remote_and_clone repo-a
    setup_fake_codegraph
    cd "${BATS_TEST_TMPDIR}/repos"
    FAKE_EXIT_codegraph=1 run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not initialise codegraph"
    [[ "${output}" == *"Could not initialise codegraph for ${BATS_TEST_TMPDIR}/repos/repo-a"* ]]
    assert_fake_called '^codegraph init '
    [ "$(codegraph_exclude_count "${BATS_TEST_TMPDIR}/repos/repo-a")" -eq 1 ]
}

@test "fetch removes the .codegraph a failed init left behind and initialises again on the next run" {
    make_bare_remote_and_clone repo-a
    replace_fake codegraph <<'EOF'
#!/bin/sh
printf 'codegraph %s (in %s)\n' "$*" "$(pwd)" >> "${FAKE_BIN_LOG}"
mkdir -p .codegraph
: > .codegraph/partial
exit 1
EOF
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not initialise codegraph"
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
    run "${GIT_DIR_SCRIPTS}/fetch"
    assert_skipped_repo_a "could not initialise codegraph"
    [ "$(grep -cxF "codegraph init (in ${BATS_TEST_TMPDIR}/repos/repo-a)" "${FAKE_BIN_LOG}")" -eq 2 ]
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
}

@test "fetch removes the .codegraph an init stopped by SIGTERM left behind, and its repo list" {
    make_bare_remote_and_clone repo-a
    local _tmp="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${_tmp}"
    # A codegraph that sends fetch SIGTERM part way through init, as a Ctrl-C
    # during a slow init would. Init runs in a subshell, which the shell may or
    # may not fork, so fetch is found by walking up the parent chain to the
    # process running the fetch script.
    replace_fake codegraph <<'EOF'
#!/bin/sh
printf 'codegraph %s (in %s)\n' "$*" "$(pwd)" >> "${FAKE_BIN_LOG}"
mkdir -p .codegraph
: > .codegraph/partial
_pid=${PPID}
while [ "${_pid}" -gt 1 ]; do
    case "$(tr '\0' ' ' < "/proc/${_pid}/cmdline")" in
        *"/git/fetch"*)
            kill -TERM "${_pid}"
            break
            ;;
    esac
    _pid=$(awk '/^PPid:/ { print $2 }' "/proc/${_pid}/status")
done
exit 143
EOF
    cd "${BATS_TEST_TMPDIR}/repos"

    TMPDIR="${_tmp}" run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"repo(s) fetched"* ]]
    assert_fake_called '^codegraph init '
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
    [ -z "$(ls -A "${_tmp}")" ]
}

@test "fetch does not initialise codegraph when codegraph is not installed" {
    make_bare_remote_and_clone repo-a
    [ -z "$(command -v codegraph)" ]
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/fetch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Initialising codegraph"* ]]
    [[ "${output}" == *"1 repo(s) fetched, 0 repo(s) skipped"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/repos/repo-a/.codegraph" ]
}

@test "the suite keeps git on PATH when codegraph is installed in the same directory as git" {
    local _bin="${BATS_TEST_TMPDIR}/shared-bin"
    mkdir -p "${_bin}"
    ln -s "$(dirname "$(command -v git)")"/* "${_bin}/"
    rm -f "${_bin}/codegraph"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/codegraph"
    chmod +x "${_bin}/codegraph"
    export PATH="${_bin}:${PATH}"
    hash -r
    remove_codegraph_from_path
    [ -z "$(command -v codegraph)" ]
    [[ "$(command -v git)" == "${BATS_TEST_TMPDIR}/path-without-codegraph."*/git ]]
    git --version
}

# ── optimise-git ─────────────────────────────────────────────────────────────

@test "optimise-git prunes, repacks, and garbage-collects every repo found" {
    make_bare_remote_and_clone repo-a
    cd "${BATS_TEST_TMPDIR}/repos"
    run "${GIT_DIR_SCRIPTS}/optimise-git"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Optimising"*"repo-a"* ]]
    [[ "${output}" == *"Done with"*"repo-a"* ]]
}

# ── rebase ───────────────────────────────────────────────────────────────────

@test "rebase fetches, rebases onto origin/main, then force-pushes" {
    setup_fake_bin git
    run "${GIT_DIR_SCRIPTS}/rebase"
    [ "${status}" -eq 0 ]
    assert_fake_called '^git fetch'
    assert_fake_called '^git rebase origin/main'
    assert_fake_called '^git push -f'
}

@test "rebase stops after a failed fetch and does not rebase or push" {
    setup_fake_bin git
    FAKE_EXIT_git=1
    export FAKE_EXIT_git
    run "${GIT_DIR_SCRIPTS}/rebase"
    [ "${status}" -ne 0 ]
    refute_fake_called '^git push'
}

# ── init-preview / update-preview / update-dotnet-sdk ───────────────────────

@test "init-preview dies when DOTNET_PREVIEW_VERSION is not set" {
    unset DOTNET_PREVIEW_VERSION
    run "${GIT_DIR_SCRIPTS}/init-preview"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DOTNET_PREVIEW_VERSION not defined"* ]]
}

@test "init-preview creates the depends/sdk/dotnet/<version>/preview branch" {
    setup_fake_bin git update-dotnet-sdk
    # env (not `export` + a separate `run`) so shellcheck doesn't flag a
    # false-positive SC2030/SC2031 cross-@test-block scope warning - each
    # @test body is a genuinely independent bats invocation at runtime.
    run env DOTNET_PREVIEW_VERSION=11 "${GIT_DIR_SCRIPTS}/init-preview"
    [ "${status}" -eq 0 ]
    assert_fake_called '^git checkout -b depends/sdk/dotnet/11/preview'
    assert_fake_called '^update-dotnet-sdk'
    [[ "${output}" == *"Branch depends/sdk/dotnet/11/preview initialised"* ]]
}

@test "update-preview dies when DOTNET_PREVIEW_VERSION is not set" {
    unset DOTNET_PREVIEW_VERSION
    run "${GIT_DIR_SCRIPTS}/update-preview"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DOTNET_PREVIEW_VERSION not defined"* ]]
}

@test "update-preview checks out the preview branch, rebases, and updates the sdk" {
    setup_fake_bin git rebase update-dotnet-sdk
    run env DOTNET_PREVIEW_VERSION=11 "${GIT_DIR_SCRIPTS}/update-preview"
    [ "${status}" -eq 0 ]
    assert_fake_called '^git checkout depends/sdk/dotnet/11/preview'
    assert_fake_called '^rebase'
    assert_fake_called '^update-dotnet-sdk'
}

@test "update-dotnet-sdk dies when DOTNET_PREVIEW_VERSION is not set" {
    unset DOTNET_PREVIEW_VERSION
    run "${GIT_DIR_SCRIPTS}/update-dotnet-sdk"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DOTNET_PREVIEW_VERSION not defined"* ]]
}

@test "update-dotnet-sdk dies when no global.json is found" {
    cd "${BATS_TEST_TMPDIR}" || exit
    run env DOTNET_PREVIEW_VERSION=11 "${GIT_DIR_SCRIPTS}/update-dotnet-sdk"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not find"* ]]
}

@test "update-dotnet-sdk updates global.json to the latest GA release and commits it" {
    setup_fake_bin git dotnet
    seed_fake_output dotnet <<'EOF'
11.0.1
11.0.2
11.0.3-preview.1
EOF
    mkdir -p "${BATS_TEST_TMPDIR}/repo"
    printf '{"sdk":{"version":"11.0.0","allowPrerelease":true}}' > "${BATS_TEST_TMPDIR}/repo/global.json"
    cd "${BATS_TEST_TMPDIR}/repo" || exit

    run env DOTNET_PREVIEW_VERSION=11 "${GIT_DIR_SCRIPTS}/update-dotnet-sdk"
    [ "${status}" -eq 0 ]
    run jq -r '.sdk.version' "${BATS_TEST_TMPDIR}/repo/global.json"
    [ "${output}" = "11.0.2" ]
    run jq -r '.sdk.allowPrerelease' "${BATS_TEST_TMPDIR}/repo/global.json"
    [ "${output}" = "false" ]
}

@test "update-dotnet-sdk fails, naming the file and keeping the original, when global.json cannot be replaced with a GA release" {
    run_update_dotnet_sdk_with_failing_mv 11.0.2
    assert_global_json_kept_after_failed_replace
}

@test "update-dotnet-sdk fails, naming the file and keeping the original, when global.json cannot be replaced with a preview release" {
    run_update_dotnet_sdk_with_failing_mv 11.0.3-preview.1
    assert_global_json_kept_after_failed_replace
}
