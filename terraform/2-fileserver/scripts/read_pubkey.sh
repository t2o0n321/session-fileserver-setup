#!/usr/bin/env bash
#
# Terraform `external` data source helper. Reads a JSON query on stdin
# ({host,user,ssh_key}), SSHes into the server, extracts the ed25519 public key
# from the identity key file, and prints {"ed25519_pubkey":"..."} on stdout.
#
# The key file written by setup.sh is `seed_hex(64) || pubkey_hex(64)` on line 1,
# so the ed25519 public key is characters 65-128.
set -euo pipefail

eval "$(jq -r '@sh "SFS_HOST=\(.host) SFS_USER=\(.user) SFS_KEY=\(.ssh_key)"')"

key_file="/var/lib/session-file-server/key_ed25519"
read_cmd="awk 'NR==1{print substr(\$0,65,64)}' ${key_file}"

# root reads the 0600 key directly; a non-root sudoer falls back to sudo.
remote="${read_cmd} 2>/dev/null || sudo ${read_cmd}"

pub="$(ssh -i "${SFS_KEY}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 \
        "${SFS_USER}@${SFS_HOST}" "${remote}" 2>/dev/null | tr -dc '0-9a-f')"

if [ "${#pub}" -ne 64 ]; then
  echo "read_pubkey: could not read a 64-char ed25519 pubkey from ${key_file} on ${SFS_HOST}" >&2
  echo "read_pubkey: is the file server installed and reachable over SSH?" >&2
  exit 1
fi

jq -n --arg k "${pub}" '{ed25519_pubkey: $k}'
