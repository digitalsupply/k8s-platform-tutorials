locals {
  ssh_key = trimspace(file(var.ssh_public_key_path))
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.vms

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vmid

  # Keep the template's firmware/controller: the openEuler golden image is
  # provisioned for OVMF and uses a virtio-scsi-single controller.
  bios          = "ovmf"
  scsi_hardware = "virtio-scsi-single"

  # Clone the golden template. `full` produces an independent disk.
  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory
  }

  # The golden template exposes its cloud-init drive on scsi1 (virtio-scsi),
  # because an IDE cdrom is not detected by the openEuler guest.
  initialization {
    interface = "scsi1"

    dns {
      servers = [var.vm_dns]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.vm_prefix_length}"
        gateway = var.vm_gateway
      }
    }

    user_account {
      username = var.vm_user
      keys     = [local.ssh_key]
    }
  }

  network_device {
    bridge = var.vm_bridge
    model  = "virtio"
  }

  started = true
}
