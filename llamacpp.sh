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
sudo apt-get update || true
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
    vulkan-tools \
    vulkan-utility-libraries-dev \
    spirv-tools \
    glslang-tools \
    libshaderc-dev

# 5. Build 1: Default CPU backend
echo "--- 3. Starting Build: Default CPU ---"
rm -rf build/Release
cmake -B build/Release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/Release --parallel $(nproc)

# 6. Build 2: Vulkan backend (GPU)
echo "--- 4. Starting Build: Vulkan GPU ---"
rm -rf build/ReleaseVulkan
cmake -B build/ReleaseVulkan -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON
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
