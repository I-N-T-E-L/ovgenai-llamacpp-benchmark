#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
cd "$SCRIPT_DIR/.."

CONFIG_FILE="config.txt"
KEYWORD="\[HF_DOWNLOAD\]"
IN_SECTION=false
DEST_PATH=""

if ! command -v hf &>/dev/null; then
    echo "hf not found. Installing huggingface_hub..."
    INSTALL_SUCCESS=false
    PIP_CMD=""

    if command -v pip &>/dev/null; then
        PIP_CMD="pip"
    elif command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"
    fi

    # Attempt 1: pip --user (safe, no system modification)
    if [[ -n "$PIP_CMD" ]]; then
        echo "Trying: $PIP_CMD install --user huggingface_hub..."
        $PIP_CMD install -q --user huggingface_hub && INSTALL_SUCCESS=true
    fi

    # Attempt 2: pipx (designed for CLI tools, manages its own venv)
    if [[ "$INSTALL_SUCCESS" == false ]]; then
        if command -v pipx &>/dev/null; then
            echo "Trying: pipx install huggingface_hub..."
            pipx install huggingface_hub && INSTALL_SUCCESS=true
        fi
    fi

    # Attempt 3: --break-system-packages (last resort)
    if [[ "$INSTALL_SUCCESS" == false ]]; then
        if [[ -n "$PIP_CMD" ]]; then
            echo "Trying: $PIP_CMD install --break-system-packages huggingface_hub..."
            $PIP_CMD install -q --break-system-packages huggingface_hub && INSTALL_SUCCESS=true
        fi
    fi

    if [[ "$INSTALL_SUCCESS" == false ]]; then
        echo "Error: Failed to install huggingface_hub. Please install it manually (e.g. pipx install huggingface_hub)."
        exit 1
    fi

    # Refresh PATH to pick up binaries installed to ~/.local/bin
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v hf &>/dev/null; then
        echo "Error: hf still not found after install. Ensure ~/.local/bin is in your PATH."
        exit 1
    fi
    echo "huggingface_hub installed successfully."
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found."
    exit 1
fi

echo "Scanning $CONFIG_FILE for section [HF_DOWNLOAD]..."

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $KEYWORD ]]; then
        IN_SECTION=true
        continue
    fi

    if [[ "$IN_SECTION" == true && "$line" =~ ^\[.*\]$ ]]; then
        IN_SECTION=false
        break
    fi

    if [[ "$IN_SECTION" == true ]]; then
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        # Skip comment lines
        [[ "$line" == \#* ]] && continue

        if [[ "$line" == DEST_FOLDER=* ]]; then
            DEST_PATH="${line#*=}"
            DEST_PATH="${DEST_PATH#./}"
            if [[ "$DEST_PATH" != /* && "$DEST_PATH" != STORE/* ]]; then
                DEST_PATH="STORE/$DEST_PATH"
            fi

            if [[ -n "$DEST_PATH" ]]; then
                if [[ ! -d "$DEST_PATH" ]]; then
                    echo "Directory missing. Creating: $DEST_PATH"
                    mkdir -p "$DEST_PATH"
                fi
                echo "Target Directory set to: $DEST_PATH"
            fi

        elif [[ "$line" == hf\ download* ]]; then
            if [[ -z "$DEST_PATH" ]]; then
                echo "Error: No DEST_FOLDER found in config. Skipping: $line"
                continue
            fi

            MODEL="${line#hf download }"
            MODEL_DIR="$DEST_PATH/${MODEL//\//__}"

            if [[ -d "$MODEL_DIR" ]]; then
                echo "Skipping: $MODEL already exists in $DEST_PATH"
            else
                echo "Downloading: $MODEL -> $DEST_PATH"
                HF_HUB_CACHE="$DEST_PATH" hf download "$MODEL"
            fi
        fi
    fi
done < "$CONFIG_FILE"

echo "Process complete."


