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
    # configure-flatpak stops unless the whitelist filter is checked out
    # where it derives the path from HOME.
    unset FLATPAK_FILTER
    mkdir -p "${HOME}/work/personal/credfeto-flatpak-filter"
    : > "${HOME}/work/personal/credfeto-flatpak-filter/flatpak.filter"
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

# Replaces the systemctl fake with one whose `is-active` and `is-enabled`
# probes exit with FAKE_EXIT_systemctl_is_active and
# FAKE_EXIT_systemctl_is_enabled (default 0), so a test can stop
# NetworkManager and dnsmasq independently. Every other call exits 0.
# Usage: fake_systemctl_probes
fake_systemctl_probes() {
    replace_fake systemctl <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "\${FAKE_BIN_LOG}"
case "\$1" in
    is-active) exit "\${FAKE_EXIT_systemctl_is_active:-0}" ;;
    is-enabled) exit "\${FAKE_EXIT_systemctl_is_enabled:-0}" ;;
esac
exit 0
EOF
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

# Prints "<mode> <target>" for every file deployment in the fake log, which
# is every `sudo install` given a mode, a source and a full target path.
# Usage: deployed_modes
deployed_modes() {
    sed -n -E 's/^sudo install -m ([^ ]+) [^ ]+ ([^ ]+)$/\1 \2/p' "${FAKE_BIN_LOG}"
}

# Asserts the `sudo install` lines in the fake log are exactly the given
# deployments, in order: the whole command line, so the mode, the source and
# the full target of every file. Each argument is "<mode> <source> <target>",
# with the source relative to the repo root.
# Usage: assert_installs_exactly "<mode> <source> <target>" ...
assert_installs_exactly() {
    local _deployment _expected=()
    for _deployment in "$@"; do
        _expected+=("sudo install -m ${_deployment%% *} ${REPO_DIR}/${_deployment#* }")
    done
    [ "$(grep '^sudo install ' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' "${_expected[@]}")" ]
}

# ── deployed file modes ──────────────────────────────────────────────────────
# cp gives a new file the working tree's checkout mode and keeps the mode of
# one that is already there, so every step deploys with `install -m` instead
# (ai/local/file-modes.instructions.md).

# Prints, as grep -n does, every line under the given paths that runs cp as a
# command, with or without sudo and whatever comes ahead of it on the line.
# Comment lines are left out; so are names that only contain "cp" (scp,
# get_cp_options). Fails when there is no such line.
# Usage: cp_command_lines <path> ...
cp_command_lines() {
    grep -rnHE '(^|[^[:alnum:]_-])cp[[:space:]]' "$@" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

@test "no install script deploys a file with cp, with or without sudo" {
    # A file deployed into the user's home takes the checkout's mode and the
    # caller's umask from cp just as one deployed with sudo cp does.
    run cp_command_lines "${REPO_DIR}/install" "${INSTALL_D}" "${REPO_DIR}/units" "${REPO_DIR}/lib"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "the cp check reports cp run as a command, with or without sudo, and nothing else" {
    local _step="${BATS_TEST_TMPDIR}/cp-check/step"
    mkdir -p "${_step%/*}"
    cat > "${_step}" <<'EOF'
cp "$src" "$dest"
    sudo cp "$src" "$dest" || die "Failed to copy $dest"
[ -f "$src" ] && cp -f "$src" "$dest"
# install -m, not cp as it was
    # cp "$src" "$dest"
scp "$src" host:
override_switch="$(get_cp_options "$override")"
install -m 0644 "$src" "$dest/cp"
EOF
    local _target
    # A directory, as the check is given install.d, and a single file, as it
    # is given install.
    for _target in "${_step%/*}" "${_step}"; do
        run cp_command_lines "${_target}"
        [ "${status}" -eq 0 ]
        [ "$(cut -d: -f2 <<< "${output}" | tr '\n' ' ')" = '1 2 3 ' ]
    done
}

@test "the steps whose files every user or service reads deploy each one as 0644, to a full target path" {
    local _step
    for _step in btrfs-scrub enable-services fail2ban harden-ssh harden-system pacman-hooks shell-prompt; do
        : > "${FAKE_BIN_LOG}"
        run_step "${_step}"
        [ "${status}" -eq 0 ]
        assert_fake_called '^sudo install '
        # Nothing but 0644 deployments to a named file under /etc.
        run ! grep -vE '^0644 /etc/.*[^/]$' <(deployed_modes)
        [ "$(deployed_modes | wc -l)" -eq "$(grep -c '^sudo install -m ' "${FAKE_BIN_LOG}")" ]
    done
}

@test "configure-network deploys the dispatcher script executable and the NetworkManager configs as 0644" {
    run_step configure-network
    [ "${status}" -eq 0 ]
    # NetworkManager silently ignores a dispatcher script that is not
    # executable.
    assert_installs_exactly \
        '0644 settings/networkmanager/ip6-privacy.conf /etc/NetworkManager/conf.d/ip6-privacy.conf' \
        '0644 settings/networkmanager/wifi_rand_mac.conf /etc/NetworkManager/conf.d/wifi_rand_mac.conf' \
        '0644 settings/networkmanager/connectivity-test.conf /etc/NetworkManager/conf.d/connectivity-test.conf' \
        '0644 settings/networkmanager/dns.conf /etc/NetworkManager/conf.d/dns.conf' \
        '0755 hooks/networkmanager/10-update-timesyncd /etc/NetworkManager/dispatcher.d/10-update-timesyncd'
}

@test "enable-services deploys the logrotate defaults and the pacman-sync units as 0644, each to its own file" {
    run_step enable-services
    [ "${status}" -eq 0 ]
    assert_installs_exactly \
        '0644 settings/logrotate/01-defaults /etc/logrotate.d/01-defaults' \
        '0644 units/pacman-sync/pacman-sync.service /etc/systemd/system/pacman-sync.service' \
        '0644 units/pacman-sync/pacman-sync.timer /etc/systemd/system/pacman-sync.timer'
}

@test "harden-system deploys the banners and the modprobe, mkinitcpio and sysctl configs as 0644, each to its own file" {
    run_step harden-system
    [ "${status}" -eq 0 ]
    assert_installs_exactly \
        '0644 settings/issue/contents /etc/issue' \
        '0644 settings/issue/contents /etc/issue.net' \
        '0644 settings/issue/contents /etc/motd' \
        '0644 settings/modprobe/blacklist-firewire.conf /etc/modprobe.d/blacklist-firewire.conf' \
        '0644 settings/modprobe/disable-protocols.conf /etc/modprobe.d/disable-protocols.conf' \
        '0644 settings/mkinitcpio/01_compression.conf /etc/mkinitcpio.conf.d/01_compression.conf' \
        '0644 settings/sysctl/dmesg_restrict.conf /etc/sysctl.d/dmesg_restrict.conf' \
        '0644 settings/sysctl/harden_bpf.conf /etc/sysctl.d/harden_bpf.conf' \
        '0644 settings/sysctl/kptr_restrict.conf /etc/sysctl.d/kptr_restrict.conf' \
        '0644 settings/sysctl/ptrace_scope.conf /etc/sysctl.d/ptrace_scope.conf' \
        '0644 settings/sysctl/fs.conf /etc/sysctl.d/fs.conf' \
        '0644 settings/sysctl/kernel_modules.conf /etc/sysctl.d/kernel_modules.conf' \
        '0644 settings/sysctl/unprivileged_userns_clone.conf /etc/sysctl.d/unprivileged_userns_clone.conf' \
        '0644 settings/sysctl/kexec.conf /etc/sysctl.d/kexec.conf'
}

@test "security-tools deploys the audit rules as 0640 and the usbguard rules as 0600" {
    run_step security-tools
    [ "${status}" -eq 0 ]
    [ "$(deployed_modes)" = "$(printf '%s\n' \
        '0640 /etc/audit/rules.d/00_passwd.rules' \
        '0640 /etc/audit/rules.d/01_security.rules' \
        '0640 /etc/audit/rules.d/02_audit-config.rules' \
        '0600 /etc/usbguard/rules.d/01_allow_keyboard_and_mouse.conf' \
        '0600 /etc/usbguard/rules.d/02_mass_storage.conf' \
        '0600 /etc/usbguard/rules.d/99_adb.conf')" ]
    [ "$(grep -c '^sudo install ' "${FAKE_BIN_LOG}")" -eq 6 ]
}

# ── btrfs-scrub ──────────────────────────────────────────────────────────────

@test "btrfs-scrub installs and enables the scrub timer" {
    run_step btrfs-scrub
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"btrfs scrub installed"* ]]
    assert_fake_called '^sudo install -m 0644 .*/btrfs-scrub\.service /etc/systemd/system/btrfs-scrub\.service$'
    assert_fake_called '^sudo install -m 0644 .*/btrfs-scrub\.timer /etc/systemd/system/btrfs-scrub\.timer$'
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

@test "configure-flatpak keeps going without deleting anything when flathub is not a remote" {
    mark_installed flatpak
    seed_fake_output flatpak <<< "flathub-verified"
    run_step configure-flatpak
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Flatpak configured"* ]]
    refute_fake_called 'remote-delete'
    assert_fake_called '^sudo flatpak remote-add .* flathub-verified '
}

@test "configure-flatpak stops when listing the flatpak remotes fails" {
    mark_installed flatpak
    run_step configure-flatpak FAKE_EXIT_flatpak=1
    assert_step_died "Failed to list flatpak remotes" "Flatpak configured"
    refute_fake_called '^sudo flatpak'
}

@test "configure-flatpak stops when adding the flathub-verified remote fails" {
    mark_installed flatpak
    run_step configure-flatpak FAKE_SUDO_FAIL='^flatpak remote-add .* flathub-verified '
    assert_step_died "Failed to add the flathub-verified flatpak remote" "Flatpak configured"
    refute_fake_called 'flathub-whitelist'
}

@test "configure-flatpak filters the whitelist remote with the filter under HOME" {
    mark_installed flatpak
    run_step configure-flatpak
    [ "${status}" -eq 0 ]
    assert_fake_called "^sudo flatpak remote-add .*--filter=${HOME}/work/personal/credfeto-flatpak-filter/flatpak.filter flathub-whitelist "
    refute_fake_called '/home/markr'
}

@test "configure-flatpak stops before touching any remote when the filter file is missing" {
    mark_installed flatpak
    rm "${HOME}/work/personal/credfeto-flatpak-filter/flatpak.filter"
    run_step configure-flatpak
    assert_step_died "Flatpak filter file ${HOME}/work/personal/credfeto-flatpak-filter/flatpak.filter not found" "Flatpak configured"
    refute_fake_called 'flatpak'
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
    assert_fake_called '^sudo install -m 0644 .*/wifi_rand_mac\.conf /etc/NetworkManager/conf\.d/wifi_rand_mac\.conf$'
    assert_fake_called '^sudo systemctl disable --now dnsmasq$'
    assert_fake_called '^sudo pacman -Rns --noconfirm dnsmasq$'
    assert_fake_called '^sudo systemctl enable --now firewalld$'
    assert_fake_called '^systemctl is-active --quiet NetworkManager\.service$'
    assert_fake_called '^sudo nmcli general reload$'
}

@test "configure-network does not leak the pacman -Qq package name into the output" {
    seed_fake_output pacman <<< "leaked-package-name"
    run_step configure-network
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"leaked-package-name"* ]]
}

@test "configure-network moves NetworkManager onto systemd-resolved before removing dnsmasq" {
    run_step configure-network
    [ "${status}" -eq 0 ]
    local _resolved _dns_conf _reload _disable _remove _firewalld
    _resolved="$(log_line_of '^sudo systemctl enable --now systemd-resolved$')"
    _dns_conf="$(log_line_of '^sudo install -m 0644 .*/dns\.conf /etc/NetworkManager/conf\.d/dns\.conf$')"
    _reload="$(log_line_of '^sudo nmcli general reload$')"
    _disable="$(log_line_of '^sudo systemctl disable --now dnsmasq$')"
    _remove="$(log_line_of '^sudo pacman -Rns --noconfirm dnsmasq$')"
    _firewalld="$(log_line_of '^sudo pacman -S --needed --noconfirm firewalld$')"
    [ "${_resolved}" -lt "${_dns_conf}" ]
    [ "${_dns_conf}" -lt "${_reload}" ]
    [ "${_reload}" -lt "${_disable}" ]
    [ "${_disable}" -lt "${_remove}" ]
    [ "${_remove}" -lt "${_firewalld}" ]
}

@test "configure-network keeps dnsmasq when reloading NetworkManager fails" {
    run_step configure-network FAKE_SUDO_FAIL='^nmcli general reload$'
    assert_step_died "Failed to reload the NetworkManager config" "Network configured"
    refute_fake_called 'disable --now dnsmasq'
    refute_fake_called 'pacman -Rns --noconfirm dnsmasq'
    refute_fake_called 'firewalld'
}

@test "configure-network stops when removing a dnsmasq config fails" {
    run_step configure-network FAKE_SUDO_FAIL='^rm -f /etc/NetworkManager/dnsmasq\.d/00-caching\.conf$'
    assert_step_died "Failed to remove /etc/NetworkManager/dnsmasq.d/00-caching.conf" "Network configured"
    refute_fake_called '01-async-logs\.conf'
}

@test "configure-network stops when copying the MAC randomisation config fails" {
    run_step configure-network FAKE_SUDO_FAIL='^install -m 0644 .*/wifi_rand_mac\.conf '
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
    assert_fake_called '^sudo install -m 0644 .*/connectivity-test\.conf '
}

@test "configure-network skips disabling and removing dnsmasq when it is absent" {
    fake_systemctl_probes
    run_step configure-network FAKE_EXIT_systemctl_is_enabled=1 FAKE_EXIT_pacman=1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Network configured"* ]]
    refute_fake_called 'disable --now dnsmasq'
    refute_fake_called 'pacman -Rns --noconfirm dnsmasq'
    assert_fake_called '^sudo rm -f /etc/NetworkManager/dnsmasq\.d/03-allow-doh\.conf$'
}

@test "configure-network skips the NetworkManager configuration on a systemd-networkd host" {
    fake_systemctl_probes
    run_step configure-network FAKE_EXIT_systemctl_is_active=1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Network configured"* ]]
    [[ "${output}" == *"Skipping the NetworkManager configuration because NetworkManager is not running"* ]]
    refute_fake_called '/etc/NetworkManager'
    refute_fake_called 'nmcli'
    assert_fake_called '^sudo systemctl enable --now systemd-resolved$'
    assert_fake_called '^sudo systemctl disable --now dnsmasq$'
    assert_fake_called '^sudo systemctl enable --now firewalld$'
    assert_fake_called '^sudo firewall-cmd --permanent --add-rich-rule=.*172\.16\.0\.0/20'
}

@test "configure-network still stops when installing firewalld fails on a systemd-networkd host" {
    fake_systemctl_probes
    run_step configure-network FAKE_EXIT_systemctl_is_active=1 FAKE_SUDO_FAIL='^pacman -S .* firewalld$'
    assert_step_died "Failed to install firewalld" "Network configured"
    refute_fake_called 'enable --now firewalld'
}

@test "configure-network reloads firewalld once after adding the permanent rules" {
    run_step configure-network
    [ "${status}" -eq 0 ]
    local _last_rule _reload
    _last_rule="$(log_line_of '^sudo firewall-cmd --permanent --add-rich-rule=.*172\.16\.0\.0/20')"
    _reload="$(log_line_of '^sudo firewall-cmd --reload$')"
    [ -n "${_last_rule}" ]
    [ -n "${_reload}" ]
    [ "${_last_rule}" -lt "${_reload}" ]
    [ "$(grep -c -E '^sudo firewall-cmd --reload$' "${FAKE_BIN_LOG}")" -eq 1 ]
}

@test "configure-network stops when reloading firewalld fails" {
    run_step configure-network FAKE_SUDO_FAIL='^firewall-cmd --reload$'
    assert_step_died "Failed to reload firewalld" "Network configured"
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
    # checkupdates (run by pacman-sync.service) exits 1 without fakeroot, which
    # pacman-contrib only lists as an optional dependency.
    assert_fake_called '^sudo pacman -S --needed --noconfirm fakeroot$'
    assert_fake_called '^sudo systemctl enable --now pacman-sync\.timer$'
}

@test "enable-services stops when installing fakeroot fails and never installs or enables pacman-sync" {
    run_step enable-services FAKE_SUDO_FAIL='^pacman -S --needed --noconfirm fakeroot$'
    assert_step_died "Failed to install fakeroot" "Services enabled"
    refute_fake_called 'pacman-sync'
}

@test "enable-services links the network-online helper pacman-sync.service runs before installing or enabling pacman-sync" {
    run_step enable-services
    [ "${status}" -eq 0 ]
    local _link='^sudo ln -sf '"${REPO_DIR}"'/settings/scripts/linux/network-online /usr/local/bin/network-online$'
    assert_fake_called "${_link}"
    [ "$(log_line_of "${_link}")" -lt "$(log_line_of 'pacman-sync\.service')" ]
    [ "$(log_line_of "${_link}")" -lt "$(log_line_of '^sudo systemctl enable --now pacman-sync\.timer$')" ]
}

@test "enable-services stops when linking the network-online helper fails and never installs or enables pacman-sync" {
    run_step enable-services FAKE_SUDO_FAIL='^ln -sf .* /usr/local/bin/network-online$'
    assert_step_died "Failed to link /usr/local/bin/network-online" "Services enabled"
    refute_fake_called 'pacman-sync'
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
    assert_fake_called '^sudo install -m 0644 .*/ssh\.local /etc/fail2ban/jail\.d/ssh\.local$'
    assert_fake_called '^sudo systemctl enable --now fail2ban$'
}

@test "fail2ban stops when copying the ssh jail fails" {
    run_step fail2ban FAKE_SUDO_FAIL='^install -m 0644 .*/ssh\.local '
    assert_step_died "Failed to copy /etc/fail2ban/jail.d/ssh.local" "fail2ban installed"
    refute_fake_called 'enable --now fail2ban'
}

# The package creates /etc/fail2ban/jail.d, so on a fresh machine the jails
# can only be copied in once it is installed.
@test "fail2ban installs the package before copying its jails, then enables the service" {
    run_step fail2ban
    [ "${status}" -eq 0 ]
    local _expected=(
        "sudo pacman -S --needed --noconfirm fail2ban"
        "sudo install -m 0644 ${REPO_DIR}/settings/fail2ban/default.local /etc/fail2ban/jail.d/default.local"
        "sudo install -m 0644 ${REPO_DIR}/settings/fail2ban/ssh.local /etc/fail2ban/jail.d/ssh.local"
        "sudo systemctl enable --now fail2ban"
    )
    [ "$(cat "${FAKE_BIN_LOG}")" = "$(printf '%s\n' "${_expected[@]}")" ]
}

@test "fail2ban stops when installing the package fails, before copying any jail" {
    run_step fail2ban FAKE_SUDO_FAIL='^pacman -S .*fail2ban$'
    assert_step_died "Failed to install fail2ban" "fail2ban installed"
    refute_fake_called '^sudo install '
    refute_fake_called 'enable --now fail2ban'
}

# ── firejail ─────────────────────────────────────────────────────────────────

@test "firejail installs firejail and deploys the user profiles as 0644, whatever the umask and the mode of a profile already there" {
    # The profiles go under the user's home, so install runs for real here,
    # without sudo, and the modes it leaves can be read back. cp would give
    # a new profile 0640 under this umask and leave the existing one 0600.
    mkdir -p "${HOME}/.config/firejail"
    printf 'stale\n' > "${HOME}/.config/firejail/ssh.local"
    chmod 0600 "${HOME}/.config/firejail/ssh.local"
    umask 027
    run_step firejail
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"firejail installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm firejail$'
    refute_fake_called '^sudo install '
    local _profile
    for _profile in git.local shellcheck.local ssh.local; do
        [ "$(stat -c '%a' "${HOME}/.config/firejail/${_profile}")" = 644 ]
        cmp -s "${REPO_DIR}/settings/firejail/${_profile}" "${HOME}/.config/firejail/${_profile}"
    done
}

@test "firejail deploys exactly its three profiles, each with install -m 0644 to a full target path" {
    local _source="${REPO_DIR}/settings/firejail" _target="${HOME}/.config/firejail"
    setup_fake_bin install
    run_step firejail
    [ "${status}" -eq 0 ]
    [ "$(grep '^install ' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' \
        "install -m 0644 ${_source}/git.local ${_target}/git.local" \
        "install -m 0644 ${_source}/shellcheck.local ${_target}/shellcheck.local" \
        "install -m 0644 ${_source}/ssh.local ${_target}/ssh.local")" ]
    [ "$(ls "${_source}")" = "$(printf '%s\n' git.local shellcheck.local ssh.local)" ]
}

@test "firejail stops, naming the profile, when deploying one fails" {
    setup_fake_bin install
    run_step firejail FAKE_EXIT_install=1
    assert_step_died "Failed to copy ${HOME}/.config/firejail/git.local" "firejail installed"
    [ "$(grep -c '^install ' "${FAKE_BIN_LOG}")" -eq 1 ]
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
    assert_fake_called '^sudo install -m 0644 .*/unprivileged_userns_clone\.conf /etc/sysctl\.d/unprivileged_userns_clone\.conf$'
    assert_fake_called '^sudo install -m 0644 .*/kexec\.conf /etc/sysctl\.d/kexec\.conf$'
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
    assert_fake_called '^sudo install -m 0644 .*/pacman-cache-cleanup\.hook /etc/pacman\.d/hooks/pacman-cache-cleanup\.hook$'
    assert_fake_called '^sudo install -m 0644 .*/spectacle-remove-firejail-wrapper\.hook /etc/pacman\.d/hooks/spectacle-remove-firejail-wrapper\.hook$'
}

@test "pacman-hooks creates the hooks directory with an explicit 0755 mode, before copying into it" {
    run_step pacman-hooks
    [ "${status}" -eq 0 ]
    [ "$(grep '^sudo install ' "${FAKE_BIN_LOG}" | head -n 1)" = "sudo install -d -m 0755 /etc/pacman.d/hooks" ]
    refute_fake_called '^sudo mkdir '
}

@test "pacman-hooks stops when creating the hooks directory fails" {
    run_step pacman-hooks FAKE_SUDO_FAIL='^install -d -m 0755 /etc/pacman\.d/hooks$'
    assert_step_died "Failed to create /etc/pacman.d/hooks" "Pacman hooks installed"
    refute_fake_called '\.hook'
}

@test "pacman-hooks stops when copying a hook fails" {
    run_step pacman-hooks FAKE_SUDO_FAIL='^install -m 0644 .*/pacman-cache-cleanup\.hook '
    assert_step_died "Failed to copy /etc/pacman.d/hooks/pacman-cache-cleanup.hook" "Pacman hooks installed"
    refute_fake_called 'spectacle-remove-firejail-wrapper'
}

@test "pacman-hooks stops when copying the second hook fails" {
    run_step pacman-hooks FAKE_SUDO_FAIL='^install -m 0644 .*/spectacle-remove-firejail-wrapper\.hook '
    assert_step_died "Failed to copy /etc/pacman.d/hooks/spectacle-remove-firejail-wrapper.hook" "Pacman hooks installed"
}

# ── configure-pacman ─────────────────────────────────────────────────────────

@test "configure-pacman enables each missing option" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    printf '[options]\nHoldPkg = pacman glibc\n' > "${_conf}"
    run_step configure-pacman PACMAN_CONF="${_conf}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Pacman configured"* ]]
    assert_fake_called '^sudo sed -i .*ILoveCandy'
    assert_fake_called '^sudo sed -i .*CheckSpace'
    assert_fake_called '^sudo sed -i .*VerbosePkgLists'
}

@test "configure-pacman stops when adding an option fails" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    printf '[options]\nHoldPkg = pacman glibc\n' > "${_conf}"
    run_step configure-pacman PACMAN_CONF="${_conf}" FAKE_SUDO_FAIL='^sed -i .*CheckSpace'
    assert_step_died "Failed to add CheckSpace to ${_conf}" "Pacman configured"
    refute_fake_called 'VerbosePkgLists'
}

@test "configure-pacman stops when uncommenting an option fails" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    printf '[options]\n#ILoveCandy\n' > "${_conf}"
    run_step configure-pacman PACMAN_CONF="${_conf}" FAKE_SUDO_FAIL='^sed -i .*ILoveCandy'
    assert_step_died "Failed to enable ILoveCandy in ${_conf}" "Pacman configured"
    refute_fake_called 'CheckSpace'
}

@test "configure-pacman stops when pacman.conf cannot be read" {
    run_step configure-pacman PACMAN_CONF="${BATS_TEST_TMPDIR}/missing.conf"
    assert_step_died "Failed to read ${BATS_TEST_TMPDIR}/missing.conf" "Pacman configured"
}

# An option made of the characters grep -E and sed read as syntax, so a
# configure-pacman run that used it as anything but literal text would
# change the wrong line or write a different one.
SED_SPECIAL_OPTION='Foo.Bar/&\baz[*]^$'

# Replaces the fake sudo with one that logs the command line and then runs
# it, so the sed edits configure-pacman makes land in the test's own fixture.
fake_sudo_runs_command() {
    replace_fake sudo <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "${FAKE_BIN_LOG}"
exec "$@"
EOF
}

# Writes each argument as a line of the given pacman.conf fixture.
# Usage: write_pacman_conf <file> <line> ...
write_pacman_conf() {
    local _conf="$1"
    shift
    printf '%s\n' "$@" > "${_conf}"
}

# Runs configure-pacman against the given fixture for the given options,
# with sudo running the edits.
# Usage: run_configure_pacman_with <file> <option> ...
run_configure_pacman_with() {
    local _conf="$1"
    shift
    fake_sudo_runs_command
    run env PACMAN_CONF="${_conf}" "${INSTALL_D}/configure-pacman" "$@"
}

@test "configure-pacman uncomments an option holding sed-special characters as literal text" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    write_pacman_conf "${_conf}" '[options]' "#${SED_SPECIAL_OPTION}"
    run_configure_pacman_with "${_conf}" "${SED_SPECIAL_OPTION}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Pacman configured"* ]]
    [ "$(cat "${_conf}")" = "$(printf '%s\n' '[options]' "${SED_SPECIAL_OPTION}")" ]
}

@test "configure-pacman adds an absent option holding sed-special characters as literal text" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    write_pacman_conf "${_conf}" '[options]' 'HoldPkg = pacman glibc'
    run_configure_pacman_with "${_conf}" "${SED_SPECIAL_OPTION}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${_conf}")" = "$(printf '%s\n' '[options]' "${SED_SPECIAL_OPTION}" 'HoldPkg = pacman glibc')" ]
}

@test "configure-pacman keeps the leading whitespace of an option it adds" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    write_pacman_conf "${_conf}" '[options]'
    run_configure_pacman_with "${_conf}" "  ${SED_SPECIAL_OPTION}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${_conf}")" = "$(printf '%s\n' '[options]' "  ${SED_SPECIAL_OPTION}")" ]
}

@test "configure-pacman leaves an already active option holding sed-special characters alone" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    write_pacman_conf "${_conf}" '[options]' "${SED_SPECIAL_OPTION}"
    run_configure_pacman_with "${_conf}" "${SED_SPECIAL_OPTION}"
    [ "${status}" -eq 0 ]
    refute_fake_called '^sudo '
    [ "$(cat "${_conf}")" = "$(printf '%s\n' '[options]' "${SED_SPECIAL_OPTION}")" ]
}

@test "configure-pacman matches an option only as literal text, never a line its characters would match as a pattern" {
    local _conf="${BATS_TEST_TMPDIR}/pacman.conf"
    write_pacman_conf "${_conf}" '[options]' 'FooXBar' '#FooXBar' '#Foo.Bar'
    run_configure_pacman_with "${_conf}" 'Foo.Bar'
    [ "${status}" -eq 0 ]
    [ "$(cat "${_conf}")" = "$(printf '%s\n' '[options]' 'FooXBar' '#FooXBar' 'Foo.Bar')" ]
}

# ── remove-aur-helpers ───────────────────────────────────────────────────────

@test "remove-aur-helpers removes yay and paru when both are installed" {
    run_step remove-aur-helpers
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AUR helpers removed"* ]]
    assert_fake_called '^sudo pacman -Rns --noconfirm yay$'
    assert_fake_called '^sudo pacman -Rns --noconfirm paru$'
}

@test "remove-aur-helpers does not leak the pacman -Qq package name into the output" {
    seed_fake_output pacman <<< "leaked-package-name"
    run_step remove-aur-helpers
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"leaked-package-name"* ]]
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
        "sudo install -m 0640 ${REPO_DIR}/settings/audit/rules/00_passwd.rules /etc/audit/rules.d/00_passwd.rules" \
        "sudo install -m 0640 ${REPO_DIR}/settings/audit/rules/01_security.rules /etc/audit/rules.d/01_security.rules" \
        "sudo install -m 0640 ${REPO_DIR}/settings/audit/rules/02_audit-config.rules /etc/audit/rules.d/02_audit-config.rules" \
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

@test "shell-environment installs the shared and bash-only shell config" {
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

@test "shell-environment stops when installing a bash.bashrc.d script fails" {
    run_step shell-environment FAKE_SUDO_FAIL='^install -m 0644 .* /etc/bash\.bashrc\.d/00_shell-options\.sh$'
    assert_step_died "Failed to install /etc/bash.bashrc.d/00_shell-options.sh" "Shell environment installed"
    refute_fake_called '/etc/bash\.bashrc\.d/05_ls-grep-colors\.sh'
    refute_fake_called '^sudo tee '
}

# ── shell-prompt ─────────────────────────────────────────────────────────────

@test "shell-prompt installs starship and deploys its theme" {
    run_step shell-prompt
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Starship prompt installed"* ]]
    assert_fake_called '^sudo pacman -S --needed --noconfirm starship$'
    assert_fake_called '^sudo install -m 0644 .*/starship\.toml /etc/starship\.toml$'
}

@test "shell-prompt stops when copying the starship theme fails" {
    run_step shell-prompt FAKE_SUDO_FAIL='^install -m 0644 .*/starship\.toml '
    assert_step_died "Failed to copy /etc/starship.toml" "Starship prompt installed"
    refute_fake_called 'bash\.bashrc'
}

STARSHIP_BEGIN='# BEGIN credfeto-systemd starship'
STARSHIP_END='# END credfeto-systemd starship'

# Replaces sudo with one that logs every command line as the fake sudo does,
# and runs the command only when its last argument is the step's own
# bash.bashrc (SHELL_PROMPT_BASHRC, as the step is run with it), so a test
# can read back what the step wrote there. Everything else it only logs.
fake_sudo_writing_bashrc() {
    replace_fake sudo <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "${FAKE_BIN_LOG}"
for _last; do :; done
if [ -n "${SHELL_PROMPT_BASHRC:-}" ] && [ "${_last}" = "${SHELL_PROMPT_BASHRC}" ]; then
    exec "$@"
fi
exit 0
EOF
}

# Runs shell-prompt against the given bash.bashrc, letting it write the file,
# under a restrictive umask so the mode it leaves is the one it set.
# Usage: run_shell_prompt_on <bashrc>
run_shell_prompt_on() {
    fake_sudo_writing_bashrc
    # shellcheck disable=SC2016
    run env SHELL_PROMPT_BASHRC="$1" sh -c 'umask 027; exec "$1"' _ "${INSTALL_D}/shell-prompt"
}

# Prints the Starship block the step writes, taken from a run on an empty
# bash.bashrc.
starship_block() {
    local _bashrc="${BATS_TEST_TMPDIR}/block-only.bashrc"
    : > "${_bashrc}"
    fake_sudo_writing_bashrc
    SHELL_PROMPT_BASHRC="${_bashrc}" "${INSTALL_D}/shell-prompt" > /dev/null || return 1
    cat "${_bashrc}"
}

# Asserts the given file holds exactly one BEGIN and one END marker line.
# Usage: assert_one_starship_block <bashrc>
assert_one_starship_block() {
    [ "$(grep -cxF "${STARSHIP_BEGIN}" "$1")" -eq 1 ] || return 1
    [ "$(grep -cxF "${STARSHIP_END}" "$1")" -eq 1 ]
}

@test "shell-prompt appends the Starship block once to a bash.bashrc that has none, leaving it world-readable" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc"
    printf '%s\n' '# distro defaults' 'shopt -s checkwinsize' > "${_bashrc}"
    # Another mode first, so 0644 afterwards is the one the step set.
    chmod 0600 "${_bashrc}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Starship prompt installed"* ]]
    assert_one_starship_block "${_bashrc}"
    [ "$(head -n 2 "${_bashrc}")" = "$(printf '%s\n' '# distro defaults' 'shopt -s checkwinsize')" ]
    [ "$(tail -n 1 "${_bashrc}")" = "${STARSHIP_END}" ]
    [ "$(stat -c '%a' "${_bashrc}")" = 644 ]
    assert_fake_called "^sudo install -m 0644 [^ ]+ ${_bashrc}$"
}

@test "shell-prompt replaces a stale Starship block in place, keeping everything around it" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc" _block
    _block="$(starship_block)"
    printf '%s\n' '# before' "${STARSHIP_BEGIN}" 'export STALE=1' "${STARSHIP_END}" '# after' > "${_bashrc}"
    chmod 0600 "${_bashrc}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Starship prompt installed"* ]]
    assert_one_starship_block "${_bashrc}"
    [ "$(cat "${_bashrc}")" = "$(printf '%s\n%s\n%s' '# before' "${_block}" '# after')" ]
    [ "$(stat -c '%a' "${_bashrc}")" = 644 ]
}

@test "shell-prompt leaves a bash.bashrc whose Starship block is already current untouched" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc" _before
    printf '%s\n' '# before' > "${_bashrc}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    printf '%s\n' '# after' >> "${_bashrc}"
    _before="$(cat "${_bashrc}")"
    : > "${FAKE_BIN_LOG}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"up to date, skipping"* ]]
    [[ "${output}" == *"Starship prompt installed"* ]]
    [ "$(cat "${_bashrc}")" = "${_before}" ]
    refute_fake_called "${_bashrc}$"
}

@test "shell-prompt stops without touching a bash.bashrc whose Starship markers are unpaired or repeated" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc" _before _case
    for _case in begin-only end-only end-first two-blocks; do
        case "${_case}" in
            begin-only) printf '%s\n' '# before' "${STARSHIP_BEGIN}" 'export STALE=1' '# after' > "${_bashrc}" ;;
            end-only) printf '%s\n' '# before' 'export STALE=1' "${STARSHIP_END}" '# after' > "${_bashrc}" ;;
            end-first) printf '%s\n' "${STARSHIP_END}" '# between' "${STARSHIP_BEGIN}" > "${_bashrc}" ;;
            two-blocks) printf '%s\n' "${STARSHIP_BEGIN}" "${STARSHIP_END}" "${STARSHIP_BEGIN}" "${STARSHIP_END}" > "${_bashrc}" ;;
        esac
        _before="$(cat "${_bashrc}")"
        : > "${FAKE_BIN_LOG}"
        run_shell_prompt_on "${_bashrc}"
        assert_step_died "unpaired or repeated Starship BEGIN/END marker" "Starship prompt installed"
        [ "$(cat "${_bashrc}")" = "${_before}" ]
        refute_fake_called "${_bashrc}$"
    done
}

@test "shell-prompt stops when writing the Starship block fails" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc"
    : > "${_bashrc}"
    run_step shell-prompt SHELL_PROMPT_BASHRC="${_bashrc}" FAKE_SUDO_FAIL="^install -m 0644 [^ ]+ ${_bashrc}$"
    assert_step_died "Failed to write the Starship block to ${_bashrc}" "Starship prompt installed"
}

# Sources the given bash.bashrc in a non-interactive bash whose PATH starts
# with the fakes, with HOME in the test's directory, then prints
# STARSHIP_CONFIG and the two names the block uses for itself. Leading
# VAR=value arguments are set in the shell's environment.
# Usage: run_starship_block <bashrc> [<VAR=value> ...]
run_starship_block() {
    local _bashrc="$1"
    shift
    # shellcheck disable=SC2016
    run env -u XDG_CONFIG_HOME -u STARSHIP_CONFIG -u _STARSHIP_DEFAULTED \
        HOME="${BATS_TEST_TMPDIR}/shell-home" PATH="${FAKE_BIN_DIR}:/usr/bin:/bin" "$@" \
        bash --norc --noprofile -c '. "$1"; printf "%s\n" "${STARSHIP_CONFIG-unset}" "${_starship_home-unset}" "${_starship_config_dir-unset}"' _ "${_bashrc}"
}

@test "the Starship block starts no id or cut, and runs getent only when XDG_CONFIG_HOME is unset" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc" _passwd_home="${BATS_TEST_TMPDIR}/passwd-home" _uid
    : > "${_bashrc}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    _uid="$(id -u)"
    setup_fake_bin id cut getent starship
    printf 'someone:x:%s:%s:Some One:%s:/bin/bash\n' "${_uid}" "${_uid}" "${_passwd_home}" | seed_fake_output getent
    mkdir -p "${BATS_TEST_TMPDIR}/shell-home" "${_passwd_home}/.config"

    # The home getent gives, not HOME, holds the user's own config.
    : > "${_passwd_home}/.config/starship.toml"
    run_starship_block "${_bashrc}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' unset unset unset)" ]
    [ "$(cat "${FAKE_BIN_LOG}")" = "$(printf '%s\n' "getent passwd ${_uid}" 'starship init bash')" ]

    # No config there: the system default.
    rm "${_passwd_home}/.config/starship.toml"
    : > "${FAKE_BIN_LOG}"
    run_starship_block "${_bashrc}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = /etc/starship.toml ]
    refute_fake_called '^(id|cut) '

    # XDG_CONFIG_HOME answers it without getent.
    mkdir -p "${BATS_TEST_TMPDIR}/xdg"
    : > "${BATS_TEST_TMPDIR}/xdg/starship.toml"
    : > "${FAKE_BIN_LOG}"
    run_starship_block "${_bashrc}" XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/xdg"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' unset unset unset)" ]
    [ "$(cat "${FAKE_BIN_LOG}")" = 'starship init bash' ]

    # A STARSHIP_CONFIG set upstream is kept without looking anything up.
    : > "${FAKE_BIN_LOG}"
    run_starship_block "${_bashrc}" STARSHIP_CONFIG=/upstream.toml
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = /upstream.toml ]
    [ "$(cat "${FAKE_BIN_LOG}")" = 'starship init bash' ]
}

@test "the Starship block falls back to HOME when getent does not know the user" {
    local _bashrc="${BATS_TEST_TMPDIR}/bash.bashrc"
    : > "${_bashrc}"
    run_shell_prompt_on "${_bashrc}"
    [ "${status}" -eq 0 ]
    setup_fake_bin getent starship
    mkdir -p "${BATS_TEST_TMPDIR}/shell-home/.config"
    : > "${BATS_TEST_TMPDIR}/shell-home/.config/starship.toml"
    run_starship_block "${_bashrc}" FAKE_EXIT_getent=2
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' unset unset unset)" ]
    rm "${BATS_TEST_TMPDIR}/shell-home/.config/starship.toml"
    run_starship_block "${_bashrc}" FAKE_EXIT_getent=2
    [ "${lines[0]}" = /etc/starship.toml ]
}

@test "shell-prompt stops when installing starship fails" {
    run_step shell-prompt FAKE_SUDO_FAIL='^pacman -S --needed --noconfirm starship$'
    assert_step_died "Failed to install starship" "Starship prompt installed"
    refute_fake_called 'starship\.toml'
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
        _expected+=("sudo install -m 0644 ${_conf} ${SSHD_TARGET_DIR}/$(basename "${_conf}")")
    done
    [ "${#_expected[@]}" -gt 0 ]
    [ "$(grep '^sudo install ' "${FAKE_BIN_LOG}")" = "$(printf '%s\n' "${_expected[@]}")" ]
}

@test "harden-ssh stops at a failed copy, naming its target, and copies nothing after it" {
    run_step harden-ssh FAKE_SUDO_FAIL='^install -m 0644 .*/07_X11Forwarding\.conf '
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to copy ${SSHD_TARGET_DIR}/07_X11Forwarding.conf"* ]]
    [[ "${output}" != *"SSH hardened"* ]]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo install -m 0644 ${SSHD_SOURCE_DIR}/07_X11Forwarding.conf ${SSHD_TARGET_DIR}/07_X11Forwarding.conf" ]
}

# Copies harden-ssh, lib/common and settings/sshd into a checkout-shaped tree
# under the test dir, a git repo with everything in it tracked, as harden-ssh
# deploys only tracked drop-ins; a file a test adds afterwards stays
# untracked. Prints the tree's root.
setup_harden_ssh_tree() {
    local _root="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "${_root}/install.d" "${_root}/lib" "${_root}/settings"
    cp "${INSTALL_D}/harden-ssh" "${_root}/install.d/"
    cp "${REPO_DIR}/lib/common" "${_root}/lib/"
    cp -r "${SSHD_SOURCE_DIR}" "${_root}/settings/"
    git init --quiet "${_root}"
    git -C "${_root}" add -A
    printf '%s\n' "${_root}"
}

@test "harden-ssh deploys only tracked drop-ins, leaving out an untracked one beside them" {
    local _root
    _root="$(setup_harden_ssh_tree)"
    printf 'PermitRootLogin yes\n' > "${_root}/settings/sshd/99_untracked.conf"
    run "${_root}/install.d/harden-ssh"
    [ "${status}" -eq 0 ]
    assert_fake_called "^sudo install -m 0644 ${_root}/settings/sshd/13_TCPKeepAlive\\.conf ${SSHD_TARGET_DIR}/13_TCPKeepAlive\\.conf\$"
    refute_fake_called '99_untracked\.conf'
}

@test "harden-ssh dies, deploying nothing, when its tree is not a checkout but sits inside another repo" {
    local _root
    _root="$(setup_harden_ssh_tree)"
    rm -rf "${_root}/.git"
    # An enclosing repo that tracks the whole tree, as a dotfiles repo in
    # $HOME might; listing through it would deploy what it tracks.
    git init --quiet "${BATS_TEST_TMPDIR}"
    git -C "${BATS_TEST_TMPDIR}" add "${_root}"
    run "${_root}/install.d/harden-ssh"
    assert_step_died "${_root} is not a git checkout; run install from a git clone of this repository" "SSH hardened"
    [[ "${output}" != *"Failed to list"* ]]
    refute_fake_called '^sudo install '
}

@test "harden-ssh skips a tracked symlink, warning, and never deploys what it points at" {
    local _root
    _root="$(setup_harden_ssh_tree)"
    printf 'PermitRootLogin yes\n' > "${BATS_TEST_TMPDIR}/private.conf"
    ln -s "${BATS_TEST_TMPDIR}/private.conf" "${_root}/settings/sshd/99_link.conf"
    git -C "${_root}" add settings/sshd/99_link.conf
    run "${_root}/install.d/harden-ssh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Not deploying ${_root}/settings/sshd/99_link.conf: it is a symlink"* ]]
    refute_fake_called '99_link\.conf'
    assert_fake_called "^sudo install -m 0644 ${_root}/settings/sshd/13_TCPKeepAlive\\.conf "
}

@test "harden-ssh fails when the sshd drop-ins cannot be listed" {
    local _root
    _root="$(setup_harden_ssh_tree)"
    fail_git_for ' ls-files -- '
    run "${_root}/install.d/harden-ssh"
    assert_step_died "Failed to list the sshd drop-ins in ${_root}/settings/sshd" "SSH hardened"
    refute_fake_called '^sudo install '
}

@test "harden-ssh fails when settings/sshd holds no tracked drop-in" {
    local _root
    _root="$(setup_harden_ssh_tree)"
    rm "${_root}/settings/sshd"/*.conf
    run "${_root}/install.d/harden-ssh"
    assert_step_died "No sshd drop-ins found in ${_root}/settings/sshd" "SSH hardened"
    refute_fake_called '^sudo install '
}

@test "harden-ssh stops when installing curl fails and never renders the key server config" {
    run_step harden-ssh FAKE_SUDO_FAIL='^pacman -S '
    assert_step_died "Failed to install curl" "SSH hardened"
    assert_fake_called '^sudo install -m 0644 .*/13_TCPKeepAlive\.conf '
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

@test "harden-ssh sets the key server config to an explicit 0644 mode after writing it" {
    run_step harden-ssh
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo chmod 0644 ${SSHD_TARGET_DIR}/14_KeyServer.conf" ]
}

@test "harden-ssh stops when setting the key server config mode fails" {
    run_step harden-ssh FAKE_SUDO_FAIL='^chmod 0644 /etc/ssh/sshd_config\.d/14_KeyServer\.conf$'
    assert_step_died "Failed to set the mode of ${SSHD_TARGET_DIR}/14_KeyServer.conf" "SSH hardened"
}

@test "harden-ssh stops when writing the key server config fails" {
    run_step harden-ssh FAKE_SUDO_FAIL='^tee /etc/ssh/sshd_config\.d/14_KeyServer\.conf$'
    assert_step_died "Failed to write ${SSHD_TARGET_DIR}/14_KeyServer.conf" "SSH hardened"
    [ "$(tail -n 1 "${FAKE_BIN_LOG}")" = "sudo tee ${SSHD_TARGET_DIR}/14_KeyServer.conf" ]
}
