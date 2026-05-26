#!/bin/bash

# --- 0. Set CWD to project root ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

set -euo pipefail

RESULTS_DIR=""
CONFIG_FILE="config.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Missing config file: $CONFIG_FILE"
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq not found."
    exit 1
fi

RESULTS_DIR=$(yq -r '.results_dir // empty' "$CONFIG_FILE")
if [[ -z "$RESULTS_DIR" ]]; then
    echo "Error: Missing results_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$RESULTS_DIR" != /* ]]; then
    RESULTS_DIR="$PROJECT_ROOT/${RESULTS_DIR#./}"
fi

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "Error: Results directory not found: $RESULTS_DIR"
    exit 1
fi

INPUT_FILE="${1:-}"
if [[ -z "$INPUT_FILE" ]]; then
    INPUT_FILE=$(ls -1t "$RESULTS_DIR"/genaibench_*.txt 2>/dev/null | head -n 1 || true)
    if [[ -z "$INPUT_FILE" ]]; then
        echo "Error: No genaibench_*.txt found in $RESULTS_DIR"
        exit 1
    fi
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

if [[ "$(basename "$INPUT_FILE")" != genaibench_*.txt ]]; then
    echo "Error: Unsupported input file name. Expected pattern: genaibench_*.txt"
    exit 1
fi

OUTPUT_CSV="${INPUT_FILE%.txt}.csv"

build_missing_hf_report() {
    local hf_root=""
    local normalized_root=""
    local ir_root=""
    local model_id=""
    local stripped_model_name=""
    local safe_model_name=""
    local expected_path=""
    local configured_count=0
    local missing_count=0
    local -a model_items=()
    local -a missing_items=()
    local -a selected_devices=()
    local normalized_device=""
    declare -A seen_expected=()

    echo "#"
    echo "# === HF MODEL PRESENCE CHECK ==="

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "# [Missing config: $CONFIG_FILE]"
        return
    fi

    if ! command -v yq >/dev/null 2>&1; then
        echo "# [yq not found; skipping HF model presence check]"
        return
    fi

    hf_root=$(yq -r '.ir_dir // empty' "$CONFIG_FILE")
    if [[ -z "$hf_root" ]]; then
        echo "# [Missing ir_dir in $CONFIG_FILE]"
        return
    fi

    if [[ "$hf_root" != /* ]]; then
        normalized_root="$PROJECT_ROOT/${hf_root#./}"
    else
        normalized_root="$hf_root"
    fi

    mapfile -t model_items < <(yq -r '.ir_models.models[]?' "$CONFIG_FILE")
    if [[ ${#model_items[@]} -eq 0 ]]; then
        echo "# [No ir_models entries found; expected ir_models.models[]]"
        return
    fi

    mapfile -t selected_devices < <(yq -r '.defaults.devices[]?' "$CONFIG_FILE")
    if [[ ${#selected_devices[@]} -eq 0 ]]; then
        selected_devices=("GPU" "NPU")
    fi

    for model_id in "${model_items[@]}"; do
        model_id=$(echo "$model_id" | xargs)
        [[ -z "$model_id" ]] && continue

        stripped_model_name="${model_id#*/}"
        safe_model_name="${stripped_model_name//\//__}"

        for normalized_device in "${selected_devices[@]}"; do
            normalized_device=$(echo "$normalized_device" | xargs | tr '[:lower:]' '[:upper:]')
            if [[ "$normalized_device" != "GPU" && "$normalized_device" != "NPU" ]]; then
                continue
            fi

            expected_path="$normalized_root/$normalized_device/$safe_model_name/openvino_model.xml"
            if [[ -n "${seen_expected[$expected_path]:-}" ]]; then
                continue
            fi
            seen_expected[$expected_path]=1
            configured_count=$((configured_count + 1))

            if [[ ! -f "$expected_path" ]]; then
                missing_items+=("$normalized_device/$safe_model_name")
                missing_count=$((missing_count + 1))
            fi
        done
    done

    echo "# hf_root: $normalized_root"
    echo "# configured_device_models: $configured_count"
    echo "# missing_device_models: $missing_count"

    if [[ $missing_count -eq 0 ]]; then
        echo "# missing_hf_model: NONE"
    else
        for expected_path in "${missing_items[@]}"; do
            echo "# missing_hf_model: $expected_path"
        done
    fi
}

{
    build_missing_hf_report
    echo
} > "$OUTPUT_CSV"

awk '
function trim(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
}

function csv_escape(s) {
    gsub(/"/, "\"\"", s)
    return "\"" s "\""
}

function base_name(path, parts, n) {
    n = split(path, parts, "/")
    if (n > 0) {
        return parts[n]
    }
    return path
}

function flush_row() {
    if (!in_frame) {
        return
    }

    if (device != "" || model != "" || pit != "" || input_tokens != "" || ttft_ms != "" || tps != "") {
        print csv_escape(model) "," csv_escape(device) "," csv_escape(pit) "," csv_escape(input_tokens) "," csv_escape(ttft_ms) "," csv_escape(tps)
        rows++
    }
}

BEGIN {
    rows = 0
    in_frame = 0
    device = ""
    model = ""
    pit = ""
    input_tokens = ""
    ttft_ms = ""
    tps = ""

    print "Model,Device,PIT_s,InputTokenSize,TTFT_ms,TPS"
}

/^>> Device:/ {
    flush_row()

    in_frame = 1
    device = trim(substr($0, index($0, ":") + 1))
    model = ""
    pit = ""
    input_tokens = ""
    ttft_ms = ""
    tps = ""
    next
}

/^>> Model Dir:/ {
    model_dir = trim(substr($0, index($0, ":") + 1))
    model = base_name(model_dir)
    next
}

/\[ INFO \] Pipeline initialization time:/ {
    if (pit == "") {
        line = $0
        sub(/^.*Pipeline initialization time:[[:space:]]*/, "", line)
        sub(/s.*$/, "", line)
        pit = trim(line)
    }
    next
}

/\[ INFO \] \[Average\].*Input token size:/ {
    line = $0

    part = line
    sub(/^.*Input token size:[[:space:]]*/, "", part)
    sub(/,.*$/, "", part)
    input_tokens = trim(part)

    part = line
    sub(/^.*1st token latency:[[:space:]]*/, "", part)
    sub(/[[:space:]]*ms.*$/, "", part)
    ttft_ms = trim(part)

    part = line
    sub(/^.*2nd tokens throughput:[[:space:]]*/, "", part)
    sub(/[[:space:]]*tokens\/s.*$/, "", part)
    tps = trim(part)
    next
}

END {
    flush_row()

    if (rows == 0) {
        exit 2
    }
}
' "$INPUT_FILE" >> "$OUTPUT_CSV" || {
    status=$?
    if [[ "$status" -eq 2 ]]; then
        echo "Error: No benchmark frames found in $INPUT_FILE"
    else
        echo "Error: Failed to parse benchmark file: $INPUT_FILE"
    fi
    exit 1
}

echo "Input:  $INPUT_FILE"
echo "Output: $OUTPUT_CSV"
echo "genai parsing complete."
