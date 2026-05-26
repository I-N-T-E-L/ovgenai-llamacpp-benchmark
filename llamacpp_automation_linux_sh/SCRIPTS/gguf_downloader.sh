#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

CONFIG_FILE="config.yaml"
GGUF_ROOT=""

apply_optional_proxy_from_config() {
    local use_proxy=""
    local proxy_line=""
    local proxy_var=""
    local proxy_val=""

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

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found."
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq not found. Run SCRIPTS/llamacpp_build.sh first to install dependencies."
    exit 1
fi

apply_optional_proxy_from_config

GGUF_ROOT=$(yq -r '.gguf_dir // empty' "$CONFIG_FILE")
if [[ -z "$GGUF_ROOT" ]]; then
    echo "Error: Missing gguf_dir in $CONFIG_FILE"
    exit 1
fi

if [[ "$GGUF_ROOT" != /* ]]; then
    GGUF_ROOT="$PROJECT_ROOT/${GGUF_ROOT#./}"
fi

mkdir -p "$GGUF_ROOT"
echo "GGUF root set to: $GGUF_ROOT"

mapfile -t SELECTED_QUANTS < <(yq -r '.llamacpp.quantizations[]?' "$CONFIG_FILE")
if [[ ${#SELECTED_QUANTS[@]} -eq 0 ]]; then
    echo "Error: llamacpp.quantizations is empty in $CONFIG_FILE"
    exit 1
fi

if [[ ${#SELECTED_QUANTS[@]} -eq 0 ]]; then
    echo "Error: No quantization entries found in $CONFIG_FILE"
    exit 1
fi

echo "Scanning $CONFIG_FILE for GGUF URLs from selected quantizations..."

for quant in "${SELECTED_QUANTS[@]}"; do
    quant=$(echo "$quant" | xargs)
    [[ -z "$quant" ]] && continue

    QUANT_DIR="$GGUF_ROOT/$quant"
    mkdir -p "$QUANT_DIR"

    mapfile -t URLS < <(yq -r --arg q "$quant" '.gguf_models[$q][]? // empty' "$CONFIG_FILE")
    if [[ ${#URLS[@]} -eq 0 ]]; then
        echo "Warning: No gguf_models.$quant entry"
        continue
    fi

    for url in "${URLS[@]}"; do
        [[ -z "$url" ]] && continue

        if [[ "$url" == http* ]]; then
            file_name="${url##*/}"
            file_name="${file_name%%\?*}"

            if [[ -f "$QUANT_DIR/$file_name" ]]; then
                echo "Skipping: $file_name already exists in $QUANT_DIR"
            else
                echo "Downloading [$quant]: $url"
                wget -q --show-progress -P "$QUANT_DIR" "$url"
            fi
        else
            echo "Warning: Skipping non-URL entry under quantization '$quant': $url"
        fi
    done
done

echo "Process complete."

