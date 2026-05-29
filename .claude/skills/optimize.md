# Skill: optimize

One full iteration of the population-based optimization loop:
select → implement (N variants in worktrees) → tiered correctness → benchmark → profile →
commit/revert → log.

Inspired by AutoKernel (arXiv:2603.21331): immutable benchmark + mutable code + git ledger.

---

## Full Loop

```
Profile (4-phase)
  ↓
SELECTION — 3 agents propose (opus / sonnet / haiku) → chair picks winner
  ↓
IMPLEMENTATION — 3 agents implement in parallel worktrees → best variant wins
  ↓
Tiered correctness (light gate on the winner; full gate only on accept)
  ↓
Step 1: Benchmark (cascade + evbuffer workloads; ns/op, events/sec, syscalls)
  ↓
Step 2: Profile → classify new bottleneck
  ↓
Accept (commit to libevent submodule) or Reject (discard worktree)
  ↓
Log to EXPERIMENTS.md + token-ledger.tsv
```

---

## Steps

### 1. Run profile (if stale)
```bash
scripts/run-profile.sh
```
Skip if the last profile matches the current libevent commit. Read the cycle-budget kernel%
share first — it routes which tier you target.

### 2. Selection phase
```bash
EXP_ID=EXP-NNN scripts/select.sh
```
3 proposers in parallel (opus / sonnet / haiku) + chair (opus). Read
`experiments/EXP-NNN/proposals/TIMESTAMP/chair-decision.md` for the winning hypothesis.

If `select.sh` is unavailable (interactive): act as chair yourself — read the profile +
playbook, propose 3 alternatives from different tiers, pick the strongest, state the
falsifiable hypothesis explicitly.

### 3. Implementation phase
```bash
EXP_ID=EXP-NNN scripts/implement.sh experiments/EXP-NNN/proposals/TIMESTAMP/chair-decision.md
```
3 implementers in parallel, each in its own git worktree with an isolated build dir. Each
produces a unified diff, built + correctness-checked + benchmarked. Best passing variant wins.

If `implement.sh` is unavailable: implement the hypothesis yourself (single variant).

### 4. Tiered correctness (winner — before any benchmark)
```bash
scripts/verify-correctness.sh            # light gate
scripts/verify-correctness.sh --full     # full gate (run on accept)
```
Light = build + relevant regress subset under per-test timeouts. Full = all backends +
ASAN + TSAN. If any stage fails or hangs: discard the variant, return to step 2.

### 5. Step 1 — Benchmark
```bash
scripts/build-bench.sh
EXP=EXP-NNN scripts/run-bench.sh
```
Compare ns/op + events/sec + syscall count vs the last accepted entry.

### 6. Step 2 — Profile
```bash
scripts/run-profile.sh
```
Classify the new bottleneck for the next iteration.

### 7. Commit or revert
**Accept** (≥ +2% on ≥ 1 workload, no regression > 1%, full gate passes):
```bash
git -C libevent add -A && git -C libevent commit -m "EXP-NNN: <one-line>"
```
**Reject**: discard the variant worktree (`scripts/new-variant-worktree.sh` cleans up on exit).

### 8. Log
Append to `experiments/EXPERIMENTS.md` (use `experiments/TEMPLATE.md`). All agent token
counts → Token Cost table + `experiments/token-ledger.tsv`. If rejected → "Known
Non-Starters" in `.claude/program.md`. Update `experiments/SUMMARY.md` + README counts.

---

## Move-On Criteria

- **5 consecutive rejects** from the same tier → move to the next tier
- **2 hours wall time** → stop, log current state, pick up next session
- **< 2% CPU** in the target symbol after profiling → re-classify, pick a new tier
- **≥ +10% accepted** → re-profile before choosing the next experiment
- **off-CPU dominates** → consumer is latency-bound; park CPU micro-opts

---

## Decision Thresholds

| | Criteria |
|--|---------|
| **Accept** | ≥ +2% on ≥ 1 workload, no regression > 1%, profile confirms shift, full gate green |
| **Reject** | < 1% delta (noise), any regression, correctness failure, or a hang |
| **Park** | ≥ +1% but < 2%, or needs a prerequisite, or single-thread-only / backend-specific |
