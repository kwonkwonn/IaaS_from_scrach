#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# variables
# ----------------------------------------------------------------------------

VNET_A_NS=${VNET_A_NS:-vnet-a}
VNET_B_NS=${VNET_B_NS:-vnet-b}

VNET_A_BRIDGE=${VNET_A_BRIDGE:-br-vnet-a}
VNET_B_BRIDGE=${VNET_B_BRIDGE:-br-vnet-b}

VETH_A_HOST=${VETH_A_HOST:-veth-a-host}
VETH_A_NS=${VETH_A_NS:-veth-a-ns}
VETH_B_HOST=${VETH_B_HOST:-veth-b-host}
VETH_B_NS=${VETH_B_NS:-veth-b-ns}

VETH_A_HOST_IP=${VETH_A_HOST_IP:-10.0.0.1}
VETH_A_NS_IP=${VETH_A_NS_IP:-10.0.0.2}
VETH_B_HOST_IP=${VETH_B_HOST_IP:-10.0.1.1}
VETH_B_NS_IP=${VETH_B_NS_IP:-10.0.1.2}
VETH_PREFIX=${VETH_PREFIX:-30}

VM_GW=${VM_GW:-192.168.0.254}
VM_PREFIX=${VM_PREFIX:-24}
VM1_IP=${VM1_IP:-192.168.0.1}
VM2_IP=${VM2_IP:-192.168.0.2}
VM3_IP=${VM3_IP:-192.168.0.3}

TAP_VM1=${TAP_VM1:-tap-vm1}
TAP_VM2=${TAP_VM2:-tap-vm2}
TAP_VM3=${TAP_VM3:-tap-vm3}

VM1_SSH_PORT=${VM1_SSH_PORT:-2201}
VM2_SSH_PORT=${VM2_SSH_PORT:-2202}
VM3_SSH_PORT=${VM3_SSH_PORT:-2203}

NETPLAN_FILE=${NETPLAN_FILE:-/etc/netplan/99-vms-vnet.yaml}

HOST_NIC=$(ip route get 8.8.8.8 | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)

# ----------------------------------------------------------------------------
# functions
# ----------------------------------------------------------------------------

# setup_veth <host-iface> <ns-iface> <ns-name>
#   creates veth pair and moves ns-side into namespace
setup_veth() {
    local host=$1 ns_iface=$2 ns=$3
    ip link add "$host" type veth peer name "$ns_iface"
    ip link set "$ns_iface" netns "$ns"
    ip link set "$host" up
}

# setup_ns_internals <ns> <bridge> <veth-ns> <veth-ns-ip> <veth-host-ip> [tap...]
#   configures everything inside a namespace: veth IP, bridge, taps, default route
setup_ns_internals() {
    local ns=$1 bridge=$2 veth_ns=$3 veth_ns_ip=$4 veth_host_ip=$5
    shift 5
    local taps=("$@")

    ip netns exec "$ns" ip addr add "${veth_ns_ip}/${VETH_PREFIX}" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up

    ip netns exec "$ns" ip link add "$bridge" type bridge
    ip netns exec "$ns" ip addr add "${VM_GW}/${VM_PREFIX}" dev "$bridge"
    ip netns exec "$ns" ip link set "$bridge" up

    for tap in "${taps[@]}"; do
        ip netns exec "$ns" ip tuntap add dev "$tap" mode tap
        ip netns exec "$ns" ip link set "$tap" master "$bridge"
        ip netns exec "$ns" ip link set "$tap" up
    done

    ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1
    ip netns exec "$ns" sysctl -qw "net.ipv4.conf.${veth_ns}.proxy_arp=1"
    ip netns exec "$ns" ip route add default via "$veth_host_ip"

    # outbound NAT: VM traffic leaving namespace — skip host-side veth to preserve source IP on return path
    ip netns exec "$ns" iptables -t nat -A POSTROUTING -o "$veth_ns" ! -d "${veth_host_ip}" -j MASQUERADE
}

# ----------------------------------------------------------------------------
# namespaces
# ----------------------------------------------------------------------------

mkdir -p /var/run/netns

ip netns add "$VNET_A_NS"
ip netns add "$VNET_B_NS"

ip netns exec "$VNET_A_NS" ip link set lo up
ip netns exec "$VNET_B_NS" ip link set lo up

# ----------------------------------------------------------------------------
# veth pairs + netplan (host-side IP, file-based)
# ----------------------------------------------------------------------------

setup_veth "$VETH_A_HOST" "$VETH_A_NS" "$VNET_A_NS"
setup_veth "$VETH_B_HOST" "$VETH_B_NS" "$VNET_B_NS"

sed \
    -e "s|__VETH_A_HOST__|$VETH_A_HOST|g" \
    -e "s|__VETH_B_HOST__|$VETH_B_HOST|g" \
    -e "s|__VETH_A_HOST_IP__|$VETH_A_HOST_IP|g" \
    -e "s|__VETH_B_HOST_IP__|$VETH_B_HOST_IP|g" \
    -e "s|__VETH_PREFIX__|$VETH_PREFIX|g" \
    "$(dirname "$0")/templates/vnet.netplan.tmpl" > "$NETPLAN_FILE"

netplan apply

# ----------------------------------------------------------------------------
# namespace internals
# ----------------------------------------------------------------------------

setup_ns_internals \
    "$VNET_A_NS" "$VNET_A_BRIDGE" "$VETH_A_NS" "$VETH_A_NS_IP" "$VETH_A_HOST_IP" \
    "$TAP_VM1" "$TAP_VM2"

setup_ns_internals \
    "$VNET_B_NS" "$VNET_B_BRIDGE" "$VETH_B_NS" "$VETH_B_NS_IP" "$VETH_B_HOST_IP" \
    "$TAP_VM3"

# ----------------------------------------------------------------------------
# host routing + iptables
# ----------------------------------------------------------------------------

sysctl -qw net.ipv4.ip_forward=1

# /32 host routes: DNAT 패킷이 올바른 namespace로 진입
ip route add "${VM1_IP}/32" dev "$VETH_A_HOST"
ip route add "${VM2_IP}/32" dev "$VETH_A_HOST"
ip route add "${VM3_IP}/32" dev "$VETH_B_HOST"

# host → internet NAT
iptables -t nat -A POSTROUTING -o "$HOST_NIC" \
    -s "${VETH_A_HOST_IP%.*}.0/${VETH_PREFIX}" -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$HOST_NIC" \
    -s "${VETH_B_HOST_IP%.*}.0/${VETH_PREFIX}" -j MASQUERADE

iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "$VETH_A_HOST" -j ACCEPT
iptables -A FORWARD -i "$VETH_B_HOST" -j ACCEPT

# inbound SSH port-forward
iptables -t nat -A PREROUTING -p tcp --dport "$VM1_SSH_PORT" -j DNAT --to-destination "${VM1_IP}:22"
iptables -t nat -A PREROUTING -p tcp --dport "$VM2_SSH_PORT" -j DNAT --to-destination "${VM2_IP}:22"
iptables -t nat -A PREROUTING -p tcp --dport "$VM3_SSH_PORT" -j DNAT --to-destination "${VM3_IP}:22"

echo "[network] done"
echo "  vnet-a: $VM1_IP, $VM2_IP  (via $VETH_A_HOST_IP <-> $VETH_A_NS_IP)"
echo "  vnet-b: $VM3_IP           (via $VETH_B_HOST_IP <-> $VETH_B_NS_IP)"
