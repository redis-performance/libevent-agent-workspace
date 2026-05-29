#!/usr/bin/env bash
# 4-phase perf pipeline for libevent. Separates libevent self-CPU from kernel/syscall time
# BEFORE choosing an optimization. See .claude/skills/profile.md.
#
# Env:
#   BUILD     — build dir (default: <workspace>/build/main)
#   EXP       — experiment id (default: EXP-000)
#   PIN_CORES — taskset CPU set (default: 2-5)
#   BENCH_ARGS — args for the bench binary (default: -n 100 -a 1 -w 100)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$WORKSPACE/build/main}"
EXP="${EXP:-EXP-000}"
PIN_CORES="${PIN_CORES:-2-5}"
BENCH_ARGS="${BENCH_ARGS:--n 100 -a 1 -w 100}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$WORKSPACE/experiments/$EXP/profile-results"
PERF_DATA="$OUT_DIR/$TIMESTAMP-perf.data"
mkdir -p "$OUT_DIR"

BENCH="$(find "$BUILD" -name bench -type f -perm -u+x 2>/dev/null | head -1)"
[[ -x "${BENCH:-}" ]] || { echo "ERROR: bench not found under $BUILD; run build-bench.sh." >&2; exit 1; }
command -v perf &>/dev/null || { echo "ERROR: perf not found. sudo apt install linux-tools-generic" >&2; exit 1; }

PIN=""; command -v taskset &>/dev/null && PIN="taskset -c $PIN_CORES"
# loop the short benchmark so perf has enough samples
runbench() { for i in $(seq 1 "${1:-20}"); do $PIN "$BENCH" $BENCH_ARGS >/dev/null 2>&1 || true; done; }

echo "================ Phase 1 — cycle budget (the routing gate) ================"
sudo perf stat -e instructions,cycles,branches,branch-misses,cache-references,cache-misses \
  -- bash -c "$(declare -f runbench); BENCH='$BENCH'; PIN='$PIN'; BENCH_ARGS='$BENCH_ARGS'; runbench 40" 2>&1 | tail -18
echo ""
echo "    Kernel vs user split (cycles):"
sudo perf stat -e cycles:u,cycles:k \
  -- bash -c "$(declare -f runbench); BENCH='$BENCH'; PIN='$PIN'; BENCH_ARGS='$BENCH_ARGS'; runbench 40" 2>&1 | grep -E "cycles:[uk]" || true
echo "    → if epoll_wait+readv+writev dominate (>~40%): SYSCALL-BOUND → Tier 2/3"

echo ""
echo "================ Phase 2 — manifest-scoped attribution ================"
sudo perf record -g -F 999 -o "$PERF_DATA" -- \
  bash -c "$(declare -f runbench); BENCH='$BENCH'; PIN='$PIN'; BENCH_ARGS='$BENCH_ARGS'; runbench 60" >/dev/null 2>&1
echo "    Top symbols (self CPU):"
sudo perf report --stdio -i "$PERF_DATA" --no-children 2>/dev/null \
  | grep -E "^\s+[0-9]+\.[0-9]+%" | head -25
echo ""
echo "    libevent hot symbols (from config/hot-methods.yaml):"
sudo perf report --stdio -i "$PERF_DATA" --no-children 2>/dev/null \
  | grep -iE "evbuffer_|event_base_loop|event_process_active|epoll_|evmap_" | head -20

echo ""
echo "================ Phase 4 — syscall attribution ================"
echo "    user-only cycles (libevent code attribution):"
sudo perf stat -e cycles:u -- \
  bash -c "$(declare -f runbench); BENCH='$BENCH'; PIN='$PIN'; BENCH_ARGS='$BENCH_ARGS'; runbench 40" 2>&1 | grep -E "cycles:u" || true
echo "    syscall counts (epoll_wait / read / write / epoll_ctl):"
sudo perf stat -e 'syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_ctl,syscalls:sys_enter_read,syscalls:sys_enter_write,syscalls:sys_enter_readv,syscalls:sys_enter_writev' \
  -- bash -c "$(declare -f runbench); BENCH='$BENCH'; PIN='$PIN'; BENCH_ARGS='$BENCH_ARGS'; runbench 20" 2>&1 \
  | grep -E "syscalls:sys_enter" || echo "    (syscall tracepoints unavailable — need perf_event_paranoid<=1)"

echo ""
echo "==> perf data: $PERF_DATA"
echo "==> Phase 3 (off-CPU) is manual: sudo perf sched record -- <bench>; perf sched latency"
echo "==> Reminder: validate timing deltas with a perf-OFF run (perf perturbs the loop)."
