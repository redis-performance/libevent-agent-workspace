# libevent-agent-workspace

Performance-optimization workspace for [libevent](https://libevent.org/) —
the OSS event-notification library ([libevent/libevent](https://github.com/libevent/libevent)).

Goal: push libevent's hot paths — the **evbuffer data plane**, **socket I/O batching**,
and **event-loop dispatch** — beyond the current baseline through profiled,
evidence-based micro-optimizations. Every experiment is logged; failures are as
valuable as wins.

This workspace mirrors the proven design of
[`ffc-agent-workspace`](https://github.com/redis-performance/ffc-agent-workspace),
adapted from a single-header parser to a multi-file event library.

---

## Optimization Pipeline

Population-based selection AND implementation, inspired by AutoKernel (arXiv:2603.21331).

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PROFILE (4-phase) → classify bottleneck → pick tier from program.md     │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │
                ┌───────────▼───────────┐
                │   SELECTION PHASE     │  ← opus / sonnet / haiku (parallel)
                │  3 proposers + chair  │
                └───────────┬───────────┘
                            │
          ┌─────────────────▼──────────────────┐
          │       IMPLEMENTATION PHASE          │
          │  3 implementers in parallel         │  ← each in its own git worktree
          │  each produces a unified diff       │     + isolated CMake build dir
          └──┬──────────────┬──────────────┬───┘
             │              │              │
         variant-1      variant-2      variant-3
        correctness    correctness    correctness   ← tiered gate (regress + timeouts)
        + benchmark    + benchmark    + benchmark
             └──────────────┴──────────────┘
                            │
                    best passing variant
                            │
                ┌───────────▼───────────┐
                │  TIERED CORRECTNESS   │
                │  light: regress subset│
                │  full:  all backends  │  ← only on accept (+ ASAN/TSAN)
                │  + per-test timeouts  │
                └───────────┬───────────┘
                            │
                ┌───────────▼───────────┐
                │  STEP 1: BENCHMARK    │  cascade + evbuffer workloads
                └───────────┬───────────┘
                            │
                ┌───────────▼───────────┐
                │  STEP 2: PROFILE      │  classify new bottleneck
                └───────────┬───────────┘
                            │
               ┌────────────┴────────────┐
           ACCEPT                     REJECT
      commit to libevent          git checkout -- (worktree pruned)
      submodule + log             log reason + Known Non-Starters
```

Two-step validation is mandatory before accepting any change:

| Step | Tool | Signal |
|------|------|--------|
| 1 — Benchmark | libevent's own OSS `bench` / `bench_cascade` / `bench_http` | events/sec, ns/op, syscall count — **never MB/s** |
| 2 — Profile | `perf stat` + `perf record -g` (4-phase) | hot symbols, % CPU, IPC, kernel/syscall share |

A result that wins in benchmark but reveals a new bottleneck in profile is a partial
win — document it and keep going.

### Why not a single throughput number

libevent is an event loop, not a parser. There is no MB/s. The profiling step first
runs a **cycle-budget gate**: if `epoll_wait`/`readv`/`writev` syscalls dominate
wall-clock, the run is flagged *syscall-bound* and the next experiment is routed toward
syscall reduction rather than userspace micro-opt. Every accept/reject is validated with
two runs — `perf`-on for direction, `perf`-off for the true delta — reported as the
median of ≥ 3.

---

## Optimization Target

Hot paths, in priority order (see [`.claude/program.md`](.claude/program.md) for the full
tiered playbook). These are derived from profiling libevent's own OSS benchmarks, not from
any downstream consumer.

1. **evbuffer data plane** (`buffer.c`) — chain allocation/reuse, `evbuffer_expand`,
   `evbuffer_read`/`evbuffer_write_atmost`, `evbuffer_drain`.
2. **socket I/O batching** — `readv`/`writev` iovec sizing, high-water marks, read caps.
3. **`epoll_ctl` churn** (`event.c` → `evmap.c` → `epoll.c`) — redundant event re-arming.
4. **event activation queue** (`event_process_active_single_queue`) — dispatch overhead.

`config/hot-methods.yaml` is the machine-readable manifest of which symbols matter; it is
populated from the first profile run and steers proposer agents.

---

## Workspace Layout

```
libevent/                       libevent source (submodule — redis-performance/libevent, OSS upstream)
  buffer.c                      evbuffer data plane — primary optimization target
  event.c                       event_base loop + event registration
  epoll.c / evmap.c             epoll backend + fd→event map (epoll_ctl churn)
  test/bench*.c                 OSS benchmarks (immutable harness — never edited by agents)
config/
  workload.toml                 benchmark workload parameters (version-controlled, immutable)
  hot-methods.yaml              symbols that matter (populated from profiling)
experiments/
  EXPERIMENTS.md                Append-only experiments log
  SUMMARY.md                    Status table (keep in sync with README counts)
  TEMPLATE.md                   Copy-paste template for new entries
  token-ledger.tsv              Machine-readable token cost per agent per phase
  EXP-NNN/                      One folder per experiment (bench-results/, profile-results/, proposals/, variants/)
scripts/
  build-bench.sh                Configure + build libevent static + OSS benchmarks
  run-bench.sh                  Run benchmark workloads, pinned cores, median of 3
  run-profile.sh                4-phase perf pipeline (cycle-budget → attribution → off-CPU → syscalls)
  verify-correctness.sh         Tiered gate (light regress subset / full multi-backend + ASAN/TSAN)
  new-variant-worktree.sh       git worktree + isolated build dir per implementer variant
  select.sh                     Selection phase: 3 proposers + chair (parallel)
  implement.sh                  Implementation phase: 3 variants in worktrees + best-wins
  agent-run.sh                  Agent-agnostic shim (AGENT=claude|codex|aider)
  llm-call.py                   Anthropic API call with real token accounting
.claude/
  CLAUDE.md                     Agent instructions (workflow, rules)
  program.md                    Tiered optimization playbook + bottleneck classification
  skills/                       optimize / select / chair / implement / bench / profile / correctness
.workspace-memory/
  MEMORY.md                     Persistent memory index (committed, agent-backend-agnostic)
```

---

## Quick Start

```bash
git clone --recurse-submodules git@github.com:redis-performance/libevent-agent-workspace.git
cd libevent-agent-workspace

# Build libevent (static, RelWithDebInfo) + OSS benchmarks
./scripts/build-bench.sh

# Step 1: baseline numbers
./scripts/run-bench.sh

# Step 2: profile (4-phase)
./scripts/run-profile.sh

# Edit libevent/*.c in a variant worktree, then:
./scripts/verify-correctness.sh        # correctness first — always
./scripts/build-bench.sh && ./scripts/run-bench.sh   # compare
./scripts/run-profile.sh               # verify bottleneck shifted
```

---

## Experiments

All experiments are logged in [`experiments/EXPERIMENTS.md`](experiments/EXPERIMENTS.md).
[`experiments/SUMMARY.md`](experiments/SUMMARY.md) is the single source of truth for status.

| Status | Count |
|--------|-------|
| Accepted | 1 |
| Rejected | 10 |
| Parked | 0 |
| In Progress | 0 |

---

## Inspiration

Directly inspired by **AutoKernel: Autonomous GPU Kernel Optimization via Iterative
Agent-Driven Search** (Jaber & Jaber, arXiv:2603.21331, 2026): immutable benchmark
harness + mutable code + git as the experiment ledger. We apply the same loop to a CPU
event-notification library instead of GPU kernels.

Key borrowed design choices:
- **Immutable benchmark harness** — libevent's own OSS benchmarks are never edited by the agent
- **Multi-stage correctness before any performance measurement** — a broken event loop is never benchmarked
- **Git as experiment ledger** — accept = commit advances the submodule tip, reject = discard the worktree
- **Tiered optimization playbook** ([`.claude/program.md`](.claude/program.md))
- **Bottleneck classification** — profile output classified to steer the next tier
- **Move-on criteria** — prevents over-investment in diminishing returns

---

## References

- Jaber & Jaber, [AutoKernel](https://arxiv.org/abs/2603.21331), arXiv, 2026 ← **direct inspiration**
- [libevent](https://github.com/libevent/libevent) — the OSS library under optimization
- Nick Mathewson, [Fast portable non-blocking network programming with libevent](https://libevent.org/libevent-book/)
