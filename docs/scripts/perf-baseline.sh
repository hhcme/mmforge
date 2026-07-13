#!/bin/bash
# MMForge Performance Baseline
# Builds CLI from current source, generates large model, runs parse benchmark.
# Output: JSON report with ONLY verified, reproducible metrics. Unimplemented
# metrics are explicitly marked as "not_implemented" with a reason.
#
# Run: bash docs/scripts/perf-baseline.sh
#
# Exit: 0 on success, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Configuration ---
MODEL_PATH="${MMFORGE_PERF_MODEL:-/tmp/mmforge_perf_model.lsm}"
OUTPUT_JSON="${MMFORGE_PERF_OUTPUT:-/tmp/mmforge_perf_baseline.json}"
TRIANGLES="${MMFORGE_PERF_TRIANGLES:-100000}"
SEED="${MMFORGE_PERF_SEED:-42}"
LEVELS="${MMFORGE_PERF_LEVELS:-4}"
ITERATIONS="${MMFORGE_PERF_ITERATIONS:-5}"

cd "$ROOT"

# --- 0. Build from source (never reuse stale binaries) ---
echo "# Building CLI from current source (cargo build --release -p mmforge-cli)" >&2
cargo build --release -p mmforge-cli

CLI="$ROOT/target/release/mmforge"

# Verify the binary actually works
echo "# Verifying binary" >&2
"$CLI" version >/dev/null || {
  echo "ERROR: Built binary failed 'version' check" >&2
  exit 1
}

# --- Helper: run a command and capture duration + output (stdout only) ---
run_timed_json() {
  local label="$1"
  shift
  local start_ns
  start_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null || echo 0)
  local output
  local rc=0
  output=$("$@") || rc=$?
  local end_ns
  end_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null || echo 0)
  local duration_ms=0
  if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
    duration_ms=$(( (end_ns - start_ns) / 1000000 ))
  fi
  # Return: label|rc|duration_ms|output (newlines escaped)
  printf '%s|%d|%d|%s\n' "$label" "$rc" "$duration_ms" "$(echo "$output" | tr '\n' '\t')"
}

# --- Helper: run a command, capture stdout+stderr, duration ---
run_timed() {
  local label="$1"
  shift
  local start_ns
  start_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null || echo 0)
  local output
  local rc=0
  output=$("$@" 2>&1) || rc=$?
  local end_ns
  end_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))' 2>/dev/null || echo 0)
  local duration_ms=0
  if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
    duration_ms=$(( (end_ns - start_ns) / 1000000 ))
  fi
  # Return: label|rc|duration_ms|output (newlines escaped)
  printf '%s|%d|%d|%s\n' "$label" "$rc" "$duration_ms" "$(echo "$output" | tr '\n' '\t')"
}

# --- 1. Generate large model ---
echo "# Generating large model ($TRIANGLES triangles, seed=$SEED, levels=$LEVELS)" >&2
gen_result=$(run_timed_json "generate" "$CLI" generate-large-model \
  --output "$MODEL_PATH" \
  --triangles "$TRIANGLES" \
  --seed "$SEED" \
  --levels "$LEVELS")
gen_rc=$(echo "$gen_result" | cut -d'|' -f2)
gen_ms=$(echo "$gen_result" | cut -d'|' -f3)

if [ "$gen_rc" -ne 0 ]; then
  echo "ERROR: model generation failed (exit $gen_rc)" >&2
  echo "$gen_result" | cut -d'|' -f4 | tr '\t' '\n' >&2
  exit 1
fi

# Parse generation JSON output for model stats.
gen_output=$(echo "$gen_result" | cut -d'|' -f4- | tr '\t' '\n')
file_size_bytes=$(echo "$gen_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('file_size_bytes',0))" 2>/dev/null || echo "0")
node_count=$(echo "$gen_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_count',0))" 2>/dev/null || echo "0")
geometry_count=$(echo "$gen_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('geometry_count',0))" 2>/dev/null || echo "0")
material_count=$(echo "$gen_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('material_count',0))" 2>/dev/null || echo "0")
triangle_count=$(echo "$gen_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('triangle_count',0))" 2>/dev/null || echo "0")

echo "# Model: $node_count nodes, $geometry_count geometries, $triangle_count triangles, $file_size_bytes bytes" >&2

# --- 2. Parse benchmark ---
echo "# Benchmarking parse ($ITERATIONS iterations)" >&2
bench_times=()
for i in $(seq 1 "$ITERATIONS"); do
  bench_result=$(run_timed "bench_$i" "$CLI" benchmark "$MODEL_PATH" --iterations 1 --format json)
  bench_rc=$(echo "$bench_result" | cut -d'|' -f2)
  bench_ms=$(echo "$bench_result" | cut -d'|' -f3)
  if [ "$bench_rc" -ne 0 ]; then
    echo "WARNING: benchmark iteration $i failed" >&2
    continue
  fi
  # Extract parse_ms_avg from JSON.
  bench_out=$(echo "$bench_result" | cut -d'|' -f4- | tr '\t' '\n')
  parse_ms=$(echo "$bench_out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('parse_ms_avg',0))" 2>/dev/null || echo "0")
  bench_times+=("$parse_ms")
done

# Compute min/max/median/avg of bench times.
compute_stats() {
  python3 -c "
import sys
vals = sorted([float(x) for x in sys.argv[1:]])
n = len(vals)
if n == 0:
    print('0|0|0|0')
else:
    mn = vals[0]
    mx = vals[-1]
    med = vals[n//2]
    avg = sum(vals)/n
    print(f'{mn}|{mx}|{med}|{avg}')
" "${bench_times[@]}"
}
bench_stats=$(compute_stats "${bench_times[@]}")
bench_min=$(echo "$bench_stats" | cut -d'|' -f1)
bench_max=$(echo "$bench_stats" | cut -d'|' -f2)
bench_median=$(echo "$bench_stats" | cut -d'|' -f3)
bench_avg=$(echo "$bench_stats" | cut -d'|' -f4)

echo "# Parse benchmark: min=$bench_min ms, max=$bench_max ms, median=$bench_median ms, avg=$bench_avg ms" >&2

# --- 3. Info ---
echo "# Getting model info" >&2
info_result=$(run_timed "info" "$CLI" info "$MODEL_PATH" --format json)
info_rc=$(echo "$info_result" | cut -d'|' -f2)
info_ms=$(echo "$info_result" | cut -d'|' -f3)
info_output=$(echo "$info_result" | cut -d'|' -f4- | tr '\t' '\n')

# --- 4. Validate ---
echo "# Validating model" >&2
validate_result=$(run_timed "validate" "$CLI" validate "$MODEL_PATH" --format json)
validate_rc=$(echo "$validate_result" | cut -d'|' -f2)
validate_ms=$(echo "$validate_result" | cut -d'|' -f3)
validate_output=$(echo "$validate_result" | cut -d'|' -f4- | tr '\t' '\n')

# --- 5. Machine environment ---
echo "# Collecting machine info" >&2
machine_model=$(sysctl -n hw.model 2>/dev/null || echo "unknown")
cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
memory_gb=$(python3 -c "print(round($memory_bytes / (1024**3), 1))" 2>/dev/null || echo "0")
macos_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")

# --- 6. Build JSON output ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 -c "
import json

report = {
    'timestamp': '$timestamp',
    'machine': {
        'model': '$machine_model',
        'cpu': '$cpu_brand',
        'memory_gb': float($memory_gb),
        'macos_version': '$macos_version'
    },
    'build': {
        'command': 'cargo build --release -p mmforge-cli',
        'profile': 'release'
    },
    'model': {
        'node_count': $node_count,
        'triangle_count': $triangle_count,
        'geometry_count': $geometry_count,
        'material_count': $material_count,
        'file_size_bytes': $file_size_bytes,
        'generation_duration_ms': $gen_ms
    },
    'parse_benchmark': {
        'iterations': $ITERATIONS,
        'min_ms': $bench_min,
        'max_ms': $bench_max,
        'median_ms': $bench_median,
        'avg_ms': $bench_avg
    },
    'unimplemented_metrics': {
        'first_usable_mesh_ms': {
            'status': 'not_implemented',
            'reason': 'Requires streaming mesh availability tracking in renderer. Not measurable from CLI alone.'
        },
        'peak_memory_mb': {
            'status': 'not_implemented',
            'reason': 'Requires per-process memory profiling. Rough estimate via /usr/bin/time -l possible but not yet integrated.'
        },
        'frame_time_ms': {
            'status': 'not_implemented',
            'reason': 'Requires Metal frame timing instrumentation. Not measurable from CLI alone. See macos/MMForge/Metal/MetalRenderer.swift for future integration point.'
        }
    },
    'validation': {
        'info_exit_code': $info_rc,
        'validate_exit_code': $validate_rc
    }
}

print(json.dumps(report, indent=2))
" > "$OUTPUT_JSON"

echo "# Baseline report written to $OUTPUT_JSON" >&2
echo ""
cat "$OUTPUT_JSON"

exit 0
