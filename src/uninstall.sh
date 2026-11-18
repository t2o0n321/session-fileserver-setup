#!/usr/bin/env bash
#
# Teardown.  --uninstall removes what the installer added but preserves data by
# default (uploaded files, the database, the server identity key).  --purge also
# deletes that data.  The previous installer had no teardown at all, so a failed
# experiment left a half-configured box with no clean way back.

_stop_and_disable_service() {
    if unit_exists "${SERVICE_NAME}.service"; then
        run systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
        ok "Stopped and disabled ${SERVICE_NAME}"
    fi
    if [[ -f "${SERVICE_UNIT}" ]]; then
        run rm -f "${SERVICE_UNIT}"
        run systemctl daemon-reload || true
        ok "Removed ${SERVICE_UNIT}"
    fi
}

_remove_nginx() {
    local default_site="/etc/nginx/sites-available/000-${NGINX_SITE_NAME}-default"
    run rm -f "${NGINX_ENABLED}" "/etc/nginx/sites-enabled/000-${NGINX_SITE_NAME}-default"
    run rm -f "${NGINX_AVAILABLE}" "${default_site}"
    run rm -f "/etc/nginx/conf.d/${NGINX_SITE_NAME}-limits.conf"
    if cmd_exists nginx && [[ "${DRY_RUN}" != "1" ]]; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
    ok "Removed nginx site (self-signed cert, if any, left in place)"
}

_remove_ssh_dropin() {
    run rm -f "${SSHD_DROPIN}"
    if cmd_exists sshd && [[ "${DRY_RUN}" != "1" ]]; then
        sshd -t >/dev/null 2>&1 && systemctl try-reload-or-restart ssh >/dev/null 2>&1 || true
    fi
    ok "Removed the sshd MAC drop-in (sshd is back to its stock MACs)"
}

_remove_config_and_code() {
    run rm -f "${UWSGI_INI_FILE}"
    run rm -rf "${CONF_DIR}"
    run rm -rf "${CODE_DIR}"
    ok "Removed ${CODE_DIR} and ${CONF_DIR}"
}

_remove_apt_source() {
    run rm -f "${OXEN_SOURCES_FILE}" "${OXEN_KEYRING}"
    ok "Removed the Oxen apt source (installed packages are left in place)"
}

# Data-destroying actions, gated behind --purge and a confirmation.
_purge_data() {
    if [[ "${PURGE}" != "1" ]]; then
        notice "Kept data: ${STATE_DIR} (files + key) and the '${DB_NAME}' database. Use --purge to delete."
        return 0
    fi
    if ! confirm "PURGE: permanently delete uploaded files, the '${DB_NAME}' database and the identity key?"; then
        notice "Purge cancelled; data left intact."
        return 0
    fi

    if _database_exists 2>/dev/null || unit_active postgresql; then
        as_postgres dropdb --if-exists "${DB_NAME}" || notice "Could not drop database ${DB_NAME}."
        as_postgres dropuser --if-exists "${DB_USER}" || notice "Could not drop role ${DB_USER}."
        ok "Dropped database and role"
    fi
    run rm -rf "${STATE_DIR}"
    ok "Deleted ${STATE_DIR}"
    if user_exists "${SERVICE_USER}"; then
        run userdel "${SERVICE_USER}" >/dev/null 2>&1 || notice "Could not remove user ${SERVICE_USER}."
        run groupdel "${SERVICE_GROUP}" >/dev/null 2>&1 || true
        ok "Removed service account"
    fi
}

run_uninstall() {
    set_step_total 7
    [[ "${DRY_RUN}" == "1" ]] && notice "DRY RUN: no changes will be made."
    notice "Uninstalling the Session file server${PURGE:+ (with --purge)}."

    step "Stop the service";          _stop_and_disable_service
    step "Remove nginx site";         _remove_nginx
    step "Remove sshd MAC drop-in";   _remove_ssh_dropin
    step "Remove config and code";    _remove_config_and_code
    step "Remove the apt source";     _remove_apt_source
    step "Handle data";               _purge_data
    step "Done";                      ok "Uninstall complete."
}
