#!/usr/bin/env bats
# End-to-end tests for the install.d/ steps that change system state. Every
# privileged step goes through the fake sudo from test_helper, which logs the
# command line and never runs it, and every command a step runs without sudo
# is a logging fake too, so nothing here touches the host. Each step is run
# once with every command succeeding, and once with a single step failing,
# which must stop the script, name the failed step and skip `success`.

bats_require_minimum_version 1.5.0

load test_helper

INSTALL_D="${REPO_DIR}/install.d"

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    # Empty, so every install-state flag in lib/common reads 0 unless a test
    # adds the binary it probes for.
    export INSTALL_STATE_BIN_DIR="${BATS_TEST_TMPDIR}/state-bin"
    mkdir -p "${INSTALL_STATE_BIN_DIR}"
    # Each test that needs a step to fail sets this for its own run only.
    unset FAKE_SUDO_FAIL
    setup_fake_sudo systemctl pacman flatpak balooctl6 hostnamectl aa-enforce
    seed_fake_output hostnamectl <<< "testhost"
}

# Marks a tool as installed for lib/common's install-state flags.
# Usage: mark_installed <binary-name>
mark_installed() {
    : > "${INSTALL_STATE_BIN_DIR}/$1"
}

# Runs install.d/<name> with the fakes in place. Any VAR=value arguments
# (e.g. FAKE_SUDO_FAIL, FAKE_EXIT_<tool>) are set for that run only, through
# env rather than export, so shellcheck does not flag a cross-@test
# modification (SC2030/SC2031).
# Usage: run_step <name> [VAR=value ...]
run_step() {
    local _step="$1"
    shift
    run env "$@" "${INSTALL_D}/${_step}"
}

# Asserts the last run_step stopped with status 1, printed the given die text
# and never reached the step's success line.
# Usage: assert_step_died <die-text> <success-text>
assert_step_died() {
    [ "${status}" -eq 1 ] || return 1
    [[ "${output}" == *"$1"* ]] || return 1
    [[ "${output}" != *"$2"* ]]
}

# ── btrfs-scrub ──────────────────────────────────────────────────────────────

@test "btrfs-scrub installs and enables the scrub timer" {
    run_step btrfs-scrub
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"btrfs scrub installed"* ]]
    assert_fake_called '^sudo cp .*/btrfs-scrub\.service /etc/systemd/system/$'
    assert_fake_called '^sudo cp .*/btrfs-scrub\.timer /etc/systemd/system/$'
    assert_fake_called '^sudo systemctl daemon-reload$'
    assert_fake_called '^sudo systemctl enable --now btrfs-scrub\.timer$'
}

@test "btrfs-scrub stops when reloading systemd fails" {
    run_step btrfs-scrub FAKE_SUDO_FAIL='^systemctl daemon-reload$'
    assert_step_died "Failed to reload the systemd manager" "btrfs scrub installed"
    refute_fake_called 'enable --now btrfs-scrub\.timer'
}

# ── configure-flatpak ────────────────────────────────────────────────────────

@test "configure-flatpak replaces flathub with the verified and whitelist remotes" {
    mark_installed flatpak
    seed_fake_output flatpak <<< "flathub"
    run_step configure-flatpak
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Flatpak configured"* ]]
    assert_fake_called '^sudo flatpak remote-delete flathub$'
    assert_fake_called '^sudo flatpak remote-add .* flathub-verified '
    assert_fake_called '^sudo flatpak remote-add .* flathub-whitelist '
    assert_fake_called '^sudo flatpak remote-modify .* flathub-verified$'
    assert_fake_called '^sudo flatpak remote-modify .* flathub-whitelist$'
}

@test "configure-flatpak stops when adding the flathub-verified remote fails" {
    mark_installed flatpak
    run_step configure-flatpak FAKE_SUDO_FAIL='^flatpak remote-add .* flathub-verified '
    assert_step_died "Failed to add the flathub-verified flatpak remote" "Flatpak configured"
    refute_fake_called 'flathub-whitelist'
}

@test "configure-flatpak does nothing when flatpak is not installed" {
    run_step configure-flatpak
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Flatpak configured"* ]]
    refute_fake_called 'flatpak'
}

# ── configure-network ────────────────────────────────────────────────────────

@test "configure-network configures NetworkManager, removes dnsmasq and enables firewalld" {
    run_step configure-network
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Network configured"* ]]
    [[ "${output}" == *"Enabling MAC privacy"* ]]
    assert_fake_called '^sudo cp .*/wifi_rand_mac\.conf /etc/NetworkManager/conf\.d/wifi_rand_mac\.conf$'
    assert_fake_called '^sudo systemctl disable --now dnsmasq$'
    assert_fake_called '^sudo pacman -Rns --noconfirm dnsmasq$'
    assert_fake_called '^sudo systemctl enable --now firewalld$'
    assert_fake_called '^sudo nmcli general reload$'
}

@test "configure-network stops when removing a dnsmasq config fails" {
    run_step configure-network FAKE_SUDO_FAIL='^rm -f /etc/NetworkManager/dnsmasq\.d/00-caching\.conf$'
    assert_step_died "Failed to remove /etc/NetworkManager/dnsmasq.d/00-caching.conf" "Network configured"
    refute_fake_called '01-async-logs\.conf'
}

@test "configure-network stops when copying the MAC randomisation config fails" {
    run_step configure-network FAKE_SUDO_FAIL='^cp .*/wifi_rand_mac\.conf '
    assert_step_died "Failed to copy /etc/NetworkManager/conf.d/wifi_rand_mac.conf" "Network configured"
    refute_fake_called 'connectivity-test\.conf'
}

@test "configure-network leaves MAC randomisation off when incus is installed" {
    mark_installed incus
    run_step configure-network
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Network configured"* ]]
    refute_fake_called 'wifi_rand_mac'
    [[ "${output}" == *"Skipping MAC privacy because incus is installed"* ]]
    [[ "${output}" != *"Enabling MAC privacy"* ]]
    assert_fake_called '^sudo cp .*/connectivity-test\.conf '
}

@test "configure-network skips disabling and removing dnsmasq when it is absent" {
    run_step configure-network FAKE_EXIT_systemctl=1 FAKE_EXIT_pacman=1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Network configured"* ]]
    refute_fake_called 'disable --now dnsmasq'
    refute_fake_called 'pacman -Rns --noconfirm dnsmasq'
    assert_fake_called '^sudo rm -f /etc/NetworkManager/dnsmasq\.d/03-allow-doh\.conf$'
}

# ── dash ─────────────────────────────────────────────────────────────────────

@test "dash installs dash, dashbinsh and checkbashisms" {
    run_step dash
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dash installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm dash dashbinsh checkbashisms$'
}

@test "dash stops when installing the packages fails" {
    run_step dash FAKE_SUDO_FAIL='^pacman -S '
    assert_step_died "Failed to install dash, dashbinsh and checkbashisms" "dash installed"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo pacman -S --needed --noconfirm dash dashbinsh checkbashisms" ]
}

# ── disable-baloo ────────────────────────────────────────────────────────────

@test "disable-baloo disables and purges the indexer" {
    run_step disable-baloo
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"baloo disabled"* ]]
    assert_fake_called '^balooctl6 disable$'
    assert_fake_called '^balooctl6 purge$'
}

@test "disable-baloo reports the skip, not a success, when balooctl6 is not installed" {
    # A PATH holding only the tools the script needs, so neither the fake nor
    # any real balooctl6 on the host is found.
    local _bin="${BATS_TEST_TMPDIR}/no-baloo-bin"
    mkdir -p "${_bin}"
    ln -s "$(type -P dirname)" "${_bin}/dirname"
    ln -s "$(type -P readlink)" "${_bin}/readlink"
    run_step disable-baloo PATH="${_bin}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"balooctl6 is not installed, so there is no baloo indexer to disable"* ]]
    [[ "${output}" != *"baloo disabled"* ]]
    refute_fake_called '^balooctl6 '
}

@test "disable-baloo stops when disabling the indexer fails" {
    run_step disable-baloo FAKE_EXIT_balooctl6=1
    assert_step_died "Failed to disable the baloo file indexer" "baloo disabled"
    refute_fake_called '^balooctl6 purge'
}

# ── enable-services ──────────────────────────────────────────────────────────

@test "enable-services enables ssh-agent, apparmor, logrotate, paccache and pacman-sync" {
    run_step enable-services
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Services enabled"* ]]
    assert_fake_called '^systemctl enable --now --user ssh-agent$'
    assert_fake_called '^sudo pacman -S --needed --noconfirm apparmor$'
    assert_fake_called '^sudo aa-enforce firejail-default$'
    assert_fake_called '^sudo systemctl enable --now logrotate\.timer$'
    assert_fake_called '^sudo systemctl enable --now paccache\.timer$'
    assert_fake_called '^sudo systemctl enable --now pacman-sync\.timer$'
}

@test "enable-services stops when enabling the ssh-agent user service fails" {
    run_step enable-services FAKE_EXIT_systemctl=1
    assert_step_died "Failed to enable the ssh-agent user service" "Services enabled"
    refute_fake_called 'apparmor\.service'
}

@test "enable-services installs apparmor before enabling it and enforcing its profile" {
    run_step enable-services
    [ "${status}" -eq 0 ]
    [ "$(grep -E 'apparmor|aa-enforce' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' \
        'sudo pacman -S --needed --noconfirm apparmor' \
        'sudo systemctl enable --now apparmor.service' \
        'sudo aa-enforce firejail-default')" ]
}

@test "enable-services stops when installing apparmor fails and never enables it" {
    run_step enable-services FAKE_SUDO_FAIL='^pacman -S --needed --noconfirm apparmor$'
    assert_step_died "Failed to install apparmor" "Services enabled"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo pacman -S --needed --noconfirm apparmor" ]
}

@test "enable-services stops when enforcing the firejail apparmor profile fails" {
    run_step enable-services FAKE_SUDO_FAIL='^aa-enforce '
    assert_step_died "Failed to enforce the firejail-default apparmor profile" "Services enabled"
    refute_fake_called 'logrotate'
}

# ── fail2ban ─────────────────────────────────────────────────────────────────

@test "fail2ban installs its jails and enables the service" {
    run_step fail2ban
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fail2ban installed"* ]]
    assert_fake_called '^sudo cp .*/ssh\.local /etc/fail2ban/jail\.d/ssh\.local$'
    assert_fake_called '^sudo systemctl enable --now fail2ban$'
}

@test "fail2ban stops when copying the ssh jail fails" {
    run_step fail2ban FAKE_SUDO_FAIL='^cp .*/ssh\.local '
    assert_step_died "Failed to copy /etc/fail2ban/jail.d/ssh.local" "fail2ban installed"
    refute_fake_called 'pacman -S'
}

# ── firejail ─────────────────────────────────────────────────────────────────

@test "firejail installs firejail and copies the user profiles" {
    run_step firejail
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"firejail installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm firejail$'
    local _profile
    for _profile in git.local shellcheck.local ssh.local; do
        [ -f "${HOME}/.config/firejail/${_profile}" ]
    done
}

@test "firejail stops when the user profile directory cannot be created" {
    : > "${HOME}/.config"
    run_step firejail
    assert_step_died "Failed to create ${HOME}/.config/firejail" "firejail installed"
    [[ "${output}" != *"Failed to copy"* ]]
}

# ── harden-system ────────────────────────────────────────────────────────────

@test "harden-system keeps both sysctl restrictions when no exempt tool is installed" {
    run_step harden-system
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"System hardened"* ]]
    assert_fake_called '^sudo cp .*/unprivileged_userns_clone\.conf /etc/sysctl\.d/unprivileged_userns_clone\.conf$'
    assert_fake_called '^sudo cp .*/kexec\.conf /etc/sysctl\.d/kexec\.conf$'
    refute_fake_called '^sudo rm '
}

@test "harden-system removes the userns restriction once when docker and incus are both installed" {
    mark_installed docker
    mark_installed incus
    run_step harden-system
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"System hardened"* ]]
    [ "$(grep -c '^sudo rm /etc/sysctl\.d/unprivileged_userns_clone\.conf$' "${FAKE_BIN_LOG}")" -eq 1 ]
    refute_fake_called '^sudo rm /etc/sysctl\.d/kexec\.conf$'
}

@test "harden-system removes the kexec restriction when zoom is installed" {
    mark_installed zoom
    run_step harden-system
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"System hardened"* ]]
    assert_fake_called '^sudo rm /etc/sysctl\.d/kexec\.conf$'
    refute_fake_called '^sudo rm /etc/sysctl\.d/unprivileged_userns_clone\.conf$'
}

@test "harden-system stops when setting the sudoers.d owner fails" {
    run_step harden-system FAKE_SUDO_FAIL='^chown '
    assert_step_died "Failed to set the owner of /etc/sudoers.d" "System hardened"
    refute_fake_called '^sudo chmod 750 /etc/sudoers\.d$'
}

@test "harden-system stops when removing the kexec restriction fails" {
    mark_installed zoom
    run_step harden-system FAKE_SUDO_FAIL='^rm /etc/sysctl\.d/kexec\.conf$'
    assert_step_died "Failed to remove /etc/sysctl.d/kexec.conf" "System hardened"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo rm /etc/sysctl.d/kexec.conf" ]
}

# ── pacman-hooks ─────────────────────────────────────────────────────────────

@test "pacman-hooks copies both hooks" {
    run_step pacman-hooks
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Pacman hooks installed"* ]]
    assert_fake_called '^sudo cp .*/pacman-cache-cleanup\.hook /etc/pacman\.d/hooks/pacman-cache-cleanup\.hook$'
    assert_fake_called '^sudo cp .*/spectacle-remove-firejail-wrapper\.hook /etc/pacman\.d/hooks/spectacle-remove-firejail-wrapper\.hook$'
}

@test "pacman-hooks stops when copying a hook fails" {
    run_step pacman-hooks FAKE_SUDO_FAIL='^cp .*/pacman-cache-cleanup\.hook '
    assert_step_died "Failed to copy /etc/pacman.d/hooks/pacman-cache-cleanup.hook" "Pacman hooks installed"
    refute_fake_called 'spectacle-remove-firejail-wrapper'
}

# ── remove-aur-helpers ───────────────────────────────────────────────────────

@test "remove-aur-helpers removes yay and paru when both are installed" {
    run_step remove-aur-helpers
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AUR helpers removed"* ]]
    assert_fake_called '^sudo pacman -Rns --noconfirm yay$'
    assert_fake_called '^sudo pacman -Rns --noconfirm paru$'
}

@test "remove-aur-helpers removes nothing when neither helper is installed" {
    run_step remove-aur-helpers FAKE_EXIT_pacman=1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AUR helpers removed"* ]]
    refute_fake_called '^sudo pacman -Rns'
}

@test "remove-aur-helpers stops when removing yay fails" {
    run_step remove-aur-helpers FAKE_SUDO_FAIL='^pacman -Rns --noconfirm yay$'
    assert_step_died "Failed to remove yay" "AUR helpers removed"
    refute_fake_called 'paru'
}

# ── security-tools ───────────────────────────────────────────────────────────

@test "security-tools installs and enables the security tooling" {
    run_step security-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Security tools installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm audit$'
    assert_fake_called '^sudo systemctl enable --now auditd$'
    assert_fake_called 'usbguard generate-policy'
    assert_fake_called '^sudo systemctl enable --now usbguard$'
    assert_fake_called '^sudo pacman -S --needed --noconfirm arch-audit$'
}

@test "security-tools installs audit before copying its rules and enabling auditd" {
    run_step security-tools
    [ "${status}" -eq 0 ]
    [ "$(grep -E ' audit$|/etc/audit/|auditd$' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' \
        'sudo pacman -S --needed --noconfirm audit' \
        "sudo cp ${REPO_DIR}/settings/audit/rules/00_passwd.rules /etc/audit/rules.d" \
        "sudo cp ${REPO_DIR}/settings/audit/rules/01_security.rules /etc/audit/rules.d" \
        "sudo cp ${REPO_DIR}/settings/audit/rules/02_audit-config.rules /etc/audit/rules.d" \
        'sudo systemctl enable --now auditd')" ]
}

@test "security-tools stops when installing audit fails and never copies its rules or enables it" {
    run_step security-tools FAKE_SUDO_FAIL='^pacman -S --needed --noconfirm audit$'
    assert_step_died "Failed to install audit" "Security tools installed"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo pacman -S --needed --noconfirm audit" ]
}

@test "security-tools stops when generating the usbguard base policy fails" {
    run_step security-tools FAKE_SUDO_FAIL='generate-policy'
    assert_step_died "Failed to generate /etc/usbguard/rules.d/00_base.conf" "Security tools installed"
    refute_fake_called '01_allow_keyboard_and_mouse'
}

# ── shell-environment ────────────────────────────────────────────────────────

@test "shell-environment installs the shared and interactive shell config" {
    run_step shell-environment
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Shell environment installed"* ]]
    assert_fake_called '^sudo install -m 0644 .*/20_xdg-dirs\.sh /etc/profile\.d/20_xdg-dirs\.sh$'
    assert_fake_called '^sudo install -m 0644 .*/95_update\.sh /etc/bash\.bashrc\.d/95_update\.sh$'
}

@test "shell-environment stops when installing a profile.d script fails" {
    run_step shell-environment FAKE_SUDO_FAIL='^install -m 0644 .* /etc/profile\.d/20_xdg-dirs\.sh$'
    assert_step_died "Failed to install /etc/profile.d/20_xdg-dirs.sh" "Shell environment installed"
    refute_fake_called '/etc/bash\.bashrc\.d/20_xdg-dirs\.sh'
}

# ── shell-prompt ─────────────────────────────────────────────────────────────

@test "shell-prompt installs starship and deploys its theme" {
    run_step shell-prompt
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Starship prompt installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm starship$'
    assert_fake_called '^sudo cp .*/starship\.toml /etc/starship\.toml$'
}

@test "shell-prompt stops when copying the starship theme fails" {
    run_step shell-prompt FAKE_SUDO_FAIL='^cp .*/starship\.toml '
    assert_step_died "Failed to copy /etc/starship.toml" "Starship prompt installed"
    refute_fake_called '^sudo tee '
}

# ── harden-ssh ───────────────────────────────────────────────────────────────

SSHD_SOURCE_DIR="${REPO_DIR}/settings/sshd"
SSHD_TARGET_DIR="/etc/ssh/sshd_config.d"

@test "harden-ssh copies every sshd drop-in under its own name, in order" {
    run_step harden-ssh
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH hardened"* ]]

    local _conf _expected=()
    for _conf in "${SSHD_SOURCE_DIR}"/*.conf; do
        _expected+=("sudo cp ${_conf} ${SSHD_TARGET_DIR}/$(basename "${_conf}")")
    done
    [ "${#_expected[@]}" -gt 0 ]
    [ "$(grep '^sudo cp ' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' "${_expected[@]}")" ]
}

@test "harden-ssh stops at a failed copy, naming its target, and copies nothing after it" {
    run_step harden-ssh FAKE_SUDO_FAIL='^cp .*/07_X11Forwarding\.conf '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to copy ${SSHD_TARGET_DIR}/07_X11Forwarding.conf"* ]]
    [[ "${output}" != *"SSH hardened"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo cp ${SSHD_SOURCE_DIR}/07_X11Forwarding.conf ${SSHD_TARGET_DIR}/07_X11Forwarding.conf" ]
}

@test "harden-ssh stops when installing curl fails and never renders the key server config" {
    run_step harden-ssh FAKE_SUDO_FAIL='^pacman -S '
    assert_step_died "Failed to install curl" "SSH hardened"
    assert_fake_called '^sudo cp .*/13_TCPKeepAlive\.conf '
    refute_fake_called '^hostnamectl '
    refute_fake_called '^sudo tee '
}

@test "harden-ssh stops when the hostname is empty and never renders the key server config" {
    seed_fake_output hostnamectl < /dev/null
    run_step harden-ssh
    assert_step_died "Unable to determine hostname for key server AuthorizedKeysCommand config" "SSH hardened"
    assert_fake_called '^sudo pacman -S --needed --noconfirm curl$'
    assert_fake_called '^hostnamectl --static$'
    refute_fake_called '^sudo tee '
}

@test "harden-ssh stops when writing the key server config fails" {
    run_step harden-ssh FAKE_SUDO_FAIL='^tee /etc/ssh/sshd_config\.d/14_KeyServer\.conf$'
    assert_step_died "Failed to write ${SSHD_TARGET_DIR}/14_KeyServer.conf" "SSH hardened"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo tee ${SSHD_TARGET_DIR}/14_KeyServer.conf" ]
}
