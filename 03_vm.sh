#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# variables
# ----------------------------------------------------------------------------

VM1_NAME=${VM1_NAME:-vm1}
VM2_NAME=${VM2_NAME:-vm2}
VM3_NAME=${VM3_NAME:-vm3}

VM1_IP=${VM1_IP:-192.168.0.1}
VM2_IP=${VM2_IP:-192.168.0.2}
VM3_IP=${VM3_IP:-192.168.0.3}
VM_GW=${VM_GW:-192.168.0.254}
VM_PREFIX=${VM_PREFIX:-24}

TAP_VM1=${TAP_VM1:-tap-vm1}
TAP_VM2=${TAP_VM2:-tap-vm2}
TAP_VM3=${TAP_VM3:-tap-vm3}

VM1_MAC=${VM1_MAC:-52:54:00:00:00:01}
VM2_MAC=${VM2_MAC:-52:54:00:00:00:02}
VM3_MAC=${VM3_MAC:-52:54:00:00:00:03}

VNET_A_NS=${VNET_A_NS:-vnet-a}
VNET_B_NS=${VNET_B_NS:-vnet-b}

VM_RAM_MB=${VM_RAM_MB:-2048}
VM_CPUS=${VM_CPUS:-1}
VM_CPU_PIN=${VM_CPU_PIN:-0}
VM1_CPUSET=${VM1_CPUSET:-}
VM2_CPUSET=${VM2_CPUSET:-}
VM3_CPUSET=${VM3_CPUSET:-}

VM1_VNC_PORT=${VM1_VNC_PORT:-5901}
VM2_VNC_PORT=${VM2_VNC_PORT:-5902}
VM3_VNC_PORT=${VM3_VNC_PORT:-5903}

CLOUD_INIT_DIR=${CLOUD_INIT_DIR:-/tmp/cloud-init}
VM_PIDDIR=${VM_PIDDIR:-/run/vms}
VM_LOGDIR=${VM_LOGDIR:-/var/log/vms}
CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
CEPH_KEYRING=${CEPH_KEYRING:-/var/snap/microceph/current/conf/ceph.client.admin.keyring}
VM_UEFI=${VM_UEFI:-0}
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}

TMPL_DIR="$(dirname "$0")/templates"

# ----------------------------------------------------------------------------
# functions
# ----------------------------------------------------------------------------

# render_tmpl <template> <key=value> ...
render_tmpl() {
    local tmpl=$1; shift
    local content
    content=$(cat "$tmpl")
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        content=$(echo "$content" | sed "s|__${key}__|${val}|g")
    done
    echo "$content"
}

# make_seed <vm-name> <vm-ip> <vm-mac>
#   creates cloud-init seed ISO for a VM
make_seed() {
    local name=$1 ip=$2 mac=$3
    local dir="${CLOUD_INIT_DIR}/${name}"
    mkdir -p "$dir"

    render_tmpl "${TMPL_DIR}/user-data.tmpl"       "VM_NAME=${name}" \
        > "${dir}/user-data"

    if [[ "${VM_QOS_BENCH:-0}" -eq 1 ]]; then
        local bench_script
        bench_script=$(render_tmpl "${TMPL_DIR}/qos_bench.sh.tmpl" \
            "LOG_PATH=${QOS_BENCH_LOG:-/var/log/qos_bench.log}" \
            "DD_BS=${QOS_BENCH_BS:-4k}" \
            "DD_COUNT=${QOS_BENCH_COUNT:-25600}")
        cat >> "${dir}/user-data" << CLOUDINIT

write_files:
  - path: /usr/local/bin/qos_bench.sh
    permissions: '0755'
    content: |
$(echo "$bench_script" | sed 's/^/      /')

runcmd:
  - /usr/local/bin/qos_bench.sh
CLOUDINIT
    fi

    render_tmpl "${TMPL_DIR}/meta-data.tmpl"       "VM_NAME=${name}" \
        > "${dir}/meta-data"

    cat > "${dir}/network-config" << EOF
version: 2
ethernets:
  id0:
    match:
      macaddress: "${mac}"
    optional: true
    dhcp4: no
    addresses:
      - ${ip}/${VM_PREFIX}
    routes:
      - to: default
        via: ${VM_GW}
    nameservers:
      addresses:
        - 8.8.8.8
EOF

    cloud-localds --network-config="${dir}/network-config" \
        "${dir}/seed.iso" "${dir}/user-data" "${dir}/meta-data"

    echo "[vm] seed ISO ready: ${dir}/seed.iso"
}

# launch_vm <vm-name> <ns> <tap> <vnc-port> <mac> [cpuset]
#   runs QEMU inside the given network namespace;
#   if VM_CPU_PIN=1 and cpuset is non-empty, pins via taskset -c
launch_vm() {
    local name=$1 ns=$2 tap=$3 vnc_port=$4 mac=$5 cpuset=${6:-}
    local img
    img=$(cat "${VM_PIDDIR}/${name}.disk")

    local qos_bps_total=$(( ${VM_QOS_BPS_LIMIT:-0} ))
    local qos_bps_read=$(( ${VM_QOS_READ_BPS_LIMIT:-0} ))
    local qos_bps_write=$(( ${VM_QOS_WRITE_BPS_LIMIT:-0} ))
    local qos_iops_total=$(( ${VM_QOS_IOPS_LIMIT:-0} ))
    local qos_iops_read=$(( ${VM_QOS_READ_IOPS_LIMIT:-0} ))
    local qos_iops_write=$(( ${VM_QOS_WRITE_IOPS_LIMIT:-0} ))
    local qos_bps_burst=$(( ${VM_QOS_BPS_BURST:-0} ))
    local qos_iops_burst=$(( ${VM_QOS_IOPS_BURST:-0} ))

    local throttle=""
    [[ $qos_bps_total  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-total=${qos_bps_total}"
    [[ $qos_bps_read   -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-read=${qos_bps_read}"
    [[ $qos_bps_write  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-write=${qos_bps_write}"
    [[ $qos_iops_total -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-total=${qos_iops_total}"
    [[ $qos_iops_read  -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-read=${qos_iops_read}"
    [[ $qos_iops_write -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-write=${qos_iops_write}"
    [[ $qos_bps_burst  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-total-max=${qos_bps_burst}"
    [[ $qos_iops_burst -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-total-max=${qos_iops_burst}"

    local rbd_drive="format=raw,file=rbd:${img}:conf=${CEPH_CONF}:keyring=${CEPH_KEYRING},if=virtio,cache=none${throttle:+,$throttle}"
    local seed="${CLOUD_INIT_DIR}/${name}/seed.iso"
    local vnc_display=$(( vnc_port - 5900 ))

    local -a qemu_args=(
        -enable-kvm
        -m "$VM_RAM_MB"
        -smp "$VM_CPUS"
        -drive "$rbd_drive"
        -drive "file=${seed},media=cdrom,readonly=on"
        -netdev "tap,id=net0,ifname=${tap},script=no,downscript=no"
        -device "virtio-net-pci,netdev=net0,mac=${mac}"
        -vnc "127.0.0.1:${vnc_display}"
        -serial "file:${VM_LOGDIR}/${name}-console.log"
        -name "$name"
        -daemonize
        -pidfile "${VM_PIDDIR}/${name}.pid"
    )

    if [[ "${VM_UEFI}" -eq 1 ]]; then
        local vars_file="${VM_PIDDIR}/${name}-uefi-vars.fd"
        [[ ! -f "$vars_file" ]] && cp "$OVMF_VARS" "$vars_file"
        qemu_args+=(
            -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
            -drive "if=pflash,format=raw,file=${vars_file}"
        )
    fi

    local -a launcher=(ip netns exec "$ns")
    if [[ "${VM_CPU_PIN}" -eq 1 && -n "$cpuset" ]]; then
        launcher=(taskset -c "$cpuset" ip netns exec "$ns")
        echo "[vm] $name: CPU pinned to $cpuset"
    fi

    "${launcher[@]}" qemu-system-x86_64 "${qemu_args[@]}"

    echo "[vm] $name started — VNC 127.0.0.1:${vnc_port}  console: ${VM_LOGDIR}/${name}-console.log"
}

# ----------------------------------------------------------------------------
# per-VM: seed ISO + launch
# ----------------------------------------------------------------------------

mkdir -p "$VM_PIDDIR" "$VM_LOGDIR" "$CLOUD_INIT_DIR"

make_seed "$VM1_NAME" "$VM1_IP" "$VM1_MAC"
make_seed "$VM2_NAME" "$VM2_IP" "$VM2_MAC"
make_seed "$VM3_NAME" "$VM3_IP" "$VM3_MAC"

# ----------------------------------------------------------------------------
# launch VMs
# ----------------------------------------------------------------------------

launch_vm "$VM1_NAME" "$VNET_A_NS" "$TAP_VM1" "$VM1_VNC_PORT" "$VM1_MAC" "$VM1_CPUSET"
launch_vm "$VM2_NAME" "$VNET_A_NS" "$TAP_VM2" "$VM2_VNC_PORT" "$VM2_MAC" "$VM2_CPUSET"
launch_vm "$VM3_NAME" "$VNET_B_NS" "$TAP_VM3" "$VM3_VNC_PORT" "$VM3_MAC" "$VM3_CPUSET"

echo "[vm] all VMs running"
echo "  VNC access: vncviewer 127.0.0.1:<port>"
echo "  SSH access (password: ubuntu):"
echo "    ssh ubuntu@${VM1_IP}  # ${VM1_NAME}"
echo "    ssh ubuntu@${VM2_IP}  # ${VM2_NAME}"
echo "    ssh ubuntu@${VM3_IP}  # ${VM3_NAME}"
