#!/usr/bin/env bats
# Acceptance tests for settings/scripts/general/.

bats_require_minimum_version 1.5.0

load test_helper

GENERAL_DIR="${SCRIPTS_DIR}/general"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    # Where wallpaper keeps its clone of the wallpapers repo.
    WALLPAPERS_DIR="${HOME}/work/thirdparty/wallpapers"
    mkdir -p "${HOME}"
}

# ── mkrelease ────────────────────────────────────────────────────────────────

@test "mkrelease dies when no release is given" {
    run "${GENERAL_DIR}/mkrelease"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid release"* ]]
}

@test "mkrelease dies when not in a git repository" {
    cd "${BATS_TEST_TMPDIR}"
    run "${GENERAL_DIR}/mkrelease" 1.2.3
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Not in a git repository"* ]]
}

@test "mkrelease dies when CHANGELOG.md is missing" {
    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    cd "${BATS_TEST_TMPDIR}/repo"
    run "${GENERAL_DIR}/mkrelease" 1.2.3
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CHANGELOG.md not found"* ]]
}

@test "mkrelease updates the changelog, commits, and pushes" {
    # Real git sets up the fixture; only stubbed afterwards for the actual
    # script invocation, so `git init` etc. above aren't shadowed too.
    git init --quiet "${BATS_TEST_TMPDIR}/repo"
    printf '# Changelog\n' > "${BATS_TEST_TMPDIR}/repo/CHANGELOG.md"
    cd "${BATS_TEST_TMPDIR}/repo"

    setup_fake_bin dotnet git
    # Fake git needs to answer rev-parse --show-toplevel with a real path.
    seed_fake_output git <<< "${BATS_TEST_TMPDIR}/repo"

    run "${GENERAL_DIR}/mkrelease" 1.2.3
    [ "${status}" -eq 0 ]
    assert_fake_called '^dotnet changelog -c 1\.2\.3'
    assert_fake_called '^git commit .*CHANGELOG\.md -mChangelog for 1\.2\.3 -n'
    assert_fake_called '^git push --no-verify'
    [[ "${output}" == *"Released 1.2.3"* ]]
}

# ── stream ───────────────────────────────────────────────────────────────────
# The success path is an unbounded `while true; do ...; sleep 60; done` loop -
# not safe to exercise even via stubs, so only the argument-validation path
# is tested.

@test "stream dies when no streamer is given" {
    run "${GENERAL_DIR}/stream"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Streamer not specified"* ]]
}

# ── wallpaper ────────────────────────────────────────────────────────────────

# Creates the wallpapers directory and has the fake git report it as its own
# work tree's top level, so wallpaper treats it as a clone.
# Usage: make_wallpapers_clone
make_wallpapers_clone() {
    mkdir -p "${WALLPAPERS_DIR}"
    readlink -f "${WALLPAPERS_DIR}" | seed_fake_output git
}

@test "wallpaper clones the wallpapers repo when absent, exits cleanly if still absent after" {
    setup_fake_bin git
    run "${GENERAL_DIR}/wallpaper"
    [ "${status}" -eq 0 ]
    assert_fake_called "clone https://gitlab.com/credfeto/wallpapers.git"
    [[ "${output}" == *"Could not find"*"wallpapers"* ]]
}

@test "wallpaper picks a random jpg, copies it to Pictures/Backgrounds" {
    setup_fake_bin git
    # Real desktops already have ~/Pictures via xdg-user-dirs; the script
    # only mkdir's the Backgrounds subfolder (not -p), so this precondition
    # is part of the fixture, not something the script itself guarantees.
    mkdir -p "${HOME}/Pictures"
    make_wallpapers_clone
    printf 'fake-jpg-1' > "${WALLPAPERS_DIR}/one.jpg"
    printf 'fake-jpg-2' > "${WALLPAPERS_DIR}/two.jpg"

    run "${GENERAL_DIR}/wallpaper"
    [ "${status}" -eq 0 ]
    assert_fake_called '^git -C .*wallpapers pull'
    [[ "${output}" == *"Selected wallpaper:"* ]]
    # dt.jpg itself is not asserted here: the script deliberately uses
    # `cp --reflink` (a real btrfs CoW copy on the target desktop, not
    # something to weaken), which errors with "Operation not supported" on
    # a non-CoW test filesystem (e.g. tmpfs under BATS_TEST_TMPDIR) even
    # though it works as intended on the real machine. The script has no
    # `set -e`, so execution continues past that failure regardless.
    [ -L "${HOME}/Pictures/Backgrounds/dt-link.jpg" ]
}

@test "wallpaper dies naming a wallpapers directory that is not a git clone, and never pulls" {
    setup_fake_bin git
    mkdir -p "${WALLPAPERS_DIR}"
    # The fake git prints nothing for rev-parse, as for a directory that is
    # in no repo of its own.
    run "${GENERAL_DIR}/wallpaper"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${WALLPAPERS_DIR} exists but is not a git clone"* ]]
    assert_fake_called '^git -C .*wallpapers rev-parse --show-toplevel$'
    refute_fake_called 'pull'
}

@test "wallpaper does not attempt to copy into an empty Zoom virtual-background directory" {
    setup_fake_bin git
    mkdir -p "${HOME}/Pictures"
    make_wallpapers_clone
    printf 'fake-jpg-1' > "${WALLPAPERS_DIR}/one.jpg"
    # Present, but with no "{...}"-named subfolder yet - e.g. Zoom's virtual
    # background picker was opened but no custom background added.
    mkdir -p "${HOME}/.var/app/us.zoom.Zoom/.zoom/data/VirtualBkgnd_Custom"

    run "${GENERAL_DIR}/wallpaper"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"cp: missing"* ]]
    [[ "${output}" != *"omitting"* ]]
}

# ── install-dotnet-tools ───────────────────────────────────────────────────

@test "install-dotnet-tools creates a tool manifest when absent, then installs every tool" {
    setup_fake_bin dotnet
    run "${GENERAL_DIR}/install-dotnet-tools"
    [ "${status}" -eq 1 ]
    # No tool manifest exists and the fake `dotnet new tool-manifest` is a
    # no-op that doesn't create dotnet-tools.json, so the script's own
    # `[ -f "$HOME/dotnet-tools.json" ] || die "No tool manifest"` guard
    # fires - this is the genuine behaviour with any non-functional stub,
    # so it's asserted directly rather than papered over.
    assert_fake_called '^dotnet new tool-manifest'
    [[ "${output}" == *"No tool manifest"* ]]
}

@test "install-dotnet-tools installs every tool once a manifest exists" {
    setup_fake_bin dotnet
    printf '{}' > "${HOME}/dotnet-tools.json"
    run "${GENERAL_DIR}/install-dotnet-tools"
    [ "${status}" -eq 0 ]
    refute_fake_called '^dotnet new tool-manifest'
    assert_fake_called '^dotnet tool install --local sleet$'
    assert_fake_called '^dotnet tool install --local TSQLLint$'
    assert_fake_called '^dotnet tool install --local FunFair\.BuildCheck$'
    assert_fake_called '^dotnet tool install --local FunFair\.BuildVersion$'
    assert_fake_called '^dotnet tool install --local Credfeto\.Changelog\.Cmd$'
    assert_fake_called '^dotnet tool install --local Credfeto\.Package\.Push$'
    assert_fake_called '^dotnet tool install --local Credfeto\.Package\.Update$'
    assert_fake_called '^dotnet tool install --local Credfeto\.DotNet\.Code\.Analysis\.Overrides\.Cmd$'
    assert_fake_called '^dotnet tool install --local Credfeto\.DotNet\.Repo\.Tools\.Cmd$'
    assert_fake_called '^dotnet tool install --local Credfeto\.DotNet\.Repo\.Formatter$'
    assert_fake_called '^dotnet tool install --local Credfeto\.Build\.Dotnet\.Server$'
    assert_fake_called '^dotnet tool install --local FunFair\.Content\.Packager\.Cmd$'
    assert_fake_called '^dotnet tool install --local FunFair\.Content\.PackageSigner\.Cmd$'
    assert_fake_called '^dotnet tool install --local powershell$'
    assert_fake_called '^dotnet tool install --local dotnet-script$'
    assert_fake_called '^dotnet tool install --local dotnet-reportgenerator-globaltool$'
    assert_fake_called '^dotnet tool install --local ilspycmd$'
    [ "$(grep -c '^dotnet tool install --local ' "${FAKE_BIN_LOG}")" -eq 17 ]
    [[ "${output}" == *"Done"* ]]
}

# ── update-dotnet-tools ──────────────────────────────────────────────────────

@test "update-dotnet-tools reinstalls global tools locally and updates every local tool" {
    replace_fake dotnet <<'EOF'
#!/bin/sh
printf 'dotnet %s\n' "$*" >> "${FAKE_BIN_LOG}"
case "$1 $2" in
    "tool list")
        if [ "$3" = "--local" ]; then
            printf 'Package Id      Version\n-----------------------\nlocaltool       1.0.0\n'
        elif [ "$3" = "--global" ]; then
            printf 'Package Id      Version\n-----------------------\nglobaltool      1.0.0\n'
        fi
        ;;
esac
exit 0
EOF

    run "${GENERAL_DIR}/update-dotnet-tools"
    [ "${status}" -eq 0 ]
    assert_fake_called '^dotnet tool uninstall --global globaltool$'
    assert_fake_called '^dotnet tool install --local globaltool$'
    assert_fake_called '^dotnet tool update --local localtool$'
}

# ── install-latest-dotnet ────────────────────────────────────────────────────
# Static assertions over the script's constructs, plus end-to-end runs with
# DOTNET_INSTALL_ROOT and DOTNET_WORK_ROOT pointed at folders of the test's
# own, against the fakes setup_dotnet_install_fakes makes. Should the script
# stop honouring an override, the run fails rather than touching the host:
# - DOTNET_INSTALL_ROOT: every change to the install root runs under sudo,
#   and the fake sudo refuses any argument naming the real /usr/share/dotnet*.
#   The run lock lives there too, so the same override moves it and the same
#   refusal stops it being created at the real /usr/share/dotnet-install.lock;
# - DOTNET_WORK_ROOT: every work folder and file comes from mktemp, and the
#   fake mktemp refuses any template outside the test's work root. The work
#   folder variable is then left empty, so the clean-up removes nothing.

INSTALL_LATEST_DOTNET="${GENERAL_DIR}/install-latest-dotnet"

# The time the fake date reports, and so the name of the new install folder.
DOTNET_TEST_STAMP="20261027T120000Z"
DOTNET_TEST_NEW_INSTALL="dotnet-${DOTNET_TEST_STAMP}"

# The install folder seed_previous_dotnet_install points the live link at.
DOTNET_TEST_PREVIOUS_INSTALL="dotnet-20260101T000000Z"

# Lays out the copy of install-latest-dotnet and its tool-script fakes that
# setup_dotnet_install_fakes describes. A copy rather than a link, as the
# script finds its folder by resolving links to itself.
setup_install_latest_dotnet_copy() {
    local tree="${BATS_TEST_TMPDIR}/repo"
    local tool varname
    DOTNET_TEST_SCRIPT_DIR="${tree}/settings/scripts/general"
    mkdir -p "${DOTNET_TEST_SCRIPT_DIR}" "${tree}/lib" "${tree}/install.d"
    cp "${INSTALL_LATEST_DOTNET}" "${DOTNET_TEST_SCRIPT_DIR}/install-latest-dotnet"
    ln -sfn "${REPO_DIR}/lib/common" "${tree}/lib/common"

    # The .NET environment step writes under /etc, so the copy gets a fake
    # that logs the SDK it was given, then exits with
    # FAKE_EXIT_dotnet_environment, or 0. Its own suite is
    # dotnet-environment.bats.
    write_fake_script "${tree}/install.d/dotnet-environment" dotnet-environment <<'EOF'
#!/bin/sh
printf 'dotnet-environment DOTNET_ENV_SDK_DIR=%s\n' "${DOTNET_ENV_SDK_DIR-unset}" >> "${FAKE_BIN_LOG}"
exit "${FAKE_EXIT_dotnet_environment:-0}"
EOF

    for tool in install-dotnet-tools update-dotnet-tools; do
        varname="FAKE_EXIT_${tool//-/_}"
        write_fake_script "${DOTNET_TEST_SCRIPT_DIR}/${tool}" "${tool}" <<EOF
#!/bin/sh
printf '%s PWD=%s PATH_FIRST=%s dotnet=%s\n' "${tool}" "\${PWD}" "\${PATH%%:*}" "\$(command -v dotnet)" >> "\${FAKE_BIN_LOG}"
exit "\${${varname}:-0}"
EOF
    done
}

# Makes the fakes an end-to-end run needs, and the install and work roots it
# runs against (DOTNET_TEST_WORK_ROOT is exported for the fake mktemp):
# - sudo runs what it is given as the test user, after logging it, unless the
#   command line matches the grep -E pattern in $FAKE_SUDO_FAIL; when it
#   matches the pattern in $FAKE_SUDO_SIGNAL it runs the command, then sends
#   the script SIGTERM, as a Ctrl-C landing just as that command ends would;
# - mktemp runs the real mktemp, unless its template is outside
#   $DOTNET_TEST_WORK_ROOT, when it fails without creating anything;
# - df reports $FAKE_DF_AVAILABLE_KB (default 100 GiB) free on one filesystem;
# - stat runs the real stat, except that stat -c %d on the work root prints
#   $FAKE_STAT_WORK_ROOT_DEVICE when it is set, as if the work root were on
#   another filesystem from the install root;
# - findmnt runs the real findmnt, except that when $FAKE_FINDMNT_UUID is set,
#   even to nothing, it prints that as the UUID of every path, so a test can
#   give both roots one filesystem UUID or none, and when $FAKE_FINDMNT_FAIL
#   is set it prints a UUID but fails, so the UUID must not be used;
# - date prints DOTNET_TEST_STAMP;
# - curl serves a releases index with a 10.0 and an 11.0 SDK, and "downloads"
#   an SDK by writing its URL to the -o file, or fails when
#   $FAKE_CURL_FAIL_DOWNLOAD is set;
# - tar turns that file into a minimal SDK: a versioned sdk folder and a
#   dotnet that logs each call with the DOTNET_ROOT it saw, and for
#   --list-sdks lists the sdk folders beside it, or nothing when
#   $FAKE_DOTNET_LIST_NOTHING is set;
# - install-dotnet-tools and update-dotnet-tools are fakes beside a copy of
#   the script in DOTNET_TEST_SCRIPT_DIR, which run_install_latest_dotnet
#   runs; see the comment in install-latest-dotnet on the tool scripts for
#   why they are found there rather than on PATH.
#   Each logs its name with the folder it started in, the first PATH entry
#   and the dotnet that PATH finds, then exits with FAKE_EXIT_<tool> (with
#   underscores for hyphens), or 0.
setup_dotnet_install_fakes() {
    DOTNET_TEST_INSTALL_ROOT="${BATS_TEST_TMPDIR}/share"
    export DOTNET_TEST_WORK_ROOT="${BATS_TEST_TMPDIR}/vartmp"
    DOTNET_TEST_LOCK_FILE="${DOTNET_TEST_INSTALL_ROOT}/dotnet-install.lock"
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}" "${DOTNET_TEST_WORK_ROOT}"
    setup_fake_bin
    setup_install_latest_dotnet_copy

    replace_fake sudo <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "${FAKE_BIN_LOG}"
for arg in "$@"; do
    case "${arg}" in
        /usr/share/dotnet*)
            echo "fake sudo: refusing to touch the real ${arg}" >&2
            exit 1
            ;;
    esac
done
if [ -n "${FAKE_SUDO_FAIL:-}" ] && printf '%s\n' "$*" | grep -qE "${FAKE_SUDO_FAIL}"; then
    exit 1
fi
if [ -n "${FAKE_SUDO_SIGNAL:-}" ] && printf '%s\n' "$*" | grep -qE "${FAKE_SUDO_SIGNAL}"; then
    "$@"
    status=$?
    kill -TERM "${PPID}"
    exit "${status}"
fi
exec "$@"
EOF

    # Looked up with the fakes taken off PATH, so the fake cannot find
    # itself when a test sets the fakes up a second time.
    local real_mktemp
    real_mktemp="$(PATH="${PATH#"${FAKE_BIN_DIR}:"}" type -P mktemp)"
    write_fake_script "${FAKE_BIN_DIR}/mktemp" mktemp DOTNET_TEST_WORK_ROOT <<EOF
#!/bin/sh
for template in "\$@"; do :; done
case "\${template}" in
    "\${DOTNET_TEST_WORK_ROOT}"/*) ;;
    *)
        echo "fake mktemp: refusing \${template}, outside the test's work root" >&2
        exit 1
        ;;
esac
exec "${real_mktemp}" "\$@"
EOF

    replace_fake df <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fakefs 999999999 1 %s 1%% /\n' "${FAKE_DF_AVAILABLE_KB:-104857600}"
EOF

    local real_stat
    real_stat="$(PATH="${PATH#"${FAKE_BIN_DIR}:"}" type -P stat)"
    write_fake_script "${FAKE_BIN_DIR}/stat" stat DOTNET_TEST_WORK_ROOT <<EOF
#!/bin/sh
if [ -n "\${FAKE_STAT_WORK_ROOT_DEVICE:-}" ] && [ "\$*" = "-c %d \${DOTNET_TEST_WORK_ROOT}" ]; then
    echo "\${FAKE_STAT_WORK_ROOT_DEVICE}"
    exit 0
fi
exec "${real_stat}" "\$@"
EOF

    local real_findmnt
    real_findmnt="$(PATH="${PATH#"${FAKE_BIN_DIR}:"}" type -P findmnt)"
    write_fake_script "${FAKE_BIN_DIR}/findmnt" findmnt DOTNET_TEST_WORK_ROOT <<EOF
#!/bin/sh
if [ -n "\${FAKE_FINDMNT_FAIL:-}" ]; then
    echo 11111111-2222-3333-4444-555555555555
    exit 1
fi
if [ "\${FAKE_FINDMNT_UUID+set}" = set ]; then
    echo "\${FAKE_FINDMNT_UUID}"
    exit 0
fi
exec "${real_findmnt}" "\$@"
EOF

    replace_fake date <<EOF
#!/bin/sh
echo ${DOTNET_TEST_STAMP}
EOF

    replace_fake curl <<'EOF'
#!/bin/sh
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        --max-time | --retry | --retry-delay | --retry-max-time | --user-agent) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
printf 'curl %s\n' "${url}" >> "${FAKE_BIN_LOG}"
case "${url}" in
    *releases-index.json)
        echo '{"releases-index":[{"channel-version":"10.0","latest-sdk":"10.0.100-bats"},{"channel-version":"11.0","latest-sdk":"11.0.100-bats"}]}'
        ;;
    *)
        [ -z "${FAKE_CURL_FAIL_DOWNLOAD:-}" ] || exit 22
        echo "${url}" > "${out}"
        ;;
esac
EOF

    replace_fake tar <<'EOF'
#!/bin/sh
archive=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -xzf) archive="$2"; shift ;;
        -C) out="$2"; shift ;;
    esac
    shift
done
version="$(sed -n 's|.*/dotnet-sdk-\(.*\)-linux-x64\.tar\.gz$|\1|p' "${archive}")"
mkdir -p "${out}/sdk/${version}"
echo sdk > "${out}/sdk/${version}/file"
cat > "${out}/dotnet" <<'DOTNET'
#!/bin/sh
printf 'dotnet %s DOTNET_ROOT=%s\n' "$*" "${DOTNET_ROOT-unset}" >> "${FAKE_BIN_LOG}"
if [ "$1" = "--list-sdks" ] && [ -z "${FAKE_DOTNET_LIST_NOTHING:-}" ]; then
    root="$(dirname "$0")"
    for sdk in "${root}"/sdk/*; do
        printf '%s [%s/sdk]\n' "$(basename "${sdk}")" "${root}"
    done
fi
exit 0
DOTNET
chmod 755 "${out}/dotnet"
EOF
}

# Runs the copy of install-latest-dotnet setup_dotnet_install_fakes made
# against the test's install and work folders, with DOTNET_ROOT set as a login
# shell would set it. Leading VAR=value arguments are passed on to env.
# Usage: run_install_latest_dotnet [<VAR=value> ...]
run_install_latest_dotnet() {
    run env DOTNET_INSTALL_ROOT="${DOTNET_TEST_INSTALL_ROOT}" DOTNET_WORK_ROOT="${DOTNET_TEST_WORK_ROOT}" \
        DOTNET_ROOT="${DOTNET_TEST_INSTALL_ROOT}/dotnet" "$@" "${DOTNET_TEST_SCRIPT_DIR}/install-latest-dotnet"
}

# Seeds the previous install folder holding a marker file, and points the live
# link at it, as a previous run would have left them.
seed_previous_dotnet_install() {
    setup_dotnet_install_fakes
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_PREVIOUS_INSTALL}"
    echo previous > "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_PREVIOUS_INSTALL}/marker"
    ln -sfn "${DOTNET_TEST_PREVIOUS_INSTALL}" "${DOTNET_TEST_INSTALL_ROOT}/dotnet"
}

# Succeeds when the live link still points at the install
# seed_previous_dotnet_install made.
assert_previous_dotnet_install_live() {
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_PREVIOUS_INSTALL}" ]
}

# The names under the install root, one a line, sorted.
dotnet_install_root_listing() {
    find "${DOTNET_TEST_INSTALL_ROOT}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

# Succeeds when the work root holds no work folder.
work_root_has_no_work_dir() {
    [ -z "$(find "${DOTNET_TEST_WORK_ROOT}" -mindepth 1 -maxdepth 1 -name 'dotnet-install.*')" ]
}

# Succeeds when a failed run left the install seed_previous_dotnet_install made
# live and untouched, with nothing of its own new install or work folder left.
assert_failed_run_left_previous_install() {
    assert_previous_dotnet_install_live
    [ -f "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_PREVIOUS_INSTALL}/marker" ]
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_NEW_INSTALL}" ]
    work_root_has_no_work_dir
}

# Line number of the first line matching the given grep -E pattern, so a test
# can assert ordering rather than mere presence.
first_line_matching() {
    grep -nE -e "$1" "${INSTALL_LATEST_DOTNET}" | head -1 | cut -d: -f1
}

@test "install-latest-dotnet sets a umask that leaves the install world-readable" {
    # Why 022 is needed: see the comment above the umask in
    # install-latest-dotnet.
    grep -qE '^umask 022$' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet sets the umask before it touches the filesystem" {
    # Presence alone is not enough: a umask set after the install directory is
    # created no longer governs anything that matters. Everything that
    # extracts or copies happens after sudo mkdir; the run lock made before it
    # has its mode set explicitly.
    umask_line="$(first_line_matching '^umask ')"
    mkdir_line="$(first_line_matching '^sudo mkdir ')"

    [ -n "${umask_line}" ]
    [ -n "${mkdir_line}" ]
    [ "${umask_line}" -lt "${mkdir_line}" ]
}

@test "install-latest-dotnet makes the installed tree readable and traversable by everyone" {
    # Covers what the umask cannot: see the comment above this chmod in
    # install-latest-dotnet.
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    grep -qE 'sudo chmod -R a\+rX "\$out_path"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet never invokes a bare dotnet from PATH" {
    # A bare dotnet is not on PATH on a first install: see the comment in
    # install-latest-dotnet on the tool scripts.
    run ! grep -qE '(^|\|\||&&|;)[[:space:]]*dotnet[[:space:]]' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet installs only the 10.0 and 11.0 SDKs" {
    [ "$(grep -c '^VERSIONS_TO_INSTALL=' "${INSTALL_LATEST_DOTNET}")" -eq 1 ]
    grep -qxF 'VERSIONS_TO_INSTALL="10.0 11.0"' "${INSTALL_LATEST_DOTNET}"
}

# Replaces find with one that lists everything the real find does but exits 1
# when listing an extraction folder, as find does when it meets a folder it
# cannot read part-way through, so only its status shows the list is partial.
fail_find_listing_extracted_files() {
    local real_find
    real_find="$(PATH="${PATH#"${FAKE_BIN_DIR}:"}" type -P find)"
    replace_fake find <<EOF
#!/bin/sh
"${real_find}" "\$@"
find_status=\$?
case "\$*" in
    */extract.*) exit 1 ;;
esac
exit "\${find_status}"
EOF
}

@test "install-latest-dotnet stops without switching when listing the extracted SDK fails" {
    seed_previous_dotnet_install
    fail_find_listing_extracted_files

    run_install_latest_dotnet
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not list the files extracted into ${DOTNET_TEST_WORK_ROOT}/dotnet-install."*"/extract."* ]]
    [[ "${output}" != *"Restoring tools"* ]]
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet stops without switching when copying the files outside the versioned folders fails" {
    seed_previous_dotnet_install
    new_install="${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_NEW_INSTALL}"

    # Only the dotnet host at the top of the extraction, which is outside
    # every versioned folder, so the versioned copy before it succeeds.
    run_install_latest_dotnet FAKE_SUDO_FAIL='^cp -R .*/extract\.[^/ ]+/dotnet '
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Could not copy the versioned SDK folders"* ]]
    [[ "${output}" == *"Could not copy ${new_install}/dotnet"* ]]
    [[ "${output}" == *"Could not copy the SDK files into ${new_install}"* ]]
    [[ "${output}" != *"Restoring tools"* ]]
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet stops, naming the target, when copying the SDK into place fails" {
    seed_previous_dotnet_install
    new_install="${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_NEW_INSTALL}"

    run_install_latest_dotnet FAKE_SUDO_FAIL='^cp -R '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not copy ${new_install}/sdk/10.0.100-bats/"* ]]
    [[ "${output}" == *"Could not copy the versioned SDK folders into ${new_install}"* ]]
    [[ "${output}" != *"Restoring tools"* ]]
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet never removes the live dotnet path" {
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    run ! grep -qE 'rm .*"\$DOTNET_INSTALL_DIR"' "${INSTALL_LATEST_DOTNET}"
    run ! grep -qE 'rm .*/usr/share/dotnet' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet stamps the install folder in the UTC format prune_old_installs matches" {
    # The fake date ignores its format, so no run catches a change to it, and
    # prune_old_installs only removes names matching
    # dotnet-(legacy-)?[0-9]{8}T[0-9]{6}Z: any other format would leave every
    # old install behind.
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'INSTALL_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet makes the switch link with ln -sfn" {
    # No run reaches ln with a switch link left behind by a run killed before
    # its rename, which -f replaces and -n stops ln following into the folder
    # it points at.
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'sudo ln -sfn "$NEW_INSTALL_NAME" "$DOTNET_SWITCH_LINK"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet works under /var/tmp, not TMPDIR or /tmp" {
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qxF 'DOTNET_WORK_ROOT="${DOTNET_WORK_ROOT:-/var/tmp}"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'mktemp -d "$DOTNET_WORK_ROOT/dotnet-install.XXXXXXXX"' "${INSTALL_LATEST_DOTNET}"
    # Comments may name them; code may not. The [^r] lets /var/tmp through.
    run ! grep -E '^[^#]*(TMPDIR|(^|[^r])/tmp)' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet takes the run lock, sets the clean-up trap and checks free space before it downloads" {
    trap_line="$(first_line_matching '^trap cleanup EXIT$')"
    lock_line="$(first_line_matching '^flock -n 9 ')"
    space_line="$(first_line_matching '^require_free_space$')"
    work_line="$(first_line_matching '^WORK_DIR="\$\(mktemp ')"
    loop_line="$(first_line_matching '^for VERSION in ')"

    [ -n "${trap_line}" ]
    [ -n "${lock_line}" ]
    [ -n "${space_line}" ]
    [ "${trap_line}" -lt "${work_line}" ]
    [ "${lock_line}" -lt "${space_line}" ]
    [ "${space_line}" -lt "${work_line}" ]
    [ "${work_line}" -lt "${loop_line}" ]
}

@test "install-latest-dotnet installs into a new folder, verifies it, then links the live path to it" {
    seed_previous_dotnet_install
    new_install="${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_NEW_INSTALL}"

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
    [ -f "${new_install}/sdk/10.0.100-bats/file" ]
    [ -f "${new_install}/sdk/11.0.100-bats/file" ]
    [ -f "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_PREVIOUS_INSTALL}/marker" ]
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    work_root_has_no_work_dir

    verify_line="$(log_line_of '^dotnet --list-sdks DOTNET_ROOT=unset$')"
    switch_line="$(log_line_of '^sudo mv -T ')"
    [ -n "${verify_line}" ]
    [ -n "${switch_line}" ]
    [ "${verify_line}" -lt "${switch_line}" ]
    # Why it runs without sudo: see the comment above LISTED_SDKS in
    # install-latest-dotnet.
    refute_fake_called '^sudo .*--list-sdks'
    refute_fake_called "^sudo rm .*${DOTNET_TEST_INSTALL_ROOT}/dotnet( |$)"
    assert_fake_called '^dotnet tool restore '
}

@test "install-latest-dotnet installs then updates the dotnet tools from HOME with the new install first on PATH" {
    seed_previous_dotnet_install
    live="${DOTNET_TEST_INSTALL_ROOT}/dotnet"
    mkdir -p "${BATS_TEST_TMPDIR}/elsewhere"
    cd "${BATS_TEST_TMPDIR}/elsewhere"

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]

    switch_line="$(log_line_of '^sudo mv -T .*/dotnet\.tmp-link ')"
    install_line="$(log_line_of "^install-dotnet-tools PWD=${HOME} PATH_FIRST=${live} dotnet=${live}/dotnet$")"
    update_line="$(log_line_of "^update-dotnet-tools PWD=${HOME} PATH_FIRST=${live} dotnet=${live}/dotnet$")"
    restore_line="$(log_line_of '^dotnet tool restore ')"
    [ -n "${switch_line}" ]
    [ -n "${install_line}" ]
    [ -n "${update_line}" ]
    [ -n "${restore_line}" ]
    [ "${switch_line}" -lt "${install_line}" ]
    [ "${install_line}" -lt "${update_line}" ]
    [ "${update_line}" -lt "${restore_line}" ]
    # install-dotnet-tools lists PowerShell with the other tools, and
    # update-dotnet-tools updates every local tool, so a tool step of its own
    # here would only install or update a tool a second time.
    refute_fake_called '^dotnet tool (install|update) '
    refute_fake_called '[Pp][Oo][Ww][Ee][Rr][Ss][Hh][Ee][Ll][Ll]'
}

@test "install-latest-dotnet stops, naming the step, when installing the dotnet tools fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_EXIT_install_dotnet_tools=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not install the dotnet tools"* ]]
    [[ "${output}" != *"Done"* ]]
    assert_fake_called '^install-dotnet-tools '
    refute_fake_called '^update-dotnet-tools '
    refute_fake_called '^dotnet tool restore '
}

@test "install-latest-dotnet stops, naming the step, when updating the dotnet tools fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_EXIT_update_dotnet_tools=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not update the dotnet tools"* ]]
    [[ "${output}" != *"Done"* ]]
    assert_fake_called '^install-dotnet-tools '
    assert_fake_called '^update-dotnet-tools '
    refute_fake_called '^dotnet tool restore '
}

@test "install-latest-dotnet installs the .NET environment for the live path once it has switched to the new install" {
    seed_previous_dotnet_install

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]

    switch_line="$(log_line_of '^sudo mv -T .*/dotnet\.tmp-link ')"
    environment_line="$(log_line_of "^dotnet-environment DOTNET_ENV_SDK_DIR=${DOTNET_TEST_INSTALL_ROOT}/dotnet$")"
    install_line="$(log_line_of '^install-dotnet-tools ')"
    [ -n "${switch_line}" ]
    [ -n "${environment_line}" ]
    [ -n "${install_line}" ]
    [ "${switch_line}" -lt "${environment_line}" ]
    [ "${environment_line}" -lt "${install_line}" ]
    [ "$(grep -c '^dotnet-environment ' "${FAKE_BIN_LOG}")" -eq 1 ]
}

@test "install-latest-dotnet leaves the .NET environment alone when the install fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_CURL_FAIL_DOWNLOAD=1
    [ "${status}" -eq 1 ]
    assert_failed_run_left_previous_install
    refute_fake_called '^dotnet-environment '
}

@test "install-latest-dotnet stops, naming the step, when installing the .NET environment fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_EXIT_dotnet_environment=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not install the .NET environment"* ]]
    [[ "${output}" != *"Done"* ]]
    assert_fake_called '^dotnet-environment '
    refute_fake_called '^install-dotnet-tools '
}

# Seeds the live path as the real folder earlier versions of the script
# installed into, holding a marker file.
seed_legacy_dotnet_install() {
    setup_dotnet_install_fakes
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/dotnet"
    echo legacy > "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker"
}

@test "install-latest-dotnet moves an install that is still a real folder aside rather than deleting it" {
    seed_legacy_dotnet_install

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
    [ "$(cat "${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-${DOTNET_TEST_STAMP}/marker")" = legacy ]
    refute_fake_called "^sudo rm .*${DOTNET_TEST_INSTALL_ROOT}/dotnet( |$)"
}

# Succeeds when the folder seed_legacy_dotnet_install made is back at the live
# path, untouched, with nothing of the failed run left beside it but the run
# lock, which is kept for the next run.
assert_legacy_dotnet_install_restored() {
    [ -d "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ ! -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ "$(cat "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker")" = legacy ]
    [ "$(dotnet_install_root_listing)" = "$(printf '%s\n' dotnet dotnet-install.lock)" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet puts a moved-aside install back when the switch link cannot be made" {
    seed_legacy_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_FAIL='^ln -sfn '
    [ "${status}" -eq 1 ]
    assert_legacy_dotnet_install_restored
}

@test "install-latest-dotnet puts a moved-aside install back when the switch rename fails" {
    seed_legacy_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_FAIL='^mv -T .*/dotnet\.tmp-link '
    [ "${status}" -eq 1 ]
    assert_legacy_dotnet_install_restored
}

# The sudo mv -T that moves the legacy folder aside, as opposed to the ones
# that rename the switch link or put the legacy folder back, which
# DOTNET_TEST_SWITCH_OR_RESTORE matches.
DOTNET_TEST_LEGACY_MOVE="^mv -T .*/dotnet .*/dotnet-legacy-${DOTNET_TEST_STAMP}$"
DOTNET_TEST_SWITCH_OR_RESTORE='^mv -T [^ ]*/(dotnet\.tmp-link|dotnet-legacy-[^ ]*) '

@test "install-latest-dotnet names the moved-aside install when it cannot put it back" {
    seed_legacy_dotnet_install
    legacy_install="${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-${DOTNET_TEST_STAMP}"

    # Fails both the switch rename and the move back.
    run_install_latest_dotnet FAKE_SUDO_FAIL="${DOTNET_TEST_SWITCH_OR_RESTORE}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not move ${legacy_install} back to ${DOTNET_TEST_INSTALL_ROOT}/dotnet"* ]]
    [ "$(cat "${legacy_install}/marker")" = legacy ]
}

@test "install-latest-dotnet puts a moved-aside install back when signalled just after moving it" {
    seed_legacy_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_SIGNAL="${DOTNET_TEST_LEGACY_MOVE}"
    [ "${status}" -eq 1 ]
    assert_fake_called "^sudo mv .*/dotnet-legacy-${DOTNET_TEST_STAMP}$"
    assert_legacy_dotnet_install_restored
}

@test "install-latest-dotnet leaves the live folder alone when it cannot move it aside" {
    seed_legacy_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_FAIL="${DOTNET_TEST_LEGACY_MOVE}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not move ${DOTNET_TEST_INSTALL_ROOT}/dotnet aside"* ]]
    [[ "${output}" != *"back to"* ]]
    refute_fake_called "^sudo ${DOTNET_TEST_SWITCH_OR_RESTORE#^}"
    assert_legacy_dotnet_install_restored
}

@test "install-latest-dotnet moves the legacy folder aside with mv -T" {
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'sudo mv -T "$DOTNET_INSTALL_DIR" "$LEGACY_INSTALL_DIR"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet leaves both folders alone when the moved-aside name is already taken" {
    seed_legacy_dotnet_install
    taken="${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-${DOTNET_TEST_STAMP}"
    mkdir -p "${taken}"
    echo other > "${taken}/marker"

    run_install_latest_dotnet
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${taken} already exists"* ]]
    [[ "${output}" != *"back to"* ]]
    refute_fake_called '^sudo mv '
    [ -d "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ ! -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ "$(cat "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker")" = legacy ]
    [ "$(cat "${taken}/marker")" = other ]
    [ ! -e "${taken}/dotnet" ]
    [ "$(dotnet_install_root_listing)" = "$(printf '%s\n' dotnet dotnet-install.lock "dotnet-legacy-${DOTNET_TEST_STAMP}")" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet leaves an install already at the new install's name alone" {
    seed_previous_dotnet_install
    taken="${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_NEW_INSTALL}"
    mkdir -p "${taken}"
    echo other > "${taken}/marker"

    run_install_latest_dotnet
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${taken} already exists"* ]]
    refute_fake_called '^sudo mkdir '
    refute_fake_called '^sudo rm '
    refute_fake_called '^curl .*/dotnet-sdk-'
    refute_fake_called '^sudo (ln|mv) '
    assert_previous_dotnet_install_live
    [ -f "${DOTNET_TEST_INSTALL_ROOT}/${DOTNET_TEST_PREVIOUS_INSTALL}/marker" ]
    [ "$(cat "${taken}/marker")" = other ]
    [ "$(dotnet_install_root_listing)" = "$(printf '%s\n' dotnet dotnet-install.lock "${DOTNET_TEST_PREVIOUS_INSTALL}" "${DOTNET_TEST_NEW_INSTALL}" | sort)" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet removes the new install folder when signalled just after making it" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_SIGNAL='^mkdir '
    [ "${status}" -eq 1 ]
    assert_fake_called "^sudo mkdir .*/${DOTNET_TEST_NEW_INSTALL}$"
    refute_fake_called '^curl .*/dotnet-sdk-'
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet removes the switch link when signalled just after making it" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_SIGNAL='^ln -sfn '
    [ "${status}" -eq 1 ]
    assert_fake_called '^sudo ln -sfn '
    refute_fake_called '^sudo mv -T '
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    [ ! -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet keeps only the new install and the one it replaced" {
    seed_previous_dotnet_install
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/dotnet-20250101T000000Z" \
        "${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-20240101T000000Z" \
        "${DOTNET_TEST_INSTALL_ROOT}/dotnet-unrelated"

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    # The run lock survives the prune as well.
    [ "$(dotnet_install_root_listing)" = "$(printf '%s\n' dotnet dotnet-install.lock "${DOTNET_TEST_PREVIOUS_INSTALL}" "${DOTNET_TEST_NEW_INSTALL}" dotnet-unrelated | sort)" ]
}

@test "install-latest-dotnet leaves the previous install live and cleans up when a download fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_CURL_FAIL_DOWNLOAD=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not download: "* ]]
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet does not switch to an install that does not list every SDK" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DOTNET_LIST_NOTHING=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"does not list the 10.0.100-bats SDK"* ]]
    assert_failed_run_left_previous_install
    refute_fake_called '^sudo mv -T '
}

@test "install-latest-dotnet stops before downloading when there is not enough free space" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=1024
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Only 1 MB free on ${DOTNET_TEST_WORK_ROOT}"* ]]
    refute_fake_called '^curl '
    refute_fake_called '^sudo mkdir '
    assert_previous_dotnet_install_live
    work_root_has_no_work_dir
}

@test "install-latest-dotnet needs room for both the download and the install when they share a filesystem" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=4194304
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Only 4096 MB free on ${DOTNET_TEST_INSTALL_ROOT}; installing the SDKs needs 5120 MB"* ]]
    refute_fake_called '^curl '
    assert_previous_dotnet_install_live
}

@test "install-latest-dotnet treats paths with no UUID on different devices as separate filesystems even when df names the same source" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=4194304 FAKE_STAT_WORK_ROOT_DEVICE=999999 FAKE_FINDMNT_UUID=
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MB free on"* ]]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
}

@test "install-latest-dotnet falls back to the device id when findmnt fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=4194304 FAKE_STAT_WORK_ROOT_DEVICE=999999 FAKE_FINDMNT_FAIL=1
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MB free on"* ]]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
}

@test "install-latest-dotnet treats paths with one UUID on different devices as one filesystem, as btrfs subvolumes are" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=4194304 FAKE_STAT_WORK_ROOT_DEVICE=999999 FAKE_FINDMNT_UUID=11111111-2222-3333-4444-555555555555
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Only 4096 MB free on ${DOTNET_TEST_INSTALL_ROOT}; installing the SDKs needs 5120 MB"* ]]
    refute_fake_called '^curl '
    assert_previous_dotnet_install_live
}

@test "the install-latest-dotnet fake mktemp creates nothing outside the test's work root" {
    setup_dotnet_install_fakes
    mkdir "${BATS_TEST_TMPDIR}/elsewhere"

    run mktemp -d "${BATS_TEST_TMPDIR}/elsewhere/dotnet-install.XXXXXXXX"

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"fake mktemp: refusing"* ]]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/elsewhere")" ]

    run mktemp -d "${DOTNET_TEST_WORK_ROOT}/dotnet-install.XXXXXXXX"

    [ "${status}" -eq 0 ]
    [ -d "${output}" ]
}

@test "install-latest-dotnet keeps one run lock for every account beside the install, opened read-only" {
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qxF 'LOCK_FILE="$DOTNET_INSTALL_ROOT/dotnet-install.lock"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qxF 'exec 9<"$LOCK_FILE" || die "Could not open $LOCK_FILE"' "${INSTALL_LATEST_DOTNET}"
    # Never opened for writing, so a lock file owned by another account
    # cannot stop a run.
    run ! grep -E '^[^#]*9>' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet creates a world-readable run lock beside the install when there is none" {
    seed_previous_dotnet_install

    run_install_latest_dotnet

    [ "${status}" -eq 0 ]
    assert_fake_called "^sudo touch ${DOTNET_TEST_LOCK_FILE}$"
    assert_fake_called "^sudo chmod 0644 ${DOTNET_TEST_LOCK_FILE}$"
    [ "$(stat -c '%a' "${DOTNET_TEST_LOCK_FILE}")" = 644 ]
}

@test "install-latest-dotnet keeps the run lock when a run fails" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_CURL_FAIL_DOWNLOAD=1

    [ "${status}" -eq 1 ]
    [ -f "${DOTNET_TEST_LOCK_FILE}" ]
}

@test "install-latest-dotnet runs when XDG_RUNTIME_DIR is not set" {
    seed_previous_dotnet_install

    run_install_latest_dotnet XDG_RUNTIME_DIR=

    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
}

@test "install-latest-dotnet runs while the run lock belongs to another account" {
    [ "$(id -u)" -ne 0 ] || skip "root can open a read-only file for writing"
    seed_previous_dotnet_install
    # Stands in for the lock a run under sudo, or from another account, made:
    # readable by this account but not writable by it.
    touch "${DOTNET_TEST_LOCK_FILE}"
    chmod 0444 "${DOTNET_TEST_LOCK_FILE}"

    run_install_latest_dotnet

    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "${DOTNET_TEST_NEW_INSTALL}" ]
    refute_fake_called "^sudo touch ${DOTNET_TEST_LOCK_FILE}$"
}

# Succeeds when a run that stopped at the run lock left the install
# seed_previous_dotnet_install made live, and never downloaded, made an install
# folder or a work folder, or switched.
assert_stopped_at_run_lock() {
    refute_fake_called '^curl '
    refute_fake_called '^sudo mkdir '
    refute_fake_called '^sudo mv -T '
    assert_failed_run_left_previous_install
}

@test "install-latest-dotnet stops without installing anything when it cannot create the run lock" {
    seed_previous_dotnet_install

    run_install_latest_dotnet FAKE_SUDO_FAIL='^touch .*/dotnet-install\.lock$'

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not create ${DOTNET_TEST_LOCK_FILE}"* ]]
    assert_stopped_at_run_lock
}

@test "install-latest-dotnet stops without installing anything when it cannot open the run lock" {
    [ "$(id -u)" -ne 0 ] || skip "root can open an unreadable file"
    seed_previous_dotnet_install
    touch "${DOTNET_TEST_LOCK_FILE}"
    chmod 0 "${DOTNET_TEST_LOCK_FILE}"
    # A chmod that reports success on the lock without changing it, so the
    # lock is still unreadable when the script opens it.
    local real_chmod
    real_chmod="$(PATH="${PATH#"${FAKE_BIN_DIR}:"}" type -P chmod)"
    write_fake_script "${FAKE_BIN_DIR}/chmod" chmod <<EOF
#!/bin/sh
printf 'chmod %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
for arg in "\$@"; do
    [ "\${arg}" = "${DOTNET_TEST_LOCK_FILE}" ] && exit 0
done
exec "${real_chmod}" "\$@"
EOF

    run_install_latest_dotnet

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not open ${DOTNET_TEST_LOCK_FILE}"* ]]
    assert_fake_called "^sudo chmod 0644 ${DOTNET_TEST_LOCK_FILE}$"
    assert_stopped_at_run_lock
}

@test "install-latest-dotnet stops without touching anything while another run holds the lock" {
    seed_previous_dotnet_install
    # A switch link a running install has just made, which this run must not
    # take for one of its own.
    ln -s "${DOTNET_TEST_PREVIOUS_INSTALL}" "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link"

    exec 8> "${DOTNET_TEST_LOCK_FILE}"
    flock -n 8
    run_install_latest_dotnet
    exec 8>&-

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Another install-latest-dotnet run holds"* ]]
    refute_fake_called '^curl '
    refute_fake_called '^sudo '
    [ -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    assert_previous_dotnet_install_live
}
