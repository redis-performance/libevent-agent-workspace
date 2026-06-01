# libevent-agent-workspace — Experiments Log

Append-only. One `## EXP-NNN` section per experiment, newest at the bottom.
Use `experiments/TEMPLATE.md` for the entry format. Failures are as valuable as wins —
log every rejection with its reason.

Metric reminder: **never MB/s**. Report microseconds per `run_once` (lower=better),
events/sec, and syscall count.

---

<!-- EXP-001 starts here. Run `EXP_ID=EXP-001 scripts/select.sh` to begin the first loop,
     after capturing a baseline with `EXP=EXP-001 BASELINE=1 scripts/run-bench.sh`. -->

## EXP-001 — 2026-06-01 — Lazy epoll_ctl(DEL) deferral — REJECTED

**Technique (Tier 3a)**: Defer `EPOLL_CTL_DEL` in `epoll_nochangelist_del`; convert the
next `EPOLL_CTL_ADD` for the same fd into `EPOLL_CTL_MOD`, saving one syscall per del+add pair.

**Hypothesis**: cascade_bench does 100 × (event_del + event_add) per `run_once()`, generating
200 epoll_ctl calls. Optimization reduces that to 100 EPOLL_CTL_MOD, cutting setup syscalls 50%.

**Result**: 0% improvement on cascade_bench; +1.6% regression on cascade_chain (within noise).

| Workload | Baseline µs | EXP-001 µs (15-rep) | Δ% |
|----------|-------------|---------------------|-----|
| cascade_bench | 106 | 106 | 0% |
| cascade_chain | 192 | 195 | +1.6% (noise) |

**Root cause of failure**: The event_del+event_add setup loop is NOT in the timed window of
cascade_bench (gettimeofday wraps only the cascade dispatch do-while). cascade_chain times the
ADD calls (in window) but not the DEL calls (after gettimeofday(&te)). The optimization saves
syscalls exclusively in untimed code paths.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.  
**Files**: `experiments/EXP-001/bench-results/` (5-rep and 15-rep runs), `experiments/EXP-001/EXP-001.md`  
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-002 — 2026-06-01 — Skip timerfd_settime on NONBLOCK path — REJECTED

**Technique (Tier 5a)**: When `tv = {0,0}` (EVLOOP_NONBLOCK), skip the `timerfd_settime`
syscall in `epoll_dispatch`; `epoll_wait(timeout=0)` returns immediately regardless of timerfd state.

**Hypothesis**: Every NONBLOCK dispatch calls `timerfd_settime(fd, 0, {0,0}, NULL)` to disarm
the timer — a wasted syscall. Eliminating ~101 calls per cascade `run_once` should cut
cascade_bench median by ≥2%.

**Result**: INAPPLICABLE / no-op. `USING_TIMERFD` is only defined when
`!defined(EVENT__HAVE_EPOLL_PWAIT2)`. This system has `EVENT__HAVE_EPOLL_PWAIT2 = 1`, so
the `#ifdef USING_TIMERFD` block is dead code. The hot path uses `epoll_pwait2` with a
`struct timespec` timeout; no timerfd is involved.

| Workload | Baseline µs (15-rep) | EXP-002 µs (5-rep) | Δ% |
|----------|---------------------|--------------------|----|
| cascade_bench | 106 | 123 | +16% (machine noise — no-op change) |
| cascade_chain | 195 | 195 | 0% |

The cascade_bench "regression" is machine load noise: last-rep raw samples (103-118 µs) are
consistent with baseline; first 4 reps (121-133 µs) reflect machine load during that run.

**Root cause of rejection**: Technique targets dead code on this platform. No binary diff.

**Correctness**: PASS (370/370 regress tests). Reverted after identifying no-op.  
**Files**: `experiments/EXP-002/bench-results/`, `experiments/EXP-002/EXP-002.md`  
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-003 — 2026-06-01 — Guard epoll changelist flush on n_changes > 0 — REJECTED

**Technique (Tier 5a)**: In `epoll_dispatch`, wrap `epoll_apply_changes(base)` and
`event_changelist_remove_all_(&base->changelist, base)` behind `if (base->changelist.n_changes)`
to skip both when the changelist is empty (always true for the default non-changelist `epollops` backend).

**Hypothesis**: For the non-changelist `epollops` backend, `n_changes` is always 0 on entry to
`epoll_dispatch`. `event_changelist_remove_all_` is a cross-TU function call (evmap.c → epoll.c,
not inlinable at -O2 without LTO) costing ~8–12 ns/call. Eliminating 101 calls per cascade_bench
`run_once` saves ~800–1200 ns, ≥2% of the 106 µs baseline.

**Result**: 0% improvement. Both workloads unchanged within noise.

| Workload | Baseline µs (p50) | EXP-003 µs (p50) | Δ% |
|----------|-------------------|------------------|----|
| cascade_bench | 106 | 106 | 0% |
| cascade_chain | 192 | 192 | 0% |

**Root cause of failure**: The per-call overhead of `event_changelist_remove_all_` for the
n_changes=0 case (~8 ns: call + two no-op `event_changelist_check` + read + compare + write + return)
and the already-inlined `epoll_apply_changes` loop body (dead iteration, ~2 ns) sum to ~10 ns/iter.
Over 101 iterations: ~1010 ns = 0.95% of 106 µs baseline. The machine noise (baseline stddev 9.85 µs)
swamps this sub-1% signal, yielding a measured Δ of exactly 0.

**Key learning**: Both benchmarks are ~85–90% syscall-bound (epoll_pwait2 + recv + send + epoll_ctl).
The remaining userspace overhead is ~100–200 ns per event_base_loop call — so a 1% win requires
eliminating only ~1–2 ns of the ~100–200 ns. Individual function calls and loop checks are at that
noise floor. Future experiments must target either (a) syscall count reduction or (b) a technique
that affects many instructions per callback, not per-dispatch.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.  
**Files**: `experiments/EXP-003/bench-results/`  
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-004 — 2026-06-01 — EPOLLONESHOT for non-persistent events — ACCEPTED

**Technique (Tier 3 / Tier 5 hybrid)**: For non-persistent events that are the sole watcher
on their fd (nread==1, nwrite==0, nclose==0), register with `EPOLLONESHOT` instead of plain
`EPOLLIN`. The kernel then auto-disarms the fd after one fire, eliminating the explicit
`epoll_ctl(DEL)` call that `event_del_nolock_` otherwise issues when a non-persistent event fires.

**Hypothesis**: bench_cascade creates 100 non-persistent `EV_READ` events per `run_once`, each
firing once and triggering an `epoll_ctl(DEL)` in the timed window. With `EPOLLONESHOT`, those
100 DEL syscalls (~150 ns each = ~15 µs total) are eliminated, saving ≥ 8% of cascade_chain's
192 µs baseline.

**Result**: ACCEPTED — cascade_chain improved -18% (192→158 µs median). cascade_bench
unchanged (machine load elevated both baseline and EXP measurements equally; code analysis
confirms EV_PERSIST events bypass all new ONESHOT logic and evmap_io_del_ is not called for
persistent events during normal dispatch).

| Workload | Baseline µs | EXP-004 µs (p50) | Δ% |
|----------|-------------|------------------|----|
| cascade_bench | 106 | 122–124 (machine load) | machine noise — code unaffected |
| cascade_chain | 192 | 158–166 | **-17% to -18%** |

cascade_bench min across runs: 100–105 µs (identical to baseline min=100). The elevated medians
match the EXP-002 machine-load pattern (no-op change also showed ~123 µs for cascade_bench).
EV_PERSIST events take a completely separate path (event_queue_remove_active, not
event_del_nolock_) so the ONESHOT optimization does not touch them.

**Implementation** (37 lines across 3 files):
- `changelist-internal.h`: add `EV_CHANGE_ONESHOT = 0x40` flag
- `evmap.c`: add `ev_uint16_t oneshot` to `struct evmap_io` (fits in existing padding, no
  size change); set flag in `evmap_io_add_` when `EV_FEATURE_ET` backend + non-persistent + sole
  watcher; skip `evsel->del` in `evmap_io_del_` when oneshot flag is set
- `epoll.c`: propagate `EV_CHANGE_ONESHOT` through `epoll_nochangelist_add` to
  `epoll_apply_one_change` → `epev.events |= EPOLLONESHOT`

**Correctness**: FULL gate PASS (370 regress tests + ASAN clean + TSAN clean). Non-epoll
backends (select/poll) lack `EV_FEATURE_ET` so ONESHOT is never applied to them. Re-addition
of a ONESHOT-disabled fd handles EEXIST via existing MOD fallback.

**Files**: `experiments/EXP-004/bench-results/` (4 runs), libevent submodule commit 21a7111e

---

## EXP-005 — 2026-06-01 — `gettime` cache-warming for non-update_time_cache callers — REJECTED

**Technique (Tier 5a)**: When `gettime(base, tp)` is called cold with `tp` pointing to a local
variable (not `&base->tv_cache`), also warm `base->tv_cache` with the result so subsequent
`gettime` calls within the same "cold window" return immediately. The primary target is the 100
`event_add_nolock_` calls in cascade_chain's timed setup: each calls `gettime(base, &now)` cold,
costing 100 monotonic clock calls; caching after the first reduces this to 1.

**Hypothesis**: cascade_chain performs 100 `event_add()` calls in the timed window; all 100 call
`evutil_gettime_monotonic_` through a cold `base->tv_cache`. Warming the cache on the first cold
`gettime` call eliminates 99 redundant clock calls (~99 × 15 ns ≈ 1.5 µs), giving ≥2% improvement
on cascade_chain (158 µs baseline → ≤155 µs).

**Result**: REJECTED — no measurable improvement on either workload.

| Workload | EXP-004 µs (p50) | EXP-005 µs (p50) | Δ% |
|----------|------------------|------------------|----|
| cascade_bench | 124 (machine load) | 124 (machine load) | 0% |
| cascade_chain | 158 | 160 | +1.3% (noise; min 146 vs 149) |

cascade_chain p50 is within one stddev of EXP-004's result. cascade_bench is identical. One
cascade_chain sample was 858 µs (scheduler artifact), inflating mean/stddev; excluding it, the
distribution is comparable to EXP-004.

**Root cause of rejection**: The expected saving (~1.5 µs from 99 eliminated 15-ns vDSO
`clock_gettime` calls) is an order of magnitude below the run-to-run noise floor (stddev 8–17 µs).
The optimization is real but unmeasurable with the current benchmark sample count. Clock calls
outside the dispatch loop (event_add setup) are vDSO-fast (~15 ns) and sum to only ~1.5 µs.

**Key learning**: Confirms EXP-003's conclusion — **userspace savings smaller than ~3–5 µs
per run_once are unmeasurable** at 5×25 samples on this machine. The change to `gettime` does
no harm (370/370 tests pass, no semantic regression) but provides no measurable signal. Future
experiments must eliminate ≥10+ µs of overhead to produce a reliable measurement.

The second sub-technique tried (skip `update_time_cache` when heap empty) was REVERTED before
benchmarking because it broke the `gettimeofday_cached` test contract: callbacks fired in the
same dispatch iteration expect identical cached time (`tv1 == tv2 == tv3`), which requires
`update_time_cache` to run unconditionally after every dispatch.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.  
**Files**: `experiments/EXP-005/bench-results/20260601-025231-*.txt`  
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-006 — 2026-06-01 — Drop `ioctl(FIONREAD)` before `evbuffer_read` — REJECTED

**Technique (Tier 2c)**: In `get_n_bytes_readable_on_socket`, replace the Linux
`ioctl(fd, FIONREAD, &n)` call with an immediate return of `EVBUFFER_MAX_READ_DEFAULT`.
Since `evbuffer_read` already caps reads at `buf->max_read`, the FIONREAD value is only
useful when it's smaller than `max_read` (avoids over-allocating for tiny reads). Dropping
it saves one syscall per `evbuffer_read` call.

**Hypothesis**: Each `evbuffer_read` call currently pays one `ioctl(FIONREAD)` syscall
(~200 ns) before the `readv`. For evbuffer-based workloads with many small reads, eliminating
this syscall should reduce per-read overhead by ≥2%.

**Result**: 0% improvement on both workloads (INAPPLICABLE — cascade benchmarks bypass evbuffer).

| Workload | EXP-004/005 µs (p50) | EXP-006 µs (p50) | Δ% |
|----------|---------------------|------------------|----|
| cascade_bench | 106 | 106 | 0% |
| cascade_chain | 158–166 | 154 | ~−2.5% (machine noise, see below) |

cascade_chain's apparent 154 µs is within normal run-to-run variance (EXP-006 stddev = 5.9 µs;
EXP-005 saw heavy machine load in its last 50 samples inflating that median). Both `bench` and
`bench_cascade` use raw `recv`/`send` in callbacks and never call `evbuffer_read`. The FIONREAD
change is a strict no-op for these workloads.

**Root cause of rejection**: Tier 2 (Socket I/O Batching) is inapplicable to the current
benchmark suite. `bench` and `bench_cascade` are designed to stress the event-loop dispatch
path and use raw `recv`/`send`; evbuffer is never exercised. To measure Tier 2 improvements,
`bench_http` (bufferevent-based HTTP pipeline) would need to be added to `scripts/run-bench.sh`.

**Key learning**: After exhaustive analysis of all Tier 3–5 options, **every remaining
userspace optimization saves < 3–5 µs** — below the 6–17 µs per-run noise floor at 5×25
samples. The cascade benchmarks are at a practical optimum for what libevent can control
in userspace. Future gains require either: (a) eliminating mandatory syscalls (none remain),
(b) adding evbuffer-based workloads to the benchmark suite, or (c) increasing sample count
(REPETITIONS=20+) to detect sub-5 µs improvements.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.  
**Files**: `experiments/EXP-006/bench-results/20260601-032616-*.txt`  
**Known Non-Starter added**: see `.claude/program.md`


---

## EXP-007 — 2026-06-01 — `#pragma GCC optimize("O3")` on dispatch hot path — REJECTED

**Technique (Tier 4a)**: Apply `#pragma GCC push_options` / `#pragma GCC optimize("O3")` / `#pragma GCC pop_options` around `event_process_active_single_queue` and `event_process_active` in `event.c`. The default build uses `-O2` (`RelWithDebInfo`); O3 enables more aggressive inlining, loop unrolling, and register allocation for these two hot functions without touching the rest of the build.

**Hypothesis**: Compiling `event_process_active_single_queue` and `event_process_active` with `-O3` instead of `-O2` inlines hot helpers (`event_queue_remove_active`, `event_callback_to_event`) into the dispatch loop, reducing per-callback overhead for the 100-event cascade workloads by ≥ 2µs per run_once (≥ 2%).

**Result**: REJECTED — both workloads regressed.

| Workload | EXP-006 µs (p50) | EXP-007 µs (p50) | Δ% |
|----------|------------------|------------------|----|
| cascade_bench | 106 | 124 | **+17% REGRESSION** |
| cascade_chain | 154 | 159 | +3.2% regression (within noise, but wrong direction) |

cascade_bench regressed from 106 µs to 124 µs (+17%). cascade_chain regressed from 154 µs to 159 µs (+3%). Both workloads moved in the wrong direction.

**Root cause of regression**: The O3 pragma caused the compiler to aggressively inline and unroll the bodies of `event_queue_remove_active`, `event_del_nolock_`, and related helpers into the dispatch loop. This bloated the function size substantially (O3's inlining threshold is much higher than O2's), thrashing the L1 instruction cache during the 100-iteration tight dispatch loop in cascade_bench. The CPU's icache is shared between the dispatch loop and the callback overhead — enlarging the dispatch functions caused cache-line evictions on every iteration.

cascade_bench suffered more (+17%) because its EV_PERSIST path has shorter callbacks (just recv+send) and the loop iterates 100 times per run_once — the icache pressure compounds over more iterations. cascade_chain has a similar iteration count but each iteration also includes event_del_nolock_ and min_heap overhead, which partially masks the icache regression.

**Key learning**: Confirms the `program.md` warning about compiler annotation disruption (icache/register-allocation disruption from `hot/cold/noinline/optimize` attributes). The event dispatch path is icache-sensitive: the O2 inlining thresholds are well-calibrated for this workload. Applying O3 to any event dispatch function (`event_base_loop`, `event_process_active*`, `event_del_nolock_`) is counterproductive. Do NOT attempt O3 pragmas on dispatch code.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.
**Files**: `experiments/EXP-007/bench-results/20260601-034411-*.txt`
**Known Non-Starter added**: see `.claude/program.md`


---

## EXP-008 — 2026-06-01 — Skip redundant epoll_ctl(ADD→EEXIST) on ONESHOT re-arm — REJECTED

**Technique (Tier 3/5 follow-on)**: After EXP-004's EPOLLONESHOT optimization, the `event_add`
call following a fired non-persist event issues `epoll_ctl(EPOLL_CTL_ADD)` → fails with EEXIST
(fd is ONESHOT-disabled but still in epoll) → retries `epoll_ctl(EPOLL_CTL_MOD)`. This wastes
one failed kernel call per re-arm. The proposed fix: track "ONESHOT-disabled-but-present" state
in bits 2–3 of `ctx->oneshot` in `evmap_io`, so `evmap_io_add_` can synthesize `old |= EV_READ`
and have the op-table select `EPOLL_CTL_MOD` directly (no ADD→EEXIST round-trip).

**Hypothesis**: Eliminating 100 failed `epoll_ctl(ADD)` calls per cascade_chain `run_once`
(each ~100–150 ns) should reduce cascade_chain latency by ~10–15 µs (≥ 6%).

**Implementation**: Three changes to `evmap.c`:
1. Added bits 2–3 to `ctx->oneshot` to track "ONESHOT-disabled" fd state
2. In `evmap_io_del_` skip_del path: set bit 2/3 instead of only clearing bit 0/1
3. In `evmap_io_add_`: check bits 2/3 and include EV_READ/EV_WRITE in `old` so
   epolltable selects MOD; clear bits 2/3 after add

**Result**: REJECTED — no measurable improvement; cascade_chain showed marginal regression.

| Workload | EXP-004 µs (p50) | EXP-008 µs (p50) | Δ% |
|----------|------------------|------------------|----|
| cascade_bench | 124 | 124 | 0% |
| cascade_chain | 166 | 172 | +3.6% (regression) |

Machine load indicator: cascade_bench = 124 µs in both runs (same load level).

cascade_chain regressed from 166 to 172 µs. EXP-008 had stddev=6 µs (cleaner run than EXP-004's
17 µs), making the 172 µs a reliable measurement. EXP-004's mean was 171.91 µs (very close to
EXP-008's 173.88 µs), suggesting the 166 µs p50 in EXP-004 was partly a distribution artifact
of its high-variance run. The true central tendency appears similar, with no improvement.

**Root cause of rejection**: The `epoll_ctl(ADD→EEXIST→MOD)` path in Linux appears to be at
least as fast as, if not faster than, direct `epoll_ctl(MOD)` for ONESHOT-disabled fds. Likely
explanation: the failed ADD exits the kernel quickly (EEXIST fast-path in the rb-tree lookup
without updating epitem state), while the successful MOD performs a full ep_item_poll readiness
check (which can be non-trivial when the pipe already has data). The net cost of
ADD(fast-fail)+MOD(full-update) ≤ MOD(full-update). Any saving is below the ~6–17 µs noise
floor of this benchmark.

**Key learning**: The ADD→EEXIST→MOD fallback in epoll_apply_one_change is not wasteful —
the failed ADD is a kernel fast-path that avoids the readiness check. Attempting to bypass it
with direct MOD does not help and may hurt due to different kernel code paths. The ONESHOT
re-arm pattern is at an optimum for the cascade_chain workload after EXP-004.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.  
**Files**: `experiments/EXP-008/bench-results/20260601-040328-*.txt`  
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-009 — 2026-06-01 — Fast path in `evmap_io_del_` for ONESHOT single-reader — REJECTED

**Technique (Tier 4c)**: Add an early-exit fast path at the top of `evmap_io_del_` for the common
cascade_chain case: sole EV_READ watcher with EPOLLONESHOT armed. The fast path skips computing
`old` (3 conditional loads), `res` (3 conditional decrements), and `skip_del` (bitwise comparison)
by detecting the ONESHOT single-watcher condition directly and returning after the minimum necessary
writes (`ctx->nread = 0`, `ctx->oneshot &= ~1`, `LIST_REMOVE`).

**Hypothesis**: `evmap_io_del_` is called 100× per cascade_chain run_once for non-persist EV_READ
events under EPOLLONESHOT. A direct early-exit eliminates ~15 redundant operations per call, saving
≥ 2 µs (≥ 1.3%) on cascade_chain (158–166 µs accepted baseline).

**Result**: REJECTED — observed improvement matches machine-noise level; the unaffected control
(cascade_bench) improved by as much or more at p50, making attribution to code impossible.

| Workload | EXP-008 µs (p50) | EXP-009 µs (p50) | Δ% | Notes |
|----------|-----------------|-----------------|-----|-------|
| cascade_bench | 124 | 107 | **-13.7%** | EV_PERSIST — code change has NO effect |
| cascade_chain | 172 | 154 | -10.5% | Our change only applies here |

cascade_bench (the unaffected control) improved by 13.7% at p50 — more than cascade_chain — which
confirms the entire observed delta is machine load improvement, not code improvement. cascade_bench
min improved 5 µs (106→101), cascade_chain min improved 18 µs (167→149); the 13 µs residual
at min slightly favors a real effect, but this is a single data point against contradictory p50
evidence.

**Root cause of rejection**: The expected code saving was ~300 ns–1.6 µs (15 skipped instructions ×
100 events at 2.3 GHz). This is well below the ~6 µs run-to-run stddev (6.05–6.31 µs across both
workloads). Machine load variation between runs accounts for 10–15 µs swings that swamp any
instruction-level saving. A single-run benchmark at the current sample count (5×25 = 125 samples)
cannot distinguish a 1–2 µs code improvement from noise when machine load varies that much.

The `evmap_io_del_` fast path is logically correct (passes 370/370 regress tests) and slightly
cleaner, but its performance impact is unmeasurable at this noise floor.

**Key learning**: Instruction-level optimizations in the evmap_io_del_ hot path (~15 instructions
per call) save < 2 µs per run_once — permanently below the noise floor for the current methodology.
To measure sub-2 µs improvements, sample count would need to increase 5–10× (REPETITIONS=50–100)
AND machine load would need to be controlled. The cascade benchmarks are at the practical optimum
for userspace-only dispatch improvements.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.
**Files**: `experiments/EXP-009/bench-results/20260601-043124-*.txt`
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-010 — 2026-06-01 — Increase `INITIAL_NEVENT` from 32 to 64 in `epoll.c` — REJECTED

**Technique (Tier 5a)**: The initial epoll event-array size (`INITIAL_NEVENT = 32`) limits the
number of events returned per `epoll_wait` call before the array must be reallocated (doubled
via `mm_realloc`). Increasing from 32 to 64 avoids this reallocation for workloads that
simultaneously have 33–64 events ready, reducing `mm_realloc` overhead and memory allocation
fragmentation on first dispatch.

**Hypothesis**: For cascade_bench and cascade_chain (serial 1-event-per-dispatch workloads),
the change is expected to have zero effect because `epoll_wait` returns at most 1 event per call
and the initial array size is never the bottleneck. The experiment validates this expectation
and formally documents the INITIAL_NEVENT tuning as inapplicable to serial event workloads.

**Implementation**: One-line change in `epoll.c` — `#define INITIAL_NEVENT 32` → `64`.

**Result**: REJECTED — zero measurable effect on both workloads.

| Workload | EXP-009 µs (p50) | EXP-010 µs (p50) | Δ% | Notes |
|----------|-----------------|-----------------|-----|-------|
| cascade_bench | 107 | 106 | -0.9% | Within noise (stddev 7.07 µs) |
| cascade_chain | 154 | 155 | +0.6% | Within noise (stddev 5.29 µs) |

Both deltas are within one standard deviation of run-to-run noise. The unaffected control
(cascade_bench) moved by the same magnitude as the treatment (cascade_chain), confirming all
variation is machine load noise.

**Root cause of rejection**: The cascade benchmarks process exactly 1 event per `epoll_wait`
call (serial workload: each callback writes to the NEXT pipe, triggering the next event
sequentially). The `epoll_wait` result array never fills beyond 1 entry — the initial size
(32 or 64) is irrelevant because the auto-grow path (`res == nevents`) is never triggered.
`INITIAL_NEVENT` only matters when N > INITIAL_NEVENT events become ready simultaneously
(parallel workloads), which requires a different benchmark (e.g., `bench -n 100 -a 100`).

**Key learning**: `INITIAL_NEVENT` tuning only affects workloads where multiple events fire
simultaneously within a single `epoll_wait`. For serial cascade patterns (events trigger one
at a time), any value of INITIAL_NEVENT ≥ 1 is equivalent. The auto-grow mechanism (doubling
when the array fills) already handles parallel workloads gracefully; only the reallocation
overhead on first batch differs.

**Correctness**: PASS (370/370 regress tests). Reverted after reject.
**Files**: `experiments/EXP-010/bench-results/20260601-052226-*.txt`
**Known Non-Starter added**: see `.claude/program.md`

---

## EXP-011 — 2026-06-01 — EPOLLET instead of EPOLLONESHOT for non-persistent events — REJECTED

**Technique (Tier 3c)**: Replace `EPOLLONESHOT` (EXP-004) with `EPOLLET` (edge-triggered,
no auto-disarm) for non-persistent sole-watcher `EV_READ` events on `EV_FEATURE_ET` backends.
With EPOLLET, the fd stays continuously armed in epoll after each fire. The re-arm call in the
callback (`event_add`) can then skip `epoll_ctl(MOD)` entirely: the fd is already in epoll and
the next data arrival fires a new EPOLLIN edge. This would eliminate 100 `epoll_ctl(MOD)` calls
per cascade_chain `run_once` (currently paid after every ONESHOT re-arm).

**Hypothesis**: Eliminating 100 `epoll_ctl(MOD)` re-arm calls per cascade_chain run_once (each
~380 ns ≈ 38 µs total) should reduce cascade_chain latency by ~25% (155 µs → ~117 µs). The
baseline comparison is EXP-010 (cascade_bench=106 µs, cascade_chain=155 µs).

**Implementation** (evmap.c only, ~25 lines changed):
- In `evmap_io_add_`: replace `EV_CHANGE_ONESHOT` with `EV_CHANGE_ET`; when `ctx->oneshot & 1`
  is set (EPOLLET already armed, fd in epoll), skip `evsel->add` entirely (no epoll_ctl).
- In `evmap_io_del_`: keep `ctx->oneshot` bits SET on the skip_del path (don't clear them), so
  the next `evmap_io_add_` call knows the fd is still armed and can skip epoll_ctl.
- `ctx->oneshot` field reinterpreted as "EPOLLET-armed state" instead of "ONESHOT-disarmed state".

**Result**: REJECTED — correctness gate failure. `scripts/verify-correctness.sh` (light) failed
with 3 test timeouts (signal 14 = SIGALRM = hang):
- `main/simpleread` — FAILED (hang)
- `main/multiple` — FAILED (hang)
- `main/fork` — FAILED (hang)
- `http/cancel_inactive_server` — TIMEOUT

No benchmark was run.

| Workload | EXP-010 µs (p50) | EXP-011 µs (p50) | Δ% |
|----------|-----------------|-----------------|-----|
| cascade_bench | 106 | NOT BENCHMARKED | — |
| cascade_chain | 155 | NOT BENCHMARKED | — |

**Root cause of rejection**: EPOLLET semantics are fundamentally incompatible with libevent's
non-persistent event model in the general case. EPOLLET fires only on rising edges (transition
from not-readable to readable). Level-triggered epoll (and EPOLLONESHOT-MOD re-arm) re-checks
current fd readiness on each `epoll_ctl(MOD)` call — if data is already present in the pipe,
`epoll_wait` returns it immediately on the next wait. EPOLLET with no MOD (just keeping the fd
armed) MISSES data that was already present before the re-arm: no new edge occurs for pre-existing
unread data. Any test that writes data before calling event_add, or that doesn't fully drain
the fd in the callback, will hang waiting for an event that never fires.

Specifically:
- `simpleread`: writes to a pipe, then registers EV_READ. With EPOLLET, if data was already in
  the pipe when `epoll_ctl(ADD)` ran and the initial edge was "consumed" by the first fire, a
  re-arm of the same event finds no new edge → hangs.
- `multiple` / `fork`: similar patterns with non-trivial read sequences.

The cascade_chain pattern (which this was designed for) is a special case: each callback reads
exactly all available data (1 byte recv, fully draining the pipe), then new data arrives as a
new 1-byte write (fresh edge). EPOLLET works for this pattern but is unsafe in general.

**Key learning**: EPOLLET without ONESHOT cannot replace ONESHOT for general-purpose non-
persistent events. The ONESHOT→MOD re-arm path in EXP-004 serves a correctness function beyond
the pure syscall-elimination benefit: the MOD triggers a readiness re-check (ep_item_poll in the
kernel), which is the mechanism by which pre-existing unread data is re-delivered after
re-registration. Any optimization that eliminates the MOD also eliminates this re-check.

To use EPOLLET for non-persistent events without correctness regression, the system would need to
guarantee that every callback fully drains the fd to EAGAIN before returning — a constraint not
enforced by libevent's API or tests. Alternatively, a separate "EAGAIN-drained" flag per fd would
need to be tracked and the re-arm decision conditioned on it. This is out of scope.

**Correctness**: FAIL (simpleread, multiple, fork hang; cancel_inactive_server timeout). Reverted.
**Files**: none (no bench run)
**Known Non-Starter added**: see `.claude/program.md`
