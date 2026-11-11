# 示例：从 PVE 模板/云镜像克隆出不可变镜像。
# 需要：packer >= 1.16 + packer-plugin-proxmox >= 1.2.4；token 需替换。

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

source "proxmox-clone" "openeuler" {
  proxmox_url              = "https://127.0.0.1:8006/api2/json"
  username                 = "terraform@pve!terraform"
  token                    = "<redacted-proxmox-api-token>"
  node                     = "teacher"
  clone_vm                 = "tmpl-openeuler2403"
  template_name            = "tmpl-openeuler-packer"
  vm_id                    = 130
  ssh_username             = "hao"
  ssh_private_key_file     = "/root/.ssh/id_rsa"
  insecure_skip_tls_verify = true
}

build {
  sources = ["source.proxmox-clone.openeuler"]
  provisioner "shell" {
    inline = ["cloud-init status --long || true", "sudo dnf -y install qemu-guest-agent || true"]
  }
}
