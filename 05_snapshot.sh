# #!/usr/bin/env bash
# set -euo pipefail

# ## DUE TO THE ENVIROMENT 


# # ----------------------------------------------------------------------------
# # variables
# # ----------------------------------------------------------------------------

# VM1_NAME=${VM1_NAME:-vm1}
# VM2_NAME=${VM2_NAME:-vm2}
# VM3_NAME=${VM3_NAME:-vm3}

# VM1_MAC=${VM1_MAC:-52:54:00:00:00:01}
# VM2_MAC=${VM2_MAC:-52:54:00:00:00:02}
# VM3_MAC=${VM3_MAC:-52:54:00:00:00:03}

# VM1_VNC_PORT=${VM1_VNC_PORT:-5901}
# VM2_VNC_PORT=${VM2_VNC_PORT:-5902}
# VM3_VNC_PORT=${VM3_VNC_PORT:-5903}

# TAP_VM1=${TAP_VM1:-tap-vm1}
# TAP_VM2=${TAP_VM2:-tap-vm2}
# TAP_VM3=${TAP_VM3:-tap-vm3}

# VNET_A_NS=${VNET_A_NS:-vnet-a}
# VNET_B_NS=${VNET_B_NS:-vnet-b}

# VM_RAM_MB=${VM_RAM_MB:-2048}
# VM_CPUS=${VM_CPUS:-1}

# CEPH_CONF=${CEPH_CONF:-/var/snap/microceph/current/conf/ceph.conf}
# CEPH_KEYRING=${CEPH_KEYRING:-/var/snap/microceph/current/conf/ceph.client.admin.keyring}

# VM_PIDDIR=${VM_PIDDIR:-/run/vms}
# VM_LOGDIR=${VM_LOGDIR:-/var/log/vms}
# CLOUD_INIT_DIR=${CLOUD_INIT_DIR:-/tmp/cloud-init}

# VM_QOS_BPS_LIMIT=${VM_QOS_BPS_LIMIT:-0}
# VM_QOS_READ_BPS_LIMIT=${VM_QOS_READ_BPS_LIMIT:-0}
# VM_QOS_WRITE_BPS_LIMIT=${VM_QOS_WRITE_BPS_LIMIT:-0}
# VM_QOS_IOPS_LIMIT=${VM_QOS_IOPS_LIMIT:-0}
# VM_QOS_READ_IOPS_LIMIT=${VM_QOS_READ_IOPS_LIMIT:-0}
# VM_QOS_WRITE_IOPS_LIMIT=${VM_QOS_WRITE_IOPS_LIMIT:-0}
# VM_QOS_BPS_BURST=${VM_QOS_BPS_BURST:-0}
# VM_QOS_IOPS_BURST=${VM_QOS_IOPS_BURST:-0}

# ALL_VMS=("$VM1_NAME" "$VM2_NAME" "$VM3_NAME")

# # ----------------------------------------------------------------------------
# # helpers
# # ----------------------------------------------------------------------------

# rbd_img() { cat "${VM_PIDDIR}/${1}.disk"; }

# vm_ns() {
#     case "$1" in
#         "$VM1_NAME"|"$VM2_NAME") echo "$VNET_A_NS" ;;
#         "$VM3_NAME")             echo "$VNET_B_NS" ;;
#         *) echo "[snap] unknown VM: $1" >&2; exit 1 ;;
#     esac
# }

# vm_tap() {
#     case "$1" in
#         "$VM1_NAME") echo "$TAP_VM1" ;;
#         "$VM2_NAME") echo "$TAP_VM2" ;;
#         "$VM3_NAME") echo "$TAP_VM3" ;;
#         *) echo "[snap] unknown VM: $1" >&2; exit 1 ;;
#     esac
# }

# vm_vnc_port() {
#     case "$1" in
#         "$VM1_NAME") echo "$VM1_VNC_PORT" ;;
#         "$VM2_NAME") echo "$VM2_VNC_PORT" ;;
#         "$VM3_NAME") echo "$VM3_VNC_PORT" ;;
#         *) echo "[snap] unknown VM: $1" >&2; exit 1 ;;
#     esac
# }

# vm_mac() {
#     case "$1" in
#         "$VM1_NAME") echo "$VM1_MAC" ;;
#         "$VM2_NAME") echo "$VM2_MAC" ;;
#         "$VM3_NAME") echo "$VM3_MAC" ;;
#         *) echo "[snap] unknown VM: $1" >&2; exit 1 ;;
#     esac
# }

# # kill_vm <vm-name>
# kill_vm() {
#     local name=$1
#     local pidfile="${VM_PIDDIR}/${name}.pid"
#     if [[ ! -f "$pidfile" ]]; then
#         echo "[snap] $name: no PID file, skipping"
#         return
#     fi
#     local pid
#     pid=$(cat "$pidfile")
#     if kill -0 "$pid" 2>/dev/null; then
#         kill "$pid"
#         local i=0
#         while kill -0 "$pid" 2>/dev/null && [[ $i -lt 15 ]]; do
#             sleep 1; (( i++ ))
#         done
#         kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
#         echo "[snap] $name stopped (pid $pid)"
#     else
#         echo "[snap] $name: pid $pid not running"
#     fi
#     rm -f "$pidfile"
# }

# # launch_vm <vm-name>
# launch_vm() {
#     local name=$1
#     local ns tap vnc_port mac img vnc_display
#     ns=$(vm_ns "$name")
#     tap=$(vm_tap "$name")
#     vnc_port=$(vm_vnc_port "$name")
#     mac=$(vm_mac "$name")
#     img=$(rbd_img "$name")
#     vnc_display=$(( vnc_port - 5900 ))

#     local qos_bps_total=$(( ${VM_QOS_BPS_LIMIT:-0} ))
#     local qos_bps_read=$(( ${VM_QOS_READ_BPS_LIMIT:-0} ))
#     local qos_bps_write=$(( ${VM_QOS_WRITE_BPS_LIMIT:-0} ))
#     local qos_iops_total=$(( ${VM_QOS_IOPS_LIMIT:-0} ))
#     local qos_iops_read=$(( ${VM_QOS_READ_IOPS_LIMIT:-0} ))
#     local qos_iops_write=$(( ${VM_QOS_WRITE_IOPS_LIMIT:-0} ))
#     local qos_bps_burst=$(( ${VM_QOS_BPS_BURST:-0} ))
#     local qos_iops_burst=$(( ${VM_QOS_IOPS_BURST:-0} ))

#     local throttle=""
#     [[ $qos_bps_total  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-total=${qos_bps_total}"
#     [[ $qos_bps_read   -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-read=${qos_bps_read}"
#     [[ $qos_bps_write  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-write=${qos_bps_write}"
#     [[ $qos_iops_total -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-total=${qos_iops_total}"
#     [[ $qos_iops_read  -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-read=${qos_iops_read}"
#     [[ $qos_iops_write -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-write=${qos_iops_write}"
#     [[ $qos_bps_burst  -gt 0 ]] && throttle+="${throttle:+,}throttling.bps-total-max=${qos_bps_burst}"
#     [[ $qos_iops_burst -gt 0 ]] && throttle+="${throttle:+,}throttling.iops-total-max=${qos_iops_burst}"

#     local rbd_drive="format=raw,file=rbd:${img}:conf=${CEPH_CONF}:keyring=${CEPH_KEYRING},if=virtio,cache=none${throttle:+,$throttle}"
#     local seed="${CLOUD_INIT_DIR}/${name}/seed.iso"

#     ip netns exec "$ns" qemu-system-x86_64 \
#         -enable-kvm \
#         -m "$VM_RAM_MB" \
#         -smp "$VM_CPUS" \
#         -drive "$rbd_drive" \
#         -drive file="$seed",media=cdrom,readonly=on \
#         -netdev tap,id=net0,ifname="$tap",script=no,downscript=no \
#         -device virtio-net-pci,netdev=net0,mac="$mac" \
#         -vnc "127.0.0.1:${vnc_display}" \
#         -serial "file:${VM_LOGDIR}/${name}-console.log" \
#         -name "$name" \
#         -daemonize \
#         -pidfile "${VM_PIDDIR}/${name}.pid"

#     echo "[snap] $name restarted — VNC 127.0.0.1:${vnc_port}"
# }

# # ----------------------------------------------------------------------------
# # snapshot operations
# # ----------------------------------------------------------------------------

# do_create() {
#     local name=$1
#     local img snap_name
#     img=$(rbd_img "$name")
#     snap_name="snap-$(date +%Y%m%d-%H%M%S)"
#     rbd snap create "${img}@${snap_name}"
#     echo "[snap] $name: created ${snap_name}"
# }

# do_list() {
#     local name=$1
#     local img
#     img=$(rbd_img "$name")
#     echo "[snap] $name:"
#     rbd snap ls "$img"
# }

# do_rollback() {
#     local name=$1 snap_name=$2
#     local img
#     img=$(rbd_img "$name")
#     kill_vm "$name"
#     rbd snap rollback "${img}@${snap_name}"
#     echo "[snap] $name: rolled back to ${snap_name}"
#     launch_vm "$name"
# }

# do_purge() {
#     local name=$1
#     local img
#     img=$(rbd_img "$name")
#     rbd snap purge "$img"
#     echo "[snap] $name: all snapshots purged"
# }

# # ----------------------------------------------------------------------------
# # dispatch
# # ----------------------------------------------------------------------------

# CMD=${1:-}
# shift || true

# case "$CMD" in
#     create)
#         target=${1:-all}
#         if [[ "$target" == "all" ]]; then
#             for vm in "${ALL_VMS[@]}"; do do_create "$vm"; done
#         else
#             do_create "$target"
#         fi
#         ;;
#     list)
#         target=${1:-all}
#         if [[ "$target" == "all" ]]; then
#             for vm in "${ALL_VMS[@]}"; do do_list "$vm"; done
#         else
#             do_list "$target"
#         fi
#         ;;
#     rollback)
#         vm=${1:-}; snap=${2:-}
#         [[ -n "$vm" && -n "$snap" ]] || { echo "Usage: $0 rollback <vm> <snap>" >&2; exit 1; }
#         do_rollback "$vm" "$snap"
#         ;;
#     purge)
#         target=${1:-all}
#         if [[ "$target" == "all" ]]; then
#             for vm in "${ALL_VMS[@]}"; do do_purge "$vm"; done
#         else
#             do_purge "$target"
#         fi
#         ;;
#     *)
#         echo "Usage: $0 {create|list|rollback|purge} [vm|all] [snap-name]" >&2
#         exit 1
#         ;;
# esac