#!/usr/bin/env bash
# Implementation phase: N agents implement the winning hypothesis in parallel, each in its
# OWN git worktree + isolated build dir. Each diff is applied, correctness-checked (light),
# and benchmarked. Best passing variant (lowest median µs) wins and is applied to the
# libevent submodule (caller then commits or reverts). Token counts via llm-call.py.
#
# Usage: EXP_ID=EXP-001 ./scripts/implement.sh <chair-decision.md>   (or hypothesis on stdin)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LLM="python3 $WORKSPACE/scripts/llm-call.py"
SRC="$WORKSPACE/libevent"
LEDGER="$WORKSPACE/experiments/token-ledger.tsv"
EXP_ID="${EXP_ID:-EXP-000}"
N_VARIANTS="${N_VARIANTS:-3}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
VARIANTS_DIR="$WORKSPACE/experiments/$EXP_ID/variants/$TIMESTAMP"
mkdir -p "$VARIANTS_DIR"

if [[ -n "${1:-}" && -f "$1" ]]; then HYP="$1"; else HYP="$VARIANTS_DIR/hypothesis.md"; cat > "$HYP"; fi

MODELS=("claude-opus-4-8" "claude-sonnet-4-6" "claude-sonnet-4-6")
AGENT_NAMES=("opus" "sonnet-a" "sonnet-b")

# files an implementer may need to see (hot data-plane + dispatch)
SRC_FILES=(buffer.c evbuffer-internal.h event.c evmap.c epoll.c)

echo "==> Implementation — $EXP_ID — $N_VARIANTS variants in parallel worktrees" >&2
PIDS=()
for i in $(seq 0 $((N_VARIANTS-1))); do
  name="${AGENT_NAMES[$i]}"; pf="$VARIANTS_DIR/prompt-$name.md"
  { cat "$WORKSPACE/.claude/skills/implement.md"; echo; echo "---"; echo "## Winning hypothesis"; cat "$HYP";
    echo; echo "## Current source files";
    for f in "${SRC_FILES[@]}"; do [[ -f "$SRC/$f" ]] && { echo; echo "### libevent/$f"; echo '```c'; cat "$SRC/$f"; echo '```'; }; done
  } > "$pf"
  echo "    variant $((i+1))/$N_VARIANTS: ${MODELS[$i]} ($name)" >&2
  $LLM --model "${MODELS[$i]}" --prompt-file "$pf" --exp-id "$EXP_ID" \
       --phase implement --agent-id "$name" --ledger "$LEDGER" --description "implementation variant" --max-tokens 8192 \
       > "$VARIANTS_DIR/variant-$name-raw.md" 2>>"$VARIANTS_DIR/stderr.log" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done
echo "==> Implementers done. Extracting diffs..." >&2

declare -A SCORE STATUS
for i in $(seq 0 $((N_VARIANTS-1))); do
  name="${AGENT_NAMES[$i]}"; raw="$VARIANTS_DIR/variant-$name-raw.md"; diff="$VARIANTS_DIR/variant-$name.diff"
  awk '/^DIFF:/{f=1;next} /^```$/&&f{f=0} f{print}' "$raw" > "$diff" 2>/dev/null || true
  [[ -s "$diff" ]] || awk '/^--- a\//{f=1} f{print}' "$raw" > "$diff" 2>/dev/null || true

  echo "" >&2; echo "==> variant $name: worktree → apply → light correctness → bench" >&2
  if [[ ! -s "$diff" ]]; then STATUS[$name]="fail-no-diff"; echo "    no diff extracted — FAIL" >&2; continue; fi

  eval "$("$WORKSPACE/scripts/new-variant-worktree.sh" "$name")"   # sets WORKTREE, BUILD
  if ! git -C "$WORKTREE" apply --recount "$diff" 2>/dev/null && ! patch -p1 -d "$WORKTREE" < "$diff" >/dev/null 2>&1; then
    STATUS[$name]="fail-patch"; echo "    diff failed to apply — FAIL" >&2; continue
  fi
  if ! SRC="$WORKTREE" BUILD="$BUILD" "$WORKSPACE/scripts/verify-correctness.sh" >/dev/null 2>&1; then
    STATUS[$name]="fail-correctness"; echo "    correctness FAIL" >&2; continue
  fi
  SRC="$WORKTREE" BUILD="$BUILD" "$WORKSPACE/scripts/build-bench.sh" >/dev/null 2>&1 || { STATUS[$name]="fail-build"; continue; }
  bench_out="$VARIANTS_DIR/bench-$name.json"
  EXP="$EXP_ID" BUILD="$BUILD" "$WORKSPACE/scripts/run-bench.sh" > "$VARIANTS_DIR/bench-$name.log" 2>&1 || true
  cp "$(ls -t "$WORKSPACE/experiments/$EXP_ID/bench-results/"*.json 2>/dev/null | head -1)" "$bench_out" 2>/dev/null || true
  # lower median µs = better; grab cascade workload median
  med="$(grep -oE '"median_us": [0-9.]+' "$bench_out" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || echo "")"
  if [[ -n "$med" ]]; then STATUS[$name]="pass"; SCORE[$name]="$med"; echo "    PASS — cascade median ${med}us" >&2
  else STATUS[$name]="fail-bench"; echo "    bench produced no number — FAIL" >&2; fi
done

echo "" >&2; echo "==> Results:" >&2
WINNER=""; WINNER_SCORE=""
for name in "${AGENT_NAMES[@]}"; do
  s="${STATUS[$name]:-?}"; sc="${SCORE[$name]:-}"
  echo "    $name  status=$s  median=${sc:-NA}us" >&2
  if [[ "$s" == "pass" ]]; then
    if [[ -z "$WINNER_SCORE" ]] || awk "BEGIN{exit !($sc < $WINNER_SCORE)}"; then WINNER="$name"; WINNER_SCORE="$sc"; fi
  fi
done

{ echo "WINNER: ${WINNER:-none}"; echo "SCORE: ${WINNER_SCORE:-NA} us (median, lower=better)"; } > "$VARIANTS_DIR/result.txt"
if [[ -z "$WINNER" ]]; then echo "==> No variant passed — all rejected." >&2; exit 1; fi

echo "" >&2; echo "==> Winner: $WINNER (${WINNER_SCORE}us). Applying to libevent submodule..." >&2
git -C "$SRC" apply --recount "$VARIANTS_DIR/variant-$WINNER.diff" 2>/dev/null \
  || patch -p1 -d "$SRC" < "$VARIANTS_DIR/variant-$WINNER.diff" >/dev/null
"$WORKSPACE/scripts/new-variant-worktree.sh" --prune >/dev/null 2>&1 || true
echo "==> Applied. Run run-bench.sh + run-profile.sh, then commit/revert. Variants: $VARIANTS_DIR/" >&2
