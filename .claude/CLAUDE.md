# libevent-agent-workspace — Agent Instructions

You are an optimization agent for libevent, an OSS event-notification library.
Your job: find and implement changes that improve the throughput / latency of its hot
paths, validated by benchmark + profile data.

This is a pure OSS effort against upstream libevent (`redis-performance/libevent`).
No downstream-consumer patch is in scope.

---

## Codebase Map

| Path | Purpose |
|------|---------|
| `libevent/buffer.c` | evbuffer data plane — **primary target** (read/write/drain/expand/chain alloc) |
| `libevent/event.c` | event_base loop, event registration (`event_add_nolock_`) |
| `libevent/evmap.c` | fd→event map (`evmap_io_*`) — drives `epoll_ctl` churn |
| `libevent/epoll.c` | epoll backend (`epoll_dispatch`, add/del → `epoll_ctl`) |
| `libevent/evbuffer-internal.h` | evbuffer chain internals |
| `libevent/test/bench*.c` | **Immutable OSS benchmark harness — never edit** |
| `config/hot-methods.yaml` | Which symbols matter — scope your work to these |
| `.claude/program.md` | **Tiered optimization playbook** — read before each experiment |

---

## Optimization Workflow

Inspired by AutoKernel (arXiv:2603.21331): immutable benchmark harness + mutable code +
git as the experiment ledger.

1. **Profile** — run `scripts/run-profile.sh` (4-phase); identify the hottest symbol and
   the kernel/syscall share of wall-clock
2. **Classify** — use `.claude/program.md` Bottleneck Classification table to pick a tier
3. **Consult playbook** — pick the highest-expected-gain technique from that tier not yet tried
4. **Hypothesize** — one falsifiable sentence before touching code
5. **Implement** — edit `libevent/*.c` only, in a variant worktree; one technique, minimal diff
6. **Correctness gate** (mandatory, before any benchmark) — `scripts/verify-correctness.sh`:
   - LIGHT (every iteration): build + relevant `regress` subset under per-test timeouts
   - FULL (on accept): all backends (`EVENT_NOEPOLL`/`NOSELECT`/`NOPOLL`/`NOKQUEUE`) + ASAN + TSAN
7. **Step 1: Benchmark** — `scripts/build-bench.sh && scripts/run-bench.sh`
8. **Step 2: Profile** — `scripts/run-profile.sh`; classify the new bottleneck
9. **Commit or revert**:
   - Accept → `git -C libevent add -A && git -C libevent commit -m "EXP-NNN: ..."`
   - Reject → discard the variant worktree
10. **Log** — append to `experiments/EXPERIMENTS.md`; update `experiments/SUMMARY.md` + README counts

Never benchmark broken or hanging code. Never skip the profile step.
The libevent submodule tip always reflects the best accepted state.

---

## Rules

- Edit `libevent/*.c` / `*.h` — never edit `libevent/test/bench*.c` (immutable harness)
- Each implementer variant runs in its own git worktree + isolated build dir
- All correctness stages must pass before benchmarking — no exceptions
- **Never report MB/s** — report events/sec, ns/op per fired event, and syscall count
- Log every experiment, including rejections — the reason a thing didn't work is valuable
- Keep `experiments/SUMMARY.md` and `README.md` counts in sync
- Commit to the `libevent` submodule on accept; discard the worktree on reject
- After a permanent dead end: add to "Known Non-Starters" in `.claude/program.md`
- Never force-push
- Workspace memory lives in `.workspace-memory/` — commit updates alongside results
- **Always capture a BASELINE benchmark on every target machine before applying any patch.**
  Save it as `experiments/<EXP-NNN>/bench-results/<date>-<machine>-BASELINE.json`.
  Run as `EXP=EXP-NNN scripts/run-bench.sh` so files land in the right folder.

---

## Two-Step Validation Criteria

**Benchmark (Step 1) — accept signal:**
- ≥ +2% improvement on at least one workload (events/sec up, or ns/op down)
- No regression > 1% on other workloads (within noise)
- Numbers stable across the median of ≥ 3 runs (raise repetitions if variance > 5%)
- Validated with both `perf`-on (direction) and `perf`-off (true delta) runs

**Profile (Step 2) — accept signal:**
- Target symbol's CPU % decreased, OR IPC increased, OR branch-miss rate decreased, OR
  syscall count/share decreased
- No surprising new bottleneck that voids the benchmark win

**Reject if:** < 1% delta (noise), any regression, correctness failure, or a hang.
**Park if:** promising but needs a prerequisite, or real but < 2% (not worth the complexity).

---

## Profile Interpretation

The profile is 4-phase (see `scripts/run-profile.sh` and `.claude/skills/profile.md`):

1. **Cycle budget** — `perf stat`; quantify kernel/syscall % of wall-clock. If
   `epoll_wait`+`readv`+`writev` dominate (> ~40%) the run is **syscall-bound** → route the
   next experiment to syscall reduction (iovec sizing, high-water marks, `epoll_ctl` churn),
   not userspace micro-opt.
2. **Manifest-scoped attribution** — `perf report` filtered to `config/hot-methods.yaml` symbols.
3. **Off-CPU** — detect latency-bound runs; park CPU micro-opts when off-CPU dominates.
4. **Syscall attribution** — `epoll_wait` tracepoints + `cycles:u` for user-only attribution.

Key symbols to watch: `event_base_loop` (everything is under it), `evbuffer_read` /
`evbuffer_write_atmost` (carry the syscalls), `evbuffer_expand_fast_` / `evbuffer_chain_new`
(allocation pressure), `epoll_dispatch` / `evmap_io_*` (`epoll_ctl` churn).

---

## Experiment Log Format

Append to `experiments/EXPERIMENTS.md` using `experiments/TEMPLATE.md`. Record all agent
token counts in the Token Cost table and `experiments/token-ledger.tsv`. If rejected, add
the technique to "Known Non-Starters" in `.claude/program.md`.

---

## Workspace Memory

Write memories to `.workspace-memory/` (not `~/.claude/projects/`).
Commit `.workspace-memory/` changes alongside experiment results.
