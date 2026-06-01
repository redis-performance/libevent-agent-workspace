# libevent-agent-workspace — Experiments Log

Append-only. One `## EXP-NNN` section per experiment, newest at the bottom.
Use `experiments/TEMPLATE.md` for the entry format. Failures are as valuable as wins —
log every rejection with its reason.

Metric reminder: **never MB/s**. Report microseconds per `run_once` (lower=better),
events/sec, and syscall count.

---

<!-- EXP-001 starts here. Run `EXP_ID=EXP-001 scripts/select.sh` to begin the first loop,
     after capturing a baseline with `EXP=EXP-001 BASELINE=1 scripts/run-bench.sh`. -->

## EXP-001 — 2026-06-01 — EVBUFFER_MAX_READ_DEFAULT 4096 → 16384

## Status: REJECTED

---

## Selection Phase

Single-agent run (c4a, claude-sonnet-4-6). No profile data available (`perf` not installed for
kernel 6.14.0-1014-gcp on this machine). Technique chosen from Tier 2b in program.md.

**Hypothesis**: Increasing `EVBUFFER_MAX_READ_DEFAULT` from 4096 to 16384 reduces the number
of `readv` syscalls per unit of data consumed via `evbuffer_read`, improving throughput on
evbuffer-based socket workloads.

---

## Implementation Phase

**Change**: `buffer.c` line 137: `#define EVBUFFER_MAX_READ_DEFAULT 4096` → `16384`

Correctness: PASS (light gate — 370 tests ok, 33 skipped)

---

## Step 1: Benchmark (winner vs baseline)

Baseline: `experiments/baseline/bench-results/20260531-235235-...-BASELINE.txt`
EXP-001:  `experiments/EXP-001/bench-results/20260601-010933-....txt`

| Workload | Before (µs) | After (µs) | Δ% |
|----------|------------|-----------|-----|
| cascade_bench (-n 100 -a 1 -w 100) | 144 | 142 | -1.4% |
| cascade_chain (-n 100) | 278 | 277 | -0.4% |

Neither workload reaches the ≥2% accept threshold. The apparent 1.4% on cascade_bench is
within noise (stddev=6.99µs = 4.9% of mean; 2µs delta ≈ 0.3 standard errors of the median).

---

## Step 2: Profile

Skipped — `perf` not available on this kernel. Would require installing
`linux-tools-6.14.0-1014-gcp` / `linux-cloud-tools-6.14.0-1014-gcp`.

---

## Decision

**Status**: REJECT

**Reason**: The cascade benchmarks (`bench`, `bench_cascade`) use raw `recv`/`send` syscalls
directly — they do NOT call `evbuffer_read` or any evbuffer path. `EVBUFFER_MAX_READ_DEFAULT`
is only read in `evbuffer_read_buf` → `evbuffer_expand_fast_` and related chain-sizing
logic. Zero-effect change for these workloads. Delta is measurement noise.

**Key lesson**: The two OSS benchmark workloads (cascade_bench, cascade_chain) are pure
event-dispatch benchmarks — no evbuffer, no bufferevent. All Tier 1–2 evbuffer/I/O-batching
techniques have **zero effect** on these specific benchmarks. Future experiments for these
workloads must target Tier 3–5 (epoll_ctl churn, activation queue, per-backend dispatch).
Add perf tooling before the next run to actually profile and classify the bottleneck.

---

## Token Cost

| Phase | Agent | Model | Notes |
|-------|-------|-------|-------|
| single-agent | c4a | claude-sonnet-4-6 | single-turn overnight run |

---

## Lessons

1. `perf` must be installed on the target machine before starting the optimization loop.
   Without it, bottleneck classification is guesswork.
2. The cascade OSS benchmarks are purely event-dispatch workloads; they exercise
   `event_base_loop`, `epoll_dispatch`, and `evmap_io_active_` — NOT evbuffer.
   All Tier 1–2 changes are irrelevant for these benchmarks.
3. Next experiment should target Tier 3–5 (epoll churn or dispatch overhead) and
   should first verify that `perf` is available.
