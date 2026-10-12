#!/usr/bin/env bats
# Tests for the environment test_helper gives the code under test. Loading it
# clears the variables that name a git repository, so a suite started from a
# git hook works on its own scratch repositories. Its run_with_clean_tool_env
# is what every suite that sources a bash.bashrc.d section relies on to keep
# the settings of whoever runs the suite out of the result and what the code
# creates out of their home.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # The git these tests run must read no config of whoever runs the suite.
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
}

# Creates a repository with one commit whose git directory sits apart from
# its working tree, which is what makes git export GIT_DIR to the hooks it
# runs there. Sets DECOY_GIT_DIR.
setup_decoy_repository() {
    DECOY_GIT_DIR="${BATS_TEST_TMPDIR}/decoy.git"
    git init --quiet --separate-git-dir "${DECOY_GIT_DIR}" "${BATS_TEST_TMPDIR}/decoy"
    git -C "${BATS_TEST_TMPDIR}/decoy" -c user.name=Decoy -c user.email=decoy@example.com \
        commit --quiet --allow-empty -m "decoy"
}

# Prints the decoy's config, every ref with the commit it points at, and
# what its index holds.
decoy_state() {
    cat "${DECOY_GIT_DIR}/config"
    git --git-dir="${DECOY_GIT_DIR}" show-ref --head
    git --git-dir="${DECOY_GIT_DIR}" ls-files --stage
}

# Writes a suite that loads test_helper and then uses git the way the real
# suites do: a bare and a plain scratch repository, an identity, a commit and
# a staged file. Prints its path.
write_git_using_suite() {
    local _suite="${BATS_TEST_TMPDIR}/git-using.bats"
    cat > "${_suite}" <<EOF
load "${REPO_DIR}/test/test_helper"

@test "git works on the scratch repositories" {
    cd "\${BATS_TEST_TMPDIR}"
    git init --quiet --bare origin.git
    git init --quiet repo
    git -C repo config user.email "test@example.com"
    git -C repo config user.name "Test"
    git -C repo commit --quiet --allow-empty -m "initial"
    : > repo/Changed.cs
    git -C repo add Changed.cs

    [ "\$(git -C origin.git rev-parse --is-bare-repository)" = true ]
    [ "\$(git -C repo rev-parse --absolute-git-dir)" = "\$(readlink -f repo/.git)" ]
    [ "\$(git -C repo config --local user.name)" = Test ]
    [ "\$(git -C repo log --format=%s)" = initial ]
    [ "\$(git -C repo ls-files)" = Changed.cs ]
}
EOF
    printf '%s\n' "${_suite}"
}

@test "a suite started from a git hook leaves the hook's repository untouched and works on its own scratch repositories" {
    local _suite _before
    setup_decoy_repository
    _suite="$(write_git_using_suite)"
    _before="$(decoy_state)"

    # What git exports to a pre-commit hook of a repository like the decoy.
    run env GIT_DIR="${DECOY_GIT_DIR}" GIT_INDEX_FILE="${DECOY_GIT_DIR}/index" GIT_PREFIX= bats "${_suite}"
    [ "$(decoy_state)" = "${_before}" ]
    [ "${status}" -eq 0 ]
}

@test "loading test_helper clears every variable git lists as naming a repository" {
    local _elsewhere="${BATS_TEST_TMPDIR}/elsewhere" _var
    local -a _named=()
    while IFS= read -r _var; do
        _named+=("${_var}=${_elsewhere}")
    done < <(git rev-parse --local-env-vars)
    [ "${#_named[@]}" -gt 0 ]

    # shellcheck disable=SC2016 # expanded by the bash that env starts
    run env "${_named[@]}" bash -c '. "$1" && env' _ "${REPO_DIR}/test/test_helper.bash"
    [ "${status}" -eq 0 ]
    run ! grep -F "${_elsewhere}" <<< "${output}"
}

# Loads test_helper in a bash of its own, which prints "loaded" only when
# the load ran to its end.
load_test_helper_afresh() {
    # shellcheck disable=SC2016 # expanded by the bash that run starts
    run --separate-stderr bash -c '. "$1"; echo loaded' _ "${REPO_DIR}/test/test_helper.bash"
}

@test "loading test_helper stops when git fails to list its repository variables" {
    setup_fake_bin git
    export FAKE_EXIT_git=1
    load_test_helper_afresh
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"git did not list its repository variables"* ]]
}

@test "loading test_helper stops when git lists no repository variables" {
    setup_fake_bin git
    load_test_helper_afresh
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"git did not list its repository variables"* ]]
}

@test "run_with_clean_tool_env clears the caller's tool settings and gives the command a minimal PATH" {
    NVM_DIR=/caller/nvm GOPATH=/caller/go BUN_INSTALL=/caller/bun DOTNET_NOLOGO=caller DOTNET_ROOT=/caller/dotnet LINUX_DISTRIBUTION=caller \
        run run_with_clean_tool_env env
    [ "${status}" -eq 0 ]
    grep -qx 'PATH=/usr/bin:/bin' <<< "${output}"
    run ! grep -E '^(NVM_DIR|GOPATH|BUN_INSTALL|DOTNET_NOLOGO|DOTNET_ROOT|LINUX_DISTRIBUTION)=' <<< "${output}"
}

@test "run_with_clean_tool_env points the XDG base directories at the test's HOME, whatever the caller has them set to" {
    XDG_CONFIG_HOME=/caller/config XDG_DATA_HOME=/caller/data XDG_STATE_HOME=/caller/state XDG_CACHE_HOME=/caller/cache \
        run run_with_clean_tool_env env
    [ "${status}" -eq 0 ]
    grep -qx "XDG_CONFIG_HOME=${HOME}/.config" <<< "${output}"
    grep -qx "XDG_DATA_HOME=${HOME}/.local/share" <<< "${output}"
    grep -qx "XDG_STATE_HOME=${HOME}/.local/state" <<< "${output}"
    grep -qx "XDG_CACHE_HOME=${HOME}/.cache" <<< "${output}"
    run ! grep -F '/caller/' <<< "${output}"
}

@test "run_with_clean_tool_env does the same when the caller has no XDG base directories set" {
    # env -u, not unset, so shellcheck does not flag a cross-@test
    # modification (SC2030/SC2031). The function is exported for the bash
    # that env starts.
    export -f run_with_clean_tool_env
    run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME bash -c 'run_with_clean_tool_env env'
    [ "${status}" -eq 0 ]
    grep -qx "XDG_CONFIG_HOME=${HOME}/.config" <<< "${output}"
    grep -qx "XDG_CACHE_HOME=${HOME}/.cache" <<< "${output}"
}

@test "run_with_clean_tool_env applies a VAR=value argument after its own settings" {
    run run_with_clean_tool_env NVM_DIR=/chosen/nvm XDG_CONFIG_HOME=/chosen/config /usr/bin/env
    [ "${status}" -eq 0 ]
    grep -qx 'NVM_DIR=/chosen/nvm' <<< "${output}"
    grep -qx 'XDG_CONFIG_HOME=/chosen/config' <<< "${output}"
}

@test "run_with_clean_tool_env does not run the command when HOME is not the test's own" {
    local _marker="${BATS_TEST_TMPDIR}/ran"
    HOME=/nonexistent/real-home run --separate-stderr run_with_clean_tool_env touch "${_marker}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"HOME (/nonexistent/real-home) is not under the test's temporary directory"* ]]
    [ ! -e "${_marker}" ]
}

@test "70_nvm.sh run through the clean environment sets nvm up under the test's HOME, not where the caller's XDG_CONFIG_HOME points" {
    local _package _section
    _package="$(setup_fake_nvm_package)"
    _section="$(nvm_section_reading "${_package}")"
    # Stands in for the real ~/.config of whoever runs the suite, which
    # 20_xdg-dirs.sh exports on every machine this repo installs.
    # shellcheck disable=SC2016
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/callers-config" run_section_shell non-interactive '. "$2"; printf "%s\n" "${NVM_DIR}"' "${_section}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${HOME}/.config/nvm" ]
    [ "$(readlink "${HOME}/.config/nvm/nvm.sh")" = "${_package}/nvm.sh" ]
    [ ! -e "${BATS_TEST_TMPDIR}/callers-config" ]
}
