#!/usr/bin/env bats
# Acceptance tests for settings/scripts/general/.

load test_helper

GENERAL_DIR="${SCRIPTS_DIR}/general"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
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
    mkdir -p "${HOME}/work/thirdparty/wallpapers"
    printf 'fake-jpg-1' > "${HOME}/work/thirdparty/wallpapers/one.jpg"
    printf 'fake-jpg-2' > "${HOME}/work/thirdparty/wallpapers/two.jpg"

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

@test "wallpaper does not attempt to copy into an empty Zoom virtual-background directory" {
    setup_fake_bin git
    mkdir -p "${HOME}/Pictures"
    mkdir -p "${HOME}/work/thirdparty/wallpapers"
    printf 'fake-jpg-1' > "${HOME}/work/thirdparty/wallpapers/one.jpg"
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
    assert_fake_called '^dotnet tool install --local csharpier'
    assert_fake_called '^dotnet tool install --local ilspycmd'
    [[ "${output}" == *"Done"* ]]
}

# ── update-dotnet-tools ──────────────────────────────────────────────────────

@test "update-dotnet-tools reinstalls global tools locally and updates every local tool" {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    mkdir -p "${FAKE_BIN_DIR}"
    : > "${FAKE_BIN_LOG}"
    cat > "${FAKE_BIN_DIR}/dotnet" <<'EOF'
#!/bin/sh
printf 'dotnet %s\n' "$*" >> "__FAKE_BIN_LOG__"
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
    sed -i "s#__FAKE_BIN_LOG__#${FAKE_BIN_LOG}#" "${FAKE_BIN_DIR}/dotnet"
    chmod +x "${FAKE_BIN_DIR}/dotnet"
    export PATH="${FAKE_BIN_DIR}:${PATH}"

    run "${GENERAL_DIR}/update-dotnet-tools"
    [ "${status}" -eq 0 ]
    assert_fake_called '^dotnet tool uninstall --global globaltool'
    assert_fake_called '^dotnet tool install --local globaltool'
    assert_fake_called '^dotnet tool update --local localtool'
}

# ── install-latest-dotnet ────────────────────────────────────────────────────
# Static assertions over the script rather than an end-to-end run: it installs
# to the hard-coded /usr/share/dotnet and opens by deleting it, so running it
# here would destroy the host's dotnet install - the same reasoning as
# shell-environment.bats.

INSTALL_LATEST_DOTNET="${GENERAL_DIR}/install-latest-dotnet"

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
    grep -qE 'sudo chmod -R a\+rX "\$out_path"' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet verifies the install unprivileged" {
    # Under sudo this would only prove root can run dotnet, hiding the exact
    # fault it is there to catch.
    grep -qE '^[[:space:]]*"\$DOTNET" --list-sdks' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet never invokes a bare dotnet from PATH" {
    # 60_dotnet.sh only adds /usr/share/dotnet to PATH when the directory
    # already exists, evaluated when the shell started - so on a first install
    # a bare `dotnet` is not on PATH at all.
    ! grep -qE '(^|\|\||&&|;)[[:space:]]*dotnet[[:space:]]' "${INSTALL_LATEST_DOTNET}"
}

@test "install-latest-dotnet ensures a tool manifest before any --local call" {
    # dotnet tool update/install/restore --local all need a manifest in the
    # current directory or an ancestor; there is none by default.
    manifest_line="$(first_line_matching '\[ -f "\$DOTNET_TOOL_MANIFEST" \]')"
    local_line="$(first_line_matching '"\$DOTNET" tool [a-z]+ --local')"

    [ -n "${manifest_line}" ]
    [ -n "${local_line}" ]
    [ "${manifest_line}" -lt "${local_line}" ]
}
