#!/usr/bin/env bats
# Regression tests for how install.d/shell-environment deploys its files.
# Static assertions over the script rather than an end-to-end run: the paths
# it writes to (/etc/profile.d, /etc/bash.bashrc.d) are hard-coded real
# system locations, so running it here would mutate the host - the same
# reason install.bats asserts wiring rather than executing steps.

bats_require_minimum_version 1.5.0

load test_helper

SHELL_ENVIRONMENT="${REPO_DIR}/install.d/shell-environment"

# Lists the source path of every settings file the script deploys.
deployed_sources() {
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    grep -oE '\$BASEDIR/settings/[^"]+' "${SHELL_ENVIRONMENT}"
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

@test "shell-environment deploys every file with an explicit mode" {
    missing=""
    while IFS= read -r line; do
        case "${line}" in
            *" -m "*) ;;
            *) missing="${missing} ${line}" ;;
        esac
    done <<< "$(grep -E '^\s*sudo install ' "${SHELL_ENVIRONMENT}")"

    [ -z "${missing}" ]
}

@test "shell-environment deploys every file world-readable" {
    # 0644, not the 0640 these files used to land as: /etc/profile.d and
    # /etc/bash.bashrc.d are sourced by every user's shell, not just root's.
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    deployments="$(grep -cE '^\s*sudo install -m 0644 "\$BASEDIR/settings/' "${SHELL_ENVIRONMENT}")"
    # shellcheck disable=SC2016 # regex escape for a literal $, not a shell expansion
    total="$(grep -cE '^\s*sudo install .*"\$BASEDIR/settings/' "${SHELL_ENVIRONMENT}")"

    [ "${deployments}" -eq "${total}" ]
}

@test "shell-environment deploys every file under settings/shell-env" {
    missing=""
    for source in "${REPO_DIR}"/settings/shell-env/*; do
        [ -f "${source}" ] || continue
        name="$(basename "${source}")"
        deployed_sources | grep -qF "settings/shell-env/${name}" || missing="${missing} ${name}"
    done

    [ -z "${missing}" ]
}

@test "shell-environment deploys every file under settings/bash.bashrc.d" {
    missing=""
    for source in "${REPO_DIR}"/settings/bash.bashrc.d/*; do
        [ -f "${source}" ] || continue
        name="$(basename "${source}")"
        deployed_sources | grep -qF "settings/bash.bashrc.d/${name}" || missing="${missing} ${name}"
    done

    [ -z "${missing}" ]
}
