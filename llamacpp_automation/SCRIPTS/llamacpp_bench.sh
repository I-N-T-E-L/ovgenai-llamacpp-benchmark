#!/bin/bash

# --- 0. Set CWD to project root ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

CONFIG_FILE="config.yaml"
OV_LOG_FILE=""
OV_PATH=""
OV_DEST_FOLDER=""
GGUF_ROOT=""
BUILD_ROOT=""
BENCHMARK_DEVICES_RAW=""
PP_TOKENS=""
TG_TOKENS=""
NPU_PP_TOKENS=""
NPU_TG_TOKENS=""
GPU_DEPTH=""
N_GPU_LAYERS=""
BENCH_REPETITIONS=""
LLAMACPP_USE_MODE="build"
declare -a COMMANDS
declare -A DEVICE_SELECTED
declare -A DEVICE_RUNTIME_ENV_PREFIX
declare -A MODEL_PATHS
declare -A COMMAND_KEYS_ADDED

extract_semver_from_text() {
    local text="$1"
    echo "$text" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

is_int_list() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]]
}

detect_installed_ov_version() {
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

check_ov_log_version_match() {
    local logged_ov_version=""
    local logged_ov_version_raw=""
    local installed_ov_version=""
    local active_mode=""

    if [[ "$OV_VERSION_MODE" == "latest" ]]; then
        active_mode="latest"
    elif [[ "$OV_VERSION_MODE" == "default" ]]; then
        active_mode="default"
    else
        active_mode="unknown"
    fi

    if [[ ! -f "$OV_LOG_FILE" ]]; then
        echo "Error: Missing OpenVINO build log at $OV_LOG_FILE."
        echo "Run SCRIPTS/llamacpp_build.sh to rebuild OV backend with the current OpenVINO install."
        return 1
    fi

    logged_ov_version_raw=$(head -n 1 "$OV_LOG_FILE" 2>/dev/null | xargs || true)
    logged_ov_version=$(extract_semver_from_text "$logged_ov_version_raw")
    installed_ov_version=$(detect_installed_ov_version "$OV_DEST_FOLDER")

    if [[ -z "$logged_ov_version" || "$logged_ov_version" == "N/A" ]]; then
        echo "Error: Invalid OpenVINO version log format in $OV_LOG_FILE."
        echo "Expected first line semver like: 2026.1.2"
        echo "Run SCRIPTS/llamacpp_build.sh to refresh OV build version log."
        return 1
    fi

    if [[ "$installed_ov_version" == "N/A" ]]; then
        echo "Error: Could not detect installed OpenVINO version at $OV_DEST_FOLDER."
        echo "Expected explicit version file: $OV_DEST_FOLDER/runtime/version.txt"
        return 1
    fi

    if [[ "$installed_ov_version" != "$logged_ov_version" ]]; then
        echo "Error: OpenVINO version mismatch in benchmark precheck (mode: $active_mode)."
        echo "Logged OV build version: $logged_ov_version"
        echo "Installed OV version:    $installed_ov_version"
        echo "Fix: rerun SCRIPTS/llamacpp_build.sh so ReleaseOV is rebuilt against installed OV."
        return 1
    fi

    return 0
}

check_ov_binary_runtime_match() {
    local ov_bin=""
    local required_ov_soname=""
    local resolved_ov_path=""
    local normalized_ov_root=""

    ov_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/ReleaseOV")

    if [[ ! -x "$ov_bin" ]]; then
        echo "Error: Missing OV benchmark binary at $ov_bin"
        echo "Run SCRIPTS/llamacpp_build.sh to build OpenVINO backend first."
        return 1
    fi

    if ! command -v ldd >/dev/null 2>&1; then
        echo "Warning: ldd not available; skipping OV ABI preflight check."
        return 0
    fi

    required_ov_soname=$(ldd "$ov_bin" 2>/dev/null | awk '/libopenvino\.so/{print $1; exit}')
    if [[ -z "$required_ov_soname" ]]; then
        echo "Warning: Could not determine required OpenVINO soname from $ov_bin; skipping ABI check."
        return 0
    fi

    resolved_ov_path=$(ldd "$ov_bin" 2>/dev/null | awk '/libopenvino\.so/{print $3; exit}')
    if [[ -n "$resolved_ov_path" && "$resolved_ov_path" != "not" && -f "$resolved_ov_path" ]]; then
        normalized_ov_root=$(cd "$OV_DEST_FOLDER" 2>/dev/null && pwd)
        if [[ -n "$normalized_ov_root" ]]; then
            case "$resolved_ov_path" in
                "$normalized_ov_root"/*)
                    return 0
                    ;;
            esac
        fi
    fi

    if find "$OV_DEST_FOLDER" -type f -name "$required_ov_soname" 2>/dev/null | grep -q .; then
        return 0
    fi

    echo "Error: OpenVINO runtime mismatch detected before benchmark start."
    echo "Required by OV binary: $required_ov_soname"
    echo "Configured OpenVINO folder: $OV_DEST_FOLDER"
    echo "Fix: provide matching runtime libraries under the configured OpenVINO folder."
    return 1
}

build_runtime_env_prefix() {
    local device_lc="$1"
    local entry=""
    local key=""
    local value=""
    local escaped_value=""
    local prefix=""

    while IFS= read -r entry; do
        key=${entry%%=*}
        value=${entry#*=}

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Warning: Skipping invalid env var key '$key' under llamacpp.runtime_env.$device_lc"
            continue
        fi

        escaped_value=$(printf '%q' "$value")
        prefix+="$key=$escaped_value "
    done < <(yq -r --arg d "$device_lc" '.llamacpp.runtime_env[$d] // {} | to_entries[]? | "\(.key)=\(.value|tostring)"' "$CONFIG_FILE")

    echo "$prefix"
}

build_backend_ld_prefix() {
    local backend_dir="$1"

    if [[ "$LLAMACPP_USE_MODE" == "release" ]]; then
        echo "LD_LIBRARY_PATH=$backend_dir:$backend_dir/bin:\${LD_LIBRARY_PATH:-} "
        return
    fi

    # Build mode relies on binary RUNPATH and configured OpenVINO setup; do not override loader paths.
    echo ""
}

resolve_backend_bench_binary() {
    local backend_dir="$1"

    # Release packages may keep executables at backend root; source builds keep them in bin/.
    if [[ -x "$backend_dir/llama-bench" ]]; then
        echo "$backend_dir/llama-bench"
        return
    fi

    echo "$backend_dir/bin/llama-bench"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

# Avoid large core dump files when driver/runtime aborts on unsupported model-device combos.
ulimit -c 0 >/dev/null 2>&1 || true

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq not found. Run SCRIPTS/llamacpp_build.sh first to install dependencies."
    exit 1
fi

MODEL_FOLDER=$(yq -r '.gguf_dir // empty' "$CONFIG_FILE")
if [[ -z "$MODEL_FOLDER" ]]; then
    echo "Error: Missing gguf_dir in $CONFIG_FILE"
    exit 1
fi

BUILD_ROOT=$(yq -r '.build_dir // empty' "$CONFIG_FILE")
if [[ -z "$BUILD_ROOT" ]]; then
    echo "Error: Missing build_dir in $CONFIG_FILE"
    exit 1
fi

LLAMACPP_USE_MODE=$(yq -r '.llamacpp.use // "build"' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
if [[ "$LLAMACPP_USE_MODE" != "build" && "$LLAMACPP_USE_MODE" != "release" ]]; then
    echo "Error: llamacpp.use must be 'build' or 'release' in $CONFIG_FILE"
    exit 1
fi

OV_LOG_FILE=$(yq -r '.logs_dir // empty' "$CONFIG_FILE")
if [[ -z "$OV_LOG_FILE" ]]; then
    echo "Error: Missing logs_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$OV_LOG_FILE" != /* ]]; then
    OV_LOG_FILE="$PROJECT_ROOT/${OV_LOG_FILE#./}"
fi
OV_LOG_FILE="$OV_LOG_FILE/ov_build_info_${LLAMACPP_USE_MODE}.txt"

RUN_MATRIX_CPU=$(yq -r '.run_matrix.devices.cpu // ""' "$CONFIG_FILE")
RUN_MATRIX_GPU=$(yq -r '.run_matrix.devices.gpu // ""' "$CONFIG_FILE")
RUN_MATRIX_NPU=$(yq -r '.run_matrix.devices.npu // ""' "$CONFIG_FILE")
RUN_MATRIX_MODE="false"

if [[ -n "$RUN_MATRIX_CPU" || -n "$RUN_MATRIX_GPU" || -n "$RUN_MATRIX_NPU" ]]; then
    RUN_MATRIX_MODE="true"

    if [[ "${RUN_MATRIX_CPU,,}" == "true" ]]; then
        DEVICE_SELECTED["CPU"]=1
    fi
    if [[ "${RUN_MATRIX_GPU,,}" == "true" ]]; then
        DEVICE_SELECTED["GPU"]=1
    fi
    if [[ "${RUN_MATRIX_NPU,,}" == "true" ]]; then
        DEVICE_SELECTED["NPU"]=1
    fi
else
    mapfile -t DEVICE_ITEMS < <(yq -r '.defaults.devices[]?' "$CONFIG_FILE")
    if [[ ${#DEVICE_ITEMS[@]} -eq 0 ]]; then
        echo "Error: Missing run_matrix.devices and defaults.devices in $CONFIG_FILE"
        exit 1
    fi

    for device in "${DEVICE_ITEMS[@]}"; do
        parsed_device=$(echo "$device" | xargs | tr '[:lower:]' '[:upper:]')
        case "$parsed_device" in
            CPU|GPU|NPU)
                DEVICE_SELECTED["$parsed_device"]=1
                ;;
            "")
                ;;
            *)
                echo "Warning: Unsupported benchmark device '$parsed_device'; skipping."
                ;;
        esac
    done
fi

mapfile -t QUANT_ITEMS < <(yq -r '.llamacpp.quantizations[]?' "$CONFIG_FILE")
if [[ ${#QUANT_ITEMS[@]} -eq 0 ]]; then
    echo "Error: Missing llamacpp.quantizations in $CONFIG_FILE"
    exit 1
fi

PP_TOKENS=$(yq -r '.llamacpp.bench.pp_tokens // empty' "$CONFIG_FILE")
TG_TOKENS=$(yq -r '.llamacpp.bench.tg_tokens // empty' "$CONFIG_FILE")
NPU_PP_TOKENS=$(yq -r '.llamacpp.bench.npu_pp_tokens // empty' "$CONFIG_FILE")
NPU_TG_TOKENS=$(yq -r '.llamacpp.bench.npu_tg_tokens // empty' "$CONFIG_FILE")
GPU_DEPTH=$(yq -r '.llamacpp.bench.gpu_depth // empty' "$CONFIG_FILE")
N_GPU_LAYERS=$(yq -r '.llamacpp.bench.n_gpu_layers // empty' "$CONFIG_FILE")
BENCH_REPETITIONS=$(yq -r '.llamacpp.bench.repetitions // empty' "$CONFIG_FILE")

if [[ -z "$PP_TOKENS" || -z "$TG_TOKENS" || -z "$NPU_PP_TOKENS" || -z "$NPU_TG_TOKENS" || -z "$GPU_DEPTH" || -z "$N_GPU_LAYERS" || \
    -z "$BENCH_REPETITIONS" ]]; then
    echo "Error: Missing required values under llamacpp.bench in $CONFIG_FILE"
    exit 1
fi

if ! is_int_list "$PP_TOKENS" || \
   ! is_int_list "$TG_TOKENS" || \
   ! is_int_list "$NPU_PP_TOKENS" || \
   ! is_int_list "$NPU_TG_TOKENS" || \
   ! is_int_list "$GPU_DEPTH" || \
   ! is_int_list "$N_GPU_LAYERS" || \
   ! is_int_list "$BENCH_REPETITIONS"; then
    echo "Error: llamacpp.bench values must be integer or comma-separated integer lists"
    exit 1
fi

if [[ "$MODEL_FOLDER" != /* ]]; then
    MODEL_FOLDER="$PROJECT_ROOT/${MODEL_FOLDER#./}"
fi
if [[ "$BUILD_ROOT" != /* ]]; then
    BUILD_ROOT="$PROJECT_ROOT/${BUILD_ROOT#./}"
fi
GGUF_ROOT="$MODEL_FOLDER"
BUILD_ROOT="$BUILD_ROOT/llama.cpp/$LLAMACPP_USE_MODE"

for quant in "${QUANT_ITEMS[@]}"; do
    quant=$(echo "$quant" | xargs)
    [[ -z "$quant" ]] && continue

    QUANT_DIR="$GGUF_ROOT/$quant"
    if [[ ! -d "$QUANT_DIR" ]]; then
        echo "Warning: Missing quantization folder '$QUANT_DIR' for benchmark quantization '$quant'"
        continue
    fi

    mapfile -t CONFIG_MODEL_ENTRIES < <(yq -r --arg q "$quant" '.gguf_models[$q][]? // empty' "$CONFIG_FILE")
    if [[ ${#CONFIG_MODEL_ENTRIES[@]} -eq 0 ]]; then
        echo "Warning: No models listed under gguf_models.$quant in $CONFIG_FILE"
        continue
    fi

    for model_entry in "${CONFIG_MODEL_ENTRIES[@]}"; do
        model_entry=$(echo "$model_entry" | xargs)
        [[ -z "$model_entry" ]] && continue

        model_file_name=""
        if [[ "$model_entry" == http*://* ]]; then
            model_file_name="${model_entry##*/}"
            model_file_name="${model_file_name%%\?*}"
        elif [[ "$model_entry" == /* ]]; then
            if [[ -f "$model_entry" ]]; then
                MODEL_PATHS["$model_entry"]=1
            else
                echo "Warning: Config-listed model not found: $model_entry"
            fi
            continue
        else
            model_file_name="${model_entry##*/}"
        fi

        [[ -z "$model_file_name" ]] && continue

        model_path="$QUANT_DIR/$model_file_name"
        if [[ -f "$model_path" ]]; then
            MODEL_PATHS["$model_path"]=1
        else
            echo "Warning: Config-listed model not found for quantization '$quant': $model_path"
        fi
    done
done

if [[ ${#MODEL_PATHS[@]} -eq 0 ]]; then
    echo "Error: No matching model files found in $GGUF_ROOT for selected llamacpp.quantizations"
    exit 1
fi

if [[ -z "${DEVICE_SELECTED[CPU]}" && -z "${DEVICE_SELECTED[GPU]}" && -z "${DEVICE_SELECTED[NPU]}" ]]; then
    if [[ "$RUN_MATRIX_MODE" == "true" ]]; then
        echo "Error: No enabled devices found in run_matrix.devices. Supported: cpu, gpu, npu"
    else
        echo "Error: No valid devices found in defaults.devices. Supported: CPU, GPU, NPU"
    fi
    exit 1
fi

DEVICE_RUNTIME_ENV_PREFIX["CPU"]=$(build_runtime_env_prefix "cpu")
DEVICE_RUNTIME_ENV_PREFIX["GPU"]=$(build_runtime_env_prefix "gpu")
DEVICE_RUNTIME_ENV_PREFIX["NPU"]=$(build_runtime_env_prefix "npu")

add_command_once() {
    local cmd_key="$1"
    local cmd_value="$2"

    if [[ -n "${COMMAND_KEYS_ADDED[$cmd_key]:-}" ]]; then
        return
    fi

    COMMAND_KEYS_ADDED[$cmd_key]=1
    COMMANDS+=("$cmd_value")
}

for device in CPU GPU NPU; do
    [[ -z "${DEVICE_SELECTED[$device]:-}" ]] && continue

    BACKEND_ITEMS=()
    if [[ "$RUN_MATRIX_MODE" == "true" ]]; then
        case "$device" in
            CPU)
                [[ "$(yq -r '.run_matrix.cpu.llamacpp_ggml_cpu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]] && BACKEND_ITEMS+=("llamacpp_barecpu")
                [[ "$(yq -r '.run_matrix.cpu.llamacpp_ov_cpu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]] && BACKEND_ITEMS+=("llamacpp_openvino")
                ;;
            GPU)
                [[ "$(yq -r '.run_matrix.gpu.llamacpp_vulkan_gpu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]] && BACKEND_ITEMS+=("llamacpp_vulkan")
                [[ "$(yq -r '.run_matrix.gpu.llamacpp_ov_gpu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]] && BACKEND_ITEMS+=("llamacpp_openvino")
                ;;
            NPU)
                [[ "$(yq -r '.run_matrix.npu.llamacpp_ov_npu // false' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')" == "true" ]] && BACKEND_ITEMS+=("llamacpp_openvino")
                ;;
        esac
    else
        mapfile -t BACKEND_ITEMS < <(yq -r --arg d "$device" '.defaults[$d][]?' "$CONFIG_FILE")
    fi

    if [[ ${#BACKEND_ITEMS[@]} -eq 0 ]]; then
        if [[ "$RUN_MATRIX_MODE" == "true" ]]; then
            echo "Warning: No enabled llama backends found under run_matrix.${device,,}; skipping device."
        else
            echo "Warning: No backend list found under defaults.$device; skipping device."
        fi
        continue
    fi

    for backend in "${BACKEND_ITEMS[@]}"; do
        backend=$(echo "$backend" | xargs | tr '[:upper:]' '[:lower:]')
        [[ -z "$backend" ]] && continue

        ld_prefix=""
        bench_bin=""
        env_prefix="${DEVICE_RUNTIME_ENV_PREFIX[$device]:-}"

        case "$device:$backend" in
            CPU:llamacpp_barecpu)
                ld_prefix=$(build_backend_ld_prefix "$BUILD_ROOT/Release")
                bench_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/Release")
                add_command_once "CPU:llamacpp_barecpu" "${ld_prefix}${env_prefix}$bench_bin -r \"${BENCH_REPETITIONS}\" -p \"${PP_TOKENS}\" -n \"${TG_TOKENS}\""
                ;;
            CPU:llamacpp_openvino)
                if [[ -z "$env_prefix" ]]; then
                    env_prefix="GGML_OPENVINO_DEVICE=CPU GGML_OPENVINO_STATEFUL_EXECUTION=1 "
                fi
                ld_prefix=$(build_backend_ld_prefix "$BUILD_ROOT/ReleaseOV")
                bench_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/ReleaseOV")
                add_command_once "CPU:llamacpp_openvino" "${ld_prefix}${env_prefix}$bench_bin -fa 1 -r \"${BENCH_REPETITIONS}\" -p \"${PP_TOKENS}\" -n \"${TG_TOKENS}\""
                ;;
            GPU:llamacpp_vulkan)
                ld_prefix=$(build_backend_ld_prefix "$BUILD_ROOT/ReleaseVulkan")
                bench_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/ReleaseVulkan")
                add_command_once "GPU:llamacpp_vulkan" "${ld_prefix}${env_prefix}$bench_bin -r \"${BENCH_REPETITIONS}\" -d \"${GPU_DEPTH}\" -ngl \"${N_GPU_LAYERS}\" -p \"${PP_TOKENS}\" -n \"${TG_TOKENS}\""
                ;;
            GPU:llamacpp_openvino)
                if [[ -z "$env_prefix" ]]; then
                    env_prefix="GGML_OPENVINO_DEVICE=GPU GGML_OPENVINO_STATEFUL_EXECUTION=1 "
                fi
                ld_prefix=$(build_backend_ld_prefix "$BUILD_ROOT/ReleaseOV")
                bench_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/ReleaseOV")
                add_command_once "GPU:llamacpp_openvino" "${ld_prefix}${env_prefix}$bench_bin -fa 1 -r \"${BENCH_REPETITIONS}\" -d \"${GPU_DEPTH}\" -ngl \"${N_GPU_LAYERS}\" -p \"${PP_TOKENS}\" -n \"${TG_TOKENS}\""
                ;;
            NPU:llamacpp_openvino)
                if [[ -z "$env_prefix" ]]; then
                    env_prefix="GGML_OPENVINO_DEVICE=NPU "
                fi
                ld_prefix=$(build_backend_ld_prefix "$BUILD_ROOT/ReleaseOV")
                bench_bin=$(resolve_backend_bench_binary "$BUILD_ROOT/ReleaseOV")
                add_command_once "NPU:llamacpp_openvino" "${ld_prefix}${env_prefix}$bench_bin -fa 1 -r \"${BENCH_REPETITIONS}\" -p \"${NPU_PP_TOKENS}\" -n \"${NPU_TG_TOKENS}\""
                ;;
            *)
                ;;
        esac
    done
done

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
    if [[ "$RUN_MATRIX_MODE" == "true" ]]; then
        echo "Error: No runnable llama backends enabled in run_matrix.<device> in $CONFIG_FILE"
    else
        echo "Error: No runnable llama benchmark backends selected from defaults.<DEVICE> in $CONFIG_FILE"
    fi
    exit 1
fi

NEEDS_OV_RUNTIME="false"
for cmd in "${COMMANDS[@]}"; do
    if [[ "$cmd" == *"ReleaseOV"* ]]; then
        NEEDS_OV_RUNTIME="true"
        break
    fi
done

if [[ "$NEEDS_OV_RUNTIME" == "true" ]]; then
    if [[ "$LLAMACPP_USE_MODE" == "build" ]]; then
        OV_VERSION_MODE=$(yq -r '.openvino.version // empty' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]')
        if [[ "$OV_VERSION_MODE" != "default" && "$OV_VERSION_MODE" != "latest" ]]; then
            echo "Error: openvino.version must be 'default' or 'latest' in $CONFIG_FILE"
            exit 1
        fi

        OV_DEST_FOLDER=$(yq -r '.llamacpp_ov_dir // empty' "$CONFIG_FILE")
        if [[ -z "$OV_DEST_FOLDER" ]]; then
            echo "Error: Missing llamacpp_ov_dir in $CONFIG_FILE"
            exit 1
        fi

        if [[ "$OV_DEST_FOLDER" != /* ]]; then
            OV_DEST_FOLDER="$PROJECT_ROOT/${OV_DEST_FOLDER#./}"
        fi

        OV_PATH="${OV_DEST_FOLDER}/setupvars.sh"
        if [[ ! -f "$OV_PATH" ]]; then
            echo "Error: Missing explicit OpenVINO setupvars path: $OV_PATH"
            exit 1
        fi

        # Ensure installed OV matches the OV version used during last OV build.
        check_ov_log_version_match || exit 1

        # Fail early if ReleaseOV binary and configured OpenVINO runtime are ABI-incompatible.
        check_ov_binary_runtime_match || exit 1
    elif [[ "$LLAMACPP_USE_MODE" == "release" ]]; then
        OV_DEST_FOLDER="$BUILD_ROOT/OpenVINO_release_runtime"
        OV_PATH="${OV_DEST_FOLDER}/setupvars.sh"

        if [[ ! -f "$OV_PATH" ]]; then
            echo "Error: Missing release OpenVINO runtime setupvars path: $OV_PATH"
            echo "Run SCRIPTS/llamacpp_build.sh in release mode to provision OpenVINO_release_runtime."
            exit 1
        fi

        # Fail early if ReleaseOV binary and release runtime folder are ABI-incompatible.
        check_ov_binary_runtime_match || exit 1
    fi
fi

MODELS=()
for model_path in "${!MODEL_PATHS[@]}"; do
    MODELS+=("$model_path")
done

echo "Found ${#MODELS[@]} selected models in $GGUF_ROOT"

RESULTS_DIR=$(yq -r '.results_dir // empty' "$CONFIG_FILE")
if [[ -z "$RESULTS_DIR" ]]; then
    echo "Error: Missing results_dir in $CONFIG_FILE"
    exit 1
fi
if [[ "$RESULTS_DIR" != /* ]]; then
    RESULTS_DIR="$PROJECT_ROOT/${RESULTS_DIR#./}"
fi
mkdir -p "$RESULTS_DIR"
RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_FILE="$RESULTS_DIR/llamabench_${RUN_TIMESTAMP}.txt"

echo "Saving all run outputs to: $OUT_FILE"

for CMD in "${COMMANDS[@]}"; do
    for MODEL in "${MODELS[@]}"; do
        EXEC_PATH=$(echo "$CMD" | awk '{for (i=1;i<=NF;i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {print $i; exit}}')
        if [[ -n "$EXEC_PATH" && "$EXEC_PATH" != /* && "$EXEC_PATH" != ./* && "$EXEC_PATH" != ../* ]]; then
            EXEC_PATH="./$EXEC_PATH"
        fi

        if [[ -n "$EXEC_PATH" && ! -x "$EXEC_PATH" ]]; then
            echo "Error: Executable not found or not executable at $EXEC_PATH"
            exit 1
        fi

        RUN_CMD="$CMD -m \"$MODEL\""
        PRINT_CMD=""
        PRINT_LD_LIBRARY_PATH=""
        for tok in $RUN_CMD; do
            if [[ "$tok" == LD_LIBRARY_PATH=* ]]; then
                PRINT_LD_LIBRARY_PATH="${tok#LD_LIBRARY_PATH=}"
                PRINT_CMD+="LD_LIBRARY_PATH=<hidden> "
                continue
            fi
            PRINT_CMD+="$tok "
        done
        PRINT_CMD="${PRINT_CMD% }"
        {
            run_rc=0

            echo "------------------------------------------------"
            echo ">> Executing: $PRINT_CMD"
            echo ">>"
            if [[ -n "$PRINT_LD_LIBRARY_PATH" ]]; then
                echo ">> LD_LIBRARY_PATH: $PRINT_LD_LIBRARY_PATH"
                echo ">>"
            fi
            echo ">> Model: $(basename "$MODEL")"
            echo ">>"
            echo ">> Output File: $OUT_FILE"

            if [[ "$CMD" == *"ReleaseOV"* && ( "$LLAMACPP_USE_MODE" == "build" || "$LLAMACPP_USE_MODE" == "release" ) ]]; then
                (
                    . "$OV_PATH" >/dev/null 2>&1

                    eval "$RUN_CMD"
                ) || run_rc=$?
            else
                eval "$RUN_CMD" || run_rc=$?
            fi

            if [[ "$run_rc" -ne 0 ]]; then
                echo "Warning: Command failed (exit=$run_rc) for model $(basename "$MODEL"). Continuing."
            fi

            echo "------------------------------------------------"
        } 2>&1 | sed '/^load_backend:/d' | tee -a "$OUT_FILE"
    done
done
