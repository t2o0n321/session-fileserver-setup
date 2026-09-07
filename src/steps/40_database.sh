#!/usr/bin/env bash
#
# PostgreSQL role, database and schema.
#
# Notably absent: any edit to pg_hba.conf.  The previous installer rewrote
# `local all all peer` to `trust`, which lets *every* local account connect as
# *any* role -- including the postgres superuser -- with no password.  Because the
# service runs as its own OS account whose name matches the database role, stock
# peer authentication already works.

# Read-only query helper; deliberately not wrapped in run() so --dry-run can
# still inspect the live database.
_psql_postgres() { sudo -u postgres psql -tAqX -v ON_ERROR_STOP=1 "$@"; }

_ensure_postgres_running() {
    if ! unit_active postgresql; then
        run systemctl enable --now postgresql || die "Could not start PostgreSQL."
        ok "PostgreSQL started"
    else
        skipped "PostgreSQL running"
    fi
    if ! unit_enabled postgresql; then
        run systemctl enable postgresql || notice "Could not enable postgresql at boot."
    fi
    # A freshly started cluster may not accept connections for a moment.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if sudo -u postgres psql -tAqX -c 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    [[ "${DRY_RUN}" == "1" ]] || die "PostgreSQL is not accepting connections."
}

_role_exists() {
    [[ "$(_psql_postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'" 2>/dev/null)" == "1" ]]
}

_database_exists() {
    [[ "$(_psql_postgres -c "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" 2>/dev/null)" == "1" ]]
}

_schema_loaded() {
    [[ "$(_psql_postgres -d "${DB_NAME}" -c \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'files'" \
        2>/dev/null)" == "1" ]]
}

_create_role() {
    if _role_exists; then
        skipped "Database role '${DB_USER}' exists"
        return 0
    fi
    # No LOGIN password: the role is reachable only over the local socket by the
    # OS account of the same name (peer auth).
    as_postgres createuser -- "${DB_USER}" || die "Could not create database role '${DB_USER}'."
    ok "Created database role '${DB_USER}'"
}

_create_database() {
    if _database_exists; then
        skipped "Database '${DB_NAME}' exists"
        return 0
    fi
    as_postgres createdb -O "${DB_USER}" -- "${DB_NAME}" \
        || die "Could not create database '${DB_NAME}'."
    ok "Created database '${DB_NAME}' owned by '${DB_USER}'"
}

# Loaded *as the application role*, so every table, view and sequence is owned by
# it.  The previous installer loaded the schema as the postgres superuser and then
# tried to hand ownership back with a series of GRANTs, which leaves the app
# unable to ALTER or TRUNCATE its own tables.
_load_schema() {
    if _schema_loaded; then
        skipped "Schema already loaded in '${DB_NAME}'"
        return 0
    fi
    local schema="${CODE_DIR}/schema.pgsql"
    if [[ ! -f "${schema}" ]]; then
        [[ "${DRY_RUN}" == "1" ]] && return 0
        die "Schema file not found: ${schema}"
    fi
    as_service_user psql -v ON_ERROR_STOP=1 -q -d "${DB_NAME}" -f "${schema}" \
        || die "Could not load ${schema} into '${DB_NAME}'."
    ok "Loaded schema as role '${DB_USER}'"
}

# files.pool is NOT NULL and references storage_pools(id), but schema.pgsql seeds
# no pools, so uploads fail until one exists.
_seed_storage_pool() {
    if [[ "${DRY_RUN}" == "1" ]] && ! _schema_loaded; then
        printf '    %s[dry-run]%s seed storage pool %s\n' "${C_DIM}" "${C_RESET}" "${DB_DEFAULT_POOL}"
        return 0
    fi
    local count
    count="$(sudo -u "${SERVICE_USER}" psql -tAqX -d "${DB_NAME}" \
        -c "SELECT count(*) FROM storage_pools WHERE name = '${DB_DEFAULT_POOL}'" 2>/dev/null || echo 0)"
    if [[ "${count}" != "0" ]]; then
        skipped "Storage pool '${DB_DEFAULT_POOL}' exists"
        return 0
    fi
    as_service_user psql -v ON_ERROR_STOP=1 -q -d "${DB_NAME}" \
        -c "INSERT INTO storage_pools (name, active) VALUES ('${DB_DEFAULT_POOL}', true);" \
        || die "Could not insert the default storage pool."
    ok "Seeded storage pool '${DB_DEFAULT_POOL}'"
}

step_database() {
    _ensure_postgres_running
    _create_role
    _create_database
    _load_schema
    _seed_storage_pool
}
