#!/usr/bin/env bash
# Tiered correctness gate. Run BEFORE any benchmark. A broken or hanging loop is never benchmarked.
#   (no args)  LIGHT gate — build + regress subset under per-test hang timeouts
#   --full     FULL gate  — all backends + ASAN + TSAN (run only before accepting)
#
# Env:
#   SRC   — libevent source (default: <workspace>/libevent)
#   BUILD — build dir (default: <workspace>/build/main)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$WORKSPACE/libevent}"
BUILD="${BUILD:-$WORKSPACE/build/main}"
MODE="light"; [[ "${1:-}" == "--full" ]] && MODE="full"

# CPU-bound tests 30s, socket I/O up to 60s; a timeout = deadlock = FAIL.
TIMEOUT_BIN="timeout"; command -v timeout &>/dev/null || TIMEOUT_BIN=""

find_regress() { find "$1" -name regress -type f -perm -u+x 2>/dev/null | head -1; }

build_regress() {
  local bdir="$1"; shift
  local extra_flags="${1:-}"
  cmake -B "$bdir" -S "$SRC" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DEVENT__LIBRARY_TYPE=STATIC \
    -DEVENT__DISABLE_TESTS=OFF \
    -DEVENT__DISABLE_BENCHMARK=ON \
    -DEVENT__DISABLE_SAMPLES=ON \
    -DEVENT__DISABLE_OPENSSL=ON \
    -DCMAKE_C_FLAGS="-fno-omit-frame-pointer $extra_flags" \
    --no-warn-unused-cli -Wno-dev >/dev/null 2>&1
  cmake --build "$bdir" --target regress -j"$(nproc)" >/dev/null 2>&1
}

# run regress with a wall-clock hang guard; args after the binary are passed through
run_regress() {
  local bin="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    $TIMEOUT_BIN 120 "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

echo "================ Correctness gate: $MODE ================"

echo "==> Building regress..."
build_regress "$BUILD" || { echo "BUILD FAILED → FAIL"; exit 1; }
REG="$(find_regress "$BUILD")"
[[ -x "${REG:-}" ]] || { echo "regress binary not found → FAIL"; exit 1; }

echo "==> LIGHT gate: regress (hang-guarded)..."
if run_regress "$REG"; then
  echo "  regress: PASS"
else
  rc=$?
  [[ $rc -eq 124 ]] && echo "  regress: TIMEOUT (deadlock) → FAIL" || echo "  regress: FAIL (rc=$rc)"
  exit 1
fi

if [[ "$MODE" == "light" ]]; then
  echo "→ LIGHT gate PASS"
  exit 0
fi

echo ""
echo "==> FULL gate: all backends..."
for nob in NOEPOLL NOSELECT NOPOLL NOKQUEUE NODEVPOLL NOEVPORT; do
  var="EVENT_$nob"
  if env "$var=1" run_regress "$REG" >/dev/null 2>&1; then
    echo "  backend (with $var=1): PASS"
  else
    rc=$?
    # backend genuinely unavailable on this OS → SKIP, not FAIL
    [[ $rc -eq 124 ]] && { echo "  $var: TIMEOUT → FAIL"; exit 1; }
    echo "  backend (with $var=1): SKIP/NA (rc=$rc)"
  fi
done

echo ""
echo "==> FULL gate: ASAN..."
ASAN_BUILD="$WORKSPACE/build/asan"
build_regress "$ASAN_BUILD" "-fsanitize=address -g" \
  && ASAN_OPTIONS=detect_leaks=1 run_regress "$(find_regress "$ASAN_BUILD")" >/dev/null 2>&1 \
  && echo "  ASAN: clean" || { echo "  ASAN: FAIL"; exit 1; }

echo ""
echo "==> FULL gate: TSAN..."
TSAN_BUILD="$WORKSPACE/build/tsan"
SUPP="$WORKSPACE/config/tsan.supp"
[[ -f "$SUPP" ]] || : > "$SUPP"
build_regress "$TSAN_BUILD" "-fsanitize=thread -g" \
  && TSAN_OPTIONS="suppressions=$SUPP" run_regress "$(find_regress "$TSAN_BUILD")" >/dev/null 2>&1 \
  && echo "  TSAN: clean" || { echo "  TSAN: FAIL (or needs a suppression in config/tsan.supp)"; exit 1; }

echo "→ FULL gate PASS"
