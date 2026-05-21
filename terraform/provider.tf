terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.97.1"
    }
  }
}

provider "proxmox" {
  # Configuration options
  endpoint	= var.proxmox_api_url
  api_token	= "${var.proxmox_api_user}=${var.proxmox_api_token}"
  insecure	= var.proxmox_api_tls_insecure
  ssh {
    agent	= true
    username	= "root"
    password	= var.proxmox_password
  }
}
