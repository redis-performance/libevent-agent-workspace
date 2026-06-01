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
