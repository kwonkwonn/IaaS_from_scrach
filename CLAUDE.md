# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All configuration (IPs, MACs, ports, disk sizes) is centralized in the `Makefile`. Scripts read those values via exported environment variables.

```bash
# Full setup (runs all steps in order)
sudo make all

# Individual steps
sudo make prereq       # install packages, microceph snap, download Ubuntu cloud image (~800 MB total)
sudo make microceph    # provision loop-device-backed raw disk images for each VM
sudo make network      # create network namespaces, bridges, TAP interfaces, iptables rules
sudo make vms          # write cloud image to disks, build cloud-init seeds, launch QEMU VMs

# Run tests
sudo make test         # or: sudo bash 04_test.sh

# Tear down everything
sudo make clean        # kills VMs, removes namespaces, loop devices, disk images, iptables rules
```

Scripts can also be run standalone (they have built-in defaults matching the Makefile):
```bash
sudo bash 04_test.sh   # run only tests without re-running setup
```

SSH into a running VM:
```bash
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.1  # vm1
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.2  # vm2
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.3  # vm3
```

## Architecture

This project builds a 3-VM lab environment on a single Linux host using KVM/QEMU, with L2 network isolation enforced via Linux network namespaces.

### Network topology

Two isolated L2 segments are created as Linux network namespaces:

```
Host
├── veth-a-host (10.0.0.1/30) ──── veth-a-ns (10.0.0.2/30)  [namespace: vnet-a]
│                                       └── br-vnet-a (192.168.0.254/24)
│                                               ├── tap-vm1 → vm1 (192.168.0.1)
│                                               └── tap-vm2 → vm2 (192.168.0.2)
│
└── veth-b-host (10.0.1.1/30) ──── veth-b-ns (10.0.1.2/30)  [namespace: vnet-b]
                                        └── br-vnet-b (192.168.0.254/24)
                                                └── tap-vm3 → vm3 (192.168.0.3)
```

- **vm1 and vm2** share `vnet-a` → can ping each other (L2 reachable)
- **vm3** lives in `vnet-b` → cannot reach vm1/vm2 (L2 isolated, not firewall)
- Each namespace has a default route via the veth back to the host, with MASQUERADE NAT for internet access
- Host has /32 routes (`ip route add 192.168.0.x/32 dev veth-x-host`) and DNAT rules forwarding ports 2201–2203 to VM SSH

### Storage (01_microceph.sh)

Currently a **placeholder** for Ceph RBD. It creates raw disk images under `/var/lib/vm-disks/` and exposes them as loop devices. `03_vm.sh` reads the block device path from `/run/vms/<name>.disk`. To swap in real Ceph RBD, only `01_microceph.sh` needs changing — the interface (`/run/vms/<name>.disk` containing the block device path) stays the same.

### VM boot flow (03_vm.sh)

1. Cloud image (`/tmp/noble-cloudimg.img`, Ubuntu Noble) is written to each VM's block device via `qemu-img convert`
2. Per-VM cloud-init seed ISOs are built from templates in `templates/` using `__PLACEHOLDER__` substitution via `sed`
3. QEMU is launched inside the appropriate network namespace (`ip netns exec <ns> qemu-system-x86_64 ... -daemonize`) with a TAP interface attached to the namespace bridge

### Templates

`templates/` contains four files with `__KEY__` placeholders substituted at runtime:
- `user-data.tmpl` — sets hostname, creates `ubuntu` user with sudo/password auth
- `meta-data.tmpl` — sets instance-id and local-hostname
- `network-config.tmpl` — static IP config matched by MAC address (netplan v2)
- `vnet.netplan.tmpl` — host-side veth IP config applied via `netplan apply`

### Test phases (04_test.sh)

1. **Network plumbing** — checks namespaces, bridges, TAPs, host routes exist; verifies TAP isolation (tap-vm3 must not appear in vnet-a)
2. **VM SSH availability** — waits up to 180s per VM for TCP port 22
3. **Inter-VM ping** — vm1↔vm2 must succeed; vm1↔vm3 and vm2↔vm3 must fail

### Prerequisites

- Requires root (`EUID=0`), `/dev/kvm`, and CPU virtualization flags (`vmx`/`svm`)
- `00_prereq.sh` is idempotent: skips microceph install and image download if already present
