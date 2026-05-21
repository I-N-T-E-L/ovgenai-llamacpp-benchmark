#!/bin/bash

set -euo pipefail

# --- 0. Set CWD to project root ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR"

RESULTS_DIR=""
CONFIG_FILE="config.yaml"

if [[ $EUID -eq 0 ]]; then
	echo "Error: Do not run this script with sudo."
	echo "Run as normal user; privileged steps will escalate with sudo when needed."
	exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "Error: Missing config file: $CONFIG_FILE"
	exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
	echo "Error: yq is required to resolve results_dir from $CONFIG_FILE"
	exit 1
fi

RESULTS_DIR=$(yq -r '.results_dir // empty' "$CONFIG_FILE")
if [[ -z "$RESULTS_DIR" ]]; then
	echo "Error: Missing results_dir in $CONFIG_FILE"
	exit 1
fi
if [[ "$RESULTS_DIR" != /* ]]; then
	RESULTS_DIR="$SCRIPT_DIR/${RESULTS_DIR#./}"
fi

run_step() {
	local script_path="$1"
	local label="$2"
	local script_arg="${3:-}"

	if [[ ! -f "$script_path" ]]; then
		echo "Error: Missing script for ${label}: $script_path"
		exit 1
	fi

	echo
	echo "=== Running: ${label} ==="
	if [[ -n "$script_arg" ]]; then
		bash "$script_path" "$script_arg"
	else
		bash "$script_path"
	fi
}

echo "Starting unified llama.cpp benchmark workflow..."
run_step "SCRIPTS/llamacpp_build.sh" "llama.cpp Install/Build (includes dependency install + OpenVINO setup)"

# Backward-compatible filename resolution for requested gguf_downloadr.sh.
if [[ -f "SCRIPTS/gguf_downloadr.sh" ]]; then
	run_step "SCRIPTS/gguf_downloadr.sh" "GGUF Downloader"
else
	run_step "SCRIPTS/gguf_downloader.sh" "GGUF Downloader"
fi

run_step "SCRIPTS/llamacpp_bench.sh" "llama.cpp Benchmark"
run_step "SCRIPTS/llamacpp_parser.sh" "Benchmark Parser"

if [[ ! -d "$RESULTS_DIR" ]]; then
	echo "Error: Results directory missing: $RESULTS_DIR"
	exit 1
fi

LLAMA_CSV=$(ls -1t "$RESULTS_DIR"/llamabench_*.csv 2>/dev/null | head -n 1)
if [[ -z "${LLAMA_CSV:-}" ]]; then
	echo "Warning: No llama CSV file found in $RESULTS_DIR after llama parser step"
fi

run_step "SCRIPTS/genai_build.sh" "GenAI Build"
run_step "SCRIPTS/ovir_downloader.sh" "OV IR Downloader"
run_step "SCRIPTS/genai_bench.sh" "GenAI Benchmark"
run_step "SCRIPTS/genai_parser.sh" "GenAI Parser"

GENAI_CSV=$(ls -1t "$RESULTS_DIR"/genaibench_*.csv 2>/dev/null | head -n 1)
if [[ -z "${GENAI_CSV:-}" ]]; then
	echo "Warning: No GenAI CSV file found in $RESULTS_DIR after GenAI parser step"
fi

RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
UNIFIED_CSV="$SCRIPT_DIR/result_${RUN_TIMESTAMP}.csv"

if [[ -n "${LLAMA_CSV:-}" ]]; then
	cp -f "$LLAMA_CSV" "$UNIFIED_CSV"
	{
		echo
		echo "# --- Base CSV: $(basename "$LLAMA_CSV") ---"
	} >> "$UNIFIED_CSV"
elif [[ -n "${GENAI_CSV:-}" ]]; then
	cp -f "$GENAI_CSV" "$UNIFIED_CSV"
	{
		echo
		echo "# --- Base CSV: $(basename "$GENAI_CSV") ---"
	} >> "$UNIFIED_CSV"
else
	echo "Error: Neither llamabench_*.csv nor genaibench_*.csv found in $RESULTS_DIR"
	exit 1
fi

if [[ -n "${LLAMA_CSV:-}" && -n "${GENAI_CSV:-}" ]]; then
	if [[ "$LLAMA_CSV" != "$GENAI_CSV" ]]; then
		{
			echo
			echo "# --- Appended GenAI CSV: $(basename "$GENAI_CSV") ---"
			cat "$GENAI_CSV"
		} >> "$UNIFIED_CSV"
	fi
elif [[ -z "${LLAMA_CSV:-}" ]]; then
	{
		echo
		echo "# --- Note: llama CSV missing; unified file contains only GenAI CSV. ---"
	} >> "$UNIFIED_CSV"
elif [[ -z "${GENAI_CSV:-}" ]]; then
	{
		echo
		echo "# --- Note: GenAI CSV missing; unified file contains only llama CSV. ---"
	} >> "$UNIFIED_CSV"
fi

echo
echo "Copied unified CSV to script directory: $UNIFIED_CSV"
echo "Workflow complete."

