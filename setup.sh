#!/usr/bin/env bash
#
# Session file server installer for Ubuntu Server.
#
# Deploys github.com/session-foundation/session-file-server behind nginx+TLS,
# supervised by systemd, and hands back the two values this fork's Android client
# needs (endpoint URL + Ed25519 public key).  Safe to re-run: every step is
# idempotent.  See README.md for the design and ./setup.sh --help for options.

set -Eeuo pipefail

# --------------------------------------------------------------------------
# Locate ourselves and load the library.  SCRIPT_DIR is resolved from this
# file, so the installer works regardless of the caller's working directory.
# --------------------------------------------------------------------------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -h "${SCRIPT_SOURCE}" ]]; do
    dir="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${dir}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
readonly SCRIPT_DIR
readonly SRC_DIR="${SCRIPT_DIR}/src"

# Order matters: config defines constants, log/ui define output, util depends on
# both, preflight and the steps depend on all of the above.
# shellcheck source=src/lib/config.sh
source "${SRC_DIR}/lib/config.sh"
# shellcheck source=src/lib/log.sh
source "${SRC_DIR}/lib/log.sh"
# shellcheck source=src/lib/ui.sh
source "${SRC_DIR}/lib/ui.sh"
# shellcheck source=src/lib/util.sh
source "${SRC_DIR}/lib/util.sh"
# shellcheck source=src/preflight.sh
source "${SRC_DIR}/preflight.sh"
for _step in "${SRC_DIR}"/steps/*.sh; do
    # shellcheck disable=SC1090
    source "${_step}"
done
# shellcheck source=src/uninstall.sh
source "${SRC_DIR}/uninstall.sh"
# shellcheck source=src/tf_vultr.sh
source "${SRC_DIR}/tf_vultr.sh"

# --------------------------------------------------------------------------
# Options (defaults from config.sh)
# --------------------------------------------------------------------------
DOMAIN=""
TLS_MODE="${DEFAULT_TLS_MODE}"
TLS_CERT_PATH=""
TLS_KEY_PATH=""
CERTBOT_EMAIL=""
UPSTREAM_REF="${UPSTREAM_DEFAULT_REF}"
MAX_FILE_SIZE="${DEFAULT_MAX_FILE_SIZE}"
UWSGI_PROCESSES="${DEFAULT_UWSGI_PROCESSES}"

# shellcheck disable=SC2034  # consumed by the dynamically-sourced src/steps/*.sh
DRY_RUN=0
ASSUME_YES=0
UPGRADE_SYSTEM=0
CONFIGURE_FIREWALL=0
SKIP_DNS_CHECK=0
SKIP_SELFTEST=0
ALLOW_UNSUPPORTED_OS=0
DO_UNINSTALL=0
PURGE=0

# Local Terraform/Vultr launcher mode (runs on the developer's machine).
TF_VULTR=0
VULTR_API_KEY_ARG=""

usage() {
    cat <<EOF
Session file server installer ${INSTALLER_VERSION}

USAGE
    sudo ./setup.sh --domain <fqdn> [options]
    sudo ./setup.sh --uninstall [--purge]

REQUIRED
    -d, --domain <fqdn>      Domain the server answers on and the client points at.

TLS (default: ${DEFAULT_TLS_MODE})
        --tls <mode>         certbot | existing | self-signed | none
        --email <addr>       Contact address for Let's Encrypt (--tls certbot).
        --cert <path>        Certificate chain (--tls existing).
        --key <path>         Private key (--tls existing).

DEPLOYMENT
        --ref <git-ref>      Upstream commit/tag/branch to deploy
                             (default: pinned ${UPSTREAM_DEFAULT_REF:0:12}).
        --max-file-size <n>  Max upload in bytes (default: ${DEFAULT_MAX_FILE_SIZE}).
        --processes <n>      uWSGI worker processes (default: ${DEFAULT_UWSGI_PROCESSES}).
        --firewall           Configure and offer to enable UFW (allows SSH first).
        --upgrade-system     Run 'apt upgrade' during install (off by default).

BEHAVIOUR
        --dry-run            Show what would change; make no changes.
    -y, --yes                Assume "yes" for prompts (unattended installs).
        --skip-dns-check     Do not verify the domain resolves to this host.
        --skip-selftest      Skip the upload/download round-trip check.
        --allow-unsupported-os   Proceed on a non-tested OS/release.

MAINTENANCE
        --uninstall          Remove the service, config, code and DB role.
        --purge              With --uninstall, also delete uploaded files,
                             the database and the server identity key.
    -h, --help               This help.
    -V, --version            Print version and exit.

VULTR (local launcher — runs the terraform/ workflow on your machine, not here)
        --tf-vultr           Instead of installing on this host, drive the Vultr
                             workflow. Prompts to: 1) create an instance,
                             2) install the file server on one, or 3) live-monitor
                             a server's log (with its ed25519 pubkey pinned on
                             top). 1 and 2 need Terraform locally; 3 needs SSH.
        --vultr-api-key=<k>  Vultr API key. Must be given together with --tf-vultr
                             (neither works without the other).

EXAMPLES
    sudo ./setup.sh -d files.example.org --email admin@example.org --firewall
    sudo ./setup.sh -d files.example.org --tls self-signed --skip-dns-check
    sudo ./setup.sh -d files.example.org --dry-run

    # From your own machine: create/manage the Vultr instance via Terraform
    ./setup.sh --tf-vultr --vultr-api-key=xxxxxxxx
    ./setup.sh --tf-vultr --vultr-api-key=xxxxxxxx --domain files.example.org
EOF
}

# require_value <flag> <value> -- guards against "--flag" being the last token,
# which under set -u would otherwise abort with a raw "unbound variable".
require_value() {
    [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] \
        || { printf 'Option %s requires a value.\n\n' "$1" >&2; usage >&2; exit 2; }
}

parse_args() {
    # shellcheck disable=SC2034  # options below are read by the sourced src/steps/*.sh
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)        require_value "$1" "${2:-}"; DOMAIN="$2"; shift 2 ;;
            --tls)              require_value "$1" "${2:-}"; TLS_MODE="$2"; shift 2 ;;
            --email)            require_value "$1" "${2:-}"; CERTBOT_EMAIL="$2"; shift 2 ;;
            --cert)             require_value "$1" "${2:-}"; TLS_CERT_PATH="$2"; shift 2 ;;
            --key)              require_value "$1" "${2:-}"; TLS_KEY_PATH="$2"; shift 2 ;;
            --ref)              require_value "$1" "${2:-}"; UPSTREAM_REF="$2"; shift 2 ;;
            --max-file-size)    require_value "$1" "${2:-}"; MAX_FILE_SIZE="$2"; shift 2 ;;
            --processes)        require_value "$1" "${2:-}"; UWSGI_PROCESSES="$2"; shift 2 ;;
            --firewall)         CONFIGURE_FIREWALL=1; shift ;;
            --upgrade-system)   UPGRADE_SYSTEM=1; shift ;;
            --dry-run)          DRY_RUN=1; shift ;;
            -y|--yes)           ASSUME_YES=1; shift ;;
            --skip-dns-check)   SKIP_DNS_CHECK=1; shift ;;
            --skip-selftest)    SKIP_SELFTEST=1; shift ;;
            --allow-unsupported-os) ALLOW_UNSUPPORTED_OS=1; shift ;;
            --uninstall)        DO_UNINSTALL=1; shift ;;
            --purge)            PURGE=1; shift ;;
            --tf-vultr)         TF_VULTR=1; shift ;;
            --vultr-api-key)    require_value "$1" "${2:-}"; VULTR_API_KEY_ARG="$2"; shift 2 ;;
            --vultr-api-key=*)  VULTR_API_KEY_ARG="${1#*=}"; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       printf '%s\n' "${INSTALLER_VERSION}"; exit 0 ;;
            --)                 shift; break ;;
            -*)                 printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
            *)                  printf 'Unexpected argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

# Validate a domain without a DNS lookup: a dotted, letters/digits/hyphen FQDN.
validate_domain() {
    [[ -n "${DOMAIN}" ]] || { printf 'A domain is required: sudo ./setup.sh --domain <fqdn>\n\n' >&2; usage >&2; exit 2; }
    [[ "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] \
        || die "Not a valid domain: '${DOMAIN}'"
}

main() {
    parse_args "$@"

    # Local Terraform/Vultr launcher mode. This drives the terraform/ workflow from
    # the developer's machine instead of installing on the current host, so it must
    # intercept before the root check, OS detection and the /var/log setup. The two
    # flags are required together.
    if [[ "${TF_VULTR}" == "1" || -n "${VULTR_API_KEY_ARG}" ]]; then
        [[ "${TF_VULTR}" == "1" ]] \
            || die "--vultr-api-key is only valid together with --tf-vultr."
        [[ -n "${VULTR_API_KEY_ARG}" ]] \
            || die "--tf-vultr requires --vultr-api-key=<key> (both must be given together)."
        run_tf_vultr
        exit 0
    fi

    require_root          # before touching the log file
    init_logging
    install_error_trap
    banner

    if [[ "${DO_UNINSTALL}" == "1" ]]; then
        run_uninstall
        exit 0
    fi

    validate_domain
    [[ "${DRY_RUN}" == "1" ]] && notice "DRY RUN: no changes will be made."
    log_info "domain=${DOMAIN} tls=${TLS_MODE} ref=${UPSTREAM_REF} firewall=${CONFIGURE_FIREWALL}"

    set_step_total 10
    step "Preflight checks";                 preflight
    step "Install system packages";          step_packages
    step "Create service account & layout";  step_account
    step "Fetch the file server source";     step_source
    step "Set up PostgreSQL";                step_database
    step "Configure the application";        step_app
    step "Install the systemd service";      step_service
    step "Configure nginx and TLS";          step_nginx
    # Verify while the network is fully open, then harden with the firewall last.
    step "Verify the deployment";            step_verify
    step "Configure the firewall";           step_firewall
    print_summary
    log_info "==== installer finished successfully ===="
}

main "$@"
