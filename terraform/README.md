# Terraform — Vultr + Session File Server

Two-stage Terraform workflow to stand up a Vultr instance and install the
[session file server](../README.md) on it.

The two stages are deliberately separate because a **manual DNS step sits between
them**: Feature 1 gives you an IP, you point a domain at it yourself, and once
that has propagated you run Feature 2.

```
Feature 1 (terraform)          you (manual)              Feature 2 (terraform)
─────────────────────    ─────────────────────      ──────────────────────────
create Vultr instance  →  note the IP, add a DNS  →  pick instance, run setup.sh,
output external IP         A record, wait for it       get the ed25519 pubkey
```

> **Why Feature 2 has a launcher script.** Terraform is declarative and can't
> render an interactive "pick one of these instances" menu mid-run. So the
> listing + selection lives in `select-instance.sh`; it then calls
> `terraform apply`, which does the real work (upload + run `setup.sh`) and
> returns the pubkey as a normal Terraform output. You can also skip the launcher
> and pass `-var instance_ip=... -var domain=...` directly.

> **Shortcut.** From the repo root you can drive both features without `cd`-ing
> in here: `./setup.sh --tf-vultr --vultr-api-key=<key>` prompts for Feature 1,
> 2, or 3 (live-monitor a server's log, ed25519 pubkey pinned on top) and runs
> the same Terraform under the hood (add `--domain <fqdn>` for Feature 2). The
> commands below are the direct, no-wrapper equivalent.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.3
- A Vultr API key: `export VULTR_API_KEY=xxxxxxxx`
- An SSH key pair (default paths `~/.ssh/id_ed25519[.pub]`)
- For Feature 2's launcher: `curl`, `jq`, `ssh`

## Feature 1 — create the instance

Spec matches the console screenshot: **Shared CPU `vc2-1c-1gb`** (1 vCPU / 1 GB /
25 GB SSD) in **Seoul (`icn`)**, backups disabled.

```bash
cd 1-instance
export VULTR_API_KEY=xxxxxxxx
terraform init
terraform apply            # prints the external IP
```

Then, **manually**:

1. Create a DNS `A` record: `files.example.org → <the IP that was printed>`
2. Wait for it to take effect: `dig +short files.example.org` returns that IP.

Re-print the values any time with `terraform output`.

**Duplicate names.** Via `setup.sh --tf-vultr`, Feature 1 first checks the
account for an instance with the same label. If one exists it asks whether to
continue and, on approval, uses the next free suffix (`session-fileserver-2`,
`-3`, …) — each instance in its own Terraform workspace, so a new one never
renames or replaces an existing one. (Running `terraform apply` directly in
`1-instance` does not do this check; it manages a single instance in the current
workspace.)

## Feature 2 — install the file server

After DNS resolves:

```bash
cd ../2-fileserver
export VULTR_API_KEY=xxxxxxxx
./select-instance.sh --domain files.example.org --email you@example.org
```

The launcher lists every running instance on the account, you pick the one you
just created, and Terraform then:

1. uploads `setup.sh` + `src/` to the instance,
2. runs `setup.sh --domain files.example.org --email … --firewall --yes`
   (obtains a Let's Encrypt cert, starts the service, self-tests an upload),
3. reads back and prints the server's **ed25519 public key**.

Paste the result into `session-android/.env.local`:

```dotenv
DEFAULT_FILE_SERVER_URL="https://files.example.org"
DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX="<printed by Terraform>"
```

### Non-interactive Feature 2

```bash
cd 2-fileserver
terraform init
terraform apply -var instance_ip=203.0.113.10 -var domain=files.example.org -var email=you@example.org
terraform output -raw ed25519_pubkey
```

### Useful flags (`--extra` for the launcher, or `-var extra_setup_args=…`)

| Want | Pass |
|---|---|
| Skip the firewall step | `-var extra_setup_args=""` |
| Self-signed cert (testing) | `-var extra_setup_args="--tls self-signed" -var skip_dns_check=true` |
| A specific upstream commit | `-var extra_setup_args="--ref <commit>"` |

## Files

```
terraform/
├── 1-instance/            Feature 1: create the instance, output the IP
│   ├── main.tf  variables.tf  outputs.tf  versions.tf
│   └── terraform.tfvars.example
└── 2-fileserver/          Feature 2: install the file server, output the pubkey
    ├── main.tf  variables.tf  outputs.tf  versions.tf
    ├── select-instance.sh          interactive launcher (list + pick)
    └── scripts/read_pubkey.sh      external data source: reads the pubkey back
```

## Notes

- State files can contain the API key and IPs — the bundled `.gitignore` keeps
  `*.tfstate*` and `*.tfvars` out of git. Commit only `*.tfvars.example`.
- Feature 2 is independent of Feature 1's state: it operates on whichever running
  instance you pick, so you can also target an instance created another way.
- `setup.sh` is idempotent, so re-running Feature 2 against the same box is safe.
- Ubuntu 24.04 is the default image; override with `-var os_name=` in Feature 1
  (`setup.sh` also supports 25.10 and 26.04).
- **Duplicate names** are detected and suffixed (`-2`, `-3`, …) with one
  workspace per instance — see [Feature 1](#feature-1--create-the-instance)
  above. `terraform workspace list` shows them.

## Troubleshooting

**`Error: ... {"error":"Unauthorized IP address: <ip>","status":401}`**
Vultr restricts the API to an IP allowlist and your current public IP isn't on
it — most often because a VPN changed your egress IP. Add it under
**Account → API → Access Control** (https://my.vultr.com/settings/#settingsapi),
e.g. `<ip>/32`, or turn the VPN off if your real IP is already allowed, then
re-run. Read calls (like the `vultr_os` lookup) can succeed while writes fail, so
this typically shows up only at `apply`. Nothing is created before the failing
call, so the state stays clean for a retry.

**`Error: ... no OS found` / empty `vultr_os` result**
`var.os_name` didn't exactly match a Vultr image name. Override it, e.g.
`-var os_name="Ubuntu 24.04 LTS x64"`.

**`apply` hangs during Feature 2's setup step**
That is `setup.sh` running `apt`/`certbot` on the box (several minutes). If it
stalls specifically at the firewall step, re-run with `-var extra_setup_args=""`.

**Feature 2 finishes but warns `TLS is NOT active` / certbot's challenge timed out**
Let's Encrypt (and the Session client) need ports **80 and 443 reachable from the
internet**. A common cause is a Vultr **Firewall Group** attached to the instance
blocking them. The install still completes and prints the ed25519 pubkey (the
server works over HTTP), but the client cannot use it until TLS is up:
1. Allow inbound TCP 80 and 443 (Vultr firewall group, and `ufw status` on the box).
2. On the server: `certbot --nginx -d <your-domain>`
3. Confirm `https://<your-domain>/` responds.
The server's identity key is preserved across re-runs, so the pubkey does not change.
