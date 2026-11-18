#!/usr/bin/env bash
#
# Every constant the installer relies on lives here, so auditing "what does this
# script touch on my server" is a single-file read.  Nothing in this file runs
# commands or has side effects.

# --------------------------------------------------------------------------
# Installer identity
# --------------------------------------------------------------------------
readonly INSTALLER_VERSION="2.0.0"

# --------------------------------------------------------------------------
# Upstream source
# --------------------------------------------------------------------------
readonly UPSTREAM_REPO_URL="https://github.com/session-foundation/session-file-server.git"

# Upstream publishes no tags and its default branch (`dev`) moves under us, so we
# pin a reviewed commit instead of deploying whatever HEAD happens to be.
# 45534715 = "Merge pull request #8 from jagerman/storage-pools" (2025-12-02),
# the revision this installer was validated against.  Override with --ref.
readonly UPSTREAM_DEFAULT_REF="45534715dc755943527ec5e22778bfb5e67285d0"

# --------------------------------------------------------------------------
# Filesystem layout
#
# Code, state and runtime data are deliberately separated: the service account
# cannot rewrite its own code, and nothing lives under a human user's $HOME (so
# no `chmod o+x /home/you` is ever needed to let nginx reach the socket).
# --------------------------------------------------------------------------
readonly CODE_DIR="/opt/session-file-server"          # git checkout + venv, root-owned
readonly VENV_DIR="${CODE_DIR}/venv"
readonly APP_CONFIG_FILE="${CODE_DIR}/fileserver/config.py"

readonly STATE_DIR="/var/lib/session-file-server"     # private to the service account
readonly FILES_DIR="${STATE_DIR}/files"               # FILE_BASE_PATH, must pre-exist
readonly SERVER_KEY_FILE="${STATE_DIR}/key_ed25519"   # the server's identity key

readonly CONF_DIR="/etc/session-file-server"
readonly UWSGI_INI_FILE="${CONF_DIR}/uwsgi.ini"

readonly RUNTIME_DIR_NAME="session-file-server"       # systemd RuntimeDirectory=
readonly SOCKET_PATH="/run/${RUNTIME_DIR_NAME}/sfs.sock"

readonly SETUP_LOG_FILE="/var/log/session-fileserver-setup.log"

# --------------------------------------------------------------------------
# Service identity
# --------------------------------------------------------------------------
readonly SERVICE_NAME="session-file-server"
readonly SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SERVICE_USER="sfs"
readonly SERVICE_GROUP="sfs"
readonly WEB_GROUP="www-data"                         # nginx's group; owns the socket

# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------
readonly DB_NAME="sessionfiles"
readonly DB_USER="${SERVICE_USER}"                    # peer auth: role name == OS user
readonly DB_DEFAULT_POOL="default"

# --------------------------------------------------------------------------
# nginx
# --------------------------------------------------------------------------
readonly NGINX_SITE_NAME="session-file-server"
readonly NGINX_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
readonly NGINX_SNIPPET_TLS="/etc/nginx/snippets/${NGINX_SITE_NAME}-tls.conf"
readonly SELF_SIGNED_CERT="/etc/ssl/certs/${NGINX_SITE_NAME}-selfsigned.crt"
readonly SELF_SIGNED_KEY="/etc/ssl/private/${NGINX_SITE_NAME}-selfsigned.key"

# Must comfortably exceed MAX_FILE_SIZE once onion-request framing is added,
# otherwise nginx rejects a legitimate upload with 413 before the app sees it.
readonly NGINX_MAX_BODY_SIZE="16m"

# --------------------------------------------------------------------------
# sshd
# --------------------------------------------------------------------------
# Encrypt-then-MAC with SHA-2 or 128-bit UMAC only: drops the hmac-sha1 and
# 64-bit-tag umac-64 MACs that stock OpenSSH still offers.
readonly SSHD_MACS="hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com"
# sshd keeps the first value it reads and Ubuntu's sshd_config includes
# sshd_config.d/*.conf at the top, so a low number puts this ahead of most files.
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-session-file-server.conf"

# --------------------------------------------------------------------------
# APT: the Oxen repository supplies python3-session-util
# --------------------------------------------------------------------------
readonly OXEN_KEY_URL="https://deb.oxen.io/pub.gpg"
readonly OXEN_KEYRING="/etc/apt/keyrings/deb.oxen.io.gpg"
readonly OXEN_SOURCES_FILE="/etc/apt/sources.list.d/oxen.sources"
# Jason Rhinelander <jason@session.foundation>; verified against the key served
# at $OXEN_KEY_URL.  Checked after download so a swapped key aborts the install.
readonly OXEN_KEY_FINGERPRINT="66361D8E3C96E41C6DCB7051C4992CE7A88D4262"
# Used when deb.oxen.io has no suite matching this release's codename.
readonly OXEN_SUITE_FALLBACK="noble"

# Ubuntu releases this installer has been exercised against.
readonly SUPPORTED_UBUNTU_CODENAMES="noble questing resolute"

# Base packages.  `python3-venv` (not python3.NN-venv) tracks whatever the
# release's default interpreter is -- 26.04 ships 3.14, so a hardcoded
# python3.12-venv does not exist there.
readonly APT_PACKAGES=(
    ca-certificates
    curl
    git
    gnupg
    openssl
    nginx
    postgresql
    postgresql-client
    python3
    python3-coloredlogs
    python3-flask
    python3-pip
    python3-session-util
    python3-systemd
    python3-uwsgidecorators
    python3-venv
    ufw
    uwsgi-core
    uwsgi-plugin-python3
)

# Only installed when TLS is provisioned with certbot.
readonly APT_PACKAGES_CERTBOT=(certbot python3-certbot-nginx)

# Installed into the venv.  Upstream needs psycopg 3.x -- explicitly *not* the
# distro's psycopg2.  Pure-python wheels, so no compiler is required; libpq
# comes from postgresql-client.
readonly PIP_PACKAGES=(coloredlogs psycopg psycopg_pool pynacl requests)

# --------------------------------------------------------------------------
# Defaults for command-line options
# --------------------------------------------------------------------------
readonly DEFAULT_TLS_MODE="certbot"
# Upstream's sample defaults to 6 MB, but this fork's client advertises a 10 MB
# attachment limit (FileServerApis.MAX_FILE_SIZE), so a 6 MB server would 413
# uploads the client happily offered.  Override with --max-file-size.
readonly DEFAULT_MAX_FILE_SIZE="10000000"
readonly DEFAULT_UWSGI_PROCESSES="4"
