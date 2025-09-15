#!/bin/bash
# Script to tune network stack and NIC settings based on installed memory
# Usage: iface-tuning.sh [interface]
# If no interface is specified, the script uses the default gateway interface.

set -euo pipefail

# Maximum per-queue RX/TX buffers
BUFFERS=4096

# --- Find default interface if none given ---
DEFAULTIF=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || true)
IFACE=${1:-"$DEFAULTIF"}

if [[ -z "$IFACE" ]]; then
    echo "Error: No interface specified and no default route found." >&2
    exit 1
fi

if ! command -v ethtool >/dev/null; then
    echo "Error: ethtool not found, cannot tune NIC." >&2
    exit 1
fi

echo "[INFO] Using interface: $IFACE"

# --- Detect physical cores per socket ---
SOCKETS=$(lscpu -p=SOCKET | grep -v '^#' | sort -u | wc -l)
PHYSICAL_CORES=$(lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l)
CORES_PER_SOCKET=$(( PHYSICAL_CORES / SOCKETS ))

echo "[INFO] Detected $PHYSICAL_CORES physical cores across $SOCKETS socket(s)"
echo "[INFO] $CORES_PER_SOCKET physical cores per socket (used for NIC queues)"

# --- Get RX/TX buffer limits from NIC ---
RX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/RX:/ {print $2; exit}' || echo 0)
TX_MAX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/TX:/ {print $2; exit}' || echo 0)

# Scale buffers per queue
RX=$(( RX_MAX < BUFFERS ? RX_MAX : BUFFERS ))
TX=$(( TX_MAX < BUFFERS ? TX_MAX : BUFFERS ))
RX_PER_QUEUE=$(( RX / CORES_PER_SOCKET > 0 ? RX / CORES_PER_SOCKET : 1 ))
TX_PER_QUEUE=$(( TX / CORES_PER_SOCKET > 0 ? TX / CORES_PER_SOCKET : 1 ))

echo "[INFO] RX=$RX (per queue $RX_PER_QUEUE), TX=$TX (per queue $TX_PER_QUEUE)"

# --- Calculate memory-based sysctl buffer sizes with 512 MB cap ---
MEM_BYTES=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
MAX_BUFFER=$((512 * 1024 * 1024))  # 512 MB max per socket

# Scale TCP buffers to ~0.2% of memory, capped
TCP_RMEM_MAX=$(( MEM_BYTES / 512 ))
TCP_WMEM_MAX=$TCP_RMEM_MAX
TCP_RMEM_MAX=$(( TCP_RMEM_MAX > MAX_BUFFER ? MAX_BUFFER : TCP_RMEM_MAX ))
TCP_WMEM_MAX=$(( TCP_WMEM_MAX > MAX_BUFFER ? MAX_BUFFER : TCP_WMEM_MAX ))

# Core buffers scaled similarly, capped
RMEM_MAX=$TCP_RMEM_MAX
WMEM_MAX=$TCP_WMEM_MAX
RMEM_DEFAULT=262144
WMEM_DEFAULT=262144

echo "[INFO] Memory detected: $((MEM_BYTES / 1024 / 1024)) MB"
echo "[INFO] TCP rmem_max=$TCP_RMEM_MAX, wmem_max=$TCP_WMEM_MAX (capped at 512 MB)"
echo "[INFO] Core rmem_max=$RMEM_MAX, wmem_max=$WMEM_MAX"

# --- Apply sysctl settings dynamically, suppress output ---
sysctl --load - <<EOF >/dev/null 2>&1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rmem = 4096 262144 $TCP_RMEM_MAX
net.ipv4.tcp_wmem = 4096 262144 $TCP_WMEM_MAX
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $RMEM_DEFAULT
net.core.wmem_default = $WMEM_DEFAULT
net.core.optmem_max = 65536
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.core.netdev_max_backlog = 500000
net.core.netdev_budget = 60000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_tw_buckets = 200000
vm.max_map_count = 1048576
vm.overcommit_memory = 1
vm.swappiness = 1
kernel.shmmax = 68719476736
EOF

echo "[INFO] Applied sysctl settings based on installed memory"

# --- Helper function to apply ethtool commands silently ---
apply_ethtool() {
    if ! ethtool "$IFACE" "$@" >/dev/null 2>&1; then
        echo "[WARN] Failed to run: ethtool $*"
    fi
}

# --- Apply NIC settings ---
apply_ethtool -G rx "$RX" tx "$TX"
apply_ethtool -K gro on gso on tso on lro on
apply_ethtool -C rx-usecs 50 tx-usecs 50 rx-frames 0 tx-frames 0 \
               rx-usecs-irq 25 rx-frames-irq 0 tx-usecs-irq 25 tx-frames-irq 0
apply_ethtool -L combined "$CORES_PER_SOCKET"

echo "[INFO] NIC tuning complete on $IFACE"
