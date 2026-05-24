#!/usr/bin/env bash
set -euo pipefail

# ── pre-flight checks ────────────────────────────────────────────────────────

# KVM device must exist (nested virt or bare-metal with VT-x/AMD-V)
[[ -e /dev/kvm ]] || { echo "[prereq] ERROR: /dev/kvm not found — enable VT-x/AMD-V or nested virtualization"; exit 1; }

# CPU must expose virtualization flag
grep -qE 'vmx|svm' /proc/cpuinfo || { echo "[prereq] ERROR: CPU virtualization flag (vmx/svm) not found"; exit 1; }

# Must run as root
[[ $EUID -eq 0 ]] || { echo "[prereq] ERROR: must run as root"; exit 1; }

echo "[prereq] pre-flight OK — KVM available, running as root"

# ── apt packages ─────────────────────────────────────────────────────────────

apt-get update -qq

apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    ceph-common \
    iproute2 \
    iptables \
    cloud-image-utils \
    numactl \
    ovmf \
    wget \
    sshpass

# ── microceph (snap) ─────────────────────────────────────────────────────────

systemctl enable --now snapd.socket
snap wait system seed.loaded

# skip if already installed
if ! snap list microceph &>/dev/null; then
    # NOTE: ~200 MB download, takes a few minutes
    snap install microceph
else
    echo "[prereq] microceph already installed — skipping"
fi

# ── microceph bootstrap (single-node) ────────────────────────────────────────

CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
VM_LOGDIR=${VM_LOGDIR:-/var/log/vms}
CLOUD_INIT_DIR=${CLOUD_INIT_DIR:-/tmp/cloud-init}

if ! microceph.ceph --conf "$CEPH_CONF" status &>/dev/null; then
    microceph cluster bootstrap
    echo "[prereq] waiting for Ceph cluster health..."
    until microceph.ceph --conf "$CEPH_CONF" health 2>/dev/null | grep -qE "HEALTH_OK|HEALTH_WARN"; do
        sleep 3
    done
else
    echo "[prereq] microceph cluster already running — skipping bootstrap"
fi

# single-node: allow size=1 and set defaults before pool/OSD creation
microceph.ceph config set global mon_allow_pool_size_one true
microceph.ceph config set global osd_pool_default_size 1
microceph.ceph config set global osd_pool_default_min_size 1

# ── OSD (loop-device backed, single-node) ────────────────────────────────────

if microceph.ceph osd stat 2>/dev/null | grep -q "^0 osds"; then
    echo "[prereq] adding loop OSD (30 GB) ..."
    microceph disk add loop,30G,1
    echo "[prereq] waiting for OSD to come up ..."
    until microceph.ceph osd stat 2>/dev/null | grep -qE "^[1-9]"; do
        sleep 3
    done
else
    echo "[prereq] OSD already present — skipping"
fi

# ── kernel modules ───────────────────────────────────────────────────────────

# tun: required for QEMU TAP interfaces inside network namespaces
modprobe tun
# rbd: required for kernel RBD block device mapping
modprobe rbd

# ── runtime directories ──────────────────────────────────────────────────────

mkdir -p "$VM_PIDDIR" "$VM_LOGDIR" "$CLOUD_INIT_DIR"

echo "[prereq] done"
