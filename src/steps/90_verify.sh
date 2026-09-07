#!/usr/bin/env bash
#
# Prove the installer's own work before declaring success, then hand the operator
# exactly the values this fork's client needs.
#
# Everything is checked THROUGH nginx on loopback: the uWSGI socket speaks the
# uwsgi wire protocol, not HTTP, so it cannot be curled directly -- and going via
# nginx also validates the reverse-proxy config. --resolve pins the domain to
# 127.0.0.1 so this works before DNS propagates, and -k accepts a self-signed
# cert (we are only talking to our own box).
#
# TLS may legitimately not be up yet: certbot needs ports 80/443 reachable from
# the internet, and that can fail for reasons outside this script (a cloud
# firewall). When that happens nginx still serves the app on port 80, so the
# verification probes whichever port is actually live rather than assuming 443.

# The client URL scheme/host (what the operator configures) -- always HTTPS unless
# TLS was explicitly disabled, regardless of whether the cert is in place yet.
_scheme()   { [[ "${TLS_MODE}" == "none" ]] && printf 'http' || printf 'https'; }
_base_url() { printf '%s://%s' "$(_scheme)" "${DOMAIN}"; }

# The endpoint that is actually answering on loopback right now.
LIVE_SCHEME=""
LIVE_PORT=""
TLS_LIVE=0

# True if nginx answers an app route on <scheme>://loopback:<port> (any HTTP
# status counts -- even a cold-start 502 means the proxy path is wired; only a
# refused/timed-out connection fails).
_probe_local() {
    local scheme="$1" port="$2"
    curl -sk --max-time 10 --resolve "${DOMAIN}:${port}:127.0.0.1" \
        -o /dev/null "${scheme}://${DOMAIN}/session_version?platform=desktop" 2>/dev/null
}

# Prefer HTTPS on 443; fall back to HTTP on 80 (e.g. when certbot has not yet
# succeeded). Sets LIVE_SCHEME/LIVE_PORT/TLS_LIVE. Returns 1 if neither answers.
_detect_local_endpoint() {
    LIVE_SCHEME=""; LIVE_PORT=""; TLS_LIVE=0
    if [[ "${TLS_MODE}" != "none" ]] && _probe_local https 443; then
        LIVE_SCHEME="https"; LIVE_PORT="443"; TLS_LIVE=1
        return 0
    fi
    if _probe_local http 80; then
        LIVE_SCHEME="http"; LIVE_PORT="80"; TLS_LIVE=0
        return 0
    fi
    return 1
}

_live_curl() {
    curl -sk --max-time 15 --resolve "${DOMAIN}:${LIVE_PORT}:127.0.0.1" "$@"
}
_live_url() { printf '%s://%s' "${LIVE_SCHEME}" "${DOMAIN}"; }

_verify_reachable() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    %s[dry-run]%s probe /session_version through nginx (https, or http if TLS is not up)\n' "${C_DIM}" "${C_RESET}"
        return 0
    fi
    unit_active "${SERVICE_NAME}" || die "${SERVICE_NAME} is not active."
    unit_active nginx || die "nginx is not active."

    if ! _detect_local_endpoint; then
        log_error "$(journalctl -u "${SERVICE_NAME}" --no-pager -n 20 2>&1)"
        die "Could not reach the app through nginx on http/https loopback. See journalctl -u ${SERVICE_NAME}."
    fi

    local code
    code="$(_live_curl -o /dev/null -w '%{http_code}' "$(_live_url)/session_version?platform=desktop" 2>/dev/null || true)"

    if [[ "${TLS_LIVE}" != "1" && "${TLS_MODE}" != "none" ]]; then
        ok "nginx reaches the app over HTTP (status ${code}) -- TLS is not active yet"
    elif [[ "${code}" == "502" || "${code}" == "503" ]]; then
        ok "nginx reaches the app (status ${code}; /session_version warms up over the first minutes)"
    else
        ok "nginx reaches the app (status ${code})"
    fi
}

# Extract the "id" from the upload JSON without assuming jq is present.
_json_id() {
    if cmd_exists python3; then
        python3 -c 'import sys,json
try: print(json.load(sys.stdin)["id"])
except Exception: pass' 2>/dev/null
    else
        grep -oE '"id"[[:space:]]*:[[:space:]]*"?[^",}]+' | head -1 | grep -oE '[0-9A-Za-z_-]+$'
    fi
}

# The authoritative check: a full upload+download round-trip proves FILE_BASE_PATH
# is writable, the storage pool is seeded, PostgreSQL is reachable and the socket
# works -- the exact failure modes that otherwise only surface when a real client
# first sends an attachment. Runs over whichever endpoint _verify_reachable found.
_verify_roundtrip() {
    if [[ "${DRY_RUN}" == "1" || "${SKIP_SELFTEST}" == "1" ]]; then
        [[ "${SKIP_SELFTEST}" == "1" ]] && skipped "Upload self-test (--skip-selftest)"
        return 0
    fi
    cmd_exists curl || { notice "curl unavailable; skipping upload self-test."; return 0; }
    [[ -n "${LIVE_PORT}" ]] || return 0

    local payload id got
    payload="selftest-$(random_string 12)"
    id="$(_live_curl -X POST -H 'Content-Type: application/octet-stream' \
        --data-binary "${payload}" "$(_live_url)/file" 2>/dev/null | _json_id || true)"

    if [[ -z "${id}" ]]; then
        log_error "$(journalctl -u "${SERVICE_NAME}" --no-pager -n 20 2>&1)"
        die "Upload self-test failed (no file id). Check FILE_BASE_PATH permissions, the storage pool and PostgreSQL."
    fi

    got="$(_live_curl "$(_live_url)/file/${id}" 2>/dev/null || true)"
    if [[ "${got}" == "${payload}" ]]; then
        ok "Upload/download round-trip succeeded (file id ${id})"
    else
        die "Round-trip mismatch: uploaded and downloaded bytes differ (id ${id})."
    fi
}

# Derives the two hex public keys the client configuration needs. The Ed25519
# pubkey is what this fork puts in DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX; the
# X25519 pubkey is what the onion-request layer actually encrypts to.
read_server_pubkeys() {
    [[ -f "${SERVER_KEY_FILE}" ]] || return 1
    "${VENV_DIR}/bin/python3" - "${SERVER_KEY_FILE}" <<'PY'
import sys
from nacl.signing import SigningKey
data = open(sys.argv[1]).read().strip()
sk = SigningKey(bytes.fromhex(data[:64]))
print(sk.verify_key.encode().hex())
print(sk.to_curve25519_private_key().public_key.encode().hex())
PY
}

step_verify() {
    _verify_reachable
    _verify_roundtrip
}

# The closing hand-off: the two client-config values and an operations cheat
# sheet. Always runs (even in dry-run) so the operator sees the shape.
print_summary() {
    local ed="" x=""
    if [[ "${DRY_RUN}" != "1" ]]; then
        { IFS= read -r ed; IFS= read -r x; } < <(read_server_pubkeys 2>/dev/null) || true
    fi

    local url; url="$(_base_url)"

    heading "Session file server is deployed."
    cat <<EOF

  Endpoint URL   : ${url}
  Ed25519 pubkey : ${ed:-<run without --dry-run to read the key>}
  X25519 pubkey  : ${x:-<derived from the Ed25519 key at runtime>}

  Point this fork's Android client at the server by setting, in
  session-android/.env.local (see notes/98):

      DEFAULT_FILE_SERVER_URL="${url}"
      DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX="${ed:-<Ed25519 pubkey above>}"

  Operations:
    Status    : systemctl status ${SERVICE_NAME}
    Logs      : journalctl -u ${SERVICE_NAME} -f
    Restart   : systemctl restart ${SERVICE_NAME}
    Config    : ${APP_CONFIG_FILE}
    Uploads   : ${FILES_DIR}
    Re-run    : safe and idempotent; re-run this installer to update or repair.
EOF

    # TLS was requested but is not actually serving -- almost always ports 80/443
    # are not reachable from the internet. The client needs HTTPS, so make this
    # impossible to miss and give the exact recovery steps.
    if [[ "${DRY_RUN}" != "1" && "${TLS_MODE}" != "none" && "${TLS_LIVE}" != "1" ]]; then
        cat >&2 <<EOF

  ${C_YELLOW}==============================  ACTION REQUIRED  ==============================${C_RESET}
  TLS is NOT active: the server is answering on HTTP only, but the Session client
  requires HTTPS on port 443, so it cannot use this server yet.

  This is usually because ports 80 and 443 are not reachable from the internet
  (e.g. a Vultr cloud firewall). To finish:
    1. Allow inbound TCP 80 and 443 from anywhere (Vultr firewall group / your host firewall).
    2. On the server run:   certbot --nginx -d ${DOMAIN}
    3. Check https://${DOMAIN}/ responds, then the client can use the URL above.
  ${C_YELLOW}=============================================================================${C_RESET}
EOF
    elif [[ "${TLS_MODE}" == "self-signed" ]]; then
        printf '\n  Note: the self-signed certificate may be rejected by exit nodes; use --tls certbot for production.\n'
    fi
    log_info "Summary printed. Endpoint ${url}, ed25519 ${ed:-unknown}, tls_live ${TLS_LIVE}"
}
