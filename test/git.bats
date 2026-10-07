#!/usr/bin/env bats
# Acceptance tests for settings/scripts/git/.

load test_helper

GIT_DIR_SCRIPTS="${SCRIPTS_DIR}/git"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
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

@test "update-dotnet-sdk fails, naming the file, when global.json cannot be replaced" {
    # Real mv is shadowed only for the script run; the fixture is set up
    # with the real tools first.
    mkdir -p "${BATS_TEST_TMPDIR}/repo"
    printf '{"sdk":{"version":"11.0.0","allowPrerelease":true}}' > "${BATS_TEST_TMPDIR}/repo/global.json"
    cd "${BATS_TEST_TMPDIR}/repo" || exit
    setup_fake_bin git dotnet mv
    seed_fake_output dotnet <<'EOF2'
11.0.2
EOF2

    run env DOTNET_PREVIEW_VERSION=11 FAKE_EXIT_mv=1 "${GIT_DIR_SCRIPTS}/update-dotnet-sdk"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not replace ${BATS_TEST_TMPDIR}/repo/global.json"* ]]
    refute_fake_called '^git '
}
