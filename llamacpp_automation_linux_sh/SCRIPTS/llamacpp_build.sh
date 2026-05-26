#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

# Exit immediately if a command exits with a non-zero status
set -e

CONFIG_FILE="$PROJECT_ROOT/config.yaml"
LLAMA_REPO_URL="https://github.com/ggml-org/llama.cpp"
LLAMA_DIR=""
LLAMA_LOG_FILE=""
OV_LOG_FILE=""
BUILD_ROOT=""
SKIP_REASON=""
COMMIT_MATCH=false
REMOTE_FULL_COMMIT=""
NEED_FULL_REBUILD=true
NEED_BUILD_RELEASE=true
NEED_BUILD_VULKAN=true
NEED_BUILD_OV=true
OV_ACTIVE_MODE=""
OV_TARGET_SEMVER=""
OV_CURRENT_VERSION=""
OV_MODE_TARGET_CHECK_REASON=""
OV_STATUS_NOTE=""
SKIP_DEP_INSTALL="${SKIP_DEP_INSTALL:-no}"
YQ_VERSION="${YQ_VERSION:-latest}"
LLAMACPP_USE_MODE="build"
LLAMA_RELEASE_TAG=""
LLAMA_RELEASE_CPU_URL=""
LLAMA_RELEASE_VULKAN_URL=""
LLAMA_RELEASE_OPENVINO_URL=""
LLAMA_RELEASE_OPENVINO_VERSION=""
RELEASE_OV_REQUIRED_SONAME=""
RELEASE_OV_RUNTIME_DIR=""

ensure_dependencies_installed() {
    local APT_PREFIX=""
    local apt_update_done="false"
    local USER_BIN=""
    local -a required_pkgs=(
        build-essential
        libcurl4-openssl-dev
        libtbb12
        cmake
        ninja-build
        python3
        python3-pip
        curl
        wget
        tar
        ocl-icd-opencl-dev
        opencl-headers
        opencl-clhpp-headers
        intel-opencl-icd
        libvulkan-dev
        vulkan-headers
        vulkan-tools
        vulkan-utility-libraries-dev
        spirv-tools
        spirv-headers
        glslang-tools
        shaderc
        jq
    )
    local pkg=""
    local all_pkgs_present="true"

    if [[ "$SKIP_DEP_INSTALL" =~ ^([Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1)$ ]]; then
        echo "Skipping dependency installation (SKIP_DEP_INSTALL=$SKIP_DEP_INSTALL)."
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "Error: Dependency installation currently supports Linux/apt environments only." >&2
        return 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "Error: apt-get not found. Install dependencies manually for your distro." >&2
        return 1
    fi

    if ! command -v dpkg >/dev/null 2>&1; then
        echo "Error: dpkg not found. This script expects a Debian/Ubuntu base." >&2
        return 1
    fi

    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            all_pkgs_present="false"
            break
        fi
    done

    if [[ "$all_pkgs_present" == "true" ]] \
        && command -v cmake >/dev/null 2>&1 \
        && command -v ninja >/dev/null 2>&1 \
        && command -v jq >/dev/null 2>&1 \
        && command -v yq >/dev/null 2>&1 \
        && yq -n '.' >/dev/null 2>&1; then
        echo "Dependency check: all required packages/tools already installed. Skipping apt refresh/install."
        return 0
    fi

    if [[ "$EUID" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            APT_PREFIX="sudo"
            echo "Sudo access is required for dependency installation."
            if ! sudo -v; then
                echo "Error: sudo authentication failed. Cannot install dependencies." >&2
                return 1
            fi
        else
            echo "Error: sudo is required when not running as root." >&2
            return 1
        fi
    fi

    yq_is_healthy() {
        command -v yq >/dev/null 2>&1 && yq -n '.' >/dev/null 2>&1
    }

    disable_broken_ddebs_security_repo() {
        local changed="false"
        local file=""

        for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [[ -f "$file" ]] || continue

            if grep -Eq '^[[:space:]]*deb[[:space:]].*ddebs\.ubuntu\.com.*noble-security' "$file"; then
                echo "Disabling broken ddebs noble-security entry in $file"
                $APT_PREFIX sed -i.bak -E \
                    '/^[[:space:]]*deb[[:space:]].*ddebs\.ubuntu\.com.*noble-security/s/^/# disabled by llamacpp_build: /' \
                    "$file"
                changed="true"
            fi
        done

        [[ "$changed" == "true" ]]
    }

    disable_intel_oneapi_repo() {
        local changed="false"
        local file=""
        local base=""
        local disabled_path=""

        # Disable dedicated oneAPI source files outright (.list or deb822 .sources).
        for file in /etc/apt/sources.list.d/*; do
            [[ -f "$file" ]] || continue

            if grep -Eq 'apt\.repos\.intel\.com/oneapi' "$file"; then
                base=$(basename "$file")
                disabled_path="/etc/apt/sources.list.d/${base}.disabled"
                echo "Disabling Intel oneAPI apt source file $file -> $disabled_path"
                if [[ -f "$disabled_path" ]]; then
                    $APT_PREFIX rm -f "$disabled_path"
                fi
                $APT_PREFIX mv "$file" "$disabled_path"
                changed="true"
            fi
        done

        # Also handle inline entries that may be mixed inside sources.list.
        for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [[ -f "$file" ]] || continue

            if grep -Eq '^[[:space:]]*deb[[:space:]].*apt\.repos\.intel\.com/oneapi' "$file"; then
                echo "Disabling Intel oneAPI apt source in $file"
                $APT_PREFIX sed -i.bak -E \
                    '/^[[:space:]]*deb[[:space:]].*apt\.repos\.intel\.com\/oneapi/s/^/# disabled by llamacpp_build: /' \
                    "$file"
                changed="true"
            fi
        done

        [[ "$changed" == "true" ]]
    }

    apt_update_once() {
        if [[ "$apt_update_done" == "false" ]]; then
            echo "Updating apt package index..."
            if ! $APT_PREFIX apt-get update; then
                echo "Warning: apt-get update failed. Attempting to auto-fix known broken ddebs noble-security repo..."

                if disable_broken_ddebs_security_repo; then
                    echo "Retrying apt package index update after repo fix..."
                    $APT_PREFIX apt-get update
                else
                    echo "Error: apt-get update failed and no known auto-fix applied."
                    echo "Please fix apt repositories, then rerun SCRIPTS/llamacpp_build.sh"
                    return 1
                fi
            fi
            apt_update_done="true"
        fi
    }

    install_apt_pkg() {
        local pkg="$1"
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            apt_update_once
            echo "Installing $pkg..."
            $APT_PREFIX apt-get install -y "$pkg"
        fi
    }

    configure_lunarg_repo() {
        local ubuntu_codename=""

        if command -v lsb_release >/dev/null 2>&1; then
            ubuntu_codename=$(lsb_release -sc)
        elif [[ -f /etc/os-release ]]; then
            ubuntu_codename=$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
        fi

        if [[ -z "$ubuntu_codename" ]]; then
            echo "Warning: Could not detect Ubuntu codename, skipping LunarG repo setup."
            return
        fi

        if ! command -v wget >/dev/null 2>&1; then
            echo "Warning: wget not available yet, skipping LunarG repo setup."
            return
        fi

        echo "Configuring LunarG Vulkan repository for ${ubuntu_codename}..."
        wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | $APT_PREFIX tee /etc/apt/trusted.gpg.d/lunarg.asc > /dev/null
        $APT_PREFIX wget -qO "/etc/apt/sources.list.d/lunarg-vulkan-${ubuntu_codename}.list" \
            "https://packages.lunarg.com/vulkan/lunarg-vulkan-${ubuntu_codename}.list" || \
            echo "Warning: LunarG repo not available for ${ubuntu_codename}, using distro Vulkan packages."

        apt_update_done="false"
    }

    echo "--- 0. Ensuring build dependencies are installed ---"
    disable_intel_oneapi_repo || true
    configure_lunarg_repo
    apt_update_once
    $APT_PREFIX apt-get remove -y libshaderc-dev || true

    for pkg in "${required_pkgs[@]}"; do
        install_apt_pkg "$pkg"
    done

    echo "--- Installing Python-based yq ---"
    if yq_is_healthy; then
        echo "yq is already installed and healthy; skipping yq install."
    else
        if [[ "$EUID" -eq 0 ]]; then
            if command -v pipx >/dev/null 2>&1; then
                echo "Trying pipx global install for yq..."
                if [[ "$YQ_VERSION" == "latest" ]]; then
                    pipx install --global yq || pipx upgrade --global yq || true
                else
                    pipx install --global "yq==${YQ_VERSION}" || pipx upgrade --global "yq==${YQ_VERSION}" || true
                fi
            fi

            if ! yq_is_healthy; then
                if [[ "$YQ_VERSION" == "latest" ]]; then
                    if ! python3 -m pip install --upgrade yq; then
                        echo "pip install failed in externally-managed environment. Retrying with --break-system-packages..."
                        python3 -m pip install --break-system-packages --upgrade yq
                    fi
                else
                    if ! python3 -m pip install --upgrade "yq==${YQ_VERSION}"; then
                        echo "pip install failed in externally-managed environment. Retrying with --break-system-packages..."
                        python3 -m pip install --break-system-packages --upgrade "yq==${YQ_VERSION}"
                    fi
                fi
            fi
        else
            if command -v pipx >/dev/null 2>&1; then
                echo "Trying pipx install for yq..."
                if [[ "$YQ_VERSION" == "latest" ]]; then
                    pipx install yq || pipx upgrade yq || true
                else
                    pipx install "yq==${YQ_VERSION}" || pipx upgrade "yq==${YQ_VERSION}" || true
                fi
            fi

            if ! yq_is_healthy; then
                if [[ "$YQ_VERSION" == "latest" ]]; then
                    python3 -m pip install --user --upgrade yq
                else
                    python3 -m pip install --user --upgrade "yq==${YQ_VERSION}"
                fi
            fi

            USER_BIN="$(python3 -m site --user-base)/bin"
            if [[ -d "$USER_BIN" && ":$PATH:" != *":$USER_BIN:"* ]]; then
                export PATH="$USER_BIN:$PATH"
                echo "Temporarily added $USER_BIN to PATH for this shell."
                echo "Tip: add it to your shell profile for future sessions."
            fi
        fi
    fi

    echo "--- Verifying dependency installation ---"
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq command not found after installation." >&2
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq command not found after installation." >&2
        echo "If pip installed yq under ~/.local/bin, add it to PATH and rerun SCRIPTS/llamacpp_build.sh" >&2
        return 1
    fi

    if ! command -v cmake >/dev/null 2>&1; then
        echo "Error: cmake command not found after installation." >&2
        return 1
    fi

    if ! command -v ninja >/dev/null 2>&1; then
        echo "Error: ninja command not found after installation." >&2
        return 1
    fi

    if ! yq -n '.' >/dev/null 2>&1; then
        echo "Error: yq is installed, but failed to run a basic query." >&2
        return 1
    fi

    echo "cmake version: $(cmake --version | head -n 1)"
    echo "ninja version: $(ninja --version)"
    echo "jq version: $(jq --version)"
    echo "yq version: $(yq --version)"
}

resolve_build_and_logs_dirs_from_config() {
    local build_dir=""
    local logs_dir=""
    local llama_root=""

    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq not found. Rerun SCRIPTS/llamacpp_build.sh to install dependencies first." >&2
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Missing config file at $CONFIG_FILE" >&2
        return 1
    fi

    build_dir=$(yq -r '.build_dir // empty' "$CONFIG_FILE")
    if [[ -z "$build_dir" ]]; then
        echo "Error: Missing build_dir in $CONFIG_FILE" >&2
        return 1
    fi

    logs_dir=$(yq -r '.logs_dir // empty' "$CONFIG_FILE")
    if [[ -z "$logs_dir" ]]; then
        echo "Error: Missing logs_dir in $CONFIG_FILE" >&2
        return 1
    fi

    if [[ "$build_dir" != /* ]]; then
        build_dir="$PROJECT_ROOT/${build_dir#./}"
    fi
    if [[ "$logs_dir" != /* ]]; then
        logs_dir="$PROJECT_ROOT/${logs_dir#./}"
    fi

    llama_root="$build_dir/llama.cpp"
    BUILD_ROOT="$llama_root/$LLAMACPP_USE_MODE"
    LLAMA_DIR="$BUILD_ROOT/src"
    LLAMA_LOG_FILE="$logs_dir/llama_cpp_commit_${LLAMACPP_USE_MODE}.txt"
    OV_LOG_FILE="$logs_dir/ov_build_info_${LLAMACPP_USE_MODE}.txt"
}

resolve_llamacpp_use_mode_from_config() {
    local mode=""

    mode=$(yq -r '.llamacpp.use // "build"' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
    if [[ "$mode" != "build" && "$mode" != "release" ]]; then
        echo "Error: llamacpp.use must be 'build' or 'release' in $CONFIG_FILE" >&2
        return 1
    fi

    LLAMACPP_USE_MODE="$mode"
}

resolve_latest_release_asset_urls() {
    local api_url="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
    local release_json=""

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required to resolve latest llama.cpp release assets." >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to resolve latest llama.cpp release assets." >&2
        return 1
    fi

    release_json=$(curl -fsSL "$api_url" 2>/dev/null || true)
    if [[ -z "$release_json" ]]; then
        echo "Warning: Failed to fetch latest llama.cpp release metadata from GitHub API. Trying HTML fallback..."
        resolve_latest_release_asset_urls_from_html && return 0
        echo "Error: Could not resolve latest llama.cpp release metadata from API or HTML fallback." >&2
        return 1
    fi

    LLAMA_RELEASE_TAG=$(echo "$release_json" | jq -r '.tag_name // empty')
    if [[ -z "$LLAMA_RELEASE_TAG" ]]; then
        echo "Error: Could not resolve latest llama.cpp release tag from GitHub API response." >&2
        return 1
    fi

    LLAMA_RELEASE_CPU_URL=$(echo "$release_json" | jq -r '.assets[]?.browser_download_url // empty' \
        | grep -E '/llama-[^/]+-bin-ubuntu-x64\.tar\.gz$' \
        | grep -Ev 'vulkan|openvino' \
        | head -n 1)

    LLAMA_RELEASE_VULKAN_URL=$(echo "$release_json" | jq -r '.assets[]?.browser_download_url // empty' \
        | grep -E '/llama-[^/]+-bin-ubuntu-vulkan-x64\.tar\.gz$' \
        | head -n 1)

    LLAMA_RELEASE_OPENVINO_URL=$(echo "$release_json" | jq -r '.assets[]?.browser_download_url // empty' \
        | grep -E '/llama-[^/]+-bin-ubuntu-openvino-[^-]+-x64\.tar\.gz$' \
        | head -n 1)

    if [[ -z "$LLAMA_RELEASE_CPU_URL" || -z "$LLAMA_RELEASE_VULKAN_URL" || -z "$LLAMA_RELEASE_OPENVINO_URL" ]]; then
        echo "Warning: API response missing one or more required ubuntu-x64 assets for tag $LLAMA_RELEASE_TAG. Trying HTML fallback..."
        resolve_latest_release_asset_urls_from_html && return 0
        echo "Error: Could not resolve one or more required ubuntu-x64 release assets for tag $LLAMA_RELEASE_TAG." >&2
        echo "CPU URL:      ${LLAMA_RELEASE_CPU_URL:-<missing>}" >&2
        echo "Vulkan URL:   ${LLAMA_RELEASE_VULKAN_URL:-<missing>}" >&2
        echo "OpenVINO URL: ${LLAMA_RELEASE_OPENVINO_URL:-<missing>}" >&2
        return 1
    fi

    return 0
}

resolve_latest_release_asset_urls_from_html() {
    local latest_effective_url=""
    local assets_url=""
    local assets_html=""

    latest_effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${LLAMA_REPO_URL}/releases/latest" 2>/dev/null || true)
    if [[ -z "$latest_effective_url" ]]; then
        return 1
    fi

    LLAMA_RELEASE_TAG=$(echo "$latest_effective_url" | sed -nE 's#.*/tag/([^/?#]+).*#\1#p')
    if [[ -z "$LLAMA_RELEASE_TAG" ]]; then
        return 1
    fi

    assets_url="${LLAMA_REPO_URL}/releases/expanded_assets/${LLAMA_RELEASE_TAG}"
    assets_html=$(curl -fsSL "$assets_url" 2>/dev/null || true)
    if [[ -z "$assets_html" ]]; then
        return 1
    fi

    LLAMA_RELEASE_CPU_URL=$(echo "$assets_html" \
        | grep -oE '/ggml-org/llama\.cpp/releases/download/[^" ]+/llama-[^" ]+-bin-ubuntu-x64\.tar\.gz' \
        | grep -Ev 'vulkan|openvino' \
        | head -n 1)

    LLAMA_RELEASE_VULKAN_URL=$(echo "$assets_html" \
        | grep -oE '/ggml-org/llama\.cpp/releases/download/[^" ]+/llama-[^" ]+-bin-ubuntu-vulkan-x64\.tar\.gz' \
        | head -n 1)

    LLAMA_RELEASE_OPENVINO_URL=$(echo "$assets_html" \
        | grep -oE '/ggml-org/llama\.cpp/releases/download/[^" ]+/llama-[^" ]+-bin-ubuntu-openvino-[^-]+-x64\.tar\.gz' \
        | head -n 1)

    if [[ -z "$LLAMA_RELEASE_CPU_URL" || -z "$LLAMA_RELEASE_VULKAN_URL" || -z "$LLAMA_RELEASE_OPENVINO_URL" ]]; then
        return 1
    fi

    [[ "$LLAMA_RELEASE_CPU_URL" =~ ^https?:// ]] || LLAMA_RELEASE_CPU_URL="https://github.com${LLAMA_RELEASE_CPU_URL}"
    [[ "$LLAMA_RELEASE_VULKAN_URL" =~ ^https?:// ]] || LLAMA_RELEASE_VULKAN_URL="https://github.com${LLAMA_RELEASE_VULKAN_URL}"
    [[ "$LLAMA_RELEASE_OPENVINO_URL" =~ ^https?:// ]] || LLAMA_RELEASE_OPENVINO_URL="https://github.com${LLAMA_RELEASE_OPENVINO_URL}"

    return 0
}

resolve_release_openvino_version_from_asset_url() {
    local asset_url="$1"
    local ov_version=""

    ov_version=$(echo "$asset_url" | sed -nE 's#.*-openvino-([0-9]+\.[0-9]+)-x64\.tar\.gz$#\1#p')
    if [[ -n "$ov_version" ]]; then
        echo "$ov_version"
        return 0
    fi

    return 1
}

detect_releaseov_required_openvino_soname() {
    local ov_lib=""
    local required_soname=""

    ov_lib=$(find "$BUILD_ROOT/ReleaseOV" -maxdepth 1 -type f -name 'libggml-openvino.so*' 2>/dev/null | head -n 1)
    if [[ -z "$ov_lib" ]]; then
        return 1
    fi

    if ! command -v readelf >/dev/null 2>&1; then
        return 1
    fi

    required_soname=$(readelf -d "$ov_lib" 2>/dev/null | awk '/\(NEEDED\).*libopenvino\.so/{gsub(/\[|\]/, "", $5); print $5; exit}')
    if [[ -z "$required_soname" ]]; then
        return 1
    fi

    echo "$required_soname"
}

map_openvino_soname_to_release_version() {
    local soname="$1"
    local soname_code=""
    local year_part=""
    local minor_raw=""
    local minor_val=0

    soname_code=$(echo "$soname" | sed -nE 's/^libopenvino\.so\.([0-9]{4})$/\1/p')
    if [[ -z "$soname_code" ]]; then
        return 1
    fi

    year_part="20${soname_code:0:2}"
    minor_raw="${soname_code:2:2}"
    minor_val=$((10#$minor_raw))

    if (( minor_val % 10 == 0 )); then
        minor_val=$((minor_val / 10))
    fi

    echo "${year_part}.${minor_val}"
}

resolve_ov_url_for_release_version() {
    local release_version="$1"
    local base_url="https://storage.openvinotoolkit.org/repositories/openvino/packages/${release_version}/linux/"
    local filetree_url="https://storage.openvinotoolkit.org/filetree.json"
    local filetree_json=""
    local full_path=""
    local release_re=""
    local file_name=""
    local html=""

    release_re="${release_version//./\\.}"
    filetree_json=$(curl -fsSL "$filetree_url" 2>/dev/null || true)
    if [[ -n "$filetree_json" ]]; then
        full_path=$(echo "$filetree_json" \
            | grep -oE "repositories/openvino/packages/[0-9]+(\.[0-9]+)*/linux/openvino_toolkit_ubuntu24_${release_re}\.[^\"\\/]*_x86_64\.tgz" \
            | grep -Ev 'nightly|\.dev' \
            | sort -uV \
            | tail -n 1)

        if [[ -n "$full_path" ]]; then
            echo "https://storage.openvinotoolkit.org/${full_path}"
            return 0
        fi

        file_name=$(echo "$filetree_json" \
            | grep -oE "openvino_toolkit_ubuntu24_${release_re}\.[^\"\\/]*_x86_64\.tgz" \
            | grep -Ev 'nightly|\.dev' \
            | sort -uV \
            | tail -n 1)

        if [[ -n "$file_name" ]]; then
            echo "${base_url}${file_name}"
            return 0
        fi
    fi

    html=$(curl -fsSL "$base_url" 2>/dev/null || true)
    if [[ -z "$html" ]]; then
        return 1
    fi

    file_name=$(echo "$html" \
        | grep -oE 'href="openvino_toolkit_ubuntu24_[^"]*x86_64\.tgz"' \
        | sed -E 's/^href="|"$//g' \
        | grep -E "openvino_toolkit_ubuntu24_${release_re}\." \
        | grep -Ev 'nightly|\.dev' \
        | sort -V \
        | tail -n 1)

    if [[ -z "$file_name" ]]; then
        return 1
    fi

    echo "${base_url}${file_name}"
}

resolve_ov_url_from_llama_release_workflow() {
    local release_tag="$1"
    local expected_major="$2"
    local workflow_url=""
    local workflow_yml=""
    local ov_major=""
    local ov_full=""

    if [[ -z "$release_tag" || -z "$expected_major" ]]; then
        return 1
    fi

    workflow_url="https://raw.githubusercontent.com/ggml-org/llama.cpp/${release_tag}/.github/workflows/release.yml"
    workflow_yml=$(curl -fsSL "$workflow_url" 2>/dev/null || true)
    if [[ -z "$workflow_yml" ]]; then
        return 1
    fi

    ov_major=$(echo "$workflow_yml" | awk -F'"' '/OPENVINO_VERSION_MAJOR:/ {print $2; exit}')
    ov_full=$(echo "$workflow_yml" | awk -F'"' '/OPENVINO_VERSION_FULL:/ {print $2; exit}')

    if [[ -z "$ov_major" || -z "$ov_full" ]]; then
        return 1
    fi

    if [[ "$ov_major" != "$expected_major" ]]; then
        return 1
    fi

    echo "https://storage.openvinotoolkit.org/repositories/openvino/packages/${ov_major}/linux/openvino_toolkit_ubuntu24_${ov_full}_x86_64.tgz"
}

ensure_release_openvino_runtime() {
    local required_release_version=""
    local soname_version_hint=""
    local required_soname=""
    local runtime_dir=""
    local setupvars_path=""
    local installed_semver=""
    local download_url=""
    local response_content_type=""
    local fallback_url=""
    local tmp_file=""
    local extract_dir=""
    local extracted_folder=""

    runtime_dir="$BUILD_ROOT/OpenVINO_release_runtime"
    setupvars_path="$runtime_dir/setupvars.sh"
    RELEASE_OV_RUNTIME_DIR="$runtime_dir"

    required_release_version=$(resolve_release_openvino_version_from_asset_url "$LLAMA_RELEASE_OPENVINO_URL" 2>/dev/null || true)
    required_soname=$(detect_releaseov_required_openvino_soname 2>/dev/null || true)
    if [[ -n "$required_soname" ]]; then
        RELEASE_OV_REQUIRED_SONAME="$required_soname"
        soname_version_hint=$(map_openvino_soname_to_release_version "$required_soname" 2>/dev/null || true)
        if [[ -n "$soname_version_hint" ]]; then
            required_release_version="$soname_version_hint"
        fi
    fi

    if [[ -z "$required_release_version" ]]; then
        echo "Error: Could not determine required OpenVINO release line for ReleaseOV." >&2
        echo "Hint: expected llama release asset name like: ...-openvino-2026.0-x64.tar.gz" >&2
        return 1
    fi

    LLAMA_RELEASE_OPENVINO_VERSION="$required_release_version"

    installed_semver=$(detect_ov_version_for_log "$runtime_dir")
    if [[ -f "$setupvars_path" && "$installed_semver" == "${required_release_version}"* ]]; then
        echo "Release OpenVINO runtime already present at $runtime_dir (version: $installed_semver)."
        return 0
    fi

    download_url=$(resolve_ov_url_for_release_version "$required_release_version" 2>/dev/null || true)
    if [[ -z "$download_url" ]]; then
        echo "Error: Could not resolve OpenVINO package URL for release line ${required_release_version}." >&2
        return 1
    fi

    response_content_type=$(curl -fsSLI "$download_url" 2>/dev/null | awk -F': *' 'tolower($1)=="content-type" {print tolower($2); exit}' | tr -d '\r')
    if [[ "$response_content_type" == text/html* ]]; then
        fallback_url=$(resolve_ov_url_from_llama_release_workflow "$LLAMA_RELEASE_TAG" "$required_release_version" 2>/dev/null || true)
        if [[ -n "$fallback_url" ]]; then
            download_url="$fallback_url"
            response_content_type=$(curl -fsSLI "$download_url" 2>/dev/null | awk -F': *' 'tolower($1)=="content-type" {print tolower($2); exit}' | tr -d '\r')
        fi
    fi

    if [[ "$response_content_type" == text/html* || -z "$response_content_type" ]]; then
        echo "Error: Resolved OpenVINO URL returned HTML instead of a package: $download_url" >&2
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required to download release OpenVINO runtime package." >&2
        return 1
    fi

    tmp_file="$PROJECT_ROOT/ov_release_runtime_pkg.tgz"
    extract_dir="$PROJECT_ROOT/ov_release_runtime_extract"
    rm -rf "$extract_dir" "$tmp_file"
    mkdir -p "$extract_dir"

    echo "Downloading release OpenVINO runtime package: $download_url"
    curl -fL "$download_url" --output "$tmp_file"

    if ! tar -tzf "$tmp_file" >/dev/null 2>&1; then
        echo "Error: Downloaded OpenVINO package is not a valid .tgz archive: $download_url" >&2
        echo "Hint: proxy/content filter may have returned HTML."
        rm -rf "$extract_dir" "$tmp_file"
        return 1
    fi

    echo "Extracting release OpenVINO runtime package..."
    tar -xf "$tmp_file" -C "$extract_dir"

    extracted_folder=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [[ -z "$extracted_folder" ]]; then
        echo "Error: Could not locate extracted OpenVINO runtime folder in $extract_dir" >&2
        rm -rf "$extract_dir" "$tmp_file"
        return 1
    fi

    rm -rf "$runtime_dir"
    mv "$extracted_folder" "$runtime_dir"
    rm -rf "$extract_dir" "$tmp_file"

    if [[ ! -f "$setupvars_path" ]]; then
        echo "Error: Missing setupvars.sh in release OpenVINO runtime folder: $setupvars_path" >&2
        return 1
    fi

    installed_semver=$(detect_ov_version_for_log "$runtime_dir")
    echo "Prepared release OpenVINO runtime at $runtime_dir (version: ${installed_semver:-unknown}, target line: $required_release_version)."
    if [[ -n "$RELEASE_OV_REQUIRED_SONAME" ]]; then
        echo "ReleaseOV binary requires: $RELEASE_OV_REQUIRED_SONAME"
    fi

    return 0
}

install_release_archive_to_target() {
    local archive_url="$1"
    local target_dir="$2"
    local label="$3"
    local tmp_dir=""
    local archive_file=""
    local extract_dir=""
    local bench_path=""
    local release_root=""
    local fallback_root=""
    local bin_dir=""

    tmp_dir=$(mktemp -d "$PROJECT_ROOT/.llama_release_${label}.XXXXXX")
    archive_file="$tmp_dir/pkg.tar.gz"
    extract_dir="$tmp_dir/extract"
    mkdir -p "$extract_dir"

    echo "Downloading ${label} backend archive: $archive_url"
    curl -fL "$archive_url" -o "$archive_file"

    echo "Extracting ${label} backend archive..."
    tar -xf "$archive_file" -C "$extract_dir"

    bench_path=$(find "$extract_dir" -type f -path '*/bin/llama-bench' | head -n 1)
    if [[ -z "$bench_path" ]]; then
        # Newer upstream archives are flat (no bin/), e.g. llama-b9151/llama-bench.
        bench_path=$(find "$extract_dir" -type f -name 'llama-bench' | head -n 1)
    fi

    if [[ -z "$bench_path" ]]; then
        echo "Error: Could not locate llama-bench in extracted ${label} archive from $archive_url" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    release_root=$(dirname "$(dirname "$bench_path")")
    fallback_root=$(dirname "$bench_path")

    # For flat archives, release_root may be too high (missing llama-bench file in it).
    if [[ ! -f "$release_root/llama-bench" && ! -f "$release_root/bin/llama-bench" ]]; then
        release_root="$fallback_root"
    fi

    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    cp -a "$release_root"/. "$target_dir"/

    # Keep upstream flat layout intact; add bin/ symlinks for script compatibility.
    if [[ ! -x "$target_dir/bin/llama-bench" && -x "$target_dir/llama-bench" ]]; then
        local exe_file=""
        mkdir -p "$target_dir/bin"
        while IFS= read -r exe_file; do
            ln -sfn "../$(basename "$exe_file")" "$target_dir/bin/$(basename "$exe_file")"
        done < <(find "$target_dir" -maxdepth 1 -type f \( -name 'llama-*' -o -name 'rpc-*' \))
    fi

    rm -rf "$tmp_dir"

    if [[ ! -x "$target_dir/bin/llama-bench" && ! -x "$target_dir/llama-bench" ]]; then
        echo "Error: Installed ${label} backend missing executable llama-bench under $target_dir" >&2
        return 1
    fi

    echo "Installed ${label} backend to $target_dir"
    return 0
}

write_release_mode_commit_log() {
    local cpu_pkg=""

    cpu_pkg=$(basename "$LLAMA_RELEASE_CPU_URL")
    mkdir -p "$(dirname "$LLAMA_LOG_FILE")"
    echo "$LLAMA_RELEASE_TAG prebuilt-package=$cpu_pkg" > "$LLAMA_LOG_FILE"
    echo "Saved release info to $LLAMA_LOG_FILE: $LLAMA_RELEASE_TAG"
}

install_latest_release_backends() {
    if [[ "$NEED_BUILD_RELEASE" == true ]]; then
        install_release_archive_to_target "$LLAMA_RELEASE_CPU_URL" "$BUILD_ROOT/Release" "cpu"
    else
        echo "Release CPU backend already exists; skipping download/install."
    fi

    if [[ "$NEED_BUILD_VULKAN" == true ]]; then
        install_release_archive_to_target "$LLAMA_RELEASE_VULKAN_URL" "$BUILD_ROOT/ReleaseVulkan" "vulkan"
    else
        echo "Release Vulkan backend already exists; skipping download/install."
    fi

    if [[ "$NEED_BUILD_OV" == true ]]; then
        install_release_archive_to_target "$LLAMA_RELEASE_OPENVINO_URL" "$BUILD_ROOT/ReleaseOV" "openvino"
    else
        echo "Release OpenVINO backend already exists; skipping download/install."
    fi

    write_release_mode_commit_log
    refresh_ov_build_info_log_if_available || true
    return 0
}

plan_release_backends() {
    local logged_tag=""

    NEED_BUILD_RELEASE=true
    NEED_BUILD_VULKAN=true
    NEED_BUILD_OV=true
    SKIP_REASON=""

    if ! resolve_latest_release_asset_urls; then
        return 1
    fi

    echo "Latest llama.cpp release tag: $LLAMA_RELEASE_TAG"

    [[ -x "$BUILD_ROOT/Release/bin/llama-bench" ]] && NEED_BUILD_RELEASE=false
    [[ -x "$BUILD_ROOT/ReleaseVulkan/bin/llama-bench" ]] && NEED_BUILD_VULKAN=false
    [[ -x "$BUILD_ROOT/ReleaseOV/bin/llama-bench" ]] && NEED_BUILD_OV=false

    if [[ -f "$LLAMA_LOG_FILE" ]]; then
        logged_tag=$(awk 'NR==1{print $1}' "$LLAMA_LOG_FILE")
    fi

    if [[ "$logged_tag" != "$LLAMA_RELEASE_TAG" ]]; then
        NEED_BUILD_RELEASE=true
        NEED_BUILD_VULKAN=true
        NEED_BUILD_OV=true

        if [[ -z "$logged_tag" ]]; then
            SKIP_REASON="Missing release log at $LLAMA_LOG_FILE"
        else
            SKIP_REASON="Latest release tag ($LLAMA_RELEASE_TAG) differs from logged tag ($logged_tag)"
        fi
    else
        SKIP_REASON="Latest release tag matches logged tag ($logged_tag)"
    fi

    echo "Skip check: $SKIP_REASON"

    if [[ "$NEED_BUILD_RELEASE" == false && "$NEED_BUILD_VULKAN" == false && "$NEED_BUILD_OV" == false ]]; then
        refresh_ov_build_info_log_if_available
        echo "All release backends already exist for tag $LLAMA_RELEASE_TAG. Skipping download/install steps."
        return 0
    fi

    echo "Release install mode: installing missing/outdated backend targets only."
    return 0
}

apply_optional_proxy_from_config() {
    local use_proxy=""
    local proxy_line=""
    local proxy_var=""
    local proxy_val=""

    if [[ ! -f "$CONFIG_FILE" ]] || ! command -v yq >/dev/null 2>&1; then
        return
    fi

    use_proxy=$(yq -r '.proxy.use_proxy // "false"' "$CONFIG_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [[ "$use_proxy" != "true" && "$use_proxy" != "yes" && "$use_proxy" != "1" ]]; then
        return
    fi

    while IFS= read -r proxy_line; do
        proxy_line=$(echo "$proxy_line" | xargs)
        [[ -z "$proxy_line" ]] && continue

        if [[ "$proxy_line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            proxy_var="${BASH_REMATCH[2]}"
            proxy_val="${BASH_REMATCH[3]}"
            export "$proxy_var=$proxy_val"
        fi
    done < <(yq -r '.proxy.proxy_list[]? // empty' "$CONFIG_FILE" 2>/dev/null)

    echo "Applied proxy settings from $CONFIG_FILE"
}

resolve_ov_dest_from_config() {
    local ov_version_mode=""
    local ov_dest=""

    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq not found. Rerun SCRIPTS/llamacpp_build.sh to install dependencies first." >&2
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Missing config file at $CONFIG_FILE" >&2
        return 1
    fi

    ov_version_mode=$(yq -r '.openvino.version // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
    if [[ "$ov_version_mode" != "default" && "$ov_version_mode" != "latest" ]]; then
        echo "Error: openvino.version must be 'default' or 'latest' in $CONFIG_FILE" >&2
        return 1
    fi

    ov_dest=$(yq -r '.llamacpp_ov_dir // empty' "$CONFIG_FILE")
    if [[ -z "$ov_dest" ]]; then
        echo "Error: Missing llamacpp_ov_dir in $CONFIG_FILE" >&2
        return 1
    fi

    echo "$ov_dest"
}

extract_semver_from_text() {
    local text="$1"
    echo "$text" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

resolve_latest_ov_url() {
    local base_url="$1"
    local filetree_url filetree_json file_name version_dir candidate_url
    local versions_html latest_version linux_url linux_html

    filetree_url="https://storage.openvinotoolkit.org/filetree.json"

    filetree_json=$(curl -fsSL "$filetree_url" 2>/dev/null || true)
    if [[ -n "$filetree_json" ]]; then
        file_name=$(echo "$filetree_json" \
            | grep -oE 'openvino_toolkit_ubuntu24_[^"\\/]*x86_64\.tgz' \
            | grep -Ev 'nightly|\.dev' \
            | sort -uV \
            | tail -n 1)

        if [[ -n "$file_name" ]]; then
            version_dir=$(echo "$file_name" \
                | sed -E 's/^openvino_toolkit_ubuntu24_([0-9]+\.[0-9]+\.[0-9]+)\..*x86_64\.tgz$/\1/')

            if [[ -n "$version_dir" ]]; then
                candidate_url="${base_url}${version_dir}/linux/${file_name}"
                if curl -fsIL "$candidate_url" >/dev/null 2>&1; then
                    echo "$candidate_url"
                    return 0
                fi
            fi
        fi
    fi

    versions_html=$(curl -fsSL "$base_url") || return 1

    latest_version=$(echo "$versions_html" \
        | grep -oE 'href="[0-9]+(\.[0-9]+)*/"' \
        | sed -E 's/^href="|\/"$//g' \
        | sort -V \
        | tail -n 1)

    if [[ -z "$latest_version" ]]; then
        return 1
    fi

    linux_url="${base_url}${latest_version}/linux/"
    linux_html=$(curl -fsSL "$linux_url") || return 1

    file_name=$(echo "$linux_html" \
        | grep -oE 'href="openvino_toolkit_ubuntu24_[^"]*x86_64\.tgz"' \
        | sed -E 's/^href="|"$//g' \
        | grep -vi 'nightly' \
        | sort -V \
        | tail -n 1)

    if [[ -z "$file_name" ]]; then
        file_name=$(echo "$linux_html" \
            | grep -oE 'href="openvino_toolkit_[^"]*x86_64\.tgz"' \
            | sed -E 's/^href="|"$//g' \
            | grep -vi 'nightly' \
            | sort -V \
            | tail -n 1)
    fi

    if [[ -z "$file_name" ]]; then
        return 1
    fi

    echo "${linux_url}${file_name}"
}

resolve_ov_mode_target_semver() {
    local ov_version_mode=""
    local base_url="https://storage.openvinotoolkit.org/repositories/openvino/packages/"
    local default_url=""
    local latest_url=""

    ov_version_mode=$(yq -r '.openvino.version // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')

    if [[ "$ov_version_mode" == "latest" ]]; then
        OV_ACTIVE_MODE="latest"
        latest_url=$(resolve_latest_ov_url "$base_url" 2>/dev/null || true)
        if [[ -z "$latest_url" ]]; then
            OV_MODE_TARGET_CHECK_REASON="Failed to resolve latest OpenVINO package URL from web"
            return 1
        fi
        OV_TARGET_SEMVER=$(extract_semver_from_text "$latest_url")
        if [[ -z "$OV_TARGET_SEMVER" ]]; then
            OV_MODE_TARGET_CHECK_REASON="Could not parse semver from latest OpenVINO URL: $latest_url"
            return 1
        fi
        return 0
    fi

    if [[ "$ov_version_mode" == "default" ]]; then
        OV_ACTIVE_MODE="default"
        default_url=$(yq -r '.openvino.default_url // empty' "$CONFIG_FILE")
        if [[ -z "$default_url" ]]; then
            OV_MODE_TARGET_CHECK_REASON="Missing openvino.default_url in $CONFIG_FILE"
            return 1
        fi
        OV_TARGET_SEMVER=$(extract_semver_from_text "$default_url")
        if [[ -z "$OV_TARGET_SEMVER" ]]; then
            OV_MODE_TARGET_CHECK_REASON="Could not parse semver from openvino.default_url"
            return 1
        fi
        return 0
    fi

    OV_MODE_TARGET_CHECK_REASON="openvino.version must be 'default' or 'latest' in $CONFIG_FILE"
    return 1
}

ensure_openvino_installed() {
    local ov_dest=""
    local ov_version_mode=""
    local download_url=""
    local target_pkg_tag=""
    local target_semver=""
    local installed_semver=""
    local setupvars_path=""
    local tmp_file=""
    local extract_dir=""
    local extracted_folder=""
    local install_prefix=""
    local ov_parent_dir=""

    ov_dest=$(resolve_ov_dest_from_config)
    if [[ -z "$ov_dest" ]]; then
        echo "Error: Could not resolve OpenVINO destination from config."
        return 1
    fi

    if [[ "$ov_dest" != /* ]]; then
        ov_dest="$PROJECT_ROOT/$ov_dest"
    fi

    ov_parent_dir=$(dirname "$ov_dest")
    if [[ ( -e "$ov_dest" && ! -w "$ov_dest" ) || ( ! -e "$ov_dest" && ! -w "$ov_parent_dir" ) ]]; then
        if [[ "$EUID" -eq 0 ]]; then
            install_prefix=""
        elif command -v sudo >/dev/null 2>&1; then
            echo "Sudo access is required to install OpenVINO at $ov_dest."
            if ! sudo -v; then
                echo "Error: sudo authentication failed. Cannot install OpenVINO to $ov_dest."
                return 1
            fi
            install_prefix="sudo"
        else
            echo "Error: No write access to $ov_dest and sudo is not available."
            return 1
        fi
    fi

    ov_version_mode=$(yq -r '.openvino.version // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
    if [[ "$ov_version_mode" == "latest" ]]; then
        download_url=$(resolve_latest_ov_url "https://storage.openvinotoolkit.org/repositories/openvino/packages/")
    else
        download_url=$(yq -r '.openvino.default_url // empty' "$CONFIG_FILE")
    fi

    if [[ -z "$download_url" ]]; then
        echo "Error: Could not resolve OpenVINO download URL for mode '$ov_version_mode'."
        return 1
    fi

    target_pkg_tag=$(basename "$download_url")
    target_semver=$(extract_semver_from_text "$download_url")
    if [[ -z "$target_semver" && -n "$target_pkg_tag" ]]; then
        target_semver=$(extract_semver_from_text "$target_pkg_tag")
    fi

    if [[ -z "$target_semver" ]]; then
        echo "Error: Could not resolve target OpenVINO semver from URL: $download_url"
        return 1
    fi

    installed_semver=$(detect_ov_version_for_log "$ov_dest")
    setupvars_path="$ov_dest/setupvars.sh"
    if [[ "$installed_semver" == "$target_semver" && -f "$setupvars_path" ]]; then
        echo "OpenVINO already installed at $ov_dest (version: $installed_semver)."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required to download OpenVINO packages."
        return 1
    fi

    tmp_file="$PROJECT_ROOT/ov_pkg.tgz"
    extract_dir="$PROJECT_ROOT/ov_temp_extract"
    rm -rf "$extract_dir" "$tmp_file"
    mkdir -p "$extract_dir"

    echo "Downloading OpenVINO package: $download_url"
    curl -fL "$download_url" --output "$tmp_file"

    echo "Extracting OpenVINO archive..."
    tar -xf "$tmp_file" -C "$extract_dir"

    extracted_folder=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [[ -z "$extracted_folder" ]]; then
        echo "Error: Could not locate extracted OpenVINO folder in $extract_dir"
        rm -rf "$extract_dir" "$tmp_file"
        return 1
    fi

    if [[ -d "$ov_dest" ]]; then
        if [[ -n "$install_prefix" ]]; then
            $install_prefix rm -rf "$ov_dest"
        else
            rm -rf "$ov_dest"
        fi
    fi

    if [[ -n "$install_prefix" ]]; then
        $install_prefix mkdir -p "$ov_parent_dir"
        $install_prefix mv "$extracted_folder" "$ov_dest"
    else
        mkdir -p "$ov_parent_dir"
        mv "$extracted_folder" "$ov_dest"
    fi
    rm -rf "$extract_dir" "$tmp_file"

    installed_semver=$(detect_ov_version_for_log "$ov_dest")
    if [[ "$installed_semver" != "$target_semver" ]]; then
        echo "Error: OpenVINO install version mismatch: expected $target_semver, found $installed_semver"
        return 1
    fi

    if [[ ! -f "$ov_dest/setupvars.sh" ]]; then
        echo "Error: OpenVINO setupvars.sh not found at $ov_dest/setupvars.sh"
        return 1
    fi

    echo "OpenVINO installed at $ov_dest (version: $installed_semver)."
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

detect_ov_version_for_log() {
    local ov_root="$1"
    local ov_version=""
    local raw_version=""

    if [[ -f "$ov_root/runtime/version.txt" ]]; then
        raw_version=$(head -n 1 "$ov_root/runtime/version.txt" 2>/dev/null | xargs)
        ov_version=$(extract_semver_from_text "$raw_version")
        [[ -z "$ov_version" ]] && ov_version="$raw_version"
    fi

    [[ -n "$ov_version" ]] && echo "$ov_version" || echo "N/A"
}

verify_ov_mode_target_alignment() {
    local ov_dest="$1"
    local ov_vars="$2"

    OV_ACTIVE_MODE=""
    OV_TARGET_SEMVER=""
    OV_CURRENT_VERSION=""
    OV_MODE_TARGET_CHECK_REASON=""

    if ! resolve_ov_mode_target_semver; then
        return 1
    fi

    OV_CURRENT_VERSION=$(detect_ov_version_for_log "$ov_dest")
    if [[ -z "$OV_CURRENT_VERSION" || "$OV_CURRENT_VERSION" == "N/A" ]]; then
        OV_MODE_TARGET_CHECK_REASON="Could not detect installed OpenVINO version from $ov_dest"
        return 1
    fi

    if [[ "$OV_CURRENT_VERSION" != "$OV_TARGET_SEMVER" ]]; then
        OV_MODE_TARGET_CHECK_REASON="OpenVINO mode target mismatch ($OV_ACTIVE_MODE): target=$OV_TARGET_SEMVER installed=$OV_CURRENT_VERSION"
        return 1
    fi

    return 0
}

write_ov_build_info_log() {
    local ov_dest="$1"
    local ov_vars="$2"
    local ov_version=""

    ov_version=$(detect_ov_version_for_log "$ov_dest")
    if [[ -z "$ov_version" || "$ov_version" == "N/A" ]]; then
        echo "Error: Could not detect OpenVINO version for $OV_LOG_FILE from $ov_dest" >&2
        return 1
    fi

    mkdir -p "$(dirname "$OV_LOG_FILE")"
    echo "$ov_version" > "$OV_LOG_FILE"
    return 0
}

refresh_ov_build_info_log_if_available() {
    local ov_dest=""
    local ov_vars=""
    local ov_bin="$BUILD_ROOT/ReleaseOV/bin/llama-bench"

    # Prebuilt release archives bundle their own runtime stack; no local OV log coupling.
    [[ "$LLAMACPP_USE_MODE" == "release" ]] && return 0

    [[ -x "$ov_bin" ]] || return 0

    ov_dest=$(resolve_ov_dest_from_config 2>/dev/null)
    if [[ -z "$ov_dest" ]]; then
        echo "Error: Could not resolve OpenVINO destination from config."
        return 1
    fi

    if [[ "$ov_dest" != /* ]]; then
        ov_dest="$PROJECT_ROOT/$ov_dest"
    fi

    ov_vars="$ov_dest/setupvars.sh"
    if ! verify_ov_mode_target_alignment "$ov_dest" "$ov_vars"; then
        echo "Error: ${OV_MODE_TARGET_CHECK_REASON}" >&2
        return 1
    fi

    write_ov_build_info_log "$ov_dest" "$ov_vars"
}

check_ov_runtime_alignment() {
    local ov_dest ov_vars current_ov_version logged_ov_version

    # If OV binary is already missing, it is already scheduled for rebuild.
    [[ "$NEED_BUILD_OV" == true ]] && return

    ov_dest=$(resolve_ov_dest_from_config 2>/dev/null)
    if [[ -z "$ov_dest" ]]; then
        echo "Error: Could not resolve OpenVINO destination from config."
        return 1
    fi

    if [[ "$ov_dest" != /* ]]; then
        ov_dest="$PROJECT_ROOT/$ov_dest"
    fi

    ov_vars="$ov_dest/setupvars.sh"

    if ! verify_ov_mode_target_alignment "$ov_dest" "$ov_vars"; then
        NEED_BUILD_OV=true
        SKIP_REASON="${SKIP_REASON}; ${OV_MODE_TARGET_CHECK_REASON}"
        return
    fi

    current_ov_version=$(detect_ov_version_for_log "$ov_dest")
    logged_ov_version=$(head -n 1 "$OV_LOG_FILE" 2>/dev/null | xargs || true)

    if [[ -z "$logged_ov_version" || "$logged_ov_version" == "N/A" ]]; then
        NEED_BUILD_OV=true
        SKIP_REASON="${SKIP_REASON}; OV build version log missing"
        return
    fi

    if [[ "$current_ov_version" != "$logged_ov_version" ]]; then
        NEED_BUILD_OV=true
        SKIP_REASON="${SKIP_REASON}; OV runtime changed (${logged_ov_version} -> ${current_ov_version})"
    else
        OV_STATUS_NOTE="OV version matches (${current_ov_version})"
    fi
}

plan_builds() {
    if check_commit_match && [[ -d "$BUILD_ROOT" ]]; then
        NEED_FULL_REBUILD=false

        [[ -x "$BUILD_ROOT/Release/bin/llama-bench" ]] && NEED_BUILD_RELEASE=false
        [[ -x "$BUILD_ROOT/ReleaseVulkan/bin/llama-bench" ]] && NEED_BUILD_VULKAN=false
        [[ -x "$BUILD_ROOT/ReleaseOV/bin/llama-bench" ]] && NEED_BUILD_OV=false

        check_ov_runtime_alignment
        if [[ -n "$OV_STATUS_NOTE" ]]; then
            SKIP_REASON="${SKIP_REASON}; ${OV_STATUS_NOTE}"
        fi

        if [[ "$NEED_BUILD_RELEASE" == false && "$NEED_BUILD_VULKAN" == false && "$NEED_BUILD_OV" == false ]]; then
            refresh_ov_build_info_log_if_available
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

ensure_dependencies_installed
apply_optional_proxy_from_config
resolve_llamacpp_use_mode_from_config
resolve_build_and_logs_dirs_from_config

if [[ "$LLAMACPP_USE_MODE" == "build" ]]; then
    ensure_openvino_installed
fi

if [[ "$LLAMACPP_USE_MODE" == "release" ]]; then
    echo "llamacpp.use=release selected; downloading latest prebuilt ubuntu-x64 backends."
    mkdir -p "$BUILD_ROOT"
    plan_release_backends

    if [[ "$NEED_BUILD_RELEASE" == false && "$NEED_BUILD_VULKAN" == false && "$NEED_BUILD_OV" == false ]]; then
        ensure_release_openvino_runtime
        echo "------------------------------------------------"
        echo "Prebuilt release backends already up to date for tag: $LLAMA_RELEASE_TAG"
        echo "Binaries are located in $BUILD_ROOT/Release, $BUILD_ROOT/ReleaseVulkan, and $BUILD_ROOT/ReleaseOV"
        echo "Release OpenVINO runtime is located in $BUILD_ROOT/OpenVINO_release_runtime"
        exit 0
    fi

    install_latest_release_backends
    ensure_release_openvino_runtime
    echo "------------------------------------------------"
    echo "Prebuilt release backends installed successfully for tag: $LLAMA_RELEASE_TAG"
    echo "Binaries are located in $BUILD_ROOT/Release, $BUILD_ROOT/ReleaseVulkan, and $BUILD_ROOT/ReleaseOV"
    echo "Release OpenVINO runtime is located in $BUILD_ROOT/OpenVINO_release_runtime"
    exit 0
fi

plan_builds

if [[ "$NEED_FULL_REBUILD" == true ]]; then
    rm -rf "$BUILD_ROOT"
fi

echo "--- 1. Setting up Environment ---"
# Create explicit logs directory if it does not exist
mkdir -p "$(dirname "$LLAMA_LOG_FILE")"

# 2. Cloning Repository
mkdir -p "$(dirname "$LLAMA_DIR")"
if [[ "$NEED_FULL_REBUILD" == true ]]; then
    echo "Full rebuild: cloning fresh llama.cpp repository..."
    git clone "$LLAMA_REPO_URL" "$LLAMA_DIR"
    cd "$LLAMA_DIR"
else
    if [ -d "$LLAMA_DIR" ]; then
        echo "Folder llama.cpp already exists. Using current commit for incremental build..."
        cd "$LLAMA_DIR"
    else
        echo "llama.cpp folder missing in incremental mode. Cloning..."
        git clone "$LLAMA_REPO_URL" "$LLAMA_DIR"
        cd "$LLAMA_DIR"
    fi
fi

# 3. Logging Commit Version
update_commit_log

# 5. Build 1: Default CPU backend
if [[ "$NEED_BUILD_RELEASE" == true ]]; then
    echo "--- 3. Starting Build: Default CPU ---"
    rm -rf "$BUILD_ROOT/Release"
    cmake -B "$BUILD_ROOT/Release" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=OFF -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_WEBUI=OFF
    cmake --build "$BUILD_ROOT/Release" --parallel $(nproc)
else
    echo "--- 3. Skipping Build: Default CPU already exists ---"
fi

# 6. Build 2: Vulkan backend (GPU)
if [[ "$NEED_BUILD_VULKAN" == true ]]; then
    echo "--- 4. Starting Build: Vulkan GPU ---"
    # Verify Vulkan headers are present
    VULKAN_CORE_H=$(find /usr/include /usr/local/include -name "vulkan_core.h" 2>/dev/null | head -1)
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

    rm -rf "$BUILD_ROOT/ReleaseVulkan"
    cmake -B "$BUILD_ROOT/ReleaseVulkan" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON \
        -DVulkan_INCLUDE_DIR="${VULKAN_INCLUDE_DIR}" \
        -DCMAKE_INCLUDE_PATH="${VULKAN_INCLUDE_DIR}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLLAMA_BUILD_WEBUI=OFF
    cmake --build "$BUILD_ROOT/ReleaseVulkan" --parallel $(nproc)
else
    echo "--- 4. Skipping Build: Vulkan GPU already exists ---"
fi

# 7. Build 3: OpenVINO backend (CPU, GPU, NPU)
if [[ "$NEED_BUILD_OV" == true ]]; then
    echo "--- 5. Starting Build: OpenVINO ---"
    OV_DEST_FOLDER=$(resolve_ov_dest_from_config)

    if [[ -z "$OV_DEST_FOLDER" ]]; then
        echo "Error: Could not resolve OV destination from openvino yes/no flags in $CONFIG_FILE"
        exit 1
    fi

    if [[ "$OV_DEST_FOLDER" != /* ]]; then
        OV_DEST_FOLDER="$PROJECT_ROOT/$OV_DEST_FOLDER"
    fi

    OV_VARS="${OV_DEST_FOLDER}/setupvars.sh"

    if ! verify_ov_mode_target_alignment "$OV_DEST_FOLDER" "$OV_VARS"; then
        echo "Error: ${OV_MODE_TARGET_CHECK_REASON}"
        echo "Fix: rerun SCRIPTS/llamacpp_build.sh so OpenVINO is downloaded/updated to the YAML-selected mode target."
        exit 1
    fi

    if [[ -f "$OV_VARS" ]]; then
        # We use '.' instead of 'source' for maximum shell compatibility
        . "$OV_VARS"
        rm -rf "$BUILD_ROOT/ReleaseOV"
        cmake -B "$BUILD_ROOT/ReleaseOV" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_OPENVINO=ON -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_WEBUI=OFF
        cmake --build "$BUILD_ROOT/ReleaseOV" --parallel $(nproc)
        write_ov_build_info_log "$OV_DEST_FOLDER" "$OV_VARS"
    else
        echo "Error: Missing explicit OpenVINO setupvars path: $OV_VARS"
        exit 1
    fi
else
    echo "--- 5. Skipping Build: OpenVINO already exists ---"
    refresh_ov_build_info_log_if_available
fi

echo "------------------------------------------------"
echo "All builds completed successfully!"
echo "Binaries are located in $BUILD_ROOT/Release, $BUILD_ROOT/ReleaseVulkan, and $BUILD_ROOT/ReleaseOV"
