output "instance_id" {
  description = "Vultr instance id."
  value       = vultr_instance.fileserver.id
}

output "instance_ip" {
  description = "External IPv4 address — point your DNS A record at this."
  value       = vultr_instance.fileserver.main_ip
}

output "instance_label" {
  value = vultr_instance.fileserver.label
}

# Note: the human-facing "next steps" guidance is printed by the launcher
# (setup.sh --tf-vultr) and documented in the README, so it is intentionally not
# a Terraform output here — that keeps `terraform apply`'s output compact.
