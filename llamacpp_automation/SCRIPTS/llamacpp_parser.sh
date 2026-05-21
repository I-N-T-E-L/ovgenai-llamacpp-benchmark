#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_ROOT"

RESULTS_DIR=""
CONFIG_FILE="config.yaml"
LLAMACPP_USE_MODE="build"
OV_RUNTIME_SOURCE="N/A"
OV_RUNTIME_VERSION="N/A"

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "Error: Missing config file: $CONFIG_FILE"
	exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
	echo "Error: yq not found."
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

if [[ ! -d "$RESULTS_DIR" ]]; then
	echo "Error: Results directory not found: $RESULTS_DIR"
	exit 1
fi

INPUT_TXT="${1:-}"

if [[ -z "$INPUT_TXT" ]]; then
	LATEST_TXT=$(ls -1t "$RESULTS_DIR"/llamabench_*.txt 2>/dev/null | head -n 1 || true)
	if [[ -z "$LATEST_TXT" ]]; then
		echo "Error: No llamabench_*.txt found in $RESULTS_DIR"
		exit 1
	fi
else
	LATEST_TXT="$INPUT_TXT"
fi

if [[ ! -f "$LATEST_TXT" ]]; then
	echo "Error: Input benchmark file not found: $LATEST_TXT"
	exit 1
fi

CSV_FILE="${LATEST_TXT%.txt}.csv"
SYS_CONFIG_SCRIPT="SCRIPTS/sys_config.sh"
COMMIT_FILE=$(yq -r '.logs_dir // empty' "$CONFIG_FILE")
if [[ -z "$COMMIT_FILE" ]]; then
	echo "Error: Missing logs_dir in $CONFIG_FILE"
	exit 1
fi

LLAMACPP_USE_MODE=$(yq -r '.llamacpp.use // "build"' "$CONFIG_FILE" | tr '[:upper:]' '[:lower:]' | xargs)
if [[ "$LLAMACPP_USE_MODE" != "build" && "$LLAMACPP_USE_MODE" != "release" ]]; then
	echo "Error: llamacpp.use must be 'build' or 'release' in $CONFIG_FILE"
	exit 1
fi

if [[ "$COMMIT_FILE" != /* ]]; then
	COMMIT_FILE="$PROJECT_ROOT/${COMMIT_FILE#./}"
fi
COMMIT_FILE="$COMMIT_FILE/llama_cpp_commit_${LLAMACPP_USE_MODE}.txt"

extract_semver_from_text() {
	local text="$1"
	echo "$text" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

resolve_parser_ov_runtime_details() {
	local build_dir=""
	local ov_dir=""
	local version_line=""
	local parsed_semver=""

	if [[ "$LLAMACPP_USE_MODE" == "build" ]]; then
		ov_dir=$(yq -r '.llamacpp_ov_dir // empty' "$CONFIG_FILE")
		if [[ -n "$ov_dir" ]]; then
			if [[ "$ov_dir" != /* ]]; then
				ov_dir="$PROJECT_ROOT/${ov_dir#./}"
			fi
			OV_RUNTIME_SOURCE="$ov_dir/runtime/version.txt"
		fi
	else
		# In release mode, parser intentionally skips OpenVINO version discovery/printing.
		OV_RUNTIME_SOURCE="N/A"
		OV_RUNTIME_VERSION="N/A"
		return
	fi

	if [[ -n "$OV_RUNTIME_SOURCE" && "$OV_RUNTIME_SOURCE" != "N/A" && -f "$OV_RUNTIME_SOURCE" ]]; then
		version_line=$(head -n 1 "$OV_RUNTIME_SOURCE" 2>/dev/null | xargs || true)
		parsed_semver=$(extract_semver_from_text "$version_line")
		if [[ -n "$parsed_semver" ]]; then
			OV_RUNTIME_VERSION="$parsed_semver"
		elif [[ -n "$version_line" ]]; then
			OV_RUNTIME_VERSION="$version_line"
		fi
	fi
}

resolve_parser_ov_runtime_details

build_missing_gguf_report() {
	local gguf_root=""
	local normalized_root=""
	local quant=""
	local model_entry=""
	local file_name=""
	local expected_path=""
	local configured_count=0
	local missing_count=0
	local -a quant_items=()
	local -a configured_models=()
	local -a missing_items=()
	declare -A seen_expected=()

	echo "#"
	echo "# === GGUF MODEL PRESENCE CHECK ==="

	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo "# [Missing config: $CONFIG_FILE]"
		return
	fi

	if ! command -v yq >/dev/null 2>&1; then
		echo "# [yq not found; skipping GGUF model presence check]"
		return
	fi

	gguf_root=$(yq -r '.gguf_dir // empty' "$CONFIG_FILE")
	if [[ -z "$gguf_root" ]]; then
		echo "# [Missing gguf_dir in $CONFIG_FILE]"
		return
	fi

	if [[ "$gguf_root" != /* ]]; then
		normalized_root="$PROJECT_ROOT/${gguf_root#./}"
	else
		normalized_root="$gguf_root"
	fi

	mapfile -t quant_items < <(yq -r '.llamacpp.quantizations[]?' "$CONFIG_FILE")
	if [[ ${#quant_items[@]} -eq 0 ]]; then
		echo "# [No llamacpp.quantizations entries found]"
		return
	fi

	for quant in "${quant_items[@]}"; do
		quant=$(echo "$quant" | xargs)
		[[ -z "$quant" ]] && continue

		mapfile -t configured_models < <(yq -r --arg q "$quant" '.gguf_models[$q][]? // empty' "$CONFIG_FILE")
		for model_entry in "${configured_models[@]}"; do
			model_entry=$(echo "$model_entry" | xargs)
			[[ -z "$model_entry" ]] && continue

			if [[ "$model_entry" == http*://* ]]; then
				file_name="${model_entry##*/}"
				file_name="${file_name%%\?*}"
			elif [[ "$model_entry" == /* ]]; then
				expected_path="$model_entry"
				if [[ -n "${seen_expected[$expected_path]:-}" ]]; then
					continue
				fi
				seen_expected[$expected_path]=1
				((configured_count++))

				if [[ ! -f "$expected_path" ]]; then
					missing_items+=("$expected_path")
					((missing_count++))
				fi
				continue
			else
				file_name="${model_entry##*/}"
			fi

			[[ -z "$file_name" ]] && continue

			expected_path="$normalized_root/$quant/$file_name"
			if [[ -n "${seen_expected[$expected_path]:-}" ]]; then
				continue
			fi
			seen_expected[$expected_path]=1
			((configured_count++))

			if [[ ! -f "$expected_path" ]]; then
				missing_items+=("$quant/$file_name")
				((missing_count++))
			fi
		done
	done

	echo "# gguf_root: $normalized_root"
	echo "# configured_models: $configured_count"
	echo "# missing_models: $missing_count"

	if [[ $missing_count -eq 0 ]]; then
		echo "# missing_model: NONE"
	else
		for expected_path in "${missing_items[@]}"; do
			echo "# missing_model: $expected_path"
		done
	fi
}

{
	echo "# sys_config_output:"
	if [[ -f "$SYS_CONFIG_SCRIPT" ]]; then
		bash "$SYS_CONFIG_SCRIPT" \
			| awk '
				BEGIN { skip_ov_block = 0 }
				/^=== OPENVINO DETAILS ===$/ { skip_ov_block = 1; next }
				skip_ov_block {
					if ($0 ~ /^$/) {
						skip_ov_block = 0
					}
					next
				}
				{ print }
			' \
			| sed 's/^/# /'
	else
		echo "# [Missing script: $SYS_CONFIG_SCRIPT]"
	fi

	echo "#"
	echo "# === LLAMA_CPP LATEST COMMIT HASH & COMMENT ==="
	if [[ -f "$COMMIT_FILE" ]]; then
		echo "# $(head -n 1 "$COMMIT_FILE")"
	else
		echo "# N/A"
	fi

	if [[ "$LLAMACPP_USE_MODE" == "build" ]]; then
		echo "#"
		echo "# === OPENVINO VERSION ==="
		echo "# mode: $LLAMACPP_USE_MODE"
		echo "# source: $OV_RUNTIME_SOURCE"
		echo "# version: $OV_RUNTIME_VERSION"
	fi

	build_missing_gguf_report

	echo
	echo "Model,SizeValue,SizeUnit,ParamsValue,ParamsUnit,Backend,D,P,N,PP_Mean,PP_StdDev,TG_Mean,TG_StdDev,Error"
} > "$CSV_FILE"

awk '
function trim(s) {
	gsub(/^[ \t]+|[ \t]+$/, "", s)
	return s
}

function csv_escape(s) {
	gsub(/"/, "\"\"", s)
	return "\"" s "\""
}

function split_value_unit(src, out_arr, n) {
	src = trim(src)
	n = split(src, out_arr, /[[:space:]]+/)
	if (n < 2) {
		out_arr[1] = src
		out_arr[2] = ""
	}
}

function split_tps(src, out_arr, n) {
	src = trim(src)
	n = split(src, out_arr, /[[:space:]]*±[[:space:]]*/)
	if (n < 2) {
		out_arr[1] = src
		out_arr[2] = ""
	}
}

function get_col(cols, idx, fallback) {
	if (idx > 0) {
		return trim(cols[idx])
	}
	return fallback
}

function sort_triplet(vals, means, stds, n, i, j, tmp) {
	for (i = 1; i <= n; i++) {
		for (j = i + 1; j <= n; j++) {
			if ((vals[i] + 0) > (vals[j] + 0)) {
				tmp = vals[i]; vals[i] = vals[j]; vals[j] = tmp
				tmp = means[i]; means[i] = means[j]; means[j] = tmp
				tmp = stds[i]; stds[i] = stds[j]; stds[j] = tmp
			}
		}
	}
}

function append_frame_note(frame_id, note_line) {
	note_line = trim(note_line)
	if (note_line == "") {
		return
	}

	if (frame_note[frame_id] == "") {
		frame_note[frame_id] = note_line
	} else {
		frame_note[frame_id] = frame_note[frame_id] " | " note_line
	}
}

function parse_test_fields(test_src, kind_out, val_out, d_out, t, m) {
	t = trim(tolower(test_src))
	kind_out = ""
	val_out = ""
	d_out = "0"

	if (match(t, /^(pp|tg)[0-9]+/)) {
		m = substr(t, RSTART, RLENGTH)
		if (substr(m, 1, 2) == "pp") {
			kind_out = "pp"
			val_out = substr(m, 3)
		} else if (substr(m, 1, 2) == "tg") {
			kind_out = "tg"
			val_out = substr(m, 3)
		}
	}

	if (match(t, /@[[:space:]]*d[0-9]+/)) {
		m = substr(t, RSTART, RLENGTH)
		gsub(/^[^0-9]*/, "", m)
		d_out = m
	}

	test_kind = kind_out
	test_val = val_out
	test_d = d_out
}

/^>> Model:/ {
	current_model = $0
	sub(/^>> Model:[[:space:]]*/, "", current_model)
	current_model = trim(current_model)
	sub(/\.gguf$/, "", current_model)
	if (current_frame > 0) {
		frame_model[current_frame] = current_model
	}
	next
}

/^>> Executing:/ {
	current_frame++
	current_ov_device = ""
	capture_frame_notes = 0
	frame_has_metrics[current_frame] = 0
	frame_model[current_frame] = ""
	frame_backend[current_frame] = ""
	frame_note[current_frame] = ""
	if (current_frame > max_frame) {
		max_frame = current_frame
	}

	# Classify backend by executable path first. Runtime env vars may still contain
	# GGML_OPENVINO_DEVICE for non-OV runs (e.g. Vulkan/CPU), which should not
	# change backend labeling.
	if ($0 ~ /ReleaseVulkan/) {
		frame_backend[current_frame] = "Vulkan"
	} else if ($0 ~ /ReleaseOV/) {
		if (match($0, /GGML_OPENVINO_DEVICE=[^[:space:]]+/)) {
			current_ov_device = substr($0, RSTART, RLENGTH)
			sub(/^GGML_OPENVINO_DEVICE=/, "", current_ov_device)
			gsub(/^"|"$/, "", current_ov_device)
			current_ov_device = trim(current_ov_device)
			frame_backend[current_frame] = "OV-" current_ov_device
		} else {
			frame_backend[current_frame] = "OPENVINO"
		}
	} else if ($0 ~ /Release\//) {
		frame_backend[current_frame] = "BARE-CPU"
	}
	next
}

/^OpenVINO:[[:space:]]*using device/ {
	if (current_frame > 0) {
		capture_frame_notes = 1
	}
	next
}

/^[[:space:]]*\|[[:space:]]*model/ {
	capture_frame_notes = 0
}

{
	if (capture_frame_notes && current_frame > 0) {
		if ($0 !~ /^[[:space:]]*\|/ && $0 !~ /^-+$/) {
			append_frame_note(current_frame, $0)
		}
	}
}

/^[[:space:]]*\|/ {
	ncols = split($0, cols, "|")
	if (ncols < 4) {
		next
	}

	# Detect and map header columns dynamically so extra columns (e.g., fa, ngl, threads) are ignored.
	head_first = tolower(trim(cols[2]))
	if (head_first == "model") {
		idx_model = idx_size = idx_params = idx_backend = idx_test = idx_tps = 0
		for (i = 2; i <= ncols - 1; i++) {
			col_name = tolower(trim(cols[i]))
			if (col_name == "model") idx_model = i
			else if (col_name == "size") idx_size = i
			else if (col_name == "params") idx_params = i
			else if (col_name == "backend") idx_backend = i
			else if (col_name == "test") idx_test = i
			else if (col_name == "t/s") idx_tps = i
		}
		next
	}

	# Skip separator rows like | ----- |
	if (trim(cols[2]) ~ /^-+$/) {
		next
	}

	table_model = get_col(cols, idx_model, trim(cols[2]))
	size       = get_col(cols, idx_size, trim(cols[3]))
	params     = get_col(cols, idx_params, trim(cols[4]))
	back       = get_col(cols, idx_backend, trim(cols[5]))
	test       = get_col(cols, idx_test, trim(cols[7]))
	tps        = get_col(cols, idx_tps, trim(cols[8]))

	if (toupper(back) == "OPENVINO" && current_ov_device != "") {
		back = "OV-" current_ov_device
	} else if (toupper(back) == "CPU") {
		back = "BARE-CPU"
	}

	# Skip invalid rows
	if (table_model == "" || tolower(table_model) == "model") {
		next
	}
	if (table_model ~ /^-+$/ || size ~ /^-+$/) {
		next
	}

	if (current_model == "") {
		current_model = table_model
	}

	split_value_unit(size, size_parts)
	split_value_unit(params, param_parts)
	split_tps(tps, tps_parts)
	parse_test_fields(test, kind_tmp, val_tmp, d_tmp)

	if (test_kind == "") {
		next
	}

	if (current_frame == 0) {
		current_frame = 1
	}
	frame_has_metrics[current_frame] = 1
	if (frame_model[current_frame] == "") {
		frame_model[current_frame] = current_model
	}

	key = current_frame SUBSEP current_model SUBSEP size_parts[1] SUBSEP size_parts[2] SUBSEP param_parts[1] SUBSEP param_parts[2] SUBSEP back SUBSEP test_d

	if (!(key in seen)) {
		seen[key] = 1
		keys[++key_count] = key
		if (frame_keys[current_frame] == "") {
			frame_keys[current_frame] = key
		} else {
			frame_keys[current_frame] = frame_keys[current_frame] "\n" key
		}
	}

	if (test_kind == "pp") {
		pp_idx = ++pp_count[key]
		pp_val[key, pp_idx] = test_val
		pp_mean[key, pp_idx] = tps_parts[1]
		pp_std[key, pp_idx] = tps_parts[2]
	} else if (test_kind == "tg") {
		tg_idx = ++tg_count[key]
		tg_val[key, tg_idx] = test_val
		tg_mean[key, tg_idx] = tps_parts[1]
		tg_std[key, tg_idx] = tps_parts[2]
	}
}

END {
	printed_any = 0
	prev_backend_group = ""

	for (frame_id = 1; frame_id <= max_frame; frame_id++) {
		curr_backend_group = tolower(frame_backend[frame_id])
		if (curr_backend_group == "cpu") {
			curr_backend_group = "bare-cpu"
		}

		if (printed_any && curr_backend_group != "" && curr_backend_group != prev_backend_group) {
			print ""
		}

		if ((frame_has_metrics[frame_id] + 0) > 0 && frame_keys[frame_id] != "") {
			n = split(frame_keys[frame_id], frame_key_list, "\n")
			for (i = 1; i <= n; i++) {
				key = frame_key_list[i]
				split(key, k, SUBSEP)

				pc = pp_count[key] + 0
				tc = tg_count[key] + 0
				pair_n = (pc < tc ? pc : tc)

				if (pair_n <= 0) {
					continue
				}

				delete pvals
				delete pmeans
				delete pstds
				delete tvals
				delete tmeans
				delete tstds

				for (j = 1; j <= pc; j++) {
					pvals[j] = pp_val[key, j]
					pmeans[j] = pp_mean[key, j]
					pstds[j] = pp_std[key, j]
				}
				for (j = 1; j <= tc; j++) {
					tvals[j] = tg_val[key, j]
					tmeans[j] = tg_mean[key, j]
					tstds[j] = tg_std[key, j]
				}

				sort_triplet(pvals, pmeans, pstds, pc)
				sort_triplet(tvals, tmeans, tstds, tc)

				for (j = 1; j <= pair_n; j++) {
					print csv_escape(k[2]) "," \
						  csv_escape(k[3]) "," \
						  csv_escape(k[4]) "," \
						  csv_escape(k[5]) "," \
						  csv_escape(k[6]) "," \
						  csv_escape(k[7]) "," \
						  csv_escape(k[8]) "," \
						  csv_escape(pvals[j]) "," \
						  csv_escape(tvals[j]) "," \
						  csv_escape(pmeans[j]) "," \
						  csv_escape(pstds[j]) "," \
						  csv_escape(tmeans[j]) "," \
						  csv_escape(tstds[j]) "," \
						  csv_escape("")
				}
			}

			printed_any = 1
			if (curr_backend_group != "") {
				prev_backend_group = curr_backend_group
			}
			continue
		}

		# Preserve frames that produced no benchmark metric rows.
		fallback_model = frame_model[frame_id]
		if (fallback_model == "") {
			fallback_model = "UNKNOWN_MODEL"
		}

		print csv_escape(fallback_model) "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape(frame_backend[frame_id]) "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape("") "," \
			  csv_escape(frame_note[frame_id])

		printed_any = 1
		if (curr_backend_group != "") {
			prev_backend_group = curr_backend_group
		}
	}
}
' "$LATEST_TXT" >> "$CSV_FILE"

echo "CSV created: $CSV_FILE"
