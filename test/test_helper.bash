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

# Creates the directory the fakes live in, with their log and canned-output
# directory, and puts it first on PATH. Whichever helper needs the directory
# calls this, so a test may start with any of them. Calling it again leaves
# the log holding what it holds, and puts the directory first on PATH, and
# there once, however many helpers a test uses and whatever it has put on
# PATH ahead of the directory since.
#
# FAKE_BIN_LOG and FAKE_BIN_OUTPUT_DIR are exported because every fake reads
# them from its environment when it runs, as it does FAKE_EXIT_<tool>; none
# has either path written into its text. A fake is then written the same way
# wherever it is, a path holding a character the shell acts on needs no
# escaping, and no test exports either variable itself. Nothing the suites
# run starts a fake without them: run_with_clean_tool_env and the other env
# calls remove only the variables they name, and the fake sudos either run
# nothing or run the command with the environment they were given. Should
# that ever change, every fake fails rather than logging nowhere: see
# write_fake_script.
ensure_fake_bin_dir() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    export FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    export FAKE_BIN_OUTPUT_DIR="${BATS_TEST_TMPDIR}/fakebin-output"
    mkdir -p "${FAKE_BIN_DIR}" "${FAKE_BIN_OUTPUT_DIR}"
    [ -e "${FAKE_BIN_LOG}" ] || : > "${FAKE_BIN_LOG}"
    # Every entry PATH already has for the directory is taken out before it
    # goes on the front, so a directory a test put ahead of it since the last
    # call cannot shadow a fake. This mirrors _bashrc_d_path_prepend rather
    # than sourcing it: that is code under test, and a fault in it must not
    # take every fake down with it. An empty entry means the current
    # directory, so it is kept; the trailing ':' sentinel makes a trailing
    # empty entry, and an empty PATH, come out as an entry of their own.
    local rest="${PATH}:" entry joined="${FAKE_BIN_DIR}"
    while [ -n "${rest}" ]; do
        entry="${rest%%:*}"
        rest="${rest#*:}"
        [ "${entry}" = "${FAKE_BIN_DIR}" ] || joined+=":${entry}"
    done
    export PATH="${joined}"
}

# Creates fake executables on a PATH prefix, so a script under test invokes
# the fakes instead of real system tools. Each fake logs its own name plus
# arguments to $FAKE_BIN_LOG, echoes back any canned output seeded via
# seed_fake_output, and exits 0 unless FAKE_EXIT_<tool> overrides it. Each
# fails, as write_fake_script describes, when FAKE_BIN_LOG or
# FAKE_BIN_OUTPUT_DIR is not set.
#
# Usage: setup_fake_bin <tool-name> [<tool-name> ...]
setup_fake_bin() {
    ensure_fake_bin_dir
    : > "${FAKE_BIN_LOG}"

    local _tool _varname
    for _tool in "$@"; do
        # Tool names may contain hyphens (e.g. update-dotnet-sdk), which are
        # not valid in a bash variable name - sanitised to underscores for
        # the FAKE_EXIT_<tool> override lookup below.
        _varname="FAKE_EXIT_${_tool//-/_}"
        write_fake_script "${FAKE_BIN_DIR}/${_tool}" "${_tool}" FAKE_BIN_LOG FAKE_BIN_OUTPUT_DIR <<EOF
#!/bin/sh
printf '%s %s\n' "${_tool}" "\$*" >> "\${FAKE_BIN_LOG}"
if [ -f "\${FAKE_BIN_OUTPUT_DIR}/${_tool}" ]; then
    cat "\${FAKE_BIN_OUTPUT_DIR}/${_tool}"
fi
exit "\${${_varname}:-0}"
EOF
    done
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
    write_fake_script "${FAKE_BIN_DIR}/sudo" sudo <<EOF
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
if [ -n "\${FAKE_SUDO_FAIL:-}" ] && printf '%s\n' "\$*" | grep -qE "\${FAKE_SUDO_FAIL}"; then
    exit 1
fi
exit 0
EOF
}

# Writes a fake from a script read from stdin, for a tool whose fake has to
# do more than log and echo canned output. It takes the place of the fake
# setup_fake_bin made for that tool, if there is one; no call to
# setup_fake_bin is needed first. A fake that logs appends to
# "${FAKE_BIN_LOG}" as its environment has it when it runs: written as that
# in a quoted heredoc, and with the "$" escaped in an unquoted one, where
# bash would otherwise put the path into the script, and would do so before
# this function has set it. The fake is written by write_fake_script, so it
# fails when FAKE_BIN_LOG is not set.
# Usage: replace_fake <tool-name> <<'EOF' ... EOF
replace_fake() {
    ensure_fake_bin_dir
    write_fake_script "${FAKE_BIN_DIR}/$1" "$1"
}

# The status a fake exits with when a variable it reads is not set. No
# FAKE_EXIT_<tool> a test sets uses it, and neither env (125 when it fails
# itself) nor the shell (126, 127 and 128 onwards) does.
FAKE_ENV_MISSING_STATUS=97

# Writes the script read from stdin to <path> as an executable fake, with a
# guard after its #! line for each named variable (FAKE_BIN_LOG when none is
# named). The guard stops the fake, printing "fake <name>: <variable> is not
# set" to stderr and exiting with FAKE_ENV_MISSING_STATUS, when the variable
# is unset or empty. The fakes read these from their environment, so a fake
# started without them would otherwise log nowhere and still exit as asked,
# and every refute_fake_called would pass without looking at anything. The
# guard is POSIX sh, as the fakes are. The script must start with a #! line.
# Usage: write_fake_script <path> <name> [<variable> ...] <<'EOF' ... EOF
write_fake_script() {
    local _path="$1" _name="$2" _shebang _var
    shift 2
    [ "$#" -gt 0 ] || set -- FAKE_BIN_LOG
    if ! IFS= read -r _shebang || [[ "${_shebang}" != '#!'* ]]; then
        echo "write_fake_script: the script for ${_name} does not start with a #! line" >&2
        return 1
    fi
    {
        printf '%s\n' "${_shebang}"
        for _var in "$@"; do
            cat <<EOF
[ -n "\${${_var}:-}" ] || { echo 'fake ${_name}: ${_var} is not set' >&2; exit ${FAKE_ENV_MISSING_STATUS}; }
EOF
        done
        cat
    } > "${_path}"
    chmod +x "${_path}"
}

# Seeds canned stdout for a fake tool created by setup_fake_bin.
# Usage: seed_fake_output <tool-name> <<< "canned output"
seed_fake_output() {
    cat > "${FAKE_BIN_OUTPUT_DIR}/$1"
}

# Leaves the given git repo mid-merge with the given tracked file in
# conflict: commits what is staged, changes the file one way on a second
# branch and another way on the first, then merges the second, which fails.
# Usage: make_merge_conflict <repo> <path-in-repo>
make_merge_conflict() {
    local _git=(git -C "$1" -c user.name=bats -c user.email=bats@example.invalid -c commit.gpgsign=false)
    "${_git[@]}" commit --quiet --allow-empty -m base
    "${_git[@]}" checkout --quiet -b conflicting
    printf 'theirs\n' >> "$1/$2"
    "${_git[@]}" commit --quiet -am theirs
    "${_git[@]}" checkout --quiet -
    printf 'ours\n' >> "$1/$2"
    "${_git[@]}" commit --quiet -am ours
    ! "${_git[@]}" merge --quiet conflicting > /dev/null 2>&1
    [ -n "$(git -C "$1" ls-files --unmerged)" ]
}

# Replaces git with one that logs each call to $FAKE_BIN_LOG as
# "git <arguments>", fails when its arguments, with a space added at each
# end, contain the given text, and runs the real git otherwise. With no text
# it fails nothing, so a test only gets the log. The added spaces let text
# such as " rebase " match a whole argument, which " --git-path rebase-merge "
# does not contain. A rebase --abort always runs the real
# git, so failing " rebase " fails only the rebase itself. The failure exits
# with the given code, 1 when none is given.
# Usage: fake_git [<text> [<exit-code>]]
fake_git() {
    local _real_git _fail_case=""
    _real_git="$(command -v git)"
    [ -z "${1:-}" ] || _fail_case="    *\"$1\"*) exit ${2:-1} ;;"
    replace_fake git <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
case " \$* " in
    *" rebase --abort ") ;;
${_fail_case}
esac
exec "${_real_git}" "\$@"
EOF
}

# Replaces git with the fake_git that fails when its arguments contain the
# given text, exiting with the given code (1 when none is given).
# Usage: fail_git_for <text> [<exit-code>]
fail_git_for() {
    fake_git "$1" "${2:-1}"
}

# Holds a flock on the given file from a background process for the given
# number of seconds, as another run would, and returns once it is held. The
# holder's pid is left in LOCK_HOLDER_PID for the test to wait on. Its output
# and bats's fd 3 are closed, so bats does not wait on it when a test ends.
# Usage: hold_lock_in_background <lock-file> <seconds>
hold_lock_in_background() {
    local _ready="${BATS_TEST_TMPDIR}/lock-holder-ready" _holder="${BATS_TEST_TMPDIR}/lock-holder" _tries=0
    rm -f "${_ready}"
    # Signals it holds the lock, then keeps it for the given seconds.
    cat > "${_holder}" <<'EOF'
#!/bin/sh
: > "$1"
sleep "$2"
EOF
    chmod +x "${_holder}"
    flock "$1" "${_holder}" "${_ready}" "$2" > /dev/null 2>&1 3>&- &
    export LOCK_HOLDER_PID=$!
    until [ -e "${_ready}" ]; do
        _tries=$((_tries + 1))
        [ "${_tries}" -le 100 ] || return 1
        sleep 0.1
    done
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

# Prints the line number of the first fake log line matching the given
# grep -E pattern.
# Usage: log_line_of <pattern>
log_line_of() {
    grep -n -m 1 -E "$1" "${FAKE_BIN_LOG}" | cut -d: -f1
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
# does nothing without it. So is CREDFETO_TEST_ROOT, so a section reads this
# machine's own system files unless the test names a stand-in root itself.
# The XDG base directories are set to where
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
    env -u NVM_DIR -u GOPATH -u BUN_INSTALL -u DOTNET_NOLOGO -u DOTNET_ROOT -u LINUX_DISTRIBUTION -u CREDFETO_TEST_ROOT \
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
    local _loads="${BATS_TEST_TMPDIR}/nvm-loads"
    mkdir -p "$1"
    printf 'echo %s >> %s\n' "$2" "${_loads@Q}" > "$1/nvm.sh"
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

# Creates this test's stand-in system root, empty unless a test writes into
# it, and prints its path. A section run with CREDFETO_TEST_ROOT set to it
# reads every system file it names from there instead of this machine.
stand_in_root() {
    local _root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${_root}"
    printf '%s\n' "${_root}"
}

# Creates a stand-in for the nvm package's directory, labelled "package",
# where 70_nvm.sh looks for it under the stand-in root, and prints its path.
setup_fake_nvm_package() {
    local _package
    _package="$(stand_in_root)/usr/share/nvm"
    write_fake_nvm "${_package}" package
    : > "${_package}/nvm-exec"
    printf '%s\n' "${_package}"
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
