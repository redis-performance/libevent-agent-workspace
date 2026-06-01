# Experiments Summary

Single source of truth for experiment status. Keep in sync with the README counts.

| Status | Count |
|--------|-------|
| Accepted | 3 |
| Rejected | 8 |
| Parked | 0 |
| In Progress | 0 |

---

## Accepted (best-known chain)

| EXP | Date | Technique | Result | Commit |
|-----|------|-----------|--------|--------|
| EXP-003 | 2026-06-01 | Skip redundant timerfd_settime when already disarmed (Tier 5a) | cascade_bench -2.1%, cascade_chain -1.1% | aa7a4df5 |
| EXP-007 | 2026-06-01 | Lazy update_time_cache: skip clock_gettime when EVLOOP_NONBLOCK + empty heap (Tier 4c) | cascade_bench -5.6%, cascade_chain 0% | a9437a38 |
| EXP-008 | 2026-06-01 | Skip gettimeofday in update_time_cache, use evutil_gettime_monotonic_ directly (Tier 4c) | cascade_bench +0.7% (noise), cascade_chain -2.2% | 563fa02e |

## Rejected

| EXP | Date | Technique | Result | Reason |
|-----|------|-----------|--------|--------|
| EXP-001 | 2026-06-01 | EVBUFFER_MAX_READ_DEFAULT 4096→16384 | cascade_bench -1.4%, cascade_chain -0.4% (both noise) | Cascade benchmarks do not use evbuffer_read; Tier 2 changes have zero effect on these workloads |
| EXP-002 | 2026-06-01 | Enable epoll changelist by default (Tier 3a) | cascade_bench +0.7%, cascade_chain -0.7% (both noise) | Changelist userspace overhead (fdinfo lookup, array management) cancels the 1 saved epoll_ctl syscall per cascade step |
| EXP-004 | 2026-06-01 | Zero-timeout fast path + changelist n_changes guard in epoll_dispatch (Tier 5a) | cascade_bench +0.7%, cascade_chain +0.4% (both noise) | Function call savings (~2 µs) invisible vs. 7 µs stddev; syscalls dominate, not userspace per-dispatch overhead |
| EXP-005 | 2026-06-01 | EPOLLONESHOT for non-persistent events to skip epoll_ctl(DEL) (Tier 3/5) | Correctness fail | multiple_events_for_same_fd deadlock: EPOLLONESHOT fires and disables fd when first event fires, stranding other events on same fd; evmap only calls backend ADD for 0→1 transition |
| EXP-006 | 2026-06-01 | timerfd absolute-deadline caching to skip redundant timerfd_settime (Tier 5a) | No change (dead code) | USING_TIMERFD is disabled when EVENT__HAVE_EPOLL_PWAIT2 is defined (Linux ≥5.11); the entire timerfd optimization path is compiled out; dispatch uses epoll_pwait2 with inline nanosecond timeout instead |
| EXP-009 | 2026-06-01 | Pass NULL epev to epoll_ctl(EPOLL_CTL_DEL) to skip struct construction | cascade_bench 0%, cascade_chain +0.4% (noise) | memset+2-field overhead (~4ns) invisible vs kernel syscall cost (~500ns); not a measurable bottleneck at cascade scale |
| EXP-010 | 2026-06-01 | Skip update_time_cache for blocking dispatches with empty timer heap | Correctness fail | `event_base_gettimeofday_cached` requires update_time_cache for consistent time across all callbacks in a dispatch cycle; NONBLOCK guard in EXP-007 is a semantic boundary, not just a heuristic |
| EXP-011 | 2026-06-01 | Lazy tv_cache populate in gettimeofday_cached + skip update_time_cache for empty heap | cascade_bench 0%, cascade_chain +0.7% (noise) | vDSO clock_gettime(MONOTONIC) is ~5-10ns on this GCP VM; 100 calls × 10ns = 1µs — below the ~19µs noise floor; time-cache optimizations are exhausted |

## Parked

_None yet._
