#!/usr/bin/env bats
# Tests for the environment test_helper gives the code under test. Loading it
# clears the variables that name a git repository, so a suite started from a
# git hook works on its own scratch repositories, and points git at no global
# and no system config, so no suite reads the git settings of whoever runs it
# or of the machine. Its run_with_clean_tool_env
# is what every suite that sources a bash.bashrc.d section relies on to keep
# the settings of whoever runs the suite out of the result and what the code
# creates out of their home.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
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

GIT_USING_TEST_NAME="git works on the scratch repositories"

# Writes a suite that loads test_helper and then uses git the way the real
# suites do: a bare and a plain scratch repository, an identity, a commit and
# a staged file. Prints its path.
#
# The line that declares the suite's test is printed rather than written out
# in the heredoc: bats finds tests by matching each line of a file, heredocs
# included, so a line here that began with the test keyword would be taken
# for a test of this file and rewritten before the heredoc was ever read.
write_git_using_suite() {
    local _suite="${BATS_TEST_TMPDIR}/git-using.bats"
    {
        printf 'load "%s/test/test_helper"\n\n' "${REPO_DIR}"
        printf '%s "%s" {\n' '@test' "${GIT_USING_TEST_NAME}"
        cat <<'EOF'
    cd "${BATS_TEST_TMPDIR}"
    git init --quiet --bare origin.git
    git init --quiet repo
    git -C repo config user.email "test@example.com"
    git -C repo config user.name "Test"
    git -C repo commit --quiet --allow-empty -m "initial"
    : > repo/Changed.cs
    git -C repo add Changed.cs

    [ "$(git -C origin.git rev-parse --is-bare-repository)" = true ]
    [ "$(git -C repo rev-parse --absolute-git-dir)" = "$(readlink -f repo/.git)" ]
    [ "$(git -C repo config --local user.name)" = Test ]
    [ "$(git -C repo log --format=%s)" = initial ]
    [ "$(git -C repo ls-files)" = Changed.cs ]
}
EOF
    } > "${_suite}"
    printf '%s\n' "${_suite}"
}

# Succeeds when load_test_helper_afresh ran the load to its end and left no
# GIT_ variable set but the two test_helper sets itself.
assert_loaded_with_only_the_config_isolation_set() {
    [ "${lines[0]}" = loaded ] || return 1
    [ "${#lines[@]}" -eq 3 ] || return 1
    grep -qx GIT_CONFIG_GLOBAL <<< "${output}" || return 1
    grep -qx GIT_CONFIG_SYSTEM <<< "${output}"
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
    # A suite bats found no test in passes as well, having run no git at all.
    [ "${lines[0]}" = "1..1" ]
    [ "${lines[1]}" = "ok 1 ${GIT_USING_TEST_NAME}" ]
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

@test "every variable git lists as naming a repository starts with GIT_" {
    # test_helper asks git for the list only when a GIT_ variable is set, so
    # a listed name without the prefix would be one it could leave in place.
    run git rev-parse --local-env-vars
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -gt 0 ]
    run ! grep -v '^GIT_' <<< "${output}"
}

# Runs the given script in a bash of its own that has loaded test_helper
# first, with the path of test_helper as $1. That bash starts with no GIT_
# variable but the ones given, whatever the load of this file, setup and
# whoever runs the suite have set.
# Usage: run_after_loading_test_helper_afresh <script> [<VAR=value> ...]
run_after_loading_test_helper_afresh() {
    local _script="$1" _var
    local -a _env=()
    shift
    for _var in "${!GIT_@}"; do
        _env+=(-u "${_var}")
    done
    run --separate-stderr env "${_env[@]}" "$@" bash -c ". \"\$1\"; ${_script}" _ "${REPO_DIR}/test/test_helper.bash"
}

# Loads test_helper in such a bash, which prints "loaded" only when the load
# ran to its end, then the name of each GIT_ variable still set, one a line.
# Usage: load_test_helper_afresh [<GIT_VAR=value> ...]
load_test_helper_afresh() {
    # shellcheck disable=SC2016 # expanded by the bash that env starts
    run_after_loading_test_helper_afresh 'printf "%s\n" loaded ${!GIT_@}' "$@"
}

# Writes a git config file holding the setting decoy.<name> = seen at the
# given path, for a test to find out whether git reads that file.
# Usage: write_decoy_git_config <path> <name>
write_decoy_git_config() {
    mkdir -p "${1%/*}"
    printf '[decoy]\n\t%s = seen\n' "$2" > "$1"
}

# Prints every decoy setting the git config in force holds, as git sees it
# from a directory that is in no repository.
# shellcheck disable=SC2016 # expanded by the bash that runs it
DECOY_SETTINGS_SEEN='git -C "${BATS_TEST_TMPDIR}" config --get-regexp "^decoy\\."'

@test "loading test_helper stops when git fails to list its repository variables" {
    setup_fake_bin git
    export FAKE_EXIT_git=1
    load_test_helper_afresh GIT_INDEX_FILE="${BATS_TEST_TMPDIR}/index"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"git did not list its repository variables"* ]]
}

@test "loading test_helper stops when git lists no repository variables" {
    setup_fake_bin git
    load_test_helper_afresh GIT_INDEX_FILE="${BATS_TEST_TMPDIR}/index"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"git did not list its repository variables"* ]]
}

@test "loading test_helper asks git for the list when the only GIT_ variable set is one git does not list" {
    # GIT_EDITOR is what git gives a pre-commit hook when the commit opens no
    # editor. Nothing tells it apart from a listed variable but the list.
    setup_fake_bin git
    load_test_helper_afresh GIT_EDITOR=:
    [ "${status}" -eq 1 ]
    assert_fake_called '^git rev-parse --local-env-vars$'
}

@test "loading test_helper asks git for the list and clears a listed variable that is set but empty" {
    # A variable git lists counts as set with no value: it is the name being
    # set that sends the load to git, not what the variable holds.
    setup_fake_bin git
    seed_fake_output git <<< "GIT_INDEX_FILE"
    load_test_helper_afresh GIT_INDEX_FILE=
    [ "${status}" -eq 0 ]
    assert_fake_called '^git rev-parse --local-env-vars$'
    # The variable is no longer set.
    assert_loaded_with_only_the_config_isolation_set
}

@test "loading test_helper does not start git when no GIT_ variable is set" {
    # The fake lists nothing, so the load would stop if git were asked.
    setup_fake_bin git
    load_test_helper_afresh
    [ "${status}" -eq 0 ]
    assert_loaded_with_only_the_config_isolation_set
    [ -z "${stderr}" ]
    [ ! -s "${FAKE_BIN_LOG}" ]
}

@test "loading test_helper does not start git when the only GIT_ variables set are the two it sets itself" {
    # What every load after the first inherits: bats loads test_helper for
    # the file and again in the process of each test. The fake lists nothing,
    # so the load would stop if git were asked.
    setup_fake_bin git
    load_test_helper_afresh GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    [ "${status}" -eq 0 ]
    assert_loaded_with_only_the_config_isolation_set
    [ -z "${stderr}" ]
    [ ! -s "${FAKE_BIN_LOG}" ]
}

@test "loading test_helper still asks git for the list when a repository or config variable is set beside the two it sets itself" {
    # GIT_CONFIG, GIT_CONFIG_COUNT and GIT_CONFIG_PARAMETERS begin as the
    # helper's own names do, and GIT_CONFIG_GLOBAL_ and GIT_CONFIG_NOSYSTEM
    # are near them without being listed: none may pass for one of the two.
    local _var
    setup_fake_bin git
    for _var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL_ GIT_CONFIG_NOSYSTEM; do
        : > "${FAKE_BIN_LOG}"
        load_test_helper_afresh GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "${_var}=${BATS_TEST_TMPDIR}/elsewhere"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"git did not list its repository variables"* ]]
        assert_fake_called '^git rev-parse --local-env-vars$'
    done
}

@test "git lists neither of the variables test_helper sets itself as naming a repository" {
    # test_helper does not ask git for the list when these are the only GIT_
    # variables set, so one that git listed would be one it left in place.
    run git rev-parse --local-env-vars
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -gt 0 ]
    run ! grep -x -e GIT_CONFIG_GLOBAL -e GIT_CONFIG_SYSTEM <<< "${output}"
}

@test "git reads no global config after test_helper loads, in HOME or under XDG_CONFIG_HOME" {
    # Stand in for the ~/.gitconfig and ~/.config/git/config of whoever runs
    # the suite. This file loaded test_helper before the test started.
    local _xdg="${BATS_TEST_TMPDIR}/xdg"
    write_decoy_git_config "${HOME}/.gitconfig" home
    write_decoy_git_config "${_xdg}/git/config" xdg

    # Precondition: git reads both when it is not told where its config is.
    XDG_CONFIG_HOME="${_xdg}" run env -u GIT_CONFIG_GLOBAL git -C "${BATS_TEST_TMPDIR}" config --get-regexp '^decoy\.'
    [ "${status}" -eq 0 ]
    [ "${output}" = "decoy.xdg seen
decoy.home seen" ]

    XDG_CONFIG_HOME="${_xdg}" run git -C "${BATS_TEST_TMPDIR}" config --get-regexp '^decoy\.'
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "git finds an empty global and an empty system config after test_helper loads" {
    # The machine's /etc/gitconfig cannot be stood in for, so this asks git
    # for all it holds at each scope. Left to itself git prints the settings
    # of whoever runs the suite and of the machine, and fails where there is
    # no such file, as there is no ~/.gitconfig in the test's HOME.
    local _scope
    for _scope in --global --system; do
        run --separate-stderr git config "${_scope}" --list
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
        [ -z "${stderr}" ]
    done
    [ "${GIT_CONFIG_GLOBAL}" = /dev/null ]
    [ "${GIT_CONFIG_SYSTEM}" = /dev/null ]
}

@test "loading test_helper replaces a global and a system config the caller points git at" {
    local _global="${BATS_TEST_TMPDIR}/callers/gitconfig" _system="${BATS_TEST_TMPDIR}/callers/etc-gitconfig"
    write_decoy_git_config "${_global}" global
    write_decoy_git_config "${_system}" system

    # Precondition: git reads both where the caller points it.
    run env GIT_CONFIG_GLOBAL="${_global}" GIT_CONFIG_SYSTEM="${_system}" git -C "${BATS_TEST_TMPDIR}" config --get-regexp '^decoy\.'
    [ "${status}" -eq 0 ]
    [ "${output}" = "decoy.system seen
decoy.global seen" ]

    run_after_loading_test_helper_afresh "${DECOY_SETTINGS_SEEN}" GIT_CONFIG_GLOBAL="${_global}" GIT_CONFIG_SYSTEM="${_system}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "loading test_helper clears the config a caller gives git through the environment" {
    local -a _given=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=decoy.counted GIT_CONFIG_VALUE_0=seen "GIT_CONFIG_PARAMETERS='decoy.parameter=seen'")

    # Precondition: git takes both settings from the environment.
    run env "${_given[@]}" git -C "${BATS_TEST_TMPDIR}" config --get-regexp '^decoy\.'
    [ "${status}" -eq 0 ]
    [ "${output}" = "decoy.counted seen
decoy.parameter seen" ]

    run_after_loading_test_helper_afresh "${DECOY_SETTINGS_SEEN}" "${_given[@]}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "a script a test runs after test_helper loads inherits the config isolation" {
    # A script under test is a process of its own, as this one is, and the
    # git it runs must read no more than the git of the test does.
    local _script="${BATS_TEST_TMPDIR}/script-under-test"
    write_decoy_git_config "${HOME}/.gitconfig" home
    cat > "${_script}" <<'EOF'
#!/bin/sh
printf '%s\n' "global=${GIT_CONFIG_GLOBAL-unset}" "system=${GIT_CONFIG_SYSTEM-unset}"
git config --global --list
git config --system --list
EOF
    chmod +x "${_script}"

    run "${_script}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "global=/dev/null
system=/dev/null" ]
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

@test "section_reading substitutes a directory whose name holds sed's special characters literally" {
    # An ampersand, the delimiter and a back-reference are what a sed
    # replacement would act on; the space is what a shell would split on.
    local _package="${BATS_TEST_TMPDIR}/R&D a|b\\1 c"
    printf '%s\n' '[ -f /usr/share/pkg/load.sh ] && . /usr/share/pkg/load.sh' 'unrelated' > "${BATS_TEST_TMPDIR}/section.sh"

    SECTIONS_DIR="${BATS_TEST_TMPDIR}" run section_reading section.sh /usr/share/pkg "${_package}" "[ -f ${_package}/load.sh ]"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${BATS_TEST_TMPDIR}/sections/section.sh" ]
    [ "$(cat "${output}")" = "[ -f ${_package}/load.sh ] && . ${_package}/load.sh
unrelated" ]
}

@test "section_reading leaves alone a directory the system directory only matches as a pattern" {
    # The system directory's "." and "*" would match the second line as a
    # regular expression and the third as a glob.
    printf '%s\n' '. /opt/pkg.d*/load.sh' '. /opt/pkgXd/load.sh' '. /opt/pkg.dir/load.sh' > "${BATS_TEST_TMPDIR}/section.sh"

    SECTIONS_DIR="${BATS_TEST_TMPDIR}" run section_reading section.sh '/opt/pkg.d*' /elsewhere
    [ "${status}" -eq 0 ]
    [ "$(cat "${output}")" = ". /elsewhere/load.sh
. /opt/pkgXd/load.sh
. /opt/pkg.dir/load.sh" ]
}
