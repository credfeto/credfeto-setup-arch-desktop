#!/usr/bin/env bats
# Regression tests for install.d/configure-pacman's idempotent pacman.conf
# option-enabling logic (ILoveCandy, CheckSpace, VerbosePkgLists). Runs
# against a fixture file (PACMAN_CONF override), never the real
# /etc/pacman.conf.

bats_require_minimum_version 1.5.0

load test_helper

CONFIGURE_PACMAN="${REPO_DIR}/install.d/configure-pacman"

setup() {
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixture"
    mkdir -p "${FIXTURE_DIR}"

    # A real sudo is neither available nor wanted in tests; this fake execs
    # the wrapped command directly as the current (fixture-owning) user.
    SUDO_BIN_DIR="${BATS_TEST_TMPDIR}/sudobin"
    mkdir -p "${SUDO_BIN_DIR}"
    cat > "${SUDO_BIN_DIR}/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
    chmod +x "${SUDO_BIN_DIR}/sudo"
    export PATH="${SUDO_BIN_DIR}:${PATH}"
}

write_fixture() {
    cat > "${FIXTURE_DIR}/pacman.conf"
}

run_configure_pacman() {
    PACMAN_CONF="${FIXTURE_DIR}/pacman.conf" run "${CONFIGURE_PACMAN}"
}

@test "configure-pacman inserts ILoveCandy when it has no line at all" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc
CheckSpace
VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist
EOF

    run_configure_pacman

    [ "$status" -eq 0 ]
    grep -qx "ILoveCandy" "${FIXTURE_DIR}/pacman.conf"
}

@test "configure-pacman uncomments CheckSpace when commented" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc
#CheckSpace
#VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist
EOF

    run_configure_pacman

    [ "$status" -eq 0 ]
    grep -qx "CheckSpace" "${FIXTURE_DIR}/pacman.conf"
    run ! grep -qx "#CheckSpace" "${FIXTURE_DIR}/pacman.conf"
}

@test "configure-pacman uncomments VerbosePkgLists when commented" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc
CheckSpace
#VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist
EOF

    run_configure_pacman

    [ "$status" -eq 0 ]
    grep -qx "VerbosePkgLists" "${FIXTURE_DIR}/pacman.conf"
    run ! grep -qx "#VerbosePkgLists" "${FIXTURE_DIR}/pacman.conf"
}

@test "configure-pacman leaves already-active options untouched" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc
ILoveCandy
CheckSpace
VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist
EOF

    before="$(cat "${FIXTURE_DIR}/pacman.conf")"
    run_configure_pacman
    after="$(cat "${FIXTURE_DIR}/pacman.conf")"

    [ "$status" -eq 0 ]
    [ "$before" = "$after" ]
}

@test "configure-pacman scopes its check to the [options] section only" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc

[core]
CheckSpace
Include = /etc/pacman.d/mirrorlist
EOF

    run_configure_pacman

    [ "$status" -eq 0 ]
    # CheckSpace must appear twice: the pre-existing [core] line (left
    # untouched) plus a newly inserted line under [options] - a global,
    # unscoped check would have wrongly treated the [core] line as already
    # satisfying [options] and skipped the insert.
    count="$(grep -cx "CheckSpace" "${FIXTURE_DIR}/pacman.conf")"
    [ "$count" -eq 2 ]
    sed -n '/^\[options\]/,/^\[/p' "${FIXTURE_DIR}/pacman.conf" | grep -qx "CheckSpace"
}

@test "configure-pacman is idempotent across repeated runs" {
    write_fixture <<'EOF'
[options]
HoldPkg = pacman glibc
#CheckSpace
#VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist
EOF

    run_configure_pacman
    first="$(cat "${FIXTURE_DIR}/pacman.conf")"
    run_configure_pacman
    second="$(cat "${FIXTURE_DIR}/pacman.conf")"

    [ "$status" -eq 0 ]
    [ "$first" = "$second" ]
}
