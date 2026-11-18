#!/usr/bin/env bash
#
# Full install inside a throwaway Ubuntu 26.04 systemd container, then a re-run
# to prove idempotency, then --uninstall --purge. Requires Docker.
#
#   ./test/e2e-docker.sh [ubuntu-tag]   (default: 26.04)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG="${1:-26.04}"
IMG="sfs-e2e-test:${TAG}"
NAME="sfs-e2e-$$"

command -v docker >/dev/null || { echo "docker required"; exit 1; }

echo "== building systemd image (${IMG}) =="
docker build -q -t "${IMG}" - >/dev/null <<EOF
FROM ubuntu:${TAG}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo curl ca-certificates gnupg git iproute2 openssh-server \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== starting container =="
docker run -d --name "${NAME}" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$PWD":/installer:ro "${IMG}" >/dev/null
sleep 5

run() { docker exec "${NAME}" bash -c "cd /installer && $*"; }

echo "== install =="
run "./setup.sh --domain files.test.local --tls self-signed --skip-dns-check --yes"
run "source src/lib/config.sh && sshd -T | grep -qx \"macs \${SSHD_MACS}\""
echo "  ok  sshd negotiates only the configured MACs"
echo "== re-run (idempotency) =="
run "./setup.sh --domain files.test.local --tls self-signed --skip-dns-check --yes"
echo "== uninstall --purge =="
run "./setup.sh --uninstall --purge --yes"
run "source src/lib/config.sh && test ! -e \"\${SSHD_DROPIN}\""
echo "  ok  sshd drop-in removed"
echo "ALL PASS"
