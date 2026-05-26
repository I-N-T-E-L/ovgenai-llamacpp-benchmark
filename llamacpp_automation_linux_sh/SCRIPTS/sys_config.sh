#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_FILE="$PROJECT_ROOT/config.yaml"

# Helper function to extract specific modinfo fields cleanly
get_driver_meta() {
    local module=$1
    if [ -n "$module" ]; then
        echo "  > Driver: $module"
        modinfo "$module" 2>/dev/null | grep -E "^version:|^description:|^srcversion:" | sed 's/^/    /'
    fi
}

resolve_ov_config() {
    local ov_version_mode=""
    local ov_dest=""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        return 4
    fi

    ov_version_mode=$(yq -r '.openvino.version // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
    if [[ "$ov_version_mode" != "default" && "$ov_version_mode" != "latest" ]]; then
        return 2
    fi

    ov_dest=$(yq -r '.llamacpp_ov_dir // empty' "$CONFIG_FILE")
    if [[ -z "$ov_dest" ]]; then
        return 3
    fi

    if [[ "$ov_version_mode" == "latest" ]]; then
        OV_MODE="LATEST"
        OV_DEST_FOLDER="$ov_dest"
    else
        OV_MODE="DEFAULT"
        OV_DEST_FOLDER="$ov_dest"
    fi

    return 0
}

detect_ov_version() {
    local ov_root="$1"
    local version=""

    if [[ -f "$ov_root/runtime/version.txt" ]]; then
        version=$(head -n 1 "$ov_root/runtime/version.txt" | xargs)
    fi

    [[ -n "$version" ]] && echo "$version" || echo "N/A"
}

echo "=== OS & KERNEL ==="
lsb_release -d | cut -f2
uname -r

echo -e "\n=== SYSTEM HARDWARE ==="
echo "Model: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'N/A')"
echo "CPU: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
if command -v df &> /dev/null; then
    STORAGE_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    echo "Storage : $STORAGE_TOTAL"
else
    echo "Storage : N/A"
fi

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

echo -e "\n=== OPENVINO DETAILS ==="
OV_MODE=""
OV_DEST_FOLDER=""

resolve_ov_config
OV_CFG_STATUS=$?

if [[ $OV_CFG_STATUS -eq 1 ]]; then
    echo "OpenVINO Config: Missing config file at $CONFIG_FILE"
elif [[ $OV_CFG_STATUS -eq 2 ]]; then
    echo "OpenVINO Config Error: openvino.version must be 'default' or 'latest'"
elif [[ $OV_CFG_STATUS -eq 3 ]]; then
    echo "OpenVINO Config Error: Missing llamacpp_ov_dir"
elif [[ $OV_CFG_STATUS -eq 4 ]]; then
    echo "OpenVINO Config Error: yq not found. Run SCRIPTS/dependency_installer.sh"
else
    if [[ "$OV_DEST_FOLDER" != /* ]]; then
        OV_DEST_FOLDER="$PROJECT_ROOT/$OV_DEST_FOLDER"
    fi

    echo "Configured Mode: $OV_MODE"
    echo "Configured Location: $OV_DEST_FOLDER"

    if [[ -f "$OV_DEST_FOLDER/setupvars.sh" ]]; then
        echo "Setupvars: Found"
        echo "OpenVINO Version: $(detect_ov_version "$OV_DEST_FOLDER")"
    else
        echo "Setupvars: Missing ($OV_DEST_FOLDER/setupvars.sh)"
        echo "OpenVINO Version: N/A"
    fi
fi

