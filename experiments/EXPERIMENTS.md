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

