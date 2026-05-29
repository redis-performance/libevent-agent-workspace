#!/usr/bin/env bash
# Run libevent's OSS benchmarks, pinned to fixed cores, warmup + N repetitions,
# report the median microseconds-per-run_once (lower = better). NEVER MB/s.
#
# Env:
#   EXP         — experiment id (default: EXP-000); results land under experiments/<EXP>/bench-results/
#   BUILD       — build dir (default: <workspace>/build/main)
#   PIN_CORES   — taskset CPU set (default: from config or 2-5)
#   REPETITIONS — real runs (default: 5)
#   WARMUP      — discarded warmup runs (default: 1)
#   BASELINE    — set to 1 to tag the output as the machine baseline
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$WORKSPACE/build/main}"
EXP="${EXP:-EXP-000}"
PIN_CORES="${PIN_CORES:-2-5}"
REPETITIONS="${REPETITIONS:-5}"
WARMUP="${WARMUP:-1}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOST="$(uname -n)"
OUT_DIR="$WORKSPACE/experiments/$EXP/bench-results"
mkdir -p "$OUT_DIR"

BENCH="$(find "$BUILD" -name bench -type f -perm -u+x 2>/dev/null | head -1)"
BENCH_CASCADE="$(find "$BUILD" -name bench_cascade -type f -perm -u+x 2>/dev/null | head -1)"
if [[ ! -x "${BENCH:-}" ]]; then
  echo "ERROR: bench binary not found under $BUILD. Run scripts/build-bench.sh first." >&2
  exit 1
fi

PIN=""
command -v taskset &>/dev/null && PIN="taskset -c $PIN_CORES"

# median of stdin numbers (one per line)
median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0){print "NaN";exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "%.1f", m }'; }
minval() { sort -n | head -1; }

# run a benchmark binary; collect the per-run µs samples it prints (25 lines/invocation),
# across WARMUP+REPETITIONS invocations (warmup invocations discarded), print median+min µs.
run_workload() {
  local label="$1"; shift
  local bin="$1"; shift
  local samples=""
  for ((r=0; r<WARMUP; r++)); do $PIN "$bin" "$@" >/dev/null 2>&1 || true; done
  for ((r=0; r<REPETITIONS; r++)); do
    local out; out="$($PIN "$bin" "$@" 2>/dev/null || true)"
    samples+="$out"$'\n'
  done
  local clean; clean="$(printf '%s' "$samples" | grep -E '^[0-9]+$' || true)"
  local med min
  med="$(printf '%s\n' "$clean" | median)"
  min="$(printf '%s\n' "$clean" | minval)"
  local n; n="$(printf '%s\n' "$clean" | grep -c . || echo 0)"
  echo "  $label: median=${med}us  min=${min}us  (n=$n samples)"
  echo "\"$label\": {\"median_us\": $med, \"min_us\": $min, \"samples\": $n}" >> "$OUT_DIR/.json.$TIMESTAMP"
}

SUFFIX=""; [[ "${BASELINE:-0}" == "1" ]] && SUFFIX="-BASELINE"
OUTFILE="$OUT_DIR/$TIMESTAMP-$HOST$SUFFIX.json"
: > "$OUT_DIR/.json.$TIMESTAMP"

echo "===== libevent benchmark — $EXP — $TIMESTAMP ====="
echo "Host: $HOST  Cores: $PIN_CORES  Reps: $REPETITIONS (+$WARMUP warmup)"
echo "Method: $($PIN "$BENCH" 2>&1 | grep -i 'using libevent' | head -1 || true)"
echo "Metric: microseconds per run_once (lower is better)"
echo ""

# cascade: pipe/event throughput (bench.c -n pipes -a active -w writes)
run_workload "cascade(bench -n100 -a1 -w100)" "$BENCH" -n 100 -a 1 -w 100
# cascade_chain: event-propagation latency (bench_cascade.c -n pipes)
[[ -x "${BENCH_CASCADE:-}" ]] && run_workload "cascade_chain(bench_cascade -n100)" "$BENCH_CASCADE" -n 100

# assemble JSON
{
  echo "{"
  echo "  \"exp\": \"$EXP\", \"host\": \"$HOST\", \"timestamp\": \"$TIMESTAMP\","
  echo "  \"cores\": \"$PIN_CORES\", \"repetitions\": $REPETITIONS,"
  echo "  \"workloads\": {"
  paste -sd, "$OUT_DIR/.json.$TIMESTAMP" | sed 's/^/    /'
  echo "  }"
  echo "}"
} > "$OUTFILE"
rm -f "$OUT_DIR/.json.$TIMESTAMP"

echo ""
echo "==> Saved to $OUTFILE"
if [[ "${BASELINE:-0}" == "1" ]]; then echo "==> Tagged as BASELINE for $HOST."; fi
exit 0
