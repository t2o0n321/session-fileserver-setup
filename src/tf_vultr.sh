#!/usr/bin/env bash
#
# Optional launcher mode: `setup.sh --tf-vultr --vultr-api-key=<key>`.
#
# Unlike the normal installer (which runs ON the target Ubuntu server as root),
# this mode runs on the developer's own machine and drives the Terraform workflow
# under terraform/ — so it must be intercepted before the root / OS / logging
# setup, and must stay portable to macOS's bash 3.2.

# Set by _resolve_instance_label (avoids capturing prompts via command subst).
RESOLVED_LABEL=""

# Entry point. main() has already confirmed --tf-vultr and --vultr-api-key were
# given together, so here we only validate the environment and dispatch.
run_tf_vultr() {
    banner

    # terraform is needed by Features 1 and 2 (checked there); Feature 3 (monitor)
    # is pure SSH, so it is not required just to reach the menu.
    local tf_root="${SCRIPT_DIR}/terraform"
    if [[ ! -d "${tf_root}/1-instance" || ! -d "${tf_root}/2-fileserver" ]]; then
        die "terraform/ workflow not found next to setup.sh (looked in ${tf_root})."
    fi

    # Handed to Terraform / select-instance.sh through the environment only —
    # never placed on a command line or written to a log.
    export VULTR_API_KEY="${VULTR_API_KEY_ARG}"

    heading "Vultr Terraform workflow"
    printf '  1) %-42s(Feature 1)\n'   'Create a new instance'
    printf '  2) %-42s(Feature 2)\n'   'Install the session file server on one'
    printf '  3) %-42s(Feature 3)\n\n' "Live-monitor a server's log"

    local choice=""
    read -r -p "Which do you want to run? [1/2/3]: " choice
    printf '\n'

    case "${choice}" in
        1) _tf_vultr_create "${tf_root}/1-instance" ;;
        2) _tf_vultr_install "${tf_root}/2-fileserver" ;;
        3) _tf_vultr_monitor ;;
        *) die "Invalid selection '${choice}' — enter 1, 2 or 3." ;;
    esac
}

# --------------------------------------------------------------------------
# Shared instance listing / picking (used by Feature 3)
# --------------------------------------------------------------------------

# Emits instances as TSV rows: ip \t label \t region \t power \t os.
_vultr_list_rows() {
    curl -fsS -H "Authorization: Bearer ${VULTR_API_KEY}" \
        "https://api.vultr.com/v2/instances?per_page=500" \
        | jq -r '.instances[] | [.main_ip, (.label // "-"), .region, .power_status, (.os // "-")] | @tsv'
}

PICKED_IP=""
PICKED_LABEL=""

# Lists instances and prompts for one. Sets PICKED_IP/PICKED_LABEL; returns 1 on
# no instances / invalid selection.
_pick_instance() {
    PICKED_IP=""; PICKED_LABEL=""
    local rows=() line
    while IFS= read -r line; do rows+=("${line}"); done < <(_vultr_list_rows)
    local n="${#rows[@]}"
    if [[ "${n}" -eq 0 ]]; then
        notice "No instances found on this account."
        return 1
    fi

    printf '  Select an instance:\n'
    local i=1 ip label region power os
    for line in "${rows[@]}"; do
        IFS=$'\t' read -r ip label region power os <<<"${line}"
        printf '  %2d) %-15s  %-24s  %-6s  %-9s  %s\n' "${i}" "${ip}" "${label}" "${region}" "${power}" "${os}"
        i=$((i + 1))
    done
    printf '\n'

    local choice=""
    read -r -p "Enter number [1-${n}]: " choice
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${n}" ]; then
        notice "Invalid selection."
        return 1
    fi

    local _rest
    IFS=$'\t' read -r PICKED_IP PICKED_LABEL _rest <<<"${rows[$((choice - 1))]}"
    return 0
}

# Lists every instance label on the account (one per line). per_page=500 is the
# Vultr maximum, so a single page covers all but the largest accounts.
_vultr_instance_labels() {
    curl -fsS -H "Authorization: Bearer ${VULTR_API_KEY}" \
        "https://api.vultr.com/v2/instances?per_page=500" \
        | jq -r '.instances[].label // empty'
}

# True if <label> is present in the newline-separated <set> (exact whole line).
_label_in_set() {
    printf '%s\n' "$2" | grep -qxF -- "$1"
}

# Decides the label for a new instance. If <base> already exists on the account,
# asks whether to continue; on yes, picks the lowest free "<base>-N" (N>=2).
# Result goes in RESOLVED_LABEL; returns non-zero if the user declines.
_resolve_instance_label() {
    local base="$1"
    RESOLVED_LABEL=""

    if ! cmd_exists curl || ! cmd_exists jq; then
        notice "curl/jq not available — skipping the duplicate-name check."
        RESOLVED_LABEL="${base}"
        return 0
    fi

    local labels
    if ! labels="$(_vultr_instance_labels 2>/dev/null)"; then
        notice "Could not list existing instances (API error) — proceeding with '${base}'."
        RESOLVED_LABEL="${base}"
        return 0
    fi

    if ! _label_in_set "${base}" "${labels}"; then
        RESOLVED_LABEL="${base}"
        return 0
    fi

    notice "An instance named '${base}' already exists on this Vultr account."
    confirm "Create another instance anyway?" || return 1

    local n=2 candidate
    while :; do
        candidate="${base}-${n}"
        if ! _label_in_set "${candidate}" "${labels}"; then
            RESOLVED_LABEL="${candidate}"
            ok "New instance will be named '${candidate}'."
            return 0
        fi
        n=$((n + 1))
    done
}

# Feature 1: create the instance and print its IP + next steps. Each instance is
# kept in its own Terraform workspace (named after its label) so creating a
# second one never renames or replaces the first.
_tf_vultr_create() {
    local dir="$1"
    heading "Feature 1 — create the Vultr instance"

    cmd_exists terraform \
        || die "terraform is not installed — see https://developer.hashicorp.com/terraform/install"

    local base_label="${TF_VULTR_LABEL:-session-fileserver}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    [dry-run] check the account for an instance named "%s" (suffix -N on collision)\n' "${base_label}"
        printf '    [dry-run] terraform -chdir=%s apply -var label=<resolved> (own workspace)\n' "${dir}"
        return 0
    fi

    if ! _resolve_instance_label "${base_label}"; then
        notice "Cancelled — no instance created."
        return 0
    fi
    local label="${RESOLVED_LABEL}"

    run terraform -chdir="${dir}" init -input=false \
        || die "terraform init failed."

    # Isolate this instance's state in a workspace named after its label.
    if ! terraform -chdir="${dir}" workspace select "${label}" >/dev/null 2>&1; then
        terraform -chdir="${dir}" workspace new "${label}" >/dev/null \
            || die "Could not create terraform workspace '${label}'."
    fi
    ok "Using terraform workspace '${label}'"

    run terraform -chdir="${dir}" apply -var "label=${label}" \
        || die "terraform apply failed or was cancelled."

    local ip
    ip="$(terraform -chdir="${dir}" output -raw instance_ip 2>/dev/null || true)"

    heading "Instance ready"
    [[ -n "${ip}" ]] && printf '  IP address : %s\n' "${ip}"
    printf '  Label      : %s   (terraform workspace: %s)\n\n' "${label}" "${label}"
    printf '  Next steps:\n'
    printf '    1. Create a DNS A record:  <your-domain>  ->  %s\n' "${ip:-<the IP above>}"
    printf '    2. Wait for it to resolve  (dig +short <your-domain>)\n'
    printf '    3. Install the file server, choosing option 2:\n'
    printf '         ./setup.sh --tf-vultr --vultr-api-key=<key> --domain <your-domain>\n'
}

# Feature 2: hand off to the interactive launcher (list instances, pick, install,
# print the ed25519 pubkey). Passes --domain/--email through when provided.
_tf_vultr_install() {
    local dir="$1"
    local launcher="${dir}/select-instance.sh"
    [[ -f "${launcher}" ]] || die "launcher not found: ${launcher}"

    heading "Feature 2 — install the session file server"

    # The domain is a setup.sh option (--domain); if it wasn't passed, ask for it
    # here rather than relying on a prompt buried inside the launcher.
    local domain="${DOMAIN}"
    if [[ -z "${domain}" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Domain for the file server (must already resolve to the instance you pick): " domain
        else
            die "No --domain given and no terminal to prompt on — re-run with --domain <fqdn>."
        fi
    fi
    [[ -n "${domain}" ]] || die "A domain is required for Feature 2."

    # Always has --domain, so the array is never empty (safe on bash 3.2 + set -u).
    local args=(--domain "${domain}")
    [[ -n "${CERTBOT_EMAIL}" ]] && args+=(--email "${CERTBOT_EMAIL}")

    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    [dry-run] %s %s\n' "${launcher}" "${args[*]}"
        return 0
    fi

    bash "${launcher}" "${args[@]}"
}

# --------------------------------------------------------------------------
# Feature 3: live log monitor with the ed25519 pubkey pinned at the top
# --------------------------------------------------------------------------

# Base SSH options, shared by the pubkey read and the log stream. The key
# defaults to ~/.ssh/id_ed25519 (what Feature 1 installs); override with
# TF_VULTR_SSH_KEY. If the key file is absent we let ssh fall back to its own
# default identities.
_monitor_ssh_opts() {
    MON_SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o ServerAliveInterval=15)
    local key="${TF_VULTR_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
    [[ -f "${key}" ]] && MON_SSH_OPTS+=(-i "${key}")
}

_tf_vultr_monitor() {
    heading "Feature 3 — live log monitor"

    local t
    for t in curl jq ssh; do
        cmd_exists "${t}" || die "Feature 3 needs '${t}' installed locally."
    done

    _pick_instance || return 0
    local ip="${PICKED_IP}" label="${PICKED_LABEL}"
    printf '  Selected: %s (%s)\n\n' "${ip}" "${label}"

    _monitor_ssh_opts
    local key_file="/var/lib/session-file-server/key_ed25519"

    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '    [dry-run] ssh root@%s and stream: journalctl -u %s -f (ed25519 pubkey pinned on top)\n' \
            "${ip}" "${SERVICE_NAME}"
        return 0
    fi

    # Read the ed25519 pubkey (chars 65-128 of the key file). A failed SSH here is
    # our connectivity check.
    local pubkey
    if ! pubkey="$(ssh "${MON_SSH_OPTS[@]}" "root@${ip}" \
        "awk 'NR==1{print substr(\$0,65,64)}' ${key_file} 2>/dev/null")"; then
        die "Could not SSH to root@${ip}. Check your key (${TF_VULTR_SSH_KEY:-~/.ssh/id_ed25519}) and that the instance is up."
    fi
    pubkey="$(printf '%s' "${pubkey}" | tr -dc '0-9a-f')"
    [[ -n "${pubkey}" ]] || pubkey="<no key found — is the file server installed on this instance?>"

    if [[ ! -t 1 ]]; then
        # No terminal to pin a header on: just stream plainly, after showing the key.
        printf 'ed25519 pubkey: %s\n\n' "${pubkey}"
        ssh -tt "${MON_SSH_OPTS[@]}" "root@${ip}" \
            "journalctl -u ${SERVICE_NAME} -n 40 -f --no-pager --no-hostname" || true
        return 0
    fi

    _live_monitor "${ip}" "${label}" "${pubkey}"
}

# Restores the terminal (scroll region + cursor). Safe to call repeatedly and must
# not depend on any function-local state, since it runs from traps too.
_monitor_reset() { printf '\033[r\033[?25h' 2>/dev/null || true; }

# Pins a header (title + the ed25519 pubkey + a hint) and streams the journal
# below it, using a DECSTBM scroll region so the header never scrolls away. The
# header height is computed from the terminal width so the (long) pubkey line may
# wrap without the scroll region cutting into it.
_live_monitor() {
    local ip="$1" label="$2" pubkey="$3"

    # Use `stty size` (real TIOCGWINSZ) not `tput cols`: on macOS tput returns the
    # static terminfo default (80), not the live window width.
    local size rows cols
    size="$(stty size 2>/dev/null || true)"           # "rows cols"
    rows="${size%% *}"; cols="${size##* }"
    [[ "${rows}" =~ ^[0-9]+$ ]] || rows=24
    [[ "${cols}" =~ ^[0-9]+$ ]] || cols=80
    [[ "${rows}" -ge 8  ]] || rows=24
    [[ "${cols}" -ge 24 ]] || cols=80

    # Title and hint are truncated to one row; the pubkey is shown in full and may
    # wrap, so its height is measured and folded into the scroll-region top.
    local title="== session file server :: live log :: ${ip} (${label}) =="
    local hint="streaming journalctl -u ${SERVICE_NAME} -f    (press Ctrl-C to quit)"
    title="${title:0:${cols}}"
    hint="${hint:0:${cols}}"

    local pk_len=$(( 9 + ${#pubkey} ))            # "ed25519: " is 9 columns
    local pk_rows=$(( (pk_len + cols - 1) / cols ))
    [[ "${pk_rows}" -ge 1 ]] || pk_rows=1
    local region_top=$(( 2 + pk_rows + 1 ))       # title + pubkey(pk_rows) + hint, then +1

    trap '_monitor_reset' EXIT
    trap '_monitor_reset; exit 130' INT TERM

    # Set the scroll region first, then draw the header ABOVE it from home. The
    # header lines use \r\n and the last one has NO trailing newline, so nothing
    # scrolls before the cursor is dropped into the region -- that ordering is what
    # keeps the title row from being eaten.
    printf '\033[2J'                                                            # clear
    printf '\033[%d;%dr' "${region_top}" "${rows}"                              # scroll region [top..bottom]
    printf '\033[H'                                                             # home (row 1)
    printf '%s%s%s%s\033[K\r\n'      "${C_BOLD}" "${C_CYAN}"  "${title}"  "${C_RESET}"
    printf '%sed25519:%s %s%s%s\033[K\r\n' "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${pubkey}" "${C_RESET}"
    printf '%s%s%s\033[K'          "${C_DIM}"  "${hint}"   "${C_RESET}"
    printf '\033[%d;1H'  "${region_top}"                                        # cursor into the region

    # -tt forces a remote PTY so journalctl dies cleanly when we disconnect.
    ssh -tt "${MON_SSH_OPTS[@]}" "root@${ip}" \
        "journalctl -u ${SERVICE_NAME} -n 40 -f --no-pager --no-hostname" 2>&1 || true

    _monitor_reset
    trap - EXIT INT TERM
}
