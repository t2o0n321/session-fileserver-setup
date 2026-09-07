#!/usr/bin/env bash
#
# Logging and fatal-error handling.
#
# Separation of concerns: the *console* shows the pretty step/ok/notice lines
# from ui.sh (on stdout) plus errors (on stderr); the *log file* gets the full
# timestamped record. log_info/log_warn therefore only journal to the file — they
# do not echo to the console, so ordinary messages are never printed twice.

LOG_READY=0

_log_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Append one timestamped line to the persistent log file, when we have one. In
# launcher mode (no root, no log file) this is a silent no-op.
_journal() {
    [[ "${LOG_READY}" == "1" ]] || return 0
    printf '[%s] [%s] %s\n' "$(_log_timestamp)" "$1" "${*:2}" >>"${SETUP_LOG_FILE}"
}

# Detail for the record only (not shown on the console).
log_info() { _journal INFO "$*"; }
log_warn() { _journal WARN "$*"; }

# Errors always reach the console (stderr) as well as the log file.
log_error() {
    _journal ERROR "$*"
    printf '%s%s%s\n' "${C_RED:-}" "$*" "${C_RESET:-}" >&2
}

# die <message...> -- report and abort. Prints the error once; only points at the
# log file when one actually exists (so launcher mode stays quiet about it).
die() {
    log_error "$*"
    if [[ "${LOG_READY}" == "1" ]]; then
        _journal ERROR "Aborted."
        printf '%sAborted. Full log: %s%s\n' "${C_DIM:-}" "${SETUP_LOG_FILE}" "${C_RESET:-}" >&2
    fi
    exit 1
}

# Creates the log file with root-only permissions. Must be called *after* the
# root check.
init_logging() {
    local dir
    dir="$(dirname -- "${SETUP_LOG_FILE}")"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p -- "${dir}" || die "Cannot create log directory ${dir}"
    fi
    if ! touch -- "${SETUP_LOG_FILE}"; then
        die "Cannot create log file ${SETUP_LOG_FILE}"
    fi
    chmod 600 -- "${SETUP_LOG_FILE}" || die "Cannot chmod ${SETUP_LOG_FILE}"
    chown root:root -- "${SETUP_LOG_FILE}" || die "Cannot chown ${SETUP_LOG_FILE}"
    LOG_READY=1
    log_info "==== session-file-server installer ${INSTALLER_VERSION} started ===="
}

# Reports the failing line instead of exiting silently on `set -e`.
_on_err() {
    local exit_code="$1" line="$2" command="$3"
    log_error "Unexpected failure (exit ${exit_code}) at ${BASH_SOURCE[1]:-?}:${line}: ${command}"
    [[ "${LOG_READY}" == "1" ]] \
        && printf '%sNothing further was changed. Full log: %s%s\n' "${C_DIM:-}" "${SETUP_LOG_FILE}" "${C_RESET:-}" >&2
    return 0
}

install_error_trap() {
    set -E
    trap '_on_err "$?" "${LINENO}" "${BASH_COMMAND}"' ERR
}
