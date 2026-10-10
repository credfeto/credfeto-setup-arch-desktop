#!/usr/bin/env bats
# Regression tests for how install.d/shell-environment deploys its files.
# The script runs end to end against the fake sudo from test_helper, which
# logs each privileged command line and never runs it, so the deployments are
# asserted from that log without touching /etc/profile.d or
# /etc/bash.bashrc.d on the host.

bats_require_minimum_version 1.5.0

load test_helper

SHELL_ENVIRONMENT="${REPO_DIR}/install.d/shell-environment"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
}

# Runs shell-environment against the fake sudo, then writes every file
# deployment it made (each `install` other than the directory creation) to
# ${BATS_TEST_TMPDIR}/deployments, one "<mode> <source> <target>" line each.
run_shell_environment() {
    setup_fake_sudo pacman
    run "${SHELL_ENVIRONMENT}"
    [ "${status}" -eq 0 ]
    grep '^sudo install ' "${FAKE_BIN_LOG}" | grep -v '^sudo install -d ' | sed -E 's/^sudo install -m ([^ ]+) /\1 /' > "${BATS_TEST_TMPDIR}/deployments"
}

# Prints the "<source> <target>" pair every file in settings/<dir> must be
# deployed as, once for each target directory given.
# Usage: expected_deployments <dir> <target-dir> [<target-dir> ...]
expected_deployments() {
    local _dir="$1" _source _target
    shift
    for _source in "${REPO_DIR}/settings/${_dir}"/*; do
        for _target in "$@"; do
            printf '%s %s\n' "${_source}" "${_target}/$(basename "${_source}")"
        done
    done
}

@test "shell-environment deploys no file with cp" {
    # cp gives the destination the *source* file's mode when the destination
    # does not already exist. The working tree is checked out under the
    # user's umask (027 for the reporter), so every deployed file landed as
    # 0640 root:root and no ordinary user could source it. install -m sets
    # the mode explicitly instead, independent of both the checkout mode and
    # of whether the destination happened to exist.
    run ! grep -q 'sudo cp ' "${SHELL_ENVIRONMENT}"
}

@test "shell-environment deploys every file world-readable, with an explicit mode" {
    # 0644, not the 0640 these files used to land as: /etc/profile.d and
    # /etc/bash.bashrc.d are sourced by every user's shell, not just root's.
    run_shell_environment
    [ -s "${BATS_TEST_TMPDIR}/deployments" ]
    run ! grep -vE '^0644 [^ ]+ [^ ]+$' "${BATS_TEST_TMPDIR}/deployments"
}

@test "shell-environment deploys exactly the files under settings/shell-env and settings/bash.bashrc.d, each to its tier" {
    # Compared against the directory listings, so a file added to either
    # directory is deployed without editing the script, and nothing else is.
    run_shell_environment
    expected="$(
        {
            expected_deployments shell-env /etc/profile.d /etc/bash.bashrc.d
            expected_deployments bash.bashrc.d /etc/bash.bashrc.d
        } | sort
    )"
    actual="$(cut -d' ' -f2- "${BATS_TEST_TMPDIR}/deployments" | sort)"
    [ "${actual}" = "${expected}" ]
}

# Copies shell-environment, lib/common and both settings directories into a
# checkout-shaped tree under the test dir, so a test can remove files from it.
# Prints the tree's root.
setup_shell_environment_tree() {
    local _root="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "${_root}/install.d" "${_root}/lib" "${_root}/settings"
    cp "${SHELL_ENVIRONMENT}" "${_root}/install.d/"
    cp "${REPO_DIR}/lib/common" "${_root}/lib/"
    cp -r "${REPO_DIR}/settings/shell-env" "${REPO_DIR}/settings/bash.bashrc.d" "${_root}/settings/"
    printf '%s\n' "${_root}"
}

@test "shell-environment fails when settings/shell-env holds no files to deploy" {
    local _root
    _root="$(setup_shell_environment_tree)"
    rm "${_root}/settings/shell-env"/*.sh
    setup_fake_sudo pacman
    run "${_root}/install.d/shell-environment"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No shell config files found in ${_root}/settings/shell-env"* ]]
    [[ "${output}" != *"Shell environment installed"* ]]
}

@test "shell-environment fails when settings/bash.bashrc.d is missing" {
    local _root
    _root="$(setup_shell_environment_tree)"
    rm -r "${_root}/settings/bash.bashrc.d"
    setup_fake_sudo pacman
    run "${_root}/install.d/shell-environment"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No shell config files found in ${_root}/settings/bash.bashrc.d"* ]]
    [[ "${output}" != *"Shell environment installed"* ]]
}

# ── update ───────────────────────────────────────────────────────────────────
# Only the install-selection helper is exercised: update() itself runs the
# real system package manager.

# Creates a stub install script under $HOME/work/<tree> that echoes which
# tree it came from.
make_setup_install() {
    local _dir="${HOME}/work/$1/credfeto-setup-arch-desktop"
    mkdir -p "${_dir}"
    printf '#!/bin/sh\necho "%s install ran"\n' "$1" > "${_dir}/install"
    chmod +x "${_dir}/install"
}

run_update_setup_install() {
    # shellcheck source=../settings/bash.bashrc.d/95_update.sh disable=SC1091
    source "${REPO_DIR}/settings/bash.bashrc.d/95_update.sh"
    run _update_setup_arch_desktop
}

@test "update runs the reference clone's install when it exists" {
    make_setup_install reference
    make_setup_install personal

    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ "${output}" = "reference install ran" ]
}

@test "update falls back to the personal checkout's install without a reference clone" {
    make_setup_install personal

    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ "${output}" = "personal install ran" ]
}

@test "update runs no install when neither checkout exists" {
    run_update_setup_install
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# ── interactive-only bash.bashrc.d sections ─────────────────────────────────
# /etc/bash.bashrc sources bash.bashrc.d in interactive shells, and
# run-dev-update sources it non-interactively, so each interactive-only part
# is checked in both kinds of shell.

# Clears the settings 00_shell-options.sh turns on and gives PROMPT_COMMAND an
# existing hook, sources the section, then prints what it left behind.
# shellcheck disable=SC2016
SHELL_OPTIONS_SCRIPT='
shopt -u checkwinsize histappend
PROMPT_COMMAND=(existing_hook)
. "$1/00_shell-options.sh"
shopt -q checkwinsize && echo checkwinsize
shopt -q histappend && echo histappend
printf "PROMPT_COMMAND=%s\n" "${PROMPT_COMMAND[@]}"
'

@test "00_shell-options.sh in an interactive shell with no terminal sets the window and history options and appends to PROMPT_COMMAND, without calling stty" {
    setup_fake_bin stty
    # PATH is passed on so the shell finds the fake stty.
    run_section_shell PATH="${PATH}" interactive "${SHELL_OPTIONS_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'checkwinsize\nhistappend\nPROMPT_COMMAND=existing_hook\nPROMPT_COMMAND=history -a' ]
    refute_fake_called '^stty'
}

@test "00_shell-options.sh in an interactive shell with no terminal reports no stty or bind failure" {
    # No fake here: the real stty fails when stdin is not a terminal.
    run_section_shell interactive "${SHELL_OPTIONS_SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${stderr}" != *stty* ]]
    [[ "${stderr}" != *bind* ]]
}

@test "00_shell-options.sh in an interactive shell on a terminal frees ctrl-S" {
    command -v script > /dev/null || skip "script (util-linux) not installed"
    setup_fake_bin stty
    local _script_file="${BATS_TEST_TMPDIR}/shell-options-script"
    printf '%s\n' "${SHELL_OPTIONS_SCRIPT}" > "${_script_file}"
    # script gives the shell a pseudo-terminal as its stdin.
    run script -qec "$(printf 'bash --norc --noprofile +m -i %q %q' "${_script_file}" "${SECTIONS_DIR}")" /dev/null < /dev/null
    [ "${status}" -eq 0 ]
    [[ "${output}" == *checkwinsize*histappend*'PROMPT_COMMAND=history -a'* ]]
    assert_fake_called '^stty -ixon$'
}

@test "00_shell-options.sh in a non-interactive shell leaves the shell options, PROMPT_COMMAND and the terminal alone" {
    setup_fake_bin stty
    # PATH is passed on so the shell would find the fake stty.
    run_section_shell PATH="${PATH}" non-interactive "${SHELL_OPTIONS_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'PROMPT_COMMAND=existing_hook' ]
    refute_fake_called '^stty'
}

@test "00_shell-options.sh leaves no interactive-test variable behind in either kind of shell" {
    # The interactive check is made in place, so nothing is kept to hold its
    # answer. The first source in the shell, so no other section can have set
    # the name.
    # shellcheck disable=SC2016
    local _script='. "$1/00_shell-options.sh"; echo "iatest=${iatest-unset}"'
    setup_fake_bin stty
    run_section_shell PATH="${PATH}" interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'iatest=unset' ]
    run_section_shell PATH="${PATH}" non-interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'iatest=unset' ]
}

@test "40_bash-completion.sh loads bash-completion only in an interactive shell" {
    [ -f /usr/share/bash-completion/bash_completion ] || [ -f /etc/bash_completion ] || skip "bash-completion not installed"
    # bash-completion installs a default (-D) completion; bash has none
    # without it.
    # shellcheck disable=SC2016
    local _script='. "$1/40_bash-completion.sh"; complete -p -D'
    run_section_shell interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
    run_section_shell non-interactive "${_script}"
    [ "${status}" -ne 0 ]
}

@test "70_nvm.sh loads nvm's bash completion only in an interactive shell" {
    local _nvm_dir="${BATS_TEST_TMPDIR}/nvm"
    mkdir -p "${_nvm_dir}"
    echo 'nvm_completion_loaded=yes' > "${_nvm_dir}/bash_completion"
    # shellcheck disable=SC2016
    local _script='. "$1/70_nvm.sh"; echo "nvm_completion_loaded=${nvm_completion_loaded:-no}"'
    run_section_shell NVM_DIR="${_nvm_dir}" interactive "${_script}"
    [ "${output}" = 'nvm_completion_loaded=yes' ]
    run_section_shell NVM_DIR="${_nvm_dir}" non-interactive "${_script}"
    [ "${output}" = 'nvm_completion_loaded=no' ]
}

@test "78_socket-cli.sh registers socket's completion only in an interactive shell" {
    local _completion_dir="${HOME}/.local/share/socket/completion"
    mkdir -p "${_completion_dir}"
    echo '_socket_completion() { :; }' > "${_completion_dir}/socket-completion.bash"
    # shellcheck disable=SC2016
    local _script='. "$1/78_socket-cli.sh"; complete -p socket'
    run_section_shell interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'complete -F _socket_completion socket' ]
    run_section_shell non-interactive "${_script}"
    [ "${status}" -ne 0 ]
}

@test "77_autojump.sh registers autojump's completion and prompt hook only in an interactive shell" {
    [ -f /usr/share/autojump/autojump.sh ] || skip "autojump not installed"
    # shellcheck disable=SC2016
    local _script='. "$1/77_autojump.sh"
complete -p j > /dev/null 2>&1 && echo completion
[[ "${PROMPT_COMMAND[*]}" == *autojump_add_to_database* ]] && echo hook
true'
    run_section_shell interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'completion\nhook' ]
    run_section_shell non-interactive "${_script}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "14_cd-aliases.sh defines the .. to .......... and cd.. to cd.......... aliases and cleans up its variables" {
    local _expected="" _dots=".." _path=".."
    while [ "${#_dots}" -le 10 ]; do
        _expected+="alias ${_dots}='cd ${_path}'"$'\n'"alias cd${_dots}='cd ${_path}'"$'\n'
        _dots+="."
        _path="../${_path}"
    done
    # shellcheck disable=SC2016
    run_section_shell non-interactive '. "$1/14_cd-aliases.sh"; alias -p; declare -p _cd_up_path _cd_up_dots 2> /dev/null; true'
    [ "${status}" -eq 0 ]
    [ "$(sort <<< "${output}")" = "$(sort <<< "${_expected%$'\n'}")" ]
}

# ── PATH sections sourced more than once ────────────────────────────────────
# A nested interactive shell, or run-dev-update started from a terminal,
# sources these sections in a shell whose PATH already has their entries.

# Sources the named section twice, after the PATH helpers it calls, starting
# from the given PATH, and leaves the resulting PATH in $output. Any VAR=value
# arguments are set in the shell's environment first.
# Usage: run_section_twice <section-file> <starting-path> [<VAR=value> ...]
run_section_twice() {
    # shellcheck disable=SC2016
    run_section_shell "${@:3}" non-interactive 'PATH="$3"; . "$1/45_path-helpers.sh"; . "$1/$2"; . "$1/$2"; printf "%s\n" "$PATH"' "$1" "$2"
}

# Calls the named helper from 45_path-helpers.sh with a directory, starting
# from the given PATH, and leaves the resulting PATH in $output.
# Usage: run_path_helper <helper> <starting-path> <dir>
run_path_helper() {
    # shellcheck disable=SC2016
    run_section_shell non-interactive 'PATH="$3"; . "$1/45_path-helpers.sh"; "$2" "$4"; printf "%s\n" "$PATH"' "$1" "$2" "$3"
}

@test "_bashrc_d_path_append adds a directory to the end of a PATH that does not hold it" {
    run_path_helper _bashrc_d_path_append /usr/bin:/bin /opt/tool/bin
    [ "${status}" -eq 0 ]
    [ "${output}" = '/usr/bin:/bin:/opt/tool/bin' ]
}

@test "_bashrc_d_path_append leaves PATH alone when it already holds the directory, wherever it is" {
    local _path
    for _path in /opt/tool/bin:/usr/bin:/bin /usr/bin:/opt/tool/bin:/bin /usr/bin:/bin:/opt/tool/bin /opt/tool/bin; do
        run_path_helper _bashrc_d_path_append "${_path}" /opt/tool/bin
        [ "${output}" = "${_path}" ]
    done
}

@test "_bashrc_d_path_append matches whole entries only" {
    # Neither entry is /opt/tool, though both contain it.
    run_path_helper _bashrc_d_path_append /opt/tool/bin:/usr/opt/tool /opt/tool
    [ "${output}" = '/opt/tool/bin:/usr/opt/tool:/opt/tool' ]
}

@test "_bashrc_d_path_append gives an empty PATH no empty entry" {
    # An empty entry means the current directory.
    run_path_helper _bashrc_d_path_append '' /opt/tool/bin
    [ "${output}" = '/opt/tool/bin' ]
}

@test "_bashrc_d_path_prepend puts a directory at the front of a PATH that does not hold it" {
    run_path_helper _bashrc_d_path_prepend /usr/bin:/bin /opt/tool/bin
    [ "${status}" -eq 0 ]
    [ "${output}" = '/opt/tool/bin:/usr/bin:/bin' ]
}

@test "_bashrc_d_path_prepend leaves the directory first, once, wherever PATH held it and however often" {
    local _path
    for _path in /opt/tool/bin:/usr/bin:/bin /usr/bin:/opt/tool/bin:/bin /usr/bin:/bin:/opt/tool/bin \
        /opt/tool/bin:/usr/bin:/opt/tool/bin:/opt/tool/bin:/bin:/opt/tool/bin; do
        run_path_helper _bashrc_d_path_prepend "${_path}" /opt/tool/bin
        [ "${output}" = '/opt/tool/bin:/usr/bin:/bin' ]
    done
}

@test "_bashrc_d_path_prepend matches whole entries only" {
    # Neither entry is /opt/tool, though both contain it.
    run_path_helper _bashrc_d_path_prepend /opt/tool/bin:/usr/opt/tool /opt/tool
    [ "${output}" = '/opt/tool:/opt/tool/bin:/usr/opt/tool' ]
}

@test "_bashrc_d_path_prepend gives a PATH with nothing else in it no empty entry" {
    # An empty entry means the current directory.
    local _path
    for _path in '' /opt/tool/bin /opt/tool/bin:/opt/tool/bin; do
        run_path_helper _bashrc_d_path_prepend "${_path}" /opt/tool/bin
        [ "${output}" = '/opt/tool/bin' ]
    done
}

@test "_bashrc_d_path_prepend leaves no variable of its own behind" {
    # shellcheck disable=SC2016
    run_section_shell non-interactive '. "$1/45_path-helpers.sh"; _bashrc_d_path_prepend /opt/tool/bin; echo "${_bashrc_d_path_rest-unset}"'
    [ "${output}" = unset ]
}

@test "45_path-helpers.sh works in a POSIX sh, which the sh sections that call it are written for" {
    [ -x /usr/bin/dash ] || skip "dash not installed"
    mkdir -p "${HOME}/.bun/bin"
    # shellcheck disable=SC2016
    run /usr/bin/dash -c 'PATH="/usr/bin:$HOME/.bun/bin:/bin"; . "$1/45_path-helpers.sh"; . "$1/50_paths.sh"; . "$1/75_bun.sh"; . "$1/50_paths.sh"; . "$1/75_bun.sh"; printf "%s\n" "$PATH"' _ "${SECTIONS_DIR}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${HOME}/.bun/bin:/usr/bin:/bin:${HOME}/.local/bin:${HOME}/.cargo/bin" ]
}

@test "50_paths.sh adds each of its PATH entries once however often it is sourced" {
    local _toolbox="${HOME}/.local/share/JetBrains/Toolbox/scripts"
    mkdir -p "${_toolbox}"
    run_section_twice 50_paths.sh /usr/bin:/bin
    [ "${output}" = "/usr/bin:/bin:${_toolbox}:${HOME}/.local/bin:${HOME}/.cargo/bin" ]
}

@test "50_paths.sh leaves the JetBrains Toolbox scripts directory off PATH when it does not exist" {
    run_section_twice 50_paths.sh /usr/bin:/bin
    [ "${output}" = "/usr/bin:/bin:${HOME}/.local/bin:${HOME}/.cargo/bin" ]
}

@test "55_go.sh adds GOPATH/bin to PATH once however often it is sourced" {
    [ -x /usr/bin/go ] || skip "go not installed"
    local _gopath="${BATS_TEST_TMPDIR}/gopath"
    run_section_twice 55_go.sh /usr/bin:/bin GOPATH="${_gopath}"
    [ "${output}" = "/usr/bin:/bin:${_gopath}/bin" ]
}

# Sources 55_go.sh once, after the PATH helpers it calls, with a fake go that
# answers every call with the given GOPATH, and leaves the resulting PATH in
# $output. Any VAR=value arguments are set in the shell's environment first.
# Usage: run_go_section_with_fake_go <gopath-go-reports> [<VAR=value> ...]
run_go_section_with_fake_go() {
    setup_fake_bin go
    seed_fake_output go <<< "$1"
    # shellcheck disable=SC2016
    run_section_shell PATH="${FAKE_BIN_DIR}:/usr/bin:/bin" "${@:2}" non-interactive '. "$1/45_path-helpers.sh"; . "$1/55_go.sh"; printf "%s\n" "$PATH"'
}

@test "55_go.sh takes GOPATH from the environment without starting go" {
    local _gopath="${BATS_TEST_TMPDIR}/gopath"
    run_go_section_with_fake_go "${BATS_TEST_TMPDIR}/go-default" GOPATH="${_gopath}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_BIN_DIR}:/usr/bin:/bin:${_gopath}/bin" ]
    refute_fake_called '^go'
}

@test "55_go.sh asks go for GOPATH, once, when the environment has none" {
    local _gopath="${BATS_TEST_TMPDIR}/go-default"
    run_go_section_with_fake_go "${_gopath}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_BIN_DIR}:/usr/bin:/bin:${_gopath}/bin" ]
    [ "$(cat "${FAKE_BIN_LOG}")" = 'go env GOPATH' ]
}

@test "55_go.sh asks go for GOPATH when the environment's is empty" {
    local _gopath="${BATS_TEST_TMPDIR}/go-default"
    run_go_section_with_fake_go "${_gopath}" GOPATH=
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_BIN_DIR}:/usr/bin:/bin:${_gopath}/bin" ]
    [ "$(cat "${FAKE_BIN_LOG}")" = 'go env GOPATH' ]
}

@test "55_go.sh adds only the bin directory of the first entry of a GOPATH list, where go install writes" {
    local _first="${BATS_TEST_TMPDIR}/gopath-first" _second="${BATS_TEST_TMPDIR}/gopath-second"
    run_go_section_with_fake_go "${BATS_TEST_TMPDIR}/go-default" GOPATH="${_first}:${_second}"
    [ "${status}" -eq 0 ]
    # Not the list with /bin on the end, which is the first entry itself and
    # the second one's bin directory.
    [ "${output}" = "${FAKE_BIN_DIR}:/usr/bin:/bin:${_first}/bin" ]
    refute_fake_called '^go'
}

@test "55_go.sh takes the first entry of a GOPATH list that go reports" {
    local _first="${BATS_TEST_TMPDIR}/go-default-first" _second="${BATS_TEST_TMPDIR}/go-default-second"
    run_go_section_with_fake_go "${_first}:${_second}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FAKE_BIN_DIR}:/usr/bin:/bin:${_first}/bin" ]
    [ "$(cat "${FAKE_BIN_LOG}")" = 'go env GOPATH' ]
}

@test "55_go.sh leaves no variable of its own behind" {
    # Compared with the variables 45_path-helpers.sh alone leaves, in a shell
    # with no GOPATH, so anything 55_go.sh kept to hold go's answer shows up.
    setup_fake_bin go
    seed_fake_output go <<< "${BATS_TEST_TMPDIR}/go-default"
    # shellcheck disable=SC2016
    run_section_shell PATH="${FAKE_BIN_DIR}:/usr/bin:/bin" non-interactive '. "$1/45_path-helpers.sh"; before="$(compgen -v)"; . "$1/55_go.sh"; diff <(printf "%s\n" "$before" before | sort) <(compgen -v | sort)'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "60_dotnet.sh adds DOTNET_ROOT to PATH once however often it is sourced" {
    run_section_twice 60_dotnet.sh /usr/bin:/bin
    if [ -d /usr/share/dotnet ]; then
        [ "${output}" = '/usr/bin:/bin:/usr/share/dotnet' ]
    else
        [ "${output}" = '/usr/bin:/bin' ]
    fi
}

@test "75_bun.sh puts bun first on PATH once however often it is sourced" {
    mkdir -p "${HOME}/.bun/bin"
    run_section_twice 75_bun.sh /usr/bin:/bin
    [ "${output}" = "${HOME}/.bun/bin:/usr/bin:/bin" ]
}

@test "75_bun.sh moves bun to the front of a PATH that has it in the middle, leaving it there once" {
    mkdir -p "${HOME}/.bun/bin"
    run_section_twice 75_bun.sh "/usr/bin:${HOME}/.bun/bin:/bin"
    [ "${output}" = "${HOME}/.bun/bin:/usr/bin:/bin" ]
}

@test "75_bun.sh moves bun to the front of a PATH that has it at the end, leaving it there once" {
    mkdir -p "${HOME}/.bun/bin"
    run_section_twice 75_bun.sh "/usr/bin:/bin:${HOME}/.bun/bin"
    [ "${output}" = "${HOME}/.bun/bin:/usr/bin:/bin" ]
}

@test "75_bun.sh leaves PATH alone when there is no ~/.bun" {
    run_section_twice 75_bun.sh /usr/bin:/bin
    [ "${output}" = '/usr/bin:/bin' ]
}
