# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All configuration (IPs, MACs, ports, disk sizes) is centralized in the `Makefile`. Scripts read those values via exported environment variables.

```bash
# Full setup (runs all steps in order)
sudo make all

# Individual steps
sudo make prereq       # install packages, bootstrap microceph cluster + OSD + pool, download Ubuntu cloud image (~800 MB total)
sudo make microceph    # register RBD image names for each VM (writes to /run/vms/<name>.disk)
sudo make network      # create network namespaces, bridges, TAP interfaces, iptables rules
sudo make vms          # write cloud image to RBD, build cloud-init seeds, launch QEMU VMs

# Run tests
sudo make test         # or: sudo bash 04_test.sh

# Tear down everything
sudo make clean        # kills VMs, removes namespaces, RBD images, iptables rules, cloud image
```

Scripts can also be run standalone (they have built-in defaults matching the Makefile):
```bash
sudo bash 04_test.sh   # run only tests without re-running setup
```

SSH into a running VM (direct IP, reachable from host):
```bash
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.1  # vm1
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.2  # vm2
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.0.3  # vm3
```

Or via host-forwarded ports (2201–2203 → VM SSH):
```bash
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no -p 2201 ubuntu@127.0.0.1  # vm1
```

VNC and serial console:
```bash
vncviewer 127.0.0.1:5901   # vm1 (:5902 vm2, :5903 vm3)
tail -f /var/log/vms/vm1-console.log   # serial console output
```

## Architecture

This project builds a 3-VM lab environment on a single Linux host using KVM/QEMU, Ceph RBD storage (via microceph), and L2 network isolation via Linux network namespaces.

### Script responsibilities

| Script | `make` target | What it does |
|---|---|---|
| `00_prereq.sh` | `prereq` | Installs apt packages, bootstraps microceph (cluster + loop OSD + pool), downloads cloud image |
| `01_microceph.sh` | `microceph` | Writes `<pool>/<name>` to `/run/vms/<name>.disk`, creates RBD images, writes cloud image into each (idempotent via `@installed` snap) |
| `02_network.sh` | `network` | Creates namespaces, bridges, TAPs, veth pairs, iptables rules, netplan config |
| `03_vm.sh` | `vms` | Writes cloud image to RBD, builds cloud-init ISOs, launches QEMU inside namespaces |
| `04_test.sh` | `test` | Three-phase validation (see Test phases below) |
| `cleanup.sh` | `clean` | Kills VMs, removes namespaces/routes/iptables, deletes RBD images, removes cloud image |

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

### Storage (00_prereq.sh + 01_microceph.sh + 03_vm.sh)

VMs boot from **Ceph RBD images** managed by the microceph snap (single-node, loop OSD):

1. `00_prereq.sh` bootstraps microceph: cluster → 30 GB loop OSD → pool `vms` (size=1, min_size=1)
2. `01_microceph.sh` records `vms/<name>` in `/run/vms/<name>.disk`, then creates each RBD image and writes the cloud image into it via `qemu-img convert`; marks completion with an `@installed` snap so re-runs are skipped
3. `03_vm.sh` reads the pool/name from `/run/vms/<name>.disk` and passes it as the RBD drive URL to QEMU

To swap in external Ceph: only `00_prereq.sh` and `01_microceph.sh` need changing — `03_vm.sh` just reads the `.disk` file and constructs the `rbd:` URL.

### VM boot flow (03_vm.sh)

1. `make_seed()` renders templates in `templates/` (using `__KEY__` → value substitution via `sed`) into cloud-init user-data, meta-data, and network-config, then builds a seed ISO with `cloud-localds`
2. `launch_vm()` runs `qemu-system-x86_64` inside the correct namespace (`ip netns exec`) with the RBD drive (URL read from `/run/vms/<name>.disk`), seed ISO, and TAP interface; daemonizes and writes PID to `/run/vms/<name>.pid`

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
- `00_prereq.sh` is idempotent: skips microceph bootstrap, OSD, pool creation, and image download if already present
- Kernel modules `tun` (TAP interfaces) and `rbd` (kernel RBD mapping) are loaded by `00_prereq.sh`
