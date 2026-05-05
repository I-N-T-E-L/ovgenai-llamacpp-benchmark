#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

# Exit immediately if a command exits with a non-zero status
set -e

CONFIG_FILE="$PROJECT_ROOT/config.txt"
LLAMA_REPO_URL="https://github.com/ggml-org/llama.cpp"
LLAMA_DIR="$PROJECT_ROOT/STORE/llama_cpp"
LLAMA_LOG_FILE="$PROJECT_ROOT/STORE/logs/llama_cpp_commit.txt"
BUILD_ROOT="$LLAMA_DIR/build"
SKIP_REASON=""
COMMIT_MATCH=false
REMOTE_FULL_COMMIT=""
NEED_FULL_REBUILD=true
NEED_BUILD_RELEASE=true
NEED_BUILD_VULKAN=true
NEED_BUILD_OV=true

resolve_ov_dest_from_config() {
    local section=""
    local ov_subsection=""
    local line header
    local has_default=false
    local has_latest=false
    local default_dest=""
    local latest_dest=""

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
            if [[ "$ov_subsection" == "DEFAULT" ]]; then
                [[ -z "$default_dest" ]] && default_dest="${line#*=}"
            elif [[ "$ov_subsection" == "LATEST" ]]; then
                [[ -z "$latest_dest" ]] && latest_dest="${line#*=}"
            fi
        fi
    done < "$CONFIG_FILE"

    if [[ "$has_default" == true && "$has_latest" == true ]]; then
        echo "Error: Both [DEFAULT] and [LATEST] are active under [OV_DOWNLOAD]. Keep exactly one active subsection and comment out the other." >&2
        return 1
    fi

    if [[ "$has_default" == false && "$has_latest" == false ]]; then
        echo "Error: Neither [DEFAULT] nor [LATEST] is active under [OV_DOWNLOAD]. Uncomment exactly one subsection." >&2
        return 1
    fi

    if [[ "$has_latest" == true ]]; then
        echo "$latest_dest"
    else
        echo "$default_dest"
    fi
}

check_commit_match() {
    local remote_commit logged_commit remote_short

    if [[ ! -d "$LLAMA_DIR" ]]; then
        SKIP_REASON="No existing folder at $LLAMA_DIR"
        return 1
    fi

    if [[ ! -f "$LLAMA_LOG_FILE" ]]; then
        SKIP_REASON="Missing commit log at $LLAMA_LOG_FILE"
        return 1
    fi

    remote_commit=$(git ls-remote "$LLAMA_REPO_URL" HEAD 2>/dev/null | awk '{print $1}')
    if [[ -z "$remote_commit" ]]; then
        SKIP_REASON="Could not fetch remote HEAD from $LLAMA_REPO_URL"
        return 1
    fi
    REMOTE_FULL_COMMIT="$remote_commit"

    logged_commit=$(awk 'NR==1{print $1}' "$LLAMA_LOG_FILE")
    if [[ -z "$logged_commit" ]]; then
        SKIP_REASON="Commit log file is empty or malformed: $LLAMA_LOG_FILE"
        return 1
    fi

    remote_short="${remote_commit:0:${#logged_commit}}"
    if [[ "$remote_short" == "$logged_commit" ]]; then
        SKIP_REASON="Remote HEAD matches logged commit (${logged_commit})"
        COMMIT_MATCH=true
        return 0
    fi

    SKIP_REASON="Remote HEAD (${remote_commit:0:12}) differs from logged commit (${logged_commit})"
    COMMIT_MATCH=false
    return 1
}

update_commit_log() {
    local commit_for_log short_commit commit_subject

    commit_for_log="$REMOTE_FULL_COMMIT"
    if [[ -z "$commit_for_log" ]]; then
        commit_for_log=$(git rev-parse HEAD 2>/dev/null || true)
    fi

    if [[ -z "$commit_for_log" ]]; then
        echo "Warning: Could not determine commit for $LLAMA_LOG_FILE; keeping previous log."
        return
    fi

    short_commit="${commit_for_log:0:9}"
    commit_subject=$(git log -1 --format=%s "$commit_for_log" 2>/dev/null || git log -1 --format=%s HEAD)

    mkdir -p "$(dirname "$LLAMA_LOG_FILE")"
    echo "$short_commit $commit_subject" > "$LLAMA_LOG_FILE"
    echo "Saved commit info to $LLAMA_LOG_FILE: $short_commit"
}

plan_builds() {
    if check_commit_match && [[ -d "$BUILD_ROOT" ]]; then
        NEED_FULL_REBUILD=false

        [[ -x "$BUILD_ROOT/Release/bin/llama-bench" ]] && NEED_BUILD_RELEASE=false
        [[ -x "$BUILD_ROOT/ReleaseVulkan/bin/llama-bench" ]] && NEED_BUILD_VULKAN=false
        [[ -x "$BUILD_ROOT/ReleaseOV/bin/llama-bench" ]] && NEED_BUILD_OV=false

        if [[ "$NEED_BUILD_RELEASE" == false && "$NEED_BUILD_VULKAN" == false && "$NEED_BUILD_OV" == false ]]; then
            echo "Skip check: $SKIP_REASON"
            echo "All build targets already exist for current commit. Skipping install and build steps."
            exit 0
        fi

        echo "Skip check: $SKIP_REASON"
        echo "Incremental build mode: rebuilding only missing targets."
        return
    fi

    NEED_FULL_REBUILD=true
    NEED_BUILD_RELEASE=true
    NEED_BUILD_VULKAN=true
    NEED_BUILD_OV=true

    if [[ "$COMMIT_MATCH" == true ]]; then
        SKIP_REASON="Build directory missing at $BUILD_ROOT"
    fi

    echo "Skip check: $SKIP_REASON"
    echo "Full rebuild mode: commit changed or build directory missing."
}

plan_builds

if [[ "$NEED_FULL_REBUILD" == true ]]; then
    rm -rf "$LLAMA_DIR"
fi

echo "--- 1. Setting up Environment ---"
# Create STORE and logs directory if they don't exist
mkdir -p STORE/logs

# 2. Cloning Repository
cd "$PROJECT_ROOT/STORE"
if [[ "$NEED_FULL_REBUILD" == true ]]; then
    echo "Full rebuild: cloning fresh llama.cpp repository..."
    git clone "$LLAMA_REPO_URL" "$LLAMA_DIR"
    cd "$LLAMA_DIR"
else
    if [ -d "$LLAMA_DIR" ]; then
        echo "Folder llama_cpp already exists. Using current commit for incremental build..."
        cd "$LLAMA_DIR"
    else
        echo "llama_cpp folder missing in incremental mode. Cloning..."
        git clone "$LLAMA_REPO_URL" "$LLAMA_DIR"
        cd "$LLAMA_DIR"
    fi
fi

# 3. Logging Commit Version
update_commit_log

# 4. Installing Prerequisites
if [[ "$NEED_FULL_REBUILD" == true ]]; then
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
        spirv-headers \
        glslang-tools \
        shaderc
else
    echo "--- 2. Skipping dependency installation (incremental build mode) ---"
fi

# 5. Build 1: Default CPU backend
if [[ "$NEED_BUILD_RELEASE" == true ]]; then
    echo "--- 3. Starting Build: Default CPU ---"
    rm -rf build/Release
    cmake -B build/Release -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=OFF -DBUILD_SHARED_LIBS=OFF
    cmake --build build/Release --parallel $(nproc)
else
    echo "--- 3. Skipping Build: Default CPU already exists ---"
fi

# 6. Build 2: Vulkan backend (GPU)
if [[ "$NEED_BUILD_VULKAN" == true ]]; then
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
        -DCMAKE_INCLUDE_PATH="${VULKAN_INCLUDE_DIR}" \
        -DBUILD_SHARED_LIBS=OFF
    cmake --build build/ReleaseVulkan --parallel $(nproc)
else
    echo "--- 4. Skipping Build: Vulkan GPU already exists ---"
fi

# 7. Build 3: OpenVINO backend (CPU, GPU, NPU)
if [[ "$NEED_BUILD_OV" == true ]]; then
    echo "--- 5. Starting Build: OpenVINO ---"
    OV_DEST_FOLDER=$(resolve_ov_dest_from_config)

    if [[ -z "$OV_DEST_FOLDER" ]]; then
        echo "Error: DEST_FOLDER not found in active [OV_DOWNLOAD] mode in $CONFIG_FILE"
        exit 1
    fi

    OV_VARS="${OV_DEST_FOLDER}/setupvars.sh"

    if [[ -f "$OV_VARS" ]]; then
        # We use '.' instead of 'source' for maximum shell compatibility
        . "$OV_VARS"
        rm -rf build/ReleaseOV
        cmake -B build/ReleaseOV -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_OPENVINO=ON -DBUILD_SHARED_LIBS=OFF
        cmake --build build/ReleaseOV --parallel $(nproc)
    else
        echo "Warning: OpenVINO setupvars.sh not found at $OV_VARS. Skipping OV build."
    fi
else
    echo "--- 5. Skipping Build: OpenVINO already exists ---"
fi

echo "------------------------------------------------"
echo "All builds completed successfully!"
echo "Binaries are located in build/Release, build/ReleaseVulkan, and build/ReleaseOV"

