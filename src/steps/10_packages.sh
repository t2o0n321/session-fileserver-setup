#!/usr/bin/env bash
#
# APT: bootstrap the tools needed to add a repository, register deb.oxen.io with
# a scoped keyring, then install the runtime packages.

readonly APT_ENV=(env DEBIAN_FRONTEND=noninteractive)

# apt 3.x prints "WARNING: apt does not have a stable CLI interface. Use with
# caution in scripts." for every invocation -- apt-get is the scriptable one.
_apt_get() { run "${APT_ENV[@]}" apt-get -y -o Dpkg::Use-Pty=0 "$@"; }

_apt_update() { _apt_get update || die "apt-get update failed."; }

# The bare minimum required to fetch and verify a repository key.  A minimal
# Ubuntu image has neither curl nor gnupg, and the previous installer called
# curl before installing anything.
_bootstrap_apt_tools() {
    local missing=()
    local pkg
    for pkg in ca-certificates curl gnupg; do
        pkg_installed "${pkg}" || missing+=("${pkg}")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        skipped "Bootstrap tools present (ca-certificates, curl, gnupg)"
        return 0
    fi
    _apt_update
    _apt_get install "${missing[@]}" || die "Could not install bootstrap tools: ${missing[*]}"
    ok "Installed bootstrap tools: ${missing[*]}"
}

# deb.oxen.io does not publish every Ubuntu codename on release day, so probe
# before writing a suite that would make every later apt run fail.
_oxen_suite() {
    local suite="${OS_CODENAME}"
    if curl -fsS --head --max-time 15 "https://deb.oxen.io/dists/${suite}/Release" >/dev/null 2>&1; then
        printf '%s' "${suite}"
        return 0
    fi
    log_warn "deb.oxen.io has no '${suite}' suite; falling back to '${OXEN_SUITE_FALLBACK}'."
    printf '%s' "${OXEN_SUITE_FALLBACK}"
}

# Installs the key into its own keyring and binds it to this one repository with
# Signed-By.  Dropping it into /etc/apt/trusted.gpg.d (what the previous version
# did) makes that key a valid signer for *every* configured repository.
_install_oxen_key() {
    local tmp
    if [[ -s "${OXEN_KEYRING}" ]] \
        && gpg --show-keys --with-colons "${OXEN_KEYRING}" 2>/dev/null | grep -q "^fpr:::::::::${OXEN_KEY_FINGERPRINT}:"; then
        skipped "Oxen signing key already installed"
        return 0
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    %s[dry-run]%s download and verify %s into %s\n' \
            "${C_DIM}" "${C_RESET}" "${OXEN_KEY_URL}" "${OXEN_KEYRING}"
        return 0
    fi

    tmp="$(mktemp)" || die "Cannot create temp file for the Oxen key."
    curl -fsS --max-time 30 -o "${tmp}" "${OXEN_KEY_URL}" \
        || die "Could not download the Oxen signing key from ${OXEN_KEY_URL}"

    # Fail closed if the served key is not the one this installer trusts.
    if ! gpg --show-keys --with-colons "${tmp}" 2>/dev/null | grep -q "^fpr:::::::::${OXEN_KEY_FINGERPRINT}:"; then
        rm -f -- "${tmp}"
        die "Oxen key fingerprint mismatch: ${OXEN_KEY_URL} is not ${OXEN_KEY_FINGERPRINT}. Refusing to trust it."
    fi

    mkdir -p -- "$(dirname -- "${OXEN_KEYRING}")" || die "Cannot create /etc/apt/keyrings"
    install -m 0644 -o root -g root -- "${tmp}" "${OXEN_KEYRING}" \
        || die "Cannot install ${OXEN_KEYRING}"
    rm -f -- "${tmp}"
    ok "Installed Oxen signing key (${OXEN_KEY_FINGERPRINT})"
}

_configure_oxen_repo() {
    local suite
    suite="$(_oxen_suite)"

    write_file "${OXEN_SOURCES_FILE}" 0644 root:root <<EOF
# Managed by session-fileserver-setup. Supplies python3-session-util, which the
# file server needs for Session's blinded-ID version-check endpoint.
Types: deb
URIs: https://deb.oxen.io
Suites: ${suite}
Components: main
Signed-By: ${OXEN_KEYRING}
EOF

    # An older install may have left the globally-trusted key and one-line list.
    if [[ -e /etc/apt/trusted.gpg.d/oxen.gpg ]]; then
        run rm -f /etc/apt/trusted.gpg.d/oxen.gpg
        notice "Removed the legacy globally-trusted key /etc/apt/trusted.gpg.d/oxen.gpg"
    fi
    if [[ -e /etc/apt/sources.list.d/oxen.list ]]; then
        run rm -f /etc/apt/sources.list.d/oxen.list
        notice "Removed the legacy /etc/apt/sources.list.d/oxen.list"
    fi

    if [[ "${FILE_CHANGED}" == "1" ]]; then
        ok "Configured deb.oxen.io (suite: ${suite})"
    else
        skipped "deb.oxen.io already configured (suite: ${suite})"
    fi
}

_install_packages() {
    local -a wanted=("${APT_PACKAGES[@]}")
    if [[ "${TLS_MODE}" == "certbot" ]]; then
        wanted+=("${APT_PACKAGES_CERTBOT[@]}")
    fi

    local -a missing=()
    local pkg
    for pkg in "${wanted[@]}"; do
        pkg_installed "${pkg}" || missing+=("${pkg}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        skipped "All ${#wanted[@]} packages already installed"
        return 0
    fi

    log_info "Installing: ${missing[*]}"
    _apt_get install "${missing[@]}" \
        || die "Package installation failed. Missing packages: ${missing[*]}"
    ok "Installed ${#missing[@]} package(s)"
}

# A full `apt upgrade` is intentionally *not* part of a deployment run: it can
# restart unrelated services and take an unbounded amount of time.  Opt in.
_upgrade_system() {
    if [[ "${UPGRADE_SYSTEM}" != "1" ]]; then
        return 0
    fi
    _apt_get upgrade || die "apt-get upgrade failed."
    ok "System packages upgraded"
}

step_packages() {
    _bootstrap_apt_tools
    _install_oxen_key
    _configure_oxen_repo
    _apt_update
    _upgrade_system
    _install_packages
}
