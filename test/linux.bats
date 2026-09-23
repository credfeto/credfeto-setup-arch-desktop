#!/usr/bin/env bats
# Acceptance tests for settings/scripts/linux/.

load test_helper

LINUX_DIR="${SCRIPTS_DIR}/linux"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    # With global/system config blanked above, git has no identity to fall
    # back on unless the host account's GECOS full name happens to be set,
    # which it is not on every machine - so the fixtures below need their
    # own, independent of what the host is configured with.
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
}

# ── dev-update ───────────────────────────────────────────────────────────────

make_pullable_repo() {
    local _path="$1"
    local _remote
    _remote="${BATS_TEST_TMPDIR}/remotes/$(basename "${_path}").git"
    mkdir -p "$(dirname "${_remote}")"
    git init --quiet --bare "${_remote}"
    git init --quiet "${_path}"
    git -C "${_path}" commit --quiet --allow-empty -m initial
    git -C "${_path}" remote add origin "${_remote}"
    git -C "${_path}" push --quiet -u origin HEAD:main
}

@test "dev-update skips every repo that is not present, still runs install-claude-hooks via \$HOME" {
    # dev-update's final step, update-dotnet-tools, would otherwise run real
    # dotnet tool restores over the network.
    setup_fake_bin dotnet

    # credfeto-orchestrator is itself one of the update_repo() targets, so it
    # has to be a genuinely pullable repo for this "everything else is
    # skipped" scenario to reach the unconditional install-claude-hooks step.
    make_pullable_repo "${HOME}/work/personal/credfeto-orchestrator"
    cat > "${HOME}/work/personal/credfeto-orchestrator/install-claude-hooks" <<'EOF'
#!/bin/sh
echo "install-claude-hooks ran"
exit 0
EOF
    chmod +x "${HOME}/work/personal/credfeto-orchestrator/install-claude-hooks"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Skipping"*"credfeto-setup-arch-desktop"*"not present"* ]]
    [[ "${output}" == *"Skipping"*"credfeto-ai-skills"*"not present"* ]]
    [[ "${output}" == *"install-claude-hooks ran"* ]]
    [[ "${output}" == *"Dev environment updated"* ]]
}

@test "dev-update pulls a present repo and dies if the pull fails" {
    # A present repo dir with no remote configured - `git pull` fails, and
    # update_repo() must die rather than continue silently.
    git init --quiet "${HOME}/work/personal/cs-template"
    git -C "${HOME}/work/personal/cs-template" commit --quiet --allow-empty -m initial

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to pull"*"cs-template"* ]]
}

@test "dev-update runs the credfeto-ai-skills installer when that repo is present" {
    # dev-update's final step, update-dotnet-tools, would otherwise run real
    # dotnet tool restores over the network.
    setup_fake_bin dotnet

    make_pullable_repo "${HOME}/work/personal/credfeto-orchestrator"
    printf '#!/bin/sh\nexit 0\n' > "${HOME}/work/personal/credfeto-orchestrator/install-claude-hooks"
    chmod +x "${HOME}/work/personal/credfeto-orchestrator/install-claude-hooks"

    make_pullable_repo "${HOME}/work/personal/credfeto-ai-skills"

    mkdir -p "${HOME}/work/personal/credfeto-ai-skills/ai/skills"
    cat > "${HOME}/work/personal/credfeto-ai-skills/ai/skills/install" <<'EOF'
#!/bin/sh
echo "ai-skills install ran"
exit 0
EOF
    chmod +x "${HOME}/work/personal/credfeto-ai-skills/ai/skills/install"

    run "${LINUX_DIR}/dev-update"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ai-skills install ran"* ]]
}

# ── install-fp ───────────────────────────────────────────────────────────────

@test "install-fp installs every candidate flatpak package" {
    setup_fake_bin flatpak
    run "${LINUX_DIR}/install-fp"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak install -y com\.brave\.Browser'
    assert_fake_called '^flatpak install -y com\.ktechpit\.whatsie'
    [[ "${output}" == *"All flatpak packages installed"* ]]
}

# ── logout ───────────────────────────────────────────────────────────────────

@test "logout updates/cleans flatpaks then runs a full pacman/AUR upgrade" {
    setup_fake_bin flatpak yay
    run "${LINUX_DIR}/logout"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak update -y'
    assert_fake_called '^flatpak uninstall --unused -y'
    assert_fake_called '^yay -Syu --noconfirm'
}

# ── login ────────────────────────────────────────────────────────────────────

setup_fake_flatpak_with_installed() {
    # $1: newline-separated list of installed app IDs `flatpak list` reports.
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    mkdir -p "${FAKE_BIN_DIR}"
    : > "${FAKE_BIN_LOG}"
    cat > "${FAKE_BIN_DIR}/flatpak" <<EOF
#!/bin/sh
printf 'flatpak %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ "\$1 \$2" = "list --app" ]; then
    printf '%s\n' "$1"
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/flatpak"
    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

@test "login only launches candidate apps that are actually installed" {
    setup_fake_flatpak_with_installed "$(printf 'com.discordapp.Discord\norg.mozilla.firefox\ncom.some.UnrelatedApp')"
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
    assert_fake_called '^flatpak run org\.mozilla\.firefox$'
    refute_fake_called '^flatpak run com\.some\.UnrelatedApp'
    refute_fake_called '^flatpak run com\.spotify\.Client'
    [[ "${output}" == *"Login complete"* ]]
}

@test "login gives Brave its Ozone/Wayland flags, no other app gets them" {
    setup_fake_flatpak_with_installed "$(printf 'com.brave.Browser\ncom.discordapp.Discord')"
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    assert_fake_called '^flatpak run com\.brave\.Browser --enable-feature=UseOzonePlatform --ozone-platform=wayland'
    assert_fake_called '^flatpak run com\.discordapp\.Discord$'
}

@test "login starts the paults_aquaescape stream only when streamlink is installed" {
    setup_fake_flatpak_with_installed ""
    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"streamlink found"* ]]
    refute_fake_called '^stream '
}

@test "login starts the stream when streamlink is present" {
    setup_fake_flatpak_with_installed ""
    cat > "${FAKE_BIN_DIR}/streamlink" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "${FAKE_BIN_DIR}/stream" <<EOF
#!/bin/sh
printf 'stream %s\n' "\$*" >> "${FAKE_BIN_LOG}"
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/streamlink" "${FAKE_BIN_DIR}/stream"

    run "${LINUX_DIR}/login"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"streamlink found, starting stream"* ]]
    assert_fake_called '^stream paults_aquaescape$'
}

# -- tmux-here ----------------------------------------------------------------

# A fake tmux that logs every call and reports has-session as failing (no
# session) unless the marker file $BATS_TEST_TMPDIR/session-exists is present.
setup_fake_tmux() {
    FAKE_BIN_DIR="${BATS_TEST_TMPDIR}/fakebin"
    FAKE_BIN_LOG="${BATS_TEST_TMPDIR}/fakebin.log"
    mkdir -p "${FAKE_BIN_DIR}"
    : > "${FAKE_BIN_LOG}"
    cat > "${FAKE_BIN_DIR}/tmux" <<EOF
#!/bin/sh
printf 'tmux %s\n' "\$*" >> "${FAKE_BIN_LOG}"
if [ "\$1" = "has-session" ] && [ ! -f "${BATS_TEST_TMPDIR}/session-exists" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/tmux"
    export PATH="${FAKE_BIN_DIR}:${PATH}"
    unset TMUX
}

@test "tmux-here creates a session in the current directory then attaches when none exists" {
    setup_fake_tmux
    mkdir -p "${BATS_TEST_TMPDIR}/my.project"
    cd "${BATS_TEST_TMPDIR}/my.project"

    run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    assert_fake_called '^tmux new-session -d -s my_project-[0-9]+ -c .*/my\.project$'
    assert_fake_called '^tmux attach-session -t =my_project-[0-9]+$'
}

@test "tmux-here only attaches when the session already exists" {
    setup_fake_tmux
    touch "${BATS_TEST_TMPDIR}/session-exists"
    mkdir -p "${BATS_TEST_TMPDIR}/proj"
    cd "${BATS_TEST_TMPDIR}/proj"

    run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    refute_fake_called 'new-session'
    assert_fake_called '^tmux attach-session -t =proj-[0-9]+$'
}

@test "tmux-here switches client instead of attaching when already inside tmux" {
    setup_fake_tmux
    touch "${BATS_TEST_TMPDIR}/session-exists"
    mkdir -p "${BATS_TEST_TMPDIR}/proj"
    cd "${BATS_TEST_TMPDIR}/proj"

    TMUX=/tmp/fake,1,0 run "${LINUX_DIR}/tmux-here"
    [ "${status}" -eq 0 ]
    refute_fake_called 'attach-session'
    assert_fake_called '^tmux switch-client -t =proj-[0-9]+$'
}

@test "tmux-here gives same-named directories in different places different sessions" {
    setup_fake_tmux
    mkdir -p "${BATS_TEST_TMPDIR}/a/proj" "${BATS_TEST_TMPDIR}/b/proj"

    cd "${BATS_TEST_TMPDIR}/a/proj"
    run "${LINUX_DIR}/tmux-here"
    cd "${BATS_TEST_TMPDIR}/b/proj"
    run "${LINUX_DIR}/tmux-here"

    [ "$(grep '^tmux attach-session' "${FAKE_BIN_LOG}" | sort -u | wc -l)" -eq 2 ]
}
