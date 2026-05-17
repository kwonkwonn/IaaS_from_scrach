.EXPORT_ALL_VARIABLES:
SHELL := /bin/bash

# ── Ceph ────────────────────────────────────────────────────────────────────
CEPH_POOL        := vms
CEPH_CONF        := /var/snap/microceph/current/conf/ceph.conf
CEPH_KEYRING     := /var/snap/microceph/current/conf/ceph.client.admin.keyring
VM_DISK_SIZE     := 20G

# ── VM ──────────────────────────────────────────────────────────────────────
VM_RAM_MB        := 2048
VM_CPUS          := 1

VM1_NAME         := vm1
VM2_NAME         := vm2
VM3_NAME         := vm3

VM1_IP           := 192.168.0.1
VM2_IP           := 192.168.0.2
VM3_IP           := 192.168.0.3

VM1_MAC          := 52:54:00:00:00:01
VM2_MAC          := 52:54:00:00:00:02
VM3_MAC          := 52:54:00:00:00:03
VM_GW            := 192.168.0.254
VM_PREFIX        := 24

VM1_VNC_PORT     := 5901
VM2_VNC_PORT     := 5902
VM3_VNC_PORT     := 5903

VM1_SSH_PORT     := 2201
VM2_SSH_PORT     := 2202
VM3_SSH_PORT     := 2203

VM_USER          := ubuntu
VM_PASS          := ubuntu

# ── Network ─────────────────────────────────────────────────────────────────
VNET_A_NS        := vnet-a
VNET_B_NS        := vnet-b

VNET_A_BRIDGE    := br-vnet-a
VNET_B_BRIDGE    := br-vnet-b

TAP_VM1          := tap-vm1
TAP_VM2          := tap-vm2
TAP_VM3          := tap-vm3

VETH_A_HOST      := veth-a-host
VETH_A_NS        := veth-a-ns
VETH_B_HOST      := veth-b-host
VETH_B_NS        := veth-b-ns

VETH_A_HOST_IP   := 10.0.0.1
VETH_A_NS_IP     := 10.0.0.2
VETH_B_HOST_IP   := 10.0.1.1
VETH_B_NS_IP     := 10.0.1.2
VETH_PREFIX      := 30

# ── Cloud image ─────────────────────────────────────────────────────────────
CLOUD_IMAGE_URL  := https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
CLOUD_IMAGE_FILE := /tmp/noble-cloudimg.img

# ── Runtime dirs ────────────────────────────────────────────────────────────
VM_PIDDIR        := /run/vms
VM_LOGDIR        := /var/log/vms
CLOUD_INIT_DIR   := /tmp/cloud-init
DISK_DIR         := /var/lib/vm-disks

# ── Targets ─────────────────────────────────────────────────────────────────
.PHONY: all prereq microceph network vms test clean

all: prereq microceph network vms

prereq:
	bash 00_prereq.sh

microceph: prereq
	bash 01_microceph.sh

network: prereq
	bash 02_network.sh

vms: microceph network
	bash 03_vm.sh

test:
	bash 04_test.sh

clean:
	bash cleanup.sh
