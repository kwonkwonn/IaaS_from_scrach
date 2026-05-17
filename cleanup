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
