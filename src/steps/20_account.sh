#!/usr/bin/env bash
#
# The service account and the directory layout it owns.
#
# A dedicated system account is what lets the rest of the design be simple:
# PostgreSQL peer authentication needs no pg_hba.conf edit, the private key is
# readable by exactly one uid, and nothing has to be moved out of a human user's
# home directory (or have that home directory made world-traversable).

_create_service_account() {
    if user_exists "${SERVICE_USER}"; then
        skipped "Service account '${SERVICE_USER}' exists"
        return 0
    fi
    run useradd \
        --system \
        --home-dir "${STATE_DIR}" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --user-group \
        --comment "Session file server" \
        "${SERVICE_USER}" \
        || die "Could not create service account '${SERVICE_USER}'."
    ok "Created system account '${SERVICE_USER}' (nologin, no home)"
}

# ensure_dir <path> <mode> <owner:group>
_ensure_dir() {
    local path="$1" mode="$2" owner="$3"
    if [[ ! -d "${path}" ]]; then
        run install -d -m "${mode}" -o "${owner%%:*}" -g "${owner##*:}" "${path}" \
            || die "Could not create ${path}"
        ok "Created ${path} (${mode}, ${owner})"
        return 0
    fi
    # Converge an existing directory instead of leaving it however it was found.
    run chmod "${mode}" "${path}" || die "Could not chmod ${path}"
    run chown "${owner}" "${path}" || die "Could not chown ${path}"
    skipped "${path} (${mode}, ${owner})"
}

_create_directories() {
    # Code is root-owned so a compromised service account cannot rewrite it.
    _ensure_dir "${CODE_DIR}" 0755 root:root
    _ensure_dir "${CONF_DIR}" 0755 root:root

    # State is private to the service account: it holds the server identity key
    # and every uploaded file.  0700 means nginx's group cannot read it either.
    _ensure_dir "${STATE_DIR}" 0700 "${SERVICE_USER}:${SERVICE_GROUP}"

    # FILE_BASE_PATH. The app only does `store.parent.mkdir(...)`, so it creates
    # pool/prefix subdirectories but never this base directory -- without it,
    # every upload fails with an unhandled exception at write time.
    _ensure_dir "${FILES_DIR}" 0700 "${SERVICE_USER}:${SERVICE_GROUP}"
}

step_account() {
    _create_service_account
    _create_directories
}
