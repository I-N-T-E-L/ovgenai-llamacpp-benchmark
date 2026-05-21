#!/bin/bash

set -euo pipefail

# --- 0. Set CWD to project root ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

CONFIG_FILE="config.yaml"
BUILD_DIR=""
GENAI_BENCH_SCRIPT=""
GENAI_VENV_ACTIVATE=""
MODELS_ROOT=""
IR_MODELS_ROOT=""
RESULTS_DIR=""

INITIAL_CONTENT_LENGTH=""
ITERATIONS=""
PROMPT_VALUE=""
PROMPT_FILE_VALUE=""
MAX_CONTEXT=""
declare -A DEVICE_SELECTED
RUN_MATRIX_MODE="false"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq not found. Run SCRIPTS/llamacpp_build.sh first to install dependencies."
    exit 1
fi

BUILD_DIR=$(yq -r '.build_dir // empty' "$CONFIG_FILE")
if [[ -z "$BUILD_DIR" ]]; then
    echo "Error: Missing build_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$PROJECT_ROOT/${BUILD_DIR#./}"
fi
GENAI_BENCH_SCRIPT="$BUILD_DIR/openvino.genai/tools/llm_bench/benchmark.py"
GENAI_VENV_ACTIVATE="$BUILD_DIR/openvino.genai/tools/llm_bench/python-env/bin/activate"

if [[ ! -f "$GENAI_BENCH_SCRIPT" ]]; then
    echo "Error: Missing benchmark script at $GENAI_BENCH_SCRIPT"
    exit 1
fi

if [[ ! -f "$GENAI_VENV_ACTIVATE" ]]; then
    echo "Error: Missing GenAI Python environment activate script at $GENAI_VENV_ACTIVATE"
    echo "Run SCRIPTS/genai_build.sh first to create the environment."
    exit 1
fi

IR_MODELS_ROOT=$(yq -r '.ir_dir // empty' "$CONFIG_FILE")
if [[ -z "$IR_MODELS_ROOT" ]]; then
    echo "Error: Missing ir_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$IR_MODELS_ROOT" != /* ]]; then
    IR_MODELS_ROOT="$PROJECT_ROOT/${IR_MODELS_ROOT#./}"
fi

if [[ -d "$IR_MODELS_ROOT" ]]; then
    MODELS_ROOT="$IR_MODELS_ROOT"
else
    echo "Error: Models root not found at $IR_MODELS_ROOT"
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

INITIAL_CONTENT_LENGTH=$(yq -r '.genai.benchmark.initial_content_length // empty' "$CONFIG_FILE")
ITERATIONS=$(yq -r '.genai.benchmark.iterations // empty' "$CONFIG_FILE")
PROMPT_VALUE=$(yq -r '.genai.benchmark.prompt // empty' "$CONFIG_FILE")
PROMPT_FILE_VALUE=$(yq -r '.genai.benchmark.prompt_file // empty' "$CONFIG_FILE")
MAX_CONTEXT=$(yq -r '.genai.benchmark.max_context // empty' "$CONFIG_FILE")

mapfile -t CONFIG_DEVICES < <(yq -r '.defaults.devices[]?' "$CONFIG_FILE")
RUN_MATRIX_GPU=$(yq -r '.run_matrix.devices.gpu // ""' "$CONFIG_FILE")
RUN_MATRIX_NPU=$(yq -r '.run_matrix.devices.npu // ""' "$CONFIG_FILE")

if [[ -n "$RUN_MATRIX_GPU" || -n "$RUN_MATRIX_NPU" ]]; then
    RUN_MATRIX_MODE="true"

    if [[ "${RUN_MATRIX_GPU,,}" == "true" ]]; then
        if [[ "$(yq -r '.run_matrix.gpu.ov_genai_ir_gpu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
            DEVICE_SELECTED["GPU"]=1
        else
            echo "Warning: run_matrix.devices.gpu is true but run_matrix.gpu.ov_genai_ir_gpu is false; skipping GPU for genai benchmark."
        fi
    fi

    if [[ "${RUN_MATRIX_NPU,,}" == "true" ]]; then
        if [[ "$(yq -r '.run_matrix.npu.ov_genai_ir_npu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
            DEVICE_SELECTED["NPU"]=1
        else
            echo "Warning: run_matrix.devices.npu is true but run_matrix.npu.ov_genai_ir_npu is false; skipping NPU for genai benchmark."
        fi
    fi
else
    if [[ ${#CONFIG_DEVICES[@]} -eq 0 ]]; then
        echo "Error: Missing run_matrix.devices and defaults.devices in $CONFIG_FILE"
        exit 1
    fi

    for DEVICE in "${CONFIG_DEVICES[@]}"; do
        NORMALIZED_DEVICE=$(echo "$DEVICE" | xargs | tr '[:lower:]' '[:upper:]')
        case "$NORMALIZED_DEVICE" in
            GPU|NPU)
                DEVICE_SELECTED["$NORMALIZED_DEVICE"]=1
                ;;
            CPU)
                ;;
            "")
                ;;
            *)
                echo "Warning: Unsupported genai benchmark device '$NORMALIZED_DEVICE'; skipping."
                ;;
        esac
    done
fi

if [[ -z "${DEVICE_SELECTED[GPU]:-}" && -z "${DEVICE_SELECTED[NPU]:-}" ]]; then
    if [[ "$RUN_MATRIX_MODE" == "true" ]]; then
        echo "Error: No supported genai devices enabled in run_matrix (requires devices.<gpu|npu>=true and ov_genai_ir_<gpu|npu>=true)."
    else
        echo "Error: No supported genai devices selected in defaults.devices. Supported: GPU, NPU"
    fi
    exit 1
fi

if [[ -z "$INITIAL_CONTENT_LENGTH" || -z "$ITERATIONS" || -z "$MAX_CONTEXT" ]]; then
    echo "Error: Missing required values under genai.benchmark in $CONFIG_FILE"
    exit 1
fi

if ! [[ "$INITIAL_CONTENT_LENGTH" =~ ^[0-9]+$ && "$ITERATIONS" =~ ^[0-9]+$ && "$MAX_CONTEXT" =~ ^[0-9]+$ ]]; then
    echo "Error: genai.benchmark.initial_content_length, iterations, and max_context must be integers"
    exit 1
fi

PROMPT_FILE_RESOLVED=""
declare -a PROMPT_ARGS

# Prompt string is always preferred. Use prompt_file only when prompt is not available.
if [[ -n "$PROMPT_VALUE" && "$PROMPT_VALUE" != "null" ]]; then
    PROMPT_ARGS=(-p "$PROMPT_VALUE")
else
    if [[ -z "$PROMPT_FILE_VALUE" || "$PROMPT_FILE_VALUE" == "null" ]]; then
        echo "Error: genai.benchmark.prompt is empty and genai.benchmark.prompt_file is not configured"
        exit 1
    fi

    if [[ "$PROMPT_FILE_VALUE" == /* ]]; then
        PROMPT_FILE_RESOLVED="$PROMPT_FILE_VALUE"
    else
        PROMPT_FILE_RESOLVED="$PROJECT_ROOT/${PROMPT_FILE_VALUE#./}"
    fi

    if [[ ! -f "$PROMPT_FILE_RESOLVED" ]]; then
        echo "Error: Prompt file not found at $PROMPT_FILE_RESOLVED"
        echo "Provide genai.benchmark.prompt or a valid genai.benchmark.prompt_file"
        exit 1
    fi

    PROMPT_ARGS=(-pf "$PROMPT_FILE_RESOLVED")
fi

mkdir -p "$RESULTS_DIR"
RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_FILE="$RESULTS_DIR/genaibench_${RUN_TIMESTAMP}.txt"

# shellcheck disable=SC1091
source "$GENAI_VENV_ACTIVATE"

echo "Saving all run outputs to: $OUT_FILE"

TOTAL_RUNS=0

mapfile -t CONFIG_IR_MODELS < <(yq -r '.ir_models.models[]?' "$CONFIG_FILE")
if [[ ${#CONFIG_IR_MODELS[@]} -eq 0 ]]; then
    echo "Error: No models listed under ir_models.models in $CONFIG_FILE"
    exit 1
fi

for DEVICE in GPU NPU; do
    if [[ -z "${DEVICE_SELECTED[$DEVICE]:-}" ]]; then
        continue
    fi

    MODEL_XML_FILES=()
    for MODEL_ID in "${CONFIG_IR_MODELS[@]}"; do
        MODEL_ID=$(echo "$MODEL_ID" | xargs)
        [[ -z "$MODEL_ID" ]] && continue

        STRIPPED_MODEL_NAME="${MODEL_ID#*/}"
        SAFE_MODEL_NAME="${STRIPPED_MODEL_NAME//\//__}"
        EXPECTED_MODEL_XML="$MODELS_ROOT/$DEVICE/$SAFE_MODEL_NAME/openvino_model.xml"

        if [[ -f "$EXPECTED_MODEL_XML" ]]; then
            MODEL_XML_FILES+=("$EXPECTED_MODEL_XML")
        else
            {
                echo "------------------------------------------------"
                echo ">> Config-listed $DEVICE model not found: $MODEL_ID"
                echo ">> Expected IR path: $EXPECTED_MODEL_XML"
                echo "------------------------------------------------"
            } | tee -a "$OUT_FILE"
        fi
    done

    if [[ ${#MODEL_XML_FILES[@]} -eq 0 ]]; then
        {
            echo "------------------------------------------------"
            echo ">> No config-listed $DEVICE models found under $MODELS_ROOT"
            echo "------------------------------------------------"
        } | tee -a "$OUT_FILE"
        continue
    fi

    for MODEL_XML in "${MODEL_XML_FILES[@]}"; do
        MODEL_DIR=$(dirname "$MODEL_XML")

        {
            echo "------------------------------------------------"
            echo ">> Device: $DEVICE"
            echo ">> Model Dir: $MODEL_DIR"
            echo ">> Executing: python3 $GENAI_BENCH_SCRIPT -ic $INITIAL_CONTENT_LENGTH -n $ITERATIONS ${PROMPT_ARGS[*]} -d $DEVICE -mc $MAX_CONTEXT -m $MODEL_DIR"
            python3 "$GENAI_BENCH_SCRIPT" \
                -ic "$INITIAL_CONTENT_LENGTH" \
                -n "$ITERATIONS" \
                "${PROMPT_ARGS[@]}" \
                -d "$DEVICE" \
                -mc "$MAX_CONTEXT" \
                -m "$MODEL_DIR"
            echo "------------------------------------------------"
        } 2>&1 | tee -a "$OUT_FILE"

        TOTAL_RUNS=$((TOTAL_RUNS + 1))
    done
done

if [[ "$TOTAL_RUNS" -eq 0 ]]; then
    echo "Error: No GPU/NPU OpenVINO model directories found under $MODELS_ROOT"
    exit 1
fi

echo "Completed $TOTAL_RUNS genai benchmark runs."
echo "Results saved to: $OUT_FILE"
