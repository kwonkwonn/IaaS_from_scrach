# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All configuration (IPs, MACs, ports, disk sizes) is centralized in the `Makefile`. Scripts read those values via exported environment variables (`.EXPORT_ALL_VARIABLES:` in Makefile).

```bash
# Full setup (runs all steps in order)
sudo make all

# Individual steps
sudo make prereq       # install packages, bootstrap microceph cluster + OSD + pool, download Ubuntu cloud image (~800 MB total)
sudo make microceph    # create RBD images, write cloud image into each, register /run/vms/<name>.disk
sudo make network      # create network namespaces, bridges, TAP interfaces, iptables rules
sudo make vms          # build cloud-init seeds, launch QEMU VMs

# Run tests
sudo make test         # or: sudo bash 04_test.sh

# Snapshot management
sudo make snapshot                        # create snapshot for all VMs
sudo make snapshot VM=vm1                 # create snapshot for one VM
sudo make snapshot-list                   # list snapshots for all VMs
sudo make snapshot-rollback VM=vm1 SNAP=<snap-name>
sudo make snapshot-purge                  # delete all snapshots for all VMs

# Tear down everything
sudo make clean        # kills VMs, removes namespaces, RBD images, iptables rules, cloud image
```

Scripts can also be run standalone — each has built-in defaults matching the Makefile:
```bash
sudo bash 04_test.sh   # run only tests without re-running setup
```

SSH into a running VM (direct IP, reachable from host after network setup):
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
| `01_microceph.sh` | `microceph` | Creates RBD images, writes cloud image via `qemu-img convert`, marks completion with `@installed` snap, writes `<pool>/<name>` to `/run/vms/<name>.disk` |
| `02_network.sh` | `network` | Creates namespaces, bridges, TAPs, veth pairs, iptables rules, netplan config |
| `03_vm.sh` | `vms` | Builds cloud-init seed ISOs from templates, launches QEMU inside namespaces |
| `04_test.sh` | `test` | Three-phase validation (see Test phases below) |
| `05_snapshot.sh` | `snapshot*` | RBD snapshot create/list/rollback/purge |
| `cleanup.sh` | `clean` | Kills VMs, removes namespaces/routes/iptables, deletes RBD images, removes cloud image |

### Idempotency pattern

Scripts are designed to be re-run safely. The key guards are:
- `00_prereq.sh` — skips microceph bootstrap, OSD, pool creation, and cloud image download if already present
- `01_microceph.sh` — skips `qemu-img convert` if the RBD image already has an `@installed` snap (`rbd snap ls | grep -w installed`)
- `cleanup.sh` uses `|| true` throughout (no `-e` flag) so partial teardowns don't abort

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
- **vm3** lives in `vnet-b` → cannot reach vm1/vm2 (L2 isolation, not firewall)
- Each namespace has a default route via the veth back to the host, with MASQUERADE NAT for internet access
- Host has /32 routes (`ip route add 192.168.0.x/32 dev veth-x-host`) and DNAT rules forwarding ports 2201–2203 to VM SSH

### Storage (00_prereq.sh + 01_microceph.sh + 03_vm.sh)

VMs boot from **Ceph RBD images** managed by the microceph snap (single-node, loop-device OSD):

1. `00_prereq.sh` bootstraps microceph: cluster → 30 GB loop OSD → pool `vms` (size=1, min_size=1)
2. `01_microceph.sh` creates each RBD image and writes the cloud image into it via `qemu-img convert`; marks completion with an `@installed` snap so re-runs are skipped; writes `vms/<name>` to `/run/vms/<name>.disk`
3. `03_vm.sh` reads the pool/name from `/run/vms/<name>.disk` and passes it as the RBD drive URL to QEMU

To swap in external Ceph: only `00_prereq.sh` and `01_microceph.sh` need changing — `03_vm.sh` just reads the `.disk` file and constructs the `rbd:` URL.

### VM boot flow (03_vm.sh)

1. `render_tmpl()` substitutes `__KEY__` placeholders in files under `templates/` using `sed`
2. `make_seed()` renders `user-data.tmpl` and `meta-data.tmpl`, then renders the network-config inline (not from a template file), then builds a seed ISO with `cloud-localds`. If `VM_QOS_BENCH=1`, a benchmark script rendered from `templates/qos_bench.sh.tmpl` is appended to user-data and run at first boot, writing results to `/var/log/qos_bench.log`
3. `launch_vm()` runs `qemu-system-x86_64` inside the correct namespace (`ip netns exec`) with the RBD drive, seed ISO, and TAP interface; daemonizes and writes PID to `/run/vms/<name>.pid`

### QoS throttling

QoS is applied as QEMU block-layer throttling via the `-drive` option, not via Ceph RBD config. Non-zero `VM_QOS_*` variables in the Makefile are appended to the `rbd_drive` string as `throttling.*` key/value pairs inside `launch_vm()` in `03_vm.sh`. Setting all limits to `0` means unlimited.

### Templates

`templates/` contains files with `__KEY__` placeholders substituted at runtime by `render_tmpl()`:
- `user-data.tmpl` — cloud-init user-data: sets hostname, creates `ubuntu` user with sudo/password auth
- `meta-data.tmpl` — cloud-init meta-data: sets instance-id and local-hostname
- `qos_bench.sh.tmpl` — dd benchmark script injected via cloud-init when `VM_QOS_BENCH=1`
- `vnet.netplan.tmpl` — host-side veth IP config applied via `netplan apply`

Note: `network-config` (VM-side static IP) is rendered inline in `make_seed()` in `03_vm.sh`, not from a template file.

### Test phases (04_test.sh)

1. **Network plumbing** — checks namespaces, bridges, TAPs, host routes exist; verifies TAP isolation (tap-vm3 must not appear in vnet-a)
2. **VM SSH availability** — waits up to 180s per VM for TCP port 22
3. **Inter-VM ping** — vm1↔vm2 must succeed; vm1↔vm3 and vm2↔vm3 must fail

### Prerequisites

- Requires root (`EUID=0`), `/dev/kvm`, and CPU virtualization flags (`vmx`/`svm`)
- On GCP: requires `--enable-nested-virtualization` and `--min-cpu-platform="Intel Haswell"` or later
- Kernel modules `tun` (TAP interfaces) and `rbd` (kernel RBD mapping) are loaded by `00_prereq.sh`
- `qemu-img convert` from qcow2 to RBD can take several minutes per VM; this is normal
