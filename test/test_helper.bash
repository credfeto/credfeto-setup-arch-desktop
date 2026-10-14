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
    # take every fake down with it.
    local rest=":${PATH}:"
    while [[ "${rest}" == *":${FAKE_BIN_DIR}:"* ]]; do
        rest="${rest%%":${FAKE_BIN_DIR}:"*}:${rest#*":${FAKE_BIN_DIR}:"}"
    done
    rest="${rest#:}"
    rest="${rest%:}"
    export PATH="${FAKE_BIN_DIR}${rest:+:${rest}}"
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

# Prints, on stderr, why section_reading cannot copy a section, naming the
# section and the line, and fails.
# Usage: section_reading_fail <section-file> <line-number> <reason>
section_reading_fail() {
    printf 'section_reading: %s line %s: %s\n' "$1" "$2" "$3" >&2
    return 1
}

# Prints one line of a section with every occurrence of the system directory
# replaced by the shell-quoted package directory, or fails, saying why, for an
# occurrence that cannot be replaced safely. Quotes are followed within the
# line only; a backslash outside single quotes escapes the next character,
# and a "#" outside quotes at the start of a word starts a comment, where
# quote characters are only text. Every occurrence is counted first, and the
# line fails unless each was replaced, so one the scan stepped over (after a
# backslash) cannot reach the copy still naming the system directory.
# Usage: section_line_reading <section-file> <line-number> <line> <system-dir> <quoted-package-dir>
section_line_reading() {
    local _line="$3" _system_dir="$4" _quoted="$5"
    local _out="" _quote="" _quote_start=-1 _comment="" _i=0
    local _char _before _after _rest="$3" _occurrences=0 _replaced=0
    while [[ "${_rest}" == *"${_system_dir}"* ]]; do
        _rest="${_rest#*"${_system_dir}"}"
        _occurrences=$((_occurrences + 1))
    done
    while [ "${_i}" -lt "${#_line}" ]; do
        _char="${_line:_i:1}"
        # Compared as a string, so a "." or "*" in the system directory is
        # taken as it is written.
        if [ "${_line:_i:${#_system_dir}}" = "${_system_dir}" ]; then
            _before=""
            if [ "${_i}" -gt 0 ]; then
                _before="${_line:_i-1:1}"
            fi
            _after="${_line:_i+${#_system_dir}:1}"
            if [[ "${_before}" == [A-Za-z0-9._/\}-] || "${_after}" == [A-Za-z0-9._-] ]]; then
                section_reading_fail "$1" "$2" "names ${_system_dir} as part of a longer name, not a whole path component" || return
            fi
            if [ -n "${_comment}" ] || [ -z "${_quote}" ]; then
                _out+="${_quoted}"
            elif [ "${_quote}" = '"' ] && [ "${_quote_start}" -eq "$((_i - 1))" ] && [ "${_after}" = '"' ]; then
                # A whole double-quoted word: the shell-quoted directory takes
                # the place of the word, quotes and all.
                _out="${_out%\"}${_quoted}"
                _quote=""
                _i=$((_i + 1))
            elif [ "${_quote}" = '"' ]; then
                section_reading_fail "$1" "$2" "names ${_system_dir} inside a double-quoted string other than as the whole word" || return
            else
                section_reading_fail "$1" "$2" "names ${_system_dir} inside a single-quoted string" || return
            fi
            _replaced=$((_replaced + 1))
            _i=$((_i + ${#_system_dir}))
            continue
        fi
        if [ -z "${_comment}" ] && [ "${_quote}" != "'" ] && [ "${_char}" = "\\" ]; then
            _out+="${_line:_i:2}"
            _i=$((_i + 2))
            continue
        fi
        if [ -n "${_comment}" ]; then
            :
        elif [ -n "${_quote}" ]; then
            if [ "${_char}" = "${_quote}" ]; then
                _quote=""
            fi
        elif [ "${_char}" = '"' ] || [ "${_char}" = "'" ]; then
            _quote="${_char}"
            _quote_start="${_i}"
        elif [ "${_char}" = '#' ] && [[ "${_i}" -eq 0 || "${_line:_i-1:1}" == [[:space:]] ]]; then
            _comment=yes
        fi
        _out+="${_char}"
        _i=$((_i + 1))
    done
    if [ "${_replaced}" -lt "${_occurrences}" ]; then
        section_reading_fail "$1" "$2" "names ${_system_dir} where it cannot be replaced, such as straight after a backslash" || return
    fi
    printf '%s\n' "${_out}"
}

# Writes a copy of a bash.bashrc.d section that reads a package from the
# given directory wherever the section names the package's system directory,
# so a test decides whether the package is there and what it holds. The
# sections themselves have no way to be pointed at another directory, and
# need none. The copy names the directory shell-quoted, so the directory may
# hold any character, including the system directory itself. Supported: the
# system directory as a whole path component (not touching a letter, digit,
# ".", "_" or "-", nor a "/" or "}" before it) that is either outside quotes,
# alone or followed by more of a path, or a whole double-quoted word, such as
# "/usr/share/dotnet"; in a comment it is replaced as plain text. Anything
# else fails, with a message on stderr naming the section, the line and the
# reason: the system directory inside a single- or double-quoted string in
# any other way, as part of a longer name, or straight after a backslash.
# Quotes are followed one line at a time, as the sections hold no string that
# spans lines. Every quote character outside a comment and not escaped opens
# or closes a string wherever it stands, including inside ${...}, $(...) and $'...', so quoting nested in
# those, and a $'...' string's own escapes, are not understood. Also fails, saying so, unless the copy holds every
# expected line, so a section that changes shape cannot leave a test reading
# the real package unnoticed. Expected lines name the directory as ${dir@Q}
# does. Each call writes its copy, under the section's own file name, into a
# directory of its own, so a second copy of the same section in one test
# cannot overwrite the first. Prints the copy's path.
# Usage: section_reading <section-file> <system-dir> <package-dir> [<expected-line> ...]
section_reading() {
    local _section="$1" _system_dir="$2" _quoted="${3@Q}"
    local _copy _line _number=0 _content="" _expected
    mkdir -p "${BATS_TEST_TMPDIR}/sections" || return 1
    _copy="$(mktemp -d "${BATS_TEST_TMPDIR}/sections/XXXXXX")/${_section}" || return 1
    while IFS= read -r _line || [ -n "${_line}" ]; do
        _number=$((_number + 1))
        if [[ "${_line}" == *"${_system_dir}"* ]]; then
            _line="$(section_line_reading "${_section}" "${_number}" "${_line}" "${_system_dir}" "${_quoted}")" || return 1
        fi
        _content+="${_line}"$'\n'
    done < "${SECTIONS_DIR}/${_section}" || return 1
    printf '%s' "${_content}" > "${_copy}"
    shift 3
    for _expected in "$@"; do
        grep -q -F "${_expected}" "${_copy}" ||
            section_reading_fail "${_section}" "(any)" "the copy holds no line with: ${_expected}" || return
    done
    printf '%s\n' "${_copy}"
}

# Writes the copy of 70_nvm.sh that looks for the nvm package in the given
# directory: its existence test, both loads and both links.
# Usage: nvm_section_reading <package-dir>
nvm_section_reading() {
    section_reading 70_nvm.sh /usr/share/nvm "$1" \
        "[ -f ${1@Q}/nvm.sh ]" ". ${1@Q}/nvm.sh" ". ${1@Q}/bash_completion" \
        "ln -sf ${1@Q}/nvm.sh " "ln -sf ${1@Q}/nvm-exec "
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
        "[ -f ${1@Q}/autojump.sh ]" ". ${1@Q}/autojump.sh"
}

# Writes the copy of 60_dotnet.sh that looks for .NET in the given directory:
# its existence test and the DOTNET_ROOT it exports.
# Usage: dotnet_section_reading <dotnet-dir>
dotnet_section_reading() {
    section_reading 60_dotnet.sh /usr/share/dotnet "$1" \
        "[ -d ${1@Q} ]" "export DOTNET_ROOT=${1@Q}"
}
