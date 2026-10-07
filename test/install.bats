#!/usr/bin/env bats
# Regression test: install must actually invoke every install.d/ step it
# ships. install itself is not run end-to-end here - most steps mutate real
# system state (pacman, sshd, sysctl, ...) and are exercised individually by
# their own bats suites instead; this only asserts the wiring is present.

load test_helper

INSTALL="${REPO_DIR}/install"

@test "install invokes every script present under install.d/" {
    missing=""
    for step in "${REPO_DIR}"/install.d/*; do
        [ -f "${step}" ] || continue
        [ -x "${step}" ] || continue
        step_name="$(basename "${step}")"
        grep -qF "install.d/${step_name}" "${INSTALL}" || missing="${missing} ${step_name}"
    done

    [ -z "${missing}" ]
}

@test "install wraps every install.d/ step in || die, so a failed step stops it" {
    # Every step exits non-zero only on a real failure, so a bare call would
    # let install carry on and print "Done" over a step that did not finish.
    unguarded=""
    while IFS= read -r line; do
        step_name="${line#*install.d/}"
        step_name="${step_name%%\"*}"
        case "${line}" in
            *"|| die \"install.d/${step_name} failed\"") ;;
            *) unguarded="${unguarded} ${step_name}" ;;
        esac
    done < <(grep -E 'install\.d/' "${INSTALL}")

    [ -z "${unguarded}" ]
}
