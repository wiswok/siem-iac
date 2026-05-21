############################
# SSH KEYS
############################
data "local_file" "ssh_public_key_ansible" {
  filename = pathexpand("~/.ssh/id_ed25519.pub")
}

data "local_file" "ssh_public_key_arodper" {
  filename = pathexpand("~/.ssh/id_ed25519_ops.pub")
}

############################
# DEFINICIÓN DE VMS
############################
locals {
  vms = {
    sec_core = {
      name    = "sec-core"
      node    = "pve1"
      ip      = "10.10.30.10"
      cores   = 8
      memory  = 32768
      disk    = 100
      vlan    = 30
      gateway = "10.10.30.1"
      dns     = ["10.10.30.1"]
      tags    = ["siem", "security", "elk"]
      groups  = ["elk", "wazuh"]
    }

    obs_core = {
      name    = "obs-core"
      node    = "pve2"
      ip      = "10.10.30.20"
      cores   = 4
      memory  = 8192
      disk    = 50
      vlan    = 30
      gateway = "10.10.30.1"
      dns     = ["10.10.30.1"]
      tags    = ["siem", "monitoring", "observability"]
      groups  = ["monitoring", "wazuh_agents"]
    }

    ids_core = {
      name    = "ids-core"
      node    = "pve3"
      ip      = "10.10.30.30"
      cores   = 4
      memory  = 8192
      disk    = 50
      vlan    = 30
      gateway = "10.10.30.1"
      dns     = ["10.10.30.1"]
      tags    = ["siem", "ids", "suricata"]
      groups  = ["suricata", "wazuh_agents"]
    }

    edge_core = {
      name    = "edge-core"
      node    = "pve2"
      ip      = "10.10.30.5"
      cores   = 2
      memory  = 2048
      disk    = 20
      vlan    = 30
      gateway = "10.10.30.1"
      dns     = ["10.10.30.1"]
      tags    = ["siem", "edge", "traefik"]
      groups  = ["edge"]
    }

  }

  # Conjunto de nodos únicos para descargar la imagen
  nodes = toset([for vm in local.vms : vm.node])

  # Hosts externos no gestionados por Terraform pero sí por Ansible.
  # gitlab-core vive fuera del clúster (10.10.10.0/24) y solo recibe el agente Wazuh.
  external_hosts = {
    gitlab_core = {
      name = "gitlab-core"
      ip   = "10.10.10.40"
    }
  }

  # Grupos del inventario de Ansible
  ansible_groups = {
    elk          = ["sec_core"]
    wazuh        = ["sec_core"]
    monitoring   = ["obs_core"]
    suricata     = ["ids_core"]
    wazuh_agents = ["obs_core", "ids_core", "gitlab_core"]
    edge         = ["edge_core"]
    elastalert   = ["sec_core"]
  }

  # Mapa combinado (VMs gestionadas + hosts externos) para el render del inventario
  ansible_hosts = merge(
    { for k, v in local.vms : k => { name = v.name, ip = v.ip } },
    local.external_hosts,
  )

  ansible_inventory = <<-EOT
[all:vars]
ansible_user=ansible
ansible_become=true
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_private_key_file=~/.ssh/id_ed25519

[all]
%{for host_key, host in local.ansible_hosts ~}
${host.name} ansible_host=${host.ip}
%{endfor ~}

[elk]
%{for host_key in local.ansible_groups.elk ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[wazuh]
%{for host_key in local.ansible_groups.wazuh ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[monitoring]
%{for host_key in local.ansible_groups.monitoring ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[suricata]
%{for host_key in local.ansible_groups.suricata ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[wazuh_agents]
%{for host_key in local.ansible_groups.wazuh_agents ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[edge]
%{for host_key in local.ansible_groups.edge ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}

[elastalert]
%{for host_key in local.ansible_groups.elastalert ~}
${local.ansible_hosts[host_key].name}
%{endfor ~}
EOT
}

############################
# DESCARGA DE IMAGEN POR NODO
############################
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each = local.nodes

  content_type = "import"
  datastore_id = "local"
  node_name    = each.value

  url       = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  file_name = "jammy-server-cloudimg-amd64.qcow2"
}

############################
# CLOUD-INIT SNIPPETS
############################
resource "proxmox_virtual_environment_file" "cloudinit" {
  for_each = local.vms

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = <<EOF
#cloud-config
hostname: ${each.value.name}
fqdn: ${each.value.name}.lab.wiswok.net
manage_etc_hosts: true
timezone: Europe/Madrid

users:
  - default

  - name: ansible
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key_ansible.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL

  - name: arodper
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ${trimspace(data.local_file.ssh_public_key_arodper.content)}
    sudo: ALL=(ALL) NOPASSWD:ALL

package_update: true
packages:
  - qemu-guest-agent
  - curl
  - python3
  - python3-apt
  - net-tools

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

    file_name = "${each.value.name}-cloud-config.yaml"
  }
}

############################
# CREACIÓN DE LAS VMS
############################
resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  name      = each.value.name
  node_name = each.value.node
  tags      = each.value.tags

  started = true
  on_boot = true

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.node].id
    interface    = "virtio0"
    size         = each.value.disk
    iothread     = true
    discard      = "on"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = each.value.gateway
      }
    }

    dns {
      servers = each.value.dns
      domain  = "lab.wiswok.net"
    }

    user_data_file_id = proxmox_virtual_environment_file.cloudinit[each.key].id
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    vlan_id  = each.value.vlan
    firewall = false
  }
}

############################
# INVENTARIO DE ANSIBLE
############################
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.ini"
  content  = local.ansible_inventory
}

############################
# OUTPUTS
############################
output "vm_ips" {
  value = {
    for k, vm in local.vms : k => vm.ip
  }
}

output "ansible_inventory_path" {
  value = local_file.ansible_inventory.filename
}
