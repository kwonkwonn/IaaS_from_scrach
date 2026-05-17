#!/usr/bin/env bash
set -uo pipefail   # no -e: best-effort

# ----------------------------------------------------------------------------
# variables
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
DISK_DIR=${DISK_DIR:-/var/lib/vm-disks}
CLOUD_IMAGE_FILE=${CLOUD_IMAGE_FILE:-/tmp/noble-cloudimg.img}
CLOUD_INIT_DIR=${CLOUD_INIT_DIR:-/tmp/cloud-init}

# ----------------------------------------------------------------------------
# loop devices
# ----------------------------------------------------------------------------

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    img="$DISK_DIR/${name}.raw"
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        losetup -d "$dev" 2>/dev/null && echo "[cleanup] detached $dev" || true
    done < <(losetup -j "$img" 2>/dev/null | cut -d: -f1)
done

# ----------------------------------------------------------------------------
# files
# ----------------------------------------------------------------------------

rm -rf "$DISK_DIR"
rm -rf "$CLOUD_INIT_DIR"
rm -f  "$CLOUD_IMAGE_FILE"
rm -f  "${VM_PIDDIR}"/*.disk 2>/dev/null || true

echo "[cleanup] done"
