#!/usr/bin/env bash
set -uo pipefail

# ----------------------------------------------------------------------------
# variables
# ----------------------------------------------------------------------------

VNET_A_NS=${VNET_A_NS:-vnet-a}
VNET_B_NS=${VNET_B_NS:-vnet-b}
VNET_A_BRIDGE=${VNET_A_BRIDGE:-br-vnet-a}
VNET_B_BRIDGE=${VNET_B_BRIDGE:-br-vnet-b}
TAP_VM1=${TAP_VM1:-tap-vm1}
TAP_VM2=${TAP_VM2:-tap-vm2}
TAP_VM3=${TAP_VM3:-tap-vm3}
VETH_A_HOST=${VETH_A_HOST:-veth-a-host}
VETH_B_HOST=${VETH_B_HOST:-veth-b-host}

VM1_IP=${VM1_IP:-192.168.0.1}
VM2_IP=${VM2_IP:-192.168.0.2}
VM3_IP=${VM3_IP:-192.168.0.3}
VM_GW=${VM_GW:-192.168.0.254}

VM_USER=${VM_USER:-ubuntu}
VM_PASS=${VM_PASS:-ubuntu}

VM_QOS_BENCH=${VM_QOS_BENCH:-0}
VM_QOS_BPS_LIMIT=${VM_QOS_BPS_LIMIT:-0}
VM_QOS_IOPS_LIMIT=${VM_QOS_IOPS_LIMIT:-0}
QOS_BENCH_LOG=${QOS_BENCH_LOG:-/var/log/qos_bench.log}

SSH_TIMEOUT=${SSH_TIMEOUT:-180}   # seconds to wait for each VM's SSH
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=no"

PASS=0
FAIL=0

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

ok()   { echo "[PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "[FAIL] $*"; FAIL=$(( FAIL + 1 )); }

check() {
    local desc=$1; shift
    if "$@" &>/dev/null; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

# check_pipe <desc> <full-shell-expression>  — evaluated with eval
check_pipe() {
    local desc=$1 expr=$2
    if eval "$expr" &>/dev/null; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

# wait_tcp <ip> <port> <seconds>
wait_tcp() {
    local ip=$1 port=$2 limit=$3
    local deadline=$(( $(date +%s) + limit ))
    while (( $(date +%s) < deadline )); do
        timeout 3 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

# ssh_run <ip> <cmd>  — returns exit code of remote command
ssh_run() {
    local ip=$1; shift
    sshpass -p "$VM_PASS" ssh $SSH_OPTS "${VM_USER}@${ip}" "$@"
}

# ----------------------------------------------------------------------------
# phase 1 — network plumbing
# ----------------------------------------------------------------------------

echo "=== Phase 1: network plumbing ==="

check_pipe "namespace ${VNET_A_NS} exists"   "ip netns list | grep -q '^${VNET_A_NS}'"
check_pipe "namespace ${VNET_B_NS} exists"   "ip netns list | grep -q '^${VNET_B_NS}'"

check "bridge ${VNET_A_BRIDGE} in ${VNET_A_NS}" ip netns exec "$VNET_A_NS" ip link show "$VNET_A_BRIDGE"
check "bridge ${VNET_B_BRIDGE} in ${VNET_B_NS}" ip netns exec "$VNET_B_NS" ip link show "$VNET_B_BRIDGE"

check "tap ${TAP_VM1} in ${VNET_A_NS}"  ip netns exec "$VNET_A_NS" ip link show "$TAP_VM1"
check "tap ${TAP_VM2} in ${VNET_A_NS}"  ip netns exec "$VNET_A_NS" ip link show "$TAP_VM2"
check "tap ${TAP_VM3} in ${VNET_B_NS}"  ip netns exec "$VNET_B_NS" ip link show "$TAP_VM3"

check "host route to ${VM1_IP}"  ip route get "$VM1_IP"
check "host route to ${VM2_IP}"  ip route get "$VM2_IP"
check "host route to ${VM3_IP}"  ip route get "$VM3_IP"

# gateway IPs on bridges
check_pipe "gateway ${VM_GW} on ${VNET_A_BRIDGE}" \
    "ip netns exec ${VNET_A_NS} ip addr show dev ${VNET_A_BRIDGE} | grep -q ${VM_GW}"
check_pipe "gateway ${VM_GW} on ${VNET_B_BRIDGE}" \
    "ip netns exec ${VNET_B_NS} ip addr show dev ${VNET_B_BRIDGE} | grep -q ${VM_GW}"

# vm3 tap must NOT be in vnet-a (L2 isolation check at host level)
if ip netns exec "$VNET_A_NS" ip link show "$TAP_VM3" &>/dev/null; then
    fail "tap ${TAP_VM3} must NOT be in ${VNET_A_NS} (isolation broken)"
else
    ok  "tap ${TAP_VM3} absent from ${VNET_A_NS}"
fi

# ----------------------------------------------------------------------------
# phase 2 — wait for VMs
# ----------------------------------------------------------------------------

echo ""
echo "=== Phase 2: waiting for VMs (SSH, up to ${SSH_TIMEOUT}s each) ==="

if ! command -v sshpass &>/dev/null; then
    echo "[test] sshpass not found — skipping VM-level ping tests"
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed"
    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

vm1_up=0; vm2_up=0; vm3_up=0

echo "[test] waiting for vm1 (${VM1_IP})..."
if wait_tcp "$VM1_IP" 22 "$SSH_TIMEOUT"; then
    ok "vm1 SSH port reachable"; vm1_up=1
else
    fail "vm1 SSH timeout after ${SSH_TIMEOUT}s"
fi

echo "[test] waiting for vm2 (${VM2_IP})..."
if wait_tcp "$VM2_IP" 22 "$SSH_TIMEOUT"; then
    ok "vm2 SSH port reachable"; vm2_up=1
else
    fail "vm2 SSH timeout after ${SSH_TIMEOUT}s"
fi

echo "[test] waiting for vm3 (${VM3_IP})..."
if wait_tcp "$VM3_IP" 22 "$SSH_TIMEOUT"; then
    ok "vm3 SSH port reachable"; vm3_up=1
else
    fail "vm3 SSH timeout after ${SSH_TIMEOUT}s"
fi

# ----------------------------------------------------------------------------
# phase 3 — inter-VM ping (L2 isolation)
# ----------------------------------------------------------------------------

echo ""
echo "=== Phase 3: inter-VM ping ==="

# vm1 → vm2: same vnet-a, must succeed
if [[ $vm1_up -eq 1 && $vm2_up -eq 1 ]]; then
    if ssh_run "$VM1_IP" "ping -c2 -W2 ${VM2_IP}" &>/dev/null; then
        ok "vm1 → vm2 ping OK  (same L2 segment — expected)"
    else
        fail "vm1 → vm2 ping FAILED (same L2 segment — unexpected)"
    fi
else
    echo "[test] skip vm1→vm2 (one or both VMs unreachable)"
fi

# vm1 → vm3: different vnet, must fail (L2 isolation, not firewall)
if [[ $vm1_up -eq 1 && $vm3_up -eq 1 ]]; then
    if ssh_run "$VM1_IP" "ping -c2 -W2 ${VM3_IP}" &>/dev/null; then
        fail "vm1 → vm3 ping succeeded (L2 isolation BROKEN)"
    else
        ok "vm1 → vm3 ping blocked  (L2 isolated — expected)"
    fi
else
    echo "[test] skip vm1→vm3 (one or both VMs unreachable)"
fi

# vm3 → vm1: different vnet, must fail
if [[ $vm3_up -eq 1 && $vm1_up -eq 1 ]]; then
    if ssh_run "$VM3_IP" "ping -c2 -W2 ${VM1_IP}" &>/dev/null; then
        fail "vm3 → vm1 ping succeeded (L2 isolation BROKEN)"
    else
        ok "vm3 → vm1 ping blocked  (L2 isolated — expected)"
    fi
else
    echo "[test] skip vm3→vm1 (one or both VMs unreachable)"
fi

# vm2 → vm3: different vnet, must fail
if [[ $vm2_up -eq 1 && $vm3_up -eq 1 ]]; then
    if ssh_run "$VM2_IP" "ping -c2 -W2 ${VM3_IP}" &>/dev/null; then
        fail "vm2 → vm3 ping succeeded (L2 isolation BROKEN)"
    else
        ok "vm2 → vm3 ping blocked  (L2 isolated — expected)"
    fi
else
    echo "[test] skip vm2→vm3 (one or both VMs unreachable)"
fi

# ----------------------------------------------------------------------------
# phase 4 — QoS benchmark (only when VM_QOS_BENCH=1)
# ----------------------------------------------------------------------------

if [[ "${VM_QOS_BENCH}" -eq 1 ]]; then
    echo ""
    echo "=== Phase 4: QoS benchmark ==="

    # parse_bps <log-line>  →  bytes/sec as integer
    parse_bps() {
        local line=$1
        local val unit
        if [[ "$line" =~ ([0-9]+(\.[0-9]+)?)[[:space:]]*(GB/s|MB/s|kB/s|B/s) ]]; then
            val="${BASH_REMATCH[1]}"
            unit="${BASH_REMATCH[3]}"
            case "$unit" in
                GB/s) echo "${val%.*}000000000" ;;
                MB/s) echo "${val%.*}000000" ;;
                kB/s) echo "${val%.*}000" ;;
                B/s)  echo "${val%.*}" ;;
            esac
        else
            echo "0"
        fi
    }

    for vm_ip in "$VM1_IP" "$VM2_IP" "$VM3_IP"; do
        local_name="vm${vm_ip##*.}"  # vm1 from 192.168.0.1
        if ! ssh_run "$vm_ip" "test -f ${QOS_BENCH_LOG}" &>/dev/null; then
            echo "[bench] ${vm_ip}: log not found — was VM_QOS_BENCH=1 at boot?"
            continue
        fi

        log=$(ssh_run "$vm_ip" "cat ${QOS_BENCH_LOG}")
        write_line=$(echo "$log" | grep -A1 "^--- write" | tail -1)
        read_line=$(echo  "$log" | grep -A1 "^--- read"  | tail -1)

        echo "[bench] ${vm_ip} write: ${write_line}"
        echo "[bench] ${vm_ip} read:  ${read_line}"

        if [[ "${VM_QOS_BPS_LIMIT}" -gt 0 ]]; then
            write_bps=$(parse_bps "$write_line")
            if [[ "$write_bps" -le "${VM_QOS_BPS_LIMIT}" ]]; then
                ok "${vm_ip} write BPS within limit (${write_bps} ≤ ${VM_QOS_BPS_LIMIT})"
            else
                fail "${vm_ip} write BPS exceeded limit (${write_bps} > ${VM_QOS_BPS_LIMIT})"
            fi
        fi
    done
else
    echo ""
    echo "=== Phase 4: QoS benchmark skipped (VM_QOS_BENCH=0) ==="
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
