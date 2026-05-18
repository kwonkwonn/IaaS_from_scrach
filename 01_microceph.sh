#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# variables  (Makefile exports override; defaults allow standalone run)
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}
VM_DISK_SIZE=${VM_DISK_SIZE:-20G}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
CEPH_POOL=${CEPH_POOL:-vms}
CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
CEPH_KEYRING=${CEPH_KEYRING:-/var/snap/microceph/current/conf/ceph.client.admin.keyring}

RBD="microceph.rbd"

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# convert "20G" → MB for rbd create --size
_size_mb() {
    local s=${1^^}
    case $s in
        *G) echo $(( ${s%G} * 1024 )) ;;
        *M) echo "${s%M}" ;;
        *)  echo "$s" ;;
    esac
}

# ----------------------------------------------------------------------------
# provision
# ----------------------------------------------------------------------------

mkdir -p "$VM_PIDDIR"

size_mb=$(_size_mb "$VM_DISK_SIZE")

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    if ! $RBD info "${CEPH_POOL}/${name}"; then
        $RBD create "${CEPH_POOL}/${name}" --size "$size_mb"
        echo "[storage] created RBD image ${CEPH_POOL}/${name} (${VM_DISK_SIZE})"
    else
        echo "[storage] ${CEPH_POOL}/${name} already exists — skipping"
    fi

    echo "${CEPH_POOL}/${name}" > "${VM_PIDDIR}/${name}.disk"
    echo "[storage] $name → ${CEPH_POOL}/${name}"
done

echo "[storage] provisioned:"
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "  $name  $(cat "${VM_PIDDIR}/${name}.disk")"
done
