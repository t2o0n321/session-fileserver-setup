#!/usr/bin/env bash
#
# UFW.  The previous installer ran `ufw allow 'Nginx Full'` but never enabled
# ufw (so nothing was enforced) and never allowed SSH (so an operator who later
# enabled ufw would lock themselves out).  Enabling a firewall is a
# lock-yourself-out risk, so this step is opt-in via --firewall and always
# allows the current SSH session first.

step_firewall() {
    if [[ "${CONFIGURE_FIREWALL}" != "1" ]]; then
        skipped "Firewall not configured (pass --firewall to enable UFW)"
        return 0
    fi
    if ! cmd_exists ufw; then
        notice "ufw not installed; skipping firewall configuration."
        return 0
    fi

    # Allow SSH *before* enabling, so we cannot cut off the operator. Detect the
    # port without assuming sshd is installed or on PATH (that failure must not
    # abort the run), falling back to the active session's port, then 22.
    local ssh_port=""
    if cmd_exists sshd; then
        ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    fi
    if [[ -z "${ssh_port}" && -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}" || true)"
    fi
    [[ -n "${ssh_port}" ]] || ssh_port=22
    # Also allow the named profile in case sshd listens on multiple ports.
    run ufw allow OpenSSH >/dev/null 2>&1 || true
    run ufw allow "${ssh_port}/tcp" || die "Could not add the SSH firewall rule."
    ok "Allowed SSH on ${ssh_port}/tcp"

    run ufw allow 'Nginx Full' || die "Could not add the Nginx firewall rule."
    ok "Allowed HTTP/HTTPS (Nginx Full)"

    if unit_active ufw || ufw status 2>/dev/null | grep -q 'Status: active'; then
        run ufw reload || true
        skipped "UFW already active"
    else
        if confirm "Enable UFW now? SSH (${ssh_port}) and HTTP/HTTPS are allowed."; then
            run ufw --force enable || die "Could not enable UFW."
            ok "UFW enabled"
        else
            notice "Left UFW disabled. Rules are staged; enable later with 'ufw enable'."
        fi
    fi
}
