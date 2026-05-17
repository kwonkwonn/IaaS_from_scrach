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
    ovmf \
    wget

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

# ── kernel modules ───────────────────────────────────────────────────────────

# tun: required for QEMU TAP interfaces inside network namespaces
modprobe tun

# ── runtime directories ──────────────────────────────────────────────────────

mkdir -p "$VM_PIDDIR" "$VM_LOGDIR" "$CLOUD_INIT_DIR"

echo "[prereq] done"
