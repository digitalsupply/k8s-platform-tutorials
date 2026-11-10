output "vms" {
  description = "Map of hostname => VM connection details"
  value = {
    for name, vm in proxmox_virtual_environment_vm.node : name => {
      vmid = vm.vm_id
      ip   = var.vms[name].ip
      user = var.vm_user
    }
  }
}
