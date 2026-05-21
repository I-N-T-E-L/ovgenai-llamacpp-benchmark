#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

CONFIG_FILE="config.yaml"
BUILD_DIR=""
HF_MODELS_ROOT=""
GENAI_VENV_ACTIVATE=""
SUCCESS_COUNT=0
FAIL_COUNT=0
declare -a FAILURE_ITEMS
declare -a DEVICE_STATUS_ITEMS
EXPORT_FAILURE_REASON=""
EXPORT_TMP_RESULT=""
EXPORT_LAST_OUTPUT=""
INITIAL_TRANSFORMERS_VERSION=""

IR_GPU_GROUP_SIZE=""
IR_GPU_WEIGHT_FORMAT=""
IR_GPU_RATIO=""
IR_GPU_SYM=""
IR_GPU_TRUST_REMOTE_CODE=""
IR_NPU_GROUP_SIZE=""
IR_NPU_WEIGHT_FORMAT=""
IR_NPU_RATIO=""
IR_NPU_SYM=""
IR_NPU_TRUST_REMOTE_CODE=""

print_model_separator() {
    local title="$1"
    echo ""
    echo "============================================================"
    echo "$title"
    echo "============================================================"
}

append_device_status() {
    local device="$1"
    local model_name="$2"
    local status="$3"
    DEVICE_STATUS_ITEMS+=("$device|$model_name|$status")
}

extract_failure_reason() {
    local output_text="$1"
    local reason=""

    reason=$(printf '%s\n' "$output_text" | grep -E 'Maximum required is|not supported|unsupported|Unknown model type|requires[[:space:]]+transformers|ValueError|RuntimeError|OSError|Exception|Traceback' | tail -n 1 | xargs || true)

    if [[ -z "$reason" ]]; then
        reason=$(printf '%s\n' "$output_text" | awk 'NF { last=$0 } END { print last }' | xargs || true)
    fi

    if [[ -z "$reason" ]]; then
        reason="Unknown export failure (empty log output)"
    fi

    echo "$reason"
}

get_transformers_version() {
    python - <<'PY'
try:
    import transformers
    print(transformers.__version__)
except Exception:
    pass
PY
}

install_transformers_version() {
    local version="$1"
    [[ -z "$version" ]] && return 1
    python -m pip install -q "transformers==$version"
}

restore_transformers_version() {
    local current_version=""

    current_version=$(get_transformers_version | xargs || true)
    if [[ -n "$INITIAL_TRANSFORMERS_VERSION" ]]; then
        if [[ "$current_version" != "$INITIAL_TRANSFORMERS_VERSION" ]]; then
            echo "Info: Restoring transformers==$INITIAL_TRANSFORMERS_VERSION"
            install_transformers_version "$INITIAL_TRANSFORMERS_VERSION" || true
        fi
    else
        if [[ -n "$current_version" ]]; then
            echo "Info: Restoring environment by removing transformers"
            python -m pip uninstall -y transformers >/dev/null 2>&1 || true
        fi
    fi
}

extract_transformers_target_version() {
    local output_text="$1"
    local target_version=""

    target_version=$(printf '%s\n' "$output_text" | grep -oE 'Maximum required is [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $4}' | head -n 1)
    if [[ -n "$target_version" ]]; then
        echo "$target_version"
        return
    fi

    target_version=$(printf '%s\n' "$output_text" | sed -nE 's/.*requires[[:space:]]+transformers[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)
    if [[ -n "$target_version" ]]; then
        echo "$target_version"
        return
    fi

    target_version=$(printf '%s\n' "$output_text" | sed -nE 's/.*transformers==([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)
    echo "$target_version"
}

resolve_ir_export_settings_from_config() {
    IR_GPU_GROUP_SIZE=$(yq -r '.ir_models.params.gpu.group_size // empty' "$CONFIG_FILE" | xargs)
    IR_GPU_WEIGHT_FORMAT=$(yq -r '.ir_models.params.gpu.weight_format // empty' "$CONFIG_FILE" | xargs)
    IR_GPU_RATIO=$(yq -r '.ir_models.params.gpu.ratio // empty' "$CONFIG_FILE" | xargs)
    IR_GPU_SYM=$(yq -r '.ir_models.params.gpu.sym // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
    IR_GPU_TRUST_REMOTE_CODE=$(yq -r '.ir_models.params.gpu.trust_remote_code // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)

    IR_NPU_GROUP_SIZE=$(yq -r '.ir_models.params.npu.group_size // empty' "$CONFIG_FILE" | xargs)
    IR_NPU_WEIGHT_FORMAT=$(yq -r '.ir_models.params.npu.weight_format // empty' "$CONFIG_FILE" | xargs)
    IR_NPU_RATIO=$(yq -r '.ir_models.params.npu.ratio // empty' "$CONFIG_FILE" | xargs)
    IR_NPU_SYM=$(yq -r '.ir_models.params.npu.sym // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
    IR_NPU_TRUST_REMOTE_CODE=$(yq -r '.ir_models.params.npu.trust_remote_code // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
}

run_optimum_export_capture() {
    local model="$1"
    local device="$2"
    local out_dir="$3"
    local cmd_output=""
    local rc=0
    local weight_format=""
    local group_size=""
    local ratio=""
    local sym=""
    local trust_remote_code=""
    local -a cmd

    if [[ "$device" == "GPU" ]]; then
        weight_format="$IR_GPU_WEIGHT_FORMAT"
        group_size="$IR_GPU_GROUP_SIZE"
        ratio="$IR_GPU_RATIO"
        sym="$IR_GPU_SYM"
        trust_remote_code="$IR_GPU_TRUST_REMOTE_CODE"
    else
        weight_format="$IR_NPU_WEIGHT_FORMAT"
        group_size="$IR_NPU_GROUP_SIZE"
        ratio="$IR_NPU_RATIO"
        sym="$IR_NPU_SYM"
        trust_remote_code="$IR_NPU_TRUST_REMOTE_CODE"
    fi

    EXPORT_LAST_OUTPUT=""
    cmd=(optimum-cli export openvino -m "$model")

    if [[ -n "$weight_format" ]]; then
        cmd+=(--weight-format "$weight_format")
    fi

    if [[ "$sym" == "true" || "$sym" == "yes" || "$sym" == "1" ]]; then
        cmd+=(--sym)
    fi

    if [[ -n "$ratio" ]]; then
        cmd+=(--ratio "$ratio")
    fi

    if [[ -n "$group_size" ]]; then
        cmd+=(--group-size "$group_size")
    fi

    cmd+=("$out_dir")

    if [[ "$trust_remote_code" == "true" || "$trust_remote_code" == "yes" || "$trust_remote_code" == "1" ]]; then
        cmd+=(--trust-remote-code)
    fi

    cmd_output=$("${cmd[@]}" 2>&1)
    rc=$?

    EXPORT_LAST_OUTPUT="$cmd_output"
    if [[ -n "$cmd_output" ]]; then
        printf '%s\n' "$cmd_output"
    fi

    return $rc
}

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

apply_optional_hf_token_from_config() {
    local hf_token=""

    hf_token=$(yq -r '.ir_models.hf_token // empty' "$CONFIG_FILE" 2>/dev/null | xargs)
    if [[ -z "$hf_token" ]]; then
        return
    fi

    export HF_TOKEN="$hf_token"
    export HUGGINGFACE_HUB_TOKEN="$hf_token"
    export HF_HUB_TOKEN="$hf_token"
    echo "Applied optional hf_token from $CONFIG_FILE"
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
apply_optional_hf_token_from_config
resolve_ir_export_settings_from_config

BUILD_DIR=$(yq -r '.build_dir // empty' "$CONFIG_FILE")
if [[ -z "$BUILD_DIR" ]]; then
    echo "Error: Missing build_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$PROJECT_ROOT/${BUILD_DIR#./}"
fi
GENAI_VENV_ACTIVATE="$BUILD_DIR/openvino.genai/tools/llm_bench/python-env/bin/activate"

if [[ ! -f "$GENAI_VENV_ACTIVATE" ]]; then
    echo "Error: Missing GenAI Python environment activate script at $GENAI_VENV_ACTIVATE"
    echo "Run SCRIPTS/genai_build.sh first to create the environment."
    exit 1
fi

# shellcheck disable=SC1091
source "$GENAI_VENV_ACTIVATE"

if ! command -v optimum-cli >/dev/null 2>&1; then
    echo "Error: optimum-cli not found. Install Optimum/OpenVINO tooling first."
    exit 1
fi

INITIAL_TRANSFORMERS_VERSION=$(get_transformers_version | xargs || true)
if [[ -n "$INITIAL_TRANSFORMERS_VERSION" ]]; then
    echo "Detected transformers version: $INITIAL_TRANSFORMERS_VERSION"
else
    echo "Warning: transformers is not currently installed in the active environment."
fi

export_with_optional_transformers_retry() {
    local model="$1"
    local device="$2"
    local tmp_dir="$3"
    local target_tf=""
    local current_tf=""
    local changed_tf="false"
    local combined_output=""

    EXPORT_FAILURE_REASON=""
    EXPORT_TMP_RESULT=""

    if run_optimum_export_capture "$model" "$device" "$tmp_dir"; then
        EXPORT_TMP_RESULT="$tmp_dir"
        return 0
    fi
    combined_output="$EXPORT_LAST_OUTPUT"

    target_tf=$(extract_transformers_target_version "$combined_output")
    if [[ -n "$target_tf" ]]; then
        echo "Info: $device export for $model suggests transformers==$target_tf. Retrying with that version" >&2
        current_tf=$(get_transformers_version | xargs || true)
        if [[ "$current_tf" != "$target_tf" ]]; then
            changed_tf="true"
        fi

        if install_transformers_version "$target_tf"; then
            rm -rf "$tmp_dir"
            tmp_dir=$(mktemp -d "$HF_MODELS_ROOT/.${device,,}_retry.XXXXXX")

            if run_optimum_export_capture "$model" "$device" "$tmp_dir"; then
                EXPORT_TMP_RESULT="$tmp_dir"
                if [[ "$changed_tf" == "true" ]]; then
                    restore_transformers_version
                fi
                return 0
            fi
            combined_output="$combined_output
$EXPORT_LAST_OUTPUT"
        else
            echo "Warning: Failed to install transformers==$target_tf for retry." >&2
        fi

        if [[ "$changed_tf" == "true" ]]; then
            restore_transformers_version
        fi
    fi

    EXPORT_FAILURE_REASON=$(extract_failure_reason "$combined_output")
    rm -rf "$tmp_dir"
    return 1
}

HF_MODELS_ROOT=$(yq -r '.ir_dir // empty' "$CONFIG_FILE")
if [[ -z "$HF_MODELS_ROOT" ]]; then
    echo "Error: Missing ir_dir in $CONFIG_FILE"
    exit 1
fi

if [[ "$HF_MODELS_ROOT" != /* ]]; then
    HF_MODELS_ROOT="$PROJECT_ROOT/${HF_MODELS_ROOT#./}"
fi

mkdir -p "$HF_MODELS_ROOT"
echo "IR models root set to: $HF_MODELS_ROOT"

echo "Scanning $CONFIG_FILE for section ir_models..."

mapfile -t MODELS < <(yq -r '.ir_models.models[]?' "$CONFIG_FILE")
if [[ ${#MODELS[@]} -eq 0 ]]; then
    echo "Error: No models found in ir_models.models"
    exit 1
fi

for MODEL in "${MODELS[@]}"; do
    MODEL=$(echo "$MODEL" | xargs)
    [[ -z "$MODEL" ]] && continue

    print_model_separator "Model: $MODEL"

    STRIPPED_MODEL_NAME="${MODEL#*/}"
    SAFE_MODEL_NAME="${STRIPPED_MODEL_NAME//\//__}"

    NPU_OUT_DIR="$HF_MODELS_ROOT/NPU/$SAFE_MODEL_NAME"
    GPU_OUT_DIR="$HF_MODELS_ROOT/GPU/$SAFE_MODEL_NAME"

    if [[ -f "$NPU_OUT_DIR/openvino_model.xml" ]]; then
        echo "Skipping NPU export for $MODEL (already exists at $NPU_OUT_DIR)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        append_device_status "NPU" "$MODEL" "QUANTIZED"
    else
        echo "Exporting NPU model: $MODEL -> $NPU_OUT_DIR"
        TMP_NPU_DIR=$(mktemp -d "$HF_MODELS_ROOT/.npu_${SAFE_MODEL_NAME}.XXXXXX")
        export_with_optional_transformers_retry "$MODEL" "NPU" "$TMP_NPU_DIR" || true

        if [[ -n "$EXPORT_TMP_RESULT" && -d "$EXPORT_TMP_RESULT" ]]; then
            mkdir -p "$(dirname "$NPU_OUT_DIR")"
            rm -rf "$NPU_OUT_DIR"
            mv "$EXPORT_TMP_RESULT" "$NPU_OUT_DIR"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            append_device_status "NPU" "$MODEL" "QUANTIZED"
        else
            echo "Warning: NPU export failed for $MODEL"
            echo "Reason: $EXPORT_FAILURE_REASON"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILURE_ITEMS+=("NPU|$MODEL|$EXPORT_FAILURE_REASON")
            append_device_status "NPU" "$MODEL" "NOT_QUANTIZED"
        fi
    fi

    if [[ -f "$GPU_OUT_DIR/openvino_model.xml" ]]; then
        echo "Skipping GPU export for $MODEL (already exists at $GPU_OUT_DIR)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        append_device_status "GPU" "$MODEL" "QUANTIZED"
    else
        echo "Exporting GPU model: $MODEL -> $GPU_OUT_DIR"
        TMP_GPU_DIR=$(mktemp -d "$HF_MODELS_ROOT/.gpu_${SAFE_MODEL_NAME}.XXXXXX")
        export_with_optional_transformers_retry "$MODEL" "GPU" "$TMP_GPU_DIR" || true

        if [[ -n "$EXPORT_TMP_RESULT" && -d "$EXPORT_TMP_RESULT" ]]; then
            mkdir -p "$(dirname "$GPU_OUT_DIR")"
            rm -rf "$GPU_OUT_DIR"
            mv "$EXPORT_TMP_RESULT" "$GPU_OUT_DIR"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            append_device_status "GPU" "$MODEL" "QUANTIZED"
        else
            echo "Warning: GPU export failed for $MODEL"
            echo "Reason: $EXPORT_FAILURE_REASON"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILURE_ITEMS+=("GPU|$MODEL|$EXPORT_FAILURE_REASON")
            append_device_status "GPU" "$MODEL" "NOT_QUANTIZED"
        fi
    fi
done

echo ""
echo "Device-wise quantization status:"
if [[ ${#DEVICE_STATUS_ITEMS[@]} -eq 0 ]]; then
    echo "  - NONE"
else
    for item in "${DEVICE_STATUS_ITEMS[@]}"; do
        IFS='|' read -r status_device status_model status_value <<< "$item"
        echo "  - $status_device :: $status_model :: $status_value"
    done
fi

echo "Process complete."

