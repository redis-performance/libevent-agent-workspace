# EXP-NNN — YYYY-MM-DD — [Short Title]

## Status: IN PROGRESS

---

## Selection Phase

### Proposals

| Agent | Model | Tier | Technique | Expected Gain | Confidence |
|-------|-------|------|-----------|---------------|------------|
| opus | claude-opus-4-8 | | | | |
| sonnet | claude-sonnet-4-6 | | | | |
| haiku | claude-haiku-4-5 | | | | |

Full proposals: `experiments/EXP-NNN/proposals/TIMESTAMP/`

### Chair Decision

**Winner**: [agent]  
**Hypothesis**: [one falsifiable sentence]  
**Runner-up**: [agent, technique — why it didn't win]  
**Park for later**: [technique, or "none"]

---

## Implementation Phase

### Variants (each in its own worktree)

| Variant | Model | Change summary | Correctness | cascade median µs |
|---------|-------|---------------|-------------|-------------------|
| opus | claude-opus-4-8 | | pass/fail | |
| sonnet-a | claude-sonnet-4-6 | | pass/fail | |
| sonnet-b | claude-sonnet-4-6 | | pass/fail | |

**Winner variant**: [name] — [µs] (lower=better)  
Full variant diffs: `experiments/EXP-NNN/variants/TIMESTAMP/`

---

## Step 1: Benchmark (winner vs baseline) — never MB/s

| Workload | Before (µs) | After (µs) | Δ% | events/sec Δ |
|----------|------------|-----------|----|--------------|
| cascade (bench -n100 -a1 -w100) | | | | |
| cascade_chain (bench_cascade -n100) | | | | |

Benchmark file: `experiments/EXP-NNN/bench-results/TIMESTAMP.json`

---

## Step 2: Profile (winner)

```
Phase 1 — kernel/syscall share: NN%  → [syscall-bound | cpu-bound]
Phase 2 — top libevent symbols (self CPU):
  N.N%  symbol  [file]
Phase 4 — syscalls/iter: epoll_wait=N readv=N writev=N epoll_ctl=N
  IPC: N.NN (before N.NN)   branch-miss: N.NN% (before N.NN%)
```

**New bottleneck classification**: [Tier N — reason] → feeds next selection round

---

## Decision

**Status**: accept / reject / park  
**Reason**: [one or two sentences — what the numbers showed]

If rejected: add technique to "Known Non-Starters" in `.claude/program.md`.

---

## Token Cost

| Phase | Agent | Model | Tokens In | Tokens Out |
|-------|-------|-------|-----------|------------|
| select-propose | opus | claude-opus-4-8 | | |
| select-propose | sonnet | claude-sonnet-4-6 | | |
| select-propose | haiku | claude-haiku-4-5 | | |
| select-chair | chair | claude-opus-4-8 | | |
| implement | opus | claude-opus-4-8 | | |
| implement | sonnet-a | claude-sonnet-4-6 | | |
| implement | sonnet-b | claude-sonnet-4-6 | | |
| **Total** | | | **0** | **0** |

Full ledger: `experiments/token-ledger.tsv`

---

## Lessons

What this experiment revealed that applies to future attempts.
