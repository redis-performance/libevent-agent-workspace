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
| Lazy epoll_ctl(DEL) deferral in `epoll_nochangelist_del/add` (Tier 3a) | The cascade_bench setup (event_del+event_add) happens **before** `gettimeofday(&ts)` — it is NOT in the timed window. Only the dispatch loop is measured. Saved 100 epoll_ctl calls per setup but 0% wall-clock improvement. cascade_chain setup IS timed but no DEL calls are in the timed window either (cleanup is after `gettimeofday(&te)`). Redirect to dispatch-loop optimizations (Tier 4, 5) or cascade_chain event_add path (100 epoll_ctl ADD calls in timed window). |
| Skip `timerfd_settime` when tv={0,0} in `epoll_dispatch` (Tier 5a) | **INAPPLICABLE on this system.** `USING_TIMERFD` is only compiled when `!defined(EVENT__HAVE_EPOLL_PWAIT2)` (epoll.c line 84). This system has `EVENT__HAVE_EPOLL_PWAIT2=1`, so the `#ifdef USING_TIMERFD` block is dead code. The hot path uses `epoll_pwait2` + `struct timespec`. Any timeout optimization must target the `epoll_pwait2` path, not the timerfd path. |
| Guard `epoll_apply_changes` + `event_changelist_remove_all_` behind `n_changes > 0` in `epoll_dispatch` (Tier 5a) | For the non-changelist `epollops` backend, `n_changes` is always 0. The cross-TU call to `event_changelist_remove_all_` costs ~10 ns/iter. Over 101 iterations this is ~1010 ns = <1% of the 106 µs baseline — below the machine noise floor (stddev 9.85 µs). Both benchmarks are **85–90% syscall-bound**; userspace savings smaller than ~20–30 ns/iter cannot be measured with 5×25 samples. Future Tier 5a attempts must target the `epoll_pwait2` call itself or result-loop overhead, not the changelist cleanup path. |
| Warm `base->tv_cache` inside `gettime` on cold calls with a local-variable `tp` (Tier 5a) | cascade_chain makes 100 cold `gettime` calls in its event_add setup loop (in timed window); caching after the first eliminates 99 redundant vDSO `clock_gettime` calls (~15 ns each = ~1.5 µs). **Below the 8–17 µs run-to-run noise floor**. Confirmed unmeasurable at 5×25 samples. Rule: any single-technique userspace savings < ~3–5 µs per run_once cannot be reliably detected with current methodology. Sub-technique (skip `update_time_cache` when heap empty) FAILS correctness: breaks `gettimeofday_cached` test requiring all same-dispatch callbacks to see identical cached time. |
| Drop `ioctl(FIONREAD)` in `get_n_bytes_readable_on_socket` (Tier 2c) | **INAPPLICABLE to cascade benchmarks.** Both `bench` and `bench_cascade` use raw `recv(fd, &ch, 1, 0)` / `send` in their callbacks and never call `evbuffer_read`. `FIONREAD` elimination therefore has zero impact on the measured workloads; cascade_chain's apparent 154 µs vs 158 µs result is machine-load noise (within the 6–17 µs run-to-run stddev). For evbuffer-based workloads (HTTP, bufferevent), this would save 1 `ioctl` syscall per read — but requires a bench_http benchmark to validate. |
| `#pragma GCC optimize("O3")` around `event_process_active_single_queue` + `event_process_active` (Tier 4a) | **REGRESSION.** cascade_bench: 106 → 124 µs (+17%); cascade_chain: 154 → 159 µs (+3%). Applying O3 to these functions caused icache pressure — O3 aggressively unrolls and inlines, bloating code size and thrashing L1 icache on the tight 100-iteration dispatch loop. Confirms program.md warning: compiler annotation disruption (hot/cold/optimize) consistently regresses libevent's dispatch path due to icache sensitivity. Do NOT apply -O3 or aggressive unroll pragmas to any event dispatch function. |
| Skip `epoll_ctl(ADD→EEXIST)` on ONESHOT re-arm by tracking "disabled-but-present" state in `ctx->oneshot` bits 2–3 (Tier 3/5 follow-on to EXP-004) | **No improvement.** cascade_chain: 166 → 172 µs (+3.6%) regression. The ADD→EEXIST path is a kernel fast-path (fails before doing the ep_item_poll readiness check); direct MOD triggers the full readiness check. Net: ADD(fast-fail)+MOD(full) ≤ MOD(full). The ONESHOT re-arm pattern is at optimum after EXP-004. Do NOT attempt further optimizations to the EPOLLONESHOT re-arm path. |
| Fast path in `evmap_io_del_` for ONESHOT single-reader (Tier 4c) — skip computing `old`/`res`/`skip_del` for sole EV_READ watcher with EPOLLONESHOT | **Below noise floor.** cascade_chain 172→154 µs (-10.5%) with code; but unaffected cascade_bench ALSO improved 124→107 µs (-13.7%) from machine noise alone — the control improved more than the treatment. Expected code saving: ~15 instructions × 100 events ≈ 1–2 µs, well below the ~6 µs run-to-run stddev. Any instruction-level optimization saving < 2 µs per run_once is permanently unmeasurable at 5×25 samples on this machine. Do NOT try further instruction-count reductions in `evmap_io_del_`, `evmap_io_add_`, `evmap_io_active_`, or similar short O(1) paths — they cannot overcome the noise floor. |
| Increase `INITIAL_NEVENT` from 32 to 64 (or any tuning of initial epoll event-array size) (Tier 5a) | **Zero effect on serial workloads.** cascade_bench: 107→106 µs (-0.9%, noise), cascade_chain: 154→155 µs (+0.6%, noise). The cascade benchmarks process exactly 1 event per `epoll_wait` — the event array never fills beyond 1 entry regardless of INITIAL_NEVENT. The auto-grow path (`res == nevents`) is never triggered. INITIAL_NEVENT tuning is only relevant for parallel workloads where N > INITIAL_NEVENT events fire simultaneously, which requires a `bench -n 100 -a 100` type workload (not currently in the harness). |
| EPOLLET (edge-triggered, stays armed after fire) instead of EPOLLONESHOT for non-persistent sole-watcher events — skip `epoll_ctl(MOD)` on re-arm (Tier 3c) | **CORRECTNESS FAILURE.** `main/simpleread`, `main/multiple`, `main/fork` hang (signal 14). EPOLLET fires only on rising edges; it MISSES pre-existing unread data when a non-persistent event re-registers without a new write. The ONESHOT→MOD re-arm in EXP-004 serves a correctness function: the MOD triggers `ep_item_poll` (kernel readiness re-check), delivering data already in the pipe. Eliminating MOD breaks any test/workload that does not fully drain the fd to EAGAIN before re-registering. The cascade_chain pattern works only because each callback reads exactly all available data (1 byte) and new data always arrives as a fresh write (new edge). EPOLLET cannot safely replace ONESHOT for general-purpose non-persistent events. |
| Cache `base->th_base_lock != NULL` as a local `with_lock` constant at entry of `event_process_active_single_queue` to skip `base->current_event_waiters` load per callback (Tier 6a) | **Below noise floor.** cascade_bench: 106→106 µs (0%), cascade_chain: 155→153 µs (-1.3%, within noise; 1734 µs OS outlier). Expected saving: ~1 ns/event × 100 events = ~100 ns per run_once — permanently below the 5–7 µs noise floor. The `current_event_waiters` load is a single L1-cached load + predicted branch; the savings are ~0.1% of total runtime which is 90% kernel/syscall. All Tier 6a lock-elision techniques for the dispatch path are exhausted. |

> Heed `ffc-agent-workspace`'s hard-won lessons that transfer here:
> `__attribute__((hot/cold))` and `noinline` annotations repeatedly **regressed** there
> (icache/register-allocation disruption). Treat any hot/cold/noinline tagging as a logged,
> revertible experiment — never bake it into the harness or assume it helps.

---

## AutoKernel Parallel

This playbook is the libevent equivalent of AutoKernel's `program.md` — the structured
technique catalogue the agent reads before each experiment to decide *what* to try next
and *what gain to expect*. Reference: Jaber & Jaber, arXiv:2603.21331, 2026.
