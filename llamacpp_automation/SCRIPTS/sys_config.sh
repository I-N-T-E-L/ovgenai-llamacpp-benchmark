#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_FILE="$PROJECT_ROOT/config.txt"

# Helper function to extract specific modinfo fields cleanly
get_driver_meta() {
    local module=$1
    if [ -n "$module" ]; then
        echo "  > Driver: $module"
        modinfo "$module" 2>/dev/null | grep -E "^version:|^description:|^srcversion:" | sed 's/^/    /'
    fi
}

resolve_ov_config() {
    local section=""
    local ov_subsection=""
    local line=""
    local header=""
    local has_default=false
    local has_latest=false
    local default_dest=""
    local latest_dest=""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$line" ]] && continue

        if [[ "$section" == "OV_DOWNLOAD" && "$line" =~ ^#\s*\[(DEFAULT|LATEST)\]$ ]]; then
            ov_subsection=""
            continue
        fi

        [[ "$line" == "#"* ]] && continue

        if [[ "$line" =~ ^\[.*\]$ ]]; then
            header="${line:1:${#line}-2}"

            if [[ "$section" == "OV_DOWNLOAD" && ( "$header" == "DEFAULT" || "$header" == "LATEST" ) ]]; then
                ov_subsection="$header"
                if [[ "$header" == "DEFAULT" ]]; then
                    has_default=true
                else
                    has_latest=true
                fi
                continue
            fi

            section="$header"
            if [[ "$section" != "OV_DOWNLOAD" ]]; then
                ov_subsection=""
            fi
            continue
        fi

        if [[ "$section" == "OV_DOWNLOAD" && "$line" == DEST_FOLDER=* ]]; then
            if [[ "$ov_subsection" == "DEFAULT" && -z "$default_dest" ]]; then
                default_dest="${line#*=}"
            elif [[ "$ov_subsection" == "LATEST" && -z "$latest_dest" ]]; then
                latest_dest="${line#*=}"
            fi
        fi
    done < "$CONFIG_FILE"

    if [[ "$has_default" == true && "$has_latest" == true ]]; then
        return 2
    fi

    if [[ "$has_default" == false && "$has_latest" == false ]]; then
        return 3
    fi

    if [[ "$has_latest" == true ]]; then
        OV_MODE="LATEST"
        OV_DEST_FOLDER="$latest_dest"
    else
        OV_MODE="DEFAULT"
        OV_DEST_FOLDER="$default_dest"
    fi

    return 0
}

detect_ov_version() {
    local ov_root="$1"
    local version=""

    if [[ -f "$ov_root/runtime/version.txt" ]]; then
        version=$(head -n 1 "$ov_root/runtime/version.txt" | xargs)
    fi

    if [[ -z "$version" ]]; then
        local base_name
        base_name=$(basename "$ov_root")
        if [[ "$base_name" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
            version="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ -z "$version" && -f "$ov_root/setupvars.sh" ]]; then
        version=$(bash -c "source \"$ov_root/setupvars.sh\" >/dev/null 2>&1; python3 -c 'import openvino as ov; print(ov.__version__)'" 2>/dev/null | head -n 1 | xargs)
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
    echo "OpenVINO Config Error: Both [DEFAULT] and [LATEST] are active under [OV_DOWNLOAD]"
elif [[ $OV_CFG_STATUS -eq 3 ]]; then
    echo "OpenVINO Config Error: Neither [DEFAULT] nor [LATEST] is active under [OV_DOWNLOAD]"
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

