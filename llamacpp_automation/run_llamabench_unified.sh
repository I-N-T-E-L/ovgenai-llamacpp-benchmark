#!/bin/bash

set -euo pipefail

# --- 0. Set CWD to project root ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR"

RESULTS_DIR="STORE/results"

if [[ $EUID -eq 0 ]]; then
	echo "Error: Do not run this script with sudo."
	echo "Run as normal user; only the OpenVINO step will escalate privileges."
	exit 1
fi

run_step() {
	local script_path="$1"
	local label="$2"

	if [[ ! -f "$script_path" ]]; then
		echo "Error: Missing script for ${label}: $script_path"
		exit 1
	fi

	echo
	echo "=== Running: ${label} ==="
	bash "$script_path"
}

run_step_with_sudo() {
	local script_path="$1"
	local label="$2"

	if [[ ! -f "$script_path" ]]; then
		echo "Error: Missing script for ${label}: $script_path"
		exit 1
	fi

	echo
	echo "=== Running: ${label} (sudo) ==="
	sudo bash "$script_path"
}

echo "Starting unified llama.cpp benchmark workflow..."

run_step_with_sudo "SCRIPTS/ov_downloader.sh" "OpenVINO Downloader"
run_step "SCRIPTS/llamacpp_install.sh" "llama.cpp Install/Build"

# Backward-compatible filename resolution for requested gguf_downloadr.sh.
if [[ -f "SCRIPTS/gguf_downloadr.sh" ]]; then
	run_step "SCRIPTS/gguf_downloadr.sh" "GGUF Downloader"
else
	run_step "SCRIPTS/gguf_downloader.sh" "GGUF Downloader"
fi

run_step "SCRIPTS/llamacpp_bench.sh" "llama.cpp Benchmark"
run_step "SCRIPTS/parser.sh" "Benchmark Parser"

if [[ ! -d "$RESULTS_DIR" ]]; then
	echo "Error: Results directory missing: $RESULTS_DIR"
	exit 1
fi

LATEST_CSV=$(ls -1t "$RESULTS_DIR"/*.csv 2>/dev/null | head -n 1)
if [[ -z "${LATEST_CSV:-}" ]]; then
	echo "Error: No CSV file found in $RESULTS_DIR after parser step"
	exit 1
fi

cp -f "$LATEST_CSV" "$SCRIPT_DIR/"
echo
echo "Copied CSV to working directory: $SCRIPT_DIR/$(basename "$LATEST_CSV")"
echo "Workflow complete."

