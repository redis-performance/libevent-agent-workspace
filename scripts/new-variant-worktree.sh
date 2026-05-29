#!/usr/bin/env bash
# Create an isolated git worktree + build dir for one implementer variant, off the
# writable libevent submodule. Replaces ffc's single-header cp-r swap — multiple .c files
# built by 3 parallel variants cannot share one tree (filesystem races, -march cache corruption).
#
# Usage: scripts/new-variant-worktree.sh <variant-name>
#   prints two lines:  WORKTREE=<path>   BUILD=<path>
# Cleanup: scripts/new-variant-worktree.sh --prune   (removes all variant worktrees)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$WORKSPACE/libevent"
WT_ROOT="$WORKSPACE/.claude/worktrees"
mkdir -p "$WT_ROOT"

if [[ "${1:-}" == "--prune" ]]; then
  for wt in "$WT_ROOT"/variant-*; do
    [[ -d "$wt" ]] || continue
    git -C "$SRC" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    echo "pruned $wt"
  done
  git -C "$SRC" worktree prune 2>/dev/null || true
  exit 0
fi

NAME="${1:?usage: new-variant-worktree.sh <variant-name>}"
WT="$WT_ROOT/variant-$NAME"
BUILD="$WORKSPACE/build/variant-$NAME"
BASE="$(git -C "$SRC" rev-parse HEAD)"

# fresh worktree from the current submodule tip (the best accepted state)
git -C "$SRC" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
git -C "$SRC" worktree add --detach "$WT" "$BASE" >/dev/null 2>&1
# isolated build dir, always fresh to avoid -march cache corruption between variants
rm -rf "$BUILD"

echo "WORKTREE=$WT"
echo "BUILD=$BUILD"
