#!/usr/bin/env bash
set -euo pipefail

# Storage provisioning — loop device backend (placeholder for Ceph RBD)
#
# 03_vm.sh reads /run/vms/vm{1,2,3}.disk for the block device path.
# Replace this script with 01_microceph.sh later; no other script changes.

# ----------------------------------------------------------------------------
# variables  (Makefile exports override; defaults allow standalone run)
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}
VM_DISK_SIZE=${VM_DISK_SIZE:-20G}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
DISK_DIR=${DISK_DIR:-/var/lib/vm-disks}

# ----------------------------------------------------------------------------
# pre-flight: disk space
# ----------------------------------------------------------------------------

# VM_DISK_SIZE is like "20G" — convert to bytes for comparison
_size_bytes() {
    local s=${1^^}  # uppercase
    case $s in
        *G) echo $(( ${s%G} * 1024 * 1024 * 1024 )) ;;
        *M) echo $(( ${s%M} * 1024 * 1024 )) ;;
        *)  echo "$s" ;;
    esac
}

required=$(( $(_size_bytes "$VM_DISK_SIZE") * 3 ))
available=$(df --output=avail -B1 / | tail -1)

if (( available < required )); then
    echo "[storage] ERROR: need $(( required / 1024 / 1024 / 1024 ))G, only $(( available / 1024 / 1024 / 1024 ))G available"
    exit 1
fi

# ----------------------------------------------------------------------------
# disk images
# ----------------------------------------------------------------------------

mkdir -p "$DISK_DIR" "$VM_PIDDIR"

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    img="$DISK_DIR/${name}.raw"

    if [[ -f "$img" ]]; then
        echo "[storage] $img already exists — skipping"
        continue
    fi

    qemu-img create -f raw "$img" "$VM_DISK_SIZE"
    echo "[storage] created $img ($VM_DISK_SIZE)"
done

# ----------------------------------------------------------------------------
# loop device mapping
# ----------------------------------------------------------------------------

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    img="$DISK_DIR/${name}.raw"

    # detach ALL stale loops for this image (losetup -j may return multiple)
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        losetup -d "$dev" || echo "[storage] warn: could not detach $dev (busy?) — continuing"
    done < <(losetup -j "$img" | cut -d: -f1)

    dev=$(losetup -f --show "$img")
    echo "$dev" > "${VM_PIDDIR}/${name}.disk"
    echo "[storage] $name → $dev"
done

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------

echo "[storage] provisioned:"
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "  $name  $(cat "${VM_PIDDIR}/${name}.disk")"
done
