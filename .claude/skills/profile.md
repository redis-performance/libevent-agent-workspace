# Skill: profile

Profile the benchmark and classify the bottleneck. libevent is an event loop dominated by
syscalls (epoll_wait/readv/writev), so the profile is 4-phase — you must separate libevent
self-CPU from kernel/syscall time before choosing an optimization.

## Steps

```bash
scripts/build-bench.sh     # builds with -O2/RelWithDebInfo -g -fno-omit-frame-pointer
scripts/run-profile.sh
```

`run-profile.sh` runs four phases:

### Phase 1 — Cycle budget (the routing gate)
`perf stat` for instructions, cycles, branches, branch-misses, cache-refs, cache-misses,
plus the kernel/user split. **Quantify the syscall share of wall-clock.**
- If `epoll_wait` + `readv` + `writev` dominate (> ~40%) → flag **syscall-bound** → next
  experiment goes to Tier 2/3 (iovec sizing, read caps, epoll_ctl churn), NOT userspace micro-opt.

### Phase 2 — Manifest-scoped attribution
`perf record -g` then `perf report` filtered to `config/hot-methods.yaml` symbols
(`event_base_loop`, `evbuffer_read`/`write_atmost`/`drain`/`expand_fast_`, `epoll_dispatch`,
`evmap_io_*`). Note the top-3 libevent symbols by self CPU %.

### Phase 3 — Off-CPU triage
`perf sched` / sleep-stack sampling. If the loop spends most time blocked (off-CPU), the
workload is latency-bound → **park CPU micro-opts**, report and stop.

### Phase 4 — Syscall attribution
`epoll_wait` enter/exit tracepoints + `cycles:u` (user-only) to cleanly attribute user CPU
to libevent code vs kernel. Report syscall count per workload iteration.

## Validation discipline
Run the binary TWICE: once with perf attached (direction / symbol ranking) and once without
(the TRUE timing delta — perf perturbs the loop). Report the median of ≥ 3 perf-off runs.

## Key Metrics to Report

| Metric | What to look for |
|--------|-----------------|
| Hottest libevent symbol | data plane (`buffer.c`) vs dispatch (`event.c`/`epoll.c`)? |
| Kernel/syscall % of wall-clock | > ~40% → syscall-bound (Tier 2/3) |
| syscall count / iteration | fewer is better; the lever for Tier 2 |
| IPC | < 2.0 suggests memory/branch stalls |
| branch-miss rate | > 3% → Tier 4 candidate |
| `epoll_ctl` calls | high = re-arm churn (Tier 3) |

## Output Format

```
Phase 1 — cycle budget:
  IPC : N.NN   branch-miss : N.NN%   cache-miss : N.NN%
  kernel/syscall share : NN%  → [syscall-bound | cpu-bound]

Phase 2 — top libevent symbols (self CPU):
  N.N%  evbuffer_read        [buffer.c]
  N.N%  event_base_loop      [event.c]
  N.N%  epoll_dispatch       [epoll.c]

Phase 4 — syscalls/iter: epoll_wait=N  readv=N  writev=N  epoll_ctl=N

Classification: Tier N — <reason> → feeds next selection round
```

After the first run, populate `config/hot-methods.yaml` with the measured `cpu_pct` values
and bump its `version`.
