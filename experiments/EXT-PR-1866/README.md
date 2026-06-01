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
change worth making — and the one azat is most likely to ask for.

### Improvement #2 IMPLEMENTED: multishot read-timeout enforcement

Branch `redis-performance/libevent:io-uring-read-timeout` (commit `d7493e51`, on top of
PR #1866). Closes the documented limitation.

- **Approach**: a libevent min-heap inactivity timer on the bufferevent (armed at multishot
  submit, **reset on each data CQE**, fires `BEV_EVENT_READING|BEV_EVENT_TIMEOUT` + cancels the
  multishot on idle). **Not `IORING_OP_LINK_TIMEOUT`** (the author's suggestion): a linked
  timeout is a one-shot *deadline*, but libevent read timeouts are *inactivity* timeouts;
  re-linking per CQE would defeat multishot. A socket-specific `adj_timeouts` makes
  `bufferevent_set_timeouts()` work on a live multishot.
- **Validation (c4)**: 2 regress tests (`read_timeout`, `read_timeout_after_enable`), each
  **fails without the respective fix**; full regress **377/377 ok**; **ASAN clean**;
  **throughput unchanged** (128p: 3035 vs 3048 — the timer is a no-op without a configured timeout).
- **7-maintainer review**: **GO-WITH-FIXES, 82/100**, 6/7 green. The panel **validated the
  design**: *"libevent min-heap timer WINS, decisively… LINK_TIMEOUT rejected. The author's
  reasoning is correct."* Their one real blocker — `set_timeouts()`-after-enable silently
  dropping the timeout (generic `adj_timeouts` can't see the out-of-epoll `ev_read`) — was a
  genuine hole I'd under-weighted as a "doc footnote"; now fixed + regression-guarded. The two
  style nits (merge the duplicate `if (trigger_user)`; comment the deferred arm) were folded in.

### Improvement #3 ATTEMPTED: zero-copy multishot recv (profile-driven)

**Profile first** (c4, software `task-clock`; GCP VMs have no HW PMU): at 64 KiB × 128p the
`--uring` path is **copy-bound** — `_copy_to_iter` 17% + `_copy_from_iter` 12% (kernel socket
copies, inherent to loopback) + **libc memcpy 17%** (the userspace `evbuffer_add()` copy of the
provided buffer) + ~10% memcg/page-zero. The one addressable userspace lever is the recv copy.

**Change** (branch `io-uring-zerocopy-recv`, `fdefb9dd`): reference the provided buffer via
`evbuffer_add_reference()` (released to the ring by a cleanup cb on chain free) instead of copying.
**Measured: 64 KiB ×64p 2702→3770 (+40%), ×128p 3048→3492 (+15%)**, 1 KiB unchanged. io_uring
regress green, full regress 377/377, ASAN clean.

**7-maintainer review: GO-WITH-FIXES, 45/100, 2/7 green — NOT mergeable as-is.** Two real blockers
(the review earned its keep):
1. **Teardown UAF** — a referenced provided buffer is in an *app-owned* evbuffer that can outlive
   `event_base_free()`; the cleanup then dereferences the freed `buf_relctx`/ring/base. The
   377/377 + ASAN-clean result proved nothing because every test frees bufferevents before the base
   and drains promptly. A genuine lifecycle bug I missed.
2. **Shared-pool fairness** — zero-copy unconditionally pins the shared 128-buffer pool; one slow
   consumer starves multishot for all connections. The +40%→+15% (64p→128p) drop *is* that pressure.
The panel also correctly **refuted** a (non-)bug three lenses raised (per-bid slot reuse is safe —
the kernel won't re-deliver a bid until released).

**To make it mergeable**: (a) a teardown-safe release context (refcount that survives the base, or
force-drain-on-teardown), (b) a copy-fallback under watermark / low free-buffer count to bound the
pool, (c) regress tests for evbuffer-outlives-base (ASAN) and pool exhaustion. The win is real and
wanted; the path is clear. Scoped as the next step.

### Improvement #3 — zero-copy recv, HARDENED to merge-ready (v2/v3)

The +40% was real but the v1 review (45/100) found a **teardown UAF** + a **shared-pool
fairness** flaw. Hardened across two more rounds, each re-reviewed by the 7-maintainer panel:

- **The UAF was real** — reproduced with a standalone program: an `evbuffer` (moved out of the
  bufferevent) freed *after* `event_base_free()` → **SEGV in `event_io_uring_buf_release_`**.
  The 377/377 + ASAN-clean suite had missed it because no test let an evbuffer outlive the base.
- **v2**: refcounted `event_io_uring_bufpool` that **outlives the base** (cleanup never touches
  freed `base->io_uring`) + low-water copy-fallback to bound the shared pool. **Re-review:
  GO-WITH-FIXES 80/100, B1 closed ✓, B2 closed ✓** ("a real root-cause fix, not a band-aid").
  But it caught a **new** refcount leak (ref reserved before `evbuffer_add_reference`; leaks on
  failure) — and the sharp insight that the leak *"corrupts the B2 bound"* by inflating `inflight`.
- **v3**: undo the reservation on `add_reference` failure + `EVUTIL_ASSERT(inflight>0)` guard +
  checkpatch decl fixes + the two regress tests (`recv_ref_outlives_base`, `pool_pressure`).

**Final state (branch `io-uring-zerocopy-recv`, `7ccce898`):** +39% (64p) / +13% (128p),
full regress **379/379**, ASAN clean (incl. the once-SEGV repro), throughput-cost-free bound.
All three blockers the panels raised (teardown UAF, fairness, refcount leak) are closed; the
chair's stated merge conditions ("fix the leak, the checkpatch decls, and the assert") are met.

**Net for PR #1866**: two upstreamable follow-ups — `io-uring-read-timeout` (82/100, closes the
documented limitation) and `io-uring-zerocopy-recv` (a profile-driven +39% that the review loop
turned from a UAF-carrying draft into a hardened, tested, bounded change).
