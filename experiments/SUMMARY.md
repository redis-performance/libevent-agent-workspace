# Experiments Summary

Single source of truth for experiment status. Keep in sync with the README counts.

| Status | Count |
|--------|-------|
| Accepted | 1 |
| Rejected | 8 |
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

## Parked

_None yet._
