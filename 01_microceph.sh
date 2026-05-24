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
CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
CEPH_KEYRING=${CEPH_KEYRING:-/var/snap/microceph/current/conf/ceph.client.admin.keyring}
VM_DISK_SIZE=${VM_DISK_SIZE:-20G}

CLOUD_IMAGE_URL=${CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
CLOUD_IMAGE_FILE=${CLOUD_IMAGE_FILE:-/tmp/noble-cloudimg.img}

RBD="microceph.rbd"

# ----------------------------------------------------------------------------
# pool setup (idempotent)
# ----------------------------------------------------------------------------

if ! microceph.ceph osd pool ls 2>/dev/null | grep -q "^${CEPH_POOL}$"; then
    microceph.ceph osd pool create "$CEPH_POOL" 32
    $RBD pool init "$CEPH_POOL"
    echo "[storage] pool '$CEPH_POOL' created"
else
    echo "[storage] pool '$CEPH_POOL' already exists — skipping"
fi

# single-node: no replication
microceph.ceph osd pool set "$CEPH_POOL" size 1 --yes-i-really-mean-it
microceph.ceph osd pool set "$CEPH_POOL" min_size 1

# ----------------------------------------------------------------------------
# functions
# ----------------------------------------------------------------------------


# install_image <pool/name>
#   creates RBD image and writes cloud image to it; idempotent via @installed snap
install_image() {
    local img=$1
    local rbd_url="rbd:${img}:conf=${CEPH_CONF}:keyring=${CEPH_KEYRING}"

    if $RBD snap ls "$img" 2>/dev/null | grep -qw "installed"; then
        echo "[storage] $img already has OS — skipping image write"
        return
    fi

    $RBD rm "$img" &>/dev/null || true

    echo "[storage] writing cloud image to $img ..."
    qemu-img convert -f qcow2 -O raw "$CLOUD_IMAGE_FILE" "$rbd_url"

    echo "[storage] resizing $img to ${VM_DISK_SIZE} ..."
    $RBD resize --size "$VM_DISK_SIZE" "$img"

    $RBD snap create "${img}@installed"
    echo "[storage] $img ready"
}

# ----------------------------------------------------------------------------
# provision: register disk paths + write OS image
# ----------------------------------------------------------------------------

mkdir -p "$VM_PIDDIR"

# download cloud image once (before the per-VM loop)
# NOTE: ~600 MB, takes a few minutes on first run
if [[ ! -f "$CLOUD_IMAGE_FILE" ]]; then
    echo "[storage] downloading cloud image (~600 MB) ..."
    wget --progress=dot:giga -O "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL"
else
    echo "[storage] cloud image already present — skipping download"
fi

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "${CEPH_POOL}/${name}" > "${VM_PIDDIR}/${name}.disk"
done

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    install_image "${CEPH_POOL}/${name}"
done

echo "[storage] all disks ready"
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "  $name  $(cat "${VM_PIDDIR}/${name}.disk")"
done
