#!/usr/bin/env bash
# Configure + build libevent (static, RelWithDebInfo) and its OSS benchmarks.
# Env:
#   SRC   — libevent source tree   (default: <workspace>/libevent)
#   BUILD — CMake build directory   (default: <workspace>/build/main)
#   FRESH — set to 1 to wipe the build dir first (avoids -march cache corruption)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$WORKSPACE/libevent}"
BUILD="${BUILD:-$WORKSPACE/build/main}"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "ERROR: libevent source not found at $SRC (did you init the submodule?)" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

if [[ "${FRESH:-0}" == "1" ]]; then
  echo "==> FRESH build — removing $BUILD"
  rm -rf "$BUILD"
fi

echo "==> Configuring libevent (SRC=$SRC BUILD=$BUILD)..."
cmake -B "$BUILD" -S "$SRC" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DEVENT__LIBRARY_TYPE=STATIC \
  -DEVENT__DISABLE_BENCHMARK=OFF \
  -DEVENT__DISABLE_TESTS=OFF \
  -DEVENT__DISABLE_SAMPLES=ON \
  -DEVENT__DISABLE_OPENSSL=ON \
  -DCMAKE_C_FLAGS="-march=native -fno-omit-frame-pointer" \
  --no-warn-unused-cli -Wno-dev \
  2>&1 | tail -5

echo "==> Building benchmarks + regress..."
cmake --build "$BUILD" --target bench bench_cascade bench_http regress -j"$(nproc)" 2>&1 | tail -8

echo "==> Done. Binaries under $BUILD:"
for b in bench bench_cascade bench_http; do
  found="$(find "$BUILD" -name "$b" -type f -perm -u+x 2>/dev/null | head -1)"
  echo "    ${found:-($b not found)}"
done
