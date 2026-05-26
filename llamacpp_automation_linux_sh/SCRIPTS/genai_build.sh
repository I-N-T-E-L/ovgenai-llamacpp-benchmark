#!/usr/bin/env bash

set -euo pipefail

REPO_URL="https://github.com/openvinotoolkit/openvino.genai.git"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_FILE="$PROJECT_ROOT/config.yaml"
BUILD_DIR=""
REPO_DIR=""
LLM_BENCH_DIR="tools/llm_bench"
VENV_DIR="python-env"

log() {
	printf "\n[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Error: required command '$1' is not installed or not in PATH."
		exit 1
	fi
}

apply_optional_proxy_from_config() {
	local use_proxy=""
	local proxy_line=""
	local proxy_var=""
	local proxy_val=""

	if [[ ! -f "$CONFIG_FILE" ]] || ! command -v yq >/dev/null 2>&1; then
		return
	fi

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

	log "Applied proxy settings from $CONFIG_FILE"
}

log "Checking required commands"
require_command git
require_command python3
require_command yq

apply_optional_proxy_from_config

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "Error: Missing config file at $CONFIG_FILE"
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

REPO_DIR="$BUILD_DIR/openvino.genai"
mkdir -p "$BUILD_DIR"

if [ -d "$REPO_DIR" ] && [ ! -d "$REPO_DIR/$LLM_BENCH_DIR" ]; then
	log "Existing repository layout is invalid at '$REPO_DIR' (missing '$LLM_BENCH_DIR')"
	log "Deleting '$REPO_DIR' and recloning from scratch"
	rm -rf "$REPO_DIR"
fi

if [ ! -d "$REPO_DIR" ]; then
	log "Cloning repository: $REPO_URL"
	git clone "$REPO_URL" "$REPO_DIR"
else
	log "Repository already exists at '$REPO_DIR', skipping clone"
fi

cd "$REPO_DIR/$LLM_BENCH_DIR"
log "Working directory: $(pwd)"

export GIT_CLONE_PROTECTION_ACTIVE=false
log "Set GIT_CLONE_PROTECTION_ACTIVE=false"

if [ ! -d "$VENV_DIR" ]; then
	log "Creating Python virtual environment"
	python3 -m venv "$VENV_DIR"
else
	log "Virtual environment already exists at '$VENV_DIR'"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
log "Activated virtual environment"

log "Upgrading pip"
python -m pip install --upgrade pip

log "Installing requirements"
pip install -r requirements.txt

log "Installing pinned transformers version"
pip install transformers==4.55.4

# Keep diffusers aligned with the pinned transformers release.
# Newer diffusers builds can require transformer symbols not present in 4.55.4.
log "Installing compatible diffusers version"
pip install "diffusers<0.35"

log "Done. Environment setup completed (no model download/quantization run)."