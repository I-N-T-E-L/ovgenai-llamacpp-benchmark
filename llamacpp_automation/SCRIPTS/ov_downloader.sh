#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
cd "$SCRIPT_DIR/.."

CONFIG_FILE="config.txt"
KEYWORD="\[OV_DOWNLOAD\]" 
IN_SECTION=false              
DEST_PATH=""
DEFAULT_DEST_PATH=""
DEFAULT_URL=""
LATEST_DEST_PATH=""
ACTIVE_MODE=""
CURRENT_OV_SUBSECTION=""
HAS_DEFAULT_SECTION=false
HAS_LATEST_SECTION=false

OV_BASE_URL="https://storage.openvinotoolkit.org/repositories/openvino/packages/"
OV_VERSION_META_FILE_NAME=".openvino_installed_version"

extract_pkg_tag_from_url() {
    local url="$1"
    local file_name

    file_name=$(basename "$url")
    if [[ "$file_name" =~ ^openvino_toolkit_[^_]+_([^/]+)_x86_64\.tgz$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

extract_semver_from_text() {
    local text="$1"
    echo "$text" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

detect_local_ov_version() {
    local dest_path="$1"
    local setupvars="$dest_path/setupvars.sh"
    local meta_file="$dest_path/$OV_VERSION_META_FILE_NAME"
    local raw_line semver

    if [[ -f "$meta_file" ]]; then
        raw_line=$(head -n 1 "$meta_file" | tr -d '\r' | xargs)
        semver=$(extract_semver_from_text "$raw_line")
        echo "$raw_line|$semver"
        return 0
    fi

    if [[ -f "$setupvars" ]]; then
        semver=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$setupvars" | head -n 1)
        if [[ -n "$semver" ]]; then
            echo "|$semver"
            return 0
        fi
    fi

    echo "|"
}

resolve_latest_ov_url() {
    local base_url="$1"
    local filetree_url filetree_json file_name version_dir candidate_url
    local versions_html version latest_version linux_url linux_html

    filetree_url="https://storage.openvinotoolkit.org/filetree.json"

    # Primary path: parse filetree metadata for stable Ubuntu24 x86_64 toolkit archives.
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

    # Pick latest stable version directory like 2026.1/, 2025.3/, ... (skip nightly-like names)
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

    # Prefer Ubuntu24 x86_64 toolkit archives; explicitly exclude nightly artifacts.
    file_name=$(echo "$linux_html" \
        | grep -oE 'href="openvino_toolkit_ubuntu24_[^"]*x86_64\.tgz"' \
        | sed -E 's/^href="|"$//g' \
        | grep -vi 'nightly' \
        | sort -V \
        | tail -n 1)

    # Fallback: any openvino_toolkit x86_64 tgz under linux folder, non-nightly.
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

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo to modify /opt/intel/."
   exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found."
    exit 1
fi

echo "Scanning $CONFIG_FILE for section $KEYWORD..."

while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r' | xargs)

    # A commented mode header means that mode block is disabled; stop consuming lines for current subsection.
    if [[ "$IN_SECTION" == true && "$line" =~ ^#\s*\[(DEFAULT|LATEST)\]$ ]]; then
        CURRENT_OV_SUBSECTION=""
        continue
    fi

    if [[ "$line" =~ $KEYWORD ]]; then
        IN_SECTION=true
        continue
    fi

    if [[ "$IN_SECTION" == true && "$line" =~ ^\[(DEFAULT|LATEST)\]$ ]]; then
        CURRENT_OV_SUBSECTION="${BASH_REMATCH[1]}"
        if [[ "$CURRENT_OV_SUBSECTION" == "DEFAULT" ]]; then
            HAS_DEFAULT_SECTION=true
        elif [[ "$CURRENT_OV_SUBSECTION" == "LATEST" ]]; then
            HAS_LATEST_SECTION=true
        fi
        continue
    fi

    if [[ "$IN_SECTION" == true && "$line" =~ ^\[.*\]$ ]]; then
        IN_SECTION=false
        break 
    fi

    if [[ "$IN_SECTION" == true ]]; then
        [[ -z "$line" || "$line" == "#"* ]] && continue

        if [[ "$line" == DEST_FOLDER=* ]]; then
            if [[ "$CURRENT_OV_SUBSECTION" == "DEFAULT" ]]; then
                [[ -z "$DEFAULT_DEST_PATH" ]] && DEFAULT_DEST_PATH="${line#*=}"
            elif [[ "$CURRENT_OV_SUBSECTION" == "LATEST" ]]; then
                [[ -z "$LATEST_DEST_PATH" ]] && LATEST_DEST_PATH="${line#*=}"
            fi
        elif [[ "$line" == http* && "$CURRENT_OV_SUBSECTION" == "DEFAULT" ]]; then
            [[ -z "$DEFAULT_URL" ]] && DEFAULT_URL="$line"
        fi
    fi
done < "$CONFIG_FILE"

if [[ "$HAS_DEFAULT_SECTION" == true && "$HAS_LATEST_SECTION" == true ]]; then
    echo "Error: Both [DEFAULT] and [LATEST] are active under [OV_DOWNLOAD]. Keep exactly one active subsection and comment out the other."
    exit 1
fi

if [[ "$HAS_DEFAULT_SECTION" == false && "$HAS_LATEST_SECTION" == false ]]; then
    echo "Error: Neither [DEFAULT] nor [LATEST] is active under [OV_DOWNLOAD]. Uncomment exactly one subsection."
    exit 1
fi

if [[ "$HAS_LATEST_SECTION" == true ]]; then
    ACTIVE_MODE="LATEST"
else
    ACTIVE_MODE="DEFAULT"
fi

if [[ "$ACTIVE_MODE" != "DEFAULT" && "$ACTIVE_MODE" != "LATEST" ]]; then
    echo "Error: Could not determine OV mode from [OV_DOWNLOAD]."
    exit 1
fi

if [[ "$ACTIVE_MODE" == "LATEST" ]]; then
    DEST_PATH="$LATEST_DEST_PATH"
    if [[ -z "$DEST_PATH" ]]; then
        echo "Error: DEST_FOLDER not defined under [OV_DOWNLOAD] [LATEST]."
        exit 1
    fi

    echo "Selected mode: LATEST"
    echo "Target Directory: $DEST_PATH"
    echo "Resolving latest stable OpenVINO package (nightly excluded)..."
    DOWNLOAD_URL=$(resolve_latest_ov_url "$OV_BASE_URL")
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "Error: Failed to resolve latest stable OpenVINO package from $OV_BASE_URL"
        exit 1
    fi
else
    DEST_PATH="$DEFAULT_DEST_PATH"
    if [[ -z "$DEST_PATH" ]]; then
        echo "Error: DEST_FOLDER not defined under [OV_DOWNLOAD] [DEFAULT]."
        exit 1
    fi
    if [[ -z "$DEFAULT_URL" ]]; then
        echo "Error: Download URL not defined under [OV_DOWNLOAD] [DEFAULT]."
        exit 1
    fi

    echo "Selected mode: DEFAULT"
    echo "Target Directory: $DEST_PATH"
    DOWNLOAD_URL="$DEFAULT_URL"
fi

TARGET_PKG_TAG=$(extract_pkg_tag_from_url "$DOWNLOAD_URL")
TARGET_SEMVER=$(extract_semver_from_text "$TARGET_PKG_TAG")
SETUPVARS_PATH="$DEST_PATH/setupvars.sh"

if [[ -f "$SETUPVARS_PATH" ]]; then
    LOCAL_VERSION_INFO=$(detect_local_ov_version "$DEST_PATH")
    LOCAL_PKG_TAG="${LOCAL_VERSION_INFO%%|*}"
    LOCAL_SEMVER="${LOCAL_VERSION_INFO#*|}"

    if [[ -n "$TARGET_PKG_TAG" && -n "$LOCAL_PKG_TAG" && "$LOCAL_PKG_TAG" == "$TARGET_PKG_TAG" ]]; then
        echo "OpenVINO already installed at $DEST_PATH"
        echo "Skip download: local package tag matches target ($TARGET_PKG_TAG)."
        exit 0
    fi

    if [[ -n "$TARGET_SEMVER" && -n "$LOCAL_SEMVER" && "$LOCAL_SEMVER" == "$TARGET_SEMVER" ]]; then
        echo "OpenVINO already installed at $DEST_PATH"
        echo "Skip download: local version matches target ($TARGET_SEMVER)."
        exit 0
    fi
fi

# 2. Setup Temporary Workspace
TMP_FILE="ov_pkg.tgz"
EXTRACT_DIR="ov_temp_extract"
mkdir -p "$EXTRACT_DIR"

# 3. Download
echo "------------------------------------------------"
echo "Downloading: $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" --output "$TMP_FILE"

# 4. Expand
echo "Extracting archive..."
tar -xf "$TMP_FILE" -C "$EXTRACT_DIR"

# 5. Replacement Logic (The "Overwrite" Feature)
EXTRACTED_FOLDER_NAME=$(ls "$EXTRACT_DIR" | head -n 1)

if [[ -d "$DEST_PATH" ]]; then
    echo "Path $DEST_PATH already exists. Replacing files..."
    rm -rf "$DEST_PATH"
fi

echo "Installing to: $DEST_PATH"
mkdir -p "$(dirname "$DEST_PATH")"
mv "$EXTRACT_DIR/$EXTRACTED_FOLDER_NAME" "$DEST_PATH"

if [[ -n "$TARGET_PKG_TAG" ]]; then
    echo "$TARGET_PKG_TAG" > "$DEST_PATH/$OV_VERSION_META_FILE_NAME"
fi

# 6. Cleanup
rm -rf "$EXTRACT_DIR" "$TMP_FILE"
echo "Installation complete."

echo "------------------------------------------------"
echo "Process finished."

