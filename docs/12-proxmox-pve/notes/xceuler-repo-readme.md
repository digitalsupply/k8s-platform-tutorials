# openEuler VMs on Proxmox — Terraform + cloud-init + Ansible

Batch-provision three openEuler 24.03 LTS-SP4 cloud VMs on the Proxmox node
`teacher` using a golden cloud-init template, Terraform (bpg/proxmox),
and Ansible for post-configuration.

| Hostname | VMID | IP        | vCPU | RAM   | User  |
|----------|------|-----------|------|-------|-------|
| web01    | 125  | 10.0.0.7  | 2    | 2 GiB | hao   |
| sweb01   | 126  | 10.0.0.8  | 2    | 2 GiB | hao   |
| lb01     | 127  | 10.0.0.9  | 2    | 2 GiB | hao   |

All hosts use SSH **key-only** authentication (password auth disabled) and
`hao` has passwordless `sudo`.

## Layout

```
/root/xceuler/
├── images/                 # source openEuler cloud qcow2 (+ sha256)
├── terraform/              # VM creation from the golden template
│   ├── versions.tf         # bpg/proxmox provider + filesystem mirror
│   ├── variables.tf
│   ├── main.tf             # for_each web01/sweb01/lb01
│   ├── outputs.tf
│   └── terraform.tfvars    # API endpoint/token, node, template VMID
└── ansible/                # post-boot configuration
    ├── ansible.cfg
    ├── inventory.ini
    └── playbook.yml
```

## Golden template

* **VMID 9010** `tmpl-openeuler2403` — openEuler 24.03 LTS-SP4 cloud image
  with `cloud-init`, `hostname`, and `qemu-guest-agent` baked in, sysprepped
  (empty `machine-id`, no SSH host keys, no cloud-init state).
* Cloud-init drive is attached on **scsi1** (virtio-scsi); an IDE cdrom is
  *not* detected by the guest.
* Firmware is **OVMF** and the controller is **virtio-scsi-single**, both
  preserved by `main.tf`.
* The template deliberately has **no `searchdomain`** so cloud-init sets the
  short hostname (e.g. `web01`), not an FQDN.

## Usage

Terraform (run on the Proxmox node):

```sh
cd /root/xceuler/terraform
terraform init
terraform plan
terraform apply -auto-approve
terraform output
```

Ansible (post-configuration; idempotent):

```sh
cd /root/xceuler/ansible
ansible-playbook playbook.yml
```

The playbook enforces the short hostname, key-only sshd, passwordless sudo
for `hao`, `/etc/hosts`, and keeps `qemu-guest-agent` running.

## Verification

```sh
ssh -i /root/.ssh/id_rsa hao@10.0.0.7 'hostname; hostname -I; sudo -n true && echo sudo-ok'
```

Expected: `web01`, `10.0.0.7`, `sudo-ok` (same pattern for sweb01/lb01).

## Notes / gotchas

* **Provider install:** GitHub release downloads are blocked on this host;
  the bpg/proxmox provider is fetched via `gh-proxy.com` and installed into a
  filesystem mirror configured in `/root/.terraformrc` +
  `/root/.terraform.d/plugins`.
* **Existing `db01`:** an unrelated VM **118** is still named `db01`
  (IP 10.0.0.51, running). The managed host at `10.0.0.9` was originally
  created as `db01` and has been renamed to **`lb01`** (VMID 127) to avoid the
  name collision.
* Run `terraform` from `/root/xceuler/terraform` so the local state file and
  `/.terraform` are used.
