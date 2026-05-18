# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Full setup (prereqs → microceph/storage → network → VMs)
make all          # or run steps individually:
make prereq       # installs apt packages, microceph snap, downloads cloud image
make microceph    # provisions loop-device-backed VM disks (placeholder for Ceph RBD)
make network      # creates network namespaces, bridges, taps, veth pairs, iptables rules
make vms          # writes cloud image to disks, builds cloud-init ISOs, launches QEMU

# Test
make test         # or: bash 04_test.sh

# Teardown
make clean        # or: bash cleanup.sh
```

All scripts must run as root. All Makefile variables are exported to the environment, so each script can also be run standalone with overrides (e.g. `VM_DISK_SIZE=10G bash 01_microceph.sh`).

## Architecture

This is a shell-script infrastructure project that provisions three KVM/QEMU virtual machines on a single Linux host, with L2-isolated virtual networks, using cloud-init for first-boot configuration.

### Script execution order and responsibilities

| Script | Role |
|---|---|
| `00_prereq.sh` | Installs host packages (`qemu-system-x86`, `ceph-common`, etc.), ensures `microceph` snap is installed, loads the `tun` kernel module, downloads the Ubuntu Noble cloud image to `/tmp/noble-cloudimg.img` |
| `01_microceph.sh` | Provisions VM storage. Currently uses raw image files + loop devices (not Ceph RBD). Writes each VM's block device path to `/run/vms/<name>.disk` for use by `03_vm.sh`. The file comment notes this is a placeholder — replacing it with a real Ceph implementation requires no changes to other scripts. |
| `02_network.sh` | Creates two network namespaces (`vnet-a`, `vnet-b`), each with a Linux bridge, TAP interfaces for the VMs, and a veth pair connecting the namespace to the host. Applies host-side IP config via netplan (`/etc/netplan/99-vms-vnet.yaml`). Sets up iptables NAT (outbound MASQUERADE, inbound SSH DNAT on ports 2201–2203). |
| `03_vm.sh` | Writes the cloud image to each loop device, generates per-VM cloud-init seed ISOs from `templates/`, and launches each QEMU process daemonized inside the appropriate network namespace. PIDs written to `/run/vms/<name>.pid`. |
| `04_test.sh` | Three-phase test: (1) verifies network plumbing — namespaces, bridges, taps, routes; (2) waits up to 180 s for each VM's SSH port; (3) validates L2 isolation — vm1↔vm2 can ping (same `vnet-a`), vm1/vm2↔vm3 cannot ping (across `vnet-a`/`vnet-b`). |
| `cleanup.sh` | Reverses everything: kills QEMU processes, removes iptables rules, deletes namespaces (which removes bridges/taps/veth-ns automatically), removes host-side veths, removes the netplan file, detaches loop devices, deletes disk images and cloud-init ISOs. |

### Network topology

```
Host
├── veth-a-host (10.0.0.1/30) ──── veth-a-ns (10.0.0.2/30)
│                                   └── [vnet-a namespace]
│                                        ├── br-vnet-a (192.168.0.254/24, gateway)
│                                        ├── tap-vm1 → vm1 (192.168.0.1)
│                                        └── tap-vm2 → vm2 (192.168.0.2)
│
└── veth-b-host (10.0.1.1/30) ──── veth-b-ns (10.0.1.2/30)
                                    └── [vnet-b namespace]
                                         ├── br-vnet-b (192.168.0.254/24, gateway)
                                         └── tap-vm3 → vm3 (192.168.0.3)
```

Both namespaces share the same internal subnet (`192.168.0.0/24`) and gateway IP — L2 isolation is enforced by placing them in separate network namespaces, not by firewall rules.

### Templates

`templates/` contains `__PLACEHOLDER__`-style templates rendered by `sed` in `02_network.sh` (netplan config) and `03_vm.sh` (cloud-init user-data, meta-data, network-config). The `render_tmpl` function in `03_vm.sh` handles generic substitution; `02_network.sh` does its own inline `sed`.

### Runtime directories

- `/run/vms/` — PID files (`<name>.pid`) and block device paths (`<name>.disk`)
- `/var/log/vms/` — per-VM serial console logs (`<name>-console.log`)
- `/tmp/cloud-init/<name>/` — rendered cloud-init files and seed ISO
- `/var/lib/vm-disks/` — raw disk images (created by `01_microceph.sh`)

### VM access

- SSH: `sshpass -p ubuntu ssh ubuntu@192.168.0.<N>` (direct, via namespace routing) or `ssh ubuntu@127.0.0.1 -p 220<N>` (via DNAT)
- VNC: `vncviewer 127.0.0.1:590<N>` (console, bound to localhost)
- Credentials: user `ubuntu`, password `ubuntu`
