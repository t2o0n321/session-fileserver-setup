#!/usr/bin/env bash
#
# Offline checks that run anywhere (no root, no Ubuntu, no Docker): bash syntax
# for every script, and shellcheck across the sourced tree. For a real
# end-to-end install test, see test/e2e-docker.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

echo "== bash -n (syntax) =="
while IFS= read -r -d '' f; do
    if bash -n "$f"; then printf '  ok  %s\n' "$f"; else printf '  ERR %s\n' "$f"; fail=1; fi
done < <(find setup.sh src -name '*.sh' -print0 | sort -z)

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -s bash setup.sh; then
        echo "  ok  clean"
    else
        echo "  ERR shellcheck reported issues"; fail=1
    fi
else
    echo "  -- shellcheck not installed; skipping"
fi

[[ "${fail}" == "0" ]] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
