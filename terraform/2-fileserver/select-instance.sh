#!/usr/bin/env bash
#
# Feature 2 launcher. Lists the running instances on your Vultr account, lets you
# pick one, then runs `terraform apply` to install the session file server on it
# and prints the server's ed25519 public key.
#
# Requires: VULTR_API_KEY in the environment, plus curl, jq, terraform and ssh.
#
# Usage:
#   export VULTR_API_KEY=xxxx
#   ./select-instance.sh --domain files.example.org [--email you@example.org] [--extra "--firewall"]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VULTR_API_KEY:?Set VULTR_API_KEY to your Vultr API key}"
for bin in curl jq terraform ssh; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

domain="" email="" extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="${2:?}"; shift 2 ;;
    --email)  email="${2:?}"; shift 2 ;;
    --extra)  extra="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "Fetching running instances from Vultr..."
json="$(curl -fsS -H "Authorization: Bearer ${VULTR_API_KEY}" "https://api.vultr.com/v2/instances")"
# Portable read loop instead of `mapfile` (bash 4+) so this runs on macOS's bash 3.2.
rows=()
while IFS= read -r _line; do
  rows+=("$_line")
done < <(jq -r '.instances[] | [.id, .main_ip, (.label // "-"), .region, .power_status, (.os // "-")] | @tsv' <<<"$json")
count="${#rows[@]}"
[ "$count" -gt 0 ] || { echo "No instances found on this account." >&2; exit 1; }

echo
echo "Select the instance to install the session file server on:"
i=1
for r in "${rows[@]}"; do
  # shellcheck disable=SC2034  # positional TSV destructuring; not all fields used
  IFS=$'\t' read -r id ip label region power os <<<"$r"
  printf '  %2d) %-15s  %-24s  %-6s  %-9s  %s\n' "$i" "$ip" "$label" "$region" "$power" "$os"
  i=$((i + 1))
done
echo
read -r -p "Enter number [1-${count}]: " choice
[[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] \
  || { echo "Invalid selection." >&2; exit 2; }

# shellcheck disable=SC2034  # positional TSV destructuring; not all fields used
IFS=$'\t' read -r sel_id sel_ip sel_label sel_region sel_power sel_os <<<"${rows[$((choice - 1))]}"
echo "Selected: ${sel_ip}  (${sel_label}, ${sel_region})"
echo

[ -n "$domain" ] || read -r -p "Domain that already points at ${sel_ip}: " domain
[ -n "$domain" ] || { echo "A domain is required." >&2; exit 2; }
[ -n "$email" ]  || read -r -p "Email for Let's Encrypt (blank to skip): " email

cd "$here"
terraform init -input=false >/dev/null

terraform apply \
  -var "instance_ip=${sel_ip}" \
  -var "instance_label=${sel_label}" \
  -var "domain=${domain}" \
  -var "email=${email}" \
  ${extra:+-var "extra_setup_args=${extra}"}

pubkey="$(terraform output -raw ed25519_pubkey)"
echo
echo "==================================================================="
echo " Session file server installed on ${sel_ip}  (https://${domain})"
echo
echo " ed25519 public key:"
echo "   ${pubkey}"
echo
echo " Put these in session-android/.env.local:"
echo "   DEFAULT_FILE_SERVER_URL=\"https://${domain}\""
echo "   DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX=\"${pubkey}\""
echo "==================================================================="
