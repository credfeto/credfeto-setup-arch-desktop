#!/usr/bin/env bats
# Tests for the environment test_helper's run_with_clean_tool_env gives the
# code under test, which every suite that sources a bash.bashrc.d section
# relies on to keep the settings of whoever runs the suite out of the result
# and what the code creates out of their home.

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
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
    [ -f /usr/share/nvm/init-nvm.sh ] || skip "nvm package not installed"
    # Stands in for the real ~/.config of whoever runs the suite, which
    # 20_xdg-dirs.sh exports on every machine this repo installs.
    # shellcheck disable=SC2016
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/callers-config" run_section_shell non-interactive '. "$1/45_path-helpers.sh"; . "$1/70_nvm.sh"; printf "%s\n" "${NVM_DIR}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "${HOME}/.config/nvm" ]
    [ -L "${HOME}/.config/nvm/nvm.sh" ]
    [ ! -e "${BATS_TEST_TMPDIR}/callers-config" ]
}
