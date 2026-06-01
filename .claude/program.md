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

Document failed experiments here as they are discovered.

| Technique | Why it didn't work |
|-----------|--------------------|
| **EPOLLONESHOT for non-persistent events + skip `epoll_ctl(DEL)`** (overnight EXP-004, −18% cascade_chain) | **Plausible-but-wrong — breaks two epoll invariants.** (1) epoll keeps ONE epitem per fd with a combined `EPOLLIN\|EPOLLOUT` mask; `EPOLLONESHOT` disarms the *whole* epitem after one delivery, but `evmap_io` refcounts read/write/close independently — so a read+write (or persistent+non-persistent) pair on the same fd silently drops the un-fired interest (hang/data-loss). (2) "Disarmed" ≠ "removed": skipping `epoll_ctl(DEL)` leaves a live epitem in the kernel set, desyncing libevent's `old_events` from the kernel and leaving a stale registration across `close()`+fd-reuse (breaks the EEXIST→MOD / ENOENT→ADD retry paths). No re-arm path. `evmap_io.oneshot` is per-fd but eligibility (`EV_PERSIST`) is per-event. A correct version needs a single-interest-total gate + `EPOLL_CTL_MOD` re-arm and must KEEP the DEL — do not retry the skip-DEL form. (Maintainer-review mergeability 2/100.) |
| **Replace `gettime(base,…)` with `evutil_gettime_monotonic_()` in `update_time_cache`** (overnight EXP-008, −2.2% cascade_chain) | **Plausible-but-wrong — drops the wall-clock offset resync.** On its fall-through path `gettime()` also refreshes `base->tv_clock_diff` / `last_updated_clock_diff` (event.c ~433-439), the monotonic→wall-clock offset, on effectively every call. Bypassing it leaves `tv_clock_diff` stale, silently corrupting `event_base_gettimeofday_cached()`, the `EV_TIMEOUT` remap in `event_pending()`, and `event_base_dump_events()` after an NTP step / manual clock set. Any direct-monotonic-read variant MUST replicate the clock-diff resync. (Maintainer-review mergeability 25/100.) |

> Heed `ffc-agent-workspace`'s hard-won lessons that transfer here:
> `__attribute__((hot/cold))` and `noinline` annotations repeatedly **regressed** there
> (icache/register-allocation disruption). Treat any hot/cold/noinline tagging as a logged,
> revertible experiment — never bake it into the harness or assume it helps.

---

## AutoKernel Parallel

This playbook is the libevent equivalent of AutoKernel's `program.md` — the structured
technique catalogue the agent reads before each experiment to decide *what* to try next
and *what gain to expect*. Reference: Jaber & Jaber, arXiv:2603.21331, 2026.
