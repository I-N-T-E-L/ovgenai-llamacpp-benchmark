#!/bin/bash

CONFIG_FILE="config.txt"
KEYWORD="\[DOWNLOAD\]" 
IN_SECTION=false              
DEST_PATH=""

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found."
    exit 1
fi

echo "Scanning $CONFIG_FILE for section $KEYWORD..."

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

        # Logic to capture and create the destination folder
        if [[ "$line" == DEST_FOLDER=* ]]; then
            DEST_PATH="${line#*=}"
            
            if [[ -n "$DEST_PATH" ]]; then
                # Create the folder if it doesn't exist
                if [[ ! -d "$DEST_PATH" ]]; then
                    echo "Directory missing. Creating: $DEST_PATH"
                    mkdir -p "$DEST_PATH"
                fi
                echo "Target Directory set to: $DEST_PATH"
            fi
        
        elif [[ "$line" == http* ]]; then
            # STRICT CHECK: If DEST_PATH is still empty, skip the download
            if [[ -z "$DEST_PATH" ]]; then
                echo "Error: No DEST_FOLDER found in config. Skipping download: $line"
                continue
            fi
            
            FILE_NAME="${line##*/}"
            
            if [[ -f "$DEST_PATH/$FILE_NAME" ]]; then
                echo "Skipping: $FILE_NAME already exists in $DEST_PATH"
            else
                echo "Downloading: $line"
                wget -q --show-progress -P "$DEST_PATH" "$line"
            fi
        fi
    fi
done < "$CONFIG_FILE"

echo "Process complete."
