# Agent Notes — libevent-agent-workspace

Conventions for agent loops running in this workspace.
Mirrors the style of `ffc-agent-workspace/AGENTS.md` and `redis-agent-workspace/AGENTS.md`.

---

## Optimization Goal

Push libevent's hot paths beyond the current baseline: the **evbuffer data plane**
(`buffer.c`), **socket I/O batching** (`evbuffer_read`/`evbuffer_write_atmost`), and
**event-loop dispatch / `epoll_ctl` churn** (`event.c`, `evmap.c`, `epoll.c`).

This is a pure OSS effort against upstream libevent. There is no downstream-consumer
patch in scope — work against `redis-performance/libevent` (a fork of OSS upstream).

---

## Two-Step Validation (mandatory)

Every code change must pass both steps before being accepted:

1. **Benchmark** — run `scripts/run-bench.sh`; compare events/sec, ns/op, syscall count
   - Must improve at least one workload without regressing others
   - **Never report MB/s** — libevent is an event loop, not a parser
   - Results go in the experiment log entry in `experiments/EXPERIMENTS.md`

2. **Profile** — run `scripts/run-profile.sh` (4-phase); compare hot symbols
   - Confirm the expected bottleneck shifted
   - Capture key `perf report` lines + the cycle-budget kernel% share

An approach that improves benchmark numbers but reveals a new surprising bottleneck
is a **partial win** — document the new bottleneck and continue.

---

## Agent-Agnostic Shim — `scripts/agent-run.sh`

Single env var `AGENT` selects the backend:
- `AGENT=claude` (default) — uses `claude` CLI in non-interactive mode
- `AGENT=codex` (planned)
- `AGENT=aider` (planned)

Skills under `.claude/skills/*.md` are plain markdown prompts.

---

## Persistent Memory — `.workspace-memory/`

All memory files live in `.workspace-memory/` so every agent backend shares context.
`MEMORY.md` is the index; one file per memory entry.

When running autonomously: commit any `.workspace-memory/` updates back to `main`
in the same commit as the experiment results. Git log is the audit trail.

---

## Workflow Rules

- **Edit `libevent/*.c` / `libevent/*.h`** — never edit `libevent/test/bench*.c` (the
  benchmark harness is immutable — never modify it to make libevent look better)
- Each implementer variant runs in its **own git worktree** with an isolated CMake build
  dir — never let 3 variants build in the same tree (filesystem races, `-march` cache corruption)
- **Always run `scripts/verify-correctness.sh` before logging a benchmark result** —
  correctness first, no exceptions. A bad edit can deadlock the loop; per-test timeouts guard it.
- Log every experiment in `experiments/EXPERIMENTS.md` — failures are valuable
- Keep `experiments/SUMMARY.md` and `README.md` counts in sync after each decision
- Accept → commit to the `libevent` submodule (tip = best accepted state).
  Reject → discard the worktree. Never force-push to `main`.
- After a permanent dead end: add to "Known Non-Starters" in `.claude/program.md`

---

## Runner Requirements

This workspace runs entirely locally — no remote runners required.

- `clang` / `gcc`, `cmake` ≥ 3.5, `make`
- `perf` (Linux kernel tools) — `sudo apt install linux-tools-generic`
- `taskset` (util-linux) for core pinning
- `python3` ≥ 3.10 (for `llm-call.py` token accounting)
- `claude` CLI — `npm i -g @anthropic-ai/claude-code`

For perf counter access (IPC, branch mispredicts, cache misses, syscall tracepoints):
```bash
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
```

---

## Required Secrets

None — this workspace is fully OSS and runs locally.
Set `ANTHROPIC_API_KEY` or use `CLAUDE_CODE_OAUTH_TOKEN` for the `claude` CLI / `llm-call.py`.

---

## Key Operational Notes

- The benchmark uses libevent's shipped OSS benchmarks (`bench`, `bench_cascade`,
  `bench_http`), built via CMake with `-DEVENT__DISABLE_BENCHMARK=OFF`
- Build with `RelWithDebInfo -march=native -fno-omit-frame-pointer` so perf has frames
- `sudo` is needed for `perf` hardware counters and syscall tracepoints
- Pin to fixed cores (`taskset`) and take the median of ≥ 3 runs — event-loop benchmarks
  are noisier than parser benchmarks; kernel scheduling and frequency scaling add variance
- Validate every delta with two runs: `perf`-on for direction, `perf`-off for the true number
