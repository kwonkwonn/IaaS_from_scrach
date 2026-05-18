#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# variables  (Makefile exports override; defaults allow standalone run)
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
CEPH_POOL=${CEPH_POOL:-vms}

# ----------------------------------------------------------------------------
# provision
# ----------------------------------------------------------------------------

mkdir -p "$VM_PIDDIR"

# RBD image creation + OS write is handled by qemu-img convert in 03_vm.sh.
# This script only registers the pool/name so 03_vm.sh knows where to write.
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "${CEPH_POOL}/${name}" > "${VM_PIDDIR}/${name}.disk"
    echo "[storage] $name → ${CEPH_POOL}/${name}"
done

echo "[storage] provisioned:"
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "  $name  $(cat "${VM_PIDDIR}/${name}.disk")"
done
