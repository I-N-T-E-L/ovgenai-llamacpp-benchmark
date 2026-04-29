#!/bin/bash

# Helper function to extract specific modinfo fields cleanly
get_driver_meta() {
    local module=$1
    if [ -n "$module" ]; then
        echo "  > Driver: $module"
        modinfo "$module" 2>/dev/null | grep -E "^version:|^description:|^srcversion:" | sed 's/^/    /'
    fi
}

echo "=== OS & KERNEL ==="
lsb_release -d | cut -f2
uname -r

echo -e "\n--- SYSTEM HARDWARE ---"
echo "Model: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'N/A')"
echo "CPU: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"

echo -e "\n=== GPU DETAILS ==="
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    # Also get kernel module details for the nvidia driver
    get_driver_meta "nvidia"
else
    # Detect active kernel driver for Integrated/AMD
    GPU_DRIVER=$(lspci -k | grep -A 3 "VGA" | grep "kernel driver in use" | awk '{print $5}')
    lspci -nnk | grep -A 3 "VGA" | grep -E "kernel driver|product"
    get_driver_meta "$GPU_DRIVER"
    
    echo "  > API Version:"
    glxinfo -B 2>/dev/null | grep -E "Device:|Version:" | sed 's/^/    /' || echo "    [Install 'mesa-utils' for GL info]"
fi

echo -e "\n=== NPU DETAILS ==="
# Search for active NPU modules (intel_vpu, amd_npu, etc.)
NPU_MODULE=$(lsmod | grep -iE "intel_vpu|vpu|accel|amd_npu" | awk '{print $1}' | head -n 1)

if [ -n "$NPU_MODULE" ]; then
    echo "NPU Status: Active"
    get_driver_meta "$NPU_MODULE"
elif command -v nputop &> /dev/null; then
    echo "NPU Status: Tool 'nputop' found, but module not detected in lsmod."
else
    # Fallback: Search PCI bus for hardware even if driver is missing
    NPU_CHECK=$(lspci -nn | grep -iE "AI|Accelerator|Neural|NPU")
    if [ -n "$NPU_CHECK" ]; then
        echo "Hardware Found (Driver potentially missing):"
        echo "  $NPU_CHECK"
        # Try to see if a driver is assigned but not loaded
        OFFLINE_DRIVER=$(lspci -k | grep -A 3 -iE "AI|Accelerator|Neural" | grep "kernel driver" | awk '{print $5}')
        [ -n "$OFFLINE_DRIVER" ] && get_driver_meta "$OFFLINE_DRIVER"
    else
        echo "NPU Status: Not detected."
    fi
fi
