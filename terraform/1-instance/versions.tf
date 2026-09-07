terraform {
  required_version = ">= 1.3.0"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.21"
    }
  }
}
