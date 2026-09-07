#!/usr/bin/env bash
#
# Console presentation only: the banner, numbered step headers and the closing
# hand-off summary.  Kept apart from log.sh so that changing how things look
# never risks changing what gets recorded.

if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_CYAN=$'\033[36m'
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

STEP_INDEX=0
STEP_TOTAL=0

banner() {
    local art_file="${SCRIPT_DIR}/art.txt"
    if [[ -f "${art_file}" ]]; then
        cat -- "${art_file}"
    fi
    printf '%s\n' "${C_DIM}  Session file server installer ${INSTALLER_VERSION}${C_RESET}"
    printf '\n'
}

set_step_total() { STEP_TOTAL="$1"; }

# step <title> -- prints a numbered header and records it in the log.
step() {
    STEP_INDEX=$((STEP_INDEX + 1))
    printf '\n%s==> [%d/%d] %s%s\n' \
        "${C_BOLD}${C_CYAN}" "${STEP_INDEX}" "${STEP_TOTAL}" "$*" "${C_RESET}"
    log_info "STEP ${STEP_INDEX}/${STEP_TOTAL}: $*"
}

ok()      { printf '    %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; log_info "  ok: $*"; }
skipped() { printf '    %s·%s %s %s(already done)%s\n' "${C_DIM}" "${C_RESET}" "$*" "${C_DIM}" "${C_RESET}"; log_info "  skip: $*"; }
notice()  { printf '    %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; log_warn "$*"; }

heading() { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
