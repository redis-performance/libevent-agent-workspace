#!/usr/bin/env bash
# Run libevent's OSS benchmarks, pinned to fixed cores, warmup + N repetitions.
# Metric: microseconds per run_once (lower = better). NEVER MB/s.
#
# PRESERVES ALL RELEVANT NUMBERS. Every run writes TWO files under
# experiments/<EXP>/bench-results/:
#   <ts>-<host>[-BASELINE].txt   — human-readable: full stats + EVERY raw sample
#   <ts>-<host>[-BASELINE].json  — machine-readable summary stats
# These are never overwritten (timestamped) and never gitignored (text/json kept).
#
# Env:
#   EXP EXP-000 | BUILD build/main | PIN_CORES 2-5 | REPETITIONS 5 | WARMUP 1 | BASELINE 0|1
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
[[ -x "${BENCH:-}" ]] || { echo "ERROR: bench not found under $BUILD. Run scripts/build-bench.sh first." >&2; exit 1; }

PIN=""; command -v taskset &>/dev/null && PIN="taskset -c $PIN_CORES"

SUFFIX=""; [[ "${BASELINE:-0}" == "1" ]] && SUFFIX="-BASELINE"
TXT="$OUT_DIR/$TIMESTAMP-$HOST$SUFFIX.txt"
JSON="$OUT_DIR/$TIMESTAMP-$HOST$SUFFIX.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
METHOD="$($PIN "$BENCH" 2>&1 | grep -ioE 'Using Libevent[^.]*' | head -1 || true)"
[[ -n "$METHOD" ]] || METHOD="libevent ($(git -C "$WORKSPACE/libevent" rev-parse --short HEAD 2>/dev/null || echo unknown))"

# stats over stdin (one number/line): n min p50 p95 p99 max mean stddev
stats() {
  sort -n | awk '
    {a[NR]=$1; s+=$1; ss+=$1*$1}
    END{
      n=NR; if(n==0){print "0 NaN NaN NaN NaN NaN NaN NaN"; exit}
      p50=a[int((n+1)*0.50)]; p95=a[int((n+1)*0.95)]; p99=a[int((n+1)*0.99)];
      if(p95==""){p95=a[n]} if(p99==""){p99=a[n]}
      mean=s/n; var=(ss/n)-(mean*mean); if(var<0)var=0; sd=sqrt(var);
      printf "%d %s %s %s %s %s %.2f %.2f\n", n, a[1], p50, p95, p99, a[n], mean, sd
    }'
}

run_workload() {  # name  bin  args...
  local name="$1"; shift; local bin="$1"; shift
  local sf="$TMP/$name.samples"; : > "$sf"
  for ((r=0; r<WARMUP; r++)); do $PIN "$bin" "$@" >/dev/null 2>&1 || true; done
  for ((r=0; r<REPETITIONS; r++)); do
    $PIN "$bin" "$@" 2>/dev/null | grep -E '^[0-9]+$' >> "$sf" || true
  done
  read -r n mn p50 p95 p99 mx mean sd < <(stats < "$sf") || true
  # human-readable block + every raw sample
  {
    echo "## $name"
    echo "   cmd        : $(basename "$bin") $*"
    echo "   samples    : $n   (us per run_once, lower=better)"
    echo "   min        : $mn"
    echo "   median(p50): $p50"
    echo "   p95        : $p95"
    echo "   p99        : $p99"
    echo "   max        : $mx"
    echo "   mean       : $mean"
    echo "   stddev     : $sd"
    echo "   raw_samples: $(paste -sd' ' "$sf")"
    echo ""
  } >> "$TXT"
  # one json fragment
  printf '"%s": {"cmd": "%s %s", "n": %s, "min_us": %s, "median_us": %s, "p95_us": %s, "p99_us": %s, "max_us": %s, "mean_us": %s, "stddev_us": %s}' \
    "$name" "$(basename "$bin")" "$*" "$n" "$mn" "$p50" "$p95" "$p99" "$mx" "$mean" "$sd" >> "$TMP/json.frags"
  echo "," >> "$TMP/json.frags"
  echo "  $name: median=${p50}us min=${mn}us p99=${p99}us mean=${mean}us±${sd} (n=$n)"
}

# ---- header (text) ----
{
  echo "# libevent benchmark run"
  echo "# exp=$EXP host=$HOST timestamp=$TIMESTAMP"
  echo "# cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs)"
  echo "# cores=$PIN_CORES repetitions=$REPETITIONS warmup=$WARMUP"
  echo "# libevent=$METHOD  commit=$(git -C "$WORKSPACE/libevent" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "# metric=microseconds_per_run_once (lower is better)"
  echo ""
} > "$TXT"
: > "$TMP/json.frags"

echo "===== libevent benchmark — $EXP — $TIMESTAMP ====="
echo "Host: $HOST  Cores: $PIN_CORES  Reps: $REPETITIONS (+$WARMUP warmup)  $METHOD"
echo "Metric: microseconds per run_once (lower is better)"
echo ""

run_workload "cascade_bench"   "$BENCH" -n 100 -a 1 -w 100
[[ -x "${BENCH_CASCADE:-}" ]] && run_workload "cascade_chain" "$BENCH_CASCADE" -n 100

# ---- assemble JSON ----
{
  echo "{"
  echo "  \"exp\": \"$EXP\", \"host\": \"$HOST\", \"timestamp\": \"$TIMESTAMP\","
  echo "  \"libevent_commit\": \"$(git -C "$WORKSPACE/libevent" rev-parse HEAD 2>/dev/null || echo unknown)\","
  echo "  \"cores\": \"$PIN_CORES\", \"repetitions\": $REPETITIONS, \"warmup\": $WARMUP,"
  echo "  \"baseline\": $([[ "${BASELINE:-0}" == "1" ]] && echo true || echo false),"
  echo "  \"workloads\": {"
  sed '$ s/,$//' "$TMP/json.frags" | sed 's/^/    /'
  echo "  }"
  echo "}"
} > "$JSON"

echo ""
echo "==> Text  (all samples + stats): $TXT"
echo "==> JSON  (summary):             $JSON"
if [[ "${BASELINE:-0}" == "1" ]]; then echo "==> Tagged as BASELINE for $HOST."; fi
exit 0
