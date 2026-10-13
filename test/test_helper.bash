#!/usr/bin/env bash
# Shared helpers for the bats suites covering settings/scripts/ and the
# install.d/ mechanism that deploys them.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Consumed by the .bats files that `load test_helper`, not by this file
# itself, so shellcheck's single-file analysis can't see the use.
# shellcheck disable=SC2034
SCRIPTS_DIR="${REPO_DIR}/settings/scripts"
SECTIONS_DIR="${REPO_DIR}/settings/bash.bashrc.d"

# The variables isolate_git_config sets, and so the only GIT_ variables
# clear_git_repository_env does not ask git about. The array's own name must
# not start with GIT_: it would then be one of the variables looked at.
ISOLATED_GIT_CONFIG_VARS=(GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM)

# Clears the variables that tell git which repository to act on. git exports
# some of them to the hooks it runs: GIT_INDEX_FILE always, and GIT_DIR when
# the repository's .git is a file naming a git directory elsewhere, as it is
# in a linked worktree. A git command that inherits them acts on the
# repository they name whatever directory or -C it is given, so a suite
# started from a pre-commit hook would set up its scratch repositories
# inside the repository being committed to. The list is git's own rather
# than one kept here, so a variable a later git adds is cleared as well, and
# git prints it without looking for a repository, so it does not matter
# where the suite is started from.
#
# git is not asked when no variable whose name starts with GIT_ is set but
# the ones this helper sets itself, which is the usual case and saves starting
# it for every test: every name it lists starts with GIT_, and none is one of
# this helper's (test-helper.bats fails if either ever stops being so), so
# there is then nothing it could name. The helper's own names have to be let
# through because a load exports them and the next one inherits them: bats
# loads the helper once for the file and again in the process of each test.
# They are matched whole, so GIT_CONFIG, GIT_CONFIG_COUNT and
# GIT_CONFIG_PARAMETERS, which git does list, still send the load to git. Any
# other GIT_ variable only costs the call, and once git is asked, a list that
# cannot be had still stops the load. The check is a parameter expansion,
# which bash always has, rather than compgen, which a bash built without
# completion lacks: the load would carry on as if nothing were set.
clear_git_repository_env() {
    local _vars _var _ask=""
    for _var in "${!GIT_@}"; do
        case " ${ISOLATED_GIT_CONFIG_VARS[*]} " in
            *" ${_var} "*) ;;
            *)
                _ask=yes
                break
                ;;
        esac
    done
    [ -n "${_ask}" ] || return 0
    if ! _vars="$(git rev-parse --local-env-vars)" || [ -z "${_vars}" ]; then
        echo "clear_git_repository_env: git did not list its repository variables" >&2
        return 1
    fi
    while IFS= read -r _var; do
        unset "${_var}"
    done <<< "${_vars}"
}

# Points git at no global and no system config, so no git a test or a script
# under test runs reads the settings of whoever runs the suite or of the
# machine: an identity, commit.gpgsign, init.defaultBranch, core.hooksPath, a
# url rewrite or an alias there would change what a test does, and CI has
# none of them. A scratch HOME is not enough: it hides ~/.gitconfig, but not
# /etc/gitconfig, nor the config under an XDG_CONFIG_HOME still naming the
# real one. Set whatever the caller has them set to, and exported so the
# scripts under test get them too. A test that needs a global config points
# GIT_CONFIG_GLOBAL at a file of its own; a repository's own config is still
# read, which is where a test puts the settings it needs.
#
# The other way to give git configuration through the environment is
# GIT_CONFIG_COUNT with its GIT_CONFIG_KEY_<n> and GIT_CONFIG_VALUE_<n>, and
# GIT_CONFIG_PARAMETERS. git lists the first and the last as repository
# variables, so clear_git_repository_env has cleared them by now, and the
# numbered ones are not read without the count.
isolate_git_config() {
    local _var
    for _var in "${ISOLATED_GIT_CONFIG_VARS[@]}"; do
        export "${_var}=/dev/null"
    done
}

# Both run while the helper loads, which is before any test or setup can run
# git. A suite that could not be cut off from its caller's repository must
# not run, hence the exit: bats reports it as a failure of the whole file.
clear_git_repository_env || exit 1
isolate_git_config

# Creates fake executables on a PATH prefix, so a script under test invokes
# the fakes instead of real system tools. Each fake logs its own name plus
# arguments to $FAKE_BIN_LOG, echoes back any canned output seeded via
# seed_fake_output, and exits 0 unless FAKE_EXIT_<tool> overrides it.
#
# Usage: setup_fake_bin <tool-name> [<tool-name> ...]
setup_fake_bin() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    FAKE_BIN_OUTPUT_DIR="${BATS_TEST_TMPDIR}/fakebin-output"
    mkdir -p "${FAKE_BIN_DIR}" "${FAKE_BIN_OUTPUT_DIR}"
    : > "${FAKE_BIN_LOG}"

    local _tool _varname
    for _tool in "$@"; do
        # Tool names may contain hyphens (e.g. update-dotnet-sdk), which are
        # not valid in a bash variable name - sanitised to underscores for
        # the FAKE_EXIT_<tool> override lookup below.
        _varname="FAKE_EXIT_${_tool//-/_}"
        cat > "${FAKE_BIN_DIR}/${_tool}" <<EOF
#!/bin/sh
printf '%s %s\n' "${_tool}" "\$*" >> "${FAKE_BIN_LOG}"
if [ -f "${FAKE_BIN_OUTPUT_DIR}/${_tool}" ]; then
    cat "${FAKE_BIN_OUTPUT_DIR}/${_tool}"
fi
exit "\${${_varname}:-0}"
EOF
        chmod +x "${FAKE_BIN_DIR}/${_tool}"
    done

    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

# Creates the fakes setup_fake_bin would, plus a fake sudo that never runs
# the command it wraps: it logs "sudo <command line>" to $FAKE_BIN_LOG, then
# exits 1 when that command line matches the grep -E pattern in
# $FAKE_SUDO_FAIL (read when sudo runs, so a test sets it before the run) and
# 0 otherwise. Lets an install.d/ script be run end to end, with exactly one
# privileged step failing, without real root or any change to the host.
#
# Usage: setup_fake_sudo [<tool-name> ...]
setup_fake_sudo() {
    setup_fake_bin "$@"
    cat > "${FAKE_BIN_DIR}/sudo" <<EOF
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ -n "\${FAKE_SUDO_FAIL:-}" ] && printf '%s\n' "\$*" | grep -qE "\${FAKE_SUDO_FAIL}"; then
    exit 1
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/sudo"
}

# Replaces a fake created by setup_fake_bin with a script read from stdin,
# for a tool whose fake has to do more than log and echo canned output.
# Usage: replace_fake <tool-name> <<'EOF' ... EOF
replace_fake() {
    cat > "${FAKE_BIN_DIR}/$1"
    chmod +x "${FAKE_BIN_DIR}/$1"
}

# Seeds canned stdout for a fake tool created by setup_fake_bin.
# Usage: seed_fake_output <tool-name> <<< "canned output"
seed_fake_output() {
    cat > "${FAKE_BIN_OUTPUT_DIR}/$1"
}

# Asserts the fake invocation log contains a line matching the given
# grep -E pattern.
assert_fake_called() {
    grep -qE "$1" "${FAKE_BIN_LOG}"
}

# Asserts the fake invocation log does NOT contain a line matching the
# given grep -E pattern.
refute_fake_called() {
    ! grep -qE "$1" "${FAKE_BIN_LOG}"
}

# Asserts each dev-update unit in the user unit directory is a symlink that
# resolves to the same unit under the given directory.
# Usage: assert_dev_update_units_linked_to <units-dir>
assert_dev_update_units_linked_to() {
    local _unit _link
    for _unit in dev-update.service dev-update.timer; do
        _link="${HOME}/.config/systemd/user/${_unit}"
        [ -L "${_link}" ] || return 1
        [ "$(readlink -f "${_link}")" = "$(readlink -f "$1/${_unit}")" ] || return 1
    done
}

# Runs a command with the caller's tool settings cleared and a minimal PATH,
# so the nvm, Go, bun or dotnet setup of whoever runs the suite cannot leak
# into what the code under test produces. LINUX_DISTRIBUTION is cleared too:
# a shell that has loaded 00_shell-options.sh exports it, and 85_pacman.sh
# does nothing without it. The XDG base directories are set to where
# 20_xdg-dirs.sh puts them, under HOME, rather than left as the caller has
# them: tools place their own directories from these (70_nvm.sh puts
# NVM_DIR under XDG_CONFIG_HOME), so the caller's values would send what the
# code under test creates to the real ~/.config of whoever runs the suite.
# HOME must therefore already be the test's own, and the command is not run
# when it is not. Leading VAR=value arguments are applied after all of this
# (env reads them), so a test can start from another PATH, or give a tool
# variable a known value, without repeating the list.
# Usage: run_with_clean_tool_env [<VAR=value> ...] <command> [<arg> ...]
run_with_clean_tool_env() {
    if [[ "${HOME}" != "${BATS_TEST_TMPDIR}"/* ]]; then
        echo "run_with_clean_tool_env: HOME (${HOME}) is not under the test's temporary directory" >&2
        return 1
    fi
    env -u NVM_DIR -u GOPATH -u BUN_INSTALL -u DOTNET_NOLOGO -u DOTNET_ROOT -u LINUX_DISTRIBUTION \
        XDG_CONFIG_HOME="${HOME}/.config" XDG_DATA_HOME="${HOME}/.local/share" \
        XDG_STATE_HOME="${HOME}/.local/state" XDG_CACHE_HOME="${HOME}/.cache" \
        PATH=/usr/bin:/bin "$@"
}

# Runs the given script in bash with the bash.bashrc.d directory as $1, in an
# interactive shell (as /etc/bash.bashrc sources the sections) or in a
# non-interactive one (as run-dev-update does). Either kind starts from
# run_with_clean_tool_env's environment, so every suite means the same thing
# by "non-interactive"; leading VAR=value arguments are passed on to it.
# --norc and --noprofile keep the host's deployed /etc/bash.bashrc.d out of
# the shell, and +m stops it taking over a terminal for job control. Stdin is
# /dev/null, so the shell has no terminal, and an interactive run's stderr
# cannot be asserted empty: an interactive bash with no terminal warns there
# that it has no job control. Any further arguments reach the script as $2
# onwards. Leaves stdout in $output and stderr in $stderr.
# Usage: run_section_shell [<VAR=value> ...] interactive|non-interactive <script> [<arg> ...]
run_section_shell() {
    local -a _env=() _flags=(--norc --noprofile +m)
    while [[ "$1" == *=* ]]; do
        _env+=("$1")
        shift
    done
    local _mode="$1" _script="$2"
    shift 2
    case "${_mode}" in
        interactive) _flags+=(-i) ;;
        non-interactive) ;;
        *)
            echo "run_section_shell: unknown mode '${_mode}'" >&2
            return 1
            ;;
    esac
    run --separate-stderr run_with_clean_tool_env "${_env[@]}" bash "${_flags[@]}" -c "${_script}" _ "${SECTIONS_DIR}" "$@" < /dev/null
}

# Writes a stand-in for nvm into the given directory: an nvm.sh that adds the
# given label to ${BATS_TEST_TMPDIR}/nvm-loads each time it is sourced, and a
# bash_completion that leaves the label in nvm_completion_loaded.
# Usage: write_fake_nvm <dir> <label>
write_fake_nvm() {
    mkdir -p "$1"
    printf 'echo %s >> "%s"\n' "$2" "${BATS_TEST_TMPDIR}/nvm-loads" > "$1/nvm.sh"
    printf 'nvm_completion_loaded=%s\n' "$2" > "$1/bash_completion"
}

# Succeeds when the stand-in nvm.sh files were sourced exactly as listed, one
# label a line, and by nothing when no label is given.
# Usage: assert_nvm_loads [<label> ...]
assert_nvm_loads() {
    local _loads="${BATS_TEST_TMPDIR}/nvm-loads"
    if [ "$#" -eq 0 ]; then
        [ ! -e "${_loads}" ]
        return
    fi
    [ "$(cat "${_loads}")" = "$(printf '%s\n' "$@")" ]
}

# Creates a stand-in for the nvm package's directory, labelled "package", and
# prints its path.
setup_fake_nvm_package() {
    local _package="${BATS_TEST_TMPDIR}/nvm-package"
    write_fake_nvm "${_package}" package
    : > "${_package}/nvm-exec"
    printf '%s\n' "${_package}"
}

# Writes a copy of a bash.bashrc.d section that reads a package from the
# given directory wherever the section names the package's system directory,
# so a test decides whether the package is there and what it holds. The
# sections themselves have no way to be pointed at another directory, and
# need none. Fails unless the copy holds every expected line and no longer
# names the system directory, so a section that changes shape cannot leave a
# test reading the real package unnoticed. Prints the copy's path.
# Usage: section_reading <section-file> <system-dir> <package-dir> [<expected-line> ...]
section_reading() {
    local _copy="${BATS_TEST_TMPDIR}/sections/$1" _system_dir="$2" _content
    local _expected
    mkdir -p "${_copy%/*}"
    _content="$(< "${SECTIONS_DIR}/$1")" || return 1
    # Both directories are quoted so each is taken as it is written: unquoted,
    # the first would be a pattern and an "&" in the second would stand for
    # what the first matched, and a test's directory can hold any character.
    printf '%s\n' "${_content//"${_system_dir}"/"$3"}" > "${_copy}"
    shift 3
    for _expected in "$@"; do
        grep -q -F "${_expected}" "${_copy}" || return 1
    done
    ! grep -q -F "${_system_dir}" "${_copy}" || return 1
    printf '%s\n' "${_copy}"
}

# Writes the copy of 70_nvm.sh that looks for the nvm package in the given
# directory: its existence test, both loads and both links.
# Usage: nvm_section_reading <package-dir>
nvm_section_reading() {
    section_reading 70_nvm.sh /usr/share/nvm "$1" \
        "[ -f $1/nvm.sh ]" ". $1/nvm.sh" ". $1/bash_completion" \
        "ln -sf $1/nvm.sh " "ln -sf $1/nvm-exec "
}

# Writes a stand-in for autojump into the given directory: an autojump.sh
# that registers the j completion and the PROMPT_COMMAND hook the real one
# does. It registers them in any shell, so only the section sourcing it
# decides which shells get them.
# Usage: write_fake_autojump <dir>
write_fake_autojump() {
    mkdir -p "$1"
    cat > "$1/autojump.sh" <<'EOF'
_autojump() { :; }
complete -F _autojump j
autojump_add_to_database() { :; }
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND} ; }autojump_add_to_database"
EOF
}

# Writes the copy of 77_autojump.sh that looks for autojump in the given
# directory: its existence test and its load.
# Usage: autojump_section_reading <autojump-dir>
autojump_section_reading() {
    section_reading 77_autojump.sh /usr/share/autojump "$1" \
        "[ -f $1/autojump.sh ]" ". $1/autojump.sh"
}

# Writes the copy of 60_dotnet.sh that looks for .NET in the given directory:
# its existence test and the DOTNET_ROOT it exports.
# Usage: dotnet_section_reading <dotnet-dir>
dotnet_section_reading() {
    section_reading 60_dotnet.sh /usr/share/dotnet "$1" \
        "[ -d \"$1\" ]" "export DOTNET_ROOT=$1"
}
