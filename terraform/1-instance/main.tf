# Feature 1: create a single Vultr Cloud Compute (Shared CPU) instance matching
# the spec in the console screenshot — vc2-1c-1gb in Seoul (icn) — and output its
# external IP so the developer can point DNS at it.

provider "vultr" {
  # Falls back to the VULTR_API_KEY environment variable when var.vultr_api_key
  # is null (the recommended way to pass the key — keeps it out of state files).
  api_key = var.vultr_api_key
}

# Resolve the OS id by name so we never hardcode a numeric id that Vultr may change.
data "vultr_os" "ubuntu" {
  filter {
    name   = "name"
    values = [var.os_name]
  }
}

# Register the developer's public key so Feature 2 can SSH in with the matching
# private key. One resource per apply; destroying the module removes it again.
resource "vultr_ssh_key" "dev" {
  name    = "${var.label}-terraform"
  ssh_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "vultr_instance" "fileserver" {
  region      = var.region # icn = Seoul, KR
  plan        = var.plan   # vc2-1c-1gb = 1 vCPU / 1 GB / 25 GB SSD
  os_id       = data.vultr_os.ubuntu.id
  label       = var.label
  hostname    = var.hostname != "" ? var.hostname : var.label
  tags        = var.tags
  enable_ipv6 = var.enable_ipv6

  # Matches the screenshot: Automatic Backups disabled.
  backups          = "disabled"
  activation_email = false

  ssh_key_ids = [vultr_ssh_key.dev.id]
}
