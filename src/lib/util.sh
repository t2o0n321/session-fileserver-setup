#!/usr/bin/env bash
#
# Small, side-effect-free-by-default helpers shared by every step.
#
# run() and write_file() are the only two places that mutate the system, which
# is what makes --dry-run trustworthy: if a step goes through them, dry-run
# covers it.

# --------------------------------------------------------------------------
# Mutation wrappers
# --------------------------------------------------------------------------

# run <command...> -- execute, or describe under --dry-run.
run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    %s[dry-run]%s %s\n' "${C_DIM}" "${C_RESET}" "$*"
        log_info "  dry-run: $*"
        return 0
    fi
    log_info "  exec: $*"
    "$@"
}

# write_file <path> <mode> <owner:group> < content
#
# Writes atomically, but only when the content actually differs, so re-running
# the installer neither rewrites files nor needlessly restarts services.
# Sets FILE_CHANGED=1 when the file was created or modified, 0 otherwise.
FILE_CHANGED=0
write_file() {
    local path="$1" mode="$2" owner="$3" content
    content="$(cat)"
    FILE_CHANGED=0

    if [[ -f "${path}" ]] && [[ "$(cat -- "${path}")" == "${content}" ]]; then
        return 0
    fi
    FILE_CHANGED=1

    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    %s[dry-run]%s write %s (mode %s, owner %s, %d bytes)\n' \
            "${C_DIM}" "${C_RESET}" "${path}" "${mode}" "${owner}" "${#content}"
        log_info "  dry-run: write ${path}"
        return 0
    fi

    local dir tmp
    dir="$(dirname -- "${path}")"
    mkdir -p -- "${dir}" || die "Cannot create directory ${dir}"
    tmp="$(mktemp -- "${path}.XXXXXX")" || die "Cannot create temp file next to ${path}"
    printf '%s\n' "${content}" >"${tmp}" || die "Cannot write ${tmp}"
    chmod "${mode}" -- "${tmp}" || die "Cannot chmod ${tmp}"
    chown "${owner}" -- "${tmp}" || die "Cannot chown ${tmp} to ${owner}"
    mv -f -- "${tmp}" "${path}" || die "Cannot move ${tmp} to ${path}"
    log_info "  wrote ${path} (mode ${mode}, owner ${owner})"
}

# --------------------------------------------------------------------------
# Probes -- read-only, so they run unchanged under --dry-run
# --------------------------------------------------------------------------
cmd_exists() { command -v -- "$1" >/dev/null 2>&1; }

pkg_installed() {
    dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null | grep -q 'ok installed'
}

user_exists()  { id -u -- "$1" >/dev/null 2>&1; }
group_exists() { getent group -- "$1" >/dev/null 2>&1; }

unit_exists()  { systemctl list-unit-files -- "$1" >/dev/null 2>&1 && systemctl cat -- "$1" >/dev/null 2>&1; }
unit_active()  { systemctl is-active --quiet -- "$1"; }
unit_enabled() { systemctl is-enabled --quiet -- "$1" 2>/dev/null; }

# True when something is already listening on the given TCP port.
port_in_use() {
    local port="$1"
    cmd_exists ss || return 1
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

# Every IP configured on this host (used to accept a DNS record that points at
# an address bound locally, e.g. a VPS with the public IP on the interface).
local_ips() {
    if cmd_exists ip; then
        ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    fi
}

# Best-effort public address; empty when there is no egress.
public_ip() {
    local ip=""
    if cmd_exists curl; then
        ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
        [[ -n "${ip}" ]] || ip="$(curl -fsS --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)"
    fi
    printf '%s' "${ip}"
}

# A/AAAA records for a host, via glibc so no dnsutils dependency is needed
# (the old script shelled out to nslookup, which Ubuntu does not install).
resolve_ips() {
    getent ahosts -- "$1" 2>/dev/null | awk '{print $1}' | sort -u || true
}

random_string() {
    local length="${1:-32}"
    # `tr </dev/urandom | head -c` makes head close the pipe early, so tr takes a
    # SIGPIPE; under `set -o pipefail` that would abort the caller. `|| true`
    # keeps the already-produced output and swallows the signal.
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${length}" || true
}

# Home directory of a user without the `eval echo ~$user` injection hazard.
home_dir_of() { getent passwd -- "$1" | cut -d: -f6; }

# confirm <question> -- yes/no prompt, auto-yes under --yes, refuses to block
# when stdin is not a terminal (so unattended runs fail loudly instead of hanging).
confirm() {
    local question="$1" reply
    if [[ "${ASSUME_YES}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Need confirmation for: ${question} -- re-run with --yes for unattended installs."
    fi
    read -r -p "    ${question} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# Free space in MiB on the filesystem holding <path> (walks up to an existing dir).
free_mib() {
    local path="$1"
    while [[ ! -d "${path}" && "${path}" != "/" ]]; do path="$(dirname -- "${path}")"; done
    df -Pm -- "${path}" | awk 'NR==2 {print $4}'
}

# Runs a command as the service account. sudo -u works even though the account
# has /usr/sbin/nologin, because no login shell is involved.
as_service_user() { run sudo -u "${SERVICE_USER}" -- "$@"; }
as_postgres()     { run sudo -u postgres -- "$@"; }
