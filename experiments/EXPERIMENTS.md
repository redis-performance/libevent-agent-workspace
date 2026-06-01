# libevent-agent-workspace — Experiments Log

Append-only. One `## EXP-NNN` section per experiment, newest at the bottom.
Use `experiments/TEMPLATE.md` for the entry format. Failures are as valuable as wins —
log every rejection with its reason.

Metric reminder: **never MB/s**. Report microseconds per `run_once` (lower=better),
events/sec, and syscall count.

---

<!-- EXP-001 starts here. Run `EXP_ID=EXP-001 scripts/select.sh` to begin the first loop,
     after capturing a baseline with `EXP=EXP-001 BASELINE=1 scripts/run-bench.sh`. -->

---

## EXT-PR-1866 — 2026-06-01 — Track & improve upstream io_uring fast path — TRACKING

External PR [libevent/libevent#1866](https://github.com/libevent/libevent/pull/1866)
(`widgetii`): opt-in io_uring multishot-recv fast path for socket bufferevents.
Full analysis, reproduced baseline, and improvement attempts in
[`EXT-PR-1866/README.md`](EXT-PR-1866/README.md).

- **Baseline reproduced** (c4, kernel 6.14): io_uring +35% (64p) / +47% (128p) at 64 KiB.
- **Perf tune V1** (buffer pool 128→1024, depth 256→512): **REJECT −11%** @128p —
  small L3-resident pool beats a 16 MiB cache-thrashing one.
- **Perf tune V2** (`IORING_SETUP_SINGLE_ISSUER`): reject (~0%, noise).
- `DEFER/COOP_TASKRUN` avoided — incompatible with the CQ-poll-via-epoll wakeup.
- **Conclusion**: perf config near-optimal; the real improvement is the documented
  timeout limitation (`IORING_OP_LINK_TIMEOUT` on each multishot recv) — a feature,
  not a tune. Identified as next step.
