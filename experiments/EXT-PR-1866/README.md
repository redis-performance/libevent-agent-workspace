# EXT-PR-1866 — Track & improve: io_uring fast path for socket bufferevents

External upstream PR we are tracking (not one of our own optimization experiments).

- **Upstream**: [libevent/libevent#1866](https://github.com/libevent/libevent/pull/1866) by `widgetii`
- **Head**: `widgetii/libevent` @ `ac1caa8e` (fetch via `refs/pull/1866/head`)
- **Size**: +2032/−12, 22 files, 9 commits. State: OPEN, **all CI green**, no maintainer review yet.
- **Supersedes**: the experimental #1356 (closed); closes #1019.

## What it does

Opt-in io_uring(7) fast path for socket bufferevent reads/writes, gated per
`event_base` via `EVENT_BASE_FLAG_IO_URING`. Multishot `recv` with a provided
buffer ring (reads skip epoll once enabled); writes batch in the SQ and submit
once per loop iteration; wakeup polls the ring fd directly (no eventfd read).
Degrades gracefully without liburing / on non-Linux / with `EVENT_NOIO_URING`.
ABI-additive (one flag + one internal `event_base` field).

Clean layering: all ring state in `event_io_uring.c`; bufferevent consumes it
via accessors (`event_io_uring_submit_readv_/writev_`, `_recv_multishot_`,
`_cqe_more_`, `_cqe_buf_id_`, `_buf_addr_`, …) and never includes `liburing.h`.

## Reported performance (author, Linux 6.18, socketpair ping-pong)

`test/bench_bufferevent_io --bytes B --rounds R --pairs P [--uring]`:

| payload | pairs | syscall MiB/s | io_uring MiB/s | Δ |
|---|---:|---:|---:|---:|
| 64 KiB | 1 | 2116 | 2193 | +4% |
| 64 KiB | 64 | 1183 | 1926 | **+63%** |
| 64 KiB | 128 | 1093 | 1866 | **+71%** |
| 1 KiB | 16 | 154 | 244 | +58% |

Wins concentrate at high concurrency / small payloads (multishot amortises
per-round submission overhead).

## Documented known limitation (improvement target #2)

Bufferevent read/write **timeouts are not enforced while a multishot recv is in
flight** (only at submission boundaries). Author's intended fix:
`IORING_OP_LINK_TIMEOUT` linked to each recv SQE. Left for a follow-up.

## Our improvement targets (ranked)

1. **Ring setup flags** — `IORING_SETUP_DEFER_TASKRUN | COOP_TASKRUN |
   SINGLE_ISSUER` in `event_io_uring_init_`. A single-threaded event loop is the
   textbook case for DEFER_TASKRUN (task_work deferred to `io_uring_enter`,
   fewer IPIs/wakeups). Cheap, low-risk, expected single-digit-to-20% throughput
   on the syscall-bound path. **Primary — measurable, minimal diff.**
2. **Timeout enforcement** via `IORING_OP_LINK_TIMEOUT` linked to recv — closes
   the documented limitation; what azat would ask for. Medium effort.
3. **`IORING_OP_SEND_ZC`** (zero-copy send) for large writes — bigger win at
   large payloads; needs notification-CQE handling. Higher effort.

## Method

Reproduce on the c4 GCP box (x86, kernel 6.14, liburing-dev): build the PR with
liburing, run `bench_bufferevent_io` syscall-vs-`--uring` to get our own
baseline, then apply target #1, rebuild, re-bench, compare. Validate with
`make verify` + the new `regress_io_uring` group + ASAN. Log numbers below.

## Results (c4 GCP, x86, kernel 6.14, liburing 2.5; bench_bufferevent_io, median of 3)

**Baseline reproduced** — the io_uring win holds on our host:

| point | syscall MiB/s | io_uring MiB/s | Δ |
|---|---:|---:|---:|
| 64 KiB × 64p | 2007 | **2702** | +35% |
| 64 KiB × 128p | 2079 | **3048** | +47% |
| 1 KiB × 16p | 441 | 487 | +10% |
| 1 KiB × 64p | 426 | 487 | +14% |

(Lower absolute Δ than the author's 6.18 host, but the multishot win is confirmed.)

### Perf-improvement attempts — both REJECTED (config is well-tuned)

| Variant | Change | io_uring 128p | Verdict |
|---|---|---:|---|
| baseline | — | 3048 | — |
| V1 | `BUF_NBUFS 128→1024`, `QUEUE_DEPTH 256→512` | 2698 | **REJECT −11%** |
| V2 | `IORING_SETUP_SINGLE_ISSUER` (+ fallback) | 3044 | reject (~0%, noise) |

Both passed the `io_uring/*` regress group. Findings:
- **Enlarging the provided-buffer pool *hurts*.** Buffer exhaustion is NOT the
  bottleneck; the 128×16 KiB pool (2 MiB) stays L3-resident and hot, while a
  16 MiB pool thrashes cache. The author's small pool is deliberately right.
- **`SINGLE_ISSUER` is a no-op here** — the loop is already a single submitter and
  the internal sync it elides is not on the hot path for this workload.
- **`DEFER_TASKRUN`/`COOP_TASKRUN` were NOT tried** — the design polls the ring fd
  via epoll ("POLLIN asserted when the CQ has unread entries"), and deferred
  task-run only posts CQEs on the issuer's `io_uring_enter`, which would strand
  completions while the loop blocks in `epoll_wait` → missed wakeups. Confirmed
  architecturally incompatible; correctly avoided.

**Conclusion:** the PR's performance configuration is near-optimal on this host;
the cheap, safe knobs do not improve it. The genuine remaining improvement is
**correctness completeness, not throughput**: the documented timeout limitation
(target #2, `IORING_OP_LINK_TIMEOUT` linked to each multishot recv). That is the
change worth making — and the one azat is most likely to ask for — but it is a
real feature (per-bufferevent linked-timeout SQE + timeout-CQE handling + tests),
not a one-line tune. Scoped as the next step.
