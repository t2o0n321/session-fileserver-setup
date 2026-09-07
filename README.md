# Session File Server — automated deployment

Deploys the [Session File Server](https://github.com/session-foundation/session-file-server)
onto an Ubuntu server and hands back the two values this fork's Android client
needs to use it. Built so a self-hosted operator can go from a bare VPS to a
working, TLS-terminated file server in one command — and re-run it safely.

Self-hosting keeps uploaded attachments on infrastructure you control instead of
the shared public file server (see `notes/6_自建SessionFileServer.md`).

---

## Two ways to deploy

- **On an Ubuntu server you already have** — run `setup.sh` directly (see
  [Quick start](#quick-start) below).
- **From scratch on Vultr** — the [`terraform/`](terraform/README.md) workflow
  provisions a `vc2-1c-1gb` instance, you point DNS at the IP it prints, then it
  runs `setup.sh` on the box and returns the Ed25519 public key. Two stages, with
  a manual DNS step between them. Drive it in one command from your own machine
  (needs Terraform installed locally):

  ```bash
  ./setup.sh --tf-vultr --vultr-api-key=xxxxxxxx
  #   choose 1) create instance  → prints external IP
  #   → add a DNS A record for that IP, wait for it to resolve
  ./setup.sh --tf-vultr --vultr-api-key=xxxxxxxx --domain files.example.org
  #   choose 2) install  → prints the Ed25519 public key
  ```

  `--tf-vultr` runs the workflow locally instead of installing on the current
  host (the two flags must be given together). The menu also offers **3)
  live-monitor a server's log** — pick an instance and it streams
  `journalctl -f` over SSH with the server's ed25519 pubkey pinned at the top.
  If an instance with the same name already exists, Feature 1 asks before
  creating another and, on approval, appends the next free number
  (`session-fileserver-2`, `-3`, …), each in its own Terraform workspace. You can
  also run the Terraform modules directly — full details in
  [terraform/README.md](terraform/README.md).

---

## Requirements

- **Ubuntu Server 24.04 (noble), 25.10 (questing) or 26.04 LTS (resolute)**, `amd64` or `arm64`.
  Other releases are refused unless you pass `--allow-unsupported-os`.
- Run as **root** (via `sudo`).
- A **domain name** with an `A`/`AAAA` record pointing at the server (required
  for the default Let's Encrypt TLS mode; skippable with `--skip-dns-check`).
- Outbound HTTPS (to `deb.oxen.io`, GitHub and PyPI) during installation.

`python3-session-util` comes from the Oxen apt repository; on 26.04 it is built
for Python 3.14, which the installer's system-site-packages virtualenv picks up
automatically.

---

## Quick start

```bash
sudo ./setup.sh --domain files.example.org --email you@example.org
```

This will, as ten idempotent steps:

1. **Preflight** — verify OS/arch/systemd/disk, that ports 80/443 are free, and
   that the domain resolves to this host.
2. **Packages** — register `deb.oxen.io` with a *scoped* signing key
   (`/etc/apt/keyrings`, `Signed-By`) and install nginx, PostgreSQL, uWSGI,
   Python and `python3-session-util`.
3. **Account & layout** — create the unprivileged `sfs` system account and the
   `/opt` (code), `/etc` (config) and `/var/lib` (state) directories.
4. **Source** — clone the file server at a **pinned commit** (override `--ref`).
5. **PostgreSQL** — create the `sfs` role and `sessionfiles` database (peer auth,
   no `pg_hba.conf` edit), load the schema **as the owner**, and seed the
   default storage pool.
6. **Application** — build the virtualenv, generate the server's Ed25519
   identity key (`0600`), and write `config.py`.
7. **Service** — install and start a hardened `systemd` unit running uWSGI.
8. **nginx + TLS** — reverse-proxy the socket and obtain a certificate.
9. **Firewall** — optional (`--firewall`); always allows SSH before enabling UFW.
10. **Verify** — probe the app over its socket and do an upload/download
    round-trip, then print the client configuration values.

### Point the client at it

The final summary prints exactly what to put in `session-android/.env.local`
(see `notes/98_環境變數.md`):

```dotenv
DEFAULT_FILE_SERVER_URL="https://files.example.org"
DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX="<printed by the installer>"
```

The client talks to the server exclusively over onion requests
(`POST /oxen/v4/lsrpc`), encrypting to the X25519 key derived from that Ed25519
public key, so both values must match the deployed server.

---

## Options

| Option | Meaning |
|---|---|
| `-d, --domain <fqdn>` | **Required.** Domain the server answers on. |
| `--tls <mode>` | `certbot` (default), `existing`, `self-signed`, or `none`. |
| `--email <addr>` | Contact address for Let's Encrypt. |
| `--cert <path>` / `--key <path>` | Certificate and key for `--tls existing`. |
| `--ref <git-ref>` | Upstream commit/tag/branch to deploy (default: pinned). |
| `--max-file-size <bytes>` | Upload limit (default `10000000`, matching the client). |
| `--processes <n>` | uWSGI worker processes (default `4`). |
| `--firewall` | Configure UFW (allows the detected SSH port first). |
| `--upgrade-system` | Run `apt upgrade` during install (off by default). |
| `--dry-run` | Print every change without making any. |
| `-y, --yes` | Assume "yes" for prompts (unattended). |
| `--skip-dns-check` | Do not require the domain to resolve here. |
| `--skip-selftest` | Skip the upload/download round-trip. |
| `--allow-unsupported-os` | Proceed on an untested OS/release. |
| `--uninstall` [`--purge`] | Remove the deployment (`--purge` also deletes data). |
| `-h, --help` / `-V, --version` | Help / version. |

### TLS modes

- **certbot** *(default)* — Let's Encrypt via the nginx plugin. Needs public DNS
  and port 80 reachable. Choosing this mode agrees to the Let's Encrypt ToS.
- **existing** — you supply `--cert` and `--key` (e.g. a wildcard cert).
- **self-signed** — generated locally; for testing only. An exit service node
  may reject an untrusted certificate.
- **none** — plain HTTP. Only sensible behind a separate TLS-terminating proxy.

---

## Operating it

```bash
systemctl status session-file-server      # health
journalctl -u session-file-server -f      # logs
systemctl restart session-file-server     # restart

# Update to a newer upstream revision:
sudo ./setup.sh --domain files.example.org --ref <commit> --skip-dns-check
```

- **Code**: `/opt/session-file-server` (root-owned; the service cannot rewrite it).
- **Config**: `/etc/session-file-server/` and `/opt/session-file-server/fileserver/config.py`.
- **State** (uploads + identity key): `/var/lib/session-file-server/` (`sfs`, `0700`).
- **Install log**: `/var/log/session-fileserver-setup.log`.

Re-running `setup.sh` is safe: existing accounts, databases, keys and configs are
detected and preserved, and unchanged files never trigger a service restart.

### Uninstall

```bash
sudo ./setup.sh --uninstall           # remove service/config/code; keep data
sudo ./setup.sh --uninstall --purge   # also drop the database, files and key
```

---

## Project layout

```
setup.sh                 Entry point: argument parsing and step orchestration.
src/lib/config.sh        All constants (paths, package lists, defaults).
src/lib/log.sh           Logging and fatal-error handling.
src/lib/ui.sh            Banner, step headers, summary.
src/lib/util.sh          run()/write_file() mutation wrappers + probes.
src/preflight.sh         Pre-change environment checks.
src/steps/NN_*.sh        One file per install step, in order.
src/uninstall.sh         Teardown.
test/                    Offline lint + Docker end-to-end test harness.
terraform/               Optional: provision a Vultr VPS and run setup.sh on it
                         (two-stage workflow — see terraform/README.md).
```

Every system change goes through `run()` or `write_file()`, which is what makes
`--dry-run` a faithful preview and re-runs idempotent.

---

## Notes

- The server enforces its own `MAX_FILE_SIZE`; the installer defaults it to
  10 MB to match the client, and nginx allows some headroom above it.
- `/session_version` returns `502` for the first minutes after start while the
  app fetches release metadata from GitHub — this is upstream behaviour and
  does not affect file upload/download.
- `POST /file` is unauthenticated by design (as on the official file server);
  nginx applies a light rate limit as defence-in-depth.
