# Experiments Summary

Single source of truth for experiment status. Keep in sync with the README counts.

| Status | Count |
|--------|-------|
| Accepted | 0 |
| Rejected | 1 |
| Parked | 0 |
| In Progress | 0 |

---

## Accepted (best-known chain)

_None yet. The first accepted experiment advances the `libevent` submodule tip._

## Rejected

| EXP | Date | Technique | Result | Reason |
|-----|------|-----------|--------|--------|
| EXP-001 | 2026-06-01 | EVBUFFER_MAX_READ_DEFAULT 4096→16384 | cascade_bench -1.4%, cascade_chain -0.4% (both noise) | Cascade benchmarks do not use evbuffer_read; Tier 2 changes have zero effect on these workloads |

## Parked

_None yet._
