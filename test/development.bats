#!/usr/bin/env bats
# Acceptance tests for settings/scripts/development/. buildcheck/buildtest
# (vendored from credfeto-global-pre-commit/src/scripts, not credfeto/scripts
# - see final migration report) also require benchmark-test-affected,
# latest-target-framework, and dacpac-only-solution as siblings.

load test_helper

DEV_DIR="${SCRIPTS_DIR}/development"
PRE_COMMIT_CHECK="${DEV_DIR}/pre-commit-check"
BUILDCHECK="${DEV_DIR}/buildcheck"
BUILDTEST="${DEV_DIR}/buildtest"

setup() {
    # Isolate every test from the real machine's global/system git config -
    # pre-commit-check and buildtest's require_dotnet_tool both consult it.
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
}

# A dotnet fake whose `tool list`/`tool list --global` output satisfies
# require_dotnet_tool for buildcheck/FunFair.BuildCheck; every other
# subcommand just logs and succeeds, like the plain setup_fake_bin fakes.
setup_fake_dotnet_with_buildcheck_tool() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    mkdir -p "${FAKE_BIN_DIR}"
    : > "${FAKE_BIN_LOG}"
    cat > "${FAKE_BIN_DIR}/dotnet" <<'EOF'
#!/bin/sh
printf 'dotnet %s\n' "$*" >> "__FAKE_BIN_LOG__"
case "$1 $2" in
    "tool list")
        printf 'Package Id      Version      Commands\n----------------------------------------\nfunfair.buildcheck   1.0.0   buildcheck\n'
        ;;
esac
exit 0
EOF
    sed -i "s#__FAKE_BIN_LOG__#${FAKE_BIN_LOG}#" "${FAKE_BIN_DIR}/dotnet"
    chmod +x "${FAKE_BIN_DIR}/dotnet"
    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

# ── pre-commit-check ────────────────────────────────────────────────────────

@test "pre-commit-check dies when no hook is found anywhere" {
    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No pre-commit hook found"* ]]
}

@test "pre-commit-check runs the repo's own hooks/pre-commit" {
    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    cat > "${BATS_TEST_TMPDIR}/repo/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "ran with: $*"
exit 0
EOF
    chmod +x "${BATS_TEST_TMPDIR}/repo/.git/hooks/pre-commit"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ran with: --all-files"* ]]
    [[ "${output}" == *"Pre-commit checks passed"* ]]
}

@test "pre-commit-check dies when the repo's hook fails" {
    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    cat > "${BATS_TEST_TMPDIR}/repo/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${BATS_TEST_TMPDIR}/repo/.git/hooks/pre-commit"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"pre-commit hook failed"* ]]
}

# Creates a bare "origin.git" plus a working repo remote-added and pushed to
# it, with a commit already made and identity configured. Returns via globals
# ORIGIN and REPO (both under BATS_TEST_TMPDIR).
setup_origin_and_repo() {
    ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init --quiet --bare "${ORIGIN}"
    git init --quiet "${REPO}"
    git -C "${REPO}" config user.email "test@example.com"
    git -C "${REPO}" config user.name "Test"
    git -C "${REPO}" commit --quiet --allow-empty -m "initial"
    git -C "${REPO}" remote add origin "${ORIGIN}"
    git -C "${REPO}" push --quiet -u origin HEAD:main
    git -C "${ORIGIN}" symbolic-ref HEAD refs/heads/main
}

add_passing_hook() {
    cat > "$1/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "ran with: $*"
exit 0
EOF
    chmod +x "$1/.git/hooks/pre-commit"
}

# Pushes an extra commit to origin's main branch via a throwaway clone, so
# REPO (which doesn't fetch it) becomes behind.
advance_origin_main() {
    ADVANCER="${BATS_TEST_TMPDIR}/advancer"
    git clone --quiet "${ORIGIN}" "${ADVANCER}"
    git -C "${ADVANCER}" config user.email "test@example.com"
    git -C "${ADVANCER}" config user.name "Test"
    git -C "${ADVANCER}" commit --quiet --allow-empty -m "advance"
    git -C "${ADVANCER}" push --quiet origin HEAD:main
}

@test "pre-commit-check passes when branch is up to date with its upstream" {
    setup_origin_and_repo
    add_passing_hook "${REPO}"
    cd "${REPO}"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Pre-commit checks passed"* ]]
}

@test "pre-commit-check dies when branch is behind its own upstream" {
    setup_origin_and_repo
    add_passing_hook "${REPO}"
    advance_origin_main
    cd "${REPO}"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"behind origin/main"* ]]
}

@test "pre-commit-check checks against the default branch when current branch has no upstream" {
    setup_origin_and_repo
    git -C "${REPO}" checkout --quiet -b feature --no-track origin/main
    add_passing_hook "${REPO}"
    advance_origin_main
    cd "${REPO}"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"behind origin/main"* ]]
}

@test "pre-commit-check dies when up to date with its own upstream but behind the default branch" {
    setup_origin_and_repo
    git -C "${REPO}" checkout --quiet -b feature
    git -C "${REPO}" push --quiet -u origin feature
    add_passing_hook "${REPO}"
    advance_origin_main
    cd "${REPO}"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"behind origin/main"* ]]
}

@test "pre-commit-check dies when origin cannot be fetched" {
    setup_origin_and_repo
    add_passing_hook "${REPO}"
    git -C "${REPO}" remote set-url origin "${BATS_TEST_TMPDIR}/does-not-exist.git"
    cd "${REPO}"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not fetch origin"* ]]
}

@test "pre-commit-check falls back to the globally configured hooksPath" {
    mkdir -p "${BATS_TEST_TMPDIR}/global-hooks"
    cat > "${BATS_TEST_TMPDIR}/global-hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "global hook ran"
exit 0
EOF
    chmod +x "${BATS_TEST_TMPDIR}/global-hooks/pre-commit"

    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
    git config --global core.hooksPath "${BATS_TEST_TMPDIR}/global-hooks"

    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${PRE_COMMIT_CHECK}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global hook ran"* ]]
}

# ── buildcheck ───────────────────────────────────────────────────────────────
# require_dotnet_tool runs before anything else, so every buildcheck test
# needs the FunFair.BuildCheck tool-list gate satisfied one way or another.

@test "buildcheck dies with the AI-agent guidance when the required tool is missing and CLAUDECODE=1" {
    export CLAUDECODE=1
    cd "${BATS_TEST_TMPDIR}"
    run "${BUILDCHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Required package (FunFair.BuildCheck) is not installed"* ]]
}

@test "buildcheck dies with a plain message when the required tool is missing and not an AI agent" {
    unset CLAUDECODE
    cd "${BATS_TEST_TMPDIR}"
    run "${BUILDCHECK}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"buildcheck (FunFair.BuildCheck) dotnet tool is not installed"* ]]
}

@test "buildcheck skips (exit 0) when the tool is present but no solution file is found" {
    setup_fake_dotnet_with_buildcheck_tool
    cd "${BATS_TEST_TMPDIR}"
    run "${BUILDCHECK}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No solution file found"* ]]
}

@test "buildcheck runs dotnet buildcheck against the found solution" {
    setup_fake_dotnet_with_buildcheck_tool
    mkdir -p "${BATS_TEST_TMPDIR}/repo/src"
    printf 'dummy' > "${BATS_TEST_TMPDIR}/repo/src/Foo.slnx"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${BUILDCHECK}"
    [ "${status}" -eq 0 ]
    assert_fake_called 'buildcheck -Solution .*Foo\.slnx -WarningAsErrors true -PreReleaseBuild true'
}

# ── buildtest ────────────────────────────────────────────────────────────────
# The default path (no ruleset override present) never calls
# require_dotnet_tool, so these don't need the tool-list gate.

@test "buildtest skips (exit 0) when no .csproj files are found" {
    cd "${BATS_TEST_TMPDIR}"
    run "${BUILDTEST}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No .csproj files found"* ]]
}

@test "buildtest skips (exit 0) when a .csproj exists but no solution file does" {
    mkdir -p "${BATS_TEST_TMPDIR}/repo"
    printf '<Project Sdk="Microsoft.NET.Sdk"></Project>' > "${BATS_TEST_TMPDIR}/repo/Foo.csproj"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${BUILDTEST}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No solution file found"* ]]
}

@test "buildtest runs the dotnet pipeline and skips testing a dacpac-only solution" {
    setup_fake_bin dotnet
    mkdir -p "${BATS_TEST_TMPDIR}/repo/src/Foo.Database"
    cd "${BATS_TEST_TMPDIR}/repo"
    git init --quiet
    printf '<Project></Project>' > src/Foo.slnx
    printf '<Project Sdk="MSBuild.Sdk.SqlProj/2.5.0"></Project>' > src/Foo.Database/Foo.Database.csproj

    run "${BUILDTEST}"
    [ "${status}" -eq 0 ]
    assert_fake_called '^dotnet nuget locals http-cache --clear'
    assert_fake_called '^dotnet tool restore'
    assert_fake_called '^dotnet restore'
    assert_fake_called '^dotnet clean'
    assert_fake_called '^dotnet build '
    refute_fake_called '^dotnet test '
    [[ "${output}" == *"Only project in solution is a SQL Server database project (dacpac)"* ]]
    [[ "${output}" == *"Completed"* ]]
}
