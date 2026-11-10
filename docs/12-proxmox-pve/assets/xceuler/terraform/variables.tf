variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint"
  type        = string
  default     = "https://127.0.0.1:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form user@realm!tokenid=secret"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name that hosts the VMs"
  type        = string
  default     = "teacher"
}

variable "template_vmid" {
  description = "VMID of the golden openEuler cloud-init template"
  type        = number
  default     = 9010
}

variable "vm_user" {
  description = "Cloud-init user created on every VM"
  type        = string
  default     = "hao"
}

variable "ssh_public_key_path" {
  description = "Public key injected into the cloud-init user account"
  type        = string
  default     = "/root/.ssh/id_rsa.pub"
}

variable "vm_bridge" {
  description = "Proxmox bridge for the VM network device"
  type        = string
  default     = "vmbr1"
}

variable "vm_gateway" {
  description = "Default gateway handed to the VMs"
  type        = string
  default     = "10.0.0.1"
}

variable "vm_dns" {
  description = "DNS server handed to the VMs"
  type        = string
  default     = "223.5.5.5"
}

variable "vm_prefix_length" {
  description = "Subnet prefix length for the VM addresses"
  type        = number
  default     = 24
}

variable "vm_cores" {
  description = "vCPUs per VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Dedicated memory (MiB) per VM"
  type        = number
  default     = 2048
}

variable "vms" {
  description = "VMs to create: hostname => { vmid, ip }"
  type = map(object({
    vmid = number
    ip   = string
  }))
  default = {
    web01  = { vmid = 125, ip = "10.0.0.7" }
    sweb01 = { vmid = 126, ip = "10.0.0.8" }
    lb01   = { vmid = 127, ip = "10.0.0.9" }
  }
}
