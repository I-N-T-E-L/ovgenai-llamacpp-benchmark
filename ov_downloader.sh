#!/bin/bash

CONFIG_FILE="config.txt"
KEYWORD="\[OV_DOWNLOAD\]" 
IN_SECTION=false              
DEST_PATH=""

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

    if [[ "$line" =~ $KEYWORD ]]; then
        IN_SECTION=true
        continue
    fi

    if [[ "$IN_SECTION" == true && "$line" =~ ^\[.*\]$ ]]; then
        IN_SECTION=false
        break 
    fi

    if [[ "$IN_SECTION" == true ]]; then
        [[ -z "$line" || "$line" == "#"* ]] && continue

        if [[ "$line" == DEST_FOLDER=* ]]; then
            DEST_PATH="${line#*=}"
            echo "Target Directory: $DEST_PATH"
        
        elif [[ "$line" == http* ]]; then
            if [[ -z "$DEST_PATH" ]]; then
                echo "Error: DEST_FOLDER not defined. Skipping: $line"
                continue
            fi

            # 2. Setup Temporary Workspace
            TMP_FILE="ov_pkg.tgz"
            EXTRACT_DIR="ov_temp_extract"
            mkdir -p "$EXTRACT_DIR"

            # 3. Download
            echo "------------------------------------------------"
            echo "Downloading: $line"
            curl -L "$line" --output "$TMP_FILE"

            # 4. Expand
            echo "Extracting archive..."
            tar -xf "$TMP_FILE" -C "$EXTRACT_DIR"

            # 5. Replacement Logic (The "Overwrite" Feature)
            # Find the actual folder name inside the extracted content
            EXTRACTED_FOLDER_NAME=$(ls "$EXTRACT_DIR" | head -n 1)

            if [[ -d "$DEST_PATH" ]]; then
                echo "Path $DEST_PATH already exists. Replacing files..."
                rm -rf "$DEST_PATH"
            fi

            echo "Installing to: $DEST_PATH"
            mkdir -p "$(dirname "$DEST_PATH")"
            mv "$EXTRACT_DIR/$EXTRACTED_FOLDER_NAME" "$DEST_PATH"

            # 6. Cleanup
            rm -rf "$EXTRACT_DIR" "$TMP_FILE"
            echo "Installation complete."
        fi
    fi
done < "$CONFIG_FILE"

echo "------------------------------------------------"
echo "Process finished."
