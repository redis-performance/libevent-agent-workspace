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

| EXP | Date | Technique | Result | Reason |
|-----|------|-----------|--------|--------|
| EXP-001 | 2026-06-01 | EVBUFFER_MAX_READ_DEFAULT 4096→16384 | cascade_bench -1.4%, cascade_chain -0.4% (both noise) | Cascade benchmarks do not use evbuffer_read; Tier 2 changes have zero effect on these workloads |
| EXP-002 | 2026-06-01 | Enable epoll changelist by default (Tier 3a) | cascade_bench +0.7%, cascade_chain -0.7% (both noise) | Changelist userspace overhead (fdinfo lookup, array management) cancels the 1 saved epoll_ctl syscall per cascade step |

## Parked

_None yet._
