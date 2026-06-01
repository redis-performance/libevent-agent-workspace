# Experiments Summary

Single source of truth for experiment status. Keep in sync with the README counts.

| Status | Count |
|--------|-------|
| Accepted | 0 |
| Rejected | 2 |
| Parked | 0 |
| In Progress | 0 |

---

## Accepted (best-known chain)

_None yet. The first accepted experiment advances the `libevent` submodule tip._

## Rejected

- **EXP-001** (2026-06-01): Lazy `EPOLL_CTL_DEL` deferral (Tier 3a) — 0% on cascade_bench,
  +1.6% regression on cascade_chain (noise). Optimized untimed setup phase, not dispatch loop.
- **EXP-002** (2026-06-01): Skip `timerfd_settime` on NONBLOCK path (Tier 5a) — inapplicable;
  `USING_TIMERFD` is defined only when `!epoll_pwait2`, so this system uses `epoll_pwait2` and
  the timerfd block is dead code. Change was a no-op; 16% cascade_bench delta was machine noise.

## Parked

_None yet._
