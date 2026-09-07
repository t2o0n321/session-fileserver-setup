variable "instance_ip" {
  description = "External IP of the running instance to install the file server on."
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", var.instance_ip))
    error_message = "instance_ip must be an IPv4 address."
  }
}

variable "instance_label" {
  description = "Human label of the chosen instance (informational only)."
  type        = string
  default     = ""
}

variable "domain" {
  description = "Domain that already resolves to instance_ip (used for TLS and the client URL)."
  type        = string

  validation {
    condition     = can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$", var.domain))
    error_message = "domain must be a fully-qualified domain name, e.g. files.example.org."
  }
}

variable "email" {
  description = "Contact email for Let's Encrypt (blank registers without one)."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "SSH user on the instance (Vultr Ubuntu images default to root)."
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Private key matching the public key installed by Feature 1."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "setup_src" {
  description = "Path to the session-fileserver-setup repo root. Empty = auto-detect (../..)."
  type        = string
  default     = ""
}

variable "extra_setup_args" {
  description = "Extra flags passed through to setup.sh (e.g. --firewall, --tls self-signed)."
  type        = string
  default     = "--firewall"
}

variable "skip_dns_check" {
  description = "Pass --skip-dns-check to setup.sh (use only if a proxy sits in front)."
  type        = bool
  default     = false
}
