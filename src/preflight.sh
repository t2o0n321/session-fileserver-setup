#!/usr/bin/env bash
#
# Everything that must be true *before* the installer changes anything.  Failing
# here costs the operator nothing; failing halfway through step 5 costs them a
# half-configured server.

# Populated by detect_os().
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        printf 'This installer must run as root:\n\n    sudo ./setup.sh --domain <fqdn>\n\n' >&2
        exit 1
    fi
}

# Reads /etc/os-release rather than shelling out to lsb_release, which is not
# installed on minimal Ubuntu images -- and the old script used it *before*
# installing anything, so the repository line silently became "deb ... main".
detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."
    # shellcheck disable=SC1091
    OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
    OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    OS_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    [[ -n "${OS_CODENAME}" ]] || die "/etc/os-release has no VERSION_CODENAME; cannot pick an apt suite."
}

_check_os_supported() {
    if [[ "${OS_ID}" != "ubuntu" ]]; then
        if [[ "${ALLOW_UNSUPPORTED_OS}" == "1" ]]; then
            notice "OS is '${OS_ID}', not Ubuntu -- continuing because --allow-unsupported-os was given."
        else
            die "This installer targets Ubuntu Server; detected '${OS_ID}'. Re-run with --allow-unsupported-os to override."
        fi
    fi
    if [[ " ${SUPPORTED_UBUNTU_CODENAMES} " == *" ${OS_CODENAME} "* ]]; then
        ok "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME})"
    elif [[ "${ALLOW_UNSUPPORTED_OS}" == "1" ]]; then
        notice "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) is untested -- continuing because --allow-unsupported-os was given."
    else
        die "Ubuntu ${OS_VERSION_ID} (${OS_CODENAME}) is untested by this installer (tested: ${SUPPORTED_UBUNTU_CODENAMES}). Re-run with --allow-unsupported-os to override."
    fi
}

_check_arch() {
    local arch
    arch="$(dpkg --print-architecture)"
    case "${arch}" in
        amd64 | arm64) ok "Architecture ${arch}" ;;
        *) die "deb.oxen.io publishes python3-session-util for amd64/arm64 only; this host is ${arch}." ;;
    esac
}

_check_systemd() {
    [[ -d /run/systemd/system ]] || die "systemd is not the init system; this installer manages a systemd unit."
    cmd_exists systemctl || die "systemctl not found."
    ok "systemd available"
}

_check_disk() {
    local mib
    mib="$(free_mib "${STATE_DIR}")"
    if [[ -z "${mib}" ]]; then
        notice "Could not determine free space for ${STATE_DIR}."
    elif (( mib < 2048 )); then
        die "Only ${mib} MiB free on the filesystem holding ${STATE_DIR}; uploads need room. Free at least 2 GiB."
    else
        ok "Disk space: ${mib} MiB free for ${STATE_DIR}"
    fi
}

# Port 80/443 held by something that is not nginx means certbot and the site
# will both fail in confusing ways, so say so now.
_check_ports() {
    if ! cmd_exists ss; then
        notice "iproute2 'ss' unavailable; skipping port checks."
        return 0
    fi
    local port
    for port in 80 443; do
        if port_in_use "${port}"; then
            if pkg_installed nginx; then
                ok "Port ${port} in use (nginx already installed -- assumed to be ours)"
            else
                die "Port ${port} is already in use by another service. Stop it before deploying."
            fi
        else
            ok "Port ${port} free"
        fi
    done
}

# The domain must reach *this* host or clients will never arrive, and certbot's
# HTTP-01 challenge will fail.  Opt out with --skip-dns-check for split-horizon
# DNS or a proxy in front.
_check_dns() {
    if [[ "${SKIP_DNS_CHECK}" == "1" ]]; then
        notice "Skipping DNS verification for ${DOMAIN} (--skip-dns-check)."
        return 0
    fi

    local resolved
    resolved="$(resolve_ips "${DOMAIN}")"
    if [[ -z "${resolved}" ]]; then
        die "${DOMAIN} does not resolve. Point an A/AAAA record at this server, or pass --skip-dns-check."
    fi

    local candidates ip
    candidates="$(local_ips)"$'\n'"$(public_ip)"
    for ip in ${resolved}; do
        if grep -qxF -- "${ip}" <<<"${candidates}"; then
            ok "${DOMAIN} resolves to ${ip}, which is this host"
            return 0
        fi
    done

    log_warn "Resolved: $(tr '\n' ' ' <<<"${resolved}")"
    log_warn "This host: $(tr '\n' ' ' <<<"${candidates}")"
    die "${DOMAIN} does not resolve to this host. Fix DNS, or pass --skip-dns-check if a proxy sits in front."
}

_check_tls_options() {
    case "${TLS_MODE}" in
        certbot)
            if [[ "${SKIP_DNS_CHECK}" == "1" ]]; then
                notice "--tls certbot with --skip-dns-check: the HTTP-01 challenge still needs public DNS and port 80."
            fi
            [[ -n "${CERTBOT_EMAIL}" ]] || notice "No --email given; certbot will register without a recovery contact."
            ;;
        existing)
            [[ -n "${TLS_CERT_PATH}" && -n "${TLS_KEY_PATH}" ]] || die "--tls existing requires both --cert and --key."
            [[ -r "${TLS_CERT_PATH}" ]] || die "Certificate not readable: ${TLS_CERT_PATH}"
            [[ -r "${TLS_KEY_PATH}" ]]  || die "Private key not readable: ${TLS_KEY_PATH}"
            ok "Using existing certificate ${TLS_CERT_PATH}"
            ;;
        self-signed)
            notice "--tls self-signed is for testing. Session clients reach this server through an exit service node, which may reject an untrusted certificate."
            ;;
        none)
            notice "--tls none serves plain HTTP. This fork's client derives its URL from DEFAULT_FILE_SERVER_URL; an http:// file server means attachment traffic is not TLS-protected on the last hop."
            ;;
        *) die "Unknown --tls mode '${TLS_MODE}' (expected: certbot, self-signed, existing, none)." ;;
    esac
}

# Re-running the installer is a supported operation; say what will be reused so
# the operator is not surprised by "already exists" messages later.
_report_existing_install() {
    local found=0
    [[ -d "${CODE_DIR}/.git" ]] && { skipped "Existing checkout at ${CODE_DIR} will be updated"; found=1; }
    user_exists "${SERVICE_USER}" && { skipped "Service account '${SERVICE_USER}' exists"; found=1; }
    [[ -f "${SERVER_KEY_FILE}" ]] && { skipped "Server key exists and will be preserved"; found=1; }
    if [[ "${found}" == "0" ]]; then
        ok "Fresh installation"
    fi
}

preflight() {
    detect_os
    _check_os_supported
    _check_arch
    _check_systemd
    _check_disk
    _check_ports
    _check_dns
    _check_tls_options
    _report_existing_install
}
