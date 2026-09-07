# Feature 2: given an already-running instance (chosen interactively by
# select-instance.sh, or passed directly via -var), upload the
# session-fileserver-setup tree, run setup.sh over SSH, and surface the server's
# ed25519 public key as a Terraform output.
#
# The interactive "list instances and pick one" step lives in select-instance.sh
# because Terraform cannot render a dynamic menu mid-run; everything else — the
# provisioning and the returned key — is Terraform.

locals {
  # Root of the session-fileserver-setup repo (this module is at terraform/2-fileserver).
  setup_src   = var.setup_src != "" ? var.setup_src : abspath("${path.module}/../..")
  sudo_prefix = var.ssh_user == "root" ? "" : "sudo "
  email_arg   = var.email != "" ? "--email ${var.email}" : ""
  dns_arg     = var.skip_dns_check ? "--skip-dns-check" : ""
}

resource "null_resource" "setup" {
  # Re-provision when the target, the domain, or setup.sh itself changes. setup.sh
  # is idempotent, so re-runs are safe.
  triggers = {
    instance_ip = var.instance_ip
    domain      = var.domain
    setup_hash  = filemd5("${local.setup_src}/setup.sh")
  }

  connection {
    type        = "ssh"
    host        = var.instance_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  # File provisioners need the parent directory to exist first.
  provisioner "remote-exec" {
    inline = ["mkdir -p /root/session-fileserver-setup"]
  }

  # Upload only what setup.sh needs — not the whole repo (no .git, no terraform/).
  provisioner "file" {
    source      = "${local.setup_src}/setup.sh"
    destination = "/root/session-fileserver-setup/setup.sh"
  }
  provisioner "file" {
    source      = "${local.setup_src}/art.txt"
    destination = "/root/session-fileserver-setup/art.txt"
  }
  provisioner "file" {
    # No trailing slash: uploads the directory as /root/session-fileserver-setup/src
    source      = "${local.setup_src}/src"
    destination = "/root/session-fileserver-setup"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /root/session-fileserver-setup/setup.sh",
      "cd /root/session-fileserver-setup && ${local.sudo_prefix}./setup.sh --domain ${var.domain} ${local.email_arg} ${local.dns_arg} ${var.extra_setup_args} --yes",
    ]
  }
}

# Read the server's ed25519 public key back out, after setup has run, and expose
# it as an output. The key file is `seed_hex(64) || pubkey_hex(64)`, so the
# ed25519 public key is characters 65-128 of the first line.
data "external" "pubkey" {
  depends_on = [null_resource.setup]

  program = ["bash", "${path.module}/scripts/read_pubkey.sh"]

  query = {
    host    = var.instance_ip
    user    = var.ssh_user
    ssh_key = pathexpand(var.ssh_private_key_path)
  }
}
