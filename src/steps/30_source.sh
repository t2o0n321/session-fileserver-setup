#!/usr/bin/env bash
#
# Fetch the upstream file server at a pinned revision.
#
# The previous installer ran a bare `git clone` of the default branch, which is
# `dev` and moves: two operators running the same script a month apart would get
# different code.  Here the revision is explicit, recorded, and overridable.

_clone_or_fetch() {
    if [[ -d "${CODE_DIR}/.git" ]]; then
        run git -C "${CODE_DIR}" remote set-url origin "${UPSTREAM_REPO_URL}" \
            || die "Could not update the origin URL in ${CODE_DIR}"
        run git -C "${CODE_DIR}" fetch --tags --prune origin \
            || die "Could not fetch from ${UPSTREAM_REPO_URL}"
        skipped "Checkout present at ${CODE_DIR}; fetched updates"
    else
        if [[ -e "${CODE_DIR}" ]] && [[ -n "$(ls -A "${CODE_DIR}" 2>/dev/null)" ]]; then
            die "${CODE_DIR} exists and is not a git checkout. Move it aside, or run --uninstall first."
        fi
        run git clone "${UPSTREAM_REPO_URL}" "${CODE_DIR}" \
            || die "Could not clone ${UPSTREAM_REPO_URL}"
        ok "Cloned ${UPSTREAM_REPO_URL}"
    fi
}

_checkout_ref() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    %s[dry-run]%s git checkout %s in %s\n' "${C_DIM}" "${C_RESET}" "${UPSTREAM_REF}" "${CODE_DIR}"
        return 0
    fi

    # Accept a commit, tag or branch. For a branch, track its remote tip.
    local target="${UPSTREAM_REF}"
    if git -C "${CODE_DIR}" rev-parse --verify --quiet "refs/remotes/origin/${UPSTREAM_REF}" >/dev/null; then
        target="origin/${UPSTREAM_REF}"
    fi

    git -C "${CODE_DIR}" -c advice.detachedHead=false checkout --force "${target}" -- \
        2>/dev/null \
        || git -C "${CODE_DIR}" -c advice.detachedHead=false checkout --force "${target}" \
        || die "Could not check out '${UPSTREAM_REF}'. Is it a valid commit, tag or branch?"

    # A stale tracked file from an older revision would shadow the new code.
    git -C "${CODE_DIR}" clean -fd -e venv -e files -e fileserver/config.py >/dev/null \
        || die "Could not clean ${CODE_DIR}"

    RESOLVED_COMMIT="$(git -C "${CODE_DIR}" rev-parse HEAD)"
    ok "Checked out ${UPSTREAM_REF} (${RESOLVED_COMMIT:0:12})"
}

# The two source patches the previous installer applied with `perl -i -pe` are
# both fixed upstream now: subrequest.py already stringifies CONTENT_LENGTH, and
# routes.py renamed ts_str to ts (so the old regex silently matched nothing and
# perl still exited 0).  Rather than carry dead patches, assert the fixed code is
# present -- if a future revision regresses, the operator hears about it.
_verify_upstream_expectations() {
    local subrequest="${CODE_DIR}/fileserver/subrequest.py"
    local routes="${CODE_DIR}/fileserver/routes.py"
    local schema="${CODE_DIR}/schema.pgsql"

    if [[ "${DRY_RUN}" == "1" && ! -f "${subrequest}" ]]; then
        return 0
    fi

    [[ -f "${schema}" ]] || die "${schema} is missing; this does not look like session-file-server."
    grep -q 'CREATE TABLE storage_pools' "${schema}" \
        || die "${schema} has no storage_pools table; this installer's database step expects it."

    if [[ -f "${subrequest}" ]] && ! grep -q '"CONTENT_LENGTH": str(content_length)' "${subrequest}"; then
        notice "${subrequest} does not stringify CONTENT_LENGTH; sub-requests may fail on this revision."
    fi
    if [[ -f "${routes}" ]] && ! grep -qE 'to_verify = str\(ts(_str)?\)\.encode\(\)' "${routes}"; then
        notice "${routes} does not stringify the signature timestamp; version checks may fail on this revision."
    fi
    ok "Upstream revision matches this installer's expectations"
}

step_source() {
    _clone_or_fetch
    _checkout_ref
    _verify_upstream_expectations
}
