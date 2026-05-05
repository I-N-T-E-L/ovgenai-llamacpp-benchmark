#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
cd "$SCRIPT_DIR/.."

CONFIG_FILE="config.txt"
OV_PATH=""
OV_DEST_FOLDER=""
OV_CURRENT_SUBSECTION=""
OV_DEFAULT_DEST=""
OV_LATEST_DEST=""
OV_HAS_DEFAULT=false
OV_HAS_LATEST=false
MODEL_FOLDER=""
declare -a COMMANDS
CMD_COUNT=0

normalize_run_command() {
    local cmd="$1"

    # Backward compatibility: older configs used llama_cpp/... paths.
    cmd=$(echo "$cmd" | sed -E 's@(^|[[:space:]])llama_cpp/@\1STORE/llama_cpp/@g')

    echo "$cmd"
}

# --- 1. Simple Parse ---
# We just need GGUF model path, OV path, and raw lines under [RUN]
SECTION=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r' | xargs) # Remove Windows junk and trim
    [[ -z "$line" ]] && continue

    # In OV_DOWNLOAD, commented subsection headers disable their block and prevent accidental carry-over.
    if [[ "$SECTION" == "OV_DOWNLOAD" && "$line" =~ ^#\s*\[(DEFAULT|LATEST)\]$ ]]; then
        OV_CURRENT_SUBSECTION=""
        continue
    fi

    [[ "$line" == "#"* ]] && continue

    if [[ "$line" =~ ^\[.*\]$ ]]; then
        HEADER="${line:1:${#line}-2}"

        # Nested subsections inside [OV_DOWNLOAD]
        if [[ "$SECTION" == "OV_DOWNLOAD" && ( "$HEADER" == "DEFAULT" || "$HEADER" == "LATEST" ) ]]; then
            OV_CURRENT_SUBSECTION="$HEADER"
            if [[ "$HEADER" == "DEFAULT" ]]; then
                OV_HAS_DEFAULT=true
            else
                OV_HAS_LATEST=true
            fi
            continue
        fi

        SECTION="$HEADER"

        # Leaving [OV_DOWNLOAD] scope resets nested OV subsection tracking.
        if [[ "$SECTION" != "OV_DOWNLOAD" ]]; then
            OV_CURRENT_SUBSECTION=""
        fi

        continue
    fi

    case "$SECTION" in
        GGUF)
            [[ "$line" == DEST_FOLDER* ]] && MODEL_FOLDER=$(echo "$line" | awk -F'=' '{print $2}' | xargs)
            ;;
        OV_DOWNLOAD)
            if [[ "$line" == DEST_FOLDER* ]]; then
                if [[ "$OV_CURRENT_SUBSECTION" == "DEFAULT" ]]; then
                    [[ -z "$OV_DEFAULT_DEST" ]] && OV_DEFAULT_DEST=$(echo "$line" | awk -F'=' '{print $2}' | xargs)
                elif [[ "$OV_CURRENT_SUBSECTION" == "LATEST" ]]; then
                    [[ -z "$OV_LATEST_DEST" ]] && OV_LATEST_DEST=$(echo "$line" | awk -F'=' '{print $2}' | xargs)
                fi
            fi
            ;;
        RUN)
            COMMANDS[$CMD_COUNT]="$(normalize_run_command "$line")"
            ((CMD_COUNT++))
            ;;
    esac
done < "$CONFIG_FILE"

if [[ -z "$MODEL_FOLDER" ]]; then
    echo "Error: GGUF DEST_FOLDER is missing in $CONFIG_FILE"
    exit 1
fi

if [[ "$OV_HAS_DEFAULT" == true && "$OV_HAS_LATEST" == true ]]; then
    echo "Error: Both [DEFAULT] and [LATEST] are active under [OV_DOWNLOAD]. Keep exactly one active subsection and comment out the other."
    exit 1
fi

if [[ "$OV_HAS_DEFAULT" == false && "$OV_HAS_LATEST" == false ]]; then
    echo "Error: Neither [DEFAULT] nor [LATEST] is active under [OV_DOWNLOAD]. Uncomment exactly one subsection."
    exit 1
fi

if [[ "$OV_HAS_LATEST" == true ]]; then
    OV_DEST_FOLDER="$OV_LATEST_DEST"
else
    OV_DEST_FOLDER="$OV_DEFAULT_DEST"
fi

if [[ -z "$OV_DEST_FOLDER" ]]; then
    echo "Error: OV DEST_FOLDER is missing in active [OV_DOWNLOAD] mode in $CONFIG_FILE"
    exit 1
fi

# --- 2. Environment Setup ---
OV_PATH="${OV_DEST_FOLDER}/setupvars.sh"

# --- 3. Execution ---
# Find all .gguf model files
MODELS=($(find "$MODEL_FOLDER" -type f -name "*.gguf"))
echo "Found ${#MODELS[@]} models in $MODEL_FOLDER"

RESULTS_DIR="STORE/results"
mkdir -p "$RESULTS_DIR"
RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUT_FILE="$RESULTS_DIR/llamabench_${RUN_TIMESTAMP}.txt"

echo "Saving all run outputs to: $OUT_FILE"

for CMD in "${COMMANDS[@]}"; do
    for MODEL in "${MODELS[@]}"; do
        EXEC_PATH=$(echo "$CMD" | awk '{for (i=1;i<=NF;i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {print $i; exit}}')
        if [[ -n "$EXEC_PATH" ]] && [[ "$EXEC_PATH" != /* ]] && [[ "$EXEC_PATH" != ./* ]] && [[ "$EXEC_PATH" != ../* ]]; then
            EXEC_PATH="./$EXEC_PATH"
        fi

        if [[ -n "$EXEC_PATH" ]] && [[ ! -x "$EXEC_PATH" ]]; then
            {
                echo "------------------------------------------------"
                echo ">> Skipping command: $CMD"
                echo ">> Reason: executable not found or not executable at $EXEC_PATH"
                echo ">> Hint: run SCRIPTS/llamacpp_install.sh or verify [RUN] paths in $CONFIG_FILE"
                echo "------------------------------------------------"
            } | tee -a "$OUT_FILE"
            continue
        fi

        RUN_CMD="$CMD -m \"$MODEL\""
        {
            echo "------------------------------------------------"
            echo ">> Executing: $RUN_CMD"
            echo ">> Model: $(basename "$MODEL")"
            echo ">> Output File: $OUT_FILE"

            if [[ "$CMD" == *"ReleaseOV"* ]] && [[ -f "$OV_PATH" ]]; then
                # Source OV inside a subshell so it never contaminates non-OV runs
                bash -c "source \"$OV_PATH\" > /dev/null 2>&1 && $RUN_CMD"
            else
                # For non-OV runs, just execute directly.
                eval "$RUN_CMD"
            fi

            echo "------------------------------------------------"
        } 2>&1 | tee -a "$OUT_FILE"
    done
done

