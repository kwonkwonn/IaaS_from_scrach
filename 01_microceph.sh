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
# functions
# ----------------------------------------------------------------------------

# apply_qos <pool/name>
#   sets non-zero librbd QoS limits on the image via config image set (0 = unlimited)
apply_qos() {
    local img=$1
    declare -A qos=(
        [rbd_qos_iops_limit]="${VM_QOS_IOPS_LIMIT:-0}"
        [rbd_qos_bps_limit]="${VM_QOS_BPS_LIMIT:-0}"
        [rbd_qos_read_iops_limit]="${VM_QOS_READ_IOPS_LIMIT:-0}"
        [rbd_qos_write_iops_limit]="${VM_QOS_WRITE_IOPS_LIMIT:-0}"
        [rbd_qos_read_bps_limit]="${VM_QOS_READ_BPS_LIMIT:-0}"
        [rbd_qos_write_bps_limit]="${VM_QOS_WRITE_BPS_LIMIT:-0}"
        [rbd_qos_iops_burst]="${VM_QOS_IOPS_BURST:-0}"
        [rbd_qos_bps_burst]="${VM_QOS_BPS_BURST:-0}"
    )
    local applied=0
    for key in "${!qos[@]}"; do
        local val="${qos[$key]}"
        if [[ "$val" -gt 0 ]]; then
            $RBD config image set "$img" "$key" "$val"
            echo "[storage] QoS: $img $key = $val"
            applied=1
        fi
    done
    [[ $applied -eq 0 ]] && echo "[storage] QoS: $img unlimited (all limits = 0)"
}

# install_image <pool/name>
#   creates RBD image and writes cloud image to it; idempotent via @installed snap
install_image() {
    local img=$1
    local rbd_url="rbd:${img}:conf=${CEPH_CONF}:keyring=${CEPH_KEYRING}"

    if $RBD snap ls "$img" 2>/dev/null | grep -qw "installed"; then
        echo "[storage] $img already has OS — skipping image write"
        return
    fi

    if [[ ! -f "$CLOUD_IMAGE_FILE" ]]; then
        echo "[storage] cloud image not found — downloading ..."
        wget --progress=dot:giga -O "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL"
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

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "${CEPH_POOL}/${name}" > "${VM_PIDDIR}/${name}.disk"
done

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    install_image "${CEPH_POOL}/${name}"
    apply_qos    "${CEPH_POOL}/${name}"
done

echo "[storage] all disks ready"
for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    echo "  $name  $(cat "${VM_PIDDIR}/${name}.disk")"
done
