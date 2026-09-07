variable "vultr_api_key" {
  description = "Vultr API key. Leave null to use the VULTR_API_KEY environment variable."
  type        = string
  default     = null
  sensitive   = true
}

variable "region" {
  description = "Vultr region id. icn = Seoul, KR."
  type        = string
  default     = "icn"
}

variable "plan" {
  description = "Vultr plan id. vc2-1c-1gb = Shared CPU, 1 vCPU, 1 GB, 25 GB SSD."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "os_name" {
  description = "Exact Vultr OS name to deploy. Must be an Ubuntu release supported by setup.sh (24.04/25.10/26.04)."
  type        = string
  default     = "Ubuntu 24.04 LTS x64"
}

variable "label" {
  description = "Instance label shown in the Vultr console."
  type        = string
  default     = "session-fileserver"
}

variable "hostname" {
  description = "Instance hostname. Defaults to the label when empty."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to attach to the instance."
  type        = list(string)
  default     = ["session-fileserver"]
}

variable "enable_ipv6" {
  description = "Assign an IPv6 address as well as IPv4."
  type        = bool
  default     = false
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to install on the instance (Feature 2 uses the matching private key)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
