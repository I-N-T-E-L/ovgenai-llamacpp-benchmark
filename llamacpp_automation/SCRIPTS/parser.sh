#!/bin/bash

# --- 0. Set CWD to project root ---
# Get the directory where the script is located.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Change the current working directory to the parent directory (the project root).
cd "$SCRIPT_DIR/.."

RESULTS_DIR="STORE/results"

if [[ ! -d "$RESULTS_DIR" ]]; then
	echo "Error: Results directory not found: $RESULTS_DIR"
	exit 1
fi

LATEST_TXT=$(ls -1t "$RESULTS_DIR"/*.txt 2>/dev/null | head -n 1)
if [[ -z "$LATEST_TXT" ]]; then
	echo "Error: No .txt files found in $RESULTS_DIR"
	exit 1
fi

CSV_FILE="${LATEST_TXT%.txt}.csv"
SYS_CONFIG_SCRIPT="SCRIPTS/sys_config.sh"
COMMIT_FILE="STORE/logs/llama_cpp_commit.txt"

{
	echo "# sys_config_output:"
	if [[ -f "$SYS_CONFIG_SCRIPT" ]]; then
		bash "$SYS_CONFIG_SCRIPT" | sed 's/^/# /'
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

	echo
	echo "Model,SizeValue,SizeUnit,ParamsValue,ParamsUnit,Backend,D,P,N,PP_Mean,PP_StdDev,TG_Mean,TG_StdDev"
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
	next
}

/^>> Executing:/ {
	current_frame++
	current_ov_device = ""
	if (match($0, /GGML_OPENVINO_DEVICE=[^[:space:]]+/)) {
		current_ov_device = substr($0, RSTART, RLENGTH)
		sub(/^GGML_OPENVINO_DEVICE=/, "", current_ov_device)
		gsub(/^"|"$/, "", current_ov_device)
		current_ov_device = trim(current_ov_device)
	}
	next
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

	key = current_frame SUBSEP current_model SUBSEP size_parts[1] SUBSEP size_parts[2] SUBSEP param_parts[1] SUBSEP param_parts[2] SUBSEP back SUBSEP test_d

	if (!(key in seen)) {
		seen[key] = 1
		keys[++key_count] = key
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

	for (i = 1; i <= key_count; i++) {
		key = keys[i]
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

		curr_backend_group = tolower(k[7])
		if (curr_backend_group == "cpu") {
			curr_backend_group = "bare-cpu"
		}

		if (printed_any) {
			if (curr_backend_group != prev_backend_group) {
				print ""
			}
		}

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
				  csv_escape(tstds[j])
		}

		printed_any = 1
		prev_backend_group = curr_backend_group
	}
}
' "$LATEST_TXT" >> "$CSV_FILE"

echo "CSV created: $CSV_FILE"

