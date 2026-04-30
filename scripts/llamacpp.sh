#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "--- 1. Setting up Environment ---"
# Create logs directory if it doesn't exist
mkdir -p logs

# 2. Cloning Repository
if [ -d "llama.cpp" ]; then
    echo "Folder llama.cpp already exists. Updating..."
    cd llama.cpp
    git pull
else
    echo "Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp
    cd llama.cpp
fi

# 3. Logging Commit Version
echo "Saving commit info to logs/llama_cpp_commit.txt"
git log -1 --oneline > ../logs/llama_cpp_commit.txt

# 4. Installing Prerequisites
echo "--- 2. Installing Dependencies (Requires Sudo) ---"

UBUNTU_CODENAME=$(lsb_release -sc)
wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc > /dev/null
sudo wget -qO "/etc/apt/sources.list.d/lunarg-vulkan-${UBUNTU_CODENAME}.list" \
    "https://packages.lunarg.com/vulkan/lunarg-vulkan-${UBUNTU_CODENAME}.list" || \
    echo "Warning: LunarG repo not available for ${UBUNTU_CODENAME}, will fall back to distro Vulkan packages."

sudo apt-get update || true
sudo apt-get remove -y libshaderc-dev || true
sudo apt-get install -y \
    build-essential \
    libcurl4-openssl-dev \
    libtbb12 \
    cmake \
    ninja-build \
    python3-pip \
    curl \
    wget \
    tar \
    ocl-icd-opencl-dev \
    opencl-headers \
    opencl-clhpp-headers \
    intel-opencl-icd \
    libvulkan-dev \
    vulkan-headers \
    vulkan-tools \
    vulkan-utility-libraries-dev \
    spirv-tools \
    glslang-tools \
    shaderc

# 5. Build 1: Default CPU backend
echo "--- 3. Starting Build: Default CPU ---"
rm -rf build/Release
cmake -B build/Release -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=OFF
cmake --build build/Release --parallel $(nproc)

# 6. Build 2: Vulkan backend (GPU)
echo "--- 4. Starting Build: Vulkan GPU ---"
# Verify Vulkan headers are present; if not, attempt a direct install before failing
VULKAN_CORE_H=$(find /usr/include /usr/local/include -name "vulkan_core.h" 2>/dev/null | head -1)
if [ -z "${VULKAN_CORE_H}" ]; then
    echo "Vulkan headers missing after install — retrying with distro packages..."
    sudo apt-get install -y libvulkan-dev vulkan-headers spirv-tools glslang-tools
    VULKAN_CORE_H=$(find /usr/include /usr/local/include -name "vulkan_core.h" 2>/dev/null | head -1)
fi
if [ -z "${VULKAN_CORE_H}" ]; then
    echo "ERROR: vulkan/vulkan_core.h not found. Cannot build Vulkan backend." >&2
    exit 1
fi

# Resolve the parent dir that contains the vulkan/ subdirectory (i.e. the dir with vulkan/vulkan_core.h)
VULKAN_INCLUDE_DIR=""
for candidate in \
    "/usr/include" \
    "/usr/local/include" \
    "/opt/vulkan-sdk/include" \
    $(pkg-config --variable=includedir vulkan 2>/dev/null || true); do
    if [ -f "${candidate}/vulkan/vulkan_core.h" ]; then
        VULKAN_INCLUDE_DIR="${candidate}"
        break
    fi
done

if [ -z "${VULKAN_INCLUDE_DIR}" ]; then
    echo "ERROR: vulkan/vulkan_core.h not found in any standard location. Cannot build Vulkan backend." >&2
    exit 1
fi
echo "Using Vulkan include dir: ${VULKAN_INCLUDE_DIR}"

rm -rf build/ReleaseVulkan
cmake -B build/ReleaseVulkan -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON \
    -DVulkan_INCLUDE_DIR="${VULKAN_INCLUDE_DIR}" \
    -DCMAKE_INCLUDE_PATH="${VULKAN_INCLUDE_DIR}"
cmake --build build/ReleaseVulkan --parallel $(nproc)

# 7. Build 3: OpenVINO backend (CPU, GPU, NPU)
echo "--- 5. Starting Build: OpenVINO ---"
OV_VARS="/opt/intel/openvino/setupvars.sh"

if [[ -f "$OV_VARS" ]]; then
    # We use '.' instead of 'source' for maximum shell compatibility
    . "$OV_VARS"
    cmake -B build/ReleaseOV -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_OPENVINO=ON
    cmake --build build/ReleaseOV --parallel $(nproc)
else
    echo "Warning: OpenVINO setupvars.sh not found at $OV_VARS. Skipping OV build."
fi

echo "------------------------------------------------"
echo "All builds completed successfully!"
echo "Binaries are located in build/Release, build/ReleaseVulkan, and build/ReleaseOV"
