# libevent Optimization Playbook

Agent-readable catalogue of optimization techniques for an event-notification library,
organized by tier and expected gain. Inspired by AutoKernel's program.md.

Read this before each experiment to choose the next technique to try.
After profiling, use the **Bottleneck Classification** section to pick the right tier.

Scope every change to `config/hot-methods.yaml`. Do not optimize control-plane / setup code.

---

## Bottleneck Classification

Run `scripts/run-profile.sh` and classify before choosing a tier:

| Profile Signal | Bottleneck Type | Go to Tier |
|---------------|-----------------|------------|
| `evbuffer_*` (read/write/drain/expand) hottest; allocation visible | **evbuffer data plane** | 1 |
| `readv`/`writev`/`epoll_wait` syscalls > ~40% of wall-clock | **Socket I/O / syscall-bound** | 2 |
| `epoll_ctl` / `evmap_io_*` / `event_add_nolock_` hot | **epoll_ctl churn** | 3 |
| `event_process_active_single_queue` hot; branch-miss > 3% | **Activation queue** | 4 |
| backend dispatch (`epoll_dispatch`) hot; IPC < 2.0 | **Per-backend dispatch** | 5 |
| lock/atomic symbols (`EVTHREAD_*`, `evthread_*`) visible single-threaded | **Lock/sync overhead** | 6 |

When unsure, profile first. If off-CPU dominates (Phase 3), the consumer is latency-bound —
park CPU micro-opts.

---

## Tier 1 — evbuffer Data Plane (expected: 5–25%)

`buffer.c` chain machinery is where bytes flow. Allocation behavior dominates the data plane.

### 1a. Chain allocation reuse / pooling
`evbuffer_chain_new` mallocs per chain. A freelist of recently-freed chains (size-classed)
avoids malloc/free churn on steady-state read/drain cycles.

### 1b. Tune `evbuffer_expand_fast_` growth heuristic
The chain-growth policy (when to realign vs allocate vs double) affects allocation count.
Measure realign-vs-alloc ratio; adjust the threshold.

### 1c. Keep `evbuffer_get_length` O(1) and inlinable
Called from many sites. Ensure it stays a field read, not a chain walk; verify inlining.

### 1d. Reduce copies in `evbuffer_add` / `evbuffer_drain`
Avoid redundant `memcpy` when appending to a chain that already has room; advance
`misalign`/`off` instead of copying on drain.

---

## Tier 2 — Socket I/O Batching (expected: 5–20%, syscall-bound)

`evbuffer_read` (`readv`) and `evbuffer_write_atmost` (`writev`) carry the syscalls.

### 2a. iovec sizing for readv/writev
Larger / better-sized iovecs reduce syscall count per byte. Measure bytes-per-syscall.

### 2b. Read cap (`EVBUFFER_MAX_READ`) tuning
The per-read byte cap trades syscall count against transient allocation. Profile both.

### 2c. Drop the pre-read `FIONREAD` ioctl
If `evbuffer_read` queries readable bytes before reading, that ioctl is a syscall that can
sometimes be elided in favor of a fixed-size readv. Measure carefully — affects sizing.

### 2d. Write high-water-mark coalescing
Batch small writes until a high-water mark to emit fewer, larger `writev`s.

---

## Tier 3 — epoll_ctl Churn Reduction (expected: 3–15%)

`epoll_ctl` per fd add/del/mod is costly. High churn = re-arming interest more than needed.

### 3a. Avoid redundant re-arming
`event_add_nolock_` → `evmap_io_*` → `epoll_ctl`. If read/write interest toggles every loop,
coalesce so `epoll_ctl` only fires when the interest mask actually changes.

### 3b. Persistent events / `EV_PERSIST`
Where an event is repeatedly re-added, a persistent event avoids del+add cycles.

### 3c. Edge-triggered (`EV_ET`) where safe
Edge-triggering reduces epoll churn but changes semantics — gate behind full correctness.

---

## Tier 4 — Event Activation Queue (expected: 3–10%)

### 4a. Branch elimination in `event_process_active_single_queue`
The per-callback dispatch loop has predictable branches that can be hoisted/simplified.

### 4b. Activation-queue traversal
Reduce pointer chasing / improve locality when walking active events.

### 4c. Callback dispatch overhead
Trim per-callback bookkeeping (counters, debug guards) on the hot path.

---

## Tier 5 — Per-Backend Dispatch (expected: 2–8%)

### 5a. epoll fast path
Streamline `epoll_dispatch`'s result-handling loop; avoid redundant timeout math.

### 5b. Avoid backend vtable indirection on the hot path
The `evsel`/`evbase` indirection is one load per dispatch; consider devirtualizing for the
single compiled backend when only epoll is built.

---

## Tier 6 — Lock / Sync Elision (expected: 2–8%, gated)

Only when the event base is single-threaded. **Must** pass full multi-backend + TSAN.

### 6a. Single-threaded fast paths
`EVTHREAD_*` lock macros are no-ops without threading, but the branches/atomics may remain.
Skip lock acquisition when `base->th_base_lock == NULL`.

### 6b. `event_callback_activate_nolock_` sync skipping
Elide cross-thread notify when single-threaded.

---

## Known Non-Starters (do not retry)

Document failed experiments here as they are discovered. Starting empty.

| Technique | Why it didn't work |
|-----------|--------------------|
| EVBUFFER_MAX_READ_DEFAULT tuning (Tier 2b) | The cascade OSS benchmarks (bench, bench_cascade) use raw recv/send — they do NOT call evbuffer_read. Zero effect on measured workloads. Only useful when bufferevent/evbuffer-based benchmarks are available. |
| Enable epoll changelist by default (Tier 3a) | Changelist merges DEL+ADD into 1 MOD epoll_ctl per non-persistent event cycle, but the userspace overhead (fdinfo lookup, changelist array management, flush per dispatch) cancels the 1 saved syscall at cascade scale (100-step chain). cascade_chain delta: -0.7% (noise). Note: cascade_bench uses EV_PERSIST — changelist has zero effect on it. |
| Zero-timeout fast path + changelist n_changes guard in epoll_dispatch (Tier 5a) | Both cascade benchmarks use the nochangelist backend (n_changes always 0). Adding a `if (tv_sec==0 && tv_usec==0) timeout=0` fast path (avoids evutil_tv_to_msec_ function call) and `if (n_changes)` guard (avoids 2 no-op function calls per dispatch) showed no measurable improvement: cascade_bench +0.7%, cascade_chain +0.4% — both within noise (stddev 7-9µs). These overheads are not bottlenecks; syscalls dominate. |
| EPOLLONESHOT for non-persistent events to skip epoll_ctl(DEL) (Tier 3/5) | Correctness failure: libevent's evmap only calls the backend ADD function when per-fd interest goes 0→1. A second event added to the same fd does NOT trigger a new ADD, so there's no chance to switch from EPOLLONESHOT to level-triggered. When EPOLLONESHOT fires, the fd is auto-disabled and any other registered events on the same fd are stranded (never fire). Confirmed by `regress main/multiple_events_for_same_fd` deadlock. A correct implementation requires evmap changes to call the backend even for 1→2 transitions, or re-arming logic in evmap_io_del_ — both are architectural. |
| timerfd-based optimizations (Tier 5a, any EXP) | The build uses `epoll_pwait2` (Linux ≥5.11 with `EVENT__HAVE_EPOLL_PWAIT2`), which disables `USING_TIMERFD` at compile time. There is NO timerfd in the dispatch path — no timerfd_settime, no timerfd_create. All code inside `#ifdef USING_TIMERFD` is dead. EXP-003 (accepted, dead code) and EXP-006 (rejected) both targeted this dead path. Any further timerfd optimization is pointless on this machine. The dispatch path is: epoll_pwait2(fd, events, n, tv ? &ts : NULL, NULL). |
| CLOCK_SYNC_INTERVAL = 0 (or any value > -1) in `gettime()` | Breaking `event_timer/default_clock` and `event_timer/precise_clock` regress tests: `evtimer_add` calls `gettime()` which updates `tv_clock_diff`; `evtimer_pending` immediately uses `tv_clock_diff` for monotonic→wall-clock conversion. With CLOCK_SYNC_INTERVAL=0, the second call in the same second skips the gettimeofday sync, leaving `tv_clock_diff` stale and causing `remaining > deadline` by the drift amount. The fix (EXP-008) is to bypass gettimeofday only in `update_time_cache` (not in all `gettime()` calls) by calling `evutil_gettime_monotonic_` directly. |
| Pass NULL epev to epoll_ctl(EPOLL_CTL_DEL) to skip struct construction (Tier 5a/misc) | The `memset`+2-field-write overhead of constructing `struct epoll_event` is ~4 instructions ≈ 4ns per call. Even with 100 DEL calls per cascade_chain run_once, the total saving is ~400ns vs 272µs total — completely lost in noise (observed +0.4% = noise). The kernel syscall cost dominates completely; the userspace struct construction overhead is irrelevant. Do not retry for epoll_ctl paths. |
| Skip `update_time_cache` for blocking dispatches with empty timer heap (extension of EXP-007) | `event_base_gettimeofday_cached` relies on `tv_cache` being populated by `update_time_cache` within a dispatch cycle so that all callbacks see the SAME consistent time. When skipped, each callback's `gettimeofday_cached` falls back to a fresh `gettimeofday` call, breaking time consistency (`main/gettimeofday_cached` and `main/gettimeofday_cached_sleep` regress tests fail). The `!(flags & EVLOOP_NONBLOCK)` guard in EXP-007 is a semantic boundary: NONBLOCK dispatches are polling cycles where no application code is expected to call `event_base_gettimeofday_cached`; blocking dispatches CAN have such callbacks. |
| Lazy tv_cache populate in gettimeofday_cached + skip update_time_cache for any empty-heap dispatch (EXP-011) | Even with a correctness fix (lazy populate `tv_cache` on first `gettimeofday_cached` call within a cycle, so all callbacks see the same time), the improvement is not measurable. vDSO `clock_gettime(CLOCK_MONOTONIC)` takes ~5-10ns on this GCP VM; 100 calls × 10ns = 1µs savings, below the cascade_chain noise floor (~19µs). **Time-cache optimizations are exhausted.** |
| Tier 4a: Branch hoisting in event_process_active_single_queue (EXP-012) | Both cascade benchmarks dispatch exactly 1 event per single_queue call (a=1 active). Per-event savings (2 comparisons × 1 event = <1ns) multiplied by 100 cycles = <100ns total — invisible against any noise floor. The Tier 4 3–10% estimate assumes many events per dispatch cycle (N>10). For N=1 serial-chain workloads, all Tier 4 per-event optimizations are below 0.1% and cannot be measured. **Tier 4 micro-opts are exhausted for these 1-event-per-cycle workloads.** |
| Write-back gettime result to tv_cache in gettime() to share clock read across event_add batch (EXP-013) | cascade_chain's 100 event_add calls in the measurement window each call gettime(). Write-back `base->tv_cache = *tp` saves calls 2–100. Measured improvement is only ~2µs (0.7%) — well below the 2% threshold. Root cause: the gettime cache-miss cost on this GCP VM is ~20ns (CLOCK_MONOTONIC_COARSE ~3ns + gettimeofday ~17ns at this load level), not the ~80ns implied by earlier experiments. Clock-call latency varies 3–4× with GCP VM load, making this optimization unreliable and unmeasurable at cascade scale. |

> Heed `ffc-agent-workspace`'s hard-won lessons that transfer here:
> `__attribute__((hot/cold))` and `noinline` annotations repeatedly **regressed** there
> (icache/register-allocation disruption). Treat any hot/cold/noinline tagging as a logged,
> revertible experiment — never bake it into the harness or assume it helps.

---

## AutoKernel Parallel

This playbook is the libevent equivalent of AutoKernel's `program.md` — the structured
technique catalogue the agent reads before each experiment to decide *what* to try next
and *what gain to expect*. Reference: Jaber & Jaber, arXiv:2603.21331, 2026.
