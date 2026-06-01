# Experiments Summary

Single source of truth for experiment status. Keep in sync with the README counts.

| Status | Count |
|--------|-------|
| Accepted | 1 |
| Rejected | 13 |
| Parked | 0 |
| In Progress | 0 |

---

## Accepted (best-known chain)

- **EXP-004** (2026-06-01): EPOLLONESHOT for non-persistent events (Tier 3/5) — **-18%
  cascade_chain** (192→158 µs). Eliminates 100 `epoll_ctl(DEL)` calls per `run_once` by
  registering non-persistent, sole-watcher events with `EPOLLONESHOT`; kernel auto-disarms
  after fire. cascade_bench unaffected (EV_PERSIST events bypass new code path entirely).

## Rejected

- **EXP-001** (2026-06-01): Lazy `EPOLL_CTL_DEL` deferral (Tier 3a) — 0% on cascade_bench,
  +1.6% regression on cascade_chain (noise). Optimized untimed setup phase, not dispatch loop.
- **EXP-002** (2026-06-01): Skip `timerfd_settime` on NONBLOCK path (Tier 5a) — inapplicable;
  `USING_TIMERFD` is defined only when `!epoll_pwait2`, so this system uses `epoll_pwait2` and
  the timerfd block is dead code. Change was a no-op; 16% cascade_bench delta was machine noise.
- **EXP-003** (2026-06-01): Guard `epoll_apply_changes` + `event_changelist_remove_all_` behind
  `n_changes > 0` in `epoll_dispatch` (Tier 5a) — 0% on both workloads. ~10 ns/iter saving is
  below the machine noise floor (baseline stddev 9.85 µs). Benchmarks are 85–90% syscall-bound;
  sub-1% userspace savings are unmeasurable at 5×25 samples.
- **EXP-005** (2026-06-01): `gettime` cache-warming for `event_add` timeout path (Tier 5a) — 0%
  improvement. Expected saving (~1.5 µs from 99 eliminated vDSO clock calls) is below the 8–17 µs
  noise floor. Confirms: userspace savings < ~3–5 µs per run_once are unmeasurable at current
  sample count.
- **EXP-006** (2026-06-01): Drop `ioctl(FIONREAD)` before `evbuffer_read` (Tier 2c) — 0% on
  cascade benchmarks. Cascade benchmarks use raw `recv`/`send` and never call `evbuffer_read`.
  Tier 2 is inapplicable to the current bench suite; requires `bench_http` to validate.
- **EXP-007** (2026-06-01): `#pragma GCC optimize("O3")` on `event_process_active_single_queue`
  + `event_process_active` (Tier 4a) — **REGRESSION**: cascade_bench +17% (106→124 µs),
  cascade_chain +3% (154→159 µs). O3 bloated the dispatch path and thrashed L1 icache.
  Confirms: compiler optimize/hot/cold pragmas on dispatch code consistently regress
  icache-sensitive loops.
- **EXP-008** (2026-06-01): Skip `epoll_ctl(ADD→EEXIST)` on ONESHOT re-arm via `ctx->oneshot`
  bits 2–3 (Tier 3/5 follow-on) — no improvement; cascade_chain 166→172 µs (+3.6%).
  The failed ADD is a kernel fast-path (EEXIST without readiness check); direct MOD triggers
  ep_item_poll and is no faster. ADD→EEXIST→MOD is already at optimum after EXP-004.

## Rejected (continued)

- **EXP-009** (2026-06-01): Fast path in `evmap_io_del_` for ONESHOT single-reader (Tier 4c) —
  REJECTED. cascade_chain 172→154 µs (-10.5%), but unaffected cascade_bench also improved
  124→107 µs (-13.7%) — confirms all improvement is machine load noise. Expected code saving
  (~15 instructions × 100 events ≈ 1–2 µs) permanently below ~6 µs noise floor.
- **EXP-010** (2026-06-01): Increase `INITIAL_NEVENT` from 32 to 64 in `epoll.c` (Tier 5a) —
  REJECTED. cascade_bench: 107→106 µs (-0.9%, noise), cascade_chain: 154→155 µs (+0.6%, noise).
  Zero effect: cascade benchmarks return 1 event per `epoll_wait` (serial workload), so the
  event array never fills and the auto-grow path is never triggered. INITIAL_NEVENT only affects
  parallel workloads where N > INITIAL_NEVENT events fire simultaneously.
- **EXP-011** (2026-06-01): EPOLLET instead of EPOLLONESHOT for non-persistent sole-watcher events
  (Tier 3c) — **CORRECTNESS FAILURE** (not benchmarked). `main/simpleread`, `main/multiple`,
  `main/fork` hang. EPOLLET misses pre-existing unread data on re-registration; the ONESHOT→MOD
  re-arm triggers `ep_item_poll` (kernel readiness re-check) which is required for correctness.
  EPOLLET only works when callbacks fully drain the fd to EAGAIN (not guaranteed by libevent API).
- **EXP-012** (2026-06-01): Tier 6a single-threaded fast path — cache `base->th_base_lock != NULL`
  as local `with_lock` in `event_process_active_single_queue` to skip `current_event_waiters` load
  per callback. cascade_bench: 106→106 µs (0%), cascade_chain: 155→153 µs (-1.3%, within noise).
  Expected saving (~100 ns) is permanently below the 5–7 µs noise floor. Closes all remaining
  Tier 3–6 dispatch-loop techniques. Future progress requires evbuffer benchmarks (Tier 1–2) or
  REPETITIONS ≥ 20 to lower the noise floor.
- **EXP-013** (2026-06-01): `NUM_READ_IOVEC` 4→8 in `buffer.c` (Tier 2a iovec sizing) — 0% on
  both workloads (cascade_bench: 106→107 µs, cascade_chain: 153→154 µs, both within noise).
  Confirmed by construction: cascade benchmarks use raw `recv`/`send`, never calling `evbuffer_read`.
  Entire Tier 1–2 evbuffer space is inapplicable to current bench suite. Technique is valid for
  evbuffer workloads (e.g., bench_http + wrk) but unmeasurable without an HTTP load generator.
- **EXP-014** (2026-06-01): Tier 6b cross-thread notify skip — guard `EVBASE_NEED_NOTIFY` in
  `event_callback_activate_nolock_` behind `base->th_base_lock != NULL`. cascade_bench: 107→108 µs
  (+0.9%, noise), cascade_chain: 154→154 µs (0%). Expected saving ~400 ns (1 BSS load × 100
  activations) is permanently below the 5–7 µs noise floor. Formally closes the last untried Tier
  6 technique. All program.md tiers are now exhausted for the current cascade benchmark suite.

## Parked

_None yet._
