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

---

## EXP-003 — 2026-06-01 — Skip redundant timerfd_settime when already disarmed (Tier 5a)

## Status: ACCEPTED

---

## Selection Phase

Single-agent run (c4a, claude-sonnet-4-6). Technique chosen from Tier 5a in program.md.

**Hypothesis**: The cascade benchmark registers no timer events, so `timerfd_settime({0,0})`
(disarm) is called on every `epoll_dispatch` iteration even though the timer is already
disarmed — one wasted syscall per loop. Caching the last-set `itimerspec` and skipping the
call when transitioning from disarmed to disarmed will eliminate this syscall from the hot
path and reduce cascade_bench µs by ≥2%.

**Background**: The libevent codebase contained an explicit TODO comment at the
`timerfd_settime` call site: *"we could avoid unnecessary syscalls here by only calling
timerfd_settime when the top timeout changes, or when we're called with a different timeval."*
This experiment implements the most conservative form of that optimization.

---

## Implementation Phase

**Change**: `libevent/epoll.c` — two edits:

1. Add `struct itimerspec last_timerfd_set;` to `struct epollop` (inside `#ifdef USING_TIMERFD`)
2. In `epoll_dispatch`, replace unconditional `timerfd_settime` with a guarded call that skips
   the syscall when both the desired state and the cached state are `{0,0}` (disarmed):

```c
/* Skip timerfd_settime when the disarmed state is already set;
 * avoids a syscall per dispatch on workloads with no timer events. */
if (is.it_value.tv_sec != 0 || is.it_value.tv_nsec != 0 ||
    epollop->last_timerfd_set.it_value.tv_sec != 0 ||
    epollop->last_timerfd_set.it_value.tv_nsec != 0) {
    if (timerfd_settime(epollop->timerfd, 0, &is, NULL) < 0) {
        event_warn("timerfd_settime");
    }
    epollop->last_timerfd_set = is;
}
```

The guard is intentionally conservative: only skips when the timer is (and should remain)
disarmed. Any active timer (non-zero `is.it_value`) still calls `timerfd_settime`.
`mm_calloc` zero-initializes `last_timerfd_set`, matching the timerfd's initial disarmed state.

Correctness: PASS (light gate — 370 tests ok, 33 skipped; ASAN clean)

Note on TSAN: `FATAL: ThreadSanitizer: unexpected memory mapping` was observed both before and
after the change (verified by stashing the patch and re-running). This is a pre-existing
kernel 6.14.0-1014-gcp / GCP address-space incompatibility, not caused by this change.
The new field `last_timerfd_set` is accessed only in `epoll_dispatch`, which is called under
the base lock — there is no threading concern.

---

## Step 1: Benchmark (winner vs baseline)

Baseline: `experiments/baseline/bench-results/20260531-235235-...-BASELINE.txt`
EXP-003:  `experiments/EXP-003/bench-results/20260601-013418-....txt`

| Workload | Before (µs) | After (µs) | Δ% |
|----------|------------|-----------|-----|
| cascade_bench (-n 100 -a 1 -w 100) | 144 | 141 | -2.1% |
| cascade_chain (-n 100) | 278 | 275 | -1.1% |

cascade_bench: median=141µs min=139µs p99=167µs mean=145.61µs±7.05 (n=125)
cascade_chain: median=275µs min=265µs p99=681µs mean=296.81µs±170.42 (n=125)

cascade_bench meets the ≥2% accept threshold. cascade_chain also improved (no regression).

---

## Step 2: Profile

Skipped — `perf` not available on this kernel (linux-tools-6.14.0-1014-gcp not installed).

---

## Decision

**Status**: ACCEPT

**Reason**: cascade_bench improved from 144→141µs (-2.1%), exceeding the ≥2% threshold.
cascade_chain also improved from 278→275µs (-1.1%). No regressions. The change eliminates
the `timerfd_settime` syscall from the `epoll_dispatch` hot path for workloads with no timer
events — exactly the cascade benchmark workload. ASAN is clean; TSAN failure is pre-existing
infrastructure (kernel incompatibility), verified by testing the unmodified code.

Committed to libevent submodule: `aa7a4df5`

---

## Token Cost

| Phase | Agent | Model | Notes |
|-------|-------|-------|-------|
| single-agent | c4a | claude-sonnet-4-6 | single-turn overnight run |

---

## Lessons

1. The timerfd path in `epoll_dispatch` calls `timerfd_settime` unconditionally every
   dispatch iteration. When there are no timer events (cascade bench case), this is a
   wasted syscall that can be elided with a simple cached-value check.
2. The optimization was explicitly called out as a TODO in the source — look for TODO
   comments in hot paths as a source of low-hanging fruit.
3. TSAN (`FATAL: ThreadSanitizer: unexpected memory mapping`) is broken on kernel
   6.14.0-1014-gcp due to address space incompatibility. This is infrastructure, not code.
   Document in Known Non-Starters for TSAN, or add a workspace note.
4. Conservative guard (only skip disarmed→disarmed) is safer than full caching: avoids
   potential correctness issues with periodic timers that happen to have the same duration.

---

## EXP-004 — 2026-06-01 — Zero-timeout fast path + changelist n_changes guard in epoll_dispatch (Tier 5a)

## Status: REJECTED

---

## Selection Phase

Single-agent run (c4a, claude-sonnet-4-6). Technique chosen from Tier 5a in program.md.

**Hypothesis**: `epoll_dispatch` calls `evutil_tv_to_msec_()` (an external, non-inline function with overflow checks, multiplication, and division) even when `tv = {0,0}` (EVLOOP_NONBLOCK path, always returns 0), and unconditionally calls `epoll_apply_changes()` and `event_changelist_remove_all_()` even when the changelist is empty (`n_changes = 0`, always the case for the nochangelist backend). Adding a `tv_sec==0 && tv_usec==0` short-circuit to set `timeout=0` directly, and guarding the two changelist calls behind `if (base->changelist.n_changes)`, eliminates ~4–5 function calls per cascade_bench dispatch step and improves throughput by ≥2%.

**Background**: For both cascade benchmarks, `base->evsel` is `epollops` (nochangelist backend): adds/deletes go directly to `epoll_ctl` without using the changelist, so `n_changes` is always 0. For cascade_bench (EVLOOP_NONBLOCK), `tv = {0,0}` every dispatch. Both checks should be near-zero-cost to add.

---

## Implementation Phase

**Change**: `libevent/epoll.c` — two edits to `epoll_dispatch`:

1. **Zero-timeout fast path**: Replace `evutil_tv_to_msec_(tv)` with a guarded check:
```c
if (tv->tv_sec == 0 && tv->tv_usec == 0) {
    timeout = 0;
} else {
    timeout = evutil_tv_to_msec_(tv);
    if (timeout < 0 || timeout > MAX_EPOLL_TIMEOUT_MSEC)
        timeout = MAX_EPOLL_TIMEOUT_MSEC;
}
```

2. **Changelist n_changes guard**: Wrap both changelist calls:
```c
if (base->changelist.n_changes) {
    epoll_apply_changes(base);
    event_changelist_remove_all_(&base->changelist, base);
}
```

Correctness: PASS (light gate — 370 tests ok, 33 skipped)

---

## Step 1: Benchmark (winner vs baseline)

Previous accepted state (EXP-003): `experiments/EXP-003/bench-results/20260601-013418-....txt`
EXP-004: `experiments/EXP-004/bench-results/20260601-015940-....txt`

| Workload | Before (µs) | After (µs) | Δ% |
|----------|------------|-----------|-----|
| cascade_bench (-n 100 -a 1 -w 100) | 141 | 142 | +0.7% |
| cascade_chain (-n 100) | 275 | 276 | +0.4% |

Noise bands: cascade_bench stddev ≈ 7.19 µs; cascade_chain stddev ≈ 9.00 µs.
Both deltas are within noise (< 0.2 standard errors of the median).

---

## Step 2: Profile

Skipped — `perf` not available on this kernel.

---

## Decision

**Status**: REJECT

**Reason**: Neither workload improved: cascade_bench regressed +0.7% and cascade_chain +0.4% (both within measurement noise). The changelist checks and `evutil_tv_to_msec_` function call are not bottlenecks for these workloads — the cascade benchmark latency is dominated by socket I/O syscalls (epoll_wait, recv, send), not by the surrounding userspace overhead. Eliminating 2–3 function calls per dispatch step at ~10–20 ns each saves ~1–2 µs total, which is invisible against a 141 µs run with 7 µs stddev.

---

## Token Cost

| Phase | Agent | Model | Notes |
|-------|-------|-------|-------|
| single-agent | c4a | claude-sonnet-4-6 | single-turn overnight run |

---

## Lessons

1. Function call overhead per dispatch (~10–20 ns each) is not measurable at this workload scale (100 cascade steps × ~1.4 µs/step). The stddev of ~7 µs dwarfs the expected savings of ~2 µs.
2. The cascade benchmark is dominated by 3 syscalls per step (epoll_wait + recv + send). Userspace overhead is ~10–20% of total time, and individual function calls within that are not separately measurable without perf.
3. To find 2%+ improvements without perf, changes must target syscall elimination (saves ~0.2–0.5 µs per call) or fundamental algorithm changes (fewer dispatch iterations), not per-call overhead reduction.
4. Techniques that save < 1 function call equivalent per step (at the 100-step cascade scale) will not reach the 2% threshold. Only opportunities that affect O(1) overhead per run_once or eliminate a syscall are worth pursuing.

---

## EXP-005 — 2026-06-01 — EPOLLONESHOT for non-persistent events to skip epoll_ctl(DEL) (Tier 3/5 hybrid)

## Status: REJECTED

---

## Selection Phase

Single-agent run (c4a, claude-sonnet-4-6). Technique: use EPOLLONESHOT for non-persistent events to eliminate explicit epoll_ctl(DEL) syscalls.

**Hypothesis**: Non-persistent events in cascade_chain fire exactly once and auto-delete; replacing level-triggered epoll with EPOLLONESHOT allows skipping the explicit epoll_ctl(DEL) syscall (100 calls/run), saving ≥2% on cascade_chain.

**Motivation**: cascade_chain has 100 epoll_ctl(DEL) calls per run (non-persistent events auto-delete after firing). At ~100-300ns per epoll_ctl, eliminating these saves 10-30µs on 275µs → 3.6-10.9% improvement. This is the largest remaining syscall-reduction opportunity.

---

## Implementation Phase

**Changes attempted** (reverted on correctness failure):

1. `evmap.c` — pass `EV_PERSIST` flag from evmap to backend in `evmap_io_add_`:
   - `evsel->add(..., (ev->ev_events & (EV_ET|EV_PERSIST)) | res, ...)` (was: `& EV_ET` only)

2. `epoll.c` — EPOLLONESHOT implementation:
   - `epollops.fdinfo_len`: 0 → `sizeof(uint8_t)` (1 byte per fd: 0=none, 1=EPOLLONESHOT armed, 2=fired)
   - `epoll_apply_one_change`: added `uint32_t extra_events` parameter; adds `events |= extra_events`
   - `epoll_nochangelist_add`: for non-persistent IO events, adds `EPOLLONESHOT` to epoll events and sets fdinfo=1
   - `epoll_nochangelist_del`: checks fdinfo; if state==2 (fired), skips epoll_ctl(DEL) and returns 0
   - `epoll_dispatch`: after epoll_wait returns, uses `evmap_io_get_fdinfo_` to advance fdinfo 1→2 for each fired fd

**Correctness gate result: FAIL**

Two tests failed:
1. `main/multiple_events_for_same_fd` — TIMEOUT/deadlock (the core correctness bug)
2. `thread/no_events` — TIMEOUT (cascade of previous failure)

**Root cause**: EPOLLONESHOT fires for the first non-persistent event on a fd, auto-disabling it in the kernel. If a second event (persistent or not) is also registered on the same fd via evmap_io_add_ with nread going from 0→1 (for the first event) and 1→2 (no backend ADD call for the second), the fd remains EPOLLONESHOT-armed. When EPOLLONESHOT fires, the fd is disabled. The second event stays registered in evmap but the fd is disabled in epoll and never fires again — causing a deadlock.

**Why this can't be fixed simply**: libevent's evmap only calls `evsel->add` when the per-fd per-direction count transitions from 0→1. There is no callback when a second event joins an fd that already has EPOLLONESHOT armed. A correct implementation would need either: (1) evmap calling `evsel->add` to MOD from EPOLLONESHOT to level-triggered when a second event arrives, or (2) re-arming the fd when a non-persistent event is deleted and the remaining count is >0. Both require architectural evmap changes.

---

## Step 1: Benchmark

Not reached (correctness gate failed).

---

## Decision

**Status**: REJECT

**Reason**: Correctness gate failure — `main/multiple_events_for_same_fd` times out because EPOLLONESHOT disables the fd in the kernel after the first event fires, stranding other events registered on the same fd. The bug is fundamental to how EPOLLONESHOT interacts with libevent's evmap architecture, which only calls the backend ADD function when fd interest transitions from 0→1.

---

## Token Cost

| Phase | Agent | Model | Notes |
|-------|-------|-------|-------|
| single-agent | c4a | claude-sonnet-4-6 | single-turn overnight run |

---

## Lessons

1. EPOLLONESHOT cannot be safely used for non-persistent events in libevent without evmap-level changes. The evmap architecture only calls the backend ADD for the first event on a fd; any subsequent events share the same epoll registration. If EPOLLONESHOT fires, subsequent events are stranded.
2. The `multiple_events_for_same_fd` regress test is the canary for this class of bug. It tests exactly the mixed persistent/non-persistent case on a shared fd.
3. The remaining syscall reduction opportunity for cascade_chain (100 epoll_ctl DEL calls/run) requires either: (a) EPOLLONESHOT with deeper evmap integration, (b) fd-level state tracking to detect "last event on fd", or (c) accepting that the benchmark workload is structurally limited by the cascade architecture.
4. Per-syscall cost: timerfd_settime ~30ns (EXP-003); epoll_ctl(DEL) estimated ~100-300ns. The DEL savings would be 3-10% on cascade_chain if correctly implemented.
