#!/usr/bin/env bash
# Selection phase: 3 proposer agents (different models) independently propose the next
# experiment, then a chair agent picks the winner. Token counts come from the API response
# (via llm-call.py) — not self-reported.
#
# Output: experiments/<EXP>/proposals/TIMESTAMP/ (one file per agent + chair decision)
# Stdout: the chair decision (pipe into implement.sh)
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
LLM="python3 $WORKSPACE/scripts/llm-call.py"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LEDGER="$WORKSPACE/experiments/token-ledger.tsv"
EXP_ID="${EXP_ID:-$(printf 'EXP-%03d' "$(grep -c '^## EXP-' "$WORKSPACE/experiments/EXPERIMENTS.md" 2>/dev/null || echo 0)")}"
PROPOSALS_DIR="$WORKSPACE/experiments/$EXP_ID/proposals/$TIMESTAMP"
mkdir -p "$PROPOSALS_DIR"

MODELS=("claude-opus-4-8" "claude-sonnet-4-6" "claude-haiku-4-5-20251001")
AGENT_NAMES=("opus" "sonnet" "haiku")

# shared context for all proposers
CONTEXT_FILE="$PROPOSALS_DIR/context.md"
{
  echo "## Most recent profile"
  ls -t "$WORKSPACE/experiments"/*/profile-results/*.txt 2>/dev/null | head -1 | xargs cat 2>/dev/null \
    || echo "(no profile yet — classify from the benchmark / kernel% gate)"
  echo ""
  echo "## Most recent benchmark"
  ls -t "$WORKSPACE/experiments"/*/bench-results/*.json 2>/dev/null | head -1 | xargs cat 2>/dev/null \
    || echo "(no benchmark yet)"
  echo ""
  echo "## Hot-method manifest"
  cat "$WORKSPACE/config/hot-methods.yaml"
  echo ""
  echo "## Experiment history"
  cat "$WORKSPACE/experiments/EXPERIMENTS.md" 2>/dev/null || echo "(none yet)"
  echo ""
  echo "## Optimization playbook"
  cat "$WORKSPACE/.claude/program.md"
} > "$CONTEXT_FILE"

echo "==> Selection — $EXP_ID — $TIMESTAMP — ${#MODELS[@]} proposers in parallel" >&2
PIDS=()
for i in "${!MODELS[@]}"; do
  name="${AGENT_NAMES[$i]}"
  pf="$PROPOSALS_DIR/prompt-$name.md"
  { cat "$WORKSPACE/.claude/skills/select.md"; echo; echo "---"; cat "$CONTEXT_FILE"; } > "$pf"
  $LLM --model "${MODELS[$i]}" --prompt-file "$pf" --exp-id "$EXP_ID" \
       --phase select-propose --agent-id "$name" --ledger "$LEDGER" --description proposal \
       > "$PROPOSALS_DIR/proposal-$name.md" 2>>"$PROPOSALS_DIR/stderr.log" &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done
echo "==> Proposers done." >&2

CHAIR_MODEL="claude-opus-4-8"
CP="$PROPOSALS_DIR/prompt-chair.md"
{ cat "$WORKSPACE/.claude/skills/chair.md"; echo; echo "---"; echo "## Proposals to evaluate";
  for i in "${!MODELS[@]}"; do n="${AGENT_NAMES[$i]}";
    echo; echo "### Agent $((i+1)) — ${MODELS[$i]} ($n)"; cat "$PROPOSALS_DIR/proposal-$n.md" 2>/dev/null || echo "(missing)";
  done; } > "$CP"

echo "==> Chair ($CHAIR_MODEL) selecting..." >&2
CHAIR_OUT="$PROPOSALS_DIR/chair-decision.md"
$LLM --model "$CHAIR_MODEL" --prompt-file "$CP" --exp-id "$EXP_ID" \
     --phase select-chair --agent-id chair --ledger "$LEDGER" --description "chair decision" \
     > "$CHAIR_OUT" 2>>"$PROPOSALS_DIR/stderr.log"

echo "==> Proposals: $PROPOSALS_DIR/  |  decision: $CHAIR_OUT" >&2
cat "$CHAIR_OUT"
