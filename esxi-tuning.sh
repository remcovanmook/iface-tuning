#!/bin/bash

# Needs testing, report issues

# Define your network interface
NIC="vmnic0"  # Adjust to your interface

echo "Tuning NIC: $NIC"

# Ensure MTU 1500
esxcli network nic set -n $NIC -m 1500

# Enable Receive Side Scaling (RSS)
esxcli system settings advanced set -o /Net/NetNetRssEnable -i 1

# --- Detect PCI address of NIC ---
PCI_ADDR=$(esxcli network nic list | grep -w $NIC | awk '{print $1}')
if [ -z "$PCI_ADDR" ]; then
    echo "Error: Could not find PCI address for $NIC"
    exit 1
fi

# --- Find NUMA node of NIC ---
NUMA_NODE=$(esxcli hardware pci list | grep -A5 $PCI_ADDR | grep "NUMA Node" | awk '{print $NF}')
if [ -z "$NUMA_NODE" ]; then
    echo "Warning: Could not detect NUMA node, defaulting to 0"
    NUMA_NODE=0
fi

# --- Detect physical cores on that NUMA node ---
# Uses esxcli cpu list
PHYS_CORES=$(esxcli hardware cpu list | awk -v numa=$NUMA_NODE '
$0 ~ "NUMA node" {curr=$NF}
$0 ~ "Thread" {if(curr==numa){count++}}
END {print count/2}')  # Divide by 2 to get physical cores from hyperthreads

if [ -z "$PHYS_CORES" ] || [ "$PHYS_CORES" -lt 1 ]; then
    echo "Warning: Could not detect physical cores, defaulting to 26"
    PHYS_CORES=26
fi

echo "NIC $NIC attached to NUMA node $NUMA_NODE with $PHYS_CORES physical cores"
RSS_QUEUES=$PHYS_CORES

# Apply RSS queues
esxcli system settings advanced set -o /Net/NetNetRssQueueCount -i $RSS_QUEUES

# Disable TSO and LRO for lower latency
esxcli system module parameters set -m vmxnet3 -p "disable_tso=1"
esxcli system module parameters set -m vmxnet3 -p "disable_lro=1"

# Increase receive and transmit buffers
esxcli system settings advanced set -o /Net/NetRxBufSize -i 262144
esxcli system settings advanced set -o /Net/NetTxBufSize -i 262144

# Enable Adaptive Interrupt Moderation
esxcli system settings advanced set -o /Net/NetInterruptModeration -i 1

# Reload vmxnet3 module
esxcli system module parameters load -m vmxnet3

echo "ESXi network tuning applied successfully:"
echo "  NIC=$NIC"
echo "  MTU=1500"
echo "  RSS queues=$RSS_QUEUES"
echo "  NUMA node=$NUMA_NODE"
