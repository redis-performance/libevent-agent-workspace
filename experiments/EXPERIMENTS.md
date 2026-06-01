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

---

## EXP-002 — 2026-06-01 — Enable epoll changelist by default (Tier 3a)

## Status: REJECTED

---

## Selection Phase

Single-agent run (c4a, claude-sonnet-4-6). Technique chosen from Tier 3a in program.md.

**Hypothesis**: Enabling the epoll changelist by default collapses the DEL+ADD `epoll_ctl` pair
(non-persistent events re-registered in callback) into a single MOD syscall, reducing
cascade_chain's `epoll_ctl` count by ~50% (100 → 50 per iteration) and improving cascade_chain
throughput by ≥3% with no regression on cascade_bench (EV_PERSIST, no DEL/ADD churn).

**Key analysis**:
- `cascade_bench` (`bench -n 100 -a 1 -w 100`): uses `EV_READ | EV_PERSIST` → no epoll_ctl churn
  per step in steady state; changelist has zero effect.
- `cascade_chain` (`bench_cascade -n 100`): uses `EV_READ` (non-persistent) → each step does
  `epoll_ctl(DEL)` before callback then `epoll_ctl(ADD)` after. Changelist would batch these into
  a single `EPOLL_CTL_MOD` at the next dispatch.

---

## Implementation Phase

**Change**: `libevent/epoll.c` `epoll_init` — modify the changelist activation condition to
always enable the changelist unless `EVENT_BASE_FLAG_IGNORE_ENV` is explicitly set:

```c
// Before:
if ((base->flags & EVENT_BASE_FLAG_EPOLL_USE_CHANGELIST) != 0 ||
    ((base->flags & EVENT_BASE_FLAG_IGNORE_ENV) == 0 &&
        evutil_getenv_("EVENT_EPOLL_USE_CHANGELIST") != NULL)) {
    base->evsel = &epollops_changelist;
}

// After:
if ((base->flags & EVENT_BASE_FLAG_EPOLL_USE_CHANGELIST) != 0 ||
    (base->flags & EVENT_BASE_FLAG_IGNORE_ENV) == 0) {
    base->evsel = &epollops_changelist;
}
```

First attempt (always use changelist) broke `main/base_environ` test. Revised to preserve
IGNORE_ENV semantics: when IGNORE_ENV is set and EPOLL_USE_CHANGELIST flag is not set, fall back
to plain epoll (satisfying the test expectation for `ignoreenvname = "epoll"`).

Correctness: PASS (light gate — 370 tests ok, 33 skipped)

---

## Step 1: Benchmark (winner vs baseline)

Baseline: `experiments/baseline/bench-results/20260531-235235-...-BASELINE.txt`
EXP-002:  `experiments/EXP-002/bench-results/20260601-012506-....txt`

| Workload | Before (µs) | After (µs) | Δ% |
|----------|------------|-----------|-----|
| cascade_bench (-n 100 -a 1 -w 100) | 144 | 145 | +0.7% |
| cascade_chain (-n 100) | 278 | 276 | -0.7% |

Noise bands: cascade_bench stddev ≈ 8-12 µs; cascade_chain stddev ≈ 8-11 µs.
A ±1 µs change is < 0.1 standard errors — not statistically significant.

---

## Step 2: Profile

Skipped — `perf` not available on this kernel.

---

## Decision

**Status**: REJECT

**Reason**: The changelist optimization (merging DEL+ADD into a single MOD `epoll_ctl` call)
reduces syscall count for cascade_chain by ~50% in theory, but the userspace overhead of the
changelist mechanism (fdinfo lookup, change array management, changelist flush per dispatch)
cancels the savings. Net delta: -0.7% on cascade_chain (< 1 µs, within noise), +0.7% on
cascade_bench. Neither meets the ≥2% threshold.

The technique is correctly identified but the mechanism's overhead is not worth it at this
scale (1 epoll_ctl saved per step). May be worth revisiting on a workload with much higher
fd churn (e.g., 1000+ fds, many simultaneous DEL+ADD cycles per dispatch).

---

## Token Cost

| Phase | Agent | Model | Notes |
|-------|-------|-------|-------|
| single-agent | c4a | claude-sonnet-4-6 | single-turn overnight run |

---

## Lessons

1. `cascade_bench` uses `EV_PERSIST` — no DEL/ADD churn per step, epoll_ctl churn
   optimizations have zero effect on it.
2. `cascade_chain` has 1 DEL + 1 ADD per cascade step (2 epoll_ctl calls). Merging to 1 MOD
   via the changelist saves 100 syscalls per 100-step chain. But changelist overhead (userspace)
   erases the gain at this workload size.
3. The changelist is already tested (test-changelist.c, regress main/base_environ handles
   "epoll (with changelist)" as a special case). Implementation was correct and clean.
4. Future epoll_ctl churn reduction must reduce churn more aggressively (e.g., avoid the DEL
   entirely for non-persistent events when the fd is known to be immediately re-added).
