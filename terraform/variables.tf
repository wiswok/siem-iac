variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_user" {
  type = string
}

variable "proxmox_api_token" {
  type = string
}

variable "proxmox_api_tls_insecure" {
  type    = bool
  default = true
}

variable "proxmox_password" {
  type      = string
  sensitive = true
}

