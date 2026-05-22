#!/usr/bin/env bash
set -uo pipefail   # no -e: best-effort

# ----------------------------------------------------------------------------
# variables
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
CLOUD_IMAGE_FILE=${CLOUD_IMAGE_FILE:-/tmp/noble-cloudimg.img}
CEPH_POOL=${CEPH_POOL:-vms}
CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
CEPH_KEYRING=${CEPH_KEYRING:-/var/snap/microceph/current/conf/ceph.client.admin.keyring}

RBD="microceph.rbd"
CLOUD_INIT_DIR=${CLOUD_INIT_DIR:-/tmp/cloud-init}
VM_LOGDIR=${VM_LOGDIR:-/var/log/vms}

VNET_A_NS=${VNET_A_NS:-vnet-a}
VNET_B_NS=${VNET_B_NS:-vnet-b}
VETH_A_HOST=${VETH_A_HOST:-veth-a-host}
VETH_A_NS=${VETH_A_NS:-veth-a-ns}
VETH_B_HOST=${VETH_B_HOST:-veth-b-host}
VETH_B_NS=${VETH_B_NS:-veth-b-ns}

VM1_IP=${VM1_IP:-192.168.0.1}
VM2_IP=${VM2_IP:-192.168.0.2}
VM3_IP=${VM3_IP:-192.168.0.3}

VM1_SSH_PORT=${VM1_SSH_PORT:-2201}
VM2_SSH_PORT=${VM2_SSH_PORT:-2202}
VM3_SSH_PORT=${VM3_SSH_PORT:-2203}

NETPLAN_FILE=${NETPLAN_FILE:-/etc/netplan/99-vms-vnet.yaml}

HOST_NIC=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1 || echo "")

# ----------------------------------------------------------------------------
# VMs — graceful shutdown then force kill
# ----------------------------------------------------------------------------

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    pidfile="${VM_PIDDIR}/${name}.pid"
    [[ ! -f "$pidfile" ]] && continue

    pid=$(cat "$pidfile")

    # SIGTERM: ask QEMU to shut down gracefully
    kill -TERM "$pid" 2>/dev/null || { rm -f "$pidfile"; continue; }

    # wait up to 10s for clean exit
    for _ in $(seq 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    # still alive → force kill
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true

    rm -f "$pidfile"
    echo "[cleanup] stopped $name (pid $pid)"
done

# ----------------------------------------------------------------------------
# iptables: inbound DNAT
# ----------------------------------------------------------------------------

iptables -t nat -D PREROUTING -p tcp --dport "$VM1_SSH_PORT" -j DNAT --to-destination "${VM1_IP}:22" 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport "$VM2_SSH_PORT" -j DNAT --to-destination "${VM2_IP}:22" 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport "$VM3_SSH_PORT" -j DNAT --to-destination "${VM3_IP}:22" 2>/dev/null || true

# iptables: outbound MASQUERADE (host → internet)
[[ -n "$HOST_NIC" ]] && {
    iptables -t nat -D POSTROUTING -o "$HOST_NIC" -s "10.0.0.0/30" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o "$HOST_NIC" -s "10.0.1.0/30" -j MASQUERADE 2>/dev/null || true
}

# iptables: FORWARD
iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$VETH_A_HOST" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$VETH_B_HOST" -j ACCEPT 2>/dev/null || true

# ----------------------------------------------------------------------------
# host /32 routes
# ----------------------------------------------------------------------------

ip route del "${VM1_IP}/32" 2>/dev/null || true
ip route del "${VM2_IP}/32" 2>/dev/null || true
ip route del "${VM3_IP}/32" 2>/dev/null || true

# ----------------------------------------------------------------------------
# namespaces  (ns 삭제 시 내부 bridge, tap, veth-ns 전부 함께 제거됨)
# ----------------------------------------------------------------------------

ip netns del "$VNET_A_NS" 2>/dev/null || true
ip netns del "$VNET_B_NS" 2>/dev/null || true

# host-side veth는 ns 삭제 후에도 남음 — 명시적으로 제거
ip link del "$VETH_A_HOST" 2>/dev/null || true
ip link del "$VETH_B_HOST" 2>/dev/null || true

# ----------------------------------------------------------------------------
# netplan
# ----------------------------------------------------------------------------

rm -f "$NETPLAN_FILE"
netplan apply 2>/dev/null || true

# ----------------------------------------------------------------------------
# Ceph: RBD images → pool → OSDs
# ----------------------------------------------------------------------------

for name in "$VM1_NAME" "$VM2_NAME" "$VM3_NAME"; do
    $RBD snap purge "${CEPH_POOL}/${name}" 2>/dev/null || true
    $RBD rm "${CEPH_POOL}/${name}" 2>/dev/null && echo "[cleanup] removed ${CEPH_POOL}/${name}" || true
done

# pool only — do NOT remove OSDs; ceph osd rm on a live daemon fails silently
# and leaves the cluster in a degraded state that causes rbd I/O to hang
microceph.ceph config set mon mon_allow_pool_delete true 2>/dev/null || true
microceph.ceph osd pool delete "$CEPH_POOL" "$CEPH_POOL" \
    --yes-i-really-really-mean-it 2>/dev/null \
    && echo "[cleanup] deleted pool ${CEPH_POOL}" || true

# ----------------------------------------------------------------------------
# files
# ----------------------------------------------------------------------------

rm -rf "$CLOUD_INIT_DIR"
rm -f  "$CLOUD_IMAGE_FILE"
rm -f  "${VM_PIDDIR}"/*.disk 2>/dev/null || true
rm -f  "${VM_PIDDIR}"/*-uefi-vars.fd 2>/dev/null || true
rm -f  "${VM_LOGDIR}"/*.log  2>/dev/null || true

echo "[cleanup] done"
