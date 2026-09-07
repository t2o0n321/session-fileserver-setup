output "ed25519_pubkey" {
  description = "The file server's ed25519 public key — put this in the client's .env."
  value       = data.external.pubkey.result.ed25519_pubkey
}

output "fileserver_url" {
  value = "https://${var.domain}"
}

output "client_env" {
  description = "Lines to paste into session-android/.env.local."
  value       = <<-EOT
    DEFAULT_FILE_SERVER_URL="https://${var.domain}"
    DEFAULT_FILE_SERVER_ED25519_PUBKEY_HEX="${data.external.pubkey.result.ed25519_pubkey}"
  EOT
}
