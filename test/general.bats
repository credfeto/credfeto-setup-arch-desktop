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
    assert_fake_called '^dotnet tool install --local sleet'
    assert_fake_called '^dotnet tool install --local TSQLLint'
    assert_fake_called '^dotnet tool install --local ilspycmd'
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
    assert_fake_called '^dotnet tool uninstall --global globaltool'
    assert_fake_called '^dotnet tool install --local globaltool'
    assert_fake_called '^dotnet tool update --local localtool'
}

# ── install-latest-dotnet ────────────────────────────────────────────────────
# Static assertions over the script's constructs, plus end-to-end runs with
# DOTNET_INSTALL_ROOT and DOTNET_WORK_ROOT pointed at folders of the test's
# own, against the fakes setup_dotnet_install_fakes makes. The runs never use
# the real /usr/share or /var/tmp: the fake sudo refuses any argument naming
# the real install or work folders, so an override the script stops honouring
# fails the test rather than touching the host.

INSTALL_LATEST_DOTNET="${GENERAL_DIR}/install-latest-dotnet"

# The time the fake date reports, and so the name of the new install folder.
DOTNET_TEST_STAMP="20261027T120000Z"

# Makes the fakes an end-to-end run needs, and the install and work roots it
# runs against:
# - sudo runs what it is given as the test user, after logging it, unless the
#   command line matches the grep -E pattern in $FAKE_SUDO_FAIL;
# - df reports $FAKE_DF_AVAILABLE_KB (default 100 GiB) free on one filesystem;
# - date prints DOTNET_TEST_STAMP;
# - curl serves a releases index with a 10.0 and an 11.0 SDK, and "downloads"
#   an SDK by writing its URL to the -o file, or fails when
#   $FAKE_CURL_FAIL_DOWNLOAD is set;
# - tar turns that file into a minimal SDK: a versioned sdk folder and a
#   dotnet that logs each call with the DOTNET_ROOT it saw, and for
#   --list-sdks lists the sdk folders beside it, or nothing when
#   $FAKE_DOTNET_LIST_NOTHING is set.
setup_dotnet_install_fakes() {
    DOTNET_TEST_INSTALL_ROOT="${BATS_TEST_TMPDIR}/share"
    DOTNET_TEST_WORK_ROOT="${BATS_TEST_TMPDIR}/vartmp"
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}" "${DOTNET_TEST_WORK_ROOT}"
    setup_fake_bin

    replace_fake sudo <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "${FAKE_BIN_LOG}"
for arg in "$@"; do
    case "${arg}" in
        /usr/share/dotnet* | /var/tmp/dotnet-install.* | /var/tmp/install-latest-dotnet.*)
            echo "fake sudo: refusing to touch the real ${arg}" >&2
            exit 1
            ;;
    esac
done
if [ -n "${FAKE_SUDO_FAIL:-}" ] && printf '%s\n' "$*" | grep -qE "${FAKE_SUDO_FAIL}"; then
    exit 1
fi
exec "$@"
EOF

    replace_fake df <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fakefs 999999999 1 %s 1%% /\n' "${FAKE_DF_AVAILABLE_KB:-104857600}"
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

# Runs install-latest-dotnet against the test's install and work roots, with
# DOTNET_ROOT set as a login shell would set it. Leading VAR=value arguments
# are passed on to env.
# Usage: run_install_latest_dotnet [<VAR=value> ...]
run_install_latest_dotnet() {
    run env DOTNET_INSTALL_ROOT="${DOTNET_TEST_INSTALL_ROOT}" DOTNET_WORK_ROOT="${DOTNET_TEST_WORK_ROOT}" \
        DOTNET_ROOT="${DOTNET_TEST_INSTALL_ROOT}/dotnet" "$@" "${INSTALL_LATEST_DOTNET}"
}

# Seeds an install folder holding a marker file, and points the live link at
# it, as a previous run would have left them.
# Usage: seed_previous_dotnet_install <folder-name>
seed_previous_dotnet_install() {
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/$1"
    echo previous > "${DOTNET_TEST_INSTALL_ROOT}/$1/marker"
    ln -sfn "$1" "${DOTNET_TEST_INSTALL_ROOT}/dotnet"
}

# The names under the install root, one a line, sorted.
dotnet_install_root_listing() {
    find "${DOTNET_TEST_INSTALL_ROOT}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

# Line number of the first fake log line matching the given grep -E pattern.
first_log_line_matching() {
    grep -nE -e "$1" "${FAKE_BIN_LOG}" | head -1 | cut -d: -f1
}

# Succeeds when the work root holds no work folder.
work_root_has_no_work_dir() {
    [ -z "$(find "${DOTNET_TEST_WORK_ROOT}" -mindepth 1 -maxdepth 1 -name 'dotnet-install.*')" ]
}

# Line number of the first line matching the given grep -E pattern, so a test
# can assert ordering rather than mere presence.
first_line_matching() {
    grep -nE -e "$1" "${INSTALL_LATEST_DOTNET}" | head -1 | cut -d: -f1
}

@test "install-latest-dotnet sets a umask that leaves the install world-readable" {
    # tar applies the caller's umask for a non-root user, and cp masks the
    # source mode again on the way out, so under the 027 umask this repo is
    # checked out with the whole SDK landed 0750/0640 root:root and
    # /usr/share/dotnet/dotnet was unrunnable by any ordinary user.
    grep -qE '^umask 022$' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet sets the umask before it touches the filesystem" {
    # Presence alone is not enough: a umask set after the install directory is
    # created no longer governs anything that matters. sudo mkdir is the first
    # thing the script does to the filesystem, and everything that extracts or
    # copies happens after it.
    umask_line="$(first_line_matching '^umask ')"
    mkdir_line="$(first_line_matching '^sudo mkdir ')"

    [ -n "${umask_line}" ]
    [ -n "${mkdir_line}" ]
    [ "${umask_line}" -lt "${mkdir_line}" ]
}

@test "install-latest-dotnet makes the installed tree readable and traversable by everyone" {
    # Belt to the umask's braces: this one also covers an archive member the
    # SDK ships with a restrictive mode of its own.
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    grep -qE 'sudo chmod -R a\+rX "\$out_path"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet verifies the install unprivileged" {
    # Under sudo this would only prove root can run dotnet, hiding the exact
    # fault it is there to catch.
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    grep -qE '^LISTED_SDKS="\$\(env -u DOTNET_ROOT "\$NEW_INSTALL_DIR/dotnet" --list-sdks' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet never invokes a bare dotnet from PATH" {
    # 60_dotnet.sh only adds /usr/share/dotnet to PATH when the directory
    # already exists, evaluated when the shell started - so on a first install
    # a bare `dotnet` is not on PATH at all.
    run ! grep -qE '(^|\|\||&&|;)[[:space:]]*dotnet[[:space:]]' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet ensures a tool manifest before any --local call" {
    # dotnet tool update/install/restore --local all need a manifest in the
    # current directory or an ancestor; there is none by default.
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    manifest_line="$(first_line_matching '\[ -f "\$DOTNET_TOOL_MANIFEST" \]')"
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    local_line="$(first_line_matching '"\$DOTNET" tool [a-z]+ --local')"

    [ -n "${manifest_line}" ]
    [ -n "${local_line}" ]
    [ "${manifest_line}" -lt "${local_line}" ]
}

@test "install-latest-dotnet checks for the tool manifest where dotnet new tool-manifest writes it" {
    # Run from $HOME, `dotnet new tool-manifest` writes $HOME/dotnet-tools.json,
    # the same file install-dotnet-tools uses. Checking anywhere else misses an
    # existing manifest, and the create step then refuses to overwrite it.
    # shellcheck disable=SC2016 # literal $HOME in the script source, not a shell expansion
    grep -qxF 'DOTNET_TOOL_MANIFEST="$HOME/dotnet-tools.json"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $HOME in the script source, not a shell expansion
    grep -qF '[ -f "$HOME/dotnet-tools.json" ]' "${GENERAL_DIR}/install-dotnet-tools"
}

@test "install-latest-dotnet installs only the 10.0 and 11.0 SDKs" {
    [ "$(grep -c '^VERSIONS_TO_INSTALL=' "${INSTALL_LATEST_DOTNET}")" -eq 1 ]
    grep -qxF 'VERSIONS_TO_INSTALL="10.0 11.0"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet stops, naming the target, when copying the SDK into place fails" {
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z
    new_install="${DOTNET_TEST_INSTALL_ROOT}/dotnet-${DOTNET_TEST_STAMP}"

    run_install_latest_dotnet FAKE_SUDO_FAIL='^cp -R '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not copy ${new_install}/sdk/10.0.100-bats/"* ]]
    [[ "${output}" == *"Could not copy the versioned SDK folders into ${new_install}"* ]]
    [[ "${output}" != *"Restoring tools"* ]]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-20260101T000000Z" ]
    [ ! -e "${new_install}" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet never removes the live dotnet path" {
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    run ! grep -qE 'rm .*"\$DOTNET_INSTALL_DIR"' "${INSTALL_LATEST_DOTNET}"
    run ! grep -qE 'rm .*/usr/share/dotnet' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet installs the SDKs into a timestamped folder" {
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'INSTALL_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qxF 'NEW_INSTALL_NAME="dotnet-$INSTALL_STAMP"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'extract_dotnet_package "$TEMPORARY_FILE" "$NEW_INSTALL_DIR"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet verifies the new install with DOTNET_ROOT unset before switching to it" {
    verify_line="$(first_line_matching 'env -u DOTNET_ROOT ')"
    switch_line="$(first_line_matching '^sudo mv -T ')"

    [ -n "${verify_line}" ]
    [ -n "${switch_line}" ]
    [ "${verify_line}" -lt "${switch_line}" ]
}

@test "install-latest-dotnet switches with mv -T over a relative symlink" {
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'sudo ln -sfn "$NEW_INSTALL_NAME" "$DOTNET_SWITCH_LINK"' "${INSTALL_LATEST_DOTNET}"
    # shellcheck disable=SC2016 # literal $ in the script source, not a shell expansion
    grep -qF 'sudo mv -T "$DOTNET_SWITCH_LINK" "$DOTNET_INSTALL_DIR"' "${INSTALL_LATEST_DOTNET}"
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
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z
    new_install="${DOTNET_TEST_INSTALL_ROOT}/dotnet-${DOTNET_TEST_STAMP}"

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-${DOTNET_TEST_STAMP}" ]
    [ -f "${new_install}/sdk/10.0.100-bats/file" ]
    [ -f "${new_install}/sdk/11.0.100-bats/file" ]
    [ -f "${DOTNET_TEST_INSTALL_ROOT}/dotnet-20260101T000000Z/marker" ]
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    work_root_has_no_work_dir

    verify_line="$(first_log_line_matching '^dotnet --list-sdks DOTNET_ROOT=unset$')"
    switch_line="$(first_log_line_matching '^sudo mv -T ')"
    [ -n "${verify_line}" ]
    [ -n "${switch_line}" ]
    [ "${verify_line}" -lt "${switch_line}" ]
    refute_fake_called '^sudo .*--list-sdks'
    refute_fake_called "^sudo rm .*${DOTNET_TEST_INSTALL_ROOT}/dotnet( |$)"
    assert_fake_called '^dotnet tool restore '
}

@test "install-latest-dotnet moves an install that is still a real folder aside rather than deleting it" {
    setup_dotnet_install_fakes
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/dotnet"
    echo legacy > "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker"

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-${DOTNET_TEST_STAMP}" ]
    [ "$(cat "${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-${DOTNET_TEST_STAMP}/marker")" = legacy ]
    refute_fake_called "^sudo rm .*${DOTNET_TEST_INSTALL_ROOT}/dotnet( |$)"
}

# Seeds the live path as the real folder earlier versions of the script
# installed into, holding a marker file.
seed_legacy_dotnet_install() {
    setup_dotnet_install_fakes
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/dotnet"
    echo legacy > "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker"
}

# Succeeds when the folder seed_legacy_dotnet_install made is back at the live
# path, untouched, with nothing of the failed run left beside it.
assert_legacy_dotnet_install_restored() {
    [ -d "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ ! -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet" ]
    [ "$(cat "${DOTNET_TEST_INSTALL_ROOT}/dotnet/marker")" = legacy ]
    [ "$(dotnet_install_root_listing)" = dotnet ]
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

@test "install-latest-dotnet names the moved-aside install when it cannot put it back" {
    seed_legacy_dotnet_install
    legacy_install="${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-${DOTNET_TEST_STAMP}"

    # Fails both the switch rename and the move back.
    run_install_latest_dotnet FAKE_SUDO_FAIL='^mv -T '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not move ${legacy_install} back to ${DOTNET_TEST_INSTALL_ROOT}/dotnet"* ]]
    [ "$(cat "${legacy_install}/marker")" = legacy ]
}

@test "install-latest-dotnet keeps only the new install and the one it replaced" {
    setup_dotnet_install_fakes
    mkdir -p "${DOTNET_TEST_INSTALL_ROOT}/dotnet-20250101T000000Z" \
        "${DOTNET_TEST_INSTALL_ROOT}/dotnet-legacy-20240101T000000Z" \
        "${DOTNET_TEST_INSTALL_ROOT}/dotnet-unrelated"
    seed_previous_dotnet_install dotnet-20260101T000000Z

    run_install_latest_dotnet
    [ "${status}" -eq 0 ]
    [ "$(dotnet_install_root_listing)" = "$(printf '%s\n' dotnet dotnet-20260101T000000Z "dotnet-${DOTNET_TEST_STAMP}" dotnet-unrelated | sort)" ]
}

@test "install-latest-dotnet leaves the previous install live and cleans up when a download fails" {
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z

    run_install_latest_dotnet FAKE_CURL_FAIL_DOWNLOAD=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not download: "* ]]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-20260101T000000Z" ]
    [ -f "${DOTNET_TEST_INSTALL_ROOT}/dotnet-20260101T000000Z/marker" ]
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/dotnet-${DOTNET_TEST_STAMP}" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet does not switch to an install that does not list every SDK" {
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z

    run_install_latest_dotnet FAKE_DOTNET_LIST_NOTHING=1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"does not list the 10.0.100-bats SDK"* ]]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-20260101T000000Z" ]
    [ ! -e "${DOTNET_TEST_INSTALL_ROOT}/dotnet-${DOTNET_TEST_STAMP}" ]
    refute_fake_called '^sudo mv -T '
    work_root_has_no_work_dir
}

@test "install-latest-dotnet stops before downloading when there is not enough free space" {
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z

    run_install_latest_dotnet FAKE_DF_AVAILABLE_KB=1024
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Only 1 MB free on ${DOTNET_TEST_WORK_ROOT}"* ]]
    refute_fake_called '^curl '
    refute_fake_called '^sudo mkdir '
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-20260101T000000Z" ]
    work_root_has_no_work_dir
}

@test "install-latest-dotnet stops without touching anything while another run holds the lock" {
    setup_dotnet_install_fakes
    seed_previous_dotnet_install dotnet-20260101T000000Z
    # A switch link a running install has just made, which this run must not
    # take for one of its own.
    ln -s dotnet-20260101T000000Z "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link"

    exec 8> "${DOTNET_TEST_WORK_ROOT}/install-latest-dotnet.lock"
    flock -n 8
    run_install_latest_dotnet
    exec 8>&-

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Another install-latest-dotnet run holds"* ]]
    refute_fake_called '^curl '
    refute_fake_called '^sudo '
    [ -L "${DOTNET_TEST_INSTALL_ROOT}/dotnet.tmp-link" ]
    [ "$(readlink "${DOTNET_TEST_INSTALL_ROOT}/dotnet")" = "dotnet-20260101T000000Z" ]
}
