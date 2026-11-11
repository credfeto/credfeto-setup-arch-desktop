#!/usr/bin/env bats
# Covers install.d/dotnet-environment, lib/dotnet-environment and
# settings/scripts/general/uninstall-dotnet: the files that give every kind of
# session the .NET environment listed in settings/dotnet-env/dotnet.conf.
# Every run points /etc, /usr/local/bin and the SDK at folders under the
# test's own temporary folder, which are writable, so nothing goes through
# sudo and the files written can be read back.

load test_helper

INSTALL_SCRIPT="${REPO_DIR}/install.d/dotnet-environment"
UNINSTALL_SCRIPT="${SCRIPTS_DIR}/general/uninstall-dotnet"
CONF_FILE="${REPO_DIR}/settings/dotnet-env/dotnet.conf"
BLOCK_BEGIN="# BEGIN credfeto-setup-arch-desktop dotnet"
BLOCK_END="# END credfeto-setup-arch-desktop dotnet"

setup() {
    unset CLAUDECODE
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"

    export DOTNET_ENV_ETC_DIR="${BATS_TEST_TMPDIR}/etc"
    export DOTNET_ENV_BIN_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${DOTNET_ENV_ETC_DIR}"

    # As install-latest-dotnet lays it out: a live link to a versioned folder.
    export DOTNET_INSTALL_ROOT="${BATS_TEST_TMPDIR}/share"
    SDK_DIR="${DOTNET_INSTALL_ROOT}/dotnet"
    SDK_FOLDER="${DOTNET_INSTALL_ROOT}/dotnet-20260101T000000Z"
    mkdir -p "${SDK_FOLDER}"
    printf '#!/bin/sh\nexit 0\n' > "${SDK_FOLDER}/dotnet"
    chmod +x "${SDK_FOLDER}/dotnet"
    ln -s "${SDK_FOLDER}" "${SDK_DIR}"
    export DOTNET_ENV_SDK_DIR="${SDK_DIR}"

    ENVIRONMENT_D_FILE="${DOTNET_ENV_ETC_DIR}/environment.d/60-dotnet.conf"
    PROFILE_D_FILE="${DOTNET_ENV_ETC_DIR}/profile.d/60_dotnet.sh"
    BASHRC_D_FILE="${DOTNET_ENV_ETC_DIR}/bash.bashrc.d/60_dotnet.sh"
    PAM_CONF="${DOTNET_ENV_ETC_DIR}/security/pam_env.conf"
    LINK="${DOTNET_ENV_BIN_DIR}/dotnet"

    # Nothing here should need root; the fake sudo shows if anything asks.
    setup_fake_sudo
}

# The NAME=value lines of the list, DOTNET_ROOT taken out, as the files are
# checked against them.
conf_lines_without_root() {
    grep -v -e '^#' -e '^$' -e '^DOTNET_ROOT=' "${CONF_FILE}"
}

# Prints how many lines of the file are exactly the given text.
count_lines() {
    grep -cxF -- "$2" "$1" || true
}

# Copies the scripts the install runs into a tree of its own, so a test can
# change the list without changing the repository's.
copy_tree() {
    TREE="${BATS_TEST_TMPDIR}/tree"
    mkdir -p "${TREE}/install.d" "${TREE}/settings"
    cp -R "${REPO_DIR}/lib" "${TREE}/lib"
    cp "${INSTALL_SCRIPT}" "${TREE}/install.d/dotnet-environment"
    cp -R "${REPO_DIR}/settings/dotnet-env" "${TREE}/settings/dotnet-env"
}

@test "the list sets DOTNET_ROOT to the default SDK folder" {
    [ "$(count_lines "${CONF_FILE}" "DOTNET_ROOT=/usr/share/dotnet")" -eq 1 ]
}

@test "installs every value from the list once into each file" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ "$(count_lines "${ENVIRONMENT_D_FILE}" "DOTNET_ROOT=${SDK_DIR}")" -eq 1 ]
    [ "$(count_lines "${PROFILE_D_FILE}" "export DOTNET_ROOT=${SDK_DIR}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "DOTNET_ROOT DEFAULT=${SDK_DIR}")" -eq 1 ]

    local line name value
    while IFS= read -r line; do
        name="${line%%=*}"
        value="${line#*=}"
        [ "$(count_lines "${ENVIRONMENT_D_FILE}" "${name}=${value}")" -eq 1 ]
        [ "$(count_lines "${PROFILE_D_FILE}" "export ${name}=${value}")" -eq 1 ]
        [ "$(count_lines "${PAM_CONF}" "${name} DEFAULT=${value}")" -eq 1 ]
    done < <(conf_lines_without_root)

    cmp "${PROFILE_D_FILE}" "${BASHRC_D_FILE}"
    refute_fake_called '^sudo '
}

@test "the environment.d file has no export and appends the SDK to PATH" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ "$(grep -c 'export' "${ENVIRONMENT_D_FILE}")" -eq 0 ]
    [ "$(grep -c '\$' "${ENVIRONMENT_D_FILE}")" -eq 1 ]
    [ "$(count_lines "${ENVIRONMENT_D_FILE}" "PATH=\$PATH:${SDK_DIR}")" -eq 1 ]
}

@test "the pam_env block has no PATH line and keeps what pam_env.conf already held" {
    mkdir -p "${DOTNET_ENV_ETC_DIR}/security"
    printf '# the stock file\nEDITOR DEFAULT=vim\n' > "${PAM_CONF}"

    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ "$(grep -c '^PATH' "${PAM_CONF}")" -eq 0 ]
    [ "$(sed -n '1,2p' "${PAM_CONF}")" = "$(printf '# the stock file\nEDITOR DEFAULT=vim')" ]
    [ "$(count_lines "${PAM_CONF}" "${BLOCK_BEGIN}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "${BLOCK_END}")" -eq 1 ]
}

@test "installing twice leaves exactly one pam_env block, holding the current values" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ "$(count_lines "${PAM_CONF}" "${BLOCK_BEGIN}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "${BLOCK_END}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "DOTNET_NOLOGO DEFAULT=true")" -eq 1 ]

    # A changed SDK replaces the block's value rather than adding another.
    local other="${BATS_TEST_TMPDIR}/other-sdk"
    mkdir -p "${other}"
    cp "${SDK_FOLDER}/dotnet" "${other}/dotnet"
    DOTNET_ENV_SDK_DIR="${other}" run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(count_lines "${PAM_CONF}" "${BLOCK_BEGIN}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "DOTNET_ROOT DEFAULT=${other}")" -eq 1 ]
    [ "$(count_lines "${PAM_CONF}" "DOTNET_ROOT DEFAULT=${SDK_DIR}")" -eq 0 ]
}

@test "a pam_env.conf with an unpaired marker is left as it is" {
    mkdir -p "${DOTNET_ENV_ETC_DIR}/security"
    printf '%s\nKEEP DEFAULT=me\n' "${BLOCK_BEGIN}" > "${PAM_CONF}"
    local before
    before="$(cat "${PAM_CONF}")"

    run "${INSTALL_SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"pair them up or remove them by hand"* ]]
    [ "$(cat "${PAM_CONF}")" = "${before}" ]
}

@test "installs nothing when the SDK has no dotnet" {
    DOTNET_ENV_SDK_DIR="${BATS_TEST_TMPDIR}/no-sdk" run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No .NET SDK at ${BATS_TEST_TMPDIR}/no-sdk"* ]]

    [ ! -e "${ENVIRONMENT_D_FILE}" ]
    [ ! -e "${PROFILE_D_FILE}" ]
    [ ! -e "${BASHRC_D_FILE}" ]
    [ ! -e "${PAM_CONF}" ]
    [ ! -e "${LINK}" ]
    [ ! -L "${LINK}" ]
}

@test "a list line that is not NAME=value stops the install before anything is written" {
    copy_tree
    printf 'NOT A SETTING\n' >> "${TREE}/settings/dotnet-env/dotnet.conf"

    run "${TREE}/install.d/dotnet-environment"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not a NAME=value line: NOT A SETTING"* ]]
    [ ! -e "${ENVIRONMENT_D_FILE}" ]
    [ ! -e "${PAM_CONF}" ]
}

@test "a list value pam_env would expand stops the install" {
    copy_tree
    # shellcheck disable=SC2016
    printf 'DOTNET_BAD=$HOME\n' >> "${TREE}/settings/dotnet-env/dotnet.conf"

    run "${TREE}/install.d/dotnet-environment"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DOTNET_BAD holds a character other than"* ]]
    [ ! -e "${PAM_CONF}" ]
}

@test "a name set twice in the list stops the install" {
    copy_tree
    printf 'DOTNET_NOLOGO=false\n' >> "${TREE}/settings/dotnet-env/dotnet.conf"

    run "${TREE}/install.d/dotnet-environment"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DOTNET_NOLOGO is set more than once"* ]]
}

@test "every file is world-readable whatever the umask" {
    run sh -c 'umask 027 && exec "$0"' "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    local file
    for file in "${ENVIRONMENT_D_FILE}" "${PROFILE_D_FILE}" "${BASHRC_D_FILE}" "${PAM_CONF}"; do
        [ "$(stat -c '%a' "${file}")" = 644 ]
    done
    for file in environment.d profile.d bash.bashrc.d security; do
        [ "$(stat -c '%a' "${DOTNET_ENV_ETC_DIR}/${file}")" = 755 ]
    done
}

@test "links dotnet where a minimal PATH finds it" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    [ -L "${LINK}" ]
    [ "$(readlink -f "${LINK}")" = "$(readlink -f "${SDK_FOLDER}/dotnet")" ]
    [ "$(PATH="${DOTNET_ENV_BIN_DIR}:/usr/bin:/bin" sh -c 'readlink -f "$(command -v dotnet)"')" = "$(readlink -f "${SDK_FOLDER}/dotnet")" ]
}

@test "leaves something other than a link where the link would go" {
    mkdir -p "${DOTNET_ENV_BIN_DIR}"
    printf '#!/bin/sh\n' > "${LINK}"

    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"something other than a link is already there"* ]]
    [ ! -L "${LINK}" ]
    [ "$(cat "${LINK}")" = '#!/bin/sh' ]
}

# The scripts are expanded by the shell each test starts, not by bats.
# shellcheck disable=SC2016
@test "the profile.d file puts the SDK and the user's tools on PATH once, however often it is sourced" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    local shell
    for shell in sh bash; do
        command -v "${shell}" > /dev/null || continue
        run env -i HOME="${HOME}" PATH=/usr/bin:/bin "$(command -v "${shell}")" -c '. "$1" && . "$1" && printf "%s\n" "$PATH" "$DOTNET_ROOT" "$DOTNET_NOLOGO"' _ "${PROFILE_D_FILE}"
        [ "${status}" -eq 0 ]
        [ "${lines[0]}" = "/usr/bin:/bin:${SDK_DIR}:${HOME}/.dotnet/tools" ]
        [ "${lines[1]}" = "${SDK_DIR}" ]
        [ "${lines[2]}" = true ]
    done

    # Starting from a PATH with no dotnet on it, as the host running the
    # suite may have one of its own in /usr/bin, which would come first.
    local empty="${BATS_TEST_TMPDIR}/empty-bin" sh_path readlink_path
    mkdir -p "${empty}"
    sh_path="$(command -v sh)"
    readlink_path="$(command -v readlink)"
    run env -i HOME="${HOME}" PATH="${empty}" "${sh_path}" -c '. "$1" && "$2" -f "$(command -v dotnet)"' _ "${PROFILE_D_FILE}" "${readlink_path}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(readlink -f "${SDK_FOLDER}/dotnet")" ]
}

# shellcheck disable=SC2016
@test "the profile.d file leaves out the user's tools when there is no HOME" {
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]

    run env -i PATH=/usr/bin:/bin sh -c '. "$1" && printf "%s\n" "$PATH"' _ "${PROFILE_D_FILE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/usr/bin:/bin:${SDK_DIR}" ]
}

@test "uninstall-dotnet removes the files, the pam_env block, the link and the SDK" {
    mkdir -p "${DOTNET_ENV_ETC_DIR}/security"
    printf 'EDITOR DEFAULT=vim\n' > "${PAM_CONF}"
    run "${INSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    local legacy="${DOTNET_INSTALL_ROOT}/dotnet-legacy-20250101T000000Z"
    mkdir -p "${legacy}" "${DOTNET_INSTALL_ROOT}/dotnet-other" "${DOTNET_INSTALL_ROOT}/unrelated"
    ln -s "${SDK_FOLDER}" "${DOTNET_INSTALL_ROOT}/dotnet.tmp-link"

    run "${UNINSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".NET removed"* ]]

    [ ! -e "${ENVIRONMENT_D_FILE}" ]
    [ ! -e "${PROFILE_D_FILE}" ]
    [ ! -e "${BASHRC_D_FILE}" ]
    [ "$(cat "${PAM_CONF}")" = "EDITOR DEFAULT=vim" ]
    [ ! -e "${LINK}" ]
    [ ! -L "${LINK}" ]
    [ ! -e "${SDK_DIR}" ]
    [ ! -L "${SDK_DIR}" ]
    [ ! -L "${DOTNET_INSTALL_ROOT}/dotnet.tmp-link" ]
    [ ! -e "${SDK_FOLDER}" ]
    [ ! -e "${legacy}" ]
    # Names install-latest-dotnet never gives its folders are left.
    [ -d "${DOTNET_INSTALL_ROOT}/dotnet-other" ]
    [ -d "${DOTNET_INSTALL_ROOT}/unrelated" ]
    refute_fake_called '^sudo '
}

@test "uninstall-dotnet removes a legacy SDK folder at the live path" {
    rm "${SDK_DIR}"
    mkdir -p "${SDK_DIR}"

    run "${UNINSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ ! -e "${SDK_DIR}" ]
}

@test "uninstall-dotnet leaves a dotnet link made for another SDK" {
    mkdir -p "${DOTNET_ENV_BIN_DIR}"
    ln -s /opt/other/dotnet "${LINK}"

    run "${UNINSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${LINK}")" = /opt/other/dotnet ]
}

@test "uninstall-dotnet succeeds when nothing is installed" {
    rm "${SDK_DIR}"
    rm -rf "${SDK_FOLDER}"

    run "${UNINSTALL_SCRIPT}"
    [ "${status}" -eq 0 ]
    [ ! -e "${PAM_CONF}" ]
}

@test "uninstall-dotnet stops while an install-latest-dotnet run holds the lock" {
    local lock="${DOTNET_INSTALL_ROOT}/dotnet-install.lock"
    : > "${lock}"

    exec 8< "${lock}"
    flock -n 8
    run "${UNINSTALL_SCRIPT}"
    exec 8<&-
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"An install-latest-dotnet run holds ${lock}"* ]]
    [ -L "${SDK_DIR}" ]
}

@test "uninstall-dotnet refuses to run from a Claude Code session" {
    run env CLAUDECODE=1 "${UNINSTALL_SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be run from a Claude Code session"* ]]
    [ -L "${SDK_DIR}" ]
}
